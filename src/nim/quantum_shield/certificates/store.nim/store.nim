import std/[asyncdispatch, openssl, os, options, tables, times, json]
import ../../../utils/[logging, errors]

type
  CertificateStoreError* = object of CatchableError
    code*: int
    details*: string

  CertificateMetadata* = object
    fingerprint*: string
    subject*: string
    issuer*: string
    notBefore*: Time
    notAfter*: Time
    serialNumber*: string
    isRoot*: bool
    isTrusted*: bool
    lastVerified*: Time
    revocationStatus*: RevocationStatus

  RevocationStatus* = enum
    rsUnknown
    rsGood
    rsRevoked
    rsExpired

  CertificateStore* = ref object
    storePath*: string
    trustedCerts*: Table[string, X509]
    intermediateCerts*: Table[string, X509]
    metadata*: Table[string, CertificateMetadata]
    logger: Logger
    crlCache*: Table[string, CRL]
    ocspCache*: Table[string, OCSPResponse]

proc newCertificateStore*(storePath: string): CertificateStore =
  result = CertificateStore(
    storePath: storePath,
    trustedCerts: initTable[string, X509](),
    intermediateCerts: initTable[string, X509](),
    metadata: initTable[string, CertificateMetadata](),
    logger: newLogger("CertificateStore"),
    crlCache: initTable[string, CRL](),
    ocspCache: initTable[string, OCSPResponse]()
  )
  discard existsOrCreateDir(storePath)

proc loadCertificate(path: string): X509 =
  let data = readFile(path)
  result = data.loadX509()

proc getFingerprint*(cert: X509): string =
  cert.getFingerprint(HashType.sha256)

proc loadTrustedCertificates*(store: CertificateStore) {.async.} =
  let trustedPath = store.storePath / "trusted"
  discard existsOrCreateDir(trustedPath)
  
  for file in walkFiles(trustedPath / "*.pem"):
    try:
      let cert = loadCertificate(file)
      let fp = cert.getFingerprint()
      store.trustedCerts[fp] = cert
      
      store.metadata[fp] = CertificateMetadata(
        fingerprint: fp,
        subject: cert.getSubjectName().getString(),
        issuer: cert.getIssuerName().getString(),
        notBefore: cert.getNotBefore(),
        notAfter: cert.getNotAfter(),
        serialNumber: cert.getSerialNumber(),
        isRoot: cert.isSelfSigned(),
        isTrusted: true,
        lastVerified: getTime(),
        revocationStatus: rsUnknown
      )
      
    except:
      store.logger.error("信頼された証明書の読み込みに失敗しました: " & getCurrentExceptionMsg())

proc loadIntermediateCertificates*(store: CertificateStore) {.async.} =
  let intermediatePath = store.storePath / "intermediate"
  discard existsOrCreateDir(intermediatePath)
  
  for file in walkFiles(intermediatePath / "*.pem"):
    try:
      let cert = loadCertificate(file)
      let fp = cert.getFingerprint()
      store.intermediateCerts[fp] = cert
      
      store.metadata[fp] = CertificateMetadata(
        fingerprint: fp,
        subject: cert.getSubjectName().getString(),
        issuer: cert.getIssuerName().getString(),
        notBefore: cert.getNotBefore(),
        notAfter: cert.getNotAfter(),
        serialNumber: cert.getSerialNumber(),
        isRoot: false,
        isTrusted: false,
        lastVerified: getTime(),
        revocationStatus: rsUnknown
      )
      
    except:
      store.logger.error("中間証明書の読み込みに失敗しました: " & getCurrentExceptionMsg())

proc findIssuerCertificate*(store: CertificateStore, cert: X509): Option[X509] =
  # 発行者の証明書を探す
  let issuerName = cert.getIssuerName().getString()
  
  # まず信頼された証明書から探す
  for trustedCert in store.trustedCerts.values:
    if trustedCert.getSubjectName().getString() == issuerName:
      return some(trustedCert)
  
  # 次に中間証明書から探す
  for intermediateCert in store.intermediateCerts.values:
    if intermediateCert.getSubjectName().getString() == issuerName:
      return some(intermediateCert)
  
  return none(X509)

proc addTrustedCertificate*(store: CertificateStore, cert: X509) {.async.} =
  try:
    let fp = cert.getFingerprint()
    let path = store.storePath / "trusted" / (fp & ".pem")
    writeFile(path, cert.toString())
    
    store.trustedCerts[fp] = cert
    store.metadata[fp] = CertificateMetadata(
      fingerprint: fp,
      subject: cert.getSubjectName().getString(),
      issuer: cert.getIssuerName().getString(),
      notBefore: cert.getNotBefore(),
      notAfter: cert.getNotAfter(),
      serialNumber: cert.getSerialNumber(),
      isRoot: cert.isSelfSigned(),
      isTrusted: true,
      lastVerified: getTime(),
      revocationStatus: rsUnknown
    )
    
  except:
    raise newException(CertificateStoreError, "信頼された証明書の追加に失敗しました: " & getCurrentExceptionMsg())

proc addIntermediateCertificate*(store: CertificateStore, cert: X509) {.async.} =
  try:
    let fp = cert.getFingerprint()
    let path = store.storePath / "intermediate" / (fp & ".pem")
    writeFile(path, cert.toString())
    
    store.intermediateCerts[fp] = cert
    store.metadata[fp] = CertificateMetadata(
      fingerprint: fp,
      subject: cert.getSubjectName().getString(),
      issuer: cert.getIssuerName().getString(),
      notBefore: cert.getNotBefore(),
      notAfter: cert.getNotAfter(),
      serialNumber: cert.getSerialNumber(),
      isRoot: false,
      isTrusted: false,
      lastVerified: getTime(),
      revocationStatus: rsUnknown
    )
    
  except:
    raise newException(CertificateStoreError, "中間証明書の追加に失敗しました: " & getCurrentExceptionMsg())

proc removeCertificate*(store: CertificateStore, fingerprint: string) {.async.} =
  try:
    if fingerprint in store.trustedCerts:
      let path = store.storePath / "trusted" / (fingerprint & ".pem")
      removeFile(path)
      store.trustedCerts.del(fingerprint)
      store.metadata.del(fingerprint)
      
    elif fingerprint in store.intermediateCerts:
      let path = store.storePath / "intermediate" / (fingerprint & ".pem")
      removeFile(path)
      store.intermediateCerts.del(fingerprint)
      store.metadata.del(fingerprint)
      
  except:
    raise newException(CertificateStoreError, "証明書の削除に失敗しました: " & getCurrentExceptionMsg())

proc isRevoked*(store: CertificateStore, cert: X509): Future[bool] {.async.} =
  try:
    let fp = cert.getFingerprint()
    
    # メタデータから失効状態を確認
    if fp in store.metadata:
      case store.metadata[fp].revocationStatus
      of rsGood: return false
      of rsRevoked: return true
      else: discard
    
    # CRLによる確認
    if cert.hasCrlDistributionPoints():
      for url in cert.getCrlDistributionPoints():
        if url in store.crlCache:
          let crl = store.crlCache[url]
          if not crl.isExpired():
            return cert.isRevokedByCRL(crl)
    
    # OCSPによる確認
    if cert.hasAuthorityInfoAccess():
      for url in cert.getOcspResponders():
        if url in store.ocspCache:
          let resp = store.ocspCache[url]
          if not resp.isExpired():
            return resp.isRevoked(cert)
    
    return false
    
  except:
    store.logger.error("失効確認に失敗しました: " & getCurrentExceptionMsg())
    return false

proc updateRevocationStatus*(store: CertificateStore, cert: X509, status: RevocationStatus) {.async.} =
  let fp = cert.getFingerprint()
  if fp in store.metadata:
    store.metadata[fp].revocationStatus = status
    store.metadata[fp].lastVerified = getTime()

proc saveMetadata*(store: CertificateStore) {.async.} =
  try:
    var data = newJObject()
    for fp, meta in store.metadata:
      data[fp] = %*{
        "fingerprint": meta.fingerprint,
        "subject": meta.subject,
        "issuer": meta.issuer,
        "notBefore": meta.notBefore.toUnix,
        "notAfter": meta.notAfter.toUnix,
        "serialNumber": meta.serialNumber,
        "isRoot": meta.isRoot,
        "isTrusted": meta.isTrusted,
        "lastVerified": meta.lastVerified.toUnix,
        "revocationStatus": $meta.revocationStatus
      }
    
    writeFile(store.storePath / "metadata.json", $data)
    
  except:
    store.logger.error("メタデータの保存に失敗しました: " & getCurrentExceptionMsg())

proc loadMetadata*(store: CertificateStore) {.async.} =
  try:
    let path = store.storePath / "metadata.json"
    if fileExists(path):
      let data = parseJson(readFile(path))
      for fp, jMeta in data:
        store.metadata[fp] = CertificateMetadata(
          fingerprint: jMeta["fingerprint"].getStr,
          subject: jMeta["subject"].getStr,
          issuer: jMeta["issuer"].getStr,
          notBefore: fromUnix(jMeta["notBefore"].getBiggestInt),
          notAfter: fromUnix(jMeta["notAfter"].getBiggestInt),
          serialNumber: jMeta["serialNumber"].getStr,
          isRoot: jMeta["isRoot"].getBool,
          isTrusted: jMeta["isTrusted"].getBool,
          lastVerified: fromUnix(jMeta["lastVerified"].getBiggestInt),
          revocationStatus: parseEnum[RevocationStatus](jMeta["revocationStatus"].getStr)
        )
        
  except:
    store.logger.error("メタデータの読み込みに失敗しました: " & getCurrentExceptionMsg()) 