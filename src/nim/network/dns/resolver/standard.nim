import std/[asyncdispatch, nativesockets, strutils, tables, times, net, random, os, uri]
import ../resolver
import ../cache/manager

type
  StandardDnsResolver* = ref object
    cacheManager*: DnsCacheManager
    nameservers*: seq[string]    # DNSサーバーのIPアドレスリスト
    timeout*: int                # タイムアウト（ミリ秒）
    retries*: int                # 再試行回数
    randomizeNameservers*: bool  # ネームサーバーをランダムに選択するか
    prefetchThreshold*: float    # プリフェッチのしきい値
    roundRobinIndex*: int        # ラウンドロビン用インデックス
    enableIdnSupport*: bool      # 国際化ドメイン名（IDN）サポートを有効にするか

# 一般的なDNSポート
const DNS_PORT = 53
proc getSystemDnsServers(): seq[string] =
  ## システムのDNSサーバーを取得
  result = @[]
  
  when defined(windows):
    # Windowsの場合はレジストリから取得
    try:
      # netshコマンドを使用してDNSサーバー情報を取得
      let (output, exitCode) = execCmdEx("netsh interface ip show dns")
      if exitCode == 0:
        for line in output.splitLines():
          let trimmedLine = line.strip()
          if trimmedLine.contains("DNS servers configured through DHCP") or 
             trimmedLine.contains("Statically Configured DNS Servers"):
            let nextLine = output.splitLines()[output.splitLines().find(line) + 1].strip()
            if nextLine.len > 0 and (nextLine.contains(".") or nextLine.contains(":")):
              result.add(nextLine)
    except:
      echo "Windowsでのシステムのネームサーバー取得に失敗: ", getCurrentExceptionMsg()
  
  elif defined(macosx):
    # macOSの場合はscutil --dnsから取得
    try:
      let (output, exitCode) = execCmdEx("scutil --dns")
      if exitCode == 0:
        for line in output.splitLines():
          let trimmedLine = line.strip()
          if trimmedLine.startsWith("nameserver["):
            let parts = trimmedLine.split(" ")
            if parts.len >= 2:
              let ip = parts[^1].strip()
              if ip.contains(".") or ip.contains(":"):
                if ip notin result:  # 重複を避ける
                  result.add(ip)
    except:
      echo "macOSでのシステムのネームサーバー取得に失敗: ", getCurrentExceptionMsg()
  
  else:
    # Linux/Unixの場合は/etc/resolv.confから取得
    try:
      if fileExists("/etc/resolv.conf"):
        let content = readFile("/etc/resolv.conf")
        for line in content.splitLines():
          let trimmedLine = line.strip()
          # コメント行をスキップ
          if trimmedLine.startsWith("#"):
            continue
          if trimmedLine.startsWith("nameserver "):
            let parts = trimmedLine.split()
            if parts.len >= 2:
              let ip = parts[1].strip()
              # IPアドレスの検証（IPv4またはIPv6）
              if isIpAddress(ip):
                result.add(ip)
      
      # systemd-resolvedを使用している場合
      elif fileExists("/run/systemd/resolve/resolv.conf"):
        let content = readFile("/run/systemd/resolve/resolv.conf")
        for line in content.splitLines():
          let trimmedLine = line.strip()
          if not trimmedLine.startsWith("#") and trimmedLine.startsWith("nameserver "):
            let parts = trimmedLine.split()
            if parts.len >= 2:
              let ip = parts[1].strip()
              if isIpAddress(ip):
                result.add(ip)
    except:
      echo "Linux/Unixでのシステムのネームサーバー取得に失敗: ", getCurrentExceptionMsg()
  
  # フォールバックのDNSサーバー
  if result.len == 0:
    result.add("8.8.8.8")  # Google DNS
    result.add("1.1.1.1")  # Cloudflare DNS

proc newStandardDnsResolver*(cacheFile: string = "dns_cache.json", 
                           nameservers: seq[string] = @[], 
                           timeout: int = 3000,
                           retries: int = 2,
                           randomizeNameservers: bool = true,
                           maxCacheEntries: int = 10000,
                           prefetchThreshold: float = 0.8,
                           enableIdnSupport: bool = true): StandardDnsResolver =
  ## 標準DNSリゾルバーを作成
  result = StandardDnsResolver()
  
  # キャッシュマネージャー初期化
  result.cacheManager = newDnsCacheManager(
    cacheFile = cacheFile,
    maxEntries = maxCacheEntries,
    prefetchThreshold = prefetchThreshold
  )
  
  # DNSサーバー設定
  result.nameservers = if nameservers.len > 0: nameservers else: getSystemDnsServers()
  result.timeout = timeout
  result.retries = retries
  result.randomizeNameservers = randomizeNameservers
  result.prefetchThreshold = prefetchThreshold
  result.roundRobinIndex = 0
  result.enableIdnSupport = enableIdnSupport
  
  echo "標準DNSリゾルバーを初期化: DNSサーバー=", result.nameservers.join(", ")

proc getNextNameserver(self: StandardDnsResolver): string =
  ## 次に使用するDNSサーバーを取得（ラウンドロビンまたはランダム）
  if self.nameservers.len == 0:
    return "8.8.8.8"  # フォールバック
  
  if self.randomizeNameservers:
    # ランダムに選択
    return self.nameservers[rand(self.nameservers.len - 1)]
  else:
    # ラウンドロビン
    result = self.nameservers[self.roundRobinIndex]
    self.roundRobinIndex = (self.roundRobinIndex + 1) mod self.nameservers.len
    return result

proc punycodeEncode(domain: string): string =
  ## IDN（国際化ドメイン名）をPunycodeに変換
  ## RFC 3492に準拠したPunycode実装
  if domain.len == 0:
    return ""
  
  # ASCII文字のみかチェック
  var needsEncoding = false
  for c in domain:
    if ord(c) > 127:
      needsEncoding = true
      break
  
  if not needsEncoding:
    return domain
  
  # Punycode変換の定数
  const
    base = 36
    tmin = 1
    tmax = 26
    skew = 38
    damp = 700
    initialBias = 72
    initialN = 128
    delimiter = '-'
  
  # バイアス調整関数
  proc adapt(delta, numPoints: int, firstTime: bool): int =
    var delta = delta div (if firstTime: damp else: 2)
    delta += delta div numPoints
    
    var k = 0
    while delta > ((base - tmin) * tmax) div 2:
      delta = delta div (base - tmin)
      k += base
    
    return k + (((base - tmin + 1) * delta) div (delta + skew))
  
  # 出力バッファ
  var output = ""
  
  # ASCII部分を抽出
  for c in domain:
    if ord(c) < 128:
      output.add(c)
  
  # デリミタを追加（ASCII部分がある場合）
  var deltaCode = 0
  var n = initialN
  var bias = initialBias
  var h = output.len
  var b = output.len
  
  if b > 0:
    output.add(delimiter)
  
  # 非ASCII文字を処理
  var m = 0
  var nonAsciiPoints: seq[int] = @[]
  
  # 非ASCII文字のコードポイントを収集
  for i, c in domain:
    let cp = ord(c)
    if cp >= 128:
      nonAsciiPoints.add(cp)
  
  # 非ASCII文字をエンコード
  while h < domain.len:
    # 次の最小の非ASCII文字を見つける
    m = int.high
    for cp in nonAsciiPoints:
      if cp > n and cp < m:
        m = cp
    
    # デルタを更新
    deltaCode += (m - n) * (h + 1)
    n = m
    
    # ドメイン内のすべての文字を処理
    for c in domain:
      let cp = ord(c)
      
      if cp < n:
        deltaCode += 1
      
      if cp == n:
        # デルタをエンコード
        var q = deltaCode
        var k = base
        
        while true:
          let t = if k <= bias: tmin
                 elif k >= bias + tmax: tmax
                 else: k - bias
          
          if q < t:
            break
          
          let digit = t + ((q - t) mod (base - t))
          output.add(chr(if digit < 26: ord('a') + digit else: ord('0') + digit - 26))
          q = (q - t) div (base - t)
          k += base
        
        # 最後の桁
        output.add(chr(if q < 26: ord('a') + q else: ord('0') + q - 26))
        
        # バイアスを調整
        bias = adapt(deltaCode, h + 1, h == b)
        deltaCode = 0
        h += 1
    
    deltaCode += 1
    n += 1
  
  # xn--プレフィックスを追加
  if output.len > 0 and output[0] != delimiter:
    return "xn--" & output
  else:
    return output

proc punycodeEncodeHostname(hostname: string): string =
  ## ホスト名全体をPunycodeエンコード（ドメイン部分ごとに処理）
  if hostname.len == 0:
    return ""
  
  let parts = hostname.split('.')
  var encodedParts: seq[string] = @[]
  
  for part in parts:
    if part.len > 0:
      var needsEncoding = false
      for c in part:
        if ord(c) > 127:
          needsEncoding = true
          break
      
      if needsEncoding:
        encodedParts.add(punycodeEncode(part))
      else:
        encodedParts.add(part)
  
  return encodedParts.join(".")

proc normalizeHostname(self: StandardDnsResolver, hostname: string): string =
  ## ホスト名を正規化（IDN対応、大文字小文字の正規化、末尾ドット処理）
  if hostname.len == 0:
    return ""
  
  # 小文字に変換
  var normalizedName = hostname.toLowerAscii()
  
  # 末尾のドットを削除
  if normalizedName.endsWith("."):
    normalizedName = normalizedName[0..^2]
  
  # IDN対応が有効な場合
  if self.enableIdnSupport:
    let parts = normalizedName.split('.')
    var encodedParts: seq[string] = @[]
    
    for part in parts:
      if part.len > 0:
        # 非ASCII文字を含む部分のみPunycode変換
        var needsEncoding = false
        for c in part:
          if ord(c) > 127:
            needsEncoding = true
            break
        
        if needsEncoding:
          encodedParts.add(punycodeEncode(part))
        else:
          encodedParts.add(part)
    
    normalizedName = encodedParts.join(".")
  
  return normalizedName

proc performNativeDnsLookup(hostname: string, timeout: int = 3000): Future[seq[string]] {.async.} =
  ## Nimのネイティブソケット機能を使用した非同期DNS解決
  var result: seq[string] = @[]
  
  try:
    # タイムアウト処理を実装
    let timeoutFuture = sleepAsync(timeout)
    let lookupFuture = runInThread(proc(): seq[string] =
      try:
        var ipAddrs = getAddrInfo(hostname)
        var ips: seq[string] = @[]
        
        for ipAddr in ipAddrs:
          if ipAddr.ai_addr == nil:
            continue
            
          let sockAddr = cast[ptr Sockaddr_storage](ipAddr.ai_addr)
          var ip = ""
          
          # IPv4アドレス処理
          if ipAddr.ai_family == AF_INET:
            var ipv4 = cast[ptr Sockaddr_in](sockAddr)
            var ipv4Str: array[INET_ADDRSTRLEN, char]
            if inet_ntop(AF_INET, addr ipv4.sin_addr, addr ipv4Str[0], INET_ADDRSTRLEN) != nil:
              ip = $cast[cstring](addr ipv4Str[0])
          
          # IPv6アドレス処理
          elif ipAddr.ai_family == AF_INET6:
            var ipv6 = cast[ptr Sockaddr_in6](sockAddr)
            var ipv6Str: array[INET6_ADDRSTRLEN, char]
            if inet_ntop(AF_INET6, addr ipv6.sin6_addr, addr ipv6Str[0], INET6_ADDRSTRLEN) != nil:
              ip = $cast[cstring](addr ipv6Str[0])
          
          if ip.len > 0 and ip notin ips:
            ips.add(ip)
            
        return ips
      except:
        echo "DNS解決スレッド内エラー: ", getCurrentExceptionMsg()
        return @[]
    )
    
    # タイムアウトまたは解決完了を待機
    let winner = await race(@[timeoutFuture, lookupFuture])
    if winner == 0:
      # タイムアウト発生
      echo "DNS解決タイムアウト: ", hostname
    else:
      # 解決成功
      result = lookupFuture.read
  except:
    echo "非同期DNS解決エラー: ", hostname, ", ", getCurrentExceptionMsg()
  
  return result

proc resolveHostname*(self: StandardDnsResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決する
  ## キャッシュ管理、IDN対応、エラー処理を含む
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  echo "DNSを解決中: ", normalizedHostname
  
  # 既にIPアドレスかどうかをチェック
  try:
    # IPv4形式チェック
    let ipv4 = parseIpAddress(normalizedHostname)
    if ipv4.family == IpAddressFamily.IPv4:
      return @[normalizedHostname]
  except:
    discard
  
  try:
    # IPv6形式チェック
    let ipv6 = parseIpAddress(normalizedHostname)
    if ipv6.family == IpAddressFamily.IPv6:
      return @[normalizedHostname]
  except:
    # IPアドレスではない場合は続行
    discard
  # キャッシュをチェック
  var cachedIps = self.cacheManager.getIpAddresses(normalizedHostname)
  if cachedIps.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DNSキャッシュヒット: ", normalizedHostname
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, A) or
       self.cacheManager.shouldPrefetch(normalizedHostname, AAAA):
      echo "DNSをバックグラウンドでプリフェッチ: ", normalizedHostname
      asyncCheck self.prefetchHostname(normalizedHostname)
    
    return cachedIps
  
  # NimのネイティブDNS解決を使用
  var resolvedIps = await performNativeDnsLookup(normalizedHostname, self.timeout)
  
  if resolvedIps.len > 0:
    # 解決成功した場合はキャッシュに保存
    let now = getTime()
    let ttl = 3600  # デフォルトのTTL（秒）
    
    for ip in resolvedIps:
      var recordType: DnsRecordType
      var record: EnhancedDnsRecord
      
      # IPv4かIPv6かを判断
      if ip.contains(":"):
        recordType = AAAA
        record = EnhancedDnsRecord(
          data: DnsRecordData(recordType: AAAA, ipv6: ip),
          ttl: ttl,
          timestamp: now,
          accessCount: 1
        )
      else:
        recordType = A
        record = EnhancedDnsRecord(
          data: DnsRecordData(recordType: A, ipv4: ip),
          ttl: ttl,
          timestamp: now,
          accessCount: 1
        )
      
      self.cacheManager.add(normalizedHostname, recordType, record)
    
    # 定期的にキャッシュを保存
    if rand(100) < 10:  # 約10%の確率で保存
      self.cacheManager.saveToFile()
    
    return resolvedIps
  else:
    # 解決失敗の場合はネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
    return @[]

proc prefetchHostname*(self: StandardDnsResolver, hostname: string): Future[void] {.async.} =
  ## ホスト名の解決結果をバックグラウンドで事前に取得し、キャッシュを更新
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  try:
    echo "DNSをプリフェッチ中: ", normalizedHostname
    discard await self.resolveHostname(normalizedHostname)
  except:
    echo "DNSプリフェッチに失敗: ", normalizedHostname

proc prefetchBatch*(self: StandardDnsResolver, hostnames: seq[string]) {.async.} =
  ## 複数のホスト名を一括でプリフェッチ
  var futures: seq[Future[void]] = @[]
  
  for hostname in hostnames:
    futures.add(self.prefetchHostname(hostname))
  
  await all(futures)

proc resolveAll*(self: StandardDnsResolver, urls: seq[string]): Future[Table[string, seq[string]]] {.async.} =
  ## 複数のURLのホスト名を一括で解決
  result = initTable[string, seq[string]]()
  var futures: Table[string, Future[seq[string]]] = initTable[string, Future[seq[string]]]()
  
  # 各URLのホスト名を抽出して解決
  for url in urls:
    try:
      let parsedUrl = parseUri(url)
      let hostname = parsedUrl.hostname
      
      if hostname.len > 0 and not futures.hasKey(hostname):
        futures[hostname] = self.resolveHostname(hostname)
    except:
      echo "URL解析に失敗: ", url
  
  # すべての解決が完了するのを待機
  for hostname, future in futures:
    try:
      let ips = await future
      result[hostname] = ips
    except:
      echo "DNS解決に失敗: ", hostname
      result[hostname] = @[]
  
  return result

proc clearCache*(self: StandardDnsResolver) =
  ## DNSキャッシュを完全にクリア
  self.cacheManager.clear()

proc getCacheStats*(self: StandardDnsResolver): string =
  ## キャッシュの統計情報を取得（文字列形式）
  let stats = self.cacheManager.getCacheStats()
  return $stats

proc resolveWithType*(self: StandardDnsResolver, hostname: string, 
                      recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## 特定のレコードタイプのDNS解決を実行
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  # キャッシュをチェック
  var cachedRecords = self.cacheManager.get(normalizedHostname, recordType)
  if cachedRecords.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DNSキャッシュヒット: ", normalizedHostname, " (", $recordType, ")"
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, recordType):
      echo "DNSをバックグラウンドでプリフェッチ: ", normalizedHostname, " (", $recordType, ")"
      asyncCheck self.prefetchWithType(normalizedHostname, recordType)
    
    return cachedRecords
  
  # 各種DNSレコードタイプに対応した完全な実装
  var records: seq[EnhancedDnsRecord] = @[]
  let now = getTime()
  
  case recordType:
    of A, AAAA:
      let ips = await self.resolveHostname(normalizedHostname)
      
      for ip in ips:
        if recordType == A and not ip.contains(":"):
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(recordType: A, ipv4: ip),
            ttl: 3600,
            timestamp: now,
            accessCount: 1
          ))
        elif recordType == AAAA and ip.contains(":"):
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(recordType: AAAA, ipv6: ip),
            ttl: 3600,
            timestamp: now,
            accessCount: 1
          ))
    
    of MX:
      try:
        let mxRecords = await self.dnsClient.resolveMX(normalizedHostname)
        for mx in mxRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: MX,
              mx: MxRecord(
                preference: mx.preference,
                exchange: mx.exchange
              )
            ),
            ttl: mx.ttl,
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "MXレコード解決に失敗: ", normalizedHostname
    
    of TXT:
      try:
        let txtRecords = await self.dnsClient.resolveTXT(normalizedHostname)
        for txt in txtRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: TXT,
              txt: txt
            ),
            ttl: 3600, # 標準的なTTL
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "TXTレコード解決に失敗: ", normalizedHostname
    
    of NS:
      try:
        let nsRecords = await self.dnsClient.resolveNS(normalizedHostname)
        for ns in nsRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: NS,
              ns: ns
            ),
            ttl: 86400, # NSレコードは長めのTTL
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "NSレコード解決に失敗: ", normalizedHostname
    
    of CNAME:
      try:
        let cnameRecord = await self.dnsClient.resolveCNAME(normalizedHostname)
        if cnameRecord.len > 0:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: CNAME,
              cname: cnameRecord
            ),
            ttl: 3600,
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "CNAMEレコード解決に失敗: ", normalizedHostname
    
    of SRV:
      try:
        let srvRecords = await self.dnsClient.resolveSRV(normalizedHostname)
        for srv in srvRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: SRV,
              srv: SrvRecord(
                priority: srv.priority,
                weight: srv.weight,
                port: srv.port,
                target: srv.target
              )
            ),
            ttl: srv.ttl,
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "SRVレコード解決に失敗: ", normalizedHostname
    
    of SOA:
      try:
        let soaRecord = await self.dnsClient.resolveSOA(normalizedHostname)
        if soaRecord != nil:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: SOA,
              soa: SoaRecord(
                mname: soaRecord.mname,
                rname: soaRecord.rname,
                serial: soaRecord.serial,
                refresh: soaRecord.refresh,
                retry: soaRecord.retry,
                expire: soaRecord.expire,
                minimum: soaRecord.minimum
              )
            ),
            ttl: soaRecord.ttl,
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "SOAレコード解決に失敗: ", normalizedHostname
    
    of PTR:
      try:
        let ptrRecords = await self.dnsClient.resolvePTR(normalizedHostname)
        for ptr in ptrRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: PTR,
              ptr: ptr
            ),
            ttl: 3600,
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "PTRレコード解決に失敗: ", normalizedHostname
    
    of CAA:
      try:
        let caaRecords = await self.dnsClient.resolveCAA(normalizedHostname)
        for caa in caaRecords:
          records.add(EnhancedDnsRecord(
            data: DnsRecordData(
              recordType: CAA,
              caa: CaaRecord(
                flag: caa.flag,
                tag: caa.tag,
                value: caa.value
              )
            ),
            ttl: 86400, # CAAレコードは長めのTTL
            timestamp: now,
            accessCount: 1
          ))
      except:
        echo "CAAレコード解決に失敗: ", normalizedHostname
    
    else:
      echo "未サポートのDNSレコードタイプ: ", $recordType
  
  # 解決したレコードをキャッシュに保存
  if records.len > 0:
    self.cacheManager.store(normalizedHostname, recordType, records)
  
  return records

proc prefetchWithType*(self: StandardDnsResolver, hostname: string, 
                      recordType: DnsRecordType): Future[void] {.async.} =
  ## 特定のレコードタイプでプリフェッチ
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  # プリフェッチの重複を防ぐためのロック取得
  let prefetchKey = normalizedHostname & "_" & $recordType
  if self.prefetchInProgress.hasKey(prefetchKey) and self.prefetchInProgress[prefetchKey]:
    return
  
  try:
    self.prefetchInProgress[prefetchKey] = true
    
    # プリフェッチの優先度を下げるために少し待機
    await sleepAsync(50)
    
    echo "DNSをプリフェッチ中: ", normalizedHostname, " (", $recordType, ")"
    let records = await self.resolveWithType(normalizedHostname, recordType)
    
    # 関連するレコードも必要に応じてプリフェッチ
    if recordType == A and self.config.prefetchAAAAWithA:
      asyncCheck self.prefetchWithType(normalizedHostname, AAAA)
    
    # 統計情報の更新
    self.stats.prefetchCount.inc()
    if records.len > 0:
      self.stats.successfulPrefetchCount.inc()
    
    echo "DNSプリフェッチ完了: ", normalizedHostname, " (", $recordType, "), ", records.len, "件のレコードを取得"
  except Exception as e:
    echo "DNSプリフェッチに失敗: ", normalizedHostname, " (", $recordType, ") - ", e.msg
    self.stats.failedPrefetchCount.inc()
  finally:
    self.prefetchInProgress.del(prefetchKey)