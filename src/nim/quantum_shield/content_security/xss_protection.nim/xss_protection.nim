# xss_protection.nim
## XSS保護モジュール
## クロスサイトスクリプティング攻撃を防止するための機能を提供します

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
  uri,
  re,
  json,
  htmlparser,
  xmltree,
  logging,
  asyncdispatch
]

import ../../utils/[logging, errors]

type
  XssProtectionMode* = enum
    ## XSS保護モード
    xpmDisabled,      ## 保護無効
    xpmDetectOnly,    ## 検出のみ（ブロックしない）
    xpmBlock,         ## 検出時にブロック
    xpmSanitize       ## 検出時に無害化

  XssSeverity* = enum
    ## XSS重大度
    xsInfo,           ## 情報のみ
    xsLow,            ## 低
    xsMedium,         ## 中
    xsHigh,           ## 高
    xsCritical        ## 重大

  XssDetectionRule* = object
    ## XSS検出ルール
    pattern*: Regex              ## パターン
    description*: string         ## 説明
    severity*: XssSeverity       ## 重大度
    enabled*: bool               ## 有効フラグ
    contexts*: set[XssContext]   ## 適用コンテキスト

  XssContext* = enum
    ## XSSコンテキスト
    xcUrl,            ## URL
    xcHtml,           ## HTML
    xcScript,         ## スクリプト
    xcAttribute,      ## 属性
    xcCss,            ## CSS
    xcJson            ## JSON

  XssVulnerability* = object
    ## XSS脆弱性
    input*: string               ## 入力文字列
    matchedPattern*: string      ## マッチしたパターン
    context*: XssContext         ## コンテキスト
    severity*: XssSeverity       ## 重大度
    description*: string         ## 説明
    timestamp*: Time             ## 検出時刻
    sanitizedOutput*: Option[string]  ## 無害化後の出力

  XssProtection* = ref object
    ## XSS保護機能
    enabled*: bool                ## 有効フラグ
    mode*: XssProtectionMode      ## 保護モード
    logger: Logger                ## ロガー
    rules*: seq[XssDetectionRule] ## 検出ルール
    exemptDomains*: HashSet[string]  ## 例外ドメイン
    detectionHistory*: seq[XssVulnerability]  ## 検出履歴
    strictMode*: bool             ## 厳格モード
    maxHistorySize*: int          ## 履歴最大サイズ

const
  # デフォルトルール
  DEFAULT_XSS_PATTERNS = [
    (r"<script[^>]*>", "スクリプトタグ", xsHigh, {xcHtml}),
    (r"javascript:", "javascriptプロトコル", xsHigh, {xcUrl, xcHtml, xcAttribute}),
    (r"(?i)on\w+\s*=", "イベントハンドラ属性", xsHigh, {xcHtml, xcAttribute}),
    (r"(?i)expression\s*\(", "CSSエクスプレッション", xsMedium, {xcCss}),
    (r"(?i)<!--.*?-->", "HTMLコメント", xsLow, {xcHtml}),
    (r"(?i)<iframe[^>]*>", "インラインフレーム", xsMedium, {xcHtml}),
    (r"(?i)<form[^>]*>", "フォームタグ", xsMedium, {xcHtml}),
    (r"(?i)<img[^>]*src=[^>]*>", "画像タグ", xsLow, {xcHtml}),
    (r"(?i)<link[^>]*>", "リンクタグ", xsMedium, {xcHtml}),
    (r"(?i)<meta[^>]*>", "メタタグ", xsMedium, {xcHtml}),
    (r"(?i)<svg[^>]*>", "SVGタグ", xsMedium, {xcHtml}),
    (r"(?i)<object[^>]*>", "オブジェクトタグ", xsHigh, {xcHtml}),
    (r"(?i)<embed[^>]*>", "埋め込みタグ", xsHigh, {xcHtml}),
    (r"(?i)data:", "データURI", xsMedium, {xcUrl, xcHtml, xcAttribute}),
    (r"(?i)vbscript:", "VBScriptプロトコル", xsHigh, {xcUrl, xcHtml, xcAttribute}),
    (r"(?i)alert\s*\(", "アラート関数", xsMedium, {xcScript}),
    (r"(?i)eval\s*\(", "評価関数", xsHigh, {xcScript}),
    (r"(?i)document\.cookie", "Cookieアクセス", xsHigh, {xcScript}),
    (r"(?i)document\.domain", "ドメインアクセス", xsHigh, {xcScript}),
    (r"(?i)document\.write", "ドキュメント書き込み", xsHigh, {xcScript}),
    (r"(?i)innerHTML", "innerHTML操作", xsMedium, {xcScript}),
    (r"(?i)outerHTML", "outerHTML操作", xsMedium, {xcScript}),
    (r"(?i)<base[^>]*>", "ベースタグ", xsMedium, {xcHtml}),
    (r"(?i)<applet[^>]*>", "アプレットタグ", xsHigh, {xcHtml}),
    (r"(?i)@import", "CSSインポート", xsLow, {xcCss})
  ]

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc newXssProtection*(): XssProtection =
  ## 新しいXSS保護機能を作成
  new(result)
  result.enabled = true
  result.mode = xpmBlock
  result.logger = newLogger("XssProtection")
  result.rules = @[]
  result.exemptDomains = initHashSet[string]()
  result.detectionHistory = @[]
  result.strictMode = false
  result.maxHistorySize = 100
  
  # デフォルトルールの追加
  for (pattern, desc, severity, contexts) in DEFAULT_XSS_PATTERNS:
    result.rules.add(XssDetectionRule(
      pattern: re(pattern),
      description: desc,
      severity: severity,
      enabled: true,
      contexts: contexts
    ))

proc enable*(protection: XssProtection) =
  ## XSS保護を有効化
  protection.enabled = true
  protection.logger.info("XSS保護を有効化")

proc disable*(protection: XssProtection) =
  ## XSS保護を無効化
  protection.enabled = false
  protection.logger.info("XSS保護を無効化")

proc enableStrictMode*(protection: XssProtection) =
  ## 厳格モードを有効化
  protection.strictMode = true
  protection.logger.info("XSS保護の厳格モードを有効化")

proc disableStrictMode*(protection: XssProtection) =
  ## 厳格モードを無効化
  protection.strictMode = false
  protection.logger.info("XSS保護の厳格モードを無効化")

proc setMode*(protection: XssProtection, mode: XssProtectionMode) =
  ## 保護モードを設定
  protection.mode = mode
  protection.logger.info("XSS保護モードを変更: " & $mode)

proc isEnabled*(protection: XssProtection): bool =
  ## 有効かどうかを確認
  return protection.enabled

proc addRule*(protection: XssProtection, pattern: string, description: string, 
            severity: XssSeverity, contexts: set[XssContext]) =
  ## ルールを追加
  protection.rules.add(XssDetectionRule(
    pattern: re(pattern),
    description: description,
    severity: severity,
    enabled: true,
    contexts: contexts
  ))
  protection.logger.info("XSS検出ルールを追加: " & description)

proc enableRule*(protection: XssProtection, index: int) =
  ## ルールを有効化
  if index >= 0 and index < protection.rules.len:
    protection.rules[index].enabled = true

proc disableRule*(protection: XssProtection, index: int) =
  ## ルールを無効化
  if index >= 0 and index < protection.rules.len:
    protection.rules[index].enabled = false

proc addExemptDomain*(protection: XssProtection, domain: string) =
  ## 例外ドメインを追加
  protection.exemptDomains.incl(domain)
  protection.logger.info("XSS保護の例外ドメインを追加: " & domain)

proc removeExemptDomain*(protection: XssProtection, domain: string) =
  ## 例外ドメインを削除
  protection.exemptDomains.excl(domain)
  protection.logger.info("XSS保護の例外ドメインを削除: " & domain)

proc isExemptDomain*(protection: XssProtection, domain: string): bool =
  ## 例外ドメインかどうかを確認
  if domain in protection.exemptDomains:
    return true
  
  # サブドメインのチェック
  for d in protection.exemptDomains:
    if domain.endsWith("." & d):
      return true
  
  return false

proc clearHistory*(protection: XssProtection) =
  ## 履歴をクリア
  protection.detectionHistory = @[]
  protection.logger.info("XSS検出履歴をクリア")

#----------------------------------------
# XSS検出と無害化
#----------------------------------------

proc detectXss*(protection: XssProtection, input: string, context: XssContext): Option[XssVulnerability] =
  ## XSSを検出
  if not protection.enabled:
    return none(XssVulnerability)
  
  for rule in protection.rules:
    if not rule.enabled:
      continue
    
    if context notin rule.contexts:
      continue
    
    if input.match(rule.pattern):
      let vulnerability = XssVulnerability(
        input: input,
        matchedPattern: $rule.pattern,
        context: context,
        severity: rule.severity,
        description: rule.description,
        timestamp: getTime(),
        sanitizedOutput: none(string)
      )
      
      # 履歴に追加
      protection.detectionHistory.add(vulnerability)
      
      # 履歴サイズの制限
      if protection.detectionHistory.len > protection.maxHistorySize:
        protection.detectionHistory.delete(0)
      
      protection.logger.warn("XSS検出: " & rule.description & " in " & $context)
      return some(vulnerability)
  
  return none(XssVulnerability)

proc sanitizeHtml*(input: string): string =
  ## HTMLを無害化
  try:
    let doc = parseHtml(input)
    
    # スクリプトタグを削除
    var scriptsToRemove: seq[XmlNode] = @[]
    for script in doc.findAll("script"):
      scriptsToRemove.add(script)
    
    for script in scriptsToRemove:
      script.parent.removeChild(script)
    
    # 危険な属性を削除
    for element in doc.findAll("*"):
      var attrsToRemove: seq[string] = @[]
      
      for attr, value in element.attrs:
        if attr.toLowerAscii().startsWith("on") or
           value.toLowerAscii().contains("javascript:") or
           value.toLowerAscii().contains("data:"):
          attrsToRemove.add(attr)
      
      for attr in attrsToRemove:
        element.attrs.del(attr)
    
    result = $doc
  except:
    # パース失敗時は安全な代替テキストを返す
    result = input.replace("<", "&lt;").replace(">", "&gt;")

proc sanitizeUrl*(url: string): string =
  ## URLを無害化
  try:
    let parsedUrl = parseUri(url)
    
    # javascriptなどの危険なスキームをブロック
    let scheme = parsedUrl.scheme.toLowerAscii()
    if scheme in ["javascript", "vbscript", "data"]:
      return "about:blank"
    
    return url
  except:
    return "about:blank"

proc sanitizeAttribute*(attrValue: string): string =
  ## 属性値を無害化
  result = attrValue
    .replace("<", "&lt;")
    .replace(">", "&gt;")
    .replace("\"", "&quot;")
    .replace("'", "&#39;")
    .replace("`", "&#96;")
  
  # javascriptプロトコルを削除
  result = result.replacef(re"(?i)javascript:", "invalid:")

proc sanitizeCss*(css: string): string =
  ## CSSを無害化
  result = css
    .replace("expression", "")
    .replace("eval", "")
    .replace("javascript", "")
    
  # url()関数からjavascriptを削除
  result = result.replacef(re"url\s*\(\s*['\"]?javascript:", "url(invalid:")

proc sanitize*(protection: XssProtection, input: string, context: XssContext): string =
  ## コンテキストに応じた無害化
  let detected = protection.detectXss(input, context)
  
  if detected.isNone:
    return input
  
  var sanitized = ""
  
  case context
  of xcHtml:
    sanitized = sanitizeHtml(input)
  of xcUrl:
    sanitized = sanitizeUrl(input)
  of xcAttribute:
    sanitized = sanitizeAttribute(input)
  of xcCss:
    sanitized = sanitizeCss(input)
  of xcScript:
    # スクリプトは安全に無害化できないので空文字列に
    sanitized = ""
  of xcJson:
    # JSONは必要に応じてエスケープ
    sanitized = input.replace("<", "\\u003c").replace(">", "\\u003e")
  
  # 無害化したバージョンを履歴に記録
  var vulnerability = detected.get()
  vulnerability.sanitizedOutput = some(sanitized)
  
  # 履歴の最後の要素を更新
  protection.detectionHistory[^1] = vulnerability
  
  return sanitized

proc processHtml*(protection: XssProtection, html: string, domain: string = ""): string =
  ## HTMLを処理
  if not protection.enabled or (domain.len > 0 and protection.isExemptDomain(domain)):
    return html
  
  # モードに応じた処理
  case protection.mode
  of xpmDisabled:
    return html
  of xpmDetectOnly:
    discard protection.detectXss(html, xcHtml)
    return html
  of xpmBlock:
    let detected = protection.detectXss(html, xcHtml)
    if detected.isSome:
      # 特定の重大度以上のXSSをブロック
      if detected.get().severity >= xsMedium or protection.strictMode:
        protection.logger.warn("XSSブロック: " & detected.get().description)
        return "<!-- XSSフィルタによりブロックされました -->"
    return html
  of xpmSanitize:
    return protection.sanitize(html, xcHtml)

proc processUrl*(protection: XssProtection, url: string, domain: string = ""): string =
  ## URLを処理
  if not protection.enabled or (domain.len > 0 and protection.isExemptDomain(domain)):
    return url
  
  # モードに応じた処理
  case protection.mode
  of xpmDisabled:
    return url
  of xpmDetectOnly:
    discard protection.detectXss(url, xcUrl)
    return url
  of xpmBlock:
    let detected = protection.detectXss(url, xcUrl)
    if detected.isSome:
      protection.logger.warn("URL XSSブロック: " & detected.get().description)
      return "about:blank"
    return url
  of xpmSanitize:
    return protection.sanitize(url, xcUrl)

proc getHistory*(protection: XssProtection): seq[XssVulnerability] =
  ## 検出履歴を取得
  return protection.detectionHistory

proc toJson*(protection: XssProtection): JsonNode =
  ## JSONシリアライズ
  result = newJObject()
  result["enabled"] = %protection.enabled
  result["mode"] = %($protection.mode)
  result["strictMode"] = %protection.strictMode
  
  var rules = newJArray()
  for rule in protection.rules:
    var ruleObj = newJObject()
    ruleObj["pattern"] = %($rule.pattern)
    ruleObj["description"] = %rule.description
    ruleObj["severity"] = %($rule.severity)
    ruleObj["enabled"] = %rule.enabled
    
    var contexts = newJArray()
    for context in XssContext:
      if context in rule.contexts:
        contexts.add(%($context))
    ruleObj["contexts"] = contexts
    
    rules.add(ruleObj)
  result["rules"] = rules
  
  var exceptions = newJArray()
  for domain in protection.exemptDomains:
    exceptions.add(%domain)
  result["exemptDomains"] = exceptions
  
  var history = newJArray()
  for item in protection.detectionHistory:
    var itemObj = newJObject()
    itemObj["input"] = %item.input
    itemObj["matchedPattern"] = %item.matchedPattern
    itemObj["context"] = %($item.context)
    itemObj["severity"] = %($item.severity)
    itemObj["description"] = %item.description
    itemObj["timestamp"] = %($item.timestamp)
    
    if item.sanitizedOutput.isSome:
      itemObj["sanitizedOutput"] = %item.sanitizedOutput.get()
    
    history.add(itemObj)
  result["history"] = history 