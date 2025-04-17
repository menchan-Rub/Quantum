# data_sanitizer.nim
## データサニタイゼーションモジュール
## ブラウザから送信されるデータやWebサイトから受信するデータを安全にサニタイズする

import std/[
  options,
  tables,
  sets,
  hashes,
  strutils,
  strformat,
  sequtils,
  algorithm,
  times,
  random,
  json,
  logging,
  math,
  re,
  uri,
  htmlparser,
  xmltree
]

type
  DataSanitizer* = ref DataSanitizerObj
  DataSanitizerObj = object
    enabled*: bool                         ## 有効フラグ
    sanitizationLevel*: SanitizationLevel  ## サニタイズレベル
    urlSanitizer*: UrlSanitizer            ## URL処理
    htmlSanitizer*: HtmlSanitizer          ## HTML処理
    jsonSanitizer*: JsonSanitizer          ## JSON処理
    headerSanitizer*: HeaderSanitizer      ## HTTPヘッダー処理
    logger*: Logger                        ## ロガー
    allowedDomains*: HashSet[string]       ## 許可ドメイン
    allowedSchemes*: HashSet[string]       ## 許可スキーム
    customRules*: Table[string, string]    ## カスタムルール

  SanitizationLevel* = enum
    slMinimal,    ## 最小限のサニタイズ
    slStandard,   ## 標準的なサニタイズ
    slStrict,     ## 厳格なサニタイズ
    slCustom      ## カスタム設定

  UrlSanitizer* = ref UrlSanitizerObj
  UrlSanitizerObj = object
    maxLength*: int                      ## 最大URL長
    blockedParams*: HashSet[string]      ## ブロックするパラメータ
    trackingParams*: HashSet[string]     ## トラッキングパラメータ

  HtmlSanitizer* = ref HtmlSanitizerObj
  HtmlSanitizerObj = object
    allowedTags*: HashSet[string]        ## 許可するタグ
    allowedAttributes*: Table[string, HashSet[string]]  ## 許可する属性
    allowedProtocols*: HashSet[string]   ## 許可するプロトコル

  JsonSanitizer* = ref JsonSanitizerObj
  JsonSanitizerObj = object
    maxDepth*: int                       ## 最大ネスト深度
    maxLength*: int                      ## 最大文字列長
    sensitiveKeys*: HashSet[string]      ## 機密キー

  HeaderSanitizer* = ref HeaderSanitizerObj
  HeaderSanitizerObj = object
    blockedHeaders*: HashSet[string]     ## ブロックするヘッダー
    privacyHeaders*: Table[string, string]  ## プライバシー保護ヘッダー

const
  # デフォルトの許可するHTMLタグ（標準レベル）
  DEFAULT_ALLOWED_TAGS = [
    "a", "abbr", "address", "article", "aside", "b", "blockquote", "br",
    "caption", "cite", "code", "col", "colgroup", "dd", "div", "dl", "dt",
    "em", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
    "header", "hr", "i", "img", "li", "main", "nav", "ol", "p", "pre", "q",
    "section", "span", "strong", "sub", "sup", "table", "tbody", "td",
    "tfoot", "th", "thead", "tr", "u", "ul"
  ].toHashSet

  # デフォルトのブロックするトラッキングパラメータ
  DEFAULT_TRACKING_PARAMS = [
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "msclkid", "zanpid", "dclid", "igshid"
  ].toHashSet

  # デフォルトのブロックするHTTPヘッダー
  DEFAULT_BLOCKED_HEADERS = [
    "X-Forwarded-For", "Referer", "User-Agent", "Via", "From", "Cookie"
  ].toHashSet

  # デフォルトのプライバシー保護HTTPヘッダー
  DEFAULT_PRIVACY_HEADERS = {
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "X-XSS-Protection": "1; mode=block"
  }.toTable

  # デフォルトの機密JSONキー
  DEFAULT_SENSITIVE_KEYS = [
    "password", "token", "secret", "api_key", "apiKey", "key", "credential",
    "auth", "session", "cookie", "ssn", "credit_card", "creditCard", "cvv"
  ].toHashSet

# ユーティリティ関数
proc createDefaultUrlSanitizer(): UrlSanitizer =
  ## デフォルトのURLサニタイザを作成
  new(result)
  result.maxLength = 2048
  result.blockedParams = initHashSet[string]()
  result.trackingParams = DEFAULT_TRACKING_PARAMS

proc createDefaultHtmlSanitizer(): HtmlSanitizer =
  ## デフォルトのHTMLサニタイザを作成
  new(result)
  result.allowedTags = DEFAULT_ALLOWED_TAGS
  result.allowedAttributes = initTable[string, HashSet[string]]()
  
  # グローバル属性
  let globalAttrs = ["class", "id", "lang", "title"].toHashSet
  
  # 要素別の許可属性
  result.allowedAttributes["a"] = ["href", "target", "rel"].toHashSet + globalAttrs
  result.allowedAttributes["img"] = ["src", "alt", "width", "height", "loading"].toHashSet + globalAttrs
  result.allowedAttributes["table"] = ["border", "cellpadding", "cellspacing", "width"].toHashSet + globalAttrs
  result.allowedAttributes["th"] = ["scope", "colspan", "rowspan"].toHashSet + globalAttrs
  result.allowedAttributes["td"] = ["colspan", "rowspan"].toHashSet + globalAttrs
  
  result.allowedProtocols = ["http", "https", "mailto", "tel"].toHashSet

proc createDefaultJsonSanitizer(): JsonSanitizer =
  ## デフォルトのJSONサニタイザを作成
  new(result)
  result.maxDepth = 20
  result.maxLength = 10 * 1024 * 1024  # 10MB
  result.sensitiveKeys = DEFAULT_SENSITIVE_KEYS

proc createDefaultHeaderSanitizer(): HeaderSanitizer =
  ## デフォルトのHTTPヘッダーサニタイザを作成
  new(result)
  result.blockedHeaders = DEFAULT_BLOCKED_HEADERS
  result.privacyHeaders = DEFAULT_PRIVACY_HEADERS

proc newDataSanitizer*(level: SanitizationLevel = slStandard): DataSanitizer =
  ## 新しいデータサニタイザを作成
  new(result)
  result.enabled = true
  result.sanitizationLevel = level
  result.urlSanitizer = createDefaultUrlSanitizer()
  result.htmlSanitizer = createDefaultHtmlSanitizer()
  result.jsonSanitizer = createDefaultJsonSanitizer()
  result.headerSanitizer = createDefaultHeaderSanitizer()
  result.logger = newConsoleLogger()
  result.allowedDomains = initHashSet[string]()
  result.allowedSchemes = ["http", "https", "ftp", "ftps", "mailto", "tel", "data"].toHashSet
  result.customRules = initTable[string, string]()
  
  # レベルに基づいて設定を調整
  case level
  of slMinimal:
    # 最小限の制限
    result.headerSanitizer.blockedHeaders = ["User-Agent"].toHashSet
    result.urlSanitizer.maxLength = 4096
    # HTMLとJSONはデフォルト設定のまま
  
  of slStandard:
    # デフォルト設定はそのまま使用
    discard
  
  of slStrict:
    # より厳格な制限
    result.urlSanitizer.maxLength = 1024
    
    # HTMLの許可タグを制限
    result.htmlSanitizer.allowedTags = [
      "a", "b", "br", "div", "em", "h1", "h2", "h3", "h4", "h5", "h6",
      "i", "li", "ol", "p", "span", "strong", "ul"
    ].toHashSet
    
    # JSON深度の制限を厳しく
    result.jsonSanitizer.maxDepth = 10
    result.jsonSanitizer.maxLength = 1 * 1024 * 1024  # 1MB
  
  of slCustom:
    # カスタム設定はユーザーが後で設定
    discard

# 基本メソッド
proc enable*(sanitizer: DataSanitizer) =
  ## サニタイザを有効化
  sanitizer.enabled = true

proc disable*(sanitizer: DataSanitizer) =
  ## サニタイザを無効化
  sanitizer.enabled = false

proc isEnabled*(sanitizer: DataSanitizer): bool =
  ## サニタイザが有効かどうか
  return sanitizer.enabled

proc setLevel*(sanitizer: DataSanitizer, level: SanitizationLevel) =
  ## サニタイズレベルを設定
  sanitizer.sanitizationLevel = level
  
  # レベルに基づいて設定を再調整
  let newSanitizer = newDataSanitizer(level)
  sanitizer.urlSanitizer = newSanitizer.urlSanitizer
  sanitizer.htmlSanitizer = newSanitizer.htmlSanitizer
  sanitizer.jsonSanitizer = newSanitizer.jsonSanitizer
  sanitizer.headerSanitizer = newSanitizer.headerSanitizer

proc allowDomain*(sanitizer: DataSanitizer, domain: string) =
  ## ドメインを許可リストに追加
  sanitizer.allowedDomains.incl(domain)

proc isDomainAllowed*(sanitizer: DataSanitizer, domain: string): bool =
  ## ドメインが許可リストに含まれているかどうか
  return domain in sanitizer.allowedDomains

proc addCustomRule*(sanitizer: DataSanitizer, name: string, rule: string) =
  ## カスタムサニタイズルールを追加
  sanitizer.customRules[name] = rule

# URLサニタイズ機能
proc sanitizeUrl*(sanitizer: DataSanitizer, url: string): string =
  ## URLをサニタイズ
  if not sanitizer.enabled:
    return url
  
  try:
    # URLをパース
    var uri = parseUri(url)
    
    # スキームの検証
    if uri.scheme != "" and uri.scheme notin sanitizer.allowedSchemes:
      return ""  # 禁止されたスキーム
    
    # ホストの検証
    let host = uri.hostname
    if host != "" and not sanitizer.isDomainAllowed(host):
      # ドメインが許可リストにない場合は一般的な検証を行う
      if host.contains("javascript:") or host.contains("data:"):
        return ""  # 危険な可能性のあるスキーム
    
    # URLの長さチェック
    if url.len > sanitizer.urlSanitizer.maxLength:
      return url[0..<sanitizer.urlSanitizer.maxLength]
    
    # トラッキングパラメータの削除
    if uri.query.len > 0:
      var params = uri.query.split('&')
      var filteredParams: seq[string] = @[]
      
      for param in params:
        let parts = param.split('=', 1)
        if parts.len > 0:
          let paramName = parts[0]
          if paramName notin sanitizer.urlSanitizer.trackingParams and
             paramName notin sanitizer.urlSanitizer.blockedParams:
            filteredParams.add(param)
      
      # 新しいクエリ文字列を構築
      uri.query = filteredParams.join("&")
    
    # サニタイズされたURLを返す
    result = $uri
    
  except:
    # パースエラーの場合は空文字列を返す
    sanitizer.logger.log(lvlError, "URL sanitization error: " & getCurrentExceptionMsg())
    result = ""

# HTMLサニタイズ機能
proc sanitizeHtml*(sanitizer: DataSanitizer, html: string): string =
  ## HTMLをサニタイズ
  if not sanitizer.enabled:
    return html
  
  try:
    # HTMLをパース
    let doc = parseHtml(html)
    
    # 禁止タグと属性を除去する再帰関数
    proc cleanNode(node: XmlNode): XmlNode =
      if node.kind == xnElement:
        # 許可タグのチェック
        if node.tag.toLowerAscii() notin sanitizer.htmlSanitizer.allowedTags:
          # タグが許可されていない場合はテキストのみ保持
          result = newElement("span")
          for child in node:
            if child.kind == xnText:
              result.add(child)
            else:
              let cleaned = cleanNode(child)
              if cleaned != nil:
                result.add(cleaned)
          return
        
        # 許可されたタグの場合は新しい要素を作成
        result = newElement(node.tag)
        
        # 許可された属性のみコピー
        let allowedAttrs = if node.tag in sanitizer.htmlSanitizer.allowedAttributes:
                              sanitizer.htmlSanitizer.allowedAttributes[node.tag]
                           else:
                              initHashSet[string]()
        
        for attrKey, attrVal in node.attrs:
          let lowerKey = attrKey.toLowerAscii()
          
          # 特別な処理が必要な属性
          if lowerKey == "href" or lowerKey == "src":
            # URLスキームの検証
            var uri = parseUri(attrVal)
            if uri.scheme != "" and uri.scheme notin sanitizer.htmlSanitizer.allowedProtocols:
              continue  # 禁止されたプロトコル
            
            # それ以外は通常のサニタイズ
            if lowerKey in allowedAttrs:
              let sanitizedUrl = sanitizer.sanitizeUrl(attrVal)
              if sanitizedUrl != "":
                result.attrs[attrKey] = sanitizedUrl
          elif lowerKey in allowedAttrs:
            # 通常の許可属性
            result.attrs[attrKey] = attrVal
        
        # スクリプトイベント属性を除去
        for attr in result.attrs.keys:
          if attr.toLowerAscii().startsWith("on"):
            result.attrs.del(attr)
        
        # 子ノードを再帰的に処理
        for child in node:
          let cleaned = cleanNode(child)
          if cleaned != nil:
            result.add(cleaned)
            
      elif node.kind == xnText:
        # テキストノードはそのまま
        result = node
      else:
        # コメントなどは無視
        result = nil
    
    # ルートから再帰的に処理
    let cleanedDoc = cleanNode(doc)
    if cleanedDoc == nil:
      return ""
    
    # 結果を文字列化
    result = $cleanedDoc
    
  except:
    # パースエラーの場合は空文字列を返す
    sanitizer.logger.log(lvlError, "HTML sanitization error: " & getCurrentExceptionMsg())
    result = ""

# JSONサニタイズ機能
proc sanitizeJson*(sanitizer: DataSanitizer, jsonStr: string): string =
  ## JSONをサニタイズ
  if not sanitizer.enabled:
    return jsonStr
  
  try:
    # 長さチェック
    if jsonStr.len > sanitizer.jsonSanitizer.maxLength:
      let truncated = jsonStr[0..<sanitizer.jsonSanitizer.maxLength]
      sanitizer.logger.log(lvlWarn, "JSON truncated due to length limit")
      return truncated
    
    # JSONパース
    let jsonNode = parseJson(jsonStr)
    
    # 機密情報をマスクする再帰関数
    proc maskSensitiveData(node: JsonNode, depth: int = 0): JsonNode =
      if depth > sanitizer.jsonSanitizer.maxDepth:
        # 深すぎる場合は省略
        return %* {"sanitized": "max depth exceeded"}
      
      case node.kind
      of JObject:
        result = newJObject()
        for key, value in node:
          if key.toLowerAscii() in sanitizer.jsonSanitizer.sensitiveKeys:
            # 機密キーの値をマスク
            result[key] = %* "***REDACTED***"
          else:
            # 再帰的に処理
            result[key] = maskSensitiveData(value, depth + 1)
      
      of JArray:
        result = newJArray()
        for item in node:
          result.add(maskSensitiveData(item, depth + 1))
      
      of JString:
        # 文字列長のチェック
        let str = node.getStr()
        if str.len > 1000:  # 長い文字列は短縮
          result = % (str[0..<997] & "...")
        else:
          result = node
      
      else:
        # その他の型はそのまま
        result = node
    
    # JSONを処理
    let sanitizedJson = maskSensitiveData(jsonNode)
    
    # 結果を文字列化
    result = $sanitizedJson
    
  except:
    # パースエラーの場合は元の文字列を返す
    sanitizer.logger.log(lvlError, "JSON sanitization error: " & getCurrentExceptionMsg())
    result = jsonStr

# HTTPヘッダーサニタイズ機能
proc sanitizeRequestHeaders*(
  sanitizer: DataSanitizer, 
  headers: TableRef[string, string]
): TableRef[string, string] =
  ## HTTPリクエストヘッダーをサニタイズ
  if not sanitizer.enabled:
    return headers
  
  result = newTable[string, string]()
  
  # ヘッダーをコピー（ブロックされたものを除く）
  for key, value in headers:
    if key.toLowerAscii() notin sanitizer.headerSanitizer.blockedHeaders:
      result[key] = value

proc sanitizeResponseHeaders*(
  sanitizer: DataSanitizer, 
  headers: TableRef[string, string]
): TableRef[string, string] =
  ## HTTPレスポンスヘッダーをサニタイズ
  if not sanitizer.enabled:
    return headers
  
  result = newTable[string, string]()
  
  # レスポンスヘッダーをコピー
  for key, value in headers:
    result[key] = value
  
  # プライバシー保護ヘッダーを追加
  for key, value in sanitizer.headerSanitizer.privacyHeaders:
    # 既存のヘッダーを上書きしない（サーバーの設定を尊重）
    if key notin result:
      result[key] = value

# ユーティリティ関数
proc sanitizeUserInput*(sanitizer: DataSanitizer, input: string): string =
  ## ユーザー入力をサニタイズ（XSS対策など）
  if not sanitizer.enabled:
    return input
  
  # HTMLタグを除去
  var result = input
  
  # "<" と ">" をHTMLエンティティに置換
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  
  # 引用符をHTMLエンティティに置換
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&#39;")
  
  # スクリプト実行可能なURLスキームを除去
  result = result.replace(re"(?i)javascript:", "")
  result = result.replace(re"(?i)data:", "")
  
  return result

proc getSanitizationStatus*(sanitizer: DataSanitizer): JsonNode =
  ## サニタイゼーション状態をJSON形式で取得
  result = %*{
    "enabled": sanitizer.enabled,
    "level": $sanitizer.sanitizationLevel,
    "urlSanitizer": {
      "maxLength": sanitizer.urlSanitizer.maxLength,
      "trackingParamsCount": sanitizer.urlSanitizer.trackingParams.len,
      "blockedParamsCount": sanitizer.urlSanitizer.blockedParams.len
    },
    "htmlSanitizer": {
      "allowedTagsCount": sanitizer.htmlSanitizer.allowedTags.len,
      "allowedProtocolsCount": sanitizer.htmlSanitizer.allowedProtocols.len
    },
    "jsonSanitizer": {
      "maxDepth": sanitizer.jsonSanitizer.maxDepth,
      "maxLength": sanitizer.jsonSanitizer.maxLength,
      "sensitiveKeysCount": sanitizer.jsonSanitizer.sensitiveKeys.len
    },
    "headerSanitizer": {
      "blockedHeadersCount": sanitizer.headerSanitizer.blockedHeaders.len,
      "privacyHeadersCount": sanitizer.headerSanitizer.privacyHeaders.len
    },
    "allowedDomains": sanitizer.allowedDomains.len,
    "allowedSchemes": sanitizer.allowedSchemes.len,
    "customRules": sanitizer.customRules.len
  }

when isMainModule:
  # テスト用コード
  let sanitizer = newDataSanitizer(slStandard)
  
  # URLサニタイズテスト
  let testUrl = "https://example.com/path?utm_source=test&id=123&utm_medium=email"
  echo "Original URL: ", testUrl
  echo "Sanitized URL: ", sanitizer.sanitizeUrl(testUrl)
  
  # HTMLサニタイズテスト
  let testHtml = """
  <div class="content">
    <h1>タイトル</h1>
    <p>テキスト <script>alert("XSS");</script></p>
    <a href="javascript:alert('evil')">悪意あるリンク</a>
    <a href="https://example.com" onclick="evil()">正常なリンク（悪意のあるonclick）</a>
    <img src="https://example.com/image.jpg" onerror="evil()" alt="画像">
  </div>
  """
  echo "\nSanitized HTML: ", sanitizer.sanitizeHtml(testHtml)
  
  # JSONサニタイズテスト
  let testJson = """
  {
    "user": {
      "name": "テストユーザー",
      "password": "secret123",
      "email": "test@example.com",
      "preferences": {
        "theme": "dark",
        "notifications": true
      },
      "api_key": "12345abcde"
    },
    "items": [1, 2, 3, 4, 5]
  }
  """
  echo "\nSanitized JSON: ", sanitizer.sanitizeJson(testJson)
  
  # ヘッダーサニタイズテスト
  var headers = newTable[string, string]()
  headers["User-Agent"] = "TestBrowser/1.0"
  headers["Accept"] = "text/html"
  headers["Referer"] = "https://previous-site.com"
  let sanitizedHeaders = sanitizer.sanitizeRequestHeaders(headers.newTableRef())
  echo "\nSanitized Headers: "
  for key, value in sanitizedHeaders:
    echo "  ", key, ": ", value 