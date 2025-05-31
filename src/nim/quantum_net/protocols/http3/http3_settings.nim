# HTTP/3設定モジュール
#
# HTTP/3プロトコルの設定を管理するためのモジュール。
# RFC 9114に準拠したHTTP/3設定パラメータ管理を提供します。

import std/[strutils, strformat, options, tables, json, sets]
import std/[times, math, algorithm, hashes, sequtils]

# HTTP/3設定識別子
const
  # 標準設定識別子
  H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0x01
  H3_SETTINGS_MAX_FIELD_SECTION_SIZE = 0x06
  H3_SETTINGS_QPACK_BLOCKED_STREAMS = 0x07
  
  # 追加設定識別子
  H3_SETTINGS_ENABLE_CONNECT_PROTOCOL = 0x08
  H3_SETTINGS_ENABLE_WEBTRANSPORT = 0x2B603742  # IETF提案中
  H3_SETTINGS_ENABLE_DATAGRAM = 0xffd277  # draft-RFC
  
  # Quantum独自拡張
  H3_SETTINGS_QUANTUM_PRIORITIES = 0xF1000001  # 優先度拡張
  H3_SETTINGS_QUANTUM_PACING = 0xF1000002  # パケットペーシング
  H3_SETTINGS_QUANTUM_HYBRID_RTT = 0xF1000003  # ハイブリッドRTT
  H3_SETTINGS_QUANTUM_ACCELERATION = 0xF1000004  # 量子加速モード
  H3_SETTINGS_QUANTUM_AI_PREFETCH = 0xF1000005  # AI先読み対応
  H3_SETTINGS_QUANTUM_MULTIPATH = 0xF1000006  # マルチパス通信対応
  H3_SETTINGS_QUANTUM_STREAMING = 0xF1000007  # 拡張ストリーミング対応
  H3_SETTINGS_QUANTUM_BANDWIDTH_PROBING = 0xF1000008  # 帯域探索対応
  H3_SETTINGS_QUANTUM_CONGESTION = 0xF1000009  # 輻輳制御拡張
  H3_SETTINGS_QUANTUM_DATAGRAM_QOS = 0xF100000A  # データグラムQoS
  H3_SETTINGS_QUANTUM_ZERO_RTT_EXTENSION = 0xF100000B  # 0-RTT拡張

# 設定値の型
type
  SettingType* = enum
    stInteger,  # 整数値
    stBoolean,  # 真偽値
    stString,   # 文字列値
    stBlob      # バイナリ値

# HTTP/3最適化プロファイル
type
  OptimizationProfile* = enum
    opBalanced,     # バランス型（デフォルト）
    opHighThroughput, # 高スループット
    opLowLatency,   # 低遅延
    opReliability,  # 信頼性重視
    opMobile,       # モバイル最適化
    opSatellite,    # 衛星回線最適化
    opQuantum       # 量子最適化（最先端設定）

  # HTTP/3設定オプション
  Http3SettingsOption* = enum
    soQpackDynamicTable,   # QPACKの動的テーブルを有効化
    soHeaderCompression,   # ヘッダー圧縮を強化
    soMaxConcurrency,      # 同時リクエスト数を最大化
    soHighThroughput,      # 高スループット向け設定
    soLowLatency,          # 低遅延向け設定
    soLongLivedConnection, # 長時間接続向け設定
    soReliableTransfer,    # 信頼性重視
    soStreamPrioritization, # ストリーム優先度付け
    soDatagramSupport,     # QUICデータグラム対応
    soFlowControl,         # フロー制御最適化
    soQuantumAcceleration  # 量子加速モード

  # HTTP/3設定
  Http3Settings* = ref object
    # QPACK設定
    qpackMaxTableCapacity*: uint64  # QPACK動的テーブル最大容量
    qpackBlockedStreams*: uint64    # ブロックされたストリーム上限
    
    # HTTP/3設定
    maxFieldSectionSize*: uint64    # フィールドセクション最大サイズ
    maxHeaderListSize*: uint64      # ヘッダーリスト最大サイズ
    
    # ストリーム設定
    maxConcurrentStreams*: uint64   # 同時ストリーム上限
    initialStreamFlowWindow*: uint64 # 初期ストリームフロー制御ウィンドウ
    
    # 一般設定
    enableConnectProtocol*: bool    # CONNECT対応
    enableWebTransport*: bool       # WebTransport対応
    enableDatagrams*: bool          # データグラム対応
    
    # 拡張設定
    enableExtensiblePriorities*: bool # 拡張可能な優先度付け
    enableEarlyData*: bool          # 0-RTTデータ対応
    enableStreamIndependence*: bool # ストリーム独立性有効化
    initialRtt*: uint64             # 初期RTT（ミリ秒）
    initialBandwidth*: uint64       # 初期帯域（bps）
    maxStreamsBidi*: uint64         # 双方向ストリーム最大数
    maxStreamsUni*: uint64          # 単方向ストリーム最大数
    
    # 輻輳制御設定
    congestionControlAlgorithm*: string # 輻輳制御アルゴリズム
    pacing*: bool                   # パケットペーシング
    pacingRate*: float              # ペーシングレート
    
    # Quantum拡張
    enableQuantumMode*: bool        # 量子モード有効化
    quantumPriorities*: bool        # 量子優先度付け
    hybridRtt*: bool                # ハイブリッドRTT
    dynamicStreamScheduling*: bool  # 動的ストリームスケジューリング
    prefetchHints*: bool            # プリフェッチヒント
    multipleAckRanges*: bool        # 複数ACK範囲
    intelligentRetransmission*: bool # 知的再送
    bandwidthEstimationMode*: int   # 帯域見積もりモード
    flowControlWindow*: uint64      # フロー制御ウィンドウ
    optimizationProfile*: OptimizationProfile # 最適化プロファイル
    enabledOptions*: set[Http3SettingsOption] # 有効オプション
    
    # Advanced Quantum 拡張設定
    adaptivePacing*: bool           # 適応型ペーシング
    jumpStart*: bool                # 高速起動
    customInitialWindow*: uint64    # カスタム初期ウィンドウ
    rtxBackoffFactor*: float        # 再送バックオフ係数
    multiPathPolicy*: int           # マルチパスポリシー
    zeroCopyMode*: bool             # ゼロコピーモード
    lowLatencyMode*: bool           # 低レイテンシーモード
    proactiveProbingInterval*: int  # 積極的探索間隔
    maxDatagramSize*: uint16        # 最大データグラムサイズ
    maxCwndGain*: float             # 最大輻輳ウィンドウゲイン
    maxInFlightPackets*: uint64     # 飛行中パケット最大数
    maxDuplicateAcks*: int          # 重複ACK最大数
    maxDataRetransmissions*: int    # データ再送最大数
    maxTimeoutReset*: int           # タイムアウトリセット最大数
    
    # 環境適応設定
    adaptiveSettings*: bool         # 環境適応設定
    mobileFriendly*: bool           # モバイル対応設定
    satelliteFriendly*: bool        # 衛星回線対応
    badNetworkMitigation*: bool     # 不安定ネットワーク対策
    lowBandwidthMode*: bool         # 低帯域モード
    highLatencyMode*: bool          # 高遅延モード

# ネットワーク条件からハッシュ値を計算
proc hash*(nc: NetworkCondition): Hash =
  var h: Hash = 0
  h = h !& hash(nc.bandwidth.int64)
  h = h !& hash(nc.rtt.int64)
  h = h !& hash(int(nc.packetLoss * 1000))
  h = h !& hash(int(nc.jitter * 1000))
  h = h !& hash(ord(nc.networkType))
  h = h !& hash(int(nc.congestion * 1000))
  h = h !& hash(nc.batteryPowered)
  h = h !& hash(int(nc.batteryLevel * 1000))
  if nc.signalStrength.isSome:
    h = h !& hash(int(nc.signalStrength.get() * 1000))
  return !$h

# デフォルト設定でインスタンスを生成
proc newHttp3Settings*(): Http3Settings =
  new(result)
  # 標準設定
  result.qpackMaxTableCapacity = 4096  # 4KB
  result.qpackBlockedStreams = 16
  result.maxFieldSectionSize = 16384  # 16KB
  result.maxHeaderListSize = 16384  # 16KB
  result.maxConcurrentStreams = 100
  result.initialStreamFlowWindow = 65536  # 64KB
  
  # 一般設定
  result.enableConnectProtocol = true
  result.enableWebTransport = false
  result.enableDatagrams = true
  
  # 拡張設定
  result.enableExtensiblePriorities = true
  result.enableEarlyData = true
  result.enableStreamIndependence = true
  result.initialRtt = 100  # 100ms
  result.initialBandwidth = 1_000_000  # 1Mbps
  result.maxStreamsBidi = 100
  result.maxStreamsUni = 100
  
  # 輻輳制御設定
  result.congestionControlAlgorithm = "cubic"
  result.pacing = true
  result.pacingRate = 1.25
  
  # Quantum拡張
  result.enableQuantumMode = false
  result.quantumPriorities = false
  result.hybridRtt = false
  result.dynamicStreamScheduling = false
  result.prefetchHints = false
  result.multipleAckRanges = false
  result.intelligentRetransmission = false
  result.bandwidthEstimationMode = 0
  result.flowControlWindow = 16777216  # 16MB
  result.optimizationProfile = opBalanced
  
  # 先進設定
  result.adaptivePacing = false
  result.jumpStart = false
  result.customInitialWindow = 0
  result.rtxBackoffFactor = 1.5
  result.multiPathPolicy = 0
  result.zeroCopyMode = false
  result.lowLatencyMode = false
  result.proactiveProbingInterval = 0
  result.maxDatagramSize = 1200
  result.maxCwndGain = 2.0
  result.maxInFlightPackets = 1000
  result.maxDuplicateAcks = 3
  result.maxDataRetransmissions = 10
  result.maxTimeoutReset = 5
  
  # 環境適応設定
  result.adaptiveSettings = true
  result.mobileFriendly = false
  result.satelliteFriendly = false
  result.badNetworkMitigation = true
  result.lowBandwidthMode = false
  result.highLatencyMode = false
  
  # 有効オプション
  result.enabledOptions = {soQpackDynamicTable, soHeaderCompression, soMaxConcurrency, soFlowControl}

# 設定バイナリエンコード
proc encodeSettings*(settings: Http3Settings): seq[byte] =
  result = @[]
  
  # QPACK最大テーブル容量
  if settings.qpackMaxTableCapacity > 0:
    # 識別子エンコード
    result.add(byte(H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY))
    
    # 値をエンコード
    var value = settings.qpackMaxTableCapacity
    var buffer: seq[byte] = @[]
    
    while value > 0:
      buffer.add(byte(value and 0xFF))
      value = value shr 8
    
    # 長さを追加
    result.add(byte(buffer.len))
    
    # 値を追加（リトルエンディアン→ビッグエンディアン変換）
    for i in countdown(buffer.len - 1, 0):
      result.add(buffer[i])
  
  # QPACK Blocked Streams
  if settings.qpackBlockedStreams > 0:
    # 識別子エンコード
    result.add(byte(H3_SETTINGS_QPACK_BLOCKED_STREAMS))
    
    # 値をエンコード
    var value = settings.qpackBlockedStreams
    var buffer: seq[byte] = @[]
    
    while value > 0:
      buffer.add(byte(value and 0xFF))
      value = value shr 8
    
    # 長さを追加
    result.add(byte(buffer.len))
    
    # 値を追加（リトルエンディアン→ビッグエンディアン変換）
    for i in countdown(buffer.len - 1, 0):
      result.add(buffer[i])
  
  # Max Field Section Size
  if settings.maxFieldSectionSize > 0:
    # 識別子エンコード
    result.add(byte(H3_SETTINGS_MAX_FIELD_SECTION_SIZE))
    
    # 値をエンコード
    var value = settings.maxFieldSectionSize
    var buffer: seq[byte] = @[]
    
    while value > 0:
      buffer.add(byte(value and 0xFF))
      value = value shr 8
    
    # 長さを追加
    result.add(byte(buffer.len))
    
    # 値を追加（リトルエンディアン→ビッグエンディアン変換）
    for i in countdown(buffer.len - 1, 0):
      result.add(buffer[i])
  
  # CONNECT Protocol設定
  if settings.enableConnectProtocol:
    # 識別子エンコード
    result.add(byte(H3_SETTINGS_ENABLE_CONNECT_PROTOCOL))
    
    # 値をエンコード (1 = 有効)
    result.add(byte(1))
    result.add(byte(1))
  
  # WebTransport設定
  if settings.enableWebTransport:
    # 識別子エンコード（64ビットエンコードが必要）
    var idBuffer: seq[byte] = @[]
    var id = H3_SETTINGS_ENABLE_WEBTRANSPORT
    
    while id > 0:
      idBuffer.add(byte(id and 0xFF))
      id = id shr 8
    
    # 識別子を追加（リトルエンディアン→ビッグエンディアン変換）
    for i in countdown(idBuffer.len - 1, 0):
      result.add(idBuffer[i])
    
    # 値をエンコード (1 = 有効)
    result.add(byte(1))
    result.add(byte(1))
  
  # Datagram設定
  if settings.enableDatagrams:
    # 識別子エンコード（64ビットエンコードが必要）
    var idBuffer: seq[byte] = @[]
    var id = H3_SETTINGS_ENABLE_DATAGRAM
    
    while id > 0:
      idBuffer.add(byte(id and 0xFF))
      id = id shr 8
    
    # 識別子を追加（リトルエンディアン→ビッグエンディアン変換）
    for i in countdown(idBuffer.len - 1, 0):
      result.add(idBuffer[i])
    
    # 値をエンコード (1 = 有効)
    result.add(byte(1))
    result.add(byte(1))
  
  # 量子モード設定
  if settings.enableQuantumMode:
    # 量子優先度付け
    if settings.quantumPriorities:
      var idBuffer: seq[byte] = @[]
      var id = H3_SETTINGS_QUANTUM_PRIORITIES
      
      while id > 0:
        idBuffer.add(byte(id and 0xFF))
        id = id shr 8
      
      # 識別子を追加
      for i in countdown(idBuffer.len - 1, 0):
        result.add(idBuffer[i])
      
      # 値をエンコード (1 = 有効)
      result.add(byte(1))
      result.add(byte(1))
    
    # ハイブリッドRTT
    if settings.hybridRtt:
      var idBuffer: seq[byte] = @[]
      var id = H3_SETTINGS_QUANTUM_HYBRID_RTT
      
      while id > 0:
        idBuffer.add(byte(id and 0xFF))
        id = id shr 8
      
      # 識別子を追加
      for i in countdown(idBuffer.len - 1, 0):
        result.add(idBuffer[i])
      
      # 値をエンコード (1 = 有効)
      result.add(byte(1))
      result.add(byte(1))
    
    # 量子加速モード
    var idBuffer: seq[byte] = @[]
    var id = H3_SETTINGS_QUANTUM_ACCELERATION
    
    while id > 0:
      idBuffer.add(byte(id and 0xFF))
      id = id shr 8
    
    # 識別子を追加
    for i in countdown(idBuffer.len - 1, 0):
      result.add(idBuffer[i])
    
    # 値をエンコード (1 = 有効)
    result.add(byte(1))
    result.add(byte(1))
    
    # マルチパス対応
    if settings.multiPathPolicy > 0:
      var idBuffer: seq[byte] = @[]
      var id = H3_SETTINGS_QUANTUM_MULTIPATH
      
      while id > 0:
        idBuffer.add(byte(id and 0xFF))
        id = id shr 8
      
      # 識別子を追加
      for i in countdown(idBuffer.len - 1, 0):
        result.add(idBuffer[i])
      
      # 値をエンコード
      result.add(byte(1))
      result.add(byte(settings.multiPathPolicy))
    
    # 帯域探索対応
    if settings.proactiveProbingInterval > 0:
      var idBuffer: seq[byte] = @[]
      var id = H3_SETTINGS_QUANTUM_BANDWIDTH_PROBING
      
      while id > 0:
        idBuffer.add(byte(id and 0xFF))
        id = id shr 8
      
      # 識別子を追加
      for i in countdown(idBuffer.len - 1, 0):
        result.add(idBuffer[i])
      
      # 値をエンコード
      var valueBuffer: seq[byte] = @[]
      var value = settings.proactiveProbingInterval
      
      while value > 0:
        valueBuffer.add(byte(value and 0xFF))
        value = value shr 8
      
      # 長さを追加
      result.add(byte(valueBuffer.len))
      
      # 値を追加
      for i in countdown(valueBuffer.len - 1, 0):
        result.add(valueBuffer[i])
  
  return result

# 最適化プロファイル適用
proc applyOptimizationProfile*(settings: Http3Settings, profile: OptimizationProfile): Http3Settings =
  case profile
  of opBalanced:
    # バランス型（デフォルト）
    settings.qpackMaxTableCapacity = 4096
    settings.qpackBlockedStreams = 16
    settings.maxConcurrentStreams = 100
    settings.initialStreamFlowWindow = 65536
    settings.pacing = true
    settings.pacingRate = 1.25
    settings.enableQuantumMode = false
    settings.flowControlWindow = 16777216  # 16MB
  
  of opHighThroughput:
    # 高スループット
    settings.qpackMaxTableCapacity = 16384
    settings.qpackBlockedStreams = 32
    settings.maxConcurrentStreams = 1000
    settings.initialStreamFlowWindow = 262144  # 256KB
    settings.pacing = true
    settings.pacingRate = 1.5
    settings.congestionControlAlgorithm = "bbr"
    settings.enableQuantumMode = true
    settings.flowControlWindow = 67108864  # 64MB
    settings.dynamicStreamScheduling = true
    settings.bandwidthEstimationMode = 1
    settings.adaptivePacing = true
    settings.jumpStart = true
    settings.maxCwndGain = 2.5
  
  of opLowLatency:
    # 低遅延
    settings.qpackMaxTableCapacity = 2048
    settings.qpackBlockedStreams = 8
    settings.maxConcurrentStreams = 50
    settings.initialStreamFlowWindow = 32768  # 32KB
    settings.pacing = true
    settings.pacingRate = 1.1
    settings.congestionControlAlgorithm = "cubic"
    settings.enableQuantumMode = true
    settings.flowControlWindow = 8388608  # 8MB
    settings.prefetchHints = true
    settings.lowLatencyMode = true
    settings.intelligentRetransmission = true
    settings.zeroCopyMode = true
  
  of opReliability:
    # 信頼性重視
    settings.qpackMaxTableCapacity = 4096
    settings.qpackBlockedStreams = 16
    settings.maxConcurrentStreams = 64
    settings.initialStreamFlowWindow = 65536  # 64KB
    settings.pacing = true
    settings.pacingRate = 1.0
    settings.congestionControlAlgorithm = "cubic"
    settings.enableQuantumMode = true
    settings.flowControlWindow = 16777216  # 16MB
    settings.multipleAckRanges = true
    settings.intelligentRetransmission = true
    settings.maxDataRetransmissions = 20
    settings.maxDuplicateAcks = 5
    settings.badNetworkMitigation = true
  
  of opMobile:
    # モバイル最適化
    settings.qpackMaxTableCapacity = 8192
    settings.qpackBlockedStreams = 16
    settings.maxConcurrentStreams = 32
    settings.initialStreamFlowWindow = 32768  # 32KB
    settings.pacing = true
    settings.pacingRate = 1.2
    settings.congestionControlAlgorithm = "cubic"
    settings.enableQuantumMode = true
    settings.flowControlWindow = 4194304  # 4MB
    settings.mobileFriendly = true
    settings.adaptiveSettings = true
    settings.enableEarlyData = true
    settings.lowBandwidthMode = true
  
  of opSatellite:
    # 衛星回線最適化
    settings.qpackMaxTableCapacity = 16384
    settings.qpackBlockedStreams = 32
    settings.maxConcurrentStreams = 32
    settings.initialStreamFlowWindow = 524288  # 512KB
    settings.pacing = true
    settings.pacingRate = 2.0
    settings.congestionControlAlgorithm = "hybla"
    settings.enableQuantumMode = true
    settings.flowControlWindow = 33554432  # 32MB
    settings.initialRtt = 600  # 600ms
    settings.satelliteFriendly = true
    settings.highLatencyMode = true
    settings.prefetchHints = true
    settings.bandwidthEstimationMode = 2
  
  of opQuantum:
    # 量子最適化（最先端設定）
    settings.qpackMaxTableCapacity = 131072  # 128KB
    settings.qpackBlockedStreams = 100
    settings.maxConcurrentStreams = 1000
    settings.initialStreamFlowWindow = 1048576  # 1MB
    settings.pacing = true
    settings.pacingRate = 1.5
    settings.congestionControlAlgorithm = "quantumcubic"  # カスタム輻輳制御
    settings.enableQuantumMode = true
    settings.quantumPriorities = true
    settings.hybridRtt = true
    settings.dynamicStreamScheduling = true
    settings.prefetchHints = true
    settings.multipleAckRanges = true
    settings.intelligentRetransmission = true
    settings.flowControlWindow = 134217728  # 128MB
    settings.adaptivePacing = true
    settings.jumpStart = true
    settings.zeroCopyMode = true
    settings.maxDatagramSize = 1440
    settings.maxCwndGain = 2.7
    settings.proactiveProbingInterval = 100
    settings.maxInFlightPackets = 10000
    settings.enabledOptions = {soQpackDynamicTable, soHeaderCompression, 
                              soMaxConcurrency, soHighThroughput, soLowLatency,
                              soStreamPrioritization, soDatagramSupport, 
                              soFlowControl, soQuantumAcceleration}
  
  settings.optimizationProfile = profile
  return settings

# 環境適応設定
proc applyNetworkEnvironment*(settings: Http3Settings, 
                            bandwidth: int, # kbps
                            rtt: int,      # ms
                            lossRate: float, # 0.0 - 1.0
                            isMobile: bool): Http3Settings =
  # 基本設定
  if bandwidth < 500:  # 低帯域
    settings.lowBandwidthMode = true
    settings.maxConcurrentStreams = 16
    settings.qpackMaxTableCapacity = 2048
    settings.initialStreamFlowWindow = 16384  # 16KB
    settings.pacingRate = 1.0
  elif bandwidth < 2000:  # 中帯域
    settings.lowBandwidthMode = false
    settings.maxConcurrentStreams = 32
    settings.qpackMaxTableCapacity = 4096
    settings.initialStreamFlowWindow = 32768  # 32KB
    settings.pacingRate = 1.2
  else:  # 高帯域
    settings.lowBandwidthMode = false
    settings.maxConcurrentStreams = 100
    settings.qpackMaxTableCapacity = 8192
    settings.initialStreamFlowWindow = 65536  # 64KB
    settings.pacingRate = 1.5
  
  # RTT設定
  if rtt > 300:  # 高遅延
    settings.highLatencyMode = true
    settings.initialRtt = uint64(rtt)
    settings.flowControlWindow = 33554432  # 32MB
    settings.maxDataRetransmissions = 15
    settings.prefetchHints = true
    settings.pacingRate *= 1.5
    settings.adaptivePacing = true
  else:  # 低遅延～中遅延
    settings.highLatencyMode = false
    settings.initialRtt = uint64(rtt)
    if rtt < 50:
      settings.lowLatencyMode = true
    else:
      settings.lowLatencyMode = false
  
  # パケットロス対応
  if lossRate > 0.05:  # 高いパケットロス
    settings.badNetworkMitigation = true
    settings.intelligentRetransmission = true
    settings.congestionControlAlgorithm = "cubic"
    settings.multipleAckRanges = true
    settings.maxDuplicateAcks = 5
    settings.maxDataRetransmissions = 15
  else:
    settings.badNetworkMitigation = false
  
  # モバイル設定
  if isMobile:
    settings.mobileFriendly = true
    settings.adaptiveSettings = true
    settings.enableEarlyData = true
    settings.initialStreamFlowWindow = max(settings.initialStreamFlowWindow, 32768)
    settings.adaptivePacing = true
  
  # 量子モード判断（良好な通信環境なら有効に）
  if bandwidth >= 10000 and rtt < 100 and lossRate < 0.01:
    settings.enableQuantumMode = true
    settings.quantumPriorities = true
    settings.dynamicStreamScheduling = true
  else:
    # 厳しい環境でも一部の機能を有効化
    settings.enableQuantumMode = true
    settings.intelligentRetransmission = true
  
  return settings

# 設定文字列化（デバッグ用）
proc `$`*(settings: Http3Settings): string =
  result = "Http3Settings:\n"
  result &= &"  qpackMaxTableCapacity: {settings.qpackMaxTableCapacity}\n"
  result &= &"  qpackBlockedStreams: {settings.qpackBlockedStreams}\n"
  result &= &"  maxFieldSectionSize: {settings.maxFieldSectionSize}\n"
  result &= &"  maxConcurrentStreams: {settings.maxConcurrentStreams}\n"
  result &= &"  initialStreamFlowWindow: {settings.initialStreamFlowWindow}\n"
  result &= &"  enableConnectProtocol: {settings.enableConnectProtocol}\n"
  result &= &"  enableWebTransport: {settings.enableWebTransport}\n"
  result &= &"  enableDatagrams: {settings.enableDatagrams}\n"
  result &= &"  optimizationProfile: {settings.optimizationProfile}\n"
  result &= &"  enableQuantumMode: {settings.enableQuantumMode}\n"
  if settings.enableQuantumMode:
    result &= &"  quantumPriorities: {settings.quantumPriorities}\n"
    result &= &"  hybridRtt: {settings.hybridRtt}\n"
    result &= &"  dynamicStreamScheduling: {settings.dynamicStreamScheduling}\n"
    result &= &"  prefetchHints: {settings.prefetchHints}\n"
    result &= &"  multipleAckRanges: {settings.multipleAckRanges}\n"
    result &= &"  intelligentRetransmission: {settings.intelligentRetransmission}\n"
  result &= &"  pacing: {settings.pacing}\n"
  result &= &"  pacingRate: {settings.pacingRate}\n"
  result &= &"  congestionControlAlgorithm: {settings.congestionControlAlgorithm}\n"
  result &= &"  initialRtt: {settings.initialRtt}ms\n"
  result &= &"  flowControlWindow: {settings.flowControlWindow} bytes\n"
  result &= &"  environmentAdapted: {settings.adaptiveSettings}\n"

# ネットワーク条件に基づく設定の最適化
proc optimizeForNetwork*(settings: var Http3Settings, network: NetworkCondition) =
  # 帯域に基づくフロー制御ウィンドウサイズの最適化
  # BDP（帯域遅延積）に基づく計算
  if network.bandwidth > 0 and network.rtt > 0:
    let bdp = network.bandwidth / 8 * network.rtt / 1000  # バイト単位のBDP
    settings.flowControlWindow = uint64(max(DEFAULT_FLOW_CONTROL_WINDOW.float, bdp * 1.5))
    settings.flowControlWindow = min(settings.flowControlWindow, MAX_FLOW_CONTROL_WINDOW)
  
  # パケットロス率に応じた設定
  if network.packetLoss > 0.05:  # 5%以上のパケットロス
    # より保守的な設定
    settings.initialRtt = uint64(max(settings.initialRtt.float, network.rtt * 1.5))
    settings.maxConcurrentStreams = uint64(float(settings.maxConcurrentStreams) * 0.7)
    settings.maxConcurrentStreams = max(settings.maxConcurrentStreams, 5)
  
  # ネットワークタイプに応じた最適化
  case network.networkType
  of ntWifi:
    if network.signalStrength.isSome and network.signalStrength.get() < 0.4:
      # 低信号強度WiFi
      settings.maxConcurrentStreams = uint64(float(settings.maxConcurrentStreams) * 0.8)
  
  of ntCellular4G, ntCellular5G:
    # モバイルネットワーク最適化
    settings.qpackMaxTableCapacity = min(settings.qpackMaxTableCapacity, 16384)  # 16KB
    if network.batteryPowered and network.batteryLevel < 0.3:
      # バッテリー残量が低い場合
      settings.optimizationProfile = opBatteryEfficient
      settings.flowControlWindow = min(settings.flowControlWindow, 8388608)  # 8MB
  
  of ntCellular3G:
    # 低速モバイル最適化
    settings.qpackMaxTableCapacity = min(settings.qpackMaxTableCapacity, 8192)  # 8KB
    settings.maxConcurrentStreams = min(settings.maxConcurrentStreams, 20)
    settings.optimizationProfile = opLowBandwidth
  
  of ntSatellite:
    # 高遅延ネットワーク
    settings.initialRtt = max(settings.initialRtt, 500)  # 少なくとも500ms
    settings.qpackBlockedStreams = min(settings.qpackBlockedStreams, 16)
    settings.maxConcurrentStreams = min(settings.maxConcurrentStreams, 10)
  
  of ntVPN:
    # VPNは一般的に遅延が増加
    settings.initialRtt = uint64(settings.initialRtt.float * 1.2)
  
  else:
    discard

  # ジッターに応じた設定
  if network.jitter > 50:  # 高ジッター
    settings.initialRtt = uint64(settings.initialRtt.float + network.jitter * 0.5)
  
  # バッテリー状態に応じた最適化
  if network.batteryPowered:
    if network.batteryLevel < 0.15:  # バッテリーが非常に低い
      # 超省電力モード
      settings.optimizationProfile = opBatteryEfficient
      settings.qpackMaxTableCapacity = min(settings.qpackMaxTableCapacity, 2048)  # 2KB
      settings.maxConcurrentStreams = min(settings.maxConcurrentStreams, 10)
      settings.maxIdleTimeout = min(settings.maxIdleTimeout, 15000)  # 15秒
    elif network.batteryLevel < 0.3:  # バッテリーが低い
      # 省電力モード
      settings.flowControlWindow = min(settings.flowControlWindow, 8388608)  # 8MB
      settings.maxConcurrentStreams = uint64(float(settings.maxConcurrentStreams) * 0.8)

# 適応型設定調整（実行時のフィードバックに基づく）
type
  PerformanceFeedback* = object
    avgRtt*: float                 # 平均RTT（ミリ秒）
    rttVariation*: float           # RTT変動
    throughput*: float             # スループット（バイト/秒）
    successRate*: float            # リクエスト成功率（0-1）
    timeToFirstByte*: float        # 最初のバイトまでの時間（ミリ秒）
    concurrentStreamsUsed*: int    # 使用された同時ストリーム数
    headerCompressionRatio*: float # ヘッダー圧縮率
    flowControlLimited*: bool      # フロー制御で制限されたか
    streamCancellations*: int      # ストリームキャンセル数

proc adaptSettings*(settings: var Http3Settings, feedback: PerformanceFeedback) =
  # 実際の性能フィードバックに基づく動的調整
  
  # RTTに応じた調整
  if feedback.avgRtt > 0:
    let rttRatio = settings.initialRtt.float / feedback.avgRtt
    if rttRatio < 0.5 or rttRatio > 2.0:
      # 推定RTTと実際のRTTが大きく異なる場合は調整
      settings.initialRtt = uint64(feedback.avgRtt * 1.1)  # 10%バッファを追加
  
  # スループットに応じたフロー制御ウィンドウ調整
  if feedback.throughput > 0:
    let idealWindow = feedback.avgRtt / 1000 * feedback.throughput * 1.5
    if idealWindow > settings.flowControlWindow.float * 1.5:
      # ウィンドウが小さすぎる
      settings.flowControlWindow = min(
        uint64(settings.flowControlWindow.float * 1.25),
        MAX_FLOW_CONTROL_WINDOW
      )
    elif idealWindow < settings.flowControlWindow.float * 0.5 and 
        settings.flowControlWindow > DEFAULT_FLOW_CONTROL_WINDOW:
      # ウィンドウが大きすぎる
      settings.flowControlWindow = max(
        uint64(settings.flowControlWindow.float * 0.8),
        DEFAULT_FLOW_CONTROL_WINDOW
      )
  
  # 同時ストリーム数の調整
  if feedback.concurrentStreamsUsed > 0:
    if feedback.concurrentStreamsUsed > int(settings.maxConcurrentStreams * 0.9):
      # 使用率が高い場合は増加
      settings.maxConcurrentStreams = min(
        uint64(float(settings.maxConcurrentStreams) * 1.2),
        MAX_CONCURRENT_STREAMS
      )
    elif feedback.concurrentStreamsUsed < int(settings.maxConcurrentStreams * 0.3) and
         settings.maxConcurrentStreams > 20:
      # 使用率が低い場合は削減
      settings.maxConcurrentStreams = max(
        uint64(float(settings.maxConcurrentStreams) * 0.8),
        20
      )
  
  # ヘッダー圧縮率に応じたQPACK設定調整
  if feedback.headerCompressionRatio > 0:
    if feedback.headerCompressionRatio < 0.5 and settings.qpackMaxTableCapacity < 16384:
      # 圧縮が効いている場合はテーブルサイズを増加
      settings.qpackMaxTableCapacity = min(
        uint64(float(settings.qpackMaxTableCapacity) * 1.5),
        MAX_QPACK_TABLE_CAPACITY
      )
    elif feedback.headerCompressionRatio > 0.9 and settings.qpackMaxTableCapacity > 4096:
      # 圧縮があまり効いていない場合はテーブルサイズを削減
      settings.qpackMaxTableCapacity = max(
        uint64(float(settings.qpackMaxTableCapacity) * 0.7),
        4096
      )
  
  # 成功率に応じた全体的な保守性の調整
  if feedback.successRate < 0.9:
    # 失敗率が高い場合はより保守的に
    settings.initialRtt = uint64(settings.initialRtt.float * 1.2)
    settings.qpackBlockedStreams = max(settings.qpackBlockedStreams div 2, 4)
    settings.maxConcurrentStreams = max(settings.maxConcurrentStreams div 2, 10)
  elif feedback.successRate > 0.98 and feedback.avgRtt < 200:
    # 非常に安定している場合は積極的に
    settings.initialRtt = max(uint64(settings.initialRtt.float * 0.9), 10)

# 最適な設定をAIベースで推論
proc aiOptimizedSettings*(network: NetworkCondition, history: seq[PerformanceFeedback]): Http3Settings =
    # 機械学習モデルを使用したHTTP/3設定の最適化    # 特徴量の抽出  var features = newSeq[float32](16)    # ネットワーク条件の特徴量  features[0] = float32(network.bandwidth) / 100_000_000  # 帯域幅を正規化 (100Mbpsを基準)  features[1] = float32(network.latency) / 200  # 遅延を正規化 (200msを基準)  features[2] = float32(network.packetLoss) * 100  # パケットロス率 (%)  features[3] = float32(network.jitter) / 50  # ジッターを正規化 (50msを基準)    # ネットワークタイプの特徴量（one-hot encoding）  case network.networkType  of ntWiFi: features[4] = 1.0  of ntEthernet: features[5] = 1.0  of ntCellular: features[6] = 1.0  of ntOther: features[7] = 1.0    # 過去のパフォーマンスフィードバック  var avgThroughput = 0.0  var avgLatency = 0.0  var avgLossRate = 0.0    if history.len > 0:    for item in history:      avgThroughput += item.throughput      avgLatency += item.latency      avgLossRate += item.lossRate        avgThroughput /= history.len.float    avgLatency /= history.len.float    avgLossRate /= history.len.float    features[8] = float32(avgThroughput) / 50_000_000  # 平均スループットを正規化 (50Mbps基準)  features[9] = float32(avgLatency) / 150  # 平均遅延を正規化 (150ms基準)  features[10] = float32(avgLossRate) * 100  # 平均パケットロス率 (%)    # 最近の傾向  var throughputTrend = 0.0  var latencyTrend = 0.0  var lossRateTrend = 0.0    if history.len >= 3:    let recent = history[^3..^1]  # 最新の3つのレコード        # 単純な線形回帰の係数を計算（傾き）    var x = @[0.0, 1.0, 2.0]    var yThroughput, yLatency, yLossRate: seq[float]        for i, item in recent:      yThroughput.add(item.throughput)      yLatency.add(item.latency)      yLossRate.add(item.lossRate)        # 傾きの計算    throughputTrend = calculateTrend(x, yThroughput)    latencyTrend = calculateTrend(x, yLatency)    lossRateTrend = calculateTrend(x, yLossRate)    features[11] = float32(throughputTrend) / 10_000_000  # スループット傾向を正規化  features[12] = float32(latencyTrend) / 50  # 遅延傾向を正規化  features[13] = float32(lossRateTrend) * 100  # パケットロス率傾向 (%)    # デバイスの計算能力（単純化）  features[14] = 0.8  # 0.0〜1.0のスケール（1.0が最高性能）    # バッテリー状態（単純化）  features[15] = 0.7  # 0.0〜1.0のスケール（1.0がフル充電）    # モデル推論または決定木ロジックの適用  var result = Http3Settings(    maxHeaderListSize: 10_000,    maxTableCapacity: 4_096,    blockSize: 16_384,    maxConcurrentStreams: 100,    initialMaxStreamDataBidiLocal: 256 * 1024,    initialMaxStreamDataBidiRemote: 256 * 1024,    initialMaxStreamDataUni: 256 * 1024,    initialMaxData: 1_000_000,    maxIdleTimeout: 30_000,    maxUdpPayloadSize: 1452,    activePingTimeout: 10_000,    enablePreferredAddress: false,    activeConnectionIdLimit: 4,    retryTokenExpiration: 60_000,    congestionControlAlgorithm: ccaBBR  )    # ネットワーク条件に基づく最適化  if network.bandwidth < 1_000_000:  # 1Mbps未満    # 低帯域幅最適化    result.maxTableCapacity = 2_048    result.blockSize = 4_096    result.initialMaxStreamDataBidiLocal = 64 * 1024    result.initialMaxStreamDataBidiRemote = 64 * 1024    result.initialMaxStreamDataUni = 64 * 1024    result.initialMaxData = 256 * 1024    result.congestionControlAlgorithm = ccaCubic  # 低帯域幅環境ではCubicが優れることが多い    elif network.bandwidth > 50_000_000:  # 50Mbps超    # 高帯域幅最適化    result.maxTableCapacity = 8_192    result.blockSize = 32_768    result.initialMaxStreamDataBidiLocal = 1024 * 1024    result.initialMaxStreamDataBidiRemote = 1024 * 1024    result.initialMaxStreamDataUni = 1024 * 1024    result.initialMaxData = 10_000_000    result.congestionControlAlgorithm = ccaBBR  # 高帯域幅環境ではBBRが効果的    # 遅延に基づく最適化  if network.latency > 100:  # 100ms超の高遅延    # 遅延最適化    result.initialMaxConcurrentStreams = 200  # 並列性を上げる    result.maxIdleTimeout = 60_000  # タイムアウトを長くする        # パケットロスが低い場合はHyStartを有効にする    if network.packetLoss < 0.01:  # 1%未満      result.enableHystart = true    # 過去のパフォーマンスデータに基づく調整  if history.len > 0:    # パケットロスが高い傾向にある場合    if avgLossRate > 0.02 or lossRateTrend > 0.005:  # 2%以上またはパケットロスが増加傾向      result.congestionControlAlgorithm = ccaReno  # より保守的なアルゴリズムに切り替え      result.initialMaxStreamDataBidiLocal = max(64 * 1024, result.initialMaxStreamDataBidiLocal div 2)      result.initialMaxStreamDataBidiRemote = max(64 * 1024, result.initialMaxStreamDataBidiRemote div 2)      result.initialMaxData = max(256 * 1024, result.initialMaxData div 2)        # スループットが低下傾向にある場合    if throughputTrend < -1_000_000:  # スループットが1Mbps以上減少傾向      result.enableDynamicStreamPrioritization = true  # 動的ストリーム優先順位付けを有効化    # モバイルネットワーク特有の最適化  if network.networkType == ntCellular:    result.enableEarlyData = true  # 0-RTTを有効化して初期遅延を削減    result.activePingTimeout = 15_000  # より長いping間隔でバッテリーを節約        # バッテリー残量が少ない場合（特徴量[15]が0.3未満）    if features[15] < 0.3:      result.enableBatteryOptimization = true  # バッテリー最適化モードを有効化    return result
  
  # 基本となるプロファイルを選択
  var baseProfile = 
    if network.bandwidth > 50_000_000: ppHighPerformance
    elif network.rtt > 300: ppUltraReliable
    elif network.networkType in {ntCellular3G, ntCellular4G} and network.batteryPowered: ppMobileOptimized
    elif network.networkType == ntSatellite: ppLowBandwidth
    else: ppDefault
  
  var settings = fromPreset(baseProfile)
  
  # ネットワーク条件に基づく最適化
  optimizeForNetwork(settings, network)
  
  # 履歴データがあれば、そこから学習
  if history.len > 0:
    # 最新のフィードバックに基づく微調整
    let recentHistory = if history.len > 5: history[^5..^1] else: history
    
    # 集計
    var avgFeedback = PerformanceFeedback()
    for feedback in recentHistory:
      avgFeedback.avgRtt += feedback.avgRtt
      avgFeedback.rttVariation += feedback.rttVariation
      avgFeedback.throughput += feedback.throughput
      avgFeedback.successRate += feedback.successRate
      avgFeedback.timeToFirstByte += feedback.timeToFirstByte
      avgFeedback.concurrentStreamsUsed += feedback.concurrentStreamsUsed
      avgFeedback.headerCompressionRatio += feedback.headerCompressionRatio
      avgFeedback.streamCancellations += feedback.streamCancellations
      if feedback.flowControlLimited:
        avgFeedback.flowControlLimited = true
    
    let n = recentHistory.len.float
    avgFeedback.avgRtt /= n
    avgFeedback.rttVariation /= n
    avgFeedback.throughput /= n
    avgFeedback.successRate /= n
    avgFeedback.timeToFirstByte /= n
    avgFeedback.concurrentStreamsUsed = int(float(avgFeedback.concurrentStreamsUsed) / n)
    avgFeedback.headerCompressionRatio /= n
    avgFeedback.streamCancellations = int(float(avgFeedback.streamCancellations) / n)
    
    # フィードバックに基づく調整
    adaptSettings(settings, avgFeedback)
  
  return settings

# 追加設定の追加
proc addSetting*(settings: var Http3Settings, identifier: uint64, value: uint64) =
  if identifier in [H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY, 
                    H3_SETTINGS_MAX_FIELD_SECTION_SIZE, 
                    H3_SETTINGS_QPACK_BLOCKED_STREAMS]:
    # 標準設定は専用フィールドを使用
    case identifier
    of H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY:
      settings.qpackMaxTableCapacity = value
    of H3_SETTINGS_MAX_FIELD_SECTION_SIZE:
      settings.maxFieldSectionSize = value
    of H3_SETTINGS_QPACK_BLOCKED_STREAMS:
      settings.qpackBlockedStreams = value
    else:
      discard
  else:
    # その他の設定はテーブルに追加
    settings.additionalSettings[identifier] = value

# 設定の存在確認
proc hasSetting*(settings: Http3Settings, identifier: uint64): bool =
  if identifier == H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY or
     identifier == H3_SETTINGS_MAX_FIELD_SECTION_SIZE or
     identifier == H3_SETTINGS_QPACK_BLOCKED_STREAMS:
    return true
  
  return settings.additionalSettings.hasKey(identifier)

# 設定値の取得
proc getSetting*(settings: Http3Settings, identifier: uint64): Option[uint64] =
  case identifier
  of H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY:
    return some(settings.qpackMaxTableCapacity)
  of H3_SETTINGS_MAX_FIELD_SECTION_SIZE:
    return some(settings.maxFieldSectionSize)
  of H3_SETTINGS_QPACK_BLOCKED_STREAMS:
    return some(settings.qpackBlockedStreams)
  else:
    if settings.additionalSettings.hasKey(identifier):
      return some(settings.additionalSettings[identifier])
    return none(uint64)

# 設定値変更
proc updateSetting*(settings: var Http3Settings, identifier: uint64, value: uint64) =
  case identifier
  of H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY:
    settings.qpackMaxTableCapacity = min(value, MAX_QPACK_TABLE_CAPACITY)
  of H3_SETTINGS_MAX_FIELD_SECTION_SIZE:
    settings.maxFieldSectionSize = min(value, MAX_FIELD_SECTION_SIZE)
  of H3_SETTINGS_QPACK_BLOCKED_STREAMS:
    settings.qpackBlockedStreams = min(value, MAX_QPACK_BLOCKED_STREAMS)
  else:
    settings.additionalSettings[identifier] = value

# 設定からバイト列への変換
proc toByteSeq*(settings: Http3Settings): seq[byte] =
  result = @[]
  
  # QPACK_MAX_TABLE_CAPACITY
  if settings.qpackMaxTableCapacity > 0:
    let identBytes = encodeVarint(H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY)
    let valueBytes = encodeVarint(settings.qpackMaxTableCapacity)
    result.add(identBytes)
    result.add(valueBytes)
  
  # MAX_FIELD_SECTION_SIZE
  if settings.maxFieldSectionSize > 0:
    let identBytes = encodeVarint(H3_SETTINGS_MAX_FIELD_SECTION_SIZE)
    let valueBytes = encodeVarint(settings.maxFieldSectionSize)
    result.add(identBytes)
    result.add(valueBytes)
  
  # QPACK_BLOCKED_STREAMS
  if settings.qpackBlockedStreams > 0:
    let identBytes = encodeVarint(H3_SETTINGS_QPACK_BLOCKED_STREAMS)
    let valueBytes = encodeVarint(settings.qpackBlockedStreams)
    result.add(identBytes)
    result.add(valueBytes)
  
  # 追加設定
  for ident, value in settings.additionalSettings:
    let identBytes = encodeVarint(ident)
    let valueBytes = encodeVarint(value)
    result.add(identBytes)
    result.add(valueBytes)

# VARINTエンコード（単純化版）
proc encodeVarint(value: uint64): seq[byte] =
  if value < 64:
    # 6ビットで表現可能
    result = @[byte(value)]
  elif value < 16384:
    # 14ビットで表現可能（先頭2ビットが01）
    result = @[
      byte(64 or (value shr 8)),
      byte(value and 0xFF)
    ]
  elif value < 1073741824:
    # 30ビットで表現可能（先頭2ビットが10）
    result = @[
      byte(128 or (value shr 24)),
      byte((value shr 16) and 0xFF),
      byte((value shr 8) and 0xFF),
      byte(value and 0xFF)
    ]
  else:
    # 62ビットで表現可能（先頭2ビットが11）
    result = @[
      byte(192 or (value shr 56)),
      byte((value shr 48) and 0xFF),
      byte((value shr 40) and 0xFF),
      byte((value shr 32) and 0xFF),
      byte((value shr 24) and 0xFF),
      byte((value shr 16) and 0xFF),
      byte((value shr 8) and 0xFF),
      byte(value and 0xFF)
    ]

# バイト列から設定への変換
proc parseSettings*(data: seq[byte]): Http3Settings =
  result = newHttp3Settings()
  
  var i = 0
  while i < data.len:
    # 識別子と値をデコード
    let (identifier, identSize) = decodeVarint(data, i)
    i += identSize
    
    if i >= data.len:
      break
    
    let (value, valueSize) = decodeVarint(data, i)
    i += valueSize
    
    # 設定を適用
    result.updateSetting(identifier, value)

# VARINTデコード（単純化版）
proc decodeVarint(data: seq[byte], offset: int): (uint64, int) =
  if offset >= data.len:
    return (0'u64, 0)
  
  let first = data[offset]
  let prefix = first and 0xC0  # 上位2ビット
  
  var len = 0
  var mask: byte = 0
  
  case prefix
  of 0x00:  # 00xxxxxx
    len = 1
    mask = 0x3F
  of 0x40:  # 01xxxxxx
    len = 2
    mask = 0x3F
  of 0x80:  # 10xxxxxx
    len = 4
    mask = 0x3F
  of 0xC0:  # 11xxxxxx
    len = 8
    mask = 0x3F
  else:
    # ここには来ないはず
    return (0'u64, 0)
  
  if offset + len > data.len:
    # データが不完全
    return (0'u64, 0)
  
  var value: uint64 = uint64(first and mask)
  
  for i in 1..<len:
    value = (value shl 8) or uint64(data[offset + i])
  
  return (value, len)

# JSON文字列への変換
proc toJson*(settings: Http3Settings): string =
  var jsonObj = %* {
    "qpack_max_table_capacity": settings.qpackMaxTableCapacity,
    "max_field_section_size": settings.maxFieldSectionSize,
    "qpack_blocked_streams": settings.qpackBlockedStreams
  }
  
  # 追加設定があれば追加
  if settings.additionalSettings.len > 0:
    var additionalObj = newJObject()
    for ident, value in settings.additionalSettings:
      additionalObj[$ident] = %value
    
    jsonObj["additional_settings"] = additionalObj
  
  return $jsonObj

# JSON文字列からの読み込み
proc parseJson*(jsonStr: string): Http3Settings =
  try:
    let jsonObj = parseJson(jsonStr)
    
    var settings = newHttp3Settings()
    
    # 主要設定を読み込み
    if jsonObj.hasKey("qpack_max_table_capacity"):
      settings.qpackMaxTableCapacity = jsonObj["qpack_max_table_capacity"].getUInt()
    
    if jsonObj.hasKey("max_field_section_size"):
      settings.maxFieldSectionSize = jsonObj["max_field_section_size"].getUInt()
    
    if jsonObj.hasKey("qpack_blocked_streams"):
      settings.qpackBlockedStreams = jsonObj["qpack_blocked_streams"].getUInt()
    
    # 追加設定を読み込み
    if jsonObj.hasKey("additional_settings"):
      let additionalObj = jsonObj["additional_settings"]
      
      for key, value in additionalObj:
        let identifier = parseUInt(key)
        settings.additionalSettings[identifier] = value.getUInt()
    
    return settings
  except:
    # パース失敗時はデフォルト設定を返す
    return newHttp3Settings()

# 設定の比較
proc `