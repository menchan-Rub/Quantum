# cookie_policy.nim
## クッキーポリシー管理モジュール - サイト別のクッキーポリシーを定義・管理

import std/[
  tables,
  options,
  sets,
  sugar,
  strutils,
  algorithm,
  json,
  os,
  times
]
import ../cookie_types

type
  CookiePolicyRule* = enum
    ## ポリシールールの種類
    prAllow,         # 許可
    prBlock,         # ブロック
    prAllowSession,  # セッションのみ許可（永続的クッキーをセッションに変換）
    prAllowFirstParty, # ファーストパーティのみ許可
    prPartition,     # 分離して許可
    prPrompt         # ユーザーに確認

  CookiePolicyEntry* = object
    ## サイト別ポリシーエントリ
    domain*: string            # 対象ドメイン
    rule*: CookiePolicyRule    # 適用ルール
    createdAt*: Time           # 作成時刻
    lastUpdated*: Time         # 最終更新時刻
    expiresAt*: Option[Time]   # 有効期限（任意）
    isUserCreated*: bool       # ユーザーが作成したポリシーか
    priority*: int             # 優先度（高いほど優先）
  
  CookiePolicy* = ref object
    ## クッキーポリシーシステム
    entries*: Table[string, CookiePolicyEntry]  # ドメイン別ポリシー
    defaultFirstParty*: CookiePolicyRule        # ファーストパーティのデフォルトルール
    defaultThirdParty*: CookiePolicyRule        # サードパーティのデフォルトルール
    blockPatterns*: seq[string]                 # ブロックするクッキー名パターン
    allowPatterns*: seq[string]                 # 常に許可するクッキー名パターン
    userDataPath*: string                       # 設定ファイルパス
    autoSave*: bool                             # 変更時に自動保存するか
    domainExceptions*: HashSet[string]          # 例外ドメイン（システム設定より優先）

###################
# コンストラクタ
###################

proc newCookiePolicy*(
  userDataPath: string = "",
  autoSave: bool = true,
  defaultFirstPartyRule: CookiePolicyRule = prAllow,
  defaultThirdPartyRule: CookiePolicyRule = prAllowFirstParty
): CookiePolicy =
  ## 新しいクッキーポリシーを作成
  result = CookiePolicy(
    entries: initTable[string, CookiePolicyEntry](),
    defaultFirstParty: defaultFirstPartyRule,
    defaultThirdParty: defaultThirdPartyRule,
    blockPatterns: @[],
    allowPatterns: @[],
    userDataPath: userDataPath,
    autoSave: autoSave,
    domainExceptions: initHashSet[string]()
  )
  
  # デフォルトのブロックパターン
  result.blockPatterns = @[
    "tracker", "analytics", "beacon", "pixel", "visitor",
    "counter", "monitor", "stats_", "_stats", "statistics"
  ]
  
  # デフォルトの許可パターン
  result.allowPatterns = @[
    "session", "login", "auth", "csrf", "xsrf", "token"
  ]
  
  # 設定ファイルがあれば読み込み
  if userDataPath.len > 0 and fileExists(userDataPath):
    discard result.loadFromFile(userDataPath)

###################
# ポリシー管理
###################

proc addRule*(policy: CookiePolicy, domain: string, rule: CookiePolicyRule, 
             isUserCreated: bool = true, priority: int = 100,
             expiresAt: Option[Time] = none(Time)): bool =
  ## ドメイン別ポリシールールを追加
  let normalizedDomain = domain.toLowerAscii
  let now = getTime()
  
  policy.entries[normalizedDomain] = CookiePolicyEntry(
    domain: normalizedDomain,
    rule: rule,
    createdAt: now,
    lastUpdated: now,
    expiresAt: expiresAt,
    isUserCreated: isUserCreated,
    priority: priority
  )
  
  # 自動保存
  if policy.autoSave and policy.userDataPath.len > 0:
    discard policy.saveToFile(policy.userDataPath)
  
  return true

proc removeRule*(policy: CookiePolicy, domain: string): bool =
  ## ドメイン別ポリシールールを削除
  let normalizedDomain = domain.toLowerAscii
  
  if policy.entries.hasKey(normalizedDomain):
    policy.entries.del(normalizedDomain)
    
    # 自動保存
    if policy.autoSave and policy.userDataPath.len > 0:
      discard policy.saveToFile(policy.userDataPath)
    
    return true
  
  return false

proc getRuleForDomain*(policy: CookiePolicy, domain: string): CookiePolicyRule =
  ## ドメイン用のポリシールールを取得
  let normalizedDomain = domain.toLowerAscii
  
  # 例外ドメインチェック
  if normalizedDomain in policy.domainExceptions:
    return prAllow
  
  # 完全一致のルールを検索
  if policy.entries.hasKey(normalizedDomain):
    let entry = policy.entries[normalizedDomain]
    if entry.expiresAt.isNone or getTime() < entry.expiresAt.get():
      return entry.rule
  
  # パターンマッチングによるルール検索（ワイルドカード対応）
  var matchingRule: Option[CookiePolicyEntry] = none(CookiePolicyEntry)
  var highestPriority = -1
  
  for entryDomain, entry in policy.entries:
    # ワイルドカードマッチング（*.example.com）
    if entryDomain.startsWith("*.") and 
       normalizedDomain.endsWith(entryDomain[1..^1]):
      if entry.priority > highestPriority:
        matchingRule = some(entry)
        highestPriority = entry.priority
    
    # サブドメインマッチング（.example.com）
    elif entryDomain.startsWith(".") and
        (normalizedDomain.endsWith(entryDomain) or 
         normalizedDomain == entryDomain[1..^1]):
      if entry.priority > highestPriority:
        matchingRule = some(entry)
        highestPriority = entry.priority
  
  if matchingRule.isSome:
    let entry = matchingRule.get()
    if entry.expiresAt.isNone or getTime() < entry.expiresAt.get():
      return entry.rule
  
  # デフォルトルールを返す（ファーストパーティの場合）
  return policy.defaultFirstParty

proc isFirstPartyContext*(domain: string, documentDomain: string): bool =
  ## ファーストパーティコンテキストか判断
  
  # 完全一致
  if domain == documentDomain:
    return true
  
  # サブドメインとして一致するか確認
  let domainParts = domain.split('.')
  let documentParts = documentDomain.split('.')
  
  if domainParts.len < 2 or documentParts.len < 2:
    return false
  
  # eTLD+1の比較（例：example.comの部分）
  let domainBase = domainParts[^2] & "." & domainParts[^1]
  let documentBase = documentParts[^2] & "." & documentParts[^1]
  
  return domainBase == documentBase

proc getRuleForContext*(policy: CookiePolicy, cookieDomain: string, 
                        documentDomain: string): CookiePolicyRule =
  ## コンテキストに応じたポリシールールを取得
  # まず特定ドメイン用のルールを確認
  let domainRule = policy.getRuleForDomain(cookieDomain)
  if domainRule != policy.defaultFirstParty:
    return domainRule
  
  # ファーストパーティかサードパーティかで判断
  if isFirstPartyContext(cookieDomain, documentDomain):
    return policy.defaultFirstParty
  else:
    return policy.defaultThirdParty

proc shouldBlockCookieName*(policy: CookiePolicy, name: string): bool =
  ## クッキー名に基づくブロック判定
  let nameNorm = name.toLowerAscii
  
  # 許可パターンを優先チェック
  for pattern in policy.allowPatterns:
    if nameNorm.contains(pattern):
      return false
  
  # ブロックパターンをチェック
  for pattern in policy.blockPatterns:
    if nameNorm.contains(pattern):
      return true
  
  return false

###################
# 永続化
###################

proc saveToFile*(policy: CookiePolicy, filePath: string): bool =
  ## ポリシーを設定ファイルに保存
  try:
    var jsonEntries = newJArray()
    
    for domain, entry in policy.entries:
      var jsonEntry = %*{
        "domain": entry.domain,
        "rule": $entry.rule,
        "created_at": entry.createdAt.toUnix(),
        "last_updated": entry.lastUpdated.toUnix(),
        "is_user_created": entry.isUserCreated,
        "priority": entry.priority
      }
      
      if entry.expiresAt.isSome:
        jsonEntry["expires_at"] = %entry.expiresAt.get().toUnix()
      
      jsonEntries.add(jsonEntry)
    
    let jsonData = %*{
      "entries": jsonEntries,
      "default_first_party": $policy.defaultFirstParty,
      "default_third_party": $policy.defaultThirdParty,
      "block_patterns": policy.blockPatterns,
      "allow_patterns": policy.allowPatterns,
      "exceptions": toSeq(policy.domainExceptions)
    }
    
    writeFile(filePath, $jsonData)
    return true
  except:
    return false

proc loadFromFile*(policy: CookiePolicy, filePath: string): bool =
  ## ポリシーを設定ファイルから読み込み
  try:
    if not fileExists(filePath):
      return false
    
    let jsonContent = parseJson(readFile(filePath))
    
    # デフォルト設定の読み込み
    if jsonContent.hasKey("default_first_party"):
      let ruleStr = jsonContent["default_first_party"].getStr()
      for rule in CookiePolicyRule:
        if $rule == ruleStr:
          policy.defaultFirstParty = rule
    
    if jsonContent.hasKey("default_third_party"):
      let ruleStr = jsonContent["default_third_party"].getStr()
      for rule in CookiePolicyRule:
        if $rule == ruleStr:
          policy.defaultThirdParty = rule
    
    # パターンの読み込み
    if jsonContent.hasKey("block_patterns"):
      policy.blockPatterns = @[]
      for pattern in jsonContent["block_patterns"]:
        policy.blockPatterns.add(pattern.getStr())
    
    if jsonContent.hasKey("allow_patterns"):
      policy.allowPatterns = @[]
      for pattern in jsonContent["allow_patterns"]:
        policy.allowPatterns.add(pattern.getStr())
    
    # 例外ドメインの読み込み
    if jsonContent.hasKey("exceptions"):
      policy.domainExceptions = initHashSet[string]()
      for domain in jsonContent["exceptions"]:
        policy.domainExceptions.incl(domain.getStr())
    
    # エントリの読み込み
    policy.entries.clear()
    if jsonContent.hasKey("entries"):
      for item in jsonContent["entries"]:
        let domain = item["domain"].getStr()
        var rule = prAllow
        let ruleStr = item["rule"].getStr()
        
        for r in CookiePolicyRule:
          if $r == ruleStr:
            rule = r
        
        let createdAt = fromUnix(item["created_at"].getBiggestInt())
        let lastUpdated = fromUnix(item["last_updated"].getBiggestInt())
        let isUserCreated = item["is_user_created"].getBool()
        let priority = item["priority"].getInt()
        
        var expiresAt: Option[Time] = none(Time)
        if item.hasKey("expires_at"):
          expiresAt = some(fromUnix(item["expires_at"].getBiggestInt()))
        
        policy.entries[domain] = CookiePolicyEntry(
          domain: domain,
          rule: rule,
          createdAt: createdAt,
          lastUpdated: lastUpdated,
          expiresAt: expiresAt,
          isUserCreated: isUserCreated,
          priority: priority
        )
    
    return true
  except:
    return false

###################
# 例外管理
###################

proc addException*(policy: CookiePolicy, domain: string) =
  ## ドメインを例外として追加（常に許可）
  policy.domainExceptions.incl(domain.toLowerAscii)
  
  # 自動保存
  if policy.autoSave and policy.userDataPath.len > 0:
    discard policy.saveToFile(policy.userDataPath)

proc removeException*(policy: CookiePolicy, domain: string): bool =
  ## ドメインの例外を削除
  let normalizedDomain = domain.toLowerAscii
  if normalizedDomain in policy.domainExceptions:
    policy.domainExceptions.excl(normalizedDomain)
    
    # 自動保存
    if policy.autoSave and policy.userDataPath.len > 0:
      discard policy.saveToFile(policy.userDataPath)
    
    return true
  
  return false

proc clearExpiredRules*(policy: CookiePolicy): int =
  ## 期限切れのルールをクリーンアップ
  result = 0
  let now = getTime()
  var expiredDomains: seq[string] = @[]
  
  for domain, entry in policy.entries:
    if entry.expiresAt.isSome and now >= entry.expiresAt.get():
      expiredDomains.add(domain)
  
  for domain in expiredDomains:
    policy.entries.del(domain)
    result.inc
  
  # 自動保存
  if result > 0 and policy.autoSave and policy.userDataPath.len > 0:
    discard policy.saveToFile(policy.userDataPath) 