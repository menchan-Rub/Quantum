# セキュリティマネージャーモジュール
#
# このモジュールは、ブラウザの全体的なセキュリティ設定と機能を管理します。
# 証明書、TLS、CSP、混合コンテンツなどのセキュリティ関連機能を統合します。

import std/[options, tables, sets, strutils, json, uri, times]
import ../logging
import certificates/certificate_store
import certificates/cert_transparency
import tls/tls_config
import csp/content_security_policy
import mixed_content/mixed_content_detector
import hsts/hsts_manager
import dns/secure_dns

type
  SecurityLevel* = enum
    slLow = "low"         # 低セキュリティレベル（互換性優先）
    slMedium = "medium"   # 中セキュリティレベル（バランス）
    slHigh = "high"       # 高セキュリティレベル（セキュリティ優先）
    slVeryHigh = "very_high" # 非常に高いセキュリティレベル（最大セキュリティ）
    slCustom = "custom"   # カスタムセキュリティレベル

  SecurityFeature* = enum
    sfStrictTLS           # 厳格なTLS設定
    sfBlockMixedContent   # 混合コンテンツをブロック
    sfHSTS                # HTTP Strict Transport Security
    sfDNSSEC              # DNSSECを使用
    sfSRI                 # Subresource Integrity
    sfExpectCT            # Certificate Transparency
    sfCertificateVerification # 証明書の検証
    sfSecureDNS           # セキュアDNS (DoH/DoT)

  SecurityManager* = ref object
    certificateStore*: CertificateStore
    tlsConfig*: TlsConfig
    mixedContentDetector*: MixedContentDetector
    cspPolicy*: Option[ContentSecurityPolicy]
    securityLevel*: SecurityLevel
    enabledFeatures*: set[SecurityFeature]
    hstsManager*: HstsManager    # HSTSマネージャー
    certTransparency*: CertificateTransparency  # 証明書透明性マネージャー
    secureDnsManager*: SecureDnsManager   # セキュアDNSマネージャー
    customSettings*: Table[string, string]  # カスタム設定

# 新しいセキュリティマネージャーを作成
proc newSecurityManager*(
  securityLevel: SecurityLevel = slMedium,
  certificateStore: CertificateStore = nil
): SecurityManager =
  var certStore = certificateStore
  if certStore == nil:
    certStore = loadSystemStore()

  var tlsConfig: TlsConfig
  var mixedContentPolicy: MixedContentPolicy
  var enabledFeatures: set[SecurityFeature]
  
  # セキュリティレベルに基づいて設定
  case securityLevel:
    of slLow:
      tlsConfig = newLegacyTlsConfig()
      mixedContentPolicy = mcpAllowAll
      enabledFeatures = {sfCertificateVerification}
    
    of slMedium:
      tlsConfig = newCompatibleTlsConfig()
      mixedContentPolicy = mcpBlockActive
      enabledFeatures = {sfCertificateVerification, sfBlockMixedContent}
    
    of slHigh:
      tlsConfig = newModernTlsConfig()
      mixedContentPolicy = mcpBlock
      enabledFeatures = {sfCertificateVerification, sfBlockMixedContent, sfStrictTLS, sfSRI, sfHSTS}
    
    of slVeryHigh:
      tlsConfig = newModernTlsConfig()
      mixedContentPolicy = mcpBlock
      enabledFeatures = {sfCertificateVerification, sfBlockMixedContent, sfStrictTLS, sfHSTS, sfDNSSEC, sfSRI, sfExpectCT, sfSecureDNS}
    
    of slCustom:
      tlsConfig = newCompatibleTlsConfig()
      mixedContentPolicy = mcpBlockActive
      enabledFeatures = {sfCertificateVerification, sfBlockMixedContent}
  
  # 証明書ストアをTLS設定に設定
  tlsConfig.setCertificateStore(certStore)
  
  # 各コンポーネントの初期化
  let hstsConfig = newHstsConfig()
  let hstsManager = newHstsManager(hstsConfig)
  
  # 証明書透明性マネージャーを初期化
  var ctManager = newCertificateTransparency(certStore)
  
  # セキュアDNSマネージャーを初期化
  let secureDnsConfig = newSecureDnsConfig()
  let secureDnsManager = newSecureDnsManager(secureDnsConfig)
  
  result = SecurityManager(
    certificateStore: certStore,
    tlsConfig: tlsConfig,
    mixedContentDetector: newMixedContentDetector(mixedContentPolicy),
    cspPolicy: none(ContentSecurityPolicy),
    securityLevel: securityLevel,
    enabledFeatures: enabledFeatures,
    hstsManager: hstsManager,
    certTransparency: ctManager,
    secureDnsManager: secureDnsManager,
    customSettings: initTable[string, string]()
  )
  
  # 各コンポーネントの初期化を実行
  hstsManager.init()
  ctManager.init()

# セキュリティレベルを変更
proc setSecurityLevel*(manager: SecurityManager, level: SecurityLevel) =
  if manager.securityLevel == level:
    return
  
  manager.securityLevel = level
  
  # レベルに基づいて設定を更新
  case level:
    of slLow:
      manager.tlsConfig = newLegacyTlsConfig()
      manager.tlsConfig.setCertificateStore(manager.certificateStore)
      manager.mixedContentDetector.setPolicy(mcpAllowAll)
      manager.enabledFeatures = {sfCertificateVerification}
      
      # HSTS無効化
      manager.hstsManager.setState(hstsDisabled)
      
      # 証明書透明性を無効化
      manager.certTransparency.setVerificationPolicy(ctRequirementNone)
      
      # セキュアDNS無効化
      manager.secureDnsManager.setMode(sdmOff)
    
    of slMedium:
      manager.tlsConfig = newCompatibleTlsConfig()
      manager.tlsConfig.setCertificateStore(manager.certificateStore)
      manager.mixedContentDetector.setPolicy(mcpBlockActive)
      manager.enabledFeatures = {sfCertificateVerification, sfBlockMixedContent}
      
      # HSTS有効化
      manager.hstsManager.setState(hstsEnabled)
      
      # 証明書透明性を最小限に
      manager.certTransparency.setVerificationPolicy(ctRequirementBestEffort)
      
      # セキュアDNS自動モード
      manager.secureDnsManager.setMode(sdmAutomatic)
    
    of slHigh:
      manager.tlsConfig = newModernTlsConfig()
      manager.tlsConfig.setCertificateStore(manager.certificateStore)
      manager.mixedContentDetector.setPolicy(mcpBlock)
      manager.enabledFeatures = {sfCertificateVerification, sfBlockMixedContent, sfStrictTLS, sfSRI, sfHSTS}
      
      # HSTS有効化
      manager.hstsManager.setState(hstsEnabled)
      
      # 証明書透明性を有効化
      manager.certTransparency.setVerificationPolicy(ctRequirementBestEffort)
      
      # セキュアDNS自動モード
      manager.secureDnsManager.setMode(sdmAutomatic)
    
    of slVeryHigh:
      manager.tlsConfig = newModernTlsConfig()
      manager.tlsConfig.setCertificateStore(manager.certificateStore)
      manager.mixedContentDetector.setPolicy(mcpBlock)
      manager.enabledFeatures = {sfCertificateVerification, sfBlockMixedContent, sfStrictTLS, sfHSTS, sfDNSSEC, sfSRI, sfExpectCT, sfSecureDNS}
      
      # HSTS有効化（厳格モード）
      manager.hstsManager.setState(hstsEnabled)
      
      # 証明書透明性を強制
      manager.certTransparency.setVerificationPolicy(ctRequirementEnforced)
      
      # セキュアDNS強制モード
      manager.secureDnsManager.setMode(sdmSecure)
    
    of slCustom:
      # カスタムモードでは設定を変更しない
      discard
  
  log(lvlInfo, "セキュリティレベルを変更しました: " & $level)

# セキュリティ機能の有効/無効を切り替え
proc setFeatureEnabled*(manager: SecurityManager, feature: SecurityFeature, enabled: bool) =
  if enabled:
    manager.enabledFeatures.incl(feature)
    log(lvlInfo, "セキュリティ機能を有効にしました: " & $feature)
  else:
    manager.enabledFeatures.excl(feature)
    log(lvlInfo, "セキュリティ機能を無効にしました: " & $feature)
  
  # 機能に基づいて関連設定を更新
  case feature:
    of sfStrictTLS:
      if enabled:
        # 厳格なTLS設定
        manager.tlsConfig.minVersion = tlsTLS12
        manager.tlsConfig.insecureFallback = false
      else:
        # 互換性のあるTLS設定
        manager.tlsConfig.minVersion = tlsTLS11
        manager.tlsConfig.insecureFallback = true
    
    of sfBlockMixedContent:
      if enabled:
        manager.mixedContentDetector.setPolicy(mcpBlock)
      else:
        manager.mixedContentDetector.setPolicy(mcpAllowAll)
    
    of sfHSTS:
      if enabled:
        manager.hstsManager.setState(hstsEnabled)
      else:
        manager.hstsManager.setState(hstsDisabled)
    
    of sfExpectCT:
      if enabled:
        manager.certTransparency.setVerificationPolicy(ctRequirementEnforced)
      else:
        manager.certTransparency.setVerificationPolicy(ctRequirementNone)
    
    of sfSecureDNS:
      if enabled:
        manager.secureDnsManager.setMode(sdmSecure)
      else:
        manager.secureDnsManager.setMode(sdmOff)
    
    else:
      # その他の機能は単に有効/無効フラグのみを設定
      discard
  
  # カスタムセキュリティレベルに切り替え
  if manager.securityLevel != slCustom:
    manager.securityLevel = slCustom

# HSTSホストを追加
proc addHstsHost*(manager: SecurityManager, host: string, includeSubdomains: bool = false, maxAge: int = -1) =
  let hostname = host.toLowerAscii()
  manager.hstsManager.addHstsHost(hostname, maxAge, includeSubdomains, hstsUserDefined)
  
  log(lvlInfo, "HSTSホストを追加しました: " & host)

# HSTSホストをチェック
proc isHstsHost*(manager: SecurityManager, host: string, port: int = 443): bool =
  return manager.hstsManager.isHstsHost(host.toLowerAscii(), port)

# HSTSヘッダーを処理
proc processHstsHeader*(manager: SecurityManager, host: string, headerValue: string) =
  # HSTSが無効の場合は処理しない
  if sfHSTS notin manager.enabledFeatures:
    return
  
  manager.hstsManager.processHstsHeader(host.toLowerAscii(), headerValue)

# 証明書の透明性が必要なホストを追加
proc addCertTransparencyHost*(manager: SecurityManager, host: string) =
  manager.certTransparency.addEnforcedDomain(host.toLowerAscii())
  log(lvlInfo, "証明書の透明性が必要なホストを追加しました: " & host)

# 証明書の透明性が必要かチェック
proc requiresCertificateTransparency*(manager: SecurityManager, host: string): bool =
  # 証明書透明性機能が有効かチェック
  if sfExpectCT notin manager.enabledFeatures:
    return false
  
  return manager.certTransparency.isDomainEnforced(host.toLowerAscii())

# 証明書の透明性を検証
proc verifyCertificateTransparency*(
  manager: SecurityManager,
  host: string,
  certificate: string,
  tlsExtensionScts: seq[SignedCertificateTimestamp] = @[],
  ocspScts: seq[SignedCertificateTimestamp] = @[]
): bool =
  # 証明書透明性機能が無効の場合は常に検証成功と見なす
  if sfExpectCT notin manager.enabledFeatures:
    return true
  
  let result = manager.certTransparency.verifyCertificate(certificate, host, tlsExtensionScts, ocspScts)
  return result.isValid

# デフォルトのCSPポリシーを設定
proc setDefaultCspPolicy*(manager: SecurityManager, policy: ContentSecurityPolicy) =
  manager.cspPolicy = some(policy)
  log(lvlInfo, "デフォルトのCSPポリシーを設定しました")

# ホストに対するCSPポリシーを取得（カスタマイズ可能）
proc getCspPolicyForHost*(manager: SecurityManager, host: string): Option[ContentSecurityPolicy] =
  # 将来的に、ホストごとに異なるポリシーを実装する場合に拡張
  return manager.cspPolicy

# 混合コンテンツのリソースを処理
proc processMixedContentResource*(
  manager: SecurityManager,
  baseUrl: string,
  resourceUrl: string,
  resourceType: ResourceCategory
): tuple[allowResource: bool, modifiedUrl: string] =
  # 混合コンテンツ機能が有効かチェック
  if sfBlockMixedContent notin manager.enabledFeatures:
    return (true, resourceUrl)  # 機能が無効の場合はそのまま許可
  
  # 混合コンテンツ検出器で処理
  return manager.mixedContentDetector.checkAndHandleResource(
    baseUrl, resourceUrl, resourceType)

# URLに対するセキュリティ情報を取得
proc getSecurityInfoForUrl*(manager: SecurityManager, url: string): JsonNode =
  result = newJObject()
  
  let uri = parseUri(url)
  let host = uri.hostname.toLowerAscii()
  let isHttps = uri.scheme.toLowerAscii() == "https"
  
  result["url"] = %url
  result["isSecure"] = %isHttps
  
  if isHttps:
    result["hstsEnabled"] = %manager.isHstsHost(host)
    result["certTransparencyRequired"] = %manager.requiresCertificateTransparency(host)
    
    var features = newJArray()
    for feature in manager.enabledFeatures:
      features.add(%($feature))
    result["enabledFeatures"] = features
    
    result["tlsInfo"] = %{
      "minVersion": %($manager.tlsConfig.minVersion),
      "maxVersion": %($manager.tlsConfig.maxVersion)
    }
  
  return result

# HTTPSにアップグレードすべきURLかチェック
proc shouldUpgradeToHttps*(manager: SecurityManager, url: string): bool =
  # HSTS機能が有効かチェック
  if sfHSTS notin manager.enabledFeatures:
    return false
  
  return manager.hstsManager.isHstsUrl(url)

# HTTPSにアップグレード
proc upgradeToHttps*(manager: SecurityManager, url: string): string =
  # HSTS機能が有効かチェック
  if sfHSTS notin manager.enabledFeatures:
    return url
  
  return manager.hstsManager.upgradeUrlToHttps(url)

# セキュリティマネージャーの状態をJSONに変換
proc toJson*(manager: SecurityManager): JsonNode =
  result = newJObject()
  
  result["securityLevel"] = %($manager.securityLevel)
  
  var featuresArray = newJArray()
  for feature in manager.enabledFeatures:
    featuresArray.add(%($feature))
  result["enabledFeatures"] = featuresArray
  
  result["tlsConfig"] = manager.tlsConfig.toJson()
  
  # HSTSマネージャー情報
  result["hstsManager"] = %{
    "state": %($manager.hstsManager.config.state),
    "entryCount": %manager.hstsManager.entries.len
  }
  
  # 証明書透明性情報
  result["certTransparency"] = %{
    "enforcedDomains": %manager.certTransparency.getEnforcedDomainsCount(),
    "exemptedDomains": %manager.certTransparency.getExemptedDomainsCount()
  }
  
  # セキュアDNS情報
  result["secureDns"] = %{
    "mode": %($manager.secureDnsManager.config.mode),
    "provider": %manager.secureDnsManager.config.providers[manager.secureDnsManager.config.selectedProvider].name
  }
  
  var customSettingsObj = newJObject()
  for key, value in manager.customSettings:
    customSettingsObj[key] = %value
  result["customSettings"] = customSettingsObj
  
  result["mixedContentDetector"] = manager.mixedContentDetector.toJson()
  
  if manager.cspPolicy.isSome():
    result["cspPolicy"] = %manager.cspPolicy.get().toCspHeader()
  
  return result

# カスタム設定値を設定
proc setCustomSetting*(manager: SecurityManager, key: string, value: string) =
  manager.customSettings[key] = value

# カスタム設定値を取得
proc getCustomSetting*(manager: SecurityManager, key: string): Option[string] =
  if manager.customSettings.hasKey(key):
    return some(manager.customSettings[key])
  return none(string)

# セキュリティレベルの評価を取得
proc evaluateSecurityLevel*(manager: SecurityManager): tuple[score: int, comments: seq[string]] =
  var score = 100
  var comments: seq[string] = @[]
  
  # TLS設定の評価
  let tlsEval = manager.tlsConfig.evaluateSecurityLevel()
  score = (score + tlsEval.score) div 2  # TLS評価を50%の重みで反映
  
  for comment in tlsEval.comments:
    comments.add("TLS: " & comment)
  
  # 混合コンテンツの評価
  case manager.mixedContentDetector.policy:
    of mcpBlock:
      # 最適
      discard
    of mcpBlockActive:
      score -= 10
      comments.add("混合コンテンツ: 能動的コンテンツのみブロックされています")
    of mcpAllowAll:
      score -= 30
      comments.add("混合コンテンツ: すべての混合コンテンツが許可されており、安全ではありません")
    of mcpUpgrade:
      score -= 5
      comments.add("混合コンテンツ: アップグレードモードが有効です")
  
  # セキュリティ機能の評価
  if sfHSTS notin manager.enabledFeatures:
    score -= 10
    comments.add("HSTS機能が無効です")
  
  if sfDNSSEC notin manager.enabledFeatures:
    score -= 5
    comments.add("DNSSEC機能が無効です")
  
  if sfSRI notin manager.enabledFeatures:
    score -= 10
    comments.add("サブリソース完全性チェックが無効です")
  
  if sfExpectCT notin manager.enabledFeatures:
    score -= 5
    comments.add("証明書の透明性チェックが無効です")
  
  if sfSecureDNS notin manager.enabledFeatures:
    score -= 5
    comments.add("セキュアDNS機能が無効です")
  
  # CSPポリシーの評価
  if manager.cspPolicy.isNone():
    score -= 15
    comments.add("デフォルトのCSPポリシーが設定されていません")
  
  # 最終スコアの制限
  score = max(0, min(100, score))
  
  # 全体的な評価コメント
  if score >= 90:
    comments.add("セキュリティ設定は非常に高いレベルです")
  elif score >= 70:
    comments.add("セキュリティ設定は良好ですが、改善の余地があります")
  elif score >= 50:
    comments.add("セキュリティ設定は最低限のレベルですが、強化が推奨されます")
  else:
    comments.add("セキュリティ設定は不十分で、重大なリスクがあります")
  
  return (score, comments)

# すべてのセキュリティコンポーネントの統計情報を取得
proc getStatistics*(manager: SecurityManager): JsonNode =
  result = newJObject()
  
  # 全体的な統計
  result["securityLevel"] = %($manager.securityLevel)
  result["enabledFeaturesCount"] = %manager.enabledFeatures.card
  
  # HSTS統計
  result["hsts"] = manager.hstsManager.getStats()
  
  # 証明書透明性統計
  result["certTransparency"] = manager.certTransparency.getStats()
  
  # セキュアDNS統計
  result["secureDns"] = %{
    "mode": %($manager.secureDnsManager.config.mode),
    "provider": %manager.secureDnsManager.config.providers[manager.secureDnsManager.config.selectedProvider].name,
    "cacheSize": %manager.secureDnsManager.dnsCache.len
  }
  
  # 混合コンテンツ統計
  result["mixedContent"] = %{
    "policy": %($manager.mixedContentDetector.policy)
  }
  
  return result 