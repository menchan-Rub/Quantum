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
        else:
          # CRLがキャッシュになければ取得を試みる
          try:
            let client = newAsyncHttpClient()
            let response = await client.get(url)
            
            if response.code == 200:
              let crlData = await response.body
              let crl = loadCRL(crlData)
              
              # キャッシュに保存
              store.crlCache[url] = crl
              
              # 失効確認
              let revoked = cert.isRevokedByCRL(crl)
              if revoked:
                await store.updateRevocationStatus(cert, rsRevoked)
                return true
          except:
            store.logger.error("CRLの取得に失敗しました: " & url & " - " & getCurrentExceptionMsg())
    
    # OCSPによる確認
    if cert.hasAuthorityInfoAccess():
      for url in cert.getOcspResponders():
        if url in store.ocspCache:
          let resp = store.ocspCache[url]
          if not resp.isExpired():
            return resp.isRevoked(cert)
        else:
          # OCSPレスポンスがキャッシュになければ取得を試みる
          try:
            # 発行者証明書を特定
            let issuerCertOpt = store.findIssuerCertificate(cert)
            if issuerCertOpt.isNone:
              store.logger.error("発行者証明書が見つかりません")
              continue
              
            let issuerCert = issuerCertOpt.get()
            
            # OCSP要求を作成
            let ocspReq = createOcspRequest(cert, issuerCert)
            let encodedReq = ocspReq.encode()
            
            # HTTP POSTでOCSPリクエスト送信
            let client = newAsyncHttpClient()
            client.headers = newHttpHeaders({
              "Content-Type": "application/ocsp-request",
              "Accept": "application/ocsp-response"
            })
            
            let response = await client.post(url, encodedReq)
            
            if response.code == 200:
              let ocspData = await response.body
              
              # OCSPレスポンスを解析
              let ocspResponse = parseOcspResponse(ocspData)
              
              # キャッシュに保存（有効期限に応じて）
              store.ocspCache[url] = ocspResponse
              
              # 証明書の失効状態を更新
              if ocspResponse.status == OCSP_STATUS_SUCCESSFUL:
                let certStatus = ocspResponse.getCertStatus(cert, issuerCert)
                
                case certStatus
                of OCSP_CERT_GOOD:
                  await store.updateRevocationStatus(cert, rsGood)
                  return false
                of OCSP_CERT_REVOKED:
                  await store.updateRevocationStatus(cert, rsRevoked)
                  return true
                else:
                  await store.updateRevocationStatus(cert, rsUnknown)
          except:
            store.logger.error("OCSPの確認に失敗しました: " & url & " - " & getCurrentExceptionMsg())
    
    # 証明書の有効期限を確認
    let now = getTime()
    if cert.getNotBefore() > now or cert.getNotAfter() < now:
      await store.updateRevocationStatus(cert, rsExpired)
      return true
    
    # 失効が確認できなかった場合は有効と判断
    await store.updateRevocationStatus(cert, rsGood)
    return false
    
  except:
    store.logger.error("失効確認に失敗しました: " & getCurrentExceptionMsg())
    return false

# CRLを読み込む
proc loadCRL(data: string): CRL =
  let bio = bioNew(BIO_s_mem())
  discard bio.bioWrite(data.cstring, data.len)
  result = d2i_X509_CRL_bio(bio, nil)
  bioFree(bio)

# CRLによる証明書失効確認
proc isRevokedByCRL(cert: X509, crl: CRL): bool =
  let x509 = cert.getInternalPtr()
  let revoked = X509_CRL_get0_by_cert(crl, nil, x509)
  return revoked == 1

# CRLの有効期限確認
proc isExpired(crl: CRL): bool =
  let now = getTime()
  let lastUpdate = X509_CRL_get_lastUpdate(crl).asn1_to_time()
  let nextUpdate = X509_CRL_get_nextUpdate(crl).asn1_to_time()
  
  return now < lastUpdate or now > nextUpdate

# OCSPリクエスト作成
proc createOcspRequest(cert: X509, issuerCert: X509): OCSPRequest =
  let req = OCSP_REQUEST_new()
  
  # 証明書IDを作成
  let certid = OCSP_cert_to_id(EVP_sha1(), cert.getInternalPtr(), issuerCert.getInternalPtr())
  
  # リクエストに証明書IDを追加
  discard OCSP_request_add0_id(req, certid)
  
  # ノンスを追加
  var nonce = newString(16)
  for i in 0..<16:
    nonce[i] = char(rand(255))
  
  discard OCSP_request_add1_nonce(req, nonce.cstring, nonce.len)
  
  return req

# OCSPリクエストをエンコード
proc encode(req: OCSPRequest): string =
  var length: cint
  let data = OCSP_i2d_req_bio(req, length)
  
  result = newString(length)
  copyMem(addr result[0], data, length)
  
  OPENSSL_free(data)

# OCSPレスポンスを解析
proc parseOcspResponse(data: string): OCSPResponse =
  let bio = bioNew(BIO_s_mem())
  discard bio.bioWrite(data.cstring, data.len)
  result = d2i_OCSP_RESPONSE_bio(bio, nil)
  bioFree(bio)

# OCSPレスポンスの有効期限確認
proc isExpired(resp: OCSPResponse): bool =
  let basic = OCSP_response_get1_basic(resp)
  if basic == nil:
    return true
  
  var thisupd, nextupd: PASN1_TIME
  
  # 最後の更新時刻と次の更新時刻を取得
  discard OCSP_resp_get0_produced_at(basic, thisupd.addr)
  discard OCSP_resp_find_status(basic, nil, nil, nil, nextupd.addr, nil, nil)
  
  let now = getTime()
  let thisUpdate = thisupd.asn1_to_time()
  
  # 次の更新がない場合は24時間有効と仮定
  if nextupd == nil:
    return now < thisUpdate or now > thisUpdate + initDuration(hours = 24)
  
  let nextUpdate = nextupd.asn1_to_time()
  return now < thisUpdate or now > nextUpdate

# OCSPレスポンスから証明書の状態を取得
proc getCertStatus(resp: OCSPResponse, cert: X509, issuerCert: X509): int =
  let basic = OCSP_response_get1_basic(resp)
  if basic == nil:
    return OCSP_CERT_UNKNOWN
  
  # 証明書IDを作成
  let certid = OCSP_cert_to_id(EVP_sha1(), cert.getInternalPtr(), issuerCert.getInternalPtr())
  
  var status: cint
  var reason: cint
  var revtime: PASN1_TIME
  var thisupd: PASN1_TIME
  var nextupd: PASN1_TIME
  
  # 証明書の状態を取得
  let res = OCSP_resp_find_status(basic, certid, status.addr, reason.addr, revtime.addr, thisupd.addr, nextupd.addr)
  
  if res != 1:
    return OCSP_CERT_UNKNOWN
  
  return status

# OCSPレスポンスから証明書が失効しているかを確認
proc isRevoked(resp: OCSPResponse, cert: X509): bool =
  # 発行者証明書を探す
  let issuerCertOpt = findIssuerCertificate(cert)
  if issuerCertOpt.isNone:
    return false
    
  let status = resp.getCertStatus(cert, issuerCertOpt.get())
  return status == OCSP_CERT_REVOKED

# ASN1 TIMEをTimeに変換
proc asn1_to_time(time: PASN1_TIME): Time =
  var tm: TmStruct
  ASN1_TIME_to_tm(time, tm.addr)
  
  var timeinfo: Tm
  timeinfo.tm_year = tm.tm_year
  timeinfo.tm_mon = tm.tm_mon
  timeinfo.tm_mday = tm.tm_mday
  timeinfo.tm_hour = tm.tm_hour
  timeinfo.tm_min = tm.tm_min
  timeinfo.tm_sec = tm.tm_sec
  
  return timeinfo.toTime()

# 拡張情報からCRL配布ポイントを取得
proc hasCrlDistributionPoints*(cert: X509): bool =
  return X509_get_ext_by_NID(cert.getInternalPtr(), NID_crl_distribution_points, -1) >= 0

proc getCrlDistributionPoints*(cert: X509): seq[string] =
  result = @[]
  
  let ext = X509_get_ext(cert.getInternalPtr(), X509_get_ext_by_NID(cert.getInternalPtr(), NID_crl_distribution_points, -1))
  if ext == nil:
    return result
  
  var crlDist = X509V3_EXT_d2i(ext)
  if crlDist == nil:
    return result
  
  let numDist = sk_DIST_POINT_num(cast[STACK_OF_DIST_POINT](crlDist))
  
  for i in 0..<numDist:
    let dist = sk_DIST_POINT_value(cast[STACK_OF_DIST_POINT](crlDist), i)
    if dist.distpoint == nil:
      continue
    
    if dist.distpoint.`type` == 0: # fullname
      let numNames = sk_GENERAL_NAME_num(dist.distpoint.name.fullname)
      
      for j in 0..<numNames:
        let name = sk_GENERAL_NAME_value(dist.distpoint.name.fullname, j)
        
        if name.`type` == GEN_URI:
          var data = ASN1_STRING_data(name.d.uniformResourceIdentifier)
          var length = ASN1_STRING_length(name.d.uniformResourceIdentifier)
          
          var url = newString(length)
          copyMem(addr url[0], data, length)
          
          result.add(url)
  
  DIST_POINT_free(cast[PDIST_POINT](crlDist))

# 拡張情報からAuthority Info Accessを取得
proc hasAuthorityInfoAccess*(cert: X509): bool =
  return X509_get_ext_by_NID(cert.getInternalPtr(), NID_info_access, -1) >= 0

proc getOcspResponders*(cert: X509): seq[string] =
  result = @[]
  
  let ext = X509_get_ext(cert.getInternalPtr(), X509_get_ext_by_NID(cert.getInternalPtr(), NID_info_access, -1))
  if ext == nil:
    return result
  
  var info = X509V3_EXT_d2i(ext)
  if info == nil:
    return result
  
  let numAcc = sk_ACCESS_DESCRIPTION_num(cast[STACK_OF_ACCESS_DESCRIPTION](info))
  
  for i in 0..<numAcc:
    let acc = sk_ACCESS_DESCRIPTION_value(cast[STACK_OF_ACCESS_DESCRIPTION](info), i)
    
    # OCSP用のアクセスポイントかを確認
    if OBJ_obj2nid(acc.method) == NID_ad_OCSP:
      if acc.location.`type` == GEN_URI:
        var data = ASN1_STRING_data(acc.location.d.uniformResourceIdentifier)
        var length = ASN1_STRING_length(acc.location.d.uniformResourceIdentifier)
        
        var url = newString(length)
        copyMem(addr url[0], data, length)
        
        result.add(url)
  
  ACCESS_DESCRIPTION_free(cast[PACCESS_DESCRIPTION](info))

# 証明書が自己署名かどうかを確認
proc isSelfSigned*(cert: X509): bool =
  let issuer = cert.getIssuerName().getString()
  let subject = cert.getSubjectName().getString()
  
  if issuer != subject:
    return false
  
  # 公開鍵で署名を検証
  let pubkey = X509_get_pubkey(cert.getInternalPtr())
  let res = X509_verify(cert.getInternalPtr(), pubkey)
  EVP_PKEY_free(pubkey)
  
  return res == 1

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