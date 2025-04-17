# コンテンツセキュリティポリシー(CSP)モジュール
#
# このモジュールは、Webブラウザのコンテンツセキュリティポリシー(CSP)機能を実装します。
# CSPは、クロスサイトスクリプティング(XSS)やデータインジェクション攻撃などの
# セキュリティ脅威からユーザーを保護するために使用されます。

import std/[tables, options, sets, strutils, strformat, sequtils, sugar, parseutils]
import std/[uri, json]
import ../../logging

type
  CspDirectiveType* = enum
    # フェッチディレクティブ
    cdDefaultSrc      # デフォルトのソースポリシー
    cdScriptSrc       # スクリプトのソースポリシー
    cdStyleSrc        # スタイルシートのソースポリシー
    cdImgSrc          # 画像のソースポリシー
    cdConnectSrc      # 接続先のソースポリシー
    cdFontSrc         # フォントのソースポリシー
    cdObjectSrc       # オブジェクトのソースポリシー
    cdMediaSrc        # メディアのソースポリシー
    cdFrameSrc        # フレームのソースポリシー
    cdWorkerSrc       # ワーカーのソースポリシー
    cdManifestSrc     # マニフェストのソースポリシー
    
    # ドキュメントディレクティブ
    cdBaseUri         # ベースURIの制限
    cdSandbox         # サンドボックス制限
    cdFormAction      # フォーム送信先の制限
    cdFrameAncestors  # フレーム先祖の制限
    cdNavigateTo      # ナビゲーション先の制限
    
    # レポーティングディレクティブ
    cdReportUri       # 違反レポート送信先
    cdReportTo        # レポートグループの指定
    
    # その他のディレクティブ
    cdUpgradeInsecureRequests  # 安全でないリクエストのアップグレード
    cdBlockAllMixedContent     # 混合コンテンツのブロック
    cdRequireSriFor            # サブリソース整合性の要求
    cdRequireTrustedTypesFor   # 信頼されたタイプの要求
    cdTrustedTypes            # 信頼されたタイプの設定

  CspSourceType* = enum
    cstNone           # 'none' - 何も許可しない
    cstSelf           # 'self' - 同一オリジンのみ許可
    cstUnsafeInline   # 'unsafe-inline' - インラインスクリプト/スタイルを許可
    cstUnsafeEval     # 'unsafe-eval' - evalを許可
    cstStrictDynamic  # 'strict-dynamic' - 動的スクリプト生成を許可
    cstUnsafeHashes   # 'unsafe-hashes' - ハッシュベースの許可
    cstReportSample   # 'report-sample' - サンプルをレポート
    cstHost           # ホスト（例: example.com）
    cstScheme         # スキーム（例: https:）
    cstHash           # ハッシュ（例: 'sha256-...'）
    cstNonce          # ノンス（例: 'nonce-...'）

  CspSource* = object
    sourceType*: CspSourceType
    value*: string           # ホスト名、スキーム、ハッシュ値など

  CspDirective* = object
    directiveType*: CspDirectiveType
    sources*: seq[CspSource]  # ソースリスト
    raw*: string              # 生のディレクティブ文字列

  CspViolationType* = enum
    cvtBlockedUri           # ブロックされたURI
    cvtViolatedDirective    # 違反したディレクティブ
    cvtEffectiveDirective   # 実効ディレクティブ
    cvtOriginalPolicy       # 元のポリシー
    cvtDisposition          # 強制または報告のみ
    cvtReferrer             # リファラー
    cvtScriptSample         # スクリプトサンプル

  CspViolation* = object
    violationType*: CspViolationType
    blockedUri*: string      # ブロックされたリソースURI
    violatedDirective*: string # 違反したディレクティブ
    effectiveDirective*: string # 実効ディレクティブ
    originalPolicy*: string   # 元のポリシー
    documentUri*: string      # 違反の発生したドキュメントURI
    referrer*: string         # リファラー
    statusCode*: int          # HTTPステータスコード
    timestamp*: string        # 違反発生時刻
    sample*: string           # 違反したコードのサンプル

  ContentSecurityPolicy* = ref object
    directives*: Table[CspDirectiveType, CspDirective]
    reportOnly*: bool         # レポートのみのポリシーか
    raw*: string              # 生のCSPヘッダー値

# CSPディレクティブ名の変換テーブル
const DirectiveNameMap = {
  "default-src": cdDefaultSrc,
  "script-src": cdScriptSrc,
  "style-src": cdStyleSrc,
  "img-src": cdImgSrc,
  "connect-src": cdConnectSrc,
  "font-src": cdFontSrc,
  "object-src": cdObjectSrc,
  "media-src": cdMediaSrc,
  "frame-src": cdFrameSrc,
  "worker-src": cdWorkerSrc,
  "manifest-src": cdManifestSrc,
  "base-uri": cdBaseUri,
  "sandbox": cdSandbox,
  "form-action": cdFormAction,
  "frame-ancestors": cdFrameAncestors,
  "navigate-to": cdNavigateTo,
  "report-uri": cdReportUri,
  "report-to": cdReportTo,
  "upgrade-insecure-requests": cdUpgradeInsecureRequests,
  "block-all-mixed-content": cdBlockAllMixedContent,
  "require-sri-for": cdRequireSriFor,
  "require-trusted-types-for": cdRequireTrustedTypesFor,
  "trusted-types": cdTrustedTypes
}.toTable

# CSPディレクティブ型から名前への変換テーブル
const DirectiveTypeNameMap = {
  cdDefaultSrc: "default-src",
  cdScriptSrc: "script-src",
  cdStyleSrc: "style-src", 
  cdImgSrc: "img-src",
  cdConnectSrc: "connect-src",
  cdFontSrc: "font-src",
  cdObjectSrc: "object-src",
  cdMediaSrc: "media-src",
  cdFrameSrc: "frame-src",
  cdWorkerSrc: "worker-src",
  cdManifestSrc: "manifest-src",
  cdBaseUri: "base-uri",
  cdSandbox: "sandbox",
  cdFormAction: "form-action",
  cdFrameAncestors: "frame-ancestors", 
  cdNavigateTo: "navigate-to",
  cdReportUri: "report-uri",
  cdReportTo: "report-to",
  cdUpgradeInsecureRequests: "upgrade-insecure-requests",
  cdBlockAllMixedContent: "block-all-mixed-content",
  cdRequireSriFor: "require-sri-for",
  cdRequireTrustedTypesFor: "require-trusted-types-for",
  cdTrustedTypes: "trusted-types"
}.toTable

# CSPソースキーワードの変換テーブル
const SourceKeywordMap = {
  "'none'": cstNone,
  "'self'": cstSelf,
  "'unsafe-inline'": cstUnsafeInline,
  "'unsafe-eval'": cstUnsafeEval,
  "'strict-dynamic'": cstStrictDynamic,
  "'unsafe-hashes'": cstUnsafeHashes,
  "'report-sample'": cstReportSample
}.toTable

# 新しいCSPソースを作成
proc newCspSource*(sourceType: CspSourceType, value: string = ""): CspSource =
  result = CspSource(
    sourceType: sourceType,
    value: value
  )

# 文字列からCSPソースを解析
proc parseCspSource*(source: string): CspSource =
  # キーワードソースの場合
  if SourceKeywordMap.hasKey(source):
    return newCspSource(SourceKeywordMap[source])
  
  # ハッシュの場合
  if source.startsWith("'sha"):
    return newCspSource(cstHash, source)
  
  # ノンスの場合
  if source.startsWith("'nonce-"):
    return newCspSource(cstNonce, source)
  
  # スキームの場合
  if source.endsWith(":"):
    return newCspSource(cstScheme, source)
  
  # ホストの場合
  return newCspSource(cstHost, source)

# 新しいCSPディレクティブを作成
proc newCspDirective*(directiveType: CspDirectiveType, sources: seq[CspSource], raw: string = ""): CspDirective =
  result = CspDirective(
    directiveType: directiveType,
    sources: sources,
    raw: raw
  )

# CSPディレクティブを文字列から解析
proc parseCspDirective*(directive: string): Option[CspDirective] =
  let parts = directive.split(maxsplit=1)
  if parts.len < 1:
    return none(CspDirective)
  
  let directiveName = parts[0].strip()
  
  if not DirectiveNameMap.hasKey(directiveName):
    log(lvlWarn, fmt"不明なCSPディレクティブ: {directiveName}")
    return none(CspDirective)
  
  let directiveType = DirectiveNameMap[directiveName]
  var sources: seq[CspSource] = @[]
  
  if parts.len > 1:
    let sourceStr = parts[1].strip()
    let sourceParts = sourceStr.split(' ')
    
    for part in sourceParts:
      if part.len > 0:
        sources.add(parseCspSource(part))
  
  let result = newCspDirective(directiveType, sources, directive)
  return some(result)

# 新しいコンテンツセキュリティポリシーを作成
proc newContentSecurityPolicy*(reportOnly: bool = false): ContentSecurityPolicy =
  result = ContentSecurityPolicy(
    directives: initTable[CspDirectiveType, CspDirective](),
    reportOnly: reportOnly,
    raw: ""
  )

# CSPヘッダー文字列からポリシーを解析
proc parseContentSecurityPolicy*(headerValue: string, reportOnly: bool = false): ContentSecurityPolicy =
  result = newContentSecurityPolicy(reportOnly)
  result.raw = headerValue
  
  let directives = headerValue.split(';')
  for directive in directives:
    let trimmed = directive.strip()
    if trimmed.len > 0:
      let parsedDirective = parseCspDirective(trimmed)
      if parsedDirective.isSome():
        let dir = parsedDirective.get()
        result.directives[dir.directiveType] = dir

# ディレクティブをポリシーに追加
proc addDirective*(policy: ContentSecurityPolicy, directive: CspDirective) =
  policy.directives[directive.directiveType] = directive

# ディレクティブをポリシーに追加（型とソースから）
proc addDirective*(policy: ContentSecurityPolicy, directiveType: CspDirectiveType, sources: seq[CspSource]) =
  var rawSources = ""
  for source in sources:
    if rawSources.len > 0:
      rawSources.add(" ")
    
    case source.sourceType:
      of cstNone, cstSelf, cstUnsafeInline, cstUnsafeEval, cstStrictDynamic, 
         cstUnsafeHashes, cstReportSample:
        # キーワードソースの場合、キーを逆引き
        for k, v in SourceKeywordMap.pairs:
          if v == source.sourceType:
            rawSources.add(k)
            break
      else:
        # その他のソースタイプの場合、値を使用
        rawSources.add(source.value)
  
  # ディレクティブ名を取得
  let directiveName = DirectiveTypeNameMap[directiveType]
  let raw = directiveName & " " & rawSources
  
  let directive = newCspDirective(directiveType, sources, raw)
  policy.directives[directiveType] = directive

# ポリシーをCSPヘッダー文字列に変換
proc toCspHeader*(policy: ContentSecurityPolicy): string =
  var parts: seq[string] = @[]
  
  for directiveType, directive in policy.directives:
    parts.add(directive.raw)
  
  result = parts.join("; ")

# CSPヘッダー名を取得
proc getCspHeaderName*(reportOnly: bool = false): string =
  if reportOnly:
    return "Content-Security-Policy-Report-Only"
  else:
    return "Content-Security-Policy"

# ポリシーがディレクティブを持っているか確認
proc hasDirective*(policy: ContentSecurityPolicy, directiveType: CspDirectiveType): bool =
  return policy.directives.hasKey(directiveType)

# ポリシーからディレクティブを取得
proc getDirective*(policy: ContentSecurityPolicy, directiveType: CspDirectiveType): Option[CspDirective] =
  if policy.directives.hasKey(directiveType):
    return some(policy.directives[directiveType])
  return none(CspDirective)

# ディレクティブがソースを許可しているか確認
proc allowsSource*(directive: CspDirective, source: string, resourceType: string = ""): bool =
  # 'none'が含まれていれば、何も許可しない
  for src in directive.sources:
    if src.sourceType == cstNone:
      return false
  
  # ソースがディレクティブに含まれているか確認
  let parsedSource = parseCspSource(source)
  
  for src in directive.sources:
    # 完全一致
    if src.sourceType == parsedSource.sourceType and src.value == parsedSource.value:
      return true
    
    # 'self'とオリジンの比較
    if src.sourceType == cstSelf:
      # 同一オリジンチェック
      let sourceUri = parseUri(source)
      let currentOrigin = getCurrentOrigin() # 現在のドキュメントのオリジン取得
      let sourceOrigin = getOriginFromUri(sourceUri)
      if currentOrigin == sourceOrigin:
        return true
    # ホストパターンの一致チェック
    if src.sourceType == cstHost and parsedSource.sourceType == cstHost:
      # ワイルドカードのサポート
      if src.value.startsWith("*.") and parsedSource.value.endsWith(src.value[1..^1]):
        return true
      
      # 完全なホスト名の一致
      if src.value == parsedSource.value:
        return true
    
    # スキームの一致チェック
    if src.sourceType == cstScheme and parsedSource.sourceType == cstHost:
      let uri = parseUri(parsedSource.value)
      if src.value == uri.scheme & ":":
        return true
  
  return false

# ポリシーがURLをロードすることを許可するか確認
proc allowsLoad*(policy: ContentSecurityPolicy, url: string, resourceType: string): bool =
  var directiveType: CspDirectiveType
  
  # リソースタイプに基づいてディレクティブを選択
  case resourceType:
    of "script":
      directiveType = cdScriptSrc
    of "style":
      directiveType = cdStyleSrc
    of "image":
      directiveType = cdImgSrc
    of "connect":
      directiveType = cdConnectSrc
    of "font":
      directiveType = cdFontSrc
    of "object":
      directiveType = cdObjectSrc
    of "media":
      directiveType = cdMediaSrc
    of "frame":
      directiveType = cdFrameSrc
    of "worker":
      directiveType = cdWorkerSrc
    of "manifest":
      directiveType = cdManifestSrc
    else:
      # 不明なリソースタイプ
      directiveType = cdDefaultSrc
  
  # 指定されたディレクティブがあるか確認
  let directiveOpt = policy.getDirective(directiveType)
  
  # ディレクティブがない場合、default-srcを使用
  if directiveOpt.isNone() and directiveType != cdDefaultSrc:
    return allowsLoad(policy, url, "default")
  
  # default-srcもない場合、デフォルトでは許可
  if directiveOpt.isNone():
    return true
  
  # ディレクティブがソースを許可するか確認
  return directiveOpt.get().allowsSource(url, resourceType)

# CSP違反の作成
proc newCspViolation*(blockedUri: string, violatedDirective: string, 
                     effectiveDirective: string, originalPolicy: string,
                     documentUri: string, referrer: string = "", 
                     statusCode: int = 0, sample: string = ""): CspViolation =
  result = CspViolation(
    blockedUri: blockedUri,
    violatedDirective: violatedDirective,
    effectiveDirective: effectiveDirective,
    originalPolicy: originalPolicy,
    documentUri: documentUri,
    referrer: referrer,
    statusCode: statusCode,
    timestamp: $now(),
    sample: sample
  )

# CSP違反をJSONに変換
proc toJson*(violation: CspViolation): JsonNode =
  result = newJObject()
  result["csp-report"] = newJObject()
  
  let report = result["csp-report"]
  report["blocked-uri"] = %violation.blockedUri
  report["violated-directive"] = %violation.violatedDirective
  report["effective-directive"] = %violation.effectiveDirective
  report["original-policy"] = %violation.originalPolicy
  report["document-uri"] = %violation.documentUri
  
  if violation.referrer.len > 0:
    report["referrer"] = %violation.referrer
  
  if violation.statusCode > 0:
    report["status-code"] = %violation.statusCode
  
  if violation.sample.len > 0:
    report["script-sample"] = %violation.sample

# デフォルトのCSPポリシーを作成
proc createDefaultPolicy*(reportOnly: bool = false): ContentSecurityPolicy =
  result = newContentSecurityPolicy(reportOnly)
  
  # デフォルトのソースディレクティブ
  result.addDirective(cdDefaultSrc, @[
    newCspSource(cstSelf)
  ])
  
  # スクリプトのソースディレクティブ
  result.addDirective(cdScriptSrc, @[
    newCspSource(cstSelf),
    newCspSource(cstUnsafeInline)
  ])
  
  # スタイルのソースディレクティブ
  result.addDirective(cdStyleSrc, @[
    newCspSource(cstSelf),
    newCspSource(cstUnsafeInline)
  ])
  
  # 画像のソースディレクティブ
  result.addDirective(cdImgSrc, @[
    newCspSource(cstSelf),
    newCspSource(cstScheme, "https:")
  ])
  
  # 安全でないリクエストのアップグレード
  result.addDirective(cdUpgradeInsecureRequests, @[])
  
  # レポートURI（違反を報告するURL）
  if reportOnly:
    result.addDirective(cdReportUri, @[
      newCspSource(cstHost, "/csp-report")
    ])

# 厳格なCSPポリシーを作成
proc createStrictPolicy*(reportOnly: bool = false): ContentSecurityPolicy =
  result = newContentSecurityPolicy(reportOnly)
  
  # デフォルトのソースディレクティブ（厳格モード）
  result.addDirective(cdDefaultSrc, @[
    newCspSource(cstNone)
  ])
  
  # スクリプトのソースディレクティブ
  result.addDirective(cdScriptSrc, @[
    newCspSource(cstSelf)
  ])
  
  # スタイルのソースディレクティブ
  result.addDirective(cdStyleSrc, @[
    newCspSource(cstSelf)
  ])
  
  # 画像のソースディレクティブ
  result.addDirective(cdImgSrc, @[
    newCspSource(cstSelf),
    newCspSource(cstScheme, "https:")
  ])
  
  # 接続先のソースディレクティブ
  result.addDirective(cdConnectSrc, @[
    newCspSource(cstSelf)
  ])
  
  # フォントのソースディレクティブ
  result.addDirective(cdFontSrc, @[
    newCspSource(cstSelf)
  ])
  
  # オブジェクトのソースディレクティブ
  result.addDirective(cdObjectSrc, @[
    newCspSource(cstNone)
  ])
  
  # メディアのソースディレクティブ
  result.addDirective(cdMediaSrc, @[
    newCspSource(cstSelf)
  ])
  
  # フレームのソースディレクティブ
  result.addDirective(cdFrameSrc, @[
    newCspSource(cstNone)
  ])
  
  # フレーム先祖のディレクティブ
  result.addDirective(cdFrameAncestors, @[
    newCspSource(cstNone)
  ])
  
  # ベースURIのディレクティブ
  result.addDirective(cdBaseUri, @[
    newCspSource(cstSelf)
  ])
  
  # フォームアクションのディレクティブ
  result.addDirective(cdFormAction, @[
    newCspSource(cstSelf)
  ])
  
  # 混合コンテンツのブロック
  result.addDirective(cdBlockAllMixedContent, @[])
  
  # 安全でないリクエストのアップグレード
  result.addDirective(cdUpgradeInsecureRequests, @[])
  
  # レポートURI（違反を報告するURL）
  if reportOnly:
    result.addDirective(cdReportUri, @[
      newCspSource(cstHost, "/csp-report")
    ])

# CSPポリシーをマージ
proc mergePolicies*(policies: seq[ContentSecurityPolicy]): ContentSecurityPolicy =
  if policies.len == 0:
    return newContentSecurityPolicy()
  
  if policies.len == 1:
    return policies[0]
  
  var result = newContentSecurityPolicy(policies[0].reportOnly)
  
  # 各ディレクティブ種別ごとに処理
  for directiveType in CspDirectiveType:
    var sources: seq[CspSource] = @[]
    var foundDirective = false
    
    # 各ポリシーからソースを収集
    for policy in policies:
      let directiveOpt = policy.getDirective(directiveType)
      if directiveOpt.isSome():
        foundDirective = true
        let directive = directiveOpt.get()
        
        # ソースを追加（重複排除）
        for source in directive.sources:
          var isDuplicate = false
          for existingSource in sources:
            if existingSource.sourceType == source.sourceType and 
               existingSource.value == source.value:
              isDuplicate = true
              break
          
          if not isDuplicate:
            sources.add(source)
    
    # 新しいディレクティブを追加
    if foundDirective:
      result.addDirective(directiveType, sources)
  
  return result 