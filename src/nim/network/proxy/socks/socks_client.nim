## SOCKSプロキシクライアント実装
##
## SOCKS4/SOCKS5プロキシプロトコルを実装したクライアントライブラリです。
## RFC 1928 (SOCKS Protocol Version 5) に準拠しています。

import std/[asyncdispatch, asyncnet, base64, net, options, strformat, strutils, tables, times, uri]
import ../../../core/logging/logger
import ../../security/tls/tls_client
import ./socks_types

type
  SocksClient* = ref object
    ## SOCKSプロキシクライアント
    host*: string                    # プロキシホスト
    port*: int                       # プロキシポート
    username*: string                # 認証ユーザー名（SOCKS5のみ）
    password*: string                # 認証パスワード（SOCKS5のみ）
    version*: SocksVersion           # SOCKSプロトコルバージョン
    connectTimeout*: int             # 接続タイムアウト（ミリ秒）
    requestTimeout*: int             # リクエストタイムアウト（ミリ秒）
    maxConnections*: int             # 最大同時接続数
    connectionPool: Table[string, seq[AsyncSocket]]  # 接続プール
    logger: Logger                   # ロガー
    lastActivity*: Time              # 最後のアクティビティ時間
    isActive*: bool                  # アクティブフラグ

const
  DefaultSocksPort = 1080           # デフォルトSOCKSポート
  DefaultConnectTimeout = 30000     # デフォルト接続タイムアウト（30秒）
  DefaultRequestTimeout = 60000     # デフォルトリクエストタイムアウト（60秒）
  DefaultMaxConnections = 6         # デフォルト最大同時接続数

proc newSocksClient*(host: string, 
                    port: int = DefaultSocksPort,
                    version: SocksVersion = svSocks5,
                    username: string = "", 
                    password: string = "",
                    connectTimeout: int = DefaultConnectTimeout,
                    requestTimeout: int = DefaultRequestTimeout,
                    maxConnections: int = DefaultMaxConnections,
                    logger: Logger = nil): SocksClient =
  ## 新しいSOCKSプロキシクライアントを作成する
  ##
  ## 引数:
  ##   host: プロキシサーバーのホスト名またはIP
  ##   port: プロキシサーバーのポート（デフォルト: 1080）
  ##   version: SOCKSプロトコルバージョン（デフォルト: SOCKS5）
  ##   username: プロキシ認証用ユーザー名（SOCKS5のみ、オプション）
  ##   password: プロキシ認証用パスワード（SOCKS5のみ、オプション）
  ##   connectTimeout: 接続タイムアウト（ミリ秒）
  ##   requestTimeout: リクエストタイムアウト（ミリ秒）
  ##   maxConnections: 最大同時接続数
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   SocksClientオブジェクト
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("SocksClient") else: logger
  
  result = SocksClient(
    host: host,
    port: port,
    username: username,
    password: password,
    version: version,
    connectTimeout: connectTimeout,
    requestTimeout: requestTimeout,
    maxConnections: maxConnections,
    connectionPool: initTable[string, seq[AsyncSocket]](),
    logger: clientLogger,
    lastActivity: getTime(),
    isActive: true
  )

proc getConnectionKey(targetHost: string, targetPort: int): string =
  ## 接続プールのキーを生成する
  result = fmt"{targetHost}:{targetPort}"

proc getOrCreateConnection(client: SocksClient): Future[AsyncSocket] {.async.} =
  ## SOCKSプロキシサーバーへの接続を取得または新規作成する
  
  # 新しい接続を作成
  client.logger.debug(fmt"Creating new connection to SOCKS{client.version} proxy {client.host}:{client.port}")
  
  var socket = newAsyncSocket()
  # タイムアウトを設定
  socket.setSockOpt(OptSendTimeout, client.connectTimeout)
  socket.setSockOpt(OptRecvTimeout, client.requestTimeout)
  
  try:
    await withTimeout(socket.connect(client.host, Port(client.port)), client.connectTimeout):
      raise newException(TimeoutError, "Connection to SOCKS proxy timed out")
    
    client.lastActivity = getTime()
    return socket
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Failed to connect to SOCKS proxy: {errMsg}")
    socket.close()
    raise

proc returnConnection(client: SocksClient, socket: AsyncSocket, targetHost: string, targetPort: int) =
  ## 接続をプールに返却する
  ##
  ## 引数:
  ##   socket: 返却するソケット
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  
  let key = getConnectionKey(targetHost, targetPort)
  
  try:
    if not client.connectionPool.hasKey(key):
      client.connectionPool[key] = @[]
    
    # プール内の接続数をチェック
    if client.connectionPool[key].len < client.maxConnections:
      client.connectionPool[key].add(socket)
    else:
      socket.close()
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"Error returning connection to pool: {errMsg}")
    socket.close()

proc performSocks5Handshake(client: SocksClient, socket: AsyncSocket): Future[bool] {.async.} =
  ## SOCKS5ハンドシェイクを実行する
  ##
  ## 引数:
  ##   socket: SOCKSプロキシへの接続ソケット
  ##
  ## 戻り値:
  ##   ハンドシェイク成功の場合はtrue、失敗の場合はfalse
  
  client.logger.debug("Performing SOCKS5 handshake")
  
  # 認証方式のネゴシエーション
  var authRequest = "\x05\x02\x00\x02"  # VER=5, NMETHODS=2, NO_AUTH=0, USERNAME/PASSWORD=2
  
  try:
    # 認証方式のネゴシエーションリクエスト送信
    await socket.send(authRequest)
    
    # サーバーレスポンスの受信
    var authResponse = await socket.recv(2)
    if authResponse.len < 2:
      client.logger.error("Invalid SOCKS5 auth negotiation response (too short)")
      return false
    
    # サーバーレスポンスの検証
    if ord(authResponse[0]) != 5:
      client.logger.error(fmt"Invalid SOCKS5 version in response: {ord(authResponse[0])}")
      return false
    
    let authMethod = ord(authResponse[1])
    
    # 選択された認証方式に基づく処理
    case authMethod
    of 0:  # NO_AUTH
      client.logger.debug("SOCKS5 no authentication required")
      # 認証不要なので次のステップへ
    of 2:  # USERNAME/PASSWORD
      if client.username.len == 0:
        client.logger.error("SOCKS5 server requires authentication, but no credentials provided")
        return false
      
      client.logger.debug("SOCKS5 username/password authentication")
      
      # USERNAME/PASSWORD認証 (RFC 1929)
      var authData = "\x01"  # VER=1 for auth protocol
      authData.add(char(client.username.len))
      authData.add(client.username)
      authData.add(char(client.password.len))
      authData.add(client.password)
      
      await socket.send(authData)
      
      # 認証レスポンス受信
      var authVerifyResponse = await socket.recv(2)
      if authVerifyResponse.len < 2:
        client.logger.error("Invalid SOCKS5 auth verification response (too short)")
        return false
      
      if ord(authVerifyResponse[0]) != 1:
        client.logger.error(fmt"Invalid auth protocol version in response: {ord(authVerifyResponse[0])}")
        return false
      
      if ord(authVerifyResponse[1]) != 0:
        client.logger.error("SOCKS5 authentication failed")
        return false
      
      client.logger.debug("SOCKS5 authentication successful")
    of 0xFF:  # NO ACCEPTABLE METHODS
      client.logger.error("SOCKS5 server rejected all authentication methods")
      return false
    else:
      client.logger.error(fmt"Unsupported SOCKS5 authentication method: {authMethod}")
      return false
    
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"SOCKS5 handshake error: {errMsg}")
    return false

proc performSocks4Handshake(client: SocksClient, socket: AsyncSocket, 
                           targetHost: string, targetPort: int): Future[bool] {.async.} =
  ## SOCKS4ハンドシェイクを実行する
  ##
  ## 引数:
  ##   socket: SOCKSプロキシへの接続ソケット
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  ##
  ## 戻り値:
  ##   ハンドシェイク成功の場合はtrue、失敗の場合はfalse
  
  client.logger.debug(fmt"Performing SOCKS4 handshake for {targetHost}:{targetPort}")
  
  # SOCKS4リクエストパケットの構築
  var request = "\x04\x01"  # VER=4, CMD=1 (CONNECT)
  request.add(char((targetPort shr 8) and 0xFF))  # PORT高バイト
  request.add(char(targetPort and 0xFF))          # PORT低バイト
  
  # IPアドレスかホスト名かを判断
  var ipAddr: IpAddress
  try:
    ipAddr = targetHost.parseIpAddress()
    
    # IPv4アドレスの場合
    if ipAddr.family == IpAddressFamily.IPv4:
      let octets = ipAddr.address_v4
      for i in 0..3:
        request.add(char(octets[i]))
    else:
      # SOCKS4はIPv4のみサポート
      client.logger.error("SOCKS4 only supports IPv4 addresses")
      return false
  except:
    # ホスト名の場合はSOCKS4a形式を使用
    # SOCKS4aでは、IPアドレス部分に 0.0.0.x (x != 0) を設定し、
    # NULL終端のホスト名を後に続ける
    request.add("\x00\x00\x00\x01")  # 0.0.0.1
  
  # ユーザーID (オプション)
  if client.username.len > 0:
    request.add(client.username)
  
  # NULL終端
  request.add("\x00")
  
  # SOCKS4aの場合、ホスト名を追加
  if ipAddr.family != IpAddressFamily.IPv4:
    request.add(targetHost)
    request.add("\x00")  # NULL終端
  
  try:
    # リクエスト送信
    await socket.send(request)
    
    # レスポンス受信
    var response = await socket.recv(8)
    if response.len < 8:
      client.logger.error("Invalid SOCKS4 response (too short)")
      return false
    
    # レスポンスの検証
    if ord(response[0]) != 0:
      client.logger.error(fmt"Invalid SOCKS4 response VN field: {ord(response[0])}")
      return false
    
    let status = ord(response[1])
    case status
    of 90:  # Request granted
      client.logger.debug("SOCKS4 connection established")
      return true
    of 91:  # Request rejected or failed
      client.logger.error("SOCKS4 connection request rejected or failed")
    of 92:  # Request rejected: SOCKS server cannot connect to identd on the client
      client.logger.error("SOCKS4 request rejected (cannot connect to identd)")
    of 93:  # Request rejected: client program and identd report different user-ids
      client.logger.error("SOCKS4 request rejected (user-id mismatch)")
    else:
      client.logger.error(fmt"SOCKS4 unknown status code: {status}")
    
    return false
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"SOCKS4 handshake error: {errMsg}")
    return false

proc connect*(client: SocksClient, 
             targetHost: string, 
             targetPort: int, 
             secure: bool = false): Future[tuple[socket: AsyncSocket, tlsSocket: Option[AsyncTlsSocket]]] {.async.} =
  ## SOCKSプロキシを介して指定されたホストとポートに接続する
  ##
  ## 引数:
  ##   targetHost: 接続先ホスト
  ##   targetPort: 接続先ポート
  ##   secure: TLSを使用するかどうか
  ##
  ## 戻り値:
  ##   (AsyncSocket, Option[AsyncTlsSocket]) のタプル
  
  client.logger.info(fmt"Connecting to {targetHost}:{targetPort} via SOCKS{client.version} proxy")
  
  # プロキシへの接続を確立
  let socket = await client.getOrCreateConnection()
  
  try:
    # SOCKS バージョンに応じたハンドシェイク
    var handshakeSuccess: bool
    if client.version == svSocks5:
      handshakeSuccess = await client.performSocks5Handshake(socket)
      if not handshakeSuccess:
        socket.close()
        raise newException(SocksError, "SOCKS5 handshake failed")
      
      # SOCKS5 CONNECT コマンド
      var connectRequest = "\x05\x01\x00"  # VER=5, CMD=1 (CONNECT), RSV=0
      
      # DST.ADDR
      try:
        # まずIPアドレスとして解析を試みる
        let ipAddr = targetHost.parseIpAddress()
        
        if ipAddr.family == IpAddressFamily.IPv4:
          # IPv4アドレス (ATYP=1)
          connectRequest.add("\x01")
          let octets = ipAddr.address_v4
          for i in 0..3:
            connectRequest.add(char(octets[i]))
        elif ipAddr.family == IpAddressFamily.IPv6:
          # IPv6アドレス (ATYP=4)
          connectRequest.add("\x04")
          let octets = ipAddr.address_v6
          for i in 0..15:
            connectRequest.add(char(octets[i]))
      except:
        # ドメイン名 (ATYP=3)
        connectRequest.add("\x03")
        connectRequest.add(char(targetHost.len))
        connectRequest.add(targetHost)
      
      # DST.PORT
      connectRequest.add(char((targetPort shr 8) and 0xFF))  # PORT高バイト
      connectRequest.add(char(targetPort and 0xFF))          # PORT低バイト
      
      # CONNECTリクエスト送信
      await socket.send(connectRequest)
      
      # レスポンス受信
      var response = await socket.recv(4)
      if response.len < 4:
        client.logger.error("Invalid SOCKS5 command response (too short)")
        socket.close()
        raise newException(SocksError, "Invalid SOCKS5 response")
      
      # レスポンスの検証
      if ord(response[0]) != 5:
        client.logger.error(fmt"Invalid SOCKS5 version in response: {ord(response[0])}")
        socket.close()
        raise newException(SocksError, "Invalid SOCKS5 protocol version")
      
      let status = ord(response[1])
      if status != 0:
        var errorMsg = "SOCKS5 connection failed: "
        case status
        of 1: errorMsg &= "general failure"
        of 2: errorMsg &= "connection not allowed by ruleset"
        of 3: errorMsg &= "network unreachable"
        of 4: errorMsg &= "host unreachable"
        of 5: errorMsg &= "connection refused"
        of 6: errorMsg &= "TTL expired"
        of 7: errorMsg &= "command not supported"
        of 8: errorMsg &= "address type not supported"
        else: errorMsg &= fmt"unknown error code {status}"
        
        client.logger.error(errorMsg)
        socket.close()
        raise newException(SocksError, errorMsg)
      
      # アドレスタイプを確認
      let addrType = ord(response[3])
      
      # レスポンスの残りを読み取る（BND.ADDRとBND.PORT）
      var additionalBytes = 0
      case addrType
      of 1:  # IPv4
        additionalBytes = 4 + 2  # 4オクテット + 2バイトポート
      of 3:  # ドメイン名
        let domainLen = ord(await socket.recv(1)[0])
        additionalBytes = domainLen + 2  # ドメイン名 + 2バイトポート
      of 4:  # IPv6
        additionalBytes = 16 + 2  # 16オクテット + 2バイトポート
      else:
        client.logger.error(fmt"Unsupported SOCKS5 address type: {addrType}")
        socket.close()
        raise newException(SocksError, "Unsupported address type")
      
      # 残りのレスポンスを読み取り（ただし使用しない）
      discard await socket.recv(additionalBytes)
    else:
      # SOCKS4/4aハンドシェイク
      handshakeSuccess = await client.performSocks4Handshake(socket, targetHost, targetPort)
      if not handshakeSuccess:
        socket.close()
        raise newException(SocksError, "SOCKS4 handshake failed")
    
    client.logger.info(fmt"Connection to {targetHost}:{targetPort} established via SOCKS proxy")
    
    # 接続先がTLSの場合、TLSハンドシェイクを実行
    if secure:
      client.logger.debug(fmt"Initiating TLS handshake with {targetHost}")
      
      let tlsConfig = newTlsConfig()
      let tlsSocket = newAsyncTlsSocket(socket, tlsConfig, targetHost)
      
      await withTimeout(tlsSocket.handshake(), client.connectTimeout):
        raise newException(TimeoutError, fmt"TLS handshake with {targetHost} timed out")
      
      client.logger.debug(fmt"TLS handshake with {targetHost} completed")
      return (socket, some(tlsSocket))
    
    return (socket, none(AsyncTlsSocket))
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.error(fmt"SOCKS connection error: {errMsg}")
    
    # エラーが発生した場合は接続をクリーンアップ
    socket.close()
    raise

proc close*(client: SocksClient) =
  ## SOCKSプロキシクライアントを閉じる
  client.isActive = false
  
  # プール内のすべての接続を閉じる
  for key, connectionList in client.connectionPool:
    for socket in connectionList:
      try:
        socket.close()
      except:
        discard
  
  client.connectionPool.clear()
  
  client.logger.info("SocksClient closed")

proc clearConnectionPool*(client: SocksClient) =
  ## 接続プールをクリアする
  
  # プール内のすべての接続を閉じる
  for key, connectionList in client.connectionPool:
    for socket in connectionList:
      try:
        socket.close()
      except:
        discard
  
  client.connectionPool.clear()
  
  client.logger.debug("Connection pool cleared")

proc getSocksProxyUrl*(client: SocksClient): string =
  ## プロキシのURLを取得する
  ##
  ## 戻り値:
  ##   SOCKSプロキシURL
  ##
  ## 例:
  ##   socks5://username:password@host:port
  
  let scheme = if client.version == svSocks5: "socks5" else: "socks4"
  
  if client.username.len > 0 and client.version == svSocks5:
    # URLエンコード
    var encodedUsername = client.username
    var encodedPassword = client.password
    
    # 簡易的なURLエンコード（完全なエンコードにするには専用の関数を使用）
    encodedUsername = encodedUsername.replace("%", "%25").replace(":", "%3A").replace("@", "%40")
    encodedPassword = encodedPassword.replace("%", "%25").replace(":", "%3A").replace("@", "%40")
    
    result = fmt"{scheme}://{encodedUsername}:{encodedPassword}@{client.host}:{client.port}"
  else:
    result = fmt"{scheme}://{client.host}:{client.port}" 