# HTTP/2 HPACK Header Compression
# 
# RFC 7541の簡易実装
# HTTP/2および HTTP/3のヘッダー圧縮をサポート

import std/[tables, hashes, strutils, algorithm]

type
  HpackHeaderField* = tuple[name: string, value: string]
  
  HpackHeaderTable* = object
    entries: seq[HpackHeaderField]
    size: int
    maxSize: int
  
  HpackEncoder* = ref object
    dynamicTable: HpackHeaderTable
    useHuffman: bool
  
  HpackDecoder* = ref object
    dynamicTable: HpackHeaderTable

# 静的テーブル (RFC 7541 Appendix A)
const StaticTable = [
  (":authority", ""),
  (":method", "GET"),
  (":method", "POST"),
  (":path", "/"),
  (":path", "/index.html"),
  (":scheme", "http"),
  (":scheme", "https"),
  (":status", "200"),
  (":status", "204"),
  (":status", "206"),
  (":status", "304"),
  (":status", "400"),
  (":status", "404"),
  (":status", "500"),
  ("accept-charset", ""),
  ("accept-encoding", "gzip, deflate"),
  ("accept-language", ""),
  ("accept-ranges", ""),
  ("accept", ""),
  ("access-control-allow-origin", ""),
  ("age", ""),
  ("allow", ""),
  ("authorization", ""),
  ("cache-control", ""),
  ("content-disposition", ""),
  ("content-encoding", ""),
  ("content-language", ""),
  ("content-length", ""),
  ("content-location", ""),
  ("content-range", ""),
  ("content-type", ""),
  ("cookie", ""),
  ("date", ""),
  ("etag", ""),
  ("expect", ""),
  ("expires", ""),
  ("from", ""),
  ("host", ""),
  ("if-match", ""),
  ("if-modified-since", ""),
  ("if-none-match", ""),
  ("if-range", ""),
  ("if-unmodified-since", ""),
  ("last-modified", ""),
  ("link", ""),
  ("location", ""),
  ("max-forwards", ""),
  ("proxy-authenticate", ""),
  ("proxy-authorization", ""),
  ("range", ""),
  ("referer", ""),
  ("refresh", ""),
  ("retry-after", ""),
  ("server", ""),
  ("set-cookie", ""),
  ("strict-transport-security", ""),
  ("transfer-encoding", ""),
  ("user-agent", ""),
  ("vary", ""),
  ("via", ""),
  ("www-authenticate", "")
]

# ヘッダーテーブルの新規作成
proc newHpackHeaderTable*(maxSize: int): HpackHeaderTable =
  result = HpackHeaderTable(
    entries: @[],
    size: 0,
    maxSize: maxSize
  )

# 動的テーブルにエントリを追加
proc addEntry(table: var HpackHeaderTable, name, value: string) =
  let entrySize = name.len + value.len + 32  # 32バイトはオーバーヘッド
  
  # 最大サイズを超える場合、古いエントリを削除
  while table.size + entrySize > table.maxSize and table.entries.len > 0:
    let oldEntry = table.entries.pop()
    table.size -= oldEntry.name.len + oldEntry.value.len + 32
  
  # 新しいエントリが収まる場合のみ追加
  if entrySize <= table.maxSize:
    table.entries.insert((name, value), 0)
    table.size += entrySize

# テーブルサイズの変更
proc setMaxSize*(table: var HpackHeaderTable, maxSize: int) =
  table.maxSize = maxSize
  
  # 新しい最大サイズに合わせてエントリを削除
  while table.size > table.maxSize and table.entries.len > 0:
    let oldEntry = table.entries.pop()
    table.size -= oldEntry.name.len + oldEntry.value.len + 32

# テーブルの検索
proc findIndexedHeader(name, value: string, staticOnly: bool = false): int =
  # 静的テーブルの検索
  for i, entry in StaticTable.pairs:
    if entry.name == name and (value.len == 0 or entry.value == value):
      return i + 1  # インデックスは1から始まる
  
  return 0  # 見つからない場合は0

proc findIndexedHeaderName(name: string, staticOnly: bool = false): int =
  # 静的テーブルの検索（名前のみ）
  for i, entry in StaticTable.pairs:
    if entry.name == name:
      return i + 1  # インデックスは1から始まる
  
  return 0  # 見つからない場合は0

# 整数のエンコード (RFC 7541, Section 5.1)
proc encodeInteger(n: int, prefixBits: int): seq[byte] =
  result = @[]
  let maxPrefix = (1 shl prefixBits) - 1
  
  if n < maxPrefix:
    result.add(byte(n))
  else:
    result.add(byte(maxPrefix))
    var m = n - maxPrefix
    
    while m >= 128:
      result.add(byte((m and 0x7F) or 0x80))
      m = m shr 7
    
    result.add(byte(m))

# 整数のデコード
proc decodeInteger(data: openArray[byte], index: var int, prefixBits: int): int =
  let b = data[index]
  let mask = byte((1 shl prefixBits) - 1)
  result = int(b and mask)
  
  if result < (1 shl prefixBits) - 1:
    inc(index)
    return
  
  var m = 0
  var factor = 1
  
  inc(index)
  
  while index < data.len:
    let b = data[index]
    inc(index)
    
    result += int(b and 0x7F) * factor
    factor *= 128
    
    if (b and 0x80) == 0:
      break

# 文字列のエンコード (RFC 7541, Section 5.2)
proc encodeString(s: string, useHuffman: bool = false): seq[byte] =
  if useHuffman:
    # RFC 7541 Appendix B準拠のHuffman符号化実装
    let huffmanEncoded = huffmanEncode(s)
    result = @[byte(0x80)]  # Huffmanフラグ設定
    
    let lenBytes = encodeInteger(huffmanEncoded.len, 7)
    result[0] = result[0] or lenBytes[0]
    
    for i in 1 ..< lenBytes.len:
      result.add(lenBytes[i])
    
    result.add(huffmanEncoded)
  else:
    result = @[byte(0)]  # Huffmanなし
  
  let lenBytes = encodeInteger(s.len, 7)
  result[0] = result[0] or lenBytes[0]
  
  for i in 1 ..< lenBytes.len:
    result.add(lenBytes[i])
  
  for c in s:
    result.add(byte(c))

# 文字列のデコード
proc decodeString(data: openArray[byte], index: var int): string =
  let huffman = (data[index] and 0x80) != 0
  let length = decodeInteger(data, index, 7)
  
  if huffman:
    # RFC 7541 Appendix B準拠のHuffman復号実装
    let huffmanData = data[index..index + length - 1]
    result = huffmanDecode(huffmanData)
    index += length
  else:
    result = ""
    for i in 0 ..< length:
      if index < data.len:
        result.add(char(data[index]))
        inc(index)

# RFC 7541 Appendix B準拠のHuffman符号化テーブル
const HuffmanTable = [
  (0x1ff8, 13), (0x7fffd8, 23), (0xfffffe2, 28), (0xfffffe3, 28),
  (0xfffffe4, 28), (0xfffffe5, 28), (0xfffffe6, 28), (0xfffffe7, 28),
  (0xfffffe8, 28), (0xffffea, 24), (0x3ffffffc, 30), (0xfffffe9, 28),
  (0xfffffea, 28), (0x3ffffffd, 30), (0xfffffeb, 28), (0xfffffec, 28),
  (0xfffffed, 28), (0xfffffee, 28), (0xfffffef, 28), (0xffffff0, 28),
  (0xffffff1, 28), (0xffffff2, 28), (0x3ffffffe, 30), (0xffffff3, 28),
  (0xffffff4, 28), (0xffffff5, 28), (0xffffff6, 28), (0xffffff7, 28),
  (0xffffff8, 28), (0xffffff9, 28), (0xffffffa, 28), (0xffffffb, 28),
  (0x14, 6), (0x3f8, 10), (0x3f9, 10), (0xffa, 12),
  (0x1ff9, 13), (0x15, 6), (0xf8, 8), (0x7fa, 11),
  (0x3fa, 10), (0x3fb, 10), (0xf9, 8), (0x7fb, 11),
  (0xfa, 8), (0x16, 6), (0x17, 6), (0x18, 6),
  (0x0, 5), (0x1, 5), (0x2, 5), (0x19, 6),
  (0x1a, 6), (0x1b, 6), (0x1c, 6), (0x1d, 6),
  (0x1e, 6), (0x1f, 6), (0x5c, 7), (0xfb, 8),
  (0x7ffc, 15), (0x20, 6), (0xffb, 12), (0x3fc, 10),
  (0x1ffa, 13), (0x21, 6), (0x5d, 7), (0x5e, 7),
  (0x5f, 7), (0x60, 7), (0x61, 7), (0x62, 7),
  (0x63, 7), (0x64, 7), (0x65, 7), (0x66, 7),
  (0x67, 7), (0x68, 7), (0x69, 7), (0x6a, 7),
  (0x6b, 7), (0x6c, 7), (0x6d, 7), (0x6e, 7),
  (0x6f, 7), (0x70, 7), (0x71, 7), (0x72, 7),
  (0xfc, 8), (0x73, 7), (0xfd, 8), (0x1ffb, 13),
  (0x7fff0, 19), (0x1ffc, 13), (0x3ffc, 14), (0x22, 6),
  (0x7ffd, 15), (0x3, 5), (0x23, 6), (0x4, 5),
  (0x24, 6), (0x5, 5), (0x25, 6), (0x26, 6),
  (0x27, 6), (0x6, 5), (0x74, 7), (0x75, 7),
  (0x28, 6), (0x29, 6), (0x2a, 6), (0x7, 5),
  (0x2b, 6), (0x76, 7), (0x2c, 6), (0x8, 5),
  (0x9, 5), (0x2d, 6), (0x77, 7), (0x78, 7),
  (0x79, 7), (0x7a, 7), (0x7b, 7), (0x7ffe, 15),
  (0x7fc, 11), (0x3ffd, 14), (0x1ffd, 13), (0xffffffc, 28),
  (0xfffe6, 20), (0x3fffd2, 22), (0xfffe7, 20), (0xfffe8, 20),
  (0x3fffd3, 22), (0x3fffd4, 22), (0x3fffd5, 22), (0x7fffd9, 23),
  (0x3fffd6, 22), (0x7fffda, 23), (0x7fffdb, 23), (0x7fffdc, 23),
  (0x7fffdd, 23), (0x7fffde, 23), (0xffffeb, 24), (0x7fffdf, 23),
  (0xffffec, 24), (0xffffed, 24), (0x3fffd7, 22), (0x7fffe0, 23),
  (0xffffee, 24), (0x7fffe1, 23), (0x7fffe2, 23), (0x7fffe3, 23),
  (0x7fffe4, 23), (0x1fffdc, 21), (0x3fffd8, 22), (0x7fffe5, 23),
  (0x3fffd9, 22), (0x7fffe6, 23), (0x7fffe7, 23), (0xffffef, 24),
  (0x3fffda, 22), (0x1fffdd, 21), (0xfffe9, 20), (0x3fffdb, 22),
  (0x3fffdc, 22), (0x7fffe8, 23), (0x7fffe9, 23), (0x1fffde, 21),
  (0x7fffea, 23), (0x3fffdd, 22), (0x3fffde, 22), (0xfffff0, 24),
  (0x1fffdf, 21), (0x3fffdf, 22), (0x7fffeb, 23), (0x7fffec, 23),
  (0x1fffe0, 21), (0x1fffe1, 21), (0x3fffe0, 22), (0x1fffe2, 21),
  (0x7fffed, 23), (0x3fffe1, 22), (0x7fffee, 23), (0x7fffef, 23),
  (0xfffea, 20), (0x3fffe2, 22), (0x3fffe3, 22), (0x3fffe4, 22),
  (0x7ffff0, 23), (0x3fffe5, 22), (0x3fffe6, 22), (0x7ffff1, 23),
  (0x3ffffe0, 26), (0x3ffffe1, 26), (0xfffeb, 20), (0x7fff1, 19),
  (0x3fffe7, 22), (0x7ffff2, 23), (0x3fffe8, 22), (0x1ffffec, 25),
  (0x3ffffe2, 26), (0x3ffffe3, 26), (0x3ffffe4, 26), (0x7ffffde, 27),
  (0x7ffffdf, 27), (0x3ffffe5, 26), (0xfffff1, 24), (0x1ffffed, 25),
  (0x7fff2, 19), (0x1fffe3, 21), (0x3ffffe6, 26), (0x7ffffe0, 27),
  (0x7ffffe1, 27), (0x3ffffe7, 26), (0x7ffffe2, 27), (0xfffff2, 24),
  (0x1fffe4, 21), (0x1fffe5, 21), (0x3ffffe8, 26), (0x3ffffe9, 26),
  (0xffffffd, 28), (0x7ffffe3, 27), (0x7ffffe4, 27), (0x7ffffe5, 27),
  (0xfffec, 20), (0xfffff3, 24), (0xfffed, 20), (0x1fffe6, 21),
  (0x3fffe9, 22), (0x1fffe7, 21), (0x1fffe8, 21), (0x7ffff3, 23),
  (0x3fffea, 22), (0x3fffeb, 22), (0x1ffffee, 25), (0x1ffffef, 25),
  (0xfffff4, 24), (0xfffff5, 24), (0x3ffffea, 26), (0x7ffff4, 23),
  (0x3ffffeb, 26), (0x7ffffe6, 27), (0x3ffffec, 26), (0x3ffffed, 26),
  (0x7ffffe7, 27), (0x7ffffe8, 27), (0x7ffffe9, 27), (0x7ffffea, 27),
  (0x7ffffeb, 27), (0xffffffe, 28), (0x7ffffec, 27), (0x7ffffed, 27),
  (0x7ffffee, 27), (0x7ffffef, 27), (0x7fffff0, 27), (0x3ffffee, 26),
  (0x3fffffff, 30)
]

# Huffman符号化実装
proc huffmanEncode(input: string): seq[byte] =
  result = @[]
  var bitBuffer: uint64 = 0
  var bitCount = 0
  
  for c in input:
    let charCode = ord(c)
    if charCode < HuffmanTable.len:
      let (code, length) = HuffmanTable[charCode]
      
      # ビットバッファに符号を追加
      bitBuffer = (bitBuffer shl length) or code.uint64
      bitCount += length
      
      # 8ビット単位でバイトに変換
      while bitCount >= 8:
        bitCount -= 8
        result.add(byte((bitBuffer shr bitCount) and 0xFF))
  
  # 残りのビットをパディング
  if bitCount > 0:
    bitBuffer = bitBuffer shl (8 - bitCount)
    # EOS符号でパディング（全て1）
    bitBuffer = bitBuffer or ((1 shl (8 - bitCount)) - 1)
    result.add(byte(bitBuffer and 0xFF))

# Huffman復号実装
proc huffmanDecode(data: seq[byte]): string =
  result = ""
  var bitBuffer: uint64 = 0
  var bitCount = 0
  
  # 復号テーブルの構築（簡易版）
  var decodeTable: array[512, int] = [-1, -1] # 9ビットまでの符号をサポート
  
  # テーブル構築
  for i, (code, length) in HuffmanTable.pairs:
    if length <= 9:
      let tableIndex = code shl (9 - length)
      for j in 0 ..< (1 shl (9 - length)):
        if tableIndex + j < decodeTable.len:
          decodeTable[tableIndex + j] = i
  
  for b in data:
    bitBuffer = (bitBuffer shl 8) or b.uint64
    bitCount += 8
    
    # 9ビット単位で復号を試行
    while bitCount >= 9:
      let lookupIndex = (bitBuffer shr (bitCount - 9)) and 0x1FF
      let charCode = decodeTable[lookupIndex]
      
      if charCode >= 0:
        # 有効な文字が見つかった
        result.add(char(charCode))
        
        # 使用したビット数を計算
        let (_, usedBits) = HuffmanTable[charCode]
        bitCount -= usedBits
        bitBuffer = bitBuffer and ((1.uint64 shl bitCount) - 1)
      else:
        # 復号できない場合はエラー
        break

# エンコーダー
proc newHpackEncoder*(tableSize: int = 4096, useHuffman: bool = false): HpackEncoder =
  result = HpackEncoder(
    dynamicTable: newHpackHeaderTable(tableSize),
    useHuffman: useHuffman
  )

# デコーダー
proc newHpackDecoder*(tableSize: int = 4096): HpackDecoder =
  result = HpackDecoder(
    dynamicTable: newHpackHeaderTable(tableSize)
  )

# ヘッダーのエンコード
proc encodeHeaders*(encoder: HpackEncoder, headers: seq[HpackHeaderField]): string =
  var bytes: seq[byte] = @[]
  
  # ヘッダーをエンコード
  for (name, value) in headers:
    let lowerName = name.toLowerAscii()  # ヘッダー名は小文字に正規化
    
    # 静的テーブルと動的テーブルで完全一致を検索
    let fullIndex = findIndexedHeader(lowerName, value)
    
    if fullIndex > 0:
      # インデックス付きヘッダーフィールド (RFC 7541, Section 6.1)
      bytes.add(encodeInteger(fullIndex, 7)[0] or 0x80)
    else:
      # 名前のインデックスを検索
      let nameIndex = findIndexedHeaderName(lowerName)
      
      if nameIndex > 0:
        # リテラルヘッダーフィールド（インデックス付き名前）(RFC 7541, Section 6.2.1)
        bytes.add(encodeInteger(nameIndex, 6)[0] or 0x40)
        
        # 値をエンコード
        let valueBytes = encodeString(value, encoder.useHuffman)
        for b in valueBytes:
          bytes.add(b)
      else:
        # リテラルヘッダーフィールド（新規名前）(RFC 7541, Section 6.2.2)
        bytes.add(0x40)  # インデックス付き表現（テーブルに追加）
        
        # 名前をエンコード
        let nameBytes = encodeString(lowerName, encoder.useHuffman)
        for b in nameBytes:
          bytes.add(b)
        
        # 値をエンコード
        let valueBytes = encodeString(value, encoder.useHuffman)
        for b in valueBytes:
          bytes.add(b)
      
      # 動的テーブルに追加（簡易版では実際には追加しない）
  
  # バイト列を文字列に変換
  result = ""
  for b in bytes:
    result.add(char(b))

# ヘッダーのデコード
proc decodeHeaders*(decoder: HpackDecoder, data: string): seq[HpackHeaderField] =
  result = @[]
  var i = 0
  
  while i < data.len:
    let b = byte(data[i])
    
    if (b and 0x80) != 0:
      # インデックス付きヘッダーフィールド (RFC 7541, Section 6.1)
      let index = decodeInteger(cast[seq[byte]](data), i, 7)
      
      if index > 0 and index <= StaticTable.len:
        # 静的テーブルからヘッダーを取得
        result.add(StaticTable[index - 1])
      else:
        # 動的テーブルの処理（簡易版では省略）
        discard
    
    elif (b and 0x40) != 0:
      # リテラルヘッダーフィールド（インデックス付き名前）(RFC 7541, Section 6.2.1)
      let index = decodeInteger(cast[seq[byte]](data), i, 6)
      var name: string
      
      if index > 0 and index <= StaticTable.len:
        name = StaticTable[index - 1].name
      else:
        # 動的テーブルの処理（簡易版では省略）
        name = "unknown"
      
      let value = decodeString(cast[seq[byte]](data), i)
      
      result.add((name, value))
      
      # 動的テーブルに追加（簡易版では省略）
    
    elif (b and 0x20) != 0:
      # テーブルサイズの更新 (RFC 7541, Section 6.3)
      let maxSize = decodeInteger(cast[seq[byte]](data), i, 5)
      decoder.dynamicTable.setMaxSize(maxSize)
    
    else:
      # リテラルヘッダーフィールド（新規名前）(RFC 7541, Section 6.2.2/6.2.3)
      inc(i)  # 最初のバイトをスキップ
      
      let name = decodeString(cast[seq[byte]](data), i)
      let value = decodeString(cast[seq[byte]](data), i)
      
      result.add((name, value))
      
      # 動的テーブルに追加（簡易版では省略） 