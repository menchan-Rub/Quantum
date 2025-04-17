## WebSocketフレーム処理
##
## WebSocketプロトコル（RFC 6455）に準拠したフレームの処理を提供します。
## フレームのエンコード、デコード、操作のための関数を実装しています。

import std/[strutils, random, endians]
import ./websocket_types

# WebSocketマスク処理関数
proc applyMask(data: var string, maskKey: array[4, char]) =
  ## WebSocketペイロードにマスクを適用する
  for i in 0..<data.len:
    data[i] = char(uint8(data[i]) xor uint8(maskKey[i mod 4]))

proc generateMaskKey(): array[4, char] =
  ## WebSocketフレーム用のランダムなマスクキーを生成する
  result[0] = char(rand(255))
  result[1] = char(rand(255))
  result[2] = char(rand(255))
  result[3] = char(rand(255))

proc encodeFrame*(payload: string, opCode: WebSocketOpCode, fin: bool = true, mask: bool = false): string =
  ## WebSocketフレームをエンコードする
  ##
  ## 引数:
  ##   payload: フレームのペイロードデータ
  ##   opCode: 操作コード（Text, Binary, Close, Ping, Pong, Continuation）
  ##   fin: 最終フレームかどうか
  ##   mask: ペイロードにマスクを適用するかどうか
  ##
  ## 戻り値:
  ##   エンコードされたWebSocketフレームデータ
  
  var firstByte: uint8 = uint8(opCode)
  if fin:
    firstByte = firstByte or 0x80  # FINビットを設定
  
  var secondByte: uint8 = 0
  if mask:
    secondByte = secondByte or 0x80  # マスクビットを設定
  
  # ペイロード長の決定
  var length = payload.len
  
  result = ""
  result.add(char(firstByte))
  
  # ペイロード長フィールドを設定
  if length < 126:
    secondByte = secondByte or uint8(length)
    result.add(char(secondByte))
  elif length <= 0xFFFF:
    secondByte = secondByte or 126
    result.add(char(secondByte))
    
    var lenBytes: array[2, char]
    bigEndian16(addr lenBytes, unsafeAddr length)
    result.add(lenBytes[0])
    result.add(lenBytes[1])
  else:
    secondByte = secondByte or 127
    result.add(char(secondByte))
    
    var lenBytes: array[8, char]
    var len64 = uint64(length)
    bigEndian64(addr lenBytes, unsafeAddr len64)
    for b in lenBytes:
      result.add(b)
  
  # マスクが有効な場合、マスクキーを追加
  var maskKey: array[4, char]
  if mask:
    maskKey = generateMaskKey()
    result.add(maskKey[0])
    result.add(maskKey[1])
    result.add(maskKey[2])
    result.add(maskKey[3])
  
  # ペイロードデータを追加
  var payloadData = payload
  if mask:
    applyMask(payloadData, maskKey)
  
  result.add(payloadData)

proc encodeCloseFrame*(code: uint16, reason: string = ""): string =
  ## WebSocketのクローズフレームをエンコードする
  ##
  ## 引数:
  ##   code: クローズコード（1000-4999）
  ##   reason: クローズ理由（オプション）
  ##
  ## 戻り値:
  ##   エンコードされたクローズフレーム
  
  var payload = ""
  
  # コードをバイナリ形式に変換（ネットワークバイトオーダー）
  var codeBytes: array[2, char]
  var networkCode = code
  bigEndian16(addr codeBytes, unsafeAddr networkCode)
  
  payload.add(codeBytes[0])
  payload.add(codeBytes[1])
  
  # 理由文字列を追加（存在する場合）
  if reason.len > 0:
    payload.add(reason)
  
  # クローズフレームをエンコード
  return encodeFrame(payload, Close, true, false)

proc decodeFrame*(frameData: string): tuple[frame: WebSocketFrame, bytesConsumed: int] =
  ## WebSocketフレームをデコードする
  ##
  ## 引数:
  ##   frameData: デコードするバイナリデータ
  ##
  ## 戻り値:
  ##   (WebSocketFrame, 消費されたバイト数)のタプル
  ##
  ## 例外:
  ##   ProtocolError: フレームデータが不正な場合
  ##   InsufficientData: フレームデータが不完全な場合
  
  # 最小フレームヘッダーサイズ（2バイト）を確認
  if frameData.len < 2:
    raise newException(InsufficientData, "Frame data too short for header")
  
  # 基本フレーム情報の解析
  let firstByte = uint8(frameData[0])
  let secondByte = uint8(frameData[1])
  
  # フレームフラグの抽出
  let fin = (firstByte and 0x80) != 0
  let rsv1 = (firstByte and 0x40) != 0
  let rsv2 = (firstByte and 0x20) != 0
  let rsv3 = (firstByte and 0x10) != 0
  
  # 拡張フラグがセットされているかチェック（現在はサポートしない）
  if rsv1 or rsv2 or rsv3:
    raise newException(ProtocolError, "RSV bits are set but no extension is negotiated")
  
  # OpCodeの抽出
  let opCode = WebSocketOpCode(firstByte and 0x0F)
  
  # OpCodeの有効性をチェック
  if int(opCode) > 10:
    raise newException(ProtocolError, "Invalid OpCode: " & $int(opCode))
  
  # マスクフラグの抽出
  let masked = (secondByte and 0x80) != 0
  
  # ペイロード長の取得
  var payloadLen = int(secondByte and 0x7F)
  var headerLen = 2
  
  # 拡張ペイロード長フィールドの処理
  if payloadLen == 126:
    # 2バイト長
    if frameData.len < 4:
      raise newException(InsufficientData, "Frame data too short for 2-byte payload length")
    
    var length: uint16
    bigEndian16(addr length, unsafeAddr frameData[2])
    payloadLen = int(length)
    headerLen = 4
  elif payloadLen == 127:
    # 8バイト長
    if frameData.len < 10:
      raise newException(InsufficientData, "Frame data too short for 8-byte payload length")
    
    var length: uint64
    bigEndian64(addr length, unsafeAddr frameData[2])
    payloadLen = int(length)
    headerLen = 10
  
  # マスクキーの処理
  var maskKey: array[4, char]
  if masked:
    if frameData.len < headerLen + 4:
      raise newException(InsufficientData, "Frame data too short for mask key")
    
    maskKey[0] = frameData[headerLen]
    maskKey[1] = frameData[headerLen + 1]
    maskKey[2] = frameData[headerLen + 2]
    maskKey[3] = frameData[headerLen + 3]
    headerLen += 4
  
  # フレーム全体のサイズを確認
  let frameSize = headerLen + payloadLen
  if frameData.len < frameSize:
    raise newException(InsufficientData, "Frame data too short for payload")
  
  # ペイロードの抽出
  var payload = frameData[headerLen..<frameSize]
  
  # マスクの適用解除（必要な場合）
  if masked:
    applyMask(payload, maskKey)
  
  # WebSocketFrameオブジェクトの作成
  let frame = WebSocketFrame(
    fin: fin,
    rsv1: rsv1,
    rsv2: rsv2,
    rsv3: rsv3,
    opCode: opCode,
    masked: masked,
    maskKey: maskKey,
    payload: payload
  )
  
  return (frame, frameSize)

proc isControlFrame*(frame: WebSocketFrame): bool =
  ## フレームがコントロールフレームかどうかをチェックする
  case frame.opCode
  of Close, Ping, Pong:
    true
  else:
    false

proc isDataFrame*(frame: WebSocketFrame): bool =
  ## フレームがデータフレームかどうかをチェックする
  case frame.opCode
  of Text, Binary, Continuation:
    true
  else:
    false 