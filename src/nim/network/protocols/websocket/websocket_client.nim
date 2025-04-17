## WebSocketクライアント実装
## 
## WebSocketプロトコル（RFC 6455）に準拠したクライアント実装を提供します。
## HTTPからWebSocketへのアップグレード、メッセージの送受信、各種制御フレームの処理を行います。

import std/[asyncdispatch, asyncnet, base64, httpclient, net, options, random, 
           strformat, strutils, tables, times, uri]
import ../../../core/logging/logger
import ../../security/tls/tls_client
import ../../http/headers/http_headers
import ./websocket_types
import ./websocket_frame

type
  WebSocketState* = enum
    wsConnecting,   # 接続中
    wsOpen,         # 接続済み
    wsClosing,      # クローズ中
    wsClosed        # 接続終了

  WebSocketCloseReason* = enum
    wscrNormal,              # 正常終了
    wscrGoingAway,           # クライアントがページを離れた
    wscrProtocolError,       # プロトコルエラー
    wscrUnsupportedData,     # サポートされていないデータが受信された
    wscrNoStatusReceived,    # ステータスコードが受信されなかった
    wscrAbnormalClosure,     # 異常終了
    wscrInvalidFrameData,    # 不正なフレームデータ
    wscrPolicyViolation,     # ポリシー違反
    wscrMessageTooBig,       # メッセージが大きすぎる
    wscrMissingExtension,    # 必要な拡張機能がない
    wscrInternalError,       # 内部エラー
    wscrServiceRestart,      # サービス再起動
    wscrTryAgainLater,       # 一時的な障害、後で再接続
    wscrTlsHandshake         # TLSハンドシェイク失敗

  WebSocketClient* = ref object
    ## WebSocketクライアント
    url*: string                           # WebSocketのURL
    socket: AsyncSocket                    # 基本ソケット
    tlsSocket: Option[AsyncTlsSocket]      # TLS使用時のソケット
    secure: bool                           # TLS使用フラグ
    state*: WebSocketState                 # 現在の状態
    headers: HttpHeaders                   # 接続時のHTTPヘッダー
    subprotocol*: string                   # 選択されたサブプロトコル
    extensions*: seq[string]               # 使用する拡張機能
    closeCode*: uint16                     # 接続終了コード
    closeReason*: string                   # 接続終了理由
    lastReceived*: Time                    # 最後にメッセージを受信した時間
    lastSent*: Time                        # 最後にメッセージを送信した時間
    pingInterval*: int                     # Pingの送信間隔（ミリ秒）
    pongTimeout*: int                      # Pongの待機タイムアウト（ミリ秒）
    maxMessageSize*: int                   # 最大メッセージサイズ（バイト）
    buffer: string                         # 受信バッファ
    fragmentedOpCode: Option[WebSocketOpCode]  # 分割メッセージのOpCode
    fragmentBuffer: string                 # 分割メッセージバッファ
    logger: Logger                         # ロガー
    isAutoReconnect*: bool                 # 自動再接続フラグ
    reconnectAttempts*: int                # 再接続試行回数
    maxReconnectAttempts*: int             # 最大再接続試行回数
    reconnectDelay*: int                   # 再接続遅延（ミリ秒）
    onOpen*: proc(client: WebSocketClient) {.closure, gcsafe.}
    onMessage*: proc(client: WebSocketClient, opCode: WebSocketOpCode, data: string) {.closure, gcsafe.}
    onClose*: proc(client: WebSocketClient, code: uint16, reason: string) {.closure, gcsafe.}
    onError*: proc(client: WebSocketClient, error: string) {.closure, gcsafe.}

const
  WebSocketCloseCodes = {
    wscrNormal: 1000,
    wscrGoingAway: 1001,
    wscrProtocolError: 1002,
    wscrUnsupportedData: 1003,
    wscrNoStatusReceived: 1005,
    wscrAbnormalClosure: 1006,
    wscrInvalidFrameData: 1007,
    wscrPolicyViolation: 1008,
    wscrMessageTooBig: 1009,
    wscrMissingExtension: 1010,
    wscrInternalError: 1011,
    wscrServiceRestart: 1012,
    wscrTryAgainLater: 1013,
    wscrTlsHandshake: 1015
  }.toTable

# ガイド値：最小値は4096バイト（4KB）、一般的には128KB程度
const DefaultMaxMessageSize = 128 * 1024  # 128KB

proc generateWebSocketKey(): string =
  ## ランダムなWebSocket接続キーを生成する
  var key = ""
  for i in 0..<16:
    key.add(chr(rand(255)))
  return encode(key)

proc newWebSocketClient*(url: string, 
                       subprotocols: seq[string] = @[], 
                       headers: HttpHeaders = nil,
                       pingInterval: int = 30000,  # 30秒
                       pongTimeout: int = 10000,   # 10秒
                       maxMessageSize: int = DefaultMaxMessageSize,
                       logger: Logger = nil): WebSocketClient =
  ## 新しいWebSocketクライアントを作成する
  randomize()  # 乱数ジェネレータを初期化
  
  # URLをパース
  let parsedUrl = parseUri(url)
  let secure = parsedUrl.scheme == "wss"
  
  # ヘッダーを準備
  var clientHeaders = if headers.isNil: newHttpHeaders() else: headers
  
  # サブプロトコルを設定
  if subprotocols.len > 0:
    clientHeaders["Sec-WebSocket-Protocol"] = subprotocols.join(", ")
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("WebSocketClient") else: logger
  
  result = WebSocketClient(
    url: url,
    socket: nil,
    tlsSocket: none(AsyncTlsSocket),
    secure: secure,
    state: wsConnecting,
    headers: clientHeaders,
    subprotocol: "",
    extensions: @[],
    closeCode: 0,
    closeReason: "",
    lastReceived: Time(),
    lastSent: Time(),
    pingInterval: pingInterval,
    pongTimeout: pongTimeout,
    maxMessageSize: maxMessageSize,
    buffer: "",
    fragmentedOpCode: none(WebSocketOpCode),
    fragmentBuffer: "",
    logger: clientLogger,
    isAutoReconnect: false,
    reconnectAttempts: 0,
    maxReconnectAttempts: 3,
    reconnectDelay: 1000  # 1秒
  )

proc handleError(client: WebSocketClient, error: string) =
  ## エラー処理
  client.logger.error(fmt"WebSocket error: {error}")
  if not client.onError.isNil:
    try:
      client.onError(client, error)
    except:
      client.logger.error(fmt"Error in onError callback: {getCurrentExceptionMsg()}")

proc close*(client: WebSocketClient, code: uint16 = 1000, reason: string = "") {.async.} =
  ## WebSocket接続を閉じる
  if client.state == wsOpen or client.state == wsClosing:
    client.state = wsClosing
    client.closeCode = code
    client.closeReason = reason
    
    # クローズフレームを送信
    try:
      let closeFrame = encodeCloseFrame(code, reason)
      if client.secure and client.tlsSocket.isSome:
        await client.tlsSocket.get().send(closeFrame)
      else:
        await client.socket.send(closeFrame)
      
      client.lastSent = getTime()
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.error(fmt"Error sending close frame: {errMsg}")
    
    # ソケットを閉じる
    try:
      if client.secure and client.tlsSocket.isSome:
        client.tlsSocket.get().close()
      else:
        client.socket.close()
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.error(fmt"Error closing socket: {errMsg}")
    
    client.state = wsClosed
    
    # クローズコールバックを呼び出す
    if not client.onClose.isNil:
      try:
        client.onClose(client, code, reason)
      except:
        client.logger.error(fmt"Error in onClose callback: {getCurrentExceptionMsg()}")

proc connect*(client: WebSocketClient): Future[bool] {.async.} =
  ## WebSocket接続を確立する
  if client.state != wsConnecting:
    client.state = wsConnecting
  
  client.logger.info(fmt"Connecting to {client.url}")
  
  let parsedUrl = parseUri(client.url)
  let hostname = parsedUrl.hostname
  
  # ポート番号を決定
  var port = 0
  if parsedUrl.port == "":
    port = if client.secure: 443 else: 80
  else:
    port = parseInt(parsedUrl.port)
  
  # パスとクエリを取得
  var path = parsedUrl.path
  if path == "":
    path = "/"
  if parsedUrl.query != "":
    path = path & "?" & parsedUrl.query
  
  # ソケット接続を確立
  try:
    client.socket = newAsyncSocket()
    await client.socket.connect(hostname, Port(port))
    
    # TLS接続の場合
    if client.secure:
      let tlsConfig = newTlsConfig()
      let tlsSocket = newAsyncTlsSocket(client.socket, tlsConfig, hostname)
      await tlsSocket.handshake()
      client.tlsSocket = some(tlsSocket)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Connection failed: {errMsg}")
    client.state = wsClosed
    return false
  
  # WebSocketハンドシェイクのキーを生成
  let wsKey = generateWebSocketKey()
  
  # HTTP接続アップグレードリクエストを送信
  try:
    var requestHeaders = "GET " & path & " HTTP/1.1\r\n"
    requestHeaders &= "Host: " & hostname & "\r\n"
    requestHeaders &= "Upgrade: websocket\r\n"
    requestHeaders &= "Connection: Upgrade\r\n"
    requestHeaders &= "Sec-WebSocket-Key: " & wsKey & "\r\n"
    requestHeaders &= "Sec-WebSocket-Version: 13\r\n"
    
    # カスタムヘッダーを追加
    for key, value in client.headers.pairs:
      if key.toLowerAscii notin ["host", "upgrade", "connection", 
                                "sec-websocket-key", "sec-websocket-version"]:
        requestHeaders &= key & ": " & value & "\r\n"
    
    # リクエスト終了
    requestHeaders &= "\r\n"
    
    # リクエスト送信
    if client.secure and client.tlsSocket.isSome:
      await client.tlsSocket.get().send(requestHeaders)
    else:
      await client.socket.send(requestHeaders)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Handshake request failed: {errMsg}")
    client.state = wsClosed
    return false
  
  # レスポンスの読み取り
  try:
    var response = ""
    var headerCompleted = false
    var buffer = newString(4096)
    
    while not headerCompleted:
      var bytesRead = 0
      if client.secure and client.tlsSocket.isSome:
        bytesRead = await client.tlsSocket.get().recv(buffer, 0, 4096)
      else:
        bytesRead = await client.socket.recv(buffer, 0, 4096)
      
      if bytesRead <= 0:
        raise newException(IOError, "Connection closed during handshake")
      
      response &= buffer[0..<bytesRead]
      
      # ヘッダー部分が完了したかチェック
      if response.contains("\r\n\r\n"):
        headerCompleted = true
    
    # レスポンスの解析
    let headerEnd = response.find("\r\n\r\n")
    let headerPart = response[0..<headerEnd]
    client.buffer = response[headerEnd + 4..^1]  # 残りのデータをバッファに保存
    
    let headerLines = headerPart.split("\r\n")
    let statusLine = headerLines[0]
    
    # ステータスラインをチェック
    if not statusLine.contains("101"):
      let errMsg = fmt"Unexpected status line: {statusLine}"
      client.handleError(errMsg)
      client.state = wsClosed
      return false
    
    # レスポンスヘッダーを解析
    var upgradeFound = false
    var connectionUpgrade = false
    var validKey = false
    
    for i in 1..<headerLines.len:
      let line = headerLines[i]
      if line.len == 0:
        break
      
      let colonPos = line.find(":")
      if colonPos < 0:
        continue
      
      let name = line[0..<colonPos].strip().toLowerAscii()
      let value = line[colonPos + 1..^1].strip()
      
      case name
      of "upgrade":
        if value.toLowerAscii() == "websocket":
          upgradeFound = true
      of "connection":
        if value.toLowerAscii().contains("upgrade"):
          connectionUpgrade = true
      of "sec-websocket-accept":
        # WebSocketキーの検証
        let expectedKey = encode(secureHash(wsKey & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        if value == expectedKey:
          validKey = true
      of "sec-websocket-protocol":
        client.subprotocol = value
      of "sec-websocket-extensions":
        for ext in value.split(","):
          client.extensions.add(ext.strip())
    
    # すべての条件が満たされているか確認
    if not (upgradeFound and connectionUpgrade and validKey):
      let errMsg = "Invalid WebSocket handshake response"
      client.handleError(errMsg)
      client.state = wsClosed
      return false
    
    # 接続確立
    client.state = wsOpen
    client.lastReceived = getTime()
    client.lastSent = getTime()
    
    # 接続オープンコールバックを呼び出す
    if not client.onOpen.isNil:
      try:
        client.onOpen(client)
      except:
        client.logger.error(fmt"Error in onOpen callback: {getCurrentExceptionMsg()}")
    
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Handshake response processing failed: {errMsg}")
    client.state = wsClosed
    return false

proc send*(client: WebSocketClient, data: string, opCode: WebSocketOpCode = Binary): Future[bool] {.async.} =
  ## データを送信する
  if client.state != wsOpen:
    client.handleError("Cannot send message: connection not open")
    return false
  
  try:
    # データをフレームに変換
    let frameData = encodeFrame(data, opCode, true, false)
    
    # フレームを送信
    if client.secure and client.tlsSocket.isSome:
      await client.tlsSocket.get().send(frameData)
    else:
      await client.socket.send(frameData)
    
    client.lastSent = getTime()
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Send failed: {errMsg}")
    return false

proc sendText*(client: WebSocketClient, text: string): Future[bool] {.async.} =
  ## テキストメッセージを送信する
  return await client.send(text, Text)

proc sendBinary*(client: WebSocketClient, data: string): Future[bool] {.async.} =
  ## バイナリメッセージを送信する
  return await client.send(data, Binary)

proc sendPing*(client: WebSocketClient, data: string = ""): Future[bool] {.async.} =
  ## Pingフレームを送信する
  return await client.send(data, Ping)

proc sendPong*(client: WebSocketClient, data: string = ""): Future[bool] {.async.} =
  ## Pongフレームを送信する
  return await client.send(data, Pong)

proc processFrame(client: WebSocketClient, frame: WebSocketFrame) {.async.} =
  ## 受信したフレームを処理する
  
  case frame.opCode
  of Continuation:
    # 継続フレーム
    if client.fragmentedOpCode.isNone:
      client.handleError("Received continuation frame but no fragmented message is in progress")
      await client.close(uint16(WebSocketCloseCodes[wscrProtocolError]), "Protocol error")
      return
    
    client.fragmentBuffer &= frame.payload
    
    # 最終フレームの場合、完全なメッセージを処理
    if frame.fin:
      let completeMessage = client.fragmentBuffer
      let messageOpCode = client.fragmentedOpCode.get()
      
      # フラグメンテーション状態をリセット
      client.fragmentedOpCode = none(WebSocketOpCode)
      client.fragmentBuffer = ""
      
      # メッセージコールバックを呼び出す
      if not client.onMessage.isNil:
        try:
          client.onMessage(client, messageOpCode, completeMessage)
        except:
          client.logger.error(fmt"Error in onMessage callback: {getCurrentExceptionMsg()}")
  
  of Text, Binary:
    # テキストまたはバイナリフレーム
    if client.fragmentedOpCode.isSome:
      client.handleError("Received new message frame while fragmented message is still in progress")
      await client.close(uint16(WebSocketCloseCodes[wscrProtocolError]), "Protocol error")
      return
    
    if frame.fin:
      # 単一フレームのメッセージ
      if not client.onMessage.isNil:
        try:
          client.onMessage(client, frame.opCode, frame.payload)
        except:
          client.logger.error(fmt"Error in onMessage callback: {getCurrentExceptionMsg()}")
    else:
      # フラグメント化されたメッセージの開始
      client.fragmentedOpCode = some(frame.opCode)
      client.fragmentBuffer = frame.payload
  
  of Close:
    # クローズフレーム
    var code: uint16 = 1000
    var reason = ""
    
    if frame.payload.len >= 2:
      code = (uint16(frame.payload[0]) shl 8) or uint16(frame.payload[1])
      if frame.payload.len > 2:
        reason = frame.payload[2..^1]
    
    client.logger.info(fmt"Received close frame: code={code}, reason={reason}")
    
    if client.state == wsOpen:
      # クローズフレームを返信して接続を閉じる
      await client.close(code, reason)
    elif client.state == wsClosing:
      # 既にクローズプロセス中なのでソケットを閉じる
      if client.secure and client.tlsSocket.isSome:
        client.tlsSocket.get().close()
      else:
        client.socket.close()
      
      client.state = wsClosed
      
      # クローズコールバックを呼び出す
      if not client.onClose.isNil:
        try:
          client.onClose(client, code, reason)
        except:
          client.logger.error(fmt"Error in onClose callback: {getCurrentExceptionMsg()}")
  
  of Ping:
    # Pingフレーム - 自動的にPongで応答
    client.logger.debug("Received ping frame")
    discard await client.sendPong(frame.payload)
  
  of Pong:
    # Pongフレーム
    client.logger.debug("Received pong frame")
    client.lastReceived = getTime()
  
  else:
    # 未知のOpCode
    client.handleError(fmt"Received frame with unknown opcode: {frame.opCode}")
    await client.close(uint16(WebSocketCloseCodes[wscrProtocolError]), "Protocol error")

proc receiveFrame(client: WebSocketClient): Future[Option[WebSocketFrame]] {.async.} =
  ## フレームを受信して解析する
  
  # バッファがまだ空の場合、データを読み込む
  if client.buffer.len == 0:
    var tempBuffer = newString(4096)
    var bytesRead = 0
    
    try:
      if client.secure and client.tlsSocket.isSome:
        bytesRead = await client.tlsSocket.get().recv(tempBuffer, 0, 4096)
      else:
        bytesRead = await client.socket.recv(tempBuffer, 0, 4096)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Error receiving data: {errMsg}")
      return none(WebSocketFrame)
    
    if bytesRead <= 0:
      client.handleError("Connection closed by peer")
      client.state = wsClosed
      
      # 異常なクローズに対するコールバックを呼び出す
      if not client.onClose.isNil:
        try:
          client.onClose(client, uint16(WebSocketCloseCodes[wscrAbnormalClosure]), "Connection closed unexpectedly")
        except:
          client.logger.error(fmt"Error in onClose callback: {getCurrentExceptionMsg()}")
      
      return none(WebSocketFrame)
    
    client.buffer &= tempBuffer[0..<bytesRead]
    client.lastReceived = getTime()
  
  # フレームの解析を試みる
  try:
    let (frame, bytesConsumed) = decodeFrame(client.buffer)
    
    if bytesConsumed > 0:
      client.buffer = client.buffer[bytesConsumed..^1]
      return some(frame)
    else:
      # フレーム解析に十分なデータがまだない
      return none(WebSocketFrame)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Error decoding frame: {errMsg}")
    await client.close(uint16(WebSocketCloseCodes[wscrProtocolError]), "Invalid frame format")
    return none(WebSocketFrame)

proc receiveMessage*(client: WebSocketClient): Future[tuple[opCode: WebSocketOpCode, data: string]] {.async.} =
  ## 完全なメッセージを受信する
  if client.state != wsOpen:
    raise newException(IOError, "WebSocket connection is not open")
  
  var messageData = ""
  var messageOpCode: WebSocketOpCode
  var isFirstFragment = true
  
  while true:
    let frameOpt = await client.receiveFrame()
    if frameOpt.isNone:
      raise newException(IOError, "Failed to receive frame")
    
    let frame = frameOpt.get()
    
    case frame.opCode
    of Continuation:
      if isFirstFragment:
        raise newException(ProtocolError, "Received continuation frame but no fragmented message is in progress")
      
      messageData &= frame.payload
      
      if frame.fin:
        return (messageOpCode, messageData)
    
    of Text, Binary:
      if not isFirstFragment:
        raise newException(ProtocolError, "Received new message frame while fragmented message is still in progress")
      
      if frame.fin:
        # 単一フレームのメッセージ
        return (frame.opCode, frame.payload)
      else:
        # フラグメント化されたメッセージの開始
        isFirstFragment = false
        messageOpCode = frame.opCode
        messageData = frame.payload
    
    of Close:
      var code: uint16 = 1000
      var reason = ""
      
      if frame.payload.len >= 2:
        code = (uint16(frame.payload[0]) shl 8) or uint16(frame.payload[1])
        if frame.payload.len > 2:
          reason = frame.payload[2..^1]
      
      # クローズフレームを送信して接続を閉じる
      if client.state == wsOpen:
        await client.close(code, reason)
      
      raise newException(WebSocketClosedError, fmt"WebSocket closed with code {code}: {reason}")
    
    of Ping:
      # Pingフレームは自動処理されるのでスキップ
      discard await client.sendPong(frame.payload)
    
    of Pong:
      # Pongフレームもスキップ
      discard
    
    else:
      raise newException(ProtocolError, fmt"Received frame with unknown opcode: {frame.opCode}")

proc listen*(client: WebSocketClient) {.async.} =
  ## WebSocketの受信ループを開始する
  
  while client.state == wsOpen:
    try:
      let frameOpt = await client.receiveFrame()
      if frameOpt.isNone:
        # 接続が閉じられたか、エラーが発生した場合
        if client.state == wsOpen:
          # まだOpenなら異常終了を処理
          await client.close(uint16(WebSocketCloseCodes[wscrAbnormalClosure]), "Connection closed abnormally")
        break
      
      # 受信したフレームを処理
      await client.processFrame(frameOpt.get())
      
      # Ping送信判定（最後のメッセージから一定時間経過した場合）
      let currentTime = getTime()
      if (currentTime - client.lastSent).inMilliseconds >= client.pingInterval:
        discard await client.sendPing()
      
      # 待機なしで次のフレームを処理
      await sleepAsync(0)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Error in receive loop: {errMsg}")
      
      if client.state == wsOpen:
        await client.close(uint16(WebSocketCloseCodes[wscrInternalError]), "Internal error")
      break
  
  # 自動再接続ロジック
  if client.isAutoReconnect and client.reconnectAttempts < client.maxReconnectAttempts:
    client.reconnectAttempts += 1
    client.logger.info(fmt"Attempting to reconnect... (attempt {client.reconnectAttempts}/{client.maxReconnectAttempts})")
    
    # 再接続前の遅延
    await sleepAsync(client.reconnectDelay)
    
    let success = await client.connect()
    if success:
      client.reconnectAttempts = 0
      await client.listen()

proc startHeartbeat*(client: WebSocketClient) {.async.} =
  ## 定期的なPingを送信するハートビートを開始する
  
  while client.state == wsOpen:
    # 一定間隔でPingを送信
    await sleepAsync(client.pingInterval)
    
    if client.state != wsOpen:
      break
    
    # 最後のメッセージ送信からpingInterval以上経過していればPingを送信
    let currentTime = getTime()
    if (currentTime - client.lastSent).inMilliseconds >= client.pingInterval:
      discard await client.sendPing()
    
    # 最後のメッセージ受信からpongTimeout以上経過していれば接続終了とみなす
    if (currentTime - client.lastReceived).inMilliseconds > client.pongTimeout:
      client.logger.warn("Pong timeout detected, closing connection")
      await client.close(uint16(WebSocketCloseCodes[wscrAbnormalClosure]), "Pong timeout")
      break 