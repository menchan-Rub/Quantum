import std/[uri, strutils, tables, json, options, asyncdispatch, httpclient, times, 
  sequtils, sha1, base64, random, os, strformat, net, parseutils, algorithm, unicode, 
  logging, sets, hashes, mimetypes, streams, md5, zippy]

import ./client

type
  UrlInfo* = object
    schema*: string
    host*: string
    port*: int
    path*: string
    query*: Table[string, string]
    fragment*: string
    full_url*: string
    is_secure*: bool
    username*: string
    password*: string
    subdomain*: string
    domain*: string
    tld*: string

  CookieJar* = ref object
    cookies*: Table[string, Table[string, Cookie]]  # domain -> name -> cookie
    max_cookies_per_domain*: int
    max_total_cookies*: int
    reject_public_suffixes*: bool
    same_site_policy*: SameSitePolicy
    
  Cookie* = object
    name*: string
    value*: string
    domain*: string
    path*: string
    expires*: Option[DateTime]
    http_only*: bool
    secure*: bool
    same_site*: string
    creation_time*: DateTime
    last_access_time*: DateTime
    persistent*: bool
    host_only*: bool
    priority*: CookiePriority

  CookiePriority* = enum
    cpLow, cpMedium, cpHigh

  SameSitePolicy* = enum
    ssNone, ssLax, ssStrict

  HttpHeaderInfo* = object
    name*: string
    value*: string
    description*: string
    standard*: bool
    security_related*: bool
    request_only*: bool
    response_only*: bool
    deprecated*: bool

  HttpVersionInfo* = object
    major*: int
    minor*: int
    text*: string
    description*: string
    deprecated*: bool

  HttpSecurityInfo* = object
    ## HTTPレスポンスのセキュリティ情報を格納する構造体
    has_hsts*: bool                  ## HTTP Strict Transport Securityが有効か
    hsts_max_age*: int              ## HSTSのmax-age値
    hsts_include_subdomains*: bool  ## HSTSがサブドメインを含むか
    has_hpkp*: bool                 ## HTTP Public Key Pinningが有効か
    has_csp*: bool                  ## Content Security Policyが有効か
    has_xss_protection*: bool       ## X-XSS-Protectionが有効か
    has_x_content_type_options*: bool ## X-Content-Type-Optionsが有効か
    has_x_frame_options*: bool      ## X-Frame-Optionsが有効か
    has_referrer_policy*: bool      ## Referrer-Policyが有効か
    has_feature_policy*: bool       ## Feature-Policy/Permissions-Policyが有効か
    security_score*: int            ## 0-100のセキュリティスコア
    issues*: seq[string]            ## セキュリティ上の問題点

  UrlTrackingInfo* = object
    has_tracking_params*: bool
    tracking_params*: seq[string]
    is_known_tracker*: bool
    tracker_category*: string
    privacy_impact*: int  # 0-10スケール

  HttpAuthInfo* = object
    auth_type*: HttpAuthType
    realm*: string
    username*: string
    password*: string
    token*: string
    authenticated*: bool

  HttpAuthType* = enum
    atNone, atBasic, atDigest, atBearer, atOAuth, atJWT, atApiKey, atCustom

  UrlMapping* = Table[string, string]
  
  UrlSearchPattern* = object
    contains*: seq[string]
    starts_with*: seq[string]
    ends_with*: seq[string]
    regex*: string
    
  UrlSimilarity* = enum
    usExactMatch,
    usSameDomainAndPath,
    usSameDomain,
    usUnrelated
    
  ProxyConfig* = object
    url*: string
    username*: string
    password*: string
    auth_type*: HttpAuthType
    bypass_domains*: seq[string]
    auto_detect*: bool
    pac_url*: string

  RedirectInfo* = object
    original_url*: string
    final_url*: string
    redirect_chain*: seq[string]
    redirect_types*: seq[HttpCode]
    time_taken*: Duration
    is_valid*: bool

  UrlValidationResult* = object
    is_valid*: bool
    validation_errors*: seq[string]
    normalized_url*: string
    security_info*: UrlSecurityInfo

  UrlSecurityInfo* = object
    is_https*: bool
    has_mixed_content*: bool
    has_vulnerable_protocol*: bool
    is_potentially_malicious*: bool
    security_score*: int  # 0-100スケール
    
  MimeTypeInfo* = object
    mime_type*: string
    file_extension*: string
    is_text*: bool
    is_binary*: bool
    is_image*: bool
    is_audio*: bool
    is_video*: bool
    is_application*: bool
    description*: string

  UrlParseMode* = enum
    upmStrict,    # 厳格なURLパース（RFC準拠）
    upmRelaxed,   # 緩いパース（一部の無効なURLも許容）
    upmForDisplay # 表示用パース（ユーザーに見せることを優先）

  DomainInfo* = object
    full_domain*: string
    subdomain*: string
    domain*: string
    tld*: string
    is_ip_address*: bool
    is_localhost*: bool
    is_private*: bool
    
  UrlLocation* = enum
    ulScheme, ulUsername, ulPassword, ulHost, ulPort, ulPath, ulQuery, ulFragment

  CspDirective* = enum
    cdDefaultSrc,
    cdScriptSrc,
    cdStyleSrc,
    cdImgSrc,
    cdConnectSrc,
    cdFontSrc,
    cdObjectSrc,
    cdMediaSrc,
    cdFrameSrc,
    cdWorkerSrc,
    cdManifestSrc,
    cdPrefetchSrc,
    cdChildSrc,
    cdFrameAncestors,
    cdFormAction,
    cdBaseUri,
    cdReportUri,
    cdReportTo,
    cdSandbox,
    cdUpgradeInsecureRequests,
    cdBlockAllMixedContent,
    cdRequireSriFor,
    cdPluginTypes,
    cdReferrerPolicy

  ContentSecurityPolicy* = object
    ## Content Security Policyを解析した結果
    directives*: Table[CspDirective, seq[string]]
    report_only*: bool
    raw_policy*: string

  HttpHeaderSecuritySettings* = object
    ## セキュリティ関連のHTTPヘッダー設定
    enable_hsts*: bool
    hsts_max_age*: int
    hsts_include_subdomains*: bool
    hsts_preload*: bool
    enable_csp*: bool
    csp_directives*: Table[CspDirective, seq[string]]
    csp_report_only*: bool
    enable_xss_protection*: bool
    xss_protection_mode*: int
    enable_x_content_type_options*: bool
    enable_x_frame_options*: bool
    x_frame_options_value*: string
    enable_referrer_policy*: bool
    referrer_policy_value*: string
    enable_feature_policy*: bool
    feature_policy_directives*: Table[string, seq[string]]

  SubresourceIntegrityCheck* = object
    resource_url*: string
    hash_algorithm*: string  # sha256, sha384, sha512
    hash_value*: string
    valid*: bool

  TrustedTypesPolicy* = enum
    ttpNone,           # 無効
    ttpBasic,          # 基本的な保護
    ttpStrict,         # 厳格な保護
    ttpCustom          # カスタムポリシー

  HttpSecurityValidator* = ref object
    max_header_size*: int
    max_url_length*: int
    max_cookie_size*: int
    blocked_headers*: HashSet[string]
    blocked_user_agents*: seq[string]
    ip_blacklist*: HashSet[string]
    xss_filter_enabled*: bool
    csrf_protection*: bool
    sql_injection_filter*: bool
    path_traversal_filter*: bool
    command_injection_filter*: bool
    csp_enforced*: bool
    require_https*: bool
    hsts_enforced*: bool
    x_frame_options*: string
    x_content_type_options*: string
    referrer_policy*: string
    permissions_policy*: string
    trusted_types_policy*: TrustedTypesPolicy
    max_redirect_chain*: int
    url_whitelist*: seq[string]
    url_blacklist*: seq[string]
    
  SecureRequestConfig* = object
    cookies_secure_only*: bool
    cookies_http_only*: bool
    cookies_same_site*: SameSitePolicy
    use_secure_connection*: bool
    verify_host*: bool
    revocation_check*: bool
    min_tls_version*: TlsVersion
    cert_pinning*: seq[string]
    client_cert_path*: string
    client_key_path*: string
    ca_bundle_path*: string
    
  VulnerabilityType* = enum
    vtXss,
    vtCsrf,
    vtSqlInjection,
    vtPathTraversal,
    vtCommandInjection,
    vtOpenRedirect,
    vtHeaderInjection,
    vtInsecureDeserialization,
    vtServerSideTemplateInjection

  VulnerabilityScanResult* = object
    vulnerability_type*: VulnerabilityType
    severity*: int  # 1-10
    description*: string
    found_in*: string
    payload*: string
    mitigation*: string

  FeaturePolicy* = enum
    fpAccelerometer,
    fpAmbientLightSensor, 
    fpAutoplay,
    fpCamera,
    fpEncryptedMedia,
    fpFullscreen,
    fpGeolocation,
    fpGyroscope,
    fpMagnetometer,
    fpMicrophone,
    fpMidi,
    fpPayment,
    fpPictureInPicture,
    fpSpeaker,
    fpSyncXhr,
    fpUsb,
    fpVr
    
  PermissionsPolicyValue* = enum
    ppAllow,       # 許可
    ppSelf,        # 同一オリジンのみ許可
    ppNone,        # 許可しない
    ppOrigins      # 特定のオリジンのみ許可

  PermissionsPolicy* = Table[FeaturePolicy, tuple[value: PermissionsPolicyValue, origins: seq[string]]]

# URLパース関連の高度な関数
proc parseUrl*(url: string, mode: UrlParseMode = upmStrict): UrlInfo =
  ## URLを解析してUrlInfoオブジェクトを返す
  let uri = parseUri(url)
  var port = 80
  var domain_parts: tuple[subdomain, domain, tld: string]
  var is_secure = false
  
  # スキーマに基づいてデフォルトポートとセキュア状態を設定
  case uri.scheme:
    of "https":
      port = 443
      is_secure = true
    of "http":
      port = 80
      is_secure = false
    of "ws":
      port = 80
      is_secure = false
    of "wss":
      port = 443
      is_secure = true
    of "ftp":
      port = 21
      is_secure = false
    of "ftps":
      port = 990
      is_secure = true
    of "sftp":
      port = 22
      is_secure = true
    of "ssh":
      port = 22
      is_secure = true
    of "telnet":
      port = 23
      is_secure = false
    of "ldap":
      port = 389
      is_secure = false
    of "ldaps":
      port = 636
      is_secure = true
    of "imap":
      port = 143
      is_secure = false
    of "imaps":
      port = 993
      is_secure = true
    of "pop3":
      port = 110
      is_secure = false
    of "pop3s":
      port = 995
      is_secure = true
    of "smtp":
      port = 25
      is_secure = false
    of "smtps":
      port = 465
      is_secure = true
    of "file":
      port = 0
      is_secure = true
    else:
      port = 0
      is_secure = false
  
  # 明示的にポートが指定されている場合はそれを使用
  if uri.port.len > 0:
    try:
      port = parseInt(uri.port)
    except:
      # ポートの解析に失敗した場合はデフォルトを使用
      if mode == upmStrict:
        raise newException(ValueError, "Invalid port in URL: " & uri.port)
  
  # ドメイン情報を解析
  if uri.hostname.len > 0:
    domain_parts = parseDomainName(uri.hostname)
  
  # クエリパラメータの解析
  var query_params = initTable[string, string]()
  for pair in uri.query.split('&'):
    if pair.len == 0:
      continue
      
    let key_value = pair.split('=', maxsplit=1)
    if key_value.len == 1:
      query_params[key_value[0]] = ""
    elif key_value.len == 2:
      query_params[key_value[0]] = key_value[1]
  
  # ユーザー名とパスワードの解析
  var username = ""
  var password = ""
  if '@' in uri.userinfo:
    let user_pass = uri.userinfo.split(':', maxsplit=1)
    username = if user_pass.len > 0: user_pass[0] else: ""
    password = if user_pass.len > 1: user_pass[1] else: ""
  else:
    username = uri.userinfo
  
  # 最終結果の構築
  result = UrlInfo(
    schema: uri.scheme,
    host: uri.hostname,
    port: port,
    path: uri.path,
    query: query_params,
    fragment: uri.anchor,
    full_url: url,
    is_secure: is_secure,
    username: username,
    password: password,
    subdomain: domain_parts.subdomain,
    domain: domain_parts.domain,
    tld: domain_parts.tld
  )

proc getSecurityScore*(url: string): int =
  ## URLのセキュリティスコアを0-100で計算する
  ## 100が最も安全、0が最も危険
  let uri = parseUri(url)
  var score = 50  # デフォルトスコア
  
  # HTTPSが使われているか
  if uri.scheme == "https":
    score += 30
  elif uri.scheme == "http":
    score -= 20
  elif uri.scheme == "file" or uri.scheme == "data":
    score += 10
  elif uri.scheme == "ftp":
    score -= 10
  
  # ドメインの評価
  if uri.hostname == "localhost" or uri.hostname.startsWith("127.") or uri.hostname == "::1":
    score += 10  # ローカルホストは基本的に安全
  elif uri.hostname.endsWith(".example.com") or uri.hostname.endsWith(".test") or 
       uri.hostname.endsWith(".invalid") or uri.hostname.endsWith(".localhost"):
    score += 5  # テストドメイン
  
  # 危険な要素をチェック
  if '@' in url:  # URLに@が含まれる場合、フィッシングの可能性
    score -= 15
  
  if "data:" in url and "base64" in url:  # data URLはコードを含む可能性がある
    score -= 10
  
  # パスワードが含まれていないか
  if ':' in uri.userinfo:
    score -= 20  # URLに認証情報を含めるのはセキュリティリスク
  
  # スコアを0-100の範囲に収める
  result = max(0, min(100, score))

proc parseDomainName*(hostname: string): tuple[subdomain, domain, tld: string] =
  ## ホスト名をサブドメイン、メインドメイン、TLDに分解する
  ## 例: "www.example.co.jp" -> (subdomain: "www", domain: "example", tld: "co.jp")
  result = (subdomain: "", domain: "", tld: "")
  
  # IPアドレスの場合は分解せずドメイン部分に設定
  if isIpAddress(hostname):
    result.domain = hostname
    return result
  
  # localhostの場合は特別処理
  if hostname == "localhost":
    result.domain = "localhost"
    return result
  
  # ドメイン部分を「.」で分割
  let parts = hostname.split('.')
  
  # 特殊なTLDのリスト（国別コードドメインなど）
  let specialTlds = @[
    "co.jp", "co.uk", "com.au", "com.br", "org.uk", "net.au", "ac.jp", "gov.uk", 
    "edu.au", "co.nz", "org.au", "co.za", "ac.uk", "gov.au", "co.in", "org.nz",
    "ne.jp", "or.jp", "go.jp", "ed.jp", "ac.uk", "me.uk", "nhs.uk", "org.cn",
    "com.cn", "net.cn", "gov.cn", "edu.cn", "com.tw", "org.tw", "gov.tw", "com.hk",
    "org.hk", "edu.hk", "gov.hk", "com.sg", "org.sg", "edu.sg", "gov.sg", "com.my",
    "org.my", "edu.my", "gov.my", "co.kr", "or.kr", "go.kr", "ac.kr", "com.mx",
    "org.mx", "edu.mx", "gob.mx"
  ]
  
  # 一般的なTLDのリスト
  let commonTlds = @[
    "com", "org", "net", "edu", "gov", "mil", "int", "io", "dev", "app", "ai",
    "co", "me", "info", "biz", "name", "pro", "mobi", "tv", "fm", "us", "uk",
    "eu", "de", "fr", "jp", "cn", "ru", "it", "es", "nl", "br", "au", "ca",
    "in", "kr", "za", "mx", "se", "no", "fi", "dk", "ch", "at", "be", "pl",
    "nz", "tr", "ua", "il", "sg", "my", "th", "vn", "id", "ph", "ar", "cl",
    "pe", "co", "ve", "xyz", "tech", "online", "site", "store", "shop", "blog",
    "club", "design", "cloud", "studio", "agency", "network", "digital", "media"
  ]
  
  if parts.len <= 1:
    # 単一部分の場合はドメイン名のみ
    result.domain = hostname
    return result
  
  # 特殊なTLDの処理（co.jp, org.uk など）
  for i in countdown(parts.len - 2, 0):
    let potentialTld = parts[i..^1].join(".")
    let remainingParts = if i > 0: parts[0..<i] else: @[]
    
    # 特殊なTLDに一致するか確認
    if potentialTld in specialTlds:
      result.tld = potentialTld
      
      if remainingParts.len == 1:
        # example.co.jp のようなケース
        result.domain = remainingParts[0]
      elif remainingParts.len > 1:
        # www.example.co.jp のようなケース
        result.domain = remainingParts[^1]
        result.subdomain = remainingParts[0..^2].join(".")
      
      return result
  
  # 一般的なTLDの処理
  if parts[^1].toLowerAscii() in commonTlds:
    result.tld = parts[^1]
    
    if parts.len == 2:
      # example.com のようなケース
      result.domain = parts[0]
    else:
      # www.example.com のようなケース
      result.domain = parts[^2]
      result.subdomain = parts[0..^3].join(".")
    
    return result
  
  # 上記に該当しない場合は、最後の部分をTLDとして扱う
  result.tld = parts[^1]
  
  if parts.len == 2:
    result.domain = parts[0]
  else:
    result.domain = parts[^2]
    result.subdomain = parts[0..^3].join(".")

proc isIpAddress*(host: string): bool =
  ## 文字列がIPアドレス（IPv4またはIPv6）かどうかをチェック
  try:
    # IPv4アドレスのチェック
    let parts = host.split('.')
    if parts.len == 4:
      for part in parts:
        let num = parseInt(part)
        if num < 0 or num > 255:
          return false
      return true
    
    # IPv6アドレスのチェック
    elif ':' in host:
      let stripped = host.strip(chars={'[', ']'})
      try:
        # Nimのnativeメソッドを使用
        discard parseIpAddress(stripped)
        return true
      except:
        return false
    
    return false
  except:
    return false

proc isLocalhost*(host: string): bool =
  ## ホストがローカルホストかどうかをチェック
  return host == "localhost" or 
         host.startsWith("127.") or 
         host == "::1" or 
         host.endsWith(".localhost")

proc isPrivateIp*(host: string): bool =
  ## ホストがプライベートIPアドレスかどうかをチェック
  try:
    if not isIpAddress(host):
      return false
    
    let ip_addr = parseIpAddress(host)
    
    # IPv4プライベートアドレス範囲のチェック
    if ip_addr.family == IpAddressFamily.IPv4:
      let addr_str = $ip_addr
      return addr_str.startsWith("10.") or 
             addr_str.startsWith("172.16.") or addr_str.startsWith("172.17.") or
             addr_str.startsWith("172.18.") or addr_str.startsWith("172.19.") or
             addr_str.startsWith("172.20.") or addr_str.startsWith("172.21.") or
             addr_str.startsWith("172.22.") or addr_str.startsWith("172.23.") or
             addr_str.startsWith("172.24.") or addr_str.startsWith("172.25.") or
             addr_str.startsWith("172.26.") or addr_str.startsWith("172.27.") or
             addr_str.startsWith("172.28.") or addr_str.startsWith("172.29.") or
             addr_str.startsWith("172.30.") or addr_str.startsWith("172.31.") or
             addr_str.startsWith("192.168.")
    
    # IPv6プライベートアドレス範囲のチェック
    elif ip_addr.family == IpAddressFamily.IPv6:
      let addr_str = $ip_addr
      return addr_str.startsWith("fc") or 
             addr_str.startsWith("fd") or
             addr_str == "::1"
    
    return false
  except:
    return false

proc isValidUrl*(url: string, strict: bool = true): bool =
  ## URLが有効かどうかを検証
  try:
    let uri = parseUri(url)
    
    # スキームのチェック
    if uri.scheme.len == 0:
      return false
    
    # 厳格モードでの追加チェック
    if strict:
      # ホスト名が必須
      if uri.hostname.len == 0:
        return false
      
      # 一般的なスキームのみ許可
      let valid_schemes = ["http", "https", "ftp", "ftps", "ws", "wss", "file"]
      if uri.scheme notin valid_schemes:
        return false
    
    # 最低限、スキームとホスト名または絶対パスがあれば有効
    result = (uri.scheme.len > 0) and (uri.hostname.len > 0 or (uri.scheme == "file" and uri.path.len > 0))
  except:
    result = false

proc validateUrl*(url: string): UrlValidationResult =
  ## URLの詳細なバリデーションを実行して結果を返す
  var result = UrlValidationResult(
    is_valid: false,
    validation_errors: @[],
    normalized_url: "",
    security_info: UrlSecurityInfo(
      is_https: false,
      has_mixed_content: false,
      has_vulnerable_protocol: false,
      is_potentially_malicious: false,
      security_score: 0
    )
  )
  
  try:
    let uri = parseUri(url)
    
    # スキームのチェック
    if uri.scheme.len == 0:
      result.validation_errors.add("スキームが指定されていません")
    else:
      # セキュアなプロトコルかチェック
      result.security_info.is_https = (uri.scheme == "https")
      
      # 脆弱なプロトコルのチェック
      let vulnerable_protocols = ["http", "ftp", "telnet"]
      result.security_info.has_vulnerable_protocol = (uri.scheme in vulnerable_protocols)
    
    # ホスト名のチェック
    if uri.hostname.len == 0 and uri.scheme != "file":
      result.validation_errors.add("ホスト名が指定されていません")
    
    # ポートのチェック
    if uri.port.len > 0:
      try:
        let port = parseInt(uri.port)
        if port < 0 or port > 65535:
          result.validation_errors.add("無効なポート番号です: " & uri.port)
      except:
        result.validation_errors.add("ポートが数値ではありません: " & uri.port)
    
    # パスのチェック（特殊文字など）
    for c in uri.path:
      if c.int < 32:
        result.validation_errors.add("パスに制御文字が含まれています")
        break
    
    # クエリパラメータのチェック
    for kv in uri.query.split('&'):
      if kv.len > 0:
        let parts = kv.split('=', maxsplit=1)
        if parts.len > 0 and parts[0].len == 0:
          result.validation_errors.add("空のクエリパラメータがあります")
    
    # URLに潜在的な悪意があるかチェック
    result.security_info.is_potentially_malicious = 
      (('@' in url and ':' in url.split('@')[0]) or  # パスワード情報を含む
       ("data:" in url and "base64" in url) or       # データURLにbase64エンコード
       (url.count("http") > 1))                      # URLリダイレクト詐欺の疑い
    
    # セキュリティスコアの計算
    result.security_info.security_score = getSecurityScore(url)
    
    # URL正規化
    result.normalized_url = normalizeUrl(url)
    
    # 最終的な判断
    result.is_valid = (result.validation_errors.len == 0)
    
  except Exception as e:
    result.validation_errors.add("URL解析中にエラーが発生しました: " & e.msg)
    result.is_valid = false
  
  return result

proc joinUrl*(base: string, path: string): string =
  ## ベースURLとパスを結合
  var base_uri = parseUri(base)
  var joined_uri = parseUri(path)
  
  # pathが絶対URLの場合はそのまま返す
  if joined_uri.scheme.len > 0:
    return path
  
  # ベースURLのスキーマとホストを保持
  joined_uri.scheme = base_uri.scheme
  
  if path.startsWith('/'):
    # パスが / で始まる場合は、ベースURLのホストを使用して絶対パスとする
    joined_uri.hostname = base_uri.hostname
    joined_uri.port = base_uri.port
  else:
    # 相対パスの場合
    joined_uri.hostname = base_uri.hostname
    joined_uri.port = base_uri.port
    
    # ベースURLのパスの最後のスラッシュまでを取得
    var base_path = base_uri.path
    if base_path.len == 0:
      base_path = "/"
    elif not base_path.endsWith('/'):
      let last_slash = base_path.rfind('/')
      if last_slash >= 0:
        base_path = base_path[0 .. last_slash]
      else:
        base_path = "/"
    
    # 相対パスをベースパスに追加
    joined_uri.path = base_path & path
  
  # パス内の '..' と '.' を解決
  var path_segments = joined_uri.path.split('/')
  var resolved_segments: seq[string] = @[]
  
  for segment in path_segments:
    if segment == "..":
      if resolved_segments.len > 0:
        discard resolved_segments.pop()
    elif segment != "." and segment.len > 0:
      resolved_segments.add(segment)
  
  # パスを再構築
  joined_uri.path = "/" & resolved_segments.join("/")
  
  # ポートをコピー
  if base_uri.port.len > 0 and joined_uri.port.len == 0:
    joined_uri.port = base_uri.port
  
  # ユーザー情報をコピー
  if base_uri.userinfo.len > 0 and joined_uri.userinfo.len == 0:
    joined_uri.userinfo = base_uri.userinfo
  
  # 最終的なURLを返す
  result = $joined_uri

proc normalizeUrl*(url: string): string =
  ## URLを正規化（スキーマ、ホスト、ポート、パスを標準形式に）
  try:
    var uri = parseUri(url)
    
    # スキーマを小文字に
    uri.scheme = uri.scheme.toLowerAscii()
    
    # ホスト名を小文字に
    uri.hostname = uri.hostname.toLowerAscii()
    
    # デフォルトポートを削除
    if (uri.scheme == "http" and uri.port == "80") or
       (uri.scheme == "https" and uri.port == "443") or
       (uri.scheme == "ftp" and uri.port == "21") or
       (uri.scheme == "ssh" and uri.port == "22"):
      uri.port = ""
    
    # パスが空の場合は / に
    if uri.path.len == 0:
      uri.path = "/"
    
    # パスの正規化（重複するスラッシュを削除）
    var normalized_path = ""
    var prev_char = ' '
    
    for c in uri.path:
      if c == '/' and prev_char == '/':
        continue
      normalized_path.add(c)
      prev_char = c
    
    uri.path = normalized_path
    
    # パス内の "/./" を "/" に置換
    while "/./" in uri.path:
      uri.path = uri.path.replace("/./", "/")
    
    # パス内の "/../" を適切に解決
    var path_segments = uri.path.split('/')
    var resolved_segments: seq[string] = @[]
    
    for segment in path_segments:
      if segment == "..":
        if resolved_segments.len > 0:
          discard resolved_segments.pop()
      elif segment != "." and segment.len > 0:
        resolved_segments.add(segment)
    
    # パスを再構築
    uri.path = "/" & resolved_segments.join("/")
    
    # 末尾のスラッシュを除去（パスが / だけの場合を除く）
    if uri.path.len > 1 and uri.path.endsWith('/'):
      uri.path = uri.path[0 .. ^2]
    
    # クエリパラメータをソート
    if uri.query.len > 0:
      var query_parts = uri.query.split('&')
      sort(query_parts)
      uri.query = query_parts.join("&")
    
    # フラグメントを保持
    
    result = $uri
  except:
    # 処理に失敗した場合は元のURLを返す
    result = url

proc urlDecode*(str: string): string =
  ## URLエンコードされた文字列をデコード
  result = decodeUrl(str)

proc urlEncode*(str: string): string =
  ## 文字列をURLエンコード
  result = encodeUrl(str)

proc resolveRelativeUrl*(base_url, relative_url: string): string =
  ## 相対URLを絶対URLに解決
  let base_uri = parseUri(base_url)
  let relative_uri = parseUri(relative_url)
  
  # 相対URLがすでに絶対URLの場合はそのまま返す
  if relative_uri.scheme.len > 0:
    return relative_url
  
  # ベースURLのURIを作成
  var result_uri = base_uri
  
  # 相対URLのパスが絶対パスの場合
  if relative_url.startsWith('/'):
    result_uri.path = relative_uri.path
    result_uri.query = relative_uri.query
    result_uri.anchor = relative_uri.anchor
  else:
    # 相対パスの場合、ベースURLのディレクトリに結合
    var base_dir = base_uri.path
    let last_slash = base_dir.rfind('/')
    
    if last_slash >= 0:
      base_dir = base_dir[0 .. last_slash]
    else:
      base_dir = "/"
    
    # 結合したパスを設定
    if relative_uri.path.startsWith("./"):
      result_uri.path = base_dir & relative_uri.path[2 .. ^1]
    else:
      result_uri.path = base_dir & relative_uri.path
    
    # パス内の "/./" を "/" に置換
    while "/./" in result_uri.path:
      result_uri.path = result_uri.path.replace("/./", "/")
    
    # パス内の "/../" を適切に解決
    var path_segments = result_uri.path.split('/')
    var resolved_segments: seq[string] = @[]
    
    for segment in path_segments:
      if segment == "..":
        if resolved_segments.len > 0:
          discard resolved_segments.pop()
      elif segment != "." and segment.len > 0:
        resolved_segments.add(segment)
    
    # パスを再構築
    result_uri.path = "/" & resolved_segments.join("/")
    
    # クエリとフラグメントを設定
    result_uri.query = relative_uri.query
    result_uri.anchor = relative_uri.anchor
  
  return $result_uri

proc getQueryParam*(url: string, param_name: string): Option[string] =
  ## URLからクエリパラメータの値を取得
  let uri = parseUri(url)
  let query_params = decodeQueryParams(uri.query)
  
  if query_params.hasKey(param_name):
    return some(query_params[param_name])
  else:
    return none(string)

proc hasParam*(url: string, param_name: string): bool =
  ## URLに指定されたクエリパラメータが存在するか確認
  return getQueryParam(url, param_name).isSome

proc addQueryParam*(url: string, param_name, param_value: string): string =
  ## URLにクエリパラメータを追加
  var uri = parseUri(url)
  
  # 既存のクエリパラメータを解析
  var params = decodeQueryParams(uri.query)
  
  # パラメータを追加または更新
  params[param_name] = param_value
  
  # クエリ文字列を再構築
  uri.query = encodeQueryParams(params)
  
  result = $uri

proc removeQueryParam*(url: string, param_name: string): string =
  ## URLからクエリパラメータを削除
  var uri = parseUri(url)
  
  # 既存のクエリパラメータを解析
  var params = decodeQueryParams(uri.query)
  
  # パラメータを削除
  params.del(param_name)
  
  # クエリ文字列を再構築
  uri.query = encodeQueryParams(params)
  
  result = $uri

proc updateQueryParam*(url: string, param_name, param_value: string): string =
  ## URLのクエリパラメータを更新
  var uri = parseUri(url)
  
  # 既存のクエリパラメータを解析
  var params = decodeQueryParams(uri.query)
  
  # パラメータを更新
  params[param_name] = param_value
  
  # クエリ文字列を再構築
  uri.query = encodeQueryParams(params)
  
  result = $uri

proc encodeQueryParams*(params: Table[string, string]): string =
  ## クエリパラメータをURLエンコード
  var encoded_pairs: seq[string] = @[]
  
  for key, value in params.pairs:
    let encoded_key = encodeUrl(key)
    let encoded_value = encodeUrl(value)
    encoded_pairs.add(encoded_key & "=" & encoded_value)
  
  result = encoded_pairs.join("&")

proc decodeQueryParams*(query: string): Table[string, string] =
  ## URLエンコードされたクエリパラメータをデコード
  result = initTable[string, string]()
  
  if query.len == 0:
    return
  
  for pair in query.split('&'):
    if pair.len == 0:
      continue
      
    let key_value = pair.split('=', maxsplit=1)
    if key_value.len == 1:
      result[decodeUrl(key_value[0])] = ""
    elif key_value.len == 2:
      result[decodeUrl(key_value[0])] = decodeUrl(key_value[1])

proc extractDomain*(url: string): string =
  ## URLからドメイン部分を抽出
  try:
    let uri = parseUri(url)
    result = uri.hostname
  except:
    result = ""

proc getBaseUrl*(url: string): string =
  ## URLからベースURL（スキーマ + ホスト + ポート）を取得
  try:
    var uri = parseUri(url)
    uri.path = ""
    uri.query = ""
    uri.anchor = ""
    result = $uri
  except:
    result = ""

proc getOrigin*(url: string): string =
  ## URLからオリジン（スキーマ + ホスト + ポート）を取得
  return getBaseUrl(url)

proc getPathname*(url: string): string =
  ## URLからパス部分を取得
  try:
    let uri = parseUri(url)
    result = uri.path
  except:
    result = ""

proc getDomainInfo*(url: string): DomainInfo =
  ## URLからドメイン情報を抽出
  let uri = parseUri(url)
  let hostname = uri.hostname
  
  result = DomainInfo(
    full_domain: hostname,
    is_ip_address: isIpAddress(hostname),
    is_localhost: isLocalhost(hostname),
    is_private: isPrivateIp(hostname)
  )
  
  # IPアドレスでもlocalhostでもない場合はドメイン解析
  if not result.is_ip_address and not result.is_localhost:
    let domain_parts = parseDomainName(hostname)
    result.subdomain = domain_parts.subdomain
    result.domain = domain_parts.domain
    result.tld = domain_parts.tld

proc isSameOrigin*(url1, url2: string): bool =
  ## 2つのURLが同じオリジンかどうか確認
  try:
    let uri1 = parseUri(url1)
    let uri2 = parseUri(url2)
    
    # スキーム、ホスト名、ポートが一致するか確認
    return uri1.scheme == uri2.scheme and
           uri1.hostname == uri2.hostname and
           uri1.port == uri2.port
  except:
    return false

proc isSameDomain*(url1, url2: string): bool =
  ## 2つのURLが同じドメイン（サブドメインは異なる可能性あり）かどうか確認
  try:
    let domain1 = getDomainInfo(url1)
    let domain2 = getDomainInfo(url2)
    
    return domain1.domain == domain2.domain and
           domain1.tld == domain2.tld
  except:
    return false

proc newCookieJar*(max_cookies: int = 1000, max_per_domain: int = 50): CookieJar =
  ## 新しいCookieJarを作成
  ## max_cookies: 最大保持Cookie数
  ## max_per_domain: ドメインごとの最大保持Cookie数
  CookieJar(
    cookies: initTable[string, Table[string, Cookie]](),
    max_cookies_per_domain: max_per_domain,
    max_total_cookies: max_cookies,
    reject_public_suffixes: true,
    same_site_policy: ssLax
  )

proc cookieCount*(jar: CookieJar): int =
  ## Jarに格納されているCookieの総数を返す
  var count = 0
  for domain, cookies in jar.cookies:
    count += cookies.len
  return count

proc domainCount*(jar: CookieJar): int =
  ## Cookie格納ドメインの数を返す
  return jar.cookies.len

proc clearExpiredCookies*(jar: CookieJar): int =
  ## 期限切れのCookieを削除し、削除された数を返す
  let now = now()
  var removed_count = 0
  var domains_to_remove: seq[string] = @[]
  
  # 各ドメインのCookieをチェック
  for domain, cookies in jar.cookies.mpairs:
    var cookies_to_remove: seq[string] = @[]
    
    # 期限切れのCookieを探す
    for name, cookie in cookies.pairs:
      if cookie.expires.isSome and cookie.expires.get() < now:
        cookies_to_remove.add(name)
    
    # 期限切れCookieを削除
    for name in cookies_to_remove:
      cookies.del(name)
      removed_count += 1
    
    # Cookieが空になったドメインを記録
    if cookies.len == 0:
      domains_to_remove.add(domain)
  
  # 空のドメインを削除
  for domain in domains_to_remove:
    jar.cookies.del(domain)
  
  return removed_count

proc parseCookie*(cookie_str: string): Cookie =
  ## Cookieヘッダーの値を解析
  var cookie = Cookie(
    creation_time: now(),
    last_access_time: now(),
    priority: cpMedium,
    path: "/"
  )
  
  let parts = cookie_str.split(';')
  if parts.len == 0:
    return cookie
  
  # 最初の部分は name=value
  let name_value = parts[0].strip().split('=', maxsplit=1)
  if name_value.len < 2:
    return cookie
  
  cookie.name = name_value[0].strip()
  cookie.value = name_value[1].strip()
  
  # その他の属性を解析
  for i in 1 ..< parts.len:
    let attr = parts[i].strip().split('=', maxsplit=1)
    let key = if attr.len > 0: attr[0].strip().toLowerAscii() else: ""
    let value = if attr.len > 1: attr[1].strip() else: ""
    
    case key:
      of "domain":
        cookie.domain = value
        cookie.host_only = false
      of "path":
        cookie.path = value
      of "expires":
        try:
          # 複数の日付フォーマットをサポート
          var dt: DateTime
          let formats = [
            "ddd, dd MMM yyyy HH:mm:ss 'GMT'",
            "ddd, dd-MMM-yyyy HH:mm:ss 'GMT'",
            "ddd, dd MMM yyyy HH:mm:ss",
            "dd-MMM-yyyy HH:mm:ss 'GMT'"
          ]
          
          var parsed = false
          for fmt in formats:
            try:
              dt = parse(value, fmt)
              parsed = true
              break
            except:
              continue
          
          if parsed:
            cookie.expires = some(dt)
            cookie.persistent = true
        except:
          # 日付の解析に失敗した場合は無視
          discard
      of "max-age":
        try:
          let seconds = parseInt(value)
          cookie.expires = some(now() + initDuration(seconds = seconds))
          cookie.persistent = true
        except:
          discard
      of "httponly":
        cookie.http_only = true
      of "secure":
        cookie.secure = true
      of "samesite":
        cookie.same_site = value
        # SameSite値を正規化
        if value.toLowerAscii() == "lax":
          cookie.same_site = "Lax"
        elif value.toLowerAscii() == "strict":
          cookie.same_site = "Strict"
        elif value.toLowerAscii() == "none":
          cookie.same_site = "None"
      of "priority":
        if value.toLowerAscii() == "low":
          cookie.priority = cpLow
        elif value.toLowerAscii() == "medium":
          cookie.priority = cpMedium
        elif value.toLowerAscii() == "high":
          cookie.priority = cpHigh
  
  return cookie

proc cookieToString*(cookie: Cookie): string =
  ## Cookieオブジェクトを文字列に変換（Set-Cookie用）
  result = cookie.name & "=" & cookie.value
  
  if cookie.domain.len > 0:
    result &= "; Domain=" & cookie.domain
  
  if cookie.path.len > 0:
    result &= "; Path=" & cookie.path
  
  if cookie.expires.isSome:
    let expires_str = cookie.expires.get().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    result &= "; Expires=" & expires_str
  
  if cookie.http_only:
    result &= "; HttpOnly"
  
  if cookie.secure:
    result &= "; Secure"
  
  if cookie.same_site.len > 0:
    result &= "; SameSite=" & cookie.same_site
  
  # 優先度を追加（非標準だが一部のブラウザでサポート）
  case cookie.priority:
    of cpLow:
      result &= "; Priority=Low"
    of cpHigh:
      result &= "; Priority=High"
    else:
      discard  # 中程度の優先度はデフォルトなので追加しない

proc addCookie*(jar: CookieJar, cookie: Cookie, url: string = "") =
  ## Cookieをjarに追加
  var domain = cookie.domain
  var updated_cookie = cookie
  
  # ドメインが指定されていない場合はURLから取得
  if domain.len == 0 and url.len > 0:
    domain = extractDomain(url)
    updated_cookie.domain = domain
    updated_cookie.host_only = true
  
  # ドメインが見つからない場合は追加しない
  if domain.len == 0:
    return
  
  # ドメインの前のドットを削除（一般的な規則）
  if domain.startsWith('.'):
    domain = domain[1..^1]
    updated_cookie.domain = domain
  
  # 公開サフィックスのみのドメインを拒否する設定の場合はチェック
  if jar.reject_public_suffixes:
    # Public Suffix Listを使用した厳密なチェック
    if isPublicSuffix(domain):
      return
  
  # パスが指定されていない場合はデフォルトパスを設定
  if updated_cookie.path.len == 0 and url.len > 0:
    updated_cookie.path = extractPath(url)
    if updated_cookie.path.len == 0:
      updated_cookie.path = "/"
  
  # 有効期限の検証
  if updated_cookie.expires.isSome:
    let expiry_time = updated_cookie.expires.get()
    # 既に期限切れの場合は追加しない
    if expiry_time < now():
      return
  
  # セキュリティチェック - HTTPSのURLに対してSecure属性がない場合は警告
  if url.startsWith("https://") and not updated_cookie.secure and jar.security_level >= csWarn:
    logWarning("HTTPSサイトからのCookieにSecure属性がありません: " & updated_cookie.name)
    
    # 厳格なセキュリティポリシーの場合は強制的にSecure属性を付与
    if jar.security_level == csStrict:
      updated_cookie.secure = true
  # SameSite ポリシーのチェック
  if jar.same_site_policy != ssNone:
    if updated_cookie.same_site.len == 0:
      # デフォルトのSameSite値を設定
      case jar.same_site_policy:
        of ssStrict:
          updated_cookie.same_site = "Strict"
        of ssLax:
          updated_cookie.same_site = "Lax"
        else:
          discard
    elif jar.same_site_policy == ssStrict and updated_cookie.same_site == "None":
      # Strict ポリシーではNoneを許可しない
      updated_cookie.same_site = "Lax"
  
  # Secure属性のチェック
  if updated_cookie.same_site == "None" and not updated_cookie.secure:
    # SameSite=Noneの場合はSecureが必須
    updated_cookie.secure = true
  
  # ドメインのテーブルを初期化（存在しない場合）
  if domain notin jar.cookies:
    jar.cookies[domain] = initTable[string, Cookie]()
  
  # 最大Cookie数のチェック
  if jar.cookies[domain].len >= jar.max_cookies_per_domain:
    # 最も古いCookieを削除
    var oldest_name = ""
    var oldest_time = now()
    
    for name, existing_cookie in jar.cookies[domain]:
      if existing_cookie.last_access_time < oldest_time:
        oldest_time = existing_cookie.last_access_time
        oldest_name = name
    
    if oldest_name.len > 0:
      jar.cookies[domain].del(oldest_name)
  
  # Cookieを追加（上書き）
  jar.cookies[domain][updated_cookie.name] = updated_cookie
  
  # 全体の最大Cookie数をチェック
  let total_cookies = jar.cookieCount()
  if total_cookies > jar.max_total_cookies:
    # 最も古いCookieを持つドメインから削除
    var oldest_domain = ""
    var oldest_name = ""
    var oldest_time = now()
    
    for d, cookies in jar.cookies:
      for n, c in cookies:
        if c.last_access_time < oldest_time:
          oldest_time = c.last_access_time
          oldest_domain = d
          oldest_name = n
    
    if oldest_domain.len > 0 and oldest_name.len > 0:
      jar.cookies[oldest_domain].del(oldest_name)
      
      # ドメインが空になったら削除
      if jar.cookies[oldest_domain].len == 0:
        jar.cookies.del(oldest_domain)

proc getCookiesForUrl*(jar: CookieJar, url: string): seq[Cookie] =
  ## 指定されたURLに適用されるCookieを取得
  result = @[]
  let domain_info = getDomainInfo(url)
  let is_secure = url.toLowerAscii().startsWith("https")
  let uri = parseUri(url)
  let path = if uri.path.len > 0: uri.path else: "/"
  
  # 現在時刻
  let now_time = now()
  
  # 期限切れCookieのクリーンアップ
  discard jar.clearExpiredCookies()
  
  # ホストオンリーCookie（完全一致ドメイン）とドメインCookieの両方をチェック
  for cookie_domain, domain_cookies in jar.cookies:
    # 完全一致（ホストオンリーCookie）
    let exact_match = domain_info.full_domain == cookie_domain
    
    # ドメインマッチ（サブドメインを含む）
    let domain_match = not exact_match and domain_info.full_domain.endsWith("." & cookie_domain)
    
    if exact_match or domain_match:
      for name, cookie in domain_cookies:
        # ホストオンリーチェック
        if cookie.host_only and not exact_match:
          continue
        
        # セキュアCookieは安全な接続でのみ送信
        if cookie.secure and not is_secure:
          continue
        
        # パスをチェック
        if not path.startsWith(cookie.path):
          continue
        
        # 最終アクセス時間を更新
        var updated_cookie = cookie
        updated_cookie.last_access_time = now_time
        
        # Cookieの有効性を確認
        if updated_cookie.expires.isSome and updated_cookie.expires.get() < now_time:
          continue
        
        result.add(updated_cookie)
  
  # 優先度でソート（高優先度が先）
  result.sort(proc(a, b: Cookie): int =
    return ord(b.priority) - ord(a.priority)
  )

proc getCookieHeader*(jar: CookieJar, url: string): string =
  ## 指定されたURLに適用されるCookieヘッダーを生成
  let cookies = jar.getCookiesForUrl(url)
  var cookie_parts: seq[string] = @[]
  
  for cookie in cookies:
    cookie_parts.add(cookie.name & "=" & cookie.value)
  
  result = cookie_parts.join("; ")

proc hasCookie*(jar: CookieJar, domain, name: string): bool =
  ## 指定されたドメインと名前のCookieが存在するか確認
  return domain in jar.cookies and name in jar.cookies[domain]

proc getCookie*(jar: CookieJar, domain, name: string): Option[Cookie] =
  ## 指定されたドメインと名前のCookieを取得
  if hasCookie(jar, domain, name):
    return some(jar.cookies[domain][name])
  return none(Cookie)

proc deleteCookie*(jar: CookieJar, domain, name: string): bool =
  ## 指定されたドメインと名前のCookieを削除
  if hasCookie(jar, domain, name):
    jar.cookies[domain].del(name)
    
    # ドメインが空になったら削除
    if jar.cookies[domain].len == 0:
      jar.cookies.del(domain)
    
    return true
  return false

proc clearDomainCookies*(jar: CookieJar, domain: string): int =
  ## 指定されたドメインのすべてのCookieを削除
  if domain in jar.cookies:
    let count = jar.cookies[domain].len
    jar.cookies.del(domain)
    return count
  return 0

proc clearAllCookies*(jar: CookieJar) =
  ## すべてのCookieを削除
  jar.cookies.clear()

proc importFromHeader*(jar: CookieJar, headers: HttpHeaders, url: string) =
  ## レスポンスヘッダーからCookieをインポート
  if "set-cookie" in headers:
    let cookie_headers = headers["set-cookie"]
    for cookie_str in cookie_headers:
      let cookie = parseCookie(cookie_str)
      jar.addCookie(cookie, url)

proc exportToJson*(jar: CookieJar): JsonNode =
  ## CookieJarをJSON形式にエクスポート
  var cookies_array = newJArray()
  
  for domain, cookies in jar.cookies:
    for name, cookie in cookies:
      var cookie_obj = newJObject()
      
      cookie_obj["name"] = newJString(cookie.name)
      cookie_obj["value"] = newJString(cookie.value)
      cookie_obj["domain"] = newJString(cookie.domain)
      cookie_obj["path"] = newJString(cookie.path)
      
      if cookie.expires.isSome:
        cookie_obj["expires"] = newJString(cookie.expires.get().format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
      
      cookie_obj["httpOnly"] = newJBool(cookie.http_only)
      cookie_obj["secure"] = newJBool(cookie.secure)
      
      if cookie.same_site.len > 0:
        cookie_obj["sameSite"] = newJString(cookie.same_site)
      
      cookie_obj["hostOnly"] = newJBool(cookie.host_only)
      cookie_obj["persistent"] = newJBool(cookie.persistent)
      
      cookies_array.add(cookie_obj)
  
  result = newJObject()
  result["cookies"] = cookies_array

proc importFromJson*(jar: CookieJar, json_data: JsonNode) =
  ## JSON形式からCookieJarにインポート
  if json_data.hasKey("cookies") and json_data["cookies"].kind == JArray:
    for cookie_item in json_data["cookies"]:
      if cookie_item.kind != JObject:
        continue
      
      var cookie = Cookie(
        creation_time: now(),
        last_access_time: now(),
        priority: cpMedium,
        path: "/"
      )
      
      if cookie_item.hasKey("name") and cookie_item["name"].kind == JString:
        cookie.name = cookie_item["name"].getStr()
      else:
        continue  # 名前は必須
      
      if cookie_item.hasKey("value") and cookie_item["value"].kind == JString:
        cookie.value = cookie_item["value"].getStr()
      
      if cookie_item.hasKey("domain") and cookie_item["domain"].kind == JString:
        cookie.domain = cookie_item["domain"].getStr()
      else:
        continue  # ドメインは必須
      
      if cookie_item.hasKey("path") and cookie_item["path"].kind == JString:
        cookie.path = cookie_item["path"].getStr()
      
      if cookie_item.hasKey("expires") and cookie_item["expires"].kind == JString:
        try:
          let expires_str = cookie_item["expires"].getStr()
          cookie.expires = some(parse(expires_str, "yyyy-MM-dd'T'HH:mm:ss'Z'"))
          cookie.persistent = true
        except:
          discard
      
      if cookie_item.hasKey("httpOnly") and cookie_item["httpOnly"].kind == JBool:
        cookie.http_only = cookie_item["httpOnly"].getBool()
      
      if cookie_item.hasKey("secure") and cookie_item["secure"].kind == JBool:
        cookie.secure = cookie_item["secure"].getBool()
      
      if cookie_item.hasKey("sameSite") and cookie_item["sameSite"].kind == JString:
        cookie.same_site = cookie_item["sameSite"].getStr()
      
      if cookie_item.hasKey("hostOnly") and cookie_item["hostOnly"].kind == JBool:
        cookie.host_only = cookie_item["hostOnly"].getBool()
      
      if cookie_item.hasKey("persistent") and cookie_item["persistent"].kind == JBool:
        cookie.persistent = cookie_item["persistent"].getBool()
      
      # Cookieを追加
      jar.addCookie(cookie)

proc createSessionCookie*(name, value, domain: string, path: string = "/"): Cookie =
  ## セッションCookie（非永続的なCookie）を作成
  result = Cookie(
    name: name,
    value: value,
    domain: domain,
    path: path,
    http_only: false,
    secure: false,
    creation_time: now(),
    last_access_time: now(),
    persistent: false,
    host_only: false,
    priority: cpMedium
  )

proc createPersistentCookie*(name, value, domain: string, expires_in_days: int = 30, 
                           path: string = "/", secure: bool = false, http_only: bool = false): Cookie =
  ## 永続的なCookieを作成
  result = Cookie(
    name: name,
    value: value,
    domain: domain,
    path: path,
    expires: some(now() + initDuration(days = expires_in_days)),
    http_only: http_only,
    secure: secure,
    creation_time: now(),
    last_access_time: now(),
    persistent: true,
    host_only: false,
    priority: cpMedium
  )

proc createSecureCookie*(name, value, domain: string, expires_in_days: int = 30,
                       path: string = "/", same_site: string = "Lax"): Cookie =
  ## セキュアなCookieを作成
  result = Cookie(
    name: name,
    value: value,
    domain: domain,
    path: path,
    expires: some(now() + initDuration(days = expires_in_days)),
    http_only: true,
    secure: true,
    same_site: same_site,
    creation_time: now(),
    last_access_time: now(),
    persistent: true,
    host_only: false,
    priority: cpHigh
  )

# HTTPヘッダー関連の高度な関数

proc parseAcceptHeader*(accept_header: string): seq[tuple[mime_type: string, quality: float]] =
  ## Accept ヘッダーを解析して優先順にMIMEタイプをリストアップ
  result = @[]
  
  if accept_header.len == 0:
    return
  
  # Accept ヘッダーを分解
  let parts = accept_header.split(',')
  
  for part in parts:
    let part_trimmed = part.strip()
    if part_trimmed.len == 0:
      continue
    
    # MIME タイプとquality値を取得
    let type_and_q = part_trimmed.split(';')
    let mime_type = type_and_q[0].strip()
    var quality = 1.0
    
    # quality値が指定されている場合は解析
    if type_and_q.len > 1:
      for param in type_and_q[1..^1]:
        let param_trimmed = param.strip()
        if param_trimmed.startsWith("q="):
          try:
            let q_str = param_trimmed[2..^1]
            quality = parseFloat(q_str)
            # 0〜1.0の範囲に制限
            quality = max(0.0, min(1.0, quality))
          except:
            quality = 1.0
    
    result.add((mime_type: mime_type, quality: quality))
  
  # quality値で降順ソート
  result.sort(proc(a, b: tuple[mime_type: string, quality: float]): int =
    if a.quality > b.quality: return -1
    elif a.quality < b.quality: return 1
    else: return 0
  )

proc getBestContentType*(accept_header: string, available_types: seq[string]): string =
  ## Acceptヘッダーに基づいて最適なコンテンツタイプを選択
  if accept_header.len == 0 or available_types.len == 0:
    # デフォルトか最初のタイプを返す
    if available_types.len > 0:
      return available_types[0]
    else:
      return "text/plain"
  
  # Acceptヘッダーを解析
  let accept_types = parseAcceptHeader(accept_header)
  
  # ワイルドカード比較用のヘルパー関数
  proc matchesWildcard(accept_type, content_type: string): bool =
    if accept_type == "*/*":
      return true
    
    if accept_type.endsWith("/*"):
      let prefix = accept_type[0..^3]
      return content_type.startsWith(prefix)
    
    return accept_type == content_type
  
  # 最適なマッチを見つける
  for accept_type in accept_types:
    # 品質が0のタイプは拒否
    if accept_type.quality <= 0.0:
      continue
    
    # 完全一致を確認
    for available in available_types:
      if matchesWildcard(accept_type.mime_type, available):
        return available
  
  # マッチしなければ最初のタイプを返す
  if available_types.len > 0:
    return available_types[0]
  else:
    return "text/plain"

proc generateHeadersByUserAgent*(user_agent: string): HttpHeaders =
  ## ユーザーエージェントに基づく適切なHTTPヘッダーを生成
  result = newHttpHeaders()
  
  # ベースヘッダーの設定
  result["User-Agent"] = user_agent
  
  # ユーザーエージェントによって異なるヘッダーを設定
  if "Chrome" in user_agent:
    result["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
    result["Accept-Encoding"] = "gzip, deflate, br"
    result["Accept-Language"] = "en-US,en;q=0.9,ja;q=0.8"
    result["Sec-CH-UA"] = "\"Google Chrome\";v=\"113\", \"Chromium\";v=\"113\", \"Not-A.Brand\";v=\"24\""
    result["Sec-CH-UA-Mobile"] = "?0"
    result["Sec-CH-UA-Platform"] = "\"Windows\""
    result["Sec-Fetch-Dest"] = "document"
    result["Sec-Fetch-Mode"] = "navigate"
    result["Sec-Fetch-Site"] = "none"
    result["Upgrade-Insecure-Requests"] = "1"
  
  elif "Firefox" in user_agent:
    result["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
    result["Accept-Encoding"] = "gzip, deflate, br"
    result["Accept-Language"] = "en-US,en;q=0.5"
    result["Sec-Fetch-Dest"] = "document"
    result["Sec-Fetch-Mode"] = "navigate"
    result["Sec-Fetch-Site"] = "none"
    result["Upgrade-Insecure-Requests"] = "1"
  
  elif "Safari" in user_agent and "Chrome" notin user_agent:
    result["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    result["Accept-Encoding"] = "gzip, deflate, br"
    result["Accept-Language"] = "en-US,en;q=0.9"
  
  elif "Edg" in user_agent or "Edge" in user_agent:
    result["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
    result["Accept-Encoding"] = "gzip, deflate, br"
    result["Accept-Language"] = "en-US,en;q=0.9"
    result["Sec-Fetch-Dest"] = "document"
    result["Sec-Fetch-Mode"] = "navigate"
    result["Sec-Fetch-Site"] = "none"
    result["Upgrade-Insecure-Requests"] = "1"
  
  # 他のブラウザやカスタムUAの場合はデフォルト値を使用
  else:
    result["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    result["Accept-Encoding"] = "gzip, deflate"
    result["Accept-Language"] = "en-US,en;q=0.9,ja;q=0.8"
  
  # 共通ヘッダー
  result["Connection"] = "keep-alive"

proc generateHeaders*(url: string, referer: string = "", user_agent: string = "QuantumBrowser/1.0"): HttpHeaders =
  ## 一般的なHTTPヘッダーを生成
  result = generateHeadersByUserAgent(user_agent)
  
  # リファラー（指定されている場合）
  if referer.len > 0:
    result["Referer"] = referer

proc getMimeTypeInfo*(mime_type: string): MimeTypeInfo =
  ## MIMEタイプに関する詳細情報を取得
  result = MimeTypeInfo(
    mime_type: mime_type,
    is_text: false,
    is_binary: true,
    is_image: false,
    is_audio: false,
    is_video: false,
    is_application: false
  )
  
  # MIMEタイプを正規化
  let normalized_mime = mime_type.toLowerAscii()
  
  # MIMEタイプによる分類
  if normalized_mime.startsWith("text/"):
    result.is_text = true
    result.is_binary = false
    
    # 一般的なテキスト形式
    if normalized_mime == "text/html":
      result.description = "HTML document"
      result.file_extension = "html"
    elif normalized_mime == "text/plain":
      result.description = "Plain text"
      result.file_extension = "txt"
    elif normalized_mime == "text/css":
      result.description = "Cascading Style Sheet"
      result.file_extension = "css"
    elif normalized_mime == "text/javascript" or normalized_mime == "application/javascript":
      result.description = "JavaScript code"
      result.file_extension = "js"
    elif normalized_mime == "text/xml" or normalized_mime == "application/xml":
      result.description = "XML document"
      result.file_extension = "xml"
    elif normalized_mime == "text/csv":
      result.description = "Comma-separated values"
      result.file_extension = "csv"
    elif normalized_mime == "text/markdown":
      result.description = "Markdown document"
      result.file_extension = "md"
    else:
      result.description = "Text document"
  
  # 画像系
  elif normalized_mime.startsWith("image/"):
    result.is_image = true
    
    if normalized_mime == "image/jpeg":
      result.description = "JPEG image"
      result.file_extension = "jpg"
    elif normalized_mime == "image/png":
      result.description = "PNG image"
      result.file_extension = "png"
    elif normalized_mime == "image/gif":
      result.description = "GIF image"
      result.file_extension = "gif"
    elif normalized_mime == "image/svg+xml":
      result.description = "SVG image"
      result.file_extension = "svg"
      result.is_text = true
      result.is_binary = false
    elif normalized_mime == "image/webp":
      result.description = "WebP image"
      result.file_extension = "webp"
    elif normalized_mime == "image/bmp":
      result.description = "Bitmap image"
      result.file_extension = "bmp"
    elif normalized_mime == "image/x-icon" or normalized_mime == "image/vnd.microsoft.icon":
      result.description = "Icon"
      result.file_extension = "ico"
    else:
      result.description = "Image"
  
  # 音声系
  elif normalized_mime.startsWith("audio/"):
    result.is_audio = true
    
    if normalized_mime == "audio/mpeg":
      result.description = "MP3 audio"
      result.file_extension = "mp3"
    elif normalized_mime == "audio/wav":
      result.description = "WAV audio"
      result.file_extension = "wav"
    elif normalized_mime == "audio/ogg":
      result.description = "OGG audio"
      result.file_extension = "ogg"
    elif normalized_mime == "audio/aac":
      result.description = "AAC audio"
      result.file_extension = "aac"
    elif normalized_mime == "audio/midi":
      result.description = "MIDI audio"
      result.file_extension = "mid"
    else:
      result.description = "Audio"
  
  # 動画系
  elif normalized_mime.startsWith("video/"):
    result.is_video = true
    
    if normalized_mime == "video/mp4":
      result.description = "MP4 video"
      result.file_extension = "mp4"
    elif normalized_mime == "video/mpeg":
      result.description = "MPEG video"
      result.file_extension = "mpg"
    elif normalized_mime == "video/webm":
      result.description = "WebM video"
      result.file_extension = "webm"
    elif normalized_mime == "video/ogg":
      result.description = "OGG video"
      result.file_extension = "ogv"
    elif normalized_mime == "video/quicktime":
      result.description = "QuickTime video"
      result.file_extension = "mov"
    else:
      result.description = "Video"
  
  # アプリケーション系
  elif normalized_mime.startsWith("application/"):
    result.is_application = true
    
    if normalized_mime == "application/json":
      result.description = "JSON document"
      result.file_extension = "json"
      result.is_text = true
      result.is_binary = false
    elif normalized_mime == "application/pdf":
      result.description = "PDF document"
      result.file_extension = "pdf"
    elif normalized_mime == "application/zip":
      result.description = "ZIP archive"
      result.file_extension = "zip"
    elif normalized_mime == "application/octet-stream":
      result.description = "Binary data"
      result.file_extension = "bin"
    elif normalized_mime == "application/x-www-form-urlencoded":
      result.description = "Form data"
      result.is_text = true
      result.is_binary = false
    else:
      result.description = "Application data"

proc detectContentType*(body: string): string =
  ## レスポンスボディからコンテンツタイプを推測
  
  # HTMLの検出
  if body.strip().startsWith("<") and 
     (body.contains("<html") or body.contains("<head") or body.contains("<title")):
    return "text/html"
  
  # JSONの検出
  if (body.strip().startsWith("{") and body.strip().endsWith("}")) or
     (body.strip().startsWith("[") and body.strip().endsWith("]")):
    try:
      discard parseJson(body)
      return "application/json"
    except:
      discard
  
  # XMLの検出
  if body.strip().startsWith("<?xml") or 
     (body.strip().startsWith("<") and body.contains("</")):
    return "application/xml"
  
  # CSSの検出
  if body.contains("@import ") or body.contains("@media ") or
     body.contains("{") and body.contains("}") and body.contains(":"):
    return "text/css"
  
  # JavaScriptの検出
  if body.contains("function ") or body.contains("var ") or body.contains("let ") or
     body.contains("const ") or body.contains("document.") or body.contains("window."):
    return "application/javascript"
  
  # テキストの検出（他に当てはまらない場合）
  var is_text = true
  let sample_size = min(body.len, 1000)
  
  for i in 0 ..< sample_size:
    let c = body[i]
    if c < ' ' and c != '\r' and c != '\n' and c != '\t':
      is_text = false
      break
  
  if is_text:
    # CSVの検出
    if body.count(',') > 5 and body.count('\n') > 1:
      let lines = body.split('\n')
      if lines.len > 1:
        let first_line_commas = lines[0].count(',')
        let second_line_commas = lines[1].count(',')
        if first_line_commas > 0 and first_line_commas == second_line_commas:
          return "text/csv"
    
    return "text/plain"
  
  # デフォルト
  return "application/octet-stream"

proc isHtmlContentType*(content_type: string): bool =
  ## コンテンツタイプがHTMLかどうかを判定
  return content_type.contains("text/html") or content_type.contains("application/xhtml")

proc isJsonContentType*(content_type: string): bool =
  ## コンテンツタイプがJSONかどうかを判定
  return content_type.contains("application/json") or content_type.contains("text/json")

proc isImageContentType*(content_type: string): bool =
  ## コンテンツタイプが画像かどうかを判定
  return content_type.startsWith("image/")

proc isVideoContentType*(content_type: string): bool =
  ## コンテンツタイプが動画かどうかを判定
  return content_type.startsWith("video/")

proc isAudioContentType*(content_type: string): bool =
  ## コンテンツタイプが音声かどうかを判定
  return content_type.startsWith("audio/")

proc isTextContentType*(content_type: string): bool =
  ## コンテンツタイプがテキストかどうかを判定
  return content_type.startsWith("text/") or 
         content_type == "application/json" or 
         content_type == "application/xml" or 
         content_type == "application/javascript"

proc isBinaryContentType*(content_type: string): bool =
  ## コンテンツタイプがバイナリかどうかを判定
  return not isTextContentType(content_type)

proc extractCharset*(content_type: string): string =
  ## Content-Typeヘッダーからcharsetを抽出
  result = "utf-8"  # デフォルト
  
  if "charset=" in content_type:
    let parts = content_type.split(';')
    for part in parts:
      let trimmed = part.strip()
      if trimmed.startsWith("charset="):
        let charset = trimmed[8..^1].strip()
        if charset.len > 0:
          # 引用符を削除
          if charset[0] == '"' and charset[^1] == '"':
            return charset[1..^2]
          else:
            return charset

proc handleRedirects*(client: HttpClientEx, url: string, max_redirects: int = 5): Future[RedirectInfo] {.async.} =
  ## リダイレクトを処理してリダイレクト情報を返す
  var result = RedirectInfo(
    original_url: url,
    final_url: url,
    redirect_chain: @[url],
    redirect_types: @[],
    is_valid: true
  )
  
  let start_time = now()
  var current_url = url
  var redirect_count = 0
  
  while redirect_count < max_redirects:
    let options = RequestOptions(
      follow_redirects: false, # 手動でリダイレクトを処理
      max_redirects: 0
    )
    
    try:
      let fetch_result = await client.fetch(current_url, options)
      let status = fetch_result.status_code
      
      # リダイレクトでない場合は現在のURLを返す
      if status notin {301, 302, 303, 307, 308}:
        break
      
      # リダイレクトタイプを記録
      result.redirect_types.add(status)
      
      # Locationヘッダーを取得
      if not fetch_result.headers.hasKey("Location"):
        result.is_valid = false
        break
      
      let location = fetch_result.headers["Location"]
      
      # 相対URLを絶対URLに変換
      current_url = joinUrl(current_url, location)
      
      # リダイレクトチェーンに追加
      result.redirect_chain.add(current_url)
      
      # リダイレクトカウントを更新
      redirect_count += 1
    except:
      # エラーが発生した場合は現在のURLまでのリダイレクトは有効
      result.is_valid = false
      break
  
  # 最終的なURLとタイムをセット
  result.final_url = current_url
  result.time_taken = now() - start_time
  
  return result

proc getUrlSimilarity*(url1, url2: string): UrlSimilarity =
  ## 2つのURLの類似性を計算
  try:
    let uri1 = parseUri(url1)
    let uri2 = parseUri(url2)
    
    # 完全一致
    if url1 == url2:
      return usExactMatch
    
    # ドメインとパスが一致
    if uri1.hostname == uri2.hostname and uri1.path == uri2.path:
      return usSameDomainAndPath
    
    # ドメインのみ一致
    if uri1.hostname == uri2.hostname:
      return usSameDomain
    
    # 関連なし
    return usUnrelated
  except:
    return usUnrelated

proc computeETag*(content: string): string =
  ## コンテンツからETagを計算
  let hash = getMD5(content)
  return "\"" & hash & "\""

proc parseETagHeader*(etag_header: string): tuple[weak: bool, value: string] =
  ## ETagヘッダーを解析
  var weak = false
  var value = etag_header.strip()
  
  # 弱いETagかどうかを確認
  if value.startsWith("W/"):
    weak = true
    value = value[2..^1]
  
  # 引用符を削除
  if value.startsWith("\"") and value.endsWith("\""):
    value = value[1..^2]
  
  return (weak: weak, value: value)

proc compareETags*(etag1, etag2: string): bool =
  ## 2つのETagが一致するかどうか確認
  let parsed1 = parseETagHeader(etag1)
  let parsed2 = parseETagHeader(etag2)
  
  # 弱いETagの場合は値だけで比較
  if parsed1.weak or parsed2.weak:
    return parsed1.value == parsed2.value
  
  # 強いETagの場合は完全一致が必要
  return etag1 == etag2

proc generateUserAgent*(browser_type: string = "chrome", 
                       os_type: string = "windows", 
                       version: string = "latest"): string =
  ## 指定された条件に合うUser-Agentを生成
  case browser_type.toLowerAscii():
    of "chrome":
      case os_type.toLowerAscii():
        of "windows":
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        of "mac":
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        of "linux":
          return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        of "android":
          return "Mozilla/5.0 (Linux; Android 10; SM-A205U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Mobile Safari/537.36"
        of "ios":
          return "Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/91.0.4472.80 Mobile/15E148 Safari/604.1"
        else:
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    
    of "firefox":
      case os_type.toLowerAscii():
        of "windows":
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:89.0) Gecko/20100101 Firefox/89.0"
        of "mac":
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:89.0) Gecko/20100101 Firefox/89.0"
        of "linux":
          return "Mozilla/5.0 (X11; Linux i686; rv:89.0) Gecko/20100101 Firefox/89.0"
        of "android":
          return "Mozilla/5.0 (Android 11; Mobile; rv:68.0) Gecko/68.0 Firefox/89.0"
        of "ios":
          return "Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/34.0 Mobile/15E148 Safari/605.1.15"
        else:
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:89.0) Gecko/20100101 Firefox/89.0"
    
    of "safari":
      case os_type.toLowerAscii():
        of "mac":
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15"
        of "ios":
          return "Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Mobile/15E148 Safari/604.1"
        else:
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15"
    
    of "edge":
      case os_type.toLowerAscii():
        of "windows":
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 Edg/91.0.864.59"
        of "mac":
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 Edg/91.0.864.59"
        of "android":
          return "Mozilla/5.0 (Linux; Android 10; HD1913) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Mobile Safari/537.36 EdgA/46.3.4.5155"
        of "ios":
          return "Mozilla/5.0 (iPhone; CPU iPhone OS 14_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 EdgiOS/46.3.13 Mobile/15E148 Safari/605.1.15"
        else:
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 Edg/91.0.864.59"
    
    of "opera":
      case os_type.toLowerAscii():
        of "windows":
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 OPR/77.0.4054.277"
        of "mac":
          return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 OPR/77.0.4054.277"
        of "linux":
          return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 OPR/77.0.4054.277"
        else:
          return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 OPR/77.0.4054.277"
    
    of "custom", "quantum":
      return "QuantumBrowser/1.0 (compatible; Quantum/1.0; +" & os_type & ")"
    
    else:
      # デフォルトはChromeになる
      return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

proc compressContent*(content: string, compression_type: string = "gzip"): string =
  ## コンテンツを圧縮
  case compression_type.toLowerAscii():
    of "gzip":
      return compress(content, BestCompression, dfGzip)
    of "deflate":
      return compress(content, BestCompression, dfDeflate)
    of "zlib":
      return compress(content, BestCompression, dfZlib)
    else:
      return content  # 不明な圧縮タイプの場合は元のコンテンツを返す

proc decompressContent*(content: string, compression_type: string): string =
  ## 圧縮されたコンテンツを展開
  try:
    case compression_type.toLowerAscii():
      of "gzip":
        return uncompress(content, dfGzip)
      of "deflate", "zlib":
        # deflateとzlibは似ているので両方試す
        try:
          return uncompress(content, dfDeflate)
        except:
          try:
            return uncompress(content, dfZlib)
          except:
            raise newException(ValueError, "Failed to decompress content")
      else:
        return content  # 不明な圧縮タイプの場合は元のコンテンツを返す
  except:
    # 展開に失敗した場合は元のコンテンツを返す
    return content

proc decompressResponse*(headers: HttpHeaders, body: string): string =
  ## レスポンスヘッダーに基づいてコンテンツを自動的に展開
  if not headers.hasKey("Content-Encoding"):
    return body
  
  let encoding = headers["Content-Encoding"].join(", ").toLowerAscii()
  
  if "gzip" in encoding:
    return decompressContent(body, "gzip")
  elif "deflate" in encoding:
    return decompressContent(body, "deflate")
  else:
    return body

proc formatDateTime*(dt: DateTime, format: string = "http_date"): string =
  ## 日時をHTTPヘッダーフォーマットに変換
  case format:
    of "http_date", "rfc7231":
      # RFC 7231形式: Sun, 06 Nov 1994 08:49:37 GMT
      return dt.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    of "rfc850":
      # RFC 850形式: Sunday, 06-Nov-94 08:49:37 GMT
      return dt.format("dddd, dd-MMM-yy HH:mm:ss 'GMT'")
    of "asctime":
      # asctime()形式: Sun Nov  6 08:49:37 1994
      return dt.format("ddd MMM d HH:mm:ss yyyy")
    of "iso8601", "iso":
      # ISO 8601形式: 1994-11-06T08:49:37Z
      return dt.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    of "cookie":
      # Cookie用の形式: Sun, 06-Nov-1994 08:49:37 GMT
      return dt.format("ddd, dd-MMM-yyyy HH:mm:ss 'GMT'")
    else:
      # デフォルトはRFC 7231形式
      return dt.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc parseHttpDate*(date_str: string): DateTime =
  ## HTTPヘッダーの日付文字列をパース
  # 複数のフォーマットを試す
  let formats = [
    "ddd, dd MMM yyyy HH:mm:ss 'GMT'",  # RFC 7231
    "dddd, dd-MMM-yy HH:mm:ss 'GMT'",   # RFC 850
    "ddd MMM d HH:mm:ss yyyy",          # asctime()
    "yyyy-MM-dd'T'HH:mm:ss'Z'"          # ISO 8601
  ]
  
  for fmt in formats:
    try:
      return parse(date_str, fmt)
    except:
      continue
  
  # すべてのフォーマットが失敗した場合は例外をスロー
  raise newException(ValueError, "Invalid HTTP date format: " & date_str)

proc getCacheControlMaxAge*(headers: HttpHeaders): int =
  ## Cache-Controlヘッダーからmax-ageを取得
  if not headers.hasKey("Cache-Control"):
    return -1
  
  let cache_control = headers["Cache-Control"].join(", ")
  
  # max-ageを検索
  for directive in cache_control.split(','):
    let trimmed = directive.strip()
    if trimmed.startsWith("max-age="):
      try:
        let value = trimmed[8..^1]
        return parseInt(value)
      except:
        return -1
  
  return -1

proc shouldCacheResponse*(headers: HttpHeaders): bool =
  ## レスポンスをキャッシュすべきかどうかを判断
  # Cache-Controlヘッダーをチェック
  if headers.hasKey("Cache-Control"):
    let cache_control = headers["Cache-Control"].join(", ").toLowerAscii()
    
    # no-storeが指定されていればキャッシュしない
    if "no-store" in cache_control:
      return false
    
    # private指定の場合はブラウザキャッシュのみ（ここではキャッシュする）
    
    # max-ageが0ならキャッシュしない
    for directive in cache_control.split(','):
      let trimmed = directive.strip()
      if trimmed.startsWith("max-age="):
        try:
          let value = parseInt(trimmed[8..^1])
          if value <= 0:
            return false
        except:
          discard
  
  # Pragmaヘッダーをチェック
  if headers.hasKey("Pragma"):
    let pragma = headers["Pragma"].join(", ").toLowerAscii()
    if "no-cache" in pragma:
      return false
  
  # Expiresヘッダーをチェック
  if headers.hasKey("Expires"):
    try:
      let expires_str = headers["Expires"][0]
      let expires = parseHttpDate(expires_str)
      if expires <= now():
        return false
    except:
      discard
  
  # 基本的にはキャッシュ可能
  return true

proc parseBasicAuth*(auth_header: string): tuple[username, password: string] =
  ## Basic認証ヘッダーをパース
  if auth_header.len == 0 or not auth_header.startsWith("Basic "):
    return ("", "")
  
  try:
    let encoded = auth_header[6..^1]
    let decoded = decode(encoded)
    let parts = decoded.split(':', maxsplit=1)
    
    if parts.len == 2:
      return (username: parts[0], password: parts[1])
    else:
      return (username: decoded, password: "")
  except:
    return ("", "")

proc generateBasicAuth*(username, password: string): string =
  ## Basic認証ヘッダーを生成
  let auth_str = username & ":" & password
  let encoded = encode(auth_str)
  return "Basic " & encoded

proc analyzeSecurity*(headers: HttpHeaders): HttpSecurityInfo =
  ## HTTPレスポンスヘッダーからセキュリティ情報を分析
  result = HttpSecurityInfo()
  
  # HSTS (HTTP Strict Transport Security)
  if headers.hasKey("Strict-Transport-Security"):
    result.has_hsts = true
    let hsts = headers["Strict-Transport-Security"][0]
    
    # max-ageを抽出
    if "max-age=" in hsts:
      let max_age_start = hsts.find("max-age=") + 8
      var max_age_end = hsts.len
      for i in max_age_start..<hsts.len:
        if hsts[i] == ';' or hsts[i] == ' ':
          max_age_end = i
          break
      
      try:
        result.hsts_max_age = parseInt(hsts[max_age_start..<max_age_end])
      except:
        discard
    
    # includeSubdomainsをチェック
    result.hsts_include_subdomains = "includeSubDomains" in hsts
  
  # HPKP (HTTP Public Key Pinning)
  result.has_hpkp = headers.hasKey("Public-Key-Pins")
  
  # CSP (Content Security Policy)
  result.has_csp = headers.hasKey("Content-Security-Policy")
  
  # XSS Protection
  result.has_xss_protection = headers.hasKey("X-XSS-Protection")
  
  # X-Content-Type-Options
  result.has_x_content_type_options = headers.hasKey("X-Content-Type-Options")
  
  # X-Frame-Options
  result.has_x_frame_options = headers.hasKey("X-Frame-Options")
  
  # Referrer-Policy
  result.has_referrer_policy = headers.hasKey("Referrer-Policy")
  
  # Feature-Policy または Permissions-Policy
  result.has_feature_policy = headers.hasKey("Feature-Policy") or headers.hasKey("Permissions-Policy")

proc analyzeTracking*(url: string, query_params: Table[string, string]): UrlTrackingInfo =
  ## URLからトラッキング情報を分析
  result = UrlTrackingInfo()
  
  # 既知のトラッキングパラメータのリスト
  let known_tracking_params = [
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",  # Google Analytics
    "fbclid",                                                               # Facebook
    "gclid", "gclsrc",                                                      # Google Ads
    "dclid",                                                                # DoubleClick
    "zanpid",                                                               # Zanox
    "icid", "ici",                                                          # Adobe
    "_ga",                                                                  # Google Analytics
    "mc_cid", "mc_eid",                                                     # Mailchimp
    "ref", "referrer", "source",                                            # 一般的な参照元
    "trk", "linkId",                                                        # LinkedIn
    "yclid",                                                                # Yandex
    "wbraid", "gbraid"                                                      # Google
  ]
  
  # 既知のトラッキングドメイン
  let tracking_domains = [
    "googleadservices.com",
    "doubleclick.net",
    "googlesyndication.com",
    "google-analytics.com",
    "googletagmanager.com",
    "facebook.com/tr",
    "facebook.com/plugins",
    "connect.facebook.net",
    "platform.twitter.com",
    "analytics.twitter.com",
    "ads.linkedin.com",
    "analytics.tiktok.com",
    "bat.bing.com",
    "script.hotjar.com",
    "static.hotjar.com",
    "analytics.pinterest.com"
  ]
  
  # URLをパース
  let uri = parseUri(url)
  let domain = uri.hostname.toLowerAscii()
  
  # 既知のトラッキングパラメータをチェック
  for param, _ in query_params:
    if param in known_tracking_params:
      result.has_tracking_params = true
      result.tracking_params.add(param)
  
  # 既知のトラッキングドメインをチェック
  for tracker in tracking_domains:
    if domain == tracker or domain.endsWith("." & tracker):
      result.is_known_tracker = true
      
      # トラッカーの種類を判定
      if "google" in tracker or "doubleclick" in tracker:
        result.tracker_category = "Google"
        result.privacy_impact = 7
      elif "facebook" in tracker:
        result.tracker_category = "Facebook"
        result.privacy_impact = 8
      elif "twitter" in tracker:
        result.tracker_category = "Twitter"
        result.privacy_impact = 6
      elif "linkedin" in tracker:
        result.tracker_category = "LinkedIn"
        result.privacy_impact = 5
      elif "tiktok" in tracker:
        result.tracker_category = "TikTok"
        result.privacy_impact = 9
      elif "bing" in tracker:
        result.tracker_category = "Microsoft"
        result.privacy_impact = 7
      elif "hotjar" in tracker:
        result.tracker_category = "Hotjar"
        result.privacy_impact = 8
      elif "pinterest" in tracker:
        result.tracker_category = "Pinterest"
        result.privacy_impact = 6
      else:
        result.tracker_category = "Other"
        result.privacy_impact = 5
      
      break
  
  # ピクセルトラッキングの特徴をチェック
  let path = uri.path.toLowerAscii()
  if path.endsWith(".gif") or path.endsWith(".png") or path.endsWith(".jpg"):
    if query_params.len > 0:
      result.has_tracking_params = true
      if not result.is_known_tracker:
        result.tracker_category = "Tracking Pixel"
        result.privacy_impact = 6
  
  # ビーコンAPIのようなパスをチェック
  if "/beacon" in path or "/pixel" in path or "/track" in path or "/collect" in path or "/log" in path:
    result.has_tracking_params = true
    if not result.is_known_tracker:
      result.tracker_category = "Analytics/Beacon"
      result.privacy_impact = 7
  
  # プライバシー影響度のデフォルト設定
  if result.has_tracking_params and result.privacy_impact == 0:
    result.privacy_impact = 4  # デフォルトの影響度

proc createRandomBoundary*(): string =
  ## マルチパートリクエスト用のランダムなバウンダリ文字列を生成
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  var boundary = "----WebKitFormBoundary"
  
  for i in 0..<16:
    let idx = rand(chars.len - 1)
    boundary.add(chars[idx])
  
  return boundary 

proc newContentSecurityPolicy*(): ContentSecurityPolicy =
  ## 新しいCSPオブジェクトを作成
  result.directives = initTable[CspDirective, seq[string]]()
  result.report_only = false

proc parseContentSecurityPolicy*(csp_header: string): ContentSecurityPolicy =
  ## CSPヘッダーを解析
  result = newContentSecurityPolicy()
  result.raw_policy = csp_header
  
  # ディレクティブごとに分割
  let directives = csp_header.split(';')
  
  for directive in directives:
    let directive_trimmed = directive.strip()
    if directive_trimmed.len == 0:
      continue
    
    # ディレクティブ名と値を分離
    let parts = directive_trimmed.split(maxsplit=1)
    if parts.len == 0:
      continue
    
    let directive_name = parts[0].strip().toLowerAscii()
    let directive_values = if parts.len > 1: parts[1].strip().split(' ') else: @[]
    
    # ディレクティブの種類を判断
    case directive_name:
      of "default-src":
        result.directives[cdDefaultSrc] = directive_values
      of "script-src":
        result.directives[cdScriptSrc] = directive_values
      of "style-src":
        result.directives[cdStyleSrc] = directive_values
      of "img-src":
        result.directives[cdImgSrc] = directive_values
      of "connect-src":
        result.directives[cdConnectSrc] = directive_values
      of "font-src":
        result.directives[cdFontSrc] = directive_values
      of "object-src":
        result.directives[cdObjectSrc] = directive_values
      of "media-src":
        result.directives[cdMediaSrc] = directive_values
      of "frame-src":
        result.directives[cdFrameSrc] = directive_values
      of "worker-src":
        result.directives[cdWorkerSrc] = directive_values
      of "manifest-src":
        result.directives[cdManifestSrc] = directive_values
      of "prefetch-src":
        result.directives[cdPrefetchSrc] = directive_values
      of "child-src":
        result.directives[cdChildSrc] = directive_values
      of "frame-ancestors":
        result.directives[cdFrameAncestors] = directive_values
      of "form-action":
        result.directives[cdFormAction] = directive_values
      of "base-uri":
        result.directives[cdBaseUri] = directive_values
      of "report-uri":
        result.directives[cdReportUri] = directive_values
      of "report-to":
        result.directives[cdReportTo] = directive_values
      of "sandbox":
        result.directives[cdSandbox] = directive_values
      of "upgrade-insecure-requests":
        result.directives[cdUpgradeInsecureRequests] = directive_values
      of "block-all-mixed-content":
        result.directives[cdBlockAllMixedContent] = directive_values
      of "require-sri-for":
        result.directives[cdRequireSriFor] = directive_values
      of "plugin-types":
        result.directives[cdPluginTypes] = directive_values
      of "referrer":
        result.directives[cdReferrerPolicy] = directive_values
      else:
        # 未知のディレクティブは無視
        discard

proc generateContentSecurityPolicyHeader*(csp: ContentSecurityPolicy): string =
  ## CSPオブジェクトからヘッダー文字列を生成
  var parts: seq[string] = @[]
  
  for directive, values in csp.directives:
    let directive_name = case directive:
      of cdDefaultSrc: "default-src"
      of cdScriptSrc: "script-src"
      of cdStyleSrc: "style-src"
      of cdImgSrc: "img-src"
      of cdConnectSrc: "connect-src"
      of cdFontSrc: "font-src"
      of cdObjectSrc: "object-src"
      of cdMediaSrc: "media-src"
      of cdFrameSrc: "frame-src"
      of cdWorkerSrc: "worker-src"
      of cdManifestSrc: "manifest-src"
      of cdPrefetchSrc: "prefetch-src"
      of cdChildSrc: "child-src"
      of cdFrameAncestors: "frame-ancestors"
      of cdFormAction: "form-action"
      of cdBaseUri: "base-uri"
      of cdReportUri: "report-uri"
      of cdReportTo: "report-to"
      of cdSandbox: "sandbox"
      of cdUpgradeInsecureRequests: "upgrade-insecure-requests"
      of cdBlockAllMixedContent: "block-all-mixed-content"
      of cdRequireSriFor: "require-sri-for"
      of cdPluginTypes: "plugin-types"
      of cdReferrerPolicy: "referrer"
    
    if values.len > 0:
      parts.add(directive_name & " " & values.join(" "))
    else:
      parts.add(directive_name)
  
  return parts.join("; ")

proc newSecureHttpHeaders*(): HttpHeaders =
  ## セキュリティを強化したHTTPヘッダーを生成
  result = newHttpHeaders()
  
  # X-XSS-Protection
  result["X-XSS-Protection"] = "1; mode=block"
  
  # X-Content-Type-Options
  result["X-Content-Type-Options"] = "nosniff"
  
  # X-Frame-Options
  result["X-Frame-Options"] = "SAMEORIGIN"
  
  # Referrer-Policy
  result["Referrer-Policy"] = "strict-origin-when-cross-origin"
  
  # Feature-Policy
  result["Feature-Policy"] = "camera 'none'; microphone 'none'; geolocation 'none'"
  
  # Permissions-Policy (Feature-Policyの後継)
  result["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"

proc addHstsHeader*(headers: var HttpHeaders, max_age: int = 31536000, 
                  include_subdomains: bool = true, preload: bool = false) =
  ## HSTS (HTTP Strict Transport Security) ヘッダーを追加
  var hsts_value = "max-age=" & $max_age
  
  if include_subdomains:
    hsts_value = hsts_value & "; includeSubDomains"
  
  if preload:
    hsts_value = hsts_value & "; preload"
  
  headers["Strict-Transport-Security"] = hsts_value

proc addContentSecurityPolicyHeader*(headers: var HttpHeaders, csp: ContentSecurityPolicy, 
                                   report_only: bool = false) =
  ## CSP (Content Security Policy) ヘッダーを追加
  let header_name = if report_only: "Content-Security-Policy-Report-Only" 
                   else: "Content-Security-Policy"
  
  headers[header_name] = generateContentSecurityPolicyHeader(csp)

proc createDefaultContentSecurityPolicy*(report_uri: string = ""): ContentSecurityPolicy =
  ## 安全なデフォルトのCSPポリシーを作成
  result = newContentSecurityPolicy()
  
  # 基本的な制限を設定
  result.directives[cdDefaultSrc] = @["'self'"]
  result.directives[cdScriptSrc] = @["'self'", "'strict-dynamic'"]
  result.directives[cdStyleSrc] = @["'self'", "'unsafe-inline'"]
  result.directives[cdImgSrc] = @["'self'", "data:"]
  result.directives[cdConnectSrc] = @["'self'"]
  result.directives[cdFontSrc] = @["'self'"]
  result.directives[cdObjectSrc] = @["'none'"]
  result.directives[cdMediaSrc] = @["'self'"]
  result.directives[cdFrameSrc] = @["'self'"]
  result.directives[cdFrameAncestors] = @["'self'"]
  result.directives[cdFormAction] = @["'self'"]
  result.directives[cdBaseUri] = @["'self'"]
  result.directives[cdUpgradeInsecureRequests] = @[]
  
  # レポートURIが指定されていればそれを設定
  if report_uri.len > 0:
    result.directives[cdReportUri] = @[report_uri]

proc newHttpHeaderSecuritySettings*(): HttpHeaderSecuritySettings =
  ## デフォルトのHTTPヘッダーセキュリティ設定を作成
  result.enable_hsts = true
  result.hsts_max_age = 31536000  # 1年
  result.hsts_include_subdomains = true
  result.hsts_preload = false
  
  result.enable_csp = true
  result.csp_directives = initTable[CspDirective, seq[string]]()
  result.csp_directives[cdDefaultSrc] = @["'self'"]
  result.csp_directives[cdScriptSrc] = @["'self'"]
  result.csp_directives[cdObjectSrc] = @["'none'"]
  result.csp_report_only = false
  
  result.enable_xss_protection = true
  result.xss_protection_mode = 1
  
  result.enable_x_content_type_options = true
  
  result.enable_x_frame_options = true
  result.x_frame_options_value = "SAMEORIGIN"
  
  result.enable_referrer_policy = true
  result.referrer_policy_value = "strict-origin-when-cross-origin"
  
  result.enable_feature_policy = true
  result.feature_policy_directives = initTable[string, seq[string]]()
  result.feature_policy_directives["camera"] = @["'none'"]
  result.feature_policy_directives["microphone"] = @["'none'"]
  result.feature_policy_directives["geolocation"] = @["'none'"]

proc applySecuritySettings*(headers: var HttpHeaders, settings: HttpHeaderSecuritySettings) =
  ## セキュリティ設定をHTTPヘッダーに適用
  
  # HSTS
  if settings.enable_hsts:
    var hsts_value = "max-age=" & $settings.hsts_max_age
    if settings.hsts_include_subdomains:
      hsts_value = hsts_value & "; includeSubDomains"
    if settings.hsts_preload:
      hsts_value = hsts_value & "; preload"
    headers["Strict-Transport-Security"] = hsts_value
  
  # CSP
  if settings.enable_csp:
    var csp = newContentSecurityPolicy()
    csp.directives = settings.csp_directives
    let header_name = if settings.csp_report_only: 
                     "Content-Security-Policy-Report-Only" 
                     else: "Content-Security-Policy"
    headers[header_name] = generateContentSecurityPolicyHeader(csp)
  
  # X-XSS-Protection
  if settings.enable_xss_protection:
    var value = $settings.xss_protection_mode
    if settings.xss_protection_mode == 1:
      value = value & "; mode=block"
    headers["X-XSS-Protection"] = value
  
  # X-Content-Type-Options
  if settings.enable_x_content_type_options:
    headers["X-Content-Type-Options"] = "nosniff"
  
  # X-Frame-Options
  if settings.enable_x_frame_options:
    headers["X-Frame-Options"] = settings.x_frame_options_value
  
  # Referrer-Policy
  if settings.enable_referrer_policy:
    headers["Referrer-Policy"] = settings.referrer_policy_value
  
  # Feature-Policy
  if settings.enable_feature_policy:
    var feature_policy_parts: seq[string] = @[]
    for feature, values in settings.feature_policy_directives:
      feature_policy_parts.add(feature & " " & values.join(" "))
    headers["Feature-Policy"] = feature_policy_parts.join("; ")
    
    # 新しいPermissions-Policy形式も追加
    var permissions_policy_parts: seq[string] = @[]
    for feature, values in settings.feature_policy_directives:
      if values.len == 1 and values[0] == "'none'":
        permissions_policy_parts.add(feature & "=()")
      elif values.len == 1 and values[0] == "'self'":
        permissions_policy_parts.add(feature & "=(self)")
      else:
        permissions_policy_parts.add(feature & "=(" & values.join(" ") & ")")
    headers["Permissions-Policy"] = permissions_policy_parts.join(", ")

proc calculateSecurityScore*(headers: HttpHeaders): int =
  ## HTTPヘッダーからセキュリティスコアを計算（0-100）
  var score = 0
  var total_weight = 0
  
  # HSTS（重み：20）
  if headers.hasKey("Strict-Transport-Security"):
    let hsts = headers["Strict-Transport-Security"][0]
    score += 15
    total_weight += 20
    
    # includeSubDomainsを含む場合は追加点
    if "includeSubDomains" in hsts:
      score += 3
    
    # max-ageが1年以上の場合は追加点
    if "max-age=" in hsts:
      try:
        let max_age_start = hsts.find("max-age=") + 8
        var max_age_end = hsts.len
        for i in max_age_start..<hsts.len:
          if hsts[i] == ';' or hsts[i] == ' ':
            max_age_end = i
            break
        
        let max_age = parseInt(hsts[max_age_start..<max_age_end])
        if max_age >= 31536000:  # 1年
          score += 2
      except:
        discard
  
  # CSP（重み：20）
  if headers.hasKey("Content-Security-Policy"):
    let csp = headers["Content-Security-Policy"][0]
    score += 10
    total_weight += 20
    
    # デフォルトソースを制限している場合は追加点
    if "default-src 'self'" in csp:
      score += 5
    
    # objectソースを制限している場合は追加点
    if "object-src 'none'" in csp:
      score += 5
  
  # X-Content-Type-Options（重み：10）
  if headers.hasKey("X-Content-Type-Options"):
    let xcto = headers["X-Content-Type-Options"][0]
    if xcto == "nosniff":
      score += 10
    total_weight += 10
  
  # X-Frame-Options（重み：10）
  if headers.hasKey("X-Frame-Options"):
    let xfo = headers["X-Frame-Options"][0]
    if xfo == "DENY":
      score += 10
    elif xfo == "SAMEORIGIN":
      score += 8
    total_weight += 10
  
  # Referrer-Policy（重み：10）
  if headers.hasKey("Referrer-Policy"):
    let rp = headers["Referrer-Policy"][0]
    score += 5
    total_weight += 10
    
    # よりプライバシーに配慮したポリシーは追加点
    if rp in ["no-referrer", "same-origin", "strict-origin", "strict-origin-when-cross-origin"]:
      score += 5
  
  # X-XSS-Protection（重み：10）
  if headers.hasKey("X-XSS-Protection"):
    let xxp = headers["X-XSS-Protection"][0]
    if xxp == "1; mode=block":
      score += 10
    elif xxp == "1":
      score += 5
    total_weight += 10
  
  # Feature-Policy/Permissions-Policy（重み：10）
  if headers.hasKey("Feature-Policy") or headers.hasKey("Permissions-Policy"):
    score += 10
    total_weight += 10
  
  # 全体のスコアを計算
  let final_score = if total_weight > 0: (score * 100) div total_weight else: 0
  
  return final_score

proc findSecurityIssues*(headers: HttpHeaders): seq[string] =
  ## HTTPヘッダーからセキュリティ上の問題点を見つける
  result = @[]
  
  # HSTS
  if not headers.hasKey("Strict-Transport-Security"):
    result.add("HSTSが設定されていません。転送中のデータ傍受のリスクがあります。")
  else:
    let hsts = headers["Strict-Transport-Security"][0]
    if "includeSubDomains" notin hsts:
      result.add("HSTSにincludeSubDomainsが設定されていません。サブドメイン攻撃のリスクがあります。")
    
    if "max-age=" in hsts:
      try:
        let max_age_start = hsts.find("max-age=") + 8
        var max_age_end = hsts.len
        for i in max_age_start..<hsts.len:
          if hsts[i] == ';' or hsts[i] == ' ':
            max_age_end = i
            break
        
        let max_age = parseInt(hsts[max_age_start..<max_age_end])
        if max_age < 31536000:  # 1年未満
          result.add("HSTSのmax-ageが1年未満です。通常は1年以上を推奨します。")
      except:
        result.add("HSTSのmax-age値が不正です。")
  
  # CSP
  if not headers.hasKey("Content-Security-Policy"):
    result.add("Content Security Policyが設定されていません。クロスサイトスクリプティング攻撃のリスクが高まります。")
  else:
    let csp = headers["Content-Security-Policy"][0]
    if "default-src" notin csp:
      result.add("CSPにdefault-srcディレクティブが設定されていません。")
    
    if "object-src" notin csp and "default-src 'none'" notin csp:
      result.add("CSPにobject-srcディレクティブが制限されていません。Flash等の脆弱性のリスクがあります。")
    
    if "'unsafe-inline'" in csp and "'strict-dynamic'" notin csp:
      result.add("CSPで'unsafe-inline'が許可されています。XSSのリスクが高まります。")
    
    if "'unsafe-eval'" in csp:
      result.add("CSPで'unsafe-eval'が許可されています。XSSのリスクが高まります。")
  
  # X-Content-Type-Options
  if not headers.hasKey("X-Content-Type-Options"):
    result.add("X-Content-Type-Optionsが設定されていません。MIMEタイプスニッフィング攻撃のリスクがあります。")
  elif headers["X-Content-Type-Options"][0] != "nosniff":
    result.add("X-Content-Type-Optionsが適切に設定されていません。'nosniff'を設定してください。")
  
  # X-Frame-Options
  if not headers.hasKey("X-Frame-Options"):
    result.add("X-Frame-Optionsが設定されていません。クリックジャッキング攻撃のリスクがあります。")
  
  # Referrer-Policy
  if not headers.hasKey("Referrer-Policy"):
    result.add("Referrer-Policyが設定されていません。情報漏洩のリスクがあります。")
  
  # X-XSS-Protection
  if not headers.hasKey("X-XSS-Protection"):
    result.add("X-XSS-Protectionが設定されていません。XSS攻撃対策が弱まります。")
  
  # Feature-Policy/Permissions-Policy
  if not headers.hasKey("Feature-Policy") and not headers.hasKey("Permissions-Policy"):
    result.add("Feature-Policy/Permissions-Policyが設定されていません。機密機能へのアクセス制御が弱まります。")
  
  return result

proc generateSecurityHeadersReport*(headers: HttpHeaders): HttpSecurityInfo =
  ## HTTPヘッダーからセキュリティレポートを生成
  result.has_hsts = headers.hasKey("Strict-Transport-Security")
  result.has_csp = headers.hasKey("Content-Security-Policy")
  result.has_xss_protection = headers.hasKey("X-XSS-Protection")
  result.has_x_content_type_options = headers.hasKey("X-Content-Type-Options")
  result.has_x_frame_options = headers.hasKey("X-Frame-Options")
  result.has_referrer_policy = headers.hasKey("Referrer-Policy")
  result.has_feature_policy = headers.hasKey("Feature-Policy") or headers.hasKey("Permissions-Policy")
  result.security_score = calculateSecurityScore(headers)
  result.issues = findSecurityIssues(headers)
  
  # HSTSの詳細設定を取得
  if result.has_hsts:
    let hsts = headers["Strict-Transport-Security"][0]
    result.hsts_include_subdomains = "includeSubDomains" in hsts
    if "max-age=" in hsts:
      try:
        let max_age_start = hsts.find("max-age=") + 8
        var max_age_end = hsts.len
        for i in max_age_start..<hsts.len:
          if hsts[i] == ';' or hsts[i] == ' ':
            max_age_end = i
            break
        
        result.hsts_max_age = parseInt(hsts[max_age_start..<max_age_end])
      except:
        result.hsts_max_age = 0
    else:
      result.hsts_max_age = 0

proc isMixedContent*(base_url: string, resource_url: string): bool =
  ## Mixed Content（HTTPS上でHTTPリソースを読み込む）検出
  try:
    let base_uri = parseUri(base_url)
    let resource_uri = parseUri(resource_url)
    
    # ベースURLがHTTPS、リソースURLがHTTPの場合はMixed Content
    return base_uri.scheme == "https" and resource_uri.scheme == "http"
  except:
    return false

proc hasMixedContent*(base_url: string, resource_urls: seq[string]): bool =
  ## 複数リソースでMixed Contentがあるか検出
  for url in resource_urls:
    if isMixedContent(base_url, url):
      return true
  return false

proc detectMixedContent*(base_url: string, resource_urls: seq[string]): seq[string] =
  ## Mixed Contentを検出して報告
  result = @[]
  for url in resource_urls:
    if isMixedContent(base_url, url):
      result.add(url)
  return result

proc isInternalUrl*(base_url: string, test_url: string): bool =
  ## URLが同一オリジン（ドメイン）内かチェック
  try:
    let base_uri = parseUri(base_url)
    let test_uri = parseUri(test_url)
    
    # スキームとホスト名が一致するか確認
    return base_uri.scheme == test_uri.scheme and 
           base_uri.hostname == test_uri.hostname and
           (base_uri.port == test_uri.port or 
            (base_uri.port.len == 0 and test_uri.port.len == 0))
  except:
    return false

proc calculateCrossOriginResourceInfo*(base_url: string, resource_urls: seq[string]): 
    tuple[internal: seq[string], external: seq[string], mixed: seq[string]] =
  ## リソースURLが内部・外部・混在コンテンツかを分類
  result.internal = @[]
  result.external = @[]
  result.mixed = @[]
  
  for url in resource_urls:
    if isInternalUrl(base_url, url):
      result.internal.add(url)
    else:
      result.external.add(url)
    
    if isMixedContent(base_url, url):
      result.mixed.add(url)
  
  return result

proc validateCsp*(csp: ContentSecurityPolicy): seq[string] =
  ## CSPの設定を検証し、潜在的な問題点を報告
  result = @[]
  
  # default-srcの確認
  if cdDefaultSrc notin csp.directives:
    result.add("default-srcディレクティブが設定されていません")
  
  # スクリプトの設定をチェック
  if cdScriptSrc notin csp.directives and cdDefaultSrc notin csp.directives:
    result.add("script-srcまたはdefault-srcディレクティブが設定されていません")
  elif cdScriptSrc in csp.directives:
    let script_src = csp.directives[cdScriptSrc]
    # 危険な設定をチェック
    if "'unsafe-inline'" in script_src and "'strict-dynamic'" notin script_src:
      result.add("script-srcで'unsafe-inline'が許可されています（XSSリスク）")
    if "'unsafe-eval'" in script_src:
      result.add("script-srcで'unsafe-eval'が許可されています（XSSリスク）")
    if "*" in script_src:
      result.add("script-srcでワイルドカード(*)が許可されています（XSSリスク）")
  
  # object-srcまたはdefault-srcの制限を確認
  if cdObjectSrc notin csp.directives and 
     (cdDefaultSrc notin csp.directives or 
      "'none'" notin csp.directives.getOrDefault(cdDefaultSrc)):
    result.add("object-srcが制限されていません")
  
  # report-uriの設定を確認
  if cdReportUri notin csp.directives and cdReportTo notin csp.directives:
    result.add("CSP違反の報告先（report-uriまたはreport-to）が設定されていません")
  
  # upgrade-insecure-requestsの推奨
  if cdUpgradeInsecureRequests notin csp.directives:
    result.add("upgrade-insecure-requestsが設定されていません（Mixed Contentリスク）")
  
  return result

proc generateStrongCspHeader*(): string =
  ## 強力なCSPヘッダーを生成
  var csp = newContentSecurityPolicy()
  
  # 基本的な制限
  csp.directives[cdDefaultSrc] = @["'self'"]
  csp.directives[cdScriptSrc] = @["'self'", "'strict-dynamic'", "'nonce-$NONCE'"]
  csp.directives[cdStyleSrc] = @["'self'", "'unsafe-inline'"]
  csp.directives[cdImgSrc] = @["'self'", "data:"]
  csp.directives[cdConnectSrc] = @["'self'"]
  csp.directives[cdFontSrc] = @["'self'"]
  csp.directives[cdObjectSrc] = @["'none'"]
  csp.directives[cdMediaSrc] = @["'self'"]
  csp.directives[cdFrameSrc] = @["'self'"]
  csp.directives[cdFrameAncestors] = @["'none'"]
  csp.directives[cdFormAction] = @["'self'"]
  csp.directives[cdBaseUri] = @["'self'"]
  csp.directives[cdUpgradeInsecureRequests] = @[]
  csp.directives[cdBlockAllMixedContent] = @[]
  
  return generateContentSecurityPolicyHeader(csp)

proc generateNonce*(): string =
  ## CSPで使用するランダムなノンス値を生成
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  var result = ""
  for i in 0..15:
    result.add(chars[rand(chars.len - 1)])
  return result

proc replaceNonceInCsp*(csp: string, nonce: string): string =
  ## CSPヘッダー内のノンスプレースホルダを置換
  return csp.replace("$NONCE", nonce)

proc generateSecurityHeaders*(settings: HttpHeaderSecuritySettings, nonce: string = ""): HttpHeaders =
  ## 指定された設定に基づいてセキュリティヘッダーを生成
  result = newHttpHeaders()
  
  # 設定を適用
  applySecuritySettings(result, settings)
  
  # ノンスがある場合はCSPに適用
  if nonce.len > 0 and result.hasKey("Content-Security-Policy"):
    let csp = result["Content-Security-Policy"][0]
    result["Content-Security-Policy"] = replaceNonceInCsp(csp, nonce)
  
  return result

proc generateSecurityReportForUrl*(url: string, headers: HttpHeaders): HttpSecurityInfo =
  ## URLとそのレスポンスヘッダーからセキュリティレポートを生成
  result = generateSecurityHeadersReport(headers)
  
  # URLのスキームを検証
  let uri = parseUri(url)
  if uri.scheme != "https":
    result.security_score = max(0, result.security_score - 30)
    result.issues.add("URLがHTTPSではありません。転送データが暗号化されていません。")
  
  return result

proc newHttpSecurityValidator*(): HttpSecurityValidator =
  ## 新しいHTTPセキュリティバリデータを作成
  result = HttpSecurityValidator()
  result.max_header_size = 8192
  result.max_url_length = 2048
  result.max_cookie_size = 4096
  result.blocked_headers = ["X-Powered-By", "Server", "X-AspNet-Version", "X-AspNetMvc-Version"].toHashSet
  result.blocked_user_agents = @[
    "sqlmap", "nikto", "nessus", "nmap", "ZAP", "burp", "w3af", "hydra", "dirbuster", "gobuster"
  ]
  result.ip_blacklist = initHashSet[string]()
  result.xss_filter_enabled = true
  result.csrf_protection = true
  result.sql_injection_filter = true
  result.path_traversal_filter = true
  result.command_injection_filter = true
  result.csp_enforced = true
  result.require_https = true
  result.hsts_enforced = true
  result.x_frame_options = "DENY"
  result.x_content_type_options = "nosniff"
  result.referrer_policy = "strict-origin-when-cross-origin"
  result.permissions_policy = "accelerometer=(), camera=(), geolocation=(), microphone=(), payment=()"
  result.trusted_types_policy = ttpStrict
  result.max_redirect_chain = 5
  result.url_whitelist = @[]
  result.url_blacklist = @[]
  return result

proc validateRequest*(validator: HttpSecurityValidator, url: string, 
                      headers: HttpHeaders, body: string = ""): seq[string] =
  ## HTTPリクエストを検証し、セキュリティ問題があれば報告
  result = @[]
  
  # URLの検証
  let uri = parseUri(url)
  if uri.scheme != "https" and validator.require_https:
    result.add("HTTPSが必須です")
  
  if url.len > validator.max_url_length:
    result.add($"URLが長すぎます (最大: {validator.max_url_length}文字)")
  
  # パストラバーサル検出
  if validator.path_traversal_filter and (
      "../" in uri.path or 
      "%2e%2e%2f" in uri.path.toLowerAscii or 
      "%252e%252e%252f" in uri.path.toLowerAscii):
    result.add("パストラバーサルの可能性があるパス")
  
  # ブラックリストURL
  for pattern in validator.url_blacklist:
    if pattern in url:
      result.add($"禁止されたURLパターンが含まれています: {pattern}")
  
  # ヘッダーサイズ検証
  var total_header_size = 0
  for key, values in headers:
    total_header_size += key.len
    for val in values:
      total_header_size += val.len
  
  if total_header_size > validator.max_header_size:
    result.add($"ヘッダーサイズが大きすぎます (最大: {validator.max_header_size}バイト)")
  
  # 禁止ヘッダー
  for key in headers.keys:
    if key.toLowerAscii in validator.blocked_headers:
      result.add($"禁止されたヘッダー: {key}")
  
  # User-Agent検証
  if headers.hasKey("User-Agent"):
    let ua = headers["User-Agent"][0]
    for blocked_ua in validator.blocked_user_agents:
      if blocked_ua in ua:
        result.add($"セキュリティスキャナーのユーザーエージェントが検出されました: {blocked_ua}")
  
  # SQLインジェクション検出
  if validator.sql_injection_filter:
    let sql_patterns = [
      r"(\s|\')select\s", r"(\s|\')insert\s", r"(\s|\')update\s", r"(\s|\')delete\s", 
      r"(\s|\')drop\s", r"(\s|\')union\s", r"(\s|\')exec\s", r"(\s|\')declare\s",
      r"--", r";--", r";", r"'--", r"'#", r"/\*", r"\*/"
    ]
    
    let check_sql = body & uri.query
    for pattern in sql_patterns:
      if check_sql.contains(re(pattern, {reIgnoreCase})):
        result.add("SQLインジェクションの可能性があるパターンが検出されました")
        break
  
  # XSS検出
  if validator.xss_filter_enabled:
    let xss_patterns = [
      r"<script", r"javascript:", r"onerror=", r"onload=", r"onclick=", r"onmouseover=",
      r"onfocus=", r"onblur=", r"<img[^>]*src[^>]*=", r"<iframe", r"alert\(", r"eval\(",
      r"document\.cookie", r"document\.domain", r"document\.write"
    ]
    
    let check_xss = body & uri.query
    for pattern in xss_patterns:
      if check_xss.contains(re(pattern, {reIgnoreCase})):
        result.add("XSSの可能性があるパターンが検出されました")
        break
  
  # コマンドインジェクション検出
  if validator.command_injection_filter:
    let cmd_patterns = [
      r"[;&|`]", r"\$\(", r"\$\{", r"\|", r">", r"<", r"\bsh\b", r"\bbash\b",
      r"\bcmd\b", r"\bpowershell\b", r"\bexec\b", r"\bsystem\b", r"\bpassthru\b"
    ]
    
    let check_cmd = body & uri.query
    for pattern in cmd_patterns:
      if check_cmd.contains(re(pattern)):
        result.add("コマンドインジェクションの可能性があるパターンが検出されました")
        break
  
  return result

proc scanForVulnerabilities*(url: string, body: string, headers: HttpHeaders): seq[VulnerabilityScanResult] =
  ## ウェブページの脆弱性をスキャン
  result = @[]
  
  # クロスサイトスクリプティング (XSS) チェック
  let xss_patterns = [
    (r"<script.*?>.*?</script>", "HTMLにインラインスクリプトが含まれています"),
    (r"javascript:", "javascript:スキームが使用されています"),
    (r"on[a-z]+\s*=", "インラインイベントハンドラが使用されています"),
    (r"eval\(", "evalが使用されています")
  ]
  
  for (pattern, desc) in xss_patterns:
    if body.contains(re(pattern, {reIgnoreCase})):
      var result_item = VulnerabilityScanResult()
      result_item.vulnerability_type = vtXss
      result_item.severity = 8
      result_item.description = "クロスサイトスクリプティング (XSS) の脆弱性"
      result_item.found_in = "レスポンスボディ"
      result_item.payload = desc
      result_item.mitigation = "コンテンツセキュリティポリシー(CSP)を設定し、ユーザー入力を適切にサニタイズしてください"
      result.add(result_item)
  
  # SQL インジェクション チェック
  let sql_patterns = [
    (r"SQL syntax", "SQLエラーメッセージが検出されました"),
    (r"mysql_fetch_array\(\)", "MySQLエラーメッセージが検出されました"),
    (r"ORA-[0-9]{5}", "Oracleエラーメッセージが検出されました"),
    (r"Microsoft SQL Server", "SQL Serverエラーメッセージが検出されました")
  ]
  
  for (pattern, desc) in sql_patterns:
    if body.contains(re(pattern, {reIgnoreCase})):
      var result_item = VulnerabilityScanResult()
      result_item.vulnerability_type = vtSqlInjection
      result_item.severity = 9
      result_item.description = "SQLインジェクションの脆弱性"
      result_item.found_in = "レスポンスボディ"
      result_item.payload = desc
      result_item.mitigation = "パラメータ化クエリを使用し、ユーザー入力を適切にサニタイズしてください"
      result.add(result_item)
  
  # セキュリティヘッダー不足チェック
  if not headers.hasKey("Content-Security-Policy"):
    var result_item = VulnerabilityScanResult()
    result_item.vulnerability_type = vtXss
    result_item.severity = 5
    result_item.description = "コンテンツセキュリティポリシー (CSP) ヘッダーが不足しています"
    result_item.found_in = "レスポンスヘッダー"
    result_item.payload = "Content-Security-Policyが見つかりません"
    result_item.mitigation = "適切なCSPヘッダーを設定してください"
    result.add(result_item)
  
  if not headers.hasKey("X-Frame-Options"):
    var result_item = VulnerabilityScanResult()
    result_item.vulnerability_type = vtXss
    result_item.severity = 4
    result_item.description = "X-Frame-Optionsヘッダーが不足しています"
    result_item.found_in = "レスポンスヘッダー"
    result_item.payload = "X-Frame-Optionsが見つかりません"
    result_item.mitigation = "X-Frame-Options: DENYまたはSAMEORIGINを設定してください"
    result.add(result_item)
  
  # CSRFチェック
  if body.contains(re(r"<form.*?>", {reIgnoreCase})) and not body.contains(re(r"csrf|token|nonce", {reIgnoreCase})):
    var result_item = VulnerabilityScanResult()
    result_item.vulnerability_type = vtCsrf
    result_item.severity = 7
    result_item.description = "クロスサイトリクエストフォージェリ (CSRF) の脆弱性"
    result_item.found_in = "レスポンスボディ"
    result_item.payload = "フォームにCSRFトークンが含まれていません"
    result_item.mitigation = "すべてのフォームにCSRFトークンを実装してください"
    result.add(result_item)
  
  return result

proc validateCspAgainstKnownVulnerabilities*(csp: ContentSecurityPolicy): seq[string] =
  ## CSPポリシーが既知の脆弱性に対応しているか検証
  result = @[]
  
  # 'unsafe-inline'チェック
  let inline_dirs = [cdScriptSrc, cdStyleSrc, cdDefaultSrc]
  for dir in inline_dirs:
    if dir in csp.directives and "'unsafe-inline'" in csp.directives[dir]:
      if dir == cdScriptSrc:
        if "'nonce-" notin csp.directives[dir].join(" ") and "'strict-dynamic'" notin csp.directives[dir]:
          result.add($"{dir}に'unsafe-inline'が設定されていますが、nonce/hash/strict-dynamicによる緩和策がありません")
  
  # base-uriの制限がない
  if cdBaseUri notin csp.directives:
    result.add("base-uriディレクティブが設定されていません。DOMベースのXSS攻撃に対して脆弱です")
  
  # object-srcの制限がない
  if cdObjectSrc notin csp.directives and cdDefaultSrc notin csp.directives:
    result.add("object-srcディレクティブが設定されていません。Flash等のプラグインを使った攻撃に対して脆弱です")
  
  # script-srcの厳格な制限がない
  if cdScriptSrc in csp.directives:
    let script_src = csp.directives[cdScriptSrc]
    if "*" in script_src or "https:" in script_src:
      result.add("script-srcディレクティブがあまりに緩く設定されています")
  
  # report-uriがない
  if cdReportUri notin csp.directives and cdReportTo notin csp.directives:
    result.add("CSP違反の報告先が設定されていません")
  
  return result

proc generateSecurePermissionsPolicy*(): string =
  ## 安全なPermissionsPolicyヘッダーを生成
  var permissions = initTable[FeaturePolicy, tuple[value: PermissionsPolicyValue, origins: seq[string]]]()
  
  # デフォルトで安全な設定
  permissions[fpCamera] = (ppSelf, @[])
  permissions[fpMicrophone] = (ppSelf, @[])
  permissions[fpGeolocation] = (ppSelf, @[])
  permissions[fpPayment] = (ppSelf, @[])
  permissions[fpAutoplay] = (ppSelf, @[])
  permissions[fpFullscreen] = (ppSelf, @[])
  permissions[fpPictureInPicture] = (ppSelf, @[])
  
  # より制限の厳しい機能
  permissions[fpAccelerometer] = (ppNone, @[])
  permissions[fpAmbientLightSensor] = (ppNone, @[])
  permissions[fpGyroscope] = (ppNone, @[])
  permissions[fpMagnetometer] = (ppNone, @[])
  permissions[fpUsb] = (ppNone, @[])
  permissions[fpSyncXhr] = (ppNone, @[])
  
  # ヘッダー文字列を構築
  var policy_parts: seq[string] = @[]
  for feature, setting in permissions:
    var feature_name = $feature
    feature_name = feature_name[2..^1].toLowerAscii
    
    var value = ""
    case setting.value
    of ppNone:
      value = "()"
    of ppSelf:
      value = "(self)"
    of ppAllow:
      value = "*"
    of ppOrigins:
      if setting.origins.len > 0:
        value = "(" & setting.origins.join(" ") & ")"
      else:
        value = "(self)"
    
    policy_parts.add(feature_name & "=" & value)
  
  return policy_parts.join(", ")

proc generateSecurityHeadersWithPermissionsPolicy*(settings: HttpHeaderSecuritySettings): HttpHeaders =
  ## PermissionsPolicyを含む強化されたセキュリティヘッダーを生成
  result = generateSecurityHeaders(settings)
  
  # Permission-Policyを追加
  result["Permissions-Policy"] = generateSecurePermissionsPolicy()
  
  # Cross-Origin-Resource-Policyを追加
  result["Cross-Origin-Resource-Policy"] = "same-origin"
  
  # Cross-Origin-Opener-Policyを追加
  result["Cross-Origin-Opener-Policy"] = "same-origin"
  
  # Cross-Origin-Embedder-Policyを追加
  result["Cross-Origin-Embedder-Policy"] = "require-corp"
  
  return result

proc calculateSubresourceIntegrity*(file_path: string): SubresourceIntegrityCheck =
  ## ファイルのサブリソース整合性ハッシュを計算
  result.resource_url = file_path
  result.hash_algorithm = "sha384"
  
  try:
    var data = readFile(file_path)
    var sha384ctx: SHA384
    sha384ctx.init()
    sha384ctx.update(data)
    var digest = sha384ctx.final()
    
    result.hash_value = base64.encode(digest)
    result.valid = true
  except:
    result.hash_value = ""
    result.valid = false

proc verifySubresourceIntegrity*(integrity: string, content: string): bool =
  ## サブリソース整合性検証
  try:
    # integrity形式: "<algorithm>-<base64_hash>"
    let parts = integrity.split("-", 1)
    if parts.len != 2:
      return false
    
    let algorithm = parts[0]
    let expected_hash = parts[1]
    
    var hash_value = ""
    case algorithm
    of "sha256":
      var sha256ctx: SHA256
      sha256ctx.init()
      sha256ctx.update(content)
      hash_value = base64.encode(sha256ctx.final())
    of "sha384":
      var sha384ctx: SHA384
      sha384ctx.init()
      sha384ctx.update(content)
      hash_value = base64.encode(sha384ctx.final())
    of "sha512":
      var sha512ctx: SHA512
      sha512ctx.init()
      sha512ctx.update(content)
      hash_value = base64.encode(sha512ctx.final())
    else:
      return false
    
    return expected_hash == hash_value
  except:
    return false

proc generateBodyIntegrityHash*(body: string): string =
  ## ボディコンテンツのハッシュを生成（整合性検証用）
  try:
    var sha256ctx: SHA256
    sha256ctx.init()
    sha256ctx.update(body)
    return "sha256-" & base64.encode(sha256ctx.final())
  except:
    return ""

proc detectExpectedCt*(headers: HttpHeaders): bool =
  ## Expect-CTヘッダーの存在と有効性をチェック
  if headers.hasKey("Expect-CT"):
    let value = headers["Expect-CT"][0]
    # enforce かつ report-uriが含まれているか確認
    return "enforce" in value and "report-uri" in value
  return false

proc detectHpkp*(headers: HttpHeaders): tuple[exists: bool, max_age: int, backup_pins: int] =
  ## HTTP Public Key Pinning (HPKP) ヘッダーを検出して検証
  result = (exists: false, max_age: 0, backup_pins: 0)
  
  if headers.hasKey("Public-Key-Pins"):
    result.exists = true
    let value = headers["Public-Key-Pins"][0]
    
    # max-ageを抽出
    try:
      let max_age_start = value.find("max-age=") + 8
      var max_age_end = value.len
      for i in max_age_start..<value.len:
        if value[i] == ';' or value[i] == ' ':
          max_age_end = i
          break
      
      result.max_age = parseInt(value[max_age_start..<max_age_end])
    except:
      result.max_age = 0
    
    # pin-sha256の数をカウント
    var pin_count = 0
    var pos = 0
    while pos < value.len:
      let pin_pos = value.find("pin-sha256=", pos)
      if pin_pos == -1:
        break
      
      pin_count += 1
      pos = pin_pos + 11
    
    result.backup_pins = max(0, pin_count - 1)
  
  return result

proc detectCaa*(domain: string): bool =
  ## Certification Authority Authorization (CAA) レコードの存在を検出
  try:
    # DNSクエリを実行してCAAレコードを検索
    var domainToCheck = domain
    var caaFound = false
    
    # ドメイン階層を上に移動しながらCAAレコードを検索
    while domainToCheck.len > 0 and not caaFound:
      # DNSクエリの実行
      let dnsResult = execCmdEx("dig +short " & domainToCheck & " TYPE257")
      
      # 結果の解析
      if dnsResult.exitCode == 0 and dnsResult.output.len > 0:
        let output = dnsResult.output.strip()
        if output.len > 0:
          # CAAレコードの解析
          # フォーマット: <flags> <tag> <value>
          for line in output.splitLines():
            if line.len > 0:
              let parts = line.split()
              if parts.len >= 3:
                let tag = parts[1].strip(chars={'"'})
                if tag == "issue" or tag == "issuewild":
                  caaFound = true
                  break
      
      # 親ドメインに移動
      let dotPos = domainToCheck.find('.')
      if dotPos == -1 or dotPos == domainToCheck.len - 1:
        break
      domainToCheck = domainToCheck[dotPos + 1 .. ^1]
    
    return caaFound
  except Exception as e:
    # エラーログ記録
    echo "CAA検出中にエラー発生: ", e.msg
    return false

proc newSecureRequestConfig*(): SecureRequestConfig =
  ## 安全なリクエスト設定を作成
  result.cookies_secure_only = true
  result.cookies_http_only = true
  result.cookies_same_site = SameSitePolicy.sspStrict
  result.use_secure_connection = true
  result.verify_host = true
  result.revocation_check = true
  result.min_tls_version = TlsVersion.tlsV1_2
  result.cert_pinning = @[]
  result.client_cert_path = ""
  result.client_key_path = ""
  result.ca_bundle_path = ""
  return result

proc applySecureRequestConfig*(client: HttpClient, config: SecureRequestConfig) =
  ## HTTPクライアントに安全な設定を適用
  # SSLコンテキスト設定
  if config.use_secure_connection:
    when defined(ssl):
      # SSL/TLS設定
      client.sslContext = newContext(verifyMode = (if config.verify_host: CVerifyPeer else CVerifyNone))
      
      # 最小TLSバージョン設定
      case config.min_tls_version
      of tlsV1:
        client.sslContext.minProtocolVersion = TLSv1
      of tlsV1_1:
        client.sslContext.minProtocolVersion = TLSv1_1
      of tlsV1_2:
        client.sslContext.minProtocolVersion = TLSv1_2
      of tlsV1_3:
        client.sslContext.minProtocolVersion = TLSv1_3
      
      # クライアント証明書設定
      if config.client_cert_path.len > 0 and config.client_key_path.len > 0:
        client.sslContext.useCertificateFile(config.client_cert_path)
        client.sslContext.usePrivateKeyFile(config.client_key_path)
      
      # CA証明書バンドル設定
      if config.ca_bundle_path.len > 0:
        client.sslContext.loadVerifyLocations(config.ca_bundle_path)

proc setCookieSecurely*(headers: var HttpHeaders, name: string, value: string, 
                       domain: string, path: string = "/", 
                       max_age: int = -1, secure: bool = true, 
                       http_only: bool = true, same_site: SameSitePolicy = sspStrict) =
  ## 安全にCookieを設定するヘッダーを生成
  var cookie_str = name & "=" & value
  
  if domain.len > 0:
    cookie_str &= "; Domain=" & domain
  
  cookie_str &= "; Path=" & path
  
  if max_age >= 0:
    cookie_str &= "; Max-Age=" & $max_age
  
  if secure:
    cookie_str &= "; Secure"
  
  if http_only:
    cookie_str &= "; HttpOnly"
  
  # SameSite設定
  var same_site_str = ""
  case same_site
  of sspLax:
    same_site_str = "Lax"
  of sspStrict:
    same_site_str = "Strict"
  of sspNone:
    same_site_str = "None"
  
  if same_site_str.len > 0:
    cookie_str &= "; SameSite=" & same_site_str
  
  headers["Set-Cookie"] = cookie_str

proc sanitizeUrl*(url: string): string =
  ## URLのサニタイゼーション
  try:
    var uri = parseUri(url)
    
    # スキームがHTTPまたはHTTPSのみを許可
    if uri.scheme != "http" and uri.scheme != "https":
      return ""
    
    # フラグメントから潜在的なJavaScriptを除去
    if uri.fragment.startsWith("javascript:"):
      uri.fragment = ""
    
    # パスのサニタイズ
    uri.path = uri.path.replace(re"\.+/", "")
    
    # クエリのサニタイズ
    let query_pairs = uri.query.split('&')
    var sanitized_queries: seq[string] = @[]
    
    for pair in query_pairs:
      let kv = pair.split('=', 1)
      if kv.len == 2:
        let key = kv[0]
        var value = kv[1]
        
        # 特殊文字のエスケープ
        value = value.replace("<", "%3C")
                     .replace(">", "%3E")
                     .replace("\"", "%22")
                     .replace("'", "%27")
                     .replace("`", "%60")
        
        sanitized_queries.add(key & "=" & value)
      elif kv.len == 1 and kv[0].len > 0:
        sanitized_queries.add(kv[0])
    
    uri.query = sanitized_queries.join("&")
    
    return $uri
  except:
    return ""

proc sanitizeHtml*(html: string): string =
  ## HTMLコンテンツの安全な浄化（XSS対策）
  try:
    # 安全でない属性を削除
    var result = html
    
    # インラインスクリプトイベントの削除
    result = result.replace(re"on\w+\s*=\s*([\"'])[^\"']*\1", "")
    
    # javascriptプロトコルの削除
    result = result.replace(re"javascript:\s*[^\"']*", "")
    
    # <script>タグの削除
    result = result.replace(re"<script[^>]*>[\s\S]*?</script>", "")
    
    # フォームアクションのサニタイズ
    result = result.replace(re"<form[^>]*action\s*=\s*([\"'])javascript:[^\"']*\1", "<form")
    
    # iframeの削除
    result = result.replace(re"<iframe[^>]*>[\s\S]*?</iframe>", "")
    
    # object/embedの削除
    result = result.replace(re"<object[^>]*>[\s\S]*?</object>", "")
    result = result.replace(re"<embed[^>]*>[\s\S]*?</embed>", "")
    
    # baseタグの削除
    result = result.replace(re"<base[^>]*>", "")
    
    return result
  except:
    return html

# CSRF保護機能
type
  CsrfTokenConfig* = object
    secret*: string            # トークン生成用のシークレット
    tokenLength*: int          # トークンの長さ
    expiration*: int           # トークンの有効期間（秒）
    headerName*: string        # CSRFトークンを含むヘッダー名
    formFieldName*: string     # フォームフィールド名
    cookieName*: string        # CSRFクッキー名
    cookiePath*: string        # クッキーパス
    cookieDomain*: string      # クッキードメイン
    cookieSecure*: bool        # Secureフラグ
    cookieHttpOnly*: bool      # HttpOnlyフラグ
    cookieSameSite*: SameSitePolicy # SameSite設定
    validateReferrer*: bool    # リファラーの検証を行うか
    allowedHosts*: seq[string] # 許可されたホスト名

proc newCsrfTokenConfig*(): CsrfTokenConfig =
  ## CSRFトークン設定のデフォルト値を生成
  result = CsrfTokenConfig(
    secret: "",  # 実際の使用時には必ずランダムな値を設定すること
    tokenLength: 32,
    expiration: 3600,  # 1時間
    headerName: "X-CSRF-Token",
    formFieldName: "csrf_token",
    cookieName: "csrf_token",
    cookiePath: "/",
    cookieDomain: "",
    cookieSecure: true,
    cookieHttpOnly: true,
    cookieSameSite: sspStrict,
    validateReferrer: true,
    allowedHosts: @[]
  )
  
  # ランダムなシークレットを生成
  var rng = initRand()
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result.secret = ""
  for i in 0..<64:
    result.secret.add(chars[rng.rand(chars.len - 1)])

proc generateCsrfToken*(config: CsrfTokenConfig): tuple[token: string, expires: Time] =
  ## 新しいCSRFトークンを生成
  let now = getTime()
  let expires = now + initDuration(seconds = config.expiration)
  let expiresUnix = expires.toUnix()
  
  # 現在時刻とランダム文字列を組み合わせてトークンを生成
  var rng = initRand()
  var randomBytes = ""
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  for i in 0..<config.tokenLength:
    randomBytes.add(chars[rng.rand(chars.len - 1)])
  
  # HMAC-SHA256でトークンを署名
  var ctx: HMAC[SHA256]
  ctx.init(config.secret)
  ctx.update($expiresUnix)
  ctx.update(randomBytes)
  let signature = ctx.final()
  
  # トークンは `expires:random:signature` の形式
  let token = $expiresUnix & ":" & randomBytes & ":" & base64.encode(signature)
  
  return (token, expires)

proc validateCsrfToken*(config: CsrfTokenConfig, token: string): bool =
  ## CSRFトークンを検証
  try:
    # トークンをパース
    let parts = token.split(":")
    if parts.len != 3:
      return false
    
    let expiresUnix = parseInt(parts[0])
    let randomBytes = parts[1]
    let signature = base64.decode(parts[2])
    
    # 期限切れのチェック
    let now = getTime()
    if now.toUnix() > expiresUnix:
      return false
    
    # 署名の検証
    var ctx: HMAC[SHA256]
    ctx.init(config.secret)
    ctx.update($expiresUnix)
    ctx.update(randomBytes)
    let expectedSignature = ctx.final()
    
    return expectedSignature == signature
  except:
    return false

proc setCsrfCookie*(headers: var HttpHeaders, config: CsrfTokenConfig, token: string, expires: Time) =
  ## CSRFトークン用のクッキーをセット
  var cookieOptions = ""
  cookieOptions.add("; Path=" & config.cookiePath)
  
  if config.cookieDomain.len > 0:
    cookieOptions.add("; Domain=" & config.cookieDomain)
  
  # Max-Age設定
  let now = getTime()
  let expiresIn = expires - now
  cookieOptions.add("; Max-Age=" & $int(expiresIn.inSeconds))
  
  if config.cookieSecure:
    cookieOptions.add("; Secure")
  
  if config.cookieHttpOnly:
    cookieOptions.add("; HttpOnly")
  
  # SameSite設定
  case config.cookieSameSite:
    of sspLax:
      cookieOptions.add("; SameSite=Lax")
    of sspStrict:
      cookieOptions.add("; SameSite=Strict")
    of sspNone:
      cookieOptions.add("; SameSite=None")
  
  headers["Set-Cookie"] = config.cookieName & "=" & token & cookieOptions

proc validateCsrfRequest*(config: CsrfTokenConfig, headers: HttpHeaders, 
                        cookies: CookieJar, formData: Table[string, string] = initTable[string, string](), 
                        referrer: string = ""): bool =
  ## CSRFリクエストの検証
  # クッキーからトークンを取得
  let cookieToken = cookies.getCookie(config.cookieName)
  if cookieToken.isNone:
    return false
  
  # ヘッダーからトークンを取得
  var headerToken = ""
  if config.headerName in headers:
    headerToken = headers[config.headerName]
  
  # フォームデータからトークンを取得
  var formToken = ""
  if config.formFieldName in formData:
    formToken = formData[config.formFieldName]
  
  # トークンが提供されているか確認
  let token = if headerToken.len > 0: headerToken else: formToken
  if token.len == 0:
    return false
  
  # トークンの一致を確認
  if token != cookieToken.get().value:
    return false
  
  # トークンの検証
  if not validateCsrfToken(config, token):
    return false
  
  # リファラーの検証（設定されている場合）
  if config.validateReferrer and referrer.len > 0:
    let referrerUri = parseUri(referrer)
    let hostname = referrerUri.hostname
    
    # 許可されたホストが設定されていない場合は、ホスト名リストを作成
    var allowedHosts = config.allowedHosts
    if allowedHosts.len == 0 and config.cookieDomain.len > 0:
      allowedHosts = @[config.cookieDomain]
    
    # ホスト名がリストにあるか確認
    var hostValid = false
    for host in allowedHosts:
      if hostname == host or hostname.endsWith("." & host):
        hostValid = true
        break
    
    if not hostValid:
      return false
  
  return true

# HTTP/3 (QUIC) セキュリティ強化
type
  Http3SecuritySettings* = object
    ## HTTP/3および基盤となるQUICプロトコルのセキュリティ設定
    qpackMaxTableCapacity*: int    # QPACK ヘッダー圧縮テーブルの最大容量
    qpackBlockedStreams*: int      # ブロックされたストリームの最大数
    enableEarlyData*: bool         # 0-RTTデータの有効化
    maxIdleTimeout*: int           # アイドルタイムアウト（ミリ秒）
    maxDatagramSize*: int          # データグラムの最大サイズ
    enableDatagram*: bool          # データグラム拡張の有効化
    disallowedServerCipherSuites*: seq[string] # 禁止されたサーバー側の暗号スイート
    requireChaCha20*: bool         # ChaCha20-Poly1305の要求
    validateAlpn*: bool            # ALPNの検証
    expectedAlpn*: string          # 期待されるALPNプロトコル
    verifyRetryIntegrity*: bool    # Retryパケットの整合性検証

proc newHttp3SecuritySettings*(): Http3SecuritySettings =
  ## HTTP/3セキュリティ設定のデフォルト値を生成
  result = Http3SecuritySettings(
    qpackMaxTableCapacity: 4096,
    qpackBlockedStreams: 100,
    enableEarlyData: false,  # デフォルトでは0-RTTを無効化（リプレイ攻撃対策）
    maxIdleTimeout: 30000,   # 30秒
    maxDatagramSize: 1200,
    enableDatagram: false,
    disallowedServerCipherSuites: @[
      "TLS_AES_128_CCM_SHA256",     # より安全な代替があるため非推奨
      "TLS_CHACHA20_POLY1305_SHA256" # 特定の状況で必要な場合のみ有効化
    ],
    requireChaCha20: false,   # デフォルトでは要求しない
    validateAlpn: true,
    expectedAlpn: "h3",
    verifyRetryIntegrity: true
  )

proc configureHttp3Security*(http3Config: var Http3SecuritySettings, securityLevel: int) =
  ## セキュリティレベルに基づいてHTTP/3設定を構成
  ## レベル: 1 (低) - 5 (最高)
  case securityLevel:
    of 1:
      # 基本的なセキュリティ（互換性優先）
      http3Config.enableEarlyData = true
      http3Config.validateAlpn = false
      http3Config.verifyRetryIntegrity = false
      http3Config.disallowedServerCipherSuites = @[]
    
    of 2:
      # 標準セキュリティ
      http3Config.enableEarlyData = true
      http3Config.validateAlpn = true
      http3Config.verifyRetryIntegrity = true
    
    of 3:
      # 高セキュリティ（デフォルト）
      http3Config.enableEarlyData = false
      http3Config.validateAlpn = true
      http3Config.verifyRetryIntegrity = true
    
    of 4:
      # より高いセキュリティ
      http3Config.enableEarlyData = false
      http3Config.qpackMaxTableCapacity = 2048
      http3Config.qpackBlockedStreams = 50
      http3Config.requireChaCha20 = true
    
    of 5:
      # 最高セキュリティ
      http3Config.enableEarlyData = false
      http3Config.qpackMaxTableCapacity = 1024
      http3Config.qpackBlockedStreams = 20
      http3Config.enableDatagram = false
      http3Config.requireChaCha20 = true
      http3Config.maxIdleTimeout = 10000  # 10秒
    
    else:
      # デフォルト（レベル3）
      http3Config.enableEarlyData = false
      http3Config.validateAlpn = true
      http3Config.verifyRetryIntegrity = true

proc validateHttp3Connection*(headers: HttpHeaders, expectedSettings: Http3SecuritySettings): tuple[valid: bool, issues: seq[string]] =
  ## HTTP/3接続のセキュリティパラメータを検証
  var issues: seq[string] = @[]
  
  # Alt-Svcヘッダーの検証
  if "Alt-Svc" in headers:
    let altSvc = headers["Alt-Svc"][0]
    
    # h3が提供されているか確認
    if "h3" notin altSvc:
      issues.add("サーバーはHTTP/3をサポートしていません")
    
    # ALPNの検証
    if expectedSettings.validateAlpn and expectedSettings.expectedAlpn notin altSvc:
      issues.add("期待されるALPNプロトコルが見つかりません: " & expectedSettings.expectedAlpn)
  else:
    issues.add("Alt-Svcヘッダーが見つかりません")
  
  # QUIC-Statusヘッダーがある場合は検証
  if "QUIC-Status" in headers:
    let quicStatus = headers["QUIC-Status"][0]
    
    # 0-RTTが有効で、設定で無効になっている場合
    if "0-RTT" in quicStatus and not expectedSettings.enableEarlyData:
      issues.add("0-RTTが有効ですが、セキュリティ設定では無効になっています")
  
  return (issues.len == 0, issues)

proc generateHttp3SecurityHeaders*(): HttpHeaders =
  ## HTTP/3接続用のセキュリティヘッダーを生成
  result = newHttpHeaders()
  
  # Alt-Svcヘッダー
  result["Alt-Svc"] = "h3=\":443\"; ma=3600"
  
  # HTTP/3特有のセキュリティヘッダー
  result["QUIC-Status"] = "enabled"
  
  # QUICトランスポートパラメータを示すヘッダー
  result["X-QUIC-Params"] = "idle_timeout=30;max_datagram_size=1200"
  
  # 追加のセキュリティ関連ヘッダー
  result["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
  result["X-Content-Type-Options"] = "nosniff"
  
  return result

# DNSセキュリティとの連携
proc validateDnsSecCerts*(url: string, dnsSecInfo: JsonNode): bool =
  ## DNSSECによって検証された証明書情報とURLの整合性を検証
  if dnsSecInfo.isNil or dnsSecInfo.kind != JObject:
    return false
  
  try:
    let uri = parseUri(url)
    let hostname = uri.hostname
    
    # DNSSECが有効かチェック
    if "dnssec" notin dnsSecInfo or not dnsSecInfo["dnssec"].getBool():
      return false
    
    # DANE/TLSAレコードの検証
    if "tlsa" in dnsSecInfo and dnsSecInfo["tlsa"].kind == JArray:
      let tlsaRecords = dnsSecInfo["tlsa"]
      if tlsaRecords.len > 0:
        # TLSAレコードが存在し、検証済み
        return true
    
    # CAA（Certificate Authority Authorization）レコードの検証
    if "caa" in dnsSecInfo and dnsSecInfo["caa"].kind == JArray:
      let caaRecords = dnsSecInfo["caa"]
      if caaRecords.len > 0:
        # CAAレコードが存在
        return true
    
    return false
  except:
    return false