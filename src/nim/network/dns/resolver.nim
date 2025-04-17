import std/[asyncdispatch, net, nativesockets, strutils, random, endians, tables, sequtils, options, times, sugar, os]
import records, cache

const
  DNS_PORT = 53
  MAX_UDP_SIZE = 512
  DNS_TIMEOUT = 5000 # ミリ秒
  MAX_RETRIES = 3
  ROOT_SERVERS = [
    "198.41.0.4",       # a.root-servers.net
    "199.9.14.201",     # b.root-servers.net
    "192.33.4.12",      # c.root-servers.net
    "199.7.91.13",      # d.root-servers.net
    "192.203.230.10",   # e.root-servers.net
    "192.5.5.241",      # f.root-servers.net
    "192.112.36.4",     # g.root-servers.net
    "198.97.190.53",    # h.root-servers.net
    "192.36.148.17",    # i.root-servers.net
    "192.58.128.30",    # j.root-servers.net
    "193.0.14.129",     # k.root-servers.net
    "199.7.83.42",      # l.root-servers.net
    "202.12.27.33"      # m.root-servers.net
  ]

type
  DnsHeader = object
    id: uint16
    flags: uint16
    qdcount: uint16  # 質問数
    ancount: uint16  # 回答数
    nscount: uint16  # 権威ネームサーバー数
    arcount: uint16  # 追加レコード数

  DnsQuestion = object
    name: string
    qtype: uint16
    qclass: uint16

  DnsResolver* = ref object
    nameservers*: seq[string]
    cache*: DnsCache
    useRootServers: bool
    randomizeNameservers: bool
    timeout: int  # ミリ秒
    maxRetries: int
    checkHosts: bool  # hostsファイルを確認するかどうか
    hostsPath: string  # hostsファイルのパス

# ビット操作ユーティリティ
proc setBit(value: var uint16, bit: int, on: bool) =
  if on:
    value = value or (1'u16 shl bit)
  else:
    value = value and (not (1'u16 shl bit))

proc getBit(value: uint16, bit: int): bool =
  return (value and (1'u16 shl bit)) != 0

# DNSヘッダーのフラグ操作
proc setQR(header: var DnsHeader, value: bool) = setBit(header.flags, 15, value)
proc setOpcode(header: var DnsHeader, value: uint16) =
  header.flags = (header.flags and 0x87FF'u16) or ((value and 0x0F'u16) shl 11)
proc setAA(header: var DnsHeader, value: bool) = setBit(header.flags, 10, value)
proc setTC(header: var DnsHeader, value: bool) = setBit(header.flags, 9, value)
proc setRD(header: var DnsHeader, value: bool) = setBit(header.flags, 8, value)
proc setRA(header: var DnsHeader, value: bool) = setBit(header.flags, 7, value)
proc setZ(header: var DnsHeader, value: uint16) =
  header.flags = (header.flags and 0xFF8F'u16) or ((value and 0x07'u16) shl 4)
proc setRcode(header: var DnsHeader, value: uint16) =
  header.flags = (header.flags and 0xFFF0'u16) or (value and 0x0F'u16)

proc getQR(header: DnsHeader): bool = getBit(header.flags, 15)
proc getOpcode(header: DnsHeader): uint16 = (header.flags shr 11) and 0x0F'u16
proc getAA(header: DnsHeader): bool = getBit(header.flags, 10)
proc getTC(header: DnsHeader): bool = getBit(header.flags, 9)
proc getRD(header: DnsHeader): bool = getBit(header.flags, 8)
proc getRA(header: DnsHeader): bool = getBit(header.flags, 7)
proc getZ(header: DnsHeader): uint16 = (header.flags shr 4) and 0x07'u16
proc getRcode(header: DnsHeader): uint16 = header.flags and 0x0F'u16

# エンコード/デコードユーティリティ
proc encodeDomainName(domain: string): seq[byte] =
  # ドメイン名をDNSワイヤーフォーマットにエンコード
  result = @[]
  let labels = domain.split('.')
  
  for label in labels:
    if label.len > 0:
      result.add(byte(label.len))
      for c in label:
        result.add(byte(c))
  
  # 終了ラベル
  result.add(0)

proc decodeDomainName(data: seq[byte], offset: var int): string =
  # DNSワイヤーフォーマットからドメイン名をデコード
  result = ""
  var position = offset
  var jumped = false
  var jumpPos = 0
  var length = 0.byte
  
  # ジャンプの最大回数（無限ループ防止）
  const maxJumps = 10
  var jumps = 0
  
  while true:
    # バッファチェック
    if position >= data.len:
      return ""
    
    length = data[position]
    
    # 終端または長さ0のラベル
    if length == 0:
      position += 1
      break
    
    # 圧縮ポインタ
    if (length and 0xC0'u8) == 0xC0'u8:
      if position + 1 >= data.len:
        return ""
      
      if not jumped:
        offset = position + 2
        jumped = true
      
      # ポインタ位置の計算
      jumpPos = ((length and 0x3F'u8).int shl 8) or data[position + 1].int
      position = jumpPos
      
      inc(jumps)
      if jumps >= maxJumps:
        return ""  # 無限ループを防止
      
      continue
    
    # 通常のラベル
    position += 1
    
    # ラベル長チェック
    if position + length.int > data.len:
      return ""
    
    # ラベルをデコード
    if result.len > 0:
      result &= "."
    
    for i in 0..<length.int:
      result &= char(data[position])
      position += 1
  
  # オフセットの更新（ジャンプがなかった場合のみ）
  if not jumped:
    offset = position

proc encodeHeader(header: DnsHeader): seq[byte] =
  result = newSeq[byte](12)
  
  # ID
  var id = header.id
  bigEndian16(addr result[0], addr id)
  
  # フラグ
  var flags = header.flags
  bigEndian16(addr result[2], addr flags)
  
  # その他のフィールド
  var qdcount = header.qdcount
  bigEndian16(addr result[4], addr qdcount)
  
  var ancount = header.ancount
  bigEndian16(addr result[6], addr ancount)
  
  var nscount = header.nscount
  bigEndian16(addr result[8], addr nscount)
  
  var arcount = header.arcount
  bigEndian16(addr result[10], addr arcount)

proc decodeHeader(data: seq[byte]): tuple[header: DnsHeader, bytesRead: int] =
  if data.len < 12:
    return (DnsHeader(), 0)
  
  var header: DnsHeader
  
  # ID
  var id: uint16
  bigEndian16(addr id, unsafeAddr data[0])
  header.id = id
  
  # フラグ
  var flags: uint16
  bigEndian16(addr flags, unsafeAddr data[2])
  header.flags = flags
  
  # その他のフィールド
  var qdcount: uint16
  bigEndian16(addr qdcount, unsafeAddr data[4])
  header.qdcount = qdcount
  
  var ancount: uint16
  bigEndian16(addr ancount, unsafeAddr data[6])
  header.ancount = ancount
  
  var nscount: uint16
  bigEndian16(addr nscount, unsafeAddr data[8])
  header.nscount = nscount
  
  var arcount: uint16
  bigEndian16(addr arcount, unsafeAddr data[10])
  header.arcount = arcount
  
  return (header, 12)

proc encodeQuestion(question: DnsQuestion): seq[byte] =
  # 名前のエンコード
  result = encodeDomainName(question.name)
  
  # タイプ
  var qtype = question.qtype
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], addr qtype)
  
  # クラス
  var qclass = question.qclass
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], addr qclass)

proc decodeQuestion(data: seq[byte], offset: var int): tuple[question: DnsQuestion, bytesRead: int] =
  let startOffset = offset
  
  # 名前のデコード
  let name = decodeDomainName(data, offset)
  
  # サイズチェック
  if offset + 4 > data.len:
    return (DnsQuestion(), 0)
  
  # タイプ
  var qtype: uint16
  bigEndian16(addr qtype, unsafeAddr data[offset])
  offset += 2
  
  # クラス
  var qclass: uint16
  bigEndian16(addr qclass, unsafeAddr data[offset])
  offset += 2
  
  let question = DnsQuestion(name: name, qtype: qtype, qclass: qclass)
  return (question, offset - startOffset)

proc encodeQuery(domain: string, recordType: DnsRecordType, id: uint16 = 0): seq[byte] =
  # ランダムIDの生成（指定されていない場合）
  var queryId = id
  if queryId == 0:
    randomize()
    queryId = uint16(rand(high(int16)))
  
  # ヘッダーの準備
  var header: DnsHeader
  header.id = queryId
  setRD(header, true)  # 再帰的クエリを要求
  header.qdcount = 1
  
  # 質問の準備
  let question = DnsQuestion(
    name: domain,
    qtype: uint16(recordType.ord),
    qclass: 1  # IN (インターネット)
  )
  
  # パケットの構築
  result = encodeHeader(header)
  result.add(encodeQuestion(question))

proc decodeResponse(data: seq[byte]): tuple[records: seq[DnsRecord], rcode: DnsResponseCode] =
  var offset = 0
  
  # ヘッダーのデコード
  let (header, headerBytes) = decodeHeader(data)
  if headerBytes == 0:
    return (@[], DnsResponseCode.ServerFailure)
  
  offset += headerBytes
  
  # レスポンスコードの取得
  let rcode = DnsResponseCode(header.getRcode())
  
  # 質問セクションをスキップ
  for i in 0..<header.qdcount.int:
    var questionOffset = offset
    let (_, bytesRead) = decodeQuestion(data, questionOffset)
    if bytesRead == 0:
      return (@[], rcode)
    offset = questionOffset
  
  # 回答セクションの処理
  var records: seq[DnsRecord] = @[]
  
  for i in 0..<header.ancount.int:
    # ドメイン名のデコード
    let domain = decodeDomainName(data, offset)
    
    # サイズチェック
    if offset + 10 > data.len:
      break
    
    # タイプ
    var recordTypeValue: uint16
    bigEndian16(addr recordTypeValue, unsafeAddr data[offset])
    offset += 2
    
    # レコードタイプが範囲外の場合はスキップ
    if recordTypeValue.int > high(DnsRecordType).int:
      # 残りのフィールドをスキップ
      # クラス(2) + TTL(4) + データ長(2)
      offset += 2
      var dataLen: uint16
      bigEndian16(addr dataLen, unsafeAddr data[offset + 4])
      offset += 6 + dataLen.int
      continue
    
    let recordType = DnsRecordType(recordTypeValue.int)
    
    # クラス
    var recordClass: uint16
    bigEndian16(addr recordClass, unsafeAddr data[offset])
    offset += 2
    
    # インターネットクラス以外はスキップ
    if recordClass != 1:
      # 残りのフィールドをスキップ
      # TTL(4) + データ長(2)
      var dataLen: uint16
      bigEndian16(addr dataLen, unsafeAddr data[offset + 4])
      offset += 6 + dataLen.int
      continue
    
    # TTL
    var ttl: uint32
    bigEndian32(addr ttl, unsafeAddr data[offset])
    offset += 4
    
    # データ長
    var dataLen: uint16
    bigEndian16(addr dataLen, unsafeAddr data[offset])
    offset += 2
    
    # データサイズチェック
    if offset + dataLen.int > data.len:
      break
    
    # レコードデータの解析
    var recordData = ""
    
    case recordType
    of DnsRecordType.A:
      if dataLen == 4:
        recordData = $data[offset] & "." & $data[offset+1] & "." & 
                    $data[offset+2] & "." & $data[offset+3]
    of DnsRecordType.AAAA:
      if dataLen == 16:
        var ipv6Parts: array[8, string]
        for i in 0..<8:
          let part = (data[offset + i*2].int shl 8) or data[offset + i*2 + 1].int
          ipv6Parts[i] = part.toHex(4).toLowerAscii
        recordData = ipv6Parts.join(":")
    of DnsRecordType.CNAME, DnsRecordType.NS, DnsRecordType.PTR:
      var nameOffset = offset
      recordData = decodeDomainName(data, nameOffset)
    of DnsRecordType.MX:
      if dataLen >= 2:
        # 優先度
        var preference: uint16
        bigEndian16(addr preference, unsafeAddr data[offset])
        var nameOffset = offset + 2
        let exchange = decodeDomainName(data, nameOffset)
        recordData = $preference & " " & exchange
    of DnsRecordType.TXT:
      # テキストレコードの処理
      var textOffset = offset
      var txtEnd = offset + dataLen.int
      
      while textOffset < txtEnd:
        let txtLen = data[textOffset].int
        textOffset += 1
        
        if textOffset + txtLen > txtEnd:
          break
        
        for i in 0..<txtLen:
          recordData.add(char(data[textOffset + i]))
        
        textOffset += txtLen
    of DnsRecordType.SOA:
      # SOAレコードの処理
      var soaOffset = offset
      let mname = decodeDomainName(data, soaOffset)
      let rname = decodeDomainName(data, soaOffset)
      
      if soaOffset + 20 <= data.len:
        var serial, refresh, retry, expire, minimum: uint32
        bigEndian32(addr serial, unsafeAddr data[soaOffset])
        bigEndian32(addr refresh, unsafeAddr data[soaOffset+4])
        bigEndian32(addr retry, unsafeAddr data[soaOffset+8])
        bigEndian32(addr expire, unsafeAddr data[soaOffset+12])
        bigEndian32(addr minimum, unsafeAddr data[soaOffset+16])
        
        recordData = mname & " " & rname & " " & $serial & " " & 
                    $refresh & " " & $retry & " " & $expire & " " & $minimum
    of DnsRecordType.SRV:
      # SRVレコードの処理
      if dataLen >= 6:
        var priority, weight, port: uint16
        bigEndian16(addr priority, unsafeAddr data[offset])
        bigEndian16(addr weight, unsafeAddr data[offset+2])
        bigEndian16(addr port, unsafeAddr data[offset+4])
        
        var targetOffset = offset + 6
        let target = decodeDomainName(data, targetOffset)
        
        recordData = $priority & " " & $weight & " " & $port & " " & target
    else:
      # その他のレコードタイプ
      # バイナリデータを16進数に変換
      for i in 0..<dataLen.int:
        recordData.add(data[offset + i].toHex(2))
    
    # レコードの作成と追加
    let record = DnsRecord(
      domain: domain,
      recordType: recordType,
      ttl: ttl.int,
      data: recordData,
      timestamp: getTime()
    )
    
    records.add(record)
    
    # 次のレコードへ
    offset += dataLen.int
  
  return (records, rcode)

proc newDnsResolver*(nameservers: seq[string] = @[], 
                    cacheSize: int = 1000,
                    cachePath: string = "",
                    useRootServers: bool = false,
                    randomizeNameservers: bool = true,
                    timeout: int = DNS_TIMEOUT,
                    maxRetries: int = MAX_RETRIES,
                    checkHosts: bool = true,
                    hostsPath: string = ""): DnsResolver =
  ## 新しいDNSリゾルバを生成
  result = DnsResolver(
    cache: newDnsCache(cacheSize, cachePath),
    useRootServers: useRootServers,
    randomizeNameservers: randomizeNameservers,
    timeout: timeout,
    maxRetries: maxRetries,
    checkHosts: checkHosts
  )
  
  # システムのホストファイルパスをデフォルトで使用
  if hostsPath == "":
    when defined(windows):
      result.hostsPath = r"C:\Windows\System32\drivers\etc\hosts"
    else:
      result.hostsPath = "/etc/hosts"
  else:
    result.hostsPath = hostsPath
  
  # キャッシュの読み込み
  if cachePath != "":
    discard result.cache.loadFromDisk()
  
  # ネームサーバー設定
  if nameservers.len > 0:
    result.nameservers = nameservers
  else:
    # システムのネームサーバーの設定を取得
    try:
      when defined(windows):
        # Windowsのネームサーバー設定取得（簡易版）
        discard
      else:
        # Unix系OSのresolv.confからDNSサーバーを取得
        if fileExists("/etc/resolv.conf"):
          for line in lines("/etc/resolv.conf"):
            let parts = line.strip().split()
            if parts.len >= 2 and parts[0] == "nameserver":
              result.nameservers.add(parts[1])
    except:
      discard
  
  # ネームサーバーが設定されていない場合、デフォルトを使用
  if result.nameservers.len == 0:
    result.nameservers = @["8.8.8.8", "8.8.4.4"]  # Googleパブリックネームサーバー
  
  # ルートサーバーの使用が指定されている場合
  if useRootServers:
    result.nameservers = @[]
    for server in ROOT_SERVERS:
      result.nameservers.add(server)
  
  # ネームサーバーのランダム化
  if randomizeNameservers and result.nameservers.len > 1:
    randomize()
    shuffle(result.nameservers)

proc readHostsFile(resolver: DnsResolver): Table[string, seq[DnsRecord]] =
  ## hostsファイルから情報を読み込む
  result = initTable[string, seq[DnsRecord]]()
  
  if not resolver.checkHosts or not fileExists(resolver.hostsPath):
    return
  
  try:
    for line in lines(resolver.hostsPath):
      # コメントを削除
      let commentPos = line.find('#')
      let processLine = if commentPos >= 0: line[0..<commentPos] else: line
      
      # 空行をスキップ
      if processLine.strip() == "":
        continue
      
      # 行を解析
      let parts = processLine.strip().splitWhitespace()
      if parts.len < 2:
        continue
      
      let ip = parts[0]
      # IPアドレスの検証
      var ipType: DnsRecordType
      if ip.contains(':'):
        ipType = DnsRecordType.AAAA
      elif ip.count('.') == 3:
        ipType = DnsRecordType.A
      else:
        continue
      
      # ホスト名ごとにレコードを作成
      for i in 1..<parts.len:
        let domain = parts[i].toLowerAscii
        
        # レコードの作成
        let record = DnsRecord(
          domain: domain,
          recordType: ipType,
          ttl: 86400,  # 1日
          data: ip,
          timestamp: getTime()
        )
        
        # ドメインのレコードリストに追加
        if not result.hasKey(domain):
          result[domain] = @[]
        
        result[domain].add(record)
  except:
    # hostsファイル読み取りエラーは無視
    discard

proc queryNameserver(nameserver: string, query: seq[byte], timeout: int): Future[seq[byte]] {.async.} =
  ## 単一のネームサーバーにクエリを送信
  var socket = newAsyncSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  
  try:
    # タイムアウトの設定
    socket.setSockOpt(OptSendTimeout, timeout)
    socket.setSockOpt(OptRecvTimeout, timeout)
    
    # ネームサーバーのアドレス設定
    var serverAddr = SockAddr_in()
    serverAddr.sin_family = AF_INET.int16
    serverAddr.sin_port = htons(DNS_PORT.uint16)
    serverAddr.sin_addr.s_addr = inet_addr(nameserver)
    
    # クエリ送信
    let sent = await socket.sendTo(cast[pointer](unsafeAddr query[0]), query.len, 
                                  cast[ptr SockAddr](addr serverAddr), sizeof(serverAddr).SockLen)
    
    # 応答バッファ
    var response = newSeq[byte](MAX_UDP_SIZE)
    var fromAddr: SockAddr
    var fromLen: SockLen
    
    # 応答受信
    let received = await socket.recvFrom(cast[pointer](addr response[0]), MAX_UDP_SIZE, 
                                        addr fromAddr, addr fromLen)
    
    if received <= 0:
      return @[]
    
    return response[0..<received]
  finally:
    socket.close()

proc resolveAsync*(resolver: DnsResolver, domain: string, recordType: DnsRecordType = DnsRecordType.A): Future[seq[DnsRecord]] {.async.} =
  ## ドメイン名を非同期に解決
  
  # ドメイン名の正規化
  let normalizedDomain = domain.toLowerAscii.removeSuffix(".")
  
  # hostsファイルをチェック
  if resolver.checkHosts:
    let hostsRecords = resolver.readHostsFile()
    if hostsRecords.hasKey(normalizedDomain):
      let matchingRecords = hostsRecords[normalizedDomain].filterIt(it.recordType == recordType)
      if matchingRecords.len > 0:
        return matchingRecords
  
  # キャッシュをチェック
  let cachedRecords = resolver.cache.get(normalizedDomain, recordType)
  if cachedRecords.len > 0:
    return cachedRecords
  
  # クエリパケットの作成
  let query = encodeQuery(normalizedDomain, recordType)
  
  # 複数のネームサーバーへのクエリをランダム順に実行
  var nameservers = resolver.nameservers
  if resolver.randomizeNameservers:
    randomize()
    shuffle(nameservers)
  
  for i in 0..<min(nameservers.len, resolver.maxRetries):
    let nameserver = nameservers[i]
    
    try:
      # クエリ送信と応答受信
      let response = await queryNameserver(nameserver, query, resolver.timeout)
      
      if response.len == 0:
        continue
      
      # 応答の解析
      let (records, rcode) = decodeResponse(response)
      
      # 応答コードのチェック
      if rcode != DnsResponseCode.NoError:
        continue
      
      # 応答が空でなければキャッシュに追加して返す
      if records.len > 0:
        # キャッシュに追加
        for record in records:
          resolver.cache.add(record)
        
        # 該当するレコードタイプのみをフィルタリング
        return records.filterIt(it.recordType == recordType)
    except:
      # エラーは無視して次のネームサーバーを試行
      continue
  
  # 全てのネームサーバーが失敗した場合は空のシーケンスを返す
  return @[]

proc resolveAll*(resolver: DnsResolver, domain: string, recordType: DnsRecordType = DnsRecordType.A): Future[seq[DnsRecord]] {.async.} =
  ## 指定されたドメインの全てのレコードを取得
  return await resolver.resolveAsync(domain, recordType)

proc resolve*(resolver: DnsResolver, domain: string, recordType: DnsRecordType = DnsRecordType.A): seq[DnsRecord] =
  ## ドメイン名の同期解決（ノンブロッキングコールのラッパー）
  let future = resolver.resolveAsync(domain, recordType)
  return waitFor future

proc resolveIpv4*(resolver: DnsResolver, domain: string): Future[seq[string]] {.async.} =
  ## ドメイン名からIPv4アドレスを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.A)
  return records.map(r => r.data)

proc resolveIpv6*(resolver: DnsResolver, domain: string): Future[seq[string]] {.async.} =
  ## ドメイン名からIPv6アドレスを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.AAAA)
  return records.map(r => r.data)

proc resolveMx*(resolver: DnsResolver, domain: string): Future[seq[tuple[preference: int, exchange: string]]] {.async.} =
  ## ドメイン名からMXレコードを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.MX)
  
  result = @[]
  for record in records:
    let parts = record.data.split(' ', 1)
    if parts.len == 2:
      try:
        let preference = parseInt(parts[0])
        result.add((preference, parts[1]))
      except:
        continue

proc resolveTxt*(resolver: DnsResolver, domain: string): Future[seq[string]] {.async.} =
  ## ドメイン名からTXTレコードを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.TXT)
  return records.map(r => r.data)

proc resolveNs*(resolver: DnsResolver, domain: string): Future[seq[string]] {.async.} =
  ## ドメイン名からNSレコードを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.NS)
  return records.map(r => r.data)

proc resolveCname*(resolver: DnsResolver, domain: string): Future[Option[string]] {.async.} =
  ## ドメイン名からCNAMEレコードを解決
  let records = await resolver.resolveAsync(domain, DnsRecordType.CNAME)
  if records.len > 0:
    return some(records[0].data)
  return none(string)

proc clearCache*(resolver: DnsResolver) =
  ## リゾルバのキャッシュをクリア
  resolver.cache.clear()

proc saveCache*(resolver: DnsResolver) =
  ## リゾルバのキャッシュを永続化
  resolver.cache.saveToDisk()

proc getCacheStats*(resolver: DnsResolver): DnsCacheStats =
  ## リゾルバのキャッシュ統計を取得
  return resolver.cache.getStats()

proc setNameservers*(resolver: DnsResolver, nameservers: seq[string]) =
  ## リゾルバのネームサーバーを設定
  resolver.nameservers = nameservers
  if resolver.randomizeNameservers and resolver.nameservers.len > 1:
    randomize()
    shuffle(resolver.nameservers)

proc getNameservers*(resolver: DnsResolver): seq[string] =
  ## リゾルバのネームサーバーを取得
  return resolver.nameservers

proc setTimeout*(resolver: DnsResolver, timeout: int) =
  ## リゾルバのタイムアウトを設定
  resolver.timeout = timeout

proc setMaxRetries*(resolver: DnsResolver, maxRetries: int) =
  ## リゾルバの最大リトライ回数を設定
  resolver.maxRetries = maxRetries 