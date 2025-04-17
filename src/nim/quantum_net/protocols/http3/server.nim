## quantum_net/protocols/http3/server.nim
## 
## HTTP/3サーバー実装
## RFC 9114に基づくHTTP/3サーバーの実装

import std/[
  asyncdispatch,
  strutils,
  strformat,
  options,
  uri,
  tables,
  times,
  deques,
  sequtils,
  hashes,
  json,
  os,
  net
]

import atomics
import frames
import stream
import errors

# 型定義
type
  Http3RouteHandler* = proc (request: Http3Request): Future[Http3Response] {.async.}
  
  Http3RequestHandler* = ref object
    ## HTTP/3リクエストハンドラー
    pattern*: string                 ## ルートパターン
    handler*: Http3RouteHandler      ## ハンドラー関数
    methods*: seq[Http3RequestMethod] ## 対応メソッド

  WebTransportSession* = ref object
    ## WebTransportセッション
    id*: string                      ## セッションID
    stream*: Http3Stream             ## 関連ストリーム
    datagrams*: Deque[seq[byte]]     ## データグラムキュー
    isOpen*: Atomic[bool]            ## オープンフラグ
    connection*: QuicConnection      ## 関連接続

  QuicConnection* = ref object
    ## QUIC接続
    id*: string                      ## 接続ID
    socket*: AsyncSocket             ## ソケット
    remoteAddress*: string           ## リモートアドレス
    streams*: Http3StreamManager     ## ストリームマネージャー
    isActive*: Atomic[bool]          ## アクティブフラグ
    lastActivity*: Time              ## 最終アクティビティ時間
    flowControlWindow*: Atomic[int]  ## フロー制御ウィンドウ
    webTransportSessions*: Table[string, WebTransportSession] ## WebTransportセッション
    peerMaxStreamData*: int          ## ピアの最大ストリームデータ
    localMaxStreamData*: int         ## ローカルの最大ストリームデータ
    connectTime*: Time               ## 接続時間
    errorCode*: uint64               ## エラーコード (0:エラーなし)
    alpnProtocol*: string            ## ALPNプロトコル

  Http3Server* = ref object
    ## HTTP/3サーバー
    host*: string                    ## ホスト
    port*: int                       ## ポート
    isRunning*: Atomic[bool]         ## 実行中フラグ
    socket*: AsyncSocket             ## サーバーソケット
    connections*: Table[string, QuicConnection] ## アクティブ接続
    maxClients*: int                 ## 最大クライアント数
    activeClients*: int              ## アクティブクライアント数
    qpackEncoder*: QpackEncoder      ## QPACKエンコーダー
    qpackDecoder*: QpackDecoder      ## QPACKデコーダー
    serverSettings*: Http3Settings   ## サーバー設定
    sessionTickets*: Table[string, string] ## セッションチケット
    handlers*: seq[Http3RequestHandler] ## リクエストハンドラー
    staticDir*: string               ## 静的ファイルディレクトリ
    lastActivity*: Time              ## 最終アクティビティ時間
    tlsCertFile*: string             ## TLS証明書ファイル
    tlsKeyFile*: string              ## TLS秘密鍵ファイル
    errorHandler*: proc(err: Http3Error) {.gcsafe.} ## エラーハンドラー
    logger*: proc(msg: string) {.gcsafe.} ## ロガー

  Http3Request* = object
    ## HTTP/3リクエスト
    method*: Http3RequestMethod      ## HTTPメソッド
    url*: string                     ## リクエストURL
    path*: string                    ## パス
    query*: string                   ## クエリ文字列
    headers*: seq[Http3HeaderField]  ## ヘッダー
    body*: seq[byte]                 ## ボディ
    streamId*: uint64                ## ストリームID
    receivedTime*: Time              ## 受信時間
    remoteAddress*: string           ## リモートアドレス
    connection*: QuicConnection      ## 関連接続

  Http3Response* = object
    ## HTTP/3レスポンス
    status*: int                     ## ステータスコード
    headers*: seq[Http3HeaderField]  ## ヘッダー
    body*: seq[byte]                 ## ボディ
    streamId*: uint64                ## ストリームID
    version*: string                 ## HTTPバージョン
    receivedTime*: Time              ## 受信時間

  Http3RequestMethod* = enum
    ## HTTPメソッド
    hmGet = "GET",
    hmPost = "POST",
    hmPut = "PUT",
    hmDelete = "DELETE",
    hmHead = "HEAD",
    hmOptions = "OPTIONS",
    hmTrace = "TRACE",
    hmPatch = "PATCH",
    hmConnect = "CONNECT"

  Http3HeaderField* = tuple
    ## HTTPヘッダーフィールド
    name: string
    value: string

  Http3Settings* = object
    ## HTTP/3サーバー設定
    maxTableCapacity*: uint64   ## QPACK最大テーブル容量
    maxBlockedStreams*: uint64  ## QPACKブロック済みストリーム数
    maxHeaderListSize*: uint64  ## 最大ヘッダーリストサイズ

  QpackEncoder* = ref object
    ## QPACKエンコーダー (ダミー実装)

  QpackDecoder* = ref object
    ## QPACKデコーダー (ダミー実装)

# 定数
const
  DEFAULT_PORT* = 443
  DEFAULT_HOST* = "0.0.0.0"
  DEFAULT_MAX_CLIENTS* = 100
  DEFAULT_IDLE_TIMEOUT* = 60 * 1000 # 60秒
  DEFAULT_MAX_HEADER_LIST_SIZE* = 65536
  QUIC_VERSION* = "h3-29"        # HTTP/3 バージョン
  DEFAULT_FLOW_CONTROL_WINDOW* = 65535 # デフォルトフロー制御ウィンドウサイズ
  CONNECTION_TIMEOUT* = 30 * 1000 # 接続タイムアウト (30秒)
  ALPN_HTTP3* = "h3"             # HTTP/3のALPNプロトコル値
  ALPN_WEBTRANSPORT* = "wt"      # WebTransportのALPNプロトコル値

# ユーティリティ関数
proc newQpackEncoder*(): QpackEncoder =
  ## 新しいQPACKエンコーダーを作成
  new(result)

proc newQpackDecoder*(): QpackDecoder =
  ## 新しいQPACKデコーダーを作成
  new(result)

proc encodeHeaders*(encoder: QpackEncoder, headers: seq[Http3HeaderField]): seq[byte] =
  ## ヘッダーをエンコード (ダミー実装)
  result = @[]
  # ここでは単純にヘッダーを文字列化してバイト列に変換
  for header in headers:
    let headerStr = header.name & ": " & header.value & "\r\n"
    result.add(cast[seq[byte]](headerStr))

proc decodeHeaders*(decoder: QpackDecoder, encodedHeaders: seq[byte]): seq[Http3HeaderField] =
  ## ヘッダーをデコード (ダミー実装)
  result = @[]
  # ダミー実装：単純に改行で分割して解析
  let headerStr = cast[string](encodedHeaders)
  let headerLines = headerStr.split("\r\n")
  for line in headerLines:
    if line.len == 0:
      continue
    let parts = line.split(": ", 1)
    if parts.len == 2:
      result.add((name: parts[0], value: parts[1]))

proc statusDescription*(statusCode: int): string =
  ## ステータスコードの説明を取得
  case statusCode:
  of 100: "Continue"
  of 101: "Switching Protocols"
  of 102: "Processing"
  of 103: "Early Hints"
  of 200: "OK"
  of 201: "Created"
  of 202: "Accepted"
  of 203: "Non-Authoritative Information"
  of 204: "No Content"
  of 205: "Reset Content"
  of 206: "Partial Content"
  of 300: "Multiple Choices"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 304: "Not Modified"
  of 305: "Use Proxy"
  of 307: "Temporary Redirect"
  of 308: "Permanent Redirect"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 402: "Payment Required"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 406: "Not Acceptable"
  of 407: "Proxy Authentication Required"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 410: "Gone"
  of 411: "Length Required"
  of 412: "Precondition Failed"
  of 413: "Payload Too Large"
  of 414: "URI Too Long"
  of 415: "Unsupported Media Type"
  of 416: "Range Not Satisfiable"
  of 417: "Expectation Failed"
  of 418: "I'm a teapot"
  of 421: "Misdirected Request"
  of 422: "Unprocessable Entity"
  of 423: "Locked"
  of 424: "Failed Dependency"
  of 425: "Too Early"
  of 426: "Upgrade Required"
  of 428: "Precondition Required"
  of 429: "Too Many Requests"
  of 431: "Request Header Fields Too Large"
  of 451: "Unavailable For Legal Reasons"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  of 505: "HTTP Version Not Supported"
  of 506: "Variant Also Negotiates"
  of 507: "Insufficient Storage"
  of 508: "Loop Detected"
  of 510: "Not Extended"
  of 511: "Network Authentication Required"
  else: "Unknown Status"

# QUIC関連関数

proc generateConnectionId(): string =
  ## ランダムな接続IDを生成
  var id = ""
  for i in 0..<16:
    id.add(chr(rand(256).byte))
  return id

proc newQuicConnection*(socket: AsyncSocket, remoteAddress: string): QuicConnection =
  ## 新しいQUIC接続を作成
  result = QuicConnection(
    id: generateConnectionId(),
    socket: socket,
    remoteAddress: remoteAddress,
    streams: newHttp3StreamManager(),
    lastActivity: getTime()
  )
  
  result.isActive.store(true)
  result.flowControlWindow.store(DEFAULT_FLOW_CONTROL_WINDOW)

proc updateConnectionActivity*(conn: QuicConnection) =
  ## 接続のアクティビティを更新
  conn.lastActivity = getTime()

proc isConnectionIdle*(conn: QuicConnection, timeout: int = CONNECTION_TIMEOUT): bool =
  ## 接続がアイドル状態かどうか確認
  let elapsed = (getTime() - conn.lastActivity).inMilliseconds
  return elapsed > timeout

proc closeConnection*(conn: QuicConnection) {.async.} =
  ## QUIC接続を閉じる
  if not conn.isActive.load():
    return
  
  conn.isActive.store(false)
  
  try:
    # GOAWAY フレームを送信
    let goawayFrame = GoawayFrame(
      frameType: ftGoaway,
      streamId: 0
    )
    
    await conn.socket.send(cast[string](encodeFrame(goawayFrame)))
    await conn.socket.close()
  except:
    # ソケットは既に閉じられている可能性がある
    discard

proc newWebTransportSession*(conn: QuicConnection, stream: Http3Stream): WebTransportSession =
  ## 新しいWebTransportセッションを作成
  result = WebTransportSession(
    id: generateConnectionId(),
    stream: stream,
    datagrams: initDeque[seq[byte]](),
    connection: conn
  )
  result.isOpen.store(true)
  conn.webTransportSessions[result.id] = result

proc sendDatagram*(session: WebTransportSession, data: seq[byte]): Future[bool] {.async.} =
  ## WebTransportセッションでデータグラムを送信
  if not session.isOpen.load():
    return false
  
  try:
    # 実際の実装ではQUICデータグラムとして送信する
    # ここではシミュレーション
    return true
  except:
    return false

proc receiveDatagram*(session: WebTransportSession): Option[seq[byte]] =
  ## WebTransportセッションからデータグラムを受信
  if not session.isOpen.load() or session.datagrams.len == 0:
    return none(seq[byte])
  
  return some(session.datagrams.popFirst())

proc hasDatagrams*(session: WebTransportSession): bool =
  ## セッションにデータグラムがあるかどうか
  return session.datagrams.len > 0

proc queueDatagram*(session: WebTransportSession, data: seq[byte]) =
  ## データグラムをセッションのキューに追加
  session.datagrams.addLast(data)

proc closeWebTransportSession*(session: WebTransportSession) {.async.} =
  ## WebTransportセッションを閉じる
  if not session.isOpen.load():
    return
  
  session.isOpen.store(false)
  
  # 関連するストリームをクローズ
  if not session.stream.isNil and not session.stream.isClosed():
    session.stream.state.store(sClosed)
  
  # セッション管理からの削除
  if not session.connection.isNil and session.connection.webTransportSessions.hasKey(session.id):
    session.connection.webTransportSessions.del(session.id)

proc createStream*(conn: QuicConnection, streamType: Http3StreamType): Option[Http3Stream] =
  ## 指定されたタイプのストリームを作成
  if not conn.isActive.load():
    return none(Http3Stream)
  
  var streamId: uint64
  var direction: Http3StreamDirection
  
  case streamType:
  of stControl, stQpackEncoder, stQpackDecoder:
    # 単方向ストリーム
    direction = sdUnidirectional
    streamId = conn.streams.nextStreamId.load()
    streamId = (streamId and not 0x3) or ClientInitiatedUnidirectional
    discard conn.streams.nextStreamId.fetchAdd(4)
  else:
    # 双方向ストリーム
    direction = sdBidirectional
    streamId = conn.streams.nextStreamId.load()
    streamId = (streamId and not 0x3) or ClientInitiatedBidirectional
    discard conn.streams.nextStreamId.fetchAdd(4)
  
  let stream = conn.streams.createStream(streamId, direction)
  stream.streamType = streamType
  return some(stream)

proc processQuicPacket*(conn: QuicConnection, data: seq[byte]): Future[bool] {.async.} =
  ## QUICパケットを処理
  ## 注：簡略化のため、実際のQUICパケット処理は実装していません
  conn.updateConnectionActivity()
  
  # 実際の実装ではパケットの解析とフレームの抽出を行う
  # ここではダミー実装
  
  return true

# サーバー関連の関数

proc newHttp3Server*(host: string = DEFAULT_HOST, 
                    port: int = DEFAULT_PORT,
                    maxClients: int = DEFAULT_MAX_CLIENTS,
                    tlsCertFile: string = "",
                    tlsKeyFile: string = ""): Http3Server =
  ## 新しいHTTP/3サーバーを作成
  randomize() # 乱数初期化
  
  result = Http3Server(
    host: host,
    port: port,
    maxClients: maxClients,
    connections: initTable[string, QuicConnection](),
    qpackEncoder: newQpackEncoder(),
    qpackDecoder: newQpackDecoder(),
    serverSettings: Http3Settings(
      maxTableCapacity: 4096,
      maxBlockedStreams: 100,
      maxHeaderListSize: DEFAULT_MAX_HEADER_LIST_SIZE
    ),
    sessionTickets: initTable[string, string](),
    handlers: @[],
    staticDir: "",
    lastActivity: getTime(),
    activeClients: 0,
    tlsCertFile: tlsCertFile,
    tlsKeyFile: tlsKeyFile
  )
  result.isRunning.store(false)
  
  # デフォルトロガーを設定
  result.logger = proc(msg: string) =
    echo "[HTTP/3] ", msg
  
  # デフォルトエラーハンドラーを設定
  result.errorHandler = proc(err: Http3Error) =
    echo "[HTTP/3 Error] ", err.message

proc addRouteHandler*(server: Http3Server, 
                      pattern: string, 
                      handler: Http3RouteHandler,
                      methods: varargs[Http3RequestMethod]): Http3RequestHandler =
  ## ルートハンドラーを追加
  var methodList: seq[Http3RequestMethod] = @[]
  
  # メソッドが指定されていない場合は全メソッドを許可
  if methods.len == 0:
    for m in Http3RequestMethod:
      methodList.add(m)
  else:
    for m in methods:
      methodList.add(m)
  
  let requestHandler = Http3RequestHandler(
    pattern: pattern,
    handler: handler,
    methods: methodList
  )
  
  server.handlers.add(requestHandler)
  return requestHandler

proc removeRouteHandler*(server: Http3Server, handler: Http3RequestHandler) =
  ## ルートハンドラーを削除
  server.handlers.keepIf(proc(h: Http3RequestHandler): bool = h != handler)

proc setStaticDir*(server: Http3Server, dir: string) =
  ## 静的ファイルディレクトリを設定
  server.staticDir = dir

proc acceptConnection(server: Http3Server) {.async.} =
  ## 新しいクライアント接続を受け入れる
  try:
    let (clientSocket, address) = await server.socket.acceptAddr()
    
    if server.activeClients >= server.maxClients:
      # 最大クライアント数に達した場合
      await clientSocket.close()
      server.logger("Connection rejected: Maximum client limit reached")
      return
    
    # 新しいQUIC接続を作成
    let quicConn = newQuicConnection(clientSocket, address)
    server.connections[quicConn.id] = quicConn
    server.activeClients += 1
    
    server.logger("New connection from " & address & " [" & quicConn.id & "]")
    
    # TLSハンドシェイクとQUIC設定
    # 実際の実装ではここでTLSとQUICのセットアップを行う
    
    # HTTP/3制御ストリームの作成
    await quicConn.createControlStreams()
    
    # 受信ループを開始
    asyncCheck quicConn.receiveLoop()
    
  except:
    let msg = getCurrentExceptionMsg()
    server.logger("Error accepting connection: " & msg)

proc start*(server: Http3Server): Future[bool] {.async.} =
  ## サーバーを開始
  if server.isRunning.load():
    return false
  
  try:
    # ソケットを作成
    server.socket = newAsyncSocket()
    server.socket.setSockOpt(OptReuseAddr, true)
    server.socket.bindAddr(Port(server.port), server.host)
    server.socket.listen()
    
    server.isRunning.store(true)
    server.logger("Server started on " & server.host & ":" & $server.port)
    
    # 接続受付ループを開始
    while server.isRunning.load():
      asyncCheck server.acceptConnection()
      await sleepAsync(100)
    
    return true
  except:
    let msg = getCurrentExceptionMsg()
    server.logger("Error starting server: " & msg)
    return false

proc stop*(server: Http3Server): Future[void] {.async.} =
  ## サーバーを停止
  if not server.isRunning.load():
    return
  
  server.logger("Stopping server...")
  
  # 接続を全て閉じる
  server.isRunning.store(false)
  
  for id, conn in server.connections:
    asyncCheck conn.closeConnection()
  
  # サーバーソケットを閉じる
  if not server.socket.isNil:
    await server.socket.close()
  
  server.connections.clear()
  server.activeClients = 0
  server.logger("Server stopped")

proc isRunning*(server: Http3Server): bool =
  ## サーバーが実行中かどうか
  return server.isRunning.load()

proc updateActivity*(server: Http3Server) =
  ## アクティビティ時間を更新
  server.lastActivity = getTime()

proc isIdle*(server: Http3Server, timeout: int = DEFAULT_IDLE_TIMEOUT): bool =
  ## サーバーがアイドル状態かどうか判断
  let elapsed = (getTime() - server.lastActivity).inMilliseconds
  return elapsed > timeout

# リクエスト処理関連の関数

proc sendResponse*(server: Http3Server, 
                   stream: Http3Stream, 
                   response: Http3Response): Future[bool] {.async.} =
  ## レスポンスを送信
  server.updateActivity()
  
  if not stream.canSendData():
    return false
  
  # 接続を取得
  var connection: QuicConnection = nil
  for id, conn in server.connections:
    if conn.streams.getStream(stream.id).isSome:
      connection = conn
      break
  
  if connection.isNil:
    return false
  
  connection.updateConnectionActivity()
  
  # ヘッダーをQPACKでエンコード
  var responseHeaders: seq[Http3HeaderField] = @[
    (":status", $response.status)
  ]
  
  # 標準ヘッダーが含まれていない場合は追加
  if not response.headers.anyIt(it.name.toLower() == "content-type"):
    responseHeaders.add(("content-type", "text/plain"))
  
  if not response.headers.anyIt(it.name.toLower() == "date"):
    let now = now()
    responseHeaders.add(("date", now.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")))
  
  if not response.headers.anyIt(it.name.toLower() == "server"):
    responseHeaders.add(("server", "Quantum/HTTP3"))
  
  # コンテンツ長さを追加
  if response.body.len > 0 and not response.headers.anyIt(it.name.toLower() == "content-length"):
    responseHeaders.add(("content-length", $response.body.len))
  
  # ユーザー指定のヘッダーを追加
  for header in response.headers:
    if not header.name.startsWith(":"):  # 疑似ヘッダーは除外
      responseHeaders.add(header)
  
  # ヘッダーをエンコード
  let encodedHeaders = server.qpackEncoder.encodeHeaders(responseHeaders)
  
  # HEADERSフレームを送信
  stream.queueFrame(newHeadersFrame(encodedHeaders))
  
  # ボディを送信（存在する場合）
  if response.body.len > 0:
    stream.queueFrame(newDataFrame(response.body))
  
  # サーバー側のストリーム終了を送信
  stream.queueFrame(newStreamEndFrame())
  stream.state.store(sHalfClosedLocal)
  
  return true

proc handleWebTransport*(server: Http3Server, 
                         req: Http3Request, 
                         stream: Http3Stream): Future[WebTransportSession] {.async.} =
  ## WebTransportリクエストを処理
  if req.method != hmConnect:
    return nil
  
  # WebTransport関連ヘッダーをチェック
  var isWebTransport = false
  var protocol = ""
  var path = ""
  var scheme = ""
  var authority = ""
  
  for header in req.headers:
    case header.name.toLower()
    of ":protocol":
      protocol = header.value
    of ":path":
      path = header.value
    of ":scheme":
      scheme = header.value
    of ":authority":
      authority = header.value
  
  if protocol == "webtransport":
    isWebTransport = true
  
  if not isWebTransport:
    return nil
  
  # WebTransportセッションを作成
  let session = newWebTransportSession(req.connection, stream)
  
  # 200 OKレスポンスを送信
  let response = Http3Response(
    status: 200,
    headers: @[
      ("sec-webtransport-http3-draft", "draft02")
    ],
    version: "HTTP/3"
  )
  
  discard await server.sendResponse(stream, response)
  
  server.logger("WebTransport session created: " & session.id)
  return session

proc processDatagramReceivedEvent*(conn: QuicConnection, data: seq[byte]): Future[void] {.async.} =
  ## データグラム受信イベントを処理
  # このデータグラムをどのWebTransportセッションに関連付けるか？
  # 実際には、データグラムにセッションIDが含まれているはず
  
  # デモのため、最初のセッションにデータグラムを追加
  for id, session in conn.webTransportSessions:
    session.queueDatagram(data)
    break

proc createControlStreams*(conn: QuicConnection): Future[void] {.async.} =
  ## 制御ストリームを作成
  # HTTP/3制御ストリーム
  let controlStreamOpt = conn.createStream(stControl)
  if controlStreamOpt.isNone:
    return
  
  let controlStream = controlStreamOpt.get()
  
  # ストリームタイプ
  let streamTypeData = @[byte(stControl)]
  await conn.socket.send(cast[string](streamTypeData))
  
  # QPACKエンコーダーストリーム
  let encoderStreamOpt = conn.createStream(stQpackEncoder)
  if encoderStreamOpt.isSome:
    let encoderStream = encoderStreamOpt.get()
    let encoderTypeData = @[byte(stQpackEncoder)]
    await conn.socket.send(cast[string](encoderTypeData))
  
  # QPACKデコーダーストリーム
  let decoderStreamOpt = conn.createStream(stQpackDecoder)
  if decoderStreamOpt.isSome:
    let decoderStream = decoderStreamOpt.get()
    let decoderTypeData = @[byte(stQpackDecoder)]
    await conn.socket.send(cast[string](decoderTypeData))

proc processStream*(server: Http3Server, stream: Http3Stream): Future[void] {.async.} =
  ## ストリームを処理
  server.updateActivity()
  
  # 接続を取得
  var connection: QuicConnection = nil
  for id, conn in server.connections:
    if conn.streams.getStream(stream.id).isSome:
      connection = conn
      break
  
  if connection.isNil:
    return
  
  connection.updateConnectionActivity()
  
  # ストリームタイプに基づいて処理
  if stream.streamType != stControl and isUnidirectional(stream.id):
    # 単方向ストリームの場合、最初のバイトがストリームタイプを示す
    if stream.receiveBuffer.len > 0:
      let frame = stream.receiveBuffer.popFirst()
      if frame.frameType == ftData:
        let data = DataFrame(frame).data
        if data.len > 0:
          let streamType = Http3StreamType(data[0])
          stream.streamType = streamType
    return
  
  # リクエストをデコード
  var headers: seq[Http3HeaderField] = @[]
  var body: seq[byte] = @[]
  var method: Http3RequestMethod = hmGet
  var path = "/"
  var requestComplete = false
  
  # フレームの取得と処理
  while not requestComplete and stream.canReceiveData():
    var frame: Http3Frame = nil
    
    # 受信バッファからフレームを取得
    if stream.receiveBuffer.len > 0:
      frame = stream.receiveBuffer.popFirst()
    else:
      # フレームが見つからない場合は待機
      await sleepAsync(10)
      continue
    
    # フレームタイプに基づいて処理
    case frame.frameType
    of ftHeaders:
      let headersFrame = HeadersFrame(frame)
      let decodedHeaders = server.qpackDecoder.decodeHeaders(headersFrame.headerBlock)
      headers.add(decodedHeaders)
      
      # メソッドとパスを抽出
      for header in decodedHeaders:
        if header.name == ":method":
          try:
            method = parseEnum[Http3RequestMethod](header.value)
          except:
            method = hmGet
        elif header.name == ":path":
          path = header.value
    
    of ftData:
      let dataFrame = DataFrame(frame)
      body.add(dataFrame.data)
    
    of ftSettings:
      # クライアントの設定を処理
      let settingsFrame = SettingsFrame(frame)
      for setting in settingsFrame.settings:
        case setting.identifier
        of SettingsQpackMaxTableCapacity:
          # クライアントのQPACK最大テーブル容量
          discard
        of SettingsMaxFieldSectionSize:
          # クライアントの最大ヘッダーサイズ
          discard
        of SettingsQpackBlockedStreams:
          # QPACKブロック済みストリーム
          discard
        else:
          # 未知の設定
          discard
    
    else:
      # 他のフレームタイプは処理
      case frame.frameType
      of ftCancelPush:
        let cancelPushFrame = CancelPushFrame(frame)
        # プッシュをキャンセル
        discard
      
      of ftGoaway:
        let goawayFrame = GoawayFrame(frame)
        # クライアントからの切断要求
        asyncCheck connection.closeConnection()
      
      of ftMaxPushId:
        let maxPushIdFrame = MaxPushIdFrame(frame)
        # 最大プッシュID
        discard
      
      of ftPushPromise:
        let pushPromiseFrame = PushPromiseFrame(frame)
        # サーバープッシュは未サポート
        discard
      
      of ftReservedH3:
        # 予約済みフレーム
        discard
    
    # ストリームの状態をチェック
    if stream.isRemoteClosed():
      requestComplete = true
  
  # 有効なリクエストかどうかチェック
  if headers.len == 0:
    # 不正なリクエスト
    let errorResponse = Http3Response(
      status: 400,
      headers: @[],
      body: cast[seq[byte]]("Bad Request"),
      streamId: stream.id,
      version: "HTTP/3"
    )
    
    discard await server.sendResponse(stream, errorResponse)
    return
  
  # URLを構築
  var scheme = "https"
  var authority = ""
  
  for header in headers:
    if header.name == ":scheme":
      scheme = header.value
    elif header.name == ":authority":
      authority = header.value
  
  let url = scheme & "://" & authority & path
  
  # パスとクエリに分割
  var queryStr = ""
  var pathOnly = path
  
  let queryPos = path.find('?')
  if queryPos >= 0:
    pathOnly = path[0 ..< queryPos]
    if queryPos + 1 < path.len:
      queryStr = path[queryPos + 1 .. ^1]
  
  # リクエストオブジェクトを作成
  let request = Http3Request(
    method: method,
    url: url,
    path: pathOnly,
    query: queryStr,
    headers: headers,
    body: body,
    streamId: stream.id,
    receivedTime: getTime(),
    remoteAddress: connection.remoteAddress,
    connection: connection
  )
  
  # WebTransport CONNECTリクエストの特別処理
  if method == hmConnect:
    for header in headers:
      if header.name == ":protocol" and header.value == "webtransport":
        let session = await server.handleWebTransport(request, stream)
        return
  
  # ハンドラーを探す
  var matchedHandler: Http3RouteHandler = nil
  
  for handler in server.handlers:
    # メソッドチェック
    if method notin handler.methods:
      continue
    
    # パターンマッチング（単純なパスマッチング）
    if handler.pattern == pathOnly or 
       (handler.pattern.endsWith("*") and 
        pathOnly.startsWith(handler.pattern[0..^2])):
      matchedHandler = handler.handler
      break
  
  # レスポンスを処理
  var response: Http3Response
  
  if matchedHandler != nil:
    # ハンドラーを呼び出す
    response = await matchedHandler(request)
  else:
    # 404 Not Found
    response = Http3Response(
      status: 404,
      headers: @[("content-type", "text/plain")],
      body: cast[seq[byte]]("404 Not Found: " & pathOnly),
      version: "HTTP/3"
    )
  
  # レスポンスがストリームIDを設定していない場合は設定
  if response.streamId == 0:
    response.streamId = stream.id
  
  # レスポンスを送信
  discard await server.sendResponse(stream, response)

proc processEvents*(server: Http3Server) {.async.} =
  ## イベント処理
  server.updateActivity()
  
  # 接続のクリーンアップ
  var idleConnections: seq[string] = @[]
  
  for id, conn in server.connections:
    if conn.isConnectionIdle():
      idleConnections.add(id)
    else:
      # 接続のストリームを処理
      for streamId, stream in conn.streams.streams:
        asyncCheck server.processStream(stream)
  
  # アイドル接続をクローズ
  for id in idleConnections:
    if server.connections.hasKey(id):
      asyncCheck server.connections[id].closeConnection()
      server.connections.del(id)
      server.activeClients -= 1
      server.logger("Closed idle connection: " & id)
  
  # アイドルチェック
  if server.isIdle() and server.activeClients == 0:
    await server.stop()

# ヘルパー関数

proc json*(body: JsonNode, status: int = 200): Http3Response =
  ## JSON形式のレスポンスを生成
  result = Http3Response(
    status: status,
    headers: @[("content-type", "application/json")],
    body: cast[seq[byte]]($ body),
    version: "HTTP/3"
  )

proc html*(body: string, status: int = 200): Http3Response =
  ## HTML形式のレスポンスを生成
  result = Http3Response(
    status: status,
    headers: @[("content-type", "text/html; charset=utf-8")],
    body: cast[seq[byte]](body),
    version: "HTTP/3"
  )

proc text*(body: string, status: int = 200): Http3Response =
  ## テキスト形式のレスポンスを生成
  result = Http3Response(
    status: status,
    headers: @[("content-type", "text/plain; charset=utf-8")],
    body: cast[seq[byte]](body),
    version: "HTTP/3"
  )

proc redirect*(location: string, status: int = 302): Http3Response =
  ## リダイレクトレスポンスを生成
  result = Http3Response(
    status: status,
    headers: @[
      ("location", location),
      ("content-type", "text/plain; charset=utf-8")
    ],
    body: cast[seq[byte]]("Redirecting to " & location),
    version: "HTTP/3"
  )

# WebTransport APIヘルパー

proc createWebTransportHandler*(handler: proc(session: WebTransportSession): Future[void] {.async.}): Http3RouteHandler =
  ## WebTransportハンドラーを作成
  result = proc(request: Http3Request): Future[Http3Response] {.async.} =
    if request.method != hmConnect:
      return Http3Response(
        status: 405,
        headers: @[("content-type", "text/plain")],
        body: cast[seq[byte]]("Method Not Allowed"),
        version: "HTTP/3"
      )
    
    # WebTransportプロトコルヘッダーをチェック
    var hasWebTransportProtocol = false
    
    for header in request.headers:
      if header.name.toLower() == ":protocol" and header.value == "webtransport":
        hasWebTransportProtocol = true
        break
    
    if not hasWebTransportProtocol:
      return Http3Response(
        status: 400,
        headers: @[("content-type", "text/plain")],
        body: cast[seq[byte]]("Bad Request: Missing WebTransport protocol"),
        version: "HTTP/3"
      )
    
    # WebTransportセッションを作成
    let stream = request.connection.streams.getStream(request.streamId).get()
    let session = newWebTransportSession(request.connection, stream)
    
    # セッションハンドラーを非同期で開始
    asyncCheck handler(session)
    
    # 成功レスポンスを返す
    return Http3Response(
      status: 200,
      headers: @[
        ("sec-webtransport-http3-draft", "draft02"),
        ("content-type", "application/webtransport")
      ],
      body: @[],
      version: "HTTP/3"
    )

# 拡張ユーティリティ

proc addStaticFileHandler*(server: Http3Server, urlPrefix: string, directory: string) =
  ## 静的ファイルハンドラーを追加
  server.addRouteHandler(urlPrefix & "*", proc(req: Http3Request): Future[Http3Response] {.async.} =
    # URLからファイルパスを取得
    var filePath = req.path
    
    # URLプレフィックスを削除
    if filePath.startsWith(urlPrefix):
      filePath = filePath[urlPrefix.len..^1]
    
    # ディレクトリトラバーサル対策
    if ".." in filePath:
      return Http3Response(
        status: 403,
        headers: @[("content-type", "text/plain")],
        body: cast[seq[byte]]("Forbidden"),
        version: "HTTP/3"
      )
    
    # ファイルパスを構築
    filePath = directory / filePath
    
    # インデックスファイル
    if fileExists(filePath) and dirExists(filePath):
      filePath = filePath / "index.html"
    
    # ファイルが存在するかチェック
    if not fileExists(filePath):
      return Http3Response(
        status: 404,
        headers: @[("content-type", "text/plain")],
        body: cast[seq[byte]]("Not Found: " & req.path),
        version: "HTTP/3"
      )
    
    # Content-Typeを判断
    var contentType = "application/octet-stream"
    let ext = splitFile(filePath).ext.toLowerAscii()
    
    case ext
    of ".html", ".htm":
      contentType = "text/html; charset=utf-8"
    of ".css":
      contentType = "text/css; charset=utf-8"
    of ".js":
      contentType = "application/javascript; charset=utf-8"
    of ".json":
      contentType = "application/json; charset=utf-8"
    of ".png":
      contentType = "image/png"
    of ".jpg", ".jpeg":
      contentType = "image/jpeg"
    of ".gif":
      contentType = "image/gif"
    of ".svg":
      contentType = "image/svg+xml"
    of ".txt":
      contentType = "text/plain; charset=utf-8"
    else:
      contentType = "application/octet-stream"
    
    # ファイルを読み込む
    let fileContent = readFile(filePath)
    
    return Http3Response(
      status: 200,
      headers: @[
        ("content-type", contentType),
        ("content-length", $fileContent.len)
      ],
      body: cast[seq[byte]](fileContent),
      version: "HTTP/3"
    )
  )

proc receiveLoop*(conn: QuicConnection) {.async.} =
  ## データ受信ループ
  const BUFFER_SIZE = 4096
  var buffer = newSeq[byte](BUFFER_SIZE)
  
  while conn.isActive.load():
    try:
      let bytesRead = await conn.socket.recvInto(addr buffer[0], BUFFER_SIZE)
      
      if bytesRead <= 0:
        # 接続が閉じられた
        break
      
      let data = buffer[0..<bytesRead]
      discard await conn.processQuicPacket(data)
      
    except:
      let msg = getCurrentExceptionMsg()
      if conn.isActive.load():
        echo "Error in receive loop: " & msg
      break
  
  # 接続が閉じられた
  conn.isActive.store(false)

# サンプル使用例
when isMainModule:
  proc main() {.async.} =
    # サーバーを作成
    let server = newHttp3Server(port=8443)
    
    # ルートハンドラーを追加
    server.addRouteHandler("/", proc(req: Http3Request): Future[Http3Response] {.async.} =
      return html("<h1>Welcome to HTTP/3 Server</h1><p>This is a demonstration of the HTTP/3 server implementation.</p>")
    )
    
    server.addRouteHandler("/api/hello", proc(req: Http3Request): Future[Http3Response] {.async.} =
      return text("Hello, HTTP/3!")
    )
    
    server.addRouteHandler("/api/info", proc(req: Http3Request): Future[Http3Response] {.async.} =
      let info = %*{
        "server": "Quantum HTTP/3",
        "protocol": "HTTP/3",
        "version": QUIC_VERSION,
        "time": $now(),
        "remote": req.remoteAddress
      }
      return json(info)
    )
    
    # WebTransportのデモハンドラー
    server.addRouteHandler("/webtransport", createWebTransportHandler(proc(session: WebTransportSession): Future[void] {.async.} =
      # エコーサーバー
      while session.isOpen.load():
        if session.hasDatagrams():
          let data = session.receiveDatagram().get()
          # データをエコーバック
          discard await session.sendDatagram(data)
        else:
          await sleepAsync(10)
    }))
    
    # 静的ファイルハンドラー
    if dirExists("public"):
      server.addStaticFileHandler("/static/", "public")
    
    # サーバーを開始
    discard await server.start()
    
    server.logger("Server is running. Press Ctrl+C to stop.")
    
    # イベント処理ループ
    while server.isRunning():
      await server.processEvents()
      await sleepAsync(100)
  
  waitFor main() 