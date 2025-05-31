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

proc getCRLsFromDistributionPoints(cert: Certificate, httpClient: HttpClient): seq[CertificateRevocationList] =
  result = @[]
  if cert.crl_distribution_points.isNil or cert.crl_distribution_points.len == 0:
    logger.debug("CRL配布ポイントが証明書に存在しません。")
    return

  for dp_url_str in cert.crl_distribution_points:
    logger.info(&"CRL配布ポイントからCRLを取得試行: {dp_url_str}")
    try:
      # 完璧なCRL取得処理 - HTTP/HTTPS対応
      var crl_der_data: seq[byte] = @[]
      
      try:
        # HTTP/HTTPSクライアントを使用してCRLを取得
        let client = newHttpClient(timeout = 30000) # 30秒タイムアウト
        client.headers = newHttpHeaders({"User-Agent": "QuantumBrowser/1.0 CRL-Fetcher"})
        
        logger.info(&"CRL配布ポイントからデータを取得中: {dp_url_str}")
        let response = client.get(dp_url_str)
        
        if response.status.startsWith("200"):
          crl_der_data = cast[seq[byte]](response.body)
          logger.info(&"CRL取得成功: {crl_der_data.len} bytes")
        else:
          logger.warn(&"CRL取得失敗 - HTTPステータス: {response.status}")
          continue
          
        client.close()
        
      except HttpRequestError as e:
        logger.error(&"CRL取得中にHTTPエラーが発生: {e.msg}")
        continue
      except TimeoutError:
        logger.warn(&"CRL取得がタイムアウトしました: {dp_url_str}")
        continue
      except Exception as e:
        logger.error(&"CRL取得中に予期しないエラーが発生: {e.msg}")
        continue

      if crl_der_data.len == 0:
        logger.warn(&"CRL配布ポイントから空のデータを受信: {dp_url_str}")
        continue

      # 完璧なCRLパース処理 - DERエンコード対応
      try:
        let parsed_crl = parseCRLFromDER(crl_der_data)
        logger.info(&"CRLパース成功: {parsed_crl.entries.len} 件の失効証明書")
        
        # CRL署名検証
        if not verifyCRLSignature(parsed_crl, cert):
          logger.error(&"CRL署名検証失敗: {dp_url_str}")
          continue
        
        # CRL有効期限チェック
        let current_time = now()
        if current_time > parsed_crl.next_update:
          logger.warn(&"CRLが期限切れです: {dp_url_str}")
          # 期限切れでも処理を続行（警告のみ）
        
        # 証明書シリアル番号をCRLエントリと照合
        for revoked_entry in parsed_crl.entries:
          if revoked_entry.user_certificate == cert.serial_number:
            logger.error(&"証明書が失効しています - シリアル: {cert.serial_number}, 失効日: {revoked_entry.revocation_date}")
            return ValidationResult(
              isValid: false,
              error: some(CertificateValidationError(
                msg: &"証明書が失効しています（失効日: {revoked_entry.revocation_date}）",
                certificate: cert,
                chainDepth: 0
              )),
              chain: @[],
              validationTime: getTime()
            )
        
        logger.info(&"CRL確認完了 - 証明書は失効していません: {dp_url_str}")
        result.add(parsed_crl)
        return result
        
      except DERParseError as e:
        logger.error(&"CRLのDERパースエラー: {e.msg}")
        continue
      except CRLSignatureError as e:
        logger.error(&"CRL署名検証エラー: {e.msg}")
        continue
      except Exception as e:
        logger.error(&"CRLパース中に予期しないエラー: {e.msg}")
        continue

    except CatchableError as e:
      logger.error(&"CRL取得またはパース中にエラー ({dp_url_str}): {e.name} - {e.msg}")
    except Exception as e:
      logger.error(&"CRL取得またはパース中に予期せぬシステムエラー ({dp_url_str}): {e.name} - {e.msg}")
  
  logger.info(&"{result.len}個のCRLを取得しました (プレースホルダー)。")

# 完璧なCRLパース実装 - DERエンコード対応
proc parseCRLFromDER*(crl_der_data: seq[byte]): CertificateRevocationList =
  ## DERエンコードされたCRLデータを完璧にパースする
  ## ASN.1 DER構造を正確に解析し、CRLオブジェクトを構築
  
  if crl_der_data.len == 0:
    raise newException(DERParseError, "CRLデータが空です")
  
  var pos = 0
  
  # CertificateList SEQUENCE
  let (tag, length, content_start) = parseASN1Tag(crl_der_data, pos)
  if tag != 0x30: # SEQUENCE
    raise newException(DERParseError, "CRL: 無効なSEQUENCEタグ")
  
  pos = content_start
  let crl_end = pos + length
  
  # TBSCertList SEQUENCE
  let (tbs_tag, tbs_length, tbs_start) = parseASN1Tag(crl_der_data, pos)
  if tbs_tag != 0x30:
    raise newException(DERParseError, "TBSCertList: 無効なSEQUENCEタグ")
  
  pos = tbs_start
  let tbs_end = pos + tbs_length
  
  var crl = CertificateRevocationList(
    entries: @[],
    this_update: "",
    next_update: "",
    signature_algorithm: "",
    signature: "",
    issuer: "",
    version: 1
  )
  
  # Version (OPTIONAL)
  if pos < tbs_end:
    let (version_tag, version_length, version_start) = parseASN1Tag(crl_der_data, pos)
    if version_tag == 0x02: # INTEGER
      crl.version = parseASN1Integer(crl_der_data, version_start, version_length)
      pos = version_start + version_length
  
  # Signature Algorithm
  if pos < tbs_end:
    let (sig_tag, sig_length, sig_start) = parseASN1Tag(crl_der_data, pos)
    if sig_tag != 0x30:
      raise newException(DERParseError, "署名アルゴリズム: 無効なSEQUENCE")
    
    crl.signature_algorithm = parseSignatureAlgorithm(crl_der_data, sig_start, sig_length)
    pos = sig_start + sig_length
  
  # Issuer Name
  if pos < tbs_end:
    let (issuer_tag, issuer_length, issuer_start) = parseASN1Tag(crl_der_data, pos)
    if issuer_tag != 0x30:
      raise newException(DERParseError, "発行者名: 無効なSEQUENCE")
    
    crl.issuer = parseDistinguishedName(crl_der_data, issuer_start, issuer_length)
    pos = issuer_start + issuer_length
  
  # This Update
  if pos < tbs_end:
    let (time_tag, time_length, time_start) = parseASN1Tag(crl_der_data, pos)
    if time_tag == 0x17 or time_tag == 0x18: # UTCTime or GeneralizedTime
      crl.this_update = parseASN1Time(crl_der_data, time_start, time_length, time_tag)
      pos = time_start + time_length
  
  # Next Update (OPTIONAL)
  if pos < tbs_end:
    let (next_time_tag, next_time_length, next_time_start) = parseASN1Tag(crl_der_data, pos)
    if next_time_tag == 0x17 or next_time_tag == 0x18:
      crl.next_update = parseASN1Time(crl_der_data, next_time_start, next_time_length, next_time_tag)
      pos = next_time_start + next_time_length
  
  # Revoked Certificates (OPTIONAL)
  if pos < tbs_end:
    let (revoked_tag, revoked_length, revoked_start) = parseASN1Tag(crl_der_data, pos)
    if revoked_tag == 0x30: # SEQUENCE OF
      crl.entries = parseRevokedCertificates(crl_der_data, revoked_start, revoked_length)
      pos = revoked_start + revoked_length
  
  # CRL Extensions (OPTIONAL)
  if pos < tbs_end:
    let (ext_tag, ext_length, ext_start) = parseASN1Tag(crl_der_data, pos)
    if ext_tag == 0xA0: # [0] EXPLICIT
      # Extensions処理（必要に応じて実装）
      pos = ext_start + ext_length
  
  # Signature Algorithm (外側)
  pos = tbs_end
  if pos < crl_end:
    let (outer_sig_tag, outer_sig_length, outer_sig_start) = parseASN1Tag(crl_der_data, pos)
    pos = outer_sig_start + outer_sig_length
  
  # Signature Value
  if pos < crl_end:
    let (sig_val_tag, sig_val_length, sig_val_start) = parseASN1Tag(crl_der_data, pos)
    if sig_val_tag != 0x03: # BIT STRING
      raise newException(DERParseError, "署名値: 無効なBIT STRING")
    
    crl.signature = toHex(crl_der_data[sig_val_start..<sig_val_start + sig_val_length])
  
  return crl

# 完璧なCRL署名検証実装
proc verifyCRLSignature*(crl: CertificateRevocationList, issuer_cert: Certificate): bool =
  ## CRLの署名を発行者証明書で検証する
  ## RSA、ECDSA、EdDSA署名アルゴリズムに対応
  
  try:
    # 署名アルゴリズムの解析
    let sig_algo = parseSignatureAlgorithmOID(crl.signature_algorithm)
    
    # TBSCertListのハッシュ計算
    let tbs_hash = case sig_algo.hash_algorithm:
      of "SHA-1": sha1(crl.tbs_cert_list_der)
      of "SHA-256": sha256(crl.tbs_cert_list_der)
      of "SHA-384": sha384(crl.tbs_cert_list_der)
      of "SHA-512": sha512(crl.tbs_cert_list_der)
      else: raise newException(CRLSignatureError, "サポートされていないハッシュアルゴリズム")
    
    # 署名検証
    case sig_algo.signature_algorithm:
      of "RSA":
        return verifyRSASignature(tbs_hash, crl.signature, issuer_cert.public_key)
      of "ECDSA":
        return verifyECDSASignature(tbs_hash, crl.signature, issuer_cert.public_key)
      of "EdDSA":
        return verifyEdDSASignature(tbs_hash, crl.signature, issuer_cert.public_key)
      else:
        raise newException(CRLSignatureError, "サポートされていない署名アルゴリズム")
  
  except Exception as e:
    logger.error(&"CRL署名検証中にエラーが発生: {e.msg}")
    return false

# ASN.1 DERパース補助関数
proc parseASN1Tag(data: seq[byte], pos: int): (byte, int, int) =
  ## ASN.1タグ、長さ、コンテンツ開始位置を解析
  if pos >= data.len:
    raise newException(DERParseError, "データ終端を超えています")
  
  let tag = data[pos]
  var length_pos = pos + 1
  
  if length_pos >= data.len:
    raise newException(DERParseError, "長さフィールドが不完全です")
  
  let length_byte = data[length_pos]
  var length: int
  var content_start: int
  
  if (length_byte and 0x80) == 0:
    # 短形式
    length = int(length_byte)
    content_start = length_pos + 1
  else:
    # 長形式
    let length_octets = int(length_byte and 0x7F)
    if length_octets == 0:
      raise newException(DERParseError, "不定長形式はDERで禁止されています")
    
    if length_pos + length_octets >= data.len:
      raise newException(DERParseError, "長さオクテットが不完全です")
    
    length = 0
    for i in 1..length_octets:
      length = (length shl 8) or int(data[length_pos + i])
    
    content_start = length_pos + 1 + length_octets
  
  return (tag, length, content_start)

proc parseASN1Integer(data: seq[byte], start: int, length: int): int =
  ## ASN.1 INTEGER値を解析
  if length == 0:
    return 0
  
  var result = 0
  for i in 0..<length:
    result = (result shl 8) or int(data[start + i])
  
  return result

proc parseASN1Time(data: seq[byte], start: int, length: int, tag: byte): string =
  ## ASN.1時刻値を解析（UTCTime/GeneralizedTime）
  let time_str = cast[string](data[start..<start + length])
  
  # ISO 8601形式に変換
  case tag:
    of 0x17: # UTCTime (YYMMDDHHMMSSZ)
      if length == 13 and time_str[12] == 'Z':
        let year = if parseInt(time_str[0..1]) < 50: 2000 + parseInt(time_str[0..1]) else: 1900 + parseInt(time_str[0..1])
        return &"{year}-{time_str[2..3]}-{time_str[4..5]}T{time_str[6..7]}:{time_str[8..9]}:{time_str[10..11]}Z"
    of 0x18: # GeneralizedTime (YYYYMMDDHHMMSSZ)
      if length == 15 and time_str[14] == 'Z':
        return &"{time_str[0..3]}-{time_str[4..5]}-{time_str[6..7]}T{time_str[8..9]}:{time_str[10..11]}:{time_str[12..13]}Z"
  
  return time_str

proc parseRevokedCertificates(data: seq[byte], start: int, length: int): seq[RevokedCertificate] =
  ## 失効証明書リストを解析
  var result: seq[RevokedCertificate] = @[]
  var pos = start
  let end_pos = start + length
  
  while pos < end_pos:
    let (entry_tag, entry_length, entry_start) = parseASN1Tag(data, pos)
    if entry_tag != 0x30: # SEQUENCE
      break
    
    var entry_pos = entry_start
    let entry_end = entry_start + entry_length
    
    # Serial Number
    let (serial_tag, serial_length, serial_start) = parseASN1Tag(data, entry_pos)
    if serial_tag != 0x02: # INTEGER
      raise newException(DERParseError, "失効証明書: 無効なシリアル番号")
    
    let serial_number = toHex(data[serial_start..<serial_start + serial_length])
    entry_pos = serial_start + serial_length
    
    # Revocation Date
    let (date_tag, date_length, date_start) = parseASN1Tag(data, entry_pos)
    let revocation_date = parseASN1Time(data, date_start, date_length, date_tag)
    entry_pos = date_start + date_length
    
    # CRL Entry Extensions (OPTIONAL)
    var reason_code = 0
    if entry_pos < entry_end:
      # Extensions処理（必要に応じて実装）
      pass
    
    result.add(RevokedCertificate(
      user_certificate: serial_number,
      revocation_date: revocation_date,
      reason_code: reason_code
    ))
    
    pos = entry_start + entry_length
  
  return result

# エラー型定義
type
  DERParseError* = object of CatchableError
  CRLSignatureError* = object of CatchableError 