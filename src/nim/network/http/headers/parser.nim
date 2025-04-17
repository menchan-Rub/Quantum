import std/[strutils, tables, options, parseutils, strformat, sequtils]
import ./types, ./constants

type
  HeaderParseError* = enum
    NoError,
    InvalidFormat,       # ヘッダー全体のフォーマットが不正
    InvalidName,         # ヘッダー名が不正
    InvalidValue,        # ヘッダー値が不正
    EmptyHeader,         # 空のヘッダー
    DuplicateHeader,     # 重複するヘッダー名（許可しない場合）
    HeaderTooLong,       # ヘッダーが長すぎる
    TooManyHeaders,      # ヘッダーの数が多すぎる
    MalformedHeaderLine  # ヘッダー行の形式が不正

  ParserConfig* = object
    maxHeaderNameLength*: int       # ヘッダー名の最大長
    maxHeaderValueLength*: int      # ヘッダー値の最大長
    maxHeaderCount*: int            # ヘッダーの最大数
    allowDuplicateHeaders*: bool    # 重複ヘッダーを許可するか
    foldLongValues*: bool           # 長いヘッダー値を折り返すか
    caseSensitiveNames*: bool       # ヘッダー名が大文字・小文字を区別するか
    strictParsing*: bool            # 厳密なパース（RFC準拠）を行うか
    trimWhitespace*: bool           # ヘッダー値の先頭と末尾の空白を削除するか

  HeaderParser* = object
    config*: ParserConfig
    lastError*: HeaderParseError
    lastErrorMessage*: string

const
  DefaultMaxHeaderNameLength* = 100
  DefaultMaxHeaderValueLength* = 8192
  DefaultMaxHeaderCount* = 100
  LineFoldingChars* = {' ', '\t'}
  ValidHeaderNameChars* = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}

proc newParserConfig*(): ParserConfig =
  ## デフォルトのパーサー設定を作成する
  result.maxHeaderNameLength = DefaultMaxHeaderNameLength
  result.maxHeaderValueLength = DefaultMaxHeaderValueLength
  result.maxHeaderCount = DefaultMaxHeaderCount
  result.allowDuplicateHeaders = true
  result.foldLongValues = true
  result.caseSensitiveNames = false
  result.strictParsing = true
  result.trimWhitespace = true

proc newHeaderParser*(): HeaderParser =
  ## 新しいHTTPヘッダーパーサーを作成する
  result.config = newParserConfig()
  result.lastError = NoError
  result.lastErrorMessage = ""

proc newHeaderParser*(config: ParserConfig): HeaderParser =
  ## 指定された設定で新しいHTTPヘッダーパーサーを作成する
  result.config = config
  result.lastError = NoError
  result.lastErrorMessage = ""

proc setError(parser: var HeaderParser, error: HeaderParseError, message: string = "") =
  ## パーサーのエラー状態を設定する
  parser.lastError = error
  parser.lastErrorMessage = message

proc resetError(parser: var HeaderParser) =
  ## パーサーのエラー状態をリセットする
  parser.lastError = NoError
  parser.lastErrorMessage = ""

proc isValidHeaderName(name: string, strictParsing: bool): bool =
  ## ヘッダー名が有効かどうかを確認する
  if name.len == 0:
    return false
  
  if strictParsing:
    # RFC7230に準拠したヘッダー名の検証
    # token = 1*tchar
    # tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    let validChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'} + 
                    {'0'..'9', 'a'..'z', 'A'..'Z'}
    for c in name:
      if c notin validChars:
        return false
  else:
    # より寛容な検証
    for c in name:
      if c notin ValidHeaderNameChars and c != '.':
        return false
  
  return true

proc normalizeHeaderName(name: string, caseSensitive: bool): string =
  ## ヘッダー名を正規化する
  if caseSensitive:
    return name
  else:
    return name.toLowerAscii()

proc parseHeaderLine(parser: var HeaderParser, line: string): Option[(string, string)] =
  ## 1行のヘッダーをパースする
  parser.resetError()
  
  if line.len == 0:
    parser.setError(EmptyHeader, "Empty header line")
    return none((string, string))
  
  let colonPos = line.find(':')
  if colonPos < 0:
    parser.setError(InvalidFormat, "No colon found in header line")
    return none((string, string))
  
  let 
    rawName = line[0..<colonPos]
    rawValue = if colonPos + 1 < line.len: line[colonPos + 1..^1] else: ""
  
  # ヘッダー名のバリデーション
  if rawName.len == 0:
    parser.setError(InvalidName, "Empty header name")
    return none((string, string))
  
  if rawName.len > parser.config.maxHeaderNameLength:
    parser.setError(HeaderTooLong, fmt"Header name too long: {rawName.len} > {parser.config.maxHeaderNameLength}")
    return none((string, string))
  
  if not isValidHeaderName(rawName, parser.config.strictParsing):
    parser.setError(InvalidName, fmt"Invalid header name: '{rawName}'")
    return none((string, string))
  
  # ヘッダー値のバリデーション
  var value = rawValue
  if parser.config.trimWhitespace:
    value = value.strip()
  
  if value.len > parser.config.maxHeaderValueLength:
    parser.setError(HeaderTooLong, fmt"Header value too long: {value.len} > {parser.config.maxHeaderValueLength}")
    return none((string, string))
  
  # ヘッダー名の正規化
  let name = normalizeHeaderName(rawName, parser.config.caseSensitiveNames)
  
  return some((name, value))

proc parseRawHeaders*(parser: var HeaderParser, rawHeaders: string): HttpHeaders =
  ## 生のヘッダーテキストをパースしてHttpHeadersを返す
  result = newHttpHeaders()
  if rawHeaders.len == 0:
    return result
  
  parser.resetError()
  var 
    headerCount = 0
    lines = rawHeaders.splitLines()
    i = 0
    currentHeader: Option[(string, string)] = none((string, string))
  
  while i < lines.len:
    var line = lines[i]
    i.inc
    
    # 空行はヘッダーの終わりを示す
    if line.len == 0:
      continue
    
    # 行の折り返しの処理
    if i < lines.len and lines[i].len > 0 and lines[i][0] in LineFoldingChars:
      # 複数行にわたるヘッダー値の連結
      while i < lines.len and lines[i].len > 0 and lines[i][0] in LineFoldingChars:
        line &= " " & lines[i].strip(leading=true)
        i.inc
    
    # ヘッダー行のパース
    currentHeader = parser.parseHeaderLine(line)
    if currentHeader.isNone:
      if parser.config.strictParsing:
        parser.setError(MalformedHeaderLine, fmt"Malformed header line: '{line}'")
        return newHttpHeaders() # 厳密モードでは失敗
      continue # 寛容モードでは次のヘッダーへ
    
    let (name, value) = currentHeader.get
    
    # ヘッダーが多すぎる場合のチェック
    headerCount.inc
    if headerCount > parser.config.maxHeaderCount:
      parser.setError(TooManyHeaders, fmt"Too many headers: {headerCount} > {parser.config.maxHeaderCount}")
      if parser.config.strictParsing:
        return newHttpHeaders()
      break
    
    # 重複ヘッダーのチェック
    if not parser.config.allowDuplicateHeaders and result.hasKey(name):
      parser.setError(DuplicateHeader, fmt"Duplicate header: '{name}'")
      if parser.config.strictParsing:
        return newHttpHeaders()
      continue
    
    # ヘッダーの追加
    if result.hasKey(name) and parser.config.allowDuplicateHeaders:
      result[name].add(value)
    else:
      result[name] = @[value]
  
  return result

proc parseSingleHeader*(parser: var HeaderParser, headerLine: string): Option[(string, string)] =
  ## 単一のヘッダー行をパースする
  parser.resetError()
  return parser.parseHeaderLine(headerLine)

proc parseHeaderList*(parser: var HeaderParser, headerLines: openArray[string]): HttpHeaders =
  ## ヘッダー行のリストをパースする
  result = newHttpHeaders()
  parser.resetError()
  
  var 
    headerCount = 0
    i = 0
    currentLine: string
    currentHeader: Option[(string, string)]
  
  while i < headerLines.len:
    currentLine = headerLines[i]
    i.inc
    
    # 空行は無視
    if currentLine.len == 0:
      continue
    
    # 行の折り返しの処理
    if i < headerLines.len and headerLines[i].len > 0 and headerLines[i][0] in LineFoldingChars:
      # 複数行にわたるヘッダー値の連結
      while i < headerLines.len and headerLines[i].len > 0 and headerLines[i][0] in LineFoldingChars:
        currentLine &= " " & headerLines[i].strip(leading=true)
        i.inc
    
    # ヘッダー行のパース
    currentHeader = parser.parseHeaderLine(currentLine)
    if currentHeader.isNone:
      if parser.config.strictParsing:
        return newHttpHeaders() # 厳密モードでは失敗
      continue # 寛容モードでは次のヘッダーへ
    
    let (name, value) = currentHeader.get
    
    # ヘッダーが多すぎる場合のチェック
    headerCount.inc
    if headerCount > parser.config.maxHeaderCount:
      parser.setError(TooManyHeaders, fmt"Too many headers: {headerCount} > {parser.config.maxHeaderCount}")
      if parser.config.strictParsing:
        return newHttpHeaders()
      break
    
    # 重複ヘッダーのチェック
    if not parser.config.allowDuplicateHeaders and result.hasKey(name):
      parser.setError(DuplicateHeader, fmt"Duplicate header: '{name}'")
      if parser.config.strictParsing:
        return newHttpHeaders()
      continue
    
    # ヘッダーの追加
    if result.hasKey(name) and parser.config.allowDuplicateHeaders:
      result[name].add(value)
    else:
      result[name] = @[value]
  
  return result

proc parseContentType*(contentType: string): Option[(string, Table[string, string])] =
  ## Content-Typeヘッダーをパースする
  ## 返値は (mediaType, parameters) のタプル
  var 
    i = 0
    mediaType = ""
    parameters = initTable[string, string]()
  
  # メディアタイプのパース
  i += contentType.parseUntil(mediaType, {';'}, i)
  mediaType = mediaType.strip().toLowerAscii()
  
  # パラメータが無い場合
  if i >= contentType.len:
    return some((mediaType, parameters))
  
  # セミコロンをスキップ
  i.inc
  
  # パラメータのパース
  while i < contentType.len:
    var 
      paramName = ""
      paramValue = ""
    
    # 余分な空白をスキップ
    while i < contentType.len and contentType[i] in Whitespace:
      i.inc
    
    # パラメータ名のパース
    i += contentType.parseUntil(paramName, {'='}, i)
    paramName = paramName.strip().toLowerAscii()
    
    if i >= contentType.len or contentType[i] != '=':
      # パラメータ値が無い場合
      if paramName.len > 0:
        parameters[paramName] = ""
      break
    
    # '='をスキップ
    i.inc
    
    # パラメータ値のパース
    if i < contentType.len and contentType[i] == '"':
      # 引用符で囲まれた値
      i.inc  # 開始引用符をスキップ
      i += contentType.parseUntil(paramValue, {'"'}, i)
      i.inc  # 終了引用符をスキップ
    else:
      # 引用符なしの値
      i += contentType.parseUntil(paramValue, {';'}, i)
      paramValue = paramValue.strip()
    
    # パラメータの追加
    if paramName.len > 0:
      parameters[paramName] = paramValue
    
    # 次のパラメータへ
    if i < contentType.len and contentType[i] == ';':
      i.inc
  
  return some((mediaType, parameters))

proc parseContentTypeHeader*(headers: HttpHeaders): Option[(string, Table[string, string])] =
  ## HttpHeadersからContent-Typeをパースする
  let contentType = headers.getFirstValue("content-type")
  if contentType.len == 0:
    return none((string, Table[string, string]))
  
  return parseContentType(contentType)

proc parseCookieHeader*(cookieHeader: string): Table[string, string] =
  ## Cookieヘッダーをパースする
  ## 返値はname=valueのテーブル
  result = initTable[string, string]()
  
  var cookiePairs = cookieHeader.split(';')
  for pair in cookiePairs:
    let trimmedPair = pair.strip()
    if trimmedPair.len == 0:
      continue
    
    let eqPos = trimmedPair.find('=')
    if eqPos < 0:
      # 値のないcookieの場合
      result[trimmedPair] = ""
    else:
      let 
        name = trimmedPair[0..<eqPos].strip()
        value = if eqPos + 1 < trimmedPair.len: trimmedPair[eqPos + 1..^1].strip() else: ""
      
      if name.len > 0:
        result[name] = value

proc parseAcceptHeader*(acceptHeader: string): seq[(string, float)] =
  ## Acceptヘッダーをパースする
  ## 返値は (mediaType, quality) のシーケンス
  result = @[]
  
  let parts = acceptHeader.split(',')
  for part in parts:
    var 
      mediaType = ""
      quality = 1.0
      trimmedPart = part.strip()
    
    if trimmedPart.len == 0:
      continue
    
    let qPos = trimmedPart.find(";q=")
    if qPos < 0:
      mediaType = trimmedPart
    else:
      mediaType = trimmedPart[0..<qPos].strip()
      let qValStr = trimmedPart[qPos + 3..^1].strip()
      try:
        quality = parseFloat(qValStr)
      except:
        quality = 1.0
    
    result.add((mediaType, quality))
  
  # 品質値でソート (降順)
  result.sort(proc(x, y: (string, float)): int =
    if x[1] > y[1]: -1
    elif x[1] < y[1]: 1
    else: 0
  )

proc parseRange*(rangeHeader: string): Option[(string, seq[(int, int)])] =
  ## Rangeヘッダーをパースする
  ## 返値は (unit, ranges) のタプル
  ## rangesは (start, end) のシーケンス（endは-1で無限を表す）
  var 
    unit = ""
    ranges: seq[(int, int)] = @[]
    eqPos = rangeHeader.find('=')
  
  if eqPos < 0:
    return none((string, seq[(int, int)]))
  
  unit = rangeHeader[0..<eqPos].strip()
  let rangeStr = rangeHeader[eqPos + 1..^1]
  
  for r in rangeStr.split(','):
    let trimmedR = r.strip()
    if trimmedR.len == 0:
      continue
    
    let dashPos = trimmedR.find('-')
    if dashPos < 0:
      continue
    
    var startPos, endPos: int
    
    # 開始位置のパース
    if dashPos == 0:
      # -N の形式 (最後のN bytes)
      try:
        endPos = parseInt(trimmedR[1..^1])
        startPos = -1  # 特別な値で最後のN bytesを表す
      except:
        continue
    else:
      # N- または N-M の形式
      try:
        startPos = parseInt(trimmedR[0..<dashPos])
        
        if dashPos + 1 < trimmedR.len:
          endPos = parseInt(trimmedR[dashPos + 1..^1])
        else:
          endPos = -1  # 無限を表す
      except:
        continue
    
    ranges.add((startPos, endPos))
  
  if ranges.len == 0:
    return none((string, seq[(int, int)]))
  
  return some((unit, ranges))

proc parseConnectionHeader*(connectionHeader: string): seq[string] =
  ## Connectionヘッダーをパースする
  ## 返値は指定されたトークンのシーケンス
  result = @[]
  
  for token in connectionHeader.split(','):
    let trimmedToken = token.strip().toLowerAscii()
    if trimmedToken.len > 0:
      result.add(trimmedToken)

proc parseAuthorizationHeader*(authHeader: string): Option[(string, string)] =
  ## Authorizationヘッダーをパースする
  ## 返値は (scheme, credentials) のタプル
  if authHeader.len == 0:
    return none((string, string))
  
  let spacePos = authHeader.find(' ')
  if spacePos < 0:
    # スペースがない場合はスキーム全体とみなす
    return some((authHeader.strip(), ""))
  
  let 
    scheme = authHeader[0..<spacePos].strip()
    credentials = authHeader[spacePos + 1..^1].strip()
  
  return some((scheme, credentials))

proc parseForwardedHeader*(forwardedHeader: string): seq[Table[string, string]] =
  ## Forwardedヘッダーをパースする
  ## 返値はフォワード情報の配列
  result = @[]
  
  for fwdPart in forwardedHeader.split(','):
    var forwardInfo = initTable[string, string]()
    let trimmedPart = fwdPart.strip()
    
    for param in trimmedPart.split(';'):
      let trimmedParam = param.strip()
      if trimmedParam.len == 0:
        continue
      
      let eqPos = trimmedParam.find('=')
      if eqPos < 0:
        # 値のないパラメータの場合
        forwardInfo[trimmedParam.toLowerAscii()] = ""
      else:
        var 
          name = trimmedParam[0..<eqPos].strip().toLowerAscii()
          value = if eqPos + 1 < trimmedParam.len: trimmedParam[eqPos + 1..^1].strip() else: ""
        
        # 引用符を削除
        if value.len >= 2 and value[0] == '"' and value[^1] == '"':
          value = value[1..^2]
        
        forwardInfo[name] = value
    
    if forwardInfo.len > 0:
      result.add(forwardInfo)

proc parseCacheControlHeader*(cacheControl: string): Table[string, string] =
  ## Cache-Controlヘッダーをパースする
  ## 返値はディレクティブと値のテーブル
  result = initTable[string, string]()
  
  for directive in cacheControl.split(','):
    let trimmedDirective = directive.strip()
    if trimmedDirective.len == 0:
      continue
    
    let eqPos = trimmedDirective.find('=')
    if eqPos < 0:
      # 値のないディレクティブの場合
      result[trimmedDirective.toLowerAscii()] = ""
    else:
      let 
        name = trimmedDirective[0..<eqPos].strip().toLowerAscii()
        value = if eqPos + 1 < trimmedDirective.len: trimmedDirective[eqPos + 1..^1].strip() else: ""
      
      # 引用符を削除
      var cleanValue = value
      if cleanValue.len >= 2 and cleanValue[0] == '"' and cleanValue[^1] == '"':
        cleanValue = cleanValue[1..^2]
      
      result[name] = cleanValue

proc getLastError*(parser: HeaderParser): (HeaderParseError, string) =
  ## パーサーの最後のエラーを取得する
  return (parser.lastError, parser.lastErrorMessage)

proc hasError*(parser: HeaderParser): bool =
  ## パーサーにエラーがあるかどうかを確認する
  return parser.lastError != NoError 