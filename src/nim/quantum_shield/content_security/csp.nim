import std/[tables, strutils, sequtils, options, sets, json]
import std/[times, os, logging]

type
  CspDirective* = enum
    DefaultSrc = "default-src"
    ScriptSrc = "script-src"
    StyleSrc = "style-src"
    ImgSrc = "img-src"
    ConnectSrc = "connect-src"
    FontSrc = "font-src"
    ObjectSrc = "object-src"
    MediaSrc = "media-src"
    FrameSrc = "frame-src"
    ChildSrc = "child-src"
    FormAction = "form-action"
    FrameAncestors = "frame-ancestors"
    BaseUri = "base-uri"
    WorkerSrc = "worker-src"
    ManifestSrc = "manifest-src"
    PrefetchSrc = "prefetch-src"
    NavigateTo = "navigate-to"

  CspSource* = enum
    None = "'none'"
    Self = "'self'"
    UnsafeInline = "'unsafe-inline'"
    UnsafeEval = "'unsafe-eval'"
    StrictDynamic = "'strict-dynamic'"
    UnsafeHashes = "'unsafe-hashes'"
    ReportSample = "'report-sample'"
    WasmUnsafeEval = "'wasm-unsafe-eval'"

  CspReportSettings* = object
    reportUri*: string
    reportTo*: string
    enforced*: bool

  CspPolicy* = ref object
    directives*: Table[CspDirective, HashSet[string]]
    reportSettings*: CspReportSettings
    exemptDomains*: HashSet[string]
    nonces*: HashSet[string]
    hashes*: HashSet[string]
    lastModified*: Time
    version*: int

proc newCspPolicy*(): CspPolicy =
  result = CspPolicy(
    directives: initTable[CspDirective, HashSet[string]](),
    reportSettings: CspReportSettings(enforced: true),
    exemptDomains: initHashSet[string](),
    nonces: initHashSet[string](),
    hashes: initHashSet[string](),
    lastModified: getTime(),
    version: 1
  )

proc addDirective*(policy: CspPolicy, directive: CspDirective, source: string) =
  if not policy.directives.hasKey(directive):
    policy.directives[directive] = initHashSet[string]()
  policy.directives[directive].incl(source)
  policy.lastModified = getTime()
  inc policy.version

proc addDirectives*(policy: CspPolicy, directive: CspDirective, sources: openArray[string]) =
  for source in sources:
    policy.addDirective(directive, source)

proc removeDirective*(policy: CspPolicy, directive: CspDirective, source: string) =
  if policy.directives.hasKey(directive):
    policy.directives[directive].excl(source)
    if policy.directives[directive].len == 0:
      policy.directives.del(directive)
    policy.lastModified = getTime()
    inc policy.version

proc clearDirective*(policy: CspPolicy, directive: CspDirective) =
  if policy.directives.hasKey(directive):
    policy.directives.del(directive)
    policy.lastModified = getTime()
    inc policy.version

proc addNonce*(policy: CspPolicy, nonce: string) =
  policy.nonces.incl(nonce)
  policy.lastModified = getTime()
  inc policy.version

proc addHash*(policy: CspPolicy, hash: string) =
  policy.hashes.incl(hash)
  policy.lastModified = getTime()
  inc policy.version

proc setReportUri*(policy: CspPolicy, uri: string) =
  policy.reportSettings.reportUri = uri
  policy.lastModified = getTime()
  inc policy.version

proc setReportTo*(policy: CspPolicy, endpoint: string) =
  policy.reportSettings.reportTo = endpoint
  policy.lastModified = getTime()
  inc policy.version

proc setEnforced*(policy: CspPolicy, enforced: bool) =
  policy.reportSettings.enforced = enforced
  policy.lastModified = getTime()
  inc policy.version

proc addExemptDomain*(policy: CspPolicy, domain: string) =
  policy.exemptDomains.incl(domain)
  policy.lastModified = getTime()
  inc policy.version

proc removeExemptDomain*(policy: CspPolicy, domain: string) =
  policy.exemptDomains.excl(domain)
  policy.lastModified = getTime()
  inc policy.version

proc toString*(policy: CspPolicy): string =
  var parts: seq[string] = @[]
  
  for directive, sources in policy.directives:
    if sources.len > 0:
      let sourceStr = toSeq(sources).join(" ")
      parts.add($directive & " " & sourceStr)
  
  if policy.reportSettings.reportUri.len > 0:
    parts.add("report-uri " & policy.reportSettings.reportUri)
  
  if policy.reportSettings.reportTo.len > 0:
    parts.add("report-to " & policy.reportSettings.reportTo)
  
  if not policy.reportSettings.enforced:
    result = "Content-Security-Policy-Report-Only: " & parts.join("; ")
  else:
    result = "Content-Security-Policy: " & parts.join("; ")

proc standardPolicy*(): CspPolicy =
  result = newCspPolicy()
  result.addDirectives(DefaultSrc, [$Self])
  result.addDirectives(ScriptSrc, [$Self, $StrictDynamic])
  result.addDirectives(StyleSrc, [$Self])
  result.addDirectives(ImgSrc, [$Self])
  result.addDirectives(ConnectSrc, [$Self])
  result.addDirectives(FontSrc, [$Self])
  result.addDirectives(ObjectSrc, [$None])
  result.addDirectives(MediaSrc, [$Self])
  result.addDirectives(FrameSrc, [$Self])
  result.addDirectives(ChildSrc, [$Self])
  result.addDirectives(FormAction, [$Self])
  result.addDirectives(FrameAncestors, [$None])
  result.addDirectives(BaseUri, [$Self])
  result.addDirectives(WorkerSrc, [$Self])

proc strictPolicy*(): CspPolicy =
  result = newCspPolicy()
  result.addDirectives(DefaultSrc, [$None])
  result.addDirectives(ScriptSrc, [$Self, $StrictDynamic])
  result.addDirectives(StyleSrc, [$Self])
  result.addDirectives(ImgSrc, [$Self])
  result.addDirectives(ConnectSrc, [$Self])
  result.addDirectives(FontSrc, [$Self])
  result.addDirectives(ObjectSrc, [$None])
  result.addDirectives(MediaSrc, [$None])
  result.addDirectives(FrameSrc, [$None])
  result.addDirectives(ChildSrc, [$None])
  result.addDirectives(FormAction, [$Self])
  result.addDirectives(FrameAncestors, [$None])
  result.addDirectives(BaseUri, [$None])
  result.addDirectives(WorkerSrc, [$None])

proc maximumSecurityPolicy*(): CspPolicy =
  result = newCspPolicy()
  result.addDirectives(DefaultSrc, [$None])
  result.addDirectives(ScriptSrc, [$StrictDynamic])
  result.addDirectives(StyleSrc, [$Self])
  result.addDirectives(ImgSrc, [$Self])
  result.addDirectives(ConnectSrc, [$Self])
  result.addDirectives(FontSrc, [$Self])
  result.addDirectives(ObjectSrc, [$None])
  result.addDirectives(MediaSrc, [$None])
  result.addDirectives(FrameSrc, [$None])
  result.addDirectives(ChildSrc, [$None])
  result.addDirectives(FormAction, [$Self])
  result.addDirectives(FrameAncestors, [$None])
  result.addDirectives(BaseUri, [$None])
  result.addDirectives(WorkerSrc, [$None])
  result.addDirectives(ManifestSrc, [$None])
  result.addDirectives(PrefetchSrc, [$None])
  result.addDirectives(NavigateTo, [$None])

proc toJson*(policy: CspPolicy): JsonNode =
  result = newJObject()
  
  var directivesObj = newJObject()
  for directive, sources in policy.directives:
    directivesObj[$directive] = %toSeq(sources)
  
  result["directives"] = directivesObj
  result["reportUri"] = %policy.reportSettings.reportUri
  result["reportTo"] = %policy.reportSettings.reportTo
  result["enforced"] = %policy.reportSettings.enforced
  result["exemptDomains"] = %toSeq(policy.exemptDomains)
  result["nonces"] = %toSeq(policy.nonces)
  result["hashes"] = %toSeq(policy.hashes)
  result["lastModified"] = %($policy.lastModified)
  result["version"] = %policy.version

proc fromJson*(jsonStr: string): CspPolicy =
  let json = parseJson(jsonStr)
  result = newCspPolicy()
  
  if json.hasKey("directives"):
    for directive, sources in json["directives"].getFields:
      let dir = parseEnum[CspDirective](directive)
      for source in sources:
        result.addDirective(dir, source.getStr)
  
  if json.hasKey("reportUri"):
    result.setReportUri(json["reportUri"].getStr)
  
  if json.hasKey("reportTo"):
    result.setReportTo(json["reportTo"].getStr)
  
  if json.hasKey("enforced"):
    result.setEnforced(json["enforced"].getBool)
  
  if json.hasKey("exemptDomains"):
    for domain in json["exemptDomains"]:
      result.addExemptDomain(domain.getStr)
  
  if json.hasKey("nonces"):
    for nonce in json["nonces"]:
      result.addNonce(nonce.getStr)
  
  if json.hasKey("hashes"):
    for hash in json["hashes"]:
      result.addHash(hash.getStr)
  
  if json.hasKey("version"):
    result.version = json["version"].getInt

proc validatePolicy*(policy: CspPolicy): bool =
  # 基本的なバリデーション
  if policy.directives.len == 0:
    warn "CSPポリシーにディレクティブが設定されていません"
    return false

  # default-srcまたはscript-srcが必要
  if not (policy.directives.hasKey(DefaultSrc) or policy.directives.hasKey(ScriptSrc)):
    warn "CSPポリシーにdefault-srcまたはscript-srcが必要です"
    return false

  # 'none'と他のソースの組み合わせをチェック
  for directive, sources in policy.directives:
    if $None in sources and sources.len > 1:
      warn fmt"ディレクティブ{directive}で'none'と他のソースが混在しています"
      return false

  return true

proc isExempt*(policy: CspPolicy, domain: string): bool =
  domain in policy.exemptDomains

proc hasValidNonce*(policy: CspPolicy, nonce: string): bool =
  nonce in policy.nonces

proc hasValidHash*(policy: CspPolicy, hash: string): bool =
  hash in policy.hashes 