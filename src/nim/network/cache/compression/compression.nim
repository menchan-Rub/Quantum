import std/[times, strutils, options, tables, os]
import zip/zlib

type
  CompressionType* = enum
    ctNone,     # 圧縮なし
    ctGzip,     # gzip圧縮
    ctDeflate,  # deflate圧縮
    ctBrotli    # brotli圧縮（未実装）

  CompressionLevel* = enum
    clNone = 0,       # 圧縮なし
    clFastest = 1,    # 最速（低圧縮率）
    clFast = 3,       # 高速（中低圧縮率）
    clDefault = 6,    # デフォルト（バランス）
    clBest = 9        # 最高圧縮率（低速）

  CompressionConfig* = object
    ## 圧縮設定
    enabled*: bool                # 圧縮を有効にするかどうか
    defaultType*: CompressionType # デフォルトの圧縮タイプ
    level*: CompressionLevel      # 圧縮レベル
    minSizeToCompress*: int       # 圧縮する最小サイズ（バイト）
    excludedTypes*: seq[string]   # 圧縮しないMIMEタイプ

  CompressionResult* = object
    ## 圧縮結果
    success*: bool               # 圧縮に成功したかどうか
    originalSize*: int           # 元のサイズ（バイト）
    compressedSize*: int         # 圧縮後のサイズ（バイト）
    compressionRatio*: float     # 圧縮率（元のサイズに対する割合）
    data*: string                # 圧縮後のデータ
    compressionType*: CompressionType  # 使用した圧縮タイプ

proc newCompressionConfig*(
  enabled: bool = true,
  defaultType: CompressionType = ctGzip,
  level: CompressionLevel = clDefault,
  minSizeToCompress: int = 1024,  # 1KB
  excludedTypes: seq[string] = @["image/", "video/", "audio/", "application/octet-stream"]
): CompressionConfig =
  ## 新しい圧縮設定を作成する
  result = CompressionConfig(
    enabled: enabled,
    defaultType: defaultType,
    level: level,
    minSizeToCompress: minSizeToCompress,
    excludedTypes: excludedTypes
  )

proc shouldCompress*(config: CompressionConfig, contentType: string, contentLength: int): bool =
  ## 圧縮すべきかどうかを判断する
  if not config.enabled:
    return false
  
  # サイズが小さすぎる場合は圧縮しない
  if contentLength < config.minSizeToCompress:
    return false
  
  # 既に圧縮されているタイプは圧縮しない
  if contentType.startsWith("image/") or 
     contentType.startsWith("video/") or 
     contentType.startsWith("audio/") or
     contentType == "application/octet-stream" or
     contentType.endsWith("+gzip") or
     contentType.endsWith("+deflate") or
     contentType.endsWith("+br"):
    return false
  
  # 除外タイプをチェック
  for excludedType in config.excludedTypes:
    if contentType.startsWith(excludedType):
      return false
  
  return true

proc determineCompressionType*(config: CompressionConfig, acceptEncoding: string): CompressionType =
  ## Accept-Encodingヘッダーに基づいて最適な圧縮タイプを決定する
  if acceptEncoding.len == 0:
    return ctNone
  
  # Accept-Encodingヘッダーをパースして圧縮タイプとquality値のマッピングを作成
  var compressionPreferences: Table[string, float] = initTable[string, float]()
  let encodings = acceptEncoding.toLowerAscii().split(',')
  
  for encoding in encodings:
    var e = encoding.strip()
    var quality: float = 1.0
    
    # quality値が指定されている場合（例: gzip;q=0.8）
    if e.contains(';'):
      let parts = e.split(';')
      e = parts[0].strip()
      
      for param in parts[1..^1]:
        let kvPair = param.strip().split('=')
        if kvPair.len == 2 and kvPair[0].strip() == "q":
          try:
            quality = parseFloat(kvPair[1].strip())
          except ValueError:
            quality = 1.0
    
    # 有効なエンコーディングのみテーブルに追加
    if e in ["gzip", "deflate", "br", "zstd"]:
      compressionPreferences[e] = quality
  
  # サポートされていない、またはq=0の圧縮タイプを除外
  for encoding, quality in compressionPreferences.mpairs:
    if quality <= 0.0:
      compressionPreferences.del(encoding)
  
  # 圧縮タイプが指定されていない場合
  if compressionPreferences.len == 0:
    return ctNone
  
  # 設定で指定された優先圧縮タイプがクライアントでサポートされている場合はそれを使用
  case config.defaultType:
  of ctBrotli:
    if "br" in compressionPreferences:
      return ctBrotli
  of ctGzip:
    if "gzip" in compressionPreferences:
      return ctGzip
  of ctDeflate:
    if "deflate" in compressionPreferences:
      return ctDeflate
  of ctZstd:
    if "zstd" in compressionPreferences:
      return ctZstd
  else:
    discard
  
  # quality値に基づいて最適な圧縮タイプを選択
  var bestEncoding: string = ""
  var bestQuality: float = -1.0
  
  for encoding, quality in compressionPreferences.pairs:
    if quality > bestQuality:
      bestQuality = quality
      bestEncoding = encoding
  
  # 最適な圧縮タイプを返す
  case bestEncoding:
  of "br": return ctBrotli
  of "gzip": return ctGzip
  of "deflate": return ctDeflate
  of "zstd": return ctZstd
  else: return ctNone

proc compressData*(data: string, compressionType: CompressionType, level: CompressionLevel = clDefault): CompressionResult =
  ## データを圧縮する
  result.originalSize = data.len
  result.compressionType = compressionType
  
  if data.len == 0:
    result.success = false
    result.data = data
    result.compressedSize = 0
    result.compressionRatio = 1.0
    return
  
  case compressionType
  of ctNone:
    # 圧縮なし
    result.success = true
    result.data = data
    result.compressedSize = data.len
    result.compressionRatio = 1.0
  
  of ctGzip:
    try:
      # gzip圧縮
      let compressedData = compress(data, level=level.int, GZIP)
      result.success = true
      result.data = compressedData
      result.compressedSize = compressedData.len
      result.compressionRatio = if data.len > 0: compressedData.len.float / data.len.float else: 1.0
    except:
      # 圧縮に失敗した場合
      result.success = false
      result.data = data
      result.compressedSize = data.len
      result.compressionRatio = 1.0
  
  of ctDeflate:
    try:
      # deflate圧縮
      let compressedData = compress(data, level=level.int)
      result.success = true
      result.data = compressedData
      result.compressedSize = compressedData.len
      result.compressionRatio = if data.len > 0: compressedData.len.float / data.len.float else: 1.0
    except:
      # 圧縮に失敗した場合
      result.success = false
      result.data = data
      result.compressedSize = data.len
      result.compressionRatio = 1.0
  
  of ctBrotli:
    try:
      # Brotli圧縮の実装
      import brotli
      
      # 圧縮レベルをBrotli用に変換（0-11）
      let brotliLevel = case level:
        of clFastest: 0
        of clFast: 2
        of clDefault: 6
        of clBest: 11
        else: 6
      
      let compressedData = brotliCompress(data, quality=brotliLevel)
      result.success = true
      result.data = compressedData
      result.compressedSize = compressedData.len
      result.compressionRatio = if data.len > 0: compressedData.len.float / data.len.float else: 1.0
    except:
      # 圧縮に失敗した場合
      result.success = false
      result.data = data
      result.compressedSize = data.len
      result.compressionRatio = 1.0
  
  of ctZstd:
    try:
      # Zstandard圧縮の実装
      import zstd
      
      # 圧縮レベルをZstd用に変換（1-22）
      let zstdLevel = case level:
        of clFastest: 1
        of clFast: 3
        of clDefault: 9
        of clBest: 19
        else: 9
      
      let compressedData = compress(data, level=zstdLevel)
      result.success = true
      result.data = compressedData
      result.compressedSize = compressedData.len
      result.compressionRatio = if data.len > 0: compressedData.len.float / data.len.float else: 1.0
    except:
      # 圧縮に失敗した場合
      result.success = false
      result.data = data
      result.compressedSize = data.len
      result.compressionRatio = 1.0

proc decompressData*(data: string, compressionType: CompressionType): string =
  ## 圧縮データを展開する
  if data.len == 0:
    return ""
  
  case compressionType
  of ctNone:
    # 圧縮なし
    return data
  
  of ctGzip:
    try:
      # gzip展開
      return uncompress(data, GZIP)
    except:
      # 展開に失敗した場合
      return data
  
  of ctDeflate:
    try:
      # deflate展開
      return uncompress(data)
    except:
      # 展開に失敗した場合
      return data
  
  of ctBrotli:
    try:
      # Brotli展開の実装
      import brotli
      return brotliDecompress(data)
    except:
      # 展開に失敗した場合
      return data
  
  of ctZstd:
    try:
      # Zstandard展開の実装
      import zstd
      return decompress(data)
    except:
      # 展開に失敗した場合
      return data

proc getEncodingHeader*(compressionType: CompressionType): string =
  ## 圧縮タイプに対応するContent-Encodingヘッダー値を取得する
  case compressionType
  of ctNone:
    return ""
  of ctGzip:
    return "gzip"
  of ctDeflate:
    return "deflate"
  of ctBrotli:
    return "br"

proc compressForCache*(config: CompressionConfig, content: string, contentType: string, acceptEncoding: string = "gzip, deflate"): tuple[data: string, encoding: string, compressed: bool] =
  ## キャッシュ用にコンテンツを圧縮する
  ## 戻り値: (圧縮されたデータ, Content-Encodingヘッダー値, 圧縮されたかどうか)
  
  # 圧縮すべきかどうかを判断
  if not shouldCompress(config, contentType, content.len):
    return (content, "", false)
  
  # 圧縮タイプを決定
  let compressionType = determineCompressionType(config, acceptEncoding)
  if compressionType == ctNone:
    return (content, "", false)
  
  # 圧縮を実行
  let compressionResult = compressData(content, compressionType, config.level)
  
  # 圧縮に失敗した場合や圧縮効率が悪い場合は元のデータを返す
  if not compressionResult.success or compressionResult.compressionRatio >= 0.9:
    return (content, "", false)
  
  # 圧縮に成功した場合
  return (compressionResult.data, getEncodingHeader(compressionType), true)

when isMainModule:
  # テスト用のメイン関数
  proc testCompression() =
    echo "圧縮モジュールのテスト"
    
    # 圧縮設定を作成
    let config = newCompressionConfig()
    
    # テスト用のデータ
    let testData = "Hello, World!".repeat(100)  # 繰り返して少し大きめのデータを作成
    
    # 圧縮すべきかどうかのテスト
    echo "text/htmlを圧縮すべき？: ", shouldCompress(config, "text/html", testData.len)
    echo "image/jpegを圧縮すべき？: ", shouldCompress(config, "image/jpeg", testData.len)
    
    # 圧縮タイプの決定テスト
    echo "Accept-Encoding: gzip, deflate, br の圧縮タイプ: ", determineCompressionType(config, "gzip, deflate, br")
    
    # 圧縮と展開のテスト
    let compressionResult = compressData(testData, ctGzip)
    echo "元のサイズ: ", compressionResult.originalSize, " バイト"
    echo "圧縮後のサイズ: ", compressionResult.compressedSize, " バイト"
    echo "圧縮率: ", compressionResult.compressionRatio * 100, "%"
    
    # 展開テスト
    let decompressed = decompressData(compressionResult.data, ctGzip)
    echo "展開後のサイズ: ", decompressed.len, " バイト"
    echo "元のデータと一致？: ", decompressed == testData
    
    # キャッシュ用圧縮のテスト
    let (compressedData, encoding, compressed) = compressForCache(config, testData, "text/html")
    echo "キャッシュ用圧縮: ", if compressed: "成功" else: "不要"
    if compressed:
      echo "エンコーディング: ", encoding
      echo "圧縮後のサイズ: ", compressedData.len, " バイト"
  
  # テスト実行
  testCompression() 