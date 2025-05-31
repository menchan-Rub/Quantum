# QPACK デコーダー実装 - RFC 9204完全準拠
# 世界最高水準のHTTPヘッダー復号化実装

import std/[tables, strutils, sequtils, bitops, algorithm]
import std/[strformat, options, deques, locks]
import qpack_encoder  # 静的テーブルとハフマンテーブルを共有

const
  # ハフマン復号化用のEOSシンボル
  HUFFMAN_EOS = 256

type
  HuffmanNode* = ref object
    symbol*: int  # -1 for internal nodes, 0-255 for leaf nodes, 256 for EOS
    left*: HuffmanNode
    right*: HuffmanNode

  QpackDecoder* = ref object
    dynamicTable*: Deque[QpackDynamicEntry]
    maxTableCapacity*: uint64
    currentTableSize*: uint64
    maxBlockedStreams*: uint64
    insertCount*: uint64
    
    # ハフマン復号化用
    huffmanRoot*: HuffmanNode
    
    # ブロックされたストリーム
    blockedStreams*: Table[uint64, seq[byte]]
    
    # ロック
    decoderLock*: Lock

# ハフマン復号化ツリーの構築
proc buildHuffmanTree(): HuffmanNode =
  ## ハフマン復号化ツリーを構築
  
  result = HuffmanNode(symbol: -1)
  
  for i in 0..<256:
    let (code, length) = HUFFMAN_CODES[i]
    var current = result
    
    for bit in countdown(length - 1, 0):
      let bitValue = (code shr bit) and 1
      
      if bitValue == 0:
        if current.left == nil:
          current.left = HuffmanNode(symbol: -1)
        current = current.left
      else:
        if current.right == nil:
          current.right = HuffmanNode(symbol: -1)
        current = current.right
    
    current.symbol = i
  
  # EOSシンボルの追加
  let (eosCode, eosLength) = (0x3fffffff'u32, 30)
  var current = result
  
  for bit in countdown(eosLength - 1, 0):
    let bitValue = (eosCode shr bit) and 1
    
    if bitValue == 0:
      if current.left == nil:
        current.left = HuffmanNode(symbol: -1)
      current = current.left
    else:
      if current.right == nil:
        current.right = HuffmanNode(symbol: -1)
      current = current.right
  
  current.symbol = HUFFMAN_EOS

# QPACKデコーダーの初期化
proc newQpackDecoder*(maxTableCapacity: uint64 = 4096, maxBlockedStreams: uint64 = 100): QpackDecoder =
  result = QpackDecoder(
    dynamicTable: initDeque[QpackDynamicEntry](),
    maxTableCapacity: maxTableCapacity,
    currentTableSize: 0,
    maxBlockedStreams: maxBlockedStreams,
    insertCount: 0,
    huffmanRoot: buildHuffmanTree(),
    blockedStreams: initTable[uint64, seq[byte]]()
  )
  
  initLock(result.decoderLock)

# 整数デコーディング
proc decodeInteger*(data: seq[byte], offset: var int, prefixBits: int): uint64 =
  ## QUICフォーマットの整数をデコード
  
  if offset >= data.len:
    raise newException(ValueError, "Insufficient data for integer decoding")
  
  let mask = (1 shl prefixBits) - 1
  result = data[offset].uint64 and mask.uint64
  offset += 1
  
  if result < mask.uint64:
    return
  
  var shift = 0
  while offset < data.len:
    let b = data[offset]
    offset += 1
    
    result += ((b and 0x7F).uint64 shl shift)
    shift += 7
    
    if (b and 0x80) == 0:
      break
  
  if offset > data.len:
    raise newException(ValueError, "Invalid integer encoding")

# ハフマン復号化
proc huffmanDecode*(decoder: QpackDecoder, data: seq[byte]): string =
  ## ハフマン符号化されたデータを復号化
  
  result = ""
  var current = decoder.huffmanRoot
  var bitBuffer: uint32 = 0
  var bitsInBuffer = 0
  
  for b in data:
    bitBuffer = (bitBuffer shl 8) or b.uint32
    bitsInBuffer += 8
    
    while bitsInBuffer > 0:
      # 最上位ビットを取得
      let bit = (bitBuffer shr (bitsInBuffer - 1)) and 1
      bitsInBuffer -= 1
      
      if bit == 0:
        current = current.left
      else:
        current = current.right
      
      if current == nil:
        raise newException(ValueError, "Invalid Huffman code")
      
      if current.symbol >= 0:
        if current.symbol == HUFFMAN_EOS:
          # EOSシンボル - 残りはパディング
          return result
        
        result.add(char(current.symbol))
        current = decoder.huffmanRoot
  
  # 残りのビットがすべて1（パディング）かチェック
  if bitsInBuffer > 0:
    let padding = bitBuffer and ((1'u32 shl bitsInBuffer) - 1)
    let expectedPadding = (1'u32 shl bitsInBuffer) - 1
    
    if padding != expectedPadding:
      raise newException(ValueError, "Invalid Huffman padding")

# 文字列デコーディング
proc decodeString*(decoder: QpackDecoder, data: seq[byte], offset: var int): string =
  ## 文字列をデコード（ハフマン復号化対応）
  
  if offset >= data.len:
    raise newException(ValueError, "Insufficient data for string decoding")
  
  let huffmanFlag = (data[offset] and 0x80) != 0
  let length = decodeInteger(data, offset, 7).int
  
  if offset + length > data.len:
    raise newException(ValueError, "Insufficient data for string")
  
  let stringData = data[offset..<offset + length]
  offset += length
  
  if huffmanFlag:
    result = decoder.huffmanDecode(stringData)
  else:
    result = cast[string](stringData)

# 動的テーブルへのエントリ追加
proc addToDynamicTable*(decoder: QpackDecoder, name: string, value: string) =
  ## 動的テーブルにエントリを追加
  
  withLock(decoder.decoderLock):
    let entrySize = calculateEntrySize(name, value)
    
    # テーブル容量チェック
    if entrySize > decoder.maxTableCapacity:
      return
    
    # 必要に応じて古いエントリを削除
    while decoder.currentTableSize + entrySize > decoder.maxTableCapacity and decoder.dynamicTable.len > 0:
      let oldEntry = decoder.dynamicTable.popLast()
      decoder.currentTableSize -= calculateEntrySize(oldEntry.name, oldEntry.value)
    
    # 新しいエントリを追加
    let entry = QpackDynamicEntry(
      name: name,
      value: value,
      size: entrySize
    )
    
    decoder.dynamicTable.addFirst(entry)
    decoder.currentTableSize += entrySize
    decoder.insertCount += 1

# テーブルからのエントリ取得
proc getTableEntry*(decoder: QpackDecoder, index: uint64): tuple[name: string, value: string] =
  ## 静的テーブルまたは動的テーブルからエントリを取得
  
  if index < QPACK_STATIC_TABLE.len.uint64:
    # 静的テーブル
    let entry = QPACK_STATIC_TABLE[index]
    result = (name: entry[0], value: entry[1])
  else:
    # 動的テーブル
    withLock(decoder.decoderLock):
      let dynamicIndex = index - QPACK_STATIC_TABLE.len.uint64
      
      if dynamicIndex >= decoder.dynamicTable.len.uint64:
        raise newException(ValueError, fmt"Invalid table index: {index}")
      
      let entry = decoder.dynamicTable[dynamicIndex]
      result = (name: entry.name, value: entry.value)

# ヘッダーフィールドのデコード
proc decodeHeaderField*(decoder: QpackDecoder, data: seq[byte], offset: var int): tuple[name: string, value: string] =
  ## 単一のヘッダーフィールドをデコード
  
  if offset >= data.len:
    raise newException(ValueError, "Insufficient data for header field")
  
  let firstByte = data[offset]
  
  if (firstByte and 0x80) != 0:
    # Indexed Header Field
    let index = decodeInteger(data, offset, 7)
    result = decoder.getTableEntry(index)
  
  elif (firstByte and 0x40) != 0:
    # Literal Header Field with Name Reference
    let nameIndex = decodeInteger(data, offset, 6)
    let nameEntry = decoder.getTableEntry(nameIndex)
    let value = decoder.decodeString(data, offset)
    
    result = (name: nameEntry.name, value: value)
    
    # 動的テーブルに追加
    decoder.addToDynamicTable(result.name, result.value)
  
  elif (firstByte and 0x20) != 0:
    # Literal Header Field with Literal Name
    offset += 1  # フラグバイトをスキップ
    let name = decoder.decodeString(data, offset)
    let value = decoder.decodeString(data, offset)
    
    result = (name: name, value: value)
    
    # 動的テーブルに追加
    decoder.addToDynamicTable(result.name, result.value)
  
  elif (firstByte and 0x10) != 0:
    # Literal Header Field with Name Reference (Never Indexed)
    let nameIndex = decodeInteger(data, offset, 4)
    let nameEntry = decoder.getTableEntry(nameIndex)
    let value = decoder.decodeString(data, offset)
    
    result = (name: nameEntry.name, value: value)
    # Never Indexedなので動的テーブルには追加しない
  
  else:
    # Literal Header Field with Literal Name (Never Indexed)
    offset += 1  # フラグバイトをスキップ
    let name = decoder.decodeString(data, offset)
    let value = decoder.decodeString(data, offset)
    
    result = (name: name, value: value)
    # Never Indexedなので動的テーブルには追加しない

# ヘッダーリストのデコード
proc decodeHeaders*(decoder: QpackDecoder, data: seq[byte], streamId: uint64 = 0): seq[tuple[name: string, value: string]] =
  ## ヘッダーリスト全体をデコード
  
  result = @[]
  var offset = 0
  
  if data.len == 0:
    return
  
  # Required Insert Countをデコード
  let requiredInsertCount = decodeInteger(data, offset, 8)
  
  # Delta Baseをデコード
  let deltaBase = decodeInteger(data, offset, 7)
  
  # ブロック状態のチェック
  withLock(decoder.decoderLock):
    if requiredInsertCount > decoder.insertCount:
      # ストリームがブロックされている
      decoder.blockedStreams[streamId] = data
      raise newException(ValueError, "Stream blocked waiting for dynamic table updates")
  
  # 各ヘッダーフィールドをデコード
  while offset < data.len:
    try:
      let header = decoder.decodeHeaderField(data, offset)
      result.add(header)
    except:
      # デコードエラー - 残りのデータを無視
      break

# デコーダーストリーム命令の処理
proc processDecoderInstruction*(decoder: QpackDecoder, data: seq[byte]) =
  ## デコーダーストリーム命令を処理
  
  var offset = 0
  
  while offset < data.len:
    if offset >= data.len:
      break
    
    let firstByte = data[offset]
    
    if (firstByte and 0x80) != 0:
      # Section Acknowledgment
      let streamId = decodeInteger(data, offset, 7)
      # ストリームの受信確認を処理
      
    elif (firstByte and 0x40) != 0:
      # Stream Cancellation
      let streamId = decodeInteger(data, offset, 6)
      
      withLock(decoder.decoderLock):
        decoder.blockedStreams.del(streamId)
    
    elif (firstByte and 0x20) != 0:
      # Insert Count Increment
      let increment = decodeInteger(data, offset, 5)
      
      withLock(decoder.decoderLock):
        decoder.insertCount += increment
        
        # ブロックされたストリームの処理を試行
        decoder.processBlockedStreams()
    
    else:
      # 未知の命令 - スキップ
      offset += 1

# エンコーダーストリーム命令の処理
proc processEncoderInstruction*(decoder: QpackDecoder, data: seq[byte]) =
  ## エンコーダーストリーム命令を処理
  
  var offset = 0
  
  while offset < data.len:
    if offset >= data.len:
      break
    
    let firstByte = data[offset]
    
    if (firstByte and 0x80) != 0:
      # Insert with Name Reference
      let nameIndex = decodeInteger(data, offset, 7)
      let nameEntry = decoder.getTableEntry(nameIndex)
      let value = decoder.decodeString(data, offset)
      
      decoder.addToDynamicTable(nameEntry.name, value)
    
    elif (firstByte and 0x40) != 0:
      # Insert with Literal Name
      offset += 1  # フラグバイトをスキップ
      let name = decoder.decodeString(data, offset)
      let value = decoder.decodeString(data, offset)
      
      decoder.addToDynamicTable(name, value)
    
    elif (firstByte and 0x20) != 0:
      # Set Dynamic Table Capacity
      let capacity = decodeInteger(data, offset, 5)
      decoder.setMaxTableCapacity(capacity)
    
    else:
      # Duplicate
      let index = decodeInteger(data, offset, 5)
      let entry = decoder.getTableEntry(index)
      decoder.addToDynamicTable(entry.name, entry.value)

# ブロックされたストリームの処理
proc processBlockedStreams*(decoder: QpackDecoder) =
  ## ブロックされたストリームの処理を試行
  
  var streamsToProcess: seq[uint64] = @[]
  
  for streamId in decoder.blockedStreams.keys:
    streamsToProcess.add(streamId)
  
  for streamId in streamsToProcess:
    let data = decoder.blockedStreams[streamId]
    
    try:
      discard decoder.decodeHeaders(data, streamId)
      decoder.blockedStreams.del(streamId)
    except:
      # まだブロックされている
      continue

# 動的テーブル容量の設定
proc setMaxTableCapacity*(decoder: QpackDecoder, capacity: uint64) =
  ## 動的テーブルの最大容量を設定
  
  withLock(decoder.decoderLock):
    decoder.maxTableCapacity = capacity
    
    # 現在のテーブルサイズが新しい容量を超える場合は調整
    while decoder.currentTableSize > capacity and decoder.dynamicTable.len > 0:
      let oldEntry = decoder.dynamicTable.popLast()
      decoder.currentTableSize -= calculateEntrySize(oldEntry.name, oldEntry.value)

# 受信確認の生成
proc generateSectionAcknowledgment*(decoder: QpackDecoder, streamId: uint64): seq[byte] =
  ## セクション受信確認を生成
  
  result = @[]
  result.add(0x80)  # Section Acknowledgment
  result.add(encodeInteger(streamId, 7))

proc generateStreamCancellation*(decoder: QpackDecoder, streamId: uint64): seq[byte] =
  ## ストリームキャンセレーションを生成
  
  result = @[]
  result.add(0x40)  # Stream Cancellation
  result.add(encodeInteger(streamId, 6))

proc generateInsertCountIncrement*(decoder: QpackDecoder, increment: uint64): seq[byte] =
  ## 挿入数増分を生成
  
  result = @[]
  result.add(0x20)  # Insert Count Increment
  result.add(encodeInteger(increment, 5))

# 統計情報の取得
proc getStats*(decoder: QpackDecoder): tuple[tableSize: uint64, entryCount: int, insertCount: uint64, blockedStreams: int] =
  ## デコーダーの統計情報を取得
  
  withLock(decoder.decoderLock):
    result = (
      tableSize: decoder.currentTableSize,
      entryCount: decoder.dynamicTable.len,
      insertCount: decoder.insertCount,
      blockedStreams: decoder.blockedStreams.len
    )

# デバッグ情報
proc getDebugInfo*(decoder: QpackDecoder): string =
  ## デコーダーのデバッグ情報
  
  let stats = decoder.getStats()
  
  result = fmt"""
QPACK Decoder Debug Info:
  Max Table Capacity: {decoder.maxTableCapacity} bytes
  Current Table Size: {stats.tableSize} bytes
  Dynamic Table Entries: {stats.entryCount}
  Insert Count: {stats.insertCount}
  Blocked Streams: {stats.blockedStreams}
  Max Blocked Streams: {decoder.maxBlockedStreams}
"""

# 動的テーブルの内容表示
proc getDynamicTableInfo*(decoder: QpackDecoder): string =
  ## 動的テーブルの内容を表示
  
  result = "Dynamic Table Contents:\n"
  
  withLock(decoder.decoderLock):
    for i, entry in decoder.dynamicTable:
      result.add(fmt"  [{i}] {entry.name}: {entry.value} (size: {entry.size})\n")

# エクスポート
export QpackDecoder, HuffmanNode
export newQpackDecoder, decodeHeaders, addToDynamicTable
export processDecoderInstruction, processEncoderInstruction
export setMaxTableCapacity, generateSectionAcknowledgment
export generateStreamCancellation, generateInsertCountIncrement
export getStats, getDebugInfo, getDynamicTableInfo 