# HTTP/2 Client Implementation
#
# HTTP/2プロトコルを使用するクライアント実装

import std/[asyncdispatch, asyncnet, strutils, tables, options, uri, strformat, times]
import std/[deques, hashes, sequtils, random, endians, sets]
import std/[net, openssl]
import ./http2_protocol

# 型定義
type
  Http2ClientError* = object of CatchableError
  
  Http2Method* = enum
    GET = "GET"
    POST = "POST"
    PUT = "PUT"
    DELETE = "DELETE"
    HEAD = "HEAD"
    OPTIONS = "OPTIONS"
    PATCH = "PATCH"
    TRACE = "TRACE"
    CONNECT = "CONNECT"
  
  Http2Header* = tuple[name: string, value: string]
  
  Http2Body* = object
    case isStream*: bool
    of true:
      stream*: AsyncStream
    of false:
      data*: string
  
  Http2Response* = ref object
    statusCode*: int
    headers*: seq[Http2Header]
    body*: Http2Body
    version*: string
    streamId*: uint32
    error*: uint32
    
  Http2Request* = ref object
    url*: Uri
    method*: Http2Method
    headers*: seq[Http2Header]
    body*: Http2Body
    timeout*: int  # ミリ秒

  Http2Client* = ref object
    socket*: AsyncSocket
    secure*: bool
    host*: string
    port*: int
    
    # TLS設定
    ctx*: SslContext
    ssl*: SslPtr
    
    # 接続管理
    connected*: bool
    lastStreamId*: uint32
    nextStreamId*: uint32
    goawayReceived*: bool
    
    # ストリーム管理
    streams*: Table[uint32, Http2Stream]
    
    # フロー制御
    connectionSendWindow*: int32
    connectionRecvWindow*: int32
    
    # HPACK
    encoder*: HPACKEncoder
    decoder*: HPACKDecoder
    
    # 設定
    localSettings*: Http2Settings
    remoteSettings*: Http2Settings
    
    # 処理キュー
    frameQueue*: Deque[Http2Frame]
    processingFrames*: bool
    
    # イベント処理
    closed*: bool
    closeFuture*: Future[void]
    receiveTask*: Future[void]
    sendTask*: Future[void]

  AsyncStream* = ref object
    readable*: AsyncEvent
    readerClosed*: bool
    writerClosed*: bool
    buffer: Deque[string]
    maxBufferSize: int

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

# TLS接続ヘルパー
proc setupTls(client: Http2Client): Future[bool] {.async.} =
  # OpenSSL 初期化
  client.ctx = newContext(protVersion = protTLSv1_2, verifyMode = CVerifyPeer)
  
  # ALPN設定
  var alpnProtos = @["h2"]
  client.ctx.setAlpnProtocols(alpnProtos)
  
  # CTXをSSLに適用
  client.ssl = newSSL(client.ctx)
  
  # ホスト名設定
  client.ssl.setTlsExtHostname(client.host)
  
  # SSL接続を確立
  client.ssl.setSslSock(cast[SocketHandle](client.socket.getFd()))
  
  # ハンドシェイク
  var ret = client.ssl.handshake()
  while ret <= 0:
    let err = client.ssl.getError(ret)
    if err == SSL_ERROR_WANT_READ:
      await client.socket.waitForData()
    elif err == SSL_ERROR_WANT_WRITE:
      await client.socket.sendNotify()
    else:
      return false
    
    ret = client.ssl.handshake()
  
  # ALPNプロトコル確認
  let selectedProto = client.ssl.getAlpnSelected()
  return selectedProto == "h2"

# HTTP/2クライアントの実装
proc newHttp2Client*(host: string, port: int, secure: bool = true): Future[Http2Client] {.async.} =
  var client = Http2Client(
    host: host,
    port: port,
    secure: secure,
    connected: false,
    lastStreamId: 0,
    nextStreamId: 1,  # クライアント発行は奇数から
    goawayReceived: false,
    streams: initTable[uint32, Http2Stream](),
    connectionSendWindow: DefaultInitialWindowSize.int32,
    connectionRecvWindow: DefaultInitialWindowSize.int32,
    localSettings: newHttp2Settings(),
    remoteSettings: newHttp2Settings(),
    frameQueue: initDeque[Http2Frame](),
    processingFrames: false,
    closed: false,
    closeFuture: newFuture[void]("http2.client.close")
  )
  
  # ソケット作成
  client.socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  
  # 接続
  await client.socket.connect(host, Port(port))
  
  # TLS設定（必要な場合）
  if secure:
    let success = await client.setupTls()
    if not success:
      raise newException(Http2ClientError, "TLS handshake failed or ALPN negotiation failed")
  
  # HPACK初期化
  client.encoder = newHPACKEncoder(DefaultHeaderTableSize)
  client.decoder = newHPACKDecoder(DefaultHeaderTableSize)
  
  # HTTP/2接続プリフェイス送信
  await client.socket.send(Http2ConnectionPreface)
  
  # 初期SETTINGS送信
  var settings: seq[Http2SettingsParam] = @[
    Http2SettingsParam(identifier: SettingsHeaderTableSize, value: client.localSettings.headerTableSize),
    Http2SettingsParam(identifier: SettingsEnablePush, value: (if client.localSettings.enablePush: 1'u32 else: 0'u32)),
    Http2SettingsParam(identifier: SettingsMaxConcurrentStreams, value: client.localSettings.maxConcurrentStreams),
    Http2SettingsParam(identifier: SettingsInitialWindowSize, value: client.localSettings.initialWindowSize),
    Http2SettingsParam(identifier: SettingsMaxFrameSize, value: client.localSettings.maxFrameSize),
    Http2SettingsParam(identifier: SettingsMaxHeaderListSize, value: client.localSettings.maxHeaderListSize)
  ]
  
  let settingsPayload = serializeSettingsPayload(settings)
  
  var settingsFrame = Http2Frame(
    length: settingsPayload.len.uint32,
    typ: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: settingsPayload
  )
  
  await client.sendFrame(settingsFrame)
  
  # 初期SETTINGSフレームを待機
  var frame = await client.recvFrame()
  
  if frame.typ != FrameSettings:
    raise newException(Http2ClientError, "Expected SETTINGS frame, got: " & $frame.typ)
  
  # SETTINGSを処理
  client.processFrame(frame)
  
  # バックグラウンドタスク開始
  client.receiveTask = frameReceiver(client)
  client.sendTask = frameSender(client)
  
  client.connected = true
  return client

proc close*(client: Http2Client): Future[void] {.async.} =
  if client.closed:
    return
  
  client.closed = true
  
  # GOAWAYフレーム送信
  var goawayFrame = Http2Frame(
    length: 8,
    typ: FrameGoaway,
    flags: 0,
    streamId: 0,
    payload: newString(8)
  )
  
  let
    networkLastStreamId = hostToNetwork32(client.lastStreamId)
    networkErrorCode = hostToNetwork32(ErrorNoError)
  
  copyMem(addr goawayFrame.payload[0], unsafeAddr networkLastStreamId, 4)
  copyMem(addr goawayFrame.payload[4], unsafeAddr networkErrorCode, 4)
  
  try:
    await client.sendFrame(goawayFrame)
  except:
    discard
  
  # バックグラウンドタスクの終了を待機
  if not client.receiveTask.finished:
    client.receiveTask.cancel()
  
  if not client.sendTask.finished:
    client.sendTask.cancel()
  
  # 接続クローズ
  if client.secure and client.ssl != nil:
    discard client.ssl.shutdown()
    client.ssl.free()
    client.ctx.free()
  
  client.socket.close()
  
  # 接続クローズフューチャーを完了としてマーク
  if not client.closeFuture.finished:
    client.closeFuture.complete()

proc createStream*(client: Http2Client): Future[uint32] {.async.} =
  if client.closed or client.goawayReceived:
    raise newException(Http2ClientError, "Connection closed")
  
  let streamId = client.nextStreamId
  client.nextStreamId += 2  # クライアント発行は奇数
  
  client.streams[streamId] = newHttp2Stream(streamId)
  return streamId

proc sendRequest*(client: Http2Client, url: Uri, method: HttpMethod, 
                  headers: seq[Http2Header], body: Http2Body, 
                  timeout: int = 30000): Future[Http2Response] {.async.} =
  # ストリーム作成
  let streamId = await client.createStream()
  let stream = client.streams[streamId]
  
  # ヘッダー準備
  var requestHeaders = headers
  
  # 必須ヘッダー
  let
    scheme = if client.secure: "https" else: "http"
    authority = url.hostname & (if url.port == "": "" else: ":" & url.port)
    path = if url.path == "": "/" else: url.path & (if url.query == "": "" else: "?" & url.query)
  
  requestHeaders.add((":method", $method))
  requestHeaders.add((":scheme", scheme))
  requestHeaders.add((":authority", authority))
  requestHeaders.add((":path", path))
  
  # ボディがある場合、Content-Lengthを追加
  if not body.isStream and body.data.len > 0:
    var hasContentLength = false
    for header in requestHeaders:
      if header.name.toLowerAscii() == "content-length":
        hasContentLength = true
        break
    
    if not hasContentLength:
      requestHeaders.add(("content-length", $body.data.len))
  
  # HEADERSフレーム送信
  let encodedHeaders = client.encoder.encodeHeaders(requestHeaders)
  
  var flags = 0'u8
  
  # ボディがない場合はENDSTREAMフラグを設定
  if (not body.isStream and body.data.len == 0) or (body.isStream and body.stream.writerClosed):
    flags = flags or FlagEndStream
  
  flags = flags or FlagEndHeaders  # 常にENDHEADERSフラグを設定
  
  var headersFrame = Http2Frame(
    length: encodedHeaders.len.uint32,
    typ: FrameHeaders,
    flags: flags,
    streamId: streamId,
    payload: encodedHeaders
  )
  
  await client.sendFrame(headersFrame)
  
  # ボディ送信（ある場合）
  if not (flags and FlagEndStream) != 0:
    if not body.isStream:
      # 固定サイズのボディ
      let maxFrameSize = client.remoteSettings.maxFrameSize.int
      var offset = 0
      
      while offset < body.data.len:
        let remaining = body.data.len - offset
        let chunkSize = min(remaining, maxFrameSize)
        let isLastChunk = offset + chunkSize >= body.data.len
        
        var dataFrame = Http2Frame(
          length: chunkSize.uint32,
          typ: FrameData,
          flags: if isLastChunk: FlagEndStream else: 0,
          streamId: streamId,
          payload: body.data[offset ..< offset + chunkSize]
        )
        
        await client.sendFrame(dataFrame)
        offset += chunkSize
    else:
      # ストリーミングボディ
      let maxFrameSize = client.remoteSettings.maxFrameSize.int
      
      while true:
        let chunk = await body.stream.read(maxFrameSize)
        if chunk.isNone:
          # ストリーム終了
          var dataFrame = Http2Frame(
            length: 0,
            typ: FrameData,
            flags: FlagEndStream,
            streamId: streamId,
            payload: ""
          )
          
          await client.sendFrame(dataFrame)
          break
        
        let isLastChunk = body.stream.writerClosed and body.stream.buffer.len == 0
        
        var dataFrame = Http2Frame(
          length: chunk.get().len.uint32,
          typ: FrameData,
          flags: if isLastChunk: FlagEndStream else: 0,
          streamId: streamId,
          payload: chunk.get()
        )
        
        await client.sendFrame(dataFrame)
  
  # レスポンス待機
  let timeoutFuture = sleepAsync(timeout)
  let completionFuture = stream.completionFuture
  
  let firstFuture = await firstCompletedFuture(completionFuture, timeoutFuture)
  
  if firstFuture == timeoutFuture:
    # リクエストタイムアウト
    # ストリームをリセット
    var rstFrame = Http2Frame(
      length: 4,
      typ: FrameRstStream,
      flags: 0,
      streamId: streamId,
      payload: newString(4)
    )
    
    let errorCode = hostToNetwork32(ErrorCancel)
    copyMem(addr rstFrame.payload[0], unsafeAddr errorCode, 4)
    
    await client.sendFrame(rstFrame)
    
    raise newException(Http2ClientError, "Request timed out")
  
  # レスポンスヘッダーを解析
  var statusCode = 200
  var responseHeaders: seq[Http2Header] = @[]
  
  for header in stream.headers:
    if header.name == ":status":
      try:
        statusCode = parseInt(header.value)
      except:
        statusCode = 200
    elif not header.name.startsWith(":"):
      responseHeaders.add(header)
  
  # レスポンスボディを構築
  var responseBody: string = ""
  
  while stream.dataQueue.len > 0:
    responseBody.add(stream.dataQueue.popFirst())
  
  # HTTP/2レスポンスオブジェクト作成
  let response = Http2Response(
    statusCode: statusCode,
    headers: responseHeaders,
    body: Http2Body(isStream: false, data: responseBody),
    version: "HTTP/2",
    streamId: streamId,
    error: stream.error
  )
  
  return response

# バックグラウンド処理タスク
proc frameReceiver(client: Http2Client) {.async.} =
  try:
    while not client.closed:
      var frame = await client.recvFrame()
      client.processFrame(frame)
  except:
    # エラーが発生した場合は接続をクローズ
    if not client.closed:
      asyncCheck client.close()

proc frameSender(client: Http2Client) {.async.} =
  try:
    while not client.closed:
      # 送信キューが空になるまで待機
      if client.frameQueue.len == 0:
        await sleepAsync(1)
        continue
      
      # キューからフレームを取得
      let frame = client.frameQueue.popFirst()
      
      # フレームを送信
      await client.sendFrame(frame)
  except:
    # エラーが発生した場合は接続をクローズ
    if not client.closed:
      asyncCheck client.close()

# 便利なショートカットメソッド
proc get*(client: Http2Client, url: string, headers: seq[Http2Header] = @[]): Future[Http2Response] {.async.} =
  return await client.sendRequest(parseUri(url), HttpGet, headers, Http2Body(isStream: false, data: ""))

proc post*(client: Http2Client, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
          headers: seq[Http2Header] = @[]): Future[Http2Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  return await client.sendRequest(parseUri(url), HttpPost, requestHeaders, Http2Body(isStream: false, data: body))

proc put*(client: Http2Client, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
         headers: seq[Http2Header] = @[]): Future[Http2Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  return await client.sendRequest(parseUri(url), HttpPut, requestHeaders, Http2Body(isStream: false, data: body))

proc delete*(client: Http2Client, url: string, headers: seq[Http2Header] = @[]): Future[Http2Response] {.async.} =
  return await client.sendRequest(parseUri(url), HttpDelete, headers, Http2Body(isStream: false, data: "")) 