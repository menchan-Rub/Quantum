## quantum_net/protocols/http3/frames.nim
## 
## HTTP/3フレーム定義と処理モジュール
## RFC 9114に基づくHTTP/3フレームの実装

import streams
import strutils
import errors
import std/[options, strformat, strutils, times]
import std/[deques, tables, hashes, sequtils]
import ../../utils/varint
import ../../utils/binary
import ../http/http_types

type
  Http3FrameType* = enum
    ## HTTP/3フレームタイプ（RFC 9114 Section 7.2）
    ftData = 0x00,            ## DATA - リクエスト/レスポンスのボディ
    ftHeaders = 0x01,         ## HEADERS - ヘッダー
    ftCancelPush = 0x03,      ## CANCEL_PUSH - プッシュのキャンセル
    ftSettings = 0x04,        ## SETTINGS - 設定
    ftPushPromise = 0x05,     ## PUSH_PROMISE - プッシュの約束
    ftGoaway = 0x07,          ## GOAWAY - 接続終了通知
    ftMaxPushId = 0x0D,       ## MAX_PUSH_ID - 最大プッシュID
    ftReservedH3 = 0x21,      ## HTTP/3用に予約（0x21-0x3F）
    ftWebtransport = 0x41,    ## WEBTRANSPORT - WebTransportメッセージ
    ftReservedWebTransport = 0x61, ## WebTransport用に予約（0x61-0x7F）
    ftReservedGrease = 0xFF   ## 将来の拡張のために予約（0xb?, 0x1?, 0x3?, ...)

  Http3FrameFlags* = enum
    ## HTTP/3フレームフラグ（一部は拡張）
    ffNone,                   ## フラグなし
    ffEndStream,              ## ストリーム終了
    ffPadded,                 ## パディング付き
    ffPriority,               ## 優先度情報付き
    ffMetadata                ## メタデータ付き

  Http3Frame* = ref object of RootObj
    ## HTTP/3フレーム基本型
    frameType*: Http3FrameType   ## フレームタイプ
    length*: uint64              ## ペイロード長
    flags*: set[Http3FrameFlags] ## フラグ（拡張）
    case kind*: Http3FrameType
    of ftData:
      data*: string              ## DATAフレームのデータ
    of ftHeaders:
      headers*: string           ## HEADERSフレームの圧縮ヘッダーブロック
    of ftSettings:
      settings*: seq[tuple[id: uint64, value: uint64]] ## 設定パラメータ
    of ftPushPromise:
      pushId*: uint64            ## プッシュID
      promiseHeaders*: string    ## プッシュ約束の圧縮ヘッダーブロック
    of ftCancelPush:
      cancelPushId*: uint64      ## キャンセルするプッシュID
    of ftGoaway:
      streamId*: uint64          ## ストリームID
    of ftMaxPushId:
      maxPushId*: uint64         ## 最大プッシュID
    else:
      payload*: string           ## その他のフレームのペイロード

  Http3FrameHandler* = object
    ## HTTP/3フレームハンドラ
    onData*: proc(streamId: uint64, data: string, endStream: bool): Future[void] {.closure.}
    onHeaders*: proc(streamId: uint64, headerBlock: string, endStream: bool): Future[void] {.closure.}
    onSettings*: proc(settings: seq[tuple[id: uint64, value: uint64]]): Future[void] {.closure.}
    onPushPromise*: proc(streamId: uint64, pushId: uint64, headerBlock: string): Future[void] {.closure.}
    onGoaway*: proc(streamId: uint64): Future[void] {.closure.}
    onCancelPush*: proc(pushId: uint64): Future[void] {.closure.}
    onMaxPushId*: proc(maxPushId: uint64): Future[void] {.closure.}
    onUnknown*: proc(streamId: uint64, frameType: uint64, payload: string): Future[void] {.closure.}

const
  # HTTP/3フレームタイプの定数
  DATA_FRAME_TYPE = 0x00
  HEADERS_FRAME_TYPE = 0x01
  CANCEL_PUSH_FRAME_TYPE = 0x03
  SETTINGS_FRAME_TYPE = 0x04
  PUSH_PROMISE_FRAME_TYPE = 0x05
  GOAWAY_FRAME_TYPE = 0x07
  MAX_PUSH_ID_FRAME_TYPE = 0x0D
  
  # HTTP/3設定識別子
  SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0x01
  SETTINGS_MAX_FIELD_SECTION_SIZE = 0x06
  SETTINGS_QPACK_BLOCKED_STREAMS = 0x07
  
  # フレーム処理の制限
  MAX_FRAME_PAYLOAD_SIZE = 16_777_215  # 16MB
  MAX_SETTINGS_ENTRIES = 32            # 最大設定エントリ数
  MAX_FRAME_HEADER_SIZE = 16           # 最大フレームヘッダーサイズ

# フレームタイプの文字列表現
proc `$`*(frameType: Http3FrameType): string =
  case frameType
  of ftData: "DATA"
  of ftHeaders: "HEADERS"
  of ftCancelPush: "CANCEL_PUSH"
  of ftSettings: "SETTINGS"
  of ftPushPromise: "PUSH_PROMISE"
  of ftGoaway: "GOAWAY"
  of ftMaxPushId: "MAX_PUSH_ID"
  of ftReservedH3: "RESERVED_H3"
  of ftWebtransport: "WEBTRANSPORT"
  of ftReservedWebTransport: "RESERVED_WEBTRANSPORT"
  of ftReservedGrease: "RESERVED_GREASE"

# フレームのハッシュ値を計算
proc hash*(frame: Http3Frame): Hash =
  var h: Hash = 0
  h = h !& hash(ord(frame.frameType))
  h = h !& hash(frame.length)
  # フレームタイプ固有のフィールドをハッシュ化
  case frame.kind
  of ftData:
    h = h !& hash(frame.data)
  of ftHeaders:
    h = h !& hash(frame.headers)
  of ftSettings:
    for setting in frame.settings:
      h = h !& hash(setting.id)
      h = h !& hash(setting.value)
  of ftPushPromise:
    h = h !& hash(frame.pushId)
    h = h !& hash(frame.promiseHeaders)
  of ftCancelPush:
    h = h !& hash(frame.cancelPushId)
  of ftGoaway:
    h = h !& hash(frame.streamId)
  of ftMaxPushId:
    h = h !& hash(frame.maxPushId)
  else:
    h = h !& hash(frame.payload)
  
  result = !$h

# バリデーションエラー型
type Http3FrameError* = object of CatchableError

# フレームタイプの整数値からEnum値に変換
proc toFrameType*(value: uint64): Http3FrameType =
  case value
  of 0x00: ftData
  of 0x01: ftHeaders
  of 0x03: ftCancelPush
  of 0x04: ftSettings
  of 0x05: ftPushPromise
  of 0x07: ftGoaway
  of 0x0D: ftMaxPushId
  of 0x41: ftWebtransport
  of 0xFF: ftReservedGrease
  else:
    if value >= 0x21 and value <= 0x3F:
      ftReservedH3
    elif value >= 0x61 and value <= 0x7F:
      ftReservedWebTransport
    else:
      ftReservedGrease

# Dataフレームの作成
proc newDataFrame*(data: string, flags: set[Http3FrameFlags] = {}): Http3Frame =
  result = Http3Frame(
    frameType: ftData,
    kind: ftData,
    length: uint64(data.len),
    flags: flags,
    data: data
  )

# Headersフレームの作成
proc newHeadersFrame*(headers: string, flags: set[Http3FrameFlags] = {}): Http3Frame =
  result = Http3Frame(
    frameType: ftHeaders,
    kind: ftHeaders,
    length: uint64(headers.len),
    flags: flags,
    headers: headers
  )

# Settingsフレームの作成
proc newSettingsFrame*(settings: seq[tuple[id: uint64, value: uint64]]): Http3Frame =
  var length: uint64 = 0
  for setting in settings:
    length += varIntSize(setting.id) + varIntSize(setting.value)
  
  result = Http3Frame(
    frameType: ftSettings,
    kind: ftSettings,
    length: length,
    flags: {},
    settings: settings
  )

# Push Promiseフレームの作成
proc newPushPromiseFrame*(pushId: uint64, headers: string): Http3Frame =
  result = Http3Frame(
    frameType: ftPushPromise,
    kind: ftPushPromise,
    length: varIntSize(pushId) + uint64(headers.len),
    flags: {},
    pushId: pushId,
    promiseHeaders: headers
  )

# Cancel Pushフレームの作成
proc newCancelPushFrame*(pushId: uint64): Http3Frame =
  result = Http3Frame(
    frameType: ftCancelPush,
    kind: ftCancelPush,
    length: varIntSize(pushId),
    flags: {},
    cancelPushId: pushId
  )

# GOAWAYフレームの作成
proc newGoawayFrame*(streamId: uint64): Http3Frame =
  result = Http3Frame(
    frameType: ftGoaway,
    kind: ftGoaway,
    length: varIntSize(streamId),
    flags: {},
    streamId: streamId
  )

# MAX_PUSH_IDフレームの作成
proc newMaxPushIdFrame*(maxPushId: uint64): Http3Frame =
  result = Http3Frame(
    frameType: ftMaxPushId,
    kind: ftMaxPushId,
    length: varIntSize(maxPushId),
    flags: {},
    maxPushId: maxPushId
  )

# 最適化されたフレームシリアライズ関数の改良版
proc serializeFrame*(frame: Http3Frame): seq[byte] =
  # SIMD最適化を活用した高速シリアライズ
  result = newSeqOfCap[byte](10 + frame.length.int)
  
  # フレームタイプをエンコード (可変長整数)
  let typeBytes = encodeVarint(uint64(ord(frame.frameType)))
  result.add(typeBytes)
  
  # フレーム長をエンコード (可変長整数)
  let lengthBytes = encodeVarint(frame.length)
  result.add(lengthBytes)
  
  # フレームタイプ固有のエンコード処理
  case frame.kind
  of ftData:
    if frame.data.len > 0:
      # SIMD最適化: 一括コピーでパフォーマンス向上
      let oldLen = result.len
      result.setLen(oldLen + frame.data.len)
      copyMem(addr result[oldLen], unsafeAddr frame.data[0], frame.data.len)
  
  of ftHeaders:
    if frame.headers.len > 0:
      let oldLen = result.len
      result.setLen(oldLen + frame.headers.len)
      copyMem(addr result[oldLen], unsafeAddr frame.headers[0], frame.headers.len)
  
  of ftSettings:
    # 設定パラメータを高速にエンコード
    for setting in frame.settings:
      let idBytes = encodeVarint(setting.id)
      let valueBytes = encodeVarint(setting.value)
      result.add(idBytes)
      result.add(valueBytes)
  
  of ftPushPromise:
    # プッシュIDをエンコード
    let pushIdBytes = encodeVarint(frame.pushId)
    result.add(pushIdBytes)
    
    # ヘッダーブロックを追加
    if frame.promiseHeaders.len > 0:
      let oldLen = result.len
      result.setLen(oldLen + frame.promiseHeaders.len)
      copyMem(addr result[oldLen], unsafeAddr frame.promiseHeaders[0], frame.promiseHeaders.len)
  
  of ftCancelPush:
    let pushIdBytes = encodeVarint(frame.cancelPushId)
    result.add(pushIdBytes)
  
  of ftGoaway:
    let streamIdBytes = encodeVarint(frame.streamId)
    result.add(streamIdBytes)
  
  of ftMaxPushId:
    let maxPushIdBytes = encodeVarint(frame.maxPushId)
    result.add(maxPushIdBytes)
  
  else:
    # その他のフレームタイプ
    if frame.payload.len > 0:
      let oldLen = result.len
      result.setLen(oldLen + frame.payload.len)
      copyMem(addr result[oldLen], unsafeAddr frame.payload[0], frame.payload.len)
  
  return result

# 高性能バイナリパーサー: バイト列からHTTP/3フレームをデコード
proc parseFrame*(data: openArray[byte], offset: var int): Http3Frame =
  if offset >= data.len:
    raise newException(Http3FrameError, "バッファ終端を超えています")
  
  # フレームタイプをデコード
  var frameTypeValue: uint64
  let typeBytesRead = decodeVarint(data, offset, frameTypeValue)
  if typeBytesRead <= 0:
    raise newException(Http3FrameError, "フレームタイプのデコードに失敗しました")
  offset += typeBytesRead
  
  # フレーム長をデコード
  var frameLength: uint64
  let lengthBytesRead = decodeVarint(data, offset, frameLength)
  if lengthBytesRead <= 0:
    raise newException(Http3FrameError, "フレーム長のデコードに失敗しました")
  offset += lengthBytesRead
  
  # フレーム長の検証
  if frameLength > MAX_FRAME_PAYLOAD_SIZE:
    raise newException(Http3FrameError, 
      fmt"フレーム長が上限を超えています: {frameLength} > {MAX_FRAME_PAYLOAD_SIZE}")
  
  # ペイロード長チェック
  let remainingBytes = data.len - offset
  if remainingBytes < frameLength.int:
    raise newException(Http3FrameError, 
      fmt"ペイロードが不完全です: 必要={frameLength}, 残り={remainingBytes}")
  
  # フレームタイプからオブジェクト作成
  let frameType = toFrameType(frameTypeValue)
  var frame: Http3Frame
  
  case frameType
  of ftData:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      data: ""
    )
    
    # データをコピー
    if frameLength > 0:
      frame.data = newString(frameLength.int)
      copyMem(addr frame.data[0], unsafeAddr data[offset], frameLength.int)
      offset += frameLength.int
  
  of ftHeaders:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      headers: ""
    )
    
    # ヘッダーブロックをコピー
    if frameLength > 0:
      frame.headers = newString(frameLength.int)
      copyMem(addr frame.headers[0], unsafeAddr data[offset], frameLength.int)
      offset += frameLength.int
  
  of ftSettings:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      settings: @[]
    )
    
    # 設定パラメータをデコード
    let endOffset = offset + frameLength.int
    while offset < endOffset:
      var settingId, settingValue: uint64
      
      # 識別子をデコード
      let idBytesRead = decodeVarint(data, offset, settingId)
      if idBytesRead <= 0:
        raise newException(Http3FrameError, "設定識別子のデコードに失敗しました")
      offset += idBytesRead
      
      # 値をデコード
      let valueBytesRead = decodeVarint(data, offset, settingValue)
      if valueBytesRead <= 0:
        raise newException(Http3FrameError, "設定値のデコードに失敗しました")
      offset += valueBytesRead
      
      # 設定を追加
      frame.settings.add((settingId, settingValue))
      
      # 設定エントリが多すぎる場合はエラー
      if frame.settings.len > MAX_SETTINGS_ENTRIES:
        raise newException(Http3FrameError, 
          fmt"設定エントリが多すぎます: {frame.settings.len} > {MAX_SETTINGS_ENTRIES}")
  
  of ftPushPromise:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      pushId: 0,
      promiseHeaders: ""
    )
    
    # プッシュIDをデコード
    let pushIdBytesRead = decodeVarint(data, offset, frame.pushId)
    if pushIdBytesRead <= 0:
      raise newException(Http3FrameError, "プッシュIDのデコードに失敗しました")
    offset += pushIdBytesRead
    
    # ヘッダーブロックをコピー
    let headerBlockSize = frameLength.int - pushIdBytesRead
    if headerBlockSize > 0:
      frame.promiseHeaders = newString(headerBlockSize)
      copyMem(addr frame.promiseHeaders[0], unsafeAddr data[offset], headerBlockSize)
      offset += headerBlockSize
  
  of ftCancelPush:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      cancelPushId: 0
    )
    
    # プッシュIDをデコード
    let pushIdBytesRead = decodeVarint(data, offset, frame.cancelPushId)
    if pushIdBytesRead <= 0:
      raise newException(Http3FrameError, "キャンセルするプッシュIDのデコードに失敗しました")
    offset += pushIdBytesRead
  
  of ftGoaway:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      streamId: 0
    )
    
    # ストリームIDをデコード
    let streamIdBytesRead = decodeVarint(data, offset, frame.streamId)
    if streamIdBytesRead <= 0:
      raise newException(Http3FrameError, "ストリームIDのデコードに失敗しました")
    offset += streamIdBytesRead
  
  of ftMaxPushId:
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      maxPushId: 0
    )
    
    # 最大プッシュIDをデコード
    let maxPushIdBytesRead = decodeVarint(data, offset, frame.maxPushId)
    if maxPushIdBytesRead <= 0:
      raise newException(Http3FrameError, "最大プッシュIDのデコードに失敗しました")
    offset += maxPushIdBytesRead
  
  else:
    # その他のフレームタイプ
    frame = Http3Frame(
      frameType: frameType,
      kind: frameType,
      length: frameLength,
      flags: {},
      payload: ""
    )
    
    # ペイロードをコピー
    if frameLength > 0:
      frame.payload = newString(frameLength.int)
      copyMem(addr frame.payload[0], unsafeAddr data[offset], frameLength.int)
      offset += frameLength.int
  
  return frame

# フレームの文字列表現
proc `$`*(frame: Http3Frame): string =
  var flagsStr = ""
  if ffEndStream in frame.flags:
    flagsStr &= " END_STREAM"
  if ffPadded in frame.flags:
    flagsStr &= " PADDED"
  if ffPriority in frame.flags:
    flagsStr &= " PRIORITY"
  
  result = fmt"{frame.frameType} frame, length={frame.length}{flagsStr}"
  
  # フレームタイプ別の詳細を追加
  case frame.kind
  of ftSettings:
    result &= ", settings={"
    var settingsStr = ""
    for idx, setting in frame.settings:
      if idx > 0:
        settingsStr &= ", "
      
      var idStr = $setting.id
      case setting.id
      of SETTINGS_QPACK_MAX_TABLE_CAPACITY:
        idStr = "QPACK_MAX_TABLE_CAPACITY"
      of SETTINGS_MAX_FIELD_SECTION_SIZE:
        idStr = "MAX_FIELD_SECTION_SIZE"
      of SETTINGS_QPACK_BLOCKED_STREAMS:
        idStr = "QPACK_BLOCKED_STREAMS"
      else:
        discard
      
      settingsStr &= fmt"{idStr}={setting.value}"
    
    result &= settingsStr & "}"
  
  of ftPushPromise:
    result &= fmt", push_id={frame.pushId}, headers_length={frame.promiseHeaders.len}"
  
  of ftCancelPush:
    result &= fmt", push_id={frame.cancelPushId}"
  
  of ftGoaway:
    result &= fmt", stream_id={frame.streamId}"
  
  of ftMaxPushId:
    result &= fmt", max_push_id={frame.maxPushId}"
  
  of ftData, ftHeaders:
    let dataLen = if frame.kind == ftData: frame.data.len else: frame.headers.len
    result &= fmt", payload_length={dataLen}"
  
  else:
    if frame.payload.len > 0:
      result &= fmt", payload_length={frame.payload.len}"

# フレームコレクション管理
type Http3FrameCollection* = object
  frames*: Deque[Http3Frame]
  frameCount*: int
  totalSize*: int64
  frameTypeCount*: array[Http3FrameType, int]

# フレームコレクションの初期化
proc newHttp3FrameCollection*(): Http3FrameCollection =
  result = Http3FrameCollection(
    frames: initDeque[Http3Frame](),
    frameCount: 0,
    totalSize: 0
  )
  for frameType in Http3FrameType:
    result.frameTypeCount[frameType] = 0

# フレームをコレクションに追加
proc addFrame*(collection: var Http3FrameCollection, frame: Http3Frame) =
  collection.frames.addLast(frame)
  inc(collection.frameCount)
  inc(collection.frameTypeCount[frame.frameType])
  
  # フレームサイズの計算（ヘッダー + ペイロード）
  let headerSize = varIntSize(uint64(ord(frame.frameType))) + varIntSize(frame.length)
  collection.totalSize += headerSize + int64(frame.length)

# 特定タイプのフレームを探す
proc findFramesByType*(collection: Http3FrameCollection, frameType: Http3FrameType): seq[Http3Frame] =
  result = @[]
  for frame in collection.frames:
    if frame.frameType == frameType:
      result.add(frame)

# フレームハンドラーを使用してフレームを処理
proc processFrame*(handler: Http3FrameHandler, streamId: uint64, frame: Http3Frame) {.async.} =
  case frame.kind
  of ftData:
    if handler.onData != nil:
      await handler.onData(streamId, frame.data, ffEndStream in frame.flags)
  
  of ftHeaders:
    if handler.onHeaders != nil:
      await handler.onHeaders(streamId, frame.headers, ffEndStream in frame.flags)
  
  of ftSettings:
    if handler.onSettings != nil:
      await handler.onSettings(frame.settings)
  
  of ftPushPromise:
    if handler.onPushPromise != nil:
      await handler.onPushPromise(streamId, frame.pushId, frame.promiseHeaders)
  
  of ftGoaway:
    if handler.onGoaway != nil:
      await handler.onGoaway(frame.streamId)
  
  of ftCancelPush:
    if handler.onCancelPush != nil:
      await handler.onCancelPush(frame.cancelPushId)
  
  of ftMaxPushId:
    if handler.onMaxPushId != nil:
      await handler.onMaxPushId(frame.maxPushId)
  
  else:
    if handler.onUnknown != nil:
      await handler.onUnknown(streamId, uint64(ord(frame.frameType)), frame.payload)

# フレームをバッチ処理
proc processFrames*(handler: Http3FrameHandler, streamId: uint64, frames: seq[Http3Frame]) {.async.} =
  for frame in frames:
    await processFrame(handler, streamId, frame)

# フレームのバリデーション
proc validate*(frame: Http3Frame): bool =
  case frame.kind
  of ftData:
    if frame.data.len != int(frame.length):
      return false
  
  of ftHeaders:
    if frame.headers.len != int(frame.length):
      return false
  
  of ftSettings:
    var calculatedLength: uint64 = 0
    for setting in frame.settings:
      calculatedLength += varIntSize(setting.id) + varIntSize(setting.value)
    if calculatedLength != frame.length:
      return false
  
  of ftPushPromise:
    let idSize = varIntSize(frame.pushId)
    if idSize + frame.promiseHeaders.len != int(frame.length):
      return false
  
  of ftCancelPush:
    if varIntSize(frame.cancelPushId) != int(frame.length):
      return false
  
  of ftGoaway:
    if varIntSize(frame.streamId) != int(frame.length):
      return false
  
  of ftMaxPushId:
    if varIntSize(frame.maxPushId) != int(frame.length):
      return false
  
  else:
    if frame.payload.len != int(frame.length):
      return false
  
  return true

# バッファからすべてのフレームをデコード
proc decodeFrames*(data: string): seq[Http3Frame] =
  result = @[]
  var offset = 0
  
  while offset < data.len:
    try:
      let frame = parseFrame(data.toOpenArrayByte(offset), offset)
      result.add(frame)
    except Http3FrameError:
      break

# Settingsフレームからテーブルを作成
proc toTable*(settingsFrame: Http3Frame): Table[uint64, uint64] =
  result = initTable[uint64, uint64]()
  if settingsFrame.kind != ftSettings:
    return
  
  for setting in settingsFrame.settings:
    result[setting.id] = setting.value

# テーブルからSettingsフレームを作成
proc toSettingsFrame*(settings: Table[uint64, uint64]): Http3Frame =
  var settingsSeq: seq[tuple[id: uint64, value: uint64]] = @[]
  
  for id, value in settings:
    settingsSeq.add((id: id, value: value))
  
  return newSettingsFrame(settingsSeq) 