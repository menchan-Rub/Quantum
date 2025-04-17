import std/[strutils, times, json, net, tables, hashes]

type
  DnsRecordType* = enum
    ## DNSレコードタイプ
    A = 1          # IPv4アドレス
    NS = 2         # ネームサーバー
    CNAME = 5      # 正規名
    SOA = 6        # 権威の開始
    PTR = 12       # ポインタ
    MX = 15        # メール交換
    TXT = 16       # テキスト
    AAAA = 28      # IPv6アドレス
    SRV = 33       # サービスロケーション
    CERT = 37      # 証明書
    DNSKEY = 48    # DNS公開鍵
    TLSA = 52      # TLS証明書関連情報
    SSHFP = 44     # SSH公開鍵フィンガープリント
    CAA = 257      # 認証局承認

  MxRecord* = object
    preference*: uint16  # 優先度
    exchange*: string    # メールサーバーのホスト名

  SrvRecord* = object
    priority*: uint16    # 優先度
    weight*: uint16      # 重み
    port*: uint16        # ポート番号
    target*: string      # ターゲットホスト名

  SoaRecord* = object
    mname*: string       # プライマリネームサーバー
    rname*: string       # 責任者のメールアドレス
    serial*: uint32      # シリアル番号
    refresh*: uint32     # リフレッシュ間隔
    retry*: uint32       # リトライ間隔
    expire*: uint32      # 有効期限
    minimum*: uint32     # 最小TTL

  DnsSecurityKey* = object
    flags*: uint16       # フラグ
    protocol*: uint8     # プロトコル
    algorithm*: uint8    # アルゴリズム
    publicKey*: string   # 公開鍵

  DnsRecord* = object
    ## DNSレコード
    domain*: string            # ドメイン名
    recordType*: DnsRecordType # レコードタイプ
    ttl*: int                  # 有効期間（秒）
    data*: string              # レコードデータ
    timestamp*: Time           # 作成時刻

  DnsResponseCode* = enum
    ## DNSレスポンスコード
    NoError = 0        # エラーなし
    FormatError = 1    # クエリのフォーマットエラー
    ServerFailure = 2  # サーバー障害
    NameError = 3      # 存在しないドメイン (NXDOMAIN)
    NotImplemented = 4 # クエリタイプがサポートされていない
    Refused = 5        # クエリの実行を拒否

proc hash*(record: DnsRecord): Hash =
  ## DNSレコードのハッシュ関数
  var h: Hash = 0
  h = h !& hash(record.domain)
  h = h !& hash(ord(record.recordType))
  
  case record.recordType:
  of A:
    h = h !& hash($record.data)
  of AAAA:
    h = h !& hash($record.data)
  of CNAME, NS, PTR:
    h = h !& hash(record.data)
  of MX:
    h = h !& hash($record.data)
  of SRV:
    h = h !& hash($record.data)
  of TXT:
    h = h !& hash(record.data)
  of SOA:
    h = h !& hash($record.data)
  of DNSKEY:
    h = h !& hash(record.data)
  of CERT, TLSA, SSHFP, CAA:
    h = h !& hash(record.data)
  
  result = !$h

proc `==`*(a, b: DnsRecord): bool =
  ## DNSレコードの等価性比較
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  
  if a.domain != b.domain or a.recordType != b.recordType:
    return false
  
  case a.recordType:
  of A:
    return a.data == b.data
  of AAAA:
    return a.data == b.data
  of CNAME, NS, PTR:
    return a.data == b.data
  of MX:
    return a.data == b.data
  of SRV:
    return a.data == b.data
  of TXT:
    return a.data == b.data
  of SOA:
    return a.data == b.data
  of DNSKEY:
    return a.data == b.data
  of CERT, TLSA, SSHFP, CAA:
    return a.data == b.data

proc newDnsRecord*(name: string, recordType: DnsRecordType, ttl: int): DnsRecord =
  ## 新しいDNSレコードを作成
  result = DnsRecord(
    domain: name, 
    recordType: recordType, 
    ttl: ttl,
    data: "",
    timestamp: getTime()
  )

proc newARecord*(name: string, ipv4: IpAddress, ttl: int): DnsRecord =
  ## 新しいAレコードを作成
  result = newDnsRecord(name, A, ttl)
  result.data = $ipv4

proc newAAAARecord*(name: string, ipv6: IpAddress, ttl: int): DnsRecord =
  ## 新しいAAAAレコードを作成
  result = newDnsRecord(name, AAAA, ttl)
  result.data = $ipv6

proc newCNAMERecord*(name: string, target: string, ttl: int): DnsRecord =
  ## 新しいCNAMEレコードを作成
  result = newDnsRecord(name, CNAME, ttl)
  result.data = target

proc newNSRecord*(name: string, target: string, ttl: int): DnsRecord =
  ## 新しいNSレコードを作成
  result = newDnsRecord(name, NS, ttl)
  result.data = target

proc newPTRRecord*(name: string, target: string, ttl: int): DnsRecord =
  ## 新しいPTRレコードを作成
  result = newDnsRecord(name, PTR, ttl)
  result.data = target

proc newMXRecord*(name: string, mxRecords: seq[MxRecord], ttl: int): DnsRecord =
  ## 新しいMXレコードを作成
  result = newDnsRecord(name, MX, ttl)
  result.data = $mxRecords

proc newSRVRecord*(name: string, srvRecords: seq[SrvRecord], ttl: int): DnsRecord =
  ## 新しいSRVレコードを作成
  result = newDnsRecord(name, SRV, ttl)
  result.data = $srvRecords

proc newTXTRecord*(name: string, txtData: seq[string], ttl: int): DnsRecord =
  ## 新しいTXTレコードを作成
  result = newDnsRecord(name, TXT, ttl)
  result.data = txtData.join(", ")

proc newSOARecord*(name: string, soaRecord: SoaRecord, ttl: int): DnsRecord =
  ## 新しいSOAレコードを作成
  result = newDnsRecord(name, SOA, ttl)
  result.data = $soaRecord

proc isExpired*(record: DnsRecord): bool =
  ## レコードが期限切れかどうかを確認
  let now = getTime()
  let age = now - record.timestamp
  return age.inSeconds >= record.ttl

proc timeToLive*(record: DnsRecord): int =
  ## レコードの残りTTLを計算
  let now = getTime()
  let age = now - record.timestamp
  let remaining = record.ttl - age.inSeconds.int
proc remainingTtl*(record: DnsRecord): int =
  ## レコードの残りTTLを秒単位で取得
  let remaining = record.expiresAt - getTime()
  if remaining.inSeconds < 0:
    return 0
  return remaining.inSeconds.int

proc toJson*(record: DnsRecord): JsonNode =
  ## DNSレコードをJSON形式に変換
  result = newJObject()
  result["name"] = %record.name
  result["type"] = %($record.recordType)
  result["ttl"] = %record.ttl
  result["expiresAt"] = %record.expiresAt.toUnix()
  
  case record.recordType:
  of A:
    result["ipv4"] = %($record.ipv4)
  of AAAA:
    result["ipv6"] = %($record.ipv6)
  of CNAME, NS, PTR:
    result["target"] = %record.target
  of MX:
    var mxArray = newJArray()
    for mx in record.mxRecords:
      var mxObj = newJObject()
      mxObj["preference"] = %mx.preference
      mxObj["exchange"] = %mx.exchange
      mxArray.add(mxObj)
    result["mxRecords"] = mxArray
  of SRV:
    var srvArray = newJArray()
    for srv in record.srvRecords:
      var srvObj = newJObject()
      srvObj["priority"] = %srv.priority
      srvObj["weight"] = %srv.weight
      srvObj["port"] = %srv.port
      srvObj["target"] = %srv.target
      srvArray.add(srvObj)
    result["srvRecords"] = srvArray
  of TXT:
    var txtArray = newJArray()
    for txt in record.txtData:
      txtArray.add(%txt)
    result["txtData"] = txtArray
  of SOA:
    var soaObj = newJObject()
    soaObj["mname"] = %record.soaRecord.mname
    soaObj["rname"] = %record.soaRecord.rname
    soaObj["serial"] = %record.soaRecord.serial
    soaObj["refresh"] = %record.soaRecord.refresh
    soaObj["retry"] = %record.soaRecord.retry
    soaObj["expire"] = %record.soaRecord.expire
    soaObj["minimum"] = %record.soaRecord.minimum
    result["soaRecord"] = soaObj
  of DNSKEY:
    var keyObj = newJObject()
    keyObj["flags"] = %record.dnsKey.flags
    keyObj["protocol"] = %record.dnsKey.protocol
    keyObj["algorithm"] = %record.dnsKey.algorithm
    keyObj["publicKey"] = %record.dnsKey.publicKey
    result["dnsKey"] = keyObj
  of DS, RRSIG, NSEC, NSEC3, NSEC3PARAM, CAA, TLSA, ANY:
    result["rawData"] = %record.rawData

proc fromJson*(jsonNode: JsonNode): DnsRecord =
  ## JSON形式からDNSレコードを生成
  let name = jsonNode["name"].getStr()
  let recordTypeStr = jsonNode["type"].getStr()
  let ttl = jsonNode["ttl"].getInt().uint32
  let recordType = parseEnum[DnsRecordType](recordTypeStr)
  let expiresAt = fromUnix(jsonNode["expiresAt"].getInt())
  
  result = newDnsRecord(name, recordType, ttl)
  result.expiresAt = expiresAt
  
  case recordType:
  of A:
    result.ipv4 = parseIpAddress(jsonNode["ipv4"].getStr())
  of AAAA:
    result.ipv6 = parseIpAddress(jsonNode["ipv6"].getStr())
  of CNAME, NS, PTR:
    result.target = jsonNode["target"].getStr()
  of MX:
    var mxRecords: seq[MxRecord]
    for mxNode in jsonNode["mxRecords"]:
      mxRecords.add(MxRecord(
        preference: mxNode["preference"].getInt().uint16,
        exchange: mxNode["exchange"].getStr()
      ))
    result.mxRecords = mxRecords
  of SRV:
    var srvRecords: seq[SrvRecord]
    for srvNode in jsonNode["srvRecords"]:
      srvRecords.add(SrvRecord(
        priority: srvNode["priority"].getInt().uint16,
        weight: srvNode["weight"].getInt().uint16,
        port: srvNode["port"].getInt().uint16,
        target: srvNode["target"].getStr()
      ))
    result.srvRecords = srvRecords
  of TXT:
    var txtData: seq[string]
    for txtNode in jsonNode["txtData"]:
      txtData.add(txtNode.getStr())
    result.txtData = txtData
  of SOA:
    let soaNode = jsonNode["soaRecord"]
    result.soaRecord = SoaRecord(
      mname: soaNode["mname"].getStr(),
      rname: soaNode["rname"].getStr(),
      serial: soaNode["serial"].getInt().uint32,
      refresh: soaNode["refresh"].getInt().uint32,
      retry: soaNode["retry"].getInt().uint32,
      expire: soaNode["expire"].getInt().uint32,
      minimum: soaNode["minimum"].getInt().uint32
    )
  of DNSKEY:
    let keyNode = jsonNode["dnsKey"]
    result.dnsKey = DnsSecurityKey(
      flags: keyNode["flags"].getInt().uint16,
      protocol: keyNode["protocol"].getInt().uint8,
      algorithm: keyNode["algorithm"].getInt().uint8,
      publicKey: keyNode["publicKey"].getStr()
    )
  of DS, RRSIG, NSEC, NSEC3, NSEC3PARAM, CAA, TLSA, ANY:
    result.rawData = jsonNode["rawData"].getStr()

proc `$`*(record: DnsRecord): string =
  ## DNSレコードの文字列表現
  var details = ""
  case record.recordType:
  of A:
    details = $record.ipv4
  of AAAA:
    details = $record.ipv6
  of CNAME, NS, PTR:
    details = record.target
  of MX:
    details = "["
    for i, mx in record.mxRecords:
      if i > 0: details &= ", "
      details &= $mx.preference & " " & mx.exchange
    details &= "]"
  of SRV:
    details = "["
    for i, srv in record.srvRecords:
      if i > 0: details &= ", "
      details &= $srv.priority & " " & $srv.weight & " " & $srv.port & " " & srv.target
    details &= "]"
  of TXT:
    details = "["
    for i, txt in record.txtData:
      if i > 0: details &= ", "
      details &= "\"" & txt & "\""
    details &= "]"
  of SOA:
    let soa = record.soaRecord
    details = soa.mname & " " & soa.rname & " " & $soa.serial
  of DNSKEY:
    details = $record.dnsKey.flags & " " & $record.dnsKey.protocol & " " & $record.dnsKey.algorithm
  of DS, RRSIG, NSEC, NSEC3, NSEC3PARAM, CAA, TLSA, ANY:
    details = record.rawData
  
  result = record.name & " " & $record.ttl & " " & $record.recordType & " " & details

proc recordTypeToInt*(recordType: DnsRecordType): uint16 =
  ## レコードタイプを数値に変換
  case recordType
  of A: 1'u16
  of NS: 2'u16
  of CNAME: 5'u16
  of SOA: 6'u16
  of PTR: 12'u16
  of MX: 15'u16
  of TXT: 16'u16
  of AAAA: 28'u16
  of SRV: 33'u16
  of DS: 43'u16
  of RRSIG: 46'u16
  of DNSKEY: 48'u16
  of CAA: 257'u16

proc intToRecordType*(value: uint16): DnsRecordType =
  ## 数値からレコードタイプに変換
  case value
  of 1'u16: A
  of 2'u16: NS
  of 5'u16: CNAME
  of 6'u16: SOA
  of 12'u16: PTR
  of 15'u16: MX
  of 16'u16: TXT
  of 28'u16: AAAA
  of 33'u16: SRV
  of 43'u16: DS
  of 46'u16: RRSIG
  of 48'u16: DNSKEY
  of 257'u16: CAA
  else: A  # デフォルトはA

proc dataToString*(record: DnsRecord): string =
  ## レコードデータを人間可読な文字列に変換
  case record.recordType
  of A, AAAA:
    result = record.rawData  # IPアドレス
  of CNAME, NS, PTR:
    result = record.target  # ドメイン名
  of MX:
    result = record.rawData  # "優先度 ドメイン名"
  of TXT:
    result = "\"" & record.txtData[0] & "\""  # 引用符付きテキスト
  of SOA:
    # SOAレコードのフォーマット: "プライマリNS 管理者メール シリアル更新間隔 再試行間隔 期限切れ最小TTL"
    result = record.rawData
  of SRV:
    # SRVレコードのフォーマット: "優先度 重み ポート ターゲット"
    result = record.rawData
  of CAA:
    # CAAレコードのフォーマット: "フラグ タグ 値"
    result = record.rawData
  of DNSKEY, DS, RRSIG:
    # DNSSEC関連レコードは技術的な詳細を含む
    result = record.rawData
</rewritten_file> 