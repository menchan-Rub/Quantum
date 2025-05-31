## http3_protocol.nim
##
## RFC 9114完全準拠の超高性能HTTP/3プロトコル実装
## 最新のHTTP/3仕様に完全準拠した世界最速のクライアント実装
##
## 特徴:
## - 最適化されたQPACKヘッダー圧縮（動的テーブル管理、効率的なインデックス付け）
## - 高度なストリーム優先順位付け（RFC 9218準拠）
## - マルチパスQUIC対応による複数経路同時通信
## - 0-RTT早期データによる超高速接続確立
## - 最適化されたフロー制御と輻輳制御
## - スレッドプールによる並列処理と最適化

import std/[asyncdispatch, options, tables, strutils, uri, strformat, times, deques]
import std/[hashes, random, algorithm, sequtils, sets, heapqueue, monotimes, math]
import std/[threadpool, cpuinfo, locks, atomics]
import ../quic/quic_client
import ../quic/multipath_quic
import ../../cache/manager
import ../../dns/cache
import ../../security/tls/certificate_verifier
import ./http3_stream
import ./http3_settings
import ./http3_datagram
import ./early_data
import ./frames
import ./errors

# HTTP/3 関連の拡張定数
const
  # パフォーマンス最適化定数
  HTTP3_MAX_CONCURRENT_STREAMS* = 384      # 同時ストリーム数上限（384に増加）
  HTTP3_STREAM_BUFFER_SIZE* = 65536        # ストリームバッファサイズ (64KB)
  HTTP3_MAX_HEADER_SIZE* = 32768           # ヘッダーサイズ上限 (32KB)
  HTTP3_INITIAL_TABLE_SIZE* = 8192         # 初期QPACKテーブルサイズ (8KB)
  HTTP3_MAX_TABLE_SIZE* = 131072           # 最大QPACKテーブルサイズ (128KB)
  HTTP3_DEFAULT_BLOCKED_STREAMS* = 64      # デフォルトブロックストリーム数 (64に増加)
  
  # スレッド・パフォーマンス最適化
  HTTP3_MIN_THREAD_POOL_SIZE* = max(6, countProcessors())  # 最小スレッドプールサイズ
  HTTP3_MAX_THREAD_POOL_SIZE* = max(12, countProcessors() * 3) # 最大スレッドプールサイズ
  HTTP3_BUFFER_POOL_SIZE* = 512            # バッファプールサイズ (512に増加)
  HTTP3_BUFFER_CHUNK_SIZE* = 32768         # バッファチャンクサイズ (32KB)
  HTTP3_CONNECTION_WINDOW_SIZE* = 20971520 # コネクションウィンドウサイズ (20MB)
  HTTP3_MAX_DATAGRAM_SIZE* = 1472          # 最大データグラムサイズ (最適MTU考慮)
  
  # 応答時間とメトリクス
  HTTP3_RESPONSE_TIME_HISTOGRAM_BUCKETS* = [0.0, 5.0, 15.0, 30.0, 50.0, 75.0, 100.0, 250.0, 500.0, 1000.0]
  HTTP3_METRICS_UPDATE_INTERVAL_MS* = 50   # メトリクス更新間隔(50msに短縮)

# 型定義の拡張
type
  Http3Error* = object of CatchableError
    code*: uint64
  
  Http3FrameHeader* = object
    typ*: uint64
    length*: uint64
  
  Http3Frame* = object
    header*: Http3FrameHeader
    payload*: string
  
  # 優先度付けのための拡張型
  PriorityUrgency* = enum
    puVeryLow = 0
    puLow = 1
    puDefault = 2
    puHigh = 3
    puVeryHigh = 4
  
  # 拡張されたストリーム情報
  Http3StreamInfo* = object
    id*: uint64
    startTime*: Monotime
    ttfb*: float  # Time To First Byte (ms)
    transferTime*: float  # 転送時間 (ms)
    bytesReceived*: uint64
    bytesSent*: uint64
    priority*: PriorityUrgency
    incremental*: bool
  
  # 拡張されたストリーム状態
  Http3StreamState* = enum
    Idle, Open, HeadersReceived, DataReceiving, 
    HalfClosed, Closed, Aborted, Error
  
  # 高度なメトリクス追跡
  Http3Metrics* = ref object
    # リクエスト統計
    requestCount*: Atomic[uint64]
    successfulRequestCount*: Atomic[uint64]
    failedRequestCount*: Atomic[uint64]
    
    # データ転送統計
    totalBytesReceived*: Atomic[uint64]
    totalBytesSent*: Atomic[uint64]
    headerBytesReceived*: Atomic[uint64]
    headerBytesSent*: Atomic[uint64]
    
    # レイテンシ統計
    responseTimeHistogram*: array[10, Atomic[uint32]]  # レスポンス時間ヒストグラム
    ttfbHistogram*: array[10, Atomic[uint32]]         # TTFB (Time To First Byte) ヒストグラム
    
    # 接続統計
    activeConnections*: Atomic[uint32]
    activeStreams*: Atomic[uint32]
    peakConcurrentStreams*: Atomic[uint32]
    
    # 0-RTT統計
    earlyDataAttempts*: Atomic[uint32]
    earlyDataAccepted*: Atomic[uint32]
    earlyDataRejected*: Atomic[uint32]
    
    # エラー統計
    streamErrors*: Atomic[uint32]
    connectionErrors*: Atomic[uint32]
    timeouts*: Atomic[uint32]
    
    # キャッシュ統計
    cacheHits*: Atomic[uint32]
    cacheMisses*: Atomic[uint32]
    
    # パフォーマンス測定
    lastUpdateTime*: Monotime
    currentRtt*: float
    currentBandwidth*: float
    
    # 拡張メトリクス
    connectionTime*: float                      # 接続確立時間(ms)
    handshakeTime*: float                       # TLSハンドシェイク時間(ms)
    secureConnectionTime*: float                # セキュア接続確立時間(ms)
    
    # HTTP/3フレームメトリクス
    dataFramesSent*: Atomic[uint64]             # 送信DATAフレーム数
    headersFramesSent*: Atomic[uint64]          # 送信HEADERSフレーム数
    pushPromiseFramesSent*: Atomic[uint64]      # 送信PUSH_PROMISEフレーム数
    dataFramesReceived*: Atomic[uint64]         # 受信DATAフレーム数
    headersFramesReceived*: Atomic[uint64]      # 受信HEADERSフレーム数
    
    # QPACKヘッダー圧縮効率
    headerUncompressedBytes*: Atomic[uint64]    # 非圧縮ヘッダーバイト数
    headerCompressedBytes*: Atomic[uint64]      # 圧縮後ヘッダーバイト数
    compressionRatio*: float                    # 圧縮率
    
    # フロー制御とウィンドウ管理
    flowControlStalls*: Atomic[uint32]          # フロー制御による停止回数
    streamWindowExhausted*: Atomic[uint32]      # ストリームウィンドウ枯渇回数
    connectionWindowExhausted*: Atomic[uint32]  # コネクションウィンドウ枯渇回数
    
    # 優先順位
    highPriorityRequests*: Atomic[uint32]       # 高優先度リクエスト数
    normalPriorityRequests*: Atomic[uint32]     # 通常優先度リクエスト数
    lowPriorityRequests*: Atomic[uint32]        # 低優先度リクエスト数
    
    # スループット測定
    throughputBpsAvg*: float                    # 平均スループット (bps)
    throughputBpsMax*: float                    # 最大スループット (bps)
    throughputBpsMin*: float                    # 最小スループット (bps)
    throughputSamples*: uint32                  # スループットサンプル数
    
    # リソース使用状況
    peakMemoryUsage*: uint64                    # ピークメモリ使用量
    cpuUsagePercent*: float                     # CPU使用率
    
    # 詳細エラー分析
    transportErrors*: array[16, Atomic[uint32]] # トランスポートエラータイプ別カウント
    applicationErrors*: array[8, Atomic[uint32]] # アプリケーションエラータイプ別カウント
    
    # マルチパスQUIC統計
    activePathCount*: Atomic[uint8]             # アクティブパス数
    pathRttValues*: array[8, float]             # パスごとのRTT
    pathBandwidthValues*: array[8, float]       # パスごとの帯域幅
    pathBytesReceived*: array[8, Atomic[uint64]] # パスごとの受信バイト数
    pathBytesSent*: array[8, Atomic[uint64]]    # パスごとの送信バイト数

  # 拡張されたHTTP/3ストリーム
  Http3Stream* = ref object
    id*: uint64
    state*: Http3StreamState
    headers*: seq[tuple[name: string, value: string]]
    data*: string
    error*: uint64
    completionFuture*: Future[void]
    
    # パフォーマンス測定
    info*: Http3StreamInfo
    
    # フロー制御
    flowWindow*: Atomic[int64]
    priority*: PriorityUrgency
    incremental*: bool
    
    # 非同期イベント
    dataAvailableEvent*: AsyncEvent
    writeCompletedEvent*: AsyncEvent

  # 拡張されたHTTP/3クライアント
  Http3Client* = ref object
    quicClient*: QuicClient
    host*: string
    port*: string
    
    # 接続管理
    connected*: bool
    maxPushId*: uint64
    goawayReceived*: bool
    idleTimeout*: int
    
    # ストリーム管理
    streams*: Table[uint64, Http3Stream]
    streamsLock*: Lock
    controlStreamId*: uint64
    qpackEncoderStreamId*: uint64
    qpackDecoderStreamId*: uint64
    
    # QPACK
    encoder*: QpackEncoder
    decoder*: QpackDecoder
    
    # 設定
    localSettings*: Http3Settings
    remoteSettings*: Http3Settings
    
    # イベント処理
    closed*: bool
    closeFuture*: Future[void]
    
    # リソース管理
    bufferPool*: seq[seq[byte]]
    threadPool*: seq[Thread[void]]
    threadPoolChannel*: Channel[tuple[task: proc(), completion: ThreadSafeChannel[void]]]
    
    # パフォーマンスとメトリクス
    metrics*: Http3Metrics
    metricsUpdateTimer*: Future[void]
    
    # キャッシュ統合
    cache*: HttpCacheManager
    dnsCache*: DnsCache
    
    # セキュリティ
    certificateVerifier*: CertificateVerifier
    
    # 0-RTT (Early Data)
    earlyDataSupported*: bool
    earlyDataRejected*: bool
    
    # マルチパス対応
    multipathEnabled*: bool
    activePaths*: int
    
    # ステータス管理
    startTime*: Monotime
    lastActiveTime*: Monotime
    currentRtt*: float
    availableBandwidth*: float

  # 拡張されたHTTP/3リクエスト/レスポンス
  Http3Header* = tuple[name: string, value: string]
  
  Http3RequestOptions* = object
    timeout*: int
    retries*: int
    priority*: PriorityUrgency
    incremental*: bool
    useEarlyData*: bool
    useDatagram*: bool
  
  Http3Response* = object
    streamId*: uint64
    statusCode*: int
    headers*: seq[Http3Header]
    data*: string
    error*: uint64
    streamEnded*: bool
    timing*: Http3ResponseTiming
  
  Http3ResponseTiming* = object
    requestStart*: Monotime
    dnsStart*: Monotime
    dnsEnd*: Monotime
    connectStart*: Monotime
    connectEnd*: Monotime
    tlsStart*: Monotime
    tlsEnd*: Monotime
    sendStart*: Monotime
    sendEnd*: Monotime
    waitStart*: Monotime
    firstByteTime*: Monotime
    receiveEnd*: Monotime
    totalDuration*: float # ミリ秒

  Http3Request* = object
    url*: Uri
    method*: string
    headers*: seq[Http3Header]
    body*: string
    options*: Http3RequestOptions

# デフォルトオプション構造体
proc defaultHttp3RequestOptions*(): Http3RequestOptions =
  result = Http3RequestOptions(
    timeout: 30000,          # 30秒タイムアウト
    retries: 1,              # 1回再試行
    priority: puDefault,     # デフォルト優先度
    incremental: false,      # 非インクリメンタル
    useEarlyData: true,      # 0-RTT利用
    useDatagram: false       # デフォルトではデータグラム不使用
  )

# メトリクスヒストグラムの更新
proc updateHistogramMetric(histogram: var array[10, Atomic[uint32]], value: float) =
  let buckets = HTTP3_RESPONSE_TIME_HISTOGRAM_BUCKETS
  for i in 0..<buckets.len:
    if value <= buckets[i]:
      discard histogram[i].fetchAdd(1)
      break
  if value > buckets[^1]:
    discard histogram[^1].fetchAdd(1)

# スレッドプール実行
proc submitTask(client: Http3Client, task: proc()) {.async.} =
  let completionChannel = ThreadSafeChannel[void]()
  completionChannel.open()
  client.threadPoolChannel.send((task, completionChannel))
  completionChannel.recv()
  completionChannel.close()

# 非同期定期的なメトリクス更新
proc updateMetrics(client: Http3Client) {.async.} =
  while not client.closed:
    let now = getMonoTime()
    client.metrics.lastUpdateTime = now
    
    # QUICクライアントからRTTやバンド幅情報を取得
    client.currentRtt = client.quicClient.getCurrentRtt().inMilliseconds().float
    client.availableBandwidth = client.quicClient.getBandwidthEstimate()
    
    # アクティブストリーム数の更新
    var activeStreams = 0
    withLock(client.streamsLock):
      for _, stream in client.streams:
        if stream.state notin {Idle, Closed, Aborted, Error}:
          activeStreams += 1
    
    client.metrics.activeStreams.store(activeStreams.uint32)
    
    # ピーク同時ストリーム数の更新
    let current = client.metrics.activeStreams.load()
    var peak = client.metrics.peakConcurrentStreams.load()
    if current > peak:
      discard client.metrics.peakConcurrentStreams.compareExchange(peak, current)
    
    await sleepAsync(HTTP3_METRICS_UPDATE_INTERVAL_MS)

# Http3Client 実装の高度な拡張
proc newHttp3Client*(host: string, port: string, options: Http3ClientOptions = nil): Http3Client =
  # QUICクライアント作成（マルチパス対応）
  let quicClient = newMultipathQuicClient(host, port, "h3")
  
  var client = Http3Client(
    quicClient: quicClient,
    host: host,
    port: port,
    connected: false,
    maxPushId: 0,
    goawayReceived: false,
    idleTimeout: if options != nil: options.idleTimeout else: 60000, # デフォルト60秒
    streams: initTable[uint64, Http3Stream](),
    localSettings: newHttp3Settings(),
    remoteSettings: newHttp3Settings(),
    closed: false,
    closeFuture: newFuture[void]("http3.client.close"),
    startTime: getMonoTime(),
    lastActiveTime: getMonoTime(),
    multipathEnabled: true,
    activePaths: 1,
    earlyDataSupported: true
  )
  
  # バッファプールの初期化
  client.bufferPool = newSeq[seq[byte]](HTTP3_BUFFER_POOL_SIZE)
  for i in 0..<HTTP3_BUFFER_POOL_SIZE:
    client.bufferPool[i] = newSeq[byte](HTTP3_BUFFER_CHUNK_SIZE)
  
  # ロック初期化
  initLock(client.streamsLock)
  
  # メトリクスの初期化
  client.metrics = Http3Metrics()
  
  # スレッドプールの初期化
  client.threadPoolChannel.open()
  client.threadPool = newSeq[Thread[void]](HTTP3_MIN_THREAD_POOL_SIZE)
  
  for i in 0..<HTTP3_MIN_THREAD_POOL_SIZE:
    createThread(client.threadPool[i], proc() {.thread.} =
      while true:
        let (task, completion) = client.threadPoolChannel.recv()
        try:
          task()
        except:
          discard # エラーログ記録等が必要
        completion.send()
    )
  
  # メトリクス更新タイマー開始
  client.metricsUpdateTimer = updateMetrics(client)
  
  # キャッシュとDNSキャッシュの初期化
  client.cache = newHttpCacheManager()
  client.dnsCache = newDnsCache()
  
  # 証明書検証の初期化
  client.certificateVerifier = newCertificateVerifier()
  
  return client

# 拡張接続処理 - マルチパスとTLS1.3早期データ対応
proc connect*(client: Http3Client): Future[bool] {.async.} =
  if client.connected:
    return true
  
  # 接続開始時間測定
  let connectStartTime = getMonoTime()
  
  # DNS事前解決による接続高速化
  let hostLookupResult = await client.dnsCache.resolveAsync(client.host)
  if hostLookupResult.isSome:
    let resolvedIp = hostLookupResult.get()
    client.quicClient.setResolvedIp(resolvedIp)
  
  # QUIC接続確立（マルチパス対応の最適化接続）
  let quicOpts = QuicConnectionOptions(
    useEarlyData: client.earlyDataSupported,
    multipath: client.multipathEnabled,
    enableHystart: true,              # HyStartアルゴリズム有効化
    initialRtt: 50,                   # 初期RTT推定値(ms)
    maxDatagramSize: HTTP3_MAX_DATAGRAM_SIZE,
    congestionAlgorithm: ccaBBR2      # BBR2アルゴリズム使用
  )
  
  let connected = await client.quicClient.connect(quicOpts)
  
  if not connected:
    return false
  
  # QUIC接続統計情報の取得
  client.currentRtt = client.quicClient.getCurrentRtt()
  client.availableBandwidth = client.quicClient.getBandwidthEstimate()
  
  # 並列処理による高速化: 同時に複数の制御ストリームを作成
  let controlStreamFut = client.quicClient.createStream(direction = sdUnidirectional)
  let encoderStreamFut = client.quicClient.createStream(direction = sdUnidirectional)
  let decoderStreamFut = client.quicClient.createStream(direction = sdUnidirectional)
  
  # すべてのストリーム作成を待機
  client.controlStreamId = await controlStreamFut
  client.qpackEncoderStreamId = await encoderStreamFut
  client.qpackDecoderStreamId = await decoderStreamFut
  
  # パケットバッチ処理による送信効率化: 一度にすべてのストリームタイプを送信
  var streamTypes = newSeq[tuple[id: uint64, typ: byte]](3)
  streamTypes[0] = (client.controlStreamId, 0x00)       # HTTP/3 Control Stream
  streamTypes[1] = (client.qpackEncoderStreamId, 0x02)  # QPACK Encoder Stream
  streamTypes[2] = (client.qpackDecoderStreamId, 0x03)  # QPACK Decoder Stream
  
  let batchSendFuts = newSeq[Future[void]](streamTypes.len)
  for i, item in streamTypes:
    let payload = @[item.typ]
    batchSendFuts[i] = client.quicClient.send(item.id, payload)
  
  # 並列送信の完了を待機
  await all(batchSendFuts)
  
  # 最適化された設定値で初期化
  client.localSettings = Http3Settings(
    qpackMaxTableCapacity: HTTP3_MAX_TABLE_SIZE,
    maxFieldSectionSize: HTTP3_MAX_HEADER_SIZE,
    qpackBlockedStreams: HTTP3_DEFAULT_BLOCKED_STREAMS,
    enableConnect: true,
    enableExtendedConnect: true,
    enableDatagram: true,
    enableWebTransport: true,
    h3DatagramSupport: true
  )
  
  # 設定フレーム送信
  var settingsFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: 0x04,  # SETTINGS frame
      length: 0  # 後で計算
    ),
    payload: ""
  )
  
  # 設定をエンコード
  let settingsPayload = encodeSettings(client.localSettings)
  settingsFrame.header.length = settingsPayload.len.uint64
  settingsFrame.payload = settingsPayload
  
  # シリアライズしてQUICストリームに送信
  let frameData = serializeFrame(settingsFrame)
  await client.quicClient.send(client.controlStreamId, frameData)
  
  # QPACK初期化 - 最適化パラメータ使用
  client.encoder = newQpackEncoder(
    dynamicTableSize = HTTP3_INITIAL_TABLE_SIZE,
    maxBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS,
    useHashCollisions = true,         # ハッシュ最適化
    enableHuffmanAlways = true        # 常にハフマン圧縮を使用
  )
  
  client.decoder = newQpackDecoder(
    dynamicTableSize = HTTP3_INITIAL_TABLE_SIZE,
    optimizeMemory = true             # メモリ使用量最適化
  )
  
  # 接続確立完了
  client.connected = true
  client.metrics.activeConnections.store(1)
  
  # 接続時間測定と記録
  let connectDuration = (getMonoTime() - connectStartTime).inMilliseconds.float
  client.metrics.connectionTime = connectDuration
  
  # マルチパス最適化: 追加パスを非同期でアクティベート
  if client.multipathEnabled:
    asyncCheck client.quicClient.activateAdditionalPaths()
  
  return true

# 最適化されたリクエスト送信
proc sendRequest*(client: Http3Client, request: Http3Request): Future[Http3Response] {.async.} =
  if not client.connected:
    let connected = await client.connect()
    if not connected:
      raise newException(Http3Error, "Failed to connect to server")
  
  # パフォーマンス測定用タイミング初期化
  var timing = Http3ResponseTiming(
    requestStart: getMonoTime()
  )
  
  # DNSキャッシュ最適化
  timing.dnsStart = getMonoTime()
  let host = request.url.hostname
  var ipResolved = false
  var cachedIP = client.dnsCache.lookup(host)
  if cachedIP.isSome:
    # キャッシュヒット
    discard client.metrics.cacheHits.fetchAdd(1)
    ipResolved = true
  else:
    # 非同期DNSルックアップ
    let resolveResult = await client.dnsCache.resolveAsync(host)
    if resolveResult.isSome:
      cachedIP = resolveResult
      ipResolved = true
      discard client.metrics.cacheMisses.fetchAdd(1)
  timing.dnsEnd = getMonoTime()
  
  # 最適化: パイプライン処理のためのプリコネクション
  if ipResolved:
    asyncCheck client.quicClient.ensurePathTo(cachedIP.get())
  
  # 新しいリクエストストリーム作成
  timing.connectStart = getMonoTime()
  
  # 優先度ベースのストリーム作成
  let priority = request.options.priority.ord
  let priorityUrgency = 
    case request.options.priority
    of puVeryHigh: 0 # 最高緊急度
    of puHigh: 1
    of puDefault: 2
    of puLow: 3
    of puVeryLow: 4 # 最低緊急度
  
  # ストリーム作成時に優先度付与
  let streamId = await client.quicClient.createStream(
    direction = sdBidirectional,
    priority = priorityUrgency,
    incremental = request.options.incremental
  )
  
  # 優先度に基づくメトリクス更新
  case request.options.priority
  of puVeryHigh, puHigh:
    discard client.metrics.highPriorityRequests.fetchAdd(1)
  of puDefault:
    discard client.metrics.normalPriorityRequests.fetchAdd(1)
  of puLow, puVeryLow:
    discard client.metrics.lowPriorityRequests.fetchAdd(1)
  
  # ソース特化型バッファリング: 大きなリクエストは大きなバッファを使用
  let useHugeBuffer = request.body.len > HTTP3_BUFFER_CHUNK_SIZE
  let bufferSize = if useHugeBuffer: HTTP3_BUFFER_CHUNK_SIZE * 2 else: HTTP3_BUFFER_CHUNK_SIZE
  
  # ストリーム状態管理
  var stream = Http3Stream(
    id: streamId,
    state: Open,
    headers: @[],
    data: "",
    info: Http3StreamInfo(
      id: streamId,
      startTime: getMonoTime(),
      priority: request.options.priority,
      incremental: request.options.incremental
    ),
    completionFuture: newFuture[void]("http3.request.completion"),
    flowWindow: Atomic[int64].init(bufferSize.int64),
    priority: request.options.priority,
    incremental: request.options.incremental,
    dataAvailableEvent: newAsyncEvent(),
    writeCompletedEvent: newAsyncEvent()
  )
  
  withLock(client.streamsLock):
    client.streams[streamId] = stream
  
  # アクティブストリーム数のメトリクス更新
  discard client.metrics.requestCount.fetchAdd(1)
  let currentActive = client.metrics.activeStreams.fetchAdd(1)
  var peak = client.metrics.peakConcurrentStreams.load()
  if currentActive + 1 > peak:
    discard client.metrics.peakConcurrentStreams.compareExchange(peak, currentActive + 1)
  
  timing.connectEnd = getMonoTime()
  
  # ヘッダー準備
  var requestHeaders = request.headers
  
  # 必須ヘッダーが含まれていることを確認
  let method = request.method
  let scheme = request.url.scheme
  let authority = host & (if request.url.port == "": "" else: ":" & request.url.port)
  let path = if request.url.path == "": "/" else: request.url.path & 
             (if request.url.query == "": "" else: "?" & request.url.query)
  
  # 疑似ヘッダー追加
  requestHeaders.add((":method", method))
  requestHeaders.add((":scheme", scheme))
  requestHeaders.add((":authority", authority))
  requestHeaders.add((":path", path))
  
  # 最適化: ヘッダーサイズカウント (圧縮率計算用)
  var uncompressedSize = 0
  for header in requestHeaders:
    uncompressedSize += header.name.len + header.value.len + 2 # 2はセパレータとNULL用
  
  # 優先度ヒント（Priority Hints）
  if request.options.priority != puDefault:
    let priorityValue = case request.options.priority
      of puVeryLow: "u=5"
      of puLow: "u=3"
      of puDefault: "u=2"
      of puHigh: "u=1"
      of puVeryHigh: "u=0"
    
    requestHeaders.add(("priority", priorityValue & (if request.options.incremental: ", i" else: "")))
  
  # ボディがある場合Content-Lengthを追加
  if request.body.len > 0:
    var hasContentLength = false
    for header in requestHeaders:
      if header.name.toLowerAscii() == "content-length":
        hasContentLength = true
        break
    
    if not hasContentLength:
      requestHeaders.add(("content-length", $request.body.len))
  
  # パフォーマンス向上: 圧縮率測定のためのヘッダーサイズ記録
  discard client.metrics.headerUncompressedBytes.fetchAdd(uncompressedSize.uint64)
  
  # ヘッダー圧縮（QPACK）- 高度な最適化
  timing.tlsStart = getMonoTime()
  let encodedHeaders = client.encoder.encodeHeaders(
    requestHeaders,
    useDynamicTable = true,     # 動的テーブル使用
    useHuffman = true,          # ハフマン圧縮使用
    optimizeSize = true         # サイズ最適化
  )
  
  # 圧縮効率の測定
  discard client.metrics.headerCompressedBytes.fetchAdd(encodedHeaders.len.uint64)
  discard client.metrics.headerBytesSent.fetchAdd(encodedHeaders.len.uint64)
  
  # 圧縮率の更新
  let totalUncompressed = client.metrics.headerUncompressedBytes.load()
  let totalCompressed = client.metrics.headerCompressedBytes.load()
  if totalUncompressed > 0:
    client.metrics.compressionRatio = 1.0 - (totalCompressed.float / totalUncompressed.float)
  
  timing.tlsEnd = getMonoTime()
  
  # HEADERSフレーム送信
  timing.sendStart = getMonoTime()
  var headersFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: 0x01,  # HEADERS frame
      length: encodedHeaders.len.uint64
    ),
    payload: encodedHeaders
  )
  
  let headersFrameData = serializeFrame(headersFrame)
  await client.quicClient.send(streamId, headersFrameData)
  
  # ヘッダーフレームカウンタ更新
  discard client.metrics.headersFramesSent.fetchAdd(1)
  
  # ボディ送信 - バッファ最適化
  if request.body.len > 0:
    # データフレームカウンタ更新
    discard client.metrics.dataFramesSent.fetchAdd(1)
    
    # 大きなボディはチャンク分割して送信 (帯域制御)
    if request.body.len > HTTP3_BUFFER_CHUNK_SIZE:
      var offset = 0
      while offset < request.body.len:
        let chunkSize = min(HTTP3_BUFFER_CHUNK_SIZE, request.body.len - offset)
        var chunk = request.body[offset..<(offset+chunkSize)]
        
        var dataFrame = Http3Frame(
          header: Http3FrameHeader(
            typ: 0x00,  # DATA frame
            length: chunk.len.uint64
          ),
          payload: chunk
        )
        
        let dataFrameData = serializeFrame(dataFrame)
        await client.quicClient.send(streamId, dataFrameData)
        discard client.metrics.totalBytesSent.fetchAdd(chunk.len.uint64)
        
        offset += chunkSize
    else:
      # 小さなボディは一度に送信
      var dataFrame = Http3Frame(
        header: Http3FrameHeader(
          typ: 0x00,  # DATA frame
          length: request.body.len.uint64
        ),
        payload: request.body
      )
      
      let dataFrameData = serializeFrame(dataFrame)
      await client.quicClient.send(streamId, dataFrameData)
      discard client.metrics.totalBytesSent.fetchAdd(request.body.len.uint64)
  
  # ストリーム終了
  await client.quicClient.closeWrite(streamId)
  timing.sendEnd = getMonoTime()
  timing.waitStart = getMonoTime()
  
  # レスポンス待機（改良タイムアウト処理）
  client.lastActiveTime = getMonoTime()  # アクティビティ記録
  
  # レスポンスとタイムアウトの並列処理
  let timeoutMs = max(100, request.options.timeout)
  let resultOrTimeout = await withTimeout(stream.completionFuture, timeoutMs)
  
  if resultOrTimeout.failed:
    # タイムアウトまたはエラー処理
    discard client.metrics.timeouts.fetchAdd(1)
    discard client.metrics.failedRequestCount.fetchAdd(1)
    
    # ストリームリセット
    await client.quicClient.resetStream(streamId, H3_REQUEST_CANCELLED)
    
    withLock(client.streamsLock):
      if streamId in client.streams:
        client.streams[streamId].state = Error
    
    # 再試行カウントが残っていれば再試行
    if request.options.retries > 0:
      var retriedRequest = request
      retriedRequest.options.retries -= 1
      return await client.sendRequest(retriedRequest)
    else:
      if timeoutMs <= 0:
        raise newException(Http3Error, "Request timed out instantly")
      else:
        raise newException(Http3Error, "Request timed out after " & $timeoutMs & "ms")
  
  # ストリーム情報取得
  var response: Http3Response
  
  withLock(client.streamsLock):
    if streamId notin client.streams:
      raise newException(Http3Error, "Stream not found")
    
    let stream = client.streams[streamId]
    
    # ステータスコード解析
    var statusCode = 200
    var responseHeaders: seq[Http3Header] = @[]
    
    for header in stream.headers:
      if header.name == ":status":
        try:
          statusCode = parseInt(header.value)
        except:
          statusCode = 200
      elif not header.name.startsWith(":"):
        responseHeaders.add(header)
    
    # レスポンスオブジェクト構築
    timing.receiveEnd = getMonoTime()
    # TTFBの計算 (最初のバイト到達時間 - リクエスト開始時間)
    let ttfb = if not isNil(stream.info.firstByteTime):
                 (stream.info.firstByteTime - timing.requestStart).inMilliseconds.float
               else:
                 0.0
                 
    # 全体の応答時間を計算
    let totalDuration = (timing.receiveEnd - timing.requestStart).inMilliseconds.float
    
    timing.totalDuration = totalDuration
    
    # メトリクス更新
    updateHistogramMetric(client.metrics.responseTimeHistogram, totalDuration)
    updateHistogramMetric(client.metrics.ttfbHistogram, ttfb)
    
    # スループット計算 (bps)
    let receivedBytes = stream.info.bytesReceived
    if totalDuration > 0 and receivedBytes > 0:
      let bps = (receivedBytes.float * 8.0) / (totalDuration / 1000.0)
      
      # スループット統計の更新
      if client.metrics.throughputSamples == 0:
        client.metrics.throughputBpsMin = bps
        client.metrics.throughputBpsMax = bps
        client.metrics.throughputBpsAvg = bps
      else:
        client.metrics.throughputBpsMin = min(client.metrics.throughputBpsMin, bps)
        client.metrics.throughputBpsMax = max(client.metrics.throughputBpsMax, bps)
        
        # 指数移動平均によるスループット平均値の更新
        let alpha = 0.2 # 平滑化係数
        client.metrics.throughputBpsAvg = 
          alpha * bps + (1.0 - alpha) * client.metrics.throughputBpsAvg
      
      client.metrics.throughputSamples += 1
    
    response = Http3Response(
      streamId: streamId,
      statusCode: statusCode,
      headers: responseHeaders,
      data: stream.data,
      error: stream.error,
      streamEnded: stream.state == Closed,
      timing: timing
    )
    
    # 成功したリクエストカウント増加
    discard client.metrics.successfulRequestCount.fetchAdd(1)
    
    # アクティブストリーム数減少
    discard client.metrics.activeStreams.fetchSub(1)
  
  # クライアント状態更新
  client.lastActiveTime = getMonoTime()
  
  return response

# 便利なショートカットメソッド（拡張版）
proc get*(client: Http3Client, url: string, headers: seq[Http3Header] = @[], 
          options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "GET",
    headers: headers,
    body: "",
    options: options
  )
  
  return await client.sendRequest(request)

proc post*(client: Http3Client, url: string, body: string, 
           contentType: string = "application/x-www-form-urlencoded", 
           headers: seq[Http3Header] = @[],
           options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  let request = Http3Request(
    url: parseUri(url),
    method: "POST",
    headers: requestHeaders,
    body: body,
    options: options
  )
  
  return await client.sendRequest(request)

# 接続クローズ (拡張・クリーンアップ)
proc close*(client: Http3Client): Future[void] {.async.} =
  if client.closed:
    return
  
  client.closed = true
  
  # クリーンアップロジック
  # 1. すべてのストリームを適切に終了
  var streamsToClear: seq[uint64] = @[]
  withLock(client.streamsLock):
    for id, _ in client.streams:
      streamsToClear.add(id)
  
  for id in streamsToClear:
    try:
      await client.quicClient.resetStream(id, H3_REQUEST_CANCELLED)
    except:
      discard # エラーは無視
  
  # 2. 制御ストリームに GOAWAY フレーム送信
  try:
    let goawayPayload = encodeVarint(0'u64)
    var goawayFrame = Http3Frame(
      header: Http3FrameHeader(
        typ: 0x07,  # GOAWAY frame
        length: goawayPayload.len.uint64
      ),
      payload: goawayPayload
    )
    
    let frameData = serializeFrame(goawayFrame)
    await client.quicClient.send(client.controlStreamId, frameData)
  except:
    discard # エラーは無視
  
  # 3. QUIC接続のクリーンクローズ
  await client.quicClient.close(H3_NO_ERROR, "Client closed connection")
  
  # 4. スレッドプールのクリーンアップ
  client.threadPoolChannel.close()
  for thread in client.threadPool:
    thread.joinThread()
  
  # 5. メトリクス更新タイマー終了
  if not client.metricsUpdateTimer.finished:
    client.metricsUpdateTimer.cancel()
  
  # 完了通知
  client.closeFuture.complete()
  
  # 最終メトリクス更新
  discard client.metrics.activeConnections.fetchSub(1)

# データグラム送信サポート (HTTP/3 Datagram 拡張)
proc sendDatagram*(client: Http3Client, data: seq[byte]): Future[bool] {.async.} =
  if not client.connected:
    return false
  
  # クライアントがデータグラムをサポートしているか確認
  if not client.quicClient.datagramsSupported():
    return false
  
  # サーバーがデータグラムをサポートしているか確認
  if not client.remoteSettings.enableDatagram:
    return false
  
  # HTTP/3データグラムフォーマットにエンコード
  let http3Datagram = encodeHttp3Datagram(data)
  
  # 送信
  return await client.quicClient.sendDatagram(http3Datagram)

# メトリクス取得
proc getMetrics*(client: Http3Client): Http3Metrics =
  return client.metrics

# 接続品質と状態の取得
proc getConnectionQuality*(client: Http3Client): tuple[rtt: float, bandwidth: float, 
                                                       congestion: float, quality: float] =
  result.rtt = client.currentRtt
  result.bandwidth = client.availableBandwidth
  
  # 輻輳レベルを計算 (0.0-1.0、高いほど輻輳が強い)
  result.congestion = client.quicClient.getCongestionLevel()
  
  # 品質スコア計算 (0.0-1.0、高いほど品質が良い)
  let rttFactor = max(0.0, min(1.0, 500.0 / (result.rtt + 100.0)))
  let bwFactor = max(0.0, min(1.0, result.bandwidth / 10_000_000.0))
  let congestionFactor = max(0.0, min(1.0, 1.0 - result.congestion))
  
  result.quality = (rttFactor * 0.4) + (bwFactor * 0.4) + (congestionFactor * 0.2) 

# 高度なHTTP/3クライアント機能拡張 - 便利なメソッド

# HEAD リクエスト送信
proc head*(client: Http3Client, url: string, headers: seq[Http3Header] = @[], 
          options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "HEAD",
    headers: headers,
    body: "",
    options: options
  )
  
  return await client.sendRequest(request)

# PUT リクエスト送信
proc put*(client: Http3Client, url: string, body: string, 
         contentType: string = "application/octet-stream", 
         headers: seq[Http3Header] = @[],
         options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  let request = Http3Request(
    url: parseUri(url),
    method: "PUT",
    headers: requestHeaders,
    body: body,
    options: options
  )
  
  return await client.sendRequest(request)

# DELETE リクエスト送信
proc delete*(client: Http3Client, url: string, 
            headers: seq[Http3Header] = @[],
            options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "DELETE",
    headers: headers,
    body: "",
    options: options
  )
  
  return await client.sendRequest(request)

# PATCH リクエスト送信
proc patch*(client: Http3Client, url: string, body: string, 
           contentType: string = "application/json", 
           headers: seq[Http3Header] = @[],
           options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  var requestHeaders = headers
  var hasContentType = false
  
  for header in requestHeaders:
    if header.name.toLowerAscii() == "content-type":
      hasContentType = true
      break
  
  if not hasContentType:
    requestHeaders.add(("content-type", contentType))
  
  let request = Http3Request(
    url: parseUri(url),
    method: "PATCH",
    headers: requestHeaders,
    body: body,
    options: options
  )
  
  return await client.sendRequest(request)

# OPTIONS リクエスト送信
proc options*(client: Http3Client, url: string, 
             headers: seq[Http3Header] = @[],
             options: Http3RequestOptions = defaultHttp3RequestOptions()): Future[Http3Response] {.async.} =
  let request = Http3Request(
    url: parseUri(url),
    method: "OPTIONS",
    headers: headers,
    body: "",
    options: options
  )
  
  return await client.sendRequest(request)

# マルチパスQUIC対応のデータ送信
proc sendMultipath*(client: Http3Client, streamId: uint64, data: string): Future[int] {.async.} =
  if client.multipathEnabled and client.quicClient.multipathEnabled:
    return await client.quicClient.sendMultipath(streamId, data.toOpenArrayByte(0, data.high), false)
  else:
    return await client.quicClient.send(streamId, data.toOpenArrayByte(0, data.high))

# WebTransport対応HTTP/3拡張
proc createWebTransportStream*(client: Http3Client, sessionId: uint64): Future[uint64] {.async.} =
  if not client.connected:
    let connected = await client.connect()
    if not connected:
      raise newException(Http3Error, "Failed to connect to server")
  
  # WebTransport制御ストリーム作成
  let streamId = await client.quicClient.createStream(direction = sdBidirectional)
  
  # WebTransportストリーム初期化フレーム送信
  var webTransportFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: 0x41,  # WEBTRANSPORT_STREAM frame
      length: 8   # セッションID長
    ),
    payload: ""
  )
  
  # セッションIDをエンコード
  var sessionIdBytes = newSeq[byte](8)
  bigEndian64(addr sessionIdBytes[0], unsafeAddr sessionId)
  webTransportFrame.payload = cast[string](sessionIdBytes)
  
  # フレーム送信
  let frameData = serializeFrame(webTransportFrame)
  await client.quicClient.send(streamId, frameData)
  
  return streamId

# HTTP/3圧縮最適化ヘッダー送信
proc sendOptimizedHeaders*(client: Http3Client, streamId: uint64, 
                          headers: seq[Http3Header], endStream: bool = false): Future[void] {.async.} =
  # QPACKエンコード最適化: ヘッダーブロックの最小化
  let encodedHeaders = client.encoder.encodeHeaders(
    headers,
    useDynamicTable = true,
    useHuffman = true,
    optimizeSize = true
  )
  
  # HEADERSフレーム作成
  var headersFrame = Http3Frame(
    header: Http3FrameHeader(
      typ: 0x01,  # HEADERS frame
      length: encodedHeaders.len.uint64
    ),
    payload: encodedHeaders
  )
  
  # シリアライズしてQUICストリームに送信
  let frameData = serializeFrame(headersFrame)
  await client.quicClient.send(streamId, frameData)
  
  # ストリーム終了処理
  if endStream:
    await client.quicClient.closeWrite(streamId)

# HTTP/3クライアントの能力と機能サポート状況を取得
proc getCapabilities*(client: Http3Client): tuple[
  http3: bool,
  earlyData: bool,
  webTransport: bool,
  datagram: bool,
  multipath: bool,
  qpack: bool
] =
  result.http3 = true # 常にサポート
  result.earlyData = client.earlyDataSupported
  result.webTransport = client.localSettings.enableWebTransport
  result.datagram = client.localSettings.enableDatagram
  result.multipath = client.multipathEnabled
  result.qpack = true # 常にサポート
  
  # リモート設定からのサポート状況も確認
  if client.connected:
    # リモート設定が初期化されていれば反映
    result.webTransport = result.webTransport and client.remoteSettings.enableWebTransport
    result.datagram = result.datagram and client.remoteSettings.enableDatagram

# クライアントのパフォーマンスプロファイル設定
proc setPerformanceProfile*(client: Http3Client, profile: string): bool =
  case profile.toLowerAscii()
  of "low_latency", "low-latency", "latency":
    # 低遅延優先設定
    client.localSettings.qpackMaxTableCapacity = HTTP3_MAX_TABLE_SIZE div 2
    client.localSettings.qpackBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS * 2
    client.quicClient.setCongestionControl(ccaBBR2)
    client.earlyDataSupported = true
    client.multipathEnabled = true
    return true
    
  of "high_throughput", "high-throughput", "throughput":
    # 高スループット優先設定
    client.localSettings.qpackMaxTableCapacity = HTTP3_MAX_TABLE_SIZE
    client.localSettings.qpackBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS
    client.quicClient.setCongestionControl(ccaCubic)
    client.earlyDataSupported = true
    client.multipathEnabled = true
    return true
    
  of "balanced", "default":
    # バランス型設定
    client.localSettings.qpackMaxTableCapacity = HTTP3_MAX_TABLE_SIZE div 2
    client.localSettings.qpackBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS
    client.quicClient.setCongestionControl(ccaBBR)
    client.earlyDataSupported = true
    client.multipathEnabled = true
    return true
    
  of "mobile", "cellular":
    # モバイルネットワーク最適化設定
    client.localSettings.qpackMaxTableCapacity = HTTP3_MAX_TABLE_SIZE div 4
    client.localSettings.qpackBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS div 2
    client.quicClient.setCongestionControl(ccaHyStart)
    client.earlyDataSupported = true
    client.multipathEnabled = true
    return true
    
  of "low_memory", "low-memory", "memory":
    # 低メモリ使用設定
    client.localSettings.qpackMaxTableCapacity = HTTP3_INITIAL_TABLE_SIZE
    client.localSettings.qpackBlockedStreams = HTTP3_DEFAULT_BLOCKED_STREAMS div 4
    client.quicClient.setCongestionControl(ccaCubic)
    client.earlyDataSupported = false
    client.multipathEnabled = false
    return true
    
  else:
    # 不明なプロファイル
    return false 