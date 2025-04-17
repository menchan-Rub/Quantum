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
  PriorityQueue[T] = object
    queues: array[AsyncCompressionPriority, Deque[T]]
    size: int

proc newPriorityQueue[T](): PriorityQueue[T] =
  result.size = 0
  for i in AsyncCompressionPriority:
    result.queues[i] = initDeque[T]()

proc enqueue[T](queue: var PriorityQueue[T], item: T, priority: AsyncCompressionPriority) =
  queue.queues[priority].addLast(item)
  inc queue.size

proc dequeue[T](queue: var PriorityQueue[T]): Option[T] =
  if queue.size == 0:
    return none(T)
  
  # 高優先度から順に取り出し
  for priority in countdown(acpCritical, acpLow):
    if queue.queues[priority].len > 0:
      dec queue.size
      return some(queue.queues[priority].popFirst())
  
  return none(T)

proc peek[T](queue: var PriorityQueue[T]): Option[T] =
  if queue.size == 0:
    return none(T)
  
  # 高優先度から順に確認
  for priority in countdown(acpCritical, acpLow):
    if queue.queues[priority].len > 0:
      return some(queue.queues[priority][0])
  
  return none(T)

proc len[T](queue: PriorityQueue[T]): int =
  return queue.size

proc contains[T](queue: PriorityQueue[T], predicate: proc(item: T): bool): bool =
  for priority in AsyncCompressionPriority:
    for item in queue.queues[priority]:
      if predicate(item):
        return true
  return false

proc find[T](queue: PriorityQueue[T], predicate: proc(item: T): bool): Option[T] =
  for priority in AsyncCompressionPriority:
    for item in queue.queues[priority]:
      if predicate(item):
        return some(item)
  return none(T)

proc remove[T](queue: var PriorityQueue[T], predicate: proc(item: T): bool): bool =
  for priority in AsyncCompressionPriority:
    var i = 0
    while i < queue.queues[priority].len:
      if predicate(queue.queues[priority][i]):
        queue.queues[priority].delete(i)
        dec queue.size
        return true
      inc i
  return false

# 共有キューの実装
type
  SharedQueue[T] = ref object
    queue: Deque[T]
    lock: Lock
    cond: Cond

proc newSharedQueue[T](): SharedQueue[T] =
  new(result)
  result.queue = initDeque[T]()
  initLock(result.lock)
  initCond(result.cond)

proc enqueue[T](queue: SharedQueue[T], item: T) =
  acquire(queue.lock)
  queue.queue.addLast(item)
  signal(queue.cond)
  release(queue.lock)

proc dequeue[T](queue: SharedQueue[T], timeoutMs: int = -1): Option[T] =
  acquire(queue.lock)
  
  if timeoutMs > 0:
    var timeoutNs = timeoutMs * 1_000_000
    while queue.queue.len == 0:
      if not wait(queue.cond, queue.lock, timeoutNs):
        release(queue.lock)
        return none(T)
  else:
    while queue.queue.len == 0:
      wait(queue.cond, queue.lock)
  
  let item = queue.queue.popFirst()
  release(queue.lock)
  return some(item)

proc tryDequeue[T](queue: SharedQueue[T]): Option[T] =
  try:
    acquire(queue.lock)
    if queue.queue.len == 0:
      release(queue.lock)
      return none(T)
    
    let item = queue.queue.popFirst()
    release(queue.lock)
    return some(item)
  except:
    if queue.lock.locked:
      release(queue.lock)
    return none(T)

proc size[T](queue: SharedQueue[T]): int =
  acquire(queue.lock)
  let size = queue.queue.len
  release(queue.lock)
  return size

# デフォルト圧縮オプション
proc defaultAsyncCompressionOptions*(): AsyncCompressionOptions =
  result = AsyncCompressionOptions(
    mode: acmThreaded,
    priority: acpNormal,
    useCache: true,
    chunkSize: DEFAULT_CHUNK_SIZE,
    algorithmHint: cahNone,
    compressionLevel: sclDefault,
    timeoutMs: TASK_TIMEOUT_MS,
    algorithm: ""
  )

# 非同期圧縮マネージャーの作成
proc newAsyncCompressionManager*(
  threadCount: int = DEFAULT_THREAD_COUNT,
  maxQueueSize: int = DEFAULT_QUEUE_SIZE,
  chunkSize: int = DEFAULT_CHUNK_SIZE,
  useCache: bool = true
): AsyncCompressionManager =
  var actualThreadCount = threadCount
  if actualThreadCount <= 0:
    # CPUコア数に基づいてスレッド数を決定
    actualThreadCount = max(1, countProcessors() - 1)
  
  result = AsyncCompressionManager(
    compressionTasks: newTable[string, CompressionTask](),
    decompressionTasks: newTable[string, DecompressionTask](),
    compressionQueue: newPriorityQueue[CompressionTask](),
    decompressionQueue: newPriorityQueue[DecompressionTask](),
    messageQueue: newSharedQueue[ThreadMessage](),
    workers: @[],
    threadCount: actualThreadCount,
    maxQueueSize: maxQueueSize,
    chunkSize: chunkSize,
    flushPending: false,
    lastFlushCheck: epochTime(),
    isRunning: false,
    stats: AsyncCompressionStats()
  )
  
  # キャッシュの作成（使用する場合）
  if useCache:
    result.cache = newCompressionCache(
      policy = ccpHybrid,
      mode = ccmPredictive,
      maxCacheSize = DEFAULT_CACHE_SIZE_BYTES,
      useSimd = isSimdSupported()
    )
  
  # 処理ロックの初期化
  initLock(result.processingLock)

# ワーカースレッド処理
proc workerThreadProc(threadId: int) {.thread.} =
  # スレッドローカル変数の初期化
  var 
    simdOptions = newSimdCompressionOptions()
    compressionContext = newCompressionContext()
    decompressionContext = newDecompressionContext()
    message: ThreadMessage
    taskCompleted = false
    lastActivityTime = epochTime()
    currentTaskId = ""
    processingData: string
    resultData: string
    errorMessage: string
    compressionStats: CompressionStats
  
  # SIMDサポートの確認と最適化
  if isSimdSupported():
    simdOptions.enableHardwareAcceleration = true
    simdOptions.preferredInstructionSet = detectBestSimdInstructionSet()
  
  debug(fmt"ワーカースレッド {threadId} が開始しました。SIMD対応: {isSimdSupported()}")
  
  while true:
    try:
      # メッセージキューからタスクを取得
      if globalManager.messageQueue.tryRecv(message):
        lastActivityTime = epochTime()
        
        case message.kind
        of tmkShutdown:
          # シャットダウン命令を受け取った場合
          debug(fmt"ワーカースレッド {threadId} がシャットダウン命令を受信しました")
          break
          
        of tmkCompression:
          # 圧縮タスクの処理
          currentTaskId = message.taskId
          let task = globalManager.compressionTasks[currentTaskId]
          
          # ワーカーステータスの更新
          withLock(globalManager.processingLock):
            for worker in globalManager.workers.mitems:
              if worker.id == threadId:
                worker.state = tsProcessing
                worker.currentTaskId = currentTaskId
                worker.startTime = epochTime()
          
          debug(fmt"ワーカー {threadId}: 圧縮タスク {currentTaskId} を開始 (アルゴリズム: {task.options.algorithm})")
          
          # 圧縮処理の実行
          processingData = task.data
          let algorithm = if task.options.algorithm == "": detectBestCompressionAlgorithm(processingData) else: task.options.algorithm
          
          let startTime = epochTime()
          try:
            resultData = compressionContext.compress(
              processingData, 
              algorithm, 
              task.options.compressionLevel,
              simdOptions
            )
            taskCompleted = true
            
            # 統計情報の更新
            compressionStats = CompressionStats(
              originalSize: processingData.len,
              compressedSize: resultData.len,
              compressionRatio: 1.0 - (resultData.len.float / max(1.0, processingData.len.float)),
              processingTimeMs: (epochTime() - startTime) * 1000.0,
              algorithm: algorithm
            )
            
          except Exception as e:
            errorMessage = e.msg
            taskCompleted = false
            error(fmt"圧縮タスク {currentTaskId} でエラー発生: {errorMessage}")
          
          # 結果の送信
          withLock(globalManager.processingLock):
            if taskCompleted:
              task.future.complete(resultData)
              # キャッシュに結果を保存（有効な場合）
              if task.options.useCache and globalManager.cache != nil:
                globalManager.cache.store(processingData, resultData, algorithm)
              # 統計情報の更新
              globalManager.stats.totalCompressedBytes += processingData.len
              globalManager.stats.totalOutputBytes += resultData.len
              globalManager.stats.compressionTasks += 1
            else:
              task.future.fail(newException(CompressionError, errorMessage))
              globalManager.stats.failedTasks += 1
            
            # ワーカーステータスの更新
            for worker in globalManager.workers.mitems:
              if worker.id == threadId:
                worker.state = tsIdle
                worker.currentTaskId = ""
          
        of tmkDecompression:
          # 解凍タスクの処理
          currentTaskId = message.taskId
          let task = globalManager.decompressionTasks[currentTaskId]
          
          # ワーカーステータスの更新
          withLock(globalManager.processingLock):
            for worker in globalManager.workers.mitems:
              if worker.id == threadId:
                worker.state = tsProcessing
                worker.currentTaskId = currentTaskId
                worker.startTime = epochTime()
          
          debug(fmt"ワーカー {threadId}: 解凍タスク {currentTaskId} を開始")
          
          # 解凍処理の実行
          processingData = task.data
          let startTime = epochTime()
          try:
            # 圧縮形式の自動検出
            let detectedAlgorithm = if task.options.algorithm == "": detectCompressionAlgorithm(processingData) else: task.options.algorithm
            
            resultData = decompressionContext.decompress(
              processingData,
              detectedAlgorithm,
              simdOptions
            )
            taskCompleted = true
            
          except Exception as e:
            errorMessage = e.msg
            taskCompleted = false
            error(fmt"解凍タスク {currentTaskId} でエラー発生: {errorMessage}")
          
          # 結果の送信
          withLock(globalManager.processingLock):
            if taskCompleted:
              task.future.complete(resultData)
              # キャッシュに結果を保存（有効な場合）
              if task.options.useCache and globalManager.cache != nil:
                globalManager.cache.storeDecompression(processingData, resultData)
              # 統計情報の更新
              globalManager.stats.totalDecompressedBytes += processingData.len
              globalManager.stats.totalOutputBytes += resultData.len
              globalManager.stats.decompressionTasks += 1
            else:
              task.future.fail(newException(DecompressionError, errorMessage))
              globalManager.stats.failedTasks += 1
            
            # ワーカーステータスの更新
            for worker in globalManager.workers.mitems:
              if worker.id == threadId:
                worker.state = tsIdle
                worker.currentTaskId = ""
        
        of tmkPrioritize:
          # タスクの優先度変更
          debug(fmt"ワーカー {threadId}: タスク {message.taskId} の優先度を変更")
          withLock(globalManager.processingLock):
            if message.taskId in globalManager.compressionTasks:
              globalManager.compressionTasks[message.taskId].options.priority = message.newPriority
            elif message.taskId in globalManager.decompressionTasks:
              globalManager.decompressionTasks[message.taskId].options.priority = message.newPriority
      
      # アイドル状態の場合、短いスリープ
      else:
        # 長時間アイドル状態の場合、リソース解放を検討
        if epochTime() - lastActivityTime > IDLE_RESOURCE_CLEANUP_THRESHOLD_SEC:
          compressionContext.releaseUnusedResources()
          decompressionContext.releaseUnusedResources()
          lastActivityTime = epochTime()
        
        sleep(WORKER_IDLE_SLEEP_MS)
    
    except Exception as e:
      # 予期しないエラーの処理
      error(fmt"ワーカースレッド {threadId} で予期しないエラー: {e.msg}")
      # 現在処理中のタスクがある場合は失敗として処理
      if currentTaskId != "":
        withLock(globalManager.processingLock):
          if currentTaskId in globalManager.compressionTasks:
            globalManager.compressionTasks[currentTaskId].future.fail(newException(CompressionError, e.msg))
          elif currentTaskId in globalManager.decompressionTasks:
            globalManager.decompressionTasks[currentTaskId].future.fail(newException(DecompressionError, e.msg))
          
          # ワーカーステータスの更新
          for worker in globalManager.workers.mitems:
            if worker.id == threadId:
              worker.state = tsIdle
              worker.currentTaskId = ""
          
          globalManager.stats.failedTasks += 1
      
      # エラー後の回復時間
      sleep(WORKER_ERROR_RECOVERY_MS)
  
  # スレッド終了時のクリーンアップ
  compressionContext.dispose()
  decompressionContext.dispose()
  debug(fmt"ワーカースレッド {threadId} が終了しました")

# 一意のタスクIDを生成
proc generateTaskId(): string =
  let timestamp = epochTime()
  let randVal = rand(high(int))
  result = $hash([timestamp, randVal])

# 非同期圧縮マネージャーの初期化と開始
proc start*(manager: AsyncCompressionManager) =
  ## 非同期圧縮マネージャーを初期化し、ワーカースレッドとタイマーを開始します
  if manager.isRunning:
    debug("マネージャーは既に実行中です")
    return
  
  debug("非同期圧縮マネージャーを開始します")
  manager.isRunning = true
  manager.startTime = epochTime()
  manager.lastStatsUpdate = manager.startTime
  
  # 統計情報の初期化
  manager.stats = CompressionStats(
    totalTasks: 0,
    completedTasks: 0,
    failedTasks: 0,
    canceledTasks: 0,
    totalBytesInput: 0,
    totalBytesOutput: 0,
    cacheHits: 0,
    cacheMisses: 0,
    avgCompressionRatio: 0.0,
    peakMemoryUsage: 0,
    avgTaskDuration: 0.0
  )
  
  # ロックの初期化
  manager.processingLock = createLock()
  manager.queueLock = createLock()
  
  # タスクキューの初期化
  manager.compressionTasks = initTable[string, CompressionTask]()
  manager.decompressionTasks = initTable[string, DecompressionTask]()
  manager.priorityQueue = initHeapQueue[PriorityTask]()
  
  # ワーカースレッドの作成
  debug(fmt"ワーカースレッドを {manager.threadCount} 個作成します")
  manager.workers = newSeq[WorkerThread](manager.threadCount)
  for i in 0..<manager.threadCount:
    manager.workers[i] = WorkerThread(
      id: i,
      state: tsIdle,
      currentTaskId: "",
      startTime: 0.0,
      totalTasksProcessed: 0,
      totalBytesProcessed: 0,
      lastActivityTime: epochTime()
    )
    createThread(manager.workers[i].thread, workerThreadProc, i)
  
  # フラッシュタイマーの開始
  proc flushProc() {.async.} =
    debug("フラッシュタイマーを開始します")
    while manager.isRunning:
      let now = epochTime()
      if now - manager.lastFlushCheck >= FLUSH_CHECK_INTERVAL_MS / 1000.0:
        manager.lastFlushCheck = now
        
        # タイムアウトしたタスクの確認と処理
        withLock(manager.processingLock):
          var timeoutTasks: seq[string] = @[]
          
          # 圧縮タスクのタイムアウトチェック
          for taskId, task in manager.compressionTasks:
            if task.options.timeout > 0 and now - task.startTime > task.options.timeout:
              timeoutTasks.add(taskId)
              task.future.fail(newException(TimeoutError, fmt"タスク {taskId} がタイムアウトしました"))
              manager.stats.failedTasks += 1
          
          # 解凍タスクのタイムアウトチェック
          for taskId, task in manager.decompressionTasks:
            if task.options.timeout > 0 and now - task.startTime > task.options.timeout:
              timeoutTasks.add(taskId)
              task.future.fail(newException(TimeoutError, fmt"タスク {taskId} がタイムアウトしました"))
              manager.stats.failedTasks += 1
          
          # タイムアウトしたタスクの削除
          for taskId in timeoutTasks:
            debug(fmt"タスク {taskId} をタイムアウトにより削除します")
            if taskId in manager.compressionTasks:
              manager.compressionTasks.del(taskId)
            elif taskId in manager.decompressionTasks:
              manager.decompressionTasks.del(taskId)
            
            # ワーカーステータスの更新
            for worker in manager.workers.mitems:
              if worker.currentTaskId == taskId:
                worker.state = tsIdle
                worker.currentTaskId = ""
        
        # 統計情報の更新
        if now - manager.lastStatsUpdate >= STATS_UPDATE_INTERVAL_SEC:
          manager.updateStats()
          manager.lastStatsUpdate = now
        
        # キャッシュのメンテナンス
        if manager.cache != nil and now - manager.lastCacheMaintenance >= CACHE_MAINTENANCE_INTERVAL_SEC:
          manager.cache.performMaintenance()
          manager.lastCacheMaintenance = now
      
      await sleepAsync(FLUSH_CHECK_INTERVAL_MS)
  
  # リソースモニタリングタイマーの開始
  proc resourceMonitorProc() {.async.} =
    debug("リソースモニタリングタイマーを開始します")
    while manager.isRunning:
      # システムリソースの監視
      let memUsage = getSystemMemoryUsage()
      let cpuUsage = getSystemCpuUsage()
      
      # リソース使用量に基づいてスレッド数を動的に調整
      if manager.dynamicThreading:
        if cpuUsage > HIGH_CPU_THRESHOLD and manager.threadCount < manager.maxThreadCount:
          # CPUの使用率が高い場合、スレッドを追加
          manager.addWorkerThread()
        elif cpuUsage < LOW_CPU_THRESHOLD and manager.threadCount > manager.minThreadCount:
          # CPUの使用率が低い場合、スレッドを削減
          manager.removeWorkerThread()
      
      # メモリ使用量が高い場合、キャッシュをクリア
      if memUsage > HIGH_MEMORY_THRESHOLD and manager.cache != nil:
        debug("メモリ使用量が高いため、キャッシュをクリアします")
        manager.cache.clear()
      
      # 統計情報の更新
      if memUsage > manager.stats.peakMemoryUsage:
        manager.stats.peakMemoryUsage = memUsage
      
      await sleepAsync(RESOURCE_MONITOR_INTERVAL_MS)
  
  # タイマーの開始
  manager.flushFuture = flushProc()
  manager.resourceMonitorFuture = resourceMonitorProc()
  
  debug("非同期圧縮マネージャーが正常に開始されました")

# 非同期圧縮の実行
proc compressAsync*(
  manager: AsyncCompressionManager, 
  data: string,
  options: AsyncCompressionOptions = defaultAsyncCompressionOptions()
): Future[string] =
  ## データを非同期に圧縮
  var retFuture = newFuture[string]("compressAsync")
  
  # キャッシュのチェック
  if options.useCache and manager.cache != nil:
    let algorithm = 
      if options.algorithm.len > 0: options.algorithm
      else: "auto"
    
    # キャッシュキーの生成とチェック
    let cacheKey = generateCacheKey(data, algorithm)
    let cachedEntry = manager.cache.getCacheEntryInfo(cacheKey)
    
    if cachedEntry.isSome:
      # キャッシュヒット - すぐに結果を返す
      let compressedData = manager.cache.compress(data, algorithm, options.algorithmHint)
      retFuture.complete(compressedData)
      return retFuture
  
  # 小さなデータの場合は同期処理
  if data.len <= 4096 and options.mode != acmAsync and options.mode != acmThreaded:
    try:
      let compressedData = 
        if isSimdSupported():
          let simdOptions = newSimdCompressionOptions(level: options.compressionLevel)
          compressSimd(data, simdOptions)
        else:
          # シンプルな圧縮（SIMD非対応環境用）
          data # プレースホルダ
      
      # キャッシュに追加（使用する場合）
      if options.useCache and manager.cache != nil:
        discard manager.cache.compress(data, options.algorithm, options.algorithmHint)
      
      retFuture.complete(compressedData)
    except Exception as e:
      retFuture.fail(newException(IOError, "圧縮に失敗しました: " & e.msg))
    
    return retFuture
  
  # モードに応じた処理
  case options.mode:
    of acmSync:
      # 同期処理（サイズがしきい値を超えても同期で処理）
      try:
        let startTime = epochTime()
        
        let compressedData = 
          if isSimdSupported():
            let simdOptions = newSimdCompressionOptions(level: options.compressionLevel)
            compressSimd(data, simdOptions)
          else:
            # シンプルな圧縮（SIMD非対応環境用）
            data # プレースホルダ
        
        let endTime = epochTime()
        
        # 統計情報の更新
        acquire(manager.processingLock)
        manager.stats.totalCompressedBytes += compressedData.len
        manager.stats.totalUncompressedBytes += data.len
        inc manager.stats.totalCompressTasks
        
        let elapsed = endTime - startTime
        let totalTasks = manager.stats.totalCompressTasks
        manager.stats.averageCompressionTime = 
          (manager.stats.averageCompressionTime * (totalTasks - 1) + elapsed) / totalTasks.float
        
        if data.len > 0:
          manager.stats.compressionRatio = 
            (manager.stats.compressionRatio * (totalTasks - 1) + 
            (compressedData.len.float / data.len.float)) / totalTasks.float
        
        release(manager.processingLock)
        
        # キャッシュに追加（使用する場合）
        if options.useCache and manager.cache != nil:
          discard manager.cache.compress(data, options.algorithm, options.algorithmHint)
        
        retFuture.complete(compressedData)
      except Exception as e:
        acquire(manager.processingLock)
        inc manager.stats.failedTasks
        release(manager.processingLock)
        
        retFuture.fail(newException(IOError, "圧縮に失敗しました: " & e.msg))
    
    of acmAsync, acmThreaded, acmHybrid:
      # 非同期処理またはスレッド処理
      let taskId = generateTaskId()
      let task = CompressionTask(
        id: taskId,
        data: data,
        priority: options.priority,
        options: options,
        status: csQueued,
        createdAt: epochTime(),
        future: retFuture
      )
      
      # タスクをキューに追加
      acquire(manager.processingLock)
      
      # キューサイズのチェック
      if manager.compressionQueue.len >= manager.maxQueueSize:
        release(manager.processingLock)
        retFuture.fail(newException(IOError, "圧縮キューがいっぱいです"))
        return retFuture
      
      manager.compressionTasks[taskId] = task
      manager.compressionQueue.enqueue(task, options.priority)
      
      # 統計情報の更新
      manager.stats.peakQueueSize = max(manager.stats.peakQueueSize, 
                                      manager.compressionQueue.len + manager.decompressionQueue.len)
      
      release(manager.processingLock)
      
      # ワーカースレッドにタスクを送信
      let msg = ThreadMessage(
        msgType: mtCompressTask,
        taskId: taskId,
        data: data,
        options: options
      )
      manager.messageQueue.enqueue(msg)
  
  return retFuture

# 非同期解凍の実行
proc decompressAsync*(
  manager: AsyncCompressionManager, 
  compressedData: string,
  options: AsyncCompressionOptions = defaultAsyncCompressionOptions()
): Future[string] =
  ## データを非同期に解凍
  var retFuture = newFuture[string]("decompressAsync")
  
  # キャッシュのチェック
  if options.useCache and manager.cache != nil:
    let cachedData = manager.cache.decompress(compressedData)
    if cachedData.isSome:
      # キャッシュヒット - すぐに結果を返す
      retFuture.complete(cachedData.get)
      return retFuture
  
  # 小さなデータの場合は同期処理
  if compressedData.len <= 4096 and options.mode != acmAsync and options.mode != acmThreaded:
    try:
      let decompressedData = 
        if isSimdSupported():
          decompressSimd(compressedData)
        else:
          # シンプルな解凍（SIMD非対応環境用）
          compressedData # プレースホルダ
      
      retFuture.complete(decompressedData)
    except Exception as e:
      retFuture.fail(newException(IOError, "解凍に失敗しました: " & e.msg))
    
    return retFuture
  
  # モードに応じた処理
  case options.mode:
    of acmSync:
      # 同期処理
      try:
        let startTime = epochTime()
        
        let decompressedData = 
          if isSimdSupported():
            decompressSimd(compressedData)
          else:
            # シンプルな解凍（SIMD非対応環境用）
            compressedData # プレースホルダ
        
        let endTime = epochTime()
        
        # 統計情報の更新
        acquire(manager.processingLock)
        manager.stats.totalCompressedBytes += compressedData.len
        manager.stats.totalUncompressedBytes += decompressedData.len
        inc manager.stats.totalDecompressTasks
        
        let elapsed = endTime - startTime
        let totalTasks = manager.stats.totalDecompressTasks
        manager.stats.averageCompressionTime = 
          (manager.stats.averageCompressionTime * (totalTasks - 1) + elapsed) / totalTasks.float
        
        release(manager.processingLock)
        
        retFuture.complete(decompressedData)
      except Exception as e:
        acquire(manager.processingLock)
        inc manager.stats.failedTasks
        release(manager.processingLock)
        
        retFuture.fail(newException(IOError, "解凍に失敗しました: " & e.msg))
    
    of acmAsync, acmThreaded, acmHybrid:
      # 非同期処理またはスレッド処理
      let taskId = generateTaskId()
      let task = DecompressionTask(
        id: taskId,
        data: compressedData,
        priority: options.priority,
        options: options,
        status: csQueued,
        createdAt: epochTime(),
        future: retFuture
      )
      
      # タスクをキューに追加
      acquire(manager.processingLock)
      
      # キューサイズのチェック
      if manager.decompressionQueue.len >= manager.maxQueueSize:
        release(manager.processingLock)
        retFuture.fail(newException(IOError, "解凍キューがいっぱいです"))
        return retFuture
      
      manager.decompressionTasks[taskId] = task
      manager.decompressionQueue.enqueue(task, options.priority)
      
      # 統計情報の更新
      manager.stats.peakQueueSize = max(manager.stats.peakQueueSize, 
                                      manager.compressionQueue.len + manager.decompressionQueue.len)
      
      release(manager.processingLock)
      
      # ワーカースレッドにタスクを送信
      let msg = ThreadMessage(
        msgType: mtDecompressTask,
        taskId: taskId,
        data: compressedData,
        options: options
      )
      manager.messageQueue.enqueue(msg)
  
  return retFuture

# タスクのキャンセル
proc cancelTask*(manager: AsyncCompressionManager, taskId: string): bool =
  ## タスクをキャンセル
  acquire(manager.processingLock)
  
  # 圧縮タスクのチェック
  if taskId in manager.compressionTasks:
    let task = manager.compressionTasks[taskId]
    
    # キュー内のタスクかチェック
    if task.status == csQueued:
      # キューから削除
      let removed = manager.compressionQueue.remove(proc(t: CompressionTask): bool = t.id == taskId)
      if removed:
        task.status = csCancelled
        task.future.fail(newException(CatchableError, "タスクがキャンセルされました"))
        manager.compressionTasks.del(taskId)
        release(manager.processingLock)
        return true
    
    # すでに処理中の場合は完了を待つ
    release(manager.processingLock)
    return false
  
  # 解凍タスクのチェック
  if taskId in manager.decompressionTasks:
    let task = manager.decompressionTasks[taskId]
    
    # キュー内のタスクかチェック
    if task.status == csQueued:
      # キューから削除
      let removed = manager.decompressionQueue.remove(proc(t: DecompressionTask): bool = t.id == taskId)
      if removed:
        task.status = csCancelled
        task.future.fail(newException(CatchableError, "タスクがキャンセルされました"))
        manager.decompressionTasks.del(taskId)
        release(manager.processingLock)
        return true
    
    # すでに処理中の場合は完了を待つ
    release(manager.processingLock)
    return false
  
  release(manager.processingLock)
  return false

# キューのフラッシュ
proc flushQueues*(manager: AsyncCompressionManager): Future[void] =
  ## すべての保留中のタスクを処理
  var retFuture = newFuture[void]("flushQueues")
  
  if manager.flushPending:
    retFuture.complete()
    return retFuture
  
  # フラッシュ処理を開始
  manager.flushPending = true
  
  proc checkComplete() {.async.} =
    while manager.flushPending:
      acquire(manager.processingLock)
      let allEmpty = manager.compressionQueue.len == 0 and manager.decompressionQueue.len == 0
      release(manager.processingLock)
      
      if allEmpty:
        manager.flushPending = false
        retFuture.complete()
        break
      
      await sleepAsync(50)  # 50ms待機
  
  asyncCheck checkComplete()
  
  return retFuture

# 統計情報の取得
proc getStats*(manager: AsyncCompressionManager): AsyncCompressionStats =
  ## 圧縮マネージャーの統計情報を取得
  acquire(manager.processingLock)
  let stats = manager.stats
  release(manager.processingLock)
  
  return stats

# 非同期圧縮マネージャーの停止
proc stop*(manager: AsyncCompressionManager) =
  ## 圧縮マネージャーの停止
  if not manager.isRunning:
    return
  
  manager.isRunning = false
  
  # すべてのワーカースレッドにシャットダウンメッセージを送信
  for _ in 0..<manager.threadCount:
    let msg = ThreadMessage(msgType: mtShutdown)
    manager.messageQueue.enqueue(msg)
  
  # すべてのスレッドの終了を待機
  for worker in manager.workers:
    joinThread(worker.thread)
  
  # すべてのFutureを失敗させる
  acquire(manager.processingLock)
  
  for taskId, task in manager.compressionTasks:
    if task.status != csCompleted and task.status != csFailed:
      task.status = csCancelled
      task.future.fail(newException(CatchableError, "圧縮マネージャーが停止しました"))
  
  for taskId, task in manager.decompressionTasks:
    if task.status != csCompleted and task.status != csFailed:
      task.status = csCancelled
      task.future.fail(newException(CatchableError, "圧縮マネージャーが停止しました"))
  
  manager.compressionTasks.clear()
  manager.decompressionTasks.clear()
  # キューのクリア（ここでは簡略化）
  
  release(manager.processingLock)

# 大きなデータの分割圧縮
proc compressLargeData*(
  manager: AsyncCompressionManager,
  data: string,
  options: AsyncCompressionOptions = defaultAsyncCompressionOptions()
): Future[string] {.async.} =
  ## 大きなデータを分割圧縮
  if data.len <= options.chunkSize:
    # 小さなデータの場合は通常の圧縮
    return await compressAsync(manager, data, options)
  
  # チャンクに分割
  var chunks: seq[string] = @[]
  var position = 0
  while position < data.len:
    let chunkSize = min(options.chunkSize, data.len - position)
    let chunk = data[position..<position+chunkSize]
    chunks.add(chunk)
    position += chunkSize
  
  # 各チャンクを並列に圧縮
  var futures: seq[Future[string]] = @[]
  for chunk in chunks:
    futures.add(compressAsync(manager, chunk, options))
  
  # すべてのチャンクの圧縮を待機
  await all(futures)
  
  # 圧縮されたチャンクを結合
  var compressedData = ""
  for future in futures:
    try:
      compressedData &= future.read()
    except:
      # エラー処理
      raise newException(IOError, "チャンクの圧縮に失敗しました")
  
  return compressedData

# 大きなデータの分割解凍
proc decompressLargeData*(
  manager: AsyncCompressionManager,
  compressedData: string,
  options: AsyncCompressionOptions = defaultAsyncCompressionOptions()
): Future[string] {.async.} =
  ## 大きなデータを分割解凍
  if compressedData.len <= options.chunkSize:
    # 小さなデータの場合は通常の解凍
    return await decompressAsync(manager, compressedData, options)
  
  # チャンクに分割
  var chunks: seq[string] = @[]
  var position = 0
  while position < compressedData.len:
    let chunkSize = min(options.chunkSize, compressedData.len - position)
    let chunk = compressedData[position..<position+chunkSize]
    chunks.add(chunk)
    position += chunkSize
  
  # 各チャンクを並列に解凍
  var futures: seq[Future[string]] = @[]
  for chunk in chunks:
    futures.add(decompressAsync(manager, chunk, options))
  
  # すべてのチャンクの解凍を待機
  await all(futures)
  
  # 解凍されたチャンクを結合
  var decompressedData = ""
  for future in futures:
    try:
      decompressedData &= future.read()
    except:
      # エラー処理
      raise newException(IOError, "チャンクの解凍に失敗しました")
  
  return decompressedData

# キューの状態取得
proc getQueueStatus*(manager: AsyncCompressionManager): tuple[
  compressionQueueSize: int,
  decompressionQueueSize: int,
  activeThreads: int,
  idleThreads: int
] =
  ## キューの状態を取得
  acquire(manager.processingLock)
  
  let compressionQueueSize = manager.compressionQueue.len
  let decompressionQueueSize = manager.decompressionQueue.len
  
  var activeThreads = 0
  var idleThreads = 0
  
  for worker in manager.workers:
    if worker.state == tsBusy:
      inc activeThreads
    elif worker.state == tsIdle:
      inc idleThreads
  
  release(manager.processingLock)
  
  return (
    compressionQueueSize: compressionQueueSize,
    decompressionQueueSize: decompressionQueueSize,
    activeThreads: activeThreads,
    idleThreads: idleThreads
  )

# タスクのステータス取得
proc getTaskStatus*(manager: AsyncCompressionManager, taskId: string): Option[CompressionStatus] =
  ## タスクのステータスを取得
  acquire(manager.processingLock)
  
  if taskId in manager.compressionTasks:
    let status = manager.compressionTasks[taskId].status
    release(manager.processingLock)
    return some(status)
  
  if taskId in manager.decompressionTasks:
    let status = manager.decompressionTasks[taskId].status
    release(manager.processingLock)
    return some(status)
  
  release(manager.processingLock)
  return none(CompressionStatus)

# キャッシュの使用状況
proc getCacheStats*(manager: AsyncCompressionManager): Option[CompressionCacheStats] =
  ## キャッシュの統計情報を取得
  if manager.cache != nil:
    return some(manager.cache.getStats())
  
  return none(CompressionCacheStats) 