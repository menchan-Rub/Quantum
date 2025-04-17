import std/[asyncdispatch, httpclient, httpcore, tables, strutils, uri, options, times, 
         streams, net, os, logging, json, parseutils, strformat, unicode, random, 
         math, sequtils, algorithm, deques, base64, sha1, md5, sets, mimetypes]
import ./core
import ../utils
import ../headers
import ../../dns/resolver

const
  MaxCacheSize* = 100 * 1024 * 1024  # 100MB
  MaxCacheEntries* = 1000
  DefaultCacheTTL* = 60 * 60 * 24    # 24時間（秒単位）

type
  HttpClientAdvanced* = ref object
    core*: HttpClientCore
    retryConfig*: RetryConfig
    cacheManager*: CacheManager
    securityConfig*: SecurityConfig
    redirectHandler*: RedirectHandler
    compressionSettings*: CompressionSettings
    interceptors*: seq[RequestInterceptor]
    metrics*: ClientMetrics
    debugMode*: bool
    
  RetryConfig* = object
    maxRetries*: int
    retryDelay*: int  # ミリ秒
    retryStatusCodes*: set[int]
    retryMethods*: set[HttpMethod]
    exponentialBackoff*: bool
    jitterFactor*: float
    retryOnNetworkError*: bool
    
  CacheManager* = ref object
    enabled*: bool
    cacheDir*: string
    entries*: Table[string, CacheEntry]
    totalSize*: int64
    maxSize*: int64
    maxEntries*: int
    defaultTTL*: int
    
  CacheEntry* = object
    url*: string
    statusCode*: int
    headers*: HttpHeaders
    body*: string
    expires*: Time
    lastAccessed*: Time
    size*: int64
    etag*: string
    lastModified*: string
    
  SecurityConfig* = object
    validateSsl*: bool
    validateHost*: bool
    minTlsVersion*: TlsVersion
    verifyPeers*: bool
    certPinning*: Table[string, seq[string]]
    secureOnly*: bool
    userAgentOverride*: string
    
  RedirectHandler* = object
    followRedirects*: bool
    maxRedirects*: int
    preserveMethod*: bool
    allowedHosts*: HashSet[string]
    allowedSchemes*: HashSet[string]
    
  CompressionSettings* = object
    enabled*: bool
    acceptEncoding*: string
    autoDecompress*: bool
    compressRequests*: bool
    minSizeToCompress*: int
    
  RequestInterceptor* = object
    phase*: InterceptorPhase
    callback*: proc(req: var HttpRequest, res: var HttpResponse): Future[bool] {.async.}
    
  InterceptorPhase* = enum
    ipBeforeRequest, ipAfterResponse, ipBeforeRetry, ipOnError
    
  HttpRequest* = object
    url*: string
    method*: HttpMethod
    headers*: HttpHeaders
    body*: string
    options*: RequestOptions
    
  HttpResponse* = object
    statusCode*: int
    headers*: HttpHeaders
    body*: string
    url*: string
    contentType*: string
    error*: string
    
  ClientMetrics* = object
    requestCount*: int
    errorCount*: int
    retryCount*: int
    cacheHits*: int
    cacheMisses*: int
    totalBytesDownloaded*: int64
    totalBytesUploaded*: int64
    requestTimes*: Table[string, seq[float]]  # URLパターン別の時間
    
  CachePolicy* = enum
    cpNoStore,     # キャッシュしない
    cpDefault,     # 標準的な動作
    cpForceCache,  # 可能な限りキャッシュを使用
    cpReload,      # 常に再検証
    cpNoCache      # 使用前に再検証

proc newHttpClientAdvanced*(): HttpClientAdvanced =
  ## 高度なHTTPクライアントを作成
  result = HttpClientAdvanced()
  result.core = newHttpClientCore()
  
  # リトライ設定
  result.retryConfig.maxRetries = 3
  result.retryConfig.retryDelay = 1000  # 1秒
  result.retryConfig.retryStatusCodes = {408, 429, 500, 502, 503, 504}
  result.retryConfig.retryMethods = {HttpGet, HttpHead, HttpOptions}
  result.retryConfig.exponentialBackoff = true
  result.retryConfig.jitterFactor = 0.2
  result.retryConfig.retryOnNetworkError = true
  
  # キャッシュマネージャー
  result.cacheManager = CacheManager()
  result.cacheManager.enabled = true
  result.cacheManager.cacheDir = getTempDir() / "http_cache"
  result.cacheManager.entries = initTable[string, CacheEntry]()
  result.cacheManager.totalSize = 0
  result.cacheManager.maxSize = MaxCacheSize
  result.cacheManager.maxEntries = MaxCacheEntries
  result.cacheManager.defaultTTL = DefaultCacheTTL
  
  # セキュリティ設定
  result.securityConfig.validateSsl = true
  result.securityConfig.validateHost = true
  result.securityConfig.minTlsVersion = tlsV12
  result.securityConfig.verifyPeers = true
  result.securityConfig.certPinning = initTable[string, seq[string]]()
  result.securityConfig.secureOnly = false
  
  # リダイレクト設定
  result.redirectHandler.followRedirects = true
  result.redirectHandler.maxRedirects = 10
  result.redirectHandler.preserveMethod = false
  result.redirectHandler.allowedHosts = initHashSet[string]()
  result.redirectHandler.allowedSchemes = ["http", "https"].toHashSet
  
  # 圧縮設定
  result.compressionSettings.enabled = true
  result.compressionSettings.acceptEncoding = "gzip, deflate"
  result.compressionSettings.autoDecompress = true
  result.compressionSettings.compressRequests = true
  result.compressionSettings.minSizeToCompress = 1024  # 1KB以上の場合のみ圧縮
  
  # インターセプター
  result.interceptors = @[]
  
  # メトリクス
  result.metrics = ClientMetrics()
  result.metrics.requestTimes = initTable[string, seq[float]]()
  
  # デバッグモード
  result.debugMode = false

proc createCacheKey(url: string, headers: HttpHeaders): string =
  ## キャッシュのキーを作成
  var headerStr = ""
  for key, val in headers:
    if key in ["Cache-Control", "Pragma", "Vary"]:
      headerStr &= key & ":" & val.join(",") & "|"
  
  # URLとヘッダーのハッシュを生成
  var ctx: SHA1
  ctx.init()
  ctx.update(url)
  ctx.update(headerStr)
  return $ctx.final()

proc isCacheable(method: HttpMethod, statusCode: int, reqHeaders: HttpHeaders, resHeaders: HttpHeaders): bool =
  ## レスポンスがキャッシュ可能かどうかを判断
  # GETとHEADメソッドのみをキャッシュ
  if method != HttpGet and method != HttpHead:
    return false
  
  # 成功レスポンスと特定のリダイレクトのみをキャッシュ
  if statusCode notin {200, 203, 204, 206, 300, 301, 404, 405, 410, 414, 501}:
    return false
  
  # Cache-Controlヘッダーをチェック
  if "Cache-Control" in resHeaders:
    let cacheControl = resHeaders["Cache-Control"][0].toLowerAscii()
    if "no-store" in cacheControl:
      return false
    if "private" in cacheControl and "Authorization" in reqHeaders:
      return false
  
  # Pragma: no-cacheをチェック
  if "Pragma" in resHeaders and "no-cache" in resHeaders["Pragma"][0].toLowerAscii():
    return false
  
  return true

proc calculateExpiry(resHeaders: HttpHeaders, defaultTTL: int): Time =
  ## キャッシュの有効期限を計算
  let now = getTime()
  
  # Cache-Controlのmax-ageを確認
  if "Cache-Control" in resHeaders:
    let cacheControl = resHeaders["Cache-Control"][0]
    let maxAgePos = cacheControl.find("max-age=")
    if maxAgePos >= 0:
      let maxAgeStart = maxAgePos + 8
      var maxAgeEnd = cacheControl.len
      for i in maxAgeStart..<cacheControl.len:
        if cacheControl[i] in [',', ' ', ';']:
          maxAgeEnd = i
          break
      try:
        let maxAge = parseInt(cacheControl[maxAgeStart..<maxAgeEnd])
        return now + initDuration(seconds = maxAge)
      except:
        discard
  
  # Expiresヘッダーを確認
  if "Expires" in resHeaders:
    try:
      let expiresTime = parse(resHeaders["Expires"][0], "ddd, dd MMM yyyy HH:mm:ss 'GMT'")
      let expiresDate = dateTime(expiresTime.year, expiresTime.month, expiresTime.monthday, 
                              expiresTime.hour, expiresTime.minute, expiresTime.second)
      return toTime(expiresDate)
    except:
      discard
  
  # デフォルトのTTLを使用
  return now + initDuration(seconds = defaultTTL)

proc cachePut*(client: HttpClientAdvanced, url: string, statusCode: int, 
              reqHeaders: HttpHeaders, resHeaders: HttpHeaders, body: string) =
  ## キャッシュにレスポンスを保存
  if not client.cacheManager.enabled:
    return
  
  let cacheKey = createCacheKey(url, reqHeaders)
  let size = body.len.int64
  
  var entry = CacheEntry()
  entry.url = url
  entry.statusCode = statusCode
  entry.headers = resHeaders
  entry.body = body
  entry.expires = calculateExpiry(resHeaders, client.cacheManager.defaultTTL)
  entry.lastAccessed = getTime()
  entry.size = size
  
  # ETagとLast-Modifiedを保存
  if "ETag" in resHeaders:
    entry.etag = resHeaders["ETag"][0]
  if "Last-Modified" in resHeaders:
    entry.lastModified = resHeaders["Last-Modified"][0]
  
  # キャッシュが上限に達している場合は古いエントリを削除
  if client.cacheManager.entries.len >= client.cacheManager.maxEntries or
     client.cacheManager.totalSize + size > client.cacheManager.maxSize:
    # 最も古いエントリを削除
    var oldestTime = high(Time)
    var oldestKey = ""
    
    for key, e in client.cacheManager.entries:
      if e.lastAccessed < oldestTime:
        oldestTime = e.lastAccessed
        oldestKey = key
    
    if oldestKey.len > 0:
      client.cacheManager.totalSize -= client.cacheManager.entries[oldestKey].size
      client.cacheManager.entries.del(oldestKey)
  
  # キャッシュに追加
  client.cacheManager.entries[cacheKey] = entry
  client.cacheManager.totalSize += size

proc cacheGet*(client: HttpClientAdvanced, url: string, headers: HttpHeaders): Option[CacheEntry] =
  ## キャッシュからレスポンスを取得
  if not client.cacheManager.enabled:
    return none(CacheEntry)
  
  let cacheKey = createCacheKey(url, headers)
  if cacheKey notin client.cacheManager.entries:
    return none(CacheEntry)
  
  var entry = client.cacheManager.entries[cacheKey]
  let now = getTime()
  
  # 有効期限をチェック
  if now > entry.expires:
    return none(CacheEntry)
  
  # 最終アクセス時間を更新
  entry.lastAccessed = now
  client.cacheManager.entries[cacheKey] = entry
  
  return some(entry)

proc addInterceptor*(client: HttpClientAdvanced, phase: InterceptorPhase, 
                    callback: proc(req: var HttpRequest, res: var HttpResponse): Future[bool] {.async.}) =
  ## リクエストインターセプターを追加
  client.interceptors.add(RequestInterceptor(phase: phase, callback: callback))

proc compressBody*(body: string, encoding: string = "gzip"): string =
  ## ボディを圧縮
  if encoding.toLowerAscii() == "gzip":
    return compress(body, DefaultCompression, dfGzip)
  elif encoding.toLowerAscii() == "deflate":
    return compress(body, DefaultCompression, dfDeflate)
  else:
    return body

proc decompressBody*(body: string, encoding: string): string =
  ## ボディを解凍
  try:
    if encoding.toLowerAscii() == "gzip" or encoding.toLowerAscii() == "deflate":
      return uncompress(body)
    else:
      return body
  except:
    return body

proc calculateDelay(baseDelay: int, retryCount: int, exponential: bool, jitterFactor: float): int =
  ## リトライ間の遅延を計算
  if not exponential:
    result = baseDelay
  else:
    result = baseDelay * (2 ^ retryCount)
  
  # ジッターを追加して同時リトライを防ぐ
  if jitterFactor > 0:
    let jitter = float(result) * jitterFactor
    result += rand(int(jitter * 2)) - int(jitter)
  
  # 負の値にならないようにする
  if result < 0:
    result = 0

proc addCertificatePinning*(client: HttpClientAdvanced, host: string, pins: seq[string]) =
  ## 証明書ピンニングを追加
  client.securityConfig.certPinning[host] = pins

proc getContentType*(headers: HttpHeaders): string =
  ## Content-Typeヘッダーから型を取得
  if "Content-Type" in headers:
    let contentType = headers["Content-Type"][0]
    let semicolonPos = contentType.find(';')
    if semicolonPos >= 0:
      return contentType[0..<semicolonPos].strip()
    else:
      return contentType.strip()
  else:
    return ""

proc getContentTypeAndCharset*(headers: HttpHeaders): tuple[contentType: string, charset: string] =
  ## Content-Typeからタイプと文字セットを取得
  if "Content-Type" in headers:
    let contentType = headers["Content-Type"][0]
    let semicolonPos = contentType.find(';')
    
    if semicolonPos >= 0:
      let mainType = contentType[0..<semicolonPos].strip()
      let params = contentType[semicolonPos+1..^1]
      
      let charsetPos = params.toLowerAscii().find("charset=")
      if charsetPos >= 0:
        var charsetStart = charsetPos + 8
        var charsetEnd = params.len
        
        # 引用符を処理
        if params[charsetStart] == '"':
          charsetStart += 1
          for i in charsetStart..<params.len:
            if params[i] == '"':
              charsetEnd = i
              break
        else:
          for i in charsetStart..<params.len:
            if params[i] in [';', ' ']:
              charsetEnd = i
              break
        
        let charset = params[charsetStart..<charsetEnd].strip()
        return (mainType, charset)
      else:
        return (mainType, "")
    else:
      return (contentType.strip(), "")
  else:
    return ("", "")

proc isRedirect(statusCode: int): bool =
  ## リダイレクトのステータスコードかどうかを確認
  return statusCode in {301, 302, 303, 307, 308}

proc applySecurityConfig*(client: HttpClientAdvanced) =
  ## セキュリティ設定を適用
  
  # SSLコンテキストの設定
  when defined(ssl):
    var sslContext = newContext(verifyMode = (if client.securityConfig.validateSsl: CVerifyPeer else: CVerifyNone))
    
    # TLSバージョンの制限
    case client.securityConfig.minTlsVersion
    of tlsV10:
      sslContext.minProtocolVersion = TLSv1
    of tlsV11:
      sslContext.minProtocolVersion = TLSv1_1
    of tlsV12:
      sslContext.minProtocolVersion = TLSv1_2
    of tlsV13:
      sslContext.minProtocolVersion = TLSv1_3
    else:
      sslContext.minProtocolVersion = TLSv1_2
    
    # 安全な暗号スイートの設定
    sslContext.cipherList = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
    
    client.core.sslContext = sslContext

proc shouldRetry*(client: HttpClientAdvanced, method: HttpMethod, statusCode: int, attempt: int): bool =
  ## リトライすべきかどうかを判断
  if attempt >= client.retryConfig.maxRetries:
    return false
  
  if method notin client.retryConfig.retryMethods:
    return false
  
  if statusCode in client.retryConfig.retryStatusCodes:
    return true
  
  return false

proc extractHostname*(url: string): string =
  ## URLからホスト名を抽出
  try:
    let uri = parseUri(url)
    return uri.hostname
  except:
    return ""

proc updateMetrics*(client: HttpClientAdvanced, url: string, statusCode: int, 
                   requestTime: float, downloadBytes: int64, uploadBytes: int64, 
                   isError: bool, isRetry: bool, isCacheHit: bool) =
  ## メトリクスを更新
  # リクエスト数を更新
  client.metrics.requestCount += 1
  
  # エラー数を更新
  if isError:
    client.metrics.errorCount += 1
  
  # リトライ数を更新
  if isRetry:
    client.metrics.retryCount += 1
  
  # キャッシュヒットを更新
  if isCacheHit:
    client.metrics.cacheHits += 1
  else:
    client.metrics.cacheMisses += 1
  
  # 転送バイト数を更新
  client.metrics.totalBytesDownloaded += downloadBytes
  client.metrics.totalBytesUploaded += uploadBytes
  
  # リクエスト時間を記録
  # URLパターン別に集計するための簡易パターン化（例：ドメイン別）
  let hostname = extractHostname(url)
  if hostname notin client.metrics.requestTimes:
    client.metrics.requestTimes[hostname] = @[]
  
  client.metrics.requestTimes[hostname].add(requestTime)
  
  # 最大100エントリまで保持
  if client.metrics.requestTimes[hostname].len > 100:
    client.metrics.requestTimes[hostname].delete(0)

proc runInterceptors*(client: HttpClientAdvanced, phase: InterceptorPhase, 
                     req: var HttpRequest, res: var HttpResponse): Future[bool] {.async.} =
  ## 指定フェーズのインターセプターを実行
  result = true
  
  for interceptor in client.interceptors:
    if interceptor.phase == phase:
      try:
        let continueExecution = await interceptor.callback(req, res)
        if not continueExecution:
          return false
      except:
        if client.debugMode:
          echo "インターセプター実行中にエラーが発生しました: " & getCurrentExceptionMsg()
        # エラーが発生しても他のインターセプターは続行
        continue

proc request*(client: HttpClientAdvanced, url: string, httpMethod: HttpMethod, 
             body: string = "", headers: HttpHeaders = nil, 
             cachePolicy: CachePolicy = cpDefault): Future[HttpResponse] {.async.} =
  ## 高度なリクエスト処理
  var req = HttpRequest(
    url: url,
    method: httpMethod,
    headers: if headers != nil: headers else: newHttpHeaders(),
    body: body,
    options: RequestOptions()
  )
  
  var res = HttpResponse(
    statusCode: 0,
    headers: newHttpHeaders(),
    body: "",
    url: url,
    contentType: "",
    error: ""
  )
  
  # インターセプターの実行（リクエスト前）
  let shouldContinue = await client.runInterceptors(ipBeforeRequest, req, res)
  if not shouldContinue:
    return res
  
  # セキュリティ設定の適用
  if client.securityConfig.secureOnly and not url.startsWith("https://"):
    res.statusCode = 0
    res.error = "セキュリティポリシーによりHTTPSのみが許可されています"
    discard await client.runInterceptors(ipOnError, req, res)
    return res
  
  # User-Agentオーバーライドの適用
  if client.securityConfig.userAgentOverride.len > 0:
    req.headers["User-Agent"] = client.securityConfig.userAgentOverride
  
  # 圧縮設定の適用
  if client.compressionSettings.enabled:
    req.headers["Accept-Encoding"] = client.compressionSettings.acceptEncoding
  
  # キャッシュ制御
  case cachePolicy
  of cpNoStore:
    req.headers["Cache-Control"] = "no-store"
  of cpForceCache:
    # キャッシュからのみ取得を試みる
    if httpMethod == HttpGet or httpMethod == HttpHead:
      let cacheEntry = client.cacheGet(url, req.headers)
      if cacheEntry.isSome:
        let entry = cacheEntry.get()
        res.statusCode = entry.statusCode
        res.headers = entry.headers
        res.body = entry.body
        res.url = entry.url
        res.contentType = getContentType(entry.headers)
        
        # メトリクスを更新
        client.updateMetrics(url, res.statusCode, 0.0, entry.body.len.int64, 0, false, false, true)
        
        # インターセプターの実行（レスポンス後）
        discard await client.runInterceptors(ipAfterResponse, req, res)
        return res
      else:
        res.statusCode = 504  # Gateway Timeout
        res.error = "キャッシュにエントリがなく、ネットワーク取得が無効です"
        discard await client.runInterceptors(ipOnError, req, res)
        return res
  of cpReload:
    req.headers["Cache-Control"] = "no-cache"
  of cpNoCache:
    req.headers["Cache-Control"] = "max-age=0"
  else:
    # デフォルト動作
    discard
  
  # リクエストボディの圧縮
  if client.compressionSettings.compressRequests and body.len >= client.compressionSettings.minSizeToCompress:
    let compressedBody = compressBody(body)
    if compressedBody.len < body.len:
      req.body = compressedBody
      req.headers["Content-Encoding"] = "gzip"
  
  # リクエスト実行（リトライ処理付き）
  var attempt = 0
  let startTime = epochTime()
  
  while true:
    try:
      # 実際のリクエストを実行
      let response = await client.core.request(
        req.url, 
        req.method, 
        req.body, 
        req.headers
      )
      
      # レスポンス処理
      res.statusCode = response.code.int
      res.headers = response.headers
      res.body = response.body
      res.url = req.url
      
      # Content-Typeの解析
      let (contentType, charset) = getContentTypeAndCharset(response.headers)
      res.contentType = contentType
      
      # リダイレクト処理
      if isRedirect(res.statusCode) and client.redirectHandler.followRedirects:
        if "Location" in res.headers:
          let redirectUrl = res.headers["Location"][0]
          let absoluteUrl = if redirectUrl.startsWith("http"): redirectUrl else: combineUrl(req.url, redirectUrl)
          
          # リダイレクト制限のチェック
          let redirectHost = extractHostname(absoluteUrl)
          let origHost = extractHostname(req.url)
          
          # ホスト制限のチェック
          if client.redirectHandler.allowedHosts.len > 0 and redirectHost notin client.redirectHandler.allowedHosts:
            res.error = "リダイレクト先のホストが許可リストにありません: " & redirectHost
            break
          
          # スキーム制限のチェック
          let scheme = parseUri(absoluteUrl).scheme
          if scheme notin client.redirectHandler.allowedSchemes:
            res.error = "リダイレクト先のスキームが許可されていません: " & scheme
            break
          
          # メソッド保持の設定
          let redirectMethod = if client.redirectHandler.preserveMethod or res.statusCode == 307 or res.statusCode == 308: 
                              req.method else: HttpGet
          
          # リダイレクト回数のチェック
          if attempt >= client.redirectHandler.maxRedirects:
            res.error = "最大リダイレクト回数を超えました"
            break
          
          # リダイレクト先へのリクエスト準備
          req.url = absoluteUrl
          req.method = redirectMethod
          if redirectMethod == HttpGet or redirectMethod == HttpHead:
            req.body = ""
          
          attempt += 1
          continue  # リダイレクト先へリクエスト
      
      # ボディの解凍
      if client.compressionSettings.autoDecompress and "Content-Encoding" in res.headers:
        let encoding = res.headers["Content-Encoding"][0]
        try:
          res.body = decompressBody(res.body, encoding)
        except:
          # 解凍失敗時はそのまま使用
          if client.debugMode:
            echo "ボディの解凍に失敗しました: " & getCurrentExceptionMsg()
      
      # リトライが必要かチェック
      if client.shouldRetry(req.method, res.statusCode, attempt) and attempt < client.retryConfig.maxRetries:
        # インターセプターの実行（リトライ前）
        var shouldRetry = await client.runInterceptors(ipBeforeRetry, req, res)
        if not shouldRetry:
          break
        
        # 指数バックオフによる待機
        let delay = calculateDelay(
          client.retryConfig.retryDelay, 
          attempt, 
          client.retryConfig.exponentialBackoff,
          client.retryConfig.jitterFactor
        )
        await sleepAsync(delay)
        
        attempt += 1
        continue
      
      # 成功レスポンスをキャッシュ
      if client.cacheManager.enabled and isCacheable(req.method, res.statusCode, req.headers, res.headers):
        client.cachePut(req.url, res.statusCode, req.headers, res.headers, res.body)
      
      break
    except Exception as e:
      # エラー処理
      res.statusCode = 0
      res.error = getCurrentExceptionMsg()
      
      # ネットワークエラーでリトライするか
      if client.retryConfig.retryOnNetworkError and attempt < client.retryConfig.maxRetries:
        # インターセプターの実行（リトライ前）
        var shouldRetry = await client.runInterceptors(ipBeforeRetry, req, res)
        if not shouldRetry:
          break
        
        # 指数バックオフによる待機
        let delay = calculateDelay(
          client.retryConfig.retryDelay, 
          attempt, 
          client.retryConfig.exponentialBackoff,
          client.retryConfig.jitterFactor
        )
        await sleepAsync(delay)
        
        attempt += 1
        continue
      else:
        # インターセプターの実行（エラー時）
        discard await client.runInterceptors(ipOnError, req, res)
        break
  
  # リクエスト完了時の処理
  let endTime = epochTime()
  let requestTime = endTime - startTime
  
  # メトリクスを更新
  client.updateMetrics(
    req.url,
    res.statusCode,
    requestTime,
    res.body.len.int64,
    req.body.len.int64,
    res.error.len > 0,
    attempt > 0,
    false  # キャッシュヒットはここではfalse
  )
  
  # インターセプターの実行（レスポンス後）
  discard await client.runInterceptors(ipAfterResponse, req, res)
  
  return res

proc get*(client: HttpClientAdvanced, url: string, headers: HttpHeaders = nil, 
         cachePolicy: CachePolicy = cpDefault): Future[HttpResponse] {.async.} =
  ## HTTP GETリクエストを実行
  return await client.request(url, HttpGet, "", headers, cachePolicy)

proc post*(client: HttpClientAdvanced, url: string, body: string, 
          headers: HttpHeaders = nil): Future[HttpResponse] {.async.} =
  ## HTTP POSTリクエストを実行
  return await client.request(url, HttpPost, body, headers, cpNoStore)

proc put*(client: HttpClientAdvanced, url: string, body: string, 
         headers: HttpHeaders = nil): Future[HttpResponse] {.async.} =
  ## HTTP PUTリクエストを実行
  return await client.request(url, HttpPut, body, headers, cpNoStore)

proc delete*(client: HttpClientAdvanced, url: string, headers: HttpHeaders = nil): Future[HttpResponse] {.async.} =
  ## HTTP DELETEリクエストを実行
  return await client.request(url, HttpDelete, "", headers, cpNoStore)

proc head*(client: HttpClientAdvanced, url: string, headers: HttpHeaders = nil, 
          cachePolicy: CachePolicy = cpDefault): Future[HttpResponse] {.async.} =
  ## HTTP HEADリクエストを実行
  return await client.request(url, HttpHead, "", headers, cachePolicy)

proc patch*(client: HttpClientAdvanced, url: string, body: string, 
           headers: HttpHeaders = nil): Future[HttpResponse] {.async.} =
  ## HTTP PATCHリクエストを実行
  return await client.request(url, HttpPatch, body, headers, cpNoStore)

proc getJson*(client: HttpClientAdvanced, url: string, 
             headers: HttpHeaders = nil): Future[JsonNode] {.async.} =
  ## JSONデータを取得
  var mergedHeaders = if headers != nil: headers else: newHttpHeaders()
  if "Accept" notin mergedHeaders:
    mergedHeaders["Accept"] = "application/json"
  
  let response = await client.get(url, mergedHeaders)
  if response.statusCode div 100 != 2:
    raise newException(HttpRequestError, "HTTPエラー: " & $response.statusCode & ", " & response.error)
  
  if response.body.len == 0:
    return newJNull()
  
  return parseJson(response.body)

proc postJson*(client: HttpClientAdvanced, url: string, data: JsonNode, 
              headers: HttpHeaders = nil): Future[JsonNode] {.async.} =
  ## JSON形式でデータを送信し、JSONレスポンスを取得
  var mergedHeaders = if headers != nil: headers else: newHttpHeaders()
  if "Content-Type" notin mergedHeaders:
    mergedHeaders["Content-Type"] = "application/json"
  if "Accept" notin mergedHeaders:
    mergedHeaders["Accept"] = "application/json"
  
  let body = $data
  let response = await client.post(url, body, mergedHeaders)
  if response.statusCode div 100 != 2:
    raise newException(HttpRequestError, "HTTPエラー: " & $response.statusCode & ", " & response.error)
  
  if response.body.len == 0:
    return newJNull()
  
  return parseJson(response.body)

proc downloadFile*(client: HttpClientAdvanced, url: string, filename: string, 
                  headers: HttpHeaders = nil): Future[bool] {.async.} =
  ## ファイルをダウンロード
  let response = await client.get(url, headers)
  if response.statusCode div 100 != 2:
    return false
  
  try:
    let file = open(filename, fmWrite)
    file.write(response.body)
    file.close()
    return true
  except:
    return false

proc close*(client: HttpClientAdvanced) =
  ## クライアントを閉じる
  client.core.close()

proc getMetrics*(client: HttpClientAdvanced): ClientMetrics =
  ## メトリクスを取得
  return client.metrics

proc getAverageResponseTime*(client: HttpClientAdvanced, hostname: string = ""): float =
  ## 平均レスポンス時間を取得
  if hostname.len > 0:
    if hostname in client.metrics.requestTimes and client.metrics.requestTimes[hostname].len > 0:
      var total = 0.0
      for time in client.metrics.requestTimes[hostname]:
        total += time
      return total / client.metrics.requestTimes[hostname].len.float
    return 0.0
  else:
    var total = 0.0
    var count = 0
    for _, times in client.metrics.requestTimes:
      for time in times:
        total += time
        count += 1
    
    if count > 0:
      return total / count.float
    return 0.0

proc clearCache*(client: HttpClientAdvanced) =
  ## キャッシュをクリア
  client.cacheManager.entries.clear()
  client.cacheManager.totalSize = 0

proc enableDebugging*(client: HttpClientAdvanced, enabled: bool = true) =
  ## デバッグモードを有効/無効化
  client.debugMode = enabled 