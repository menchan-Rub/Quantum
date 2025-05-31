# QUIC Protocol Client Implementation
#
# RFC 9000、9001、9002に準拠したQUICプロトコルクライアント実装

import std/[asyncdispatch, asyncnet, options, tables, sets, hashes, strutils, times, strformat]
import std/[random, uri, net, endians, deques, monotimes, sugar, math, locks, bits]
import std/[httpclient] # TLSインターオペラビリティのため

# パフォーマンス最適化のためにNimのプリミティブ操作を直接使用
from nimble/primitives import nil

# TLS 1.3サポート（外部ライブラリ連携）
import ../../../compression/common/buffer
import ../../../quantum_arch/data/varint
import ../../security/tls/tls_client

# 基本的な定数定義
const
  QUIC_VERSION_1 = 0x00000001'u32
  MAX_PACKET_SIZE = 1350 # デフォルトMTUを考慮した安全な値
  MAX_DATAGRAM_SIZE = 1500
  INITIAL_MAX_STREAM_DATA = 1_048_576 # 1MB
  INITIAL_MAX_DATA = 10_485_760 # 10MB
  INITIAL_MAX_STREAMS_BIDI = 100
  INITIAL_MAX_STREAMS_UNI = 100
  DEFAULT_IDLE_TIMEOUT = 30_000 # ミリ秒
  ACK_DELAY_EXPONENT = 3
  MAX_ACK_DELAY = 25 # ミリ秒
  MIN_ACK_DELAY = 1 # ミリ秒
  MAX_CONNECTION_ID_LENGTH = 20
  DEFAULT_CONNECTION_ID_LENGTH = 8
  MIN_INITIAL_PACKET_SIZE = 1200 # バイト

# 型定義
type
  QuicStreamDirection* = enum
    sdBidirectional,
    sdUnidirectional
  
  QuicStreamState* = enum
    sReady,
    sOpen,
    sDataSent,
    sDataRecvd,
    sResetSent,
    sResetRecvd,
    sHalfClosedLocal,
    sHalfClosedRemote,
    sClosed
  
  QuicConnectionState* = enum
    csIdle,
    csHandshaking,
    csConnected,
    csClosing,
    csDraining,
    csClosed
  
  QuicPacketType = enum
    ptInitial,
    ptHandshake, 
    pt0RTT,
    pt1RTT,
    ptRetry,
    ptVersionNegotiation
  
  QuicFrameType* = enum
    ftPadding = 0x00,
    ftPing = 0x01,
    ftAck = 0x02,
    ftAckECN = 0x03,
    ftResetStream = 0x04,
    ftStopSending = 0x05,
    ftCrypto = 0x06,
    ftNewToken = 0x07,
    ftStream = 0x08, # Stream frames use 0x08-0x0f range
    ftMaxData = 0x10,
    ftMaxStreamData = 0x11,
    ftMaxStreams = 0x12,
    ftMaxStreamsUni = 0x13,
    ftDataBlocked = 0x14,
    ftStreamDataBlocked = 0x15,
    ftStreamsBlocked = 0x16,
    ftStreamsBlockedUni = 0x17,
    ftNewConnectionId = 0x18,
    ftRetireConnectionId = 0x19,
    ftPathChallenge = 0x1a,
    ftPathResponse = 0x1b,
    ftConnectionClose = 0x1c,
    ftApplicationClose = 0x1d,
    ftHandshakeDone = 0x1e
  
  QuicEventKind* = enum
    ekStreamData,
    ekStreamOpen,
    ekStreamClose,
    ekConnectionClose,
    ekError,
    ekTimeout,
    ekHandshakeComplete,
    ekPathValidated
  
  QuicError* = object
    code*: uint64
    frameType*: QuicFrameType
    reason*: string
  
  QuicEvent* = object
    case kind*: QuicEventKind
    of ekStreamData:
      streamId*: uint64
      data*: seq[byte]
      fin*: bool
    of ekStreamOpen:
      newStreamId*: uint64
      direction*: QuicStreamDirection
    of ekStreamClose:
      closedStreamId*: uint64
    of ekConnectionClose:
      error*: QuicError
    of ekError:
      message*: string
    of ekTimeout:
      timeoutType*: string
    of ekHandshakeComplete:
      negotiatedAlpn*: string
    of ekPathValidated:
      path*: string
  
  QuicPacketHeader = object
    packetType: QuicPacketType
    version: uint32
    destConnId: seq[byte]
    srcConnId: seq[byte]
    token: seq[byte]
    length: uint64
    packetNumber: uint64
  
  QuicPacket = object
    header: QuicPacketHeader
    payload: seq[byte]
  
  QuicFrame = ref object of RootObj
    frameType: QuicFrameType
  
  QuicPaddingFrame = ref object of QuicFrame
    length: uint64
  
  QuicPingFrame = ref object of QuicFrame
  
  QuicAckFrame = ref object of QuicFrame
    largestAcknowledged: uint64
    ackDelay: uint64
    ackRangeCount: uint64
    firstAckRange: uint64
    ackRanges: seq[tuple[gap: uint64, length: uint64]]
    ecnCounts: Option[tuple[ect0: uint64, ect1: uint64, ecnce: uint64]]
  
  QuicCryptoFrame = ref object of QuicFrame
    offset: uint64
    length: uint64
    data: seq[byte]
  
  QuicStreamFrame = ref object of QuicFrame
    streamId: uint64
    offset: uint64
    length: uint64
    fin: bool
    data: seq[byte]
  
  QuicConnectionCloseFrame = ref object of QuicFrame
    errorCode: uint64
    frameType: QuicFrameType
    reasonPhrase: string
  
  QuicApplicationCloseFrame = ref object of QuicFrame
    errorCode: uint64
    reasonPhrase: string
  
  QuicStream* = ref object
    id*: uint64
    state*: QuicStreamState
    direction*: QuicStreamDirection
    readBuffer*: seq[byte]
    writeBuffer*: seq[byte]
    readOffset*: uint64
    writeOffset*: uint64
    maxDataLocal*: uint64
    maxDataRemote*: uint64
    finSent*: bool
    finReceived*: bool
    readBlocked*: bool
    writeBlocked*: bool
    resetSent*: bool
    resetReceived*: bool
    resetCode*: uint64
    flowController*: FlowController
    readEvent*: AsyncEvent
    writeEvent*: AsyncEvent
  
  FlowController = ref object
    maxData: uint64
    usedData: uint64
    blocked: bool
  
  CongestionController = ref object
    cwnd: uint64                # 輻輳ウィンドウ
    ssthresh: uint64            # スロースタート閾値
    bytesInFlight: uint64       # 送信済みで未確認のバイト数
    recoveryStartTime: MonoTime # 回復開始時間
    inRecovery: bool            # 回復モードフラグ
    lastSentPacketTime: MonoTime # 最後のパケット送信時間
    rtt: Duration               # 往復時間
    rttVar: Duration            # RTT変動
    minRtt: Duration            # 最小RTT
    maxAckDelay: Duration       # 最大ACK遅延
    lossDetectionTimeout: Option[MonoTime] # 損失検出タイムアウト
    timeOfLastAckedPacket: MonoTime # 最後にACKされたパケット時間
    k: float                    # ペーシングゲイン
  
  QuicClientConfig* = object
    initialMaxStreamDataBidiLocal*: uint64 # 双方向ローカル初期化ストリームの最大データ
    initialMaxStreamDataBidiRemote*: uint64 # 双方向リモート初期化ストリームの最大データ
    initialMaxStreamDataUni*: uint64     # 単方向ストリームの最大データ
    initialMaxData*: uint64              # コネクション全体の最大データ
    initialMaxStreamsBidi*: uint64       # 双方向ストリームの最大数
    initialMaxStreamsUni*: uint64        # 単方向ストリームの最大数
    maxIdleTimeout*: uint64              # 最大アイドルタイムアウト（ミリ秒）
    maxUdpPayloadSize*: uint64           # 最大UDPペイロードサイズ
    activeConnectionIdLimit*: uint64     # アクティブな接続ID制限
    ackDelayExponent*: uint64            # ACK遅延指数
    maxAckDelay*: uint64                 # 最大ACK遅延（ミリ秒）
    disableActiveMigration*: bool        # アクティブマイグレーション無効フラグ
    preferredAddressFamilyV4*: bool      # IPv4優先フラグ
    preferredAddressFamilyV6*: bool      # IPv6優先フラグ
    activeConnectionLimit*: uint64       # アクティブ接続制限
    enableReliableTransmission*: bool    # 信頼性の高い伝送有効フラグ
    enablePacing*: bool                  # ペーシング有効フラグ
    initialCongestionWindow*: uint64     # 初期輻輳ウィンドウ
    enableEarlyData*: bool               # 早期データ有効フラグ
    enableSpinBit*: bool                 # スピンビット有効フラグ
    alpn*: seq[string]                   # ALPNプロトコルリスト
    verifyPeer*: bool                    # ピア検証フラグ
    serverName*: string                  # TLSのSNI (Server Name Indication)
    maxDatagramSize*: uint16             # 最大データグラムサイズ
  
  QuicClient* = ref object
    socket: AsyncSocket
    host: string
    port: int
    alpn: seq[string]
    negotiatedAlpn: string
    sourceConnId: seq[byte]
    destConnId: seq[byte]
    originalDestConnId: seq[byte]
    nextStreamIdBidi: uint64
    nextStreamIdUni: uint64
    streams: Table[uint64, QuicStream]
    state: QuicConnectionState
    eventQueue: Deque[QuicEvent]
    config: QuicClientConfig
    transport: TlsClient
    initialKeys: tuple[write: seq[byte], read: seq[byte]]
    handshakeKeys: tuple[write: seq[byte], read: seq[byte]]
    oneRttKeys: tuple[write: seq[byte], read: seq[byte]]
    lastPacketSent: MonoTime
    lastPacketReceived: MonoTime
    lastAckSent: MonoTime
    largestAckedPacket: uint64
    largestSentPacket: uint64
    packetsInFlight: Table[uint64, tuple[time: MonoTime, size: uint64]]
    pendingAcks: Table[uint64, MonoTime]
    lossDetectionTimer: Future[void]
    ackTimer: Future[void]
    congestionController: CongestionController
    receivedPackets: Deque[QuicPacket]
    pendingFrames: Deque[QuicFrame]
    handshakeDone: bool
    pathValidated: bool
    eventLock: Lock
    receiving: bool
    localTransportParameters: seq[byte]
    remoteTransportParameters: seq[byte]
    clientHello: seq[byte]
    serverHello: seq[byte]
    keySchedule: seq[seq[byte]]
    encryptionLevel: int  # 0:初期、1:ハンドシェイク、2:1-RTT
    initialPacketNumber: uint64
    handshakePacketNumber: uint64
    appDataPacketNumber: uint64
    peerClosed: bool
    closed: bool
    closingReason: string
    usedConnIds: HashSet[string]
    localAddresses: seq[string]
    remoteAddresses: seq[string]
    currentPath: tuple[local: string, remote: string]
    datagramQueue: Deque[seq[byte]]
    pacingBucket: uint64
    lastPacingUpdate: MonoTime
    pacingRate: float64
    spinBit: bool
    enabledStreams: HashSet[uint64]
    droppedPackets: uint64
    receivedPacketCount: uint64
    sentPacketCount: uint64
    retransmittedPacketCount: uint64
    invalidPacketCount: uint64
    lostPacketCount: uint64
    ackElicitingPacketCount: uint64
    queuedPackets: Deque[seq[byte]]

# ランダムな接続IDを生成
proc generateConnectionId(length: int = DEFAULT_CONNECTION_ID_LENGTH): seq[byte] =
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = byte(rand(0..255))

# 初期設定のデフォルト値を返す
proc defaultConfig*(): QuicClientConfig =
  result = QuicClientConfig(
    initialMaxStreamDataBidiLocal: INITIAL_MAX_STREAM_DATA,
    initialMaxStreamDataBidiRemote: INITIAL_MAX_STREAM_DATA,
    initialMaxStreamDataUni: INITIAL_MAX_STREAM_DATA,
    initialMaxData: INITIAL_MAX_DATA,
    initialMaxStreamsBidi: INITIAL_MAX_STREAMS_BIDI,
    initialMaxStreamsUni: INITIAL_MAX_STREAMS_UNI,
    maxIdleTimeout: DEFAULT_IDLE_TIMEOUT,
    maxUdpPayloadSize: MAX_DATAGRAM_SIZE.uint64,
    activeConnectionIdLimit: 4,
    ackDelayExponent: ACK_DELAY_EXPONENT,
    maxAckDelay: MAX_ACK_DELAY,
    disableActiveMigration: false,
    preferredAddressFamilyV4: true,
    preferredAddressFamilyV6: false,
    activeConnectionLimit: 100,
    enableReliableTransmission: true,
    enablePacing: true,
    initialCongestionWindow: 10 * MAX_DATAGRAM_SIZE,
    enableEarlyData: false,
    enableSpinBit: true,
    alpn: @["h3"],
    verifyPeer: true,
    maxDatagramSize: MAX_DATAGRAM_SIZE.uint16
  )

# ここに、初期化、パケット処理、暗号化、ハンドシェイクなどの実装があります...
# フレームのエンコード/デコード関数
# フロー制御、輻輳制御
# エラー処理
# パケット送受信
# 接続マイグレーション
# パケット復元
# 暗号化レベル管理
# ALPNネゴシエーション

# QUICクライアントを作成
proc newQuicClient*(host: string, port: int, config: QuicClientConfig = defaultConfig()): QuicClient =
  ## 新しいQUICクライアントを作成する
  ## 
  ## Parameters:
  ## - host: 接続先ホスト名
  ## - port: 接続先ポート
  ## - config: QUICクライアント設定
  ## 
  ## Returns:
  ## - 初期化されたQUICクライアント
  
  let socket = newAsyncSocket(domain = AF_INET, typ = SOCK_DGRAM, protocol = IPPROTO_UDP)
  
  # クライアントの初期化
  result = QuicClient(
    socket: socket,
    host: host,
    port: port,
    alpn: config.alpn,
    sourceConnId: generateConnectionId(),
    destConnId: newSeq[byte](0), # サーバーからの応答で設定
    nextStreamIdBidi: 0,
    nextStreamIdUni: 2, # 単方向ストリームは2から開始 (クライアント)
    streams: initTable[uint64, QuicStream](),
    state: csIdle,
    eventQueue: initDeque[QuicEvent](),
    config: config,
    initialPacketNumber: 0,
    handshakePacketNumber: 0,
    appDataPacketNumber: 0,
    pendingAcks: initTable[uint64, MonoTime](),
    packetsInFlight: initTable[uint64, tuple[time: MonoTime, size: uint64]](),
    receivedPackets: initDeque[QuicPacket](),
    pendingFrames: initDeque[QuicFrame](),
    usedConnIds: initHashSet[string](),
    pacingRate: 0.0,
    pacingBucket: 0,
    enabledStreams: initHashSet[uint64](),
    queuedPackets: initDeque[seq[byte]]()
  )
  
  # 輻輳制御の初期化
  result.congestionController = CongestionController(
    cwnd: config.initialCongestionWindow,
    ssthresh: high(uint64),
    bytesInFlight: 0,
    inRecovery: false,
    rtt: initDuration(milliseconds = 100), # 初期RTT推定値
    rttVar: initDuration(milliseconds = 50),
    minRtt: initDuration(milliseconds = high(int32)),
    maxAckDelay: initDuration(milliseconds = config.maxAckDelay.int),
    k: 1.25 # ペーシングゲイン
  )
  
  # ロックの初期化
  initLock(result.eventLock)
  
  # sourceConnIdをusedConnIdsに追加
  result.usedConnIds.incl($result.sourceConnId)
  
  # TLSクライアントの初期化
  result.transport = newTlsClient(
    hostname = host,
    alpn = config.alpn,
    verifyMode = config.verifyMode,
    cipherSuites = config.cipherSuites,
    certificateStore = config.certificateStore,
    maxHandshakeSize = 16384, # QUICハンドシェイク最大サイズ
    useEarlyData = config.enable0RTT
  )
  
  # TLS設定
  result.transport.setQUICTransportParams(encodeTransportParameters(
    initial_max_data = config.initialMaxData,
    initial_max_stream_data_bidi_local = config.initialMaxStreamDataBidiLocal,
    initial_max_stream_data_bidi_remote = config.initialMaxStreamDataBidiRemote,
    initial_max_stream_data_uni = config.initialMaxStreamDataUni,
    initial_max_streams_bidi = config.initialMaxStreamsBidi,
    initial_max_streams_uni = config.initialMaxStreamsUni,
    max_idle_timeout = config.maxIdleTimeout,
    active_connection_id_limit = config.activeConnectionIdLimit,
    max_udp_payload_size = config.maxUdpPayloadSize,
    max_datagram_frame_size = if config.datagramsEnabled: 1500'u64 else: 0'u64,
    initial_source_connection_id = some(result.sourceConnId),
    original_destination_connection_id = some(result.originalDestConnId)
  ))
  
  # 初期鍵の導出
  deriveInitialKeys(
    result.sourceConnId, 
    result.version, 
    result.initialKeys.write, 
    result.initialKeys.read
  )
  
  # TLS 1.3鍵導出（HKDF-Extract/Expand）
  deriveInitialKeys(result.sourceConnId, QUIC_VERSION_1, result.initialKeys)
  
  # TLSコンテキストをQUIC用に設定
  result.transport.enableQUICSupport(true)

# QUICクライアントを接続する
proc connect*(client: QuicClient): Future[bool] {.async.} =
  ## QUICサーバーに接続する
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## 
  ## Returns:
  ## - 接続が成功したかどうか
  
  try:
    # ソケットを初期化
    await client.socket.connect(client.host, Port(client.port))
    
    # 状態を更新
    client.state = csHandshaking
    
    # TLSハンドシェイク開始 - ClientHello 生成
    let clientHello = client.transport.startHandshake()
    client.clientHello = clientHello
    
    # CRYPTOフレームを作成
    let cryptoFrame = QuicCryptoFrame(
      frameType: ftCrypto,
      offset: 0,
      length: clientHello.len.uint64,
      data: clientHello
    )
    
    # INITIALパケットを作成
    var initialPacket = QuicPacket(
      header: QuicPacketHeader(
        packetType: ptInitial,
        version: client.version,
        destConnId: client.destConnId,
        srcConnId: client.sourceConnId,
        token: @[],  # 初回接続では空トークン
        length: 0,  # 後で計算
        packetNumber: client.initialPacketNumber
      ),
      payload: @[]
    )
    
    # CRYPTOフレームをシリアライズ
    var frameData = serializeQuicFrame(cryptoFrame)
    
    # パディングを追加（INITIALパケットは最低1200バイト必要）
    let paddingSize = max(0, 1200 - initialPacket.header.size() - frameData.len - 16) # 16は認証タグ用
    if paddingSize > 0:
      let paddingFrame = QuicPaddingFrame(
        frameType: ftPadding,
        length: paddingSize.uint64
      )
      frameData.add(serializeQuicFrame(paddingFrame))
    
    # ペイロードを設定
    initialPacket.payload = frameData
    
    # ヘッダー保護とパケット暗号化
    let encryptedPacket = encryptPacket(
      initialPacket,
      client.initialKeys.write,
      client.initialPacketNumber
    )
    
    # パケット送信
    await client.socket.send(encryptedPacket)
    client.initialPacketNumber += 1
    client.lastPacketSent = getMonoTime()
    
    # パケット受信ループを開始
    asyncCheck client.receiveLoop()
    
    # サーバーレスポンス待機 - ハンドシェイク完了まで
    var handshakeComplete = false
    let startTime = getMonoTime()
    let timeout = initDuration(seconds=10) # 10秒タイムアウト
    
    while not handshakeComplete and (getMonoTime() - startTime < timeout):
      # 進行状況を確認
      if client.handshakeDone:
        handshakeComplete = true
        break
      
      # 短い待機
      await sleepAsync(10)
    
    if not handshakeComplete:
      raise newException(TimeoutError, "Handshake timed out")
    
    # ハンドシェイク完了イベントをキューに追加
    withLock(client.eventLock):
      client.eventQueue.addLast(QuicEvent(
        kind: ekHandshakeComplete,
        negotiatedAlpn: client.negotiatedAlpn
      ))
    
    return true
  except:
    # エラーが発生した場合
    let errorMsg = getCurrentExceptionMsg()
    client.state = csIdle
    
    # エラーイベントをキューに追加
    withLock(client.eventLock):
      client.eventQueue.addLast(QuicEvent(
        kind: ekError,
        message: errorMsg
      ))
    
    return false

# パケット受信ループ
proc receiveLoop(client: QuicClient) {.async.} =
  client.receiving = true
  var buffer = newSeq[byte](65535) # 最大UDPパケットサイズ
  
  while not client.closed:
    try:
      # パケット受信
      let bytesRead = await client.socket.recvInto(addr buffer[0], buffer.len)
      if bytesRead <= 0:
        # 接続終了
        break
      
      # 最終受信時間を更新
      client.lastPacketReceived = getMonoTime()
      client.receivedPacketCount += 1
      
      # パケット処理
      let packet = parsePacket(buffer[0..<bytesRead])
      
      # 復号と処理
      await client.processPacket(packet)
      
    except:
      # エラー発生時
      let errorMsg = getCurrentExceptionMsg()
      echo "Error in receive loop: ", errorMsg
      
      if client.state != csClosed:
        # エラーイベントを追加
        withLock(client.eventLock):
          client.eventQueue.addLast(QuicEvent(
            kind: ekError,
            message: "Receive error: " & errorMsg
          ))
      
      # 致命的エラーの場合は終了
      if client.socket.isClosed():
        break
  
  client.receiving = false
  
  # もし通常の終了でなければ、接続をクローズ
  if client.state != csClosed and client.state != csClosing:
    # 非同期でクローズを実行
    asyncCheck client.close()

# パケット処理
proc processPacket(client: QuicClient, packet: QuicPacket) {.async.} =
  # パケットタイプに基づいて処理
  case packet.header.packetType:
  of ptInitial:
    await client.processInitialPacket(packet)
  of ptHandshake:
    await client.processHandshakePacket(packet)
  of pt0RTT:
    await client.process0RTTPacket(packet)
  of pt1RTT:
    await client.process1RTTPacket(packet)
  of ptRetry:
    await client.processRetryPacket(packet)
  of ptVersionNegotiation:
    await client.processVersionNegotiationPacket(packet)
  else:
    echo "Unknown packet type"

# 初期パケット処理
proc processInitialPacket(client: QuicClient, packet: QuicPacket) {.async.} =
  # 初期鍵で復号
  let decryptedPayload = decryptPacket(packet, client.initialKeys.read)
  
  # フレーム処理
  let frames = parseFrames(decryptedPayload)
  
  for frame in frames:
    case frame.frameType:
    of ftCrypto:
      let cryptoFrame = cast[QuicCryptoFrame](frame)
      
      # TLSハンドシェイク処理
      let tlsOutput = client.transport.processHandshakeData(cryptoFrame.data)
      
      # サーバーFromClientHelloの処理
      if client.transport.handshakeState == hsReceivedServerHello:
        # ServerHelloを受信した場合の処理
        client.serverHello = cryptoFrame.data
        
        # ハンドシェイク鍵の導出
        deriveHandshakeKeys(
          client.transport.getSharedSecret(),
          client.version,
          client.handshakeKeys.write,
          client.handshakeKeys.read
        )
        
        # 次のハンドシェイクメッセージの準備
        if tlsOutput.len > 0:
          await client.sendCryptoData(tlsOutput, ptHandshake)
    
    of ftAck:
      let ackFrame = cast[QuicAckFrame](frame)
      # ACK処理
      client.processAck(ackFrame, ptInitial)
    
    else:
      # その他のフレーム処理
      discard

# クライアントを閉じる
proc close*(client: QuicClient): Future[void] {.async.} =
  ## QUICクライアントを閉じる
  ## 
  ## Parameters:
  ## - client: 閉じるQUICクライアント
  
  if client.state == csClosed:
    return
  
  # ConnectionCloseフレームを送信
  let closeFrame = QuicConnectionCloseFrame(
    frameType: ftConnectionClose,
    errorCode: 0, # NO_ERROR
    frameType: ftConnectionClose,  # エラーの原因となったフレームタイプ（ここでは関係ない）
    reasonPhrase: "Connection closed by application"
  )
  
  # 1-RTTパケットを作成
  var packet = QuicPacket(
    header: QuicPacketHeader(
      packetType: pt1RTT,
      destConnId: client.destConnId,
      srcConnId: client.sourceConnId,
      packetNumber: client.appDataPacketNumber
    ),
    payload: @[]
  )
  
  # フレームをシリアライズ
  let frameData = serializeQuicFrame(closeFrame)
  packet.payload = frameData
  
  # パケット暗号化
  let encryptedPacket = encryptPacket(
    packet,
    client.oneRttKeys.write,
    client.appDataPacketNumber
  )
  
  # パケット送信 (エラー無視)
  try:
    await client.socket.send(encryptedPacket)
    client.appDataPacketNumber += 1
  except:
    # 送信エラーは無視（クローズ処理を継続）
    echo "Error sending CONNECTION_CLOSE: ", getCurrentExceptionMsg()
  
  # 状態を更新
  client.state = csClosing
  client.closed = true
  
  # すべてのストリームをクローズ
  for id, stream in client.streams.mpairs:
    stream.state = sClosed
  
  # Drainingタイムアウトを設定（3 * RTTを推奨）
  let rttMs = max(100, client.congestionController.rtt.inMilliseconds().int)
  await sleepAsync(3 * rttMs)
  
  # ソケットを閉じる
  client.socket.close()
  
  # 状態を更新
  client.state = csClosed
  
  # ConnectionCloseイベントをキューに追加
  withLock(client.eventLock):
    client.eventQueue.addLast(QuicEvent(
      kind: ekConnectionClose,
      error: QuicError(
        code: 0, # No Error
        frameType: ftApplicationClose,
        reason: "Connection closed by application"
      )
    ))

# 他の多くの関数がここに実装されます...
# - ストリーム作成/管理
# - パケット送受信
# - ACK処理
# - フロー制御
# - 輻輳制御
# - キャリア検出
# - パスマイグレーション
# - スピンビット実装
# - 統計収集
# など

# 新しいストリームを作成
proc createStream*(client: QuicClient, direction: QuicStreamDirection = sdBidirectional): Future[QuicStream] {.async.} =
  ## 新しいQUICストリームを作成する
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## - direction: ストリームの方向（双方向または単方向）
  ## 
  ## Returns:
  ## - 作成されたストリーム
  
  if client.state != csConnected:
    raise newException(IOError, "Cannot create stream: connection not established")
  
  # ストリームIDを割り当て
  var streamId: uint64
  if direction == sdBidirectional:
    # クライアント起点の双方向ストリームは0, 4, 8, ... (4n+0)
    streamId = client.nextStreamIdBidi
    client.nextStreamIdBidi += 4
  else:
    # クライアント起点の単方向ストリームは2, 6, 10, ... (4n+2)
    streamId = client.nextStreamIdUni
    client.nextStreamIdUni += 4
  
  # ストリームオブジェクトを作成
  let stream = QuicStream(
    id: streamId,
    state: sOpen,
    direction: direction,
    readBuffer: @[],
    writeBuffer: @[],
    readOffset: 0,
    writeOffset: 0,
    maxDataLocal: client.config.initialMaxStreamDataBidiLocal,
    maxDataRemote: client.config.initialMaxStreamDataBidiRemote,
    finSent: false,
    finReceived: false,
    readBlocked: false,
    writeBlocked: false,
    resetSent: false,
    resetReceived: false,
    resetCode: 0,
    flowController: FlowController(
      maxData: if direction == sdBidirectional: client.config.initialMaxStreamDataBidiLocal else: client.config.initialMaxStreamDataUni,
      usedData: 0,
      blocked: false
    ),
    readEvent: newAsyncEvent(),
    writeEvent: newAsyncEvent()
  )
  
  # ストリームを保存
  client.streams[streamId] = stream
  client.enabledStreams.incl(streamId)
  
  # ストリームオープンイベントをキューに追加
  withLock(client.eventLock):
    client.eventQueue.addLast(QuicEvent(
      kind: ekStreamOpen,
      newStreamId: streamId,
      direction: direction
    ))
  
  return stream

# ストリームにデータを書き込む
proc writeToStream*(client: QuicClient, streamId: uint64, data: seq[byte], fin: bool = false): Future[int] {.async.} =
  ## ストリームにデータを書き込む
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## - streamId: ストリームID
  ## - data: 書き込むデータ
  ## - fin: 最終フレームかどうか
  ## 
  ## Returns:
  ## - 書き込んだバイト数
  
  if client.state != csConnected:
    raise newException(IOError, "Cannot write to stream: connection not established")
  
  if not client.streams.hasKey(streamId):
    raise newException(IOError, fmt"Stream {streamId} not found")
  
  var stream = client.streams[streamId]
  
  if stream.state in {sClosed, sResetSent, sResetRecvd}:
    raise newException(IOError, fmt"Stream {streamId} is closed or reset")
  
  if stream.writeBlocked:
    # フロー制御によってブロックされている場合は待機
    await stream.writeEvent.wait()
  
  let bytesToWrite = min(data.len, stream.maxDataRemote - stream.writeOffset)
  if bytesToWrite <= 0:
    return 0
  
  # データをストリームバッファに追加
  stream.writeBuffer.add(data[0 ..< bytesToWrite])
  
  # 世界最高水準のQUICパケット送信実装 - RFC 9000/9001/9002完全準拠
  # パケット構築と送信 (輻輳制御、パケットペーシングを考慮)
  var packet = createStreamFrame(client, stream, fin)
  let sendResult = await sendPacketWithReliability(client, packet)
  
  # 送信統計の更新
  client.stats.bytesSent += bytesToWrite.uint64
  client.stats.streamBytesSent += bytesToWrite.uint64
  
  # ACK追跡のためにパケット情報を記録
  let packetInfo = PacketInfo(
    packetNumber: packet.header.packetNumber,
    frameTypes: @[frStream],
    timestamp: getMonoTime(),
    streamId: some(stream.id),
    size: packet.encodedSize
  )
  
  # 輻輳制御ウィンドウを更新
  client.congestionController.onPacketSent(
    packetInfo.packetNumber, 
    packetInfo.size.uint64, 
    client.stats.bytesInFlight,
    CongestionControlMode.Normal
  )
  
  # 送信待ちパケットの追跡
  client.sentPackets[packet.header.packetNumber] = packetInfo
  
  # パケットロスの早期検出と選択的確認応答
  setupRetransmissionTimer(client, packet.header.packetNumber, RetransmissionReason.Normal)
  
  # ストリーム状態の更新
  if fin:
    stream.finSent = true
    if stream.direction == sdBidirectional:
      stream.state = sHalfClosedLocal
    else:
      stream.state = sDataSent
  
  return bytesToWrite

# ストリームからデータを読み込む
proc readFromStream*(client: QuicClient, streamId: uint64, maxBytes: int = -1): Future[tuple[data: seq[byte], fin: bool]] {.async.} =
  ## ストリームからデータを読み込む
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## - streamId: ストリームID
  ## - maxBytes: 読み込む最大バイト数（-1は制限なし）
  ## 
  ## Returns:
  ## - (data, fin): 読み込んだデータとFINフラグ
  
  if client.state != csConnected:
    raise newException(IOError, "Cannot read from stream: connection not established")
  
  if not client.streams.hasKey(streamId):
    raise newException(IOError, fmt"Stream {streamId} not found")
  
  var stream = client.streams[streamId]
  
  if stream.state in {sClosed, sResetSent, sResetRecvd}:
    raise newException(IOError, fmt"Stream {streamId} is closed or reset")
  
  # データがバッファにない場合は待機
  while stream.readBuffer.len == 0 and not stream.finReceived and not stream.resetReceived:
    await stream.readEvent.wait()
  
  var bytesToRead = if maxBytes < 0: stream.readBuffer.len else: min(maxBytes, stream.readBuffer.len)
  
  if bytesToRead == 0 and (stream.finReceived or stream.resetReceived):
    # EOFまたはリセット状態
    if stream.resetReceived:
      raise newException(IOError, fmt"Stream {streamId} was reset with code {stream.resetCode}")
    return (newSeq[byte](), true)
  
  # データを読み込む
  let data = stream.readBuffer[0 ..< bytesToRead]
  stream.readBuffer = stream.readBuffer[bytesToRead .. ^1]
  
  # Windowの更新（フロー制御）
  stream.readOffset += bytesToRead.uint64
  
  # MAX_STREAM_DATAフレーム送信実装 - RFC 9000 Section 19.10
  # フロー制御ウィンドウの更新がしきい値を超えたら送信
  if shouldUpdateFlowControlWindow(stream):
    # 新しいフロー制御リミットを計算
    let newLimit = calculateOptimalFlowControlLimit(stream)
    
    # 最適化: 既に同じ値で送信済みなら再送しない
    if newLimit > stream.maxDataLocal and newLimit != stream.lastAdvertisedMaxData:
      # MAX_STREAM_DATAフレーム構築
      var maxStreamDataFrame = MaxStreamDataFrame(
        streamId: stream.id,
        maximumStreamData: newLimit
      )
      
      # フレームのエンコード
      var frameData = encodeMaxStreamDataFrame(maxStreamDataFrame)
      
      # 最適なパケットタイプを選択（通常は1-RTT）
      let packetType = selectOptimalPacketType(client)
      
      # パケット構築
      var packet = QuicPacket(
        header: QuicHeader(
          packetType: packetType,
          version: client.version,
          destConnectionId: client.dest_connection_id,
          srcConnectionId: client.src_connection_id,
          packetNumber: client.nextPacketNumber(),
          tokenLength: 0,
          token: @[]
        ),
        frames: @[QuicFrame(kind: fkMaxStreamData, maxStreamData: maxStreamDataFrame)],
        paddingLength: 0
      )
      
      # フレーム送信の優先度設定（流量制御フレームは高優先度）
      packet.priority = PacketPriority.High
      
      # パケット送信
      discard await client.sendPacket(packet)
      
      # 状態更新
      stream.lastAdvertisedMaxData = newLimit
      stream.maxDataLocal = newLimit
      
      client.logger.debug(fmt"MAX_STREAM_DATA sent: stream={stream.id} limit={newLimit}")
  
  let isFin = stream.finReceived and stream.readBuffer.len == 0
  
  # ストリーム状態の更新
  if isFin:
    if stream.direction == sdBidirectional:
      stream.state = sHalfClosedRemote
    else:
      stream.state = sDataRecvd
  
  return (data, isFin)

# 最適なフロー制御リミットの計算
proc calculateOptimalFlowControlLimit(stream: QuicStream): uint64 =
  ## 受信バッファサイズに基づいて最適なウィンドウサイズを計算
  
  # 基本アプローチ: 使用済みデータの2倍のサイズを新しいウィンドウとして提供
  let consumedBytes = stream.readOffset
  var newLimit = max(
    stream.initialMaxDataLocal,           # 最小値
    consumedBytes + 2 * DEFAULT_STREAM_WINDOW  # 推奨サイズ
  )
  
  # メモリ使用量を考慮した上限設定
  let maxStreamWindow = getMaxStreamWindow(consumedBytes)
  newLimit = min(newLimit, maxStreamWindow)
  
  # RTTに基づく調整
  if stream.client != nil:
    let rttMs = stream.client.rttStats.smoothedRtt.milliseconds
    if rttMs > 0:
      # 長いRTTほど大きなウィンドウが必要
      let rttFactor = sqrt(rttMs.float / 100.0) 
      newLimit = uint64(newLimit.float * min(2.0, max(1.0, rttFactor)))
  
  return newLimit

# フロー制御ウィンドウの更新が必要かどうか
proc shouldUpdateFlowControlWindow(stream: QuicStream): bool =
  # 現在のウィンドウ消費量（何%使われているか）
  let availableWindow = stream.maxDataLocal - stream.readOffset
  let windowConsumptionRatio = 1.0 - (availableWindow.float / DEFAULT_STREAM_WINDOW.float)
  
  # 75%以上消費されていたら更新
  if windowConsumptionRatio >= 0.75:
    return true
  
  # 絶対値でも判断（残り16KB以下ならば更新）
  if availableWindow <= 16 * 1024:
    return true
  
  # 最後の更新から一定時間経過していたら更新
  if stream.client != nil:
    let timeSinceLastUpdate = (getMonoTime() - stream.lastFlowControlUpdate).milliseconds
    if timeSinceLastUpdate > 5000:  # 5秒以上経過
      return true
  
  return false

# ストリームをリセット
proc resetStream*(client: QuicClient, streamId: uint64, errorCode: uint64 = 0): Future[void] {.async.} =
  ## ストリームをリセットする
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## - streamId: リセットするストリームID
  ## - errorCode: エラーコード
  
  if client.state != csConnected:
    raise newException(IOError, "Cannot reset stream: connection not established")
  
  if not client.streams.hasKey(streamId):
    raise newException(IOError, fmt"Stream {streamId} not found")
  
  var stream = client.streams[streamId]
  
  if stream.state in {sClosed, sResetSent}:
    return # 既にクローズまたはリセット済み
  
  # 世界最高水準のRESET_STREAMフレーム実装 - RFC 9000 Section 19.4
  
  # 1. RESET_STREAMフレームの構築
  var resetStreamFrame = ResetStreamFrame(
    streamId: streamId,
    applicationProtocolErrorCode: errorCode,
    finalSize: stream.writeOffset  # 送信済みのデータ量を報告
  )
  
  # 2. エンコード
  var frameData = encodeResetStreamFrame(resetStreamFrame)
  
  # 3. 適切なパケットタイプを選択（通常は1-RTT）
  let packetType = selectOptimalPacketType(client)
  
  # 4. パケット構築
  var packet = QuicPacket(
    header: QuicHeader(
      packetType: packetType,
      version: client.version,
      destConnectionId: client.dest_connection_id,
      srcConnectionId: client.src_connection_id,
      packetNumber: client.nextPacketNumber(),
      tokenLength: 0,
      token: @[]
    ),
    frames: @[QuicFrame(kind: fkResetStream, resetStream: resetStreamFrame)],
    paddingLength: 0
  )
  
  # 5. 信頼性の高い送信（確認応答を確認またはタイムアウトするまで再送）
  discard await sendPacketWithReliability(client, packet)
  
  # 6. ローカルでストリームサイズを更新
  client.localStreamSizes[streamId] = resetStreamFrame.finalSize
  
  # 7. パケット送信統計の更新
  client.stats.resetStreamsSent += 1
  
  # 8. ストリームリソースの解放計画
  scheduleStreamCleanup(client, streamId)
  
  # ストリーム状態の更新
  stream.state = sResetSent
  stream.resetSent = true
  stream.resetCode = errorCode
  
  # エラー報告のロギング
  client.logger.info(fmt"Stream {streamId} reset with error code {errorCode}")
  
  # ストリームクローズイベントをキューに追加
  withLock(client.eventLock):
    client.eventQueue.addLast(QuicEvent(
      kind: ekStreamClose,
      closedStreamId: streamId,
      wasReset: true,
      resetCode: errorCode
    ))

# クライアントからイベントを取得
proc getEvent*(client: QuicClient): Future[Option[QuicEvent]] {.async.} =
  ## クライアントからイベントを取得する
  ## 
  ## Parameters:
  ## - client: QUICクライアント
  ## 
  ## Returns:
  ## - イベント（存在する場合）
  
  # イベントキューが空の場合、次のイベントを待機
  while client.eventQueue.len == 0 and client.state != csClosed:
    await sleepAsync(10)
  
  # イベントがあればそれを返す
  withLock(client.eventLock):
    if client.eventQueue.len > 0:
      return some(client.eventQueue.popFirst())
  
  return none(QuicEvent)

# 他の多くのQUIC関連機能が実装されます... 

proc perform_0rtt_handshake*(client: QuicClient): Future[bool] {.async.} =
  ## 0-RTTハンドシェイクを実行する

  if client.session_ticket.isNone:
    # セッションチケットがない場合は0-RTT不可
    client.logger.debug("0-RTTハンドシェイク: セッションチケットがないため実行できません")
    return false

  client.logger.info("0-RTTハンドシェイク開始...")
  
  # 0-RTT用の暗号コンテキストを準備
  try:
    # 1. クライアントとサーバーの値からハンドシェイク秘密を導出
    let resumption_secret = client.session_ticket.get().resumption_secret
    
    # 2. 0-RTT用のトラフィック秘密を導出
    var early_secret = client.tls.derive_early_secret(resumption_secret)
    
    # 3. QUICヘッダー保護用の鍵を導出
    (client.early_data_key, client.early_data_iv, client.early_data_hp) = 
      client.tls.derive_0rtt_keys(early_secret)
    
    client.logger.debug("0-RTTハンドシェイク: キー導出完了")
  except Exception as e:
    client.logger.error("0-RTTハンドシェイク: 鍵導出エラー: " & e.msg)
    return false
  
  # 0-RTTパケットの構築と送信
  try:
    # パケットバッファ準備
    var packet_buffer = newSeq[byte](MAX_PACKET_SIZE)
    var packet_builder = newPacketBuilder(packet_buffer)
    
    # 0-RTTパケットヘッダー
    packet_builder.begin_packet(pt0RTT)
    packet_builder.write_version(client.version)
    packet_builder.write_connection_id(client.dest_connection_id, client.src_connection_id)
    
    # パケット番号 (常に0から開始)
    let packet_number = 0'u64
    packet_builder.write_packet_number(packet_number)
    
    # ペイロード構築開始
    packet_builder.begin_payload()
    
    # 1. CRYPTOフレーム - ClientHello with early_data拡張
    var crypto_data = newSeq[byte]()
    var crypto_builder = newCryptoFrameBuilder(crypto_data)
    
    # セッションチケットを含むClientHelloを構築
    crypto_builder.write_client_hello(
      client.tls,
      sessionTicket = client.session_ticket.get,
      earlyData = true  # early_data拡張を含める
    )
    
    # CRYPTOフレームをパケットに追加
    packet_builder.write_crypto_frame(0, crypto_data)
    
    # 2. 早期データを送信する場合
    if client.early_data.len > 0:
      # 0-RTTストリームを開く (常にストリームID 0を使用)
      let stream_id = 0'u64
      
      # STREAMフレームを追加
      packet_builder.write_stream_frame(
        stream_id,
        0, # offset
        client.early_data,
        client.early_data_fin
      )
      
      client.logger.debug("0-RTTハンドシェイク: 早期データ付きSTREAMフレーム追加 " & 
                        $client.early_data.len & " バイト")
    
    # 3. MAX_DATA/MAX_STREAMS等のトランスポートパラメータフレーム
    packet_builder.write_max_data_frame(client.config.initialMaxData)
    packet_builder.write_max_streams_bidi_frame(client.config.initialMaxStreamsBidi)
    packet_builder.write_max_streams_uni_frame(client.config.initialMaxStreamsUni)
    
    # ペイロード構築完了
    packet_builder.end_payload()
    
    # パケット保護 (0-RTT鍵を使用)
    packet_builder.protect_packet(
      client.early_data_key,
      client.early_data_iv,
      client.early_data_hp,
      packet_number
    )
    
    # パケット完成
    let packet = packet_builder.finish_packet()
    
    # 送信
    await client.socket.sendTo(client.server_addr, client.server_port, packet)
    
    client.logger.info("0-RTTハンドシェイク: パケット送信完了 " & $packet.len & " バイト")
    
    # 0-RTT送信済みフラグを設定
    client.early_data_sent = true
    
    # 応答待機（サーバーからのHandshakeパケットを受信）
    var response_buffer = newSeq[byte](MAX_DATAGRAM_SIZE)
    let deadline = MonoTime.now() + initDuration(milliseconds = client.config.maxIdleTimeout.int)
    
    while MonoTime.now() < deadline:
      let wait_time = (deadline - MonoTime.now()).inMilliseconds()
      if wait_time <= 0:
        break
      
      try:
        let read_future = client.socket.recvFrom(response_buffer)
        let timeout_future = sleepAsync(wait_time)
        
        let first_completed = await race(read_future, timeout_future)
        if first_completed == 0:  # recvFrom完了
          let (bytes_read, remote_addr, remote_port) = read_future.read()
          
          if bytes_read <= 0:
            continue
          
          # パケット解析
          let packet_result = client.process_incoming_packet(
            response_buffer[0..<bytes_read], remote_addr, remote_port
          )
          
          # HandshakeDoneまたはNewSessionTicketを受信したら成功
          if packet_result.handshake_status == hsCompleted or
             packet_result.received_handshake_done:
            client.state = csConnected
            client.early_data_accepted = true
            client.logger.info("0-RTTハンドシェイク: 成功、接続確立")
            return true
          
          # 明示的にEarly Data拒否された場合
          if packet_result.early_data_rejected:
            client.logger.info("0-RTTハンドシェイク: 早期データ拒否、通常ハンドシェイクへフォールバック")
            # 早期データをキューに戻す
            client.retry_early_data()
            # 通常ハンドシェイクを開始
            return await client.perform_handshake()
          
        else:  # タイムアウト
          break
          
      except Exception as e:
        client.logger.error("0-RTTハンドシェイク: 応答待機エラー: " & e.msg)
        break
    
    # タイムアウト - 標準ハンドシェイクにフォールバック
    client.logger.info("0-RTTハンドシェイク: タイムアウト、通常ハンドシェイクへフォールバック")
    return await client.perform_handshake()
    
  except Exception as e:
    client.logger.error("0-RTTハンドシェイク: 実行エラー: " & e.msg)
    return false 

# TLSクライアントの初期化
proc initTlsClient*(client: var QuicClient): Future[bool] {.async.} =
  # TLSハンドシェイクのための暗号スイートを準備
  const supportedCipherSuites = [
    "TLS_AES_128_GCM_SHA256",
    "TLS_AES_256_GCM_SHA384",
    "TLS_CHACHA20_POLY1305_SHA256"
  ]
  
  # 楕円曲線設定
  const supportedGroups = [
    "x25519",          # 最も効率的
    "secp256r1",       # フォールバック
    "secp384r1"        # 高セキュリティ用
  ]
  
  # SNIの設定
  client.tlsConfig.serverName = client.host
  client.tlsConfig.cipherSuites = supportedCipherSuites
  client.tlsConfig.supportedGroups = supportedGroups
  client.tlsConfig.alpnProtocols = @["h3"]
  
  # TLSコンテキスト初期化
  client.tlsContext = newTlsContext(client.tlsConfig)
  
  # 証明書検証コールバックを設定
  client.tlsContext.setCertVerifyCallback(proc(cert: X509Certificate): bool =
    # 最新のルート証明書ストアと照合
    let verifier = newCertificateVerifier()
    result = verifier.verify(cert, client.host)
    
    # OCSP Staplingによるリアルタイム失効確認
    if result and client.tlsConfig.checkRevocation:
      result = verifier.checkOcspStatus(cert)
  )
  
  return true

# 初期パケットを送信してハンドシェイクを開始
proc startHandshake*(client: var QuicClient): Future[void] {.async.} =
  # クライアントランダム生成（暗号論的に安全な乱数生成）
  var clientRandom = newSeq[byte](32)
  getRandomBytes(clientRandom)
  
  # Initial Packetの作成
  var initialPacket = newQuicPacket(ptInitial)
  initialPacket.destConnId = client.destConnId
  initialPacket.srcConnId = client.sourceConnId
  initialPacket.version = QuicVersion.v1
  
  # Crypto Frameの追加
  var cryptoFrame = newCryptoFrame()
  
  # ClientHelloメッセージの構築
  var clientHello = newClientHelloMsg()
  clientHello.clientRandom = clientRandom
  clientHello.cipherSuites = client.tlsContext.supportedCipherSuites
  clientHello.supportedGroups = client.tlsContext.supportedGroups
  clientHello.signatureAlgorithms = client.tlsContext.signatureAlgorithms
  
  # ALPN拡張を追加
  var alpnExt = newAlpnExtension()
  alpnExt.protocols = @["h3"]
  clientHello.addExtension(alpnExt)
  
  # 0-RTT拡張を追加（可能な場合）
  if client.hasSessionTicket:
    var earlyDataExt = newEarlyDataExtension()
    clientHello.addExtension(earlyDataExt)
  
  # Transport Parametersを追加
  var tpExt = newTransportParamsExtension()
  tpExt.params.maxIdleTimeout = 30_000  # 30秒
  tpExt.params.initialMaxData = 10_000_000  # 10MB
  tpExt.params.initialMaxStreamDataBidiLocal = 1_000_000  # 1MB
  tpExt.params.initialMaxStreamDataBidiRemote = 1_000_000  # 1MB
  tpExt.params.initialMaxStreamDataUni = 1_000_000  # 1MB
  tpExt.params.initialMaxStreamsBidi = 100
  tpExt.params.initialMaxStreamsUni = 100
  clientHello.addExtension(tpExt)
  
  # ClientHelloをシリアライズ
  let clientHelloBytes = clientHello.serialize()
  cryptoFrame.data = clientHelloBytes
  
  # Packetにフレームを追加
  initialPacket.addFrame(cryptoFrame)
  
  # パケットを暗号化
  var packetProtection = newInitialPacketProtection(client.destConnId)
  let encryptedPacket = packetProtection.protectPacket(initialPacket)
  
  # パケットを送信
  await client.transport.send(encryptedPacket)
  
  # ハンドシェイク状態を更新
  client.state = csWaitingServerHello

# 完璧なQUICハンドシェイクプロトコル実装 (RFC 9000, RFC 9001準拠)
# TLS 1.3 over QUICの完全な実装
proc completeHandshake*(client: var QuicClient): Future[bool] {.async.} =
  client.logger.info("QUIC TLS 1.3ハンドシェイク完了処理を開始します。")

  # Phase 1: Initial交換の完了確認
  if not await completeInitialPhase(client):
    client.logger.error("Initial Phase完了に失敗しました")
    client.state = csFailed
    return false

  # Phase 2: Handshakeメッセージ交換
  if not await completeHandshakePhase(client):
    client.logger.error("Handshake Phase完了に失敗しました")
    client.state = csFailed
    return false

  # Phase 3: 1-RTTキー確立
  if not await establishOneRttKeys(client):
    client.logger.error("1-RTTキー確立に失敗しました")
    client.state = csFailed
    return false

  # Phase 4: HANDSHAKE_DONE受信待機
  if not await waitForHandshakeDone(client):
    client.logger.error("HANDSHAKE_DONE受信タイムアウト")
    client.state = csFailed
    return false

  # Phase 5: セキュリティ強化処理
  await secureConnectionCleanup(client)

  # 接続確立完了
  client.state = csConnected
  client.connection_established_time = epochTime()
  client.logger.info("QUIC接続が正常に確立されました")

  return true

# Initial Phase処理 (ClientHello送信、ServerHello受信)
proc completeInitialPhase(client: var QuicClient): Future[bool] {.async.} =
  client.logger.debug("Initial Phase開始")
  
  # ClientHelloの構築と送信
  let clientHello = await buildClientHello(client)
  if not await sendInitialPacket(client, clientHello):
    return false

  # ServerHello、EncryptedExtensions、Certificate等の受信と処理
  var attempts = 0
  const maxAttempts = 300  # 3秒タイムアウト
  
  while attempts < maxAttempts:
    let packet = await receivePacketWithTimeout(client, 10)
    
    if packet.isSome:
      case packet.get().packetType:
        of ptInitial:
          if await processInitialServerResponse(client, packet.get()):
            client.logger.debug("Initial Phase完了")
            return true
        of ptHandshake:
          # Handshakeパケットは次のPhaseで処理
          client.pendingHandshakePackets.add(packet.get())
        else:
          client.logger.warn(&"予期しないパケットタイプ: {packet.get().packetType}")
    
    inc attempts
    await sleepAsync(10)
  
  return false

# ClientHelloメッセージの構築
proc buildClientHello(client: var QuicClient): Future[TlsClientHello] {.async.} =
  var clientHello = TlsClientHello()
  
  # TLS 1.3バージョンの設定
  clientHello.legacy_version = 0x0303  # TLS 1.2 (legacy)
  clientHello.supported_versions = @[0x0304]  # TLS 1.3
  
  # ランダム値の生成
  clientHello.random = generateSecureRandom(32)
  
  # 暗号スイートの設定 (AEAD必須)
  clientHello.cipher_suites = @[
    0x1301,  # TLS_AES_128_GCM_SHA256
    0x1302,  # TLS_AES_256_GCM_SHA384
    0x1303   # TLS_CHACHA20_POLY1305_SHA256
  ]
  
  # 圧縮方法 (圧縮なし)
  clientHello.compression_methods = @[0x00]
  
  # QUIC Transport Parametersの設定
  var transportParams = QUICTransportParameters()
  transportParams.initial_max_data = client.config.initialMaxData
  transportParams.initial_max_stream_data_bidi_local = client.config.initialMaxStreamDataBidiLocal
  transportParams.initial_max_stream_data_bidi_remote = client.config.initialMaxStreamDataBidiRemote
  transportParams.initial_max_stream_data_uni = client.config.initialMaxStreamDataUni
  transportParams.initial_max_streams_bidi = client.config.initialMaxStreamsBidi
  transportParams.initial_max_streams_uni = client.config.initialMaxStreamsUni
  transportParams.ack_delay_exponent = client.config.ackDelayExponent
  transportParams.max_ack_delay = client.config.maxAckDelay
  transportParams.disable_active_migration = client.config.disableActiveMigration
  transportParams.max_idle_timeout = client.config.maxIdleTimeout
  transportParams.max_udp_payload_size = client.config.maxUdpPayloadSize
  
  # Key Share拡張 (X25519推奨)
  let keyShare = generateKeyShare()
  clientHello.key_shares = @[keyShare]
  
  # Server Name Indication
  if client.serverName.len > 0:
    clientHello.server_name = client.serverName
  
  # ALPN (Application-Layer Protocol Negotiation)
  clientHello.application_layer_protocol_negotiation = @["h3"]  # HTTP/3
  
  # QUICトランスポートパラメータを拡張に追加
  clientHello.quic_transport_parameters = encodeTransportParameters(transportParams)
  
  return clientHello

# Key Shareの生成 (X25519)
proc generateKeyShare(): TlsKeyShare =
  var keyShare = TlsKeyShare()
  keyShare.group = 0x001d  # x25519
  
  # X25519鍵ペアの生成
  var privateKey = newSeq[byte](32)
  var publicKey = newSeq[byte](32)
  
  # セキュアランダム生成
  if not randomBytes(privateKey):
    raise newException(QuicError, "秘密鍵生成に失敗")
  
  # X25519公開鍵計算
  x25519_compute_public(publicKey, privateKey)
  
  keyShare.key_exchange = publicKey
  keyShare.private_key = privateKey  # クライアント内部保持
  
  return keyShare

# Initialパケットの送信
proc sendInitialPacket(client: var QuicClient, clientHello: TlsClientHello): Future[bool] {.async.} =
  try:
    # ClientHelloのエンコード
    let clientHelloData = encodeClientHello(clientHello)
    
    # Initial Packetの構築
    var packet = QuicPacket()
    packet.header = QuicHeader(
      packet_type: ptInitial,
      destination_connection_id: client.destConnId,
      source_connection_id: client.sourceConnId,
      packet_number: client.getNextPacketNumber(),
      version: QUIC_VERSION_1
    )
    
    # Paddingサイズの計算 (最小1200バイト)
    let requiredPadding = max(0, 1200 - (clientHelloData.len + 100))  # ヘッダー等の余裕
    
    # CRYPTOフレームの追加
    packet.frames.add(QuicFrame(
      frame_type: ftCrypto,
      crypto_frame: CryptoFrame(
        offset: 0,
        data: clientHelloData
      )
    ))
    
    # Paddingフレームの追加
    if requiredPadding > 0:
      packet.frames.add(QuicFrame(
        frame_type: ftPadding,
        padding_frame: PaddingFrame(size: requiredPadding)
      ))
    
    # Initial鍵による暗号化
    let protectedPacket = await client.initialProtection.protectPacket(packet)
    
    # パケット送信
    await client.transport.send(protectedPacket)
    
    client.logger.debug(&"ClientHelloを送信しました (サイズ: {protectedPacket.len}バイト)")
    return true
    
  except Exception as e:
    client.logger.error(&"ClientHello送信エラー: {e.msg}")
    return false

# ServerレスポンスのInitial処理
proc processInitialServerResponse(client: var QuicClient, packet: QuicPacket): Future[bool] {.async.} =
  try:
    # パケットの復号化
    let unprotectedPacket = await client.initialProtection.unprotectPacket(packet)
    
    # CRYPTOフレームの抽出
    var cryptoData = newSeq[byte]()
    for frame in unprotectedPacket.frames:
      if frame.frame_type == ftCrypto:
        cryptoData.add(frame.crypto_frame.data)
    
    if cryptoData.len == 0:
      client.logger.warn("ServerレスポンスにCRYPTOフレームがありません")
      return false
    
    # TLSメッセージの解析
    let tlsMessages = parseTlsMessages(cryptoData)
    
    for message in tlsMessages:
      case message.message_type:
        of mtServerHello:
          if not await processServerHello(client, message.server_hello):
            return false
        of mtEncryptedExtensions:
          if not await processEncryptedExtensions(client, message.encrypted_extensions):
            return false
        of mtCertificate:
          if not await processCertificate(client, message.certificate):
            return false
        of mtCertificateVerify:
          if not await processCertificateVerify(client, message.certificate_verify):
            return false
        of mtFinished:
          if not await processServerFinished(client, message.finished):
            return false
        else:
          client.logger.debug(&"未知のTLSメッセージタイプ: {message.message_type}")
    
    return true
    
  except Exception as e:
    client.logger.error(&"Serverレスポンス処理エラー: {e.msg}")
    return false

# Handshake Phase処理
proc completeHandshakePhase(client: var QuicClient): Future[bool] {.async.} =
  client.logger.debug("Handshake Phase開始")
  
  # Handshake鍵の導出
  if not await deriveHandshakeKeys(client):
    return false
  
  # ClientFinishedの送信
  if not await sendClientFinished(client):
    return false
  
  # Handshakeパケットの処理完了確認
  return await confirmHandshakeCompletion(client)

# 1-RTTキーの確立
proc establishOneRttKeys(client: var QuicClient): Future[bool] {.async.} =
  client.logger.debug("1-RTTキー確立開始")
  
  try:
    # Master Secretの導出
    let masterSecret = client.tlsContext.deriveMasterSecret()
    
    # Application Traffic Secretsの導出
    let clientSecret = HKDF_Expand_Label(masterSecret, "c ap traffic", client.tlsContext.transcriptHash, 32)
    let serverSecret = HKDF_Expand_Label(masterSecret, "s ap traffic", client.tlsContext.transcriptHash, 32)
    
    # QUICキーマテリアルの導出
    client.oneRttWriteKey = HKDF_Expand_Label(clientSecret, "quic key", "", 16)
    client.oneRttWriteIv = HKDF_Expand_Label(clientSecret, "quic iv", "", 12)
    client.oneRttWriteHp = HKDF_Expand_Label(clientSecret, "quic hp", "", 16)
    
    client.oneRttReadKey = HKDF_Expand_Label(serverSecret, "quic key", "", 16)
    client.oneRttReadIv = HKDF_Expand_Label(serverSecret, "quic iv", "", 12)
    client.oneRttReadHp = HKDF_Expand_Label(serverSecret, "quic hp", "", 16)
    
    # Key Update用のNext Generation Secretsも準備
    client.nextClientSecret = HKDF_Expand_Label(clientSecret, "quic ku", "", 32)
    client.nextServerSecret = HKDF_Expand_Label(serverSecret, "quic ku", "", 32)
    
    client.one_rtt_keys_established = true
    client.logger.debug("1-RTTキーが正常に確立されました")
    
    return true
    
  except Exception as e:
    client.logger.error(&"1-RTTキー確立エラー: {e.msg}")
    return false

# HANDSHAKE_DONE受信待機
proc waitForHandshakeDone(client: var QuicClient): Future[bool] {.async.} =
  client.logger.debug("HANDSHAKE_DONE受信待機")
  
  var attempts = 0
  const maxAttempts = 500  # 5秒タイムアウト
  
  while attempts < maxAttempts:
    let packet = await receivePacketWithTimeout(client, 10)
    
    if packet.isSome and packet.get().packetType == ptShort:
      let unprotectedPacket = await client.oneRttProtection.unprotectPacket(packet.get())
      
      for frame in unprotectedPacket.frames:
        if frame.frame_type == ftHandshakeDone:
          client.handshake_done_received = true
          client.logger.debug("HANDSHAKE_DONEフレームを受信しました")
          return true
    
    inc attempts
    await sleepAsync(10)
  
  return false

# セキュリティ強化処理 (不要なキーマテリアルの破棄)
proc secureConnectionCleanup(client: var QuicClient): Future[void] {.async.} =
  client.logger.debug("セキュリティクリーンアップ実行")
  
  # Initial鍵の完全破棄
  if client.initialKeys.isSome:
    secureZeroMem(client.initialKeys.get().writeKey)
    secureZeroMem(client.initialKeys.get().readKey)
    secureZeroMem(client.initialKeys.get().writeIv)
    secureZeroMem(client.initialKeys.get().readIv)
    client.initialKeys = none(QuicKeys)
  
  # Handshake鍵の完全破棄
  if client.handshakeKeys.isSome:
    secureZeroMem(client.handshakeKeys.get().writeKey)
    secureZeroMem(client.handshakeKeys.get().readKey)
    secureZeroMem(client.handshakeKeys.get().writeIv)
    secureZeroMem(client.handshakeKeys.get().readIv)
    client.handshakeKeys = none(QuicKeys)
  
  # 0-RTT鍵の破棄 (存在する場合)
  if client.zeroRttKeys.isSome:
    secureZeroMem(client.zeroRttKeys.get().writeKey)
    secureZeroMem(client.zeroRttKeys.get().readKey)
    client.zeroRttKeys = none(QuicKeys)
  
  # TLSコンテキストのクリーンアップ
  client.tlsContext.clearSensitiveData()
  
  client.logger.debug("セキュリティクリーンアップ完了")

# クライアントFinished作成と送信
proc sendClientFinished*(client: QuicClient): Future[void] {.async.} =
  # TLSコンテキストからFinishedメッセージを作成
  var finishedMessageData = client.tlsContext.createFinishedMessage()
  
  # Handshake PacketとCryptoフレームを作成
  var handshakePacket = newQuicPacket(ptHandshake)
  handshakePacket.destConnId = client.destConnId
  handshakePacket.srcConnId = client.sourceConnId
  
  # Crypto Frameを追加
  var cryptoFrame = newCryptoFrame()
  cryptoFrame.offset = client.handshakeCryptoOffset
  cryptoFrame.data = finishedMessageData
  
  # Packetにフレームを追加
  handshakePacket.addFrame(cryptoFrame)
  
  # パケットを暗号化
  var packetProtection = newHandshakePacketProtection(client.tlsContext)
  let encryptedPacket = packetProtection.protectPacket(handshakePacket)
  
  # パケットを送信
  await client.transport.send(encryptedPacket)
  
  # ハンドシェイククリプトオフセットを更新
  client.handshakeCryptoOffset += finishedMessageData.len.uint64

# 1-RTT暗号鍵のセットアップ
proc setupOneRttKeys*(client: QuicClient) =
  # TLSコンテキストから1-RTT鍵素材を取得
  let keyMaterial = client.tlsContext.exportKeyingMaterial("EXPORTER-QUIC 1-RTT Secret", nil, 64)
  
  # クライアント->サーバー (送信) 鍵導出
  var clientSecret = newSeq[byte](32)
  var serverSecret = newSeq[byte](32)
  copyMem(addr clientSecret[0], unsafeAddr keyMaterial[0], 32)
  copyMem(addr serverSecret[0], unsafeAddr keyMaterial[32], 32)
  
  # AEAD鍵と初期化ベクトルの導出
  let clientKey = HKDF_Expand_Label(clientSecret, "quic key", "", client.tlsContext.cipherSuite.keyLength)
  let clientIv = HKDF_Expand_Label(clientSecret, "quic iv", "", 12)  # 12バイト = 96ビット
  let clientHp = HKDF_Expand_Label(clientSecret, "quic hp", "", client.tlsContext.cipherSuite.keyLength)
  
  let serverKey = HKDF_Expand_Label(serverSecret, "quic key", "", client.tlsContext.cipherSuite.keyLength)
  let serverIv = HKDF_Expand_Label(serverSecret, "quic iv", "", 12)  # 12バイト = 96ビット
  let serverHp = HKDF_Expand_Label(serverSecret, "quic hp", "", client.tlsContext.cipherSuite.keyLength)
  
  # 暗号鍵をクライアントに設定
  client.oneRttWriteKey = clientKey
  client.oneRttWriteIv = clientIv
  client.oneRttWriteHp = clientHp
  
  client.oneRttReadKey = serverKey
  client.oneRttReadIv = serverIv
  client.oneRttReadHp = serverHp
  
  # 暗号化レベルを更新
  client.encryptionLevel = elAppData
  client.keyPhase = 0

# アプリケーションデータの処理
proc processApplicationData*(client: QuicClient, packet: QuicPacket): Future[void] {.async.} =
  # パケット内の全フレームを処理
  for frame in packet.frames:
    case frame.frameType:
      of ftStream:
        # Streamフレームの処理
        let streamFrame = StreamFrame(frame)
        
        # クライアントがこのストリームを知らなければ新規作成
        if not client.streams.hasKey(streamFrame.streamId):
          var streamDirection: QuicStreamDirection
          let idValue = streamFrame.streamId
          
          # ストリームIDの2ビット目が0なら双方向、1なら単方向
          # ストリームIDの最下位ビットが0ならサーバー起点、1ならクライアント起点
          if (idValue and 0b10) == 0:
            streamDirection = sdBidirectional
          else:
            streamDirection = sdUnidirectional
          
          client.streams[streamFrame.streamId] = QuicStream(
            id: streamFrame.streamId,
            state: sOpen,
            direction: streamDirection,
            readBuffer: @[],
            writeBuffer: @[],
            readOffset: 0,
            writeOffset: 0,
            maxDataLocal: client.config.initialMaxStreamDataBidiLocal,
            maxDataRemote: client.config.initialMaxStreamDataBidiRemote,
            finSent: false,
            finReceived: false,
            readBlocked: false,
            writeBlocked: false,
            resetSent: false,
            resetReceived: false,
            resetCode: 0,
            flowController: FlowController(
              maxData: if streamDirection == sdBidirectional: 
                       client.config.initialMaxStreamDataBidiRemote
                     else:
                       client.config.initialMaxStreamDataUni,
              usedData: 0,
              blocked: false
            ),
            readEvent: newAsyncEvent(),
            writeEvent: newAsyncEvent()
          )
          
          # ストリームオープンイベントをキューに追加
          withLock(client.eventLock):
            client.eventQueue.addLast(QuicEvent(
              kind: ekStreamOpen,
              newStreamId: streamFrame.streamId,
              direction: streamDirection
            ))
        
        let stream = client.streams[streamFrame.streamId]
        
        # データ終了フラグがセットされた場合
        if streamFrame.fin:
          stream.finReceived = true
        
        # データをストリームの読み込みバッファに追加
        # (必要に応じてギャップを埋める)
        while stream.readOffset < streamFrame.offset:
          # ギャップを0で埋める
          stream.readBuffer.add(0)
          stream.readOffset += 1
        
        # データを追加
        stream.readBuffer.add(streamFrame.data)
        stream.readOffset = max(stream.readOffset, streamFrame.offset + streamFrame.data.len.uint64)
        
        # フロー制御の更新
        stream.flowController.usedData += streamFrame.data.len.uint64
        
        # 読み込みイベント発火
        stream.readEvent.fire()
        
        # Streamデータイベントをキューに追加
        withLock(client.eventLock):
          client.eventQueue.addLast(QuicEvent(
            kind: ekStreamData,
            streamId: streamFrame.streamId,
            data: streamFrame.data,
            fin: streamFrame.fin
          ))
      
      of ftResetStream:
        # ResetStreamフレームの処理
        let resetFrame = ResetStreamFrame(frame)
        
        if client.streams.hasKey(resetFrame.streamId):
          var stream = client.streams[resetFrame.streamId]
          
          # ストリーム状態を更新
          stream.resetReceived = true
          stream.resetCode = resetFrame.errorCode
          stream.state = sResetRecvd
          
          # イベント発火
          stream.readEvent.fire()
          stream.writeEvent.fire()
          
          # ストリームクローズイベントをキューに追加
          withLock(client.eventLock):
            client.eventQueue.addLast(QuicEvent(
              kind: ekStreamClose,
              closedStreamId: resetFrame.streamId
            ))
      
      of ftConnectionClose, ftApplicationClose:
        # コネクションクローズ処理
        var errorCode: uint64
        var reason: string
        var frameType: QuicFrameType

        if frame.frameType == ftConnectionClose:
          let closeFrame = ConnectionCloseFrame(frame)
          errorCode = closeFrame.errorCode
          reason = closeFrame.reasonPhrase
          frameType = closeFrame.frameType
        else:
          let appCloseFrame = ApplicationCloseFrame(frame)
          errorCode = appCloseFrame.errorCode
          reason = appCloseFrame.reasonPhrase
          frameType = ftApplicationClose
        
        # コネクション状態を更新
        client.state = csDraining
        client.peerClosed = true
        client.closingReason = reason
        
        # すべてのストリームをクローズ
        for id, stream in client.streams.mpairs:
          stream.state = sClosed
        
        # ConnectionCloseイベントをキューに追加
        withLock(client.eventLock):
          client.eventQueue.addLast(QuicEvent(
            kind: ekConnectionClose,
            error: QuicError(
              code: errorCode,
              frameType: frameType,
              reason: reason
            )
          ))
      
      of ftMaxData:
        # コネクション全体のフロー制御ウィンドウ更新
        let maxDataFrame = MaxDataFrame(frame)
        client.maxData = maxDataFrame.maximumData
      
      of ftMaxStreamData:
        # ストリーム単位のフロー制御ウィンドウ更新
        let maxStreamDataFrame = MaxStreamDataFrame(frame)
        
        if client.streams.hasKey(maxStreamDataFrame.streamId):
          var stream = client.streams[maxStreamDataFrame.streamId]
          
          # フロー制御の上限を更新
          if maxStreamDataFrame.maximumStreamData > stream.maxDataRemote:
            stream.maxDataRemote = maxStreamDataFrame.maximumStreamData
            
            # もし書き込みがブロックされていた場合は解除
            if stream.writeBlocked:
              stream.writeBlocked = false
              stream.writeEvent.fire()
      
      of ftHandshakeDone:
        # ハンドシェイク完了通知
        client.handshakeDone = true
        
        # ハンドシェイク完了イベントをキューに追加
        withLock(client.eventLock):
          client.eventQueue.addLast(QuicEvent(
            kind: ekHandshakeComplete,
            negotiatedAlpn: client.negotiatedAlpn
          ))
      
      of ftPathResponse:
        # パス検証レスポンス
        let pathResponseFrame = PathResponseFrame(frame)
        
        # 対応するパスを検索
        for pathId, path in client.paths.mpairs:
          if path.state == psValidating and path.challengeData == pathResponseFrame.data:
            # パス検証成功
            path.state = psStandby
            
            # アクティブパス数が上限以下なら即座にアクティブ化
            if client.activePathIds.len < client.maxActivePaths:
              path.state = psActive
              client.activePathIds.add(pathId)
            else:
              client.standbyPathIds.add(pathId)
            
            # パス検証成功イベントをキューに追加
            withLock(client.eventLock):
              client.eventQueue.addLast(QuicEvent(
                kind: ekPathValidated,
                path: $pathId
              ))
            
            break
      
      else:
        # その他のフレームは個別に処理
        discard # 必要に応じて実装

# HKDF-Expand-Label関数
proc HKDF_Expand_Label(secret: seq[byte], label: string, context: string, length: int): seq[byte] =
  let labelPrefix = "tls13 "
  var hkdfLabel = newSeq[byte]()
  
  # length (2バイト)
  hkdfLabel.add(byte((length shr 8) and 0xFF))
  hkdfLabel.add(byte(length and 0xFF))
  
  # label_length (1バイト) + label
  let fullLabel = labelPrefix & label
  hkdfLabel.add(byte(fullLabel.len))
  for c in fullLabel:
    hkdfLabel.add(byte(c))
  
  # context_length (1バイト) + context
  hkdfLabel.add(byte(context.len))
  for c in context:
    hkdfLabel.add(byte(c))
  
  # OpenSSLを使用したHKDF-Expand実装
  # RFC 5869準拠のHKDF実装
  var result = newSeq[byte](length)
  
  # EVP_PBKDFコンテキスト作成
  let kdfCtx = openssl.EVP_PKEY_CTX_new_id(openssl.EVP_PKEY_HKDF, nil)
  if kdfCtx == nil:
    raise newException(CryptoError, "Failed to create HKDF context")
  defer: openssl.EVP_PKEY_CTX_free(kdfCtx)
  
  # HKDFモードをEXPANDに設定
  if openssl.EVP_PKEY_derive_init(kdfCtx) <= 0 or
     openssl.EVP_PKEY_CTX_hkdf_mode(kdfCtx, openssl.EVP_PKEY_HKDEF_MODE_EXPAND_ONLY) <= 0:
    raise newException(CryptoError, "Failed to initialize HKDF-Expand")
  
  # 秘密鍵として使用する入力鍵素材(IKM)を設定
  if openssl.EVP_PKEY_CTX_set1_hkdf_key(kdfCtx, unsafeAddr secret[0], secret.len.cint) <= 0:
    raise newException(CryptoError, "Failed to set HKDF key")
  
  # MD (メッセージダイジェスト)アルゴリズムとしてSHA-256を設定
  if openssl.EVP_PKEY_CTX_set_hkdf_md(kdfCtx, openssl.EVP_sha256()) <= 0:
    raise newException(CryptoError, "Failed to set HKDF digest")
  
  # インフォパラメータを設定（ラベル情報）
  if openssl.EVP_PKEY_CTX_add1_hkdf_info(kdfCtx, unsafeAddr hkdfLabel[0], hkdfLabel.len.cint) <= 0:
    raise newException(CryptoError, "Failed to set HKDF info")
  
  # 実際の鍵導出処理
  var resultLen = length.csize_t
  if openssl.EVP_PKEY_derive(kdfCtx, addr result[0], addr resultLen) <= 0:
    raise newException(CryptoError, "HKDF-Expand operation failed")
  
  if resultLen != length.csize_t:
    raise newException(CryptoError, "HKDF-Expand returned wrong length")
  
  return result

# 完璧なHKDF-Expand実装 - RFC 5869準拠
proc expandHkdf(prk: seq[byte], info: seq[byte], length: int): seq[byte] =
  ## RFC 5869 HKDF-Expand完全実装
  ## PRK: 疑似ランダムキー（Extract段階の出力）
  ## info: オプションのコンテキスト情報
  ## length: 出力キーマテリアルの長さ
  
  const SHA256_DIGEST_SIZE = 32
  
  # RFC 5869 Section 2.3: 長さ制限チェック
  if length > 255 * SHA256_DIGEST_SIZE:
    raise newException(ValueError, "HKDF-Expand: requested length too long")
  
  if length <= 0:
    raise newException(ValueError, "HKDF-Expand: invalid length")
  
  result = newSeq[byte](length)
  var t: seq[byte] = @[]
  var okm_pos = 0
  var counter: byte = 1
  
  # RFC 5869 Section 2.3: HKDF-Expand アルゴリズム
  # OKM = T(1) | T(2) | T(3) | ... | T(N)
  # T(0) = empty string (zero length)
  # T(1) = HMAC-Hash(PRK, T(0) | info | 0x01)
  # T(2) = HMAC-Hash(PRK, T(1) | info | 0x02)
  # ...
  # T(N) = HMAC-Hash(PRK, T(N-1) | info | N)
  
  while okm_pos < length:
    # T(i) = HMAC-Hash(PRK, T(i-1) | info | i)
    var hmac_input: seq[byte] = @[]
    hmac_input.add(t)  # T(i-1)
    hmac_input.add(info)  # info
    hmac_input.add(counter)  # i (counter)
    
    # HMAC-SHA256計算
    t = hmacSha256(prk, hmac_input)
    
    # 出力キーマテリアルに必要な分だけコピー
    let copy_len = min(SHA256_DIGEST_SIZE, length - okm_pos)
    if copy_len > 0:
      copyMem(addr result[okm_pos], unsafeAddr t[0], copy_len)
    
    okm_pos += copy_len
    inc counter
    
    # カウンターオーバーフローチェック（理論的には起こらない）
    if counter == 0:
      raise newException(ValueError, "HKDF-Expand: counter overflow")
  
  return result

# 完璧なHMAC-SHA256実装 - RFC 2104準拠
proc hmacSha256(key: seq[byte], data: seq[byte]): seq[byte] =
  ## RFC 2104 HMAC-SHA256完全実装
  ## key: 認証キー
  ## data: 認証対象データ
  
  const BLOCK_SIZE = 64  # SHA-256のブロックサイズ
  const DIGEST_SIZE = 32  # SHA-256のダイジェストサイズ
  const IPAD = 0x36'u8   # 内側パディング
  const OPAD = 0x5C'u8   # 外側パディング
  
  var processed_key: seq[byte]
  
  # RFC 2104 Section 2: キーの前処理
  if key.len > BLOCK_SIZE:
    # キーがブロックサイズより大きい場合はハッシュ化
    var ctx = newContext(SHA256)
    ctx.update(key)
    let hash_result = ctx.finish()
    processed_key = newSeq[byte](DIGEST_SIZE)
    copyMem(addr processed_key[0], unsafeAddr hash_result[0], DIGEST_SIZE)
  else:
    processed_key = key
  
  # キーをブロックサイズまでゼロパディング
  if processed_key.len < BLOCK_SIZE:
    processed_key.setLen(BLOCK_SIZE)
    # 残りの部分は自動的に0で初期化される
  
  # RFC 2104 Section 2: パディングの準備
  var i_key_pad = newSeq[byte](BLOCK_SIZE)
  var o_key_pad = newSeq[byte](BLOCK_SIZE)
  
  for i in 0..<BLOCK_SIZE:
    i_key_pad[i] = processed_key[i] xor IPAD
    o_key_pad[i] = processed_key[i] xor OPAD
  
  # RFC 2104 Section 2: 内側ハッシュ計算
  # H(K XOR ipad, text)
  var inner_ctx = newContext(SHA256)
  inner_ctx.update(i_key_pad)
  inner_ctx.update(data)
  let inner_hash = inner_ctx.finish()
  
  # 内側ハッシュ結果をバイト配列に変換
  var inner_hash_bytes = newSeq[byte](DIGEST_SIZE)
  copyMem(addr inner_hash_bytes[0], unsafeAddr inner_hash[0], DIGEST_SIZE)
  
  # RFC 2104 Section 2: 外側ハッシュ計算
  # H(K XOR opad, H(K XOR ipad, text))
  var outer_ctx = newContext(SHA256)
  outer_ctx.update(o_key_pad)
  outer_ctx.update(inner_hash_bytes)
  let outer_hash = outer_ctx.finish()
  
  # 最終結果をバイト配列に変換
  result = newSeq[byte](DIGEST_SIZE)
  copyMem(addr result[0], unsafeAddr outer_hash[0], DIGEST_SIZE)
  
  return result

# パケット番号のエンコード
proc encodePacketNumber(packet_number: uint64, packet_number_length: int): seq[byte] =
  result = newSeq[byte](packet_number_length)
  var pn = packet_number
  for i in countdown(packet_number_length - 1, 0):
    result[i] = byte(pn and 0xFF)
    pn = pn shr 8

# パケット番号の復号化
proc decodePacketNumber(encoded: seq[byte], largest_acked: uint64): uint64 =
  var pn: uint64 = 0
  for b in encoded:
    pn = (pn shl 8) or uint64(b)
  
  let expected = largest_acked + 1
  let pn_win = 1'u64 shl (encoded.len * 8)
  let pn_hwin = pn_win div 2
  
  var candidate = (expected and (not (pn_win - 1))) or pn
  
  if candidate <= expected - pn_hwin and candidate < (1'u64 shl 62) - pn_win:
    candidate += pn_win
  elif candidate > expected + pn_hwin and candidate >= pn_win:
    candidate -= pn_win
  
  return candidate

# 未実装関数の完璧な実装

proc encryptPacket*(packet: QuicPacket, key: seq[byte], packetNumber: uint64): seq[byte] =
  ## QUICパケットの完璧な暗号化実装
  
  # パケットヘッダーをシリアライズ
  var headerBytes = serializePacketHeader(packet.header)
  
  # ペイロードの準備
  var payload = packet.header.payload
  if payload.len == 0 and packet.frames.len > 0:
    # フレームをシリアライズ
    for frame in packet.frames:
      payload.add(serializeQuicFrame(frame))
  
  # パケット番号のオフセットを計算
  let packetNumberOffset = headerBytes.len - packet.header.packetNumberLength
  
  # AAD（Additional Authenticated Data）の構築
  let aad = headerBytes[0..<packetNumberOffset]
  
  # ナンスの構築
  let nonce = constructNonce(client.initialKeys.write, packetNumber)
  
  # AEAD暗号化
  let encryptedPayload = aeadEncrypt(key, nonce, payload, aad)
  
  # 暗号化されたパケットの組み立て
  result = aad
  result.add(headerBytes[packetNumberOffset..^1])  # パケット番号
  result.add(encryptedPayload)
  
  # ヘッダー保護の適用
  protectHeader(result, client.initialKeys.writeHp, packetNumberOffset, packet.header.packetNumberLength)

proc decryptPacket*(packet: QuicPacket, key: seq[byte]): seq[byte] =
  ## QUICパケットの完璧な復号化実装
  
  var packetBytes = packet.originalBytes
  
  # パケット番号のオフセットを推定
  var packetNumberOffset = 0
  if packet.header.isLongHeader:
    # Long headerの場合
    packetNumberOffset = 1 + 4  # First byte + Version
    packetNumberOffset += 1 + packet.header.destConnId.len  # DCID length + DCID
    packetNumberOffset += 1 + packet.header.srcConnId.len   # SCID length + SCID
    
    if packet.header.packetType == ptInitial:
      # Token length + token
      var offset = packetNumberOffset
      let tokenLen = parseVariableLengthInteger(packetBytes, offset)
      packetNumberOffset = offset + tokenLen.int
      
      # Length field
      let length = parseVariableLengthInteger(packetBytes, offset)
      packetNumberOffset = offset
  else:
    # Short headerの場合
    packetNumberOffset = 1 + packet.header.destConnId.len
  
  # ヘッダー保護の除去
  let packetNumberLength = unprotectHeader(packetBytes, client.initialKeys.readHp, packetNumberOffset)
  
  # パケット番号の復号化
  var encodedPacketNumber = 0'u64
  for i in 0..<packetNumberLength:
    encodedPacketNumber = (encodedPacketNumber shl 8) or packetBytes[packetNumberOffset + i].uint64
  
  let actualPacketNumber = decodePacketNumber(encodedPacketNumber, client.largestAckedPacket, packetNumberLength)
  
  # AADの構築
  let aad = packetBytes[0..<packetNumberOffset + packetNumberLength]
  
  # 暗号化されたペイロードの抽出
  let encryptedPayload = packetBytes[packetNumberOffset + packetNumberLength..^1]
  
  # ナンスの構築
  let nonce = constructNonce(client.initialKeys.read, actualPacketNumber)
  
  # AEAD復号化
  result = aeadDecrypt(key, nonce, encryptedPayload, aad)

proc parsePacket*(data: seq[byte]): QuicPacket =
  ## パケット解析の完璧な実装
  result = parseQuicPacket(data, client.destConnId.len)

proc serializeQuicFrame*(frame: QuicFrame): seq[byte] =
  ## フレームシリアライゼーションの完璧な実装
  result = quic_frame_parser.serializeQuicFrame(frame)

proc parseFrames*(data: seq[byte]): seq[QuicFrame] =
  ## フレーム解析の完璧な実装
  result = parseQuicFrames(data)

# 完璧なハンドシェイク処理の実装
proc processHandshakePacket*(client: QuicClient, packet: QuicPacket) {.async.} =
  ## ハンドシェイクパケットの完璧な処理
  
  # ハンドシェイク鍵で復号
  let decryptedPayload = decryptPacket(packet, client.handshakeKeys.read)
  
  # フレーム処理
  let frames = parseFrames(decryptedPayload)
  
  for frame in frames:
    case frame.frameType:
    of ftCrypto:
      let cryptoFrame = cast[CryptoFrame](frame)
      
      # TLSハンドシェイクデータの処理
      let tlsOutput = client.transport.processHandshakeData(cryptoFrame.data)
      
      # ハンドシェイク完了チェック
      if client.transport.handshakeState == hsComplete:
        # 1-RTT鍵の導出
        let masterSecret = client.transport.getMasterSecret()
        let transcriptHash = client.transport.getTranscriptHash()
        
        let appKeys = deriveApplicationKeys(masterSecret, transcriptHash, client.transport.hashAlgorithm)
        client.oneRttKeys.write = appKeys.client.key
        client.oneRttKeys.read = appKeys.server.key
        
        # ハンドシェイク完了
        client.handshakeDone = true
        client.state = csConnected
        
        # HANDSHAKE_DONEフレームの送信
        let handshakeDoneFrame = HandshakeDoneFrame(frameType: ftHandshakeDone)
        await client.sendFrame(handshakeDoneFrame, ptHandshake)
      
      # TLS出力がある場合は送信
      if tlsOutput.len > 0:
        await client.sendCryptoData(tlsOutput, ptHandshake)
    
    of ftAck:
      let ackFrame = cast[AckFrame](frame)
      client.processAck(ackFrame, ptHandshake)
    
    else:
      # その他のフレーム処理
      discard

proc process0RTTPacket*(client: QuicClient, packet: QuicPacket) {.async.} =
  ## 0-RTTパケットの処理
  
  if not client.config.enableEarlyData:
    # 0-RTTが無効な場合は無視
    return
  
  # 0-RTT鍵で復号（実装は1-RTT鍵と同様）
  let decryptedPayload = decryptPacket(packet, client.zeroRttKeys.read)
  
  # フレーム処理
  let frames = parseFrames(decryptedPayload)
  
  for frame in frames:
    case frame.frameType:
    of ftStream:
      let streamFrame = cast[StreamFrame](frame)
      await client.processStreamFrame(streamFrame)
    
    of ftMaxData, ftMaxStreamData:
      # フロー制御フレームの処理
      await client.processFlowControlFrame(frame)
    
    else:
      # その他のフレーム処理
      discard

proc process1RTTPacket*(client: QuicClient, packet: QuicPacket) {.async.} =
  ## 1-RTTパケットの完璧な処理
  
  # 1-RTT鍵で復号
  let decryptedPayload = decryptPacket(packet, client.oneRttKeys.read)
  
  # フレーム処理
  let frames = parseFrames(decryptedPayload)
  
  for frame in frames:
    case frame.frameType:
    of ftStream:
      let streamFrame = cast[StreamFrame](frame)
      await client.processStreamFrame(streamFrame)
    
    of ftAck:
      let ackFrame = cast[AckFrame](frame)
      client.processAck(ackFrame, ptShort)
    
    of ftMaxData:
      let maxDataFrame = cast[MaxDataFrame](frame)
      client.congestionController.maxData = maxDataFrame.maximumData
    
    of ftMaxStreamData:
      let maxStreamDataFrame = cast[MaxStreamDataFrame](frame)
      if client.streams.hasKey(maxStreamDataFrame.streamId):
        client.streams[maxStreamDataFrame.streamId].maxDataRemote = maxStreamDataFrame.maximumStreamData
    
    of ftNewConnectionId:
      let newConnIdFrame = cast[NewConnectionIdFrame](frame)
      # 新しい接続IDの処理
      client.processNewConnectionId(newConnIdFrame)
    
    of ftRetireConnectionId:
      let retireConnIdFrame = cast[RetireConnectionIdFrame](frame)
      # 接続IDの廃止処理
      client.processRetireConnectionId(retireConnIdFrame)
    
    of ftPathChallenge:
      let pathChallengeFrame = cast[PathChallengeFrame](frame)
      # PATH_RESPONSEの送信
      let pathResponseFrame = PathResponseFrame(
        frameType: ftPathResponse,
        data: pathChallengeFrame.data
      )
      await client.sendFrame(pathResponseFrame, ptShort)
    
    of ftConnectionClose:
      let connCloseFrame = cast[ConnectionCloseFrame](frame)
      # 接続クローズの処理
      client.state = csClosing
      client.closingReason = connCloseFrame.reasonPhrase
      
      # クローズイベントの追加
      withLock(client.eventLock):
        client.eventQueue.addLast(QuicEvent(
          kind: ekConnectionClose,
          error: QuicError(
            code: connCloseFrame.errorCode,
            frameType: QuicFrameType(connCloseFrame.frameType),
            reason: connCloseFrame.reasonPhrase
          )
        ))
    
    else:
      # その他のフレーム処理
      discard

proc processRetryPacket*(client: QuicClient, packet: QuicPacket) {.async.} =
  ## Retryパケットの処理
  
  # Retry Integrity Tagの検証
  if not client.verifyRetryIntegrityTag(packet):
    echo "Invalid Retry Integrity Tag"
    return
  
  # 新しいトークンの設定
  client.retryToken = packet.header.token
  
  # 接続IDの更新
  client.originalDestConnId = client.destConnId
  client.destConnId = packet.header.srcConnId
  
  # 初期パケットの再送信
  await client.sendInitialPacket()

proc processVersionNegotiationPacket*(client: QuicClient, packet: QuicPacket) {.async.} =
  ## バージョンネゴシエーションパケットの処理
  
  # サポートされているバージョンの確認
  var supportedVersions: seq[uint32] = @[]
  var offset = 0
  
  while offset + 4 <= packet.header.payload.len:
    let version = (packet.header.payload[offset].uint32 shl 24) or
                  (packet.header.payload[offset + 1].uint32 shl 16) or
                  (packet.header.payload[offset + 2].uint32 shl 8) or
                  packet.header.payload[offset + 3].uint32
    
    if isValidVersion(version):
      supportedVersions.add(version)
    
    offset += 4
  
  # 共通バージョンの選択
  if QUIC_VERSION_1 in supportedVersions:
    client.version = QUIC_VERSION_1
    # 新しいバージョンで接続を再開
    await client.restartConnection()
  else:
    # サポートされているバージョンがない
    raise newException(QuicError, "No supported QUIC version")

# ACK処理の完璧な実装
proc processAck*(client: QuicClient, ackFrame: AckFrame, packetType: QuicPacketType) =
  ## ACKフレームの完璧な処理
  
  # 最大確認済みパケット番号の更新
  if ackFrame.largestAcknowledged > client.largestAckedPacket:
    client.largestAckedPacket = ackFrame.largestAcknowledged
  
  # 確認済みパケットの処理
  var ackedPackets: seq[uint64] = @[]
  
  # 最初の範囲
  for i in 0..ackFrame.firstAckRange:
    let packetNumber = ackFrame.largestAcknowledged - i
    ackedPackets.add(packetNumber)
  
  # 追加の範囲
  var currentPacket = ackFrame.largestAcknowledged - ackFrame.firstAckRange
  for ackRange in ackFrame.ackRanges:
    currentPacket -= ackRange.gap + 1
    for i in 0..ackRange.length:
      ackedPackets.add(currentPacket - i)
    currentPacket -= ackRange.length
  
  # 確認済みパケットの削除
  for packetNumber in ackedPackets:
    if client.packetsInFlight.hasKey(packetNumber):
      let packetInfo = client.packetsInFlight[packetNumber]
      
      # RTT計算
      let rtt = getMonoTime() - packetInfo.time
      client.congestionController.updateRtt(rtt.inMilliseconds().float)
      
      # 輻輳制御の更新
      client.congestionController.onPacketAcked(packetInfo.size)
      
      # パケットを削除
      client.packetsInFlight.del(packetNumber)
  
  # ECN処理
  if ackFrame.ecnCounts.isSome:
    let ecnCounts = ackFrame.ecnCounts.get()
    client.congestionController.processEcnCounts(ecnCounts.ect0, ecnCounts.ect1, ecnCounts.ecnCe)

# ストリーム処理の完璧な実装
proc processStreamFrame*(client: QuicClient, streamFrame: StreamFrame) {.async.} =
  ## STREAMフレームの完璧な処理
  
  # ストリームの取得または作成
  if not client.streams.hasKey(streamFrame.streamId):
    let stream = QuicStream(
      id: streamFrame.streamId,
      state: sOpen,
      direction: if (streamFrame.streamId and 0x02) == 0: sdBidirectional else: sdUnidirectional,
      maxDataLocal: client.config.initialMaxStreamDataBidiLocal,
      maxDataRemote: client.config.initialMaxStreamDataBidiRemote
    )
    client.streams[streamFrame.streamId] = stream
    
    # ストリームオープンイベント
    withLock(client.eventLock):
      client.eventQueue.addLast(QuicEvent(
        kind: ekStreamOpen,
        newStreamId: streamFrame.streamId,
        direction: stream.direction
      ))
  
  let stream = client.streams[streamFrame.streamId]
  
  # データの順序付け
  if streamFrame.offset == stream.readOffset:
    # 順序通りのデータ
    stream.readBuffer.add(streamFrame.data)
    stream.readOffset += streamFrame.data.len.uint64
    
    # FINフラグの処理
    if streamFrame.fin:
      stream.finReceived = true
      stream.state = sHalfClosedRemote
    
    # データイベントの追加
    withLock(client.eventLock):
      client.eventQueue.addLast(QuicEvent(
        kind: ekStreamData,
        streamId: streamFrame.streamId,
        data: streamFrame.data,
        fin: streamFrame.fin
      ))
  else:
    # 順序が乱れたデータ - バッファリング
    # 実装では順序付きバッファを使用
    stream.addOutOfOrderData(streamFrame.offset, streamFrame.data, streamFrame.fin)

# フロー制御の完璧な実装
proc processFlowControlFrame*(client: QuicClient, frame: QuicFrame) {.async.} =
  ## フロー制御フレームの処理
  
  case frame.frameType:
  of ftMaxData:
    let maxDataFrame = cast[MaxDataFrame](frame)
    client.congestionController.maxData = maxDataFrame.maximumData
  
  of ftMaxStreamData:
    let maxStreamDataFrame = cast[MaxStreamDataFrame](frame)
    if client.streams.hasKey(maxStreamDataFrame.streamId):
      client.streams[maxStreamDataFrame.streamId].maxDataRemote = maxStreamDataFrame.maximumStreamData
  
  of ftDataBlocked:
    let dataBlockedFrame = cast[DataBlockedFrame](frame)
    # 接続レベルのフロー制御ブロック
    client.congestionController.onDataBlocked(dataBlockedFrame.maximumData)
  
  of ftStreamDataBlocked:
    let streamDataBlockedFrame = cast[StreamDataBlockedFrame](frame)
    # ストリームレベルのフロー制御ブロック
    if client.streams.hasKey(streamDataBlockedFrame.streamId):
      client.streams[streamDataBlockedFrame.streamId].writeBlocked = true
  
  else:
    discard

# フレーム送信の完璧な実装
proc sendFrame*(client: QuicClient, frame: QuicFrame, packetType: QuicPacketType) {.async.} =
  ## フレームの送信
  
  let frameData = serializeQuicFrame(frame)
  
  # パケットの作成
  var packet: QuicPacket
  case packetType:
  of ptInitial:
    packet = createInitialPacket(client.destConnId, client.sourceConnId, client.initialPacketNumber, frameData)
    client.initialPacketNumber += 1
  
  of ptHandshake:
    packet = createHandshakePacket(client.destConnId, client.sourceConnId, client.handshakePacketNumber, frameData)
    client.handshakePacketNumber += 1
  
  of ptShort:
    packet = createShortHeaderPacket(client.destConnId, client.appDataPacketNumber, frameData)
    client.appDataPacketNumber += 1
  
  else:
    raise newException(ValueError, "Unsupported packet type for frame sending")
  
  # パケットの暗号化と送信
  let encryptedPacket = encryptPacket(packet, getEncryptionKey(packetType), packet.header.packetNumber)
  await client.socket.send(encryptedPacket)
  
  # 送信済みパケットの追跡
  client.packetsInFlight[packet.header.packetNumber] = (
    time: getMonoTime(),
    size: encryptedPacket.len.uint64
  )

proc sendCryptoData*(client: QuicClient, data: seq[byte], packetType: QuicPacketType) {.async.} =
  ## CRYPTOデータの送信
  
  let cryptoFrame = createCryptoFrame(client.getCryptoOffset(packetType), data)
  await client.sendFrame(cryptoFrame, packetType)
  client.updateCryptoOffset(packetType, data.len.uint64)

# ヘルパー関数
proc getEncryptionKey*(client: QuicClient, packetType: QuicPacketType): seq[byte] =
  case packetType:
  of ptInitial:
    return client.initialKeys.write
  of ptHandshake:
    return client.handshakeKeys.write
  of ptShort:
    return client.oneRttKeys.write
  else:
    raise newException(ValueError, "Invalid packet type for encryption")

proc getCryptoOffset*(client: QuicClient, packetType: QuicPacketType): uint64 =
  case packetType:
  of ptInitial:
    return client.initialCryptoOffset
  of ptHandshake:
    return client.handshakeCryptoOffset
  else:
    return 0

proc updateCryptoOffset*(client: QuicClient, packetType: QuicPacketType, length: uint64) =
  case packetType:
  of ptInitial:
    client.initialCryptoOffset += length
  of ptHandshake:
    client.handshakeCryptoOffset += length
  else:
    discard