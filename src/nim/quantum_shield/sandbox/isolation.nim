import std/[asyncdispatch, options, sets, tables, times, uri, json]
import ../../utils/[logging, errors]

type
  SandboxLevel* = enum
    sbDisabled,     ## サンドボックス無効
    sbBasic,        ## 基本的な分離
    sbStrict,       ## 厳格な分離
    sbExtreme       ## 最大限の分離

  SandboxPolicy* = object
    allowScripts*: bool           ## JavaScriptの実行を許可
    allowWorkers*: bool           ## Web Workersの使用を許可
    allowModals*: bool           ## モーダルダイアログの表示を許可
    allowPopups*: bool           ## ポップアップを許可
    allowForms*: bool            ## フォームの使用を許可
    allowPointerLock*: bool      ## ポインターロックを許可
    allowPresentation*: bool     ## プレゼンテーションAPIの使用を許可
    allowSameOrigin*: bool       ## 同一オリジンポリシーの適用
    allowTopNavigation*: bool    ## トップレベルナビゲーションを許可
    allowDownloads*: bool        ## ダウンロードを許可
    allowClipboard*: bool        ## クリップボードの使用を許可
    allowStorage*: bool          ## ストレージの使用を許可
    allowPlugins*: bool          ## プラグインの使用を許可
    allowSharedArrayBuffer*: bool ## SharedArrayBufferの使用を許可

  SandboxIsolation* = ref object
    enabled*: bool
    level*: SandboxLevel
    logger: Logger
    defaultPolicy*: SandboxPolicy
    domainPolicies*: Table[string, SandboxPolicy]
    exceptionDomains*: HashSet[string]
    isolationStats*: Table[string, IsolationStats]
    lastPolicyUpdate*: Time

  IsolationStats* = object
    domain*: string
    policyViolations*: int
    scriptBlocks*: int
    popupBlocks*: int
    modalBlocks*: int
    storageBlocks*: int
    clipboardBlocks*: int
    lastViolation*: Option[Time]
    violationTypes*: HashSet[string]

const
  DefaultSandboxFlags = [
    "allow-scripts",
    "allow-same-origin",
    "allow-forms",
    "allow-popups",
    "allow-modals",
    "allow-downloads"
  ]

proc newSandboxIsolation*(): SandboxIsolation =
  result = SandboxIsolation(
    enabled: true,
    level: sbBasic,
    logger: newLogger("SandboxIsolation"),
    defaultPolicy: SandboxPolicy(
      allowScripts: true,
      allowWorkers: true,
      allowModals: true,
      allowPopups: true,
      allowForms: true,
      allowPointerLock: false,
      allowPresentation: false,
      allowSameOrigin: true,
      allowTopNavigation: false,
      allowDownloads: true,
      allowClipboard: true,
      allowStorage: true,
      allowPlugins: false,
      allowSharedArrayBuffer: false
    ),
    domainPolicies: initTable[string, SandboxPolicy](),
    exceptionDomains: initHashSet[string](),
    isolationStats: initTable[string, IsolationStats](),
    lastPolicyUpdate: getTime()
  )

proc setSandboxLevel*(s: SandboxIsolation, level: SandboxLevel) =
  s.level = level
  s.lastPolicyUpdate = getTime()

  case level
  of sbDisabled:
    s.enabled = false
  of sbBasic:
    s.enabled = true
    s.defaultPolicy = SandboxPolicy(
      allowScripts: true,
      allowWorkers: true,
      allowModals: true,
      allowPopups: true,
      allowForms: true,
      allowPointerLock: false,
      allowPresentation: false,
      allowSameOrigin: true,
      allowTopNavigation: false,
      allowDownloads: true,
      allowClipboard: true,
      allowStorage: true,
      allowPlugins: false,
      allowSharedArrayBuffer: false
    )
  of sbStrict:
    s.enabled = true
    s.defaultPolicy = SandboxPolicy(
      allowScripts: true,
      allowWorkers: false,
      allowModals: false,
      allowPopups: false,
      allowForms: true,
      allowPointerLock: false,
      allowPresentation: false,
      allowSameOrigin: true,
      allowTopNavigation: false,
      allowDownloads: false,
      allowClipboard: false,
      allowStorage: true,
      allowPlugins: false,
      allowSharedArrayBuffer: false
    )
  of sbExtreme:
    s.enabled = true
    s.defaultPolicy = SandboxPolicy(
      allowScripts: false,
      allowWorkers: false,
      allowModals: false,
      allowPopups: false,
      allowForms: false,
      allowPointerLock: false,
      allowPresentation: false,
      allowSameOrigin: false,
      allowTopNavigation: false,
      allowDownloads: false,
      allowClipboard: false,
      allowStorage: false,
      allowPlugins: false,
      allowSharedArrayBuffer: false
    )

proc setDomainPolicy*(s: SandboxIsolation, domain: string, policy: SandboxPolicy) =
  s.domainPolicies[domain] = policy
  s.lastPolicyUpdate = getTime()

proc getDomainPolicy*(s: SandboxIsolation, domain: string): SandboxPolicy =
  if domain in s.domainPolicies:
    return s.domainPolicies[domain]
  
  # サブドメインのチェック
  for d, policy in s.domainPolicies:
    if domain.endsWith("." & d):
      return policy
  
  return s.defaultPolicy

proc addExceptionDomain*(s: SandboxIsolation, domain: string) =
  s.exceptionDomains.incl(domain)

proc removeExceptionDomain*(s: SandboxIsolation, domain: string) =
  s.exceptionDomains.excl(domain)

proc isExceptionDomain*(s: SandboxIsolation, domain: string): bool =
  result = domain in s.exceptionDomains or
           any(s.exceptionDomains, proc(d: string): bool = domain.endsWith("." & d))

proc generateSandboxFlags*(s: SandboxIsolation, domain: string): string =
  if not s.enabled or s.isExceptionDomain(domain):
    return ""

  let policy = s.getDomainPolicy(domain)
  var flags: seq[string] = @[]

  if policy.allowScripts:
    flags.add("allow-scripts")
  if policy.allowWorkers:
    flags.add("allow-scripts")  # Workersにはscriptsフラグが必要
  if policy.allowModals:
    flags.add("allow-modals")
  if policy.allowPopups:
    flags.add("allow-popups")
  if policy.allowForms:
    flags.add("allow-forms")
  if policy.allowPointerLock:
    flags.add("allow-pointer-lock")
  if policy.allowPresentation:
    flags.add("allow-presentation")
  if policy.allowSameOrigin:
    flags.add("allow-same-origin")
  if policy.allowTopNavigation:
    flags.add("allow-top-navigation")
  if policy.allowDownloads:
    flags.add("allow-downloads")
  if policy.allowStorage:
    flags.add("allow-storage-access-by-user-activation")
  if policy.allowPlugins:
    flags.add("allow-plugins")

  return flags.join(" ")

proc generateCSP*(s: SandboxIsolation, domain: string): string =
  if not s.enabled or s.isExceptionDomain(domain):
    return ""

  let policy = s.getDomainPolicy(domain)
  var directives: seq[string] = @[]

  # デフォルトのソースポリシー
  directives.add("default-src 'self'")

  # スクリプトポリシー
  if policy.allowScripts:
    directives.add("script-src 'self' 'unsafe-inline' 'unsafe-eval'")
  else:
    directives.add("script-src 'none'")

  # Workerポリシー
  if policy.allowWorkers:
    directives.add("worker-src 'self'")
  else:
    directives.add("worker-src 'none'")

  # フレームポリシー
  directives.add("frame-ancestors 'self'")
  if not policy.allowTopNavigation:
    directives.add("frame-src 'self'")

  # プラグインポリシー
  if not policy.allowPlugins:
    directives.add("object-src 'none'")
    directives.add("plugin-types")

  # その他のセキュリティヘッダー
  if not policy.allowSharedArrayBuffer:
    directives.add("require-corp")

  return directives.join("; ")

proc recordViolation*(s: SandboxIsolation, domain: string, violationType: string) =
  if domain notin s.isolationStats:
    s.isolationStats[domain] = IsolationStats(
      domain: domain,
      policyViolations: 0,
      scriptBlocks: 0,
      popupBlocks: 0,
      modalBlocks: 0,
      storageBlocks: 0,
      clipboardBlocks: 0,
      lastViolation: none(Time),
      violationTypes: initHashSet[string]()
    )

  var stats = s.isolationStats[domain]
  stats.policyViolations += 1
  stats.lastViolation = some(getTime())
  stats.violationTypes.incl(violationType)

  case violationType
  of "script":
    stats.scriptBlocks += 1
  of "popup":
    stats.popupBlocks += 1
  of "modal":
    stats.modalBlocks += 1
  of "storage":
    stats.storageBlocks += 1
  of "clipboard":
    stats.clipboardBlocks += 1
  else:
    discard

  s.isolationStats[domain] = stats

proc getIsolationStats*(s: SandboxIsolation, domain: string = ""): seq[IsolationStats] =
  result = @[]
  for stats in s.isolationStats.values:
    if domain.len == 0 or stats.domain == domain:
      result.add(stats)

proc clearIsolationStats*(s: SandboxIsolation, olderThan: Duration = initDuration(days = 7)) =
  let threshold = getTime() - olderThan
  var toRemove: seq[string] = @[]

  for domain, stats in s.isolationStats:
    if stats.lastViolation.isSome and stats.lastViolation.get() < threshold:
      toRemove.add(domain)

  for domain in toRemove:
    s.isolationStats.del(domain)

proc generatePolicyReport*(s: SandboxIsolation): JsonNode =
  result = %*{
    "enabled": s.enabled,
    "level": $s.level,
    "lastPolicyUpdate": s.lastPolicyUpdate.toUnix,
    "exceptionDomains": toSeq(s.exceptionDomains),
    "domainPolicies": newJObject(),
    "statistics": {
      "totalViolations": 0,
      "scriptBlocks": 0,
      "popupBlocks": 0,
      "modalBlocks": 0,
      "storageBlocks": 0,
      "clipboardBlocks": 0,
      "violationsByDomain": newJObject()
    }
  }

  # ドメインポリシーの追加
  for domain, policy in s.domainPolicies:
    result["domainPolicies"][domain] = %*{
      "allowScripts": policy.allowScripts,
      "allowWorkers": policy.allowWorkers,
      "allowModals": policy.allowModals,
      "allowPopups": policy.allowPopups,
      "allowForms": policy.allowForms,
      "allowPointerLock": policy.allowPointerLock,
      "allowPresentation": policy.allowPresentation,
      "allowSameOrigin": policy.allowSameOrigin,
      "allowTopNavigation": policy.allowTopNavigation,
      "allowDownloads": policy.allowDownloads,
      "allowClipboard": policy.allowClipboard,
      "allowStorage": policy.allowStorage,
      "allowPlugins": policy.allowPlugins,
      "allowSharedArrayBuffer": policy.allowSharedArrayBuffer
    }

  # 統計情報の集計
  for stats in s.isolationStats.values:
    result["statistics"]["totalViolations"].num += stats.policyViolations
    result["statistics"]["scriptBlocks"].num += stats.scriptBlocks
    result["statistics"]["popupBlocks"].num += stats.popupBlocks
    result["statistics"]["modalBlocks"].num += stats.modalBlocks
    result["statistics"]["storageBlocks"].num += stats.storageBlocks
    result["statistics"]["clipboardBlocks"].num += stats.clipboardBlocks

    result["statistics"]["violationsByDomain"][stats.domain] = %*{
      "violations": stats.policyViolations,
      "lastViolation": if stats.lastViolation.isSome: stats.lastViolation.get().toUnix else: nil,
      "violationTypes": toSeq(stats.violationTypes)
    }
