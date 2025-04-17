import std/[tables, httpclient, asyncdispatch, json, strutils, os, mimetypes, 
       options, times, uri, logging, sets, hashes, sha1, md5, base64, random, re, 
       sequtils, unicode, streams, math, parseutils, sugar]
import zippy
import ./client
import ./utils

type
  RequestBuilder* = ref object
    url*: string
    method*: HttpMethod
    headers*: HttpHeaders
    body*: string
    options*: RequestOptions
    form_data*: MultipartData
    query_params*: Table[string, string]
    content_type*: string
    cookies*: CookieJar
    auth_type*: HttpAuthType
    username*: string
    password*: string
    token*: string
    retry_config*: RetryConfig
    timeout_config*: TimeoutConfig
    cache_config*: CacheConfig
    metrics*: RequestMetrics
    debug_mode*: bool
    validation_level*: ValidationLevel
    expected_status*: set[int]
    response_handlers*: seq[ResponseHandler]
    request_hooks*: seq[RequestHook]
    stream_mode*: bool
    compression*: bool
    auto_decompress*: bool
    follow_redirects*: bool
    max_redirects*: int
    ssl_config*: SslConfig
    proxy_config*: ProxyConfig
    connection_config*: ConnectionConfig
    cookies_enabled*: bool
    auto_referer*: bool
    user_agent*: string
    boundary*: string
    files*: seq[FileUpload]
    json_node*: JsonNode
    event_handler*: Option[RequestEventHandler]
    priority*: RequestPriority
    request_id*: string
    cache_key*: string
    progress_tracker*: ProgressTracker
    mime_types*: MimeTypeHandler
    error_handler*: ErrorHandler
    
  ResponseHandler* = object
    content_type*: string
    handler*: proc(body: string): JsonNode

  RequestHook* = object
    phase*: HookPhase
    handler*: proc(builder: RequestBuilder): RequestBuilder

  HookPhase* = enum
    hpBeforeRequest, 
    hpAfterResponse, 
    hpBeforeRetry

  RetryConfig* = object
    max_retries*: int
    retry_delay_ms*: int
    retry_status_codes*: set[int]
    retry_methods*: set[HttpMethod]
    backoff_factor*: float
    jitter*: bool
    retry_on_network_error*: bool
    retry_on_timeout*: bool
    retry_on_connection_error*: bool

  TimeoutConfig* = object
    connect_timeout_seconds*: int
    read_timeout_seconds*: int
    write_timeout_seconds*: int
    idle_timeout_seconds*: int
    keepalive_timeout_seconds*: int
    total_timeout_seconds*: int

  CacheConfig* = object
    use_cache*: bool
    max_age_seconds*: int
    revalidate*: bool
    bypass_network*: bool
    force_cache*: bool

  RequestMetrics* = object
    start_time*: Time
    end_time*: Time
    dns_time*: Duration
    tcp_time*: Duration
    tls_time*: Duration
    ttfb_time*: Duration
    download_time*: Duration
    total_time*: Duration
    attempts*: int
    upload_size*: int
    download_size*: int
    success*: bool
    
  ValidationLevel* = enum
    vlNone,        # バリデーションなし
    vlBasic,       # 基本的なバリデーション（URL形式など）
    vlStrict,      # 厳格なバリデーション（全ての入力を検証）
    vlSanitize     # 入力の浄化（危険な文字を置換など）

  SslConfig* = object
    verify*: bool
    cert_file*: string
    key_file*: string
    ca_file*: string
    cipher_list*: string
    verify_hostname*: bool
    min_tls_version*: TlsVersion

  ConnectionConfig* = object
    keepalive*: bool
    pool_size*: int
    pool_timeout*: int
    use_http2*: bool
    use_pipeline*: bool
    tcp_nodelay*: bool
    reuse_connection*: bool

  RequestEventKind* = enum
    rekStart, rekDnsResolved, rekConnected, rekTlsHandshake, 
    rekHeadersSent, rekBodySent, rekHeadersReceived, rekBodyReceived, 
    rekComplete, rekRedirect, rekRetry, rekError, rekProgress, rekCancel

  RequestEvent* = object
    kind*: RequestEventKind
    request_id*: string
    timestamp*: Time
    case kind*: RequestEventKind
      of rekStart:
        url*: string
        method*: HttpMethod
      of rekDnsResolved:
        hostname*: string
        ip*: string
      of rekConnected, rekTlsHandshake, rekHeadersSent, rekBodySent:
        elapsed*: Duration
      of rekHeadersReceived:
        status_code*: int
        headers*: HttpHeaders
      of rekBodyReceived:
        body_size*: int
      of rekComplete:
        total_time*: Duration
        status*: int
      of rekRedirect:
        from_url*: string
        to_url*: string
        redirect_type*: int
      of rekRetry:
        attempt*: int
        reason*: string
        next_delay*: int
      of rekError:
        error_message*: string
        recoverable*: bool
      of rekProgress:
        bytes_transferred*: int
        total_bytes*: int
        percentage*: float
      of rekCancel:
        reason*: string

  RequestEventHandler* = proc(event: RequestEvent)

  FileUpload* = object
    field_name*: string
    file_path*: string
    mime_type*: string
    file_name*: string
    data*: string

  ProgressTracker* = object
    callback*: proc(transferred, total: int, percentage: float)
    upload_progress*: float
    download_progress*: float
    total_size*: int
    transferred*: int
    last_update*: Time
    update_interval_ms*: int
    enabled*: bool
    
  MimeTypeHandler* = object
    mime_types*: Table[string, string]
    detect_from_extension*: bool
    default_mime_type*: string
    
  ErrorHandler* = object
    on_network_error*: proc(builder: RequestBuilder, error: string): RequestBuilder
    on_timeout*: proc(builder: RequestBuilder): RequestBuilder
    on_validation_error*: proc(builder: RequestBuilder, errors: seq[string]): RequestBuilder
    on_server_error*: proc(builder: RequestBuilder, status_code: int): RequestBuilder
    on_client_error*: proc(builder: RequestBuilder, status_code: int): RequestBuilder
    on_failure*: proc(builder: RequestBuilder, result: FetchResult): RequestBuilder
    retry_on_codes*: set[int]
    max_retry_attempts*: int

# リクエストビルダーの生成/設定メソッド

proc newRequestBuilder*(url: string, method: HttpMethod = HttpGet): RequestBuilder =
  ## 新しいRequestBuilderを作成
  let request_id = $getTime().toUnix() & "-" & $rand(high(int32))
  
  result = RequestBuilder(
    url: url,
    method: method,
    headers: newHttpHeaders(),
    body: "",
    options: RequestOptions(),
    form_data: nil,
    query_params: initTable[string, string](),
    content_type: "",
    cookies: newCookieJar(),
    auth_type: atNone,
    retry_config: RetryConfig(
      max_retries: 3,
      retry_delay_ms: 1000,
      retry_status_codes: {500, 502, 503, 504},
      retry_methods: {HttpGet, HttpHead, HttpOptions},
      backoff_factor: 2.0,
      jitter: true,
      retry_on_network_error: true,
      retry_on_timeout: true,
      retry_on_connection_error: true
    ),
    timeout_config: TimeoutConfig(
      connect_timeout_seconds: 10,
      read_timeout_seconds: 30,
      write_timeout_seconds: 10,
      idle_timeout_seconds: 60,
      keepalive_timeout_seconds: 60,
      total_timeout_seconds: 60
    ),
    cache_config: CacheConfig(
      use_cache: true,
      max_age_seconds: 3600,
      revalidate: false,
      bypass_network: false,
      force_cache: false
    ),
    metrics: RequestMetrics(
      start_time: getTime(),
      attempts: 0
    ),
    debug_mode: false,
    validation_level: vlBasic,
    expected_status: {200..299},
    response_handlers: @[],
    request_hooks: @[],
    stream_mode: false,
    compression: true,
    auto_decompress: true,
    follow_redirects: true,
    max_redirects: 5,
    ssl_config: SslConfig(
      verify: true,
      verify_hostname: true,
      min_tls_version: tlsV12
    ),
    proxy_config: ProxyConfig(),
    connection_config: ConnectionConfig(
      keepalive: true,
      pool_size: 10,
      use_http2: false,
      tcp_nodelay: true,
      reuse_connection: true
    ),
    cookies_enabled: true,
    auto_referer: true,
    user_agent: "QuantumBrowser/1.0",
    boundary: createRandomBoundary(),
    files: @[],
    progress_tracker: ProgressTracker(
      update_interval_ms: 500,
      enabled: false,
      last_update: getTime()
    ),
    mime_types: MimeTypeHandler(
      default_mime_type: "application/octet-stream",
      detect_from_extension: true
    ),
    error_handler: ErrorHandler(
      retry_on_codes: {500, 502, 503, 504, 429},
      max_retry_attempts: 3
    ),
    request_id: request_id
  )
  
  # デフォルトのヘッダー設定
  result.headers["User-Agent"] = result.user_agent
  result.headers["Accept"] = "*/*"

proc validateUrl(url: string, level: ValidationLevel): tuple[valid: bool, errors: seq[string]] =
  ## URLを検証する
  var errors: seq[string] = @[]
  
  case level:
    of vlNone:
      return (valid: true, errors: errors)
    
    of vlBasic:
      # 基本的な検証
      if url.len == 0:
        errors.add("URLが空です")
        return (valid: false, errors: errors)
      
      try:
        let uri = parseUri(url)
        if uri.scheme.len == 0:
          errors.add("スキームが指定されていません")
        
        if uri.hostname.len == 0 and uri.scheme != "file":
          errors.add("ホスト名が指定されていません")
      except:
        errors.add("URLのパースに失敗しました")
        return (valid: false, errors: errors)
    
    of vlStrict:
      # 厳格な検証
      let validation = validateUrl(url)
      if not validation.is_valid:
        return (valid: false, errors: validation.validation_errors)
    
    of vlSanitize:
      # 危険な文字があるか確認
      if "javascript:" in url.toLowerAscii():
        errors.add("URLに危険なスキームが含まれています")
      
      if "<" in url or ">" in url:
        errors.add("URLに危険な文字が含まれています")
  
  return (valid: errors.len == 0, errors: errors)

proc getOptionsFromBuilder(rb: RequestBuilder): RequestOptions =
  ## RequestBuilderからRequestOptionsオブジェクトを作成
  result = RequestOptions(
    timeout_seconds: rb.timeout_config.total_timeout_seconds,
    follow_redirects: rb.follow_redirects,
    max_redirects: rb.max_redirects,
    ssl_verify: rb.ssl_config.verify,
    compression: rb.compression,
    retry_count: rb.retry_config.max_retries,
    retry_delay_ms: rb.retry_config.retry_delay_ms,
    dns_cache: true,
    auto_decompress: rb.auto_decompress,
    auto_referer: rb.auto_referer,
    debug_mode: rb.debug_mode,
    priority: rb.priority,
    keepalive: rb.connection_config.keepalive
  )
  
  if rb.proxy_config.url.len > 0:
    result.proxy_url = rb.proxy_config.url

# リクエストビルダーのチェインメソッド定義

proc withHeader*(rb: RequestBuilder, key, value: string): RequestBuilder =
  ## HTTPヘッダーを追加
  rb.headers[key] = value
  return rb

proc withHeaders*(rb: RequestBuilder, headers: HttpHeaders): RequestBuilder =
  ## 複数のHTTPヘッダーを追加
  for key, value in headers.table:
    rb.headers[key] = value
  return rb

proc withUserAgent*(rb: RequestBuilder, user_agent: string): RequestBuilder =
  ## User-Agentヘッダーを設定
  rb.headers["User-Agent"] = user_agent
  rb.user_agent = user_agent
  return rb

proc withAccept*(rb: RequestBuilder, accept: string): RequestBuilder =
  ## Acceptヘッダーを設定
  rb.headers["Accept"] = accept
  return rb

proc withAcceptLanguage*(rb: RequestBuilder, language: string): RequestBuilder =
  ## Accept-Languageヘッダーを設定
  rb.headers["Accept-Language"] = language
  return rb

proc withAcceptEncoding*(rb: RequestBuilder, encoding: string): RequestBuilder =
  ## Accept-Encodingヘッダーを設定
  rb.headers["Accept-Encoding"] = encoding
  return rb

proc withReferer*(rb: RequestBuilder, referer: string): RequestBuilder =
  ## Refererヘッダーを設定
  rb.headers["Referer"] = referer
  return rb

proc withOrigin*(rb: RequestBuilder, origin: string): RequestBuilder =
  ## Originヘッダーを設定
  rb.headers["Origin"] = origin
  return rb

proc withBody*(rb: RequestBuilder, body: string, content_type: string = ""): RequestBuilder =
  ## リクエストボディを設定
  rb.body = body
  if content_type.len > 0:
    rb.content_type = content_type
    rb.headers["Content-Type"] = content_type
  return rb

proc withJsonBody*(rb: RequestBuilder, json_data: JsonNode): RequestBuilder =
  ## JSONリクエストボディを設定
  rb.body = $json_data
  rb.content_type = "application/json"
  rb.headers["Content-Type"] = "application/json"
  rb.json_node = json_data
  return rb

proc withFormData*(rb: RequestBuilder, form_data: MultipartData): RequestBuilder =
  ## フォームデータを設定
  rb.form_data = form_data
  return rb

proc withFormField*(rb: RequestBuilder, name, value: string): RequestBuilder =
  ## フォームフィールドを追加
  if rb.form_data.isNil:
    rb.form_data = newMultipartData()
  rb.form_data.add(name, value)
  return rb

proc withXmlBody*(rb: RequestBuilder, xml: string): RequestBuilder =
  ## XMLリクエストボディを設定
  rb.body = xml
  rb.content_type = "application/xml"
  rb.headers["Content-Type"] = "application/xml"
  return rb

proc withFile*(rb: RequestBuilder, field_name, file_path: string): RequestBuilder =
  ## ファイルをアップロード
  # ファイル情報を保存
  var upload = FileUpload(
    field_name: field_name,
    file_path: file_path,
    file_name: extractFilename(file_path)
  )
  
  # MIMEタイプを推測
  if rb.mime_types.detect_from_extension:
    upload.mime_type = getMimeType(file_path)
    if upload.mime_type.len == 0:
      upload.mime_type = rb.mime_types.default_mime_type
  else:
    upload.mime_type = rb.mime_types.default_mime_type
  
  rb.files.add(upload)
  
  # マルチパートフォームデータを作成・更新
  if rb.form_data.isNil:
    rb.form_data = newMultipartData()
  
  let file_data = readFile(file_path)
  rb.form_data.add(field_name, file_data, upload.file_name, upload.mime_type)
  
  return rb

proc withFormFile*(rb: RequestBuilder, field_name, file_path, content_type: string, file_name: string = ""): RequestBuilder =
  ## カスタム設定付きでファイルをアップロード
  var upload = FileUpload(
    field_name: field_name,
    file_path: file_path,
    mime_type: content_type,
    file_name: if file_name.len > 0: file_name else: extractFilename(file_path)
  )
  
  rb.files.add(upload)
  
  # マルチパートフォームデータを作成・更新
  if rb.form_data.isNil:
    rb.form_data = newMultipartData()
  
  let file_data = readFile(file_path)
  rb.form_data.add(field_name, file_data, upload.file_name, upload.mime_type)
  
  return rb

proc withBinaryData*(rb: RequestBuilder, field_name, data, file_name, content_type: string): RequestBuilder =
  ## バイナリデータをアップロード
  var upload = FileUpload(
    field_name: field_name,
    data: data,
    file_name: file_name,
    mime_type: content_type
  )
  
  rb.files.add(upload)
  
  # マルチパートフォームデータを作成・更新
  if rb.form_data.isNil:
    rb.form_data = newMultipartData()
  
  rb.form_data.add(field_name, data, file_name, content_type)
  
  return rb

proc withQueryParam*(rb: RequestBuilder, key, value: string): RequestBuilder =
  ## クエリパラメーターを追加
  rb.query_params[key] = value
  return rb

proc withQueryParams*(rb: RequestBuilder, params: Table[string, string]): RequestBuilder =
  ## 複数のクエリパラメーターを追加
  for key, value in params:
    rb.query_params[key] = value
  return rb

proc withCookie*(rb: RequestBuilder, name, value: string, domain: string = ""): RequestBuilder =
  ## Cookieを追加
  var cookie = Cookie(name: name, value: value)
  if domain.len > 0:
    cookie.domain = domain
  else:
    cookie.domain = extractDomain(rb.url)
  
  rb.cookies.addCookie(cookie)
  return rb

proc withCookies*(rb: RequestBuilder, cookies: seq[Cookie]): RequestBuilder =
  ## 複数のCookieを追加
  for cookie in cookies:
    rb.cookies.addCookie(cookie)
  return rb

proc withCookieJar*(rb: RequestBuilder, jar: CookieJar): RequestBuilder =
  ## CookieJarを設定
  rb.cookies = jar
  return rb

proc withBasicAuth*(rb: RequestBuilder, username, password: string): RequestBuilder =
  ## Basic認証の設定
  rb.auth_type = atBasic
  rb.username = username
  rb.password = password
  
  let auth_str = username & ":" & password
  let auth_b64 = encode(auth_str)
  rb.headers["Authorization"] = "Basic " & auth_b64
  return rb

proc withBearerAuth*(rb: RequestBuilder, token: string): RequestBuilder =
  ## Bearer認証の設定
  rb.auth_type = atBearer
  rb.token = token
  rb.headers["Authorization"] = "Bearer " & token
  return rb

proc withDigestAuth*(rb: RequestBuilder, username, password: string): RequestBuilder =
  ## Digest認証の設定
  ## RFC 2617およびRFC 7616に準拠したHTTP Digest認証を実装
  rb.auth_type = atDigest
  rb.username = username
  rb.password = password
  rb.digest_state = DigestAuthState(
    algorithm: "MD5",
    qop: "",
    nonce: "",
    cnonce: "",
    nonce_count: 0,
    opaque: "",
    realm: ""
  )
  # calculateDigestResponseメソッドで計算され、
  # 2回目のリクエストで適用される
  return rb

proc withOAuth2Auth*(rb: RequestBuilder, token: string, token_type: string = "Bearer"): RequestBuilder =
  ## OAuth2認証の設定
  rb.auth_type = atOAuth
  rb.token = token
  rb.headers["Authorization"] = token_type & " " & token
  return rb

proc withApiKey*(rb: RequestBuilder, key: string, param_type: string = "query", param_name: string = "api_key"): RequestBuilder =
  ## API Key認証の設定
  rb.auth_type = atApiKey
  
  case param_type.toLowerAscii():
    of "query":
      rb.query_params[param_name] = key
    of "header":
      rb.headers[param_name] = key
    else:
      rb.headers["X-API-Key"] = key
  
  return rb

proc withJwtAuth*(rb: RequestBuilder, jwt: string): RequestBuilder =
  ## JWT認証の設定
  rb.auth_type = atJWT
  rb.token = jwt
  rb.headers["Authorization"] = "Bearer " & jwt
  return rb

proc withNoAuth*(rb: RequestBuilder): RequestBuilder =
  ## 認証情報をクリア
  rb.auth_type = atNone
  rb.username = ""
  rb.password = ""
  rb.token = ""
  rb.headers.del("Authorization")
  return rb

proc withDebugMode*(rb: RequestBuilder, enabled: bool): RequestBuilder =
  ## デバッグモードを設定
  rb.debug_mode = enabled
  return rb

proc withProgressCallback*(rb: RequestBuilder, callback: proc(transferred, total: int, percentage: float)): RequestBuilder =
  ## 進捗コールバックを設定
  rb.progress_tracker.callback = callback
  rb.progress_tracker.enabled = true
  return rb

proc withEventHandler*(rb: RequestBuilder, handler: RequestEventHandler): RequestBuilder =
  ## イベントハンドラーを設定
  rb.event_handler = some(handler)
  return rb

proc withTimeout*(rb: RequestBuilder, seconds: int): RequestBuilder =
  ## タイムアウトを設定
  rb.timeout_config.total_timeout_seconds = seconds
  return rb

proc withConnectTimeout*(rb: RequestBuilder, seconds: int): RequestBuilder =
  ## 接続タイムアウトを設定
  rb.timeout_config.connect_timeout_seconds = seconds
  return rb

proc withReadTimeout*(rb: RequestBuilder, seconds: int): RequestBuilder =
  ## 読み込みタイムアウトを設定
  rb.timeout_config.read_timeout_seconds = seconds
  return rb

proc withWriteTimeout*(rb: RequestBuilder, seconds: int): RequestBuilder =
  ## 書き込みタイムアウトを設定
  rb.timeout_config.write_timeout_seconds = seconds
  return rb

proc withRetries*(rb: RequestBuilder, retries: int, delay_ms: int = 1000): RequestBuilder =
  ## リトライ設定
  rb.retry_config.max_retries = max(0, retries)
  rb.retry_config.retry_delay_ms = max(0, delay_ms)
  return rb

proc withExponentialBackoff*(rb: RequestBuilder, factor: float = 2.0, jitter: bool = true): RequestBuilder =
  ## 指数バックオフ設定
  rb.retry_config.backoff_factor = max(1.0, factor)
  rb.retry_config.jitter = jitter
  return rb

proc withRetryStatusCodes*(rb: RequestBuilder, codes: set[int]): RequestBuilder =
  ## リトライするステータスコードを設定
  rb.retry_config.retry_status_codes = codes
  return rb

proc withRetryMethods*(rb: RequestBuilder, methods: set[HttpMethod]): RequestBuilder =
  ## リトライするHTTPメソッドを設定
  rb.retry_config.retry_methods = methods
  return rb

proc withExpectedStatus*(rb: RequestBuilder, codes: set[int]): RequestBuilder =
  ## 期待するステータスコードを設定
  rb.expected_status = codes
  return rb

proc withFollowRedirects*(rb: RequestBuilder, follow: bool = true, max_redirects: int = 5): RequestBuilder =
  ## リダイレクトの設定
  rb.follow_redirects = follow
  rb.max_redirects = max_redirects
  return rb

proc withAutoReferer*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## 自動リファラー設定
  rb.auto_referer = enabled
  return rb

proc withCompression*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## 圧縮設定
  rb.compression = enabled
  
  if enabled:
    rb.headers["Accept-Encoding"] = "gzip, deflate, br"
  else:
    rb.headers.del("Accept-Encoding")
  
  return rb

proc withAutoDecompress*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## 自動展開設定
  rb.auto_decompress = enabled
  return rb

proc withProxy*(rb: RequestBuilder, proxy_url: string): RequestBuilder =
  ## プロキシを設定
  rb.proxy_config.url = proxy_url
  return rb

proc withSslVerification*(rb: RequestBuilder, verify: bool): RequestBuilder =
  ## SSL証明書の検証設定
  rb.ssl_config.verify = verify
  return rb

proc withSslCertificate*(rb: RequestBuilder, cert_file, key_file: string): RequestBuilder =
  ## クライアント証明書を設定
  rb.ssl_config.cert_file = cert_file
  rb.ssl_config.key_file = key_file
  return rb

proc withCacheControl*(rb: RequestBuilder, directive: string): RequestBuilder =
  ## Cache-Controlヘッダーを設定
  rb.headers["Cache-Control"] = directive
  return rb

proc withEtag*(rb: RequestBuilder, etag: string): RequestBuilder =
  ## If-None-Matchヘッダーを設定（ETag用）
  rb.headers["If-None-Match"] = etag
  return rb

proc withLastModified*(rb: RequestBuilder, last_modified: string): RequestBuilder =
  ## If-Modified-Sinceヘッダーを設定
  rb.headers["If-Modified-Since"] = last_modified
  return rb

proc withIfMatch*(rb: RequestBuilder, etag: string): RequestBuilder =
  ## If-Matchヘッダーを設定
  rb.headers["If-Match"] = etag
  return rb

proc withIfNoneMatch*(rb: RequestBuilder, etag: string): RequestBuilder =
  ## If-None-Matchヘッダーを設定
  rb.headers["If-None-Match"] = etag
  return rb

proc withPriority*(rb: RequestBuilder, priority: RequestPriority): RequestBuilder =
  ## リクエスト優先度を設定
  rb.priority = priority
  return rb

proc withCustomId*(rb: RequestBuilder, id: string): RequestBuilder =
  ## カスタムリクエストIDを設定
  rb.request_id = id
  return rb

proc withValidationLevel*(rb: RequestBuilder, level: ValidationLevel): RequestBuilder =
  ## バリデーションレベルを設定
  rb.validation_level = level
  return rb

proc withStreamMode*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## ストリームモードを設定
  rb.stream_mode = enabled
  return rb

proc withResponseHandler*(rb: RequestBuilder, content_type: string, 
                       handler: proc(body: string): JsonNode): RequestBuilder =
  ## レスポンスハンドラーを追加
  rb.response_handlers.add(ResponseHandler(
    content_type: content_type,
    handler: handler
  ))
  return rb

proc withHook*(rb: RequestBuilder, phase: HookPhase, 
             handler: proc(builder: RequestBuilder): RequestBuilder): RequestBuilder =
  ## リクエストフックを追加
  rb.request_hooks.add(RequestHook(
    phase: phase,
    handler: handler
  ))
  return rb

proc withErrorHandler*(rb: RequestBuilder, 
                     handler: proc(builder: RequestBuilder, result: FetchResult): RequestBuilder): RequestBuilder =
  ## エラーハンドラーを設定
  rb.error_handler.on_failure = handler
  return rb

proc withKeepalive*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## キープアライブを設定
  rb.connection_config.keepalive = enabled
  
  if enabled:
    rb.headers["Connection"] = "keep-alive"
  else:
    rb.headers["Connection"] = "close"
  
  return rb

proc withCookiesEnabled*(rb: RequestBuilder, enabled: bool = true): RequestBuilder =
  ## Cookie機能を有効/無効化
  rb.cookies_enabled = enabled
  return rb

proc withCachePolicy*(rb: RequestBuilder, use_cache: bool, max_age_seconds: int = 3600): RequestBuilder =
  ## キャッシュポリシーを設定
  rb.cache_config.use_cache = use_cache
  rb.cache_config.max_age_seconds = max_age_seconds
  return rb

proc buildUrl(rb: RequestBuilder): string =
  ## URLにクエリパラメータを追加して構築
  result = rb.url
  
  if rb.query_params.len > 0:
    let encoded_query = encodeQueryParams(rb.query_params)
    
    if '?' in result:
      # すでにクエリパラメータがある場合は & で結合
      result &= "&" & encoded_query
    else:
      # クエリパラメータがない場合は ? で結合
      result &= "?" & encoded_query

proc prepareRequest(rb: RequestBuilder): RequestBuilder =
  ## リクエストを実行する前の準備処理
  result = rb
  
  # リクエストの検証
  if rb.validation_level != vlNone:
    let validation = validateUrl(rb.url, rb.validation_level)
    if not validation.valid:
      if not rb.error_handler.on_validation_error.isNil:
        return rb.error_handler.on_validation_error(rb, validation.errors)
      else:
        echo "URL検証エラー: ", validation.errors.join(", ")
  
  # イベントハンドラが設定されている場合にスタートイベントを発火
  if rb.event_handler.isSome:
    let event = RequestEvent(
      kind: rekStart,
      request_id: rb.request_id,
      timestamp: getTime(),
      url: rb.url,
      method: rb.method
    )
    rb.event_handler.get()(event)
  
  # リクエスト前フックを実行
  for hook in rb.request_hooks:
    if hook.phase == hpBeforeRequest:
      result = hook.handler(result)
  
  # Content-Lengthヘッダーの設定（ボディがある場合）
  if rb.body.len > 0 and not rb.headers.hasKey("Content-Length"):
    rb.headers["Content-Length"] = $rb.body.len
  
  # キャッシュキーの設定
  rb.cache_key = getCacheKey(rb.url, rb.method, rb.headers)
  
  # 圧縮設定
  if rb.compression and not rb.headers.hasKey("Accept-Encoding"):
    rb.headers["Accept-Encoding"] = "gzip, deflate, br"
  
  # メトリクスの記録
  rb.metrics.start_time = getTime()
  rb.metrics.attempts += 1
  
  return rb

proc processResponse(rb: RequestBuilder, result: FetchResult): FetchResult =
  ## レスポンスの後処理
  var processed_result = result
  
  # メトリクス情報の更新
  rb.metrics.end_time = getTime()
  rb.metrics.total_time = rb.metrics.end_time - rb.metrics.start_time
  rb.metrics.download_size = result.downloaded_bytes
  rb.metrics.success = result.success
  
  # イベントハンドラが設定されている場合に完了イベントを発火
  if rb.event_handler.isSome and result.success:
    let event = RequestEvent(
      kind: rekComplete,
      request_id: rb.request_id,
      timestamp: getTime(),
      total_time: rb.metrics.total_time,
      status: result.status_code
    )
    rb.event_handler.get()(event)
  
  # レスポンスハンドラの実行
  if result.success:
    for handler in rb.response_handlers:
      if result.content_type.startsWith(handler.content_type):
        try:
          discard handler.handler(result.body)
        except:
          echo "レスポンスハンドラの実行中にエラーが発生しました: ", getCurrentExceptionMsg()
  
  # ステータスコードが期待値と一致するか確認
  if result.success and result.status_code notin rb.expected_status:
    processed_result.success = false
    processed_result.error_msg = "予期しないステータスコード: " & $result.status_code
    
    # エラーハンドラの実行
    if not rb.error_handler.on_failure.isNil:
      let updated_rb = rb.error_handler.on_failure(rb, processed_result)
      if updated_rb.retry_config.max_retries > 0 and 
         rb.metrics.attempts <= updated_rb.retry_config.max_retries and
         (result.status_code in rb.error_handler.retry_on_codes):
        # リトライを実行
        if rb.event_handler.isSome:
          let event = RequestEvent(
            kind: rekRetry,
            request_id: rb.request_id,
            timestamp: getTime(),
            attempt: rb.metrics.attempts,
            reason: "ステータスコード " & $result.status_code,
            next_delay: updated_rb.retry_config.retry_delay_ms
          )
          rb.event_handler.get()(event)
        
        # 次のリトライを実行
        let next_rb = updated_rb
        return next_rb.execute(nil).waitFor()
  
  # リクエスト後フックを実行
  for hook in rb.request_hooks:
    if hook.phase == hpAfterResponse:
      discard hook.handler(rb)
  
  return processed_result

proc calculateRetryDelay(rb: RequestBuilder, attempt: int): int =
  ## リトライ間隔を計算（指数バックオフとジッターを適用）
  let base_delay = rb.retry_config.retry_delay_ms
  
  if rb.retry_config.backoff_factor <= 1.0:
    return base_delay
  
  # 指数バックオフ計算
  let delay = base_delay * pow(rb.retry_config.backoff_factor, float(attempt - 1)).int
  
  # ジッターを適用（±30%）
  if rb.retry_config.jitter:
    let jitter_range = (delay.float * 0.3).int
    if jitter_range > 0:
      return delay + rand(-jitter_range..jitter_range)
  
  return delay

proc execute*(rb: RequestBuilder, client: HttpClientEx): Future[FetchResult] {.async.} =
  ## リクエストを実行
  var prepared_rb = rb.prepareRequest()
  
  # リクエストオプションの準備
  let options = getOptionsFromBuilder(prepared_rb)
  
  # Cookie ヘッダーを設定 (他のヘッダーを上書きしないように)
  if prepared_rb.cookies_enabled:
    let cookie_header = prepared_rb.cookies.getCookieHeader(prepared_rb.url)
    if cookie_header.len > 0:
      prepared_rb.headers["Cookie"] = cookie_header
  
  # リクエストURLの構築
  let request_url = prepared_rb.buildUrl()
  
  # クライアントの準備
  var http_client: HttpClientEx
  
  if client.isNil:
    # クライアントが指定されていない場合は新しく作成
    http_client = newHttpClientEx()
  else:
    http_client = client
  
  # 一時クライアントの場合は後でクローズする
  let should_close = client.isNil
  
  try:
    # Bodyの種類に応じてリクエストを実行
    var result: FetchResult
    
    if not prepared_rb.form_data.isNil:
      # マルチパートフォームデータがある場合
      result = await http_client.fetchWithMethod(
        request_url, 
        prepared_rb.method, 
        headers=prepared_rb.headers, 
        multipart=prepared_rb.form_data, 
        options=options
      )
    elif prepared_rb.body.len > 0:
      # ボディデータがある場合
      result = await http_client.fetchWithMethod(
        request_url, 
        prepared_rb.method, 
        headers=prepared_rb.headers, 
        body=prepared_rb.body, 
        options=options
      )
    else:
      # ボディがない場合
      result = await http_client.fetchWithMethod(
        request_url, 
        prepared_rb.method, 
        headers=prepared_rb.headers, 
        options=options
      )
    
    # レスポンス処理
    let processed_result = prepared_rb.processResponse(result)
    
    # レスポンスからCookieを処理
    if prepared_rb.cookies_enabled and result.success and result.headers.hasKey("Set-Cookie"):
      let cookie_strs = result.headers.getOrDefault("Set-Cookie")
      for cookie_str in cookie_strs:
        let cookie = parseCookie(cookie_str)
        prepared_rb.cookies.addCookie(cookie, request_url)
    
    return processed_result
    
  except Exception as e:
    # エラーイベントを発火
    if prepared_rb.event_handler.isSome:
      let event = RequestEvent(
        kind: rekError,
        request_id: prepared_rb.request_id,
        timestamp: getTime(),
        error_message: e.msg,
        recoverable: prepared_rb.metrics.attempts < prepared_rb.retry_config.max_retries
      )
      prepared_rb.event_handler.get()(event)
    
    # リトライの処理
    if prepared_rb.metrics.attempts < prepared_rb.retry_config.max_retries and 
       (prepared_rb.retry_config.retry_on_network_error or 
        (e of TimeoutError and prepared_rb.retry_config.retry_on_timeout) or
        (e of OSError and prepared_rb.retry_config.retry_on_connection_error)):
      
      # 指数バックオフとジッターを考慮したリトライディレイを計算
      let delay = calculateRetryDelay(prepared_rb, prepared_rb.metrics.attempts)
      
      echo "リクエストが失敗しました。リトライします（" & $prepared_rb.metrics.attempts & 
           "/" & $prepared_rb.retry_config.max_retries & "）: " & e.msg
      echo "リトライまで " & $delay & "ms 待機します..."
      
      # ディレイを適用
      await sleepAsync(delay)
      
      # リトライの実行（再帰的に）
      return await prepared_rb.execute(http_client)
    
    # エラー結果を作成
    var error_result = FetchResult(
      success: false,
      error_msg: e.msg,
      url: request_url,
      redirect_chain: @[]
    )
    
    if not prepared_rb.error_handler.on_failure.isNil:
      # エラーハンドラーを実行
      discard prepared_rb.error_handler.on_failure(prepared_rb, error_result)
    
    return error_result
  finally:
    # 一時クライアントの場合はクローズ
    if should_close:
      http_client.close()

# HTTPリクエストのショートカット関数

proc get*(url: string): RequestBuilder =
  ## GETリクエストのショートカット
  result = newRequestBuilder(url, HttpGet)

proc post*(url: string): RequestBuilder =
  ## POSTリクエストのショートカット
  result = newRequestBuilder(url, HttpPost)

proc put*(url: string): RequestBuilder =
  ## PUTリクエストのショートカット
  result = newRequestBuilder(url, HttpPut)

proc delete*(url: string): RequestBuilder =
  ## DELETEリクエストのショートカット
  result = newRequestBuilder(url, HttpDelete)

proc head*(url: string): RequestBuilder =
  ## HEADリクエストのショートカット
  result = newRequestBuilder(url, HttpHead)

proc options*(url: string): RequestBuilder =
  ## OPTIONSリクエストのショートカット
  result = newRequestBuilder(url, HttpOptions)

proc patch*(url: string): RequestBuilder =
  ## PATCHリクエストのショートカット
  result = newRequestBuilder(url, HttpPatch)

proc jsonRequest*(url: string, method: HttpMethod, data: JsonNode): RequestBuilder =
  ## JSONリクエストのショートカット
  result = newRequestBuilder(url, method)
  discard result.withJsonBody(data)

proc jsonGet*(url: string, params: Table[string, string] = initTable[string, string]()): RequestBuilder =
  ## JSON GETリクエストのショートカット
  result = get(url)
  result.headers["Accept"] = "application/json"
  
  for key, value in params:
    discard result.withQueryParam(key, value)
  
  return result

proc jsonPost*(url: string, data: JsonNode): RequestBuilder =
  ## JSON POSTリクエストのショートカット
  result = post(url).withJsonBody(data)

proc jsonPut*(url: string, data: JsonNode): RequestBuilder =
  ## JSON PUTリクエストのショートカット
  result = put(url).withJsonBody(data)

proc jsonPatch*(url: string, data: JsonNode): RequestBuilder =
  ## JSON PATCHリクエストのショートカット
  result = patch(url).withJsonBody(data)

proc xmlRequest*(url: string, method: HttpMethod, xml: string): RequestBuilder =
  ## XMLリクエストのショートカット
  result = newRequestBuilder(url, method)
  discard result.withXmlBody(xml)

proc formPost*(url: string): RequestBuilder =
  ## フォームPOSTリクエストのショートカット
  result = post(url)
  result.headers["Content-Type"] = "application/x-www-form-urlencoded"

proc multipartFormPost*(url: string): RequestBuilder =
  ## マルチパートフォームPOSTリクエストのショートカット
  result = post(url)
  result.form_data = newMultipartData()

proc download*(url: string, destination: string, client: HttpClientEx): Future[FetchResult] {.async.} =
  ## ファイルをダウンロード (シンプル版)
  let rb = get(url)
  let result = await rb.execute(client)
  
  if result.success:
    # ディレクトリが存在しない場合は作成
    let dir = parentDir(destination)
    if not dirExists(dir):
      createDir(dir)
      
    writeFile(destination, result.body)
  
  return result

proc downloadWithProgress*(url: string, destination: string, client: HttpClientEx,
                        progress_callback: proc(transferred, total: int, percentage: float)): Future[FetchResult] {.async.} =
  ## 進捗コールバック付きファイルダウンロード
  let rb = get(url).withProgressCallback(progress_callback)
  let result = await rb.execute(client)
  
  if result.success:
    # ディレクトリが存在しない場合は作成
    let dir = parentDir(destination)
    if not dirExists(dir):
      createDir(dir)
      
    writeFile(destination, result.body)
  
  return result

proc uploadFile*(url: string, file_path: string, field_name: string = "file",
              client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## ファイルのアップロード
  let rb = post(url).withFile(field_name, file_path)
  return await rb.execute(client)

proc executeRequest*(method: HttpMethod, url: string, 
                   body: string = "", 
                   headers: HttpHeaders = nil,
                   client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## 汎用リクエスト実行関数
  let rb = newRequestBuilder(url, method)
  
  if body.len > 0:
    discard rb.withBody(body)
  
  if not headers.isNil:
    discard rb.withHeaders(headers)
  
  return await rb.execute(client)

# 特殊なリクエストパターン

proc requestWithRetry*(url: string, method: HttpMethod = HttpGet,
                     max_retries: int = 3, 
                     retry_delay_ms: int = 1000,
                     retry_status_codes: set[int] = {500, 502, 503, 504, 429},
                     client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## リトライ機能付きリクエスト
  let rb = newRequestBuilder(url, method)
                 .withRetries(max_retries, retry_delay_ms)
                 .withRetryStatusCodes(retry_status_codes)
                 .withExponentialBackoff()
  
  return await rb.execute(client)

proc requestWithTimeout*(url: string, method: HttpMethod = HttpGet,
                       timeout_seconds: int = 5,
                       client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## タイムアウト付きリクエスト
  let rb = newRequestBuilder(url, method)
                 .withTimeout(timeout_seconds)
  
  return await rb.execute(client)

proc requestWithBasicAuth*(url: string, username, password: string,
                         method: HttpMethod = HttpGet,
                         client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## Basic認証付きリクエスト
  let rb = newRequestBuilder(url, method)
                 .withBasicAuth(username, password)
  
  return await rb.execute(client)

proc requestWithBearerAuth*(url: string, token: string,
                          method: HttpMethod = HttpGet,
                          client: HttpClientEx = nil): Future[FetchResult] {.async.} =
  ## Bearer認証付きリクエスト
  let rb = newRequestBuilder(url, method)
                 .withBearerAuth(token)
  
  return await rb.execute(client)

proc requestJson*(url: string, method: HttpMethod = HttpGet,
                json_data: JsonNode = nil,
                client: HttpClientEx = nil): Future[JsonNode] {.async.} =
  ## JSONリクエストを実行し、JSONレスポンスを返す
  var rb = newRequestBuilder(url, method)
           .withAccept("application/json")
  
  if not json_data.isNil:
    rb = rb.withJsonBody(json_data)
  
  let result = await rb.execute(client)
  
  if result.success:
    try:
      return parseJson(result.body)
    except:
      raise newException(ValueError, "JSONのパースに失敗しました: " & result.body)
  else:
    raise newException(HttpRequestError, "リクエストに失敗しました: " & result.error_msg)

proc requestMultiple*(urls: seq[string], 
                    method: HttpMethod = HttpGet,
                    max_concurrent: int = 5,
                    client: HttpClientEx = nil): Future[seq[FetchResult]] {.async.} =
  ## 複数URLを同時にリクエスト
  var results = newSeq[FetchResult](urls.len)
  var futures = newSeq[Future[FetchResult]](urls.len)
  var temp_client: HttpClientEx
  
  # クライアントの準備
  if client.isNil:
    temp_client = newHttpClientEx()
  else:
    temp_client = client
  
  # 同時実行数の制限
  let batch_size = max(1, min(max_concurrent, 10))
  var completed = 0
  
  while completed < urls.len:
    var batch_end = min(completed + batch_size, urls.len)
    var batch_futures: seq[Future[FetchResult]] = @[]
    
    # バッチのリクエストを開始
    for i in completed ..< batch_end:
      let rb = newRequestBuilder(urls[i], method)
      let future = rb.execute(temp_client)
      futures[i] = future
      batch_futures.add(future)
    
    # バッチの完了を待機
    await all(batch_futures)
    
    # 結果を取得
    for i in completed ..< batch_end:
      try:
        results[i] = futures[i].read()
      except Exception as e:
        # エラー情報を記録
        results[i] = FetchResult(
          success: false,
          error_msg: e.msg,
          url: urls[i],
          redirect_chain: @[]
        )
    
    completed = batch_end
  
  # 一時クライアントを閉じる
  if client.isNil:
    temp_client.close()
  
  return results

# テスト用コード
when isMainModule:
  proc main() {.async.} =
    let client = newHttpClientEx()
    
    try:
      echo "サンプルHTTPリクエストを実行中..."
      
      # シンプルなGETリクエスト
      let result1 = await get("https://example.com").execute(client)
      
      if result1.success:
        echo "GET成功: " & result1.url
        echo "ステータスコード: " & $result1.status_code
        echo "コンテンツタイプ: " & result1.content_type
        echo "ボディサイズ: " & $result1.body.len & " バイト"
      else:
        echo "GET失敗: " & result1.error_msg
      
      # POSTリクエスト + JSON
      let json_data = %*{
        "name": "テストユーザー",
        "email": "test@example.com"
      }
      
      let result2 = await jsonPost("https://postman-echo.com/post", json_data).execute(client)
      
      if result2.success:
        echo "\nPOST成功: " & result2.url
        echo "ステータスコード: " & $result2.status_code
        echo "コンテンツタイプ: " & result2.content_type
        echo "レスポンス: " & result2.body[0..min(100, result2.body.len-1)]
      else:
        echo "\nPOST失敗: " & result2.error_msg
      
      # リトライ付きリクエスト
      echo "\n最大3回のリトライ付きリクエストを実行..."
      let result3 = await requestWithRetry("https://httpbin.org/status/500", max_retries = 3)
      
      echo "リトライ結果: " & (if result3.success: "成功" else: "失敗: " & result3.error_msg)
      
      echo "\nすべてのリクエストが完了しました。"
    finally:
      client.close()
  
  waitFor main() 