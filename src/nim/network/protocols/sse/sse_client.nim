## SSE（Server-Sent Events）クライアント実装
##
## HTTP上に構築された単方向メッセージングプロトコルであるServer-Sent Events（SSE）のクライアント実装を提供します。
## テキストベースの軽量プロトコルで、サーバーからクライアントへの継続的な更新に適しています。

import std/[asyncdispatch, httpclient, options, strformat, strutils, tables, times, uri]
import ../../../core/logging/logger
import ../../http/headers/http_headers
import ../../http/client/http_client
import ./sse_types

type
  SseState* = enum
    ## SSE接続の状態
    ssConnecting,   # 接続中
    ssOpen,         # 接続済み
    ssClosed        # 接続終了
  
  SseClient* = ref object
    ## Server-Sent Events クライアント
    url*: string                 # 接続先URL
    httpClient: HttpClient       # HTTP接続用クライアント
    headers: HttpHeaders         # 接続に使用するHTTPヘッダー
    state*: SseState             # 現在の接続状態
    lastEventId*: string         # 最後に受信したイベントID
    reconnectionTime*: int       # 再接続待機時間（ミリ秒）
    lastReconnectionTime*: int   # 最後の再接続待機時間
    maxReconnectionTime*: int    # 最大再接続待機時間
    reconnectionAttempts*: int   # 再接続試行回数
    isAutoReconnect*: bool       # 自動再接続フラグ
    buffer: string               # 受信バッファ
    eventBuffer: SseEventBuffer  # イベントバッファ
    logger: Logger               # ロガー
    isStreamActive: bool         # ストリームアクティブフラグ
    lastReceived*: Time          # 最後のデータ受信時間
    onOpen*: proc(client: SseClient) {.closure, gcsafe.}
    onMessage*: proc(client: SseClient, event: SseEvent) {.closure, gcsafe.}
    onComment*: proc(client: SseClient, comment: string) {.closure, gcsafe.}
    onError*: proc(client: SseClient, error: string) {.closure, gcsafe.}
    onClose*: proc(client: SseClient) {.closure, gcsafe.}

# デフォルト設定値
const
  DefaultReconnectionTime = 3000       # デフォルト再接続待機時間（3秒）
  DefaultMaxReconnectionTime = 60000   # デフォルト最大再接続待機時間（1分）
  DefaultBufferSize = 8192             # デフォルトバッファサイズ（8KB）

proc newSseClient*(url: string, 
                  headers: HttpHeaders = nil,
                  reconnectionTime: int = DefaultReconnectionTime,
                  maxReconnectionTime: int = DefaultMaxReconnectionTime,
                  logger: Logger = nil): SseClient =
  ## 新しいSSEクライアントを作成する
  ##
  ## 引数:
  ##   url: 接続先のURL
  ##   headers: 接続に使用するHTTPヘッダー
  ##   reconnectionTime: 再接続待機時間（ミリ秒）
  ##   maxReconnectionTime: 最大再接続待機時間（ミリ秒）
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   SseClientオブジェクト
  
  # HTTPクライアントの初期化
  let httpClient = newHttpClient()
  httpClient.timeout = -1  # タイムアウトなし（SSEは長時間接続を維持）
  
  # ヘッダーを準備
  var clientHeaders = if headers.isNil: newHttpHeaders() else: headers
  
  # Accept: text/event-stream ヘッダーを追加（必須）
  clientHeaders["Accept"] = "text/event-stream"
  
  # Cache-Control: no-cache ヘッダーを追加（推奨）
  if not clientHeaders.hasKey("Cache-Control"):
    clientHeaders["Cache-Control"] = "no-cache"
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("SseClient") else: logger
  
  result = SseClient(
    url: url,
    httpClient: httpClient,
    headers: clientHeaders,
    state: ssConnecting,
    lastEventId: "",
    reconnectionTime: reconnectionTime,
    lastReconnectionTime: reconnectionTime,
    maxReconnectionTime: maxReconnectionTime,
    reconnectionAttempts: 0,
    isAutoReconnect: true,
    buffer: "",
    eventBuffer: newSseEventBuffer(),
    logger: clientLogger,
    isStreamActive: false,
    lastReceived: getTime()
  )

proc handleError(client: SseClient, error: string) =
  ## エラー処理
  client.logger.error(fmt"SSE error: {error}")
  if not client.onError.isNil:
    try:
      client.onError(client, error)
    except:
      client.logger.error(fmt"Error in onError callback: {getCurrentExceptionMsg()}")

proc close*(client: SseClient) =
  ## SSE接続を閉じる
  if client.state != ssClosed:
    client.state = ssClosed
    client.isStreamActive = false
    
    # HTTPクライアントを閉じる
    client.httpClient.close()
    
    # クローズコールバックを呼び出す
    if not client.onClose.isNil:
      try:
        client.onClose(client)
      except:
        client.logger.error(fmt"Error in onClose callback: {getCurrentExceptionMsg()}")
    
    client.logger.info("SSE connection closed")

proc connect*(client: SseClient): Future[bool] {.async.} =
  ## SSE接続を確立する
  ##
  ## 戻り値:
  ##   接続成功の場合はtrue、失敗の場合はfalse
  
  if client.state != ssConnecting:
    client.state = ssConnecting
  
  client.logger.info(fmt"Connecting to SSE endpoint: {client.url}")
  
  # 接続に使用するヘッダーを準備
  var headers = client.headers
  
  # 最後のイベントIDがある場合は追加
  if client.lastEventId.len > 0:
    headers["Last-Event-ID"] = client.lastEventId
  
  try:
    # GETリクエストを非同期に送信
    let response = await client.httpClient.getAsync(client.url, headers = headers)
    
    # レスポンスのステータスコードをチェック
    if response.code != Http200:
      client.handleError(fmt"SSE connection failed: HTTP {response.code}")
      client.state = ssClosed
      return false
    
    # Content-Typeヘッダーをチェック
    let contentType = response.headers.getOrDefault("content-type").toLowerAscii()
    if not (contentType.startsWith("text/event-stream") or 
            contentType.contains("text/event-stream;")):
      client.handleError(fmt"SSE connection failed: Invalid Content-Type '{contentType}'")
      client.state = ssClosed
      return false
    
    # 接続成功
    client.state = ssOpen
    client.isStreamActive = true
    client.lastReceived = getTime()
    client.reconnectionAttempts = 0
    
    # 接続オープンコールバックを呼び出す
    if not client.onOpen.isNil:
      try:
        client.onOpen(client)
      except:
        client.logger.error(fmt"Error in onOpen callback: {getCurrentExceptionMsg()}")
    
    client.logger.info("SSE connection established")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"SSE connection failed: {errMsg}")
    client.state = ssClosed
    return false

proc processLine(client: SseClient, line: string) =
  ## SSEイベントストリームの1行を処理する
  
  client.logger.debug(fmt"Processing SSE line: '{line}'")
  
  if line.len == 0:
    # 空行はイベントの終了を表す
    if client.eventBuffer.hasData():
      let event = client.eventBuffer.buildEvent()
      
      # イベントIDがある場合は保存
      if event.id.len > 0:
        client.lastEventId = event.id
      
      # リトライタイムの処理
      if event.event == "retry" and event.data.len > 0:
        try:
          let retryTime = parseInt(event.data)
          if retryTime > 0:
            client.reconnectionTime = retryTime
            client.lastReconnectionTime = retryTime
            client.logger.debug(fmt"SSE retry time updated: {retryTime}ms")
          else:
            client.logger.warn(fmt"Invalid retry time: {event.data}")
        except:
          client.logger.warn(fmt"Failed to parse retry time: {event.data}")
      else:
        # イベントコールバックを呼び出す
        if not client.onMessage.isNil:
          try:
            client.onMessage(client, event)
          except:
            client.logger.error(fmt"Error in onMessage callback: {getCurrentExceptionMsg()}")
      
      # イベントバッファをリセット
      client.eventBuffer.reset()
  elif line.startsWith(":"):
    # コメント行
    let comment = line[1..^1].strip()
    
    if not client.onComment.isNil:
      try:
        client.onComment(client, comment)
      except:
        client.logger.error(fmt"Error in onComment callback: {getCurrentExceptionMsg()}")
  elif line.contains(":"):
    # フィールド行
    let colonPos = line.find(":")
    if colonPos > 0:
      var fieldName = line[0..<colonPos]
      var fieldValue = if colonPos < line.len - 1: line[colonPos + 1..^1] else: ""
      
      # 最初の空白を取り除く（仕様による）
      if fieldValue.len > 0 and fieldValue[0] == ' ':
        fieldValue = fieldValue[1..^1]
      
      # フィールドを処理
      case fieldName.toLowerAscii()
      of "event":
        client.eventBuffer.event = fieldValue
      of "data":
        if client.eventBuffer.data.len > 0:
          client.eventBuffer.data.add("\n")
        client.eventBuffer.data.add(fieldValue)
      of "id":
        # 空でないID値を設定
        if not fieldValue.contains(char(0)):  # NULLバイトを含まない
          client.eventBuffer.id = fieldValue
      of "retry":
        # リトライ時間フィールドは後で処理（イベント構築時）
        client.eventBuffer.retry = fieldValue
      else:
        # 未知のフィールドは無視
        client.logger.debug(fmt"Unknown SSE field: {fieldName}={fieldValue}")
  else:
    # フィールド名なしのデータ（仕様外だが処理）
    client.logger.warn(fmt"Malformed SSE line: '{line}'")

proc processChunk(client: SseClient, chunk: string) =
  ## 受信したチャンクを処理する
  
  client.lastReceived = getTime()
  
  # バッファにチャンクを追加
  client.buffer.add(chunk)
  
  # 完全な行を処理
  var position = 0
  while true:
    let newlinePos = client.buffer.find("\n", position)
    if newlinePos < 0:
      break
    
    let line = client.buffer[position..<newlinePos].strip(trailing = true)
    client.processLine(line)
    
    position = newlinePos + 1
  
  # 処理済みのデータをバッファから削除
  if position > 0:
    client.buffer = client.buffer[position..^1]

proc listen*(client: SseClient) {.async.} =
  ## SSEストリームの受信ループを開始する
  
  if client.state != ssOpen or not client.isStreamActive:
    client.handleError("Cannot listen: SSE connection is not open")
    return
  
  client.logger.info("Starting SSE event stream listening")
  
  # 自動再接続が必要になるまで受信を続ける
  var shouldReconnect = false
  
  try:
    # 非同期で受信処理
    while client.state == ssOpen and client.isStreamActive:
      var buffer = newString(DefaultBufferSize)
      
      try:
        let bytesRead = await client.httpClient.recvAsync(buffer)
        
        if bytesRead <= 0:
          # ストリームが終了した場合
          client.logger.info("SSE stream ended normally")
          shouldReconnect = client.isAutoReconnect
          break
        
        # 読み取ったデータを処理
        client.processChunk(buffer[0..<bytesRead])
      except:
        let errMsg = getCurrentExceptionMsg()
        client.handleError(fmt"Error reading SSE stream: {errMsg}")
        shouldReconnect = client.isAutoReconnect
        break
      
      # 処理間隔を少し空ける
      await sleepAsync(1)
  finally:
    # 接続状態を更新
    if client.state != ssClosed:
      client.isStreamActive = false
      
      if shouldReconnect:
        # 再接続ロジック
        client.state = ssConnecting
        
        # 指数バックオフで再接続を試みる
        while client.isAutoReconnect:
          # 再接続前の待機
          client.logger.info(fmt"Reconnecting to SSE stream in {client.lastReconnectionTime}ms...")
          await sleepAsync(client.lastReconnectionTime)
          
          # 接続が手動で閉じられた場合
          if client.state == ssClosed:
            break
          
          # 再接続試行
          client.reconnectionAttempts += 1
          let success = await client.connect()
          
          if success:
            # 再接続成功、リスニングを再開
            await client.listen()
            break
          else:
            # 再接続失敗、待機時間を増やす
            let newTime = min(client.lastReconnectionTime * 2, client.maxReconnectionTime)
            client.lastReconnectionTime = newTime
            
            # 無限再試行を防止するための安全対策
            if client.reconnectionAttempts > 10:
              client.logger.error("Maximum SSE reconnection attempts exceeded")
              client.close()
              break
      else:
        # 再接続なしでクローズ
        client.close()

proc send*(client: SseClient, data: string): Future[bool] {.async.} =
  ## SSEサーバーにデータを送信する（SSEは単方向なので、これは別のHTTPリクエストを使用）
  ##
  ## この機能は標準のSSEモデルの範囲外ですが、同じURLにPOSTリクエストを
  ## 送信するための便宜的なメソッドです。
  ##
  ## 引数:
  ##   data: 送信するデータ
  ##
  ## 戻り値:
  ##   送信成功の場合はtrue、失敗の場合はfalse
  
  try:
    # 同じURLにPOSTリクエストを送信
    let httpClient = newHttpClient()
    let response = await httpClient.postAsync(client.url, data)
    
    # レスポンスのステータスコードをチェック
    return response.code == Http200 or response.code == Http204
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to send data to SSE server: {errMsg}")
    return false 