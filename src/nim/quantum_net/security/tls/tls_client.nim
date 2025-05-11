# TLS 1.3 Client Implementation
# RFC 8446準拠
#
# QUICおよびHTTP/3と連携するための最適化されたTLS 1.3クライアント実装

import std/[asyncdispatch, options, tables, sets, strutils, strformat, times, random]
import std/[deques, hashes, sugar, net, streams, endians, sequtils]

# 暗号化アルゴリズムのインポート
import ../../compression/common/buffer
import ../../../quantum_arch/data/varint
import ../certificates/store
import ../certificates/validator

const
  # TLS 1.3 バージョン
  TLS_1_3_VERSION = 0x0304

  # TLS 1.3 メッセージタイプ
  HANDSHAKE_MSG_CLIENT_HELLO = 1
  HANDSHAKE_MSG_SERVER_HELLO = 2
  HANDSHAKE_MSG_NEW_SESSION_TICKET = 4
  HANDSHAKE_MSG_END_OF_EARLY_DATA = 5
  HANDSHAKE_MSG_ENCRYPTED_EXTENSIONS = 8
  HANDSHAKE_MSG_CERTIFICATE = 11
  HANDSHAKE_MSG_CERTIFICATE_REQUEST = 13
  HANDSHAKE_MSG_CERTIFICATE_VERIFY = 15
  HANDSHAKE_MSG_FINISHED = 20
  HANDSHAKE_MSG_KEY_UPDATE = 24
  HANDSHAKE_MSG_MESSAGE_HASH = 254

  # TLS 1.3 拡張タイプ
  EXT_SERVER_NAME = 0
  EXT_MAX_FRAGMENT_LENGTH = 1
  EXT_STATUS_REQUEST = 5
  EXT_SUPPORTED_GROUPS = 10
  EXT_SIGNATURE_ALGORITHMS = 13
  EXT_USE_SRTP = 14
  EXT_ALN = 16
  EXT_PADDING = 21
  EXT_PRE_SHARED_KEY = 41
  EXT_EARLY_DATA = 42
  EXT_SUPPORTED_VERSIONS = 43
  EXT_COOKIE = 44
  EXT_PSK_KEY_EXCHANGE_MODES = 45
  EXT_CERTIFICATE_AUTHORITIES = 47
  EXT_OID_FILTERS = 48
  EXT_POST_HANDSHAKE_AUTH = 49
  EXT_SIGNATURE_ALGORITHMS_CERT = 50
  EXT_KEY_SHARE = 51
  EXT_QUIC_TRANSPORT_PARAMETERS = 0xffa5 # QUICトランスポートパラメータ (IANA割り当て)

  # TLS 1.3 暗号スイート
  TLS_AES_128_GCM_SHA256 = 0x1301
  TLS_AES_256_GCM_SHA384 = 0x1302
  TLS_CHACHA20_POLY1305_SHA256 = 0x1303
  TLS_AES_128_CCM_SHA256 = 0x1304
  TLS_AES_128_CCM_8_SHA256 = 0x1305
  
  # TLS 1.3 鍵交換グループ
  NAMED_GROUP_SECP256R1 = 0x0017
  NAMED_GROUP_SECP384R1 = 0x0018
  NAMED_GROUP_SECP521R1 = 0x0019
  NAMED_GROUP_X25519 = 0x001D
  NAMED_GROUP_X448 = 0x001E

  # TLS 1.3 署名アルゴリズム
  SIGN_ECDSA_SECP256R1_SHA256 = 0x0403
  SIGN_ECDSA_SECP384R1_SHA384 = 0x0503
  SIGN_ECDSA_SECP521R1_SHA512 = 0x0603
  SIGN_RSA_PSS_RSAE_SHA256 = 0x0804
  SIGN_RSA_PSS_RSAE_SHA384 = 0x0805
  SIGN_RSA_PSS_RSAE_SHA512 = 0x0806
  SIGN_ED25519 = 0x0807
  SIGN_ED448 = 0x0808

  # TLS 1.3 アラートレベル
  ALERT_LEVEL_WARNING = 1
  ALERT_LEVEL_FATAL = 2

  # TLS 1.3 アラート説明
  ALERT_CLOSE_NOTIFY = 0
  ALERT_UNEXPECTED_MESSAGE = 10
  ALERT_BAD_RECORD_MAC = 20
  ALERT_RECORD_OVERFLOW = 22
  ALERT_HANDSHAKE_FAILURE = 40
  ALERT_BAD_CERTIFICATE = 42
  ALERT_UNSUPPORTED_CERTIFICATE = 43
  ALERT_CERTIFICATE_REVOKED = 44
  ALERT_CERTIFICATE_EXPIRED = 45
  ALERT_CERTIFICATE_UNKNOWN = 46
  ALERT_ILLEGAL_PARAMETER = 47
  ALERT_UNKNOWN_CA = 48
  ALERT_ACCESS_DENIED = 49
  ALERT_DECODE_ERROR = 50
  ALERT_DECRYPT_ERROR = 51
  ALERT_PROTOCOL_VERSION = 70
  ALERT_INSUFFICIENT_SECURITY = 71
  ALERT_INTERNAL_ERROR = 80
  ALERT_INAPPROPRIATE_FALLBACK = 86
  ALERT_USER_CANCELED = 90
  ALERT_MISSING_EXTENSION = 109
  ALERT_UNSUPPORTED_EXTENSION = 110
  ALERT_UNRECOGNIZED_NAME = 112
  ALERT_BAD_CERTIFICATE_STATUS_RESPONSE = 113
  ALERT_UNKNOWN_PSK_IDENTITY = 115
  ALERT_CERTIFICATE_REQUIRED = 116
  ALERT_NO_APPLICATION_PROTOCOL = 120

type
  TlsRecordType = enum
    rtInvalid = 0
    rtChangeCipherSpec = 20
    rtAlert = 21
    rtHandshake = 22
    rtApplicationData = 23
  
  TlsVersion* = enum
    TLS10 = (3, 1)
    TLS11 = (3, 2)
    TLS12 = (3, 3)
    TLS13 = (3, 4)
  
  TlsHandshakeType = enum
    htClientHello = 1
    htServerHello = 2
    htNewSessionTicket = 4
    htEndOfEarlyData = 5
    htEncryptedExtensions = 8
    htCertificate = 11
    htCertificateRequest = 13
    htCertificateVerify = 15
    htFinished = 20
    htKeyUpdate = 24
    htMessageHash = 254
  
  TlsAlertLevel = enum
    alWarning = 1
    alFatal = 2
  
  TlsAlertDescription = enum
    adCloseNotify = 0
    adUnexpectedMessage = 10
    adBadRecordMac = 20
    adRecordOverflow = 22
    adHandshakeFailure = 40
    adBadCertificate = 42
    adUnsupportedCertificate = 43
    adCertificateRevoked = 44
    adCertificateExpired = 45
    adCertificateUnknown = 46
    adIllegalParameter = 47
    adUnknownCa = 48
    adAccessDenied = 49
    adDecodeError = 50
    adDecryptError = 51
    adProtocolVersion = 70
    adInsufficientSecurity = 71
    adInternalError = 80
    adInappropriateFallback = 86
    adUserCanceled = 90
    adMissingExtension = 109
    adUnsupportedExtension = 110
    adUnrecognizedName = 112
    adBadCertificateStatusResponse = 113
    adUnknownPskIdentity = 115
    adCertificateRequired = 116
    adNoApplicationProtocol = 120
  
  TlsExtension = object
    extensionType*: uint16
    data*: seq[byte]
  
  TlsRecord = object
    recordType*: TlsRecordType
    version*: TlsVersion
    fragment*: seq[byte]
  
  TlsHandshakeMessage = object
    handshakeType*: TlsHandshakeType
    data*: seq[byte]
  
  TlsAlert = object
    level*: TlsAlertLevel
    description*: TlsAlertDescription
  
  TlsError* = object of CatchableError
  
  TlsConfig* = object
    serverName*: string
    alpnProtocols*: seq[string]
    verifyPeer*: bool
    cipherSuites*: seq[uint16]
    supportedGroups*: seq[uint16]
    signatureAlgorithms*: seq[uint16]
    maxEarlyDataSize*: uint32
    sessionTickets*: bool
    pskModes*: seq[byte]
    transportParams*: seq[byte] # QUIC Transport Parameters
    caStore*: CertificateStore
    certificateValidator*: CertificateValidator
  
  TlsClientState = enum
    csUninitialized
    csClientHelloSent
    csServerHelloReceived
    csEncryptedExtensionsReceived
    csCertificateReceived
    csCertificateVerifyReceived
    csFinishedReceived
    csEstablished
    csClosing
    csClosed
  
  TlsClient* = ref object
    config*: TlsConfig
    state*: TlsClientState
    version*: TlsVersion
    handshakeMessages*: seq[TlsHandshakeMessage]
    clientHello*: seq[byte]
    serverHello*: seq[byte]
    negotiatedCipherSuite*: uint16
    negotiatedGroup*: uint16
    privateKey*: seq[byte]
    publicKey*: seq[byte]
    clientRandom*: seq[byte]
    serverRandom*: seq[byte]
    handshakeSecret*: seq[byte]
    earlySecret*: seq[byte]
    masterSecret*: seq[byte]
    clientHandshakeTrafficSecret*: seq[byte]
    serverHandshakeTrafficSecret*: seq[byte]
    clientApplicationTrafficSecret*: seq[byte]
    serverApplicationTrafficSecret*: seq[byte]
    serverCertificate*: seq[byte]
    serverCertificateVerified*: bool
    negotiatedAlpn*: string
    peerTransportParams*: seq[byte]
    session*: TlsSession
    earlyDataAccepted*: bool
    receivedNewSessionTicket*: bool
    newSessionTicket*: TlsNewSessionTicket
  
  TlsSession* = ref object
    sessionId*: seq[byte]
    psk*: seq[byte]
    pskIdentity*: seq[byte]
    ticketAgeAdd*: uint32
    ticketNonce*: seq[byte]
    creationTime*: Time
    maxEarlyDataSize*: uint32
    cipherSuite*: uint16
    alpn*: string
  
  TlsNewSessionTicket* = object
    ticketLifetime*: uint32
    ticketAgeAdd*: uint32
    ticketNonce*: seq[byte]
    ticket*: seq[byte]
    maxEarlyDataSize*: uint32

# デフォルトTLS設定
proc defaultTlsConfig*(): TlsConfig =
  result = TlsConfig(
    serverName: "",
    alpnProtocols: @[],
    verifyPeer: true,
    cipherSuites: @[
      TLS_AES_128_GCM_SHA256,
      TLS_AES_256_GCM_SHA384,
      TLS_CHACHA20_POLY1305_SHA256
    ],
    supportedGroups: @[
      NAMED_GROUP_X25519,
      NAMED_GROUP_SECP256R1,
      NAMED_GROUP_SECP384R1
    ],
    signatureAlgorithms: @[
      SIGN_ECDSA_SECP256R1_SHA256,
      SIGN_ECDSA_SECP384R1_SHA384,
      SIGN_RSA_PSS_RSAE_SHA256,
      SIGN_ED25519
    ],
    maxEarlyDataSize: 0,
    sessionTickets: true,
    pskModes: @[0], # psk_ke モード
    caStore: newCertificateStore()
  )

# TLSクライアントの作成
proc newTlsClient*(config: TlsConfig): TlsClient =
  result = TlsClient(
    config: config,
    state: csUninitialized,
    version: TLS13,
    handshakeMessages: @[],
    negotiatedCipherSuite: 0,
    negotiatedGroup: 0,
    clientRandom: newSeq[byte](32),
    serverRandom: newSeq[byte](0),
    serverCertificateVerified: false,
    earlyDataAccepted: false,
    receivedNewSessionTicket: false
  )
  
  # クライアントランダム値の生成
  for i in 0..<result.clientRandom.len:
    result.clientRandom[i] = byte(rand(0..255))

# 拡張データをエンコード
proc encodeExtension(extension: TlsExtension): seq[byte] =
  var buffer = newSeq[byte]()
  
  # 拡張タイプ
  var typeBytes = newSeq[byte](2)
  bigEndian16(addr typeBytes[0], addr extension.extensionType)
  buffer.add(typeBytes)
  
  # 拡張データ長
  var lengthBytes = newSeq[byte](2)
  let length = uint16(extension.data.len)
  bigEndian16(addr lengthBytes[0], addr length)
  buffer.add(lengthBytes)
  
  # 拡張データ
  buffer.add(extension.data)
  
  return buffer

# サーバー名拡張の作成
proc createServerNameExtension(serverName: string): TlsExtension =
  var data = newSeq[byte]()
  
  # リスト長用の2バイト (後で更新)
  data.add(0)
  data.add(0)
  
  # エントリータイプ (HostName = 0)
  data.add(0)
  
  # HostName長
  let nameLength = uint16(serverName.len)
  var nameLengthBytes = newSeq[byte](2)
  bigEndian16(addr nameLengthBytes[0], addr nameLength)
  data.add(nameLengthBytes)
  
  # HostName
  for c in serverName:
    data.add(byte(c))
  
  # リスト長を更新
  let listLength = uint16(data.len - 2)
  bigEndian16(addr data[0], addr listLength)
  
  return TlsExtension(
    extensionType: EXT_SERVER_NAME,
    data: data
  )

# ALPNプロトコル拡張の作成
proc createAlpnExtension(protocols: seq[string]): TlsExtension =
  var data = newSeq[byte]()
  
  # プロトコルリスト長用の2バイト (後で更新)
  data.add(0)
  data.add(0)
  
  var protocolsLenTotal = 0
  
  # 各プロトコルを追加
  for protocol in protocols:
    # プロトコル長
    data.add(byte(protocol.len))
    protocolsLenTotal += 1
    
    # プロトコル
    for c in protocol:
      data.add(byte(c))
    protocolsLenTotal += protocol.len
  
  # リスト長を更新
  let listLength = uint16(protocolsLenTotal)
  bigEndian16(addr data[0], addr listLength)
  
  return TlsExtension(
    extensionType: EXT_ALN,
    data: data
  )

# サポートバージョン拡張の作成
proc createSupportedVersionsExtension(): TlsExtension =
  var data = newSeq[byte]()
  
  # バージョンの数
  data.add(2) # 1つのバージョン = 2バイト
  
  # バージョンの値
  data.add(3) # Major version
  data.add(4) # Minor version (TLS 1.3)
  
  return TlsExtension(
    extensionType: EXT_SUPPORTED_VERSIONS,
    data: data
  )

# サポート暗号スイート拡張の作成
proc createCipherSuitesData(cipherSuites: seq[uint16]): seq[byte] =
  var data = newSeq[byte]()
  
  # 暗号スイートの長さ (バイト単位)
  let length = uint16(cipherSuites.len * 2)
  var lengthBytes = newSeq[byte](2)
  bigEndian16(addr lengthBytes[0], addr length)
  data.add(lengthBytes)
  
  # 各暗号スイートを追加
  for suite in cipherSuites:
    var suiteBytes = newSeq[byte](2)
    bigEndian16(addr suiteBytes[0], addr suite)
    data.add(suiteBytes)
  
  return data

# サポート鍵交換グループ拡張の作成
proc createSupportedGroupsExtension(groups: seq[uint16]): TlsExtension =
  var data = newSeq[byte]()
  
  # グループリストの長さ (バイト単位)
  let length = uint16(groups.len * 2)
  var lengthBytes = newSeq[byte](2)
  bigEndian16(addr lengthBytes[0], addr length)
  data.add(lengthBytes)
  
  # 各グループを追加
  for group in groups:
    var groupBytes = newSeq[byte](2)
    bigEndian16(addr groupBytes[0], addr group)
    data.add(groupBytes)
  
  return TlsExtension(
    extensionType: EXT_SUPPORTED_GROUPS,
    data: data
  )

# サポート署名アルゴリズム拡張の作成
proc createSignatureAlgorithmsExtension(algorithms: seq[uint16]): TlsExtension =
  var data = newSeq[byte]()
  
  # アルゴリズムリストの長さ (バイト単位)
  let length = uint16(algorithms.len * 2)
  var lengthBytes = newSeq[byte](2)
  bigEndian16(addr lengthBytes[0], addr length)
  data.add(lengthBytes)
  
  # 各アルゴリズムを追加
  for alg in algorithms:
    var algBytes = newSeq[byte](2)
    bigEndian16(addr algBytes[0], addr alg)
    data.add(algBytes)
  
  return TlsExtension(
    extensionType: EXT_SIGNATURE_ALGORITHMS,
    data: data
  )

# QUIC転送パラメータ拡張の作成
proc createQuicTransportParametersExtension(params: seq[byte]): TlsExtension =
  return TlsExtension(
    extensionType: EXT_QUIC_TRANSPORT_PARAMETERS,
    data: params
  )

# 鍵共有拡張の作成 (X25519を使用)
proc createKeyShareExtension(client: TlsClient): TlsExtension =
  var data = newSeq[byte]()
  
  # 鍵共有リストの長さ用の2バイト (後で更新)
  data.add(0)
  data.add(0)
  
  # 鍵交換方式 (X25519)
  var groupBytes = newSeq[byte](2)
  let group = NAMED_GROUP_X25519
  bigEndian16(addr groupBytes[0], addr group)
  data.add(groupBytes)
  
  # X25519の鍵ペアを生成
  # 実際の実装では暗号ライブラリを使用して鍵を生成する
  var privateKey = newSeq[byte](32)
  var publicKey = newSeq[byte](32)
  
  # ここでは例として単純なランダムデータで埋める
  for i in 0..<privateKey.len:
    privateKey[i] = byte(rand(0..255))
  
  # 実際のX25519計算は省略 (ここではダミーデータ)
  for i in 0..<publicKey.len:
    publicKey[i] = byte(rand(0..255))
  
  # 鍵を保存
  client.privateKey = privateKey
  client.publicKey = publicKey
  
  # 鍵データの長さ
  let keyLength = uint16(publicKey.len)
  var keyLengthBytes = newSeq[byte](2)
  bigEndian16(addr keyLengthBytes[0], addr keyLength)
  data.add(keyLengthBytes)
  
  # 公開鍵データ
  data.add(publicKey)
  
  # リスト長を更新
  let listLength = uint16(data.len - 2)
  bigEndian16(addr data[0], addr listLength)
  
  return TlsExtension(
    extensionType: EXT_KEY_SHARE,
    data: data
  )

# ClientHelloメッセージの作成
proc createClientHello(client: TlsClient): seq[byte] =
  var data = newSeq[byte]()
  
  # バージョン (TLS 1.2を指定、TLS 1.3は拡張で指定)
  data.add(3) # Major version
  data.add(3) # Minor version
  
  # クライアントランダム
  data.add(client.clientRandom)
  
  # セッションID長 (0 = セッションID無し)
  data.add(0)
  
  # 暗号スイートリスト
  data.add(createCipherSuitesData(client.config.cipherSuites))
  
  # 圧縮方式リスト
  data.add(1) # 圧縮方式の数
  data.add(0) # null圧縮
  
  # 拡張リスト
  var extensions = newSeq[TlsExtension]()
  
  # サーバー名拡張 (SNI)
  if client.config.serverName.len > 0:
    extensions.add(createServerNameExtension(client.config.serverName))
  
  # ALPNプロトコル拡張
  if client.config.alpnProtocols.len > 0:
    extensions.add(createAlpnExtension(client.config.alpnProtocols))
  
  # サポートバージョン拡張 (TLS 1.3)
  extensions.add(createSupportedVersionsExtension())
  
  # サポート鍵交換グループ拡張
  extensions.add(createSupportedGroupsExtension(client.config.supportedGroups))
  
  # サポート署名アルゴリズム拡張
  extensions.add(createSignatureAlgorithmsExtension(client.config.signatureAlgorithms))
  
  # 鍵共有拡張
  extensions.add(createKeyShareExtension(client))
  
  # QUIC転送パラメータ拡張
  if client.config.transportParams.len > 0:
    extensions.add(createQuicTransportParametersExtension(client.config.transportParams))
  
  # 拡張リストの長さ
  var extensionsData = newSeq[byte]()
  for ext in extensions:
    extensionsData.add(encodeExtension(ext))
  
  let extensionsLength = uint16(extensionsData.len)
  var extensionsLengthBytes = newSeq[byte](2)
  bigEndian16(addr extensionsLengthBytes[0], addr extensionsLength)
  data.add(extensionsLengthBytes)
  
  # 拡張データ
  data.add(extensionsData)
  
  # 最終的なClientHelloメッセージを作成
  var clientHello = newSeq[byte]()
  
  # ハンドシェイクタイプ
  clientHello.add(byte(htClientHello))
  
  # メッセージ長
  let messageLength = uint32(data.len)
  var messageLengthBytes = newSeq[byte](3) # 長さは3バイト
  messageLengthBytes[0] = byte((messageLength shr 16) and 0xFF)
  messageLengthBytes[1] = byte((messageLength shr 8) and 0xFF)
  messageLengthBytes[2] = byte(messageLength and 0xFF)
  clientHello.add(messageLengthBytes)
  
  # メッセージ本体
  clientHello.add(data)
  
  return clientHello

# TLSクライアントの初期化
proc initialize*(client: TlsClient) =
  client.clientHello = createClientHello(client)
  client.state = csClientHelloSent

# TLSハンドシェイクの開始
proc startHandshake*(client: TlsClient): seq[byte] =
  # ClientHelloメッセージを含むTLSレコードを作成
  var record = newSeq[byte]()
  
  # レコードヘッダー
  record.add(byte(rtHandshake)) # レコードタイプ
  record.add(3) # Major version
  record.add(1) # Minor version (TLS 1.0を装う)
  
  # レコード長
  let recordLength = uint16(client.clientHello.len)
  var recordLengthBytes = newSeq[byte](2)
  bigEndian16(addr recordLengthBytes[0], addr recordLength)
  record.add(recordLengthBytes)
  
  # ハンドシェイクメッセージ
  record.add(client.clientHello)
  
  return record

# TLSレコードの処理
proc processRecord*(client: TlsClient, data: seq[byte]): seq[byte] =
  # ここでは簡略化のため、TLSレコードの基本的な処理のみを示す
  # 実際の実装では、レコードの復号化、ハンドシェイクメッセージの処理、鍵の導出などを行う
  
  if data.len < 5:
    raise newException(TlsError, "Record too short")
  
  # レコードヘッダーの解析
  let recordType = TlsRecordType(data[0])
  let majorVersion = data[1]
  let minorVersion = data[2]
  var recordLength: uint16 = 0
  bigEndian16(addr recordLength, addr data[3])
  
  if data.len < 5 + recordLength:
    raise newException(TlsError, "Incomplete record")
  
  # レコード本文
  let fragment = data[5 ..< 5 + recordLength]
  
  case recordType
  of rtHandshake:
    # ハンドシェイクメッセージの処理
    if fragment.len < 4:
      raise newException(TlsError, "Handshake message too short")
    
    let handshakeType = TlsHandshakeType(fragment[0])
    var messageLength: uint32 = 0
    messageLength = (uint32(fragment[1]) shl 16) or (uint32(fragment[2]) shl 8) or uint32(fragment[3])
    
    if fragment.len < 4 + messageLength:
      raise newException(TlsError, "Incomplete handshake message")
    
    let messageData = fragment[4 ..< 4 + messageLength]
    
    # ハンドシェイクの状態に応じたメッセージ処理
    case handshakeType
    of htServerHello:
      # ServerHelloの処理
      client.serverHello = fragment[0 ..< 4 + messageLength]
      client.state = csServerHelloReceived
      # 実際の実装では、ここでServerHelloを解析し、暗号スイートや鍵交換パラメータを抽出する
    
    of htEncryptedExtensions:
      client.state = csEncryptedExtensionsReceived
      # 実際の実装では、ここで拡張の解析を行う
    
    of htCertificate:
      client.state = csCertificateReceived
      # 実際の実装では、ここで証明書の検証を行う
    
    of htCertificateVerify:
      client.state = csCertificateVerifyReceived
      # 実際の実装では、ここで証明書の署名検証を行う
    
    of htFinished:
      client.state = csFinishedReceived
      # 実際の実装では、ここでFinishedメッセージの検証と自身のFinishedメッセージの生成を行う
    
    of htNewSessionTicket:
      client.receivedNewSessionTicket = true
      # 実際の実装では、ここでセッションチケットを解析し保存する
    
    else:
      raise newException(TlsError, "Unexpected handshake message type")
  
  of rtAlert:
    # アラートの処理
    if fragment.len < 2:
      raise newException(TlsError, "Alert record too short")
    
    let alertLevel = TlsAlertLevel(fragment[0])
    let alertDescription = TlsAlertDescription(fragment[1])
    
    if alertLevel == alFatal:
      client.state = csClosed
      raise newException(TlsError, fmt"Fatal alert: {alertDescription}")
  
  of rtApplicationData:
    # アプリケーションデータの処理 (QUIC では使用しない)
    return fragment
  
  of rtChangeCipherSpec:
    # 暗号仕様変更の処理 (TLS 1.3では互換性のために使用される場合がある)
    discard
  
  else:
    raise newException(TlsError, "Unknown record type")
  
  # 応答メッセージの生成 (簡略化のため省略)
  return @[]

# TLSハンドシェイクが完了したかどうかの確認
proc isHandshakeComplete*(client: TlsClient): bool =
  return client.state == csEstablished or client.state == csFinishedReceived

# ネゴシエーションされたALPNプロトコルの取得
proc getNegotiatedAlpn*(client: TlsClient): string =
  return client.negotiatedAlpn

# ピアのQUICトランスポートパラメータの取得
proc getPeerTransportParams*(client: TlsClient): seq[byte] =
  return client.peerTransportParams

# エクスポートキーの取得（QUICで使用）
proc exportKeyingMaterial*(client: TlsClient, label: string, context: seq[byte], length: int): seq[byte] =
  # TLS 1.3 キー導出関数 (HKDF-Expand-Label)
  # 実際の実装では、HKDFによるキー導出を行う
  # 簡略化のためダミー実装
  result = newSeq[byte](length)
  for i in 0..<length:
    result[i] = byte(i mod 256)
  
  return result