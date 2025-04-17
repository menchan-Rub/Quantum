# Cookieストアモジュール
# このモジュールはブラウザのCookieストレージを管理します

import std/[
  tables,
  options,
  times,
  json,
  os,
  strutils,
  uri,
  hashes,
  logging,
  sequtils,
  strformat,
  sugar,
  db_sqlite,
  base64,
  asyncdispatch
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, settings, encryption]
import ../../quantum_crypto/encryption as crypto_encrypt
import ../common/base
import ./policy

type
  CookieSameSite* = enum
    ## Cookieの同一サイト属性
    csNone,         # 制限なし
    csLax,          # 緩やかな制限
    csStrict        # 厳格な制限

  CookieSecure* = enum
    ## Cookieのセキュリティ属性
    csecNone,       # セキュア属性なし
    csecSecure      # セキュア属性あり (HTTPS接続のみ)

  StorageLocation* = enum
    ## Cookieストレージの保存場所
    slMemory,       # メモリ内のみ (永続化なし)
    slDisk,         # ディスクに永続化
    slEncrypted     # 暗号化して永続化

  Cookie* = object
    ## Cookie情報
    id*: string                # 一意のID
    name*: string              # Cookie名
    value*: string             # Cookie値
    domain*: string            # ドメイン
    path*: string              # パス
    expirationDate*: Option[DateTime] # 有効期限
    isSession*: bool           # セッションCookieかどうか
    isSecure*: bool            # セキュア属性
    isHttpOnly*: bool          # HttpOnly属性
    sameSite*: CookieSameSite  # 同一サイト属性
    creationTime*: DateTime    # 作成日時
    lastAccessTime*: DateTime  # 最終アクセス日時
    hostOnly*: bool            # ホストのみに制限
    sourceScheme*: string      # ソーススキーム (http/https)
    sourcePort*: int           # ソースポート

  CookieStore* = ref object
    ## Cookieストア
    db*: DbConn                # データベース接続
    memoryStore*: Table[string, Cookie] # メモリ内ストア
    policy*: CookiePolicy      # Cookieポリシー
    location*: StorageLocation # ストレージ場所
    initialized*: bool         # 初期化済みフラグ
    encryptionKey*: string     # 暗号化キー
    sessionOnly*: bool         # セッションCookieのみモード

# 定数
const
  SQLITE_DB_FILE = "cookies.db"
  SCHEMA_VERSION = 1
  MAX_COOKIE_SIZE = 4096      # 最大Cookie値サイズ (バイト)
  MAX_COOKIES_PER_DOMAIN = 50 # ドメインあたりの最大Cookie数

# -----------------------------------------------
# Helper Functions
# -----------------------------------------------

proc generateCookieId(name, domain, path: string): string =
  ## Cookie識別子を生成
  # nameとdomainとpathの組み合わせでユニークなID生成
  result = $hash(name & domain & path)

proc isExpired(cookie: Cookie): bool =
  ## Cookieが有効期限切れかどうかをチェック
  if cookie.isSession:
    return false # セッションCookieは有効期限なし
  
  if cookie.expirationDate.isNone:
    return false # 有効期限未設定
    
  return cookie.expirationDate.get() < now()

proc isCookieValid(cookie: Cookie): bool =
  ## Cookieが有効かどうかをチェック
  if cookie.name.len == 0:
    return false
    
  if cookie.value.len > MAX_COOKIE_SIZE:
    return false
    
  if isExpired(cookie):
    return false
    
  return true

proc domainMatches(cookieDomain, requestDomain: string): bool =
  ## Cookieドメインとリクエストドメインがマッチするかチェック
  # 完全一致
  if cookieDomain == requestDomain:
    return true
    
  # ドットから始まるドメインの場合（.example.com）
  if cookieDomain.startsWith(".") and requestDomain.endsWith(cookieDomain[1..^1]):
    return true
    
  # サブドメインマッチ
  if requestDomain.endsWith("." & cookieDomain):
    return true
    
  return false

proc pathMatches(cookiePath, requestPath: string): bool =
  ## Cookieパスとリクエストパスがマッチするかチェック
  # パスは前方一致
  if requestPath.startsWith(cookiePath):
    # パスが完全一致するか、cookiePathがスラッシュで終わるか、
    # requestPathの次の文字がスラッシュの場合にマッチ
    if requestPath.len == cookiePath.len or 
       cookiePath.endsWith("/") or 
       requestPath[cookiePath.len] == '/':
      return true
  
  return false

proc encryptCookieValue(value, key: string): string =
  ## Cookie値を暗号化
  if value.len == 0 or key.len == 0:
    return value
    
  try:
    result = crypto_encrypt.encryptString(value, key)
  except:
    error "Failed to encrypt cookie value", error_msg = getCurrentExceptionMsg()
    result = value

proc decryptCookieValue(encryptedValue, key: string): string =
  ## 暗号化されたCookie値を復号
  if encryptedValue.len == 0 or key.len == 0:
    return encryptedValue
  
  try:
    result = crypto_encrypt.decryptString(encryptedValue, key)
  except:
    error "Failed to decrypt cookie value", error_msg = getCurrentExceptionMsg()
    result = encryptedValue

# -----------------------------------------------
# CookieStore Implementation
# -----------------------------------------------

proc setupDatabase(self: CookieStore) =
  ## データベーススキーマ初期化
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS cookies (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      value TEXT NOT NULL,
      domain TEXT NOT NULL,
      path TEXT NOT NULL,
      expiration_date INTEGER,
      is_session INTEGER NOT NULL,
      is_secure INTEGER NOT NULL,
      is_http_only INTEGER NOT NULL,
      same_site INTEGER NOT NULL,
      creation_time INTEGER NOT NULL,
      last_access_time INTEGER NOT NULL,
      host_only INTEGER NOT NULL,
      source_scheme TEXT NOT NULL,
      source_port INTEGER NOT NULL,
      is_encrypted INTEGER NOT NULL
    )
  """)
  
  # インデックス作成
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_cookies_domain ON cookies(domain)")
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_cookies_expiration ON cookies(expiration_date)")
  
  # メタデータテーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  
  # バージョン情報設定
  self.db.exec(sql"INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
    "schema_version", $SCHEMA_VERSION)

proc loadCookiesFromDb(self: CookieStore) =
  ## データベースからCookieを読み込み
  let query = sql"""
    SELECT id, name, value, domain, path, expiration_date, is_session, is_secure,
           is_http_only, same_site, creation_time, last_access_time, host_only,
           source_scheme, source_port, is_encrypted
    FROM cookies
    WHERE (expiration_date IS NULL OR expiration_date > ?) OR is_session = 1
  """
  
  let currentTime = now().toTime().toUnix()
  
  for row in self.db.fastRows(query, $currentTime):
    var cookie = Cookie(
      id: row[0],
      name: row[1],
      domain: row[3],
      path: row[4],
      isSession: row[6] == "1",
      isSecure: row[7] == "1",
      isHttpOnly: row[8] == "1",
      sameSite: CookieSameSite(parseInt(row[9])),
      creationTime: fromUnix(parseInt(row[10])),
      lastAccessTime: fromUnix(parseInt(row[11])),
      hostOnly: row[12] == "1",
      sourceScheme: row[13],
      sourcePort: parseInt(row[14])
    )
    
    # 値の復号
    let isEncrypted = row[15] == "1"
    let rawValue = row[2]
    cookie.value = if isEncrypted and self.location == StorageLocation.slEncrypted: 
                    decryptCookieValue(rawValue, self.encryptionKey)
                  else:
                    rawValue
    
    # 有効期限設定
    if not cookie.isSession and row[5] != "":
      cookie.expirationDate = some(fromUnix(parseInt(row[5])))
    
    # メモリストアに追加
    if isCookieValid(cookie):
      self.memoryStore[cookie.id] = cookie

proc saveCookieToDb(self: CookieStore, cookie: Cookie) =
  ## 単一のCookieをデータベースに保存
  if self.location == StorageLocation.slMemory:
    return
  
  # セッションのみモードで、永続化Cookieは保存しない
  if self.sessionOnly and not cookie.isSession:
    return
  
  var 
    expirationUnix: int64 = 0
    shouldEncrypt = self.location == StorageLocation.slEncrypted
    valueToStore = if shouldEncrypt: encryptCookieValue(cookie.value, self.encryptionKey)
                   else: cookie.value
  
  if cookie.expirationDate.isSome:
    expirationUnix = cookie.expirationDate.get().toTime().toUnix()
  
  self.db.exec(sql"""
    INSERT OR REPLACE INTO cookies (
      id, name, value, domain, path, expiration_date, is_session, is_secure,
      is_http_only, same_site, creation_time, last_access_time, host_only,
      source_scheme, source_port, is_encrypted
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """,
    cookie.id,
    cookie.name,
    valueToStore,
    cookie.domain,
    cookie.path,
    if cookie.isSession: nil else: $expirationUnix,
    if cookie.isSession: "1" else: "0",
    if cookie.isSecure: "1" else: "0",
    if cookie.isHttpOnly: "1" else: "0",
    $ord(cookie.sameSite),
    $cookie.creationTime.toTime().toUnix(),
    $cookie.lastAccessTime.toTime().toUnix(),
    if cookie.hostOnly: "1" else: "0",
    cookie.sourceScheme,
    $cookie.sourcePort,
    if shouldEncrypt: "1" else: "0"
  )

proc countCookiesForDomain(self: CookieStore, domain: string): int =
  ## ドメインごとのCookie数をカウント
  result = 0
  for cookie in self.memoryStore.values:
    if cookie.domain == domain:
      inc result

proc newCookieStore*(policy: CookiePolicy, location: StorageLocation = StorageLocation.slDisk, 
                    encryptionKey: string = ""): CookieStore =
  ## 新しいCookieストアを作成
  result = CookieStore(
    memoryStore: initTable[string, Cookie](),
    policy: policy,
    location: location,
    initialized: false,
    encryptionKey: encryptionKey,
    sessionOnly: false
  )
  
  # 暗号化モードで、キーが必要な場合
  if location == StorageLocation.slEncrypted and encryptionKey.len == 0:
    # 暗号化キーがない場合は、ディスクモードに降格
    result.location = StorageLocation.slDisk
    warn "No encryption key provided, falling back to unencrypted disk storage"
  
  if location != StorageLocation.slMemory:
    # データベースに接続
    let dbPath = if getAppDir().len > 0: getAppDir() / SQLITE_DB_FILE
                else: SQLITE_DB_FILE
    
    result.db = open(dbPath, "", "", "")
    
    # スキーマセットアップ
    result.setupDatabase()
    
    # データベースからCookieを読み込み
    result.loadCookiesFromDb()

  result.initialized = true
  info "Cookie store initialized", location = $location, 
       cookie_count = result.memoryStore.len

proc close*(self: CookieStore) =
  ## ストアを閉じる
  if self.db != nil:
    close(self.db)
    info "Cookie store closed"

proc setCookie*(self: CookieStore, name, value, domain, path: string, 
               expirationDate: Option[DateTime] = none(DateTime),
               isSecure: bool = false, isHttpOnly: bool = false,
               sameSite: CookieSameSite = CookieSameSite.csLax,
               sourceScheme: string = "https", sourcePort: int = 443): bool =
  ## Cookieを設定
  # Cookie名と値のバリデーション
  if name.len == 0:
    error "Cannot set cookie with empty name"
    return false
    
  if value.len > MAX_COOKIE_SIZE:
    error "Cookie value too large", name = name, size = value.len, max_size = MAX_COOKIE_SIZE
    return false
  
  # ドメイン制限チェック
  if domain.len == 0:
    error "Cannot set cookie with empty domain"
    return false
  
  # ポリシーチェック - 拒否されるCookieは保存しない
  let action = self.policy.shouldAcceptCookie(name, domain, domain)
  if action == CookieAction.caReject:
    info "Cookie rejected by policy", name = name, domain = domain
    return false
  
  # セッションのみのCookieかどうか判断
  let isSessionCookie = action == CookieAction.caAcceptSession or expirationDate.isNone
  
  # ドメインあたりの最大Cookie数チェック
  if self.countCookiesForDomain(domain) >= MAX_COOKIES_PER_DOMAIN:
    warn "Maximum number of cookies reached for domain", domain = domain, max = MAX_COOKIES_PER_DOMAIN
    
    # 最も古いCookieを削除
    var oldestCookie: Option[Cookie]
    var oldestTime = now()
    
    for cookie in self.memoryStore.values:
      if cookie.domain == domain and cookie.lastAccessTime < oldestTime:
        oldestTime = cookie.lastAccessTime
        oldestCookie = some(cookie)
    
    if oldestCookie.isSome:
      let id = oldestCookie.get().id
      self.memoryStore.del(id)
      
      if self.db != nil and self.location != StorageLocation.slMemory:
        self.db.exec(sql"DELETE FROM cookies WHERE id = ?", id)
        
      info "Removed oldest cookie for domain", domain = domain, cookie_name = oldestCookie.get().name
  
  # Cookieオブジェクト作成
  let cookieId = generateCookieId(name, domain, path)
  let currentTime = now()
  
  let cookie = Cookie(
    id: cookieId,
    name: name,
    value: value,
    domain: domain,
    path: if path.len == 0: "/" else: path,
    expirationDate: if isSessionCookie: none(DateTime) else: expirationDate,
    isSession: isSessionCookie,
    isSecure: isSecure,
    isHttpOnly: isHttpOnly,
    sameSite: sameSite,
    creationTime: if self.memoryStore.hasKey(cookieId): self.memoryStore[cookieId].creationTime else: currentTime,
    lastAccessTime: currentTime,
    hostOnly: not domain.startsWith("."),
    sourceScheme: sourceScheme,
    sourcePort: sourcePort
  )
  
  # メモリに保存
  self.memoryStore[cookieId] = cookie
  
  # データベースに保存（必要な場合）
  if self.location != StorageLocation.slMemory:
    self.saveCookieToDb(cookie)
  
  info "Cookie set", name = name, domain = domain, session_only = isSessionCookie
  return true

proc getCookie*(self: CookieStore, name, domain, path: string): Option[Cookie] =
  ## 指定された名前、ドメイン、パスのCookieを取得
  let cookieId = generateCookieId(name, domain, path)
  
  if self.memoryStore.hasKey(cookieId):
    let cookie = self.memoryStore[cookieId]
    
    # 有効期限チェック
    if isExpired(cookie):
      self.memoryStore.del(cookieId)
      if self.db != nil and self.location != StorageLocation.slMemory:
        self.db.exec(sql"DELETE FROM cookies WHERE id = ?", cookieId)
      return none(Cookie)
    
    # 最終アクセス時間更新
    var updatedCookie = cookie
    updatedCookie.lastAccessTime = now()
    self.memoryStore[cookieId] = updatedCookie
    
    # DBも更新（必要な場合）
    if self.location != StorageLocation.slMemory:
      self.db.exec(sql"UPDATE cookies SET last_access_time = ? WHERE id = ?",
        $updatedCookie.lastAccessTime.toTime().toUnix(), cookieId)
    
    return some(updatedCookie)
  
  return none(Cookie)

proc getCookiesForUrl*(self: CookieStore, url: string): seq[Cookie] =
  ## 指定URLに関連するすべてのCookieを取得
  result = @[]
  let uri = parseUri(url)
  
  # ホスト名とパスが必要
  if uri.hostname.len == 0:
    return result
  
  let 
    host = uri.hostname
    path = if uri.path.len == 0: "/" else: uri.path
    scheme = uri.scheme
    isSecure = scheme == "https"
  
  for cookie in self.memoryStore.values:
    # 有効期限チェック
    if isExpired(cookie):
      self.memoryStore.del(cookie.id)
      if self.db != nil and self.location != StorageLocation.slMemory:
        self.db.exec(sql"DELETE FROM cookies WHERE id = ?", cookie.id)
      continue
    
    # セキュアCookieはHTTPSでのみ送信可能
    if cookie.isSecure and not isSecure:
      continue
    
    # ドメインマッチチェック
    if not domainMatches(cookie.domain, host):
      continue
    
    # パスマッチチェック
    if not pathMatches(cookie.path, path):
      continue
    
    # 最終アクセス時間更新
    var updatedCookie = cookie
    updatedCookie.lastAccessTime = now()
    self.memoryStore[cookie.id] = updatedCookie
    
    # DBも更新（必要な場合）
    if self.location != StorageLocation.slMemory:
      self.db.exec(sql"UPDATE cookies SET last_access_time = ? WHERE id = ?",
        $updatedCookie.lastAccessTime.toTime().toUnix(), cookie.id)
    
    result.add(updatedCookie)

proc deleteCookie*(self: CookieStore, name, domain, path: string): bool =
  ## 指定された名前、ドメイン、パスのCookieを削除
  let cookieId = generateCookieId(name, domain, path)
  
  if self.memoryStore.hasKey(cookieId):
    self.memoryStore.del(cookieId)
    
    if self.db != nil and self.location != StorageLocation.slMemory:
      self.db.exec(sql"DELETE FROM cookies WHERE id = ?", cookieId)
    
    info "Cookie deleted", name = name, domain = domain
    return true
  
  return false

proc deleteAllCookies*(self: CookieStore) =
  ## すべてのCookieを削除
  self.memoryStore.clear()
  
  if self.db != nil and self.location != StorageLocation.slMemory:
    self.db.exec(sql"DELETE FROM cookies")
  
  info "All cookies deleted"

proc deleteCookiesForDomain*(self: CookieStore, domain: string): int =
  ## 指定ドメインのすべてのCookieを削除し、削除数を返す
  var count = 0
  
  # 削除すべきIDを集める
  var cookieIdsToDelete: seq[string] = @[]
  for cookie in self.memoryStore.values:
    if domainMatches(cookie.domain, domain):
      cookieIdsToDelete.add(cookie.id)
      inc count
  
  # メモリから削除
  for id in cookieIdsToDelete:
    self.memoryStore.del(id)
  
  # データベースからも削除（必要な場合）
  if count > 0 and self.db != nil and self.location != StorageLocation.slMemory:
    # 正確なドメインマッチングはSQLでは難しいので、IDベースで削除
    for id in cookieIdsToDelete:
      self.db.exec(sql"DELETE FROM cookies WHERE id = ?", id)
  
  info "Deleted cookies for domain", domain = domain, count = count
  return count

proc deleteExpiredCookies*(self: CookieStore): int =
  ## 有効期限切れのCookieを削除し、削除数を返す
  let currentTime = now()
  var count = 0
  
  # 削除すべきIDを集める
  var cookieIdsToDelete: seq[string] = @[]
  for cookie in self.memoryStore.values:
    if isExpired(cookie):
      cookieIdsToDelete.add(cookie.id)
      inc count
  
  # メモリから削除
  for id in cookieIdsToDelete:
    self.memoryStore.del(id)
  
  # データベースからも削除（必要な場合）
  if count > 0 and self.db != nil and self.location != StorageLocation.slMemory:
    self.db.exec(sql"""
      DELETE FROM cookies 
      WHERE is_session = 0 AND expiration_date IS NOT NULL AND expiration_date < ?
    """, $currentTime.toTime().toUnix())
  
  info "Deleted expired cookies", count = count
  return count

proc setSessionOnlyMode*(self: CookieStore, enabled: bool) =
  ## セッションのみモードを設定（永続Cookieを保存しない）
  self.sessionOnly = enabled
  info "Session-only mode", enabled = enabled

# -----------------------------------------------
# Cookie String Handling
# -----------------------------------------------

proc parseSetCookieHeader*(header: string): Option[Cookie] =
  ## Set-CookieヘッダーをパースしてCookieオブジェクトに変換
  if header.len == 0:
    return none(Cookie)
  
  var 
    parts = header.split(';')
    nameValue = parts[0].strip().split('=', 1)
  
  if nameValue.len < 2:
    warn "Invalid Set-Cookie header format", header = header
    return none(Cookie)
  
  let
    name = nameValue[0].strip()
    value = nameValue[1].strip()
  
  var cookie = Cookie(
    id: "", # 後で設定
    name: name,
    value: value,
    domain: "",
    path: "/",
    isSession: true,
    isSecure: false,
    isHttpOnly: false,
    sameSite: CookieSameSite.csLax,
    creationTime: now(),
    lastAccessTime: now(),
    hostOnly: true,
    sourceScheme: "https",
    sourcePort: 443
  )
  
  for i in 1..<parts.len:
    let attr = parts[i].strip().split('=', 1)
    let attrName = if attr.len > 0: attr[0].strip().toLowerAscii() else: ""
    let attrValue = if attr.len > 1: attr[1].strip() else: ""
    
    case attrName:
      of "expires":
        try:
          # 日付形式変換
          let expTime = times.parse(attrValue, "ddd, dd MMM yyyy HH:mm:ss 'GMT'")
          cookie.expirationDate = some(expTime)
          cookie.isSession = false
        except:
          warn "Failed to parse cookie expiration date", date = attrValue
      
      of "max-age":
        try:
          let seconds = parseInt(attrValue)
          cookie.expirationDate = some(now() + seconds.seconds)
          cookie.isSession = false
        except:
          warn "Failed to parse max-age value", value = attrValue
      
      of "domain":
        var domain = attrValue
        if domain.len > 0:
          # 先頭のドットは省略可能
          if not domain.startsWith("."):
            domain = "." & domain
          cookie.domain = domain
          cookie.hostOnly = false
      
      of "path":
        if attrValue.len > 0:
          cookie.path = attrValue
      
      of "secure":
        cookie.isSecure = true
      
      of "httponly":
        cookie.isHttpOnly = true
      
      of "samesite":
        case attrValue.toLowerAscii():
          of "strict":
            cookie.sameSite = CookieSameSite.csStrict
          of "lax":
            cookie.sameSite = CookieSameSite.csLax
          of "none":
            cookie.sameSite = CookieSameSite.csNone
          else:
            cookie.sameSite = CookieSameSite.csLax
  
  return some(cookie)

proc formatCookieHeader*(cookies: seq[Cookie]): string =
  ## CookieシーケンスをHTTPリクエストヘッダー形式に変換
  if cookies.len == 0:
    return ""
  
  var parts: seq[string] = @[]
  for cookie in cookies:
    parts.add(cookie.name & "=" & cookie.value)
  
  return parts.join("; ")

# -----------------------------------------------
# Async Interface
# -----------------------------------------------

proc getCookieAsync*(self: CookieStore, name, domain, path: string): Future[Option[Cookie]] {.async.} =
  ## 非同期でCookieを取得
  return self.getCookie(name, domain, path)

proc getCookiesForUrlAsync*(self: CookieStore, url: string): Future[seq[Cookie]] {.async.} =
  ## 非同期で指定URLのCookieを取得
  return self.getCookiesForUrl(url)

proc setCookieAsync*(self: CookieStore, name, value, domain, path: string, 
                    expirationDate: Option[DateTime] = none(DateTime),
                    isSecure: bool = false, isHttpOnly: bool = false,
                    sameSite: CookieSameSite = CookieSameSite.csLax,
                    sourceScheme: string = "https", sourcePort: int = 443): Future[bool] {.async.} =
  ## 非同期でCookieを設定
  return self.setCookie(name, value, domain, path, expirationDate, isSecure,
                      isHttpOnly, sameSite, sourceScheme, sourcePort)

proc deleteCookieAsync*(self: CookieStore, name, domain, path: string): Future[bool] {.async.} =
  ## 非同期でCookieを削除
  return self.deleteCookie(name, domain, path)

proc cleanupTask*(self: CookieStore) {.async.} =
  ## 有効期限切れCookieの定期クリーンアップタスク
  while true:
    # 1時間ごとに実行
    await sleepAsync(60 * 60 * 1000)
    discard self.deleteExpiredCookies()

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード - 実際のアプリケーションでは以下のコードは削除される
  
  proc testCookieStore() =
    # テスト用のポリシー作成
    let policy = newCookiePolicy()
    
    # Cookieストア初期化
    let store = newCookieStore(policy, StorageLocation.slMemory)
    
    # Cookieをいくつか設定
    discard store.setCookie("test1", "value1", "example.com", "/")
    discard store.setCookie("test2", "value2", "example.com", "/", some(now() + 1.days))
    discard store.setCookie("test3", "value3", "sub.example.com", "/blog", some(now() + 7.days))
    
    # Cookieを取得
    let cookie1 = store.getCookie("test1", "example.com", "/")
    if cookie1.isSome:
      echo "Found cookie: ", cookie1.get().name, " = ", cookie1.get().value
    
    # URLに関連するCookieを取得
    let cookies = store.getCookiesForUrl("https://example.com/index.html")
    echo "Cookies for URL: ", cookies.len
    for c in cookies:
      echo "  ", c.name, " = ", c.value
    
    # Set-Cookieヘッダーをパース
    let headerVal = "sessionid=abc123; Path=/; Domain=example.com; Secure; HttpOnly; SameSite=Strict; Max-Age=3600"
    let parsedCookie = parseSetCookieHeader(headerVal)
    if parsedCookie.isSome:
      let c = parsedCookie.get()
      echo "Parsed cookie from header: ", c.name, " = ", c.value
      echo "  Domain: ", c.domain
      echo "  Path: ", c.path
      echo "  Secure: ", c.isSecure
      echo "  HttpOnly: ", c.isHttpOnly
      echo "  SameSite: ", c.sameSite
      
      if c.expirationDate.isSome:
        echo "  Expires: ", c.expirationDate.get()
    
    # Cookieを削除
    discard store.deleteCookie("test1", "example.com", "/")
    
    # 全Cookieを削除
    store.deleteAllCookies()
    
    store.close()
  
  when isMainModule:
    testCookieStore() 