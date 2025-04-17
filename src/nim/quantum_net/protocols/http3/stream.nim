## quantum_net/protocols/http3/stream.nim
## 
## HTTP/3ストリーム管理
## HTTP/3プロトコルにおけるストリームの管理と操作

import std/deques
import std/hashes
import std/options
import std/tables
import std/asyncdispatch
import atomics
import strutils
import errors
import frames

type
  Http3StreamState* = enum
    ## HTTP/3ストリームの状態
    sIdle,            ## アイドル状態
    sReservedLocal,   ## ローカル予約済み
    sReservedRemote,  ## リモート予約済み
    sOpen,            ## オープン状態
    sHalfClosedLocal, ## ローカル終了
    sHalfClosedRemote,## リモート終了
    sClosed,          ## クローズ状態
    sError            ## エラー状態

  Http3StreamDirection* = enum
    ## ストリームの方向
    sdBidirectional,  ## 双方向ストリーム
    sdUnidirectional  ## 単方向ストリーム

  Http3StreamType* = enum
    ## HTTP/3ストリームタイプ
    stControl = 0,      ## 制御ストリーム
    stPush = 1,         ## プッシュストリーム
    stQpackEncoder = 2, ## QPACKエンコーダストリーム
    stQpackDecoder = 3, ## QPACKデコーダストリーム
    stWebTransport = 0x54, ## WebTransportストリーム
    stUnknown = 0xFF    ## 未知のストリーム

  Http3StreamEvent* = enum
    ## ストリームイベント
    seHeader,         ## ヘッダー受信
    seData,           ## データ受信
    seReset,          ## リセット
    seClose,          ## クローズ
    seError           ## エラー

  Http3Stream* = ref object
    ## HTTP/3ストリーム
    id*: uint64                        ## ストリームID
    state*: Atomic[Http3StreamState]   ## ストリーム状態
    direction*: Http3StreamDirection   ## ストリーム方向
    streamType*: Http3StreamType       ## ストリームタイプ
    flowControlWindow*: Atomic[int]    ## フロー制御ウィンドウ
    priority*: int                     ## 優先度（0-255）
    
    # 送信関連
    sendBuffer*: Deque[Http3Frame]     ## 送信バッファ
    sendCompleted*: Atomic[bool]       ## 送信完了フラグ
    
    # 受信関連
    receiveBuffer*: Deque[Http3Frame]  ## 受信バッファ
    receiveCompleted*: Atomic[bool]    ## 受信完了フラグ
    
    # イベント処理
    events*: Deque[Http3StreamEvent]   ## イベントキュー
    eventPromise*: Future[Http3StreamEvent] ## イベント通知用Promise
    
    # エラー情報
    error*: Option[Http3Error]         ## エラー情報

  Http3StreamManager* = ref object
    ## ストリームマネージャー
    streams*: Table[uint64, Http3Stream] ## ストリームテーブル
    nextStreamId*: Atomic[uint64]        ## 次のストリームID
    maxConcurrentStreams*: int           ## 同時ストリーム最大数
    maxStreamData*: int                  ## ストリーム最大データ量
    activeStreams*: int                  ## アクティブストリーム数

# ストリームID範囲の定義
const
  ClientInitiatedBidirectional* = 0    ## クライアント開始双方向ストリーム（0, 4, 8, ...）
  ServerInitiatedBidirectional* = 1    ## サーバー開始双方向ストリーム（1, 5, 9, ...）
  ClientInitiatedUnidirectional* = 2   ## クライアント開始単方向ストリーム（2, 6, 10, ...）
  ServerInitiatedUnidirectional* = 3   ## サーバー開始単方向ストリーム（3, 7, 11, ...）

# ストリームユーティリティ関数

proc isClientInitiated*(streamId: uint64): bool {.inline.} =
  ## クライアント開始ストリームかどうか
  (streamId and 0x1) == 0

proc isServerInitiated*(streamId: uint64): bool {.inline.} =
  ## サーバー開始ストリームかどうか
  (streamId and 0x1) == 1

proc isBidirectional*(streamId: uint64): bool {.inline.} =
  ## 双方向ストリームかどうか
  (streamId and 0x2) == 0

proc isUnidirectional*(streamId: uint64): bool {.inline.} =
  ## 単方向ストリームかどうか
  (streamId and 0x2) == 2

proc getStreamType*(streamId: uint64): Http3StreamDirection {.inline.} =
  ## ストリームタイプを取得
  if isBidirectional(streamId):
    return sdBidirectional
  return sdUnidirectional

proc canSendData*(stream: Http3Stream): bool {.inline.} =
  ## データ送信可能かどうか
  let state = stream.state.load()
  return state == sOpen or state == sHalfClosedRemote

proc canReceiveData*(stream: Http3Stream): bool {.inline.} =
  ## データ受信可能かどうか
  let state = stream.state.load()
  return state == sOpen or state == sHalfClosedLocal

proc isRemoteClosed*(stream: Http3Stream): bool {.inline.} =
  ## リモート側が閉じているかどうか
  let state = stream.state.load()
  return state == sHalfClosedRemote or state == sClosed

proc isLocalClosed*(stream: Http3Stream): bool {.inline.} =
  ## ローカル側が閉じているかどうか
  let state = stream.state.load()
  return state == sHalfClosedLocal or state == sClosed

proc isClosed*(stream: Http3Stream): bool {.inline.} =
  ## ストリームが閉じているかどうか
  let state = stream.state.load()
  return state == sClosed

proc isError*(stream: Http3Stream): bool {.inline.} =
  ## エラー状態かどうか
  let state = stream.state.load()
  return state == sError

# ストリーム作成・管理

proc newHttp3Stream*(id: uint64, direction: Http3StreamDirection): Http3Stream =
  ## 新しいHTTP/3ストリームを作成
  result = Http3Stream(
    id: id,
    direction: direction,
    streamType: if isUnidirectional(id): stUnknown else: stControl,
    priority: 16,
    sendBuffer: initDeque[Http3Frame](),
    receiveBuffer: initDeque[Http3Frame](),
    events: initDeque[Http3StreamEvent]()
  )
  
  result.state.store(sIdle)
  result.flowControlWindow.store(65535) # デフォルトウィンドウサイズ
  result.sendCompleted.store(false)
  result.receiveCompleted.store(false)
  result.error = none(Http3Error)

proc newHttp3StreamManager*(): Http3StreamManager =
  ## 新しいストリームマネージャーを作成
  result = Http3StreamManager(
    streams: initTable[uint64, Http3Stream](),
    maxConcurrentStreams: 100,
    maxStreamData: 1024 * 1024, # 1MB
    activeStreams: 0
  )
  result.nextStreamId.store(0)

proc getStream*(manager: Http3StreamManager, id: uint64): Option[Http3Stream] =
  ## IDからストリームを取得
  if manager.streams.hasKey(id):
    return some(manager.streams[id])
  return none(Http3Stream)

proc createStream*(manager: Http3StreamManager, 
                 id: uint64 = 0, 
                 direction: Http3StreamDirection = sdBidirectional): Http3Stream =
  ## 新しいストリームを作成
  var streamId = id
  
  if streamId == 0:
    # 自動ID生成
    streamId = manager.nextStreamId.load()
    
    # クライアント側なら偶数の双方向/単方向ストリームID
    if direction == sdBidirectional:
      streamId = (streamId and not 0x3) or ClientInitiatedBidirectional
    else:
      streamId = (streamId and not 0x3) or ClientInitiatedUnidirectional
      
    discard manager.nextStreamId.fetchAdd(4)
  
  let stream = newHttp3Stream(streamId, direction)
  manager.streams[streamId] = stream
  manager.activeStreams.inc
  
  return stream

proc setStreamType*(stream: Http3Stream, streamType: Http3StreamType) =
  ## ストリームタイプを設定
  stream.streamType = streamType

proc closeStream*(stream: Http3Stream) =
  ## ストリームを閉じる
  let currentState = stream.state.load()
  
  # 状態に応じた適切な遷移
  case currentState
  of sIdle, sReservedLocal, sReservedRemote:
    stream.state.store(sClosed)
  of sOpen:
    stream.state.store(sHalfClosedLocal)
  of sHalfClosedRemote:
    stream.state.store(sClosed)
  of sHalfClosedLocal, sClosed, sError:
    discard # すでに閉じているか、エラー

  stream.sendCompleted.store(true)
  
  # イベントがある場合は通知
  if not stream.eventPromise.isNil and not stream.eventPromise.finished:
    stream.events.addLast(seClose)
    stream.eventPromise.complete(seClose)

proc resetStream*(stream: Http3Stream, error: Http3Error) =
  ## ストリームをリセット
  stream.state.store(sError)
  stream.error = some(error)
  stream.sendCompleted.store(true)
  stream.receiveCompleted.store(true)
  
  # イベントがある場合は通知
  if not stream.eventPromise.isNil and not stream.eventPromise.finished:
    stream.events.addLast(seReset)
    stream.eventPromise.complete(seReset)

proc removeStream*(manager: Http3StreamManager, id: uint64) =
  ## ストリームを削除
  if manager.streams.hasKey(id):
    manager.streams.del(id)
    manager.activeStreams.dec

# フレーム送受信

proc queueFrame*(stream: Http3Stream, frame: Http3Frame) =
  ## フレームを送信キューに追加
  if stream.isLocalClosed():
    return
    
  stream.sendBuffer.addLast(frame)

proc sendHeaders*(stream: Http3Stream, headerBlock: seq[byte]) =
  ## ヘッダーを送信
  if not stream.canSendData():
    return
    
  let frame = newHeadersFrame(headerBlock)
  stream.queueFrame(frame)

proc sendData*(stream: Http3Stream, data: seq[byte]) =
  ## データを送信
  if not stream.canSendData():
    return
    
  let frame = newDataFrame(data)
  stream.queueFrame(frame)

proc sendGoaway*(stream: Http3Stream, lastStreamId: uint64) =
  ## GOAWAYフレームを送信
  let frame = newGoawayFrame(lastStreamId)
  stream.queueFrame(frame)

proc receiveFrame*(stream: Http3Stream, frame: Http3Frame) =
  ## フレームを受信
  if stream.isRemoteClosed():
    return
    
  # フレームを受信バッファに追加
  stream.receiveBuffer.addLast(frame)
  
  # フレームタイプに応じたイベント通知
  var event: Http3StreamEvent
  
  case frame.frameType
  of ftHeaders:
    event = seHeader
  of ftData:
    event = seData
  else:
    return
  
  # イベントキューに追加
  stream.events.addLast(event)
  
  # イベント通知
  if not stream.eventPromise.isNil and not stream.eventPromise.finished:
    stream.eventPromise.complete(event)

proc nextFrame*(stream: Http3Stream): Option[Http3Frame] =
  ## 次の送信フレームを取得
  if stream.sendBuffer.len == 0:
    return none(Http3Frame)
    
  return some(stream.sendBuffer.popFirst())

proc peekFrame*(stream: Http3Stream): Option[Http3Frame] =
  ## 次の送信フレームを覗き見
  if stream.sendBuffer.len == 0:
    return none(Http3Frame)
    
  return some(stream.sendBuffer[0])

proc hasFramesToSend*(stream: Http3Stream): bool =
  ## 送信すべきフレームがあるか確認
  result = stream.sendBuffer.len > 0

proc getNextEvent*(stream: Http3Stream): Future[Http3StreamEvent] =
  ## 次のイベントを非同期で取得
  if stream.events.len > 0:
    let event = stream.events.popFirst()
    return newFuture[Http3StreamEvent]().complete(event)
    
  # イベントがない場合は新しいPromiseを作成
  stream.eventPromise = newFuture[Http3StreamEvent]("Http3Stream.getNextEvent")
  return stream.eventPromise

proc readHeaders*(stream: Http3Stream): Option[seq[byte]] =
  ## ヘッダーブロックを読み込み
  for i in 0..<stream.receiveBuffer.len:
    let frame = stream.receiveBuffer[i]
    if frame.frameType == ftHeaders:
      let headersFrame = HeadersFrame(stream.receiveBuffer.popAt(i))
      return some(headersFrame.headerBlock)
      
  return none(seq[byte])

proc readData*(stream: Http3Stream): Option[seq[byte]] =
  ## データを読み込み
  for i in 0..<stream.receiveBuffer.len:
    let frame = stream.receiveBuffer[i]
    if frame.frameType == ftData:
      let dataFrame = DataFrame(stream.receiveBuffer.popAt(i))
      return some(dataFrame.data)
      
  return none(seq[byte])

proc readAllData*(stream: Http3Stream): seq[byte] =
  ## すべてのデータを読み込み
  result = @[]
  
  var i = 0
  while i < stream.receiveBuffer.len:
    let frame = stream.receiveBuffer[i]
    if frame.frameType == ftData:
      let dataFrame = DataFrame(stream.receiveBuffer.popAt(i))
      result.add(dataFrame.data)
    else:
      i.inc
      
  return result

# ストリームの文字列表現

proc `$`*(state: Http3StreamState): string =
  ## ストリーム状態の文字列表現
  case state
  of sIdle: "Idle"
  of sReservedLocal: "Reserved (Local)"
  of sReservedRemote: "Reserved (Remote)"
  of sOpen: "Open"
  of sHalfClosedLocal: "Half-Closed (Local)"
  of sHalfClosedRemote: "Half-Closed (Remote)"
  of sClosed: "Closed"
  of sError: "Error"

proc `$`*(direction: Http3StreamDirection): string =
  ## ストリーム方向の文字列表現
  case direction
  of sdBidirectional: "Bidirectional"
  of sdUnidirectional: "Unidirectional"

proc `$`*(streamType: Http3StreamType): string =
  ## ストリームタイプの文字列表現
  case streamType
  of stControl: "Control"
  of stPush: "Push"
  of stQpackEncoder: "QPACK Encoder"
  of stQpackDecoder: "QPACK Decoder"
  of stWebTransport: "WebTransport"
  of stUnknown: "Unknown"

proc `$`*(event: Http3StreamEvent): string =
  ## ストリームイベントの文字列表現
  case event
  of seHeader: "Header"
  of seData: "Data"
  of seReset: "Reset"
  of seClose: "Close"
  of seError: "Error"

proc `$`*(stream: Http3Stream): string =
  ## ストリームの文字列表現
  let state = stream.state.load()
  result = "HTTP/3 Stream #" & $stream.id & " (" & $stream.direction & ", " & $state & ")"
  
  if stream.streamType != stUnknown:
    result &= " [" & $stream.streamType & "]"
    
  if state == sError and stream.error.isSome:
    result &= " - " & $stream.error.get()

# ストリームマネージャーの文字列表現

proc `$`*(manager: Http3StreamManager): string =
  ## ストリームマネージャーの文字列表現
  let nextId = manager.nextStreamId.load()
  result = "HTTP/3 Stream Manager\n"
  result &= "  Active Streams: " & $manager.activeStreams & " / " & $manager.maxConcurrentStreams & "\n"
  result &= "  Next Stream ID: " & $nextId & "\n"
  result &= "  Streams:"
  
  if manager.streams.len == 0:
    result &= " <none>"
  else:
    result &= "\n"
    for id, stream in manager.streams:
      result &= "    " & $stream & "\n"