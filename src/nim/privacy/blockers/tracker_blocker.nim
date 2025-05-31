# tracker_blocker.nim
## トラッカーブロック機能の実装
## 広告、解析ツール、トラッキングスクリプトなどを検出し、ブロックする機能を提供

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
  os,
  re,
  httpclient,
  json,
  logging,
  threadpool,
  asyncdispatch
]

import ../privacy_types
import ../../network/http/client/http_client_types

# フォワード宣言
type
  TrackerBlocker* = ref TrackerBlockerObj
  TrackerBlockerObj = object
    ## トラッカーブロッカー
    lists: Table[string, PrivacyListInfo]         ## ブロックリスト情報
    rules: Table[string, seq[TrackerRule]]        ## ドメイン別ルール
    globalRules: seq[TrackerRule]                 ## グローバルルール
    trackers: Table[string, TrackerInfo]          ## トラッカー情報
    categories: Table[string, TrackerCategory]    ## カテゴリ情報
    listUpdateTime: Table[string, Time]           ## リスト更新時間
    severity: TrackerBlockerSeverity              ## 厳格度
    enabled: bool                                 ## 有効フラグ
    whitelistedDomains: HashSet[string]           ## ホワイトリストドメイン
    ruleCount: int                                ## ルール数
    regexCache: Table[string, Regex]              ## 正規表現キャッシュ
    logger: Logger                                ## ロガー
    blockStats: Table[string, int]                ## ブロック統計
    lastCleanupTime: Time                         ## 最終クリーンアップ時間
    customRules: seq[TrackerRule]                 ## カスタムルール
    webRtcProtection: WebRtcProtection            ## WebRTC保護機能

  TrackerMatch* = object
    ## トラッカーマッチ結果
    url*: string                                  ## URL
    domain*: string                               ## ドメイン
    rule*: TrackerRule                            ## マッチしたルール
    tracker*: Option[TrackerInfo]                 ## トラッカー情報
    category*: Option[TrackerCategory]            ## カテゴリ情報
    blockDecision*: BlockMode                     ## ブロック決定
    redirectUrl*: Option[string]                  ## リダイレクトURL
    timestamp*: Time                              ## タイムスタンプ
    requestType*: string                          ## リクエストタイプ

  WebRtcPolicy* = enum
    ## WebRTC IPアドレス保護ポリシー
    wrpDefault,       ## デフォルト（制限なし）
    wrpPublicOnly,    ## パブリックIPのみ保護
    wrpFullProtection ## 全IPアドレス保護

  WebRtcProtection* = ref object
    ## WebRTC保護機能
    enabled*: bool                ## 有効フラグ
    policy*: WebRtcPolicy        ## 保護ポリシー
    enforceMdns*: bool           ## mDNS強制使用
    connStats*: Table[string, int] ## 接続統計
    logger*: Logger              ## ロガー

const
  DEFAULT_LISTS = {
    "easylist": "https://easylist.to/easylist/easylist.txt",
    "easyprivacy": "https://easylist.to/easylist/easyprivacy.txt",
    "adguard_base": "https://filters.adtidy.org/extension/chromium/filters/2.txt",
    "disconnect": "https://raw.githubusercontent.com/disconnectme/disconnect-tracking-protection/master/services.json",
    "ublock_privacy": "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/privacy.txt"
  }.toTable

  RULE_PATTERN = r"^(?:@@)?\|\|?([^/:]+)(?:[:\/]|$)([^$]+)?(?:\$([^,]+))?(?:,(.*))?$"
  MAX_CACHE_SIZE = 1000  # 正規表現キャッシュの最大サイズ
  CLEANUP_INTERVAL = initDuration(hours = 1)  # クリーンアップ間隔
  LIST_UPDATE_INTERVAL = 24 * 60 * 60  # リスト更新間隔（秒）
  LIST_STORAGE_DIR = "privacy_lists"   # リスト保存ディレクトリ

#----------------------------------------
# ユーティリティ関数
#----------------------------------------

proc getDomainFromUrl(url: string): string =
  ## URLからドメインを抽出
  try:
    let uri = parseUri(url)
    result = uri.hostname
  except:
    result = ""

proc isThirdPartyRequest(requestUrl, documentUrl: string): bool =
  ## サードパーティリクエストかどうかを判定
  let requestDomain = getDomainFromUrl(requestUrl)
  let documentDomain = getDomainFromUrl(documentUrl)
  
  if requestDomain.len == 0 or documentDomain.len == 0:
    return false
  
  # 完全一致または、サブドメインの場合はファーストパーティ
  result = not (requestDomain == documentDomain or 
               requestDomain.endsWith("." & documentDomain) or
               documentDomain.endsWith("." & requestDomain))

proc isMatchingDomain(domain: string, pattern: string): bool =
  ## ドメインがパターンにマッチするか
  if pattern.startsWith("*."):
    # ワイルドカード（サブドメイン）パターン
    let baseDomain = pattern[2..^1]
    return domain == baseDomain or domain.endsWith("." & baseDomain)
  else:
    # 完全一致パターン
    return domain == pattern

proc matchUrlWithRule(url: string, rule: TrackerRule, regexCache: var Table[string, Regex]): bool =
  ## URLがルールにマッチするか確認
  if rule.isRegex:
    # 正規表現ルール
    try:
      var pattern: Regex
      if regexCache.hasKey(rule.pattern):
        pattern = regexCache[rule.pattern]
      else:
        pattern = re(rule.pattern)
        # キャッシュが大きすぎる場合はクリーンアップ
        if regexCache.len >= MAX_CACHE_SIZE:
          regexCache.clear()
        regexCache[rule.pattern] = pattern
      
      return url.match(pattern)
    except:
      return false
  else:
    # 文字列パターン
    return url.contains(rule.pattern)

#----------------------------------------
# TrackerBlockerの実装
#----------------------------------------

proc newTrackerBlocker*(severity: TrackerBlockerSeverity = tbsStandard): TrackerBlocker =
  ## 新しいトラッカーブロッカーを作成
  new(result)
  result.lists = initTable[string, PrivacyListInfo]()
  result.rules = initTable[string, seq[TrackerRule]]()
  result.globalRules = @[]
  result.trackers = initTable[string, TrackerInfo]()
  result.categories = initTable[string, TrackerCategory]()
  result.listUpdateTime = initTable[string, Time]()
  result.severity = severity
  result.enabled = true
  result.whitelistedDomains = initHashSet[string]()
  result.ruleCount = 0
  result.regexCache = initTable[string, Regex]()
  result.logger = newConsoleLogger()
  result.blockStats = initTable[string, int]()
  result.lastCleanupTime = getTime()
  result.customRules = @[]
  # WebRTC保護機能の初期化
  result.webRtcProtection = newWebRtcProtection()

proc addCategory*(blocker: TrackerBlocker, category: TrackerCategory) =
  ## カテゴリを追加
  blocker.categories[category.name] = category

proc addTracker*(blocker: TrackerBlocker, tracker: TrackerInfo) =
  ## トラッカー情報を追加
  blocker.trackers[tracker.name] = tracker
  
  # 関連ドメインごとにインデックス作成
  for domain in tracker.domains:
    var domainRules = if blocker.rules.hasKey(domain): blocker.rules[domain] else: @[]
    
    # トラッカーのパターンからルールを作成
    for pattern in tracker.patterns:
      let rule = TrackerRule(
        id: $genOid(),
        pattern: pattern,
        isRegex: tracker.useRegex,
        domains: @[domain],
        action: if tracker.category.defaultAction == bmBlock: traBlock else: traAllow
      )
      domainRules.add(rule)
    
    blocker.rules[domain] = domainRules
    blocker.ruleCount += tracker.patterns.len

proc addCustomRule*(blocker: TrackerBlocker, rule: TrackerRule) =
  ## カスタムルールを追加
  blocker.customRules.add(rule)
  
  if rule.domains.len > 0:
    # 特定ドメイン用ルール
    for domain in rule.domains:
      var domainRules = if blocker.rules.hasKey(domain): blocker.rules[domain] else: @[]
      domainRules.add(rule)
      blocker.rules[domain] = domainRules
  else:
    # グローバルルール
    blocker.globalRules.add(rule)
  
  blocker.ruleCount += 1

proc whitelistDomain*(blocker: TrackerBlocker, domain: string) =
  ## ドメインをホワイトリストに追加
  blocker.whitelistedDomains.incl(domain)

proc blacklistDomain*(blocker: TrackerBlocker, domain: string) =
  ## ドメインをブラックリストに追加（カスタムルールとして）
  let rule = TrackerRule(
    id: $genOid(),
    pattern: "||" & domain,
    isRegex: false,
    domains: @[],
    action: traBlock
  )
  blocker.addCustomRule(rule)

proc isWhitelisted*(blocker: TrackerBlocker, domain: string): bool =
  ## ドメインがホワイトリストに含まれるか
  return domain in blocker.whitelistedDomains

proc parseEasyList(content: string): seq[TrackerRule] =
  ## EasyList形式のルールをパース
  result = @[]
  
  let ruleRegex = re(RULE_PATTERN)
  
  for line in content.splitLines():
    let trimmedLine = line.strip()
    
    # コメント行と空行を無視
    if trimmedLine.len == 0 or trimmedLine.startsWith('!'):
      continue
    
    # 単純なパターンマッチングルールのみをサポート
    if not (trimmedLine.startsWith("||") or 
           trimmedLine.startsWith("|") or 
           trimmedLine.startsWith("@@") or
           trimmedLine.contains("$")):
      continue
    
    try:
      var matches: array[4, string]
      if match(trimmedLine, ruleRegex, matches):
        let domain = matches[0]
        let pattern = if matches[1].len > 0: matches[1] else: domain
        let options = matches[2]
        
        # オプションによる制約（基本実装）
        var resourceTypes: seq[string] = @[]
        var exceptDomains: seq[string] = @[]
        var allowRule = trimmedLine.startsWith("@@")
        
        if options.len > 0:
          let optParts = options.split(',')
          for opt in optParts:
            let trimOpt = opt.strip()
            if trimOpt.startsWith("~"):
              # 除外ドメイン
              exceptDomains.add(trimOpt[1..^1])
            elif trimOpt in ["script", "image", "stylesheet", "xhr", "document", "other"]:
              # リソースタイプ
              resourceTypes.add(trimOpt)
        
        let rule = TrackerRule(
          id: $genOid(),
          pattern: pattern,
          isRegex: false,
          domains: if domain.len > 0: @[domain] else: @[],
          exceptDomains: exceptDomains,
          resourceTypes: resourceTypes,
          action: if allowRule: traAllow else: traBlock
        )
        
        result.add(rule)
    except:
      # パース失敗したルールは無視
      continue

proc parseDisconnectList(content: string): seq[TrackerRule] =
  ## Disconnect形式のルールをパース
  result = @[]
  
  try:
    let jsonData = parseJson(content)
    
    if jsonData.hasKey("categories"):
      let categories = jsonData["categories"]
      
      for categoryName, categoryData in categories:
        for serviceObj in categoryData:
          for serviceName, domains in serviceObj:
            let sourceType = parseTrackingSourceType(categoryName)
            
            # ドメインリストを取得
            var domainList: seq[string] = @[]
            
            if domains.kind == JArray:
              for domain in domains:
                if domain.kind == JString:
                  domainList.add(domain.getStr())
            
            for domain in domainList:
              let rule = TrackerRule(
                id: $genOid(),
                pattern: "||" & domain,
                isRegex: false,
                domains: @[domain],
                action: traBlock
              )
              
              result.add(rule)
    
  except Exception as e:
    echo "Disconnect list parsing error: " & e.msg

proc loadPrivacyList*(blocker: TrackerBlocker, name: string, url: string, force: bool = false): Future[bool] {.async.} =
  ## プライバシーリストをロードする
  let listDir = getTempDir() / LIST_STORAGE_DIR
  createDir(listDir)
  
  let listPath = listDir / name & ".txt"
  var needsUpdate = true
  
  # 更新が必要かチェック
  if fileExists(listPath) and not force:
    let modTime = getFileInfo(listPath).lastWriteTime
    let currentTime = getTime()
    needsUpdate = (currentTime - modTime).inSeconds > LIST_UPDATE_INTERVAL
  
  if needsUpdate:
    # 更新が必要な場合はダウンロード
    try:
      let client = newAsyncHttpClient()
      let response = await client.get(url)
      let content = await response.body
      writeFile(listPath, content)
      blocker.listUpdateTime[name] = getTime()
      client.close()
    except Exception as e:
      echo "Error downloading list " & name & ": " & e.msg
      return false
  
  # リスト読み込み
  try:
    let content = readFile(listPath)
    var rules: seq[TrackerRule]
    
    if name.toLowerAscii().contains("disconnect"):
      rules = parseDisconnectList(content)
    else:
      rules = parseEasyList(content)
    
    # リスト情報を保存
    var listInfo = PrivacyListInfo(
      name: name,
      provider: lpCustom,  # シンプル実装のため
      url: url,
      description: name & " privacy list",
      version: "1.0",
      lastUpdated: blocker.listUpdateTime.getOrDefault(name, getTime()),
      expires: getTime() + initDuration(days = 7),
      count: rules.len,
      homepage: "",
      license: ""
    )
    
    blocker.lists[name] = listInfo
    
    # ルールをドメイン別に振り分け
    for rule in rules:
      if rule.domains.len > 0:
        # 特定ドメイン用ルール
        for domain in rule.domains:
          var domainRules = if blocker.rules.hasKey(domain): blocker.rules[domain] else: @[]
          domainRules.add(rule)
          blocker.rules[domain] = domainRules
      else:
        # グローバルルール
        blocker.globalRules.add(rule)
      
      blocker.ruleCount += 1
    
    return true
  except Exception as e:
    echo "Error parsing list " & name & ": " & e.msg
    return false

proc initDefaultLists*(blocker: TrackerBlocker) {.async.} =
  ## デフォルトリストを初期化
  for name, url in DEFAULT_LISTS:
    discard await blocker.loadPrivacyList(name, url)

proc setSeverity*(blocker: TrackerBlocker, severity: TrackerBlockerSeverity) =
  ## 厳格度を設定
  blocker.severity = severity

proc shouldBlockDomain*(blocker: TrackerBlocker, domain: string, parentDomain: string): bool =
  ## ドメインをブロックすべきか判断
  
  # ホワイトリストチェック
  if domain in blocker.whitelistedDomains:
    return false
  
  # 同一ドメインはブロックしない（ファーストパーティ）
  if domain == parentDomain or 
     domain.endsWith("." & parentDomain) or 
     parentDomain.endsWith("." & domain):
    return false
  
  # ドメイン別ルールチェック
  if blocker.rules.hasKey(domain):
    # 厳格度に基づき判断
    case blocker.severity:
    of tbsRelaxed:
      # 広告と暗号通貨マイニングのみブロック
      for rule in blocker.rules[domain]:
        if rule.action == traBlock:
          # Relaxedモードでは広告と暗号通貨マイニングのみをブロック
          if rule.category in [trcAdvertising, trcCryptomining]:
            return true
          # 特定のサブカテゴリ（悪意のある広告など）も常にブロック
          if rule.subCategory in [trscMalvertising, trscScam, trscMalware]:
            return true
    
    of tbsStandard, tbsStrict:
      # 標準または厳格モード
      for rule in blocker.rules[domain]:
        if rule.action == traBlock:
          return true
    
    of tbsCustom:
      # カスタムモード - カスタムルールを優先
      for rule in blocker.customRules:
        if ((rule.domains.len == 0) or (domain in rule.domains)) and
            rule.action == traBlock:
          return true
      
      # 次にデフォルトルール
      for rule in blocker.rules[domain]:
        if rule.action == traBlock:
          return true
  
  # グローバルルールチェック
  for rule in blocker.globalRules:
    if matchUrlWithRule("http://" & domain, rule, blocker.regexCache) and
       rule.action == traBlock:
      return true
  
  # ブロック対象でない
  return false

proc shouldBlockUrl*(blocker: TrackerBlocker, url: string, referrerUrl: string, requestType: string = ""): Option[TrackerMatch] =
  ## URLをブロックすべきか判断
  if not blocker.enabled:
    return none(TrackerMatch)
  
  # 基本情報抽出
  let domain = getDomainFromUrl(url)
  let referrerDomain = getDomainFromUrl(referrerUrl)
  
  # ホワイトリストチェック
  if domain in blocker.whitelistedDomains:
    return none(TrackerMatch)
  
  # リクエストタイプが指定され、厳格度がRelaxedの場合の特別処理
  if requestType.len > 0 and blocker.severity == tbsRelaxed:
    # 広告と追跡に関連しないリソースタイプはブロックしない
    if requestType in ["main_frame", "sub_frame", "font"]:
      return none(TrackerMatch)
  
  # ドメイン別ルールチェック
  if blocker.rules.hasKey(domain):
    for rule in blocker.rules[domain]:
      # リソースタイプチェック
      if rule.resourceTypes.len > 0 and requestType.len > 0:
        if requestType notin rule.resourceTypes:
          continue
      
      # 除外ドメインチェック
      if referrerDomain.len > 0 and rule.exceptDomains.len > 0:
        var excluded = false
        for exceptDomain in rule.exceptDomains:
          if isMatchingDomain(referrerDomain, exceptDomain):
            excluded = true
            break
        
        if excluded:
          continue
      
      # URLパターンマッチング
      if matchUrlWithRule(url, rule, blocker.regexCache):
        # トラッカー情報とカテゴリ情報の抽出
        var trackerInfo: Option[TrackerInfo] = none(TrackerInfo)
        var categoryInfo: Option[TrackerCategory] = none(TrackerCategory)
        
        for name, tracker in blocker.trackers:
          if domain in tracker.domains:
            trackerInfo = some(tracker)
            categoryInfo = some(tracker.category)
            break
        
        # ブロック統計の更新
        if rule.action == traBlock:
          if blocker.blockStats.hasKey(domain):
            blocker.blockStats[domain] += 1
          else:
            blocker.blockStats[domain] = 1
        
        # 結果の生成
        var match = TrackerMatch(
          url: url,
          domain: domain,
          rule: rule,
          tracker: trackerInfo,
          category: categoryInfo,
          blockDecision: if rule.action == traBlock: bmBlock else: bmAllow,
          timestamp: getTime(),
          requestType: requestType
        )
        
        # リダイレクトルールの場合
        if rule.action == traRedirect:
          match.redirectUrl = some(rule.redirectUrl)
          match.blockDecision = bmRedirect
        
        return some(match)
  
  # グローバルルールチェック
  for rule in blocker.globalRules:
    if matchUrlWithRule(url, rule, blocker.regexCache):
      # トラッカー情報とカテゴリ情報の抽出
      var trackerInfo: Option[TrackerInfo] = none(TrackerInfo)
      var categoryInfo: Option[TrackerCategory] = none(TrackerCategory)
      
      # ブロック統計の更新
      if rule.action == traBlock:
        if blocker.blockStats.hasKey(domain):
          blocker.blockStats[domain] += 1
        else:
          blocker.blockStats[domain] = 1
      
      # 結果の生成
      var match = TrackerMatch(
        url: url,
        domain: domain,
        rule: rule,
        tracker: trackerInfo,
        category: categoryInfo,
        blockDecision: if rule.action == traBlock: bmBlock else: bmAllow,
        timestamp: getTime(),
        requestType: requestType
      )
      
      # リダイレクトルールの場合
      if rule.action == traRedirect:
        match.redirectUrl = some(rule.redirectUrl)
        match.blockDecision = bmRedirect
      
      return some(match)
  
  # ブロック対象でない
  return none(TrackerMatch)

proc cleanupCache*(blocker: TrackerBlocker) =
  ## キャッシュをクリーンアップ
  # 正規表現キャッシュのクリーンアップ
  if blocker.regexCache.len > MAX_CACHE_SIZE div 2:
    blocker.regexCache.clear()
  
  blocker.lastCleanupTime = getTime()

proc getStats*(blocker: TrackerBlocker): JsonNode =
  ## ブロッカーの統計情報を取得
  # キャッシュクリーンアップチェック
  if (getTime() - blocker.lastCleanupTime) > CLEANUP_INTERVAL:
    blocker.cleanupCache()
  
  # 上位ブロックドメインを抽出
  var topBlocked: seq[tuple[domain: string, count: int]] = @[]
  for domain, count in blocker.blockStats:
    topBlocked.add((domain: domain, count: count))
  
  # ブロック数で降順ソート
  topBlocked.sort(proc(x, y: tuple[domain: string, count: int]): int = 
    cmp(y.count, x.count))
  
  # 上位10件に制限
  if topBlocked.len > 10:
    topBlocked = topBlocked[0..9]
  
  # JSONデータ生成
  var topBlockedJson = newJArray()
  for item in topBlocked:
    topBlockedJson.add(%*{
      "domain": item.domain,
      "count": item.count
    })
  
  # リスト情報
  var listsJson = newJArray()
  for name, info in blocker.lists:
    listsJson.add(%*{
      "name": name,
      "count": info.count,
      "lastUpdated": $info.lastUpdated.toUnix()
    })

  # WebRTC統計の統合
  let webRtcStats = blocker.webRtcProtection.getWebRtcStats()
  
  # 統計情報を返す
  result = %*{
    "enabled": blocker.enabled,
    "ruleCount": blocker.ruleCount,
    "listCount": blocker.lists.len,
    "severity": $blocker.severity,
    "whitelistedCount": blocker.whitelistedDomains.len,
    "customRulesCount": blocker.customRules.len,
    "topBlocked": topBlockedJson,
    "lists": listsJson,
    "webRtcProtection": webRtcStats,
    "totalBlockedRequests": block:
      var total = 0
      for _, count in blocker.blockStats:
        total += count
      total
  }

proc saveWhitelist*(blocker: TrackerBlocker, filePath: string): bool =
  ## ホワイトリストを保存
  try:
    var list = newJArray()
    for domain in blocker.whitelistedDomains:
      list.add(%domain)
    
    writeFile(filePath, $list)
    return true
  except:
    return false

proc loadWhitelist*(blocker: TrackerBlocker, filePath: string): bool =
  ## ホワイトリストを読み込む
  try:
    if not fileExists(filePath):
      return false
    
    let content = readFile(filePath)
    let jsonData = parseJson(content)
    
    if jsonData.kind != JArray:
      return false
    
    blocker.whitelistedDomains.clear()
    for item in jsonData:
      if item.kind == JString:
        blocker.whitelistedDomains.incl(item.getStr())
    
    return true
  except:
    return false

proc saveCustomRules*(blocker: TrackerBlocker, filePath: string): bool =
  ## カスタムルールを保存
  try:
    var rulesArray = newJArray()
    
    for rule in blocker.customRules:
      var ruleObj = %*{
        "id": rule.id,
        "pattern": rule.pattern,
        "isRegex": rule.isRegex,
        "domains": rule.domains,
        "exceptDomains": rule.exceptDomains,
        "resourceTypes": rule.resourceTypes,
        "action": $rule.action
      }
      
      # アクションごとの追加情報
      case rule.action
      of traRedirect:
        ruleObj["redirectUrl"] = %rule.redirectUrl
      of traModify:
        ruleObj["modificationScript"] = %rule.modificationScript
      else:
        discard
      
      rulesArray.add(ruleObj)
    
    writeFile(filePath, pretty(rulesArray))
    return true
  except:
    return false

proc loadCustomRules*(blocker: TrackerBlocker, filePath: string): bool =
  ## カスタムルールを読み込む
  try:
    if not fileExists(filePath):
      return false
    
    let content = readFile(filePath)
    let jsonData = parseJson(content)
    
    if jsonData.kind != JArray:
      return false
    
    blocker.customRules.setLen(0)
    
    for item in jsonData:
      if item.kind != JObject:
        continue
      
      # 基本情報を取得
      let id = item.getOrDefault("id").getStr($genOid())
      let pattern = item.getOrDefault("pattern").getStr("")
      let isRegex = item.getOrDefault("isRegex").getBool(false)
      
      # ドメイン情報を取得
      var domains: seq[string] = @[]
      if item.hasKey("domains") and item["domains"].kind == JArray:
        for domain in item["domains"]:
          domains.add(domain.getStr())
      
      # 除外ドメイン情報を取得
      var exceptDomains: seq[string] = @[]
      if item.hasKey("exceptDomains") and item["exceptDomains"].kind == JArray:
        for domain in item["exceptDomains"]:
          exceptDomains.add(domain.getStr())
      
      # リソースタイプ情報を取得
      var resourceTypes: seq[string] = @[]
      if item.hasKey("resourceTypes") and item["resourceTypes"].kind == JArray:
        for resType in item["resourceTypes"]:
          resourceTypes.add(resType.getStr())
      
      # アクション情報を取得
      let actionStr = item.getOrDefault("action").getStr("traBlock")
      let action: TrackerRuleAction = 
        case actionStr
        of "traAllow": traAllow
        of "traRedirect": traRedirect
        of "traModify": traModify
        else: traBlock
      
      # ルールオブジェクトを作成
      var rule = TrackerRule(
        id: id,
        pattern: pattern,
        isRegex: isRegex,
        domains: domains,
        exceptDomains: exceptDomains,
        resourceTypes: resourceTypes,
        action: action
      )
      
      # アクション特有の情報を設定
      case action
      of traRedirect:
        rule.redirectUrl = item.getOrDefault("redirectUrl").getStr("")
      of traModify:
        rule.modificationScript = item.getOrDefault("modificationScript").getStr("")
      else:
        discard
      
      # ルールを追加
      blocker.addCustomRule(rule)
    
    return true
  except:
    return false

proc initFromPrivacySettings*(blocker: TrackerBlocker, settings: PrivacySettings) =
  ## プライバシー設定からブロッカーを初期化
  blocker.severity = settings.trackerBlocking
  blocker.enabled = true
  
  # ホワイトリストの設定
  blocker.whitelistedDomains.clear()
  for domain in settings.whitelistedDomains:
    blocker.whitelistedDomains.incl(domain)
  
  # カスタムルールの設定
  blocker.customRules.setLen(0)
  for rule in settings.customRules:
    blocker.addCustomRule(rule)

  # WebRTC保護設定
  configureWebRtcFromSettings(blocker.webRtcProtection, settings)

proc enable*(blocker: TrackerBlocker) =
  ## ブロッカーを有効化
  blocker.enabled = true

proc disable*(blocker: TrackerBlocker) =
  ## ブロッカーを無効化
  blocker.enabled = false

proc isEnabled*(blocker: TrackerBlocker): bool =
  ## ブロッカーが有効かどうか
  return blocker.enabled

#----------------------------------------
# WebRTC保護機能実装
#----------------------------------------

proc newWebRtcProtection*(): WebRtcProtection =
  ## 新しいWebRTC保護機能を作成
  new(result)
  result.enabled = true
  result.policy = wrpPublicOnly
  result.enforceMdns = true
  result.connStats = initTable[string, int]()
  result.logger = newConsoleLogger()

proc enableWebRtcProtection*(protection: WebRtcProtection) =
  ## WebRTC保護を有効化
  protection.enabled = true

proc disableWebRtcProtection*(protection: WebRtcProtection) =
  ## WebRTC保護を無効化
  protection.enabled = false

proc setWebRtcPolicy*(protection: WebRtcProtection, policy: WebRtcPolicy) =
  ## WebRTCポリシーを設定
  protection.policy = policy

proc shouldBlockIceCandidate*(protection: WebRtcProtection, candidate: string): bool =
  ## ICE候補をブロックすべきか判断
  if not protection.enabled:
    return false
    
  # 基本的なICE候補パターン解析
  let candidateLower = candidate.toLowerAscii()
  
  case protection.policy
  of wrpDefault:
    # デフォルトモードでは何もブロックしない
    return false
    
  of wrpPublicOnly:
    # パブリックIPのみブロック
    if candidateLower.contains("typ host") and not candidateLower.contains("mdns"):
      # ローカルネットワーク候補は許可
      if candidateLower.contains("192.168.") or
         candidateLower.contains("10.") or
         candidateLower.contains("172.16.") or
         candidateLower.contains("172.17.") or
         candidateLower.contains("172.18.") or
         candidateLower.contains("172.19.") or
         candidateLower.contains("172.20.") or
         candidateLower.contains("172.21.") or
         candidateLower.contains("172.22.") or
         candidateLower.contains("172.23.") or
         candidateLower.contains("172.24.") or
         candidateLower.contains("172.25.") or
         candidateLower.contains("172.26.") or
         candidateLower.contains("172.27.") or
         candidateLower.contains("172.28.") or
         candidateLower.contains("172.29.") or
         candidateLower.contains("172.30.") or
         candidateLower.contains("172.31.") or
         candidateLower.contains("127.0.0.") or
         candidateLower.contains("::1"):
        return false
      
      # IPv6リンクローカルアドレスは許可
      if candidateLower.contains("fe80:"):
        return false
      
      # その他のパブリックIPと思われるアドレスはブロック
      return true
      
  of wrpFullProtection:
    # 全IPアドレス保護モード
    # mDNSを使用した候補のみを許可
    if candidateLower.contains("typ host") and not candidateLower.contains("mdns"):
      return true
    
    # STUN/TURN サーバーからの候補も制限
    if candidateLower.contains("typ srflx") or candidateLower.contains("typ relay"):
      return true
  
  return false

proc processWebRtcCandidate*(protection: WebRtcProtection, candidate: string, origin: string): tuple[allow: bool, replacement: string] =
  ## WebRTC ICE候補を処理して許可/拒否を判断
  if not protection.enabled:
    return (true, "")
  
  # 統計情報更新
  if not protection.connStats.hasKey(origin):
    protection.connStats[origin] = 0
  protection.connStats[origin] += 1
  
  # ブロック判断
  let shouldBlock = protection.shouldBlockIceCandidate(candidate)
  
  if shouldBlock:
    # mDNS強制有効時は置換用の候補を生成
    if protection.enforceMdns:
      // 特定のパターンの候補をドロップ
      // Backgroundスクリプトと通信して判断
      if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
        chrome.runtime.sendMessage({type: 'checkIceCandidate', candidate: candidate}, function(response) {
          if (!response.allow) return; // ドロップ
          cb.apply(this, arguments);
        });
        return;
      } else if (window.parent) {
        window.parent.postMessage({type: 'checkIceCandidate', candidate: candidate}, '*');
        // 応答待ちのロジックを追加可能
        return;
      }
      // 通信APIがなければそのまま
    let replacement = "candidate:1 1 udp 2122262783 hostname.local 56789 typ host generation 0 ufrag XXXX network-id 1"
    return (false, replacement)
  
  # ブロック不要の場合は元のまま
  return (true, "")

proc getWebRtcStats*(protection: WebRtcProtection): JsonNode =
  ## WebRTC保護統計を取得
  var originStats = newJArray()
  for origin, count in protection.connStats:
    originStats.add(%*{
      "origin": origin,
      "connectionAttempts": count
    })
  
  result = %*{
    "enabled": protection.enabled,
    "policy": $protection.policy,
    "enforceMdns": protection.enforceMdns,
    "totalConnectionAttempts": block:
      var total = 0
      for _, count in protection.connStats:
        total += count
      total,
    "origins": originStats
  }

proc injectWebRtcProtectionScript*(protection: WebRtcProtection): string =
  ## WebRTC保護のためのJavaScriptを生成
  ## これはコンテンツスクリプトとして注入される
  if not protection.enabled:
    return ""
  
  // WebRTC保護のためのJavaScriptスクリプトを生成
  result = """// Quantum Browser WebRTC Privacy Protection(function() {
    const originalRTCPeerConnection = window.RTCPeerConnection;
    const originalGetUserMedia = navigator.mediaDevices && navigator.mediaDevices.getUserMedia ?
      navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices) : null;
    const originalGetDisplayMedia = navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia ?
      navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices) : null;

    // WebRTC接続設定の保護
    if (originalRTCPeerConnection) {
      window.RTCPeerConnection = function(...args) {
        // デフォルト設定の上書き
        if (args.length > 0 && args[0] !== undefined) {
          // ICE設定の保護
          if (!args[0].iceServers) {
            args[0].iceServers = [];
          }

          // STUN/TURNサーバーのフィルタリング
          if (Array.isArray(args[0].iceServers)) {
            const filteredServers = args[0].iceServers.filter(server => {
              // 信頼できるSTUN/TURNサーバーのみを許可
              const urls = Array.isArray(server.urls) ? server.urls : [server.urls];
              for (const url of urls) {
                if (typeof url === 'string') {
                  // Googleなど既知の安全なサーバー以外をブロック
                  if (!url.includes('stun.l.google.com') &&
                      !url.includes('stun.quantum-browser.org')) {
                    return false;
                  }
                }
              }
              return true;
            });
            args[0].iceServers = filteredServers;
          }

          // IP漏洩防止設定
          args[0].iceTransportPolicy = 'relay'; // TURNサーバー経由のみに制限

          // 追加のプライバシー保護設定
          if (${protection.enforceMdns}) {
            // mDNSオプションを強制
            if (!args[0].sdpSemantics) {
              args[0].sdpSemantics = 'unified-plan';
            }

            // ICE候補のIPマスキング
            // Chrome 74以降のmDNS機能を強制有効化
            if (!args[0].bundlePolicy) {
              args[0].bundlePolicy = 'max-bundle';
            }
          }
        }

        // 新しいPeerConnection作成
        const pc = new originalRTCPeerConnection(...args);

        // onicecandidate処理のオーバーライド
        const originalOnIceCandidate = pc.onicecandidate;
        Object.defineProperty(pc, 'onicecandidate', {
          get() {
            return originalOnIceCandidate;
          },
          set(cb) {
            originalOnIceCandidate = function(event) {
              if (event && event.candidate) {
                // ICE候補のフィルタリング・変更
                const candidateStr = event.candidate.candidate;

                // IPアドレスを含む候補をフィルタリング
                const ipRegex = /([0-9]{1,3}(\.[0-9]{1,3}){3}|[a-f0-9]{1,4}(:[a-f0-9]{1,4}){7})/i;

                if (${protection.blockNonMdns}) {
                  // 非mDNS候補を完全にブロック
                  if (ipRegex.test(candidateStr) && !candidateStr.includes('.local')) {
                    // IP漏洩の候補を削除
                    return; // コールバック呼び出しをスキップ
                  }
                }

                // mdnsマスキングを強制
                if (${protection.enforceMdns} && ipRegex.test(candidateStr)) {
                  // IPを含む候補を.localアドレスに変換（単純化のためここでは処理をスキップ）
                  // 実際の置換はサーバーサイドで処理
                }
              }

              // オリジナルのコールバックを呼び出し
              if (cb) {
                cb(event);
              }
            };
            return originalOnIceCandidate;
          }
        });

        // getStats APIの上書き
        const originalGetStats = pc.getStats.bind(pc);
        pc.getStats = async function(...args) {
          const stats = await originalGetStats(...args);
          // センシティブな統計情報の削除
          if (stats && typeof stats.forEach === 'function') {
            stats.forEach(stat => {
              // IPアドレス情報を削除
              if (stat.type === 'local-candidate' || stat.type === 'remote-candidate') {
                if (stat.ip) {
                  stat.ip = stat.address = '0.0.0.0';
                }
                if (stat.address) {
                  stat.address = '0.0.0.0';
                }
              }
            });
          }
          return stats;
        };

        return pc;
      };
    }

    // getUserMedia APIの保護
    if (originalGetUserMedia) {
      navigator.mediaDevices.getUserMedia = async function(constraints) {
        // プライバシー保護のための制約を強制
        if (constraints) {
          // ビデオの解像度制限
          if (constraints.video) {
            if (constraints.video === true) {
              constraints.video = {};
            }

            if (typeof constraints.video === 'object') {
              // 低解像度を強制して識別可能性を低減
              constraints.video.width = { max: 640 };
              constraints.video.height = { max: 480 };

              // フレームレートの制限
              constraints.video.frameRate = { max: 30 };
            }
          }

          // オーディオ制約
          if (constraints.audio) {
            if (constraints.audio === true) {
              constraints.audio = {};
            }

            // エコーキャンセレーションなどの高度な機能を無効化
            if (typeof constraints.audio === 'object') {
              constraints.audio.echoCancellation = false;
              constraints.audio.noiseSuppression = false;
              constraints.audio.autoGainControl = false;
            }
          }
        }

        return originalGetUserMedia.call(navigator.mediaDevices, constraints);
      };
    }

    // getDisplayMedia APIの保護
    if (originalGetDisplayMedia) {
      navigator.mediaDevices.getDisplayMedia = async function(constraints) {
        // プライバシー保護のための制約を強制
        if (constraints) {
          // 画面共有の解像度制限
          if (constraints.video) {
            if (constraints.video === true) {
              constraints.video = {};
            }

            if (typeof constraints.video === 'object') {
              // 低解像度を強制して識別可能性を低減
              constraints.video.width = { max: 1280 };
              constraints.video.height = { max: 720 };

              // フレームレートの制限
              constraints.video.frameRate = { max: 15 };
            }
          }
        }

        return originalGetDisplayMedia.call(navigator.mediaDevices, constraints);
      };
    }

    // RTC関連のフィンガープリントAPI保護
    const protectDTMF = function() {
      if (window.RTCDTMFSender) {
        const originalInsertDTMF = window.RTCDTMFSender.prototype.insertDTMF;
        window.RTCDTMFSender.prototype.insertDTMF = function(tones, duration, interToneGap) {
          // DTMF音のタイミングを標準化して指紋作成を防止
          return originalInsertDTMF.call(this, tones, 100, 70);
        };
      }
    };
    protectDTMF();
    console.log('[Quantum] WebRTC Privacy Protection Enabled');
  })();
"""
  
  // ポリシーに応じたスクリプト修正
  case protection.policy
  of wrpDefault:
    result = result.replace("$policy$", "デフォルト")
  of wrpPublicOnly:
    result = result.replace("$policy$", "パブリックIPのみ保護")
  of wrpFullProtection:
    result = result.replace("$policy$", "完全保護")

# TrackerBlockerにWebRTC保護機能を統合
proc getWebRtcProtection*(blocker: TrackerBlocker): WebRtcProtection =
  ## TrackerBlockerのWebRTC保護機能を取得
  return blocker.webRtcProtection

proc processWebRtcRequest*(blocker: TrackerBlocker, candidate: string, origin: string): tuple[allow: bool, replacement: string] =
  ## TrackerBlockerを通してWebRTC要求を処理
  return blocker.webRtcProtection.processWebRtcCandidate(candidate, origin)

proc configureWebRtcFromSettings*(protection: WebRtcProtection, settings: PrivacySettings) =
  ## プライバシー設定からWebRTC保護を設定
  protection.enabled = settings.webRtcPolicy
  
  # 設定の厳格度に応じてWebRTCポリシーを調整
  case settings.trackerBlocking
  of tbsRelaxed:
    protection.policy = wrpPublicOnly
    protection.enforceMdns = false
  of tbsStandard:
    protection.policy = wrpPublicOnly
    protection.enforceMdns = true
  of tbsStrict, tbsCustom:
    protection.policy = wrpFullProtection
    protection.enforceMdns = true

proc sanitizeIceCandidates*(blocker: TrackerBlocker, 
                          candidates: seq[string], 
                          protection: WebRtcProtection): seq[string] =
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
              if not protection.mdnsMappings.hasKey(ip):
                protection.mdnsMappings[ip] = mdnsName
                # デバッグログ
                blocker.logger.debug(fmt"mDNSマッピング作成: {ip} -> {mdnsName}")
              
              # 新しい候補を構築
              let newCandidate = fmt"candidate:{foundation} {component} {transport} " &
                                fmt"{priority} {protection.mdnsMappings[ip]} {port} typ {typ}"
              
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
              if protection.onIceCandidateModified != nil:
                protection.onIceCandidateModified(ip, protection.mdnsMappings[ip])
              
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
    # IPv4の正規表現パターン
    let ipv4Pattern = r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$"
    let matches = s.findAll(re(ipv4Pattern))
    if matches.len == 0:
      return false
    
    # 各オクテットが0-255の範囲内かチェック
    let octets = s.split('.')
    for octet in octets:
      let num = parseInt(octet)
      if num < 0 or num > 255:
        return false
    
    return true
  except:
    return false

proc isIpv6Address(s: string): bool =
  try:
    # 簡易的なIPv6判定（より厳密な実装が必要な場合は拡張する）
    return s.count(':') >= 2 and not s.contains('.')
  except:
    return false

when isMainModule:
  # テスト用コード
  let blocker = newTrackerBlocker()
  waitFor blocker.initDefaultLists()
  
  # WebRTC保護のテスト
  echo "WebRTC保護が有効: ", blocker.webRtcProtection.enabled
  
  # ICE候補のテスト
  let testCandidate = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0"
  let publicCandidate = "candidate:1 1 udp 1686052607 203.0.113.5 56789 typ srflx raddr 10.0.0.1 rport 56789 generation 0"
  let mdnsCandidate = "candidate:1 1 udp 2122260223 abcd1234-5678-abcd.local 56789 typ host generation 0"
  
  let localResult = blocker.processWebRtcRequest(testCandidate, "https://example.com")
  let publicResult = blocker.processWebRtcRequest(publicCandidate, "https://example.com")
  let mdnsResult = blocker.processWebRtcRequest(mdnsCandidate, "https://example.com")
  
  echo "ローカルIP候補: ", if localResult.allow: "許可" else: "ブロック"
  echo "パブリックIP候補: ", if publicResult.allow: "許可" else: "ブロック"
  echo "mDNS候補: ", if mdnsResult.allow: "許可" else: "ブロック"

  # 異なる保護レベルでのテスト
  echo "\n異なる保護レベルでのテスト:"
  
  # デフォルトモード
  blocker.webRtcProtection.policy = wrpDefault
  echo "デフォルトモード - ローカルIP: ", 
       if blocker.processWebRtcRequest(testCandidate, "https://example.com").allow: "許可" else: "ブロック"
  echo "デフォルトモード - パブリックIP: ", 
       if blocker.processWebRtcRequest(publicCandidate, "https://example.com").allow: "許可" else: "ブロック"
  
  # パブリックIPのみ保護モード
  blocker.webRtcProtection.policy = wrpPublicOnly
  echo "パブリックIPのみ保護 - ローカルIP: ", 
       if blocker.processWebRtcRequest(testCandidate, "https://example.com").allow: "許可" else: "ブロック"
  echo "パブリックIPのみ保護 - パブリックIP: ", 
       if blocker.processWebRtcRequest(publicCandidate, "https://example.com").allow: "許可" else: "ブロック"
  
  # 完全保護モード
  blocker.webRtcProtection.policy = wrpFullProtection
  echo "完全保護モード - ローカルIP: ", 
       if blocker.processWebRtcRequest(testCandidate, "https://example.com").allow: "許可" else: "ブロック"
  echo "完全保護モード - パブリックIP: ", 
       if blocker.processWebRtcRequest(publicCandidate, "https://example.com").allow: "許可" else: "ブロック"
  echo "完全保護モード - mDNS: ", 
       if blocker.processWebRtcRequest(mdnsCandidate, "https://example.com").allow: "許可" else: "ブロック"

  # 複数リクエストのテスト（統計情報計測）
  for i in 0..<5:
    discard blocker.processWebRtcRequest(testCandidate, "https://example.com")
    discard blocker.processWebRtcRequest(publicCandidate, "https://other-site.com")
  
  echo "\nWebRTC保護統計:"
  echo pretty(blocker.webRtcProtection.getWebRtcStats())
  
  # サンプルURLのテスト
  let testUrls = [
    "https://www.example.com/",
    "https://ads.doubleclick.net/pixel.gif",
    "https://www.google-analytics.com/analytics.js",
    "https://connect.facebook.net/en_US/fbevents.js"
  ]
  
  for url in testUrls:
    let result = blocker.shouldBlockUrl(url, "https://www.example.com/")
    if result.isSome:
      echo url, " -> BLOCKED"
    else:
      echo url, " -> ALLOWED"
  
  echo "\n総合統計情報:"
  echo pretty(blocker.getStats()) 