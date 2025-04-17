# test_compression.nim
## 圧縮機能のテストモジュール

import std/[os, times, strformat, strutils, tables]
import common/compression_base
import gzip/gzip
import brotli/brotli
import zstd/zstd

proc formatSize(size: int): string =
  ## ファイルサイズを読みやすく整形
  if size < 1024:
    return $size & " B"
  elif size < 1024 * 1024:
    return fmt"{size / 1024:.2f} KB"
  else:
    return fmt"{size / (1024 * 1024):.2f} MB"

proc formatRatio(compressedSize, originalSize: int): string =
  ## 圧縮率を計算して整形
  let ratio = compressedSize.float / originalSize.float
  return fmt"{ratio * 100:.2f}%"

proc timeOperation(op: proc): float =
  ## 操作の実行時間を計測
  let startTime = epochTime()
  op()
  let endTime = epochTime()
  return (endTime - startTime) * 1000

proc testCompression(inputData: string, name: string) =
  ## 各圧縮アルゴリズムをテスト
  let originalSize = inputData.len
  echo fmt"テスト対象: {name} (サイズ: {formatSize(originalSize)})"
  echo "=".repeat(60)
  
  var results = newTable[string, tuple[size: int, ratio: float, compressTime, decompressTime: float]]()
  
  # gzip圧縮テスト
  block:
    var compressed: string
    let compressTime = timeOperation(proc() =
      compressed = gzip.compress(inputData, newGzipOption(level = gzBestCompression))
    )
    
    var decompressed: string
    let decompressTime = timeOperation(proc() =
      decompressed = gzip.decompress(compressed)
    )
    
    # 検証
    doAssert decompressed == inputData, "gzip解凍後のデータが元と一致しない"
    
    results["gzip"] = (compressed.len, compressed.len.float / originalSize.float, compressTime, decompressTime)
  
  # brotli圧縮テスト
  block:
    var compressed: string
    let compressTime = timeOperation(proc() =
      compressed = brotli.compress(inputData, newBrotliOption(quality = 11))
    )
    
    var decompressed: string
    let decompressTime = timeOperation(proc() =
      decompressed = brotli.decompress(compressed)
    )
    
    # 検証
    doAssert decompressed == inputData, "brotli解凍後のデータが元と一致しない"
    
    results["brotli"] = (compressed.len, compressed.len.float / originalSize.float, compressTime, decompressTime)
  
  # zstd圧縮テスト
  block:
    var compressed: string
    let compressTime = timeOperation(proc() =
      compressed = zstd.compress(inputData, newZstdOption(level = 19))
    )
    
    var decompressed: string
    let decompressTime = timeOperation(proc() =
      decompressed = zstd.decompress(compressed)
    )
    
    # 検証
    doAssert decompressed == inputData, "zstd解凍後のデータが元と一致しない"
    
    results["zstd"] = (compressed.len, compressed.len.float / originalSize.float, compressTime, decompressTime)
  
  # 結果表示
  echo fmt"アルゴリズム  | 圧縮サイズ | 圧縮率    | 圧縮時間  | 解凍時間  "
  echo fmt"------------|-----------|-----------|-----------|----------"
  
  for algo, res in results:
    echo fmt"{algo:<12} | {formatSize(res.size):<9} | {formatRatio(res.size, originalSize):<9} | {res.compressTime:.2f} ms | {res.decompressTime:.2f} ms"
  
  echo ""

proc testCompressionRatios() =
  ## 異なるタイプのデータに対する圧縮率テスト
  echo "==================== 圧縮テスト ===================="
  
  # テキストデータ
  let textData = readFile("README.md")
  testCompression(textData, "テキストデータ（README.md）")
  
  # HTMLデータ
  var htmlData = """
  <!DOCTYPE html>
  <html>
  <head>
    <title>圧縮テスト</title>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
      body {
        font-family: Arial, sans-serif;
        margin: 0;
        padding: 20px;
        background-color: #f5f5f5;
      }
      .container {
        max-width: 800px;
        margin: 0 auto;
        background-color: white;
        padding: 20px;
        border-radius: 5px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      }
      h1 {
        color: #333;
        border-bottom: 1px solid #eee;
        padding-bottom: 10px;
      }
      p {
        line-height: 1.6;
        color: #666;
      }
    </style>
  </head>
  <body>
    <div class="container">
      <h1>圧縮アルゴリズムテスト</h1>
      <p>このページは異なる圧縮アルゴリズムのテストに使用されます。HTMLは構造化されたテキストデータの典型的な例です。</p>
      <p>圧縮アルゴリズムは一般的に、繰り返しパターンを見つけてより効率的な表現に置き換えることで動作します。</p>
      <h2>テスト対象のアルゴリズム</h2>
      <ul>
        <li>gzip - 広く使われている圧縮形式</li>
        <li>brotli - Googleが開発した新しい圧縮アルゴリズム</li>
        <li>zstd - Facebookが開発した高速で効率的な圧縮アルゴリズム</li>
      </ul>
    </div>
  </body>
  </html>
  """
  testCompression(htmlData, "HTMLデータ")
  
  # ランダムデータ (圧縮しにくい)
  var randomData = newString(10000)
  for i in 0 ..< randomData.len:
    randomData[i] = char(rand(255))
  testCompression(randomData, "ランダムデータ")
  
  # 繰り返しパターン (圧縮しやすい)
  var repeatedData = "abcdefghijklmnopqrstuvwxyz".repeat(1000)
  testCompression(repeatedData, "繰り返しパターン")

proc testStreamCompression() =
  ## ストリーム圧縮のテスト
  echo "==================== ストリーム圧縮テスト ===================="
  
  # テストデータ作成
  let testDir = getTempDir() / "compression_test"
  removeDir(testDir)
  createDir(testDir)
  
  # 大きなファイルを生成
  let testFile = testDir / "large_file.txt"
  let compressedFile = testDir / "compressed_file"
  let decompressedFile = testDir / "decompressed_file.txt"
  
  var f = open(testFile, fmWrite)
  for i in 0 ..< 10000:
    f.writeLine("テストデータ行 #" & $i & " " & "abcdefghijklmnopqrstuvwxyz".repeat(10))
  f.close()
  
  # ファイルサイズ
  let originalSize = getFileSize(testFile)
  echo fmt"作成したテストファイル: {formatSize(originalSize)}"
  
  # gzipストリーム圧縮テスト
  block:
    echo "\ngzipストリーム圧縮テスト:"
    let inStream = newFileStream(testFile, fmRead)
    let outStream = newFileStream(compressedFile & ".gz", fmWrite)
    
    let compressTime = timeOperation(proc() =
      gzip.compressStream(inStream, outStream)
    )
    
    inStream.close()
    outStream.close()
    
    # 解凍
    let inStream2 = newFileStream(compressedFile & ".gz", fmRead)
    let outStream2 = newFileStream(decompressedFile, fmWrite)
    
    let decompressTime = timeOperation(proc() =
      gzip.decompressStream(inStream2, outStream2)
    )
    
    inStream2.close()
    outStream2.close()
    
    # ファイルサイズと圧縮率
    let compressedSize = getFileSize(compressedFile & ".gz")
    
    echo fmt"圧縮サイズ: {formatSize(compressedSize)}"
    echo fmt"圧縮率: {formatRatio(compressedSize, originalSize)}"
    echo fmt"圧縮時間: {compressTime:.2f} ms"
    echo fmt"解凍時間: {decompressTime:.2f} ms"
    
    # 元ファイルと解凍後のファイルを比較
    doAssert readFile(testFile) == readFile(decompressedFile), "gzipストリーム解凍後のデータが元と一致しない"
  
  # brotliストリーム圧縮テスト
  block:
    echo "\nbrotliストリーム圧縮テスト:"
    let inStream = newFileStream(testFile, fmRead)
    let outStream = newFileStream(compressedFile & ".br", fmWrite)
    
    let compressTime = timeOperation(proc() =
      brotli.compressStream(inStream, outStream)
    )
    
    inStream.close()
    outStream.close()
    
    # 解凍
    let inStream2 = newFileStream(compressedFile & ".br", fmRead)
    let outStream2 = newFileStream(decompressedFile, fmWrite)
    
    let decompressTime = timeOperation(proc() =
      brotli.decompressStream(inStream2, outStream2)
    )
    
    inStream2.close()
    outStream2.close()
    
    # ファイルサイズと圧縮率
    let compressedSize = getFileSize(compressedFile & ".br")
    
    echo fmt"圧縮サイズ: {formatSize(compressedSize)}"
    echo fmt"圧縮率: {formatRatio(compressedSize, originalSize)}"
    echo fmt"圧縮時間: {compressTime:.2f} ms"
    echo fmt"解凍時間: {decompressTime:.2f} ms"
    
    # 元ファイルと解凍後のファイルを比較
    doAssert readFile(testFile) == readFile(decompressedFile), "brotliストリーム解凍後のデータが元と一致しない"
  
  # zstdストリーム圧縮テスト
  block:
    echo "\nzstdストリーム圧縮テスト:"
    let inStream = newFileStream(testFile, fmRead)
    let outStream = newFileStream(compressedFile & ".zst", fmWrite)
    
    let compressTime = timeOperation(proc() =
      zstd.compressStream(inStream, outStream)
    )
    
    inStream.close()
    outStream.close()
    
    # 解凍
    let inStream2 = newFileStream(compressedFile & ".zst", fmRead)
    let outStream2 = newFileStream(decompressedFile, fmWrite)
    
    let decompressTime = timeOperation(proc() =
      zstd.decompressStream(inStream2, outStream2)
    )
    
    inStream2.close()
    outStream2.close()
    
    # ファイルサイズと圧縮率
    let compressedSize = getFileSize(compressedFile & ".zst")
    
    echo fmt"圧縮サイズ: {formatSize(compressedSize)}"
    echo fmt"圧縮率: {formatRatio(compressedSize, originalSize)}"
    echo fmt"圧縮時間: {compressTime:.2f} ms"
    echo fmt"解凍時間: {decompressTime:.2f} ms"
    
    # 元ファイルと解凍後のファイルを比較
    doAssert readFile(testFile) == readFile(decompressedFile), "zstdストリーム解凍後のデータが元と一致しない"
  
  # クリーンアップ
  removeDir(testDir)

when isMainModule:
  randomize()
  echo "圧縮アルゴリズムテスト開始"
  echo "===================================="
  
  # 圧縮率テスト
  testCompressionRatios()
  
  # ストリーム圧縮テスト
  testStreamCompression()
  
  echo "すべてのテストが成功しました！" 