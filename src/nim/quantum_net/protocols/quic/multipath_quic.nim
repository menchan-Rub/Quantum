# マルチパスQUIC実装
# RFC 9000拡張による複数ネットワークパス同時利用実装

import std/[asyncdispatch, tables, sets, hashes, options, deques, monotimes]
import std/[strutils, times, strformat, sugar, sequtils, algorithm]
import ../../security/tls/tls_client
import ../../../quantum_arch/data/varint
import ../../../quantum_arch/memory/memory_manager
import ../../../compression/common/buffer

# マルチパスQUIC標準化ドラフト対応
# https://datatracker.ietf.org/doc/html/draft-ietf-quic-multipath

type
  PathState* = enum
    psNew,           # 新規作成パス
    psValidating,    # 検証中
    psActive,        # アクティブ状態
    psStandby,       # スタンバイ状態
    psDraining,      # ドレイン状態
    psClosed         # クローズ状態

  PathStatistics* = object
    rtt*: Duration               # 往復時間
    rttVar*: Duration            # RTT分散
    minRtt*: Duration            # 最小RTT
    congestionWindow*: uint64    # 輻輳ウィンドウ
    bytesInFlight*: uint64       # 未確認バイト数
    bytesSent*: uint64           # 送信総バイト数
    bytesReceived*: uint64       # 受信総バイト数
    packetsSent*: uint64         # 送信パケット数
    packetsReceived*: uint64     # 受信パケット数
    packetsLost*: uint64         # 損失パケット数
    lossRate*: float64           # パケット損失率
    linkCapacity*: float64       # リンク容量推定(Mbps)
    lastActiveTime*: MonoTime    # 最終アクティブ時間

  # パスレスポンスハンドラの型定義
  PathResponseHandler* = proc(responseData: seq[byte]): void

  MultiPathCongestionController* = ref object
    pathCwnd*: Table[PathId, uint64]       # パス別輻輳ウィンドウ
    pathSsthresh*: Table[PathId, uint64]   # パス別スロースタート閾値
    pathRecovery*: Table[PathId, bool]     # パス別回復状態
    aggregateCwnd*: uint64                 # 集約輻輳ウィンドウ
    maxAggregateWindow*: uint64            # 最大集約ウィンドウ
    bandwidthWeights*: Table[PathId, float] # 帯域幅重み付け
    lastSchedulingTime*: MonoTime          # 最終スケジューリング時間

  PathId* = tuple
    localAddr: string
    remoteAddr: string
    localConnId: seq[byte]
    remoteConnId: seq[byte]

  MultiPathStrategy* = enum
    mpsLowestRtt,       # 最小RTTパス優先
    mpsRoundRobin,      # ラウンドロビン
    mpsBandwidthAware,  # 帯域幅重み付け
    mpsRedundant,       # 冗長送信
    mpsAdaptive         # 適応型(AI支援)

  NetworkType* = enum
    ntWifi,             # WiFiネットワーク
    ntCellular,         # モバイルネットワーク
    ntEthernet,         # 有線接続
    ntSatellite,        # 衛星通信
    ntUnknown           # 不明

  BatteryState* = enum
    bsCharging,         # 充電中
    bsDischarging,      # 放電中
    bsUnknown           # 不明

  DeviceContext* = object
    batteryState*: BatteryState
    batteryLevel*: float
    networkTypes*: Table[PathId, NetworkType]
    isLowPowerMode*: bool
    isBackgroundMode*: bool

  MultiPathScheduler* = ref object
    paths*: Table[PathId, Path]
    activePathIds*: seq[PathId]
    standbyPathIds*: seq[PathId]
    currentStrategy*: MultiPathStrategy
    deviceContext*: DeviceContext
    priorityFrames*: HashSet[QuicFrameType]
    lastUsedPathIndex*: int
    frameQueuePerPath*: Table[PathId, Deque[QuicFrame]]
    pendingFrames*: Deque[QuicFrame]
    mpController*: MultiPathCongestionController
    sendPacketCallback*: proc(pathId: PathId, packet: QuicPacket): Future[void]
    responseHandlers*: Table[PathId, PathResponseHandler]  # パスごとのレスポンスハンドラ
    pathResponseLock*: Lock   # 並行アクセス保護用ロック

  Path* = ref object
    id*: PathId
    state*: PathState
    challengeData*: seq[byte]
    challengeTime*: MonoTime
    validationTimeout*: Duration
    lastPacketSentTime*: MonoTime
    lastPacketRecvTime*: MonoTime
    pathMtu*: uint16
    stats*: PathStatistics
    enabled*: bool
    pathPreference*: uint8 # パス優先度 (0-255)
    networkType*: NetworkType
    nextPacketNumber*: uint64
    unackedPackets*: Table[uint64, (seq[byte], MonoTime)]
    pathActivateTime*: MonoTime

const
  PATH_VALIDATION_TIMEOUT = initDuration(seconds=5)
  PATH_MTU_DISCOVERY_INTERVAL = initDuration(minutes=10)
  MAX_ACTIVE_PATHS = 8          # 同時アクティブパス最大数
  MAX_PATH_CANDIDATES = 16      # 候補パス最大数
  PATH_STANDBY_TIMEOUT = initDuration(minutes=2)
  CHALLENGE_DATA_SIZE = 8       # パス検証用チャレンジデータサイズ
  MAX_PATH_RTT_RATIO = 3.0      # 最小RTTと比較した最大比率
  MIN_PACKETS_FOR_RTT = 10      # RTT計算に必要な最小パケット数
  CONGESTION_FEEDBACK_INTERVAL = 50 # 輻輳フィードバックパケット間隔
  PATH_STATISTICS_SAMPLING = 100 # パス統計サンプリング回数

# 乱数生成
proc generateRandomBytes(size: int): seq[byte] =
  result = newSeq[byte](size)
  for i in 0..<size:
    result[i] = byte(rand(0..255))

# 新しいマルチパススケジューラの作成
proc newMultiPathScheduler*(): MultiPathScheduler =
  let mpController = MultiPathCongestionController(
    pathCwnd: initTable[PathId, uint64](),
    pathSsthresh: initTable[PathId, uint64](),
    pathRecovery: initTable[PathId, bool](),
    aggregateCwnd: 10 * 1350, # 初期10パケット
    maxAggregateWindow: 16_000_000, # 16MB
    bandwidthWeights: initTable[PathId, float](),
    lastSchedulingTime: getMonoTime()
  )
  
  result = MultiPathScheduler(
    paths: initTable[PathId, Path](),
    activePathIds: @[],
    standbyPathIds: @[],
    currentStrategy: mpsAdaptive, # デフォルトはAI支援適応型
    priorityFrames: toHashSet([ftConnectionClose, ftHandshakeDone, ftAck]),
    lastUsedPathIndex: 0,
    frameQueuePerPath: initTable[PathId, Deque[QuicFrame]](),
    pendingFrames: initDeque[QuicFrame](),
    mpController: mpController,
    deviceContext: DeviceContext(
      batteryState: bsUnknown,
      batteryLevel: 1.0,
      networkTypes: initTable[PathId, NetworkType](),
      isLowPowerMode: false,
      isBackgroundMode: false
    ),
    responseHandlers: initTable[PathId, PathResponseHandler](),
    pathResponseLock: Lock()
  )

# パス追加
proc addPath*(scheduler: MultiPathScheduler, localAddr, remoteAddr: string, 
               localConnId, remoteConnId: seq[byte], mtu: uint16 = 1350,
               networkType: NetworkType = ntUnknown): PathId =
  
  let pathId = (localAddr, remoteAddr, localConnId, remoteConnId)
  
  # パスが既に存在する場合は既存のIDを返す
  if scheduler.paths.hasKey(pathId):
    return pathId
    
  # 新しいパスを作成
  let path = Path(
    id: pathId,
    state: psNew,
    challengeData: generateRandomBytes(CHALLENGE_DATA_SIZE),
    challengeTime: getMonoTime(),
    validationTimeout: PATH_VALIDATION_TIMEOUT,
    lastPacketSentTime: getMonoTime(),
    lastPacketRecvTime: getMonoTime(),
    pathMtu: mtu,
    stats: PathStatistics(
      rtt: initDuration(milliseconds=100),  # 初期推定値
      rttVar: initDuration(milliseconds=50),
      minRtt: initDuration(milliseconds=100),
      congestionWindow: 10 * mtu.uint64, # 初期10パケット
      bytesInFlight: 0,
      bytesSent: 0,
      bytesReceived: 0,
      packetsSent: 0,
      packetsReceived: 0,
      packetsLost: 0,
      lossRate: 0.0,
      linkCapacity: 10.0, # 初期推定10Mbps
      lastActiveTime: getMonoTime()
    ),
    enabled: true,
    pathPreference: 128, # デフォルト中間値
    networkType: networkType,
    nextPacketNumber: 0,
    unackedPackets: initTable[uint64, (seq[byte], MonoTime)](),
    pathActivateTime: getMonoTime()
  )
  
  # パス登録
  scheduler.paths[pathId] = path
  
  # 輻輳制御初期設定
  scheduler.mpController.pathCwnd[pathId] = path.stats.congestionWindow
  scheduler.mpController.pathSsthresh[pathId] = high(uint64)
  scheduler.mpController.pathRecovery[pathId] = false
  
  # デバイスコンテキスト追加
  scheduler.deviceContext.networkTypes[pathId] = networkType
  
  # パスごとのフレームキュー初期化
  scheduler.frameQueuePerPath[pathId] = initDeque[QuicFrame]()
  
  # 帯域幅重み初期化
  scheduler.mpController.bandwidthWeights[pathId] = 1.0
  
  # パス検証開始
  path.state = psValidating
  
  return pathId

# パス検証
proc validatePath*(scheduler: MultiPathScheduler, pathId: PathId): Future[bool] {.async.} =
  if not scheduler.paths.hasKey(pathId):
    return false
    
  var path = scheduler.paths[pathId]
  
  if path.state != psValidating:
    # 既に検証済みまたは検証中でない場合
    return path.state == psActive or path.state == psStandby
  
  # PATH_CHALLENGEフレーム送信
  # フレーム構築
  let challengeFrame = QuicPathChallengeFrame(
    data: path.challengeData
  )
  
  # チャレンジフレームを含むパケットを構築
  var packet = newQuicPacket(ptOneRtt)
  packet.frames.add(challengeFrame)
  
  # 送信処理はコンテキストに応じて変わるため、送信コールバックを使用
  if scheduler.sendPacketCallback.isNil:
    raise newException(ValueError, "送信コールバックが設定されていません")
  
  # コールバックを使用してパケット送信
  await scheduler.sendPacketCallback(pathId, packet)
  
  # レスポンス待機
  var responseReceived = false
  let deadline = path.challengeTime + path.validationTimeout
  
  # 効率的な応答処理のためにイベント/タイマーを使用
  let pathResponseEvent = newAsyncEvent()
  
  # 応答受信ハンドラを設定（グローバルハンドラで呼び出される）
  proc handlePathResponse(responseData: seq[byte]): void =
    # チャレンジデータと応答データを照合
    if responseData == path.challengeData:
      responseReceived = true
      pathResponseEvent.fire()
  
  # グローバルハンドラに登録
  scheduler.registerPathResponseHandler(pathId, handlePathResponse)
  
  # タイムアウト処理
  let timeoutFuture = sleepAsync((deadline - getMonoTime()).inMilliseconds.int)
  let responseFuture = pathResponseEvent.wait()
  
  # いずれかのイベントが完了するまで待機
  if await withTimeoutOrSignal(timeoutFuture, responseFuture):
    # 応答イベントが先に完了 = 成功
    responseReceived = true
  else:
    # タイムアウトが先に完了 = 失敗
    responseReceived = false
  
  # ハンドラ登録解除
  scheduler.unregisterPathResponseHandler(pathId)
  
  if responseReceived:
    # パス検証成功
    path.state = psStandby
    
    # アクティブパスが少ない場合は即座にアクティブ化
    if scheduler.activePathIds.len < MAX_ACTIVE_PATHS:
      path.state = psActive
      scheduler.activePathIds.add(pathId)
    else:
      scheduler.standbyPathIds.add(pathId)
    
    return true
  else:
    # パス検証失敗
    path.state = psClosed
    return false

# パスを選択（スケジューリング戦略に基づく）
proc selectPath*(scheduler: MultiPathScheduler, frame: QuicFrame): PathId =
  # 優先フレームはすべてのアクティブパスで送信
  if frame.frameType in scheduler.priorityFrames and scheduler.activePathIds.len > 0:
    return scheduler.activePathIds[0] # 最初のパスを使用
  
  # アクティブパスがない場合
  if scheduler.activePathIds.len == 0:
    # 検証済みスタンバイパスがあればアクティブ化
    if scheduler.standbyPathIds.len > 0:
      let newActivePath = scheduler.standbyPathIds[0]
      scheduler.standbyPathIds.delete(0)
      scheduler.activePathIds.add(newActivePath)
      scheduler.paths[newActivePath].state = psActive
    else:
      # パスがない場合はエラー
      raise newException(IOError, "No available paths")
  
  # 現在の戦略に基づいてパスを選択
  case scheduler.currentStrategy
  of mpsLowestRtt:
    # 最小RTTパス選択
    var minRtt = initDuration(seconds = high(int))
    var selectedPathId: PathId
    
    for pathId in scheduler.activePathIds:
      let path = scheduler.paths[pathId]
      if path.stats.rtt < minRtt:
        minRtt = path.stats.rtt
        selectedPathId = pathId
    
    return selectedPathId
    
  of mpsRoundRobin:
    # ラウンドロビン選択
    scheduler.lastUsedPathIndex = (scheduler.lastUsedPathIndex + 1) mod scheduler.activePathIds.len
    return scheduler.activePathIds[scheduler.lastUsedPathIndex]
    
  of mpsBandwidthAware:
    # 帯域幅重み付けによる選択
    # トークンバケットに基づくスケジューリング
    var maxWeight = 0.0
    var selectedPathId = scheduler.activePathIds[0]
    
    for pathId in scheduler.activePathIds:
      let weight = scheduler.mpController.bandwidthWeights[pathId]
      if weight > maxWeight:
        maxWeight = weight
        selectedPathId = pathId
    
    return selectedPathId
    
  of mpsRedundant:
    # 冗長モードでは単一フレーム選択に意味がないが、
    # 実装のためにラウンドロビンを使用
    scheduler.lastUsedPathIndex = (scheduler.lastUsedPathIndex + 1) mod scheduler.activePathIds.len
    return scheduler.activePathIds[scheduler.lastUsedPathIndex]
    
  of mpsAdaptive:
    # 適応型選択（AI支援）
    
    # 低バッテリーモードの場合
    if scheduler.deviceContext.isLowPowerMode or 
       (scheduler.deviceContext.batteryState == bsDischarging and
        scheduler.deviceContext.batteryLevel < 0.2):
      # 電力効率の良いパスを優先
      for pathId in scheduler.activePathIds:
        if scheduler.deviceContext.networkTypes[pathId] == ntWifi:
          return pathId
    
    # ストリーミングや大容量転送の場合
    if isLargeDataTransfer(frame):
      # 帯域幅が最も広いパスを選択
      var maxCapacity = 0.0
      var selectedPathId = scheduler.activePathIds[0]
      
      for pathId in scheduler.activePathIds:
        let capacity = scheduler.paths[pathId].stats.linkCapacity
        if capacity > maxCapacity:
          maxCapacity = capacity
          selectedPathId = pathId
          
      return selectedPathId
    
    # インタラクティブトラフィック（小さいフレーム）
    if isInteractiveTraffic(frame):
      # 最小RTTパス選択
      var minRtt = initDuration(seconds = high(int))
      var selectedPathId = scheduler.activePathIds[0]
      
      for pathId in scheduler.activePathIds:
        let path = scheduler.paths[pathId]
        if path.stats.rtt < minRtt:
          minRtt = path.stats.rtt
          selectedPathId = pathId
      
      return selectedPathId
    
    # デフォルトは重み付け帯域幅
    var totalWeight = 0.0
    for pathId in scheduler.activePathIds:
      totalWeight += scheduler.mpController.bandwidthWeights[pathId]
    
    let randomValue = rand(totalWeight)
    var cumulativeWeight = 0.0
    
    for pathId in scheduler.activePathIds:
      cumulativeWeight += scheduler.mpController.bandwidthWeights[pathId]
      if randomValue <= cumulativeWeight:
        return pathId
    
    # フォールバック
    return scheduler.activePathIds[0]

proc isLargeDataTransfer(frame: QuicFrame): bool =
  # STREAMフレームで大きいデータを運ぶ場合を判定
  if frame.frameType == ftStream:
    let streamFrame = cast[QuicStreamFrame](frame)
    return streamFrame.data.len > 1000 # 1KB以上を大容量転送と見なす
  return false

proc isInteractiveTraffic(frame: QuicFrame): bool =
  # インタラクティブトラフィックの判定
  # STREAMフレームの小さなデータやPINGなど
  if frame.frameType == ftStream:
    let streamFrame = cast[QuicStreamFrame](frame)
    return streamFrame.data.len < 200 # 200バイト未満を対話型と見なす
  
  return frame.frameType in {ftPing, ftAck, ftConnectionClose}

# パス状態更新
proc updatePathStatistics*(scheduler: MultiPathScheduler, pathId: PathId, 
                          rttSample: Option[Duration] = none(Duration),
                          bytesSent: uint64 = 0, bytesReceived: uint64 = 0,
                          packetsLost: uint64 = 0) =
  if not scheduler.paths.hasKey(pathId):
    return
  
  var path = scheduler.paths[pathId]
  
  # 統計更新
  path.stats.bytesSent += bytesSent
  path.stats.bytesReceived += bytesReceived
  path.stats.packetsSent += if bytesSent > 0: 1 else: 0
  path.stats.packetsReceived += if bytesReceived > 0: 1 else: 0
  path.stats.packetsLost += packetsLost
  
  if path.stats.packetsSent > 0:
    path.stats.lossRate = path.stats.packetsLost.float / path.stats.packetsSent.float
  
  # RTT更新
  if rttSample.isSome:
    let newRtt = rttSample.get
    
    # RFC 6298のRTT平滑化アルゴリズム
    let alpha = 0.125  # 1/8
    let beta = 0.25    # 1/4
    
    # 初回RTTサンプルの場合
    if path.stats.minRtt.inMilliseconds == 100: # 初期値
      path.stats.rtt = newRtt
      path.stats.rttVar = newRtt / 2
      path.stats.minRtt = newRtt
    else:
      # RTT変動計算
      path.stats.rttVar = (1.0 - beta) * path.stats.rttVar + 
                          beta * abs(path.stats.rtt - newRtt)
      
      # 平滑化RTT計算
      path.stats.rtt = (1.0 - alpha) * path.stats.rtt + alpha * newRtt
      
      # 最小RTT更新
      if newRtt < path.stats.minRtt:
        path.stats.minRtt = newRtt
  
  # リンク容量推定（シンプルな推定）
  if path.stats.packetsSent > MIN_PACKETS_FOR_RTT and path.stats.rtt.inNanoseconds > 0:
    # 最近の送信スループットからリンク容量を推定
    let recentThroughputMbps = 
      (path.stats.bytesSent.float * 8.0 / 1_000_000.0) / 
      (path.stats.rtt.inMilliseconds.float / 1000.0)
    
    # 指数平滑化でリンク容量を更新
    path.stats.linkCapacity = 
      0.9 * path.stats.linkCapacity + 0.1 * recentThroughputMbps
  
  # 最終アクティブ時間更新
  path.stats.lastActiveTime = getMonoTime()
  
  # 輻輳制御更新
  if packetsLost > 0:
    # パケットロスを検出した場合、輻輳回避モードに移行
    scheduler.mpController.pathSsthresh[pathId] = 
      max(scheduler.mpController.pathCwnd[pathId] div 2, 2 * path.pathMtu.uint64)
    scheduler.mpController.pathCwnd[pathId] = scheduler.mpController.pathSsthresh[pathId]
    scheduler.mpController.pathRecovery[pathId] = true
  elif rttSample.isSome:
    # 正常なACKの場合
    let cwnd = scheduler.mpController.pathCwnd[pathId]
    let ssthresh = scheduler.mpController.pathSsthresh[pathId]
    
    if cwnd < ssthresh:
      # スロースタート: 各ACKごとにウィンドウを1MSS増やす
      scheduler.mpController.pathCwnd[pathId] += path.pathMtu.uint64
    else:
      # 輻輳回避: 各ACKごとに1/cwnd MSS増やす
      scheduler.mpController.pathCwnd[pathId] += 
        (path.pathMtu.uint64 * path.pathMtu.uint64) div cwnd
    
    # 回復モードを終了
    scheduler.mpController.pathRecovery[pathId] = false
  
  # パス帯域幅の重み更新
  updatePathWeights(scheduler)

# パス帯域幅の重み更新
proc updatePathWeights(scheduler: MultiPathScheduler) =
  # アクティブパスがない場合
  if scheduler.activePathIds.len == 0:
    return
  
  # 各パスの最新リンク容量情報を使用してウェイトを更新
  var totalCapacity = 0.0
  for pathId in scheduler.activePathIds:
    let path = scheduler.paths[pathId]
    totalCapacity += path.stats.linkCapacity
  
  # 重み計算
  for pathId in scheduler.activePathIds:
    let path = scheduler.paths[pathId]
    if totalCapacity > 0:
      # 相対的な帯域幅の割合をウェイトとして設定
      scheduler.mpController.bandwidthWeights[pathId] = 
        path.stats.linkCapacity / totalCapacity
    else:
      # 均等配分
      scheduler.mpController.bandwidthWeights[pathId] = 
        1.0 / scheduler.activePathIds.len.float

# パスの健全性チェックと最適化
proc optimizePaths*(scheduler: MultiPathScheduler): Future[void] {.async.} =
  # アクティブパスの健全性確認
  var unhealthyPaths: seq[PathId] = @[]
  
  for pathId in scheduler.activePathIds:
    let path = scheduler.paths[pathId]
    let now = getMonoTime()
    
    # 長時間アイドル状態のパスをチェック
    if now - path.stats.lastActiveTime > initDuration(seconds=30):
      # パスがアイドル状態 - PINGで生存確認
      # アイドル状態のパスにPINGフレームを送信して生存確認
      let pingFrame = QuicPingFrame(
        frameType: ftPing
      )
      
      # PINGフレームを含むパケットを構築
      var packet = newQuicPacket(ptOneRtt)
      packet.frames.add(pingFrame)
      
      # コールバックを使用してパケット送信
      if not scheduler.sendPacketCallback.isNil:
        try:
          asyncCheck scheduler.sendPacketCallback(pathId, packet)
          
          # 統計を更新
          path.lastPacketSentTime = now
          path.stats.packetsSent += 1
        except:
          # 送信エラーは記録するが処理は続行
          echo "Failed to send PING on path: ", getCurrentExceptionMsg()
    
    # パフォーマンスの悪いパスを特定
    if path.stats.packetsLost > 50 and path.stats.lossRate > 0.1:
      # 損失率10%超は不健全とみなす
      unhealthyPaths.add(pathId)
    
    # 極端に長いRTTのパスを特定
    let minRttPath = block:
      var minRtt = initDuration(seconds=high(int))
      var result: PathId
      for pid in scheduler.activePathIds:
        if scheduler.paths[pid].stats.rtt < minRtt:
          minRtt = scheduler.paths[pid].stats.rtt
          result = pid
      result
    
    let minRtt = scheduler.paths[minRttPath].stats.rtt
    
    if path.stats.rtt > minRtt * MAX_PATH_RTT_RATIO:
      # 最小RTTの3倍以上のRTTは不健全とみなす
      unhealthyPaths.add(pathId)
  
  # 不健全パスをスタンバイに移動
  for pathId in unhealthyPaths:
    if scheduler.activePathIds.len > 1:  # 最低1つはアクティブパスを維持
      scheduler.paths[pathId].state = psStandby
      scheduler.activePathIds.keepItIf(pid => pid != pathId)
      scheduler.standbyPathIds.add(pathId)
  
  # スタンバイパスの再評価
  var pathsToActivate: seq[PathId] = @[]
  
  for pathId in scheduler.standbyPathIds:
    let path = scheduler.paths[pathId]
    
    # 一定時間経過したパスを再評価
    if getMonoTime() - path.stats.lastActiveTime > initDuration(minutes=1):
      # パス再検証 (PATH_CHALLENGEで計測)
      var newRtt: Option[Duration]
      
      # パスが有効かつ応答可能かを確認するためのチャレンジを送信
      let challengeData = generateRandomBytes(CHALLENGE_DATA_SIZE)
      let challengeFrame = QuicPathChallengeFrame(
        frameType: ftPathChallenge,
        data: challengeData
      )
      
      # パケット構築
      var packet = newQuicPacket(ptOneRtt)
      packet.frames.add(challengeFrame)
      
      # 送信時間記録
      let sendTime = getMonoTime()
      
      # 応答待機用の設定
      var responseReceived = false
      var receiveTime: MonoTime
      let responseEvent = newAsyncEvent()
      
      # 応答ハンドラを設定
      proc handleRevalidationResponse(responseData: seq[byte]): void =
        if responseData == challengeData:
          responseReceived = true
          receiveTime = getMonoTime()
          responseEvent.fire()
      
      # ハンドラ登録
      scheduler.registerPathResponseHandler(pathId, handleRevalidationResponse)
      
      # パケット送信
      if not scheduler.sendPacketCallback.isNil:
        try:
          await scheduler.sendPacketCallback(pathId, packet)
          
          # 短いタイムアウトでレスポンス待機（最大500ms）
          let timeoutFuture = sleepAsync(500)
          let responseFuture = responseEvent.wait()
          
          if await withTimeoutOrSignal(timeoutFuture, responseFuture):
            # 応答受信成功、RTT計算
            let rtt = receiveTime - sendTime
            newRtt = some(rtt)
            
            # パス統計更新
            path.stats.lastPacketSentTime = sendTime
            path.stats.lastPacketRecvTime = receiveTime
            path.stats.packetsSent += 1
            path.stats.packetsReceived += 1
          
        except:
          echo "Failed to send path challenge: ", getCurrentExceptionMsg()
      
      # ハンドラ登録解除
      scheduler.unregisterPathResponseHandler(pathId)
      
      # RTTサンプルが取得できた場合は統計を更新
      if newRtt.isSome:
        updatePathStatistics(scheduler, pathId, rttSample = newRtt)
      
      # アクティブにするための条件確認
      if newRtt.isSome and scheduler.activePathIds.len < MAX_ACTIVE_PATHS:
        pathsToActivate.add(pathId)
  
  # スタンバイパスをアクティブ化
  for pathId in pathsToActivate:
    scheduler.paths[pathId].state = psActive
    scheduler.standbyPathIds.keepItIf(pid => pid != pathId)
    scheduler.activePathIds.add(pathId)
  
  # 帯域幅重みの再計算
  updatePathWeights(scheduler)

# パスレスポンスハンドラの登録
proc registerPathResponseHandler*(scheduler: MultiPathScheduler, pathId: PathId, handler: PathResponseHandler) =
  withLock(scheduler.pathResponseLock):
    scheduler.responseHandlers[pathId] = handler

# パスレスポンスハンドラの登録解除
proc unregisterPathResponseHandler*(scheduler: MultiPathScheduler, pathId: PathId) =
  withLock(scheduler.pathResponseLock):
    if scheduler.responseHandlers.hasKey(pathId):
      scheduler.responseHandlers.del(pathId)

# パスレスポンスの処理（外部からのPATH_RESPONSEフレーム受信時に呼び出し）
proc processPathResponse*(scheduler: MultiPathScheduler, pathId: PathId, responseData: seq[byte]) =
  var handler: PathResponseHandler
  
  # ハンドラを取得（スレッドセーフに）
  withLock(scheduler.pathResponseLock):
    if not scheduler.responseHandlers.hasKey(pathId):
      return
    handler = scheduler.responseHandlers[pathId]
  
  # ハンドラを呼び出し
  if not handler.isNil:
    handler(responseData)

# タイムアウトまたはシグナル待機（どちらか早い方を待つ）
proc withTimeoutOrSignal*(timeoutFuture, signalFuture: Future[void]): Future[bool] {.async.} =
  var futures = @[
    cast[FutureBase](timeoutFuture),
    cast[FutureBase](signalFuture)
  ]
  
  let winner = await asyncdispatch.selectInto(futures)
  
  # シグナルが先に来たらtrue、タイムアウトが先ならfalse
  return winner == 1  # インデックス1はシグナルフューチャー 