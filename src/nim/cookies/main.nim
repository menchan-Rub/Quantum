# main.nim
## ブラウザのクッキー管理システム - メインモジュール
## このモジュールはクッキー管理の主要なエントリーポイントとして機能し、
## 必要なすべてのサブモジュールを統合します。

import std/[
  uri,
  options,
  strutils,
  times,
  sequtils,
  sets,
  tables,
  json,
  os,
  logging
]

import ./cookie_types
import ./store/cookie_store
import ./security/cookie_security
import ./security/secure_cookie_jar

export cookie_types
export cookie_security
export cookie_store
export secure_cookie_jar

type
  CookieManagerMode* = enum
    ## クッキーマネージャの動作モード
    cmSecure,     ## セキュリティ強化モード（デフォルト）
    cmBasic,      ## 基本モード
    cmIncognito   ## プライベートモード（永続化なし）

  BrowserCookieConfig* = object
    ## ブラウザクッキー設定
    userDataDir*: string                    ## ユーザーデータディレクトリ
    maxPerDomain*: int                      ## ドメインあたりの最大クッキー数
    maxTotal*: int                          ## 全体の最大クッキー数
    maxSizeBytes*: int                      ## クッキーの最大サイズ（バイト）
    persistSessionCookies*: bool            ## セッションクッキーを永続化するか
    encryptSensitive*: bool                 ## 機密クッキーを暗号化するか
    securityPolicy*: CookieSecurePolicy     ## セキュリティポリシー
    thirdPartyPolicy*: CookieThirdPartyPolicy ## サードパーティクッキーポリシー
    partitioningPolicy*: CookiePartition    ## プライバシー分離ポリシー
    masterKey*: string                      ## 暗号化マスターキー
    sensitivePatterns*: seq[string]         ## 機密クッキーパターン
    mode*: CookieManagerMode                ## 動作モード

  CookieManager* = ref object
    ## 統合クッキーマネージャー
    case mode*: CookieManagerMode
    of cmBasic:
      store*: CookieStore                  ## 基本クッキーストア
    of cmSecure:
      secureJar*: SecureCookieJar          ## セキュアクッキージャー
    of cmIncognito:
      incognitoJar*: SecureCookieJar       ## インコグニトモード用ジャー
    
    config*: BrowserCookieConfig           ## 設定
    logger*: Logger                        ## ロガー
    lastMetricsTime*: Time                 ## 最後のメトリクス取得時刻
    blockMatchers*: seq[string]            ## ブロックパターン

###################
# デフォルト設定
###################

proc defaultBrowserCookieConfig*(): BrowserCookieConfig =
  ## デフォルトのブラウザクッキー設定を生成
  result = BrowserCookieConfig(
    userDataDir: getTempDir() / "browser_data",
    maxPerDomain: 50,
    maxTotal: 3000,
    maxSizeBytes: 4096,
    persistSessionCookies: false,
    encryptSensitive: true,
    securityPolicy: csPreferSecure,
    thirdPartyPolicy: tpSmartBlock,
    partitioningPolicy: cpThirdParty,
    masterKey: "",
    sensitivePatterns: @[
      "auth", "token", "session", "id", "userid", "user_id", 
      "login", "pass", "key", "secret", "csrf", "xsrf"
    ],
    mode: cmSecure
  )

###################
# クッキーマネージャー
###################

proc newCookieManager*(config = defaultBrowserCookieConfig()): CookieManager =
  ## 新しいクッキーマネージャーを作成
  new(result)
  
  # 共通設定
  result.config = config
  result.logger = newConsoleLogger()
  result.lastMetricsTime = getTime()
  result.blockMatchers = @[]
  result.mode = config.mode
  
  # モード別の初期化
  case config.mode
  of cmBasic:
    let storeOptions = newCookieStoreOptions(
      userDataDir = config.userDataDir,
      encryptionEnabled = config.encryptSensitive,
      cookiesPerDomainLimit = config.maxPerDomain,
      totalCookiesLimit = config.maxTotal,
      maxCookieSizeBytes = config.maxSizeBytes,
      persistSessionCookies = config.persistSessionCookies,
      thirdPartyPolicy = config.thirdPartyPolicy,
      securePolicy = config.securityPolicy,
      partitioningPolicy = config.partitioningPolicy
    )
    result.store = newCookieStore(storeOptions)
    discard result.store.loadCookies()
    
  of cmSecure:
    let secureOptions = SecureCookieJarOptions(
      maxPerDomain: config.maxPerDomain,
      maxTotal: config.maxTotal,
      encryptSensitive: config.encryptSensitive,
      securityPolicy: config.securityPolicy,
      masterKey: config.masterKey,
      sensitiveNamePatterns: config.sensitivePatterns
    )
    result.secureJar = newSecureCookieJar(secureOptions)
    
  of cmIncognito:
    let secureOptions = SecureCookieJarOptions(
      maxPerDomain: config.maxPerDomain,
      maxTotal: config.maxTotal,
      encryptSensitive: true,  # インコグニトモードは常に暗号化
      securityPolicy: csRequireSecure,  # インコグニトモードは最高セキュリティ
      masterKey: config.masterKey,
      sensitiveNamePatterns: config.sensitivePatterns
    )
    result.incognitoJar = newSecureCookieJar(secureOptions)

proc saveCookies*(manager: CookieManager): bool =
  ## 現在のクッキーを保存
  case manager.mode
  of cmBasic:
    return manager.store.saveCookies()
  of cmSecure:
    # セキュアジャーの永続化処理（必要に応じて実装）
    return true
  of cmIncognito:
    # インコグニトモードでは保存しない
    return true

proc addCookie*(manager: CookieManager, cookie: Cookie): bool =
  ## クッキーを追加
  case manager.mode
  of cmBasic:
    return manager.store.addCookie(cookie)
  of cmSecure:
    return manager.secureJar.addCookie(cookie)
  of cmIncognito:
    return manager.incognitoJar.addCookie(cookie)

proc addCookieFromHeader*(manager: CookieManager, header: string, domain: string, secure: bool = false): bool =
  ## Set-Cookieヘッダーからクッキーを追加
  # ヘッダーのパース
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
      # HTTP日付パース（RFC準拠・複数フォーマット対応）
      let dateStr = attr[8..^1].strip()
      let formats = [
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",   # RFC 1123
        "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",    # RFC 850
        "EEE MMM d HH:mm:ss yyyy"            # ANSI C asctime
      ]
      var parsed = false
      for fmt in formats:
        try:
          expirationTime = some(parse(dateStr, fmt))
          parsed = true
          break
        except: discard
      if not parsed:
        # 無効な日付形式は無視
        discard
    
    elif attr.startsWith("max-age="):
      try:
        let seconds = parseInt(attr[8..^1].strip())
        maxAge = some(seconds)
        # Max-AgeはExpiresより優先される
        expirationTime = some(getTime() + initDuration(seconds = seconds))
      except:
        # 無効な形式は無視
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
        sameSite = ssLax  # 不明な値はLaxとしてデフォルト扱い
  
  # クッキーオブジェクトの作成と追加
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
  
  return manager.addCookie(cookie)

proc setCookie*(manager: CookieManager, 
               name, value, domain, path: string,
               maxAge: Option[int] = none(int),
               secure: bool = true,
               httpOnly: bool = true,
               sameSite: CookieSameSite = ssLax): bool =
  ## 高レベルAPI: 新しいクッキーを設定
  var expirationTime: Option[Time] = none(Time)
  
  # MaxAgeから有効期限を計算
  if maxAge.isSome:
    expirationTime = some(getTime() + initDuration(seconds = maxAge.get()))
  
  let cookie = newCookie(
    name = name,
    value = value,
    domain = domain,
    path = path,
    expirationTime = expirationTime,
    isSecure = secure,
    isHttpOnly = httpOnly,
    sameSite = sameSite,
    source = csManuallyAdded
  )
  
  return manager.addCookie(cookie)

proc getCookies*(manager: CookieManager, url: Uri, firstPartyUrl: Option[Uri] = none(Uri)): seq[Cookie] =
  ## URLに関連するクッキーを取得
  case manager.mode
  of cmBasic:
    return manager.store.getCookies(url, firstPartyUrl)
  of cmSecure:
    return manager.secureJar.getCookies(url, firstPartyUrl = firstPartyUrl)
  of cmIncognito:
    return manager.incognitoJar.getCookies(url, firstPartyUrl = firstPartyUrl)

proc getCookieHeader*(manager: CookieManager, url: Uri, firstPartyUrl: Option[Uri] = none(Uri)): string =
  ## URLに対するCookieヘッダーを生成
  let cookies = manager.getCookies(url, firstPartyUrl)
  if cookies.len == 0:
    return ""
  
  # クッキー値を組み立て
  var values: seq[string] = @[]
  for cookie in cookies:
    values.add(cookie.name & "=" & cookie.value)
  
  return values.join("; ")

proc getCookie*(manager: CookieManager, name: string, domain: string, path: string = "/"): Option[Cookie] =
  ## 特定のクッキーを名前、ドメイン、パスで検索
  case manager.mode
  of cmBasic:
    let criteria = CookieMatchCriteria(
      name: some(name),
      domain: some(domain),
      path: some(path)
    )
    let results = manager.store.findCookies(criteria)
    if results.len > 0:
      return some(results[0])
    return none(Cookie)
    
  of cmSecure:
    return manager.secureJar.getCookie(name, domain, path)
    
  of cmIncognito:
    return manager.incognitoJar.getCookie(name, domain, path)

proc getCookieValue*(manager: CookieManager, name: string, domain: string, path: string = "/"): Option[string] =
  ## クッキー値を取得
  case manager.mode
  of cmBasic:
    let cookieOpt = manager.getCookie(name, domain, path)
    if cookieOpt.isSome:
      return some(cookieOpt.get().value)
    return none(string)
    
  of cmSecure:
    return manager.secureJar.getCookieValue(name, domain, path)
    
  of cmIncognito:
    return manager.incognitoJar.getCookieValue(name, domain, path)

proc deleteCookie*(manager: CookieManager, name: string, domain: string, path: string = "/"): bool =
  ## クッキーを削除
  case manager.mode
  of cmBasic:
    let cookieOpt = manager.getCookie(name, domain, path)
    if cookieOpt.isSome:
      return manager.store.removeCookie(cookieOpt.get())
    return false
    
  of cmSecure:
    return manager.secureJar.deleteCookie(name, domain, path)
    
  of cmIncognito:
    return manager.incognitoJar.deleteCookie(name, domain, path)

proc clearAllCookies*(manager: CookieManager): int =
  ## すべてのクッキーをクリア
  case manager.mode
  of cmBasic:
    return manager.store.clearAllCookies()
  of cmSecure:
    manager.secureJar.clear()
    return 0  # 削除数は不明
  of cmIncognito:
    manager.incognitoJar.clear()
    return 0  # 削除数は不明

proc clearDomainCookies*(manager: CookieManager, domain: string): int =
  ## 特定ドメインのクッキーをクリア
  case manager.mode
  of cmBasic:
    return manager.store.removeDomainCookies(domain)
  of cmSecure:
    manager.secureJar.clearDomain(domain)
    return 0  # 削除数は不明
  of cmIncognito:
    manager.incognitoJar.clearDomain(domain)
    return 0  # 削除数は不明

proc cleanupExpiredCookies*(manager: CookieManager): int =
  ## 期限切れクッキーをクリーンアップ
  case manager.mode
  of cmBasic:
    return manager.store.removeExpiredCookies()
  of cmSecure:
    return manager.secureJar.removeExpiredCookies()
  of cmIncognito:
    return manager.incognitoJar.removeExpiredCookies()

proc addCookieBlockPattern*(manager: CookieManager, pattern: string) =
  ## クッキーブロックパターンを追加
  manager.blockMatchers.add(pattern)

proc shouldBlockCookie*(manager: CookieManager, name: string, domain: string): bool =
  ## クッキーをブロックすべきかを判断
  # 名前ベースのブロック
  for pattern in manager.blockMatchers:
    if name.toLowerAscii().contains(pattern.toLowerAscii()):
      return true
  
  # 必要に応じてドメイン・名前・値などに基づくブロック判断を追加
  return false

proc generateCsrfToken*(manager: CookieManager, domain: string): string =
  ## CSRFトークンを生成
  case manager.mode
  of cmBasic:
    # 基本モードでの実装
    return generateCsrfToken()
  of cmSecure:
    return manager.secureJar.generateCsrfToken(domain)
  of cmIncognito:
    return manager.incognitoJar.generateCsrfToken(domain)

proc validateCsrfToken*(manager: CookieManager, domain: string, token: string): bool =
  ## CSRFトークンを検証
  case manager.mode
  of cmBasic:
    # 基本モードでの実装は省略
    return false
  of cmSecure:
    return manager.secureJar.validateCsrfToken(domain, token)
  of cmIncognito:
    return manager.incognitoJar.validateCsrfToken(domain, token)

proc getMetrics*(manager: CookieManager): JsonNode =
  ## クッキー管理のメトリクスを取得
  var cookiesCount = 0
  var domainsCount = 0
  var sessionCookiesCount = 0
  var secureCount = 0
  var httpOnlyCount = 0
  
  case manager.mode
  of cmBasic:
    let stats = manager.store.getStats()
    cookiesCount = stats["total_cookies"].getInt()
    sessionCookiesCount = stats["session_cookies"].getInt()
    secureCount = stats["secure_only"].getInt()
    httpOnlyCount = stats["http_only"].getInt()
    domainsCount = stats["domains_count"].getInt()
    
  of cmSecure, cmIncognito:
    let jar = if manager.mode == cmSecure: manager.secureJar else: manager.incognitoJar
    # Jarのメトリクス収集
    cookiesCount = jar.totalCookieCount()
    # その他メトリクスは近似値または取得不可能
  
  # メトリクス更新
  manager.lastMetricsTime = getTime()
  
  return %*{
    "total_cookies": cookiesCount,
    "domains_count": domainsCount,
    "session_cookies": sessionCookiesCount,
    "persistent_cookies": cookiesCount - sessionCookiesCount,
    "secure_cookies": secureCount,
    "httponly_cookies": httpOnlyCount,
    "timestamp": $manager.lastMetricsTime.toUnix()
  }

proc setSecurityPolicy*(manager: CookieManager, policy: CookieSecurePolicy) =
  ## セキュリティポリシーを設定
  manager.config.securityPolicy = policy
  
  case manager.mode
  of cmBasic:
    manager.store.options.securePolicy = policy
  of cmSecure:
    manager.secureJar.updateSecurityPolicy(policy)
  of cmIncognito:
    # インコグニトモードでは最高セキュリティを維持
    discard

proc setThirdPartyPolicy*(manager: CookieManager, policy: CookieThirdPartyPolicy) =
  ## サードパーティポリシーを設定
  manager.config.thirdPartyPolicy = policy
  
  case manager.mode
  of cmBasic:
    manager.store.options.thirdPartyPolicy = policy
  of cmSecure, cmIncognito:
    # セキュアモードとインコグニトモードでの対応は省略
    discard

proc importCookiesFromNetscape*(manager: CookieManager, text: string): int =
  ## Netscapeフォーマットのクッキーをインポート
  case manager.mode
  of cmBasic:
    return manager.store.importCookiesFromText(text)
  of cmSecure, cmIncognito:
    # Netscape形式からクッキーをパースしてジャーにインポート
    var cookies: seq[Cookie] = @[]
    
    for line in text.splitLines():
      # コメント行と空行をスキップ
      let trimmedLine = line.strip()
      if trimmedLine.len == 0 or trimmedLine.startsWith("#"):
        continue
      
      let fields = trimmedLine.split('\t')
      if fields.len < 7:
        continue  # 不正なフォーマット
      
      # フィールド解析
      let 
        domain = fields[0]
        hostOnly = fields[1] == "FALSE"
        path = fields[2]
        isSecure = fields[3].toUpperAscii == "TRUE"
        expiresStr = fields[4]
        name = fields[5]
        value = fields[6]
      
      var expirationTime: Option[Time]
      
      if expiresStr != "0" and expiresStr != "":
        try:
          # Unix時間としてパース
          let expiresUnix = parseBiggestInt(expiresStr)
          expirationTime = some(fromUnix(expiresUnix))
        except ValueError:
          expirationTime = none(Time)
      else:
        expirationTime = none(Time)  # セッションクッキー
      
      # クッキー作成
      let cookie = newCookie(
        name = name,
        value = value,
        domain = domain,
        path = path,
        expirationTime = expirationTime,
        isSecure = isSecure,
        isHttpOnly = false,  # Netscapeフォーマットには存在しない
        sameSite = ssNone,   # Netscapeフォーマットには存在しない
        source = csImported,
        isHostOnly = hostOnly
      )
      
      cookies.add(cookie)
    
    # 対応するジャーにインポート
    let jar = if manager.mode == cmSecure: manager.secureJar else: manager.incognitoJar
    return jar.importCookies(cookies)

proc createCookieManagerForProfile*(profileName: string, mode: CookieManagerMode = cmSecure): CookieManager =
  ## 特定プロファイル用のクッキーマネージャーを作成
  var config = defaultBrowserCookieConfig()
  config.mode = mode
  config.userDataDir = getTempDir() / "browser_data" / profileName
  
  # プロファイル固有の設定を適用
  if profileName == "private" or mode == cmIncognito:
    config.persistSessionCookies = false
    config.securityPolicy = csRequireSecure
    config.thirdPartyPolicy = tpBlock
  
  return newCookieManager(config) 