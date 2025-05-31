# ネットワーク状態に基づく設定最適化機能を追加

import std/[strutils, strformat, options, tables, json, sets]
import std/[times, math, algorithm, hashes, sequtils]

type
  Http3Settings* = ref object
    ## HTTP/3プロトコル設定
    qpackMaxTableCapacity*: uint64       # QPACK動的テーブルの最大容量（バイト）
    maxFieldSectionSize*: uint64         # ヘッダーセクションの最大サイズ（バイト）
    qpackBlockedStreams*: uint64         # QPACKの処理待ちストリーム最大数
    additionalSettings*: Table[uint64, uint64] # 追加の設定パラメータ
    flowControlWindow*: uint64           # フロー制御ウィンドウサイズ（新規追加）
    maxConcurrentStreams*: uint64        # 同時ストリーム最大数（新規追加）
    initialRtt*: int64                  # 初期RTT推定値（新規追加）
    maxIdleTimeout*: int64              # 最大アイドルタイムアウト（新規追加）
    activeConnectionMigration*: bool     # アクティブな接続移行（新規追加）
    preferredAddressMode*: int          # 優先アドレスモード（新規追加）
    datagramSupport*: bool               # データグラムサポート（新規追加）
    optimizationProfile*: OptimizationProfile # 最適化プロファイル（新規追加）
    extensiblePriorities*: bool          # RFC 9218拡張優先度対応
    grease*: bool                       # GREASEビット対応
    binaryHeaders*: bool                 # バイナリヘッダーサポート
    enableQuantumMode*: bool             # 量子最適化モード
    pacing*: bool                        # パケットペーシング
    dynamicStreamScheduling*: bool        # 動的ストリームスケジューリング
    prefetchHints*: bool                  # プリフェッチヒントサポート
    hybridRtt*: bool                       # ハイブリッドRTT測定
    multipleAckRanges*: bool               # 複数ACK範囲対応
    intelligentRetransmission*: bool        # 知的再送戦略

  Http3SettingsOption* = enum
    ## 設定オプション
    soQpackDynamicTable     # QPACK動的テーブルを使用
    soHeaderCompression     # ヘッダー圧縮を最適化
    soServerPush            # サーバープッシュを許可
    soFlowControl           # フロー制御を細かく調整
    soMaxConcurrency        # 同時リクエスト数を増加
    soLongLivedConnection   # 長時間接続の最適化
    soLowLatency            # 低遅延優先
    soHighThroughput        # 高スループット優先
    soBatteryEfficient      # バッテリー効率優先（新規追加）
    soReliability           # 信頼性優先（新規追加）
    soLowMemory             # メモリ使用量最小化（新規追加）
    soSecurityStrict        # 厳格なセキュリティ（新規追加）
    soReliableTransfer      # 信頼性重視
    soStreamPrioritization  # ストリーム優先度付け
    soDatagramSupport       # QUICデータグラム対応
    soQuantumAcceleration   # 量子加速モード

  OptimizationProfile* = enum
    opBalanced,         # バランス型
    opLowLatency,       # 低遅延型
    opHighThroughput,   # 高スループット型
    opLowBandwidth,     # 低帯域型
    opBatteryEfficient, # バッテリー効率型
    opMobile,           # モバイル型
    opDesktop,          # デスクトップ型
    opReliability,      # 信頼性重視
    opSatellite,         # 衛星回線最適化
    opQuantum            # 量子最適化（最先端設定）

  NetworkCondition* = object
    ## ネットワーク状態
    bandwidth*: float               # 推定帯域（ビット/秒）
    rtt*: float                     # RTT（ミリ秒）
    packetLoss*: float              # パケットロス率（0-1）
    jitter*: float                  # ジッター（ミリ秒）
    networkType*: NetworkType       # ネットワークタイプ
    congestion*: float              # 輻輳レベル（0-1）
    batteryPowered*: bool           # バッテリー電源使用フラグ
    batteryLevel*: float            # バッテリーレベル（0-1）
    signalStrength*: Option[float]  # 信号強度（0-1、無線の場合）

  NetworkType* = enum
    ntUnknown,         # 不明
    ntWifi,            # WiFi
    ntEthernet,        # 有線LAN
    ntCellular4G,      # 4G携帯
    ntCellular5G,      # 5G携帯
    ntCellular3G,      # 3G携帯
    ntSatellite,       # 衛星
    ntVPN              # VPN

  PresetProfile* = enum
    ppDefault,         # デフォルト
    ppMobileOptimized, # モバイル最適化
    ppHighPerformance, # 高性能
    ppLowBandwidth,    # 低帯域
    ppUltraReliable,   # 超高信頼性
    ppGaming,          # ゲーム向け
    ppStreaming,       # ストリーミング向け
    ppIoT              # IoT向け

const
  # 設定識別子の定数
  H3_SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0x01
  H3_SETTINGS_MAX_FIELD_SECTION_SIZE = 0x06
  H3_SETTINGS_QPACK_BLOCKED_STREAMS = 0x07
  H3_SETTINGS_FLOW_CONTROL_WINDOW = 0x08  # 独自拡張
  H3_SETTINGS_MAX_CONCURRENT_STREAMS = 0x09  # 独自拡張
  H3_SETTINGS_INITIAL_RTT = 0x0A  # 独自拡張
  H3_SETTINGS_MAX_IDLE_TIMEOUT = 0x0B  # 独自拡張
  H3_SETTINGS_PREFERRED_ADDRESS_MODE = 0x0C  # 独自拡張
  
  # デフォルト値
  DEFAULT_QPACK_MAX_TABLE_CAPACITY = 4096   # 4KB
  DEFAULT_MAX_FIELD_SECTION_SIZE = 65536    # 64KB
  DEFAULT_QPACK_BLOCKED_STREAMS = 16        # 16ストリーム
  DEFAULT_FLOW_CONTROL_WINDOW = 16777216    # 16MB
  DEFAULT_MAX_CONCURRENT_STREAMS = 100      # 100ストリーム
  DEFAULT_INITIAL_RTT = 100                 # 100ms
  DEFAULT_MAX_IDLE_TIMEOUT = 30000          # 30秒
  
  # 最大値
  MAX_QPACK_TABLE_CAPACITY = 16_777_216     # 16MB
  MAX_FIELD_SECTION_SIZE = 1_048_576        # 1MB
  MAX_QPACK_BLOCKED_STREAMS = 128           # 128ストリーム
  MAX_FLOW_CONTROL_WINDOW = 1_073_741_824   # 1GB
  MAX_CONCURRENT_STREAMS = 1000             # 1000ストリーム

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
  result = Http3Settings(
    qpackMaxTableCapacity: DEFAULT_QPACK_MAX_TABLE_CAPACITY,
    maxFieldSectionSize: DEFAULT_MAX_FIELD_SECTION_SIZE,
    qpackBlockedStreams: DEFAULT_QPACK_BLOCKED_STREAMS,
    additionalSettings: initTable[uint64, uint64](),
    flowControlWindow: DEFAULT_FLOW_CONTROL_WINDOW,
    maxConcurrentStreams: DEFAULT_MAX_CONCURRENT_STREAMS,
    initialRtt: DEFAULT_INITIAL_RTT,
    maxIdleTimeout: DEFAULT_MAX_IDLE_TIMEOUT,
    activeConnectionMigration: true,
    preferredAddressMode: 1,
    datagramSupport: false,
    optimizationProfile: opBalanced,
    extensiblePriorities: true,
    grease: true,
    binaryHeaders: false,
    enableQuantumMode: false,
    pacing: true,
    dynamicStreamScheduling: true,
    prefetchHints: true,
    hybridRtt: true,
    multipleAckRanges: true,
    intelligentRetransmission: true
  )

# カスタム設定でインスタンスを生成
proc newHttp3Settings*(qpackMaxTableCapacity: uint64,
                     maxFieldSectionSize: uint64,
                     qpackBlockedStreams: uint64,
                     flowControlWindow: uint64 = DEFAULT_FLOW_CONTROL_WINDOW,
                     maxConcurrentStreams: uint64 = DEFAULT_MAX_CONCURRENT_STREAMS): Http3Settings =
  result = Http3Settings(
    qpackMaxTableCapacity: qpackMaxTableCapacity,
    maxFieldSectionSize: maxFieldSectionSize,
    qpackBlockedStreams: qpackBlockedStreams,
    additionalSettings: initTable[uint64, uint64](),
    flowControlWindow: flowControlWindow,
    maxConcurrentStreams: maxConcurrentStreams,
    initialRtt: DEFAULT_INITIAL_RTT,
    maxIdleTimeout: DEFAULT_MAX_IDLE_TIMEOUT,
    activeConnectionMigration: true,
    preferredAddressMode: 1,
    datagramSupport: false,
    optimizationProfile: opBalanced,
    extensiblePriorities: true,
    grease: true,
    binaryHeaders: false,
    enableQuantumMode: false,
    pacing: true,
    dynamicStreamScheduling: true,
    prefetchHints: true,
    hybridRtt: true,
    multipleAckRanges: true,
    intelligentRetransmission: true
  )

# 最適化プリセットから設定を生成
proc optimizedSettings*(options: set[Http3SettingsOption]): Http3Settings =
  var settings = newHttp3Settings()
  
  if soQpackDynamicTable in options:
    # QPACKの動的テーブルサイズを増加
    settings.qpackMaxTableCapacity = 16384 # 16KB
  
  if soHeaderCompression in options:
    # ヘッダー圧縮を最適化
    settings.qpackMaxTableCapacity = 32768 # 32KB
    settings.qpackBlockedStreams = 32
  
  if soMaxConcurrency in options:
    # 同時リクエスト数を最大化
    settings.qpackBlockedStreams = 64
    settings.maxConcurrentStreams = 500
  
  if soHighThroughput in options:
    # 高スループット向け設定
    settings.qpackMaxTableCapacity = 65536 # 64KB
    settings.maxFieldSectionSize = 262144  # 256KB
    settings.qpackBlockedStreams = 64
    settings.flowControlWindow = 67108864  # 64MB
    settings.optimizationProfile = opHighThroughput
    settings.pacing = true
    settings.dynamicStreamScheduling = true
  
  if soLowLatency in options:
    # 低遅延向け設定
    settings.qpackMaxTableCapacity = 8192  # 8KB
    settings.qpackBlockedStreams = 32
    settings.initialRtt = 50  # 50ms
    settings.optimizationProfile = opLowLatency
    settings.hybridRtt = true
    settings.multipleAckRanges = true
  
  if soLongLivedConnection in options:
    # 長時間接続向け
    settings.maxIdleTimeout = 300000  # 5分
    settings.activeConnectionMigration = true
    settings.preferredAddressMode = 2  # 積極的アドレス変更
  
  if soReliableTransfer in options:
    # 信頼性重視
    settings.optimizationProfile = opReliability
    settings.intelligentRetransmission = true
    settings.initialRtt = 100  # 保守的な初期RTT
  
  if soStreamPrioritization in options:
    # ストリーム優先度付け最適化
    settings.extensiblePriorities = true
  
  if soDatagramSupport in options:
    # QUICデータグラムサポート
    settings.datagramSupport = true
  
  if soFlowControl in options:
    # フロー制御最適化
    settings.flowControlWindow = 33554432  # 32MB
  
  if soQuantumAcceleration in options:
    # 量子加速モード (最先端設定)
    settings.enableQuantumMode = true
    settings.optimizationProfile = opQuantum
    settings.qpackMaxTableCapacity = 131072 # 128KB
    settings.flowControlWindow = 134217728  # 128MB
    settings.maxConcurrentStreams = 1000
    settings.prefetchHints = true
    settings.dynamicStreamScheduling = true
    settings.pacing = true
    settings.hybridRtt = true
    settings.intelligentRetransmission = true
  
  return settings

# プリセットプロファイルから設定を生成
proc fromPreset*(preset: PresetProfile): Http3Settings =
  case preset
  of ppDefault:
    return newHttp3Settings()
  
  of ppMobileOptimized:
    var settings = newHttp3Settings(
      4096,   # 4KB QPACK
      32768,  # 32KB ヘッダーサイズ
      16      # 16 ブロックストリーム
    )
    settings.flowControlWindow = 8388608  # 8MB
    settings.maxConcurrentStreams = 50
    settings.initialRtt = 150
    settings.maxIdleTimeout = 60000
    settings.optimizationProfile = opMobile
    return settings
  
  of ppHighPerformance:
    var settings = newHttp3Settings(
      65536,  # 64KB QPACK
      262144, # 256KB ヘッダーサイズ
      64      # 64 ブロックストリーム
    )
    settings.flowControlWindow = 134217728  # 128MB
    settings.maxConcurrentStreams = 500
    settings.initialRtt = 30
    settings.maxIdleTimeout = 120000
    settings.optimizationProfile = opHighThroughput
    return settings
  
  of ppLowBandwidth:
    var settings = newHttp3Settings(
      2048,   # 2KB QPACK
      16384,  # 16KB ヘッダーサイズ
      8       # 8 ブロックストリーム
    )
    settings.flowControlWindow = 4194304  # 4MB
    settings.maxConcurrentStreams = 20
    settings.initialRtt = 300
    settings.optimizationProfile = opLowBandwidth
    return settings
  
  of ppUltraReliable:
    var settings = newHttp3Settings(
      8192,   # 8KB QPACK
      65536,  # 64KB ヘッダーサイズ
      32      # 32 ブロックストリーム
    )
    settings.flowControlWindow = 33554432  # 32MB
    settings.maxConcurrentStreams = 50
    settings.initialRtt = 500  # 高めに設定して保守的に
    settings.maxIdleTimeout = 600000  # 10分
    settings.activeConnectionMigration = true
    return settings
  
  of ppGaming:
    var settings = newHttp3Settings(
      2048,   # 2KB QPACK（小さめ）
      16384,  # 16KB ヘッダーサイズ
      16      # 16 ブロックストリーム
    )
    settings.flowControlWindow = 16777216  # 16MB
    settings.maxConcurrentStreams = 30
    settings.initialRtt = 20  # 非常に低いRTT目標
    settings.maxIdleTimeout = 30000
    settings.optimizationProfile = opLowLatency
    return settings
  
  of ppStreaming:
    var settings = newHttp3Settings(
      32768,  # 32KB QPACK
      131072, # 128KB ヘッダーサイズ
      32      # 32 ブロックストリーム
    )
    settings.flowControlWindow = 268435456  # 256MB
    settings.maxConcurrentStreams = 10
    settings.initialRtt = 50
    settings.maxIdleTimeout = 300000
    settings.optimizationProfile = opHighThroughput
    return settings
  
  of ppIoT:
    var settings = newHttp3Settings(
      1024,   # 1KB QPACK（超小型）
      8192,   # 8KB ヘッダーサイズ
      4       # 4 ブロックストリーム
    )
    settings.flowControlWindow = 1048576  # 1MB
    settings.maxConcurrentStreams = 5
    settings.initialRtt = 200
    settings.maxIdleTimeout = 1800000  # 30分
    settings.optimizationProfile = opBatteryEfficient
    return settings

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
    settings.initialRtt = int64(max(settings.initialRtt.float, network.rtt * 1.5))
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
    settings.initialRtt = int64(settings.initialRtt.float * 1.2)
  
  else:
    discard

  # ジッターに応じた設定
  if network.jitter > 50:  # 高ジッター
    settings.initialRtt = int64(settings.initialRtt.float + network.jitter * 0.5)
  
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
      settings.initialRtt = int64(feedback.avgRtt * 1.1)  # 10%バッファを追加
  
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
    settings.initialRtt = int64(settings.initialRtt.float * 1.2)
    settings.qpackBlockedStreams = max(settings.qpackBlockedStreams div 2, 4)
    settings.maxConcurrentStreams = max(settings.maxConcurrentStreams div 2, 10)
  elif feedback.successRate > 0.98 and feedback.avgRtt < 200:
    # 非常に安定している場合は積極的に
    settings.initialRtt = max(int64(settings.initialRtt.float * 0.9), 10)

# 最適な設定をAIベースで推論
proc aiOptimizedSettings*(network: NetworkCondition, history: seq[PerformanceFeedback]): Http3Settings =
  # 機械学習モデルで最適なHTTP/3設定を推論
  let model = loadHttp3SettingsModel()
  result = model.predict(network, history)

# 設定の比較
proc `==`*(a, b: Http3Settings): bool =
  if a.qpackMaxTableCapacity != b.qpackMaxTableCapacity:
    return false
  if a.maxFieldSectionSize != b.maxFieldSectionSize:
    return false
  if a.qpackBlockedStreams != b.qpackBlockedStreams:
    return false
  if a.flowControlWindow != b.flowControlWindow:
    return false
  if a.maxConcurrentStreams != b.maxConcurrentStreams:
    return false
  if a.initialRtt != b.initialRtt:
    return false
  if a.maxIdleTimeout != b.maxIdleTimeout:
    return false
  if a.activeConnectionMigration != b.activeConnectionMigration:
    return false
  if a.preferredAddressMode != b.preferredAddressMode:
    return false
  if a.datagramSupport != b.datagramSupport:
    return false
  if a.optimizationProfile != b.optimizationProfile:
    return false
  if a.extensiblePriorities != b.extensiblePriorities:
    return false
  if a.grease != b.grease:
    return false
  if a.binaryHeaders != b.binaryHeaders:
    return false
  if a.enableQuantumMode != b.enableQuantumMode:
    return false
  if a.pacing != b.pacing:
    return false
  if a.dynamicStreamScheduling != b.dynamicStreamScheduling:
    return false
  if a.prefetchHints != b.prefetchHints:
    return false
  if a.hybridRtt != b.hybridRtt:
    return false
  if a.multipleAckRanges != b.multipleAckRanges:
    return false
  if a.intelligentRetransmission != b.intelligentRetransmission:
    return false
  
  # 追加設定を比較
  if a.additionalSettings.len != b.additionalSettings.len:
    return false
  
  for ident, value in a.additionalSettings:
    if not b.additionalSettings.hasKey(ident) or
       b.additionalSettings[ident] != value:
      return false
  
  return true

# 文字列表現
proc `$`*(settings: Http3Settings): string =
  var profileStr = case settings.optimizationProfile
    of opBalanced: "Balanced"
    of opLowLatency: "Low Latency"
    of opHighThroughput: "High Throughput"
    of opLowBandwidth: "Low Bandwidth"
    of opBatteryEfficient: "Battery Efficient"
    of opMobile: "Mobile"
    of opDesktop: "Desktop"
    of opReliability: "Reliability"
    of opSatellite: "Satellite"
    of opQuantum: "Quantum"
  
  var additionalStr = ""
  if settings.additionalSettings.len > 0:
    var pairs: seq[string] = @[]
    for ident, value in settings.additionalSettings:
      pairs.add($ident & "=" & $value)
    additionalStr = ", additional={" & pairs.join(", ") & "}"
  
  result = fmt"Http3Settings(profile={profileStr}, " &
           fmt"qpackTable={settings.qpackMaxTableCapacity}, " &
           fmt"maxFieldSize={settings.maxFieldSectionSize}, " &
           fmt"blockedStreams={settings.qpackBlockedStreams}, " &
           fmt"flowWindow={settings.flowControlWindow}, " &
           fmt"maxStreams={settings.maxConcurrentStreams}, " &
           fmt"initRtt={settings.initialRtt}ms, " &
           fmt"idleTimeout={settings.maxIdleTimeout}ms" &
           fmt"{additionalStr})" 