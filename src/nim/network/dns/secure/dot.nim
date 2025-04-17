import std/[asyncdispatch, asyncnet, net, ssl, tables, times, strutils, random, options, base64]
import ../resolver
import ../cache/manager

type
  DotResolver* = ref object
    cacheManager*: DnsCacheManager
    sslContext*: SslContext
    servers*: seq[DotServer]
    currentServerIndex*: int
    timeout*: int              # タイムアウト（ミリ秒）
    retries*: int              # 再試行回数
    enableIdnSupport*: bool    # 国際化ドメイン名（IDN）サポートを有効にするか
    connectionPool*: Table[string, AsyncSocket]  # サーバーごとの接続プール
    maxPoolSize*: int          # 接続プールの最大サイズ
  
  DotServer* = object
    name*: string              # サーバー名
    hostname*: string          # ホスト名
    ip*: string                # IPアドレス
    port*: int                 # ポート番号（デフォルト: 853）
    trustLevel*: int           # 信頼レベル（1-10）
    requiresConnectByHostname*: bool  # IPではなくホスト名で接続するか
    validateHostname*: bool    # 証明書のホスト名検証を行うか

# よく知られたDoTサーバー
const WELL_KNOWN_DOT_SERVERS = [
  DotServer(
    name: "Google",
    hostname: "dns.google",
    ip: "8.8.8.8",
    port: 853,
    trustLevel: 8,
    requiresConnectByHostname: false,
    validateHostname: true
  ),
  DotServer(
    name: "Cloudflare",
    hostname: "cloudflare-dns.com",
    ip: "1.1.1.1",
    port: 853,
    trustLevel: 9,
    requiresConnectByHostname: false,
    validateHostname: true
  ),
  DotServer(
    name: "Quad9",
    hostname: "dns.quad9.net",
    ip: "9.9.9.9",
    port: 853,
    trustLevel: 8,
    requiresConnectByHostname: false,
    validateHostname: true
  )
]

# DNS メッセージID生成用
var dnsMessageIdCounter: uint16 = 0

proc getNextDnsMessageId(): uint16 =
  ## DNS メッセージIDを生成
  result = dnsMessageIdCounter
  dnsMessageIdCounter = (dnsMessageIdCounter + 1) mod 65536

proc newDotResolver*(
  cacheFile: string = "dot_cache.json",
  customServers: seq[DotServer] = @[],
  timeout: int = 5000,
  retries: int = 2,
  maxCacheEntries: int = 10000,
  prefetchThreshold: float = 0.8,
  enableIdnSupport: bool = true,
  maxPoolSize: int = 5
): DotResolver =
  ## DNS over TLS (DoT) リゾルバーを作成
  result = DotResolver()
  
  # キャッシュマネージャー初期化
  result.cacheManager = newDnsCacheManager(
    cacheFile = cacheFile,
    maxEntries = maxCacheEntries,
    prefetchThreshold = prefetchThreshold
  )
  
  # SSLコンテキスト初期化
  when defined(ssl):
    result.sslContext = newContext(verifyMode = CVerifyPeer)
    result.sslContext.minProtocolVersion = TLSv1_2
  
  # DoTサーバー設定
  result.servers = if customServers.len > 0: customServers else: @WELL_KNOWN_DOT_SERVERS
  result.currentServerIndex = 0
  result.timeout = timeout
  result.retries = retries
  result.enableIdnSupport = enableIdnSupport
  result.maxPoolSize = maxPoolSize
  result.connectionPool = initTable[string, AsyncSocket]()
  
  echo "DoTリゾルバーを初期化: サーバー数=", result.servers.len
proc punycodeEncode(domain: string): string =
  ## IDN（国際化ドメイン名）をPunycodeに変換
  ## RFC 3492に準拠したPunycode実装
  if domain.len == 0:
    return ""
  
  # 英数字とハイフンのみの場合はそのまま返す
  var needsEncoding = false
  for c in domain:
    if not ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.'):
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
    prefixAce = "xn--"
  
  # バイアス調整関数
  proc adapt(delta: int, numpoints: int, firstTime: bool): int =
    var delta = delta
    if firstTime:
      delta = delta div damp
    else:
      delta = delta div 2
    
    delta += delta div numpoints
    var k = 0
    while delta > ((base - tmin) * tmax) div 2:
      delta = delta div (base - tmin)
      k += base
    
    return k + (((base - tmin + 1) * delta) div (delta + skew))
  
  # ドメイン部分ごとに処理
  var parts = domain.split('.')
  var result = newSeq[string](parts.len)
  
  for i, part in parts:
    if part.len == 0:
      result[i] = part
      continue
    
    # 基本文字と拡張文字に分離
    var basic = ""
    var extended = newSeq[tuple[pos: int, cp: int]]()
    
    for j, c in part:
      let cp = ord(c)
      if cp < 128:
        basic.add(c)
      else:
        extended.add((j, cp))
    
    # 拡張文字がない場合はそのまま
    if extended.len == 0:
      result[i] = part
      continue
    
    # Punycode変換開始
    var output = ""
    if basic.len > 0:
      output = basic & delimiter
    else:
      output = ""
    
    # 拡張文字の処理
    var n = initialN
    var delta = 0
    var bias = initialBias
    var h = basic.len
    var b = basic.len
    
    while h < part.len:
      # 次の最小のコードポイントを見つける
      var m = high(int)
      for (_, cp) in extended:
        if cp >= n and cp < m:
          m = cp
      
      # デルタ更新
      delta += (m - n) * (h + 1)
      n = m
      
      # 該当するコードポイントを処理
      for j, (pos, cp) in extended:
        if cp < n:
          delta += 1
        elif cp == n:
          # エンコード
          var q = delta
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
          let digit = q
          output.add(chr(if digit < 26: ord('a') + digit else: ord('0') + digit - 26))
          
          # バイアス調整
          bias = adapt(delta, h + 1, h == b)
          delta = 0
          h += 1
      
      delta += 1
      n += 1
    
    # ACE接頭辞を追加
    result[i] = prefixAce & output
  
  return result.join(".")

proc normalizeHostname(self: DotResolver, hostname: string): string =
  ## ホスト名を正規化（IDN対応）
  if hostname.len == 0:
    return ""
  
  var normalizedName = hostname.toLowerAscii()
  
  # 末尾のドットを削除
  if normalizedName.endsWith("."):
    normalizedName = normalizedName[0..^2]
  
  # IDN対応
  if self.enableIdnSupport:
    let parts = normalizedName.split('.')
    var encodedParts: seq[string] = @[]
    
    for part in parts:
      if part.len > 0:
        encodedParts.add(punycodeEncode(part))
    
    normalizedName = encodedParts.join(".")
  
  return normalizedName

proc getNextServer(self: DotResolver): DotServer =
  ## 次に使用するDoTサーバーを取得
  if self.servers.len == 0:
    # フォールバック: Googleを使用
    return WELL_KNOWN_DOT_SERVERS[0]
  
  result = self.servers[self.currentServerIndex]
  self.currentServerIndex = (self.currentServerIndex + 1) mod self.servers.len
  return result

proc getServerKey(server: DotServer): string =
  ## サーバー接続のキーを生成
  return server.hostname & ":" & $server.port

proc getConnection(self: DotResolver, server: DotServer): Future[AsyncSocket] {.async.} =
  ## DoTサーバーへの接続を取得
  let serverKey = getServerKey(server)
  
  # 既存の接続をチェック
  if serverKey in self.connectionPool:
    let socket = self.connectionPool[serverKey]
    if not socket.isClosed():
      return socket
    else:
      # 閉じた接続をプールから削除
      self.connectionPool.del(serverKey)
  
  # 新しい接続を作成
  var socket = newAsyncSocket()
  await socket.connect(server.ip, Port(server.port))
  
  # TLS接続を確立
  when defined(ssl):
    try:
      var sslSocket = newAsyncSocket()
      
      # SSL/TLSコンテキストを使用してソケットをラップ
      let hostname = if server.requiresConnectByHostname: server.hostname else: server.ip
      wrapConnectedSocket(self.sslContext, socket, handshakeAsClient, hostname)
      
      # 接続プールに追加
      if self.connectionPool.len < self.maxPoolSize:
        self.connectionPool[serverKey] = socket
      
      return socket
    except:
      echo "DoT TLS接続に失敗: ", getCurrentExceptionMsg()
      socket.close()
      raise
  else:
    # SSL未定義の場合はエラー
    socket.close()
    raise newException(Exception, "SSLサポートが有効になっていません")

proc releaseConnection(self: DotResolver, server: DotServer, socket: AsyncSocket) =
  ## 接続をプールに戻す、もしくは閉じる
  let serverKey = getServerKey(server)
  
  # ソケットが閉じている場合は何もしない
  if socket.isClosed():
    return
  
  # プールサイズをチェック
  if serverKey in self.connectionPool and self.connectionPool[serverKey] == socket:
    # このソケットが既にプールにある場合はそのまま
    discard
  elif self.connectionPool.len < self.maxPoolSize:
    # プールに空きがある場合は追加
    self.connectionPool[serverKey] = socket
  else:
    # プールが一杯の場合は閉じる
    socket.close()

proc buildDnsQuery(hostname: string, recordType: DnsRecordType): seq[byte] =
  ## DNSクエリパケットを構築
  ## RFC 1035に準拠したDNSパケットフォーマットを使用
  result = @[]
  
  # メッセージID（ランダムな16ビット値）
  let messageId = getNextDnsMessageId()
  result.add(byte((messageId shr 8) and 0xFF))
  result.add(byte(messageId and 0xFF))
  
  # フラグ（標準クエリ）
  result.add(0x01)  # QR=0（クエリ）, OPCODE=0（標準クエリ）, AA=0, TC=0, RD=1（再帰的）
  result.add(0x00)  # RA=0, Z=0, AD=0, CD=0, RCODE=0
  
  # QDCOUNTは1（1つの質問）
  result.add(0x00)
  result.add(0x01)
  
  # ANCOUNT, NSCOUNT, ARCOUNTはすべて0
  for i in 0..<6:
    result.add(0x00)
  
  # QNAMEの構築（ドメイン名をDNSフォーマットに変換）
  let parts = hostname.split('.')
  for part in parts:
    if part.len > 0:
      if part.len > 63:
        raise newException(ValueError, "ドメイン名のラベルが長すぎます: " & part)
      result.add(byte(part.len))
      for c in part:
        result.add(byte(c))
  
  # 終端の0
  result.add(0x00)
  
  # QTYPEはレコードタイプに応じて設定
  let typeValue = case recordType
    of A: 0x0001
    of AAAA: 0x001C
    of CNAME: 0x0005
    of MX: 0x000F
    of TXT: 0x0010
    of NS: 0x0002
    of SRV: 0x0021
    of PTR: 0x000C
    of SOA: 0x0006
    of CAA: 0x0101
    of DNSKEY: 0x0030
    of DS: 0x002B
    of RRSIG: 0x002E
    of NSEC: 0x002F
    of NSEC3: 0x0032
    of HTTPS: 0x0041
    of SVCB: 0x0040
    of TLSA: 0x0034
    of ANY: 0x00FF
  
  result.add(byte((typeValue shr 8) and 0xFF))
  result.add(byte(typeValue and 0xFF))
  
  # QCLASSはIN（インターネット）
  result.add(0x00)
  result.add(0x01)

proc parseDomainName(data: seq[byte], startPos: int, packetData: seq[byte]): tuple[name: string, endPos: int] =
  ## DNSパケット内のドメイン名を解析する
  ## 圧縮ポインタにも対応（RFC 1035 4.1.4）
  var pos = startPos
  var nameParts: seq[string] = @[]
  var isPointer = false
  var pointerFollowed = false
  
  while true:
    if pos >= data.len:
      break
      
    let labelLen = int(data[pos])
    
    # 終端の0を検出
    if labelLen == 0:
      pos += 1
      break
      
    # 圧縮ポインタを検出（上位2ビットが11）
    if (labelLen and 0xC0) == 0xC0:
      if not pointerFollowed:
        # 最初のポインタの場合、元の位置の次を返す
        isPointer = true
      
      # ポインタの位置を計算（下位14ビット）
      let pointerPos = ((labelLen and 0x3F) shl 8) or int(data[pos + 1])
      pos += 2
      
      # ポインタが指す位置からドメイン名を再帰的に解析
      let pointerResult = parseDomainName(packetData, pointerPos, packetData)
      nameParts.add(pointerResult.name.split('.'))
      
      # ポインタを追跡したらループを抜ける
      pointerFollowed = true
      break
    
    # 通常のラベルを処理
    var label = ""
    for i in 1..labelLen:
      label.add(char(data[pos + i]))
    
    nameParts.add(label)
    pos += labelLen + 1
  
  # 最終的なドメイン名を構築
  let name = nameParts.join(".")
  
  # ポインタを追跡した場合は元の位置の次を返す
  let endPos = if isPointer: pos else: pos
  
  return (name: name, endPos: endPos)

proc parseResourceRecord(data: seq[byte], pos: var int, packetData: seq[byte]): tuple[record: EnhancedDnsRecord, newPos: int] =
  ## DNSリソースレコードを解析する
  let domainResult = parseDomainName(data[pos..^1], 0, packetData)
  let name = domainResult.name
  pos += domainResult.endPos
  
  # TYPE, CLASS, TTL, RDLENGTHを解析
  let recordType = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
  pos += 2
  
  let recordClass = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
  pos += 2
  
  let ttl = (uint32(data[pos]) shl 24) or
            (uint32(data[pos + 1]) shl 16) or
            (uint32(data[pos + 2]) shl 8) or
            uint32(data[pos + 3])
  pos += 4
  
  let rdLength = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
  pos += 2
  
  # RDATAを解析
  var recordData: DnsRecordData
  
  case recordType
  of 0x0001: # A
    if rdLength == 4:
      let ipv4 = $data[pos] & "." & $data[pos+1] & "." & $data[pos+2] & "." & $data[pos+3]
      recordData = DnsRecordData(recordType: A, ipv4: ipv4)
  
  of 0x001C: # AAAA
    if rdLength == 16:
      var ipv6Parts: seq[string] = @[]
      for i in countup(0, 14, 2):
        let hexPart = toHex(int((uint16(data[pos+i]) shl 8) or uint16(data[pos+i+1])), 4)
        ipv6Parts.add(hexPart.toLowerAscii())
      let ipv6 = ipv6Parts.join(":")
      recordData = DnsRecordData(recordType: AAAA, ipv6: ipv6)
  
  of 0x0005: # CNAME
    let cnameResult = parseDomainName(data[pos..^1], 0, packetData)
    recordData = DnsRecordData(recordType: CNAME, cname: cnameResult.name)
  
  of 0x000F: # MX
    let preference = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
    let exchangeResult = parseDomainName(data[pos+2..^1], 0, packetData)
    recordData = DnsRecordData(recordType: MX, mxPreference: int(preference), mxExchange: exchangeResult.name)
  
  of 0x0010: # TXT
    var txtData = ""
    var txtPos = pos
    let endPos = pos + int(rdLength)
    
    while txtPos < endPos:
      let strLen = int(data[txtPos])
      txtPos += 1
      for i in 0..<strLen:
        if txtPos + i < endPos:
          txtData.add(char(data[txtPos + i]))
      txtPos += strLen
    
    recordData = DnsRecordData(recordType: TXT, txt: txtData)
  
  of 0x0002: # NS
    let nsResult = parseDomainName(data[pos..^1], 0, packetData)
    recordData = DnsRecordData(recordType: NS, ns: nsResult.name)
  
  of 0x0006: # SOA
    let mNameResult = parseDomainName(data[pos..^1], 0, packetData)
    var newPos = pos + mNameResult.endPos
    
    let rNameResult = parseDomainName(data[newPos..^1], 0, packetData)
    newPos += rNameResult.endPos
    
    let serial = (uint32(data[newPos]) shl 24) or
                 (uint32(data[newPos + 1]) shl 16) or
                 (uint32(data[newPos + 2]) shl 8) or
                 uint32(data[newPos + 3])
    newPos += 4
    
    let refresh = (uint32(data[newPos]) shl 24) or
                  (uint32(data[newPos + 1]) shl 16) or
                  (uint32(data[newPos + 2]) shl 8) or
                  uint32(data[newPos + 3])
    newPos += 4
    
    let retry = (uint32(data[newPos]) shl 24) or
                (uint32(data[newPos + 1]) shl 16) or
                (uint32(data[newPos + 2]) shl 8) or
                uint32(data[newPos + 3])
    newPos += 4
    
    let expire = (uint32(data[newPos]) shl 24) or
                 (uint32(data[newPos + 1]) shl 16) or
                 (uint32(data[newPos + 2]) shl 8) or
                 uint32(data[newPos + 3])
    newPos += 4
    
    let minimum = (uint32(data[newPos]) shl 24) or
                  (uint32(data[newPos + 1]) shl 16) or
                  (uint32(data[newPos + 2]) shl 8) or
                  uint32(data[newPos + 3])
    
    recordData = DnsRecordData(
      recordType: SOA,
      soaMName: mNameResult.name,
      soaRName: rNameResult.name,
      soaSerial: int(serial),
      soaRefresh: int(refresh),
      soaRetry: int(retry),
      soaExpire: int(expire),
      soaMinimum: int(minimum)
    )
  
  else:
    # その他のレコードタイプは生データとして保存
    var rawData: seq[byte] = @[]
    for i in 0..<rdLength:
      rawData.add(data[pos + i])
    
    let dnsType = case recordType
      of 0x0021: SRV
      of 0x000C: PTR
      of 0x0030: DNSKEY
      of 0x002B: DS
      of 0x002E: RRSIG
      of 0x002F: NSEC
      of 0x0032: NSEC3
      of 0x0101: CAA
      of 0x0041: HTTPS
      of 0x0040: SVCB
      of 0x0034: TLSA
      of 0x00FF: ANY
      else: UNKNOWN
    
    recordData = DnsRecordData(recordType: dnsType, rawData: rawData)
  
  pos += int(rdLength)
  
  # EnhancedDnsRecordを作成
  let now = getTime()
  let record = EnhancedDnsRecord(
    name: name,
    data: recordData,
    ttl: int(ttl),
    timestamp: now,
    accessCount: 1
  )
  
  return (record: record, newPos: pos)

proc parseDnsResponse(response: seq[byte], recordType: DnsRecordType): seq[EnhancedDnsRecord] =
  ## DNSレスポンスパケットを解析
  ## RFC 1035に準拠したDNSパケット解析を実装
  result = @[]
  
  if response.len < 12:
    # ヘッダーが不完全
    echo "DNSレスポンスが短すぎます: ", response.len, " バイト"
    return @[]
  
  # ヘッダーを解析
  let id = (uint16(response[0]) shl 8) or uint16(response[1])
  let flags = (uint16(response[2]) shl 8) or uint16(response[3])
  let qdcount = (uint16(response[4]) shl 8) or uint16(response[5])
  let ancount = (uint16(response[6]) shl 8) or uint16(response[7])
  let nscount = (uint16(response[8]) shl 8) or uint16(response[9])
  let arcount = (uint16(response[10]) shl 8) or uint16(response[11])
  
  # QRフラグをチェック（1はレスポンス）
  if (flags and 0x8000) == 0:
    echo "受信したパケットはDNSレスポンスではありません"
    return @[]
  
  # RCODEをチェック（エラーコード）
  let rcode = flags and 0x000F
  if rcode != 0:
    let rcodeMsg = case rcode
      of 1: "フォーマットエラー"
      of 2: "サーバー障害"
      of 3: "名前エラー（NXDOMAIN）"
      of 4: "未実装"
      of 5: "拒否"
      else: "未知のエラー"
    
    echo "DNSレスポンスエラー: RCODE=", rcode, " (", rcodeMsg, ")"
    return @[]
  
  # 現在の位置を追跡
  var pos = 12
  
  # 質問セクションをスキップ
  for i in 0..<qdcount:
    # ドメイン名をスキップ
    while pos < response.len:
      let labelLen = int(response[pos])
      
      # 終端の0またはポインタを検出
      if labelLen == 0 or (labelLen and 0xC0) == 0xC0:
        if (labelLen and 0xC0) == 0xC0:
          pos += 2  # ポインタは2バイト
        else:
          pos += 1  # 終端の0は1バイト
        break
      
      # 通常のラベルをスキップ
      pos += labelLen + 1
    
    # QTYPE, QCLASSをスキップ（各2バイト）
    pos += 4
  
  # 回答セクションを解析
  var records: seq[EnhancedDnsRecord] = @[]
  for i in 0..<ancount:
    if pos >= response.len:
      break
    
    # リソースレコードの解析
    let parseResult = parseResourceRecord(response, pos, response)
    if parseResult.success:
      records.add(parseResult.record)
      pos = parseResult.newPos
    else:
      echo "回答セクションのリソースレコード解析に失敗しました: ", parseResult.errorMsg
      break
  
  # 権威セクションを解析
  for i in 0..<nscount:
    if pos >= response.len:
      break
    
    let parseResult = parseResourceRecord(response, pos, response)
    if parseResult.success:
      # 権威レコードに特別なフラグを設定
      var authRecord = parseResult.record
      authRecord.isAuthority = true
      records.add(authRecord)
      pos = parseResult.newPos
    else:
      echo "権威セクションのリソースレコード解析に失敗しました: ", parseResult.errorMsg
      break
  
  # 追加セクションを解析
  for i in 0..<arcount:
    if pos >= response.len:
      break
    
    let parseResult = parseResourceRecord(response, pos, response)
    if parseResult.success:
      # 追加レコードに特別なフラグを設定
      var addRecord = parseResult.record
      addRecord.isAdditional = true
      records.add(addRecord)
      pos = parseResult.newPos
    else:
      echo "追加セクションのリソースレコード解析に失敗しました: ", parseResult.errorMsg
      break
  
  return records

proc queryDns(self: DotResolver, hostname: string, recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## DoTを使用してDNSクエリを実行
  let server = self.getNextServer()
  
  # DNSクエリの構築
  let query = buildDnsQuery(hostname, recordType)
  
  # クエリの長さを示す2バイトのプレフィックス
  let queryLen = query.len
  var lenPrefix = @[byte((queryLen shr 8) and 0xFF), byte(queryLen and 0xFF)]
  
  # DoTサーバーに接続
  var socket: AsyncSocket
  try:
    socket = await self.getConnection(server)
  except:
    echo "DoTサーバー接続に失敗: ", getCurrentExceptionMsg()
    return @[]
  
  # クエリ送信
  try:
    # まず長さプレフィックスを送信
    await socket.send(lenPrefix)
    
    # 次にDNSクエリを送信
    await socket.send(query)
    
    # レスポンスの長さを受信（2バイト）
    var lenBuf = newString(2)
    let lenReceived = await socket.recvInto(addr lenBuf[0], 2)
    if lenReceived != 2:
      echo "DoTレスポンス長の受信に失敗"
      self.releaseConnection(server, socket)
      return @[]
    
    # レスポンスの長さを計算
    let responseLen = (uint16(lenBuf[0].byte) shl 8) or uint16(lenBuf[1].byte)
    
    # レスポンスを受信
    var response = newString(responseLen)
    let responseReceived = await socket.recvInto(addr response[0], responseLen)
    if responseReceived != responseLen:
      echo "DoTレスポンスの受信に失敗: 予想=", responseLen, ", 実際=", responseReceived
      self.releaseConnection(server, socket)
      return @[]
    
    # 接続をプールに戻す
    self.releaseConnection(server, socket)
    
    # レスポンスを解析
    var responseBytes: seq[byte] = @[]
    for c in response:
      responseBytes.add(byte(c))
    
    let records = parseDnsResponse(responseBytes, recordType)
    return records
  except:
    echo "DoTクエリ実行中のエラー: ", getCurrentExceptionMsg()
    if not socket.isClosed():
      socket.close()
    return @[]

proc resolveWithType*(self: DotResolver, hostname: string, 
                     recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## 特定のレコードタイプのDNS解決を実行
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  echo "DoT解決中: ", normalizedHostname, " (", $recordType, ")"
  
  # キャッシュをチェック
  var cachedRecords = self.cacheManager.get(normalizedHostname, recordType)
  if cachedRecords.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DoTキャッシュヒット: ", normalizedHostname, " (", $recordType, ")"
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, recordType):
      echo "DoTをバックグラウンドでプリフェッチ: ", normalizedHostname, " (", $recordType, ")"
      asyncCheck self.prefetchWithType(normalizedHostname, recordType)
    
    return cachedRecords
  
  # DoTクエリを実行
  var records: seq[EnhancedDnsRecord]
  var success = false
  
  for attempt in 0..<(self.retries + 1):
    try:
      records = await self.queryDns(normalizedHostname, recordType)
      
      if records.len > 0:
        success = true
        break
    except:
      echo "DoTクエリ失敗 (試行 ", attempt + 1, "/", self.retries + 1, "): ", getCurrentExceptionMsg()
    
    if attempt < self.retries:
      # リトライ前に少し待機
      await sleepAsync(200 * (attempt + 1))
  
  if success and records.len > 0:
    # 解決成功した場合はキャッシュに保存
    for record in records:
      self.cacheManager.add(normalizedHostname, record.data.recordType, record)
    
    # 定期的にキャッシュを保存
    if rand(100) < 10:  # 約10%の確率で保存
      self.cacheManager.saveToFile()
    
    return records
  else:
    # 解決失敗の場合はネガティブキャッシュに追加
    self.cacheManager.addNegative(normalizedHostname)
    return @[]

proc prefetchWithType*(self: DotResolver, hostname: string, 
                      recordType: DnsRecordType): Future[void] {.async.} =
  ## 特定のレコードタイプでプリフェッチ
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  try:
    echo "DoTをプリフェッチ中: ", normalizedHostname, " (", $recordType, ")"
    discard await self.resolveWithType(normalizedHostname, recordType)
  except:
    echo "DoTプリフェッチに失敗: ", normalizedHostname, " (", $recordType, ")"

proc resolveHostname*(self: DotResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決する
  ## キャッシュにある場合はキャッシュから返す
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  echo "DoTを解決中: ", normalizedHostname
  
  # キャッシュをチェック
  var cachedIps = self.cacheManager.getIpAddresses(normalizedHostname)
  if cachedIps.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DoTキャッシュヒット: ", normalizedHostname
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, A) or
       self.cacheManager.shouldPrefetch(normalizedHostname, AAAA):
      echo "DoTをバックグラウンドでプリフェッチ: ", normalizedHostname
      asyncCheck self.prefetchHostname(normalizedHostname)
    
    return cachedIps
  
  # まずAレコードを解決
  var aRecords = await self.resolveWithType(normalizedHostname, A)
  
  # 次にAAAAレコードを解決
  var aaaaRecords = await self.resolveWithType(normalizedHostname, AAAA)
  
  # IPアドレスを抽出
  var ips: seq[string] = @[]
  for record in aRecords:
    ips.add(record.data.ipv4)
  
  for record in aaaaRecords:
    ips.add(record.data.ipv6)
  
  return ips

proc prefetchHostname*(self: DotResolver, hostname: string): Future[void] {.async.} =
  ## ホスト名の解決結果をバックグラウンドで事前に取得し、キャッシュを更新
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  try:
    echo "DoTをプリフェッチ中: ", normalizedHostname
    discard await self.resolveHostname(normalizedHostname)
  except:
    echo "DoTプリフェッチに失敗: ", normalizedHostname

proc prefetchBatch*(self: DotResolver, hostnames: seq[string]) {.async.} =
  ## 複数のホスト名を一括でプリフェッチ
  var futures: seq[Future[void]] = @[]
  
  for hostname in hostnames:
    futures.add(self.prefetchHostname(hostname))
  
  await all(futures)

proc resolveAll*(self: DotResolver, urls: seq[string]): Future[Table[string, seq[string]]] {.async.} =
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
      echo "DoT解決に失敗: ", hostname
      result[hostname] = @[]
  
  return result

proc clearCache*(self: DotResolver) =
  ## DoTキャッシュを完全にクリア
  self.cacheManager.clear()

proc getCacheStats*(self: DotResolver): string =
  ## キャッシュの統計情報を取得（文字列形式）
  let stats = self.cacheManager.getCacheStats()
  return $stats 