import std/[tables, sets, asyncdispatch, httpclient, net, strutils, uri, times, options, hashes]
import ../../dns/dns_resolver

type
  ConnectionState* = enum
    csNone,             # 接続なし
    csResolving,        # DNS解決中
    csConnecting,       # TCP接続中
    csConnected,        # TCP接続完了
    csTlsHandshaking,   # TLSハンドシェイク中
    csEstablished,      # 接続確立済み
    csFailed            # 接続失敗

  ConnectionType* = enum
    ctHttp,             # HTTP接続
    ctHttps             # HTTPS接続

  ConnectionInfo* = object
    ## 接続情報
    url*: string                # 接続先URL
    hostname*: string           # ホスト名
    port*: int                  # ポート番号
    connectionType*: ConnectionType  # 接続タイプ
    state*: ConnectionState     # 接続状態
    createdAt*: Time            # 作成時刻
    establishedAt*: Option[Time]  # 確立時刻
    failedAt*: Option[Time]     # 失敗時刻
    error*: Option[string]      # エラーメッセージ
    ipAddress*: Option[string]  # 解決されたIPアドレス
    reuseCount*: int            # 再利用回数
    socket*: Option[Socket]     # ソケット (HTTPの場合)
    tlsSocket*: Option[SslSocket]  # TLSソケット (HTTPSの場合)
    priority*: int              # 優先度 (高いほど優先)

  PreconnectManager* = object
    ## 事前接続マネージャー
    activeConnections*: Table[string, ConnectionInfo]  # アクティブな接続
    pendingConnections*: Table[string, ConnectionInfo]  # 保留中の接続
    recentFailures*: Table[string, Time]  # 最近の失敗
    maxConcurrentConnections*: int  # 最大同時接続数
    connectionTimeout*: int      # 接続タイムアウト（ミリ秒）
    tlsHandshakeTimeout*: int   # TLSハンドシェイクタイムアウト（ミリ秒）
    maxConnectionsPerHost*: int  # ホストごとの最大接続数
    retryDelayMs*: int          # 再試行の遅延（ミリ秒）
    maxRetries*: int            # 最大再試行回数
    connectionPoolSize*: int    # 接続プールサイズ
    dnsResolver*: DnsResolver   # DNS解決器
    enableIPv6*: bool           # IPv6を有効にするかどうか

proc hash*(connectionInfo: ConnectionInfo): Hash =
  ## ConnectionInfoのハッシュ関数
  var h: Hash = 0
  h = h !& hash(connectionInfo.hostname)
  h = h !& hash(connectionInfo.port)
  h = h !& hash(connectionInfo.connectionType)
  result = !$h

proc newPreconnectManager*(
  maxConcurrentConnections: int = 8,
  connectionTimeout: int = 10000,  # 10秒
  tlsHandshakeTimeout: int = 5000,  # 5秒
  maxConnectionsPerHost: int = 6,
  retryDelayMs: int = 1000,  # 1秒
  maxRetries: int = 3,
  connectionPoolSize: int = 100,
  dnsResolver: DnsResolver = nil,
  enableIPv6: bool = true
): PreconnectManager =
  ## 新しいPreconnectManagerを作成する
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
  ## 接続キーを生成する
  result = $connectionType & "://" & hostname & ":" & $port

proc parsePreconnectUrl*(url: string): tuple[hostname: string, port: int, connectionType: ConnectionType] =
  ## URLを解析して接続情報を取得する
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
  ## URLに対する接続情報を取得または作成する
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  # アクティブな接続をチェック
  if manager.activeConnections.hasKey(connectionKey):
    return manager.activeConnections[connectionKey]
  
  # 保留中の接続をチェック
  if manager.pendingConnections.hasKey(connectionKey):
    return manager.pendingConnections[connectionKey]
  
  # 新しい接続情報を作成
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
  ## 指定されたURLへの接続を事前に確立する
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  # 最近の失敗をチェック
  if manager.recentFailures.hasKey(connectionKey):
    let failureTime = manager.recentFailures[connectionKey]
    let elapsed = getTime() - failureTime
    if elapsed.inMilliseconds < manager.retryDelayMs:
      var info = getOrCreateConnectionInfo(manager, url, priority)
      info.state = csFailed
      info.error = some("最近接続に失敗しました。再試行を待機中です。")
      return info
  
  # アクティブな接続数をチェック
  if manager.activeConnections.len >= manager.maxConcurrentConnections:
    # 優先度の低い接続を見つけて閉じる
    var lowestPriorityKey = ""
    var lowestPriority = high(int)
    
    for key, info in manager.activeConnections:
      if info.priority < lowestPriority:
        lowestPriority = info.priority
        lowestPriorityKey = key
    
    if lowestPriority < priority and lowestPriorityKey != "":
      # 優先度の低い接続を閉じる
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
      # 接続数が上限に達しており、より低い優先度の接続がない場合
      var info = getOrCreateConnectionInfo(manager, url, priority)
      info.state = csNone
      info.error = some("接続数が上限に達しています。")
      return info
  
  # 新しい接続情報を作成
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
  
  # TCP接続
  connectionInfo.state = csConnecting
  try:
    if connectionInfo.connectionType == ctHttps:
      # HTTPS接続
      var socket = newAsyncSocket()
      await socket.connect(connectionInfo.ipAddress.get(), Port(port))
      
      # TLSハンドシェイク
      connectionInfo.state = csTlsHandshaking
      var sslContext = newContext(verifyMode = CVerifyPeer)
      var tlsSocket = newAsyncSslSocket(socket, sslContext, true)
      await tlsSocket.handshake()
      
      connectionInfo.socket = none(Socket)  # ソケットはTLSソケットに含まれる
      connectionInfo.tlsSocket = some(tlsSocket)
    else:
      # HTTP接続
      var socket = newAsyncSocket()
      await socket.connect(connectionInfo.ipAddress.get(), Port(port))
      connectionInfo.socket = some(socket)
      connectionInfo.tlsSocket = none(SslSocket)
    
    # 接続確立成功
    connectionInfo.state = csEstablished
    connectionInfo.establishedAt = some(getTime())
    
    # アクティブな接続に移動
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
  ## 接続を閉じる
  if manager.activeConnections.hasKey(connectionKey):
    var info = manager.activeConnections[connectionKey]
    
    # ソケットを閉じる
    if info.socket.isSome:
      try:
        info.socket.get().close()
      except:
        discard
    
    # TLSソケットを閉じる
    if info.tlsSocket.isSome:
      try:
        info.tlsSocket.get().close()
      except:
        discard
    
    # アクティブな接続から削除
    manager.activeConnections.del(connectionKey)

proc preconnectMultiple*(manager: var PreconnectManager, urls: seq[string], 
                        priority: int = 0): Future[int] {.async.} =
  ## 複数のURLに事前接続する
  ## 戻り値: 成功した接続数
  var successCount = 0
  var futures: seq[Future[ConnectionInfo]] = @[]
  
  # 同時に複数の接続を開始
  for url in urls:
    futures.add(manager.preconnect(url, priority))
  
  # すべての接続が完了するまで待機
  for future in futures:
    let connectionInfo = await future
    if connectionInfo.state == csEstablished:
      successCount += 1
  
  return successCount

proc getHostConnections*(manager: PreconnectManager, hostname: string): seq[ConnectionInfo] =
  ## 指定されたホストへの接続を取得する
  for _, info in manager.activeConnections:
    if info.hostname == hostname:
      result.add(info)

proc getActiveConnectionsCount*(manager: PreconnectManager): int =
  ## アクティブな接続数を取得する
  return manager.activeConnections.len

proc getPendingConnectionsCount*(manager: PreconnectManager): int =
  ## 保留中の接続数を取得する
  return manager.pendingConnections.len

proc getConnectionByUrl*(manager: PreconnectManager, url: string): Option[ConnectionInfo] =
  ## URLに対応する接続情報を取得する
  let (hostname, port, connectionType) = parsePreconnectUrl(url)
  let connectionKey = generateConnectionKey(hostname, port, connectionType)
  
  if manager.activeConnections.hasKey(connectionKey):
    return some(manager.activeConnections[connectionKey])
  
  if manager.pendingConnections.hasKey(connectionKey):
    return some(manager.pendingConnections[connectionKey])
  
  return none(ConnectionInfo)

proc getConnectionsPerHost*(manager: PreconnectManager): Table[string, int] =
  ## ホストごとの接続数を取得する
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
  ## 非アクティブな接続をクリーンアップする
  let currentTime = getTime()
  var connectionsToClose: seq[string] = @[]
  
  # 長時間アクティブなままの接続を特定
  for key, info in manager.activeConnections:
    if info.establishedAt.isSome:
      let age = currentTime - info.establishedAt.get()
      if age.inMilliseconds > maxAgeMs:
        connectionsToClose.add(key)
  
  # 接続を閉じる
  for key in connectionsToClose:
    manager.closeConnection(key)
  
  # 最近の失敗記録も古いものをクリーンアップ
  var failuresToClear: seq[string] = @[]
  for key, time in manager.recentFailures:
    let age = currentTime - time
    if age.inMilliseconds > manager.retryDelayMs * 5:  # 再試行遅延の5倍経過したら削除
      failuresToClear.add(key)
  
  for key in failuresToClear:
    manager.recentFailures.del(key)

proc reuseConnection*(manager: var PreconnectManager, url: string): Future[bool] {.async.} =
  ## 既存の接続を再利用する
  let connectionInfo = manager.getConnectionByUrl(url)
  if connectionInfo.isNone or connectionInfo.get().state != csEstablished:
    return false
  
  var info = connectionInfo.get()
  
  # 接続が健全かチェック
  if info.socket.isSome:
    # HTTP接続の場合
    try:
      # 接続がまだ有効かチェック（ダミーデータ送信）
      let socket = info.socket.get()
      if not socket.isClosed():
        # 再利用カウントを増やす
        info.reuseCount += 1
        let connectionKey = generateConnectionKey(info.hostname, info.port, info.connectionType)
        manager.activeConnections[connectionKey] = info
        return true
      else:
        # 接続が閉じられている場合は失敗
        return false
    except:
      # エラーが発生した場合は失敗
      return false
  
  elif info.tlsSocket.isSome:
    # HTTPS接続の場合
    try:
      # 接続がまだ有効かチェック
      let tlsSocket = info.tlsSocket.get()
      if not tlsSocket.isClosed():
        # 再利用カウントを増やす
        info.reuseCount += 1
        let connectionKey = generateConnectionKey(info.hostname, info.port, info.connectionType)
        manager.activeConnections[connectionKey] = info
        return true
      else:
        # 接続が閉じられている場合は失敗
        return false
    except:
      # エラーが発生した場合は失敗
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
  ## 接続統計情報を取得する
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
  # テスト用コード
  import asyncdispatch
  
  proc testPreconnect() {.async.} =
    echo "PreconnectManagerのテスト"
    
    # DNSリゾルバーを作成
    let dnsResolver = newDnsResolver()
    
    # PreconnectManagerを作成
    var preconnectManager = newPreconnectManager(
      maxConcurrentConnections = 4,
      dnsResolver = dnsResolver
    )
    
    # 単一のURLに事前接続
    echo "https://example.com に事前接続します..."
    let connectionInfo = await preconnectManager.preconnect("https://example.com")
    
    if connectionInfo.state == csEstablished:
      echo "事前接続に成功しました"
      echo "URL: ", connectionInfo.url
      echo "ホスト名: ", connectionInfo.hostname
      echo "IPアドレス: ", connectionInfo.ipAddress.get()
      echo "接続時間: ", (connectionInfo.establishedAt.get() - connectionInfo.createdAt).inMilliseconds, "ms"
    else:
      echo "事前接続に失敗しました"
      echo "状態: ", connectionInfo.state
      if connectionInfo.error.isSome:
        echo "エラー: ", connectionInfo.error.get()
    
    # 接続統計情報を表示
    let stats = preconnectManager.getConnectionStatistics()
    echo "統計情報："
    echo "  アクティブな接続数: ", stats.activeCount
    echo "  保留中の接続数: ", stats.pendingCount
    echo "  失敗数: ", stats.failureCount
    echo "  HTTPS比率: ", stats.httpsRatio * 100, "%"
    echo "  平均接続確立時間: ", stats.avgEstablishTimeMs, "ms"
    
    # 接続をクリーンアップ
    preconnectManager.cleanupInactiveConnections()
    
    # マネージャーを閉じる
    preconnectManager.close()
  
  waitFor testPreconnect() 