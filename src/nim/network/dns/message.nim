import std/[endians, strutils, net, options, times, random]
import records

const
  DNS_PACKET_MAX_SIZE* = 4096  # 最大パケットサイズ
  DNS_HEADER_SIZE* = 12        # ヘッダーサイズ（バイト）
  DNS_CLASS_IN* = 1            # インターネットクラス
  DNS_MAX_LABEL_LENGTH* = 63   # ドメイン名ラベルの最大長
  DNS_MAX_NAME_LENGTH* = 255   # ドメイン名の最大長
  DNS_POINTER_MASK* = 0xC0     # ドメイン名圧縮ポインタのマスク
  DNS_EDNS0_OPT* = 41          # EDNS0 OPTレコードタイプ

type
  DnsHeaderFlags* = object
    qr*: bool           # Query/Response: 0=クエリ, 1=レスポンス
    opcode*: uint8      # 操作コード: 0=標準クエリ, 1=逆引きクエリ, 2=サーバーステータスリクエスト
    aa*: bool           # Authoritative Answer: 権威応答
    tc*: bool           # Truncation: 応答が切り詰められたか
    rd*: bool           # Recursion Desired: 再帰的クエリが必要か
    ra*: bool           # Recursion Available: 再帰的クエリをサポートするか
    z*: uint8           # 予約済み
    ad*: bool           # Authenticated Data: DNSSEC
    cd*: bool           # Checking Disabled: DNSSEC
    rcode*: uint8       # レスポンスコード

  DnsHeader* = object
    id*: uint16           # 識別子
    flags*: DnsHeaderFlags  # フラグ
    qdcount*: uint16      # クエリ数
    ancount*: uint16      # 回答数
    nscount*: uint16      # 権威ネームサーバー数
    arcount*: uint16      # 追加レコード数

  DnsQuestion* = object
    name*: string          # クエリ名（ドメイン）
    qtype*: DnsRecordType  # クエリタイプ
    qclass*: uint16        # クエリクラス

  DnsResourceRecord* = object
    name*: string          # レコード名
    rrtype*: DnsRecordType # レコードタイプ
    rrclass*: uint16       # レコードクラス
    ttl*: uint32           # 有効期間
    rdlength*: uint16      # リソースデータ長
    rdata*: seq[byte]      # リソースデータ

  DnsMessage* = object
    header*: DnsHeader
    questions*: seq[DnsQuestion]
    answers*: seq[DnsResourceRecord]
    authorities*: seq[DnsResourceRecord]
    additionals*: seq[DnsResourceRecord]

  DnsLabel* = object
    offset*: int   # ラベルの開始位置
    length*: int   # ラベルの長さ
    isPointer*: bool  # 圧縮ポインタか
    pointerOffset*: int  # ポインタの場合のオフセット

  DnsParseContext* = object
    data*: seq[byte]       # パース対象のデータ
    labels*: seq[DnsLabel] # パース済みラベル
    maxJump*: int          # 最大ジャンプ数（無限ループ防止）

# 一般的なユーティリティ関数
proc newDnsHeader*(): DnsHeader =
  ## 新しいDNSヘッダーを作成
  result.id = uint16(rand(65535))
  result.flags.qr = false
  result.flags.opcode = 0
  result.flags.aa = false
  result.flags.tc = false
  result.flags.rd = true
  result.flags.ra = false
  result.flags.z = 0
  result.flags.ad = false
  result.flags.cd = false
  result.flags.rcode = 0
  result.qdcount = 0
  result.ancount = 0
  result.nscount = 0
  result.arcount = 0

proc newDnsMessage*(): DnsMessage =
  ## 新しいDNSメッセージを作成
  result.header = newDnsHeader()
  result.questions = @[]
  result.answers = @[]
  result.authorities = @[]
  result.additionals = @[]

# フラグ操作
proc encodeFlags*(flags: DnsHeaderFlags): uint16 =
  ## ヘッダーフラグを16ビット値にエンコード
  var value: uint16 = 0
  if flags.qr: value = value or (1'u16 shl 15)
  value = value or ((uint16(flags.opcode) and 0x0F'u16) shl 11)
  if flags.aa: value = value or (1'u16 shl 10)
  if flags.tc: value = value or (1'u16 shl 9)
  if flags.rd: value = value or (1'u16 shl 8)
  if flags.ra: value = value or (1'u16 shl 7)
  value = value or ((uint16(flags.z) and 0x01'u16) shl 6)
  if flags.ad: value = value or (1'u16 shl 5)
  if flags.cd: value = value or (1'u16 shl 4)
  value = value or (uint16(flags.rcode) and 0x0F'u16)
  return value

proc decodeFlags*(value: uint16): DnsHeaderFlags =
  ## 16ビット値からヘッダーフラグをデコード
  result.qr = (value and (1'u16 shl 15)) != 0
  result.opcode = uint8((value shr 11) and 0x0F'u16)
  result.aa = (value and (1'u16 shl 10)) != 0
  result.tc = (value and (1'u16 shl 9)) != 0
  result.rd = (value and (1'u16 shl 8)) != 0
  result.ra = (value and (1'u16 shl 7)) != 0
  result.z = uint8((value shr 6) and 0x01'u16)
  result.ad = (value and (1'u16 shl 5)) != 0
  result.cd = (value and (1'u16 shl 4)) != 0
  result.rcode = uint8(value and 0x0F'u16)

# ドメイン名エンコード/デコード
proc encodeDomainName*(domain: string): seq[byte] =
  ## ドメイン名をDNSワイヤーフォーマットにエンコード
  result = @[]
  
  if domain.len == 0:
    # ルートドメインの場合
    result.add(0'u8)
    return
  
  var name = domain
  if name.endsWith('.'):
    name = name[0..^2]  # 末尾のドットを削除
  
  let labels = name.split('.')
  for label in labels:
    if label.len > DNS_MAX_LABEL_LENGTH:
      raise newException(ValueError, "ドメイン名ラベルが長すぎます: " & label)
    
    result.add(uint8(label.len))
    for c in label:
      result.add(uint8(c))
  
  # 末尾のNULLラベル
  result.add(0'u8)

proc decodeDomainName*(data: seq[byte], offset: var int, ctx: var DnsParseContext): string =
  ## DNSワイヤーフォーマットからドメイン名をデコード
  ## offsetは入力/出力パラメータで、デコード後に更新される
  result = ""
  var currentOffset = offset
  var jumps = 0
  var firstJump = -1
  
  while true:
    # 境界チェック
    if currentOffset >= data.len:
      raise newException(ValueError, "不正なドメイン名: データ境界外")
    
    let labelLength = data[currentOffset]
    
    # 終端ラベル
    if labelLength == 0:
      currentOffset += 1
      break
    
    # 圧縮ポインタ
    if (labelLength and uint8(DNS_POINTER_MASK)) == uint8(DNS_POINTER_MASK):
      if currentOffset + 1 >= data.len:
        raise newException(ValueError, "不正な圧縮ポインタ: データ境界外")
      
      if firstJump == -1:
        firstJump = currentOffset
      
      inc(jumps)
      if jumps > ctx.maxJump:
        raise newException(ValueError, "圧縮ポインタの循環参照: " & $jumps)
      
      # ポインタ値の計算
      let pointerHigh = (labelLength and 0x3F'u8).int shl 8
      let pointerLow = data[currentOffset + 1].int
      currentOffset = pointerHigh or pointerLow
      continue
    
    # 通常のラベル
    if labelLength > DNS_MAX_LABEL_LENGTH:
      raise newException(ValueError, "ラベルが長すぎます: " & $labelLength.int)
    
    currentOffset += 1
    
    # ラベルデータの境界チェック
    if currentOffset + labelLength.int > data.len:
      raise newException(ValueError, "不正なラベル: データ境界外")
    
    # ラベルを追加
    if result.len > 0:
      result.add(".")
    
    for i in 0..<labelLength.int:
      result.add(char(data[currentOffset]))
      currentOffset += 1
  
  # オフセットの更新（ポインタにジャンプした場合は元のポインタ位置の次）
  if firstJump != -1:
    offset = firstJump + 2
  else:
    offset = currentOffset

# メッセージエンコード/デコード
proc encodeHeader*(header: DnsHeader): seq[byte] =
  ## DNSヘッダーをエンコード
  result = newSeq[byte](DNS_HEADER_SIZE)
  
  # ID
  var id = header.id
  bigEndian16(addr result[0], addr id)
  
  # フラグ
  var flags = encodeFlags(header.flags)
  bigEndian16(addr result[2], addr flags)
  
  # その他のカウンタ
  var qdcount = header.qdcount
  bigEndian16(addr result[4], addr qdcount)
  
  var ancount = header.ancount
  bigEndian16(addr result[6], addr ancount)
  
  var nscount = header.nscount
  bigEndian16(addr result[8], addr nscount)
  
  var arcount = header.arcount
  bigEndian16(addr result[10], addr arcount)

proc decodeHeader*(data: seq[byte]): tuple[header: DnsHeader, bytesRead: int] =
  ## DNSヘッダーをデコード
  if data.len < DNS_HEADER_SIZE:
    raise newException(ValueError, "ヘッダーデータが不足しています")
  
  var header: DnsHeader
  
  # ID
  var id: uint16
  bigEndian16(addr id, unsafeAddr data[0])
  header.id = id
  
  # フラグ
  var flags: uint16
  bigEndian16(addr flags, unsafeAddr data[2])
  header.flags = decodeFlags(flags)
  
  # その他のカウンタ
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
  
  return (header, DNS_HEADER_SIZE)

proc encodeQuestion*(question: DnsQuestion): seq[byte] =
  ## DNSクエリをエンコード
  # ドメイン名のエンコード
  result = encodeDomainName(question.name)
  
  # タイプ
  let qtype = uint16(question.qtype)
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], unsafeAddr qtype)
  
  # クラス
  var qclass = question.qclass
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], unsafeAddr qclass)

proc decodeQuestion*(data: seq[byte], offset: var int): tuple[question: DnsQuestion, bytesRead: int] =
  ## DNSクエリをデコード
  let startOffset = offset
  var ctx = DnsParseContext(data: data, maxJump: 10)
  
  # 名前のデコード
  let name = decodeDomainName(data, offset, ctx)
  
  # タイプとクラスのバウンドチェック
  if offset + 4 > data.len:
    raise newException(ValueError, "クエリデータが不足しています")
  
  # タイプ
  var qtype: uint16
  bigEndian16(addr qtype, unsafeAddr data[offset])
  offset += 2
  
  # クラス
  var qclass: uint16
  bigEndian16(addr qclass, unsafeAddr data[offset])
  offset += 2
  
  # クエリオブジェクト作成
  var question = DnsQuestion(
    name: name,
    qtype: intToRecordType(qtype),
    qclass: qclass
  )
  
  return (question, offset - startOffset)

proc encodeResourceRecord*(rr: DnsResourceRecord): seq[byte] =
  ## リソースレコードをエンコード
  # 名前のエンコード
  result = encodeDomainName(rr.name)
  
  # タイプ
  var rrtype = uint16(rr.rrtype)
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], unsafeAddr rrtype)
  
  # クラス
  var rrclass = rr.rrclass
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], unsafeAddr rrclass)
  
  # TTL
  var ttl = rr.ttl
  result.setLen(result.len + 4)
  bigEndian32(addr result[result.len - 4], unsafeAddr ttl)
  
  # データ長
  var rdlength = uint16(rr.rdata.len)
  result.setLen(result.len + 2)
  bigEndian16(addr result[result.len - 2], unsafeAddr rdlength)
  
  # リソースデータ
  result.add(rr.rdata)

proc decodeResourceRecord*(data: seq[byte], offset: var int): tuple[rr: DnsResourceRecord, bytesRead: int] =
  ## リソースレコードをデコード
  let startOffset = offset
  var ctx = DnsParseContext(data: data, maxJump: 10)
  
  # 名前のデコード
  let name = decodeDomainName(data, offset, ctx)
  
  # タイプ、クラス、TTL、データ長のバウンドチェック
  if offset + 10 > data.len:
    raise newException(ValueError, "リソースレコードデータが不足しています")
  
  # タイプ
  var rrtype: uint16
  bigEndian16(addr rrtype, unsafeAddr data[offset])
  offset += 2
  
  # クラス
  var rrclass: uint16
  bigEndian16(addr rrclass, unsafeAddr data[offset])
  offset += 2
  
  # TTL
  var ttl: uint32
  bigEndian32(addr ttl, unsafeAddr data[offset])
  offset += 4
  
  # データ長
  var rdlength: uint16
  bigEndian16(addr rdlength, unsafeAddr data[offset])
  offset += 2
  
  # リソースデータのバウンドチェック
  if offset + rdlength.int > data.len:
    raise newException(ValueError, "リソースデータが不足しています")
  
  # リソースデータ
  var rdata = newSeq[byte](rdlength.int)
  if rdlength > 0:
    for i in 0..<rdlength.int:
      rdata[i] = data[offset + i]
  offset += rdlength.int
  
  # リソースレコードオブジェクト作成
  var rr = DnsResourceRecord(
    name: name,
    rrtype: intToRecordType(rrtype),
    rrclass: rrclass,
    ttl: ttl,
    rdlength: rdlength,
    rdata: rdata
  )
  
  return (rr, offset - startOffset)

# メッセージレベルエンコード/デコード
proc encodeDnsMessage*(msg: DnsMessage): seq[byte] =
  ## DNSメッセージを完全にエンコード
  # ヘッダーのエンコード
  result = encodeHeader(msg.header)
  
  # クエリのエンコード
  for question in msg.questions:
    result.add(encodeQuestion(question))
  
  # 回答、権威、追加セクションのエンコード
  for answer in msg.answers:
    result.add(encodeResourceRecord(answer))
  
  for auth in msg.authorities:
    result.add(encodeResourceRecord(auth))
  
  for additional in msg.additionals:
    result.add(encodeResourceRecord(additional))

proc decodeDnsMessage*(data: seq[byte]): DnsMessage =
  ## DNSメッセージを完全にデコード
  var offset = 0
  var msg = newDnsMessage()
  
  # ヘッダーのデコード
  let (header, headerBytes) = decodeHeader(data)
  msg.header = header
  offset += headerBytes
  
  # クエリのデコード
  for i in 0..<header.qdcount.int:
    try:
      let (question, bytesRead) = decodeQuestion(data, offset)
      msg.questions.add(question)
    except:
      let e = getCurrentException()
      echo "クエリのデコードに失敗: ", e.msg
      break
  
  # 回答セクションのデコード
  for i in 0..<header.ancount.int:
    try:
      let (answer, bytesRead) = decodeResourceRecord(data, offset)
      msg.answers.add(answer)
    except:
      let e = getCurrentException()
      echo "回答のデコードに失敗: ", e.msg
      break
  
  # 権威セクションのデコード
  for i in 0..<header.nscount.int:
    try:
      let (auth, bytesRead) = decodeResourceRecord(data, offset)
      msg.authorities.add(auth)
    except:
      let e = getCurrentException()
      echo "権威のデコードに失敗: ", e.msg
      break
  
  # 追加セクションのデコード
  for i in 0..<header.arcount.int:
    try:
      let (additional, bytesRead) = decodeResourceRecord(data, offset)
      msg.additionals.add(additional)
    except:
      let e = getCurrentException()
      echo "追加セクションのデコードに失敗: ", e.msg
      break
  
  return msg

# クエリ操作ユーティリティ
proc createQuery*(domain: string, recordType: DnsRecordType, id: uint16 = 0): DnsMessage =
  ## 特定のドメインとレコードタイプに対するクエリメッセージを作成
  var msg = newDnsMessage()
  
  # ランダムIDの設定（指定されていない場合）
  if id == 0:
    randomize()
    msg.header.id = uint16(rand(65535))
  else:
    msg.header.id = id
  
  # フラグの設定
  msg.header.flags.qr = false  # クエリ
  msg.header.flags.opcode = 0  # 標準クエリ
  msg.header.flags.rd = true   # 再帰的解決を希望
  
  # クエリの追加
  var question = DnsQuestion(
    name: domain,
    qtype: recordType,
    qclass: DNS_CLASS_IN  # インターネットクラス
  )
  msg.questions.add(question)
  msg.header.qdcount = 1
  
  return msg

# リソースレコード処理
proc resourceRecordToDnsRecord*(rr: DnsResourceRecord): DnsRecord =
  ## リソースレコードからDnsRecordオブジェクトに変換
  var record = newDnsRecord(rr.name, rr.rrtype, rr.ttl.int)
  
  # レコードタイプに応じたデータの解析
  case rr.rrtype:
    of A:
      if rr.rdlength == 4:
        let ip = $rr.rdata[0] & "." & $rr.rdata[1] & "." & $rr.rdata[2] & "." & $rr.rdata[3]
        record.data = ip
    of AAAA:
      if rr.rdlength == 16:
        var ipv6Parts: array[8, uint16]
        for i in 0..<8:
          let offset = i * 2
          ipv6Parts[i] = uint16(rr.rdata[offset]) shl 8 or uint16(rr.rdata[offset + 1])
        
        var ipv6 = ""
        for i in 0..<8:
          if i > 0: ipv6 &= ":"
          ipv6 &= ipv6Parts[i].toHex(4)
        record.data = ipv6
    of CNAME, NS, PTR:
      # 名前フィールドをデコード
      var nameOffset = 0
      var ctx = DnsParseContext(data: rr.rdata, maxJump: 10)
      try:
        record.data = decodeDomainName(rr.rdata, nameOffset, ctx)
      except:
        record.data = "error-decoding-name"
    of MX:
      if rr.rdlength >= 2:
        var preference: uint16
        bigEndian16(addr preference, unsafeAddr rr.rdata[0])
        
        var nameOffset = 2
        var ctx = DnsParseContext(data: rr.rdata, maxJump: 10)
        try:
          let exchange = decodeDomainName(rr.rdata, nameOffset, ctx)
          record.data = $preference & " " & exchange
        except:
          record.data = $preference & " error-decoding-name"
    else:
      # 他のレコードタイプはバイナリデータを16進表現
      record.data = ""
      for b in rr.rdata:
        record.data &= b.toHex(2)
  
  return record

# 文字列表現
proc `$`*(flags: DnsHeaderFlags): string =
  ## ヘッダーフラグの文字列表現
  var parts: seq[string] = @[]
  
  if flags.qr: parts.add("QR")
  
  parts.add("OPCODE=" & $flags.opcode.int)
  
  if flags.aa: parts.add("AA")
  if flags.tc: parts.add("TC")
  if flags.rd: parts.add("RD")
  if flags.ra: parts.add("RA")
  if flags.z != 0: parts.add("Z=" & $flags.z.int)
  if flags.ad: parts.add("AD")
  if flags.cd: parts.add("CD")
  
  parts.add("RCODE=" & $flags.rcode.int)
  
  return parts.join(" ")

proc `$`*(header: DnsHeader): string =
  ## ヘッダーの文字列表現
  result = "ID=" & $header.id
  result &= " Flags=[" & $header.flags & "]"
  result &= " QD=" & $header.qdcount
  result &= " AN=" & $header.ancount
  result &= " NS=" & $header.nscount
  result &= " AR=" & $header.arcount

proc `$`*(question: DnsQuestion): string =
  ## クエリの文字列表現
  result = question.name & " "
  result &= $question.qtype & " "
  if question.qclass == DNS_CLASS_IN:
    result &= "IN"
  else:
    result &= "CLASS" & $question.qclass

proc `$`*(rr: DnsResourceRecord): string =
  ## リソースレコードの文字列表現
  result = rr.name & " "
  result &= $rr.ttl & " "
  
  if rr.rrclass == DNS_CLASS_IN:
    result &= "IN "
  else:
    result &= "CLASS" & $rr.rrclass & " "
  
  result &= $rr.rrtype & " "
  
  # データ部の文字列表現（レコードタイプに依存）
  case rr.rrtype:
    of A:
      if rr.rdlength == 4:
        result &= $rr.rdata[0] & "." & $rr.rdata[1] & "." & $rr.rdata[2] & "." & $rr.rdata[3]
    of AAAA:
      if rr.rdlength == 16:
        var ipv6Parts: array[8, uint16]
        for i in 0..<8:
          let offset = i * 2
          ipv6Parts[i] = uint16(rr.rdata[offset]) shl 8 or uint16(rr.rdata[offset + 1])
        
        for i in 0..<8:
          if i > 0: result &= ":"
          result &= ipv6Parts[i].toHex(4)
    of CNAME, NS, PTR:
      # 名前フィールドをデコード
      var nameOffset = 0
      var ctx = DnsParseContext(data: rr.rdata, maxJump: 10)
      try:
        result &= decodeDomainName(rr.rdata, nameOffset, ctx)
      except:
        result &= "<invalid name>"
    of MX:
      if rr.rdlength >= 2:
        var preference: uint16
        bigEndian16(addr preference, unsafeAddr rr.rdata[0])
        result &= $preference & " "
        
        var nameOffset = 2
        var ctx = DnsParseContext(data: rr.rdata, maxJump: 10)
        try:
          result &= decodeDomainName(rr.rdata, nameOffset, ctx)
        except:
          result &= "<invalid name>"
    else:
      # その他のタイプは16進表示
      result &= "<"
      for i, b in rr.rdata:
        if i > 0: result &= " "
        result &= b.toHex(2)
      result &= ">"

proc `$`*(msg: DnsMessage): string =
  ## DNSメッセージの文字列表現
  result = ";; HEADER: " & $msg.header & "\n"
  
  if msg.questions.len > 0:
    result &= "\n;; QUESTION SECTION:\n"
    for q in msg.questions:
      result &= $q & "\n"
  
  if msg.answers.len > 0:
    result &= "\n;; ANSWER SECTION:\n"
    for a in msg.answers:
      result &= $a & "\n"
  
  if msg.authorities.len > 0:
    result &= "\n;; AUTHORITY SECTION:\n"
    for a in msg.authorities:
      result &= $a & "\n"
  
  if msg.additionals.len > 0:
    result &= "\n;; ADDITIONAL SECTION:\n"
    for a in msg.additionals:
      result &= $a & "\n" 