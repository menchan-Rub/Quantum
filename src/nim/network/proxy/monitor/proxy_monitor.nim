# proxy_monitor.nim
# プロキシパフォーマンスモニタリングシステム
# プロキシの可用性、パフォーマンス、信頼性を監視し、最適なプロキシ選択をサポートします

import std/[tables, times, options, strutils, sequtils, uri, os, json]
import std/[asyncdispatch, asyncnet, httpclient]
import std/[random, math]
import logging

import ../http/http_proxy_types
import ../http/http_proxy_client
import ../socks/socks_proxy_types
import ../socks/socks_proxy_client
import ../../utils/ip_utils
import ../../utils/url_utils

type
  ProxyHealthStatus* = enum
    phsHealthy,        # 正常
    phsDegraded,       # 低下
    phsUnhealthy,      # 不健全
    phsUnknown         # 未知

  ProxyPerformanceMetrics* = ref object
    proxyId*: string             # プロキシID
    lastChecked*: DateTime       # 最後にチェックした時刻
    availability*: float         # 可用性 (0.0-1.0)
    successRate*: float          # 成功率 (0.0-1.0)
    avgLatency*: int             # 平均レイテンシ (ミリ秒)
    minLatency*: int             # 最小レイテンシ (ミリ秒)
    maxLatency*: int             # 最大レイテンシ (ミリ秒)
    requestCount*: int           # リクエスト総数
    successCount*: int           # 成功したリクエスト数
    failureCount*: int           # 失敗したリクエスト数
    consecutiveFailures*: int    # 連続失敗数
    consecutiveSuccesses*: int   # 連続成功数
    healthStatus*: ProxyHealthStatus  # 健康状態
    lastError*: string           # 最後のエラー
    isBlacklisted*: bool         # ブラックリストに載っているか
    blacklistedUntil*: Option[DateTime]  # ブラックリスト期限

  ProxyMonitorConfig* = ref object
    enabled*: bool               # モニタリングが有効かどうか
    checkInterval*: int          # ヘルスチェック間隔（秒）
    testUrls*: seq[string]       # テスト用のURL
    healthyThreshold*: float     # 健全とみなすしきい値 (0.0-1.0)
    degradedThreshold*: float    # 低下とみなすしきい値 (0.0-1.0)
    blacklistThreshold*: int     # ブラックリスト化のしきい値（連続失敗数）
    blacklistDuration*: int      # ブラックリスト期間（秒）
    latencyWeight*: float        # レイテンシの重み
    successRateWeight*: float    # 成功率の重み
    availabilityWeight*: float   # 可用性の重み
    timeoutMs*: int              # チェックタイムアウト（ミリ秒）
    logPerformanceData*: bool    # パフォーマンスデータをログに記録するか

  ProxyMonitor* = ref object
    config*: ProxyMonitorConfig  # モニタリング設定
    metrics*: Table[string, ProxyPerformanceMetrics]  # メトリクス
    logger*: Logger              # ロガー
    lastCheckTime*: DateTime     # 最後のチェック時刻
    isChecking*: bool            # チェック中かどうか

const
  DefaultCheckInterval* = 300     # 5分
  DefaultHealthyThreshold* = 0.8  # 80%
  DefaultDegradedThreshold* = 0.5 # 50%
  DefaultBlacklistThreshold* = 5  # 5回連続失敗
  DefaultBlacklistDuration* = 600 # 10分
  DefaultLatencyWeight* = 0.3
  DefaultSuccessRateWeight* = 0.5
  DefaultAvailabilityWeight* = 0.2
  DefaultTimeout* = 10000        # 10秒
  DefaultTestUrls* = @[
    "http://www.example.com",
    "http://www.google.com",
    "http://www.microsoft.com"
  ]

proc newProxyMonitorConfig*(
  enabled: bool = true,
  checkInterval: int = DefaultCheckInterval,
  testUrls: seq[string] = DefaultTestUrls,
  healthyThreshold: float = DefaultHealthyThreshold,
  degradedThreshold: float = DefaultDegradedThreshold,
  blacklistThreshold: int = DefaultBlacklistThreshold,
  blacklistDuration: int = DefaultBlacklistDuration,
  latencyWeight: float = DefaultLatencyWeight,
  successRateWeight: float = DefaultSuccessRateWeight,
  availabilityWeight: float = DefaultAvailabilityWeight,
  timeoutMs: int = DefaultTimeout,
  logPerformanceData: bool = false
): ProxyMonitorConfig =
  ## 新しいプロキシモニタリング設定を作成します
  result = ProxyMonitorConfig(
    enabled: enabled,
    checkInterval: checkInterval,
    testUrls: testUrls,
    healthyThreshold: healthyThreshold,
    degradedThreshold: degradedThreshold,
    blacklistThreshold: blacklistThreshold,
    blacklistDuration: blacklistDuration,
    latencyWeight: latencyWeight,
    successRateWeight: successRateWeight,
    availabilityWeight: availabilityWeight,
    timeoutMs: timeoutMs,
    logPerformanceData: logPerformanceData
  )

proc newProxyMonitor*(config: ProxyMonitorConfig = nil, logger: Logger = nil): ProxyMonitor =
  ## 新しいプロキシモニターを作成します
  let actualConfig = if config.isNil: newProxyMonitorConfig() else: config
  let actualLogger = if logger.isNil: newConsoleLogger() else: logger
  
  result = ProxyMonitor(
    config: actualConfig,
    metrics: initTable[string, ProxyPerformanceMetrics](),
    logger: actualLogger,
    lastCheckTime: now(),
    isChecking: false
  )

proc generateProxyId*(httpSettings: Option[HttpProxySettings], socksSettings: Option[SocksProxySettings]): string =
  ## プロキシIDを生成します
  if httpSettings.isSome:
    let http = httpSettings.get
    result = "http://" & http.host & ":" & $http.port
    if http.username.len > 0:
      result = http.username & "@" & result
  elif socksSettings.isSome:
    let socks = socksSettings.get
    result = "socks" & $socks.version & "://" & socks.host & ":" & $socks.port
    if socks.username.len > 0:
      result = socks.username & "@" & result
  else:
    result = "direct"

proc calculateHealthStatus(metrics: ProxyPerformanceMetrics, config: ProxyMonitorConfig): ProxyHealthStatus =
  ## メトリクスに基づいて健康状態を計算します
  if metrics.isBlacklisted:
    return phsUnhealthy
  
  let score = metrics.successRate * config.successRateWeight +
              metrics.availability * config.availabilityWeight +
              (1.0 - min(1.0, float(metrics.avgLatency) / 1000.0)) * config.latencyWeight
  
  if score >= config.healthyThreshold:
    result = phsHealthy
  elif score >= config.degradedThreshold:
    result = phsDegraded
  else:
    result = phsUnhealthy

proc initMetrics*(proxyId: string): ProxyPerformanceMetrics =
  ## 新しいパフォーマンスメトリクスを初期化します
  result = ProxyPerformanceMetrics(
    proxyId: proxyId,
    lastChecked: now(),
    availability: 1.0,
    successRate: 1.0,
    avgLatency: 0,
    minLatency: high(int),
    maxLatency: 0,
    requestCount: 0,
    successCount: 0,
    failureCount: 0,
    consecutiveFailures: 0,
    consecutiveSuccesses: 0,
    healthStatus: phsUnknown,
    lastError: "",
    isBlacklisted: false,
    blacklistedUntil: none(DateTime)
  )

proc registerProxy*(monitor: ProxyMonitor, 
                  httpSettings: Option[HttpProxySettings] = none(HttpProxySettings),
                  socksSettings: Option[SocksProxySettings] = none(SocksProxySettings)): string =
  ## プロキシをモニタリングシステムに登録します
  let proxyId = generateProxyId(httpSettings, socksSettings)
  
  if not monitor.metrics.hasKey(proxyId):
    let metrics = initMetrics(proxyId)
    monitor.metrics[proxyId] = metrics
    monitor.logger.log(lvlInfo, "プロキシを登録しました: " & proxyId)
  
  return proxyId

proc unregisterProxy*(monitor: ProxyMonitor, proxyId: string): bool =
  ## プロキシの登録を解除します
  if monitor.metrics.hasKey(proxyId):
    monitor.metrics.del(proxyId)
    monitor.logger.log(lvlInfo, "プロキシの登録を解除しました: " & proxyId)
    return true
  
  return false

proc getProxyMetrics*(monitor: ProxyMonitor, proxyId: string): Option[ProxyPerformanceMetrics] =
  ## プロキシのパフォーマンスメトリクスを取得します
  if monitor.metrics.hasKey(proxyId):
    return some(monitor.metrics[proxyId])
  
  return none(ProxyPerformanceMetrics)

proc isProxyHealthy*(monitor: ProxyMonitor, proxyId: string): bool =
  ## プロキシが健全かどうかをチェックします
  if monitor.metrics.hasKey(proxyId):
    let metrics = monitor.metrics[proxyId]
    return metrics.healthStatus == phsHealthy
  
  return false

proc isProxyBlacklisted*(monitor: ProxyMonitor, proxyId: string): bool =
  ## プロキシがブラックリストに載っているかチェックします
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let metrics = monitor.metrics[proxyId]
  if not metrics.isBlacklisted:
    return false
  
  # ブラックリスト期限をチェック
  if metrics.blacklistedUntil.isSome:
    let currentTime = now()
    if currentTime > metrics.blacklistedUntil.get:
      # ブラックリスト期限切れ
      metrics.isBlacklisted = false
      metrics.blacklistedUntil = none(DateTime)
      return false
  
  return true

proc getHealthyProxies*(monitor: ProxyMonitor): seq[string] =
  ## 健全なプロキシのリストを取得します
  result = @[]
  
  for proxyId, metrics in monitor.metrics:
    if metrics.healthStatus == phsHealthy and not metrics.isBlacklisted:
      result.add(proxyId)

proc getDegradedProxies*(monitor: ProxyMonitor): seq[string] =
  ## 低下したプロキシのリストを取得します
  result = @[]
  
  for proxyId, metrics in monitor.metrics:
    if metrics.healthStatus == phsDegraded and not metrics.isBlacklisted:
      result.add(proxyId)

proc getUnhealthyProxies*(monitor: ProxyMonitor): seq[string] =
  ## 不健全なプロキシのリストを取得します
  result = @[]
  
  for proxyId, metrics in monitor.metrics:
    if metrics.healthStatus == phsUnhealthy or metrics.isBlacklisted:
      result.add(proxyId)

proc blacklistProxy*(monitor: ProxyMonitor, proxyId: string, durationSec: int = -1): bool =
  ## プロキシをブラックリストに追加します
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let metrics = monitor.metrics[proxyId]
  metrics.isBlacklisted = true
  
  let duration = if durationSec > 0: durationSec else: monitor.config.blacklistDuration
  let currentTime = now()
  metrics.blacklistedUntil = some(currentTime + initTimeInterval(seconds = duration))
  
  monitor.logger.log(lvlInfo, "プロキシをブラックリストに追加しました: " & proxyId & 
                      " (" & $duration & "秒間)")
  return true

proc whitelistProxy*(monitor: ProxyMonitor, proxyId: string): bool =
  ## プロキシをブラックリストから削除します
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let metrics = monitor.metrics[proxyId]
  if not metrics.isBlacklisted:
    return false
  
  metrics.isBlacklisted = false
  metrics.blacklistedUntil = none(DateTime)
  metrics.consecutiveFailures = 0
  
  monitor.logger.log(lvlInfo, "プロキシをブラックリストから削除しました: " & proxyId)
  return true

proc recordProxyResult*(monitor: ProxyMonitor, proxyId: string, 
                      success: bool, latencyMs: int, errorMsg: string = ""): bool =
  ## プロキシリクエストの結果を記録します
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let metrics = monitor.metrics[proxyId]
  metrics.lastChecked = now()
  metrics.requestCount += 1
  
  if success:
    metrics.successCount += 1
    metrics.consecutiveSuccesses += 1
    metrics.consecutiveFailures = 0
    
    # レイテンシの更新
    if latencyMs > 0:
      if metrics.avgLatency == 0:
        metrics.avgLatency = latencyMs
      else:
        # 指数移動平均
        metrics.avgLatency = (metrics.avgLatency * 3 + latencyMs) div 4
      
      if latencyMs < metrics.minLatency:
        metrics.minLatency = latencyMs
      
      if latencyMs > metrics.maxLatency:
        metrics.maxLatency = latencyMs
  else:
    metrics.failureCount += 1
    metrics.consecutiveFailures += 1
    metrics.consecutiveSuccesses = 0
    metrics.lastError = errorMsg
    
    # 連続失敗がしきい値を超えた場合はブラックリスト
    if metrics.consecutiveFailures >= monitor.config.blacklistThreshold:
      monitor.blacklistProxy(proxyId)
  
  # 成功率と可用性の更新
  metrics.successRate = float(metrics.successCount) / float(metrics.requestCount)
  metrics.availability = 1.0 - float(metrics.consecutiveFailures) / 
                        float(max(monitor.config.blacklistThreshold, 10))
  
  # 健康状態の更新
  metrics.healthStatus = calculateHealthStatus(metrics, monitor.config)
  
  if monitor.config.logPerformanceData:
    monitor.logger.log(lvlDebug, "プロキシパフォーマンス更新: " & proxyId & 
                      " - 成功: " & $success & 
                      ", レイテンシ: " & $latencyMs & "ms" & 
                      ", 健康状態: " & $metrics.healthStatus & 
                      ", 成功率: " & $(metrics.successRate * 100) & "%")
  
  return true

proc selectBestProxy*(monitor: ProxyMonitor, candidates: seq[string] = @[]): Option[string] =
  ## 最適なプロキシを選択します
  var eligibleProxies: seq[tuple[id: string, score: float]] = @[]
  let candidateSet = if candidates.len > 0: candidates.toHashSet else: monitor.getHealthyProxies().toHashSet
  
  if candidateSet.len == 0:
    # 健全なプロキシがない場合は低下したプロキシも対象にする
    let degraded = monitor.getDegradedProxies()
    for proxyId in degraded:
      if candidates.len == 0 or proxyId in candidateSet:
        if not monitor.isProxyBlacklisted(proxyId):
          eligibleProxies.add((proxyId, 0.5))  # 低下したプロキシには低いスコアを付ける
  else:
    # 健全なプロキシのスコアを計算
    for proxyId in candidateSet:
      if monitor.metrics.hasKey(proxyId) and not monitor.isProxyBlacklisted(proxyId):
        let metrics = monitor.metrics[proxyId]
        if metrics.healthStatus in {phsHealthy, phsDegraded}:
          # スコア計算 - 高いほど良い
          let latencyScore = max(0.0, 1.0 - min(1.0, float(metrics.avgLatency) / 1000.0))
          let score = metrics.successRate * monitor.config.successRateWeight +
                      metrics.availability * monitor.config.availabilityWeight +
                      latencyScore * monitor.config.latencyWeight
          
          eligibleProxies.add((proxyId, score))
  
  if eligibleProxies.len == 0:
    return none(string)
  
  # スコアでソート（高いほど良い）
  eligibleProxies.sort(proc (x, y: tuple[id: string, score: float]): int =
    if x.score > y.score: -1
    elif x.score < y.score: 1
    else: 0
  )
  
  # 上位の候補からランダムに選択 (加重確率で)
  if eligibleProxies.len == 1:
    return some(eligibleProxies[0].id)
  else:
    var totalWeight = 0.0
    for proxy in eligibleProxies:
      totalWeight += proxy.score
    
    var targetWeight = rand(0.0..totalWeight)
    var currentWeight = 0.0
    
    for proxy in eligibleProxies:
      currentWeight += proxy.score
      if currentWeight >= targetWeight:
        return some(proxy.id)
    
    # フォールバック
    return some(eligibleProxies[0].id)

proc testHttpProxy(httpSettings: HttpProxySettings, testUrl: string, timeoutMs: int): tuple[success: bool, latencyMs: int, error: string] {.async.} =
  ## HTTPプロキシをテストします
  var startTime = epochTime() * 1000
  var client: HttpProxyClient
  
  try:
    # HTTPプロキシクライアントを作成
    client = newHttpProxyClient(
      host = httpSettings.host,
      port = httpSettings.port,
      username = httpSettings.username,
      password = httpSettings.password,
      authScheme = httpSettings.authScheme,
      connectionMode = httpSettings.connectionMode,
      timeoutMs = timeoutMs
    )
    
    # プロキシに接続
    await client.connect()
    
    # テストURLにHTTPリクエストを送信
    let uri = parseUri(testUrl)
    let isHttps = uri.scheme == "https"
    
    if isHttps:
      await client.establishTunnel(uri.hostname, if uri.port == "": 443 else: parseInt(uri.port))
    
    let response = await client.request(
      httpMethod = HttpGet,
      url = uri.path,
      hostname = uri.hostname,
      port = if uri.port == "": (if isHttps: 443 else: 80) else: parseInt(uri.port),
      headers = @[("Host", uri.hostname)]
    )
    
    # ステータスコードが200-299の範囲かチェック
    let success = response.status >= 200 and response.status < 300
    let endTime = epochTime() * 1000
    let latency = int(endTime - startTime)
    
    if not success:
      return (false, latency, "HTTPステータスコード: " & $response.status)
    
    return (true, latency, "")
  except:
    let endTime = epochTime() * 1000
    let latency = int(endTime - startTime)
    return (false, latency, getCurrentExceptionMsg())
  finally:
    if not client.isNil:
      await client.disconnect()

proc testSocksProxy(socksSettings: SocksProxySettings, testUrl: string, timeoutMs: int): tuple[success: bool, latencyMs: int, error: string] {.async.} =
  ## SOCKSプロキシをテストします
  var startTime = epochTime() * 1000
  var client: SocksProxyClient
  
  try:
    # SOCKSプロキシクライアントを作成
    client = newSocksProxyClient(
      host = socksSettings.host,
      port = socksSettings.port,
      username = socksSettings.username,
      password = socksSettings.password,
      version = socksSettings.version,
      timeoutMs = timeoutMs
    )
    
    # プロキシに接続
    await client.connect()
    
    # テストURLにHTTPリクエストを送信
    let uri = parseUri(testUrl)
    let targetHost = uri.hostname
    let targetPort = if uri.port == "": (if uri.scheme == "https": 443 else: 80) else: parseInt(uri.port)
    
    # SOCKSプロキシを介して接続
    await client.connectToDestination(targetHost, targetPort)
    
    # 基本的なHTTPリクエストを作成
    let httpRequest = "GET " & (if uri.path == "": "/" else: uri.path) & " HTTP/1.1\r\nHost: " & 
                      targetHost & "\r\nConnection: close\r\n\r\n"
    
    # リクエストを送信
    await client.send(httpRequest)
    
    # レスポンスを受信
    let response = await client.receiveAll(4096)
    
    # HTTPステータスを解析
    let statusLine = response.splitLines()[0]
    let success = statusLine.contains("200 OK") or 
                 (statusLine.contains("HTTP/1.") and not statusLine.contains("4") and not statusLine.contains("5"))
    
    let endTime = epochTime() * 1000
    let latency = int(endTime - startTime)
    
    if not success:
      return (false, latency, "HTTPレスポンス: " & statusLine)
    
    return (true, latency, "")
  except:
    let endTime = epochTime() * 1000
    let latency = int(endTime - startTime)
    return (false, latency, getCurrentExceptionMsg())
  finally:
    if not client.isNil:
      await client.disconnect()

proc testProxy*(monitor: ProxyMonitor, proxyId: string): Future[bool] {.async.} =
  ## プロキシを非同期でテストします
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let metrics = monitor.metrics[proxyId]
  var successCount = 0
  var totalLatency = 0
  var lastError = ""
  
  # プロキシタイプを特定
  let isHttp = proxyId.startsWith("http://")
  let isSocks = proxyId.startsWith("socks")
  
  if not isHttp and not isSocks:
    # プロキシタイプが特定できない
    monitor.logger.log(lvlError, "不明なプロキシタイプ: " & proxyId)
    return false
  
  # テストURLを選択 (複数URLをテスト)
  let testUrls = if monitor.config.testUrls.len > 0: 
                  monitor.config.testUrls
                else:
                  DefaultTestUrls
  
  let shuffledUrls = testUrls
  
  var httpSettings: HttpProxySettings
  var socksSettings: SocksProxySettings
  
  # プロキシ設定を作成
  if isHttp:
    var uri = parseUri(proxyId)
    var username = ""
    var password = ""
    
    # ユーザー名とパスワードを抽出
    if "@" in proxyId:
      let parts = proxyId.split('@', 1)
      let auth = parts[0].split(':', 1)
      username = auth[0]
      if auth.len > 1:
        password = auth[1]
      uri = parseUri("http://" & parts[1])
    
    httpSettings = HttpProxySettings(
      host: uri.hostname,
      port: if uri.port == "": 8080 else: parseInt(uri.port),
      username: username,
      password: password,
      authScheme: HttpProxyAuthScheme.hasBasic,
      connectionMode: HttpProxyConnectionMode.hpcmTunnel
    )
  elif isSocks:
    var version = 5  # デフォルトはSOCKS5
    if "4" in proxyId:
      version = 4
    
    var uri = parseUri(proxyId.replace("socks4://", "socks://").replace("socks5://", "socks://"))
    var username = ""
    var password = ""
    
    # ユーザー名とパスワードを抽出
    if "@" in proxyId:
      let parts = proxyId.split('@', 1)
      let auth = parts[0].split(':', 1)
      username = auth[0]
      if auth.len > 1:
        password = auth[1]
      uri = parseUri("socks://" & parts[1])
    
    socksSettings = SocksProxySettings(
      host: uri.hostname,
      port: if uri.port == "": 1080 else: parseInt(uri.port),
      username: username,
      password: password,
      version: version
    )
  
  for testUrl in shuffledUrls:
    var testResult: tuple[success: bool, latencyMs: int, error: string]
    
    if isHttp:
      testResult = await testHttpProxy(httpSettings, testUrl, monitor.config.timeoutMs)
    else:
      testResult = await testSocksProxy(socksSettings, testUrl, monitor.config.timeoutMs)
    
    if testResult.success:
      successCount += 1
      totalLatency += testResult.latencyMs
    else:
      lastError = testResult.error
    
    # 成功または失敗のどちらかが確定したら早期終了
    if successCount > 0 or lastError.len > 0:
      break
  
  let success = successCount > 0
  let avgLatency = if success: totalLatency div successCount else: 0
  
  # 結果を記録
  monitor.recordProxyResult(proxyId, success, avgLatency, lastError)
  
  return success

proc checkAllProxies*(monitor: ProxyMonitor) {.async.} =
  ## すべてのプロキシをチェックします
  if monitor.isChecking or not monitor.config.enabled:
    return
  
  monitor.isChecking = true
  let currentTime = now()
  
  # 最後のチェックからの経過時間をチェック
  let timeSinceLastCheck = currentTime - monitor.lastCheckTime
  if timeSinceLastCheck.inSeconds < monitor.config.checkInterval:
    monitor.isChecking = false
    return
  
  monitor.logger.log(lvlInfo, "すべてのプロキシをチェックしています...")
  
  var futures: seq[Future[bool]] = @[]
  
  # すべてのプロキシを非同期でテスト
  for proxyId in toSeq(monitor.metrics.keys):
    futures.add(monitor.testProxy(proxyId))
  
  # すべてのテストが完了するのを待つ
  if futures.len > 0:
    await all(futures)
  
  monitor.lastCheckTime = now()
  monitor.isChecking = false
  
  monitor.logger.log(lvlInfo, "プロキシチェック完了. 健全: " & $monitor.getHealthyProxies().len & 
                    ", 低下: " & $monitor.getDegradedProxies().len & 
                    ", 不健全: " & $monitor.getUnhealthyProxies().len)

proc getRankedProxies*(monitor: ProxyMonitor): seq[tuple[proxyId: string, score: float, status: ProxyHealthStatus]] =
  ## プロキシをランク付けして返します
  result = @[]
  
  for proxyId, metrics in monitor.metrics:
    if not metrics.isBlacklisted:
      # スコア計算
      let latencyScore = max(0.0, 1.0 - min(1.0, float(metrics.avgLatency) / 1000.0))
      let score = metrics.successRate * monitor.config.successRateWeight +
                  metrics.availability * monitor.config.availabilityWeight +
                  latencyScore * monitor.config.latencyWeight
      
      result.add((proxyId, score, metrics.healthStatus))
  
  # スコア順に並べ替え
  result.sort(proc (x, y: tuple[proxyId: string, score: float, status: ProxyHealthStatus]): int =
    if x.score > y.score: -1
    elif x.score < y.score: 1
    else: 0
  )

proc getPerformanceReport*(monitor: ProxyMonitor): JsonNode =
  ## パフォーマンスレポートを生成します
  var report = %*{
    "timestamp": $now(),
    "totalProxies": monitor.metrics.len,
    "healthyProxies": monitor.getHealthyProxies().len,
    "degradedProxies": monitor.getDegradedProxies().len,
    "unhealthyProxies": monitor.getUnhealthyProxies().len,
    "proxies": []
  }
  
  let rankedProxies = monitor.getRankedProxies()
  
  for proxy in rankedProxies:
    let proxyId = proxy.proxyId
    let metrics = monitor.metrics[proxyId]
    
    let proxyData = %*{
      "id": proxyId,
      "score": proxy.score,
      "status": $metrics.healthStatus,
      "latency": {
        "avg": metrics.avgLatency,
        "min": metrics.minLatency,
        "max": metrics.maxLatency
      },
      "successRate": metrics.successRate,
      "availability": metrics.availability,
      "requestCount": metrics.requestCount,
      "lastChecked": $metrics.lastChecked
    }
    
    if metrics.lastError.len > 0:
      proxyData["lastError"] = %metrics.lastError
    
    report["proxies"].add(proxyData)
  
  return report

proc resetMetrics*(monitor: ProxyMonitor, proxyId: string): bool =
  ## プロキシのメトリクスをリセットします
  if not monitor.metrics.hasKey(proxyId):
    return false
  
  let oldMetrics = monitor.metrics[proxyId]
  let newMetrics = initMetrics(proxyId)
  monitor.metrics[proxyId] = newMetrics
  
  monitor.logger.log(lvlInfo, "プロキシメトリクスをリセットしました: " & proxyId)
  return true

proc scheduleCheck*(monitor: ProxyMonitor) {.async.} =
  ## 定期的なプロキシチェックをスケジュールします
  while monitor.config.enabled:
    await monitor.checkAllProxies()
    await sleepAsync(monitor.config.checkInterval * 1000)

proc startMonitoring*(monitor: ProxyMonitor) =
  ## モニタリングを開始します
  if not monitor.config.enabled:
    monitor.logger.log(lvlInfo, "プロキシモニタリングは無効化されています")
    return
  
  monitor.logger.log(lvlInfo, "プロキシモニタリングを開始しています...")
  discard monitor.scheduleCheck()

proc stopMonitoring*(monitor: ProxyMonitor) =
  ## モニタリングを停止します
  monitor.config.enabled = false
  monitor.logger.log(lvlInfo, "プロキシモニタリングを停止しました")

proc exportMetrics*(monitor: ProxyMonitor, filePath: string): bool =
  ## メトリクスをJSONファイルにエクスポートします
  try:
    let report = monitor.getPerformanceReport()
    writeFile(filePath, $report)
    monitor.logger.log(lvlInfo, "メトリクスをエクスポートしました: " & filePath)
    return true
  except:
    monitor.logger.log(lvlError, "メトリクスのエクスポートに失敗しました: " & getCurrentExceptionMsg())
    return false

proc importMetrics*(monitor: ProxyMonitor, filePath: string): bool =
  ## メトリクスをJSONファイルからインポートします
  if not fileExists(filePath):
    monitor.logger.log(lvlError, "メトリクスファイルが見つかりません: " & filePath)
    return false
  
  try:
    let content = readFile(filePath)
    let json = parseJson(content)
    
    if json.hasKey("proxies") and json["proxies"].kind == JArray:
      for proxyJson in json["proxies"]:
        if proxyJson.hasKey("id"):
          let proxyId = proxyJson["id"].getStr
          
          if not monitor.metrics.hasKey(proxyId):
            monitor.metrics[proxyId] = initMetrics(proxyId)
          
          let metrics = monitor.metrics[proxyId]
          
          if proxyJson.hasKey("latency"):
            let latency = proxyJson["latency"]
            if latency.hasKey("avg"):
              metrics.avgLatency = latency["avg"].getInt
            if latency.hasKey("min"):
              metrics.minLatency = latency["min"].getInt
            if latency.hasKey("max"):
              metrics.maxLatency = latency["max"].getInt
          
          if proxyJson.hasKey("successRate"):
            metrics.successRate = proxyJson["successRate"].getFloat
          
          if proxyJson.hasKey("availability"):
            metrics.availability = proxyJson["availability"].getFloat
          
          if proxyJson.hasKey("requestCount"):
            metrics.requestCount = proxyJson["requestCount"].getInt
          
          if proxyJson.hasKey("status"):
            metrics.healthStatus = parseEnum[ProxyHealthStatus](proxyJson["status"].getStr)
    
    monitor.logger.log(lvlInfo, "メトリクスをインポートしました: " & filePath)
    return true
  except:
    monitor.logger.log(lvlError, "メトリクスのインポートに失敗しました: " & getCurrentExceptionMsg())
    return false 