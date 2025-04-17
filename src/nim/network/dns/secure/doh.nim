import std/[asyncdispatch, httpclient, json, tables, times, strutils, base64, uri, options, random]
import ../resolver
import ../cache/manager

type
  DohResolver* = ref object
    cacheManager*: DnsCacheManager
    httpClient*: AsyncHttpClient
    dohProviders*: seq[DohProvider]
    currentProviderIndex*: int
    timeout*: int                # タイムアウト（ミリ秒）
    retries*: int                # 再試行回数
    enableIdnSupport*: bool      # 国際化ドメイン名（IDN）サポートを有効にするか
    preferJson*: bool            # JSON形式のDoHを優先するか（falseの場合はDNSワイヤフォーマット）
  
  DohProvider* = object
    name*: string                # プロバイダー名
    url*: string                 # DoHエンドポイントURL
    supportsJson*: bool          # JSON形式をサポートするか
    supportsDnsWire*: bool       # DNSワイヤフォーマットをサポートするか
    requiresUserAgent*: bool     # User-Agentヘッダーが必要か
    requiresAcceptHeader*: bool  # Acceptヘッダーが必要か
    trustLevel*: int             # 信頼レベル（1-10）

# よく知られたDoHプロバイダー
const WELL_KNOWN_DOH_PROVIDERS = [
  DohProvider(
    name: "Google",
    url: "https://dns.google/dns-query",
    supportsJson: true,
    supportsDnsWire: true,
    requiresUserAgent: false,
    requiresAcceptHeader: true,
    trustLevel: 8
  ),
  DohProvider(
    name: "Cloudflare",
    url: "https://cloudflare-dns.com/dns-query",
    supportsJson: true,
    supportsDnsWire: true,
    requiresUserAgent: false,
    requiresAcceptHeader: true,
    trustLevel: 9
  ),
  DohProvider(
    name: "Quad9",
    url: "https://dns.quad9.net/dns-query",
    supportsJson: true,
    supportsDnsWire: true,
    requiresUserAgent: false,
    requiresAcceptHeader: true,
    trustLevel: 8
  ),
  DohProvider(
    name: "AdGuard",
    url: "https://dns.adguard.com/dns-query",
    supportsJson: true,
    supportsDnsWire: true,
    requiresUserAgent: true,
    requiresAcceptHeader: true,
    trustLevel: 7
  )
]

proc newDohResolver*(
  cacheFile: string = "doh_cache.json",
  customProviders: seq[DohProvider] = @[],
  timeout: int = 5000,
  retries: int = 2,
  maxCacheEntries: int = 10000,
  prefetchThreshold: float = 0.8,
  enableIdnSupport: bool = true,
  preferJson: bool = true
): DohResolver =
  ## DNS over HTTPS (DoH) リゾルバーを作成
  result = DohResolver()
  
  # キャッシュマネージャー初期化
  result.cacheManager = newDnsCacheManager(
    cacheFile = cacheFile,
    maxEntries = maxCacheEntries,
    prefetchThreshold = prefetchThreshold
  )
  
  # HTTP クライアント初期化
  var headers = newHttpHeaders()
  headers["User-Agent"] = "NimBrowser/1.0 DoH Client"
  result.httpClient = newAsyncHttpClient(headers = headers)
  result.httpClient.timeout = timeout
  
  # DoHプロバイダー設定
  result.dohProviders = if customProviders.len > 0: customProviders else: @WELL_KNOWN_DOH_PROVIDERS
  result.currentProviderIndex = 0
  result.timeout = timeout
  result.retries = retries
  result.enableIdnSupport = enableIdnSupport
  result.preferJson = preferJson
  
  echo "DoHリゾルバーを初期化: プロバイダー数=", result.dohProviders.len

proc punycodeEncode(domain: string): string =
  ## IDN（国際化ドメイン名）をPunycodeに変換する
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
    var delta = delta div (if firstTime: damp else: 2)
    delta += delta div numpoints
    
    var k = 0
    while delta > ((base - tmin) * tmax) div 2:
      delta = delta div (base - tmin)
      k += base
    
    return k + (((base - tmin + 1) * delta) div (delta + skew))
  
  # ASCII部分と非ASCII部分を分離
  var basic: seq[char] = @[]
  var nonBasic: seq[tuple[pos: int, cp: int]] = @[]
  
  for i, c in domain:
    if c.int < 128:
      basic.add(c)
    else:
      nonBasic.add((pos: basic.len, cp: c.int))
  
  # 出力バッファ
  var output = ""
  
  # ASCII部分をコピー
  for c in basic:
    output.add(c)
  
  # 非ASCII文字がない場合はそのまま返す
  if nonBasic.len == 0:
    return output
  
  # 非ASCII文字がある場合はACEプレフィックスを付加
  if output.len > 0:
    output.add(delimiter)
  
  # Punycode変換のメインアルゴリズム
  var n = initialN
  var bias = initialBias
  var delta = 0
  var h = basic.len
  var b = basic.len
  
  if b > 0:
    output.add(delimiter)
  
  # 非ASCII文字をエンコード
  while h < domain.len:
    # 次の最小のコードポイントを見つける
    var m = int.high
    for item in nonBasic:
      if item.cp < m and item.cp >= n:
        m = item.cp
    
    # デルタ更新
    delta += (m - n) * (h + 1)
    n = m
    
    # 同じコードポイントを持つ文字を処理
    for item in nonBasic:
      if item.cp < n:
        delta += 1
      elif item.cp == n:
        # コードポイントをエンコード
        var q = delta
        var k = base
        
        while true:
          let t = if k <= bias: tmin
                 elif k >= bias + tmax: tmax
                 else: k - bias
          
          if q < t:
            break
          
          let digit = t + ((q - t) mod (base - t))
          let c = if digit < 26: char(digit + ord('a'))
                 else: char(digit - 26 + ord('0'))
          
          output.add(c)
          q = (q - t) div (base - t)
          k += base
        
        # 最後の桁
        let c = if q < 26: char(q + ord('a'))
               else: char(q - 26 + ord('0'))
        
        output.add(c)
        
        # バイアス調整
        bias = adapt(delta, h + 1, h == b)
        delta = 0
        h += 1
    
    delta += 1
    n += 1
  
  return prefixAce & output

proc normalizeHostname(self: DohResolver, hostname: string): string =
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

proc getNextProvider(self: DohResolver): DohProvider =
  ## 次に使用するDoHプロバイダーを取得
  if self.dohProviders.len == 0:
    # フォールバック: Googleを使用
    return WELL_KNOWN_DOH_PROVIDERS[0]
  
  result = self.dohProviders[self.currentProviderIndex]
  self.currentProviderIndex = (self.currentProviderIndex + 1) mod self.dohProviders.len
  return result

proc queryDnsJson*(self: DohResolver, hostname: string, recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## JSON形式でDoHクエリを実行
  let provider = self.getNextProvider()
  let recordTypeStr = $recordType
  
  # 「A」や「AAAA」のようなレコードタイプ文字列が必要
  let typeStr = case recordType
    of A: "A"
    of AAAA: "AAAA"
    of CNAME: "CNAME"
    of MX: "MX"
    of TXT: "TXT"
    of NS: "NS"
    of SRV: "SRV"
    of PTR: "PTR"
    of SOA: "SOA"
    of DNSKEY: "DNSKEY"
    of DS: "DS"
    of RRSIG: "RRSIG"
    of NSEC: "NSEC"
    of NSEC3: "NSEC3"
  
  # URLを構築
  var url = provider.url
  if provider.url.contains("?"):
    url &= "&name=" & hostname & "&type=" & typeStr
  else:
    url &= "?name=" & hostname & "&type=" & typeStr
  
  # JSON応答を要求
  var headers = newHttpHeaders()
  headers["Accept"] = "application/dns-json"
  
  if provider.requiresUserAgent:
    headers["User-Agent"] = "NimBrowser/1.0 DoH Client"
  
  # リクエスト実行
  var response: Response
  try:
    response = await self.httpClient.request(url, HttpGet, headers = headers)
  except:
    echo "DoHリクエスト失敗: ", getCurrentExceptionMsg()
    return @[]
  
  # レスポンス検証
  if response.code != Http200:
    echo "DoHエラー: HTTP ", response.code, " from ", provider.name
    return @[]
  
  # JSONレスポンスをパース
  let jsonBody = parseJson(response.body)
  
  # 応答をEnhancedDnsRecordに変換
  var records: seq[EnhancedDnsRecord] = @[]
  let now = getTime()
  
  # Google Public DNSのJSON形式に基づいて解析
  if jsonBody.hasKey("Answer"):
    for answer in jsonBody["Answer"]:
      if answer.hasKey("type") and answer.hasKey("data") and answer.hasKey("TTL"):
        let answerType = answer["type"].getInt()
        let data = answer["data"].getStr()
        let ttl = answer["TTL"].getInt()
        let name = if answer.hasKey("name"): answer["name"].getStr() else: hostname
        
        # レコードタイプが要求したものと一致するか確認
        let recordTypeInt = case recordType
          of A: 1
          of AAAA: 28
          of CNAME: 5
          of MX: 15
          of TXT: 16
          of NS: 2
          of SRV: 33
          of PTR: 12
          of SOA: 6
          of DNSKEY: 48
          of DS: 43
          of RRSIG: 46
          of NSEC: 47
          of NSEC3: 50
        
        if answerType == recordTypeInt:
          var record = EnhancedDnsRecord(
            ttl: ttl,
            timestamp: now,
            accessCount: 1,
            source: DnsSource.DoH,
            provider: provider.name,
            hostname: name,
            data: DnsRecordData(recordType: recordType)
          )
          
          # レコードタイプに応じてデータを設定
          case recordType
            of A:
              record.data.ipv4 = data
            of AAAA:
              record.data.ipv6 = data
            of CNAME:
              record.data.cname = data
            of MX:
              # MXレコードは「優先度 交換サーバー」の形式
              let parts = data.split()
              if parts.len >= 2:
                try:
                  record.data.preference = parseInt(parts[0])
                  record.data.exchange = parts[1]
                except ValueError:
                  echo "MXレコード解析エラー: ", getCurrentExceptionMsg()
                  record.data.preference = 10  # デフォルト
                  record.data.exchange = data
              else:
                record.data.preference = 10
                record.data.exchange = data
            of TXT:
              # 引用符を削除
              var textData = data
              if textData.startsWith("\"") and textData.endsWith("\""):
                textData = textData[1..^2]
              record.data.text = textData
            of NS:
              record.data.nameserver = data
            of SRV:
              # SRVレコードは「優先度 重み ポート ターゲット」の形式
              let parts = data.split()
              if parts.len >= 4:
                try:
                  record.data.priority = parseInt(parts[0])
                  record.data.weight = parseInt(parts[1])
                  record.data.port = parseInt(parts[2])
                  record.data.target = parts[3]
                except ValueError:
                  echo "SRVレコード解析エラー: ", getCurrentExceptionMsg()
                  record.data.target = data
              else:
                record.data.target = data
            of PTR:
              record.data.ptrdname = data
            of SOA:
              # SOAレコードは「プライマリNS 管理者メール シリアル リフレッシュ リトライ 有効期限 最小TTL」の形式
              let parts = data.split()
              if parts.len >= 7:
                try:
                  record.data.mname = parts[0]
                  record.data.rname = parts[1]
                  record.data.serial = parseUInt(parts[2])
                  record.data.refresh = parseInt(parts[3])
                  record.data.retry = parseInt(parts[4])
                  record.data.expire = parseInt(parts[5])
                  record.data.minimum = parseInt(parts[6])
                except ValueError:
                  echo "SOAレコード解析エラー: ", getCurrentExceptionMsg()
                  record.data.rawData = data
              else:
                record.data.rawData = data
            of DNSKEY, DS, RRSIG, NSEC, NSEC3:
              # 複雑なDNSSECレコードはrawDataに格納
              record.data.rawData = data
          
          # 検証フラグの設定（DNSSEC対応の場合）
          if answer.hasKey("authenticated") and answer["authenticated"].getBool():
            record.dnssecValidated = true
          
          records.add(record)
  
  # Cloudflare DNSやその他のプロバイダ対応
  if records.len == 0 and jsonBody.hasKey("Status"):
    let status = jsonBody["Status"].getInt()
    if status != 0:  # エラーステータス
      echo "DoHエラー: ステータスコード ", status, " from ", provider.name
  
  return records
proc queryDnsWire*(self: DohResolver, hostname: string, recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## DNSワイヤフォーマットでDoHクエリを実行
  ## RFC8484に準拠したDNSワイヤフォーマットの実装
  
  # DNSクエリパケットの構築
  var packet: seq[byte] = @[]
  let id = rand(0xFFFF).uint16  # ランダムなクエリID
  
  # ヘッダーの構築
  packet.add(byte((id shr 8) and 0xFF))  # ID上位バイト
  packet.add(byte(id and 0xFF))          # ID下位バイト
  packet.add(0x01)  # フラグ1: 標準クエリ、再帰的解決要求
  packet.add(0x00)  # フラグ2: 応答コード等
  packet.add(0x00)  # QDCOUNT上位バイト
  packet.add(0x01)  # QDCOUNT下位バイト (1つのクエリ)
  packet.add(0x00)  # ANCOUNT上位バイト
  packet.add(0x00)  # ANCOUNT下位バイト (応答セクション0)
  packet.add(0x00)  # NSCOUNT上位バイト
  packet.add(0x00)  # NSCOUNT下位バイト (権威セクション0)
  packet.add(0x00)  # ARCOUNT上位バイト
  packet.add(0x00)  # ARCOUNT下位バイト (追加セクション0)
  
  # クエリドメイン名のエンコード
  let labels = hostname.split('.')
  for label in labels:
    if label.len > 0:
      packet.add(byte(label.len))
      for c in label:
        packet.add(byte(c))
  
  # 終端バイト
  packet.add(0x00)
  
  # クエリタイプとクラスの追加
  let typeValue = ord(recordType).uint16
  packet.add(byte((typeValue shr 8) and 0xFF))  # タイプ上位バイト
  packet.add(byte(typeValue and 0xFF))          # タイプ下位バイト
  packet.add(0x00)  # クラス上位バイト (IN)
  packet.add(0x01)  # クラス下位バイト (IN)
  
  # Base64urlエンコード
  let encodedQuery = base64.encode(packet)
  let safeEncodedQuery = encodedQuery.replace('+', '-').replace('/', '_').replace("=", "")
  
  # HTTPリクエストの構築
  var client = newHttpClient()
  client.headers = newHttpHeaders({
    "Accept": "application/dns-message",
    "Content-Type": "application/dns-message"
  })
  
  # DoHサーバーへのリクエスト
  let url = self.serverUrl & "?dns=" & safeEncodedQuery
  
  try:
    let response = await client.getContent(url)
    let responseBytes = cast[seq[byte]](response)
    
    # DNSレスポンスの解析
    if responseBytes.len < 12:
      echo "DoHワイヤーフォーマット応答が短すぎます"
      return @[]
    
    # ヘッダーの解析
    let responseId = (responseBytes[0].uint16 shl 8) or responseBytes[1].uint16
    if responseId != id:
      echo "DoHワイヤーフォーマット応答IDが一致しません"
      return @[]
    
    # レスポンスコードの確認
    let rcode = responseBytes[3] and 0x0F
    if rcode != 0:
      echo "DNSエラー応答コード: ", rcode
      return @[]
    
    # 回答セクションの数を取得
    let ancount = (responseBytes[6].uint16 shl 8) or responseBytes[7].uint16
    
    # 回答レコードの解析
    var records: seq[EnhancedDnsRecord] = @[]
    var pos = 12  # ヘッダー後の位置
    
    # クエリセクションをスキップ
    while pos < responseBytes.len and responseBytes[pos] != 0:
      pos += responseBytes[pos].int + 1
    pos += 5  # 終端バイト + タイプ + クラス
    
    # 現在時刻を取得
    let now = getTime()
    
    # 回答セクションの解析
    for i in 0..<ancount:
      if pos + 12 > responseBytes.len:
        break
      
      # 名前フィールドの処理（圧縮ポインタの可能性あり）
      if (responseBytes[pos] and 0xC0) == 0xC0:
        pos += 2  # 圧縮ポインタをスキップ
      else:
        # 非圧縮名をスキップ
        while pos < responseBytes.len and responseBytes[pos] != 0:
          pos += responseBytes[pos].int + 1
        pos += 1  # 終端バイト
      
      # タイプ、クラス、TTL、データ長の取得
      let answerType = (responseBytes[pos].uint16 shl 8) or responseBytes[pos+1].uint16
      pos += 4  # タイプとクラスをスキップ
      
      let ttl = (responseBytes[pos].uint32 shl 24) or
                (responseBytes[pos+1].uint32 shl 16) or
                (responseBytes[pos+2].uint32 shl 8) or
                responseBytes[pos+3].uint32
      pos += 4
      
      let rdlength = (responseBytes[pos].uint16 shl 8) or responseBytes[pos+1].uint16
      pos += 2
      
      # データの解析
      if pos + rdlength.int <= responseBytes.len:
        var record = EnhancedDnsRecord()
        record.ttl = ttl
        record.timestamp = now
        record.accessCount = 1
        record.data.recordType = recordType
        
        # レコードタイプに応じたデータの解析
        case recordType
          of A:
            if rdlength == 4:
              record.data.ipv4 = $responseBytes[pos] & "." & 
                                $responseBytes[pos+1] & "." & 
                                $responseBytes[pos+2] & "." & 
                                $responseBytes[pos+3]
          of AAAA:
            if rdlength == 16:
              var ipv6Parts: array[8, string]
              for j in 0..<8:
                let hexValue = (responseBytes[pos + j*2].int shl 8) or responseBytes[pos + j*2 + 1].int
                ipv6Parts[j] = toHex(hexValue, 4).toLowerAscii
              record.data.ipv6 = ipv6Parts.join(":")
          of CNAME, NS, PTR:
            # ドメイン名の解析（圧縮を考慮）
            var domainName = self.decodeDomainName(responseBytes, pos)
            case recordType
              of CNAME: record.data.cname = domainName
              of NS: record.data.nameserver = domainName
              of PTR: record.data.ptrdname = domainName
              else: discard
          of MX:
            if rdlength >= 2:
              record.data.preference = (responseBytes[pos].uint16 shl 8) or responseBytes[pos+1].uint16
              record.data.exchange = self.decodeDomainName(responseBytes, pos+2)
          of TXT:
            if rdlength > 0:
              let txtLen = responseBytes[pos].int
              if txtLen > 0 and pos + 1 + txtLen <= responseBytes.len:
                var txtData = ""
                for j in 0..<txtLen:
                  txtData.add(char(responseBytes[pos + 1 + j]))
                record.data.text = txtData
          of SRV:
            if rdlength >= 6:
              record.data.priority = (responseBytes[pos].uint16 shl 8) or responseBytes[pos+1].uint16
              record.data.weight = (responseBytes[pos+2].uint16 shl 8) or responseBytes[pos+3].uint16
              record.data.port = (responseBytes[pos+4].uint16 shl 8) or responseBytes[pos+5].uint16
              record.data.target = self.decodeDomainName(responseBytes, pos+6)
          of SOA, DNSKEY, DS, RRSIG, NSEC, NSEC3:
            # 複雑なレコードは生データを保存
            var rawData = ""
            for j in 0..<rdlength.int:
              rawData.add(char(responseBytes[pos + j]))
            record.data.rawData = rawData
          else:
            # その他のレコードタイプは生データを保存
            var rawData = ""
            for j in 0..<rdlength.int:
              rawData.add(char(responseBytes[pos + j]))
            record.data.rawData = rawData
        
        records.add(record)
      
      pos += rdlength.int
    
    return records
  except Exception as e:
    echo "DoHワイヤーフォーマットクエリエラー: ", e.msg
    # エラー時はJSONメソッドにフォールバック
    return await self.queryDnsJson(hostname, recordType)

proc decodeDomainName(self: DohResolver, data: seq[byte], startPos: int): string =
  ## DNSメッセージからドメイン名をデコード（圧縮対応）
  var result = ""
  var pos = startPos
  var jumping = false
  var jumpCount = 0
  const maxJumps = 10  # 無限ループ防止
  
  while pos < data.len:
    if jumpCount > maxJumps:
      return result
    
    let len = data[pos]
    if len == 0:
      # 終端
      if not jumping:
        pos += 1
      break
    elif (len and 0xC0) == 0xC0:
      # 圧縮ポインタ
      if pos + 1 >= data.len:
        break
      
      let offset = ((len and 0x3F).int shl 8) or data[pos + 1].int
      if not jumping:
        pos += 2
      
      jumping = true
      jumpCount += 1
      pos = offset
    else:
      # 通常のラベル
      pos += 1
      if pos + len.int > data.len:
        break
      
      if result.len > 0:
        result.add('.')
      
      for i in 0..<len.int:
        result.add(char(data[pos + i]))
      
      pos += len.int
  
  return result

proc resolveWithType*(self: DohResolver, hostname: string, 
                     recordType: DnsRecordType): Future[seq[EnhancedDnsRecord]] {.async.} =
  ## 特定のレコードタイプのDNS解決を実行
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  echo "DoH解決中: ", normalizedHostname, " (", $recordType, ")"
  
  # キャッシュをチェック
  var cachedRecords = self.cacheManager.get(normalizedHostname, recordType)
  if cachedRecords.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DoHキャッシュヒット: ", normalizedHostname, " (", $recordType, ")"
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, recordType):
      echo "DoHをバックグラウンドでプリフェッチ: ", normalizedHostname, " (", $recordType, ")"
      asyncCheck self.prefetchWithType(normalizedHostname, recordType)
    
    return cachedRecords
  
  # DoHクエリを実行
  var records: seq[EnhancedDnsRecord]
  var success = false
  
  for attempt in 0..<(self.retries + 1):
    try:
      if self.preferJson:
        records = await self.queryDnsJson(normalizedHostname, recordType)
      else:
        records = await self.queryDnsWire(normalizedHostname, recordType)
      
      if records.len > 0:
        success = true
        break
    except:
      echo "DoHクエリ失敗 (試行 ", attempt + 1, "/", self.retries + 1, "): ", getCurrentExceptionMsg()
    
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

proc prefetchWithType*(self: DohResolver, hostname: string, 
                      recordType: DnsRecordType): Future[void] {.async.} =
  ## 特定のレコードタイプでプリフェッチ
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  try:
    echo "DoHをプリフェッチ中: ", normalizedHostname, " (", $recordType, ")"
    discard await self.resolveWithType(normalizedHostname, recordType)
  except:
    echo "DoHプリフェッチに失敗: ", normalizedHostname, " (", $recordType, ")"

proc resolveHostname*(self: DohResolver, hostname: string): Future[seq[string]] {.async.} =
  ## ホスト名をIPアドレスに解決する
  ## キャッシュにある場合はキャッシュから返す
  ## ない場合は実際に解決を行う
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return @[]
  
  echo "DoHを解決中: ", normalizedHostname
  
  # キャッシュをチェック
  var cachedIps = self.cacheManager.getIpAddresses(normalizedHostname)
  if cachedIps.len > 0:
    # キャッシュが有効な場合はそれを返す
    echo "DoHキャッシュヒット: ", normalizedHostname
    
    # TTLのしきい値を超えていればバックグラウンドでプリフェッチ
    if self.cacheManager.shouldPrefetch(normalizedHostname, A) or
       self.cacheManager.shouldPrefetch(normalizedHostname, AAAA):
      echo "DoHをバックグラウンドでプリフェッチ: ", normalizedHostname
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

proc prefetchHostname*(self: DohResolver, hostname: string): Future[void] {.async.} =
  ## ホスト名の解決結果をバックグラウンドで事前に取得し、キャッシュを更新
  let normalizedHostname = self.normalizeHostname(hostname)
  
  if normalizedHostname.len == 0:
    return
  
  try:
    echo "DoHをプリフェッチ中: ", normalizedHostname
    discard await self.resolveHostname(normalizedHostname)
  except:
    echo "DoHプリフェッチに失敗: ", normalizedHostname

proc prefetchBatch*(self: DohResolver, hostnames: seq[string]) {.async.} =
  ## 複数のホスト名を一括でプリフェッチ
  var futures: seq[Future[void]] = @[]
  
  for hostname in hostnames:
    futures.add(self.prefetchHostname(hostname))
  
  await all(futures)

proc resolveAll*(self: DohResolver, urls: seq[string]): Future[Table[string, seq[string]]] {.async.} =
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
      echo "DoH解決に失敗: ", hostname
      result[hostname] = @[]
  
  return result

proc clearCache*(self: DohResolver) =
  ## DoHキャッシュを完全にクリア
  self.cacheManager.clear()

proc getCacheStats*(self: DohResolver): string =
  ## キャッシュの統計情報を取得（文字列形式）
  let stats = self.cacheManager.getCacheStats()
  return $stats 