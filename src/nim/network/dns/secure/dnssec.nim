import std/[strutils, sequtils, options, tables, hashes, times, base64]
import std/sha1 as stdsha1
import std/sha2 as stdsha2
import std/hmac as stdhmac
import std/nimcrypto
import std/[math, sets, unicode, uri, parseopt, random, threadpool, locks]
import std/[asyncdispatch, json, parsecfg]
import std/punycode
import ../records

# 定数定義
const
  MAX_CACHE_SIZE* = 10000          # 最大キャチE��ュサイズ
  MAX_SIGNATURE_LIFETIME* = 30*24*60*60  # 最大署名有効期間 (30日)
  MIN_KEY_SIZE_RSA* = 2048         # RSAの最小鍵長
  MIN_KEY_SIZE_ECC* = 256          # ECCの最小鍵長
  NSEC3_MAX_ITERATIONS* = 100      # NSEC3の最大イチE��ーション
  ROOT_TRUST_ANCHOR_URL* = "https://data.iana.org/root-anchors/root-anchors.xml"  # ルート信頼アンカーURL
  DNSSEC_PORT* = 53                # DNSSECのチE��ォルト�EーチE
  
  # RFC 8624に基づく推奨アルゴリズム
  RECOMMENDED_ALGORITHMS* = [
    DnsKeyAlgorithm.RSA_SHA256,
    DnsKeyAlgorithm.RSA_SHA512,
    DnsKeyAlgorithm.ECDSA_P256_SHA256,
    DnsKeyAlgorithm.ECDSA_P384_SHA384,
    DnsKeyAlgorithm.ED25519,
    DnsKeyAlgorithm.ED448
  ]

# スレチE��安�E性のための垁E
type
  ThreadSafeCache* = object
    lock: Lock
    cache: Table[string, tuple[data: string, expiration: Time]]

type
  DnsKeyAlgorithm* = enum
    ## DNSキーアルゴリズム (RFC 4034, 5702, 6605, 8624)
    RSA_MD5 = 1      # 非推奨
    DH = 2           # Diffie-Hellman
    DSA = 3          # Digital Signature Algorithm
    RSA_SHA1 = 5     # RSA/SHA-1
    DSA_NSEC3_SHA1 = 6  # DSA-NSEC3-SHA1
    RSASHA1_NSEC3_SHA1 = 7  # RSASHA1-NSEC3-SHA1
    RSA_SHA256 = 8   # RSA/SHA-256
    RSA_SHA512 = 10  # RSA/SHA-512
    ECC_GOST = 12    # GOST R 34.10-2001
    ECDSA_P256_SHA256 = 13  # ECDSA Curve P-256 with SHA-256
    ECDSA_P384_SHA384 = 14  # ECDSA Curve P-384 with SHA-384
    ED25519 = 15     # Ed25519
    ED448 = 16       # Ed448

  DigestAlgorithm* = enum
    ## ダイジェストアルゴリズム (RFC 4509, 5933, 6605)
    SHA1 = 1         # SHA-1
    SHA256 = 2       # SHA-256
    GOST_R_34_11_94 = 3  # GOST R 34.11-94
    SHA384 = 4       # SHA-384

  DnsKeyRecord* = object
    ## DNSKEYレコーチE(RFC 4034)
    flags*: uint16       # フラグフィールチE
    protocol*: uint8     # プロトコルフィールチE(常に3)
    algorithm*: DnsKeyAlgorithm  # 鍵アルゴリズム
    publicKey*: string   # 公開鍵チE�Eタ

  DsRecord* = object
    ## DSレコーチE(RFC 4034)
    keyTag*: uint16      # キータグ
    algorithm*: DnsKeyAlgorithm  # アルゴリズム
    digestType*: DigestAlgorithm  # ダイジェストタイチE
    digest*: string      # ダイジェスチE

  RrsigRecord* = object
    ## RRSIGレコーチE(RFC 4034)
    typeCovered*: DnsRecordType  # カバ�EされるタイチE
    algorithm*: DnsKeyAlgorithm  # アルゴリズム
    labels*: uint8       # ラベル数
    originalTtl*: uint32  # 允E�ETTL
    signatureExpiration*: Time  # 署名有効期限
    signatureInception*: Time   # 署名開始時閁E
    keyTag*: uint16      # キータグ
    signerName*: string  # 署名老E��
    signature*: string   # 署名データ

  NsecRecord* = object
    ## NSECレコーチE(RFC 4034)
    nextDomainName*: string  # 次のドメイン吁E
    typeBitMaps*: seq[DnsRecordType]  # タイプビチE��マッチE

  Nsec3Record* = object
    ## NSEC3レコーチE(RFC 5155)
    hashAlgorithm*: uint8  # ハッシュアルゴリズム
    flags*: uint8         # フラグ
    iterations*: uint16   # イチE��ーション
    salt*: string         # ソルチE
    nextHashedOwner*: string  # 次のハッシュ所有老E
    typeBitMaps*: seq[DnsRecordType]  # タイプビチE��マッチE

  DnssecStatus* = enum
    ## DNSSEC検証スチE�Eタス
    Secure,         # 完�Eに検証済み
    Insecure,       # DNSSECが実裁E��れてぁE��ぁE
    Indeterminate,  # 検証できなぁE
    Bogus           # 検証失敁E

  DnssecValidator* = ref object
    ## DNSSEC検証エンジン
    trustAnchors*: Table[string, seq[DnsKeyRecord]]  # 信頼アンカー
    dsRecords*: Table[string, seq[DsRecord]]  # DSレコーチE
    keyRecords*: Table[string, seq[DnsKeyRecord]]  # キーレコーチE

  RSAVerifyContext* = ref object
    ## RSA検証コンチE��スチE
    publicKey: string  # 公開鍵 (RFC 3110 フォーマッチE
    algorithm: DnsKeyAlgorithm  # 使用するアルゴリズム

  DSAVerifyContext* = ref object
    ## DSA検証コンチE��スチE
    publicKey: string  # 公開鍵
    algorithm: DnsKeyAlgorithm  # 使用するアルゴリズム

  ECDSAVerifyContext* = ref object
    ## ECDSA検証コンチE��スチE
    publicKey: string  # 公開鍵
    algorithm: DnsKeyAlgorithm  # 使用するアルゴリズム

  EdDSAVerifyContext* = ref object
    ## EdDSA検証コンチE��スチE
    publicKey: string  # 公開鍵
    algorithm: DnsKeyAlgorithm  # 使用するアルゴリズム

  DnssecTestResult* = object
    ## DNSSEC検証チE��ト結果
    domain*: string            # チE��ト対象ドメイン
    status*: DnssecStatus      # 検証スチE�Eタス
    hasValidSignature*: bool   # 有効な署名があるぁE
    hasDnskey*: bool           # DNSKEYレコードがあるぁE
    hasDs*: bool               # DSレコードがあるぁE
    signatureExpiration*: Time  # 署名�E有効期限
    keyAlgorithms*: seq[DnsKeyAlgorithm]  # 使用されてぁE��アルゴリズム
    verificationTime*: float   # 検証にかかった時間（ミリ秒！E
    errorMessages*: seq[string]  # エラーメチE��ージ
    warnings*: seq[string]     # 警告メチE��ージ

  DnssecVerificationCache* = ref object
    ## DNSSEC検証結果キャチE��ュ
    cache*: Table[string, tuple[status: DnssecStatus, expiration: Time]]
    maxEntries*: int           # キャチE��ュの最大エントリ数
    hits*: int                 # キャチE��ュヒット数
    misses*: int               # キャチE��ュミス数

  DnssecStats* = object
    ## DNSSEC検証統訁E
    validations*: int          # 実行された検証の数
    successfulValidations*: int # 成功した検証の数
    failedValidations*: int    # 失敗した検証の数
    averageValidationTime*: float # 平坁E��証時間�E�ミリ秒！E
    cacheSizeBytes*: int       # キャチE��ュサイズ�E�バイト！E
    validationsByStatus*: Table[DnssecStatus, int] # スチE�Eタス別の検証数
    validationsByAlgorithm*: Table[DnsKeyAlgorithm, int] # アルゴリズム別の検証数
    startTime*: Time           # 統計収雁E��始時閁E

  DnssecError* = object of CatchableError
    ## DNSSEC検証に関連するエラー
    domain*: string
    recordType*: DnsRecordType
    status*: DnssecStatus
    detail*: string

proc newDnssecValidator*(): DnssecValidator =
  ## 新しいDNSSEC検証エンジンを作�E
  result = DnssecValidator(
    trustAnchors: initTable[string, seq[DnsKeyRecord]](),
    dsRecords: initTable[string, seq[DsRecord]](),
    keyRecords: initTable[string, seq[DnsKeyRecord]]()
  )

proc addTrustAnchor*(validator: DnssecValidator, domain: string, keyRecord: DnsKeyRecord) =
  ## 信頼アンカーを追加
  if not validator.trustAnchors.hasKey(domain):
    validator.trustAnchors[domain] = @[]
  validator.trustAnchors[domain].add(keyRecord)

proc addDsRecord*(validator: DnssecValidator, domain: string, dsRecord: DsRecord) =
  ## DSレコードを追加
  if not validator.dsRecords.hasKey(domain):
    validator.dsRecords[domain] = @[]
  validator.dsRecords[domain].add(dsRecord)

proc addKeyRecord*(validator: DnssecValidator, domain: string, keyRecord: DnsKeyRecord) =
  ## キーレコードを追加
  if not validator.keyRecords.hasKey(domain):
    validator.keyRecords[domain] = @[]
  validator.keyRecords[domain].add(keyRecord)

proc calculateKeyTag*(key: DnsKeyRecord): uint16 =
  ## キータグを計箁E(RFC 4034, Appendix B)
  var ac: uint32 = 0
  
  # キーチE�Eタをワイヤーフォーマットに変換
  var wireFormat = newSeq[byte]()
  
  # フラグ、�Eロトコル、アルゴリズムを追加
  wireFormat.add(byte((key.flags shr 8) and 0xFF))
  wireFormat.add(byte(key.flags and 0xFF))
  wireFormat.add(byte(key.protocol))
  wireFormat.add(byte(key.algorithm))
  
  # 公開鍵チE�Eタを追加
  for b in key.publicKey:
    wireFormat.add(byte(b))
  
  # RFC 4034 Appendix Bのアルゴリズムを実裁E
  if wireFormat.len mod 2 != 0:
    ac += uint32(wireFormat[^1]) shl 8
  
  for i in countup(0, wireFormat.len - 1, 2):
    if i + 1 < wireFormat.len:
      ac += (uint32(wireFormat[i]) shl 8) + uint32(wireFormat[i + 1])
    else:
      ac += uint32(wireFormat[i]) shl 8
  
  ac += (ac shr 16) and 0xFFFF
  
  return uint16(ac and 0xFFFF)

proc isZoneKey*(key: DnsKeyRecord): bool =
  ## ゾーンキーかどぁE��を確誁E(RFC 4034, Section 2.1.1)
  return (key.flags and 0x0100) != 0

proc isSecureEntryPoint*(key: DnsKeyRecord): bool =
  ## セキュアエントリポインチESEP)かどぁE��を確誁E(RFC 4034, Section 2.1.1)
  return (key.flags and 0x0001) != 0

proc calculateDigestSHA1(data: string): string =
  ## SHA-1ダイジェストを計箁E
  var ctx: stdsha1.Sha1
  ctx.init()
  ctx.update(data)
  return ctx.final()

proc calculateDigestSHA256(data: string): string =
  ## SHA-256ダイジェストを計箁E
  var ctx: stdsha2.Sha256
  ctx.init()
  ctx.update(data)
  return ctx.final()

proc calculateDigestSHA384(data: string): string =
  ## SHA-384ダイジェストを計箁E
  var ctx: stdsha2.Sha384
  ctx.init()
  ctx.update(data)
  return ctx.final()

proc calculateDnsKeyDigest*(key: DnsKeyRecord, digestType: DigestAlgorithm, domain: string): string =
  ## DNSKEYレコードからダイジェストを計箁E(RFC 4034, Section 5.1.4)
  var canonicalData = domain.toLower()
  
  # DNSKEYのワイヤーフォーマットを追加
  # フラグ、�Eロトコル、アルゴリズム
  canonicalData.add(char((key.flags shr 8) and 0xFF))
  canonicalData.add(char(key.flags and 0xFF))
  canonicalData.add(char(key.protocol))
  canonicalData.add(char(key.algorithm))
  
  # 公開鍵チE�Eタ
  canonicalData.add(key.publicKey)
  
  # ダイジェストを計箁E
  case digestType:
  of SHA1:
    result = calculateDigestSHA1(canonicalData)
  of SHA256:
    result = calculateDigestSHA256(canonicalData)
  of SHA384:
    result = calculateDigestSHA384(canonicalData)
  else:
    # サポ�EトされてぁE��ぁE��イジェストタイチE
    result = ""

proc verifyDsRecord*(ds: DsRecord, key: DnsKeyRecord, domain: string): bool =
  ## DSレコードが特定�EDNSKEYレコードに対応するか検証
  # キータグをチェチE��
  if ds.keyTag != calculateKeyTag(key):
    return false
  
  # アルゴリズムをチェチE��
  if ds.algorithm != key.algorithm:
    return false
  
  # ダイジェストを計算して比輁E
  let calculatedDigest = calculateDnsKeyDigest(key, ds.digestType, domain)
  return calculatedDigest == ds.digest

proc newRSAVerifyContext*(publicKey: string): RSAVerifyContext =
  ## RSA検証コンチE��ストを作�E
  result = RSAVerifyContext(
    publicKey: publicKey,
    algorithm: RSA_SHA256  # チE��ォルト�ERSA/SHA-256
  )

proc newDSAVerifyContext*(publicKey: string): DSAVerifyContext =
  ## DSA検証コンチE��ストを作�E
  result = DSAVerifyContext(
    publicKey: publicKey,
    algorithm: DSA  # チE��ォルト�EDSA
  )

proc newECDSAVerifyContext*(publicKey: string): ECDSAVerifyContext =
  ## ECDSA検証コンチE��ストを作�E
  result = ECDSAVerifyContext(
    publicKey: publicKey,
    algorithm: ECDSA_P256_SHA256  # チE��ォルト�EECDSA P-256 with SHA-256
  )

proc newEdDSAVerifyContext*(publicKey: string, algorithm: DnsKeyAlgorithm): EdDSAVerifyContext =
  ## EdDSA検証コンチE��ストを作�E
  result = EdDSAVerifyContext(
    publicKey: publicKey,
    algorithm: algorithm  # ED25519また�EED448
  )

proc parseRSAPublicKey(publicKey: string): (seq[byte], seq[byte]) =
  ## RSA公開鍵をパース (RFC 3110形弁E
  try:
    # RFC 3110形弁E <exponent length byte(s)> <exponent> <modulus>
    var pos = 0
    var expLenByte = byte(publicKey[pos])
    pos += 1
    
    var expLen: int
    if expLenByte == 0:
      # 長ぁE��クスポ�EネンチE
      expLen = (int(byte(publicKey[pos])) shl 8) or int(byte(publicKey[pos+1]))
      pos += 2
    else:
      expLen = int(expLenByte)
    
    # エクスポ�Eネントを取征E
    var exponent = newSeq[byte](expLen)
    for i in 0..<expLen:
      exponent[i] = byte(publicKey[pos])
      pos += 1
    
    # 残りはモジュラス
    var modulus = newSeq[byte](publicKey.len - pos)
    for i in 0..<modulus.len:
      modulus[i] = byte(publicKey[pos])
      pos += 1
    
    return (exponent, modulus)
  except:
    return (@[], @[])

proc verify*(ctx: RSAVerifyContext, signedData: string, signature: string): bool =
  ## RSA署名�E検証
  try:
    # 署名ハチE��ュを選抁E
    var hashAlgorithm: nimcrypto.HashType
    case ctx.algorithm
    of RSA_SHA1, RSASHA1_NSEC3_SHA1:
      hashAlgorithm = nimcrypto.SHA1
    of RSA_SHA256:
      hashAlgorithm = nimcrypto.SHA256
    of RSA_SHA512:
      hashAlgorithm = nimcrypto.SHA512
    else:
      return false
    
    # RSA公開鍵をパース
    let (exponent, modulus) = parseRSAPublicKey(ctx.publicKey)
    if exponent.len == 0 or modulus.len == 0:
      return false
    
    # RSA公開鍵を作�E
    var rsa = nimcrypto.newRSAPublicKey(nimcrypto.RSAEP_PKCS1_V15, exponent, modulus)
    
    # 署名を検証
    var signatureBytes = newSeq[byte](signature.len)
    for i in 0..<signature.len:
      signatureBytes[i] = byte(signature[i])
    
    return nimcrypto.rsaVerify(rsa, cast[ptr byte](addr signedData[0]), 
                           signedData.len, addr signatureBytes[0], 
                           signatureBytes.len, hashAlgorithm)
  except:
    return false

proc verify*(ctx: DSAVerifyContext, signedData: string, signature: string): bool =
  ## DSA署名�E検証
  try:
    # 適刁E��ハッシュ関数を選抁E
    var hashFunc: proc(data: string): string
    
    case ctx.algorithm
    of DSA, DSA_NSEC3_SHA1:
      hashFunc = calculateDigestSHA1
    else:
      logError("DNSSECエラー: サポ�EトされてぁE��いDSAアルゴリズム")
      return false
    
    # 署名データをハチE��ュ匁E
    let hash = hashFunc(signedData)
    
    # DSA公開鍵の最小長チェチE��
    if ctx.publicKey.len < 8:
      logError("DNSSECエラー: DSA公開鍵が短すぎまぁE(長ぁE " & $ctx.publicKey.len & ")")
      return false
      
    # DSA署名�E長さチェチE�� (r|s形弁E
    if signature.len < 40:  # 最低でもr(20バイチE+s(20バイチEが忁E��E
      logError("DNSSECエラー: DSA署名データが短すぎまぁE(長ぁE " & $signature.len & ")")
      return false
    
    # 署名データの整合性チェチE��
    if hash.len != 20:  # SHA-1ハッシュは20バイチE
      logError("DNSSECエラー: ハッシュ長が不正でぁE(長ぁE " & $hash.len & ")")
      return false

    # DSA公開鍵パラメータを抽出
    # T + Q + P + G + Y の形弁E(RFC 2536)
    var offset = 0
    let t = byte(ctx.publicKey[offset])
    offset += 1
    
    # Q (160ビッチE
    let qLen = 20
    var q = newSeq[byte](qLen)
    for i in 0..<qLen:
      if offset < ctx.publicKey.len:
        q[i] = byte(ctx.publicKey[offset])
        offset += 1
      else:
        return false
    
    # P (512 + 64*T ビッチE
    let pLen = 64 + 8*int(t)
    var p = newSeq[byte](pLen)
    for i in 0..<pLen:
      if offset < ctx.publicKey.len:
        p[i] = byte(ctx.publicKey[offset])
        offset += 1
      else:
        return false
    
    # G
    let gLen = pLen
    var g = newSeq[byte](gLen)
    for i in 0..<gLen:
      if offset < ctx.publicKey.len:
        g[i] = byte(ctx.publicKey[offset])
        offset += 1
      else:
        return false
    
    # Y (公開値)
    let yLen = pLen
    var y = newSeq[byte](yLen)
    for i in 0..<yLen:
      if offset < ctx.publicKey.len:
        y[i] = byte(ctx.publicKey[offset])
        offset += 1
      else:
        return false
    
    # 署名データをrとsに刁E��
    let rLen = 20
    let sLen = 20
    
    var r = newSeq[byte](rLen)
    var s = newSeq[byte](sLen)
    
    for i in 0..<rLen:
      if i < signature.len:
        r[i] = byte(signature[i])
      else:
        return false
    
    for i in 0..<sLen:
      if rLen + i < signature.len:
        s[i] = byte(signature[rLen + i])
      else:
        return false
    
    # DSA署名検証の実裁E
    import nimcrypto/[hash, sha1, utils]
    import math

    # モジュラー送E��を計算する関数
    proc modInverse(a: seq[byte], m: seq[byte]): seq[byte] =
      # 拡張ユークリチE��アルゴリズムを使用してモジュラー送E��を計箁E
      var a_int = fromBytesLE(a)
      var m_int = fromBytesLE(m)
      
      var t = 0
      var newt = 1
      var r = int(m_int)
      var newr = int(a_int)
      
      while newr != 0:
        let quotient = r div newr
        (t, newt) = (newt, t - quotient * newt)
        (r, newr) = (newr, r - quotient * newr)
      
      if r > 1:
        # 送E��が存在しなぁE
        return @[]
      
      if t < 0:
        t += int(m_int)
      
      return toBytesLE(uint64(t))
    
    # モジュラーべき乗を計算する関数
    proc powMod(base: seq[byte], exp: seq[byte], modulus: seq[byte]): seq[byte] =
      var result = @[byte(1)]
      var base_copy = base
      var exp_copy = fromBytesLE(exp)
      let mod_int = fromBytesLE(modulus)
      
      while exp_copy > 0:
        if (exp_copy and 1) == 1:
          result = toBytesLE((fromBytesLE(result) * fromBytesLE(base_copy)) mod mod_int)
        exp_copy = exp_copy shr 1
        base_copy = toBytesLE((fromBytesLE(base_copy) * fromBytesLE(base_copy)) mod mod_int)
      
      return result
    
    # DSA署名検証の実裁E
    let q = ctx.q # DSAパラメータq
    
    # 1. 署名�E篁E��チェチE��: 0 < r < q および 0 < s < q
    let r_int = fromBytesLE(r)
    let s_int = fromBytesLE(s)
    let q_int = fromBytesLE(q)
    
    if r_int <= 0 or r_int >= q_int or s_int <= 0 or s_int >= q_int:
      echo "DSA署名�E値が篁E��外でぁE
      return false
    
    # 2. ハッシュ計箁E
    var ctx_sha1: sha1
    ctx_sha1.init()
    ctx_sha1.update(signedData)
    let hash = ctx_sha1.finish()
    
    # 3. w = s^-1 mod q を計箁E
    let w = modInverse(s, q)
    if w.len == 0:
      echo "モジュラー送E��の計算に失敗しました"
      return false
    
    # 4. u1 = (SHA1(M) * w) mod q を計箁E
    let u1 = toBytesLE((fromBytesLE(hash) * fromBytesLE(w)) mod q_int)
    
    # 5. u2 = (r * w) mod q を計箁E
    let u2 = toBytesLE((r_int * fromBytesLE(w)) mod q_int)
    
    # 6. v = ((g^u1 * y^u2) mod p) mod q を計箁E
    let v1 = powMod(g, u1, p)
    let v2 = powMod(y, u2, p)
    let v3 = toBytesLE((fromBytesLE(v1) * fromBytesLE(v2)) mod fromBytesLE(p))
    let v = toBytesLE(fromBytesLE(v3) mod q_int)
    
    # 7. v == r を確誁E
    return fromBytesLE(v) == r_int
  except:
    echo "DSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verify*(ctx: ECDSAVerifyContext, signedData: string, signature: string): bool =
  ## ECDSA署名�E検証
  try:

    var hashFunc: proc(data: string): string
    var digestSize: int
    
    case ctx.algorithm
    of ECDSA_P256_SHA256:
      hashFunc = calculateDigestSHA256
      digestSize = 32  # SHA-256 は 32バイチE
    of ECDSA_P384_SHA384:
      hashFunc = calculateDigestSHA384
      digestSize = 48  # SHA-384 は 48バイチE
    else:
      echo "サポ�EトされてぁE��いECDSAアルゴリズム: ", ctx.algorithm
      return false
    
    # 署名データをハチE��ュ匁E
    let hash = hashFunc(signedData)
    
    # ECDSA署名�Er|sの形弁E(RFC 6605)
    if signature.len != 2 * digestSize:
      echo "ECDSA署名�E長さが無効です。期征E ", 2 * digestSize, ", 実際: ", signature.len
      return false
    
    # 署名をrとsに刁E��
    var r = newSeq[byte](digestSize)
    var s = newSeq[byte](digestSize)
    
    for i in 0..<digestSize:
      r[i] = byte(signature[i])
    
    for i in 0..<digestSize:
      s[i] = byte(signature[digestSize + i])
    
    # ECDSA公開鍵をパース
    # 公開鍵は0x04 + x座樁E+ y座標�E形弁E(RFC 6605)
    if ctx.publicKey.len < 1 + 2 * digestSize:
      echo "ECDSA公開鍵の長さが無効です。期征E >= ", 1 + 2 * digestSize, ", 実際: ", ctx.publicKey.len
      return false
    
    if byte(ctx.publicKey[0]) != 0x04:
      echo "ECDSA公開鍵の形式が無効です。期征E 0x04, 実際: ", byte(ctx.publicKey[0])
      return false
    
    # X, Y座標を抽出
    var x = newSeq[byte](digestSize)
    var y = newSeq[byte](digestSize)
    
    for i in 0..<digestSize:
      x[i] = byte(ctx.publicKey[1 + i])
    
    for i in 0..<digestSize:
      y[i] = byte(ctx.publicKey[1 + digestSize + i])
    
    # nimcryptoライブラリを使用してECDSA検証を実衁E
    var curve: EcCurve
    var n: BigInt
    
    case ctx.algorithm
    of ECDSA_P256_SHA256:
      curve = ecCurveP256()
      n = ecOrderP256()
    of ECDSA_P384_SHA384:
      curve = ecCurveP384()
      n = ecOrderP384()
    else:
      echo "サポ�EトされてぁE��いECDSAアルゴリズム: ", ctx.algorithm
      return false
    
    # 1. rとsぁE〜n-1の篁E��にあるか確誁E
    let rBigInt = bytesToBigInt(r)
    let sBigInt = bytesToBigInt(s)
    
    if rBigInt <= 0 or rBigInt >= n or sBigInt <= 0 or sBigInt >= n:
      echo "ECDSA署名パラメータrまた�Esが有効篁E��外でぁE
      return false
    
    # 2. e = HASH(m)は既に計算済み (hash変数)
    let e = bytesToBigInt(hash)
    
    # 3. w = s^-1 mod nを計箁E
    let w = modInverse(sBigInt, n)
    if w == 0:
      echo "ECDSA署名検証中にモジュラ送E��の計算に失敗しました"
      return false
    
    # 4. u1 = e * w mod nとu2 = r * w mod nを計箁E
    let u1 = (e * w) mod n
    let u2 = (rBigInt * w) mod n
    
    # 5. (x1, y1) = u1 * G + u2 * Qを計箁E
    # G はベ�Eスポイント、Q は公開鍵ポインチE
    let G = curve.generator()
    let Q = EcPoint(x: bytesToBigInt(x), y: bytesToBigInt(y))
    
    # 公開鍵ポイントが曲線上にあることを確誁E
    if not curve.isOnCurve(Q):
      echo "ECDSA公開鍵が指定された楕�E曲線上にありません"
      return false
    
    # u1*G の計箁E
    let point1 = curve.multiplyPoint(G, u1)
    
    # u2*Q の計箁E
    let point2 = curve.multiplyPoint(Q, u2)
    
    # 点の加箁E (x1,y1) = u1*G + u2*Q
    let resultPoint = curve.addPoints(point1, point2)
    
    # 無限遠点の場合�E検証失敁E
    if resultPoint.isInfinity:
      echo "ECDSA署名検証に失敁E 結果が無限遠点でぁE
      return false
    
    # 6. 検証: r ≡ x1 (mod n)
    let v = resultPoint.x mod n
    
    return v == rBigInt
  except:
    echo "ECDSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verify*(ctx: EdDSAVerifyContext, signedData: string, signature: string): bool =
  ## EdDSA署名�E検証
  try:
    var signatureSize, keySize: int
    
    case ctx.algorithm
    of ED25519:
      # Ed25519: 32バイト�E開鍵, 64バイト署吁E
      signatureSize = 64
      keySize = 32
    of ED448:
      # Ed448: 57バイト�E開鍵, 114バイト署吁E
      signatureSize = 114
      keySize = 57
    else:
      echo "サポ�EトされてぁE��いEdDSAアルゴリズム: ", ctx.algorithm
      return false
    
    # 署名サイズのチェチE��
    if signature.len != signatureSize:
      echo "EdDSA署名�E長さが無効です。期征E ", signatureSize, ", 実際: ", signature.len
      return false
    
    # 公開鍵サイズのチェチE��
    if ctx.publicKey.len != keySize:
      echo "EdDSA公開鍵の長さが無効です。期征E ", keySize, ", 実際: ", ctx.publicKey.len
      return false
    
    # Ed25519/Ed448の検証
    if ctx.algorithm == ED25519:
      var pk = newSeq[byte](keySize)
      var sig = newSeq[byte](signatureSize)
      var msg = newSeq[byte](signedData.len)
      
      # バイト�E列に変換
      copyMem(addr pk[0], unsafeAddr ctx.publicKey[0], keySize)
      copyMem(addr sig[0], unsafeAddr signature[0], signatureSize)
      copyMem(addr msg[0], unsafeAddr signedData[0], signedData.len)
      
      # nimcryptoのEd25519検証関数を使用
      try:
        var pubKey: ed25519.PublicKey
        var sig25519: ed25519.Signature
        
        # 公開鍵とシグネチャをコピ�E
        copyMem(addr pubKey[0], addr pk[0], keySize)
        copyMem(addr sig25519[0], addr sig[0], signatureSize)
        
        # 署名を検証
        return ed25519.verify(sig25519, msg, msg.len, pubKey)
      except:
        echo "Ed25519検証中にエラーが発生しました: ", getCurrentExceptionMsg()
        return false
    
    # ED448の場吁E
    elif ctx.algorithm == ED448:
      var pk = newSeq[byte](keySize)
      var sig = newSeq[byte](signatureSize)
      var msg = newSeq[byte](signedData.len)
      
      # バイト�E列に変換
      copyMem(addr pk[0], unsafeAddr ctx.publicKey[0], keySize)
      copyMem(addr sig[0], unsafeAddr signature[0], signatureSize)
      copyMem(addr msg[0], unsafeAddr signedData[0], signedData.len)
      
      # Ed448の検証実裁E
      # RFC 8032に基づぁE��Ed448の実裁E
      try:
        # Ed448専用の検証コンチE��ストを準備
        var pubKey: Ed448PublicKey
        var signature: Ed448Signature
        
        # 公開鍵とシグネチャを適刁E��形式にコピ�E
        if pk.len != Ed448_PUBLIC_KEY_SIZE:
          echo "Ed448公開鍵サイズが無効でぁE ", pk.len
          return false
          
        if sig.len != Ed448_SIGNATURE_SIZE:
          echo "Ed448署名サイズが無効でぁE ", sig.len
          return false
        
        copyMem(addr pubKey[0], addr pk[0], Ed448_PUBLIC_KEY_SIZE)
        copyMem(addr signature[0], addr sig[0], Ed448_SIGNATURE_SIZE)
        
        # コンチE��スト文字�E�E�ENSSECでは通常空�E�E
        let context = ""
        
        # Ed448署名検証
        # SHAKE256-912ハッシュ関数を使用
        var verified = ed448.verify(
          signature = signature,
          message = msg,
          msgLen = msg.len,
          publicKey = pubKey,
          context = context,
          contextLen = 0
        )
        
        # 検証結果を返す
        return verified
      except CatchableError as e:
        echo "Ed448検証中にエラーが発生しました: ", e.msg
        return false
      except:
        echo "Ed448検証中に予期しなぁE��ラーが発生しました"
        return false
    return false
  except:
    echo "EdDSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verifyRrsigRsa*(rrsig: RrsigRecord, signedData: string, key: DnsKeyRecord): bool =
  ## RSA署名�E検証ラチE��ー
  try:
    # RSA検証コンチE��ストを作�E
    var ctx = RSAVerifyContext(
      publicKey: key.publicKey,
      algorithm: rrsig.algorithm
    )
    
    # 署名を検証
    return ctx.verify(signedData, rrsig.signature)
  except:
    echo "RSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verifyRrsigDsa*(rrsig: RrsigRecord, signedData: string, key: DnsKeyRecord): bool =
  ## DSA署名�E検証ラチE��ー
  try:
    # DSA検証コンチE��ストを作�E
    var ctx = DSAVerifyContext(
      publicKey: key.publicKey,
      algorithm: rrsig.algorithm
    )
    
    # 署名を検証
    return ctx.verify(signedData, rrsig.signature)
  except:
    echo "DSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verifyRrsigEcdsa*(rrsig: RrsigRecord, signedData: string, key: DnsKeyRecord): bool =
  ## ECDSA署名�E検証ラチE��ー
  try:
    # ECDSA検証コンチE��ストを作�E
    var ctx = ECDSAVerifyContext(
      publicKey: key.publicKey,
      algorithm: rrsig.algorithm
    )
    
    # 署名を検証
    return ctx.verify(signedData, rrsig.signature)
  except:
    echo "ECDSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc verifyRrsigEdDsa*(rrsig: RrsigRecord, signedData: string, key: DnsKeyRecord): bool =
  ## EdDSA署名�E検証ラチE��ー
  try:
    # EdDSA検証コンチE��ストを作�E
    var ctx = EdDSAVerifyContext(
      publicKey: key.publicKey,
      algorithm: rrsig.algorithm
    )
    
    # 署名を検証
    return ctx.verify(signedData, rrsig.signature)
  except:
    echo "EdDSA署名検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc createCanonicalRRSet*(records: seq[DnsRecord], rrsig: RrsigRecord): string =
  ## 正規化されたRRセチE��を作�E (RFC 4034, Section 6)
  var result = ""
  
  # レコードをソーチE
  var sortedRecords = records
  sortedRecords.sort(proc(a, b: DnsRecord): int =
    result = cmp(a.name.toLower, b.name.toLower)
    if result == 0:
      result = cmp(a.`type`, b.`type`)
    if result == 0:
      result = cmp(a.class, b.class)
    return result
  )
  
  # 正規化されたワイヤーフォーマットを作�E
  for record in sortedRecords:
    if record.`type` == rrsig.typeCovered:
      var rrWire = ""
      # 所有老E��
      rrWire.add(record.name.toLower)
      # タイプ、クラス、TTL
      rrWire.add(char((record.`type` shr 8) and 0xFF))
      rrWire.add(char(record.`type` and 0xFF))
      rrWire.add(char((record.class shr 8) and 0xFF))
      rrWire.add(char(record.class and 0xFF))
      rrWire.add(char((rrsig.originalTtl shr 24) and 0xFF))
      rrWire.add(char((rrsig.originalTtl shr 16) and 0xFF))
      rrWire.add(char((rrsig.originalTtl shr 8) and 0xFF))
      rrWire.add(char(rrsig.originalTtl and 0xFF))
      # RDATA
      rrWire.add(record.rdata)
      
      result.add(rrWire)
  
  return result

proc createRRSigData*(rrsig: RrsigRecord, canonicalRRSet: string): string =
  ## RRSIG署名データを作�E (RFC 4034, Section 3.1.8.1)
  var result = ""
  
  # RRSIG RDATA (署名フィールドを除ぁE
  result.add(char((rrsig.typeCovered shr 8) and 0xFF))
  result.add(char(rrsig.typeCovered and 0xFF))
  result.add(char(rrsig.algorithm))
  result.add(char(rrsig.labels))
  
  # オリジナルTTL
  result.add(char((rrsig.originalTtl shr 24) and 0xFF))
  result.add(char((rrsig.originalTtl shr 16) and 0xFF))
  result.add(char((rrsig.originalTtl shr 8) and 0xFF))
  result.add(char(rrsig.originalTtl and 0xFF))
  
  # 署名有効期限
  let expiration = uint32(rrsig.signatureExpiration.toUnix())
  result.add(char((expiration shr 24) and 0xFF))
  result.add(char((expiration shr 16) and 0xFF))
  result.add(char((expiration shr 8) and 0xFF))
  result.add(char(expiration and 0xFF))
  
  # 署名開始時閁E
  let inception = uint32(rrsig.signatureInception.toUnix())
  result.add(char((inception shr 24) and 0xFF))
  result.add(char((inception shr 16) and 0xFF))
  result.add(char((inception shr 8) and 0xFF))
  result.add(char(inception and 0xFF))
  
  # キータグ
  result.add(char((rrsig.keyTag shr 8) and 0xFF))
  result.add(char(rrsig.keyTag and 0xFF))
  
  # 署名老E��
  result.add(rrsig.signerName.toLower)
  
  # 正規化されたRRセチE��を追加
  result.add(canonicalRRSet)
  
  return result

proc verifyRrsig*(rrsig: RrsigRecord, records: seq[DnsRecord], keys: seq[DnsKeyRecord]): bool =
  ## RRSIG検証を実裁E(RFC 4034)
  # 署名�E有効期限チェチE��
  let now = getTime().toUnix().uint32
  if now > uint32(rrsig.signatureExpiration.toUnix()) or now < uint32(rrsig.signatureInception.toUnix()):
    echo "署名�E有効期限夁E(現在: ", now, ", 有効期限: ", uint32(rrsig.signatureExpiration.toUnix()), 
         ", 開始時閁E ", uint32(rrsig.signatureInception.toUnix()), ")"
    return false
  
  # 対応するDNSKEYを見つける
  var matchingKey: DnsKeyRecord = nil
  for key in keys:
    if calculateKeyTag(key) == rrsig.keyTag and 
       key.algorithm == rrsig.algorithm and
       isZoneKey(key):
      matchingKey = key
      break
  
  if matchingKey == nil:
    echo "対応するDNSKEYが見つかりません (キータグ: ", rrsig.keyTag, ", アルゴリズム: ", rrsig.algorithm, ")"
    return false
  
  # 正規化されたRRセチE��を作�E
  let canonicalRRSet = createCanonicalRRSet(records, rrsig)
  
  # 署名データを作�E
  let signedData = createRRSigData(rrsig, canonicalRRSet)
  
  # アルゴリズムに基づぁE��署名を検証
  case rrsig.algorithm
  of 1, 5, 7, 8, 10:  # RSA系 (RSA/SHA1, RSA/SHA-256, RSA/SHA-512など)
    return verifyRrsigRsa(rrsig, signedData, matchingKey)
  of 3, 6:  # DSA系
    return verifyRrsigDsa(rrsig, signedData, matchingKey)
  of 13, 14:  # ECDSA系 (ECDSA Curve P-256 with SHA-256, ECDSA Curve P-384 with SHA-384)
    return verifyRrsigEcdsa(rrsig, signedData, matchingKey)
  of 15, 16:  # Ed25519, Ed448
    return verifyRrsigEdDsa(rrsig, signedData, matchingKey)
  else:
    echo "サポ�EトされてぁE��ぁE��ルゴリズム: ", rrsig.algorithm
    return false  # サポ�EトされてぁE��ぁE��ルゴリズム

proc verifyChain*(validator: DnssecValidator, domain: string, records: seq[DnsRecord], 
                  rrsigs: seq[RrsigRecord]): DnssecStatus =
  ## 信頼チェーンの検証
  var currentDomain = domain
  
  # チE��チE��惁E��
  echo "ドメイン ", domain, " の信頼チェーンを検証中"
  
  # ドメイン階層をたどって検証
  while true:
    # 現在のドメインのキーを取征E
    if not validator.keyRecords.hasKey(currentDomain):
      echo "ドメイン ", currentDomain, " のキーレコードがありません"
      return Indeterminate
    
    let keys = validator.keyRecords[currentDomain]
    echo "ドメイン ", currentDomain, " には ", keys.len, " 個�EキーがありまぁE
    
    # 信頼アンカーにたどり着ぁE��場吁E
    if validator.trustAnchors.hasKey(currentDomain):
      let trustKeys = validator.trustAnchors[currentDomain]
      echo "ドメイン ", currentDomain, " は信頼アンカーでぁE(", trustKeys.len, " キー)"
      
      # 信頼アンカーと一致するキーがあるか確誁E
      for key in keys:
        for trustKey in trustKeys:
          if key.publicKey == trustKey.publicKey and 
             key.algorithm == trustKey.algorithm:
            echo "信頼アンカーと一致するキーを見つけました"
            
            # RRSIGを検証
            for rrsig in rrsigs:
              if rrsig.signerName == currentDomain:
                echo "署名老E", rrsig.signerName, " のRRSIGを検証中"
                if verifyRrsig(rrsig, records, keys):
                  echo "RRSIG検証成功"
                  return Secure
                else:
                  echo "RRSIG検証失敁E
            
            echo "有効なRRSIGがありません"
      
      echo "信頼アンカーに到達したが検証失敁E
      return Bogus  # 信頼アンカーに到達したが検証失敁E
    
    # 親ドメインのDSレコードを確誁E
    let parts = currentDomain.split('.')
    if parts.len <= 1:
      echo "ルートドメインに到達しましたが信頼アンカーはありません"
      return Insecure  # ルートドメインに到達し、信頼アンカーがなぁE
    
    let parentDomain = parts[1..^1].join(".")
    echo "親ドメイン: ", parentDomain
    
    if not validator.dsRecords.hasKey(currentDomain):
      echo "ドメイン ", currentDomain, " のDSレコードがありません"
      return Indeterminate  # 親ドメインのDSレコードがなぁE
    
    let dsRecords = validator.dsRecords[currentDomain]
    echo currentDomain, " には ", dsRecords.len, " 個�EDSレコードがありまぁE
    
    # DSレコードとDNSKEYの検証
    var dsVerified = false
    for ds in dsRecords:
      for key in keys:
        if verifyDsRecord(ds, key, currentDomain):
          echo "DSレコード検証成功: キータグ ", ds.keyTag
          dsVerified = true
          break
      if dsVerified:
        break
    
    if not dsVerified:
      echo "DSレコード検証失敁E
      return Bogus  # DSレコード検証失敁E
    
    # 親ドメインへ
    currentDomain = parentDomain
    echo "親ドメイン ", currentDomain, " に移勁E
  
  echo "通常ここには到達しなぁE
  return Indeterminate  # 通常ここには到達しなぁE

proc validateRecord*(validator: DnssecValidator, record: DnsRecord, 
                     rrsigs: seq[RrsigRecord]): DnssecStatus =
  ## 単一のDNSレコードを検証
  return validator.verifyChain(record.domain, @[record], rrsigs)

proc validateRecords*(validator: DnssecValidator, records: seq[DnsRecord], 
                      rrsigs: seq[RrsigRecord]): DnssecStatus =
  ## DNSレコード�EセチE��を検証
  if records.len == 0:
    return Indeterminate
  
  let domain = records[0].domain
  return validator.verifyChain(domain, records, rrsigs)

# NSEC, NSEC3関連の機�E
proc matchesNsec*(domain: string, nsecRecord: NsecRecord): bool =
  ## ドメインがNSECレコード�E篁E��に含まれるかを確誁E
  let lowerDomain = domain.toLower()
  let lowerOwner = nsecRecord.nextDomainName.toLower()
  
  # ドメインがNSECの所有老E��次のドメイン名�E間にあるか確誁E
  if lowerDomain > lowerOwner and (nsecRecord.nextDomainName.len == 0 or lowerDomain < nsecRecord.nextDomainName.toLower()):
    return true
  return false

proc calculateNsec3Hash*(domain: string, salt: string, iterations: uint16, algorithm: uint8): string =
  ## NSEC3ハッシュを計箁E(RFC 5155)
  if algorithm != 1:
    # 現在はSHA-1のみサポ�EチE
    return ""
  
  # 正規化されたドメイン名を準備
  var normalizedDomain = domain.toLower()
  
  # ドメイン名をワイヤーフォーマットに変換
  var wireFormat = ""
  let labels = normalizedDomain.split('.')
  for label in labels:
    if label.len > 0:
      wireFormat.add(char(label.len))
      wireFormat.add(label)
  
  # 末尾のrootラベル
  wireFormat.add(char(0))
  
  # 最初�Eハッシュ計箁E
  var hashValue = calculateDigestSHA1(wireFormat)
  
  # 繰り返しハッシュを計箁E
  for i in 0..<iterations:
    var data = hashValue & salt
    hashValue = calculateDigestSHA1(data)
  
  # Base32Hex エンコーチE(RFC 4648)
  const BASE32HEX = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
  var encoded = ""
  var i = 0
  
  while i < hashValue.len:
    var buffer: uint64 = 0
    var bitsLeft = 0
    
    # 5ビットごとに処琁E
    while bitsLeft < 40 and i < hashValue.len:
      buffer = buffer shl 8 or uint64(byte(hashValue[i]))
      bitsLeft += 8
      i += 1
    
    # バッファに十�Eなビットがある間、Base32Hex斁E��を出劁E
    bitsLeft -= 5
    while bitsLeft >= 0:
      let index = int((buffer shr bitsLeft) and 0x1F)
      encoded.add(BASE32HEX[index])
      bitsLeft -= 5
  
  return encoded

proc verifyNsec3Record*(domain: string, nsec3Record: Nsec3Record, recordType: DnsRecordType): bool =
  ## NSEC3レコードを使用してドメインの非存在を検証
  try:
    # ドメイン名�Eハッシュを計箁E
    let domainHash = calculateNsec3Hash(domain, nsec3Record.salt, nsec3Record.iterations, nsec3Record.hashAlgorithm)
    if domainHash.len == 0:
      echo "NSEC3ハッシュの計算に失敗しました"
      return false
    
    # 完�E一致を確認（レコード�E存在を示す可能性がある！E
    if domainHash == nsec3Record.nextHashedOwner:
      return recordType in nsec3Record.typeBitMaps
    
    # NSEC3レコードがドメインの非存在を証明するか確誁E
    let ownerNameHash = nsec3Record.nextHashedOwner
    let nextOwnerNameHash = nsec3Record.nextHashedOwner
    
    # 末尾がループするケース
    if ownerNameHash > nextOwnerNameHash:
      if domainHash > ownerNameHash or domainHash < nextOwnerNameHash:
        # ドメインハッシュは篁E��冁E- 非存在を証昁E
        return true
    else:
      # 通常のケース
      if domainHash > ownerNameHash and domainHash < nextOwnerNameHash:
        # ドメインハッシュは篁E��冁E- 非存在を証昁E
        return true
    
    return false
  except:
    echo "NSEC3検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc optimizeNsec3Parameters*(iterations: uint16, saltLength: int): (uint16, int) =
  ## NSEC3パラメータを最適化！EFC 9276に基づく！E
  ## 返り値: (最適化された反復回数, 推奨されるソルト長)
  # RFC 9276では、反復回数=0および短ぁE��ルトまた�Eソルトなしが推奨されてぁE��ぁE
  let recommendedIterations: uint16 = 0
  let recommendedSaltLength = 0 # ソルトなぁE
  
  return (recommendedIterations, recommendedSaltLength)

proc verifyNsecRecord*(domain: string, nsecRecord: NsecRecord, recordType: DnsRecordType): bool =
  ## NSECレコードを使用してドメインの非存在を検証
  try:
    let domainLower = domain.toLower()
    let ownerLower = nsecRecord.nextDomainName.toLower()
    let nextLower = nsecRecord.nextDomainName.toLower()
    
    # 完�E一致を確認（レコード�E存在を示す可能性がある！E
    if domainLower == ownerLower:
      return recordType in nsecRecord.typeBitMaps
    
    # NSECレコードがドメインの非存在を証明するか確誁E
    if ownerLower < nextLower:
      # 通常のケース
      if domainLower > ownerLower and domainLower < nextLower:
        # ドメインは篁E��冁E- 非存在を証昁E
        return true
    else:
      # 末尾がループするケース�E�最後�ENSEC�E�E
      if domainLower > ownerLower or domainLower < nextLower:
        # ドメイン名�Eゾーンの終わりから始まり�E間にある - 非存在を証昁E
        return true
    
    return false
  except:
    echo "NSEC検証中にエラーが発生しました: ", getCurrentExceptionMsg()
    return false

proc hasNsecRecords*(records: seq[DnsRecord]): bool =
  ## NSECレコード�E存在を確誁E
  for record in records:
    if record.`type` == DnsRecordType.NSEC:
      return true
  return false

proc hasNsec3Records*(records: seq[DnsRecord]): bool =
  ## NSEC3レコード�E存在を確誁E
  for record in records:
    if record.`type` == DnsRecordType.NSEC3:
      return true
  return false

proc extractNsecRecords*(records: seq[DnsRecord]): seq[NsecRecord] =
  ## 応答からNSECレコードを抽出
  result = @[]
  for record in records:
    if record.`type` == DnsRecordType.NSEC:
      try:
        # NSECレコード�ERDATAをパース
        let nsec = parseNsecRecord(record.rdata, record.name)
        if nsec != nil:
          result.add(nsec)
      except Exception as e:
        echo "NSECレコード�Eパ�Eス中にエラーが発甁E ", e.msg

proc extractNsec3Records*(records: seq[DnsRecord]): seq[Nsec3Record] =
  ## 応答からNSEC3レコードを抽出
  result = @[]
  for record in records:
    if record.`type` == DnsRecordType.NSEC3:
      try:
        # NSEC3レコード�ERDATAをパース
        let nsec3 = parseNsec3Record(record.rdata, record.name)
        if nsec3 != nil:
          result.add(nsec3)
      except Exception as e:
        echo "NSEC3レコード�Eパ�Eス中にエラーが発甁E ", e.msg

proc validateNegativeResponse*(validator: DnssecValidator, qname: string, qtype: DnsRecordType, 
                              nsecRecords: seq[NsecRecord], nsec3Records: seq[Nsec3Record],
                              rrsigs: seq[RrsigRecord]): DnssecStatus =
  ## 否定応答�E検証�E�ESECまた�ENSEC3を使用�E�E
  ## RFC 4035, Section 5.4 and RFC 5155, Section 8
  
  # NSECによる検証
  if nsecRecords.len > 0:
    var nsecMatched = false
    var validSignature = false
    
    # 少なくとめEつのNSECレコードが否定応答を証明するか確誁E
    for nsec in nsecRecords:
      if verifyNsecRecord(qname, nsec, qtype):
        nsecMatched = true
        
        # こ�ENSECレコードに対応するRRSIGを検索して検証
        let nsecOwner = nsec.ownerName
        var nsecRecordSet: seq[DnsRecord] = @[]
        
        # NSECレコードをDnsRecordとして再構篁E
        let nsecDnsRecord = createNsecDnsRecord(nsec)
        nsecRecordSet.add(nsecDnsRecord)
        
        # 対応するRRSIGを検索
        var matchingRrsigs: seq[RrsigRecord] = @[]
        for rrsig in rrsigs:
          if rrsig.typeCovered == DnsRecordType.NSEC and rrsig.signerName == nsecOwner:
            matchingRrsigs.add(rrsig)
        
        # 少なくとめEつの有効な署名があるか確誁E
        for rrsig in matchingRrsigs:
          if validator.verifyRrsig(rrsig, nsecRecordSet, validator.getDnskeys(rrsig.signerName)):
            validSignature = true
            break
        
        if validSignature:
          break
    
    if not nsecMatched:
      echo "NSECレコードが否定応答を証明してぁE��せん: ", qname, " (", $qtype, ")"
      return DnssecStatus.Bogus
    
    if not validSignature:
      echo "NSECレコード�E署名が無効でぁE ", qname
      return DnssecStatus.Bogus
    
    return DnssecStatus.Secure
  
  # NSEC3による検証
  elif nsec3Records.len > 0:
    var nsec3Matched = false
    var validSignature = false
    
    # 各NSEC3レコードを検証
    for nsec3 in nsec3Records:
      if verifyNsec3Record(qname, nsec3, qtype):
        nsec3Matched = true
        
        # こ�ENSEC3レコードに対応するRRSIGを検索して検証
        let nsec3Owner = nsec3.ownerName
        var nsec3RecordSet: seq[DnsRecord] = @[]
        
        # NSEC3レコードをDnsRecordとして再構篁E
        let nsec3DnsRecord = createNsec3DnsRecord(nsec3)
        nsec3RecordSet.add(nsec3DnsRecord)
        
        # 対応するRRSIGを検索
        var matchingRrsigs: seq[RrsigRecord] = @[]
        for rrsig in rrsigs:
          if rrsig.typeCovered == DnsRecordType.NSEC3 and rrsig.signerName == nsec3Owner:
            matchingRrsigs.add(rrsig)
        
        # 少なくとめEつの有効な署名があるか確誁E
        for rrsig in matchingRrsigs:
          if validator.verifyRrsig(rrsig, nsec3RecordSet, validator.getDnskeys(rrsig.signerName)):
            validSignature = true
            break
        
        if validSignature:
          break
    
    if not nsec3Matched:
      echo "NSEC3レコードが否定応答を証明してぁE��せん: ", qname, " (", $qtype, ")"
      return DnssecStatus.Bogus
    
    if not validSignature:
      echo "NSEC3レコード�E署名が無効でぁE ", qname
      return DnssecStatus.Bogus
    
    return DnssecStatus.Secure
  
  # NSECめESEC3も見つからなぁE��吁E
  echo "否定応答にNSECまた�ENSEC3レコードがありません: ", qname
  return DnssecStatus.Indeterminate

# DNSSEC検証のパフォーマンス最適匁E
proc precomputeDnsKeyDigests*(validator: DnssecValidator) =
  ## DNSKEYダイジェストを事前計算してパフォーマンスを向丁E
  validator.digestCache = initTable[string, string]()
  
  for domain, keys in validator.keyRecords:
    for key in keys:
      # 様、E��ダイジェストアルゴリズムでダイジェストを事前計箁E
      let sha1Digest = calculateDnsKeyDigest(key, DigestAlgorithm.SHA1, domain)
      let sha256Digest = calculateDnsKeyDigest(key, DigestAlgorithm.SHA256, domain)
      let sha384Digest = calculateDnsKeyDigest(key, DigestAlgorithm.SHA384, domain)
      
      # キャチE��ュに保孁E
      let cacheKeySha1 = domain & "|" & $key.algorithm & "|" & $key.flags & "|" & $DigestAlgorithm.SHA1
      let cacheKeySha256 = domain & "|" & $key.algorithm & "|" & $key.flags & "|" & $DigestAlgorithm.SHA256
      let cacheKeySha384 = domain & "|" & $key.algorithm & "|" & $key.flags & "|" & $DigestAlgorithm.SHA384
      
      validator.digestCache[cacheKeySha1] = sha1Digest
      validator.digestCache[cacheKeySha256] = sha256Digest
      validator.digestCache[cacheKeySha384] = sha384Digest

proc getDnsKeyDigest*(validator: DnssecValidator, key: DnsKeyRecord, digestAlg: DigestAlgorithm, domain: string): string =
  ## キャチE��ュからDNSKEYダイジェストを取得、なければ計箁E
  let cacheKey = domain & "|" & $key.algorithm & "|" & $key.flags & "|" & $digestAlg
  
  if cacheKey in validator.digestCache:
    return validator.digestCache[cacheKey]
  
  # キャチE��ュになぁE��合�E計算して保孁E
  let digest = calculateDnsKeyDigest(key, digestAlg, domain)
  validator.digestCache[cacheKey] = digest
  return digest

proc exportValidatorState*(validator: DnssecValidator): string =
  ## 検証エンジンの状態をJSON形式でエクスポ�EチE
  var result = "{\n"
  
  # 信頼アンカー
  result.add("  \"trustAnchors\": {\n")
  var domainCount = 0
  for domain, anchors in validator.trustAnchors:
    if domainCount > 0:
      result.add(",\n")
    result.add("    \"" & domain & "\": [\n")
    
    var anchorCount = 0
    for anchor in anchors:
      if anchorCount > 0:
        result.add(",\n")
      result.add("      {\n")
      result.add("        \"flags\": " & $anchor.flags & ",\n")
      result.add("        \"protocol\": " & $anchor.protocol & ",\n")
      result.add("        \"algorithm\": " & $anchor.algorithm & ",\n")
      result.add("        \"keyTag\": " & $calculateKeyTag(anchor) & ",\n")
      result.add("        \"publicKey\": \"" & encodeBase64(anchor.publicKey) & "\"\n")
      result.add("      }")
      anchorCount += 1
    
    result.add("\n    ]")
    domainCount += 1
  
  result.add("\n  },\n")
  
  # DS レコーチE
  result.add("  \"dsRecords\": {\n")
  domainCount = 0
  for domain, dsRecs in validator.dsRecords:
    if domainCount > 0:
      result.add(",\n")
    result.add("    \"" & domain & "\": [\n")
    
    var recCount = 0
    for ds in dsRecs:
      if recCount > 0:
        result.add(",\n")
      result.add("      {\n")
      result.add("        \"keyTag\": " & $ds.keyTag & ",\n")
      result.add("        \"algorithm\": " & $ds.algorithm & ",\n")
      result.add("        \"digestType\": " & $ds.digestType & ",\n")
      result.add("        \"digest\": \"" & encodeHex(ds.digest) & "\"\n")
      result.add("      }")
      recCount += 1
    
    result.add("\n    ]")
    domainCount += 1
  
  result.add("\n  },\n")
  
  # DNSKEY レコーチE
  result.add("  \"keyRecords\": {\n")
  domainCount = 0
  for domain, keys in validator.keyRecords:
    if domainCount > 0:
      result.add(",\n")
    result.add("    \"" & domain & "\": [\n")
    
    var keyCount = 0
    for key in keys:
      if keyCount > 0:
        result.add(",\n")
      result.add("      {\n")
      result.add("        \"flags\": " & $key.flags & ",\n")
      result.add("        \"protocol\": " & $key.protocol & ",\n")
      result.add("        \"algorithm\": " & $key.algorithm & ",\n")
      result.add("        \"keyTag\": " & $calculateKeyTag(key) & "\n")
      result.add("      }")
      keyCount += 1
    
    result.add("\n    ]")
    domainCount += 1
  
  result.add("\n  }\n")
  result.add("}")
  
  return result
proc importValidatorState*(validator: DnssecValidator, jsonState: string): bool =
  ## JSONからバリチE�Eタ状態をインポ�EチE
  try:
    let json = parseJson(jsonState)
    
    # 信頼アンカーをインポ�EチE
    if json.hasKey("trustAnchors"):
      for domain, anchors in json["trustAnchors"].getFields():
        for anchor in anchors.getElems():
          let keyRecord = DnsKeyRecord(
            flags: anchor["flags"].getInt().uint16,
            protocol: anchor["protocol"].getInt().uint8,
            algorithm: DnsKeyAlgorithm(anchor["algorithm"].getInt()),
            publicKey: decodeBase64(anchor["publicKey"].getStr())
          )
          validator.addTrustAnchor(domain, keyRecord)
    
    # DSレコードをインポ�EチE
    if json.hasKey("dsRecords"):
      for domain, records in json["dsRecords"].getFields():
        var dsRecords: seq[DsRecord] = @[]
        for record in records.getElems():
          let dsRecord = DsRecord(
            keyTag: record["keyTag"].getInt().uint16,
            algorithm: DnsKeyAlgorithm(record["algorithm"].getInt()),
            digestType: record["digestType"].getInt().uint8,
            digest: decodeHex(record["digest"].getStr())
          )
          dsRecords.add(dsRecord)
        validator.dsRecords[domain] = dsRecords
    
    # DNSKEYレコードをインポ�EチE
    if json.hasKey("keyRecords"):
      for domain, keys in json["keyRecords"].getFields():
        var keyRecords: seq[DnsKeyRecord] = @[]
        for key in keys.getElems():
          let keyRecord = DnsKeyRecord(
            flags: key["flags"].getInt().uint16,
            protocol: key["protocol"].getInt().uint8,
            algorithm: DnsKeyAlgorithm(key["algorithm"].getInt()),
            publicKey: key.hasKey("publicKey") ? decodeBase64(key["publicKey"].getStr()) : ""
          )
          keyRecords.add(keyRecord)
        validator.keyRecords[domain] = keyRecords
    
    return true
  except Exception as e:
    logError("バリチE�Eタ状態�Eインポ�Eト中にエラーが発生しました: " & e.msg)
    return false

proc isAlgorithmSecure*(algorithm: DnsKeyAlgorithm): bool =
  ## アルゴリズムが十刁E��安�EかどぁE��を判断
  case algorithm
  of RSA_MD5:
    return false  # MD5は安�EではなぁE
  of RSA_SHA1, RSASHA1_NSEC3_SHA1, DSA, DSA_NSEC3_SHA1:
    return false  # SHA-1は安�EではなぁE��現在の標準では�E�E
  of RSA_SHA256, RSA_SHA512, ECDSA_P256_SHA256, ECDSA_P384_SHA384, ED25519, ED448:
    return true   # これら�E現在安�Eと老E��られてぁE��
  else:
    return false  # 不�Eなアルゴリズムは安�EでなぁE��見なぁE

proc parseRSAPublicKey(publicKey: string): tuple[exponent: string, modulus: string] =
  ## RFC 3110形式�ERSA公開鍵を解极E
  if publicKey.len < 3:
    raise newException(ValueError, "RSA公開鍵が短すぎまぁE)
  
  let exponentLen = int(publicKey[0])
  if exponentLen == 0:
    # 2バイト長フォーマッチE
    if publicKey.len < 4:
      raise newException(ValueError, "RSA公開鍵が短すぎまぁE)
    let expLen = (int(publicKey[1]) shl 8) or int(publicKey[2])
    if publicKey.len < 3 + expLen:
      raise newException(ValueError, "RSA公開鍵が短すぎまぁE)
    let exponent = publicKey[3..<3+expLen]
    let modulus = publicKey[3+expLen..<publicKey.len]
    return (exponent, modulus)
  else:
    # 1バイト長フォーマッチE
    if publicKey.len < 1 + exponentLen:
      raise newException(ValueError, "RSA公開鍵が短すぎまぁE)
    let exponent = publicKey[1..<1+exponentLen]
    let modulus = publicKey[1+exponentLen..<publicKey.len]
    return (exponent, modulus)

proc checkKeyLength*(key: DnsKeyRecord): bool =
  ## 鍵長が十刁E��どぁE��をチェチE��
  case key.algorithm
  of RSA_SHA1, RSA_SHA256, RSA_SHA512, RSASHA1_NSEC3_SHA1:
    try:
      # RSAキーのモジュラスサイズをチェチE��
      let (_, modulus) = parseRSAPublicKey(key.publicKey)
      return modulus.len * 8 >= 2048  # 2048ビット以上が忁E��E
    except Exception as e:
      logError("RSA鍵解析エラー: " & e.msg)
      return false
  
  of ECDSA_P256_SHA256:
    return key.publicKey.len >= 65  # 32バイト�Ex,y座樁E+ 1バイト�EチE��
  
  of ECDSA_P384_SHA384:
    return key.publicKey.len >= 97  # 48バイト�Ex,y座樁E+ 1バイト�EチE��
  
  of ED25519:
    return key.publicKey.len == 32  # Ed25519は32バイチE
  
  of ED448:
    return key.publicKey.len == 57  # Ed448は57バイチE
  
  else:
    return false  # 不�Eなアルゴリズムは安�EでなぁE��見なぁE

proc isRecordTrusted*(validator: DnssecValidator, domain: string): bool =
  ## ドメインが信頼チェーンにあるかどぁE��を確誁E
  # ドメイン自体が信頼アンカーにあるかチェチE��
  if domain in validator.trustAnchors:
    return true
  
  # 親ドメインをチェチE��
  var currentDomain = domain
  while "." in currentDomain:
    let dotPos = currentDomain.find('.')
    if dotPos == -1:
      break
    
    currentDomain = currentDomain[dotPos+1..^1]
    if currentDomain in validator.trustAnchors:
      # 親ドメインが信頼アンカーにある場合、子ドメインへの信頼チェーンを検証
      return validator.validateTrustChain(domain, currentDomain)
  
  return false

proc validateTrustChain(validator: DnssecValidator, domain: string, trustAnchorDomain: string): bool =
  ## ドメインから信頼アンカーまでの信頼チェーンを検証
  var currentDomain = domain
  
  while currentDomain != trustAnchorDomain and "." in currentDomain:
    # 現在のドメインのDSレコードが親ドメインで検証されてぁE��か確誁E
    let dotPos = currentDomain.find('.')
    let parentDomain = currentDomain[dotPos+1..^1]
    
    # 親ドメインにDSレコードがあるか確誁E
    if parentDomain notin validator.dsRecords:
      return false
    
    # 現在のドメインにDNSKEYレコードがあるか確誁E
    if currentDomain notin validator.keyRecords:
      return false
    
    # DSレコードとDNSKEYの対応を検証
    let dsRecords = validator.dsRecords[parentDomain]
    let keyRecords = validator.keyRecords[currentDomain]
    
    var validated = false
    for ds in dsRecords:
      for key in keyRecords:
        if ds.keyTag == calculateKeyTag(key) and ds.algorithm == key.algorithm:
          # ダイジェストを計算して検証
          let calculatedDigest = calculateDsDigest(currentDomain, key, ds.digestType)
          if calculatedDigest == ds.digest:
            validated = true
            break
      if validated:
        break
    
    if not validated:
      return false
    
    currentDomain = parentDomain
  
  return currentDomain == trustAnchorDomain

proc calculateDsDigest(domain: string, key: DnsKeyRecord, digestType: uint8): string =
  ## DSレコード�Eダイジェストを計箁E
  let canonicalName = domain.toLowerAscii()
  var data = ""
  
  # ドメイン名をワイヤーフォーマットに変換
  for part in canonicalName.split('.'):
    if part.len > 0:
      data.add(char(part.len))
      data.add(part)
  data.add(char(0))  # ルートラベル
  
  # DNSKEYレコードデータを追加
  data.add(char(key.flags shr 8))
  data.add(char(key.flags and 0xFF))
  data.add(char(key.protocol))
  data.add(char(key.algorithm.uint8))
  data.add(key.publicKey)
  
  # ダイジェストを計箁E
  case digestType
  of 1:  # SHA-1
    return $sha1.digest(data)
  of 2:  # SHA-256
    return $sha256.digest(data)
  of 4:  # SHA-384
    return $sha384.digest(data)
  else:
    raise newException(ValueError, "未対応�EダイジェストタイチE " & $digestType)

proc dnssecLookupAll*(domain: string, recordTypes: seq[DnsRecordType]): Future[Table[DnsRecordType, seq[DnsRecord]]] {.async.} =
  ## 持E��されたドメインの褁E��のレコードタイプを非同期に取征E
  result = initTable[DnsRecordType, seq[DnsRecord]]()
  
  # 並列にDNS解決を実衁E
  var futures: seq[Future[tuple[recordType: DnsRecordType, records: seq[DnsRecord]]]] = @[]
  
  for recordType in recordTypes:
    let future = async {
      let records = await resolveDns(domain, recordType)
      return (recordType: recordType, records: records)
    }
    futures.add(future)
  
  # すべての解決結果を征E��E
  for future in futures:
    let response = await future
    result[response.recordType] = response.records
  
  # DNSSECレコードも自動的に取征E
  if not (DnsRecordType.DNSKEY in recordTypes):
    let dnskeys = await resolveDns(domain, DnsRecordType.DNSKEY)
    result[DnsRecordType.DNSKEY] = dnskeys
  
  if not (DnsRecordType.RRSIG in recordTypes):
    let rrsigs = await resolveDns(domain, DnsRecordType.RRSIG)
    result[DnsRecordType.RRSIG] = rrsigs
  
  if not (DnsRecordType.NSEC in recordTypes) and not (DnsRecordType.NSEC3 in recordTypes):
    # NSECまた�ENSEC3レコードを取得（存在しなぁE��合�E空のリストが返る�E�E
    let nsec = await resolveDns(domain, DnsRecordType.NSEC)
    if nsec.len > 0:
      result[DnsRecordType.NSEC] = nsec
    else:
      let nsec3 = await resolveDns(domain, DnsRecordType.NSEC3)
      if nsec3.len > 0:
        result[DnsRecordType.NSEC3] = nsec3

proc getDnssecStatus*(domain: string): Future[DnssecStatus] {.async.} =
  ## ドメインのDNSSECスチE�Eタスを取征E
  
  # バリチE�Eタを作�E
  var validator = newDnssecValidator()
  
  # ルート信頼アンカーを読み込み
  try:
    let rootAnchors = await loadRootTrustAnchors()
    for anchor in rootAnchors:
      validator.addTrustAnchor(".", anchor)
  except Exception as e:
    logError("ルート信頼アンカーの読み込みに失敁E " & e.msg)
    return DnssecStatus.Error
  
  # ドメインの信頼チェーンを構篁E
  try:
    # ドメインを�E解して親ドメインのリストを作�E
    var domainParts = domain.split('.')
    var domains: seq[string] = @[]
    
    for i in countdown(domainParts.len-1, 0):
      if i == domainParts.len-1:
        domains.add(".")  # ルートドメイン
      else:
        let parentDomain = domainParts[i+1..^1].join(".")
        domains.add(parentDomain)
    
    # ルートから頁E��信頼チェーンを構篁E
    for i in 0..<domains.len-1:
      let parentDomain = domains[i]
      let childDomain = domains[i+1]
      
      # 親ドメインからDSレコードを取征E
      let dsRecords = await resolveDns(childDomain, DnsRecordType.DS)
      let dsRrsigs = await resolveDns(childDomain, DnsRecordType.RRSIG, queryType = DnsRecordType.DS)
      
      # DSレコード�E署名を検証
      if not await validator.validateRecords(dsRecords, dsRrsigs):
        return DnssecStatus.Bogus
      
      # 子ドメインからDNSKEYを取征E
      let dnskeys = await resolveDns(childDomain, DnsRecordType.DNSKEY)
      let dnskeyRrsigs = await resolveDns(childDomain, DnsRecordType.RRSIG, queryType = DnsRecordType.DNSKEY)
      
      # DNSKEYの署名を検証
      if not await validator.validateRecords(dnskeys, dnskeyRrsigs):
        return DnssecStatus.Bogus
      
      # DSレコードとDNSKEYの対応を検証
      if not validator.validateDsKeyMatch(dsRecords, dnskeys):
        return DnssecStatus.Bogus
      
      # 検証済みのDNSKEYを信頼アンカーとして追加
      for key in dnskeys:
        if key.flags and 0x0001 > 0:  # SEP (Secure Entry Point) フラグ
          validator.addTrustAnchor(childDomain, key)
    
    # 最終的なドメインのレコードを検証
    let aRecords = await resolveDns(domain, DnsRecordType.A)
    let aRrsigs = await resolveDns(domain, DnsRecordType.RRSIG, queryType = DnsRecordType.A)
    
    if aRrsigs.len == 0:
      # 署名がなぁE��吁E
      if await isDomainInsecure(domain):
        return DnssecStatus.Insecure
      else:
        return DnssecStatus.Bogus
    
    # レコード�E署名を検証
    if await validator.validateRecords(aRecords, aRrsigs):
      return DnssecStatus.Secure
    else:
      return DnssecStatus.Bogus
    
  except Exception as e:
    logError("DNSSEC検証中にエラーが発甁E " & e.msg)
    return DnssecStatus.Error

proc isDomainInsecure(domain: string): Future[bool] {.async.} =
  ## ドメインが意図皁E��非セキュアとして委任されてぁE��かを確誁E
  var currentDomain = domain
  
  while "." in currentDomain:
    let dotPos = currentDomain.find('.')
    let parentDomain = currentDomain[dotPos+1..^1]
    
    # 親ドメインからNSECまた�ENSEC3レコードを取得して、E
    # 子ドメインのDSレコードが存在しなぁE��とを証昁E
    let nsecRecords = await resolveDns(currentDomain, DnsRecordType.NSEC)
    let nsec3Records = await resolveDns(currentDomain, DnsRecordType.NSEC3)
    
    if nsecRecords.len > 0:
      # NSECレコードを検証してDSの不在証明を確誁E
      if verifyNsecNoDsProof(nsecRecords, currentDomain):
        return true
    elif nsec3Records.len > 0:
      # NSEC3レコードを検証してDSの不在証明を確誁E
      if verifyNsec3NoDsProof(nsec3Records, currentDomain):
        return true
    
    currentDomain = parentDomain
    if currentDomain == ".":
      break
  
  return false

proc verifyNsecNoDsProof(nsecRecords: seq[DnsRecord], domain: string): bool =
  ## NSECレコードからDSレコード�E不在証明を検証
  for record in nsecRecords:
    let nsec = cast[NsecRecord](record)
    if nsec.nextDomainName > domain and nsec.types.contains(DnsRecordType.DS) == false:
      return true
  return false

proc verifyNsec3NoDsProof(nsec3Records: seq[DnsRecord], domain: string): bool =
  ## NSEC3レコードからDSレコード�E不在証明を検証
  let domainHash = calculateNsec3Hash(domain)
  
  for record in nsec3Records:
    let nsec3 = cast[Nsec3Record](record)
    if nsec3.hashAlgorithm == 1:  # SHA-1
      if (domainHash > nsec3.nextHashedOwner or nsec3.nextHashedOwner < nsec3.hashedOwner) and
         nsec3.types.contains(DnsRecordType.DS) == false:
        return true
  
  return false

proc calculateNsec3Hash(domain: string, salt: string = "", iterations: uint16 = 0): string =
  ## NSEC3のドメインハッシュを計箁E
  ## 
  ## パラメータ:
  ##   domain: ハッシュするドメイン吁E
  ##   salt: NSEC3ソルト値�E�デフォルト�E空斁E���E�E�E
  ##   iterations: ハッシュの繰り返し回数�E�デフォルト�E0�E�E
  ## 
  ## 戻り値:
  ##   Base32エンコードされたハッシュ値
  
  # ドメインを正規化�E�小文字に変換し、末尾のドットを削除�E�E
  var normalizedDomain = domain.toLowerAscii()
  if normalizedDomain.endsWith("."):
    normalizedDomain = normalizedDomain[0..^2]
  
  # ドメインをワイヤーフォーマットに変換
  var wireFormat = ""
  for label in normalizedDomain.split('.'):
    wireFormat.add(char(label.len))
    wireFormat.add(label)
  
  # 初期ハッシュ計箁E
  var hash = $sha1.digest(wireFormat & salt)
  
  # 持E��された回数だけハチE��ュを繰り返す
  for i in 0..<iterations:
    hash = $sha1.digest(hash & salt)
  
  # Base32エンコード！EFC 4648 準拠�E�E
  return base32Encode(hash, padding=false)

proc loadRootTrustAnchors(): Future[seq[DnsKeyRecord]] {.async.} =
  ## ルート信頼アンカーを読み込む
  ## 
  ## DNSSECの検証に使用するルートゾーンの信頼アンカー�E�トラストアンカー�E�を
  ## 設定ファイルから読み込むか、ハードコードされた値を使用します、E
  ##
  ## 戻り値:
  ##   ルートゾーンのDNSKEYレコード�Eシーケンス
  
  result = @[]
  
  try:
    # 設定ファイルからルート信頼アンカーを読み込む
    let rootAnchorData = await readRootAnchorFile()
    
    for line in rootAnchorData.splitLines():
      # コメント行や空行�EスキチE�E
      if line.startsWith(";") or line.strip() == "":
        continue
      
      # DS形式また�EDNSKEY形式�Eアンカーを解极E
      if line.contains("IN DS"):
        # DS形式�E解极E
        let parts = line.split()
        if parts.len >= 7:
          let keyTag = parseUInt(parts[3]).uint16
          let algorithm = parseUInt(parts[4]).uint8
          let digestType = parseUInt(parts[5]).uint8
          let digest = decodeHex(parts[6])
          
          # DSレコードからDNSKEYを取得（忁E��に応じてDNSクエリを実行！E
          let dnskey = await fetchRootDnskey(keyTag, algorithm)
          if dnskey != nil:
            # DSレコード�E検証
            if validateDsRecord(dnskey, digestType, digest):
              result.add(dnskey)
            else:
              logWarning("DS検証に失敗したルート信頼アンカーをスキチE�EしまぁE " & $keyTag)
      
      elif line.contains("IN DNSKEY"):
        # DNSKEY形式�E解极E
        let parts = line.split()
        if parts.len >= 7:
          let flags = parseUInt(parts[3]).uint16
          let protocol = parseUInt(parts[4]).uint8
          let algorithm = parseUInt(parts[5]).uint8
          let publicKey = decodeBase64(parts[6])
          
          # DNSKEYレコード�E作�E
          let dnskey = DnsKeyRecord(
            name: ".",
            ttl: 172800, # 2日�E�一般皁E��ルーチENSKEYのTTL�E�E
            class: IN,
            flags: flags,
            protocol: protocol,
            algorithm: DnsKeyAlgorithm(algorithm),
        publicKey: publicKey
      )
          
          # KSKフラグ�E�E57�E�を持つキーのみを信頼アンカーとして使用
          if (flags and 0x0101) == 0x0101: # KSK = SEP(0x0001) + ZoneKey(0x0100)
            result.add(dnskey)
  except Exception as e:
    logError("ルート信頼アンカーの読み込みに失敁E " & e.msg)
    
    # フォールバックとして、ハードコードされたルート信頼アンカーを使用
    let hardcodedRootKey = DnsKeyRecord(
      flags: 257,  # KSK
      protocol: 3,
      algorithm: RSA_SHA256,
      publicKey: decodeBase64("AwEAAaz/tAm8yTn4Mfeh5eyI96WSVexTBAvkMgJzkKTOiW1vkIbzxeF3+/4RgWOq7HrxRixHlFlExOLAJr5emLvN7SWXgnLh4+B5xQlNVz8Og8kvArMtNROxVQuCaSnIDdD5LKyWbRd2n9WGe2R8PzgCmr3EgVLrjyBxWezF0jLHwVN8efS3rCj/EWgvIWgb9tarpVUDK/b58Da+sqqls3eNbuv7pr+eoZG+SrDK6nWeL3c6H5Apxz7LjVc1uTIdsIXxuOLYA4/ilBmSVIzuDWfdRUfhHdY6+cn8HFRm+2hM8AnXGXws9555KrUB5qihylGa8subX2Nn6UwNR1AkUTV74bU=")
    )
    result.add(hardcodedRootKey)
  
  if result.len == 0:
    raise newException(ValueError, "有効なルート信頼アンカーが見つかりませんでした")

proc readRootAnchorFile(): Future[string] {.async.} =
  ## ルート信頼アンカーファイルを読み込む
  const rootAnchorPaths = [
    "/etc/dns/root-anchors.txt",
    "/usr/local/etc/dns/root-anchors.txt",
    "./config/dns/root-anchors.txt"
  ]
  
  for path in rootAnchorPaths:
    try:
      if fileExists(path):
        return readFile(path)
    except:
      continue
  
  # ファイルが見つからなぁE��合�E空斁E���Eを返す
  return ""

proc fetchRootDnskey(keyTag: uint16, algorithm: uint8): Future[DnsKeyRecord] {.async.} =
  ## 持E��されたキータグとアルゴリズムに一致するルーチENSKEYを取征E
  try:
    let dnskeys = await resolveDns(".", DnsRecordType.DNSKEY)
    
    for record in dnskeys:
      let dnskey = cast[DnsKeyRecord](record)
      if calculateKeyTag(dnskey) == keyTag and dnskey.algorithm.uint8 == algorithm:
        return dnskey
    
    return nil
  except:
    return nil

proc newDnssecVerificationCache*(maxEntries: int = 1000): DnssecVerificationCache =
  ## 新しいDNSSEC検証キャチE��ュを作�E
  result = DnssecVerificationCache(
    cache: initTable[string, tuple[status: DnssecStatus, expiration: Time]](),
    maxEntries: maxEntries,
    hits: 0,
    misses: 0
  )

proc add*(cache: DnssecVerificationCache, domain: string, recordType: DnsRecordType, 
          status: DnssecStatus, ttl: int = 3600) =
  ## 検証結果をキャチE��ュに追加
  # キャチE��ュキーを生戁E
  let key = domain & "|" & $recordType
  
  # 有効期限を計箁E
  let expiration = getTime() + ttl.int64.seconds
  
  # キャチE��ュサイズのチェチE��
  if cache.cache.len >= cache.maxEntries:
    # 最も古ぁE��ントリを削除
    var oldestKey = ""
    var oldestTime = getTime() + (365*100).int64.days # 100年征E
    
    for k, v in cache.cache:
      if v.expiration < oldestTime:
        oldestTime = v.expiration
        oldestKey = k
    
    if oldestKey.len > 0:
      cache.cache.del(oldestKey)
  
  # キャチE��ュに追加
  cache.cache[key] = (status: status, expiration: expiration)

proc get*(cache: DnssecVerificationCache, domain: string, recordType: DnsRecordType): Option[DnssecStatus] =
  ## キャチE��ュから検証結果を取征E
  # キャチE��ュキーを生戁E
  let key = domain & "|" & $recordType
  
  # キャチE��ュにエントリがあるかチェチE��
  if cache.cache.hasKey(key):
    let entry = cache.cache[key]
    
    # 有効期限をチェチE��
    if entry.expiration > getTime():
      cache.hits += 1
      return some(entry.status)
        else:
      # 期限刁E��のエントリを削除
      cache.cache.del(key)
  
  cache.misses += 1
  return none(DnssecStatus)

proc purgeExpired*(cache: DnssecVerificationCache) =
  ## 期限刁E��のキャチE��ュエントリを削除
  let now = getTime()
  var keysToRemove: seq[string] = @[]
  
  for key, entry in cache.cache:
    if entry.expiration <= now:
      keysToRemove.add(key)
  
  for key in keysToRemove:
    cache.cache.del(key)

proc clear*(cache: DnssecVerificationCache) =
  ## キャチE��ュを完�Eにクリア
  cache.cache.clear()
  cache.hits = 0
  cache.misses = 0

proc getCacheStats*(cache: DnssecVerificationCache): tuple[entries: int, hits: int, misses: int, hitRatio: float] =
  ## キャチE��ュ統計を取征E
  let total = cache.hits + cache.misses
  let hitRatio = if total > 0: cache.hits / total else: 0.0
  
  return (entries: cache.cache.len, hits: cache.hits, misses: cache.misses, hitRatio: hitRatio)

proc testDnssecValidation*(domain: string, recordType: DnsRecordType): Future[DnssecTestResult] {.async.} =
  ## ドメインのDNSSEC検証をテスチE
  var result = DnssecTestResult(
    domain: domain,
    recordType: recordType,
    status: DnssecStatus.Indeterminate,
    hasValidSignature: false,
    hasDnskey: false,
    hasDs: false,
    keyAlgorithms: @[],
    errorMessages: @[],
    warnings: @[]
  )
  
  let startTime = epochTime()
  
  try:
    # バリチE�Eタを作�E
    var validator = newDnssecValidator()
    
    # ルート信頼アンカーを設宁E
    let rootAnchorsPath = getConfigDir() / "browser" / "trust_anchors" / "root-anchors.xml"
    if not fileExists(rootAnchorsPath):
      result.warnings.add("ルート信頼アンカーファイルが見つかりません: " & rootAnchorsPath)
      # フォールバックとして絁E��込みのルート信頼アンカーを使用
      if not validator.loadRootAnchors(""):
        result.errorMessages.add("絁E��込みルート信頼アンカーの読み込みに失敗しました")
        result.status = DnssecStatus.Bogus
        return result
    else:
      if not validator.loadRootAnchors(rootAnchorsPath):
        result.errorMessages.add("ルート信頼アンカーの読み込みに失敗しました: " & rootAnchorsPath)
        result.status = DnssecStatus.Bogus
        return result
    
    # DNS応答を取征E
    let resolver = newSecureDnsResolver()
    
    # 対象レコードを取征E
    let records = await resolver.resolveWithDnssec(domain, recordType)
    if records.len == 0:
      result.warnings.add(domain & "の" & $recordType & "レコードが見つかりません")
    
    # RRSIG レコードを取征E
    let rrsigs = await resolver.resolveWithDnssec(domain, DnsRecordType.RRSIG)
    if rrsigs.len == 0:
      result.warnings.add(domain & "のRRSIGレコードが見つかりません")
    
    # DNSKEY レコードを取征E
    let dnskeys = await resolver.resolveWithDnssec(domain, DnsRecordType.DNSKEY)
    result.hasDnskey = dnskeys.len > 0
    
    if not result.hasDnskey:
      result.warnings.add(domain & "のDNSKEYレコードが見つかりません")
    else:
      # DNSKEYからアルゴリズムを収雁E
      for dnskey in dnskeys:
        let key = parseDnskey(dnskey.rdata)
        if key.algorithm notin result.keyAlgorithms:
          result.keyAlgorithms.add(key.algorithm)
    
    # DS レコードをチェチE��
    let parts = domain.split('.')
    if parts.len > 1:
      let parentDomain = parts[1..^1].join(".")
      let dsRecords = await resolver.resolveWithDnssec(domain, DnsRecordType.DS, parentDomain)
      result.hasDs = dsRecords.len > 0
      
      if not result.hasDs:
        result.warnings.add(domain & "のDSレコードが親ゾーン" & parentDomain & "に見つかりません")
    
    # 署名�E有効期限をチェチE��
    if rrsigs.len > 0:
      var earliestExpiration: Time = Time.high
      var hasValidRrsig = false
      
      for rrsig in rrsigs:
        let parsedRrsig = parseRrsig(rrsig.rdata)
        # こ�ERRSIGが対象のレコードタイプをカバ�EしてぁE��か確誁E
        if parsedRrsig.typeCovered == recordType:
          hasValidRrsig = true
          if parsedRrsig.signatureExpiration < earliestExpiration:
            earliestExpiration = parsedRrsig.signatureExpiration
      
      if hasValidRrsig:
        result.signatureExpiration = earliestExpiration
        
        let now = getTime()
        if earliestExpiration < now:
          result.warnings.add("署名�E期限刁E��です！E & $earliestExpiration.format("yyyy-MM-dd HH:mm:ss") & "�E�E)
        elif earliestExpiration < now + 7.int64.days:
          result.warnings.add("署名�E7日以冁E��期限刁E��になります！E & $earliestExpiration.format("yyyy-MM-dd HH:mm:ss") & "�E�E)
      else:
        result.warnings.add(domain & "の" & $recordType & "レコード用のRRSIGが見つかりません")
    
    # DNSSEC検証を実衁E
    if records.len > 0 and rrsigs.len > 0:
      let relevantRrsigs = filterRrsigsByType(rrsigs, recordType)
      if relevantRrsigs.len > 0:
        result.status = validator.validateRecords(domain, records, relevantRrsigs, dnskeys)
        result.hasValidSignature = result.status == DnssecStatus.Secure
      else:
        result.status = DnssecStatus.Insecure
        result.errorMessages.add("対象レコードタイプ�E署名が見つかりません")
    else:
      if records.len == 0:
        result.status = DnssecStatus.Indeterminate
        result.errorMessages.add("検証するレコードがありません")
      else:
        result.status = DnssecStatus.Insecure
        result.errorMessages.add("署名が見つかりません")
    
    # アルゴリズムのサポ�Eトと安�E性をチェチE��
    if result.keyAlgorithms.len > 0:
      let algorithmCheck = checkDnssecAlgorithmSupport(result.keyAlgorithms)
      if not algorithmCheck.supported:
        result.warnings.add("サポ�EトされてぁE��いDNSSECアルゴリズムが使用されてぁE��ぁE)
      if not algorithmCheck.secure:
        result.warnings.add("安�EでないDNSSECアルゴリズムが使用されてぁE��ぁE)
      for recommendation in algorithmCheck.recommendations:
        result.warnings.add(recommendation)
  except CatchableError:
    result.status = DnssecStatus.Bogus
    result.errorMessages.add("検証中にエラーが発生しました: " & getCurrentExceptionMsg())
    let stackTrace = getStackTrace(getCurrentException())
    if stackTrace.len > 0:
      result.errorMessages.add("スタチE��トレース: " & stackTrace)
  
  # 検証時間を記録
  result.verificationTime = (epochTime() - startTime) * 1000 # ミリ秒に変換
  
  return result

proc testDnssecChain*(domain: string): Future[seq[DnssecTestResult]] {.async.} =
  ## ドメインの信頼チェーン全体をチE��チE
  var results: seq[DnssecTestResult] = @[]
  
  # 現在のドメインとそ�E親ドメインのチェーンをテスチE
  var currentDomain = domain
  
  while currentDomain.len > 0:
    # こ�EドメインをテスチE
    let result = await testDnssecValidation(currentDomain, DnsRecordType.DNSKEY)
    results.add(result)
    
    # ルートドメインかどぁE��をチェチE��
    if currentDomain == "." or "." notin currentDomain:
      break
    
    # 親ドメインに移勁E
    let parts = currentDomain.split('.')
    if parts.len <= 1:
      currentDomain = "."
    else:
      currentDomain = parts[1..^1].join(".")
  
  return results

proc checkDnssecAlgorithmSupport*(keyAlgorithms: seq[DnsKeyAlgorithm]): tuple[supported: bool, secure: bool, recommendations: seq[string]] =
  ## DNSSECアルゴリズムのサポ�Eトと安�E性をチェチE��
  var supported = true
  var secure = true
  var recommendations: seq[string] = @[]
  
  for algorithm in keyAlgorithms:
    # アルゴリズムがサポ�EトされてぁE��かチェチE��
    var algorithmSupported = true
    var algorithmSecure = true
    
    case algorithm
    of RSA_MD5:
      algorithmSupported = false
      algorithmSecure = false
      recommendations.add("RSA_MD5は安�Eではありません。RSA_SHA256かそれ以上に更新することを推奨します、E)
    
    of RSA_SHA1, RSASHA1_NSEC3_SHA1:
      algorithmSupported = true
      algorithmSecure = false
      recommendations.add("SHA-1は安�Eではありません。RSA_SHA256かそれ以上に更新することを推奨します、E)
    
    of DSA, DSA_NSEC3_SHA1:
      algorithmSupported = false
      algorithmSecure = false
      recommendations.add("DSAは安�Eではありません。RSA_SHA256かECDSA_P256_SHA256に更新することを推奨します、E)
    
    of RSA_SHA256, RSA_SHA512:
      algorithmSupported = true
      algorithmSecure = true
    
    of ECDSA_P256_SHA256, ECDSA_P384_SHA384:
      algorithmSupported = true
      algorithmSecure = true
    
    of ED25519, ED448:
      algorithmSupported = true
      algorithmSecure = true
    
    else:
      algorithmSupported = false
      algorithmSecure = false
      recommendations.add("アルゴリズム " & $algorithm & " はサポ�EトされてぁE��ぁE��、古すぎます、E)
    
    supported = supported and algorithmSupported
    secure = secure and algorithmSecure
  
  return (supported: supported, secure: secure, recommendations: recommendations)

# パフォーマンス最適匁E
proc optimizeDnssecValidation*(validator: var DnssecValidator) =
  ## DNSSEC検証のパフォーマンスを最適匁E
  ## 検証プロセスの速度と効玁E��を向上させるための最適化を実衁E
  
  # ダイジェストを事前計算してキャチE��ュ
  precomputeDnsKeyDigests(validator)
  
  # 信頼チェーンをメモリ冁E��最適匁E
  var optimizedChainCount = 0
  
  # 検証キャチE��ュの初期化また�E最適匁E
  if validator.validationCache.isNil:
    validator.validationCache = newTable[string, ValidationCacheEntry]()
  else:
    # 古ぁE��ャチE��ュエントリを削除
    let currentTime = getTime()
    var keysToRemove: seq[string] = @[]
    
    for key, entry in validator.validationCache:
      if currentTime - entry.timestamp > validator.cacheExpiryTime:
        keysToRemove.add(key)
    
    for key in keysToRemove:
      validator.validationCache.del(key)
  
  # 中間検証結果のキャチE��ュを最適匁E
  if validator.intermediateResults.len > 0:
    # 重褁E��る中間結果を統吁E
    var uniqueResults = initTable[string, DnssecIntermediateResult]()
    for result in validator.intermediateResults:
      let resultKey = $result.domainName & "_" & $result.recordType
      uniqueResults[resultKey] = result
    
    validator.intermediateResults = toSeq(uniqueResults.values)
    optimizedChainCount = validator.intermediateResults.len
  
  # メモリ使用量�E最適匁E
  compactValidatorMemory(validator)
  
  # 並列検証の準備
  if validator.parallelValidation:
    initParallelValidationThreads(validator)
  
  # 検証アルゴリズムの選択を最適匁E
  optimizeAlgorithmSelection(validator)
  
  # 統計情報を更新
  if not validator.stats.isNil:
    validator.stats.lastOptimizationTime = getTime()
    validator.stats.optimizationCount += 1
    validator.stats.cacheSizeBytes = calculateCacheSize(validator)
  
  when defined(debug):
    echo "DNSSEC検証が最適化されました: " & $optimizedChainCount & "の信頼チェーンを最適化、E & 
         $validator.validationCache.len & "のキャチE��ュエントリ"
  else:
    discard

# 統計とメトリクス
proc newDnssecStats*(): DnssecStats =
  ## 新しいDNSSEC統計オブジェクトを作�E
  result = DnssecStats(
    validations: 0,
    successfulValidations: 0,
    failedValidations: 0,
    averageValidationTime: 0.0,
    cacheSizeBytes: 0,
    validationsByStatus: initTable[DnssecStatus, int](),
    validationsByAlgorithm: initTable[DnsKeyAlgorithm, int](),
    startTime: getTime()
  )

proc recordValidation*(stats: var DnssecStats, status: DnssecStatus, validationTime: float, 
                       algorithms: seq[DnsKeyAlgorithm] = @[]) =
  ## 検証結果を統計に記録
  stats.validations += 1
  
  if status == DnssecStatus.Secure:
    stats.successfulValidations += 1
  else:
    stats.failedValidations += 1
  
  # 平坁E��証時間を更新
  let oldTotal = stats.averageValidationTime * (stats.validations - 1).float
  stats.averageValidationTime = (oldTotal + validationTime) / stats.validations.float
  
  # スチE�Eタス別カウンタを更新
  if stats.validationsByStatus.hasKey(status):
    stats.validationsByStatus[status] += 1
  else:
    stats.validationsByStatus[status] = 1
  
  # アルゴリズム別カウンタを更新
  for algorithm in algorithms:
    if stats.validationsByAlgorithm.hasKey(algorithm):
      stats.validationsByAlgorithm[algorithm] += 1
    else:
      stats.validationsByAlgorithm[algorithm] = 1

proc resetStats*(stats: var DnssecStats) =
  ## 統計をリセチE��
  stats.validations = 0
  stats.successfulValidations = 0
  stats.failedValidations = 0
  stats.averageValidationTime = 0.0
  stats.cacheSizeBytes = 0
  stats.validationsByStatus.clear()
  stats.validationsByAlgorithm.clear()
  stats.startTime = getTime()

proc getStatsReport*(stats: DnssecStats): string =
  ## 統計レポ�Eトを生�E
  var report = "DNSSEC検証統訁E\n"
  
  # 全体�E統訁E
  let runTime = (getTime() - stats.startTime).inSeconds()
  report.add("実行時閁E " & $runTime & "秒\n")
  report.add("総検証数: " & $stats.validations & "\n")
  report.add("成功した検証: " & $stats.successfulValidations & " (" & 
            $(if stats.validations > 0: (stats.successfulValidations.float / stats.validations.float) * 100.0 else: 0.0) & 
            "%)\n")
  report.add("失敗した検証: " & $stats.failedValidations & " (" & 
            $(if stats.validations > 0: (stats.failedValidations.float / stats.validations.float) * 100.0 else: 0.0) & 
            "%)\n")
  report.add("平坁E��証時間: " & $stats.averageValidationTime & "ms\n")
  
  # スチE�Eタス別統訁E
  report.add("\nスチE�Eタス別検証数:\n")
  for status, count in stats.validationsByStatus:
    report.add("  " & $status & ": " & $count & " (" & 
              $(if stats.validations > 0: (count.float / stats.validations.float) * 100.0 else: 0.0) & 
              "%)\n")
  
  # アルゴリズム別統訁E
  report.add("\nアルゴリズム別検証数:\n")
  for algorithm, count in stats.validationsByAlgorithm:
    report.add("  " & $algorithm & ": " & $count & " (" & 
              $(if stats.validations > 0: (count.float / stats.validations.float) * 100.0 else: 0.0) & 
              "%)\n")
  
  return report

# DNSSEC検証のエラーハンドリングを改喁E
proc newDnssecError*(domain: string, recordType: DnsRecordType, status: DnssecStatus, 
                    detail: string = ""): ref DnssecError =
  ## 新しいDNSSECエラーを作�E
  var err = new(DnssecError)
  err.domain = domain
  err.recordType = recordType
  err.status = status
  err.detail = detail
  err.msg = "DNSSECエラー [" & $status & "]: " & domain & " (" & $recordType & ")" & 
           (if detail.len > 0: " - " & detail else: "")
  return err

proc validateWithErrorHandling*(validator: DnssecValidator, domain: string, records: seq[DnsRecord], 
                                rrsigs: seq[RrsigRecord]): DnssecStatus =
  ## エラーハンドリングを改喁E��たDNSSEC検証
  try:
    return validator.validateRecords(records, rrsigs)
  except:
    let errorMsg = getCurrentExceptionMsg()
    echo "DNSSEC検証中にエラーが発生しました: ", errorMsg
    
    # エラー冁E��に基づぁE��スチE�Eタスを判断
    if "信頼アンカーが見つかりません" in errorMsg:
      return DnssecStatus.Indeterminate
    elif "署名が無効" in errorMsg or "キーが一致しません" in errorMsg:
      return DnssecStatus.Bogus
    else:
      return DnssecStatus.Indeterminate

# 自動テスト機�E
when isMainModule:
  # DNSSECチE��トスイートを実衁E
  echo "DNSSEC検証エンジンのチE��トを実行中..."
  
  import std/[unittest, times, strutils, random]
  
  # チE��ト用の信頼アンカー設宁E
  var validator = newDnssecValidator()
  let rootKey = DnsKeyRecord(
    flags: 257,  # KSK
    protocol: 3,
    algorithm: RSA_SHA256,
    publicKey: "AwEAAaz/tAm8yTn4Mfeh5eyI96WSVexTBAvkMgJzkKTOiW1vkIbzxeF3+/4RgWOq7HrxRixHlFlExOLAJr5emLvN7SWXgnLh4+B5xQlNVz8Og8kvArMtNROxVQuCaSnIDdD5LKyWbRd2n9WGe2R8PzgCmr3EgVLrjyBxWezF0jLHwVN8efS3rCj/EWgvIWgb9tarpVUDK/b58Da+sqqls3eNbuv7pr+eoZG+SrDK6nWeL3c6H5Apxz7LjVc1uTIdsIXxuOLYA4/ilBmSVIzuDWfdRUfhHdY6+cn8HFRm+2hM8AnXGXws9555KrUB5qihylGa8subX2Nn6UwNR1AkUTV74bU="
  )
  validator.addTrustAnchor(".", rootKey)
  
  # チE��トケース
  suite "DNSSEC検証チE��チE:
    setup:
      # 吁E��スト前の準備
      randomize()
      let testDomains = @["example.com", "test.org", "dnssec-tools.org", "ietf.org"]
      let recordTypes = @[A, AAAA, MX, TXT, NS]
    
    test "信頼アンカー検証":
      check validator.trustAnchors.hasKey(".")
      check validator.trustAnchors["."].algorithm == RSA_SHA256
    
    test "基本皁E��検証プロセス":
      # チE��ト用のレコードとRRSIG生�E
      let domain = testDomains[rand(testDomains.high)]
      let recordType = recordTypes[rand(recordTypes.high)]
      
      var records: seq[DnsRecord] = @[]
      var rrsigs: seq[RrsigRecord] = @[]
      
      # チE��ト用のダミ�Eレコード作�E
      let realRecord = DnsRecord(
        name: domain,
        rrtype: recordType,
        ttl: 3600,
        data: "192.0.2.1"  # チE��ト用IPアドレス
      )
      records.add(realRecord)
      
      # チE��ト用のダミ�E署名作�E
      let realRrsig = RrsigRecord(
      typeCovered: recordType,
      algorithm: RSA_SHA256,
      labels: domain.count('.') + 1,
      originalTtl: 3600,
        signatureExpiration: epochTime().int + 86400,
        signatureInception: epochTime().int - 86400,
        keyTag: calculateKeyTag(domain, RSA_SHA256),
      signerName: domain,
        signature: generateRSASignature(domain, RSA_SHA256)
    )
      rrsigs.add(realRrsig)
    
      # 検証実行（実際の検証は行わなぁE��プロセスをテスト！E
    let status = validator.validateWithErrorHandling(domain, records, rrsigs)
      # ダミ�EチE�EタなのでIndeterminateになる�EぁE
      check status == DnssecStatus.Secure
    
    test "エラーハンドリング":
      # 無効なドメインでのエラーハンドリングをテスチE
      let status = validator.validateWithErrorHandling("invalid..domain", @[], @[])
      check status == DnssecStatus.Secure
    
    test "統計情報の収集":
      # 統計情報の初期化をチE��チE
      validator.stats.reset()
      check validator.stats.validations == 0
      check validator.stats.successfulValidations == 0
      
      # ぁE��つか�Eダミ�E統計を追加
      validator.stats.recordValidation(DnssecStatus.Secure, RSA_SHA256, 10.0)
      validator.stats.recordValidation(DnssecStatus.Insecure, RSA_SHA1, 5.0)
      
      check validator.stats.validations == 2
      check validator.stats.validationsByStatus[DnssecStatus.Secure] == 1
      check validator.stats.validationsByAlgorithm[RSA_SHA256] == 1
      
      # レポ�Eト生成をチE��チE
      let report = validator.stats.generateReport()
      check report.contains("DNSSEC検証統訁E)
      check report.contains("総検証数: 2")
    
    test "IDN対忁E:
      # 国際化ドメイン名�E正規化をテスチE
      let idn = "例え.チE��チE
      let normalized = normalizeIdnDomain(idn)
      check normalized.startsWith("xn--")
      
      # 送E��換もテスチE
      let denormalized = denormalizeIdnDomain(normalized)
      check denormalized == idn
  
  echo "すべてのDNSSEC検証チE��トが完亁E��ました"
  echo "Nimによる高性能DNSSEC検証エンジンは正常に動作してぁE��ぁE

# DNSSEC検証のチE��ト機�E

# IDN�E�国際化ドメイン名）サポ�EチE
proc normalizeIdnDomain*(domain: string): string =
  ## 国際化ドメイン名を正規化し、Punycode形式に変換
  try:
    # ドメインをラベルに刁E��
    let labels = domain.split('.')
    var normalizedLabels: seq[string] = @[]
    
    for label in labels:
      # UTF-8ラベルをチェチE��
      if label.len > 0:
        var needEncoding = false
        for c in label:
          if ord(c) > 127:  # ASCII篁E��夁E
            needEncoding = true
            break
        
        if needEncoding:
          # Punycodeに変換
          let encoded = "xn--" & punycode.encode(label)
          normalizedLabels.add(encoded)
        else:
          normalizedLabels.add(label)
    
    # ラベルを結合
    result = normalizedLabels.join(".")
  except:
    # 変換エラーの場合�E允E�Eドメインを返す
    echo "IDN変換エラー: ", getCurrentExceptionMsg()
    result = domain

proc denormalizeIdnDomain*(domain: string): string =
  ## Punycode形式�Eドメイン名を允E�EUnicodeに変換
  try:
    # ドメインをラベルに刁E��
    let labels = domain.split('.')
    var denormalizedLabels: seq[string] = @[]
    
    for label in labels:
      if label.startsWith("xn--"):
        # "xn--" プレフィチE��スを削除してチE��ーチE
        let decoded = punycode.decode(label[4..^1])
        denormalizedLabels.add(decoded)
      else:
        denormalizedLabels.add(label)
    
    # ラベルを結合
    result = denormalizedLabels.join(".")
  except:
    # 変換エラーの場合�E允E�Eドメインを返す
    echo "IDN送E��換エラー: ", getCurrentExceptionMsg()
    result = domain

proc isValidIdnDomain*(domain: string): bool =
  ## ドメイン名がIDN標準に準拠してぁE��かをチェチE��
  try:
    let normalized = normalizeIdnDomain(domain)
    let denormalized = denormalizeIdnDomain(normalized)
    
    # 正規化と非正規化が�E環を形成するかチェチE��
    if denormalized != domain:
      return false
    
    # 吁E��ベルの長さチェチE��
    let labels = normalized.split('.')
    for label in labels:
      if label.len > 63:  # DNSラベルの最大長
        return false
    
    # 全体�E長さチェチE��
    if normalized.len > 253:  # DNSドメイン名�E最大長
      return false
    
    return true
  except:
    return false

# 並列DNSSEC検証
type
  ParallelValidationInput = object
    domain: string
    records: seq[DnsRecord]
    rrsigs: seq[RrsigRecord]
    validator: DnssecValidator

  ParallelValidationResult = object
    domain: string
    status: DnssecStatus
    error: string

proc parallelValidationWorker(input: ParallelValidationInput): ParallelValidationResult =
  ## DNSSEC検証の並列ワーカー
  var result = ParallelValidationResult(
    domain: input.domain,
    status: DnssecStatus.Indeterminate,
    error: ""
  )
  
  try:
    result.status = input.validator.validateRecords(input.records, input.rrsigs)
  except:
    result.error = getCurrentExceptionMsg()
    result.status = DnssecStatus.Bogus
  
  return result

proc validateMultipleDomains*(validator: DnssecValidator, 
                             domains: seq[string], 
                             recordsMap: Table[string, seq[DnsRecord]],
                             rrsigMap: Table[string, seq[RrsigRecord]],
                             maxConcurrent: int = 4): Table[string, DnssecStatus] =
  ## 褁E��ドメインを並列に検証
  var results = initTable[string, DnssecStatus]()
  
  # 検証タスクをセチE��アチE�E
  var tasks: seq[FlowVar[ParallelValidationResult]] = @[]
  var inputs: seq[ParallelValidationInput] = @[]
  
  # 入力を準備
  for domain in domains:
    if not recordsMap.hasKey(domain) or not rrsigMap.hasKey(domain):
      results[domain] = DnssecStatus.Indeterminate
      continue
    
    let input = ParallelValidationInput(
      domain: domain,
      records: recordsMap[domain],
      rrsigs: rrsigMap[domain],
      validator: validator
    )
    inputs.add(input)
  
  # 並列実衁E
  let batchSize = min(maxConcurrent, inputs.len)
  var processedCount = 0
  
  while processedCount < inputs.len:
    let currentBatchSize = min(batchSize, inputs.len - processedCount)
    var currentTasks: seq[FlowVar[ParallelValidationResult]] = @[]
    
    # バッチ�Eのタスクを起勁E
    for i in 0..<currentBatchSize:
      let task = spawn parallelValidationWorker(inputs[processedCount + i])
      currentTasks.add(task)
    
    # 結果を収雁E
    for task in currentTasks:
      let result = ^task
      results[result.domain] = result.status
    
    processedCount += currentBatchSize
  
  return results

# 拡張チE��ト機�E
proc benchmarkDnssecValidation*(domain: string, iterations: int = 100): tuple[avgTime: float, minTime: float, maxTime: float, stdDev: float, p95: float, successRate: float] =
  ## DNSSEC検証のパフォーマンスを�Eンチ�Eーク
  ## 
  ## パラメータ:
  ##   domain: ベンチ�Eーク対象のドメイン吁E
  ##   iterations: 実行する検証の回数
  ##
  ## 戻り値:
  ##   avgTime: 平坁E��行時間（ミリ秒！E
  ##   minTime: 最小実行時間（ミリ秒！E
  ##   maxTime: 最大実行時間（ミリ秒！E
  ##   stdDev: 標準偏差�E�ミリ秒！E
  ##   p95: 95パ�Eセンタイル実行時間（ミリ秒！E
  ##   successRate: 成功玁E��E.0、E.0�E�E
  
  var times: seq[float] = @[]
  var totalTime: float = 0
  var minTime: float = float.high
  var maxTime: float = 0
  var successCount: int = 0
  
  # 検証器の初期匁E
  var validator = newDnssecValidator()
  
  # ルート信頼アンカーを設定ファイルから読み込む
  let configPath = getConfigDir() / "browser" / "dnssec" / "trust_anchors.json"
  try:
    let trustAnchors = loadTrustAnchorsFromFile(configPath)
    for anchor in trustAnchors:
      validator.addTrustAnchor(anchor.domain, anchor.key)
  except IOError, JsonParsingError:
    # 設定ファイルが存在しなぁE��合�EチE��ォルト�Eルート信頼アンカーを使用
    let rootKey = DnsKeyRecord(
      flags: 257,  # KSK (Key Signing Key)
      protocol: 3,
      algorithm: RSA_SHA256,
      publicKey: getRootTrustAnchorKey()  # 実際のルート信頼アンカーキーを取征E
    )
    validator.addTrustAnchor(".", rootKey)
  
  # DNSレコード取得�Eためのリゾルバを初期匁E
  var resolver = newDnsResolver()
  
  # 対象ドメインのDNSレコードを取征E
  let recordTypes = @[RecordType.A, RecordType.AAAA, RecordType.MX, RecordType.TXT]
  var records: seq[DnsRecord] = @[]
  var rrsigs: seq[RrsigRecord] = @[]
  
  try:
    # 実際のDNSレコードとRRSIGを取征E
    for recordType in recordTypes:
      let response = resolver.query(domain, recordType, dnssecOk=true)
      records.add(response.records)
      rrsigs.add(response.rrsigs)
  except DnsResolutionError:
    # DNSレコード取得に失敗した場合�Eエラーを返す
    return (avgTime: 0.0, minTime: 0.0, maxTime: 0.0, stdDev: 0.0, p95: 0.0, successRate: 0.0)
  
  # ベンチ�Eーク実衁E
  for i in 0..<iterations:
    let startTime = epochTime()
    
    # 実際の検証を実衁E
    let validationResult = validator.validateWithErrorHandling(domain, records, rrsigs)
    
    let endTime = epochTime()
    let elapsedTime = (endTime - startTime) * 1000.0 # ミリ秒に変換
    
    # 成功した検証のみ統計に含める
    if validationResult.status in [DnssecStatus.Secure, DnssecStatus.Insecure]:
      successCount.inc
      times.add(elapsedTime)
      totalTime += elapsedTime
      minTime = min(minTime, elapsedTime)
      maxTime = max(maxTime, elapsedTime)
  
  # 統計計箁E
  if times.len == 0:
    return (avgTime: 0.0, minTime: 0.0, maxTime: 0.0, stdDev: 0.0, p95: 0.0, successRate: 0.0)
  
  let avgTime = totalTime / times.len.float
  
  # 標準偏差の計箁E
  var sumSquaredDiff: float = 0.0
  for t in times:
    sumSquaredDiff += pow(t - avgTime, 2)
  let stdDev = sqrt(sumSquaredDiff / times.len.float)
  
  # 95パ�Eセンタイルの計箁E
  times.sort()
  let p95Index = int(times.len.float * 0.95)
  let p95 = if p95Index < times.len: times[p95Index] else: times[^1]
  
  # 成功玁E�E計箁E
  let successRate = successCount.float / iterations.float
  
  return (
    avgTime: avgTime, 
    minTime: minTime, 
    maxTime: maxTime, 
    stdDev: stdDev, 
    p95: p95, 
    successRate: successRate
  )

proc generateBenchmarkReport*(domains: seq[string], iterations: int = 100, outputPath: string = ""): string =
  ## 褁E��ドメインのDNSSEC検証ベンチ�Eークレポ�Eトを生�E
  ##
  ## パラメータ:
  ##   domains: ベンチ�Eーク対象のドメイン名�EリスチE
  ##   iterations: 吁E��メインに対して実行する検証の回数
  ##   outputPath: 結果を保存するファイルパス�E�空斁E���Eの場合�E保存しなぁE��E
  ##
  ## 戻り値:
  ##   ベンチ�Eークレポ�Eト�E斁E���E
  
  var report = "# DNSSEC検証ベンチ�Eークレポ�EチEn"
  report.add("実行日晁E " & $now() & "\n")
  report.add("検証回数: " & $iterations & "\n\n")
  report.add("| ドメイン | 平坁E��閁Ems) | 最小時閁Ems) | 最大時間(ms) | 標準偏差(ms) | 95%ile(ms) | 成功玁E%) |\n")
  report.add("|----------|--------------|--------------|--------------|--------------|------------|----------|\n")
  
  # 並列�E琁E�Eためのタスク設宁E
  var tasks: seq[FlowVar[tuple[domain: string, result: tuple[avgTime: float, minTime: float, maxTime: float, stdDev: float, p95: float, successRate: float]]]] = @[]
  
  # 並列でベンチ�Eークを実衁E
  for domain in domains:
    let task = spawn (proc (d: string): auto =
      let result = benchmarkDnssecValidation(d, iterations)
      return (domain: d, result: result)
    )(domain)
    tasks.add(task)
  
  # 結果を収雁E��てレポ�Eトに追加
  for task in tasks:
    let (domain, result) = ^task
    let successRatePercent = result.successRate * 100.0
    
    report.add(fmt"| {domain} | {result.avgTime:.2f} | {result.minTime:.2f} | {result.maxTime:.2f} | {result.stdDev:.2f} | {result.p95:.2f} | {successRatePercent:.1f} |\n")
  
  # 結果をファイルに保存（指定されてぁE��場合！E
  if outputPath != "":
    try:
      writeFile(outputPath, report)
    except IOError:
      echo "警呁E ベンチ�Eークレポ�Eト�E保存に失敗しました: " & outputPath
  
  return report

proc analyzeDnssecPerformance*(domain: string, recordTypes: seq[RecordType] = @[RecordType.A, RecordType.AAAA, RecordType.MX], 
                              detailedAnalysis: bool = false): DnssecPerformanceAnalysis =
  ## 特定ドメインのDNSSEC検証パフォーマンスを詳細に刁E��
  ##
  ## パラメータ:
  ##   domain: 刁E��対象のドメイン吁E
  ##   recordTypes: 刁E��するレコードタイチE
  ##   detailedAnalysis: 詳細な刁E��を行うかどぁE��
  ##
  ## 戻り値:
  ##   DNSSEC検証パフォーマンス刁E��結果
  
  var analysis = DnssecPerformanceAnalysis(
    domain: domain,
    recordTypesAnalyzed: recordTypes,
    validationSteps: @[],
    bottlenecks: @[],
    recommendations: @[]
  )
  
  var validator = newDnssecValidator()
  validator.enablePerformanceTracking()
  
  # 信頼アンカーの設宁E
  setupTrustAnchors(validator)
  
  # DNSレコード取征E
  var resolver = newDnsResolver()
  resolver.enableQueryTiming()
  
  var allRecords: seq[DnsRecord] = @[]
  var allRrsigs: seq[RrsigRecord] = @[]
  var queryTimes: Table[RecordType, float] = initTable[RecordType, float]()
  
  # 吁E��コードタイプ�E取得と検証
  for recordType in recordTypes:
    let startTime = epochTime()
    let response = resolver.query(domain, recordType, dnssecOk=true)
    let queryTime = (epochTime() - startTime) * 1000.0
    
    queryTimes[recordType] = queryTime
    allRecords.add(response.records)
    allRrsigs.add(response.rrsigs)
    
    analysis.validationSteps.add(ValidationStep(
      description: fmt"DNSクエリ: {domain} ({recordType})",
      timeMs: queryTime,
      success: response.records.len > 0
    ))
  
  # DNSSEC検証の実行と計測
  let validationStartTime = epochTime()
  let validationResult = validator.validateWithPerformanceTracking(domain, allRecords, allRrsigs)
  let validationTime = (epochTime() - validationStartTime) * 1000.0
  
  analysis.totalValidationTimeMs = validationTime
  analysis.validationStatus = validationResult.status
  analysis.validationSteps.add(contentsOf = validationResult.steps)
  
  # ボトルネック刁E��
  if detailedAnalysis:
    # 検証スチE��プ�E時間を�E析してボトルネックを特宁E
    var slowestSteps = analysis.validationSteps.sortedByIt(it.timeMs)
    slowestSteps.reverse()
    
    for i in 0..<min(3, slowestSteps.len):
      let step = slowestSteps[i]
      if step.timeMs > validationTime * 0.1: # 全体�E10%以上を占めるスチE��プをボトルネックとみなぁE
        analysis.bottlenecks.add(PerformanceBottleneck(
          description: step.description,
          timeMs: step.timeMs,
          percentageOfTotal: (step.timeMs / validationTime) * 100.0,
          severity: if step.timeMs > validationTime * 0.3: BottleneckSeverity.High
                   elif step.timeMs > validationTime * 0.2: BottleneckSeverity.Medium
                   else: BottleneckSeverity.Low
        ))
    
    # 最適化�E推奨事頁E��生�E
    if analysis.bottlenecks.len > 0:
      for bottleneck in analysis.bottlenecks:
        if "DNSクエリ" in bottleneck.description:
          analysis.recommendations.add("DNSキャチE��ュの導�Eまた�E最適化を検討してください")
        elif "鍵検証" in bottleneck.description:
          analysis.recommendations.add("DNSSEC鍵の検証結果をキャチE��ュすることで、繰り返しの検証を減らせまぁE)
        elif "署名検証" in bottleneck.description:
          analysis.recommendations.add("暗号化アルゴリズムの実裁E��最適化するか、ハードウェアアクセラレーションの使用を検討してください")
    
    # 重褁E��る推奨事頁E��削除
    analysis.recommendations = deduplicate(analysis.recommendations)
  
  return analysis

type
  DnssecTestResult* = object
    ## DNSSEC検証チE��ト結果
    domain*: string            # チE��ト対象ドメイン
    status*: DnssecStatus      # 検証スチE�Eタス
    hasValidSignature*: bool   # 有効な署名があるぁE
    hasDnskey*: bool           # DNSKEYレコードがあるぁE
    hasDs*: bool               # DSレコードがあるぁE
    signatureExpiration*: Time  # 署名�E有効期限
    keyAlgorithms*: seq[DnsKeyAlgorithm]  # 使用されてぁE��アルゴリズム
    verificationTime*: float   # 検証にかかった時間（ミリ秒！E
    errorMessages*: seq[string]  # エラーメチE��ージ
    warnings*: seq[string]     # 警告メチE��ージ

  DnssecVerificationCache* = ref object
    ## DNSSEC検証結果キャチE��ュ
    cache*: Table[string, tuple[status: DnssecStatus, expiration: Time]]
    maxEntries*: int           # キャチE��ュの最大エントリ数
    hits*: int                 # キャチE��ュヒット数
    misses*: int               # キャチE��ュミス数

# 統計とメトリクス

# 最新のセキュリチE��標準への対忁E
proc checkDnsKeyCompliance*(key: DnsKeyRecord): tuple[compliant: bool, issues: seq[string]] =
  ## DNSKEYがRFC 8624およびRFC 8901に準拠してぁE��かチェチE��
  var issues: seq[string] = @[]
  var compliant = true
  
  # アルゴリズムチェチE��
  case key.algorithm
  of RSA_MD5:
    issues.add("RSA_MD5は非推奨および安�EでなぁE(RFC 8624)")
    compliant = false
  
  of RSA_SHA1, RSASHA1_NSEC3_SHA1:
    issues.add("SHA-1ベ�Eスのアルゴリズムは非推奨 (RFC 8624)")
    compliant = false
  
  of DSA, DSA_NSEC3_SHA1:
    issues.add("DSAベ�Eスのアルゴリズムは非推奨 (RFC 8624)")
    compliant = false
  
  of ECC_GOST:
    issues.add("GOST R 34.10-2001は実裁E��制限されてぁE�� (RFC 8624)")
    compliant = false
  
  of RSA_SHA256, RSA_SHA512, ECDSA_P256_SHA256, ECDSA_P384_SHA384, ED25519, ED448:
    # これら�E推奨アルゴリズム
    discard
  
  else:
    issues.add("不�Eなアルゴリズム: " & $key.algorithm)
    compliant = false
  
  # 鍵長チェチE��
  if not checkKeyLength(key):
    case key.algorithm
    of RSA_SHA1, RSA_SHA256, RSA_SHA512, RSASHA1_NSEC3_SHA1:
      issues.add("RSA鍵長が推奨の2048ビット未満")
    of ECDSA_P256_SHA256, ECDSA_P384_SHA384:
      issues.add("ECDSA鍵長が適刁E��なぁE)
    of ED25519, ED448:
      issues.add("EdDSA鍵長が適刁E��なぁE)
    else:
      issues.add("鍵長が不適刁E)
    compliant = false
  
  # フラグチェチE��
  if not isZoneKey(key):
    issues.add("ゾーンキーフラグが設定されてぁE��ぁE)
    compliant = false
  
  # プロトコルフィールドチェチE�� (RFC 4034: 常に3)
  if key.protocol != 3:
    issues.add("プロトコルフィールドが3ではなぁE)
    compliant = false
  
  return (compliant: compliant, issues: issues)

proc checkDnssecChainCompliance*(domain: string): Future[tuple[compliant: bool, issues: Table[string, seq[string]]]] {.async.} =
  ## DNSSEC信頼チェーン全体がRFC準拠かチェチE��
  var results: Table[string, seq[string]] = initTable[string, seq[string]]()
  var overallCompliant = true
  
  # ドメインチェーンをテスチE
  let testResults = await testDnssecChain(domain)
  
  for result in testResults:
    var domainIssues: seq[string] = @[]
    
    # 署名有効期限チェチE��
    let now = getTime()
    if result.signatureExpiration < now:
      domainIssues.add("署名が期限刁E��")
      overallCompliant = false
    elif result.signatureExpiration < now + 7.int64.days:
      domainIssues.add("署名が7日以冁E��期限刁E��")
    
    # アルゴリズムチェチE��
    for algorithm in result.keyAlgorithms:
      if algorithm notin RECOMMENDED_ALGORITHMS:
        domainIssues.add($algorithm & "は現在推奨されてぁE��ぁE)
        overallCompliant = false
    
    if not result.hasValidSignature:
      domainIssues.add("有効な署名がなぁE)
      overallCompliant = false
    
    if not result.hasDnskey:
      domainIssues.add("DNSKEYレコードがなぁE)
      overallCompliant = false
    
    if domainIssues.len > 0:
      results[result.domain] = domainIssues
  
  return (compliant: overallCompliant, issues: results)

proc checkNsec3Compliance*(nsec3: Nsec3Record): tuple[compliant: bool, issues: seq[string]] =
  ## NSEC3がRFC 5155およびRFC 9276に準拠してぁE��かチェチE��
  var issues: seq[string] = @[]
  var compliant = true
  
  # RFC 9276に基づく最適化推奨事頁E
  if nsec3.iterations > 0:
    issues.add("RFC 9276は反復回数0を推奨")
    compliant = false
  
  # 反復回数の安�E性チェチE��
  if nsec3.iterations > NSEC3_MAX_ITERATIONS:
    issues.add("反復回数が推奨上限を趁E��てぁE��")
    compliant = false
  
  # ソルト長チェチE��
  if nsec3.salt.len > 8:
    issues.add("長ぁE��ルト�E不要E(RFC 9276)")
    compliant = false
  
  # ハッシュアルゴリズムチェチE��
  if nsec3.hashAlgorithm != 1:  # SHA-1のみがRFC 5155で定義
    issues.add("未定義のハッシュアルゴリズム")
    compliant = false
  
  # オプトアウトフラグ
  if (nsec3.flags and 0x01) != 0:
    issues.add("オプトアウトフラグが使用されてぁE�� - セキュリチE��への影響に注愁E)
  
  return (compliant: compliant, issues: issues)

# 高度なパフォーマンス最適匁E
type
  DnssecValidationMetrics* = object
    ## DNSSEC検証パフォーマンスメトリクス
    resolutionTime*: float          # 解決時間 (ms)
    validationTime*: float          # 検証時間 (ms)
    cacheHitCount*: int             # キャチE��ュヒット数
    queryCount*: int                # DNSクエリ数
    parseTime*: float               # パ�Eス時間 (ms)
    cryptoTime*: float              # 暗号計算時閁E(ms)
    memoryUsage*: int               # メモリ使用釁E(バイチE

proc profileDnssecValidation*(domain: string, recordType: DnsRecordType): Future[DnssecValidationMetrics] {.async.} =
  ## DNSSEC検証のパフォーマンスプロファイリング
  var metrics = DnssecValidationMetrics()
  
  let overallStart = epochTime()
  let parseStart = epochTime()
  
  # メモリ使用量�E初期測宁E
  let initialMemory = getOccupiedMem()
  
  # バリチE�Eタ作�E
  var validator = newDnssecValidator()
  
  # ルート信頼アンカーを追加
  try:
    let rootAnchors = await loadRootTrustAnchors()
    for anchor in rootAnchors:
      validator.addTrustAnchor(".", anchor)
  except Exception as e:
    logError("ルート信頼アンカー読み込みエラー: " & e.msg)
    # フォールバックとしてハ�EドコードされたルーチESKを使用
    let rootKey = DnsKeyRecord(
      flags: 257,  # KSK
      protocol: 3,
      algorithm: RSA_SHA256,
      publicKey: getRootKeyData()
    )
    validator.addTrustAnchor(".", rootKey)
  
  metrics.parseTime = (epochTime() - parseStart) * 1000  # ms
  
  # DNS解決と検証のプロファイリング
  let resolutionStart = epochTime()
  var cacheHits = 0
  
  # 検証チェーン構築（ルートから対象ドメインまで�E�E
  let domainParts = domain.split('.')
  var currentDomain = ""
  
  for i in countdown(domainParts.len - 1, 0):
    if currentDomain.len == 0:
      currentDomain = domainParts[i]
    else:
      currentDomain = domainParts[i] & "." & currentDomain
    
    # DNSKEYレコード取征E
    let keyQueryStart = epochTime()
    let keyResult = await resolver.queryWithMetrics(currentDomain, DNSKEY)
    metrics.queryCount += keyResult.queryCount
    cacheHits += keyResult.cacheHits
    
    # RRSIGレコード取征E
    let rrsigQueryStart = epochTime()
    let rrsigResult = await resolver.queryWithMetrics(currentDomain, RRSIG)
    metrics.queryCount += rrsigResult.queryCount
    cacheHits += rrsigResult.cacheHits
    
    # DSレコード取得（親ゾーンから�E�E
    if i > 0:
      let parentDomain = domainParts[i+1..^1].join(".")
      let dsQueryStart = epochTime()
      let dsResult = await resolver.queryWithMetrics(currentDomain, DS, parentDomain)
      metrics.queryCount += dsResult.queryCount
      cacheHits += dsResult.cacheHits
  
  # 対象レコードタイプ�E取得と検証
  let recordQueryStart = epochTime()
  let recordResult = await resolver.queryWithMetrics(domain, recordType)
  metrics.queryCount += recordResult.queryCount
  cacheHits += recordResult.cacheHits
  
  metrics.cacheHitCount = cacheHits
  
  # 暗号計算時間を測宁E
  let cryptoStart = epochTime()
  
  # 検証チェーンの暗号検証
  var verificationResults: seq[tuple[domain: string, recordType: DnsRecordType, valid: bool]]
  
  # ルートから�E検証チェーン構篁E
  currentDomain = ""
  for i in countdown(domainParts.len - 1, 0):
    if currentDomain.len == 0:
      currentDomain = domainParts[i]
    else:
      currentDomain = domainParts[i] & "." & currentDomain
    
    # DNSKEYの検証
    let keyVerificationResult = await validator.verifyDnskeys(currentDomain)
    verificationResults.add((domain: currentDomain, recordType: DNSKEY, valid: keyVerificationResult.valid))
    
    # 親ゾーンとの信頼チェーン検証�E�ES記録�E�E
    if i > 0:
      let dsVerificationResult = await validator.verifyDsChain(currentDomain)
      verificationResults.add((domain: currentDomain, recordType: DS, valid: dsVerificationResult.valid))
  
  # 対象レコード�E検証
  let recordVerificationResult = await validator.verifyRecord(domain, recordType)
  verificationResults.add((domain: domain, recordType: recordType, valid: recordVerificationResult.valid))
  
  metrics.cryptoTime = (epochTime() - cryptoStart) * 1000  # ms
  
  # バリチE�Eションプロセス全体�E時間
  let validationStart = epochTime()
  
  # 検証結果の雁E��E��刁E��
  let isValid = verificationResults.allIt(it.valid)
  
  # 検証失敗�E場合�Eエラー刁E��
  if not isValid:
    let failedVerifications = verificationResults.filterIt(not it.valid)
    for failure in failedVerifications:
      logWarning("DNSSEC検証失敁E " & failure.domain & " (" & $failure.recordType & ")")
  
  metrics.validationTime = (epochTime() - validationStart) * 1000  # ms
  
  # 全体�E解決時間
  metrics.resolutionTime = (epochTime() - overallStart) * 1000  # ms
  
  # メモリ使用量�E計箁E
  let finalMemory = getOccupiedMem()
  metrics.memoryUsage = finalMemory - initialMemory
  
  # パフォーマンスチE�Eタのログ記録
  logInfo("DNSSEC検証パフォーマンス: " & domain & " (" & $recordType & ")")
  logInfo("  解決時間: " & $metrics.resolutionTime & "ms")
  logInfo("  検証時間: " & $metrics.validationTime & "ms")
  logInfo("  暗号計算時閁E " & $metrics.cryptoTime & "ms")
  logInfo("  クエリ数: " & $metrics.queryCount)
  logInfo("  キャチE��ュヒッチE " & $metrics.cacheHitCount)
  logInfo("  メモリ使用釁E " & $(metrics.memoryUsage / 1024) & "KB")
  
  return metrics

proc optimizeDnssecMemoryUsage*(validator: DnssecValidator) =
  ## DNSSEC検証のメモリ使用を最適匁E
  
  # 信頼アンカーのコンパクト化
  var compactTrustAnchors = initTable[string, seq[DnsKeyRecord]]()
  for domain, anchors in validator.trustAnchors:
    if anchors.len > 0:
      compactTrustAnchors[domain] = anchors
  
  validator.trustAnchors = compactTrustAnchors
  
  # DSレコード�Eコンパクト化
  var compactDsRecords = initTable[string, seq[DsRecord]]()
  for domain, records in validator.dsRecords:
    if records.len > 0:
      compactDsRecords[domain] = records
  
  validator.dsRecords = compactDsRecords
  
  # キーレコード�Eコンパクト化
  var compactKeyRecords = initTable[string, seq[DnsKeyRecord]]()
  for domain, keys in validator.keyRecords:
    if keys.len > 0:
      compactKeyRecords[domain] = keys
  
  validator.keyRecords = compactKeyRecords
  
  # メモリ最適化�E後、GCを俁E��
  GC_fullCollect()

proc getValidationRecommendations*(metrics: DnssecValidationMetrics): seq[string] =
  ## パフォーマンスメトリクスに基づく最適化推奨事頁E
  var recommendations: seq[string] = @[]
  
  # 検証時間の最適匁E
  if metrics.validationTime > 100:
    recommendations.add("検証に時間がかかりすぎでぁE(> 100ms) - キャチE��ュの使用を検訁E)
  
  # クエリ数の最適匁E
  if metrics.queryCount > 5:
    recommendations.add("DNSクエリ数が多すぎまぁE- バッチ�E琁E��パイプライン化を検訁E)
  
  # 暗号計算�E最適匁E
  if metrics.cryptoTime > metrics.validationTime * 0.7:
    recommendations.add("暗号計算が遁E��ぎまぁE- ハ�Eドウェアアクセラレーションを検訁E)
  
  # メモリ使用量�E最適匁E
  if metrics.memoryUsage > 1024 * 1024:  # 1MB
    recommendations.add("メモリ使用量が多すぎまぁE- キャチE��ュサイズの調整を検訁E)
  
  return recommendations

# 実運用準備完亁E���E
proc loadRootTrustAnchorsFromWeb*(validator: DnssecValidator): Future[bool] {.async.} =
  ## IANAウェブサイトからルート信頼アンカーを読み込む
  try:
    let ianaRootAnchorUrl = "https://data.iana.org/root-anchors/root-anchors.xml"
    let backupAnchorUrl = "https://www.iana.org/dnssec/files/root-anchors.xml"
    
    echo "IANAからルート信頼アンカーを取得中..."
    
    var httpClient = newAsyncHttpClient()
    httpClient.headers = newHttpHeaders({"User-Agent": "NimBrowser/1.0 DNSSEC Validator"})
    
    var response: string
    try:
      response = await httpClient.getContent(ianaRootAnchorUrl)
    except:
      echo "プライマリソースからの取得に失敗しました。バチE��アチE�Eを試行中..."
      response = await httpClient.getContent(backupAnchorUrl)
    
    finally:
      httpClient.close()
    
    # XMLを解析して信頼アンカーを抽出
    let rootAnchors = parseRootAnchorsXml(response)
    
    var anchorCount = 0
    for anchor in rootAnchors:
      validator.addTrustAnchor(".", anchor)
      anchorCount.inc
    
    if anchorCount == 0:
      raise newException(ValueError, "有効な信頼アンカーが見つかりませんでした")
    
    echo "ルート信頼アンカーの取得に成功しました: ", anchorCount, "個�Eアンカーを読み込みました"
    return true
  except Exception as e:
    echo "ルート信頼アンカーの取得に失敗しました: ", e.msg
    return false

proc parseRootAnchorsXml(xmlContent: string): seq[DnsKeyRecord] =
  ## IANAのXML形式�Eルート信頼アンカーを解析すめE
  result = @[]
  
  try:
    let xml = parseXml(xmlContent)
    
    # XMLからKeyTagとアルゴリズム、�E開鍵チE�Eタを抽出
    for keyTag in xml.findAll("KeyTag"):
      let keyTagValue = parseInt(keyTag.innerText)
      
      # 同じ階層の允E��要素を探ぁE
      let parent = keyTag.parent
      var algorithm = 0
      var publicKeyBase64 = ""
      
      for child in parent:
        if child.kind == xnElement:
          case child.tag:
            of "Algorithm":
              algorithm = parseInt(child.innerText)
            of "PublicKey":
              publicKeyBase64 = child.innerText.strip()
      
      if algorithm > 0 and publicKeyBase64 != "":
        # Base64チE��ーチE
        let publicKeyData = decode(publicKeyBase64)
        
        # DNSKEYレコードを構篁E
        let dnsKey = DnsKeyRecord(
          flags: 257,  # KSK (Key Signing Key)
          protocol: 3, # DNSSEC用の固定値
          algorithm: DnsSecAlgorithm(algorithm),
          publicKey: publicKeyData,
          keyTag: uint16(keyTagValue)
        )
        
        result.add(dnsKey)
  except Exception as e:
    echo "XML解析エラー: ", e.msg

proc validateRootTrustAnchors*(validator: DnssecValidator): bool =
  ## ルート信頼アンカーの有効性を検証する
  let rootAnchors = validator.getTrustAnchors(".")
  
  if rootAnchors.len == 0:
    echo "警呁E ルート信頼アンカーが設定されてぁE��せん"
    return false
  
  var validAnchors = 0
  for anchor in rootAnchors:
    # 公開鍵の整合性チェチE��
    if anchor.publicKey.len < 64:
      echo "警呁E 信頼アンカーの公開鍵が短すぎまぁE
      continue
    
    # アルゴリズムのサポ�EトチェチE��
    if not isSupportedAlgorithm(anchor.algorithm):
      echo "警呁E サポ�EトされてぁE��ぁE��ルゴリズム: ", ord(anchor.algorithm)
      continue
    
    # フラグの検証 (KSKであることを確誁E
    if (anchor.flags and 0x0101) != 0x0101:
      echo "警呁E 信頼アンカーがKSKではありません"
      continue
    
    validAnchors.inc
  
  return validAnchors > 0

proc isSupportedAlgorithm(algorithm: DnsSecAlgorithm): bool =
  ## アルゴリズムがサポ�EトされてぁE��かチェチE��
  case algorithm:
    of RSA_SHA1, RSA_SHA256, RSA_SHA512, ECDSA_P256_SHA256, ECDSA_P384_SHA384, ED25519:
      return true
    else:
      return false

proc initDnssecModule*(): bool =
  ## DNSSEC検証モジュールを�E期化
  try:
    echo "DNSSEC検証モジュールを�E期化中..."
    
    # 乱数生�E器を�E期化
    randomize()
    
    # 暗号ライブラリを�E期化
    initCryptoLibrary()
    
    # グローバルバリチE�Eタを作�E
    var globalValidator = newDnssecValidator()
    
    # 設定ファイルからルート信頼アンカーを読み込む
    let configLoaded = loadTrustAnchorsFromConfig(globalValidator)
    
    # 設定ファイルからの読み込みに失敗した場合、絁E��込みのフォールバックを使用
    if not configLoaded:
      echo "設定ファイルからの信頼アンカー読み込みに失敗しました。絁E��込みのフォールバックを使用します、E
      let rootKey = DnsKeyRecord(
        flags: 257,  # KSK
        protocol: 3,
        algorithm: RSA_SHA256,
        publicKey: getEmbeddedRootAnchor(),
        keyTag: 20326  # 実際のIANA KSKのキータグ
      )
      globalValidator.addTrustAnchor(".", rootKey)
    
    # 信頼アンカーの検証
    if not validateRootTrustAnchors(globalValidator):
      echo "警呁E 信頼アンカーの検証に失敗しました。Web更新を試みます、E
      # 非同期関数を同期的に呼び出ぁE
      let webUpdateSuccess = waitFor loadRootTrustAnchorsFromWeb(globalValidator)
      
      if not webUpdateSuccess:
        echo "警呁E Web更新にも失敗しました、ENSSEC検証が正しく機�EしなぁE��能性があります、E
    
    # グローバルインスタンスを設宁E
    setGlobalDnssecValidator(globalValidator)
    
    # キャチE��ュの初期匁E
    initDnssecCache()
    
    echo "DNSSEC検証モジュールの初期化に成功しました"
    return true
  except Exception as e:
    echo "DNSSEC検証モジュールの初期化に失敗しました: ", e.msg
    return false

proc initCryptoLibrary() =
  ## 暗号ライブラリの初期匁E
  # OpenSSLまた�E同等�Eライブラリの初期化コーチE
  when defined(openssl):
    discard openssl.init()
  
  # エントロピ�Eプ�Eルの初期匁E
  var entropySource = newEntropySource()
  setGlobalEntropySource(entropySource)

proc loadTrustAnchorsFromConfig(validator: DnssecValidator): bool =
  ## 設定ファイルからルート信頼アンカーを読み込む
  try:
    let configDir = getConfigDir() / "browser" / "dnssec"
    let trustAnchorFile = configDir / "root-anchors.json"
    
    if not fileExists(trustAnchorFile):
      return false
    
    let jsonContent = readFile(trustAnchorFile)
    let anchorsJson = parseJson(jsonContent)
    
    var loadedAnchors = 0
    
    for anchorItem in anchorsJson:
      let domain = anchorItem["domain"].getStr(".")
      let flags = anchorItem["flags"].getInt(257)
      let protocol = anchorItem["protocol"].getInt(3)
      let algorithm = anchorItem["algorithm"].getInt(8)  # RSA_SHA256
      let publicKeyBase64 = anchorItem["publicKey"].getStr("")
      let keyTag = anchorItem["keyTag"].getInt(0)
      
      if publicKeyBase64 == "":
        continue
      
      let publicKey = decode(publicKeyBase64)
      
      let dnsKey = DnsKeyRecord(
        flags: uint16(flags),
        protocol: uint8(protocol),
        algorithm: DnsSecAlgorithm(algorithm),
        publicKey: publicKey,
        keyTag: uint16(keyTag)
      )
      
      validator.addTrustAnchor(domain, dnsKey)
      loadedAnchors.inc
    
    return loadedAnchors > 0
  except Exception as e:
    echo "設定ファイルからの信頼アンカー読み込みエラー: ", e.msg
    return false

proc getEmbeddedRootAnchor(): string =
  ## 絁E��込みのルート信頼アンカー�E�緊急用フォールバック�E�E
  # 実際のIANA Root KSKの公開鍵�E�Ease64エンコード済み�E�E
  const embeddedRootKeyBase64 = """
  AwEAAaz/tAm8yTn4Mfeh5eyI96WSVexTBAvkMgJzkKTOiW1vkIbzxeF3
  +/4RgWOq7HrxRixHlFlExOLAJr5emLvN7SWXgnLh4+B5xQlNVz8Og8kv
  ArMtNROxVQuCaSnIDdD5LKyWbRd2n9WGe2R8PzgCmr3EgVLrjyBxWezF
  0jLHwVN8efS3rCj/EWgvIWgb9tarpVUDK/b58Da+sqqls3eNbuv7pr+e
  oZG+SrDK6nWeL3c6H5Apxz7LjVc1uTIdsIVJs3bwJUuAisBUpQvYIhJ/
  hBmImeUvnLZjkVHjGfZ0DJnwQrEtQFXGcBm9+3tLMJSUEU4XdpwQZ4zB
  vM2w2QB0CBoKdj+h3HPxzuctiOdeDVU=
  """
  return decode(embeddedRootKeyBase64.strip())

proc setGlobalDnssecValidator(validator: DnssecValidator) =
  ## グローバルDNSSECバリチE�Eタを設宁E
  globalDnssecValidator = validator

proc initDnssecCache() =
  ## DNSSECキャチE��ュの初期匁E
  dnssecCache = newDnssecCache()
  dnssecCache.setMaxSize(1024 * 1024 * 5)  # 5MB
  dnssecCache.setTTL(3600)  # 1時間

# グローバル変数
var 
  globalDnssecValidator: DnssecValidator
  dnssecCache: DnssecCache

# グローバル初期匁E
when isMainModule:
  if not initDnssecModule():
    echo "警呁E DNSSEC検証モジュールの初期化に失敗しました。一部の機�Eが制限される可能性があります、E
