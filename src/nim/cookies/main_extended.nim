# main_extended.nim
## 拡張クッキー管理システム - メインエントリーポイント

import std/[
  uri,
  options,
  strutils,
  times,
  sequtils,
  sets,
  tables,
  json,
  os,
  logging
]

import ./cookie_types
import ./main
import ./store/cookie_store
import ./security/cookie_security
import ./security/secure_cookie_jar
import ./policy/cookie_policy
import ./policy/policy_loader
import ./extensions/cookie_extensions
import ./extensions/cookie_manager_ext

export cookie_types
export main
export cookie_store
export cookie_security
export secure_cookie_jar
export cookie_policy
export policy_loader
export cookie_extensions
export cookie_manager_ext

type
  BrowserCookieMode* = enum
    ## ブラウザクッキーモード
    bcmBasic,       # 基本機能のみ
    bcmStandard,    # 標準機能
    bcmPrivate,     # プライベート
    bcmStrict       # セキュリティ強化

  BrowserCookieManager* = ref object
    ## 統合クッキーマネージャー
    baseManager*: CookieManager            # 基本マネージャー
    extended*: ExtendedCookieManager      # 拡張マネージャー（ポリシー適用など）
    logger*: Logger                        # ロガー
    mode*: BrowserCookieMode               # 動作モード
    userDataDir*: string                   # ユーザーデータディレクトリ
    profileName*: string                   # プロファイル名

###################
# 初期化・設定
###################

proc newBrowserCookieManagerConfig*(
  mode: BrowserCookieMode = bcmStandard,
  userDataDir: string = "",
  profileName: string = "default"
): BrowserCookieConfig =
  ## ブラウザクッキーマネージャー用の設定を作成
  result = defaultBrowserCookieConfig()
  
  # ユーザーデータディレクトリ
  if userDataDir.len > 0:
    result.userDataDir = userDataDir
  
  # モード別の設定
  case mode
  of bcmBasic:
    result.mode = cmBasic
    result.encryptSensitive = false
    result.securityPolicy = csAllowInsecure
    result.thirdPartyPolicy = tpAllow
    result.partitioningPolicy = cpNone
  
  of bcmStandard:
    result.mode = cmSecure
    result.encryptSensitive = true
    result.securityPolicy = csPreferSecure
    result.thirdPartyPolicy = tpSmartBlock
    result.partitioningPolicy = cpThirdParty
  
  of bcmPrivate:
    result.mode = cmIncognito
    result.encryptSensitive = true
    result.securityPolicy = csRequireSecure
    result.thirdPartyPolicy = tpBlock
    result.partitioningPolicy = cpAlways
    result.persistSessionCookies = false
  
  of bcmStrict:
    result.mode = cmSecure
    result.encryptSensitive = true
    result.securityPolicy = csRequireSecure
    result.thirdPartyPolicy = tpBlock
    result.partitioningPolicy = cpAlways

proc newBrowserCookieManager*(
  mode: BrowserCookieMode = bcmStandard,
  userDataDir: string = "",
  profileName: string = "default"
): BrowserCookieManager =
  ## 新しいブラウザクッキーマネージャーを作成
  # 設定を作成
  let config = newBrowserCookieManagerConfig(mode, userDataDir, profileName)
  
  # 基本マネージャーを作成
  let baseManager = newCookieManager(config)
  
  # 完全なパスを作成
  var fullUserDataDir = if userDataDir.len > 0: userDataDir
                       else: getTempDir() / "browser_data"
  
  # ディレクトリ作成
  if not dirExists(fullUserDataDir):
    createDir(fullUserDataDir)
  
  # 厳格モードかどうか
  let strictMode = mode in [bcmStrict, bcmPrivate]
  
  # 拡張マネージャーを作成
  let extended = newExtendedCookieManager(
    baseManager = baseManager,
    userDataDir = fullUserDataDir,
    profileName = profileName,
    strictMode = strictMode
  )
  
  # 統合マネージャーを作成
  result = BrowserCookieManager(
    baseManager: baseManager,
    extended: extended,
    logger: newConsoleLogger(),
    mode: mode,
    userDataDir: fullUserDataDir,
    profileName: profileName
  )

###################
# クッキー操作
###################

proc setCookie*(manager: BrowserCookieManager, 
               name, value, domain, path: string,
               maxAge: Option[int] = none(int),
               secure: bool = true,
               httpOnly: bool = true,
               sameSite: CookieSameSite = ssLax,
               documentUrl: Uri = nil): bool =
  ## 高レベルAPI: 新しいクッキーをセット
  # クッキーオブジェクト作成
  var expirationTime: Option[Time] = none(Time)
  if maxAge.isSome:
    expirationTime = some(getTime() + initDuration(seconds = maxAge.get()))
  
  let cookie = newCookie(
    name = name,
    value = value,
    domain = domain,
    path = path,
    expirationTime = expirationTime,
    isSecure = secure,
    isHttpOnly = httpOnly,
    sameSite = sameSite,
    source = csManuallyAdded
  )
  
  # ポリシー適用
  if documentUrl != nil:
    return manager.extended.addCookieWithPolicy(cookie, documentUrl)
  else:
    return manager.baseManager.addCookie(cookie)

proc addCookieFromHeader*(manager: BrowserCookieManager, 
                          header: string, domain: string, 
                          documentUrl: Uri = nil,
                          secure: bool = false): bool =
  ## Set-Cookieヘッダーからクッキーを追加
  if documentUrl != nil:
    return manager.extended.addCookieFromHeaderWithPolicy(
      header, domain, documentUrl, true, secure)
  else:
    return manager.baseManager.addCookieFromHeader(header, domain, secure)

proc getCookies*(manager: BrowserCookieManager, 
                url: Uri, documentUrl: Option[Uri] = none(Uri)): seq[Cookie] =
  ## クッキーを取得
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.getCookiesWithPolicy(url, documentUrl)
  else:
    return manager.baseManager.getCookies(url, firstPartyUrl = documentUrl)

proc getCookieHeader*(manager: BrowserCookieManager, 
                     url: Uri, documentUrl: Option[Uri] = none(Uri)): string =
  ## Cookieヘッダーを取得
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.getCookieHeaderWithPolicy(url, documentUrl)
  else:
    return manager.baseManager.getCookieHeader(url, firstPartyUrl = documentUrl)

proc getCookie*(manager: BrowserCookieManager, 
               name: string, domain: string, path: string = "/"): Option[Cookie] =
  ## 特定のクッキーを取得
  return manager.baseManager.getCookie(name, domain, path)

proc deleteCookie*(manager: BrowserCookieManager, 
                  name: string, domain: string, path: string = "/"): bool =
  ## クッキーを削除
  return manager.baseManager.deleteCookie(name, domain, path)

proc clearAllCookies*(manager: BrowserCookieManager): int =
  ## すべてのクッキーをクリア
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.clearAllCookiesWithStats()
  else:
    return manager.baseManager.clearAllCookies()

proc clearDomainCookies*(manager: BrowserCookieManager, domain: string): int =
  ## ドメインのクッキーをクリア
  return manager.baseManager.clearDomainCookies(domain)

###################
# ポリシー・同意管理
###################

proc setConsentForDomain*(manager: BrowserCookieManager, 
                         domain: string, allowedGroups: seq[CookieGroup]): bool =
  ## ドメインの同意設定を更新
  return manager.extended.setConsentForDomain(domain, allowedGroups)

proc setDefaultConsent*(manager: BrowserCookieManager, 
                       allowedGroups: seq[CookieGroup]): bool =
  ## デフォルト同意設定を更新
  return manager.extended.setDefaultConsent(allowedGroups)

proc addPolicyRule*(manager: BrowserCookieManager, 
                   domain: string, rule: CookiePolicyRule): bool =
  ## ポリシールールを追加
  return manager.extended.addPolicyRule(domain, rule)

proc changeMode*(manager: BrowserCookieManager, newMode: BrowserCookieMode) =
  ## 動作モードを変更
  manager.mode = newMode
  
  # ポリシーを更新
  case newMode
  of bcmBasic:
    manager.extended.setProfilePolicy("permissive")
    manager.extended.enableStrictMode(false)
  of bcmStandard:
    manager.extended.setProfilePolicy("standard")
    manager.extended.enableStrictMode(false)
  of bcmPrivate:
    manager.extended.setProfilePolicy("incognito")
    manager.extended.enableStrictMode(true)
  of bcmStrict:
    manager.extended.setProfilePolicy("strict")
    manager.extended.enableStrictMode(true)

###################
# 統計・レポート
###################

proc getStats*(manager: BrowserCookieManager): JsonNode =
  ## 統計情報を取得
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.getExtendedStats()
  else:
    return manager.baseManager.getMetrics()

proc getPrivacyReport*(manager: BrowserCookieManager): JsonNode =
  ## プライバシーレポートを取得
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.getPrivacyReport()
  else:
    # 基本モードは詳細レポートを提供しない
    return %*{
      "report_time": $getTime(),
      "mode": "basic",
      "report_available": false,
      "message": "プライバシーレポートは拡張モードでのみ利用可能です"
    }

###################
# システム機能
###################

proc saveCookies*(manager: BrowserCookieManager): bool =
  ## クッキーを保存
  if manager.mode != bcmPrivate:  # プライベートモードでは保存しない
    return manager.baseManager.saveCookies()
  return true

proc cleanupExpiredCookies*(manager: BrowserCookieManager): int =
  ## 期限切れクッキーをクリーンアップ
  return manager.baseManager.cleanupExpiredCookies()

proc exportAllSettings*(manager: BrowserCookieManager): JsonNode =
  ## すべての設定をエクスポート
  var config = %*{
    "mode": $manager.mode,
    "profile_name": manager.profileName,
    "user_data_dir": manager.userDataDir,
    "timestamp": $getTime()
  }
  
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    config["policy"] = manager.extended.exportPolicy()
    
    # 同意設定
    var consentObj = newJObject()
    for domain, groups in manager.extended.consentManager.consents:
      var groupsArray = newJArray()
      for group in groups:
        groupsArray.add(%($group))
      consentObj[domain] = groupsArray
    
    config["consent"] = consentObj
    
    # トラッカー設定
    config["trackers"] = %manager.extended.trackerDetector.getTrackersList()
  
  return config

proc updateSecurity*(manager: BrowserCookieManager, securityPolicy: CookieSecurePolicy) =
  ## セキュリティポリシーを更新
  manager.baseManager.setSecurityPolicy(securityPolicy)

proc updateThirdParty*(manager: BrowserCookieManager, thirdPartyPolicy: CookieThirdPartyPolicy) =
  ## サードパーティポリシーを更新
  manager.baseManager.setThirdPartyPolicy(thirdPartyPolicy)

proc cleanupExpiredSettings*(manager: BrowserCookieManager): int =
  ## 期限切れ設定をクリーンアップ
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    return manager.extended.clearExpiredPolicyRules()
  return 0

proc addTracker*(manager: BrowserCookieManager, domain: string) =
  ## トラッカーを追加
  if manager.mode in [bcmStandard, bcmStrict, bcmPrivate]:
    manager.extended.addTracker(domain)
    discard manager.extended.saveTrackerList() 