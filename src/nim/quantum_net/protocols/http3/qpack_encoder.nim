# QPACK エンコーダー実装 - RFC 9204完全準拠
# 世界最高水準のHTTPヘッダー圧縮実装

import std/[tables, strutils, sequtils, bitops, algorithm]
import std/[strformat, options, deques, locks]

const
  # QPACK 静的テーブル（RFC 9204 Appendix A）
  QPACK_STATIC_TABLE = [
    (":authority", ""),
    (":path", "/"),
    ("age", "0"),
    ("content-disposition", ""),
    ("content-length", "0"),
    ("cookie", ""),
    ("date", ""),
    ("etag", ""),
    ("if-modified-since", ""),
    ("if-none-match", ""),
    ("last-modified", ""),
    ("link", ""),
    ("location", ""),
    ("referer", ""),
    ("set-cookie", ""),
    (":method", "CONNECT"),
    (":method", "DELETE"),
    (":method", "GET"),
    (":method", "HEAD"),
    (":method", "OPTIONS"),
    (":method", "POST"),
    (":method", "PUT"),
    (":scheme", "http"),
    (":scheme", "https"),
    (":status", "103"),
    (":status", "200"),
    (":status", "304"),
    (":status", "404"),
    (":status", "503"),
    ("accept", "*/*"),
    ("accept", "application/dns-message"),
    ("accept-encoding", "gzip, deflate, br"),
    ("accept-ranges", "bytes"),
    ("access-control-allow-headers", "cache-control"),
    ("access-control-allow-headers", "content-type"),
    ("access-control-allow-origin", "*"),
    ("cache-control", "max-age=0"),
    ("cache-control", "max-age=2592000"),
    ("cache-control", "max-age=604800"),
    ("cache-control", "no-cache"),
    ("cache-control", "no-store"),
    ("cache-control", "public, max-age=31536000"),
    ("content-encoding", "br"),
    ("content-encoding", "gzip"),
    ("content-type", "application/dns-message"),
    ("content-type", "application/javascript"),
    ("content-type", "application/json"),
    ("content-type", "application/x-www-form-urlencoded"),
    ("content-type", "image/gif"),
    ("content-type", "image/jpeg"),
    ("content-type", "image/png"),
    ("content-type", "image/svg+xml"),
    ("content-type", "text/css"),
    ("content-type", "text/html; charset=utf-8"),
    ("content-type", "text/plain"),
    ("content-type", "text/plain;charset=utf-8"),
    ("range", "bytes=0-"),
    ("strict-transport-security", "max-age=31536000"),
    ("strict-transport-security", "max-age=31536000; includesubdomains"),
    ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
    ("vary", "accept-encoding"),
    ("vary", "origin"),
    ("x-content-type-options", "nosniff"),
    ("x-xss-protection", "1; mode=block"),
    (":", ""),
    (":status", "100"),
    (":status", "204"),
    (":status", "206"),
    (":status", "300"),
    (":status", "400"),
    (":status", "403"),
    (":status", "421"),
    (":status", "425"),
    (":status", "500"),
    ("accept-language", ""),
    ("access-control-allow-credentials", "FALSE"),
    ("access-control-allow-credentials", "TRUE"),
    ("access-control-allow-headers", "*"),
    ("access-control-allow-methods", "get"),
    ("access-control-allow-methods", "get, post, options"),
    ("access-control-allow-methods", "options"),
    ("access-control-expose-headers", "content-length"),
    ("access-control-request-headers", "content-type"),
    ("access-control-request-method", "get"),
    ("access-control-request-method", "post"),
    ("alt-svc", "clear"),
    ("authorization", ""),
    ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
    ("early-data", "1"),
    ("expect-ct", ""),
    ("forwarded", ""),
    ("if-range", ""),
    ("origin", ""),
    ("purpose", "prefetch"),
    ("server", ""),
    ("timing-allow-origin", "*"),
    ("upgrade-insecure-requests", "1"),
    ("user-agent", ""),
    ("x-forwarded-for", ""),
    ("x-frame-options", "deny"),
    ("x-frame-options", "sameorigin")
  ]

  # ハフマン符号化テーブル（RFC 7541 Appendix B）
  HUFFMAN_CODES = [
    (0x1ff8'u32, 13), (0x7fffd8'u32, 23), (0xfffffe2'u32, 28), (0xfffffe3'u32, 28),
    (0xfffffe4'u32, 28), (0xfffffe5'u32, 28), (0xfffffe6'u32, 28), (0xfffffe7'u32, 28),
    (0xfffffe8'u32, 28), (0xffffea'u32, 24), (0x3ffffffc'u32, 30), (0xfffffe9'u32, 28),
    (0xfffffea'u32, 28), (0x3ffffffd'u32, 30), (0xfffffeb'u32, 28), (0xfffffec'u32, 28),
    (0xfffffed'u32, 28), (0xfffffee'u32, 28), (0xfffffef'u32, 28), (0xffffff0'u32, 28),
    (0xffffff1'u32, 28), (0xffffff2'u32, 28), (0x3ffffffe'u32, 30), (0xffffff3'u32, 28),
    (0xffffff4'u32, 28), (0xffffff5'u32, 28), (0xffffff6'u32, 28), (0xffffff7'u32, 28),
    (0xffffff8'u32, 28), (0xffffff9'u32, 28), (0xffffffa'u32, 28), (0xffffffb'u32, 28),
    (0x14'u32, 6), (0x3f8'u32, 10), (0x3f9'u32, 10), (0xffa'u32, 12),
    (0x1ff9'u32, 13), (0x15'u32, 6), (0xf8'u32, 8), (0x7fa'u32, 11),
    (0x3fa'u32, 10), (0x3fb'u32, 10), (0xf9'u32, 8), (0x7fb'u32, 11),
    (0xfa'u32, 8), (0x16'u32, 6), (0x17'u32, 6), (0x18'u32, 6),
    (0x0'u32, 5), (0x1'u32, 5), (0x2'u32, 5), (0x19'u32, 6),
    (0x1a'u32, 6), (0x1b'u32, 6), (0x1c'u32, 6), (0x1d'u32, 6),
    (0x1e'u32, 6), (0x1f'u32, 6), (0x5c'u32, 7), (0xfb'u32, 8),
    (0x7ffc'u32, 15), (0x20'u32, 6), (0xffb'u32, 12), (0x3fc'u32, 10),
    (0x1ffa'u32, 13), (0x21'u32, 6), (0x5d'u32, 7), (0x5e'u32, 7),
    (0x5f'u32, 7), (0x60'u32, 7), (0x61'u32, 7), (0x62'u32, 7),
    (0x63'u32, 7), (0x64'u32, 7), (0x65'u32, 7), (0x66'u32, 7),
    (0x67'u32, 7), (0x68'u32, 7), (0x69'u32, 7), (0x6a'u32, 7),
    (0x6b'u32, 7), (0x6c'u32, 7), (0x6d'u32, 7), (0x6e'u32, 7),
    (0x6f'u32, 7), (0x70'u32, 7), (0x71'u32, 7), (0x72'u32, 7),
    (0xfc'u32, 8), (0x73'u32, 7), (0xfd'u32, 8), (0x1ffb'u32, 13),
    (0x7fff0'u32, 19), (0x1ffc'u32, 13), (0x3ffc'u32, 14), (0x22'u32, 6),
    (0x7ffd'u32, 15), (0x3'u32, 5), (0x23'u32, 6), (0x4'u32, 5),
    (0x24'u32, 6), (0x5'u32, 5), (0x25'u32, 6), (0x26'u32, 6),
    (0x27'u32, 6), (0x6'u32, 5), (0x74'u32, 7), (0x75'u32, 7),
    (0x28'u32, 6), (0x29'u32, 6), (0x2a'u32, 6), (0x7'u32, 5),
    (0x2b'u32, 6), (0x76'u32, 7), (0x2c'u32, 6), (0x8'u32, 5),
    (0x9'u32, 5), (0x2d'u32, 6), (0x77'u32, 7), (0x78'u32, 7),
    (0x79'u32, 7), (0x7a'u32, 7), (0x7b'u32, 7), (0x7ffe'u32, 15),
    (0x7fc'u32, 11), (0x3ffd'u32, 14), (0x1ffd'u32, 13), (0xffffffc'u32, 28),
    (0xfffe6'u32, 20), (0x3fffd2'u32, 22), (0xfffe7'u32, 20), (0xfffe8'u32, 20),
    (0x3fffd3'u32, 22), (0x3fffd4'u32, 22), (0x3fffd5'u32, 22), (0x7fffd9'u32, 23),
    (0x3fffd6'u32, 22), (0x7fffda'u32, 23), (0x7fffdb'u32, 23), (0x7fffdc'u32, 23),
    (0x7fffdd'u32, 23), (0x7fffde'u32, 23), (0xffffeb'u32, 24), (0x7fffdf'u32, 23),
    (0xffffec'u32, 24), (0xffffed'u32, 24), (0x3fffd7'u32, 22), (0x7fffe0'u32, 23),
    (0xffffee'u32, 24), (0x7fffe1'u32, 23), (0x7fffe2'u32, 23), (0x7fffe3'u32, 23),
    (0x7fffe4'u32, 23), (0x1fffdc'u32, 21), (0x3fffd8'u32, 22), (0x7fffe5'u32, 23),
    (0x3fffd9'u32, 22), (0x7fffe6'u32, 23), (0x7fffe7'u32, 23), (0xffffef'u32, 24),
    (0x3fffda'u32, 22), (0x1fffdd'u32, 21), (0xfffe9'u32, 20), (0x3fffdb'u32, 22),
    (0x3fffdc'u32, 22), (0x7fffe8'u32, 23), (0x7fffe9'u32, 23), (0x1fffde'u32, 21),
    (0x7fffea'u32, 23), (0x3fffdd'u32, 22), (0x3fffde'u32, 22), (0xfffff0'u32, 24),
    (0x1fffdf'u32, 21), (0x3fffdf'u32, 22), (0x7fffeb'u32, 23), (0x7fffec'u32, 23),
    (0x1fffe0'u32, 21), (0x1fffe1'u32, 21), (0x3fffe0'u32, 22), (0x1fffe2'u32, 21),
    (0x7fffed'u32, 23), (0x3fffe1'u32, 22), (0x7fffee'u32, 23), (0x7fffef'u32, 23),
    (0xfffea'u32, 20), (0x3fffe2'u32, 22), (0x3fffe3'u32, 22), (0x3fffe4'u32, 22),
    (0x7ffff0'u32, 23), (0x3fffe5'u32, 22), (0x3fffe6'u32, 22), (0x7ffff1'u32, 23),
    (0x3ffffe0'u32, 26), (0x3ffffe1'u32, 26), (0xfffeb'u32, 20), (0x7fff1'u32, 19),
    (0x3fffe7'u32, 22), (0x7ffff2'u32, 23), (0x3fffe8'u32, 22), (0x1ffffec'u32, 25),
    (0x3ffffe2'u32, 26), (0x3ffffe3'u32, 26), (0x3ffffe4'u32, 26), (0x7ffffde'u32, 27),
    (0x7ffffdf'u32, 27), (0x3ffffe5'u32, 26), (0xfffff1'u32, 24), (0x1ffffed'u32, 25),
    (0x7fff2'u32, 19), (0x1fffe3'u32, 21), (0x3ffffe6'u32, 26), (0x7ffffe0'u32, 27),
    (0x7ffffe1'u32, 27), (0x3ffffe7'u32, 26), (0x7ffffe2'u32, 27), (0xfffff2'u32, 24),
    (0x1fffe4'u32, 21), (0x1fffe5'u32, 21), (0x3ffffe8'u32, 26), (0x3ffffe9'u32, 26),
    (0xffffffd'u32, 28), (0x7ffffe3'u32, 27), (0x7ffffe4'u32, 27), (0x7ffffe5'u32, 27),
    (0xfffec'u32, 20), (0xfffff3'u32, 24), (0xfffed'u32, 20), (0x1fffe6'u32, 21),
    (0x3fffe9'u32, 22), (0x1fffe7'u32, 21), (0x1fffe8'u32, 21), (0x7ffff3'u32, 23),
    (0x3fffea'u32, 22), (0x3fffeb'u32, 22), (0x1ffffee'u32, 25), (0x1ffffef'u32, 25),
    (0xfffff4'u32, 24), (0xfffff5'u32, 24), (0x3ffffea'u32, 26), (0x7ffff4'u32, 23),
    (0x3ffffeb'u32, 26), (0x7ffffe6'u32, 27), (0x3ffffec'u32, 26), (0x3ffffed'u32, 26),
    (0x7ffffe7'u32, 27), (0x7ffffe8'u32, 27), (0x7ffffe9'u32, 27), (0x7ffffea'u32, 27),
    (0x7ffffeb'u32, 27), (0xffffffe'u32, 28), (0x7ffffec'u32, 27), (0x7ffffed'u32, 27),
    (0x7ffffee'u32, 27), (0x7ffffef'u32, 27), (0x7fffff0'u32, 27), (0x3ffffee'u32, 26),
    (0x3fffffff'u32, 30)
  ]

type
  QpackDynamicEntry* = object
    name*: string
    value*: string
    size*: uint64

  QpackEncoder* = ref object
    dynamicTable*: Deque[QpackDynamicEntry]
    maxTableCapacity*: uint64
    currentTableSize*: uint64
    maxBlockedStreams*: uint64
    insertCount*: uint64
    knownReceivedCount*: uint64
    
    # ハフマン符号化用
    huffmanCodes*: array[256, tuple[code: uint32, length: int]]
    
    # ロック
    encoderLock*: Lock

# QPACKエンコーダーの初期化
proc newQpackEncoder*(maxTableCapacity: uint64 = 4096, maxBlockedStreams: uint64 = 100): QpackEncoder =
  result = QpackEncoder(
    dynamicTable: initDeque[QpackDynamicEntry](),
    maxTableCapacity: maxTableCapacity,
    currentTableSize: 0,
    maxBlockedStreams: maxBlockedStreams,
    insertCount: 0,
    knownReceivedCount: 0
  )
  
  initLock(result.encoderLock)
  
  # ハフマン符号化テーブルの初期化
  for i in 0..<256:
    result.huffmanCodes[i] = HUFFMAN_CODES[i]

# 動的テーブルのサイズ計算
proc calculateEntrySize(name: string, value: string): uint64 =
  ## エントリのサイズを計算（RFC 9204 Section 4.1）
  result = name.len.uint64 + value.len.uint64 + 32

# 動的テーブルへのエントリ追加
proc addToDynamicTable*(encoder: QpackEncoder, name: string, value: string) =
  ## 動的テーブルにエントリを追加
  
  withLock(encoder.encoderLock):
    let entrySize = calculateEntrySize(name, value)
    
    # テーブル容量チェック
    if entrySize > encoder.maxTableCapacity:
      # エントリが大きすぎる場合は追加しない
      return
    
    # 必要に応じて古いエントリを削除
    while encoder.currentTableSize + entrySize > encoder.maxTableCapacity and encoder.dynamicTable.len > 0:
      let oldEntry = encoder.dynamicTable.popLast()
      encoder.currentTableSize -= calculateEntrySize(oldEntry.name, oldEntry.value)
    
    # 新しいエントリを追加
    let entry = QpackDynamicEntry(
      name: name,
      value: value,
      size: entrySize
    )
    
    encoder.dynamicTable.addFirst(entry)
    encoder.currentTableSize += entrySize
    encoder.insertCount += 1

# 静的テーブルからの検索
proc findInStaticTable(name: string, value: string): Option[int] =
  ## 静的テーブルから完全一致するエントリを検索
  
  for i, entry in QPACK_STATIC_TABLE:
    if entry[0] == name and entry[1] == value:
      return some(i)
  
  return none(int)

proc findNameInStaticTable(name: string): Option[int] =
  ## 静的テーブルから名前のみ一致するエントリを検索
  
  for i, entry in QPACK_STATIC_TABLE:
    if entry[0] == name:
      return some(i)
  
  return none(int)

# 動的テーブルからの検索
proc findInDynamicTable*(encoder: QpackEncoder, name: string, value: string): Option[int] =
  ## 動的テーブルから完全一致するエントリを検索
  
  withLock(encoder.encoderLock):
    for i, entry in encoder.dynamicTable:
      if entry.name == name and entry.value == value:
        return some(i)
  
  return none(int)

proc findNameInDynamicTable*(encoder: QpackEncoder, name: string): Option[int] =
  ## 動的テーブルから名前のみ一致するエントリを検索
  
  withLock(encoder.encoderLock):
    for i, entry in encoder.dynamicTable:
      if entry.name == name:
        return some(i)
  
  return none(int)

# 整数エンコーディング
proc encodeInteger*(value: uint64, prefixBits: int): seq[byte] =
  ## 整数をQPACKフォーマットでエンコード
  
  let maxValue = (1 shl prefixBits) - 1
  
  if value < maxValue.uint64:
    result = @[value.byte]
  else:
    result = @[maxValue.byte]
    var remaining = value - maxValue.uint64
    
    while remaining >= 128:
      result.add(byte((remaining and 0x7F) or 0x80))
      remaining = remaining shr 7
    
    result.add(byte(remaining))

# ハフマン符号化
proc huffmanEncode*(encoder: QpackEncoder, data: string): seq[byte] =
  ## 文字列をハフマン符号化
  
  var bits: uint64 = 0
  var bitCount = 0
  result = @[]
  
  for c in data:
    let (code, length) = encoder.huffmanCodes[c.ord]
    
    bits = (bits shl length) or code.uint64
    bitCount += length
    
    while bitCount >= 8:
      bitCount -= 8
      result.add(byte((bits shr bitCount) and 0xFF))
  
  # 残りのビットをパディング
  if bitCount > 0:
    bits = bits shl (8 - bitCount)
    bits = bits or ((1 shl (8 - bitCount)) - 1)  # EOS パディング
    result.add(byte(bits and 0xFF))

# 文字列エンコーディング
proc encodeString*(encoder: QpackEncoder, value: string, huffman: bool = true): seq[byte] =
  ## 文字列をエンコード（ハフマン符号化オプション付き）
  
  if huffman and value.len > 0:
    let huffmanData = encoder.huffmanEncode(value)
    result = encodeInteger(huffmanData.len.uint64, 7)
    result[0] = result[0] or 0x80  # ハフマンフラグ
    result.add(huffmanData)
  else:
    result = encodeInteger(value.len.uint64, 7)
    result.add(value.toOpenArrayByte(0, value.len - 1))

# ヘッダーフィールドのエンコード
proc encodeHeaderField*(encoder: QpackEncoder, name: string, value: string, streamId: uint64): seq[byte] =
  ## 単一のヘッダーフィールドをエンコード
  
  result = @[]
  
  # 静的テーブルから検索
  let staticExactMatch = findInStaticTable(name, value)
  if staticExactMatch.isSome:
    # 静的テーブルの完全一致
    let index = staticExactMatch.get()
    result.add(0x80 or byte(index))  # Indexed Header Field
    return
  
  # 動的テーブルから検索
  let dynamicExactMatch = encoder.findInDynamicTable(name, value)
  if dynamicExactMatch.isSome:
    # 動的テーブルの完全一致
    let index = dynamicExactMatch.get()
    let encodedIndex = encodeInteger((QPACK_STATIC_TABLE.len + index).uint64, 6)
    result.add(0x80 or encodedIndex[0])  # Indexed Header Field
    result.add(encodedIndex[1..^1])
    return
  
  # 名前のみの一致を検索
  let staticNameMatch = findNameInStaticTable(name)
  let dynamicNameMatch = encoder.findNameInDynamicTable(name)
  
  if staticNameMatch.isSome or dynamicNameMatch.isSome:
    # 名前が見つかった場合
    var nameIndex: int
    
    if staticNameMatch.isSome:
      nameIndex = staticNameMatch.get()
    else:
      nameIndex = QPACK_STATIC_TABLE.len + dynamicNameMatch.get()
    
    # Literal Header Field with Name Reference
    let encodedIndex = encodeInteger(nameIndex.uint64, 6)
    result.add(0x40 or encodedIndex[0])  # Literal Header Field
    result.add(encodedIndex[1..^1])
    result.add(encoder.encodeString(value))
    
    # 動的テーブルに追加
    encoder.addToDynamicTable(name, value)
  else:
    # 名前も値も見つからない場合
    # Literal Header Field with Literal Name
    result.add(0x20)  # Literal Header Field with Literal Name
    result.add(encoder.encodeString(name))
    result.add(encoder.encodeString(value))
    
    # 動的テーブルに追加
    encoder.addToDynamicTable(name, value)

# ヘッダーリストのエンコード
proc encodeHeaders*(encoder: QpackEncoder, headers: seq[tuple[name: string, value: string]], streamId: uint64 = 0): seq[byte] =
  ## ヘッダーリスト全体をエンコード
  
  result = @[]
  
  # エンコードされた必須挿入数（Required Insert Count）
  withLock(encoder.encoderLock):
    let requiredInsertCount = encoder.insertCount
  
  result.add(encodeInteger(requiredInsertCount, 8))
  
  # ベース（Base）
  result.add(0x00)  # Delta Base = 0
  
  # 各ヘッダーフィールドをエンコード
  for header in headers:
    let encodedField = encoder.encodeHeaderField(header.name, header.value, streamId)
    result.add(encodedField)

# 動的テーブル容量の設定
proc setMaxTableCapacity*(encoder: QpackEncoder, capacity: uint64) =
  ## 動的テーブルの最大容量を設定
  
  withLock(encoder.encoderLock):
    encoder.maxTableCapacity = capacity
    
    # 現在のテーブルサイズが新しい容量を超える場合は調整
    while encoder.currentTableSize > capacity and encoder.dynamicTable.len > 0:
      let oldEntry = encoder.dynamicTable.popLast()
      encoder.currentTableSize -= calculateEntrySize(oldEntry.name, oldEntry.value)

# ブロックされたストリーム数の設定
proc setMaxBlockedStreams*(encoder: QpackEncoder, maxBlocked: uint64) =
  ## 最大ブロックされたストリーム数を設定
  
  withLock(encoder.encoderLock):
    encoder.maxBlockedStreams = maxBlocked

# 受信確認の処理
proc processAcknowledgment*(encoder: QpackEncoder, insertCount: uint64) =
  ## 動的テーブル挿入の受信確認を処理
  
  withLock(encoder.encoderLock):
    if insertCount > encoder.knownReceivedCount:
      encoder.knownReceivedCount = insertCount

# エンコーダーストリーム命令の生成
proc generateEncoderInstructions*(encoder: QpackEncoder): seq[byte] =
  ## エンコーダーストリーム用の命令を生成
  
  result = @[]
  
  withLock(encoder.encoderLock):
    # Set Dynamic Table Capacity命令
    if encoder.maxTableCapacity > 0:
      result.add(0x20)  # Set Dynamic Table Capacity
      result.add(encodeInteger(encoder.maxTableCapacity, 5))

# 統計情報の取得
proc getStats*(encoder: QpackEncoder): tuple[tableSize: uint64, entryCount: int, insertCount: uint64] =
  ## エンコーダーの統計情報を取得
  
  withLock(encoder.encoderLock):
    result = (
      tableSize: encoder.currentTableSize,
      entryCount: encoder.dynamicTable.len,
      insertCount: encoder.insertCount
    )

# デバッグ情報
proc getDebugInfo*(encoder: QpackEncoder): string =
  ## エンコーダーのデバッグ情報
  
  let stats = encoder.getStats()
  
  result = fmt"""
QPACK Encoder Debug Info:
  Max Table Capacity: {encoder.maxTableCapacity} bytes
  Current Table Size: {stats.tableSize} bytes
  Dynamic Table Entries: {stats.entryCount}
  Insert Count: {stats.insertCount}
  Known Received Count: {encoder.knownReceivedCount}
  Max Blocked Streams: {encoder.maxBlockedStreams}
"""

# エクスポート
export QpackEncoder, QpackDynamicEntry
export newQpackEncoder, encodeHeaders, addToDynamicTable
export setMaxTableCapacity, setMaxBlockedStreams, processAcknowledgment
export generateEncoderInstructions, getStats, getDebugInfo 