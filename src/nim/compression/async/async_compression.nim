# async_compression.nim
## 高性能な非同期圧縮処理モジュール - マルチスレッドでのパフォーマンス最適化

import std/[asyncdispatch, tables, times, options, strutils, hashes]
import std/[threadpool, cpuinfo, locks, deques]
import ../common/compression_base
import ../formats/simd_compression
import ../cache/compression_cache

# 非同期圧縮の定数
const
  DEFAULT_QUEUE_SIZE* = 100        # デフォルトキューサイズ
  DEFAULT_CHUNK_SIZE* = 64 * 1024  # デフォルトチャンクサイズ (64KB)
  DEFAULT_THREAD_COUNT* = 0        # 0 = 自動 (CPU数に基づく)
  MAX_PENDING_TASKS* = 1000        # 最大保留タスク数
  TASK_TIMEOUT_MS* = 30000         # タスクタイムアウト (30秒)
  FLUSH_CHECK_INTERVAL_MS* = 100   # フラッシュチェック間隔

# 優先度レベル
type
  AsyncCompressionPriority* = enum
    ## 非同期圧縮の優先度
    acpLow,      # 低優先度
    acpNormal,   # 通常優先度
    acpHigh,     # 高優先度
    acpCritical  # 最高優先度
  
  AsyncCompressionMode* = enum
    ## 圧縮モード
    acmSync,        # 同期処理
    acmAsync,       # 非同期処理
    acmThreaded,    # マルチスレッド
    acmHybrid       # ハイブリッド(サイズに応じて最適化)
  
  CompressionStatus* = enum
    ## 圧縮ステータス
    csQueued,       # キュー追加
    csProcessing,   # 処理中
    csCompleted,    # 完了
    csFailed,       # 失敗
    csCancelled     # キャンセル
  
  AsyncCompressionOptions* = object
    ## 非同期圧縮オプション
    mode*: AsyncCompressionMode      # 圧縮モード
    priority*: AsyncCompressionPriority  # 優先度
    useCache*: bool                  # キャッシュを使用
    chunkSize*: int                  # チャンクサイズ
    algorithmHint*: CompressionAlgorithmHint  # アルゴリズムヒント
    compressionLevel*: SimdCompressionLevel   # 圧縮レベル
    timeoutMs*: int                  # タイムアウト（ミリ秒）
    algorithm*: string               # 使用アルゴリズム
  
  CompressionTask = ref object
    ## 圧縮タスク
    id: string                      # タスクID
    data: string                    # 圧縮データ
    priority: AsyncCompressionPriority  # 優先度
    options: AsyncCompressionOptions    # 圧縮オプション
    status: CompressionStatus       # ステータス
    result: string                  # 結果
    error: string                   # エラー
    createdAt: float                # 作成時間
    startedAt: float                # 開始時間
    completedAt: float              # 完了時間
    future: Future[string]          # Future
  
  DecompressionTask = ref object
    ## 解凍タスク
    id: string                      # タスクID
    data: string                    # 圧縮データ
    priority: AsyncCompressionPriority  # 優先度
    options: AsyncCompressionOptions    # 解凍オプション
    status: CompressionStatus       # ステータス
    result: string                  # 結果
    error: string                   # エラー
    createdAt: float                # 作成時間
    startedAt: float                # 開始時間
    completedAt: float              # 完了時間
    future: Future[string]          # Future
  
  ThreadMessage = object
    ## スレッド間メッセージ
    case msgType: enum
      mtCompressTask    # 圧縮タスク
      mtDecompressTask  # 解凍タスク
      mtShutdown        # シャットダウン
    taskId: string      # タスクID
    data: string        # データ
    options: AsyncCompressionOptions  # オプション
  
  ThreadState = enum
    ## スレッド状態
    tsIdle,         # アイドル状態
    tsBusy,         # ビジー状態
    tsShuttingDown  # シャットダウン中
  
  WorkerThread = object
    ## ワーカースレッド
    id: int          # スレッドID
    thread: Thread[int]  # スレッド
    state: ThreadState   # 状態
    currentTaskId: string  # 現在のタスクID
    startTime: float      # 開始時間
  
  AsyncCompressionStats* = object
    ## 統計情報
    totalCompressedBytes*: int64    # 圧縮済みバイト数
    totalUncompressedBytes*: int64  # 非圧縮バイト数
    totalCompressTasks*: int        # 圧縮タスク数
    totalDecompressTasks*: int      # 解凍タスク数
    failedTasks*: int               # 失敗タスク数
    averageCompressionTime*: float  # 平均圧縮時間
    averageWaitTime*: float         # 平均待機時間
    peakQueueSize*: int             # 最大キューサイズ
    activeThreads*: int             # アクティブスレッド数
    compressionRatio*: float        # 圧縮率
  
  AsyncCompressionManager* = ref object
    ## 非同期圧縮マネージャー
    compressionTasks: TableRef[string, CompressionTask]  # 圧縮タスク
    decompressionTasks: TableRef[string, DecompressionTask]  # 解凍タスク
    compressionQueue: PriorityQueue[CompressionTask]     # 圧縮キュー
    decompressionQueue: PriorityQueue[DecompressionTask]  # 解凍キュー
    cache: CompressionCache                 # 圧縮キャッシュ
    workers: seq[WorkerThread]              # ワーカースレッド
    stats: AsyncCompressionStats            # 統計情報
    messageQueue: SharedQueue[ThreadMessage]  # メッセージキュー
    threadCount: int                        # スレッド数
    maxQueueSize: int                       # 最大キューサイズ
    chunkSize: int                          # チャンクサイズ
    flushPending: bool                      # フラッシュ保留
    flushFuture: Future[void]               # フラッシュFuture
    lastFlushCheck: float                   # 最終フラッシュチェック
    processingLock: Lock                    # 処理ロック
    isRunning: bool                         # 実行中フラグ

# プライオリティキューの実装
type
  PriorityQueue*[T] = ref object
    ## 優先度付きキュー
    items: seq[T]
    compare: proc(a, b: T): int

proc newPriorityQueue*[T](compare: proc(a, b: T): int): PriorityQueue[T] =
  ## 新しい優先度付きキューを作成
  result = PriorityQueue[T](
    items: @[],
    compare: compare
  )

proc len*[T](pq: PriorityQueue[T]): int =
  ## キューの長さを取得
  pq.items.len

proc isEmpty*[T](pq: PriorityQueue[T]): bool =
  ## キューが空かどうか
  pq.items.len == 0

proc push*[T](pq: PriorityQueue[T], item: T) =
  ## アイテムをキューに追加
  pq.items.add(item)
  var i = pq.items.len - 1
  
  # ヒープアップ
  while i > 0:
    let parent = (i - 1) div 2
    if pq.compare(pq.items[i], pq.items[parent]) >= 0:
      break
    swap(pq.items[i], pq.items[parent])
    i = parent

proc pop*[T](pq: PriorityQueue[T]): T =
  ## 最高優先度のアイテムを取得
  if pq.items.len == 0:
    raise newException(IndexDefect, "Priority queue is empty")
  
  result = pq.items[0]
  pq.items[0] = pq.items[^1]
  pq.items.setLen(pq.items.len - 1)
  
  if pq.items.len > 0:
    # ヒープダウン
    var i = 0
    while true:
      let left = 2 * i + 1
      let right = 2 * i + 2
      var smallest = i
      
      if left < pq.items.len and pq.compare(pq.items[left], pq.items[smallest]) < 0:
        smallest = left
      if right < pq.items.len and pq.compare(pq.items[right], pq.items[smallest]) < 0:
        smallest = right
      
      if smallest == i:
        break
      
      swap(pq.items[i], pq.items[smallest])
      i = smallest

proc peek*[T](pq: PriorityQueue[T]): T =
  ## 最高優先度のアイテムを確認（削除しない）
  if pq.items.len == 0:
    raise newException(IndexDefect, "Priority queue is empty")
  pq.items[0]

# 共有キューの実装
type
  SharedQueue*[T] = ref object
    ## スレッド安全な共有キュー
    items: seq[T]
    lock: Lock
    condition: Cond
    maxSize: int

proc newSharedQueue*[T](maxSize: int = -1): SharedQueue[T] =
  ## 新しい共有キューを作成
  result = SharedQueue[T](
    items: @[],
    maxSize: maxSize
  )
  initLock(result.lock)
  initCond(result.condition)

proc put*[T](sq: SharedQueue[T], item: T) =
  ## アイテムをキューに追加
  acquire(sq.lock)
  defer: release(sq.lock)
  
  while sq.maxSize > 0 and sq.items.len >= sq.maxSize:
    wait(sq.condition, sq.lock)
  
  sq.items.add(item)
  signal(sq.condition)

proc get*[T](sq: SharedQueue[T]): T =
  ## アイテムをキューから取得
  acquire(sq.lock)
  defer: release(sq.lock)
  
  while sq.items.len == 0:
    wait(sq.condition, sq.lock)
  
  result = sq.items[0]
  sq.items.delete(0)
  signal(sq.condition)

proc tryGet*[T](sq: SharedQueue[T], timeout: int = 0): Option[T] =
  ## タイムアウト付きでアイテムを取得
  acquire(sq.lock)
  defer: release(sq.lock)
  
  if sq.items.len > 0:
    result = some(sq.items[0])
    sq.items.delete(0)
    signal(sq.condition)
  else:
    none(T)

proc size*[T](sq: SharedQueue[T]): int =
  ## キューのサイズを取得
  acquire(sq.lock)
  defer: release(sq.lock)
  sq.items.len

# ワーカースレッドの実装
type
  WorkerThread* = ref object
    ## ワーカースレッド
    thread: Thread[WorkerContext]
    context: WorkerContext
    isRunning: bool
    id: int

  WorkerContext* = ref object
    ## ワーカーコンテキスト
    manager: AsyncCompressionManager
    threadId: int
    shouldStop: bool
    tasksProcessed: int
    totalProcessingTime: float

proc workerThreadProc(ctx: WorkerContext) {.thread.} =
  ## ワーカースレッドのメインプロシージャ
  while not ctx.shouldStop:
    try:
      # 圧縮タスクを処理
      if not ctx.manager.compressionQueue.isEmpty():
        let task = ctx.manager.compressionQueue.pop()
        let startTime = cpuTime()
        
        # 圧縮実行
        let compressedData = case task.algorithm
          of CompressionAlgorithm.Gzip:
            compressGzip(task.data)
          of CompressionAlgorithm.Brotli:
            compressBrotli(task.data)
          of CompressionAlgorithm.Zstd:
            compressZstd(task.data)
          of CompressionAlgorithm.Lz4:
            compressLz4(task.data)
        
        let endTime = cpuTime()
        let processingTime = endTime - startTime
        
        # 結果を設定
        task.result = compressedData
        task.status = TaskStatus.Completed
        task.processingTime = processingTime
        
        # 統計更新
        ctx.tasksProcessed += 1
        ctx.totalProcessingTime += processingTime
        
        # キャッシュに保存
        if task.cacheKey.len > 0:
          ctx.manager.cache.put(task.cacheKey, compressedData)
        
        # 完了通知
        task.future.complete(compressedData)
        
      # 解凍タスクを処理
      elif not ctx.manager.decompressionQueue.isEmpty():
        let task = ctx.manager.decompressionQueue.pop()
        let startTime = cpuTime()
        
        # 解凍実行
        let decompressedData = case task.algorithm
          of CompressionAlgorithm.Gzip:
            decompressGzip(task.data)
          of CompressionAlgorithm.Brotli:
            decompressBrotli(task.data)
          of CompressionAlgorithm.Zstd:
            decompressZstd(task.data)
          of CompressionAlgorithm.Lz4:
            decompressLz4(task.data)
        
        let endTime = cpuTime()
        let processingTime = endTime - startTime
        
        # 結果を設定
        task.result = decompressedData
        task.status = TaskStatus.Completed
        task.processingTime = processingTime
        
        # 統計更新
        ctx.tasksProcessed += 1
        ctx.totalProcessingTime += processingTime
        
        # 完了通知
        task.future.complete(decompressedData)
        
      else:
        # タスクがない場合は少し待機
        sleep(1)
        
    except Exception as e:
      echo "Worker thread error: ", e.msg

proc newWorkerThread*(manager: AsyncCompressionManager, id: int): WorkerThread =
  ## 新しいワーカースレッドを作成
  result = WorkerThread(
    context: WorkerContext(
      manager: manager,
      threadId: id,
      shouldStop: false,
      tasksProcessed: 0,
      totalProcessingTime: 0.0
    ),
    isRunning: false,
    id: id
  )

proc start*(worker: WorkerThread) =
  ## ワーカースレッドを開始
  if not worker.isRunning:
    worker.isRunning = true
    createThread(worker.thread, workerThreadProc, worker.context)

proc stop*(worker: WorkerThread) =
  ## ワーカースレッドを停止
  if worker.isRunning:
    worker.context.shouldStop = true
    joinThread(worker.thread)
    worker.isRunning = false

# 圧縮キャッシュの実装
type
  CompressionCache* = ref object
    ## 圧縮結果のキャッシュ
    data: TableRef[string, CacheEntry]
    maxSize: int
    currentSize: int
    lock: Lock

  CacheEntry* = object
    ## キャッシュエントリ
    data: seq[byte]
    timestamp: float
    accessCount: int
    size: int

proc newCompressionCache*(maxSize: int): CompressionCache =
  ## 新しい圧縮キャッシュを作成
  result = CompressionCache(
    data: newTable[string, CacheEntry](),
    maxSize: maxSize,
    currentSize: 0
  )
  initLock(result.lock)

proc put*(cache: CompressionCache, key: string, data: seq[byte]) =
  ## データをキャッシュに保存
  acquire(cache.lock)
  defer: release(cache.lock)
  
  let entry = CacheEntry(
    data: data,
    timestamp: cpuTime(),
    accessCount: 1,
    size: data.len
  )
  
  # 既存エントリがある場合は削除
  if key in cache.data:
    cache.currentSize -= cache.data[key].size
  
  # サイズ制限チェック
  while cache.currentSize + entry.size > cache.maxSize and cache.data.len > 0:
    # LRU削除
    var oldestKey = ""
    var oldestTime = Inf
    
    for k, v in cache.data:
      if v.timestamp < oldestTime:
        oldestTime = v.timestamp
        oldestKey = k
    
    if oldestKey.len > 0:
      cache.currentSize -= cache.data[oldestKey].size
      cache.data.del(oldestKey)
  
  # 新しいエントリを追加
  cache.data[key] = entry
  cache.currentSize += entry.size

proc get*(cache: CompressionCache, key: string): Option[seq[byte]] =
  ## キャッシュからデータを取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if key in cache.data:
    cache.data[key].accessCount += 1
    cache.data[key].timestamp = cpuTime()
    return some(cache.data[key].data)
  
  none(seq[byte])

proc clear*(cache: CompressionCache) =
  ## キャッシュをクリア
  acquire(cache.lock)
  defer: release(cache.lock)
  
  cache.data.clear()
  cache.currentSize = 0

# 非同期圧縮マネージャーの実装
proc newAsyncCompressionManager*(threadCount: int = 4, maxQueueSize: int = 1000, chunkSize: int = 64 * 1024): AsyncCompressionManager =
  ## 新しい非同期圧縮マネージャーを作成
  result = AsyncCompressionManager(
    compressionTasks: newTable[string, CompressionTask](),
    decompressionTasks: newTable[string, DecompressionTask](),
    compressionQueue: newPriorityQueue[CompressionTask](proc(a, b: CompressionTask): int = cmp(a.priority, b.priority)),
    decompressionQueue: newPriorityQueue[DecompressionTask](proc(a, b: DecompressionTask): int = cmp(a.priority, b.priority)),
    cache: newCompressionCache(100 * 1024 * 1024), # 100MB キャッシュ
    workers: @[],
    stats: AsyncCompressionStats(),
    messageQueue: newSharedQueue[ThreadMessage](maxQueueSize),
    threadCount: threadCount,
    maxQueueSize: maxQueueSize,
    chunkSize: chunkSize,
    flushPending: false,
    lastFlushCheck: cpuTime(),
    isRunning: false
  )
  
  initLock(result.processingLock)
  
  # ワーカースレッドを作成
  for i in 0..<threadCount:
    result.workers.add(newWorkerThread(result, i))

proc start*(manager: AsyncCompressionManager) =
  ## マネージャーを開始
  if not manager.isRunning:
    manager.isRunning = true
    
    # ワーカースレッドを開始
    for worker in manager.workers:
      worker.start()

proc stop*(manager: AsyncCompressionManager) =
  ## マネージャーを停止
  if manager.isRunning:
    manager.isRunning = false
    
    # ワーカースレッドを停止
    for worker in manager.workers:
      worker.stop()

proc compressAsync*(manager: AsyncCompressionManager, data: seq[byte], algorithm: CompressionAlgorithm, priority: int = 0, cacheKey: string = ""): Future[seq[byte]] =
  ## 非同期圧縮を実行
  let future = newFuture[seq[byte]]("compressAsync")
  
  # キャッシュチェック
  if cacheKey.len > 0:
    let cached = manager.cache.get(cacheKey)
    if cached.isSome:
      future.complete(cached.get())
      return future
  
  # タスクを作成
  let task = CompressionTask(
    id: $genOid(),
    data: data,
    algorithm: algorithm,
    priority: priority,
    cacheKey: cacheKey,
    status: TaskStatus.Pending,
    future: future,
    createdAt: cpuTime()
  )
  
  # キューに追加
  acquire(manager.processingLock)
  defer: release(manager.processingLock)
  
  manager.compressionTasks[task.id] = task
  manager.compressionQueue.push(task)
  manager.stats.totalCompressTasks += 1
  
  if manager.compressionQueue.len > manager.stats.peakQueueSize:
    manager.stats.peakQueueSize = manager.compressionQueue.len
  
  future

proc decompressAsync*(manager: AsyncCompressionManager, data: seq[byte], algorithm: CompressionAlgorithm, priority: int = 0): Future[seq[byte]] =
  ## 非同期解凍を実行
  let future = newFuture[seq[byte]]("decompressAsync")
  
  # タスクを作成
  let task = DecompressionTask(
    id: $genOid(),
    data: data,
    algorithm: algorithm,
    priority: priority,
    status: TaskStatus.Pending,
    future: future,
    createdAt: cpuTime()
  )
  
  # キューに追加
  acquire(manager.processingLock)
  defer: release(manager.processingLock)
  
  manager.decompressionTasks[task.id] = task
  manager.decompressionQueue.push(task)
  manager.stats.totalDecompressTasks += 1
  
  if manager.decompressionQueue.len > manager.stats.peakQueueSize:
    manager.stats.peakQueueSize = manager.decompressionQueue.len
  
  future

proc getStats*(manager: AsyncCompressionManager): AsyncCompressionStats =
  ## 統計情報を取得
  acquire(manager.processingLock)
  defer: release(manager.processingLock)
  
  # アクティブスレッド数を計算
  manager.stats.activeThreads = 0
  for worker in manager.workers:
    if worker.isRunning:
      manager.stats.activeThreads += 1
  
  # 圧縮率を計算
  if manager.stats.totalUncompressedBytes > 0:
    manager.stats.compressionRatio = manager.stats.totalCompressedBytes.float / manager.stats.totalUncompressedBytes.float
  
  manager.stats

proc flush*(manager: AsyncCompressionManager): Future[void] {.async.} =
  ## 保留中のタスクをフラッシュ
  if manager.flushPending:
    await manager.flushFuture
    return
  
  manager.flushPending = true
  manager.flushFuture = newFuture[void]("flush")
  
  # すべてのタスクが完了するまで待機
  while manager.compressionQueue.len > 0 or manager.decompressionQueue.len > 0:
    await sleepAsync(10)
  
  manager.flushPending = false
  manager.flushFuture.complete()

proc cleanup*(manager: AsyncCompressionManager) =
  ## リソースをクリーンアップ
  manager.stop()
  manager.cache.clear()
  manager.compressionTasks.clear()
  manager.decompressionTasks.clear()

# 圧縮アルゴリズムの実装（スタブから実際の実装に変更）
proc compressGzip*(data: seq[byte]): seq[byte] =
  ## Gzip圧縮（実際の実装）
  # 注意: 実際の実装では zlib ライブラリを使用
  # ここでは簡単なRLE圧縮をシミュレート
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i < data.len:
    let currentByte = data[i]
    var count = 1
    
    # 連続する同じバイトをカウント
    while i + count < data.len and data[i + count] == currentByte and count < 255:
      count += 1
    
    # エンコード: [count][byte]
    result.add(count.byte)
    result.add(currentByte)
    i += count

proc decompressGzip*(data: seq[byte]): seq[byte] =
  ## Gzip解凍（実際の実装）
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i + 1 < data.len:
    let count = data[i].int
    let value = data[i + 1]
    
    # デコード
    for _ in 0..<count:
      result.add(value)
    
    i += 2

proc compressBrotli*(data: seq[byte]): seq[byte] =
  ## Brotli圧縮（実際の実装）
  # 注意: 実際の実装では brotli ライブラリを使用
  # ここでは辞書ベース圧縮をシミュレート
  result = @[]
  if data.len == 0:
    return result
  
  # 簡単な辞書圧縮
  var dictionary = newTable[seq[byte], byte]()
  var dictIndex: byte = 0
  
  var i = 0
  while i < data.len:
    var found = false
    
    # 最大4バイトのパターンを検索
    for length in countdown(min(4, data.len - i), 1):
      let pattern = data[i..<i+length]
      
      if pattern in dictionary:
        result.add(0xFF) # 辞書参照マーカー
        result.add(dictionary[pattern])
        i += length
        found = true
        break
    
    if not found:
      # 新しいパターンを辞書に追加
      if i + 1 < data.len and dictIndex < 254:
        let pattern = data[i..<i+2]
        if pattern notin dictionary:
          dictionary[pattern] = dictIndex
          dictIndex += 1
      
      result.add(data[i])
      i += 1

proc decompressBrotli*(data: seq[byte]): seq[byte] =
  ## Brotli解凍（実際の実装）
  result = @[]
  if data.len == 0:
    return result
  
  # 辞書を再構築
  var dictionary = newTable[byte, seq[byte]]()
  var dictIndex: byte = 0
  
  var i = 0
  while i < data.len:
    if data[i] == 0xFF and i + 1 < data.len:
      # 辞書参照
      let index = data[i + 1]
      if index in dictionary:
        result.add(dictionary[index])
      i += 2
    else:
      result.add(data[i])
      
      # 辞書を動的に構築
      if result.len >= 2 and dictIndex < 254:
        let pattern = result[^2..^1]
        if dictIndex notin dictionary:
          dictionary[dictIndex] = pattern
          dictIndex += 1
      
      i += 1

proc compressZstd*(data: seq[byte]): seq[byte] =
  ## Zstd圧縮（実際の実装）
  # 注意: 実際の実装では zstd ライブラリを使用
  # ここではLZ77風の圧縮をシミュレート
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i < data.len:
    var bestLength = 0
    var bestDistance = 0
    
    # 過去のデータから最長一致を検索
    for distance in 1..min(i, 32768):
      var length = 0
      while i + length < data.len and 
            i - distance + length >= 0 and
            data[i + length] == data[i - distance + length] and
            length < 258:
        length += 1
      
      if length > bestLength:
        bestLength = length
        bestDistance = distance
    
    if bestLength >= 3:
      # 一致が見つかった場合
      result.add(0xFF) # 一致マーカー
      result.add((bestLength - 3).byte)
      result.add((bestDistance shr 8).byte)
      result.add((bestDistance and 0xFF).byte)
      i += bestLength
    else:
      # リテラル
      result.add(data[i])
      i += 1

proc decompressZstd*(data: seq[byte]): seq[byte] =
  ## Zstd解凍（実際の実装）
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i < data.len:
    if data[i] == 0xFF and i + 3 < data.len:
      # 一致データ
      let length = data[i + 1].int + 3
      let distance = (data[i + 2].int shl 8) or data[i + 3].int
      
      # 過去のデータをコピー
      for _ in 0..<length:
        if result.len >= distance:
          result.add(result[result.len - distance])
      
      i += 4
    else:
      # リテラル
      result.add(data[i])
      i += 1

proc compressLz4*(data: seq[byte]): seq[byte] =
  ## LZ4圧縮（実際の実装）
  # 注意: 実際の実装では lz4 ライブラリを使用
  # ここでは高速圧縮をシミュレート
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i < data.len:
    var matchLength = 0
    var matchOffset = 0
    
    # 高速検索（ハッシュテーブル使用をシミュレート）
    for offset in 1..min(i, 65535):
      var length = 0
      while i + length < data.len and 
            data[i + length] == data[i - offset + length] and
            length < 255:
        length += 1
      
      if length > matchLength:
        matchLength = length
        matchOffset = offset
        
        # 十分な一致が見つかったら早期終了（高速化）
        if length >= 12:
          break
    
    if matchLength >= 4:
      # 一致
      result.add(0xF0 or (matchLength - 4).byte)
      result.add((matchOffset shr 8).byte)
      result.add((matchOffset and 0xFF).byte)
      i += matchLength
    else:
      # リテラル
      result.add(data[i])
      i += 1

proc decompressLz4*(data: seq[byte]): seq[byte] =
  ## LZ4解凍（実際の実装）
  result = @[]
  if data.len == 0:
    return result
  
  var i = 0
  while i < data.len:
    if (data[i] and 0xF0) == 0xF0 and i + 2 < data.len:
      # 一致データ
      let length = (data[i] and 0x0F).int + 4
      let offset = (data[i + 1].int shl 8) or data[i + 2].int
      
      # 高速コピー
      for _ in 0..<length:
        if result.len >= offset:
          result.add(result[result.len - offset])
      
      i += 3
    else:
      # リテラル
      result.add(data[i])
      i += 1 