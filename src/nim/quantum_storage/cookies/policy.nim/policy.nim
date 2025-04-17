# Cookieポリシー管理モジュール
# このモジュールはブラウザのCookieポリシーを管理します

import std/[
  tables,
  options,
  times,
  json,
  os,
  strutils,
  uri,
  hashes,
  logging,
  sequtils,
  strformat,
  sugar,
  re
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, settings]
import ../common/base

type
  CookieAction* = enum
    ## Cookieに対するアクション
    caAccept,      # Cookieを許可
    caReject,      # Cookieを拒否
    caAskUser,     # ユーザーに確認
    caAcceptSession # セッション中のみ許可

  CookieCategoryLevel* = enum
    ## Cookieのカテゴリレベル
    cclEssential,  # 必須Cookie（常に許可）
    cclFunctional, # 機能Cookie（サイト機能向上）
    cclAnalytics,  # 分析Cookie（使用状況分析）
    cclAdvertising, # 広告Cookie（ターゲティング広告）
    cclUnknown     # 不明なCookie（デフォルトポリシー適用）

  CookieSourceType* = enum
    ## Cookieのソースタイプ
    cstFirstParty, # ファーストパーティCookie
    cstThirdParty  # サードパーティCookie

  PolicyMode* = enum
    ## ポリシーモード
    pmStrict,      # 厳格（ほとんどのCookieをブロック）
    pmBalanced,    # バランス（必要なCookieを許可）
    pmPermissive,  # 寛容（ほとんどのCookieを許可）
    pmCustom       # カスタム設定

  CookieRule* = object
    ## Cookie適用ルール
    domainPattern*: string  # ドメインパターン (正規表現)
    namePattern*: string    # Cookie名パターン (正規表現、空白は全て)
    action*: CookieAction   # 適用アクション
    category*: CookieCategoryLevel # Cookieカテゴリ
    sourceType*: CookieSourceType  # ソースタイプ
    description*: string    # ルールの説明
    expirationMaxDays*: Option[int] # 最大有効期限（日）

  CookiePolicySettings* = object
    ## Cookieポリシー設定
    mode*: PolicyMode      # ポリシーモード
    thirdPartyCookiesBlocked*: bool # サードパーティCookieをブロック
    allowUserPreference*: bool # ユーザー設定を許可
    notificationEnabled*: bool # Cookie通知を有効化
    retentionPeriod*: int  # Cookie保持期間（日）
    autoDeleteOnExit*: bool # 終了時に削除
    whitelistedDomains*: seq[string] # ホワイトリストドメイン
    blacklistedDomains*: seq[string] # ブラックリストドメイン
    categorySettings*: Table[CookieCategoryLevel, CookieAction] # カテゴリ別設定

  PolicyStats* = object
    ## ポリシー適用統計
    cookiesAccepted*: int  # 許可されたCookie数
    cookiesRejected*: int  # 拒否されたCookie数
    userPrompts*: int      # ユーザー確認回数
    lastApplied*: DateTime # 最終適用日時

  CookiePolicy* = ref object
    ## Cookieポリシーオブジェクト
    settings*: CookiePolicySettings # ポリシー設定
    rules*: seq[CookieRule]  # ルールリスト
    domainSpecificSettings*: Table[string, CookieAction] # ドメイン固有設定
    stats*: PolicyStats     # 統計情報
    initialized*: bool      # 初期化済みフラグ

# デフォルト設定値
const
  DEFAULT_RETENTION_PERIOD* = 90 # デフォルトの保持期間（日）
  
  # 定義済みルール（よく知られているCookieに対する推奨アクション）
  PREDEFINED_RULES* = [
    CookieRule(
      domainPattern: r".*",
      namePattern: r"^(sess|session|PHPSESSID|JSESSIONID).*$",
      action: CookieAction.caAcceptSession,
      category: CookieCategoryLevel.cclEssential,
      sourceType: CookieSourceType.cstFirstParty,
      description: "セッションCookie",
      expirationMaxDays: some(1)
    ),
    CookieRule(
      domainPattern: r".*google-analytics\.com|.*googletagmanager\.com",
      namePattern: r"^(_ga|_gid|_gat|_gtm).*$",
      action: CookieAction.caReject,
      category: CookieCategoryLevel.cclAnalytics,
      sourceType: CookieSourceType.cstThirdParty,
      description: "Google Analyticsトラッキング",
      expirationMaxDays: some(730)
    ),
    CookieRule(
      domainPattern: r".*facebook\.com|.*fb\.com",
      namePattern: r"^(fr|_fbp|_fbc).*$",
      action: CookieAction.caReject,
      category: CookieCategoryLevel.cclAdvertising,
      sourceType: CookieSourceType.cstThirdParty,
      description: "Facebook広告トラッキング",
      expirationMaxDays: some(90)
    ),
    CookieRule(
      domainPattern: r".*doubleclick\.net",
      namePattern: r".*",
      action: CookieAction.caReject,
      category: CookieCategoryLevel.cclAdvertising,
      sourceType: CookieSourceType.cstThirdParty,
      description: "DoubleClick広告トラッキング",
      expirationMaxDays: some(365)
    ),
    CookieRule(
      domainPattern: r".*",
      namePattern: r"^(_pk_|pk_|piwik_|matomo_).*$", 
      action: CookieAction.caReject,
      category: CookieCategoryLevel.cclAnalytics,
      sourceType: CookieSourceType.cstThirdParty,
      description: "Matomo/Piwik分析",
      expirationMaxDays: some(395)
    ),
    CookieRule(
      domainPattern: r".*",
      namePattern: r"^(wp-settings|wordpress_|wp_).*$",
      action: CookieAction.caAccept,
      category: CookieCategoryLevel.cclFunctional,
      sourceType: CookieSourceType.cstFirstParty,
      description: "WordPress機能Cookie",
      expirationMaxDays: some(365)
    ),
    CookieRule(
      domainPattern: r".*",
      namePattern: r"^(cf_|cloudflare).*$",
      action: CookieAction.caAccept,
      category: CookieCategoryLevel.cclEssential,
      sourceType: CookieSourceType.cstFirstParty,
      description: "Cloudflareセキュリティ",
      expirationMaxDays: some(30)
    )
  ]

# -----------------------------------------------
# Helper Functions
# -----------------------------------------------

proc ruleMatchesDomain*(rule: CookieRule, domain: string): bool =
  ## ルールがドメインにマッチするか確認
  try:
    let regex = re(rule.domainPattern)
    return domain.match(regex)
  except:
    error "Invalid domain pattern regex", pattern = rule.domainPattern, error = getCurrentExceptionMsg()
    return false

proc ruleMatchesCookieName*(rule: CookieRule, name: string): bool =
  ## ルールがCookie名にマッチするか確認
  if rule.namePattern == ".*" or rule.namePattern == "":
    return true
  
  try:
    let regex = re(rule.namePattern)
    return name.match(regex)
  except:
    error "Invalid cookie name pattern regex", pattern = rule.namePattern, error = getCurrentExceptionMsg()
    return false

proc getSourceTypeForCookie*(cookieDomain, requestDomain: string): CookieSourceType =
  ## CookieのソースタイプをURL間の関係から判定
  # ドメイン抽出
  var 
    cookieDomainOnly = cookieDomain
    requestDomainOnly = requestDomain
  
  # スキーマやパスを削除、ホスト部分だけ抽出
  try:
    let cookieUri = parseUri(cookieDomain)
    if cookieUri.hostname.len > 0:
      cookieDomainOnly = cookieUri.hostname
  except:
    discard # そのまま使用
  
  try:
    let requestUri = parseUri(requestDomain)
    if requestUri.hostname.len > 0:
      requestDomainOnly = requestUri.hostname
  except:
    discard # そのまま使用
  
  # トップレベルドメイン比較（単純化のため）
  let 
    cookieParts = cookieDomainOnly.split(".")
    requestParts = requestDomainOnly.split(".")
  
  # 同じドメインか判定するための簡易的なチェック
  if cookieParts.len >= 2 and requestParts.len >= 2:
    # 最後の2つの部分が一致するかチェック (example.com)
    let 
      cookieTld = cookieParts[^2..^1].join(".")
      requestTld = requestParts[^2..^1].join(".")
    
    if cookieTld == requestTld:
      return CookieSourceType.cstFirstParty
  
  # サブドメインを含めた完全一致
  if cookieDomainOnly == requestDomainOnly:
    return CookieSourceType.cstFirstParty
    
  # マッチしない場合はサードパーティ
  return CookieSourceType.cstThirdParty

proc guessCategory*(name, domain: string): CookieCategoryLevel =
  ## Cookie名とドメインからカテゴリを推測
  # 必須系Cookie
  if name.toLowerAscii().contains(re"(sess|session|csrf|xsrf|token|auth|login|secure|__cfduid|captcha)"):
    return CookieCategoryLevel.cclEssential
  
  # 分析系Cookie
  if name.toLowerAscii().contains(re"(analytics|_ga|_gid|utm_|pixel|stat|metrics|_pk_|piwik)") or
     domain.toLowerAscii().contains(re"(analytics|stats|pixel|count|metric)"):
    return CookieCategoryLevel.cclAnalytics
  
  # 広告系Cookie
  if name.toLowerAscii().contains(re"(ad|ads|adsense|advert|doubleclick|banner|sponsor|campaign|targeting|marketing)") or
     domain.toLowerAscii().contains(re"(ads|ad.|doubleclick|advert|banner)"):
    return CookieCategoryLevel.cclAdvertising
  
  # 機能系Cookie
  if name.toLowerAscii().contains(re"(prefs|preference|settings|config|lang|locale|region|country|currency|cart|shipping)"):
    return CookieCategoryLevel.cclFunctional
  
  # デフォルト
  return CookieCategoryLevel.cclUnknown

# -----------------------------------------------
# CookiePolicy Implementation
# -----------------------------------------------

proc defaultCategorySettings(): Table[CookieCategoryLevel, CookieAction] =
  ## デフォルトのカテゴリ別設定を返す
  result = {
    CookieCategoryLevel.cclEssential: CookieAction.caAccept,
    CookieCategoryLevel.cclFunctional: CookieAction.caAskUser,
    CookieCategoryLevel.cclAnalytics: CookieAction.caReject,
    CookieCategoryLevel.cclAdvertising: CookieAction.caReject,
    CookieCategoryLevel.cclUnknown: CookieAction.caAskUser
  }.toTable

proc defaultSettings(): CookiePolicySettings =
  ## デフォルトのポリシー設定を返す
  result = CookiePolicySettings(
    mode: PolicyMode.pmBalanced,
    thirdPartyCookiesBlocked: true,
    allowUserPreference: true,
    notificationEnabled: true,
    retentionPeriod: DEFAULT_RETENTION_PERIOD,
    autoDeleteOnExit: false,
    whitelistedDomains: @[],
    blacklistedDomains: @[],
    categorySettings: defaultCategorySettings()
  )

proc newCookiePolicy*(): CookiePolicy =
  ## 新しいCookieポリシーインスタンスを作成
  result = CookiePolicy(
    settings: defaultSettings(),
    rules: @PREDEFINED_RULES,
    domainSpecificSettings: initTable[string, CookieAction](),
    stats: PolicyStats(
      cookiesAccepted: 0,
      cookiesRejected: 0,
      userPrompts: 0,
      lastApplied: now()
    ),
    initialized: true
  )

proc setMode*(self: CookiePolicy, mode: PolicyMode) =
  ## ポリシーモードを設定
  self.settings.mode = mode
  
  # モードに基づいて各カテゴリの設定を更新
  case mode:
    of PolicyMode.pmStrict:
      self.settings.categorySettings[CookieCategoryLevel.cclEssential] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclFunctional] = CookieAction.caReject
      self.settings.categorySettings[CookieCategoryLevel.cclAnalytics] = CookieAction.caReject
      self.settings.categorySettings[CookieCategoryLevel.cclAdvertising] = CookieAction.caReject
      self.settings.categorySettings[CookieCategoryLevel.cclUnknown] = CookieAction.caReject
      self.settings.thirdPartyCookiesBlocked = true
      
    of PolicyMode.pmBalanced:
      self.settings.categorySettings[CookieCategoryLevel.cclEssential] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclFunctional] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclAnalytics] = CookieAction.caAskUser
      self.settings.categorySettings[CookieCategoryLevel.cclAdvertising] = CookieAction.caReject
      self.settings.categorySettings[CookieCategoryLevel.cclUnknown] = CookieAction.caAskUser
      self.settings.thirdPartyCookiesBlocked = true
      
    of PolicyMode.pmPermissive:
      self.settings.categorySettings[CookieCategoryLevel.cclEssential] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclFunctional] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclAnalytics] = CookieAction.caAccept
      self.settings.categorySettings[CookieCategoryLevel.cclAdvertising] = CookieAction.caAskUser
      self.settings.categorySettings[CookieCategoryLevel.cclUnknown] = CookieAction.caAccept
      self.settings.thirdPartyCookiesBlocked = false
      
    of PolicyMode.pmCustom:
      # カスタムモードでは既存の設定を保持
      discard
  
  info "Cookie policy mode set to " & $mode

proc setCategoryAction*(self: CookiePolicy, category: CookieCategoryLevel, action: CookieAction) =
  ## カテゴリごとのアクションを設定
  self.settings.categorySettings[category] = action
  
  # カスタムモードに変更
  if self.settings.mode != PolicyMode.pmCustom:
    self.settings.mode = PolicyMode.pmCustom
    info "Switched to custom policy mode due to category action change"
  
  info "Set action for category", category = $category, action = $action

proc addRule*(self: CookiePolicy, rule: CookieRule) =
  ## カスタムルールを追加
  # 既存のルールを確認し、重複を置き換え
  var ruleExists = false
  for i in 0..<self.rules.len:
    if self.rules[i].domainPattern == rule.domainPattern and 
       self.rules[i].namePattern == rule.namePattern:
      self.rules[i] = rule
      ruleExists = true
      info "Updated existing cookie rule", domain = rule.domainPattern, name = rule.namePattern
      break
  
  if not ruleExists:
    self.rules.add(rule)
    info "Added new cookie rule", domain = rule.domainPattern, name = rule.namePattern

proc removeRule*(self: CookiePolicy, domainPattern, namePattern: string) =
  ## ルールを削除
  let initialCount = self.rules.len
  self.rules.keepItIf(it.domainPattern != domainPattern or it.namePattern != namePattern)
  
  let removedCount = initialCount - self.rules.len
  info "Removed cookie rules", count = removedCount, domain = domainPattern, name = namePattern

proc addToWhitelist*(self: CookiePolicy, domain: string) =
  ## ドメインをホワイトリストに追加
  if domain notin self.settings.whitelistedDomains:
    self.settings.whitelistedDomains.add(domain)
    
    # ブラックリストにある場合は削除
    if domain in self.settings.blacklistedDomains:
      self.settings.blacklistedDomains.keepItIf(it != domain)
      
    info "Domain added to whitelist", domain = domain

proc addToBlacklist*(self: CookiePolicy, domain: string) =
  ## ドメインをブラックリストに追加
  if domain notin self.settings.blacklistedDomains:
    self.settings.blacklistedDomains.add(domain)
    
    # ホワイトリストにある場合は削除
    if domain in self.settings.whitelistedDomains:
      self.settings.whitelistedDomains.keepItIf(it != domain)
      
    info "Domain added to blacklist", domain = domain

proc removeFromWhitelist*(self: CookiePolicy, domain: string) =
  ## ドメインをホワイトリストから削除
  self.settings.whitelistedDomains.keepItIf(it != domain)
  info "Domain removed from whitelist", domain = domain

proc removeFromBlacklist*(self: CookiePolicy, domain: string) =
  ## ドメインをブラックリストから削除
  self.settings.blacklistedDomains.keepItIf(it != domain)
  info "Domain removed from blacklist", domain = domain

proc setDomainSpecificAction*(self: CookiePolicy, domain: string, action: CookieAction) =
  ## ドメイン固有のアクションを設定
  self.domainSpecificSettings[domain] = action
  info "Set specific action for domain", domain = domain, action = $action

proc removeDomainSpecificAction*(self: CookiePolicy, domain: string) =
  ## ドメイン固有のアクションを削除
  if self.domainSpecificSettings.hasKey(domain):
    self.domainSpecificSettings.del(domain)
    info "Removed specific action for domain", domain = domain

proc setThirdPartyCookieBlocking*(self: CookiePolicy, blocked: bool) =
  ## サードパーティCookieブロック設定を変更
  self.settings.thirdPartyCookiesBlocked = blocked
  info "Third-party cookie blocking", enabled = blocked

proc setRetentionPeriod*(self: CookiePolicy, days: int) =
  ## Cookie保持期間を設定
  if days < 0:
    raise newException(ValueError, "Retention period cannot be negative")
    
  self.settings.retentionPeriod = days
  info "Cookie retention period set", days = days

proc toggleNotifications*(self: CookiePolicy, enabled: bool) =
  ## Cookie通知の有効/無効を切り替え
  self.settings.notificationEnabled = enabled
  info "Cookie notifications", enabled = enabled

proc toggleAutoDeleteOnExit*(self: CookiePolicy, enabled: bool) =
  ## 終了時の自動削除設定を切り替え
  self.settings.autoDeleteOnExit = enabled
  info "Auto-delete cookies on exit", enabled = enabled

# -----------------------------------------------
# Policy Application Logic
# -----------------------------------------------

proc shouldAcceptCookie*(self: CookiePolicy, cookieName, domain, requestDomain: string): CookieAction =
  ## 特定のCookieを受け入れるべきかを決定
  # 統計情報の最終適用時刻を更新
  self.stats.lastApplied = now()
  
  # ドメイン固有の設定をチェック
  if self.domainSpecificSettings.hasKey(domain):
    let action = self.domainSpecificSettings[domain]
    info "Applied domain-specific action", domain = domain, action = $action
    return action
  
  # ホワイトリスト/ブラックリストをチェック
  if domain in self.settings.whitelistedDomains:
    inc self.stats.cookiesAccepted
    info "Domain in whitelist, accepting cookie", domain = domain, cookie = cookieName
    return CookieAction.caAccept
    
  if domain in self.settings.blacklistedDomains:
    inc self.stats.cookiesRejected
    info "Domain in blacklist, rejecting cookie", domain = domain, cookie = cookieName
    return CookieAction.caReject
  
  # ソースタイプを決定
  let sourceType = getSourceTypeForCookie(domain, requestDomain)
  
  # サードパーティCookieブロック設定をチェック
  if sourceType == CookieSourceType.cstThirdParty and self.settings.thirdPartyCookiesBlocked:
    inc self.stats.cookiesRejected
    info "Third-party cookie blocked", domain = domain, cookie = cookieName
    return CookieAction.caReject
  
  # 定義済みルールをチェック
  for rule in self.rules:
    if ruleMatchesDomain(rule, domain) and ruleMatchesCookieName(rule, cookieName):
      case rule.action:
        of CookieAction.caAccept:
          inc self.stats.cookiesAccepted
        of CookieAction.caReject:
          inc self.stats.cookiesRejected
        of CookieAction.caAskUser:
          inc self.stats.userPrompts
        of CookieAction.caAcceptSession:
          inc self.stats.cookiesAccepted
      
      info "Applied rule for cookie", domain = domain, cookie = cookieName, action = $rule.action
      return rule.action
  
  # ルールにマッチしない場合はカテゴリベースの判断
  let category = guessCategory(cookieName, domain)
  let categoryAction = self.settings.categorySettings.getOrDefault(category, CookieAction.caAskUser)
  
  case categoryAction:
    of CookieAction.caAccept:
      inc self.stats.cookiesAccepted
    of CookieAction.caReject:
      inc self.stats.cookiesRejected
    of CookieAction.caAskUser:
      inc self.stats.userPrompts
    of CookieAction.caAcceptSession:
      inc self.stats.cookiesAccepted
  
  info "Applied category-based action", domain = domain, cookie = cookieName, 
       category = $category, action = $categoryAction
  
  return categoryAction

proc resetStats*(self: CookiePolicy) =
  ## 統計情報をリセット
  self.stats = PolicyStats(
    cookiesAccepted: 0,
    cookiesRejected: 0,
    userPrompts: 0,
    lastApplied: now()
  )
  info "Reset cookie policy statistics"

# -----------------------------------------------
# Settings Serialization
# -----------------------------------------------

proc toJson*(self: CookiePolicy): JsonNode =
  ## ポリシー設定をJSONに変換
  var categorySettings = newJObject()
  for category, action in self.settings.categorySettings.pairs:
    categorySettings[$category] = %($action)
  
  var rules = newJArray()
  for rule in self.rules:
    var ruleObj = %*{
      "domainPattern": rule.domainPattern,
      "namePattern": rule.namePattern,
      "action": $rule.action,
      "category": $rule.category,
      "sourceType": $rule.sourceType,
      "description": rule.description
    }
    
    if rule.expirationMaxDays.isSome:
      ruleObj["expirationMaxDays"] = %rule.expirationMaxDays.get()
      
    rules.add(ruleObj)
  
  var domainSettings = newJObject()
  for domain, action in self.domainSpecificSettings.pairs:
    domainSettings[domain] = %($action)
  
  result = %*{
    "settings": {
      "mode": $self.settings.mode,
      "thirdPartyCookiesBlocked": self.settings.thirdPartyCookiesBlocked,
      "allowUserPreference": self.settings.allowUserPreference,
      "notificationEnabled": self.settings.notificationEnabled,
      "retentionPeriod": self.settings.retentionPeriod,
      "autoDeleteOnExit": self.settings.autoDeleteOnExit,
      "whitelistedDomains": self.settings.whitelistedDomains,
      "blacklistedDomains": self.settings.blacklistedDomains,
      "categorySettings": categorySettings
    },
    "rules": rules,
    "domainSpecificSettings": domainSettings,
    "stats": {
      "cookiesAccepted": self.stats.cookiesAccepted,
      "cookiesRejected": self.stats.cookiesRejected,
      "userPrompts": self.stats.userPrompts,
      "lastApplied": self.stats.lastApplied.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
  }

proc fromJson*(self: CookiePolicy, json: JsonNode) =
  ## JSONからポリシー設定を読み込み
  if json.hasKey("settings"):
    let settings = json["settings"]
    
    if settings.hasKey("mode"):
      self.settings.mode = parseEnum[PolicyMode](settings["mode"].getStr())
    
    if settings.hasKey("thirdPartyCookiesBlocked"):
      self.settings.thirdPartyCookiesBlocked = settings["thirdPartyCookiesBlocked"].getBool()
    
    if settings.hasKey("allowUserPreference"):
      self.settings.allowUserPreference = settings["allowUserPreference"].getBool()
    
    if settings.hasKey("notificationEnabled"):
      self.settings.notificationEnabled = settings["notificationEnabled"].getBool()
    
    if settings.hasKey("retentionPeriod"):
      self.settings.retentionPeriod = settings["retentionPeriod"].getInt()
    
    if settings.hasKey("autoDeleteOnExit"):
      self.settings.autoDeleteOnExit = settings["autoDeleteOnExit"].getBool()
    
    if settings.hasKey("whitelistedDomains"):
      self.settings.whitelistedDomains = settings["whitelistedDomains"].to(seq[string])
    
    if settings.hasKey("blacklistedDomains"):
      self.settings.blacklistedDomains = settings["blacklistedDomains"].to(seq[string])
    
    if settings.hasKey("categorySettings"):
      let categorySettings = settings["categorySettings"]
      for k, v in categorySettings.pairs:
        let 
          category = parseEnum[CookieCategoryLevel](k)
          action = parseEnum[CookieAction](v.getStr())
        self.settings.categorySettings[category] = action
  
  if json.hasKey("rules"):
    self.rules = @[]
    for ruleJson in json["rules"]:
      var rule = CookieRule(
        domainPattern: ruleJson["domainPattern"].getStr(),
        namePattern: ruleJson["namePattern"].getStr(),
        action: parseEnum[CookieAction](ruleJson["action"].getStr()),
        category: parseEnum[CookieCategoryLevel](ruleJson["category"].getStr()),
        sourceType: parseEnum[CookieSourceType](ruleJson["sourceType"].getStr()),
        description: ruleJson["description"].getStr()
      )
      
      if ruleJson.hasKey("expirationMaxDays"):
        rule.expirationMaxDays = some(ruleJson["expirationMaxDays"].getInt())
      
      self.rules.add(rule)
  
  if json.hasKey("domainSpecificSettings"):
    self.domainSpecificSettings = initTable[string, CookieAction]()
    for k, v in json["domainSpecificSettings"].pairs:
      self.domainSpecificSettings[k] = parseEnum[CookieAction](v.getStr())
  
  if json.hasKey("stats"):
    let stats = json["stats"]
    if stats.hasKey("cookiesAccepted"):
      self.stats.cookiesAccepted = stats["cookiesAccepted"].getInt()
    
    if stats.hasKey("cookiesRejected"):
      self.stats.cookiesRejected = stats["cookiesRejected"].getInt()
    
    if stats.hasKey("userPrompts"):
      self.stats.userPrompts = stats["userPrompts"].getInt()
    
    if stats.hasKey("lastApplied") and stats["lastApplied"].getStr() != "":
      try:
        self.stats.lastApplied = parse(stats["lastApplied"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        self.stats.lastApplied = now()

proc loadFromFile*(self: CookiePolicy, filepath: string) =
  ## ファイルからポリシー設定を読み込み
  if not fileExists(filepath):
    info "Cookie policy file not found, using defaults", filepath = filepath
    return
  
  try:
    let json = parseFile(filepath)
    self.fromJson(json)
    info "Loaded cookie policy from file", filepath = filepath
  except:
    error "Failed to load cookie policy from file", 
          filepath = filepath, error_msg = getCurrentExceptionMsg()

proc saveToFile*(self: CookiePolicy, filepath: string) =
  ## ポリシー設定をファイルに保存
  try:
    let json = self.toJson()
    writeFile(filepath, $json)
    info "Saved cookie policy to file", filepath = filepath
  except:
    error "Failed to save cookie policy to file", 
          filepath = filepath, error_msg = getCurrentExceptionMsg()

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード - 実際のアプリケーションでは以下のコードは削除される
  
  proc testCookiePolicy() =
    let policy = newCookiePolicy()
    
    # ポリシーモード変更テスト
    policy.setMode(PolicyMode.pmStrict)
    echo "Policy mode: ", policy.settings.mode
    
    # アクションテスト
    let action1 = policy.shouldAcceptCookie("_ga", "google-analytics.com", "example.com")
    echo "Should accept Google Analytics: ", action1
    
    let action2 = policy.shouldAcceptCookie("PHPSESSID", "example.com", "example.com")
    echo "Should accept session cookie: ", action2
    
    # カスタムルール追加テスト
    let customRule = CookieRule(
      domainPattern: r"example\.com",
      namePattern: r"test_cookie",
      action: CookieAction.caAccept,
      category: CookieCategoryLevel.cclFunctional,
      sourceType: CookieSourceType.cstFirstParty,
      description: "テスト用カスタムルール",
      expirationMaxDays: some(30)
    )
    policy.addRule(customRule)
    
    # ホワイトリスト追加テスト
    policy.addToWhitelist("trusted-site.com")
    
    # JSON変換テスト
    let json = policy.toJson()
    echo "JSON config: ", json
    
    # ファイル保存テスト
    policy.saveToFile("cookie_policy_test.json")
    
    # 統計情報
    echo "Stats - Accepted: ", policy.stats.cookiesAccepted
    echo "Stats - Rejected: ", policy.stats.cookiesRejected
    echo "Stats - Prompts: ", policy.stats.userPrompts
  
  when isMainModule:
    testCookiePolicy() 