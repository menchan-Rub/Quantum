# thread_pool.nim
## スレッドプールモジュール
##
## このモジュールは効率的な非同期処理のためのワーカースレッドプールを実装します。
## 高速な処理と最適なリソース利用を実現するための機能を提供します。

import std/[
  os,
  times,
  locks,
  asyncdispatch,
  deques,
  tables,
  options,
  sets,
  hashes,
  strformat,
  cpuinfo,
  threadpool,
  sequtils,
  random,
  atomics
]

type
  TaskPriority* = enum
    ## タスクの優先度
    tpVeryLow = "very_low",     # 非常に低い
    tpLow = "low",              # 低い
    tpNormal = "normal",        # 通常
    tpHigh = "high",            # 高い
    tpVeryHigh = "very_high",   # 非常に高い
    tpCritical = "critical"     # 緊急

  TaskState* = enum
    ## タスクの状態
    tsCreated = "created",        # 作成済み
    tsQueued = "queued",          # キュー追加済み
    tsRunning = "running",        # 実行中
    tsCompleted = "completed",    # 完了
    tsFailed = "failed",          # 失敗
    tsCancelled = "cancelled",    # キャンセル
    tsTimeout = "timeout"         # タイムアウト

  ThreadState* = enum
    ## スレッドの状態
    thsIdle = "idle",           # アイドル
    thsRunning = "running",     # 実行中
    thsSleeping = "sleeping",   # スリープ中
    thsTerminated = "terminated"# 終了済み

  ThreadPoolMode* = enum
    ## プールの動作モード
    tpmFixed = "fixed",           # 固定数スレッド
    tpmDynamic = "dynamic",       # 動的スレッド数
    tpmAuto = "auto"              # 自動調整

  Task* = ref object
    ## タスク
    id*: string                 # タスクID
    callback*: proc () {.thread.} # コールバック関数
    priority*: TaskPriority     # 優先度
    state*: TaskState           # 状態
    createTime*: Time           # 作成時間
    startTime*: Time            # 実行開始時間
    endTime*: Time              # 完了時間
    timeout*: int               # タイムアウト (ミリ秒, 0=無限)
    result*: Option[any]        # 実行結果
    error*: Option[ref Exception] # エラー
    parentId*: Option[string]   # 親タスクID
    dependsOn*: HashSet[string] # 依存タスク
    workerId*: int              # 実行ワーカーID
    retryCount*: int            # リトライ回数
    maxRetries*: int            # 最大リトライ回数
    metadata*: Table[string, string] # メタデータ
    cancelFlag*: Atomic[bool]   # キャンセルフラグ
    onComplete*: proc(task: Task) {.thread.} # 完了コールバック

  Worker* = ref object
    ## ワーカースレッド
    id*: int                    # ワーカーID
    state*: ThreadState         # 状態
    currentTaskId*: Option[string] # 現在実行中のタスクID
    startTime*: Time            # 開始時間
    taskCount*: int             # 実行タスク数
    lastActivity*: Time         # 最終アクティビティ
    cpuAffinity*: int           # CPUアフィニティ
    thread*: Thread[WorkerContext] # スレッド
    processingTime*: int64      # 処理時間 (ナノ秒)
    lock*: Lock                 # ワーカーロック

  WorkerContext* = object
    ## ワーカーコンテキスト
    workerId*: int              # ワーカーID
    queuePtr*: pointer          # タスクキューポインタ
    poolPtr*: pointer           # プールポインタ
    signal*: ptr Condition      # シグナル
    lock*: ptr Lock             # ロック
    shutdown*: ptr Atomic[bool] # シャットダウンフラグ

  ThreadPoolConfig* = object
    ## スレッドプール設定
    minThreads*: int            # 最小スレッド数
    maxThreads*: int            # 最大スレッド数
    threadIdleTimeout*: int     # スレッドアイドルタイムアウト (ミリ秒)
    mode*: ThreadPoolMode       # 動作モード
    queueSize*: int             # キューサイズ
    priorityEnabled*: bool      # 優先度有効
    workerStackSize*: int       # ワーカースタックサイズ
    autoAdjustInterval*: int    # 自動調整間隔 (ミリ秒)
    cpuAffinityEnabled*: bool   # CPUアフィニティ有効

  ThreadPoolStatistics* = object
    ## スレッドプール統計
    totalTasksProcessed*: int   # 処理済みタスク総数
    totalTasksFailed*: int      # 失敗タスク数
    averageWaitTime*: float     # 平均待機時間 (ミリ秒)
    averageProcessingTime*: float # 平均処理時間 (ミリ秒)
    currentQueueSize*: int      # 現在のキューサイズ
    activeThreads*: int         # アクティブスレッド数
    idleThreads*: int           # アイドルスレッド数
    peakThreads*: int           # ピークスレッド数
    taskTimeouts*: int          # タイムアウト数
    totalExecutionTime*: int64  # 総実行時間 (ナノ秒)
    startTime*: Time            # 開始時間

  ThreadPool* = ref object
    ## スレッドプール
    config*: ThreadPoolConfig   # 設定
    workers*: seq[Worker]       # ワーカーリスト
    taskQueue*: Deque[Task]     # タスクキュー
    priorityQueues*: Table[TaskPriority, Deque[Task]] # 優先度別キュー
    runningTasks*: Table[string, Task] # 実行中タスク
    completedTasks*: Table[string, Task] # 完了タスク
    waitingDependencies*: Table[string, HashSet[string]] # 依存待ちタスク
    statistics*: ThreadPoolStatistics # 統計情報
    lock*: Lock                 # メインロック
    condition*: Condition       # 条件変数
    shutdown*: Atomic[bool]     # シャットダウンフラグ
    isRunning*: bool            # 実行中フラグ
    maxCompletedTasks*: int     # 最大完了タスク保持数
    schedulerThread*: Thread[void] # スケジューラスレッド
    adjustmentThread*: Thread[void] # 調整スレッド
    defaultTimeout*: int        # デフォルトタイムアウト (ミリ秒)

# 定数
const
  DEFAULT_MIN_THREADS = 4        # デフォルト最小スレッド数
  DEFAULT_MAX_THREADS = 16       # デフォルト最大スレッド数
  DEFAULT_IDLE_TIMEOUT = 60000   # デフォルトアイドルタイムアウト (60秒)
  DEFAULT_QUEUE_SIZE = 1000      # デフォルトキューサイズ
  DEFAULT_STACK_SIZE = 1024 * 1024 # 1MB スタックサイズ
  DEFAULT_AUTO_ADJUST_INTERVAL = 5000 # 5秒
  DEFAULT_MAX_COMPLETED_TASKS = 1000 # 完了タスク最大保持数
  DEFAULT_TIMEOUT = 30000        # デフォルトタイムアウト (30秒)
  SCHEDULER_INTERVAL = 10        # スケジューラ間隔 (ミリ秒)

# グローバル変数
var
  globalThreadPoolLock: Lock     # グローバルロック
  isGlobalThreadPoolInitialized = false # 初期化フラグ
  theGlobalThreadPool: ThreadPool # グローバルスレッドプール

# ユーティリティ関数

proc generateTaskId(): string =
  ## ユニークなタスクIDを生成する
  let timestamp = getTime().toUnix()
  let random = rand(high(int))
  result = &"task-{timestamp}-{random:x}"

proc initPoolStatistics(): ThreadPoolStatistics =
  ## 統計情報の初期化
  result = ThreadPoolStatistics(
    totalTasksProcessed: 0,
    totalTasksFailed: 0,
    averageWaitTime: 0.0,
    averageProcessingTime: 0.0,
    currentQueueSize: 0,
    activeThreads: 0,
    idleThreads: 0,
    peakThreads: 0,
    taskTimeouts: 0,
    totalExecutionTime: 0,
    startTime: getTime()
  )

proc initThreadPoolConfig(): ThreadPoolConfig =
  ## デフォルト設定の初期化
  let cpuCount = countProcessors()
  let minThreads = max(2, cpuCount div 2)
  let maxThreads = max(4, cpuCount * 2)
  
  result = ThreadPoolConfig(
    minThreads: minThreads,
    maxThreads: maxThreads,
    threadIdleTimeout: DEFAULT_IDLE_TIMEOUT,
    mode: tpmAuto,
    queueSize: DEFAULT_QUEUE_SIZE,
    priorityEnabled: true,
    workerStackSize: DEFAULT_STACK_SIZE,
    autoAdjustInterval: DEFAULT_AUTO_ADJUST_INTERVAL,
    cpuAffinityEnabled: true
  )

proc executeTask(worker: Worker, task: Task) {.thread.} =
  ## タスクを実行する
  if task.isNil:
    return
  
  # タスク実行前の準備
  try:
    withLock worker.lock:
      worker.state = thsRunning
      worker.currentTaskId = some(task.id)
    
    task.state = tsRunning
    task.startTime = getTime()
    task.workerId = worker.id
    
    # タスクのコールバックを実行
    if not task.callback.isNil:
      task.callback()
    
    # タスク完了処理
    task.state = tsCompleted
    task.endTime = getTime()
    
    # 完了コールバックがあれば実行
    if not task.onComplete.isNil:
      task.onComplete(task)
    
    # 統計情報更新
    let processingTime = (task.endTime - task.startTime).inNanoseconds
    withLock worker.lock:
      worker.processingTime += processingTime
      inc worker.taskCount
      worker.state = thsIdle
      worker.currentTaskId = none(string)
      worker.lastActivity = getTime()
  except:
    # エラー処理
    let ex = getCurrentException()
    task.state = tsFailed
    task.endTime = getTime()
    task.error = some(ex)
    
    # ワーカー状態更新
    withLock worker.lock:
      worker.state = thsIdle
      worker.currentTaskId = none(string)
      worker.lastActivity = getTime()

proc workerProc(ctx: WorkerContext) {.thread.} =
  ## ワーカースレッド処理
  var pool = cast[ThreadPool](ctx.poolPtr)
  var workerId = ctx.workerId
  var queue = cast[Deque[Task]](ctx.queuePtr)
  var lock = ctx.lock
  var condition = ctx.signal
  var shouldShutdown = ctx.shutdown
  
  # ワーカーループ
  while not shouldShutdown[].load():
    var taskToExecute: Task = nil
    
    # タスクの取得
    withLock lock[]:
      # キューが空で、シャットダウンでなければ待機
      while queue.len == 0 and not shouldShutdown[].load():
        # ワーカー状態を更新
        var worker: Worker = nil
        for w in pool.workers:
          if w.id == workerId:
            worker = w
            break
        
        if not worker.isNil:
          withLock worker.lock:
            worker.state = thsSleeping
            worker.lastActivity = getTime()
        
        # 条件変数で待機
        wait(condition[], lock[])
        
        # 待機から復帰
        if not worker.isNil:
          withLock worker.lock:
            worker.state = thsIdle
            worker.lastActivity = getTime()
      
      # シャットダウンチェック
      if shouldShutdown[].load():
        break
      
      # タスクをキューから取得
      if queue.len > 0:
        taskToExecute = queue.popFirst()
    
    # タスクを実行
    if not taskToExecute.isNil:
      var worker: Worker = nil
      for w in pool.workers:
        if w.id == workerId:
          worker = w
          break
      
      if not worker.isNil:
        executeTask(worker, taskToExecute)

proc createWorker(id: int, pool: ThreadPool): Worker =
  ## ワーカースレッドを作成
  var worker = Worker(
    id: id,
    state: thsIdle,
    currentTaskId: none(string),
    startTime: getTime(),
    taskCount: 0,
    lastActivity: getTime(),
    cpuAffinity: id mod countProcessors(),
    processingTime: 0
  )
  
  # ロックの初期化
  initLock(worker.lock)
  
  # ワーカーコンテキストの準備
  var ctx = WorkerContext(
    workerId: id,
    queuePtr: addr pool.taskQueue,
    poolPtr: cast[pointer](pool),
    signal: addr pool.condition,
    lock: addr pool.lock,
    shutdown: addr pool.shutdown
  )
  
  # スレッドの作成
  createThread(worker.thread, workerProc, ctx)
  
  # CPUアフィニティの設定（ここでは簡易実装）
  if pool.config.cpuAffinityEnabled:
    # プラットフォーム依存のアフィニティ設定は省略
    discard
  
  return worker

proc scheduleTask(pool: ThreadPool) {.thread.} =
  ## タスクをスケジュールする
  # 停止フラグのチェック
  if pool.shutdown.load():
    return
  
  withLock pool.lock:
    # 実行可能なタスクがあるかチェック
    if pool.taskQueue.len == 0 and pool.priorityQueues.len == 0:
      return
    
    # ワーカースケジューリング
    # アイドル状態のワーカーを探す
    var idleWorkers: seq[Worker] = @[]
    for worker in pool.workers:
      withLock worker.lock:
        if worker.state == thsIdle or worker.state == thsSleeping:
          idleWorkers.add(worker)
    
    # アイドルワーカーがない場合、動的モードなら新しいワーカーを作成
    if idleWorkers.len == 0 and pool.config.mode != tpmFixed:
      if pool.workers.len < pool.config.maxThreads:
        let newWorker = createWorker(pool.workers.len, pool)
        pool.workers.add(newWorker)
        pool.statistics.peakThreads = max(pool.statistics.peakThreads, pool.workers.len)
    
    # タスクをスレッドに割り当て
    if idleWorkers.len > 0:
      # 条件変数をシグナル
      signal(pool.condition)

proc checkTimeouts(pool: ThreadPool) {.thread.} =
  ## タイムアウトチェック
  if pool.shutdown.load():
    return
  
  let now = getTime()
  var timedOutTasks: seq[Task] = @[]
  
  withLock pool.lock:
    # 実行中タスクのタイムアウトチェック
    for id, task in pool.runningTasks:
      if task.timeout > 0:
        let elapsed = (now - task.startTime).inMilliseconds.int
        if elapsed > task.timeout:
          timedOutTasks.add(task)
  
  # タイムアウトタスクの処理
  for task in timedOutTasks:
    withLock pool.lock:
      # タスクの強制キャンセル
      task.state = tsTimeout
      task.endTime = now
      pool.runningTasks.del(task.id)
      pool.completedTasks[task.id] = task
      
      # キャンセルフラグを設定
      task.cancelFlag.store(true)
      
      # 統計情報の更新
      inc pool.statistics.taskTimeouts

proc autoAdjustThreads(pool: ThreadPool) {.thread.} =
  ## スレッド数の自動調整
  if pool.config.mode != tpmAuto or pool.shutdown.load():
    return
  
  withLock pool.lock:
    let queueSize = pool.taskQueue.len
    var activeCount = 0
    var idleCount = 0
    
    # アクティブおよびアイドルワーカーのカウント
    for worker in pool.workers:
      withLock worker.lock:
        if worker.state == thsRunning:
          inc activeCount
        elif worker.state == thsIdle or worker.state == thsSleeping:
          inc idleCount
    
    # 統計情報の更新
    pool.statistics.activeThreads = activeCount
    pool.statistics.idleThreads = idleCount
    
    # スレッド数の調整
    # キューが多く、アイドルスレッドが少ない場合は増やす
    if queueSize > idleCount * 2 and pool.workers.len < pool.config.maxThreads:
      let newWorker = createWorker(pool.workers.len, pool)
      pool.workers.add(newWorker)
      pool.statistics.peakThreads = max(pool.statistics.peakThreads, pool.workers.len)
    
    # アイドルスレッドが多く、キューが少ない場合は減らす
    elif idleCount > 2 and queueSize == 0 and pool.workers.len > pool.config.minThreads:
      # 最後に追加されたアイドルワーカーを特定
      var lastIdleWorker: Worker = nil
      var lastIdleIndex = -1
      
      for i in countdown(pool.workers.high, 0):
        withLock pool.workers[i].lock:
          if pool.workers[i].state == thsIdle or pool.workers[i].state == thsSleeping:
            let idleTime = (getTime() - pool.workers[i].lastActivity).inMilliseconds.int
            if idleTime > pool.config.threadIdleTimeout:
              lastIdleWorker = pool.workers[i]
              lastIdleIndex = i
              break
      
      # アイドルワーカーを終了
      if not lastIdleWorker.isNil and lastIdleIndex >= 0:
        withLock lastIdleWorker.lock:
          lastIdleWorker.state = thsTerminated
        
        # スレッドを終了するシグナルを送信
        signal(pool.condition)
        
        # ワーカーリストから削除（ここでは簡略化）
        pool.workers.delete(lastIdleIndex)

proc schedulerProc() {.thread.} =
  ## スケジューラスレッド
  let pool = theGlobalThreadPool
  
  while not pool.shutdown.load():
    # タスクスケジュール
    scheduleTask(pool)
    
    # タイムアウトチェック
    checkTimeouts(pool)
    
    # 短い待機
    sleep(SCHEDULER_INTERVAL)

proc adjustmentProc() {.thread.} =
  ## スレッド数調整スレッド
  let pool = theGlobalThreadPool
  
  while not pool.shutdown.load():
    # スレッド数の自動調整
    autoAdjustThreads(pool)
    
    # 調整間隔で待機
    sleep(pool.config.autoAdjustInterval)

# スレッドプール実装

proc newThreadPool*(config: ThreadPoolConfig = initThreadPoolConfig()): ThreadPool =
  ## 新しいスレッドプールを作成
  result = ThreadPool(
    config: config,
    workers: @[],
    taskQueue: initDeque[Task](),
    priorityQueues: initTable[TaskPriority, Deque[Task]](),
    runningTasks: initTable[string, Task](),
    completedTasks: initTable[string, Task](),
    waitingDependencies: initTable[string, HashSet[string]](),
    statistics: initPoolStatistics(),
    isRunning: false,
    maxCompletedTasks: DEFAULT_MAX_COMPLETED_TASKS,
    defaultTimeout: DEFAULT_TIMEOUT
  )
  
  # 優先度キューの初期化
  for priority in TaskPriority:
    result.priorityQueues[priority] = initDeque[Task]()
  
  # ロックとコンディションの初期化
  initLock(result.lock)
  initCondition(result.condition)
  
  # シャットダウンフラグの初期化
  result.shutdown.store(false)

proc getGlobalThreadPool*(): ThreadPool =
  ## グローバルスレッドプールを取得する
  if not isGlobalThreadPoolInitialized:
    withLock globalThreadPoolLock:
      if not isGlobalThreadPoolInitialized:
        # グローバルロックの初期化
        initLock(globalThreadPoolLock)
        
        # グローバルプールの作成
        theGlobalThreadPool = newThreadPool()
        
        # 初期化フラグを設定
        isGlobalThreadPoolInitialized = true
  
  return theGlobalThreadPool

proc newTask*(callback: proc() {.thread.}, priority: TaskPriority = tpNormal, 
              timeout: int = 0): Task =
  ## 新しいタスクを作成する
  result = Task(
    id: generateTaskId(),
    callback: callback,
    priority: priority,
    state: tsCreated,
    createTime: getTime(),
    timeout: timeout,
    result: none(any),
    error: none(ref Exception),
    parentId: none(string),
    dependsOn: initHashSet[string](),
    retryCount: 0,
    maxRetries: 3,
    metadata: initTable[string, string]()
  )
  
  # キャンセルフラグの初期化
  result.cancelFlag.store(false)

proc start*(pool: ThreadPool): bool =
  ## スレッドプールを開始する
  if pool.isRunning:
    return true
  
  try:
    withLock pool.lock:
      # シャットダウンフラグをリセット
      pool.shutdown.store(false)
      
      # 初期スレッドの作成
      for i in 0 ..< pool.config.minThreads:
        let worker = createWorker(i, pool)
        pool.workers.add(worker)
      
      # 統計情報の初期化
      pool.statistics = initPoolStatistics()
      pool.statistics.peakThreads = pool.workers.len
      
      # スケジューラスレッドの作成
      createThread(pool.schedulerThread, schedulerProc)
      
      # 自動調整スレッドの作成（自動モードの場合）
      if pool.config.mode == tpmAuto:
        createThread(pool.adjustmentThread, adjustmentProc)
      
      pool.isRunning = true
    
    return true
  except:
    echo "Error starting thread pool: ", getCurrentExceptionMsg()
    return false

proc stop*(pool: ThreadPool, waitForCompletion: bool = true): bool =
  ## スレッドプールを停止する
  if not pool.isRunning:
    return true
  
  try:
    withLock pool.lock:
      # シャットダウンフラグを設定
      pool.shutdown.store(true)
      
      # 全スレッドに通知
      broadcast(pool.condition)
      
      if waitForCompletion:
        # 実行中のタスクが完了するまで待機
        while pool.runningTasks.len > 0:
          # ロックを解放して短い時間待つ
          {.locks: [].}:
            sleep(100)
      
      # スレッドの終了を待機
      for worker in pool.workers:
        joinThread(worker.thread)
      
      # スケジューラスレッドの終了を待機
      joinThread(pool.schedulerThread)
      
      # 自動調整スレッドの終了を待機（自動モードの場合）
      if pool.config.mode == tpmAuto:
        joinThread(pool.adjustmentThread)
      
      pool.isRunning = false
      pool.workers = @[]
    
    return true
  except:
    echo "Error stopping thread pool: ", getCurrentExceptionMsg()
    return false

proc queueTask*(pool: ThreadPool, task: Task): bool =
  ## タスクをキューに追加する
  if task.isNil:
    return false
  
  if not pool.isRunning:
    if not pool.start():
      return false
  
  # タスク状態の更新
  task.state = tsQueued
  
  withLock pool.lock:
    # 依存関係のチェック
    if task.dependsOn.len > 0:
      var allDependenciesCompleted = true
      var waitingDeps = initHashSet[string]()
      
      for depId in task.dependsOn:
        # 依存タスクが完了しているかチェック
        if not pool.completedTasks.hasKey(depId) or
           pool.completedTasks[depId].state != tsCompleted:
          allDependenciesCompleted = false
          waitingDeps.incl(depId)
      
      # 依存関係が解決していない場合は待機リストに追加
      if not allDependenciesCompleted:
        pool.waitingDependencies[task.id] = waitingDeps
        return true
    
    # タイムアウトの設定
    if task.timeout <= 0:
      task.timeout = pool.defaultTimeout
    
    # 優先度キューに追加
    if pool.config.priorityEnabled:
      pool.priorityQueues[task.priority].addLast(task)
    else:
      pool.taskQueue.addLast(task)
    
    # 統計情報の更新
    pool.statistics.currentQueueSize = pool.taskQueue.len
    
    # ワーカースレッドに通知
    signal(pool.condition)
  
  return true

proc waitForTask*(pool: ThreadPool, taskId: string, timeout: int = -1): bool =
  ## タスクの完了を待機する
  if not pool.isRunning:
    return false
  
  let startWait = getTime()
  let actualTimeout = if timeout < 0: pool.defaultTimeout else: timeout
  let endWait = startWait + initDuration(milliseconds = actualTimeout)
  
  # タスクの完了を待機
  while getTime() < endWait:
    withLock pool.lock:
      # タスクが完了しているかチェック
      if pool.completedTasks.hasKey(taskId):
        let task = pool.completedTasks[taskId]
        return task.state == tsCompleted
    
    # 短い時間待機
    sleep(10)
  
  return false  # タイムアウト

proc cancelTask*(pool: ThreadPool, taskId: string): bool =
  ## タスクをキャンセルする
  if not pool.isRunning:
    return false
  
  withLock pool.lock:
    # キュー内のタスクをキャンセル
    if pool.config.priorityEnabled:
      for priority in TaskPriority:
        var queue = pool.priorityQueues[priority]
        var i = 0
        while i < queue.len:
          if queue[i].id == taskId:
            queue[i].state = tsCancelled
            queue[i].endTime = getTime()
            pool.completedTasks[taskId] = queue[i]
            queue.delete(i)
            return true
          inc i
    else:
      var i = 0
      while i < pool.taskQueue.len:
        if pool.taskQueue[i].id == taskId:
          pool.taskQueue[i].state = tsCancelled
          pool.taskQueue[i].endTime = getTime()
          pool.completedTasks[taskId] = pool.taskQueue[i]
          pool.taskQueue.delete(i)
          return true
        inc i
    
    # 実行中のタスクをキャンセル
    if pool.runningTasks.hasKey(taskId):
      let task = pool.runningTasks[taskId]
      task.cancelFlag.store(true)
      # 注：実際のキャンセルはタスク内部でキャンセルフラグをチェックする必要がある
      return true
  
  return false

proc getTaskStatus*(pool: ThreadPool, taskId: string): Option[TaskState] =
  ## タスクの状態を取得する
  if not pool.isRunning:
    return none(TaskState)
  
  withLock pool.lock:
    # 完了タスクから検索
    if pool.completedTasks.hasKey(taskId):
      return some(pool.completedTasks[taskId].state)
    
    # 実行中タスクから検索
    if pool.runningTasks.hasKey(taskId):
      return some(pool.runningTasks[taskId].state)
    
    # キュー内のタスクを検索
    if pool.config.priorityEnabled:
      for priority in TaskPriority:
        for task in pool.priorityQueues[priority]:
          if task.id == taskId:
            return some(task.state)
    else:
      for task in pool.taskQueue:
        if task.id == taskId:
          return some(task.state)
  
  return none(TaskState)

proc getTaskResult*(pool: ThreadPool, taskId: string): Option[Task] =
  ## タスクの結果を取得する
  if not pool.isRunning:
    return none(Task)
  
  withLock pool.lock:
    # 完了タスクから検索
    if pool.completedTasks.hasKey(taskId):
      return some(pool.completedTasks[taskId])
  
  return none(Task)

proc getPoolStats*(pool: ThreadPool): ThreadPoolStatistics =
  ## スレッドプールの統計情報を取得する
  withLock pool.lock:
    # 最新の統計情報を更新
    var activeCount = 0
    var idleCount = 0
    
    for worker in pool.workers:
      withLock worker.lock:
        if worker.state == thsRunning:
          inc activeCount
        elif worker.state == thsIdle or worker.state == thsSleeping:
          inc idleCount
    
    pool.statistics.activeThreads = activeCount
    pool.statistics.idleThreads = idleCount
    pool.statistics.currentQueueSize = pool.taskQueue.len
    
    # 統計情報のコピーを返す
    result = pool.statistics

proc setMaxThreads*(pool: ThreadPool, maxThreads: int): bool =
  ## 最大スレッド数を設定する
  if maxThreads < pool.config.minThreads:
    return false
  
  withLock pool.lock:
    pool.config.maxThreads = maxThreads
    
    # 現在のスレッド数が最大値を超えている場合は調整
    if pool.workers.len > maxThreads:
      # 超過分のスレッドは自然終了を待つ（自動調整で処理）
      discard
  
  return true

proc setMinThreads*(pool: ThreadPool, minThreads: int): bool =
  ## 最小スレッド数を設定する
  if minThreads <= 0 or minThreads > pool.config.maxThreads:
    return false
  
  withLock pool.lock:
    pool.config.minThreads = minThreads
    
    # 現在のスレッド数が最小値より少ない場合は追加
    if pool.workers.len < minThreads:
      for i in pool.workers.len ..< minThreads:
        let worker = createWorker(i, pool)
        pool.workers.add(worker)
      
      pool.statistics.peakThreads = max(pool.statistics.peakThreads, pool.workers.len)
  
  return true

proc setThreadPoolMode*(pool: ThreadPool, mode: ThreadPoolMode): bool =
  ## スレッドプールモードを設定する
  withLock pool.lock:
    pool.config.mode = mode
    
    # モード変更に伴う処理
    if mode == tpmFixed:
      # 固定モードでは自動調整を停止
      discard
    elif mode == tpmAuto and not pool.isRunning:
      # 自動モードで実行中でない場合、再起動して自動調整を有効化
      discard
  
  return true

proc clearCompletedTasks*(pool: ThreadPool): int =
  ## 完了タスクをクリアする
  withLock pool.lock:
    result = pool.completedTasks.len
    pool.completedTasks.clear()

proc shutdown*() =
  ## グローバルスレッドプールをシャットダウン
  if isGlobalThreadPoolInitialized:
    withLock globalThreadPoolLock:
      if isGlobalThreadPoolInitialized:
        discard theGlobalThreadPool.stop(true)
        isGlobalThreadPoolInitialized = false

# エクスポート
export ThreadPool, Task, Worker, TaskPriority, TaskState, ThreadState
export ThreadPoolMode, ThreadPoolConfig, ThreadPoolStatistics
export newThreadPool, getGlobalThreadPool, newTask
export start, stop, queueTask, waitForTask, cancelTask
export getTaskStatus, getTaskResult, getPoolStats
export setMaxThreads, setMinThreads, setThreadPoolMode, clearCompletedTasks, shutdown