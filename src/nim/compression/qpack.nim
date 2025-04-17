# HTTP/3 QPACK Header Compression
#
# RFC 9204の簡易実装
# HTTP/3のヘッダー圧縮をサポート

import std/[tables, hashes, strutils, algorithm]
import hpack  # 基本的な機能はHPACKと共有

type
  QpackEncoder* = ref object
    baseEncoder: HpackEncoder
    knownReceivedCount: uint64
    lowestUnackedIndex: uint64
    dynamicTableCapacity: uint64
    maxEntries: uint64
    insertCount: uint64
    blockedStreams: int
  
  QpackDecoder* = ref object
    baseDecoder: HpackDecoder
    maxDynamicTableCapacity: uint64
    maxBlockedStreams: int
    insertCount: uint64
    knownReceivedCount: uint64
    blockedStreams: seq[uint64]

# QPACKエンコーダー
proc newQpackEncoder*(tableSize: int = 4096, blockedStreams: int = 100): QpackEncoder =
  result = QpackEncoder(
    baseEncoder: newHpackEncoder(tableSize),
    knownReceivedCount: 0,
    lowestUnackedIndex: 0,
    dynamicTableCapacity: uint64(tableSize),
    maxEntries: 0,  # 動的に計算
    insertCount: 0,
    blockedStreams: blockedStreams
  )

# QPACKデコーダー
proc newQpackDecoder*(tableSize: int = 4096, blockedStreams: int = 100): QpackDecoder =
  result = QpackDecoder(
    baseDecoder: newHpackDecoder(tableSize),
    maxDynamicTableCapacity: uint64(tableSize),
    maxBlockedStreams: blockedStreams,
    insertCount: 0,
    knownReceivedCount: 0,
    blockedStreams: @[]
  )

# 整数のエンコード (RFC 9204, Section 4.1.1)
proc encodeQpackInt(value: uint64, prefixBits: int): seq[byte] =
  return encodeInteger(int(value), prefixBits)

# 整数のデコード
proc decodeQpackInt(data: openArray[byte], index: var int, prefixBits: int): uint64 =
  return uint64(decodeInteger(data, index, prefixBits))

# フィールドラインのエンコード (RFC 9204, Section 4.5)
proc encodeFieldLine(name, value: string, useHuffman: bool): seq[byte] =
  var result: seq[byte] = @[]
  
  # ヘッダー名のエンコード
  let nameBytes = encodeString(name.toLowerAscii(), useHuffman)
  for b in nameBytes:
    result.add(b)
  
  # ヘッダー値のエンコード
  let valueBytes = encodeString(value, useHuffman)
  for b in valueBytes:
    result.add(b)
  
  return result

# プレフィックスのエンコード
proc encodePrefix(encoder: QpackEncoder, requiredInsertCount: uint64, baseIndex: int): seq[byte] =
  var result: seq[byte] = @[]
  
  # Required Insert Count (RFC 9204, Section 4.5.1)
  let encRequired = encodeQpackInt(requiredInsertCount, 8)
  result.add(encRequired[0])
  for i in 1 ..< encRequired.len:
    result.add(encRequired[i])
  
  # Sign bit (S) と Base Index (RFC 9204, Section 4.5.1)
  let encBaseIndex = encodeQpackInt(uint64(abs(baseIndex)), 7)
  let signBit = if baseIndex < 0: byte(0x80) else: byte(0x00)
  result.add(encBaseIndex[0] or signBit)
  for i in 1 ..< encBaseIndex.len:
    result.add(encBaseIndex[i])
  
  return result

# ヘッダーのエンコード
proc encodeHeaders*(encoder: QpackEncoder, headers: seq[tuple[name: string, value: string]]): string =
  # QPACK圧縮
  # この簡易版では、動的テーブルを使用せず、静的テーブルとリテラル表現のみを使用
  
  var prefixBytes: seq[byte] = @[]
  var headersBytes: seq[byte] = @[]
  
  # プレフィックス (RFC 9204, Section 4.5.1)
  # Required Insert Count = 0（動的テーブルを使用しない）
  # Base = 0（動的テーブル参照なし）
  prefixBytes.add(0x00)  # Required Insert Count = 0
  prefixBytes.add(0x00)  # Base = 0
  
  # ヘッダーフィールドのエンコード
  for (name, value) in headers:
    let lowerName = name.toLowerAscii()
    
    # 静的テーブルで完全一致を検索
    let fullIndex = findIndexedHeader(lowerName, value, true)
    
    if fullIndex > 0:
      # インデックス付きヘッダーフィールド (静的テーブル参照)
      headersBytes.add(byte(0x80) or byte(fullIndex))
    else:
      # 名前のインデックスを検索
      let nameIndex = findIndexedHeaderName(lowerName, true)
      
      if nameIndex > 0:
        # リテラルヘッダーフィールド（静的テーブル名前参照）
        headersBytes.add(byte(0x50) or byte(min(nameIndex, 15)))
        if nameIndex >= 15:
          let remaining = encodeQpackInt(uint64(nameIndex - 15), 8)
          for b in remaining:
            headersBytes.add(b)
        
        # 値をエンコード（非Huffman）
        let valueBytes = encodeString(value, false)
        for b in valueBytes:
          headersBytes.add(b)
      else:
        # リテラルヘッダーフィールド（名前も値もリテラル）
        headersBytes.add(0x20)  # 0010 0000 - リテラル名前・値
        
        # 名前と値をエンコード
        let fieldLineBytes = encodeFieldLine(lowerName, value, false)
        for b in fieldLineBytes:
          headersBytes.add(b)
  
  # プレフィックスとヘッダーブロックの結合
  var allBytes: seq[byte] = @[]
  for b in prefixBytes:
    allBytes.add(b)
  for b in headersBytes:
    allBytes.add(b)
  
  # バイト列を文字列に変換
  result = ""
  for b in allBytes:
    result.add(char(b))

# ヘッダーのデコード
proc decodeHeaders*(decoder: QpackDecoder, data: string): seq[tuple[name: string, value: string]] =
  if data.len < 2:
    return @[]  # データが短すぎる
  
  result = @[]
  var i = 0
  
  # プレフィックスのデコード (RFC 9204, Section 4.5.1)
  let requiredInsertCount = decodeQpackInt(cast[seq[byte]](data), i, 8)
  let baseSign = (byte(data[i]) and 0x80) != 0
  let deltaBase = decodeQpackInt(cast[seq[byte]](data), i, 7)
  
  let baseIndex = if baseSign: -(int(deltaBase)) else: int(deltaBase)
  
  # ヘッダーフィールドのデコード
  while i < data.len:
    let b = byte(data[i])
    
    if (b and 0x80) != 0:
      # インデックス付きヘッダーフィールド (RFC 9204, Section 4.5.2)
      let staticBit = (b and 0x40) != 0
      let index = if staticBit: decodeQpackInt(cast[seq[byte]](data), i, 6)
                 else: decodeQpackInt(cast[seq[byte]](data), i, 6)
      
      if staticBit and index <= StaticTable.len.uint64:
        # 静的テーブル参照
        result.add(StaticTable[index.int - 1])
      else:
        # 動的テーブル参照（簡易版では処理しない）
        discard
    
    elif (b and 0x40) != 0:
      # リテラルヘッダーフィールド（名前参照）(RFC 9204, Section 4.5.3)
      let staticBit = (b and 0x10) != 0
      let nameIdx = decodeQpackInt(cast[seq[byte]](data), i, 4)
      var name: string
      
      if staticBit and nameIdx <= StaticTable.len.uint64:
        name = StaticTable[nameIdx.int - 1].name
      else:
        # 動的テーブル参照（簡易版では処理しない）
        name = "unknown"
      
      # 値のデコード
      let value = decodeString(cast[seq[byte]](data), i)
      
      result.add((name, value))
    
    else:
      # リテラルヘッダーフィールド（新規名前）(RFC 9204, Section 4.5.4)
      inc(i)  # ヘッダーバイトをスキップ
      
      let name = decodeString(cast[seq[byte]](data), i)
      let value = decodeString(cast[seq[byte]](data), i)
      
      result.add((name, value))
  
  return result 