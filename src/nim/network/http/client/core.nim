import std/[asyncdispatch, httpclient, httpcore, tables, strutils, uri, options, times, 
         streams, net, os, logging, json, parseutils, strformat, unicode, random, 
         math, sequtils, algorithm, deques, base64, sha1, md5]
import ../../dns/resolver
import ../utils

type
  HttpClientCore* = ref object
    client*: AsyncHttpClient
    headers*: HttpHeaders
    cookies*: CookieJar
    proxy*: Proxy
    timeout*: int
    followRedirects*: bool
    maxRedirects*: int
    sslContext*: SslContext
    userAgent*: string
    connections*: Table[string, seq[AsyncSocket]]
    dnsCache*: Table[string, DnsCacheEntry]
    stats*: ClientStats
    rateLimiter*: RateLimiter
    logger*: Logger

  DnsCacheEntry* = object
    ips*: seq[string]
    expiry*: Time

  ClientStats* = object
    requestsSent*: int
    bytesDownloaded*: int64
    bytesUploaded*: int64
    requestTimes*: seq[Duration]
    statusCodes*: Table[int, int]

  RateLimiter* = object
    requestsPerSecond*: float
    lastRequests*: Deque[Time]
    domainLimits*: Table[string, float]
    domainLastRequests*: Table[string, Deque[Time]]

  RequestOptions* = object
    headers*: HttpHeaders
    body*: string
    timeout*: int
    proxy*: Proxy
    followRedirects*: bool
    maxRedirects*: int
    sslContext*: SslContext
    validateSsl*: bool
    userAgent*: string
    retries*: int
    retryDelay*: int
    cacheControl*: string
    priority*: RequestPriority

  RequestPriority* = enum
    rpLow, rpNormal, rpHigh, rpCritical

  Proxy* = object
    url*: string
    auth*: Option[tuple[username, password: string]]

proc newHttpClientCore*(): HttpClientCore =
  ## 新しいHTTPクライアントコアオブジェクトを作成
  result = HttpClientCore()
  result.client = newAsyncHttpClient()
  result.headers = newHttpHeaders()
  result.cookies = newCookieJar()
  result.followRedirects = true
  result.maxRedirects = 10
  result.timeout = 30000  # 30秒
  result.userAgent = "Nim HTTP Client/1.0"
  result.connections = initTable[string, seq[AsyncSocket]]()
  result.dnsCache = initTable[string, DnsCacheEntry]()
  result.stats = ClientStats()
  result.stats.statusCodes = initTable[int, int]()
  result.rateLimiter = RateLimiter()
  result.rateLimiter.requestsPerSecond = 10.0
  result.rateLimiter.lastRequests = initDeque[Time]()
  result.rateLimiter.domainLimits = initTable[string, float]()
  result.rateLimiter.domainLastRequests = initTable[string, Deque[Time]]()
  result.logger = newConsoleLogger()

proc addDefaultHeader*(client: HttpClientCore, key, value: string) =
  ## デフォルトヘッダーを追加
  client.headers[key] = value

proc setUserAgent*(client: HttpClientCore, userAgent: string) =
  ## ユーザーエージェントを設定
  client.userAgent = userAgent
  client.headers["User-Agent"] = userAgent

proc setCookie*(client: HttpClientCore, domain, path, name, value: string, 
                expires: Option[DateTime] = none(DateTime), 
                secure: bool = false, httpOnly: bool = false) =
  ## クッキーを設定
  var cookie = Cookie()
  cookie.name = name
  cookie.value = value
  cookie.domain = domain
  cookie.path = path
  cookie.expires = expires
  cookie.secure = secure
  cookie.http_only = httpOnly
  cookie.creation_time = now()
  cookie.last_access_time = now()
  
  # クッキージャーに追加
  client.cookies.addCookie(cookie)

proc setProxy*(client: HttpClientCore, url: string, username: string = "", password: string = "") =
  ## プロキシを設定
  client.proxy.url = url
  if username.len > 0 and password.len > 0:
    client.proxy.auth = some((username: username, password: password))
  else:
    client.proxy.auth = none(tuple[username, password: string])

proc setRateLimit*(client: HttpClientCore, requestsPerSecond: float) =
  ## 全体のレート制限を設定
  client.rateLimiter.requestsPerSecond = requestsPerSecond

proc setDomainRateLimit*(client: HttpClientCore, domain: string, requestsPerSecond: float) =
  ## ドメイン別のレート制限を設定
  client.rateLimiter.domainLimits[domain] = requestsPerSecond
  if domain notin client.rateLimiter.domainLastRequests:
    client.rateLimiter.domainLastRequests[domain] = initDeque[Time]()

proc canMakeRequest*(client: HttpClientCore, url: string): bool =
  ## レート制限に基づいてリクエストが可能かどうかを確認
  let uri = parseUri(url)
  let domain = uri.hostname
  let now = getTime()
  
  # 全体のレート制限をチェック
  let globalLimit = client.rateLimiter.requestsPerSecond
  var lastRequests = client.rateLimiter.lastRequests
  
  # 過去1秒以内のリクエストのみを保持
  while lastRequests.len > 0 and now - lastRequests[0] > initDuration(seconds = 1):
    discard lastRequests.popFirst()
  
  if lastRequests.len.float >= globalLimit:
    return false
  
  # ドメイン別レート制限をチェック
  if domain in client.rateLimiter.domainLimits:
    let domainLimit = client.rateLimiter.domainLimits[domain]
    var domainLastRequests = client.rateLimiter.domainLastRequests[domain]
    
    # 過去1秒以内のリクエストのみを保持
    while domainLastRequests.len > 0 and now - domainLastRequests[0] > initDuration(seconds = 1):
      discard domainLastRequests.popFirst()
    
    if domainLastRequests.len.float >= domainLimit:
      return false
  
  return true

proc waitForRateLimit*(client: HttpClientCore, url: string): Future[void] {.async.} =
  ## レート制限に基づいて待機
  while not client.canMakeRequest(url):
    await sleepAsync(50)  # 50ミリ秒待機

proc updateRateLimiter*(client: HttpClientCore, url: string) =
  ## リクエスト後にレート制限カウンターを更新
  let uri = parseUri(url)
  let domain = uri.hostname
  let now = getTime()
  
  # 全体のレート制限カウンターを更新
  client.rateLimiter.lastRequests.addLast(now)
  
  # ドメイン別レート制限カウンターを更新
  if domain in client.rateLimiter.domainLimits:
    client.rateLimiter.domainLastRequests[domain].addLast(now)

proc resolveDns*(client: HttpClientCore, hostname: string): Future[seq[string]] {.async.} =
  ## DNSリゾルバーを使用してホスト名を解決
  let now = getTime()
  
  # キャッシュをチェック
  if hostname in client.dnsCache:
    let cacheEntry = client.dnsCache[hostname]
    if now < cacheEntry.expiry:
      return cacheEntry.ips
  
  # 新しい解決を実行
  try:
    # ここでは簡単なためにシステムの解決を使用
    let ipAddr = await asyncGetAddrInfo(hostname, Port(0), AF_INET)
    if ipAddr.len > 0:
      var ips: seq[string] = @[]
      for addr in ipAddr:
        ips.add($addr.address)
      
      # キャッシュに保存（1時間の有効期限）
      let expiry = now + initDuration(hours = 1)
      client.dnsCache[hostname] = DnsCacheEntry(ips: ips, expiry: expiry)
      
      return ips
  except:
    client.logger.log(lvlError, "DNSの解決に失敗しました: " & hostname)
  
  return @[]

proc getConnection*(client: HttpClientCore, hostname: string, port: int, ssl: bool): Future[AsyncSocket] {.async.} =
  ## 接続プールから接続を取得またはホストに新しい接続を作成
  let hostKey = hostname & ":" & $port & ":" & $ssl
  
  # 接続プールから接続を探す
  if hostKey in client.connections and client.connections[hostKey].len > 0:
    let socket = client.connections[hostKey].pop()
    if not socket.isClosed():
      return socket
  
  # 新しい接続を作成
  let socket = newAsyncSocket()
  
  # ホスト名を解決
  let ips = await client.resolveDns(hostname)
  if ips.len == 0:
    raise newException(IOError, "ホスト名を解決できませんでした: " & hostname)
  
  # 最初のIPアドレスに接続
  let ipAddr = ips[0]
  await socket.connect(ipAddr, Port(port))
  
  # SSLの場合はハンドシェイクを実行
  if ssl:
    when defined(ssl):
      let sslContext = if client.sslContext != nil: client.sslContext else: newContext(verifyMode = CVerifyPeer)
      wrapConnectedSocket(sslContext, socket, handshakeAsClient, hostname)
    else:
      raise newException(Exception, "SSLサポートが有効になっていません")
  
  return socket

proc releaseConnection*(client: HttpClientCore, socket: AsyncSocket, hostname: string, port: int, ssl: bool) =
  ## 接続をプールに戻す
  if socket.isClosed():
    return
  
  let hostKey = hostname & ":" & $port & ":" & $ssl
  
  if hostKey notin client.connections:
    client.connections[hostKey] = @[]
  
  # 最大10個までプールに保持
  if client.connections[hostKey].len < 10:
    client.connections[hostKey].add(socket)
  else:
    socket.close()

proc updateStats*(client: HttpClientCore, statusCode: int, requestTime: Duration, bytesDownloaded, bytesUploaded: int64) =
  ## 統計情報を更新
  client.stats.requestsSent += 1
  client.stats.bytesDownloaded += bytesDownloaded
  client.stats.bytesUploaded += bytesUploaded
  client.stats.requestTimes.add(requestTime)
  
  # 最大100個の履歴を保持
  if client.stats.requestTimes.len > 100:
    client.stats.requestTimes.delete(0)
  
  # ステータスコードをカウント
  if statusCode notin client.stats.statusCodes:
    client.stats.statusCodes[statusCode] = 0
  client.stats.statusCodes[statusCode] += 1

proc close*(client: HttpClientCore) =
  ## クライアントを閉じて、全ての接続を解放
  for hostKey, connections in client.connections:
    for socket in connections:
      if not socket.isClosed():
        socket.close()
  
  client.connections.clear()
  client.client.close()

proc request*(client: HttpClientCore, url: string, httpMethod: HttpMethod, 
              body: string = "", headers: HttpHeaders = nil, 
              options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## 非同期HTTPリクエストを実行
  # レート制限に基づいて待機
  await client.waitForRateLimit(url)
  
  # リクエスト時間の記録を開始
  let startTime = getTime()
  
  # ヘッダーのマージ
  var mergedHeaders = client.headers
  if headers != nil:
    for key, val in headers:
      mergedHeaders[key] = val
  
  # ユーザーエージェントの設定
  let userAgent = if options.userAgent.len > 0: options.userAgent else: client.userAgent
  if "User-Agent" notin mergedHeaders:
    mergedHeaders["User-Agent"] = userAgent
  
  # クッキーヘッダーの設定
  let uri = parseUri(url)
  let cookieHeader = client.cookies.getCookieHeader(uri.hostname, uri.path)
  if cookieHeader.len > 0:
    mergedHeaders["Cookie"] = cookieHeader
  
  # タイムアウトの設定
  let timeout = if options.timeout > 0: options.timeout else: client.timeout
  
  # リクエストの実行
  try:
    # レート制限カウンターを更新
    client.updateRateLimiter(url)
    
    # 実際のリクエストを実行
    let response = await client.client.request(url, httpMethod, body, mergedHeaders)
    
    # レスポンス統計情報を更新
    let endTime = getTime()
    let requestTime = endTime - startTime
    let bytesDownloaded = if response.body.len > 0: response.body.len.int64 else: 0
    let bytesUploaded = body.len.int64
    client.updateStats(response.code.int, requestTime, bytesDownloaded, bytesUploaded)
    
    # レスポンスクッキーの処理
    if "Set-Cookie" in response.headers:
      for cookieStr in response.headers["Set-Cookie"]:
        let cookie = parseCookie(cookieStr, uri.hostname)
        client.cookies.addCookie(cookie)
    
    return response
  except Exception as e:
    client.logger.log(lvlError, "リクエスト中にエラーが発生しました: " & e.msg)
    raise e

proc get*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
          options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP GETリクエストを実行
  return await client.request(url, HttpGet, "", headers, options)

proc post*(client: HttpClientCore, url: string, body: string, headers: HttpHeaders = nil, 
           options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP POSTリクエストを実行
  return await client.request(url, HttpPost, body, headers, options)

proc put*(client: HttpClientCore, url: string, body: string, headers: HttpHeaders = nil, 
          options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP PUTリクエストを実行
  return await client.request(url, HttpPut, body, headers, options)

proc delete*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
             options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP DELETEリクエストを実行
  return await client.request(url, HttpDelete, "", headers, options)

proc head*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
           options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP HEADリクエストを実行
  return await client.request(url, HttpHead, "", headers, options)

proc patch*(client: HttpClientCore, url: string, body: string, headers: HttpHeaders = nil, 
            options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP PATCHリクエストを実行
  return await client.request(url, HttpPatch, body, headers, options)

proc options*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
              options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP OPTIONSリクエストを実行
  return await client.request(url, HttpOptions, "", headers, options)

proc trace*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
            options: RequestOptions = RequestOptions()): Future[Response] {.async.} =
  ## HTTP TRACEリクエストを実行
  return await client.request(url, HttpTrace, "", headers, options)

proc getJson*(client: HttpClientCore, url: string, headers: HttpHeaders = nil, 
              options: RequestOptions = RequestOptions()): Future[JsonNode] {.async.} =
  ## JSON形式でGETリクエストを実行
  var mergedHeaders = if headers != nil: headers else: newHttpHeaders()
  if "Accept" notin mergedHeaders:
    mergedHeaders["Accept"] = "application/json"
  
  let response = await client.get(url, mergedHeaders, options)
  if response.code.int div 100 != 2:
    raise newException(HttpRequestError, "HTTPエラー: " & $response.code.int)
  
  return parseJson(response.body)

proc postJson*(client: HttpClientCore, url: string, data: JsonNode, headers: HttpHeaders = nil, 
               options: RequestOptions = RequestOptions()): Future[JsonNode] {.async.} =
  ## JSON形式でPOSTリクエストを実行
  var mergedHeaders = if headers != nil: headers else: newHttpHeaders()
  if "Content-Type" notin mergedHeaders:
    mergedHeaders["Content-Type"] = "application/json"
  if "Accept" notin mergedHeaders:
    mergedHeaders["Accept"] = "application/json"
  
  let body = $data
  let response = await client.post(url, body, mergedHeaders, options)
  if response.code.int div 100 != 2:
    raise newException(HttpRequestError, "HTTPエラー: " & $response.code.int)
  
  return parseJson(response.body)

proc downloadFile*(client: HttpClientCore, url: string, filename: string, 
                  headers: HttpHeaders = nil, options: RequestOptions = RequestOptions()): Future[void] {.async.} =
  ## ファイルをダウンロード
  let response = await client.get(url, headers, options)
  if response.code.int div 100 != 2:
    raise newException(HttpRequestError, "HTTPエラー: " & $response.code.int)
  
  # ファイルに書き込み
  let file = open(filename, fmWrite)
  file.write(response.body)
  file.close()

proc getStats*(client: HttpClientCore): ClientStats =
  ## クライアントの統計情報を取得
  return client.stats

proc getAverageResponseTime*(client: HttpClientCore): float =
  ## 平均レスポンス時間をミリ秒単位で取得
  if client.stats.requestTimes.len == 0:
    return 0.0
  
  var totalMs = 0.0
  for time in client.stats.requestTimes:
    totalMs += time.inMilliseconds.float
  
  return totalMs / client.stats.requestTimes.len.float 