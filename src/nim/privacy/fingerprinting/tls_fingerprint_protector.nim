# tls_fingerprint_protector.nim
## TLS指紋（JA3/JA3S）対策モジュール
## ブラウザのTLS ClientHelloメッセージの特徴を隠蔽し、トラッキングを防止する

import std/[
  options,
  tables, 
  sets,
  strutils,
  strformat,
  sequtils,
  algorithm,
  random,
  json,
  logging,
  times,
  net,
  hashes
]

type
  TlsFingerprintProtector* = ref TlsFingerprintProtectorObj
  TlsFingerprintProtectorObj = object
    enabled*: bool                   ## 有効フラグ
    tlsProfile*: TlsProfile          ## TLSプロファイル
    cipherSuiteOrder*: seq[int]      ## 暗号スイートの順序
    consistentProfile*: bool         ## 一貫したプロファイル使用
    sessionKey*: string              ## セッションキー
    logger*: Logger                  ## ロガー
    rotationInterval*: Duration      ## プロファイル回転間隔
    lastRotation*: Time              ## 最後の回転時間
    bypassDomains*: HashSet[string]  ## バイパスするドメイン

  TlsVersion* = enum
    tlsv10 = "TLSv1.0",
    tlsv11 = "TLSv1.1",
    tlsv12 = "TLSv1.2",
    tlsv13 = "TLSv1.3"

  TlsProfileType* = enum
    ## TLSプロファイルタイプ
    tptModern,     ## 最新のセキュアなプロファイル
    tptCompatible, ## 互換性重視プロファイル
    tptChrome,     ## Chrome風プロファイル
    tptFirefox,    ## Firefox風プロファイル
    tptSafari,     ## Safari風プロファイル
    tptRandom,     ## ランダムプロファイル
    tptCustom      ## カスタムプロファイル

  TlsProfile* = object
    name*: string                    ## プロファイル名
    profileType*: TlsProfileType     ## プロファイルタイプ
    tlsVersion*: TlsVersion          ## TLSバージョン
    cipherSuites*: seq[int]          ## 対応暗号スイート
    curves*: seq[int]                ## 対応楕円曲線
    pointFormats*: seq[int]          ## 対応ポイントフォーマット
    sigAlgos*: seq[int]              ## 対応署名アルゴリズム
    alpn*: seq[string]               ## ALPNプロトコル
    extensions*: seq[int]            ## 拡張
    ja3Fingerprint*: string          ## JA3指紋（計算値）

const
  # Chrome風のTLSプロファイル
  CHROME_TLS_PROFILE = TlsProfile(
    name: "Chrome Default",
    profileType: tptChrome,
    tlsVersion: tlsv13,
    cipherSuites: @[
      0x1301, 0x1302, 0x1303, 0xc02c, 0xc02b, 0xc030, 
      0xc02f, 0xcca9, 0xcca8, 0xc013, 0xc014, 0x009c, 
      0x009d, 0x002f, 0x0035
    ],
    curves: @[0x001d, 0x0017, 0x0018, 0x0019, 0x0100, 0x0101],
    pointFormats: @[0, 1, 2],
    sigAlgos: @[
      0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 
      0x0401, 0x0501, 0x0601, 0x0303, 0x0203, 0x0201
    ],
    alpn: @["h2", "http/1.1"],
    extensions: @[0, 10, 11, 13, 16, 17, 23, 43, 45, 51, 27, 65281]
  )

  # Firefox風のTLSプロファイル
  FIREFOX_TLS_PROFILE = TlsProfile(
    name: "Firefox Default",
    profileType: tptFirefox,
    tlsVersion: tlsv13,
    cipherSuites: @[
      0x1301, 0x1302, 0x1303, 0xc02c, 0xc030, 0xc02b, 
      0xc02f, 0xcca9, 0xcca8, 0xc013, 0xc014, 0x009c, 
      0x009d, 0x002f, 0x0035
    ],
    curves: @[0x001d, 0x0017, 0x0018, 0x0019, 0x0100],
    pointFormats: @[0],
    sigAlgos: @[
      0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 
      0x0401, 0x0501, 0x0601, 0x0303, 0x0203, 0x0201
    ],
    alpn: @["h2", "http/1.1"],
    extensions: @[0, 5, 10, 11, 13, 16, 23, 43, 45, 51, 27, 65281]
  )

  # Safari風のTLSプロファイル
  SAFARI_TLS_PROFILE = TlsProfile(
    name: "Safari Default",
    profileType: tptSafari,
    tlsVersion: tlsv13,
    cipherSuites: @[
      0x1301, 0x1302, 0x1303, 0xc02c, 0xc02b, 0xcca9, 
      0xcca8, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 
      0x0035
    ],
    curves: @[0x001d, 0x0017, 0x0018, 0x0019],
    pointFormats: @[0],
    sigAlgos: @[
      0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 
      0x0401, 0x0501, 0x0601, 0x0303, 0x0203, 0x0201
    ],
    alpn: @["h2", "http/1.1"],
    extensions: @[0, 10, 11, 13, 16, 17, 43, 45, 27, 65281]
  )

  # セキュリティ優先のTLSプロファイル
  SECURE_TLS_PROFILE = TlsProfile(
    name: "Modern Secure",
    profileType: tptModern,
    tlsVersion: tlsv13,
    cipherSuites: @[
      0x1301, 0x1302, 0x1303  # TLS_AES_*_GCM_SHA*
    ],
    curves: @[0x001d, 0x0017, 0x0018],  # x25519, secp256r1, secp384r1
    pointFormats: @[0],       # uncompressed
    sigAlgos: @[
      0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806  # ECDSA-*-SHA*
    ],
    alpn: @["h2", "http/1.1"],
    extensions: @[0, 10, 11, 13, 16, 43, 45, 51, 27]
  )

  # 互換性優先のTLSプロファイル
  COMPATIBLE_TLS_PROFILE = TlsProfile(
    name: "Compatible",
    profileType: tptCompatible,
    tlsVersion: tlsv12,
    cipherSuites: @[
      0xc02c, 0xc02b, 0xc030, 0xc02f, 0xcca9, 0xcca8, 
      0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035, 
      0x000a  # TLS_RSA_WITH_3DES_EDE_CBC_SHA
    ],
    curves: @[0x001d, 0x0017, 0x0018, 0x0019, 0x0100, 0x0101],
    pointFormats: @[0, 1, 2],
    sigAlgos: @[
      0x0401, 0x0501, 0x0601, 0x0403, 0x0503, 0x0603, 
      0x0201, 0x0203, 0x0202  # Including RSA-*-SHA*
    ],
    alpn: @["http/1.1"],
    extensions: @[0, 10, 11, 13, 16, 17, 23, 65281]
  )

  # 利用可能なすべての暗号スイート（TLS 1.2およびTLS 1.3）
  ALL_CIPHER_SUITES = [
    # TLS 1.3
    0x1301,  # TLS_AES_128_GCM_SHA256
    0x1302,  # TLS_AES_256_GCM_SHA384
    0x1303,  # TLS_CHACHA20_POLY1305_SHA256
    
    # TLS 1.2 ECDHE
    0xc02c,  # TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
    0xc02b,  # TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    0xc030,  # TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    0xc02f,  # TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    0xcca9,  # TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256
    0xcca8,  # TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    0xc013,  # TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA
    0xc014,  # TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA
    0xc009,  # TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA
    0xc00a,  # TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA
    
    # TLS 1.2 DHE
    0x009e,  # TLS_DHE_RSA_WITH_AES_128_GCM_SHA256
    0x009f,  # TLS_DHE_RSA_WITH_AES_256_GCM_SHA384
    0x0033,  # TLS_DHE_RSA_WITH_AES_128_CBC_SHA
    0x0039,  # TLS_DHE_RSA_WITH_AES_256_CBC_SHA
    
    # TLS 1.2 RSA
    0x009c,  # TLS_RSA_WITH_AES_128_GCM_SHA256
    0x009d,  # TLS_RSA_WITH_AES_256_GCM_SHA384
    0x002f,  # TLS_RSA_WITH_AES_128_CBC_SHA
    0x0035,  # TLS_RSA_WITH_AES_256_CBC_SHA
    0x000a   # TLS_RSA_WITH_3DES_EDE_CBC_SHA
  ]

  # すべての有効な楕円曲線（Elliptic Curves）
  ALL_CURVES = [
    0x001d,  # x25519
    0x0017,  # secp256r1
    0x0018,  # secp384r1
    0x0019,  # secp521r1
    0x0100,  # ffdhe2048
    0x0101   # ffdhe3072
  ]

  # すべての有効なポイントフォーマット
  ALL_POINT_FORMATS = [
    0,  # uncompressed
    1,  # ansiX962_compressed_prime
    2   # ansiX962_compressed_char2
  ]

  # すべての有効な署名アルゴリズム
  ALL_SIGNATURE_ALGORITHMS = [
    0x0403,  # ecdsa_secp256r1_sha256
    0x0503,  # ecdsa_secp384r1_sha384
    0x0603,  # ecdsa_secp521r1_sha512
    0x0804,  # rsa_pss_rsae_sha256
    0x0805,  # rsa_pss_rsae_sha384
    0x0806,  # rsa_pss_rsae_sha512
    0x0401,  # rsa_pkcs1_sha256
    0x0501,  # rsa_pkcs1_sha384
    0x0601,  # rsa_pkcs1_sha512
    0x0303,  # ecdsa_sha1
    0x0203,  # rsa_sha1
    0x0201,  # rsa_md5
    0x0202   # rsa_sha1
  ]

  # すべての有効なTLS拡張
  ALL_EXTENSIONS = [
    0,      # server_name
    5,      # status_request
    10,     # supported_groups
    11,     # ec_point_formats
    13,     # signature_algorithms
    16,     # application_layer_protocol_negotiation
    17,     # status_request_v2
    23,     # extended_master_secret
    35,     # session_ticket
    43,     # supported_versions
    45,     # psk_key_exchange_modes
    51,     # key_share
    27,     # compress_certificate
    65281   # renegotiation_info
  ]

# ユーティリティ関数
proc generateSessionKey(): string =
  ## 一貫性保持用のセッションキーを生成
  var r = initRand()
  result = ""
  for i in 0..<32:
    result.add(chr(r.rand(25) + ord('a')))

proc deterministicRandom(seed: string, min: int, max: int): int =
  ## 決定論的な乱数生成（同じシードからは同じ値を生成）
  var h = 0
  for c in seed:
    h = h * 31 + ord(c)
  result = (abs(h) mod (max - min + 1)) + min

proc hashString(s: string): int =
  ## 文字列のハッシュ値を計算
  var h = 0
  for c in s:
    h = h * 31 + ord(c)
  result = abs(h)

proc shuffleSeq[T](sequence: var seq[T], seedStr: string) =
  ## 決定論的にシーケンスをシャッフル
  let seed = hashString(seedStr)
  var r = initRand(seed)
  
  for i in countdown(sequence.high, 1):
    let j = r.rand(i + 1)
    if i != j:
      swap(sequence[i], sequence[j])

proc computeJA3Fingerprint*(tlsProfile: TlsProfile): string =
  ## JA3フィンガープリントを計算
  ## JA3 = VERSION,CIPHERS,EXTENSIONS,CURVES,POINT_FORMATS
  
  let tlsVersionStr = case tlsProfile.tlsVersion
    of tlsv10: "0x0301"
    of tlsv11: "0x0302"
    of tlsv12: "0x0303"
    of tlsv13: "0x0304"
  
  let cipherSuitesStr = tlsProfile.cipherSuites.mapIt(fmt"0x{it:04x}").join("-")
  let extensionsStr = tlsProfile.extensions.mapIt(fmt"0x{it:04x}").join("-")
  let curvesStr = tlsProfile.curves.mapIt(fmt"0x{it:04x}").join("-")
  let pointFormatsStr = tlsProfile.pointFormats.mapIt(fmt"0x{it:02x}").join("-")
  
  let ja3String = [tlsVersionStr, cipherSuitesStr, extensionsStr, curvesStr, pointFormatsStr].join(",")
  
  # MD5ハッシュを計算して返す
  var ctx: MD5Context
  md5Init(ctx)
  md5Update(ctx, ja3String)
  
  # ハッシュ結果をHEX文字列として返す
  var digest: MD5Digest
  md5Final(ctx, digest)
  
  # MD5ダイジェストを16進数文字列に変換
  result = ""
  for i in 0..<16:
    result.add(fmt"{digest[i]:02x}")

# メインのTlsFingerprintProtectorの実装
proc newTlsFingerprintProtector*(): TlsFingerprintProtector =
  ## 新しいTLS指紋保護モジュールを作成
  new(result)
  result.enabled = true
  result.tlsProfile = SECURE_TLS_PROFILE  # デフォルトはセキュアなプロファイル
  result.consistentProfile = true
  result.sessionKey = generateSessionKey()
  result.logger = newConsoleLogger()
  result.rotationInterval = initDuration(hours = 24)  # 24時間ごとに回転
  result.lastRotation = getTime()
  result.bypassDomains = initHashSet[string]()
  
  # 暗号スイートの順序を決定論的に設定
  result.cipherSuiteOrder = @[]
  for cs in ALL_CIPHER_SUITES:
    result.cipherSuiteOrder.add(cs)
  
  shuffleSeq(result.cipherSuiteOrder, result.sessionKey)
  
  # JA3指紋を計算
  result.tlsProfile.ja3Fingerprint = computeJA3Fingerprint(result.tlsProfile)

proc setTlsProfile*(protector: TlsFingerprintProtector, profileType: TlsProfileType) =
  ## TLSプロファイルタイプを設定
  case profileType
  of tptModern:
    protector.tlsProfile = SECURE_TLS_PROFILE
  of tptCompatible:
    protector.tlsProfile = COMPATIBLE_TLS_PROFILE
  of tptChrome:
    protector.tlsProfile = CHROME_TLS_PROFILE
  of tptFirefox:
    protector.tlsProfile = FIREFOX_TLS_PROFILE
  of tptSafari:
    protector.tlsProfile = SAFARI_TLS_PROFILE
  of tptRandom:
    # ランダムプロファイルを生成
    var profile = TlsProfile(
      name: "Random Profile",
      profileType: tptRandom,
      tlsVersion: tlsv13,
      cipherSuites: @[],
      curves: @[],
      pointFormats: @[],
      sigAlgos: @[],
      alpn: @["h2", "http/1.1"],
      extensions: @[]
    )
    
    # TLS 1.3の暗号スイートを必ず含める
    for cs in [0x1301, 0x1302, 0x1303]:
      profile.cipherSuites.add(cs)
    
    # 他の暗号スイートをランダムに追加
    let numCiphers = deterministicRandom(protector.sessionKey & "ciphers", 5, 12)
    var otherCiphers: seq[int] = @[]
    for cs in ALL_CIPHER_SUITES:
      if cs notin [0x1301, 0x1302, 0x1303]:
        otherCiphers.add(cs)
    
    shuffleSeq(otherCiphers, protector.sessionKey & "cipher_shuffle")
    for i in 0..<min(numCiphers, otherCiphers.len):
      profile.cipherSuites.add(otherCiphers[i])
    
    # 曲線をランダムに選択
    let numCurves = deterministicRandom(protector.sessionKey & "curves", 3, 6)
    var curves = ALL_CURVES
    shuffleSeq(curves, protector.sessionKey & "curve_shuffle")
    for i in 0..<min(numCurves, curves.len):
      profile.curves.add(curves[i])
    
    # ポイントフォーマットをランダムに選択
    let numFormats = deterministicRandom(protector.sessionKey & "formats", 1, 3)
    var formats = ALL_POINT_FORMATS
    shuffleSeq(formats, protector.sessionKey & "format_shuffle")
    for i in 0..<min(numFormats, formats.len):
      profile.pointFormats.add(formats[i])
    
    # 署名アルゴリズムをランダムに選択
    let numSigAlgos = deterministicRandom(protector.sessionKey & "sigalgos", 6, 12)
    var sigAlgos = ALL_SIGNATURE_ALGORITHMS
    shuffleSeq(sigAlgos, protector.sessionKey & "sigalgo_shuffle")
    for i in 0..<min(numSigAlgos, sigAlgos.len):
      profile.sigAlgos.add(sigAlgos[i])
    
    # 拡張をランダムに選択（server_nameは必須）
    profile.extensions.add(0)  # server_name
    let numExtensions = deterministicRandom(protector.sessionKey & "extensions", 6, 12)
    var extensions: seq[int] = @[]
    for ext in ALL_EXTENSIONS:
      if ext != 0:  # server_name以外
        extensions.add(ext)
    
    shuffleSeq(extensions, protector.sessionKey & "extension_shuffle")
    for i in 0..<min(numExtensions, extensions.len):
      profile.extensions.add(extensions[i])
    
    # JA3指紋を計算
    profile.ja3Fingerprint = computeJA3Fingerprint(profile)
    
    protector.tlsProfile = profile
  
  of tptCustom:
    # カスタムプロファイルの場合は何もしない（別途設定が必要）
    discard
  
  # JA3指紋を計算
  protector.tlsProfile.ja3Fingerprint = computeJA3Fingerprint(protector.tlsProfile)

proc setCustomTlsProfile*(
  protector: TlsFingerprintProtector, 
  tlsVersion: TlsVersion,
  cipherSuites: seq[int],
  curves: seq[int],
  pointFormats: seq[int],
  extensions: seq[int]
) =
  ## カスタムTLSプロファイルを設定
  var profile = TlsProfile(
    name: "Custom Profile",
    profileType: tptCustom,
    tlsVersion: tlsVersion,
    cipherSuites: cipherSuites,
    curves: curves,
    pointFormats: pointFormats,
    sigAlgos: protector.tlsProfile.sigAlgos,  # 既存の値を使用
    alpn: @["h2", "http/1.1"],
    extensions: extensions
  )
  
  # JA3指紋を計算
  profile.ja3Fingerprint = computeJA3Fingerprint(profile)
  
  protector.tlsProfile = profile

proc enable*(protector: TlsFingerprintProtector) =
  ## 保護を有効化
  protector.enabled = true

proc disable*(protector: TlsFingerprintProtector) =
  ## 保護を無効化
  protector.enabled = false

proc isEnabled*(protector: TlsFingerprintProtector): bool =
  ## 保護が有効かどうか
  return protector.enabled

proc setRotationInterval*(protector: TlsFingerprintProtector, hours: int) =
  ## プロファイル回転間隔を設定
  protector.rotationInterval = initDuration(hours = hours)

proc bypassForDomain*(protector: TlsFingerprintProtector, domain: string) =
  ## 特定のドメインをバイパスリストに追加
  protector.bypassDomains.incl(domain)

proc shouldBypassDomain*(protector: TlsFingerprintProtector, domain: string): bool =
  ## ドメインをバイパスすべきかどうか
  return domain in protector.bypassDomains

proc rotateProfileIfNeeded*(protector: TlsFingerprintProtector) =
  ## 必要に応じてプロファイルを回転
  let currentTime = getTime()
  if currentTime - protector.lastRotation > protector.rotationInterval:
    # 新しいセッションキーを生成
    protector.sessionKey = generateSessionKey()
    
    # 現在のプロファイルタイプを保持したまま新しいプロファイルを設定
    protector.setTlsProfile(protector.tlsProfile.profileType)
    
    # 回転時間を更新
    protector.lastRotation = currentTime

proc getClientHelloConfig*(
  protector: TlsFingerprintProtector, 
  domain: string = ""
): JsonNode =
  ## ClientHello設定を取得
  if not protector.enabled or (domain.len > 0 and protector.shouldBypassDomain(domain)):
    return %*{"enabled": false}
  
  # 必要に応じてプロファイルを回転
  protector.rotateProfileIfNeeded()
  
  result = %*{
    "enabled": true,
    "tlsVersion": $protector.tlsProfile.tlsVersion,
    "cipherSuites": protector.tlsProfile.cipherSuites,
    "curves": protector.tlsProfile.curves,
    "pointFormats": protector.tlsProfile.pointFormats,
    "sigAlgos": protector.tlsProfile.sigAlgos,
    "extensions": protector.tlsProfile.extensions,
    "alpn": protector.tlsProfile.alpn,
    "ja3Fingerprint": protector.tlsProfile.ja3Fingerprint
  }

proc getProtectionStatus*(protector: TlsFingerprintProtector): JsonNode =
  ## 保護状態をJSON形式で取得
  result = %*{
    "enabled": protector.enabled,
    "profile": {
      "name": protector.tlsProfile.name,
      "type": $protector.tlsProfile.profileType,
      "tlsVersion": $protector.tlsProfile.tlsVersion,
      "ja3Fingerprint": protector.tlsProfile.ja3Fingerprint
    },
    "rotationInterval": $protector.rotationInterval,
    "bypassDomains": toSeq(protector.bypassDomains),
    "consistentProfile": protector.consistentProfile
  }

# エンジン特性への影響を最小化するための関数
proc applyClientHelloModifications*(
  protector: TlsFingerprintProtector,
  clientHello: var seq[byte]
): bool =
  ## ClientHelloパケットを修正する実装
  ## TLSハンドシェイクパケットの構造に基づいてバイナリデータを直接操作
  if not protector.enabled:
    return false
  
  # 最小限のバリデーション
  if clientHello.len < 43:  # TLSハンドシェイクの最小長: Record(5) + Handshake(4) + ClientHello(34)
    protector.logger.log(lvlError, "ClientHelloデータ長が不足しています")
    return false
  
  # TLSレコードヘッダを確認
  if clientHello[0] != 0x16:  # Handshake
    protector.logger.log(lvlError, "TLSレコードタイプがHandshakeではありません")
    return false
  
  # TLSバージョン: index 1-2
  # クライアントハンドシェイクは通常、TLS 1.0以上を示すため0x0301以上を期待
  if clientHello[1] < 0x03 or (clientHello[1] == 0x03 and clientHello[2] == 0x00):
    protector.logger.log(lvlError, "非対応TLSバージョン")
    return false
  
  # ハンドシェイクタイプを確認: 0x01 = ClientHello
  let handshakeType = clientHello[5]
  if handshakeType != 0x01:  # ClientHello
    protector.logger.log(lvlError, "ハンドシェイクタイプがClientHelloではありません")
    return false
  
  # ClientHelloの作業コピーを作成
  var modifiedClientHello = clientHello.toSeq()
  var modified = false
  
  # レコード層のTLSバージョンを修正
  if protector.tlsProfile.tlsVersion == tlsv12:
    modifiedClientHello[1] = 0x03
    modifiedClientHello[2] = 0x03  # TLS 1.2
    modified = true
  elif protector.tlsProfile.tlsVersion == tlsv13:
    modifiedClientHello[1] = 0x03
    modifiedClientHello[2] = 0x03  # TLS 1.3も1.2として表現されることに注意
    modified = true
  
  # ClientHello本体の位置を特定
  var pos = 9  # TLSレコードヘッダ(5) + ハンドシェイクヘッダ(4)
  
  # ClientHelloバージョン
  let clientHelloVersionPos = pos + 0  # ClientHelloの先頭
  modifiedClientHello[clientHelloVersionPos] = 0x03
  
  if protector.tlsProfile.tlsVersion == tlsv12:
    modifiedClientHello[clientHelloVersionPos+1] = 0x03  # TLS 1.2
    modified = true
  elif protector.tlsProfile.tlsVersion == tlsv13:
    modifiedClientHello[clientHelloVersionPos+1] = 0x03  # TLS 1.3も1.2として表現されることに注意
    modified = true
  
  # ランダム値の位置をスキップ (pos + 2) + 32バイト
  pos += 34
  
  # セッションIDの長さ
  let sessionIdLen = modifiedClientHello[pos].int
  pos += 1 + sessionIdLen
  
  # 暗号スイートの位置 - これが最も重要な修正対象
  let cipherSuitesLenPos = pos
  let cipherSuitesLen = (modifiedClientHello[pos].int shl 8) or modifiedClientHello[pos+1].int
  pos += 2
  
  # 暗号スイートの順序を修正
  if protector.tlsProfile.cipherSuites.len > 0:
    var newCipherSuites: seq[byte] = @[]
    for cs in protector.tlsProfile.cipherSuites:
      newCipherSuites.add((cs shr 8).byte)
      newCipherSuites.add((cs and 0xFF).byte)
    
    # 新しい暗号スイートリストの長さをバイト数に変換
    let newCipherSuitesLen = newCipherSuites.len
    
    # 新しい暗号スイートを適用
    if newCipherSuitesLen > 0 and newCipherSuitesLen != cipherSuitesLen:
      # 長さが異なる場合、パケット全体を再構築
      var newClientHello: seq[byte] = modifiedClientHello[0..<cipherSuitesLenPos]
      
      # 新しい長さを追加
      newClientHello.add((newCipherSuitesLen shr 8).byte)
      newClientHello.add((newCipherSuitesLen and 0xFF).byte)
      
      # 新しい暗号スイートリストを追加
      newClientHello.add(newCipherSuites)
      
      # 残りのデータを追加
      newClientHello.add(modifiedClientHello[pos + cipherSuitesLen..^1])
      
      # ハンドシェイクの長さフィールドを更新
      let lengthDiff = newCipherSuitesLen - cipherSuitesLen
      let handshakeLenPos = 6  # ハンドシェイク長さフィールドの位置
      let handshakeLen = (newClientHello[handshakeLenPos].int shl 16) or
                         (newClientHello[handshakeLenPos+1].int shl 8) or
                          newClientHello[handshakeLenPos+2].int
      let newHandshakeLen = handshakeLen + lengthDiff
      
      newClientHello[handshakeLenPos] = ((newHandshakeLen shr 16) and 0xFF).byte
      newClientHello[handshakeLenPos+1] = ((newHandshakeLen shr 8) and 0xFF).byte
      newClientHello[handshakeLenPos+2] = (newHandshakeLen and 0xFF).byte
      
      # レコードの長さフィールドも更新
      let recordLenPos = 3  # レコード長さフィールドの位置
      let recordLen = (newClientHello[recordLenPos].int shl 8) or newClientHello[recordLenPos+1].int
      let newRecordLen = recordLen + lengthDiff
      
      newClientHello[recordLenPos] = ((newRecordLen shr 8) and 0xFF).byte
      newClientHello[recordLenPos+1] = (newRecordLen and 0xFF).byte
      
      modifiedClientHello = newClientHello
      modified = true
    elif newCipherSuitesLen == cipherSuitesLen:
      # 長さが同じ場合、既存のスロットに上書き
      var suitePos = pos
      for i in 0..<(newCipherSuitesLen div 2):
        let highByte = newCipherSuites[i*2]
        let lowByte = newCipherSuites[i*2+1]
        modifiedClientHello[suitePos] = highByte
        modifiedClientHello[suitePos+1] = lowByte
        suitePos += 2
      modified = true
  
  pos += cipherSuitesLen
  
  # 圧縮メソッドをスキップ
  let compressionMethodsLen = modifiedClientHello[pos].int
  pos += 1 + compressionMethodsLen
  
  # 拡張フィールドがあるか確認
  if pos + 2 <= modifiedClientHello.len:
    let extensionsLenPos = pos
    let extensionsLen = (modifiedClientHello[pos].int shl 8) or modifiedClientHello[pos+1].int
    pos += 2
    
    # 拡張フィールドの処理
    var extensionsEndPos = pos + extensionsLen
    if extensionsEndPos <= modifiedClientHello.len:
      var newExtensions: seq[byte] = @[]
      
      # supported_groupsとec_point_formatsの拡張を修正
      var currentPos = pos
      while currentPos < extensionsEndPos:
        let extType = (modifiedClientHello[currentPos].int shl 8) or modifiedClientHello[currentPos+1].int
        let extLen = (modifiedClientHello[currentPos+2].int shl 8) or modifiedClientHello[currentPos+3].int
        
        if extType == 0x000a:  # supported_groups（旧elliptic_curves）
          # サポートされた楕円曲線グループの拡張を修正
          let curvesPos = currentPos + 4
          
          # 置換するグループリストを構築
          var newCurves: seq[byte] = @[]
          
          # 内部リストの長さフィールドを考慮（先頭2バイト）
          newCurves.add(0)  # 長さ上位バイト（後で更新）
          newCurves.add(0)  # 長さ下位バイト（後で更新）
          
          # 設定された曲線を追加
          for curve in protector.tlsProfile.curves:
            newCurves.add((curve shr 8).byte)
            newCurves.add((curve and 0xFF).byte)
          
          # 内部リストの長さを更新
          let newCurvesLen = newCurves.len - 2  # 長さフィールド自体を除く
          newCurves[0] = ((newCurvesLen shr 8) and 0xFF).byte
          newCurves[1] = (newCurvesLen and 0xFF).byte
          
          # 新しい拡張を作成
          var newExt: seq[byte] = @[]
          newExt.add(0x00)  # supported_groups拡張タイプ上位バイト
          newExt.add(0x0a)  # supported_groups拡張タイプ下位バイト
          newExt.add(((newCurves.len) shr 8).byte)  # 拡張長さ上位バイト
          newExt.add(((newCurves.len) and 0xFF).byte)  # 拡張長さ下位バイト
          newExt.add(newCurves)
          
          newExtensions.add(newExt)
          modified = true
          
        elif extType == 0x000b:  # ec_point_formats
          # 点フォーマットの拡張を修正
          if protector.tlsProfile.pointFormats.len > 0:
            var newFormats: seq[byte] = @[]
            
            # フォーマットリストの長さ（1バイト）
            newFormats.add(protector.tlsProfile.pointFormats.len.byte)
            
            # 設定されたポイントフォーマットを追加
            for format in protector.tlsProfile.pointFormats:
              newFormats.add(format.byte)
            
            # 新しい拡張を作成
            var newExt: seq[byte] = @[]
            newExt.add(0x00)  # ec_point_formats拡張タイプ上位バイト
            newExt.add(0x0b)  # ec_point_formats拡張タイプ下位バイト
            newExt.add(((newFormats.len) shr 8).byte)  # 拡張長さ上位バイト
            newExt.add(((newFormats.len) and 0xFF).byte)  # 拡張長さ下位バイト
            newExt.add(newFormats)
            
            newExtensions.add(newExt)
            modified = true
          else:
            # 既存の拡張をコピー
            var existingExt: seq[byte] = modifiedClientHello[currentPos..currentPos+3+extLen-1]
            newExtensions.add(existingExt)
          
        elif extType == 0x002b:  # supported_versions（TLS 1.3）
          # TLS 1.3の場合に対応するサポートバージョンを修正
          if protector.tlsProfile.tlsVersion == tlsv13:
            var supportedVersions: seq[byte] = @[]
            
            # バージョンリストの長さ（1バイト）
            supportedVersions.add((2 * 1).byte)  # 2バイト * バージョン数
            
            # TLS 1.3のバージョン値
            supportedVersions.add(0x03)  # メジャーバージョン
            supportedVersions.add(0x04)  # マイナーバージョン（TLS 1.3）
            
            # 新しい拡張を作成
            var newExt: seq[byte] = @[]
            newExt.add(0x00)  # supported_versions拡張タイプ上位バイト
            newExt.add(0x2b)  # supported_versions拡張タイプ下位バイト
            newExt.add(((supportedVersions.len) shr 8).byte)  # 拡張長さ上位バイト
            newExt.add(((supportedVersions.len) and 0xFF).byte)  # 拡張長さ下位バイト
            newExt.add(supportedVersions)
            
            newExtensions.add(newExt)
            modified = true
          else:
            # TLS 1.3以外の場合は拡張を削除（存在する場合）
            # newExtensionsに追加しないことで削除される
            modified = true
            
        else:
          # その他の拡張をそのままコピー
          var existingExt: seq[byte] = modifiedClientHello[currentPos..currentPos+3+extLen-1]
          newExtensions.add(existingExt)
        
        currentPos += 4 + extLen
      
      # 拡張部分を置き換え
      var newClientHello: seq[byte] = modifiedClientHello[0..<extensionsLenPos]
      
      # 新しい拡張の長さを追加
      let newExtensionsLen = newExtensions.len
      newClientHello.add((newExtensionsLen shr 8).byte)
      newClientHello.add((newExtensionsLen and 0xFF).byte)
      
      # 新しい拡張データを追加
      newClientHello.add(newExtensions)
      
      # ハンドシェイクの長さを更新
      let lengthDiff = newExtensionsLen - extensionsLen
      let handshakeLenPos = 6  # ハンドシェイク長さフィールドの位置
      let handshakeLen = (newClientHello[handshakeLenPos].int shl 16) or
                         (newClientHello[handshakeLenPos+1].int shl 8) or
                          newClientHello[handshakeLenPos+2].int
      let newHandshakeLen = handshakeLen + lengthDiff
      
      newClientHello[handshakeLenPos] = ((newHandshakeLen shr 16) and 0xFF).byte
      newClientHello[handshakeLenPos+1] = ((newHandshakeLen shr 8) and 0xFF).byte
      newClientHello[handshakeLenPos+2] = (newHandshakeLen and 0xFF).byte
      
      # レコードの長さを更新
      let recordLenPos = 3  # レコード長さフィールドの位置
      let recordLen = (newClientHello[recordLenPos].int shl 8) or newClientHello[recordLenPos+1].int
      let newRecordLen = recordLen + lengthDiff
      
      newClientHello[recordLenPos] = ((newRecordLen shr 8) and 0xFF).byte
      newClientHello[recordLenPos+1] = (newRecordLen and 0xFF).byte
      
      modifiedClientHello = newClientHello
      modified = true
  
  # 修正が行われた場合、新しいClientHelloを返す
  if modified:
    clientHello = modifiedClientHello
    protector.logger.log(lvlInfo, "ClientHello修正適用完了: 新しいJA3指紋=" & protector.tlsProfile.ja3Fingerprint)
  else:
    protector.logger.log(lvlDebug, "ClientHello修正は不要でした")
  
  return modified

proc getJA3Fingerprint*(protector: TlsFingerprintProtector): string =
  ## 現在のJA3フィンガープリントを取得
  return protector.tlsProfile.ja3Fingerprint

when isMainModule:
  # テスト用コード
  let protector = newTlsFingerprintProtector()
  
  # Chrome風プロファイルに設定
  protector.setTlsProfile(tptChrome)
  echo "Chrome Profile JA3: ", protector.getJA3Fingerprint()
  
  # Firefox風プロファイルに設定
  protector.setTlsProfile(tptFirefox)
  echo "Firefox Profile JA3: ", protector.getJA3Fingerprint()
  
  # ランダムプロファイルに設定
  protector.setTlsProfile(tptRandom)
  echo "Random Profile JA3: ", protector.getJA3Fingerprint()
  
  # ClientHello設定のテスト
  echo "Client Hello Config: ", protector.getClientHelloConfig() 