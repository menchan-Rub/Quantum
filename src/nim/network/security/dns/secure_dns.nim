# セキュアDNS (Secure DNS) モジュール
#
# このモジュールは、DNS over HTTPS (DoH) および DNS over TLS (DoT) 機能を提供します。
# 暗号化されたDNS通信を使用して、プライバシーとセキュリティを向上させます。

import std/[asyncdispatch, httpclient, uri, json, strutils, tables, options, sets, strformat, net, times, random, base64]
import ../../../logging
import ../../../config/config_manager

type
  SecureDnsProvider* = object
    name*: string              # プロバイダー名
    template*: string          # DoHテンプレートURL
    hostOverride*: string      # ホスト名オーバーライド
    resolvers*: seq[string]    # DoTリゾルバーリスト（ホスト:ポート）
    supportedProtocols*: set[SecureDnsProtocol]  # サポートするプロトコル
    pubKey*: string            # SPKI ハッシュ (PKIX-SHA256)
    description*: string       # 説明文

  SecureDnsProtocol* = enum
    sdpDnsOverHttps = "doh"    # DNS over HTTPS
    sdpDnsOverTls = "dot"      # DNS over TLS

  SecureDnsMode* = enum
    sdmAutomatic = "automatic"  # 自動（システム設定を使用し、利用可能な場合は暗号化）
    sdmSecure = "secure"        # 常に暗号化を使用
    sdmOff = "off"              # 暗号化なし

  ResolveStrategy* = enum
    rsSequential = "sequential"  # シーケンシャル解決（順番に試行）
    rsRandom = "random"          # ランダム解決
    rsRandomize = "randomize"    # 初回はランダムに選択し、その後はシーケンシャル

  DnsResponseStatus* = enum
    drsSuccess = "success"      # 成功
    drsFormatError = "format-error"  # 形式エラー
    drsServerFailure = "server-failure"  # サーバーエラー
    drsNameError = "name-error"  # 名前エラー（ドメインが存在しない）
    drsNotImplemented = "not-implemented"  # 未実装
    drsRefused = "refused"      # 拒否
    drsTimeout = "timeout"      # タイムアウト
    drsConnectionError = "connection-error"  # 接続エラー
    drsNetworkError = "network-error"  # ネットワークエラー
    drsUnknownError = "unknown-error"  # 不明なエラー

  DnsRecordType* = enum
    drtA = 1          # IPv4アドレス
    drtAAAA = 28      # IPv6アドレス
    drtCAA = 257      # 認証局認可
    drtCNAME = 5      # 正規名
    drtMX = 15        # メール交換
    drtNS = 2         # ネームサーバー
    drtPTR = 12       # ポインタ
    drtSOA = 6        # 権限の開始
    drtSRV = 33       # サービスロケーション
    drtTXT = 16       # テキスト
    drtTLSA = 52      # TLSA証明書関連付け

  DnsAnswer* = object
    name*: string        # ドメイン名
    recordType*: DnsRecordType  # レコードタイプ
    ttl*: int            # TTL
    data*: string        # データ

  DnsResponse* = object
    status*: DnsResponseStatus  # 応答ステータス
    answers*: seq[DnsAnswer]    # 応答のリスト
    queryTime*: int             # クエリ時間（ミリ秒）
    protocol*: SecureDnsProtocol  # 使用されたプロトコル

  SecureDnsConfig* = ref object
    mode*: SecureDnsMode        # セキュアDNSモード
    providers*: seq[SecureDnsProvider]  # プロバイダーリスト
    selectedProvider*: int      # 選択されたプロバイダーのインデックス
    resolveStrategy*: ResolveStrategy  # 解決戦略
    timeout*: int               # タイムアウト（ミリ秒）
    maxRetries*: int            # 最大再試行回数
    validateCertificates*: bool  # 証明書を検証するかどうか
    cacheResults*: bool         # 結果をキャッシュするかどうか
    cacheExpiry*: int           # キャッシュの有効期限（秒）
    customResolvers*: seq[string]  # カスタムリゾルバー

  SecureDnsManager* = ref object
    config*: SecureDnsConfig    # セキュアDNS設定
    dnsCache*: Table[string, tuple[expires: DateTime, response: DnsResponse]]  # DNSキャッシュ
    httpClient*: AsyncHttpClient  # HTTPクライアント
    currentQueriesCount*: int   # 現在のクエリ数
    maxConcurrentQueries*: int  # 最大同時クエリ数

# 既知のセキュアDNSプロバイダーのリスト
const KnownProviders*: seq[SecureDnsProvider] = @[
  SecureDnsProvider(
    name: "Google",
    template: "https://dns.google/dns-query{?dns}",
    hostOverride: "",
    resolvers: @["8.8.8.8:853", "8.8.4.4:853"],
    supportedProtocols: {sdpDnsOverHttps, sdpDnsOverTls},
    pubKey: "7cT8UVyJe9qMwQBUj+lvCBSdqBmq4XL5X8pSaB3WaQ4=",
    description: "Google Public DNS"
  ),
  SecureDnsProvider(
    name: "Cloudflare",
    template: "https://cloudflare-dns.com/dns-query{?dns}",
    hostOverride: "",
    resolvers: @["1.1.1.1:853", "1.0.0.1:853"],
    supportedProtocols: {sdpDnsOverHttps, sdpDnsOverTls},
    pubKey: "oJMRESz5E4gYzS/q6XDrvU1qMPYIjCWzwYRm3vUS/rc=",
    description: "Cloudflare DNS"
  ),
  SecureDnsProvider(
    name: "Quad9",
    template: "https://dns.quad9.net/dns-query{?dns}",
    hostOverride: "",
    resolvers: @["9.9.9.9:853", "149.112.112.112:853"],
    supportedProtocols: {sdpDnsOverHttps, sdpDnsOverTls},
    pubKey: "Ev2FMlHXnsJ+SFOWJHw3/EPOKcENLUKaNCMJwplGK/g=",
    description: "Quad9 (secure, filtered, DNSSEC)"
  ),
  SecureDnsProvider(
    name: "AdGuard",
    template: "https://dns.adguard.com/dns-query{?dns}",
    hostOverride: "",
    resolvers: @["94.140.14.14:853", "94.140.15.15:853"],
    supportedProtocols: {sdpDnsOverHttps, sdpDnsOverTls},
    pubKey: "qL+mKV+tlYG5CAvSAaj/yDCYADHPAIGI9Q5US2Gugpo=",
    description: "AdGuard DNS"
  )
]

# 新しいセキュアDNS設定を作成
proc newSecureDnsConfig*(
  mode: SecureDnsMode = sdmAutomatic,
  selectedProvider: int = 0,
  resolveStrategy: ResolveStrategy = rsRandomize,
  timeout: int = 5000,
  maxRetries: int = 3,
  validateCertificates: bool = true,
  cacheResults: bool = true,
  cacheExpiry: int = 300,
  customResolvers: seq[string] = @[]
): SecureDnsConfig =
  result = SecureDnsConfig(
    mode: mode,
    providers: KnownProviders,
    selectedProvider: selectedProvider,
    resolveStrategy: resolveStrategy,
    timeout: timeout,
    maxRetries: maxRetries,
    validateCertificates: validateCertificates,
    cacheResults: cacheResults,
    cacheExpiry: cacheExpiry,
    customResolvers: customResolvers
  )
  
  # プロバイダーが範囲外の場合、デフォルトに設定
  if result.selectedProvider < 0 or result.selectedProvider >= result.providers.len:
    result.selectedProvider = 0

# 新しいセキュアDNSマネージャーを作成
proc newSecureDnsManager*(config: SecureDnsConfig = nil): SecureDnsManager =
  let actualConfig = if config == nil: newSecureDnsConfig() else: config
  
  var headers = newHttpHeaders()
  headers["Accept"] = "application/dns-json, application/json, application/dns-message"
  
  result = SecureDnsManager(
    config: actualConfig,
    dnsCache: initTable[string, tuple[expires: DateTime, response: DnsResponse]](),
    httpClient: newAsyncHttpClient(userAgent = "Secure DNS Client", headers = headers),
    currentQueriesCount: 0,
    maxConcurrentQueries: 100
  )
  
  result.httpClient.timeout = actualConfig.timeout

# キャッシュキーを生成
proc generateCacheKey(domain: string, recordType: DnsRecordType): string =
  return domain & "-" & $ord(recordType)

# DoT用のDNSメッセージを作成
proc createDnsMessage(domain: string, recordType: DnsRecordType): string =
  result = ""
  # メッセージID (ランダム)
  let messageId = rand(0..65535)
  result.add(char(messageId shr 8))
  result.add(char(messageId and 0xFF))
  
  # フラグ (標準クエリ、再帰的)
  result.add(char(0x01))
  result.add(char(0x00))
  
  # 質問数 (1)
  result.add(char(0x00))
  result.add(char(0x01))
  
  # 回答RR (0)
  result.add(char(0x00))
  result.add(char(0x00))
  
  # 権限RR (0)
  result.add(char(0x00))
  result.add(char(0x00))
  
  # 追加RR (0)
  result.add(char(0x00))
  result.add(char(0x00))
  
  # ドメイン名のエンコード
  let labels = domain.split('.')
  for label in labels:
    result.add(char(label.len))
    result.add(label)
  result.add(char(0))
  
  # レコードタイプ
  result.add(char(0x00))
  result.add(char(ord(recordType)))
  
  # クラス (IN = 1)
  result.add(char(0x00))
  result.add(char(0x01))

# DoH用のDNSワイヤーフォーマットメッセージを作成してBase64エンコード
proc createDohMessage(domain: string, recordType: DnsRecordType): string =
  let dnsMessage = createDnsMessage(domain, recordType)
  return base64.encode(dnsMessage)

# DNS over HTTPS (DoH) を使用してドメインを解決
proc resolveDoh*(manager: SecureDnsManager, domain: string, recordType: DnsRecordType): Future[DnsResponse] {.async.} =
  let cacheKey = generateCacheKey(domain, recordType)
  
  # キャッシュから結果を取得
  if manager.config.cacheResults and manager.dnsCache.hasKey(cacheKey):
    let cached = manager.dnsCache[cacheKey]
    if cached.expires > now():
      return cached.response
    else:
      manager.dnsCache.del(cacheKey)
  
  result = DnsResponse(
    status: drsUnknownError,
    answers: @[],
    queryTime: 0,
    protocol: sdpDnsOverHttps
  )
  
  let provider = manager.config.providers[manager.config.selectedProvider]
  
  if sdpDnsOverHttps notin provider.supportedProtocols:
    log(lvlError, fmt"プロバイダー {provider.name} はDoHをサポートしていません")
    result.status = drsNotImplemented
    return result
  
  var url = provider.template
  if url.contains("{?dns}"):
    # RFC 8484 GET メソッド
    let dnsParam = createDohMessage(domain, recordType)
    url = url.replace("{?dns}", "?dns=" & dnsParam)
  
  let startTime = epochTime()
  
  try:
    inc(manager.currentQueriesCount)
    
    var response: AsyncResponse
    
    try:
      response = await manager.httpClient.get(url)
    except:
      result.status = drsConnectionError
      result.queryTime = int((epochTime() - startTime) * 1000)
      log(lvlError, fmt"DoH接続エラー: {getCurrentExceptionMsg()}")
      return result
    
    if response.code != Http200:
      result.status = drsServerFailure
      result.queryTime = int((epochTime() - startTime) * 1000)
      log(lvlError, fmt"DoHサーバーエラー、HTTPコード: {response.code}")
      return result
    
    let contentType = response.headers.getOrDefault("content-type")
    let body = await response.body
    
    if contentType.contains("application/dns-json") or contentType.contains("application/json"):
      # JSON応答のパース
      try:
        let jsonNode = parseJson(body)
        
        # ステータスコードのパース
        var status = drsSuccess
        if jsonNode.hasKey("Status"):
          let dnsStatus = jsonNode["Status"].getInt()
          status = case dnsStatus:
            of 0: drsSuccess
            of 1: drsFormatError
            of 2: drsServerFailure
            of 3: drsNameError
            of 4: drsNotImplemented
            of 5: drsRefused
            else: drsUnknownError
        
        result.status = status
        
        # 応答のパース
        if jsonNode.hasKey("Answer") and jsonNode["Answer"].kind == JArray:
          for answer in jsonNode["Answer"]:
            if answer.kind != JObject:
              continue
            
            let recordType = try:
              let typeValue = answer["type"].getInt()
              if typeValue in {ord(drtA)..ord(drtTLSA)}:
                DnsRecordType(typeValue)
              else:
                continue
            except:
              continue
            
            let dnsAnswer = DnsAnswer(
              name: if answer.hasKey("name"): answer["name"].getStr() else: domain,
              recordType: recordType,
              ttl: if answer.hasKey("TTL"): answer["TTL"].getInt() else: 0,
              data: if answer.hasKey("data"): answer["data"].getStr() else: ""
            )
            
            result.answers.add(dnsAnswer)
      except:
        result.status = drsFormatError
        log(lvlError, fmt"DoH応答のJSONパースエラー: {getCurrentExceptionMsg()}")
    else:
      # バイナリ応答のパース（実装は省略）
      result.status = drsNotImplemented
      log(lvlWarn, "DoHバイナリ応答パースは未実装です")
    
    result.queryTime = int((epochTime() - startTime) * 1000)
    
    # 成功した場合はキャッシュに追加
    if result.status == drsSuccess and manager.config.cacheResults:
      let expiry = now() + initDuration(seconds = manager.config.cacheExpiry)
      manager.dnsCache[cacheKey] = (expires: expiry, response: result)
    
  except:
    result.status = drsNetworkError
    result.queryTime = int((epochTime() - startTime) * 1000)
    log(lvlError, fmt"DoH解決エラー: {getCurrentExceptionMsg()}")
  
  finally:
    dec(manager.currentQueriesCount)

# DNS over TLS (DoT) を使用してドメインを解決
proc resolveDoT*(manager: SecureDnsManager, domain: string, recordType: DnsRecordType): Future[DnsResponse] {.async.} =
  inc(manager.currentQueriesCount)
  let startTime = epochTime()
  let provider = manager.config.providers[manager.config.selectedProvider]
  let cacheKey = generateCacheKey(domain, recordType)
  
  # キャッシュのチェック
  if manager.config.cacheResults and manager.dnsCache.hasKey(cacheKey):
    let cached = manager.dnsCache[cacheKey]
    if cached.expires > now():
      return cached.response
    else:
      manager.dnsCache.del(cacheKey)
  
  # 同時クエリ数の制限チェック
  if manager.currentQueriesCount > manager.config.maxConcurrentQueries:
    dec(manager.currentQueriesCount)
    return DnsResponse(
      status: drsThrottled,
      answers: @[],
      queryTime: 0,
      protocol: sdpDnsOverTls
    )
  
  result = DnsResponse(
    status: drsUnknownError,
    answers: @[],
    queryTime: 0,
    protocol: sdpDnsOverTls
  )
  
  try:
    # TLSコンテキストの設定
    let ctx = newContext(verifyMode = CVerifyPeer)
    if ctx.isNil:
      result.status = drsTlsError
      log(lvlError, "TLSコンテキストの作成に失敗しました")
      return
    
    # DoTサーバーへの接続
    let dotServer = provider.dotServer
    let dotPort = if provider.dotPort > 0: provider.dotPort else: 853
    
    var socket = newAsyncSocket()
    await socket.connect(dotServer, Port(dotPort))
    
    # TLSハンドシェイク
    var tlsSocket = newAsyncTlsSocket(socket, ctx, true)
    await tlsSocket.handshake()
    
    # DNSクエリの構築
    var dnsQuery = newDnsMessage()
    dnsQuery.header.id = uint16(rand(65535))
    dnsQuery.header.rd = 1  # 再帰的クエリを要求
    
    var question = DnsQuestion(
      name: domain,
      qtype: uint16(recordType),
      qclass: 1  # INクラス
    )
    dnsQuery.questions.add(question)
    
    # DNSメッセージをバイナリに変換
    let queryData = dnsQuery.serialize()
    
    # メッセージ長のプレフィックス（2バイト）を追加
    let queryLength = uint16(queryData.len)
    var lengthBytes = newSeq[byte](2)
    lengthBytes[0] = byte((queryLength shr 8) and 0xFF)
    lengthBytes[1] = byte(queryLength and 0xFF)
    
    # クエリの送信
    await tlsSocket.send(addr lengthBytes[0], 2)
    await tlsSocket.send(addr queryData[0], queryData.len)
    
    # 応答の受信
    var responseLengthBytes = newSeq[byte](2)
    let bytesReceived = await tlsSocket.recvInto(addr responseLengthBytes[0], 2)
    if bytesReceived != 2:
      result.status = drsNetworkError
      log(lvlError, "DoT応答長の受信に失敗しました")
      return
    
    let responseLength = (uint16(responseLengthBytes[0]) shl 8) or uint16(responseLengthBytes[1])
    var responseData = newSeq[byte](responseLength)
    let responseReceived = await tlsSocket.recvInto(addr responseData[0], responseLength.int)
    
    if responseReceived != responseLength.int:
      result.status = drsNetworkError
      log(lvlError, fmt"DoT応答データの受信に失敗しました: 期待={responseLength}, 実際={responseReceived}")
      return
    
    # DNSメッセージのパース
    let dnsResponse = parseDnsMessage(responseData)
    
    # レスポンスコードの確認
    let rcode = dnsResponse.header.rcode
    let status = case rcode
      of 0: drsSuccess
      of 1: drsFormatError
      of 2: drsServerFailure
      of 3: drsNameError
      of 4: drsNotImplemented
      of 5: drsRefused
      else: drsUnknownError
    
    result.status = status
    
    # 応答レコードの処理
    for answer in dnsResponse.answers:
      let recordType = try:
        if answer.atype.int in {ord(drtA)..ord(drtTLSA)}:
          DnsRecordType(answer.atype.int)
        else:
          continue
      except:
        continue
      
      let dnsAnswer = DnsAnswer(
        name: answer.name,
        recordType: recordType,
        ttl: answer.ttl.int,
        data: answer.rdata.toString(recordType)
      )
      
      result.answers.add(dnsAnswer)
    
    # 接続のクローズ
    tlsSocket.close()
    socket.close()
    
    result.queryTime = int((epochTime() - startTime) * 1000)
    
    # 成功した場合はキャッシュに追加
    if result.status == drsSuccess and manager.config.cacheResults:
      let expiry = now() + initDuration(seconds = manager.config.cacheExpiry)
      manager.dnsCache[cacheKey] = (expires: expiry, response: result)
    
  except CatchableError as e:
    result.status = drsNetworkError
    result.queryTime = int((epochTime() - startTime) * 1000)
    log(lvlError, fmt"DoT解決エラー: {e.msg}")
  
  finally:
    dec(manager.currentQueriesCount)

# セキュアDNSを使用してドメインを解決
proc resolve*(
  manager: SecureDnsManager,
  domain: string,
  recordType: DnsRecordType = drtA,
  forceSecure: bool = false
): Future[DnsResponse] {.async.} =
  # キャッシュのチェック
  let cacheKey = generateCacheKey(domain, recordType)
  if manager.config.cacheResults and manager.dnsCache.hasKey(cacheKey):
    let cached = manager.dnsCache[cacheKey]
    if cached.expires > now():
      return cached.response
    else:
      manager.dnsCache.del(cacheKey)
  
  # モードがオフの場合、システムのDNSリゾルバーを使用
  if manager.config.mode == sdmOff and not forceSecure:
    # ここではサポートされていないため、エラーを返す
    return DnsResponse(
      status: drsNotImplemented,
      answers: @[],
      queryTime: 0,
      protocol: sdpDnsOverHttps
    )
  
  # 選択されたプロバイダーを使用してドメインを解決
  let provider = manager.config.providers[manager.config.selectedProvider]
  
  # DoH優先、次にDoT
  if sdpDnsOverHttps in provider.supportedProtocols:
    return await manager.resolveDoh(domain, recordType)
  elif sdpDnsOverTls in provider.supportedProtocols:
    return await manager.resolveDoT(domain, recordType)
  else:
    return DnsResponse(
      status: drsNotImplemented,
      answers: @[],
      queryTime: 0,
      protocol: sdpDnsOverHttps
    )

# IPアドレスを解決
proc resolveIPAddresses*(
  manager: SecureDnsManager,
  domain: string,
  preferIPv6: bool = false
): Future[seq[string]] {.async.} =
  var addresses: seq[string] = @[]
  
  if preferIPv6:
    # IPv6アドレスを解決
    let aaaaResponse = await manager.resolve(domain, drtAAAA)
    if aaaaResponse.status == drsSuccess:
      for answer in aaaaResponse.answers:
        if answer.recordType == drtAAAA:
          addresses.add(answer.data)
  
  # IPv4アドレスを解決
  let aResponse = await manager.resolve(domain, drtA)
  if aResponse.status == drsSuccess:
    for answer in aResponse.answers:
      if answer.recordType == drtA:
        addresses.add(answer.data)
  
  # IPv6アドレスが優先されていない場合、両方のIPバージョンが混ざる
  # IPv6アドレスが優先される場合、IPv6アドレスが先に追加される
  
  return addresses

# プロバイダーを追加
proc addProvider*(manager: SecureDnsManager, provider: SecureDnsProvider) =
  manager.config.providers.add(provider)
  log(lvlInfo, fmt"セキュアDNSプロバイダーを追加しました: {provider.name}")

# プロバイダーを削除
proc removeProvider*(manager: SecureDnsManager, index: int) =
  if index >= 0 and index < manager.config.providers.len:
    let name = manager.config.providers[index].name
    manager.config.providers.delete(index)
    
    # 選択されたプロバイダーが削除された場合、インデックスを調整
    if index == manager.config.selectedProvider:
      manager.config.selectedProvider = 0
    elif index < manager.config.selectedProvider:
      dec(manager.config.selectedProvider)
    
    log(lvlInfo, fmt"セキュアDNSプロバイダーを削除しました: {name}")

# プロバイダーを選択
proc selectProvider*(manager: SecureDnsManager, index: int) =
  if index >= 0 and index < manager.config.providers.len:
    manager.config.selectedProvider = index
    let name = manager.config.providers[index].name
    log(lvlInfo, fmt"セキュアDNSプロバイダーを選択しました: {name}")

# 設定をJSONに変換
proc toJson*(config: SecureDnsConfig): JsonNode =
  result = newJObject()
  result["mode"] = %($config.mode)
  result["selected_provider"] = %config.selectedProvider
  result["resolve_strategy"] = %($config.resolveStrategy)
  result["timeout"] = %config.timeout
  result["max_retries"] = %config.maxRetries
  result["validate_certificates"] = %config.validateCertificates
  result["cache_results"] = %config.cacheResults
  result["cache_expiry"] = %config.cacheExpiry
  
  var providersArray = newJArray()
  for provider in config.providers:
    var providerObj = newJObject()
    providerObj["name"] = %provider.name
    providerObj["template"] = %provider.template
    providerObj["host_override"] = %provider.hostOverride
    
    var resolversArray = newJArray()
    for resolver in provider.resolvers:
      resolversArray.add(%resolver)
    providerObj["resolvers"] = resolversArray
    
    var protocolsArray = newJArray()
    for protocol in provider.supportedProtocols:
      protocolsArray.add(%($protocol))
    providerObj["supported_protocols"] = protocolsArray
    
    providerObj["pub_key"] = %provider.pubKey
    providerObj["description"] = %provider.description
    
    providersArray.add(providerObj)
  
  result["providers"] = providersArray
  
  var customResolversArray = newJArray()
  for resolver in config.customResolvers:
    customResolversArray.add(%resolver)
  
  result["custom_resolvers"] = customResolversArray

# JSONから設定を作成
proc fromJson*(jsonNode: JsonNode): SecureDnsConfig =
  if jsonNode.kind != JObject:
    return newSecureDnsConfig()
  
  result = newSecureDnsConfig()
  
  if jsonNode.hasKey("mode"):
    try:
      result.mode = parseEnum[SecureDnsMode](jsonNode["mode"].getStr())
    except:
      discard
  
  if jsonNode.hasKey("selected_provider"):
    try:
      result.selectedProvider = jsonNode["selected_provider"].getInt()
    except:
      discard
  
  if jsonNode.hasKey("resolve_strategy"):
    try:
      result.resolveStrategy = parseEnum[ResolveStrategy](jsonNode["resolve_strategy"].getStr())
    except:
      discard
  
  if jsonNode.hasKey("timeout"):
    try:
      result.timeout = jsonNode["timeout"].getInt()
    except:
      discard
  
  if jsonNode.hasKey("max_retries"):
    try:
      result.maxRetries = jsonNode["max_retries"].getInt()
    except:
      discard
  
  if jsonNode.hasKey("validate_certificates"):
    try:
      result.validateCertificates = jsonNode["validate_certificates"].getBool()
    except:
      discard
  
  if jsonNode.hasKey("cache_results"):
    try:
      result.cacheResults = jsonNode["cache_results"].getBool()
    except:
      discard
  
  if jsonNode.hasKey("cache_expiry"):
    try:
      result.cacheExpiry = jsonNode["cache_expiry"].getInt()
    except:
      discard
  
  # プロバイダーの読み込み
  if jsonNode.hasKey("providers") and jsonNode["providers"].kind == JArray:
    var providers: seq[SecureDnsProvider] = @[]
    
    for item in jsonNode["providers"]:
      if item.kind != JObject:
        continue
      
      var provider = SecureDnsProvider()
      
      if item.hasKey("name"):
        provider.name = item["name"].getStr()
      
      if item.hasKey("template"):
        provider.template = item["template"].getStr()
      
      if item.hasKey("host_override"):
        provider.hostOverride = item["host_override"].getStr()
      
      if item.hasKey("resolvers") and item["resolvers"].kind == JArray:
        provider.resolvers = @[]
        for resolver in item["resolvers"]:
          provider.resolvers.add(resolver.getStr())
      
      if item.hasKey("supported_protocols") and item["supported_protocols"].kind == JArray:
        provider.supportedProtocols = {}
        for protocolItem in item["supported_protocols"]:
          try:
            let protocol = parseEnum[SecureDnsProtocol](protocolItem.getStr())
            provider.supportedProtocols.incl(protocol)
          except:
            discard
      
      if item.hasKey("pub_key"):
        provider.pubKey = item["pub_key"].getStr()
      
      if item.hasKey("description"):
        provider.description = item["description"].getStr()
      
      providers.add(provider)
    
    # 少なくとも1つのプロバイダーがある場合に更新
    if providers.len > 0:
      result.providers = providers
  
  # カスタムリゾルバーの読み込み
  if jsonNode.hasKey("custom_resolvers") and jsonNode["custom_resolvers"].kind == JArray:
    result.customResolvers = @[]
    for resolver in jsonNode["custom_resolvers"]:
      result.customResolvers.add(resolver.getStr())
  
  # 選択されたプロバイダーが範囲内かチェック
  if result.selectedProvider < 0 or result.selectedProvider >= result.providers.len:
    result.selectedProvider = 0

# 設定を保存
proc saveConfig*(manager: SecureDnsManager, configPath: string): bool =
  try:
    let jsonNode = manager.config.toJson()
    let jsonStr = pretty(jsonNode)
    writeFile(configPath, jsonStr)
    log(lvlInfo, fmt"セキュアDNS設定を保存しました: {configPath}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"セキュアDNS設定の保存に失敗しました: {msg}")
    return false

# 設定を読み込み
proc loadConfig*(manager: SecureDnsManager, configPath: string): bool =
  if not fileExists(configPath):
    log(lvlWarn, fmt"セキュアDNS設定ファイルが存在しません: {configPath}")
    return false
  
  try:
    let jsonContent = readFile(configPath)
    let jsonNode = parseJson(jsonContent)
    manager.config = fromJson(jsonNode)
    
    # HTTPクライアントのタイムアウトを更新
    manager.httpClient.timeout = manager.config.timeout
    
    log(lvlInfo, fmt"セキュアDNS設定を読み込みました: {configPath}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"セキュアDNS設定の読み込みに失敗しました: {msg}")
    return false

# キャッシュをクリア
proc clearCache*(manager: SecureDnsManager) =
  manager.dnsCache.clear()
  log(lvlInfo, "セキュアDNSキャッシュをクリアしました")

# モードを設定
proc setMode*(manager: SecureDnsManager, mode: SecureDnsMode) =
  manager.config.mode = mode
  log(lvlInfo, fmt"セキュアDNSモードを設定しました: {mode}")

# TXTレコードを取得
proc resolveTxtRecords*(
  manager: SecureDnsManager,
  domain: string
): Future[seq[string]] {.async.} =
  var txtRecords: seq[string] = @[]
  
  let response = await manager.resolve(domain, drtTXT)
  if response.status == drsSuccess:
    for answer in response.answers:
      if answer.recordType == drtTXT:
        txtRecords.add(answer.data)
  
  return txtRecords

# MXレコードを取得
proc resolveMxRecords*(
  manager: SecureDnsManager,
  domain: string
): Future[seq[tuple[priority: int, target: string]]] {.async.} =
  var mxRecords: seq[tuple[priority: int, target: string]] = @[]
  
  let response = await manager.resolve(domain, drtMX)
  if response.status == drsSuccess:
    for answer in response.answers:
      if answer.recordType == drtMX:
        try:
          let parts = answer.data.split(' ', 1)
          if parts.len == 2:
            let priority = parseInt(parts[0])
            let target = parts[1]
            mxRecords.add((priority: priority, target: target))
        except:
          discard
  
  # 優先度でソート
  mxRecords.sort(proc(x, y: tuple[priority: int, target: string]): int =
    return cmp(x.priority, y.priority)
  )
  
  return mxRecords

# レスポンスをJSONに変換
proc toJson*(response: DnsResponse): JsonNode =
  result = newJObject()
  result["status"] = %($response.status)
  result["query_time"] = %response.queryTime
  result["protocol"] = %($response.protocol)
  
  var answersArray = newJArray()
  for answer in response.answers:
    var answerObj = newJObject()
    answerObj["name"] = %answer.name
    answerObj["record_type"] = %($answer.recordType)
    answerObj["ttl"] = %answer.ttl
    answerObj["data"] = %answer.data
    answersArray.add(answerObj)
  
  result["answers"] = answersArray 