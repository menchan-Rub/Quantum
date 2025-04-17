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
    # Huffman符号化は省略（実際には実装する必要あり）
    # この簡易版では非圧縮形式のみサポート
    result = @[byte(0)]  # Huffmanなし
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
    # Huffman復号は省略（実際には実装する必要あり）
    # この簡易版では非圧縮形式のみ完全サポート
    result = ""
    for i in 0 ..< length:
      if index < data.len:
        result.add(char(data[index]))
        inc(index)
  else:
    result = ""
    for i in 0 ..< length:
      if index < data.len:
        result.add(char(data[index]))
        inc(index)

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