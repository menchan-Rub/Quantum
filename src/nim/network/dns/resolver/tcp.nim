import std/[asyncdispatch, asyncnet, net, tables, options, times, strutils]
import ../message, ../packet, ../records
import ../cache/manager

type
  TcpDnsResolver* = ref object
    ## TCP DNSリゾルバ
    nameservers*: seq[string]   # DNSサーバーIPアドレスリスト
    port*: int                  # DNSサーバーポート
    cacheManager*: DnsCacheManager  # キャッシュマネージャー
    timeout*: int               # タイムアウト（ミリ秒）
    retries*: int               # 再試行回数
    connectTimeout*: int        # 接続タイムアウト（ミリ秒）
    randomizeNameservers*: bool # サーバーをランダムに選択するか
    roundRobinIndex*: int       # ラウンドロビン用インデックス
    connectionPool*: Table[string, AsyncSocket]  # 接続プール
    maxPoolSize*: int           # 最大接続プールサイズ
    idleTimeout*: int           # アイドル接続タイムアウト（ミリ秒）
    lastConnectionTime*: Table[string, Time]  # 最終接続時間

const
  DEFAULT_DNS_TCP_PORT* = 53      # 標準的なDNSポート
  DEFAULT_TCP_TIMEOUT* = 5000     # デフォルトタイムアウト（5秒）
  DEFAULT_TCP_RETRIES* = 2        # デフォルト再試行回数
  DEFAULT_CONNECT_TIMEOUT* = 2000 # デフォルト接続タイムアウト（2秒）
  DEFAULT_MAX_POOL_SIZE* = 5      # デフォルト最大接続プールサイズ
  DEFAULT_IDLE_TIMEOUT* = 30000   # デフォルトアイドルタイムアウト（30秒）

# システムDNSサーバー取得
proc getSystemDnsServers*(): seq[string] =
  ## システムのDNSサーバーを取得
  result = @[]
  
  when defined(windows):
    # Windows用実装
    try:
      # Windows APIを使用してDNSサーバー情報を取得
      var
        adaptersInfo: ptr IP_ADAPTER_ADDRESSES
        bufLen: ULONG = 15000  # 初期バッファサイズ
        ret: DWORD
        attempts = 0
        maxAttempts = 3
      
      # 必要なバッファサイズを動的に調整
      while attempts < maxAttempts:
        adaptersInfo = cast[ptr IP_ADAPTER_ADDRESSES](alloc(bufLen))
        if adaptersInfo == nil:
          raise newException(OutOfMemError, "メモリ割り当て失敗")
        
        ret = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, nil, adaptersInfo, addr bufLen)
        
        if ret == ERROR_BUFFER_OVERFLOW:
          dealloc(adaptersInfo)
          inc(attempts)
          continue
        elif ret == ERROR_SUCCESS:
          break
        else:
          dealloc(adaptersInfo)
          raise newException(OSError, "GetAdaptersAddresses失敗: " & $ret)
        
        inc(attempts)
      
      # アダプタ情報を走査してDNSサーバーを収集
      var currentAdapter = adaptersInfo
      while currentAdapter != nil:
        # アクティブな接続のみ処理
        if currentAdapter.OperStatus == IfOperStatusUp:
          var dnsServer = currentAdapter.FirstDnsServerAddress
          while dnsServer != nil:
            let sockAddr = cast[ptr SockAddr](dnsServer.Address.lpSockaddr)
            
            # IPv4アドレスの処理
            if sockAddr.sa_family == AF_INET:
              let ipv4 = cast[ptr SockAddr_in](sockAddr)
              var ipAddress = newString(INET_ADDRSTRLEN)
              if inet_ntop(AF_INET, addr ipv4.sin_addr, cstring(ipAddress), INET_ADDRSTRLEN) != nil:
                result.add($ipAddress)
            
            # IPv6アドレスの処理
            elif sockAddr.sa_family == AF_INET6:
              let ipv6 = cast[ptr SockAddr_in6](sockAddr)
              var ipAddress = newString(INET6_ADDRSTRLEN)
              if inet_ntop(AF_INET6, addr ipv6.sin6_addr, cstring(ipAddress), INET6_ADDRSTRLEN) != nil:
                result.add($ipAddress)
            
            dnsServer = dnsServer.Next
        
        currentAdapter = currentAdapter.Next
      
      # メモリ解放
      if adaptersInfo != nil:
        dealloc(adaptersInfo)
    
    except:
      echo "Windows DNSサーバー取得エラー: ", getCurrentExceptionMsg()
  
  elif defined(macosx):
    # macOS用実装
    try:
      # scutil --dns コマンドを実行してDNS情報を取得
      let (output, exitCode) = execCmdEx("scutil --dns")
      if exitCode == 0:
        # 出力を解析してDNSサーバーを抽出
        var inResolverSection = false
        for line in output.splitLines():
          let trimmedLine = line.strip()
          
          if trimmedLine.startsWith("resolver #"):
            inResolverSection = true
            continue
          
          if inResolverSection and trimmedLine.startsWith("nameserver["):
            let parts = trimmedLine.split(" ")
            if parts.len >= 2:
              let ip = parts[^1].strip()
              # 簡易的なIPアドレス検証
              if ip.contains(".") or ip.contains(":"):
                if ip notin result:  # 重複を避ける
                  result.add(ip)
          
          if inResolverSection and (trimmedLine == "" or trimmedLine.startsWith("domain")):
            inResolverSection = false
      
      # バックアップ方法: /etc/resolv.conf も確認
      if result.len == 0 and fileExists("/etc/resolv.conf"):
        let content = readFile("/etc/resolv.conf")
        for line in content.splitLines():
          let trimmedLine = line.strip()
          if trimmedLine.startsWith("nameserver "):
            let parts = trimmedLine.split()
            if parts.len >= 2:
              let ip = parts[1].strip()
              if ip.contains(".") or ip.contains(":"):
                if ip notin result:
                  result.add(ip)
    except:
      echo "macOS DNSサーバー取得エラー: ", getCurrentExceptionMsg()
  
  else:
    # Unix/Linux系用実装
    try:
      # 主要なDNS設定ファイルを確認
      let dnsConfigFiles = [
        "/etc/resolv.conf",
        "/run/systemd/resolve/resolv.conf",
        "/run/resolvconf/resolv.conf"
      ]
      
      for configFile in dnsConfigFiles:
        if fileExists(configFile):
          let content = readFile(configFile)
          for line in content.splitLines():
            let trimmedLine = line.strip()
            if trimmedLine.startsWith("nameserver "):
              let parts = trimmedLine.split()
              if parts.len >= 2:
                let ip = parts[1].strip()
                # IPアドレス検証
                if ip.contains(".") or ip.contains(":"):
                  if ip notin result:
                    result.add(ip)
      
      # NetworkManagerの設定も確認
      if result.len == 0:
        let (nmOutput, nmExitCode) = execCmdEx("nmcli -t -f IP4.DNS,IP6.DNS dev show")
        if nmExitCode == 0:
          for line in nmOutput.splitLines():
            if line.contains("DNS"):
              let parts = line.split(":")
              if parts.len >= 2:
                let ip = parts[1].strip()
                if ip.len > 0 and ip notin result:
                  result.add(ip)
      
      # systemd-resolvedの設定も確認
      if result.len == 0:
        let (resolvedOutput, resolvedExitCode) = execCmdEx("systemd-resolve --status")
        if resolvedExitCode == 0:
          var inDnsSection = false
          for line in resolvedOutput.splitLines():
            let trimmedLine = line.strip()
            
            if trimmedLine.contains("DNS Servers:"):
              inDnsSection = true
              continue
            
            if inDnsSection and trimmedLine.len > 0 and not trimmedLine.startsWith("DNS"):
              let ip = trimmedLine.strip()
              if ip.contains(".") or ip.contains(":"):
                if ip notin result:
                  result.add(ip)
            else:
              inDnsSection = false
    except:
      echo "Unix/Linux DNSサーバー取得エラー: ", getCurrentExceptionMsg()
  
  # 重複を除去して結果を返す
  result = deduplicate(result)
  # フォールバックのDNSサーバー
  if result.len == 0:
    result.add("8.8.8.8")  # Google DNS
    result.add("1.1.1.1")  # Cloudflare DNS

proc newTcpDnsResolver*(
  cacheManager: DnsCacheManager = nil,
  nameservers: seq[string] = @[],
  port: int = DEFAULT_DNS_TCP_PORT,
  timeout: int = DEFAULT_TCP_TIMEOUT,
  retries: int = DEFAULT_TCP_RETRIES,
  connectTimeout: int = DEFAULT_CONNECT_TIMEOUT,
  randomizeNameservers: bool = true,
  maxPoolSize: int = DEFAULT_MAX_POOL_SIZE,
  idleTimeout: int = DEFAULT_IDLE_TIMEOUT
): TcpDnsResolver =
  ## 新しいTCP DNSリゾルバーを作成
  result = TcpDnsResolver()
  
  # DNSサーバー設定
  result.nameservers = if nameservers.len > 0: nameservers else: getSystemDnsServers()
  result.port = port
  
  # キャッシュマネージャー設定
  result.cacheManager = if cacheManager != nil: cacheManager else: newDnsCacheManager()
  
  # タイムアウトと再試行設定
  result.timeout = timeout
  result.retries = retries
  result.connectTimeout = connectTimeout
  
  # サーバー選択ロジック
  result.randomizeNameservers = randomizeNameservers
  result.roundRobinIndex = 0
  
  # 接続プール設定
  result.connectionPool = initTable[string, AsyncSocket]()
  result.maxPoolSize = maxPoolSize
  result.idleTimeout = idleTimeout
  result.lastConnectionTime = initTable[string, Time]()
  
  # 定期的なクリーンアップタスクを開始
  asyncCheck result.cleanupIdleConnections()
  
  echo "TCPリゾルバーを初期化: サーバー=", result.nameservers.join(", ")

proc getNextNameserver*(self: TcpDnsResolver): string =
  ## 次に使用するDNSサーバーを取得
  if self.nameservers.len == 0:
    return "8.8.8.8"  # フォールバック
  
  if self.randomizeNameservers:
    # ランダムに選択
    randomize()
    return self.nameservers[rand(self.nameservers.len - 1)]
  else:
    # ラウンドロビン
    result = self.nameservers[self.roundRobinIndex]
    self.roundRobinIndex = (self.roundRobinIndex + 1) mod self.nameservers.len
    return result

proc getConnectionKey(nameserver: string, port: int): string =
  ## 接続プール用のキーを生成
  return nameserver & ":" & $port

proc getConnection*(self: TcpDnsResolver, nameserver: string): Future[AsyncSocket] {.async.} =
  ## DNSサーバーへの接続を取得（接続プールを使用）
  let key = getConnectionKey(nameserver, self.port)
  
  # プールから既存の接続を取得
  if key in self.connectionPool:
    let socket = self.connectionPool[key]
    
    # ソケットが有効かチェック
    if not socket.isClosed():
      # 最終使用時間を更新
      self.lastConnectionTime[key] = getTime()
      return socket
    else:
      # 無効なソケットをプールから削除
      self.connectionPool.del(key)
      if key in self.lastConnectionTime:
        self.lastConnectionTime.del(key)
  
  # 新しい接続を作成
  var socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  
  # タイムアウト付きで接続
  try:
    # 非同期接続を開始
    var connectFuture = socket.connect(nameserver, Port(self.port))
    
    # タイムアウト
    var timeoutFuture = sleepAsync(self.connectTimeout)
    
    let completed = await connectFuture or timeoutFuture
    if not completed:
      socket.close()
      raise newException(DnsTransportError, "DNSサーバー接続がタイムアウトしました: " & nameserver)
  except:
    socket.close()
    raise newException(DnsTransportError, "DNSサーバーへの接続に失敗: " & getCurrentExceptionMsg())
  
  # 接続プールに追加（サイズ制限を考慮）
  if self.connectionPool.len < self.maxPoolSize:
    self.connectionPool[key] = socket
    self.lastConnectionTime[key] = getTime()
  
  return socket

proc releaseConnection*(self: TcpDnsResolver, nameserver: string, socket: AsyncSocket) =
  ## 接続をプールに戻す
  let key = getConnectionKey(nameserver, self.port)
  
  # ソケットが閉じられている場合は何もしない
  if socket.isClosed():
    return
  
  # 既にプールにある場合は何もしない
  if key in self.connectionPool and self.connectionPool[key] == socket:
    return
  
  # プールサイズをチェック
  if self.connectionPool.len < self.maxPoolSize:
    # プールに空きがある場合は追加
    self.connectionPool[key] = socket
    self.lastConnectionTime[key] = getTime()
  else:
    # プールが一杯の場合は閉じる
    socket.close()

proc cleanupIdleConnections*(self: TcpDnsResolver): Future[void] {.async.} =
  ## 未使用の接続をクリーンアップする（定期的なタスク）
  while true:
    # 一定間隔でチェック
    await sleepAsync(5000)  # 5秒ごとにチェック
    
    let now = getTime()
    var keysToRemove: seq[string] = @[]
    
    # アイドルタイムアウトした接続を特定
    for key, lastTime in self.lastConnectionTime:
      if (now - lastTime).inMilliseconds >= self.idleTimeout and key in self.connectionPool:
        keysToRemove.add(key)
    
    # 特定した接続を閉じて削除
    for key in keysToRemove:
      if key in self.connectionPool:
        let socket = self.connectionPool[key]
        if not socket.isClosed():
          socket.close()
        self.connectionPool.del(key)
        self.lastConnectionTime.del(key)
        echo "アイドル接続をクローズ: ", key

proc queryDns*(self: TcpDnsResolver, domain: string, recordType: DnsRecordType): Future[DnsMessage] {.async.} =
  ## TCPを使用してDNSクエリを送信し、レスポンスを受信
  var lastError: string = ""
  
  for attempt in 0..<(self.retries + 1):
    # サーバーを選択
    let nameserver = self.getNextNameserver()
    
    # クエリメッセージ作成
    var queryMsg = createQuery(domain, recordType)
    queryMsg.header.id = getRandomDnsId()
    
    # EDNSを追加
    addEdnsRecord(queryMsg)
    
    # 接続を取得
    var socket: AsyncSocket
    try:
      socket = await self.getConnection(nameserver)
    except:
      lastError = "接続失敗: " & getCurrentExceptionMsg()
      echo "DNS TCP接続に失敗 (試行 ", attempt + 1, "/", self.retries + 1, "): ", lastError
      continue
    
    try:
      # クエリをTCP経由で送信
      await sendTcpQuery(socket, queryMsg)
      
      # タイムアウト付きでレスポンスを受信
      var response: DnsMessage
      
      try:
        var responseFuture = receiveTcpResponse(socket, self.timeout)
        var timeoutFuture = sleepAsync(self.timeout)
        
        let completed = await responseFuture or timeoutFuture
        if not completed:
          raise newException(DnsTransportError, "DNS TCPレスポンスがタイムアウトしました")
        
        response = responseFuture.read
      except:
        # タイムアウトかレスポンス受信エラー - ソケットを閉じる
        if not socket.isClosed():
          socket.close()
        raise
      
      # レスポンスの検証
      if not verifyDnsResponse(queryMsg, response):
        raise newException(DnsPacketError, "DNS TCPレスポンスがクエリと一致しません")
      
      # 接続をプールに戻す
      self.releaseConnection(nameserver, socket)
      
      return response
    except:
      # エラー発生 - ソケットを閉じる
      if not socket.isClosed():
        socket.close()
      
      lastError = getCurrentExceptionMsg()
      echo "DNS TCPクエリ失敗 (試行 ", attempt + 1, "/", self.retries + 1, "): ", lastError
    
    # 再試行前に少し待機
    if attempt < self.retries:
      await sleepAsync(100 * (attempt + 1))
  
  # すべての試行が失敗
  raise newException(DnsPacketError, "DNS TCPクエリに失敗: " & lastError)

proc resolveHostname*(self: TcpDnsResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決
  ## キャッシュチェックあり
  var normalizedHostname = hostname.toLowerAscii()
  if normalizedHostname.endsWith('.'):
    normalizedHostname = normalizedHostname[0..^2]
  
  echo "TCP DNSを解決中: ", normalizedHostname
  
  # IPアドレスかどうかをチェック
  try:
    discard parseIpAddress(normalizedHostname)
    # 既にIPアドレスならそのまま返す
    return @[normalizedHostname]
  except:
    # IPアドレスではない場合は続行
    discard
  
  # キャッシュをチェック
  var cachedIps = self.cacheManager.getIpAddresses(normalizedHostname)
  if cachedIps.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DNS TCPキャッシュヒット: ", normalizedHostname
    return cachedIps
  
  var resolvedIps: seq[string] = @[]
  
  # Aレコード（IPv4）をクエリ
  try:
    let response = await self.queryDns(normalizedHostname, A)
    
    # レスポンスからIPv4アドレスを抽出
    for answer in response.answers:
      if answer.rrtype == A and answer.rrclass == DNS_CLASS_IN:
        if answer.rdlength == 4:
          let ip = extractIPv4FromRData(answer.rdata)
          resolvedIps.add(ip)
          
          # キャッシュに追加
          var record = DnsRecord(
            domain: normalizedHostname,
            recordType: A,
            ttl: answer.ttl.int,
            data: ip,
            timestamp: getTime()
          )
          self.cacheManager.add(normalizedHostname, A, $record, answer.ttl.int)
  except:
    echo "TCP IPv4解決に失敗: ", getCurrentExceptionMsg()
  
  # AAAAレコード（IPv6）をクエリ
  try:
    let response = await self.queryDns(normalizedHostname, AAAA)
    
    # レスポンスからIPv6アドレスを抽出
    for answer in response.answers:
      if answer.rrtype == AAAA and answer.rrclass == DNS_CLASS_IN:
        if answer.rdlength == 16:
          let ip = extractIPv6FromRData(answer.rdata)
          resolvedIps.add(ip)
          
          # キャッシュに追加
          var record = DnsRecord(
            domain: normalizedHostname,
            recordType: AAAA,
            ttl: answer.ttl.int,
            data: ip,
            timestamp: getTime()
          )
          self.cacheManager.add(normalizedHostname, AAAA, $record, answer.ttl.int)
  except:
    echo "TCP IPv6解決に失敗: ", getCurrentExceptionMsg()
  
  # いずれの解決も失敗した場合
  if resolvedIps.len == 0:
    # ネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
    echo "TCP DNSの解決に失敗: ", normalizedHostname
  
  return resolvedIps

proc resolveWithType*(self: TcpDnsResolver, hostname: string, 
                     recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.} =
  ## 特定のレコードタイプでホスト名を解決
  ## キャッシュチェックあり
  var normalizedHostname = hostname.toLowerAscii()
  if normalizedHostname.endsWith('.'):
    normalizedHostname = normalizedHostname[0..^2]
  
  echo "TCP DNSを解決中: ", normalizedHostname, " (", $recordType, ")"
  
  # キャッシュをチェック
  var cachedRecords = self.cacheManager.getRecords(normalizedHostname, recordType)
  if cachedRecords.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "TCP DNSキャッシュヒット: ", normalizedHostname, " (", $recordType, ")"
    return cachedRecords
  
  var resolvedRecords: seq[DnsRecord] = @[]
  
  # クエリの実行
  try:
    let response = await self.queryDns(normalizedHostname, recordType)
    
    # レスポンスからレコードを抽出
    for answer in response.answers:
      if answer.rrtype == recordType and answer.rrclass == DNS_CLASS_IN:
        let record = resourceRecordToDnsRecord(answer)
        resolvedRecords.add(record)
        
        # キャッシュに追加
        self.cacheManager.add(normalizedHostname, recordType, $record, answer.ttl.int)
  except:
    echo "TCP DNSレコード解決に失敗: ", getCurrentExceptionMsg()
    # ネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
  
  return resolvedRecords

proc close*(self: TcpDnsResolver) =
  ## すべての接続をクローズし、リゾルバを閉じる
  for key, socket in self.connectionPool:
    if not socket.isClosed():
      socket.close()
  
  self.connectionPool.clear()
  self.lastConnectionTime.clear() 