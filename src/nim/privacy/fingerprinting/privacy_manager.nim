# privacy_manager.nim
## プライバシーマネージャー
## 様々なフィンガープリント保護機能を統合管理し、最適化とパフォーマンスのバランスを取る

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
  random,
  json,
  logging,
  math,
  os
]

import ./fingerprint_protector
import ./gpu_fingerprint_protector
import ./tls_fingerprint_protector
import ./css_js_protection
import ../privacy_types

type
  PrivacyManager* = ref PrivacyManagerObj
  PrivacyManagerObj = object
    fingerprintProtector*: FingerprintProtector         ## 基本的なフィンガープリント保護
    gpuProtector*: GpuFingerprintProtector              ## GPU指紋保護
    tlsProtector*: TlsFingerprintProtector              ## TLS指紋保護
    cssJsProtector*: CssJsProtector                     ## CSS/JS保護
    
    enabled*: bool                                      ## グローバル有効フラグ
    settings*: PrivacySettings                          ## プライバシー設定
    optimizationTarget*: OptimizationTarget             ## 最適化ターゲット
    protectionStrength*: ProtectionStrength             ## 保護強度
    domainOverrides*: Table[string, DomainOverride]     ## ドメイン別設定
    logger*: Logger                                     ## ロガー
    lastPerformanceImpact*: float                       ## 最後に計測したパフォーマンス影響度
    detectedTrackingAttempts*: int                      ## 検出したトラッキング試行
    
  OptimizationTarget* = enum
    otBalanced,      ## バランス型（デフォルト）
    otPerformance,   ## パフォーマンス優先
    otPrivacy,       ## プライバシー優先
    otCompatibility  ## サイト互換性優先
  
  ProtectionStrength* = enum
    psMinimal,       ## 最小限の保護
    psStandard,      ## 標準的な保護（デフォルト）
    psStrong,        ## 強力な保護
    psMaximum        ## 最大限の保護
  
  DomainOverride* = object
    enabled*: bool                           ## このドメインでの保護が有効か
    protectionLevel*: FingerPrintProtectionLevel  ## 保護レベル
    allowedFeatures*: seq[string]            ## 許可する機能
    customRules*: Table[string, string]      ## カスタムルール

# 機能影響度の定義（全体の中でどの程度の重要度を持つか）
const
  FEATURE_IMPACT = {
    "general": 0.15,
    "canvas": 0.1,
    "webgl": 0.1,
    "audio": 0.05,
    "font": 0.05,
    "tls": 0.15,
    "javascript": 0.2,
    "css": 0.1,
    "battery": 0.01,
    "mediaDevices": 0.03,
    "webRTC": 0.06
  }.toTable

  # 最適化ターゲット別の重み付け係数
  OPTIMIZATION_WEIGHTS = {
    otBalanced: (
      performance: 0.5,
      privacy: 0.5
    ),
    otPerformance: (
      performance: 0.8,
      privacy: 0.2
    ),
    otPrivacy: (
      performance: 0.2,
      privacy: 0.8
    ),
    otCompatibility: (
      performance: 0.6,
      privacy: 0.4
    )
  }.toTable

  # 保護強度別の各保護機能のアクティブ化レベル（0-1）
  PROTECTION_STRENGTH_LEVELS = {
    psMinimal: {
      "general": 0.3,
      "canvas": 0.3,
      "webgl": 0.3,
      "audio": 0.0,
      "font": 0.2,
      "tls": 0.0,
      "javascript": 0.2,
      "css": 0.1,
      "battery": 0.0,
      "mediaDevices": 0.0,
      "webRTC": 0.3
    }.toTable,
    
    psStandard: {
      "general": 0.6,
      "canvas": 0.6,
      "webgl": 0.6,
      "audio": 0.4,
      "font": 0.5,
      "tls": 0.5,
      "javascript": 0.5,
      "css": 0.4,
      "battery": 0.5,
      "mediaDevices": 0.5,
      "webRTC": 0.7
    }.toTable,
    
    psStrong: {
      "general": 0.8,
      "canvas": 0.8,
      "webgl": 0.8,
      "audio": 0.7,
      "font": 0.8,
      "tls": 0.8,
      "javascript": 0.7,
      "css": 0.7,
      "battery": 0.8,
      "mediaDevices": 0.8,
      "webRTC": 0.9
    }.toTable,
    
    psMaximum: {
      "general": 1.0,
      "canvas": 1.0,
      "webgl": 1.0,
      "audio": 1.0,
      "font": 1.0,
      "tls": 1.0,
      "javascript": 1.0,
      "css": 1.0,
      "battery": 1.0,
      "mediaDevices": 1.0,
      "webRTC": 1.0
    }.toTable
  }.toTable

  # 各機能のパフォーマンス影響度（0-1）
  PERFORMANCE_IMPACT = {
    "general": 0.1,
    "canvas": 0.3,
    "webgl": 0.5,
    "audio": 0.2,
    "font": 0.1,
    "tls": 0.05,
    "javascript": 0.6,
    "css": 0.3,
    "battery": 0.01,
    "mediaDevices": 0.01,
    "webRTC": 0.2
  }.toTable

proc newPrivacyManager*(settings: PrivacySettings): PrivacyManager =
  ## 新しいプライバシーマネージャーを作成
  new(result)
  result.enabled = true
  result.settings = settings
  result.optimizationTarget = otBalanced  # デフォルトはバランス型
  result.protectionStrength = psStandard  # デフォルトは標準的な保護
  result.domainOverrides = initTable[string, DomainOverride]()
  result.logger = newConsoleLogger()
  result.lastPerformanceImpact = 0.0
  result.detectedTrackingAttempts = 0
  
  # 各保護モジュールを初期化
  result.fingerprintProtector = newFingerprintProtector(settings.fingerPrintProtection)
  result.gpuProtector = newGpuFingerprintProtector()
  result.tlsProtector = newTlsFingerprintProtector()
  result.cssJsProtector = newCssJsProtector(plStandard)
  
  # 各モジュールの初期設定
  result.updateProtectionSettings()

proc updateProtectionSettings*(manager: PrivacyManager) =
  ## 保護設定を最適化ターゲットと保護強度に基づいて更新
  let strengthLevels = PROTECTION_STRENGTH_LEVELS[manager.protectionStrength]
  let weights = OPTIMIZATION_WEIGHTS[manager.optimizationTarget]
  
  # フィンガープリント保護の設定
  let fpLevel = case manager.protectionStrength
    of psMinimal: fpMinimal
    of psStandard: fpStandard
    of psStrong: fpStrict
    of psMaximum: fpStrict
  
  manager.fingerprintProtector.setProtectionLevel(fpLevel)
  
  # 各ベクターの有効/無効を決定
  for vector in FingerprintVector:
    let vectorName = case vector
      of fvCanvas: "canvas"
      of fvWebGL: "webgl"
      of fvAudioContext: "audio"
      of fvSystemFonts: "font"
      of fvUserAgent: "general"
      of fvTimezone: "general"
      of fvClientHints: "general"
      of fvScreenResolution: "general"
      of fvLanguage: "general"
      of fvBatteryStatus: "battery"
      of fvPlugins: "general"
      of fvMediaDevices: "mediaDevices"
      of fvWebRTC: "webRTC"
      of fvDomRect: "javascript"
      of fvSpeechSynthesis: "general"
    
    let level = strengthLevels.getOrDefault(vectorName, 0.5)
    let performanceImpact = PERFORMANCE_IMPACT.getOrDefault(vectorName, 0.3)
    let importance = FEATURE_IMPACT.getOrDefault(vectorName, 0.1)
    
    # パフォーマンスとプライバシーを考慮したスコア計算
    let privacyScore = level * importance
    let performanceScore = (1.0 - level * performanceImpact)
    let totalScore = weights.privacy * privacyScore + weights.performance * performanceScore
    
    # スコアが0.5以上なら有効化
    let shouldEnable = totalScore >= 0.5
    
    if fpLevel == fpCustom:
      manager.fingerprintProtector.setVectorProtection(vector, shouldEnable)
  
  # GPU保護の設定
  let gpuLevel = strengthLevels.getOrDefault("webgl", 0.5)
  
  if gpuLevel > 0.7:
    manager.gpuProtector.setNoiseLevel(0.003)
    if gpuLevel > 0.9:
      manager.gpuProtector.optimizeForSecurity()
    else:
      # 中間レベル
      manager.gpuProtector.setNoiseLevel(0.002)
  else:
    manager.gpuProtector.setNoiseLevel(0.001)
    manager.gpuProtector.optimizeForPerformance()
  
  # TLS保護の設定
  let tlsLevel = strengthLevels.getOrDefault("tls", 0.5)
  
  if tlsLevel < 0.3:
    manager.tlsProtector.disable()  # 無効化
  else:
    manager.tlsProtector.enable()
    
    if tlsLevel > 0.8:
      # 最大限の保護
      manager.tlsProtector.setTlsProfile(tptRandom)
      manager.tlsProtector.setRotationInterval(4)  # 4時間ごとに回転
    elif tlsLevel > 0.5:
      # 標準的な保護
      manager.tlsProtector.setTlsProfile(tptModern)
      manager.tlsProtector.setRotationInterval(12)  # 12時間ごとに回転
    else:
      # 軽度の保護
      manager.tlsProtector.setTlsProfile(tptChrome)
      manager.tlsProtector.setRotationInterval(24)  # 24時間ごとに回転
  
  # CSS/JS保護の設定
  let cssLevel = strengthLevels.getOrDefault("css", 0.5)
  let jsLevel = strengthLevels.getOrDefault("javascript", 0.5)
  let combinedLevel = (cssLevel + jsLevel) / 2.0
  
  let cssJsProtectionLevel = case manager.protectionStrength
    of psMinimal: plMinimal
    of psStandard: plStandard
    of psStrong: plExtensive
    of psMaximum: plMaximum
  
  manager.cssJsProtector.setProtectionLevel(cssJsProtectionLevel)
  
  # パフォーマンス影響の計算
  var totalImpact = 0.0
  
  for feature, impact in PERFORMANCE_IMPACT.pairs:
    let level = strengthLevels.getOrDefault(feature, 0.5)
    totalImpact += impact * level * FEATURE_IMPACT.getOrDefault(feature, 0.1)
  
  manager.lastPerformanceImpact = totalImpact

proc setOptimizationTarget*(manager: PrivacyManager, target: OptimizationTarget) =
  ## 最適化ターゲットを設定
  manager.optimizationTarget = target
  manager.updateProtectionSettings()

proc setProtectionStrength*(manager: PrivacyManager, strength: ProtectionStrength) =
  ## 保護強度を設定
  manager.protectionStrength = strength
  manager.updateProtectionSettings()

proc enable*(manager: PrivacyManager) =
  ## プライバシー保護を有効化
  manager.enabled = true
  manager.fingerprintProtector.enable()
  manager.gpuProtector.enable()
  manager.tlsProtector.enable()
  manager.cssJsProtector.enable()

proc disable*(manager: PrivacyManager) =
  ## プライバシー保護を無効化
  manager.enabled = false
  manager.fingerprintProtector.disable()
  manager.gpuProtector.disable()
  manager.tlsProtector.disable()
  manager.cssJsProtector.disable()

proc isEnabled*(manager: PrivacyManager): bool =
  ## プライバシー保護が有効かどうか
  return manager.enabled

proc addDomainOverride*(
  manager: PrivacyManager, 
  domain: string, 
  override: DomainOverride
) =
  ## ドメイン別の設定を追加
  manager.domainOverrides[domain] = override
  
  # FingerprintProtectorにもドメインを追加
  if not override.enabled:
    manager.fingerprintProtector.allowDomain(domain)
    manager.tlsProtector.bypassForDomain(domain)

proc removeDomainOverride*(manager: PrivacyManager, domain: string) =
  ## ドメイン別の設定を削除
  if domain in manager.domainOverrides:
    manager.domainOverrides.del(domain)

proc getDomainOverride*(manager: PrivacyManager, domain: string): Option[DomainOverride] =
  ## ドメイン別の設定を取得
  if domain in manager.domainOverrides:
    return some(manager.domainOverrides[domain])
  return none(DomainOverride)

proc shouldProtectDomain*(manager: PrivacyManager, domain: string): bool =
  ## ドメインを保護すべきかどうか
  if not manager.enabled:
    return false
  
  if domain in manager.domainOverrides:
    return manager.domainOverrides[domain].enabled
  
  # デフォルトはグローバル設定に従う
  return true

proc getProtectionConfigForDomain*(
  manager: PrivacyManager, 
  domain: string
): JsonNode =
  ## 特定のドメインに対する保護設定をJSON形式で取得
  if not manager.enabled:
    return %*{"enabled": false}
  
  let shouldProtect = manager.shouldProtectDomain(domain)
  
  if not shouldProtect:
    return %*{
      "enabled": false,
      "domain": domain,
      "reason": "domain_override"
    }
  
  # 各保護モジュールの設定を取得
  let fpConfig = manager.fingerprintProtector.getFullFingerprintProtection(domain)
  let gpuConfig = manager.gpuProtector.getWebGLParameters()
  let tlsConfig = manager.tlsProtector.getClientHelloConfig(domain)
  
  result = %*{
    "enabled": true,
    "domain": domain,
    "protectionStrength": $manager.protectionStrength,
    "optimizationTarget": $manager.optimizationTarget,
    "performanceImpact": manager.lastPerformanceImpact,
    "fingerprint": fpConfig,
    "gpu": gpuConfig,
    "tls": tlsConfig,
    "overrideActive": domain in manager.domainOverrides
  }

proc getGlobalProtectionStatus*(manager: PrivacyManager): JsonNode =
  ## グローバルな保護状態をJSON形式で取得
  result = %*{
    "enabled": manager.enabled,
    "protectionStrength": $manager.protectionStrength,
    "optimizationTarget": $manager.optimizationTarget,
    "performanceImpact": manager.lastPerformanceImpact,
    "detectedTrackingAttempts": manager.detectedTrackingAttempts,
    "modules": {
      "fingerprint": manager.fingerprintProtector.getProtectionStatus(),
      "gpu": manager.gpuProtector.getProtectionStatus(),
      "tls": manager.tlsProtector.getProtectionStatus(),
      "cssJs": manager.cssJsProtector.getProtectionStatus()
    },
    "domainOverrides": manager.domainOverrides.len
  }

proc getJavaScriptProtectionCode*(manager: PrivacyManager, domain: string): string =
  ## 特定のドメインに対するJavaScript保護コードを取得
  if not manager.enabled or not manager.shouldProtectDomain(domain):
    return ""
  
  return manager.cssJsProtector.generateJsInterceptors()

proc getCssProtectionRules*(manager: PrivacyManager, domain: string): string =
  ## 特定のドメインに対するCSS保護ルールを取得
  if not manager.enabled or not manager.shouldProtectDomain(domain):
    return ""
  
  return manager.cssJsProtector.generateCssOverrides()

proc transformShader*(
  manager: PrivacyManager,
  domain: string,
  shaderSource: string
): string =
  ## WebGLシェーダーを変換してフィンガープリント保護を適用
  if not manager.enabled or not manager.shouldProtectDomain(domain):
    return shaderSource
  
  return manager.gpuProtector.transformShader(shaderSource)

proc notifyTrackingAttempt*(
  manager: PrivacyManager,
  domain: string,
  trackingType: string,
  details: JsonNode
) =
  ## トラッキング試行を通知
  if not manager.enabled:
    return
  
  inc(manager.detectedTrackingAttempts)
  manager.logger.log(lvlInfo, fmt"Tracking attempt detected from {domain}: {trackingType}")
  
  # ログに詳細情報を記録
  if details != nil:
    manager.logger.log(lvlDebug, $details)

proc resetSession*(manager: PrivacyManager) =
  ## セッションをリセット（新しい偽装値を生成）
  manager.fingerprintProtector.resetSession()
  
  # TLSプロファイルを回転
  let currentProfile = manager.tlsProtector.tlsProfile.profileType
  manager.tlsProtector.setTlsProfile(currentProfile)

proc updatePrivacySettings*(manager: PrivacyManager, settings: PrivacySettings) =
  ## プライバシー設定を更新
  manager.settings = settings
  
  # 指紋防止の設定を更新
  manager.fingerprintProtector.initFromPrivacySettings(settings)
  
  # 設定に基づいて保護レベルを調整
  let newStrength = case settings.fingerPrintProtection
    of fpNone: psMinimal
    of fpMinimal: psMinimal
    of fpStandard: psStandard
    of fpStrict: psStrong
    of fpCustom: manager.protectionStrength  # 変更なし
  
  if newStrength != manager.protectionStrength:
    manager.setProtectionStrength(newStrength)
  
  # ホワイトリストドメインの更新
  for domain in settings.whitelistedDomains:
    if domain notin manager.domainOverrides:
      var override = DomainOverride(
        enabled: false,
        protectionLevel: fpNone,
        allowedFeatures: @[],
        customRules: initTable[string, string]()
      )
      manager.addDomainOverride(domain, override)

proc generateProtectionReport*(manager: PrivacyManager): JsonNode =
  ## 保護レポートを生成
  var report = %*{
    "timestamp": $getTime(),
    "globalStatus": manager.getGlobalProtectionStatus(),
    "detailedMetrics": {
      "performanceImpact": manager.lastPerformanceImpact,
      "trackingAttemptsBlocked": manager.detectedTrackingAttempts,
      "domainOverridesCount": manager.domainOverrides.len,
      "featureSupport": {
        "canvas": manager.fingerprintProtector.isVectorProtected(fvCanvas),
        "webgl": manager.fingerprintProtector.isVectorProtected(fvWebGL),
        "audio": manager.fingerprintProtector.isVectorProtected(fvAudioContext),
        "fonts": manager.fingerprintProtector.isVectorProtected(fvSystemFonts),
        "mediaDevices": manager.fingerprintProtector.isVectorProtected(fvMediaDevices),
        "webRTC": manager.fingerprintProtector.isVectorProtected(fvWebRTC),
        "battery": manager.fingerprintProtector.isVectorProtected(fvBatteryStatus),
        "tlsProtection": manager.tlsProtector.isEnabled()
      }
    },
    "domainSpecificInfo": newJObject()
  }
  
  # 上位5つのドメインオーバーライドを追加
  var domains = toSeq(manager.domainOverrides.keys)
  for i in 0..<min(5, domains.len):
    let domain = domains[i]
    let override = manager.domainOverrides[domain]
    report["domainSpecificInfo"][domain] = %*{
      "enabled": override.enabled,
      "protectionLevel": $override.protectionLevel,
      "allowedFeatures": override.allowedFeatures,
      "customRulesCount": override.customRules.len
    }
  
  return report

proc exportSettings*(manager: PrivacyManager): JsonNode =
  ## 設定をエクスポート
  var domainOverrides = newJObject()
  for domain, override in manager.domainOverrides.pairs:
    var customRules = newJObject()
    for key, value in override.customRules.pairs:
      customRules[key] = %value
    
    domainOverrides[domain] = %*{
      "enabled": override.enabled,
      "protectionLevel": $override.protectionLevel,
      "allowedFeatures": override.allowedFeatures,
      "customRules": customRules
    }
  
  result = %*{
    "version": 1,
    "global": {
      "enabled": manager.enabled,
      "protectionStrength": $manager.protectionStrength,
      "optimizationTarget": $manager.optimizationTarget
    },
    "fingerprint": {
      "protectionLevel": $manager.settings.fingerPrintProtection,
      "consistentValues": manager.fingerprintProtector.consistentValues
    },
    "domainOverrides": domainOverrides
  }

proc importSettings*(manager: PrivacyManager, settings: JsonNode): bool =
  ## 設定をインポート
  try:
    if settings.hasKey("version") and settings["version"].getInt() == 1:
      # グローバル設定
      if settings.hasKey("global"):
        let global = settings["global"]
        manager.enabled = global["enabled"].getBool()
        
        if global.hasKey("protectionStrength"):
          let strengthStr = global["protectionStrength"].getStr()
          manager.protectionStrength = case strengthStr
            of "psMinimal": psMinimal
            of "psStandard": psStandard
            of "psStrong": psStrong
            of "psMaximum": psMaximum
            else: psStandard
        
        if global.hasKey("optimizationTarget"):
          let targetStr = global["optimizationTarget"].getStr()
          manager.optimizationTarget = case targetStr
            of "otBalanced": otBalanced
            of "otPerformance": otPerformance
            of "otPrivacy": otPrivacy
            of "otCompatibility": otCompatibility
            else: otBalanced
      
      # 指紋防止設定
      if settings.hasKey("fingerprint"):
        let fp = settings["fingerprint"]
        
        if fp.hasKey("protectionLevel"):
          let levelStr = fp["protectionLevel"].getStr()
          let level = case levelStr
            of "fpNone": fpNone
            of "fpMinimal": fpMinimal
            of "fpStandard": fpStandard
            of "fpStrict": fpStrict
            of "fpCustom": fpCustom
            else: fpStandard
          
          manager.settings.fingerPrintProtection = level
          manager.fingerprintProtector.setProtectionLevel(level)
        
        if fp.hasKey("consistentValues"):
          let consistent = fp["consistentValues"].getBool()
          manager.fingerprintProtector.setConsistentValues(consistent)
      
      # ドメインオーバーライド
      if settings.hasKey("domainOverrides"):
        let overrides = settings["domainOverrides"]
        manager.domainOverrides.clear()
        
        for domain, data in overrides.pairs:
          var override = DomainOverride(
            enabled: data["enabled"].getBool(),
            allowedFeatures: @[],
            customRules: initTable[string, string]()
          )
          
          if data.hasKey("protectionLevel"):
            let levelStr = data["protectionLevel"].getStr()
            override.protectionLevel = case levelStr
              of "fpNone": fpNone
              of "fpMinimal": fpMinimal
              of "fpStandard": fpStandard
              of "fpStrict": fpStrict
              of "fpCustom": fpCustom
              else: fpNone
          
          if data.hasKey("allowedFeatures") and data["allowedFeatures"].kind == JArray:
            for feature in data["allowedFeatures"]:
              override.allowedFeatures.add(feature.getStr())
          
          if data.hasKey("customRules") and data["customRules"].kind == JObject:
            for key, value in data["customRules"].pairs:
              override.customRules[key] = value.getStr()
          
          manager.addDomainOverride(domain, override)
      
      # 設定を更新
      manager.updateProtectionSettings()
      return true
    
    return false
  except:
    return false

when isMainModule:
  # テスト用コード
  var settings = PrivacySettings(
    fingerPrintProtection: fpStandard,
    whitelistedDomains: @["example.com", "trusted-site.org"]
  )
  
  let manager = newPrivacyManager(settings)
  
  # 設定テスト
  manager.setProtectionStrength(psStrong)
  manager.setOptimizationTarget(otPrivacy)
  
  # ドメインオーバーライドのテスト
  var override = DomainOverride(
    enabled: false,
    protectionLevel: fpNone,
    allowedFeatures: @["canvas"],
    customRules: {"allowWebGL": "true"}.toTable
  )
  
  manager.addDomainOverride("my-bank.com", override)
  
  # レポート生成テスト
  echo manager.getGlobalProtectionStatus()
  echo manager.getProtectionConfigForDomain("example.org")
  
  # エクスポート/インポートテスト
  let exported = manager.exportSettings()
  echo "Exported settings: ", exported
  
  # 設定を変更してからインポート
  manager.setProtectionStrength(psMinimal)
  discard manager.importSettings(exported)
  
  # インポート後の設定確認
  echo "Protection strength after import: ", manager.protectionStrength 