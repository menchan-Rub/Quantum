# policy_loader.nim
## クッキーポリシーローダー - 事前定義されたポリシーセットを提供

import std/[
  tables,
  json,
  os,
  options,
  times,
  algorithm,
  strutils,
  sequtils
]
import ./cookie_policy
import ../cookie_types

type
  PolicySet* = enum
    ## 事前定義されたポリシーセット
    psStandard,       # 標準（バランス重視）
    psStrict,         # 厳格（プライバシー重視）
    psPermissive,     # 寛容（機能性重視）
    psIncognito       # プライベートモード

  PolicyLoader* = ref object
    ## ポリシーローダー
    policyDir*: string       # ポリシーファイルディレクトリ
    loadedPolicies*: Table[PolicySet, CookiePolicy]  # 読み込み済みポリシー

const
  # 組み込みポリシーの定義
  BUILTIN_POLICIES = {
    psStandard: @[
      # 標準ポリシーのルール（例）
      (domain: "google-analytics.com", rule: prBlock),
      (domain: "doubleclick.net", rule: prBlock),
      (domain: "facebook.com", rule: prPartition),
      (domain: "fbcdn.net", rule: prPartition)
    ],
    psStrict: @[
      # 厳格ポリシーのルール（例）
      (domain: "google-analytics.com", rule: prBlock),
      (domain: "doubleclick.net", rule: prBlock),
      (domain: "facebook.com", rule: prBlock),
      (domain: "fbcdn.net", rule: prBlock),
      (domain: "twitter.com", rule: prBlock),
      (domain: "youtube.com", rule: prAllowSession),
      (domain: "linkedin.com", rule: prBlock),
      (domain: "*.ad.*", rule: prBlock),
      (domain: "*.ads.*", rule: prBlock),
      (domain: "*.track.*", rule: prBlock),
      (domain: "*.analytics.*", rule: prBlock)
    ],
    psPermissive: @[
      # 寛容ポリシーのルール（例）
      (domain: "google-analytics.com", rule: prAllowFirstParty),
      (domain: "doubleclick.net", rule: prAllowFirstParty),
      (domain: "facebook.com", rule: prAllow),
      (domain: "fbcdn.net", rule: prAllow)
    ],
    psIncognito: @[
      # インコグニトポリシーのルール（例）
      (domain: "google-analytics.com", rule: prBlock),
      (domain: "doubleclick.net", rule: prBlock),
      (domain: "facebook.com", rule: prBlock),
      (domain: "fbcdn.net", rule: prBlock),
      (domain: "twitter.com", rule: prBlock),
      (domain: "youtube.com", rule: prBlock),
      (domain: "linkedin.com", rule: prBlock),
      (domain: "*.ad.*", rule: prBlock),
      (domain: "*.ads.*", rule: prBlock),
      (domain: "*.track.*", rule: prBlock),
      (domain: "*.analytics.*", rule: prBlock),
      (domain: "*.beacon.*", rule: prBlock),
      (domain: "*.counter.*", rule: prBlock),
      (domain: "*.pixel.*", rule: prBlock)
    ]
  }

  DEFAULT_FIRST_PARTY_RULES = {
    psStandard: prAllow,
    psStrict: prAllow,
    psPermissive: prAllow,
    psIncognito: prAllowSession
  }

  DEFAULT_THIRD_PARTY_RULES = {
    psStandard: prAllowFirstParty,
    psStrict: prBlock,
    psPermissive: prAllow,
    psIncognito: prBlock
  }

proc newPolicyLoader*(policyDir: string = ""): PolicyLoader =
  ## 新しいポリシーローダーを作成
  result = PolicyLoader(
    policyDir: policyDir,
    loadedPolicies: initTable[PolicySet, CookiePolicy]()
  )

proc createDefaultPolicy*(policyType: PolicySet, userDataPath: string = ""): CookiePolicy =
  ## デフォルトポリシーを作成
  let firstPartyRule = DEFAULT_FIRST_PARTY_RULES.getOrDefault(policyType, prAllow)
  let thirdPartyRule = DEFAULT_THIRD_PARTY_RULES.getOrDefault(policyType, prAllowFirstParty)
  
  # ポリシーを初期化
  result = newCookiePolicy(
    userDataPath = userDataPath,
    autoSave = userDataPath.len > 0,
    defaultFirstPartyRule = firstPartyRule,
    defaultThirdPartyRule = thirdPartyRule
  )
  
  # 追加ブロックパターン
  case policyType
  of psStrict, psIncognito:
    result.blockPatterns.add("collect")
    result.blockPatterns.add("metric")
    result.blockPatterns.add("visit")
    result.blockPatterns.add("advert")
    result.blockPatterns.add("banner")
    result.blockPatterns.add("marketing")
  else:
    discard
  
  # 固定ルールを設定
  let rules = BUILTIN_POLICIES.getOrDefault(policyType, @[])
  for (domain, rule) in rules:
    discard result.addRule(
      domain = domain,
      rule = rule,
      isUserCreated = false,  # システム定義
      priority = 200          # 高優先度
    )

proc getFilePathForPolicy*(loader: PolicyLoader, policyType: PolicySet): string =
  ## ポリシータイプに対するファイルパスを取得
  if loader.policyDir.len == 0:
    return ""
  
  # ディレクトリがなければ作成
  if not dirExists(loader.policyDir):
    createDir(loader.policyDir)
  
  let fileName = case policyType
    of psStandard: "standard_policy.json"
    of psStrict: "strict_policy.json"
    of psPermissive: "permissive_policy.json"
    of psIncognito: "incognito_policy.json"
  
  return loader.policyDir / fileName

proc loadPolicy*(loader: PolicyLoader, policyType: PolicySet, reload: bool = false): CookiePolicy =
  ## 指定タイプのポリシーを読み込む
  
  # すでに読み込み済みで再読み込みが不要なら返す
  if not reload and loader.loadedPolicies.hasKey(policyType):
    return loader.loadedPolicies[policyType]
  
  # ファイルパスを取得
  let filePath = loader.getFilePathForPolicy(policyType)
  
  # ポリシーを作成
  var policy = createDefaultPolicy(policyType, filePath)
  
  # ファイルが存在すれば読み込む
  if filePath.len > 0 and fileExists(filePath):
    discard policy.loadFromFile(filePath)
  
  # キャッシュに保存
  loader.loadedPolicies[policyType] = policy
  return policy

proc getPolicyForProfile*(loader: PolicyLoader, profileName: string): CookiePolicy =
  ## プロファイル名に対応するポリシーを取得
  let policyType = case profileName.toLowerAscii
    of "private", "incognito": psIncognito
    of "strict": psStrict
    of "permissive": psPermissive
    else: psStandard
  
  return loader.loadPolicy(policyType)

proc exportPolicyToJson*(policy: CookiePolicy): JsonNode =
  ## ポリシーをJSON形式でエクスポート
  var entriesArray = newJArray()
  var domains = toSeq(policy.entries.keys)
  # ドメイン名でソート
  domains.sort()
  
  for domain in domains:
    let entry = policy.entries[domain]
    var entryObj = %*{
      "domain": entry.domain,
      "rule": $entry.rule,
      "priority": entry.priority,
      "is_system": not entry.isUserCreated
    }
    
    if entry.expiresAt.isSome:
      entryObj["expires"] = %entry.expiresAt.get().format("yyyy-MM-dd HH:mm:ss")
    
    entriesArray.add(entryObj)
  
  result = %*{
    "policy_type": (
      if policy.defaultThirdParty == prBlock and policy.defaultFirstParty == prAllowSession: "incognito"
      elif policy.defaultThirdParty == prBlock: "strict"
      elif policy.defaultThirdParty == prAllow: "permissive"
      else: "standard"
    ),
    "first_party_rule": $policy.defaultFirstParty,
    "third_party_rule": $policy.defaultThirdParty,
    "entries_count": entriesArray.len,
    "block_patterns_count": policy.blockPatterns.len,
    "exceptions_count": policy.domainExceptions.len,
    "entries": entriesArray,
    "block_patterns": policy.blockPatterns,
    "allow_patterns": policy.allowPatterns,
    "exceptions": toSeq(policy.domainExceptions).sorted()
  }

proc importPolicyFromJson*(jsonData: JsonNode): CookiePolicy =
  ## JSON形式からポリシーをインポート
  var policyType = psStandard
  
  # ポリシータイプの検出
  if jsonData.hasKey("policy_type"):
    let typeStr = jsonData["policy_type"].getStr
    case typeStr.toLowerAscii
    of "incognito": policyType = psIncognito
    of "strict": policyType = psStrict
    of "permissive": policyType = psPermissive
    of "standard": policyType = psStandard
    else: policyType = psStandard
  
  # 仮のパスでポリシーを作成
  result = createDefaultPolicy(policyType)
  
  # エントリを追加
  if jsonData.hasKey("entries"):
    for item in jsonData["entries"]:
      let domain = item["domain"].getStr
      var rule = prAllow
      
      if item.hasKey("rule"):
        let ruleStr = item["rule"].getStr
        for r in CookiePolicyRule:
          if $r == ruleStr:
            rule = r
      
      var priority = 100
      if item.hasKey("priority"):
        priority = item["priority"].getInt
      
      var isUserCreated = true
      if item.hasKey("is_system"):
        isUserCreated = not item["is_system"].getBool
      
      var expiresAt: Option[Time] = none(Time)
      if item.hasKey("expires"):
        try:
          let expiresStr = item["expires"].getStr
          expiresAt = some(parse(expiresStr, "yyyy-MM-dd HH:mm:ss"))
        except:
          discard
      
      discard result.addRule(
        domain = domain,
        rule = rule,
        isUserCreated = isUserCreated,
        priority = priority,
        expiresAt = expiresAt
      )
  
  # ブロックパターンを設定
  if jsonData.hasKey("block_patterns"):
    result.blockPatterns = @[]
    for pattern in jsonData["block_patterns"]:
      result.blockPatterns.add(pattern.getStr)
  
  # 許可パターンを設定
  if jsonData.hasKey("allow_patterns"):
    result.allowPatterns = @[]
    for pattern in jsonData["allow_patterns"]:
      result.allowPatterns.add(pattern.getStr)
  
  # 例外を設定
  if jsonData.hasKey("exceptions"):
    for domain in jsonData["exceptions"]:
      result.addException(domain.getStr)

proc mergePolicies*(primary: CookiePolicy, secondary: CookiePolicy, overwrite: bool = true): CookiePolicy =
  ## 2つのポリシーをマージ
  result = newCookiePolicy(
    userDataPath = primary.userDataPath,
    autoSave = primary.autoSave,
    defaultFirstPartyRule = primary.defaultFirstParty,
    defaultThirdPartyRule = primary.defaultThirdParty
  )
  
  # ブロックパターンをマージ
  var blockPatterns = initHashSet[string]()
  for pattern in primary.blockPatterns:
    blockPatterns.incl(pattern)
  for pattern in secondary.blockPatterns:
    blockPatterns.incl(pattern)
  result.blockPatterns = toSeq(blockPatterns)
  
  # 許可パターンをマージ
  var allowPatterns = initHashSet[string]()
  for pattern in primary.allowPatterns:
    allowPatterns.incl(pattern)
  for pattern in secondary.allowPatterns:
    allowPatterns.incl(pattern)
  result.allowPatterns = toSeq(allowPatterns)
  
  # 例外をマージ
  result.domainExceptions = primary.domainExceptions
  for domain in secondary.domainExceptions:
    result.domainExceptions.incl(domain)
  
  # エントリをマージ（プライマリ優先、上書きオプションに従う）
  # まずセカンダリからコピー
  for domain, entry in secondary.entries:
    if not primary.entries.hasKey(domain) or overwrite:
      result.entries[domain] = entry
  
  # プライマリのエントリを優先
  for domain, entry in primary.entries:
    result.entries[domain] = entry 