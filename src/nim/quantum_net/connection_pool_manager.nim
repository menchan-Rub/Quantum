import std/[tables, options, hashes, times, uri, strutils, sequtils]
import std/locks
import std/deques
import asyncdispatch
import ../quantum_arch/threading/thread_pool
import ../quantum_arch/memory/shared_memory
import ./http/client
import ./dns/cache

const 
  DEFAULT_MAX_CONNECTIONS_PER_HOST = 8
  DEFAULT_CONNECTION_TIMEOUT = 60 # 秒
  DEFAULT_IDLE_TIMEOUT = 300 # 秒
  DEFAULT_REUSE_TIMEOUT = 240 # 秒
  DEFAULT_KEEP_ALIVE = true
  MAX_TOTAL_CONNECTIONS = 256 # 全ホスト合計の最大接続数

type
  ConnectionState = enum
    csIdle,      # アイドル状態（再利用可能）
    csBusy,      # 使用中
    csClosing,   # クローズ中
    csClosed     # クローズ済み

  Connection = ref object
    id: uint64
    host: string
    port: int
    secure: bool
    socket: AsyncSocket
    createdTime: Time
    lastUsedTime: Time
    state: ConnectionState
    keepAlive: bool
    reuseCount: int
    rtt: Duration # 往復時間の計測値
    throughput: float # 測定されたスループット (bytes/sec)
    
  ConnectionPool = ref object
    maxConnectionsPerHost: int
    connectionTimeout: int
    idleTimeout: int
    reuseTimeout: int
    defaultKeepAlive: bool
    
    # 接続の管理データ構造
    poolsByHost: Table[string, seq[Connection]]
    activeConnections: int
    
    # 最適化のための内部状態
    hostPerformanceStats: Table[string, HostStats]
    pruneTimer: Future[void]
    lock: Lock
    
  HostStats = object
    avgRtt: Duration
    minRtt: Duration
    maxRtt: Duration
    avgThroughput: float
    successCount: int
    errorCount: int
    lastConnectTime: Time
    
  ConnectionError = object of CatchableError

# グローバルインスタンス（シングルトン）
var globalPool: ConnectionPool

proc hash(conn: Connection): Hash =
  var h: Hash = 0
  h = h !& hash(conn.id)
  h = h !& hash(conn.host)
  h = h !& hash(conn.port)
  result = !$h

proc `==`(a, b: Connection): bool =
  a.id == b.id

proc newConnection(host: string, port: int, secure: bool, socket: AsyncSocket): Connection =
  result = Connection(
    id: cast[uint64](getMonoTime().ticks),
    host: host,
    port: port,
    secure: secure,
    socket: socket,
    createdTime: getTime(),
    lastUsedTime: getTime(),
    state: csBusy,
    keepAlive: true,
    reuseCount: 0,
    rtt: initDuration(milliseconds = 0),
    throughput: 0.0
  )

proc newConnectionPool*(maxConnectionsPerHost = DEFAULT_MAX_CONNECTIONS_PER_HOST, 
                       connectionTimeout = DEFAULT_CONNECTION_TIMEOUT,
                       idleTimeout = DEFAULT_IDLE_TIMEOUT,
                       reuseTimeout = DEFAULT_REUSE_TIMEOUT,
                       defaultKeepAlive = DEFAULT_KEEP_ALIVE): ConnectionPool =
  result = ConnectionPool(
    maxConnectionsPerHost: maxConnectionsPerHost,
    connectionTimeout: connectionTimeout,
    idleTimeout: idleTimeout,
    reuseTimeout: reuseTimeout,
    defaultKeepAlive: defaultKeepAlive,
    poolsByHost: initTable[string, seq[Connection]](),
    activeConnections: 0,
    hostPerformanceStats: initTable[string, HostStats]()
  )
  initLock(result.lock)
  
  # バックグラウンドでの定期的な接続プルーニング
  result.pruneTimer = asyncCheck result.pruneIdleConnections()

proc getHostKey(host: string, port: int, secure: bool): string =
  result = if secure: "https://" else: "http://"
  result &= host & ":" & $port

proc updateHostStats(pool: ConnectionPool, host: string, conn: Connection, succeeded: bool) =
  withLock(pool.lock):
    if host notin pool.hostPerformanceStats:
      pool.hostPerformanceStats[host] = HostStats(
        avgRtt: conn.rtt,
        minRtt: conn.rtt,
        maxRtt: conn.rtt,
        avgThroughput: conn.throughput,
        successCount: if succeeded: 1 else: 0,
        errorCount: if succeeded: 0 else: 1,
        lastConnectTime: getTime()
      )
    else:
      var stats = pool.hostPerformanceStats[host]
      
      # 統計情報の更新
      if succeeded:
        inc stats.successCount
      else:
        inc stats.errorCount
        
      # RTT統計の更新
      if conn.rtt.inMilliseconds > 0:
        let totalSamples = stats.successCount + stats.errorCount
        stats.avgRtt = initDuration(
          milliseconds = ((stats.avgRtt.inMilliseconds * (totalSamples - 1)) + 
                          conn.rtt.inMilliseconds) div totalSamples
        )
        
        if conn.rtt < stats.minRtt or stats.minRtt.inMilliseconds == 0:
          stats.minRtt = conn.rtt
        if conn.rtt > stats.maxRtt:
          stats.maxRtt = conn.rtt
          
      # スループット統計の更新
      if conn.throughput > 0:
        stats.avgThroughput = (stats.avgThroughput * (totalSamples.float - 1) + 
                              conn.throughput) / totalSamples.float
      
      stats.lastConnectTime = getTime()
      pool.hostPerformanceStats[host] = stats

proc pruneIdleConnections(pool: ConnectionPool) {.async.} =
  while true:
    # 60秒ごとにアイドル接続をプルーニング
    await sleepAsync(60000)
    
    let now = getTime()
    var closedCount = 0
    
    withLock(pool.lock):
      for host, connections in pool.poolsByHost.mpairs:
        var activeConns: seq[Connection] = @[]
        
        for conn in connections:
          if conn.state == csIdle:
            # アイドルタイムアウトを超えた接続を閉じる
            if (now - conn.lastUsedTime).inSeconds > pool.idleTimeout:
              asyncCheck conn.socket.close()
              conn.state = csClosed
              closedCount.inc
            # 再利用タイムアウトを超えた接続を閉じる
            elif (now - conn.createdTime).inSeconds > pool.reuseTimeout:
              asyncCheck conn.socket.close()
              conn.state = csClosed
              closedCount.inc
            else:
              activeConns.add(conn)
          elif conn.state != csClosed:
            activeConns.add(conn)
            
        # アクティブな接続だけを保持
        if activeConns.len < connections.len:
          pool.poolsByHost[host] = activeConns
          pool.activeConnections -= (connections.len - activeConns.len)
    
    if closedCount > 0:
      echo "接続プール: ", closedCount, " 個のアイドル接続をクローズしました"

proc getConnection*(pool: ConnectionPool, host: string, port: int, secure: bool): Future[Connection] {.async.} =
  let hostKey = getHostKey(host, port, secure)
  var conn: Connection
  
  # 処理の開始時間を記録（RTT計測用）
  let startTime = getMonoTime()
  
  withLock(pool.lock):
    if hostKey in pool.poolsByHost:
      var connections = pool.poolsByHost[hostKey]
      
      # アイドル接続を探す
      for i, c in connections:
        if c.state == csIdle:
          c.state = csBusy
          c.lastUsedTime = getTime()
          c.reuseCount.inc
          conn = c
          break
          
    if conn == nil:
      # 新しい接続が必要 - ホスト別の制限をチェック
      var hostConnCount = 0
      if hostKey in pool.poolsByHost:
        hostConnCount = pool.poolsByHost[hostKey].len
        
      if hostConnCount >= pool.maxConnectionsPerHost:
        # 制限に達した場合はアイドル接続を強制的に再利用
        if hostKey in pool.poolsByHost:
          let oldestIdleConn = pool.poolsByHost[hostKey].filterIt(it.state == csIdle).
            sortedByIt(it.lastUsedTime).getOrDefault(0)
            
          if oldestIdleConn != nil:
            oldestIdleConn.state = csBusy
            oldestIdleConn.lastUsedTime = getTime()
            oldestIdleConn.reuseCount.inc
            conn = oldestIdleConn
      
      # 全体の制限をチェック
      if conn == nil and pool.activeConnections >= MAX_TOTAL_CONNECTIONS:
        # 全体制限に達した場合、一番古いアイドル接続を探す
        var oldestIdleConn: Connection
        var oldestTime = getTime()
        
        for h, connections in pool.poolsByHost:
          for c in connections:
            if c.state == csIdle and c.lastUsedTime < oldestTime:
              oldestTime = c.lastUsedTime
              oldestIdleConn = c
              
        if oldestIdleConn != nil:
          oldestIdleConn.state = csBusy
          oldestIdleConn.lastUsedTime = getTime()
          oldestIdleConn.reuseCount.inc
          conn = oldestIdleConn
  
  # 再利用可能な接続がなければ新規接続を作成
  if conn == nil:
    try:
      let socket = await asyncnet.dial(host, Port(port))
      
      # TLS接続が必要な場合はハンドシェイク
      if secure:
        # TLSのセットアップ（証明書検証・暗号化通信確立）
        await setupTls(socket, host)
        
      conn = newConnection(host, port, secure, socket)
      
      withLock(pool.lock):
        if hostKey notin pool.poolsByHost:
          pool.poolsByHost[hostKey] = @[]
          
        pool.poolsByHost[hostKey].add(conn)
        pool.activeConnections.inc
        
    except:
      let errMsg = getCurrentExceptionMsg()
      raise newException(ConnectionError, "接続に失敗しました: " & host & ":" & $port & " - " & errMsg)
  
  # RTTの測定
  let endTime = getMonoTime()
  conn.rtt = endTime - startTime
  
  # ホスト統計を更新
  pool.updateHostStats(hostKey, conn, true)
  
  return conn

proc releaseConnection*(pool: ConnectionPool, conn: Connection, keepAlive = true) =
  if conn == nil:
    return
    
  withLock(pool.lock):
    if conn.state != csClosed:
      if keepAlive and conn.keepAlive:
        conn.state = csIdle
        conn.lastUsedTime = getTime()
      else:
        conn.state = csClosing
        asyncCheck conn.socket.close()
        conn.state = csClosed
        
        # 接続をプールから削除
        let hostKey = getHostKey(conn.host, conn.port, conn.secure)
        if hostKey in pool.poolsByHost:
          let idx = pool.poolsByHost[hostKey].find(conn)
          if idx >= 0:
            pool.poolsByHost[hostKey].delete(idx)
            pool.activeConnections.dec

proc closeConnection*(pool: ConnectionPool, conn: Connection) =
  if conn == nil:
    return
    
  withLock(pool.lock):
    if conn.state != csClosed:
      conn.state = csClosing
      asyncCheck conn.socket.close()
      conn.state = csClosed
      
      # 接続をプールから削除
      let hostKey = getHostKey(conn.host, conn.port, conn.secure)
      if hostKey in pool.poolsByHost:
        let idx = pool.poolsByHost[hostKey].find(conn)
        if idx >= 0:
          pool.poolsByHost[hostKey].delete(idx)
          pool.activeConnections.dec

proc getConnectionStats*(pool: ConnectionPool): tuple[active, idle, total: int] =
  var activeCount, idleCount = 0
  
  withLock(pool.lock):
    for host, connections in pool.poolsByHost:
      for conn in connections:
        if conn.state == csBusy:
          activeCount.inc
        elif conn.state == csIdle:
          idleCount.inc
  
  return (active: activeCount, idle: idleCount, total: pool.activeConnections)

proc getHostPerformanceStats*(pool: ConnectionPool, host: string): Option[HostStats] =
  withLock(pool.lock):
    if host in pool.hostPerformanceStats:
      return some(pool.hostPerformanceStats[host])
  
  return none(HostStats)

proc closeAllConnections*(pool: ConnectionPool) =
  withLock(pool.lock):
    for host, connections in pool.poolsByHost:
      for conn in connections:
        if conn.state != csClosed:
          asyncCheck conn.socket.close()
          conn.state = csClosed
    
    pool.poolsByHost.clear()
    pool.activeConnections = 0

proc shutdown*(pool: ConnectionPool) =
  # プルーニングタイマーを停止
  if not pool.pruneTimer.isNil:
    pool.pruneTimer.cancel()
  
  # すべての接続を閉じる
  pool.closeAllConnections()
  
  # ロックを破棄
  deinitLock(pool.lock)

# グローバルプールへのアクセス関数
proc getGlobalConnectionPool*(): ConnectionPool =
  if globalPool.isNil:
    globalPool = newConnectionPool()
  return globalPool

# URL文字列からの簡易接続取得
proc getConnectionFromUrl*(url: string): Future[Connection] {.async.} =
  let pool = getGlobalConnectionPool()
  let uri = parseUri(url)
  
  let secure = uri.scheme == "https"
  let host = uri.hostname
  let port = if uri.port == "": 
               if secure: 443 else: 80
             else: 
               parseInt(uri.port)
               
  return await pool.getConnection(host, port, secure)

# パイプライン化を可能にする複数リクエスト用の接続管理
proc executePipelined*(requests: seq[HttpRequest]): Future[seq[HttpResponse]] {.async.} =
  let pool = getGlobalConnectionPool()
  var responses: seq[HttpResponse] = @[]
  
  if requests.len == 0:
    return responses
    
  # リクエストをホスト別にグループ化
  var requestsByHost = initTable[string, seq[HttpRequest]]()
  
  for req in requests:
    let uri = req.url
    let host = uri.hostname
    let port = if uri.port == "": 
                if uri.scheme == "https": "443" else: "80"
              else: 
                uri.port
    let secure = uri.scheme == "https"
    let hostKey = getHostKey(host, parseInt(port), secure)
    
    if hostKey notin requestsByHost:
      requestsByHost[hostKey] = @[]
      
    requestsByHost[hostKey].add(req)
  
  # ホスト別に処理を実行
  var futures: seq[Future[seq[HttpResponse]]] = @[]
  
  for hostKey, hostRequests in requestsByHost:
    futures.add(executePipelinedForHost(pool, hostKey, hostRequests))
  
  # すべての結果を待機して結合
  for fut in futures:
    let hostResponses = await fut
    responses.add(hostResponses)
    
  return responses

proc executePipelinedForHost(pool: ConnectionPool, hostKey: string, 
                            requests: seq[HttpRequest]): Future[seq[HttpResponse]] {.async.} =
  var responses: seq[HttpResponse] = @[]
  
  if requests.len == 0:
    return responses
    
  # 最初のリクエストからホスト情報を取得
  let uri = requests[0].url
  let host = uri.hostname
  let port = if uri.port == "": 
              if uri.scheme == "https": 443 else: 80
            else: 
              parseInt(uri.port)
  let secure = uri.scheme == "https"
  
  # 接続を取得
  let conn = await pool.getConnection(host, port, secure)
  
  try:
    # リクエストを順次送信（HTTP/2の場合は並列送信も可能）
    var requestFutures: seq[Future[HttpResponse]] = @[]
    
    for req in requests:
      # ここで実際のHTTPリクエスト処理を実装
      # 例: requestFutures.add(sendHttpRequest(conn, req))
      discard
      
    # 応答を待機
    for fut in requestFutures:
      let resp = await fut
      responses.add(resp)
      
    # 接続を再利用プールに戻す
    pool.releaseConnection(conn, true)
    
  except:
    # エラー発生時は接続を閉じる
    pool.closeConnection(conn)
    raise getCurrentException()
    
  return responses 