## Proxy Load Balancer
## 
## このモジュールはプロキシサーバーの負荷分散と冗長性を提供します。
## 複数のプロキシサーバーを管理し、様々な戦略に基づいて最適なプロキシを選択します。
## 
## 主な機能:
## - 複数のプロキシサーバーの管理
## - ラウンドロビン、最小接続数、応答時間などの負荷分散戦略
## - 障害検出と自動フェイルオーバー
## - プロキシのヘルスチェック
## - 重み付けによるトラフィック分散
## - カスタム選択ポリシーのサポート

import std/[tables, options, strutils, times, random, hashes, strformat, algorithm]
import std/[asyncdispatch, httpcore, net, uri, json, logging]
import ../http/http_proxy_client
import ../http/http_proxy_types
import ../socks/socks_proxy_client
import ../socks/socks_proxy_types
import ../monitor/proxy_monitor

type
  LoadBalancingStrategy* = enum
    lbsRoundRobin,       ## 順番にプロキシを選択
    lbsLeastConnections, ## 最も接続数の少ないプロキシを選択
    lbsFastestResponse,  ## 最も応答時間の速いプロキシを選択
    lbsWeighted,         ## 重み付けに従ってプロキシを選択
    lbsRandom,           ## ランダムにプロキシを選択
    lbsCustom            ## カスタム選択ロジックを使用

  FailoverStrategy* = enum
    fsNextAvailable,     ## 次に利用可能なプロキシに切り替え
    fsRetryThenFailover, ## 再試行後に切り替え
    fsBestPerformance,   ## 最も性能の良いプロキシに切り替え
    fsNoFailover         ## フェイルオーバーなし

  ProxyEntry* = object
    id*: string                           ## プロキシの一意識別子
    httpSettings*: Option[HttpProxySettings]   ## HTTPプロキシ設定
    socksSettings*: Option[SocksProxySettings] ## SOCKSプロキシ設定
    weight*: int                          ## 重み (重み付け戦略で使用)
    maxConnections*: int                  ## 最大接続数
    currentConnections*: int              ## 現在の接続数
    enabled*: bool                        ## プロキシが有効かどうか
    lastUsed*: Time                       ## 最後に使用された時間
    healthCheckUrl*: string               ## ヘルスチェック用URL
    responseTime*: int                    ## 最後のレスポンス時間(ms)
    consecutiveFailures*: int             ## 連続失敗回数
    consecutiveSuccesses*: int            ## 連続成功回数
    lastError*: string                    ## 最後に発生したエラー
    metadata*: Table[string, string]      ## カスタムメタデータ

  LoadBalancerConfig* = object
    strategy*: LoadBalancingStrategy      ## 負荷分散戦略
    failoverStrategy*: FailoverStrategy   ## フェイルオーバー戦略
    healthCheckInterval*: int             ## ヘルスチェック間隔(秒)
    failureThreshold*: int                ## 失敗と判断するしきい値
    successThreshold*: int                ## 復帰と判断するしきい値
    retryAttempts*: int                   ## 再試行回数
    retryDelay*: int                      ## 再試行の遅延(ms)
    drainConnectionsOnDisable*: bool      ## 無効化時に接続をドレインするか
    enableAutomaticFailover*: bool        ## 自動フェイルオーバーを有効にするか
    reservePercentage*: int               ## 予備として確保するプロキシの割合
    monitorConfig*: Option[ProxyMonitorConfig] ## モニタリング構成

  CustomProxySelector* = proc(entries: seq[ProxyEntry]): Option[ProxyEntry]

  ProxyLoadBalancer* = ref object
    config*: LoadBalancerConfig
    proxies*: seq[ProxyEntry]
    lastIndex*: int
    customSelector*: Option[CustomProxySelector]
    monitor*: Option[ProxyMonitor]
    logger*: Logger

# デフォルト設定値
const
  DefaultHealthCheckInterval* = 60  ## デフォルトのヘルスチェック間隔(秒)
  DefaultFailureThreshold* = 3      ## デフォルトの失敗しきい値
  DefaultSuccessThreshold* = 2      ## デフォルトの成功しきい値
  DefaultRetryAttempts* = 2         ## デフォルトの再試行回数
  DefaultRetryDelay* = 1000         ## デフォルトの再試行遅延(ms)
  DefaultReservePercentage* = 20    ## デフォルトの予備プロキシ割合(%)
  DefaultHealthCheckUrl* = "https://www.google.com" ## デフォルトのヘルスチェックURL

proc newLoadBalancerConfig*(
  strategy: LoadBalancingStrategy = lbsRoundRobin,
  failoverStrategy: FailoverStrategy = fsNextAvailable,
  healthCheckInterval: int = DefaultHealthCheckInterval,
  failureThreshold: int = DefaultFailureThreshold,
  successThreshold: int = DefaultSuccessThreshold,
  retryAttempts: int = DefaultRetryAttempts,
  retryDelay: int = DefaultRetryDelay,
  drainConnectionsOnDisable: bool = true,
  enableAutomaticFailover: bool = true,
  reservePercentage: int = DefaultReservePercentage,
  monitorConfig: Option[ProxyMonitorConfig] = none(ProxyMonitorConfig)
): LoadBalancerConfig =
  ## 新しいロードバランサー設定を作成します
  result = LoadBalancerConfig(
    strategy: strategy,
    failoverStrategy: failoverStrategy,
    healthCheckInterval: healthCheckInterval,
    failureThreshold: failureThreshold,
    successThreshold: successThreshold,
    retryAttempts: retryAttempts,
    retryDelay: retryDelay,
    drainConnectionsOnDisable: drainConnectionsOnDisable,
    enableAutomaticFailover: enableAutomaticFailover,
    reservePercentage: reservePercentage,
    monitorConfig: monitorConfig
  )

proc hash*(entry: ProxyEntry): Hash =
  ## ProxyEntryのハッシュ関数
  var h: Hash = 0
  h = h !& hash(entry.id)
  if entry.httpSettings.isSome:
    h = h !& hash(entry.httpSettings.get().url)
  if entry.socksSettings.isSome:
    h = h !& hash(entry.socksSettings.get().url)
  result = !$h

proc generateProxyId(httpSettings: Option[HttpProxySettings] = none(HttpProxySettings), 
                    socksSettings: Option[SocksProxySettings] = none(SocksProxySettings)): string =
  ## プロキシのIDを生成します
  if httpSettings.isSome:
    let settings = httpSettings.get()
    return "http:" & settings.url
  elif socksSettings.isSome:
    let settings = socksSettings.get()
    return "socks:" & settings.url
  else:
    return "proxy:" & $now().toTime().toUnix() & $rand(1000)

proc newProxyEntry*(
  httpSettings: Option[HttpProxySettings] = none(HttpProxySettings),
  socksSettings: Option[SocksProxySettings] = none(SocksProxySettings),
  weight: int = 1,
  maxConnections: int = 100,
  enabled: bool = true,
  healthCheckUrl: string = DefaultHealthCheckUrl
): ProxyEntry =
  ## 新しいプロキシエントリを作成します
  result = ProxyEntry(
    id: generateProxyId(httpSettings, socksSettings),
    httpSettings: httpSettings,
    socksSettings: socksSettings,
    weight: weight,
    maxConnections: maxConnections,
    currentConnections: 0,
    enabled: enabled,
    lastUsed: now().toTime(),
    healthCheckUrl: healthCheckUrl,
    responseTime: 0,
    consecutiveFailures: 0,
    consecutiveSuccesses: 0,
    lastError: "",
    metadata: initTable[string, string]()
  )

proc newProxyLoadBalancer*(config: LoadBalancerConfig): ProxyLoadBalancer =
  ## 新しいプロキシロードバランサーを作成します
  var logger = newConsoleLogger()
  logger.addHandler(newFileLogger("proxy_load_balancer.log"))
  
  result = ProxyLoadBalancer(
    config: config,
    proxies: @[],
    lastIndex: -1,
    customSelector: none(CustomProxySelector),
    logger: logger
  )
  
  # モニターが構成されている場合は初期化
  if config.monitorConfig.isSome:
    result.monitor = some(newProxyMonitor(config.monitorConfig.get()))

proc setCustomSelector*(lb: ProxyLoadBalancer, selector: CustomProxySelector) =
  ## カスタムプロキシセレクターを設定します
  lb.customSelector = some(selector)

proc addProxy*(lb: ProxyLoadBalancer, entry: ProxyEntry): string =
  ## プロキシをロードバランサーに追加します
  lb.proxies.add(entry)
  lb.logger.log(lvlInfo, fmt"プロキシを追加しました: {entry.id}")
  
  # モニターが構成されている場合はプロキシを登録
  if lb.monitor.isSome:
    if entry.httpSettings.isSome:
      lb.monitor.get().registerHttpProxy(entry.id, entry.httpSettings.get())
    elif entry.socksSettings.isSome:
      lb.monitor.get().registerSocksProxy(entry.id, entry.socksSettings.get())
  
  return entry.id

proc addHttpProxy*(lb: ProxyLoadBalancer, settings: HttpProxySettings, 
                  weight: int = 1, maxConnections: int = 100): string =
  ## HTTPプロキシをロードバランサーに追加します
  let entry = newProxyEntry(
    httpSettings = some(settings),
    weight = weight,
    maxConnections = maxConnections
  )
  return lb.addProxy(entry)

proc addSocksProxy*(lb: ProxyLoadBalancer, settings: SocksProxySettings,
                   weight: int = 1, maxConnections: int = 100): string =
  ## SOCKSプロキシをロードバランサーに追加します
  let entry = newProxyEntry(
    socksSettings = some(settings),
    weight = weight,
    maxConnections = maxConnections
  )
  return lb.addProxy(entry)

proc removeProxy*(lb: ProxyLoadBalancer, id: string): bool =
  ## IDに基づいてプロキシを削除します
  var index = -1
  for i, entry in lb.proxies:
    if entry.id == id:
      index = i
      break
  
  if index >= 0:
    # モニターが構成されている場合はプロキシの登録を解除
    if lb.monitor.isSome:
      lb.monitor.get().unregisterProxy(id)
    
    lb.proxies.delete(index)
    lb.logger.log(lvlInfo, fmt"プロキシを削除しました: {id}")
    return true
  
  return false

proc getProxyById*(lb: ProxyLoadBalancer, id: string): Option[ProxyEntry] =
  ## IDに基づいてプロキシを取得します
  for entry in lb.proxies:
    if entry.id == id:
      return some(entry)
  
  return none(ProxyEntry)

proc enableProxy*(lb: ProxyLoadBalancer, id: string): bool =
  ## プロキシを有効にします
  for i in 0..<lb.proxies.len:
    if lb.proxies[i].id == id:
      lb.proxies[i].enabled = true
      lb.proxies[i].consecutiveFailures = 0
      lb.logger.log(lvlInfo, fmt"プロキシを有効化しました: {id}")
      return true
  
  return false

proc disableProxy*(lb: ProxyLoadBalancer, id: string): bool =
  ## プロキシを無効にします
  for i in 0..<lb.proxies.len:
    if lb.proxies[i].id == id:
      lb.proxies[i].enabled = false
      lb.logger.log(lvlInfo, fmt"プロキシを無効化しました: {id}")
      return true
  
  return false

proc getHealthyProxies*(lb: ProxyLoadBalancer): seq[ProxyEntry] =
  ## 健全なプロキシのリストを取得します
  result = @[]
  for entry in lb.proxies:
    if entry.enabled and entry.consecutiveFailures < lb.config.failureThreshold:
      result.add(entry)

proc getEnabledProxies*(lb: ProxyLoadBalancer): seq[ProxyEntry] =
  ## 有効なプロキシのリストを取得します
  result = @[]
  for entry in lb.proxies:
    if entry.enabled:
      result.add(entry)

proc updateProxyMetrics*(lb: ProxyLoadBalancer, id: string, 
                        responseTime: int, success: bool, errorMsg: string = "") =
  ## プロキシのメトリクスを更新します
  for i in 0..<lb.proxies.len:
    if lb.proxies[i].id == id:
      if success:
        inc lb.proxies[i].consecutiveSuccesses
        lb.proxies[i].consecutiveFailures = 0
        lb.proxies[i].responseTime = responseTime
        lb.proxies[i].lastError = ""
        
        # 成功しきい値に達したら自動的に有効化
        if not lb.proxies[i].enabled and 
           lb.proxies[i].consecutiveSuccesses >= lb.config.successThreshold:
          lb.proxies[i].enabled = true
          lb.logger.log(lvlInfo, fmt"プロキシが回復しました: {id}")
      else:
        inc lb.proxies[i].consecutiveFailures
        lb.proxies[i].consecutiveSuccesses = 0
        lb.proxies[i].lastError = errorMsg
        
        # 失敗しきい値に達したら自動的に無効化
        if lb.proxies[i].enabled and 
           lb.proxies[i].consecutiveFailures >= lb.config.failureThreshold and
           lb.config.enableAutomaticFailover:
          lb.proxies[i].enabled = false
          lb.logger.log(lvlWarn, fmt"プロキシが失敗しきい値に達しました: {id}, 原因: {errorMsg}")
      
      break

proc incrementConnections*(lb: ProxyLoadBalancer, id: string): bool =
  ## プロキシの接続数を増やします
  for i in 0..<lb.proxies.len:
    if lb.proxies[i].id == id:
      if lb.proxies[i].currentConnections < lb.proxies[i].maxConnections:
        inc lb.proxies[i].currentConnections
        lb.proxies[i].lastUsed = now().toTime()
        return true
      else:
        lb.logger.log(lvlWarn, fmt"プロキシの最大接続数に達しました: {id}")
        return false
  
  return false

proc decrementConnections*(lb: ProxyLoadBalancer, id: string): bool =
  ## プロキシの接続数を減らします
  for i in 0..<lb.proxies.len:
    if lb.proxies[i].id == id:
      if lb.proxies[i].currentConnections > 0:
        dec lb.proxies[i].currentConnections
        return true
      return false
  
  return false

proc selectProxyRoundRobin(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## ラウンドロビン方式でプロキシを選択します
  let healthyProxies = lb.getHealthyProxies()
  if healthyProxies.len == 0:
    return none(ProxyEntry)
  
  lb.lastIndex = (lb.lastIndex + 1) mod healthyProxies.len
  return some(healthyProxies[lb.lastIndex])

proc selectProxyLeastConnections(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## 最も接続数が少ないプロキシを選択します
  var healthyProxies = lb.getHealthyProxies()
  if healthyProxies.len == 0:
    return none(ProxyEntry)
  
  # 接続数でソート
  healthyProxies.sort(proc(x, y: ProxyEntry): int =
    result = cmp(x.currentConnections, y.currentConnections))
  
  return some(healthyProxies[0])

proc selectProxyFastestResponse(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## 最も応答が速いプロキシを選択します
  var healthyProxies = lb.getHealthyProxies()
  if healthyProxies.len == 0:
    return none(ProxyEntry)
  
  # レスポンス時間でソート
  healthyProxies.sort(proc(x, y: ProxyEntry): int =
    result = cmp(x.responseTime, y.responseTime))
  
  return some(healthyProxies[0])

proc selectProxyWeighted(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## 重み付けに基づいてプロキシを選択します
  let healthyProxies = lb.getHealthyProxies()
  if healthyProxies.len == 0:
    return none(ProxyEntry)
  
  var totalWeight = 0
  for proxy in healthyProxies:
    totalWeight += proxy.weight
  
  if totalWeight <= 0:
    # 重みが有効でない場合はランダムに選択
    return some(healthyProxies[rand(healthyProxies.len - 1)])
  
  let randomWeight = rand(totalWeight - 1)
  var currentWeight = 0
  
  for proxy in healthyProxies:
    currentWeight += proxy.weight
    if randomWeight < currentWeight:
      return some(proxy)
  
  # フォールバック
  return some(healthyProxies[0])

proc selectProxyRandom(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## ランダムにプロキシを選択します
  let healthyProxies = lb.getHealthyProxies()
  if healthyProxies.len == 0:
    return none(ProxyEntry)
  
  return some(healthyProxies[rand(healthyProxies.len - 1)])

proc selectProxy*(lb: ProxyLoadBalancer): Option[ProxyEntry] =
  ## 設定された戦略に基づいてプロキシを選択します
  # カスタムセレクターが設定されている場合はそれを使用
  if lb.customSelector.isSome:
    return lb.customSelector.get()(lb.proxies)
  
  # 戦略に基づいて選択
  case lb.config.strategy
  of lbsRoundRobin:
    return lb.selectProxyRoundRobin()
  of lbsLeastConnections:
    return lb.selectProxyLeastConnections()
  of lbsFastestResponse:
    return lb.selectProxyFastestResponse()
  of lbsWeighted:
    return lb.selectProxyWeighted()
  of lbsRandom:
    return lb.selectProxyRandom()
  of lbsCustom:
    lb.logger.log(lvlError, "カスタム戦略が選択されていますが、セレクターが設定されていません")
    # フォールバックとしてラウンドロビンを使用
    return lb.selectProxyRoundRobin()

proc checkProxyHealth*(lb: ProxyLoadBalancer, id: string): Future[bool] {.async.} =
  ## プロキシのヘルスチェックを実行します
  # プロキシを取得
  let proxyOpt = lb.getProxyById(id)
  if proxyOpt.isNone:
    lb.logger.log(lvlError, fmt"ヘルスチェック: プロキシが見つかりません: {id}")
    return false
  
  let proxy = proxyOpt.get()
  let startTime = epochTime()
  
  try:
    # プロキシの種類に基づいてヘルスチェックを実行
    if proxy.httpSettings.isSome:
      let settings = proxy.httpSettings.get()
      var client = newHttpProxyClient(settings)
      let uri = parseUri(proxy.healthCheckUrl)
      
      # プロキシに接続
      await client.connect()
      # リクエストを送信
      await client.sendRequest(HttpMethod.GET, uri.path, uri.hostname, uri.port)
      # レスポンスを受信
      let resp = await client.receiveResponse()
      # プロキシから切断
      await client.disconnect()
      
      # レスポンスコードをチェック
      let success = resp.code in {Http200..Http308}
      let elapsed = int((epochTime() - startTime) * 1000)
      
      # メトリクスを更新
      lb.updateProxyMetrics(id, elapsed, success, 
                           if not success: fmt"ヘルスチェック失敗: HTTP {resp.code}" else: "")
      
      return success

    elif proxy.socksSettings.isSome:
      let settings = proxy.socksSettings.get()
      var client = newSocksProxyClient(settings)
      let uri = parseUri(proxy.healthCheckUrl)
      
      # プロキシに接続
      await client.connect()
      # リモートホストに接続
      let connected = await client.connectToDestination(uri.hostname, Port(uri.port.parseInt))
      # プロキシから切断
      await client.disconnect()
      
      let elapsed = int((epochTime() - startTime) * 1000)
      
      # メトリクスを更新
      lb.updateProxyMetrics(id, elapsed, connected, 
                           if not connected: "SOCKSプロキシを介した接続に失敗しました" else: "")
      
      return connected
    
    else:
      lb.logger.log(lvlError, fmt"ヘルスチェック: プロキシ設定が見つかりません: {id}")
      return false
    
  except Exception as e:
    let elapsed = int((epochTime() - startTime) * 1000)
    lb.updateProxyMetrics(id, elapsed, false, fmt"ヘルスチェック例外: {e.msg}")
    lb.logger.log(lvlError, fmt"ヘルスチェック例外 for {id}: {e.msg}")
    return false

proc checkAllProxiesHealth*(lb: ProxyLoadBalancer) {.async.} =
  ## すべてのプロキシのヘルスチェックを実行します
  var futures: seq[Future[bool]] = @[]
  
  # すべてのプロキシのヘルスチェックを開始
  for proxy in lb.proxies:
    futures.add(lb.checkProxyHealth(proxy.id))
  
  # すべてのヘルスチェックが完了するのを待つ
  await all(futures)
  lb.logger.log(lvlInfo, "すべてのプロキシのヘルスチェックが完了しました")

proc startHealthChecks*(lb: ProxyLoadBalancer) {.async.} =
  ## 定期的なヘルスチェックを開始します
  while true:
    await lb.checkAllProxiesHealth()
    # 次のチェックまで待機
    await sleepAsync(lb.config.healthCheckInterval * 1000)

proc toJson*(entry: ProxyEntry): JsonNode =
  ## プロキシエントリをJSONに変換します
  result = newJObject()
  result["id"] = %entry.id
  result["weight"] = %entry.weight
  result["maxConnections"] = %entry.maxConnections
  result["currentConnections"] = %entry.currentConnections
  result["enabled"] = %entry.enabled
  result["lastUsed"] = %($entry.lastUsed)
  result["healthCheckUrl"] = %entry.healthCheckUrl
  result["responseTime"] = %entry.responseTime
  result["consecutiveFailures"] = %entry.consecutiveFailures
  result["consecutiveSuccesses"] = %entry.consecutiveSuccesses
  result["lastError"] = %entry.lastError
  
  # HTTPプロキシ設定
  if entry.httpSettings.isSome:
    let settings = entry.httpSettings.get()
    var httpSettings = newJObject()
    httpSettings["url"] = %settings.url
    httpSettings["authUser"] = %settings.authUser
    httpSettings["connectionMode"] = %($settings.connectionMode)
    result["httpSettings"] = httpSettings
  
  # SOCKSプロキシ設定
  if entry.socksSettings.isSome:
    let settings = entry.socksSettings.get()
    var socksSettings = newJObject()
    socksSettings["url"] = %settings.url
    socksSettings["version"] = %($settings.version)
    socksSettings["authUser"] = %settings.authUser
    result["socksSettings"] = socksSettings
  
  # メタデータ
  var metadata = newJObject()
  for key, value in entry.metadata:
    metadata[key] = %value
  result["metadata"] = metadata

proc toJson*(lb: ProxyLoadBalancer): JsonNode =
  ## ロードバランサーをJSONに変換します
  result = newJObject()
  
  # 設定
  var config = newJObject()
  config["strategy"] = %($lb.config.strategy)
  config["failoverStrategy"] = %($lb.config.failoverStrategy)
  config["healthCheckInterval"] = %lb.config.healthCheckInterval
  config["failureThreshold"] = %lb.config.failureThreshold
  config["successThreshold"] = %lb.config.successThreshold
  config["retryAttempts"] = %lb.config.retryAttempts
  config["retryDelay"] = %lb.config.retryDelay
  config["drainConnectionsOnDisable"] = %lb.config.drainConnectionsOnDisable
  config["enableAutomaticFailover"] = %lb.config.enableAutomaticFailover
  config["reservePercentage"] = %lb.config.reservePercentage
  result["config"] = config
  
  # プロキシ
  var proxies = newJArray()
  for proxy in lb.proxies:
    proxies.add(proxy.toJson())
  result["proxies"] = proxies

# エクスポート/インポート機能
proc exportToJson*(lb: ProxyLoadBalancer): string =
  ## ロードバランサーをJSON文字列にエクスポートします
  return $lb.toJson()

proc exportToFile*(lb: ProxyLoadBalancer, filename: string): bool =
  ## ロードバランサーをJSONファイルにエクスポートします
  try:
    let jsonStr = lb.exportToJson()
    writeFile(filename, jsonStr)
    lb.logger.log(lvlInfo, fmt"ロードバランサー設定をエクスポートしました: {filename}")
    return true
  except Exception as e:
    lb.logger.log(lvlError, fmt"ロードバランサー設定のエクスポートに失敗しました: {e.msg}")
    return false 