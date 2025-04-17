## HTTP/HTTPS プロキシクライアント
## 
## HTTP/HTTPS プロキシサーバーとの通信を処理します。
## 基本認証やNTLM認証などの認証メカニズムをサポートします。

import std/[asyncdispatch, asyncnet, base64, httpclient, nativesockets, options, os, strformat, strutils, uri]
import net as stdnet
import ../../../core/logging/logger
import ../../../utils/crypto/hash
import ../../../utils/crypto/ntlm
import ../proxy_types

type
  HttpProxyAuthMethod* = enum
    ## HTTPプロキシ認証メソッド
    hpamNone,        ## 認証なし
    hpamBasic,       ## 基本認証
    hpamNtlm,        ## NTLM認証
    hpamDigest,      ## ダイジェスト認証
    hpamNegotiate    ## Negotiate認証

  HttpProxyClient* = ref object
    ## HTTPプロキシクライアント
    logger: Logger       ## ロガー
    host*: string        ## プロキシホスト名
    port*: int           ## プロキシポート
    username*: string    ## ユーザー名（認証用）
    password*: string    ## パスワード（認証用）
    authMethod*: HttpProxyAuthMethod  ## 認証方法
    timeout*: int        ## タイムアウト（ミリ秒）
    connected*: bool     ## 接続状態
    socket: AsyncSocket  ## ソケット
    tunneled*: bool      ## トンネル接続状態

const
  DefaultProxyPort* = 8080      ## デフォルトHTTPプロキシポート
  DefaultTimeout* = 10000       ## デフォルトタイムアウト（10秒）
  UserAgent = "Mozilla/5.0 Nim HttpProxyClient"  ## デフォルトユーザーエージェント

proc newHttpProxyClient*(host: string, port = DefaultProxyPort, 
                        username = "", password = "", 
                        authMethod = hpamNone, 
                        logger: Logger = nil): HttpProxyClient =
  ## 新しいHTTPプロキシクライアントを作成する
  ##
  ## 引数:
  ##   host: プロキシサーバーのホスト名
  ##   port: プロキシサーバーのポート番号
  ##   username: 認証用ユーザー名（認証が必要な場合）
  ##   password: 認証用パスワード（認証が必要な場合）
  ##   authMethod: 認証方法
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   HttpProxyClientオブジェクト
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("HttpProxyClient") else: logger
  
  var authType = authMethod
  
  # ユーザー名とパスワードが設定されているが認証方法が指定されていない場合、
  # デフォルトとして基本認証を使用
  if authType == hpamNone and username.len > 0 and password.len > 0:
    authType = hpamBasic
  
  result = HttpProxyClient(
    logger: clientLogger,
    host: host,
    port: port,
    username: username,
    password: password,
    authMethod: authType,
    timeout: DefaultTimeout,
    connected: false,
    socket: nil,
    tunneled: false
  )

proc generateBasicAuthHeader(username, password: string): string =
  ## 基本認証ヘッダーを生成する
  ##
  ## 引数:
  ##   username: ユーザー名
  ##   password: パスワード
  ##
  ## 戻り値:
  ##   Basic認証ヘッダー文字列
  
  let auth = username & ":" & password
  result = "Basic " & base64.encode(auth)

proc parseProxyAuthChallenge(header: string): tuple[method: string, realm: string, nonce: string, opaque: string] =
  ## プロキシ認証チャレンジヘッダーを解析する
  ##
  ## 引数:
  ##   header: Proxy-Authenticate ヘッダー
  ##
  ## 戻り値:
  ##   認証方法、レルム、ノンス、オペークのタプル
  
  result = (method: "", realm: "", nonce: "", opaque: "")
  
  if header.len == 0:
    return
  
  # 認証方法を抽出
  let parts = header.split(' ', maxsplit=1)
  if parts.len < 1:
    return
  
  result.method = parts[0]
  
  if parts.len < 2:
    return
  
  # キーと値のペアを抽出
  let authParams = parts[1]
  var currentKey = ""
  var currentValue = ""
  var inQuote = false
  var escaped = false
  
  for c in authParams:
    if escaped:
      currentValue.add(c)
      escaped = false
    elif inQuote and c == '\\':
      escaped = true
    elif c == '"':
      inQuote = not inQuote
    elif not inQuote and c == ',':
      # キーと値のペアの終了
      if currentKey.len > 0:
        let key = currentKey.strip().toLowerAscii()
        if key == "realm":
          result.realm = currentValue
        elif key == "nonce":
          result.nonce = currentValue
        elif key == "opaque":
          result.opaque = currentValue
      
      currentKey = ""
      currentValue = ""
    elif not inQuote and c == '=':
      # キーの終了、値の開始
      currentKey = currentKey.strip()
    else:
      if currentKey.len > 0 and currentKey.strip().len > 0 and '=' in currentKey:
        currentValue.add(c)
      else:
        currentKey.add(c)
  
  # 最後のキーと値のペアを処理
  if currentKey.len > 0:
    let key = currentKey.strip().toLowerAscii()
    if key == "realm":
      result.realm = currentValue
    elif key == "nonce":
      result.nonce = currentValue
    elif key == "opaque":
      result.opaque = currentValue

proc connect*(client: HttpProxyClient): Future[bool] {.async.} =
  ## プロキシサーバーに接続する
  ##
  ## 戻り値:
  ##   接続に成功した場合はtrue、失敗した場合はfalse
  
  try:
    client.logger.info(fmt"Connecting to HTTP proxy {client.host}:{client.port}")
    
    # ソケットを作成して接続
    client.socket = newAsyncSocket()
    client.socket.setSockOpt(OptNoDelay, true)
    
    # タイムアウト設定
    withTimeout(client.socket.connect(client.host, Port(client.port)), client.timeout):
      client.connected = true
      client.logger.info("Connected to HTTP proxy server")
      return true
    
    client.logger.error("Connection to HTTP proxy timed out")
    return false
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to connect to HTTP proxy: {errMsg}")
    return false

proc disconnect*(client: HttpProxyClient) =
  ## プロキシサーバーから切断する
  
  try:
    if client.connected and not client.socket.isNil:
      client.socket.close()
      client.connected = false
      client.tunneled = false
      client.logger.info("Disconnected from HTTP proxy server")
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.warn(fmt"Error disconnecting from HTTP proxy: {errMsg}")

proc sendRequest(client: HttpProxyClient, request: string): Future[bool] {.async.} =
  ## リクエストをプロキシサーバーに送信する
  ##
  ## 引数:
  ##   request: 送信するHTTPリクエスト
  ##
  ## 戻り値:
  ##   送信に成功した場合はtrue、失敗した場合はfalse
  
  try:
    client.logger.debug("Sending request to proxy")
    client.logger.debug(request)
    await client.socket.send(request)
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to send request to proxy: {errMsg}")
    return false

proc receiveResponse(client: HttpProxyClient): Future[tuple[headers: string, body: string, code: int]] {.async.} =
  ## プロキシサーバーからレスポンスを受信する
  ##
  ## 戻り値:
  ##   ヘッダー、ボディ、ステータスコードのタプル
  
  try:
    var buffer = ""
    var headerEnd = 0
    var contentLength = 0
    var chunked = false
    
    # ヘッダーを受信
    while true:
      let chunk = await client.socket.recv(4096)
      if chunk.len == 0:
        break
      
      buffer.add(chunk)
      
      # ヘッダーの終端を探す
      headerEnd = buffer.find("\r\n\r\n")
      if headerEnd >= 0:
        break
    
    if headerEnd < 0:
      client.logger.error("Invalid HTTP response: no header end found")
      return ("", "", 0)
    
    # ヘッダーとボディを分離
    let headers = buffer[0 .. headerEnd + 3]
    var body = buffer[headerEnd + 4 .. ^1]
    
    # ステータスコードを解析
    let statusLine = headers.splitLines()[0]
    let statusParts = statusLine.split(' ', maxsplit=2)
    var code = 0
    if statusParts.len >= 2:
      try:
        code = parseInt(statusParts[1])
      except:
        client.logger.warn(fmt"Failed to parse status code: {statusParts[1]}")
    
    # Content-Lengthを取得
    for line in headers.splitLines():
      let headerLine = line.strip()
      if headerLine.toLowerAscii().startsWith("content-length:"):
        let lenStr = headerLine.split(':', maxsplit=1)[1].strip()
        try:
          contentLength = parseInt(lenStr)
        except:
          client.logger.warn(fmt"Failed to parse Content-Length: {lenStr}")
      elif headerLine.toLowerAscii().startsWith("transfer-encoding:") and 
           headerLine.toLowerAscii().contains("chunked"):
        chunked = true
    
    # ボディを受信（Content-Lengthベース）
    if contentLength > body.len and not chunked:
      while body.len < contentLength:
        let chunk = await client.socket.recv(4096)
        if chunk.len == 0:
          break
        body.add(chunk)
    
    # チャンク転送エンコーディングの処理
    if chunked:
      client.logger.debug("Chunked transfer encoding detected")
      var decodedBody = ""
      var currentPos = 0
      
      # 既に受信した部分を処理
      let originalBody = body
      body = ""
      
      while currentPos < originalBody.len:
        # チャンクサイズ行を探す
        let sizeLineEnd = originalBody.find("\r\n", currentPos)
        if sizeLineEnd < 0:
          # チャンクサイズ行が見つからない場合は追加データが必要
          body = originalBody[currentPos .. ^1]  # 処理していない部分を保持
          break
        
        # チャンクサイズを16進数から取得
        var chunkSizeHex = originalBody[currentPos ..< sizeLineEnd].strip()
        # 拡張部分を除去（分号以降）
        if ";" in chunkSizeHex:
          chunkSizeHex = chunkSizeHex.split(";")[0].strip()
        
        var chunkSize: int
        try:
          chunkSize = parseHexInt(chunkSizeHex)
        except:
          client.logger.warn(fmt"Invalid chunk size: {chunkSizeHex}")
          body = originalBody[currentPos .. ^1]  # 処理していない部分を保持
          break
        
        # チャンクサイズが0ならチャンク終了
        if chunkSize == 0:
          # トレーラーヘッダーをスキップ（存在する場合）
          currentPos = originalBody.find("\r\n\r\n", sizeLineEnd)
          if currentPos < 0:
            body = originalBody[sizeLineEnd .. ^1]  # 処理していない部分を保持
          else:
            # 完全に処理完了
            currentPos += 4
          
          break
        
        # データ部分の開始位置
        let dataStart = sizeLineEnd + 2
        # データの終了位置（CRLF含む）
        let dataEnd = dataStart + chunkSize + 2
        
        # 完全なチャンクがあるか確認
        if dataEnd > originalBody.len:
          # チャンクが不完全なら残りのデータを保持
          body = originalBody[currentPos .. ^1]
          break
        
        # チャンクデータを取得（末尾のCRLFを除く）
        let chunkData = originalBody[dataStart ..< dataStart + chunkSize]
        decodedBody.add(chunkData)
        
        # 次のチャンクへ
        currentPos = dataEnd
      
      # チャンクが完全に処理されていない場合、追加データを受信
      while chunked and body.len > 0:
        let chunk = await client.socket.recv(4096)
        if chunk.len == 0:
          # 接続が閉じられた場合
          break
        
        body.add(chunk)
        var processedBody = body
        body = ""
        currentPos = 0
        
        while currentPos < processedBody.len:
          # チャンクサイズ行を探す
          let sizeLineEnd = processedBody.find("\r\n", currentPos)
          if sizeLineEnd < 0:
            # チャンクサイズ行が見つからない場合は追加データが必要
            body = processedBody[currentPos .. ^1]
            break
          
          # チャンクサイズを16進数から取得
          var chunkSizeHex = processedBody[currentPos ..< sizeLineEnd].strip()
          # 拡張部分を除去
          if ";" in chunkSizeHex:
            chunkSizeHex = chunkSizeHex.split(";")[0].strip()
          
          var chunkSize: int
          try:
            chunkSize = parseHexInt(chunkSizeHex)
          except:
            client.logger.warn(fmt"Invalid chunk size: {chunkSizeHex}")
            body = processedBody[currentPos .. ^1]
            break
          
          # チャンクサイズが0ならチャンク終了
          if chunkSize == 0:
            # トレーラーヘッダーをスキップ（存在する場合）
            let trailerStart = sizeLineEnd + 2
            let trailerEnd = processedBody.find("\r\n\r\n", trailerStart)
            
            if trailerEnd < 0:
              # トレーラーが不完全なら残りを保持
              body = processedBody[trailerStart .. ^1]
            else:
              # 完全に処理完了、chunkedフラグをオフに
              chunked = false
            
            break
          
          # データ部分の開始位置
          let dataStart = sizeLineEnd + 2
          # データの終了位置（CRLF含む）
          let dataEnd = dataStart + chunkSize + 2
          
          # 完全なチャンクがあるか確認
          if dataEnd > processedBody.len:
            # チャンクが不完全なら残りのデータを保持
            body = processedBody[currentPos .. ^1]
            break
          
          # チャンクデータを取得（末尾のCRLFを除く）
          let chunkData = processedBody[dataStart ..< dataStart + chunkSize]
          decodedBody.add(chunkData)
          
          # 次のチャンクへ
          currentPos = dataEnd
      
      # デコードされたボディを設定
      body = decodedBody
    
    client.logger.debug(fmt"Received response: {code}")
    return (headers, body, code)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to receive response from proxy: {errMsg}")
    return ("", "", 0)

proc executeBasicAuth(client: HttpProxyClient, targetHost: string, targetPort: int, 
                     isHttps: bool): Future[bool] {.async.} =
  ## 基本認証を実行する
  ##
  ## 引数:
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  ##   isHttps: HTTPSかどうか
  ##
  ## 戻り値:
  ##   認証に成功した場合はtrue、失敗した場合はfalse
  
  client.logger.info("Executing Basic Authentication")
  
  let authHeader = generateBasicAuthHeader(client.username, client.password)
  var request = ""
  
  if isHttps:
    # HTTPSの場合はCONNECTメソッドを使用
    request = fmt"""CONNECT {targetHost}:{targetPort} HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  else:
    # HTTPの場合は完全なURLを指定
    request = fmt"""GET http://{targetHost}:{targetPort}/ HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  
  # リクエストを送信
  if not await client.sendRequest(request):
    return false
  
  # レスポンスを受信
  let (headers, _, code) = await client.receiveResponse(client)
  
  # ステータスコードを確認
  if code == 200:
    client.logger.info("Basic Authentication successful")
    return true
  elif code == 407:
    client.logger.error("Basic Authentication failed: Proxy Authentication Required")
    client.logger.debug(headers)
    return false
  else:
    client.logger.error(fmt"Basic Authentication failed with code: {code}")
    return false

proc executeNtlmAuth(client: HttpProxyClient, targetHost: string, targetPort: int, 
                    isHttps: bool): Future[bool] {.async.} =
  ## NTLM認証を実行する
  ##
  ## 引数:
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  ##   isHttps: HTTPSかどうか
  ##
  ## 戻り値:
  ##   認証に成功した場合はtrue、失敗した場合はfalse
  
  client.logger.info("Executing NTLM Authentication")
  
  # NTLM Type 1 メッセージを生成
  let type1Msg = createNtlmType1Message()
  let authHeader1 = "NTLM " & base64.encode(type1Msg)
  var request1 = ""
  
  if isHttps:
    # HTTPSの場合はCONNECTメソッドを使用
    request1 = fmt"""CONNECT {targetHost}:{targetPort} HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader1}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  else:
    # HTTPの場合は完全なURLを指定
    request1 = fmt"""GET http://{targetHost}:{targetPort}/ HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader1}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  
  # Type 1 メッセージを送信
  if not await client.sendRequest(request1):
    return false
  
  # レスポンスを受信
  let (headers1, _, code1) = await client.receiveResponse(client)
  
  # ステータスコードとチャレンジを確認
  if code1 != 407:
    client.logger.error(fmt"NTLM Authentication failed: Expected 407, got {code1}")
    return false
  
  # Proxy-Authenticate ヘッダーからNTLMチャレンジを抽出
  var challenge = ""
  for line in headers1.splitLines():
    let headerLine = line.strip()
    if headerLine.toLowerAscii().startsWith("proxy-authenticate:") and 
       headerLine.toLowerAscii().contains("ntlm "):
      let parts = headerLine.split("NTLM ", maxsplit=1)
      if parts.len >= 2:
        challenge = parts[1].strip()
        break
  
  if challenge.len == 0:
    client.logger.error("NTLM Authentication failed: No challenge received")
    return false
  
  # チャレンジをデコード
  let challengeBytes = base64.decode(challenge)
  
  # NTLM Type 3 メッセージを生成
  let type3Msg = createNtlmType3Message(challengeBytes, client.username, client.password)
  let authHeader3 = "NTLM " & base64.encode(type3Msg)
  var request3 = ""
  
  if isHttps:
    # HTTPSの場合はCONNECTメソッドを使用
    request3 = fmt"""CONNECT {targetHost}:{targetPort} HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader3}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  else:
    # HTTPの場合は完全なURLを指定
    request3 = fmt"""GET http://{targetHost}:{targetPort}/ HTTP/1.1
Host: {targetHost}:{targetPort}
Proxy-Authorization: {authHeader3}
User-Agent: {UserAgent}
Connection: keep-alive

"""
  
  # Type 3 メッセージを送信
  if not await client.sendRequest(request3):
    return false
  
  # レスポンスを受信
  let (_, _, code3) = await client.receiveResponse(client)
  
  # ステータスコードを確認
  if code3 == 200:
    client.logger.info("NTLM Authentication successful")
    return true
  else:
    client.logger.error(fmt"NTLM Authentication failed with code: {code3}")
    return false

proc establishTunnel*(client: HttpProxyClient, targetHost: string, targetPort: int): Future[bool] {.async.} =
  ## HTTPS用のプロキシトンネルを確立する
  ##
  ## 引数:
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  ##
  ## 戻り値:
  ##   トンネル確立に成功した場合はtrue、失敗した場合はfalse
  
  if not client.connected:
    if not await client.connect():
      client.logger.error(fmt"プロキシサーバーへの接続に失敗しました: {client.host}:{client.port}")
      return false
  
  client.logger.info(fmt"トンネルを確立しています: {targetHost}:{targetPort}")
  
  # 認証方法に応じて処理
  case client.authMethod
  of hpamNone:
    # 認証なし
    let request = fmt"""CONNECT {targetHost}:{targetPort} HTTP/1.1
Host: {targetHost}:{targetPort}
User-Agent: {UserAgent}
Proxy-Connection: keep-alive
Connection: keep-alive

"""
    if not await client.sendRequest(request):
      client.logger.error("トンネル確立リクエストの送信に失敗しました")
      return false
    
    let (headers, _, code) = await client.receiveResponse(client)
    if code == 200:
      client.tunneled = true
      client.logger.info("トンネルが正常に確立されました")
      return true
    elif code == 407:
      client.logger.error("プロキシ認証が必要です: " & headers)
      return false
    else:
      client.logger.error(fmt"トンネル確立に失敗しました、ステータスコード: {code}, レスポンス: {headers}")
      return false
  
  of hpamBasic:
    # 基本認証
    if await client.executeBasicAuth(targetHost, targetPort, true):
      client.tunneled = true
      client.logger.info("Basic認証によるトンネルが確立されました")
      return true
    client.logger.error("Basic認証によるトンネル確立に失敗しました")
    return false
  
  of hpamNtlm:
    # NTLM認証
    if await client.executeNtlmAuth(targetHost, targetPort, true):
      client.tunneled = true
      client.logger.info("NTLM認証によるトンネルが確立されました")
      return true
    client.logger.error("NTLM認証によるトンネル確立に失敗しました")
    return false
  
  of hpamDigest:
    # ダイジェスト認証
    if await client.executeDigestAuth(targetHost, targetPort, true):
      client.tunneled = true
      client.logger.info("Digest認証によるトンネルが確立されました")
      return true
    client.logger.error("Digest認証によるトンネル確立に失敗しました")
    return false
    
  of hpamNegotiate:
    # Negotiate認証（Kerberos/SPNEGO）
    client.logger.error("Negotiate認証は現在実装されていません")
    return false

proc getSocket*(client: HttpProxyClient): AsyncSocket =
  ## プロキシクライアントのソケットを取得する
  ##
  ## 戻り値:
  ##   AsyncSocketオブジェクト
  
  return client.socket

proc proxyRequest*(client: HttpProxyClient, url: string, httpMethod = "GET", 
                  headers: openArray[(string, string)] = [], 
                  body = ""): Future[tuple[headers: string, body: string, code: int]] {.async.} =
  ## HTTPリクエストをプロキシ経由で実行する
  ##
  ## 引数:
  ##   url: リクエスト先URL
  ##   httpMethod: HTTPメソッド
  ##   headers: HTTPヘッダー
  ##   body: リクエストボディ
  ##
  ## 戻り値:
  ##   レスポンスヘッダー、ボディ、ステータスコードのタプル
  
  if not client.connected:
    if not await client.connect():
      client.logger.error(fmt"プロキシサーバーへの接続に失敗しました: {client.host}:{client.port}")
      return ("", "", 0)
  
  # URLを解析
  let uri = parseUri(url)
  let targetHost = uri.hostname
  let targetPort = if uri.port == "": 
                    if uri.scheme == "https": 443 else: 80
                  else: 
                    parseInt(uri.port)
  let isHttps = uri.scheme == "https"
  let path = if uri.path == "": "/" else: uri.path & (if uri.query.len > 0: "?" & uri.query else: "")
  
  # HTTPSの場合はトンネルを確立
  if isHttps:
    if not client.tunneled:
      if not await client.establishTunnel(targetHost, targetPort):
        client.logger.error(fmt"HTTPSトンネルの確立に失敗しました: {targetHost}:{targetPort}")
        return ("", "", 0)
      
    # トンネル経由でのHTTPSリクエストは、TLSハンドシェイクが必要
    try:
      # TLSコンテキストを作成
      let tlsContext = newContext(verifyMode = CVerifyPeer)
      # TLSクライアントを作成
      let tlsSocket = newAsyncSocket()
      await tlsSocket.connect(targetHost, Port(targetPort))
      let tlsStream = newAsyncTlsStream(tlsSocket, tlsContext, targetHost)
      
      # TLS経由でHTTPリクエストを送信
      var tlsRequest = fmt"""{httpMethod} {path} HTTP/1.1
Host: {targetHost}"""
      
      # ユーザー定義ヘッダーを追加
      for (name, value) in headers:
        if cmpIgnoreCase(name, "Host") != 0:  # Hostヘッダーは既に追加済み
          tlsRequest.add(fmt"\r\n{name}: {value}")
      
      # 標準ヘッダーを追加
      tlsRequest.add(fmt"\r\nUser-Agent: {UserAgent}")
      tlsRequest.add("\r\nConnection: keep-alive")
      
      # ボディがある場合はContent-Lengthヘッダーを追加
      if body.len > 0:
        tlsRequest.add(fmt"\r\nContent-Length: {body.len}")
      
      # ヘッダーとボディの区切り
      tlsRequest.add("\r\n\r\n")
      
      # ボディを追加
      if body.len > 0:
        tlsRequest.add(body)
      
      # リクエストを送信
      await tlsStream.write(tlsRequest)
      
      # レスポンスを受信
      var responseBuffer = newStringOfCap(4096)
      var headersParsed = false
      var contentLength = 0
      var chunked = false
      var headers = ""
      var responseBody = ""
      var statusCode = 0
      
      # ヘッダーを読み込む
      while true:
        let line = await tlsStream.readLine()
        if line == "":
          break
        
        responseBuffer.add(line & "\r\n")
        
        if not headersParsed:
          if line == "":
            headersParsed = true
            headers = responseBuffer
            
            # ステータスコードを抽出
            let statusLine = headers.splitLines()[0]
            let parts = statusLine.split(' ')
            if parts.len >= 3:
              try:
                statusCode = parseInt(parts[1])
              except:
                client.logger.error("ステータスコードの解析に失敗しました: " & statusLine)
            
            # Content-Lengthを抽出
            for headerLine in headers.splitLines():
              if headerLine.startsWith("Content-Length:"):
                try:
                  contentLength = parseInt(headerLine.split(':')[1].strip())
                except:
                  client.logger.error("Content-Lengthの解析に失敗しました: " & headerLine)
              
              if headerLine.toLowerAscii().contains("transfer-encoding: chunked"):
                chunked = true
          
      # ボディを読み込む
      if chunked:
        # チャンク転送エンコーディングの処理
        var chunkSize = 0
        while true:
          let chunkHeader = await tlsStream.readLine()
          try:
            chunkSize = parseHexInt(chunkHeader)
          except:
            client.logger.error("チャンクサイズの解析に失敗しました: " & chunkHeader)
            break
          
          if chunkSize == 0:
            break
          
          var chunk = await tlsStream.read(chunkSize)
          responseBody.add(chunk)
          
          # チャンク終端のCRLFを読み飛ばす
          discard await tlsStream.readLine()
      elif contentLength > 0:
        # 固定長ボディの処理
        responseBody = await tlsStream.read(contentLength)
      
      # TLS接続を閉じる
      tlsStream.close()
      
      return (headers, responseBody, statusCode)
      
    except Exception as e:
      client.logger.error(fmt"TLS通信中にエラーが発生しました: {e.msg}")
      return ("", "", 0)
  
  # HTTP（非HTTPS）リクエスト
  var fullUrl = url
  if not url.startsWith("http"):
    fullUrl = fmt"http://{targetHost}:{targetPort}{path}"
  
  # HTTPリクエストを構築
  var request = fmt"""{httpMethod} {fullUrl} HTTP/1.1
Host: {targetHost}"""
  
  # 認証方法に応じてヘッダーを追加
  case client.authMethod
  of hpamBasic:
    request.add("\r\nProxy-Authorization: " & generateBasicAuthHeader(client.username, client.password))
  of hpamNtlm:
    # NTLMは複雑なチャレンジレスポンス認証なので、単一リクエストでは処理できない
    # 完全なNTLM認証フローを実行する必要がある
    if not await client.executeNtlmAuth(targetHost, targetPort, false):
      client.logger.error("NTLM認証に失敗しました")
      return ("", "", 0)
  of hpamDigest:
    # ダイジェスト認証も複雑なチャレンジレスポンス認証
    if not await client.executeDigestAuth(targetHost, targetPort, false):
      client.logger.error("Digest認証に失敗しました")
      return ("", "", 0)
  of hpamNegotiate:
    client.logger.error("Negotiate認証は現在実装されていません")
    return ("", "", 0)
  else:
    discard
  
  # ユーザー定義ヘッダーを追加
  for (name, value) in headers:
    if cmpIgnoreCase(name, "Host") != 0:  # Hostヘッダーは既に追加済み
      request.add(fmt"\r\n{name}: {value}")
  
  # 標準ヘッダーを追加
  request.add(fmt"\r\nUser-Agent: {UserAgent}")
  request.add("\r\nProxy-Connection: keep-alive")
  request.add("\r\nConnection: keep-alive")
  
  # ボディがある場合はContent-Lengthヘッダーを追加
  if body.len > 0:
    request.add(fmt"\r\nContent-Length: {body.len}")
  
  # ヘッダーとボディの区切り
  request.add("\r\n\r\n")
  
  # ボディを追加
  if body.len > 0:
    request.add(body)
  
  # リクエストを送信
  if not await client.sendRequest(request):
    client.logger.error("リクエストの送信に失敗しました")
    return ("", "", 0)
  
  # レスポンスを受信
  return await client.receiveResponse(client)

proc detectSystemProxy*(): ProxySettings =
  ## システムプロキシ設定を検出する
  ##
  ## 戻り値:
  ##   検出されたプロキシ設定
  
  result = ProxySettings(enabled: false)
  
  try:
    # 環境変数をチェック
    let httpProxy = getEnv("HTTP_PROXY")
    let httpsProxy = getEnv("HTTPS_PROXY")
    let noProxy = getEnv("NO_PROXY")
    
    if httpProxy.len > 0:
      result = parseProxyString(httpProxy)
      result.enabled = true
      result.noProxyList = noProxy.split(',')
      return
    
    if httpsProxy.len > 0:
      result = parseProxyString(httpsProxy)
      result.enabled = true
      result.noProxyList = noProxy.split(',')
      return
    
    # OS固有の設定を取得
    when defined(windows):
      # Windowsレジストリからプロキシ設定を取得
      try:
        # WinHTTP設定を取得
        let regKey = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections"
        let winHttpSettings = getRegistryValue(HKEY_CURRENT_USER, regKey, "DefaultConnectionSettings")
        
        if winHttpSettings.len > 0 and (ord(winHttpSettings[8]) and 0x01) != 0:
          # プロキシが有効
          result.enabled = true
          
          # プロキシサーバー文字列を取得
          let proxyServer = getRegistryValue(HKEY_CURRENT_USER, 
                                           r"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings", 
                                           "ProxyServer")
          
          if proxyServer.len > 0:
            # プロキシ設定を解析
            if proxyServer.contains("="):
              # プロトコル別設定
              for part in proxyServer.split(';'):
                if part.startsWith("http="):
                  result = parseProxyString(part.substr(5))
                  break
            else:
              # 全プロトコル共通設定
              result = parseProxyString(proxyServer)
          
          # バイパスリストを取得
          let proxyOverride = getRegistryValue(HKEY_CURRENT_USER, 
                                             r"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings", 
                                             "ProxyOverride")
          
          if proxyOverride.len > 0:
            result.noProxyList = proxyOverride.split(';')
      except:
        discard
    
    elif defined(macosx):
      # macOSのプロキシ設定を取得
      try:
        # scutilコマンドでネットワーク設定を取得
        let (output, exitCode) = execCmdEx("scutil --proxy")
        
        if exitCode == 0 and output.contains("HTTPEnable : 1"):
          result.enabled = true
          
          # HTTPプロキシホストとポートを抽出
          var hostMatch = output.find(re"HTTPProxy : (.+)")
          var portMatch = output.find(re"HTTPPort : (\d+)")
          
          if hostMatch.isSome and portMatch.isSome:
            let host = hostMatch.get.captures[0]
            let port = parseInt(portMatch.get.captures[0])
            
            result.host = host
            result.port = port
            result.authMethod = hpamNone  # macOSの設定からは認証情報を取得できない
          
          # バイパスリストを抽出
          var bypassMatch = output.find(re"ExceptionsList : \((.*)\)")
          if bypassMatch.isSome:
            let bypassList = bypassMatch.get.captures[0]
            result.noProxyList = bypassList.split(", ")
      except:
        discard
    
    elif defined(linux):
      # GNOMEプロキシ設定を取得
      try:
        let (httpMode, _) = execCmdEx("gsettings get org.gnome.system.proxy mode")
        
        if httpMode.strip() == "'manual'":
          result.enabled = true
          
          # HTTPプロキシホストとポートを取得
          let (httpHost, _) = execCmdEx("gsettings get org.gnome.system.proxy.http host")
          let (httpPort, _) = execCmdEx("gsettings get org.gnome.system.proxy.http port")
          
          if httpHost.len > 0 and httpPort.len > 0:
            result.host = httpHost.strip().replace("'", "")
            try:
              result.port = parseInt(httpPort.strip())
            except:
              result.port = 8080  # デフォルトポート
          
          # 認証情報を取得
          let (authEnabled, _) = execCmdEx("gsettings get org.gnome.system.proxy.http use-authentication")
          
          if authEnabled.strip() == "true":
            let (username, _) = execCmdEx("gsettings get org.gnome.system.proxy.http authentication-user")
            let (password, _) = execCmdEx("gsettings get org.gnome.system.proxy.http authentication-password")
            
            result.username = username.strip().replace("'", "")
            result.password = password.strip().replace("'", "")
            result.authMethod = hpamBasic
          
          # バイパスリストを取得
          let (ignoreHosts, _) = execCmdEx("gsettings get org.gnome.system.proxy ignore-hosts")
          
          if ignoreHosts.len > 0:
            let hosts = ignoreHosts.strip()
            result.noProxyList = hosts.replace("[", "").replace("]", "").replace("'", "").split(", ")
      except:
        discard
      
      # KDEプロキシ設定を取得（GNOMEの設定が見つからない場合）
      if not result.enabled:
        try:
          let (output, exitCode) = execCmdEx("kreadconfig5 --file kioslaverc --group Proxy Settings --key ProxyType")
          
          if exitCode == 0 and output.strip() == "1":
            result.enabled = true
            
            # HTTPプロキシを取得
            let httpProxy = execCmdEx("kreadconfig5 --file kioslaverc --group Proxy Settings --key httpProxy").output.strip()
            
            if httpProxy.len > 0:
              let parts = httpProxy.split(' ')
              if parts.len >= 2:
                result.host = parts[0]
                try:
                  result.port = parseInt(parts[1])
                except:
                  result.port = 8080
            
            # バイパスリストを取得
            let noProxyList = execCmdEx("kreadconfig5 --file kioslaverc --group Proxy Settings --key NoProxyFor").output.strip()
            
            if noProxyList.len > 0:
              result.noProxyList = noProxyList.split(',')
        except:
          discard
  
  except Exception as e:
    echo "システムプロキシ設定の検出中にエラーが発生しました: ", e.msg

proc close*(client: HttpProxyClient) =
  ## HTTPプロキシクライアントを閉じる
  
  client.disconnect()
  client.logger.info("HTTP proxy client closed") 