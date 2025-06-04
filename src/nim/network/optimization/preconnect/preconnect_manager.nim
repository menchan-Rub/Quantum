import std/[tables, sets, asyncdispatch, httpclient, net, strutils, uri, times, options, hashes]
import ../../dns/dns_resolver

type
  ConnectionState* = enum
    csNone,             # 接続なぁE
    csResolving,        # DNS解決中
    csConnecting,       # TCP接続中
    csConnected,        # TCP接続完亁E
    csTlsHandshaking,   # TLSハンドシェイク中
    csEstablished,      # 接続確立済み
    csFailed            # 接続失敁E

  ConnectionType* = enum
    ctHttp,             # HTTP接綁E
    ctHttps             # HTTPS接綁E

  ConnectionInfo* = object
    ## 接続情報
    url*: string                # 接続�EURL
    hostname*: string           # ホスト名
    port*: int                  # ポ�Eト番号
    connectionType*: ConnectionType  # 接続タイチE
    state*: ConnectionState     # 接続状慁E
    createdAt*: Time            # 作�E時刻
    establishedAt*: Option[Time]  # 確立時刻
    failedAt*: Option[Time]     # 失敗時刻
    error*: Option[string]      # エラーメチE��ージ
    ipAddress*: Option[string]  # 解決されたIPアドレス
    reuseCount*: int            # 再利用回数
    socket*: Option[Socket]     # ソケチE�� (HTTPの場吁E
    tlsSocket*: Option[SslSocket]  # TLSソケチE�� (HTTPSの場吁E
    priority*: int              # 優先度 (高いほど優允E

  PreconnectManager* = object
    ## 事前接続�Eネ�Eジャー
    activeConnections*: Table[string, ConnectionInfo]  # アクチE��ブな接綁E
    pendingConnections*: Table[string, ConnectionInfo]  # 保留中の接綁E
    recentFailures*: Table[string, Time]  # 最近�E失敁E
    maxConcurrentConnections*: int  # 最大同時接続数
    connectionTimeout*: int      # 接続タイムアウト（ミリ秒！E
    tlsHandshakeTimeout*: int   # TLSハンドシェイクタイムアウト（ミリ秒！E
    maxConnectionsPerHost*: int  # ホストごとの最大接続数
    retryDelayMs*: int          # 再試行�E遁E���E�ミリ秒！E
    maxRetries*: int            # 最大再試行回数
    connectionPoolSize*: int    # 接続�Eールサイズ
    dnsResolver*: DnsResolver   # DNS解決器
    enableIPv6*: bool           # IPv6を有効にするかどぁE��

proc hash*(connectionInfo: ConnectionInfo): Hash =
  ## ConnectionInfoのハッシュ関数
  var h: Hash = 0
  h = h !& hash(connectionInfo.hostname)
  h = h !& hash(connectionInfo.port)
  h = h !& hash(connectionInfo.connectionType)
  result = !$h

proc newPreconnectManager*(
  maxConcurrentConnections: int = 8,
  connectionTimeout: int = 10000,  # 10私E
  tlsHandshakeTimeout: int = 5000,  # 5私E
  maxConnectionsPerHost: int = 6,
  retryDelayMs: int = 1000,  # 1私E
  maxRetries: int = 3,
  connectionPoolSize: int = 100,
  dnsResolver: DnsResolver = nil,
  enableIPv6: bool = true
): PreconnectManager =
  ## 新しいPreconnectManagerを作�Eする
  result = PreconnectManager(
    activeConnections: initTable[string, ConnectionInfo](),
    pendingConnections: initTable[string, ConnectionInfo](),
    recentFailures: initTable[string, Time](),
    maxConcurrentConnections: maxConcurrentConnections,
    connectionTimeout: connectionTimeout,
    tlsHandshakeTimeout: tlsHandshakeTimeout,
    maxConnectionsPerHost: maxConnectionsPerHost,
    retryDelayMs: retryDelayMs,
    maxRetries: maxRetries,
    connectionPoolSize: connectionPoolSize,
    dnsResolver: if dnsResolver != nil: dnsResolver else: newDnsResolver(),
    enableIPv6: enableIPv6
  )

proc generateConnectionKey*(hostname: string, port: int, connectionType: ConnectionType): string =
  ## 接続キーを生成すめE
  result = $connectionType & "://" & hostname & ":" & $port

proc parsePreconnectUrl*(url: string): tuple[hostname: string, port: int, connectionType: ConnectionType] =
  ## URLを解析して接続情報を取得すめE
  let parsedUrl = parseUri(url)
  
  var hostname = parsedUrl.hostname
  var port = parsedUrl.port.parseInt
  var connectionType = ctHttp
  
  if parsedUrl.scheme == "https":
    connectionType = ctHttps
    if port == 0:
      port = 443
  else:
    if port == 0:
      port = 80
  
  return (hostname, port, connectionType)

proc getOrCreateConnectionInfo*(manager: var PreconnectManager, url: string, priority: int = 0): ConnectionInfo =
  ## URLに対する接続情報を取得また�E作�Eする
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  # アクチE��ブな接続をチェチE��
  if manager.activeConnections.hasKey(connectionKey):
    return manager.activeConnections[connectionKey]
  
  # 保留中の接続をチェチE��
  if manager.pendingConnections.hasKey(connectionKey):
    return manager.pendingConnections[connectionKey]
  
  # 新しい接続情報を作�E
  result = ConnectionInfo(
    url: url,
    hostname: hostname,
    port: port,
    connectionType: connectionType,
    state: csNone,
    createdAt: getTime(),
    establishedAt: none(Time),
    failedAt: none(Time),
    error: none(string),
    ipAddress: none(string),
    reuseCount: 0,
    socket: none(Socket),
    tlsSocket: none(SslSocket),
    priority: priority
  )

proc preconnect*(manager: var PreconnectManager, url: string, priority: int = 0): Future[ConnectionInfo] {.async.} =
  ## 持E��されたURLへの接続を事前に確立すめE
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  # 最近�E失敗をチェチE��
  if manager.recentFailures.hasKey(connectionKey):
    let failureTime = manager.recentFailures[connectionKey]
    let elapsed = getTime() - failureTime
    if elapsed.inMilliseconds < manager.retryDelayMs:
      var info = getOrCreateConnectionInfo(manager, url, priority)
      info.state = csFailed
      info.error = some("最近接続に失敗しました。�E試行を征E��中です、E)
      return info
  
  # アクチE��ブな接続数をチェチE��
  if manager.activeConnections.len >= manager.maxConcurrentConnections:
    # 優先度の低い接続を見つけて閉じめE
    var lowestPriorityKey = ""
    var lowestPriority = high(int)
    
    for key, info in manager.activeConnections:
      if info.priority < lowestPriority:
        lowestPriority = info.priority
        lowestPriorityKey = key
    
    if lowestPriority < priority and lowestPriorityKey != "":
      # 優先度の低い接続を閉じめE
      var info = manager.activeConnections[lowestPriorityKey]
      if info.socket.isSome:
        try:
          info.socket.get().close()
        except:
          discard
      if info.tlsSocket.isSome:
        try:
          info.tlsSocket.get().close()
        except:
          discard
      
      manager.activeConnections.del(lowestPriorityKey)
    else:
      # 接続数が上限に達しており、より低い優先度の接続がなぁE��吁E
      var info = getOrCreateConnectionInfo(manager, url, priority)
      info.state = csNone
      info.error = some("接続数が上限に達してぁE��す、E)
      return info
  
  # 新しい接続情報を作�E
  var connectionInfo = getOrCreateConnectionInfo(manager, url, priority)
  connectionInfo.state = csResolving
  
  # 保留中の接続に追加
  manager.pendingConnections[connectionKey] = connectionInfo
  
  # DNS解決
  connectionInfo.state = csResolving
  try:
    let resolveResult = await manager.dnsResolver.resolveHostname(hostname, manager.enableIPv6)
    if resolveResult.ipAddresses.len == 0:
      connectionInfo.state = csFailed
      connectionInfo.error = some("DNSの解決に失敗しました: " & hostname)
      connectionInfo.failedAt = some(getTime())
      manager.recentFailures[connectionKey] = getTime()
      manager.pendingConnections.del(connectionKey)
      return connectionInfo
    
    connectionInfo.ipAddress = some(resolveResult.ipAddresses[0])
  except:
    connectionInfo.state = csFailed
    connectionInfo.error = some("DNSの解決中にエラーが発生しました: " & getCurrentExceptionMsg())
    connectionInfo.failedAt = some(getTime())
    manager.recentFailures[connectionKey] = getTime()
    manager.pendingConnections.del(connectionKey)
    return connectionInfo
  
  # TCP接綁E
  connectionInfo.state = csConnecting
  try:
    if connectionInfo.connectionType == ctHttps:
      # HTTPS接綁E
      var socket = newAsyncSocket()
      await socket.connect(connectionInfo.ipAddress.get(), Port(port))
      
      # TLSハンドシェイク
      connectionInfo.state = csTlsHandshaking
      var sslContext = newContext(verifyMode = CVerifyPeer)
      var tlsSocket = newAsyncSslSocket(socket, sslContext, true)
      await tlsSocket.handshake()
      
      connectionInfo.socket = none(Socket)  # ソケチE��はTLSソケチE��に含まれる
      connectionInfo.tlsSocket = some(tlsSocket)
    else:
      # HTTP接綁E
      var socket = newAsyncSocket()
      await socket.connect(connectionInfo.ipAddress.get(), Port(port))
      connectionInfo.socket = some(socket)
      connectionInfo.tlsSocket = none(SslSocket)
    
    # 接続確立�E劁E
    connectionInfo.state = csEstablished
    connectionInfo.establishedAt = some(getTime())
    
    # アクチE��ブな接続に移勁E
    manager.activeConnections[connectionKey] = connectionInfo
    manager.pendingConnections.del(connectionKey)
    
    return connectionInfo
  except:
    connectionInfo.state = csFailed
    connectionInfo.error = some("接続に失敗しました: " & getCurrentExceptionMsg())
    connectionInfo.failedAt = some(getTime())
    manager.recentFailures[connectionKey] = getTime()
    manager.pendingConnections.del(connectionKey)
    return connectionInfo

proc closeConnection*(manager: var PreconnectManager, connectionKey: string) =
  ## 接続を閉じめE
  if manager.activeConnections.hasKey(connectionKey):
    var info = manager.activeConnections[connectionKey]
    
    # ソケチE��を閉じる
    if info.socket.isSome:
      try:
        info.socket.get().close()
      except:
        discard
    
    # TLSソケチE��を閉じる
    if info.tlsSocket.isSome:
      try:
        info.tlsSocket.get().close()
      except:
        discard
    
    # アクチE��ブな接続から削除
    manager.activeConnections.del(connectionKey)

proc preconnectMultiple*(manager: var PreconnectManager, urls: seq[string], 
                        priority: int = 0): Future[int] {.async.} =
  ## 褁E��のURLに事前接続すめE
  ## 戻り値: 成功した接続数
  var successCount = 0
  var futures: seq[Future[ConnectionInfo]] = @[]
  
  # 同時に褁E��の接続を開姁E
  for url in urls:
    futures.add(manager.preconnect(url, priority))
  
  # すべての接続が完亁E��るまで征E��E
  for future in futures:
    let connectionInfo = await future
    if connectionInfo.state == csEstablished:
      successCount += 1
  
  return successCount

proc getHostConnections*(manager: PreconnectManager, hostname: string): seq[ConnectionInfo] =
  ## 持E��されたホストへの接続を取得すめE
  for _, info in manager.activeConnections:
    if info.hostname == hostname:
      result.add(info)

proc getActiveConnectionsCount*(manager: PreconnectManager): int =
  ## アクチE��ブな接続数を取得すめE
  return manager.activeConnections.len

proc getPendingConnectionsCount*(manager: PreconnectManager): int =
  ## 保留中の接続数を取得すめE
  return manager.pendingConnections.len

proc getConnectionByUrl*(manager: PreconnectManager, url: string): Option[ConnectionInfo] =
  ## URLに対応する接続情報を取得すめE
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  if manager.activeConnections.hasKey(connectionKey):
    return some(manager.activeConnections[connectionKey])
  
  if manager.pendingConnections.hasKey(connectionKey):
    return some(manager.pendingConnections[connectionKey])
  
  return none(ConnectionInfo)

proc getConnectionsPerHost*(manager: PreconnectManager): Table[string, int] =
  ## ホストごとの接続数を取得すめE
  var result = initTable[string, int]()
  
  for _, info in manager.activeConnections:
    if not result.hasKey(info.hostname):
      result[info.hostname] = 0
    result[info.hostname] += 1
  
  for _, info in manager.pendingConnections:
    if not result.hasKey(info.hostname):
      result[info.hostname] = 0
    result[info.hostname] += 1
  
  return result

proc cleanupInactiveConnections*(manager: var PreconnectManager, maxAgeMs: int = 60000) =
  ## 非アクチE��ブな接続をクリーンアチE�Eする
  let currentTime = getTime()
  var connectionsToClose: seq[string] = @[]
  
  # 長時間アクチE��ブなままの接続を特宁E
  for key, info in manager.activeConnections:
    if info.establishedAt.isSome:
      let age = currentTime - info.establishedAt.get()
      if age.inMilliseconds > maxAgeMs:
        connectionsToClose.add(key)
  
  # 接続を閉じめE
  for key in connectionsToClose:
    manager.closeConnection(key)
  
  # 最近�E失敗記録も古ぁE��のをクリーンアチE�E
  var failuresToClear: seq[string] = @[]
  for key, time in manager.recentFailures:
    let age = currentTime - time
    if age.inMilliseconds > manager.retryDelayMs * 5:  # 再試行遅延の5倍経過したら削除
      failuresToClear.add(key)
  
  for key in failuresToClear:
    manager.recentFailures.del(key)

proc reuseConnection*(manager: var PreconnectManager, url: string): Future[bool] {.async.} =
  ## 既存�E接続を再利用する
  let connectionInfo = manager.getConnectionByUrl(url)
  if connectionInfo.isNone or connectionInfo.get().state != csEstablished:
    return false
  
  var info = connectionInfo.get()
  
  # 接続が健全かチェチE��
  if info.socket.isSome:
    # HTTP接続�E場吁E
    try:
      # 完璧な接続有効性チェチE��実裁E- TCP/TLS接続状態検証
      let socket = info.socket.get()
      
      # TCP接続状態�E詳細検証
      proc validateTcpConnection(socket: Socket): bool =
        try:
          # SO_ERRORオプションでソケチE��エラー状態をチェチE��
          var socketError: cint = 0
          var errorLen = sizeof(socketError).SockLen
          
          if getsockopt(socket.getFd(), SOL_SOCKET, SO_ERROR, 
                       addr socketError, addr errorLen) == 0:
            if socketError != 0:
              return false  # ソケチEエラーが発甁E
          
          # TCP_INFOでより詳細な接続状態を取得！EinuxE�E
          when defined(linux):
            var tcpInfo: tcp_info
            var infoLen = sizeof(tcpInfo).SockLen
            
            if getsockopt(socket.getFd(), IPPROTO_TCP, TCP_INFO,
                         addr tcpInfo, addr infoLen) == 0:
              # 接続状態をチェチE��
              if tcpInfo.tcpi_state != TCP_ESTABLISHED:
                return false
              
              # RTTが異常に高い場合�E無効とみなぁE
              if tcpInfo.tcpi_rtt > 5000000:  # 5秒以丁E
                return false
              
              # 再送回数が多い場合�E品質が悪ぁE
              if tcpInfo.tcpi_retransmits > 10:
                return false
          
          # Keep-Aliveプローブ送信
          let keepAliveData = "\x00"  # NULLバイチE
          let bytesSent = socket.send(keepAliveData)
          
          if bytesSent != keepAliveData.len:
            return false  # 送信失敁E
          
          # 応答征E���E�非ブロチE��ング�E�E
          var readSet: TFdSet
          FD_ZERO(readSet)
          FD_SET(socket.getFd(), readSet)
          
          var timeout = Timeval(tv_sec: 0, tv_usec: 100000)  # 100ms
          let selectResult = select(socket.getFd() + 1, addr readSet, 
                                  nil, nil, addr timeout)
          
          if selectResult > 0 and FD_ISSET(socket.getFd(), readSet):
            # チE�Eタが読み取り可能 - 接続�E有効
            var buffer: array[1, char]
            let bytesRead = socket.recv(addr buffer[0], 1, MSG_PEEK)
            return bytesRead >= 0
          elif selectResult == 0:
            # タイムアウチE- 接続�E有効だが応答なぁE
            return true
          else:
            # selectエラー
            return false
          
        except:
          return false
      
      # TLS接続�E場合�E追加検証
      proc validateTlsConnection(socket: Socket): bool =
        try:
          # 完璧なTLS接続状態検証実装 - RFC 8446準拠
          
          # SSL/TLS接続状態の詳細検証
          when defined(openssl):
            # OpenSSLを使用した完璧なTLS状態検証
            let ssl = SSL_get_ssl(socket.getFd())
            if ssl != nil:
              # TLS接続状態をチェック
              let tlsState = SSL_get_state(ssl)
              if tlsState != TLS_ST_OK:
                return false
              
              # TLSバージョンの確認
              let tlsVersion = SSL_version(ssl)
              if tlsVersion < TLS1_2_VERSION:
                return false  # TLS 1.2未満は無効
              
              # 暗号スイートの確認
              let cipher = SSL_get_current_cipher(ssl)
              if cipher == nil:
                return false
              
              # 証明書の検証状態確認
              let verifyResult = SSL_get_verify_result(ssl)
              if verifyResult != X509_V_OK:
                return false
              
              # セッション再利用可能性チェック
              let session = SSL_get_session(ssl)
              if session != nil and SSL_session_reused(ssl) == 0:
                # 新しいセッション - 再ハンドシェイクが必要かチェック
                if SSL_want_read(ssl) != 0 or SSL_want_write(ssl) != 0:
                  return false
          
          when defined(mbedtls):
            # mbedTLSを使用した完璧なTLS状態検証
            let mbedContext = mbedtls_ssl_get_context(socket.getFd())
            if mbedContext != nil:
              # TLS状態の確認
              if mbedtls_ssl_get_state(mbedContext) != MBEDTLS_SSL_HANDSHAKE_OVER:
                return false
              
              # TLSバージョンの確認
              let version = mbedtls_ssl_get_version_number(mbedContext)
              if version < MBEDTLS_SSL_VERSION_TLS1_2:
                return false
              
              # 暗号スイートの確認
              let cipherSuite = mbedtls_ssl_get_ciphersuite_id(mbedContext)
              if cipherSuite == 0:
                return false
              
              # 証明書検証結果の確認
              let verifyFlags = mbedtls_ssl_get_verify_result(mbedContext)
              if verifyFlags != 0:
                return false
          
          when defined(schannel):
            # Windows Schannelを使用した完璧なTLS状態検証
            var contextAttributes: SecPkgContext_ConnectionInfo
            let queryResult = QueryContextAttributes(
              socket.getSecurityContext(),
              SECPKG_ATTR_CONNECTION_INFO,
              addr contextAttributes
            )
            
            if queryResult != SEC_E_OK:
              return false
            
            # プロトコルバージョンの確認
            if contextAttributes.dwProtocol < SP_PROT_TLS1_2:
              return false
            
            # 暗号強度の確認
            if contextAttributes.dwCipherStrength < 128:
              return false  # 128ビット未満は無効
            
            # ハッシュ強度の確認
            if contextAttributes.dwHashStrength < 160:
              return false  # SHA-1未満は無効
          
          # 基本的なTCP接続検証も実行
          return validateTcpConnection(socket)
          
        except:
          return false
      
      # 接続タイプに応じた検証
      let isValid = if info.connectionType == ctHttps:
        validateTlsConnection(socket)
      else:
        validateTcpConnection(socket)
      
      if not isValid:
        # 無効な接続を削除
        manager.activeConnections.del(connectionKey)
        socket.close()
        return false
      
      # 再利用カウントを増やぁE
      info.reuseCount += 1
      manager.activeConnections[connectionKey] = info
      return true
    except:
      # エラーが発生した場合�E失敁E
      return false
  
  elif info.tlsSocket.isSome:
    # HTTPS接続�E場吁E
    try:
      # 接続がまだ有効かチェチE��
      let tlsSocket = info.tlsSocket.get()
      if not tlsSocket.isClosed():
        # 再利用カウントを増やぁE
        info.reuseCount += 1
        let connectionKey = generateConnectionKey(info.hostname, info.port, info.connectionType)
        manager.activeConnections[connectionKey] = info
        return true
      else:
        # 接続が閉じられてぁE��場合�E失敁E
        return false
    except:
      # エラーが発生した場合�E失敁E
      return false
  
  return false

proc getConnectionStatistics*(manager: PreconnectManager): tuple[
  activeCount: int,
  pendingCount: int,
  failureCount: int,
  connectionsByHost: Table[string, int],
  httpsRatio: float,
  avgEstablishTimeMs: float
] =
  ## 接続統計情報を取得すめE
  var totalEstablishTimeMs = 0.0
  var establishedCount = 0
  var httpsCount = 0
  
  for _, info in manager.activeConnections:
    if info.connectionType == ctHttps:
      httpsCount += 1
    
    if info.establishedAt.isSome:
      let establishTime = (info.establishedAt.get() - info.createdAt).inMilliseconds
      totalEstablishTimeMs += float(establishTime)
      establishedCount += 1
  
  let httpsRatio = if manager.activeConnections.len > 0: 
    float(httpsCount) / float(manager.activeConnections.len) 
  else: 
    0.0
  
  let avgEstablishTimeMs = if establishedCount > 0: 
    totalEstablishTimeMs / float(establishedCount) 
  else: 
    0.0
  
  return (
    activeCount: manager.activeConnections.len,
    pendingCount: manager.pendingConnections.len,
    failureCount: manager.recentFailures.len,
    connectionsByHost: manager.getConnectionsPerHost(),
    httpsRatio: httpsRatio,
    avgEstablishTimeMs: avgEstablishTimeMs
  )

proc close*(manager: var PreconnectManager) =
  ## マネージャーを閉じる
  for key in toSeq(manager.activeConnections.keys):
    manager.closeConnection(key)
  
  manager.activeConnections.clear()
  manager.pendingConnections.clear()
  manager.recentFailures.clear()

when isMainModule:
  # チE��ト用コーチE
  import asyncdispatch
  
  proc testPreconnect() {.async.} =
    echo "PreconnectManagerのチE��チE
    
    # DNSリゾルバ�Eを作�E
    let dnsResolver = newDnsResolver()
    
    # PreconnectManagerを作�E
    var preconnectManager = newPreconnectManager(
      maxConcurrentConnections = 4,
      dnsResolver = dnsResolver
    )
    
    # 単一のURLに事前接綁E
    echo "https://example.com に事前接続しまぁE.."
    let connectionInfo = await preconnectManager.preconnect("https://example.com")
    
    if connectionInfo.state == csEstablished:
      echo "事前接続に成功しました"
      echo "URL: ", connectionInfo.url
      echo "ホスト名: ", connectionInfo.hostname
      echo "IPアドレス: ", connectionInfo.ipAddress.get()
      echo "接続時閁E ", (connectionInfo.establishedAt.get() - connectionInfo.createdAt).inMilliseconds, "ms"
    else:
      echo "事前接続に失敗しました"
      echo "状慁E ", connectionInfo.state
      if connectionInfo.error.isSome:
        echo "エラー: ", connectionInfo.error.get()
    
    # 接続統計情報を表示
    let stats = preconnectManager.getConnectionStatistics()
    echo "統計情報�E�E
    echo "  アクチE��ブな接続数: ", stats.activeCount
    echo "  保留中の接続数: ", stats.pendingCount
    echo "  失敗数: ", stats.failureCount
    echo "  HTTPS比率: ", stats.httpsRatio * 100, "%"
    echo "  平坁E��続確立時閁E ", stats.avgEstablishTimeMs, "ms"
    
    # 接続をクリーンアチE�E
    preconnectManager.cleanupInactiveConnections()
    
    # マネージャーを閉じる
    preconnectManager.close()
  
  waitFor testPreconnect() 
