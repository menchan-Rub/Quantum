import std/[tables, sets]

# 一般的なHTTPヘッダー名
const
  ContentTypeHeader* = "content-type"
  ContentLengthHeader* = "content-length"
  ContentEncodingHeader* = "content-encoding"
  ContentRangeHeader* = "content-range"
  ContentDispositionHeader* = "content-disposition"
  ContentLanguageHeader* = "content-language"
  ContentLocationHeader* = "content-location"
  ContentSecurityPolicyHeader* = "content-security-policy"
  
  AcceptHeader* = "accept"
  AcceptEncodingHeader* = "accept-encoding"
  AcceptLanguageHeader* = "accept-language"
  AcceptRangesHeader* = "accept-ranges"
  AcceptCharsetHeader* = "accept-charset"
  
  AuthorizationHeader* = "authorization"
  WwwAuthenticateHeader* = "www-authenticate"
  ProxyAuthenticateHeader* = "proxy-authenticate"
  ProxyAuthorizationHeader* = "proxy-authorization"
  
  CacheControlHeader* = "cache-control"
  PragmaHeader* = "pragma"
  ExpiresHeader* = "expires"
  EtagHeader* = "etag"
  IfMatchHeader* = "if-match"
  IfNoneMatchHeader* = "if-none-match"
  IfModifiedSinceHeader* = "if-modified-since"
  IfUnmodifiedSinceHeader* = "if-unmodified-since"
  LastModifiedHeader* = "last-modified"
  
  CookieHeader* = "cookie"
  SetCookieHeader* = "set-cookie"
  
  HostHeader* = "host"
  UserAgentHeader* = "user-agent"
  RefererHeader* = "referer"
  ReferrerPolicyHeader* = "referrer-policy"
  ServerHeader* = "server"
  
  LocationHeader* = "location"
  
  ConnectionHeader* = "connection"
  KeepAliveHeader* = "keep-alive"
  UpgradeHeader* = "upgrade"
  
  TransferEncodingHeader* = "transfer-encoding"
  TeHeader* = "te"
  TrailerHeader* = "trailer"
  
  DateHeader* = "date"
  AgeHeader* = "age"
  RetryAfterHeader* = "retry-after"
  
  AllowHeader* = "allow"
  VaryHeader* = "vary"
  
  RangeHeader* = "range"
  
  ForwardedHeader* = "forwarded"
  XForwardedForHeader* = "x-forwarded-for"
  XForwardedHostHeader* = "x-forwarded-host"
  XForwardedProtoHeader* = "x-forwarded-proto"
  
  StrictTransportSecurityHeader* = "strict-transport-security"
  XContentTypeOptionsHeader* = "x-content-type-options"
  XFrameOptionsHeader* = "x-frame-options"
  XssProtectionHeader* = "x-xss-protection"

# セキュリティ関連のヘッダー一覧
let SecurityHeaders* = [
  ContentSecurityPolicyHeader,
  StrictTransportSecurityHeader,
  XContentTypeOptionsHeader,
  XFrameOptionsHeader,
  XssProtectionHeader,
  ReferrerPolicyHeader
].toHashSet

# Hop-by-hopヘッダー（中継で削除されるべきヘッダー）
let HopByHopHeaders* = [
  ConnectionHeader,
  KeepAliveHeader,
  ProxyAuthenticateHeader,
  ProxyAuthorizationHeader,
  TeHeader,
  TrailerHeader,
  TransferEncodingHeader,
  UpgradeHeader
].toHashSet

# リクエストでのみ有効なヘッダー
let RequestOnlyHeaders* = [
  AcceptHeader,
  AcceptEncodingHeader,
  AcceptLanguageHeader,
  AcceptCharsetHeader,
  AuthorizationHeader,
  CookieHeader,
  ExpectHeader,
  HostHeader,
  IfMatchHeader,
  IfModifiedSinceHeader,
  IfNoneMatchHeader,
  IfRangeHeader,
  IfUnmodifiedSinceHeader,
  ProxyAuthorizationHeader,
  RangeHeader,
  RefererHeader,
  UserAgentHeader
].toHashSet

# レスポンスでのみ有効なヘッダー
let ResponseOnlyHeaders* = [
  AcceptRangesHeader,
  AgeHeader,
  EtagHeader,
  LocationHeader,
  ProxyAuthenticateHeader,
  RetryAfterHeader,
  ServerHeader,
  SetCookieHeader,
  VaryHeader,
  WwwAuthenticateHeader
].toHashSet

# 一般的なContent-Type値
const
  ContentTypeTextPlain* = "text/plain"
  ContentTypeTextHtml* = "text/html"
  ContentTypeTextCss* = "text/css"
  ContentTypeTextJavascript* = "text/javascript"
  ContentTypeApplicationJson* = "application/json"
  ContentTypeApplicationXml* = "application/xml"
  ContentTypeApplicationFormUrlencoded* = "application/x-www-form-urlencoded"
  ContentTypeMultipartFormData* = "multipart/form-data"
  ContentTypeApplicationOctetStream* = "application/octet-stream"
  ContentTypeImageJpeg* = "image/jpeg"
  ContentTypeImagePng* = "image/png"
  ContentTypeImageGif* = "image/gif"
  ContentTypeImageWebp* = "image/webp"
  ContentTypeImageSvgXml* = "image/svg+xml"
  ContentTypeAudioMpeg* = "audio/mpeg"
  ContentTypeAudioOgg* = "audio/ogg"
  ContentTypeVideoMp4* = "video/mp4"
  ContentTypeVideoWebm* = "video/webm"

# ファイル拡張子とContent-Typeのマッピング
let FileExtToContentType* = {
  ".txt": ContentTypeTextPlain,
  ".html": ContentTypeTextHtml,
  ".htm": ContentTypeTextHtml,
  ".css": ContentTypeTextCss,
  ".js": ContentTypeTextJavascript,
  ".json": ContentTypeApplicationJson,
  ".xml": ContentTypeApplicationXml,
  ".jpg": ContentTypeImageJpeg,
  ".jpeg": ContentTypeImageJpeg,
  ".png": ContentTypeImagePng,
  ".gif": ContentTypeImageGif,
  ".webp": ContentTypeImageWebp,
  ".svg": ContentTypeImageSvgXml,
  ".mp3": ContentTypeAudioMpeg,
  ".ogg": ContentTypeAudioOgg,
  ".mp4": ContentTypeVideoMp4,
  ".webm": ContentTypeVideoWebm,
  ".bin": ContentTypeApplicationOctetStream,
  ".pdf": "application/pdf",
  ".zip": "application/zip",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".eot": "application/vnd.ms-fontobject"
}.toTable

# 一般的なContent-Encodingの値
const
  ContentEncodingGzip* = "gzip"
  ContentEncodingDeflate* = "deflate"
  ContentEncodingBr* = "br"
  ContentEncodingIdentity* = "identity"

# Cache-Controlディレクティブ
const
  CacheControlNoCache* = "no-cache"
  CacheControlNoStore* = "no-store"
  CacheControlMaxAge* = "max-age"
  CacheControlMaxStale* = "max-stale"
  CacheControlMinFresh* = "min-fresh"
  CacheControlMustRevalidate* = "must-revalidate"
  CacheControlNoTransform* = "no-transform"
  CacheControlOnlyIfCached* = "only-if-cached"
  CacheControlPublic* = "public"
  CacheControlPrivate* = "private"
  CacheControlProxyRevalidate* = "proxy-revalidate"
  CacheControlSMaxAge* = "s-maxage"
  CacheControlImmutable* = "immutable"
  CacheControlStaleWhileRevalidate* = "stale-while-revalidate"
  CacheControlStaleIfError* = "stale-if-error"

# Content Security Policyディレクティブ
const
  CspDefaultSrc* = "default-src"
  CspScriptSrc* = "script-src"
  CspStyleSrc* = "style-src"
  CspImgSrc* = "img-src"
  CspConnectSrc* = "connect-src"
  CspFontSrc* = "font-src"
  CspObjectSrc* = "object-src"
  CspMediaSrc* = "media-src"
  CspFrameSrc* = "frame-src"
  CspFrameAncestors* = "frame-ancestors"
  CspFormAction* = "form-action"
  CspBaseUri* = "base-uri"
  CspChildSrc* = "child-src"
  CspWorkerSrc* = "worker-src"
  CspManifestSrc* = "manifest-src"
  CspPrefetchSrc* = "prefetch-src"
  CspNavigateTo* = "navigate-to"
  CspReportUri* = "report-uri"
  CspReportTo* = "report-to"
  CspSandbox* = "sandbox"
  CspUpgradeInsecureRequests* = "upgrade-insecure-requests"
  CspBlockAllMixedContent* = "block-all-mixed-content"
  CspRequireSriFor* = "require-sri-for"
  CspTrustedTypes* = "trusted-types"

# CSPソース値
const
  CspSelf* = "'self'"
  CspUnsafeInline* = "'unsafe-inline'"
  CspUnsafeEval* = "'unsafe-eval'"
  CspNone* = "'none'"
  CspStrictDynamic* = "'strict-dynamic'"
  CspReportSample* = "'report-sample'"
  CspWasmUnsafeEval* = "'wasm-unsafe-eval'"
  CspHttps* = "https:"
  CspData* = "data:"
  CspMediaStream* = "mediastream:"
  CspBlob* = "blob:"
  CspFileSystem* = "filesystem:"

# X-Frame-Optionsの値
const
  XFrameOptionsDeny* = "deny"
  XFrameOptionsSameOrigin* = "sameorigin"
  XFrameOptionsAllowFrom* = "allow-from"

# X-Content-Type-Optionsの値
const
  XContentTypeOptionsNosniff* = "nosniff"

# X-XSS-Protectionの値
const
  XssProtectionDisabled* = "0"
  XssProtectionEnabled* = "1"
  XssProtectionEnabledBlock* = "1; mode=block"
  XssProtectionEnabledReport* = "1; report="

# Referrer-Policyの値
const
  ReferrerPolicyNoReferrer* = "no-referrer"
  ReferrerPolicyNoReferrerWhenDowngrade* = "no-referrer-when-downgrade"
  ReferrerPolicySameOrigin* = "same-origin"
  ReferrerPolicyOrigin* = "origin"
  ReferrerPolicyStrictOrigin* = "strict-origin"
  ReferrerPolicyOriginWhenCrossOrigin* = "origin-when-cross-origin"
  ReferrerPolicyStrictOriginWhenCrossOrigin* = "strict-origin-when-cross-origin"
  ReferrerPolicyUnsafeUrl* = "unsafe-url"

# Transfer-Encodingの値
const
  TransferEncodingChunked* = "chunked"
  TransferEncodingCompress* = "compress"
  TransferEncodingDeflate* = "deflate"
  TransferEncodingGzip* = "gzip"
  TransferEncodingIdentity* = "identity"

# Connectionの値
const
  ConnectionClose* = "close"
  ConnectionKeepAlive* = "keep-alive"
  ConnectionUpgrade* = "upgrade"

# コンテンツ文字セット
const
  CharsetUtf8* = "utf-8"
  CharsetIso88591* = "iso-8859-1"
  CharsetUsAscii* = "us-ascii"
  CharsetUtf16* = "utf-16"
  CharsetWindows1252* = "windows-1252"

# 特殊なヘッダー値
const
  ExpectHeader* = "expect"
  Expect100Continue* = "100-continue"
  
  IfRangeHeader* = "if-range"
  
  AccessControlAllowOriginHeader* = "access-control-allow-origin"
  AccessControlAllowMethodsHeader* = "access-control-allow-methods"
  AccessControlAllowHeadersHeader* = "access-control-allow-headers"
  AccessControlExposeHeadersHeader* = "access-control-expose-headers"
  AccessControlMaxAgeHeader* = "access-control-max-age"
  AccessControlAllowCredentialsHeader* = "access-control-allow-credentials"
  AccessControlRequestMethodHeader* = "access-control-request-method"
  AccessControlRequestHeadersHeader* = "access-control-request-headers"
  
  TimingAllowOriginHeader* = "timing-allow-origin"
  
  OriginHeader* = "origin" 