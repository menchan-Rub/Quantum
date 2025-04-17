# gzip.nim
## gzip圧縮・解凍機能を提供するモジュール
## RFC 1952 (GZIP file format specification)に準拠した実装

import std/[streams, zlib, times, hashes, strutils, os]

type
  GzipCompressionLevel* = enum
    gzNone = 0,        ## 圧縮なし
    gzBestSpeed = 1,   ## 最速（低圧縮率）
    gzFast = 3,        ## 高速
    gzDefault = 6,     ## デフォルト圧縮率
    gzHighCompression = 8, ## 高圧縮率
    gzBestCompression = 9  ## 最高圧縮率（低速）

  GzipHeader* = object
    modificationTime*: Time  ## ファイルの最終更新時間
    fileName*: string        ## 元のファイル名（省略可）
    comment*: string         ## ファイルコメント（省略可）
    extraFields*: seq[(uint8, string)] ## 追加フィールド（ID, データ）

  GzipOption* = object
    level*: GzipCompressionLevel ## 圧縮レベル
    header*: GzipHeader          ## GZIPヘッダー情報

  GzipError* = object of CatchableError

const
  GZIP_ID1: uint8 = 0x1F
  GZIP_ID2: uint8 = 0x8B
  GZIP_DEFLATE_METHOD: uint8 = 8
  
  # フラグ定義
  FTEXT: uint8 = 0x01
  FHCRC: uint8 = 0x02
  FEXTRA: uint8 = 0x04
  FNAME: uint8 = 0x08
  FCOMMENT: uint8 = 0x10
  
  # デフォルト設定
  DEFAULT_BUFFER_SIZE = 8192

proc newGzipOption*(level: GzipCompressionLevel = gzDefault): GzipOption =
  ## デフォルトのGzip圧縮オプションを作成
  result = GzipOption(
    level: level,
    header: GzipHeader(
      modificationTime: getTime(),
      fileName: "",
      comment: "",
      extraFields: @[]
    )
  )

proc zlibCompressionLevel(level: GzipCompressionLevel): int =
  ## GzipCompressionLevelをzlibのレベルに変換
  case level
  of gzNone: Z_NO_COMPRESSION
  of gzBestSpeed: Z_BEST_SPEED
  of gzFast: 3
  of gzDefault: Z_DEFAULT_COMPRESSION
  of gzHighCompression: 8
  of gzBestCompression: Z_BEST_COMPRESSION

proc writeGzipHeader(s: Stream, header: GzipHeader) =
  ## GZIPヘッダーをストリームに書き込む
  var flags: uint8 = 0
  
  # マジックナンバーとメソッド
  s.write(GZIP_ID1)
  s.write(GZIP_ID2)
  s.write(GZIP_DEFLATE_METHOD)
  
  # フラグの計算
  if header.fileName.len > 0:
    flags = flags or FNAME
  if header.comment.len > 0:
    flags = flags or FCOMMENT
  if header.extraFields.len > 0:
    flags = flags or FEXTRA
  
  # フラグを書き込む
  s.write(flags)
  
  # 修正時間（UNIX時間）
  let mtime = uint32(header.modificationTime.toUnixFloat())
  s.write(mtime)
  
  # 追加フラグとOS (デフォルト値)
  s.write(uint8(0)) # 追加フラグ
  s.write(uint8(255)) # 不明なOS
  
  # 拡張フィールド
  if (flags and FEXTRA) != 0:
    var extraLen = 0
    for (_, data) in header.extraFields:
      extraLen += data.len + 2 # ID(2バイト) + データ長
    
    s.write(uint16(extraLen))
    for (id, data) in header.extraFields:
      s.write(id)
      s.write(uint16(data.len))
      s.writeData(data.cstring, data.len)
  
  # ファイル名 (存在する場合)
  if (flags and FNAME) != 0:
    s.writeData(header.fileName.cstring, header.fileName.len)
    s.write(uint8(0)) # null終端
  
  # コメント (存在する場合)
  if (flags and FCOMMENT) != 0:
    s.writeData(header.comment.cstring, header.comment.len)
    s.write(uint8(0)) # null終端

proc readGzipHeader*(s: Stream): GzipHeader =
  ## GZIPヘッダーをストリームから読み込む
  var id1 = s.readUint8()
  var id2 = s.readUint8()
  
  if id1 != GZIP_ID1 or id2 != GZIP_ID2:
    raise newException(GzipError, "無効なGZIPマジックナンバー")
  
  let method = s.readUint8()
  if method != GZIP_DEFLATE_METHOD:
    raise newException(GzipError, "サポートされていない圧縮メソッド: " & $method)
  
  let flags = s.readUint8()
  let mtime = s.readUint32()
  
  # 修正時間を取得
  let modTime = fromUnixFloat(float(mtime))
  
  # 追加フラグとOSは読み飛ばす
  discard s.readUint8() # 追加フラグ
  discard s.readUint8() # OS
  
  var header = GzipHeader(modificationTime: modTime)
  
  # 拡張フィールドの処理
  if (flags and FEXTRA) != 0:
    let extraLen = s.readUint16()
    var bytesRead: uint16 = 0
    var extraFields: seq[(uint8, string)] = @[]
    
    while bytesRead < extraLen:
      let id = s.readUint8()
      let len = s.readUint16()
      bytesRead += 3 # ID + 長さフィールド
      
      var data = newString(len)
      discard s.readData(data.cstring, len)
      bytesRead += len
      
      extraFields.add((id, data))
    
    header.extraFields = extraFields
  
  # ファイル名の処理
  if (flags and FNAME) != 0:
    var fileName = ""
    var c = s.readChar()
    while c != '\0':
      fileName.add(c)
      c = s.readChar()
    header.fileName = fileName
  
  # コメントの処理
  if (flags and FCOMMENT) != 0:
    var comment = ""
    var c = s.readChar()
    while c != '\0':
      comment.add(c)
      c = s.readChar()
    header.comment = comment
  
  # ヘッダーCRCは現在スキップ
  if (flags and FHCRC) != 0:
    discard s.readUint16() # CRCスキップ
  
  result = header

proc compress*(input: string, options: GzipOption = newGzipOption()): string =
  ## 文字列をgzip形式に圧縮する
  var outStream = newStringStream()
  
  # GZIPヘッダーを書き込む
  writeGzipHeader(outStream, options.header)
  
  # 元データのCRC32とサイズを計算
  let crc = crc32(cstring(input), input.len)
  let isize = uint32(input.len) and 0xFFFFFFFF # 32ビットで切り捨て
  
  # zlib deflateでデータを圧縮
  var compressedData = compress(input, zlibCompressionLevel(options.level))
  
  # zlib独自のヘッダーとフッターを削除 (2バイトのヘッダーと4バイトのADLER32チェックサム)
  compressedData = compressedData[2..^5]
  
  # 圧縮データを書き込む
  outStream.write(compressedData)
  
  # フッター：CRC32とISize
  outStream.write(crc)
  outStream.write(isize)
  
  # 結果を返す
  outStream.setPosition(0)
  result = outStream.readAll()
  outStream.close()

proc decompress*(input: string): string =
  ## gzip圧縮された文字列を解凍する
  var inStream = newStringStream(input)
  
  # ヘッダーを読み込む
  discard readGzipHeader(inStream)
  
  # 圧縮データの開始位置
  let dataStart = inStream.getPosition()
  
  # 圧縮データの終了位置（CRC32とISizeを除く）
  inStream.setPosition(input.len - 8)
  let expectedCrc = inStream.readUint32()
  let expectedSize = inStream.readUint32()
  
  # 圧縮されたデータを取得
  inStream.setPosition(dataStart)
  let compressedData = inStream.readStr(input.len - dataStart - 8)
  
  # zlibヘッダーを追加して解凍
  let zlibHeader = @[0x78.char, 0x9C.char] # Zlibデフォルトヘッダー
  let zlibFooter = @[0x00.char, 0x00.char, 0x00.char, 0x00.char] # ダミーADLER32
  
  let zlibData = zlibHeader.join("") & compressedData & zlibFooter.join("")
  var decompressed = uncompress(zlibData)
  
  # 整合性チェック
  if decompressed.len != int(expectedSize):
    raise newException(GzipError, "解凍後のサイズが不一致: 期待値 " & $expectedSize & ", 実際 " & $decompressed.len)
  
  let actualCrc = crc32(cstring(decompressed), decompressed.len)
  if actualCrc != expectedCrc:
    raise newException(GzipError, "CRC32チェックサムエラー: 期待値 " & toHex(int(expectedCrc)) & ", 実際 " & toHex(int(actualCrc)))
  
  inStream.close()
  return decompressed

proc compressFile*(inputFile, outputFile: string, options: GzipOption = newGzipOption()) =
  ## ファイルをgzip圧縮する
  var opt = options
  
  # ファイル名が設定されていない場合は入力ファイル名を使用
  if opt.header.fileName.len == 0:
    opt.header.fileName = splitFile(inputFile).name
  
  # 入力ファイルを読み込む
  let inData = readFile(inputFile)
  
  # 圧縮してファイルに保存
  let compressedData = compress(inData, opt)
  writeFile(outputFile, compressedData)

proc decompressFile*(inputFile, outputFile: string) =
  ## gzip圧縮されたファイルを解凍する
  let compressedData = readFile(inputFile)
  let decompressedData = decompress(compressedData)
  writeFile(outputFile, decompressedData)

proc compressStream*(input, output: Stream, options: GzipOption = newGzipOption(), bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## ストリームをgzip圧縮する（大きなデータ向け）
  # GZIPヘッダーを書き込む
  writeGzipHeader(output, options.header)
  
  # zlibのdeflateストリームを初期化
  var strm: z_stream
  var windowBits = -MAX_WBITS # 負の値を指定すると生のdeflateストリームを生成
  
  # 初期化
  if deflateInit2(strm, zlibCompressionLevel(options.level), 
                  Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY) != Z_OK:
    raise newException(GzipError, "zlibの初期化に失敗しました")
  
  # CRC32を計算するための変数
  var crc: uint32 = 0
  var totalSize: uint32 = 0
  
  # バッファを確保
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  
  # データを読み込みながら圧縮
  var bytesRead = input.readData(inBuf[0].addr, bufferSize)
  while bytesRead > 0:
    # CRCとサイズを更新
    crc = crc32(crc, cast[ptr uint8](inBuf[0].addr), bytesRead)
    totalSize += uint32(bytesRead)
    
    # 圧縮処理
    strm.avail_in = bytesRead.cuint
    strm.next_in = cast[ptr cuchar](inBuf[0].addr)
    
    var flush = if bytesRead < bufferSize: Z_FINISH else: Z_NO_FLUSH
    
    # 出力バッファが空になるまで繰り返す
    while true:
      strm.avail_out = bufferSize.cuint
      strm.next_out = cast[ptr cuchar](outBuf[0].addr)
      
      # 圧縮を実行
      let ret = deflate(strm, flush)
      
      # 圧縮したデータを書き込む
      let have = bufferSize - int(strm.avail_out)
      if have > 0:
        output.writeData(outBuf[0].addr, have)
      
      # バッファが空になったか、または終了条件を満たした場合
      if strm.avail_out > 0:
        break
    
    # 次のデータを読み込む
    bytesRead = input.readData(inBuf[0].addr, bufferSize)
  
  # zlibストリームを終了
  discard deflateEnd(strm)
  
  # フッター（CRC32とサイズ）を書き込む
  output.write(crc)
  output.write(totalSize)

proc decompressStream*(input, output: Stream, bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## gzip圧縮されたストリームを解凍する（大きなデータ向け）
  # ヘッダーを読み込む
  discard readGzipHeader(input)
  
  # zlibのinflateストリームを初期化
  var strm: z_stream
  var windowBits = -MAX_WBITS # 負の値を指定すると生のdeflateストリームを解析
  
  # 初期化
  if inflateInit2(strm, windowBits) != Z_OK:
    raise newException(GzipError, "zlibの初期化に失敗しました")
  
  # バッファを確保
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  
  # CRCとサイズをチェックするための変数
  var crc: uint32 = 0
  var totalSize: uint32 = 0
  
  # 最後の8バイト（CRC32とISize）を除く全データを処理
  var inputSize = input.getSize()
  var footerPosition = inputSize - 8
  
  # CRC32とISizeを読み込む
  input.setPosition(footerPosition)
  let expectedCrc = input.readUint32()
  let expectedSize = input.readUint32()
  
  # 先頭に戻る
  input.setPosition(input.getPosition() - 8)
  
  # データを読み込みながら解凍
  var bytesRead = input.readData(inBuf[0].addr, min(bufferSize, footerPosition - input.getPosition()))
  while bytesRead > 0:
    # 解凍処理
    strm.avail_in = bytesRead.cuint
    strm.next_in = cast[ptr cuchar](inBuf[0].addr)
    
    # 出力バッファが空になるまで繰り返す
    while strm.avail_in > 0:
      strm.avail_out = bufferSize.cuint
      strm.next_out = cast[ptr cuchar](outBuf[0].addr)
      
      # 解凍を実行
      let ret = inflate(strm, Z_NO_FLUSH)
      if ret != Z_OK and ret != Z_STREAM_END:
        discard inflateEnd(strm)
        raise newException(GzipError, "解凍に失敗しました: " & $ret)
      
      # 解凍したデータを書き込み、CRCを更新
      let have = bufferSize - int(strm.avail_out)
      if have > 0:
        output.writeData(outBuf[0].addr, have)
        crc = crc32(crc, cast[ptr uint8](outBuf[0].addr), have)
        totalSize += uint32(have)
    
    # 次のデータを読み込む
    if input.getPosition() < footerPosition:
      bytesRead = input.readData(inBuf[0].addr, min(bufferSize, footerPosition - input.getPosition()))
    else:
      break
  
  # zlibストリームを終了
  discard inflateEnd(strm)
  
  # 整合性チェック
  if totalSize != expectedSize:
    raise newException(GzipError, "解凍後のサイズが不一致: 期待値 " & $expectedSize & ", 実際 " & $totalSize)
  
  if crc != expectedCrc:
    raise newException(GzipError, "CRC32チェックサムエラー: 期待値 " & toHex(int(expectedCrc)) & ", 実際 " & toHex(int(crc))) 