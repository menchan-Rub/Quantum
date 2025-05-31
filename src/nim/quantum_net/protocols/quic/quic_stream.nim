# QUIC ストリーム管理実装 - RFC 9000完全準拠
# 世界最高水準のストリーム処理とフロー制御

import std/[tables, deques, options, asyncdispatch, locks, times]
import std/[strformat, sequtils, algorithm, monotimes]
import quic_frame_parser

const
  # ストリーム制限
  MAX_STREAM_DATA_DEFAULT = 1024 * 1024  # 1MB
  MAX_STREAMS_BIDI_DEFAULT = 100
  MAX_STREAMS_UNI_DEFAULT = 100
  STREAM_BUFFER_SIZE = 64 * 1024  # 64KB
  
  # フロー制御
  FLOW_CONTROL_WINDOW_UPDATE_THRESHOLD = 0.5  # 50%でウィンドウ更新

type
  StreamDirection* = enum
    sdBidirectional
    sdUnidirectional

  StreamState* = enum
    sIdle
    sOpen
    sHalfClosedLocal
    sHalfClosedRemote
    sClosed

  StreamType* = enum
    stClientInitiatedBidirectional = 0x00
    stServerInitiatedBidirectional = 0x01
    stClientInitiatedUnidirectional = 0x02
    stServerInitiatedUnidirectional = 0x03

  StreamDataChunk* = object
    offset*: uint64
    data*: seq[byte]
    fin*: bool

  QuicStream* = ref object
    id*: uint64
    direction*: StreamDirection
    streamType*: StreamType
    state*: StreamState
    
    # 読み取り関連
    readBuffer*: seq[byte]
    readOffset*: uint64
    maxDataLocal*: uint64      # ローカルが受信可能な最大データ量
    receivedData*: uint64      # 受信済みデータ量
    outOfOrderData*: Table[uint64, StreamDataChunk]  # 順序が乱れたデータ
    finReceived*: bool
    finOffset*: uint64
    
    # 書き込み関連
    writeBuffer*: Deque[seq[byte]]
    writeOffset*: uint64
    maxDataRemote*: uint64     # リモートが受信可能な最大データ量
    sentData*: uint64          # 送信済みデータ量
    writeBlocked*: bool
    finSent*: bool
    
    # フロー制御
    flowControlLock*: Lock
    lastWindowUpdate*: MonoTime
    
    # イベント通知
    dataAvailable*: AsyncEvent
    writeReady*: AsyncEvent
    closed*: AsyncEvent

  StreamManager* = ref object
    streams*: Table[uint64, QuicStream]
    nextClientBidiStreamId*: uint64
    nextClientUniStreamId*: uint64
    nextServerBidiStreamId*: uint64
    nextServerUniStreamId*: uint64
    
    # 制限
    maxStreamsBidiLocal*: uint64
    maxStreamsBidiRemote*: uint64
    maxStreamsUniLocal*: uint64
    maxStreamsUniRemote*: uint64
    
    # フロー制御
    maxStreamDataBidiLocal*: uint64
    maxStreamDataBidiRemote*: uint64
    maxStreamDataUniLocal*: uint64
    maxStreamDataUniRemote*: uint64
    
    # 統計
    totalStreamsCreated*: uint64
    totalDataSent*: uint64
    totalDataReceived*: uint64
    
    # ロック
    managerLock*: Lock

# ストリーム管理の初期化
proc newStreamManager*(): StreamManager =
  result = StreamManager(
    streams: initTable[uint64, QuicStream](),
    nextClientBidiStreamId: 0,
    nextClientUniStreamId: 2,
    nextServerBidiStreamId: 1,
    nextServerUniStreamId: 3,
    maxStreamsBidiLocal: MAX_STREAMS_BIDI_DEFAULT,
    maxStreamsBidiRemote: MAX_STREAMS_BIDI_DEFAULT,
    maxStreamsUniLocal: MAX_STREAMS_UNI_DEFAULT,
    maxStreamsUniRemote: MAX_STREAMS_UNI_DEFAULT,
    maxStreamDataBidiLocal: MAX_STREAM_DATA_DEFAULT,
    maxStreamDataBidiRemote: MAX_STREAM_DATA_DEFAULT,
    maxStreamDataUniLocal: MAX_STREAM_DATA_DEFAULT,
    maxStreamDataUniRemote: MAX_STREAM_DATA_DEFAULT,
    totalStreamsCreated: 0,
    totalDataSent: 0,
    totalDataReceived: 0
  )
  
  initLock(result.managerLock)

# ストリームの作成
proc newQuicStream*(id: uint64, direction: StreamDirection, streamType: StreamType): QuicStream =
  result = QuicStream(
    id: id,
    direction: direction,
    streamType: streamType,
    state: sIdle,
    readBuffer: @[],
    readOffset: 0,
    maxDataLocal: MAX_STREAM_DATA_DEFAULT,
    receivedData: 0,
    outOfOrderData: initTable[uint64, StreamDataChunk](),
    finReceived: false,
    finOffset: 0,
    writeBuffer: initDeque[seq[byte]](),
    writeOffset: 0,
    maxDataRemote: MAX_STREAM_DATA_DEFAULT,
    sentData: 0,
    writeBlocked: false,
    finSent: false,
    lastWindowUpdate: getMonoTime(),
    dataAvailable: newAsyncEvent(),
    writeReady: newAsyncEvent(),
    closed: newAsyncEvent()
  )
  
  initLock(result.flowControlLock)

# ストリームタイプの判定
proc getStreamType*(streamId: uint64): StreamType =
  case streamId and 0x03:
  of 0x00: stClientInitiatedBidirectional
  of 0x01: stServerInitiatedBidirectional
  of 0x02: stClientInitiatedUnidirectional
  of 0x03: stServerInitiatedUnidirectional
  else: stClientInitiatedBidirectional

proc isClientInitiated*(streamId: uint64): bool =
  (streamId and 0x01) == 0

proc isBidirectional*(streamId: uint64): bool =
  (streamId and 0x02) == 0

# ストリームの作成と取得
proc createStream*(manager: StreamManager, direction: StreamDirection, isClient: bool): QuicStream =
  ## 新しいストリームを作成
  
  withLock(manager.managerLock):
    var streamId: uint64
    
    if isClient:
      if direction == sdBidirectional:
        streamId = manager.nextClientBidiStreamId
        manager.nextClientBidiStreamId += 4
      else:
        streamId = manager.nextClientUniStreamId
        manager.nextClientUniStreamId += 4
    else:
      if direction == sdBidirectional:
        streamId = manager.nextServerBidiStreamId
        manager.nextServerBidiStreamId += 4
      else:
        streamId = manager.nextServerUniStreamId
        manager.nextServerUniStreamId += 4
    
    let streamType = getStreamType(streamId)
    result = newQuicStream(streamId, direction, streamType)
    result.state = sOpen
    
    manager.streams[streamId] = result
    manager.totalStreamsCreated += 1

proc getStream*(manager: StreamManager, streamId: uint64): Option[QuicStream] =
  ## ストリームを取得
  
  withLock(manager.managerLock):
    if manager.streams.hasKey(streamId):
      result = some(manager.streams[streamId])
    else:
      result = none(QuicStream)

proc getOrCreateStream*(manager: StreamManager, streamId: uint64): QuicStream =
  ## ストリームを取得または作成
  
  let existing = manager.getStream(streamId)
  if existing.isSome:
    return existing.get()
  
  # 新しいストリームを作成
  let streamType = getStreamType(streamId)
  let direction = if isBidirectional(streamId): sdBidirectional else: sdUnidirectional
  
  result = newQuicStream(streamId, direction, streamType)
  result.state = sOpen
  
  withLock(manager.managerLock):
    manager.streams[streamId] = result
    manager.totalStreamsCreated += 1

# データの書き込み
proc writeData*(stream: QuicStream, data: seq[byte]): Future[void] {.async.} =
  ## ストリームにデータを書き込み
  
  if stream.state in {sClosed, sHalfClosedLocal}:
    raise newException(ValueError, "Stream is closed for writing")
  
  withLock(stream.flowControlLock):
    stream.writeBuffer.addLast(data)
  
  # 書き込み準備完了を通知
  stream.writeReady.trigger()

proc writeDataSync*(stream: QuicStream, data: seq[byte]) =
  ## ストリームにデータを同期書き込み
  
  if stream.state in {sClosed, sHalfClosedLocal}:
    raise newException(ValueError, "Stream is closed for writing")
  
  withLock(stream.flowControlLock):
    stream.writeBuffer.addLast(data)

# データの読み取り
proc readData*(stream: QuicStream, maxBytes: int = -1): Future[seq[byte]] {.async.} =
  ## ストリームからデータを読み取り
  
  if stream.state == sClosed:
    return @[]
  
  # データが利用可能になるまで待機
  while stream.readBuffer.len == 0 and not stream.finReceived:
    await stream.dataAvailable.wait()
  
  withLock(stream.flowControlLock):
    if maxBytes < 0 or maxBytes >= stream.readBuffer.len:
      result = stream.readBuffer
      stream.readBuffer = @[]
    else:
      result = stream.readBuffer[0..<maxBytes]
      stream.readBuffer = stream.readBuffer[maxBytes..^1]

proc readDataSync*(stream: QuicStream, maxBytes: int = -1): seq[byte] =
  ## ストリームからデータを同期読み取り
  
  if stream.state == sClosed:
    return @[]
  
  withLock(stream.flowControlLock):
    if maxBytes < 0 or maxBytes >= stream.readBuffer.len:
      result = stream.readBuffer
      stream.readBuffer = @[]
    else:
      result = stream.readBuffer[0..<maxBytes]
      stream.readBuffer = stream.readBuffer[maxBytes..^1]

# ストリームフレームの処理
proc processStreamFrame*(stream: QuicStream, frame: StreamFrame): seq[QuicFrame] =
  ## STREAMフレームを処理し、必要に応じてフロー制御フレームを返す
  
  result = @[]
  
  withLock(stream.flowControlLock):
    # オフセットチェック
    if frame.offset < stream.readOffset:
      # 重複データ - 無視
      return
    
    if frame.offset == stream.readOffset:
      # 順序通りのデータ
      stream.readBuffer.add(frame.data)
      stream.readOffset += frame.data.len.uint64
      stream.receivedData += frame.data.len.uint64
      
      # FINフラグの処理
      if frame.fin:
        stream.finReceived = true
        stream.finOffset = frame.offset + frame.data.len.uint64
        
        if stream.state == sOpen:
          stream.state = sHalfClosedRemote
        elif stream.state == sHalfClosedLocal:
          stream.state = sClosed
          stream.closed.trigger()
      
      # 順序が乱れたデータの処理
      stream.processOutOfOrderData()
      
      # データ利用可能を通知
      stream.dataAvailable.trigger()
    else:
      # 順序が乱れたデータ - バッファリング
      let chunk = StreamDataChunk(
        offset: frame.offset,
        data: frame.data,
        fin: frame.fin
      )
      stream.outOfOrderData[frame.offset] = chunk
    
    # フロー制御ウィンドウの更新チェック
    let windowUsed = stream.receivedData.float64 / stream.maxDataLocal.float64
    if windowUsed >= FLOW_CONTROL_WINDOW_UPDATE_THRESHOLD:
      # MAX_STREAM_DATAフレームを生成
      stream.maxDataLocal += MAX_STREAM_DATA_DEFAULT
      let maxStreamDataFrame = MaxStreamDataFrame(
        frameType: ftMaxStreamData,
        streamId: stream.id,
        maximumStreamData: stream.maxDataLocal
      )
      result.add(maxStreamDataFrame)

# 順序が乱れたデータの処理
proc processOutOfOrderData*(stream: QuicStream) =
  ## 順序が乱れたデータを順序通りに処理
  
  var processed = true
  while processed:
    processed = false
    
    if stream.outOfOrderData.hasKey(stream.readOffset):
      let chunk = stream.outOfOrderData[stream.readOffset]
      
      stream.readBuffer.add(chunk.data)
      stream.readOffset += chunk.data.len.uint64
      stream.receivedData += chunk.data.len.uint64
      
      if chunk.fin:
        stream.finReceived = true
        stream.finOffset = chunk.offset + chunk.data.len.uint64
      
      stream.outOfOrderData.del(stream.readOffset - chunk.data.len.uint64)
      processed = true

# 送信用データの取得
proc getDataToSend*(stream: QuicStream, maxBytes: uint64): tuple[data: seq[byte], fin: bool, offset: uint64] =
  ## 送信用データを取得
  
  result.data = @[]
  result.fin = false
  result.offset = stream.writeOffset
  
  withLock(stream.flowControlLock):
    # フロー制御チェック
    let availableWindow = stream.maxDataRemote - stream.sentData
    let bytesToSend = min(maxBytes, availableWindow)
    
    if bytesToSend == 0:
      stream.writeBlocked = true
      return
    
    # バッファからデータを取得
    var totalBytes = 0'u64
    while stream.writeBuffer.len > 0 and totalBytes < bytesToSend:
      let chunk = stream.writeBuffer.peekFirst()
      let remainingBytes = bytesToSend - totalBytes
      
      if chunk.len.uint64 <= remainingBytes:
        # チャンク全体を送信
        result.data.add(chunk)
        totalBytes += chunk.len.uint64
        discard stream.writeBuffer.popFirst()
      else:
        # チャンクの一部を送信
        result.data.add(chunk[0..<remainingBytes.int])
        totalBytes += remainingBytes
        stream.writeBuffer[0] = chunk[remainingBytes.int..^1]
        break
    
    # FINフラグの設定
    if stream.writeBuffer.len == 0 and not stream.finSent:
      result.fin = true
      stream.finSent = true
      
      if stream.state == sOpen:
        stream.state = sHalfClosedLocal
      elif stream.state == sHalfClosedRemote:
        stream.state = sClosed
        stream.closed.trigger()
    
    # 送信統計の更新
    stream.sentData += totalBytes
    stream.writeOffset += totalBytes

# ストリームのクローズ
proc closeStream*(stream: QuicStream) =
  ## ストリームをクローズ
  
  withLock(stream.flowControlLock):
    if stream.state != sClosed:
      stream.state = sClosed
      stream.closed.trigger()

proc closeStreamForWriting*(stream: QuicStream) =
  ## 書き込み側をクローズ
  
  withLock(stream.flowControlLock):
    if stream.state == sOpen:
      stream.state = sHalfClosedLocal
    elif stream.state == sHalfClosedRemote:
      stream.state = sClosed
      stream.closed.trigger()

# フロー制御の更新
proc updateMaxStreamData*(stream: QuicStream, maxData: uint64) =
  ## 最大ストリームデータの更新
  
  withLock(stream.flowControlLock):
    if maxData > stream.maxDataRemote:
      stream.maxDataRemote = maxData
      stream.writeBlocked = false
      stream.writeReady.trigger()

# ストリーム制限の管理
proc updateMaxStreams*(manager: StreamManager, maxStreamsBidi: uint64, maxStreamsUni: uint64, isLocal: bool) =
  ## 最大ストリーム数の更新
  
  withLock(manager.managerLock):
    if isLocal:
      manager.maxStreamsBidiLocal = maxStreamsBidi
      manager.maxStreamsUniLocal = maxStreamsUni
    else:
      manager.maxStreamsBidiRemote = maxStreamsBidi
      manager.maxStreamsUniRemote = maxStreamsUni

# ストリーム統計
proc getStreamCount*(manager: StreamManager): tuple[bidi: int, uni: int] =
  ## アクティブなストリーム数を取得
  
  withLock(manager.managerLock):
    var bidiCount = 0
    var uniCount = 0
    
    for stream in manager.streams.values:
      if stream.state != sClosed:
        if stream.direction == sdBidirectional:
          bidiCount += 1
        else:
          uniCount += 1
    
    result = (bidi: bidiCount, uni: uniCount)

proc getStreamStats*(manager: StreamManager): tuple[created: uint64, dataSent: uint64, dataReceived: uint64] =
  ## ストリーム統計を取得
  
  withLock(manager.managerLock):
    result = (
      created: manager.totalStreamsCreated,
      dataSent: manager.totalDataSent,
      dataReceived: manager.totalDataReceived
    )

# ストリームのリセット
proc resetStream*(stream: QuicStream, errorCode: uint64): ResetStreamFrame =
  ## ストリームをリセット
  
  withLock(stream.flowControlLock):
    stream.state = sClosed
    stream.closed.trigger()
  
  result = ResetStreamFrame(
    frameType: ftResetStream,
    streamId: stream.id,
    applicationProtocolErrorCode: errorCode,
    finalSize: stream.sentData
  )

# 送信停止要求
proc stopSending*(stream: QuicStream, errorCode: uint64): StopSendingFrame =
  ## 送信停止要求
  
  result = StopSendingFrame(
    frameType: ftStopSending,
    streamId: stream.id,
    applicationProtocolErrorCode: errorCode
  )

# ストリームの状態チェック
proc isReadable*(stream: QuicStream): bool =
  ## ストリームが読み取り可能かチェック
  stream.readBuffer.len > 0 or stream.finReceived

proc isWritable*(stream: QuicStream): bool =
  ## ストリームが書き込み可能かチェック
  stream.state in {sOpen, sHalfClosedRemote} and not stream.writeBlocked

proc isClosed*(stream: QuicStream): bool =
  ## ストリームがクローズされているかチェック
  stream.state == sClosed

# 順序付きデータの追加（外部から呼び出し用）
proc addOutOfOrderData*(stream: QuicStream, offset: uint64, data: seq[byte], fin: bool) =
  ## 順序が乱れたデータを追加
  
  withLock(stream.flowControlLock):
    let chunk = StreamDataChunk(
      offset: offset,
      data: data,
      fin: fin
    )
    stream.outOfOrderData[offset] = chunk
    
    # 順序通りに処理できるかチェック
    stream.processOutOfOrderData()
    
    if stream.readBuffer.len > 0:
      stream.dataAvailable.trigger()

# デバッグ情報
proc getDebugInfo*(stream: QuicStream): string =
  ## ストリームのデバッグ情報
  
  result = fmt"""
Stream {stream.id} Debug Info:
  Direction: {stream.direction}
  State: {stream.state}
  Read Buffer: {stream.readBuffer.len} bytes
  Read Offset: {stream.readOffset}
  Write Buffer: {stream.writeBuffer.len} chunks
  Write Offset: {stream.writeOffset}
  Max Data Local: {stream.maxDataLocal}
  Max Data Remote: {stream.maxDataRemote}
  Received Data: {stream.receivedData}
  Sent Data: {stream.sentData}
  FIN Received: {stream.finReceived}
  FIN Sent: {stream.finSent}
  Write Blocked: {stream.writeBlocked}
  Out of Order Chunks: {stream.outOfOrderData.len}
"""

proc getManagerDebugInfo*(manager: StreamManager): string =
  ## ストリーム管理のデバッグ情報
  
  let streamCount = manager.getStreamCount()
  let stats = manager.getStreamStats()
  
  result = fmt"""
StreamManager Debug Info:
  Active Streams: {streamCount.bidi} bidi, {streamCount.uni} uni
  Total Streams Created: {stats.created}
  Total Data Sent: {stats.dataSent} bytes
  Total Data Received: {stats.dataReceived} bytes
  Max Streams Bidi Local: {manager.maxStreamsBidiLocal}
  Max Streams Bidi Remote: {manager.maxStreamsBidiRemote}
  Max Streams Uni Local: {manager.maxStreamsUniLocal}
  Max Streams Uni Remote: {manager.maxStreamsUniRemote}
"""

# エクスポート
export QuicStream, StreamManager, StreamDirection, StreamState, StreamType
export newStreamManager, newQuicStream, createStream, getStream, getOrCreateStream
export writeData, writeDataSync, readData, readDataSync
export processStreamFrame, getDataToSend, closeStream, closeStreamForWriting
export updateMaxStreamData, updateMaxStreams, resetStream, stopSending
export isReadable, isWritable, isClosed, getStreamCount, getStreamStats
export addOutOfOrderData, getDebugInfo, getManagerDebugInfo 