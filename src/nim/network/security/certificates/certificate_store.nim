# 証明書ストアモジュール
#
# このモジュールは、ブラウザの証明書管理機能を提供します。
# SSL/TLS接続の検証に使用される証明書の管理、検証、保存などの機能を実装します。

import std/[os, times, tables, options, strutils, sequtils, sugar, hashes]
import std/[json, streams, base64]
import ../../logging

type
  CertificateFormat* = enum
    cfPEM     # PEMフォーマット（Base64エンコード、---BEGIN CERTIFICATE---で始まる）
    cfDER     # DERフォーマット（バイナリ）
    cfPKCS12  # PKCS#12フォーマット（通常、.pfxまたは.p12ファイル）

  CertificateType* = enum
    ctRootCA      # ルート認証局
    ctIntermediateCA  # 中間認証局
    ctEndEntity   # エンドエンティティ証明書（サーバーやクライアント）
    ctSelfSigned  # 自己署名証明書

  CertificateStatus* = enum
    csValid       # 有効
    csExpired     # 期限切れ
    csRevoked     # 失効
    csUntrusted   # 信頼できない
    csUnknown     # 不明

  TrustLevel* = enum
    tlTrusted     # 信頼する
    tlDistrusted  # 信頼しない
    tlUnknown     # 未定義

  CertificateValidationResult* = enum
    cvrValid              # 証明書は有効
    cvrExpired            # 証明書の有効期限が切れている
    cvrNotYetValid        # 証明書はまだ有効期間に入っていない
    cvrRevoked            # 証明書は失効している
    cvrSelfSigned         # 自己署名証明書
    cvrUnknownIssuer      # 発行者が不明
    cvrInvalidSignature   # 署名が無効
    cvrInvalidChain       # 証明書チェーンが無効
    cvrGeneralError       # その他のエラー

  ValidationOptions* = object
    checkRevocation*: bool     # 失効確認を行うかどうか
    allowSelfSigned*: bool     # 自己署名証明書を許可するかどうか
    verifyHostname*: bool      # ホスト名の検証を行うかどうか
    currentTime*: Option[DateTime]  # 検証に使用する時間（未指定の場合は現在時刻）
    trustStore*: Option[CertificateStore]  # 検証に使用する信頼ストア（未指定の場合はシステムのものを使用）

  Certificate* = ref object
    subject*: string          # 証明書の主体者（Subject）
    issuer*: string           # 発行者（Issuer）
    serialNumber*: string     # シリアル番号
    thumbprint*: string       # サムプリント（指紋）
    notBefore*: DateTime      # 有効期間開始日時
    notAfter*: DateTime       # 有効期間終了日時
    subjectAltNames*: seq[string]  # サブジェクト代替名
    keyUsage*: seq[string]    # 鍵使用法
    certificateType*: CertificateType  # 証明書タイプ
    publicKey*: string        # 公開鍵
    format*: CertificateFormat # 証明書フォーマット
    rawData*: string          # 生の証明書データ（PEMまたはDER）
    status*: CertificateStatus # 証明書のステータス
    trustLevel*: TrustLevel   # 信頼レベル
    customAttributes*: Table[string, string]  # カスタム属性

  CertificateStore* = ref object
    name*: string                    # ストア名
    location*: string                # ストアの場所（ファイルパスなど）
    certificates*: Table[string, Certificate]  # 証明書のテーブル（キーはサムプリント）
    trustedCAs*: seq[string]         # 信頼されたCAのサムプリント
    untrustedCAs*: seq[string]       # 信頼されていないCAのサムプリント
    lastUpdated*: DateTime           # 最終更新日時

# 新しい証明書を作成
proc newCertificate*(
  subject: string,
  issuer: string,
  serialNumber: string,
  notBefore: DateTime,
  notAfter: DateTime,
  rawData: string,
  format: CertificateFormat = cfPEM,
  subjectAltNames: seq[string] = @[],
  certificateType: CertificateType = ctEndEntity,
  publicKey: string = "",
  keyUsage: seq[string] = @[],
  status: CertificateStatus = csUnknown,
  trustLevel: TrustLevel = tlUnknown
): Certificate =
  # 証明書のサムプリント（指紋）を計算
  # SHA-256暗号学的ハッシュ関数を使用
  var thumbprint: string
  
  case format:
    of cfPEM, cfDER:
      # OpenSSLを使用してサムプリントを計算
      try:
        # SHA-256ハッシュを使用
        thumbprint = calculateThumbprint(rawData, format)
        if thumbprint.len == 0:
          raise newException(CertificateError, "空のサムプリントが生成されました")
      except CertificateError as e:
        # 特定のエラーを再送出
        log(lvlError, "証明書のサムプリント計算中にエラーが発生しました: " & e.msg)
        raise e
      except:
        # その他のエラーの場合はフォールバック
        thumbprint = $hash(rawData)
        log(lvlWarn, "証明書のサムプリント計算に失敗しました。一時的なハッシュを使用します: " & getCurrentExceptionMsg())
    of cfPKCS12:
      try:
        thumbprint = calculatePKCS12Thumbprint(rawData)
      except:
        thumbprint = $hash(rawData)
        log(lvlWarn, "PKCS#12証明書のサムプリント計算に失敗しました: " & getCurrentExceptionMsg())
    else:
      thumbprint = $hash(rawData)
      log(lvlWarn, "未知のフォーマットの証明書です。標準ハッシュを使用します。")
  
  # 公開鍵の抽出
  var extractedPublicKey = publicKey
  if extractedPublicKey.len == 0:
    try:
      case format:
        of cfPEM:
          extractedPublicKey = extractPublicKeyFromPEM(rawData)
        of cfDER:
          extractedPublicKey = extractPublicKeyFromDER(rawData)
        of cfPKCS12:
          extractedPublicKey = extractPublicKeyFromPKCS12(rawData)
        else:
          log(lvlWarn, "未対応の証明書フォーマットからの公開鍵抽出: " & $format)
      
      if extractedPublicKey.len == 0:
        log(lvlWarn, "証明書から抽出された公開鍵が空です")
    except CertificateError as e:
      log(lvlError, "証明書からの公開鍵抽出中にエラーが発生しました: " & e.msg)
      raise e
    except:
      log(lvlWarn, "証明書から公開鍵の抽出に失敗しました: " & getCurrentExceptionMsg())
  # 証明書オブジェクトの作成
  result = Certificate(
    subject: subject,
    issuer: issuer,
    serialNumber: serialNumber,
    thumbprint: thumbprint,
    notBefore: notBefore,
    notAfter: notAfter,
    subjectAltNames: subjectAltNames,
    keyUsage: keyUsage,
    certificateType: certificateType,
    publicKey: extractedPublicKey,
    format: format,
    rawData: rawData,
    status: status,
    trustLevel: trustLevel,
    customAttributes: initTable[string, string]()
  )
  
  # 証明書の有効期限を確認して初期ステータスを設定
  let currentTime = now()
  if result.status == csUnknown:
    if currentTime < notBefore:
      result.status = csNotYetValid
    elif currentTime > notAfter:
      result.status = csExpired
    else:
      result.status = csValid
      
  # 自己署名証明書の検出
  if subject == issuer:
    # 自己署名証明書の場合、カスタム属性に記録
    result.customAttributes["isSelfSigned"] = "true"
    
    # ルート証明書でない自己署名証明書は通常信頼されない
    if certificateType != ctRootCA and result.trustLevel == tlUnknown:
      result.trustLevel = tlDistrusted

# 新しい証明書ストアを作成
proc newCertificateStore*(name: string, location: string): CertificateStore =
  result = CertificateStore(
    name: name,
    location: location,
    certificates: initTable[string, Certificate](),
    trustedCAs: @[],
    untrustedCAs: @[],
    lastUpdated: now()
  )

# システムの証明書ストアを読み込む
proc loadSystemStore*(): CertificateStore =
  result = newCertificateStore("System", "system")
  
  # プラットフォームごとの証明書ストアの読み込み方法
  when defined(windows):
    # Windows の証明書ストアの読み込み方法
    var storeHandle: HCERTSTORE
    var certContext: PCCERT_CONTEXT
    
    # Windows証明書ストアを開く
    storeHandle = CertOpenSystemStoreA(0, "ROOT")
    if storeHandle == nil:
      log(lvlError, "Windows証明書ストアを開けませんでした: " & $GetLastError())
      return result
    
    defer: CertCloseStore(storeHandle, 0)
    
    # 証明書を列挙
    certContext = CertEnumCertificatesInStore(storeHandle, nil)
    while certContext != nil:
      try:
        # 証明書データを取得
        let rawData = newSeq[byte](certContext.cbCertEncoded)
        copyMem(addr rawData[0], certContext.pbCertEncoded, certContext.cbCertEncoded)
        
        # 証明書を解析
        let cert = parseCertificate(rawData, cfDER)
        if cert != nil:
          # 証明書をストアに追加
          result.certificates[cert.thumbprint] = cert
          
          # ルート証明書として信頼設定
          if cert.certificateType == ctRootCA:
            cert.trustLevel = tlTrusted
            result.trustedCAs.add(cert.thumbprint)
      except:
        log(lvlWarn, "Windows証明書の解析に失敗: " & getCurrentExceptionMsg())
      
      # 次の証明書へ
      certContext = CertEnumCertificatesInStore(storeHandle, certContext)
    
    # 中間証明書ストアも読み込む
    storeHandle = CertOpenSystemStoreA(0, "CA")
    if storeHandle != nil:
      defer: CertCloseStore(storeHandle, 0)
      
      certContext = CertEnumCertificatesInStore(storeHandle, nil)
      while certContext != nil:
        try:
          let rawData = newSeq[byte](certContext.cbCertEncoded)
          copyMem(addr rawData[0], certContext.pbCertEncoded, certContext.cbCertEncoded)
          
          let cert = parseCertificate(rawData, cfDER)
          if cert != nil:
            result.certificates[cert.thumbprint] = cert
            
            if cert.certificateType == ctIntermediateCA:
              cert.trustLevel = tlTrusted
              result.trustedCAs.add(cert.thumbprint)
        except:
          log(lvlWarn, "Windows中間証明書の解析に失敗: " & getCurrentExceptionMsg())
        
        certContext = CertEnumCertificatesInStore(storeHandle, certContext)
  
  elif defined(macosx):
    # macOS の証明書ストアの読み込み方法
    var keychain: SecKeychainRef
    var searchRef: SecKeychainSearchRef
    var itemRef: SecKeychainItemRef
    var status: OSStatus
    
    # デフォルトキーチェーンを開く
    status = SecKeychainCopyDefault(addr keychain)
    if status != errSecSuccess:
      log(lvlError, "macOSキーチェーンを開けませんでした: " & $status)
      return result
    
    defer: CFRelease(keychain)
    
    # 証明書の検索を作成
    status = SecKeychainSearchCreateFromAttributes(
      keychain, 
      kSecCertificateItemClass, 
      nil, 
      addr searchRef
    )
    
    if status != errSecSuccess:
      log(lvlError, "macOS証明書検索の作成に失敗: " & $status)
      return result
    
    defer: CFRelease(searchRef)
    
    # 証明書を列挙
    while SecKeychainSearchCopyNext(searchRef, addr itemRef) == errSecSuccess:
      var certRef: SecCertificateRef
      
      # 証明書参照を取得
      status = SecCertificateCreateFromData(itemRef, addr certRef)
      if status == errSecSuccess and certRef != nil:
        try:
          # 証明書データを取得
          var dataRef: CFDataRef
          dataRef = SecCertificateCopyData(certRef)
          
          if dataRef != nil:
            let dataLen = CFDataGetLength(dataRef)
            let dataPtr = CFDataGetBytePtr(dataRef)
            
            var rawData = newSeq[byte](dataLen)
            copyMem(addr rawData[0], dataPtr, dataLen)
            
            # 証明書を解析
            let cert = parseCertificate(rawData, cfDER)
            if cert != nil:
              # 証明書をストアに追加
              result.certificates[cert.thumbprint] = cert
              
              # 信頼設定を評価
              var trustRef: SecTrustRef
              var trustResult: SecTrustResultType
              
              # 証明書の信頼評価を作成
              status = SecTrustCreateWithCertificates(certRef, nil, addr trustRef)
              if status == errSecSuccess:
                # 信頼評価を実行
                status = SecTrustEvaluate(trustRef, addr trustResult)
                if status == errSecSuccess:
                  # 信頼結果に基づいて設定
                  if trustResult == kSecTrustResultProceed or trustResult == kSecTrustResultUnspecified:
                    cert.trustLevel = tlTrusted
                    if cert.certificateType in {ctRootCA, ctIntermediateCA}:
                      result.trustedCAs.add(cert.thumbprint)
                  elif trustResult == kSecTrustResultDeny:
                    cert.trustLevel = tlDistrusted
                    if cert.certificateType in {ctRootCA, ctIntermediateCA}:
                      result.untrustedCAs.add(cert.thumbprint)
                
                CFRelease(trustRef)
            
            CFRelease(dataRef)
        except:
          log(lvlWarn, "macOS証明書の解析に失敗: " & getCurrentExceptionMsg())
        
        CFRelease(certRef)
      
      CFRelease(itemRef)
  
  else:
    # Linux などの証明書ストアの読み込み方法
    # 複数の可能性のある証明書ディレクトリをチェック
    let possibleCertDirs = [
      "/etc/ssl/certs",
      "/etc/pki/tls/certs",
      "/usr/share/ca-certificates",
      "/usr/local/share/ca-certificates"
    ]
    
    var certDirsChecked = 0
    
    for certsDir in possibleCertDirs:
      if dirExists(certsDir):
        certDirsChecked.inc
        
        # ディレクトリ内の証明書ファイルを読み込む
        for kind, path in walkDir(certsDir):
          if kind == pcFile or kind == pcLinkToFile:
            let ext = path.splitFile.ext.toLowerAscii
            
            # 証明書ファイルの拡張子をチェック
            if ext in [".pem", ".crt", ".cer", ".der"]:
              try:
                # ファイルからデータを読み込む
                let rawData = readFile(path)
                
                # ファイル形式を判断
                let format = if ext in [".pem", ".crt"]: cfPEM else: cfDER
                
                # 証明書を解析
                let cert = parseCertificate(cast[seq[byte]](rawData), format)
                if cert != nil:
                  # 証明書をストアに追加
                  result.certificates[cert.thumbprint] = cert
                  
                  # Linux環境では通常、システムディレクトリにある証明書は信頼されている
                  if cert.certificateType in {ctRootCA, ctIntermediateCA}:
                    cert.trustLevel = tlTrusted
                    result.trustedCAs.add(cert.thumbprint)
              except:
                log(lvlWarn, "証明書ファイルの読み込みに失敗: " & path & " - " & getCurrentExceptionMsg())
    
    # Mozilla NSS共有データベースからの読み込みも試みる
    let nssDbPath = getHomeDir() / ".pki/nssdb"
    if dirExists(nssDbPath):
      certDirsChecked.inc
      
      # NSS certutil コマンドを使用して証明書を抽出
      try:
        let (output, exitCode) = execCmdEx("certutil -L -d sql:" & nssDbPath & " -h all")
        if exitCode == 0:
          # 出力から証明書のニックネームを抽出
          for line in output.splitLines():
            if line.len > 0 and not line.startsWith(" ") and not line.startsWith("Certificate"):
              let nickname = line.strip()
              
              # 各証明書をエクスポート
              let tempFile = getTempDir() / "temp_cert.pem"
              let exportCmd = "certutil -L -d sql:" & nssDbPath & " -n \"" & nickname & "\" -a > " & tempFile
              
              if execCmd(exportCmd) == 0:
                try:
                  # エクスポートした証明書を読み込む
                  let rawData = readFile(tempFile)
                  let cert = parseCertificate(cast[seq[byte]](rawData), cfPEM)
                  
                  if cert != nil:
                    result.certificates[cert.thumbprint] = cert
                    
                    # 信頼フラグを確認
                    if "u" in line or "c" in line or "p" in line:
                      cert.trustLevel = tlTrusted
                      if cert.certificateType in {ctRootCA, ctIntermediateCA}:
                        result.trustedCAs.add(cert.thumbprint)
                except:
                  log(lvlWarn, "NSS証明書の解析に失敗: " & nickname & " - " & getCurrentExceptionMsg())
                
                # 一時ファイルを削除
                removeFile(tempFile)
      except:
        log(lvlWarn, "NSS証明書データベースの読み込みに失敗: " & getCurrentExceptionMsg())
    
    # 証明書が見つからなかった場合の警告
    if certDirsChecked == 0:
      log(lvlWarn, "システム証明書ディレクトリが見つかりませんでした")

  log(lvlInfo, "システム証明書ストアを読み込みました。証明書数: " & $result.certificates.len)
  
  return result

# 証明書ストアに証明書を追加
proc addCertificate*(store: CertificateStore, certificate: Certificate) =
  store.certificates[certificate.thumbprint] = certificate
  store.lastUpdated = now()
  
  # 証明書の種類に応じて、信頼されたCAリストに追加
  if certificate.certificateType in {ctRootCA, ctIntermediateCA} and 
     certificate.trustLevel == tlTrusted:
    store.trustedCAs.add(certificate.thumbprint)

# 証明書ストアから証明書を削除
proc removeCertificate*(store: CertificateStore, thumbprint: string) =
  if store.certificates.hasKey(thumbprint):
    # 信頼されたCAリストから削除
    store.trustedCAs.keepIf(proc(x: string): bool = x != thumbprint)
    # 信頼されていないCAリストから削除
    store.untrustedCAs.keepIf(proc(x: string): bool = x != thumbprint)
    # 証明書を削除
    store.certificates.del(thumbprint)
    store.lastUpdated = now()

# 証明書の信頼レベルを設定
proc setTrustLevel*(store: CertificateStore, thumbprint: string, level: TrustLevel) =
  if store.certificates.hasKey(thumbprint):
    let cert = store.certificates[thumbprint]
    cert.trustLevel = level
    
    # 信頼レベルに応じてリストを更新
    if cert.certificateType in {ctRootCA, ctIntermediateCA}:
      # 現在のリストから削除
      store.trustedCAs.keepIf(proc(x: string): bool = x != thumbprint)
      store.untrustedCAs.keepIf(proc(x: string): bool = x != thumbprint)
      
      # 適切なリストに追加
      case level:
        of tlTrusted:
          store.trustedCAs.add(thumbprint)
        of tlDistrusted:
          store.untrustedCAs.add(thumbprint)
        of tlUnknown:
          discard  # どのリストにも追加しない
    
    store.lastUpdated = now()

# 証明書のステータスを更新
proc updateCertificateStatus*(cert: Certificate) =
  let now = now()
  
  # 有効期限のチェック
  if now < cert.notBefore:
    cert.status = csUntrusted  # まだ有効期間に入っていない
  elif now > cert.notAfter:
    cert.status = csExpired    # 期限切れ
  else:
    # 信頼レベルに基づいたステータス設定
    case cert.trustLevel:
      of tlTrusted:
        cert.status = csValid
      of tlDistrusted:
        cert.status = csUntrusted
      of tlUnknown:
        # 自己署名証明書の場合は信頼できない
        if cert.subject == cert.issuer:
          cert.status = csUntrusted
        else:
          cert.status = csUnknown

# 証明書ストア内のすべての証明書のステータスを更新
proc updateAllCertificateStatus*(store: CertificateStore) =
  for thumbprint, cert in store.certificates:
    updateCertificateStatus(cert)
  
  store.lastUpdated = now()
  log(lvlInfo, "証明書ストア内のすべての証明書ステータスを更新しました")

# 証明書のPEMデータを解析して証明書オブジェクトを作成
proc parsePEMCertificate*(pemData: string): Option[Certificate] =
  # PEM形式の証明書のヘッダーとフッターをチェック
  if not (pemData.contains("-----BEGIN CERTIFICATE-----") and 
          pemData.contains("-----END CERTIFICATE-----")):
    log(lvlError, "無効なPEM形式の証明書です")
    return none(Certificate)
  
  try:
    # OpenSSLを使用してPEM形式の証明書を解析
    let bio = bioNewMemBuf(pemData.cstring, pemData.len.cint)
    if bio == nil:
      log(lvlError, "BIOメモリバッファの作成に失敗しました")
      return none(Certificate)
    
    defer: bioFree(bio)
    
    let cert = PEM_read_bio_X509(bio, nil, nil, nil)
    if cert == nil:
      log(lvlError, "PEMデータからX509証明書の解析に失敗しました")
      return none(Certificate)
    
    defer: X509_free(cert)
    
    # 証明書の基本情報を抽出
    var subject, issuer: string
    var serialNumber: string
    var notBefore, notAfter: Time
    var thumbprint: string
    
    # 主体者名を取得
    let subjectName = X509_get_subject_name(cert)
    if subjectName != nil:
      subject = extractNameString(subjectName)
    
    # 発行者名を取得
    let issuerName = X509_get_issuer_name(cert)
    if issuerName != nil:
      issuer = extractNameString(issuerName)
    
    # シリアル番号を取得
    let serial = X509_get_serialNumber(cert)
    if serial != nil:
      serialNumber = extractSerialNumberString(serial)
    
    # 有効期間を取得
    notBefore = extractTimeFromASN1(X509_get_notBefore(cert))
    notAfter = extractTimeFromASN1(X509_get_notAfter(cert))
    
    # 証明書のフィンガープリント（サムプリント）を計算
    thumbprint = calculateThumbprint(cert, EVP_sha256())
    
    # 証明書タイプを判定
    let certType = determineCertificateType(cert)
    
    # 証明書オブジェクトを作成
    let certificate = Certificate(
      subject: subject,
      issuer: issuer,
      serialNumber: serialNumber,
      notBefore: notBefore,
      notAfter: notAfter,
      thumbprint: thumbprint,
      format: cfPEM,
      rawData: pemData,
      certificateType: certType,
      trustLevel: tlUnknown,
      status: csUnknown
    )
    
    # 証明書のステータスを更新
    updateCertificateStatus(certificate)
    
    log(lvlInfo, "PEM証明書を正常に解析しました: " & subject)
    return some(certificate)
  
  except Exception as e:
    log(lvlError, "PEM証明書の解析中にエラーが発生しました: " & e.msg)
    return none(Certificate)

# 証明書のDERデータを解析して証明書オブジェクトを作成
proc parseDERCertificate*(derData: string): Option[Certificate] =
  # OpenSSLを使用してDER形式の証明書を直接解析する
  try:
    # DERデータのバリデーション
    if derData.len == 0:
      log(lvlError, "空のDERデータが提供されました")
      return none(Certificate)
    
    # OpenSSLのX509構造体にDERデータを読み込む
    var cert: X509Ptr
    let bio = bioNewMemBuf(derData.cstring, derData.len.cint)
    if bio == nil:
      log(lvlError, "BIOメモリバッファの作成に失敗しました")
      return none(Certificate)
    
    defer: bioFree(bio)
    
    cert = d2i_X509_bio(bio, nil)
    if cert == nil:
      log(lvlError, "DERデータからX509証明書の解析に失敗しました")
      return none(Certificate)
    
    defer: X509_free(cert)
    
    # 証明書の基本情報を抽出
    var subjectName, issuerName: string
    var serialNumber: string
    var notBefore, notAfter: Time
    
    # 主体者名を取得
    let subject = X509_get_subject_name(cert)
    if subject != nil:
      var subjectBuf = newString(256)
      let subjectLen = X509_NAME_get_text_by_NID(subject, NID_commonName, subjectBuf.cstring, 256)
      if subjectLen > 0:
        subjectName = subjectBuf[0..<subjectLen]
    
    # 発行者名を取得
    let issuer = X509_get_issuer_name(cert)
    if issuer != nil:
      var issuerBuf = newString(256)
      let issuerLen = X509_NAME_get_text_by_NID(issuer, NID_commonName, issuerBuf.cstring, 256)
      if issuerLen > 0:
        issuerName = issuerBuf[0..<issuerLen]
    
    # シリアル番号を取得
    let serial = X509_get_serialNumber(cert)
    if serial != nil:
      var serialBuf = newString(256)
      let serialLen = i2d_ASN1_INTEGER(serial, nil)
      if serialLen > 0:
        var p = cast[ptr UncheckedArray[uint8]](serialBuf.cstring)
        discard i2d_ASN1_INTEGER(serial, addr p)
        serialNumber = serialBuf[0..<serialLen].toHex()
    
    # 有効期間を取得
    let asn1Before = X509_get_notBefore(cert)
    let asn1After = X509_get_notAfter(cert)
    
    if asn1Before != nil and asn1After != nil:
      var beforeTime, afterTime: Time
      var beforeTm, afterTm: Tm
      
      discard ASN1_TIME_to_tm(asn1Before, addr beforeTm)
      discard ASN1_TIME_to_tm(asn1After, addr afterTm)
      
      notBefore = fromTm(beforeTm)
      notAfter = fromTm(afterTm)
    
    # DERデータをBase64エンコードしてPEM形式に変換（保存用）
    let base64Data = encode(derData)
    var pemData = "-----BEGIN CERTIFICATE-----\n"
    
    # Base64データを64文字ごとに改行
    var i = 0
    while i < base64Data.len:
      let endPos = min(i + 64, base64Data.len)
      pemData.add(base64Data[i..<endPos])
      pemData.add("\n")
      i = endPos
    
    pemData.add("-----END CERTIFICATE-----\n")
    
    # 証明書オブジェクトを作成
    let certificate = newCertificate(
      subjectName,
      issuerName,
      serialNumber,
      notBefore,
      notAfter,
      pemData,  # PEM形式で保存
      cfDER     # 元のフォーマットはDER
    )
    
    # 証明書のステータスを更新
    updateCertificateStatus(certificate)
    
    return some(certificate)
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, "DER証明書の解析中にエラーが発生しました: " & msg)
    return none(Certificate)

# PEMファイルから証明書を読み込む
proc loadCertificateFromPEMFile*(filePath: string): Option[Certificate] =
  try:
    let pemData = readFile(filePath)
    return parsePEMCertificate(pemData)
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, "PEMファイルの読み込みに失敗しました: " & msg)
    return none(Certificate)

# DERファイルから証明書を読み込む
proc loadCertificateFromDERFile*(filePath: string): Option[Certificate] =
  try:
    let derData = readFile(filePath)
    return parseDERCertificate(derData)
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, "DERファイルの読み込みに失敗しました: " & msg)
    return none(Certificate)

# ディレクトリ内のすべての証明書ファイルを読み込む
proc loadCertificatesFromDirectory*(directory: string, store: CertificateStore) =
  if not dirExists(directory):
    log(lvlError, "ディレクトリが存在しません: " & directory)
    return
  
  # ディレクトリ内のファイルを走査
  for kind, path in walkDir(directory):
    if kind == pcFile:
      let ext = path.splitFile().ext.toLowerAscii()
      
      var certOpt: Option[Certificate]
      
      # ファイル拡張子に基づいて読み込み方法を選択
      if ext == ".pem" or ext == ".crt" or ext == ".cer":
        certOpt = loadCertificateFromPEMFile(path)
      elif ext == ".der":
        certOpt = loadCertificateFromDERFile(path)
      
      # 証明書が正常に読み込まれた場合、ストアに追加
      if certOpt.isSome():
        store.addCertificate(certOpt.get())
        log(lvlInfo, "証明書を読み込みました: " & path)

# 証明書ストアをJSONに変換
proc toJson*(cert: Certificate): JsonNode =
  result = newJObject()
  result["subject"] = %cert.subject
  result["issuer"] = %cert.issuer
  result["serialNumber"] = %cert.serialNumber
  result["thumbprint"] = %cert.thumbprint
  result["notBefore"] = %($cert.notBefore)
  result["notAfter"] = %($cert.notAfter)
  result["subjectAltNames"] = %cert.subjectAltNames
  result["keyUsage"] = %cert.keyUsage
  result["certificateType"] = %($cert.certificateType)
  result["format"] = %($cert.format)
  result["status"] = %($cert.status)
  result["trustLevel"] = %($cert.trustLevel)
  
  # カスタム属性
  let attrsJson = newJObject()
  for k, v in cert.customAttributes:
    attrsJson[k] = %v
  result["customAttributes"] = attrsJson

# 証明書ストアをJSONに変換
proc toJson*(store: CertificateStore): JsonNode =
  result = newJObject()
  result["name"] = %store.name
  result["location"] = %store.location
  result["lastUpdated"] = %($store.lastUpdated)
  
  # 証明書リスト
  let certsJson = newJObject()
  for thumbprint, cert in store.certificates:
    certsJson[thumbprint] = cert.toJson()
  result["certificates"] = certsJson
  
  # 信頼されたCA
  result["trustedCAs"] = %store.trustedCAs
  
  # 信頼されていないCA
  result["untrustedCAs"] = %store.untrustedCAs

# 証明書ストアをJSONファイルに保存
proc saveToJsonFile*(store: CertificateStore, filePath: string): bool =
  try:
    let json = store.toJson()
    writeFile(filePath, $json)
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, "証明書ストアのJSON保存に失敗しました: " & msg)
    return false

# 証明書をPEMファイルにエクスポート
proc exportToPEMFile*(cert: Certificate, filePath: string): bool =
  try:
    # すでにPEM形式の場合はそのまま書き込む
    if cert.format == cfPEM:
      writeFile(filePath, cert.rawData)
    else:
      # DER形式の場合はPEMに変換
      let base64Data = encode(cert.rawData)
      var pemData = "-----BEGIN CERTIFICATE-----\n"
      
      # Base64データを64文字ごとに改行
      var i = 0
      while i < base64Data.len:
        let endPos = min(i + 64, base64Data.len)
        pemData.add(base64Data[i..<endPos])
        pemData.add("\n")
        i = endPos
      
      pemData.add("-----END CERTIFICATE-----\n")
      writeFile(filePath, pemData)
    
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, "証明書のPEMエクスポートに失敗しました: " & msg)
    return false

# 証明書の検証オプションを作成
proc newValidationOptions*(
  checkRevocation: bool = true,
  allowSelfSigned: bool = false,
  verifyHostname: bool = true,
  currentTime: Option[DateTime] = none(DateTime),
  trustStore: Option[CertificateStore] = none(CertificateStore)
): ValidationOptions =
  result = ValidationOptions(
    checkRevocation: checkRevocation,
    allowSelfSigned: allowSelfSigned,
    verifyHostname: verifyHostname,
    currentTime: currentTime,
    trustStore: trustStore
  )

# 証明書の検証
proc validateCertificate*(
  cert: Certificate, 
  options: ValidationOptions = newValidationOptions(), 
  hostname: string = ""
): CertificateValidationResult =
  # 検証に使用する時間
  var validationTime = now()
  if options.currentTime.isSome():
    validationTime = options.currentTime.get()
  
  # 有効期間の検証
  if validationTime < cert.notBefore:
    return cvrNotYetValid
  if validationTime > cert.notAfter:
    return cvrExpired
  
  # 自己署名証明書の検証
  let isSelfSigned = cert.subject == cert.issuer
  if isSelfSigned and not options.allowSelfSigned:
    return cvrSelfSigned
  
  # 信頼ストアの使用
  var trustStore: CertificateStore
  if options.trustStore.isSome():
    trustStore = options.trustStore.get()
  else:
    # システムの信頼ストアを使用
    trustStore = loadSystemStore()
  
  # 発行者の検証（証明書チェーンの検証）
  if not isSelfSigned:
    # 発行者証明書を信頼ストアから検索
    let issuerCerts = trustStore.findCertificatesBySubject(cert.issuer)
    if issuerCerts.len == 0:
      return cvrUntrustedIssuer
    
    # 署名の検証
    var signatureValid = false
    for issuerCert in issuerCerts:
      if verifySignature(cert, issuerCert):
        signatureValid = true
        break
    
    if not signatureValid:
      return cvrInvalidSignature
  
  # ホスト名の検証
  if options.verifyHostname and hostname != "":
    var hostnameMatched = false
    
    # 証明書の主体者名と比較
    if cert.subject.contains("CN=" & hostname):
      hostnameMatched = true
    
    # サブジェクト代替名との比較
    for altName in cert.subjectAltNames:
      # 完全一致
      if altName == hostname:
        hostnameMatched = true
        break
      
      # ワイルドカード証明書の処理
      if altName.startsWith("*.") and hostname.contains("."):
        let hostParts = hostname.split('.')
        let altNameParts = altName[2..^1].split('.')
        
        # ドメイン部分が一致し、ワイルドカードが最初のセグメントのみに適用される場合
        if hostParts.len == altNameParts.len and 
           hostParts[1..^1].join(".") == altNameParts.join("."):
          hostnameMatched = true
          break
    
    if not hostnameMatched:
      return cvrHostnameMismatch
  
  # 失効チェック
  if options.checkRevocation:
    # CRLによる失効チェック
    let crlResult = checkCertificateRevocationByCRL(cert, trustStore)
    if crlResult == csRevoked:
      return cvrRevoked
    
    # OCSPによる失効チェック（CRLが利用できない場合）
    if crlResult == csUnknown:
      let ocspResult = checkCertificateRevocationByOCSP(cert)
      if ocspResult == csRevoked:
        return cvrRevoked
  
  # 証明書の使用目的の検証
  if not validateCertificateUsage(cert, cuServerAuth):
    return cvrInvalidPurpose
  
  # 証明書の拡張機能の検証
  if not validateCertificateExtensions(cert):
    return cvrInvalidExtension
  
  # すべての検証に合格した場合
  return cvrValid

# 証明書チェーンの検証
proc validateCertificateChain*(
  certs: seq[Certificate], 
  options: ValidationOptions = newValidationOptions(), 
  hostname: string = ""
): CertificateValidationResult =
  # 証明書チェーンの検証ロジック
  
  # 証明書がない場合
  if certs.len == 0:
    return cvrGeneralError
  
  # エンドエンティティ証明書の検証
  let endEntityCert = certs[0]
  let endEntityResult = validateCertificate(endEntityCert, options, hostname)
  if endEntityResult != cvrValid:
    return endEntityResult
  
  # 証明書チェーンの構築と検証
  var currentCert = endEntityCert
  var verifiedChain: seq[Certificate] = @[endEntityCert]
  var remainingCerts = certs[1..^1]
  
  # チェーンの各証明書を検証
  while not isRootCA(currentCert):
    # 次の発行者を見つける
    var nextIssuer: Option[Certificate] = none(Certificate)
    
    # 提供されたチェーンから発行者を探す
    for i, cert in remainingCerts:
      if cert.subject == currentCert.issuer and verifySignature(currentCert, cert):
        nextIssuer = some(cert)
        remainingCerts.delete(i)
        break
    
    # 提供されたチェーンに発行者がない場合、信頼ストアから探す
    if nextIssuer.isNone():
      let trustStore = if options.trustStore.isSome(): options.trustStore.get() else: loadSystemStore()
      let issuerCerts = trustStore.findCertificatesBySubject(currentCert.issuer)
      
      for issuerCert in issuerCerts:
        if verifySignature(currentCert, issuerCert):
          nextIssuer = some(issuerCert)
          break
    
    # 発行者が見つからない場合
    if nextIssuer.isNone():
      return cvrIncompleteChain
    
    # 発行者証明書を検証
    let issuerCert = nextIssuer.get()
    let issuerOptions = newValidationOptions(
      checkRevocation: options.checkRevocation,
      allowSelfSigned: issuerCert.subject == issuerCert.issuer,  # ルート証明書は自己署名可
      verifyHostname: false,
      currentTime: options.currentTime,
      trustStore: options.trustStore
    )
    
    let issuerResult = validateCertificate(issuerCert, issuerOptions)
    if issuerResult != cvrValid:
      return cvrInvalidChain
    
    # 検証済みチェーンに追加
    verifiedChain.add(issuerCert)
    currentCert = issuerCert
    
    # ルート証明書に到達したら終了
    if isRootCA(currentCert):
      break
  
  # パス長制約の検証
  if not validatePathLengthConstraint(verifiedChain):
    return cvrPathLengthExceeded
  # 中間CA証明書の検証
  for i in 1..<certs.len:
    let caCert = certs[i]
    let caOptions = newValidationOptions(
      checkRevocation: options.checkRevocation,
      allowSelfSigned: false,  # CA証明書は自己署名を許可しない
      verifyHostname: false,   # CA証明書はホスト名の検証を行わない
      currentTime: options.currentTime,
      trustStore: options.trustStore
    )
    
    let caResult = validateCertificate(caCert, caOptions)
    if caResult != cvrValid:
      # 中間CAが無効な場合、チェーン全体が無効
      return cvrInvalidChain
  
  # すべての証明書が有効な場合
  return cvrValid 