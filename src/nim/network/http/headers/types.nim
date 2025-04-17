import std/[tables, strutils, options, times, strformat, sequtils]
import ./constants

type
  # HTTPヘッダーの種類
  HttpHeaderKind* = enum
    GeneralHeader,     # 一般ヘッダー（リクエスト・レスポンス両方で使用）
    RequestHeader,     # リクエスト固有のヘッダー
    ResponseHeader,    # レスポンス固有のヘッダー
    EntityHeader,      # エンティティ（コンテンツ）関連のヘッダー
    SecurityHeader,    # セキュリティ関連のヘッダー
    CustomHeader       # カスタムヘッダー

  # HTTPヘッダーの値の種類
  HttpHeaderValueKind* = enum
    SingleValue,       # 単一の値
    MultiValue,        # 複数の値（カンマ区切り）
    SemicolonValue,    # セミコロン区切りの値
    DateValue,         # 日付形式の値
    IntValue,          # 整数値
    BoolValue,         # 真偽値
    QualityValue       # 品質値 (q=0.x)

  # HTTPヘッダーの定義
  HttpHeaderDefinition* = object
    name*: string              # ヘッダー名
    kind*: HttpHeaderKind      # ヘッダーの種類
    valueKind*: HttpHeaderValueKind  # 値の種類
    description*: string       # 説明
    deprecated*: bool          # 非推奨かどうか
    securityImpact*: int       # セキュリティへの影響度（0-10）

  # HTTPヘッダー値
  HttpHeaderValue* = object
    case kind*: HttpHeaderValueKind
    of SingleValue:
      value*: string
    of MultiValue:
      values*: seq[string]
    of SemicolonValue:
      parts*: Table[string, string]
    of DateValue:
      date*: DateTime
    of IntValue:
      intVal*: int
    of BoolValue:
      boolVal*: bool
    of QualityValue:
      mainValue*: string
      quality*: float

  # HTTPヘッダー
  HttpHeader* = object
    name*: string              # ヘッダー名
    rawValue*: string          # 生の値（未解析）
    parsedValue*: HttpHeaderValue  # 解析された値
    definition*: HttpHeaderDefinition  # ヘッダーの定義

  # HTTPヘッダーコレクション
  HttpHeaders* = object
    headers*: Table[string, HttpHeader]  # ヘッダー名（小文字）からヘッダーへのマッピング
    orderedNames*: seq[string]  # 順序を保持するためのヘッダー名リスト

# 標準HTTPヘッダーの定義
let 
  # 一般ヘッダー
  ContentTypeHeader* = HttpHeaderDefinition(
    name: "Content-Type",
    kind: EntityHeader,
    valueKind: SemicolonValue,
    description: "送信されるデータの種類を示す",
    deprecated: false,
    securityImpact: 3
  )

  ContentLengthHeader* = HttpHeaderDefinition(
    name: "Content-Length",
    kind: EntityHeader,
    valueKind: IntValue,
    description: "送信されるデータの長さをバイト単位で示す",
    deprecated: false,
    securityImpact: 1
  )

  # リクエストヘッダー
  UserAgentHeader* = HttpHeaderDefinition(
    name: "User-Agent",
    kind: RequestHeader,
    valueKind: SingleValue,
    description: "リクエストを行うクライアントソフトウェアの情報",
    deprecated: false,
    securityImpact: 2
  )

  AcceptHeader* = HttpHeaderDefinition(
    name: "Accept",
    kind: RequestHeader,
    valueKind: QualityValue,
    description: "クライアントが処理可能なコンテンツタイプ",
    deprecated: false,
    securityImpact: 1
  )

  HostHeader* = HttpHeaderDefinition(
    name: "Host",
    kind: RequestHeader,
    valueKind: SingleValue,
    description: "リクエストされるサーバーのホスト名とポート番号",
    deprecated: false,
    securityImpact: 5
  )

  # レスポンスヘッダー
  ServerHeader* = HttpHeaderDefinition(
    name: "Server",
    kind: ResponseHeader,
    valueKind: SingleValue,
    description: "レスポンスを生成するサーバーソフトウェアの情報",
    deprecated: false,
    securityImpact: 4
  )

  # セキュリティヘッダー
  ContentSecurityPolicyHeader* = HttpHeaderDefinition(
    name: "Content-Security-Policy",
    kind: SecurityHeader,
    valueKind: SemicolonValue,
    description: "コンテンツセキュリティポリシーを定義",
    deprecated: false,
    securityImpact: 9
  )

  StrictTransportSecurityHeader* = HttpHeaderDefinition(
    name: "Strict-Transport-Security",
    kind: SecurityHeader,
    valueKind: SemicolonValue,
    description: "HTTPSのみの通信を強制",
    deprecated: false,
    securityImpact: 10
  )

# 標準ヘッダー定義のテーブル
var StandardHttpHeaders* = {
  "content-type": ContentTypeHeader,
  "content-length": ContentLengthHeader,
  "user-agent": UserAgentHeader,
  "accept": AcceptHeader,
  "host": HostHeader,
  "server": ServerHeader,
  "content-security-policy": ContentSecurityPolicyHeader,
  "strict-transport-security": StrictTransportSecurityHeader
}.toTable()

# 新しいHttpHeadersインスタンスを作成
proc newHttpHeaders*(): HttpHeaders =
  result.headers = initTable[string, HttpHeader]()
  result.orderedNames = @[]

# 文字列からHttpHeadersを解析
proc parseHeaders*(headers: string): HttpHeaders =
  result = newHttpHeaders()
  
  # ヘッダー行ごとに処理
  for line in headers.split("\r\n"):
    if line.len == 0:
      continue
      
    let parts = line.split(":", 1)
    if parts.len < 2:
      continue
      
    let 
      name = parts[0].strip()
      value = parts[1].strip()
      lowerName = name.toLowerAscii()
    
    var header = HttpHeader(
      name: name,
      rawValue: value
    )
    
    # 標準ヘッダー定義が存在するかチェック
    if StandardHttpHeaders.hasKey(lowerName):
      header.definition = StandardHttpHeaders[lowerName]
    else:
      header.definition = HttpHeaderDefinition(
        name: name,
        kind: CustomHeader,
        valueKind: SingleValue,
        description: "",
        deprecated: false,
        securityImpact: 0
      )
    
    # ヘッダー値の解析
    header.parsedValue = parseHeaderValue(value, header.definition.valueKind)
    
    # ヘッダーを追加
    result.headers[lowerName] = header
    result.orderedNames.add(lowerName)

# ヘッダー値を種類に応じて解析
proc parseHeaderValue*(value: string, kind: HttpHeaderValueKind): HttpHeaderValue =
  case kind
  of SingleValue:
    return HttpHeaderValue(kind: SingleValue, value: value)
    
  of MultiValue:
    var values: seq[string] = @[]
    for part in value.split(','):
      values.add(part.strip())
    return HttpHeaderValue(kind: MultiValue, values: values)
    
  of SemicolonValue:
    var parts = initTable[string, string]()
    let mainParts = value.split(';')
    
    if mainParts.len > 0:
      parts["_main"] = mainParts[0].strip()
      
      for i in 1..<mainParts.len:
        let paramParts = mainParts[i].strip().split('=', 1)
        if paramParts.len == 2:
          parts[paramParts[0].strip()] = paramParts[1].strip().strip(chars={'"', '\''})
        elif paramParts.len == 1:
          parts[paramParts[0].strip()] = ""
    
    return HttpHeaderValue(kind: SemicolonValue, parts: parts)
    
  of DateValue:
    try:
      let dt = parse(value, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
      return HttpHeaderValue(kind: DateValue, date: dt)
    except:
      return HttpHeaderValue(kind: SingleValue, value: value)
    
  of IntValue:
    try:
      let intVal = parseInt(value)
      return HttpHeaderValue(kind: IntValue, intVal: intVal)
    except:
      return HttpHeaderValue(kind: SingleValue, value: value)
    
  of BoolValue:
    let lowerValue = value.toLowerAscii()
    if lowerValue == "true" or lowerValue == "1" or lowerValue == "yes":
      return HttpHeaderValue(kind: BoolValue, boolVal: true)
    else:
      return HttpHeaderValue(kind: BoolValue, boolVal: false)
    
  of QualityValue:
    var 
      mainValue = ""
      quality = 1.0
    
    let parts = value.split(';')
    if parts.len > 0:
      mainValue = parts[0].strip()
      
      for i in 1..<parts.len:
        let paramParts = parts[i].strip().split('=', 1)
        if paramParts.len == 2 and paramParts[0].strip().toLowerAscii() == "q":
          try:
            quality = parseFloat(paramParts[1])
          except:
            quality = 1.0
    
    return HttpHeaderValue(kind: QualityValue, mainValue: mainValue, quality: quality)

# ヘッダーの取得（大文字小文字を区別しない）
proc getHeader*(headers: HttpHeaders, name: string): Option[HttpHeader] =
  let lowerName = name.toLowerAscii()
  if headers.headers.hasKey(lowerName):
    return some(headers.headers[lowerName])
  else:
    return none(HttpHeader)

# ヘッダーの追加
proc add*(headers: var HttpHeaders, name: string, value: string) =
  let lowerName = name.toLowerAscii()
  
  var header = HttpHeader(
    name: name,
    rawValue: value
  )
  
  # 標準ヘッダー定義が存在するかチェック
  if StandardHttpHeaders.hasKey(lowerName):
    header.definition = StandardHttpHeaders[lowerName]
    header.parsedValue = parseHeaderValue(value, header.definition.valueKind)
  else:
    header.definition = HttpHeaderDefinition(
      name: name,
      kind: CustomHeader,
      valueKind: SingleValue,
      description: "",
      deprecated: false,
      securityImpact: 0
    )
    header.parsedValue = parseHeaderValue(value, SingleValue)
  
  # 既存のヘッダーを上書き、または新規追加
  if not headers.headers.hasKey(lowerName):
    headers.orderedNames.add(lowerName)
  
  headers.headers[lowerName] = header

# ヘッダーの削除
proc remove*(headers: var HttpHeaders, name: string) =
  let lowerName = name.toLowerAscii()
  if headers.headers.hasKey(lowerName):
    headers.headers.del(lowerName)
    # 順序リストからも削除
    let idx = headers.orderedNames.find(lowerName)
    if idx >= 0:
      headers.orderedNames.delete(idx)

# ヘッダーの存在チェック
proc contains*(headers: HttpHeaders, name: string): bool =
  return headers.headers.hasKey(name.toLowerAscii())

# ヘッダーの文字列表現（HTTP標準形式）
proc `$`*(headers: HttpHeaders): string =
  var result = ""
  for name in headers.orderedNames:
    let header = headers.headers[name]
    result.add(fmt"{header.name}: {header.rawValue}\r\n")
  return result

# ヘッダー値の文字列表現
proc `$`*(value: HttpHeaderValue): string =
  case value.kind
  of SingleValue:
    return value.value
  of MultiValue:
    return value.values.join(", ")
  of SemicolonValue:
    var parts: seq[string] = @[]
    if value.parts.hasKey("_main"):
      parts.add(value.parts["_main"])
    
    for k, v in value.parts:
      if k != "_main":
        if v.len > 0:
          parts.add(fmt"{k}={v}")
        else:
          parts.add(k)
    
    return parts.join("; ")
  of DateValue:
    return value.date.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
  of IntValue:
    return $value.intVal
  of BoolValue:
    return if value.boolVal: "true" else: "false"
  of QualityValue:
    if value.quality == 1.0:
      return value.mainValue
    else:
      return fmt"{value.mainValue}; q={value.quality:.1f}"

# ヘッダーセットの複製
proc clone*(headers: HttpHeaders): HttpHeaders =
  result = newHttpHeaders()
  for name in headers.orderedNames:
    let header = headers.headers[name]
    result.headers[name] = header
    result.orderedNames.add(name)

# Content-Typeヘッダーからメディアタイプを取得
proc getMediaType*(headers: HttpHeaders): string =
  let contentType = headers.getHeader("Content-Type")
  if contentType.isSome:
    let headerValue = contentType.get().parsedValue
    if headerValue.kind == SemicolonValue and headerValue.parts.hasKey("_main"):
      return headerValue.parts["_main"]
  
  return ""

# Content-Typeヘッダーからcharsetを取得
proc getCharset*(headers: HttpHeaders): string =
  let contentType = headers.getHeader("Content-Type")
  if contentType.isSome:
    let headerValue = contentType.get().parsedValue
    if headerValue.kind == SemicolonValue and headerValue.parts.hasKey("charset"):
      return headerValue.parts["charset"]
  
  return "utf-8"  # デフォルトはUTF-8

# Content-Lengthヘッダーから長さを取得
proc getContentLength*(headers: HttpHeaders): int =
  let contentLength = headers.getHeader("Content-Length")
  if contentLength.isSome:
    let headerValue = contentLength.get().parsedValue
    if headerValue.kind == IntValue:
      return headerValue.intVal
  
  return -1  # 未定義

# セキュリティスコアの計算（すべてのセキュリティヘッダーの有無と内容に基づく）
proc calculateSecurityScore*(headers: HttpHeaders): int =
  var score = 0
  
  # Strict-Transport-Security
  if headers.contains("Strict-Transport-Security"):
    score += 20
  
  # Content-Security-Policy
  if headers.contains("Content-Security-Policy"):
    score += 25
  
  # X-Content-Type-Options
  if headers.contains("X-Content-Type-Options"):
    score += 10
  
  # X-Frame-Options
  if headers.contains("X-Frame-Options"):
    score += 10
  
  # X-XSS-Protection
  if headers.contains("X-XSS-Protection"):
    score += 5
  
  # Referrer-Policy
  if headers.contains("Referrer-Policy"):
    score += 10
  
  # Feature-Policy/Permissions-Policy
  if headers.contains("Feature-Policy") or headers.contains("Permissions-Policy"):
    score += 10
  
  # Cache-Control（機密データのキャッシュ防止）
  if headers.contains("Cache-Control"):
    let cacheControl = headers.getHeader("Cache-Control").get()
    if cacheControl.rawValue.contains("no-store") or cacheControl.rawValue.contains("private"):
      score += 10
  
  return min(score, 100)  # 最大100点

# ヘッダーを標準形式に正規化
proc normalizeHeaders*(headers: var HttpHeaders) =
  for name in headers.orderedNames:
    let header = headers.headers[name]
    # 標準ヘッダー名の大文字小文字を修正
    if StandardHttpHeaders.hasKey(name):
      let standardName = StandardHttpHeaders[name].name
      var newHeader = header
      newHeader.name = standardName
      headers.headers[name] = newHeader

# 新しいHttpHeaders型を作成する
proc newHttpHeaders*(caseSensitive: bool = false): HttpHeaders =
  result = HttpHeaders(
    headers: initTable[string, HttpHeader](),
    orderedNames: @[]
  )

# HttpHeaders型からヘッダー名を正規化する
proc normalizeHeaderName*(headers: HttpHeaders, name: string): string =
  if headers.caseSensitive:
    return name
  else:
    return name.toLowerAscii()

# ヘッダーを追加する
proc add*(headers: HttpHeaders, name, value: string) =
  let normalizedName = headers.normalizeHeaderName(name)
  
  # 元の大文字小文字を保持
  if normalizedName notin headers.headers:
    headers.orderedNames.add(normalizedName)
  
  # 値を追加
  let headerValue = HttpHeaderValue(value: value, params: initTable[string, string]())
  if normalizedName in headers.headers:
    headers.headers[normalizedName].parsedValue = headerValue
  else:
    headers.headers[normalizedName] = HttpHeader(
      name: normalizedName,
      rawValue: value,
      parsedValue: headerValue,
      definition: HttpHeaderDefinition(
        name: normalizedName,
        kind: GeneralHeader,
        valueKind: SingleValue,
        description: "",
        deprecated: false,
        securityImpact: 0
      )
    )

# パラメータ付きのヘッダーを追加する
proc addWithParams*(headers: HttpHeaders, name, value: string, params: Table[string, string]) =
  let normalizedName = headers.normalizeHeaderName(name)
  
  # 元の大文字小文字を保持
  if normalizedName notin headers.headers:
    headers.orderedNames.add(normalizedName)
  
  # パラメータ付きの値を追加
  let headerValue = HttpHeaderValue(value: value, params: params)
  if normalizedName in headers.headers:
    headers.headers[normalizedName].parsedValue = headerValue
  else:
    headers.headers[normalizedName] = HttpHeader(
      name: normalizedName,
      rawValue: value,
      parsedValue: headerValue,
      definition: HttpHeaderDefinition(
        name: normalizedName,
        kind: GeneralHeader,
        valueKind: SemicolonValue,
        description: "",
        deprecated: false,
        securityImpact: 0
      )
    )

# ヘッダーを設定する（既存の値を上書き）
proc set*(headers: HttpHeaders, name, value: string) =
  let normalizedName = headers.normalizeHeaderName(name)
  
  # 元の大文字小文字を保持
  headers.orderedNames.add(normalizedName)
  
  # 値を設定
  let headerValue = HttpHeaderValue(value: value, params: initTable[string, string]())
  headers.headers[normalizedName] = HttpHeader(
    name: normalizedName,
    rawValue: value,
    parsedValue: headerValue,
    definition: HttpHeaderDefinition(
      name: normalizedName,
      kind: GeneralHeader,
      valueKind: SingleValue,
      description: "",
      deprecated: false,
      securityImpact: 0
    )
  )

# ヘッダーを取得する（最初の値のみ）
proc getFirst*(headers: HttpHeaders, name: string): Option[string] =
  let normalizedName = headers.normalizeHeaderName(name)
  if normalizedName in headers.headers and headers.headers[normalizedName].parsedValue.kind != SingleValue:
    return some(headers.headers[normalizedName].parsedValue.value)
  return none(string)

# ヘッダーの全ての値を取得する
proc getAll*(headers: HttpHeaders, name: string): seq[string] =
  result = @[]
  let normalizedName = headers.normalizeHeaderName(name)
  if normalizedName in headers.headers:
    result.add(headers.headers[normalizedName].parsedValue.value)

# ヘッダーパラメータ付きで取得する
proc getAllWithParams*(headers: HttpHeaders, name: string): seq[HttpHeaderValue] =
  result = @[]
  let normalizedName = headers.normalizeHeaderName(name)
  if normalizedName in headers.headers:
    result = @[headers.headers[normalizedName].parsedValue]

# ヘッダーが存在するか確認する
proc contains*(headers: HttpHeaders, name: string): bool =
  let normalizedName = headers.normalizeHeaderName(name)
  return normalizedName in headers.headers

# ヘッダーを削除する
proc delete*(headers: HttpHeaders, name: string) =
  let normalizedName = headers.normalizeHeaderName(name)
  if normalizedName in headers.headers:
    headers.headers.del(normalizedName)
    headers.orderedNames.delete(headers.orderedNames.find(normalizedName))

# 全てのヘッダーを削除する
proc clear*(headers: HttpHeaders) =
  headers.headers.clear()
  headers.orderedNames.clear()

# ヘッダー名の一覧を取得する（元の大文字小文字で）
proc names*(headers: HttpHeaders): seq[string] =
  result = headers.orderedNames

# Content-Typeをパースする
proc parseContentType*(value: string): ContentType =
  result = ContentType(
    mediaType: "",
    charset: none(string),
    boundary: none(string)
  )
  
  let parts = value.split(';')
  if parts.len > 0:
    result.mediaType = parts[0].strip()
    
    for i in 1..<parts.len:
      let param = parts[i].strip().split('=', maxsplit=1)
      if param.len == 2:
        let paramName = param[0].strip().toLowerAscii()
        var paramValue = param[1].strip()
        
        # 値が引用符で囲まれている場合、引用符を削除
        if paramValue.len >= 2 and paramValue[0] == '"' and paramValue[^1] == '"':
          paramValue = paramValue[1..^2]
        
        if paramName == "charset":
          result.charset = some(paramValue)
        elif paramName == "boundary":
          result.boundary = some(paramValue)

# Authorizationヘッダーをパースする
proc parseAuthorization*(value: string): AuthCredentials =
  let parts = value.splitWhitespace(maxsplit=1)
  if parts.len < 1:
    raise newException(HttpHeaderException, "Invalid Authorization header format")
  
  let scheme = parts[0].toLowerAscii()
  
  case scheme
  of "basic":
    if parts.len < 2:
      raise newException(HttpHeaderException, "Missing credentials in Basic Authorization")
    
    let credentials = decode(parts[1]).split(':', maxsplit=1)
    if credentials.len < 2:
      raise newException(HttpHeaderException, "Invalid Basic Authorization format")
    
    result = AuthCredentials(
      scheme: AuthBasic,
      username: credentials[0],
      password: credentials[1]
    )
  
  of "bearer":
    if parts.len < 2:
      raise newException(HttpHeaderException, "Missing token in Bearer Authorization")
    
    result = AuthCredentials(
      scheme: AuthBearer,
      token: parts[1]
    )
  
  of "digest":
    if parts.len < 2:
      raise newException(HttpHeaderException, "Missing parameters in Digest Authorization")
    
    var digestParams = initTable[string, string]()
    let paramStr = parts[1]
    
    var i = 0
    while i < paramStr.len:
      # パラメータ名を取得
      var nameStart = i
      while i < paramStr.len and paramStr[i] != '=':
        inc(i)
      
      if i >= paramStr.len:
        break
      
      let name = paramStr[nameStart..<i].strip()
      inc(i) # '='をスキップ
      
      # パラメータ値を取得
      var valueStart = i
      var inQuotes = false
      if i < paramStr.len and paramStr[i] == '"':
        inQuotes = true
        inc(valueStart)
        inc(i)
      
      while i < paramStr.len:
        if inQuotes and paramStr[i] == '"' and (i == 0 or paramStr[i-1] != '\\'):
          break
        if not inQuotes and paramStr[i] == ',':
          break
        inc(i)
      
      var value: string
      if inQuotes:
        value = paramStr[valueStart..<i]
        inc(i) # '"'をスキップ
      else:
        value = paramStr[valueStart..<i].strip()
      
      digestParams[name] = value
      
      # 次のパラメータをスキップ
      while i < paramStr.len and (paramStr[i] == ',' or paramStr[i] == ' '):
        inc(i)
    
    result = AuthCredentials(
      scheme: AuthDigest,
      digestParams: digestParams
    )
  
  of "negotiate", "ntlm":
    if parts.len < 2:
      raise newException(HttpHeaderException, "Missing token in Negotiate/NTLM Authorization")
    
    if scheme == "negotiate":
      result = AuthCredentials(
        scheme: AuthNegotiate,
        negotiateToken: parts[1]
      )
    else:
      result = AuthCredentials(
        scheme: AuthNtlm,
        negotiateToken: parts[1]
      )
  
  else:
    # カスタム認証方式として扱う
    if parts.len < 2:
      raise newException(HttpHeaderException, "Missing value in Authorization")
    
    result = AuthCredentials(
      scheme: AuthCustom,
      authName: parts[0],
      authValue: parts[1]
    )

# Cache-Controlヘッダーをパースする
proc parseCacheControl*(value: string): seq[CacheDirective] =
  result = @[]
  
  let directives = value.split(',')
  for directive in directives:
    let parts = directive.strip().split('=', maxsplit=1)
    let name = parts[0].strip().toLowerAscii()
    
    if parts.len == 1:
      # 値のないディレクティブ
      result.add(CacheDirective(name: name, value: none(string)))
    else:
      # 値のあるディレクティブ
      var directiveValue = parts[1].strip()
      
      # 値が引用符で囲まれている場合、引用符を削除
      if directiveValue.len >= 2 and directiveValue[0] == '"' and directiveValue[^1] == '"':
        directiveValue = directiveValue[1..^2]
      
      result.add(CacheDirective(name: name, value: some(directiveValue)))

# CSPヘッダーをパースする
proc parseContentSecurityPolicy*(value: string): seq[CspDirective] =
  result = @[]
  
  let directives = value.split(';')
  for directive in directives:
    let directive = directive.strip()
    if directive.len == 0:
      continue
    
    let parts = directive.split(maxsplit=1)
    if parts.len == 0:
      continue
    
    let name = parts[0].strip()
    var sources: seq[string] = @[]
    
    if parts.len > 1:
      let sourceStr = parts[1].strip()
      # ソースリストをスペースで分割
      for source in sourceStr.split():
        if source.len > 0:
          sources.add(source)
    
    result.add(CspDirective(name: name, sources: sources))

# Acceptヘッダーをパースする
proc parseAccept*(value: string): seq[MediaTypeWithQValue] =
  result = @[]
  
  let mediaTypes = value.split(',')
  for mediaType in mediaTypes:
    let mediaType = mediaType.strip()
    if mediaType.len == 0:
      continue
    
    var typeAndParams = mediaType.split(';')
    let typeValue = typeAndParams[0].strip()
    
    var qValue: float = 1.0
    var params = initTable[string, string]()
    
    for i in 1..<typeAndParams.len:
      let param = typeAndParams[i].strip().split('=', maxsplit=1)
      if param.len != 2:
        continue
      
      let paramName = param[0].strip().toLowerAscii()
      let paramValue = param[1].strip()
      
      if paramName == "q":
        try:
          qValue = parseFloat(paramValue)
          # q値は0.0～1.0の範囲に制限
          qValue = max(0.0, min(1.0, qValue))
        except ValueError:
          # パース失敗時はデフォルト値を使用
          qValue = 1.0
      else:
        params[paramName] = paramValue
    
    result.add(MediaTypeWithQValue(
      mediaType: typeValue,
      qValue: qValue,
      params: params
    ))
  
  # q値で降順にソート
  result.sort(proc(x, y: MediaTypeWithQValue): int =
    if x.qValue > y.qValue: return -1
    if x.qValue < y.qValue: return 1
    return 0
  )

# Accept-Languageヘッダーをパースする
proc parseAcceptLanguage*(value: string): seq[LanguageWithQValue] =
  result = @[]
  
  let languages = value.split(',')
  for lang in languages:
    let lang = lang.strip()
    if lang.len == 0:
      continue
    
    let parts = lang.split(';')
    let langTag = parts[0].strip()
    
    var qValue: float = 1.0
    
    if parts.len > 1:
      for i in 1..<parts.len:
        let param = parts[i].strip().split('=', maxsplit=1)
        if param.len != 2:
          continue
        
        let paramName = param[0].strip().toLowerAscii()
        let paramValue = param[1].strip()
        
        if paramName == "q":
          try:
            qValue = parseFloat(paramValue)
            # q値は0.0～1.0の範囲に制限
            qValue = max(0.0, min(1.0, qValue))
          except ValueError:
            # パース失敗時はデフォルト値を使用
            qValue = 1.0
    
    result.add(LanguageWithQValue(
      language: langTag,
      qValue: qValue
    ))
  
  # q値で降順にソート
  result.sort(proc(x, y: LanguageWithQValue): int =
    if x.qValue > y.qValue: return -1
    if x.qValue < y.qValue: return 1
    return 0
  )

# Accept-Encodingヘッダーをパースする
proc parseAcceptEncoding*(value: string): seq[EncodingWithQValue] =
  result = @[]
  
  let encodings = value.split(',')
  for enc in encodings:
    let enc = enc.strip()
    if enc.len == 0:
      continue
    
    let parts = enc.split(';')
    let encoding = parts[0].strip()
    
    var qValue: float = 1.0
    
    if parts.len > 1:
      for i in 1..<parts.len:
        let param = parts[i].strip().split('=', maxsplit=1)
        if param.len != 2:
          continue
        
        let paramName = param[0].strip().toLowerAscii()
        let paramValue = param[1].strip()
        
        if paramName == "q":
          try:
            qValue = parseFloat(paramValue)
            # q値は0.0～1.0の範囲に制限
            qValue = max(0.0, min(1.0, qValue))
          except ValueError:
            # パース失敗時はデフォルト値を使用
            qValue = 1.0
    
    result.add(EncodingWithQValue(
      encoding: encoding,
      qValue: qValue
    ))
  
  # q値で降順にソート
  result.sort(proc(x, y: EncodingWithQValue): int =
    if x.qValue > y.qValue: return -1
    if x.qValue < y.qValue: return 1
    return 0
  )

# Rangeヘッダーをパースする
proc parseRange*(value: string): seq[ByteRange] =
  result = @[]
  
  # "bytes=" プレフィックスを確認
  if not value.startsWith("bytes="):
    raise newException(HttpHeaderException, "Invalid Range header: missing 'bytes=' prefix")
  
  let rangeStr = value[6..^1]  # "bytes=" の後の部分
  let ranges = rangeStr.split(',')
  
  for r in ranges:
    let r = r.strip()
    if r.len == 0:
      continue
    
    let parts = r.split('-')
    if parts.len != 2:
      raise newException(HttpHeaderException, "Invalid Range header format")
    
    var startPos, endPos: Option[int]
    
    # 開始位置をパース
    let startStr = parts[0].strip()
    if startStr.len > 0:
      try:
        startPos = some(parseInt(startStr))
        if startPos.get() < 0:
          raise newException(HttpHeaderException, "Invalid Range header: negative start position")
      except ValueError:
        raise newException(HttpHeaderException, "Invalid Range header: start position is not a number")
    else:
      startPos = none(int)
    
    # 終了位置をパース
    let endStr = parts[1].strip()
    if endStr.len > 0:
      try:
        endPos = some(parseInt(endStr))
        if endPos.get() < 0:
          raise newException(HttpHeaderException, "Invalid Range header: negative end position")
      except ValueError:
        raise newException(HttpHeaderException, "Invalid Range header: end position is not a number")
    else:
      endPos = none(int)
    
    # 範囲の妥当性を確認
    if startPos.isNone and endPos.isNone:
      raise newException(HttpHeaderException, "Invalid Range header: both start and end positions are missing")
    
    if startPos.isSome and endPos.isSome and startPos.get() > endPos.get():
      raise newException(HttpHeaderException, "Invalid Range header: start position is greater than end position")
    
    result.add(ByteRange(
      startPos: startPos,
      endPos: endPos
    ))

# Forwardedヘッダーをパースする
proc parseForwarded*(value: string): seq[ForwardedInfo] =
  result = @[]
  
  let forwardedElements = value.split(',')
  for element in forwardedElements:
    let element = element.strip()
    if element.len == 0:
      continue
    
    var info = ForwardedInfo(
      by: none(string),
      forAddr: none(string),
      host: none(string),
      proto: none(string)
    )
    
    let pairs = element.split(';')
    for pair in pairs:
      let parts = pair.strip().split('=', maxsplit=1)
      if parts.len != 2:
        continue
      
      let name = parts[0].strip().toLowerAscii()
      var value = parts[1].strip()
      
      # 値が引用符で囲まれている場合、引用符を削除
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1..^2]
      
      case name
      of "by":
        info.by = some(value)
      of "for":
        info.forAddr = some(value)
      of "host":
        info.host = some(value)
      of "proto":
        info.proto = some(value)
    
    result.add(info)

# X-Forwarded-Forヘッダーをパースする
proc parseXForwardedFor*(value: string): seq[string] =
  result = @[]
  
  let ips = value.split(',')
  for ip in ips:
    let ip = ip.strip()
    if ip.len > 0:
      result.add(ip)

# Cookieヘッダーをパースする
proc parseCookie*(value: string): Table[string, string] =
  result = initTable[string, string]()
  
  let pairs = value.split(';')
  for pair in pairs:
    let parts = pair.strip().split('=', maxsplit=1)
    if parts.len == 2:
      let name = parts[0].strip()
      let value = parts[1].strip()
      
      # 値が引用符で囲まれている場合、引用符を削除
      var cookieValue = value
      if cookieValue.len >= 2 and cookieValue[0] == '"' and cookieValue[^1] == '"':
        cookieValue = cookieValue[1..^2]
      
      result[name] = cookieValue

# Set-Cookieヘッダーをパースする
proc parseSetCookie*(value: string): tuple[name, value: string, attributes: CookieAttributes] =
  var name, cookieValue: string
  var attributes = CookieAttributes(
    secure: false,
    httpOnly: false
  )
  
  let parts = value.split(';')
  if parts.len > 0:
    let nameValue = parts[0].strip().split('=', maxsplit=1)
    if nameValue.len == 2:
      name = nameValue[0].strip()
      cookieValue = nameValue[1].strip()
      
      # 値が引用符で囲まれている場合、引用符を削除
      if cookieValue.len >= 2 and cookieValue[0] == '"' and cookieValue[^1] == '"':
        cookieValue = cookieValue[1..^2]
  
  for i in 1..<parts.len:
    let attr = parts[i].strip()
    if attr.len == 0:
      continue
    
    let attrParts = attr.split('=', maxsplit=1)
    let attrName = attrParts[0].strip().toLowerAscii()
    
    if attrParts.len == 1:
      # 値のない属性
      case attrName
      of "secure":
        attributes.secure = true
      of "httponly":
        attributes.httpOnly = true
      else:
        attributes.extensions.add(attrName)
    else:
      # 値のある属性
      var attrValue = attrParts[1].strip()
      
      # 値が引用符で囲まれている場合、引用符を削除
      if attrValue.len >= 2 and attrValue[0] == '"' and attrValue[^1] == '"':
        attrValue = attrValue[1..^2]
      
      case attrName
      of "expires":
        try:
          # HTTP日付形式をパース
          let dt = parse(attrValue, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
          attributes.expires = some(dt)
        except:
          # パースエラーは無視
          discard
      of "max-age":
        try:
          attributes.maxAge = some(parseInt(attrValue))
        except ValueError:
          # パースエラーは無視
          discard
      of "domain":
        attributes.domain = some(attrValue)
      of "path":
        attributes.path = some(attrValue)
      of "samesite":
        attributes.sameSite = some(attrValue)
      else:
        attributes.extensions.add(attrName & "=" & attrValue)
  
  result = (name, cookieValue, attributes)

# Link ヘッダーをパースする
proc parseLink*(value: string): seq[LinkValue] =
  result = @[]
  
  let links = value.split(',')
  for link in links:
    let link = link.strip()
    if link.len == 0:
      continue
    
    var url: string
    var rel, title, mediaType: Option[string]
    var otherParams = initTable[string, string]()
    
    # URLを取得 <url> 形式
    let urlStart = link.find('<')
    let urlEnd = link.find('>')
    
    if urlStart == -1 or urlEnd == -1 or urlStart >= urlEnd:
      continue  # 無効なフォーマット
    
    url = link[urlStart+1..<urlEnd]
    
    # パラメータを解析
    var i = urlEnd + 1
    while i < link.len:
      # セミコロンを探す
      while i < link.len and (link[i] == ';' or link[i] == ' '):
        inc(i)
      
      if i >= link.len:
        break
      
      # パラメータ名を取得
      var nameStart = i
      while i < link.len and link[i] != '=':
        inc(i)
      
      if i >= link.len:
        break
      
      let paramName = link[nameStart..<i].strip()
      inc(i)  # '='をスキップ
      
      # パラメータ値を取得
      var valueStart = i
      var inQuotes = false
      if i < link.len and link[i] == '"':
        inQuotes = true
        inc(valueStart)
        inc(i)
      
      while i < link.len:
        if inQuotes and link[i] == '"' and (i == 0 or link[i-1] != '\\'):
          break
        if not inQuotes and (link[i] == ';' or link[i] == ','):
          break
        inc(i)
      
      var paramValue: string
      if inQuotes:
        paramValue = link[valueStart..<i]
        inc(i)  # '"'をスキップ
      else:
        paramValue = link[valueStart..<i].strip()
      
      # パラメータを設定
      case paramName.toLowerAscii()
      of "rel":
        rel = some(paramValue)
      of "title":
        title = some(paramValue)
      of "type":
        mediaType = some(paramValue)
      else:
        otherParams[paramName] = paramValue
      
      # 次のパラメータまでスキップ
      while i < link.len and link[i] != ';' and link[i] != ',':
        inc(i)
      
      if i < link.len and link[i] == ',':
        break  # 次のリンクへ
    
    result.add(LinkValue(
      url: url,
      rel: rel,
      title: title,
      mediaType: mediaType,
      otherParams: otherParams
    ))

# WWW-Authenticate / Proxy-Authenticate ヘッダーをパースする
proc parseAuthChallenge*(value: string): seq[AuthChallenge] =
  result = @[]
  
  var i = 0
  while i < value.len:
    # 認証スキームを取得
    var schemeStart = i
    while i < value.len and value[i] != ' ' and value[i] != ',':
      inc(i)
    
    let scheme = value[schemeStart..<i].strip()
    
    var params = initTable[string, string]()
    
    # パラメータを解析
    while i < value.len and value[i] != ',':
      # スペースをスキップ
      while i < value.len and value[i] == ' ':
        inc(i)
      
      if i >= value.len or value[i] == ',':
        break
      
      # パラメータ名を取得
      var nameStart = i
      while i < value.len and value[i] != '=':
        inc(i)
      
      if i >= value.len:
        break
      
      let paramName = value[nameStart..<i].strip()
      inc(i)  # '='をスキップ
      
      # パラメータ値を取得
      var valueStart = i
      var inQuotes = false
      if i < value.len and value[i] == '"':
        inQuotes = true
        inc(valueStart)
        inc(i)
      
      while i < value.len:
        if inQuotes and value[i] == '"' and (i == 0 or value[i-1] != '\\'):
          break
        if not inQuotes and (value[i] == ' ' or value[i] == ','):
          break
        inc(i)
      
      var paramValue: string
      if inQuotes:
        paramValue = value[valueStart..<i]
        inc(i)  # '"'をスキップ
      else:
        paramValue = value[valueStart..<i].strip()
      
      params[paramName] = paramValue
      
      # 次のパラメータをスキップ
      while i < value.len and value[i] != ',' and value[i] != ' ':
        inc(i)
    
    result.add(AuthChallenge(
      scheme: scheme,
      params: params
    ))
    
    # カンマをスキップして次の認証スキームへ
    if i < value.len and value[i] == ',':
      inc(i)

# Vary ヘッダーをパースする
proc parseVary*(value: string): VaryValue =
  if value.strip() == "*":
    return VaryValue(kind: VaryAll)
  
  var headerNames: seq[string] = @[]
  let fields = value.split(',')
  for field in fields:
    let name = field.strip()
    if name.len > 0:
      headerNames.add(name)
  
  return VaryValue(kind: VarySpecific, headerNames: headerNames)

# Connection ヘッダーをパースする
proc parseConnection*(value: string): seq[ConnectionOption] =
  result = @[]
  
  let options = value.split(',')
  for opt in options:
    let opt = opt.strip().toLowerAscii()
    
    case opt
    of "close":
      result.add(ConnClose)
    of "keep-alive":
      result.add(ConnKeepAlive)
    of "upgrade":
      result.add(ConnUpgrade)
    else:
      # 他のオプションは無視
      discard 