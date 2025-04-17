# cookie_extensions.nim
## クッキー拡張機能モジュール - クッキー管理機能の拡張

import std/[
  options,
  tables,
  json,
  os,
  times,
  strutils,
  sequtils,
  algorithm,
  logging,
  re,
  hashes,
  sets
]
import ../cookie_types
import ../security/cookie_security

type
  CookieGroup* = enum
    ## クッキーのグループ分類
    cgSession,        # セッション管理
    cgAuth,           # 認証
    cgPreferences,    # 設定・環境設定
    cgSecurity,       # セキュリティ関連
    cgAnalytics,      # 分析・統計
    cgAdvertising,    # 広告
    cgSocial,         # SNS
    cgFunctional,     # 機能性
    cgNecessary,      # 必須
    cgUnknown         # 不明

  CookieAnalyzer* = ref object
    ## クッキー分析ツール
    namePatterns*: Table[CookieGroup, seq[string]]  # 名前パターンとグループの対応
    domainPatterns*: Table[CookieGroup, seq[string]]  # ドメインパターンとグループの対応
    logger*: Logger  # ロガー

  CookieConsentManager* = ref object
    ## クッキー同意管理
    consents*: Table[string, HashSet[CookieGroup]]  # ドメイン別の同意グループ
    defaultConsent*: HashSet[CookieGroup]  # デフォルトで同意するグループ
    persistPath*: string  # 永続化パス
    autoSave*: bool  # 自動保存フラグ

  # クッキーステータス追跡用
  CookieStats* = ref object
    ## クッキー統計情報
    totalAccepted*: int  # 受け入れたクッキー数
    totalBlocked*: int  # ブロックしたクッキー数
    totalModified*: int  # 変更したクッキー数
    domainStats*: Table[string, tuple[accepted, blocked, modified: int]]  # ドメイン別統計
    groupStats*: Table[CookieGroup, tuple[accepted, blocked, modified: int]]  # グループ別統計
    resetTime*: Time  # 最終リセット時刻

  CookieTrackerDetector* = ref object
    ## トラッカー検出ツール
    trackerDomains*: HashSet[string]  # 既知のトラッカードメイン
    trackerPatterns*: seq[Regex]  # トラッカーパターン
    blockedDomainsCache*: Table[string, tuple[isTracker: bool, updatedAt: Time]]  # キャッシュ
    cacheDuration*: Duration  # キャッシュ有効期間

const
  # デフォルトの名前パターン
  DEFAULT_NAME_PATTERNS = {
    cgSession: @["session", "sess", "sid", "_sid", "sessid"],
    cgAuth: @["auth", "login", "token", "jwt", "access", "uid", "user", "account"],
    cgPreferences: @["pref", "settings", "config", "theme", "lang", "language", "locale"],
    cgSecurity: @["csrf", "xsrf", "sec", "security", "captcha", "verify"],
    cgAnalytics: @["analytics", "stats", "_ga", "gtm", "pixel", "track", "visitor", "visit"],
    cgAdvertising: @["ad", "ads", "advert", "promo", "promotion", "banner", "campaign"],
    cgSocial: @["fb", "facebook", "twitter", "linkedin", "instagram", "social"],
    cgFunctional: @["func", "feature", "tool", "util", "cart", "basket", "recent"]
  }.toTable

  # デフォルトのドメインパターン  
  DEFAULT_DOMAIN_PATTERNS = {
    cgAnalytics: @["analytics", "stats", "metrics", "counter", "pixel", "track"],
    cgAdvertising: @["ad", "ads", "advert", "doubleclick", "banner", "promo"],
    cgSocial: @["facebook", "twitter", "linkedin", "instagram", "social", "connect"],
    cgSession: @["session", "login", "account", "auth", "secure"]
  }.toTable

  # 必須と見なすグループ
  NECESSARY_GROUPS = [cgNecessary, cgSession, cgSecurity, cgAuth]

###################
# クッキー分析ツール
###################

proc newCookieAnalyzer*(): CookieAnalyzer =
  ## 新しいクッキー分析ツールを作成
  result = CookieAnalyzer(
    namePatterns: DEFAULT_NAME_PATTERNS,
    domainPatterns: DEFAULT_DOMAIN_PATTERNS,
    logger: newConsoleLogger()
  )

proc detectGroup*(analyzer: CookieAnalyzer, cookie: Cookie): CookieGroup =
  ## クッキーのグループを検出
  let name = cookie.name.toLowerAscii
  let domain = cookie.domain.toLowerAscii
  
  # 1. 名前ベースのパターンマッチング
  for group, patterns in analyzer.namePatterns:
    for pattern in patterns:
      if name.contains(pattern):
        return group
  
  # 2. ドメインベースのパターンマッチング
  for group, patterns in analyzer.domainPatterns:
    for pattern in patterns:
      if domain.contains(pattern):
        return group
  
  # デフォルトは不明
  return cgUnknown

proc addNamePattern*(analyzer: CookieAnalyzer, group: CookieGroup, pattern: string) =
  ## 名前パターンを追加
  if not analyzer.namePatterns.hasKey(group):
    analyzer.namePatterns[group] = @[]
  analyzer.namePatterns[group].add(pattern.toLowerAscii)

proc addDomainPattern*(analyzer: CookieAnalyzer, group: CookieGroup, pattern: string) =
  ## ドメインパターンを追加
  if not analyzer.domainPatterns.hasKey(group):
    analyzer.domainPatterns[group] = @[]
  analyzer.domainPatterns[group].add(pattern.toLowerAscii)

proc isNecessaryCookie*(analyzer: CookieAnalyzer, cookie: Cookie): bool =
  ## 必須クッキーかどうかを判定
  let group = analyzer.detectGroup(cookie)
  return group in NECESSARY_GROUPS

proc isTrackingCookie*(analyzer: CookieAnalyzer, cookie: Cookie): bool =
  ## トラッキングクッキーかどうかを判定
  let group = analyzer.detectGroup(cookie)
  return group in [cgAnalytics, cgAdvertising]

###################
# クッキー同意管理
###################

proc newCookieConsentManager*(persistPath: string = "", autoSave: bool = true): CookieConsentManager =
  ## 新しいクッキー同意管理を作成
  result = CookieConsentManager(
    consents: initTable[string, HashSet[CookieGroup]](),
    defaultConsent: toHashSet([cgNecessary, cgSession, cgSecurity]),
    persistPath: persistPath,
    autoSave: autoSave
  )
  
  # 保存ファイルがあれば読み込み
  if persistPath.len > 0 and fileExists(persistPath):
    try:
      let jsonData = parseJson(readFile(persistPath))
      
      # デフォルト同意を読み込み
      if jsonData.hasKey("default_consent"):
        result.defaultConsent.clear()
        for item in jsonData["default_consent"]:
          let groupStr = item.getStr()
          for group in CookieGroup:
            if $group == groupStr:
              result.defaultConsent.incl(group)
      
      # ドメイン別同意を読み込み
      if jsonData.hasKey("domains"):
        for domain, groups in jsonData["domains"].pairs:
          var groupSet = initHashSet[CookieGroup]()
          for item in groups:
            let groupStr = item.getStr()
            for group in CookieGroup:
              if $group == groupStr:
                groupSet.incl(group)
          
          if groupSet.len > 0:
            result.consents[domain] = groupSet
    except:
      # 読み込みエラーは無視
      discard

proc saveConsents*(manager: CookieConsentManager): bool =
  ## 同意設定を保存
  if manager.persistPath.len == 0:
    return false
  
  try:
    var domainsJson = newJObject()
    
    for domain, groups in manager.consents:
      var groupsArray = newJArray()
      for group in groups:
        groupsArray.add(%($group))
      domainsJson[domain] = groupsArray
    
    var defaultConsentArray = newJArray()
    for group in manager.defaultConsent:
      defaultConsentArray.add(%($group))
    
    let jsonData = %*{
      "default_consent": defaultConsentArray,
      "domains": domainsJson
    }
    
    writeFile(manager.persistPath, $jsonData)
    return true
  except:
    return false

proc setDomainConsent*(manager: CookieConsentManager, domain: string, groups: HashSet[CookieGroup]): bool =
  ## ドメインの同意グループを設定
  manager.consents[domain.toLowerAscii] = groups
  
  if manager.autoSave:
    return manager.saveConsents()
  return true

proc getDomainConsent*(manager: CookieConsentManager, domain: string): HashSet[CookieGroup] =
  ## ドメインの同意グループを取得
  let normalizedDomain = domain.toLowerAscii
  
  # 完全一致で検索
  if manager.consents.hasKey(normalizedDomain):
    return manager.consents[normalizedDomain]
  
  # ワイルドカード・サブドメイン検索
  let parts = normalizedDomain.split('.')
  if parts.len >= 2:
    let baseDomain = parts[^2] & "." & parts[^1]  # example.com部分
    
    # .*example.comパターン
    if manager.consents.hasKey("*." & baseDomain):
      return manager.consents["*." & baseDomain]
    
    # .example.comパターン
    if manager.consents.hasKey("." & baseDomain):
      return manager.consents["." & baseDomain]
    
    # example.comパターン
    if manager.consents.hasKey(baseDomain):
      return manager.consents[baseDomain]
  
  # デフォルト同意を返す
  return manager.defaultConsent

proc hasConsentFor*(manager: CookieConsentManager, domain: string, group: CookieGroup): bool =
  ## 特定ドメインの特定グループに同意しているか
  let consent = manager.getDomainConsent(domain)
  return group in consent or group in [cgNecessary]  # 必須は常に同意

proc setDefaultConsent*(manager: CookieConsentManager, groups: HashSet[CookieGroup]): bool =
  ## デフォルト同意グループを設定
  manager.defaultConsent = groups
  
  # 必須は常に含める
  manager.defaultConsent.incl(cgNecessary)
  
  if manager.autoSave:
    return manager.saveConsents()
  return true

proc clearDomainConsent*(manager: CookieConsentManager, domain: string): bool =
  ## ドメインの同意設定を削除
  let normalizedDomain = domain.toLowerAscii
  
  if manager.consents.hasKey(normalizedDomain):
    manager.consents.del(normalizedDomain)
    
    if manager.autoSave:
      return manager.saveConsents()
    return true
  
  return false

proc isCookieAllowed*(manager: CookieConsentManager, cookie: Cookie, analyzer: CookieAnalyzer): bool =
  ## 同意に基づきクッキーが許可されているかをチェック
  # 必須クッキーは常に許可
  if analyzer.isNecessaryCookie(cookie):
    return true
  
  # グループを検出
  let group = analyzer.detectGroup(cookie)
  
  # 同意チェック
  return manager.hasConsentFor(cookie.domain, group)

###################
# クッキー統計情報
###################

proc newCookieStats*(): CookieStats =
  ## 新しいクッキー統計情報を作成
  result = CookieStats(
    totalAccepted: 0,
    totalBlocked: 0,
    totalModified: 0,
    domainStats: initTable[string, tuple[accepted, blocked, modified: int]](),
    groupStats: initTable[CookieGroup, tuple[accepted, blocked, modified: int]](),
    resetTime: getTime()
  )

proc recordAccepted*(stats: CookieStats, cookie: Cookie, group: CookieGroup) =
  ## 受け入れたクッキーを記録
  stats.totalAccepted.inc
  
  # ドメイン統計
  let domain = cookie.domain
  if not stats.domainStats.hasKey(domain):
    stats.domainStats[domain] = (accepted: 0, blocked: 0, modified: 0)
  stats.domainStats[domain].accepted.inc
  
  # グループ統計
  if not stats.groupStats.hasKey(group):
    stats.groupStats[group] = (accepted: 0, blocked: 0, modified: 0)
  stats.groupStats[group].accepted.inc

proc recordBlocked*(stats: CookieStats, cookie: Cookie, group: CookieGroup) =
  ## ブロックしたクッキーを記録
  stats.totalBlocked.inc
  
  # ドメイン統計
  let domain = cookie.domain
  if not stats.domainStats.hasKey(domain):
    stats.domainStats[domain] = (accepted: 0, blocked: 0, modified: 0)
  stats.domainStats[domain].blocked.inc
  
  # グループ統計
  if not stats.groupStats.hasKey(group):
    stats.groupStats[group] = (accepted: 0, blocked: 0, modified: 0)
  stats.groupStats[group].blocked.inc

proc recordModified*(stats: CookieStats, cookie: Cookie, group: CookieGroup) =
  ## 変更したクッキーを記録
  stats.totalModified.inc
  
  # ドメイン統計
  let domain = cookie.domain
  if not stats.domainStats.hasKey(domain):
    stats.domainStats[domain] = (accepted: 0, blocked: 0, modified: 0)
  stats.domainStats[domain].modified.inc
  
  # グループ統計
  if not stats.groupStats.hasKey(group):
    stats.groupStats[group] = (accepted: 0, blocked: 0, modified: 0)
  stats.groupStats[group].modified.inc

proc reset*(stats: CookieStats) =
  ## 統計をリセット
  stats.totalAccepted = 0
  stats.totalBlocked = 0
  stats.totalModified = 0
  stats.domainStats.clear()
  stats.groupStats.clear()
  stats.resetTime = getTime()

proc getTopBlockedDomains*(stats: CookieStats, limit: int = 10): seq[tuple[domain: string, count: int]] =
  ## ブロック数が多いドメインを取得
  result = @[]
  
  for domain, data in stats.domainStats:
    if data.blocked > 0:
      result.add((domain: domain, count: data.blocked))
  
  # ブロック数の多い順にソート
  result.sort(proc (a, b: tuple[domain: string, count: int]): int =
    return b.count - a.count
  )
  
  # 上位のみ返す
  if result.len > limit:
    result.setLen(limit)

proc getGroupStats*(stats: CookieStats): JsonNode =
  ## グループ別統計をJSON形式で取得
  result = newJObject()
  
  for group in CookieGroup:
    var groupObj = %*{"accepted": 0, "blocked": 0, "modified": 0}
    
    if stats.groupStats.hasKey(group):
      let data = stats.groupStats[group]
      groupObj["accepted"] = %data.accepted
      groupObj["blocked"] = %data.blocked
      groupObj["modified"] = %data.modified
    
    result[$group] = groupObj

proc toJson*(stats: CookieStats): JsonNode =
  ## 統計情報をJSON形式で取得
  var domainsObj = newJObject()
  
  for domain, data in stats.domainStats:
    domainsObj[domain] = %*{
      "accepted": data.accepted,
      "blocked": data.blocked,
      "modified": data.modified,
      "total": data.accepted + data.blocked + data.modified
    }
  
  result = %*{
    "total_accepted": stats.totalAccepted,
    "total_blocked": stats.totalBlocked,
    "total_modified": stats.totalModified,
    "total_cookies": stats.totalAccepted + stats.totalBlocked + stats.totalModified,
    "domains_count": stats.domainStats.len,
    "reset_time": $stats.resetTime,
    "domains": domainsObj,
    "groups": stats.getGroupStats()
  }

###################
# トラッカー検出
###################

proc newCookieTrackerDetector*(): CookieTrackerDetector =
  ## 新しいトラッカー検出ツールを作成
  result = CookieTrackerDetector(
    trackerDomains: initHashSet[string](),
    trackerPatterns: @[],
    blockedDomainsCache: initTable[string, tuple[isTracker: bool, updatedAt: Time]](),
    cacheDuration: initDuration(hours = 24)  # 24時間キャッシュ
  )
  
  # デフォルトのトラッカードメイン
  const defaultTrackers = [
    "google-analytics.com", "googletagmanager.com", "doubleclick.net",
    "facebook.net", "facebook.com", "fbcdn.net", "twitter.com",
    "scorecardresearch.com", "adnxs.com", "advertising.com", "omtrdc.net",
    "criteo.com", "outbrain.com", "taboola.com", "mathtag.com", "pubmatic.com",
    "rubiconproject.com", "quantserve.com", "amazon-adsystem.com", "chartbeat.com"
  ]
  
  for domain in defaultTrackers:
    result.trackerDomains.incl(domain)
  
  # デフォルトのトラッカーパターン
  const patternStrs = [
    r"analytics\.", r"tracker\.", r"tracking\.", r"stats\.", r"pixel\.",
    r"count\.", r"counter\.", r"tag\.", r"audience\.", r"metrics\.",
    r"telemetry\.", r"collect\.", r"\bad[s]?\.", r"beacon\."
  ]
  
  for patternStr in patternStrs:
    try:
      result.trackerPatterns.add(re(patternStr))
    except:
      # 正規表現エラーは無視
      discard

proc loadTrackerList*(detector: CookieTrackerDetector, filePath: string): bool =
  ## トラッカーリストを読み込む
  try:
    if not fileExists(filePath):
      return false
    
    let content = readFile(filePath)
    for line in content.splitLines():
      let trimmedLine = line.strip()
      if trimmedLine.len > 0 and not trimmedLine.startsWith("#"):
        detector.trackerDomains.incl(trimmedLine.toLowerAscii())
    
    return true
  except:
    return false

proc isTracker*(detector: CookieTrackerDetector, domain: string): bool =
  ## ドメインがトラッカーかどうかを判定
  let normalizedDomain = domain.toLowerAscii()
  
  # キャッシュチェック
  if detector.blockedDomainsCache.hasKey(normalizedDomain):
    let cachedResult = detector.blockedDomainsCache[normalizedDomain]
    let now = getTime()
    if now - cachedResult.updatedAt < detector.cacheDuration:
      return cachedResult.isTracker
  
  # 完全一致チェック
  if normalizedDomain in detector.trackerDomains:
    detector.blockedDomainsCache[normalizedDomain] = (isTracker: true, updatedAt: getTime())
    return true
  
  # サブドメインチェック
  let parts = normalizedDomain.split('.')
  if parts.len >= 2:
    let baseDomain = parts[^2] & "." & parts[^1]  # example.com部分
    if baseDomain in detector.trackerDomains:
      detector.blockedDomainsCache[normalizedDomain] = (isTracker: true, updatedAt: getTime())
      return true
  
  # パターンマッチング
  for pattern in detector.trackerPatterns:
    if normalizedDomain.match(pattern):
      detector.blockedDomainsCache[normalizedDomain] = (isTracker: true, updatedAt: getTime())
      return true
  
  # トラッカーではない
  detector.blockedDomainsCache[normalizedDomain] = (isTracker: false, updatedAt: getTime())
  return false

proc addTrackerDomain*(detector: CookieTrackerDetector, domain: string) =
  ## トラッカードメインを追加
  detector.trackerDomains.incl(domain.toLowerAscii())
  detector.blockedDomainsCache.clear()  # キャッシュをクリア

proc addTrackerPattern*(detector: CookieTrackerDetector, patternStr: string): bool =
  ## トラッカーパターンを追加
  try:
    detector.trackerPatterns.add(re(patternStr))
    detector.blockedDomainsCache.clear()  # キャッシュをクリア
    return true
  except:
    return false

proc isTrackingCookie*(detector: CookieTrackerDetector, cookie: Cookie, analyzer: CookieAnalyzer): bool =
  ## クッキーがトラッキング用かどうかを判定
  # 1. ドメインベースでチェック
  if detector.isTracker(cookie.domain):
    return true
  
  # 2. アナライザーでグループをチェック
  return analyzer.isTrackingCookie(cookie)

proc getTrackersList*(detector: CookieTrackerDetector): seq[string] =
  ## トラッカーリストを取得
  result = toSeq(detector.trackerDomains)
  result.sort() 