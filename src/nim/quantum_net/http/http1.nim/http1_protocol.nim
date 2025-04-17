# HTTP/1.1 Protocol Implementation
#
# HTTP/1.1プロトコルの完全な実装
# RFC 2616, RFC 7230-7235に準拠

import std/[asyncdispatch, asyncnet, strutils, tables, options, uri, strformat, times]
import std/httpcore
import std/streams
import std/sequtils
import ../../quantum_arch/threading/thread_pool
import ../../compression/gzip
import ../../compression/deflate
import ../../compression/brotli

type
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
    version*: string
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
    version*: string
    timeout*: int  # ミリ秒
  
  AsyncStream* = ref object
    readable*: AsyncEvent
    readerClosed*: bool
    writerClosed*: bool
    buffer: Deque[string]
    maxBufferSize: int
  
  ChunkedState = enum
    ChunkSize, ChunkData, ChunkTrailer, ChunkEnd
  
  HttpParserState = enum
    StatusLine, Headers, Body, Done, Error

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

# ヘッダー操作ユーティリティ
proc getHeader(headers: seq[HttpHeader], name: string): Option[string] =
  for header in headers:
    if header.name.toLowerAscii() == name.toLowerAscii():
      return some(header.value)
  
  return none(string)

proc hasHeader(headers: seq[HttpHeader], name: string): bool =
  for header in headers:
    if header.name.toLowerAscii() == name.toLowerAscii():
      return true
  
  return false

proc addHeader(headers: var seq[HttpHeader], name, value: string) =
  headers.add((name, value))

proc replaceHeader(headers: var seq[HttpHeader], name, value: string) =
  var found = false
  for i in 0 ..< headers.len:
    if headers[i].name.toLowerAscii() == name.toLowerAscii():
      headers[i] = (name, value)
      found = true
      break
  
  if not found:
    headers.add((name, value))

# HTTP/1.1 パーサー
proc parseStatusLine(line: string): tuple[version: string, statusCode: int, reasonPhrase: string] =
  let parts = line.split(' ', maxsplit=2)
  if parts.len < 3:
    raise newException(ValueError, "Invalid status line: " & line)
  
  let statusCode = try:
    parseInt(parts[1])
  except:
    raise newException(ValueError, "Invalid status code: " & parts[1])
  
  return (parts[0], statusCode, parts[2])

proc parseHeaders(headerLines: seq[string]): seq[HttpHeader] =
  result = @[]
  
  for line in headerLines:
    if line.len == 0:
      continue
    
    let colonPos = line.find(':')
    if colonPos < 0:
      raise newException(ValueError, "Invalid header line: " & line)
    
    let name = line[0 ..< colonPos].strip()
    let value = line[colonPos + 1 .. ^1].strip()
    
    result.add((name, value))

# デコーダー
proc decodeChunkedBody(socket: AsyncSocket, timeout: int = 30000): Future[tuple[body: string, trailers: seq[HttpHeader]]] {.async.} =
  var buffer = ""
  var result = ""
  var trailers: seq[HttpHeader] = @[]
  var state = ChunkSize
  var chunkSize = 0
  var bytesRead = 0
  
  let timeoutFuture = sleepAsync(timeout)
  
  while state != ChunkEnd:
    if state == ChunkSize:
      # チャンクサイズ行を読み取る
      var line = ""
      while not line.endsWith("\r\n"):
        let c = await socket.recv(1)
        if c.len == 0:
          raise newException(IOError, "Connection closed while reading chunk size")
        
        line.add(c)
        
        if line.len > 1024:
          raise newException(IOError, "Chunk size line too long")
      
      # 行から16進数のサイズを抽出
      let hexSize = line.strip().split(';')[0]
      chunkSize = parseHexInt(hexSize)
      
      if chunkSize == 0:
        state = ChunkTrailer
      else:
        state = ChunkData
        bytesRead = 0
    
    elif state == ChunkData:
      # チャンクデータを読み取る
      let remaining = chunkSize - bytesRead
      let data = await socket.recv(remaining)
      
      if data.len == 0:
        raise newException(IOError, "Connection closed while reading chunk data")
      
      result.add(data)
      bytesRead += data.len
      
      if bytesRead >= chunkSize:
        # チャンク終端の CRLF を読み飛ばす
        let crlf = await socket.recv(2)
        if crlf != "\r\n":
          raise newException(IOError, "Invalid chunk data terminator")
        
        state = ChunkSize
    
    elif state == ChunkTrailer:
      # トレーラーヘッダーを読み取る
      var headerLines: seq[string] = @[]
      var line = ""
      
      while true:
        let c = await socket.recv(1)
        if c.len == 0:
          raise newException(IOError, "Connection closed while reading trailers")
        
        line.add(c)
        
        if line.endsWith("\r\n"):
          if line == "\r\n":
            # 空行で終了
            state = ChunkEnd
            break
          
          headerLines.add(line.strip())
          line = ""
      
      trailers = parseHeaders(headerLines)
  
  return (result, trailers)

proc decodeContentLengthBody(socket: AsyncSocket, contentLength: int, timeout: int = 30000): Future[string] {.async.} =
  var result = ""
  var bytesRead = 0
  
  while bytesRead < contentLength:
    let remaining = contentLength - bytesRead
    let data = await socket.recv(min(4096, remaining))
    
    if data.len == 0:
      raise newException(IOError, "Connection closed while reading body")
    
    result.add(data)
    bytesRead += data.len
  
  return result

# HTTP/1.1 リクエスト送信
proc sendRequest*(socket: AsyncSocket, url: Uri, httpMethod: HttpMethod, 
                 headers: seq[HttpHeader], body: HttpBody, timeout: int = 30000): Future[HttpResponse] {.async.} =
  let startTime = epochTime()
  
  # リクエストラインの構築
  let path = if url.path == "": "/" else: url.path
  let queryStr = if url.query == "": "" else: "?" & url.query
  let requestLine = $httpMethod & " " & path & queryStr & " HTTP/1.1\r\n"
  
  # ヘッダーの準備
  var requestHeaders = headers
  
  # 必須ヘッダーの追加
  if not hasHeader(requestHeaders, "Host"):
    addHeader(requestHeaders, "Host", url.hostname & (if url.port == "": "" else: ":" & url.port))
  
  # Content-Lengthヘッダーの設定
  var contentLength = 0
  if not body.isStream and body.data.len > 0:
    contentLength = body.data.len
    replaceHeader(requestHeaders, "Content-Length", $contentLength)
  
  # Connectionヘッダーの設定（Keep-Alive はデフォルト）
  if not hasHeader(requestHeaders, "Connection"):
    addHeader(requestHeaders, "Connection", "keep-alive")
  
  # ヘッダー文字列の構築
  var headerStr = ""
  for (name, value) in requestHeaders:
    headerStr.add(name & ": " & value & "\r\n")
  
  # リクエスト本文の終端
  headerStr.add("\r\n")
  
  # リクエスト送信
  socket.send(requestLine & headerStr)
  
  # ボディの送信
  if not body.isStream and body.data.len > 0:
    socket.send(body.data)
  elif body.isStream:
    while true:
      let data = await body.stream.read()
      if data.isNone:
        break
      socket.send(data.get())
  
  # レスポンス解析
  var state = StatusLine
  var response = HttpResponse(
    headers: @[],
    body: HttpBody(isStream: false, data: ""),
    keepAlive: true
  )
  
  var buffer = ""
  var headerLines: seq[string] = @[]
  var currentLine = ""
  
  # レスポンスの読み取りとパース
  while state != Done and state != Error:
    let data = await socket.recv(4096)
    if data.len == 0:
      if state != Body:
        state = Error
        raise newException(IOError, "Connection closed unexpectedly")
      break
    
    buffer.add(data)
    
    # バッファを処理
    while buffer.len > 0:
      case state
      of StatusLine:
        let nlPos = buffer.find("\r\n")
        if nlPos >= 0:
          currentLine = buffer[0 ..< nlPos]
          buffer = buffer[nlPos + 2 .. ^1]
          
          try:
            let status = parseStatusLine(currentLine)
            response.version = status.version
            response.statusCode = status.statusCode
            response.reasonPhrase = status.reasonPhrase
            state = Headers
          except:
            state = Error
            raise getCurrentException()
        else:
          break
      
      of Headers:
        let nlPos = buffer.find("\r\n")
        if nlPos >= 0:
          currentLine = buffer[0 ..< nlPos]
          buffer = buffer[nlPos + 2 .. ^1]
          
          if currentLine == "":
            # ヘッダー終了、本文開始
            state = Body
            
            # ヘッダーの解析
            response.headers = parseHeaders(headerLines)
            
            # Content-Length の取得
            let contentLengthOpt = getHeader(response.headers, "Content-Length")
            if contentLengthOpt.isSome:
              try:
                response.contentLength = some(parseInt(contentLengthOpt.get()))
              except:
                response.contentLength = none(int)
            
            # Transfer-Encoding の確認
            let transferEncodingOpt = getHeader(response.headers, "Transfer-Encoding")
            response.chunked = transferEncodingOpt.isSome and "chunked" in transferEncodingOpt.get().toLowerAscii()
            
            # Connection ヘッダーの確認
            let connectionOpt = getHeader(response.headers, "Connection")
            if connectionOpt.isSome:
              response.keepAlive = "close" notin connectionOpt.get().toLowerAscii()
            else:
              response.keepAlive = true  # HTTP/1.1 のデフォルトは keep-alive
          else:
            headerLines.add(currentLine)
        else:
          break
      
      of Body:
        # ボディの処理
        if response.chunked:
          # チャンク転送エンコーディング
          let (body, trailers) = await decodeChunkedBody(socket)
          response.body.data = body
          
          # トレーラーヘッダーの追加
          for trailer in trailers:
            response.headers.add(trailer)
          
          state = Done
        elif response.contentLength.isSome:
          # Content-Length指定
          response.body.data = await decodeContentLengthBody(socket, response.contentLength.get(), timeout)
          state = Done
        else:
          # ボディなしか、接続が閉じるまで読み取り
          response.body.data = buffer & await socket.recvAll()
          buffer = ""
          state = Done
      
      of Done, Error:
        break
  
  response.requestTime = epochTime() - startTime
  
  return response

# リクエスト送信の簡易バージョン
proc get*(socket: AsyncSocket, url: string, headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  return await sendRequest(socket, parseUri(url), GET, headers, HttpBody(isStream: false, data: ""))

proc post*(socket: AsyncSocket, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
          headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  var requestHeaders = headers
  addHeader(requestHeaders, "Content-Type", contentType)
  
  return await sendRequest(socket, parseUri(url), POST, requestHeaders, HttpBody(isStream: false, data: body))

proc put*(socket: AsyncSocket, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
         headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  var requestHeaders = headers
  addHeader(requestHeaders, "Content-Type", contentType)
  
  return await sendRequest(socket, parseUri(url), PUT, requestHeaders, HttpBody(isStream: false, data: body))

proc delete*(socket: AsyncSocket, url: string, headers: seq[HttpHeader] = @[]): Future[HttpResponse] {.async.} =
  return await sendRequest(socket, parseUri(url), DELETE, headers, HttpBody(isStream: false, data: ""))

# HTTP/1.1 サーバーからの応答を非同期で待機
proc recvResponse*(socket: AsyncSocket, timeout: int = 30000): Future[HttpResponse] {.async.} =
  let timeoutFuture = sleepAsync(timeout)
  let startTime = epochTime()
  
  var response = HttpResponse(
    headers: @[],
    body: HttpBody(isStream: false, data: ""),
    keepAlive: true
  )
  
  var state = StatusLine
  var buffer = ""
  var headerLines: seq[string] = @[]
  var currentLine = ""
  
  while state != Done and state != Error:
    let readFuture = socket.recv(4096)
    let firstFuture = await firstCompletedFuture(readFuture, timeoutFuture)
    
    if firstFuture == timeoutFuture:
      raise newException(TimeoutError, "Timeout while waiting for response")
    
    let data = readFuture.read()
    if data.len == 0:
      if state != Body:
        state = Error
        raise newException(IOError, "Connection closed unexpectedly")
      break
    
    buffer.add(data)
    
    # バッファを処理
    while buffer.len > 0:
      case state
      of StatusLine:
        let nlPos = buffer.find("\r\n")
        if nlPos >= 0:
          currentLine = buffer[0 ..< nlPos]
          buffer = buffer[nlPos + 2 .. ^1]
          
          try:
            let status = parseStatusLine(currentLine)
            response.version = status.version
            response.statusCode = status.statusCode
            response.reasonPhrase = status.reasonPhrase
            state = Headers
          except:
            state = Error
            raise getCurrentException()
        else:
          break
      
      of Headers:
        let nlPos = buffer.find("\r\n")
        if nlPos >= 0:
          currentLine = buffer[0 ..< nlPos]
          buffer = buffer[nlPos + 2 .. ^1]
          
          if currentLine == "":
            # ヘッダー終了、本文開始
            state = Body
            
            # ヘッダーの解析
            response.headers = parseHeaders(headerLines)
            
            # Content-Length の取得
            let contentLengthOpt = getHeader(response.headers, "Content-Length")
            if contentLengthOpt.isSome:
              try:
                response.contentLength = some(parseInt(contentLengthOpt.get()))
              except:
                response.contentLength = none(int)
            
            # Transfer-Encoding の確認
            let transferEncodingOpt = getHeader(response.headers, "Transfer-Encoding")
            response.chunked = transferEncodingOpt.isSome and "chunked" in transferEncodingOpt.get().toLowerAscii()
            
            # Connection ヘッダーの確認
            let connectionOpt = getHeader(response.headers, "Connection")
            if connectionOpt.isSome:
              response.keepAlive = "close" notin connectionOpt.get().toLowerAscii()
            else:
              response.keepAlive = true  # HTTP/1.1 のデフォルトは keep-alive
          else:
            headerLines.add(currentLine)
        else:
          break
      
      of Body:
        # ボディの処理
        if response.chunked:
          # チャンク転送エンコーディング
          let (body, trailers) = await decodeChunkedBody(socket, timeout)
          response.body.data = body
          
          # トレーラーヘッダーの追加
          for trailer in trailers:
            response.headers.add(trailer)
          
          state = Done
        elif response.contentLength.isSome:
          # Content-Length指定
          response.body.data = await decodeContentLengthBody(socket, response.contentLength.get(), timeout)
          state = Done
        else:
          # ボディなしか、接続が閉じるまで読み取り
          response.body.data = buffer & await socket.recvAll()
          buffer = ""
          state = Done
      
      of Done, Error:
        break
  
  response.requestTime = epochTime() - startTime
  
  return response

# HTTP/1.1 パイプラインリクエスト (複数リクエストの一括送信)
proc sendPipelinedRequests*(socket: AsyncSocket, requests: seq[tuple[url: Uri, method: HttpMethod, headers: seq[HttpHeader], body: HttpBody]]): 
                           Future[seq[HttpResponse]] {.async.} =
  var responses: seq[HttpResponse] = @[]
  
  # すべてのリクエストを一度に送信
  for (url, method, headers, body) in requests:
    let path = if url.path == "": "/" else: url.path
    let queryStr = if url.query == "": "" else: "?" & url.query
    let requestLine = $method & " " & path & queryStr & " HTTP/1.1\r\n"
    
    var requestHeaders = headers
    
    # 必須ヘッダーの追加
    if not hasHeader(requestHeaders, "Host"):
      addHeader(requestHeaders, "Host", url.hostname & (if url.port == "": "" else: ":" & url.port))
    
    # Content-Lengthヘッダーの設定
    if not body.isStream and body.data.len > 0:
      replaceHeader(requestHeaders, "Content-Length", $body.data.len)
    
    # Connectionヘッダーの設定（最後のリクエスト以外はKeep-Alive必須）
    replaceHeader(requestHeaders, "Connection", "keep-alive")
    
    # ヘッダー文字列の構築
    var headerStr = ""
    for (name, value) in requestHeaders:
      headerStr.add(name & ": " & value & "\r\n")
    
    # リクエスト本文の終端
    headerStr.add("\r\n")
    
    # リクエスト送信
    socket.send(requestLine & headerStr)
    
    # ボディの送信
    if not body.isStream and body.data.len > 0:
      socket.send(body.data)
  
  # レスポンスを順番に受信
  for i in 0 ..< requests.len:
    let response = await recvResponse(socket)
    responses.add(response)
    
    # 接続が閉じられた場合、残りのレスポンスは取得できない
    if not response.keepAlive and i < requests.len - 1:
      raise newException(IOError, "Connection closed before all responses were received")
  
  return responses

# WebSocket アップグレード (HTTP/1.1からWebSocketへの切り替え)
proc upgradeToWebSocket*(socket: AsyncSocket, url: Uri, headers: seq[HttpHeader] = @[]): Future[tuple[success: bool, response: HttpResponse]] {.async.} =
  var upgradeHeaders = headers
  
  # WebSocketアップグレードに必要なヘッダー
  let key = base64.encode(rand(1_000_000).toHex())
  
  addHeader(upgradeHeaders, "Upgrade", "websocket")
  addHeader(upgradeHeaders, "Connection", "Upgrade")
  addHeader(upgradeHeaders, "Sec-WebSocket-Key", key)
  addHeader(upgradeHeaders, "Sec-WebSocket-Version", "13")
  
  # リクエスト送信
  let response = await sendRequest(socket, url, GET, upgradeHeaders, HttpBody(isStream: false, data: ""))
  
  # レスポンスの確認
  let success = response.statusCode == 101 and
                getHeader(response.headers, "Upgrade").isSome and
                getHeader(response.headers, "Upgrade").get().toLowerAscii() == "websocket" and
                getHeader(response.headers, "Connection").isSome and
                "upgrade" in getHeader(response.headers, "Connection").get().toLowerAscii()
  
  return (success, response) 