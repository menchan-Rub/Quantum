# Nimネットワーク層最適化設定
#
# Quantum Browser向け高度なネットワーク最適化設定
# 異なるネットワーク環境に応じた最適なパフォーマンス設定

import std/[
  tables,
  json,
  strutils,
  strformat,
  options,
  os
]

# 定数定義
const
  DEFAULT_CONFIG_FILE = "config/network_optimizer.json"
  MAX_PROFILES = 10  # 最大プロファイル数
  
  # ネットワーク環境プロファイル
  PROFILE_FAST = "fast"        # 高速固定回線
  PROFILE_MOBILE = "mobile"    # モバイル回線
  PROFILE_CONGESTED = "congested"  # 輻輳ネットワーク
  PROFILE_LOW_LATENCY = "low_latency"  # 低遅延回線
  PROFILE_SATELLITE = "satellite"  # 衛星回線
  PROFILE_BALANCED = "balanced"  # バランス型（デフォルト）
  PROFILE_AGGRESSIVE = "aggressive"  # 積極的最適化
  PROFILE_CONSERVATIVE = "conservative"  # 控えめ最適化
  PROFILE_BATTERY_SAVER = "battery_saver"  # バッテリー節約モード
  PROFILE_CUSTOM = "custom"    # カスタムプロファイル

type
  # 最適化設定
  OptimizerConfig* = object
    profiles*: Table[string, NetworkProfile]  # プロファイル
    activeProfile*: string                   # アクティブプロファイル
    dynamicOptimization*: bool               # 動的最適化有効
    anomalyDetection*: bool                  # 異常検出有効
    adaptiveQoS*: bool                       # 適応型QoS有効
    autoSwitching*: bool                     # 自動プロファイル切替有効
    switchingThreshold*: float               # 切替閾値
    lastSwitchTime*: int64                   # 最終切替時間
    customRules*: seq[NetworkRule]           # カスタムルール
  
  # ネットワークプロファイル
  NetworkProfile* = object
    name*: string                            # プロファイル名
    description*: string                     # 説明
    
    # 一般設定
    concurrentConnections*: int              # 同時接続数
    maxConcurrentStreams*: int               # 最大同時ストリーム数
    socketBufferSize*: int                   # ソケットバッファサイズ
    socketNoDelay*: bool                     # TCPノーディレイ設定
    
    # HTTP/3設定
    http3Settings*: HTTP3Settings            # HTTP/3設定
    
    # TLS設定
    tlsSettings*: TLSSettings                # TLS設定
    
    # DNS設定
    dnsSettings*: DNSSettings                # DNS設定
    
    # キャッシュ設定
    cacheSettings*: CacheSettings            # キャッシュ設定
    
    # ネットワークパラメータ（プロファイルの基準となる想定値）
    bandwidthTarget*: float                  # 想定帯域幅(Mbps)
    latencyTarget*: float                    # 想定遅延(ms)
    lossTarget*: float                       # 想定パケットロス率(%)
    priorityLevel*: int                      # 優先度レベル(1-10)
    
    # 適応型調整
    adaptiveParameters*: AdaptiveParameters  # 適応型調整パラメータ
  
  # HTTP/3設定
  HTTP3Settings* = object
    enabled*: bool                           # HTTP/3有効
    enableQUIC*: bool                        # QUIC有効
    enableQUICv2*: bool                      # QUICv2有効
    enableEarlyData*: bool                   # Early Dataサポート
    multipathMode*: string                   # マルチパスモード
    congestionControl*: string               # 輻輳制御アルゴリズム
    enablePacing*: bool                      # パケットペーシング有効
    enableSpinBit*: bool                     # QUIC Spin Bit有効
    initialRtt*: float                       # 初期RTT推定値(ms)
    maxStreamsBidi*: int                     # 最大双方向ストリーム数
    maxStreamsUni*: int                      # 最大単方向ストリーム数
    initialMaxData*: int64                   # 初期最大データサイズ
    maxIdleTimeout*: int                     # 最大アイドルタイムアウト(ms)
    retransmissionFactor*: float             # 再送係数
    datagramSupport*: bool                   # デイタグラムサポート
    
    # QUICパラメータチューニング
    ackDelayExponent*: int                   # ACK遅延指数
    maxAckDelay*: int                        # 最大ACK遅延(ms)
    minAckDelay*: int                        # 最小ACK遅延(ms)
    enableHystart*: bool                     # Hystart++有効
    maxDatagramSize*: int                    # 最大データグラムサイズ
    maxUdpPayloadSize*: int                  # 最大UDPペイロードサイズ
    activeConnectionIdLimit*: int            # アクティブ接続ID制限
    
    # HTTP/3固有設定
    qpackSettings*: QPACKSettings            # QPACK設定
    enablePush*: bool                        # サーバープッシュ有効
    maxHeaderListSize*: int                  # 最大ヘッダリストサイズ
  
  # TLS設定
  TLSSettings* = object
    verifyPeer*: bool                        # ピア検証有効
    verifyHostname*: bool                    # ホスト名検証有効
    cipherPreference*: seq[string]           # 暗号スイート優先順位
    sessionTickets*: bool                    # セッションチケット有効
    sessionCacheSize*: int                   # セッションキャッシュサイズ
    ecdhCurves*: seq[string]                 # ECDHカーブ
    maxTlsVersion*: string                   # 最大TLSバージョン
    minTlsVersion*: string                   # 最小TLSバージョン
    ocspStapling*: bool                      # OCSPステープリング有効
    ctVerification*: bool                    # 証明書透明性検証
    zeroCopy*: bool                          # ゼロコピーハンドシェイク
  
  # QPACK設定
  QPACKSettings* = object
    maxTableCapacity*: int                   # 最大テーブル容量
    blockedStreams*: int                     # ブロックされたストリーム
    useDynamicTable*: bool                   # 動的テーブル使用
    immediateAck*: bool                      # 即時ACK
  
  # DNS設定
  DNSSettings* = object
    cacheSize*: int                          # キャッシュサイズ
    cacheTtl*: int                           # キャッシュTTL(秒)
    enablePrefetch*: bool                    # プリフェッチ有効
    useDoH*: bool                            # DNS over HTTPS使用
    useDoT*: bool                            # DNS over TLS使用
    resolvers*: seq[string]                  # 名前解決サーバー
    rotateResolvers*: bool                   # リゾルバローテーション
    resolverTimeout*: int                    # リゾルバタイムアウト(ms)
    maxRetries*: int                         # 最大再試行回数
    ipv6Preference*: int                     # IPv6優先度(0-10)
  
  # キャッシュ設定
  CacheSettings* = object
    maxMemoryCacheSize*: int64               # 最大メモリキャッシュサイズ
    maxDiskCacheSize*: int64                 # 最大ディスクキャッシュサイズ
    enableCompression*: bool                 # キャッシュ圧縮有効
    predictiveCaching*: bool                 # 予測キャッシング有効
    staleWhileRevalidate*: bool              # 検証中古いリソース使用
    staleIfError*: bool                      # エラー時古いリソース使用
    backgroundRevalidation*: bool            # バックグラウンド再検証
    intelligentEviction*: bool               # 知的排出戦略
  
  # 適応型調整パラメータ
  AdaptiveParameters* = object
    enableAdaptivePacing*: bool              # 適応型ペーシング有効
    enableBandwidthProbing*: bool            # 帯域幅プロービング有効
    pacingGain*: float                       # ペーシングゲイン
    probeRttInterval*: int                   # RTTプローブ間隔(ms)
    bandwidthProbeInterval*: int             # 帯域幅プローブ間隔(ms)
    enableCongestionPrediction*: bool        # 輻輳予測有効
    dynamicStreamPriority*: bool             # 動的ストリーム優先度
    adaptiveConcurrency*: bool               # 適応型同時実行数
    minConcurrency*: int                     # 最小同時実行数
    maxConcurrency*: int                     # 最大同時実行数
  
  # ネットワークルール
  NetworkRule* = object
    name*: string                            # ルール名
    pattern*: string                         # パターン（ホスト/ドメイン）
    profileOverride*: string                 # プロファイルオーバーライド
    priority*: int                           # 優先度
    enabled*: bool                           # 有効フラグ

# デフォルト設定を生成
proc defaultOptimizerConfig*(): OptimizerConfig =
  var config = OptimizerConfig(
    activeProfile: PROFILE_BALANCED,
    dynamicOptimization: true,
    anomalyDetection: true,
    adaptiveQoS: true,
    autoSwitching: true,
    switchingThreshold: 0.3,
    lastSwitchTime: 0,
    customRules: @[]
  )
  
  # プロファイルテーブル初期化
  config.profiles = initTable[string, NetworkProfile]()
  
  # 高速回線プロファイル
  var fastProfile = NetworkProfile(
    name: PROFILE_FAST,
    description: "High-bandwidth fixed connection optimization",
    concurrentConnections: 12,
    maxConcurrentStreams: 200,
    socketBufferSize: 512 * 1024,  # 512KB
    socketNoDelay: true,
    bandwidthTarget: 100.0,  # 100Mbps
    latencyTarget: 15.0,     # 15ms
    lossTarget: 0.01,        # 0.01%
    priorityLevel: 8
  )
  
  # HTTP/3設定（高速回線用）
  fastProfile.http3Settings = HTTP3Settings(
    enabled: true,
    enableQUIC: true,
    enableQUICv2: true,
    enableEarlyData: true,
    multipathMode: "aggregation",
    congestionControl: "cubic",
    enablePacing: true,
    enableSpinBit: true,
    initialRtt: 20.0,  # ms
    maxStreamsBidi: 200,
    maxStreamsUni: 200,
    initialMaxData: 15 * 1024 * 1024,  # 15MB
    maxIdleTimeout: 60_000,  # 60秒
    retransmissionFactor: 1.0,
    datagramSupport: true,
    ackDelayExponent: 3,
    maxAckDelay: 25,  # ms
    minAckDelay: 5,   # ms
    enableHystart: true,
    maxDatagramSize: 1350,
    maxUdpPayloadSize: 1452,
    activeConnectionIdLimit: 4,
    enablePush: true,
    maxHeaderListSize: 64 * 1024  # 64KB
  )
  
  # QPACK設定
  fastProfile.http3Settings.qpackSettings = QPACKSettings(
    maxTableCapacity: 16384,  # 16KB
    blockedStreams: 32,
    useDynamicTable: true,
    immediateAck: true
  )
  
  # TLS設定
  fastProfile.tlsSettings = TLSSettings(
    verifyPeer: true,
    verifyHostname: true,
    cipherPreference: @[
      "TLS_AES_256_GCM_SHA384",
      "TLS_AES_128_GCM_SHA256",
      "TLS_CHACHA20_POLY1305_SHA256"
    ],
    sessionTickets: true,
    sessionCacheSize: 1000,
    ecdhCurves: @["X25519", "P-256"],
    maxTlsVersion: "1.3",
    minTlsVersion: "1.2",
    ocspStapling: true,
    ctVerification: true,
    zeroCopy: true
  )
  
  # DNS設定
  fastProfile.dnsSettings = DNSSettings(
    cacheSize: 10000,
    cacheTtl: 3600,  # 1時間
    enablePrefetch: true,
    useDoH: true,
    useDoT: false,
    resolvers: @[
      "https://cloudflare-dns.com/dns-query",
      "https://dns.google/dns-query"
    ],
    rotateResolvers: true,
    resolverTimeout: 2000,  # 2秒
    maxRetries: 3,
    ipv6Preference: 5
  )
  
  # キャッシュ設定
  fastProfile.cacheSettings = CacheSettings(
    maxMemoryCacheSize: 256 * 1024 * 1024,  # 256MB
    maxDiskCacheSize: 1024 * 1024 * 1024,   # 1GB
    enableCompression: true,
    predictiveCaching: true,
    staleWhileRevalidate: true,
    staleIfError: true,
    backgroundRevalidation: true,
    intelligentEviction: true
  )
  
  # 適応型調整パラメータ
  fastProfile.adaptiveParameters = AdaptiveParameters(
    enableAdaptivePacing: true,
    enableBandwidthProbing: true,
    pacingGain: 1.25,
    probeRttInterval: 10_000,   # 10秒
    bandwidthProbeInterval: 5_000,  # 5秒
    enableCongestionPrediction: true,
    dynamicStreamPriority: true,
    adaptiveConcurrency: true,
    minConcurrency: 6,
    maxConcurrency: 32
  )
  
  # プロファイル追加
  config.profiles[PROFILE_FAST] = fastProfile

  # モバイル回線プロファイル
  var mobileProfile = NetworkProfile(
    name: PROFILE_MOBILE,
    description: "Mobile network optimization",
    concurrentConnections: 6,
    maxConcurrentStreams: 100,
    socketBufferSize: 256 * 1024,  # 256KB
    socketNoDelay: true,
    bandwidthTarget: 10.0,  # 10Mbps
    latencyTarget: 80.0,    # 80ms
    lossTarget: 1.0,        # 1%
    priorityLevel: 6
  )
  
  # HTTP/3設定（モバイル回線用）
  mobileProfile.http3Settings = HTTP3Settings(
    enabled: true,
    enableQUIC: true,
    enableQUICv2: true,
    enableEarlyData: true,
    multipathMode: "handover",  # モバイル用にハンドオーバーモード
    congestionControl: "bbr",   # BBRはモバイル回線に強い
    enablePacing: true,
    enableSpinBit: true,
    initialRtt: 100.0,  # ms
    maxStreamsBidi: 100,
    maxStreamsUni: 100,
    initialMaxData: 6 * 1024 * 1024,  # 6MB
    maxIdleTimeout: 90_000,  # 90秒（モバイルはアイドル時間が長い傾向）
    retransmissionFactor: 1.5,
    datagramSupport: true,
    ackDelayExponent: 4,
    maxAckDelay: 40,  # ms
    minAckDelay: 10,  # ms
    enableHystart: true,
    maxDatagramSize: 1200,
    maxUdpPayloadSize: 1350,
    activeConnectionIdLimit: 8,  # モバイルは接続切り替えが多いため大きめ
    enablePush: false,  # モバイルではプッシュを無効に
    maxHeaderListSize: 32 * 1024  # 32KB
  )
  
  # QPACK設定
  mobileProfile.http3Settings.qpackSettings = QPACKSettings(
    maxTableCapacity: 8192,  # 8KB
    blockedStreams: 16,
    useDynamicTable: true,
    immediateAck: false
  )
  
  # TLS設定
  mobileProfile.tlsSettings = TLSSettings(
    verifyPeer: true,
    verifyHostname: true,
    cipherPreference: @[
      "TLS_CHACHA20_POLY1305_SHA256",  # ChaCha20はモバイルで効率的
      "TLS_AES_128_GCM_SHA256",
      "TLS_AES_256_GCM_SHA384"
    ],
    sessionTickets: true,
    sessionCacheSize: 500,
    ecdhCurves: @["X25519", "P-256"],
    maxTlsVersion: "1.3",
    minTlsVersion: "1.2",
    ocspStapling: true,
    ctVerification: false,  # モバイルではCT検証を無効化（帯域節約）
    zeroCopy: true
  )
  
  # DNS設定
  mobileProfile.dnsSettings = DNSSettings(
    cacheSize: 5000,
    cacheTtl: 7200,  # 2時間
    enablePrefetch: false,  # モバイルではプリフェッチを控えめに
    useDoH: true,
    useDoT: false,
    resolvers: @["https://cloudflare-dns.com/dns-query"],
    rotateResolvers: false,
    resolverTimeout: 3000,  # 3秒
    maxRetries: 2,
    ipv6Preference: 3
  )
  
  # キャッシュ設定
  mobileProfile.cacheSettings = CacheSettings(
    maxMemoryCacheSize: 128 * 1024 * 1024,  # 128MB
    maxDiskCacheSize: 512 * 1024 * 1024,   # 512MB
    enableCompression: true,
    predictiveCaching: true,
    staleWhileRevalidate: true,
    staleIfError: true,
    backgroundRevalidation: false,  # モバイルではバックグラウンド再検証を無効化
    intelligentEviction: true
  )
  
  # 適応型調整パラメータ
  mobileProfile.adaptiveParameters = AdaptiveParameters(
    enableAdaptivePacing: true,
    enableBandwidthProbing: true,
    pacingGain: 1.5,  # モバイルではより積極的なペーシング
    probeRttInterval: 15_000,   # 15秒
    bandwidthProbeInterval: 10_000,  # 10秒
    enableCongestionPrediction: true,
    dynamicStreamPriority: true,
    adaptiveConcurrency: true,
    minConcurrency: 2,
    maxConcurrency: 16
  )
  
  # プロファイル追加
  config.profiles[PROFILE_MOBILE] = mobileProfile
  
  # バランスプロファイル（デフォルト）
  var balancedProfile = NetworkProfile(
    name: PROFILE_BALANCED,
    description: "Balanced optimization for most connections",
    concurrentConnections: 8,
    maxConcurrentStreams: 128,
    socketBufferSize: 256 * 1024,  # 256KB
    socketNoDelay: true,
    bandwidthTarget: 30.0,  # 30Mbps
    latencyTarget: 50.0,    # 50ms
    lossTarget: 0.1,        # 0.1%
    priorityLevel: 5
  )
  
  # HTTP/3設定（バランス設定）
  balancedProfile.http3Settings = HTTP3Settings(
    enabled: true,
    enableQUIC: true,
    enableQUICv2: true,
    enableEarlyData: true,
    multipathMode: "dynamic",  # 動的モード
    congestionControl: "cubic",
    enablePacing: true,
    enableSpinBit: true,
    initialRtt: 50.0,  # ms
    maxStreamsBidi: 128,
    maxStreamsUni: 128,
    initialMaxData: 8 * 1024 * 1024,  # 8MB
    maxIdleTimeout: 60_000,  # 60秒
    retransmissionFactor: 1.2,
    datagramSupport: true,
    ackDelayExponent: 3,
    maxAckDelay: 25,  # ms
    minAckDelay: 5,   # ms
    enableHystart: true,
    maxDatagramSize: 1280,
    maxUdpPayloadSize: 1400,
    activeConnectionIdLimit: 4,
    enablePush: true,
    maxHeaderListSize: 48 * 1024  # 48KB
  )
  
  # QPACK設定
  balancedProfile.http3Settings.qpackSettings = QPACKSettings(
    maxTableCapacity: 10240,  # 10KB
    blockedStreams: 20,
    useDynamicTable: true,
    immediateAck: true
  )
  
  # プロファイル追加
  config.profiles[PROFILE_BALANCED] = balancedProfile
  
  # 他のプロファイルの詳細設定は省略
  
  return config

# 設定をJSONからロード
proc loadFromJson*(jsonStr: string): OptimizerConfig =
  try:
    let jsonNode = parseJson(jsonStr)
    # JSON解析と設定構造への変換（実装省略）
    result = defaultOptimizerConfig()
  except:
    echo "Failed to parse JSON. Using default configuration."
    result = defaultOptimizerConfig()

# 設定をファイルからロード
proc loadFromFile*(filePath: string = DEFAULT_CONFIG_FILE): OptimizerConfig =
  try:
    if fileExists(filePath):
      let jsonStr = readFile(filePath)
      result = loadFromJson(jsonStr)
    else:
      echo "Config file not found. Using default configuration."
      result = defaultOptimizerConfig()
  except:
    echo "Error loading config file. Using default configuration."
    result = defaultOptimizerConfig()

# 設定をJSONに変換
proc toJson*(config: OptimizerConfig): string =
  # 設定をJSON形式に変換（実装省略）
  result = "{}" # 仮の空JSON

# 設定をファイルに保存
proc saveToFile*(config: OptimizerConfig, filePath: string = DEFAULT_CONFIG_FILE): bool =
  try:
    let jsonStr = config.toJson()
    writeFile(filePath, jsonStr)
    return true
  except:
    echo "Error saving config file: ", getCurrentExceptionMsg()
    return false

# 最適なプロファイルを選択
proc selectOptimalProfile*(config: var OptimizerConfig, 
                          bandwidth: float, 
                          latency: float, 
                          loss: float, 
                          networkType: string): string =
  # 自動切替が無効の場合は現在のプロファイルを維持
  if not config.autoSwitching:
    return config.activeProfile
  
  var bestMatch = config.activeProfile
  var bestScore = 0.0
  
  # 各プロファイルの適合度を計算
  for profileName, profile in config.profiles:
    # 帯域幅スコア: 目標に近いほど高い (1.0 = 完全一致)
    let bandwidthRatio = min(bandwidth / profile.bandwidthTarget, 
                            profile.bandwidthTarget / bandwidth)
    let bandwidthScore = bandwidthRatio * 0.3  # 30%ウェイト
    
    # 遅延スコア: 目標に近いほど高い
    let latencyRatio = min(latency / profile.latencyTarget, 
                          profile.latencyTarget / latency)
    let latencyScore = latencyRatio * 0.5  # 50%ウェイト
    
    # パケットロススコア: 目標に近いほど高い
    let lossRatio = if loss < 0.01: 1.0  # 非常に低いロスは1.0とみなす
                    else: min(loss / profile.lossTarget, 
                            profile.lossTarget / loss)
    let lossScore = lossRatio * 0.2  # 20%ウェイト
    
    # 合計スコア
    let totalScore = bandwidthScore + latencyScore + lossScore
    
    # より良いマッチを見つけた場合は更新
    if totalScore > bestScore:
      bestScore = totalScore
      bestMatch = profileName
  
  # スコアが閾値を超えた場合のみプロファイルを切り替え
  if bestMatch != config.activeProfile and bestScore > config.switchingThreshold:
    echo fmt"Switching network profile from {config.activeProfile} to {bestMatch} (score: {bestScore:.2f})"
    config.activeProfile = bestMatch
    config.lastSwitchTime = epochTime().int64
  
  return config.activeProfile

# ネットワークパラメータに基づく設定最適化
proc optimizeForNetwork*(config: var OptimizerConfig, 
                        bandwidth: float, 
                        latency: float, 
                        loss: float, 
                        networkType: string): bool =
  # 最適なプロファイルを選択
  let profileName = config.selectOptimalProfile(bandwidth, latency, loss, networkType)
  
  # プロファイルが存在しない場合は失敗
  if profileName notin config.profiles:
    return false
  
  # 追加の動的最適化
  if config.dynamicOptimization:
    let profile = addr config.profiles[profileName]
    
    # 帯域幅に基づく初期ウィンドウサイズ最適化
    # 計算式: 帯域幅(Mbps) * 往復時間(秒) * 1000 バイト/Mb
    let bwDelayProduct = bandwidth * (latency / 1000.0) * 125000.0
    profile.http3Settings.initialMaxData = max(1_000_000, bwDelayProduct.int64)
    
    # 遅延に基づくACK遅延最適化
    let ackDelay = max(1, min(25, (latency * 0.1).int))
    profile.http3Settings.maxAckDelay = ackDelay
    
    # パケットロスに基づく再送係数調整
    if loss > 5.0:
      profile.http3Settings.retransmissionFactor = 2.0  # 高ロス環境では積極的再送
    elif loss > 1.0:
      profile.http3Settings.retransmissionFactor = 1.5
    else:
      profile.http3Settings.retransmissionFactor = 1.0
      
    # 帯域幅に基づく最大ストリーム数最適化
    let streamCount = max(30, min(500, (bandwidth * 1.5).int))
    profile.http3Settings.maxStreamsBidi = streamCount
    profile.http3Settings.maxStreamsUni = streamCount
    
    # モバイルネットワーク特別処理
    if networkType == "cellular":
      profile.http3Settings.congestionControl = "bbr"  # BBRはモバイルに適している
      profile.http3Settings.multipathMode = "handover"  # ハンドオーバーモード
    
    # 高速回線特別処理
    if bandwidth > 50.0 and latency < 20.0:
      profile.http3Settings.congestionControl = "cubic"  # Cubicは高速固定回線に適している
      profile.http3Settings.multipathMode = "aggregation"  # 集約モード
  
  return true

# プロファイルを取得
proc getProfile*(config: OptimizerConfig, profileName: string = ""): Option[NetworkProfile] =
  let name = if profileName.len > 0: profileName else: config.activeProfile
  
  if name in config.profiles:
    return some(config.profiles[name])
  
  return none(NetworkProfile)

# アクティブなHTTP/3設定を取得
proc getActiveHttp3Settings*(config: OptimizerConfig): HTTP3Settings =
  let profileOpt = config.getProfile()
  
  if profileOpt.isSome:
    return profileOpt.get().http3Settings
  
  # デフォルト値を返す
  return HTTP3Settings(
    enabled: true,
    enableQUIC: true,
    enableQUICv2: true,
    enableEarlyData: true,
    multipathMode: "dynamic",
    congestionControl: "cubic",
    enablePacing: true,
    enableSpinBit: true,
    initialRtt: 50.0,
    maxStreamsBidi: 100,
    maxStreamsUni: 100,
    initialMaxData: 10 * 1024 * 1024,
    maxIdleTimeout: 60_000,
    retransmissionFactor: 1.0,
    datagramSupport: true
  ) 