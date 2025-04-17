# cookie_compliance.nim
## クッキーコンプライアンスモジュール - 法的規制への対応機能

import std/[
  tables,
  options,
  sets,
  sugar,
  strutils,
  algorithm,
  json,
  os,
  times,
  sequtils,
  hashes,
  strformat
]
import ../cookie_types
import ./cookie_extensions

type
  ComplianceRegion* = enum
    ## サポートする法的規制地域
    crEU,            # 欧州連合 (GDPR)
    crUS_California, # カリフォルニア州 (CCPA/CPRA)
    crUS_Colorado,   # コロラド州
    crUS_Virginia,   # バージニア州
    crCanada,        # カナダ
    crUK,            # イギリス
    crAustralia,     # オーストラリア
    crJapan,         # 日本
    crSouthKorea,    # 韓国
    crBrazil,        # ブラジル
    crGlobal         # グローバル（最も厳しい規制）

  ConsentRequirement* = enum
    ## 同意要件の種類
    crOptIn,         # 明示的な同意が必要（オプトイン）
    crOptOut,        # オプトアウトの選択が必要
    crNotRequired,   # 同意不要
    crImplied        # 暗黙的な同意が可能

  ComplianceOption* = enum
    ## コンプライアンスオプション
    coRequireConsent,        # 同意を必須にする
    coAllowRevokeConsent,    # 同意の取り消しを許可
    coShowFirstPartyOnly,    # ファーストパーティクッキーのみ表示
    coRequireAgeVerification, # 年齢確認を必須にする
    coStoreConsentReceipt,   # 同意の記録を保存
    coEnableDoNotTrack,      # DoNotTrack対応を有効化
    coAllowDataPortability,  # データポータビリティを許可
    coEnableCookieWall       # クッキーウォールを有効化

  CookieExpiry* = object
    ## クッキーの有効期限ポリシー
    personalData*: int        # 個人データを含むクッキーの最大有効期間（日）
    analytics*: int           # 分析用クッキーの最大有効期間（日）
    marketing*: int           # マーケティング用クッキーの最大有効期間（日）
    necessary*: int           # 必須クッキーの最大有効期間（日）
    preference*: int          # 設定クッキーの最大有効期間（日）

  ComplianceConfig* = object
    ## コンプライアンス設定
    enforcedRegions*: HashSet[ComplianceRegion]   # 適用する地域
    options*: HashSet[ComplianceOption]           # 有効なオプション
    cookieExpiry*: CookieExpiry                   # クッキー有効期限ポリシー
    consentFrequency*: int                        # 同意確認頻度（日数）
    thirdPartyConsent*: ConsentRequirement        # サードパーティの同意要件
    requiredGroups*: HashSet[CookieGroup]         # 必須グループ
    minConsentAge*: int                           # 同意に必要な最小年齢
    recordLifetime*: int                          # 同意記録の保存期間（日）

  ConsentReceipt* = object
    ## 同意記録
    userId*: string                   # ユーザーID（匿名）
    timestamp*: Time                  # 同意タイムスタンプ
    groups*: HashSet[CookieGroup]     # 同意したグループ
    region*: ComplianceRegion         # 適用地域
    version*: string                  # 同意バージョン
    expiresAt*: Time                  # 同意有効期限
    userAgent*: string                # ユーザーエージェント
    ipHash*: string                   # IPアドレスのハッシュ（匿名化）
    method*: string                   # 同意取得方法

  ComplianceManager* = ref object
    ## コンプライアンス管理
    config*: ComplianceConfig                # 設定
    consentReceipts*: Table[string, seq[ConsentReceipt]]  # 同意記録
    persistPath*: string                     # 永続化パス
    autoSave*: bool                          # 自動保存フラグ
    regionMappings*: Table[string, ComplianceRegion]  # 国コードと地域のマッピング

# デフォルト設定
const DEFAULT_COMPLIANCE_CONFIG = ComplianceConfig(
  enforcedRegions: toHashSet([crEU, crGlobal]),
  options: toHashSet([coRequireConsent, coAllowRevokeConsent, coStoreConsentReceipt]),
  cookieExpiry: CookieExpiry(
    personalData: 365,    # 1年
    analytics: 30,        # 1ヶ月
    marketing: 180,       # 6ヶ月
    necessary: 730,       # 2年
    preference: 365       # 1年
  ),
  consentFrequency: 180,  # 6ヶ月
  thirdPartyConsent: crOptIn,
  requiredGroups: toHashSet([cgNecessary, cgSecurity]),
  minConsentAge: 16,      # EUのデフォルト
  recordLifetime: 730     # 2年
)

# 国コードと地域のマッピング
proc createRegionMappings(): Table[string, ComplianceRegion] =
  result = {
    # 欧州連合 (GDPR)
    "AT": crEU, "BE": crEU, "BG": crEU, "HR": crEU, "CY": crEU,
    "CZ": crEU, "DK": crEU, "EE": crEU, "FI": crEU, "FR": crEU,
    "DE": crEU, "GR": crEU, "HU": crEU, "IE": crEU, "IT": crEU,
    "LV": crEU, "LT": crEU, "LU": crEU, "MT": crEU, "NL": crEU,
    "PL": crEU, "PT": crEU, "RO": crEU, "SK": crEU, "SI": crEU,
    "ES": crEU, "SE": crEU,
    # イギリス
    "GB": crUK,
    # 米国（州別）
    "US-CA": crUS_California,
    "US-CO": crUS_Colorado,
    "US-VA": crUS_Virginia,
    # その他の国
    "CA": crCanada,
    "AU": crAustralia,
    "JP": crJapan,
    "KR": crSouthKorea,
    "BR": crBrazil
  }.toTable

###################
# 初期化・設定
###################

proc newComplianceManager*(persistPath: string = "", autoSave: bool = true): ComplianceManager =
  ## 新しいコンプライアンス管理を作成
  result = ComplianceManager(
    config: DEFAULT_COMPLIANCE_CONFIG,
    consentReceipts: initTable[string, seq[ConsentReceipt]](),
    persistPath: persistPath,
    autoSave: autoSave,
    regionMappings: createRegionMappings()
  )
  
  # 保存ファイルがあれば読み込み
  if persistPath.len > 0 and fileExists(persistPath):
    try:
      discard result.loadFromFile()
    except:
      # 読み込みエラーは無視
      discard

proc setRegion*(manager: ComplianceManager, regions: HashSet[ComplianceRegion]): bool =
  ## 適用地域を設定
  manager.config.enforcedRegions = regions
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

proc addRegion*(manager: ComplianceManager, region: ComplianceRegion): bool =
  ## 地域を追加
  manager.config.enforcedRegions.incl(region)
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

proc removeRegion*(manager: ComplianceManager, region: ComplianceRegion): bool =
  ## 地域を削除
  if region in manager.config.enforcedRegions:
    manager.config.enforcedRegions.excl(region)
    
    if manager.autoSave and manager.persistPath.len > 0:
      return manager.saveToFile()
    return true
  
  return false

proc setOption*(manager: ComplianceManager, option: ComplianceOption, enabled: bool): bool =
  ## オプションを設定
  if enabled:
    manager.config.options.incl(option)
  else:
    manager.config.options.excl(option)
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

proc isOptionEnabled*(manager: ComplianceManager, option: ComplianceOption): bool =
  ## オプションが有効かどうか
  return option in manager.config.options

proc setCookieExpiry*(manager: ComplianceManager, expiryPolicy: CookieExpiry): bool =
  ## クッキー有効期限ポリシーを設定
  manager.config.cookieExpiry = expiryPolicy
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

proc setMinConsentAge*(manager: ComplianceManager, age: int): bool =
  ## 最小同意年齢を設定
  manager.config.minConsentAge = max(13, age)  # 13歳未満はCOPPAなど別の規制対象
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

###################
# 同意管理
###################

proc storeConsentReceipt*(manager: ComplianceManager, 
                        userId: string,
                        groups: HashSet[CookieGroup],
                        region: ComplianceRegion,
                        userAgent: string = "",
                        ipHash: string = "",
                        method: string = "explicit"): bool =
  ## 同意記録を保存
  if not manager.isOptionEnabled(coStoreConsentReceipt):
    return true
  
  let now = getTime()
  let expiryDays = manager.config.consentFrequency
  let receipt = ConsentReceipt(
    userId: userId,
    timestamp: now,
    groups: groups,
    region: region,
    version: "1.0",
    expiresAt: now + initDuration(days = expiryDays),
    userAgent: userAgent,
    ipHash: ipHash,
    method: method
  )
  
  if not manager.consentReceipts.hasKey(userId):
    manager.consentReceipts[userId] = @[]
  
  manager.consentReceipts[userId].add(receipt)
  
  # 古い記録を削除
  let maxAge = initDuration(days = manager.config.recordLifetime)
  manager.consentReceipts[userId] = manager.consentReceipts[userId].filterIt(
    now - it.timestamp < maxAge
  )
  
  if manager.autoSave and manager.persistPath.len > 0:
    return manager.saveToFile()
  return true

proc getLatestConsent*(manager: ComplianceManager, userId: string): Option[ConsentReceipt] =
  ## 最新の同意記録を取得
  if not manager.consentReceipts.hasKey(userId):
    return none(ConsentReceipt)
  
  let receipts = manager.consentReceipts[userId]
  if receipts.len == 0:
    return none(ConsentReceipt)
  
  # タイムスタンプで並べ替えて最新のものを返す
  let sortedReceipts = receipts.sorted(
    proc(a, b: ConsentReceipt): int = cmp(b.timestamp, a.timestamp)
  )
  
  return some(sortedReceipts[0])

proc isConsentValid*(manager: ComplianceManager, userId: string): bool =
  ## 同意が有効かどうか
  let consentOpt = manager.getLatestConsent(userId)
  if consentOpt.isNone:
    return false
  
  let consent = consentOpt.get()
  let now = getTime()
  
  # 有効期限チェック
  return now < consent.expiresAt

proc consentRenewalNeeded*(manager: ComplianceManager, userId: string): bool =
  ## 同意の更新が必要かどうか
  # 同意がない場合は更新が必要
  let consentOpt = manager.getLatestConsent(userId)
  if consentOpt.isNone:
    return true
  
  let consent = consentOpt.get()
  let now = getTime()
  
  # 有効期限が切れている場合は更新が必要
  if now >= consent.expiresAt:
    return true
  
  # 残り期間が1週間未満の場合も更新が推奨
  let warningPeriod = initDuration(days = 7)
  if consent.expiresAt - now < warningPeriod:
    return true
  
  return false

proc getConsentRequirementForGroup*(manager: ComplianceManager, 
                                  group: CookieGroup, 
                                  isThirdParty: bool): ConsentRequirement =
  ## グループと文脈に基づく同意要件を取得
  # 必須グループは同意不要
  if group in manager.config.requiredGroups:
    return crNotRequired
  
  # サードパーティのコンテキスト
  if isThirdParty:
    return manager.config.thirdPartyConsent
  
  # グループごとに同意要件を決定
  case group
  of cgNecessary, cgSecurity:
    # 必須グループ（すでに上でフィルターされているはずだが念のため）
    return crNotRequired
  of cgFunctional, cgPreferences:
    # 機能性と設定は地域による
    if crEU in manager.config.enforcedRegions or 
       crGlobal in manager.config.enforcedRegions:
      return crOptIn
    else:
      return crImplied
  of cgAnalytics, cgAdvertising, cgSocial:
    # 分析、広告、ソーシャルは常にオプトイン
    return crOptIn
  else:
    # その他はオプトイン（安全策）
    return crOptIn

proc getMaxExpiryForGroup*(manager: ComplianceManager, group: CookieGroup): int =
  ## グループに基づく最大有効期限を取得（日数）
  case group
  of cgNecessary, cgSecurity:
    return manager.config.cookieExpiry.necessary
  of cgPreferences:
    return manager.config.cookieExpiry.preference
  of cgAnalytics:
    return manager.config.cookieExpiry.analytics
  of cgAdvertising, cgSocial:
    return manager.config.cookieExpiry.marketing
  of cgSession:
    return 0  # セッションクッキー
  else:
    # その他は個人データとして扱う
    return manager.config.cookieExpiry.personalData

proc getRegionFromCountryCode*(manager: ComplianceManager, countryCode: string): ComplianceRegion =
  ## 国コードから地域を取得
  let code = countryCode.toUpperAscii()
  
  # 米国の州対応
  if code.startsWith("US-"):
    if manager.regionMappings.hasKey(code):
      return manager.regionMappings[code]
    else:
      # 州が特定できない場合はカリフォルニア州のルールを適用（最も厳しい）
      return crUS_California
  
  # その他の国
  if manager.regionMappings.hasKey(code):
    return manager.regionMappings[code]
  
  # 不明な国の場合はグローバル設定
  return crGlobal

###################
# クッキー処理
###################

proc shouldRequireConsent*(manager: ComplianceManager, 
                         cookie: Cookie, 
                         group: CookieGroup, 
                         isThirdParty: bool): bool =
  ## 同意が必要かどうか判断
  # コンプライアンス設定で同意が必要ない場合
  if not manager.isOptionEnabled(coRequireConsent):
    return false
  
  # 同意要件を取得
  let requirement = manager.getConsentRequirementForGroup(group, isThirdParty)
  
  case requirement
  of crOptIn:
    return true
  of crOptOut, crImplied:
    return false
  of crNotRequired:
    return false

proc applyComplianceRules*(manager: ComplianceManager, 
                          cookie: var Cookie, 
                          group: CookieGroup, 
                          isThirdParty: bool): bool =
  ## コンプライアンスルールをクッキーに適用
  # 有効期限の制限
  if cookie.expirationTime.isSome:
    let maxDays = manager.getMaxExpiryForGroup(group)
    if maxDays > 0:  # セッションクッキーでない場合
      let maxExpiry = getTime() + initDuration(days = maxDays)
      if cookie.expirationTime.get() > maxExpiry:
        cookie.expirationTime = some(maxExpiry)
        result = true  # 変更あり
  
  # サードパーティの制限
  if isThirdParty and manager.config.thirdPartyConsent == crOptIn:
    if not cookie.isSecure:
      cookie.isSecure = true
      result = true
    
    if cookie.sameSite == ssNone:
      cookie.sameSite = ssLax
      result = true
  
  # セキュリティ設定
  if group in [cgAnalytics, cgAdvertising, cgSocial]:
    if not cookie.isSecure:
      cookie.isSecure = true
      result = true
  
  return result

###################
# 永続化
###################

proc saveToFile*(manager: ComplianceManager): bool =
  ## 設定をファイルに保存
  if manager.persistPath.len == 0:
    return false
  
  try:
    # 設定をJSONに変換
    var configObj = %*{
      "regions": toSeq(manager.config.enforcedRegions).mapIt($it),
      "options": toSeq(manager.config.options).mapIt($it),
      "expiry": {
        "personal_data": manager.config.cookieExpiry.personalData,
        "analytics": manager.config.cookieExpiry.analytics,
        "marketing": manager.config.cookieExpiry.marketing,
        "necessary": manager.config.cookieExpiry.necessary,
        "preference": manager.config.cookieExpiry.preference
      },
      "consent_frequency": manager.config.consentFrequency,
      "third_party_consent": $manager.config.thirdPartyConsent,
      "required_groups": toSeq(manager.config.requiredGroups).mapIt($it),
      "min_consent_age": manager.config.minConsentAge,
      "record_lifetime": manager.config.recordLifetime
    }
    
    # 同意記録をJSONに変換
    var receiptsObj = newJObject()
    for userId, receipts in manager.consentReceipts:
      var userReceipts = newJArray()
      for receipt in receipts:
        userReceipts.add(%*{
          "timestamp": receipt.timestamp.toUnix(),
          "groups": toSeq(receipt.groups).mapIt($it),
          "region": $receipt.region,
          "version": receipt.version,
          "expires_at": receipt.expiresAt.toUnix(),
          "user_agent": receipt.userAgent,
          "ip_hash": receipt.ipHash,
          "method": receipt.method
        })
      receiptsObj[userId] = userReceipts
    
    # 最終的なJSONを構築
    let jsonData = %*{
      "config": configObj,
      "receipts": receiptsObj
    }
    
    writeFile(manager.persistPath, $jsonData)
    return true
  except:
    return false

proc loadFromFile*(manager: ComplianceManager): bool =
  ## 設定をファイルから読み込み
  if manager.persistPath.len == 0 or not fileExists(manager.persistPath):
    return false
  
  try:
    let jsonContent = parseJson(readFile(manager.persistPath))
    
    # 設定の読み込み
    if jsonContent.hasKey("config"):
      let config = jsonContent["config"]
      
      # 地域
      if config.hasKey("regions"):
        manager.config.enforcedRegions.clear()
        for regionStr in config["regions"]:
          for region in ComplianceRegion:
            if $region == regionStr.getStr():
              manager.config.enforcedRegions.incl(region)
      
      # オプション
      if config.hasKey("options"):
        manager.config.options.clear()
        for optionStr in config["options"]:
          for option in ComplianceOption:
            if $option == optionStr.getStr():
              manager.config.options.incl(option)
      
      # 有効期限ポリシー
      if config.hasKey("expiry"):
        let expiry = config["expiry"]
        if expiry.hasKey("personal_data"):
          manager.config.cookieExpiry.personalData = expiry["personal_data"].getInt()
        if expiry.hasKey("analytics"):
          manager.config.cookieExpiry.analytics = expiry["analytics"].getInt()
        if expiry.hasKey("marketing"):
          manager.config.cookieExpiry.marketing = expiry["marketing"].getInt()
        if expiry.hasKey("necessary"):
          manager.config.cookieExpiry.necessary = expiry["necessary"].getInt()
        if expiry.hasKey("preference"):
          manager.config.cookieExpiry.preference = expiry["preference"].getInt()
      
      # その他の設定
      if config.hasKey("consent_frequency"):
        manager.config.consentFrequency = config["consent_frequency"].getInt()
      
      if config.hasKey("third_party_consent"):
        let consentStr = config["third_party_consent"].getStr()
        for requirement in ConsentRequirement:
          if $requirement == consentStr:
            manager.config.thirdPartyConsent = requirement
      
      if config.hasKey("required_groups"):
        manager.config.requiredGroups.clear()
        for groupStr in config["required_groups"]:
          for group in CookieGroup:
            if $group == groupStr.getStr():
              manager.config.requiredGroups.incl(group)
      
      if config.hasKey("min_consent_age"):
        manager.config.minConsentAge = config["min_consent_age"].getInt()
      
      if config.hasKey("record_lifetime"):
        manager.config.recordLifetime = config["record_lifetime"].getInt()
    
    # 同意記録の読み込み
    if jsonContent.hasKey("receipts"):
      manager.consentReceipts.clear()
      let receipts = jsonContent["receipts"]
      
      for userId, userReceipts in receipts:
        var receiptsList: seq[ConsentReceipt] = @[]
        
        for receiptJson in userReceipts:
          var receipt: ConsentReceipt
          receipt.userId = userId
          
          # タイムスタンプと有効期限
          if receiptJson.hasKey("timestamp"):
            receipt.timestamp = fromUnix(receiptJson["timestamp"].getBiggestInt())
          
          if receiptJson.hasKey("expires_at"):
            receipt.expiresAt = fromUnix(receiptJson["expires_at"].getBiggestInt())
          
          # グループ
          if receiptJson.hasKey("groups"):
            for groupStr in receiptJson["groups"]:
              for group in CookieGroup:
                if $group == groupStr.getStr():
                  receipt.groups.incl(group)
          
          # その他のフィールド
          if receiptJson.hasKey("region"):
            let regionStr = receiptJson["region"].getStr()
            for region in ComplianceRegion:
              if $region == regionStr:
                receipt.region = region
          
          if receiptJson.hasKey("version"):
            receipt.version = receiptJson["version"].getStr()
          
          if receiptJson.hasKey("user_agent"):
            receipt.userAgent = receiptJson["user_agent"].getStr()
          
          if receiptJson.hasKey("ip_hash"):
            receipt.ipHash = receiptJson["ip_hash"].getStr()
          
          if receiptJson.hasKey("method"):
            receipt.method = receiptJson["method"].getStr()
          
          receiptsList.add(receipt)
        
        if receiptsList.len > 0:
          manager.consentReceipts[userId] = receiptsList
    
    return true
  except:
    return false

###################
# レポート・集計
###################

proc getComplianceReport*(manager: ComplianceManager): JsonNode =
  ## コンプライアンスレポートを生成
  var regionsArray = newJArray()
  for region in manager.config.enforcedRegions:
    regionsArray.add(%($region))
  
  var optionsArray = newJArray()
  for option in manager.config.options:
    optionsArray.add(%($option))
  
  var requiredGroupsArray = newJArray()
  for group in manager.config.requiredGroups:
    requiredGroupsArray.add(%($group))
  
  # 同意記録の統計
  var totalReceipts = 0
  var validReceipts = 0
  var expiredReceipts = 0
  let now = getTime()
  
  for _, receipts in manager.consentReceipts:
    totalReceipts += receipts.len
    for receipt in receipts:
      if now < receipt.expiresAt:
        validReceipts += 1
      else:
        expiredReceipts += 1
  
  return %*{
    "regions": regionsArray,
    "options": optionsArray,
    "required_groups": requiredGroupsArray,
    "min_consent_age": manager.config.minConsentAge,
    "third_party_consent": $manager.config.thirdPartyConsent,
    "consent_stats": {
      "total": totalReceipts,
      "valid": validReceipts,
      "expired": expiredReceipts
    },
    "expiry_policy": {
      "personal_data": manager.config.cookieExpiry.personalData,
      "analytics": manager.config.cookieExpiry.analytics,
      "marketing": manager.config.cookieExpiry.marketing,
      "necessary": manager.config.cookieExpiry.necessary,
      "preference": manager.config.cookieExpiry.preference
    }
  }

proc isCompliantFor*(manager: ComplianceManager, region: ComplianceRegion): bool =
  ## 特定地域のコンプライアンスチェック
  # 地域が適用対象に含まれているか
  if region notin manager.config.enforcedRegions and 
     crGlobal notin manager.config.enforcedRegions:
    return false
  
  # 地域ごとの特殊要件をチェック
  case region
  of crEU, crUK:
    # 明示的な同意が必要
    if coRequireConsent notin manager.config.options:
      return false
    if coAllowRevokeConsent notin manager.config.options:
      return false
    # 同意記録も必要
    if coStoreConsentReceipt notin manager.config.options:
      return false
  
  of crUS_California, crUS_Colorado, crUS_Virginia:
    # オプトアウトが必要
    if coAllowRevokeConsent notin manager.config.options:
      return false
  
  of crCanada:
    # 明示的な同意が必要
    if coRequireConsent notin manager.config.options:
      return false
  
  else:
    # その他の地域は特別な要件なし
    discard
  
  return true

proc generateConsentReceiptForUser*(manager: ComplianceManager, userId: string): string =
  ## ユーザーの同意記録を生成（可読形式）
  let consentOpt = manager.getLatestConsent(userId)
  if consentOpt.isNone:
    return "同意記録がありません。"
  
  let consent = consentOpt.get()
  let groups = toSeq(consent.groups).mapIt($it).join(", ")
  
  return &"""同意記録:
ユーザーID: {userId}
同意日時: {consent.timestamp.format("yyyy-MM-dd HH:mm:ss")}
有効期限: {consent.expiresAt.format("yyyy-MM-dd HH:mm:ss")}
同意したグループ: {groups}
適用地域: {$consent.region}
バージョン: {consent.version}
記録方法: {consent.method}
""" 