# cookie_store.nim
## クッキーストレージ管理モジュール

import std/[os, times, options, json, tables, sets, strutils, uri, hashes, algorithm, logging]
import ../cookie_types

const
  # クッキーファイル関連の定数
  COOKIES_DIR = "cookies"
  COOKIES_DB_FILE = "cookies.json"
  COOKIES_DB_BACKUP = "cookies.json.bak"
  
  # 有効期限関連
  CLEANUP_INTERVAL = initDuration(hours = 24) # 24時間ごとのクリーンアップ
  EXPIRE_IMMEDIATE_THRESHOLD = 10 # n秒以内の有効期限はすぐに削除

type
  CookieStoreOptions* = object
    ## クッキーストアの設定オプション
    userDataDir*: string               # ユーザーデータディレクトリ
    encryptionEnabled*: bool           # 暗号化機能の有効化
    cookiesPerDomainLimit*: int        # ドメインあたりのクッキー上限
    totalCookiesLimit*: int            # 全体のクッキー上限
    maxCookieSizeBytes*: int           # クッキーの最大サイズ
    cleanupInterval*: Duration         # 定期クリーンアップの間隔
    persistSessionCookies*: bool       # セッションクッキーも永続化するか
    thirdPartyPolicy*: CookieThirdPartyPolicy # サードパーティクッキーポリシー
    securePolicy*: CookieSecurePolicy  # セキュアポリシー
    partitioningPolicy*: CookiePartition # パーティショニングポリシー

  CookieStore* = ref object
    ## クッキーストアオブジェクト
    options*: CookieStoreOptions       # 設定オプション
    jar*: CookieJar                    # クッキーコンテナ
    domainCookieCounts*: Table[string, int] # ドメイン別クッキー数カウンタ
    lastCleanupTime*: Time             # 最後のクリーンアップ時間
    cookiesChanged*: bool              # 変更フラグ（保存判断用）
    logger*: Logger                    # ロガー

# デフォルトのクッキーストアオプション
proc newCookieStoreOptions*(
  userDataDir = getTempDir() / "browser_data",
  encryptionEnabled = true,
  cookiesPerDomainLimit = 50,
  totalCookiesLimit = 3000,
  maxCookieSizeBytes = 4096,
  cleanupInterval = CLEANUP_INTERVAL,
  persistSessionCookies = false,
  thirdPartyPolicy = tpSmartBlock,
  securePolicy = csPreferSecure,
  partitioningPolicy = cpThirdParty
): CookieStoreOptions =
  ## デフォルトのクッキーストアオプションを作成
  result = CookieStoreOptions(
    userDataDir: userDataDir,
    encryptionEnabled: encryptionEnabled,
    cookiesPerDomainLimit: cookiesPerDomainLimit,
    totalCookiesLimit: totalCookiesLimit,
    maxCookieSizeBytes: maxCookieSizeBytes,
    cleanupInterval: cleanupInterval,
    persistSessionCookies: persistSessionCookies,
    thirdPartyPolicy: thirdPartyPolicy,
    securePolicy: securePolicy,
    partitioningPolicy: partitioningPolicy
  )

# クッキーストアの新規作成
proc newCookieStore*(options = newCookieStoreOptions()): CookieStore =
  ## 新しいクッキーストアを作成
  new(result)
  result.options = options
  result.jar = newCookieJar(
    maxCookiesPerDomain = options.cookiesPerDomainLimit,
    maxCookiesTotal = options.totalCookiesLimit,
    maxCookieSizeBytes = options.maxCookieSizeBytes
  )
  result.domainCookieCounts = initTable[string, int]()
  result.lastCleanupTime = getTime()
  result.cookiesChanged = false
  result.logger = newConsoleLogger()

# クッキーをJSONに変換
proc cookieToJson(cookie: Cookie): JsonNode =
  ## クッキーをJSON形式に変換
  result = %*{
    "name": cookie.name,
    "value": cookie.value,
    "domain": cookie.domain,
    "path": cookie.path,
    "creation_time": $cookie.creationTime.toUnix(),
    "last_access_time": $cookie.lastAccessTime.toUnix(),
    "is_secure": cookie.isSecure,
    "is_http_only": cookie.isHttpOnly,
    "same_site": $cookie.sameSite,
    "source": $cookie.source,
    "is_host_only": cookie.isHostOnly,
    "store_type": $cookie.storeType
  }
  
  # オプション項目
  if cookie.expirationTime.isSome:
    result["expiration_time"] = %($cookie.expirationTime.get().toUnix())
  
  if cookie.partitionKey.isSome:
    result["partition_key"] = %(cookie.partitionKey.get())

# JSONからクッキーを復元
proc jsonToCookie(jsonNode: JsonNode): Cookie =
  ## JSON形式からクッキーを復元
  
  # 必須項目
  result = Cookie(
    name: jsonNode["name"].getStr(),
    value: jsonNode["value"].getStr(),
    domain: jsonNode["domain"].getStr(),
    path: jsonNode["path"].getStr(),
    creationTime: fromUnix(jsonNode["creation_time"].getStr().parseBiggestInt()),
    lastAccessTime: fromUnix(jsonNode["last_access_time"].getStr().parseBiggestInt()),
    isSecure: jsonNode["is_secure"].getBool(),
    isHttpOnly: jsonNode["is_http_only"].getBool(),
    sameSite: parseEnum[CookieSameSite](jsonNode["same_site"].getStr()),
    source: parseEnum[CookieSource](jsonNode["source"].getStr()),
    isHostOnly: jsonNode["is_host_only"].getBool(),
    storeType: parseEnum[CookieStore](jsonNode["store_type"].getStr())
  )
  
  # オプション項目
  if jsonNode.hasKey("expiration_time"):
    let expTimeUnix = jsonNode["expiration_time"].getStr().parseBiggestInt()
    result.expirationTime = some(fromUnix(expTimeUnix))
  else:
    result.expirationTime = none(Time)
  
  if jsonNode.hasKey("partition_key"):
    result.partitionKey = some(jsonNode["partition_key"].getStr())
  else:
    result.partitionKey = none(string)

# ストレージディレクトリを確保
proc ensureStorageDirectory(store: CookieStore): bool =
  ## ストレージディレクトリが存在することを確認し、必要なら作成
  let cookiesDir = store.options.userDataDir / COOKIES_DIR
  try:
    if not dirExists(cookiesDir):
      createDir(cookiesDir)
    return true
  except OSError as e:
    store.logger.error("クッキーディレクトリの作成に失敗: " & e.msg)
    return false

# クッキーの保存
proc saveCookies*(store: CookieStore): bool =
  ## 現在のクッキーをディスクに保存
  if not store.cookiesChanged:
    return true  # 変更がなければ何もしない

  if not ensureStorageDirectory(store):
    return false

  let cookiesFile = store.options.userDataDir / COOKIES_DIR / COOKIES_DB_FILE
  let backupFile = store.options.userDataDir / COOKIES_DIR / COOKIES_DB_BACKUP
  
  # バックアップ作成（既存ファイルがある場合）
  if fileExists(cookiesFile):
    try:
      copyFile(cookiesFile, backupFile)
    except OSError:
      store.logger.warn("クッキーバックアップの作成に失敗")
  
  var cookiesArray = newJArray()
  
  # 期限切れでないクッキーとセッションクッキーを保存
  for cookie in store.jar.cookies.values:
    # セッションクッキーは設定に応じて永続化
    if cookie.isSessionCookie() and not store.options.persistSessionCookies:
      continue
    
    # 既に期限切れのクッキーはスキップ
    if not cookie.isSessionCookie() and cookie.isExpired():
      continue
    
    cookiesArray.add(cookieToJson(cookie))
  
  let jsonData = %*{
    "version": 1,
    "cookies": cookiesArray
  }
  
  try:
    writeFile(cookiesFile, pretty(jsonData))
    store.cookiesChanged = false
    return true
  except IOError as e:
    store.logger.error("クッキーの保存に失敗: " & e.msg)
    return false

# クッキーの読み込み
proc loadCookies*(store: CookieStore): bool =
  ## ディスクからクッキーを読み込む
  let cookiesFile = store.options.userDataDir / COOKIES_DIR / COOKIES_DB_FILE
  
  if not fileExists(cookiesFile):
    return true  # ファイルがなければ読み込み成功と見なす
  
  try:
    let jsonContent = parseFile(cookiesFile)
    
    if not jsonContent.hasKey("cookies"):
      store.logger.warn("クッキーJSONに 'cookies' キーがありません")
      return false
    
    # クッキーデータ読み込み
    let cookiesArray = jsonContent["cookies"]
    if cookiesArray.kind != JArray:
      store.logger.warn("クッキーデータが配列ではありません")
      return false
    
    # ドメインカウンターの初期化
    store.domainCookieCounts.clear()
    
    # クッキー読み込み
    for jsonCookie in cookiesArray:
      let cookie = jsonToCookie(jsonCookie)
      
      # 期限切れかチェック
      if not cookie.isSessionCookie() and cookie.isExpired():
        continue
      
      # ドメインカウント更新
      let domain = cookie.domain
      if not store.domainCookieCounts.hasKey(domain):
        store.domainCookieCounts[domain] = 0
      store.domainCookieCounts[domain] += 1
      
      # クッキーをJarに追加
      let identifier = generateCookieIdentifier(cookie)
      store.jar.cookies[identifier] = cookie
    
    return true
  except JsonParsingError as e:
    store.logger.error("クッキーJSONの解析に失敗: " & e.msg)
    return false
  except IOError as e:
    store.logger.error("クッキーファイルの読み込みに失敗: " & e.msg)
    return false
  except Exception as e:
    store.logger.error("クッキー読み込み中に未知のエラー: " & e.msg)
    return false

# クッキーの追加
proc addCookie*(store: CookieStore, cookie: Cookie): bool =
  ## クッキーを追加
  # クッキーサイズのチェック
  if cookie.getSizeInBytes() > store.options.maxCookieSizeBytes:
    store.logger.warn("クッキーサイズ超過: " & cookie.name)
    return false
  
  # 期限切れチェック
  if not cookie.isSessionCookie():
    if cookie.isExpired():
      store.logger.debug("期限切れクッキーは無視: " & cookie.name)
      return false
    
    # 即時有効期限切れのクッキー（数秒以内に期限切れ）を無視
    let now = getTime()
    let remainingSecs = (cookie.expirationTime.get() - now).inSeconds
    if remainingSecs <= EXPIRE_IMMEDIATE_THRESHOLD:
      store.logger.debug("即時期限切れクッキーは無視: " & cookie.name)
      return false
  
  # ドメイン別クッキー数の制限確認
  if not store.domainCookieCounts.hasKey(cookie.domain):
    store.domainCookieCounts[cookie.domain] = 0
  
  if store.domainCookieCounts[cookie.domain] >= store.options.cookiesPerDomainLimit:
    store.logger.warn("ドメインあたりのクッキー上限到達: " & cookie.domain)
    # 最も古いクッキーを削除して空きを作る
    var oldestCookie: Option[Cookie]
    var oldestTime = now
    var oldestId = ""
    
    for id, existingCookie in store.jar.cookies:
      if existingCookie.domain == cookie.domain:
        if existingCookie.lastAccessTime < oldestTime:
          oldestTime = existingCookie.lastAccessTime
          oldestCookie = some(existingCookie)
          oldestId = id
    
    if oldestCookie.isSome:
      store.jar.cookies.del(oldestId)
      store.domainCookieCounts[cookie.domain] -= 1
      store.logger.debug("最も古いクッキーを削除: " & oldestCookie.get().name)
    else:
      return false
  
  # 全体のクッキー数制限確認
  if store.jar.cookies.len >= store.options.totalCookiesLimit:
    store.logger.warn("全体のクッキー上限到達")
    return false
  
  # クッキーを追加/更新
  let identifier = generateCookieIdentifier(cookie)
  let isUpdate = store.jar.cookies.hasKey(identifier)
  
  if isUpdate:
    # 既存のクッキーを更新の場合はカウント変更不要
    store.jar.cookies[identifier] = cookie
  else:
    # 新規追加の場合はカウント増加
    store.jar.cookies[identifier] = cookie
    store.domainCookieCounts[cookie.domain] += 1
  
  store.cookiesChanged = true
  
  # セッションクッキーでない場合または設定により永続化する場合は保存
  if not cookie.isSessionCookie() or store.options.persistSessionCookies:
    discard store.saveCookies()
  
  return true

# クッキーの取得
proc getCookies*(store: CookieStore, url: Uri, firstPartyUrl: Option[Uri] = none(Uri)): seq[Cookie] =
  ## 指定URLに送信可能なクッキーを取得
  let isSecure = url.scheme == "https"
  let hostname = url.hostname
  let path = if url.path == "": "/" else: url.path
  
  result = @[]
  
  # 期限切れクッキーの自動クリーンアップ
  if getTime() - store.lastCleanupTime > store.options.cleanupInterval:
    discard store.removeCookiesIf(proc(c: Cookie): bool = c.isExpired())
    store.lastCleanupTime = getTime()
  
  # 各クッキーを確認
  for cookie in store.jar.cookies.values:
    # ドメイン一致チェック
    if not domainMatches(cookie.domain, hostname):
      continue
    
    # パス一致チェック
    if not pathMatches(cookie.path, path):
      continue
    
    # Secureフラグチェック - セキュア接続時のみ送信
    if cookie.isSecure and not isSecure:
      continue
    
    # 期限切れチェック
    if not cookie.isSessionCookie() and cookie.isExpired():
      continue
    
    # サードパーティチェック
    if firstPartyUrl.isSome:
      let isSameParty = (url.hostname == firstPartyUrl.get().hostname) or
                         domainMatches("." & url.hostname, firstPartyUrl.get().hostname) or
                         domainMatches("." & firstPartyUrl.get().hostname, url.hostname)
      
      # サードパーティーポリシーの適用
      if not isSameParty:
        case store.options.thirdPartyPolicy
        of tpBlock:
          continue  # サードパーティクッキーをブロック
        of tpSmartBlock:
          # スマートブロック: HttpOnlyまたはSecureでないサードパーティクッキーをブロック
          if not (cookie.isHttpOnly or cookie.isSecure):
            continue
        of tpPrompt:
          # ここではブロックする。実際の実装ではUI側でプロンプト表示
          continue
        of tpAllow:
          # 許可 - 何もしない
          discard
    
    # SameSiteポリシーチェック
    if firstPartyUrl.isSome:
      if not isSameSitePolicyAllowed(cookie, url, firstPartyUrl.get()):
        continue
    
    # すべての条件を満たしたクッキーを結果に追加
    result.add(cookie)
    
    # 最終アクセス時間を更新
    var updatedCookie = cookie
    updatedCookie.lastAccessTime = getTime()
    let identifier = generateCookieIdentifier(cookie)
    store.jar.cookies[identifier] = updatedCookie
    store.cookiesChanged = true
  
  # パスでソート（長いパスが先）
  result.sort(proc (x, y: Cookie): int =
    # 同じパスの場合は作成日時が古い方が先
    if x.path == y.path:
      return cmp(x.creationTime, y.creationTime)
    # パスの長さで降順ソート
    return cmp(y.path.len, x.path.len)
  )

# 条件に一致するクッキーの削除
proc removeCookiesIf*(store: CookieStore, predicate: proc(cookie: Cookie): bool): int =
  ## 条件に一致するクッキーを削除し、削除数を返す
  var toRemove: seq[string] = @[]
  
  # 削除対象を特定
  for id, cookie in store.jar.cookies:
    if predicate(cookie):
      toRemove.add(id)
  
  # 削除実行
  for id in toRemove:
    let cookie = store.jar.cookies[id]
    store.domainCookieCounts[cookie.domain] -= 1
    store.jar.cookies.del(id)
  
  # ドメインカウントがゼロになったエントリを削除
  var emptyDomains: seq[string] = @[]
  for domain, count in store.domainCookieCounts:
    if count <= 0:
      emptyDomains.add(domain)
  
  for domain in emptyDomains:
    store.domainCookieCounts.del(domain)
  
  if toRemove.len > 0:
    store.cookiesChanged = true
    discard store.saveCookies()
  
  return toRemove.len

# 期限切れクッキーの削除
proc removeExpiredCookies*(store: CookieStore): int =
  ## すべての期限切れクッキーを削除し、削除数を返す
  return store.removeCookiesIf(proc(c: Cookie): bool = c.isExpired())

# ドメインのクッキーを削除
proc removeDomainCookies*(store: CookieStore, domain: string): int =
  ## 指定ドメインのすべてのクッキーを削除
  return store.removeCookiesIf(proc(c: Cookie): bool =
    domainMatches(c.domain, domain) or
    domainMatches(domain, c.domain)
  )

# クッキーの削除
proc removeCookie*(store: CookieStore, cookie: Cookie): bool =
  ## 特定のクッキーを削除
  let id = generateCookieIdentifier(cookie)
  if store.jar.cookies.hasKey(id):
    let existingCookie = store.jar.cookies[id]
    store.domainCookieCounts[existingCookie.domain] -= 1
    store.jar.cookies.del(id)
    store.cookiesChanged = true
    
    # ドメインカウントがゼロになったらエントリを削除
    if store.domainCookieCounts[existingCookie.domain] <= 0:
      store.domainCookieCounts.del(existingCookie.domain)
    
    discard store.saveCookies()
    return true
  
  return false

# 検索条件に一致するクッキー取得
proc findCookies*(store: CookieStore, criteria: CookieMatchCriteria): seq[Cookie] =
  ## 検索条件に一致するクッキーを取得
  result = @[]
  
  for cookie in store.jar.cookies.values:
    # 各条件をチェック（Optionが設定されている場合のみ）
    if criteria.name.isSome and cookie.name != criteria.name.get():
      continue
    
    if criteria.domain.isSome:
      if not (cookie.domain == criteria.domain.get() or 
              domainMatches(cookie.domain, criteria.domain.get()) or
              domainMatches(criteria.domain.get(), cookie.domain)):
        continue
    
    if criteria.path.isSome and cookie.path != criteria.path.get():
      continue
    
    if criteria.isSecure.isSome and cookie.isSecure != criteria.isSecure.get():
      continue
    
    if criteria.isHttpOnly.isSome and cookie.isHttpOnly != criteria.isHttpOnly.get():
      continue
    
    if criteria.sameSite.isSome and cookie.sameSite != criteria.sameSite.get():
      continue
    
    if criteria.partitionKey.isSome:
      if cookie.partitionKey.isNone or 
         cookie.partitionKey.get() != criteria.partitionKey.get():
        continue
    
    if criteria.source.isSome and cookie.source != criteria.source.get():
      continue
    
    # 期限切れクッキーはスキップ
    if not cookie.isSessionCookie() and cookie.isExpired():
      continue
    
    result.add(cookie)

# 統計情報
proc getStats*(store: CookieStore): JsonNode =
  ## クッキーストアの統計情報を取得
  var totalCookies = 0
  var sessionCookies = 0
  var secureOnly = 0
  var httpOnly = 0
  var domainsCount = 0
  
  for cookie in store.jar.cookies.values:
    inc totalCookies
    if cookie.isSessionCookie():
      inc sessionCookies
    if cookie.isSecure:
      inc secureOnly
    if cookie.isHttpOnly:
      inc httpOnly
  
  domainsCount = store.domainCookieCounts.len
  
  result = %*{
    "total_cookies": totalCookies,
    "session_cookies": sessionCookies,
    "persistent_cookies": totalCookies - sessionCookies,
    "secure_only": secureOnly,
    "http_only": httpOnly,
    "domains_count": domainsCount
  }

# プロパティ設定
proc setMaxCookiesPerDomain*(store: CookieStore, limit: int) =
  ## ドメインあたりの最大クッキー数を設定
  if limit > 0:
    store.options.cookiesPerDomainLimit = limit
    store.jar.maxCookiesPerDomain = limit

# 全クッキー削除
proc clearAllCookies*(store: CookieStore): int =
  ## すべてのクッキーを削除
  let count = store.jar.cookies.len
  store.jar.cookies.clear()
  store.domainCookieCounts.clear()
  store.cookiesChanged = true
  discard store.saveCookies()
  return count

# クッキーのインポート (NetscapeフォーマットCSV/テキスト)
proc importCookiesFromText*(store: CookieStore, text: string): int =
  ## Netscapeフォーマットのクッキーテキストをインポート
  ## 形式: domain	flag	path	secure	expiration	name	value
  var count = 0
  
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
    
    # ストアに追加
    if store.addCookie(cookie):
      inc count
  
  return count 