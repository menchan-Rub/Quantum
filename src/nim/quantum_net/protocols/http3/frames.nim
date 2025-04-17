## quantum_net/protocols/http3/frames.nim
## 
## HTTP/3フレーム定義と処理モジュール
## RFC 9114に基づくHTTP/3フレームの実装

import streams
import strutils
import errors

type
  Http3FrameType* = enum
    ## HTTP/3フレームタイプ
    ftData = 0x0          ## DATAフレーム
    ftHeaders = 0x1       ## HEADERSフレーム
    ftCancelPush = 0x3    ## CANCEL_PUSHフレーム
    ftSettings = 0x4      ## SETTINGSフレーム
    ftPushPromise = 0x5   ## PUSH_PROMISEフレーム
    ftGoaway = 0x7        ## GOAWAYフレーム
    ftMaxPushId = 0xD     ## MAX_PUSH_IDフレーム
    ftReservedH3 = 0xFFFF ## 予約済み

  Http3Frame* = ref object of RootObj
    ## HTTP/3フレーム基底型
    frameType*: Http3FrameType ## フレームタイプ
    length*: uint64           ## ペイロード長

  DataFrame* = ref object of Http3Frame
    ## DATAフレーム
    data*: seq[byte]          ## ペイロードデータ

  HeadersFrame* = ref object of Http3Frame
    ## HEADERSフレーム
    headerBlock*: seq[byte]   ## ヘッダーブロックフラグメント

  CancelPushFrame* = ref object of Http3Frame
    ## CANCEL_PUSHフレーム
    pushId*: uint64           ## キャンセルするプッシュID

  SettingParameter* = tuple
    ## 設定パラメータ
    identifier: uint64        ## 設定識別子
    value: uint64             ## 設定値

  SettingsFrame* = ref object of Http3Frame
    ## SETTINGSフレーム
    settings*: seq[SettingParameter] ## 設定パラメータのリスト

  PushPromiseFrame* = ref object of Http3Frame
    ## PUSH_PROMISEフレーム
    pushId*: uint64           ## プッシュID
    headerBlock*: seq[byte]   ## ヘッダーブロックフラグメント

  GoawayFrame* = ref object of Http3Frame
    ## GOAWAYフレーム
    streamId*: uint64         ## ストリームID

  MaxPushIdFrame* = ref object of Http3Frame
    ## MAX_PUSH_IDフレーム
    pushId*: uint64           ## 最大プッシュID

  UnknownFrame* = ref object of Http3Frame
    ## 未知のフレーム
    rawData*: seq[byte]       ## 生データ

# 設定パラメータ識別子
const
  SettingsQpackMaxTableCapacity* = 0x1     ## QPACK最大テーブル容量
  SettingsMaxFieldSectionSize* = 0x6       ## 最大フィールドセクションサイズ
  SettingsQpackBlockedStreams* = 0x7       ## QPACKブロック済みストリーム

# 可変長整数エンコード/デコード

proc encodeVarInt*(value: uint64): seq[byte] =
  ## 可変長整数をエンコード
  # RFCに基づく可変長整数エンコーディング
  if value < (1'u64 shl 6):
    # 6ビット以内なら1バイト
    result = @[byte(value)]
  elif value < (1'u64 shl 14):
    # 14ビット以内なら2バイト
    result = @[
      byte(0x40 or (value shr 8)),
      byte(value and 0xFF)
    ]
  elif value < (1'u64 shl 30):
    # 30ビット以内なら4バイト
    result = @[
      byte(0x80 or (value shr 24)),
      byte((value shr 16) and 0xFF),
      byte((value shr 8) and 0xFF),
      byte(value and 0xFF)
    ]
  elif value < (1'u64 shl 62):
    # 62ビット以内なら8バイト
    result = @[
      byte(0xC0 or (value shr 56)),
      byte((value shr 48) and 0xFF),
      byte((value shr 40) and 0xFF),
      byte((value shr 32) and 0xFF),
      byte((value shr 24) and 0xFF),
      byte((value shr 16) and 0xFF),
      byte((value shr 8) and 0xFF),
      byte(value and 0xFF)
    ]
  else:
    # 62ビット以上は例外
    raise newException(ValueError, "Value too large for variable length integer encoding")

proc decodeVarInt*(data: openArray[byte], offset: var int): tuple[value: uint64, bytesRead: int] =
  ## 可変長整数をデコード
  if offset >= data.len:
    raise newException(ValueError, "Invalid offset for decoding variable length integer")
  
  let firstByte = data[offset]
  let prefix = firstByte and 0xC0 # 最上位2ビットを取得
  var byteLen = 1
  var mask: uint64 = 0x3F # 01111111
  
  case prefix
  of 0x00:
    byteLen = 1
    mask = 0x3F # 6ビット
  of 0x40:
    byteLen = 2
    mask = 0x3FFF # 14ビット
  of 0x80:
    byteLen = 4
    mask = 0x3FFFFFFF # 30ビット
  of 0xC0:
    byteLen = 8
    mask = 0x3FFFFFFFFFFFFFFF # 62ビット
  else:
    # あり得ない
    raise newException(ValueError, "Invalid prefix in variable length integer")
  
  # データが十分にあるか確認
  if offset + byteLen > data.len:
    raise newException(ValueError, "Incomplete variable length integer")
  
  var value: uint64 = uint64(firstByte and byte(mask shr ((byteLen - 1) * 8)))
  
  for i in 1..<byteLen:
    value = (value shl 8) or uint64(data[offset + i])
  
  offset += byteLen
  return (value, byteLen)

# フレームエンコード/デコード関数

proc encodeFrame*(frame: Http3Frame): seq[byte] =
  ## Http3フレームをエンコード
  result = encodeVarInt(uint64(frame.frameType))
  
  case frame.frameType
  of ftData:
    let dataFrame = DataFrame(frame)
    let payload = dataFrame.data
    
    result.add(encodeVarInt(uint64(payload.len)))
    result.add(payload)
    
  of ftHeaders:
    let headersFrame = HeadersFrame(frame)
    let payload = headersFrame.headerBlock
    
    result.add(encodeVarInt(uint64(payload.len)))
    result.add(payload)
    
  of ftCancelPush:
    let cancelPushFrame = CancelPushFrame(frame)
    
    result.add(encodeVarInt(1)) # ペイロード長
    result.add(encodeVarInt(cancelPushFrame.pushId))
    
  of ftSettings:
    let settingsFrame = SettingsFrame(frame)
    var payload: seq[byte] = @[]
    
    for setting in settingsFrame.settings:
      payload.add(encodeVarInt(setting.identifier))
      payload.add(encodeVarInt(setting.value))
    
    result.add(encodeVarInt(uint64(payload.len)))
    result.add(payload)
    
  of ftPushPromise:
    let pushPromiseFrame = PushPromiseFrame(frame)
    
    # プッシュIDとヘッダーブロックを含むペイロード
    var payload = encodeVarInt(pushPromiseFrame.pushId)
    payload.add(pushPromiseFrame.headerBlock)
    
    result.add(encodeVarInt(uint64(payload.len)))
    result.add(payload)
    
  of ftGoaway:
    let goawayFrame = GoawayFrame(frame)
    
    result.add(encodeVarInt(8)) # ペイロード長
    result.add(encodeVarInt(goawayFrame.streamId))
    
  of ftMaxPushId:
    let maxPushIdFrame = MaxPushIdFrame(frame)
    
    result.add(encodeVarInt(1)) # ペイロード長
    result.add(encodeVarInt(maxPushIdFrame.pushId))
    
  of ftReservedH3:
    let unknownFrame = UnknownFrame(frame)
    
    result.add(encodeVarInt(uint64(unknownFrame.rawData.len)))
    result.add(unknownFrame.rawData)

proc decodeFrame*(data: openArray[byte], offset: var int): Http3Frame =
  ## HTTP/3フレームをデコード
  var currentOffset = offset
  
  # フレームタイプをデコード
  let typeResult = decodeVarInt(data, currentOffset)
  let frameType = typeResult.value
  
  # ペイロード長をデコード
  let lengthResult = decodeVarInt(data, currentOffset)
  let payloadLength = lengthResult.value
  
  # ペイロードを取得
  let payloadStartIndex = currentOffset
  
  # データが足りない場合は例外
  if currentOffset + int(payloadLength) > data.len:
    raise newException(ValueError, "Incomplete frame payload")
  
  var frame: Http3Frame
  
  case frameType
  of uint64(ftData):
    let dataPayload = data[payloadStartIndex..<(payloadStartIndex + int(payloadLength))]
    var dataFrame = DataFrame(frameType: ftData, length: payloadLength)
    dataFrame.data = @[]
    
    for b in dataPayload:
      dataFrame.data.add(b)
      
    frame = dataFrame
    
  of uint64(ftHeaders):
    let headerPayload = data[payloadStartIndex..<(payloadStartIndex + int(payloadLength))]
    var headersFrame = HeadersFrame(frameType: ftHeaders, length: payloadLength)
    headersFrame.headerBlock = @[]
    
    for b in headerPayload:
      headersFrame.headerBlock.add(b)
      
    frame = headersFrame
    
  of uint64(ftCancelPush):
    if payloadLength > 0:
      var cpFrame = CancelPushFrame(frameType: ftCancelPush, length: payloadLength)
      var pushIdOffset = payloadStartIndex
      let pushIdResult = decodeVarInt(data, pushIdOffset)
      cpFrame.pushId = pushIdResult.value
      frame = cpFrame
    else:
      frame = CancelPushFrame(frameType: ftCancelPush, length: 0, pushId: 0)
    
  of uint64(ftSettings):
    var settingsFrame = SettingsFrame(frameType: ftSettings, length: payloadLength)
    settingsFrame.settings = @[]
    
    var settingsOffset = payloadStartIndex
    let endOffset = payloadStartIndex + int(payloadLength)
    
    while settingsOffset < endOffset:
      let identifierResult = decodeVarInt(data, settingsOffset)
      if settingsOffset >= endOffset:
        break
        
      let valueResult = decodeVarInt(data, settingsOffset)
      settingsFrame.settings.add((identifierResult.value, valueResult.value))
      
    frame = settingsFrame
    
  of uint64(ftPushPromise):
    var ppFrame = PushPromiseFrame(frameType: ftPushPromise, length: payloadLength)
    
    var promiseOffset = payloadStartIndex
    let pushIdResult = decodeVarInt(data, promiseOffset)
    ppFrame.pushId = pushIdResult.value
    
    # 残りはヘッダーブロック
    ppFrame.headerBlock = @[]
    while promiseOffset < payloadStartIndex + int(payloadLength):
      ppFrame.headerBlock.add(data[promiseOffset])
      promiseOffset.inc
      
    frame = ppFrame
    
  of uint64(ftGoaway):
    var goawayFrame = GoawayFrame(frameType: ftGoaway, length: payloadLength)
    
    var goawayOffset = payloadStartIndex
    let streamIdResult = decodeVarInt(data, goawayOffset)
    goawayFrame.streamId = streamIdResult.value
    
    frame = goawayFrame
    
  of uint64(ftMaxPushId):
    var mpFrame = MaxPushIdFrame(frameType: ftMaxPushId, length: payloadLength)
    
    var maxPushOffset = payloadStartIndex
    let pushIdResult = decodeVarInt(data, maxPushOffset)
    mpFrame.pushId = pushIdResult.value
    
    frame = mpFrame
    
  else:
    # 未知のフレーム
    var unknownFrame = UnknownFrame(frameType: ftReservedH3, length: payloadLength)
    unknownFrame.rawData = @[]
    
    for i in 0..<int(payloadLength):
      if payloadStartIndex + i < data.len:
        unknownFrame.rawData.add(data[payloadStartIndex + i])
      
    frame = unknownFrame
  
  # オフセットを更新
  offset = payloadStartIndex + int(payloadLength)
  return frame

# ユーティリティ関数

proc newDataFrame*(data: seq[byte]): DataFrame =
  ## 新しいDATAフレームを作成
  result = DataFrame(
    frameType: ftData,
    length: uint64(data.len),
    data: data
  )

proc newHeadersFrame*(headerBlock: seq[byte]): HeadersFrame =
  ## 新しいHEADERSフレームを作成
  result = HeadersFrame(
    frameType: ftHeaders,
    length: uint64(headerBlock.len),
    headerBlock: headerBlock
  )

proc newCancelPushFrame*(pushId: uint64): CancelPushFrame =
  ## 新しいCANCEL_PUSHフレームを作成
  result = CancelPushFrame(
    frameType: ftCancelPush,
    length: 8, # 可変長整数で8バイト
    pushId: pushId
  )

proc newSettingsFrame*(settings: seq[SettingParameter]): SettingsFrame =
  ## 新しいSETTINGSフレームを作成
  var payloadLength: uint64 = 0
  for setting in settings:
    # 各設定は識別子と値のペア（可変長整数）
    payloadLength += 2 # 簡略化のため、各設定に2バイト割り当て
  
  result = SettingsFrame(
    frameType: ftSettings,
    length: payloadLength,
    settings: settings
  )

proc newDefaultSettingsFrame*(): SettingsFrame =
  ## デフォルト設定のSETTINGSフレームを作成
  let defaultSettings = @[
    (SettingsQpackMaxTableCapacity, 4096'u64),   # 4KB
    (SettingsMaxFieldSectionSize, 16384'u64),    # 16KB
    (SettingsQpackBlockedStreams, 100'u64)       # 最大100ストリーム
  ]
  
  result = newSettingsFrame(defaultSettings)

proc newPushPromiseFrame*(pushId: uint64, headerBlock: seq[byte]): PushPromiseFrame =
  ## 新しいPUSH_PROMISEフレームを作成
  result = PushPromiseFrame(
    frameType: ftPushPromise,
    length: 8 + uint64(headerBlock.len), # プッシュID + ヘッダーブロック
    pushId: pushId,
    headerBlock: headerBlock
  )

proc newGoawayFrame*(streamId: uint64): GoawayFrame =
  ## 新しいGOAWAYフレームを作成
  result = GoawayFrame(
    frameType: ftGoaway,
    length: 8, # ストリームIDの長さ
    streamId: streamId
  )

proc newMaxPushIdFrame*(pushId: uint64): MaxPushIdFrame =
  ## 新しいMAX_PUSH_IDフレームを作成
  result = MaxPushIdFrame(
    frameType: ftMaxPushId,
    length: 8, # プッシュIDの長さ
    pushId: pushId
  )

# フレームのデバッグ用文字列表現

proc `$`*(frame: Http3Frame): string =
  ## Http3フレームの文字列表現
  result = $frame.frameType & " Frame"
  
  case frame.frameType
  of ftData:
    let dataFrame = DataFrame(frame)
    result &= " (Length: " & $dataFrame.length & " bytes)"
    
  of ftHeaders:
    let headersFrame = HeadersFrame(frame)
    result &= " (Length: " & $headersFrame.length & " bytes)"
    
  of ftCancelPush:
    let cancelPushFrame = CancelPushFrame(frame)
    result &= " (Push ID: " & $cancelPushFrame.pushId & ")"
    
  of ftSettings:
    let settingsFrame = SettingsFrame(frame)
    result &= " (" & $settingsFrame.settings.len & " settings)"
    
  of ftPushPromise:
    let pushPromiseFrame = PushPromiseFrame(frame)
    result &= " (Push ID: " & $pushPromiseFrame.pushId & 
              ", Header Block: " & $pushPromiseFrame.headerBlock.len & " bytes)"
    
  of ftGoaway:
    let goawayFrame = GoawayFrame(frame)
    result &= " (Stream ID: " & $goawayFrame.streamId & ")"
    
  of ftMaxPushId:
    let maxPushIdFrame = MaxPushIdFrame(frame)
    result &= " (Push ID: " & $maxPushIdFrame.pushId & ")"
    
  of ftReservedH3:
    let unknownFrame = UnknownFrame(frame)
    result &= " (Unknown Type, " & $unknownFrame.length & " bytes)"

# フレームの詳細な表示

proc `$`*(settings: seq[SettingParameter]): string =
  ## 設定パラメータのリストの文字列表現
  result = "["
  for i, setting in settings:
    if i > 0: result &= ", "
    
    let id = setting.identifier
    var idName = "0x" & toHex(id)
    
    case id
    of SettingsQpackMaxTableCapacity:
      idName = "QPACK_MAX_TABLE_CAPACITY"
    of SettingsMaxFieldSectionSize:
      idName = "MAX_FIELD_SECTION_SIZE"
    of SettingsQpackBlockedStreams:
      idName = "QPACK_BLOCKED_STREAMS"
    else:
      discard
    
    result &= idName & ": " & $setting.value
    
  result &= "]"

proc dumpFrameDetails*(frame: Http3Frame): string =
  ## Http3フレームの詳細情報
  result = "HTTP/3 " & $frame & "\n"
  result &= "  Type: 0x" & toHex(uint64(frame.frameType)) & " (" & $frame.frameType & ")\n"
  result &= "  Length: " & $frame.length & " bytes\n"
  
  case frame.frameType
  of ftData:
    let dataFrame = DataFrame(frame)
    result &= "  Data: "
    if dataFrame.data.len > 20:
      for i in 0..<20:
        result &= toHex(dataFrame.data[i]) & " "
      result &= "... (" & $dataFrame.data.len & " bytes total)"
    else:
      for b in dataFrame.data:
        result &= toHex(b) & " "
    
  of ftHeaders:
    let headersFrame = HeadersFrame(frame)
    result &= "  Header Block: "
    if headersFrame.headerBlock.len > 20:
      for i in 0..<20:
        result &= toHex(headersFrame.headerBlock[i]) & " "
      result &= "... (" & $headersFrame.headerBlock.len & " bytes total)"
    else:
      for b in headersFrame.headerBlock:
        result &= toHex(b) & " "
    
  of ftCancelPush:
    let cancelPushFrame = CancelPushFrame(frame)
    result &= "  Push ID: " & $cancelPushFrame.pushId & "\n"
    
  of ftSettings:
    let settingsFrame = SettingsFrame(frame)
    result &= "  Settings: " & $settingsFrame.settings & "\n"
    
  of ftPushPromise:
    let pushPromiseFrame = PushPromiseFrame(frame)
    result &= "  Push ID: " & $pushPromiseFrame.pushId & "\n"
    result &= "  Header Block: "
    if pushPromiseFrame.headerBlock.len > 20:
      for i in 0..<20:
        result &= toHex(pushPromiseFrame.headerBlock[i]) & " "
      result &= "... (" & $pushPromiseFrame.headerBlock.len & " bytes total)"
    else:
      for b in pushPromiseFrame.headerBlock:
        result &= toHex(b) & " "
    
  of ftGoaway:
    let goawayFrame = GoawayFrame(frame)
    result &= "  Stream ID: " & $goawayFrame.streamId & "\n"
    
  of ftMaxPushId:
    let maxPushIdFrame = MaxPushIdFrame(frame)
    result &= "  Push ID: " & $maxPushIdFrame.pushId & "\n"
    
  of ftReservedH3:
    let unknownFrame = UnknownFrame(frame)
    result &= "  Raw Data: "
    if unknownFrame.rawData.len > 20:
      for i in 0..<20:
        result &= toHex(unknownFrame.rawData[i]) & " "
      result &= "... (" & $unknownFrame.rawData.len & " bytes total)"
    else:
      for b in unknownFrame.rawData:
        result &= toHex(b) & " " 