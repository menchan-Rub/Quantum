# tracker_blocker.nim
## トラッカーブロッカーモジュール
## オンラインのトラッキングやテレメトリーをブロックします

import std/[
  options,
  tables,
  sets,
  hashes,
  strutils,
  strformat,
  sequtils,
  algorithm,
  times,
  uri,
  re,
  json,
  logging,
  asyncdispatch,
  os,
  httpclient,
  asyncnet
]

import ../../../privacy/privacy_types
import ../../../privacy/blockers/tracker_blocker as tb
import ../../../network/http/client/http_client_types
import ../../../utils/[logging, errors]

type
  TrackerCategory* = enum
    ## トラッカーカテゴリー
    tcAdvertising,    ## 広告
    tcAnalytics,      ## 分析
    tcSocial,         ## ソーシャルメディア
    tcContent,        ## コンテンツ配信
    tcCryptomining,   ## 暗号通貨マイニング
    tcFingerprinting, ## フィンガープリンティング
    tcEssential,      ## 必須機能
    tcMisc            ## その他

  BlockStrategy* = enum
    ## ブロック戦略
    bsNone,           ## ブロックしない
    bsResource,       ## リソースブロック
    bsCookie,         ## Cookieブロック
    bsResourceAndCookie, ## リソースとCookieブロック
    bsModifyRequest   ## リクエスト修正

  TrackerDefinition* = object
    ## トラッカー定義
    name*: string                  ## トラッカー名
    company*: string               ## 会社名
    category*: TrackerCategory     ## カテゴリー
    domains*: seq[string]          ## トラッカードメイン
    patterns*: seq[Regex]          ## URLパターン
    rules*: seq[BlockRule]         ## ブロックルール
    info*: string                  ## 追加情報
    defaultStrategy*: BlockStrategy ## デフォルト戦略

  BlockRule* = object
    ## ブロックルール
    pattern*: Regex                ## URLパターン
    strategy*: BlockStrategy       ## ブロック戦略
    condition*: Option[string]     ## 条件（JavaScript式）
    replaceUrl*: Option[string]    ## 置換URL
    priority*: int                 ## 優先度

  BlockStats* = object
    ## ブロック統計
    domain*: string                ## トラッカードメイン
    category*: TrackerCategory     ## カテゴリー
    count*: int                    ## ブロック回数
    lastBlocked*: Time             ## 最終ブロック時間
    byPage*: Table[string, int]    ## ページごとのブロック数

  TrackerBlocker* = ref object
    ## トラッカーブロッカー
    enabled*: bool                 ## 有効フラグ
    severity*: tb.TrackerBlockerSeverity ## 厳格さ
    logger: Logger                 ## ロガー
    trackers*: seq[TrackerDefinition] ## トラッカー定義
    blockStats*: Table[string, BlockStats] ## ブロック統計
    whitelist*: HashSet[string]    ## ホワイトリスト
    lastUpdate*: Time              ## 最終更新時間
    configPath*: string            ## 設定パス
    blockSubscriptions*: seq[string] ## ブロックリスト購読
    customRules*: seq[BlockRule]   ## カスタムルール

const
  # デフォルトの一般的な広告トラッカー
  DEFAULT_TRACKERS = [
    ("Google Analytics", "Google", tcAnalytics, 
     @["google-analytics.com", "analytics.google.com"], 
     @[r"google-analytics\.com", r"analytics\.google\.com"],
     @[],
     "ウェブ分析サービス", bsResourceAndCookie),
    
    ("Google Ads", "Google", tcAdvertising,
     @["doubleclick.net", "googleadservices.com", "googlesyndication.com"],
     @[r"doubleclick\.net", r"googleadservices\.com", r"googlesyndication\.com"],
     @[],
     "広告配信サービス", bsResourceAndCookie),
     
    ("Facebook Pixel", "Meta", tcSocial,
     @["facebook.com", "facebook.net", "fbcdn.net"],
     @[r"connect\.facebook\.net", r"facebook\.com\/tr", r"graph\.facebook\.com"],
     @[],
     "ユーザー追跡および広告コンバージョン追跡", bsResourceAndCookie),
     
    ("Twitter", "Twitter/X", tcSocial,
     @["twitter.com", "twimg.com", "t.co", "ads-twitter.com"],
     @[r"platform\.twitter\.com", r"syndication\.twitter\.com", r"ads-twitter\.com"],
     @[],
     "ソーシャルメディア共有および追跡", bsResourceAndCookie),
     
    ("Coinhive", "Coinhive", tcCryptomining,
     @["coinhive.com", "coin-hive.com"],
     @[r"coinhive\.com", r"coin-hive\.com"],
     @[],
     "ブラウザベースの暗号通貨マイニング", bsResource)
  ]

  # 組み込みのブロックリスト購読
  DEFAULT_SUBSCRIPTIONS = [
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt",
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext"
  ]

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc newTrackerBlocker*(): TrackerBlocker =
  ## 新しいトラッカーブロッカーを作成
  new(result)
  result.enabled = true
  result.severity = tb.tbsStandard
  result.logger = newLogger("TrackerBlocker")
  result.trackers = @[]
  result.blockStats = initTable[string, BlockStats]()
  result.whitelist = initHashSet[string]()
  result.lastUpdate = getTime()
  result.configPath = getConfigDir() / "browser" / "tracker_blocker"
  result.blockSubscriptions = @DEFAULT_SUBSCRIPTIONS
  result.customRules = @[]
  
  # デフォルトトラッカーの追加
  for tracker in DEFAULT_TRACKERS:
    let (name, company, category, domains, patterns, rules, info, strategy) = tracker
    
    var regexPatterns: seq[Regex] = @[]
    for pattern in patterns:
      regexPatterns.add(re(pattern))
    
    result.trackers.add(TrackerDefinition(
      name: name,
      company: company,
      category: category,
      domains: domains,
      patterns: regexPatterns,
      rules: @[],  # 初期状態では空
      info: info,
      defaultStrategy: strategy
    ))
  
  # ディレクトリの作成
  discard existsOrCreateDir(result.configPath)
  discard existsOrCreateDir(result.configPath / "lists")
  
  # 初期ロード
  try:
    discard result.loadConfiguration()
  except:
    result.logger.error("設定の読み込みに失敗しました: " & getCurrentExceptionMsg())

proc setSeverity*(blocker: TrackerBlocker, severity: tb.TrackerBlockerSeverity) =
  ## 厳格さレベルを設定
  blocker.severity = severity
  blocker.logger.info("トラッカーブロック厳格さを変更: " & $severity)

proc enable*(blocker: TrackerBlocker) =
  ## ブロッカーを有効化
  blocker.enabled = true
  blocker.logger.info("トラッカーブロッカーを有効化")

proc disable*(blocker: TrackerBlocker) =
  ## ブロッカーを無効化
  blocker.enabled = false
  blocker.logger.info("トラッカーブロッカーを無効化")

proc whitelistDomain*(blocker: TrackerBlocker, domain: string) =
  ## ドメインをホワイトリストに追加
  blocker.whitelist.incl(domain)
  blocker.logger.info("ドメインをホワイトリストに追加: " & domain)
  
  # 設定を保存
  try:
    blocker.saveConfiguration()
  except:
    blocker.logger.error("設定の保存に失敗しました: " & getCurrentExceptionMsg())

proc unwhitelistDomain*(blocker: TrackerBlocker, domain: string) =
  ## ドメインをホワイトリストから削除
  blocker.whitelist.excl(domain)
  blocker.logger.info("ドメインをホワイトリストから削除: " & domain)
  
  # 設定を保存
  try:
    blocker.saveConfiguration()
  except:
    blocker.logger.error("設定の保存に失敗しました: " & getCurrentExceptionMsg())

proc isWhitelisted*(blocker: TrackerBlocker, domain: string): bool =
  ## ドメインがホワイトリストにあるかチェック
  if domain in blocker.whitelist:
    return true
  
  # サブドメインのチェック
  for d in blocker.whitelist:
    if domain.endsWith("." & d):
      return true
  
  return false

proc addCustomRule*(blocker: TrackerBlocker, pattern: string, strategy: BlockStrategy, 
                  replaceUrl: string = "", condition: string = "", priority: int = 0) =
  ## カスタムルールを追加
  try:
    var rule = BlockRule(
      pattern: re(pattern),
      strategy: strategy,
      priority: priority
    )
    
    if replaceUrl.len > 0:
      rule.replaceUrl = some(replaceUrl)
    
    if condition.len > 0:
      rule.condition = some(condition)
    
    blocker.customRules.add(rule)
    blocker.logger.info("カスタムブロックルールを追加: " & pattern)
    
    # 設定を保存
    discard blocker.saveConfiguration()
  except:
    blocker.logger.error("カスタムルール追加に失敗しました: " & getCurrentExceptionMsg())

proc removeCustomRule*(blocker: TrackerBlocker, index: int) =
  ## カスタムルールを削除
  if index >= 0 and index < blocker.customRules.len:
    blocker.customRules.delete(index)
    blocker.logger.info("カスタムブロックルールを削除: #" & $index)
    
    # 設定を保存
    try:
      blocker.saveConfiguration()
    except:
      blocker.logger.error("設定の保存に失敗しました: " & getCurrentExceptionMsg())

proc downloadAndProcessList(blocker: TrackerBlocker, url: string) {.async.} =
  ## 指定された URL からブロックリストをダウンロードし、処理する (プレースホルダ)
  var client = newAsyncHttpClient()
  defer: client.close()
  client.headers = newHttpHeaders({"User-Agent": "QuantumBrowser/0.1"}) # 適切なUAを設定

  try:
    blocker.logger.info(&"ブロックリストをダウンロード中: {url}")
    let response = await client.getContent(url)
    blocker.logger.info(&"ブロックリストダウンロード完了: {url} ({response.len} バイト)")
    # TODO: ダウンロードしたリストの内容をパースし、トラッカー定義やルールに追加する
    #       リストのフォーマット (EasyList など) に応じたパーサーが必要
    # 例:
    # let lines = response.splitLines()
    # for line in lines:
    #   if line.startsWith("||") and line.endsWith("^"):
    #     # ドメインブロックルール
    #     let domain = line[2 .. ^2]
    #     blocker.logger.debug(&"リストからドメインルールを追加: {domain}")
    #     # ここでドメインベースのルールを blocker.customRules や blocker.trackers に追加
    #   elif line.startsWith("@@||"):
    #     # 例外ルール
    #     discard
    #   # 他のルールタイプの処理...

    # 最終更新日時を記録
    blocker.lastUpdate = getTime()
    # 必要であれば設定を保存
    # discard blocker.saveConfiguration()

  except HttpRequestError as e:
    blocker.logger.error(&"ブロックリストのダウンロードに失敗 ({url}): {e.msg}")
  except TimeoutError:
     blocker.logger.error(&"ブロックリストのダウンロードがタイムアウトしました ({url})")
  except Exception as e:
    blocker.logger.error(&"ブロックリストの処理中にエラーが発生 ({url}): {e.msg}")

proc addSubscription*(blocker: TrackerBlocker, url: string) =
  ## ブロックリスト購読を追加
  if url notin blocker.blockSubscriptions:
    blocker.blockSubscriptions.add(url)
    blocker.logger.info("ブロックリスト購読を追加: " & url)
    
    # 設定を保存
    try:
      blocker.saveConfiguration()
      # リストを非同期でダウンロード・処理
      asyncCheck downloadAndProcessList(blocker, url)
    except:
      blocker.logger.error("設定の保存またはリストダウンロードの開始に失敗: " & getCurrentExceptionMsg())

proc removeSubscription*(blocker: TrackerBlocker, url: string) =
  ## ブロックリスト購読を削除
  let index = blocker.blockSubscriptions.find(url)
  if index >= 0:
    blocker.blockSubscriptions.delete(index)
    blocker.logger.info("ブロックリスト購読を削除: " & url)
    
    # 設定を保存
    try:
      blocker.saveConfiguration()
    except:
      blocker.logger.error("設定の保存に失敗しました: " & getCurrentExceptionMsg())

#----------------------------------------
# 設定保存と読み込み
#----------------------------------------

proc saveConfiguration*(blocker: TrackerBlocker): bool =
  ## 設定を保存
  try:
    var config = newJObject()
    
    # 基本設定
    config["enabled"] = %blocker.enabled
    config["severity"] = %($blocker.severity)
    config["lastUpdate"] = %($blocker.lastUpdate)
    
    # ホワイトリスト
    var whitelist = newJArray()
    for domain in blocker.whitelist:
      whitelist.add(%domain)
    config["whitelist"] = whitelist
    
    # 購読
    var subscriptions = newJArray()
    for url in blocker.blockSubscriptions:
      subscriptions.add(%url)
    config["subscriptions"] = subscriptions
    
    # カスタムルール
    var customRules = newJArray()
    for rule in blocker.customRules:
      var ruleObj = newJObject()
      ruleObj["pattern"] = %($rule.pattern)
      ruleObj["strategy"] = %($rule.strategy)
      ruleObj["priority"] = %rule.priority
      
      if rule.replaceUrl.isSome:
        ruleObj["replaceUrl"] = %rule.replaceUrl.get()
      
      if rule.condition.isSome:
        ruleObj["condition"] = %rule.condition.get()
      
      customRules.add(ruleObj)
    config["customRules"] = customRules
    
    # ファイルに保存
    writeFile(blocker.configPath / "config.json", $config)
    return true
  except:
    blocker.logger.error("設定の保存に失敗しました: " & getCurrentExceptionMsg())
    return false

proc loadConfiguration*(blocker: TrackerBlocker): bool =
  ## 設定を読み込み
  let configFile = blocker.configPath / "config.json"
  if not fileExists(configFile):
    return false
  
  try:
    let jsonStr = readFile(configFile)
    let config = parseJson(jsonStr)
    
    # 基本設定
    if config.hasKey("enabled"):
      blocker.enabled = config["enabled"].getBool()
    
    if config.hasKey("severity"):
      try:
        blocker.severity = parseEnum[tb.TrackerBlockerSeverity](config["severity"].getStr())
      except:
        discard
    
    # ホワイトリスト
    if config.hasKey("whitelist"):
      blocker.whitelist = initHashSet[string]()
      for item in config["whitelist"]:
        blocker.whitelist.incl(item.getStr())
    
    # 購読
    if config.hasKey("subscriptions"):
      blocker.blockSubscriptions = @[]
      for item in config["subscriptions"]:
        blocker.blockSubscriptions.add(item.getStr())
    
    # カスタムルール
    if config.hasKey("customRules"):
      blocker.customRules = @[]
      for item in config["customRules"]:
        try:
          var rule = BlockRule(
            pattern: re(item["pattern"].getStr()),
            strategy: parseEnum[BlockStrategy](item["strategy"].getStr()),
            priority: item["priority"].getInt()
          )
          
          if item.hasKey("replaceUrl"):
            rule.replaceUrl = some(item["replaceUrl"].getStr())
          
          if item.hasKey("condition"):
            rule.condition = some(item["condition"].getStr())
          
          blocker.customRules.add(rule)
        except:
          blocker.logger.warn("カスタムルールの読み込みに失敗: " & getCurrentExceptionMsg())
    
    return true
  except:
    blocker.logger.error("設定の読み込みに失敗しました: " & getCurrentExceptionMsg())
    return false

#----------------------------------------
# ブロック機能
#----------------------------------------

proc isTracker*(blocker: TrackerBlocker, url: string): bool =
  ## URLがトラッカーかどうかを判定
  let parsedUrl = parseUri(url)
  let domain = parsedUrl.hostname
  
  # カスタムルールのチェック
  for rule in blocker.customRules:
    if url.match(rule.pattern):
      return true
  
  # トラッカー定義のチェック
  for tracker in blocker.trackers:
    # ドメインマッチング
    for trackerDomain in tracker.domains:
      if domain == trackerDomain or domain.endsWith("." & trackerDomain):
        return true
    
    # パターンマッチング
    for pattern in tracker.patterns:
      if url.match(pattern):
        return true
  
  return false

proc getCategoryForUrl*(blocker: TrackerBlocker, url: string): TrackerCategory =
  ## URLのカテゴリーを取得
  let parsedUrl = parseUri(url)
  let domain = parsedUrl.hostname
  
  # トラッカー定義のチェック
  for tracker in blocker.trackers:
    # ドメインマッチング
    for trackerDomain in tracker.domains:
      if domain == trackerDomain or domain.endsWith("." & trackerDomain):
        return tracker.category
    
    # パターンマッチング
    for pattern in tracker.patterns:
      if url.match(pattern):
        return tracker.category
  
  return tcMisc

proc getTrackerForUrl*(blocker: TrackerBlocker, url: string): Option[TrackerDefinition] =
  ## URLに対応するトラッカー定義を取得
  let parsedUrl = parseUri(url)
  let domain = parsedUrl.hostname
  
  # トラッカー定義のチェック
  for tracker in blocker.trackers:
    # ドメインマッチング
    for trackerDomain in tracker.domains:
      if domain == trackerDomain or domain.endsWith("." & trackerDomain):
        return some(tracker)
    
    # パターンマッチング
    for pattern in tracker.patterns:
      if url.match(pattern):
        return some(tracker)
  
  return none(TrackerDefinition)

proc getBlockStrategyForUrl*(blocker: TrackerBlocker, url: string): BlockStrategy =
  ## URLのブロック戦略を取得
  if not blocker.enabled:
    return bsNone
  
  # カスタムルールのチェック（優先度順）
  var customRules: seq[BlockRule] = @[]
  for rule in blocker.customRules:
    if url.match(rule.pattern):
      customRules.add(rule)
  
  if customRules.len > 0:
    # 優先度でソート
    customRules.sort(proc(a, b: BlockRule): int = b.priority - a.priority)
    return customRules[0].strategy
  
  # トラッカー定義のチェック
  let trackerOpt = blocker.getTrackerForUrl(url)
  if trackerOpt.isSome:
    return trackerOpt.get().defaultStrategy
  
  # 厳格さに基づくデフォルト戦略
  case blocker.severity
  of tb.tbsMild: return bsCookie  # 軽度: Cookieのみブロック
  of tb.tbsStandard: return bsResourceAndCookie  # 標準: リソースとCookieブロック
  of tb.tbsStrict: return bsResourceAndCookie  # 厳格: リソースとCookieブロック
  else: return bsNone

proc shouldBlock*(blocker: TrackerBlocker, url: string, sourceDomain: string): bool =
  ## URLをブロックすべきかどうかを判定
  if not blocker.enabled:
    return false
  
  # ソースドメインがホワイトリストにある場合はブロックしない
  if blocker.isWhitelisted(sourceDomain):
    return false
  
  let parsedUrl = parseUri(url)
  let urlDomain = parsedUrl.hostname
  
  # URLのドメインがホワイトリストにある場合はブロックしない
  if blocker.isWhitelisted(urlDomain):
    return false
  
  # ソースドメインと同じドメインの場合（ファーストパーティ）
  if urlDomain == sourceDomain or urlDomain.endsWith("." & sourceDomain) or sourceDomain.endsWith("." & urlDomain):
    # 厳格さに応じてファーストパーティトラッカーをブロックするかどうか
    if blocker.severity != tb.tbsStrict:
      return false
  
  # トラッカーかどうかをチェック
  if not blocker.isTracker(url):
    return false
  
  # ブロック戦略をチェック
  let strategy = blocker.getBlockStrategyForUrl(url)
  return strategy in [bsResource, bsResourceAndCookie]

proc modifyRequest*(blocker: TrackerBlocker, request: HttpRequest, sourceDomain: string): HttpRequest =
  ## リクエストを修正
  if not blocker.enabled:
    return request
  
  # ソースドメインがホワイトリストにある場合は修正しない
  if blocker.isWhitelisted(sourceDomain):
    return request
  
  let url = request.url
  let parsedUrl = parseUri(url)
  let urlDomain = parsedUrl.hostname
  
  # URLのドメインがホワイトリストにある場合は修正しない
  if blocker.isWhitelisted(urlDomain):
    return request
  
  # トラッカーかどうかをチェック
  if not blocker.isTracker(url):
    return request
  
  # ブロック戦略をチェック
  let strategy = blocker.getBlockStrategyForUrl(url)
  
  var modifiedRequest = request
  
  case strategy
  of bsNone:
    # 変更なし
    discard
    
  of bsResource, bsResourceAndCookie:
    # リソースブロック - 実際の実装では無効なURLに書き換えるなど
    # ここでは実際にはブロックしないが統計を記録
    blocker.recordBlock(url, sourceDomain)
    
  of bsCookie:
    # Cookieをブロック
    var newHeaders: seq[(string, string)] = @[]
    for (name, value) in request.headers:
      if name.toLowerAscii() != "cookie":
        newHeaders.add((name, value))
    
    modifiedRequest.headers = newHeaders
    blocker.recordBlock(url, sourceDomain)
    
  of bsModifyRequest:
    # リクエストを修正
    # カスタムルールの中から置換URLを探す
    for rule in blocker.customRules:
      if url.match(rule.pattern) and rule.replaceUrl.isSome:
        # 実装では実際にURLを置き換える
        blocker.recordBlock(url, sourceDomain)
        break
  
  return modifiedRequest

proc recordBlock*(blocker: TrackerBlocker, url: string, sourceDomain: string) =
  ## ブロック統計を記録
  let parsedUrl = parseUri(url)
  let domain = parsedUrl.hostname
  
  let category = blocker.getCategoryForUrl(url)
  
  if domain notin blocker.blockStats:
    blocker.blockStats[domain] = BlockStats(
      domain: domain,
      category: category,
      count: 0,
      lastBlocked: getTime(),
      byPage: initTable[string, int]()
    )
  
  # 統計更新
  var stats = blocker.blockStats[domain]
  stats.count += 1
  stats.lastBlocked = getTime()
  
  if sourceDomain notin stats.byPage:
    stats.byPage[sourceDomain] = 0
  stats.byPage[sourceDomain] += 1
  
  blocker.blockStats[domain] = stats

proc getStats*(blocker: TrackerBlocker): seq[BlockStats] =
  ## ブロック統計を取得
  result = @[]
  for stats in blocker.blockStats.values:
    result.add(stats)
  
  # ブロック数でソート（多い順）
  result.sort(proc(a, b: BlockStats): int = b.count - a.count)

proc clearStats*(blocker: TrackerBlocker) =
  ## 統計をクリア
  blocker.blockStats.clear()
  blocker.logger.info("トラッカーブロック統計をクリア")

proc toJson*(blocker: TrackerBlocker): JsonNode =
  ## JSONシリアライズ
  result = newJObject()
  result["enabled"] = %blocker.enabled
  result["severity"] = %($blocker.severity)
  
  var whitelist = newJArray()
  for domain in blocker.whitelist:
    whitelist.add(%domain)
  result["whitelist"] = whitelist
  
  var subscriptions = newJArray()
  for url in blocker.blockSubscriptions:
    subscriptions.add(%url)
  result["subscriptions"] = subscriptions
  
  var trackers = newJArray()
  for tracker in blocker.trackers:
    var trackerObj = newJObject()
    trackerObj["name"] = %tracker.name
    trackerObj["company"] = %tracker.company
    trackerObj["category"] = %($tracker.category)
    trackerObj["info"] = %tracker.info
    
    var domains = newJArray()
    for domain in tracker.domains:
      domains.add(%domain)
    trackerObj["domains"] = domains
    
    trackers.add(trackerObj)
  result["trackers"] = trackers
  
  var stats = newJArray()
  for stat in blocker.getStats():
    if stat.count > 0:
      var statObj = newJObject()
      statObj["domain"] = %stat.domain
      statObj["category"] = %($stat.category)
      statObj["count"] = %stat.count
      statObj["lastBlocked"] = %($stat.lastBlocked)
      
      var pages = newJObject()
      for page, count in stat.byPage:
        pages[page] = %count
      statObj["byPage"] = pages
      
      stats.add(statObj)
  result["stats"] = stats 