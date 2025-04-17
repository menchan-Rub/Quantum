##
## WebSocketプロトコル実装
## RFC 6455に準拠したWebSocketプロトコルの実装
##

import std/[asyncdispatch, asyncnet, base64, strutils, random, sha1, nativesockets, uri, tables, options, times, deques]
import std/strformat except `&`

type
  WebSocketOpCode* = enum
    ## WebSocketフレームの操作コード
    wsOpContinuation = 0x0 ## 継続フレーム
    wsOpText = 0x1         ## テキストフレーム
    wsOpBinary = 0x2       ## バイナリフレーム
    wsOpClose = 0x8        ## 接続終了フレーム
    wsOpPing = 0x9         ## Pingフレーム
    wsOpPong = 0xA         ## Pongフレーム

  WebSocketCloseCode* = enum
    ## WebSocketの終了コード
    wsCloseNormal = 1000           ## 正常終了
    wsCloseGoingAway = 1001        ## 接続を閉じる（ページ遷移など）
    wsCloseProtocolError = 1002    ## プロトコルエラー
    wsCloseUnsupportedData = 1003  ## サポートされていないデータ
    wsCloseNoStatus = 1005         ## ステータスなし（内部使用）
    wsCloseAbnormal = 1006         ## 異常終了（内部使用）
    wsCloseInvalidData = 1007      ## 不正なデータ（テキストフレームがUTF-8でないなど）
    wsClosePolicyViolation = 1008  ## ポリシー違反
    wsCloseMessageTooBig = 1009    ## メッセージが大きすぎる
    wsCloseExtensionRequired = 1010 ## 拡張機能が必要
    wsCloseInternalError = 1011     ## サーバー内部エラー
    wsCloseTLSHandshake = 1015      ## TLSハンドシェイク失敗（内部使用）

  WebSocketState* = enum
    ## WebSocket接続の状態
    wsStateConnecting, ## 接続中
    wsStateOpen,       ## 接続済み
    wsStateClosing,    ## 終了中
    wsStateClosed      ## 終了済み

  WebSocketMessage* = object
    ## WebSocketメッセージ
    case opcode*: WebSocketOpCode
    of wsOpText:
      textData*: string
    of wsOpBinary:
      binaryData*: seq[byte]
    of wsOpClose:
      closeCode*: uint16
      closeReason*: string
    of wsOpPing, wsOpPong:
      pingData*: seq[byte]
    of wsOpContinuation:
      continuationData*: seq[byte]

  WebSocketFrameHeader = object
    ## WebSocketフレームヘッダ（内部使用）
    fin: bool           # 最終フレームフラグ
    rsv1, rsv2, rsv3: bool # 予約ビット
    opcode: WebSocketOpCode # 操作コード
    masked: bool        # マスクフラグ
    payloadLen: uint64  # ペイロード長
    maskingKey: array[4, byte] # マスキングキー

  WebSocketError* = object of CatchableError
    ## WebSocketエラー

  WebSocketProtocolError* = object of WebSocketError
    ## WebSocketプロトコルエラー

  FrameParseError* = object of WebSocketProtocolError
    ## フレーム解析エラー

  WebSocketBufferPool* = ref object
    ## バッファプール（メモリ効率のため）
    buffers: seq[seq[byte]]
    maxPoolSize: int

  WebSocketConfig* = object
    ## WebSocket設定
    maxFrameSize*: int      ## 最大フレームサイズ（デフォルト: 16MB）
    maxMessageSize*: int    ## 最大メッセージサイズ（デフォルト: 64MB）
    pingInterval*: int      ## Ping送信間隔（ミリ秒、0で無効）
    pingTimeout*: int       ## Pingタイムアウト（ミリ秒）
    closeTimeout*: int      ## 終了処理タイムアウト（ミリ秒）
    maskFrames*: bool       ## フレームをマスクするか（クライアント側ではtrue必須）
    autoPong*: bool         ## Pingに自動応答するか
    bufferPoolSize*: int    ## バッファプールサイズ

  WebSocketConnection* = ref object
    ## WebSocket接続
    socket*: AsyncSocket    ## 基底ソケット
    isServer*: bool         ## サーバー側か
    state*: WebSocketState  ## 接続状態
    config*: WebSocketConfig ## WebSocket設定
    url*: Uri               ## 接続URL（クライアント）
    buffer: seq[byte]       ## 読み込みバッファ
    bufferPool: WebSocketBufferPool ## バッファプール
    fragmentedOpcode: WebSocketOpCode ## 分割フレームの操作コード
    fragmentedData: seq[byte]  ## 分割フレームデータ
    lastPingTime: float      ## 最後にPingを送信した時間
    lastPongTime: float      ## 最後にPongを受信した時間
    extensions: Table[string, string] ## 拡張機能
    closeCode: uint16        ## 終了コード
    closeReason: string      ## 終了理由
    messageQueue: Deque[Future[WebSocketMessage]] ## メッセージキュー
    rng: Random              ## 乱数生成器

const
  DEFAULT_BUFFER_SIZE = 4096
  DEFAULT_MAX_FRAME_SIZE = 16 * 1024 * 1024  # 16MB
  DEFAULT_MAX_MESSAGE_SIZE = 64 * 1024 * 1024  # 64MB
  DEFAULT_PING_INTERVAL = 30000  # 30秒
  DEFAULT_PING_TIMEOUT = 10000   # 10秒
  DEFAULT_CLOSE_TIMEOUT = 5000   # 5秒
  DEFAULT_BUFFER_POOL_SIZE = 10

  WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

proc newWebSocketConfig*(): WebSocketConfig =
  ## デフォルトのWebSocket設定を作成
  result = WebSocketConfig(
    maxFrameSize: DEFAULT_MAX_FRAME_SIZE,
    maxMessageSize: DEFAULT_MAX_MESSAGE_SIZE,
    pingInterval: DEFAULT_PING_INTERVAL,
    pingTimeout: DEFAULT_PING_TIMEOUT,
    closeTimeout: DEFAULT_CLOSE_TIMEOUT,
    maskFrames: true,  # クライアント側ではマスク必須
    autoPong: true,
    bufferPoolSize: DEFAULT_BUFFER_POOL_SIZE
  )

proc newBufferPool(maxPoolSize: int): WebSocketBufferPool =
  ## バッファプールを作成
  new(result)
  result.buffers = @[]
  result.maxPoolSize = maxPoolSize

proc getBuffer(pool: WebSocketBufferPool, size: int): seq[byte] =
  ## プールからバッファを取得
  if pool.buffers.len > 0:
    result = pool.buffers.pop()
    if result.len < size:
      result.setLen(size)
  else:
    result = newSeq[byte](size)

proc recycleBuffer(pool: WebSocketBufferPool, buffer: var seq[byte]) =
  ## バッファをプールに戻す
  if pool.buffers.len < pool.maxPoolSize:
    pool.buffers.add(buffer)
  buffer = @[]  # 元の変数を空にする

proc encodeFrameHeader(header: WebSocketFrameHeader): seq[byte] =
  ## WebSocketフレームヘッダをエンコード
  var headerSize = 2
  if header.payloadLen >= 126:
    if header.payloadLen <= uint64(uint16.high):
      headerSize += 2
    else:
      headerSize += 8
  
  if header.masked:
    headerSize += 4
  
  result = newSeq[byte](headerSize)
  var pos = 0
  
  # 1バイト目: FIN, RSV1-3, OpCode
  result[pos] = byte(
    (if header.fin: 0x80 else: 0x00) or 
    (if header.rsv1: 0x40 else: 0x00) or 
    (if header.rsv2: 0x20 else: 0x00) or 
    (if header.rsv3: 0x10 else: 0x00) or 
    byte(header.opcode)
  )
  pos.inc
  
  # 2バイト目: MASK, PayloadLen
  if header.payloadLen < 126:
    result[pos] = byte(
      (if header.masked: 0x80 else: 0x00) or 
      byte(header.payloadLen)
    )
  elif header.payloadLen <= uint64(uint16.high):
    result[pos] = byte(
      (if header.masked: 0x80 else: 0x00) or 
      126
    )
  else:
    result[pos] = byte(
      (if header.masked: 0x80 else: 0x00) or 
      127
    )
  pos.inc
  
  # 拡張ペイロード長
  if header.payloadLen >= 126:
    if header.payloadLen <= uint64(uint16.high):
      # 2バイト（16ビット）の長さ
      let len = uint16(header.payloadLen)
      result[pos] = byte((len shr 8) and 0xFF)
      result[pos+1] = byte(len and 0xFF)
      pos += 2
    else:
      # 8バイト（64ビット）の長さ
      var len = header.payloadLen
      for i in countdown(7, 0):
        result[pos + i] = byte(len and 0xFF)
        len = len shr 8
      pos += 8
  
  # マスキングキー
  if header.masked:
    for i in 0..3:
      result[pos + i] = header.maskingKey[i]

proc decodeFrameHeader(data: openArray[byte]): tuple[header: WebSocketFrameHeader, headerSize: int] =
  ## WebSocketフレームヘッダをデコード
  if data.len < 2:
    raise newException(FrameParseError, "不十分なデータでフレームヘッダを解析できません")
  
  var pos = 0
  var header: WebSocketFrameHeader
  
  # 1バイト目: FIN, RSV1-3, OpCode
  let byte1 = data[pos]
  header.fin = (byte1 and 0x80) != 0
  header.rsv1 = (byte1 and 0x40) != 0
  header.rsv2 = (byte1 and 0x20) != 0
  header.rsv3 = (byte1 and 0x10) != 0
  let opcodeValue = byte1 and 0x0F
  case opcodeValue:
  of 0x00: header.opcode = wsOpContinuation
  of 0x01: header.opcode = wsOpText
  of 0x02: header.opcode = wsOpBinary
  of 0x08: header.opcode = wsOpClose
  of 0x09: header.opcode = wsOpPing
  of 0x0A: header.opcode = wsOpPong
  else: raise newException(FrameParseError, "不明な操作コード: " & $opcodeValue)
  pos.inc
  
  # 2バイト目: MASK, PayloadLen
  let byte2 = data[pos]
  header.masked = (byte2 and 0x80) != 0
  let payloadLenIndicator = byte2 and 0x7F
  pos.inc
  
  # ペイロード長の取得
  case payloadLenIndicator:
  of 126:
    # 2バイト（16ビット）の長さ
    if data.len < pos + 2:
      raise newException(FrameParseError, "拡張ペイロード長（2バイト）を解析するのに十分なデータがありません")
    header.payloadLen = (uint64(data[pos]) shl 8) or uint64(data[pos+1])
    pos += 2
  of 127:
    # 8バイト（64ビット）の長さ
    if data.len < pos + 8:
      raise newException(FrameParseError, "拡張ペイロード長（8バイト）を解析するのに十分なデータがありません")
    var len: uint64 = 0
    for i in 0..7:
      len = (len shl 8) or uint64(data[pos + i])
    header.payloadLen = len
    pos += 8
  else:
    # 7ビットの長さ
    header.payloadLen = uint64(payloadLenIndicator)
  
  # マスキングキー
  if header.masked:
    if data.len < pos + 4:
      raise newException(FrameParseError, "マスキングキーを解析するのに十分なデータがありません")
    for i in 0..3:
      header.maskingKey[i] = data[pos + i]
    pos += 4
  
  result = (header, pos)

proc maskUnmaskData(data: var openArray[byte], maskingKey: array[4, byte], offset: int = 0) =
  ## データをマスク/アンマスク
  for i in 0..<data.len:
    data[i] = data[i] xor maskingKey[(i + offset) mod 4]

proc encodeFrame*(opcode: WebSocketOpCode, data: openArray[byte], fin: bool = true, mask: bool = false): seq[byte] =
  ## WebSocketフレームをエンコード
  var header = WebSocketFrameHeader(
    fin: fin,
    rsv1: false,
    rsv2: false,
    rsv3: false,
    opcode: opcode,
    masked: mask,
    payloadLen: uint64(data.len)
  )
  
  # マスキングキーの生成（必要な場合）
  if mask:
    var r = initRand()
    for i in 0..3:
      header.maskingKey[i] = byte(r.rand(0..255))
  
  # ヘッダのエンコード
  result = encodeFrameHeader(header)
  
  # データの追加
  let startPos = result.len
  result.setLen(startPos + data.len)
  
  if data.len > 0:
    copyMem(addr result[startPos], unsafeAddr data[0], data.len)
    
    # マスキング（必要な場合）
    if mask:
      var dataSlice = result[startPos .. result.high]
      maskUnmaskData(dataSlice, header.maskingKey)
  
proc encodeCloseFrame*(code: WebSocketCloseCode, reason: string = "", mask: bool = false): seq[byte] =
  ## 終了フレームをエンコード
  var payload = newSeq[byte](2 + reason.len)
  let codeValue = uint16(code)
  payload[0] = byte((codeValue shr 8) and 0xFF)
  payload[1] = byte(codeValue and 0xFF)
  
  if reason.len > 0:
    for i, c in reason:
      payload[i + 2] = byte(c)
  
  return encodeFrame(wsOpClose, payload, true, mask)

proc decodeCloseFrame*(data: openArray[byte]): tuple[code: uint16, reason: string] =
  ## 終了フレームをデコード
  if data.len < 2:
    return (1005'u16, "") # 1005: No Status Received
  
  let code = (uint16(data[0]) shl 8) or uint16(data[1])
  var reason = ""
  
  if data.len > 2:
    reason = newString(data.len - 2)
    for i in 2..<data.len:
      reason[i - 2] = char(data[i])
  
  return (code, reason)

proc generateWebSocketKey*(): string =
  ## WebSocketキーを生成（クライアント側で使用）
  var r = initRand()
  var key = newSeq[byte](16)
  for i in 0..<16:
    key[i] = byte(r.rand(0..255))
  
  result = encode(key)

proc computeWebSocketAccept*(key: string): string =
  ## WebSocketのAcceptキーを計算（サーバー側で使用）
  let concatenated = key & WEBSOCKET_GUID
  let sha1Hash = secureHash(concatenated)
  
  var hashBytes = newSeq[byte](20)
  for i in 0..<20:
    hashBytes[i] = byte(uint32(sha1Hash.data[i div 4]) shr (8 * (3 - (i mod 4))) and 0xFF)
  
  result = encode(hashBytes)

proc newWebSocketConnection*(socket: AsyncSocket, url: Uri = nil, isServer: bool = false, 
                            config: WebSocketConfig = nil): WebSocketConnection =
  ## 新しいWebSocket接続を作成
  new(result)
  result.socket = socket
  result.isServer = isServer
  result.state = wsStateConnecting
  result.url = url
  result.buffer = newSeq[byte](DEFAULT_BUFFER_SIZE)
  result.fragmentedOpcode = wsOpContinuation
  result.fragmentedData = @[]
  result.lastPingTime = 0
  result.lastPongTime = 0
  result.extensions = initTable[string, string]()
  result.closeCode = 0
  result.closeReason = ""
  result.messageQueue = initDeque[Future[WebSocketMessage]]()
  result.rng = initRand()
  
  if config.isNil:
    result.config = newWebSocketConfig()
    if isServer:
      result.config.maskFrames = false  # サーバーはマスクしない
  else:
    result.config = config
  
  result.bufferPool = newBufferPool(result.config.bufferPoolSize)

proc readFrame*(ws: WebSocketConnection): Future[tuple[opcode: WebSocketOpCode, data: seq[byte], fin: bool]] {.async.} =
  ## WebSocketフレームを非同期に読み込む
  var headerData = newSeq[byte](14)  # 最大ヘッダサイズ（フレームヘッダ + 拡張ペイロード長 + マスキングキー）
  var headerLen = 0
  var minHeaderSize = 2  # 最小ヘッダサイズ
  
  # ヘッダのために最小限のデータを読み込む
  while headerLen < minHeaderSize:
    if headerLen >= headerData.len:
      # バッファが不足している場合は拡張
      headerData.setLen(headerData.len * 2)
    
    let bytesRead = await ws.socket.recvInto(addr headerData[headerLen], headerData.len - headerLen)
    if bytesRead <= 0:
      raise newException(WebSocketError, "接続が閉じられました")
    
    headerLen += bytesRead
    
    # 最初の2バイトから必要な追加ヘッダ長を決定
    if headerLen >= 2:
      let payloadLenIndicator = headerData[1] and 0x7F
      let masked = (headerData[1] and 0x80) != 0
      
      # ヘッダサイズを再計算
      minHeaderSize = 2  # 基本ヘッダ
      if payloadLenIndicator == 126:
        minHeaderSize += 2  # 16ビットの拡張ペイロード長
      elif payloadLenIndicator == 127:
        minHeaderSize += 8  # 64ビットの拡張ペイロード長
      
      if masked:
        minHeaderSize += 4  # マスキングキー
  
  # ヘッダを解析
  let headerInfo = decodeFrameHeader(headerData.toOpenArray(0, headerLen - 1))
  let header = headerInfo.header
  let headerSize = headerInfo.headerSize
  
  # ペイロードサイズの検証
  if header.payloadLen > uint64(ws.config.maxFrameSize):
    await ws.socket.close()
    raise newException(WebSocketError, "フレームサイズが大きすぎます: " & $header.payloadLen)
  
  # ペイロードデータを読み込む
  var payload = ws.bufferPool.getBuffer(int(header.payloadLen))
  payload.setLen(int(header.payloadLen))
  
  var bytesRead = 0
  while bytesRead < payload.len:
    let readSize = await ws.socket.recvInto(addr payload[bytesRead], payload.len - bytesRead)
    if readSize <= 0:
      raise newException(WebSocketError, "接続が閉じられました")
    bytesRead += readSize
  
  # マスクされている場合はアンマスク
  if header.masked:
    maskUnmaskData(payload, header.maskingKey)
  
  return (header.opcode, payload, header.fin)

proc processMessages*(ws: WebSocketConnection) {.async.} =
  ## WebSocketメッセージを処理
  if ws.state != wsStateOpen:
    return
  
  try:
    while ws.state == wsStateOpen:
      let frame = await ws.readFrame()
      let opcode = frame.opcode
      let data = frame.data
      let fin = frame.fin
      
      case opcode
      of wsOpText, wsOpBinary:
        if fin:
          # 完全なメッセージ
          var message = WebSocketMessage(opcode: opcode)
          if opcode == wsOpText:
            message.textData = cast[string](data)
          else:
            message.binaryData = data
          
          if ws.messageQueue.len > 0:
            # キューが空でなければ、次の待機しているFutureに結果を設定
            let future = ws.messageQueue.popFirst()
            future.complete(message)
        else:
          # フラグメント化されたメッセージの開始
          ws.fragmentedOpcode = opcode
          ws.fragmentedData = data
      
      of wsOpContinuation:
        # フラグメント化されたメッセージの続き
        ws.fragmentedData.add(data)
        
        if fin:
          # フラグメント化されたメッセージの終了
          var message = WebSocketMessage(opcode: ws.fragmentedOpcode)
          if ws.fragmentedOpcode == wsOpText:
            message.textData = cast[string](ws.fragmentedData)
          else:
            message.binaryData = ws.fragmentedData
          
          # フラグメントデータをリセット
          ws.fragmentedOpcode = wsOpContinuation
          ws.fragmentedData = @[]
          
          if ws.messageQueue.len > 0:
            let future = ws.messageQueue.popFirst()
            future.complete(message)
      
      of wsOpClose:
        # 終了フレーム
        let closeInfo = decodeCloseFrame(data)
        ws.closeCode = closeInfo.code
        ws.closeReason = closeInfo.reason
        
        # 終了フレームを送り返す（まだ送っていなければ）
        if ws.state == wsStateOpen:
          ws.state = wsStateClosing
          let closeFrame = encodeCloseFrame(WebSocketCloseCode(closeInfo.code), closeInfo.reason, ws.config.maskFrames)
          await ws.socket.send(closeFrame)
          ws.state = wsStateClosed
        
        # すべての待機中のメッセージを終了で完了
        while ws.messageQueue.len > 0:
          let future = ws.messageQueue.popFirst()
          let closeMessage = WebSocketMessage(
            opcode: wsOpClose,
            closeCode: closeInfo.code,
            closeReason: closeInfo.reason
          )
          future.complete(closeMessage)
        
        # ソケットを閉じる
        await ws.socket.close()
        break
      
      of wsOpPing:
        # Pingが来たらPongを返す（自動応答が有効な場合）
        if ws.config.autoPong:
          let pongFrame = encodeFrame(wsOpPong, data, true, ws.config.maskFrames)
          await ws.socket.send(pongFrame)
        
        # Pingを上位層に通知したい場合はここでメッセージキューに追加
      
      of wsOpPong:
        # Pongを受信した時の処理
        ws.lastPongTime = epochTime()
  except:
    # エラーが発生したら接続を閉じる
    if ws.state != wsStateClosed:
      ws.state = wsStateClosed
      try:
        await ws.socket.close()
      except:
        discard
      
      # すべての待機中のメッセージをエラーで完了
      while ws.messageQueue.len > 0:
        let future = ws.messageQueue.popFirst()
        future.fail(getCurrentException())

proc sendFrame*(ws: WebSocketConnection, opcode: WebSocketOpCode, data: openArray[byte], fin: bool = true): Future[void] {.async.} =
  ## WebSocketフレームを送信
  if ws.state != wsStateOpen and ws.state != wsStateClosing:
    raise newException(WebSocketError, "WebSocket接続が開いていません")
  
  let frame = encodeFrame(opcode, data, fin, ws.config.maskFrames)
  await ws.socket.send(frame)

proc send*(ws: WebSocketConnection, data: string): Future[void] {.async.} =
  ## テキストメッセージを送信
  await ws.sendFrame(wsOpText, cast[seq[byte]](data))

proc send*(ws: WebSocketConnection, data: seq[byte]): Future[void] {.async.} =
  ## バイナリメッセージを送信
  await ws.sendFrame(wsOpBinary, data)

proc close*(ws: WebSocketConnection, code: WebSocketCloseCode = wsCloseNormal, reason: string = ""): Future[void] {.async.} =
  ## WebSocket接続を閉じる
  if ws.state == wsStateOpen:
    ws.state = wsStateClosing
    let closeFrame = encodeCloseFrame(code, reason, ws.config.maskFrames)
    try:
      await ws.socket.send(closeFrame)
      # 終了応答を待つ（タイムアウトあり）
      var closeTimeout = ws.config.closeTimeout
      if closeTimeout <= 0:
        closeTimeout = DEFAULT_CLOSE_TIMEOUT
      
      let timeoutFuture = sleepAsync(closeTimeout)
      let result = await timeoutFuture.withTimeout(closeTimeout)
      
      if result:
        # タイムアウトした場合は強制的に閉じる
        ws.state = wsStateClosed
    except:
      # エラーが発生した場合は強制的に閉じる
      ws.state = wsStateClosed
    
    # ソケットを閉じる
    try:
      await ws.socket.close()
    except:
      discard

proc ping*(ws: WebSocketConnection, data: seq[byte] = @[]): Future[void] {.async.} =
  ## Pingを送信
  if ws.state != wsStateOpen:
    raise newException(WebSocketError, "WebSocket接続が開いていません")
  
  await ws.sendFrame(wsOpPing, data)
  ws.lastPingTime = epochTime()

proc receive*(ws: WebSocketConnection): Future[WebSocketMessage] {.async.} =
  ## WebSocketメッセージを受信
  if ws.state != wsStateOpen:
    raise newException(WebSocketError, "WebSocket接続が開いていません")
  
  # 新しいFutureを作成してキューに追加
  var future = newFuture[WebSocketMessage]("WebSocketConnection.receive")
  ws.messageQueue.addLast(future)
  
  # 既にメッセージがあるか確認中のプロセスがなければ、バックグラウンドで処理を開始
  if ws.messageQueue.len == 1:
    asyncCheck ws.processMessages()
  
  return await future

proc keepAlive*(ws: WebSocketConnection) {.async.} =
  ## 接続を維持するためのPingを定期的に送信
  if ws.config.pingInterval <= 0:
    return
  
  while ws.state == wsStateOpen:
    # 前回のPingから十分な時間が経過したらPingを送信
    let now = epochTime()
    if now - ws.lastPingTime >= ws.config.pingInterval / 1000.0:
      try:
        await ws.ping()
      except:
        break
    
    # Pongのタイムアウトをチェック
    if ws.lastPingTime > 0 and ws.lastPongTime < ws.lastPingTime and 
       now - ws.lastPingTime >= ws.config.pingTimeout / 1000.0:
      # Pingがタイムアウトした場合は接続を閉じる
      try:
        await ws.close(wsCloseAbnormal, "Ping timeout")
      except:
        discard
      break
    
    # スリープ
    await sleepAsync(1000)  # 1秒ごとにチェック

proc isConnected*(ws: WebSocketConnection): bool =
  ## 接続が開いているかどうかを確認
  return ws.state == wsStateOpen

proc getUrl*(ws: WebSocketConnection): Uri =
  ## 接続URLを取得
  return ws.url

proc getExtensions*(ws: WebSocketConnection): Table[string, string] =
  ## 拡張機能を取得
  return ws.extensions

proc getCloseInfo*(ws: WebSocketConnection): tuple[code: uint16, reason: string] =
  ## 終了情報を取得
  return (ws.closeCode, ws.closeReason) 