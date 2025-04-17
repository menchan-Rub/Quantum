# compression_base.nim
## 圧縮機能の共通基底クラスとエラー型を提供するモジュール

type
  CompressionError* = object of CatchableError
    ## 圧縮関連の基本エラークラス
    code*: int                ## エラーコード
    source*: string           ## エラー発生源
    details*: string          ## 詳細情報

  CompressionFormat* = enum
    ## サポートされる圧縮形式
    cfNone = 0,      ## 無圧縮
    cfGzip = 1,      ## gzip
    cfDeflate = 2,   ## deflate
    cfBrotli = 3,    ## brotli
    cfZstd = 4,      ## zstd
    cfLZ4 = 5,       ## LZ4
    cfLZMA = 6       ## LZMA/XZ

  CompressionDirection* = enum
    ## 圧縮処理の方向
    cdCompress,      ## 圧縮
    cdDecompress     ## 解凍

  CompressionLevel* = enum
    ## 汎用圧縮レベル（各アルゴリズム固有のレベルにマッピングされる）
    clNone = 0,           ## 圧縮なし
    clFastest = 1,        ## 最速（低圧縮率）
    clFast = 2,           ## 高速
    clDefault = 3,        ## デフォルト（バランス）
    clHighCompression = 4, ## 高圧縮率
    clMaximum = 5          ## 最高圧縮率（低速）

  CompressionStrategy* = enum
    ## 圧縮戦略（特定のデータタイプに最適化）
    csDefault = 0,        ## デフォルト戦略
    csFiltered = 1,       ## フィルタリングされたデータ向け
    csHuffmanOnly = 2,    ## Huffmanエンコーディングのみ
    csRLE = 3,            ## ランレングスエンコーディング向け
    csFixed = 4           ## 固定Huffmanコード

  CompressionDictionary* = ref object
    ## 圧縮辞書（学習データに基づく圧縮効率向上）
    data*: seq[byte]      ## 辞書データ
    id*: uint32           ## 辞書ID
    format*: CompressionFormat  ## 対応する圧縮形式

  CompressionContext* = ref object of RootObj
    ## 圧縮コンテキスト基底クラス
    format*: CompressionFormat  ## 使用する圧縮形式
    level*: CompressionLevel    ## 圧縮レベル
    strategy*: CompressionStrategy  ## 圧縮戦略
    windowBits*: int            ## ウィンドウサイズ（ビット）
    memLevel*: int              ## メモリ使用レベル
    dictionary*: CompressionDictionary  ## 圧縮辞書（オプション）

proc mapToGzipLevel*(level: CompressionLevel): int =
  ## 汎用圧縮レベルをgzip圧縮レベル（0-9）にマッピング
  case level
  of clNone: 0
  of clFastest: 1
  of clFast: 3
  of clDefault: 6
  of clHighCompression: 8
  of clMaximum: 9

proc mapToBrotliLevel*(level: CompressionLevel): int =
  ## 汎用圧縮レベルをBrotli圧縮レベル（0-11）にマッピング
  case level
  of clNone: 0
  of clFastest: 1
  of clFast: 3
  of clDefault: 6
  of clHighCompression: 9
  of clMaximum: 11

proc mapToZstdLevel*(level: CompressionLevel): int =
  ## 汎用圧縮レベルをZstd圧縮レベル（-7から22）にマッピング
  case level
  of clNone: 0
  of clFastest: 1
  of clFast: 3
  of clDefault: 9
  of clHighCompression: 16
  of clMaximum: 22

proc mapToLZ4Level*(level: CompressionLevel): int =
  ## 汎用圧縮レベルをLZ4圧縮レベル（1-12）にマッピング
  case level
  of clNone: 0
  of clFastest: 1
  of clFast: 3
  of clDefault: 6
  of clHighCompression: 9
  of clMaximum: 12

proc mapToLZMALevel*(level: CompressionLevel): int =
  ## 汎用圧縮レベルをLZMA圧縮レベル（0-9）にマッピング
  case level
  of clNone: 0
  of clFastest: 1
  of clFast: 3
  of clDefault: 6
  of clHighCompression: 8
  of clMaximum: 9

proc getContentEncoding*(format: CompressionFormat): string =
  ## 圧縮形式からHTTPのContent-Encodingヘッダー値を取得
  case format
  of cfNone: "identity"
  of cfGzip: "gzip"
  of cfDeflate: "deflate"
  of cfBrotli: "br"
  of cfZstd: "zstd"
  of cfLZ4: "lz4"
  of cfLZMA: "lzma"

proc getFormatFromContentEncoding*(encoding: string): CompressionFormat =
  ## HTTPのContent-Encodingヘッダー値から圧縮形式を取得
  case encoding.toLowerAscii()
  of "gzip": cfGzip
  of "deflate": cfDeflate
  of "br", "brotli": cfBrotli
  of "zstd": cfZstd
  of "lz4": cfLZ4
  of "lzma", "xz": cfLZMA
  of "identity", "": cfNone
  else: cfNone

proc detectCompressionFormat*(data: openArray[byte], maxCheckBytes: int = 16): CompressionFormat =
  ## バイナリデータから圧縮形式を検出（マジックナンバーチェック）
  if data.len < 2:
    return cfNone
  
  # gzipシグネチャ (1F 8B)
  if data.len >= 2 and data[0] == 0x1F and data[1] == 0x8B:
    return cfGzip
  
  # zlibシグネチャ（deflate）
  if data.len >= 2:
    let cmf = data[0]
    let flg = data[1]
    # CMFとFLGは16の倍数でなければならない
    if (cmf.int * 256 + flg.int) mod 31 == 0:
      # CM値を確認（8はdeflate）
      let cm = cmf and 0x0F
      if cm == 8:
        return cfDeflate
  
  # Brotliシグネチャ
  if data.len >= 3 and (data[0] == 0xCE or (data[0] and 0x0F) == 0x0B):
    # Brotliはシグネチャが明確でないため、ヒューリスティックを使用
    return cfBrotli
  
  # zstdシグネチャ (28 B5 2F FD)
  if data.len >= 4 and data[0] == 0x28 and data[1] == 0xB5 and data[2] == 0x2F and data[3] == 0xFD:
    return cfZstd
  
  # LZ4シグネチャ (04 22 4D 18)
  if data.len >= 4 and data[0] == 0x04 and data[1] == 0x22 and data[2] == 0x4D and data[3] == 0x18:
    return cfLZ4
  
  # LZMA/XZシグネチャ (FD 37 7A 58 5A 00)
  if data.len >= 6 and data[0] == 0xFD and data[1] == 0x37 and data[2] == 0x7A and data[3] == 0x58 and data[4] == 0x5A and data[5] == 0x00:
    return cfLZMA
  
  # マジックナンバーが見つからなかった場合
  return cfNone

type
  CompressionStats* = object
    ## 圧縮/解凍操作の統計情報
    originalSize*: int64     ## 元のデータサイズ
    compressedSize*: int64   ## 圧縮後のデータサイズ
    ratio*: float            ## 圧縮率（元サイズに対する圧縮後サイズの割合）
    processingTimeMs*: float ## 処理時間（ミリ秒）
    algorithm*: CompressionFormat ## 使用されたアルゴリズム
    memoryUsed*: int64       ## 使用メモリ量（バイト）
    cpuUsage*: float         ## CPU使用率（パーセント）

  FormatCapabilities* = object
    ## 圧縮形式の機能と特性
    format*: CompressionFormat     ## 圧縮形式
    compressionSupported*: bool    ## 圧縮機能サポート
    decompressionSupported*: bool  ## 解凍機能サポート
    streamingSupported*: bool      ## ストリーミングサポート
    minLevel*: int                 ## 最小圧縮レベル
    maxLevel*: int                 ## 最大圧縮レベル
    defaultLevel*: int             ## デフォルト圧縮レベル
    dictionarySupported*: bool     ## 辞書圧縮サポート
    concurrentSupported*: bool     ## 並列処理サポート
    mediaType*: string             ## 関連するMIMEタイプ
    fileExtension*: string         ## 関連するファイル拡張子

proc getFormatCapabilities*(format: CompressionFormat): FormatCapabilities =
  ## 各圧縮形式の機能と特性情報を取得
  case format
  of cfGzip:
    FormatCapabilities(
      format: cfGzip,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 9,
      defaultLevel: 6,
      dictionarySupported: false,
      concurrentSupported: false,
      mediaType: "application/gzip",
      fileExtension: ".gz"
    )
  of cfDeflate:
    FormatCapabilities(
      format: cfDeflate,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 9,
      defaultLevel: 6,
      dictionarySupported: false,
      concurrentSupported: false,
      mediaType: "application/zlib",
      fileExtension: ".zz"
    )
  of cfBrotli:
    FormatCapabilities(
      format: cfBrotli,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 11,
      defaultLevel: 4,
      dictionarySupported: true,
      concurrentSupported: false,
      mediaType: "application/brotli",
      fileExtension: ".br"
    )
  of cfZstd:
    FormatCapabilities(
      format: cfZstd,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: -7,  # 負の値は高速、低圧縮率
      maxLevel: 22,
      defaultLevel: 3,
      dictionarySupported: true,
      concurrentSupported: true,
      mediaType: "application/zstd",
      fileExtension: ".zst"
    )
  of cfLZ4:
    FormatCapabilities(
      format: cfLZ4,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 12,
      defaultLevel: 6,
      dictionarySupported: false,
      concurrentSupported: true,
      mediaType: "application/x-lz4",
      fileExtension: ".lz4"
    )
  of cfLZMA:
    FormatCapabilities(
      format: cfLZMA,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 9,
      defaultLevel: 6,
      dictionarySupported: false,
      concurrentSupported: false,
      mediaType: "application/x-xz",
      fileExtension: ".xz"
    )
  of cfNone:
    FormatCapabilities(
      format: cfNone,
      compressionSupported: true,
      decompressionSupported: true,
      streamingSupported: true,
      minLevel: 0,
      maxLevel: 0,
      defaultLevel: 0,
      dictionarySupported: false,
      concurrentSupported: true,
      mediaType: "application/octet-stream",
      fileExtension: ""
    )

proc isSupported*(format: CompressionFormat): bool =
  ## 指定された圧縮形式がサポートされているかを確認します
  ## ライブラリの存在確認や初期化の成否に基づいて判定します。
  let capabilities = getFormatCapabilities(format)
  result = capabilities.compressionSupported and capabilities.decompressionSupported
  
  # 実行時の環境に基づく追加チェック
  case format:
    of cfBrotli:
      # Brotliライブラリの存在確認
      result = result and checkBrotliLibraryAvailable()
    of cfGzip:
      # zlibライブラリの存在確認
      result = result and checkZlibLibraryAvailable()
    of cfDeflate:
      # zlibライブラリの存在確認
      result = result and checkZlibLibraryAvailable()
    of cfZstd:
      # Zstdライブラリの存在確認
      result = result and checkZstdLibraryAvailable()
    of cfLZ4:
      # LZ4ライブラリの存在確認
      result = result and checkLZ4LibraryAvailable()
    of cfLZMA:
      # LZMAライブラリの存在確認
      result = result and checkLZMALibraryAvailable()
    of cfNone:
      # 無圧縮は常にサポート
      result = true

proc listSupportedFormats*(): seq[CompressionFormat] =
  ## サポートされている圧縮形式のリストを取得します
  ##
  ## 現在の環境で利用可能なすべての圧縮形式を返します。
  ## 実行時の環境に基づいて動的に判断されます。
  result = @[]
  for format in CompressionFormat:
    if isSupported(format):
      result.add(format)

proc getOptimalCompressionLevel*(format: CompressionFormat, dataSize: int64, 
                                speedPriority: bool = false): CompressionLevel =
  ## 指定された圧縮形式とデータサイズに基づいて最適な圧縮レベルを取得します
  ##
  ## Args:
  ##   format: 圧縮形式
  ##   dataSize: 圧縮するデータのサイズ（バイト）
  ##   speedPriority: 圧縮速度を優先する場合はtrue、圧縮率を優先する場合はfalse
  ##
  ## Returns:
  ##   最適な圧縮レベル
  let capabilities = getFormatCapabilities(format)
  
  if format == cfNone:
    return clNone
    
  if speedPriority:
    # 速度優先の場合は低めのレベルを選択
    if dataSize < 10_000:  # 10KB未満
      return clFastest
    elif dataSize < 1_000_000:  # 1MB未満
      return clFast
    else:
      return clDefault
  else:
    # 圧縮率優先の場合
    if dataSize < 10_000:  # 小さいデータは圧縮率よりも速度
      return clDefault
    elif dataSize < 10_000_000:  # 10MB未満
      return clBest
    else:
      # 大きなデータは最高圧縮
      let maxLevel = CompressionLevel(capabilities.maxLevel)
      if maxLevel > clBest:
        return maxLevel
      else:
        return clBest

proc createCompressionContext*(format: CompressionFormat, level: CompressionLevel = clDefault, 
                              strategy: CompressionStrategy = csDefault): CompressionContext =
  ## 圧縮コンテキストを作成します
  ##
  ## 指定された圧縮形式、レベル、戦略に基づいて最適化された圧縮コンテキストを生成します。
  ## 
  ## Args:
  ##   format: 使用する圧縮形式
  ##   level: 圧縮レベル（デフォルトはclDefault）
  ##   strategy: 圧縮戦略（デフォルトはcsDefault）
  ##
  ## Returns:
  ##   初期化された圧縮コンテキスト
  let capabilities = getFormatCapabilities(format)
  
  # レベルの正規化
  var normalizedLevel = level
  if level == clDefault:
    normalizedLevel = CompressionLevel(capabilities.defaultLevel)
  elif level == clNone:
    normalizedLevel = CompressionLevel(0)
  elif int(level) > capabilities.maxLevel:
    normalizedLevel = CompressionLevel(capabilities.maxLevel)
  elif int(level) < capabilities.minLevel:
    normalizedLevel = CompressionLevel(capabilities.minLevel)
  
  # 形式に応じたウィンドウビットとメモリレベルの最適化
  var windowBits = 15  # デフォルト値
  var memLevel = 8     # デフォルト値
  
  case format:
    of cfGzip:
      windowBits = 15 + 16  # gzipヘッダーを追加
    of cfDeflate:
      windowBits = 15       # 標準のdeflate
    of cfZstd:
      # Zstdは独自のウィンドウサイズ管理を使用
      windowBits = 0
      memLevel = 0
    of cfBrotli:
      # Brotliは独自のウィンドウサイズ管理を使用
      windowBits = 0
      memLevel = 0
    else:
      # その他の形式はデフォルト値を使用
      discard
  
  result = CompressionContext(
    format: format,
    level: normalizedLevel,
    strategy: strategy,
    windowBits: windowBits,
    memLevel: memLevel,
    initialized: true,
    error: "",
    compressionState: nil,
    decompressionState: nil
  )

proc createDictionary*(data: openArray[byte], format: CompressionFormat): CompressionDictionary =
  ## 圧縮辞書を作成します
  ##
  ## 指定されたデータと圧縮形式に基づいて最適化された圧縮辞書を生成します。
  ## 辞書を使用すると、類似したデータの圧縮効率が向上します。
  ##
  ## Args:
  ##   data: 辞書として使用するバイトデータ
  ##   format: 辞書を使用する圧縮形式
  ##
  ## Returns:
  ##   初期化された圧縮辞書
  ##
  ## Raises:
  ##   CompressionError: 辞書の作成に失敗した場合
  
  # 辞書をサポートしていない形式のチェック
  let capabilities = getFormatCapabilities(format)
  if not capabilities.dictionarySupported:
    raise newException(CompressionError, "指定された圧縮形式は辞書をサポートしていません: " & $format)
  
  if data.len == 0:
    raise newException(CompressionError, "辞書データが空です")
  
  # データのコピーを作成
  var dictData = newSeq[byte](data.len)
  for i in 0..<data.len:
    dictData[i] = data[i]
  
  # 辞書IDの計算（単純なハッシュ）
  var dictId: uint32 = 0
  for b in dictData:
    dictId = (dictId * 31 + uint32(b)) mod 0xFFFFFFFF
  
  # 形式に応じた辞書の最適化
  case format:
    of cfZstd:
      # Zstd辞書の最適化処理
      dictData = optimizeZstdDictionary(dictData)
    of cfBrotli:
      # Brotli辞書の最適化処理
      dictData = optimizeBrotliDictionary(dictData)
    else:
      # その他の形式は標準処理
      discard
  
  result = CompressionDictionary(
    data: dictData,
    id: dictId,
    format: format,
    optimized: true
  )

proc calculateCompressionRatio*(original, compressed: int64): float =
  ## 圧縮率を計算（小さいほど効率的）
  if original <= 0:
    return 0.0
  result = float(compressed) / float(original)

proc suggestOptimalFormat*(dataType: string, size: int64): CompressionFormat =
  ## データタイプとサイズに基づいて最適な圧縮形式を提案
  case dataType.toLowerAscii()
  of "text/html", "text/css", "text/javascript", "application/json", "text/xml":
    # テキストベースのデータにはBrotliが効果的
    if size > 1_000_000:  # 1MB以上
      return cfBrotli
    else:
      return cfGzip
  of "image/jpeg", "image/png", "image/gif", "image/webp":
    # すでに圧縮されている画像には軽量な圧縮
    return cfZstd
  of "application/octet-stream", "application/binary":
    # バイナリデータには汎用的な圧縮
    if size > 10_000_000:  # 10MB以上
      return cfZstd
    else:
      return cfLZ4
  of "video/", "audio/":
    # すでに圧縮されているメディアには圧縮なし
    return cfNone
  else:
    # デフォルト
    return cfGzip