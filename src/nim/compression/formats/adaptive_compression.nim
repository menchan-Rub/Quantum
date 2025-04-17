# adaptive_compression.nim
## 適応型高性能圧縮モジュール - データ特性に応じて最適な圧縮方式を自動選択

import std/[times, tables, hashes, options, math, stats, algorithm, strutils, sequtils]
import ../common/compression_base
import ./simd_compression

# 定数
const
  # サンプリング関連の定数
  SAMPLE_MIN_SIZE* = 4 * 1024   # 最小サンプルサイズ (4KB)
  SAMPLE_MAX_SIZE* = 64 * 1024  # 最大サンプルサイズ (64KB)
  SAMPLE_RATIO* = 0.05          # 全体の何%をサンプリングするか
  SAMPLE_COUNT* = 3             # 複数サンプル取得数
  
  # 分析関連の定数
  ENTROPY_LOW_THRESHOLD* = 0.5   # 低エントロピー閾値
  ENTROPY_HIGH_THRESHOLD* = 0.8  # 高エントロピー閾値
  PATTERN_SIZE* = 8             # パターン認識サイズ
  PATTERN_THRESHOLD* = 4        # パターン検出の閾値

# データ特性タイプ
type
  DataCharacteristicType* = enum
    ## データ特性の種類
    dctText,            # テキストデータ
    dctBinary,          # バイナリデータ
    dctStructured,      # 構造化データ (JSON/XML等)
    dctCompressed,      # 既に圧縮済み
    dctImage,           # 画像データ
    dctAudio,           # 音声データ
    dctSparse,          # スパースデータ（多くの空白や同一値）
    dctRandom,          # ランダムデータ
    dctRepetitive,      # 反復パターンが多いデータ
    dctMixed            # 混合データ

  AdaptiveCompressionOptions* = object
    ## 適応型圧縮オプション
    enableSampling*: bool         # サンプリングを有効にするか
    enableCharacteristicDetection*: bool  # 特性検出を有効にするか
    enableMultiStageCompression*: bool  # 多段圧縮を有効にするか
    enableMethodMixing*: bool     # 複数方式の混合を有効にするか
    cachingEnabled*: bool         # キャッシングを有効にするか
    learningEnabled*: bool        # 学習機能を有効にするか
    simdCompressionOptions*: SimdCompressionOptions  # SIMD圧縮オプション
    sampleRatio*: float           # サンプリング率
    sampleCount*: int             # サンプル数
  
  DataCharacteristics* = object
    ## データ特性
    entropy*: float               # 情報エントロピー
    uniqueBytes*: int             # ユニークバイト数
    patternScore*: float          # パターン性スコア
    avgChunkSize*: float          # 平均チャンクサイズ
    characteristicType*: DataCharacteristicType  # 特性の種類
    byteFrequencies*: Table[byte, float]  # バイト頻度
    mostFrequentBytes*: seq[tuple[b: byte, freq: float]]  # 頻度上位バイト
    repeatPatterns*: seq[tuple[pattern: string, count: int]]  # 繰り返しパターン
  
  CompressionResult* = object
    ## 圧縮結果
    compressedData*: string       # 圧縮後データ
    originalSize*: int            # 元のサイズ
    compressedSize*: int          # 圧縮後サイズ
    compressionRatio*: float      # 圧縮率
    compressionTime*: float       # 圧縮時間
    method*: SimdCompressionMethod  # 使用方式
    level*: SimdCompressionLevel  # 使用レベル
    dataCharacteristics*: DataCharacteristics  # データ特性
  
  # キャッシュキー
  CacheKey = object
    hash: Hash               # データハッシュ
    size: int                # データサイズ
    entropyRange: range[0..10]  # エントロピー範囲（離散化）
  
  # キャッシュエントリ
  CacheEntry = object
    method: SimdCompressionMethod  # 圧縮方式
    level: SimdCompressionLevel   # 圧縮レベル
    compressionRatio: float       # 達成した圧縮率
    timestamp: float              # 最終利用時間
  
  # 学習データ
  CharacteristicEntry = object
    entropyRange: range[0..10]    # エントロピー範囲
    uniqueBytesRange: range[0..10]  # ユニークバイト範囲
    patternRange: range[0..10]    # パターン性範囲
    bestMethod: SimdCompressionMethod  # 最適方式
    bestLevel: SimdCompressionLevel  # 最適レベル
    sampleCount: int              # サンプル数
  
  AdaptiveCompressionManager* = object
    ## 適応型圧縮マネージャー
    options*: AdaptiveCompressionOptions  # オプション
    cache: Table[CacheKey, CacheEntry]   # 結果キャッシュ
    learningData: seq[CharacteristicEntry]  # 学習データ
    stats*: AdaptiveCompressionStats      # 統計情報
  
  AdaptiveCompressionStats* = object
    ## 統計情報
    totalCompressedBytes*: int64     # 圧縮したバイト数
    totalOriginalBytes*: int64       # 元のバイト数
    totalCompressionTime*: float     # 圧縮時間合計
    methodUsage*: Table[SimdCompressionMethod, int]  # 方式の使用回数
    cacheHits*: int                  # キャッシュヒット数
    cacheMisses*: int                # キャッシュミス数
    adaptationCount*: int            # 適応回数

# デフォルトオプションの作成
proc newAdaptiveCompressionOptions*(): AdaptiveCompressionOptions =
  ## デフォルトの適応型圧縮オプションを作成
  result = AdaptiveCompressionOptions(
    enableSampling: true,
    enableCharacteristicDetection: true,
    enableMultiStageCompression: true,
    enableMethodMixing: true,
    cachingEnabled: true,
    learningEnabled: true,
    simdCompressionOptions: newSimdCompressionOptions(),
    sampleRatio: SAMPLE_RATIO,
    sampleCount: SAMPLE_COUNT
  )

# エントロピー計算
proc calculateEntropy(data: string): float =
  ## バイトレベルのシャノンエントロピーを計算
  if data.len == 0:
    return 0.0
  
  var freq = initTable[byte, int]()
  
  # 各バイトの出現頻度を計算
  for b in data:
    let byteVal = byte(b)
    if freq.hasKey(byteVal):
      freq[byteVal] += 1
    else:
      freq[byteVal] = 1
  
  # エントロピー計算
  result = 0.0
  let totalBytes = data.len
  for count in freq.values:
    let p = count.float / totalBytes.float
    result -= p * log2(p)
  
  # 正規化 (最大値は8.0)
  result = result / 8.0
  return result

# バイト分布分析
proc analyzeByteDistribution(data: string): tuple[uniqueBytes: int, frequencies: Table[byte, float], mostFrequent: seq[tuple[b: byte, freq: float]]] =
  ## バイト分布の分析
  if data.len == 0:
    return (0, initTable[byte, float](), @[])
  
  var counts = initTable[byte, int]()
  
  # 各バイトの出現回数をカウント
  for b in data:
    let byteVal = byte(b)
    if counts.hasKey(byteVal):
      counts[byteVal] += 1
    else:
      counts[byteVal] = 1
  
  # 頻度計算
  var frequencies = initTable[byte, float]()
  for b, count in counts:
    frequencies[b] = count.float / data.len.float
  
  # 頻度順に並べ替え
  var byteFreqPairs: seq[tuple[b: byte, freq: float]] = @[]
  for b, freq in frequencies:
    byteFreqPairs.add((b, freq))
  
  byteFreqPairs.sort(proc(x, y: tuple[b: byte, freq: float]): int =
    if x.freq > y.freq: -1 else: 1
  )
  
  let topN = min(10, byteFreqPairs.len)
  return (counts.len, frequencies, byteFreqPairs[0..<topN])

# パターン検出
proc detectPatterns(data: string): tuple[patternScore: float, patterns: seq[tuple[pattern: string, count: int]]] =
  ## データ内の繰り返しパターンを検出
  if data.len < PATTERN_SIZE * 2:
    return (0.0, @[])
  
  var patternCounts = initTable[string, int]()
  
  # 重複するパターンをカウント
  for i in 0..(data.len - PATTERN_SIZE):
    let pattern = data[i..<i+PATTERN_SIZE]
    if patternCounts.hasKey(pattern):
      patternCounts[pattern] += 1
    else:
      patternCounts[pattern] = 1
  
  # カウント順に並べ替え
  var patternPairs: seq[tuple[pattern: string, count: int]] = @[]
  for pattern, count in patternCounts:
    if count >= PATTERN_THRESHOLD:
      patternPairs.add((pattern, count))
  
  patternPairs.sort(proc(x, y: tuple[pattern: string, count: int]): int =
    if x.count > y.count: -1 else: 1
  )
  
  # 上位パターンのみ保持
  let topN = min(10, patternPairs.len)
  let topPatterns = if patternPairs.len > 0: patternPairs[0..<topN] else: @[]
  
  # パターン性スコアの計算
  var patternScore = 0.0
  if patternPairs.len > 0:
    let totalPatternOccurrences = patternPairs.mapIt(it.count).sum()
    patternScore = totalPatternOccurrences.float * PATTERN_SIZE.float / data.len.float
  
  return (patternScore, topPatterns)

# データ特性の分析
proc analyzeDataCharacteristics*(data: string): DataCharacteristics =
  ## データの特性を分析
  if data.len == 0:
    return DataCharacteristics(entropy: 0.0, uniqueBytes: 0)
  
  # エントロピー計算
  let entropy = calculateEntropy(data)
  
  # バイト分布
  let (uniqueBytes, byteFrequencies, mostFrequentBytes) = analyzeByteDistribution(data)
  
  # パターン検出
  let (patternScore, patterns) = detectPatterns(data)
  
  # データ特性の予測
  var characteristicType = dctMixed
  
  # 特性判断ロジック
  if entropy < ENTROPY_LOW_THRESHOLD:
    if patternScore > 0.7:
      characteristicType = dctRepetitive
    else:
      characteristicType = dctSparse
  elif entropy > ENTROPY_HIGH_THRESHOLD:
    if uniqueBytes > 220:  # ほぼすべてのバイト値が使用されている
      characteristicType = dctRandom
    else:
      characteristicType = dctBinary
  else:
    # 中間的なエントロピー
    if uniqueBytes < 128 and patternScore > 0.3:
      characteristicType = dctText
    elif uniqueBytes > 200 and patterns.len == 0:
      characteristicType = dctCompressed
    else:
      # パターンがあるがエントロピーも中程度ならstructured
      characteristicType = dctStructured
  
  # 画像/音声判定 (シンプルなヒューリスティック)
  if data.len >= 12:
    # 簡易ファイルシグネチャ検出
    if data.startsWith("\xFF\xD8\xFF"):  # JPEG
      characteristicType = dctImage
    elif data.startsWith("\x89PNG\r\n\x1A\n"):  # PNG
      characteristicType = dctImage
    elif data.startsWith("GIF8"):  # GIF
      characteristicType = dctImage
    elif data.startsWith("RIFF") and data[8..11] == "WAVE":  # WAV
      characteristicType = dctAudio
    elif data.startsWith("ID3") or data.startsWith("\xFF\xFB"):  # MP3
      characteristicType = dctAudio
  
  return DataCharacteristics(
    entropy: entropy,
    uniqueBytes: uniqueBytes,
    patternScore: patternScore,
    characteristicType: characteristicType,
    byteFrequencies: byteFrequencies,
    mostFrequentBytes: mostFrequentBytes,
    repeatPatterns: patterns
  )

# サンプリング
proc sampleData(data: string, options: AdaptiveCompressionOptions): seq[string] =
  ## データからサンプルを取得
  result = @[]
  
  if data.len <= SAMPLE_MIN_SIZE:
    # データが小さい場合はそのまま
    result.add(data)
    return
  
  let sampleSize = max(
    SAMPLE_MIN_SIZE, 
    min(SAMPLE_MAX_SIZE, int(data.len.float * options.sampleRatio))
  )
  
  # 複数サンプルを取得
  for i in 0..<options.sampleCount:
    var sampleStart = 0
    
    if i == 0:
      # 最初のサンプルは先頭から
      sampleStart = 0
    elif i == 1 and options.sampleCount >= 2:
      # 2番目のサンプルは末尾から
      sampleStart = max(0, data.len - sampleSize)
    else:
      # それ以降はランダム位置から
      sampleStart = max(0, min(data.len - sampleSize, int(rand(data.len.float))))
    
    # サンプル追加
    if sampleStart + sampleSize <= data.len:
      result.add(data[sampleStart..<sampleStart+sampleSize])
    else:
      result.add(data[sampleStart..^1])
  
  return result

# データ特性に基づく最適な圧縮方式の選択
proc selectOptimalMethod(characteristics: DataCharacteristics, options: AdaptiveCompressionOptions): tuple[method: SimdCompressionMethod, level: SimdCompressionLevel] =
  ## データ特性に最適な圧縮方式とレベルを選択
  
  # 特性タイプに基づく選択
  case characteristics.characteristicType:
    of dctText:
      # テキストデータ: Zstdが最適
      if characteristics.patternScore > 0.5:
        return (scmZstd, sclBest)  # パターンが多い場合は高圧縮率
      else:
        return (scmZstd, sclDefault)
    
    of dctBinary:
      # バイナリデータ: LZ4かDeflate
      if characteristics.entropy < 0.7:
        return (scmDeflate, sclDefault)
      else:
        return (scmLZ4, sclDefault)
    
    of dctStructured:
      # 構造化データ: Brotliが優れている
      return (scmBrotli, sclDefault)
    
    of dctCompressed:
      # 既に圧縮済み: 軽い圧縮または圧縮なし
      return (scmLZ4, sclFastest)
    
    of dctImage, dctAudio:
      # メディアデータ: 既に最適化されていることが多い
      return (scmLZ4, sclFastest)
    
    of dctSparse:
      # スパースデータ: 高圧縮率
      return (scmZstd, sclBest)
    
    of dctRandom:
      # ランダムデータ: 圧縮効果が低い
      return (scmLZ4, sclFastest)
    
    of dctRepetitive:
      # 反復パターン: 高圧縮率
      return (scmZstd, sclBest)
    
    of dctMixed:
      # 混合データ: バランス型
      if characteristics.entropy < 0.6:
        return (scmZstd, sclDefault)
      elif characteristics.entropy > 0.8:
        return (scmLZ4, sclDefault)
      else:
        return (scmBrotli, sclDefault)
  
  # フォールバック
  return (scmLZ4, sclDefault)

# マネージャーの作成
proc newAdaptiveCompressionManager*(): AdaptiveCompressionManager =
  ## 新しい適応型圧縮マネージャーを作成
  result = AdaptiveCompressionManager(
    options: newAdaptiveCompressionOptions(),
    cache: initTable[CacheKey, CacheEntry](),
    learningData: @[],
    stats: AdaptiveCompressionStats(
      methodUsage: initTable[SimdCompressionMethod, int]()
    )
  )

# エントリをキャッシュに追加
proc addToCache(manager: var AdaptiveCompressionManager, data: string, characteristics: DataCharacteristics, method: SimdCompressionMethod, level: SimdCompressionLevel, ratio: float) =
  ## 圧縮結果をキャッシュに追加
  if not manager.options.cachingEnabled:
    return
  
  # キャッシュキーの生成
  let entropyRange = min(10, max(0, int(characteristics.entropy * 10)))
  let key = CacheKey(
    hash: hash(data[0..<min(1024, data.len)]),  # 先頭部分のハッシュを使用
    size: data.len,
    entropyRange: entropyRange.range[0..10]
  )
  
  # キャッシュエントリの作成
  let entry = CacheEntry(
    method: method,
    level: level,
    compressionRatio: ratio,
    timestamp: epochTime()
  )
  
  # キャッシュに追加
  manager.cache[key] = entry

# キャッシュから探索
proc findInCache(manager: var AdaptiveCompressionManager, data: string, characteristics: DataCharacteristics): Option[tuple[method: SimdCompressionMethod, level: SimdCompressionLevel]] =
  ## キャッシュから以前の圧縮結果を検索
  if not manager.options.cachingEnabled:
    return none(tuple[method: SimdCompressionMethod, level: SimdCompressionLevel])
  
  # キャッシュキーの生成
  let entropyRange = min(10, max(0, int(characteristics.entropy * 10)))
  let key = CacheKey(
    hash: hash(data[0..<min(1024, data.len)]),
    size: data.len,
    entropyRange: entropyRange.range[0..10]
  )
  
  # キャッシュ検索
  if manager.cache.hasKey(key):
    let entry = manager.cache[key]
    # タイムスタンプを更新
    manager.cache[key].timestamp = epochTime()
    inc manager.stats.cacheHits
    return some((entry.method, entry.level))
  
  inc manager.stats.cacheMisses
  return none(tuple[method: SimdCompressionMethod, level: SimdCompressionLevel])

# 学習データを追加
proc addLearningData(manager: var AdaptiveCompressionManager, characteristics: DataCharacteristics, method: SimdCompressionMethod, level: SimdCompressionLevel) =
  ## 圧縮結果を学習データに追加
  if not manager.options.learningEnabled:
    return
  
  # 特性の離散化
  let entropyRange = min(10, max(0, int(characteristics.entropy * 10)))
  let uniqueBytesRange = min(10, max(0, int(float(characteristics.uniqueBytes) / 25.6)))
  let patternRange = min(10, max(0, int(characteristics.patternScore * 10)))
  
  # 既存エントリを検索
  var found = false
  for i in 0..<manager.learningData.len:
    if manager.learningData[i].entropyRange == entropyRange.range[0..10] and
       manager.learningData[i].uniqueBytesRange == uniqueBytesRange.range[0..10] and
       manager.learningData[i].patternRange == patternRange.range[0..10]:
      # 既存エントリの更新
      inc manager.learningData[i].sampleCount
      # 新しい方法が既存の方法より良い結果を出した場合に更新する追加ロジックが必要
      found = true
      break
  
  if not found:
    # 新しいエントリを追加
    manager.learningData.add(CharacteristicEntry(
      entropyRange: entropyRange.range[0..10],
      uniqueBytesRange: uniqueBytesRange.range[0..10],
      patternRange: patternRange.range[0..10],
      bestMethod: method,
      bestLevel: level,
      sampleCount: 1
    ))

# 学習データから最適な方法を探索
proc findFromLearningData(manager: AdaptiveCompressionManager, characteristics: DataCharacteristics): Option[tuple[method: SimdCompressionMethod, level: SimdCompressionLevel]] =
  ## 学習データから最適な圧縮方法を検索
  if not manager.options.learningEnabled or manager.learningData.len == 0:
    return none(tuple[method: SimdCompressionMethod, level: SimdCompressionLevel])
  
  # 特性の離散化
  let entropyRange = min(10, max(0, int(characteristics.entropy * 10)))
  let uniqueBytesRange = min(10, max(0, int(float(characteristics.uniqueBytes) / 25.6)))
  let patternRange = min(10, max(0, int(characteristics.patternScore * 10)))
  
  # 完全一致を検索
  for entry in manager.learningData:
    if entry.entropyRange == entropyRange.range[0..10] and
       entry.uniqueBytesRange == uniqueBytesRange.range[0..10] and
       entry.patternRange == patternRange.range[0..10]:
      return some((entry.bestMethod, entry.bestLevel))
  
  # 類似の特性を検索
  var bestMatch: Option[CharacteristicEntry]
  var bestDistance = high(int)
  
  for entry in manager.learningData:
    let distance = 
      abs(int(entry.entropyRange) - entropyRange) +
      abs(int(entry.uniqueBytesRange) - uniqueBytesRange) +
      abs(int(entry.patternRange) - patternRange)
    
    if distance < bestDistance:
      bestDistance = distance
      bestMatch = some(entry)
  
  if bestMatch.isSome and bestDistance <= 3:  # 距離閾値
    return some((bestMatch.get.bestMethod, bestMatch.get.bestLevel))
  
  return none(tuple[method: SimdCompressionMethod, level: SimdCompressionLevel])

# 統計の更新
proc updateStats(manager: var AdaptiveCompressionManager, result: CompressionResult) =
  ## 統計情報を更新
  manager.stats.totalOriginalBytes += result.originalSize
  manager.stats.totalCompressedBytes += result.compressedSize
  manager.stats.totalCompressionTime += result.compressionTime
  
  # 方式の使用回数を更新
  if manager.stats.methodUsage.hasKey(result.method):
    manager.stats.methodUsage[result.method] += 1
  else:
    manager.stats.methodUsage[result.method] = 1

# 適応型圧縮
proc compressAdaptive*(manager: var AdaptiveCompressionManager, data: string): CompressionResult =
  ## データを適応型圧縮
  if data.len == 0:
    return CompressionResult(
      compressedData: "",
      originalSize: 0,
      compressedSize: 0,
      compressionRatio: 1.0,
      method: scmLZ4,
      level: sclDefault
    )
  
  let startTime = epochTime()
  
  # データ特性の分析
  var characteristics: DataCharacteristics
  if manager.options.enableCharacteristicDetection:
    # サンプリングが有効な場合
    if manager.options.enableSampling and data.len > SAMPLE_MIN_SIZE:
      let samples = sampleData(data, manager.options)
      var combinedCharacteristics: seq[DataCharacteristics] = @[]
      
      for sample in samples:
        combinedCharacteristics.add(analyzeDataCharacteristics(sample))
      
      # 複数サンプルの特性を統合
      var totalEntropy = 0.0
      var totalUniqueBytes = 0
      var totalPatternScore = 0.0
      var characteristicType = dctMixed
      
      for c in combinedCharacteristics:
        totalEntropy += c.entropy
        totalUniqueBytes += c.uniqueBytes
        totalPatternScore += c.patternScore
      
      let avgEntropy = totalEntropy / combinedCharacteristics.len.float
      let avgUniqueBytes = totalUniqueBytes div combinedCharacteristics.len
      let avgPatternScore = totalPatternScore / combinedCharacteristics.len.float
      
      # 最も一般的な特性タイプを採用
      var typeCounts = initTable[DataCharacteristicType, int]()
      for c in combinedCharacteristics:
        if typeCounts.hasKey(c.characteristicType):
          typeCounts[c.characteristicType] += 1
        else:
          typeCounts[c.characteristicType] = 1
      
      var maxType = dctMixed
      var maxCount = 0
      for t, count in typeCounts:
        if count > maxCount:
          maxCount = count
          maxType = t
      
      characteristics = DataCharacteristics(
        entropy: avgEntropy,
        uniqueBytes: avgUniqueBytes,
        patternScore: avgPatternScore,
        characteristicType: maxType
      )
    else:
      # サンプリングなしで全データ分析
      characteristics = analyzeDataCharacteristics(data)
  else:
    # 特性検出無効時の基本値設定
    characteristics = DataCharacteristics(
      entropy: 0.5,
      uniqueBytes: 128,
      patternScore: 0.0,
      characteristicType: dctMixed
    )
  
  # 圧縮方式の選択
  var method: SimdCompressionMethod
  var level: SimdCompressionLevel
  
  # キャッシュをチェック
  let cachedMethod = findInCache(manager, data, characteristics)
  if cachedMethod.isSome:
    (method, level) = cachedMethod.get
  else:
    # 学習データをチェック
    let learnedMethod = findFromLearningData(manager, characteristics)
    if learnedMethod.isSome:
      (method, level) = learnedMethod.get
    else:
      # 最適方式の選択
      (method, level) = selectOptimalMethod(characteristics, manager.options)
      inc manager.stats.adaptationCount
  
  # SIMD圧縮オプションの構成
  var options = manager.options.simdCompressionOptions
  options.method = method
  options.level = level
  
  # 圧縮実行
  let compressStart = epochTime()
  let compressedData = compressSimd(data, options)
  let compressEnd = epochTime()
  
  # 圧縮結果の作成
  let compressionTime = compressEnd - compressStart
  let result = CompressionResult(
    compressedData: compressedData,
    originalSize: data.len,
    compressedSize: compressedData.len,
    compressionRatio: if data.len > 0: compressedData.len.float / data.len.float else: 1.0,
    compressionTime: compressionTime,
    method: method,
    level: level,
    dataCharacteristics: characteristics
  )
  
  # キャッシュと学習データの更新
  addToCache(manager, data, characteristics, method, level, result.compressionRatio)
  addLearningData(manager, characteristics, method, level)
  
  # 統計の更新
  updateStats(manager, result)
  
  return result

# 適応型解凍
proc decompressAdaptive*(compressedData: string): string =
  ## 適応型圧縮されたデータを解凍
  return decompressSimd(compressedData)

# キャッシュのクリーンアップ
proc cleanupCache*(manager: var AdaptiveCompressionManager, maxAgeSeconds: float = 3600.0) =
  ## 古いキャッシュエントリを削除
  let currentTime = epochTime()
  var keysToRemove: seq[CacheKey] = @[]
  
  for key, entry in manager.cache:
    if currentTime - entry.timestamp > maxAgeSeconds:
      keysToRemove.add(key)
  
  for key in keysToRemove:
    manager.cache.del(key)

# 複数の圧縮方法でベンチマーク
proc benchmarkMethods*(data: string, methods: openArray[SimdCompressionMethod] = [scmLZ4, scmZstd, scmDeflate, scmBrotli]): seq[CompressionResult] =
  ## 複数の圧縮方法でベンチマーク
  result = @[]
  
  # 特性分析
  let characteristics = analyzeDataCharacteristics(data)
  
  for method in methods:
    var options = newSimdCompressionOptions()
    options.method = method
    
    let startTime = epochTime()
    let compressedData = compressSimd(data, options)
    let endTime = epochTime()
    
    result.add(CompressionResult(
      compressedData: compressedData,
      originalSize: data.len,
      compressedSize: compressedData.len,
      compressionRatio: if data.len > 0: compressedData.len.float / data.len.float else: 1.0,
      compressionTime: endTime - startTime,
      method: method,
      level: options.level,
      dataCharacteristics: characteristics
    ))
  
  # 圧縮率順にソート
  result.sort(proc(x, y: CompressionResult): int =
    if x.compressionRatio < y.compressionRatio: -1 else: 1
  ) 