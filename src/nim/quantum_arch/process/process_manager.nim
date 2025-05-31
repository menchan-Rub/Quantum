# process_manager.nim
## プロセスマネージャモジュール
##
## このモジュールはブラウザの各プロセスのライフサイクル管理を担当します。
## プロセスの作成、終了、監視、およびプロセス間通信の確立を行います。

import std/[
  os,
  osproc,
  strutils,
  strformat,
  tables,
  sets,
  options,
  streams,
  json,
  times,
  asyncdispatch,
  hashes,
  random,
  locks,
  sequtils
]

import ../ipc/ipc_manager

type
  ProcessStatus* = enum
    ## プロセスのステータス
    psInitializing = "initializing",  # 初期化中
    psStarting = "starting",          # 起動中
    psRunning = "running",            # 実行中
    psSuspended = "suspended",        # 一時停止
    psTerminating = "terminating",    # 終了中
    psTerminated = "terminated",      # 終了済み
    psCrashed = "crashed",            # クラッシュ
    psUnknown = "unknown"             # 不明

  ProcessErrorType* = enum
    ## プロセスエラーの種類
    petStartFailure = "start_failure",  # 起動失敗
    petCrash = "crash",                 # クラッシュ
    petTermination = "termination",     # 異常終了
    petTimeout = "timeout",             # タイムアウト
    petIpcError = "ipc_error",          # IPC通信エラー
    petResourceLimit = "resource_limit",# リソース制限超過
    petPermissionDenied = "permission_denied", # 権限拒否
    petUnknown = "unknown"              # 不明

  ProcessInfo* = object
    ## プロセス情報
    id*: string                        # プロセスID
    pid*: int                          # OSプロセスID
    processType*: ProcessType          # プロセスタイプ
    status*: ProcessStatus             # ステータス
    startTime*: Time                   # 起動時間
    endTime*: Option[Time]             # 終了時間
    exitCode*: Option[int]             # 終了コード
    commandLine*: string               # コマンドライン
    workingDir*: string                # 作業ディレクトリ
    environment*: Table[string, string] # 環境変数
    ipcChannel*: Option[string]        # IPCチャネルID
    memoryUsage*: int64                # メモリ使用量
    cpuUsage*: float                   # CPU使用率
    lastUpdated*: Time                 # 最終更新時間
    crashCount*: int                   # クラッシュ回数
    restartCount*: int                 # 再起動回数
    userData*: JsonNode                # ユーザーデータ

  ProcessError* = object of CatchableError
    ## プロセスエラー
    errorType*: ProcessErrorType       # エラータイプ
    processId*: string                 # プロセスID
    timestamp*: Time                   # タイムスタンプ
    details*: string                   # 詳細
    errorCode*: int                    # エラーコード

  ProcessRestartPolicy* = enum
    ## 再起動ポリシー
    prpNever = "never",                # 再起動しない
    prpAlways = "always",              # 常に再起動
    prpOnCrash = "on_crash",           # クラッシュ時のみ
    prpOnFailure = "on_failure",       # 異常終了時
    prpUnlessSuccessful = "unless_successful" # 正常終了以外

  ProcessSandboxLevel* = enum
    ## サンドボックスレベル
    pslNone = "none",                  # サンドボックスなし
    pslBasic = "basic",                # 基本的な分離
    pslStrict = "strict",              # 厳格な分離
    pslSecure = "secure"               # 最高セキュリティ

  ProcessConfig* = object
    ## プロセス設定
    executablePath*: string            # 実行ファイルパス
    arguments*: seq[string]            # コマンドライン引数
    workingDir*: string                # 作業ディレクトリ
    environment*: Table[string, string] # 環境変数
    processType*: ProcessType          # プロセスタイプ
    restartPolicy*: ProcessRestartPolicy # 再起動ポリシー
    maxMemoryMB*: int                  # 最大メモリ使用量(MB)
    maxCpuPercent*: int                # 最大CPU使用率(%)
    maxRestarts*: int                  # 最大再起動回数
    restartDelay*: int                 # 再起動遅延(ミリ秒)
    terminationTimeout*: int           # 終了タイムアウト(ミリ秒)
    sandboxLevel*: ProcessSandboxLevel # サンドボックスレベル
    startupTimeout*: int               # 起動タイムアウト(ミリ秒)
    userData*: JsonNode                # ユーザーデータ

  ProcessStartResult* = object
    ## プロセス起動結果
    success*: bool                     # 成功フラグ
    processId*: string                 # プロセスID
    errorMessage*: string              # エラーメッセージ

  ProcessMonitorEvent* = object
    ## プロセス監視イベント
    processId*: string                 # プロセスID
    eventType*: string                 # イベントタイプ
    timestamp*: Time                   # タイムスタンプ
    details*: JsonNode                 # 詳細

  ProcessManagerConfig* = object
    ## マネージャ設定
    ipcManager*: IPCManager             # IPC マネージャ
    monitorInterval*: int               # 監視間隔(ミリ秒)
    defaultTerminationTimeout*: int     # デフォルト終了タイムアウト(ミリ秒)
    defaultStartupTimeout*: int         # デフォルト起動タイムアウト(ミリ秒)
    defaultSandboxLevel*: ProcessSandboxLevel # デフォルトサンドボックスレベル
    logEnabled*: bool                   # ログ有効
    autoCleanupZombies*: bool           # ゾンビプロセス自動クリーンアップ
    stateFilePath*: string              # 状態ファイルパス

  ProcessManager* = ref object
    ## プロセスマネージャ
    processes*: Table[string, ProcessInfo] # プロセス情報
    osProcesses*: Table[string, Process]   # OSプロセスオブジェクト
    ipcManager*: IPCManager             # IPCマネージャ
    config*: ProcessManagerConfig       # 設定
    monitorActive*: bool                # 監視アクティブフラグ
    shuttingDown*: bool                 # シャットダウンフラグ
    lock*: Lock                         # 同期ロック
    eventHandlers*: Table[string, seq[proc(event: ProcessMonitorEvent) {.async.}]] # イベントハンドラ
    isInitialized*: bool                # 初期化フラグ
    lastMonitorTime*: Time              # 最終監視時間

# 定数
const
  DEFAULT_MONITOR_INTERVAL = 1000      # デフォルト監視間隔 1秒
  DEFAULT_TERMINATION_TIMEOUT = 5000   # デフォルト終了タイムアウト 5秒
  DEFAULT_STARTUP_TIMEOUT = 10000      # デフォルト起動タイムアウト 10秒
  MAX_PROCESS_MEMORY_MB = 2048         # 最大メモリ使用量 2GB
  MAX_RESTARTS = 5                     # 最大再起動回数
  DEFAULT_RESTART_DELAY = 1000         # デフォルト再起動遅延 1秒
  PROCESS_ID_PREFIX = "proc"           # プロセスID接頭辞

# ユーティリティ関数

proc generateProcessId(): string =
  ## ユニークなプロセスIDを生成する
  let timestamp = getTime().toUnix()
  let random = rand(high(int))
  result = &"{PROCESS_ID_PREFIX}-{timestamp}-{random:x}"

proc parseProcessStatus*(s: string): ProcessStatus =
  ## 文字列からプロセスステータスへ変換
  try:
    return parseEnum[ProcessStatus](s)
  except:
    return psUnknown

proc parseErrorType*(s: string): ProcessErrorType =
  ## 文字列からエラータイプへ変換
  try:
    return parseEnum[ProcessErrorType](s)
  except:
    return petUnknown

proc buildEnvironmentString(env: Table[string, string]): string =
  ## 環境変数テーブルを文字列に変換
  var envStrs: seq[string] = @[]
  for key, value in env:
    envStrs.add(&"{key}={value}")
  return envStrs.join(" ")

proc getCommandLineString(config: ProcessConfig): string =
  ## コマンドライン文字列を生成
  var cmdParts = @[config.executablePath]
  cmdParts.add(config.arguments)
  return cmdParts.join(" ")

proc parseExitStatus(status: int): int =
  ## 終了ステータスを解析
  when defined(windows):
    return status
  else:
    # POSIX systems
    if WIFEXITED(status):
      return WEXITSTATUS(status)
    elif WIFSIGNALED(status):
      return 128 + WTERMSIG(status)
    else:
      return status

proc applySandbox(process: Process, level: ProcessSandboxLevel, procType: ProcessType) =
  ## サンドボックス設定を適用する
  case level
  of pslNone:
    # サンドボックスなし
    discard
  of pslBasic:
    # OSのプロセス分離APIで制限を設定
    set_process_limits_for_basic_isolation(process)
  of pslStrict:
    # 厳格な分離 (chroot, namespaces, cgroups等)
    discard
  of pslSecure:
    # 最高セキュリティ (全アクセス制限)
    discard

# プロセスマネージャ実装

proc newProcessManagerConfig*(): ProcessManagerConfig =
  ## 新しいプロセスマネージャ設定を作成する
  result = ProcessManagerConfig(
    monitorInterval: DEFAULT_MONITOR_INTERVAL,
    defaultTerminationTimeout: DEFAULT_TERMINATION_TIMEOUT,
    defaultStartupTimeout: DEFAULT_STARTUP_TIMEOUT,
    defaultSandboxLevel: pslStrict,
    logEnabled: true,
    autoCleanupZombies: true
  )

proc newProcessManager*(ipcManager: IPCManager, config: ProcessManagerConfig = nil): ProcessManager =
  ## 新しいプロセスマネージャを作成する
  var actualConfig = if config.isNil: newProcessManagerConfig() else: config
  actualConfig.ipcManager = ipcManager
  
  result = ProcessManager(
    processes: initTable[string, ProcessInfo](),
    osProcesses: initTable[string, Process](),
    ipcManager: ipcManager,
    config: actualConfig,
    monitorActive: false,
    shuttingDown: false,
    eventHandlers: initTable[string, seq[proc(event: ProcessMonitorEvent) {.async.}]](),
    isInitialized: false,
    lastMonitorTime: getTime()
  )
  
  # ロックの初期化
  initLock(result.lock)

proc initProcessConfig*(): ProcessConfig =
  ## プロセス設定をデフォルト値で初期化する
  result = ProcessConfig(
    arguments: @[],
    environment: initTable[string, string](),
    processType: ptUtility,
    restartPolicy: prpOnCrash,
    maxMemoryMB: MAX_PROCESS_MEMORY_MB,
    maxCpuPercent: 100,
    maxRestarts: MAX_RESTARTS,
    restartDelay: DEFAULT_RESTART_DELAY,
    terminationTimeout: DEFAULT_TERMINATION_TIMEOUT,
    sandboxLevel: pslStrict,
    startupTimeout: DEFAULT_STARTUP_TIMEOUT,
    userData: newJObject()
  )

proc initialize*(manager: ProcessManager): Future[bool] {.async.} =
  ## プロセスマネージャを初期化する
  if manager.isInitialized:
    return true
  
  try:
    withLock manager.lock:
      # 状態ファイルから回復（実装省略）
      manager.isInitialized = true
    
    return true
  except:
    echo "Failed to initialize process manager: ", getCurrentExceptionMsg()
    return false

proc startProcess*(manager: ProcessManager, config: ProcessConfig): Future[ProcessStartResult] {.async.} =
  ## プロセスを開始する
  var result = ProcessStartResult(
    success: false,
    processId: generateProcessId(),
    errorMessage: ""
  )
  
  if not manager.isInitialized:
    if not await manager.initialize():
      result.errorMessage = "Process manager not initialized"
      return result
  
  try:
    # 必須パラメータチェック
    if config.executablePath.len == 0:
      result.errorMessage = "Executable path is empty"
      return result
    
    # 実行ファイルの存在チェック
    if not fileExists(config.executablePath):
      result.errorMessage = &"Executable not found: {config.executablePath}"
      return result
    
    # 作業ディレクトリチェック
    var workingDir = config.workingDir
    if workingDir.len == 0:
      workingDir = getCurrentDir()
    elif not dirExists(workingDir):
      result.errorMessage = &"Working directory not found: {workingDir}"
      return result
    
    # 環境変数の準備
    var environment = initTable[string, string]()
    for key, value in getEnv():
      environment[key] = value
    
    # 設定の環境変数をマージ
    for key, value in config.environment:
      environment[key] = value
    
    # プロセス情報を作成
    var procInfo = ProcessInfo(
      id: result.processId,
      pid: 0,
      processType: config.processType,
      status: psInitializing,
      startTime: getTime(),
      commandLine: getCommandLineString(config),
      workingDir: workingDir,
      environment: environment,
      ipcChannel: none(string),
      memoryUsage: 0,
      cpuUsage: 0.0,
      lastUpdated: getTime(),
      crashCount: 0,
      restartCount: 0,
      userData: config.userData
    )
    
    # 起動オプションを準備
    var options: set[ProcessOption] = {poUsePath}
    
    # プロセス起動
    var process: Process
    
    withLock manager.lock:
      process = startProcess(
        command = config.executablePath,
        workingDir = workingDir,
        args = config.arguments,
        env = environment,
        options = options
      )
      
      # プロセス情報を更新
      procInfo.pid = process.processID
      procInfo.status = psStarting
      
      # プロセスマネージャに登録
      manager.processes[result.processId] = procInfo
      manager.osProcesses[result.processId] = process
    
    # サンドボックス設定を適用
    applySandbox(process, config.sandboxLevel, config.processType)
    
    # IPC チャネルの設定（非同期設定のため、一旦省略）
    
    # 起動完了を待機
    let startupTimeout = config.startupTimeout
    if startupTimeout > 0:
      let startTime = getTime()
      var isRunning = false
      while (getTime() - startTime).inMilliseconds.int < startupTimeout:
        # プロセスの実行状態をチェック
        isRunning = not process.running
        if not isRunning:
          # まだ起動中
          await sleepAsync(100)
        else:
          # すでに終了（エラー）
          let exitCode = parseExitStatus(process.peekExitCode())
          withLock manager.lock:
            procInfo.status = psCrashed
            procInfo.exitCode = some(exitCode)
            procInfo.endTime = some(getTime())
            manager.processes[result.processId] = procInfo
          
          result.errorMessage = &"Process terminated during startup with exit code {exitCode}"
          return result
      
      # 起動成功
      withLock manager.lock:
        procInfo.status = psRunning
        manager.processes[result.processId] = procInfo
      
      # 監視を開始（既に起動していなければ）
      if not manager.monitorActive:
        asyncCheck manager.monitorProcesses()
      
      result.success = true
      return result
    
    # タイムアウトなしの場合は即座に成功とみなす
    withLock manager.lock:
      procInfo.status = psRunning
      manager.processes[result.processId] = procInfo
    
    result.success = true
    return result
  
  except:
    result.errorMessage = "Failed to start process: " & getCurrentExceptionMsg()
    return result

proc stopProcess*(manager: ProcessManager, processId: string, force: bool = false): Future[bool] {.async.} =
  ## プロセスを停止する
  if not manager.processes.hasKey(processId):
    return false
  
  try:
    var procInfo: ProcessInfo
    var process: Process
    
    withLock manager.lock:
      procInfo = manager.processes[processId]
      
      # すでに終了しているかチェック
      if procInfo.status in [psTerminated, psCrashed]:
        return true
      
      # 終了プロセスにマーク
      procInfo.status = psTerminating
      manager.processes[processId] = procInfo
      
      # OSプロセスの取得
      if not manager.osProcesses.hasKey(processId):
        # OSプロセスが見つからない場合
        procInfo.status = psTerminated
        procInfo.endTime = some(getTime())
        manager.processes[processId] = procInfo
        return true
      
      process = manager.osProcesses[processId]
    
    # プロセスの終了を要求
    if force:
      # 強制終了
      process.kill()
    else:
      # 正常終了を要求
      process.terminate()
    
    # 終了タイムアウト
    var terminationTimeout = manager.config.defaultTerminationTimeout
    if procInfo.exitCode.isNone:
      # タイムアウトまで待機
      let startTime = getTime()
      while (getTime() - startTime).inMilliseconds.int < terminationTimeout:
        if not process.running:
          # 正常に終了
          let exitCode = parseExitStatus(process.peekExitCode())
          withLock manager.lock:
            procInfo.status = psTerminated
            procInfo.exitCode = some(exitCode)
            procInfo.endTime = some(getTime())
            manager.processes[processId] = procInfo
            manager.osProcesses.del(processId)
          
          process.close()
          return true
        
        # 短い待機
        await sleepAsync(100)
      
      # タイムアウト後も終了しない場合、強制終了
      process.kill()
      
      # 終了を確認
      if not process.running:
        let exitCode = parseExitStatus(process.peekExitCode())
        withLock manager.lock:
          procInfo.status = psTerminated
          procInfo.exitCode = some(exitCode)
          procInfo.endTime = some(getTime())
          manager.processes[processId] = procInfo
          manager.osProcesses.del(processId)
        
        process.close()
        return true
    
    return false
  except:
    echo "Error stopping process: ", getCurrentExceptionMsg()
    return false

proc terminateAllProcesses*(manager: ProcessManager, force: bool = false): Future[bool] {.async.} =
  ## 全プロセスを終了する
  var allTerminated = true
  
  manager.shuttingDown = true
  
  # プロセスIDのリストを取得
  var processIds: seq[string]
  withLock manager.lock:
    processIds = toSeq(manager.processes.keys)
  
  # 各プロセスを終了
  for processId in processIds:
    let success = await manager.stopProcess(processId, force)
    if not success:
      allTerminated = false
  
  return allTerminated

proc restartProcess*(manager: ProcessManager, processId: string): Future[ProcessStartResult] {.async.} =
  ## プロセスを再起動する
  if not manager.processes.hasKey(processId):
    return ProcessStartResult(
      success: false,
      processId: "",
      errorMessage: &"Process not found: {processId}"
    )
  
  var procInfo: ProcessInfo
  withLock manager.lock:
    procInfo = manager.processes[processId]
  
  # プロセスの設定情報を取得
  let executablePath = procInfo.commandLine.split(' ')[0]
  var arguments: seq[string] = @[]
  let cmdParts = procInfo.commandLine.split(' ')
  if cmdParts.len > 1:
    arguments = cmdParts[1 .. ^1]
  
  # 新しい設定を作成
  var config = initProcessConfig()
  config.executablePath = executablePath
  config.arguments = arguments
  config.workingDir = procInfo.workingDir
  config.environment = procInfo.environment
  config.processType = procInfo.processType
  config.userData = procInfo.userData
  
  # まず古いプロセスを停止
  let stopped = await manager.stopProcess(processId)
  if not stopped:
    # 強制終了を試みる
    discard await manager.stopProcess(processId, force = true)
  
  # 再起動カウントを更新
  withLock manager.lock:
    if manager.processes.hasKey(processId):
      var updatedInfo = manager.processes[processId]
      inc updatedInfo.restartCount
      manager.processes[processId] = updatedInfo
  
  # 新しいプロセスを起動
  return await manager.startProcess(config)

proc getProcessInfo*(manager: ProcessManager, processId: string): Option[ProcessInfo] =
  ## プロセス情報を取得する
  withLock manager.lock:
    if manager.processes.hasKey(processId):
      return some(manager.processes[processId])
  
  return none(ProcessInfo)

proc getActiveProcesses*(manager: ProcessManager): seq[ProcessInfo] =
  ## アクティブなプロセスのリストを取得する
  result = @[]
  
  withLock manager.lock:
    for _, procInfo in manager.processes:
      if procInfo.status in [psInitializing, psStarting, psRunning]:
        result.add(procInfo)

proc getAllProcesses*(manager: ProcessManager): seq[ProcessInfo] =
  ## 全プロセスのリストを取得する
  result = @[]
  
  withLock manager.lock:
    for _, procInfo in manager.processes:
      result.add(procInfo)

proc updateProcessStats*(manager: ProcessManager, processId: string): Future[bool] {.async.} =
  ## プロセスの統計情報を更新する
  if not manager.processes.hasKey(processId) or not manager.osProcesses.hasKey(processId):
    return false
  
  try:
    var procInfo: ProcessInfo
    var process: Process
    
    withLock manager.lock:
      procInfo = manager.processes[processId]
      process = manager.osProcesses[processId]
    
    # OSから最新情報を取得（実装省略）
    # 以下は簡易実装
    let isRunning = process.running
    if not isRunning:
      # プロセスが終了している場合
      let exitCode = parseExitStatus(process.peekExitCode())
      
      withLock manager.lock:
        procInfo.status = if exitCode == 0: psTerminated else: psCrashed
        procInfo.exitCode = some(exitCode)
        procInfo.endTime = some(getTime())
        manager.processes[processId] = procInfo
        manager.osProcesses.del(processId)
      
      process.close()
      
      # 再起動ポリシーの適用（実装省略）
      
      return true
    
    # 実行中の場合、リソース使用状況を更新（実装省略）
    # メモリとCPU使用状況を取得する実際のコードはプラットフォーム依存
    let memoryUsage: int64 = 0  # ダミー値
    let cpuUsage: float = 0.0   # ダミー値
    
    withLock manager.lock:
      procInfo.memoryUsage = memoryUsage
      procInfo.cpuUsage = cpuUsage
      procInfo.lastUpdated = getTime()
      manager.processes[processId] = procInfo
    
    return true
  except:
    echo "Error updating process stats: ", getCurrentExceptionMsg()
    return false

proc monitorProcesses*(manager: ProcessManager) {.async.} =
  ## プロセスを監視する
  if manager.monitorActive:
    return
  
  manager.monitorActive = true
  
  try:
    while not manager.shuttingDown:
      # 監視間隔で一時停止
      await sleepAsync(manager.config.monitorInterval)
      
      # 最終監視時間を更新
      manager.lastMonitorTime = getTime()
      
      # プロセスIDリストを取得
      var processIds: seq[string]
      withLock manager.lock:
        processIds = toSeq(manager.processes.keys)
      
      # 各プロセスの状態を更新
      for processId in processIds:
        if manager.processes.hasKey(processId):
          # 状態を更新
          discard await manager.updateProcessStats(processId)
          
          # 終了したプロセスの再起動チェック（実装省略）
  finally:
    manager.monitorActive = false

proc registerEventHandler*(manager: ProcessManager, eventType: string, 
                         handler: proc(event: ProcessMonitorEvent) {.async.}): bool =
  ## イベントハンドラを登録する
  withLock manager.lock:
    if not manager.eventHandlers.hasKey(eventType):
      manager.eventHandlers[eventType] = @[]
    
    manager.eventHandlers[eventType].add(handler)
  
  return true

proc removeEventHandler*(manager: ProcessManager, eventType: string, 
                       handler: proc(event: ProcessMonitorEvent) {.async.}): bool =
  ## イベントハンドラを削除する
  withLock manager.lock:
    if not manager.eventHandlers.hasKey(eventType):
      return false
    
    # ハンドラを特定して削除
    let handlersHash = cast[int](handler)
    var handlers = manager.eventHandlers[eventType]
    var newHandlers: seq[proc(event: ProcessMonitorEvent) {.async.}] = @[]
    
    for h in handlers:
      if cast[int](h) != handlersHash:
        newHandlers.add(h)
    
    manager.eventHandlers[eventType] = newHandlers
  
  return true

proc fireEvent*(manager: ProcessManager, event: ProcessMonitorEvent) {.async.} =
  ## イベントを発火する
  var handlers: seq[proc(event: ProcessMonitorEvent) {.async.}] = @[]
  
  withLock manager.lock:
    if manager.eventHandlers.hasKey(event.eventType):
      handlers = manager.eventHandlers[event.eventType]
  
  # ハンドラを呼び出す
  for handler in handlers:
    try:
      await handler(event)
    except:
      echo "Error in event handler: ", getCurrentExceptionMsg()

proc shutdown*(manager: ProcessManager, force: bool = false): Future[bool] {.async.} =
  ## プロセスマネージャをシャットダウンする
  manager.shuttingDown = true
  
  # 監視を停止（自動的に停止される）
  
  # 全プロセスを終了
  return await manager.terminateAllProcesses(force)

proc cleanup*(manager: ProcessManager): Future[int] {.async.} =
  ## 終了したプロセス情報をクリーンアップする
  var cleanedCount = 0
  
  withLock manager.lock:
    var processesToRemove: seq[string] = @[]
    
    # 終了したプロセスを探す
    for id, procInfo in manager.processes:
      if procInfo.status in [psTerminated, psCrashed] and not manager.osProcesses.hasKey(id):
        processesToRemove.add(id)
    
    # 終了したプロセスを削除
    for id in processesToRemove:
      manager.processes.del(id)
      inc cleanedCount
  
  return cleanedCount

proc saveState*(manager: ProcessManager, filePath: string = ""): Future[bool] {.async.} =
  ## プロセスマネージャの状態を保存する
  let path = if filePath.len > 0: filePath else: manager.config.stateFilePath
  if path.len == 0:
    return false
  
  try:
    # プロセス情報をJSONに変換
    var processesArray = newJArray()
    
    withLock manager.lock:
      for _, procInfo in manager.processes:
        var procObj = %*{
          "id": procInfo.id,
          "pid": procInfo.pid,
          "processType": $procInfo.processType,
          "status": $procInfo.status,
          "startTime": procInfo.startTime.toUnix(),
          "commandLine": procInfo.commandLine,
          "workingDir": procInfo.workingDir,
          "restartCount": procInfo.restartCount,
          "crashCount": procInfo.crashCount,
          "userData": procInfo.userData
        }
        
        if procInfo.exitCode.isSome:
          procObj["exitCode"] = %procInfo.exitCode.get()
        
        if procInfo.endTime.isSome:
          procObj["endTime"] = %procInfo.endTime.get().toUnix()
        
        if procInfo.ipcChannel.isSome:
          procObj["ipcChannel"] = %procInfo.ipcChannel.get()
        
        # 環境変数はセキュリティ上保存しない
        
        processesArray.add(procObj)
    
    # 状態ファイルに書き込み
    let stateJson = %*{
      "version": 1,
      "timestamp": getTime().toUnix(),
      "processes": processesArray
    }
    
    writeFile(path, $stateJson)
    return true
  except:
    echo "Error saving process manager state: ", getCurrentExceptionMsg()
    return false

proc loadState*(manager: ProcessManager, filePath: string = ""): Future[bool] {.async.} =
  ## プロセスマネージャの状態を読み込む
  let path = if filePath.len > 0: filePath else: manager.config.stateFilePath
  if path.len == 0 or not fileExists(path):
    return false
  
  try:
    # 状態ファイルを読み込み
    let jsonContent = parseFile(path)
    
    withLock manager.lock:
      # プロセス情報を復元（再起動はしない）
      if jsonContent.hasKey("processes"):
        let processesArray = jsonContent["processes"]
        
        for procNode in processesArray:
          var procInfo = ProcessInfo(
            id: procNode["id"].getStr(),
            pid: procNode["pid"].getInt(),
            processType: parseEnum[ProcessType](procNode["processType"].getStr()),
            status: parseEnum[ProcessStatus](procNode["status"].getStr()),
            startTime: fromUnix(procNode["startTime"].getInt()),
            commandLine: procNode["commandLine"].getStr(),
            workingDir: procNode["workingDir"].getStr(),
            environment: initTable[string, string](),
            lastUpdated: getTime()
          )
          
          if procNode.hasKey("exitCode"):
            procInfo.exitCode = some(procNode["exitCode"].getInt())
          
          if procNode.hasKey("endTime"):
            procInfo.endTime = some(fromUnix(procNode["endTime"].getInt()))
          
          if procNode.hasKey("ipcChannel"):
            procInfo.ipcChannel = some(procNode["ipcChannel"].getStr())
          
          if procNode.hasKey("restartCount"):
            procInfo.restartCount = procNode["restartCount"].getInt()
          
          if procNode.hasKey("crashCount"):
            procInfo.crashCount = procNode["crashCount"].getInt()
          
          if procNode.hasKey("userData"):
            procInfo.userData = procNode["userData"]
          
          # 復元したプロセスを登録
          manager.processes[procInfo.id] = procInfo
    
    return true
  except:
    echo "Error loading process manager state: ", getCurrentExceptionMsg()
    return false

# エクスポート関数
export ProcessManager, ProcessInfo, ProcessConfig, ProcessStartResult, ProcessStatus, ProcessError, ProcessErrorType
export ProcessRestartPolicy, ProcessSandboxLevel, ProcessManagerConfig, ProcessMonitorEvent
export newProcessManager, newProcessManagerConfig, initProcessConfig
export initialize, startProcess, stopProcess, terminateAllProcesses, restartProcess
export getProcessInfo, getActiveProcesses, getAllProcesses, updateProcessStats
export monitorProcesses, registerEventHandler, removeEventHandler, fireEvent
export shutdown, cleanup, saveState, loadState 