# cookie_manager_ext.nim
## クッキーマネージャー拡張モジュール - 拡張機能とポリシーを統合

import std/[
  options,
  tables,
  json,
  os,
  times,
  strutils,
  uri,
  sets,
  sequtils,
  logging
]
import ../cookie_types
import ../main
import ../policy/cookie_policy
import ../policy/policy_loader
import ./cookie_extensions

type
  ExtendedCookieManager* = ref object
    ## 拡張クッキーマネージャー
    baseManager*: CookieManager        # 基本クッキーマネージャー
    policy*: CookiePolicy              # クッキーポリシー
    consentManager*: CookieConsentManager  # 同意管理
    analyzer*: CookieAnalyzer          # クッキー分析
    trackerDetector*: CookieTrackerDetector  # トラッカー検出
    stats*: CookieStats                # 統計情報
    logger*: Logger                    # ロガー
    userDataDir*: string               # ユーザーデータディレクトリ
    strictMode*: bool                  # 厳格モード
    profileName*: string               # プロファイル名

###################
# 初期化・設定
###################

proc newExtendedCookieManager*(
  baseManager: CookieManager, 
  userDataDir: string = "",
  profileName: string = "default",
  strictMode: bool = false
): ExtendedCookieManager =
  ## 拡張クッキーマネージャーを作成
  result = ExtendedCookieManager(
    baseManager: baseManager,
    userDataDir: userDataDir,
    strictMode: strictMode,
    profileName: profileName,
    logger: newConsoleLogger()
  )
  
  # ユーザーディレクトリを設定
  if userDataDir.len == 0:
    result.userDataDir = baseManager.config.userDataDir
  else:
    result.userDataDir = userDataDir
  
  # 必要なディレクトリを作成
  let cookiesDir = result.userDataDir / "cookies"
  if not dirExists(cookiesDir):
    createDir(cookiesDir)
  
  # ポリシーローダー作成
  let policyDir = cookiesDir / "policies"
  if not dirExists(policyDir):
    createDir(policyDir)
  
  let policyLoader = newPolicyLoader(policyDir)
  
  # プロファイルに応じたポリシーを読み込み
  let policyType = if strictMode or profileName == "incognito": 
                     psStrict 
                   elif profileName == "permissive": 
                     psPermissive 
                   else: 
                     psStandard
  
  result.policy = policyLoader.loadPolicy(policyType)
  
  # 同意管理を作成
  let consentPath = cookiesDir / "consents" / (profileName & "_consent.json")
  result.consentManager = newCookieConsentManager(consentPath)
  
  # 分析ツール作成
  result.analyzer = newCookieAnalyzer()
  
  # トラッカー検出作成
  result.trackerDetector = newCookieTrackerDetector()
  
  # トラッカーリストの読み込み
  let trackersPath = cookiesDir / "trackers.txt"
  if fileExists(trackersPath):
    discard result.trackerDetector.loadTrackerList(trackersPath)
  
  # 統計情報作成
  result.stats = newCookieStats()

proc enableStrictMode*(manager: ExtendedCookieManager, enable: bool = true) =
  ## 厳格モードを有効/無効にする
  manager.strictMode = enable
  
  # ポリシー更新
  let policyType = if enable: psStrict else: psStandard
  let policyDir = manager.userDataDir / "cookies" / "policies"
  let policyLoader = newPolicyLoader(policyDir)
  manager.policy = policyLoader.loadPolicy(policyType, true)  # 強制再読み込み

proc setProfilePolicy*(manager: ExtendedCookieManager, profileName: string) =
  ## プロファイルに応じたポリシーを設定
  manager.profileName = profileName
  
  # ポリシー更新
  let policyType = case profileName.toLowerAscii
    of "incognito", "private": psIncognito
    of "strict": psStrict
    of "permissive": psPermissive
    else: psStandard
  
  let policyDir = manager.userDataDir / "cookies" / "policies"
  let policyLoader = newPolicyLoader(policyDir)
  manager.policy = policyLoader.loadPolicy(policyType, true)  # 強制再読み込み

###################
# クッキー処理拡張
###################

proc processCookie*(manager: ExtendedCookieManager, cookie: Cookie, 
                   documentUrl: Uri, isFirstParty: bool = true): tuple[
                     action: string, 
                     processedCookie: Option[Cookie]
                   ] =
  ## クッキーを処理（ポリシーと同意に基づく）
  let domain = cookie.domain
  
  # 1. トラッカーチェック
  let isTracker = manager.trackerDetector.isTrackingCookie(cookie, manager.analyzer)
  
  # 2. グループ検出
  let group = manager.analyzer.detectGroup(cookie)
  
  # 3. ポリシールール取得
  let documentDomain = documentUrl.hostname
  let rule = manager.policy.getRuleForContext(domain, documentDomain)
  
  # 4. 同意チェック
  let hasConsent = manager.consentManager.isCookieAllowed(cookie, manager.analyzer)
  
  # 5. 必須クッキーチェック
  let isNecessary = manager.analyzer.isNecessaryCookie(cookie)
  
  # ルールに基づいて処理
  if isNecessary:
    # 必須クッキーは常に許可
    manager.stats.recordAccepted(cookie, group)
    return (action: "accept", processedCookie: some(cookie))
    
  if isTracker and manager.strictMode:
    # 厳格モードではトラッカーをブロック
    manager.stats.recordBlocked(cookie, group)
    return (action: "block", processedCookie: none(Cookie))
  
  # ポリシーに従って処理
  case rule
  of prAllow:
    # 同意チェック
    if not hasConsent and not isFirstParty:
      manager.stats.recordBlocked(cookie, group)
      return (action: "block_no_consent", processedCookie: none(Cookie))
    
    manager.stats.recordAccepted(cookie, group)
    return (action: "accept", processedCookie: some(cookie))
    
  of prBlock:
    manager.stats.recordBlocked(cookie, group)
    return (action: "block_policy", processedCookie: none(Cookie))
    
  of prAllowSession:
    # セッションクッキーに変換
    var modifiedCookie = cookie
    modifiedCookie.expirationTime = none(Time)
    modifiedCookie.storeType = stMemory
    
    manager.stats.recordModified(cookie, group)
    return (action: "modify_session", processedCookie: some(modifiedCookie))
    
  of prAllowFirstParty:
    if isFirstParty:
      manager.stats.recordAccepted(cookie, group)
      return (action: "accept_first_party", processedCookie: some(cookie))
    else:
      manager.stats.recordBlocked(cookie, group)
      return (action: "block_third_party", processedCookie: none(Cookie))
    
  of prPartition:
    # プライバシー分離を適用
    var modifiedCookie = cookie
    # パーティションキー = eTLD+1（example.com部分）
    let parts = documentUrl.hostname.split('.')
    if parts.len >= 2:
      let partitionKey = parts[^2] & "." & parts[^1]
      modifiedCookie.partitionKey = some(partitionKey)
    
    manager.stats.recordModified(cookie, group)
    return (action: "partition", processedCookie: some(modifiedCookie))
    
  of prPrompt:
    # プロンプト（デフォルトは拒否）
    # 実際のプロンプトはUI側で処理、ここではブロック
    manager.stats.recordBlocked(cookie, group)
    return (action: "prompt", processedCookie: none(Cookie))

proc addCookieWithPolicy*(manager: ExtendedCookieManager, cookie: Cookie, 
                          documentUrl: Uri, isFirstParty: bool = true): bool =
  ## ポリシーに従ってクッキーを追加
  let result = manager.processCookie(cookie, documentUrl, isFirstParty)
  
  if result.processedCookie.isSome:
    return manager.baseManager.addCookie(result.processedCookie.get())
  
  return false

proc addCookieFromHeaderWithPolicy*(manager: ExtendedCookieManager, 
                                    header: string, domain: string, 
                                    documentUrl: Uri, 
                                    isFirstParty: bool = true,
                                    secure: bool = false): bool =
  ## ヘッダーからクッキーを追加（ポリシー適用）
  # まず通常のパース処理
  var parts = header.split(';')
  if parts.len == 0:
    return false
  
  # 最初の部分は「name=value」
  let nameValue = parts[0].strip()
  let nameValueParts = nameValue.split('=', 1)
  if nameValueParts.len != 2:
    return false
  
  let name = nameValueParts[0].strip()
  let value = nameValueParts[1].strip()
  
  # 属性のパース
  var 
    path = "/"
    expirationTime: Option[Time] = none(Time)
    maxAge: Option[int] = none(int)
    isSecure = secure
    isHttpOnly = false
    sameSite = ssLax
  
  for i in 1..<parts.len:
    let attr = parts[i].strip().toLowerAscii()
    
    if attr.startsWith("path="):
      path = attr[5..^1].strip()
      if path.len == 0:
        path = "/"
    
    elif attr.startsWith("expires="):
      # 日付形式のパース
      let dateStr = attr[8..^1].strip()
      try:
        expirationTime = some(parse(dateStr, "ddd, dd MMM yyyy HH:mm:ss 'GMT'"))
      except:
        discard
    
    elif attr.startsWith("max-age="):
      try:
        let seconds = parseInt(attr[8..^1].strip())
        maxAge = some(seconds)
        expirationTime = some(getTime() + initDuration(seconds = seconds))
      except:
        discard
    
    elif attr == "secure":
      isSecure = true
    
    elif attr == "httponly":
      isHttpOnly = true
    
    elif attr.startsWith("samesite="):
      let samesite = attr[9..^1].strip().toLowerAscii()
      case samesite
      of "strict":
        sameSite = ssStrict
      of "none":
        sameSite = ssNone
      else:
        sameSite = ssLax
  
  # クッキーオブジェクトの作成
  let cookie = newCookie(
    name = name,
    value = value,
    domain = domain,
    path = path,
    expirationTime = expirationTime,
    isSecure = isSecure,
    isHttpOnly = isHttpOnly,
    sameSite = sameSite,
    source = csHttpHeader
  )
  
  # ポリシーに従って処理
  return manager.addCookieWithPolicy(cookie, documentUrl, isFirstParty)

proc getCookiesWithPolicy*(manager: ExtendedCookieManager, url: Uri, 
                          documentUrl: Option[Uri] = none(Uri)): seq[Cookie] =
  ## ポリシーに従ってクッキーを取得
  let cookies = manager.baseManager.getCookies(url, firstPartyUrl = documentUrl)
  var result: seq[Cookie] = @[]
  
  let docUrl = if documentUrl.isSome: documentUrl.get() else: url
  let domain = url.hostname
  
  for cookie in cookies:
    # 1. グループ検出
    let group = manager.analyzer.detectGroup(cookie)
    
    # 2. 同意チェック
    let hasConsent = manager.consentManager.hasConsentFor(cookie.domain, group)
    
    # 3. 必須クッキーチェック
    let isNecessary = manager.analyzer.isNecessaryCookie(cookie)
    
    # 4. トラッカーチェック
    let isTracker = manager.trackerDetector.isTrackingCookie(cookie, manager.analyzer)
    
    # 5. ポリシールール取得
    let isFirstParty = docUrl.hostname == domain
    let rule = manager.policy.getRuleForContext(cookie.domain, docUrl.hostname)
    
    # 必須クッキーまたは同意済みの場合は常に含める
    if isNecessary or hasConsent:
      result.add(cookie)
      continue
    
    # 厳格モードではトラッカーを除外
    if isTracker and manager.strictMode:
      continue
    
    # ポリシーに従って処理
    case rule
    of prAllow:
      result.add(cookie)
      
    of prBlock:
      continue
      
    of prAllowSession:
      # 既にセッションクッキーなら含める
      if cookie.expirationTime.isNone:
        result.add(cookie)
      
    of prAllowFirstParty:
      if isFirstParty:
        result.add(cookie)
      
    of prPartition:
      # パーティションキーがあれば含める
      if cookie.partitionKey.isSome:
        result.add(cookie)
      
    of prPrompt:
      # 同意済みでなければ除外
      continue
  
  return result

proc getCookieHeaderWithPolicy*(manager: ExtendedCookieManager, url: Uri, 
                               documentUrl: Option[Uri] = none(Uri)): string =
  ## ポリシーに従ってCookieヘッダーを生成
  let cookies = manager.getCookiesWithPolicy(url, documentUrl)
  if cookies.len == 0:
    return ""
  
  # クッキー値を組み立て
  var values: seq[string] = @[]
  for cookie in cookies:
    values.add(cookie.name & "=" & cookie.value)
  
  return values.join("; ")

proc clearAllCookiesWithStats*(manager: ExtendedCookieManager): int =
  ## すべてのクッキーをクリア（統計付き）
  let count = manager.baseManager.clearAllCookies()
  
  # 統計リセット
  manager.stats.reset()
  
  return count

###################
# 統計・レポート
###################

proc getExtendedStats*(manager: ExtendedCookieManager): JsonNode =
  ## 拡張統計を取得
  var baseStats = manager.baseManager.getMetrics()
  var statsJson = manager.stats.toJson()
  
  # トラッカー統計を追加
  var trackersObj = newJObject()
  let trackersList = manager.trackerDetector.getTrackersList()
  for i, tracker in trackersList:
    trackersObj[tracker] = %true
  
  statsJson["trackers"] = %*{
    "count": trackersList.len,
    "domains": trackersObj
  }
  
  # ポリシー情報を追加
  statsJson["policy"] = %*{
    "profile": manager.profileName,
    "strict_mode": manager.strictMode,
    "rules_count": manager.policy.entries.len
  }
  
  # 同意情報を追加
  var consentDomainsObj = newJObject()
  for domain, groups in manager.consentManager.consents:
    var groupsArray = newJArray()
    for group in groups:
      groupsArray.add(%($group))
    consentDomainsObj[domain] = groupsArray
  
  statsJson["consent"] = %*{
    "domains_count": manager.consentManager.consents.len,
    "domains": consentDomainsObj
  }
  
  # 基本統計と統合
  result = baseStats
  result["extended"] = statsJson

proc getPrivacyReport*(manager: ExtendedCookieManager): JsonNode =
  ## プライバシーレポートを生成
  var topBlockedDomains = manager.stats.getTopBlockedDomains(20)
  var blockedDomainsArray = newJArray()
  
  for item in topBlockedDomains:
    blockedDomainsArray.add(%*{
      "domain": item.domain,
      "count": item.count,
      "is_tracker": manager.trackerDetector.isTracker(item.domain)
    })
  
  var groupPercentages = newJObject()
  let totalCookies = max(1, manager.stats.totalAccepted + manager.stats.totalBlocked + manager.stats.totalModified)
  
  for group in CookieGroup:
    if manager.stats.groupStats.hasKey(group):
      let data = manager.stats.groupStats[group]
      let total = data.accepted + data.blocked + data.modified
      let percentage = (total.float / totalCookies.float) * 100.0
      groupPercentages[$group] = %(percentage.int)
    else:
      groupPercentages[$group] = %0
  
  result = %*{
    "report_time": $getTime(),
    "total_cookies_processed": totalCookies,
    "accepted_percentage": (manager.stats.totalAccepted.float / totalCookies.float * 100.0).int,
    "blocked_percentage": (manager.stats.totalBlocked.float / totalCookies.float * 100.0).int,
    "modified_percentage": (manager.stats.totalModified.float / totalCookies.float * 100.0).int,
    "top_blocked_domains": blockedDomainsArray,
    "cookie_types_distribution": groupPercentages,
    "strict_mode": manager.strictMode,
    "profile": manager.profileName
  }

###################
# 同意管理
###################

proc setConsentForDomain*(manager: ExtendedCookieManager, domain: string, 
                         allowedGroups: seq[CookieGroup]): bool =
  ## ドメインの同意設定を更新
  var groupSet = toHashSet(allowedGroups)
  # 必須グループは常に含める
  groupSet.incl(cgNecessary)
  
  return manager.consentManager.setDomainConsent(domain, groupSet)

proc setDefaultConsent*(manager: ExtendedCookieManager, allowedGroups: seq[CookieGroup]): bool =
  ## デフォルト同意設定を更新
  var groupSet = toHashSet(allowedGroups)
  # 必須グループは常に含める
  groupSet.incl(cgNecessary)
  
  return manager.consentManager.setDefaultConsent(groupSet)

proc clearConsentForDomain*(manager: ExtendedCookieManager, domain: string): bool =
  ## ドメインの同意設定をクリア
  return manager.consentManager.clearDomainConsent(domain)

###################
# ポリシー管理
###################

proc addPolicyRule*(manager: ExtendedCookieManager, domain: string, 
                   rule: CookiePolicyRule, priority: int = 100): bool =
  ## ポリシールールを追加
  return manager.policy.addRule(domain, rule, isUserCreated = true, priority = priority)

proc removePolicyRule*(manager: ExtendedCookieManager, domain: string): bool =
  ## ポリシールールを削除
  return manager.policy.removeRule(domain)

proc addExceptionDomain*(manager: ExtendedCookieManager, domain: string) =
  ## 例外ドメインを追加
  manager.policy.addException(domain)

proc removeExceptionDomain*(manager: ExtendedCookieManager, domain: string): bool =
  ## 例外ドメインを削除
  return manager.policy.removeException(domain)

proc clearExpiredPolicyRules*(manager: ExtendedCookieManager): int =
  ## 期限切れのポリシールールをクリア
  return manager.policy.clearExpiredRules()

###################
# トラッカー管理
###################

proc addTracker*(manager: ExtendedCookieManager, domain: string) =
  ## トラッカーを追加
  manager.trackerDetector.addTrackerDomain(domain)

proc addTrackerPattern*(manager: ExtendedCookieManager, pattern: string): bool =
  ## トラッカーパターンを追加
  return manager.trackerDetector.addTrackerPattern(pattern)

proc saveTrackerList*(manager: ExtendedCookieManager): bool =
  ## トラッカーリストを保存
  let trackersPath = manager.userDataDir / "cookies" / "trackers.txt"
  try:
    let trackers = manager.trackerDetector.getTrackersList()
    writeFile(trackersPath, trackers.join("\n"))
    return true
  except:
    return false

proc exportPolicy*(manager: ExtendedCookieManager): JsonNode =
  ## ポリシーをエクスポート
  return policy_loader.exportPolicyToJson(manager.policy)

proc importPolicy*(manager: ExtendedCookieManager, jsonData: JsonNode) =
  ## ポリシーをインポート
  manager.policy = policy_loader.importPolicyFromJson(jsonData) 