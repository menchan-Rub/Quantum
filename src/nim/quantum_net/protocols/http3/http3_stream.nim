# HTTP/3ストリーム管理モジュール
#
# HTTP/3ストリームの状態管理と操作を提供します。
# RFC 9114に準拠した実装です。

import std/[asyncdispatch, options, tables, strutils, strformat, times, deques]
import std/[sequtils, sugar, hashes, sets, random, logging]
import ../quic/quic_client
import ../quic/quic_types
import ../quic/quic_stream
import ../../utils/varint
import ../../utils/binary
import ../../utils/flow_control
import ../../compression/qpack/qpack_encoder
import ../../compression/qpack/qpack_decoder
import ../http/http_types

type
  Http3StreamType* = enum
    stControl        # 制御ストリーム
    stPush           # プッシュストリーム
    stQpackEncoder   # QPACK エンコーダーストリーム
    stQpackDecoder   # QPACK デコーダーストリーム
    stRequest        # リクエストストリーム
    stBidirectional  # 双方向ストリーム
    stUnidirectional # 単方向ストリーム (サーバから)
    stUnknown        # 未知のストリームタイプ

  Http3StreamState* = enum
    ssIdle           # アイドル状態
    ssOpen           # オープン
    ssLocalClosed    # ローカル側が閉じた
    ssRemoteClosed   # リモート側が閉じた
    ssClosed         # 完全に閉じた
    ssReset          # リセットされた
    ssError          # エラー状態
    ssHalfClosed     # 半閉状態（新規追加）
    ssDraining       # ドレイン中（新規追加）

  PriorityLevel* = enum
    plUrgent         # 緊急（スクリプト、CSS等）
    plHigh           # 高（重要なリソース）
    plNormal         # 通常（画像等）
    plLow            # 低（非表示コンテンツ等）
    plBackground     # バックグラウンド（事前読込等）

  Http3Stream* = ref object
    id*: uint64                    # ストリームID
    streamType*: Http3StreamType   # ストリームタイプ
    state*: Http3StreamState       # 状態
    quicStream*: QuicStream        # 基盤となるQUICストリーム
    receivedData*: Deque[string]   # 受信データバッファ
    receiveCompleteFuture*: Future[void] # 受信完了Future
    requestHeaders*: Option[seq[HttpHeader]] # リクエストヘッダー
    responseHeaders*: Option[seq[HttpHeader]] # レスポンスヘッダー
    responseTrailers*: Option[seq[HttpHeader]] # レスポンストレーラー
    reset*: bool                   # リセットフラグ
    resetCode*: Option[uint64]     # リセットコード
    flowController*: FlowController # フロー制御
    creationTime*: Time            # 作成時間
    lastActivityTime*: Time        # 最後のアクティビティ時間
    pendingBytes*: int             # 送信待ちバイト数
    receivedBytes*: int            # 受信済みバイト数
    sentBytes*: int                # 送信済みバイト数
    priorityLevel*: PriorityLevel  # 優先度レベル
    priorityWeight*: int           # 優先度重み
    priorityDependency*: Option[uint64] # 優先度依存
    priorityExclusive*: bool       # 優先度排他フラグ
    completionFuture*: Future[void] # 完了Future
    error*: Option[string]         # エラーメッセージ
    metrics*: Http3StreamMetrics   # メトリクス
    dataAvailableEvent*: AsyncEvent # データ到着通知イベント
    activeDataProcessing*: bool    # データ処理中フラグ
    streamTimeout*: int            # ストリームタイムアウト(ms)

  Http3StreamMetrics* = object
    firstByteReceived*: Option[MonoTime] # 最初のバイト受信時間
    headersReceived*: Option[MonoTime]   # ヘッダー受信時間
    firstByteTime*: Option[int64]        # 最初のバイトまでの時間(ms)
    headerCompleteTime*: Option[int64]   # ヘッダー完了までの時間(ms)
    totalTransferTime*: Option[int64]    # 合計転送時間(ms)
    transferRate*: Option[float]         # 転送レート(バイト/秒)
    compressionRatio*: Option[float]     # 圧縮率（新規追加）
    processingTime*: Option[int64]       # 処理時間(ms)（新規追加）
    waitingTime*: Option[int64]          # 待ち時間(ms)（新規追加）
    retransmissions*: int                # 再送回数（新規追加）
    flowControlBlocked*: int             # フロー制御によるブロック回数（新規追加）

  Http3StreamManager* = ref object
    streams*: Table[uint64, Http3Stream] # ストリームテーブル
    controlStreamId*: Option[uint64]    # 制御ストリームID
    qpackEncoderStreamId*: Option[uint64] # QPACKエンコーダーストリームID
    qpackDecoderStreamId*: Option[uint64] # QPACKデコーダーストリームID
    nextStreamId*: uint64             # 次のストリームID
    qpackEncoder*: QpackEncoder       # QPACKエンコーダー
    qpackDecoder*: QpackDecoder       # QPACKデコーダー
    flowControlLimit*: uint64         # フロー制御制限
    maxConcurrentStreams*: uint64     # 最大同時ストリーム数
    activeStreams*: int               # アクティブストリーム数
    logger*: Logger                   # ロガー
    priorityManager*: PriorityManager # 優先度管理（新規追加）
    idleTimeout*: int                 # アイドルタイムアウト(秒)

  PriorityManager* = ref object
    streamPriorities*: Table[uint64, int] # ストリーム優先度
    priorityGroups*: array[PriorityLevel, seq[uint64]] # 優先度グループ
    urgentStreams*: HashSet[uint64]   # 緊急ストリーム

const
  # HTTP/3 ストリームタイプの識別子
  STREAM_TYPE_CONTROL = 0x00
  STREAM_TYPE_PUSH = 0x01
  STREAM_TYPE_QPACK_ENCODER = 0x02
  STREAM_TYPE_QPACK_DECODER = 0x03

  # HTTP/3 フレームタイプ
  H3_FRAME_DATA = 0x00
  H3_FRAME_HEADERS = 0x01
  H3_FRAME_CANCEL_PUSH = 0x03
  H3_FRAME_SETTINGS = 0x04
  H3_FRAME_PUSH_PROMISE = 0x05
  H3_FRAME_GOAWAY = 0x07
  H3_FRAME_MAX_PUSH_ID = 0x0D
  H3_FRAME_UNKNOWN = 0xFF

  # 制御ストリームのバッファサイズ
  CONTROL_STREAM_BUFFER_SIZE = 65536

  # デフォルトのフロー制御ウィンドウサイズ
  DEFAULT_FLOW_CONTROL_WINDOW = 16777216 # 16MB

  # デフォルトの優先度重み
  DEFAULT_PRIORITY_WEIGHT = 16

# 優先度管理機能
proc newPriorityManager*(): PriorityManager =
  result = PriorityManager(
    streamPriorities: initTable[uint64, int](),
    urgentStreams: initHashSet[uint64]()
  )
  # 優先度グループの初期化
  for level in PriorityLevel:
    result.priorityGroups[level] = @[]

# ストリームの優先度を設定
proc setPriority*(manager: PriorityManager, streamId: uint64, level: PriorityLevel, weight: int = DEFAULT_PRIORITY_WEIGHT) =
  # 以前のグループから削除（存在する場合）
  for levelIdx in PriorityLevel:
    let idx = manager.priorityGroups[levelIdx].find(streamId)
    if idx >= 0:
      manager.priorityGroups[levelIdx].delete(idx)
  
  # 新しいグループに追加
  manager.priorityGroups[level].add(streamId)
  manager.streamPriorities[streamId] = weight
  
  # 緊急ストリームの場合は特別なセットにも追加
  if level == plUrgent:
    manager.urgentStreams.incl(streamId)
  else:
    manager.urgentStreams.excl(streamId)

# 次に処理すべきストリームを取得（優先度に基づく）
proc getNextStreamId*(manager: PriorityManager): Option[uint64] =
  # 緊急ストリームが最優先
  if manager.urgentStreams.len > 0:
    return some(manager.urgentStreams.toSeq[0])
  
  # 優先度の高いレベルから順に確認
  for level in PriorityLevel:
    if manager.priorityGroups[level].len > 0:
      # 同じレベル内では重みの高いものを優先
      var highestWeightStreamId = manager.priorityGroups[level][0]
      var highestWeight = 0
      
      if manager.streamPriorities.hasKey(highestWeightStreamId):
        highestWeight = manager.streamPriorities[highestWeightStreamId]
      
      for id in manager.priorityGroups[level]:
        if manager.streamPriorities.hasKey(id) and manager.streamPriorities[id] > highestWeight:
          highestWeight = manager.streamPriorities[id]
          highestWeightStreamId = id
      
      return some(highestWeightStreamId)
  
  return none[uint64]()

# 高速なストリームIDからストリームタイプの検出
proc detectStreamType*(streamId: uint64): Http3StreamType {.inline.} =
  # RFC 9114に基づくストリームタイプの検出（ビット演算で高速化）
  let streamIdMod4 = streamId and 0x3
  
  case streamIdMod4
  of 0: return stRequest         # クライアント開始リクエスト
  of 1: return stBidirectional   # 将来のための双方向ストリーム
  of 2: return stUnidirectional  # サーバ主導の単方向ストリーム
  of 3: return stPush            # サーバ主導のプッシュストリーム
  else: return stUnknown         # 到達しないはず

# 新しいHTTP/3ストリームの作成（パフォーマンス最適化版）
proc newHttp3Stream*(quicStream: QuicStream, streamType: Http3StreamType = stUnknown): Http3Stream =
  let now = getMonoTime()
  result = Http3Stream(
    id: quicStream.id,
    streamType: streamType,
    state: ssIdle,
    quicStream: quicStream,
    receivedData: initDeque[string](),
    requestHeaders: none[seq[HttpHeader]](),
    responseHeaders: none[seq[HttpHeader]](),
    responseTrailers: none[seq[HttpHeader]](),
    reset: false,
    resetCode: none[uint64](),
    flowController: newFlowController(DEFAULT_FLOW_CONTROL_WINDOW),
    creationTime: getTime(),
    lastActivityTime: getTime(),
    pendingBytes: 0,
    receivedBytes: 0,
    sentBytes: 0,
    priorityLevel: plNormal,
    priorityWeight: DEFAULT_PRIORITY_WEIGHT,
    priorityDependency: none[uint64](),
    priorityExclusive: false,
    error: none[string](),
    metrics: Http3StreamMetrics(),
    streamTimeout: 30000,  # デフォルト30秒
    activeDataProcessing: false
  )
  
  # イベント初期化
  result.dataAvailableEvent = newAsyncEvent()
  
  # 完了Futureの初期化
  result.completionFuture = newFuture[void]("http3.stream.completion")
  result.receiveCompleteFuture = newFuture[void]("http3.stream.receive_complete")

# ストリームを閉じる（高効率実装）
proc close*(stream: Http3Stream) =
  if stream.state in {ssIdle, ssOpen, ssLocalClosed, ssRemoteClosed}:
    stream.state = ssClosed
    stream.lastActivityTime = getTime()
    
    if not stream.receiveCompleteFuture.finished:
      stream.receiveCompleteFuture.complete()
    
    if not stream.completionFuture.finished:
      stream.completionFuture.complete()
    
    # 基盤のQUICストリームも閉じる
    stream.quicStream.close()

# ストリームをリセット（高効率実装）
proc reset*(stream: Http3Stream, errorCode: uint64) =
  if stream.state != ssReset:
    stream.state = ssReset
    stream.reset = true
    stream.resetCode = some(errorCode)
    stream.lastActivityTime = getTime()
    
    # 未完了のFutureを完了させる
    if not stream.receiveCompleteFuture.finished:
      stream.receiveCompleteFuture.fail(newException(ValueError, "Stream reset with code: " & $errorCode))
    
    if not stream.completionFuture.finished:
      stream.completionFuture.fail(newException(ValueError, "Stream reset with code: " & $errorCode))
    
    # QUICストリームをリセット
    stream.quicStream.reset(errorCode)

# エラー状態に設定
proc setError*(stream: Http3Stream, errorMessage: string) =
  stream.state = ssError
  stream.error = some(errorMessage)
  stream.lastActivityTime = getTime()
  
  if not stream.completionFuture.finished:
    stream.completionFuture.fail(newException(ValueError, errorMessage))

# 優先度の設定
proc setPriority*(stream: Http3Stream, level: PriorityLevel, weight: int = 16,
                dependency: Option[uint64] = none[uint64](), exclusive: bool = false) =
  stream.priorityLevel = level
  stream.priorityWeight = weight
  stream.priorityDependency = dependency
  stream.priorityExclusive = exclusive

# データを高効率送信（最適化版）
proc sendData*(stream: Http3Stream, data: string): Future[void] {.async.} =
  # ストリームが送信可能な状態か確認
  if stream.state notin {ssIdle, ssOpen, ssRemoteClosed}:
    raise newException(ValueError, "Stream not in sendable state")
  
  stream.lastActivityTime = getTime()
  
  # フレームヘッダーの構築（DATA フレーム）
  let frameHeader = encodeVarInt(H3_FRAME_DATA) & encodeVarInt(uint64(data.len))
  
  # フレームヘッダーとデータを送信（バッファリング最適化）
  if data.len > 1024 and hasMethod(stream.quicStream, "writeOptimized"):
    # 大きなデータはゼロコピー最適化を使用
    await stream.quicStream.writeOptimized(frameHeader, data)
  else:
    # 小さなデータは通常の送信
    await stream.quicStream.write(frameHeader & data)
  
  # メトリクス更新
  stream.sentBytes += frameHeader.len + data.len
  
  # ストリーム状態の更新
  if stream.state == ssIdle:
    stream.state = ssOpen

# ヘッダーを送信（最適化版）
proc sendHeaders*(stream: Http3Stream, headers: seq[HttpHeader], 
                  encoder: QpackEncoder, endStream: bool = false): Future[void] {.async.} =
  if stream.state notin {ssIdle, ssOpen, ssRemoteClosed}:
    raise newException(ValueError, "Stream not in sendable state")
  
  stream.lastActivityTime = getTime()
  
  # QPACKを使用してヘッダーをエンコード（高速圧縮設定）
  let startTime = getMonoTime()
  let encodedHeaders = encoder.encodeHeaders(headers)
  let endTime = getMonoTime()
  
  # 処理時間の記録
  stream.metrics.processingTime = some((endTime - startTime).inMilliseconds)
  
  # 圧縮率の計算
  var uncompressedSize = 0
  for h in headers:
    uncompressedSize += h.name.len + h.value.len + 2
  
  if uncompressedSize > 0:
    stream.metrics.compressionRatio = some(float(encodedHeaders.len) / float(uncompressedSize))
  
  # フレームヘッダーの構築（HEADERS フレーム）
  let frameHeader = encodeVarInt(H3_FRAME_HEADERS) & encodeVarInt(uint64(encodedHeaders.len))
  
  # フレームヘッダーとエンコードされたヘッダーを送信
  await stream.quicStream.write(frameHeader & encodedHeaders)
  
  # メトリクス更新
  stream.sentBytes += frameHeader.len + encodedHeaders.len
  
  # ストリーム状態の更新
  if stream.state == ssIdle:
    stream.state = ssOpen
  
  # ストリームを閉じる場合
  if endStream:
    await stream.quicStream.shutdown()
    
    if stream.state == ssOpen:
      stream.state = ssLocalClosed
    elif stream.state == ssRemoteClosed:
      stream.state = ssClosed

# 高効率データ受信（非同期イベント活用）
proc receiveData*(stream: Http3Stream): Future[tuple[data: string, fin: bool]] {.async.} =
  if stream.state notin {ssIdle, ssOpen, ssLocalClosed}:
    return ("", true)
  
  stream.lastActivityTime = getTime()
  
  # 受信キューからデータを取得（既に受信済みデータがあれば）
  if stream.receivedData.len > 0:
    let data = stream.receivedData.popFirst()
    return (data, false)
  
  # バックグラウンドデータ処理が動いていなければ開始
  if not stream.activeDataProcessing:
    stream.activeDataProcessing = true
    asyncCheck stream.backgroundDataProcessing()
  
  # データが来るまで待機（タイムアウト付き）
  let waitTime = stream.streamTimeout
  let timeoutFut = sleepAsync(waitTime)
  let waitResult = await stream.dataAvailableEvent.wait() or timeoutFut
  
  if waitResult == timeoutFut:
    # タイムアウト発生
    return ("", false)
  
  # データが届いていれば取得
  if stream.receivedData.len > 0:
    let data = stream.receivedData.popFirst()
    return (data, false)
  
  # ストリーム終了確認
  if stream.quicStream.isFinReceived():
    if stream.state == ssOpen:
      stream.state = ssRemoteClosed
    elif stream.state == ssLocalClosed:
      stream.state = ssClosed
    
    # 受信完了Futureを完了
    if not stream.receiveCompleteFuture.finished:
      stream.receiveCompleteFuture.complete()
    
    return ("", true)
  
  # データがまだない（通常はここには来ないはず）
  return ("", false)

# バックグラウンドデータ処理（効率化）
proc backgroundDataProcessing(stream: Http3Stream): Future[void] {.async.} =
  try:
    while not stream.quicStream.isFinReceived() and 
          stream.state notin {ssClosed, ssReset, ssError}:
      # QUICストリームからデータを読み取り
      let (data, fin) = await stream.quicStream.read()
      
      if data.len > 0:
        # 最初のバイト受信時間を記録
        if stream.metrics.firstByteReceived.isNone:
          stream.metrics.firstByteReceived = some(getMonoTime())
          stream.metrics.firstByteTime = some((getMonoTime() - stream.creationTime.toMonoTime()).inMilliseconds)
        
        stream.receivedBytes += data.len
        stream.receivedData.addLast(data)
        
        # データ到着を通知
        stream.dataAvailableEvent.fire()
      
      if fin:
        break
    
    # ストリーム状態の更新
    if stream.quicStream.isFinReceived():
      if stream.state == ssOpen:
        stream.state = ssRemoteClosed
      elif stream.state == ssLocalClosed:
        stream.state = ssClosed
      
      # 受信完了Futureを完了
      if not stream.receiveCompleteFuture.finished:
        stream.receiveCompleteFuture.complete()
    
    # 処理完了
    stream.activeDataProcessing = false
  except:
    stream.activeDataProcessing = false
    stream.setError("Data processing error: " & getCurrentExceptionMsg())
    
    # エラー発生時もイベント通知
    stream.dataAvailableEvent.fire()

# レスポンスボディを取得（利便性メソッド）
proc getResponseBody*(stream: Http3Stream): Future[string] {.async.} =
  result = ""
  var allDone = false
  
  while not allDone:
    let (data, fin) = await stream.receiveData()
    result.add(data)
    allDone = fin
  
  # メトリクス更新
  if stream.metrics.firstByteReceived.isSome:
    stream.metrics.totalTransferTime = some(
      (getMonoTime() - stream.metrics.firstByteReceived.get()).inMilliseconds()
    )
    
    if stream.receivedBytes > 0 and stream.metrics.totalTransferTime.isSome and 
       stream.metrics.totalTransferTime.get() > 0:
      let seconds = float(stream.metrics.totalTransferTime.get()) / 1000.0
      stream.metrics.transferRate = some(float(stream.receivedBytes) / seconds)

# ストリームタイムアウトの設定
proc setTimeout*(stream: Http3Stream, timeoutMs: int) =
  stream.streamTimeout = max(100, timeoutMs) # 最小100ms

# HTTP/3ストリームマネージャーの作成（拡張版）
proc newHttp3StreamManager*(qpackEncoder: QpackEncoder, qpackDecoder: QpackDecoder): Http3StreamManager =
  result = Http3StreamManager(
    streams: initTable[uint64, Http3Stream](),
    controlStreamId: none[uint64](),
    qpackEncoderStreamId: none[uint64](),
    qpackDecoderStreamId: none[uint64](),
    nextStreamId: 0,
    qpackEncoder: qpackEncoder,
    qpackDecoder: qpackDecoder,
    flowControlLimit: DEFAULT_FLOW_CONTROL_WINDOW,
    maxConcurrentStreams: 100,
    activeStreams: 0,
    logger: newConsoleLogger(),
    priorityManager: newPriorityManager(),
    idleTimeout: 60
  )

# 新しいリクエストストリームを作成
proc createRequestStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  if manager.activeStreams >= int(manager.maxConcurrentStreams):
    raise newException(ValueError, "Maximum concurrent streams limit reached")
  
  # 新しいQUICストリームを開く
  let quicStream = await quicClient.openStream(sdBidirectional)
  
  # HTTP/3ストリームを作成
  let stream = newHttp3Stream(quicStream, stRequest)
  
  # ストリームテーブルに追加
  manager.streams[stream.id] = stream
  inc(manager.activeStreams)
  
  return stream

# 制御ストリームを作成
proc createControlStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  if manager.controlStreamId.isSome:
    raise newException(ValueError, "Control stream already exists")
  
  # 新しいQUICストリームを開く
  let quicStream = await quicClient.openStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let stream = newHttp3Stream(quicStream, stControl)
  
  # ストリームタイプを送信
  await quicStream.write(chr(STREAM_TYPE_CONTROL))
  
  # ストリームテーブルに追加
  manager.streams[stream.id] = stream
  manager.controlStreamId = some(stream.id)
  
  return stream

# QPACKエンコーダーストリームを作成
proc createQpackEncoderStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  if manager.qpackEncoderStreamId.isSome:
    raise newException(ValueError, "QPACK encoder stream already exists")
  
  # 新しいQUICストリームを開く
  let quicStream = await quicClient.openStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let stream = newHttp3Stream(quicStream, stQpackEncoder)
  
  # ストリームタイプを送信
  await quicStream.write(chr(STREAM_TYPE_QPACK_ENCODER))
  
  # ストリームテーブルに追加
  manager.streams[stream.id] = stream
  manager.qpackEncoderStreamId = some(stream.id)
  
  return stream

# QPACKデコーダーストリームを作成
proc createQpackDecoderStream*(manager: Http3StreamManager, quicClient: QuicClient): Future[Http3Stream] {.async.} =
  if manager.qpackDecoderStreamId.isSome:
    raise newException(ValueError, "QPACK decoder stream already exists")
  
  # 新しいQUICストリームを開く
  let quicStream = await quicClient.openStream(sdUnidirectional)
  
  # HTTP/3ストリームを作成
  let stream = newHttp3Stream(quicStream, stQpackDecoder)
  
  # ストリームタイプを送信
  await quicStream.write(chr(STREAM_TYPE_QPACK_DECODER))
  
  # ストリームテーブルに追加
  manager.streams[stream.id] = stream
  manager.qpackDecoderStreamId = some(stream.id)
  
  return stream

# 受信したストリームを処理
proc handleIncomingStream*(manager: Http3StreamManager, quicStream: QuicStream): Future[Http3Stream] {.async.} =
  let streamId = quicStream.id
  
  # ストリームタイプの検出
  let initialType = detectStreamType(streamId)
  let stream = newHttp3Stream(quicStream, initialType)
  
  # ストリームテーブルに追加
  manager.streams[streamId] = stream
  
  # 単方向ストリームの場合、最初のバイトでストリームタイプを判断
  if initialType == stUnidirectional:
    # 最初のバイトを読み取り
    let (data, _) = await quicStream.read(1)
    if data.len > 0:
      let streamType = ord(data[0])
      case streamType
      of STREAM_TYPE_CONTROL:
        stream.streamType = stControl
        manager.controlStreamId = some(streamId)
      of STREAM_TYPE_PUSH:
        stream.streamType = stPush
      of STREAM_TYPE_QPACK_ENCODER:
        stream.streamType = stQpackEncoder
        manager.qpackEncoderStreamId = some(streamId)
      of STREAM_TYPE_QPACK_DECODER:
        stream.streamType = stQpackDecoder
        manager.qpackDecoderStreamId = some(streamId)
      else:
        # 未知のストリームタイプ - 無視して続行
        stream.streamType = stUnknown
  
  # ストリームの状態を更新
  stream.state = ssOpen
  inc(manager.activeStreams)
  
  return stream

# ストリームを閉じる
proc closeStream*(manager: Http3StreamManager, streamId: uint64) =
  if manager.streams.hasKey(streamId):
    let stream = manager.streams[streamId]
    stream.close()
    
    # 特殊ストリームのIDをクリア
    if manager.controlStreamId.isSome and manager.controlStreamId.get() == streamId:
      manager.controlStreamId = none[uint64]()
    
    if manager.qpackEncoderStreamId.isSome and manager.qpackEncoderStreamId.get() == streamId:
      manager.qpackEncoderStreamId = none[uint64]()
    
    if manager.qpackDecoderStreamId.isSome and manager.qpackDecoderStreamId.get() == streamId:
      manager.qpackDecoderStreamId = none[uint64]()
    
    dec(manager.activeStreams)

# ストリームをリセット
proc resetStream*(manager: Http3StreamManager, streamId: uint64, errorCode: uint64) =
  if manager.streams.hasKey(streamId):
    let stream = manager.streams[streamId]
    stream.reset(errorCode)
    
    # 特殊ストリームのIDをクリア
    if manager.controlStreamId.isSome and manager.controlStreamId.get() == streamId:
      manager.controlStreamId = none[uint64]()
    
    if manager.qpackEncoderStreamId.isSome and manager.qpackEncoderStreamId.get() == streamId:
      manager.qpackEncoderStreamId = none[uint64]()
    
    if manager.qpackDecoderStreamId.isSome and manager.qpackDecoderStreamId.get() == streamId:
      manager.qpackDecoderStreamId = none[uint64]()
    
    dec(manager.activeStreams)

# すべてのストリームを閉じる
proc closeAllStreams*(manager: Http3StreamManager) =
  for streamId, stream in manager.streams:
    stream.close()
  
  manager.streams.clear()
  manager.controlStreamId = none[uint64]()
  manager.qpackEncoderStreamId = none[uint64]()
  manager.qpackDecoderStreamId = none[uint64]()
  manager.activeStreams = 0

# アイドルストリームのクリーンアップ
proc cleanupIdleStreams*(manager: Http3StreamManager, idleTimeout: int = 60) =
  let now = getTime()
  var streamsToRemove: seq[uint64] = @[]
  
  for streamId, stream in manager.streams:
    # 特殊ストリームは削除しない
    if manager.controlStreamId.isSome and manager.controlStreamId.get() == streamId:
      continue
    
    if manager.qpackEncoderStreamId.isSome and manager.qpackEncoderStreamId.get() == streamId:
      continue
    
    if manager.qpackDecoderStreamId.isSome and manager.qpackDecoderStreamId.get() == streamId:
      continue
    
    # 閉じられたストリームのみを対象とする
    if stream.state in {ssClosed, ssReset, ssError}:
      let idleTime = now - stream.lastActivityTime
      if idleTime.inSeconds >= idleTimeout:
        streamsToRemove.add(streamId)
  
  # アイドルストリームを削除
  for streamId in streamsToRemove:
    manager.streams.del(streamId) 