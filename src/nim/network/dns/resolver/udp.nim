import std/[asyncdispatch, asyncnet, net, random, tables, options, times]
import ../message, ../packet, ../records
import ../cache/manager

type
  UdpDnsResolver* = ref object
    ## UDP DNSリゾルバ
    nameservers*: seq[string]  # DNSサーバーIPアドレスリスト
    socket*: AsyncSocket       # UDPソケット
    cacheManager*: DnsCacheManager  # キャッシュマネージャー
    timeout*: int              # タイムアウト（ミリ秒）
    retries*: int              # 再試行回数
    queryTracker*: DnsQueryTracker  # クエリ追跡
    randomizeNameservers*: bool  # サーバーをランダムに選択するか
    roundRobinIndex*: int      # ラウンドロビン用インデックス

const
  DEFAULT_DNS_TIMEOUT* = 3000  # デフォルトタイムアウト（3秒）
  DEFAULT_DNS_RETRIES* = 2     # デフォルト再試行回数

# システムDNSサーバー取得
proc getSystemDnsServers*(): seq[string] =
  ## システムのDNSサーバーを取得
  result = @[]
  
  when defined(windows):
    # Windows用実装
    try:
      # Windowsレジストリからネットワークアダプタ情報を取得
      import winlean, registry
      
      const 
        TCPIP_PATH = r"SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        MAX_KEY_LENGTH = 255
      
      var
        hKey: HKEY
        subKeyName = newString(MAX_KEY_LENGTH)
        subKeyLen: DWORD
        index: DWORD = 0
        numSubKeys: DWORD
        maxSubKeyLen: DWORD
      
      # TCPIPインターフェースキーを開く
      if regOpenKeyEx(HKEY_LOCAL_MACHINE, TCPIP_PATH, 0, KEY_READ, addr hKey) == ERROR_SUCCESS:
        # サブキー情報を取得
        if regQueryInfoKey(hKey, nil, nil, nil, addr numSubKeys, addr maxSubKeyLen, 
                          nil, nil, nil, nil, nil, nil) == ERROR_SUCCESS:
          # 各ネットワークインターフェースをループ
          for i in 0..<numSubKeys:
            subKeyLen = MAX_KEY_LENGTH.DWORD
            if regEnumKeyEx(hKey, i, subKeyName, addr subKeyLen, nil, nil, nil, nil) == ERROR_SUCCESS:
              var adapterKey: HKEY
              let interfacePath = TCPIP_PATH & "\\" & subKeyName.substr(0, subKeyLen.int - 1)
              
              # アダプタのキーを開く
              if regOpenKeyEx(HKEY_LOCAL_MACHINE, interfacePath, 0, KEY_READ, addr adapterKey) == ERROR_SUCCESS:
                # NameServerの値を取得
                var
                  dataType: DWORD
                  dataSize: DWORD = 1024
                  data = newString(1024)
                
                if regQueryValueEx(adapterKey, "NameServer", nil, addr dataType, cast[PBYTE](addr data[0]), addr dataSize) == ERROR_SUCCESS:
                  let nameServers = data.substr(0, dataSize.int - 2).strip()
                  if nameServers.len > 0:
                    # カンマまたはスペースで区切られたDNSサーバーリスト
                    for server in nameServers.split({',', ' '}):
                      let trimmed = server.strip()
                      if trimmed.len > 0:
                        result.add(trimmed)
                
                regCloseKey(adapterKey)
          
          regCloseKey(hKey)
    except:
      echo "Windowsレジストリからのシステムネームサーバー取得に失敗: ", getCurrentExceptionMsg()
  
  elif defined(macosx):
    # macOS用実装
    try:
      import osproc
      
      # scutilコマンドを使用してDNS設定を取得
      let (output, exitCode) = execCmdEx("scutil --dns | grep nameserver | awk '{print $3}'")
      if exitCode == 0:
        for line in output.splitLines():
          let server = line.strip()
          if server.len > 0 and (server.contains(".") or server.contains(":")):
            if not result.contains(server):
              result.add(server)
      
      # 代替方法としてnetworksetupコマンドも試す
      if result.len == 0:
        let (netOutput, netExitCode) = execCmdEx("networksetup -getdnsservers \"$(networksetup -listallnetworkservices | grep -v '*' | head -n 1)\"")
        if netExitCode == 0 and not netOutput.contains("There aren't any DNS Servers"):
          for line in netOutput.splitLines():
            let server = line.strip()
            if server.len > 0 and (server.contains(".") or server.contains(":")):
              if not result.contains(server):
                result.add(server)
    except:
      echo "macOSシステムDNSサーバーの取得に失敗: ", getCurrentExceptionMsg()
  
  else:
    # Unix系用実装
    try:
      # /etc/resolv.confからDNSサーバーを取得
      if fileExists("/etc/resolv.conf"):
        let content = readFile("/etc/resolv.conf")
        for line in content.splitLines():
          let trimmedLine = line.strip()
          if trimmedLine.startsWith("nameserver "):
            let parts = trimmedLine.split()
            if parts.len >= 2:
              let ip = parts[1].strip()
              # IPアドレス検証
              if ip.contains(".") or ip.contains(":"):
                if not result.contains(ip):
                  result.add(ip)
      
      # systemd-resolvedを使用しているシステム向け
      if result.len == 0 and fileExists("/run/systemd/resolve/resolv.conf"):
        let content = readFile("/run/systemd/resolve/resolv.conf")
        for line in content.splitLines():
          let trimmedLine = line.strip()
          if trimmedLine.startsWith("nameserver "):
            let parts = trimmedLine.split()
            if parts.len >= 2:
              let ip = parts[1].strip()
              if ip.contains(".") or ip.contains(":"):
                if not result.contains(ip):
                  result.add(ip)
      
      # NetworkManagerの設定を確認
      if result.len == 0:
        import osproc
        let (output, exitCode) = execCmdEx("nmcli dev show | grep DNS")
        if exitCode == 0:
          for line in output.splitLines():
            if line.contains("DNS"):
              let parts = line.split(":")
              if parts.len >= 2:
                let ip = parts[1].strip()
                if ip.contains(".") or ip.contains(":"):
                  if not result.contains(ip):
                    result.add(ip)
    except:
      echo "Unix系システムDNSサーバーの取得に失敗: ", getCurrentExceptionMsg()
  
  # フォールバックのDNSサーバー
  if result.len == 0:
    result.add("8.8.8.8")  # Google DNS
    result.add("1.1.1.1")  # Cloudflare DNS

proc newUdpDnsResolver*(
  cacheManager: DnsCacheManager = nil,
  nameservers: seq[string] = @[],
  timeout: int = DEFAULT_DNS_TIMEOUT,
  retries: int = DEFAULT_DNS_RETRIES,
  randomizeNameservers: bool = true
): UdpDnsResolver =
  ## 新しいUDP DNSリゾルバーを作成
  result = UdpDnsResolver()
  
  # DNSサーバー設定
  result.nameservers = if nameservers.len > 0: nameservers else: getSystemDnsServers()
  
  # キャッシュマネージャー設定
  result.cacheManager = if cacheManager != nil: cacheManager else: newDnsCacheManager()
  
  # ソケット作成
  result.socket = newAsyncSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  
  # タイムアウトと再試行設定
  result.timeout = timeout
  result.retries = retries
  
  # クエリトラッカー設定
  result.queryTracker = newDnsQueryTracker(result.socket, dtpUdp)
  
  # サーバー選択ロジック
  result.randomizeNameservers = randomizeNameservers
  result.roundRobinIndex = 0
  
  # レスポンスハンドラ開始
  asyncCheck result.handleResponses()
  
  echo "UDPリゾルバーを初期化: サーバー=", result.nameservers.join(", ")

proc getNextNameserver*(self: UdpDnsResolver): string =
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

proc handleResponses*(self: UdpDnsResolver): Future[void] {.async.} =
  ## 非同期にDNSレスポンスを処理
  # UDPレスポンスハンドラを起動
  await self.queryTracker.handleUdpResponses()

proc queryDns*(self: UdpDnsResolver, domain: string, recordType: DnsRecordType): Future[DnsMessage] {.async.} =
  ## UDPを使用してDNSクエリを送信し、レスポンスを受信
  var serverIndex = 0
  var lastError: string = ""
  
  for attempt in 0..<(self.retries + 1):
    # サーバーを選択
    let nameserver = self.getNextNameserver()
    
    # クエリメッセージ作成
    var queryMsg = createQuery(domain, recordType)
    queryMsg.header.id = getRandomDnsId()
    
    # EDNSを追加
    addEdnsRecord(queryMsg)
    
    # クエリを追跡
    let responseFuture = self.queryTracker.trackQuery(queryMsg.header.id)
    
    try:
      # クエリ送信
      await sendUdpQuery(self.socket, queryMsg, nameserver)
      
      # 応答を待機（タイムアウト付き）
      let timeoutFuture = sleepAsync(self.timeout)
      let completed = await responseFuture or timeoutFuture
      
      if completed:
        # 応答受信成功
        return responseFuture.read
      else:
        # タイムアウト
        lastError = "タイムアウト (" & nameserver & ")"
    except:
      # エラー発生
      lastError = getCurrentExceptionMsg()
      echo "DNSクエリ失敗 (試行 ", attempt + 1, "/", self.retries + 1, "): ", lastError
    
    # 再試行前に少し待機
    if attempt < self.retries:
      await sleepAsync(50 * (attempt + 1))
  
  # すべての試行が失敗
  raise newException(DnsPacketError, "DNSクエリに失敗: " & lastError)

proc resolveHostname*(self: UdpDnsResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決
  ## キャッシュチェックあり
  var normalizedHostname = hostname.toLowerAscii()
  if normalizedHostname.endsWith('.'):
    normalizedHostname = normalizedHostname[0..^2]
  
  echo "DNSを解決中: ", normalizedHostname
  
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
    echo "DNSキャッシュヒット: ", normalizedHostname
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
    echo "IPv4解決に失敗: ", getCurrentExceptionMsg()
  
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
    echo "IPv6解決に失敗: ", getCurrentExceptionMsg()
  
  # いずれの解決も失敗した場合
  if resolvedIps.len == 0:
    # ネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
    echo "DNSの解決に失敗: ", normalizedHostname
  
  return resolvedIps

proc resolveWithType*(self: UdpDnsResolver, hostname: string, 
                     recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.} =
  ## 特定のレコードタイプでホスト名を解決
  ## キャッシュチェックあり
  var normalizedHostname = hostname.toLowerAscii()
  if normalizedHostname.endsWith('.'):
    normalizedHostname = normalizedHostname[0..^2]
  
  echo "DNSを解決中: ", normalizedHostname, " (", $recordType, ")"
  
  # キャッシュをチェック
  var cachedRecords = self.cacheManager.getRecords(normalizedHostname, recordType)
  if cachedRecords.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DNSキャッシュヒット: ", normalizedHostname, " (", $recordType, ")"
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
    echo "DNSレコード解決に失敗: ", getCurrentExceptionMsg()
    # ネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
  
  return resolvedRecords

proc close*(self: UdpDnsResolver) =
  ## リゾルバを閉じる
  self.socket.close() 