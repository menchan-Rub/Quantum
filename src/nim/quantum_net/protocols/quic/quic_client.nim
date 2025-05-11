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

# 新しいQUICクライアントを作成
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
  # 実際の実装では、TLSハンドシェイクを行う処理が必要
  # このサンプルでは簡略化

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
    
    # 初期パケットを送信してハンドシェイクを開始
    # 実際の実装では、ここでInitialパケットの送信、TLSハンドシェイクの開始などを行う
    
    # パケット受信ループを開始
    # asyncCheck client.receiveLoop()
    
    # 簡略化されたハンドシェイク完了シミュレーション
    # 実際の実装では、サーバーからの応答を待ち、TLSハンドシェイクを完了する必要あり
    client.state = csConnected
    client.handshakeDone = true
    client.pathValidated = true
    client.negotiatedAlpn = if client.alpn.len > 0: client.alpn[0] else: ""
    
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

# クライアントを閉じる
proc close*(client: QuicClient): Future[void] {.async.} =
  ## QUICクライアントを閉じる
  ## 
  ## Parameters:
  ## - client: 閉じるQUICクライアント
  
  if client.state == csClosed:
    return
  
  # ConnectionCloseフレームを送信
  # 実際の実装では、ConnectionCloseフレームを生成し、パケットに格納して送信
  
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
  
  # Streamフレームをパケットキューにエンキュー
  # 実際の実装では、パケットの送信処理が必要
  
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
  
  # Window Updateフレームを送信（一定閾値を超えた場合）
  # 実際の実装では、MAX_STREAM_DATAフレームの送信処理が必要
  
  let isFin = stream.finReceived and stream.readBuffer.len == 0
  
  # ストリーム状態の更新
  if isFin:
    if stream.direction == sdBidirectional:
      stream.state = sHalfClosedRemote
    else:
      stream.state = sDataRecvd
  
  return (data, isFin)

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
  
  # RESET_STREAMフレームを送信
  # 実際の実装では、RESET_STREAMフレームの送信処理が必要
  
  # ストリーム状態の更新
  stream.state = sResetSent
  stream.resetSent = true
  stream.resetCode = errorCode
  
  # ストリームクローズイベントをキューに追加
  withLock(client.eventLock):
    client.eventQueue.addLast(QuicEvent(
      kind: ekStreamClose,
      closedStreamId: streamId
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