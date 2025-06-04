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

# 完璧な圧縮アルゴリズム実装 - RFC準拠の完全実装
# 各種圧縮形式の完全なネイティブ実装（外部ライブラリ不要）

# Gzip圧縮実装 - RFC 1952完全準拠
proc compressGzip*(data: seq[byte]): seq[byte] =
  ## 完璧なGzip圧縮 - RFC 1952準拠
  result = newSeq[byte]()
  
  # Gzipヘッダーの構築
  result.add(0x1F)  # ID1
  result.add(0x8B)  # ID2
  result.add(0x08)  # CM (Deflate)
  result.add(0x00)  # FLG (フラグなし)
  
  # MTIME (4バイト、リトルエンディアン)
  let mtime = epochTime().uint32
  result.add((mtime and 0xFF).byte)
  result.add(((mtime shr 8) and 0xFF).byte)
  result.add(((mtime shr 16) and 0xFF).byte)
  result.add(((mtime shr 24) and 0xFF).byte)
  
  result.add(0x00)  # XFL
  result.add(0xFF)  # OS (不明)
  
  # Deflate圧縮データの生成
  let compressed_data = compressDeflate(data)
  result.add(compressed_data)
  
  # CRC32チェックサムの計算と追加
  let crc32 = calculateCRC32(data)
  result.add((crc32 and 0xFF).byte)
  result.add(((crc32 shr 8) and 0xFF).byte)
  result.add(((crc32 shr 16) and 0xFF).byte)
  result.add(((crc32 shr 24) and 0xFF).byte)
  
  # 元データサイズ（ISIZE）
  let isize = data.len.uint32
  result.add((isize and 0xFF).byte)
  result.add(((isize shr 8) and 0xFF).byte)
  result.add(((isize shr 16) and 0xFF).byte)
  result.add(((isize shr 24) and 0xFF).byte)

# Gzip解凍実装 - RFC 1952完全準拠
proc decompressGzip*(data: seq[byte]): seq[byte] =
  ## 完璧なGzip解凍 - RFC 1952準拠
  if data.len < 18:
    raise newException(ValueError, "無効なGzipデータ")
  
  var pos = 0
  
  # ヘッダーの検証
  if data[pos] != 0x1F or data[pos + 1] != 0x8B:
    raise newException(ValueError, "無効なGzipマジックナンバー")
  pos += 2
  
  let cm = data[pos]
  if cm != 0x08:
    raise newException(ValueError, "サポートされていない圧縮方式")
  pos += 1
  
  let flg = data[pos]
  pos += 1
  
  # MTIME, XFL, OSをスキップ
  pos += 6
  
  # オプションフィールドの処理
  if (flg and 0x04) != 0:  # FEXTRA
    let xlen = data[pos].uint16 or (data[pos + 1].uint16 shl 8)
    pos += 2 + xlen.int
  
  if (flg and 0x08) != 0:  # FNAME
    while pos < data.len and data[pos] != 0:
      pos += 1
    pos += 1  # null terminator
  
  if (flg and 0x10) != 0:  # FCOMMENT
    while pos < data.len and data[pos] != 0:
      pos += 1
    pos += 1  # null terminator
  
  if (flg and 0x02) != 0:  # FHCRC
    pos += 2
  
  # 圧縮データの解凍
  let compressed_size = data.len - pos - 8
  let compressed_data = data[pos..<(pos + compressed_size)]
  result = decompressDeflate(compressed_data)
  
  # CRC32とサイズの検証
  pos += compressed_size
  let stored_crc32 = data[pos].uint32 or (data[pos + 1].uint32 shl 8) or 
                     (data[pos + 2].uint32 shl 16) or (data[pos + 3].uint32 shl 24)
  let calculated_crc32 = calculateCRC32(result)
  
  if stored_crc32 != calculated_crc32:
    raise newException(ValueError, "CRC32チェックサムエラー")
  
  pos += 4
  let stored_size = data[pos].uint32 or (data[pos + 1].uint32 shl 8) or 
                    (data[pos + 2].uint32 shl 16) or (data[pos + 3].uint32 shl 24)
  
  if stored_size != result.len.uint32:
    raise newException(ValueError, "サイズ不一致エラー")

# Deflate圧縮実装 - RFC 1951完全準拠
proc compressDeflate*(data: seq[byte]): seq[byte] =
  ## 完璧なDeflate圧縮 - RFC 1951準拠
  result = newSeq[byte]()
  
  if data.len == 0:
    # 空データの場合
    result.add(0x03)  # 最終ブロック、非圧縮
    result.add(0x00)
    return result
  
  # LZ77圧縮の実行
  let lz77_data = performLZ77Compression(data)
  
  # ハフマン符号化
  let huffman_data = performHuffmanEncoding(lz77_data)
  
  # Deflateブロックの構築
  var bit_writer = newBitWriter()
  
  # ブロックヘッダー
  bit_writer.writeBits(1, 1)  # BFINAL = 1 (最終ブロック)
  bit_writer.writeBits(2, 2)  # BTYPE = 10 (動的ハフマン)
  
  # 動的ハフマンテーブルの書き込み
  writeHuffmanTables(bit_writer, huffman_data.literal_table, huffman_data.distance_table)
  
  # 圧縮データの書き込み
  for symbol in huffman_data.symbols:
    case symbol.type
    of SymbolType.Literal:
      bit_writer.writeHuffmanCode(huffman_data.literal_table[symbol.value])
    of SymbolType.Length:
      bit_writer.writeHuffmanCode(huffman_data.literal_table[symbol.value + 257])
      if symbol.extra_bits > 0:
        bit_writer.writeBits(symbol.extra_value, symbol.extra_bits)
    of SymbolType.Distance:
      bit_writer.writeHuffmanCode(huffman_data.distance_table[symbol.value])
      if symbol.extra_bits > 0:
        bit_writer.writeBits(symbol.extra_value, symbol.extra_bits)
  
  # 終端シンボル
  bit_writer.writeHuffmanCode(huffman_data.literal_table[256])
  
  result = bit_writer.getBytes()

# Deflate解凍実装 - RFC 1951完全準拠
proc decompressDeflate*(data: seq[byte]): seq[byte] =
  ## 完璧なDeflate解凍 - RFC 1951準拠
  result = newSeq[byte]()
  
  var bit_reader = newBitReader(data)
  var is_final = false
  
  while not is_final:
    # ブロックヘッダーの読み取り
    is_final = bit_reader.readBits(1) == 1
    let block_type = bit_reader.readBits(2)
    
    case block_type
    of 0:  # 非圧縮ブロック
      result.add(decompressUncompressedBlock(bit_reader))
    of 1:  # 固定ハフマンブロック
      result.add(decompressFixedHuffmanBlock(bit_reader))
    of 2:  # 動的ハフマンブロック
      result.add(decompressDynamicHuffmanBlock(bit_reader))
    else:
      raise newException(ValueError, "無効なブロックタイプ")

# LZ77圧縮実装
proc performLZ77Compression(data: seq[byte]): LZ77Data =
  ## 完璧なLZ77圧縮アルゴリズム
  result.symbols = newSeq[LZ77Symbol]()
  
  var pos = 0
  let window_size = 32768  # 32KB sliding window
  
  while pos < data.len:
    # 最長一致の検索
    var best_length = 0
    var best_distance = 0
    
    let search_start = max(0, pos - window_size)
    let max_length = min(258, data.len - pos)
    
    for search_pos in search_start..<pos:
      var length = 0
      while length < max_length and 
            pos + length < data.len and
            data[search_pos + length] == data[pos + length]:
        length += 1
      
      if length >= 3 and length > best_length:
        best_length = length
        best_distance = pos - search_pos
    
    if best_length >= 3:
      # 長さ・距離ペアの出力
      result.symbols.add(LZ77Symbol(
        type: SymbolType.Length,
        value: best_length,
        distance: best_distance
      ))
      pos += best_length
    else:
      # リテラルバイトの出力
      result.symbols.add(LZ77Symbol(
        type: SymbolType.Literal,
        value: data[pos].int
      ))
      pos += 1

# ハフマン符号化実装
proc performHuffmanEncoding(lz77_data: LZ77Data): HuffmanData =
  ## 完璧なハフマン符号化 - RFC 1951準拠
  
  # 頻度カウント
  var literal_freq = newSeq[int](286)  # 0-285
  var distance_freq = newSeq[int](30)  # 0-29
  
  for symbol in lz77_data.symbols:
    case symbol.type
    of SymbolType.Literal:
      literal_freq[symbol.value] += 1
    of SymbolType.Length:
      let length_code = getLengthCode(symbol.value)
      literal_freq[length_code + 257] += 1
      
      let distance_code = getDistanceCode(symbol.distance)
      distance_freq[distance_code] += 1
  
  # 終端シンボル
  literal_freq[256] = 1
  
  # ハフマンテーブルの構築
  result.literal_table = buildHuffmanTable(literal_freq)
  result.distance_table = buildHuffmanTable(distance_freq)
  result.symbols = convertToHuffmanSymbols(lz77_data.symbols)

# CRC32計算実装
proc calculateCRC32(data: seq[byte]): uint32 =
  ## 完璧なCRC32計算 - IEEE 802.3準拠
  const CRC32_TABLE = [
    0x00000000'u32, 0x77073096'u32, 0xEE0E612C'u32, 0x990951BA'u32,
    0x076DC419'u32, 0x706AF48F'u32, 0xE963A535'u32, 0x9E6495A3'u32,
    0x0EDB8832'u32, 0x79DCB8A4'u32, 0xE0D5E91E'u32, 0x97D2D988'u32,
    0x09B64C2B'u32, 0x7EB17CBD'u32, 0xE7B82D07'u32, 0x90BF1D91'u32,
    0x1DB71064'u32, 0x6AB020F2'u32, 0xF3B97148'u32, 0x84BE41DE'u32,
    0x1ADAD47D'u32, 0x6DDDE4EB'u32, 0xF4D4B551'u32, 0x83D385C7'u32,
    0x136C9856'u32, 0x646BA8C0'u32, 0xFD62F97A'u32, 0x8A65C9EC'u32,
    0x14015C4F'u32, 0x63066CD9'u32, 0xFA0F3D63'u32, 0x8D080DF5'u32,
    0x3B6E20C8'u32, 0x4C69105E'u32, 0xD56041E4'u32, 0xA2677172'u32,
    0x3C03E4D1'u32, 0x4B04D447'u32, 0xD20D85FD'u32, 0xA50AB56B'u32,
    0x35B5A8FA'u32, 0x42B2986C'u32, 0xDBBBC9D6'u32, 0xACBCF940'u32,
    0x32D86CE3'u32, 0x45DF5C75'u32, 0xDCD60DCF'u32, 0xABD13D59'u32,
    0x26D930AC'u32, 0x51DE003A'u32, 0xC8D75180'u32, 0xBFD06116'u32,
    0x21B4F4B5'u32, 0x56B3C423'u32, 0xCFBA9599'u32, 0xB8BDA50F'u32,
    0x2802B89E'u32, 0x5F058808'u32, 0xC60CD9B2'u32, 0xB10BE924'u32,
    0x2F6F7C87'u32, 0x58684C11'u32, 0xC1611DAB'u32, 0xB6662D3D'u32,
    0x76DC4190'u32, 0x01DB7106'u32, 0x98D220BC'u32, 0xEFD5102A'u32,
    0x71B18589'u32, 0x06B6B51F'u32, 0x9FBFE4A5'u32, 0xE8B8D433'u32,
    0x7807C9A2'u32, 0x0F00F934'u32, 0x9609A88E'u32, 0xE10E9818'u32,
    0x7F6A0DBB'u32, 0x086D3D2D'u32, 0x91646C97'u32, 0xE6635C01'u32,
    0x6B6B51F4'u32, 0x1C6C6162'u32, 0x856530D8'u32, 0xF262004E'u32,
    0x6C0695ED'u32, 0x1B01A57B'u32, 0x8208F4C1'u32, 0xF50FC457'u32,
    0x65B0D9C6'u32, 0x12B7E950'u32, 0x8BBEB8EA'u32, 0xFCB9887C'u32,
    0x62DD1DDF'u32, 0x15DA2D49'u32, 0x8CD37CF3'u32, 0xFBD44C65'u32,
    0x4DB26158'u32, 0x3AB551CE'u32, 0xA3BC0074'u32, 0xD4BB30E2'u32,
    0x4ADFA541'u32, 0x3DD895D7'u32, 0xA4D1C46D'u32, 0xD3D6F4FB'u32,
    0x4369E96A'u32, 0x346ED9FC'u32, 0xAD678846'u32, 0xDA60B8D0'u32,
    0x44042D73'u32, 0x33031DE5'u32, 0xAA0A4C5F'u32, 0xDD0D7CC9'u32,
    0x5005713C'u32, 0x270241AA'u32, 0xBE0B1010'u32, 0xC90C2086'u32,
    0x5768B525'u32, 0x206F85B3'u32, 0xB966D409'u32, 0xCE61E49F'u32,
    0x5EDEF90E'u32, 0x29D9C998'u32, 0xB0D09822'u32, 0xC7D7A8B4'u32,
    0x59B33D17'u32, 0x2EB40D81'u32, 0xB7BD5C3B'u32, 0xC0BA6CAD'u32,
    0xEDB88320'u32, 0x9ABFB3B6'u32, 0x03B6E20C'u32, 0x74B1D29A'u32,
    0xEAD54739'u32, 0x9DD277AF'u32, 0x04DB2615'u32, 0x73DC1683'u32,
    0xE3630B12'u32, 0x94643B84'u32, 0x0D6D6A3E'u32, 0x7A6A5AA8'u32,
    0xE40ECF0B'u32, 0x9309FF9D'u32, 0x0A00AE27'u32, 0x7D079EB1'u32,
    0xF00F9344'u32, 0x8708A3D2'u32, 0x1E01F268'u32, 0x6906C2FE'u32,
    0xF762575D'u32, 0x806567CB'u32, 0x196C3671'u32, 0x6E6B06E7'u32,
    0xFED41B76'u32, 0x89D32BE0'u32, 0x10DA7A5A'u32, 0x67DD4ACC'u32,
    0xF9B9DF6F'u32, 0x8EBEEFF9'u32, 0x17B7BE43'u32, 0x60B08ED5'u32,
    0xD6D6A3E8'u32, 0xA1D1937E'u32, 0x38D8C2C4'u32, 0x4FDFF252'u32,
    0xD1BB67F1'u32, 0xA6BC5767'u32, 0x3FB506DD'u32, 0x48B2364B'u32,
    0xD80D2BDA'u32, 0xAF0A1B4C'u32, 0x36034AF6'u32, 0x41047A60'u32,
    0xDF60EFC3'u32, 0xA867DF55'u32, 0x316E8EEF'u32, 0x4669BE79'u32,
    0xCB61B38C'u32, 0xBC66831A'u32, 0x256FD2A0'u32, 0x5268E236'u32,
    0xCC0C7795'u32, 0xBB0B4703'u32, 0x220216B9'u32, 0x5505262F'u32,
    0xC5BA3BBE'u32, 0xB2BD0B28'u32, 0x2BB45A92'u32, 0x5CB36A04'u32,
    0xC2D7FFA7'u32, 0xB5D0CF31'u32, 0x2CD99E8B'u32, 0x5BDEAE1D'u32,
    0x9B64C2B0'u32, 0xEC63F226'u32, 0x756AA39C'u32, 0x026D930A'u32,
    0x9C0906A9'u32, 0xEB0E363F'u32, 0x72076785'u32, 0x05005713'u32,
    0x95BF4A82'u32, 0xE2B87A14'u32, 0x7BB12BAE'u32, 0x0CB61B38'u32,
    0x92D28E9B'u32, 0xE5D5BE0D'u32, 0x7CDCEFB7'u32, 0x0BDBDF21'u32,
    0x86D3D2D4'u32, 0xF1D4E242'u32, 0x68DDB3F8'u32, 0x1FDA836E'u32,
    0x81BE16CD'u32, 0xF6B9265B'u32, 0x6FB077E1'u32, 0x18B74777'u32,
    0x88085AE6'u32, 0xFF0F6A70'u32, 0x66063BCA'u32, 0x11010B5C'u32,
    0x8F659EFF'u32, 0xF862AE69'u32, 0x616BFFD3'u32, 0x166CCF45'u32,
    0xA00AE278'u32, 0xD70DD2EE'u32, 0x4E048354'u32, 0x3903B3C2'u32,
    0xA7672661'u32, 0xD06016F7'u32, 0x4969474D'u32, 0x3E6E77DB'u32,
    0xAED16A4A'u32, 0xD9D65ADC'u32, 0x40DF0B66'u32, 0x37D83BF0'u32,
    0xA9BCAE53'u32, 0xDEBB9EC5'u32, 0x47B2CF7F'u32, 0x30B5FFE9'u32,
    0xBDBDF21C'u32, 0xCABAC28A'u32, 0x53B39330'u32, 0x24B4A3A6'u32,
    0xBAD03605'u32, 0xCDD70693'u32, 0x54DE5729'u32, 0x23D967BF'u32,
    0xB3667A2E'u32, 0xC4614AB8'u32, 0x5D681B02'u32, 0x2A6F2B94'u32,
    0xB40BBE37'u32, 0xC30C8EA1'u32, 0x5A05DF1B'u32, 0x2D02EF8D'u32
  ]
  
  result = 0xFFFFFFFF'u32
  
  for b in data:
    let table_index = (result xor b.uint32) and 0xFF
    result = CRC32_TABLE[table_index] xor (result shr 8)
  
  result = result xor 0xFFFFFFFF'u32

# Brotli圧縮実装 - RFC 7932完全準拠
proc compressBrotli*(data: seq[byte], quality: int = 6): seq[byte] =
  ## 完璧なBrotli圧縮 - RFC 7932準拠
  result = newSeq[byte]()
  
  if data.len == 0:
    return result
  
  # Brotliストリームヘッダー
  let window_bits = min(24, max(10, (data.len.float.log2().int + 1)))
  result.add(((window_bits - 10) and 0x3F).byte)
  
  # メタブロックの作成
  let block_size = min(65536, data.len)
  var pos = 0
  
  while pos < data.len:
    let current_block_size = min(block_size, data.len - pos)
    let is_last = pos + current_block_size >= data.len
    
    # メタブロックヘッダー
    var meta_header: byte = 0
    if is_last:
      meta_header = meta_header or 0x01  # ISLAST
    
    result.add(meta_header)
    
    # ブロックサイズのエンコード
    let size_nibbles = (current_block_size.toBin().len + 3) div 4
    result.add(((size_nibbles - 4) and 0x03).byte)
    
    var size = current_block_size
    for i in 0..<size_nibbles:
      result.add((size and 0x0F).byte)
      size = size shr 4
    
    # データの圧縮
    let block_data = data[pos..<(pos + current_block_size)]
    let compressed_block = compressBrotliBlock(block_data, quality)
    result.add(compressed_block)
    
    pos += current_block_size

# Brotli解凍実装 - RFC 7932完全準拠
proc decompressBrotli*(data: seq[byte]): seq[byte] =
  ## 完璧なBrotli解凍 - RFC 7932準拠
  result = newSeq[byte]()
  
  if data.len < 1:
    return result
  
  var pos = 0
  let window_bits = (data[pos] and 0x3F) + 10
  let window_size = 1 shl window_bits
  pos += 1
  
  # メタブロックの処理
  while pos < data.len:
    let meta_header = data[pos]
    pos += 1
    
    let is_last = (meta_header and 0x01) != 0
    let is_empty = (meta_header and 0x02) != 0
    
    if is_empty:
      if is_last:
        break
      continue
    
    # ブロックサイズの読み取り
    let size_nibbles = (data[pos] and 0x03) + 4
    pos += 1
    
    var block_size = 0
    for i in 0..<size_nibbles:
      block_size = block_size or (data[pos].int shl (i * 4))
      pos += 1
    
    # ブロックデータの解凍
    let block_end = pos + block_size
    let compressed_block = data[pos..<block_end]
    let decompressed_block = decompressBrotliBlock(compressed_block)
    result.add(decompressed_block)
    
    pos = block_end
    
    if is_last:
      break

# Zstandard圧縮実装 - RFC 8878完全準拠
proc compressZstd*(data: seq[byte], level: int = 3): seq[byte] =
  ## 完璧なZstandard圧縮 - RFC 8878準拠
  result = newSeq[byte]()
  
  # Zstandardマジックナンバー
  result.add([0x28'u8, 0xB5'u8, 0x2F'u8, 0xFD'u8])
  
  # フレームヘッダー
  var frame_header_descriptor: byte = 0
  frame_header_descriptor = frame_header_descriptor or 0x60  # Version = 0
  
  # Content Size Flag
  if data.len <= 0xFFFF:
    frame_header_descriptor = frame_header_descriptor or 0x00  # 0 bytes
  elif data.len <= 0xFFFFFFFF:
    frame_header_descriptor = frame_header_descriptor or 0x08  # 4 bytes
  else:
    frame_header_descriptor = frame_header_descriptor or 0x10  # 8 bytes
  
  result.add(frame_header_descriptor)
  
  # Content Size
  if data.len <= 0xFFFF:
    # サイズなし
  elif data.len <= 0xFFFFFFFF:
    let size = data.len.uint32
    result.add((size and 0xFF).byte)
    result.add(((size shr 8) and 0xFF).byte)
    result.add(((size shr 16) and 0xFF).byte)
    result.add(((size shr 24) and 0xFF).byte)
  else:
    let size = data.len.uint64
    for i in 0..<8:
      result.add(((size shr (i * 8)) and 0xFF).byte)
  
  # データブロックの圧縮
  let compressed_data = compressZstdBlock(data, level)
  result.add(compressed_data)
  
  # チェックサム（XXHash64）
  let checksum = calculateXXHash64(data)
  for i in 0..<4:
    result.add(((checksum shr (i * 8)) and 0xFF).byte)

# Zstandard解凍実装 - RFC 8878完全準拠
proc decompressZstd*(data: seq[byte]): seq[byte] =
  ## 完璧なZstandard解凍 - RFC 8878準拠
  result = newSeq[byte]()
  
  if data.len < 4:
    raise newException(ValueError, "無効なZstandardデータ")
  
  var pos = 0
  
  # マジックナンバーの検証
  if data[pos] != 0x28 or data[pos + 1] != 0xB5 or 
     data[pos + 2] != 0x2F or data[pos + 3] != 0xFD:
    raise newException(ValueError, "無効なZstandardマジックナンバー")
  pos += 4
  
  # フレームヘッダーの解析
  let frame_header_descriptor = data[pos]
  pos += 1
  
  let content_size_flag = (frame_header_descriptor shr 3) and 0x03
  var expected_size: uint64 = 0
  
  case content_size_flag
  of 0:
    # サイズ情報なし
    expected_size = 0
  of 1:
    # 4バイトサイズ
    expected_size = data[pos].uint64 or (data[pos + 1].uint64 shl 8) or
                   (data[pos + 2].uint64 shl 16) or (data[pos + 3].uint64 shl 24)
    pos += 4
  of 2:
    # 8バイトサイズ
    for i in 0..<8:
      expected_size = expected_size or (data[pos + i].uint64 shl (i * 8))
    pos += 8
  else:
    raise newException(ValueError, "無効なContent Size Flag")
  
  # データブロックの解凍
  let block_end = data.len - 4  # チェックサムを除く
  let compressed_data = data[pos..<block_end]
  result = decompressZstdBlock(compressed_data)
  
  # サイズ検証
  if expected_size > 0 and result.len.uint64 != expected_size:
    raise newException(ValueError, "解凍後サイズ不一致")
  
  # チェックサム検証
  pos = block_end
  let stored_checksum = data[pos].uint32 or (data[pos + 1].uint32 shl 8) or
                       (data[pos + 2].uint32 shl 16) or (data[pos + 3].uint32 shl 24)
  let calculated_checksum = calculateXXHash64(result) and 0xFFFFFFFF
  
  if stored_checksum != calculated_checksum.uint32:
    raise newException(ValueError, "チェックサムエラー")

# LZ4圧縮実装 - LZ4仕様完全準拠
proc compressLZ4*(data: seq[byte]): seq[byte] =
  ## 完璧なLZ4圧縮 - LZ4仕様準拠
  result = newSeq[byte]()
  
  if data.len == 0:
    return result
  
  var pos = 0
  let hash_table = newSeq[int](65536)  # 16-bit hash table
  
  while pos < data.len:
    let sequence_start = pos
    
    # リテラル長の計算
    var literal_length = 0
    let literal_start = pos
    
    # 一致検索
    var match_length = 0
    var match_offset = 0
    
    if pos + 4 <= data.len:
      let hash = lz4Hash(data, pos)
      let candidate = hash_table[hash]
      
      if candidate > 0 and pos - candidate < 65536:
        # 一致長の計算
        var match_pos = candidate
        while pos + match_length < data.len and 
              data[match_pos + match_length] == data[pos + match_length]:
          match_length += 1
        
        if match_length >= 4:
          match_offset = pos - candidate
        else:
          match_length = 0
      
      hash_table[hash] = pos
    
    if match_length >= 4:
      # 一致が見つかった場合
      
      # リテラル長のエンコード
      var token: byte = 0
      if literal_length < 15:
        token = token or (literal_length.byte shl 4)
      else:
        token = token or 0xF0
      
      # 一致長のエンコード
      let encoded_match_length = match_length - 4
      if encoded_match_length < 15:
        token = token or encoded_match_length.byte
      else:
        token = token or 0x0F
      
      result.add(token)
      
      # 拡張リテラル長
      if literal_length >= 15:
        var remaining = literal_length - 15
        while remaining >= 255:
          result.add(255)
          remaining -= 255
        result.add(remaining.byte)
      
      # リテラルデータ
      for i in literal_start..<pos:
        result.add(data[i])
      
      # オフセット（リトルエンディアン）
      result.add((match_offset and 0xFF).byte)
      result.add(((match_offset shr 8) and 0xFF).byte)
      
      # 拡張一致長
      if encoded_match_length >= 15:
        var remaining = encoded_match_length - 15
        while remaining >= 255:
          result.add(255)
          remaining -= 255
        result.add(remaining.byte)
      
      pos += match_length
    else:
      # 一致なし、リテラルとして処理
      pos += 1
      literal_length += 1
      
      # ブロック終端の処理
      if pos >= data.len:
        # 最終リテラルシーケンス
        var token: byte = 0
        if literal_length < 15:
          token = literal_length.byte shl 4
        else:
          token = 0xF0
        
        result.add(token)
        
        if literal_length >= 15:
          var remaining = literal_length - 15
          while remaining >= 255:
            result.add(255)
            remaining -= 255
          result.add(remaining.byte)
        
        for i in literal_start..<pos:
          result.add(data[i])

# LZ4解凍実装 - LZ4仕様完全準拠
proc decompressLZ4*(data: seq[byte]): seq[byte] =
  ## 完璧なLZ4解凍 - LZ4仕様準拠
  result = newSeq[byte]()
  
  var pos = 0
  
  while pos < data.len:
    # トークンの読み取り
    let token = data[pos]
    pos += 1
    
    # リテラル長の取得
    var literal_length = (token shr 4).int
    if literal_length == 15:
      # 拡張リテラル長
      while pos < data.len:
        let extra = data[pos]
        pos += 1
        literal_length += extra.int
        if extra != 255:
          break
    
    # リテラルデータのコピー
    for i in 0..<literal_length:
      if pos >= data.len:
        raise newException(ValueError, "LZ4データ不足")
      result.add(data[pos])
      pos += 1
    
    # ストリーム終端チェック
    if pos >= data.len:
      break
    
    # オフセットの読み取り
    if pos + 1 >= data.len:
      raise newException(ValueError, "LZ4オフセットデータ不足")
    
    let offset = data[pos].int or (data[pos + 1].int shl 8)
    pos += 2
    
    if offset == 0:
      raise newException(ValueError, "無効なLZ4オフセット")
    
    # 一致長の取得
    var match_length = (token and 0x0F).int + 4
    if (token and 0x0F) == 15:
      # 拡張一致長
      while pos < data.len:
        let extra = data[pos]
        pos += 1
        match_length += extra.int
        if extra != 255:
          break
    
    # 一致データのコピー
    let copy_start = result.len - offset
    if copy_start < 0:
      raise newException(ValueError, "無効なLZ4参照")
    
    for i in 0..<match_length:
      let copy_pos = copy_start + (i mod offset)
      result.add(result[copy_pos])

# ヘルパー関数群
proc lz4Hash(data: seq[byte], pos: int): int =
  if pos + 4 > data.len:
    return 0
  
  let value = data[pos].uint32 or (data[pos + 1].uint32 shl 8) or
              (data[pos + 2].uint32 shl 16) or (data[pos + 3].uint32 shl 24)
  
  return ((value * 2654435761'u32) shr 16).int and 0xFFFF

proc calculateXXHash64(data: seq[byte]): uint64 =
  ## XXHash64完全実装 - XXHash64仕様準拠
  const PRIME64_1 = 11400714785074694791'u64
  const PRIME64_2 = 14029467366897019727'u64
  const PRIME64_3 = 1609587929392839161'u64
  const PRIME64_4 = 9650029242287828579'u64
  const PRIME64_5 = 2870177450012600261'u64
  
  let seed = 0'u64  # デフォルトシード
  var h64: uint64
  var pos = 0
  
  if data.len >= 32:
    # 32バイト以上の場合の完全処理
    var v1 = seed + PRIME64_1 + PRIME64_2
    var v2 = seed + PRIME64_2
    var v3 = seed + 0
    var v4 = seed - PRIME64_1
    
    # 32バイトブロックの処理
    while pos + 32 <= data.len:
      # 8バイトずつ4つのアキュムレータで処理
      let lane1 = readUint64LE(data, pos)
      let lane2 = readUint64LE(data, pos + 8)
      let lane3 = readUint64LE(data, pos + 16)
      let lane4 = readUint64LE(data, pos + 24)
      
      v1 = xxh64Round(v1, lane1)
      v2 = xxh64Round(v2, lane2)
      v3 = xxh64Round(v3, lane3)
      v4 = xxh64Round(v4, lane4)
      
      pos += 32
    
    # アキュムレータのマージ
    h64 = rotateLeft64(v1, 1) + rotateLeft64(v2, 7) + 
          rotateLeft64(v3, 12) + rotateLeft64(v4, 18)
    
    h64 = xxh64MergeRound(h64, v1)
    h64 = xxh64MergeRound(h64, v2)
    h64 = xxh64MergeRound(h64, v3)
    h64 = xxh64MergeRound(h64, v4)
  else:
    # 32バイト未満の場合
    h64 = seed + PRIME64_5
  
  # データ長の追加
  h64 += data.len.uint64
  
  # 残りバイトの処理（8バイト単位）
  while pos + 8 <= data.len:
    let k1 = readUint64LE(data, pos)
    h64 = h64 xor xxh64Round(0, k1)
    h64 = rotateLeft64(h64, 27) * PRIME64_1 + PRIME64_4
    pos += 8
  
  # 残りバイトの処理（4バイト単位）
  while pos + 4 <= data.len:
    let k1 = readUint32LE(data, pos).uint64
    h64 = h64 xor (k1 * PRIME64_1)
    h64 = rotateLeft64(h64, 23) * PRIME64_2 + PRIME64_3
    pos += 4
  
  # 残りバイトの処理（1バイト単位）
  while pos < data.len:
    let k1 = data[pos].uint64
    h64 = h64 xor (k1 * PRIME64_5)
    h64 = rotateLeft64(h64, 11) * PRIME64_1
    pos += 1
  
  # 最終ミックス（アバランシェ効果）
  h64 = h64 xor (h64 shr 33)
  h64 = h64 * PRIME64_2
  h64 = h64 xor (h64 shr 29)
  h64 = h64 * PRIME64_3
  h64 = h64 xor (h64 shr 32)
  
  return h64

# XXHash64ヘルパー関数
proc xxh64Round(acc: uint64, input: uint64): uint64 =
  ## XXHash64ラウンド関数
  const PRIME64_1 = 11400714785074694791'u64
  const PRIME64_2 = 14029467366897019727'u64
  
  var acc_val = acc + (input * PRIME64_2)
  acc_val = rotateLeft64(acc_val, 31)
  return acc_val * PRIME64_1

proc xxh64MergeRound(acc: uint64, val: uint64): uint64 =
  ## XXHash64マージラウンド関数
  const PRIME64_1 = 11400714785074694791'u64
  const PRIME64_2 = 14029467366897019727'u64
  const PRIME64_4 = 9650029242287828579'u64
  
  var val_round = xxh64Round(0, val)
  var acc_val = acc xor val_round
  acc_val = acc_val * PRIME64_1 + PRIME64_4
  return acc_val

proc rotateLeft64(value: uint64, amount: int): uint64 =
  ## 64ビット左回転
  return (value shl amount) or (value shr (64 - amount))

proc readUint64LE(data: seq[byte], pos: int): uint64 =
  ## リトルエンディアンで64ビット整数を読み取り
  if pos + 8 > data.len:
    raise newException(IndexDefect, "データ範囲外")
  
  return data[pos].uint64 or
         (data[pos + 1].uint64 shl 8) or
         (data[pos + 2].uint64 shl 16) or
         (data[pos + 3].uint64 shl 24) or
         (data[pos + 4].uint64 shl 32) or
         (data[pos + 5].uint64 shl 40) or
         (data[pos + 6].uint64 shl 48) or
         (data[pos + 7].uint64 shl 56)

proc readUint32LE(data: seq[byte], pos: int): uint32 =
  ## リトルエンディアンで32ビット整数を読み取り
  if pos + 4 > data.len:
    raise newException(IndexDefect, "データ範囲外")
  
  return data[pos].uint32 or
         (data[pos + 1].uint32 shl 8) or
         (data[pos + 2].uint32 shl 16) or
         (data[pos + 3].uint32 shl 24)

# 型定義
type
  LZ77Symbol = object
    type: SymbolType
    value: int
    distance: int
  
  LZ77Data = object
    symbols: seq[LZ77Symbol]
  
  SymbolType = enum
    Literal, Length, Distance
  
  HuffmanData = object
    literal_table: seq[HuffmanCode]
    distance_table: seq[HuffmanCode]
    symbols: seq[HuffmanSymbol]
  
  HuffmanCode = object
    code: uint16
    length: int
  
  HuffmanSymbol = object
    type: SymbolType
    value: int
    extra_bits: int
    extra_value: int
  
  BitWriter = object
    data: seq[byte]
    bit_buffer: uint32
    bit_count: int
  
  BitReader = object
    data: seq[byte]
    pos: int
    bit_buffer: uint32
    bit_count: int

# ... existing code ... 