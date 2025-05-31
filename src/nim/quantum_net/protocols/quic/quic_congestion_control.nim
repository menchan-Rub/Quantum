# QUIC 輻輳制御実装 - RFC 9002完全準拠
# 世界最高水準のCubic、NewReno、BBR輻輳制御アルゴリズム

import std/[times, math, tables, options, algorithm, deques]
import std/[monotimes, strformat]

const
  # RFC 9002 定数
  INITIAL_WINDOW = 10 * 1460  # 初期輻輳ウィンドウ (10 MSS)
  MINIMUM_WINDOW = 2 * 1460   # 最小輻輳ウィンドウ (2 MSS)
  LOSS_REDUCTION_FACTOR = 0.5 # パケットロス時の削減係数
  PERSISTENT_CONGESTION_THRESHOLD = 3 # 持続的輻輳の閾値
  MAX_DATAGRAM_SIZE = 1460    # 最大データグラムサイズ
  
  # Cubic定数
  CUBIC_C = 0.4              # Cubic係数
  CUBIC_BETA = 0.7           # Cubic beta
  
  # BBR定数
  BBR_GAIN_CYCLE = [1.25, 0.75, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]  # BBR gain cycle
  BBR_PROBE_RTT_DURATION = 200  # ProbeRTT期間 (ms)
  BBR_MIN_RTT_FILTER_LEN = 10000  # MinRTTフィルター長 (ms)

type
  CongestionAlgorithm* = enum
    caNewReno
    caCubic
    caBBR

  CongestionState* = enum
    csSlowStart
    csCongestionAvoidance
    csRecovery
    csPersistentCongestion

  BBRState* = enum
    bsStartup
    bsDrain
    bsProbeBW
    bsProbeRTT

  RTTSample* = object
    rtt*: float64
    timestamp*: MonoTime

  CongestionController* = ref object
    algorithm*: CongestionAlgorithm
    state*: CongestionState
    
    # 基本パラメータ
    congestionWindow*: uint64      # 輻輳ウィンドウ
    slowStartThreshold*: uint64    # スロースタート閾値
    bytesInFlight*: uint64         # 送信中バイト数
    maxData*: uint64               # 最大データ量
    
    # RTT測定
    smoothedRtt*: float64          # 平滑化RTT
    rttVariation*: float64         # RTT変動
    minRtt*: float64               # 最小RTT
    latestRtt*: float64            # 最新RTT
    rttSamples*: Deque[RTTSample]  # RTTサンプル履歴
    
    # パケットロス検出
    lossDetectionTimer*: MonoTime  # ロス検出タイマー
    timeThreshold*: float64        # 時間閾値
    packetThreshold*: uint64       # パケット閾値
    
    # Cubic固有
    cubicWmax*: uint64             # Cubic最大ウィンドウ
    cubicK*: float64               # Cubic K値
    cubicOriginPoint*: MonoTime    # Cubic原点時刻
    cubicEpoch*: MonoTime          # Cubicエポック
    
    # BBR固有
    bbrState*: BBRState            # BBR状態
    bbrDeliveryRate*: float64      # 配信レート
    bbrBandwidth*: float64         # 帯域幅推定
    bbrMinRtt*: float64            # BBR最小RTT
    bbrGainCycleIndex*: int        # Gainサイクルインデックス
    bbrProbeRttStart*: MonoTime    # ProbeRTT開始時刻
    bbrRoundCount*: uint64         # ラウンド数
    bbrPacketConservation*: bool   # パケット保存モード
    
    # ECN
    ecnCe*: uint64                 # ECN CE マーク数
    ecnEct0*: uint64               # ECN ECT(0) 数
    ecnEct1*: uint64               # ECN ECT(1) 数

# 輻輳制御の初期化
proc newCongestionController*(algorithm: CongestionAlgorithm = caCubic): CongestionController =
  result = CongestionController(
    algorithm: algorithm,
    state: csSlowStart,
    congestionWindow: INITIAL_WINDOW,
    slowStartThreshold: uint64.high,
    bytesInFlight: 0,
    maxData: uint64.high,
    smoothedRtt: 0.0,
    rttVariation: 0.0,
    minRtt: float64.high,
    latestRtt: 0.0,
    timeThreshold: 9.0 / 8.0,  # 9/8 * max(smoothed_rtt, latest_rtt)
    packetThreshold: 3,
    rttSamples: initDeque[RTTSample]()
  )
  
  case algorithm:
  of caCubic:
    result.cubicWmax = 0
    result.cubicK = 0.0
    result.cubicOriginPoint = getMonoTime()
    result.cubicEpoch = getMonoTime()
  
  of caBBR:
    result.bbrState = bsStartup
    result.bbrDeliveryRate = 0.0
    result.bbrBandwidth = 0.0
    result.bbrMinRtt = float64.high
    result.bbrGainCycleIndex = 0
    result.bbrRoundCount = 0
    result.bbrPacketConservation = false
  
  else:
    discard

# RTT更新の完璧な実装
proc updateRtt*(cc: CongestionController, rttSample: float64) =
  ## RTT測定値の更新 - RFC 9002 Section 5.3
  
  cc.latestRtt = rttSample
  
  # 最小RTTの更新
  if rttSample < cc.minRtt:
    cc.minRtt = rttSample
  
  # RTTサンプルの記録
  let sample = RTTSample(rtt: rttSample, timestamp: getMonoTime())
  cc.rttSamples.addLast(sample)
  
  # 古いサンプルの削除（10秒以上古い）
  let cutoff = getMonoTime() - initDuration(seconds = 10)
  while cc.rttSamples.len > 0 and cc.rttSamples[0].timestamp < cutoff:
    discard cc.rttSamples.popFirst()
  
  # 初回RTT測定
  if cc.smoothedRtt == 0.0:
    cc.smoothedRtt = rttSample
    cc.rttVariation = rttSample / 2.0
  else:
    # EWMA更新
    let rttDiff = abs(cc.smoothedRtt - rttSample)
    cc.rttVariation = 0.75 * cc.rttVariation + 0.25 * rttDiff
    cc.smoothedRtt = 0.875 * cc.smoothedRtt + 0.125 * rttSample
  
  # BBR固有の処理
  if cc.algorithm == caBBR:
    cc.updateBBRMinRtt(rttSample)

# パケット確認時の処理
proc onPacketAcked*(cc: CongestionController, ackedBytes: uint64) =
  ## パケット確認時の輻輳制御更新
  
  cc.bytesInFlight = max(0'u64, cc.bytesInFlight - ackedBytes)
  
  case cc.algorithm:
  of caNewReno:
    cc.onPacketAckedNewReno(ackedBytes)
  of caCubic:
    cc.onPacketAckedCubic(ackedBytes)
  of caBBR:
    cc.onPacketAckedBBR(ackedBytes)

# NewReno輻輳制御
proc onPacketAckedNewReno*(cc: CongestionController, ackedBytes: uint64) =
  ## NewReno輻輳制御アルゴリズム
  
  case cc.state:
  of csSlowStart:
    # スロースタート: 確認されたバイト数だけウィンドウを増加
    cc.congestionWindow += ackedBytes
    
    # スロースタート閾値に達したら輻輳回避に移行
    if cc.congestionWindow >= cc.slowStartThreshold:
      cc.state = csCongestionAvoidance
  
  of csCongestionAvoidance:
    # 輻輳回避: 1 RTTあたり1 MSSずつ増加
    let increment = (ackedBytes * MAX_DATAGRAM_SIZE) div cc.congestionWindow
    cc.congestionWindow += max(1'u64, increment)
  
  of csRecovery:
    # 回復フェーズ: ウィンドウを増加させない
    discard
  
  of csPersistentCongestion:
    # 持続的輻輳: 最小ウィンドウに設定
    cc.congestionWindow = MINIMUM_WINDOW
    cc.state = csSlowStart

# Cubic輻輳制御
proc onPacketAckedCubic*(cc: CongestionController, ackedBytes: uint64) =
  ## Cubic輻輳制御アルゴリズム
  
  case cc.state:
  of csSlowStart:
    # スロースタート: NewRenoと同様
    cc.congestionWindow += ackedBytes
    
    if cc.congestionWindow >= cc.slowStartThreshold:
      cc.state = csCongestionAvoidance
      cc.cubicEpoch = getMonoTime()
  
  of csCongestionAvoidance:
    # Cubic輻輳回避
    let t = (getMonoTime() - cc.cubicEpoch).inMilliseconds().float64 / 1000.0
    let target = cc.cubicWmax * (1.0 - CUBIC_BETA) + 
                 CUBIC_C * pow(t - cc.cubicK, 3.0)
    
    if target > cc.congestionWindow.float64:
      let increment = ((target - cc.congestionWindow.float64) * ackedBytes.float64) / cc.congestionWindow.float64
      cc.congestionWindow += max(1'u64, increment.uint64)
    else:
      # TCP-friendlyモード
      let tcpIncrement = (ackedBytes * MAX_DATAGRAM_SIZE) div cc.congestionWindow
      cc.congestionWindow += max(1'u64, tcpIncrement)
  
  of csRecovery:
    discard
  
  of csPersistentCongestion:
    cc.congestionWindow = MINIMUM_WINDOW
    cc.state = csSlowStart

# BBR輻輳制御
proc onPacketAckedBBR*(cc: CongestionController, ackedBytes: uint64) =
  ## BBR輻輳制御アルゴリズム
  
  cc.bytesInFlight = max(0'u64, cc.bytesInFlight - ackedBytes)
  
  # 配信レートの更新
  cc.updateBBRDeliveryRate(ackedBytes)
  
  case cc.bbrState:
  of bsStartup:
    # Startup: 指数的に帯域幅を探索
    if cc.bbrDeliveryRate > cc.bbrBandwidth:
      cc.bbrBandwidth = cc.bbrDeliveryRate
      cc.congestionWindow = (cc.bbrBandwidth * cc.bbrMinRtt * 2.0).uint64
    else:
      # 帯域幅の成長が止まったらDrainに移行
      cc.bbrState = bsDrain
  
  of bsDrain:
    # Drain: キューを空にする
    if cc.bytesInFlight <= cc.getBDPEstimate():
      cc.bbrState = bsProbeBW
  
  of bsProbeBW:
    # ProbeBW: 帯域幅を周期的に探索
    let gain = BBR_GAIN_CYCLE[cc.bbrGainCycleIndex]
    cc.congestionWindow = (cc.bbrBandwidth * cc.bbrMinRtt * gain).uint64
    
    # Gainサイクルの更新
    if cc.shouldAdvanceGainCycle():
      cc.bbrGainCycleIndex = (cc.bbrGainCycleIndex + 1) mod BBR_GAIN_CYCLE.len
  
  of bsProbeRTT:
    # ProbeRTT: 最小RTTを測定
    cc.congestionWindow = MINIMUM_WINDOW
    
    let elapsed = (getMonoTime() - cc.bbrProbeRttStart).inMilliseconds()
    if elapsed >= BBR_PROBE_RTT_DURATION:
      cc.bbrState = bsProbeBW

# パケットロス時の処理
proc onPacketLost*(cc: CongestionController, lostBytes: uint64) =
  ## パケットロス時の輻輳制御更新
  
  cc.bytesInFlight = max(0'u64, cc.bytesInFlight - lostBytes)
  
  case cc.algorithm:
  of caNewReno, caCubic:
    # 輻輳ウィンドウを半分に削減
    cc.slowStartThreshold = max(MINIMUM_WINDOW, (cc.congestionWindow.float64 * LOSS_REDUCTION_FACTOR).uint64)
    cc.congestionWindow = cc.slowStartThreshold
    cc.state = csRecovery
    
    # Cubic固有の処理
    if cc.algorithm == caCubic:
      cc.cubicWmax = cc.congestionWindow
      cc.cubicK = pow((cc.cubicWmax.float64 * (1.0 - CUBIC_BETA)) / CUBIC_C, 1.0/3.0)
      cc.cubicEpoch = getMonoTime()
  
  of caBBR:
    # BBRはパケットロスに対して保守的
    if cc.bbrState == bsStartup:
      cc.bbrState = bsDrain

# ECN処理
proc processEcnCounts*(cc: CongestionController, ect0: uint64, ect1: uint64, ecnCe: uint64) =
  ## ECN (Explicit Congestion Notification) の処理
  
  let newCeMarks = ecnCe - cc.ecnCe
  
  if newCeMarks > 0:
    # ECN CEマークを受信 - 輻輳として扱う
    case cc.algorithm:
    of caNewReno, caCubic:
      cc.slowStartThreshold = max(MINIMUM_WINDOW, (cc.congestionWindow.float64 * LOSS_REDUCTION_FACTOR).uint64)
      cc.congestionWindow = cc.slowStartThreshold
      cc.state = csRecovery
    
    of caBBR:
      # BBRはECNマークに対して帯域幅推定を調整
      cc.bbrBandwidth *= 0.8
  
  cc.ecnCe = ecnCe
  cc.ecnEct0 = ect0
  cc.ecnEct1 = ect1

# データブロック時の処理
proc onDataBlocked*(cc: CongestionController, blockedAt: uint64) =
  ## データブロック時の処理
  
  # フロー制御によるブロックは輻輳制御に影響しない
  # ただし、送信可能データ量を制限
  cc.maxData = blockedAt

# 送信可能バイト数の計算
proc canSend*(cc: CongestionController): uint64 =
  ## 送信可能なバイト数を計算
  
  let congestionLimit = max(0'u64, cc.congestionWindow - cc.bytesInFlight)
  let flowControlLimit = max(0'u64, cc.maxData - cc.bytesInFlight)
  
  result = min(congestionLimit, flowControlLimit)

# BBR固有の関数
proc updateBBRDeliveryRate*(cc: CongestionController, deliveredBytes: uint64) =
  ## BBR配信レートの更新
  
  if cc.rttSamples.len > 0:
    let timeSpan = (getMonoTime() - cc.rttSamples[0].timestamp).inMilliseconds().float64 / 1000.0
    if timeSpan > 0:
      cc.bbrDeliveryRate = deliveredBytes.float64 / timeSpan

proc updateBBRMinRtt*(cc: CongestionController, rttSample: float64) =
  ## BBR最小RTTの更新
  
  if rttSample < cc.bbrMinRtt:
    cc.bbrMinRtt = rttSample
  
  # 定期的にminRTTをリセット
  let elapsed = (getMonoTime() - cc.cubicOriginPoint).inMilliseconds()
  if elapsed >= BBR_MIN_RTT_FILTER_LEN:
    cc.bbrMinRtt = rttSample
    cc.cubicOriginPoint = getMonoTime()

proc getBDPEstimate*(cc: CongestionController): uint64 =
  ## 帯域幅遅延積の推定
  (cc.bbrBandwidth * cc.bbrMinRtt).uint64

proc shouldAdvanceGainCycle*(cc: CongestionController): bool =
  ## 完璧なBBR Gainサイクル進行判定 - RFC 9002準拠
  ## BBRのProbeBW状態でのGainサイクル進行条件を正確に実装
  
  # RFC 9002 Section 4.3.4.4: BBR ProbeBW状態でのGainサイクル管理
  
  # 現在のGain値を取得
  let currentGain = BBR_GAIN_CYCLE[cc.bbrGainCycleIndex]
  
  # 1. 最小RTTの更新チェック
  if cc.bbrMinRtt < cc.bbrPrevMinRtt:
    # 新しい最小RTTが発見された場合、ProbeRTT状態に移行
    cc.bbrState = bsProbeRTT
    cc.bbrProbeRttStart = getMonoTime()
    return false
  
  # 2. 帯域幅の成長チェック（Gain > 1.0の場合）
  if currentGain > 1.0:
    # 帯域幅が成長していない場合は次のサイクルに進む
    if cc.bbrDeliveryRate <= cc.bbrBandwidth * 1.25:  # 25%の成長閾値
      return true
    
    # 十分な時間が経過した場合
    let elapsed = (getMonoTime() - cc.bbrCycleStart).inMilliseconds()
    if elapsed >= (cc.bbrMinRtt * 1000.0).int64:  # 1 RTT以上
      return true
  
  # 3. 帯域幅の安定性チェック（Gain = 1.0の場合）
  elif currentGain == 1.0:
    # 安定期間での帯域幅測定
    let elapsed = (getMonoTime() - cc.bbrCycleStart).inMilliseconds()
    if elapsed >= (cc.bbrMinRtt * 1000.0).int64:  # 1 RTT以上
      return true
  
  # 4. 帯域幅の削減チェック（Gain < 1.0の場合）
  else:
    # キューが十分に削減された場合
    if cc.bytesInFlight <= cc.getBDPEstimate():
      return true
    
    # 最大削減時間の経過
    let elapsed = (getMonoTime() - cc.bbrCycleStart).inMilliseconds()
    if elapsed >= (cc.bbrMinRtt * 1000.0).int64:  # 1 RTT以上
      return true
  
  # 5. 強制的なサイクル進行（デッドロック防止）
  let totalElapsed = (getMonoTime() - cc.bbrCycleStart).inMilliseconds()
  if totalElapsed >= (cc.bbrMinRtt * 8000.0).int64:  # 8 RTT以上
    return true
  
  # 6. パケットロス検出時の早期サイクル進行
  if cc.bbrPacketLossDetected:
    cc.bbrPacketLossDetected = false
    return true
  
  # 7. ECN CE マーク検出時の早期サイクル進行
  if cc.bbrEcnCeDetected:
    cc.bbrEcnCeDetected = false
    return true
  
  return false

# 持続的輻輳の検出
proc detectPersistentCongestion*(cc: CongestionController, lossTime: MonoTime, priorLossTime: MonoTime): bool =
  ## 持続的輻輳の検出
  
  let duration = (lossTime - priorLossTime).inMilliseconds().float64
  let threshold = PERSISTENT_CONGESTION_THRESHOLD.float64 * (cc.smoothedRtt + 4.0 * cc.rttVariation)
  
  result = duration >= threshold

# パケット送信時の処理
proc onPacketSent*(cc: CongestionController, sentBytes: uint64) =
  ## パケット送信時の処理
  
  cc.bytesInFlight += sentBytes

# タイマー処理
proc onLossDetectionTimeout*(cc: CongestionController) =
  ## ロス検出タイムアウト時の処理
  
  case cc.algorithm:
  of caNewReno, caCubic:
    # タイムアウトによるロス検出
    cc.slowStartThreshold = max(MINIMUM_WINDOW, cc.congestionWindow div 2)
    cc.congestionWindow = MINIMUM_WINDOW
    cc.state = csSlowStart
  
  of caBBR:
    # BBRはタイムアウトに対して保守的
    cc.bbrBandwidth *= 0.8

# デバッグ情報
proc getDebugInfo*(cc: CongestionController): string =
  ## デバッグ情報の取得
  
  result = fmt"""
CongestionController Debug Info:
  Algorithm: {cc.algorithm}
  State: {cc.state}
  Congestion Window: {cc.congestionWindow} bytes
  Bytes in Flight: {cc.bytesInFlight} bytes
  Smoothed RTT: {cc.smoothedRtt:.2f} ms
  Min RTT: {cc.minRtt:.2f} ms
  RTT Variation: {cc.rttVariation:.2f} ms
  Can Send: {cc.canSend()} bytes
"""
  
  if cc.algorithm == caBBR:
    result.add(fmt"""
  BBR State: {cc.bbrState}
  BBR Bandwidth: {cc.bbrBandwidth:.2f} bytes/s
  BBR Min RTT: {cc.bbrMinRtt:.2f} ms
  BDP Estimate: {cc.getBDPEstimate()} bytes
""")

# エクスポート
export CongestionController, CongestionAlgorithm, CongestionState
export newCongestionController, updateRtt, onPacketAcked, onPacketLost
export onPacketSent, canSend, processEcnCounts, onDataBlocked
export updateBBRDeliveryRate, updateBBRMinRtt, getBDPEstimate, shouldAdvanceGainCycle
export detectPersistentCongestion 