import std/[asyncdispatch, httpclient, httpcore, tables, strutils, uri, options, times, streams, net, os, logging, json, parseutils, strformat, unicode, random, math, threadpool, cpuinfo, sets, sequtils, algorithm, deques, base64, sha1, md5]
import ../dns/resolver
import ./utils
import zippy

type
  RequestOptions* = object
    timeout_seconds*: int
    follow_redirects*: bool
    max_redirects*: int
    proxy_url*: string
    ssl_verify*: bool
    compression*: bool
    keep_alive*: bool
    retry_count*: int
    retry_delay_ms*: int
    cache_control*: string
    http_version*: HttpVersion
    dns_cache*: bool
    priority*: RequestPriority
    debug_mode*: bool
    auto_decompress*: bool
    auto_referer*: bool
    default_charset*: string
    connection_pool_size*: int
    validate_certs*: bool
    bypass_cache*: bool
    timeout_connect_seconds*: int
    timeout_idle_seconds*: int
    persist_cookies*: bool

  HttpVersion* = enum
    HttpVersion11 = "HTTP/1.1",
    HttpVersion20 = "HTTP/2.0"

  RequestPriority* = enum
    rpLow, rpNormal, rpHigh, rpCritical

  FetchResult* = object
    success*: bool
    status_code*: int
    status_text*: string
    headers*: HttpHeaders
    body*: string
    content_type*: string
    charset*: string
    url*: string
    redirect_chain*: seq[string]
    error_msg*: string
    response*: Response
    downloaded_bytes*: int
    upload_bytes*: int
    timing*: RequestTiming
    from_cache*: bool
    security_info*: HttpSecurityInfo
    tracking_info*: UrlTrackingInfo
    mime_info*: MimeTypeInfo
    compressed*: bool
    decompressed*: bool
    protocol*: string
    ip_address*: string
    cert_info*: Option[SslCertInfo]
    warnings*: seq[string]
    debug_info*: JsonNode

  RequestTiming* = object
    start_time*: Time
    dns_resolution_time*: Duration
    connection_time*: Duration
    tls_handshake_time*: Duration
    time_to_first_byte*: Duration
    download_time*: Duration
    total_time*: Duration

  SslCertInfo* = object
    subject*: string
    issuer*: string
    valid_from*: DateTime
    valid_to*: DateTime
    fingerprint*: string
    serial_number*: string
    version*: int
    is_valid*: bool

  ProxySettings* = object
    url*: string
    username*: string
    password*: string
    auth_type*: HttpAuthType
    bypass_domains*: seq[string]
    proxy_type*: ProxyType

  ProxyType* = enum
    ptHttp, ptSocks4, ptSocks5

  HttpClientExEventKind* = enum
    ekBeforeRequest, ekAfterRequest, ekRedirect, ekError, ekProgress, ekCancel, ekCacheHit

  HttpClientExEvent* = object
    kind*: HttpClientExEventKind
    url*: string
    request_id*: string
    status_code*: int
    case kind*: HttpClientExEventKind
      of ekBeforeRequest:
        method*: HttpMethod
        headers*: HttpHeaders
      of ekAfterRequest:
        response_headers*: HttpHeaders
        response_time*: Duration
      of ekRedirect:
        redirect_url*: string
        redirect_type*: int
      of ekError:
        error_message*: string
      of ekProgress:
        bytes_downloaded*: int
        total_bytes*: int
        progress_percentage*: float
      of ekCancel:
        cancel_reason*: string
      of ekCacheHit:
        cache_key*: string

  HttpClientExEventCallback* = proc(event: HttpClientExEvent)
  
  TlsVersion* = enum
    tlsUnknown, tlsV10, tlsV11, tlsV12, tlsV13
  
  CachePolicy* = enum
    cpNoCache,          # キャッシュを使用しない
    cpUseCache,         # 有効なキャッシュがあれば使用
    cpForceCache,       # 期限切れでもキャッシュを使用
    cpRevalidateCache,  # 常に再検証する
    cpNetworkOnly,      # ネットワークのみ使用
    cpCacheOnly         # キャッシュのみ使用（オフライン）
  
  HttpClientEx* = ref object
    client*: AsyncHttpClient
    default_options*: RequestOptions
    default_headers*: HttpHeaders
    cookie_jar*: CookieJar
    dns_resolver*: DnsResolver
    proxy_settings*: ProxySettings
    event_callbacks*: seq[HttpClientExEventCallback]
    active_requests*: Table[string, Future[FetchResult]]
    request_stats*: RequestStats
    cache_policy*: CachePolicy
    cache_dir*: string
    user_agent*: string
    auth_manager*: AuthManager
    connection_pool*: ConnectionPool
    throttler*: RateLimiter
    debug_logger*: Logger

  RequestStats* = ref object
    total_requests*: int
    successful_requests*: int
    failed_requests*: int
    redirect_count*: int
    total_bytes_downloaded*: int64
    total_bytes_uploaded*: int64
    average_response_time*: float
    requests_by_status*: Table[int, int]
    start_time*: Time
    last_request_time*: Time
    
  ConnectionPool* = ref object
    connections*: Table[string, seq[AsyncSocket]]
    max_connections_per_host*: int
    max_total_connections*: int
    connection_timeout*: int
    idle_timeout*: int
    
  RateLimiter* = ref object
    requests_per_second*: float
    last_request_times*: Deque[Time]
    domains*: Table[string, DomainThrottling]
    enabled*: bool
    
  DomainThrottling* = object
    requests_per_second*: float
    last_request_times*: Deque[Time]
    enabled*: bool
    
  AuthManager* = ref object
    auth_info*: Table[string, HttpAuthInfo]
    enabled*: bool
    
  DnsLookupResult* = object
    hostname*: string
    ips*: seq[string]
    ttl*: int
    resolved_time*: Time
    dns_server*: string
    error*: string
    
  RequestTask* = object
    url*: string
    method*: HttpMethod
    headers*: HttpHeaders
    body*: string
    multipart*: MultipartData
    options*: RequestOptions
    request_id*: string
    priority*: RequestPriority
    
  CacheEntry* = object
    url*: string
    status_code*: int
    headers*: HttpHeaders
    body*: string
    store_time*: Time
    expires*: Time
    etag*: string
    last_modified*: string
    compressed*: bool
    access_count*: int
    last_access*: Time
    
  HttpServerInfo* = object
    software*: string
    version*: string
    os*: string
    generation_time*: float
    
  ContentEncodingInfo* = object
    encoding*: string
    compression_ratio*: float
    original_size*: int
    compressed_size*: int

proc generateRequestId(): string =
  ## ユニークなリクエストIDを生成
  let timestamp = toUnix(getTime())
  let random_part = rand(high(int32))
  result = $timestamp & "-" & $random_part

proc newRequestStats(): RequestStats =
  ## 新しいリクエスト統計オブジェクトを作成
  RequestStats(
    total_requests: 0,
    successful_requests: 0,
    failed_requests: 0,
    redirect_count: 0,
    total_bytes_downloaded: 0,
    total_bytes_uploaded: 0,
    average_response_time: 0.0,
    requests_by_status: initTable[int, int](),
    start_time: getTime(),
    last_request_time: getTime()
  )

proc newConnectionPool*(max_per_host: int = 4, max_total: int = 20, 
                      conn_timeout: int = 30, idle_timeout: int = 60): ConnectionPool =
  ## 新しいコネクションプールを作成
  ConnectionPool(
    connections: initTable[string, seq[AsyncSocket]](),
    max_connections_per_host: max_per_host,
    max_total_connections: max_total,
    connection_timeout: conn_timeout,
    idle_timeout: idle_timeout
  )

proc newRateLimiter*(rps: float = 10.0): RateLimiter =
  ## 新しいレート制限機能を作成
  RateLimiter(
    requests_per_second: rps,
    last_request_times: initDeque[Time](),
    domains: initTable[string, DomainThrottling](),
    enabled: false
  )

proc newAuthManager*(): AuthManager =
  ## 新しい認証マネージャーを作成
  AuthManager(
    auth_info: initTable[string, HttpAuthInfo](),
    enabled: true
  )

proc newHttpClientEx*(dns_resolver: DnsResolver = nil, 
                     cache_dir: string = getTempDir() / "quantum_browser_cache",
                     max_connections: int = 10,
                     user_agent: string = "QuantumBrowser/1.0"): HttpClientEx =
  ## 拡張HTTPクライアントを作成
  let resolver = if dns_resolver == nil: newDnsResolver() else: dns_resolver
  
  # キャッシュディレクトリの準備
  if not dirExists(cache_dir):
    try:
      createDir(cache_dir)
    except:
      let temp_dir = getTempDir() / "quantum_browser_cache"
      if not dirExists(temp_dir):
        createDir(temp_dir)
      cache_dir = temp_dir
  
  # デフォルトオプションの設定
  let default_options = RequestOptions(
    timeout_seconds: 30,
    follow_redirects: true,
    max_redirects: 5,
    ssl_verify: true,
    compression: true,
    keep_alive: true,
    retry_count: 1,
    retry_delay_ms: 1000,
    http_version: HttpVersion11,
    dns_cache: true,
    priority: rpNormal,
    debug_mode: false,
    auto_decompress: true,
    auto_referer: true,
    default_charset: "utf-8",
    connection_pool_size: max_connections,
    validate_certs: true,
    bypass_cache: false,
    timeout_connect_seconds: 10,
    timeout_idle_seconds: 30,
    persist_cookies: true
  )
  
  # デフォルトヘッダーの設定
  var default_headers = newHttpHeaders()
  default_headers["User-Agent"] = user_agent
  default_headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
  default_headers["Accept-Language"] = "ja,en-US;q=0.9,en;q=0.8"
  default_headers["Accept-Encoding"] = "gzip, deflate, br"
  default_headers["Connection"] = "keep-alive"
  
  # ロガーの設定
  var logger = newConsoleLogger()
  logger.levelThreshold = lvlInfo
  
  # HTTPクライアントの生成
  var client = newAsyncHttpClient(maxRedirects = 0)  # リダイレクトは手動で処理
  
  # デフォルトSSLコンテキストを設定
  client.sslContext = defaultSSLContext()
  
  result = HttpClientEx(
    client: client,
    default_options: default_options,
    default_headers: default_headers,
    cookie_jar: newCookieJar(),
    dns_resolver: resolver,
    proxy_settings: ProxySettings(),
    event_callbacks: @[],
    active_requests: initTable[string, Future[FetchResult]](),
    request_stats: newRequestStats(),
    cache_policy: cpUseCache,
    cache_dir: cache_dir,
    user_agent: user_agent,
    auth_manager: newAuthManager(),
    connection_pool: newConnectionPool(max_connections div 2, max_connections),
    throttler: newRateLimiter(),
    debug_logger: logger
  )

proc applyOptions(client: AsyncHttpClient, options: RequestOptions) =
  ## オプション設定をクライアントに適用
  # プロキシの設定
  if options.proxy_url.len > 0:
    client.proxy = some(parseUri(options.proxy_url))
  else:
    client.proxy = none(Uri)
  
  # SSL検証の設定
  client.sslContext = defaultSSLContext()
  if not options.ssl_verify:
    client.sslContext.wrapSocket = proc(socket: AsyncSocket) = discard

proc mergeOptions(default, custom: RequestOptions): RequestOptions =
  ## デフォルトオプションとカスタムオプションをマージ
  result = default
  
  # カスタムオプションが指定されていれば上書き
  if custom.timeout_seconds > 0:
    result.timeout_seconds = custom.timeout_seconds
  
  if custom.proxy_url.len > 0:
    result.proxy_url = custom.proxy_url
  
  # booleanフィールドとその他の設定のマージ
  result.follow_redirects = custom.follow_redirects
  result.ssl_verify = custom.ssl_verify
  
  if custom.max_redirects > 0:
    result.max_redirects = custom.max_redirects
  
  if custom.retry_count >= 0:
    result.retry_count = custom.retry_count
  
  if custom.retry_delay_ms > 0:
    result.retry_delay_ms = custom.retry_delay_ms
    
  # 追加オプションのマージ
  result.compression = custom.compression
  result.keep_alive = custom.keep_alive
  result.http_version = custom.http_version
  result.dns_cache = custom.dns_cache
  result.priority = custom.priority
  result.debug_mode = custom.debug_mode
  result.auto_decompress = custom.auto_decompress
  result.auto_referer = custom.auto_referer
  
  if custom.default_charset.len > 0:
    result.default_charset = custom.default_charset
  
  if custom.connection_pool_size > 0:
    result.connection_pool_size = custom.connection_pool_size
  
  result.validate_certs = custom.validate_certs
  result.bypass_cache = custom.bypass_cache
  
  if custom.timeout_connect_seconds > 0:
    result.timeout_connect_seconds = custom.timeout_connect_seconds
  
  if custom.timeout_idle_seconds > 0:
    result.timeout_idle_seconds = custom.timeout_idle_seconds
  
  result.persist_cookies = custom.persist_cookies

proc addEventCallback*(client: HttpClientEx, callback: HttpClientExEventCallback) =
  ## イベントコールバックを追加
  client.event_callbacks.add(callback)

proc removeEventCallback*(client: HttpClientEx, callback: HttpClientExEventCallback) =
  ## イベントコールバックを削除
  let idx = client.event_callbacks.find(callback)
  if idx >= 0:
    client.event_callbacks.delete(idx)

proc triggerEvent(client: HttpClientEx, event: HttpClientExEvent) =
  ## イベントを発火
  for callback in client.event_callbacks:
    try:
      callback(event)
    except:
      if client.default_options.debug_mode:
        echo "イベントコールバックでエラーが発生しました: ", getCurrentExceptionMsg()

proc getActiveRequestCount*(client: HttpClientEx): int =
  ## アクティブなリクエスト数を取得
  return client.active_requests.len

proc isRequestActive*(client: HttpClientEx, request_id: string): bool =
  ## リクエストがアクティブかどうかを確認
  return request_id in client.active_requests

proc cancelRequest*(client: HttpClientEx, request_id: string): bool =
  ## リクエストをキャンセル
  if request_id in client.active_requests:
    let future = client.active_requests[request_id]
    if not future.finished:
      client.triggerEvent(HttpClientExEvent(
        kind: ekCancel,
        url: "",
        request_id: request_id,
        status_code: 0,
        cancel_reason: "ユーザーによるキャンセル"
      ))
      # futureをキャンセル
      future.fail(newException(CatchableError, "Request cancelled"))
      client.active_requests.del(request_id)
      return true
  return false

proc cancelAllRequests*(client: HttpClientEx) =
  ## すべてのリクエストをキャンセル
  var request_ids: seq[string] = @[]
  for id in client.active_requests.keys:
    request_ids.add(id)
  
  for id in request_ids:
    discard client.cancelRequest(id)

proc setDefaultOptions*(client: HttpClientEx, options: RequestOptions) =
  ## デフォルトオプションを設定
  client.default_options = options

proc setDefaultHeader*(client: HttpClientEx, key, value: string) =
  ## デフォルトヘッダーを設定
  client.default_headers[key] = value

proc setDefaultHeaders*(client: HttpClientEx, headers: HttpHeaders) =
  ## 複数のデフォルトヘッダーを設定
  for key, values in headers.table:
    for value in values:
      client.default_headers[key] = value

proc setDefaultUserAgent*(client: HttpClientEx, user_agent: string) =
  ## デフォルトのUser-Agentを設定
  client.default_headers["User-Agent"] = user_agent
  client.user_agent = user_agent

proc setCachePolicy*(client: HttpClientEx, policy: CachePolicy) =
  ## キャッシュポリシーを設定
  client.cache_policy = policy

proc setCookieJar*(client: HttpClientEx, jar: CookieJar) =
  ## CookieJarを設定
  client.cookie_jar = jar

proc getCookieJar*(client: HttpClientEx): CookieJar =
  ## CookieJarを取得
  return client.cookie_jar

proc addCookie*(client: HttpClientEx, cookie: Cookie) =
  ## Cookieを追加
  client.cookie_jar.addCookie(cookie)

proc clearCookies*(client: HttpClientEx) =
  ## すべてのCookieをクリア
  client.cookie_jar = newCookieJar()

proc setProxy*(client: HttpClientEx, proxy_url: string, 
              username: string = "", password: string = "",
              proxy_type: ProxyType = ptHttp) =
  ## プロキシを設定
  client.proxy_settings.url = proxy_url
  client.proxy_settings.username = username
  client.proxy_settings.password = password
  client.proxy_settings.proxy_type = proxy_type
  
  # デフォルトオプションにも設定
  client.default_options.proxy_url = proxy_url

proc addProxyBypassDomain*(client: HttpClientEx, domain: string) =
  ## プロキシをバイパスするドメインを追加
  client.proxy_settings.bypass_domains.add(domain)

proc clearProxy*(client: HttpClientEx) =
  ## プロキシ設定をクリア
  client.proxy_settings = ProxySettings()
  client.default_options.proxy_url = ""

proc setDebugMode*(client: HttpClientEx, enabled: bool) =
  ## デバッグモードを設定
  client.default_options.debug_mode = enabled
  
  if enabled:
    client.debug_logger.levelThreshold = lvlDebug
  else:
    client.debug_logger.levelThreshold = lvlInfo

proc setRateLimiting*(client: HttpClientEx, requests_per_second: float, enabled: bool = true) =
  ## レート制限を設定
  client.throttler.requests_per_second = max(0.1, requests_per_second)
  client.throttler.enabled = enabled

proc setDomainRateLimiting*(client: HttpClientEx, domain: string, 
                          requests_per_second: float, enabled: bool = true) =
  ## 特定ドメインに対するレート制限を設定
  var domain_throttling = DomainThrottling(
    requests_per_second: max(0.1, requests_per_second),
    last_request_times: initDeque[Time](),
    enabled: enabled
  )
  
  client.throttler.domains[domain] = domain_throttling

proc waitForRateLimit(client: HttpClientEx, url: string): Future[void] {.async.} =
  ## レート制限に従って待機
  if not client.throttler.enabled:
    return
  
  let now = getTime()
  let hostname = parseUri(url).hostname
  
  # ドメイン固有のレート制限をチェック
  var domain_limited = false
  if hostname in client.throttler.domains and client.throttler.domains[hostname].enabled:
    domain_limited = true
    var domain_throttling = client.throttler.domains[hostname]
    
    # 古いタイムスタンプを削除
    while domain_throttling.last_request_times.len > 0:
      let oldest = domain_throttling.last_request_times.peekFirst()
      if (now - oldest).inSeconds.float >= 1.0:
        discard domain_throttling.last_request_times.popFirst()
      else:
        break
    
    # 現在のレート
    let current_rate = domain_throttling.last_request_times.len.float
    
    # 制限を超えている場合は待機
    if current_rate >= domain_throttling.requests_per_second:
      let oldest = domain_throttling.last_request_times.peekFirst()
      let wait_time = 1.0 - (now - oldest).inSeconds.float
      if wait_time > 0:
        await sleepAsync(int(wait_time * 1000))
    
    # 新しいリクエストを記録
    client.throttler.domains[hostname].last_request_times.addLast(getTime())
  
  # グローバルレート制限（ドメイン制限がない場合）
  if not domain_limited:
    # 古いタイムスタンプを削除
    while client.throttler.last_request_times.len > 0:
      let oldest = client.throttler.last_request_times.peekFirst()
      if (now - oldest).inSeconds.float >= 1.0:
        discard client.throttler.last_request_times.popFirst()
      else:
        break
    
    # 現在のレート
    let current_rate = client.throttler.last_request_times.len.float
    
    # 制限を超えている場合は待機
    if current_rate >= client.throttler.requests_per_second:
      let oldest = client.throttler.last_request_times.peekFirst()
      let wait_time = 1.0 - (now - oldest).inSeconds.float
      if wait_time > 0:
        await sleepAsync(int(wait_time * 1000))
    
    # 新しいリクエストを記録
    client.throttler.last_request_times.addLast(getTime())

proc resolveDns(client: HttpClientEx, hostname: string): Future[DnsLookupResult] {.async.} =
  ## DNSを解決
  var result = DnsLookupResult(
    hostname: hostname,
    ips: @[],
    ttl: 0,
    resolved_time: getTime(),
    dns_server: ""
  )
  
  try:
    # DNSリゾルバを使用
    let ips = await client.dns_resolver.resolve(hostname)
    result.ips = ips
    result.ttl = 300  # デフォルトTTL
    
    if client.default_options.debug_mode:
      echo "DNSを解決しました: ", hostname, " -> ", ips
    
  except Exception as e:
    result.error = e.msg
    
    if client.default_options.debug_mode:
      echo "DNS解決エラー: ", hostname, " - ", e.msg
  
  return result

proc getCacheKey(url: string, method: HttpMethod, headers: HttpHeaders): string =
  ## キャッシュキーを生成
  var key = $method & ":" & url
  
  # 一部のヘッダーをキーに含める
  if headers.hasKey("Accept"):
    key &= ":Accept=" & headers["Accept"]
  if headers.hasKey("Accept-Language"):
    key &= ":Accept-Language=" & headers["Accept-Language"]
  if headers.hasKey("Accept-Encoding"):
    key &= ":Accept-Encoding=" & headers["Accept-Encoding"]
  
  # MD5ハッシュに変換
  result = getMD5(key)

proc getCachedEntry(client: HttpClientEx, cache_key: string): Option[CacheEntry] =
  ## キャッシュからエントリを取得
  let cache_path = client.cache_dir / cache_key
  
  if not fileExists(cache_path):
    return none(CacheEntry)
  
  try:
    let json_str = readFile(cache_path)
    let json_data = parseJson(json_str)
    
    var entry = CacheEntry(
      url: json_data["url"].getStr(),
      status_code: json_data["status_code"].getInt(),
      headers: newHttpHeaders(),
      body: "",
      store_time: fromUnix(json_data["store_time"].getInt()),
      access_count: json_data["access_count"].getInt()
    )
    
    # 有効期限の取得
    if json_data.hasKey("expires"):
      entry.expires = fromUnix(json_data["expires"].getInt())
    else:
      entry.expires = entry.store_time + initDuration(hours = 1)
    
    # 最終アクセス時間の取得
    if json_data.hasKey("last_access"):
      entry.last_access = fromUnix(json_data["last_access"].getInt())
    else:
      entry.last_access = entry.store_time
    
    # ETagの取得
    if json_data.hasKey("etag"):
      entry.etag = json_data["etag"].getStr()
    
    # Last-Modifiedの取得
    if json_data.hasKey("last_modified"):
      entry.last_modified = json_data["last_modified"].getStr()
    
    # 圧縮フラグの取得
    if json_data.hasKey("compressed"):
      entry.compressed = json_data["compressed"].getBool()
    
    # ヘッダーの取得
    if json_data.hasKey("headers") and json_data["headers"].kind == JObject:
      for key, value in json_data["headers"].fields:
        if value.kind == JArray:
          for val in value:
            if val.kind == JString:
              entry.headers.add(key, val.getStr())
    
    # ボディの取得
    let body_path = client.cache_dir / (cache_key & ".body")
    if fileExists(body_path):
      entry.body = readFile(body_path)
    
    # アクセス回数とアクセス時間を更新
    entry.access_count += 1
    entry.last_access = getTime()
    
    # キャッシュエントリを更新（JSONデータのみ）
    var updated_json = json_data
    updated_json["access_count"] = newJInt(entry.access_count)
    updated_json["last_access"] = newJInt(toUnix(entry.last_access))
    writeFile(cache_path, $updated_json)
    
    return some(entry)
  except:
    if client.default_options.debug_mode:
      echo "キャッシュエントリの読み込みエラー: ", cache_key, " - ", getCurrentExceptionMsg()
    return none(CacheEntry)

proc saveToCache(client: HttpClientEx, cache_key: string, entry: CacheEntry) =
  ## エントリをキャッシュに保存
  try:
    # メタデータJSONの作成
    var json_data = newJObject()
    json_data["url"] = newJString(entry.url)
    json_data["status_code"] = newJInt(entry.status_code)
    json_data["store_time"] = newJInt(toUnix(entry.store_time))
    json_data["expires"] = newJInt(toUnix(entry.expires))
    json_data["last_access"] = newJInt(toUnix(entry.last_access))
    json_data["access_count"] = newJInt(entry.access_count)
    json_data["compressed"] = newJBool(entry.compressed)
    
    if entry.etag.len > 0:
      json_data["etag"] = newJString(entry.etag)
    
    if entry.last_modified.len > 0:
      json_data["last_modified"] = newJString(entry.last_modified)
    
    # ヘッダーの保存
    var headers_json = newJObject()
    for key, values in entry.headers.table:
      var values_arr = newJArray()
      for value in values:
        values_arr.add(newJString(value))
      headers_json[key] = values_arr
    
    json_data["headers"] = headers_json
    
    # JSONメタデータをファイルに保存
    writeFile(client.cache_dir / cache_key, $json_data)
    
    # ボディを別ファイルに保存
    writeFile(client.cache_dir / (cache_key & ".body"), entry.body)
  except:
    if client.default_options.debug_mode:
      echo "キャッシュへの保存エラー: ", cache_key, " - ", getCurrentExceptionMsg()

proc isResponseCacheable(status_code: int, headers: HttpHeaders): bool =
  ## レスポンスがキャッシュ可能かを判断
  # 成功したGETとHEADリクエストのみをキャッシュ
  if status_code < 200 or status_code >= 400:
    return false
  
  # Cache-Controlヘッダーのチェック
  if headers.hasKey("Cache-Control"):
    let cache_control = headers["Cache-Control"].join(",").toLowerAscii()
    if "no-store" in cache_control or "private" in cache_control:
      return false
    if "max-age=0" in cache_control:
      return false
  
  # Pragmaヘッダーのチェック
  if headers.hasKey("Pragma"):
    let pragma = headers["Pragma"].join(",").toLowerAscii()
    if "no-cache" in pragma:
      return false
  
  return true

proc isCacheValid(entry: CacheEntry, policy: CachePolicy): bool =
  ## キャッシュが有効かどうかを判断
  let now = getTime()
  
  case policy:
    of cpNoCache, cpNetworkOnly:
      return false
    of cpCacheOnly, cpForceCache:
      return true
    of cpUseCache:
      return now <= entry.expires
    of cpRevalidateCache:
      return entry.etag.len > 0 or entry.last_modified.len > 0

proc calculateExpirationTime(headers: HttpHeaders, default_ttl_seconds: int = 3600): Time =
  ## ヘッダーから有効期限を計算
  let now = getTime()
  
  # Cache-Controlヘッダーからmax-ageを取得
  if headers.hasKey("Cache-Control"):
    let cache_control = headers["Cache-Control"].join(",")
    for directive in cache_control.split(','):
      let trimmed = directive.strip().toLowerAscii()
      if trimmed.startsWith("max-age="):
        try:
          let max_age = parseInt(trimmed[8..^1])
          if max_age > 0:
            return now + initDuration(seconds = max_age)
        except:
          discard
  
  # Expiresヘッダーをチェック
  if headers.hasKey("Expires"):
    try:
      let expires_str = headers["Expires"][0]
      let expires_time = parseHttpDate(expires_str)
      let expires = fromUnix(toUnix(expires_time))
      if expires > now:
        return expires
    except:
      discard
  
  # デフォルトのTTL
  return now + initDuration(seconds = default_ttl_seconds)

proc extractResponseInfo(response: Response, body: string): tuple[content_type, charset: string] =
  ## レスポンスからContent-TypeとCharsetを抽出
  var content_type = ""
  var charset = "utf-8"  # デフォルト
  
  # Content-Typeヘッダーをチェック
  if response.headers.hasKey("Content-Type"):
    let ct = response.headers["Content-Type"][0]
    
    # MIMEタイプとcharset部分に分割
    var mime_type = ct
    if ";" in ct:
      let parts = ct.split(';', maxsplit=1)
      mime_type = parts[0].strip()
      
      # charsetがあれば抽出
      let params = parts[1]
      if "charset=" in params.toLowerAscii():
        let charset_parts = params.split('=', maxsplit=1)
        if charset_parts.len > 1:
          charset = charset_parts[1].strip()
          # 引用符を削除
          if charset.startsWith('"') and charset.endsWith('"'):
            charset = charset[1..^2]
          elif charset.startsWith('\'') and charset.endsWith('\''):
            charset = charset[1..^2]
    
    content_type = mime_type
  else:
    # Content-Typeがない場合はボディから推測
    content_type = detectContentType(body)
  
  return (content_type: content_type, charset: charset)

proc detectCompression(headers: HttpHeaders): string =
  ## レスポンスの圧縮方式を検出
  if headers.hasKey("Content-Encoding"):
    let encodings = headers["Content-Encoding"].join(",").toLowerAscii()
    
    if "gzip" in encodings:
      return "gzip"
    elif "deflate" in encodings:
      return "deflate"
    elif "br" in encodings:
      return "br"
  
  return ""

proc getResponseDebugInfo(response: Response, timing: RequestTiming, 
                         url: string, compressed: bool, size: int): JsonNode =
  ## レスポンスのデバッグ情報を取得
  result = newJObject()
  
  # 基本情報
  result["url"] = newJString(url)
  result["status"] = newJInt(response.code.int)
  result["method"] = newJString($response.version)
  result["size"] = newJInt(size)
  result["compressed"] = newJBool(compressed)
  
  # タイミング情報
  var timing_obj = newJObject()
  timing_obj["total_ms"] = newJInt(timing.total_time.inMilliseconds.int)
  if not timing.dns_resolution_time.isZero:
    timing_obj["dns_ms"] = newJInt(timing.dns_resolution_time.inMilliseconds.int)
  if not timing.connection_time.isZero:
    timing_obj["connection_ms"] = newJInt(timing.connection_time.inMilliseconds.int)
  if not timing.tls_handshake_time.isZero:
    timing_obj["tls_ms"] = newJInt(timing.tls_handshake_time.inMilliseconds.int)
  if not timing.time_to_first_byte.isZero:
    timing_obj["ttfb_ms"] = newJInt(timing.time_to_first_byte.inMilliseconds.int)
  if not timing.download_time.isZero:
    timing_obj["download_ms"] = newJInt(timing.download_time.inMilliseconds.int)
  
  result["timing"] = timing_obj
  
  # ヘッダー情報
  var headers_obj = newJObject()
  for key, values in response.headers.table:
    if values.len == 1:
      headers_obj[key] = newJString(values[0])
    else:
      var values_arr = newJArray()
      for value in values:
        values_arr.add(newJString(value))
      headers_obj[key] = values_arr
  
  result["headers"] = headers_obj

proc fetchWithMethod*(client: HttpClientEx, url: string, 
                    httpMethod: HttpMethod = HttpGet,
                    body: string = "",
                    headers: HttpHeaders = nil,
                    multipart: MultipartData = nil,
                    options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## 指定されたメソッドでHTTPリクエストを実行
  var result = FetchResult(
    success: false,
    redirect_chain: @[],
    timing: RequestTiming(start_time: getTime()),
    warnings: @[]
  )
  
  let request_id = generateRequestId()
  
  # リクエストタスクの作成
  var task = RequestTask(
    url: url,
    method: httpMethod,
    headers: if headers.isNil: newHttpHeaders() else: headers,
    body: body,
    multipart: multipart,
    options: options,
    request_id: request_id,
    priority: options.priority
  )
  
  # オプションをマージ
  let merged_options = mergeOptions(client.default_options, options)
  
  # ヘッダーをマージ
  var merged_headers = newHttpHeaders()
  
  # デフォルトヘッダーをコピー
  for key, values in client.default_headers.table:
    for value in values:
      merged_headers[key] = value
  
  # 指定されたヘッダーで上書き
  if not headers.isNil:
    for key, values in headers.table:
      for value in values:
        merged_headers[key] = value
  
  # レート制限に従って待機
  await client.waitForRateLimit(url)
  
  # HTTPベースクライアントの設定を更新
  client.client.applyOptions(merged_options)
  client.client.timeout = merged_options.timeout_seconds * 1000
  
  # CookieJarからCookieヘッダーを取得して設定
  let cookie_header = client.cookie_jar.getCookieHeader(url)
  if cookie_header.len > 0:
    merged_headers["Cookie"] = cookie_header
  
  # HTTPベースクライアントのデフォルトヘッダーをクリアして再設定
  # （これにより確実に正しいヘッダーだけが送信される）
  for key, values in client.client.headers.table:
    client.client.headers.del(key)
  
  for key, values in merged_headers.table:
    for value in values:
      client.client.headers[key] = value
  
  # エンコーディングを確認
  var accepts_compression = false
  if merged_headers.hasKey("Accept-Encoding"):
    let encodings = merged_headers["Accept-Encoding"].toLowerAscii()
    accepts_compression = "gzip" in encodings or "deflate" in encodings
  
  # キャッシュキーを計算
  let cache_key = getCacheKey(url, httpMethod, merged_headers)
  
  # キャッシュチェック（GETリクエストのみ）
  if httpMethod == HttpGet and 
     client.cache_policy != cpNoCache and 
     client.cache_policy != cpNetworkOnly and
     not merged_options.bypass_cache:
    
    let cache_entry = client.getCachedEntry(cache_key)
    
    if cache_entry.isSome:
      let entry = cache_entry.get()
      
      # キャッシュが有効かチェック
      if isCacheValid(entry, client.cache_policy):
        # キャッシュヒットイベントをトリガー
        client.triggerEvent(HttpClientExEvent(
          kind: ekCacheHit,
          url: url,
          request_id: request_id,
          status_code: entry.status_code,
          cache_key: cache_key
        ))
        
        # キャッシュからレスポンスを返す
        result.success = true
        result.status_code = entry.status_code
        result.headers = entry.headers
        result.body = entry.body
        
        # Content-Typeと文字セットを抽出
        let content_info = extractResponseInfo(entry.headers, entry.body)
        
        result.content_type = content_info.content_type
        result.charset = content_info.charset
        
        result.url = url
        result.from_cache = true
        result.timing.total_time = getTime() - result.timing.start_time
        
        # MIMEタイプ情報
        result.mime_info = getMimeTypeInfo(result.content_type)
        
        return result
  
  # リクエスト前イベントをトリガー
  client.triggerEvent(HttpClientExEvent(
    kind: ekBeforeRequest,
    url: url,
    request_id: request_id,
    status_code: 0,
    method: httpMethod,
    headers: merged_headers
  ))
  
  # DNS解決の時間を計測
  let dns_start_time = getTime()
  var hostname = parseUri(url).hostname
  
  if merged_options.dns_cache and hostname.len > 0:
    let dns_result = await client.resolveDns(hostname)
    result.timing.dns_resolution_time = getTime() - dns_start_time
    
    # エラーがあれば記録
    if dns_result.error.len > 0:
      result.warnings.add("DNS解決エラー: " & dns_result.error)
    
    # IPアドレスを記録
    if dns_result.ips.len > 0:
      result.ip_address = dns_result.ips[0]
  
  try:
    # リトライ用にリクエスト処理を関数化
    proc performRequest(): Future[tuple[response: Response, body: string]] {.async.} =
      let request_start_time = getTime()
      var response: Response
      
      # リクエストの実行
      case httpMethod:
        of HttpGet:
          response = await client.client.request(url, httpMethod = httpMethod)
        of HttpPost, HttpPut, HttpPatch:
          if not multipart.isNil:
            response = await client.client.request(url, httpMethod = httpMethod, multipart = multipart)
          elif body.len > 0:
            response = await client.client.request(url, httpMethod = httpMethod, body = body)
          else:
            response = await client.client.request(url, httpMethod = httpMethod)
        else:
          response = await client.client.request(url, httpMethod = httpMethod)
      
      # 最初のバイトまでの時間を計測
      result.timing.time_to_first_byte = getTime() - request_start_time
      
      # レスポンスボディの取得
      let download_start_time = getTime()
      let body_content = await response.body
      result.timing.download_time = getTime() - download_start_time
      
      return (response: response, body: body_content)
    
    # リトライロジック
    var retry_count = 0
    var last_error = ""
    var req_result: tuple[response: Response, body: string]
    
    while retry_count <= merged_options.retry_count:
      try:
        # リクエストの実行
        req_result = await performRequest()
        break
      except Exception as e:
        last_error = e.msg
        retry_count += 1
        
        # 最大リトライ回数に達していなければリトライ
        if retry_count <= merged_options.retry_count:
          # リトライ待機
          await sleepAsync(merged_options.retry_delay_ms)
          result.warnings.add(fmt"リトライ {retry_count}/{merged_options.retry_count}: {e.msg}")
        else:
          # 最大リトライ回数に達した場合は例外を再スロー
          raise e
    
    # レスポンスの処理
    let response = req_result.response
    let body_content = req_result.body
    let response_size = body_content.len
    
    # 圧縮の検出
    let compression_type = detectCompression(response.headers)
    let is_compressed = compression_type.len > 0
    
    # Content-Typeと文字セットを抽出
    let content_info = extractResponseInfo(response, body_content)
    
    # リダイレクト処理
    var final_url = url
    if merged_options.follow_redirects and 
       response.code.int in [301, 302, 303, 307, 308] and
       response.headers.hasKey("Location"):
      
      let location = response.headers["Location"]
      var redirect_url = location
      
      # 相対URLを絶対URLに変換
      if not location.startsWith("http"):
        redirect_url = url.joinUrl(location)
      
      result.redirect_chain.add(url)
      
      # リダイレクトイベントをトリガー
      client.triggerEvent(HttpClientExEvent(
        kind: ekRedirect,
        url: url,
        request_id: request_id,
        status_code: response.code.int,
        redirect_url: redirect_url,
        redirect_type: response.code.int
      ))
      
      # リダイレクト回数の制限を超えていなければリダイレクト
      if result.redirect_chain.len < merged_options.max_redirects:
        # HTTPメソッドの変更（303の場合は常にGETに変更）
        var next_method = httpMethod
        if response.code.int == 303:
          next_method = HttpGet
        
        # 自動的にリファラーを設定
        var redirect_headers = merged_headers
        if merged_options.auto_referer:
          redirect_headers["Referer"] = url
        
        # リダイレクト先をリクエスト
        var redirect_result = await client.fetchWithMethod(
          redirect_url, 
          httpMethod = next_method,
          headers = redirect_headers,
          options = merged_options
        )
        
        # リダイレクト履歴をマージ
        for ru in redirect_result.redirect_chain:
          result.redirect_chain.add(ru)
        
        # リダイレクト結果を返す
        return redirect_result
      else:
        result.warnings.add("最大リダイレクト回数に達しました")
      
      final_url = redirect_url
    
    # Set-Cookieヘッダーの処理
    if response.headers.hasKey("Set-Cookie") and merged_options.persist_cookies:
      let cookie_strs = response.headers.getOrDefault("Set-Cookie")
      for cookie_str in cookie_strs:
        let cookie = parseCookie(cookie_str)
        client.cookie_jar.addCookie(cookie, url)
    
    # レスポンス後イベントをトリガー
    client.triggerEvent(HttpClientExEvent(
      kind: ekAfterRequest,
      url: url,
      request_id: request_id,
      status_code: response.code.int,
      response_headers: response.headers,
      response_time: getTime() - result.timing.start_time
    ))
    
    # 結果の設定
    result.success = true
    result.status_code = response.code.int
    result.status_text = $response.code
    result.headers = response.headers
    result.body = if merged_options.auto_decompress and is_compressed:
                    decompressContent(body_content, compression_type)
                  else:
                    body_content
    result.content_type = content_info.content_type
    result.charset = content_info.charset
    result.url = final_url
    result.response = response
    result.downloaded_bytes = response_size
    result.upload_bytes = if body.len > 0: body.len else: 0
    result.timing.total_time = getTime() - result.timing.start_time
    result.compressed = is_compressed
    result.decompressed = merged_options.auto_decompress and is_compressed
    result.protocol = $response.version
    
    # セキュリティ情報
    result.security_info = analyzeSecurity(response.headers)
    
    # トラッキング情報
    let query_params = decodeQueryParams(parseUri(url).query)
    result.tracking_info = analyzeTracking(url, query_params)
    
    # MIMEタイプ情報
    result.mime_info = getMimeTypeInfo(result.content_type)
    
    # デバッグ情報
    if merged_options.debug_mode:
      result.debug_info = getResponseDebugInfo(
        response, 
        result.timing, 
        url, 
        is_compressed, 
        response_size
      )
    
    # キャッシュへの保存（GETリクエストかつ成功した場合）
    if httpMethod == HttpGet and 
       result.success and 
       isResponseCacheable(result.status_code, result.headers) and
       client.cache_policy != cpNoCache:
      
      # キャッシュエントリの作成
      var entry = CacheEntry(
        url: url,
        status_code: result.status_code,
        headers: result.headers,
        body: body_content,  # 圧縮されたままの状態で保存
        store_time: getTime(),
        expires: calculateExpirationTime(result.headers),
        compressed: is_compressed,
        access_count: 0,
        last_access: getTime()
      )
      
      # ETagとLast-Modifiedを取得
      if result.headers.hasKey("ETag"):
        entry.etag = result.headers["ETag"][0]
      
      if result.headers.hasKey("Last-Modified"):
        entry.last_modified = result.headers["Last-Modified"][0]
      
      # キャッシュに保存
      client.saveToCache(cache_key, entry)
    
  except Exception as e:
    # エラーイベントをトリガー
    client.triggerEvent(HttpClientExEvent(
      kind: ekError,
      url: url,
      request_id: request_id,
      status_code: 0,
      error_message: e.msg
    ))
    
    result.success = false
    result.error_msg = e.msg
    result.timing.total_time = getTime() - result.timing.start_time
  
  # 統計情報の更新
  client.request_stats.total_requests += 1
  client.request_stats.last_request_time = getTime()
  
  if result.success:
    client.request_stats.successful_requests += 1
    client.request_stats.total_bytes_downloaded += result.downloaded_bytes
    client.request_stats.total_bytes_uploaded += result.upload_bytes
    
    # ステータスコードによる統計
    if result.status_code notin client.request_stats.requests_by_status:
      client.request_stats.requests_by_status[result.status_code] = 0
    client.request_stats.requests_by_status[result.status_code] += 1
    
    # リダイレクト統計
    client.request_stats.redirect_count += result.redirect_chain.len
    
    # 応答時間の移動平均計算
    let elapsed = result.timing.total_time.inMilliseconds.float
    let current_avg = client.request_stats.average_response_time
    let total_reqs = client.request_stats.total_requests
    
    if total_reqs == 1:
      client.request_stats.average_response_time = elapsed
    else:
      client.request_stats.average_response_time = 
        ((current_avg * (total_reqs - 1).float) + elapsed) / total_reqs.float
  else:
    client.request_stats.failed_requests += 1
  
  return result

proc fetch*(client: HttpClientEx, url: string, 
           headers: HttpHeaders = nil,
           options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## GETリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpGet, "", headers, nil, options)

proc post*(client: HttpClientEx, url: string, 
          body: string = "",
          headers: HttpHeaders = nil,
          multipart: MultipartData = nil,
          options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## POSTリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpPost, body, headers, multipart, options)

proc put*(client: HttpClientEx, url: string, 
         body: string = "",
         headers: HttpHeaders = nil,
         options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## PUTリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpPut, body, headers, nil, options)

proc delete*(client: HttpClientEx, url: string,
            headers: HttpHeaders = nil,
            options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## DELETEリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpDelete, "", headers, nil, options)

proc head*(client: HttpClientEx, url: string,
          headers: HttpHeaders = nil,
          options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## HEADリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpHead, "", headers, nil, options)

proc options*(client: HttpClientEx, url: string,
             headers: HttpHeaders = nil,
             opt: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## OPTIONSリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpOptions, "", headers, nil, opt)

proc patch*(client: HttpClientEx, url: string,
           body: string = "",
           headers: HttpHeaders = nil,
           options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## PATCHリクエストを実行するショートカット
  return await client.fetchWithMethod(url, HttpPatch, body, headers, nil, options)

proc isUrlAvailable*(client: HttpClientEx, url: string, 
                    timeout_seconds: int = 5): Future[bool] {.async.} =
  ## URLが利用可能かどうかを確認
  let options = RequestOptions(
    timeout_seconds: timeout_seconds,
    follow_redirects: true,
    retry_count: 0
  )
  
  try:
    let result = await client.head(url, options = options)
    return result.success and result.status_code < 400
  except:
    return false

proc downloadFile*(client: HttpClientEx, url, destination: string, 
                 headers: HttpHeaders = nil,
                 options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## ファイルをダウンロード
  let result = await client.fetch(url, headers, options)
  
  if result.success:
    try:
      # ディレクトリが存在しない場合は作成
      let dir = parentDir(destination)
      if not dirExists(dir):
        createDir(dir)
      
      writeFile(destination, result.body)
    except Exception as e:
      var failed_result = result
      failed_result.success = false
      failed_result.error_msg = "ファイル保存エラー: " & e.msg
      return failed_result
  
  return result

proc downloadFileWithProgress*(client: HttpClientEx, url, destination: string, 
                             progress_callback: proc(downloaded, total: int64, percentage: float) {.closure.},
                             headers: HttpHeaders = nil,
                             options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## 進捗コールバック付きのファイルダウンロード
  var custom_options = options
  custom_options.auto_decompress = false  # 進捗を正確に追跡するため
  
  # イベントコールバックを設定
  let callback = proc(event: HttpClientExEvent) =
    if event.kind == ekProgress:
      progress_callback(event.bytes_downloaded.int64, event.total_bytes.int64, event.progress_percentage)
  
  client.addEventCallback(callback)
  
  try:
    let result = await client.fetch(url, headers, custom_options)
    
    if result.success:
      try:
        # ディレクトリが存在しない場合は作成
        let dir = parentDir(destination)
        if not dirExists(dir):
          createDir(dir)
        
        writeFile(destination, result.body)
      except Exception as e:
        var failed_result = result
        failed_result.success = false
        failed_result.error_msg = "ファイル保存エラー: " & e.msg
        return failed_result
    
    return result
  finally:
    # コールバックを削除
    client.removeEventCallback(callback)

proc fetchMultiple*(client: HttpClientEx, urls: seq[string], 
                  max_concurrent: int = 5,
                  headers: HttpHeaders = nil,
                  options: RequestOptions = RequestOptions()): Future[seq[FetchResult]] {.async.} =
  ## 複数のURLを同時にフェッチ
  result = newSeq[FetchResult](urls.len)
  
  # 同時実行数の制限
  let concurrent_limit = min(max_concurrent, 10)
  var active_count = 0
  var queue = newSeq[Future[FetchResult]]()
  
  # URLをループ
  for i, url in urls:
    # 同時実行数の制限に達した場合は完了したものを待つ
    if active_count >= concurrent_limit:
      let completed = await one(queue)
      let idx = queue.find(completed)
      if idx >= 0:
        queue.delete(idx)
        active_count -= 1
    
    # 新しいリクエストを開始
    let future = client.fetch(url, headers, options)
    queue.add(future)
    active_count += 1
  
  # 残りのリクエストを待つ
  while queue.len > 0:
    let completed = await one(queue)
    let idx = queue.find(completed)
    if idx >= 0:
      queue.delete(idx)
      active_count -= 1
  
  return result

proc prefetchUrls*(client: HttpClientEx, urls: seq[string], 
                 max_concurrent: int = 5,
                 headers: HttpHeaders = nil): Future[int] {.async.} =
  ## URLをプリフェッチしてキャッシュに保存
  var success_count = 0
  let options = RequestOptions(cache_policy: cpUseCache)
  
  let results = await client.fetchMultiple(urls, max_concurrent, headers, options)
  
  for result in results:
    if result.success:
      success_count += 1
  
  return success_count

proc getJson*(client: HttpClientEx, url: string, 
             headers: HttpHeaders = nil,
             options: RequestOptions = RequestOptions()): Future[JsonNode] {.async.} =
  ## JSONをGETリクエストで取得
  var merged_headers = if headers.isNil: newHttpHeaders() else: headers
  merged_headers["Accept"] = "application/json"
  
  let result = await client.fetch(url, merged_headers, options)
  
  if result.success:
    try:
      return parseJson(result.body)
    except:
      raise newException(ValueError, "JSONのパースに失敗しました: " & result.body)
  else:
    raise newException(HttpRequestError, "リクエストに失敗しました: " & result.error_msg)

proc postJson*(client: HttpClientEx, url: string, 
              json_data: JsonNode,
              headers: HttpHeaders = nil,
              options: RequestOptions = RequestOptions()): Future[JsonNode] {.async.} =
  ## JSONをPOSTリクエストで送信し、JSONレスポンスを取得
  var merged_headers = if headers.isNil: newHttpHeaders() else: headers
  
  # Content-Typeをapplication/jsonに設定
  merged_headers["Content-Type"] = "application/json"
  merged_headers["Accept"] = "application/json"
  
  let json_str = $json_data
  let result = await client.post(url, json_str, merged_headers, nil, options)
  
  if result.success:
    try:
      return parseJson(result.body)
    except:
      raise newException(ValueError, "JSONのパースに失敗しました: " & result.body)
  else:
    raise newException(HttpRequestError, "リクエストに失敗しました: " & result.error_msg)

proc postForm*(client: HttpClientEx, url: string,
              form_data: Table[string, string],
              headers: HttpHeaders = nil,
              options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## フォームデータをPOSTリクエストで送信
  var merged_headers = if headers.isNil: newHttpHeaders() else: headers
  merged_headers["Content-Type"] = "application/x-www-form-urlencoded"
  
  # フォームデータをエンコード
  var form_parts: seq[string] = @[]
  for key, value in form_data:
    form_parts.add(encodeUrl(key) & "=" & encodeUrl(value))
  
  let encoded_form = form_parts.join("&")
  
  return await client.post(url, encoded_form, merged_headers, nil, options)

proc postMultipartForm*(client: HttpClientEx, url: string,
                      form_data: MultipartData,
                      headers: HttpHeaders = nil,
                      options: RequestOptions = RequestOptions()): Future[FetchResult] {.async.} =
  ## マルチパートフォームデータをPOSTリクエストで送信
  # Content-Typeはhttpclientライブラリによって自動的に設定される
  return await client.post(url, "", headers, form_data, options)

proc createMultipartForm*(): MultipartData =
  ## マルチパートフォームデータを作成
  return newMultipartData()

proc addFormField*(form: MultipartData, name, value: string) =
  ## フォームフィールドをマルチパートフォームに追加
  form.add(name, value)

proc addFormFile*(form: MultipartData, field_name, file_path: string) =
  ## ファイルをマルチパートフォームに追加
  let file_name = extractFilename(file_path)
  let content_type = getMimeType(file_path)
  
  let file_data = readFile(file_path)
  form.add(field_name, file_data, file_name, content_type)

proc getStats*(client: HttpClientEx): RequestStats =
  ## HTTPクライアントの統計情報を取得
  return client.request_stats

proc resetStats*(client: HttpClientEx) =
  ## 統計情報をリセット
  client.request_stats = newRequestStats()

proc clearCache*(client: HttpClientEx) =
  ## キャッシュをクリア
  try:
    # キャッシュディレクトリのファイルを削除
    for kind, path in walkDir(client.cache_dir):
      if kind == pcFile:
        removeFile(path)
  except:
    if client.default_options.debug_mode:
      echo "キャッシュクリアエラー: ", getCurrentExceptionMsg()

proc getServerInfo*(client: HttpClientEx, url: string): Future[HttpServerInfo] {.async.} =
  ## サーバー情報を取得
  result = HttpServerInfo()
  
  try:
    let options = RequestOptions(
      timeout_seconds: 10,
      follow_redirects: false
    )
    
    let response = await client.head(url, options = options)
    
    if response.success:
      # Serverヘッダーから情報を抽出
      if response.headers.hasKey("Server"):
        let server = response.headers["Server"][0]
        result.software = server
        
        # バージョン情報の抽出を試みる
        let version_match = server.find(re"\d+(\.\d+)+")
        if version_match >= 0:
          let version_end = min(version_match + 10, server.len - 1)
          for i in version_match .. version_end:
            if i >= server.len or not (server[i].isDigit or server[i] == '.'):
              result.version = server[version_match .. i-1]
              break
      
      # X-Powered-Byヘッダーからプラットフォーム情報を抽出
      if response.headers.hasKey("X-Powered-By"):
        result.os = response.headers["X-Powered-By"][0]
      
      # X-Response-Timeヘッダーから生成時間を抽出
      if response.headers.hasKey("X-Response-Time"):
        let time_str = response.headers["X-Response-Time"][0]
        try:
          if "ms" in time_str:
            result.generation_time = parseFloat(time_str.replace("ms", ""))
          else:
            result.generation_time = parseFloat(time_str)
        except:
          discard
  except:
    discard

proc checkSecurityHeaders*(client: HttpClientEx, url: string): Future[HttpSecurityInfo] {.async.} =
  ## セキュリティヘッダーをチェック
  try:
    let options = RequestOptions(
      timeout_seconds: 10,
      follow_redirects: true
    )
    
    let response = await client.head(url, options = options)
    
    if response.success:
      return analyzeSecurity(response.headers)
    else:
      return HttpSecurityInfo()
  except:
    return HttpSecurityInfo()

proc detectRedirects*(client: HttpClientEx, url: string, max_redirects: int = 10): Future[RedirectInfo] {.async.} =
  ## リダイレクトを検出
  return await handleRedirects(client, url, max_redirects)

proc getCookiesForDomain*(client: HttpClientEx, domain: string): seq[Cookie] =
  ## 指定されたドメインのCookieを取得
  result = @[]
  for domain_key, domain_cookies in client.cookie_jar.cookies:
    if domain == domain_key or domain.endsWith("." & domain_key) or
       domain_key.endsWith("." & domain):
      for name, cookie in domain_cookies:
        result.add(cookie)
  
  return result

proc extractAllLinks*(client: HttpClientEx, html: string, base_url: string): seq[string] =
  ## HTMLからすべてのリンクを抽出
  result = @[]
  var i = 0
  var inside_a_tag = false
  var href = ""
  
  while i < html.len:
    # <a タグを探す
    if html[i] == '<' and i + 1 < html.len and html[i+1].toLowerAscii() == 'a':
      inside_a_tag = true
      href = ""
      
      # href属性を探す
      var j = i
      while j < html.len and html[j] != '>':
        if j + 5 < html.len and html[j..j+4].toLowerAscii() == "href=":
          j += 5
          let quote = html[j]
          if quote == '"' or quote == '\'':
            j += 1
            href = ""
            while j < html.len and html[j] != quote:
              href.add(html[j])
              j += 1
          else:
            href = ""
            while j < html.len and html[j] != ' ' and html[j] != '>':
              href.add(html[j])
              j += 1
          
          # 相対URLを絶対URLに変換
          if href.len > 0:
            if not href.startsWith("http") and not href.startsWith("//"):
              href = joinUrl(base_url, href)
            elif href.startsWith("//"):
              let uri = parseUri(base_url)
              href = uri.scheme & ":" & href
            
            # 結果に追加（重複を避ける）
            if href notin result:
              result.add(href)
          
          break
        j += 1
    
    # </a> タグを探す
    if inside_a_tag and html[i] == '<' and i + 3 < html.len and 
       html[i+1] == '/' and html[i+2].toLowerAscii() == 'a' and html[i+3] == '>':
      inside_a_tag = false
    
    i += 1
  
  return result

proc close*(client: HttpClientEx) =
  ## HTTPクライアントをクローズ
  client.cancelAllRequests()
  client.client.close()

when isMainModule:
  proc main() {.async.} =
    let client = newHttpClientEx()
    
    try:
      echo "HTTPリクエストを実行中..."
      let response = await client.fetch("https://example.com")
      
      if response.success:
        echo "ステータスコード: ", response.status_code
        echo "Content-Type: ", response.content_type
        echo "ボディサイズ: ", response.body.len, " バイト"
        
        # HTMLの場合はタイトルを抽出
        if isHtmlContentType(response.content_type):
          let title_start = response.body.find("<title>")
          let title_end = response.body.find("</title>")
          
          if title_start >= 0 and title_end >= 0:
            let title = response.body[title_start + 7 .. title_end - 1]
            echo "ページタイトル: ", title
      else:
        echo "エラー: ", response.error_msg
    finally:
      client.close()
  
  waitFor main() 