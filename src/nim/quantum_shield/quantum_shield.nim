# quantum_shield.nim
## Quantum Shield - ブラウザの先進的なセキュリティおよびプライバシー保護フレームワーク
## すべてのセキュリティコンポーネントを統一的に管理し、ユーザーを保護します

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
  uri,
  os,
  json,
  logging,
  asyncdispatch
]

# 各コンポーネントのインポート
import certificates/store
import certificates/validator
import content_security/csp
import content_security/xss_protection
import privacy/fingerprint
import privacy/tracker_blocker
import sandbox/isolation
import sandbox/process
import webrtc/protection as webrtc_protection

# 他の必要なモジュール
import ../privacy/privacy_types
import ../privacy/blockers/tracker_blocker as tb
import ../network/http/client/http_client_types

type
  SecurityLevel* = enum
    ## セキュリティレベル設定
    slStandard,    ## 標準的な保護（バランス重視）
    slHigh,        ## 高度な保護（セキュリティ重視）
    slMaximum,     ## 最大限の保護（機能制限あり）
    slCustom       ## カスタム設定

  QuantumShield* = ref object
    ## Quantum Shield コアオブジェクト
    enabled*: bool                    ## 有効フラグ
    securityLevel*: SecurityLevel     ## セキュリティレベル
    logger*: Logger                   ## ロガー
    
    # 各コンポーネント
    certificateStore*: CertificateStore         ## 証明書ストア
    certificateValidator*: CertificateValidator ## 証明書検証
    contentSecurityPolicy*: ContentSecurityPolicy ## CSP
    xssProtection*: XssProtection               ## XSS対策
    fingerprintProtection*: FingerprintProtection ## フィンガープリント対策
    trackerBlocker*: TrackerBlocker              ## トラッカーブロック
    sandboxIsolation*: SandboxIsolation         ## サンドボックス分離
    processManager*: ProcessManager             ## プロセス管理
    webRtcProtector*: webrtc_protection.WebRtcProtector ## WebRTC保護
    
    # 設定とポリシー
    domainPolicies*: Table[string, SecurityLevel] ## ドメイン別ポリシー
    siteExceptions*: HashSet[string]              ## 例外サイト
    lastUpdateTime*: Time                         ## 最終更新時間
    scanResults*: Table[string, JsonNode]         ## スキャン結果

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc newQuantumShield*(securityLevel: SecurityLevel = slStandard): QuantumShield =
  ## 新しいQuantum Shieldを作成
  new(result)
  result.enabled = true
  result.securityLevel = securityLevel
  result.logger = newConsoleLogger()
  
  # 各コンポーネントの初期化
  result.certificateStore = newCertificateStore()
  result.certificateValidator = newCertificateValidator(result.certificateStore)
  result.contentSecurityPolicy = newContentSecurityPolicy()
  result.xssProtection = newXssProtection()
  result.fingerprintProtection = newFingerprintProtection()
  result.trackerBlocker = tb.newTrackerBlocker()
  result.sandboxIsolation = newSandboxIsolation()
  result.processManager = newProcessManager()
  result.webRtcProtector = webrtc_protection.newWebRtcProtector()
  
  # その他のフィールド初期化
  result.domainPolicies = initTable[string, SecurityLevel]()
  result.siteExceptions = initHashSet[string]()
  result.lastUpdateTime = getTime()
  result.scanResults = initTable[string, JsonNode]()
  
  # セキュリティレベルに応じた初期設定
  result.applySecurityLevel(securityLevel)

proc applySecurityLevel*(shield: QuantumShield, level: SecurityLevel) =
  ## セキュリティレベルを適用
  shield.securityLevel = level
  
  case level
  of slStandard:
    # 標準的な保護設定
    shield.trackerBlocker.setSeverity(tbsStandard)
    shield.fingerprintProtection.setProtectionLevel(fpStandard)
    shield.contentSecurityPolicy.setStandardPolicy()
    shield.xssProtection.enable()
    shield.certificateValidator.setValidationLevel(vlStandard)
    shield.sandboxIsolation.setSandboxLevel(sbStandard)
    shield.processManager.setSeparationMode(psSeparateByOrigin)
    shield.webRtcProtector.setProtectionLevel(webrtc_protection.wrpPublicOnly)
    
  of slHigh:
    # 高度な保護設定
    shield.trackerBlocker.setSeverity(tbsStrict)
    shield.fingerprintProtection.setProtectionLevel(fpStrict)
    shield.contentSecurityPolicy.setStrictPolicy()
    shield.xssProtection.enableStrictMode()
    shield.certificateValidator.setValidationLevel(vlStrict)
    shield.sandboxIsolation.setSandboxLevel(sbStrict)
    shield.processManager.setSeparationMode(psSeparateAll)
    shield.webRtcProtector.setProtectionLevel(webrtc_protection.wrpFullProtection)
    
  of slMaximum:
    # 最大限の保護設定（一部機能制限）
    shield.trackerBlocker.setSeverity(tbsStrict)
    shield.fingerprintProtection.setProtectionLevel(fpStrict)
    shield.contentSecurityPolicy.setMaxSecurityPolicy()
    shield.xssProtection.enableStrictMode()
    shield.certificateValidator.setValidationLevel(vlExtreme)
    shield.sandboxIsolation.setSandboxLevel(sbExtreme)
    shield.processManager.setSeparationMode(psSeparateAllWithJS)
    shield.webRtcProtector.setProtectionLevel(webrtc_protection.wrpDisableWebRtc)
    # JavaScript完全無効化などの追加制限も可能
    
  of slCustom:
    # 現在の設定を維持（カスタム設定）
    discard

proc setDomainPolicy*(shield: QuantumShield, domain: string, level: SecurityLevel) =
  ## 特定ドメインにセキュリティポリシーを設定
  shield.domainPolicies[domain] = level

proc getDomainPolicy*(shield: QuantumShield, domain: string): SecurityLevel =
  ## ドメインのセキュリティポリシーを取得
  if shield.domainPolicies.hasKey(domain):
    return shield.domainPolicies[domain]
  
  # サブドメインのチェック
  for d, level in shield.domainPolicies:
    if domain.endsWith("." & d):
      return level
  
  # デフォルトのセキュリティレベルを返す
  return shield.securityLevel

proc addException*(shield: QuantumShield, domain: string) =
  ## 保護の例外ドメインを追加
  shield.siteExceptions.incl(domain)
  
  # 各コンポーネントに例外を設定
  shield.trackerBlocker.whitelistDomain(domain)
  shield.fingerprintProtection.addExemptDomain(domain)
  shield.contentSecurityPolicy.addExemptDomain(domain)
  shield.xssProtection.addExemptDomain(domain)
  shield.webRtcProtector.addExceptionDomain(domain)

proc removeException*(shield: QuantumShield, domain: string) =
  ## 保護の例外ドメインを削除
  shield.siteExceptions.excl(domain)
  
  # 各コンポーネントから例外を削除
  # 実際の実装では対応するメソッドを呼び出す

proc isExceptionDomain*(shield: QuantumShield, domain: string): bool =
  ## 例外ドメインかどうかを確認
  if domain in shield.siteExceptions:
    return true
  
  # サブドメインのチェック
  for d in shield.siteExceptions:
    if domain.endsWith("." & d):
      return true
  
  return false

#----------------------------------------
# メイン機能
#----------------------------------------

proc processRequest*(shield: QuantumShield, request: HttpRequest, 
                   referrer: string = ""): Future[HttpRequest] {.async.} =
  ## リクエストを処理して必要に応じて修正
  if not shield.enabled:
    return request
  
  let domain = getDomainFromUrl(request.url)
  
  # 例外ドメインの場合は修正せずに返す
  if shield.isExceptionDomain(domain):
    return request
  
  # ドメインポリシーの適用
  let policy = shield.getDomainPolicy(domain)
  
  # CSPヘッダーの追加
  var modifiedRequest = request
  case policy
  of slStandard:
    modifiedRequest.headers.add(("Content-Security-Policy", shield.contentSecurityPolicy.getStandardPolicyHeader()))
  of slHigh:
    modifiedRequest.headers.add(("Content-Security-Policy", shield.contentSecurityPolicy.getStrictPolicyHeader()))
  of slMaximum:
    modifiedRequest.headers.add(("Content-Security-Policy", shield.contentSecurityPolicy.getMaxSecurityPolicyHeader()))
  of slCustom:
    let customCsp = shield.contentSecurityPolicy.getCustomPolicyHeader(domain)
    if customCsp.len > 0:
      modifiedRequest.headers.add(("Content-Security-Policy", customCsp))
  
  # フィンガープリント保護のためのヘッダー修正
  modifiedRequest = shield.fingerprintProtection.modifyRequestHeaders(modifiedRequest, domain)
  
  # リファラーポリシーの設定
  modifiedRequest.headers.add(("Referrer-Policy", "strict-origin-when-cross-origin"))
  
  # 他のセキュリティヘッダーを追加
  modifiedRequest.headers.add(("X-Content-Type-Options", "nosniff"))
  modifiedRequest.headers.add(("X-Frame-Options", "SAMEORIGIN"))
  
  if shield.xssProtection.isEnabled():
    modifiedRequest.headers.add(("X-XSS-Protection", "1; mode=block"))
  
  return modifiedRequest

proc processResponse*(shield: QuantumShield, response: HttpResponse, 
                    url: string): Future[HttpResponse] {.async.} =
  ## レスポンスを処理して必要に応じて修正
  if not shield.enabled:
    return response
  
  let domain = getDomainFromUrl(url)
  
  # 例外ドメインの場合は修正せずに返す
  if shield.isExceptionDomain(domain):
    return response
  
  # ドメインポリシーの適用
  let policy = shield.getDomainPolicy(domain)
  
  # 証明書検証
  if url.startsWith("https://"):
    let certValid = await shield.certificateValidator.validateCertificate(url, response)
    if not certValid:
      # 証明書エラーの処理
      # 実際の実装ではエラーページにリダイレクトなど
      shield.logger.log(lvlWarn, "証明書検証エラー: " & url)
  
  # CSPの検証と強化
  var modifiedResponse = response
  shield.contentSecurityPolicy.enforcePolicy(modifiedResponse, domain, policy)
  
  # XSS保護の適用
  shield.xssProtection.sanitizeResponse(modifiedResponse, domain)
  
  # コンテンツスキャン（実装例、実際にはさらに洗練された方法を使用）
  let scanResult = shield.scanContent(modifiedResponse.body, url, domain)
  shield.scanResults[url] = scanResult
  
  # スキャン結果に基づいた処理
  if scanResult.hasKey("threat") and scanResult["threat"].getBool():
    shield.logger.log(lvlWarn, "脅威を検出: " & url)
    # 例えば、安全でないコンテンツをブロックする場合
    modifiedResponse.body = "コンテンツはセキュリティ上の理由でブロックされました"
    modifiedResponse.statusCode = 403
  
  return modifiedResponse

proc shouldBlockRequest*(shield: QuantumShield, url: string, 
                       referrerUrl: string = "", requestType: string = ""): bool =
  ## リクエストをブロックすべきか判断
  if not shield.enabled:
    return false
  
  let domain = getDomainFromUrl(url)
  
  # 例外ドメインの場合はブロックしない
  if shield.isExceptionDomain(domain):
    return false
  
  # トラッカーブロッカーによる判断
  let blockResult = shield.trackerBlocker.shouldBlockUrl(url, referrerUrl, requestType)
  if blockResult.isSome and blockResult.get().blockDecision == bmBlock:
    return true
  
  # セキュリティレベルに応じた追加チェック
  let policy = shield.getDomainPolicy(domain)
  
  case policy
  of slMaximum:
    # 最大保護では厳格にチェック
    # JavaScriptソースのブロック、未知のドメインへのリクエスト制限など
    if requestType == "script" and not shield.isKnownSafeDomain(domain):
      return true
  of slHigh:
    # 高保護ではある程度厳格にチェック
    if shield.isKnownMaliciousDomain(domain):
      return true
  else:
    # 標準保護ではより緩やかに
    if shield.isKnownMaliciousDomain(domain) and 
       requestType in ["script", "xhr", "websocket"]:
      return true
  
  return false

proc isKnownSafeDomain*(shield: QuantumShield, domain: string): bool =
  ## 既知の安全なドメインかどうか確認
  # 実際の実装ではホワイトリストやレピュテーションデータベースと照合
  # ここではサンプル実装のみ
  return domain in ["trusted-site.com", "example.org", "secure-cdn.net"]

proc isKnownMaliciousDomain*(shield: QuantumShield, domain: string): bool =
  ## 既知の悪意のあるドメインかどうか確認
  # 実際の実装ではブラックリストやレピュテーションデータベースと照合
  # ここではサンプル実装のみ
  return domain in ["malware-site.com", "phishing-example.net", "evil-tracker.org"]

proc scanContent*(shield: QuantumShield, content: string, url: string, domain: string): JsonNode =
  ## コンテンツをスキャンして脅威を検出
  # 実際の実装ではより高度なスキャンロジックを使用
  
  result = %*{
    "url": url,
    "domain": domain,
    "scanTime": $getTime().toUnix(),
    "threat": false,
    "threatType": "none",
    "details": {}
  }
  
  # 簡易的な悪意のあるパターン検出（例示のみ）
  if content.contains("<script>evil") or 
     content.contains("eval(atob(") or
     content.contains("document.cookie") and content.contains("document.location"):
    result["threat"] = %true
    result["threatType"] = %"suspicious-script"
    result["details"] = %*{
      "reason": "疑わしいスクリプトパターンを検出",
      "severity": "medium"
    }
  
  # フィッシング検出（例示のみ）
  if (content.toLowerAscii().contains("password") or content.toLowerAscii().contains("credit card")) and
     (domain != "bank.com" and domain != "paypal.com" and domain != "amazon.com"):
    if content.contains("<form") and content.contains("action="):
      result["threat"] = %true
      result["threatType"] = %"potential-phishing"
      result["details"] = %*{
        "reason": "フィッシングの疑い",
        "severity": "high"
      }

#----------------------------------------
# WebRTC保護
#----------------------------------------

proc processWebRtcRequest*(shield: QuantumShield, candidate: string, origin: string): tuple[allow: bool, replacement: string] =
  ## WebRTC要求を処理（拡張版）
  # 例外ドメインの場合
  let domain = getDomainFromUrl(origin)
  if shield.isExceptionDomain(domain):
    return (true, "")
  
  # セキュリティレベルに応じた処理
  if shield.securityLevel == slMaximum:
    # 最大保護レベルではすべてブロック
    let result = shield.webRtcProtector.processCandidate(candidate, origin)
    return (false, "")
  
  # 新しいWebRTC保護機能を利用
  let result = shield.webRtcProtector.processCandidate(candidate, origin)
  
  case result.action
  of webrtc_protection.paAllow:
    return (true, "")
  of webrtc_protection.paBlock:
    return (false, "")
  of webrtc_protection.paReplace:
    return (false, result.replacement)
  of webrtc_protection.paModify:
    return (true, result.replacement)

proc setWebRtcProtection*(shield: QuantumShield, level: webrtc_protection.WebRtcProtectionLevel) =
  ## WebRTC保護レベルを設定
  shield.webRtcProtector.setProtectionLevel(level)

proc getWebRtcProtectionScript*(shield: QuantumShield): string =
  ## WebRTC保護スクリプトを取得
  return shield.webRtcProtector.generateWebRtcPreventionScript()

proc sanitizeIceServers*(shield: QuantumShield, servers: seq[string]): seq[string] =
  ## ICEサーバーをサニタイズ
  result = @[]
  
  for server in servers:
    let sanitized = shield.webRtcProtector.sanitizeIceServer(server)
    if sanitized.allow:
      result.add(sanitized.modified)

#----------------------------------------
# 統計情報
#----------------------------------------

proc getStats*(shield: QuantumShield): JsonNode =
  ## Quantum Shieldの統計情報を取得
  var componentStats = newJObject()
  
  # 各コンポーネントの統計を集約
  componentStats["trackerBlocker"] = shield.trackerBlocker.getStats()
  componentStats["fingerprintProtection"] = shield.fingerprintProtection.getStats()
  componentStats["certificateValidator"] = shield.certificateValidator.getStats()
  componentStats["contentSecurity"] = shield.contentSecurityPolicy.getStats()
  componentStats["xssProtection"] = shield.xssProtection.getStats()
  componentStats["sandboxIsolation"] = shield.sandboxIsolation.getStats()
  componentStats["webRtcProtection"] = shield.webRtcProtector.getStats()
  
  result = %*{
    "enabled": shield.enabled,
    "securityLevel": $shield.securityLevel,
    "exceptionDomains": shield.siteExceptions.len,
    "customPolicies": shield.domainPolicies.len,
    "lastUpdated": $shield.lastUpdateTime.toUnix(),
    "components": componentStats
  }

proc resetStats*(shield: QuantumShield) =
  ## 統計情報をリセット
  # 各コンポーネントの統計をリセット
  # 実際の実装では対応するメソッドを呼び出す

#----------------------------------------
# 設定保存と読み込み
#----------------------------------------

proc saveConfiguration*(shield: QuantumShield, filePath: string): bool =
  ## 設定を保存
  try:
    var config = %*{
      "enabled": shield.enabled,
      "securityLevel": $shield.securityLevel,
      "exceptionDomains": %shield.siteExceptions.toSeq(),
      "lastUpdateTime": $shield.lastUpdateTime.toUnix()
    }
    
    # ドメインポリシーの保存
    var domainPoliciesJson = newJObject()
    for domain, level in shield.domainPolicies:
      domainPoliciesJson[domain] = %($level)
    
    config["domainPolicies"] = domainPoliciesJson
    
    # コンポーネント固有の設定
    config["componentSettings"] = %*{
      "trackerBlocker": %*{
        "severity": $shield.trackerBlocker.severity,
        "webRtcProtection": %*{
          "enabled": shield.trackerBlocker.webRtcProtection.enabled,
          "policy": $shield.trackerBlocker.webRtcProtection.policy
        }
      },
      "fingerprintProtection": %*{
        "level": $shield.fingerprintProtection.protectionLevel
      },
      "certificateValidator": %*{
        "level": $shield.certificateValidator.validationLevel
      },
      "webRtcProtector": %*{
        "level": $shield.webRtcProtector.level,
        "enforceMdns": shield.webRtcProtector.enforceMdns,
        "disableNonProxiedUdp": shield.webRtcProtector.disableNonProxiedUdp
      }
    }
    
    writeFile(filePath, pretty(config))
    return true
  except:
    shield.logger.log(lvlError, "設定の保存に失敗: " & getCurrentExceptionMsg())
    return false

proc loadConfiguration*(shield: QuantumShield, filePath: string): bool =
  ## 設定を読み込む
  try:
    if not fileExists(filePath):
      return false
    
    let jsonContent = readFile(filePath)
    let config = parseJson(jsonContent)
    
    # 基本設定
    shield.enabled = config.getOrDefault("enabled").getBool(true)
    shield.securityLevel = parseEnum[SecurityLevel](config.getOrDefault("securityLevel").getStr("slStandard"))
    
    # 例外ドメイン
    shield.siteExceptions.clear()
    for item in config.getOrDefault("exceptionDomains"):
      if item.kind == JString:
        shield.siteExceptions.incl(item.getStr())
    
    # ドメインポリシー
    shield.domainPolicies.clear()
    let domainPoliciesJson = config.getOrDefault("domainPolicies")
    if domainPoliciesJson.kind == JObject:
      for domain, levelValue in domainPoliciesJson:
        let level = parseEnum[SecurityLevel](levelValue.getStr())
        shield.domainPolicies[domain] = level
    
    # コンポーネント設定
    let componentSettings = config.getOrDefault("componentSettings")
    if componentSettings.kind == JObject:
      # トラッカーブロッカー設定
      if componentSettings.hasKey("trackerBlocker"):
        let tbSettings = componentSettings["trackerBlocker"]
        if tbSettings.hasKey("severity"):
          shield.trackerBlocker.setSeverity(parseEnum[TrackerBlockerSeverity](tbSettings["severity"].getStr()))
        
        # WebRTC保護設定
        if tbSettings.hasKey("webRtcProtection"):
          let webRtcSettings = tbSettings["webRtcProtection"]
          shield.trackerBlocker.webRtcProtection.enabled = webRtcSettings.getOrDefault("enabled").getBool(true)
          shield.trackerBlocker.webRtcProtection.policy = parseEnum[WebRtcPolicy](
            webRtcSettings.getOrDefault("policy").getStr("wrpPublicOnly"))
      
      # フィンガープリント保護設定
      if componentSettings.hasKey("fingerprintProtection"):
        let fpSettings = componentSettings["fingerprintProtection"]
        if fpSettings.hasKey("level"):
          shield.fingerprintProtection.setProtectionLevel(
            parseEnum[FingerPrintProtectionLevel](fpSettings["level"].getStr()))
      
      # 証明書検証設定
      if componentSettings.hasKey("certificateValidator"):
        let cvSettings = componentSettings["certificateValidator"]
        if cvSettings.hasKey("level"):
          shield.certificateValidator.setValidationLevel(
            parseEnum[ValidationLevel](cvSettings["level"].getStr()))
      
      # 新しいWebRTC保護設定
      if componentSettings.hasKey("webRtcProtector"):
        let wrpSettings = componentSettings["webRtcProtector"]
        if wrpSettings.hasKey("level"):
          shield.webRtcProtector.setProtectionLevel(
            parseEnum[webrtc_protection.WebRtcProtectionLevel](wrpSettings["level"].getStr()))
        
        if wrpSettings.hasKey("enforceMdns"):
          shield.webRtcProtector.enforceMdns = wrpSettings["enforceMdns"].getBool()
          
        if wrpSettings.hasKey("disableNonProxiedUdp"):
          shield.webRtcProtector.disableNonProxiedUdp = wrpSettings["disableNonProxiedUdp"].getBool()
    
    # 時間情報
    if config.hasKey("lastUpdateTime"):
      shield.lastUpdateTime = fromUnix(parseBiggestInt(config["lastUpdateTime"].getStr()))
    else:
      shield.lastUpdateTime = getTime()
    
    # セキュリティレベルの適用
    shield.applySecurityLevel(shield.securityLevel)
    
    return true
  except:
    shield.logger.log(lvlError, "設定の読み込みに失敗: " & getCurrentExceptionMsg())
    return false

#----------------------------------------
# メインテナンスとアップデート
#----------------------------------------

proc update*(shield: QuantumShield): Future[bool] {.async.} =
  ## セキュリティデータを更新
  try:
    # 各コンポーネントの更新
    await shield.trackerBlocker.initDefaultLists()
    await shield.certificateStore.updateRootCertificates()
    await shield.contentSecurityPolicy.updatePolicies()
    
    shield.lastUpdateTime = getTime()
    return true
  except:
    shield.logger.log(lvlError, "更新に失敗: " & getCurrentExceptionMsg())
    return false

proc cleanup*(shield: QuantumShield) =
  ## 未使用リソースの解放とキャッシュクリーンアップ
  shield.trackerBlocker.cleanupCache()
  shield.certificateStore.cleanupExpiredCerts()
  shield.scanResults.clear()
  # 他のコンポーネントのクリーンアップも実行

#----------------------------------------
# デバッグとトラブルシューティング
#----------------------------------------

proc generateReport*(shield: QuantumShield): string =
  ## 診断レポートを生成
  result = "Quantum Shield 診断レポート\n"
  result &= "==========================\n"
  result &= fmt"生成時刻: {$getTime()}\n"
  result &= fmt"有効状態: {shield.enabled}\n"
  result &= fmt"セキュリティレベル: {shield.securityLevel}\n"
  result &= fmt"例外ドメイン数: {shield.siteExceptions.len}\n"
  result &= fmt"カスタムポリシー数: {shield.domainPolicies.len}\n"
  result &= fmt"最終更新: {shield.lastUpdateTime}\n\n"
  
  # 各コンポーネントの状態
  result &= "コンポーネント状態:\n"
  result &= fmt"- トラッカーブロッカー: 有効, 厳格度={shield.trackerBlocker.severity}\n"
  result &= fmt"- WebRTC保護(旧): {if shield.trackerBlocker.webRtcProtection.enabled: '有効' else: '無効'}, ポリシー={shield.trackerBlocker.webRtcProtection.policy}\n"
  result &= fmt"- WebRTC保護(新): 有効, レベル={shield.webRtcProtector.level}\n"
  result &= fmt"- フィンガープリント保護: 有効, レベル={shield.fingerprintProtection.protectionLevel}\n"
  result &= fmt"- 証明書検証: 有効, レベル={shield.certificateValidator.validationLevel}\n"
  result &= fmt"- CSP: 有効, ポリシー数={shield.contentSecurityPolicy.getPolicyCount()}\n"
  result &= fmt"- XSS保護: {if shield.xssProtection.isEnabled(): '有効' else: '無効'}\n"
  result &= fmt"- サンドボックス: 有効, レベル={shield.sandboxIsolation.sandboxLevel}\n"
  
  # 統計情報
  let stats = shield.getStats()
  result &= "\n統計情報:\n"
  result &= $pretty(stats)
  
  return result

proc setLoggingLevel*(shield: QuantumShield, level: Level) =
  ## ロギングレベルを設定
  shield.logger = newConsoleLogger(level)

when isMainModule:
  # テスト用コード
  echo "Quantum Shield テスト"
  
  # 初期化
  let shield = newQuantumShield(slStandard)
  echo "Quantum Shield 初期化完了"
  
  # セキュリティレベル設定テスト
  shield.applySecurityLevel(slHigh)
  echo "セキュリティレベルを High に設定"
  
  # ドメインポリシーテスト
  shield.setDomainPolicy("example.com", slStandard)
  shield.setDomainPolicy("bank.com", slMaximum)
  echo "ドメインポリシー設定完了"
  
  # 例外追加テスト
  shield.addException("trusted-site.com")
  echo "信頼済みサイトを例外に追加"
  
  # 設定の保存と読み込みテスト
  discard shield.saveConfiguration("quantum_shield_config.json")
  echo "設定を保存"
  
  # WebRTC保護テスト
  let candidate = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0"
  let result = shield.processWebRtcRequest(candidate, "https://example.com")
  echo "WebRTC保護: ", if result.allow: "許可" else: "ブロック"
  
  # 診断レポート生成
  echo shield.generateReport() 