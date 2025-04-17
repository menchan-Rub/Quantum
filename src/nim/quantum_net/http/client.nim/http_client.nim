# Quantum HTTP Client Implementation
#
# 高性能かつ拡張性のある HTTP クライアント
# HTTP/1.1, HTTP/2, HTTP/3 をサポート

import std/[asyncdispatch, asyncnet, uri, options, tables, strutils, times, json, deques]
import std/[random, strformat, sets, hashes, sequtils, algorithm]
import std/httpclient as stdHttpClient

import ../protocols/quic/quic_client
import ../../compression/[gzip, deflate, brotli, hpack, qpack]
import ./http1 as http1
import ./http2 as http2
import ./http3 as http3

type
  HttpVersion* = enum
    Http11 = "HTTP/1.1"
    Http2 = "HTTP/2"
    Http3 = "HTTP/3"
  
  HttpMethod* = enum
    GET = "GET"
    POST = "POST"
    PUT = "PUT"
    DELETE = "DELETE"
    HEAD = "HEAD"
    OPTIONS = "OPTIONS"
    PATCH = "PATCH"
    TRACE = "TRACE"
    CONNECT = "CONNECT"
  
  HttpHeader* = tuple[name: string, value: string]
  
  HttpBody* = object
    case isStream*: bool
    of true:
      stream*: AsyncStream
    of false:
      data*: string
  
  HttpResponse* = ref object
    version*: HttpVersion
    statusCode*: int
    reasonPhrase*: string
    headers*: seq[HttpHeader]
    body*: HttpBody
    contentLength*: Option[int]
    chunked*: bool
    keepAlive*: bool
    requestTime*: float  # リクエスト開始からレスポンス完了までの時間（秒）
  
  HttpRequest* = ref object
    url*: Uri
    method*: HttpMethod
    headers*: seq[HttpHeader]
    body*: HttpBody
    version*: HttpVersion
    timeout*: int  # ミリ秒
    followRedirects*: bool
    maxRedirects*: int
    proxy*: Option[Uri]
    auth*: Option[HttpAuth]
    validationLevel*: SecurityLevel
  
  HttpAuth* = object
    username*: string
    password*: string
    kind*: AuthKind
  
  AuthKind* = enum
    Basic, Digest, Bearer
  
  SecurityLevel* = enum
    None,       # 証明書チェックなし
    Basic,      # ホスト名と有効期限のみ確認
    Normal,     # 一般的な証明書チェック
    Strict      # 厳格なセキュリティチェック（HSTS、証明書透明性など）
  
  ConnectionPoolKey = object
    host: string
    port: int
    secure: bool
  
  ConnectionInfo = object
    conn: Connection
    protocol: HttpVersion
    lastUsed: Time
    requestCount: int
    inUse: bool
  
  Connection = ref object
    case version: HttpVersion
    of Http11:
      httpConn: AsyncSocket
    of Http2:
      http2Conn: Http2Client
    of Http3:
      http3Conn: QuicClient
  
  AsyncStream* = ref object
    readable*: AsyncEvent
    readerClosed*: bool
    writerClosed*: bool
    buffer: Deque[string]
    maxBufferSize: int
  
  HttpClientConfig* = object
    userAgent*: string
    maxConnections*: int
    connectionIdleTimeout*: int  # 秒
    connectionLifetime*: int     # 秒
    requestTimeout*: int         # ミリ秒
    followRedirects*: bool
    maxRedirects*: int
    allowInsecure*: bool
    caBundle*: string
    proxy*: Option[Uri]
    validationLevel*: SecurityLevel
  
  HttpClient* = ref object
    config: HttpClientConfig
    connectionPool: Table[ConnectionPoolKey, seq[ConnectionInfo]]
    defaultHeaders: seq[HttpHeader]
    cookieJar: CookieJar
    rng: Rand
  
  CookieJar = ref object
    cookies: Table[string, Cookie]
  
  Cookie = object
    name: string
    value: string
    domain: string
    path: string
    expires: Option[Time]
    secure: bool
    httpOnly: bool
    sameSite: CookieSameSite
  
  CookieSameSite = enum
    None, Lax, Strict

# ConnectionPoolKey のハッシュ関数
proc hash(key: ConnectionPoolKey): Hash =
  var h: Hash = 0
  h = h !& hash(key.host)
  h = h !& hash(key.port)
  h = h !& hash(key.secure)
  result = !$h

# AsyncStream 実装
proc newAsyncStream*(maxBufferSize: int = 1024 * 1024): AsyncStream =
  result = AsyncStream(
    readable: newAsyncEvent(),
    readerClosed: false,
    writerClosed: false,
    buffer: initDeque[string](),
    maxBufferSize: maxBufferSize
  )

proc write*(stream: AsyncStream, data: string): Future[void] {.async.} =
  if stream.writerClosed:
    raise newException(IOError, "Stream writer is closed")
  
  var bufferSize = 0
  for item in stream.buffer:
    bufferSize += item.len
  
  if bufferSize + data.len > stream.maxBufferSize:
    # バッファがいっぱいの場合は待機
    while bufferSize + data.len > stream.maxBufferSize and not stream.readerClosed:
      await sleepAsync(10)
      
      # バッファサイズを再計算
      bufferSize = 0
      for item in stream.buffer:
        bufferSize += item.len
  
  if stream.readerClosed:
    raise newException(IOError, "Stream reader is closed")
  
  stream.buffer.addLast(data)
  stream.readable.fire()

proc close*(stream: AsyncStream) =
  stream.writerClosed = true
  stream.readable.fire()  # 読み取り側に通知

proc read*(stream: AsyncStream, maxBytes: int = -1): Future[Option[string]] {.async.} =
  if stream.readerClosed:
    return none(string)
  
  while stream.buffer.len == 0 and not stream.writerClosed:
    await stream.readable.wait()
  
  if stream.buffer.len == 0 and stream.writerClosed:
    stream.readerClosed = true
    return none(string)
  
  var data = ""
  var bytesRead = 0
  
  while stream.buffer.len > 0 and (maxBytes < 0 or bytesRead < maxBytes):
    let chunk = stream.buffer.popFirst()
    
    if maxBytes < 0 or bytesRead + chunk.len <= maxBytes:
      data.add(chunk)
      bytesRead += chunk.len
    else:
      let toTake = maxBytes - bytesRead
      data.add(chunk[0 ..< toTake])
      stream.buffer.addFirst(chunk[toTake .. ^1])
      bytesRead += toTake
      break
  
  return some(data)

# CookieJar 実装
proc newCookieJar*(): CookieJar =
  CookieJar(cookies: initTable[string, Cookie]())

proc setCookie*(jar: CookieJar, cookie: Cookie) =
  let key = cookie.domain & cookie.path & cookie.name
  jar.cookies[key] = cookie

proc getCookies*(jar: CookieJar, url: Uri): seq[Cookie] =
  result = @[]
  let host = url.hostname
  let path = if url.path == "": "/" else: url.path
  
  for cookie in jar.cookies.values:
    # ドメインマッチング
    let domain = cookie.domain
    if not host.endsWith(domain) and not ("." & host == domain):
      continue
    
    # パスマッチング
    if not path.startsWith(cookie.path):
      continue
    
    # セキュアチェック
    if cookie.secure and url.scheme != "https":
      continue
    
    # 有効期限チェック
    if cookie.expires.isSome and cookie.expires.get() < getTime():
      continue
    
    result.add(cookie)

proc parseCookies*(cookieHeader: string): seq[Cookie] =
  result = @[]
  let parts = cookieHeader.split("; ")
  
  var cookie = Cookie(
    path: "/",
    secure: false,
    httpOnly: false,
    sameSite: Lax
  )
  
  # 最初の部分は常に name=value
  let nameValue = parts[0].split("=", maxsplit=1)
  if nameValue.len >= 2:
    cookie.name = nameValue[0]
    cookie.value = nameValue[1]
  
  # 残りの属性を解析
  for i in 1 ..< parts.len:
    let attr = parts[i].split("=", maxsplit=1)
    let key = attr[0].toLowerAscii()
    
    if attr.len == 1:
      # フラグ属性
      case key
      of "secure": cookie.secure = true
      of "httponly": cookie.httpOnly = true
      else: discard
    else:
      # 値を持つ属性
      let value = attr[1]
      case key
      of "expires":
        try:
          let expTime = parse(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'")
          cookie.expires = some(expTime)
        except:
          discard
      of "max-age":
        try:
          let seconds = parseInt(value)
          cookie.expires = some(getTime() + initDuration(seconds=seconds))
        except:
          discard
      of "domain": cookie.domain = value
      of "path": cookie.path = value
      of "samesite":
        case value.toLowerAscii()
        of "none": cookie.sameSite = None
        of "lax": cookie.sameSite = Lax
        of "strict": cookie.sameSite = Strict
        else: discard
      else: discard
  
  if cookie.domain == "":
    return @[] # ドメインなしのクッキーは無効
  
  result.add(cookie)

# HttpClient の実装
proc newHttpClient*(config: HttpClientConfig = HttpClientConfig()): HttpClient =
  result = HttpClient(
    config: config,
    connectionPool: initTable[ConnectionPoolKey, seq[ConnectionInfo]](),
    defaultHeaders: @[
      ("User-Agent", config.userAgent),
      ("Accept", "*/*"),
      ("Accept-Encoding", "gzip, deflate, br")
    ],
    cookieJar: newCookieJar(),
    rng: initRand(int(epochTime() * 1000))
  )

proc close*(client: HttpClient) =
  for connections in client.connectionPool.values:
    for connInfo in connections:
      case connInfo.conn.version
      of Http11:
        connInfo.conn.httpConn.close()
      of Http2:
        asyncCheck connInfo.conn.http2Conn.close()
      of Http3:
        asyncCheck connInfo.conn.http3Conn.close()
  
  client.connectionPool.clear()

proc cleanupConnections*(client: HttpClient) =
  let now = getTime()
  
  for key, connections in client.connectionPool.mpairs:
    var newConnections: seq[ConnectionInfo] = @[]
    
    for connInfo in connections:
      if connInfo.inUse:
        newConnections.add(connInfo)
        continue
      
      let idleTime = (now - connInfo.lastUsed).inSeconds
      let lifetime = (now - connInfo.lastUsed).inSeconds + connInfo.requestCount * 10
      
      if idleTime > client.config.connectionIdleTimeout or 
         lifetime > client.config.connectionLifetime:
        # 接続をクローズ
        case connInfo.conn.version
        of Http11:
          connInfo.conn.httpConn.close()
        of Http2:
          asyncCheck connInfo.conn.http2Conn.close()
        of Http3:
          asyncCheck connInfo.conn.http3Conn.close()
      else:
        newConnections.add(connInfo)
    
    if newConnections.len == 0:
      client.connectionPool.del(key)
    else:
      client.connectionPool[key] = newConnections

proc getConnection(client: HttpClient, url: Uri, preferredVersion: HttpVersion = Http2): Future[tuple[conn: Connection, version: HttpVersion]] {.async.} =
  # まずURLからの接続情報を取得
  let secure = url.scheme == "https"
  let port = if url.port == "": 
              (if secure: 443 else: 80) 
             else: parseInt(url.port)
  
  let key = ConnectionPoolKey(
    host: url.hostname,
    port: port,
    secure: secure
  )
  
  # 接続プールから利用可能な接続を探す
  if client.connectionPool.hasKey(key):
    var connections = client.connectionPool[key]
    
    # 優先バージョンに一致する接続を優先的に選択
    for i, connInfo in connections:
      if not connInfo.inUse and connInfo.protocol == preferredVersion:
        connections[i].inUse = true
        connections[i].lastUsed = getTime()
        connections[i].requestCount += 1
        client.connectionPool[key] = connections
        return (connInfo.conn, connInfo.protocol)
    
    # 利用可能な任意の接続を選択
    for i, connInfo in connections:
      if not connInfo.inUse:
        connections[i].inUse = true
        connections[i].lastUsed = getTime()
        connections[i].requestCount += 1
        client.connectionPool[key] = connections
        return (connInfo.conn, connInfo.protocol)
  
  # 新しい接続を作成する必要がある
  # HTTP/2 または HTTP/3 を優先
  var conn: Connection
  var protocol: HttpVersion
  
  if preferredVersion == Http3 and secure:
    try:
      # HTTP/3接続の確立
      let quicConfig = newQuicConfig()
      quicConfig.verifyMode = CVerifyNone  # 本番環境では適切な証明書検証を設定
      quicConfig.alpn = @["h3"]
      quicConfig.maxIdleTimeout = 30_000  # 30秒
      
      let quicClient = await newQuicClient(
        url.hostname, 
        $port, 
        "h3", 
        config = quicConfig,
        connectionTimeout = client.connectionTimeout
      )
      
      # 接続が確立されたことを確認
      if not quicClient.isConnected:
        raise newException(HttpConnectionError, "HTTP/3接続の確立に失敗しました")
        
      conn = Connection(version: Http3, http3Conn: quicClient)
      protocol = Http3
      
      # 接続統計の記録
      client.stats.http3ConnectionsCreated.inc()
      
    except CatchableError as e:
      # HTTP/3接続の失敗を記録
      client.stats.http3ConnectionFailures.inc()
      client.logger.log(lvlDebug, fmt"HTTP/3接続に失敗: {url.hostname}:{port} - {e.msg}")
      
      # HTTP/2へのフォールバック
      if preferredVersion != Http11:
        try:
          # HTTP/2接続の確立
          var tlsConfig = newTLSConfig()
          tlsConfig.alpnProtocols = @["h2"]
          tlsConfig.verifyMode = if client.insecureSkipVerify: CVerifyNone else: CVerifyPeer
          
          let http2Conn = await http2.newHttp2Client(
            url.hostname, 
            port, 
            secure, 
            tlsConfig = tlsConfig,
            connectionTimeout = client.connectionTimeout,
            settings = client.http2Settings
          )
          
          # HTTP/2接続の設定
          http2Conn.setPingInterval(client.keepAliveInterval)
          http2Conn.setMaxConcurrentStreams(client.maxConcurrentStreams)
          
          conn = Connection(version: Http2, http2Conn: http2Conn)
          protocol = Http2
          
          # 接続統計の記録
          client.stats.http2ConnectionsCreated.inc()
          
        except CatchableError as e:
          # HTTP/2接続の失敗を記録
          client.stats.http2ConnectionFailures.inc()
          client.logger.log(lvlDebug, fmt"HTTP/2接続に失敗: {url.hostname}:{port} - {e.msg}")
          
          # HTTP/1.1へのフォールバック
          let socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
          socket.setSockOpt(OptNoDelay, true)
          socket.setSockOpt(OptKeepAlive, true)
          
          try:
            await withTimeout(socket.connect(url.hostname, Port(port)), client.connectionTimeout)
            
            if secure:
              # TLS接続の確立
              var tlsContext = newTLSContext()
              tlsContext.verifyMode = if client.insecureSkipVerify: CVerifyNone else: CVerifyPeer
              
              let tlsSocket = newTLSAsyncSocket(socket, tlsContext, true)
              await tlsSocket.handshake(url.hostname)
              
              conn = Connection(version: Http11, httpConn: tlsSocket)
            else:
              conn = Connection(version: Http11, httpConn: socket)
              
            protocol = Http11
            
            # 接続統計の記録
            client.stats.http1ConnectionsCreated.inc()
            
          except CatchableError as e:
            socket.close()
            client.stats.http1ConnectionFailures.inc()
            raise newException(HttpConnectionError, fmt"すべてのプロトコルでの接続に失敗しました: {e.msg}")
      else:
        # HTTP/1.1が明示的に指定されている場合
        let socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        socket.setSockOpt(OptNoDelay, true)
        socket.setSockOpt(OptKeepAlive, true)
        
        try:
          await withTimeout(socket.connect(url.hostname, Port(port)), client.connectionTimeout)
          
          if secure:
            # TLS接続の確立
            var tlsContext = newTLSContext()
            tlsContext.verifyMode = if client.insecureSkipVerify: CVerifyNone else: CVerifyPeer
            
            let tlsSocket = newTLSAsyncSocket(socket, tlsContext, true)
            await tlsSocket.handshake(url.hostname)
            
            conn = Connection(version: Http11, httpConn: tlsSocket)
          else:
            conn = Connection(version: Http11, httpConn: socket)
            
          protocol = Http11
          
          # 接続統計の記録
          client.stats.http1ConnectionsCreated.inc()
          
        except CatchableError as e:
          socket.close()
          client.stats.http1ConnectionFailures.inc()
          raise newException(HttpConnectionError, fmt"HTTP/1.1接続に失敗しました: {e.msg}")
  elif preferredVersion != Http11 and secure:
    try:
      let http2Conn = await http2.newHttp2Client(url.hostname, port, secure)
      conn = Connection(version: Http2, http2Conn: http2Conn)
      protocol = Http2
    except:
      # HTTP/2 が失敗した場合は HTTP/1.1 にフォールバック
      let socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      await socket.connect(url.hostname, Port(port))
      
      if secure:
        # TLS ハンドシェイク（簡略化）
        discard
      
      conn = Connection(version: Http11, httpConn: socket)
      protocol = Http11
  
  else:
    # HTTP/1.1 を使用
    let socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    await socket.connect(url.hostname, Port(port))
    
    if secure:
      # TLS ハンドシェイク（簡略化）
      discard
    
    conn = Connection(version: Http11, httpConn: socket)
    protocol = Http11
  
  # 接続プールに追加
  let connInfo = ConnectionInfo(
    conn: conn,
    protocol: protocol,
    lastUsed: getTime(),
    requestCount: 1,
    inUse: true
  )
  
  if not client.connectionPool.hasKey(key):
    client.connectionPool[key] = @[]
  
  client.connectionPool[key].add(connInfo)
  
  # プールのクリーンアップをトリガー
  if rand(1.0) < 0.1:  # 約10%の確率でクリーンアップ
    client.cleanupConnections()
  
  return (conn, protocol)

proc releaseConnection(client: HttpClient, url: Uri, conn: Connection) =
  let secure = url.scheme == "https"
  let port = if url.port == "": 
              (if secure: 443 else: 80) 
             else: parseInt(url.port)
  
  let key = ConnectionPoolKey(
    host: url.hostname,
    port: port,
    secure: secure
  )
  
  if client.connectionPool.hasKey(key):
    var connections = client.connectionPool[key]
    
    for i, connInfo in connections:
      if connInfo.conn == conn:
        connections[i].inUse = false
        connections[i].lastUsed = getTime()
        client.connectionPool[key] = connections
        break

proc decompressBody(body: string, encoding: string): string =
  if encoding == "":
    return body
  
  let encodings = encoding.toLowerAscii().split(",").mapIt(it.strip())
  
  var result = body
  
  for enc in encodings:
    if enc == "gzip":
      result = decompressGzip(result)
    elif enc == "deflate":
      result = decompressDeflate(result)
    elif enc == "br":
      result = decompressBrotli(result)
  
  return result

proc setHeaders*(client: HttpClient, key: string, value: string) =
  # 既存のヘッダーを更新または追加
  var found = false
  for i in 0 ..< client.defaultHeaders.len:
    if client.defaultHeaders[i].name.toLowerAscii() == key.toLowerAscii():
      client.defaultHeaders[i] = (key, value)
      found = true
      break
  
  if not found:
    client.defaultHeaders.add((key, value))

proc request*(client: HttpClient, req: HttpRequest): Future[HttpResponse] {.async.} =
  let startTime = epochTime()
  
  # リクエストの準備
  var request = req
  var redirectCount = 0
  var currentUrl = request.url
  
  # メソッドチェック
  if request.method notin {GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH, TRACE, CONNECT}:
    raise newException(ValueError, "Invalid HTTP method")
  
  # デフォルトヘッダーのマージ
  var headers = client.defaultHeaders
  
  for header in request.headers:
    var found = false
    for i in 0 ..< headers.len:
      if headers[i].name.toLowerAscii() == header.name.toLowerAscii():
        headers[i] = header
        found = true
        break
    
    if not found:
      headers.add(header)
  
  # レスポンスを格納する変数
  var response: HttpResponse
  
  while true:
    # 接続の取得
    let (conn, version) = await client.getConnection(currentUrl, request.version)
    
    try:
      # バージョンに応じたリクエスト送信
      case version
      of Http11:
        response = await http1.sendRequest(conn.httpConn, currentUrl, request.method, 
                                           headers, request.body, request.timeout)
      
      of Http2:
        response = await http2.sendRequest(conn.http2Conn, currentUrl, request.method, 
                                           headers, request.body, request.timeout)
      
      of Http3:
        response = await http3.sendRequest(conn.http3Conn, currentUrl, request.method, 
                                           headers, request.body, request.timeout)
    
    finally:
      # 接続を解放
      client.releaseConnection(currentUrl, conn)
    
    # レスポンスボディの解凍
    if not response.body.isStream:
      var contentEncoding = ""
      for header in response.headers:
        if header.name.toLowerAscii() == "content-encoding":
          contentEncoding = header.value
          break
      
      if contentEncoding != "":
        response.body.data = decompressBody(response.body.data, contentEncoding)
    
    # リダイレクトの処理
    if request.followRedirects and redirectCount < request.maxRedirects and 
       response.statusCode in {301, 302, 303, 307, 308}:
      
      var locationHeader = ""
      for header in response.headers:
        if header.name.toLowerAscii() == "location":
          locationHeader = header.value
          break
      
      if locationHeader != "":
        redirectCount += 1
        
        # 相対URLを絶対URLに変換
        var redirectUrl: Uri
        if locationHeader.startsWith("http://") or locationHeader.startsWith("https://"):
          redirectUrl = parseUri(locationHeader)
        else:
          redirectUrl = parseUri($currentUrl)
          if locationHeader.startsWith("/"):
            redirectUrl.path = locationHeader
            redirectUrl.query = ""
            redirectUrl.anchor = ""
          else:
            let basePath = redirectUrl.path.rsplit('/', 1)[0]
            redirectUrl.path = basePath & "/" & locationHeader
            redirectUrl.query = ""
            redirectUrl.anchor = ""
        
        currentUrl = redirectUrl
        
        # POST → GET 変換（303レスポンスの場合）
        if response.statusCode == 303 and request.method != GET:
          request.method = GET
          request.body = HttpBody(isStream: false, data: "")
        
        continue
    
    # リダイレクトが無いか、リダイレクト処理が終了
    break
  
  # レスポンスヘッダーからクッキーを処理
  for header in response.headers:
    if header.name.toLowerAscii() == "set-cookie":
      let cookies = parseCookies(header.value)
      for cookie in cookies:
        # ドメインが設定されている場合のみ保存
        if cookie.domain != "":
          client.cookieJar.setCookie(cookie)
  
  # リクエスト時間を記録
  response.requestTime = epochTime() - startTime
  
  return response

# 便利なショートカットメソッド
proc get*(client: HttpClient, url: string, headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  let request = HttpRequest(
    url: parseUri(url),
    method: GET,
    headers: headers,
    body: HttpBody(isStream: false, data: ""),
    version: Http2,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    proxy: client.config.proxy,
    validationLevel: client.config.validationLevel
  )
  
  return await client.request(request)

proc post*(client: HttpClient, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
          headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  var requestHeaders = headers
  requestHeaders.add(("Content-Type", contentType))
  requestHeaders.add(("Content-Length", $body.len))
  
  let request = HttpRequest(
    url: parseUri(url),
    method: POST,
    headers: requestHeaders,
    body: HttpBody(isStream: false, data: body),
    version: Http2,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    proxy: client.config.proxy,
    validationLevel: client.config.validationLevel
  )
  
  return await client.request(request)

proc put*(client: HttpClient, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
         headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  var requestHeaders = headers
  requestHeaders.add(("Content-Type", contentType))
  requestHeaders.add(("Content-Length", $body.len))
  
  let request = HttpRequest(
    url: parseUri(url),
    method: PUT,
    headers: requestHeaders,
    body: HttpBody(isStream: false, data: body),
    version: Http2,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    proxy: client.config.proxy,
    validationLevel: client.config.validationLevel
  )
  
  return await client.request(request)

proc delete*(client: HttpClient, url: string, headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  let request = HttpRequest(
    url: parseUri(url),
    method: DELETE,
    headers: headers,
    body: HttpBody(isStream: false, data: ""),
    version: Http2,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    proxy: client.config.proxy,
    validationLevel: client.config.validationLevel
  )
  
  return await client.request(request)

# ユーティリティ関数
proc getJson*(response: HttpResponse): JsonNode =
  if response.body.isStream:
    raise newException(ValueError, "Cannot parse streaming response body as JSON")
  
  try:
    return parseJson(response.body.data)
  except:
    raise newException(ValueError, "Response body is not valid JSON")

proc getText*(response: HttpResponse): string =
  if response.body.isStream:
    raise newException(ValueError, "Cannot get text from streaming response body")
  
  return response.body.data

proc getContentType*(response: HttpResponse): string =
  for header in response.headers:
    if header.name.toLowerAscii() == "content-type":
      return header.value
  
  return ""

proc getHeader*(response: HttpResponse, name: string): Option[string] =
  for header in response.headers:
    if header.name.toLowerAscii() == name.toLowerAscii():
      return some(header.value)
  
  return none(string)

# デフォルト設定のHTTPクライアントを作成
proc createDefaultHttpClient*(): HttpClient =
  let config = HttpClientConfig(
    userAgent: "QuantumBrowser/1.0",
    maxConnections: 100,
    connectionIdleTimeout: 60,   # 60秒
    connectionLifetime: 600,     # 10分
    requestTimeout: 30000,       # 30秒
    followRedirects: true,
    maxRedirects: 10,
    allowInsecure: false,
    validationLevel: Normal
  )
  
  return newHttpClient(config) 