# parallel_compression.nim
## 並列処理を用いた高速圧縮モジュール

import std/[os, cpuinfo, times, math, threadpool, tables, options, strutils]
import ../common/[compression_base, optimization]
import ../formats/[gzip, zstd, brotli]

# 並列圧縮の定数
const
  MIN_CHUNK_SIZE* = 64 * 1024      # 最小チャンクサイズ: 64KB
  MAX_CHUNK_SIZE* = 4 * 1024 * 1024  # 最大チャンクサイズ: 4MB
  ALIGNMENT_SIZE* = 8 * 1024       # アラインメントサイズ: 8KB
  
  # チャンク境界検出のパターン
  CHUNK_BOUNDARY_PATTERNS = [
    "\n\n", "<div", "</div>", "<p>", "</p>", 
    "function", "class", "import", "export",
    "{", "}", ";", ".", "\n"
  ]

# 並列圧縮のタイプ定義
type
  ChunkingStrategy* = enum
    ## チャンク分割戦略
    csFixed,        # 固定サイズで分割
    csContent,      # コンテンツに基づいて分割（テキスト/HTML向け）
    csAdaptive,     # データサイズと特性に基づいて適応的に分割
    csDictionary    # 辞書共有による分割
  
  ChunkResult = object
    ## チャンク処理結果
    index: int            # チャンクインデックス
    data: string          # 圧縮/解凍されたデータ
    originalSize: int     # 元のサイズ
    success: bool         # 成功したかどうか
    error: string         # エラーがあれば
  
  ParallelCompressionOptions* = object
    ## 並列圧縮オプション
    format*: CompressionFormat   # 圧縮形式
    level*: int                  # 圧縮レベル
    chunkStrategy*: ChunkingStrategy  # チャンク分割戦略
    chunkSize*: int              # チャンクサイズ (固定戦略用)
    threadCount*: int            # 使用するスレッド数 (0=自動)
    useDictionary*: bool         # 辞書を使用するか
    dictionarySize*: int         # 辞書サイズ (KB)
    optimizeForType*: bool       # コンテンツタイプに最適化

# 並列圧縮モジュール
proc newParallelCompressionOptions*(
  format: CompressionFormat = cfZstd,
  level: int = -1,  # -1 = 自動
  chunkStrategy: ChunkingStrategy = csAdaptive,
  chunkSize: int = 0,  # 0 = 自動
  threadCount: int = 0,  # 0 = 自動
  useDictionary: bool = true,
  dictionarySize: int = 64,  # 64KB
  optimizeForType: bool = true
): ParallelCompressionOptions =
  ## 並列圧縮オプションを作成
  result = ParallelCompressionOptions(
    format: format,
    level: level,
    chunkStrategy: chunkStrategy,
    threadCount: threadCount,
    useDictionary: useDictionary,
    dictionarySize: dictionarySize * 1024,
    optimizeForType: optimizeForType
  )
  
  # チャンクサイズの決定
  if chunkSize <= 0:
    # データサイズに応じた適切なチャンクサイズを自動選択
    let cpuCount = if threadCount <= 0: optimalThreadCount() else: threadCount
    # 平均的に1コアあたり4チャンク、最小サイズは64KB、最大は4MB
    result.chunkSize = clamp(1024 * 1024 div cpuCount, MIN_CHUNK_SIZE, MAX_CHUNK_SIZE)
  else:
    result.chunkSize = clamp(chunkSize, MIN_CHUNK_SIZE, MAX_CHUNK_SIZE)

proc isTextContent(data: string): bool =
  ## データがテキストコンテンツであるかを推定
  let sampleSize = min(4096, data.len)
  var textChars = 0
  var totalChars = 0
  
  for i in 0..<sampleSize:
    inc totalChars
    let c = data[i]
    # ASCII範囲のテキスト文字、または一般的な制御文字
    if (c >= ' ' and c <= '~') or c == '\n' or c == '\r' or c == '\t':
      inc textChars
  
  # 95%以上がテキスト文字ならテキストと判定
  return totalChars > 0 and (textChars.float / totalChars.float) > 0.95

proc findChunkBoundary(data: string, startPos, endPos: int): int =
  ## テキストデータのチャンク境界を検出（自然な区切りを探す）
  let targetPos = (startPos + endPos) div 2
  let searchWindow = min(ALIGNMENT_SIZE, (endPos - startPos) div 4)
  
  # 理想的な位置の前後を検索
  let searchStart = max(startPos, targetPos - searchWindow)
  let searchEnd = min(endPos, targetPos + searchWindow)
  
  # 境界パターンを探す
  for pattern in CHUNK_BOUNDARY_PATTERNS:
    var pos = searchStart
    while pos <= searchEnd - pattern.len:
      let foundPos = data.find(pattern, pos, searchEnd)
      if foundPos >= 0:
        # パターンの終わりを境界とする
        return foundPos + pattern.len
      pos = searchEnd
  
  # 境界が見つからない場合はターゲット位置を返す
  return targetPos

proc splitIntoChunks(data: string, options: ParallelCompressionOptions): seq[tuple[start, len: int]] =
  ## データをチャンクに分割
  result = @[]
  
  if data.len <= options.chunkSize:
    # 十分小さいデータは分割しない
    result.add((0, data.len))
    return
  
  case options.chunkStrategy:
    of csFixed:
      # 固定サイズで単純に分割
      var position = 0
      while position < data.len:
        let chunkSize = min(options.chunkSize, data.len - position)
        result.add((position, chunkSize))
        position += chunkSize
      
    of csContent:
      # コンテンツに基づいて分割（テキスト向け）
      if isTextContent(data):
        var position = 0
        while position < data.len:
          let targetEnd = min(data.len, position + options.chunkSize)
          # コンテンツに基づく自然な境界を探す
          let actualEnd = if targetEnd < data.len:
                           findChunkBoundary(data, position, targetEnd)
                         else:
                           targetEnd
          
          result.add((position, actualEnd - position))
          position = actualEnd
      else:
        # テキストでない場合は固定サイズで分割
        var position = 0
        while position < data.len:
          let chunkSize = min(options.chunkSize, data.len - position)
          result.add((position, chunkSize))
          position += chunkSize
      
    of csAdaptive:
      # データサイズと特性に応じて適応的に分割
      let isText = isTextContent(data)
      let cpuCount = if options.threadCount <= 0: optimalThreadCount() else: options.threadCount
      
      if data.len < cpuCount * MIN_CHUNK_SIZE:
        # 小さいデータは単純に分割
        let chunkCount = max(1, min(cpuCount, data.len div MIN_CHUNK_SIZE))
        let baseChunkSize = data.len div chunkCount
        
        var position = 0
        for i in 0..<chunkCount:
          let chunkSize = if i < chunkCount - 1: baseChunkSize
                         else: data.len - position
          result.add((position, chunkSize))
          position += chunkSize
      
      elif isText:
        # テキストはコンテンツベースで分割
        var position = 0
        while position < data.len:
          let targetEnd = min(data.len, position + options.chunkSize)
          let actualEnd = if targetEnd < data.len:
                           findChunkBoundary(data, position, targetEnd)
                         else:
                           targetEnd
          
          result.add((position, actualEnd - position))
          position = actualEnd
      
      else:
        # バイナリデータは大きめのチャンクで分割
        let adaptedChunkSize = clamp(options.chunkSize * 2, 
                                    MIN_CHUNK_SIZE, 
                                    MAX_CHUNK_SIZE)
        var position = 0
        while position < data.len:
          let chunkSize = min(adaptedChunkSize, data.len - position)
          result.add((position, chunkSize))
          position += chunkSize
      
    of csDictionary:
      # 辞書共有による分割（Zstdを想定）
      if options.format != cfZstd:
        # 辞書非対応の形式は単純分割
        var position = 0
        while position < data.len:
          let chunkSize = min(options.chunkSize, data.len - position)
          result.add((position, chunkSize))
          position += chunkSize
      else:
        # 辞書サイズを考慮した分割
        let dictSize = min(options.dictionarySize, data.len div 4)
        let effectiveChunkSize = options.chunkSize + dictSize
        
        var position = 0
        while position < data.len:
          let remainingSize = data.len - position
          var chunkSize = min(options.chunkSize, remainingSize)
          
          # 辞書のオーバーラップを考慮（初回以外）
          let dictOverlap = if position > 0: dictSize else: 0
          
          result.add((position - dictOverlap, chunkSize + dictOverlap))
          position += chunkSize

proc compressChunk(chunk: tuple[data: string, index: int, format: CompressionFormat, level: int]): ChunkResult =
  ## 単一チャンクを圧縮
  result = ChunkResult(index: chunk.index, originalSize: chunk.data.len)
  
  try:
    case chunk.format:
      of cfGzip:
        result.data = gzip.compress(chunk.data, chunk.level)
      of cfZstd:
        result.data = zstd.compress(chunk.data, chunk.level)
      of cfBrotli:
        result.data = brotli.compress(chunk.data, chunk.level)
      else:
        # 未対応の形式はgzipを使用
        result.data = gzip.compress(chunk.data, chunk.level)
    
    result.success = true
  except Exception as e:
    result.success = false
    result.error = e.msg

proc decompressChunk(chunk: tuple[data: string, index: int, format: CompressionFormat]): ChunkResult =
  ## 単一チャンクを解凍
  result = ChunkResult(index: chunk.index)
  
  try:
    case chunk.format:
      of cfGzip:
        result.data = gzip.decompress(chunk.data)
      of cfZstd:
        result.data = zstd.decompress(chunk.data)
      of cfBrotli:
        result.data = brotli.decompress(chunk.data)
      else:
        # 未対応の形式はgzipを使用
        result.data = gzip.decompress(chunk.data)
    
    result.originalSize = result.data.len
    result.success = true
  except Exception as e:
    result.success = false
    result.error = e.msg

proc prepareChunks(data: string, chunks: seq[tuple[start, len: int]], 
                   format: CompressionFormat, level: int): seq[FlowVar[ChunkResult]] =
  ## チャンクを並列処理用に準備
  result = @[]
  
  for i, chunk in chunks:
    # チャンクデータを抽出
    let chunkData = data[chunk.start..<(chunk.start + chunk.len)]
    
    # 並列処理タスクとして圧縮を実行
    let task = spawn compressChunk((chunkData, i, format, level))
    result.add(task)

proc prepareDecompressionChunks(compressedData: seq[string], 
                              format: CompressionFormat): seq[FlowVar[ChunkResult]] =
  ## 圧縮チャンクを並列解凍用に準備
  result = @[]
  
  for i, chunkData in compressedData:
    # 並列処理タスクとして解凍を実行
    let task = spawn decompressChunk((chunkData, i, format))
    result.add(task)

proc compressParallel*(data: string, options: ParallelCompressionOptions): string =
  ## データを並列で圧縮
  # 小さなデータは単一スレッドで処理
  if data.len < DEFAULT_PARALLELIZATION_THRESHOLD:
    case options.format:
      of cfGzip:
        return gzip.compress(data, options.level)
      of cfZstd:
        return zstd.compress(data, options.level)
      of cfBrotli:
        return brotli.compress(data, options.level)
      else:
        return gzip.compress(data, options.level)
  
  # 最適な圧縮レベルを決定
  let level = if options.level < 0: 
                getRecommendedCompressionLevel(data, options.format)
              else: 
                options.level
  
  # チャンク分割
  let chunks = splitIntoChunks(data, options)
  
  # 圧縮処理数に基づいてスレッドプールを設定
  let threadCount = if options.threadCount <= 0: optimalThreadCount() else: options.threadCount
  setMaxPoolSize(threadCount)
  
  # 並列圧縮を実行
  let tasks = prepareChunks(data, chunks, options.format, level)
  
  # チャンク長の配列を準備（ヘッダ情報用）
  var chunkLengths: seq[int] = @[]
  var compressedChunks: seq[string] = @[]
  
  # 結果を収集
  for task in tasks:
    let result = ^task
    if not result.success:
      # エラーが発生した場合は単一スレッドで再試行
      case options.format:
        of cfGzip:
          return gzip.compress(data, options.level)
        of cfZstd:
          return zstd.compress(data, options.level)
        of cfBrotli:
          return brotli.compress(data, options.level)
        else:
          return gzip.compress(data, options.level)
    
    # インデックスに基づいて結果を配置
    while compressedChunks.len <= result.index:
      compressedChunks.add("")
    
    compressedChunks[result.index] = result.data
    chunkLengths.add(result.data.len)
  
  # マジックナンバーとヘッダ（形式・チャンク情報）
  let magic = "PARCOMP"
  var header = ""
  
  # 圧縮形式をヘッダに追加
  header.add(char(options.format.ord))
  
  # チャンク数をヘッダに追加
  let chunkCount = chunks.len.uint32
  header.add(char((chunkCount shr 24) and 0xFF))
  header.add(char((chunkCount shr 16) and 0xFF))
  header.add(char((chunkCount shr 8) and 0xFF))
  header.add(char(chunkCount and 0xFF))
  
  # 各チャンクのサイズをヘッダに追加
  for len in chunkLengths:
    let chunkLen = len.uint32
    header.add(char((chunkLen shr 24) and 0xFF))
    header.add(char((chunkLen shr 16) and 0xFF))
    header.add(char((chunkLen shr 8) and 0xFF))
    header.add(char(chunkLen and 0xFF))
  
  # 最終結果を構築
  result = magic & header
  
  # すべてのチャンクを追加
  for chunk in compressedChunks:
    result.add(chunk)

proc decompressParallel*(compressedData: string): string =
  ## 並列圧縮されたデータを解凍
  # マジックナンバーを確認
  if compressedData.len < 8 or compressedData[0..6] != "PARCOMP":
    # 通常の圧縮と見なして単一形式の解凍を試みる
    try:
      return gzip.decompress(compressedData)
    except:
      try:
        return zstd.decompress(compressedData)
      except:
        try:
          return brotli.decompress(compressedData)
        except Exception as e:
          raise newException(ValueError, "非対応の圧縮形式: " & e.msg)
  
  # ヘッダを解析
  var pos = 7  # マジックナンバー後
  
  # 圧縮形式を取得
  let format = CompressionFormat(ord(compressedData[pos]))
  inc pos
  
  # チャンク数を取得
  let chunkCount = (ord(compressedData[pos]).uint32 shl 24) or
                  (ord(compressedData[pos+1]).uint32 shl 16) or
                  (ord(compressedData[pos+2]).uint32 shl 8) or
                  ord(compressedData[pos+3]).uint32
  pos += 4
  
  # チャンクサイズを取得
  var chunkSizes: seq[int] = @[]
  for i in 0..<chunkCount:
    let size = (ord(compressedData[pos]).int shl 24) or
              (ord(compressedData[pos+1]).int shl 16) or
              (ord(compressedData[pos+2]).int shl 8) or
              ord(compressedData[pos+3]).int
    chunkSizes.add(size)
    pos += 4
  
  # チャンクデータを抽出
  var chunks: seq[string] = @[]
  for size in chunkSizes:
    chunks.add(compressedData[pos..<(pos+size)])
    pos += size
  
  # スレッド数を最適化
  let threadCount = optimalThreadCount()
  setMaxPoolSize(threadCount)
  
  # 並列解凍を実行
  let tasks = prepareDecompressionChunks(chunks, format)
  
  # 結果を収集
  var decompressedChunks: seq[string] = @[]
  for i in 0..<tasks.len:
    decompressedChunks.add("")
  
  for task in tasks:
    let result = ^task
    if not result.success:
      # エラーが発生した場合はシングルスレッドで再試行
      case format:
        of cfGzip:
          return gzip.decompress(compressedData)
        of cfZstd:
          return zstd.decompress(compressedData)
        of cfBrotli:
          return brotli.decompress(compressedData)
        else:
          return gzip.decompress(compressedData)
    
    # インデックスに基づいて結果を配置
    decompressedChunks[result.index] = result.data
  
  # 最終結果を構築
  result = ""
  for chunk in decompressedChunks:
    result.add(chunk)

proc compressWithType*(data: string, contentType: string = "", 
                      level: int = -1): tuple[data: string, format: CompressionFormat] =
  ## コンテンツタイプに基づいて最適な圧縮を適用
  var format = cfGzip  # デフォルト
  
  # コンテンツタイプに基づいて圧縮形式を選択
  if contentType.len > 0:
    let ct = contentType.toLowerAscii()
    
    if ct.contains("text/") or ct.contains("application/json") or
       ct.contains("application/javascript") or ct.contains("application/xml") or
       ct.contains("application/xhtml") or ct.contains("/svg"):
      # テキスト系はBrotliが効果的
      format = cfBrotli
    
    elif ct.contains("image/") and not (ct.contains("image/svg")):
      # 画像（SVG以外）は既に圧縮されている可能性
      if data.len < 1024 * 1024:  # 1MB未満
        format = cfDeflate  # 軽量圧縮
      else:
        format = cfZstd     # 高速圧縮
    
    elif ct.contains("video/") or ct.contains("audio/"):
      # 動画・音声は既に圧縮されている
      format = cfDeflate    # 最小限の圧縮
    
    elif ct.contains("application/octet-stream") or ct.contains("application/binary"):
      # バイナリデータはZstdが効果的
      format = cfZstd
    
    else:
      # その他はデータサイズと内容で判断
      format = getRecommendedCompressionFormat(data)
  else:
    # コンテンツタイプが不明な場合はデータ内容から推定
    format = getRecommendedCompressionFormat(data)
  
  # 並列圧縮オプションを作成
  let options = ParallelCompressionOptions(
    format: format,
    level: level,
    chunkStrategy: csAdaptive,
    threadCount: 0,  # 自動
    useDictionary: format == cfZstd,  # Zstdのみ辞書使用
    optimizeForType: true
  )
  
  # 圧縮を実行
  let compressed = compressParallel(data, options)
  
  return (compressed, format) 