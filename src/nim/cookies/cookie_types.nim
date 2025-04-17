# cookie_types.nim
## クッキーの基本型定義と関連機能

import std/[times, options, strutils, uri, tables, hashes]

type
  CookieSameSite* = enum
    ## SameSite 属性の値
    ssNone = "None",      # SameSite制約なし（明示的に指定）
    ssLax = "Lax",        # 緩やかな制約（デフォルト）
    ssStrict = "Strict"   # 厳格な制約

  CookieSecurePolicy* = enum
    ## Secure 属性の処理ポリシー
    csAllowInsecure,      # 非セキュア接続でもクッキーを許可
    csPreferSecure,       # セキュア接続を優先、非セキュアも許可
    csRequireSecure       # セキュア接続のみ許可

  CookieThirdPartyPolicy* = enum
    ## サードパーティクッキーの処理ポリシー
    tpAllow,              # サードパーティクッキーを許可
    tpBlock,              # サードパーティクッキーをブロック
    tpSmartBlock,         # コンテキストに応じて判断（ヒューリスティック）
    tpPrompt              # ユーザーに確認

  CookiePartition* = enum
    ## クッキー分離モード（プライバシー保護用）
    cpNone,               # 分離なし
    cpThirdParty,         # サードパーティコンテキストで分離
    cpAlways              # 常に分離（最高レベルのプライバシー）

  CookieSource* = enum
    ## クッキーの取得元
    csHttpHeader,         # HTTP Set-Cookie ヘッダー
    csJavaScript,         # JavaScript document.cookie
    csImported,           # インポートされたクッキー
    csManuallyAdded,      # 手動追加されたクッキー
    csExtension           # 拡張機能によって設定されたクッキー

  CookieStore* = enum
    ## クッキーの保存先
    stMemory,             # メモリのみ（セッション終了で消失）
    stDisk,               # ディスク（永続的）
    stEncrypted           # 暗号化されたストレージ

  Cookie* = object
    ## クッキーの基本構造
    name*: string         # クッキー名
    value*: string        # クッキー値
    domain*: string       # ドメイン（ドットプレフィックスあり可）
    path*: string         # パス
    creationTime*: Time   # 作成時間
    lastAccessTime*: Time # 最終アクセス時間
    expirationTime*: Option[Time] # 有効期限（Noneはセッションクッキー）
    isSecure*: bool       # Secure属性の有無
    isHttpOnly*: bool     # HttpOnly属性の有無
    sameSite*: CookieSameSite  # SameSite属性
    partitionKey*: Option[string] # パーティションキー（プライバシー分離用）
    source*: CookieSource # 取得元
    isHostOnly*: bool     # ホストオンリーフラグ（サブドメインに送信しない）
    storeType*: CookieStore # 保存先

  CookieMatchCriteria* = object
    ## クッキー検索条件
    name*: Option[string]         # クッキー名
    domain*: Option[string]       # ドメイン
    path*: Option[string]         # パス
    isSecure*: Option[bool]       # Secure属性の有無
    isHttpOnly*: Option[bool]     # HttpOnly属性の有無
    sameSite*: Option[CookieSameSite]  # SameSite属性
    partitionKey*: Option[string] # パーティションキー
    source*: Option[CookieSource] # 取得元

  CookieJar* = object
    ## クッキーコンテナ
    cookies*: Table[string, Cookie]  # 識別子→クッキーのマップ
    maxCookiesPerDomain*: int       # ドメインあたりの最大クッキー数
    maxCookiesTotal*: int           # 全体の最大クッキー数
    maxCookieSizeBytes*: int        # クッキーの最大サイズ（バイト）

# クッキーの識別子生成（内部使用）
proc generateCookieIdentifier*(cookie: Cookie): string =
  ## クッキーの一意識別子を生成
  result = cookie.name & "|" & cookie.domain & "|" & cookie.path
  if cookie.partitionKey.isSome:
    result &= "|" & cookie.partitionKey.get()

proc hash*(cookie: Cookie): Hash =
  ## クッキーのハッシュ値を生成（Table用）
  var h: Hash = 0
  h = h !& hash(cookie.name)
  h = h !& hash(cookie.domain)
  h = h !& hash(cookie.path)
  if cookie.partitionKey.isSome:
    h = h !& hash(cookie.partitionKey.get())
  result = !$h

proc `==`*(a, b: Cookie): bool =
  ## クッキーの等価性比較
  if a.name != b.name or a.domain != b.domain or 
     a.path != b.path:
    return false
  
  if a.partitionKey.isSome and b.partitionKey.isSome:
    return a.partitionKey.get() == b.partitionKey.get()
  elif a.partitionKey.isSome or b.partitionKey.isSome:
    return false
  
  return true

proc newCookie*(
  name, value, domain, path: string,
  expirationTime: Option[Time] = none(Time),
  isSecure = false,
  isHttpOnly = false,
  sameSite = ssLax,
  partitionKey = none(string),
  source = csHttpHeader,
  isHostOnly = false
): Cookie =
  ## 新しいクッキーの作成
  let now = getTime()
  result = Cookie(
    name: name,
    value: value,
    domain: domain,
    path: if path.len == 0: "/" else: path,
    creationTime: now,
    lastAccessTime: now,
    expirationTime: expirationTime,
    isSecure: isSecure,
    isHttpOnly: isHttpOnly,
    sameSite: sameSite,
    partitionKey: partitionKey,
    source: source,
    isHostOnly: isHostOnly,
    storeType: if expirationTime.isSome: stDisk else: stMemory
  )

proc newCookieJar*(
  maxCookiesPerDomain = 50,
  maxCookiesTotal = 1000,
  maxCookieSizeBytes = 4096
): CookieJar =
  ## 新しいクッキーコンテナを作成
  result = CookieJar(
    cookies: initTable[string, Cookie](),
    maxCookiesPerDomain: maxCookiesPerDomain,
    maxCookiesTotal: maxCookiesTotal,
    maxCookieSizeBytes: maxCookieSizeBytes
  )

proc isExpired*(cookie: Cookie): bool =
  ## クッキーが期限切れかどうかを確認
  if cookie.expirationTime.isNone:
    return false  # セッションクッキーは期限切れにならない
  
  return getTime() > cookie.expirationTime.get()

proc isSessionCookie*(cookie: Cookie): bool =
  ## セッションクッキーかどうかを確認
  return cookie.expirationTime.isNone

proc getSizeInBytes*(cookie: Cookie): int =
  ## クッキーのサイズをバイト単位で取得
  result = cookie.name.len + cookie.value.len
  result += cookie.domain.len + cookie.path.len
  # その他のメタデータも加算
  result += 20  # 概算固定オーバーヘッド

proc getExpirationDate*(cookie: Cookie): string =
  ## 有効期限を文字列で取得
  if cookie.expirationTime.isNone:
    return "Session"
  
  return cookie.expirationTime.get().format("yyyy-MM-dd HH:mm:ss")

proc isSecureOnly*(cookie: Cookie): bool =
  ## Secureフラグが設定されているか確認
  return cookie.isSecure

proc shouldPartition*(cookie: Cookie, policy: CookiePartition): bool =
  ## プライバシー分離が必要かどうかを判断
  if policy == cpAlways:
    return true
  elif policy == cpNone:
    return false
  else:  # cpThirdParty
    # パーティションキーが存在する場合は既に分離されている
    return cookie.partitionKey.isSome

proc domainMatches*(cookieDomain, requestDomain: string): bool =
  ## ドメインが一致するかを確認
  if cookieDomain == requestDomain:
    return true
  
  # ドメインの先頭にドットがある場合はサブドメインも含む
  if cookieDomain.startsWith("."):
    return requestDomain.endsWith(cookieDomain[1..^1]) or 
           requestDomain == cookieDomain[1..^1]
  
  return false

proc pathMatches*(cookiePath, requestPath: string): bool =
  ## パスが一致するかを確認
  if cookiePath == requestPath:
    return true
  
  # クッキーのパスが要求パスのプレフィックスであり、
  # パスの最後が / または要求パスの次の文字が / の場合
  return requestPath.startsWith(cookiePath) and
         (cookiePath.endsWith("/") or requestPath.len == cookiePath.len or
          requestPath[cookiePath.len] == '/')

proc isSameOrigin*(url1, url2: Uri): bool =
  ## 同一オリジンチェック
  return url1.scheme == url2.scheme and
         url1.hostname == url2.hostname and
         url1.port == url2.port

proc isSameSitePolicyAllowed*(
  cookie: Cookie, 
  requestUrl, siteUrl: Uri
): bool =
  ## SameSiteポリシーに基づくアクセス許可の判断
  if cookie.sameSite == ssNone:
    return true
  
  if isSameOrigin(requestUrl, siteUrl):
    return true
  
  if cookie.sameSite == ssLax:
    # GETリクエストは緩和されたSameSite Laxポリシーで許可される
    # ここではURIだけで判断できないが、GETと仮定
    return true
  
  # Strictモードではクロスサイト要求で送信しない
  return false 