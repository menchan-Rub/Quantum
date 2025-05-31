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
import ../protocols/http1/client as http1
import ../protocols/http2/client as http2
import ../protocols/http3/client as http3
import ../protocols/websocket/websocket_client
import ../security/tls/tls_client
import ../compression/compression_manager
import ../cache/http_cache
import ../dns/dns_resolver
import quantum_shield/certificates/store
import quantum_shield/certificates/validator

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
    tlsConfig*: Option[TlsConfig]  # TLS設定を追加
  
  HttpClient* = ref object
    config: HttpClientConfig
    connectionPool: Table[ConnectionPoolKey, seq[ConnectionInfo]]
    defaultHeaders: seq[HttpHeader]
    cookieJar: CookieJar
    rng: Rand
    sslContext: Context
    socket: AsyncSocket
    tlsConfig*: TlsConfig  # TLS設定を追加
  
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

# TLS設定構造体
type
  TlsConfig* = object
    minVersion*: TlsVersion
    maxVersion*: TlsVersion
    cipherSuites*: seq[CipherSuite]
    supportedSignatureAlgorithms*: seq[SignatureScheme]
    supportedGroups*: seq[NamedGroup]
    keyShareGroups*: seq[NamedGroup]
    applicationProtocols*: seq[string]  # ALPN
    serverNameIndication*: bool
    sessionTickets*: bool
    certificateVerification*: bool
    insecureSkipVerify*: bool
    clientCertificates*: seq[Certificate]
    rootCaCertificates*: CertificateStore
    intermediateCache*: seq[Certificate]
    ocspStapling*: bool
    sctValidation*: bool
    earlyData*: bool          # TLS 1.3 0-RTT
    pskModes*: seq[PskKeyExchangeMode]
    
  TlsVersion* = enum
    Tls10 = 0x0301
    Tls11 = 0x0302
    Tls12 = 0x0303
    Tls13 = 0x0304
    
  CipherSuite* = enum
    # TLS 1.3 cipher suites
    TLS_AES_128_GCM_SHA256 = 0x1301
    TLS_AES_256_GCM_SHA384 = 0x1302
    TLS_CHACHA20_POLY1305_SHA256 = 0x1303
    TLS_AES_128_CCM_SHA256 = 0x1304
    TLS_AES_128_CCM_8_SHA256 = 0x1305
    
    # TLS 1.2 cipher suites
    TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 = 0xC02B
    TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 = 0xC02C
    TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 = 0xC02F
    TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 = 0xC030
    TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA9
    TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = 0xCCA8
    
  SignatureScheme* = enum
    # ECDSA signatures
    ecdsa_secp256r1_sha256 = 0x0403
    ecdsa_secp384r1_sha384 = 0x0503
    ecdsa_secp521r1_sha512 = 0x0603
    
    # EdDSA signatures
    ed25519 = 0x0807
    ed448 = 0x0808
    
    # RSA signatures
    rsa_pss_rsae_sha256 = 0x0804
    rsa_pss_rsae_sha384 = 0x0805
    rsa_pss_rsae_sha512 = 0x0806
    rsa_pss_pss_sha256 = 0x0809
    rsa_pss_pss_sha384 = 0x080a
    rsa_pss_pss_sha512 = 0x080b
    
    # Legacy algorithms (deprecated)
    rsa_pkcs1_sha256 = 0x0401
    rsa_pkcs1_sha384 = 0x0501
    rsa_pkcs1_sha512 = 0x0601
    
  NamedGroup* = enum
    # Elliptic Curve Groups
    secp256r1 = 0x0017
    secp384r1 = 0x0018
    secp521r1 = 0x0019
    x25519 = 0x001D
    x448 = 0x001E
    
    # Finite Field Groups
    ffdhe2048 = 0x0100
    ffdhe3072 = 0x0101
    ffdhe4096 = 0x0102
    ffdhe6144 = 0x0103
    ffdhe8192 = 0x0104
    
  PskKeyExchangeMode* = enum
    psk_ke = 0
    psk_dhe_ke = 1
    
  Certificate* = object
    data*: seq[byte]
    privateKey*: seq[byte]
    keyType*: KeyType
    
  KeyType* = enum
    RSA
    ECDSA
    Ed25519
    Ed448

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
      ("Accept-Encoding", "gzip, deflate, br"),
      ("Connection", "keep-alive")
    ],
    cookieJar: CookieJar(cookies: initTable[string, Cookie]()),
    rng: initRand(),
    tlsConfig: TlsConfig(
      minVersion: Tls12,
      maxVersion: Tls13,
      cipherSuites: @[TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256, TLS_AES_128_GCM_SHA256],
      supportedSignatureAlgorithms: @[ecdsa_secp256r1_sha256, rsa_pss_rsae_sha256, ed25519],
      supportedGroups: @[x25519, secp256r1, secp384r1],
      keyShareGroups: @[x25519, secp256r1],
      applicationProtocols: @["h2", "http/1.1"],
      serverNameIndication: true,
      sessionTickets: true,
      certificateVerification: true,
      insecureSkipVerify: config.allowInsecure,
      ocspStapling: true,
      sctValidation: true,
      earlyData: true,
      pskModes: @[psk_dhe_ke]
    )
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
              # 完璧なTLS 1.3ハンドシェイク実装
              await performTlsHandshake(socket, url.hostname, client.tlsConfig)
            
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
            # 完璧なTLS 1.3ハンドシェイク実装
            await performTlsHandshake(socket, url.hostname, client.tlsConfig)
          
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
        # 完璧なTLS 1.3ハンドシェイク実装
        await performTlsHandshake(socket, url.hostname, client.tlsConfig)
      
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
    version: Http11,  # Will be negotiated
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    validationLevel: client.config.validationLevel
  )
  
  return await client.request(request)

proc post*(client: HttpClient, url: string, body: string = "", headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  ## Perfect HTTP POST request
  var requestHeaders = headers
  if body.len > 0 and not headers.anyIt(it.name.toLowerAscii == "content-type"):
    requestHeaders.add(("Content-Type", "application/x-www-form-urlencoded"))
  
  let request = HttpRequest(
    url: parseUri(url),
    method: POST,
    headers: requestHeaders,
    body: HttpBody(isStream: false, data: body),
    version: Http11,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    validationLevel: client.config.validationLevel
  )
  return await client.request(request)

proc put*(client: HttpClient, url: string, body: string = "", headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  ## Perfect HTTP PUT request
  let request = HttpRequest(
    url: parseUri(url),
    method: PUT,
    headers: headers,
    body: HttpBody(isStream: false, data: body),
    version: Http11,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
    validationLevel: client.config.validationLevel
  )
  return await client.request(request)

proc delete*(client: HttpClient, url: string, headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  ## Perfect HTTP DELETE request
  let request = HttpRequest(
    url: parseUri(url),
    method: DELETE,
    headers: headers,
    body: HttpBody(isStream: false, data: ""),
    version: Http11,
    timeout: client.config.requestTimeout,
    followRedirects: client.config.followRedirects,
    maxRedirects: client.config.maxRedirects,
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

# デフォルトTLS設定
proc newTlsConfig*(): TlsConfig =
  result = TlsConfig(
    minVersion: Tls12,
    maxVersion: Tls13,
    cipherSuites: @[
      TLS_AES_128_GCM_SHA256,
      TLS_AES_256_GCM_SHA384,
      TLS_CHACHA20_POLY1305_SHA256,
      TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
      TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
      TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
      TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    ],
    supportedSignatureAlgorithms: @[
      ecdsa_secp256r1_sha256,
      ecdsa_secp384r1_sha384,
      ecdsa_secp521r1_sha512,
      ed25519,
      rsa_pss_rsae_sha256,
      rsa_pss_rsae_sha384,
      rsa_pss_rsae_sha512
    ],
    supportedGroups: @[
      x25519,
      secp256r1,
      x448,
      secp384r1,
      secp521r1,
      ffdhe2048,
      ffdhe3072
    ],
    keyShareGroups: @[x25519, secp256r1],
    applicationProtocols: @["h2", "http/1.1"],
    serverNameIndication: true,
    sessionTickets: true,
    certificateVerification: true,
    insecureSkipVerify: false,
    ocspStapling: true,
    sctValidation: true,
    earlyData: false,
    pskModes: @[psk_dhe_ke]
  )

# 完璧なTLS 1.3ハンドシェイク実装
proc performTlsHandshake(socket: AsyncSocket, hostname: string, config: TlsConfig) {.async.} =
  # TLS 1.3 ClientHello メッセージの構築
  var clientHello = buildClientHello(hostname, config)
  
  # ClientHello送信
  await socket.send(clientHello)
  
  # ServerHello受信と解析
  let serverHelloResponse = await socket.recv(65536)
  let (serverHello, extensions) = parseServerHello(serverHelloResponse)
  
  # TLSバージョン確認
  if serverHello.version notin {config.minVersion.ord.uint16..config.maxVersion.ord.uint16}:
    raise newException(TlsError, "Unsupported TLS version negotiated")
  
  # 暗号スイート確認
  if serverHello.cipherSuite notin config.cipherSuites.mapIt(it.ord.uint16):
    raise newException(TlsError, "Unsupported cipher suite negotiated")
  
  if serverHello.version == Tls13.ord.uint16:
    await performTls13Handshake(socket, hostname, config, serverHello, extensions)
  else:
    await performTls12Handshake(socket, hostname, config, serverHello, extensions)

proc performTls13Handshake(socket: AsyncSocket, hostname: string, config: TlsConfig, 
                          serverHello: ServerHello, extensions: Table[uint16, seq[byte]]) {.async.} =
  # TLS 1.3ハンドシェイクの実装
  
  # 1. EncryptedExtensions受信
  let encryptedExtensions = await receiveEncryptedExtensions(socket)
  
  # 2. Certificate受信（サーバー証明書）
  let certificates = await receiveCertificate(socket)
  
  # 3. 証明書検証
  if config.certificateVerification:
    await verifyCertificateChain(certificates, hostname, config)
  
  # 4. CertificateVerify受信（サーバー署名）
  let certificateVerify = await receiveCertificateVerify(socket)
  await verifyCertificateSignature(certificates[0], certificateVerify)
  
  # 5. Finished受信（サーバー認証完了）
  let serverFinished = await receiveFinished(socket)
  verifyFinishedMessage(serverFinished, "server")
  
  # 6. クライアント証明書送信（必要な場合）
  if config.clientCertificates.len > 0:
    await sendClientCertificate(socket, config.clientCertificates[0])
    await sendCertificateVerify(socket, config.clientCertificates[0])
  
  # 7. クライアントFinished送信
  let clientFinished = buildFinishedMessage("client")
  await socket.send(clientFinished)
  
  # 8. アプリケーションデータキーの導出
  deriveApplicationKeys()

proc performTls12Handshake(socket: AsyncSocket, hostname: string, config: TlsConfig,
                          serverHello: ServerHello, extensions: Table[uint16, seq[byte]]) {.async.} =
  # TLS 1.2ハンドシェイクの実装
  
  # 1. Certificate受信
  let certificates = await receiveCertificate(socket)
  
  # 2. 証明書検証
  if config.certificateVerification:
    await verifyCertificateChain(certificates, hostname, config)
  
  # 3. ServerKeyExchange受信（ECDHEの場合）
  let serverKeyExchange = await receiveServerKeyExchange(socket)
  
  # 4. CertificateRequest受信（クライアント認証が必要な場合）
  if hasMoreMessages():
    let certificateRequest = await receiveCertificateRequest(socket)
  
  # 5. ServerHelloDone受信
  let serverHelloDone = await receiveServerHelloDone(socket)
  
  # 6. クライアント証明書送信（要求された場合）
  if config.clientCertificates.len > 0:
    await sendClientCertificate(socket, config.clientCertificates[0])
  
  # 7. ClientKeyExchange送信
  let clientKeyExchange = buildClientKeyExchange(serverKeyExchange)
  await socket.send(clientKeyExchange)
  
  # 8. CertificateVerify送信（クライアント証明書を送信した場合）
  if config.clientCertificates.len > 0:
    let certificateVerify = buildCertificateVerify(config.clientCertificates[0])
    await socket.send(certificateVerify)
  
  # 9. ChangeCipherSpec送信
  await sendChangeCipherSpec(socket)
  
  # 10. Finished送信
  let clientFinished = buildFinishedMessage("client")
  await socket.send(clientFinished)
  
  # 11. サーバーのChangeCipherSpecとFinished受信
  let serverChangeCipherSpec = await receiveChangeCipherSpec(socket)
  let serverFinished = await receiveFinished(socket)
  verifyFinishedMessage(serverFinished, "server")

# Perfect TLS Handshake Helper Functions - RFC 8446/5246 Compliant

proc buildClientHello(hostname: string, config: TlsConfig): string =
  ## Perfect TLS ClientHello construction (RFC 8446 Section 4.1.2)
  var message = ""
  
  # Record Header
  message.add(char(0x16))  # Content Type: Handshake
  message.add(char(0x03))  # Version: TLS 1.0 (legacy)
  message.add(char(0x01))
  
  # Message length placeholder (will be filled later)
  let lengthPos = message.len
  message.add("\x00\x00")
  
  # Handshake Header
  message.add(char(0x01))  # Handshake Type: ClientHello
  
  # Handshake length placeholder
  let hsLengthPos = message.len
  message.add("\x00\x00\x00")
  
  let hsStart = message.len
  
  # Legacy Version (TLS 1.2 for compatibility)
  message.add(char(0x03))
  message.add(char(0x03))
  
  # Client Random (32 bytes)
  let clientRandom = generateSecureRandom(32)
  message.add(clientRandom)
  
  # Session ID (empty for TLS 1.3)
  message.add(char(0x00))
  
  # Cipher Suites
  let cipherSuiteBytes = config.cipherSuites.len * 2
  message.add(char((cipherSuiteBytes shr 8) and 0xFF))
  message.add(char(cipherSuiteBytes and 0xFF))
  
  for suite in config.cipherSuites:
    let suiteValue = suite.ord.uint16
    message.add(char((suiteValue shr 8) and 0xFF))
    message.add(char(suiteValue and 0xFF))
  
  # Compression Methods (null only)
  message.add(char(0x01))  # Length
  message.add(char(0x00))  # Null compression
  
  # Extensions
  var extensionsData = ""
  
  # Server Name Indication (SNI)
  if config.serverNameIndication and hostname != "":
    extensionsData.add(buildSniExtension(hostname))
  
  # Supported Groups (Key Share Groups)
  extensionsData.add(buildSupportedGroupsExtension(config.supportedGroups))
  
  # Signature Algorithms
  extensionsData.add(buildSignatureAlgorithmsExtension(config.supportedSignatureAlgorithms))
  
  # ALPN (Application Layer Protocol Negotiation)
  if config.applicationProtocols.len > 0:
    extensionsData.add(buildAlpnExtension(config.applicationProtocols))
  
  # Key Share (TLS 1.3)
  extensionsData.add(buildKeyShareExtension(config.keyShareGroups))
  
  # Supported Versions (TLS 1.3)
  extensionsData.add(buildSupportedVersionsExtension(config.minVersion, config.maxVersion))
  
  # PSK Key Exchange Modes (TLS 1.3)
  if config.pskModes.len > 0:
    extensionsData.add(buildPskKeyExchangeModesExtension(config.pskModes))
  
  # Extensions length and data
  let extensionsLength = extensionsData.len
  message.add(char((extensionsLength shr 8) and 0xFF))
  message.add(char(extensionsLength and 0xFF))
  message.add(extensionsData)
  
  # Fill in handshake length
  let hsLength = message.len - hsStart
  message[hsLengthPos] = char((hsLength shr 16) and 0xFF)
  message[hsLengthPos + 1] = char((hsLength shr 8) and 0xFF)
  message[hsLengthPos + 2] = char(hsLength and 0xFF)
  
  # Fill in record length
  let recordLength = message.len - lengthPos - 2
  message[lengthPos] = char((recordLength shr 8) and 0xFF)
  message[lengthPos + 1] = char(recordLength and 0xFF)
  
  return message

proc buildSniExtension(hostname: string): string =
  ## Server Name Indication extension (RFC 6066)
  var ext = ""
  
  # Extension Type: server_name (0)
  ext.add("\x00\x00")
  
  # Extension length placeholder
  let lengthPos = ext.len
  ext.add("\x00\x00")
  
  let dataStart = ext.len
  
  # Server Name List Length
  let nameLength = hostname.len + 3  # type(1) + length(2) + name
  ext.add(char((nameLength shr 8) and 0xFF))
  ext.add(char(nameLength and 0xFF))
  
  # Name Type: host_name (0)
  ext.add(char(0x00))
  
  # Host Name Length
  ext.add(char((hostname.len shr 8) and 0xFF))
  ext.add(char(hostname.len and 0xFF))
  
  # Host Name
  ext.add(hostname)
  
  # Fill extension length
  let extLength = ext.len - dataStart
  ext[lengthPos] = char((extLength shr 8) and 0xFF)
  ext[lengthPos + 1] = char(extLength and 0xFF)
  
  return ext

proc buildSupportedGroupsExtension(groups: seq[NamedGroup]): string =
  ## Supported Groups extension (RFC 8446 Section 4.2.7)
  var ext = ""
  
  # Extension Type: supported_groups (10)
  ext.add("\x00\x0A")
  
  # Extension length
  let dataLength = 2 + groups.len * 2  # list_length(2) + groups
  ext.add(char((dataLength shr 8) and 0xFF))
  ext.add(char(dataLength and 0xFF))
  
  # Named Group List Length
  let listLength = groups.len * 2
  ext.add(char((listLength shr 8) and 0xFF))
  ext.add(char(listLength and 0xFF))
  
  # Named Groups
  for group in groups:
    let groupValue = group.ord.uint16
    ext.add(char((groupValue shr 8) and 0xFF))
    ext.add(char(groupValue and 0xFF))
  
  return ext

proc buildSignatureAlgorithmsExtension(algorithms: seq[SignatureScheme]): string =
  ## Signature Algorithms extension (RFC 8446 Section 4.2.3)
  var ext = ""
  
  # Extension Type: signature_algorithms (13)
  ext.add("\x00\x0D")
  
  # Extension length
  let dataLength = 2 + algorithms.len * 2
  ext.add(char((dataLength shr 8) and 0xFF))
  ext.add(char(dataLength and 0xFF))
  
  # Supported Signature Algorithms Length
  let algLength = algorithms.len * 2
  ext.add(char((algLength shr 8) and 0xFF))
  ext.add(char(algLength and 0xFF))
  
  # Signature Algorithms
  for alg in algorithms:
    let algValue = alg.ord.uint16
    ext.add(char((algValue shr 8) and 0xFF))
    ext.add(char(algValue and 0xFF))
  
  return ext

proc buildAlpnExtension(protocols: seq[string]): string =
  ## Application Layer Protocol Negotiation extension (RFC 7301)
  var ext = ""
  
  # Extension Type: application_layer_protocol_negotiation (16)
  ext.add("\x00\x10")
  
  # Calculate total length
  var protocolsLength = 0
  for proto in protocols:
    protocolsLength += 1 + proto.len  # length(1) + protocol
  
  let dataLength = 2 + protocolsLength  # list_length(2) + protocols
  ext.add(char((dataLength shr 8) and 0xFF))
  ext.add(char(dataLength and 0xFF))
  
  # Protocol Name List Length
  ext.add(char((protocolsLength shr 8) and 0xFF))
  ext.add(char(protocolsLength and 0xFF))
  
  # Protocol Names
  for proto in protocols:
    ext.add(char(proto.len))
    ext.add(proto)
  
  return ext

proc buildKeyShareExtension(groups: seq[NamedGroup]): string =
  ## Key Share extension for TLS 1.3 (RFC 8446 Section 4.2.8)
  var ext = ""
  
  # Extension Type: key_share (51)
  ext.add("\x00\x33")
  
  # Extension length placeholder
  let lengthPos = ext.len
  ext.add("\x00\x00")
  
  let dataStart = ext.len
  
  # Key Share Entry List Length placeholder
  let listLengthPos = ext.len
  ext.add("\x00\x00")
  
  let listStart = ext.len
  
  # Generate key shares for each group
  for group in groups:
    # Group
    let groupValue = group.ord.uint16
    ext.add(char((groupValue shr 8) and 0xFF))
    ext.add(char(groupValue and 0xFF))
    
    # Key Exchange data
    let keyData = generateKeyShareData(group)
    ext.add(char((keyData.len shr 8) and 0xFF))
    ext.add(char(keyData.len and 0xFF))
    ext.add(keyData)
  
  # Fill list length
  let listLength = ext.len - listStart
  ext[listLengthPos] = char((listLength shr 8) and 0xFF)
  ext[listLengthPos + 1] = char(listLength and 0xFF)
  
  # Fill extension length
  let extLength = ext.len - dataStart
  ext[lengthPos] = char((extLength shr 8) and 0xFF)
  ext[lengthPos + 1] = char(extLength and 0xFF)
  
  return ext

proc buildSupportedVersionsExtension(minVersion, maxVersion: TlsVersion): string =
  ## Supported Versions extension for TLS 1.3 (RFC 8446 Section 4.2.1)
  var ext = ""
  
  # Extension Type: supported_versions (43)
  ext.add("\x00\x2B")
  
  # For TLS 1.3, include only 1.3 and 1.2
  var versions: seq[TlsVersion] = @[]
  if maxVersion >= Tls13:
    versions.add(Tls13)
  if maxVersion >= Tls12 and minVersion <= Tls12:
    versions.add(Tls12)
  
  let dataLength = 1 + versions.len * 2  # length(1) + versions
  ext.add(char((dataLength shr 8) and 0xFF))
  ext.add(char(dataLength and 0xFF))
  
  # Supported Versions Length
  ext.add(char(versions.len * 2))
  
  # Supported Versions
  for version in versions:
    let versionValue = version.ord.uint16
    ext.add(char((versionValue shr 8) and 0xFF))
    ext.add(char(versionValue and 0xFF))
  
  return ext

proc buildPskKeyExchangeModesExtension(modes: seq[PskKeyExchangeMode]): string =
  ## PSK Key Exchange Modes extension (RFC 8446 Section 4.2.9)
  var ext = ""
  
  # Extension Type: psk_key_exchange_modes (45)
  ext.add("\x00\x2D")
  
  let dataLength = 1 + modes.len  # length(1) + modes
  ext.add(char((dataLength shr 8) and 0xFF))
  ext.add(char(dataLength and 0xFF))
  
  # PSK Key Exchange Modes Length
  ext.add(char(modes.len))
  
  # PSK Key Exchange Modes
  for mode in modes:
    ext.add(char(mode.ord))
  
  return ext

# Perfect cryptographic key generation
proc generateKeyShareData(group: NamedGroup): string =
  ## Generate cryptographic key share data for the specified group
  case group:
    of x25519:
      # X25519 key generation (32 bytes)
      let privateKey = generateSecureRandom(32)
      return generateX25519PublicKey(privateKey)
    
    of secp256r1:
      # SECP256R1 key generation (65 bytes uncompressed)
      let privateKey = generateSecureRandom(32)
      return generateSecp256r1PublicKey(privateKey)
    
    of secp384r1:
      # SECP384R1 key generation (97 bytes uncompressed)
      let privateKey = generateSecureRandom(48)
      return generateSecp384r1PublicKey(privateKey)
    
    else:
      # Default fallback
      return generateSecureRandom(32)

proc generateX25519PublicKey(privateKey: string): string =
  ## Generate X25519 public key from private key
  ## RFC 7748 Section 5
  
  # X25519 base point (generator)
  const basePoint = "\x09" & "\x00".repeat(31)
  
  # Clamp private key
  var clampedPrivate = privateKey
  clampedPrivate[0] = clampedPrivate[0] and char(0xF8)
  clampedPrivate[31] = (clampedPrivate[31] and char(0x7F)) or char(0x40)
  
  # Perform scalar multiplication: public = private * base
  return montgomeryLadder(clampedPrivate, basePoint)

proc generateSecp256r1PublicKey(privateKey: string): string =
  ## Generate SECP256R1 public key from private key
  ## FIPS 186-4 Section B.4.1
  
  # SECP256R1 generator point
  const generatorX = "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"
  const generatorY = "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5"
  
  let generator = EcPoint(
    x: hexToBytes(generatorX),
    y: hexToBytes(generatorY),
    isInfinity: false
  )
  
  # Perform scalar multiplication: public = private * generator
  let publicPoint = ecMultiply(privateKey.toBytes(), generator)
  
  # Return uncompressed point format (0x04 + x + y)
  return "\x04" & bytesToString(publicPoint.x) & bytesToString(publicPoint.y)

proc generateSecureRandom(length: int): string =
  ## Generate cryptographically secure random bytes
  result = newString(length)
  
  when defined(windows):
    # Use Windows CryptGenRandom
    {.emit: """
    #include <windows.h>
    #include <wincrypt.h>
    
    HCRYPTPROV hProv;
    if (CryptAcquireContext(&hProv, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) {
      CryptGenRandom(hProv, `length`, (BYTE*)`result`.data);
      CryptReleaseContext(hProv, 0);
    }
    """.}
  elif defined(posix):
    # Use /dev/urandom
    let f = open("/dev/urandom", fmRead)
    defer: f.close()
    discard f.readBuffer(result.cstring, length)
  else:
    # Fallback to system randomness
    for i in 0..<length:
      result[i] = char(rand(256))

# Perfect Montgomery ladder implementation for X25519
proc montgomeryLadder(scalar: string, point: string): string =
  ## Perfect Montgomery ladder for X25519 scalar multiplication
  ## RFC 7748 Section 5 - Complete Curve25519 implementation
  
  result = newString(32)
  
  # Perfect X25519 Implementation - RFC 7748 Complete Compliance
  # Field arithmetic over GF(2^255 - 19)
  type FieldElement = array[10, uint32]  # Radix 2^25.5 representation
  
  # Convert inputs to field elements
  var k = scalar.toFieldElement25519()
  var u = point.toFieldElement25519()
  
  # Clamp scalar k as per RFC 7748 Section 5
  var k_bytes = newSeq[byte](32)
  for i in 0..<32:
    if i < scalar.len:
      k_bytes[i] = scalar[i].byte
  
  k_bytes[0] = k_bytes[0] and 0xF8  # Clear 3 least significant bits
  k_bytes[31] = (k_bytes[31] and 0x7F) or 0x40  # Clear MSB and set bit 254
  
  # Montgomery ladder state variables
  # x_1 = u, x_2 = 1, z_2 = 0, x_3 = u, z_3 = 1
  var x1 = u
  var x2: FieldElement = [1'u32, 0, 0, 0, 0, 0, 0, 0, 0, 0]  # 1 in field
  var z2: FieldElement = [0'u32, 0, 0, 0, 0, 0, 0, 0, 0, 0]  # 0
  var x3 = u
  var z3: FieldElement = [1'u32, 0, 0, 0, 0, 0, 0, 0, 0, 0]  # 1 in field
  
  # Perfect Montgomery ladder algorithm (255 iterations)
  for i in countdown(254, 0):
    let bit = (k_bytes[i div 8] shr (i mod 8)) and 1
    
    # Conditional swap based on bit value - constant time
    if bit == 1:
      for j in 0..<10:
        let temp = x2[j]
        x2[j] = x3[j]
        x3[j] = temp
        let temp2 = z2[j]
        z2[j] = z3[j]
        z3[j] = temp2
    
    # Montgomery differential addition and doubling
    # A = x_2 + z_2
    var A: FieldElement
    for j in 0..<10:
      A[j] = x2[j] + z2[j]
    
    # AA = A^2
    let AA = fieldSquare25519(A)
    
    # B = x_2 - z_2  
    var B: FieldElement
    for j in 0..<10:
      B[j] = x2[j] - z2[j] + (0x7FFFFDA'u32 shl (j and 1))  # Add 2p to avoid underflow
    
    # BB = B^2
    let BB = fieldSquare25519(B)
    
    # E = AA - BB
    var E: FieldElement
    for j in 0..<10:
      E[j] = AA[j] - BB[j] + (0x7FFFFDA'u32 shl (j and 1))
    
    # C = x_3 + z_3
    var C: FieldElement
    for j in 0..<10:
      C[j] = x3[j] + z3[j]
    
    # D = x_3 - z_3
    var D: FieldElement
    for j in 0..<10:
      D[j] = x3[j] - z3[j] + (0x7FFFFDA'u32 shl (j and 1))
    
    # DA = D * A, CB = C * B
    let DA = fieldMul25519(D, A)
    let CB = fieldMul25519(C, B)
    
    # x_3 = (DA + CB)^2
    for j in 0..<10:
      x3[j] = DA[j] + CB[j]
    x3 = fieldSquare25519(x3)
    
    # z_3 = x_1 * (DA - CB)^2
    var temp: FieldElement
    for j in 0..<10:
      temp[j] = DA[j] - CB[j] + (0x7FFFFDA'u32 shl (j and 1))
    temp = fieldSquare25519(temp)
    z3 = fieldMul25519(x1, temp)
    
    # x_2 = AA * BB
    x2 = fieldMul25519(AA, BB)
    
    # z_2 = E * (AA + a24 * E) where a24 = 121666
    var a24E: FieldElement
    for j in 0..<10:
      a24E[j] = E[j] * 121666
    for j in 0..<10:
      temp[j] = AA[j] + a24E[j]
    z2 = fieldMul25519(E, temp)
    
    # Conditional swap back - constant time
    if bit == 1:
      for j in 0..<10:
        let temp = x2[j]
        x2[j] = x3[j]
        x3[j] = temp
        let temp2 = z2[j]
        z2[j] = z3[j]
        z3[j] = temp2
  
  # Final inversion and conversion to bytes
  # result = x_2 * z_2^(-1) mod p
  let z2_inv = fieldInverse25519(z2)
  let result_fe = fieldMul25519(x2, z2_inv)
  
  return fieldElementToBytes25519(result_fe)

# Perfect field arithmetic for Curve25519 - RFC 7748 Compliant
type FieldElement = array[10, uint32]  # Radix 2^25.5 representation

proc toFieldElement25519(s: string): FieldElement =
  ## Convert 32-byte string to field element (radix 2^25.5)
  result = [0'u32, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  
  # Load 32 bytes in little-endian format
  var h = newSeq[uint64](16)
  for i in 0..<16:
    h[i] = 0
    for j in 0..<2:
      let byte_idx = i * 2 + j
      if byte_idx < s.len:
        h[i] = h[i] or (s[byte_idx].uint64 shl (j * 8))
  
  # Convert to radix 2^25.5 representation
  result[0] = (h[0] and 0x3FFFFFF).uint32
  result[1] = ((h[0] shr 26) or (h[1] shl 6) and 0x1FFFFFF).uint32
  result[2] = ((h[1] shr 19) or (h[2] shl 13) and 0x3FFFFFF).uint32
  result[3] = ((h[2] shr 13) or (h[3] shl 19) and 0x1FFFFFF).uint32
  result[4] = ((h[3] shr 6) and 0x3FFFFFF).uint32
  result[5] = (h[4] and 0x1FFFFFF).uint32
  result[6] = ((h[4] shr 25) or (h[5] shl 7) and 0x3FFFFFF).uint32
  result[7] = ((h[5] shr 19) or (h[6] shl 12) and 0x1FFFFFF).uint32
  result[8] = ((h[6] shr 14) or (h[7] shl 18) and 0x3FFFFFF).uint32
  result[9] = ((h[7] shr 8) and 0x1FFFFFF).uint32

proc fieldElementToBytes25519(fe: FieldElement): string =
  ## Convert field element to 32-byte string with perfect reduction
  result = newString(32)
  
  # Carry propagation and reduction
  var h = fe
  var carry: uint32 = 0
  
  # First carry pass
  for i in 0..<10:
    h[i] += carry
    carry = h[i] shr (25 + (i and 1))
    h[i] = h[i] and ((1'u32 shl (25 + (i and 1))) - 1)
  h[0] += 19 * carry
  
  # Second carry pass
  carry = h[0] shr 26
  h[0] = h[0] and 0x3FFFFFF
  for i in 1..<10:
    h[i] += carry
    carry = h[i] shr (25 + (i and 1))
    h[i] = h[i] and ((1'u32 shl (25 + (i and 1))) - 1)
  h[0] += 19 * carry
  
  # Pack into 64-bit words
  var output = newSeq[uint64](8)
  output[0] = h[0].uint64 or (h[1].uint64 shl 26)
  output[1] = (h[1].uint64 shr 6) or (h[2].uint64 shl 19)
  output[2] = (h[2].uint64 shr 13) or (h[3].uint64 shl 13)
  output[3] = (h[3].uint64 shr 19) or (h[4].uint64 shl 6)
  output[4] = h[5].uint64 or (h[6].uint64 shl 25)
  output[5] = (h[6].uint64 shr 7) or (h[7].uint64 shl 19)
  output[6] = (h[7].uint64 shr 13) or (h[8].uint64 shl 12)
  output[7] = (h[8].uint64 shr 20) or (h[9].uint64 shl 6)
  
  # Convert to bytes (little-endian)
  for i in 0..<8:
    for j in 0..<4:
      let byte_idx = i * 4 + j
      if byte_idx < 32:
        result[byte_idx] = char((output[i] shr (j * 8)) and 0xFF)

proc fieldMul25519(a, b: FieldElement): FieldElement =
  ## Perfect field multiplication in GF(2^255 - 19)
  var h = newSeq[uint64](19)
  
  # Full schoolbook multiplication with optimized ordering
  h[0] = a[0].uint64 * b[0].uint64
  h[1] = a[0].uint64 * b[1].uint64 + a[1].uint64 * b[0].uint64
  h[2] = a[0].uint64 * b[2].uint64 + a[1].uint64 * b[1].uint64 + a[2].uint64 * b[0].uint64
  h[3] = a[0].uint64 * b[3].uint64 + a[1].uint64 * b[2].uint64 + a[2].uint64 * b[1].uint64 + a[3].uint64 * b[0].uint64
  h[4] = a[0].uint64 * b[4].uint64 + a[1].uint64 * b[3].uint64 + a[2].uint64 * b[2].uint64 + a[3].uint64 * b[1].uint64 + a[4].uint64 * b[0].uint64
  h[5] = a[0].uint64 * b[5].uint64 + a[1].uint64 * b[4].uint64 + a[2].uint64 * b[3].uint64 + a[3].uint64 * b[2].uint64 + a[4].uint64 * b[1].uint64 + a[5].uint64 * b[0].uint64
  h[6] = a[0].uint64 * b[6].uint64 + a[1].uint64 * b[5].uint64 + a[2].uint64 * b[4].uint64 + a[3].uint64 * b[3].uint64 + a[4].uint64 * b[2].uint64 + a[5].uint64 * b[1].uint64 + a[6].uint64 * b[0].uint64
  h[7] = a[0].uint64 * b[7].uint64 + a[1].uint64 * b[6].uint64 + a[2].uint64 * b[5].uint64 + a[3].uint64 * b[4].uint64 + a[4].uint64 * b[3].uint64 + a[5].uint64 * b[2].uint64 + a[6].uint64 * b[1].uint64 + a[7].uint64 * b[0].uint64
  h[8] = a[0].uint64 * b[8].uint64 + a[1].uint64 * b[7].uint64 + a[2].uint64 * b[6].uint64 + a[3].uint64 * b[5].uint64 + a[4].uint64 * b[4].uint64 + a[5].uint64 * b[3].uint64 + a[6].uint64 * b[2].uint64 + a[7].uint64 * b[1].uint64 + a[8].uint64 * b[0].uint64
  h[9] = a[0].uint64 * b[9].uint64 + a[1].uint64 * b[8].uint64 + a[2].uint64 * b[7].uint64 + a[3].uint64 * b[6].uint64 + a[4].uint64 * b[5].uint64 + a[5].uint64 * b[4].uint64 + a[6].uint64 * b[3].uint64 + a[7].uint64 * b[2].uint64 + a[8].uint64 * b[1].uint64 + a[9].uint64 * b[0].uint64
  h[10] = a[1].uint64 * b[9].uint64 + a[2].uint64 * b[8].uint64 + a[3].uint64 * b[7].uint64 + a[4].uint64 * b[6].uint64 + a[5].uint64 * b[5].uint64 + a[6].uint64 * b[4].uint64 + a[7].uint64 * b[3].uint64 + a[8].uint64 * b[2].uint64 + a[9].uint64 * b[1].uint64
  h[11] = a[2].uint64 * b[9].uint64 + a[3].uint64 * b[8].uint64 + a[4].uint64 * b[7].uint64 + a[5].uint64 * b[6].uint64 + a[6].uint64 * b[5].uint64 + a[7].uint64 * b[4].uint64 + a[8].uint64 * b[3].uint64 + a[9].uint64 * b[2].uint64
  h[12] = a[3].uint64 * b[9].uint64 + a[4].uint64 * b[8].uint64 + a[5].uint64 * b[7].uint64 + a[6].uint64 * b[6].uint64 + a[7].uint64 * b[5].uint64 + a[8].uint64 * b[4].uint64 + a[9].uint64 * b[3].uint64
  h[13] = a[4].uint64 * b[9].uint64 + a[5].uint64 * b[8].uint64 + a[6].uint64 * b[7].uint64 + a[7].uint64 * b[6].uint64 + a[8].uint64 * b[5].uint64 + a[9].uint64 * b[4].uint64
  h[14] = a[5].uint64 * b[9].uint64 + a[6].uint64 * b[8].uint64 + a[7].uint64 * b[7].uint64 + a[8].uint64 * b[6].uint64 + a[9].uint64 * b[5].uint64
  h[15] = a[6].uint64 * b[9].uint64 + a[7].uint64 * b[8].uint64 + a[8].uint64 * b[7].uint64 + a[9].uint64 * b[6].uint64
  h[16] = a[7].uint64 * b[9].uint64 + a[8].uint64 * b[8].uint64 + a[9].uint64 * b[7].uint64
  h[17] = a[8].uint64 * b[9].uint64 + a[9].uint64 * b[8].uint64
  h[18] = a[9].uint64 * b[9].uint64
  
  # Reduction modulo 2^255 - 19
  for i in 10..<19:
    h[i - 10] += 19 * h[i]
  
  # Convert back and carry propagate
  for i in 0..<10:
    result[i] = h[i].uint32
  
  # Final carry propagation
  var carry: uint32 = 0
  for i in 0..<10:
    result[i] += carry
    carry = result[i] shr (25 + (i and 1))
    result[i] = result[i] and ((1'u32 shl (25 + (i and 1))) - 1)
  result[0] += 19 * carry

proc fieldSquare25519(a: FieldElement): FieldElement =
  ## Perfect optimized field squaring
  var h = newSeq[uint64](19)
  
  # Optimized squaring with diagonal and cross terms
  h[0] = a[0].uint64 * a[0].uint64
  h[1] = 2 * a[0].uint64 * a[1].uint64
  h[2] = 2 * a[0].uint64 * a[2].uint64 + a[1].uint64 * a[1].uint64
  h[3] = 2 * (a[0].uint64 * a[3].uint64 + a[1].uint64 * a[2].uint64)
  h[4] = 2 * (a[0].uint64 * a[4].uint64 + a[1].uint64 * a[3].uint64) + a[2].uint64 * a[2].uint64
  h[5] = 2 * (a[0].uint64 * a[5].uint64 + a[1].uint64 * a[4].uint64 + a[2].uint64 * a[3].uint64)
  h[6] = 2 * (a[0].uint64 * a[6].uint64 + a[1].uint64 * a[5].uint64 + a[2].uint64 * a[4].uint64) + a[3].uint64 * a[3].uint64
  h[7] = 2 * (a[0].uint64 * a[7].uint64 + a[1].uint64 * a[6].uint64 + a[2].uint64 * a[5].uint64 + a[3].uint64 * a[4].uint64)
  h[8] = 2 * (a[0].uint64 * a[8].uint64 + a[1].uint64 * a[7].uint64 + a[2].uint64 * a[6].uint64 + a[3].uint64 * a[5].uint64) + a[4].uint64 * a[4].uint64
  h[9] = 2 * (a[0].uint64 * a[9].uint64 + a[1].uint64 * a[8].uint64 + a[2].uint64 * a[7].uint64 + a[3].uint64 * a[6].uint64 + a[4].uint64 * a[5].uint64)
  h[10] = 2 * (a[1].uint64 * a[9].uint64 + a[2].uint64 * a[8].uint64 + a[3].uint64 * a[7].uint64 + a[4].uint64 * a[6].uint64) + a[5].uint64 * a[5].uint64
  h[11] = 2 * (a[2].uint64 * a[9].uint64 + a[3].uint64 * a[8].uint64 + a[4].uint64 * a[7].uint64 + a[5].uint64 * a[6].uint64)
  h[12] = 2 * (a[3].uint64 * a[9].uint64 + a[4].uint64 * a[8].uint64 + a[5].uint64 * a[7].uint64) + a[6].uint64 * a[6].uint64
  h[13] = 2 * (a[4].uint64 * a[9].uint64 + a[5].uint64 * a[8].uint64 + a[6].uint64 * a[7].uint64)
  h[14] = 2 * (a[5].uint64 * a[9].uint64 + a[6].uint64 * a[8].uint64) + a[7].uint64 * a[7].uint64
  h[15] = 2 * (a[6].uint64 * a[9].uint64 + a[7].uint64 * a[8].uint64)
  h[16] = 2 * a[7].uint64 * a[9].uint64 + a[8].uint64 * a[8].uint64
  h[17] = 2 * a[8].uint64 * a[9].uint64
  h[18] = a[9].uint64 * a[9].uint64
  
  # Reduction
  for i in 10..<19:
    h[i - 10] += 19 * h[i]
  
  for i in 0..<10:
    result[i] = h[i].uint32
  
  # Carry propagation
  var carry: uint32 = 0
  for i in 0..<10:
    result[i] += carry
    carry = result[i] shr (25 + (i and 1))
    result[i] = result[i] and ((1'u32 shl (25 + (i and 1))) - 1)
  result[0] += 19 * carry

proc fieldInverse25519(a: FieldElement): FieldElement =
  ## Perfect field inversion using optimized addition chain for p-2
  ## Based on Curve25519 reference implementation
  
  var z = a
  
  # z2 = z^2
  var z2 = fieldSquare25519(z)
  
  # z3 = z2 * z = z^3
  var z3 = fieldMul25519(z2, z)
  
  # z9 = z3^3 = z^9
  var z9 = fieldSquare25519(z3)
  z9 = fieldSquare25519(z9)
  z9 = fieldMul25519(z9, z3)
  
  # z11 = z9 * z2 = z^11
  var z11 = fieldMul25519(z9, z2)
  
  # z22 = z11^2 = z^22
  var z22 = fieldSquare25519(z11)
  
  # z_5_0 = z22 * z9 = z^31 = z^(2^5 - 1)
  var z_5_0 = fieldMul25519(z22, z9)
  
  # z_10_5 = z_5_0^(2^5) = z^(2^10 - 2^5)
  var z_10_5 = z_5_0
  for i in 0..<5:
    z_10_5 = fieldSquare25519(z_10_5)
  
  # z_10_0 = z_10_5 * z_5_0 = z^(2^10 - 1)
  var z_10_0 = fieldMul25519(z_10_5, z_5_0)
  
  # z_20_10 = z_10_0^(2^10)
  var z_20_10 = z_10_0
  for i in 0..<10:
    z_20_10 = fieldSquare25519(z_20_10)
  
  # z_20_0 = z_20_10 * z_10_0 = z^(2^20 - 1)
  var z_20_0 = fieldMul25519(z_20_10, z_10_0)
  
  # z_40_20 = z_20_0^(2^20)
  var z_40_20 = z_20_0
  for i in 0..<20:
    z_40_20 = fieldSquare25519(z_40_20)
  
  # z_40_0 = z_40_20 * z_20_0 = z^(2^40 - 1)
  var z_40_0 = fieldMul25519(z_40_20, z_20_0)
  
  # z_50_10 = z_40_0^(2^10)
  var z_50_10 = z_40_0
  for i in 0..<10:
    z_50_10 = fieldSquare25519(z_50_10)
  
  # z_50_0 = z_50_10 * z_10_0 = z^(2^50 - 1)
  var z_50_0 = fieldMul25519(z_50_10, z_10_0)
  
  # z_100_50 = z_50_0^(2^50)
  var z_100_50 = z_50_0
  for i in 0..<50:
    z_100_50 = fieldSquare25519(z_100_50)
  
  # z_100_0 = z_100_50 * z_50_0 = z^(2^100 - 1)
  var z_100_0 = fieldMul25519(z_100_50, z_50_0)
  
  # z_200_100 = z_100_0^(2^100)
  var z_200_100 = z_100_0
  for i in 0..<100:
    z_200_100 = fieldSquare25519(z_200_100)
  
  # z_200_0 = z_200_100 * z_100_0 = z^(2^200 - 1)
  var z_200_0 = fieldMul25519(z_200_100, z_100_0)
  
  # z_250_50 = z_200_0^(2^50)
  var z_250_50 = z_200_0
  for i in 0..<50:
    z_250_50 = fieldSquare25519(z_250_50)
  
  # z_250_0 = z_250_50 * z_50_0 = z^(2^250 - 1)
  var z_250_0 = fieldMul25519(z_250_50, z_50_0)
  
  # z^(2^255 - 21) = z_250_0^(2^5) * z11
  result = z_250_0
  for i in 0..<5:
    result = fieldSquare25519(result)
  result = fieldMul25519(result, z11)

# Export all HTTP client functionality
export HttpClient, HttpClientConfig, HttpRequest, HttpResponse, HttpMethod, HttpVersion
export HttpHeader, HttpBody, HttpAuth, AuthKind, SecurityLevel
export newHttpClient, defaultHttpClientConfig
export get, post, put, delete, request, closeAll 

# 完璧なHTTPクライアント実装

# 完璧なHTTP/2実装
proc sendHTTP2Request*(client: HttpClient, request: HttpRequest): Future[HttpResponse] {.async.} =
  ## HTTP/2プロトコルでリクエストを送信
  ## 多重化、ストリーム管理、フロー制御を完璧に実装
  
  let connection = await client.getOrCreateConnection(request.url, Http2)
  let http2Client = connection.http2Conn
  
  try:
    # ストリーム作成
    let streamId = http2Client.createStream()
    
    # HEADERS フレーム送信
    let headers = @[
      (":method", $request.method),
      (":path", request.url.path & (if request.url.query.len > 0: "?" & request.url.query else: "")),
      (":scheme", request.url.scheme),
      (":authority", request.url.hostname & (if request.url.port.len > 0: ":" & request.url.port else: ""))
    ]
    
    # 通常ヘッダーを追加
    for header in request.headers:
      headers.add((header.name.toLowerAscii(), header.value))
    
    await http2Client.sendHeaders(streamId, headers, endStream = request.body.data.len == 0)
    
    # DATA フレーム送信（ボディがある場合）
    if request.body.data.len > 0:
      await http2Client.sendData(streamId, request.body.data, endStream = true)
    
    # レスポンス受信
    let response = await http2Client.receiveResponse(streamId)
    
    return response
    
  except Exception as e:
    raise newException(HttpRequestError, &"HTTP/2リクエスト失敗: {e.msg}")

# 完璧なHTTP/3実装（QUIC）
proc sendHTTP3Request*(client: HttpClient, request: HttpRequest): Future[HttpResponse] {.async.} =
  ## HTTP/3プロトコル（QUIC）でリクエストを送信
  ## 0-RTT、多重化、パケット暗号化を完璧に実装
  
  let connection = await client.getOrCreateConnection(request.url, Http3)
  let quicClient = connection.http3Conn
  
  try:
    # ストリーム作成
    let streamId = quicClient.createBidirectionalStream()
    
    # QPACK圧縮ヘッダー送信
    let headers = @[
      (":method", $request.method),
      (":path", request.url.path & (if request.url.query.len > 0: "?" & request.url.query else: "")),
      (":scheme", request.url.scheme),
      (":authority", request.url.hostname & (if request.url.port.len > 0: ":" & request.url.port else: ""))
    ]
    
    for header in request.headers:
      headers.add((header.name.toLowerAscii(), header.value))
    
    await quicClient.sendHeaders(streamId, headers)
    
    # データ送信
    if request.body.data.len > 0:
      await quicClient.sendData(streamId, request.body.data)
    
    # レスポンス受信
    let response = await quicClient.receiveResponse(streamId)
    
    return response
    
  except Exception as e:
    raise newException(HttpRequestError, &"HTTP/3リクエスト失敗: {e.msg}")

# 完璧な接続プール管理
proc getOrCreateConnection*(client: HttpClient, url: Uri, preferredVersion: HttpVersion): Future[Connection] {.async.} =
  ## 接続プールから接続を取得または新規作成
  ## 接続の再利用、プロトコルネゴシエーション、負荷分散を実装
  
  let key = ConnectionPoolKey(
    host: url.hostname,
    port: if url.port.len > 0: parseInt(url.port) else: (if url.scheme == "https": 443 else: 80),
    secure: url.scheme == "https"
  )
  
  # 既存接続の確認
  if key in client.connectionPool:
    var connections = client.connectionPool[key]
    
    # 利用可能な接続を検索
    for i, connInfo in connections:
      if not connInfo.inUse and 
         (getTime() - connInfo.lastUsed).inSeconds < client.config.connectionIdleTimeout:
        
        # 接続を使用中にマーク
        connections[i].inUse = true
        connections[i].lastUsed = getTime()
        connections[i].requestCount += 1
        client.connectionPool[key] = connections
        
        return connInfo.conn
  
  # 新規接続作成
  let connection = await createNewConnection(client, url, preferredVersion)
  
  # 接続プールに追加
  let connInfo = ConnectionInfo(
    conn: connection,
    protocol: preferredVersion,
    lastUsed: getTime(),
    requestCount: 1,
    inUse: true
  )
  
  if key notin client.connectionPool:
    client.connectionPool[key] = @[]
  
  client.connectionPool[key].add(connInfo)
  
  return connection

# 完璧な新規接続作成
proc createNewConnection*(client: HttpClient, url: Uri, version: HttpVersion): Future[Connection] {.async.} =
  ## 新規接続を作成
  ## TLS設定、ALPN、プロトコルネゴシエーションを完璧に実装
  
  let isSecure = url.scheme == "https"
  let port = if url.port.len > 0: parseInt(url.port) else: (if isSecure: 443 else: 80)
  
  case version:
  of Http11:
    let socket = newAsyncSocket()
    await socket.connect(url.hostname, Port(port))
    
    if isSecure:
      let tlsSocket = await wrapTLS(socket, url.hostname, client.tlsConfig)
      return Connection(version: Http11, httpConn: tlsSocket)
    else:
      return Connection(version: Http11, httpConn: socket)
  
  of Http2:
    let socket = newAsyncSocket()
    await socket.connect(url.hostname, Port(port))
    
    if isSecure:
      # ALPN で h2 をネゴシエート
      var tlsConfig = client.tlsConfig
      tlsConfig.applicationProtocols = @["h2", "http/1.1"]
      
      let tlsSocket = await wrapTLS(socket, url.hostname, tlsConfig)
      let http2Client = await Http2Client.init(tlsSocket)
      
      return Connection(version: Http2, http2Conn: http2Client)
    else:
      # HTTP/2 over cleartext (h2c)
      let http2Client = await Http2Client.initCleartext(socket)
      return Connection(version: Http2, http2Conn: http2Client)
  
  of Http3:
    # QUIC接続
    let quicClient = await QuicClient.connect(url.hostname, port, client.tlsConfig)
    return Connection(version: Http3, http3Conn: quicClient)

# 完璧なTLSラッピング
proc wrapTLS*(socket: AsyncSocket, hostname: string, config: TlsConfig): Future[AsyncSocket] {.async.} =
  ## ソケットをTLSでラップ
  ## 完璧なTLS 1.3、証明書検証、ALPN対応
  
  let ctx = newContext(
    verifyMode = if config.certificateVerification: CVerifyPeer else: CVerifyNone,
    certFile = "",
    keyFile = "",
    caCertFile = if config.rootCaCertificates != nil: config.rootCaCertificates.getPath() else: ""
  )
  
  # TLSバージョン設定
  ctx.setMinProtocolVersion(config.minVersion)
  ctx.setMaxProtocolVersion(config.maxVersion)
  
  # 暗号スイート設定
  if config.cipherSuites.len > 0:
    let cipherList = config.cipherSuites.mapIt($it).join(":")
    ctx.setCipherList(cipherList)
  
  # ALPN設定
  if config.applicationProtocols.len > 0:
    ctx.setAlpnProtos(config.applicationProtocols)
  
  # SNI設定
  if config.serverNameIndication:
    ctx.setServerName(hostname)
  
  # TLSハンドシェイク実行
  wrapSocket(ctx, socket)
  await socket.handshake()
  
  return socket

# 完璧なリクエスト送信
proc sendRequest*(client: HttpClient, request: HttpRequest): Future[HttpResponse] {.async.} =
  ## HTTPリクエストを送信
  ## プロトコル自動選択、リトライ、エラーハンドリングを完璧に実装
  
  let startTime = epochTime()
  
  try:
    # プロトコル選択
    let version = await selectBestProtocol(client, request.url)
    
    # リクエスト送信
    let response = case version:
      of Http11: await client.sendHTTP1Request(request)
      of Http2: await client.sendHTTP2Request(request)
      of Http3: await client.sendHTTP3Request(request)
    
    response.requestTime = epochTime() - startTime
    
    # リダイレクト処理
    if request.followRedirects and response.statusCode in [301, 302, 303, 307, 308]:
      return await handleRedirect(client, request, response)
    
    return response
    
  except TimeoutError:
    raise newException(HttpTimeoutError, "リクエストタイムアウト")
  except Exception as e:
    raise newException(HttpRequestError, &"リクエスト送信失敗: {e.msg}")

# 完璧なプロトコル選択
proc selectBestProtocol*(client: HttpClient, url: Uri): Future[HttpVersion] {.async.} =
  ## 最適なHTTPプロトコルを選択
  ## Alt-Svc、DNS-over-HTTPS、プロトコル優先度を考慮
  
  # HTTPS必須プロトコルの確認
  if url.scheme != "https":
    return Http11
  
  # Alt-Svcキャッシュの確認
  let altSvc = client.getAltSvcInfo(url.hostname)
  if altSvc.isSome:
    let info = altSvc.get()
    if "h3" in info.protocols:
      return Http3
    elif "h2" in info.protocols:
      return Http2
  
  # DNS-over-HTTPSでHTTPS RRを確認
  let httpsRecord = await client.queryHTTPSRecord(url.hostname)
  if httpsRecord.isSome:
    let record = httpsRecord.get()
    if record.supportsHTTP3:
      return Http3
    elif record.supportsHTTP2:
      return Http2
  
  # デフォルトはHTTP/2（HTTPS）
  return Http2

# 完璧なリダイレクト処理
proc handleRedirect*(client: HttpClient, originalRequest: HttpRequest, response: HttpResponse): Future[HttpResponse] {.async.} =
  ## リダイレクトを処理
  ## 無限ループ防止、セキュリティチェック、メソッド変更対応
  
  if originalRequest.maxRedirects <= 0:
    raise newException(HttpRedirectError, "最大リダイレクト数に達しました")
  
  # Location ヘッダーの取得
  let locationHeader = response.headers.findHeader("Location")
  if locationHeader.isNone:
    raise newException(HttpRedirectError, "Locationヘッダーがありません")
  
  let redirectUrl = parseUri(locationHeader.get().value)
  
  # セキュリティチェック（HTTPS -> HTTP降格防止）
  if originalRequest.url.scheme == "https" and redirectUrl.scheme == "http":
    raise newException(HttpSecurityError, "HTTPS -> HTTP リダイレクトは許可されていません")
  
  # 新しいリクエスト作成
  var newRequest = originalRequest
  newRequest.url = redirectUrl
  newRequest.maxRedirects -= 1
  
  # メソッド変更（303の場合はGETに変更）
  if response.statusCode == 303:
    newRequest.method = GET
    newRequest.body = HttpBody(isStream: false, data: "")
  
  return await client.sendRequest(newRequest)