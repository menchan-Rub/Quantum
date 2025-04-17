# GZIP Compression Implementation
#
# RFC 1952に準拠したGZIP圧縮/解凍の実装

import std/[streams, zlib]

# データのGZIP圧縮
proc compressGzip*(data: string, level: int = -1): string =
  ## データをGZIP形式で圧縮する
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  ## 
  ## Returns:
  ## - GZIP形式で圧縮されたデータ
  
  # デフォルトではzlibのgzipサポートを使用
  result = zlib.compress(data, level, GZIP)

# GZIPデータの解凍
proc decompressGzip*(data: string): string =
  ## GZIP形式で圧縮されたデータを解凍する
  ## 
  ## Parameters:
  ## - data: 解凍するGZIP圧縮データ
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  # デフォルトではzlibのgzipサポートを使用
  result = zlib.uncompress(data, GZIP)

# ストリームからGZIPデータを読み込んで解凍
proc decompressGzipStream*(input: Stream): string =
  ## GZIPストリームを読み込んで解凍する
  ## 
  ## Parameters:
  ## - input: 読み込むGZIP圧縮データを含むストリーム
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  # ストリームの現在位置を保存
  let startPos = input.getPosition()
  
  # GZIPヘッダーを確認（マジックナンバー）
  var header = newString(2)
  discard input.readData(addr header[0], 2)
  
  if header[0].byte != 0x1F or header[1].byte != 0x8B:
    # GZIPフォーマットでない場合は元の位置に戻してエラー
    input.setPosition(startPos)
    raise newException(ValueError, "Not a GZIP format")
  
  # ストリームを先頭に戻す
  input.setPosition(startPos)
  
  # データを全て読み込む
  let compressed = input.readAll()
  
  # 解凍
  result = decompressGzip(compressed)

# ファイルからGZIPデータを読み込んで解凍
proc decompressGzipFile*(filename: string): string =
  ## GZIPファイルを読み込んで解凍する
  ## 
  ## Parameters:
  ## - filename: 読み込むGZIPファイルのパス
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  var file = newFileStream(filename, fmRead)
  if file == nil:
    raise newException(IOError, "Could not open the file: " & filename)
  
  defer: file.close()
  
  result = decompressGzipStream(file)

# ストリームにGZIP圧縮データを書き込む
proc compressGzipToStream*(data: string, output: Stream, level: int = -1) =
  ## データをGZIP形式で圧縮してストリームに書き込む
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - output: 圧縮データを書き込むストリーム
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  
  let compressed = compressGzip(data, level)
  output.write(compressed)

# ファイルにGZIP圧縮データを書き込む
proc compressGzipToFile*(data: string, filename: string, level: int = -1) =
  ## データをGZIP形式で圧縮してファイルに書き込む
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - filename: 圧縮データを書き込むファイルパス
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  
  var file = newFileStream(filename, fmWrite)
  if file == nil:
    raise newException(IOError, "Could not open the file for writing: " & filename)
  
  defer: file.close()
  
  compressGzipToStream(data, file, level) 