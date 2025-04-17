# HTTP/3 Protocol Implementation
#
# RFC 9114に準拠したHTTP/3プロトコル実装

import std/[asyncdispatch, options, tables, strutils, uri, strformat, times, deques]
import std/[hashes, random, algorithm, sequtils, sets]
import ../protocols/quic/quic_client
import ../../compression/qpack

# HTTP/3 関連の定数
const
  # フレームタイプ
  FrameData* = 0x0
  FrameHeaders* = 0x1
  FrameCancelPush* = 0x3
  FrameSettings* = 0x4
  FramePushPromise* = 0x5
  FrameGoaway* = 0x7
  FrameMaxPushId* = 0xD
  
  # 設定識別子
  SettingsQpackMaxTableCapacity* = 0x1
  SettingsMaxFieldSectionSize* = 0x6
  SettingsQpackBlockedStreams* = 0x7
  
  # ストリームタイプ
  StreamControl* = 0
  StreamPush* = 1
  StreamQpackEncoder* = 2
  StreamQpackDecoder* = 3
  
  # エラーコード
  ErrorNoError* = 0x100
  ErrorGeneralProtocolError* = 0x101
  ErrorInternalError* = 0x102
  ErrorStreamCreationError* = 0x103
  ErrorClosedCriticalStream* = 0x104
  ErrorFrameUnexpected* = 0x105
  ErrorFrameError* = 0x106
  ErrorExcessiveLoad* = 0x107
  ErrorIdError* = 0x108
  ErrorSettingsError* = 0x109
  ErrorMissingSettings* = 0x10A
  ErrorRequestRejected* = 0x10B
  ErrorRequestCancelled* = 0x10C
  ErrorRequestIncomplete* = 0x10D
  ErrorMessageError* = 0x10E
  ErrorConnectError* = 0x10F
  ErrorVersionFallback* = 0x110

# 型定義
type
  Http3Error* = object of CatchableError
    code*: uint64
  
  Http3FrameHeader* = object
    typ*: uint64
    length*: uint64
  
  Http3Frame* = object
    header*: Http3FrameHeader
    payload*: string
  
  Http3Settings* = object
    qpackMaxTableCapacity*: uint64
    maxFieldSectionSize*: uint64
    qpackBlockedStreams*: uint64
  
  Http3StreamState* = enum
    Idle, Open, HalfClosed, Closed
  
  Http3Stream* = ref object
    id*: uint64
    state*: Http3StreamState
    headers*: seq[tuple[name: string, value: string]]
    data*: string
    error*: uint64
    completionFuture*: Future[void]
  
  Http3Client* = ref object
    quicClient*: QuicClient
    host*: string
    port*: string
    
    # 接続管理
    connected*: bool
    maxPushId*: uint64
    goawayReceived*: bool
    
    # ストリーム管理
    streams*: Table[uint64, Http3Stream]
    controlStreamId*: uint64
    qpackEncoderStreamId*: uint64
    qpackDecoderStreamId*: uint64
    
    # QPACK
    encoder*: QpackEncoder
    decoder*: QpackDecoder
    
    # 設定
    localSettings*: Http3Settings
    remoteSettings*: Http3Settings
    
    # イベント処理
    closed*: bool
    closeFuture*: Future[void]

  Http3Header* = tuple[name: string, value: string]
  
  Http3Response* = object
    streamId*: uint64
    statusCode*: int
    headers*: seq[Http3Header]
    data*: string
    error*: uint64
    streamEnded*: bool
  
  Http3Request* = object
    url*: Uri
    method*: string
    headers*: seq[Http3Header]
    body*: string

# 可変長整数のエンコードとデコード
proc encodeVarInt(value: uint64): string =
  if value < 64:
    # 6ビットで表現可能
    result = newString(1)
    result[0] = char(value)
  elif value < 16384:
    # 14ビットで表現可能
    result = newString(2)
    result[0] = char((value shr 8) or 0x40)
    result[1] = char(value and 0xFF)
  elif value < 1073741824:
    # 30ビットで表現可能
    result = newString(4)
    result[0] = char((value shr 24) or 0x80)
    result[1] = char((value shr 16) and 0xFF)
    result[2] = char((value shr 8) and 0xFF)
    result[3] = char(value and 0xFF)
  else:
    # 62ビットで表現可能
    result = newString(8)
    result[0] = char((value shr 56) or 0xC0)
    result[1] = char((value shr 48) and 0xFF)
    result[2] = char((value shr 40) and 0xFF)
    result[3] = char((value shr 32) and 0xFF)
    result[4] = char((value shr 24) and 0xFF)
    result[5] = char((value shr 16) and 0xFF)
    result[6] = char((value shr 8) and 0xFF)
    result[7] = char(value and 0xFF)

proc decodeVarInt(data: string, offset: var int): uint64 =
  if offset >= data.len:
    raise newException(Http3Error, "Invalid varint: buffer too short")
  
  let firstByte = uint8(data[offset])
  let prefix = firstByte and 0xC0  # 上位2ビットを取得
  var length = 0
  var mask = 0'u64
  
  case prefix
  of 0x00:  # 00xxxxxx
    length = 1
    mask = 0x3F
  of 0x40:  # 01xxxxxx
    length = 2
    mask = 0x3F
  of 0x80:  # 10xxxxxx
    length = 4
    mask = 0x3F
  of 0xC0:  # 11xxxxxx
    length = 8
    mask = 0x3F
  else:
    raise newException(Http3Error, "Invalid varint prefix")
  
  if offset + length > data.len:
    raise newException(Http3Error, "Invalid varint: buffer too short")
  
  # 最初のバイトから値を抽出
  result = uint64(firstByte and uint8(mask))
  
  # 残りのバイトを処理
  for i in 1 ..< length:
    result = (result shl 8) or uint64(data[offset + i])
  
  # オフセットを更新
  offset += length

# HTTP/3フレーム処理
proc parseFrameHeader(data: string, offset: var int): Http3FrameHeader =
  let typ = decodeVarInt(data, offset)
  let length = decodeVarInt(data, offset)
  
  result = Http3FrameHeader(typ: typ, length: length)

proc parseFrame(data: string, offset: var int): Http3Frame =
  let header = parseFrameHeader(data, offset)
  
  if offset + header.length.int > data.len:
    raise newException(Http3Error, "Frame payload too short")
  
  let payload = data[offset ..< offset + header.length.int]
  offset += header.length.int
  
  result = Http3Frame(header: header, payload: payload)

proc serializeFrame(frame: Http3Frame): string =
  let typEncoded = encodeVarInt(frame.header.typ)
  let lengthEncoded = encodeVarInt(frame.header.length)
  
  result = typEncoded & lengthEncoded & frame.payload

# Http3Settings 操作
proc newHttp3Settings*(): Http3Settings =
  result = Http3Settings(
    qpackMaxTableCapacity: 0,  # デフォルトでは動的テーブルなし
    maxFieldSectionSize: 65536,  # 64KB
    qpackBlockedStreams: 0  # デフォルトではブロッキングなし
  )

proc parseSettingsPayload(payload: string): Http3Settings =
  result = newHttp3Settings()
  
  var offset = 0
  while offset < payload.len:
    let identifier = decodeVarInt(payload, offset)
    let value = decodeVarInt(payload, offset)
    
    case identifier
    of SettingsQpackMaxTableCapacity:
      result.qpackMaxTableCapacity = value
    of SettingsMaxFieldSectionSize:
      result.maxFieldSectionSize = value
    of SettingsQpackBlockedStreams:
      result.qpackBlockedStreams = value
    else:
      # 未知の設定は無視
      discard

proc serializeSettingsPayload(settings: Http3Settings): string =
  var payload = ""
  
  # QPACK設定（動的テーブルを使う場合のみ）
  if settings.qpackMaxTableCapacity > 0:
    payload &= encodeVarInt(SettingsQpackMaxTableCapacity)
    payload &= encodeVarInt(settings.qpackMaxTableCapacity)
  
  # 最大フィールドセクションサイズ
  payload &= encodeVarInt(SettingsMaxFieldSectionSize)
  payload &= encodeVarInt(settings.maxFieldSectionSize)
  
  # QPACKブロック済みストリーム数（動的テーブルを使う場合のみ）
  if settings.qpackBlockedStreams > 0:
    payload &= encodeVarInt(SettingsQpackBlockedStreams)
    payload &= encodeVarInt(settings.qpackBlockedStreams)
  
  return payload

# Http3Stream 操作
proc newHttp3Stream*(id: uint64): Http3Stream =
  result = Http3Stream(
    id: id,
    state: Idle,
    headers: @[],
    data: "",
    error: 0,
    completionFuture: newFuture[void]("http3.stream")
  )

# Http3Client 実装
proc handleStreamError(client: Http3Client, streamId: uint64, errorCode: uint64) =
  # ストリームをリセット
  if streamId in client.streams:
    let stream = client.streams[streamId]
    stream.error = errorCode
    stream.state = Closed
    
    # 完了フューチャーを失敗としてマーク
    if not stream.completionFuture.finished:
      stream.completionFuture.fail(newException(Http3Error, "Stream error: " & $errorCode))
    
    # QUICストリームをリセット
    asyncCheck client.quicClient.resetStream(streamId, errorCode)

proc handleConnectionError(client: Http3Client, errorCode: uint64) =
  # すべてのストリームをクローズ
  for id, stream in client.streams:
    stream.state = Closed
    stream.error = errorCode
    
    # 完了フューチャーを失敗としてマーク
    if not stream.completionFuture.finished:
      stream.completionFuture.fail(newException(Http3Error, "Connection error: " & $errorCode))
  
  # GOAWAY フレームを送信
  var goawayPayload = encodeVarInt(client.streams.len.uint64)
  
  var frame = Http3Frame(
    header: Http3FrameHeader(
      typ: FrameGoaway,
      length: goawayPayload.len.uint64
    ),
    payload: goawayPayload
  )
  
  let frameData = serializeFrame(frame)
  asyncCheck client.quicClient.sendOnStream(client.controlStreamId, frameData)
  
  # 接続をクローズ状態にマーク
  client.goawayReceived = true
  
  # QUIC接続をクローズ
  asyncCheck client.quicClient.close(errorCode, "HTTP/3 error")
  
  # 接続クローズフューチャーを完了としてマーク
  if not client.closeFuture.finished:
    client.closeFuture.complete()

proc processHeadersFrame(client: Http3Client, streamId: uint64, payload: string) =
  if streamId notin client.streams:
    client.streams[streamId] = newHttp3Stream(streamId)
  
  let stream = client.streams[streamId]
  
  # ヘッダーブロックを処理
  try:
    let headers = client.decoder.decodeHeaders(payload)
    stream.headers.add(headers)
  except:
    handleStreamError(client, streamId, ErrorGeneralProtocolError)

proc processDataFrame(client: Http3Client, streamId: uint64, payload: string) =
  if streamId notin client.streams:
    handleStreamError(client, streamId, ErrorFrameUnexpected)
    return
  
  let stream = client.streams[streamId]
  
  # データを追加
  stream.data.add(payload)

proc processSettingsFrame(client: Http3Client, payload: string) =
  let settings = parseSettingsPayload(payload)
  client.remoteSettings = settings
  
  # QPACKエンコーダのテーブルサイズを更新
  client.encoder.setDynamicTableCapacity(settings.qpackMaxTableCapacity.int)

proc processGoawayFrame(client: Http3Client, payload: string) =
  var offset = 0
  let streamId = decodeVarInt(payload, offset)
  
  # streamId より大きいストリームIDはすべて拒否する
  for id, stream in client.streams:
    if id > streamId and id mod 4 == 0:  # クライアント発行のリクエストストリームのみ
      stream.state = Closed
      stream.error = ErrorRequestRejected
      
      # 完了フューチャーを失敗としてマーク
      if not stream.completionFuture.finished:
        stream.completionFuture.fail(newException(Http3Error, "Stream rejected by server"))
  
  # 接続をクローズ状態にマーク
  client.goawayReceived = true

proc processMaxPushIdFrame(client: Http3Client, payload: string) =
  var offset = 0
  let pushId = decodeVarInt(payload, offset)
  
  # サーバーからの最大プッシュIDを更新
  client.maxPushId = pushId

proc processCancelPushFrame(client: Http3Client, payload: string) =
  # クライアント実装では特に何もする必要はない
  # サーバープッシュのキャンセル通知を受け取っただけ
  discard

proc processPushPromiseFrame(client: Http3Client, streamId: uint64, payload: string) =
  # プッシュIDとヘッダーブロックを解析
  var offset = 0
  let pushId = decodeVarInt(payload, offset)
  let headerBlock = payload[offset .. ^1]
  
  # ヘッダーブロックを処理
  try:
    let headers = client.decoder.decodeHeaders(headerBlock)
    
    # 新しいプッシュストリームIDを生成（pushId から計算）
    let pushStreamId = (pushId * 4) + StreamPush
    
    # プッシュストリームを作成
    if pushStreamId notin client.streams:
      client.streams[pushStreamId] = newHttp3Stream(pushStreamId)
    
    let pushStream = client.streams[pushStreamId]
    pushStream.headers.add(headers)
  except:
    handleStreamError(client, streamId, ErrorGeneralProtocolError)

proc processFrame(client: Http3Client, streamId: uint64, frame: Http3Frame) =
  try:
    case frame.header.typ
    of FrameHeaders:
      processHeadersFrame(client, streamId, frame.payload)
    of FrameData:
      processDataFrame(client, streamId, frame.payload)
    of FrameSettings:
      if streamId != client.controlStreamId:
        handleStreamError(client, streamId, ErrorFrameUnexpected)
      else:
        processSettingsFrame(client, frame.payload)
    of FrameGoaway:
      if streamId != client.controlStreamId:
        handleStreamError(client, streamId, ErrorFrameUnexpected)
      else:
        processGoawayFrame(client, frame.payload)
    of FrameMaxPushId:
      if streamId != client.controlStreamId:
        handleStreamError(client, streamId, ErrorFrameUnexpected)
      else:
        processMaxPushIdFrame(client, frame.payload)
    of FrameCancelPush:
      if streamId != client.controlStreamId:
        handleStreamError(client, streamId, ErrorFrameUnexpected)
      else:
        processCancelPushFrame(client, frame.payload)
    of FramePushPromise:
      processPushPromiseFrame(client, streamId, frame.payload)
    else:
      # 未知のフレームタイプは無視
      discard
  except:
    handleStreamError(client, streamId, ErrorFrameError)

proc eventHandler(client: Http3Client) {.async.} =
  while not client.closed:
    let event = await client.quicClient.waitForEvent()
    
    case event.kind
    of StreamDataReceived:
      let streamId = event.streamId
      let data = event.data
      
      var offset = 0
      
      # ユニディレクショナルストリームの最初のバイトはストリームタイプ
      if streamId mod 4 != 0 and offset == 0:
        let streamType = decodeVarInt(data, offset)
        
        # 新しいユニディレクショナルストリームを処理
        case streamType
        of StreamControl:
          client.controlStreamId = streamId
        of StreamQpackEncoder:
          client.qpackEncoderStreamId = streamId
        of StreamQpackDecoder:
          client.qpackDecoderStreamId = streamId
        else:
          # 未知のストリームタイプは無視
          discard
      
      # フレームを解析して処理
      try:
        while offset < data.len:
          let frame = parseFrame(data, offset)
          await processFrame(client, streamId, frame)
      except:
        handleStreamError(client, streamId, ErrorFrameError)
    
    of StreamFinished:
      let streamId = event.streamId
      
      if streamId in client.streams:
        let stream = client.streams[streamId]
        
        if stream.state == Open:
          stream.state = Closed
          
          # ストリームが完了したことを通知
          if not stream.completionFuture.finished:
            stream.completionFuture.complete()
    
    of ConnectionClosed:
      # 接続がクローズされた
      client.closed = true
      
      # すべてのストリームを失敗としてマーク
      for id, stream in client.streams:
        if not stream.completionFuture.finished:
          stream.completionFuture.fail(newException(Http3Error, "Connection closed"))
      
      # 接続クローズフューチャーを完了としてマーク
      if not client.closeFuture.finished:
        client.closeFuture.complete()
      
      break
    
    else:
      # その他のイベントは無視
      discard

# HTTP/3クライアントの実装
proc newHttp3Client*(host: string, port: string): Future[Http3Client] {.async.} =
  # QUICクライアント作成
  let quicClient = await newQuicClient(host, port, "h3")
  
  var client = Http3Client(
    quicClient: quicClient,
    host: host,
    port: port,
    connected: false,
    maxPushId: 0,
    goawayReceived: false,
    streams: initTable[uint64, Http3Stream](),
    localSettings: newHttp3Settings(),
    remoteSettings: newHttp3Settings(),
    closed: false,
    closeFuture: newFuture[void]("http3.client.close")
  )
  
  # QPACK初期化
  client.encoder = newQpackEncoder(0)  # デフォルトでは動的テーブルなし
  client.decoder = newQpackDecoder(0)  # デフォルトでは動的テーブルなし
  
  # 制御ストリーム作成
  client.controlStreamId = await quicClient.createStream(true)
  
  # ストリームタイプを送信
  await quicClient.sendOnStream(client.controlStreamId, encodeVarInt(StreamControl))
  
  # SETTINGS送信
  let settingsPayload = serializeSettingsPayload(client.localSettings)
  
  var settingsFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: FrameSettings,
      length: settingsPayload.len.uint64
    ),
    payload: settingsPayload
  )
  
  let frameData = serializeFrame(settingsFrame)
  await quicClient.sendOnStream(client.controlStreamId, frameData)
  
  # QPACK制御ストリーム作成
  if client.localSettings.qpackMaxTableCapacity > 0:
    # エンコーダーストリーム
    client.qpackEncoderStreamId = await quicClient.createStream(true)
    await quicClient.sendOnStream(client.qpackEncoderStreamId, encodeVarInt(StreamQpackEncoder))
    
    # デコーダーストリーム
    client.qpackDecoderStreamId = await quicClient.createStream(true)
    await quicClient.sendOnStream(client.qpackDecoderStreamId, encodeVarInt(StreamQpackDecoder))
  
  # イベントハンドラ開始
  asyncCheck eventHandler(client)
  
  client.connected = true
  return client

proc close*(client: Http3Client): Future[void] {.async.} =
  if client.closed:
    return
  
  client.closed = true
  
  # GOAWAY送信
  var goawayPayload = encodeVarInt(0'u64)  # 0をストリームIDとして送信し、すべてのストリームを拒否
  
  var frame = Http3Frame(
    header: Http3FrameHeader(
      typ: FrameGoaway,
      length: goawayPayload.len.uint64
    ),
    payload: goawayPayload
  )
  
  let frameData = serializeFrame(frame)
  
  try:
    await client.quicClient.sendOnStream(client.controlStreamId, frameData)
  except:
    discard
  
  # QUIC接続を閉じる
  await client.quicClient.close(ErrorNoError, "Client closing connection")
  
  # 接続クローズフューチャーを完了としてマーク
  if not client.closeFuture.finished:
    client.closeFuture.complete()

proc sendRequest*(client: Http3Client, request: Http3Request, timeout: int = 30000): Future[Http3Response] {.async.} =
  if client.closed or client.goawayReceived:
    raise newException(Http3Error, "Connection closed")
  
  # リクエストストリーム作成
  let streamId = await client.quicClient.createStream()
  client.streams[streamId] = newHttp3Stream(streamId)
  
  let stream = client.streams[streamId]
  stream.state = Open
  
  # ヘッダー準備
  var requestHeaders = request.headers
  
  # 必須ヘッダー
  let
    scheme = request.url.scheme
    authority = request.url.hostname & (if request.url.port == "": "" else: ":" & request.url.port)
    path = if request.url.path == "": "/" else: request.url.path & (if request.url.query == "": "" else: "?" & request.url.query)
  
  requestHeaders.add((":method", request.method))
  requestHeaders.add((":scheme", scheme))
  requestHeaders.add((":authority", authority))
  requestHeaders.add((":path", path))
  
  # ボディがある場合、Content-Lengthを追加
  if request.body.len > 0:
    var hasContentLength = false
    for header in requestHeaders:
      if header.name.toLowerAscii() == "content-length":
        hasContentLength = true
        break
    
    if not hasContentLength:
      requestHeaders.add(("content-length", $request.body.len))
  
  # HEADERSフレーム送信
  let encodedHeaders = client.encoder.encodeHeaders(requestHeaders)
  
  var headersFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: FrameHeaders,
      length: encodedHeaders.len.uint64
    ),
    payload: encodedHeaders
  )
  
  let headersFrameData = serializeFrame(headersFrame)
  await client.quicClient.sendOnStream(streamId, headersFrameData)
  
  # ボディ送信（ある場合）
  if request.body.len > 0:
    var dataFrame = Http3Frame(
      header: Http3FrameHeader(
        typ: FrameData,
        length: request.body.len.uint64
      ),
      payload: request.body
    )
    
    let dataFrameData = serializeFrame(dataFrame)
    await client.quicClient.sendOnStream(streamId, dataFrameData)
  
  # ストリーム終了マーク
  await client.quicClient.finishStream(streamId)
  
  # レスポンス待機
  let timeoutFuture = sleepAsync(timeout)
  let completionFuture = stream.completionFuture
  
  let firstFuture = await firstCompletedFuture(completionFuture, timeoutFuture)
  
  if firstFuture == timeoutFuture:
    # リクエストタイムアウト
    # ストリームをリセット
    handleStreamError(client, streamId, ErrorRequestCancelled)
    raise newException(Http3Error, "Request timed out")
  
  # レスポンスヘッダーを解析
  var statusCode = 200
  var responseHeaders: seq[Http3Header] = @[]
  
  for header in stream.headers:
    if header.name == ":status":
      try:
        statusCode = parseInt(header.value)
      except:
        statusCode = 200
    elif not header.name.startsWith(":"):
      responseHeaders.add(header)
  
  # HTTP/3レスポンスオブジェクト作成
  let response = Http3Response(
    statusCode: statusCode,
    headers: responseHeaders,
    data: stream.data,
    streamId: streamId,
    error: stream.error,
    streamEnded: stream.state == Closed
  )
  
  return response

# 便利なショートカットメソッド
proc get*(client: Http3Client, url: string, headers: seq[Http3Header] = @[]): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "GET",
    headers: headers,
    body: ""
  )
  
  return await client.sendRequest(request)

proc post*(client: Http3Client, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
          headers: seq[Http3Header] = @[]): Future[Http3Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  let request = Http3Request(
    url: parseUri(url),
    method: "POST",
    headers: requestHeaders,
    body: body
  )
  
  return await client.sendRequest(request)

proc put*(client: Http3Client, url: string, body: string, contentType: string = "application/x-www-form-urlencoded", 
         headers: seq[Http3Header] = @[]): Future[Http3Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  let request = Http3Request(
    url: parseUri(url),
    method: "PUT",
    headers: requestHeaders,
    body: body
  )
  
  return await client.sendRequest(request)

proc delete*(client: Http3Client, url: string, headers: seq[Http3Header] = @[]): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "DELETE",
    headers: headers,
    body: ""
  )
  
  return await client.sendRequest(request)