# TLS設定モジュール
#
# このモジュールは、ブラウザのTLS(Transport Layer Security)設定を管理します。
# TLSプロトコルバージョンや暗号スイートの制御、TLSセッションの設定を行います。

import std/[tables, sets, options, strutils, sequtils, sugar, json]
import ../certificates/certificate_store
import ../../logging

type
  TlsProtocolVersion* = enum
    tlsUnknown = "unknown"   # 不明なバージョン
    tlsSSL3 = "ssl3"         # SSL 3.0（非推奨）
    tlsTLS10 = "tls1.0"      # TLS 1.0（非推奨）
    tlsTLS11 = "tls1.1"      # TLS 1.1（非推奨）
    tlsTLS12 = "tls1.2"      # TLS 1.2
    tlsTLS13 = "tls1.3"      # TLS 1.3

  TlsCipherSuite* = enum
    # TLS 1.2 暗号スイート
    tcsAES_128_GCM_SHA256 = "TLS_AES_128_GCM_SHA256"
    tcsAES_256_GCM_SHA384 = "TLS_AES_256_GCM_SHA384"
    tcsCHACHA20_POLY1305_SHA256 = "TLS_CHACHA20_POLY1305_SHA256"
    tcsECDHE_ECDSA_WITH_AES_128_GCM_SHA256 = "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
    tcsECDHE_RSA_WITH_AES_128_GCM_SHA256 = "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
    tcsECDHE_ECDSA_WITH_AES_256_GCM_SHA384 = "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384"
    tcsECDHE_RSA_WITH_AES_256_GCM_SHA384 = "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
    tcsECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 = "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
    tcsECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256 = "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256"
    # レガシー暗号スイート（非推奨）
    tcsRSA_WITH_AES_128_CBC_SHA = "TLS_RSA_WITH_AES_128_CBC_SHA"
    tcsRSA_WITH_AES_256_CBC_SHA = "TLS_RSA_WITH_AES_256_CBC_SHA"
    tcsRSA_WITH_3DES_EDE_CBC_SHA = "TLS_RSA_WITH_3DES_EDE_CBC_SHA"

  TlsVerificationMode* = enum
    tvmFull                # 完全検証（証明書チェーン全体を検証）
    tvmSkipHostnameCheck   # ホスト名チェックをスキップ
    tvmSkipCertificateCheck # 証明書チェックをスキップ（危険）
    tvmAcceptInvalidCert   # 無効な証明書を受け入れる（危険）

  TlsSessionInfo* = object
    peerHostname*: string         # ピアのホスト名
    protocol*: TlsProtocolVersion # 使用されたプロトコルバージョン
    cipherSuite*: TlsCipherSuite  # 使用された暗号スイート
    peerCertificates*: seq[Certificate]  # ピアの証明書チェーン
    sessionReused*: bool          # セッションが再利用されたかどうか
    serverName*: string           # SNI (Server Name Indication)
    alpnProtocol*: string         # ALPN (Application-Layer Protocol Negotiation)
    negotiatedExtensions*: Table[string, string]  # ネゴシエートされた拡張機能

  TlsConfig* = ref object
    minVersion*: TlsProtocolVersion     # 最小許容TLSバージョン
    maxVersion*: TlsProtocolVersion     # 最大許容TLSバージョン
    cipherSuites*: seq[TlsCipherSuite]  # 許可する暗号スイート
    verificationMode*: TlsVerificationMode  # 証明書検証モード
    sessionCache*: bool                 # セッションキャッシュを有効にするかどうか
    alpnProtocols*: seq[string]         # サポートするALPNプロトコル
    certificateStore*: Option[CertificateStore]  # 証明書ストア
    insecureFallback*: bool             # 安全でないフォールバックを許可するかどうか
    customOptions*: Table[string, string]  # カスタムオプション

# 推奨される暗号スイート
const RecommendedCipherSuites = [
  tcsAES_128_GCM_SHA256,
  tcsAES_256_GCM_SHA384,
  tcsCHACHA20_POLY1305_SHA256,
  tcsECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
  tcsECDHE_RSA_WITH_AES_128_GCM_SHA256,
  tcsECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
  tcsECDHE_RSA_WITH_AES_256_GCM_SHA384,
  tcsECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
  tcsECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
]

# レガシー暗号スイート（非推奨）
const LegacyCipherSuites = [
  tcsRSA_WITH_AES_128_CBC_SHA,
  tcsRSA_WITH_AES_256_CBC_SHA,
  tcsRSA_WITH_3DES_EDE_CBC_SHA
]

# デフォルトのALPNプロトコル
const DefaultAlpnProtocols = [
  "h2",     # HTTP/2
  "http/1.1"  # HTTP/1.1
]

# 新しいTLS設定を作成
proc newTlsConfig*(
  minVersion: TlsProtocolVersion = tlsTLS12,
  maxVersion: TlsProtocolVersion = tlsTLS13,
  cipherSuites: seq[TlsCipherSuite] = @RecommendedCipherSuites,
  verificationMode: TlsVerificationMode = tvmFull,
  sessionCache: bool = true,
  alpnProtocols: seq[string] = @DefaultAlpnProtocols,
  certificateStore: Option[CertificateStore] = none(CertificateStore),
  insecureFallback: bool = false
): TlsConfig =
  result = TlsConfig(
    minVersion: minVersion,
    maxVersion: maxVersion,
    cipherSuites: cipherSuites,
    verificationMode: verificationMode,
    sessionCache: sessionCache,
    alpnProtocols: alpnProtocols,
    certificateStore: certificateStore,
    insecureFallback: insecureFallback,
    customOptions: initTable[string, string]()
  )

# 近代的な設定を作成（最新のTLS 1.3と強力な暗号スイート）
proc newModernTlsConfig*(): TlsConfig =
  result = newTlsConfig(
    minVersion = tlsTLS12,
    maxVersion = tlsTLS13,
    cipherSuites = @[
      tcsAES_128_GCM_SHA256,
      tcsAES_256_GCM_SHA384,
      tcsCHACHA20_POLY1305_SHA256
    ],
    verificationMode = tvmFull,
    sessionCache = true,
    alpnProtocols = @DefaultAlpnProtocols
  )

# 互換性のある設定を作成（より広範な互換性のためのTLS 1.2と追加の暗号スイート）
proc newCompatibleTlsConfig*(): TlsConfig =
  result = newTlsConfig(
    minVersion = tlsTLS11,
    maxVersion = tlsTLS13,
    cipherSuites = @RecommendedCipherSuites,
    verificationMode = tvmFull,
    sessionCache = true,
    alpnProtocols = @DefaultAlpnProtocols
  )

# レガシー設定を作成（非常に古いシステムとの互換性のため、セキュリティは低下）
proc newLegacyTlsConfig*(): TlsConfig =
  result = newTlsConfig(
    minVersion = tlsTLS10,
    maxVersion = tlsTLS13,
    cipherSuites = concat(@RecommendedCipherSuites, @LegacyCipherSuites),
    verificationMode = tvmFull,
    sessionCache = true,
    alpnProtocols = @DefaultAlpnProtocols,
    insecureFallback = true
  )

# カスタムオプションを設定
proc setCustomOption*(config: TlsConfig, key: string, value: string) =
  config.customOptions[key] = value

# カスタムオプションを取得
proc getCustomOption*(config: TlsConfig, key: string): Option[string] =
  if config.customOptions.hasKey(key):
    return some(config.customOptions[key])
  return none(string)

# 暗号スイートを追加
proc addCipherSuite*(config: TlsConfig, cipherSuite: TlsCipherSuite) =
  if not config.cipherSuites.contains(cipherSuite):
    config.cipherSuites.add(cipherSuite)

# 暗号スイートを削除
proc removeCipherSuite*(config: TlsConfig, cipherSuite: TlsCipherSuite) =
  config.cipherSuites.keepIf(proc(cs: TlsCipherSuite): bool = cs != cipherSuite)

# ALPNプロトコルを追加
proc addAlpnProtocol*(config: TlsConfig, protocol: string) =
  if not config.alpnProtocols.contains(protocol):
    config.alpnProtocols.add(protocol)

# ALPNプロトコルを削除
proc removeAlpnProtocol*(config: TlsConfig, protocol: string) =
  config.alpnProtocols.keepIf(proc(p: string): bool = p != protocol)

# TLSプロトコルバージョンの文字列表現を取得
proc `$`*(version: TlsProtocolVersion): string =
  case version:
    of tlsSSL3: "SSL 3.0"
    of tlsTLS10: "TLS 1.0"
    of tlsTLS11: "TLS 1.1"
    of tlsTLS12: "TLS 1.2"
    of tlsTLS13: "TLS 1.3"
    of tlsUnknown: "Unknown TLS Version"

# TLS設定をJSON形式に変換
proc toJson*(config: TlsConfig): JsonNode =
  result = newJObject()
  result["minVersion"] = %($config.minVersion)
  result["maxVersion"] = %($config.maxVersion)
  
  var cipherSuitesArray = newJArray()
  for cs in config.cipherSuites:
    cipherSuitesArray.add(%($cs))
  result["cipherSuites"] = cipherSuitesArray
  
  result["verificationMode"] = %($config.verificationMode)
  result["sessionCache"] = %config.sessionCache
  
  var alpnArray = newJArray()
  for protocol in config.alpnProtocols:
    alpnArray.add(%protocol)
  result["alpnProtocols"] = alpnArray
  
  result["insecureFallback"] = %config.insecureFallback
  
  var customOptionsObj = newJObject()
  for key, value in config.customOptions:
    customOptionsObj[key] = %value
  result["customOptions"] = customOptionsObj

# TLSセッション情報をJSON形式に変換
proc toJson*(sessionInfo: TlsSessionInfo): JsonNode =
  result = newJObject()
  result["peerHostname"] = %sessionInfo.peerHostname
  result["protocol"] = %($sessionInfo.protocol)
  result["cipherSuite"] = %($sessionInfo.cipherSuite)
  result["sessionReused"] = %sessionInfo.sessionReused
  result["serverName"] = %sessionInfo.serverName
  result["alpnProtocol"] = %sessionInfo.alpnProtocol
  
  var certsArray = newJArray()
  for cert in sessionInfo.peerCertificates:
    certsArray.add(cert.toJson())
  result["peerCertificates"] = certsArray
  
  var extensionsObj = newJObject()
  for key, value in sessionInfo.negotiatedExtensions:
    extensionsObj[key] = %value
  result["negotiatedExtensions"] = extensionsObj

# TLS設定の評価とスコア付け（セキュリティレベルの評価）
proc evaluateSecurityLevel*(config: TlsConfig): tuple[score: int, comments: seq[string]] =
  var score = 100
  var comments: seq[string] = @[]
  
  # TLSバージョンの評価
  case config.minVersion:
    of tlsSSL3:
      score -= 40
      comments.add("SSL 3.0は重大な脆弱性があるため使用すべきではありません")
    of tlsTLS10:
      score -= 30
      comments.add("TLS 1.0は非推奨で、安全でないとされています")
    of tlsTLS11:
      score -= 20
      comments.add("TLS 1.1は非推奨です")
    of tlsTLS12:
      # TLS 1.2は許容される最小バージョン
      discard
    of tlsTLS13:
      # TLS 1.3は最新の安全なバージョン
      comments.add("TLS 1.3のみを使用する設定は最高のセキュリティを提供します")
    of tlsUnknown:
      score -= 50
      comments.add("不明なTLSバージョンが指定されています")
  
  # 暗号スイートの評価
  var hasLegacyCiphers = false
  var hasWeakCiphers = false
  
  for cs in config.cipherSuites:
    if cs in LegacyCipherSuites:
      hasLegacyCiphers = true
    
    # 特に弱い暗号スイートを検出
    if cs == tcsRSA_WITH_3DES_EDE_CBC_SHA:
      hasWeakCiphers = true
  
  if hasWeakCiphers:
    score -= 20
    comments.add("危険な弱い暗号スイートが含まれています")
  elif hasLegacyCiphers:
    score -= 10
    comments.add("レガシーな暗号スイートが含まれています")
  
  # 検証モードの評価
  case config.verificationMode:
    of tvmFull:
      # 完全検証は理想的
      discard
    of tvmSkipHostnameCheck:
      score -= 15
      comments.add("ホスト名検証をスキップするとMITM攻撃に脆弱になります")
    of tvmSkipCertificateCheck:
      score -= 40
      comments.add("証明書検証のスキップは重大なセキュリティリスクです")
    of tvmAcceptInvalidCert:
      score -= 50
      comments.add("無効な証明書を受け入れることは非常に危険です")
  
  # フォールバックの評価
  if config.insecureFallback:
    score -= 25
    comments.add("安全でないフォールバックが有効になっており、ダウングレード攻撃のリスクがあります")
  
  # 最終スコアの制限
  score = max(0, min(100, score))
  
  # スコアに基づいた総合コメント
  if score >= 90:
    comments.add("設定は非常に安全です")
  elif score >= 70:
    comments.add("設定は適切ですが、改善の余地があります")
  elif score >= 50:
    comments.add("設定にセキュリティの問題があります")
  else:
    comments.add("設定には重大なセキュリティリスクがあります")
  
  return (score, comments)

# 証明書ストアを設定
proc setCertificateStore*(config: TlsConfig, store: CertificateStore) =
  config.certificateStore = some(store)

# セッション情報を作成（デバッグおよび情報表示用）
proc newTlsSessionInfo*(
  peerHostname: string,
  protocol: TlsProtocolVersion,
  cipherSuite: TlsCipherSuite,
  peerCertificates: seq[Certificate] = @[],
  sessionReused: bool = false,
  serverName: string = "",
  alpnProtocol: string = ""
): TlsSessionInfo =
  result = TlsSessionInfo(
    peerHostname: peerHostname,
    protocol: protocol,
    cipherSuite: cipherSuite,
    peerCertificates: peerCertificates,
    sessionReused: sessionReused,
    serverName: serverName,
    alpnProtocol: alpnProtocol,
    negotiatedExtensions: initTable[string, string]()
  )

# 拡張機能を追加
proc addExtension*(session: var TlsSessionInfo, name: string, value: string) =
  session.negotiatedExtensions[name] = value