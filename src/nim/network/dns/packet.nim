import std/[asyncdispatch, asyncnet, net, endians, strutils, random, tables]
import message, records

type
  DnsTransportProtocol* = enum
    dtpUdp,    # 標準的なUDP DNS
    dtpTcp,    # TCP DNS
    dtpDoH,    # DNS over HTTPS
    dtpDoT     # DNS over TLS
  
  DnsPacketError* = object of CatchableError
    ## DNSパケット処理中のエラー
  
  DnsTransportError* = object of DnsPacketError
    ## トランスポート層のエラー
  
  DnsQueryOptions* = object
    id*: uint16                 # DNSクエリID（0の場合は自動生成）
    recursionDesired*: bool     # 再帰的クエリを行うか
    checkingDisabled*: bool     # DNSSECチェックを無効化するか
    ednsEnabled*: bool          # EDNSを有効にするか
    ednsBufferSize*: uint16     # EDNSバッファサイズ
    ednsDnssecOk*: bool         # DNSSEC OKフラグ
    timeout*: int               # タイムアウト（ミリ秒）
    transport*: DnsTransportProtocol  # トランスポート層

const
  DEFAULT_DNS_PORT* = 53       # 標準的なDNSポート
  DEFAULT_DOT_PORT* = 853      # DNS over TLSポート
  DEFAULT_DNS_TIMEOUT* = 5000  # デフォルトタイムアウト（5秒）
  DEFAULT_EDNS_BUFFER_SIZE* = 1232  # OPTレコードのUDPペイロードサイズ
  DNS_TCP_MESSAGE_PREFIX_SIZE* = 2  # TCPメッセージのサイズプレフィックスのサイズ

# ユーティリティ関数
proc newDnsQueryOptions*(): DnsQueryOptions =
  ## デフォルトのDNSクエリオプションを作成
  result.id = 0  # 自動生成
  result.recursionDesired = true
  result.checkingDisabled = false
  result.ednsEnabled = true
  result.ednsBufferSize = DEFAULT_EDNS_BUFFER_SIZE
  result.ednsDnssecOk = false
  result.timeout = DEFAULT_DNS_TIMEOUT
  result.transport = dtpUdp

proc getRandomDnsId*(): uint16 =
  ## ランダムなDNS IDを生成
  randomize()
  result = uint16(rand(1..65535))

proc addEdnsRecord*(msg: var DnsMessage, bufferSize: uint16 = DEFAULT_EDNS_BUFFER_SIZE, dnssecOk: bool = false) =
  ## EDNSレコードをDNSメッセージに追加
  var edns = DnsResourceRecord()
  edns.name = "."
  edns.rrtype = DnsRecordType(41)  # OPTレコードタイプ
  edns.rrclass = bufferSize  # UDPペイロードサイズ
  
  # TTLフィールドは拡張フラグ用に使用
  var flags: uint32 = 0
  if dnssecOk:
    flags = flags or 0x8000'u32  # DO bit
  edns.ttl = flags
  
  # 空のデータ
  edns.rdlength = 0
  edns.rdata = @[]
  
  msg.additionals.add(edns)
  msg.header.arcount += 1

# UDP トランスポート
proc sendUdpQuery*(socket: AsyncSocket, query: DnsMessage, address: string, port: int = DEFAULT_DNS_PORT): Future[void] {.async.} =
  ## UDP経由でDNSクエリを送信
  let packet = encodeDnsMessage(query)
  await socket.sendTo(address, Port(port), packet)

proc receiveUdpResponse*(socket: AsyncSocket, timeout: int = DEFAULT_DNS_TIMEOUT): Future[DnsMessage] {.async.} =
  ## UDP経由でDNSレスポンスを受信
  var buffer = newString(65535)  # 最大UDPペイロードサイズ
  
  # タイムアウト処理の設定
  var timeoutFuture = sleepAsync(timeout)
  var receiveFuture = socket.recvFrom(address = 65535)
  
  var responseData: string
  var fromAddr: string
  var fromPort: Port
  
  var completed = await receiveFuture or timeoutFuture
  
  if not completed:
    raise newException(DnsTransportError, "DNSクエリがタイムアウトしました")
  
  if not receiveFuture.finished:
    raise newException(DnsTransportError, "DNSクエリがタイムアウトしました")
  
  (responseData, fromAddr, fromPort) = receiveFuture.read
  
  var packetData: seq[byte] = @[]
  for c in responseData:
    packetData.add(byte(c))
  
  try:
    result = decodeDnsMessage(packetData)
  except:
    let e = getCurrentException()
    raise newException(DnsPacketError, "DNSパケットのデコードに失敗: " & e.msg)

# TCP トランスポート
proc sendTcpQuery*(socket: AsyncSocket, query: DnsMessage): Future[void] {.async.} =
  ## TCP経由でDNSクエリを送信
  let packet = encodeDnsMessage(query)
  let packetLen = uint16(packet.len)
  
  # TCP DNSメッセージは2バイトの長さプレフィックスが必要
  var lenPrefix = newSeq[byte](2)
  bigEndian16(addr lenPrefix[0], unsafeAddr packetLen)
  
  # まず長さプレフィックスを送信
  await socket.send(lenPrefix)
  
  # 次にパケットを送信
  await socket.send(packet)

proc receiveTcpResponse*(socket: AsyncSocket, timeout: int = DEFAULT_DNS_TIMEOUT): Future[DnsMessage] {.async.} =
  ## TCP経由でDNSレスポンスを受信
  # 長さプレフィックスを受信
  var lenBuf = newString(2)
  let lenRead = await socket.recvInto(addr lenBuf[0], 2)
  
  if lenRead != 2:
    raise newException(DnsTransportError, "TCPレスポンス長さの受信に失敗")
  
  var msgLen: uint16
  bigEndian16(addr msgLen, unsafeAddr lenBuf[0])
  
  # メッセージを受信
  var buffer = newString(msgLen.int)
  let msgRead = await socket.recvInto(addr buffer[0], msgLen.int)
  
  if msgRead != msgLen.int:
    raise newException(DnsTransportError, "TCPレスポンスの受信に失敗: 期待=" & $msgLen & ", 受信=" & $msgRead)
  
  var packetData: seq[byte] = @[]
  for c in buffer:
    packetData.add(byte(c))
  
  try:
    result = decodeDnsMessage(packetData)
  except:
    let e = getCurrentException()
    raise newException(DnsPacketError, "DNSパケットのデコードに失敗: " & e.msg)

# クエリとレスポンス管理
type
  DnsQueryTracker* = ref object
    ## DNSクエリの追跡と応答の関連付けを行う
    activeQueries*: Table[uint16, Future[DnsMessage]]
    socket*: AsyncSocket
    transport*: DnsTransportProtocol
    pendingQueries*: int

proc newDnsQueryTracker*(socket: AsyncSocket, transport: DnsTransportProtocol = dtpUdp): DnsQueryTracker =
  ## 新しいDNSクエリトラッカーを作成
  result = DnsQueryTracker()
  result.activeQueries = initTable[uint16, Future[DnsMessage]]()
  result.socket = socket
  result.transport = transport
  result.pendingQueries = 0

proc trackQuery*(tracker: DnsQueryTracker, queryId: uint16): Future[DnsMessage] =
  ## 新しいクエリを追跡
  var p = newFuture[DnsMessage]("dnsQueryResponse")
  tracker.activeQueries[queryId] = p
  inc(tracker.pendingQueries)
  return p

proc completeQuery*(tracker: DnsQueryTracker, response: DnsMessage) =
  ## 受信したレスポンスを対応するクエリに関連付けて完了させる
  let queryId = response.header.id
  
  if queryId in tracker.activeQueries:
    let future = tracker.activeQueries[queryId]
    tracker.activeQueries.del(queryId)
    dec(tracker.pendingQueries)
    future.complete(response)

proc handleUdpResponses*(tracker: DnsQueryTracker) {.async.} =
  ## UDP DNSレスポンスを非同期に処理
  while true:
    if tracker.pendingQueries == 0:
      # アクティブなクエリがない場合は少し待機
      await sleepAsync(10)
      continue
    
    try:
      let response = await receiveUdpResponse(tracker.socket)
      tracker.completeQuery(response)
    except:
      let e = getCurrentException()
      echo "UDP DNSレスポンス処理中のエラー: ", e.msg
      await sleepAsync(10)

# レスポンス検証
proc verifyDnsResponse*(query: DnsMessage, response: DnsMessage): bool =
  ## DNSレスポンスが特定のクエリに対するものかを検証
  # IDが一致するか
  if query.header.id != response.header.id:
    return false
  
  # レスポンスが質問に対する回答か
  if not response.header.flags.qr:
    return false
  
  # 少なくとも1つのクエリがあるか
  if response.questions.len == 0:
    return false
  
  # クエリ数が一致するか
  if query.questions.len != response.questions.len:
    return false
  
  # 各クエリが一致するか
  for i in 0..<query.questions.len:
    let qQuestion = query.questions[i]
    let rQuestion = response.questions[i]
    
    if qQuestion.name.toLowerAscii() != rQuestion.name.toLowerAscii():
      return false
    
    if qQuestion.qtype != rQuestion.qtype:
      return false
    
    if qQuestion.qclass != rQuestion.qclass:
      return false
  
  return true

# 簡易クエリクライアント
proc queryDns*(domain: string, recordType: DnsRecordType, nameserver: string = "8.8.8.8", 
               port: int = DEFAULT_DNS_PORT, options: DnsQueryOptions = newDnsQueryOptions()): Future[DnsMessage] {.async.} =
  ## シンプルなDNSクエリを実行
  ## 
  ## Parameters:
  ##   domain: 問い合わせるドメイン名
  ##   recordType: 問い合わせるDNSレコードタイプ
  ##   nameserver: 使用するDNSサーバーのIPアドレス
  ##   port: DNSサーバーのポート番号
  ##   options: クエリオプション設定
  ##
  ## Returns:
  ##   DNSレスポンスメッセージ
  
  # 入力検証
  if domain.len == 0:
    raise newException(DnsQueryError, "ドメイン名が空です")
  
  if domain.len > 253:
    raise newException(DnsQueryError, "ドメイン名が長すぎます（最大253文字）")
  
  # クエリメッセージの作成
  var queryMsg = createQuery(domain, recordType)
  
  # IDの設定
  if options.id == 0:
    queryMsg.header.id = getRandomDnsId()
  else:
    queryMsg.header.id = options.id
  
  # フラグの設定
  queryMsg.header.flags.rd = options.recursionDesired
  queryMsg.header.flags.cd = options.checkingDisabled
  queryMsg.header.flags.ad = options.authenticatedData
  
  # EDNSの追加
  if options.ednsEnabled:
    addEdnsRecord(queryMsg, options.ednsBufferSize, options.ednsDnssecOk)
  
  # DNSSECオプションの設定
  if options.dnssecEnabled:
    queryMsg.header.flags.do = true
  
  var response: DnsMessage
  var retryCount = 0
  let maxRetries = options.retryCount
  
  while retryCount <= maxRetries:
    try:
      case options.transport:
        of dtpUdp:
          # UDP クエリ
          var socket = newAsyncSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
          try:
            # タイムアウト設定
            socket.setSockOpt(OptSoRcvTimeo, options.timeout)
            
            # クエリ送信
            await sendUdpQuery(socket, queryMsg, nameserver, port)
            
            # レスポンス受信
            response = await receiveUdpResponse(socket, options.timeout)
            
            # TCPフォールバックが有効で、レスポンスがTCフラグを持つ場合
            if options.tcpFallback and response.header.flags.tc:
              socket.close()
              return await queryDns(domain, recordType, nameserver, port, 
                                   DnsQueryOptions(transport: dtpTcp, 
                                                  timeout: options.timeout,
                                                  id: queryMsg.header.id,
                                                  recursionDesired: options.recursionDesired,
                                                  checkingDisabled: options.checkingDisabled,
                                                  authenticatedData: options.authenticatedData,
                                                  ednsEnabled: options.ednsEnabled,
                                                  ednsBufferSize: options.ednsBufferSize,
                                                  ednsDnssecOk: options.ednsDnssecOk,
                                                  dnssecEnabled: options.dnssecEnabled,
                                                  retryCount: 0))
          finally:
            socket.close()
        
        of dtpTcp:
          # TCP クエリ
          var socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
          try:
            # タイムアウト設定
            socket.setSockOpt(OptSoRcvTimeo, options.timeout)
            socket.setSockOpt(OptSoSndTimeo, options.timeout)
            
            # 接続
            await socket.connect(nameserver, Port(port))
            
            # クエリ送信
            await sendTcpQuery(socket, queryMsg)
            
            # レスポンス受信
            response = await receiveTcpResponse(socket, options.timeout)
          finally:
            socket.close()
        
        of dtpDoT:
          # DNS over TLS
          var tlsContext = newTLSContext()
          try:
            # TLS設定
            tlsContext.validateCert = true
            
            # TLSソケット作成
            var socket = newAsyncSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            try:
              # 接続
              await socket.connect(nameserver, Port(port))
              
              # TLSハンドシェイク
              var tlsSocket = wrapSocket(tlsContext, socket)
              await tlsSocket.handshake()
              
              # クエリ送信
              await sendTcpQuery(tlsSocket, queryMsg)
              
              # レスポンス受信
              response = await receiveTcpResponse(tlsSocket, options.timeout)
            finally:
              socket.close()
          finally:
            tlsContext.destroy()
        
        of dtpDoH:
          # DNS over HTTPS
          let url = if nameserver.startsWith("https://"):
                      nameserver
                    else:
                      "https://" & nameserver & "/dns-query"
          
          # HTTPクライアント設定
          var client = newAsyncHttpClient()
          try:
            # クエリをワイヤーフォーマットにエンコード
            let wireFormat = encodeDnsMessage(queryMsg)
            
            # HTTPヘッダー設定
            client.headers = newHttpHeaders({
              "Content-Type": "application/dns-message",
              "Accept": "application/dns-message"
            })
            
            # POSTリクエスト送信
            let httpResponse = await client.post(url, wireFormat)
            
            # レスポンス検証
            if httpResponse.code != Http200:
              raise newException(DnsTransportError, "DoHサーバーからエラーレスポンス: " & $httpResponse.code)
            
            # レスポンスボディ取得
            let responseBody = await httpResponse.body
            
            # DNSメッセージにデコード
            response = decodeDnsMessage(responseBody)
          finally:
            client.close()
      
      # レスポンス取得成功
      break
    
    except CatchableError as e:
      # リトライ判定
      retryCount.inc
      if retryCount > maxRetries:
        raise newException(DnsQueryError, "DNSクエリ失敗（リトライ回数超過）: " & e.msg)
      
      # 指数バックオフによる待機
      let backoffTime = min(options.timeout * (2 ^ retryCount), 10_000)
      await sleepAsync(backoffTime)
      
      # 次のリトライでIDを変更
      if options.id == 0:
        queryMsg.header.id = getRandomDnsId()
  # レスポンス検証
  if not verifyDnsResponse(queryMsg, response):
    raise newException(DnsPacketError, "DNSレスポンスがクエリと一致しません")
  
  return response

# DNS パケットの解析 (バイナリからレコードへの変換)
proc extractDnsRecordsFromResponse*(response: DnsMessage): seq[DnsRecord] =
  ## DNSレスポンスからDnsRecordを抽出
  result = @[]
  
  # 回答セクションからレコードを抽出
  for answer in response.answers:
    let record = resourceRecordToDnsRecord(answer)
    result.add(record)
  
  # 権威セクションからレコードを抽出
  for auth in response.authorities:
    let record = resourceRecordToDnsRecord(auth)
    result.add(record)
  
  # 必要に応じて追加セクションを処理
  for additional in response.additionals:
    # EDNS OPTレコードはスキップ
    if additional.rrtype.int == 41:
      continue
    
    let record = resourceRecordToDnsRecord(additional)
    result.add(record)

# バイナリデータからIPv4アドレスを抽出
proc extractIPv4FromRData*(rdata: seq[byte]): string =
  ## リソースデータからIPv4アドレスを抽出
  if rdata.len != 4:
    raise newException(ValueError, "IPv4アドレスには4バイトが必要ですが、" & $rdata.len & "バイトが指定されました")
  
  result = $rdata[0] & "." & $rdata[1] & "." & $rdata[2] & "." & $rdata[3]

# バイナリデータからIPv6アドレスを抽出
proc extractIPv6FromRData*(rdata: seq[byte]): string =
  ## リソースデータからIPv6アドレスを抽出
  if rdata.len != 16:
    raise newException(ValueError, "IPv6アドレスには16バイトが必要ですが、" & $rdata.len & "バイトが指定されました")
  
  var parts: array[8, string]
  for i in 0..<8:
    let offset = i * 2
    let value = (uint16(rdata[offset]) shl 8) or uint16(rdata[offset + 1])
    parts[i] = value.toHex(4).toLowerAscii()
  
  # 標準的なIPv6表記に変換
  result = parts.join(":")

# TCPでのDNSメッセージの分割読み取り
proc readTcpDnsMessage*(socket: AsyncSocket): Future[seq[byte]] {.async.} =
  ## TCPソケットからDNSメッセージを読み取る（長さプレフィックス付き）
  # 長さプレフィックスを読み取り
  var lenBuf = newString(DNS_TCP_MESSAGE_PREFIX_SIZE)
  let lenRead = await socket.recvInto(addr lenBuf[0], DNS_TCP_MESSAGE_PREFIX_SIZE)
  
  if lenRead != DNS_TCP_MESSAGE_PREFIX_SIZE:
    if lenRead == 0:
      raise newException(DnsTransportError, "接続が閉じられました")
    else:
      raise newException(DnsTransportError, "メッセージ長プレフィックスの読み取りに失敗: " & $lenRead & "バイト")
  
  var msgLen: uint16
  bigEndian16(addr msgLen, unsafeAddr lenBuf[0])
  
  if msgLen == 0:
    return @[]
  
  # メッセージ本体を読み取り
  var buffer = newString(msgLen.int)
  var totalRead = 0
  
  while totalRead < msgLen.int:
    let bytesRead = await socket.recvInto(addr buffer[totalRead], msgLen.int - totalRead)
    if bytesRead <= 0:
      raise newException(DnsTransportError, "メッセージ本体の読み取り中に接続が閉じられました")
    
    totalRead += bytesRead
  
  # 文字列をバイト配列に変換
  var packetData: seq[byte] = @[]
  for c in buffer:
    packetData.add(byte(c))
  
  return packetData

# TCPでのDNSメッセージの送信
proc writeTcpDnsMessage*(socket: AsyncSocket, data: seq[byte]): Future[void] {.async.} =
  ## TCPソケットにDNSメッセージを書き込む（長さプレフィックス付き）
  let dataLen = uint16(data.len)
  
  # 長さプレフィックスを作成
  var lenPrefix = newSeq[byte](DNS_TCP_MESSAGE_PREFIX_SIZE)
  bigEndian16(addr lenPrefix[0], unsafeAddr dataLen)
  
  # 長さプレフィックスを送信
  await socket.send(lenPrefix)
  
  # メッセージ本体を送信
  await socket.send(data)

# ドメイン名比較
proc compareDomainNames*(name1, name2: string): bool =
  ## ドメイン名を正規化して比較（大文字小文字を区別せず、末尾のドットを無視）
  var n1 = name1.toLowerAscii()
  var n2 = name2.toLowerAscii()
  
  if n1.endsWith('.'):
    n1 = n1[0..^2]
  
  if n2.endsWith('.'):
    n2 = n2[0..^2]
  
  return n1 == n2 