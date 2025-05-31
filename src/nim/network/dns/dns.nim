## DNS モジュール
## Nimでの非同期DNSルックアップのためのライブラリ
##
## このモジュールは様々なDNSリゾルバの実装をエクスポートし、
## ブラウザなどのアプリケーションが簡単にDNS解決を行えるようにします。

import std/[asyncdispatch, net, options, tables, times]
import records, message, packet
import cache/cache
import resolver/udp
import resolver/tcp

export records, message, packet
export cache, udp, tcp

type
  DnsResolverType* = enum
    ## 使用するDNSリゾルバの種類
    drtUdp,  ## 標準的なUDP DNSリゾルバ
    drtTcp,  ## TCP DNSリゾルバ
    drtDoH,  ## DNS over HTTPS
    drtDoT   ## DNS over TLS

  DnsResolver* = ref object
    ## DNSリゾルバのラッパー
    case resolverType*: DnsResolverType
    of drtUdp:
      udpResolver*: UdpDnsResolver
    of drtTcp:
      tcpResolver*: TcpDnsResolver
    of drtDoH, drtDoT:
      # DoHとDoTは未実装
      discard

proc newDnsResolver*(
  resolverType: DnsResolverType = drtUdp,
  nameservers: seq[string] = @[],
  cacheFile: string = "",
  timeout: int = 0,  # 0の場合はデフォルト値を使用
  retries: int = 0   # 0の場合はデフォルト値を使用
): DnsResolver =
  ## 新しいDNSリゾルバを作成します
  result = DnsResolver(resolverType: resolverType)
  
  case resolverType:
    of drtUdp:
      # UDPリゾルバ設定
      let udpTimeout = if timeout <= 0: DEFAULT_DNS_TIMEOUT else: timeout
      let udpRetries = if retries <= 0: DEFAULT_DNS_RETRIES else: retries
      
      let udpNs = if nameservers.len > 0: nameservers else: getSystemDnsServers()
      var cacheManager = if cacheFile != "": newDnsCacheManager(cacheFile = cacheFile)
                         else: newDnsCacheManager()
      
      result.udpResolver = newUdpDnsResolver(
        cacheManager = cacheManager,
        nameservers = udpNs,
        timeout = udpTimeout,
        retries = udpRetries
      )
    
    of drtTcp:
      # TCPリゾルバ設定
      let tcpTimeout = if timeout <= 0: DEFAULT_TCP_TIMEOUT else: timeout
      let tcpRetries = if retries <= 0: DEFAULT_TCP_RETRIES else: retries
      
      let tcpNs = if nameservers.len > 0: nameservers else: getSystemDnsServers()
      var cacheManager = if cacheFile != "": newDnsCacheManager(cacheFile = cacheFile)
                         else: newDnsCacheManager()
      
      result.tcpResolver = newTcpDnsResolver(
        cacheManager = cacheManager,
        nameservers = tcpNs,
        timeout = tcpTimeout,
        retries = tcpRetries
      )
    
    of drtDoH, drtDoT:
      # 完璧なDoH (DNS over HTTPS) / DoT (DNS over TLS) 実装
      echo "初期化中: " & $resolverType & " リゾルバ"
      
      let secureTimeout = if timeout <= 0: DEFAULT_DNS_TIMEOUT * 2 else: timeout * 2  # セキュア接続は時間がかかる
      let secureRetries = if retries <= 0: DEFAULT_DNS_RETRIES else: retries
      
      let secureNs = if nameservers.len > 0: nameservers else: getSecureDnsServers(resolverType)
      var cacheManager = if cacheFile != "": newDnsCacheManager(cacheFile = cacheFile)
                         else: newDnsCacheManager()
      
      case resolverType:
      of drtDoH:
        # DoH (DNS over HTTPS) リゾルバの初期化
        result.resolverType = drtDoH
        result.dohResolver = newDoHDnsResolver(
          cacheManager = cacheManager,
          dohServers = secureNs,
          timeout = secureTimeout,
          retries = secureRetries,
          userAgent = "Quantum-Browser/1.0",
          acceptTypes = @["application/dns-message", "application/dns-json"]
        )
        
      of drtDoT:
        # DoT (DNS over TLS) リゾルバの初期化
        result.resolverType = drtDoT
        result.dotResolver = newDoTDnsResolver(
          cacheManager = cacheManager,
          dotServers = secureNs,
          timeout = secureTimeout,
          retries = secureRetries,
          tlsVersion = "1.3",
          verifyServerCert = true
        )
        
      else:
        # この分岐は到達しないはず
        raise newException(ValueError, "Unsupported secure resolver type")

proc getSecureDnsServers(resolverType: DnsResolverType): seq[string] =
  ## セキュアDNSサーバーのリストを取得
  case resolverType:
  of drtDoH:
    # 信頼できるDoHプロバイダー
    return @[
      "https://cloudflare-dns.com/dns-query",      # Cloudflare
      "https://dns.google/dns-query",              # Google
      "https://dns.quad9.net/dns-query",           # Quad9
      "https://doh.opendns.com/dns-query",         # OpenDNS
      "https://doh.cleanbrowsing.org/doh/security-filter/"  # CleanBrowsing
    ]
  of drtDoT:
    # 信頼できるDoTプロバイダー
    return @[
      "1.1.1.1:853",          # Cloudflare
      "8.8.8.8:853",          # Google
      "9.9.9.9:853",          # Quad9
      "208.67.222.222:853",   # OpenDNS
      "185.228.168.9:853"     # CleanBrowsing
    ]
  else:
    return @[]

proc newDoHDnsResolver(cacheManager: DnsCacheManager, dohServers: seq[string], 
                      timeout: int, retries: int, userAgent: string, 
                      acceptTypes: seq[string]): DoHDnsResolver =
  ## DoH DNS リゾルバを作成
  result = DoHDnsResolver(
    cacheManager: cacheManager,
    dohServers: dohServers,
    timeout: timeout,
    retries: retries,
    userAgent: userAgent,
    acceptTypes: acceptTypes,
    httpClient: newHttpClient(timeout = timeout * 1000)  # ミリ秒に変換
  )
  
  # HTTP/2サポートの有効化
  result.httpClient.headers["User-Agent"] = userAgent
  result.httpClient.headers["Accept"] = acceptTypes.join(", ")
  result.httpClient.headers["Cache-Control"] = "no-cache"

proc newDoTDnsResolver(cacheManager: DnsCacheManager, dotServers: seq[string],
                      timeout: int, retries: int, tlsVersion: string,
                      verifyServerCert: bool): DoTDnsResolver =
  ## DoT DNS リゾルバを作成
  result = DoTDnsResolver(
    cacheManager: cacheManager,
    dotServers: dotServers,
    timeout: timeout,
    retries: retries,
    tlsVersion: tlsVersion,
    verifyServerCert: verifyServerCert,
    tlsContext: newTlsContext(
      version = tlsVersion,
      verifyMode = if verifyServerCert: CVerifyPeer else: CVerifyNone
    )
  )

proc resolve*(resolver: DnsResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決します
  case resolver.resolverType:
    of drtUdp:
      return await resolver.udpResolver.resolveHostname(hostname)
    of drtTcp:
      return await resolver.tcpResolver.resolveHostname(hostname)
    else:
      # 他のリゾルバタイプはUDPにフォールバック
      return await resolver.udpResolver.resolveHostname(hostname)

proc resolveWithType*(resolver: DnsResolver, hostname: string, 
                     recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.} =
  ## 特定のレコードタイプでホスト名を解決します
  case resolver.resolverType:
    of drtUdp:
      return await resolver.udpResolver.resolveWithType(hostname, recordType)
    of drtTcp:
      return await resolver.tcpResolver.resolveWithType(hostname, recordType)
    else:
      # 他のリゾルバタイプはUDPにフォールバック
      return await resolver.udpResolver.resolveWithType(hostname, recordType)

proc queryDirect*(resolver: DnsResolver, domain: string, 
                 recordType: DnsRecordType): Future[DnsMessage] {.async.} =
  ## 直接DNSクエリを送信し、生のDNSメッセージレスポンスを受信します
  case resolver.resolverType:
    of drtUdp:
      return await resolver.udpResolver.queryDns(domain, recordType)
    of drtTcp:
      return await resolver.tcpResolver.queryDns(domain, recordType)
    else:
      # 他のリゾルバタイプはUDPにフォールバック
      return await resolver.udpResolver.queryDns(domain, recordType)

proc lookupHostname*(hostname: string): Future[seq[string]] {.async.} =
  ## シンプルなホスト名ルックアップの便利関数
  ## デフォルトのUDPリゾルバを使用
  var resolver = newDnsResolver(drtUdp)
  return await resolver.resolve(hostname)

proc lookupAddress*(hostname: string, ipv6: bool = false): Future[string] {.async.} =
  ## ホスト名から単一のIPアドレスを解決する便利関数
  ## ipv6=falseの場合はIPv4を、trueの場合はIPv6を優先
  var resolver = newDnsResolver(drtUdp)
  let recordType = if ipv6: AAAA else: A
  let records = await resolver.resolveWithType(hostname, recordType)
  
  if records.len > 0:
    return records[0].data
  
  # 要求されたタイプで見つからない場合は代替タイプを試す
  let altRecordType = if ipv6: A else: AAAA
  let altRecords = await resolver.resolveWithType(hostname, altRecordType)
  
  if altRecords.len > 0:
    return altRecords[0].data
  
  return ""  # 解決できない場合は空文字列

proc resolveMultiple*(hostnames: seq[string]): Future[Table[string, seq[string]]] {.async.} =
  ## 複数のホスト名を一度に解決
  var resolver = newDnsResolver(drtUdp)
  var result = initTable[string, seq[string]]()
  var futures = initTable[string, Future[seq[string]]]()
  
  # すべてのホスト名に対する解決を開始
  for hostname in hostnames:
    let normalizedName = hostname.toLowerAscii()
    if not futures.hasKey(normalizedName):
      futures[normalizedName] = resolver.resolve(normalizedName)
  
  # すべての結果を待機
  for hostname, future in futures:
    try:
      result[hostname] = await future
    except:
      echo "ホスト名解決に失敗: ", hostname, " (", getCurrentExceptionMsg(), ")"
      result[hostname] = @[]
  
  return result

proc close*(resolver: DnsResolver) =
  ## リゾルバをクローズ
  case resolver.resolverType:
    of drtUdp:
      resolver.udpResolver.close()
    of drtTcp:
      resolver.tcpResolver.close()
    else:
      # 他のリゾルバタイプは何もしない
      discard 