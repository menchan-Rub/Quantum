## quantum_net/protocols/http3/client.nim
## 
## HTTP/3クライアント
## HTTP/3プロトコルのクライアント実装

import std/asyncdispatch
import std/asyncnet
import std/options
import std/tables
import std/uri
import std/strutils
import std/strformat
import std/times
import atomics

import ../../compression/qpack
import stream
import frames
import errors

type
  Http3RequestMethod* = enum
    ## HTTP/3リクエストメソッド
    hmGet = "GET",
    hmPost = "POST",
    hmPut = "PUT",
    hmDelete = "DELETE",
    hmHead = "HEAD",
    hmOptions = "OPTIONS",
    hmTrace = "TRACE",
    hmConnect = "CONNECT",
    hmPatch = "PATCH"

  Http3HeaderField* = tuple
    ## HTTP/3ヘッダーフィールド
    name: string
    value: string

  Http3Response* = ref object
    ## HTTP/3レスポンス
    status*: int                ## ステータスコード
    headers*: seq[Http3HeaderField] ## ヘッダーフィールド
    body*: seq[byte]            ## レスポンスボディ
    streamId*: uint64           ## ストリームID
    version*: string            ## HTTP バージョン
    receivedTime*: Time         ## 受信時間

  Http3Settings* = ref object
    ## HTTP/3設定
    maxHeaderListSize*: uint64  ## 最大ヘッダーリストサイズ
    maxTableCapacity*: uint64   ## 最大テーブル容量
    blockedStreams*: uint64     ## ブロック済みストリーム数
    pushEnabled*: bool          ## プッシュ有効フラグ

  Http3ConnectionState* = enum
    ## HTTP/3コネクション状態
    csIdle,           ## アイドル状態
    csReserved,       ## 予約済み
    csConnecting,     ## 接続中
    csConnected,      ## 接続済み
    csGoingAway,      ## 切断中
    csClosing,        ## クローズ中
    csClosed,         ## クローズ済み
    csError           ## エラー状態

  Http3Client* = ref object
    ## HTTP/3クライアント
    host*: string                      ## ホスト名
    port*: int                         ## ポート番号
    isSecure*: bool                    ## TLS使用フラグ
    state*: Atomic[Http3ConnectionState] ## コネクション状態
    streams*: Http3StreamManager       ## ストリームマネージャー
    settings*: Http3Settings           ## HTTP/3設定
    qpackEncoder*: QpackEncoder        ## QPACKエンコーダー
    qpackDecoder*: QpackDecoder        ## QPACKデコーダー
    controlStreamId*: uint64           ## 制御ストリームID
    idleTimeout*: int                  ## アイドルタイムアウト（ミリ秒）
    connectTimeout*: int               ## 接続タイムアウト（ミリ秒）
    lastActivity*: Time                ## 最後のアクティビティ時間
    userAgent*: string                 ## ユーザーエージェント
    defaultHeaders*: seq[Http3HeaderField] ## デフォルトヘッダー

# ユーティリティ関数

proc newHttp3Settings*(): Http3Settings =
  ## デフォルトのHTTP/3設定を作成
  result = Http3Settings(
    maxHeaderListSize: 65536,   # 64KB
    maxTableCapacity: 4096,     # 4KB
    blockedStreams: 100,
    pushEnabled: false
  )

proc settingsToParameters*(settings: Http3Settings): seq[SettingParameter] =
  ## HTTP/3設定をパラメータに変換
  result = @[
    (SettingsQpackMaxTableCapacity, settings.maxTableCapacity),
    (SettingsMaxFieldSectionSize, settings.maxHeaderListSize),
    (SettingsQpackBlockedStreams, settings.blockedStreams)
  ]

proc encodeHeaders*(encoder: QpackEncoder, headers: seq[Http3HeaderField]): seq[byte] =
  ## ヘッダーをエンコード
  var headerList: seq[QpackHeaderField] = @[]
  
  for header in headers:
    headerList.add((header.name, header.value))
    
  result = encoder.encodeHeaderFields(headerList)

proc decodeHeaders*(decoder: QpackDecoder, headerBlock: seq[byte]): seq[Http3HeaderField] =
  ## ヘッダーをデコード
  let headerFields = decoder.decodeHeaderFields(headerBlock)
  
  result = @[]
  for field in headerFields:
    result.add((field.name, field.value))

# HTTP/3クライアント実装

proc newHttp3Client*(host: string, port: int = 443, isSecure: bool = true): Http3Client =
  ## 新しいHTTP/3クライアントを作成
  result = Http3Client(
    host: host,
    port: port,
    isSecure: isSecure,
    streams: newHttp3StreamManager(),
    settings: newHttp3Settings(),
    qpackEncoder: newQpackEncoder(),
    qpackDecoder: newQpackDecoder(),
    idleTimeout: 60000,         # 60秒
    connectTimeout: 10000,      # 10秒
    lastActivity: getTime(),
    userAgent: "Quantum Browser/1.0"
  )
  
  result.state.store(csIdle)
  
  # デフォルトヘッダーを設定
  result.defaultHeaders = @[
    ("user-agent", result.userAgent)
  ]

proc isConnected*(client: Http3Client): bool =
  ## クライアントが接続されているかどうか
  let state = client.state.load()
  return state == csConnected

proc isConnecting*(client: Http3Client): bool =
  ## クライアントが接続中かどうか
  let state = client.state.load()
  return state == csConnecting

proc isClosed*(client: Http3Client): bool =
  ## クライアントが閉じているかどうか
  let state = client.state.load()
  return state == csClosed or state == csError

proc connect*(client: Http3Client): Future[bool] {.async.} =
  ## HTTP/3サーバーに接続
  if client.isConnected() or client.isConnecting():
    return true
    
  client.state.store(csConnecting)
  client.lastActivity = getTime()
  
  try:
    # 制御ストリームを作成
    let controlStream = client.streams.createStream(direction = sdUnidirectional)
    controlStream.setStreamType(stControl)
    controlStream.state.store(sOpen)
    client.controlStreamId = controlStream.id
    
    # SETTINGSフレームを送信
    let settingsFrame = newSettingsFrame(settingsToParameters(client.settings))
    controlStream.queueFrame(settingsFrame)
    
    # QPACK エンコーダー/デコーダーストリームを作成
    let encoderStream = client.streams.createStream(direction = sdUnidirectional)
    encoderStream.setStreamType(stQpackEncoder)
    encoderStream.state.store(sOpen)
    
    let decoderStream = client.streams.createStream(direction = sdUnidirectional)
    decoderStream.setStreamType(stQpackDecoder)
    decoderStream.state.store(sOpen)
    
    # 接続完了
    client.state.store(csConnected)
    client.lastActivity = getTime()
    return true
    
  except:
    client.state.store(csError)
    return false

proc close*(client: Http3Client) {.async.} =
  ## HTTP/3コネクションを閉じる
  if client.isClosed():
    return
    
  # GOAWAYフレームを送信
  let controlStreamOption = client.streams.getStream(client.controlStreamId)
  if controlStreamOption.isSome:
    let controlStream = controlStreamOption.get()
    # 最後に受信したストリームID = 0（簡略化のため）
    controlStream.sendGoaway(0)
    
  # すべてのストリームを閉じる
  for id, stream in client.streams.streams:
    stream.closeStream()
    
  client.state.store(csClosed)

proc abort*(client: Http3Client, error: Http3Error) {.async.} =
  ## エラーによりコネクションを終了
  client.state.store(csError)
  
  # すべてのストリームをリセット
  for id, stream in client.streams.streams:
    stream.resetStream(error)
    
  # 非同期でクローズ
  await client.close()

proc updateActivity*(client: Http3Client) {.inline.} =
  ## アクティビティタイマーを更新
  client.lastActivity = getTime()

proc isIdle*(client: Http3Client): bool =
  ## クライアントがアイドル状態かどうか
  if not client.isConnected():
    return false
    
  let elapsed = (getTime() - client.lastActivity).inMilliseconds
  return elapsed > client.idleTimeout.int64

proc prepareHeaders*(client: Http3Client, 
                    url: Uri, 
                    method: Http3RequestMethod, 
                    headers: seq[Http3HeaderField] = @[], 
                    body: seq[byte] = @[]): seq[Http3HeaderField] =
  ## リクエストヘッダーを準備
  result = client.defaultHeaders
  
  # メソッドとパス
  result.add((":method", $method))
  result.add((":scheme", if client.isSecure: "https" else: "http"))
  result.add((":authority", url.hostname))
  
  # パスとクエリ
  var path = url.path
  if path == "":
    path = "/"
  if url.query != "":
    path &= "?" & url.query
  result.add((":path", path))
  
  # ユーザー指定のヘッダーを追加
  for header in headers:
    # 既に同じヘッダーがあれば上書き
    var found = false
    for i in 0..<result.len:
      if result[i].name.toLower() == header.name.toLower():
        result[i] = header
        found = true
        break
    
    if not found:
      result.add(header)
  
  # コンテンツ長さを追加（ボディがある場合）
  if body.len > 0 and not result.anyIt(it.name.toLower() == "content-length"):
    result.add(("content-length", $body.len))

proc createRequestStream*(client: Http3Client): Option[Http3Stream] =
  ## リクエスト用の新しいストリームを作成
  if not client.isConnected():
    return none(Http3Stream)
  
  let stream = client.streams.createStream(direction = sdBidirectional)
  stream.state.store(sIdle)
  return some(stream)

proc waitForResponse*(client: Http3Client, streamId: uint64, timeout: int = 30000): Future[Option[Http3Response]] {.async.} =
  ## レスポンスを待機
  var startTime = getTime()
  
  while true:
    let elapsed = (getTime() - startTime).inMilliseconds
    if elapsed > timeout.int64:
      return none(Http3Response)
    
    let streamOption = client.streams.getStream(streamId)
    if streamOption.isNone:
      return none(Http3Response)
      
    let stream = streamOption.get()
    
    if stream.state.load() == sHalfClosedRemote:
      # レスポンスが完了
      if stream.response.isSome:
        return stream.response
      
    # エラーチェック
    if stream.error.isSome:
      return none(Http3Response)
      
    # 少し待機
    await sleepAsync(10)
    
    # アクティビティを更新
    client.updateActivity()

proc processEvents*(client: Http3Client) {.async.} =
  ## イベント処理
  client.updateActivity()
  
  # すべてのストリームのフレームを処理
  for id, stream in client.streams.streams:
    await stream.processFrames()
    
  # アイドルチェック
  if client.isIdle():
    await client.close()

proc beginRequest*(client: Http3Client, 
                  method: Http3RequestMethod, 
                  url: string, 
                  headers: seq[Http3HeaderField] = @[], 
                  body: seq[byte] = @[]): Future[Option[Http3Response]] {.async.} =
  ## HTTPリクエストを開始
  let parsedUrl = parseUri(url)
  
  # 接続チェック
  if not client.isConnected():
    let connected = await client.connect()
    if not connected:
      return none(Http3Response)
  
  # ヘッダーを準備
  let requestHeaders = client.prepareHeaders(parsedUrl, method, headers, body)
  
  # ストリームを作成
  let streamOption = client.createRequestStream()
  if streamOption.isNone:
    return none(Http3Response)
    
  let stream = streamOption.get()
  stream.state.store(sOpen)
  
  # ヘッダーをエンコード
  let encodedHeaders = encodeHeaders(client.qpackEncoder, requestHeaders)
  
  # HEADERSフレームを送信
  stream.queueFrame(newHeadersFrame(encodedHeaders))
  
  # ボディを送信（存在する場合）
  if body.len > 0:
    stream.queueFrame(newDataFrame(body))
  
  # クライアント側のストリーム終了を送信
  stream.queueFrame(newStreamEndFrame())
  stream.state.store(sHalfClosedLocal)
  
  # イベント処理をトリガー
  asyncCheck client.processEvents()
  
  # レスポンスを待機
  return await client.waitForResponse(stream.id)

proc sendRequest*(client: Http3Client, 
                 method: Http3RequestMethod, 
                 url: string, 
                 headers: seq[Http3HeaderField] = @[], 
                 body: string = ""): Future[Option[Http3Response]] {.async.} =
  ## HTTPリクエストを送信（文字列ボディ）
  var bodyBytes: seq[byte] = @[]
  if body.len > 0:
    bodyBytes = cast[seq[byte]](body)
  
  return await client.beginRequest(method, url, headers, bodyBytes)

# 便利なショートカットメソッド

proc get*(client: Http3Client, url: string, headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## GETリクエストを送信
  return await client.sendRequest(hmGet, url, headers)

proc post*(client: Http3Client, url: string, body: string = "", headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## POSTリクエストを送信
  var finalHeaders = headers
  
  # Content-Typeヘッダーがない場合はデフォルトを設定
  if not finalHeaders.anyIt(it.name.toLower() == "content-type"):
    finalHeaders.add(("content-type", "application/x-www-form-urlencoded"))
    
  return await client.sendRequest(hmPost, url, finalHeaders, body)

proc put*(client: Http3Client, url: string, body: string = "", headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## PUTリクエストを送信
  var finalHeaders = headers
  
  # Content-Typeヘッダーがない場合はデフォルトを設定
  if not finalHeaders.anyIt(it.name.toLower() == "content-type"):
    finalHeaders.add(("content-type", "application/x-www-form-urlencoded"))
    
  return await client.sendRequest(hmPut, url, finalHeaders, body)

proc delete*(client: Http3Client, url: string, headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## DELETEリクエストを送信
  return await client.sendRequest(hmDelete, url, headers)

proc head*(client: Http3Client, url: string, headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## HEADリクエストを送信
  return await client.sendRequest(hmHead, url, headers)

proc patch*(client: Http3Client, url: string, body: string = "", headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## PATCHリクエストを送信
  var finalHeaders = headers
  
  # Content-Typeヘッダーがない場合はデフォルトを設定
  if not finalHeaders.anyIt(it.name.toLower() == "content-type"):
    finalHeaders.add(("content-type", "application/x-www-form-urlencoded"))
    
  return await client.sendRequest(hmPatch, url, finalHeaders, body)

proc options*(client: Http3Client, url: string, headers: seq[Http3HeaderField] = @[]): Future[Option[Http3Response]] {.async.} =
  ## OPTIONSリクエストを送信
  return await client.sendRequest(hmOptions, url, headers)

proc getHeader*(response: Http3Response, name: string): Option[string] =
  ## レスポンスからヘッダーを取得
  for header in response.headers:
    if header.name.toLower() == name.toLower():
      return some(header.value)
  return none(string)

proc bodyString*(response: Http3Response): string =
  ## レスポンスボディを文字列として取得
  if response.body.len == 0:
    return ""
  return cast[string](response.body)

proc contentType*(response: Http3Response): Option[string] =
  ## Content-Typeヘッダーを取得
  return response.getHeader("content-type")

proc contentLength*(response: Http3Response): Option[int] =
  ## Content-Lengthヘッダーを取得
  let cl = response.getHeader("content-length")
  if cl.isSome:
    try:
      return some(parseInt(cl.get))
    except:
      discard
  return none(int)

proc isSuccess*(response: Http3Response): bool =
  ## 成功レスポンスかどうかをチェック (2xx)
  return response.status >= 200 and response.status < 300

proc isRedirect*(response: Http3Response): bool =
  ## リダイレクトレスポンスかどうかをチェック (3xx)
  return response.status >= 300 and response.status < 400

proc isClientError*(response: Http3Response): bool =
  ## クライアントエラーレスポンスかどうかをチェック (4xx)
  return response.status >= 400 and response.status < 500

proc isServerError*(response: Http3Response): bool =
  ## サーバーエラーレスポンスかどうかをチェック (5xx)
  return response.status >= 500 and response.status < 600

proc statusDescription*(response: Http3Response): string =
  ## ステータスコードの説明を取得
  case response.status:
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
  else: "Unknown Status Code"

# HTTP/3クッキー管理

proc getCookies*(response: Http3Response): Table[string, string] =
  ## レスポンスからクッキーを解析
  result = initTable[string, string]()
  
  # Set-Cookieヘッダーを検索
  for header in response.headers:
    if header.name.toLower() == "set-cookie":
      # クッキー文字列を解析
      let cookieValue = header.value
      let mainPart = cookieValue.split(';')[0].strip()
      let kvPair = mainPart.split('=', maxsplit=1)
      
      if kvPair.len == 2:
        let name = kvPair[0].strip()
        let value = kvPair[1].strip()
        result[name] = value

proc getCookieHeader*(cookies: Table[string, string]): string =
  ## クッキーテーブルからCookieヘッダー値を生成
  var cookieParts: seq[string] = @[]
  
  for name, value in cookies:
    cookieParts.add(name & "=" & value)
    
  return cookieParts.join("; ")

# WebトランスポートとHTTP/3拡張
type
  WebTransportSession* = ref object
    ## WebTransport セッション
    client*: Http3Client
    sessionId*: uint64
    isOpen*: bool
    datagrams*: seq[seq[byte]]

proc createWebTransportSession*(client: Http3Client, url: string): Future[Option[WebTransportSession]] {.async.} =
  ## WebTransportセッションを作成
  if not client.isConnected():
    let connected = await client.connect()
    if not connected:
      return none(WebTransportSession)
      
  # 拡張ヘッダーでCONNECTリクエスト
  let headers = @[
    (":method", "CONNECT"),
    (":protocol", "webtransport"),
    (":scheme", if client.isSecure: "https" else: "http"),
    (":path", parseUri(url).path),
    (":authority", parseUri(url).hostname)
  ]
  
  # ストリームを作成
  let streamOption = client.createRequestStream()
  if streamOption.isNone:
    return none(WebTransportSession)
    
  let stream = streamOption.get()
  stream.state.store(sOpen)
  
  # ヘッダーをエンコード
  let encodedHeaders = encodeHeaders(client.qpackEncoder, headers)
  
  # HEADERSフレームを送信
  stream.queueFrame(newHeadersFrame(encodedHeaders))
  
  # レスポンスを待機
  let responseOption = await client.waitForResponse(stream.id)
  if responseOption.isNone:
    return none(WebTransportSession)
    
  let response = responseOption.get()
  
  # 2xxステータスコードをチェック
  if not response.isSuccess():
    return none(WebTransportSession)
    
  # WebTransportセッションを作成
  return some(WebTransportSession(
    client: client,
    sessionId: stream.id,
    isOpen: true,
    datagrams: @[]
  ))

proc sendDatagram*(session: WebTransportSession, data: seq[byte]): Future[bool] {.async.} =
  ## WebTransportセッションでデータグラムを送信
  if not session.isOpen:
    return false
    
  # データグラムフレームを作成して送信
  # 実装はクワイックプロトコルとの相互作用に依存
  return true

proc receiveDatagram*(session: WebTransportSession): Future[Option[seq[byte]]] {.async.} =
  ## WebTransportセッションからデータグラムを受信
  if not session.isOpen or session.datagrams.len == 0:
    return none(seq[byte])
    
  # キューから最初のデータグラムを取得
  let datagram = session.datagrams[0]
  session.datagrams.delete(0)
  
  return some(datagram)

proc closeWebTransport*(session: WebTransportSession) {.async.} =
  ## WebTransportセッションを閉じる
  if not session.isOpen:
    return
    
  session.isOpen = false
  
  # セッションのストリームを閉じる
  let streamOption = session.client.streams.getStream(session.sessionId)
  if streamOption.isSome:
    let stream = streamOption.get()
    await stream.closeStream()