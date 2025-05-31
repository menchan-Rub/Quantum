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
import ../../../quantum_net/protocols/quic/quic_types
import ../../../quantum_net/protocols/http3/http3_types
import ../../../quantum_arch/data/ml/inference

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
    http3Detector*: InferenceModel ## HTTP/3トラッカー検出モデル
    mdnsMappings*: Table[string, string] ## mDNSマッピング
    onIceCandidateModified*: proc(ip: string, mdnsName: string) ## コールバック関数
    blocklist_path: string
    # last_updated: Time # ブロックリストの最終更新日時など
    lock: Lock # 設定やブロックリストへのアクセスを保護するためのロック
    # 追加: ブロックリスト自体を保持するフィールド
    blocklist_domains: HashSet[string] # ドメインベースのブロックリスト
    blocklist_url_patterns: seq[Regex] # URLパターンベースのブロックリスト (より柔軟)

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

proc newTrackerBlocker*(config_path: string, blocklist_path: string): TrackerBlocker =
  var blocker = TrackerBlocker(
    enabled: false, 
    config_path: config_path, 
    blocklist_path: blocklist_path,
    lock: newLock(),
    logger: newConsoleLogger(lvlThreshold=lvlInfo),
    blocklist_domains: initHashSet[string](),
    blocklist_url_patterns: newSeq[Regex]()
  )
  blocker.loadConfig() # 設定をロード
  blocker.loadBlocklist() # ブロックリストをロード
  return blocker

proc loadConfig*(blocker: var TrackerBlocker) =
  ## 設定を読み込み
  let configFile = blocker.configPath / "config.json"
  if not fileExists(configFile):
    return
  
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

# ブロックリストをダウンロードして処理
proc downloadAndProcessList*(blocker: TrackerBlocker, url: string) {.async.} =
  # HTTPクライアントを作成
  var client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"User-Agent": "QuantumBrowser/0.1"}) # 適切なUAを設定

  try:
    blocker.logger.info(&"ブロックリストをダウンロード中: {url}")
    let response = await client.getContent(url)
    blocker.logger.info(&"ブロックリストダウンロード完了: {url} ({response.len} バイト)")
    
    # リストをパースして処理
    let lines = response.splitLines()
    var rules_added = 0
    var exceptions_added = 0
    
    # EasyList/Adblock Plus形式のパース
    for line in lines:
      # コメントや空行をスキップ
      if line.len == 0 or line.startsWith("!") or line.startsWith("["):
        continue
        
      try:
        if line.startsWith("@@"):
          # 例外ルール (ホワイトリスト)
          let exception_rule = line[2..^1]
          if exception_rule.startsWith("||") and exception_rule.contains("^"):
            # ドメイン例外ルール
            let domain_match = exception_rule.findAll(re"^\|\|([a-z0-9][a-z0-9-_.]+\.[a-z0-9][a-z0-9-_.]+)[\^$]")
            if domain_match.len > 0:
              let domain = domain_match[0].captures[0]
              if domain.len > 0:
                blocker.whitelist.incl(domain)
                exceptions_added += 1
                blocker.logger.debug(&"ホワイトリストドメインを追加: {domain}")
          
        elif line.startsWith("||") and (line.endsWith("^") or line.contains("^")):
          # ドメインブロックルール
          let domain_match = line.findAll(re"^\|\|([a-z0-9][a-z0-9-_.]+\.[a-z0-9][a-z0-9-_.]+)[\^$]")
          if domain_match.len > 0 and domain_match[0].captures.len > 0:
            let domain = domain_match[0].captures[0]
            if domain.len > 0:
              # トラッカーカテゴリを推測
              var category = tcMisc
              if domain.contains("analytics") or domain.contains("track") or domain.contains("stats"):
                category = tcAnalytics
              elif domain.contains("ads") or domain.contains("banner") or domain.contains("sponsor"):
                category = tcAdvertising
              elif domain.contains("facebook") or domain.contains("twitter") or domain.contains("social"):
                category = tcSocial
              elif domain.contains("cdn") or domain.contains("content") or domain.contains("media"):
                category = tcContent
              elif domain.contains("mining") or domain.contains("coin") or domain.contains("crypto"):
                category = tcCryptomining
              elif domain.contains("fingerprint") or domain.contains("browser") or domain.contains("canvas"):
                category = tcFingerprinting
                
              # カスタムルールとして追加
              var pattern = &"^https?://([^/]+\\.)?{domain}/.*"
              let block_rule = BlockRule(
                pattern: re(pattern),
                strategy: bsResourceAndCookie,
                condition: none(string),
                replaceUrl: none(string),
                priority: 10
              )
              
              blocker.customRules.add(block_rule)
              rules_added += 1
              
              # 既存の定義に追加するか、新しい定義を作成
              var found = false
              for i in 0..<blocker.trackers.len:
                if domain in blocker.trackers[i].domains:
                  found = true
                  break
              
              if not found:
                # 新しいトラッカー定義を作成
                var tracker_def = TrackerDefinition(
                  name: domain,
                  company: domain.split('.')[0],
                  category: category,
                  domains: @[domain],
                  patterns: @[re(pattern)],
                  rules: @[block_rule],
                  info: "自動検出されたトラッカー",
                  defaultStrategy: bsResourceAndCookie
                )
                
                blocker.trackers.add(tracker_def)
                blocker.logger.debug(&"新しいトラッカー定義を追加: {domain}")
              
              blocker.logger.debug(&"ブロックルールを追加: {domain} (パターン: {pattern})")
              
        elif line.startsWith("/") and line.endsWith("/") and line.len > 2:
          # 正規表現ルール
          let regex_pattern = line[1..^2]
          try:
            # 正規表現の有効性をチェック
            discard re(regex_pattern)
            
            # カスタムルールとして追加
            let block_rule = BlockRule(
              pattern: re(regex_pattern),
              strategy: bsResourceAndCookie,
              condition: none(string),
              replaceUrl: none(string),
              priority: 5
            )
            
            blocker.customRules.add(block_rule)
            rules_added += 1
            
            blocker.logger.debug(&"正規表現ブロックルールを追加: {regex_pattern}")
          except RegexError:
            blocker.logger.warn(&"無効な正規表現ルールをスキップ: {regex_pattern}")
            
        elif line.contains("##") or line.contains("#@#"):
          # CSSセレクターまたは要素非表示ルール
          # この実装では扱わないためスキップ
          continue
          
        else:
          # その他のシンプルなURLルール
          if line.startsWith("|") or line.startsWith("http"):
            var url_pattern = line
            if url_pattern.startsWith("|"):
              url_pattern = url_pattern[1..^1]
              
            # URLがエスケープされていることを確認
            var escaped_pattern = url_pattern.replace(".", "\\.")
            escaped_pattern = escaped_pattern.replace("?", "\\?")
            escaped_pattern = escaped_pattern.replace("*", ".*")
            
            # カスタムルールとして追加
            try:
              let pattern_re = re(escaped_pattern)
              let block_rule = BlockRule(
                pattern: pattern_re,
                strategy: bsResource,
                condition: none(string),
                replaceUrl: none(string),
                priority: 3
              )
              
              blocker.customRules.add(block_rule)
              rules_added += 1
              
              blocker.logger.debug(&"URLブロックルールを追加: {escaped_pattern}")
            except RegexError:
              blocker.logger.warn(&"無効なURLパターンをスキップ: {escaped_pattern}")
            
      except Exception as e:
        blocker.logger.warn(&"ルール解析エラー: {line} - {e.msg}")
        continue
        
    blocker.logger.info(&"リストの処理が完了: {url} - 追加されたルール: {rules_added}, 例外: {exceptions_added}")

    # 最終更新日時を記録
    blocker.lastUpdate = getTime()
    
    # 設定を保存
    discard blocker.saveConfiguration()

  except HttpRequestError as e:
    blocker.logger.error(&"ブロックリストのダウンロードに失敗 ({url}): {e.msg}")
  except TimeoutError:
     blocker.logger.error(&"ブロックリストのダウンロードがタイムアウトしました ({url})")
  except Exception as e:
    blocker.logger.error(&"ブロックリストの処理中にエラーが発生 ({url}): {e.msg}")
  finally:
    client.close()

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
    
    of bsResource, bsResourceAndCookie:    # リソースをブロック - リクエストを無効なURLに書き換え    const BLOCKED_URL = "about:blank"    modifiedRequest.url = BLOCKED_URL        # ヘッダーを変更して追跡を防止    var newHeaders: seq[(string, string)] = @[]    for (name, value) in request.headers:      if name.toLowerAscii notin ["cookie", "referer", "origin"]:        newHeaders.add((name, value))        # Cache-Controlヘッダーを追加して確実にキャッシュされないようにする    newHeaders.add(("Cache-Control", "no-store, max-age=0"))    modifiedRequest.headers = newHeaders        # ブロック統計を記録    blocker.recordBlock(url, sourceDomain)
    
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

# HTTP/3およびQUIC特有のトラッキング対策機能を追加

# 定数定義を追加
const
  # HTTP/3およびQUIC特有のトラッキングパターン
  HTTP3_TRACKING_PATTERNS = [
    r"quic-fingerprint\.js$",
    r"(http3|h3)-analytics\.",
    r"quic-metrics\.",
    r"h3-tracking\.js$",
    r"\.gif\?(h3|quic)=",
    r"rtt-fingerprint\.js$"
  ]
  
  # HTTP/3およびQUICに特化したブロック戦略
  QUIC_CONNECTION_ID_PROTECTION = true
  QUIC_RESET_MITIGATION = true
  PREVENT_HTTP3_FINGERPRINTING = true
  HTTP3_PRIVACY_HEADERS = {
    "Sec-Fetch-Site": "same-origin",
    "Sec-Fetch-Mode": "no-cors",
    "Sec-Fetch-Dest": "empty",
    "Sec-CH-UA-Platform": "\"Unknown\"",
    "Sec-HTTP3-Privacy": "on"
  }
  
  # サードパーティCookie制限の設定
  COOKIE_ENFORCEMENT_LEVELS = {
    tbsLow: CookieEnforcementLevel(
      blockThirdPartyCookies: false,
      blockHighRiskCookies: true,
      partitionThirdPartyCookies: true,
      expireDays: 30,
      keepTrustedCookies: true
    ),
    tbsStandard: CookieEnforcementLevel(
      blockThirdPartyCookies: true,
      blockHighRiskCookies: true,
      partitionThirdPartyCookies: true,
      expireDays: 7,
      keepTrustedCookies: true
    ),
    tbsStrict: CookieEnforcementLevel(
      blockThirdPartyCookies: true,
      blockHighRiskCookies: true,
      partitionThirdPartyCookies: true,
      expireDays: 1,
      keepTrustedCookies: false
    ),
    tbsAggressive: CookieEnforcementLevel(
      blockThirdPartyCookies: true,
      blockHighRiskCookies: true,
      partitionThirdPartyCookies: true,
      expireDays: 0,  # セッションのみ
      keepTrustedCookies: false
    )
  }

# 新しい型定義
type
  # QUIC特有のプライバシーオプション
  QUICPrivacyOption* = enum
    qpoMaskConnectionIds,       # 接続IDをランダム化
    qpoPreventResets,           # リセットベースのフィンガープリントを防止
    qpoRotateTransportParams,   # トランスポートパラメータをローテーション
    qpoStrictVersion,           # バージョンを厳格に制限
    qpoDisableTokens,           # リプレイ攻撃対策トークンを無効化
    qpoBlockPaddingLeaks,       # パディング漏洩をブロック
    qpoSecureSNI,               # SNI情報保護
    qpoHideTiming              # タイミング情報を隠す

  # HTTP/3特有のトラッキング検出結果
  HTTP3TrackingDetection* = object
    isTracker*: bool            # トラッカーと判定されたか
    confidence*: float           # 信頼度（0.0-1.0）
    method*: string              # 検出方法（"pattern", "ml", "heuristic"）
    category*: TrackerCategory   # トラッカーカテゴリ
    patterns*: seq[string]       # 一致したパターン
    fingerprinting*: bool        # フィンガープリント試行を検出したか
    quicSpecific*: bool          # QUIC特有の手法か
    recommendedAction*: BlockStrategy # 推奨されるブロック戦略

  # QUICプライバシー設定
  QUICPrivacySettings* = object
    enabled*: set[QUICPrivacyOption]  # 有効なプライバシーオプション
    connectionIdSalt*: string         # 接続ID生成用のソルト
    paddingStrategy*: int             # パディング戦略（0-3）
    rotationInterval*: int            # ローテーション間隔（秒）
    fingerprintResistance*: int       # フィンガープリント耐性レベル（0-3）

  # Cookie制限レベル設定
  CookieEnforcementLevel* = object
    blockThirdPartyCookies*: bool     # サードパーティCookieをブロック
    blockHighRiskCookies*: bool       # 高リスクCookieをブロック
    partitionThirdPartyCookies*: bool # サードパーティCookieをパーティション
    expireDays*: int                  # Cookie有効期限制限（日数、0=セッションのみ）
    keepTrustedCookies*: bool         # 信頼済みサイトのCookieを保持

  # Cookieアクセス決定
  CookieAccessDecision* = enum
    cadAllow,        # 許可
    cadBlock,        # ブロック
    cadPartition,    # パーティション化して許可
    cadModify,       # 修正して許可
    cadSession       # セッションCookieとして許可

  # アクセスコンテキスト
  CookieContext* = object
    topLevelDomain*: string           # トップレベルドメイン
    requestDomain*: string            # リクエスト先ドメイン
    isThirdParty*: bool               # サードパーティか
    cookieName*: string               # Cookie名
    cookieValue*: string              # Cookie値
    isSecure*: bool                   # Secureフラグ
    isHttpOnly*: bool                 # HttpOnlyフラグ
    sameSite*: string                 # SameSite設定
    expires*: Time                    # 有効期限
    path*: string                     # パス
    isTracking*: bool                 # トラッキングCookieか

# TrackerBlocker型に新しいフィールドを追加
# 既存のTrackerBlocker型を上書きしないよう、新しいフィールドのみを示す
proc initializeHTTP3Protection*(blocker: TrackerBlocker) =
  # HTTP/3特有のトラッキングパターン追加
  var http3Patterns: seq[Regex] = @[]
  for pattern in HTTP3_TRACKING_PATTERNS:
    try:
      http3Patterns.add(re(pattern))
    except:
      blocker.logger.error("HTTP/3パターンのコンパイルに失敗: " & pattern)
  
  # HTTP/3プライバシー設定
  var http3PrivacySettings = QUICPrivacySettings(
    enabled: {qpoMaskConnectionIds, qpoPreventResets, qpoRotateTransportParams, 
              qpoSecureSNI, qpoHideTiming},
    connectionIdSalt: generateRandomString(16),
    paddingStrategy: 2, # 中間レベルのパディング
    rotationInterval: 300, # 5分ごとにローテーション
    fingerprintResistance: 2 # 中間レベルの耐性
  )
  
    # ML検出モデルの初期化  var http3MLDetector = new(InferenceModel)    # モデルパラメータの設定  http3MLDetector.modelType = ModelType.mtXGBoost  http3MLDetector.threshold = 0.70  # 70%以上の確信度でトラッカーと判断    # 特徴量名を設定  http3MLDetector.featureNames = @[    "url_contains_tracking_params", "url_entropy", "url_length",    "is_third_party", "has_tracking_headers", "domain_reputation",    "content_type", "response_size", "connection_type",    "has_fingerprinting_apis"  ]    # 特徴量の重要度を設定  var importance = initTable[string, float]()  importance["url_contains_tracking_params"] = 0.95  importance["is_third_party"] = 0.90  importance["has_tracking_headers"] = 0.85  importance["domain_reputation"] = 0.80  importance["has_fingerprinting_apis"] = 0.75  importance["url_entropy"] = 0.70  importance["content_type"] = 0.65  importance["url_length"] = 0.60  importance["response_size"] = 0.50  importance["connection_type"] = 0.45  http3MLDetector.featureImportance = importance
  
  # モデル設定
  let modelDir = getAppDir() / "models" / "privacy"
  let modelPath = modelDir / "tracker_detector_xgb.model"
  
  # ディレクトリが存在することを確認
  discard existsOrCreateDir(modelDir)
  
  # モデルをロード（存在する場合）またはトレーニング
  if fileExists(modelPath):
    try:
      blocker.logger.info("HTTP/3トラッカー検出MLモデルをロードしました: " & modelPath)
      http3MLDetector.loadModel(modelPath)
    except:
      blocker.logger.error("モデルロードエラー: " & getCurrentExceptionMsg())
      # 失敗した場合はデフォルトモデルを作成
      blocker.trainFallbackModel()
  else:
    blocker.logger.info("トラッカー検出モデルが見つかりません、トレーニングを実行")
    blocker.trainFallbackModel()
  
  # モデルを設定
  if http3MLDetector.isLoaded:
    blocker.http3Detector = http3MLDetector
  
  # HTTP/3トラッカー定義の追加
  let http3Trackers = [
    ("HTTP/3 Analytics Tracker", "Various", tcAnalytics, 
     @["h3-analytics.com", "quicmetrics.com", "http3stats.net"], 
     http3Patterns,
     @[],
     "HTTP/3接続を用いた高精度分析トラッカー", bsResourceAndCookie),
    
    ("QUIC Fingerprinting", "Various", tcFingerprinting,
     @["quicfingerprint.com", "deviceprofile-quic.com"], 
     @[],
     @[],
     "QUICトランスポートパラメータを使用したデバイス識別", bsResourceAndCookie)
  ]
  
  # トラッカー定義を追加
  for tracker in http3Trackers:
    let (name, company, category, domains, patterns, rules, info, strategy) = tracker
    
    blocker.trackers.add(TrackerDefinition(
      name: name,
      company: company,
      category: category,
      domains: domains,
      patterns: patterns,
      rules: @[],
      info: info,
      defaultStrategy: strategy
    ))
  
  blocker.logger.info("HTTP/3およびQUIC保護機能を初期化しました")

# HTTP/3特有のトラッキングを検出
proc detectHTTP3Tracking*(blocker: TrackerBlocker, url: string, 
                        headers: seq[(string, string)] = @[]): HTTP3TrackingDetection =
  # 初期結果
  result = HTTP3TrackingDetection(
    isTracker: false,
    confidence: 0.0,
    method: "unknown",
    category: tcMisc,
    patterns: @[],
    fingerprinting: false,
    quicSpecific: false,
    recommendedAction: bsNone
  )
  
  # URLのパターンマッチング
  for pattern in HTTP3_TRACKING_PATTERNS:
    try:
      let regex = re(pattern)
      if url.match(regex):
        result.isTracker = true
        result.patterns.add(pattern)
        result.method = "pattern"
        result.confidence += 0.2
        if pattern.contains("fingerprint"):
          result.fingerprinting = true
        if pattern.contains("quic") or pattern.contains("h3"):
          result.quicSpecific = true
    except:
      continue
  
  # ヘッダー分析
  for (name, value) in headers:
    # QUIC特有のフィンガープリント試行を検出
    if name.toLowerAscii.contains("quic") or 
       name.toLowerAscii.contains("http3") or
       value.contains("quic-fp"):
      result.isTracker = true
      result.patterns.add("header:" & name)
      result.method = "header"
      result.confidence += 0.3
      result.quicSpecific = true
      
    # リクエストIDチェーン（トラッキング手法）
    if name.toLowerAscii == "x-request-id" or
       name.toLowerAscii == "request-context":
      result.patterns.add("tracking-id:" & name)
      result.confidence += 0.1
  
  # 機械学習モデルによる判定
  if blocker.http3Detector != nil and blocker.http3Detector.isLoaded:
    try:
      # 特徴量の抽出
      var features = newSeq[float32](10)
      
      # URL特徴量
      features[0] = if url.contains("analytics"): 1.0 else: 0.0
      features[1] = if url.contains("track"): 1.0 else: 0.0
      features[2] = if url.contains("fingerprint"): 1.0 else: 0.0
      features[3] = if url.contains("quic") or url.contains("h3"): 1.0 else: 0.0
      
      # ヘッダー特徴量
      var quicHeaderCount = 0
      var trackingIdCount = 0
      var thirdPartyHeader = false
      var userInfoHeader = false
      
      for (name, value) in headers:
        if name.toLowerAscii.contains("quic") or name.toLowerAscii.contains("http3"):
          quicHeaderCount += 1
        if name.toLowerAscii.contains("id") or name.toLowerAscii.contains("tracking"):
          trackingIdCount += 1
        if name.toLowerAscii.contains("referer"):
          # ドメインが異なる場合はサードパーティフラグを立てる
          let refererDomain = extractDomain(value)
          let urlDomain = extractDomain(url)
          if refererDomain != urlDomain and refererDomain.len > 0:
            thirdPartyHeader = true
        if name.toLowerAscii.contains("device") or 
           name.toLowerAscii.contains("user") or 
           name.toLowerAscii.contains("client"):
          userInfoHeader = true
      
      features[4] = float32(quicHeaderCount)
      features[5] = float32(trackingIdCount)
      features[6] = if thirdPartyHeader: 1.0 else: 0.0
      features[7] = if userInfoHeader: 1.0 else: 0.0
      
      # パターンマッチ結果
      features[8] = if result.patterns.len > 0: 1.0 else: 0.0
      features[9] = result.confidence
      
      # モデル推論実行
      let prediction = blocker.http3Detector.predict(features)
      
      if prediction.len == 4:
        let mlProbability = prediction[0]
        let fingerprintProb = prediction[1]
        let analyticsProb = prediction[2]
        let adProb = prediction[3]
        
        # 結果の信頼度を更新
        if mlProbability > 0.7:
          result.confidence = max(result.confidence, mlProbability)
          result.isTracker = true
          result.method = "ml-model"
          result.patterns.add("ml-detection")
          
          # カテゴリを判断
          if fingerprintProb > analyticsProb and fingerprintProb > adProb:
            result.category = tcFingerprinting
            result.fingerprinting = true
          elif analyticsProb > fingerprintProb and analyticsProb > adProb:
            result.category = tcAnalytics
          elif adProb > fingerprintProb and adProb > analyticsProb:
            result.category = tcAdvertising
          
          blocker.logger.debug("ML検出器がトラッキングを検出: " & url & 
                              " (信頼度: " & $mlProbability & ")")
    except:
      blocker.logger.error("ML検出中にエラー発生: " & getCurrentExceptionMsg())
  
  # 信頼度調整
  if result.patterns.len > 1:
    result.confidence = min(0.9, result.confidence) # 最大0.9
  
  # 十分な信頼度があればカテゴリを決定
  if result.confidence >= 0.3:
    if result.category == tcMisc: # まだカテゴリが決まっていない場合
      if result.fingerprinting:
        result.category = tcFingerprinting
      elif url.contains("analytics") or url.contains("metrics"):
        result.category = tcAnalytics
      elif url.contains("ads") or url.contains("advert"):
        result.category = tcAdvertising
    
    # 推奨ブロック戦略を決定
    if result.confidence >= 0.7:
      result.recommendedAction = bsResourceAndCookie
    elif result.confidence >= 0.4:
      result.recommendedAction = bsModifyRequest
    else:
      result.recommendedAction = bsCookie
  
  return result

# HTTP/3リクエストにプライバシー保護を適用
proc applyHTTP3PrivacyProtection*(blocker: TrackerBlocker, 
                                request: var HttpRequest, 
                                qSettings: QUICPrivacySettings) =
  # プライバシーヘッダーの適用
  for name, value in HTTP3_PRIVACY_HEADERS.pairs:
    var found = false
    for i, (headerName, _) in request.headers:
      if headerName.toLowerAscii == name.toLowerAscii:
        request.headers[i] = (headerName, value)
        found = true
        break
    
    if not found:
      request.headers.add((name, value))
  
  # Refererポリシーの強化
  request.headers.add(("Referrer-Policy", "strict-origin-when-cross-origin"))
  
  # QuantumブラウザID（HTTP/3特化）を追加
  request.headers.add(("X-Quantum-HTTP3-Privacy", "enabled"))
  
  # URLから追跡パラメータを削除
  try:
    var uri = parseUri(request.url)
    if uri.query.len > 0:
      var queryParts = uri.query.split('&')
      var newParts: seq[string] = @[]
      
      let trackingParams = ["utm_", "fbclid", "gclid", "ref", "_ga", "quic", "h3", "fp"]
      
      for part in queryParts:
        var skip = false
        for param in trackingParams:
          if part.startsWith(param):
            skip = true
            break
        
        if not skip:
          newParts.add(part)
      
      uri.query = newParts.join("&")
      request.url = $uri
  except:
    blocker.logger.error("URLのトラッキングパラメータ削除に失敗: " & getCurrentExceptionMsg())

# QUIC接続のプライバシー強化
proc enhanceQUICPrivacy*(blocker: TrackerBlocker, 
                       connectionParams: var QuicTransportParameters,
                       settings: QUICPrivacySettings) =
  # プライバシーオプションに基づいた処理
  if qpoMaskConnectionIds in settings.enabled:
    # 接続IDをランダム化
    connectionParams.initialSourceConnectionId = generateRandomConnectionId()
  
  if qpoRotateTransportParams in settings.enabled:
    # 特定のパラメータをランダム化して識別を困難に
    connectionParams.initialMaxStreamDataBidiLocal += rand(1024)
    connectionParams.initialMaxStreamDataBidiRemote += rand(1024)
    connectionParams.initialMaxStreamDataUni += rand(1024)
  
  if qpoBlockPaddingLeaks in settings.enabled:
    # パディングを標準化して情報漏洩を防止
    connectionParams.initialMaxData += uint64(settings.paddingStrategy * 1024)
  
  # その他のプライバシー強化
  if settings.fingerprintResistance >= 2:
    # 高度なフィンガープリント対策
    connectionParams.disableMigration = false  # 追跡を困難にするためにMigrationを許可
    connectionParams.activeConnectionIdLimit = 4  # 複数の接続IDを許可

# プライバシー統計情報の生成
proc generateHTTP3PrivacyStats*(blocker: TrackerBlocker): JsonNode =
  var stats = newJObject()
  
  # HTTP/3特化したトラッカーブロック統計
  var http3Stats = newJObject()
  var totalHttp3Blocked = 0
  var totalQuicFingerprinting = 0
  
  for _, blockStat in blocker.blockStats:
    if blockStat.category == tcFingerprinting:
      totalQuicFingerprinting += blockStat.count
    
    var isHttp3Tracker = false
    for pattern in HTTP3_TRACKING_PATTERNS:
      if pattern in blockStat.domain:
        isHttp3Tracker = true
        break
    
    if isHttp3Tracker:
      totalHttp3Blocked += blockStat.count
  
  # HTTP/3固有の統計情報
  http3Stats["http3TrackersBlocked"] = %totalHttp3Blocked
  http3Stats["quicFingerprintingBlocked"] = %totalQuicFingerprinting
  http3Stats["privacyOptionsEnabled"] = %5  # 実際のQUICPrivacySettingsの値を使用
  
  stats["http3"] = http3Stats
  return stats

# ランダムな文字列を生成（ユーティリティ関数）
proc generateRandomString(length: int): string =
  const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  result = ""
  for i in 0 ..< length:
    result.add(charset[rand(charset.len - 1)])

# ランダムな接続IDを生成（ユーティリティ関数）
proc generateRandomConnectionId(): seq[byte] =
  result = newSeq[byte](8)
  for i in 0 ..< 8:
    result[i] = byte(rand(255))

# サードパーティCookieの判定
proc isThirdPartyCookie*(blocker: TrackerBlocker, topLevelDomain, cookieDomain: string): bool =
  ## あるCookieがサードパーティCookieかどうかを判定
  
  if topLevelDomain.len == 0 or cookieDomain.len == 0:
    return false
  
  # 同一ドメインは1st party
  if cookieDomain == topLevelDomain:
    return false
    
  # トップレベルドメインのサブドメインも1st party
  if cookieDomain.endsWith("." & topLevelDomain):
    return false
    
  # トップレベルドメインがCookieドメインのサブドメインなら1st party
  if topLevelDomain.endsWith("." & cookieDomain):
    return false
  
  # それ以外はサードパーティ
  return true

# Cookie名からトラッキングCookieを検出
proc isTrackingCookie*(blocker: TrackerBlocker, cookieName, cookieValue: string): bool =
  ## Cookie名と値からトラッキングCookieかどうかを判定
  
  # 典型的なトラッキングCookie名パターン
  const TRACKING_COOKIE_PATTERNS = [
    r"^_ga", r"^_gid", r"^_gat",        # Google Analytics
    r"^__utm[a-z]",                      # UTM tracking
    r"^_fbp", r"^_fbc",                  # Facebook
    r"^_ym_", r"^yandex_gid",            # Yandex
    r"^__io",                            # Ionic
    r"^amplitude_",                      # Amplitude
    r"^mp_", r"^mixpanel",               # Mixpanel
    r"^__hstc", r"^hubspotutk",          # HubSpot
    r"^_hjid", r"^_hjSessionUser",       # Hotjar
    r"^MUID", r"^MSFPC",                 # Microsoft
    r"^__qca", r"^__utmz",               # Quantcast
    r"^__adroll",                        # AdRoll
    r"^__cfduid"                         # Cloudflare (非トラッキングだが特定可能)
  ]
  
  # 1. 名前ベースの検出
  for pattern in TRACKING_COOKIE_PATTERNS:
    try:
      if cookieName.match(re(pattern)):
        return true
    except:
      continue
  
  # 2. 値ベースの検出
  if cookieValue.len > 0:
    # 長い16進数やbase64のような値はトラッキングの可能性
    const HEX_PATTERN = r"^[0-9a-f]{16,}$"
    const BASE64_PATTERN = r"^[A-Za-z0-9+/=]{20,}$"
    
    try:
      if cookieValue.match(re(HEX_PATTERN)) or 
         cookieValue.match(re(BASE64_PATTERN)):
        return cookieValue.len >= 32  # 32文字以上なら十分に長い識別子
    except:
      discard
  
  # 3. 既知のトラッカードメインに関連するCookieか
  for tracker in blocker.trackers:
    for domain in tracker.domains:
      if cookieName.contains(domain.replace(".", "_")):
        return true
  
  return false

# Cookieアクセス判定
proc evaluateCookieAccess*(blocker: TrackerBlocker, context: CookieContext): CookieAccessDecision =
  ## Cookieアクセスの許可・ブロックを判定
  
  # ブロッカーが無効なら全て許可
  if not blocker.enabled:
    return cadAllow
  
  # 使用中の設定レベル
  let enforcementLevel = COOKIE_ENFORCEMENT_LEVELS[blocker.severity]
  
  # トップレベルドメインがホワイトリストにある場合
  if blocker.isWhitelisted(context.topLevelDomain):
    # 信頼済みサイトのCookieを保持する設定なら許可
    if enforcementLevel.keepTrustedCookies:
      return cadAllow
    # そうでなくても、有効期限だけ制限
    elif enforcementLevel.expireDays > 0:
      return cadModify
  
  # サードパーティCookieの処理
  if context.isThirdParty:
    # サードパーティCookieブロック設定ならブロック
    if enforcementLevel.blockThirdPartyCookies:
      # ただしホワイトリストドメインからのCookieは許可
      if blocker.isWhitelisted(context.requestDomain):
        return if enforcementLevel.partitionThirdPartyCookies: cadPartition else: cadModify
      return cadBlock
    
    # サードパーティCookieパーティション設定なら分離
    elif enforcementLevel.partitionThirdPartyCookies:
      return cadPartition
  
  # 高リスクCookieの処理
  if enforcementLevel.blockHighRiskCookies and 
     blocker.isTrackingCookie(context.cookieName, context.cookieValue):
    # ホワイトリストドメインからのものも含め、トラッキングCookieはブロック
    return cadBlock
  
  # 有効期限の制限
  if enforcementLevel.expireDays == 0:
    # セッションのみ許可
    return cadSession
  elif enforcementLevel.expireDays > 0:
    # 有効期限を制限して許可
    let now = getTime()
    let maxExpiry = now + initDuration(days=enforcementLevel.expireDays)
    
    if context.expires > maxExpiry:
      return cadModify
  
  # それ以外は許可
  return cadAllow

# サードパーティCookieを処理
proc processThirdPartyCookie*(blocker: TrackerBlocker, topLevelDomain, cookieDomain, 
                            cookieName, cookieValue: string, secure, httpOnly: bool,
                            sameSite: string, expires: Time, 
                            path: string): (CookieAccessDecision, Option[CookieContext]) =
  ## サードパーティCookieの処理
  # 引数:
  # - topLevelDomain: トップレベルドメイン (開いているウェブサイト)
  # - cookieDomain: Cookieを設定しようとしているドメイン
  # - cookieName: Cookie名
  # - cookieValue: Cookie値
  # - secure: セキュアフラグ
  # - httpOnly: HTTPOnlyフラグ
  # - sameSite: SameSite属性
  # - expires: 有効期限
  # - path: パス
  # 
  # 戻り値: 
  # - CookieAccessDecision: 処理結果
  # - Option[CookieContext]: 結果に応じたCookieコンテキスト情報
  
  # ブロッカーが無効なら全て許可
  if not blocker.enabled:
    return (cadAllow, none(CookieContext))
  
  # サードパーティか判定
  let isThirdParty = blocker.isThirdPartyCookie(topLevelDomain, cookieDomain)
  
  # トラッキングCookieか判定
  let isTracking = blocker.isTrackingCookie(cookieName, cookieValue)
  
  # コンテキスト構築
  let context = CookieContext(
    topLevelDomain: topLevelDomain,
    requestDomain: cookieDomain,
    isThirdParty: isThirdParty,
    cookieName: cookieName,
    cookieValue: cookieValue,
    isSecure: secure,
    isHttpOnly: httpOnly,
    sameSite: sameSite,
    expires: expires,
    path: path,
    isTracking: isTracking
  )
  
  # アクセス判定
  let decision = blocker.evaluateCookieAccess(context)
  
  # ブロック統計更新
  if decision == cadBlock:
    blocker.incrementBlockCount(cookieDomain, tcPrivacy, topLevelDomain)
    blocker.logger.debug(&"Cookieブロック: {cookieName} from {cookieDomain} on {topLevelDomain}")
  elif decision == cadPartition:
    blocker.logger.debug(&"Cookieパーティション: {cookieName} from {cookieDomain} on {topLevelDomain}")
  elif decision == cadModify:
    blocker.logger.debug(&"Cookie修正: {cookieName} from {cookieDomain} on {topLevelDomain}")
  
  return (decision, some(context))

# Cookie文字列を解析・処理
proc processCookieHeader*(blocker: TrackerBlocker, headerValue: string, topLevelDomain, 
                        cookieDomain: string, isResponseHeader: bool = true): string =
  ## Cookie文字列を解析して処理する
  ## HeaderValue: "name1=value1; expires=...; path=/; name2=value2; ..."
  
  # ブロッカーが無効なら変更せず
  if not blocker.enabled:
    return headerValue
  
  if headerValue.len == 0:
    return ""
  
  # 応答ヘッダー(Set-Cookie)または要求ヘッダー(Cookie)で処理が異なる
  if isResponseHeader:
    # Set-Cookie処理（サーバーからの応答）
    # 通常は1つのヘッダーに1つのCookieのみ
    var cookieParts = headerValue.split(';')
    if cookieParts.len == 0:
      return headerValue
    
    # Cookieの名前と値を分離
    let nameValuePair = cookieParts[0].split('=', 1)
    if nameValuePair.len < 2:
      return headerValue
    
    let cookieName = nameValuePair[0].strip()
    let cookieValue = nameValuePair[1].strip()
    
    # Cookieの属性を解析
    var secure = false
    var httpOnly = false
    var sameSite = "lax"  # デフォルト
    var expires = getTime() + initDuration(days=365)  # デフォルト：1年
    var path = "/"
    
    for i in 1..<cookieParts.len:
      let part = cookieParts[i].strip().toLowerAscii()
      if part == "secure":
        secure = true
      elif part == "httponly":
        httpOnly = true
      elif part.startsWith("samesite="):
        sameSite = part[9..^1].strip()
      elif part.startsWith("expires="):
        # 簡易実装のため精密な日付解析は省略
        discard
      elif part.startsWith("max-age="):
        try:
          let maxAge = parseInt(part[8..^1].strip())
          if maxAge > 0:
            expires = getTime() + initDuration(seconds=maxAge)
          else:
            expires = getTime() - initDuration(seconds=1)  # 過去の時間
        except:
          discard
      elif part.startsWith("path="):
        path = part[5..^1].strip()
    
    # Cookie処理の実行
    let (decision, contextOpt) = blocker.processThirdPartyCookie(
      topLevelDomain, cookieDomain, cookieName, cookieValue,
      secure, httpOnly, sameSite, expires, path
    )
    
    # 処理結果に基づいた動作
    case decision
    of cadAllow:
      return headerValue  # 変更なし
      
    of cadBlock:
      return ""  # ヘッダーを削除
      
    of cadPartition:
      # Cookieをパーティション化: 名前にサイト固有のプレフィックスを追加
      let partitionedName = sanitizeForCookieName(topLevelDomain) & "--" & cookieName
      var modifiedParts = cookieParts
      modifiedParts[0] = partitionedName & "=" & cookieValue
      return modifiedParts.join(";")
      
    of cadModify, cadSession:
      # Cookieを修正：有効期限を制限
      var modifiedParts: seq[string] = @[]
      modifiedParts.add(cookieName & "=" & cookieValue)
      
      # 必須属性を追加
      if secure:
        modifiedParts.add("Secure")
      if httpOnly:
        modifiedParts.add("HttpOnly")
      
      # SameSite属性
      if sameSite.len > 0:
        modifiedParts.add("SameSite=" & sameSite)
      
      # パス
      modifiedParts.add("Path=" & path)
      
      # 有効期限を制限
      if decision == cadSession:
        # セッションCookieのみ許可（有効期限は設定しない）
        discard
      else:
        # 使用中の設定レベルに基づいた有効期限
        let enforcementLevel = COOKIE_ENFORCEMENT_LEVELS[blocker.severity]
        if enforcementLevel.expireDays > 0:
          let newExpires = getTime() + initDuration(days=enforcementLevel.expireDays)
          let expiresStr = format(newExpires, "ddd, dd MMM yyyy HH:mm:ss") & " GMT"
          modifiedParts.add("Expires=" & expiresStr)
          modifiedParts.add("Max-Age=" & $(enforcementLevel.expireDays * 86400))
      
      return modifiedParts.join("; ")
      
  else:
    # Cookie処理（クライアントからの要求）
    # 複数のCookieを処理する必要がある
    let cookiePairs = headerValue.split(';')
    var allowedCookies: seq[string] = @[]
    
    for pair in cookiePairs:
      let nameValuePair = pair.split('=', 1)
      if nameValuePair.len < 2:
        continue
      
      let cookieName = nameValuePair[0].strip()
      let cookieValue = nameValuePair[1].strip()
      
      # Cookie処理の実行（expireなどの詳細情報がないため簡易版）
      let (decision, _) = blocker.processThirdPartyCookie(
        topLevelDomain, cookieDomain, cookieName, cookieValue,
        true, false, "none", getTime(), "/"
      )
      
      # 処理結果に基づいた動作
      case decision
      of cadAllow:
        allowedCookies.add(pair)
        
      of cadBlock:
        continue  # このCookieは送信しない
        
      of cadPartition:
        # Cookieをパーティション化して送信
        let partitionedName = sanitizeForCookieName(topLevelDomain) & "--" & cookieName
        allowedCookies.add(partitionedName & "=" & cookieValue)
        
      of cadModify, cadSession:
        # 送信時は修正せずに許可
        allowedCookies.add(pair)
    
    return allowedCookies.join("; ")

# Cookieの名前に使える形にドメインを変換
proc sanitizeForCookieName(domain: string): string =
  # ドメイン名からCookieの名前に使える文字列を生成
  result = domain.replace(".", "_")
              .replace("-", "_")
              .replace(":", "_")
  
  # プレフィックスを追加（名前の衝突を避けるため）
  result = "ps_" & result 

#----------------------------------------
# ML検出モデル関連
#----------------------------------------

proc initMlDetectors*(blocker: TrackerBlocker) =
  ## 機械学習検出モデルを初期化
  
  # HTTP/3トラッカー検出モデル
  blocker.http3Detector = new(InferenceModel)
  blocker.http3Detector.modelType = ModelType.mtXGBoost
  
  # モデル設定
  let modelDir = getAppDir() / "models" / "privacy"
  let modelPath = modelDir / "tracker_detector_xgb.model"
  
  # ディレクトリが存在することを確認
  discard existsOrCreateDir(modelDir)
  
  # モデルをロード（存在する場合）またはトレーニング
  if fileExists(modelPath):
    try:
      blocker.logger.info("トラッカー検出モデルのロード: " & modelPath)
      blocker.http3Detector.loadModel(modelPath)
    except:
      blocker.logger.error("モデルロードエラー: " & getCurrentExceptionMsg())
      # 失敗した場合はデフォルトモデルを作成
      blocker.trainFallbackModel()
  else:
    blocker.logger.info("トラッカー検出モデルが見つかりません、トレーニングを実行")
    blocker.trainFallbackModel()

proc trainFallbackModel*(blocker: TrackerBlocker) =
  ## フォールバックモデルをトレーニング
  blocker.logger.info("フォールバックトラッカー検出モデルをトレーニング中")
  
  # デフォルトの特徴量と重みを設定
  let features = @[
    # URL関連特徴量
    ("url_entropy", 0.8),            # URLエントロピー
    ("url_length", 0.4),             # URL長
    ("url_param_count", 0.6),        # URLパラメータ数
    ("has_tracking_params", 0.9),    # 追跡パラメータ存在
    
    # リクエスト関連特徴量
    ("request_referer_set", 0.7),    # リファラー設定
    ("request_type", 0.5),           # リクエストタイプ
    ("request_size", 0.3),           # リクエストサイズ
    
    # コンテンツ関連特徴量
    ("content_type", 0.6),           # コンテンツタイプ
    ("is_third_party", 0.95),        # サードパーティか
    ("response_size", 0.4),          # レスポンスサイズ
    
    # ドメイン関連特徴量
    ("domain_entropy", 0.7),         # ドメインエントロピー
    ("domain_age", 0.5),             # ドメイン年齢
    ("domain_dots", 0.3),            # ドメインのドット数
    
    # ネットワーク関連特徴量
    ("connection_type", 0.4),        # 接続タイプ
    ("uses_encryption", 0.2)         # 暗号化利用
  ]
  
  # モデルの特徴量を設定
  blocker.http3Detector.featureNames = features.mapIt(it[0])
  
  # 特徴量の重要度を設定
  var featureImportance = initTable[string, float]()
  for feature in features:
    featureImportance[feature[0]] = feature[1]
  
  blocker.http3Detector.featureImportance = featureImportance
  
  # 学習用データがない場合は、ヒューリスティックベースのプリセットモデルを定義
  var trackerPatterns = newSeq[(string, float)]()
  
  # 一般的なトラッキングパラメータとその重み
  let trackingParams = [
    ("utm_", 0.7),              # Google Analytics UTMパラメータ
    ("fbclid", 0.95),           # Facebook Click ID
    ("gclid", 0.95),            # Google Click ID
    ("dclid", 0.9),             # DoubleClick ID
    ("msclkid", 0.9),           # Microsoft Click ID
    ("zanpid", 0.85),           # Zanox ID
    ("igshid", 0.85),           # Instagram Share ID
    ("_openstat", 0.8),         # OpenStat
    ("yclid", 0.9),             # Yandex Click ID
    ("wbraid", 0.9),            # Google Ads ID
    ("gbraid", 0.9),            # Google Ads ID
    ("mc_eid", 0.85),           # Mailchimp ID
    ("rb_clickid", 0.85),       # Rakuten ID
    ("twclid", 0.9),            # Twitter Click ID
    ("s_cid", 0.8),             # Adobe Analytics
    ("otc", 0.7),               # Oracle Tracking Code
    ("wickedid", 0.85),         # Wicked Reports ID
    ("dicbo", 0.8),             # Digital Ocean
    ("_ga", 0.85),              # Google Analytics
    ("_hsenc", 0.8),            # HubSpot
    ("__s", 0.7),               # Segment
    ("ttclid", 0.9),            # TikTok Click ID
    ("srsltid", 0.8),           # Square Click ID
    ("cmpid", 0.8),             # Campaign ID (一般)
    ("pxid", 0.8),              # トラッキングピクセルID
    ("redirect_log_mongo_id", 0.85),  # リダイレクトトラッキング
    ("redirect_mongo_id", 0.85),      # リダイレクトトラッキング
    ("sc_cid", 0.8),            # SnapChat
    ("dclid", 0.9),             # DoubleClick
    ("spm", 0.7),               # Alibaba
    ("admitad_uid", 0.9),       # Admitad
    ("pb_click_id", 0.85)       # Propeller Ads
  ]
  
  for (param, weight) in trackingParams:
    trackerPatterns.add((param, weight))
  
  # 一般的なトラッキングドメインパターンとその重み
  let trackerDomains = [
    ("analytics", 0.85),
    ("tracker", 0.9),
    ("pixel", 0.8),
    ("telemetry", 0.85),
    ("beacon", 0.9),
    ("adserv", 0.95),
    ("metric", 0.8),
    ("stat", 0.7),
    ("tag", 0.6),
    ("count", 0.7),
    ("track", 0.85),
    ("collect", 0.7),
    ("monitor", 0.75)
  ]
  
  for (domain, weight) in trackerDomains:
    trackerPatterns.add((domain, weight))
  
  # 既知の追跡サービスドメインとその重み
  let knownTrackers = [
    ("google-analytics.com", 1.0),
    ("doubleclick.net", 1.0),
    ("facebook.com/tr", 1.0),
    ("fb.com/tr", 1.0),
    ("bat.bing.com", 0.95),
    ("analytics.twitter.com", 0.95),
    ("ads-twitter.com", 0.95),
    ("ads.linkedin.com", 0.95),
    ("googletagmanager.com", 0.9),
    ("googletagservices.com", 0.9),
    ("googlesyndication.com", 0.95),
    ("pixel.advertising.com", 0.95),
    ("amazon-adsystem.com", 0.9),
    ("analytics.yahoo.com", 0.9),
    ("scorecardresearch.com", 0.9),
    ("tracking.miui.com", 1.0),
    ("metrics.apple.com", 0.9),
    ("graph.instagram.com", 0.9),
    ("clarity.ms", 0.9),
    ("qualtrics.com", 0.85),
    ("hotjar.com", 0.9),
    ("mouseflow.com", 0.9),
    ("crazyegg.com", 0.9),
    ("sentry.io", 0.7),
    ("bugsnag.com", 0.7),
    ("ravenjs.com", 0.8),
    ("newrelic.com", 0.7),
    ("segment.com", 0.85),
    ("segment.io", 0.85),
    ("branch.io", 0.85),
    ("adjust.com", 0.9),
    ("appsflyer.com", 0.9),
    ("amplitude.com", 0.85),
    ("mixpanel.com", 0.85),
    ("matomo", 0.8),
    ("piwik", 0.8)
  ]
  
  for (domain, weight) in knownTrackers:
    trackerPatterns.add((domain, weight))
  
  # トラッキングスクリプトパターンとその重み
  let trackingScripts = [
    ("analytics.js", 0.9),
    ("gtm.js", 0.9),
    ("pixel.js", 0.85),
    ("fbevents.js", 0.95),
    ("ga.js", 0.9),
    ("tracker.js", 0.85),
    ("uwt.js", 0.8),
    ("beacon.js", 0.85),
    ("tag.js", 0.8),
    ("clarity.js", 0.85),
    ("hotjar.js", 0.9),
    ("insight.min.js", 0.8),
    ("amplitude.js", 0.85),
    ("mixpanel.js", 0.85),
    ("googletagmanager.js", 0.9)
  ]
  
  for (script, weight) in trackingScripts:
    trackerPatterns.add((script, weight))
  
  # これらのパターンを使用して簡易ルールベースモデルを構築
  blocker.http3Detector.buildRuleBasedModel(trackerPatterns)
  
  # モデルを保存
  let modelDir = getAppDir() / "models" / "privacy"
  let modelPath = modelDir / "tracker_detector_xgb.model"
  
  try:
    discard existsOrCreateDir(modelDir)
    blocker.http3Detector.saveModel(modelPath)
    blocker.logger.info("トラッカー検出モデルを保存: " & modelPath)
  except:
    blocker.logger.error("モデル保存エラー: " & getCurrentExceptionMsg())

proc detectTrackerByML*(blocker: TrackerBlocker, url: string, 
                        requestHeaders: Option[HttpHeaders] = none(HttpHeaders), 
                        thirdParty: bool = false): tuple[isTracker: bool, confidence: float] =
  ## 機械学習モデルを使用してトラッカーを検出
  if blocker.http3Detector.isNil:
    # モデルがロードされていない場合は初期化
    blocker.initMlDetectors()
  
  # 特徴量抽出
  var features = initTable[string, float]()
  
  # URL関連特徴量
  let parsedUrl = parseUri(url)
  
  # URLエントロピー (文字の多様性)
  var charCounts = initCountTable[char]()
  for c in url:
    charCounts.inc(c)
  
  var entropy = 0.0
  let urlLen = url.len.float
  for count in charCounts.values:
    let p = count.float / urlLen
    entropy -= p * log2(p)
  
  features["url_entropy"] = entropy
  features["url_length"] = urlLen / 200.0  # 正規化
  
  # URLパラメータ数
  let paramCount = if parsedUrl.query.len > 0: parsedUrl.query.split('&').len.float else: 0.0
  features["url_param_count"] = min(paramCount / 10.0, 1.0)  # 正規化
  
  # 追跡パラメータの存在
  var hasTrackingParams = 0.0
  let query = parsedUrl.query.toLowerAscii
  for param in ["utm_", "fbclid", "gclid", "dclid", "msclkid", "_ga", "twclid"]:
    if query.contains(param):
      hasTrackingParams = 1.0
      break
  
  features["has_tracking_params"] = hasTrackingParams
  
  # リクエスト関連特徴量
  if requestHeaders.isSome:
    let headers = requestHeaders.get
    # リファラーの存在
    features["request_referer_set"] = if headers.hasKey("Referer"): 1.0 else: 0.0
    
    # コンテンツタイプ
    let contentType = if headers.hasKey("Content-Type"): headers["Content-Type"].toLowerAscii else: ""
    features["content_type"] = 
      if contentType.contains("javascript"): 0.8
      elif contentType.contains("image"): 0.3
      elif contentType.contains("json"): 0.6
      elif contentType.contains("text/plain"): 0.4
      else: 0.5
  else:
    features["request_referer_set"] = 0.0
    features["content_type"] = 0.5
  
  # URLパスの拡張子に基づくリクエストタイプ
  let path = parsedUrl.path.toLowerAscii
  features["request_type"] = 
    if path.endsWith(".js"): 0.8
    elif path.endsWith(".png") or path.endsWith(".jpg") or path.endsWith(".gif"): 0.3
    elif path.endsWith(".json"): 0.6
    elif path.endsWith(".html"): 0.2
    elif path.endsWith(".php") or path.endsWith(".aspx"): 0.5
    else: 0.4
  
  # サードパーティかどうか
  features["is_third_party"] = if thirdParty: 1.0 else: 0.0
  
  # その他のデフォルト値
  features["request_size"] = 0.5  # デフォルト
  features["response_size"] = 0.5  # デフォルト
  
  # ドメイン関連特徴量
  let domain = parsedUrl.hostname.toLowerAscii
  
  # ドメインエントロピー
  var domainCharCounts = initCountTable[char]()
  for c in domain:
    domainCharCounts.inc(c)
  
  var domainEntropy = 0.0
  let domainLen = domain.len.float
  for count in domainCharCounts.values:
    let p = count.float / domainLen
    domainEntropy -= p * log2(p)
  
  features["domain_entropy"] = domainEntropy / 5.0  # 正規化
  
  # ドメインのドット数（サブドメインレベル）
  features["domain_dots"] = min(domain.count('.').float / 3.0, 1.0)
  
  # ドメイン年齢（不明なのでデフォルト値）
  features["domain_age"] = 0.5
  
  # ネットワーク関連特徴量（デフォルト値）
  features["connection_type"] = 0.5
  features["uses_encryption"] = if parsedUrl.scheme == "https": 1.0 else: 0.0
  
  # 予測の実行
  let prediction = blocker.http3Detector.predict(features)
  
  # 結果の返却
  result = (isTracker: prediction > 0.7, confidence: prediction)

# リアルタイムトラッカー検出でトレースデータを収集
proc collectTrackerDetectionData*(blocker: TrackerBlocker, url: string, isActualTracker: bool, 
                                features: Table[string, float]) =
  ## トラッカー検出のためのトレーニングデータを収集
  let dataDir = getAppDir() / "models" / "privacy" / "training_data"
  discard existsOrCreateDir(dataDir)
  
  let dataPath = dataDir / "tracker_detection_data.jsonl"
  
  # データエントリの作成
  var entry = %*{
    "url": url,
    "is_tracker": isActualTracker,
    "timestamp": getTime().toUnix(),
    "features": newJObject()
  }
  
  # 特徴量の追加
  for key, value in features:
    entry["features"][key] = %value
  
  # ファイルに追記
  try:
    var f = open(dataPath, fmAppend)
    f.writeLine($entry)
    f.close()
  except:
    blocker.logger.error("トレーニングデータの保存エラー: " & getCurrentExceptionMsg())

# HTTP/3のトラッカー検出を実装（QUICプロトコルレイヤでの検出）
proc detectTrackerInQuicStreams*(blocker: TrackerBlocker, 
                                connId: string,
                                headers: seq[tuple[name: string, value: string]],
                                requestUrl: string): tuple[isTracker: bool, confidence: float] =
  ## QUIC/HTTP3ストリームでのトラッカー検出
  
  # ヘッダーをHTTPヘッダーに変換
  var httpHeaders = newHttpHeaders()
  for (name, value) in headers:
    httpHeaders[name] = value
  
  # ホスト情報の取得
  let host = 
    if httpHeaders.hasKey(":authority"):
      httpHeaders[":authority"]
    elif httpHeaders.hasKey("Host"):
      httpHeaders["Host"]
    else:
      try:
        parseUri(requestUrl).hostname
      except:
        ""
  
  # リファラーからファーストパーティドメインを取得
  var firstPartyDomain = ""
  if httpHeaders.hasKey("Referer"):
    try:
      let refererUri = parseUri(httpHeaders["Referer"])
      firstPartyDomain = refererUri.hostname
    except:
      discard
  
  # サードパーティリクエストかどうかを判定
  let isThirdParty = host.len > 0 and firstPartyDomain.len > 0 and
                     not isDomainOrSubdomain(host, firstPartyDomain)
  
  # MLモデルでトラッカー検出
  result = blocker.detectTrackerByML(requestUrl, some(httpHeaders), isThirdParty)
  
  # 検出結果をログに記録
  if result.isTracker:
    blocker.logger.info(fmt"QUIC/HTTP3トラッカー検出: {requestUrl} (信頼度: {result.confidence:.2f})")
  
  # 学習データを収集（実際のブロック結果に基づく）
    var features = initTable[string, float]()    # 特徴量の抽出  # 1. URLに追跡パラメータが含まれているか  let trackingParams = ["utm_", "fbclid", "gclid", "dclid", "msclkid", "ttclid", "_ga", "ref", "_ck"]  var hasTrackingParams = 0.0  for param in trackingParams:    if url.contains(param):      hasTrackingParams = 1.0      break  features["url_contains_tracking_params"] = hasTrackingParams    # 2. サードパーティリクエストか  let parsedUrl = parseUri(url)  let domain = parsedUrl.hostname  let isThirdParty = sourceDomain.len > 0 and domain != sourceDomain and                      not domain.endsWith("." & sourceDomain) and                     not sourceDomain.endsWith("." & domain)  features["is_third_party"] = if isThirdParty: 1.0 else: 0.0    # 3. トラッキングヘッダーの検出  var trackingHeaderScore = 0.0  for (name, value) in headers:    # 追跡に使われる可能性のあるヘッダー    if name.toLowerAscii in ["x-requested-with", "x-forwarded-for", "x-real-ip",                             "referer", "origin", "user-agent"]:      trackingHeaderScore += 0.2  # 各ヘッダーにスコアを加算    # フィンガープリントに使われる可能性のあるヘッダー    elif name.toLowerAscii in ["dnt", "sec-ch-ua", "sec-ch-ua-mobile",                               "sec-ch-ua-platform", "sec-fetch-site"]:      trackingHeaderScore += 0.3  features["has_tracking_headers"] = min(trackingHeaderScore, 1.0)  # 最大1.0に正規化    # 4. ドメイン評価（既知のトラッカーリストとの照合）  var domainScore = 0.0  for tracker in blocker.trackers:    for trackerDomain in tracker.domains:      if domain == trackerDomain or domain.endsWith("." & trackerDomain):        domainScore = 1.0        break    if domainScore > 0:      break    # 5. URLパスを分析して特徴的なトラッキングパターンを検出  if parsedUrl.path.contains("/analytics") or      parsedUrl.path.contains("/pixel") or      parsedUrl.path.contains("/tracker") or     parsedUrl.path.contains("/beacon") or     parsedUrl.path.contains("/collect") or     parsedUrl.path.toLowerAscii.endsWith(".gif") and parsedUrl.query.len > 0:    domainScore = max(domainScore, 0.8)    features["domain_reputation"] = domainScore    # 6. フィンガープリンティングAPIの使用  var fingerprintScore = 0.0  if url.toLowerAscii.contains("fingerprint") or      url.toLowerAscii.contains("canvas") or     url.toLowerAscii.contains("webgl") or     url.toLowerAscii.contains("audio") or     url.toLowerAscii.contains("battery") or     url.toLowerAscii.contains("deviceinfo"):    fingerprintScore = 0.9  features["has_fingerprinting_apis"] = fingerprintScore    # 7. URLエントロピー計算（ランダムパラメータの検出）  var charCounts = initCountTable[char]()  for c in url:    charCounts.inc(c)    var entropy = 0.0  let urlLen = url.len.float  for count in charCounts.values:    let p = count.float / urlLen    entropy -= p * ln(p)    # エントロピー値を0〜1に正規化（最大エントロピーを約5.0と仮定）  features["url_entropy"] = min(entropy / 5.0, 1.0)    # 8. URL長（長すぎるURLは追跡パラメータを含むことが多い）  features["url_length"] = min(urlLen / 500.0, 1.0)  # 500文字以上は1.0に正規化    # 9. コンテンツタイプ  var contentTypeScore = 0.5  # デフォルト値  for (name, value) in headers:    if name.toLowerAscii == "content-type":      if value.contains("image"):        contentTypeScore = 0.7  # 画像はピクセルトラッキングによく使われる      elif value.contains("javascript"):        contentTypeScore = 0.8  # JavaScriptはトラッキングコードを含む可能性が高い      elif value.contains("json"):        contentTypeScore = 0.6  # JSONはAPIレスポンスとして使われる      else:        contentTypeScore = 0.4      break  features["content_type"] = contentTypeScore    # 10. 接続タイプ  features["connection_type"] = 0.5  # デフォルト値  for (name, value) in headers:    if name.toLowerAscii == "connection" or name.toLowerAscii == "upgrade":      features["connection_type"] = 0.7  # WebSocketや持続的接続はトラッキングに使われることがある      break    
  # トレーニングデータとして保存
  blocker.collectTrackerDetectionData(requestUrl, result.isTracker, features)

# ドメインまたはサブドメインかどうかをチェック
proc isDomainOrSubdomain(domain, parentDomain: string): bool =
  return domain == parentDomain or domain.endsWith("." & parentDomain)

# WebRTC保護のためのICE候補改ざん
proc sanitizeIceCandidates*(blocker: TrackerBlocker, 
                          candidates: seq[string], 
                          protection: tb.WebRtcProtection): seq[string] =
  ## プライバシー保護のためのICE候補を改ざん
  
  if protection.enforceMdns:
    # ICE候補を実際に解析して適切なmDNS候補に置換する完全実装
    var sanitizedCandidates = newSeq[string]()
    
    for candidate in candidates:
      # ICE候補の解析
      if candidate.contains("candidate:"):
        let parts = candidate.split(' ')
        if parts.len >= 8:
          let 
            foundation = parts[0].replace("candidate:", "")
            component = parts[1]
            transport = parts[2]
            priority = parts[3]
            ip = parts[4]
            port = parts[5]
            typ = parts[6]
            kind = if parts.len > 7: parts[7] else: ""
            
          # IPアドレスの種類を確認
          if isIpv4Address(ip) or isIpv6Address(ip):
            if protection.enforceMdns and (typ == "host" or typ == "srflx"):
              # IPアドレスのハッシュに基づいたmDNS名を生成
              # ホストごとに一貫した名前にするため、IPとマシン固有IDを組み合わせる
              let machineId = getMachineIdentifier()
              let ipHash = secureHash(ip & machineId)
              let hashHex = ipHash.toHex().toLowerAscii()
              
              # ハッシュの最初の16文字を使用
              let mdnsName = hashHex[0..15] & ".local"
              
              # mDNSマッピングを保存（再利用のため）
              if not blocker.mdnsMappings.hasKey(ip):
                blocker.mdnsMappings[ip] = mdnsName
                # デバッグログ
                blocker.logger.debug(fmt"mDNSマッピング作成: {ip} -> {mdnsName}")
              
              # 新しい候補を構築
              let newCandidate = fmt"candidate:{foundation} {component} {transport} " &
                                fmt"{priority} {blocker.mdnsMappings[ip]} {port} typ {typ}"
              
              # 追加属性がある場合はそれらも保持
              if parts.len > 8:
                var extraAttrs = newSeq[string]()
                for i in 7..<parts.len:
                  extraAttrs.add(parts[i])
                let newCandidateWithAttrs = newCandidate & " " & extraAttrs.join(" ")
                sanitizedCandidates.add(newCandidateWithAttrs)
              else:
                sanitizedCandidates.add(newCandidate)
              
              # RTCPeerConnectionに送信されるICE候補も更新するためのフック
              if blocker.onIceCandidateModified != nil:
                blocker.onIceCandidateModified(ip, blocker.mdnsMappings[ip])
              
              continue
          
      # 変更不要な候補はそのまま追加
      sanitizedCandidates.add(candidate)
    
    return sanitizedCandidates
  
  return candidates  # 保護が無効ならそのまま返す

# マシン固有識別子を取得
proc getMachineIdentifier(): string =
  # OSごとにマシン固有IDを取得する方法を実装
  when defined(windows):
    # Windowsの場合、コンピューター名とユーザーSIDのハッシュを使用
    let computerName = getEnv("COMPUTERNAME")
    var sid = ""
    try:
      let output = execProcess("whoami /user")
      let lines = output.splitLines()
      if lines.len >= 2:
        let parts = lines[1].split()
        if parts.len >= 2:
          sid = parts[^1]
    except:
      discard
    
    if computerName.len > 0 and sid.len > 0:
      return secureHash(computerName & sid).toHex()
    elif computerName.len > 0:
      return secureHash(computerName).toHex()
    else:
      # フォールバック: 現在の時刻とランダム値
      return secureHash($getTime() & $rand(high(int))).toHex()
  
  elif defined(linux):
    # Linuxの場合、マシンIDを使用
    try:
      if fileExists("/etc/machine-id"):
        let machineId = readFile("/etc/machine-id").strip()
        if machineId.len > 0:
          return machineId
    except:
      discard
    
    # フォールバック: ホスト名
    try:
      let hostname = execProcess("hostname").strip()
      if hostname.len > 0:
        return secureHash(hostname).toHex()
    except:
      discard
    
    # 最終フォールバック
    return secureHash($getTime() & $rand(high(int))).toHex()
  
  elif defined(macosx):
    # macOSの場合、システムUUID/ハードウェアUUIDを使用
    try:
      let output = execProcess("ioreg -rd1 -c IOPlatformExpertDevice | grep -i 'UUID'")
      let lines = output.splitLines()
      for line in lines:
        if line.contains("UUID"):
          let parts = line.split("\"")
          if parts.len >= 3:
            return parts[parts.len - 2]
    except:
      discard
    
    # フォールバック: ホスト名
    try:
      let hostname = execProcess("hostname").strip()
      if hostname.len > 0:
        return secureHash(hostname).toHex()
    except:
      discard
    
    # 最終フォールバック
    return secureHash($getTime() & $rand(high(int))).toHex()
  
  else:
    # その他のOS: 時刻とランダム値
    return secureHash($getTime() & $rand(high(int))).toHex()

# IPアドレスかどうかを確認
proc isIpv4Address(s: string): bool =
  try:
    discard parseIpAddress(s)
    return true
  except:
    return false

proc isIpv6Address(s: string): bool =
  try:
    discard parseIpAddress(s)
    return true
  except:
    return false