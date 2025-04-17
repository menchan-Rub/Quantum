import std/[asyncdispatch, openssl, times, strutils, sequtils, options, sets, uri]
import ../../../utils/[logging, errors]
import ./store

type
  CertificateValidationError* = object of CatchableError
    code*: int
    details*: string
    certificate*: X509     # エラーが発生した証明書
    chainDepth*: int      # チェーン内での位置

  ValidationResult* = object
    isValid*: bool
    error*: Option[CertificateValidationError]
    chain*: seq[X509]
    validationTime*: Time
    expiresAt*: Time

  CertificateValidator* = ref object
    store*: CertificateStore
    maxChainDepth*: int
    allowSelfSigned*: bool
    checkRevocation*: bool
    strictMode*: bool
    logger: Logger
    trustedFingerprints*: HashSet[string]  # 明示的に信頼された証明書のフィンガープリント
    blockedFingerprints*: HashSet[string]  # 明示的にブロックされた証明書のフィンガープリント
    allowedKeyUsages*: set[KeyUsage]       # 許可されたキー使用法
    minRsaKeySize*: int                    # 最小RSA鍵長
    minEcdsaKeySize*: int                  # 最小ECDSA鍵長
    allowedSignatureAlgorithms*: HashSet[string]  # 許可された署名アルゴリズム

const
  DefaultMaxChainDepth = 10
  DefaultAllowSelfSigned = false 
  DefaultCheckRevocation = true
  DefaultStrictMode = true
  DefaultMinRsaKeySize = 2048
  DefaultMinEcdsaKeySize = 256

  # デフォルトで許可する署名アルゴリズム
  DefaultAllowedSignatureAlgorithms = [
    "sha256WithRSAEncryption",
    "sha384WithRSAEncryption",
    "sha512WithRSAEncryption",
    "ecdsa-with-SHA256",
    "ecdsa-with-SHA384",
    "ecdsa-with-SHA512"
  ]

proc newCertificateValidator*(store: CertificateStore, 
                            maxChainDepth = DefaultMaxChainDepth,
                            allowSelfSigned = DefaultAllowSelfSigned,
                            checkRevocation = DefaultCheckRevocation, 
                            strictMode = DefaultStrictMode): CertificateValidator =
  result = CertificateValidator(
    store: store,
    maxChainDepth: maxChainDepth,
    allowSelfSigned: allowSelfSigned, 
    checkRevocation: checkRevocation,
    strictMode: strictMode,
    logger: newLogger("CertificateValidator"),
    trustedFingerprints: initHashSet[string](),
    blockedFingerprints: initHashSet[string](),
    allowedKeyUsages: {KeyUsage.digitalSignature, KeyUsage.keyEncipherment},
    minRsaKeySize: DefaultMinRsaKeySize,
    minEcdsaKeySize: DefaultMinEcdsaKeySize,
    allowedSignatureAlgorithms: toHashSet(DefaultAllowedSignatureAlgorithms)
  )

proc validateKeyStrength(v: CertificateValidator, cert: X509): bool =
  let key = cert.pubKey
  case key.kind
  of KeyKind.rsaKey:
    let bits = key.getRsaBits()
    result = bits >= v.minRsaKeySize
  of KeyKind.ecKey:
    let bits = key.getEcBits()
    result = bits >= v.minEcdsaKeySize
  else:
    result = false

proc validateKeyUsage(v: CertificateValidator, cert: X509): bool =
  let usage = cert.getKeyUsage()
  result = (usage * v.allowedKeyUsages).len > 0

proc validateExtendedKeyUsage(v: CertificateValidator, cert: X509, required: set[ExtKeyUsage]): bool =
  let extUsage = cert.getExtendedKeyUsage()
  result = (extUsage * required).len == required.len

proc validateSignatureAlgorithm(v: CertificateValidator, cert: X509): bool =
  let sigAlg = cert.getSignatureAlgorithm()
  result = sigAlg in v.allowedSignatureAlgorithms

proc validateBasicConstraints(v: CertificateValidator, cert: X509, isCA: bool): bool =
  let constraints = cert.getBasicConstraints()
  if isCA:
    result = constraints.isCA and constraints.pathLenConstraint >= 0
  else:
    result = not constraints.isCA

proc validateCertificatePolicy(v: CertificateValidator, cert: X509): bool =
  let policies = cert.getCertificatePolicies()
  result = policies.len > 0 or not v.strictMode

proc validateNameConstraints(v: CertificateValidator, cert: X509, hostname: string): bool =
  let constraints = cert.getNameConstraints()
  if constraints.permitted.len > 0:
    var allowed = false
    for pattern in constraints.permitted:
      if hostname.matchesPattern(pattern):
        allowed = true
        break
    if not allowed:
      return false
  
  for pattern in constraints.excluded:
    if hostname.matchesPattern(pattern):
      return false
  
  return true

proc validateCertificate*(v: CertificateValidator, cert: X509): Future[ValidationResult] {.async.} =
  var result = ValidationResult(
    isValid: false,
    error: none(CertificateValidationError),
    chain: @[],
    validationTime: getTime(),
    expiresAt: cert.getNotAfter()
  )

  try:
    # 基本的な証明書の検証
    if cert.isNil:
      raise newException(CertificateValidationError, "証明書がnilです")

    # フィンガープリントによるチェック
    let fp = cert.getFingerprint()
    if fp in v.blockedFingerprints:
      raise newException(CertificateValidationError, "証明書はブロックリストに含まれています")

    # 有効期限の確認
    let now = result.validationTime
    let notBefore = cert.getNotBefore()
    let notAfter = cert.getNotAfter()

    if now < notBefore:
      raise newException(CertificateValidationError, "証明書はまだ有効期間前です")
    if now > notAfter:
      raise newException(CertificateValidationError, "証明書は有効期限切れです")

    # 鍵強度の確認
    if not v.validateKeyStrength(cert):
      raise newException(CertificateValidationError, "鍵の強度が不十分です")

    # 署名アルゴリズムの確認
    if not v.validateSignatureAlgorithm(cert):
      raise newException(CertificateValidationError, "署名アルゴリズムが許可されていません")

    # 自己署名証明書の確認
    if cert.isSelfSigned():
      if not v.allowSelfSigned:
        raise newException(CertificateValidationError, "自己署名証明書は許可されていません")
      if fp notin v.trustedFingerprints:
        raise newException(CertificateValidationError, "自己署名証明書は信頼されていません")
      result.chain = @[cert]
      result.isValid = true
      return result

    # 証明書チェーンの検証
    var chain = @[cert]
    var current = cert
    var depth = 0
    
    while depth < v.maxChainDepth:
      # 発行者証明書を取得
      let issuerCert = v.store.findIssuerCertificate(current)
      if issuerCert.isNone:
        if v.strictMode:
          raise newException(CertificateValidationError, 
            "発行者証明書が見つかりません", 
            certificate: current,
            chainDepth: depth)
        break
      
      current = issuerCert.get()
      
      # 発行者証明書の基本的な検証
      if not v.validateKeyStrength(current):
        raise newException(CertificateValidationError, 
          "発行者証明書の鍵強度が不十分です",
          certificate: current,
          chainDepth: depth + 1)
          
      if not v.validateSignatureAlgorithm(current):
        raise newException(CertificateValidationError,
          "発行者証明書の署名アルゴリズムが許可されていません",
          certificate: current,
          chainDepth: depth + 1)
          
      if not v.validateBasicConstraints(current, true):
        raise newException(CertificateValidationError,
          "発行者証明書のBasic Constraintsが不正です",
          certificate: current,
          chainDepth: depth + 1)
      
      chain.add(current)
      
      if current.isSelfSigned():
        if current.getFingerprint() in v.trustedFingerprints:
          break
        elif v.strictMode:
          raise newException(CertificateValidationError,
            "ルート証明書が信頼されていません",
            certificate: current,
            chainDepth: depth + 1)
        break
        
      depth.inc

    if depth >= v.maxChainDepth:
      raise newException(CertificateValidationError, 
        "証明書チェーンが長すぎます",
        certificate: current,
        chainDepth: depth)

    # 署名の検証
    for i in 0..chain.high-1:
      if not chain[i].verify(chain[i+1].pubKey):
        raise newException(CertificateValidationError,
          "署名の検証に失敗しました",
          certificate: chain[i],
          chainDepth: i)

    # 失効確認
    if v.checkRevocation:
      for i, cert in chain:
        if await v.store.isRevoked(cert):
          raise newException(CertificateValidationError,
            "証明書は失効しています",
            certificate: cert,
            chainDepth: i)

    result.chain = chain
    result.isValid = true
    return result

  except CertificateValidationError as e:
    result.error = some(e)
    return result
  except:
    let e = newException(CertificateValidationError,
      "予期せぬエラーが発生しました: " & getCurrentExceptionMsg())
    result.error = some(e)
    v.logger.error(e.msg)
    return result

proc validateHostname*(v: CertificateValidator, cert: X509, hostname: string): bool =
  try:
    # ホスト名の正規化
    var normalizedHostname = hostname.toLowerAscii()
    if hostname.startsWith("xn--"):
      normalizedHostname = hostname.idnToUnicode()

    # Common Name の確認
    let cn = cert.getSubjectName().getCommonName()
    if cn == normalizedHostname:
      return true

    # Subject Alternative Names の確認
    let sans = cert.getSubjectAltNames()
    for san in sans:
      case san.kind
      of GeneralName_DNS:
        var sanValue = san.value.toLowerAscii()
        if sanValue == normalizedHostname:
          return true
        # ワイルドカード証明書の確認
        if sanValue.startsWith("*."):
          let domain = sanValue[2..^1]
          let parts = normalizedHostname.split('.')
          if parts.len >= 2 and parts[1..^1].join(".") == domain:
            return true
      
      of GeneralName_iPAddress:
        if san.value == normalizedHostname:
          return true
          
      else: discard

    # 名前制約の確認
    if not v.validateNameConstraints(cert, normalizedHostname):
      return false

    return false

  except:
    v.logger.error("ホスト名の検証に失敗しました: " & getCurrentExceptionMsg())
    return false

proc validateCertificateChain*(v: CertificateValidator, chain: seq[X509]): Future[ValidationResult] {.async.} =
  if chain.len == 0:
    return ValidationResult(
      isValid: false,
      error: some(CertificateValidationError(msg: "証明書チェーンが空です")),
      validationTime: getTime()
    )

  let result = await v.validateCertificate(chain[0])
  if not result.isValid:
    return result

  # チェーンの順序を確認
  for i in 0..chain.high-1:
    if not chain[i].verify(chain[i+1].pubKey):
      return ValidationResult(
        isValid: false,
        error: some(CertificateValidationError(
          msg: "証明書チェーンの順序が不正です",
          certificate: chain[i],
          chainDepth: i
        )),
        chain: chain,
        validationTime: getTime()
      )

  return result

proc addTrustedFingerprint*(v: CertificateValidator, fingerprint: string) =
  v.trustedFingerprints.incl(fingerprint)

proc removeTrustedFingerprint*(v: CertificateValidator, fingerprint: string) =
  v.trustedFingerprints.excl(fingerprint)

proc addBlockedFingerprint*(v: CertificateValidator, fingerprint: string) =
  v.blockedFingerprints.incl(fingerprint)

proc removeBlockedFingerprint*(v: CertificateValidator, fingerprint: string) =
  v.blockedFingerprints.excl(fingerprint)

proc setAllowedKeyUsages*(v: CertificateValidator, usages: set[KeyUsage]) =
  v.allowedKeyUsages = usages

proc setMinKeySize*(v: CertificateValidator, rsaSize: int, ecdsaSize: int) =
  v.minRsaKeySize = rsaSize
  v.minEcdsaKeySize = ecdsaSize

proc setAllowedSignatureAlgorithms*(v: CertificateValidator, algorithms: HashSet[string]) =
  v.allowedSignatureAlgorithms = algorithms 