import std/[os, osproc, tables, times, strutils, json, logging]
import std/[asyncdispatch, asyncfutures]

type
  ProcessSeparationMode* = enum
    psmNone,        # プロセス分離なし
    psmSandbox,     # サンドボックス内で実行
    psmContainer,   # コンテナ内で実行
    psmVM           # 仮想マシン内で実行

  ProcessPriority* = enum
    ppLow,          # 低優先度
    ppNormal,       # 通常優先度
    ppHigh,         # 高優先度
    ppRealtime      # リアルタイム優先度

  ProcessState* = enum
    psCreated,      # 作成済み
    psRunning,      # 実行中
    psSuspended,    # 一時停止中
    psTerminated,   # 終了済み
    psCrashed       # クラッシュ

  ProcessInfo* = ref object
    pid*: int                       # プロセスID
    name*: string                   # プロセス名
    command*: string                # 実行コマンド
    workingDir*: string            # 作業ディレクトリ
    separationMode*: ProcessSeparationMode  # 分離モード
    priority*: ProcessPriority      # 優先度
    state*: ProcessState            # 状態
    startTime*: Time               # 開始時刻
    endTime*: Time                 # 終了時刻
    exitCode*: int                  # 終了コード
    cpuUsage*: float               # CPU使用率
    memoryUsage*: int64           # メモリ使用量
    parentPid*: int                # 親プロセスID
    children*: seq[int]            # 子プロセスID
    env*: TableRef[string, string] # 環境変数

  ResourceLimits* = object
    maxCpuTime*: int               # 最大CPU時間(秒)
    maxMemory*: int64             # 最大メモリ使用量(バイト)
    maxProcesses*: int             # 最大プロセス数
    maxFileSize*: int64           # 最大ファイルサイズ
    maxOpenFiles*: int             # 最大オープンファイル数

  ProcessManager* = ref object
    processes*: TableRef[int, ProcessInfo]  # プロセス情報
    resourceLimits*: ResourceLimits         # リソース制限
    logger*: Logger                         # ロガー

proc newProcessManager*(resourceLimits: ResourceLimits = ResourceLimits()): ProcessManager =
  ## 新しいプロセスマネージャーを作成
  result = ProcessManager(
    processes: newTable[int, ProcessInfo](),
    resourceLimits: resourceLimits,
    logger: newConsoleLogger()
  )

proc createProcess*(pm: ProcessManager, command: string, options: ProcessOptions = {}): Future[ProcessInfo] {.async.} =
  ## 新しいプロセスを作成
  var process = startProcess(command, options = options)
  
  var info = ProcessInfo(
    pid: process.processID,
    name: extractFilename(command),
    command: command,
    workingDir: getCurrentDir(),
    separationMode: psmNone,
    priority: ppNormal,
    state: psCreated,
    startTime: getTime(),
    env: newTable[string, string]()
  )

  pm.processes[info.pid] = info
  pm.logger.log(lvlInfo, "Process created: " & $info.pid)
  
  return info

proc terminateProcess*(pm: ProcessManager, pid: int) {.async.} =
  ## プロセスを終了
  if pid notin pm.processes:
    pm.logger.log(lvlError, "Process not found: " & $pid)
    return

  var info = pm.processes[pid]
  if info.state in {psTerminated, psCrashed}:
    return

  try:
    killProcess(pid)
    info.state = psTerminated
    info.endTime = getTime()
    pm.logger.log(lvlInfo, "Process terminated: " & $pid)
  except:
    pm.logger.log(lvlError, "Failed to terminate process: " & $pid)

proc suspendProcess*(pm: ProcessManager, pid: int) {.async.} =
  ## プロセスを一時停止
  if pid notin pm.processes:
    pm.logger.log(lvlError, "Process not found: " & $pid)
    return

  var info = pm.processes[pid]
  if info.state != psRunning:
    return

  try:
    # プロセスにSIGSTOPシグナルを送信
    discard execCmd("kill -STOP " & $pid)
    info.state = psSuspended
    pm.logger.log(lvlInfo, "Process suspended: " & $pid)
  except:
    pm.logger.log(lvlError, "Failed to suspend process: " & $pid)

proc resumeProcess*(pm: ProcessManager, pid: int) {.async.} =
  ## プロセスを再開
  if pid notin pm.processes:
    pm.logger.log(lvlError, "Process not found: " & $pid)
    return

  var info = pm.processes[pid]
  if info.state != psSuspended:
    return

  try:
    # プロセスにSIGCONTシグナルを送信
    discard execCmd("kill -CONT " & $pid)
    info.state = psRunning
    pm.logger.log(lvlInfo, "Process resumed: " & $pid)
  except:
    pm.logger.log(lvlError, "Failed to resume process: " & $pid)

proc handleCrash*(pm: ProcessManager, pid: int, exitCode: int) {.async.} =
  ## プロセスのクラッシュを処理
  if pid notin pm.processes:
    return

  var info = pm.processes[pid]
  info.state = psCrashed
  info.endTime = getTime()
  info.exitCode = exitCode
  
  pm.logger.log(lvlError, "Process crashed: " & $pid & " (exit code: " & $exitCode & ")")

  # 子プロセスも終了
  for childPid in info.children:
    await pm.terminateProcess(childPid)

proc updateResourceUsage*(pm: ProcessManager) {.async.} =
  ## プロセスのリソース使用状況を更新
  for pid, info in pm.processes:
    if info.state != psRunning:
      continue

    try:
      # /proc/[pid]/statからCPU使用率を取得
      let statFile = "/proc/" & $pid & "/stat"
      if fileExists(statFile):
        let stat = readFile(statFile).split(" ")
        let utime = parseInt(stat[13])
        let stime = parseInt(stat[14])
        info.cpuUsage = (utime.float + stime.float) / 100.0

      # /proc/[pid]/statmからメモリ使用量を取得
      let statmFile = "/proc/" & $pid & "/statm"
      if fileExists(statmFile):
        let statm = readFile(statmFile).split(" ")
        info.memoryUsage = parseInt(statm[1]) * 4096 # ページサイズ(4KB)を掛ける

      # リソース制限をチェック
      if pm.resourceLimits.maxCpuTime > 0 and info.cpuUsage > pm.resourceLimits.maxCpuTime.float:
        await pm.terminateProcess(pid)
        pm.logger.log(lvlWarn, "Process terminated due to CPU limit: " & $pid)

      if pm.resourceLimits.maxMemory > 0 and info.memoryUsage > pm.resourceLimits.maxMemory:
        await pm.terminateProcess(pid)
        pm.logger.log(lvlWarn, "Process terminated due to memory limit: " & $pid)

    except:
      pm.logger.log(lvlError, "Failed to update resource usage for process: " & $pid)

proc generateReport*(pm: ProcessManager): JsonNode =
  ## プロセス管理レポートを生成
  result = %*{
    "processes": [],
    "total_processes": len(pm.processes),
    "running_processes": 0,
    "suspended_processes": 0,
    "terminated_processes": 0,
    "crashed_processes": 0
  }

  var processes = result["processes"]
  for pid, info in pm.processes:
    var processInfo = %*{
      "pid": info.pid,
      "name": info.name,
      "command": info.command,
      "working_dir": info.workingDir,
      "separation_mode": $info.separationMode,
      "priority": $info.priority,
      "state": $info.state,
      "start_time": $info.startTime,
      "cpu_usage": info.cpuUsage,
      "memory_usage": info.memoryUsage,
      "parent_pid": info.parentPid,
      "children": info.children
    }

    if info.state in {psTerminated, psCrashed}:
      processInfo["end_time"] = %($info.endTime)
      processInfo["exit_code"] = %info.exitCode

    processes.add(processInfo)

    case info.state
    of psRunning: inc(result["running_processes"].num)
    of psSuspended: inc(result["suspended_processes"].num)
    of psTerminated: inc(result["terminated_processes"].num)
    of psCrashed: inc(result["crashed_processes"].num)
    else: discard

proc cleanup*(pm: ProcessManager) {.async.} =
  ## 終了したプロセスのクリーンアップ
  var toRemove: seq[int] = @[]
  
  for pid, info in pm.processes:
    if info.state in {psTerminated, psCrashed}:
      # 24時間以上経過した終了プロセスを削除
      if getTime() - info.endTime > initDuration(hours = 24):
        toRemove.add(pid)

  for pid in toRemove:
    pm.processes.del(pid)
    pm.logger.log(lvlInfo, "Cleaned up process: " & $pid)

proc monitorProcesses*(pm: ProcessManager) {.async.} =
  ## プロセスの監視を開始
  while true:
    await pm.updateResourceUsage()
    await pm.cleanup()
    await sleepAsync(1000) # 1秒ごとに更新 