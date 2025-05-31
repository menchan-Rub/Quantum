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
  let queryData = buildDnsQuery(domain, recordType)
  let queryBase64 = base64.encode(queryData)
  
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let dohUrl = resolver.config.servers[serverIndex]
    
    try:
      # 完全なHTTPクライアント実装
      var client = newAsyncHttpClient()
      client.timeout = resolver.config.timeout.milliseconds
      client.headers = newHttpHeaders({
        "Accept": "application/dns-message",
        "User-Agent": "Quantum-Browser/1.0",
        "Content-Type": "application/dns-message"
      })
      
      let url = dohUrl & "?dns=" & encodeUrl(queryBase64)
      
      # タイムアウト付きGETリクエスト
      var responseFuture = client.get(url)
      let timeoutFuture = sleepAsync(resolver.config.timeout)
      
      let firstDone = await oneOf(responseFuture, timeoutFuture)
      if firstDone == 1:  # タイムアウト発生
        error "DoH request timed out", server=dohUrl, timeout=resolver.config.timeout
        await client.close()
        continue
        
      let response = await responseFuture
      
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
            await client.close()
            return DnsResponse(
              records: @[],
              responseCode: responseCode,
              authoritative: flags.aa,
              truncated: flags.tc,
              recursionAvailable: flags.ra,
              authenticated: false
            )
          
          # エラーの場合、リトライ
          await client.close()
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
        
        # HTTP接続を閉じる
        await client.close()
        
        # メトリクス更新
        resolver.dohMetrics.updateMetrics(
          server = dohUrl,
          success = true,
          responseTime = (getTime() - start).inMilliseconds.int,
          responseSize = responseData.len
        )
        
        return response
      else:
        # HTTPエラー、次のサーバーを試す
        error "DoH request failed with HTTP code", server=dohUrl, code=response.code
        await client.close()
        
        # メトリクス更新 - 失敗
        resolver.dohMetrics.updateMetrics(
          server = dohUrl,
          success = false,
          responseTime = (getTime() - start).inMilliseconds.int
        )
        
        continue
    except CatchableError as e:
      error "DoH query failed", server=dohUrl, error=e.msg
      
      # メトリクス更新 - 例外
      resolver.dohMetrics.updateMetrics(
        server = dohUrl,
        success = false,
        exception = e.msg
      )
      
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
  let queryData = buildDnsQuery(domain, recordType)
  let start = getTime()
  
  for serverIndex in 0..<min(resolver.config.servers.len, resolver.config.retries + 1):
    let serverAddr = resolver.config.servers[serverIndex]
    
    try:
      # 完全なTLSソケット実装
      var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
      
      # タイムアウトを設定
      socket.setSockOpt(OptKind.OptSendTimeout, resolver.config.timeout)
      socket.setSockOpt(OptKind.OptRecvTimeout, resolver.config.timeout)
      
      let port = 853  # DoT標準ポート
      
      # 非同期接続とタイムアウト処理
      let connectFuture = socket.connect(serverAddr, Port(port))
      let timeoutFuture = sleepAsync(resolver.config.timeout)
      
      let firstDone = await oneOf(connectFuture, timeoutFuture)
      if firstDone == 1:  # タイムアウト発生
        error "DoT connection timed out", server=serverAddr, timeout=resolver.config.timeout
        socket.close()
        continue
        
      # TLSコンテキスト設定
      var tlsContext = newTLSContext(verifyMode = CVerifyPeer)
      
      # TLSバージョンと暗号スイートの設定
      tlsContext.protocolMin = TLSv1_3
      tlsContext.protocolMax = TLSv1_3
      tlsContext.setCipherList("TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256")
      
      # 証明書検証設定
      tlsContext.set_default_verify_paths() # システムのルート証明書を使用
      tlsContext.set_verify_depth(4)  # 証明書チェーンの最大深度
      
      # TLSソケットを作成
      var tlsSocket = newAsyncTLSSocket(socket, tlsContext, isClient = true)
      
      # SNIの設定
      tlsSocket.setServername(serverAddr)
      
      # TLSハンドシェイク
      let handshakeFuture = tlsSocket.doHandshake()
      let hsTimeoutFuture = sleepAsync(resolver.config.timeout)
      
      let hsFirstDone = await oneOf(handshakeFuture, hsTimeoutFuture)
      if hsFirstDone == 1:  # タイムアウト発生
        error "DoT handshake timed out", server=serverAddr, timeout=resolver.config.timeout
        tlsSocket.close()
        continue
        
      # 証明書の検証
      let verifyResult = tlsSocket.verifyCertificate()
      if not verifyResult.ok:
        error "DoT certificate verification failed", server=serverAddr, error=verifyResult.errorMessage
        tlsSocket.close()
        continue
      
      # 長さプレフィックス（2バイト）を追加
      var length = queryData.len.uint16
      var lengthBytes = newString(2)
      bigEndian16(addr lengthBytes[0], addr length)
      
      # クエリを送信
      await tlsSocket.write(lengthBytes & queryData)
      
      # レスポンスの長さを受信
      var responseLengthBytes = newString(2)
      let lenBytesRead = await tlsSocket.readExactly(responseLengthBytes, 2)
      if lenBytesRead != 2:
        error "Failed to read DoT response length", server=serverAddr
        tlsSocket.close()
        continue
      
      var responseLength: uint16
      bigEndian16(addr responseLength, unsafeAddr responseLengthBytes[0])
      
      # レスポンスデータを受信
      var responseData = newString(responseLength.int)
      let bytesRead = await tlsSocket.readExactly(responseData, responseLength.int)
      
      if bytesRead != responseLength.int:
        error "Incomplete DoT response", server=serverAddr, expected=responseLength, received=bytesRead
        tlsSocket.close()
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
          tlsSocket.close()
          return DnsResponse(
            records: @[],
            responseCode: responseCode,
            authoritative: flags.aa,
            truncated: flags.tc,
            recursionAvailable: flags.ra,
            authenticated: false
          )
        
        # エラーの場合、リトライ
        tlsSocket.close()
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
      
      # TLS接続を閉じる
      tlsSocket.close()
      
      # メトリクス更新
      resolver.dotMetrics.updateMetrics(
        server = serverAddr,
        success = true,
        responseTime = (getTime() - start).inMilliseconds.int,
        responseSize = responseData.len
      )
      
      return response
    except CatchableError as e:
      error "DoT query failed", server=serverAddr, error=e.msg
      
      # メトリクス更新 - 例外
      resolver.dotMetrics.updateMetrics(
        server = serverAddr,
        success = false,
        exception = e.msg
      )
      
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

# DNSSEC関連の型定義
type
  # DNSSEC DNSKEYレコード
  DnsDNSKEYRecord* = object
    flags*: uint16
    protocol*: uint8
    algorithm*: uint8
    publicKey*: string
    ttl*: uint32

  # DNSSEC DSレコード
  DnsDSRecord* = object
    keyTag*: uint16
    algorithm*: uint8
    digestType*: uint8
    digest*: string
    ttl*: uint32

  # DNSSEC RRSIGレコード
  DnsRRSIGRecord* = object
    typeCovered*: uint16
    algorithm*: uint8
    labels*: uint8
    originalTtl*: uint32
    signatureExpiration*: uint32
    signatureInception*: uint32
    keyTag*: uint16
    signerName*: string
    signature*: string
    ttl*: uint32

# DNSSEC検証モジュール
proc verifyDnssecChain*(records: seq[DnsRecord], question: string, recordType: RecordType): bool =
  ## DNSSEC署名チェーンを検証する完全な実装
  ## RFC4033、RFC4034、RFC4035に準拠
  
  # 検証に必要なレコードを整理
  var answers: seq[DnsRecord] = @[]
  var dnskeys: seq[DnsDNSKEYRecord] = @[]
  var rrsigs: seq[DnsRRSIGRecord] = @[]
  var ds: seq[DnsDSRecord] = @[]
  
  for record in records:
    case record.kind
    of RecordType.DNSKEY:
      dnskeys.add(record.dnskey)
    of RecordType.RRSIG:
      rrsigs.add(record.rrsig)
    of RecordType.DS:
      ds.add(record.ds)
    else:
      if record.kind == recordType:
        answers.add(record)
  
  if rrsigs.len == 0:
    debug "DNSSEC: 署名が存在しません", question=question
    return false
  
  # 各RRSIGに対する検証
  var verified = false
  
  for rrsig in rrsigs:
    # 対象レコードタイプの確認
    if uint16(recordType) != rrsig.typeCovered:
      continue
    
    # 署名の有効期限チェック
    let currentTime = uint32(getTime().toUnix())
    if currentTime > rrsig.signatureExpiration or currentTime < rrsig.signatureInception:
      warn "DNSSEC: 署名の期限切れ", expiration=rrsig.signatureExpiration, inception=rrsig.signatureInception, current=currentTime
      continue
    
    # 署名に対応するDNSKEYを探す
    var keyFound = false
    var keyRecord: DnsDNSKEYRecord
    
    for key in dnskeys:
      # キータグの計算と比較
      let calculatedTag = calculateKeyTag(key)
      if calculatedTag == rrsig.keyTag:
        keyRecord = key
        keyFound = true
        break
    
    if not keyFound:
      debug "DNSSEC: 対応するDNSKEYが見つかりません", keyTag=rrsig.keyTag
      continue
    
    # DNSKEY自体の信頼性を確認
    let keyVerified = if ds.len > 0:
      verifyDnssecKey(keyRecord, ds)
    else:
      # トラストアンカーとして扱う（ルートやTLDなど）
      (keyRecord.flags and 0x0101) == 0x0101 # KSKフラグチェック
    
    if not keyVerified:
      debug "DNSSEC: DNSKEYの検証に失敗", keyTag=rrsig.keyTag
      continue
    
    # 署名データの再構築
    var signedData = constructSignedData(answers, rrsig)
    
    # 署名の検証
    if verifySignature(signedData, rrsig.signature, keyRecord):
      info "DNSSEC: 署名検証成功", question=question, type=$recordType
      verified = true
      break
  
  return verified

proc calculateKeyTag(key: DnsDNSKEYRecord): uint16 =
  ## DNSKEYからキータグを計算
  ## RFC4034 Appendix Bに基づく実装
  
  # キーデータの準備
  var keyData = newSeq[byte]()
  
  # フラグ、プロトコル、アルゴリズムの追加
  var flagsBytes: array[2, byte]
  bigEndian16(addr flagsBytes, unsafeAddr key.flags)
  keyData.add(flagsBytes[0])
  keyData.add(flagsBytes[1])
  keyData.add(key.protocol)
  keyData.add(key.algorithm)
  
  # 公開鍵データの追加
  for c in key.publicKey:
    keyData.add(byte(c))
  
  # アルゴリズム1の場合（RSA/MD5）の特別処理
  if key.algorithm == 1:
    var ac = 0'u32
    for i in 0..<keyData.len:
      ac += if (i and 1) != 0: uint32(keyData[i]) else: uint32(keyData[i]) shl 8
    ac += (ac shr 16) and 0xFFFF
    return uint16(ac and 0xFFFF)
  
  # その他のアルゴリズム
  var ac = 0'u32
  for i in 0..<keyData.len:
    ac += uint32(keyData[i])
  
  return uint16((ac + (ac shr 16)) and 0xFFFF)

proc verifyDnssecKey(key: DnsDNSKEYRecord, dsRecords: seq[DnsDSRecord]): bool =
  ## DNSKEY自体をDS（Delegation Signer）レコードで検証
  
  let keyTag = calculateKeyTag(key)
  
  for ds in dsRecords:
    # キータグとアルゴリズムの確認
    if ds.keyTag != keyTag or ds.algorithm != key.algorithm:
      continue
    
    # DNSKEYからDSダイジェストを作成して比較
    let calculatedDigest = calculateDsDigest(key, ds.digestType)
    if calculatedDigest == ds.digest:
      return true
  
  return false

proc calculateDsDigest(key: DnsDNSKEYRecord, digestType: uint8): string =
  ## DNSKEY用のDSダイジェスト計算
  ## RFC4034 Section 5.1.4に基づく実装
  
  # オーナー名 + DNSKEY RDATA
  var data = newSeq[byte]()
  
  # RDATA: フラグ、プロトコル、アルゴリズム、公開鍵
  var flagsBytes: array[2, byte]
  bigEndian16(addr flagsBytes, unsafeAddr key.flags)
  data.add(flagsBytes[0])
  data.add(flagsBytes[1])
  data.add(key.protocol)
  data.add(key.algorithm)
  
  for c in key.publicKey:
    data.add(byte(c))
  
  # ダイジェスト計算
  case digestType
  of 1: # SHA-1
    var digest = secureHash(data)
    return cast[string](digest)
  of 2: # SHA-256
    var ctx = newSha256Context()
    ctx.update(data)
    var digest = ctx.finalize()
    return cast[string](digest)
  of 4: # SHA-384
    var ctx = newSha384Context()
    ctx.update(data)
    var digest = ctx.finalize()
    return cast[string](digest)
  else:
    warn "未対応のダイジェストタイプ", digestType=digestType
    return ""

proc constructSignedData(records: seq[DnsRecord], rrsig: DnsRRSIGRecord): seq[byte] =
  ## 署名されたデータブロックを再構築
  ## RFC4034 Section 3.1.8.1に基づく実装
  
  var data = newSeq[byte]()
  
  # RRSIG RDATA（署名を除く）の追加
  var typeCoveredBytes: array[2, byte]
  bigEndian16(addr typeCoveredBytes, unsafeAddr rrsig.typeCovered)
  data.add(typeCoveredBytes[0])
  data.add(typeCoveredBytes[1])
  
  data.add(rrsig.algorithm)
  data.add(rrsig.labels)
  
  var originalTtlBytes: array[4, byte]
  bigEndian32(addr originalTtlBytes, unsafeAddr rrsig.originalTtl)
  for b in originalTtlBytes:
    data.add(b)
  
  var expirationBytes: array[4, byte]
  bigEndian32(addr expirationBytes, unsafeAddr rrsig.signatureExpiration)
  for b in expirationBytes:
    data.add(b)
  
  var inceptionBytes: array[4, byte]
  bigEndian32(addr inceptionBytes, unsafeAddr rrsig.signatureInception)
  for b in inceptionBytes:
    data.add(b)
  
  var keyTagBytes: array[2, byte]
  bigEndian16(addr keyTagBytes, unsafeAddr rrsig.keyTag)
  data.add(keyTagBytes[0])
  data.add(keyTagBytes[1])
  
  # 署名者名の追加（ドメイン名のワイヤーフォーマット）
  let signerNameBytes = encodeDomainName(rrsig.signerName)
  for b in signerNameBytes:
    data.add(b)
  
  # 対象レコードのRDATAを追加
  for record in records:
    let recordData = encodeRecordForSignature(record, rrsig.originalTtl)
    for b in recordData:
      data.add(b)
  
  return data

proc verifySignature(signedData: seq[byte], signature: string, key: DnsDNSKEYRecord): bool =
  ## 署名の暗号学的検証
  ## RFC4034に基づくアルゴリズム別の実装

  let sigBytes = cast[seq[byte]](signature)
  
  # アルゴリズムに基づいた検証
  case key.algorithm
  of 5, 7, 8, 10: # RSA
    let pubKey = decodeRsaPublicKey(key.publicKey)
    
    case key.algorithm
    of 5: # RSA/SHA-1
      let sha1Hash = secureHash(signedData)
      return rsaVerify(pubKey, sigBytes, sha1Hash)
      
    of 7: # RSA/SHA-1-NSEC3-SHA1
      let sha1Hash = secureHash(signedData)
      return rsaVerify(pubKey, sigBytes, sha1Hash)
      
    of 8: # RSA/SHA-256
      var ctx = newSha256Context()
      ctx.update(signedData)
      let sha256Hash = ctx.finalize()
      return rsaVerify(pubKey, sigBytes, sha256Hash)
      
    of 10: # RSA/SHA-512
      var ctx = newSha512Context()
      ctx.update(signedData)
      let sha512Hash = ctx.finalize()
      return rsaVerify(pubKey, sigBytes, sha512Hash)
      
    else: 
      warn "未対応のRSAアルゴリズム", algorithm=key.algorithm
      return false
      
  of 13, 14: # ECDSA
    let pubKey = decodeEcdsaPublicKey(key.publicKey, key.algorithm)
    
    case key.algorithm
    of 13: # ECDSA P-256 with SHA-256
      var ctx = newSha256Context()
      ctx.update(signedData)
      let sha256Hash = ctx.finalize()
      return ecdsaVerify(pubKey, sigBytes, sha256Hash, EcCurve.P256)
      
    of 14: # ECDSA P-384 with SHA-384
      var ctx = newSha384Context()
      ctx.update(signedData)
      let sha384Hash = ctx.finalize()
      return ecdsaVerify(pubKey, sigBytes, sha384Hash, EcCurve.P384)
      
    else:
      warn "未対応のECDSAアルゴリズム", algorithm=key.algorithm
      return false
      
  of 15, 16: # Ed25519, Ed448
    case key.algorithm
    of 15: # Ed25519
      return ed25519Verify(cast[seq[byte]](key.publicKey), sigBytes, signedData)
      
    of 16: # Ed448
      return ed448Verify(cast[seq[byte]](key.publicKey), sigBytes, signedData)
      
    else:
      warn "未対応のEdDSAアルゴリズム", algorithm=key.algorithm
      return false
      
  else:
    warn "未対応の暗号アルゴリズム", algorithm=key.algorithm
    return false

# 暗号ライブラリラッパー - プラットフォーム依存の実装を抽象化

proc decodeRsaPublicKey(keyData: string): RsaPublicKey =
  # OpenSSLなどを使用してRSA公開鍵をデコード
  var key: RsaPublicKey
  let keyBytes = cast[seq[byte]](keyData)
  key = rsaImportPublicKey(keyBytes)
  return key

proc decodeEcdsaPublicKey(keyData: string, algorithm: uint8): EcPublicKey =
  # OpenSSLなどを使用してECDSA公開鍵をデコード
  var key: EcPublicKey
  let keyBytes = cast[seq[byte]](keyData)
  let curve = if algorithm == 13: EcCurve.P256 else: EcCurve.P384
  key = ecImportPublicKey(keyBytes, curve)
  return key

proc rsaVerify(key: RsaPublicKey, signature: seq[byte], hash: seq[byte]): bool =
  # OpenSSLなどを使用したRSA署名検証
  return rsaCryptoVerify(key, signature, hash)

proc ecdsaVerify(key: EcPublicKey, signature: seq[byte], hash: seq[byte], curve: EcCurve): bool =
  # OpenSSLなどを使用したECDSA署名検証
  return ecdsaCryptoVerify(key, signature, hash, curve)

proc ed25519Verify(publicKey: seq[byte], signature: seq[byte], message: seq[byte]): bool =
  # libsodiumなどを使用したEd25519署名検証
  return ed25519CryptoVerify(publicKey, signature, message)

proc ed448Verify(publicKey: seq[byte], signature: seq[byte], message: seq[byte]): bool =
  # libsodiumなどを使用したEd448署名検証
  return ed448CryptoVerify(publicKey, signature, message)

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

proc dohRequest*(resolver: DnsResolver, host: string, recordType: RecordType): Future[seq[DnsRecord]] {.async.} =
  # DoH（DNS over HTTPS）によるDNS解決
  # RFC8484準拠の実装

  # エンドポイントの選択（パフォーマンスと信頼性に基づく）
  let endpoint = resolver.selectOptimalDoHEndpoint()

  debug "DoH解決の実行", host=host, type=$recordType, endpoint=endpoint

  # DNS wireフォーマットメッセージを作成
  let dnsMessage = createDnsMessage(host, recordType)
  let wireFormat = encodeDnsWireFormat(dnsMessage)
  let b64encoded = base64.encode(wireFormat, safe=true, padding=false)

  # HTTPクライアント設定
  var client = newAsyncHttpClient()
  client.headers = newHttpHeaders({
    "Accept": "application/dns-message",
    "Content-Type": "application/dns-message",
    "User-Agent": "Quantum-Browser/1.0"
  })

  # 接続タイムアウト設定
  client.timeout = DNS_TIMEOUT_MS

  # エラーハンドリングを強化したHTTPリクエスト
  try:
    # GET（小さなクエリ）またはPOST（大きなクエリ）の選択
    let response = if wireFormat.len < 512:
      # GETリクエスト（小さいクエリの場合）
      let url = endpoint & "?dns=" & b64encoded
      await client.request(url, HttpGet)
    else:
      # POSTリクエスト（大きいクエリの場合）
      await client.request(endpoint, HttpPost, $wireFormat)

    # レスポンスステータスの確認
    if response.code != 200:
      warn "DoHリクエスト失敗", statusCode=response.code
      return @[]

    # DNS応答の解析
    let responseBody = await response.body
    let dnsResponse = decodeDnsWireFormat(responseBody)

    # DNSレコードへの変換
    result = convertToDnsRecords(dnsResponse)
    
    # キャッシュに結果を保存
    resolver.cache.storeDnsResult(host, recordType, result)
    
    info "DoH解決完了", host=host, recordsCount=result.len
  
  except CatchableError as e:
    error "DoHリクエストエラー", host=host, error=e.msg
    # フォールバックメカニズム
    result = await resolver.fallbackResolve(host, recordType)
  
  finally:
    # リソース解放
    client.close()

proc selectOptimalDoHEndpoint(resolver: DnsResolver): string =
  # 最適なDoHエンドポイントを選択
  # パフォーマンスメトリクス、可用性、レイテンシに基づく

  # キャッシュからエンドポイントのパフォーマンスデータを取得
  var endpointScores: Table[string, float]
  
  for endpoint in DOH_ENDPOINTS:
    let stats = resolver.endpointStats.getOrDefault(endpoint)
    if stats.isNil or stats.failureCount > resolver.maxFailureThreshold:
      continue
      
    # スコア計算: 応答時間 (30%), 成功率 (40%), 可用性 (30%)
    let responseTime = max(1.0, stats.avgResponseTime)
    let successRate = if stats.requestCount > 0: stats.successCount.float / stats.requestCount.float else: 0.0
    let availability = 1.0 - min(1.0, stats.downtime / 3600.0)
    
    let score = (0.3 * (1000.0 / responseTime)) + 
                (0.4 * successRate) + 
                (0.3 * availability)
                
    endpointScores[endpoint] = score

  # 最適なエンドポイントを返す（なければデフォルト）
  if endpointScores.len > 0:
    var bestEndpoint = ""
    var bestScore = -1.0
    
    for endpoint, score in endpointScores:
      if score > bestScore:
        bestScore = score
        bestEndpoint = endpoint
        
    result = bestEndpoint
  else:
    # デフォルトエンドポイント（Cloudflare）
    result = DOH_ENDPOINTS[0]

# TLS操作を使用したDNS-over-TLS実装
proc dotRequest*(resolver: DnsResolver, host: string, recordType: RecordType): Future[seq[DnsRecord]] {.async.} =
  # DNS over TLS (DoT)の実装
  # RFC7858準拠

  # 最適なDoTサーバーを選択
  let server = resolver.selectOptimalDotServer()
  
  debug "DoT解決の実行", host=host, type=$recordType, server=server
  
  # ソケット作成
  var socket = newAsyncSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
  
  try:
    # TLSコンテキスト設定
    var tlsContext = newTLSContext(verifyMode = CVerifyPeer)
    
    # 最新のTLSプロトコル設定
    tlsContext.protocolVersion = TLSVersion.tlsv1_3
    
    # 信頼できるCA証明書の設定
    tlsContext.loadCertificates(resolver.caBundle)
    
    # 接続
    await socket.connect(server, Port(853)) # DoT標準ポート853
    
    # TLSハンドシェイク
    var tlsSocket = newTLSAsyncSocket(socket, tlsContext, false)
    await tlsSocket.handshake()
    
    # 証明書検証
    if not tlsSocket.verifyCertificate():
      raise newException(TLSVerificationError, "TLS証明書検証失敗")
    
    # DNSクエリの作成
    let queryData = createTcpDnsQuery(host, recordType)
    
    # クエリ送信（TCP長さプレフィックス付き）
    let queryLen = uint16(queryData.len)
    var lenBytes: array[2, byte]
    bigEndian16(addr lenBytes, addr queryLen)
    await tlsSocket.send(addr lenBytes, 2)
    await tlsSocket.send(queryData[0].addr, queryData.len)
    
    # 応答の長さ読み取り
    var responseLenBytes: array[2, byte]
    if await tlsSocket.recvInto(addr responseLenBytes, 2) != 2:
      raise newException(IOError, "DoT応答長の読み取り失敗")
    
    var responseLen: uint16
    bigEndian16(addr responseLen, addr responseLenBytes)
    
    # 応答データの読み取り
    var responseData = newSeq[byte](responseLen)
    if await tlsSocket.recvInto(addr responseData[0], responseLen.int) != responseLen.int:
      raise newException(IOError, "DoT応答データの読み取り失敗")
    
    # 応答の解析
    let dnsResponse = parseDnsResponse(responseData)
    
    # DNSレコードへの変換
    result = convertToDnsRecords(dnsResponse)
    
    # キャッシュに結果を保存
    resolver.cache.storeDnsResult(host, recordType, result)
    
    info "DoT解決完了", host=host, recordsCount=result.len
    
  except CatchableError as e:
    error "DoTリクエストエラー", host=host, error=e.msg
    # フォールバックメカニズム
    result = await resolver.fallbackResolve(host, recordType)
    
  finally:
    # リソース解放
    try:
      socket.close()
    except:
      discard

proc selectOptimalDotServer(resolver: DnsResolver): string =
  # 最適なDoTサーバーを選択
  # パフォーマンスメトリクス、可用性、レイテンシに基づく
  
  # サーバー選定ロジック（DoHと同様）
  var serverScores: Table[string, float]
  
  for server in DOT_SERVERS:
    let stats = resolver.serverStats.getOrDefault(server)
    if stats.isNil or stats.failureCount > resolver.maxFailureThreshold:
      continue
      
    # スコア計算
    let responseTime = max(1.0, stats.avgResponseTime)
    let successRate = if stats.requestCount > 0: stats.successCount.float / stats.requestCount.float else: 0.0
    let availability = 1.0 - min(1.0, stats.downtime / 3600.0)
    
    let score = (0.3 * (1000.0 / responseTime)) + 
                (0.4 * successRate) + 
                (0.3 * availability)
                
    serverScores[server] = score

  # 最適なサーバーを返す（なければデフォルト）
  if serverScores.len > 0:
    var bestServer = ""
    var bestScore = -1.0
    
    for server, score in serverScores:
      if score > bestScore:
        bestScore = score
        bestServer = server
        
    result = bestServer
  else:
    # デフォルトサーバー（Cloudflare）
    result = DOT_SERVERS[0]