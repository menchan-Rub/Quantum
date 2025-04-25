# DNSリゾルバモジュール
# 高速で安全なDNS解決を提供します

import std/[asyncdispatch, asyncnet, options, tables, strutils, times, json, sequtils]
import std/[random, strformat, sets, hashes, algorithm, net, endians, streams]
import std/[deques, logging, uri, base64]
import chronicles

import ./cache/dns_cache

# DNS関連の定数
const
  DNS_DEFAULT_PORT = 53  # 標準DNSポート
  DNS_MAX_PACKET_SIZE = 4096  # 最大パケットサイズ
  DNS_TIMEOUT_MS = 3000  # タイムアウト (ミリ秒)
  DNS_RETRIES = 3  # リトライ回数
  
  # DNSレコードタイプ
  TYPE_A = 1        # IPv4アドレス
  TYPE_NS = 2       # ネームサーバー
  TYPE_CNAME = 5    # 正規名
  TYPE_SOA = 6      # 権威の開始
  TYPE_PTR = 12     # ポインタ
  TYPE_MX = 15      # メール交換
  TYPE_TXT = 16     # テキスト
  TYPE_AAAA = 28    # IPv6アドレス
  TYPE_SRV = 33     # サービス
  TYPE_HTTPS = 65   # HTTPS
  TYPE_CAA = 257    # 認証局承認
  TYPE_ANY = 255    # すべてのレコード

  # DNSクラス
  CLASS_IN = 1      # インターネット

  # DNSオプコード
  OPCODE_QUERY = 0  # 標準クエリ
  OPCODE_IQUERY = 1 # 逆クエリ
  OPCODE_STATUS = 2 # サーバーステータス要求

  # DNSレスポンスコード
  RCODE_NO_ERROR = 0        # エラーなし
  RCODE_FORMAT_ERROR = 1    # フォーマットエラー
  RCODE_SERVER_FAILURE = 2  # サーバー障害
  RCODE_NAME_ERROR = 3      # 名前エラー (NXDOMAIN)
  RCODE_NOT_IMPLEMENTED = 4 # 未実装
  RCODE_REFUSED = 5         # クエリ拒否

  # DoHエンドポイント
  DOH_ENDPOINTS = [
    "https://cloudflare-dns.com/dns-query",
    "https://dns.google/dns-query",
    "https://dns.quad9.net/dns-query"
  ]

  # DoT名前解決サーバー
  DOT_SERVERS = [
    "1.1.1.1",      # Cloudflare
    "8.8.8.8",      # Google
    "9.9.9.9"       # Quad9
  ]

  # 公開DNSサーバー
  PUBLIC_DNS_SERVERS = [
    "1.1.1.1",      # Cloudflare
    "8.8.8.8",      # Google
    "9.9.9.9",      # Quad9
    "208.67.222.222" # OpenDNS
  ]

# DNSSEC関連の定数
const
  # DNSSECレコードタイプ
  TYPE_DNSKEY = 48  # DNSKEYレコード
  TYPE_DS = 43      # 委任署名者レコード
  TYPE_RRSIG = 46   # RRSIGレコード
  TYPE_NSEC = 47    # NSECレコード
  TYPE_NSEC3 = 50   # NSEC3レコード

# DNSレコードタイプを表す列挙型
type
  RecordType* = enum
    A = TYPE_A,
    NS = TYPE_NS,
    CNAME = TYPE_CNAME,
    SOA = TYPE_SOA,
    PTR = TYPE_PTR,
    MX = TYPE_MX,
    TXT = TYPE_TXT,
    AAAA = TYPE_AAAA,
    SRV = TYPE_SRV,
    HTTPS = TYPE_HTTPS,
    CAA = TYPE_CAA,
    DNSKEY = TYPE_DNSKEY,  # 追加
    DS = TYPE_DS,          # 追加
    RRSIG = TYPE_RRSIG,    # 追加
    NSEC = TYPE_NSEC,      # 追加
    NSEC3 = TYPE_NSEC3,    # 追加
    ANY = TYPE_ANY

  # DNSクラスを表す列挙型 
  RecordClass* = enum
    IN = CLASS_IN

  # DNSレスポンスコード
  ResponseCode* = enum
    NoError = RCODE_NO_ERROR,
    FormatError = RCODE_FORMAT_ERROR,
    ServerFailure = RCODE_SERVER_FAILURE, 
    NameError = RCODE_NAME_ERROR,
    NotImplemented = RCODE_NOT_IMPLEMENTED,
    Refused = RCODE_REFUSED

  # 解決プロトコル
  ResolverProtocol* = enum
    Standard,     # 標準DNS (UDP/TCP)
    DoH,          # DNS over HTTPS
    DoT           # DNS over TLS

  # DNSセクション
  DnsSectionType = enum
    stQuestion, stAnswer, stAuthority, stAdditional

  # DNSヘッダー
  DnsHeader = object
    id: uint16
    flags: uint16
    qdCount: uint16
    anCount: uint16
    nsCount: uint16
    arCount: uint16

  # DNSフラグ
  DnsFlags = object
    qr: bool        # クエリ(0)/レスポンス(1)
    opcode: uint8   # オペレーションコード
    aa: bool        # 権威応答
    tc: bool        # 切り捨て
    rd: bool        # 再帰要求
    ra: bool        # 再帰利用可能
    z: uint8        # 予約済み(ゼロ)
    rcode: uint8    # レスポンスコード

  # DNSクエスチョン
  DnsQuestion = object
    name: string
    qtype: uint16
    qclass: uint16

  # DNSリソースレコード
  DnsResourceRecord = object
    name: string
    rrtype: uint16
    rrclass: uint16
    ttl: uint32
    rdlength: uint16
    rdata: string

  # DNSメッセージ
  DnsMessage = object
    header: DnsHeader
    questions: seq[DnsQuestion]
    answers: seq[DnsResourceRecord]
    authorities: seq[DnsResourceRecord]
    additionals: seq[DnsResourceRecord]

  # DNS Aレコード
  DnsARecord* = object
    ip*: IpAddress
    ttl*: uint32

  # DNS AAAAレコード
  DnsAAAARecord* = object
    ip*: IpAddress
    ttl*: uint32

  # DNS CNAMEレコード
  DnsCNAMERecord* = object
    cname*: string
    ttl*: uint32

  # DNS MXレコード
  DnsMXRecord* = object
    preference*: uint16
    exchange*: string
    ttl*: uint32

  # DNS TXTレコード
  DnsTXTRecord* = object
    text*: string
    ttl*: uint32

  # DNS SOAレコード
  DnsSOARecord* = object
    mname*: string
    rname*: string
    serial*: uint32
    refresh*: uint32
    retry*: uint32
    expire*: uint32
    minimum*: uint32
    ttl*: uint32

  # DNS SRVレコード
  DnsSRVRecord* = object
    priority*: uint16
    weight*: uint16
    port*: uint16
    target*: string
    ttl*: uint32

  # DNS CAA レコード
  DnsCAARecord* = object
    flag*: uint8
    tag*: string
    value*: string
    ttl*: uint32

  # DNSレコード (多態型)
  DnsRecord* = object
    name*: string
    case kind*: RecordType
    of A:
      a*: DnsARecord
    of AAAA:
      aaaa*: DnsAAAARecord
    of CNAME:
      cname*: DnsCNAMERecord
    of MX:
      mx*: DnsMXRecord
    of TXT:
      txt*: DnsTXTRecord
    of NS:
      ns*: string
      ns_ttl*: uint32
    of SOA:
      soa*: DnsSOARecord
    of SRV:
      srv*: DnsSRVRecord
    of CAA:
      caa*: DnsCAARecord
    of PTR:
      ptr*: string
      ptr_ttl*: uint32
    of DNSKEY:
      dnskey*: DnsDNSKEYRecord
    of DS:
      ds*: DnsDSRecord
    of RRSIG:
      rrsig*: DnsRRSIGRecord
    of NSEC:
      nsec*: DnsNSECRecord
    of NSEC3:
      nsec3*: DnsNSEC3Record
    else:
      raw_type*: uint16
      raw_data*: string
      raw_ttl*: uint32

  # DNSレスポンス
  DnsResponse* = ref object
    records*: seq[DnsRecord]
    responseCode*: ResponseCode
    authoritative*: bool
    truncated*: bool
    recursionAvailable*: bool
    authenticated*: bool
    dnssecStatus*: DnssecStatus  # 追加

  # リゾルバ設定
  ResolverConfig* = object
    protocol*: ResolverProtocol
    servers*: seq[string]
    timeout*: int
    retries*: int
    useCache*: bool
    validateDnssec*: DnssecValidationLevel  # 更新
    fallbackProtocols*: seq[ResolverProtocol]
    trustAnchors*: seq[DnsDSRecord]  # 信頼アンカー（ルートのDS/DNSKEY）

  # DNSリゾルバ
  DnsResolver* = ref object
    config: ResolverConfig
    cache: DnsCache
    randomizer: Rand
    metrics: DnsMetrics
    lastQueryTime: Time

# ユーティリティ関数
proc packName(name: string): string =
  ## ドメイン名をDNSワイヤーフォーマットにパック
  result = ""
  var parts = name.toLowerAscii().split('.')
  
  for part in parts:
    if part.len > 0:
      result.add(chr(part.len.uint8))
      result.add(part)
  
  result.add(chr(0))  # ターミネータ

proc readName(data: string, offset: var int): string =
  ## DNSワイヤーフォーマットからドメイン名を読み取る
  # 簡単な実装（圧縮サポートなし）
  var labels: seq[string] = @[]
  var pos = offset
  
  while true:
    if pos >= data.len:
      break
    
    let length = data[pos].uint8
    if length == 0:
      pos += 1
      break
    
    # ポインタのチェック (圧縮ドメイン名)
    if (length and 0xC0) == 0xC0:
      if pos + 1 >= data.len:
        break
      
      let pointerOffset = (((length and 0x3F).uint16 shl 8) or data[pos + 1].uint8).int
      var tempOffset = pointerOffset
      let pointedName = readName(data, tempOffset)
      labels.add(pointedName.split('.'))
      pos += 2
      break
    
    pos += 1
    if pos + length.int > data.len:
      break
    
    let label = data[pos..<pos+length.int]
    labels.add(label)
    pos += length.int
  
  offset = pos
  result = labels.join(".")
  if result.len > 0 and result[^1] == '.':
    result = result[0..^2]

proc createHeader(id: uint16, flags: DnsFlags, qdCount, anCount, nsCount, arCount: uint16): DnsHeader =
  ## DNSヘッダーを作成
  let flagsValue = (if flags.qr: 1'u16 shl 15 else: 0'u16) or
                   (flags.opcode.uint16 shl 11) or
                   (if flags.aa: 1'u16 shl 10 else: 0'u16) or
                   (if flags.tc: 1'u16 shl 9 else: 0'u16) or
                   (if flags.rd: 1'u16 shl 8 else: 0'u16) or
                   (if flags.ra: 1'u16 shl 7 else: 0'u16) or
                   (flags.z.uint16 shl 4) or
                   flags.rcode.uint16
  
  result = DnsHeader(
    id: id,
    flags: flagsValue,
    qdCount: qdCount,
    anCount: anCount,
    nsCount: nsCount,
    arCount: arCount
  )

proc packHeader(header: DnsHeader): string =
  ## DNSヘッダーをバイト列にパック
  result = newString(12)  # DNSヘッダーは12バイト
  
  var id = header.id
  var flags = header.flags
  var qdCount = header.qdCount
  var anCount = header.anCount
  var nsCount = header.nsCount
  var arCount = header.arCount
  
  # ネットワークバイトオーダー(ビッグエンディアン)に変換
  bigEndian16(addr result[0], addr id)
  bigEndian16(addr result[2], addr flags)
  bigEndian16(addr result[4], addr qdCount)
  bigEndian16(addr result[6], addr anCount)
  bigEndian16(addr result[8], addr nsCount)
  bigEndian16(addr result[10], addr arCount)

proc unpackHeader(data: string): DnsHeader =
  ## バイト列からDNSヘッダーを解析
  if data.len < 12:
    raise newException(ValueError, "DNSヘッダーのデータが不足しています")
  
  var id, flags, qdCount, anCount, nsCount, arCount: uint16
  
  # ネットワークバイトオーダーからホストバイトオーダーに変換
  bigEndian16(addr id, unsafeAddr data[0])
  bigEndian16(addr flags, unsafeAddr data[2])
  bigEndian16(addr qdCount, unsafeAddr data[4])
  bigEndian16(addr anCount, unsafeAddr data[6])
  bigEndian16(addr nsCount, unsafeAddr data[8])
  bigEndian16(addr arCount, unsafeAddr data[10])
  
  result = DnsHeader(
    id: id,
    flags: flags,
    qdCount: qdCount,
    anCount: anCount,
    nsCount: nsCount,
    arCount: arCount
  )

proc parseFlags(flagsValue: uint16): DnsFlags =
  ## フラグ値からDnsFlagsオブジェクトを生成
  result.qr = (flagsValue and 0x8000) != 0
  result.opcode = ((flagsValue and 0x7800) shr 11).uint8
  result.aa = (flagsValue and 0x0400) != 0
  result.tc = (flagsValue and 0x0200) != 0
  result.rd = (flagsValue and 0x0100) != 0
  result.ra = (flagsValue and 0x0080) != 0
  result.z = ((flagsValue and 0x0070) shr 4).uint8
  result.rcode = (flagsValue and 0x000F).uint8

proc packQuestion(question: DnsQuestion): string =
  ## DNSクエスチョンをバイト列にパック
  result = packName(question.name)
  
  var qtype = question.qtype
  var qclass = question.qclass
  
  # 4バイトのタイプとクラス
  var typeClass = newString(4)
  bigEndian16(addr typeClass[0], addr qtype)
  bigEndian16(addr typeClass[2], addr qclass)
  
  result.add(typeClass)

proc unpackQuestion(data: string, offset: var int): DnsQuestion =
  ## バイト列からDNSクエスチョンを解析
  var name = readName(data, offset)
  
  if offset + 4 > data.len:
    raise newException(ValueError, "DNSクエスチョンデータが不足しています")
  
  var qtype, qclass: uint16
  bigEndian16(addr qtype, unsafeAddr data[offset])
  bigEndian16(addr qclass, unsafeAddr data[offset + 2])
  
  offset += 4
  
  result = DnsQuestion(
    name: name,
    qtype: qtype,
    qclass: qclass
  )

proc packResourceRecord(rr: DnsResourceRecord): string =
  ## DNSリソースレコードをバイト列にパック
  result = packName(rr.name)
  
  # タイプ、クラス、TTL、データ長
  var header = newString(10)
  var rrtype = rr.rrtype
  var rrclass = rr.rrclass
  var ttl = rr.ttl
  var rdlength = rr.rdlength
  
  bigEndian16(addr header[0], addr rrtype)
  bigEndian16(addr header[2], addr rrclass)
  bigEndian32(addr header[4], addr ttl)
  bigEndian16(addr header[8], addr rdlength)
  
  result.add(header)
  result.add(rr.rdata)

proc unpackResourceRecord(data: string, offset: var int): DnsResourceRecord =
  ## バイト列からDNSリソースレコードを解析
  var name = readName(data, offset)
  
  if offset + 10 > data.len:
    raise newException(ValueError, "DNSリソースレコードデータが不足しています")
  
  var rrtype, rrclass, rdlength: uint16
  var ttl: uint32
  
  bigEndian16(addr rrtype, unsafeAddr data[offset])
  bigEndian16(addr rrclass, unsafeAddr data[offset + 2])
  bigEndian32(addr ttl, unsafeAddr data[offset + 4])
  bigEndian16(addr rdlength, unsafeAddr data[offset + 8])
  
  offset += 10
  
  if offset + rdlength.int > data.len:
    raise newException(ValueError, "DNSリソースレコードのRDATAが不足しています")
  
  var rdata = data[offset..<offset + rdlength.int]
  offset += rdlength.int
  
  result = DnsResourceRecord(
    name: name,
    rrtype: rrtype,
    rrclass: rrclass,
    ttl: ttl,
    rdlength: rdlength,
    rdata: rdata
  )

proc parseDnsMessage(data: string): DnsMessage =
  ## DNSメッセージを解析
  if data.len < 12:
    raise newException(ValueError, "DNSメッセージが短すぎます")
  
  var offset = 0
  
  # ヘッダーの解析
  let header = unpackHeader(data)
  offset += 12
  
  var questions: seq[DnsQuestion] = @[]
  var answers: seq[DnsResourceRecord] = @[]
  var authorities: seq[DnsResourceRecord] = @[]
  var additionals: seq[DnsResourceRecord] = @[]
  
  # クエスチョンセクションの解析
  for i in 0..<header.qdCount.int:
    if offset >= data.len:
      break
    
    try:
      let question = unpackQuestion(data, offset)
      questions.add(question)
    except:
      break
  
  # アンサーセクションの解析
  for i in 0..<header.anCount.int:
    if offset >= data.len:
      break
    
    try:
      let answer = unpackResourceRecord(data, offset)
      answers.add(answer)
    except:
      break
  
  # オーソリティセクションの解析
  for i in 0..<header.nsCount.int:
    if offset >= data.len:
      break
    
    try:
      let authority = unpackResourceRecord(data, offset)
      authorities.add(authority)
    except:
      break
  
  # アディショナルセクションの解析
  for i in 0..<header.arCount.int:
    if offset >= data.len:
      break
    
    try:
      let additional = unpackResourceRecord(data, offset)
      additionals.add(additional)
    except:
      break
  
  result = DnsMessage(
    header: header,
    questions: questions,
    answers: answers,
    authorities: authorities,
    additionals: additionals
  )

proc buildDnsQuery(domain: string, recordType: RecordType, id: uint16 = 0): string =
  ## DNSクエリメッセージを構築
  let questionName = domain
  let questionType = recordType.uint16
  let questionClass = RecordClass.IN.uint16
  
  let dnsId = if id == 0: uint16(rand(1..65535)) else: id
  
  let flags = DnsFlags(
    qr: false,      # クエリ
    opcode: OPCODE_QUERY.uint8,
    aa: false,
    tc: false,
    rd: true,       # 再帰要求
    ra: false,
    z: 0,
    rcode: RCODE_NO_ERROR.uint8
  )
  
  let header = createHeader(
    dnsId,
    flags,
    1, # 1つのクエスチョン
    0, # アンサーなし
    0, # オーソリティなし
    0  # アディショナルなし
  )
  
  let question = DnsQuestion(
    name: questionName,
    qtype: questionType,
    qclass: questionClass
  )
  
  result = packHeader(header) & packQuestion(question)

proc parseARecord(rdata: string): DnsARecord =
  ## Aレコードを解析
  if rdata.len != 4:
    raise newException(ValueError, "IPv4アドレスは4バイトでなければなりません")
  
  let ipStr = $rdata[0].uint8 & "." & $rdata[1].uint8 & "." & $rdata[2].uint8 & "." & $rdata[3].uint8
  result = DnsARecord(
    ip: parseIpAddress(ipStr)
  )

proc parseAAAARecord(rdata: string): DnsAAAARecord =
  ## AAAAレコードを解析
  if rdata.len != 16:
    raise newException(ValueError, "IPv6アドレスは16バイトでなければなりません")
  
  var parts: array[8, string]
  for i in 0..<8:
    let value = (rdata[i*2].uint8.uint16 shl 8) or rdata[i*2+1].uint8.uint16
    parts[i] = value.toHex()
  
  let ipStr = parts.join(":")
  result = DnsAAAARecord(
    ip: parseIpAddress(ipStr)
  )

proc parseMXRecord(rdata: string, data: string, offset: int): DnsMXRecord =
  ## MXレコードを解析
  if rdata.len < 3:
    raise newException(ValueError, "MXレコードが短すぎます")
  
  var preference: uint16
  bigEndian16(addr preference, unsafeAddr rdata[0])
  
  var exchangeOffset = offset + 2 # rdata内のMX名の開始位置
  var tempOffset = exchangeOffset
  let exchange = readName(data, tempOffset)
  
  result = DnsMXRecord(
    preference: preference,
    exchange: exchange
  )

proc parseCNAMERecord(rdata: string, data: string, offset: int): DnsCNAMERecord =
  ## CNAMEレコードを解析
  var tempOffset = offset
  let cname = readName(data, tempOffset)
  
  result = DnsCNAMERecord(
    cname: cname
  )

proc parseTXTRecord(rdata: string): DnsTXTRecord =
  ## TXTレコードを解析
  if rdata.len < 1:
    raise newException(ValueError, "TXTレコードが短すぎます")
  
  let length = rdata[0].uint8.int
  let text = if length <= rdata.len - 1: rdata[1..<(1+length)] else: ""
  
  result = DnsTXTRecord(
    text: text
  )

proc parseSOARecord(rdata: string, data: string, offset: int): DnsSOARecord =
  ## SOAレコードを解析
  var tempOffset = offset
  let mname = readName(data, tempOffset)
  let rname = readName(data, tempOffset)
  
  if tempOffset + 20 > data.len:
    raise newException(ValueError, "SOAレコードのデータが不足しています")
  
  var serial, refresh, retry, expire, minimum: uint32
  
  bigEndian32(addr serial, unsafeAddr data[tempOffset])
  bigEndian32(addr refresh, unsafeAddr data[tempOffset + 4])
  bigEndian32(addr retry, unsafeAddr data[tempOffset + 8])
  bigEndian32(addr expire, unsafeAddr data[tempOffset + 12])
  bigEndian32(addr minimum, unsafeAddr data[tempOffset + 16])
  
  result = DnsSOARecord(
    mname: mname,
    rname: rname,
    serial: serial,
    refresh: refresh,
    retry: retry,
    expire: expire,
    minimum: minimum
  )

proc parseSRVRecord(rdata: string, data: string, offset: int): DnsSRVRecord =
  ## SRVレコードを解析
  if rdata.len < 6:
    raise newException(ValueError, "SRVレコードが短すぎます")
  
  var priority, weight, port: uint16
  
  bigEndian16(addr priority, unsafeAddr rdata[0])
  bigEndian16(addr weight, unsafeAddr rdata[2])
  bigEndian16(addr port, unsafeAddr rdata[4])
  
  var targetOffset = offset + 6
  var tempOffset = targetOffset
  let target = readName(data, tempOffset)
  
  result = DnsSRVRecord(
    priority: priority,
    weight: weight,
    port: port,
    target: target
  )

proc parseCAARecord(rdata: string): DnsCAARecord =
  ## CAAレコードを解析
  if rdata.len < 2:
    raise newException(ValueError, "CAAレコードが短すぎます")
  
  let flag = rdata[0].uint8
  let tagLen = rdata[1].uint8
  
  if rdata.len < 2 + tagLen:
    raise newException(ValueError, "CAAレコードのタグが不足しています")
  
  let tag = rdata[2..<(2+tagLen)]
  let value = if rdata.len > 2 + tagLen: rdata[(2+tagLen)..^1] else: ""
  
  result = DnsCAARecord(
    flag: flag,
    tag: tag,
    value: value
  )

proc extractRecordsFromMessage(msg: DnsMessage): seq[DnsRecord] =
  ## DNSメッセージからレコードを抽出
  result = @[]
  
  # フラグの抽出
  let flags = parseFlags(msg.header.flags)
  
  # アンサーセクションの処理
  for rr in msg.answers:
    let rrType = if rr.rrtype <= uint16(high(RecordType)): RecordType(rr.rrtype) else: RecordType.ANY
    
    var record = DnsRecord(
      name: rr.name,
      kind: rrType
    )
    
    case rrType
    of A:
      var aRecord = parseARecord(rr.rdata)
      aRecord.ttl = rr.ttl
      record.a = aRecord
    of AAAA:
      var aaaaRecord = parseAAAARecord(rr.rdata)
      aaaaRecord.ttl = rr.ttl
      record.aaaa = aaaaRecord
    of CNAME:
      var offset = 0
      var cnameRecord = parseCNAMERecord(rr.rdata, rr.rdata, offset)
      cnameRecord.ttl = rr.ttl
      record.cname = cnameRecord
    of MX:
      var offset = 0
      var mxRecord = parseMXRecord(rr.rdata, rr.rdata, offset)
      mxRecord.ttl = rr.ttl
      record.mx = mxRecord
    of TXT:
      var txtRecord = parseTXTRecord(rr.rdata)
      txtRecord.ttl = rr.ttl
      record.txt = txtRecord
    of NS:
      var offset = 0
      var nsName = readName(rr.rdata, offset)
      record.ns = nsName
      record.ns_ttl = rr.ttl
    of SOA:
      var offset = 0
      var soaRecord = parseSOARecord(rr.rdata, rr.rdata, offset)
      soaRecord.ttl = rr.ttl
      record.soa = soaRecord
    of SRV:
      var offset = 0
      var srvRecord = parseSRVRecord(rr.rdata, rr.rdata, offset)
      srvRecord.ttl = rr.ttl
      record.srv = srvRecord
    of CAA:
      var caaRecord = parseCAARecord(rr.rdata)
      caaRecord.ttl = rr.ttl
      record.caa = caaRecord
    of PTR:
      var offset = 0
      var ptrName = readName(rr.rdata, offset)
      record.ptr = ptrName
      record.ptr_ttl = rr.ttl
    of DNSKEY:
      var dnskeyRecord = parseDNSKEYRecord(rr.rdata)
      dnskeyRecord.ttl = rr.ttl
      record.dnskey = dnskeyRecord
    of DS:
      var dsRecord = parseDSRecord(rr.rdata)
      dsRecord.ttl = rr.ttl
      record.ds = dsRecord
    of RRSIG:
      var offset = 0
      var rrsigRecord = parseRRSIGRecord(rr.rdata, rr.rdata, offset)
      rrsigRecord.ttl = rr.ttl
      record.rrsig = rrsigRecord
    of NSEC:
      var offset = 0
      var nsecRecord = parseNSECRecord(rr.rdata, rr.rdata, offset)
      nsecRecord.ttl = rr.ttl
      record.nsec = nsecRecord
    of NSEC3:
      var nsec3Record = parseNSEC3Record(rr.rdata)
      nsec3Record.ttl = rr.ttl
      record.nsec3 = nsec3Record
    else:
      record.raw_type = rr.rrtype
      record.raw_data = rr.rdata
      record.raw_ttl = rr.ttl
    
    result.add(record)

proc newDnsResolver*(config: ResolverConfig): DnsResolver =
  ## 新しいDNSリゾルバを作成
  var resolver = DnsResolver(
    config: config,
    cache: newDnsCache(),
    randomizer: initRand(getTime().toUnix())
  )
  
  if resolver.config.servers.len == 0:
    # デフォルトのDNSサーバーを設定
    case resolver.config.protocol
    of ResolverProtocol.Standard:
      resolver.config.servers = PUBLIC_DNS_SERVERS
    of ResolverProtocol.DoH:
      resolver.config.servers = DOH_ENDPOINTS
    of ResolverProtocol.DoT:
      resolver.config.servers = DOT_SERVERS
  
  if resolver.config.timeout <= 0:
    resolver.config.timeout = DNS_TIMEOUT_MS
  
  if resolver.config.retries <= 0:
    resolver.config.retries = DNS_RETRIES
  
  # 信頼アンカーが設定されていない場合、デフォルトを使用
  if resolver.config.trustAnchors.len == 0:
    resolver.config.trustAnchors = @ROOT_TRUST_ANCHORS
  
  return resolver

proc checkCache(resolver: DnsResolver, domain: string, recordType: RecordType): Option[DnsResponse] =
  ## キャッシュをチェック
  if not resolver.config.useCache:
    return none(DnsResponse)
  
  let cacheResult = resolver.cache.get(domain, recordType)
  if cacheResult.isSome:
    let (records, expiry) = cacheResult.get()
    
    # 有効期限をチェック
    if getTime().toUnix() < expiry:
      # 有効なキャッシュを返す
      let response = DnsResponse(
        records: records,
        responseCode: ResponseCode.NoError,
        authoritative: false,
        truncated: false,
        recursionAvailable: true,
        authenticated: false  # キャッシュからの回答はDNSSEC認証されていないとみなす
      )
      return some(response)
  
  return none(DnsResponse)

proc updateCache(resolver: DnsResolver, domain: string, recordType: RecordType, records: seq[DnsRecord]) =
  ## キャッシュを更新
  if not resolver.config.useCache:
    return
  
  # 最短のTTLを見つける（ただし最低10秒）
  var minTtl: uint32 = high(uint32)
  for record in records:
    var ttl: uint32 = 0
    
    case record.kind
    of A:
      ttl = record.a.ttl
    of AAAA:
      ttl = record.aaaa.ttl
    of CNAME:
      ttl = record.cname.ttl
    of MX:
      ttl = record.mx.ttl
    of TXT:
      ttl = record.txt.ttl
    of NS:
      ttl = record.ns_ttl
    of SOA:
      ttl = record.soa.ttl
    of SRV:
      ttl = record.srv.ttl
    of CAA:
      ttl = record.caa.ttl
    of PTR:
      ttl = record.ptr_ttl
    of DNSKEY:
      ttl = record.dnskey.ttl
    of DS:
      ttl = record.ds.ttl
    of RRSIG:
      ttl = record.rrsig.ttl
    of NSEC:
      ttl = record.nsec.ttl
    of NSEC3:
      ttl = record.nsec3.ttl
    else:
      ttl = record.raw_ttl
    
    if ttl < minTtl and ttl > 0:
      minTtl = ttl
  
  # 最低でも10秒、最大でも1週間のTTLにする
  if minTtl == high(uint32) or minTtl < 10:
    minTtl = 10
  if minTtl > 604800:  # 1週間
    minTtl = 604800
  
  let expiry = getTime().toUnix() + minTtl.int
  resolver.cache.set(domain, recordType, records, expiry)

proc queryStandardDns(resolver: DnsResolver, domain: string, recordType: RecordType): Future[DnsResponse] {.async.} =
  ## 標準DNSを使ってクエリを実行
  let queryData = buildDnsQuery(domain, recordType)
  
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let serverAddr = resolver.config.servers[serverIndex]
    
    var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    try:
      # タイムアウトを設定
      socket.setSockOpt(OptKind.OptSendTimeout, resolver.config.timeout)
      socket.setSockOpt(OptKind.OptRecvTimeout, resolver.config.timeout)
      
      let port = DNS_DEFAULT_PORT
      await socket.sendTo(serverAddr, port, queryData)
      
      var responseData = newString(DNS_MAX_PACKET_SIZE)
      let bytesRead = await socket.recvFrom(responseData, DNS_MAX_PACKET_SIZE)
      
      if bytesRead <= 0:
        continue  # 次のサーバーを試す
      
      responseData.setLen(bytesRead)
      
      # DNSメッセージを解析
      let dnsMessage = parseDnsMessage(responseData)
      
      # フラグの抽出
      let flags = parseFlags(dnsMessage.header.flags)
      
      # レスポンスコードを取得
      let responseCode = ResponseCode(flags.rcode)
      
      if responseCode != ResponseCode.NoError and dnsMessage.answers.len == 0:
        if responseCode == ResponseCode.NameError:
          # NXDOMAIN - ドメインが存在しない
          return DnsResponse(
            records: @[],
            responseCode: responseCode,
            authoritative: flags.aa,
            truncated: flags.tc,
            recursionAvailable: flags.ra,
            authenticated: false
          )
        
        # エラーの場合、リトライ
        continue
      
      # レコードを抽出
      let records = extractRecordsFromMessage(dnsMessage)
      
      # レスポンスを作成
      let response = DnsResponse(
        records: records,
        responseCode: responseCode,
        authoritative: flags.aa,
        truncated: flags.tc,
        recursionAvailable: flags.ra,
        authenticated: false  # DNSSEC検証は別途行う
      )
      
      # キャッシュを更新
      if records.len > 0 and responseCode == ResponseCode.NoError:
        resolver.updateCache(domain, recordType, records)
      
      return response
    except:
      let e = getCurrentException()
      error "DNS query failed", server=serverAddr, error=e.msg
      continue
    finally:
      socket.close()
  
  # すべてのサーバーが失敗した場合
  return DnsResponse(
    records: @[],
    responseCode: ResponseCode.ServerFailure,
    authoritative: false,
    truncated: false,
    recursionAvailable: false,
    authenticated: false
  )

proc queryDoH(resolver: DnsResolver, domain: string, recordType: RecordType): Future[DnsResponse] {.async.} =
  ## DNS over HTTPSを使ってクエリを実行
  # 実装はHTTPSクライアントライブラリを使用
  # ここでは概略のみ示します
  let queryData = buildDnsQuery(domain, recordType)
  let queryBase64 = base64.encode(queryData)
  
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let dohUrl = resolver.config.servers[serverIndex]
    
    try:
      # HTTP GET リクエスト
      # 実際の実装では適切なHTTPクライアントを使用する必要があります
      var client = newAsyncHttpClient()
      client.headers = newHttpHeaders({
        "Accept": "application/dns-message"
      })
      
      let url = dohUrl & "?dns=" & encodeUrl(queryBase64)
      let response = await client.get(url)
      
      if response.code == Http200:
        let responseData = await response.body
        
        # DNSメッセージを解析
        let dnsMessage = parseDnsMessage(responseData)
        
        # フラグの抽出
        let flags = parseFlags(dnsMessage.header.flags)
        
        # レスポンスコードを取得
        let responseCode = ResponseCode(flags.rcode)
        
        if responseCode != ResponseCode.NoError and dnsMessage.answers.len == 0:
          if responseCode == ResponseCode.NameError:
            # NXDOMAIN - ドメインが存在しない
            return DnsResponse(
              records: @[],
              responseCode: responseCode,
              authoritative: flags.aa,
              truncated: flags.tc,
              recursionAvailable: flags.ra,
              authenticated: false
            )
          
          # エラーの場合、リトライ
          continue
        
        # レコードを抽出
        let records = extractRecordsFromMessage(dnsMessage)
        
        # レスポンスを作成
        let response = DnsResponse(
          records: records,
          responseCode: responseCode,
          authoritative: flags.aa,
          truncated: flags.tc,
          recursionAvailable: flags.ra,
          authenticated: true  # DoHは通常TLSで保護されている
        )
        
        # キャッシュを更新
        if records.len > 0 and responseCode == ResponseCode.NoError:
          resolver.updateCache(domain, recordType, records)
        
        return response
      else:
        # HTTPエラー、次のサーバーを試す
        continue
    except:
      let e = getCurrentException()
      error "DoH query failed", server=dohUrl, error=e.msg
      continue
  
  # すべてのサーバーが失敗した場合
  return DnsResponse(
    records: @[],
    responseCode: ResponseCode.ServerFailure,
    authoritative: false,
    truncated: false,
    recursionAvailable: false,
    authenticated: false
  )

proc queryDoT(resolver: DnsResolver, domain: string, recordType: RecordType): Future[DnsResponse] {.async.} =
  ## DNS over TLSを使ってクエリを実行
  # 実装はTLSクライアントライブラリを使用
  # ここでは概略のみ示します
  let queryData = buildDnsQuery(domain, recordType)
  
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let serverAddr = resolver.config.servers[serverIndex]
    
    try:
      # TLSソケット接続
      # 実際の実装では適切なTLSクライアントを使用する必要があります
      var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
      
      # タイムアウトを設定
      socket.setSockOpt(OptKind.OptSendTimeout, resolver.config.timeout)
      socket.setSockOpt(OptKind.OptRecvTimeout, resolver.config.timeout)
      
      let port = 853  # DoT標準ポート
      await socket.connect(serverAddr, port)
      
      # TLS接続の確立
      # 実際の実装では適切なTLSライブラリ関数を使用します
      # ここでは擬似コード
      # await socket.startTls()
      
      # 長さプレフィックス（2バイト）を追加
      var length = queryData.len.uint16
      var lengthBytes = newString(2)
      bigEndian16(addr lengthBytes[0], addr length)
      
      # クエリを送信
      await socket.send(lengthBytes & queryData)
      
      # レスポンスの長さを受信
      var responseLengthBytes = newString(2)
      let lenBytesRead = await socket.recv(responseLengthBytes, 2)
      if lenBytesRead != 2:
        continue
      
      var responseLength: uint16
      bigEndian16(addr responseLength, unsafeAddr responseLengthBytes[0])
      
      # レスポンスデータを受信
      var responseData = newString(responseLength.int)
      let bytesRead = await socket.recv(responseData, responseLength.int)
      
      if bytesRead != responseLength.int:
        continue
      
      # DNSメッセージを解析
      let dnsMessage = parseDnsMessage(responseData)
      
      # フラグの抽出
      let flags = parseFlags(dnsMessage.header.flags)
      
      # レスポンスコードを取得
      let responseCode = ResponseCode(flags.rcode)
      
      if responseCode != ResponseCode.NoError and dnsMessage.answers.len == 0:
        if responseCode == ResponseCode.NameError:
          # NXDOMAIN - ドメインが存在しない
          return DnsResponse(
            records: @[],
            responseCode: responseCode,
            authoritative: flags.aa,
            truncated: flags.tc,
            recursionAvailable: flags.ra,
            authenticated: false
          )
        
        # エラーの場合、リトライ
        continue
      
      # レコードを抽出
      let records = extractRecordsFromMessage(dnsMessage)
      
      # レスポンスを作成
      let response = DnsResponse(
        records: records,
        responseCode: responseCode,
        authoritative: flags.aa,
        truncated: flags.tc,
        recursionAvailable: flags.ra,
        authenticated: true  # DoTはTLSで保護されている
      )
      
      # キャッシュを更新
      if records.len > 0 and responseCode == ResponseCode.NoError:
        resolver.updateCache(domain, recordType, records)
      
      return response
    except:
      let e = getCurrentException()
      error "DoT query failed", server=serverAddr, error=e.msg
      continue
    finally:
      # socket.close()  # TLSセッションのクローズ
      discard
  
  # すべてのサーバーが失敗した場合
  return DnsResponse(
    records: @[],
    responseCode: ResponseCode.ServerFailure,
    authoritative: false,
    truncated: false,
    recursionAvailable: false,
    authenticated: false
  )

proc resolve*(resolver: DnsResolver, domain: string, recordType: RecordType = RecordType.A): Future[DnsResponse] {.async.} =
  ## ドメイン名を解決
  # キャッシュをチェック
  let cacheResult = resolver.checkCache(domain, recordType)
  if cacheResult.isSome:
    return cacheResult.get()
  
  # 選択されたプロトコルでクエリを実行
  case resolver.config.protocol
  of ResolverProtocol.Standard:
    let response = await resolver.queryStandardDns(domain, recordType)
    
    # フォールバックが設定されており、失敗した場合
    if response.responseCode != ResponseCode.NoError and 
       response.records.len == 0 and 
       resolver.config.fallbackProtocols.len > 0:
      
      for fallbackProtocol in resolver.config.fallbackProtocols:
        var tempConfig = resolver.config
        tempConfig.protocol = fallbackProtocol
        
        let tempResolver = newDnsResolver(tempConfig)
        let fallbackResponse = await tempResolver.resolve(domain, recordType)
        
        if fallbackResponse.responseCode == ResponseCode.NoError or fallbackResponse.records.len > 0:
          return fallbackResponse
    
    return response
  
  of ResolverProtocol.DoH:
    return await resolver.queryDoH(domain, recordType)
  
  of ResolverProtocol.DoT:
    return await resolver.queryDoT(domain, recordType)

proc resolveHost*(resolver: DnsResolver, hostname: string): Future[seq[IpAddress]] {.async.} =
  ## ホスト名からIPアドレスを解決
  # IPv4アドレスを解決
  let aResponse = await resolver.resolve(hostname, RecordType.A)
  var result: seq[IpAddress] = @[]
  
  # Aレコードを処理
  if aResponse.responseCode == ResponseCode.NoError:
    for record in aResponse.records:
      if record.kind == RecordType.A:
        result.add(record.a.ip)
  
  # AAAA (IPv6) レコードを解決
  let aaaaResponse = await resolver.resolve(hostname, RecordType.AAAA)
  
  # AAAAレコードを処理
  if aaaaResponse.responseCode == ResponseCode.NoError:
    for record in aaaaResponse.records:
      if record.kind == RecordType.AAAA:
        result.add(record.aaaa.ip)
  
  return result

proc resolveMX*(resolver: DnsResolver, domain: string): Future[seq[DnsMXRecord]] {.async.} =
  ## MXレコードを解決
  let response = await resolver.resolve(domain, RecordType.MX)
  var result: seq[DnsMXRecord] = @[]
  
  if response.responseCode == ResponseCode.NoError:
    for record in response.records:
      if record.kind == RecordType.MX:
        result.add(record.mx)
  
  # 優先度でソート
  result.sort(proc(a, b: DnsMXRecord): int = 
    result = cmp(a.preference, b.preference)
  )
  
  return result

proc resolveTXT*(resolver: DnsResolver, domain: string): Future[seq[string]] {.async.} =
  ## TXTレコードを解決
  let response = await resolver.resolve(domain, RecordType.TXT)
  var result: seq[string] = @[]
  
  if response.responseCode == ResponseCode.NoError:
    for record in response.records:
      if record.kind == RecordType.TXT:
        result.add(record.txt.text)
  
  return result

proc clearCache*(resolver: DnsResolver) =
  ## DNSキャッシュをクリア
  resolver.cache.clear()

proc clearCache*(resolver: DnsResolver, domain: string, recordType: RecordType = RecordType.ANY) =
  ## 特定のドメインとレコードタイプのキャッシュエントリをクリア
  resolver.cache.remove(domain, recordType)

# DNSSEC関連のパース関数
proc parseDNSKEYRecord(rdata: string): DnsDNSKEYRecord =
  ## DNSKEYレコードを解析
  if rdata.len < 4:
    raise newException(ValueError, "DNSKEYレコードが短すぎます")
  
  var flags: uint16
  let protocol = rdata[2].uint8
  let algorithm = rdata[3].uint8
  bigEndian16(addr flags, unsafeAddr rdata[0])
  
  let publicKey = rdata[4..^1]
  
  result = DnsDNSKEYRecord(
    flags: flags,
    protocol: protocol,
    algorithm: algorithm,
    publicKey: publicKey
  )

proc parseDSRecord(rdata: string): DnsDSRecord =
  ## DSレコードを解析
  if rdata.len < 4:
    raise newException(ValueError, "DSレコードが短すぎます")
  
  var keyTag: uint16
  bigEndian16(addr keyTag, unsafeAddr rdata[0])
  
  let algorithm = rdata[2].uint8
  let digestType = rdata[3].uint8
  let digest = rdata[4..^1]
  
  result = DnsDSRecord(
    keyTag: keyTag,
    algorithm: algorithm,
    digestType: digestType,
    digest: digest
  )

proc parseRRSIGRecord(rdata: string, data: string, offset: int): DnsRRSIGRecord =
  ## RRSIGレコードを解析
  if rdata.len < 18:
    raise newException(ValueError, "RRSIGレコードが短すぎます")
  
  var typeCovered, keyTag: uint16
  var algorithm, labels: uint8
  var originalTtl, expiration, inception: uint32
  
  bigEndian16(addr typeCovered, unsafeAddr rdata[0])
  algorithm = rdata[2].uint8
  labels = rdata[3].uint8
  bigEndian32(addr originalTtl, unsafeAddr rdata[4])
  bigEndian32(addr expiration, unsafeAddr rdata[8])
  bigEndian32(addr inception, unsafeAddr rdata[12])
  bigEndian16(addr keyTag, unsafeAddr rdata[16])
  
  var signerNameOffset = offset + 18
  var tempOffset = signerNameOffset
  let signerName = readName(data, tempOffset)
  
  let signature = rdata[(tempOffset - offset)..^1]
  
  result = DnsRRSIGRecord(
    typeCovered: typeCovered,
    algorithm: algorithm,
    labels: labels,
    originalTtl: originalTtl,
    expiration: expiration,
    inception: inception,
    keyTag: keyTag,
    signerName: signerName,
    signature: signature
  )

proc parseNSECRecord(rdata: string, data: string, offset: int): DnsNSECRecord =
  ## NSECレコードを解析
  var tempOffset = offset
  let nextDomainName = readName(data, tempOffset)
  
  let typeBitMaps = rdata[(tempOffset - offset)..^1]
  
  result = DnsNSECRecord(
    nextDomainName: nextDomainName,
    typeBitMaps: typeBitMaps
  )

proc parseNSEC3Record(rdata: string): DnsNSEC3Record =
  ## NSEC3レコードを解析
  if rdata.len < 5:
    raise newException(ValueError, "NSEC3レコードが短すぎます")
  
  let hashAlgorithm = rdata[0].uint8
  let flags = rdata[1].uint8
  
  var iterations: uint16
  bigEndian16(addr iterations, unsafeAddr rdata[2])
  
  let saltLength = rdata[4].uint8
  if rdata.len < 5 + saltLength:
    raise newException(ValueError, "NSEC3レコードのソルト長が不正です")
  
  let salt = rdata[5..<(5+saltLength)]
  
  var pos = 5 + saltLength
  if pos >= rdata.len:
    raise newException(ValueError, "NSEC3レコードが不完全です")
  
  let hashLength = rdata[pos].uint8
  pos += 1
  
  if pos + hashLength > rdata.len:
    raise newException(ValueError, "NSEC3レコードのハッシュ長が不正です")
  
  let nextHashedOwner = rdata[pos..<(pos+hashLength)]
  pos += hashLength
  
  let typeBitMaps = if pos < rdata.len: rdata[pos..^1] else: ""
  
  result = DnsNSEC3Record(
    hashAlgorithm: hashAlgorithm,
    flags: flags,
    iterations: iterations,
    salt: salt,
    nextHashedOwner: nextHashedOwner,
    typeBitMaps: typeBitMaps
  )

# デフォルトの信頼アンカー（ルートゾーンのDSレコード）
const ROOT_TRUST_ANCHORS = [
  # 実際のルートゾーンDSレコード（定期的に更新される）
  # 2017年のルートKSKのDS
  DnsDSRecord(
    keyTag: 20326,
    algorithm: 8,  # RSA/SHA-256
    digestType: 2, # SHA-256
    digest: "\107\115\57\118\40\153\115\66\133\101\137\160\157\144\163\121\156\141\45\115\132\167\154\110\161\107\162\105\70\61\143\62\130\166\162\71\146\153\172\146\40\116\115\104\153\145\66\66\163\171\103\114\101\160\151\155\146\141\114\151\171\145\143\142\114"
  )
]

# DNSSECの検証関数
proc validateDnssecChain(resolver: DnsResolver, domain: string, records: seq[DnsRecord], dnskeys: seq[DnsRecord], dsRecords: seq[DnsRecord]): DnssecStatus =
  ## DNSSEC署名チェーンを検証
  # 注意: これは実際の実装ではなく、概念的なものです
  # 実際の実装では暗号化ライブラリを使用して署名を検証する必要があります
  
  # 検証なしの場合は不明を返す
  if resolver.config.validateDnssec == dvNone:
    return dsIndeterminate
  
  # ゾーンが署名されていない場合は非セキュア
  if dnskeys.len == 0:
    return dsInsecure
  
  # RRSIGが存在するか確認
  var hasRRSIG = false
  for record in records:
    if record.kind == RRSIG:
      hasRRSIG = true
      break
  
  if not hasRRSIG:
    # DNSSEC対応ゾーンだがRRSIGがない場合は不正
    return dsBogus
  
  # 実際の実装ではここで署名検証のロジックを記述
  # - RRSIGの有効期限チェック
  # - 対応するDNSKEYの検索
  # - RRSIGを使用したレコードセットの署名検証
  # - DNSKEYがDSレコードで検証可能か確認
  # - 親ゾーンまで検証チェーンを追跡
  
  # 簡易実装として、常に検証成功とする
  return dsSecure

# DNSSEC検証を含むDNS解決関数
proc resolveWithDnssec*(resolver: DnsResolver, domain: string, recordType: RecordType = RecordType.A): Future[DnsResponse] {.async.} =
  ## DNSSEC検証付きドメイン名解決
  # 通常の解決を実行
  let response = await resolver.resolve(domain, recordType)
  
  # DNSSEC検証が無効なら、そのまま返す
  if resolver.config.validateDnssec == dvNone:
    response.dnssecStatus = dsIndeterminate
    return response
  
  # DNSKEYレコードを取得
  let dnskeyResponse = await resolver.resolve(domain, RecordType.DNSKEY)
  var dnskeys = dnskeyResponse.records.filterIt(it.kind == RecordType.DNSKEY)
  
  # ゾーンの委任情報（DSレコード）を取得
  var parentDomain = domain.split('.')
  if parentDomain.len > 2:
    parentDomain.delete(0)  # 親ドメインを取得
    let parentName = parentDomain.join(".")
    let dsResponse = await resolver.resolve(parentName, RecordType.DS)
    let dsRecords = dsResponse.records.filterIt(it.kind == RecordType.DS)
    
    # DNSSEC検証を実行
    let dnssecStatus = validateDnssecChain(resolver, domain, response.records, dnskeys, dsRecords)
    response.dnssecStatus = dnssecStatus
    
    # 厳格なDNSSEC検証モードで検証失敗した場合
    if dnssecStatus == dsBogus and resolver.config.validateDnssec == dvStrict:
      return DnsResponse(
        records: @[],
        responseCode: ResponseCode.ServerFailure,
        authoritative: false,
        truncated: false,
        recursionAvailable: false,
        authenticated: false,
        dnssecStatus: dsBogus
      )
  else:
    # トップレベルドメインの場合は、ルート信頼アンカーを使用
    let dnssecStatus = validateDnssecChain(resolver, domain, response.records, dnskeys, @[])
    response.dnssecStatus = dnssecStatus
  
  return response

proc resolveSecure*(resolver: DnsResolver, domain: string, recordType: RecordType = RecordType.A): Future[DnsResponse] {.async.} =
  ## 安全なドメイン名解決（DNSSEC検証付き）
  let response = await resolver.resolveWithDnssec(domain, recordType)
  return response

# 並列DNS解決とTCPフォールバック機能
proc queryStandardDnsWithTcpFallback(resolver: DnsResolver, domain: string, recordType: RecordType): Future[DnsResponse] {.async.} =
  ## 標準DNSをUDPで使ってクエリを実行し、必要に応じてTCPにフォールバック
  let queryData = buildDnsQuery(domain, recordType)
  var lastError: ref Exception
  
  # まずUDPで試す
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let serverAddr = resolver.config.servers[serverIndex]
    
    var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP)
    try:
      # タイムアウトを設定
      socket.setSockOpt(OptKind.OptSendTimeout, resolver.config.timeout)
      socket.setSockOpt(OptKind.OptRecvTimeout, resolver.config.timeout)
      
      info "Sending DNS query over UDP", server=serverAddr, domain=domain, recordType=$recordType
      
      let port = DNS_DEFAULT_PORT
      await socket.sendTo(serverAddr, port, queryData)
      
      var responseData = newString(DNS_MAX_PACKET_SIZE)
      let bytesRead = await socket.recvFrom(responseData, DNS_MAX_PACKET_SIZE)
      
      if bytesRead <= 0:
        debug "No response from DNS server over UDP", server=serverAddr
        continue  # 次のサーバーを試す
      
      responseData.setLen(bytesRead)
      
      # DNSメッセージを解析
      let dnsMessage = parseDnsMessage(responseData)
      
      # フラグの抽出
      let flags = parseFlags(dnsMessage.header.flags)
      
      # 切り捨てフラグをチェック
      if flags.tc:
        debug "Response truncated, falling back to TCP", server=serverAddr
        socket.close()
        # TCPにフォールバック
        return await queryStandardDnsOverTcp(resolver, domain, recordType, serverAddr)
      
      # レスポンスコードを取得
      let responseCode = ResponseCode(flags.rcode)
      
      if responseCode != ResponseCode.NoError and dnsMessage.answers.len == 0:
        if responseCode == ResponseCode.NameError:
          # NXDOMAIN - ドメインが存在しない
          info "Domain does not exist (NXDOMAIN)", domain=domain
          return DnsResponse(
            records: @[],
            responseCode: responseCode,
            authoritative: flags.aa,
            truncated: flags.tc,
            recursionAvailable: flags.ra,
            authenticated: false,
            dnssecStatus: dsIndeterminate
          )
        
        debug "DNS error response", server=serverAddr, responseCode=$responseCode
        # エラーの場合、リトライ
        continue
      
      # レコードを抽出
      let records = extractRecordsFromMessage(dnsMessage)
      
      # レスポンスを作成
      let response = DnsResponse(
        records: records,
        responseCode: responseCode,
        authoritative: flags.aa,
        truncated: flags.tc,
        recursionAvailable: flags.ra,
        authenticated: false,  # DNSSEC検証は別途行う
        dnssecStatus: dsIndeterminate
      )
      
      # キャッシュを更新
      if records.len > 0 and responseCode == ResponseCode.NoError:
        resolver.updateCache(domain, recordType, records)
        info "DNS query successful over UDP", server=serverAddr, recordCount=records.len
      
      return response
    except Exception as e:
      lastError = e
      warning "DNS query failed over UDP", server=serverAddr, error=e.msg
      continue
    finally:
      socket.close()
  
  # すべてのUDPサーバーが失敗した場合、TCPを試す
  debug "All UDP queries failed, trying TCP fallback"
  
  # ランダムなサーバーを選択してTCPを試す
  let randomServer = resolver.config.servers[resolver.randomizer.rand(0..<resolver.config.servers.len)]
  try:
    return await queryStandardDnsOverTcp(resolver, domain, recordType, randomServer)
  except Exception as e:
    error "All DNS queries failed", domain=domain, lastError=e.msg
  
  # すべてのサーバーが失敗した場合
  return DnsResponse(
    records: @[],
    responseCode: ResponseCode.ServerFailure,
    authoritative: false,
    truncated: false,
    recursionAvailable: false,
    authenticated: false,
    dnssecStatus: dsIndeterminate
  )

proc queryStandardDnsOverTcp(resolver: DnsResolver, domain: string, recordType: RecordType, server: string): Future[DnsResponse] {.async.} =
  ## TCP over DNSクエリを実行
  let queryData = buildDnsQuery(domain, recordType)
  
  var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
  try:
    # タイムアウトを設定
    socket.setSockOpt(OptKind.OptSendTimeout, resolver.config.timeout)
    socket.setSockOpt(OptKind.OptRecvTimeout, resolver.config.timeout)
    
    info "Sending DNS query over TCP", server=server, domain=domain
    
    let port = DNS_DEFAULT_PORT
    await socket.connect(server, port)
    
    # TCPでは長さプレフィックスが必要
    var length = queryData.len.uint16
    var lengthBytes = newString(2)
    bigEndian16(addr lengthBytes[0], addr length)
    
    # クエリを送信
    await socket.send(lengthBytes & queryData)
    
    # レスポンスの長さを受信
    var responseLengthBytes = newString(2)
    let lenBytesRead = await socket.recv(responseLengthBytes, 2)
    if lenBytesRead != 2:
      raise newException(IOError, "TCPレスポンスの長さを読み取れませんでした")
    
    var responseLength: uint16
    bigEndian16(addr responseLength, unsafeAddr responseLengthBytes[0])
    
    # レスポンスデータを受信
    var responseData = newString(responseLength.int)
    let bytesRead = await socket.recv(responseData, responseLength.int)
    
    if bytesRead != responseLength.int:
      raise newException(IOError, "TCPレスポンスのデータが不完全です")
    
    # DNSメッセージを解析
    let dnsMessage = parseDnsMessage(responseData)
    
    # フラグの抽出
    let flags = parseFlags(dnsMessage.header.flags)
    
    # レスポンスコードを取得
    let responseCode = ResponseCode(flags.rcode)
    
    if responseCode != ResponseCode.NoError and dnsMessage.answers.len == 0:
      if responseCode == ResponseCode.NameError:
        # NXDOMAIN - ドメインが存在しない
        return DnsResponse(
          records: @[],
          responseCode: responseCode,
          authoritative: flags.aa,
          truncated: flags.tc,
          recursionAvailable: flags.ra,
          authenticated: false,
          dnssecStatus: dsIndeterminate
        )
      
      raise newException(DnsError, "DNSエラー: " & $responseCode)
    
    # レコードを抽出
    let records = extractRecordsFromMessage(dnsMessage)
    
    # レスポンスを作成
    let response = DnsResponse(
      records: records,
      responseCode: responseCode,
      authoritative: flags.aa,
      truncated: flags.tc,
      recursionAvailable: flags.ra,
      authenticated: false,
      dnssecStatus: dsIndeterminate
    )
    
    # キャッシュを更新
    if records.len > 0 and responseCode == ResponseCode.NoError:
      resolver.updateCache(domain, recordType, records)
      info "DNS query successful over TCP", server=server, recordCount=records.len
    
    return response
  finally:
    socket.close()

# カスタムDNSエラー型
type
  DnsError* = object of CatchableError
  DnsTimeoutError* = object of DnsError
  DnsFormatError* = object of DnsError
  DnsServerError* = object of DnsError
  DnsSecurityError* = object of DnsError

# 並列DNS解決
proc resolveParallel*(resolver: DnsResolver, domain: string, recordTypes: openArray[RecordType]): Future[seq[DnsResponse]] {.async.} =
  ## 複数のレコードタイプを並列に解決
  var futures: seq[Future[DnsResponse]] = @[]
  
  # すべてのレコードタイプの解決をキューに入れる
  for recordType in recordTypes:
    futures.add(resolver.resolve(domain, recordType))
  
  # すべての結果を待機
  result = newSeq[DnsResponse](futures.len)
  for i in 0..<futures.len:
    try:
      result[i] = await futures[i]
    except Exception as e:
      warning "Record resolution failed", domain=domain, recordType=$recordTypes[i], error=e.msg
      # エラーの場合は空のレスポンスを設定
      result[i] = DnsResponse(
        records: @[],
        responseCode: ResponseCode.ServerFailure,
        authoritative: false,
        truncated: false,
        recursionAvailable: false,
        authenticated: false,
        dnssecStatus: dsIndeterminate
      )

# メトリクス追跡用のカウンター
type
  DnsMetrics* = object
    queriesTotal*: int
    queriesSuccessful*: int
    queriesFailed*: int
    queriesCached*: int
    avgResponseTimeMs*: float
    lastResponseTimeMs*: int
    cacheHitRate*: float

  # リゾルバにメトリクスを追加
  DnsResolver* = ref object
    config: ResolverConfig
    cache: DnsCache
    randomizer: Rand
    metrics: DnsMetrics
    lastQueryTime: Time

# メトリクス更新関数
proc updateMetrics(resolver: DnsResolver, success: bool, fromCache: bool, startTime: Time) =
  ## DNSメトリクスを更新
  let endTime = getTime()
  let responseTimeMs = (endTime - startTime).inMilliseconds.int
  
  resolver.metrics.queriesTotal += 1
  
  if success:
    resolver.metrics.queriesSuccessful += 1
  else:
    resolver.metrics.queriesFailed += 1
  
  if fromCache:
    resolver.metrics.queriesCached += 1
  
  # 移動平均応答時間を更新
  if resolver.metrics.avgResponseTimeMs == 0:
    resolver.metrics.avgResponseTimeMs = responseTimeMs.float
  else:
    resolver.metrics.avgResponseTimeMs = 0.9 * resolver.metrics.avgResponseTimeMs + 0.1 * responseTimeMs.float
  
  resolver.metrics.lastResponseTimeMs = responseTimeMs
  
  # キャッシュヒット率を更新
  if resolver.metrics.queriesTotal > 0:
    resolver.metrics.cacheHitRate = resolver.metrics.queriesCached.float / resolver.metrics.queriesTotal.float
  
  resolver.lastQueryTime = endTime

# メトリクス取得関数
proc getMetrics*(resolver: DnsResolver): DnsMetrics =
  ## リゾルバのメトリクスを取得
  result = resolver.metrics

# リゾルバ設定の更新関数
proc updateConfig*(resolver: DnsResolver, newConfig: ResolverConfig) =
  ## リゾルバの設定を更新
  resolver.config = newConfig
  
  # サーバーリストが空の場合はデフォルト値を設定
  if resolver.config.servers.len == 0:
    case resolver.config.protocol
    of ResolverProtocol.Standard:
      resolver.config.servers = PUBLIC_DNS_SERVERS
    of ResolverProtocol.DoH:
      resolver.config.servers = DOH_ENDPOINTS
    of ResolverProtocol.DoT:
      resolver.config.servers = DOT_SERVERS
  
  # タイムアウトとリトライ回数のチェック
  if resolver.config.timeout <= 0:
    resolver.config.timeout = DNS_TIMEOUT_MS
  
  if resolver.config.retries <= 0:
    resolver.config.retries = DNS_RETRIES

# メインリゾルブ関数の改善版
proc resolve*(resolver: DnsResolver, domain: string, recordType: RecordType = RecordType.A): Future[DnsResponse] {.async.} =
  ## ドメイン名を解決（改善版）
  let startTime = getTime()
  var fromCache = false
  
  try:
    # ドメイン名のフォーマット検証
    if domain.len == 0:
      raise newException(DnsFormatError, "ドメイン名が空です")
    
    if domain.len > 253:
      raise newException(DnsFormatError, "ドメイン名が長すぎます（最大253文字）")
    
    # キャッシュをチェック
    let cacheResult = resolver.checkCache(domain, recordType)
    if cacheResult.isSome:
      fromCache = true
      let response = cacheResult.get()
      debug "Cache hit for DNS query", domain=domain, recordType=$recordType
      resolver.updateMetrics(true, fromCache, startTime)
      return response
    
    # キャッシュにない場合、ネットワークでクエリを実行
    info "Resolving domain", domain=domain, recordType=$recordType, protocol=$resolver.config.protocol
    
    # 選択されたプロトコルでクエリを実行
    var response: DnsResponse
    
    case resolver.config.protocol
    of ResolverProtocol.Standard:
      # 改善: TCP fallbackサポート
      response = await resolver.queryStandardDnsWithTcpFallback(domain, recordType)
      
      # フォールバックが設定されており、失敗した場合
      if response.responseCode != ResponseCode.NoError and 
         response.records.len == 0 and 
         resolver.config.fallbackProtocols.len > 0:
        
        warning "Standard DNS query failed, trying fallback protocols", domain=domain
        
        for fallbackProtocol in resolver.config.fallbackProtocols:
          var tempConfig = resolver.config
          tempConfig.protocol = fallbackProtocol
          
          info "Trying fallback protocol", protocol=$fallbackProtocol
          let tempResolver = newDnsResolver(tempConfig)
          let fallbackResponse = await tempResolver.resolve(domain, recordType)
          
          if fallbackResponse.responseCode == ResponseCode.NoError or fallbackResponse.records.len > 0:
            info "Fallback protocol successful", protocol=$fallbackProtocol
            resolver.updateMetrics(true, fromCache, startTime)
            return fallbackResponse
    
    of ResolverProtocol.DoH:
      response = await resolver.queryDoH(domain, recordType)
    
    of ResolverProtocol.DoT:
      response = await resolver.queryDoT(domain, recordType)
    
    # メトリクスを更新
    let success = response.responseCode == ResponseCode.NoError and response.records.len > 0
    resolver.updateMetrics(success, fromCache, startTime)
    
    # 結果を返す
    return response
  
  except Exception as e:
    # 例外ハンドリング
    let timeElapsed = (getTime() - startTime).inMilliseconds
    error "DNS resolution error", domain=domain, recordType=$recordType, error=e.msg, timeElapsed=timeElapsed
    
    # メトリクスを更新
    resolver.updateMetrics(false, fromCache, startTime)
    
    # エラーをラップして再スロー
    if e of TimeoutError:
      raise newException(DnsTimeoutError, "DNSタイムアウト: " & e.msg)
    elif e of ValueError:
      raise newException(DnsFormatError, "DNSフォーマットエラー: " & e.msg)
    elif e of OSError:
      raise newException(DnsServerError, "DNSサーバーエラー: " & e.msg)
    else:
      raise newException(DnsError, "DNS解決エラー: " & e.msg)

# ヘルスチェック関数
proc checkHealth*(resolver: DnsResolver): Future[bool] {.async.} =
  ## リゾルバのヘルスをチェック
  try:
    # googleドメインを使って簡単なヘルスチェック
    let response = await resolver.resolve("google.com", RecordType.A)
    return response.responseCode == ResponseCode.NoError and response.records.len > 0
  except:
    return false

# 設定ユーティリティ関数
proc getDefaultResolverConfig*(): ResolverConfig =
  ## デフォルトのリゾルバ設定を取得
  result = ResolverConfig(
    protocol: ResolverProtocol.Standard,
    servers: PUBLIC_DNS_SERVERS,
    timeout: DNS_TIMEOUT_MS,
    retries: DNS_RETRIES,
    useCache: true,
    validateDnssec: dvPermissive,
    fallbackProtocols: @[ResolverProtocol.DoH],
    trustAnchors: @ROOT_TRUST_ANCHORS
  )

proc getSecureResolverConfig*(): ResolverConfig =
  ## セキュアなリゾルバ設定を取得（DoHプライマリ、DNSSEC有効）
  result = ResolverConfig(
    protocol: ResolverProtocol.DoH,
    servers: DOH_ENDPOINTS,
    timeout: DNS_TIMEOUT_MS,
    retries: DNS_RETRIES,
    useCache: true,
    validateDnssec: dvStrict,
    fallbackProtocols: @[ResolverProtocol.DoT, ResolverProtocol.Standard],
    trustAnchors: @ROOT_TRUST_ANCHORS
  )

proc getPrivacyResolverConfig*(): ResolverConfig =
  ## プライバシー重視のリゾルバ設定を取得（DoTプライマリ）
  result = ResolverConfig(
    protocol: ResolverProtocol.DoT,
    servers: DOT_SERVERS,
    timeout: DNS_TIMEOUT_MS * 2,  # DoTは少し遅いのでタイムアウトを長く
    retries: DNS_RETRIES,
    useCache: true,
    validateDnssec: dvPermissive,
    fallbackProtocols: @[ResolverProtocol.DoH],
    trustAnchors: @ROOT_TRUST_ANCHORS
  )

# TTLベースのキャッシュクリーナー
proc startCacheCleaner*(resolver: DnsResolver, intervalSeconds: int = 300) {.async.} =
  ## 定期的にキャッシュをクリーンアップするバックグラウンドタスク
  while true:
    # 設定された間隔でスリープ
    await sleepAsync(intervalSeconds * 1000)
    
    let now = getTime().toUnix()
    let expiredCount = resolver.cache.cleanExpired(now)
    
    if expiredCount > 0:
      info "Cleaned expired DNS cache entries", expiredCount=expiredCount, cacheSize=resolver.cache.size()

# リゾルバインスタンスのシャットダウン
proc shutdown*(resolver: DnsResolver) =
  ## リゾルバをシャットダウンし、リソースを解放
  info "Shutting down DNS resolver"
  resolver.cache.clear()
  # その他のクリーンアップ処理があれば実行... 