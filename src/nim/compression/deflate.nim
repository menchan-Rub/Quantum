# DEFLATE Compression Implementation
#
# RFC 1951に準拠したDeflate圧縮/解凍の実装

import std/[streams, zlib]

# データのDeflate圧縮
proc compressDeflate*(data: string, level: int = -1): string =
  ## データをDeflate形式で圧縮する
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  ## 
  ## Returns:
  ## - Deflate形式で圧縮されたデータ
  
  # デフォルトではzlibのdeflateサポートを使用
  result = zlib.compress(data, level, DEFLATE)

# Deflateデータの解凍
proc decompressDeflate*(data: string): string =
  ## Deflate形式で圧縮されたデータを解凍する
  ## 
  ## Parameters:
  ## - data: 解凍するDeflate圧縮データ
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  # デフォルトではzlibのdeflateサポートを使用
  result = zlib.uncompress(data, DEFLATE)

# ストリームからDeflateデータを読み込んで解凍
proc decompressDeflateStream*(input: Stream): string =
  ## Deflateストリームを読み込んで解凍する
  ## 
  ## Parameters:
  ## - input: 読み込むDeflate圧縮データを含むストリーム
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  # ストリームから全データを読み込み
  let compressed = input.readAll()
  
  # 解凍
  result = decompressDeflate(compressed)

# ファイルからDeflateデータを読み込んで解凍
proc decompressDeflateFile*(filename: string): string =
  ## Deflateファイルを読み込んで解凍する
  ## 
  ## Parameters:
  ## - filename: 読み込むDeflateファイルのパス
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  var file = newFileStream(filename, fmRead)
  if file == nil:
    raise newException(IOError, "Could not open the file: " & filename)
  
  defer: file.close()
  
  result = decompressDeflateStream(file)

# ストリームにDeflate圧縮データを書き込む
proc compressDeflateToStream*(data: string, output: Stream, level: int = -1) =
  ## データをDeflate形式で圧縮してストリームに書き込む
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - output: 圧縮データを書き込むストリーム
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  
  let compressed = compressDeflate(data, level)
  output.write(compressed)

# ファイルにDeflate圧縮データを書き込む
proc compressDeflateToFile*(data: string, filename: string, level: int = -1) =
  ## データをDeflate形式で圧縮してファイルに書き込む
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - filename: 圧縮データを書き込むファイルパス
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  
  var file = newFileStream(filename, fmWrite)
  if file == nil:
    raise newException(IOError, "Could not open the file for writing: " & filename)
  
  defer: file.close()
  
  compressDeflateToStream(data, file, level)

# RAWデータのDeflate圧縮
proc compressDeflateRaw*(data: string, level: int = -1): string =
  ## データをRAW Deflate形式で圧縮する（zlib/gzipヘッダーなし）
  ## 
  ## Parameters:
  ## - data: 圧縮する元データ
  ## - level: 圧縮レベル（-1 = デフォルト, 0 = 無圧縮, 9 = 最大圧縮）
  ## 
  ## Returns:
  ## - RAW Deflate形式で圧縮されたデータ
  
  # デフォルトではzlibのRAW Deflateサポートを使用
  result = zlib.compress(data, level, RAW_DEFLATE)

# RAW Deflateデータの解凍
proc decompressDeflateRaw*(data: string): string =
  ## RAW Deflate形式で圧縮されたデータを解凍する（zlib/gzipヘッダーなし）
  ## 
  ## Parameters:
  ## - data: 解凍するRAW Deflate圧縮データ
  ## 
  ## Returns:
  ## - 解凍されたデータ
  
  # デフォルトではzlibのRAW Deflateサポートを使用
  result = zlib.uncompress(data, RAW_DEFLATE) 