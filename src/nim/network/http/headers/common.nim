import std/[strutils, tables, options, uri, times, sequtils, parseutils, sets, 
         algorithm, unicode]

type
  HeaderField* = object
    name*: string
    value*: string
    description*: string
    category*: HeaderCategory
    standardized*: bool
    deprecated*: bool
    secure*: bool

  HeaderCategory* = enum
    hcGeneral,     # 一般的なヘッダー
    hcRequest,     # リクエスト専用ヘッダー
    hcResponse,    # レスポンス専用ヘッダー
    hcEntity,      # エンティティヘッダー
    hcCaching,     # キャッシュ関連ヘッダー
    hcCookie,      # クッキー関連ヘッダー
    hcCors,        # CORS関連ヘッダー
    hcSecurity,    # セキュリティ関連ヘッダー
    hcAuth,        # 認証関連ヘッダー
    hcRange,       # レンジリクエスト関連ヘッダー
    hcProxy,       # プロキシ関連ヘッダー
    hcConditional, # 条件付きリクエスト関連ヘッダー
    hcConnection,  # 接続管理関連ヘッダー
    hcContent,     # コンテンツネゴシエーション関連ヘッダー
    hcExtended     # 拡張ヘッダー

  ContentType* = object
    mediaType*: string
    subType*: string
    parameters*: Table[string, string]

  AcceptOption* = object
    mediaType*: string
    quality*: float
    parameters*: Table[string, string]

  MediaType* = enum
    mtText,
    mtImage,
    mtAudio,
    mtVideo,
    mtApplication,
    mtMultipart,
    mtMessage,
    mtModel,
    mtFont,
    mtOther

const
  # 標準的なHTTPヘッダーのリスト
  StandardRequestHeaders* = [
    "Accept",
    "Accept-Charset",
    "Accept-Encoding",
    "Accept-Language",
    "Authorization",
    "Cache-Control",
    "Connection",
    "Content-Length",
    "Content-Type",
    "Cookie",
    "Date",
    "Expect",
    "From",
    "Host",
    "If-Match",
    "If-Modified-Since",
    "If-None-Match",
    "If-Range",
    "If-Unmodified-Since",
    "Max-Forwards",
    "Pragma",
    "Proxy-Authorization",
    "Range",
    "Referer",
    "TE",
    "Upgrade",
    "User-Agent",
    "Via",
    "Warning"
  ]

  StandardResponseHeaders* = [
    "Accept-Ranges",
    "Age",
    "Allow",
    "Cache-Control",
    "Connection",
    "Content-Disposition",
    "Content-Encoding",
    "Content-Language",
    "Content-Length",
    "Content-Location",
    "Content-Range",
    "Content-Type",
    "Date",
    "ETag",
    "Expires",
    "Last-Modified",
    "Link",
    "Location",
    "Pragma",
    "Proxy-Authenticate",
    "Public-Key-Pins",
    "Retry-After",
    "Server",
    "Set-Cookie",
    "Strict-Transport-Security",
    "Trailer",
    "Transfer-Encoding",
    "Upgrade",
    "Vary",
    "Via",
    "Warning",
    "WWW-Authenticate",
    "X-Content-Type-Options",
    "X-Frame-Options",
    "X-XSS-Protection"
  ]

  # セキュリティヘッダーのリスト
  SecurityHeaders* = [
    "Content-Security-Policy",
    "Content-Security-Policy-Report-Only",
    "Expect-CT",
    "Feature-Policy",
    "Permissions-Policy",
    "Public-Key-Pins",
    "Public-Key-Pins-Report-Only",
    "Referrer-Policy",
    "Strict-Transport-Security",
    "X-Content-Type-Options",
    "X-Frame-Options",
    "X-XSS-Protection"
  ]

  # CORS関連ヘッダーのリスト
  CorsHeaders* = [
    "Access-Control-Allow-Origin",
    "Access-Control-Allow-Credentials",
    "Access-Control-Allow-Headers",
    "Access-Control-Allow-Methods",
    "Access-Control-Expose-Headers",
    "Access-Control-Max-Age",
    "Access-Control-Request-Headers",
    "Access-Control-Request-Method",
    "Origin"
  ]

  # 機密情報が含まれる可能性のあるヘッダー
  SensitiveHeaders* = [
    "Authorization",
    "Cookie",
    "Set-Cookie",
    "Proxy-Authorization",
    "WWW-Authenticate"
  ]

  # デフォルトのUTF-8文字セット
  DefaultCharset* = "utf-8"

  # 共通のContent-Typeマッピング
  CommonContentTypes* = {
    "html": "text/html",
    "css": "text/css",
    "js": "application/javascript",
    "json": "application/json",
    "xml": "application/xml",
    "txt": "text/plain",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "png": "image/png",
    "gif": "image/gif",
    "svg": "image/svg+xml",
    "ico": "image/x-icon",
    "mp3": "audio/mpeg",
    "mp4": "video/mp4",
    "pdf": "application/pdf",
    "zip": "application/zip",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  }.toTable

  # Content-Typeカテゴリ
  ImageContentTypes* = [
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/svg+xml",
    "image/webp",
    "image/bmp",
    "image/tiff",
    "image/x-icon"
  ]

  TextContentTypes* = [
    "text/plain",
    "text/html",
    "text/css",
    "text/xml",
    "text/csv",
    "text/javascript",
    "text/markdown"
  ]

  ApplicationContentTypes* = [
    "application/json",
    "application/xml",
    "application/javascript",
    "application/pdf",
    "application/zip",
    "application/x-www-form-urlencoded"
  ]

  # ヘッダーフィールドの詳細リスト
  HeaderRegistry* = {
    "accept": HeaderField(
      name: "Accept",
      value: "*/*",
      description: "クライアントが処理できるコンテンツタイプを指定",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "accept-charset": HeaderField(
      name: "Accept-Charset",
      value: "utf-8",
      description: "クライアントが処理できる文字セットを指定",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "accept-encoding": HeaderField(
      name: "Accept-Encoding",
      value: "gzip, deflate",
      description: "クライアントが処理できるエンコーディングを指定",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "accept-language": HeaderField(
      name: "Accept-Language",
      value: "ja, en;q=0.9",
      description: "クライアントが理解できる自然言語を指定",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "authorization": HeaderField(
      name: "Authorization",
      value: "",
      description: "リクエストの認証情報を提供",
      category: hcAuth,
      standardized: true,
      deprecated: false,
      secure: true
    ),
    "cache-control": HeaderField(
      name: "Cache-Control",
      value: "no-cache",
      description: "キャッシュの動作を指定",
      category: hcCaching,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "connection": HeaderField(
      name: "Connection",
      value: "keep-alive",
      description: "特定の接続オプションを指定",
      category: hcConnection,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-disposition": HeaderField(
      name: "Content-Disposition",
      value: "attachment; filename=\"filename.jpg\"",
      description: "コンテンツの表示方法を指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-encoding": HeaderField(
      name: "Content-Encoding",
      value: "gzip",
      description: "エンティティボディに適用されたエンコーディングを指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-language": HeaderField(
      name: "Content-Language",
      value: "ja",
      description: "コンテンツの言語を指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-length": HeaderField(
      name: "Content-Length",
      value: "348",
      description: "エンティティボディのサイズをバイト単位で指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-location": HeaderField(
      name: "Content-Location",
      value: "/index.html",
      description: "返されるデータの代替ロケーションを指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-range": HeaderField(
      name: "Content-Range",
      value: "bytes 21010-47021/47022",
      description: "部分的なボディのコンテンツが表すエンティティの範囲を指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "content-security-policy": HeaderField(
      name: "Content-Security-Policy",
      value: "default-src 'self'",
      description: "コンテンツのセキュリティポリシーを指定",
      category: hcSecurity,
      standardized: true,
      deprecated: false,
      secure: true
    ),
    "content-type": HeaderField(
      name: "Content-Type",
      value: "text/html; charset=utf-8",
      description: "リソースのメディアタイプを指定",
      category: hcEntity,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "cookie": HeaderField(
      name: "Cookie",
      value: "name=value",
      description: "サーバーに以前保存されたクッキーを送信",
      category: hcCookie,
      standardized: true,
      deprecated: false,
      secure: true
    ),
    "date": HeaderField(
      name: "Date",
      value: "Wed, 21 Oct 2015 07:28:00 GMT",
      description: "メッセージが生成された日時",
      category: hcGeneral,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "etag": HeaderField(
      name: "ETag",
      value: "\"33a64df551425fcc55e4d42a148795d9f25f89d4\"",
      description: "特定バージョンのリソースの識別子",
      category: hcCaching,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "expires": HeaderField(
      name: "Expires",
      value: "Wed, 21 Oct 2015 07:28:00 GMT",
      description: "レスポンスが古いと見なされる日時",
      category: hcCaching,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "host": HeaderField(
      name: "Host",
      value: "example.com",
      description: "リクエスト先のホスト名とポート番号",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "if-match": HeaderField(
      name: "If-Match",
      value: "\"33a64df551425fcc55e4d42a148795d9f25f89d4\"",
      description: "ETAGが一致した場合のみ操作を実行",
      category: hcConditional,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "if-modified-since": HeaderField(
      name: "If-Modified-Since",
      value: "Wed, 21 Oct 2015 07:28:00 GMT",
      description: "指定日時以降に変更された場合のみレスポンスを返す",
      category: hcConditional,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "if-none-match": HeaderField(
      name: "If-None-Match",
      value: "\"33a64df551425fcc55e4d42a148795d9f25f89d4\"",
      description: "ETAGが一致しない場合のみ操作を実行",
      category: hcConditional,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "last-modified": HeaderField(
      name: "Last-Modified",
      value: "Wed, 21 Oct 2015 07:28:00 GMT",
      description: "リソースが最後に変更された日時",
      category: hcCaching,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "location": HeaderField(
      name: "Location",
      value: "http://example.com/about",
      description: "リダイレクト先のURL",
      category: hcResponse,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "origin": HeaderField(
      name: "Origin",
      value: "http://example.com",
      description: "リクエストの発信元",
      category: hcCors,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "referer": HeaderField(
      name: "Referer",
      value: "http://example.com/page.html",
      description: "現在リクエストされたページへのリンク元のURL",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "set-cookie": HeaderField(
      name: "Set-Cookie",
      value: "name=value; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly",
      description: "サーバーからクライアントにクッキーを設定",
      category: hcCookie,
      standardized: true,
      deprecated: false,
      secure: true
    ),
    "strict-transport-security": HeaderField(
      name: "Strict-Transport-Security",
      value: "max-age=31536000; includeSubDomains",
      description: "HTTPSのみを使用するようブラウザに指示",
      category: hcSecurity,
      standardized: true,
      deprecated: false,
      secure: true
    ),
    "user-agent": HeaderField(
      name: "User-Agent",
      value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
      description: "リクエストを行うクライアントのソフトウェア情報",
      category: hcRequest,
      standardized: true,
      deprecated: false,
      secure: false
    ),
    "x-content-type-options": HeaderField(
      name: "X-Content-Type-Options",
      value: "nosniff",
      description: "Content-Typeヘッダーで指定されたコンテンツタイプの遵守を強制",
      category: hcSecurity,
      standardized: false,
      deprecated: false,
      secure: true
    ),
    "x-frame-options": HeaderField(
      name: "X-Frame-Options",
      value: "DENY",
      description: "ページがフレーム内で表示されることを許可するかどうかを示す",
      category: hcSecurity,
      standardized: false,
      deprecated: false,
      secure: true
    ),
    "x-xss-protection": HeaderField(
      name: "X-XSS-Protection",
      value: "1; mode=block",
      description: "XSS攻撃を検出した際のブラウザの動作を設定",
      category: hcSecurity,
      standardized: false,
      deprecated: true,
      secure: true
    )
  }.toTable

proc newContentType*(mediaType: string): ContentType =
  ## メディアタイプ文字列からContentTypeオブジェクトを作成
  result.parameters = initTable[string, string]()
  
  # メディアタイプとパラメータの分離
  let parts = mediaType.split(";")
  if parts.len > 0:
    let mediaTypeParts = parts[0].strip().split("/")
    if mediaTypeParts.len == 2:
      result.mediaType = mediaTypeParts[0].strip().toLowerAscii()
      result.subType = mediaTypeParts[1].strip().toLowerAscii()
    
    # パラメータの解析
    for i in 1..<parts.len:
      let param = parts[i].strip()
      let eqPos = param.find('=')
      if eqPos > 0:
        let name = param[0..<eqPos].strip().toLowerAscii()
        var value = param[eqPos+1..^1].strip()
        
        # 引用符の除去
        if value.len >= 2 and value[0] == '"' and value[^1] == '"':
          value = value[1..^2]
        
        result.parameters[name] = value

proc getMediaType*(contentType: ContentType): MediaType =
  ## ContentTypeからMediaTypeを取得
  case contentType.mediaType.toLowerAscii()
  of "text": return mtText
  of "image": return mtImage
  of "audio": return mtAudio
  of "video": return mtVideo
  of "application": return mtApplication
  of "multipart": return mtMultipart
  of "message": return mtMessage
  of "model": return mtModel
  of "font": return mtFont
  else: return mtOther

proc getCharset*(contentType: ContentType): string =
  ## ContentTypeからcharsetパラメータを取得
  if "charset" in contentType.parameters:
    return contentType.parameters["charset"]
  else:
    return DefaultCharset

proc toString*(contentType: ContentType): string =
  ## ContentTypeオブジェクトから文字列表現を生成
  result = contentType.mediaType & "/" & contentType.subType
  
  for name, value in contentType.parameters:
    var paramValue = value
    
    # 特殊文字を含む場合は引用符で囲む
    if paramValue.contains({' ', ';', ',', '(', ')', '<', '>', '@', ':', '\\', '/', '[', ']', '?', '='}):
      paramValue = "\"" & paramValue & "\""
    
    result.add("; " & name & "=" & paramValue)

proc parseAcceptHeader*(acceptHeader: string): seq[AcceptOption] =
  ## Accept ヘッダーを解析してAcceptOptionのシーケンスを返す
  result = @[]
  
  if acceptHeader.len == 0:
    return
  
  let options = acceptHeader.split(',')
  for opt in options:
    let parts = opt.strip().split(';')
    
    if parts.len == 0 or parts[0].len == 0:
      continue
    
    var acceptOpt = AcceptOption()
    acceptOpt.mediaType = parts[0].strip().toLowerAscii()
    acceptOpt.quality = 1.0
    acceptOpt.parameters = initTable[string, string]()
    
    # パラメータの処理
    for i in 1..<parts.len:
      let param = parts[i].strip()
      let eqPos = param.find('=')
      
      if eqPos > 0:
        let name = param[0..<eqPos].strip().toLowerAscii()
        let value = param[eqPos+1..^1].strip()
        
        # qパラメータは品質値
        if name == "q":
          try:
            acceptOpt.quality = parseFloat(value)
          except:
            acceptOpt.quality = 1.0
        else:
          acceptOpt.parameters[name] = value
    
    result.add(acceptOpt)
  
  # 品質値で降順ソート
  result.sort(proc(a, b: AcceptOption): int =
    if a.quality > b.quality: return -1
    elif a.quality < b.quality: return 1
    else: return 0
  )

proc isSecurityHeader*(headerName: string): bool =
  ## 指定ヘッダーがセキュリティ関連かどうかを判定
  let normalizedName = headerName.toLowerAscii()
  for header in SecurityHeaders:
    if header.toLowerAscii() == normalizedName:
      return true
  return false

proc isSensitiveHeader*(headerName: string): bool =
  ## 指定ヘッダーが機密情報を含む可能性があるかどうかを判定
  let normalizedName = headerName.toLowerAscii()
  for header in SensitiveHeaders:
    if header.toLowerAscii() == normalizedName:
      return true
  return false

proc isCorsHeader*(headerName: string): bool =
  ## 指定ヘッダーがCORS関連かどうかを判定
  let normalizedName = headerName.toLowerAscii()
  for header in CorsHeaders:
    if header.toLowerAscii() == normalizedName:
      return true
  return false

proc isStandardHeader*(headerName: string, isRequest: bool = true): bool =
  ## 指定ヘッダーが標準ヘッダーかどうかを判定
  let normalizedName = headerName.toLowerAscii()
  if isRequest:
    for header in StandardRequestHeaders:
      if header.toLowerAscii() == normalizedName:
        return true
  else:
    for header in StandardResponseHeaders:
      if header.toLowerAscii() == normalizedName:
        return true
  return false

proc getHeaderField*(headerName: string): Option[HeaderField] =
  ## ヘッダー名から HeaderField 情報を取得
  let normalizedName = headerName.toLowerAscii()
  if normalizedName in HeaderRegistry:
    return some(HeaderRegistry[normalizedName])
  return none(HeaderField)

proc getContentTypeFromFileExtension*(ext: string): string =
  ## ファイル拡張子からContent-Type値を推測
  let normalizedExt = ext.toLowerAscii().strip(chars={'.'})
  if normalizedExt in CommonContentTypes:
    return CommonContentTypes[normalizedExt]
  return "application/octet-stream"  # デフォルト

proc isImageContentType*(contentType: string): bool =
  ## 指定されたContent-TypeがImgaeタイプかどうかを判定
  for imgType in ImageContentTypes:
    if contentType.toLowerAscii().startsWith(imgType):
      return true
  return false

proc isTextContentType*(contentType: string): bool =
  ## 指定されたContent-Typeがテキストタイプかどうかを判定
  for txtType in TextContentTypes:
    if contentType.toLowerAscii().startsWith(txtType):
      return true
  return false

proc formatHeader*(name: string, value: string): string =
  ## HTTPヘッダー形式に整形 (名前: 値)
  return name & ": " & value

proc formatDateHeader*(time: DateTime): string =
  ## RFC 7231に準拠した日付ヘッダー形式に変換
  let daysOfWeek = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  
  let dayOfWeek = daysOfWeek[time.weekday.ord - 1]
  let month = months[time.month.ord - 1]
  
  return &"{dayOfWeek}, {time.monthday:02d} {month} {time.year} {time.hour:02d}:{time.minute:02d}:{time.second:02d} GMT"

proc formatCurrentDateHeader*(): string =
  ## 現在時刻をRFC 7231に準拠した日付ヘッダー形式に変換
  return formatDateHeader(now().utc())

proc sanitizeHeaderValue*(value: string): string =
  ## ヘッダー値から制御文字を除去
  result = ""
  for c in value:
    # CRとLFは除外、その他の制御文字も除外
    let code = c.ord
    if code != 13 and code != 10 and (code >= 32 or code == 9):
      result.add(c)

proc foldHeaderValue*(value: string, maxLength: int = 78): string =
  ## 長いヘッダー値を複数行に分割 (RFC 7230に準拠)
  if value.len <= maxLength:
    return value
  
  result = ""
  var currentPos = 0
  
  while currentPos < value.len:
    let remaining = value.len - currentPos
    let chunkSize = if remaining > maxLength: maxLength else: remaining
    
    if result.len > 0:
      result.add("\r\n ")  # 継続行はスペースまたはタブでインデント
    
    result.add(value[currentPos..<(currentPos + chunkSize)])
    currentPos += chunkSize

proc createBasicAuthHeader*(username, password: string): string =
  ## Basic認証ヘッダーを生成
  let auth = username & ":" & password
  let encoded = encode(auth)
  return "Basic " & encoded

proc parseBasicAuth*(authHeader: string): Option[tuple[username, password: string]] =
  ## Basic認証ヘッダーを解析
  if not authHeader.startsWith("Basic "):
    return none(tuple[username, password: string])
  
  try:
    let encoded = authHeader[6..^1]
    let decoded = decode(encoded)
    let parts = decoded.split(':', 1)
    
    if parts.len == 2:
      return some((username: parts[0], password: parts[1]))
  except:
    discard
  
  return none(tuple[username, password: string])

proc createBearerAuthHeader*(token: string): string =
  ## Bearer認証ヘッダーを生成
  return "Bearer " & token

proc parseBearerAuth*(authHeader: string): Option[string] =
  ## Bearer認証ヘッダーからトークンを抽出
  if not authHeader.startsWith("Bearer "):
    return none(string)
  
  let token = authHeader[7..^1].strip()
  if token.len > 0:
    return some(token)
  
  return none(string) 