# secure_cookie_jar.nim
## セキュアクッキージャー実装 - セキュリティ強化されたクッキー管理機能

import std/[
  options, 
  tables, 
  sets, 
  hashes, 
  strutils, 
  uri, 
  times, 
  sequtils, 
  algorithm,
  logging
]
import ../cookie_types
import ./cookie_security

type
  SecureCookieJar* = ref object
    ## セキュリティ機能が強化されたクッキージャー
    cookies: Table[string, HashSet[Cookie]]  # ドメイン別クッキー格納
    securityManager: CookieSecurityManager   # セキュリティ管理
    domainCookieCounts: Table[string, int]   # ドメインごとのクッキー数
    maxPerDomain: int                        # ドメインごとの最大クッキー数
    maxTotal: int                            # 全体の最大クッキー数
    encryptSensitive: bool                   # 機密クッキーの暗号化フラグ
    securityPolicy: CookieSecurePolicy       # セキュリティポリシー
    trustedDomains: HashSet[string]          # 信頼済みドメイン
    logger: Logger                           # ロガー

  SecureCookieJarOptions* = object
    ## セキュアクッキージャーの設定オプション
    maxPerDomain*: int                    # ドメインごとの最大クッキー数
    maxTotal*: int                        # 全体の最大クッキー数
    encryptSensitive*: bool               # 機密クッキーの暗号化の有無
    securityPolicy*: CookieSecurePolicy   # セキュリティポリシー
    masterKey*: string                    # 暗号化マスターキー（空文字列ならランダム生成）
    sensitiveNamePatterns*: seq[string]   # 機密と見なすクッキー名パターン

const
  # デフォルト設定
  DEFAULT_MAX_PER_DOMAIN = 50   # ドメインごとの最大クッキー数
  DEFAULT_MAX_TOTAL = 3000      # 全体の最大クッキー数
  
  # 機密クッキーのデフォルトパターン
  DEFAULT_SENSITIVE_PATTERNS = @[
    "auth", "token", "session", "id", "userid", "user_id", 
    "login", "pass", "key", "secret", "csrf", "xsrf"
  ]

###################
# ユーティリティ関数
###################

proc generateCookieKey(cookie: Cookie): string =
  ## クッキーの一意識別子を生成
  return cookie.name & "|" & cookie.domain & "|" & cookie.path

proc isSensitiveCookie(name: string, patterns: seq[string]): bool =
  ## クッキーが機密データを含むか判定
  let nameLower = name.toLowerAscii()
  for pattern in patterns:
    if nameLower.contains(pattern.toLowerAscii()):
      return true
  return false

proc matchesDomain(cookieDomain: string, requestDomain: string): bool =
  ## クッキードメインがリクエストドメインにマッチするか
  if cookieDomain == requestDomain:
    return true
    
  # ドメインプレフィックス（.example.com形式）のチェック
  if cookieDomain.startsWith("."):
    let domain = cookieDomain[1..^1]
    return requestDomain == domain or requestDomain.endsWith("." & domain)
    
  return false

proc matchesPath(cookiePath: string, requestPath: string): bool =
  ## クッキーパスがリクエストパスにマッチするか
  if cookiePath == requestPath:
    return true
    
  if requestPath.startsWith(cookiePath):
    # パスの末尾が/で終わるか、/で区切られた次のセグメントの始まりであることを確認
    if cookiePath.endsWith("/") or requestPath[cookiePath.len] == '/':
      return true
      
  return false

proc isExpired(cookie: Cookie): bool =
  ## クッキーが有効期限切れかを確認
  if cookie.expirationTime.isNone:
    return false
    
  return getTime() > cookie.expirationTime.get()

proc sortCookiesByPath(cookies: seq[Cookie]): seq[Cookie] =
  ## クッキーをパス長の降順でソート（RFC準拠）
  result = cookies
  result.sort(proc(a, b: Cookie): int =
    # パス長が長い順（降順）
    result = b.path.len - a.path.len
    # 同じ長さの場合、作成時間の昇順
    if result == 0:
      if a.creationTime < b.creationTime: 
        result = -1
      elif a.creationTime > b.creationTime: 
        result = 1
  )

###################
# セキュアクッキージャー
###################

proc newSecureCookieJarOptions*(): SecureCookieJarOptions =
  ## デフォルト設定のセキュアクッキージャーオプションを作成
  result.maxPerDomain = DEFAULT_MAX_PER_DOMAIN
  result.maxTotal = DEFAULT_MAX_TOTAL
  result.encryptSensitive = true
  result.securityPolicy = csPreferSecure
  result.masterKey = ""
  result.sensitiveNamePatterns = DEFAULT_SENSITIVE_PATTERNS

proc newSecureCookieJar*(options: SecureCookieJarOptions = newSecureCookieJarOptions()): SecureCookieJar =
  ## 新しいセキュアクッキージャーを作成
  new(result)
  result.cookies = initTable[string, HashSet[Cookie]]()
  result.domainCookieCounts = initTable[string, int]()
  result.maxPerDomain = options.maxPerDomain
  result.maxTotal = options.maxTotal
  result.encryptSensitive = options.encryptSensitive
  result.securityManager = newCookieSecurityManager(options.masterKey)
  result.securityPolicy = options.securityPolicy
  result.trustedDomains = initHashSet[string]()
  result.logger = newConsoleLogger()

proc addTrustedDomain*(jar: SecureCookieJar, domain: string) =
  ## 信頼済みドメインとして追加
  jar.trustedDomains.incl(domain)
  # セキュリティマネージャーにも追加
  jar.securityManager.addTrustedOrigin("https://" & domain)
  jar.securityManager.addTrustedOrigin("http://" & domain)

proc isTrustedDomain*(jar: SecureCookieJar, domain: string): bool =
  ## ドメインが信頼済みかをチェック
  return domain in jar.trustedDomains

proc totalCookieCount*(jar: SecureCookieJar): int =
  ## 全クッキーの総数を取得
  var total = 0
  for domain, count in jar.domainCookieCounts:
    total += count
  return total

proc clear*(jar: SecureCookieJar) =
  ## すべてのクッキーを削除
  jar.cookies.clear()
  jar.domainCookieCounts.clear()

proc clearDomain*(jar: SecureCookieJar, domain: string) =
  ## 特定ドメインのクッキーをすべて削除
  if jar.cookies.hasKey(domain):
    jar.cookies.del(domain)
    jar.domainCookieCounts.del(domain)

proc deleteCookie*(jar: SecureCookieJar, name, domain, path: string): bool =
  ## 特定のクッキーを削除
  if not jar.cookies.hasKey(domain):
    return false
    
  let cookieKey = name & "|" & domain & "|" & path
  
  # 一致するクッキーを検索して削除
  var found = false
  var domainCookies = jar.cookies[domain]
  var newDomainCookies: HashSet[Cookie]
  
  for cookie in domainCookies:
    if generateCookieKey(cookie) == cookieKey:
      found = true
    else:
      newDomainCookies.incl(cookie)
  
  if found:
    if newDomainCookies.len > 0:
      jar.cookies[domain] = newDomainCookies
      jar.domainCookieCounts[domain] = newDomainCookies.len
    else:
      jar.cookies.del(domain)
      jar.domainCookieCounts.del(domain)
  
  return found

proc addCookie*(jar: SecureCookieJar, cookie: Cookie, 
                sensitivePatterns: seq[string] = DEFAULT_SENSITIVE_PATTERNS): bool =
  ## クッキーを追加（セキュリティ強化を適用）
  if isExpired(cookie):
    # 期限切れクッキーは追加しない
    return false
  
  # セキュリティポリシーに基づいて属性を適用
  var securedCookie = jar.securityManager.enforceSecureAttributes(cookie, jar.securityPolicy)
  
  # 機密クッキーの暗号化
  if jar.encryptSensitive and isSensitiveCookie(cookie.name, sensitivePatterns):
    securedCookie.value = jar.securityManager.encryptValue(securedCookie.value)
  
  # 既存のクッキーを削除（同名、同ドメイン、同パス）
  discard jar.deleteCookie(securedCookie.name, securedCookie.domain, securedCookie.path)
  
  # ドメインのクッキー数制限チェック
  let domain = securedCookie.domain
  var domainCount = if jar.domainCookieCounts.hasKey(domain): jar.domainCookieCounts[domain] else: 0
  
  if domainCount >= jar.maxPerDomain:
    jar.logger.log(lvlWarn, "Domain cookie limit reached for " & domain)
    return false
  
  # 総クッキー数制限チェック
  if jar.totalCookieCount() >= jar.maxTotal:
    jar.logger.log(lvlWarn, "Total cookie limit reached")
    return false
  
  # クッキーを追加
  if not jar.cookies.hasKey(domain):
    jar.cookies[domain] = initHashSet[Cookie]()
  
  jar.cookies[domain].incl(securedCookie)
  jar.domainCookieCounts[domain] = jar.cookies[domain].len
  
  return true

proc getCookies*(jar: SecureCookieJar, requestUrl: Uri, sourceUrl: Option[Uri] = none(Uri)): seq[Cookie] =
  ## URLに関連するクッキーを取得
  result = @[]
  
  let requestDomain = requestUrl.hostname
  let requestPath = if requestUrl.path.len == 0: "/" else: requestUrl.path
  let isSecure = requestUrl.scheme == "https"
  
  # ドメインマッチするクッキーを検索
  for domain, domainCookies in jar.cookies:
    if matchesDomain(domain, requestDomain):
      for cookie in domainCookies:
        # 期限切れチェック
        if isExpired(cookie):
          continue
        
        # パスマッチチェック
        if not matchesPath(cookie.path, requestPath):
          continue
        
        # セキュアクッキーはHTTPSのみ
        if cookie.isSecure and not isSecure:
          continue
        
        # Same-Siteポリシーチェック
        if sourceUrl.isSome:
          if not jar.securityManager.isSameSitePolicyAllowed(cookie, requestUrl, sourceUrl.get):
            continue
        
        # 有効なクッキーを追加
        result.add(cookie)
  
  # パスの長さに基づいてソート
  result = sortCookiesByPath(result)

proc getCookie*(jar: SecureCookieJar, name: string, domain: string, path: string = "/"): Option[Cookie] =
  ## 特定のクッキーを名前、ドメイン、パスで検索
  if not jar.cookies.hasKey(domain):
    return none(Cookie)
  
  let cookieKey = name & "|" & domain & "|" & path
  
  for cookie in jar.cookies[domain]:
    if generateCookieKey(cookie) == cookieKey:
      # 期限切れチェック
      if isExpired(cookie):
        return none(Cookie)
      
      return some(cookie)
  
  return none(Cookie)

proc getCookieValue*(jar: SecureCookieJar, name: string, domain: string, path: string = "/"): Option[string] =
  ## クッキー値を取得（機密クッキーは必要に応じて復号）
  let cookieOpt = jar.getCookie(name, domain, path)
  if cookieOpt.isNone:
    return none(string)
  
  let cookie = cookieOpt.get
  var value = cookie.value
  
  # 機密クッキーなら復号を試みる
  if jar.encryptSensitive and isSensitiveCookie(name, DEFAULT_SENSITIVE_PATTERNS):
    try:
      let decrypted = jar.securityManager.decryptValue(value)
      if decrypted.error == ceNone:
        value = decrypted.value
    except:
      # 復号に失敗した場合は元の値を使用
      discard
  
  return some(value)

proc removeExpiredCookies*(jar: SecureCookieJar): int =
  ## 期限切れクッキーを削除し、削除数を返す
  var removed = 0
  let now = getTime()
  
  for domain, domainCookies in jar.cookies:
    var validCookies: HashSet[Cookie]
    var expired = 0
    
    for cookie in domainCookies:
      if cookie.expirationTime.isSome and cookie.expirationTime.get() <= now:
        expired += 1
      else:
        validCookies.incl(cookie)
    
    if expired > 0:
      removed += expired
      if validCookies.len > 0:
        jar.cookies[domain] = validCookies
        jar.domainCookieCounts[domain] = validCookies.len
      else:
        jar.cookies.del(domain)
        jar.domainCookieCounts.del(domain)
  
  return removed

proc getSecurityRiskReport*(jar: SecureCookieJar): seq[tuple[cookie: Cookie, risk: int, issues: seq[string]]] =
  ## クッキーのセキュリティリスク評価レポートを生成
  result = @[]
  
  for domain, domainCookies in jar.cookies:
    for cookie in domainCookies:
      var issues: seq[string] = @[]
      
      # 各セキュリティ問題をチェック
      if not cookie.isSecure:
        issues.add("安全な接続(HTTPS)でのみ送信されません")
      
      if not cookie.isHttpOnly:
        issues.add("JavaScriptからアクセス可能")
      
      if cookie.sameSite == ssNone:
        issues.add("SameSite保護がありません")
      
      if cookie.path == "/":
        issues.add("パスが広すぎます(/)")
      
      if cookie.expirationTime.isSome:
        let expiry = cookie.expirationTime.get()
        let now = getTime()
        let days = (expiry - now).inDays
        
        if days > 365:
          issues.add("有効期限が長すぎます(1年超)")
        
      if cookie.value.len > 1024:
        issues.add("クッキーサイズが大きすぎます(1KB超)")
      
      if isSensitiveCookie(cookie.name, DEFAULT_SENSITIVE_PATTERNS) and not jar.encryptSensitive:
        issues.add("機密データが暗号化されていません")
      
      # リスクスコア算出
      let risk = jar.securityManager.evaluateCookieRisk(cookie)
      
      if issues.len > 0:
        result.add((cookie: cookie, risk: risk, issues: issues))
  
  # リスクの高い順にソート
  result.sort(proc(a, b: tuple[cookie: Cookie, risk: int, issues: seq[string]]): int =
    result = b.risk - a.risk
  )

proc getSecurityManager*(jar: SecureCookieJar): CookieSecurityManager =
  ## セキュリティマネージャーを取得
  return jar.securityManager

proc generateCsrfToken*(jar: SecureCookieJar, domain: string): string =
  ## 特定ドメイン用のCSRFトークンを生成
  return jar.securityManager.generateCsrfTokenForOrigin("https://" & domain)

proc validateCsrfToken*(jar: SecureCookieJar, domain: string, token: string): bool =
  ## CSRFトークンの検証
  return jar.securityManager.validateCsrfToken("https://" & domain, token)

proc importCookies*(jar: SecureCookieJar, cookies: seq[Cookie]): int =
  ## 複数のクッキーをインポート（成功した数を返す）
  var successCount = 0
  
  for cookie in cookies:
    if jar.addCookie(cookie):
      successCount += 1
  
  return successCount

proc exportCookies*(jar: SecureCookieJar, domain: string = ""): seq[Cookie] =
  ## クッキーをエクスポート（オプションで特定ドメインのみ）
  result = @[]
  
  if domain.len > 0:
    # 特定ドメインのみエクスポート
    if jar.cookies.hasKey(domain):
      for cookie in jar.cookies[domain]:
        if not isExpired(cookie):
          result.add(cookie)
  else:
    # すべてのクッキーをエクスポート
    for domain, domainCookies in jar.cookies:
      for cookie in domainCookies:
        if not isExpired(cookie):
          result.add(cookie)

proc updateSecurityPolicy*(jar: SecureCookieJar, policy: CookieSecurePolicy) =
  ## セキュリティポリシーを更新
  jar.securityPolicy = policy 