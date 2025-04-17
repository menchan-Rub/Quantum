## FTPクライアント実装
##
## File Transfer Protocol（RFC 959）に準拠したクライアント実装を提供します。
## コマンドチャネル、データチャネルの管理、及び基本的なFTPコマンドの実行をサポートします。

import std/[asyncdispatch, asyncnet, net, options, strformat, strutils, times, uri, tables, os]
import ../../../core/logging/logger
import ../../security/tls/tls_client
import ./ftp_types

type
  FtpTransferMode* = enum
    ftmAscii,    # ASCIIモード（テキストファイル用）
    ftmBinary    # バイナリモード（バイナリファイル用）
  
  FtpListFormat* = enum
    flfUnix,     # UNIXスタイルのリスト形式
    flfWindows,  # Windowsスタイルのリスト形式
    flfUnknown   # 不明なリスト形式
  
  FtpClient* = ref object
    ## FTPクライアント
    host*: string                  # ホスト名
    port*: int                     # ポート番号
    username*: string              # ユーザー名
    password*: string              # パスワード
    passive*: bool                 # パッシブモードフラグ
    secure*: bool                  # セキュア接続（FTPS）フラグ
    explicitTls*: bool             # 明示的TLS（FTPES）フラグ
    transferMode*: FtpTransferMode # 転送モード
    timeout*: int                  # タイムアウト（秒）
    connected*: bool               # 接続状態
    authenticated*: bool           # 認証状態
    commandSocket: AsyncSocket     # コマンドチャネルソケット
    tlsCommandSocket: Option[AsyncTlsSocket]  # TLS使用時のコマンドソケット
    dataSocket: AsyncSocket        # データチャネルソケット
    tlsDataSocket: Option[AsyncTlsSocket]  # TLS使用時のデータソケット
    logger: Logger                 # ロガー
    currentDir*: string            # 現在のディレクトリ
    features*: Table[string, string]  # サーバー機能
    listFormat*: FtpListFormat     # リスト表示形式
    welcomeMessage*: string        # ウェルカムメッセージ
    lastResponse*: FtpResponse     # 最後のレスポンス
    lastCommand*: string           # 最後のコマンド

# 定数
const 
  DefaultFtpPort = 21
  DefaultFtpTimeout = 60  # 60秒
  CR_LF = "\r\n"
  FtpBufferSize = 8192    # 8KB

proc newFtpClient*(host: string, 
                  port: int = DefaultFtpPort,
                  username: string = "anonymous",
                  password: string = "",
                  passive: bool = true,
                  secure: bool = false,
                  explicitTls: bool = true,
                  transferMode: FtpTransferMode = ftmBinary,
                  timeout: int = DefaultFtpTimeout,
                  logger: Logger = nil): FtpClient =
  ## 新しいFTPクライアントを作成する
  ##
  ## 引数:
  ##   host: FTPサーバーのホスト名
  ##   port: FTPサーバーのポート番号（デフォルト: 21）
  ##   username: ユーザー名（デフォルト: "anonymous"）
  ##   password: パスワード
  ##   passive: パッシブモードを使用するかどうか（デフォルト: true）
  ##   secure: FTPS（FTP over SSL/TLS）を使用するかどうか（デフォルト: false）
  ##   explicitTls: 明示的TLSを使用するかどうか（デフォルト: true）
  ##   transferMode: 転送モード（デフォルト: バイナリ）
  ##   timeout: タイムアウト時間（秒）（デフォルト: 60秒）
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   FtpClientオブジェクト
  
  let clientLogger = if logger.isNil: newLogger("FtpClient") else: logger
  
  result = FtpClient(
    host: host,
    port: port,
    username: username,
    password: password,
    passive: passive,
    secure: secure,
    explicitTls: explicitTls,
    transferMode: transferMode,
    timeout: timeout,
    connected: false,
    authenticated: false,
    commandSocket: nil,
    tlsCommandSocket: none(AsyncTlsSocket),
    dataSocket: nil,
    tlsDataSocket: none(AsyncTlsSocket),
    logger: clientLogger,
    currentDir: "/",
    features: initTable[string, string](),
    listFormat: flfUnknown,
    welcomeMessage: "",
    lastResponse: FtpResponse(code: 0, message: ""),
    lastCommand: ""
  )

proc sendCommand(client: FtpClient, command: string): Future[FtpResponse] {.async.} =
  ## FTPコマンドを送信し、レスポンスを受信する
  ##
  ## 引数:
  ##   command: 送信するFTPコマンド
  ##
  ## 戻り値:
  ##   FTPサーバーからのレスポンス
  
  if not client.connected:
    return FtpResponse(code: 0, message: "Not connected to FTP server")
  
  client.lastCommand = command
  client.logger.debug(fmt"Sending FTP command: {command}")
  
  try:
    # コマンドをCR+LFで終端して送信
    let commandStr = command & CR_LF
    if client.secure and client.tlsCommandSocket.isSome:
      await client.tlsCommandSocket.get().send(commandStr)
    else:
      await client.commandSocket.send(commandStr)
    
    # レスポンスを受信
    var response = ""
    var buffer = newString(FtpBufferSize)
    var multilineResponse = false
    var responseCode = 0
    
    while true:
      var bytesRead = 0
      if client.secure and client.tlsCommandSocket.isSome:
        bytesRead = await client.tlsCommandSocket.get().recv(buffer, 0, FtpBufferSize)
      else:
        bytesRead = await client.commandSocket.recv(buffer, 0, FtpBufferSize)
      
      if bytesRead <= 0:
        break
      
      response &= buffer[0..<bytesRead]
      
      # レスポンスの終了を検出
      let lines = response.splitLines()
      if lines.len > 0:
        # 最初の行からレスポンスコードを抽出
        if responseCode == 0 and lines[0].len >= 3:
          try:
            responseCode = parseInt(lines[0][0..2])
            
            # マルチライン応答の開始をチェック
            if lines[0].len >= 4 and lines[0][3] == '-':
              multilineResponse = true
          except ValueError:
            # レスポンスコードの解析に失敗
            client.logger.warn(fmt"Failed to parse FTP response code: {lines[0]}")
        
        # マルチライン応答の終了をチェック
        if multilineResponse and lines.len >= 2:
          let lastLine = lines[^1]
          if lastLine.len >= 3 and lastLine[0..2] == $responseCode and 
              (lastLine.len == 3 or lastLine[3] == ' '):
            break
        elif not multilineResponse and lines.len >= 1 and lines[0].len >= 3:
          # 単一行レスポンスの場合
          break
      
      # バッファが大きすぎる場合はエラー
      if response.len > 100 * 1024:  # 100KB以上
        raise newException(IOError, "FTP response too large")
    
    # レスポンスを解析
    let responseObj = parseFtpResponse(response)
    client.lastResponse = responseObj
    
    client.logger.debug(fmt"Received FTP response: {responseObj.code} {responseObj.message}")
    return responseObj
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error sending FTP command: {errMsg}")
    return FtpResponse(code: 0, message: fmt"Error: {errMsg}")

proc connect*(client: FtpClient): Future[bool] {.async.} =
  ## FTPサーバーに接続する
  ##
  ## 戻り値:
  ##   接続成功の場合はtrue、失敗の場合はfalse
  
  if client.connected:
    client.logger.warn("Already connected to FTP server")
    return true
  
  client.logger.info(fmt"Connecting to FTP server: {client.host}:{client.port}")
  
  try:
    # コマンドソケットを作成
    client.commandSocket = newAsyncSocket()
    await client.commandSocket.connect(client.host, Port(client.port))
    
    # タイムアウトを設定
    client.commandSocket.setSockOpt(OptSoRcvTimeo, client.timeout * 1000)
    client.commandSocket.setSockOpt(OptSoSndTimeo, client.timeout * 1000)
    
    # ウェルカムメッセージを受信
    var welcomeResponse = FtpResponse(code: 0, message: "")
    var buffer = newString(FtpBufferSize)
    var response = ""
    
    while true:
      let bytesRead = await client.commandSocket.recv(buffer, 0, FtpBufferSize)
      if bytesRead <= 0:
        break
      
      response &= buffer[0..<bytesRead]
      
      # レスポンス終了を検出
      if response.endsWith(CR_LF) and response.len >= 3:
        let lines = response.splitLines()
        if lines.len > 0 and lines[^1].len >= 3:
          let lastLine = lines[^1]
          if (lastLine.len >= 4 and lastLine[3] == ' ') or lastLine.len == 3:
            try:
              let code = parseInt(lastLine[0..2])
              if 200 <= code and code < 300:
                welcomeResponse = parseFtpResponse(response)
                break
            except ValueError:
              discard
      
      # バッファが大きすぎる場合はエラー
      if response.len > 10 * 1024:  # 10KB以上
        raise newException(IOError, "Welcome message too large")
    
    client.welcomeMessage = welcomeResponse.message
    client.lastResponse = welcomeResponse
    
    # 接続結果をチェック
    if welcomeResponse.code < 200 or welcomeResponse.code >= 300:
      client.logger.error(fmt"FTP connection failed: {welcomeResponse.code} {welcomeResponse.message}")
      return false
    
    client.connected = true
    client.logger.info(fmt"Connected to FTP server: {welcomeResponse.code} {welcomeResponse.message}")
    
    # TLS接続の場合、明示的TLSを開始
    if client.secure and client.explicitTls:
      let authResponse = await client.sendCommand("AUTH TLS")
      if authResponse.code != 234:
        client.logger.error(fmt"TLS authentication failed: {authResponse.code} {authResponse.message}")
        return false
      
      # TLSハンドシェイク
      let tlsConfig = newTlsConfig()
      let tlsSocket = newAsyncTlsSocket(client.commandSocket, tlsConfig, client.host)
      await tlsSocket.handshake()
      client.tlsCommandSocket = some(tlsSocket)
      
      # TLS接続後の追加認証
      let pbszResponse = await client.sendCommand("PBSZ 0")
      if pbszResponse.code != 200:
        client.logger.warn(fmt"PBSZ command failed: {pbszResponse.code} {pbszResponse.message}")
      
      let protResponse = await client.sendCommand("PROT P")
      if protResponse.code != 200:
        client.logger.warn(fmt"PROT command failed: {protResponse.code} {protResponse.message}")
    
    # サーバー機能を取得
    let featResponse = await client.sendCommand("FEAT")
    if featResponse.code == 211:
      client.features = parseFtpFeatures(featResponse.message)
    
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"FTP connection error: {errMsg}")
    
    # ソケットをクローズ
    if not client.commandSocket.isNil:
      client.commandSocket.close()
      client.commandSocket = nil
    
    if client.tlsCommandSocket.isSome:
      client.tlsCommandSocket = none(AsyncTlsSocket)
    
    client.connected = false
    return false

proc login*(client: FtpClient): Future[bool] {.async.} =
  ## FTPサーバーにログインする
  ##
  ## 戻り値:
  ##   ログイン成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected:
    let connected = await client.connect()
    if not connected:
      return false
  
  if client.authenticated:
    client.logger.warn("Already authenticated to FTP server")
    return true
  
  client.logger.info(fmt"Logging in to FTP server as user: {client.username}")
  
  # ユーザー名を送信
  let userResponse = await client.sendCommand(fmt"USER {client.username}")
  if userResponse.code != 331 and userResponse.code != 230:
    client.logger.error(fmt"USER command failed: {userResponse.code} {userResponse.message}")
    return false
  
  # 230: ログイン不要（匿名アクセスなど）
  if userResponse.code == 230:
    client.authenticated = true
    client.logger.info("Logged in to FTP server (no password required)")
    return true
  
  # パスワードを送信
  let passResponse = await client.sendCommand(fmt"PASS {client.password}")
  if passResponse.code != 230:
    client.logger.error(fmt"PASS command failed: {passResponse.code} {passResponse.message}")
    return false
  
  client.authenticated = true
  client.logger.info("Logged in to FTP server successfully")
  
  # システムタイプを取得
  let systResponse = await client.sendCommand("SYST")
  if systResponse.code == 215:
    if systResponse.message.contains("UNIX"):
      client.listFormat = flfUnix
    elif systResponse.message.contains("WINDOWS") or systResponse.message.contains("WIN32"):
      client.listFormat = flfWindows
    
    client.logger.debug(fmt"FTP server system: {systResponse.message}")
  
  # 転送モードを設定
  var typeCmd = if client.transferMode == ftmAscii: "TYPE A" else: "TYPE I"
  let typeResponse = await client.sendCommand(typeCmd)
  if typeResponse.code != 200:
    client.logger.warn(fmt"TYPE command failed: {typeResponse.code} {typeResponse.message}")
  
  # 現在のディレクトリを取得
  let pwdResponse = await client.sendCommand("PWD")
  if pwdResponse.code == 257:
    client.currentDir = extractPathFromPwd(pwdResponse.message)
    client.logger.debug(fmt"Current directory: {client.currentDir}")
  
  return true

proc openDataConnection(client: FtpClient): Future[bool] {.async.} =
  ## データ接続を開く
  ##
  ## 戻り値:
  ##   接続成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    client.logger.error("Cannot open data connection: not connected or not authenticated")
    return false
  
  try:
    if client.passive:
      # パッシブモード
      let pasvResponse = await client.sendCommand("PASV")
      if pasvResponse.code != 227:
        client.logger.error(fmt"PASV command failed: {pasvResponse.code} {pasvResponse.message}")
        return false
      
      # PASVレスポンスからホストとポートを抽出
      let (host, port) = extractHostPortFromPasv(pasvResponse.message)
      if port <= 0:
        client.logger.error(fmt"Failed to parse PASV response: {pasvResponse.message}")
        return false
      
      client.logger.debug(fmt"Opening passive data connection to {host}:{port}")
      
      # データソケットを作成して接続
      client.dataSocket = newAsyncSocket()
      try:
        await client.dataSocket.connect(host, Port(port))
      except:
        let errMsg = getCurrentExceptionMsg()
        client.logger.error(fmt"Failed to connect to {host}:{port}: {errMsg}")
        client.dataSocket.close()
        client.dataSocket = nil
        return false
      
      # TLSを使用する場合
      if client.secure:
        try:
          let tlsConfig = newTlsConfig()
          # サーバー証明書の検証設定
          if client.verifySSL:
            tlsConfig.verify = true
            tlsConfig.verifyMode = CVerifyPeer
          else:
            tlsConfig.verify = false
            tlsConfig.verifyMode = CVerifyNone
          
          let tlsSocket = newAsyncTlsSocket(client.dataSocket, tlsConfig, client.host)
          await tlsSocket.handshake()
          client.tlsDataSocket = some(tlsSocket)
        except:
          let errMsg = getCurrentExceptionMsg()
          client.logger.error(fmt"TLS handshake failed for data connection: {errMsg}")
          client.dataSocket.close()
          client.dataSocket = nil
          return false
      
      client.logger.debug("Data connection established successfully")
      return true
    else:
      # アクティブモード
      client.logger.debug("Using active mode for data connection")
      
      # ローカルアドレスとポートを取得
      let localAddr = client.controlSocket.getLocalAddr()
      let localIp = localAddr[0]
      
      # ランダムなポートを選択
      var serverSocket = newAsyncSocket()
      serverSocket.setSockOpt(OptReuseAddr, true)
      
      # 任意のポートでリッスン開始
      serverSocket.bindAddr(Port(0), localIp)
      serverSocket.listen()
      
      # バインドされたポートを取得
      let boundPort = serverSocket.getLocalAddr()[1]
      
      # IPアドレスをカンマ区切りに変換
      let ipParts = localIp.split('.')
      if ipParts.len != 4:
        client.logger.error(fmt"Invalid local IP address format: {localIp}")
        serverSocket.close()
        return false
      
      # ポートをPORTコマンド用に変換 (p1 * 256 + p2)
      let p1 = boundPort div 256
      let p2 = boundPort mod 256
      
      # PORTコマンドを送信
      let portCmd = fmt"PORT {ipParts[0]},{ipParts[1]},{ipParts[2]},{ipParts[3]},{p1},{p2}"
      let portResponse = await client.sendCommand(portCmd)
      
      if portResponse.code != 200:
        client.logger.error(fmt"PORT command failed: {portResponse.code} {portResponse.message}")
        serverSocket.close()
        return false
      
      # クライアントからの接続を待機
      client.dataSocket = await serverSocket.accept()
      serverSocket.close()
      
      # TLSを使用する場合
      if client.secure:
        try:
          let tlsConfig = newTlsConfig()
          if client.verifySSL:
            tlsConfig.verify = true
            tlsConfig.verifyMode = CVerifyPeer
          else:
            tlsConfig.verify = false
            tlsConfig.verifyMode = CVerifyNone
          
          let tlsSocket = newAsyncTlsSocket(client.dataSocket, tlsConfig, client.host)
          await tlsSocket.handshake()
          client.tlsDataSocket = some(tlsSocket)
        except:
          let errMsg = getCurrentExceptionMsg()
          client.logger.error(fmt"TLS handshake failed for data connection: {errMsg}")
          client.dataSocket.close()
          client.dataSocket = nil
          return false
      
      client.logger.debug("Active data connection established successfully")
      return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error opening data connection: {errMsg}")
    
    # 接続失敗時のクリーンアップ
    if not client.dataSocket.isNil:
      try:
        client.dataSocket.close()
      except:
        discard
      client.dataSocket = nil
    
    if client.tlsDataSocket.isSome:
      try:
        client.tlsDataSocket.get().close()
      except:
        discard
      client.tlsDataSocket = none(AsyncTlsSocket)
    
    return false

proc closeDataConnection(client: FtpClient) =
  ## データ接続を閉じる
  
  # TLSデータソケットを閉じる
  if client.tlsDataSocket.isSome:
    try:
      client.tlsDataSocket.get().close()
    except:
      client.logger.warn(fmt"Error closing TLS data socket: {getCurrentExceptionMsg()}")
    client.tlsDataSocket = none(AsyncTlsSocket)
  
  # データソケットを閉じる
  if not client.dataSocket.isNil:
    try:
      client.dataSocket.close()
    except:
      client.logger.warn(fmt"Error closing data socket: {getCurrentExceptionMsg()}")
    client.dataSocket = nil

proc listFiles*(client: FtpClient, path: string = ""): Future[seq[FtpFileInfo]] {.async.} =
  ## ディレクトリ内のファイル一覧を取得する
  ##
  ## 引数:
  ##   path: リストを取得するパス（空の場合は現在のディレクトリ）
  ##
  ## 戻り値:
  ##   ファイル情報のリスト
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return @[]
  
  # データ接続を開く
  let dataConnected = await client.openDataConnection()
  if not dataConnected:
    return @[]
  
  # LISTコマンドを送信
  var command = "LIST"
  if path.len > 0:
    command &= " " & path
  
  let listResponse = await client.sendCommand(command)
  if listResponse.code != 150 and listResponse.code != 125:
    client.logger.error(fmt"LIST command failed: {listResponse.code} {listResponse.message}")
    client.closeDataConnection()
    return @[]
  
  # データを受信
  var listData = ""
  var buffer = newString(FtpBufferSize)
  
  try:
    while true:
      var bytesRead = 0
      if client.secure and client.tlsDataSocket.isSome:
        bytesRead = await client.tlsDataSocket.get().recv(buffer, 0, FtpBufferSize)
      else:
        bytesRead = await client.dataSocket.recv(buffer, 0, FtpBufferSize)
      
      if bytesRead <= 0:
        break
      
      listData &= buffer[0..<bytesRead]
    
    # データ接続を閉じる
    client.closeDataConnection()
    
    # 転送完了を確認
    let transferResponse = await client.sendCommand("")  # サーバーからのレスポンスを待機
    if transferResponse.code != 226 and transferResponse.code != 250:
      client.logger.warn(fmt"LIST data transfer completion: {transferResponse.code} {transferResponse.message}")
    
    # リスト形式が不明な場合は推測
    if client.listFormat == flfUnknown:
      client.listFormat = detectListFormat(listData)
    
    # リストを解析
    return parseFtpListing(listData, client.listFormat)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error receiving LIST data: {errMsg}")
    client.closeDataConnection()
    return @[]

proc changeDirectory*(client: FtpClient, path: string): Future[bool] {.async.} =
  ## ディレクトリを変更する
  ##
  ## 引数:
  ##   path: 変更先のパス
  ##
  ## 戻り値:
  ##   変更成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  let cdResponse = await client.sendCommand(fmt"CWD {path}")
  if cdResponse.code != 250:
    client.logger.error(fmt"CWD command failed: {cdResponse.code} {cdResponse.message}")
    return false
  
  # 現在のディレクトリを更新
  let pwdResponse = await client.sendCommand("PWD")
  if pwdResponse.code == 257:
    client.currentDir = extractPathFromPwd(pwdResponse.message)
    client.logger.debug(fmt"Changed directory to: {client.currentDir}")
  
  return true

proc downloadFile*(client: FtpClient, remotePath: string, localPath: string): Future[bool] {.async.} =
  ## ファイルをダウンロードする
  ##
  ## 引数:
  ##   remotePath: リモートファイルパス
  ##   localPath: ローカル保存先パス
  ##
  ## 戻り値:
  ##   ダウンロード成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  # 転送モードを設定
  let typeCmd = if client.transferMode == ftmAscii: "TYPE A" else: "TYPE I"
  let typeResponse = await client.sendCommand(typeCmd)
  if typeResponse.code != 200:
    client.logger.warn(fmt"TYPE command failed: {typeResponse.code} {typeResponse.message}")
  
  # データ接続を開く
  let dataConnected = await client.openDataConnection()
  if not dataConnected:
    return false
  
  # RETRコマンドを送信
  let retrResponse = await client.sendCommand(fmt"RETR {remotePath}")
  if retrResponse.code != 150 and retrResponse.code != 125:
    client.logger.error(fmt"RETR command failed: {retrResponse.code} {retrResponse.message}")
    client.closeDataConnection()
    return false
  
  # ローカルファイルを開く
  var file: File
  try:
    file = open(localPath, fmWrite)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to open local file: {errMsg}")
    client.closeDataConnection()
    return false
  
  # データを受信してファイルに書き込む
  var buffer = newString(FtpBufferSize)
  var totalBytes: int64 = 0
  
  try:
    while true:
      var bytesRead = 0
      if client.secure and client.tlsDataSocket.isSome:
        bytesRead = await client.tlsDataSocket.get().recv(buffer, 0, FtpBufferSize)
      else:
        bytesRead = await client.dataSocket.recv(buffer, 0, FtpBufferSize)
      
      if bytesRead <= 0:
        break
      
      file.writeBuffer(addr buffer[0], bytesRead)
      totalBytes += bytesRead
    
    # ファイルを閉じる
    file.close()
    
    # データ接続を閉じる
    client.closeDataConnection()
    
    # 転送完了を確認
    let transferResponse = await client.sendCommand("")  # サーバーからのレスポンスを待機
    if transferResponse.code != 226 and transferResponse.code != 250:
      client.logger.warn(fmt"RETR data transfer completion: {transferResponse.code} {transferResponse.message}")
    
    client.logger.info(fmt"Downloaded file {remotePath} to {localPath} ({totalBytes} bytes)")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error downloading file: {errMsg}")
    
    # ファイルを閉じる
    try:
      file.close()
    except:
      discard
    
    client.closeDataConnection()
    return false

proc uploadFile*(client: FtpClient, localPath: string, remotePath: string): Future[bool] {.async.} =
  ## ファイルをアップロードする
  ##
  ## 引数:
  ##   localPath: ローカルファイルパス
  ##   remotePath: リモート保存先パス
  ##
  ## 戻り値:
  ##   アップロード成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  # ローカルファイルを開く
  var file: File
  try:
    file = open(localPath, fmRead)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to open local file: {errMsg}")
    return false
  
  # 転送モードを設定
  let typeCmd = if client.transferMode == ftmAscii: "TYPE A" else: "TYPE I"
  let typeResponse = await client.sendCommand(typeCmd)
  if typeResponse.code != 200:
    client.logger.warn(fmt"TYPE command failed: {typeResponse.code} {typeResponse.message}")
  
  # データ接続を開く
  let dataConnected = await client.openDataConnection()
  if not dataConnected:
    file.close()
    return false
  
  # STORコマンドを送信
  let storResponse = await client.sendCommand(fmt"STOR {remotePath}")
  if storResponse.code != 150 and storResponse.code != 125:
    client.logger.error(fmt"STOR command failed: {storResponse.code} {storResponse.message}")
    client.closeDataConnection()
    file.close()
    return false
  
  # ファイルデータを送信
  var buffer = newString(FtpBufferSize)
  var totalBytes: int64 = 0
  
  try:
    while not file.endOfFile():
      let bytesRead = file.readBuffer(addr buffer[0], FtpBufferSize)
      if bytesRead <= 0:
        break
      
      if client.secure and client.tlsDataSocket.isSome:
        await client.tlsDataSocket.get().send(buffer[0..<bytesRead])
      else:
        await client.dataSocket.send(buffer[0..<bytesRead])
      
      totalBytes += bytesRead
    
    # ファイルを閉じる
    file.close()
    
    # データ接続を閉じる
    client.closeDataConnection()
    
    # 転送完了を確認
    let transferResponse = await client.sendCommand("")  # サーバーからのレスポンスを待機
    if transferResponse.code != 226 and transferResponse.code != 250:
      client.logger.warn(fmt"STOR data transfer completion: {transferResponse.code} {transferResponse.message}")
    
    client.logger.info(fmt"Uploaded file {localPath} to {remotePath} ({totalBytes} bytes)")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error uploading file: {errMsg}")
    
    # ファイルを閉じる
    try:
      file.close()
    except:
      discard
    
    client.closeDataConnection()
    return false

proc deleteFile*(client: FtpClient, path: string): Future[bool] {.async.} =
  ## ファイルを削除する
  ##
  ## 引数:
  ##   path: 削除するファイルのパス
  ##
  ## 戻り値:
  ##   削除成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  let deleResponse = await client.sendCommand(fmt"DELE {path}")
  if deleResponse.code != 250:
    client.logger.error(fmt"DELE command failed: {deleResponse.code} {deleResponse.message}")
    return false
  
  client.logger.info(fmt"Deleted file: {path}")
  return true

proc makeDirectory*(client: FtpClient, path: string): Future[bool] {.async.} =
  ## ディレクトリを作成する
  ##
  ## 引数:
  ##   path: 作成するディレクトリのパス
  ##
  ## 戻り値:
  ##   作成成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  let mkdResponse = await client.sendCommand(fmt"MKD {path}")
  if mkdResponse.code != 257:
    client.logger.error(fmt"MKD command failed: {mkdResponse.code} {mkdResponse.message}")
    return false
  
  client.logger.info(fmt"Created directory: {path}")
  return true

proc removeDirectory*(client: FtpClient, path: string): Future[bool] {.async.} =
  ## ディレクトリを削除する
  ##
  ## 引数:
  ##   path: 削除するディレクトリのパス
  ##
  ## 戻り値:
  ##   削除成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  let rmdResponse = await client.sendCommand(fmt"RMD {path}")
  if rmdResponse.code != 250:
    client.logger.error(fmt"RMD command failed: {rmdResponse.code} {rmdResponse.message}")
    return false
  
  client.logger.info(fmt"Removed directory: {path}")
  return true

proc rename*(client: FtpClient, fromPath: string, toPath: string): Future[bool] {.async.} =
  ## ファイルやディレクトリの名前を変更する
  ##
  ## 引数:
  ##   fromPath: 元のパス
  ##   toPath: 新しいパス
  ##
  ## 戻り値:
  ##   名前変更成功の場合はtrue、失敗の場合はfalse
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return false
  
  # RNFRコマンドを送信
  let rnfrResponse = await client.sendCommand(fmt"RNFR {fromPath}")
  if rnfrResponse.code != 350:
    client.logger.error(fmt"RNFR command failed: {rnfrResponse.code} {rnfrResponse.message}")
    return false
  
  # RNTOコマンドを送信
  let rntoResponse = await client.sendCommand(fmt"RNTO {toPath}")
  if rntoResponse.code != 250:
    client.logger.error(fmt"RNTO command failed: {rntoResponse.code} {rntoResponse.message}")
    return false
  
  client.logger.info(fmt"Renamed {fromPath} to {toPath}")
  return true

proc getFileSize*(client: FtpClient, path: string): Future[int64] {.async.} =
  ## ファイルサイズを取得する
  ##
  ## 引数:
  ##   path: ファイルパス
  ##
  ## 戻り値:
  ##   ファイルサイズ（バイト）、エラーの場合は-1
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return -1
  
  let sizeResponse = await client.sendCommand(fmt"SIZE {path}")
  if sizeResponse.code != 213:
    client.logger.error(fmt"SIZE command failed: {sizeResponse.code} {sizeResponse.message}")
    return -1
  
  try:
    let sizeStr = sizeResponse.message.strip()
    return parseBiggestInt(sizeStr)
  except:
    client.logger.error(fmt"Failed to parse file size: {sizeResponse.message}")
    return -1

proc getModificationTime*(client: FtpClient, path: string): Future[Time] {.async.} =
  ## ファイルの最終更新時刻を取得する
  ##
  ## 引数:
  ##   path: ファイルパス
  ##
  ## 戻り値:
  ##   ファイルの最終更新時刻、エラーの場合は現在時刻
  
  if not client.connected or not client.authenticated:
    let loggedIn = await client.login()
    if not loggedIn:
      return getTime()
  
  let mdtmResponse = await client.sendCommand(fmt"MDTM {path}")
  if mdtmResponse.code != 213:
    client.logger.error(fmt"MDTM command failed: {mdtmResponse.code} {mdtmResponse.message}")
    return getTime()
  
  try:
    return parseFtpTimeStamp(mdtmResponse.message.strip())
  except:
    client.logger.error(fmt"Failed to parse modification time: {mdtmResponse.message}")
    return getTime()

proc disconnect*(client: FtpClient) {.async.} =
  ## FTPサーバーから切断する
  
  if not client.connected:
    return
  
  # QUITコマンドを送信
  try:
    let quitResponse = await client.sendCommand("QUIT")
    client.logger.info(fmt"FTP disconnect: {quitResponse.code} {quitResponse.message}")
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.warn(fmt"Error sending QUIT command: {errMsg}")
  
  # データ接続を閉じる
  client.closeDataConnection()
  
  # コマンドソケットを閉じる
  if client.tlsCommandSocket.isSome:
    try:
      client.tlsCommandSocket.get().close()
    except:
      client.logger.warn(fmt"Error closing TLS command socket: {getCurrentExceptionMsg()}")
    client.tlsCommandSocket = none(AsyncTlsSocket)
  
  if not client.commandSocket.isNil:
    try:
      client.commandSocket.close()
    except:
      client.logger.warn(fmt"Error closing command socket: {getCurrentExceptionMsg()}")
    client.commandSocket = nil
  
  client.connected = false
  client.authenticated = false
  client.logger.info("Disconnected from FTP server") 