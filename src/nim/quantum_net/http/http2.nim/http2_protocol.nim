# HTTP/2 Protocol Implementation
#
# HTTP/2プロトコルの基本実装
# RFC 7540, RFC 7541に準拠

import std/[asyncdispatch, asyncnet, tables, options, uri, strutils, streams]
import std/[sequtils, times, hashes, strformat, sugar]
import ../../compression/hpack
import ../../quantum_arch/threading/thread_pool

type
  Http2ErrorCode* = enum
    NoError = 0
    ProtocolError = 1
    InternalError = 2
    FlowControlError = 3
    SettingsTimeout = 4
    StreamClosed = 5
    FrameSizeError = 6
    RefusedStream = 7
    Cancel = 8
    CompressionError = 9
    ConnectError = 10
    EnhanceYourCalm = 11
    InadequateSecurity = 12
    Http11Required = 13

  Http2FrameType* = enum
    Data = 0
    Headers = 1
    Priority = 2
    RstStream = 3
    Settings = 4
    PushPromise = 5
    Ping = 6
    GoAway = 7
    WindowUpdate = 8
    Continuation = 9

  Http2FrameFlag* = enum
    EndStream = 0x1
    EndHeaders = 0x4
    Padded = 0x8
    Priority = 0x20
    Ack = 0x1  # For Settings and Ping frames
  
  Http2StreamState* = enum
    Idle
    ReservedLocal
    ReservedRemote
    Open
    HalfClosedLocal
    HalfClosedRemote
    Closed
  
  Http2Frame* = object
    length*: uint32  # 24ビット実際
    frameType*: Http2FrameType
    flags*: byte
    streamId*: uint32  # 31ビット実際
    payload*: string
  
  Http2Stream* = ref object
    id*: uint32
    state*: Http2StreamState
    windowSize*: uint32
    weight*: uint8
    dependency*: uint32
    exclusive*: bool
    headers*: seq[tuple[name: string, value: string]]
    receivedData*: string
    dataCompleted*: bool
    headersCompleted*: bool
    errorCode*: Http2ErrorCode
    request*: Http2Request
    response*: Future[Http2Response]
  
  Http2Settings* = object
    headerTableSize*: uint32
    enablePush*: bool
    maxConcurrentStreams*: uint32
    initialWindowSize*: uint32
    maxFrameSize*: uint32
    maxHeaderListSize*: uint32
  
  Http2Connection* = ref object
    socket*: AsyncSocket
    host*: string
    port*: string
    secure*: bool
    nextStreamId*: uint32
    lastStreamId*: uint32
    streams*: TableRef[uint32, Http2Stream]
    encoder*: HpackEncoder
    decoder*: HpackDecoder
    localSettings*: Http2Settings
    remoteSettings*: Http2Settings
    closed*: bool
    goAwayReceived*: bool
    readBuffer*: string
    writeBuffer*: string
    initialHandshakeDone*: bool
    connectionWindowSize*: uint32
    readTimeout*: int
    writeTimeout*: int
  
  Http2Request* = object
    method*: string
    url*: Uri
    headers*: seq[tuple[name: string, value: string]]
    body*: string
    priority*: uint8
    exclusive*: bool
    dependency*: uint32
  
  Http2Response* = object
    status*: int
    headers*: seq[tuple[name: string, value: string]]
    body*: string
    streamId*: uint32

# プロトコル定数
const
  HTTP2_PREFACE* = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  DEFAULT_HEADER_TABLE_SIZE* = 4096u32
  DEFAULT_ENABLE_PUSH* = true
  DEFAULT_MAX_CONCURRENT_STREAMS* = 100u32
  DEFAULT_INITIAL_WINDOW_SIZE* = 65535u32
  DEFAULT_MAX_FRAME_SIZE* = 16384u32
  DEFAULT_MAX_HEADER_LIST_SIZE* = uint32.high
  DEFAULT_READ_TIMEOUT* = 30000  # 30秒
  DEFAULT_WRITE_TIMEOUT* = 30000  # 30秒

# フラグチェック関数
proc hasFlag*(frame: Http2Frame, flag: Http2FrameFlag): bool {.inline.} =
  return (frame.flags and byte(flag)) != 0

# Http2Settingsの初期化
proc initHttp2Settings*(): Http2Settings =
  result = Http2Settings(
    headerTableSize: DEFAULT_HEADER_TABLE_SIZE,
    enablePush: DEFAULT_ENABLE_PUSH,
    maxConcurrentStreams: DEFAULT_MAX_CONCURRENT_STREAMS,
    initialWindowSize: DEFAULT_INITIAL_WINDOW_SIZE,
    maxFrameSize: DEFAULT_MAX_FRAME_SIZE,
    maxHeaderListSize: DEFAULT_MAX_HEADER_LIST_SIZE
  )

# 新しいHttp2接続を作成
proc newHttp2Connection*(host: string, port: string, secure: bool = false): Future[Http2Connection] {.async.} =
  var socket = newAsyncSocket()
  
  try:
    await socket.connect(host, Port(parseInt(port)))
    
    result = Http2Connection(
      socket: socket,
      host: host,
      port: port,
      secure: secure,
      nextStreamId: 1,  # クライアントは奇数のIDを使用
      lastStreamId: 0,
      streams: newTable[uint32, Http2Stream](),
      encoder: newHpackEncoder(DEFAULT_HEADER_TABLE_SIZE.int),
      decoder: newHpackDecoder(DEFAULT_HEADER_TABLE_SIZE.int),
      localSettings: initHttp2Settings(),
      remoteSettings: initHttp2Settings(),
      closed: false,
      goAwayReceived: false,
      readBuffer: "",
      writeBuffer: "",
      initialHandshakeDone: false,
      connectionWindowSize: DEFAULT_INITIAL_WINDOW_SIZE,
      readTimeout: DEFAULT_READ_TIMEOUT,
      writeTimeout: DEFAULT_WRITE_TIMEOUT
    )
  except:
    socket.close()
    raise

# Http2接続を閉じる
proc close*(conn: Http2Connection) {.async.} =
  if not conn.closed:
    conn.closed = true
    conn.socket.close()

# フレーム送信関数
proc sendFrame*(conn: Http2Connection, frame: Http2Frame): Future[void] {.async.} =
  var frameData = newStringOfCap(9 + frame.payload.len)
  
  # フレームヘッダーの作成（9バイト）
  frameData.add(char((frame.length shr 16) and 0xFF))
  frameData.add(char((frame.length shr 8) and 0xFF))
  frameData.add(char(frame.length and 0xFF))
  frameData.add(char(frame.frameType.ord))
  frameData.add(char(frame.flags))
  frameData.add(char((frame.streamId shr 24) and 0x7F))  # 最上位ビットは予約
  frameData.add(char((frame.streamId shr 16) and 0xFF))
  frameData.add(char((frame.streamId shr 8) and 0xFF))
  frameData.add(char(frame.streamId and 0xFF))
  
  # ペイロードの追加
  frameData.add(frame.payload)
  
  # フレーム送信
  await conn.socket.send(frameData)

# 接続初期化処理
proc performHandshake*(conn: Http2Connection): Future[void] {.async.} =
  if conn.initialHandshakeDone:
    return
  
  # HTTP/2プリフェイス送信
  await conn.socket.send(HTTP2_PREFACE)
  
  # SETTINGS送信
  var settingsPayload = ""
  
  # HEADER_TABLE_SIZE (0x1)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x01))
  settingsPayload.add(char((conn.localSettings.headerTableSize shr 24) and 0xFF))
  settingsPayload.add(char((conn.localSettings.headerTableSize shr 16) and 0xFF))
  settingsPayload.add(char((conn.localSettings.headerTableSize shr 8) and 0xFF))
  settingsPayload.add(char(conn.localSettings.headerTableSize and 0xFF))
  
  # ENABLE_PUSH (0x2)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x02))
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(if conn.localSettings.enablePush: 0x01 else: 0x00))
  
  # MAX_CONCURRENT_STREAMS (0x3)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x03))
  settingsPayload.add(char((conn.localSettings.maxConcurrentStreams shr 24) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxConcurrentStreams shr 16) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxConcurrentStreams shr 8) and 0xFF))
  settingsPayload.add(char(conn.localSettings.maxConcurrentStreams and 0xFF))
  
  # INITIAL_WINDOW_SIZE (0x4)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x04))
  settingsPayload.add(char((conn.localSettings.initialWindowSize shr 24) and 0xFF))
  settingsPayload.add(char((conn.localSettings.initialWindowSize shr 16) and 0xFF))
  settingsPayload.add(char((conn.localSettings.initialWindowSize shr 8) and 0xFF))
  settingsPayload.add(char(conn.localSettings.initialWindowSize and 0xFF))
  
  # MAX_FRAME_SIZE (0x5)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x05))
  settingsPayload.add(char((conn.localSettings.maxFrameSize shr 24) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxFrameSize shr 16) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxFrameSize shr 8) and 0xFF))
  settingsPayload.add(char(conn.localSettings.maxFrameSize and 0xFF))
  
  # MAX_HEADER_LIST_SIZE (0x6)
  settingsPayload.add(char(0x00))
  settingsPayload.add(char(0x06))
  settingsPayload.add(char((conn.localSettings.maxHeaderListSize shr 24) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxHeaderListSize shr 16) and 0xFF))
  settingsPayload.add(char((conn.localSettings.maxHeaderListSize shr 8) and 0xFF))
  settingsPayload.add(char(conn.localSettings.maxHeaderListSize and 0xFF))
  
  let settingsFrame = Http2Frame(
    length: uint32(settingsPayload.len),
    frameType: Settings,
    flags: 0,
    streamId: 0,  # SETTINGS は常にストリーム0
    payload: settingsPayload
  )
  
  await conn.sendFrame(settingsFrame)
  
  # サーバーからのSETTINGSとACKを待機
  var settingsReceived = false
  var settingsAcked = false
  
  # タイムアウト設定
  let startTime = epochTime()
  
  while not (settingsReceived and settingsAcked):
    # タイムアウトチェック
    if epochTime() - startTime > conn.readTimeout:
      raise newException(TimeoutError, "Handshake timeout")
    
    let frame = await conn.receiveFrame()
    
    case frame.frameType
    of Settings:
      if frame.hasFlag(Ack):
        settingsAcked = true
        logDebug("Received SETTINGS ACK")
      else:
        settingsReceived = true
        logDebug("Received SETTINGS frame")
        # サーバーのSETTINGSを処理
        await conn.processSettings(frame)
        
        # SETTINGSに対するACKを送信
        let ackFrame = Http2Frame(
          length: 0,
          frameType: Settings,
          flags: byte(Ack),
          streamId: 0,
          payload: ""
        )
        await conn.sendFrame(ackFrame)
        logDebug("Sent SETTINGS ACK")
    of WindowUpdate:
      # 初期ウィンドウ更新を処理
      if frame.streamId == 0:
        let windowSizeIncrement = parseWindowUpdatePayload(frame.payload)
        conn.connectionWindowSize += windowSizeIncrement
        logDebug("Connection window size updated to: " & $conn.connectionWindowSize)
    of Ping:
      # PINGに応答
      if not frame.hasFlag(Ack):
        let pingAckFrame = Http2Frame(
          length: uint32(frame.payload.len),
          frameType: Ping,
          flags: byte(Ack),
          streamId: 0,
          payload: frame.payload
        )
        await conn.sendFrame(pingAckFrame)
        logDebug("Responded to PING")
    of GoAway:
      # GoAwayフレームを処理
      let (lastStreamId, errorCode, debugData) = parseGoAwayPayload(frame.payload)
      conn.goAwayReceived = true
      conn.lastStreamId = lastStreamId
      conn.closed = true
      logError("Server sent GOAWAY during handshake: " & $errorCode & " - " & debugData)
      raise newException(Http2Error, "Server sent GOAWAY during handshake: " & $errorCode & " - " & debugData)
    else:
      # 他のフレームは一時的に保存（後で処理）
      conn.queueFrame(frame)
      logDebug("Queued frame of type: " & $frame.frameType)
  
  # 接続プリアンブルが完了
  conn.initialHandshakeDone = true
  logInfo("HTTP/2 handshake completed successfully")
  
  # 初期フロー制御ウィンドウの調整（オプション）
  if conn.localSettings.initialWindowSize > DEFAULT_INITIAL_WINDOW_SIZE:
    let increment = conn.localSettings.initialWindowSize - DEFAULT_INITIAL_WINDOW_SIZE
    let windowUpdateFrame = createWindowUpdateFrame(0, increment)
    await conn.sendFrame(windowUpdateFrame)
    logDebug("Sent initial connection WINDOW_UPDATE: +" & $increment)

# SETTINGSフレーム処理
proc processSettings*(conn: Http2Connection, frame: Http2Frame): Future[void] {.async.} =
  if frame.streamId != 0:
    # PROTOCOL_ERROR: SETTINGSフレームはストリーム0でなければならない
    await conn.sendGoAway(0, ProtocolError, "SETTINGS frame with non-zero stream ID")
    return
  
  if frame.hasFlag(Ack):
    # ACKフラグが設定されている場合、ペイロードは空でなければならない
    if frame.length > 0:
      await conn.sendGoAway(0, FrameSizeError, "SETTINGS ACK with payload")
    return
  
  var i = 0
  while i < frame.payload.len:
    if i + 6 > frame.payload.len:
      # ペイロードの長さが不正
      await conn.sendGoAway(0, FrameSizeError, "SETTINGS frame with invalid length")
      return
    
    let identifier = (uint16(ord(frame.payload[i])) shl 8) or uint16(ord(frame.payload[i+1]))
    let value = (uint32(ord(frame.payload[i+2])) shl 24) or
                (uint32(ord(frame.payload[i+3])) shl 16) or
                (uint32(ord(frame.payload[i+4])) shl 8) or
                uint32(ord(frame.payload[i+5]))
    
    case identifier
    of 0x1: # HEADER_TABLE_SIZE
      conn.remoteSettings.headerTableSize = value
      conn.decoder.setMaxTableSize(value.int)
    of 0x2: # ENABLE_PUSH
      if value > 1:
        # PROTOCOL_ERROR: ENABLE_PUSHは0か1でなければならない
        await conn.sendGoAway(0, ProtocolError, "ENABLE_PUSH with invalid value")
        return
      conn.remoteSettings.enablePush = value == 1
    of 0x3: # MAX_CONCURRENT_STREAMS
      conn.remoteSettings.maxConcurrentStreams = value
    of 0x4: # INITIAL_WINDOW_SIZE
      if value > 2147483647:
        # FLOW_CONTROL_ERROR: ウィンドウサイズは2^31-1以下でなければならない
        await conn.sendGoAway(0, FlowControlError, "INITIAL_WINDOW_SIZE too large")
        return
      
      # 既存のすべてのストリームのウィンドウサイズを調整
      let delta = int(value) - int(conn.remoteSettings.initialWindowSize)
      for streamId, stream in conn.streams:
        if stream.state != Idle and stream.state != Closed:
          let newSize = int(stream.windowSize) + delta
          if newSize < 0:
            # FLOW_CONTROL_ERROR: ウィンドウサイズがオーバーフロー
            await conn.sendGoAway(0, FlowControlError, "Window size overflow")
            return
          stream.windowSize = uint32(newSize)
      
      conn.remoteSettings.initialWindowSize = value
    of 0x5: # MAX_FRAME_SIZE
      if value < 16384 or value > 16777215:
        # PROTOCOL_ERROR: MAX_FRAME_SIZEは16384から2^24-1の範囲内でなければならない
        await conn.sendGoAway(0, ProtocolError, "MAX_FRAME_SIZE out of range")
        return
      conn.remoteSettings.maxFrameSize = value
    of 0x6: # MAX_HEADER_LIST_SIZE
      conn.remoteSettings.maxHeaderListSize = value
    else:
      # 未知の識別子は無視
      discard
    
    i += 6

# GoAwayフレーム送信
proc sendGoAway*(conn: Http2Connection, lastStreamId: uint32, errorCode: Http2ErrorCode, 
                debugData: string = ""): Future[void] {.async.} =
  var payload = ""
  
  # 最後に処理されたストリームID
  payload.add(char((lastStreamId shr 24) and 0x7F))
  payload.add(char((lastStreamId shr 16) and 0xFF))
  payload.add(char((lastStreamId shr 8) and 0xFF))
  payload.add(char(lastStreamId and 0xFF))
  
  # エラーコード
  payload.add(char((uint32(errorCode) shr 24) and 0xFF))
  payload.add(char((uint32(errorCode) shr 16) and 0xFF))
  payload.add(char((uint32(errorCode) shr 8) and 0xFF))
  payload.add(char(uint32(errorCode) and 0xFF))
  
  # デバッグデータ（オプション）
  if debugData.len > 0:
    payload.add(debugData)
  
  let goAwayFrame = Http2Frame(
    length: uint32(payload.len),
    frameType: GoAway,
    flags: 0,
    streamId: 0,  # GoAwayは常にストリーム0
    payload: payload
  )
  
  await conn.sendFrame(goAwayFrame)
  conn.goAwayReceived = true

# フレーム受信関数
proc receiveFrame*(conn: Http2Connection): Future[Http2Frame] {.async.} =
  # 最低9バイト（フレームヘッダー）を読み込む
  while conn.readBuffer.len < 9:
    let data = await conn.socket.recv(4096)
    if data.len == 0:
      conn.closed = true
      raise newException(IOError, "Connection closed by peer")
    conn.readBuffer.add(data)
  
  # フレームヘッダーの解析
  let length = (uint32(ord(conn.readBuffer[0])) shl 16) or
               (uint32(ord(conn.readBuffer[1])) shl 8) or
               uint32(ord(conn.readBuffer[2]))
  
  let frameType = Http2FrameType(ord(conn.readBuffer[3]))
  let flags = byte(ord(conn.readBuffer[4]))
  
  let streamId = (uint32(ord(conn.readBuffer[5]) and 0x7F) shl 24) or
                 (uint32(ord(conn.readBuffer[6])) shl 16) or
                 (uint32(ord(conn.readBuffer[7])) shl 8) or
                 uint32(ord(conn.readBuffer[8]))
  
  # フレームサイズの検証
  if length > conn.remoteSettings.maxFrameSize:
    # FRAME_SIZE_ERROR: フレームが大きすぎる
    await conn.sendGoAway(conn.lastStreamId, FrameSizeError, "Frame too large")
    conn.closed = true
    raise newException(IOError, "Frame size error")
  
  # ペイロードを読み込む
  while conn.readBuffer.len < 9 + length:
    let data = await conn.socket.recv(4096)
    if data.len == 0:
      conn.closed = true
      raise newException(IOError, "Connection closed by peer")
    conn.readBuffer.add(data)
  
  # フレームの作成
  result = Http2Frame(
    length: length,
    frameType: frameType,
    flags: flags,
    streamId: streamId,
    payload: conn.readBuffer[9 ..< 9 + length]
  )
  
  # 読み込み済みバッファの更新
  conn.readBuffer = conn.readBuffer[9 + length .. ^1]
  
  # フレームタイプに応じた基本的な検証
  case frameType
  of Settings, Ping, GoAway:
    if streamId != 0:
      # PROTOCOL_ERROR: これらのフレームはストリーム0でなければならない
      await conn.sendGoAway(conn.lastStreamId, ProtocolError, "Control frame with non-zero stream ID")
      conn.closed = true
      raise newException(IOError, "Protocol error: control frame with non-zero stream ID")
  of WindowUpdate:
    if length != 4:
      # FRAME_SIZE_ERROR: WINDOW_UPDATEは4バイトのペイロードを持つ必要がある
      if streamId == 0:
        await conn.sendGoAway(conn.lastStreamId, FrameSizeError, "WINDOW_UPDATE with invalid length")
      else:
        await conn.sendRstStream(streamId, FrameSizeError)
      raise newException(IOError, "Frame size error: WINDOW_UPDATE with invalid length")
  of Priority:
    if length != 5:
      # FRAME_SIZE_ERROR: PRIORITYは5バイトのペイロードを持つ必要がある
      if streamId == 0:
        await conn.sendGoAway(conn.lastStreamId, FrameSizeError, "PRIORITY with invalid length")
      else:
        await conn.sendRstStream(streamId, FrameSizeError)
      raise newException(IOError, "Frame size error: PRIORITY with invalid length")
  of RstStream:
    if length != 4:
      # FRAME_SIZE_ERROR: RST_STREAMは4バイトのペイロードを持つ必要がある
      await conn.sendGoAway(conn.lastStreamId, FrameSizeError, "RST_STREAM with invalid length")
      raise newException(IOError, "Frame size error: RST_STREAM with invalid length")
    if streamId == 0:
      # PROTOCOL_ERROR: RST_STREAMはストリーム0に送信できない
      await conn.sendGoAway(conn.lastStreamId, ProtocolError, "RST_STREAM on stream 0")
      raise newException(IOError, "Protocol error: RST_STREAM on stream 0")
  else:
    discard  # 他のフレームタイプは特別な検証が不要

# RST_STREAMフレーム送信
proc sendRstStream*(conn: Http2Connection, streamId: uint32, errorCode: Http2ErrorCode): Future[void] {.async.} =
  if streamId == 0:
    # PROTOCOL_ERROR: RST_STREAMはストリーム0に送信できない
    return
  
  var payload = ""
  payload.add(char((uint32(errorCode) shr 24) and 0xFF))
  payload.add(char((uint32(errorCode) shr 16) and 0xFF))
  payload.add(char((uint32(errorCode) shr 8) and 0xFF))
  payload.add(char(uint32(errorCode) and 0xFF))
  
  let rstFrame = Http2Frame(
    length: 4,
    frameType: RstStream,
    flags: 0,
    streamId: streamId,
    payload: payload
  )
  
  await conn.sendFrame(rstFrame)
  
  # ストリームの状態を更新
  if streamId in conn.streams:
    conn.streams[streamId].state = Closed
    conn.streams[streamId].errorCode = errorCode

# ストリーム作成関数
proc createStream*(conn: Http2Connection): Http2Stream =
  let streamId = conn.nextStreamId
  conn.nextStreamId += 2  # クライアントは奇数のIDを使用
  
  result = Http2Stream(
    id: streamId,
    state: Idle,
    windowSize: conn.remoteSettings.initialWindowSize,
    weight: 16,  # デフォルト
    dependency: 0,
    exclusive: false,
    headers: @[],
    receivedData: "",
    dataCompleted: false,
    headersCompleted: false,
    errorCode: NoError,
    request: Http2Request(),
    response: newFuture[Http2Response]("http2.createStream")
  )
  
  conn.streams[streamId] = result

# ヘッダー送信関数
proc sendHeaders*(conn: Http2Connection, stream: Http2Stream, headers: seq[tuple[name: string, value: string]], 
                 endStream: bool, endHeaders: bool = true): Future[void] {.async.} =
  let encodedHeaders = conn.encoder.encodeHeaders(headers)
  
  # ヘッダーが大きい場合は分割して送信
  var flags: byte = 0
  if endStream:
    flags = flags or byte(EndStream)
  
  if encodedHeaders.len <= conn.remoteSettings.maxFrameSize.int:
    # 1つのフレームで送信可能
    if endHeaders:
      flags = flags or byte(EndHeaders)
    
    let headersFrame = Http2Frame(
      length: uint32(encodedHeaders.len),
      frameType: Headers,
      flags: flags,
      streamId: stream.id,
      payload: encodedHeaders
    )
    
    await conn.sendFrame(headersFrame)
  else:
    # 複数のフレームに分割
    let firstChunkSize = conn.remoteSettings.maxFrameSize.int
    let firstChunk = encodedHeaders[0 ..< firstChunkSize]
    
    let headersFrame = Http2Frame(
      length: uint32(firstChunk.len),
      frameType: Headers,
      flags: flags,  # ENDHEADERSフラグなし
      streamId: stream.id,
      payload: firstChunk
    )
    
    await conn.sendFrame(headersFrame)
    
    # 残りのヘッダーをCONTINUATIONフレームで送信
    var offset = firstChunkSize
    while offset < encodedHeaders.len:
      let chunkSize = min(encodedHeaders.len - offset, conn.remoteSettings.maxFrameSize.int)
      let chunk = encodedHeaders[offset ..< offset + chunkSize]
      
      var contFlags: byte = 0
      if endHeaders and offset + chunkSize >= encodedHeaders.len:
        contFlags = contFlags or byte(EndHeaders)
      
      let contFrame = Http2Frame(
        length: uint32(chunk.len),
        frameType: Continuation,
        flags: contFlags,
        streamId: stream.id,
        payload: chunk
      )
      
      await conn.sendFrame(contFrame)
      offset += chunkSize
  
  # ストリーム状態の更新
  if stream.state == Idle:
    stream.state = Open
  
  if endStream:
    if stream.state == Open:
      stream.state = HalfClosedLocal
    elif stream.state == HalfClosedRemote:
      stream.state = Closed

# データ送信関数
proc sendData*(conn: Http2Connection, stream: Http2Stream, data: string, endStream: bool): Future[void] {.async.} =
  ## HTTP/2データフレームを送信する関数
  ## 
  ## パラメータ:
  ## - conn: HTTP/2接続オブジェクト
  ## - stream: データを送信するストリーム
  ## - data: 送信するデータ
  ## - endStream: このデータでストリームを終了するかどうか
  
  if stream.state == Closed or stream.state == HalfClosedLocal:
    raise newException(Http2ProtocolError, "Cannot send data on closed stream")
  
  # フロー制御を考慮したデータ分割送信
  var offset = 0
  var dataToSend = data
  
  # 送信データが空でendStreamが真の場合は、空のDATAフレームを送信
  if dataToSend.len == 0 and endStream:
    let dataFrame = Http2Frame(
      length: 0,
      frameType: Data,
      flags: byte(EndStream),
      streamId: stream.id,
      payload: ""
    )
    await conn.sendFrame(dataFrame)
    
    # ストリーム状態の更新
    if stream.state == Open:
      stream.state = HalfClosedLocal
    elif stream.state == HalfClosedRemote:
      stream.state = Closed
    return
  
  # 送信待機キュー
  var waitingForWindow = false
  var windowUpdateReceived = newFuture[void]("waitForWindowUpdate")
  
  while offset < dataToSend.len:
    # 送信可能なデータサイズを計算（ウィンドウサイズとフレームサイズの制限を考慮）
    let maxSize = min(stream.windowSize.int, conn.connectionWindowSize.int)
    let chunkSize = min(min(dataToSend.len - offset, conn.remoteSettings.maxFrameSize.int), maxSize)
    
    if chunkSize <= 0:
      # ウィンドウサイズが不足している場合、ウィンドウ更新を待機
      if not waitingForWindow:
        waitingForWindow = true
        windowUpdateReceived = newFuture[void]("waitForWindowUpdate")
        
        # ウィンドウ更新イベントのハンドラを設定
        proc onWindowUpdate(streamId: uint32, increment: uint32) =
          if streamId == 0 or streamId == stream.id:
            if not windowUpdateReceived.finished:
              windowUpdateReceived.complete()
        
        conn.onWindowUpdate.add(onWindowUpdate)
      
      try:
        # タイムアウト付きでウィンドウ更新を待機
        await withTimeout(windowUpdateReceived, 30_000) # 30秒タイムアウト
        waitingForWindow = false
        # ハンドラを削除
        conn.onWindowUpdate.keepItIf(it != onWindowUpdate)
      except AsyncTimeoutError:
        # タイムアウト発生時はエラーを発生
        conn.onWindowUpdate.keepItIf(it != onWindowUpdate)
        raise newException(Http2TimeoutError, "Timeout waiting for flow control window update")
      
      continue
    
    let chunk = dataToSend[offset ..< offset + chunkSize]
    
    var flags: byte = 0
    if endStream and offset + chunkSize >= dataToSend.len:
      flags = flags or byte(EndStream)
    
    let dataFrame = Http2Frame(
      length: uint32(chunk.len),
      frameType: Data,
      flags: flags,
      streamId: stream.id,
      payload: chunk
    )
    
    try:
      await conn.sendFrame(dataFrame)
    except Exception as e:
      # 送信エラー時は適切にエラーハンドリング
      if stream.state != Closed:
        stream.error = e.msg
        stream.state = Closed
      raise e
    
    # ウィンドウサイズの更新
    stream.windowSize -= uint32(chunkSize)
    conn.connectionWindowSize -= uint32(chunkSize)
    
    # 送信統計の更新
    stream.bytesSent += uint64(chunkSize)
    conn.totalBytesSent += uint64(chunkSize)
    
    offset += chunkSize
    
    # 優先度に基づいて他のストリームにCPUを譲る
    if stream.priority < HighPriority and offset < dataToSend.len:
      await sleepAsync(0)
  
  # ストリーム状態の更新
  if endStream:
    if stream.state == Open:
      stream.state = HalfClosedLocal
    elif stream.state == HalfClosedRemote:
      stream.state = Closed
      
    # ストリームが閉じられた場合、関連リソースのクリーンアップ
    if stream.state == Closed:
      stream.cleanupResources()
      
      # 必要に応じてストリームの参照を削除（実装依存）
      if conn.autoCleanupStreams:
        conn.removeClosedStream(stream.id)

# ウィンドウ更新処理
proc processWindowUpdate*(conn: Http2Connection, frame: Http2Frame): Future[void] {.async.} =
  if frame.length != 4:
    # FRAME_SIZE_ERROR: WINDOW_UPDATEは4バイトのペイロードを持つ必要がある
    if frame.streamId == 0:
      await conn.sendGoAway(conn.lastStreamId, FrameSizeError, "WINDOW_UPDATE with invalid length")
    else:
      await conn.sendRstStream(frame.streamId, FrameSizeError)
    return
  
  let increment = (uint32(ord(frame.payload[0]) and 0x7F) shl 24) or
                  (uint32(ord(frame.payload[1])) shl 16) or
                  (uint32(ord(frame.payload[2])) shl 8) or
                  uint32(ord(frame.payload[3]))
  
# リクエスト送信関数
proc sendRequest*(conn: Http2Connection, request: Http2Request): Future[Http2Response] {.async.} =
  # 接続が初期化されていない場合は、ハンドシェイクを行う
  if not conn.initialHandshakeDone:
    await conn.performHandshake()
  
  # ストリームの作成
  let stream = conn.createStream()
  stream.request = request
  stream.state = Open
  
  # :method, :scheme, :authority, :pathの準備
  var headers = @[
    (":method", request.method),
    (":scheme", request.url.scheme),
    (":authority", request.url.hostname & (if request.url.port.len > 0: ":" & request.url.port else: "")),
    (":path", if request.url.path.len > 0: request.url.path else: "/")
  ]
  
  # クエリパラメータが存在する場合、:pathに追加
  if request.url.query.len > 0:
    headers[^1] = (":path", headers[^1][1] & "?" & request.url.query)
  
  # 追加のヘッダー
  for header in request.headers:
    # HTTP/2では小文字のヘッダー名が必須
    let name = header[0].toLowerAscii()
    # 禁止されたヘッダーをスキップ
    if name notin ["connection", "keep-alive", "upgrade", "proxy-connection", 
                   "transfer-encoding", "host"]:
      headers.add((name, header[1]))
  
  # コンテンツ長さの追加（ボディがある場合）
  if request.body.len > 0 and not headers.anyIt(it[0] == "content-length"):
    headers.add(("content-length", $request.body.len))
  
  # ヘッダーの送信
  let endStream = request.body.len == 0
  await conn.sendHeaders(stream, headers, endStream)
  
  # ボディの送信（存在する場合）
  if not endStream:
    await conn.sendData(stream, request.body, true)
  
  # レスポンス待機
  let responsePromise = newFuture[Http2Response]("http2.sendRequest")
  stream.responsePromise = responsePromise
  
  # タイムアウト処理
  let timeoutFuture = sleepAsync(request.timeout)
  
  # レスポンスかタイムアウトのどちらかを待つ
  await race(@[responsePromise, timeoutFuture])
  
  if timeoutFuture.finished and not responsePromise.finished:
    # タイムアウト発生
    stream.state = Closed
    await conn.sendRstStream(stream.id, Cancel)
    raise newException(TimeoutError, "HTTP/2 request timed out")
  
  # レスポンスの取得
  result = await responsePromise
  
  # ストリームのクリーンアップ
  if result.streamEnded:
    if stream.state == HalfClosedLocal:
      stream.state = Closed
    elif stream.state == Open:
      stream.state = HalfClosedRemote
    
    # 完了したストリームをアクティブリストから削除（必要に応じて履歴に保存）
    if stream.state == Closed:
      conn.activeStreams.del(stream.id)
      if conn.keepStreamHistory:
        conn.closedStreams[stream.id] = stream

# 便利なHTTP/2リクエストメソッド
proc get*(conn: Http2Connection, url: string, headers: seq[tuple[name: string, value: string]] = @[], 
          timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
          dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 GETリクエストを送信する
  ## 
  ## Parameters:
  ##   conn: HTTP/2コネクション
  ##   url: リクエスト先URL
  ##   headers: 追加のHTTPヘッダー
  ##   timeout: リクエストタイムアウト（ミリ秒）
  ##   priority: ストリーム優先度（1-256）
  ##   exclusive: 排他的依存関係フラグ
  ##   dependency: 依存するストリームID
  let req = Http2Request(
    method: "GET",
    url: parseUri(url),
    headers: headers,
    body: "",
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 GET request failed: " & e.msg)

proc post*(conn: Http2Connection, url: string, body: string, 
          headers: seq[tuple[name: string, value: string]] = @[],
          timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
          dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 POSTリクエストを送信する
  ## 
  ## Parameters:
  ##   conn: HTTP/2コネクション
  ##   url: リクエスト先URL
  ##   body: リクエストボディ
  ##   headers: 追加のHTTPヘッダー
  ##   timeout: リクエストタイムアウト（ミリ秒）
  ##   priority: ストリーム優先度（1-256）
  ##   exclusive: 排他的依存関係フラグ
  ##   dependency: 依存するストリームID
  let req = Http2Request(
    method: "POST",
    url: parseUri(url),
    headers: headers,
    body: body,
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 POST request failed: " & e.msg)

proc put*(conn: Http2Connection, url: string, body: string, 
         headers: seq[tuple[name: string, value: string]] = @[],
         timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
         dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 PUTリクエストを送信する
  let req = Http2Request(
    method: "PUT",
    url: parseUri(url),
    headers: headers,
    body: body,
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 PUT request failed: " & e.msg)

proc delete*(conn: Http2Connection, url: string, 
            headers: seq[tuple[name: string, value: string]] = @[],
            timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
            dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 DELETEリクエストを送信する
  let req = Http2Request(
    method: "DELETE",
    url: parseUri(url),
    headers: headers,
    body: "",
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 DELETE request failed: " & e.msg)

proc head*(conn: Http2Connection, url: string, 
          headers: seq[tuple[name: string, value: string]] = @[],
          timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
          dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 HEADリクエストを送信する
  let req = Http2Request(
    method: "HEAD",
    url: parseUri(url),
    headers: headers,
    body: "",
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 HEAD request failed: " & e.msg)

proc options*(conn: Http2Connection, url: string, 
             headers: seq[tuple[name: string, value: string]] = @[],
             timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
             dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 OPTIONSリクエストを送信する
  let req = Http2Request(
    method: "OPTIONS",
    url: parseUri(url),
    headers: headers,
    body: "",
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 OPTIONS request failed: " & e.msg)

proc patch*(conn: Http2Connection, url: string, body: string, 
           headers: seq[tuple[name: string, value: string]] = @[],
           timeout: int = 30000, priority: uint8 = 16, exclusive: bool = false, 
           dependency: uint32 = 0): Future[Http2Response] {.async.} =
  ## HTTP/2 PATCHリクエストを送信する
  let req = Http2Request(
    method: "PATCH",
    url: parseUri(url),
    headers: headers,
    body: body,
    timeout: timeout,
    priority: priority,
    exclusive: exclusive,
    dependency: dependency
  )
  
  try:
    result = await conn.sendRequest(req)
  except CatchableError as e:
    raise newException(Http2Error, "HTTP/2 PATCH request failed: " & e.msg)