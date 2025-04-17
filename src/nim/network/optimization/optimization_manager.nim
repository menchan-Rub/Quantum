import std/[tables, sets, asyncdispatch, httpclient, strutils, uri, times, options, json, algorithm, sequtils, strformat, locks, hashes, math, monotimes]
import ./preconnect/preconnect_manager
import ./prefetch/prefetch_manager
import ./prioritization/resource_prioritization
import ../cache/http_cache_manager
import ../dns/dns_resolver
import ../http/http_client_metrics
import ../security/content_security_policy
import ../utils/network_analysis
import ../utils/bandwidth_monitor

type
  OptimizationStrategy* = enum
    osAggressive,      # 積極的な最適化（帯域幅よりも速度優先）
    osBalanced,        # バランスの取れた最適化
    osConservative     # 控えめな最適化（速度よりも帯域幅優先）
    osAdaptive         # 適応型最適化（ネットワーク状況に応じて動的に調整）

  NetworkCondition* = enum
    ncExcellent,       # 非常に良好 (例: 高速WiFi、光ファイバー)
    ncGood,            # 良好 (例: 標準WiFi、有線イーサネット)
    ncModerate,        # 中程度 (例: 3G/4G、混雑したWiFi)
    ncPoor,            # 貧弱 (例: 2G、不安定な接続)
    ncOffline          # オフライン

  OptimizationPhase* = enum
    opInitial,         # 初期フェーズ（ページ読み込み開始時）
    opCritical,        # クリティカルフェーズ（重要なリソースの読み込み中）
    opDeferred,        # 遅延フェーズ（重要でないリソースの読み込み中）
    opIdle,            # アイドルフェーズ（主要な読み込みが完了後）
    opPreNavigation    # ナビゲーション前フェーズ（次のページへの遷移準備中）

  OptimizationContext* = object
    ## 最適化コンテキスト
    currentUrl*: string        # 現在のURL
    isMainFrame*: bool         # メインフレームかどうか
    screenWidth*: int          # 画面幅
    screenHeight*: int         # 画面高さ
    devicePixelRatio*: float   # デバイスピクセル比
    connectionType*: string    # 接続タイプ（wifi, cellular, unknown等）
    networkEffectiveType*: string  # 有効なネットワークタイプ（4g, 3g, 2g, slow-2g）
    downlinkSpeed*: float      # ダウンリンク速度（Mbps）
    rtt*: int                  # RTT（ミリ秒）
    saveDataMode*: bool        # データセーブモードかどうか
    batteryLevel*: float       # バッテリーレベル（0.0 - 1.0）
    batteryCharging*: bool     # 充電中かどうか
    cpuUtilization*: float     # CPU使用率
    memoryPressure*: float     # メモリ圧迫度
    currentPhase*: OptimizationPhase  # 現在の最適化フェーズ
    networkCondition*: NetworkCondition  # ネットワーク状況評価
    locationHint*: string      # 位置情報ヒント（地域や国コードなど）
    effectiveBandwidthKbps*: float     # 実効帯域幅（Kbps）
    jitter*: float             # ネットワークジッター（ミリ秒）
    packetLoss*: float         # パケットロス率（0.0 - 1.0）
    
  ResourceHint* = object
    ## リソースヒント
    url*: string               # URL
    type*: ResourceHintType    # ヒントタイプ
    `as`*: string              # リソースタイプ
    crossOrigin*: bool         # クロスオリジンかどうか
    importance*: string        # 重要度

  ResourceHintType* = enum
    rhtPreconnect,             # 事前接続
    rhtPrefetch,               # 事前取得
    rhtPreload,                # 事前読み込み
    rhtPrerender,              # 事前レンダリング
    rhtDnsPrefetch             # DNS事前解決

  OptimizationMetric* = object
    ## 最適化メトリック
    name*: string              # メトリック名
    value*: float              # 値
    timestamp*: Time           # タイムスタンプ
    metadata*: Table[string, string]  # メタデータ

  ResourceLoadTiming* = object
    ## リソース読み込みタイミング
    startTime*: MonoTime       # 開始時間
    dnsStart*: MonoTime        # DNS解決開始時間
    dnsEnd*: MonoTime          # DNS解決終了時間
    connectStart*: MonoTime    # 接続開始時間
    connectEnd*: MonoTime      # 接続終了時間
    tlsStart*: MonoTime        # TLS開始時間
    tlsEnd*: MonoTime          # TLS終了時間
    requestStart*: MonoTime    # リクエスト開始時間
    requestEnd*: MonoTime      # リクエスト終了時間
    responseStart*: MonoTime   # レスポンス開始時間
    responseEnd*: MonoTime     # レスポンス終了時間
    transferSize*: int         # 転送サイズ
    encodedBodySize*: int      # エンコードされたボディサイズ
    decodedBodySize*: int      # デコードされたボディサイズ

  OptimizationPolicy* = object
    ## 最適化ポリシー
    name*: string              # ポリシー名
    priority*: int             # 優先度（高いほど優先）
    conditions*: seq[proc(ctx: OptimizationContext): bool]  # 条件
    actions*: seq[proc(ctx: OptimizationContext, manager: var OptimizationManager): Future[void] {.async.}]  # アクション

  OptimizationSettings* = object
    ## 最適化設定
    strategy*: OptimizationStrategy  # 最適化戦略
    maxConcurrentConnections*: int   # 最大同時接続数
    maxConcurrentFetches*: int       # 最大同時フェッチ数
    enablePreconnect*: bool          # 事前接続を有効にするかどうか
    enablePrefetch*: bool            # 事前フェッチを有効にするかどうか
    enablePrioritization*: bool      # 優先順位付けを有効にするかどうか
    prefetchHoverDelay*: int         # ホバー時の事前フェッチ遅延（ミリ秒）
    preconnectTimeout*: int          # 事前接続のタイムアウト（ミリ秒）
    prefetchConcurrency*: int        # 事前フェッチの同時実行数
    preconnectOnHover*: bool         # ホバー時に事前接続するかどうか
    prefetchOnHover*: bool           # ホバー時に事前フェッチするかどうか
    prefetchLimit*: int              # 事前フェッチの制限（バイト）
    adaptivePrefetching*: bool       # 適応型事前フェッチを有効にするかどうか
    aggressivePreconnect*: bool      # 積極的な事前接続を有効にするかどうか
    disableOnMeteredConnection*: bool  # 従量制接続時に無効にするかどうか
    disableOnSaveData*: bool         # データセーブモード時に無効にするかどうか
    prefetchHighPriorityOnly*: bool  # 高優先度のリソースのみを事前フェッチするかどうか
    enableQuicHint*: bool            # QUICヒントを有効にするかどうか
    preloadFonts*: bool              # フォントを事前ロードするかどうか
    preloadCriticalCss*: bool        # クリティカルCSSを事前ロードするかどうか
    preloadMainThreadScripts*: bool  # メインスレッドスクリプトを事前ロードするかどうか
    maxPreloadHints*: int            # 最大プリロードヒント数
    brotliPreference*: bool          # Brotli圧縮を優先するかどうか
    http2Preference*: bool           # HTTP/2を優先するかどうか
    http3Preference*: bool           # HTTP/3を優先するかどうか
    inlineSmallResources*: bool      # 小さいリソースをインライン化するかどうか
    inlineThresholdBytes*: int       # インライン化の閾値（バイト）
    enableSpeculativeLoading*: bool  # 投機的読み込みを有効にするかどうか
    speculationConfidenceThreshold*: float  # 投機的読み込みの信頼度閾値
    preconnectExpiryTimeMs*: int     # 事前接続の有効期限（ミリ秒）
    adaptiveBandwidthAllocation*: bool # 適応帯域幅割り当てを有効にするかどうか
    dynamicResourceHints*: bool      # 動的リソースヒントを有効にするかどうか
    enableNetworkProfileDetection*: bool # ネットワークプロファイル検出を有効にするかどうか
    priorityBoostForViewport*: float # ビューポート内リソースの優先度ブースト

  OptimizationManager* = object
    ## ネットワーク最適化マネージャー
    preconnectManager*: PreconnectManager    # 事前接続マネージャー
    prefetchManager*: PrefetchManager        # 事前フェッチマネージャー
    prioritizer*: ResourcePrioritizer        # リソース優先順位付けマネージャー
    cacheManager*: HttpCacheManager          # キャッシュマネージャー
    dnsResolver*: DnsResolver                # DNS解決器
    context*: OptimizationContext            # 最適化コンテキスト
    settings*: OptimizationSettings          # 最適化設定
    currentNavigationUrl*: string            # 現在のナビゲーションURL
    navigationStartTime*: Time               # ナビゲーション開始時間
    optimizationStartTime*: Time             # 最適化開始時間
    hoverTargets*: Table[string, Time]       # ホバー対象とタイムスタンプ
    preconnectedHosts*: HashSet[string]      # 事前接続済みのホスト
    prefetchedUrls*: HashSet[string]         # 事前フェッチ済みのURL
    predictedUrls*: seq[string]              # 予測されたURL
    predictedByClicking*: HashSet[string]    # クリックによって予測されたURL
    resourceStats*: Table[string, tuple[size: int, loadTime: int]]  # リソース統計
    optimizationMetrics*: seq[OptimizationMetric]  # 最適化指標
    resourceTimings*: Table[string, ResourceLoadTiming]  # リソースタイミング
    bandwidthMonitor*: BandwidthMonitor      # 帯域幅モニター
    contentSecurityPolicy*: ContentSecurityPolicy  # コンテンツセキュリティポリシー
    navigationPredictions*: Table[string, float]  # ナビゲーション予測と確率
    lastPreconnectTimes*: Table[string, Time]  # 最後の事前接続時間
    optimizationPolicies*: seq[OptimizationPolicy]  # 最適化ポリシー
    lock*: Lock                               # スレッド安全性のためのロック
    enabledInContext*: bool                   # 現在のコンテキストで最適化が有効かどうか
    metricsCollected*: int                    # 収集されたメトリクス数
    prefetchBudgetBytes*: int                 # 残りの事前フェッチ予算（バイト）
    activeOptimizationCount*: int             # アクティブな最適化数
    lastAdaptationTime*: Time                 # 最後の適応時間
    resourceHints*: seq[ResourceHint]         # リソースヒント
    criticalPathResources*: HashSet[string]   # クリティカルパスリソース
    lastNetworkAnalysisTime*: Time            # 最後のネットワーク分析時間

proc defaultOptimizationSettings*(strategy: OptimizationStrategy = osBalanced): OptimizationSettings =
  ## デフォルトの最適化設定を返す
  case strategy
  of osAggressive:
    result = OptimizationSettings(
      strategy: osAggressive,
      maxConcurrentConnections: 16,
      maxConcurrentFetches: 10,
      enablePreconnect: true,
      enablePrefetch: true,
      enablePrioritization: true,
      prefetchHoverDelay: 80,  # 80ミリ秒
      preconnectTimeout: 2500,  # 2.5秒
      prefetchConcurrency: 8,
      preconnectOnHover: true,
      prefetchOnHover: true,
      prefetchLimit: 15 * 1024 * 1024,  # 15MB
      adaptivePrefetching: true,
      aggressivePreconnect: true,
      disableOnMeteredConnection: false,
      disableOnSaveData: true,
      prefetchHighPriorityOnly: false,
      enableQuicHint: true,
      preloadFonts: true,
      preloadCriticalCss: true,
      preloadMainThreadScripts: true,
      maxPreloadHints: 15,
      brotliPreference: true,
      http2Preference: true,
      http3Preference: true,
      inlineSmallResources: true,
      inlineThresholdBytes: 2048,  # 2KB
      enableSpeculativeLoading: true,
      speculationConfidenceThreshold: 0.6,
      preconnectExpiryTimeMs: 60000,  # 60秒
      adaptiveBandwidthAllocation: true,
      dynamicResourceHints: true,
      enableNetworkProfileDetection: true,
      priorityBoostForViewport: 2.0
    )
  of osBalanced:
    result = OptimizationSettings(
      strategy: osBalanced,
      maxConcurrentConnections: 10,
      maxConcurrentFetches: 6,
      enablePreconnect: true,
      enablePrefetch: true,
      enablePrioritization: true,
      prefetchHoverDelay: 150,  # 150ミリ秒
      preconnectTimeout: 4000,  # 4秒
      prefetchConcurrency: 4,
      preconnectOnHover: true,
      prefetchOnHover: true,
      prefetchLimit: 8 * 1024 * 1024,  # 8MB
      adaptivePrefetching: true,
      aggressivePreconnect: false,
      disableOnMeteredConnection: false,
      disableOnSaveData: true,
      prefetchHighPriorityOnly: false,
      enableQuicHint: true,
      preloadFonts: true,
      preloadCriticalCss: true,
      preloadMainThreadScripts: true,
      maxPreloadHints: 10,
      brotliPreference: true,
      http2Preference: true,
      http3Preference: true,
      inlineSmallResources: true,
      inlineThresholdBytes: 1024,  # 1KB
      enableSpeculativeLoading: true,
      speculationConfidenceThreshold: 0.75,
      preconnectExpiryTimeMs: 45000,  # 45秒
      adaptiveBandwidthAllocation: true,
      dynamicResourceHints: true,
      enableNetworkProfileDetection: true,
      priorityBoostForViewport: 1.5
    )
  of osConservative:
    result = OptimizationSettings(
      strategy: osConservative,
      maxConcurrentConnections: 6,
      maxConcurrentFetches: 3,
      enablePreconnect: true,
      enablePrefetch: false,  # 事前フェッチは無効
      enablePrioritization: true,
      prefetchHoverDelay: 300,  # 300ミリ秒
      preconnectTimeout: 8000,  # 8秒
      prefetchConcurrency: 2,
      preconnectOnHover: true,
      prefetchOnHover: false,  # ホバー時の事前フェッチも無効
      prefetchLimit: 2 * 1024 * 1024,  # 2MB
      adaptivePrefetching: true,
      aggressivePreconnect: false,
      disableOnMeteredConnection: true,
      disableOnSaveData: true,
      prefetchHighPriorityOnly: true,
      enableQuicHint: false,
      preloadFonts: false,
      preloadCriticalCss: true,
      preloadMainThreadScripts: false,
      maxPreloadHints: 5,
      brotliPreference: false,
      http2Preference: true,
      http3Preference: false,
      inlineSmallResources: false,
      inlineThresholdBytes: 512,  # 512バイト
      enableSpeculativeLoading: false,
      speculationConfidenceThreshold: 0.9,
      preconnectExpiryTimeMs: 30000,  # 30秒
      adaptiveBandwidthAllocation: false,
      dynamicResourceHints: false,
      enableNetworkProfileDetection: true,
      priorityBoostForViewport: 1.0
    )
  of osAdaptive:
    # まずはバランス型の設定をベースにする
    result = defaultOptimizationSettings(osBalanced)
    result.strategy = osAdaptive
    result.adaptivePrefetching = true
    result.adaptiveBandwidthAllocation = true
    result.dynamicResourceHints = true
    result.enableNetworkProfileDetection = true

proc defaultOptimizationContext*(): OptimizationContext =
  ## デフォルトの最適化コンテキストを返す
  result = OptimizationContext(
    currentUrl: "",
    isMainFrame: true,
    screenWidth: 1920,
    screenHeight: 1080,
    devicePixelRatio: 1.0,
    connectionType: "unknown",
    networkEffectiveType: "4g",
    downlinkSpeed: 10.0,  # 10Mbps
    rtt: 50,  # 50ms
    saveDataMode: false,
    batteryLevel: 1.0,
    batteryCharging: true,
    cpuUtilization: 0.2,
    memoryPressure: 0.3,
    currentPhase: opInitial,
    networkCondition: ncGood,
    locationHint: "",
    effectiveBandwidthKbps: 10000.0,  # 10Mbps
    jitter: 5.0,  # 5ms
    packetLoss: 0.0
  )

proc evaluateNetworkCondition*(ctx: OptimizationContext): NetworkCondition =
  ## ネットワーク状況を評価する
  # ネットワーク状況の評価アルゴリズム
  # downlinkSpeed, rtt, jitter, packetLossの組み合わせで決定
  
  if ctx.downlinkSpeed <= 0.0 or ctx.rtt <= 0:
    return ncOffline
  
  # ネットワークスコアを計算（0-100）
  var score: float = 0.0
  
  # 帯域幅スコア（最大40ポイント）
  var bandwidthScore = min(40.0, ctx.downlinkSpeed * 4.0)
  
  # RTTスコア（最大30ポイント） - 低いほど良い
  var rttScore = 30.0 * max(0.0, min(1.0, 1.0 - (ctx.rtt.float - 10.0) / 490.0))
  
  # ジッタースコア（最大15ポイント） - 低いほど良い
  var jitterScore = 15.0 * max(0.0, min(1.0, 1.0 - ctx.jitter / 100.0))
  
  # パケットロススコア（最大15ポイント） - 低いほど良い
  var packetLossScore = 15.0 * max(0.0, min(1.0, 1.0 - ctx.packetLoss * 10.0))
  
  score = bandwidthScore + rttScore + jitterScore + packetLossScore
  
  # スコアに基づいてネットワーク状況を分類
  if score >= 85.0:
    return ncExcellent
  elif score >= 65.0:
    return ncGood
  elif score >= 40.0:
    return ncModerate
  else:
    return ncPoor

proc newBandwidthMonitor*(): BandwidthMonitor =
  ## 帯域幅モニターを作成
  result = BandwidthMonitor(
    downloadSamples: @[],
    uploadSamples: @[],
    lastSampleTime: getTime(),
    maxSamples: 30,
    currentDownloadRate: 0.0,
    currentUploadRate: 0.0,
    totalDownloadedBytes: 0,
    totalUploadedBytes: 0,
    downloadHistory: initTable[string, seq[float]](),
    availableBandwidth: 10.0 * 1024.0 * 1024.0 / 8.0  # 初期値10Mbps
  )

proc newContentSecurityPolicy*(): ContentSecurityPolicy =
  ## コンテンツセキュリティポリシーを作成
  result = ContentSecurityPolicy(
    policies: initTable[string, seq[string]](),
    enabled: true
  )

proc newOptimizationManager*(
  cacheManager: HttpCacheManager,
  settings: OptimizationSettings = defaultOptimizationSettings(),
  context: OptimizationContext = defaultOptimizationContext()
): OptimizationManager =
  ## 新しいOptimizationManagerを作成する
  # DNS解決器を作成
  let dnsResolver = newDnsResolver()
  
  # 事前接続マネージャーを作成
  let preconnectManager = newPreconnectManager(
    maxConcurrentConnections = settings.maxConcurrentConnections,
    dnsResolver = dnsResolver,
    timeout = settings.preconnectTimeout
  )
  
  # 事前フェッチマネージャーを作成
  let prefetchManager = newPrefetchManager(
    preconnectManager = preconnectManager,
    cacheManager = cacheManager,
    maxConcurrentFetches = settings.maxConcurrentFetches,
    prefetchLimit = settings.prefetchLimit
  )
  
  # リソース優先順位付けマネージャーを作成
  let prioritizer = newResourcePrioritizer()
  
  # 帯域幅モニターを作成
  let bandwidthMonitor = newBandwidthMonitor()
  
  # コンテンツセキュリティポリシーを作成
  let csp = newContentSecurityPolicy()
  
  # ネットワーク状況を評価
  let networkCondition = evaluateNetworkCondition(context)
  var updatedContext = context
  updatedContext.networkCondition = networkCondition
  
  # ロックを初期化
  var lock: Lock
  initLock(lock)
  
  result = OptimizationManager(
    preconnectManager: preconnectManager,
    prefetchManager: prefetchManager,
    prioritizer: prioritizer,
    cacheManager: cacheManager,
    dnsResolver: dnsResolver,
    context: updatedContext,
    settings: settings,
    currentNavigationUrl: "",
    navigationStartTime: getTime(),
    optimizationStartTime: getTime(),
    hoverTargets: initTable[string, Time](),
    preconnectedHosts: initHashSet[string](),
    prefetchedUrls: initHashSet[string](),
    predictedUrls: @[],
    predictedByClicking: initHashSet[string](),
    resourceStats: initTable[string, tuple[size: int, loadTime: int]](),
    optimizationMetrics: @[],
    resourceTimings: initTable[string, ResourceLoadTiming](),
    bandwidthMonitor: bandwidthMonitor,
    contentSecurityPolicy: csp,
    navigationPredictions: initTable[string, float](),
    lastPreconnectTimes: initTable[string, Time](),
    optimizationPolicies: @[],
    lock: lock,
    enabledInContext: true,
    metricsCollected: 0,
    prefetchBudgetBytes: settings.prefetchLimit,
    activeOptimizationCount: 0,
    lastAdaptationTime: getTime(),
    resourceHints: @[],
    criticalPathResources: initHashSet[string](),
    lastNetworkAnalysisTime: getTime()
  )
  
  # 最適化ポリシーを初期化
  result.initOptimizationPolicies()

proc isPreconnectExpired*(manager: OptimizationManager, host: string): bool =
  ## 事前接続が期限切れかどうかを確認する
  if host notin manager.lastPreconnectTimes:
    return true
    
  let timeSinceLastPreconnect = (getTime() - manager.lastPreconnectTimes[host]).inMilliseconds
  return timeSinceLastPreconnect > manager.settings.preconnectExpiryTimeMs

proc recordMetric*(manager: var OptimizationManager, name: string, value: float, 
                  metadata: Table[string, string] = initTable[string, string]()) =
  ## メトリックを記録する
  withLock(manager.lock):
    let metric = OptimizationMetric(
      name: name,
      value: value,
      timestamp: getTime(),
      metadata: metadata
    )
    manager.optimizationMetrics.add(metric)
    manager.metricsCollected += 1
    
    # メトリック数を制限（最大1000個）
    if manager.optimizationMetrics.len > 1000:
      manager.optimizationMetrics.delete(0)

proc initOptimizationPolicies*(manager: var OptimizationManager) =
  ## 最適化ポリシーを初期化する
  # クリティカルリソース優先ポリシー
  manager.optimizationPolicies.add(OptimizationPolicy(
    name: "critical_resources_first",
    priority: 100,
    conditions: @[
      proc(ctx: OptimizationContext): bool = ctx.currentPhase == opCritical
    ],
    actions: @[
      proc(ctx: OptimizationContext, m: var OptimizationManager): Future[void] {.async.} =
        for url in m.prioritizer.criticalResources:
          if url notin m.prefetchedUrls:
            discard await m.prefetchUrl(url, ppHigh)
    ]
  ))
  
  # 低帯域幅でのプリフェッチ制限ポリシー
  manager.optimizationPolicies.add(OptimizationPolicy(
    name: "limit_prefetch_on_slow_networks",
    priority: 90,
    conditions: @[
      proc(ctx: OptimizationContext): bool = 
        ctx.networkCondition in [ncPoor, ncModerate] and 
        ctx.downlinkSpeed < 3.0
    ],
    actions: @[
      proc(ctx: OptimizationContext, m: var OptimizationManager): Future[void] {.async.} =
        # 事前フェッチ設定を調整
        m.settings.prefetchConcurrency = 1
        m.settings.prefetchHighPriorityOnly = true
        m.recordMetric("policy_limit_prefetch_applied", 1.0)
    ]
  ))
  
  # ビューポート内リソース優先ポリシー
  manager.optimizationPolicies.add(OptimizationPolicy(
    name: "prioritize_viewport_resources",
    priority: 85,
    conditions: @[
      proc(ctx: OptimizationContext): bool = true  # 常に適用
    ],
    actions: @[
      proc(ctx: OptimizationContext, m: var OptimizationManager): Future[void] {.async.} =
        # 優先順位付けロジックを適用
        m.prioritizer.applyViewportBoost(m.settings.priorityBoostForViewport)
    ]
  ))
  
  # バッテリー節約ポリシー
  manager.optimizationPolicies.add(OptimizationPolicy(
    name: "battery_saving_mode",
    priority: 80,
    conditions: @[
      proc(ctx: OptimizationContext): bool = 
        not ctx.batteryCharging and ctx.batteryLevel < 0.2  # バッテリー残量20%未満で充電していない
    ],
    actions: @[
      proc(ctx: OptimizationContext, m: var OptimizationManager): Future[void] {.async.} =
        # バッテリー節約のために設定を調整
        m.settings.enablePrefetch = false
        m.settings.prefetchOnHover = false
        m.settings.enableSpeculativeLoading = false
        m.recordMetric("policy_battery_saving_applied", 1.0)
    ]
  ))

proc shouldOptimize*(manager: OptimizationManager): bool =
  ## 最適化を実行すべきかどうかを決定する
  # コンテキスト内で無効になっている場合
  if not manager.enabledInContext:
    return false
  
  # データセーブモードの場合
  if manager.context.saveDataMode and manager.settings.disableOnSaveData:
    return false
  
  # 従量制接続の場合
  if manager.context.connectionType == "cellular" and manager.settings.disableOnMeteredConnection:
    return false
  
  # オフライン状態の場合
  if manager.context.networkCondition == ncOffline:
    return false
  
  # 残りの事前フェッチ予算がない場合は、事前フェッチを行わない
  # ただし、他の最適化は引き続き実行する
  if manager.prefetchBudgetBytes <= 0:
    # ここでは部分的な最適化を許可
    return true
  
  return true

proc applyOptimizationPolicies*(manager: var OptimizationManager) {.async.} =
  ## 最適化ポリシーを適用する
  if manager.optimizationPolicies.len == 0:
    return
    
  # ポリシーを優先度順にソート
  let sortedPolicies = manager.optimizationPolicies.sortedByIt(-it.priority)
  
  for policy in sortedPolicies:
    # すべての条件が満たされた場合にアクションを実行
    let allConditionsMet = policy.conditions.allIt(it(manager.context))
    
    if allConditionsMet:
      for action in policy.actions:
        await action(manager.context, manager)
      
      # ポリシー適用のメトリックを記録
      manager.recordMetric("policy_applied", 1.0, {"policy_name": policy.name}.toTable)

proc startNavigation*(manager: var OptimizationManager, url: string) {.async.} =
  ## 新しいナビゲーションを開始する
  manager.currentNavigationUrl = url
  manager.navigationStartTime = getTime()
  manager.optimizationStartTime = getTime()
  manager.context.currentPhase = opInitial
  
  # 最適化を実行するかどうかをチェック
  if not manager.shouldOptimize():
    return
  
  # ナビゲーション開始メトリクスを記録
  manager.recordMetric("navigation_start", 1.0, {"url": url}.toTable)
  
  # 既存のホバーターゲットをクリア
  withLock(manager.lock):
    manager.hoverTargets.clear()
  
  # 事前接続と事前フェッチの状態をリセット
  manager.preconnectedHosts.clear()
  
  # 事前フェッチ予算をリセット
  manager.prefetchBudgetBytes = manager.settings.prefetchLimit
  
  # 新しいURLのドメインとサブリソースドメインに事前接続
  if manager.settings.enablePreconnect:
    let parsedUrl = parseUri(url)
    let hostname = parsedUrl.hostname
    
    if hostname.len > 0:
      # メインドメインに事前接続
      let mainDomainResult = await manager.preconnectUrl("https://" & hostname, 100)
      manager.recordMetric("preconnect_main_domain", if mainDomainResult: 1.0 else: 0.0)
      
      # 頻繁に使用される関連サブドメインを予測して事前接続
      # 例：CDN、API、静的アセットなど
      let possibleSubdomains = [
        "cdn." & hostname,
        "static." & hostname,
        "api." & hostname,
        "images." & hostname,
        "assets." & hostname,
        "fonts." & hostname
      ]
      
      # サブドメインの存在確率に基づいてフィルタリング
      var subdomainsToPreconnect: seq[string] = @[]
      
      for subdomain in possibleSubdomains:
        # CSPから安全なドメインを確認
        if manager.contentSecurityPolicy.isAllowedForConnecting(subdomain):
          subdomainsToPreconnect.add("https://" & subdomain)
      
      # 最も可能性の高いサブドメインから順に事前接続
      var priority = 90
      for i, subdomainUrl in subdomainsToPreconnect:
        if i < 3:  # 最大3つのサブドメインのみ事前接続
          asyncCheck manager.preconnectUrl(subdomainUrl, priority)
          priority -= 10  # 優先度を下げる
  
  # 適応最適化を開始
  if manager.settings.strategy == osAdaptive:
    # ネットワーク分析を実行
    await manager.analyzeNetworkConditions()
  
  # 最適化ポリシーを適用
  await manager.applyOptimizationPolicies()
  
  # DNS キャッシュのウォームアップ
  asyncCheck manager.warmupDnsCache(url)
  
  # フェーズをクリティカルに変更
  manager.context.currentPhase = opCritical

proc analyzeNetworkConditions*(manager: var OptimizationManager) {.async.} =
  ## ネットワーク状況を分析し、最適化設定を調整する
  # 現在の時刻を取得
  let currentTime = getTime()
  
  # 前回の分析から十分な時間が経過していない場合はスキップ
  if (currentTime - manager.lastNetworkAnalysisTime).inSeconds < 10:
    return
  
  manager.lastNetworkAnalysisTime = currentTime
  
  # ネットワーク状況を再評価
  let prevCondition = manager.context.networkCondition
  manager.context.networkCondition = evaluateNetworkCondition(manager.context)
  
  # ネットワーク状況が変化した場合、設定を調整
  if prevCondition != manager.context.networkCondition:
    manager.recordMetric("network_condition_changed", 1.0, 
      {"from": $prevCondition, "to": $manager.context.networkCondition}.toTable)
    
    # ネットワーク状況に基づいて設定を調整
    case manager.context.networkCondition
    of ncExcellent:
      # 優れたネットワーク状況では積極的な最適化
      manager.settings.prefetchConcurrency = max(6, manager.settings.prefetchConcurrency)
      manager.settings.enablePrefetch = true
      manager.settings.prefetchHighPriorityOnly = false
      manager.settings.enableSpeculativeLoading = true
      manager.settings.aggressivePreconnect = true
    of ncGood:
      # 良好なネットワーク状況ではバランスの取れた最適化
      manager.settings.prefetchConcurrency = 4
      manager.settings.enablePrefetch = true
      manager.settings.prefetchHighPriorityOnly = false
      manager.settings.enableSpeculativeLoading = true
      manager.settings.aggressivePreconnect = false
    of ncModerate:
      # 中程度のネットワークでは控えめな最適化
      manager.settings.prefetchConcurrency = 2
      manager.settings.enablePrefetch = true
      manager.settings.prefetchHighPriorityOnly = true
      manager.settings.enableSpeculativeLoading = false
      manager.settings.aggressivePreconnect = false
    of ncPoor:
      # 貧弱なネットワークでは最小限の最適化
      manager.settings.prefetchConcurrency = 1
      manager.settings.enablePrefetch = false
      manager.settings.prefetchHighPriorityOnly = true
      manager.settings.enableSpeculativeLoading = false
      manager.settings.aggressivePreconnect = false
      # クリティカルなリソースのみに集中
      manager.settings.preloadFonts = false
      manager.settings.preloadMainThreadScripts = false
    of ncOffline:
      # オフライン状態では最適化を無効にする
      manager.enabledInContext = false
      return
    
    # 最適化設定が変更されたことを記録
    manager.recordMetric("optimization_settings_adjusted", 1.0, 
      {"network_condition": $manager.context.networkCondition}.toTable)
  
  # ネットワーク分析の統計を記録
  manager.recordMetric("network_analysis_performed", 1.0, 
    {"rtt": $manager.context.rtt, "downlink": $manager.context.downlinkSpeed}.toTable)

proc warmupDnsCache*(manager: var OptimizationManager, url: string) {.async.} =
  ## DNSキャッシュをウォームアップする（関連ドメインのDNSを事前解決）
  let parsedUrl = parseUri(url)
  let hostname = parsedUrl.hostname
  
  if hostname.len == 0:
    return
  
  # まず、メインドメインのDNSを解決
  discard await manager.dnsResolver.resolveHost(hostname)
  
  # 関連ドメインを推測して解決
  let urlLower = url.toLowerAscii
  var relatedHosts: seq[string] = @[]
  
  # ページタイプに基づいて関連ドメインを推測
  if urlLower.contains("/product/") or urlLower.contains("/item/"):
    # 商品ページの場合は、画像CDNやレビューAPIなどが必要になる可能性が高い
    relatedHosts.add("images." & hostname)
    relatedHosts.add("reviews." & hostname)
    relatedHosts.add("recommendations." & hostname)
  elif urlLower.contains("/news/") or urlLower.contains("/article/"):
    # ニュース記事の場合は、画像やソーシャルメディア関連のドメインが必要になる可能性が高い
    relatedHosts.add("media." & hostname)
    relatedHosts.add("static." & hostname)
    relatedHosts.add("cdn.twitter.com")
    relatedHosts.add("connect.facebook.net")
  elif urlLower.contains("/search"):
    # 検索ページの場合は、サジェストAPIやトラッキングが必要になる可能性が高い
    relatedHosts.add("suggest." & hostname)
    relatedHosts.add("api." & hostname)
    relatedHosts.add("stats." & hostname)
  
  # キャッシュに優先順位をつけて解決
  for host in relatedHosts:
    asyncCheck manager.dnsResolver.resolveHost(host)

proc preconnectUrl*(manager: var OptimizationManager, url: string, priority: int = 50): Future[bool] {.async.} =
  ## URLに事前接続する
  if not manager.shouldOptimize() or not manager.settings.enablePreconnect:
    return false
  
  let parsedUrl = parseUri(url)
  let hostname = parsedUrl.hostname
  
  if hostname.len == 0:
    return false
  
  # セキュリティチェック - CSPに基づいて接続が許可されているか確認
  if not manager.contentSecurityPolicy.isAllowedForConnecting(hostname):
    manager.recordMetric("preconnect_blocked_by_csp", 1.0, {"hostname": hostname}.toTable)
    return false
  
  # 既に事前接続済みで、期限切れでない場合はスキップ
  if hostname in manager.preconnectedHosts and not manager.isPreconnectExpired(hostname):
    return true
  
  # 事前接続を実行
  let connectionInfo = await manager.preconnectManager.preconnect(url, priority)
  
  # 最後の事前接続時間を記録
  withLock(manager.lock):
    manager.lastPreconnectTimes[hostname] = getTime()
  
  # 接続が確立されたかどうかをチェック
  if connectionInfo.state == csEstablished:
    withLock(manager.lock):
      manager.preconnectedHosts.incl(hostname)
    
    # メトリックを記録
    manager.recordMetric("preconnect_success", 1.0, 
      {"hostname": hostname, "time_ms": $connectionInfo.connectTimeMs}.toTable)
    
    return true
  else:
    # 失敗時のメトリックを記録
    manager.recordMetric("preconnect_failure", 1.0, 
      {"hostname": hostname, "reason": connectionInfo.errorReason}.toTable)
    
    return false

proc preconnectOrigins*(manager: var OptimizationManager, origins: seq[string]) {.async.} =
  ## 複数のオリジンに事前接続する
  if not manager.shouldOptimize() or not manager.settings.enablePreconnect:
    return
  
  # 優先順位付けされたオリジンのリスト
  var prioritizedOrigins: seq[tuple[origin: string, priority: int]] = @[]
  
  # オリジンに優先順位を割り当て
  for i, origin in origins:
    # 優先順位は0から始まるインデックスの逆数（最初のオリジンが最も高い）
    let calculatedPriority = max(10, 100 - i * 10)
    prioritizedOrigins.add((origin, calculatedPriority))
  
  # 同時に処理するオリジンの数を制限
  let concurrentLimit = min(5, manager.settings.maxConcurrentConnections div 2)
  var futures: seq[Future[bool]] = @[]
  
  for i, item in prioritizedOrigins:
    futures.add(manager.preconnectUrl(item.origin, item.priority))
    
    # 同時接続数の制限に達したら、完了を待つ
    if futures.len >= concurrentLimit or i == prioritizedOrigins.len - 1:
      # すべての接続が完了するのを待つ
      discard await all(futures)
      futures = @[]

proc prefetchUrl*(manager: var OptimizationManager, url: string, 
                 priority: PrefetchPriority = ppNormal,
                 preconnectOnly: bool = false): Future[bool] {.async.} =
  ## URLを事前フェッチする
  if not manager.shouldOptimize() or not manager.settings.enablePrefetch:
    # 事前フェッチが無効の場合は代わりに事前接続を試みる
    if manager.settings.enablePreconnect:
      return await manager.preconnectUrl(url, ord(priority))
    return false
  
  # 高優先度のリソースのみを事前フェッチする設定の場合
  if manager.settings.prefetchHighPriorityOnly and priority < ppHigh:
    # 代わりに事前接続を実行する
    return await manager.preconnectUrl(url, ord(priority))
  
  # 残りのプリフェッチ予算を確認
  if manager.prefetchBudgetBytes <= 0:
    # 予算切れの場合は事前接続のみを実行
    manager.recordMetric("prefetch_budget_exceeded", 1.0)
    return await manager.preconnectUrl(url, ord(priority))
  
  # URLのスキームを確認
  let parsedUrl = parseUri(url)
  if parsedUrl.scheme notin ["http", "https"]:
    # HTTPまたはHTTPS以外のスキームは事前フェッチできない
    return false
  
  # リソースタイプを推測
  let resourceType = guessResourceType(url)
  
  # 特定のリソースタイプに対する設定をチェック
  if resourceType == rtFont and not manager.settings.preloadFonts:
    # フォントの事前ロードが無効の場合は事前接続のみを実行
    return await manager.preconnectUrl(url, ord(priority))
  
  if resourceType == rtJavaScript and not manager.settings.preloadMainThreadScripts:
    # スクリプトの事前ロードが無効の場合は事前接続のみを実行
    return await manager.preconnectUrl(url, ord(priority))
  
  if resourceType == rtCSS and not manager.settings.preloadCriticalCss:
    # CSSの事前ロードが無効の場合は事前接続のみを実行
    return await manager.preconnectUrl(url, ord(priority))
  
  # セキュリティチェック - CSPに基づいてフェッチが許可されているか確認
  let hostname = parsedUrl.hostname
  if not manager.contentSecurityPolicy.isAllowedForFetching(hostname, resourceType):
    manager.recordMetric("prefetch_blocked_by_csp", 1.0, {"url": url}.toTable)
    # 代わりに事前接続を試みる
    return await manager.preconnectUrl(url, ord(priority))
  
  # 既に事前フェッチ済みのURLはスキップ
  withLock(manager.lock):
    if url in manager.prefetchedUrls:
      return true
  
  # 事前フェッチのみか事前接続のみかを決定
  var actualPreconnectOnly = preconnectOnly
  
  # ネットワーク状況に基づいて調整
  if manager.context.networkCondition in [ncPoor, ncModerate] and not manager.settings.aggressivePreconnect:
    actualPreconnectOnly = true
  
  # 帯域幅が限られている場合は事前接続のみにフォールバック
  if manager.context.downlinkSpeed < 1.0 and resourceType notin [rtHTML, rtCSS]:
    actualPreconnectOnly = true
  
  # 実行中の事前フェッチが多すぎる場合は一部をプリコネクトのみに変更
  let activePreconnects = manager.preconnectManager.getActiveConnectionCount()
  let activePrefetches = manager.prefetchManager.getActivePrefetchCount()
  
  if activePrefetches >= manager.settings.prefetchConcurrency:
    # 同時実行数の上限に達している場合は、優先度が低いリソースは事前接続のみにする
    if priority < ppHigh:
      actualPreconnectOnly = true
  
  # 事前フェッチリクエストの詳細情報を設定
  var prefetchOptions = PrefetchOptions(
    priority: priority,
    preconnectOnly: actualPreconnectOnly,
    parentUrl: some(manager.currentNavigationUrl),
    resourceType: resourceType,
    preferBrotli: manager.settings.brotliPreference,
    preferHttp2: manager.settings.http2Preference,
    preferHttp3: manager.settings.http3Preference,
    inlineIfSmall: manager.settings.inlineSmallResources,
    inlineThreshold: manager.settings.inlineThresholdBytes
  )
  
  # 事前フェッチを実行
  let prefetchRequest = await manager.prefetchManager.prefetch(
    url = url,
    options = prefetchOptions
  )
  
  # 成功したかどうかをチェック
  if prefetchRequest.status == psCompleted:
    withLock(manager.lock):
      manager.prefetchedUrls.incl(url)
      
      # 残りの事前フェッチ予算を更新
      if not actualPreconnectOnly:
        manager.prefetchBudgetBytes -= prefetchRequest.bytesFetched
    
    # メトリックを記録
    let metadataTable = {
      "url": url,
      "bytes": $prefetchRequest.bytesFetched,
      "time_ms": $prefetchRequest.fetchTimeMs,
      "resource_type": $resourceType
    }.toTable
    
    manager.recordMetric("prefetch_success", 1.0, metadataTable)
    
    # リソースタイミングを記録
    if not actualPreconnectOnly and prefetchRequest.timing.isSome:
      withLock(manager.lock):
        manager.resourceTimings[url] = prefetchRequest.timing.get
    
    return true
  else:
    # 失敗した理由を記録
    let metadataTable = {
      "url": url,
      "reason": prefetchRequest.errorReason,
      "resource_type": $resourceType
    }.toTable
    
    manager.recordMetric("prefetch_failure", 1.0, metadataTable)
    
    return false

proc adaptPrefetchingToNetworkConditions*(manager: var OptimizationManager) {.async.} =
  ## ネットワーク状況に基づいて事前フェッチ設定を適応させる
  if not manager.settings.adaptivePrefetching:
    return
  
  # 前回の適応から十分な時間が経過していない場合はスキップ
  let currentTime = getTime()
  if (currentTime - manager.lastAdaptationTime).inSeconds < 30:
    return
  
  manager.lastAdaptationTime = currentTime
  
  # 現在の帯域幅使用状況を取得
  let currentBandwidth = manager.bandwidthMonitor.currentDownloadRate
  let availableBandwidth = manager.bandwidthMonitor.availableBandwidth
  let usageRatio = if availableBandwidth > 0: currentBandwidth / availableBandwidth else: 1.0
  
  # ネットワーク状況に基づいて適応
  case manager.context.networkCondition
  of ncExcellent, ncGood:
    # 余裕がある場合は事前フェッチを拡大
    if usageRatio < 0.5:
      manager.settings.prefetchConcurrency = min(manager.settings.prefetchConcurrency + 1, 8)
      manager.settings.prefetchHighPriorityOnly = false
    elif usageRatio > 0.8:
      # 帯域幅使用率が高い場合は抑制
      manager.settings.prefetchConcurrency = max(manager.settings.prefetchConcurrency - 1, 2)
  of ncModerate:
    # 中程度のネットワークでは控えめに
    if usageRatio > 0.7:
      manager.settings.prefetchConcurrency = max(manager.settings.prefetchConcurrency - 1, 1)
      manager.settings.prefetchHighPriorityOnly = true
    elif usageRatio < 0.3:
      manager.settings.prefetchConcurrency = min(manager.settings.prefetchConcurrency + 1, 4)
  of ncPoor:
    # 貧弱なネットワークでは最小限に
    manager.settings.prefetchConcurrency = 1
    manager.settings.prefetchHighPriorityOnly = true
    if usageRatio > 0.5:
      # 深刻な帯域幅圧迫がある場合は無効化
      manager.settings.enablePrefetch = false
  of ncOffline:
    # オフラインでは無効化
    manager.settings.enablePrefetch = false
  
  # 適応の結果を記録
  manager.recordMetric("adaptive_prefetching_adjustment", 1.0, {
    "network_condition": $manager.context.networkCondition,
    "bandwidth_usage_ratio": $usageRatio,
    "new_concurrency": $manager.settings.prefetchConcurrency
  }.toTable)

proc onHover*(manager: var OptimizationManager, url: string) {.async.} =
  ## ユーザーがリンクにホバーしたときの処理
  if not manager.shouldOptimize():
    return
  
  # 現在の時刻を取得
  let currentTime = getTime()
  
  # ホバーターゲットに追加または更新
  withLock(manager.lock):
    manager.hoverTargets[url] = currentTime
  
  # URLを解析してリソースタイプを推測
  let resourceType = guessResourceType(url)
  
  # 事前接続を実行
  if manager.settings.preconnectOnHover:
    asyncCheck manager.preconnectUrl(url, 70)  # ホバーは中程度の優先度
  
  # 事前フェッチをスケジュール
  if manager.settings.prefetchOnHover and manager.settings.enablePrefetch:
    # 遅延後に事前フェッチを実行
    proc delayedPrefetch() {.async.} =
      # リンクのURLやリソースタイプに基づいて遅延時間を調整
      var hoverDelay = manager.settings.prefetchHoverDelay
      
      # クリティカルリソースの場合は遅延を短縮
      if resourceType in [rtHTML, rtCSS]:
        hoverDelay = max(50, hoverDelay div 2)
      
      # ネットワーク状況に基づいて遅延を調整
      if manager.context.networkCondition == ncPoor:
        hoverDelay = hoverDelay * 2
      
      await sleepAsync(hoverDelay)
      
      # ホバーが継続しているかチェック
      var isHoverContinued = false
      withLock(manager.lock):
        isHoverContinued = url in manager.hoverTargets and 
                         (getTime() - manager.hoverTargets[url]).inMilliseconds >= hoverDelay
      
      if isHoverContinued:
        # 事前フェッチの優先度を設定
        let prefetchPriority = if resourceType in [rtHTML, rtCSS]: ppHigh else: ppNormal
        
        # 事前フェッチの実行
        let isPrefetchTriggered = await manager.prefetchUrl(url, prefetchPriority)
        
        # メトリックを記録
        manager.recordMetric("hover_prefetch_triggered", if isPrefetchTriggered: 1.0 else: 0.0, 
          {"url": url, "resource_type": $resourceType}.toTable)
    
    asyncCheck delayedPrefetch()
  
  # メトリックを記録
  manager.recordMetric("link_hover", 1.0, {"url": url}.toTable)

proc onLinkClick*(manager: var OptimizationManager, url: string) {.async.} =
  ## ユーザーがリンクをクリックしたときの処理
  # クリックされたURLを記録
  withLock(manager.lock):
    manager.predictedByClicking.incl(url)
  
  # 最適化フェーズを遷移前に変更
  manager.context.currentPhase = opPreNavigation
  
  # 事前接続を最高優先度で実行
  asyncCheck manager.preconnectUrl(url, 100)
  
  # クリック時のナビゲーション予測を更新
  manager.updateNavigationPredictions(url, 1.0)  # 信頼度100%
  
  # 事前フェッチをキャンセル（すぐにナビゲーションするため）
  manager.prefetchManager.cancelLowPriorityPrefetches()
  
  # 新しいページのサブリソースに対する準備
  # 例：HTMLページの場合、通常必要となる関連リソースに事前接続
  let resourceType = guessResourceType(url)
  if resourceType == rtHTML:
    let parsedUrl = parseUri(url)
    let hostname = parsedUrl.hostname
    
    if hostname.len > 0:
      # 一般的なサブリソースドメインに事前接続
      let commonSubresources = [
        "https://cdn." & hostname,
        "https://static." & hostname,
        "https://images." & hostname
      ]
      
      asyncCheck manager.preconnectOrigins(commonSubresources)
  
  # メトリクスを更新
  manager.recordMetric("link_click", 1.0, {"url": url}.toTable)

proc updateNavigationPredictions*(manager: var OptimizationManager, url: string, likelihood: float) =
  ## ナビゲーション予測を更新する
  withLock(manager.lock):
    manager.navigationPredictions[url] = likelihood
  
    # 予測キャッシュのサイズを制限（最大100個）
    if manager.navigationPredictions.len > 100:
      # 可能性の低い予測を削除
      var items = toSeq(manager.navigationPredictions.pairs)
      items.sort(proc(x, y: tuple[key: string, val: float]): int = 
        cmp(x.val, y.val))
      
      # 最も可能性の低い項目を削除
      for i in 0..<(items.len - 100):
        manager.navigationPredictions.del(items[i].key)

proc predictNavigation*(manager: var OptimizationManager, urls: seq[string], 
                       likelihood: float = 0.5) {.async.} =
  ## ナビゲーション予測を追加する
  if not manager.shouldOptimize():
    return
  
  # 予測URLを記録
  manager.predictedUrls = urls
  
  # 各URLの予測をナビゲーション予測テーブルに追加
  for url in urls:
    manager.updateNavigationPredictions(url, likelihood)
  
  # 可能性の高いURLに事前接続
  if likelihood >= 0.5 and manager.settings.enablePreconnect:
    # 投機的ロードをサポートしているかを確認
    let canSpeculativeLoad = manager.settings.enableSpeculativeLoading and 
                            likelihood >= manager.settings.speculationConfidenceThreshold
    
    # 優先順位に基づいて並行処理数を制限
    let maxConcurrentOps = if canSpeculativeLoad: 5 else: 3
    var futures: seq[Future[bool]] = @[]
    var processedCount = 0
    
    for url in urls:
      # 優先度を可能性に基づいて調整（0-100）
      let priority = int(likelihood * 100.0)
      
      if canSpeculativeLoad and processedCount < 2:
        # 投機的ロードが有効で、上位2つのURLの場合は事前フェッチを実行
        futures.add(manager.prefetchUrl(url, ppMedium))
      else:
        # それ以外の場合は事前接続のみを実行
        futures.add(manager.preconnectUrl(url, priority))
      
      processedCount += 1
      
      # 同時実行数の制限に達したら、一部の完了を待つ
      if futures.len >= maxConcurrentOps:
        # 少なくとも1つの処理が完了するのを待つ
        discard await oneOf(futures)
        # 完了した処理を取り除く
        futures = futures.filterIt(not it.finished)
    
    # 残りの処理の完了を待つ
    if futures.len > 0:
      discard await all(futures)
  
  # 予測に基づくメトリックを記録
  manager.recordMetric("navigation_prediction_added", float(urls.len), 
    {"likelihood": $likelihood}.toTable)

proc updateNetworkInfo*(manager: var OptimizationManager, 
                      connectionType: string = "", 
                      effectiveType: string = "",
                      downlinkSpeed: float = 0.0,
                      rtt: int = 0,
                      saveDataMode: bool = false,
                      batteryLevel: float = -1.0,
                      batteryCharging: bool = true,
                      jitter: float = -1.0,
                      packetLoss: float = -1.0) {.async.} =
  ## ネットワーク情報と端末状態を更新する
  var contextUpdated = false
  
  # 値が指定されている場合のみ更新
  if connectionType != "":
    manager.context.connectionType = connectionType
    contextUpdated = true
  
  if effectiveType != "":
    manager.context.networkEffectiveType = effectiveType
    contextUpdated = true
  
  if downlinkSpeed > 0.0:
    manager.context.downlinkSpeed = downlinkSpeed
    # 実効帯域幅も更新
    manager.context.effectiveBandwidthKbps = downlinkSpeed * 1000.0
    contextUpdated = true
  
  if rtt > 0:
    manager.context.rtt = rtt
    contextUpdated = true
  
  # データセーブモードが変更された場合
  if saveDataMode != manager.context.saveDataMode:
    manager.context.saveDataMode = saveDataMode
    contextUpdated = true
  
  # バッテリー情報が指定されている場合
  if batteryLevel >= 0.0 and batteryLevel <= 1.0:
    manager.context.batteryLevel = batteryLevel
    contextUpdated = true
  
  # バッテリー充電状態が変更された場合
  if batteryCharging != manager.context.batteryCharging:
    manager.context.batteryCharging = batteryCharging
    contextUpdated = true
  
  # ジッターが指定されている場合
  if jitter >= 0.0:
    manager.context.jitter = jitter
    contextUpdated = true
  
  # パケットロスが指定されている場合
  if packetLoss >= 0.0 and packetLoss <= 1.0:
    manager.context.packetLoss = packetLoss
    contextUpdated = true
  
  # コンテキストが更新された場合の処理
  if contextUpdated:
    # ネットワーク状況を再評価
    let prevCondition = manager.context.networkCondition
    manager.context.networkCondition = evaluateNetworkCondition(manager.context)
    
    # メトリクスを記録
    manager.recordMetric("network_info_updated", 1.0, {
      "connection_type": manager.context.connectionType,
      "effective_type": manager.context.networkEffectiveType,
      "downlink_speed": $manager.context.downlinkSpeed,
      "rtt": $manager.context.rtt,
      "network_condition": $manager.context.networkCondition
    }.toTable)
    
    # 最適化ポリシーを適用
    await manager.applyOptimizationPolicies()
    
    # 適応型事前フェッチの調整
    await manager.adaptPrefetchingToNetworkConditions()

proc recordResourceLoad*(manager: var OptimizationManager, url: string, size: int, loadTimeMs: int, 
                        timing: Option[ResourceLoadTiming] = none(ResourceLoadTiming)) =
  ## リソースのロード統計を記録する
  withLock(manager.lock):
    manager.resourceStats[url] = (size, loadTimeMs)
    
    # タイミング情報が提供されている場合は記録
    if timing.isSome:
      manager.resourceTimings[url] = timing.get
  
  # リソースタイプごとの統計を更新
  let resourceType = guessResourceType(url)
  
  # メトリックを記録
  let metadataTable = {
    "url": url,
    "size": $size,
    "load_time_ms": $loadTimeMs,
    "resource_type": $resourceType
  }.toTable
  
  manager.recordMetric("resource_loaded", 1.0, metadataTable)
  
  # タイプ別のメトリクスも記録
  manager.recordMetric("resource_load_time_" & $resourceType, float(loadTimeMs))
  manager.recordMetric("resource_size_" & $resourceType, float(size))
  
  # 事前フェッチされていたかどうかを確認
  var wasPrefetched = false
  withLock(manager.lock):
    wasPrefetched = url in manager.prefetchedUrls
  
  if wasPrefetched:
    # 事前フェッチの効果を記録
    manager.recordMetric("prefetch_hit", 1.0, {"url": url}.toTable)
    
    # 帯域幅モニターに事前フェッチヒットを通知
    manager.bandwidthMonitor.recordPrefetchHit(size)
  
  # リソースをロードする必要があったかどうかを評価
  if size > 0:
    # 帯域幅モニターにリソースロードを通知
    manager.bandwidthMonitor.recordResourceLoad(size, loadTimeMs)
  
  # ネットワーク状況の変化を検知するために分析を実行
  if manager.resourceTimings.len mod 10 == 0:  # 10リソースごとに実行
    asyncCheck manager.analyzeNetworkConditions()

proc prioritizeResources*(manager: var OptimizationManager, resources: seq[ResourcePriority]) {.async.} =
  ## リソースの優先順位付けを実行する
  if not manager.settings.enablePrioritization:
    return
  
  # 優先順位付けの開始時間を記録
  let startTime = getMonoTime()
  
  # リソースを追加する前に現在のフェーズに基づいて設定を調整
  case manager.context.currentPhase
  of opInitial, opCritical:
    # 初期フェーズまたはクリティカルフェーズでは、クリティカルリソースに注力
    manager.prioritizer.setCriticalPathFocus(true)
    manager.prioritizer.setViewportBoost(manager.settings.priorityBoostForViewport)
  of opDeferred, opIdle:
    # 遅延フェーズまたはアイドルフェーズでは、優先度の低いリソースも考慮
    manager.prioritizer.setCriticalPathFocus(false)
    manager.prioritizer.setViewportBoost(1.0)
  of opPreNavigation:
    # ナビゲーション前フェーズでは、次のページのクリティカルリソースに注力
    manager.prioritizer.setCriticalPathFocus(true)
    manager.prioritizer.setViewportBoost(2.0)
  
  # ネットワーク状況に基づいて優先順位付けの戦略を調整
  case manager.context.networkCondition
  of ncPoor:
    # 貧弱なネットワークでは、厳格な優先順位付けが必要
    manager.prioritizer.setStrictPrioritization(true)
    manager.prioritizer.setDelayNonEssentialResources(true)
  of ncModerate:
    # 中程度のネットワークでは、優先順位付けは重要だが柔軟性も必要
    manager.prioritizer.setStrictPrioritization(true)
    manager.prioritizer.setDelayNonEssentialResources(false)
  else:
    # 良好または優れたネットワークでは、柔軟な優先順位付けで並行処理を最大化
    manager.prioritizer.setStrictPrioritization(false)
    manager.prioritizer.setDelayNonEssentialResources(false)
  
  # プライオリタイザーにリソースを追加
  for resource in resources:
    manager.prioritizer.addResource(resource)
  
  # 優先順位付けを実行
  manager.prioritizer.prioritize()
  
  # クリティカルリソースを特定して記録
  let criticalResources = manager.prioritizer.criticalResources
  withLock(manager.lock):
    for url in criticalResources:
      manager.criticalPathResources.incl(url)
  
  # クリティカルリソースを事前接続
  var futures: seq[Future[bool]] = @[]
  for url in criticalResources:
    futures.add(manager.preconnectUrl(url, 100))  # 最高優先度
    
    # 同時接続数を制限
    if futures.len >= 5:
      discard await oneOf(futures)
      futures = futures.filterIt(not it.finished)
  
  # 残りの接続の完了を待つ
  if futures.len > 0:
    discard await all(futures)
  
  # 優先度の高いリソースを事前フェッチ
  if manager.settings.enablePrefetch:
    futures = @[]
    var prefetchCount = 0
    
    for url in manager.prioritizer.resourceOrder:
      let priority = manager.prioritizer.priorities[url]
      
      # 事前フェッチするリソースをフィルタリング
      if priority.level <= plHigh or priority.isInViewport or priority.renderBlocking:
        # 事前フェッチの優先度を決定
        let prefetchPriority = if priority.level <= plHigh: ppHigh else: ppNormal
        
        # 同時に事前フェッチするリソース数を制限
        if prefetchCount < manager.settings.prefetchConcurrency:
          futures.add(manager.prefetchUrl(url, prefetchPriority))
          prefetchCount += 1
          
          # バッチ処理を実装
          if futures.len >= 3:
            discard await oneOf(futures)
            futures = futures.filterIt(not it.finished)
    
    # 残りの事前フェッチの完了を待つ
    if futures.len > 0:
      discard await all(futures)
  
  # リソースヒントを生成
  let hints = manager.generateResourceHints()
  withLock(manager.lock):
    manager.resourceHints = hints
  
  # 優先順位付けのパフォーマンスを記録
  let durationMs = (getMonoTime() - startTime).inMilliseconds
  manager.recordMetric("prioritization_duration_ms", float(durationMs), 
    {"resource_count": $resources.len, "critical_count": $criticalResources.len}.toTable)

proc generateResourceHints*(manager: OptimizationManager): seq[ResourceHint] =
  ## リソースヒント（プリロード、プリコネクト、プリフェッチなど）を生成する
  result = @[]
  
  # ネットワーク最適化が無効の場合は空の結果を返す
  if not manager.shouldOptimize():
    return
  
  # クリティカルリソースが優先
  var criticalResources: seq[string] = @[]
  for url in manager.prioritizer.criticalResources:
    criticalResources.add(url)
  
  # リソースタイプごとのヒント上限を設定
  let maxHintsByType = {
    "preload": min(manager.settings.maxPreloadHints, 10),
    "preconnect": 8,
    "prefetch": 5,
    "dns-prefetch": 10
  }.toTable
  
  # タイプごとのカウンターを初期化
  var hintCounts = {
    "preload": 0,
    "preconnect": 0,
    "prefetch": 0,
    "dns-prefetch": 0
  }.toTable
  
  # まずはプリロードヒント（クリティカルリソース）
  if manager.settings.enablePrioritization:
    for url in criticalResources:
      if hintCounts["preload"] >= maxHintsByType["preload"]:
        break
      
      let priority = manager.prioritizer.priorities.getOrDefault(url)
      let mediaType = manager.prioritizer.mediaTypes.getOrDefault(url, "")
      
      var resourceAs = ""
      case priority.resourceType
      of rtCSS:
        resourceAs = "style"
      of rtJavaScript:
        resourceAs = "script"
      of rtFont:
        resourceAs = "font"
      of rtImage:
        resourceAs = "image"
      of rtAudio:
        resourceAs = "audio"
      of rtVideo:
        resourceAs = "video"
      else:
        resourceAs = "fetch"
      
      # クリティカルリソースタイプのフィルタリング
      if (priority.resourceType == rtFont and not manager.settings.preloadFonts) or
         (priority.resourceType == rtJavaScript and not manager.settings.preloadMainThreadScripts) or
         (priority.resourceType == rtCSS and not manager.settings.preloadCriticalCss):
        continue
      
      # プリロードヒントを追加
      result.add(ResourceHint(
        url: url,
        type: rhtPreload,
        `as`: resourceAs,
        crossOrigin: isExternalUrl(url, manager.currentNavigationUrl),
        importance: if priority.level <= plHigh: "high" else: "auto"
      ))
      
      hintCounts["preload"] += 1
  
  # 事前接続ヒント（将来的に必要とされそうなドメイン）
  if manager.settings.enablePreconnect:
    # 予測されたナビゲーションのホスト
    var predictedHosts: seq[string] = @[]
    
    for url, likelihood in manager.navigationPredictions:
      if likelihood >= 0.7:  # 可能性が高いもののみ
        let parsedUrl = parseUri(url)
        if parsedUrl.hostname.len > 0 and parsedUrl.hostname notin predictedHosts:
          predictedHosts.add(parsedUrl.hostname)
          
          if hintCounts["preconnect"] < maxHintsByType["preconnect"]:
            # プリコネクトヒントを追加
            result.add(ResourceHint(
              url: fmt"https://{parsedUrl.hostname}",
              type: rhtPreconnect,
              crossOrigin: isExternalUrl(url, manager.currentNavigationUrl),
              importance: "high"
            ))
            
            hintCounts["preconnect"] += 1
    
    # よく使われるサードパーティドメインのプリコネクト
    let commonThirdParties = [
      "fonts.googleapis.com",
      "fonts.gstatic.com",
      "cdn.jsdelivr.net",
      "unpkg.com"
    ]
    
    for host in commonThirdParties:
      if hintCounts["preconnect"] >= maxHintsByType["preconnect"]:
        break
      
      # プリコネクトヒントを追加
      result.add(ResourceHint(
        url: fmt"https://{host}",
        type: rhtPreconnect,
        crossOrigin: true,
        importance: "low"
      ))
      
      hintCounts["preconnect"] += 1
  
  # DNS事前解決ヒント（後で必要になるかもしれないドメイン）
  var dnsHints: seq[string] = @[]
  
  # ナビゲーション予測からDNSヒントを追加
  for url, likelihood in manager.navigationPredictions:
    if likelihood >= 0.5 and likelihood < 0.7:  # 中程度の可能性
      let parsedUrl = parseUri(url)
      if parsedUrl.hostname.len > 0 and 
         parsedUrl.hostname notin dnsHints and
         parsedUrl.hostname notin predictedHosts:  # 既にプリコネクトしていない
        dnsHints.add(parsedUrl.hostname)
        
        if hintCounts["dns-prefetch"] < maxHintsByType["dns-prefetch"]:
          # DNSプリフェッチヒントを追加
          result.add(ResourceHint(
            url: fmt"https://{parsedUrl.hostname}",
            type: rhtDnsPrefetch,
            crossOrigin: isExternalUrl(url, manager.currentNavigationUrl),
            importance: "low"
          ))
          
          hintCounts["dns-prefetch"] += 1
  
  # プリフェッチヒント（将来のナビゲーション用）
  if manager.settings.enablePrefetch and manager.settings.enableSpeculativeLoading:
    var prefetchCandidates: seq[tuple[url: string, likelihood: float]] = @[]
    
    # 可能性の高いページナビゲーションを抽出
    for url, likelihood in manager.navigationPredictions:
      if likelihood >= manager.settings.speculationConfidenceThreshold and 
         guessResourceType(url) == rtHTML:
        prefetchCandidates.add((url, likelihood))
    
    # 可能性の高い順にソート
    prefetchCandidates.sort(proc(x, y: tuple[url: string, likelihood: float]): int = 
      cmp(y.likelihood, x.likelihood))
    
    # トップN件のみプリフェッチ
    for i in 0..<min(prefetchCandidates.len, maxHintsByType["prefetch"]):
      let url = prefetchCandidates[i].url
      
      # プリフェッチヒントを追加
      result.add(ResourceHint(
        url: url,
        type: rhtPrefetch,
        crossOrigin: isExternalUrl(url, manager.currentNavigationUrl),
        importance: "low"
      ))
      
      hintCounts["prefetch"] += 1
  
  # 合計ヒント数をメトリックとして記録
  manager.recordMetric("resource_hints_generated", float(result.len), {
    "preload": $hintCounts["preload"],
    "preconnect": $hintCounts["preconnect"], 
    "prefetch": $hintCounts["prefetch"],
    "dns-prefetch": $hintCounts["dns-prefetch"]
  }.toTable)

proc isExternalUrl(url: string, baseUrl: string): bool =
  ## URLが外部（別オリジン）かどうかを判定
  if baseUrl.len == 0:
    return false
    
  let parsedUrl = parseUri(url)
  let parsedBase = parseUri(baseUrl)
  
  # スキームとホストが同じかどうかをチェック
  return parsedUrl.scheme != parsedBase.scheme or parsedUrl.hostname != parsedBase.hostname

proc generatePreloadHints*(manager: OptimizationManager): seq[tuple[url: string, `as`: string]] =
  ## プリロードヒントを生成する（レガシーメソッド、後方互換性のため）
  result = @[]
  
  let hints = manager.generateResourceHints()
  for hint in hints:
    if hint.type == rhtPreload:
      result.add((hint.url, hint.`as`))

proc getOptimizationStatus*(manager: OptimizationManager): JsonNode =
  ## 最適化ステータスをJSON形式で取得する
  result = newJObject()
  
  # 基本情報
  result["current_url"] = newJString(manager.currentNavigationUrl)
  result["navigation_time_ms"] = newJInt(
    (getTime() - manager.navigationStartTime).inMilliseconds)
  result["optimization_time_ms"] = newJInt(
    (getTime() - manager.optimizationStartTime).inMilliseconds)
  result["current_phase"] = newJString($manager.context.currentPhase)
  result["enabled"] = newJBool(manager.enabledInContext)
  
  # ネットワーク情報
  var networkInfo = newJObject()
  networkInfo["connection_type"] = newJString(manager.context.connectionType)
  networkInfo["effective_type"] = newJString(manager.context.networkEffectiveType)
  networkInfo["downlink_speed_mbps"] = newJFloat(manager.context.downlinkSpeed)
  networkInfo["rtt_ms"] = newJInt(manager.context.rtt)
  networkInfo["jitter_ms"] = newJFloat(manager.context.jitter)
  networkInfo["packet_loss"] = newJFloat(manager.context.packetLoss)
  networkInfo["effective_bandwidth_kbps"] = newJFloat(manager.context.effectiveBandwidthKbps)
  networkInfo["save_data_mode"] = newJBool(manager.context.saveDataMode)
  networkInfo["network_condition"] = newJString($manager.context.networkCondition)
  result["network_info"] = networkInfo
  
  # デバイス情報
  var deviceInfo = newJObject()
  deviceInfo["battery_level"] = newJFloat(manager.context.batteryLevel)
  deviceInfo["battery_charging"] = newJBool(manager.context.batteryCharging)
  deviceInfo["cpu_utilization"] = newJFloat(manager.context.cpuUtilization)
  deviceInfo["memory_pressure"] = newJFloat(manager.context.memoryPressure)
  deviceInfo["screen_width"] = newJInt(manager.context.screenWidth)
  deviceInfo["screen_height"] = newJInt(manager.context.screenHeight)
  deviceInfo["device_pixel_ratio"] = newJFloat(manager.context.devicePixelRatio)
  result["device_info"] = deviceInfo
  
  # 最適化設定
  var settings = newJObject()
  settings["strategy"] = newJString($manager.settings.strategy)
  settings["enable_preconnect"] = newJBool(manager.settings.enablePreconnect)
  settings["enable_prefetch"] = newJBool(manager.settings.enablePrefetch)
  settings["enable_prioritization"] = newJBool(manager.settings.enablePrioritization)
  settings["prefetch_concurrency"] = newJInt(manager.settings.prefetchConcurrency)
  settings["prefetch_budget_bytes"] = newJInt(manager.prefetchBudgetBytes)
  settings["adaptive_prefetching"] = newJBool(manager.settings.adaptivePrefetching)
  settings["speculative_loading"] = newJBool(manager.settings.enableSpeculativeLoading)
  result["settings"] = settings
  
  # 統計情報
  var stats = newJObject()
  stats["preconnected_hosts"] = newJInt(manager.preconnectedHosts.len)
  stats["prefetched_urls"] = newJInt(manager.prefetchedUrls.len)
  stats["hover_targets"] = newJInt(manager.hoverTargets.len)
  stats["predicted_urls"] = newJInt(manager.predictedUrls.len)
  stats["critical_path_resources"] = newJInt(manager.criticalPathResources.len)
  stats["resource_hints"] = newJInt(manager.resourceHints.len)
  stats["active_optimization_count"] = newJInt(manager.activeOptimizationCount)
  stats["metrics_collected"] = newJInt(manager.metricsCollected)
  
  # 帯域幅情報
  var bandwidthInfo = newJObject()
  bandwidthInfo["current_download_rate_bps"] = newJFloat(manager.bandwidthMonitor.currentDownloadRate)
  bandwidthInfo["available_bandwidth_bps"] = newJFloat(manager.bandwidthMonitor.availableBandwidth)
  bandwidthInfo["total_downloaded_bytes"] = newJInt(manager.bandwidthMonitor.totalDownloadedBytes)
  bandwidthInfo["total_uploaded_bytes"] = newJInt(manager.bandwidthMonitor.totalUploadedBytes)
  stats["bandwidth_info"] = bandwidthInfo
  
  result["stats"] = stats
  
  # メトリクス
  var metrics = newJObject()
  var metricsArray = newJArray()
  
  # 最新の50個のメトリクスのみを表示
  let startIdx = max(0, manager.optimizationMetrics.len - 50)
  for i in startIdx..<manager.optimizationMetrics.len:
    let metric = manager.optimizationMetrics[i]
    var metricObj = newJObject()
    metricObj["name"] = newJString(metric.name)
    metricObj["value"] = newJFloat(metric.value)
    metricObj["timestamp"] = newJString($metric.timestamp)
    
    var metadataObj = newJObject()
    for key, value in metric.metadata:
      metadataObj[key] = newJString(value)
    
    metricObj["metadata"] = metadataObj
    metricsArray.add(metricObj)
  
  result["metrics"] = metricsArray
  
  # リソースヒント
  var hintsArray = newJArray()
  for hint in manager.resourceHints:
    var hintObj = newJObject()
    hintObj["url"] = newJString(hint.url)
    hintObj["type"] = newJString($hint.type)
    hintObj["as"] = newJString(hint.`as`)
    hintObj["cross_origin"] = newJBool(hint.crossOrigin)
    hintObj["importance"] = newJString(hint.importance)
    hintsArray.add(hintObj)
  
  result["resource_hints"] = hintsArray

proc close*(manager: var OptimizationManager) {.async.} =
  ## リソースを解放する
  # クローズ操作の開始をログに記録
  manager.recordMetric("optimization_manager_closing", 1.0)
  
  # 事前接続マネージャーのアクティブな接続をすべて閉じる
  var closeErrors = 0
  for key, info in manager.preconnectManager.activeConnections:
    if info.socket.isSome:
      try:
        info.socket.get().close()
      except:
        closeErrors += 1
    if info.tlsSocket.isSome:
      try:
        info.tlsSocket.get().close()
      except:
        closeErrors += 1
  
  # 事前フェッチマネージャーのアクティブなリクエストをすべてキャンセルする
  let cancelledRequests = manager.prefetchManager.cancelAllPrefetches()
  
  # DNS解決器のキャッシュをフラッシュする
  manager.dnsResolver.flushCache()
  
  # ロックを解放する
  deinitLock(manager.lock)
  
  # メトリクスを記録
  let finalMetrics = {
    "close_errors": $closeErrors,
    "cancelled_requests": $cancelledRequests,
    "total_metrics_collected": $manager.metricsCollected,
    "total_preconnected_hosts": $manager.preconnectedHosts.len,
    "total_prefetched_urls": $manager.prefetchedUrls.len,
    "total_downloaded_bytes": $manager.bandwidthMonitor.totalDownloadedBytes.intToStr
  }.toTable
  
  # クローズ操作の完了をログに記録
  manager.recordMetric("optimization_manager_closed", 1.0, finalMetrics)
  
  # メモリを解放
  manager.preconnectedHosts.clear()
  manager.prefetchedUrls.clear()
  manager.hoverTargets.clear()
  manager.resourceStats.clear()
  manager.navigationPredictions.clear()
  manager.lastPreconnectTimes.clear()
  manager.resourceTimings.clear()
  manager.predictedUrls = @[]
  manager.optimizationPolicies = @[]
  manager.resourceHints = @[]
  manager.criticalPathResources.clear()
  manager.lastNetworkAnalysisTime = getTime()
  manager.metricsCollected = 0
  manager.prefetchBudgetBytes = 10 * 1024 * 1024
  manager.activeOptimizationCount = 0
  manager.lastAdaptationTime = getTime()
  manager.resourceHints.clear()
  manager.prefetchBudgetBytes = 10 * 1024 * 1024
  manager.activeOptimizationCount = 0
  manager.lastAdaptationTime = getTime()
  manager.resourceHints.clear()
  manager.criticalPathResources.clear()
  manager.lastNetworkAnalysisTime = getTime() 