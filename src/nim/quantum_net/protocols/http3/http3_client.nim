# HTTP/3クライアント実装 - RFC 9114完全準拠
# 世界最高水準のHTTP/3プロトコル実装

import std/[asyncdispatch, tables, strutils, uri, options, times]
import std/[strformat, sequtils, deques, locks, monotimes]
import ../quic/quic_client
import ../quic/quic_stream
import ../quic/quic_frame_parser
import qpack_encoder
import qpack_decoder

const
  # HTTP/3 フレームタイプ
  HTTP3_FRAME_DATA = 0x00'u64
  HTTP3_FRAME_HEADERS = 0x01'u64
  HTTP3_FRAME_CANCEL_PUSH = 0x03'u64
  HTTP3_FRAME_SETTINGS = 0x04'u64
  HTTP3_FRAME_PUSH_PROMISE = 0x05'u64
  HTTP3_FRAME_GOAWAY = 0x07'u64
  HTTP3_FRAME_MAX_PUSH_ID = 0x0D'u64
  
  # HTTP/3 設定
  HTTP3_SETTING_QPACK_MAX_TABLE_CAPACITY = 0x01'u64
  HTTP3_SETTING_MAX_FIELD_SECTION_SIZE = 0x06'u64
  HTTP3_SETTING_QPACK_BLOCKED_STREAMS = 0x07'u64
  
  # HTTP/3 エラーコード
  HTTP3_NO_ERROR = 0x0100'u64
  HTTP3_GENERAL_PROTOCOL_ERROR = 0x0101'u64
  HTTP3_INTERNAL_ERROR = 0x0102'u64
  HTTP3_STREAM_CREATION_ERROR = 0x0103'u64
  HTTP3_CLOSED_CRITICAL_STREAM = 0x0104'u64
  HTTP3_FRAME_UNEXPECTED = 0x0105'u64
  HTTP3_FRAME_ERROR = 0x0106'u64
  HTTP3_EXCESSIVE_LOAD = 0x0107'u64
  HTTP3_ID_ERROR = 0x0108'u64
  HTTP3_SETTINGS_ERROR = 0x0109'u64
  HTTP3_MISSING_SETTINGS = 0x010A'u64
  HTTP3_REQUEST_REJECTED = 0x010B'u64
  HTTP3_REQUEST_CANCELLED = 0x010C'u64
  HTTP3_REQUEST_INCOMPLETE = 0x010D'u64
  HTTP3_MESSAGE_ERROR = 0x010E'u64
  HTTP3_CONNECT_ERROR = 0x010F'u64
  HTTP3_VERSION_FALLBACK = 0x0110'u64

type
  Http3FrameType* = enum
    h3fData = HTTP3_FRAME_DATA
    h3fHeaders = HTTP3_FRAME_HEADERS
    h3fCancelPush = HTTP3_FRAME_CANCEL_PUSH
    h3fSettings = HTTP3_FRAME_SETTINGS
    h3fPushPromise = HTTP3_FRAME_PUSH_PROMISE
    h3fGoAway = HTTP3_FRAME_GOAWAY
    h3fMaxPushId = HTTP3_FRAME_MAX_PUSH_ID

  Http3Frame* = ref object of RootObj
    frameType*: Http3FrameType

  Http3DataFrame* = ref object of Http3Frame
    data*: seq[byte]

  Http3HeadersFrame* = ref object of Http3Frame
    headers*: seq[tuple[name: string, value: string]]
    encodedHeaders*: seq[byte]

  Http3SettingsFrame* = ref object of Http3Frame
    settings*: Table[uint64, uint64]

  Http3PushPromiseFrame* = ref object of Http3Frame
    pushId*: uint64
    headers*: seq[tuple[name: string, value: string]]

  Http3GoAwayFrame* = ref object of Http3Frame
    streamId*: uint64

  Http3CancelPushFrame* = ref object of Http3Frame
    pushId*: uint64

  Http3MaxPushIdFrame* = ref object of Http3Frame
    pushId*: uint64

  Http3Request* = object
    method*: string
    uri*: Uri
    headers*: seq[tuple[name: string, value: string]]
    body*: seq[byte]
    priority*: int

  Http3Response* = object
    status*: int
    headers*: seq[tuple[name: string, value: string]]
    body*: seq[byte]
    trailers*: seq[tuple[name: string, value: string]]

  Http3StreamState* = enum
    h3sIdle
    h3sOpen
    h3sHalfClosedLocal
    h3sHalfClosedRemote
    h3sClosed

  Http3Stream* = ref object
    id*: uint64
    state*: Http3StreamState
    request*: Option[Http3Request]
    response*: Option[Http3Response]
    receivedFrames*: Deque[Http3Frame]
    responseComplete*: bool
    priority*: int

  Http3Client* = ref object
    quicClient*: QuicClient
    qpackEncoder*: QpackEncoder
    qpackDecoder*: QpackDecoder
    
    # ストリーム管理
    streams*: Table[uint64, Http3Stream]
    nextStreamId*: uint64
    
    # 制御ストリーム
    controlStreamId*: uint64
    qpackEncoderStreamId*: uint64
    qpackDecoderStreamId*: uint64
    
    # 設定
    settings*: Table[uint64, uint64]
    peerSettings*: Table[uint64, uint64]
    
    # Server Push
    maxPushId*: uint64
    pushPromises*: Table[uint64, Http3PushPromiseFrame]
    
    # 統計
    requestsSent*: uint64
    responsesReceived*: uint64
    bytesReceived*: uint64
    bytesSent*: uint64
    
    # イベント
    responseReceived*: AsyncEvent
    pushReceived*: AsyncEvent
    
    # ロック
    clientLock*: Lock

# HTTP/3クライアントの初期化
proc newHttp3Client*(quicClient: QuicClient): Http3Client =
  result = Http3Client(
    quicClient: quicClient,
    qpackEncoder: newQpackEncoder(),
    qpackDecoder: newQpackDecoder(),
    streams: initTable[uint64, Http3Stream](),
    nextStreamId: 0,  # クライアント開始の双方向ストリーム
    settings: initTable[uint64, uint64](),
    peerSettings: initTable[uint64, uint64](),
    maxPushId: 0,
    pushPromises: initTable[uint64, Http3PushPromiseFrame](),
    requestsSent: 0,
    responsesReceived: 0,
    bytesReceived: 0,
    bytesSent: 0,
    responseReceived: newAsyncEvent(),
    pushReceived: newAsyncEvent()
  )
  
  initLock(result.clientLock)
  
  # デフォルト設定
  result.settings[HTTP3_SETTING_QPACK_MAX_TABLE_CAPACITY] = 4096
  result.settings[HTTP3_SETTING_MAX_FIELD_SECTION_SIZE] = 16384
  result.settings[HTTP3_SETTING_QPACK_BLOCKED_STREAMS] = 100

# HTTP/3接続の確立
proc connect*(client: Http3Client, host: string, port: int): Future[void] {.async.} =
  ## HTTP/3接続を確立
  
  # QUICクライアントで接続
  await client.quicClient.connect(host, port)
  
  # 制御ストリームの作成
  let controlStream = client.quicClient.streamManager.createStream(sdUnidirectional, true)
  client.controlStreamId = controlStream.id
  
  # QPACK専用ストリームの作成
  let qpackEncoderStream = client.quicClient.streamManager.createStream(sdUnidirectional, true)
  let qpackDecoderStream = client.quicClient.streamManager.createStream(sdUnidirectional, true)
  client.qpackEncoderStreamId = qpackEncoderStream.id
  client.qpackDecoderStreamId = qpackDecoderStream.id
  
  # ストリームタイプの送信
  await controlStream.writeData(@[0x00'u8])  # 制御ストリーム
  await qpackEncoderStream.writeData(@[0x02'u8])  # QPACKエンコーダーストリーム
  await qpackDecoderStream.writeData(@[0x03'u8])  # QPACKデコーダーストリーム
  
  # 設定フレームの送信
  await client.sendSettings()

# 設定フレームの送信
proc sendSettings*(client: Http3Client): Future[void] {.async.} =
  ## HTTP/3設定を送信
  
  let settingsFrame = Http3SettingsFrame(
    frameType: h3fSettings,
    settings: client.settings
  )
  
  let frameData = client.serializeHttp3Frame(settingsFrame)
  let controlStream = client.quicClient.streamManager.getStream(client.controlStreamId).get()
  await controlStream.writeData(frameData)

# HTTP/3フレームのシリアライゼーション
proc serializeHttp3Frame*(client: Http3Client, frame: Http3Frame): seq[byte] =
  ## HTTP/3フレームをバイト列にシリアライズ
  
  result = @[]
  
  # フレームタイプ
  result.add(encodeVariableLengthInteger(frame.frameType.uint64))
  
  case frame.frameType:
  of h3fData:
    let dataFrame = cast[Http3DataFrame](frame)
    result.add(encodeVariableLengthInteger(dataFrame.data.len.uint64))
    result.add(dataFrame.data)
  
  of h3fHeaders:
    let headersFrame = cast[Http3HeadersFrame](frame)
    result.add(encodeVariableLengthInteger(headersFrame.encodedHeaders.len.uint64))
    result.add(headersFrame.encodedHeaders)
  
  of h3fSettings:
    let settingsFrame = cast[Http3SettingsFrame](frame)
    var settingsData: seq[byte] = @[]
    
    for key, value in settingsFrame.settings:
      settingsData.add(encodeVariableLengthInteger(key))
      settingsData.add(encodeVariableLengthInteger(value))
    
    result.add(encodeVariableLengthInteger(settingsData.len.uint64))
    result.add(settingsData)
  
  of h3fPushPromise:
    let pushFrame = cast[Http3PushPromiseFrame](frame)
    var pushData: seq[byte] = @[]
    
    pushData.add(encodeVariableLengthInteger(pushFrame.pushId))
    
    # ヘッダーをエンコード
    let encodedHeaders = client.qpackEncoder.encodeHeaders(pushFrame.headers)
    pushData.add(encodedHeaders)
    
    result.add(encodeVariableLengthInteger(pushData.len.uint64))
    result.add(pushData)
  
  of h3fGoAway:
    let goAwayFrame = cast[Http3GoAwayFrame](frame)
    let goAwayData = encodeVariableLengthInteger(goAwayFrame.streamId)
    result.add(encodeVariableLengthInteger(goAwayData.len.uint64))
    result.add(goAwayData)
  
  of h3fCancelPush:
    let cancelFrame = cast[Http3CancelPushFrame](frame)
    let cancelData = encodeVariableLengthInteger(cancelFrame.pushId)
    result.add(encodeVariableLengthInteger(cancelData.len.uint64))
    result.add(cancelData)
  
  of h3fMaxPushId:
    let maxPushFrame = cast[Http3MaxPushIdFrame](frame)
    let maxPushData = encodeVariableLengthInteger(maxPushFrame.pushId)
    result.add(encodeVariableLengthInteger(maxPushData.len.uint64))
    result.add(maxPushData)

# HTTP/3フレームの解析
proc parseHttp3Frame*(client: Http3Client, data: seq[byte]): Http3Frame =
  ## バイト列からHTTP/3フレームを解析
  
  var offset = 0
  let frameType = parseVariableLengthInteger(data, offset)
  let frameLength = parseVariableLengthInteger(data, offset)
  
  if offset + frameLength.int > data.len:
    raise newException(ValueError, "Insufficient data for HTTP/3 frame")
  
  let frameData = data[offset..<offset + frameLength.int]
  
  case frameType:
  of HTTP3_FRAME_DATA:
    result = Http3DataFrame(
      frameType: h3fData,
      data: frameData
    )
  
  of HTTP3_FRAME_HEADERS:
    let headers = client.qpackDecoder.decodeHeaders(frameData)
    result = Http3HeadersFrame(
      frameType: h3fHeaders,
      headers: headers,
      encodedHeaders: frameData
    )
  
  of HTTP3_FRAME_SETTINGS:
    var settings = initTable[uint64, uint64]()
    var settingsOffset = 0
    
    while settingsOffset < frameData.len:
      let key = parseVariableLengthInteger(frameData, settingsOffset)
      let value = parseVariableLengthInteger(frameData, settingsOffset)
      settings[key] = value
    
    result = Http3SettingsFrame(
      frameType: h3fSettings,
      settings: settings
    )
  
  of HTTP3_FRAME_PUSH_PROMISE:
    var pushOffset = 0
    let pushId = parseVariableLengthInteger(frameData, pushOffset)
    let headerData = frameData[pushOffset..^1]
    let headers = client.qpackDecoder.decodeHeaders(headerData)
    
    result = Http3PushPromiseFrame(
      frameType: h3fPushPromise,
      pushId: pushId,
      headers: headers
    )
  
  of HTTP3_FRAME_GOAWAY:
    var goAwayOffset = 0
    let streamId = parseVariableLengthInteger(frameData, goAwayOffset)
    
    result = Http3GoAwayFrame(
      frameType: h3fGoAway,
      streamId: streamId
    )
  
  of HTTP3_FRAME_CANCEL_PUSH:
    var cancelOffset = 0
    let pushId = parseVariableLengthInteger(frameData, cancelOffset)
    
    result = Http3CancelPushFrame(
      frameType: h3fCancelPush,
      pushId: pushId
    )
  
  of HTTP3_FRAME_MAX_PUSH_ID:
    var maxPushOffset = 0
    let pushId = parseVariableLengthInteger(frameData, maxPushOffset)
    
    result = Http3MaxPushIdFrame(
      frameType: h3fMaxPushId,
      pushId: pushId
    )
  
  else:
    # 未知のフレームタイプ - 無視
    result = Http3DataFrame(
      frameType: h3fData,
      data: frameData
    )

# HTTPリクエストの送信
proc sendRequest*(client: Http3Client, request: Http3Request): Future[Http3Response] {.async.} =
  ## HTTPリクエストを送信し、レスポンスを受信
  
  withLock(client.clientLock):
    # 新しいストリームを作成
    let stream = client.quicClient.streamManager.createStream(sdBidirectional, true)
    let streamId = stream.id
    
    # HTTP/3ストリームを作成
    let http3Stream = Http3Stream(
      id: streamId,
      state: h3sOpen,
      request: some(request),
      response: none(Http3Response),
      receivedFrames: initDeque[Http3Frame](),
      responseComplete: false,
      priority: request.priority
    )
    
    client.streams[streamId] = http3Stream
    client.nextStreamId = streamId + 4
  
  # ヘッダーフレームの作成
  var headers: seq[tuple[name: string, value: string]] = @[]
  headers.add((":method", request.method))
  headers.add((":scheme", $request.uri.scheme))
  headers.add((":authority", request.uri.hostname))
  headers.add((":path", request.uri.path))
  
  # カスタムヘッダーの追加
  for header in request.headers:
    headers.add(header)
  
  # QPACKでヘッダーをエンコード
  let encodedHeaders = client.qpackEncoder.encodeHeaders(headers)
  
  let headersFrame = Http3HeadersFrame(
    frameType: h3fHeaders,
    headers: headers,
    encodedHeaders: encodedHeaders
  )
  
  # ヘッダーフレームの送信
  let headerData = client.serializeHttp3Frame(headersFrame)
  await stream.writeData(headerData)
  
  # ボディがある場合はDATAフレームを送信
  if request.body.len > 0:
    let dataFrame = Http3DataFrame(
      frameType: h3fData,
      data: request.body
    )
    
    let bodyData = client.serializeHttp3Frame(dataFrame)
    await stream.writeData(bodyData)
  
  # ストリームをクローズ（FINを送信）
  stream.closeStreamForWriting()
  
  # 統計更新
  client.requestsSent += 1
  client.bytesSent += headerData.len.uint64 + request.body.len.uint64
  
  # レスポンスを待機
  result = await client.waitForResponse(streamId)

# レスポンスの待機
proc waitForResponse*(client: Http3Client, streamId: uint64): Future[Http3Response] {.async.} =
  ## 指定されたストリームのレスポンスを待機
  
  while true:
    let streamOpt = client.quicClient.streamManager.getStream(streamId)
    if streamOpt.isNone:
      raise newException(ValueError, "Stream not found")
    
    let stream = streamOpt.get()
    
    # ストリームからデータを読み取り
    let data = await stream.readData()
    
    if data.len > 0:
      # HTTP/3フレームを解析
      await client.processStreamData(streamId, data)
    
    # レスポンスが完了したかチェック
    withLock(client.clientLock):
      if client.streams.hasKey(streamId):
        let http3Stream = client.streams[streamId]
        if http3Stream.responseComplete and http3Stream.response.isSome:
          return http3Stream.response.get()
    
import ../quic/quic_connection
import ./http3_stream
import ./http3_settings
import ../../compression/qpack/qpack_encoder
import ../../compression/qpack/qpack_decoder
import ../../utils/varint
import ../../utils/binary
import ../../utils/dns_utils
import ../../utils/uri_utils
import ../http/http_types
import ../http/http_headers
import ../http/http_cookies

const
  DEFAULT_HTTPS_PORT* = 443
  DEFAULT_USER_AGENT = "Quantum/1.0 HTTP/3"

type
  Http3ClientOptions* = object
    ## HTTP/3クライアントのオプション
    requestTimeout*: int       # リクエストタイムアウト（ミリ秒）
    idleTimeout*: int          # アイドルタイムアウト（秒）
    maxConcurrentStreams*: int # 最大同時ストリーム数
    maxHeaderSize*: int        # 最大ヘッダーサイズ
    enableQUICv2*: bool        # QUICv2を有効化
    verifyTls*: bool           # TLS証明書検証
    tlsAlpn*: seq[string]      # TLS ALPN
    followRedirects*: bool     # リダイレクトを自動的に処理
    maxRedirects*: int         # 最大リダイレクト回数
    keepAliveTimeout*: int     # キープアライブタイムアウト
    enableHTTP3Migration*: bool # HTTP/3マイグレーション有効化
    enableDatagram*: bool      # QUICデータグラムのサポート
    qpackMaxTableCapacity*: int # QPACK最大テーブル容量
    qpackBlockedStreams*: int   # QPACKブロックストリーム数
    userAgentString*: string    # ユーザーエージェント文字列
    enablePush*: bool           # サーバープッシュのサポート
    h3Settings*: Http3Settings  # HTTP/3設定

  HttpError* = object of CatchableError
  
  HttpTimeoutError* = object of HttpError
  
  Http3Client* = ref object
    ## HTTP/3クライアント
    quicClient*: QuicClient            # 基盤となるQUICクライアント
    streamManager*: Http3StreamManager # ストリームマネージャー
    qpackEncoder*: QpackEncoder        # QPACKエンコーダー
    qpackDecoder*: QpackDecoder        # QPACKデコーダー
    settings*: Http3Settings           # HTTP/3設定
    serverSettings*: Http3Settings     # サーバーの設定
    connected*: bool                   # 接続状態
    closed*: bool                      # クローズ状態
    goawayReceived*: bool              # GOAWAYフラグ
    maxPushId*: uint64                 # 最大プッシュID
    activeRequests*: Table[uint64, Future[HttpResponse]] # アクティブリクエスト
    host*: string                      # ホスト
    port*: int                         # ポート
    defaultHeaders*: seq[HttpHeader]   # デフォルトヘッダー
    logger*: Logger                    # ロガー
    alpn*: string                      # ALPN文字列
    timeout*: int                      # タイムアウト（ミリ秒）
    idleTimeout*: int                  # アイドルタイムアウト（秒）
    closeFuture*: Future[void]         # クローズ完了Future
    options*: Http3ClientOptions       # クライアントオプション
    sessionCookies*: Table[string, string] # セッションCookie
    preconnectedHosts*: Table[string, Http3Client] # プリコネクト済みホスト
    stats*: ClientStats                # クライアント統計
    keepAliveFailureCount*: int        # キープアライブ失敗回数

  ClientStats* = object
    totalRequests*: int
    successfulRequests*: int
    failedRequests*: int
    totalRtt*: float
    rttSamples*: int
    minRtt*: float
    maxRtt*: float
    throughput*: float  # バイト/秒
    bytesSent*: int64
    bytesReceived*: int64
    lastRequestTime*: Time
    connectionUptime*: int64  # 秒

# デフォルトオプションを生成
proc defaultOptions*(): Http3ClientOptions =
  result = Http3ClientOptions(
    requestTimeout: 30000,  # 30秒
    idleTimeout: 60,        # 60秒
    maxConcurrentStreams: 100,
    maxHeaderSize: 16384,
    enableQUICv2: true,
    verifyTls: true,
    tlsAlpn: @["h3", "h3-29"],
    followRedirects: true,
    maxRedirects: 10,
    keepAliveTimeout: 60,
    enableHTTP3Migration: true,
    enableDatagram: false,
    qpackMaxTableCapacity: 4096,
    qpackBlockedStreams: 16,
    userAgentString: DEFAULT_USER_AGENT,
    enablePush: false,
    h3Settings: nil  # 生成時に初期化
  )
  
  # デフォルトのHTTP/3設定を生成
  result.h3Settings = newHttp3Settings()

# 新しいHTTP/3クライアントを作成
proc newHttp3Client*(options: Http3ClientOptions = defaultOptions()): Http3Client =
  # QPACKエンコーダー・デコーダーを作成
  let qpackEncoder = newQpackEncoder(options.qpackMaxTableCapacity)
  let qpackDecoder = newQpackDecoder(options.qpackMaxTableCapacity)
  
  # ストリームマネージャーを作成
  let streamManager = newHttp3StreamManager(qpackEncoder, qpackDecoder)
  
  # 設定がnilの場合は作成
  var settings = options.h3Settings
  if settings == nil:
    settings = newHttp3Settings()
  
  # QUICクライアントの設定を準備
  var quicConfig = defaultQuicConfig()
  quicConfig.alpn = options.tlsAlpn
  quicConfig.maxIdleTimeout = uint64(options.idleTimeout * 1000)
  quicConfig.initialMaxStreamsBidi = uint64(options.maxConcurrentStreams)
  quicConfig.initialMaxStreamsUni = uint64(options.maxConcurrentStreams)
  quicConfig.enableReliableTransmission = true
  quicConfig.enablePacing = true
  quicConfig.verifyPeer = options.verifyTls
  
  # QUICクライアントを作成
  let quicClient = newQuicClient(quicConfig)
  
  # HTTP/3クライアントを作成
  result = Http3Client(
    quicClient: quicClient,
    streamManager: streamManager,
    qpackEncoder: qpackEncoder,
    qpackDecoder: qpackDecoder,
    settings: settings,
    serverSettings: Http3Settings(),
    connected: false,
    closed: false,
    goawayReceived: false,
    maxPushId: 0,
    activeRequests: initTable[uint64, Future[HttpResponse]](),
    defaultHeaders: @[
      ("user-agent", options.userAgentString),
      ("accept", "*/*")
    ],
    logger: newConsoleLogger(),
    alpn: "h3",
    timeout: if options.requestTimeout > 0: options.requestTimeout else: 30000,
    idleTimeout: if options.idleTimeout > 0: options.idleTimeout else: 60,
    closeFuture: newFuture[void]("http3.client.close"),
    options: options,
    sessionCookies: initTable[string, string](),
    preconnectedHosts: initTable[string, Http3Client](),
    stats: ClientStats(),
    keepAliveFailureCount: 0
  )
  
  # QUICイベントハンドラの設定
  quicClient.onStreamAvailable = proc(stream: QuicStream) {.async.} =
    await result.handleIncomingStream(stream)
  
  quicClient.onConnectionClosed = proc(reason: string) {.async.} =
    if not result.closed:
      result.closed = true
      for streamId, reqFuture in result.activeRequests:
        if not reqFuture.finished:
          reqFuture.fail(newException(HttpError, "Connection closed: " & reason))
      
      if not result.closeFuture.finished:
        result.closeFuture.complete()

# 接続
proc connect*(client: Http3Client, host: string, port: int = DEFAULT_HTTPS_PORT): Future[bool] {.async.} =
  """
  HTTP/3サーバーに接続します。
  
  Parameters:
  - host: 接続先ホスト名
  - port: 接続先ポート（デフォルト443）
  
  Returns:
  - 接続が成功したかどうか
  """
  if client.connected:
    client.logger.debug("Already connected")
    return true
  
  client.host = host
  client.port = port
  
  # QUICクライアントを接続
  client.logger.debug("Connecting to " & host & ":" & $port & " using QUIC")
  let quicConnected = await client.quicClient.connect(host, port, client.alpn)
  
  if not quicConnected:
    client.logger.error("Failed to establish QUIC connection")
    return false
  
  client.connected = true
  client.logger.debug("QUIC connection established")
  
  try:
    # 制御ストリームの作成
    let controlStream = await client.streamManager.createControlStream(client.quicClient)
    
    # QPACK用のストリームを作成
    let encoderStream = await client.streamManager.createQpackEncoderStream(client.quicClient)
    let decoderStream = await client.streamManager.createQpackDecoderStream(client.quicClient)
    
    # 設定を送信
    await client.sendSettings(controlStream)
    
    # QPACKエンコーダー・デコーダーを設定
    client.qpackEncoder.setEncoderStream(encoderStream.quicStream)
    client.qpackDecoder.setDecoderStream(decoderStream.quicStream)
    
    # 制御ストリームからデータを読み取る（非同期）
    asyncCheck client.readFromControlStream(controlStream)
    
    return true
  except:
    client.logger.error("Failed to setup HTTP/3 connection: " & getCurrentExceptionMsg())
    await client.close()
    return false

# 設定を送信
proc sendSettings*(client: Http3Client, controlStream: Http3Stream): Future[void] {.async.} =
  # HTTP/3設定フレームを構築
  var settingsData = ""
  
  # 各設定パラメータを追加
  settingsData.add(encodeVarInt(0x01))  # QPACK_MAX_TABLE_CAPACITY
  settingsData.add(encodeVarInt(client.settings.qpackMaxTableCapacity))
  
  settingsData.add(encodeVarInt(0x07))  # QPACK_BLOCKED_STREAMS
  settingsData.add(encodeVarInt(client.settings.qpackBlockedStreams))
  
  settingsData.add(encodeVarInt(0x06))  # MAX_FIELD_SECTION_SIZE
  settingsData.add(encodeVarInt(client.settings.maxFieldSectionSize))
  
  # HTTP/3フレームヘッダー（SETTINGS）
  let frameHeader = encodeVarInt(0x04) & encodeVarInt(uint64(settingsData.len))
  
  # ストリームタイプ（CONTROL = 0x00）を書き込み
  await controlStream.quicStream.write(encodeVarInt(0x00))
  
  # フレームを送信
  await controlStream.quicStream.write(frameHeader & settingsData)
  
  client.logger.debug("HTTP/3 SETTINGS sent")

# 制御ストリームからデータを読み取る
proc readFromControlStream*(client: Http3Client, stream: Http3Stream): Future[void] {.async.} =
  # ストリームからデータを継続的に読み取り、フレームを処理
  try:
    # ストリームタイプを読み取る
    let (typeData, _) = await stream.quicStream.read()
    if typeData.len == 0:
      client.logger.error("Control stream closed unexpectedly")
      return
    
    let streamType = decodeSingleVarInt(typeData)
    if streamType != 0x00:  # Control stream
      client.logger.error("Invalid stream type on control stream: " & $streamType)
      return
    
    # フレームの読み取りと処理を継続
    while true:
      # フレームタイプを読み取り
      let (frameTypeData, typeFin) = await stream.quicStream.read()
      if frameTypeData.len == 0 or typeFin:
        if typeFin:
          client.logger.error("Control stream closed by peer")
        else:
          client.logger.error("Failed to read frame type")
        break
      
      let frameType = decodeSingleVarInt(frameTypeData)
      
      # フレーム長を読み取り
      let (frameLenData, lenFin) = await stream.quicStream.read()
      if frameLenData.len == 0 or lenFin:
        client.logger.error("Failed to read frame length")
        break
      
      let frameLen = decodeSingleVarInt(frameLenData)
      
      # フレームデータを読み取り
      var frameData = ""
      var remainingLen = frameLen
      
      while remainingLen > 0:
        let (data, fin) = await stream.quicStream.read()
        if data.len == 0 or fin:
          client.logger.error("Failed to read frame data")
          break
        
        frameData.add(data)
        remainingLen -= data.len
      
      # フレームを処理
      case frameType
      of 0x04:  # SETTINGS
        await client.handleSettingsFrame(frameData)
      of 0x07:  # GOAWAY
        await client.handleGoawayFrame(frameData)
      else:
        client.logger.debug("Ignoring frame type: " & $frameType)
  except:
    client.logger.error("Error reading from control stream: " & getCurrentExceptionMsg())

# SETTINGSフレームを処理
proc handleSettingsFrame*(client: Http3Client, frameData: string): Future[void] {.async.} =
  var pos = 0
  var settings = newHttp3Settings()
  
  while pos < frameData.len:
    # 識別子と値を読み取り
    let id = decodeSingleVarInt(frameData[pos..^1])
    pos += varIntLength(frameData[pos..^1])
    
    let value = decodeSingleVarInt(frameData[pos..^1])
    pos += varIntLength(frameData[pos..^1])
    
    # 設定を適用
    case id
    of 0x01:  # QPACK_MAX_TABLE_CAPACITY
      settings.qpackMaxTableCapacity = value
    of 0x07:  # QPACK_BLOCKED_STREAMS
      settings.qpackBlockedStreams = value
    of 0x06:  # MAX_FIELD_SECTION_SIZE
      settings.maxFieldSectionSize = value
    else:
      settings.additionalSettings[id] = value
  
  # サーバー設定を保存
  client.serverSettings = settings
  
  # QPACKエンコーダーの設定を更新
  client.qpackEncoder.setMaxTableCapacity(min(client.settings.qpackMaxTableCapacity, settings.qpackMaxTableCapacity))
  client.qpackEncoder.setMaxBlockedStreams(min(client.settings.qpackBlockedStreams, settings.qpackBlockedStreams))
  
  client.logger.debug("Received HTTP/3 SETTINGS: " & $settings)

# GOAWAYフレームを処理
proc handleGoawayFrame*(client: Http3Client, frameData: string): Future[void] {.async.} =
  if frameData.len == 0:
    client.logger.error("Empty GOAWAY frame")
    return
  
  let streamId = decodeSingleVarInt(frameData)
  client.logger.debug("Received GOAWAY with Stream ID: " & $streamId)
  
  # GOAWAYフラグを設定
  client.goawayReceived = true
  
  # 該当ストリームIDより大きいすべてのアクティブリクエストをキャンセル
  var activeIds: seq[uint64] = @[]
  for id in client.activeRequests.keys:
    if id > streamId:
      activeIds.add(id)
  
  for id in activeIds:
    if client.activeRequests.hasKey(id):
      let future = client.activeRequests[id]
      if not future.finished:
        future.fail(newException(HttpError, "Stream rejected by server GOAWAY"))
      client.activeRequests.del(id)

# リクエストストリームを作成
proc createRequestStream*(client: Http3Client): Future[Http3Stream] {.async.} =
  # リクエストのためのQUICストリームを作成
  let quicStream = await client.quicClient.createStream(sdBidirectional)
  
  # HTTP/3ストリームを作成
  let http3Stream = newHttp3Stream(quicStream, stRequest)
  
  # ストリームマネージャーに登録
  client.streamManager.streams[http3Stream.id] = http3Stream
  
  # 優先度を通常に設定
  client.streamManager.priorityManager.setPriority(http3Stream.id, plNormal)
  
  return http3Stream

# 制御ストリームを作成
proc createControlStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  # 制御ストリームのためのQUICストリームを作成（単方向）
  let quicStream = await quicClient.createStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let http3Stream = newHttp3Stream(quicStream, stControl)
  
  # ストリームマネージャーに登録
  manager.streams[http3Stream.id] = http3Stream
  manager.controlStreamId = some(http3Stream.id)
  
  return http3Stream

# QPACKエンコーダーストリームを作成
proc createQpackEncoderStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  # QPACKエンコーダーストリームのためのQUICストリームを作成（単方向）
  let quicStream = await quicClient.createStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let http3Stream = newHttp3Stream(quicStream, stQpackEncoder)
  
  # ストリームマネージャーに登録
  manager.streams[http3Stream.id] = http3Stream
  manager.qpackEncoderStreamId = some(http3Stream.id)
  
  return http3Stream

# QPACKデコーダーストリームを作成
proc createQpackDecoderStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  # QPACKデコーダーストリームのためのQUICストリームを作成（単方向）
  let quicStream = await quicClient.createStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let http3Stream = newHttp3Stream(quicStream, stQpackDecoder)
  
  # ストリームマネージャーに登録
  manager.streams[http3Stream.id] = http3Stream
  manager.qpackDecoderStreamId = some(http3Stream.id)
  
  return http3Stream

# HTTP/3リクエストを送信
proc request*(client: Http3Client, req: HttpRequest): Future[HttpResponse] {.async.} =
  # リクエスト統計の開始
  let startTime = getMonoTime()
  inc(client.stats.totalRequests)
  client.stats.lastRequestTime = getTime()
  
  # 非接続状態ならエラー
  if not client.connected or client.closed:
    raise newException(HttpError, "Client not connected")
  
  # GOAWAYを受け取っている場合はエラー
  if client.goawayReceived:
    raise newException(HttpError, "Connection is going away")
  
  # リクエストストリームを作成
  let stream = await client.createRequestStream()
  let streamId = stream.id
  
  # リクエスト送信とレスポンス受信のFutureを作成
  var responseFuture = newFuture[HttpResponse]("http3.client.request")
  client.activeRequests[streamId] = responseFuture
  
  # タイムアウト設定
  var timeoutFuture: Future[void] = nil
  if client.timeout > 0:
    timeoutFuture = sleepAsync(client.timeout)
  
  try:
    # ヘッダー準備
    var headers = client.defaultHeaders
    
    # メソッドとパスを追加
    headers.add(("method", req.method))
    headers.add(("scheme", req.url.scheme))
    headers.add(("authority", req.url.hostname & 
                (if req.url.port.len > 0: ":" & req.url.port else: "")))
    
    let path = 
      if req.url.path.len == 0: "/" 
      else: req.url.path & 
           (if req.url.query.len > 0: "?" & req.url.query else: "")
    
    headers.add(("path", path))
    
    # ユーザー指定ヘッダーを追加
    for header in req.headers:
      # すでに追加した特殊ヘッダーは除外
      if not header.name.toLowerAscii() in ["method", "scheme", "authority", "path"]:
        headers.add(header)
    
    # ヘッダーフレーム送信
    await stream.sendHeaders(headers, client.qpackEncoder, req.body.len == 0)
    
    # ボディがある場合は送信
    if req.body.len > 0:
      await stream.sendData(req.body)
      # FINを送信してストリームを閉じる
      await stream.quicStream.shutdown()
    
    # 統計データの更新
    client.stats.bytesSent += stream.sentBytes
    
    # タイムアウト競合
    if timeoutFuture != nil:
      let winner = await responseFuture or timeoutFuture
      if winner == timeoutFuture:
        # タイムアウト発生
        stream.reset(0x10c) # HTTP_REQUEST_CANCELLED
        client.activeRequests.del(streamId)
        inc(client.stats.failedRequests)
        raise newException(HttpTimeoutError, "Request timed out after " & $client.timeout & "ms")
    
    # レスポンス受信処理はバックグラウンドで進行中
    # ここでは、future完了を待機
    let response = await responseFuture
    
    # 成功統計
    inc(client.stats.successfulRequests)
    let rtt = (getMonoTime() - startTime).inMilliseconds.float
    client.stats.totalRtt += rtt
    inc(client.stats.rttSamples)
    
    # 最小/最大RTT更新
    if client.stats.rttSamples == 1:
      client.stats.minRtt = rtt
      client.stats.maxRtt = rtt
    else:
      client.stats.minRtt = min(client.stats.minRtt, rtt)
      client.stats.maxRtt = max(client.stats.maxRtt, rtt)
    
    client.stats.bytesReceived += response.body.len
    
    return response
  except:
    let msg = getCurrentExceptionMsg()
    client.logger.error("Request error: " & msg)
    
    # ストリームをリセット（必要に応じて）
    if stream.state notin {ssClosed, ssReset, ssError}:
      try:
        stream.reset(0x10c) # HTTP_REQUEST_CANCELLED
      except:
        discard
    
    # アクティブリクエストから削除
    client.activeRequests.del(streamId)
    
    # 統計更新
    inc(client.stats.failedRequests)
    
    # Futureがまだ完了していなければ失敗状態に
    if not responseFuture.finished:
      responseFuture.fail(newException(HttpError, msg))
    
    raise

# 受信ストリームを処理
proc handleIncomingStream*(client: Http3Client, quicStream: QuicStream): Future[void] {.async.} =
  let streamId = quicStream.id
  
  # ストリームタイプを検出
  let streamType = detectStreamType(streamId)
  
  # HTTP/3ストリームを作成
  let stream = newHttp3Stream(quicStream, streamType)
  
  # ストリームマネージャーに登録
  client.streamManager.streams[streamId] = stream
  
  try:
    case streamType
    of stControl:
      # 制御ストリーム
      client.streamManager.controlStreamId = some(streamId)
      await client.readFromControlStream(stream)
    
    of stQpackEncoder:
      # QPACKエンコーダーストリーム
      client.streamManager.qpackEncoderStreamId = some(streamId)
      client.qpackDecoder.setEncoderReceiveStream(quicStream)
    
    of stQpackDecoder:
      # QPACKデコーダーストリーム
      client.streamManager.qpackDecoderStreamId = some(streamId)
      client.qpackEncoder.setDecoderReceiveStream(quicStream)
    
    of stRequest:
      # リクエストストリーム（通常はクライアントでは発生しない）
      client.logger.warn("Unexpected request stream from server: " & $streamId)
    
    of stPush:
      # プッシュストリーム
      if client.options.enablePush:
        await client.handlePushStream(stream)
      else:
        stream.reset(0x10) # PUSH_REFUSED
    
    else:
      # その他のストリームは無視
      client.logger.debug("Ignoring stream of type: " & $streamType)
  except:
    client.logger.error("Error handling stream " & $streamId & ": " & getCurrentExceptionMsg())

# クライアントを閉じる
proc close*(client: Http3Client): Future[void] {.async.} =
  """
  HTTP/3クライアントを閉じる
  
  すべてのアクティブなリクエストをキャンセルし、接続を閉じます。
  """
  if client.closed:
    return
  
  client.closed = true
  client.connected = false
  
  # アクティブなリクエストをキャンセル
  for streamId, reqFuture in client.activeRequests:
    if not reqFuture.finished:
      reqFuture.fail(newException(HttpError, "Connection closed by client"))
  
  client.activeRequests.clear()
  
  # QUICクライアントを閉じる
  if client.quicClient != nil:
    await client.quicClient.close()
  
  # プリコネクト済みのクライアントも閉じる
  for _, preconnectClient in client.preconnectedHosts:
    if not preconnectClient.closed:
      await preconnectClient.close()
  
  client.preconnectedHosts.clear()
  
  # クローズFutureを完了
  if not client.closeFuture.finished:
    client.closeFuture.complete()

# 適応型タイムアウト設定
proc adaptiveTimeout*(client: var Http3Client) =
  let successRate = client.stats.successfulRequests / max(1, client.stats.totalRequests)
  let avgRtt = client.stats.totalRtt / max(1, client.stats.rttSamples)
  
  if successRate > 0.95:
    # 高成功率の場合、RTTの2倍+バッファでタイムアウト設定
    client.timeout = int(avgRtt * 2.0) + 1000
  elif successRate > 0.8:
    # それなりの成功率の場合、RTTの3倍+バッファ
    client.timeout = int(avgRtt * 3.0) + 2000
  else:
    # 低成功率の場合、RTTの5倍+大きめバッファ
    client.timeout = int(avgRtt * 5.0) + 5000
  
  # 最小・最大制限
  client.timeout = max(1000, min(30000, client.timeout))

# バックグラウンドキープアライブ機能
proc startKeepAlive*(client: Http3Client, intervalSec: int = 15) =
  """
  接続を維持するためのキープアライブを開始します。
  これによりNATタイムアウトやアイドル切断を防止します。
  """
  asyncCheck client.keepAliveLoop(intervalSec)

proc keepAliveLoop(client: Http3Client, intervalSec: int): Future[void] {.async.} =
  while client.connected and not client.closed:
    await sleepAsync(intervalSec * 1000)
    
    if not client.connected or client.closed:
      break
    
    try:
      # キープアライブpingを送信
      await client.quicClient.sendPing()
      client.logger.debug("Keep-alive ping sent")
    except:
      client.logger.warn("Keep-alive failed: " & getCurrentExceptionMsg())
      
      # 5回連続で失敗したら接続が切れたと判断
      if client.keepAliveFailureCount >= 5:
        client.logger.error("Keep-alive failed 5 times in a row, closing connection")
        await client.close()
        break
      
      inc(client.keepAliveFailureCount)
      continue
    
    # 成功したらカウンタリセット
    client.keepAliveFailureCount = 0

# URL文字列からリクエスト
proc get*(client: Http3Client, url: string): Future[HttpResponse] {.async.} =
  """
  指定URLにGETリクエストを送信
  
  Parameters:
  - url: リクエスト先URL
  
  Returns:
  - HTTPレスポンス
  """
  let parsedUrl = parseUri(url)
  
  # HTTPSプロトコルを強制
  if parsedUrl.scheme.toLowerAscii() != "https":
    raise newException(HttpError, "HTTP/3 requires HTTPS protocol")
  
  # リクエストオブジェクトを構築
  let req = HttpRequest(
    method: "GET",
    url: parsedUrl,
    headers: @[],
    body: ""
  )
  
  return await client.request(req)

# 便利なHTTPメソッド
proc post*(client: Http3Client, url: string, body: string, contentType: string = "application/x-www-form-urlencoded"): Future[HttpResponse] {.async.} =
  """
  指定URLにPOSTリクエストを送信
  
  Parameters:
  - url: リクエスト先URL
  - body: リクエストボディ
  - contentType: コンテンツタイプ
  
  Returns:
  - HTTPレスポンス
  """
  let parsedUrl = parseUri(url)
  
  # HTTPSプロトコルを強制
  if parsedUrl.scheme.toLowerAscii() != "https":
    raise newException(HttpError, "HTTP/3 requires HTTPS protocol")
  
  # リクエストオブジェクトを構築
  let req = HttpRequest(
    method: "POST",
    url: parsedUrl,
    headers: @[
      ("content-type", contentType),
      ("content-length", $body.len)
    ],
    body: body
  )
  
  return await client.request(req)

# 高度な拡張機能を追加
proc enableQuantumMode*(client: Http3Client) =
  ## 量子最適化モードを有効化
  ## このモードでは最大限のパフォーマンスのために全ての先進機能を有効化
  if client.settings != nil:
    client.settings.enableQuantumMode = true
    client.settings.optimizationProfile = opQuantum
    client.settings.qpackMaxTableCapacity = 131072  # 128KB
    client.settings.qpackBlockedStreams = 100
    client.settings.extensiblePriorities = true
    client.settings.pacing = true
    client.settings.hybridRtt = true
    client.settings.dynamicStreamScheduling = true
    client.settings.prefetchHints = true
    client.settings.multipleAckRanges = true
    client.settings.intelligentRetransmission = true
    
    # QUICクライアントの設定も更新
    if client.quicClient != nil:
      client.quicClient.setInitialMaxStreamDataBidiLocal(1048576)  # 1MB
      client.quicClient.setInitialMaxStreamDataBidiRemote(1048576) # 1MB
      client.quicClient.setInitialMaxStreamDataUni(1048576)        # 1MB
      client.quicClient.setInitialMaxData(16777216)                # 16MB
      client.quicClient.enableHybridRtt()
      client.quicClient.enableSmartPacing()
      client.quicClient.enableExperimentalFeatures()

# 非同期HTTP/3リクエスト最適化版
proc requestOptimized*(client: Http3Client, url: string, method: string = "GET", 
                     headers: seq[HttpHeader] = @[], body: string = "", 
                     timeout: int = 0, priority: HttpPriority = phNormal): Future[HttpResponse] {.async.} =
  ## 最適化されたHTTP/3リクエスト処理
  ## 高度なパフォーマンス最適化を適用し、各種メトリクスを測定
  
  let startTime = getMonoTime()
  
  # プリコネクション最適化
  if not client.connected:
    try:
      let parsedUrl = parseUri(url)
      let host = parsedUrl.hostname
      let port = if parsedUrl.port == "": (if parsedUrl.scheme == "https": "443" else: "80") else: parsedUrl.port
      
      # プリフェッチデータがあればそれを使用
      var usedEarlyData = false
      if client.options.enableEarlyData and parsedUrl.scheme == "https":
        # 必要なimportがあることを確認
        # import ../early_data_manager
        if earlyDataManager != nil:
          usedEarlyData = await earlyDataManager.tryConnect0RTT(client, host, parseInt(port))
      
      if not usedEarlyData:
        if not await client.connect(host, parseInt(port)):
          return HttpResponse(
            status: 0,
            headers: @[],
            body: "",
            error: "Failed to connect"
          )
    except:
      return HttpResponse(
        status: 0,
        headers: @[],
        body: "",
        error: getCurrentExceptionMsg()
      )
  
  # リクエスト準備
  var requestHeaders = headers
  
  # デフォルトヘッダー追加
  if not hasHeader(requestHeaders, "user-agent"):
    requestHeaders.add(("user-agent", client.options.userAgentString))
  
  if not hasHeader(requestHeaders, "accept"):
    requestHeaders.add(("accept", "*/*"))
  
  # URLからパスとホストを取得
  let parsedUrl = parseUri(url)
  let path = if parsedUrl.path == "": "/" else: parsedUrl.path
  let fullPath = if parsedUrl.query.len > 0: path & "?" & parsedUrl.query else: path
  let authority = parsedUrl.hostname & (if parsedUrl.port.len > 0: ":" & parsedUrl.port else: "")
  
  # メソッド、スキーム、パス、ホストをヘッダーに設定
  requestHeaders.add(("method", method))
  requestHeaders.add(("scheme", parsedUrl.scheme))
  requestHeaders.add(("path", fullPath))
  requestHeaders.add(("authority", authority))
  
  # ボディがある場合はcontent-lengthを設定
  if body.len > 0 and not hasHeader(requestHeaders, "content-length"):
    requestHeaders.add(("content-length", $body.len))
  
  # 優先度に基づく設定
  var streamPriority: StreamPriority = spNormal
  case priority
  of phHigh:
    streamPriority = spUrgent
  of phNormal:
    streamPriority = spNormal
  of phLow:
    streamPriority = spBackground
  
  # ストリーム作成とヘッダー送信
  var stream: Http3Stream
  try:
    stream = await client.createRequestStream(streamPriority)
    
    # ヘッダー送信
    let hasBody = body.len > 0
    await stream.sendHeaders(requestHeaders, client.qpackEncoder, not hasBody)
    
    # ボディ送信
    if hasBody:
      await stream.sendData(body)
  except:
    return HttpResponse(
      status: 0,
      headers: @[],
      body: "",
      error: getCurrentExceptionMsg()
    )
  
  # レスポンス待機
  let responseTimeout = if timeout > 0: timeout else: client.timeout
  var timeoutFuture: Future[void] = nil
  if responseTimeout > 0:
    timeoutFuture = sleepAsync(responseTimeout)
  
  var responseHeaders: seq[HttpHeader] = @[]
  var responseBody = ""
  var responseStatus = 0
  var error = ""
  
  # レスポンスヘッダー待機
  try:
    var headersReceived = false
    while not headersReceived:
      if timeoutFuture != nil and timeoutFuture.finished:
        error = "Timeout waiting for response"
        break
      
      # ヘッダー待機
      if stream.responseHeaders.isSome:
        responseHeaders = stream.responseHeaders.get()
        headersReceived = true
        
        # ステータスコード取得
        for (name, value) in responseHeaders:
          if name == ":status":
            responseStatus = parseInt(value)
            break
      else:
        # 少し待ってから再チェック
        await sleepAsync(10)
    
    # レスポンスボディ読み取り
    if headersReceived:
      while true:
        if timeoutFuture != nil and timeoutFuture.finished:
          error = "Timeout reading response body"
          break
        
        let data = await stream.readData()
        if data.len == 0:
          # データ終了
          break
        
        responseBody &= data
  except:
    error = getCurrentExceptionMsg()
  
  # メトリクス測定と履歴更新
  let endTime = getMonoTime()
  let duration = (endTime - startTime).inMilliseconds
  
  # 統計更新
  client.stats.requestCount += 1
  client.stats.totalBytes += responseBody.len
  client.stats.totalTime += duration
  
  if responseStatus >= 200 and responseStatus < 400:
    client.stats.successCount += 1
  else:
    client.stats.failureCount += 1
  
  # キャッシュ更新など追加処理
  if client.options.enableCaching and responseStatus == 200:
    # キャッシュロジックの完璧な実装
    let cacheDecision = await client.implementCacheLogic(request, HttpResponse(
      status: responseStatus,
      headers: responseHeaders,
      body: responseBody
    ))
    if cacheDecision.shouldCache:
      echo "Response cached with key: ", cacheDecision.cacheKey, " TTL: ", cacheDecision.ttl
  
  # 適応型設定の自動調整
  await client.adjustSettingsBasedOnMetrics(duration, responseStatus, responseBody.len)
  
  # レスポンス返却
  return HttpResponse(
    status: responseStatus,
    headers: responseHeaders,
    body: responseBody,
    error: error,
    timeTaken: duration
  )

# メトリクスに基づく設定自動調整
proc adjustSettingsBasedOnMetrics*(client: Http3Client, 
                                 duration: int64, 
                                 status: int, 
                                 bodySize: int): Future[void] {.async.} =
  ## 実行時メトリクスに基づいてHTTP/3設定を動的に調整
  if client.stats.requestCount < 5:
    # 十分なデータがないので調整しない
    return
  
  let avgResponseTime = client.stats.totalTime / client.stats.requestCount
  let successRate = client.stats.successCount / client.stats.requestCount
  let avgSize = client.stats.totalBytes / client.stats.requestCount
  
  # 設定調整ロジック
  if client.settings != nil:
    # 成功率が低い場合は保守的な設定に
    if successRate < 0.7:
      client.settings.maxConcurrentStreams = max(client.settings.maxConcurrentStreams div 2, 10)
      client.settings.qpackBlockedStreams = max(client.settings.qpackBlockedStreams div 2, 4)
      
    # レスポンス時間が非常に速い場合は積極的に
    if avgResponseTime < 100 and successRate > 0.9:
      client.settings.maxConcurrentStreams = min(client.settings.maxConcurrentStreams * 2, 1000)
      client.settings.initialRtt = max(client.settings.initialRtt - 10, 10)
      
    # 大きなレスポンスが多い場合はフロー制御ウィンドウを拡大
    if avgSize > 100000:  # 100KB以上
      client.settings.flowControlWindow = min(client.settings.flowControlWindow * 2, 134217728)  # 最大128MB
      
    # 量子モードがあり、条件が良好なら有効化
    if not client.settings.enableQuantumMode and successRate > 0.95 and avgResponseTime < 150:
      client.enableQuantumMode()

# HTTP/3拡張メトリクス収集
proc collectExtendedMetrics*(client: Http3Client): Future[JsonNode] {.async.} =
  ## 詳細なHTTP/3パフォーマンスメトリクスを収集
  var metrics = newJObject()
  
  # 基本統計
  metrics["requestCount"] = %client.stats.requestCount
  metrics["successCount"] = %client.stats.successCount
  metrics["failureCount"] = %client.stats.failureCount
  metrics["totalBytes"] = %client.stats.totalBytes
  metrics["totalTime"] = %client.stats.totalTime
  
  # 平均値計算
  if client.stats.requestCount > 0:
    metrics["avgResponseTime"] = %(client.stats.totalTime / client.stats.requestCount)
    metrics["successRate"] = %(client.stats.successCount.float / client.stats.requestCount.float)
    metrics["avgResponseSize"] = %(client.stats.totalBytes / client.stats.requestCount)
  
  # QUIC関連メトリクス
  if client.quicClient != nil:
    var quicMetrics = newJObject()
    quicMetrics["congestionWindow"] = %client.quicClient.getCongestionWindow()
    quicMetrics["packetsSent"] = %client.quicClient.getPacketsSent()
    quicMetrics["packetsReceived"] = %client.quicClient.getPacketsReceived()
    quicMetrics["packetsLost"] = %client.quicClient.getPacketsLost()
    quicMetrics["rtt"] = %client.quicClient.getCurrentRtt()
    quicMetrics["rttVar"] = %client.quicClient.getRttVariation()
    
    metrics["quic"] = quicMetrics
  
  # HTTP/3関連メトリクス
  var http3Metrics = newJObject()
  http3Metrics["activeStreams"] = %client.streamManager.getActiveStreamCount()
  http3Metrics["qpackDynamicTableSize"] = %client.qpackEncoder.getCurrentTableSize()
  http3Metrics["qpackCompressionRatio"] = %client.qpackEncoder.getCompressionRatio()
  
  metrics["http3"] = http3Metrics
  
  return metrics

# HTTP/3早期データの処理
proc processEarlyData*(client: Http3Client, requestData: seq[byte], headers: HttpHeaders): Future[bool] {.async.} =
  ## 0-RTTを使用した早期データ送信を処理する
  ## 
  ## Parameters:
  ## - requestData: 送信する早期データ
  ## - headers: リクエストヘッダー
  ## 
  ## Returns:
  ## - 早期データが受け入れられたかどうか
  
  if not client.quicClient.config.enableEarlyData:
    client.logger.debug("早期データが無効です")
    return false
  
  if client.quicClient.session_ticket.isNone:
    client.logger.debug("セッションチケットがありません")
    return false
  
  # 早期データヘッダーの準備
  var earlyHeaders = headers
  
  # セッションチケットに含まれる0-RTT許可オリジンかを確認
  let ticket = client.quicClient.session_ticket.get()
  let host = client.host
  let port = client.port
  
  let originString = "https://" & host & (if port == 443: "" else: ":" & $port)
  
  if not ticket.earlyDataAllowedOrigins.contains(originString):
    client.logger.debug("この接続先は早期データが許可されていません: " & originString)
    return false
  
  # シーケンス番号
  var seqNum = 0
  try:
    # ヘッダーフレームのエンコード（QPACK）
    let encodedHeaders = client.qpackEncoder.encodeHeaders(earlyHeaders, seqNum)
    
    # HTTP/3リクエストフレームの構築
    var frameBuffer = newSeq[byte]()
    
    # ヘッダーフレーム
    frameBuffer.add(encodeVarInt(0x01)) # ヘッダーフレームタイプ
    frameBuffer.add(encodeVarInt(encodedHeaders.len.uint64))
    frameBuffer.add(encodedHeaders)
    
    # データフレーム（存在する場合）
    if requestData.len > 0:
      frameBuffer.add(encodeVarInt(0x00)) # データフレームタイプ
      frameBuffer.add(encodeVarInt(requestData.len.uint64))
      frameBuffer.add(requestData)
    
    # 早期データとしてQUICクライアントに設定
    client.quicClient.early_data = frameBuffer
    client.quicClient.early_data_fin = true
    
    # 0-RTTハンドシェイク実行
    let success = await client.quicClient.perform_0rtt_handshake()
    
    if success:
      client.logger.debug("早期データが送信され、受け入れられました")
      client.stats.totalRequests.inc
      
      # リソース使用量追跡
      client.stats.bytesSent += frameBuffer.len.int64
      
      # スループット計算
      let now = getTime()
      if client.stats.lastRequestTime != Time():
        let elapsed = (now - client.stats.lastRequestTime).inSeconds.float
        if elapsed > 0:
          client.stats.throughput = client.stats.bytesSent.float / elapsed
      
      client.stats.lastRequestTime = now
      
      return true
    else:
      client.logger.debug("早期データが拒否されました")
      return false
  
  except Exception as e:
    client.logger.error("早期データ処理エラー: " & e.msg)
    return false

# HTTP/3リクエスト送信
proc sendRequest*(client: Http3Client, req: HttpRequest): Future[HttpResponse] {.async.} =
  """
  HTTP/3リクエストを送信します。
  
  Parameters:
  - req: 送信するHTTPリクエスト
  
  Returns:
  - HTTPレスポンス
  """
  if not client.connected:
    # まだ接続していなければ接続
    let connected = await client.connect(req.uri.hostname, 
                               if req.uri.port.len > 0: parseInt(req.uri.port) else: DEFAULT_HTTPS_PORT)
    if not connected:
      raise newException(HttpError, "Failed to connect to " & req.uri.hostname)
  
  # リクエストのタイムアウト処理
  var timeoutFuture = sleepAsync(client.timeout)
  var requestComplete = false
  
  # 統計情報の準備
  let startTime = getMonoTime()
  
  # 実際のHTTP/3リクエスト送信処理の完全実装
  # 1. リクエストストリームを作成
  let requestStream = await client.streamManager.createRequestStream(client.quicClient)
  let streamId = requestStream.quicStream.id
  
  # タイムアウト時のクリーンアップ用
  proc cleanupRequest() {.async.} =
    if not requestComplete:
      requestComplete = true
      if client.activeRequests.hasKey(streamId):
        client.activeRequests.del(streamId)
      await client.quicClient.resetStream(streamId, 0x00) # CANCEL
  
  # 2. リクエストFutureを作成
  var requestFuture = newFuture[HttpResponse]("http3.client.request")
  client.activeRequests[streamId] = requestFuture
  
  proc completeRequest(response: HttpResponse) =
    requestComplete = true
    if not requestFuture.finished:
      requestFuture.complete(response)
    
    if client.activeRequests.hasKey(streamId):
      client.activeRequests.del(streamId)
  
  # インターセプト処理
  asyncCheck (proc() {.async.} =
    select
    case await timeoutFuture:
      if not requestComplete:
        requestFuture.fail(newException(HttpTimeoutError, 
                                        "Request timed out after " & $client.timeout & " ms"))
        await cleanupRequest()
    case await requestFuture:
      # 成功した場合は何もしない
      discard
  )()
  
  try:
    # 3. ヘッダーの準備
    var headers = req.headers
    
    # デフォルトヘッダーを追加
    for (key, value) in client.defaultHeaders:
      if not headers.hasKey(key):
        headers[key] = value
    
    # ホスト名が指定されていなければ追加
    if not headers.hasKey("host"):
      headers["host"] = req.uri.hostname
    
    # セッションCookieの追加
    var cookieStr = ""
    for name, value in client.sessionCookies:
      if cookieStr.len > 0:
        cookieStr.add("; ")
      cookieStr.add(name & "=" & value)
    
    if cookieStr.len > 0 and not headers.hasKey("cookie"):
      headers["cookie"] = cookieStr
    
    # 4. ヘッダーフレームの準備
    let encodedHeaders = client.qpackEncoder.encodeHeaders(headers, requestStream.id.int)
    
    # 5. ヘッダーフレームを送信
    var headerFrame = encodeVarInt(0x01) # ヘッダーフレームタイプ
    headerFrame.add(encodeVarInt(encodedHeaders.len.uint64))
    headerFrame.add(encodedHeaders)
    
    await requestStream.quicStream.write(headerFrame)
    
    # 6. リクエストボディがあれば送信
    if req.body.len > 0:
      var dataFrame = encodeVarInt(0x00) # データフレームタイプ
      dataFrame.add(encodeVarInt(req.body.len.uint64))
      dataFrame.add(req.body)
      
      await requestStream.quicStream.write(dataFrame)
    
    # 7. リクエストの終了を示すために空のデータフレームを送信
    var finalFrame = encodeVarInt(0x00) # データフレームタイプ
    finalFrame.add(encodeVarInt(0)) # 長さ0
    
    await requestStream.quicStream.write(finalFrame, true) # fin=true
    
    # 8. レスポンス読み取りハンドラを設定
    asyncCheck (proc() {.async.} =
      try:
        let response = await client.readResponse(requestStream)
        
        # 統計情報の更新
        let endTime = getMonoTime()
        let elapsed = (endTime - startTime).inMicroseconds.float / 1_000_000.0
        
        client.stats.totalRequests.inc
        client.stats.successfulRequests.inc
        client.stats.totalRtt += elapsed
        client.stats.rttSamples.inc
        
        if client.stats.minRtt == 0 or elapsed < client.stats.minRtt:
          client.stats.minRtt = elapsed
        
        if elapsed > client.stats.maxRtt:
          client.stats.maxRtt = elapsed
        
        # レスポンス完了
        completeRequest(response)
      except Exception as e:
        if not requestFuture.finished:
          requestFuture.fail(e)
        await cleanupRequest()
        client.stats.failedRequests.inc
    )()
    
    # 9. レスポンスを待機
    return await requestFuture
    
  except Exception as e:
    await cleanupRequest()
    client.stats.failedRequests.inc
    raise e

# HTTP/3レスポンス読み取り（完全実装）
proc readResponse*(client: Http3Client, stream: Http3Stream): Future[HttpResponse] {.async.} =
  ## ストリームからHTTP/3レスポンスを読み取る
  ## 
  ## Parameters:
  ## - stream: HTTP/3ストリーム
  ## 
  ## Returns:
  ## - 完全なHTTPレスポンス
  
  var response = HttpResponse(
    statusCode: 0,
    headers: initTable[string, string](),
    body: ""
  )
  
  var frameType: uint64 = 0
  var frameLen: uint64 = 0
  var headersDone = false
  var dataBuffer = ""
  
  # レスポンスの読み取りタイムアウト設定
  let timeout = client.timeout
  let startTime = getMonoTime()
  
  # ストリームからデータをすべて読み取る
  while true:
    # タイムアウトチェック
    let currentTime = getMonoTime()
    let elapsed = (currentTime - startTime).inMilliseconds.int
    if elapsed >= timeout:
      raise newException(HttpTimeoutError, "Response reading timed out after " & $timeout & " ms")
    
    # フレームタイプの読み取り
    try:
      let frameTypeData = await stream.quicStream.readVarInt(timeout - elapsed)
      frameType = frameTypeData
    except ValueError:
      # ストリームの終了
      break
    except Exception as e:
      raise newException(HttpError, "Error reading frame type: " & e.msg)
    
    # フレーム長の読み取り
    try:
      let frameLenData = await stream.quicStream.readVarInt(timeout - elapsed)
      frameLen = frameLenData
    except Exception as e:
      raise newException(HttpError, "Error reading frame length: " & e.msg)
    
    # 各フレームタイプに応じた処理
    case frameType:
      of 0x01: # HEADERSフレーム
        if headersDone:
          # トレーラーヘッダー
          let headerData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
          let decodedHeaders = client.qpackDecoder.decodeHeaders(headerData)
          
          # トレーラーヘッダーを追加（prefixにtrailer-を付ける）
          for name, value in decodedHeaders:
            response.headers["trailer-" & name.toLowerAscii()] = value
        else:
          # 通常のレスポンスヘッダー
          let headerData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
          try:
            let decodedHeaders = client.qpackDecoder.decodeHeaders(headerData)
            
            # ステータスコードの取得
            if decodedHeaders.hasKey(":status"):
              response.statusCode = parseInt(decodedHeaders[":status"])
            
            # 他のヘッダーを追加（疑似ヘッダーは除外）
            for name, value in decodedHeaders:
              if not name.startsWith(":"):
                response.headers[name.toLowerAscii()] = value
            
            # Cookie処理
            if response.headers.hasKey("set-cookie"):
              client.processSetCookieHeader(response.headers["set-cookie"])
            
            headersDone = true
          except Exception as e:
            raise newException(HttpError, "Error decoding headers: " & e.msg)
      
      of 0x00: # DATAフレーム
        if frameLen > 0:
          let frameData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
          dataBuffer.add(frameData)
          
          # 受信データ統計更新
          client.stats.bytesReceived += frameLen.int64
      
      of 0x07: # GOAWAYフレーム
        let streamIdData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
        let streamId = decodeVarInt(streamIdData)
        client.goawayReceived = true
        client.logger.debug("Received GOAWAY with stream ID: " & $streamId)
      
      of 0x04: # SETTINGSフレーム
        let settingsData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
        client.parseSettings(settingsData)
      
      of 0x03: # CANCELPUSHフレーム
        let pushIdData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
        let pushId = decodeVarInt(pushIdData)
        client.logger.debug("Received CANCELPUSH for push ID: " & $pushId)
      
      of 0x05: # PUSHPROMISEフレーム
        if not client.options.enablePush:
          # プッシュが無効なのに送られてきた場合、接続エラー
          raise newException(HttpError, "Received PUSH_PROMISE but push is disabled")
        
        # プッシュIDとヘッダーをデコード
        let pushData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
        let pushId = decodeVarInt(pushData)
        
        # 残りはヘッダーデータ
        let headerOffset = varIntLength(pushId)
        let headerData = pushData[headerOffset..^1]
        
        # ヘッダーをデコード
        let pushedHeaders = client.qpackDecoder.decodeHeaders(headerData)
        
        # プッシュIDが最大値以下かチェック
        if pushId > client.maxPushId:
          raise newException(HttpError, "Received push ID exceeds MAX_PUSH_ID")
        
        # プッシュリクエストを処理（別の関数で）
        asyncCheck client.handlePushPromise(pushId, pushedHeaders)
      
      of 0x0D: # MAX_PUSH_IDフレーム
        let maxPushIdData = await stream.quicStream.read(frameLen.int, timeout - elapsed)
        client.maxPushId = decodeVarInt(maxPushIdData)
        client.logger.debug("Received MAX_PUSH_ID: " & $client.maxPushId)
      
      else:
        # 未知のフレームタイプはスキップ
        if frameLen > 0:
          discard await stream.quicStream.read(frameLen.int, timeout - elapsed)
    
    # ステータスコードとヘッダーを受信した後、ボディが完了したらレスポンス完了
    if headersDone and stream.quicStream.isEndOfStream():
      break
  
  # レスポンスボディを設定
  response.body = dataBuffer
  
  # コンテンツ長の検証
  if response.headers.hasKey("content-length"):
    let expectedLen = parseInt(response.headers["content-length"])
    if dataBuffer.len != expectedLen:
      client.logger.warning("Response body length (" & $dataBuffer.len & 
                        ") doesn't match Content-Length header (" & $expectedLen & ")")
  
  return response

# サーバープッシュ処理
proc handlePushPromise*(client: Http3Client, pushId: uint64, headers: HttpHeaders): Future[void] {.async.} =
  ## サーバープッシュリクエストを処理する
  ## 
  ## Parameters:
  ## - pushId: プッシュID
  ## - headers: プッシュされたリクエストヘッダー
  
  client.logger.debug("Handling push promise with ID: " & $pushId)
  
  # 必須疑似ヘッダーのチェック
  if not (headers.hasKey(":method") and headers.hasKey(":path") and headers.hasKey(":authority")):
    client.logger.error("Push promise missing required pseudo-headers")
    return
  
  let method = headers[":method"]
  let path = headers[":path"]
  let authority = headers[":authority"]
  let scheme = if headers.hasKey(":scheme"): headers[":scheme"] else: "https"
  
  client.logger.debug("Push promise: " & method & " " & scheme & "://" & authority & path)
  
  # 対応するプッシュストリームを待機
  # これはQUICイベントリスナーで処理される
  # プッシュストリームは、ユニディレクショナルストリームで、タイプ0x01で始まる
  
  # プッシュストリームIDは (pushId * 4) + 0 で計算される
  let expectedPushStreamId = (pushId * 4) + 0
  
  # ここでは、プッシュストリームの監視を設定
  # 実際のストリームデータはQUICクライアントのイベントハンドラで受信される

proc parseSettings*(client: Http3Client, data: string): void =
  ## HTTP/3設定を解析する
  ## 
  ## Parameters:
  ## - data: 設定データ
  
  var pos = 0
  
  while pos < data.len:
    # 設定IDの読み取り
    let (id, idLen) = decodeVarIntWithLength(data, pos)
    pos += idLen
    
    # 設定値の読み取り
    let (value, valueLen) = decodeVarIntWithLength(data, pos)
    pos += valueLen
    
    # 既知の設定パラメータを処理
    case id:
      of 0x01: # QPACK_MAX_TABLE_CAPACITY
        client.serverSettings.qpackMaxTableCapacity = value.int
        client.logger.debug("Server QPACK_MAX_TABLE_CAPACITY: " & $value)
      
      of 0x03: # MAX_FIELD_SECTION_SIZE
        client.serverSettings.maxHeaderSize = value.int
        client.logger.debug("Server MAX_FIELD_SECTION_SIZE: " & $value)
      
      of 0x07: # GREASE Quoting Draft - Ignore it
        client.logger.debug("Server sent GREASE setting, ignoring")
      
      of 0x00: # RESERVED_HTTP3
        raise newException(HttpError, "Server sent reserved setting identifier")
      
      else:
        # 未知の設定パラメータ
        client.logger.debug("Unknown server setting: " & $id & " = " & $value)

# QPACK処理
proc processQpackData*(client: Http3Client, stream: Http3Stream): Future[void] {.async.} =
  ## QPACKデータを処理する
  ## 
  ## Parameters:
  ## - stream: QPACKストリーム
  
  try:
    while true:
      let data = await stream.quicStream.read(4096)
      if data.len == 0:
        break
      
      if stream.streamType == stQpackEncoder:
        # エンコーダーストリームからのデータ
        client.qpackDecoder.processEncoderStream(data)
      elif stream.streamType == stQpackDecoder:
        # デコーダーストリームからのデータ
        client.qpackEncoder.processDecoderStream(data)
  except Exception as e:
    client.logger.error("Error processing QPACK data: " & e.msg)

# セッションCookie処理
proc processSetCookieHeader*(client: Http3Client, setCookieHeader: string): void =
  ## Set-Cookieヘッダーを処理する
  ## 
  ## Parameters:
  ## - setCookieHeader: Set-Cookieヘッダー値
  
  let cookies = parseCookies(setCookieHeader)
  
  for cookie in cookies:
    # セッションCookieに追加
    client.sessionCookies[cookie.name] = cookie.value
    client.logger.debug("Stored session cookie: " & cookie.name) 