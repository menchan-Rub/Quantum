# compression_cache.nim
## 高度な圧縮キャッシュ - 圧縮・解凍処理の高速化のためのキャッシュシステム

import std/[tables, hashes, times, options, strutils, sequtils, algorithm]
import ../common/compression_base
import ../formats/simd_compression

# キャッシュシステムの定数定義
const
  # キャッシュのタイプ
  MAX_CACHE_SIZE_BYTES* = 100 * 1024 * 1024  # 最大100MB
  DEFAULT_CACHE_SIZE_BYTES* = 10 * 1024 * 1024  # デフォルト10MB
  
  # キャッシュエントリの有効期限
  DEFAULT_ENTRY_TTL* = 3600.0  # 1時間
  
  # プレディクティブキャッシュの閾値
  MIN_CACHE_HITS_FOR_PREDICTION* = 3  # 予測キャッシュのための最小ヒット数
  
  # ブロックサイズ
  DEFAULT_BLOCK_SIZE* = 16 * 1024  # 16KB
  
  # LRUキャッシュの更新頻度
  LRU_UPDATE_FREQUENCY* = 100  # エントリ更新の頻度

# キャッシュタイプの定義
type
  CompressionCachePolicy* = enum
    ## キャッシュポリシー
    ccpLRU,     # 最近最も使われていないものから削除
    ccpLFU,     # 最も使用頻度の低いものから削除
    ccpTTL,     # 有効期限に基づいて削除
    ccpHybrid   # LRU、LFU、TTLの組み合わせ
  
  CompressionCacheMode* = enum
    ## キャッシュモード
    ccmBasic,           # 基本キャッシュ
    ccmPredictive,      # 予測キャッシュ
    ccmSmart            # スマートキャッシュ（コンテキスト認識）
  
  CompressionAlgorithmHint* = enum
    ## アルゴリズム選択のヒント
    cahNone,            # ヒントなし
    cahText,            # テキストデータ
    cahBinary,          # バイナリデータ
    cahImage,           # 画像データ
    cahVideo,           # 動画データ
    cahAudio,           # 音声データ
    cahPreCompressed    # 既に圧縮済みのデータ
  
  CompressionCacheStats* = object
    ## キャッシュ統計情報
    hits*: int                  # キャッシュヒット数
    misses*: int                # キャッシュミス数
    totalCompressedBytes*: int64   # 圧縮されたバイト数の合計
    totalUncompressedBytes*: int64 # 非圧縮バイト数の合計
    averageCompressionRatio*: float  # 平均圧縮率
    averageCompressionTime*: float   # 平均圧縮時間（ミリ秒）
    averageDecompressionTime*: float # 平均解凍時間（ミリ秒）
    evictions*: int             # キャッシュから削除されたエントリ数
    totalEntries*: int          # 現在のエントリ数
    totalMemoryUsage*: int64    # 現在のメモリ使用量（バイト）
    hitRatio*: float            # ヒット率
  
  CompressionCacheEntry = object
    ## キャッシュエントリ
    compressedData: string      # 圧縮されたデータ
    algorithm: string           # 使用されたアルゴリズム
    originalSize: int           # 元のデータサイズ
    compressedSize: int         # 圧縮後のサイズ
    compressionRatio: float     # 圧縮率
    compressionTime: float      # 圧縮にかかった時間
    lastAccessed: float         # 最終アクセス時間
    accessCount: int            # アクセス回数
    creationTime: float         # 作成時間
    hints: CompressionAlgorithmHint  # アルゴリズム選択のヒント
  
  PatternEntry = object
    ## パターン分析エントリ
    pattern: string             # データパターン
    frequency: int              # 出現頻度
    associatedKeys: seq[string] # 関連するキー
  
  CompressionCache* = ref object
    ## 圧縮キャッシュシステム
    entries: TableRef[string, CompressionCacheEntry]  # キャッシュエントリ
    stats: CompressionCacheStats                      # 統計情報
    policy: CompressionCachePolicy                    # キャッシュポリシー
    mode: CompressionCacheMode                        # キャッシュモード
    maxCacheSize: int64                               # 最大キャッシュサイズ
    currentSize: int64                                # 現在のキャッシュサイズ
    entryTTL: float                                   # エントリの有効期限
    accessOrder: seq[string]                          # LRU用アクセス順
    accessCounters: TableRef[string, int]             # LFU用アクセスカウンタ
    patterns: seq[PatternEntry]                       # パターン分析
    blockSize: int                                    # ブロックサイズ
    operationCount: int                               # 操作カウント
    useSimd: bool                                     # SIMD使用フラグ

# キャッシュシステムの初期化
proc newCompressionCache*(
  policy: CompressionCachePolicy = ccpLRU,
  mode: CompressionCacheMode = ccmBasic,
  maxCacheSize: int64 = DEFAULT_CACHE_SIZE_BYTES,
  entryTTL: float = DEFAULT_ENTRY_TTL,
  blockSize: int = DEFAULT_BLOCK_SIZE,
  useSimd: bool = true
): CompressionCache =
  ## 新しい圧縮キャッシュの作成
  result = CompressionCache(
    entries: newTable[string, CompressionCacheEntry](),
    stats: CompressionCacheStats(),
    policy: policy,
    mode: mode,
    maxCacheSize: maxCacheSize,
    currentSize: 0,
    entryTTL: entryTTL,
    accessOrder: @[],
    accessCounters: newTable[string, int](),
    patterns: @[],
    blockSize: blockSize,
    operationCount: 0,
    useSimd: useSimd and isSimdSupported()
  )

proc generateCacheKey(data: string, algorithm: string = ""): string =
  ## データとアルゴリズムに基づいてキャッシュキーを生成
  var h = data.hash()
  if algorithm.len > 0:
    h = h !& algorithm.hash()
    h = !$h
  return $h & "_" & $data.len

proc detectDataType(data: string): CompressionAlgorithmHint =
  ## データタイプの自動検出
  if data.len < 10:
    return cahNone
  
  # バイナリデータの検出
  var nonTextChars = 0
  let sampleSize = min(1000, data.len)
  for i in 0..<sampleSize:
    let c = data[i].ord
    if c < 32 and c != 9 and c != 10 and c != 13:  # タブ、LF、CRを除く制御文字
      inc nonTextChars
  
  if nonTextChars.float / sampleSize.float > 0.3:
    # ファイルマジックナンバーの検出
    if data.len > 4:
      # JPEG
      if data[0..1] == "\xFF\xD8":
        return cahImage
      
      # PNG
      if data[0..7] == "\x89PNG\r\n\x1A\n":
        return cahImage
      
      # GIF
      if data[0..5] == "GIF87a" or data[0..5] == "GIF89a":
        return cahImage
      
      # MP3
      if data[0..2] == "ID3" or (data[0..1] == "\xFF\xFB"):
        return cahAudio
      
      # ZIP, GZIP, etc.
      if data[0..1] == "PK" or data[0..2] == "\x1F\x8B\x08":
        return cahPreCompressed
      
      # MP4, MOV
      if data.len > 12 and data[4..7] == "ftyp":
        return cahVideo
    
    return cahBinary
  
  return cahText

proc extractSignature(data: string, sampleSize: int = 512): string =
  ## データからシグネチャを抽出（予測キャッシュ用）
  let size = min(sampleSize, data.len)
  var signature = newSeq[byte](size)
  
  # 均等にサンプリング
  for i in 0..<size:
    let idx = (i * data.len) div size
    signature[i] = byte(data[idx])
  
  result = newString(size)
  copyMem(addr result[0], addr signature[0], size)

proc updateLRU(cache: CompressionCache, key: string) =
  ## LRUキャッシュの更新
  # アクセス順リストから削除
  let idx = cache.accessOrder.find(key)
  if idx != -1:
    cache.accessOrder.delete(idx)
  
  # リストの先頭に追加
  cache.accessOrder.insert(key, 0)

proc updateLFU(cache: CompressionCache, key: string) =
  ## LFUカウンターの更新
  if key in cache.accessCounters:
    inc cache.accessCounters[key]
  else:
    cache.accessCounters[key] = 1

proc evictEntries(cache: CompressionCache, bytesNeeded: int64 = 0) =
  ## キャッシュエントリの追い出し処理
  if cache.entries.len == 0:
    return
  
  # 必要なスペースを計算
  let spaceNeeded = 
    if bytesNeeded > 0: bytesNeeded
    else: cache.maxCacheSize div 10  # デフォルトで10%解放
  
  var freedSpace: int64 = 0
  var keysToRemove: seq[string] = @[]
  
  case cache.policy:
    of ccpLRU:
      # 最近使われていないものから削除
      for i in countdown(cache.accessOrder.high, 0):
        let key = cache.accessOrder[i]
        if key in cache.entries:
          keysToRemove.add(key)
          freedSpace += cache.entries[key].compressedSize
          if freedSpace >= spaceNeeded:
            break
    
    of ccpLFU:
      # アクセス頻度の低いものから削除
      var sortedKeys = toSeq(cache.accessCounters.keys)
      sortedKeys.sort(proc(a, b: string): int =
        return cache.accessCounters[a] - cache.accessCounters[b]
      )
      
      for key in sortedKeys:
        if key in cache.entries:
          keysToRemove.add(key)
          freedSpace += cache.entries[key].compressedSize
          if freedSpace >= spaceNeeded:
            break
    
    of ccpTTL:
      # 期限切れのものから削除
      let currentTime = epochTime()
      for key, entry in cache.entries:
        if currentTime - entry.creationTime > cache.entryTTL:
          keysToRemove.add(key)
          freedSpace += entry.compressedSize
      
      # まだ足りない場合は作成順で削除
      if freedSpace < spaceNeeded:
        var sortedKeys = toSeq(cache.entries.keys)
        sortedKeys.sort(proc(a, b: string): int =
          return int(cache.entries[a].creationTime - cache.entries[b].creationTime)
        )
        
        for key in sortedKeys:
          if key notin keysToRemove and key in cache.entries:
            keysToRemove.add(key)
            freedSpace += cache.entries[key].compressedSize
            if freedSpace >= spaceNeeded:
              break
    
    of ccpHybrid:
      # ハイブリッドアプローチ - TTL、LFU、LRUの組み合わせ
      let currentTime = epochTime()
      
      # 1. まず期限切れを削除
      for key, entry in cache.entries:
        if currentTime - entry.creationTime > cache.entryTTL:
          keysToRemove.add(key)
          freedSpace += entry.compressedSize
      
      # 2. 次にアクセス頻度が低く、長時間アクセスされていないものを削除
      if freedSpace < spaceNeeded:
        var hybridScore = newTable[string, float]()
        
        # ハイブリッドスコアの計算（低いほど削除対象）
        for key, entry in cache.entries:
          if key notin keysToRemove:
            let accessFreq = if key in cache.accessCounters: cache.accessCounters[key].float else: 0.0
            let lastAccessAge = currentTime - entry.lastAccessed
            let score = accessFreq / max(1.0, lastAccessAge / 3600.0)  # スコア = 頻度 / 経過時間(時間)
            hybridScore[key] = score
        
        var sortedKeys = toSeq(hybridScore.keys)
        sortedKeys.sort(proc(a, b: string): int =
          return int(hybridScore[a] - hybridScore[b])
        )
        
        for key in sortedKeys:
          if key in cache.entries:
            keysToRemove.add(key)
            freedSpace += cache.entries[key].compressedSize
            if freedSpace >= spaceNeeded:
              break
  
  # エントリの実際の削除
  for key in keysToRemove:
    if key in cache.entries:
      cache.currentSize -= cache.entries[key].compressedSize
      cache.entries.del(key)
      cache.accessCounters.del(key)
      
      let idx = cache.accessOrder.find(key)
      if idx != -1:
        cache.accessOrder.delete(idx)
  
  # 統計情報の更新
  cache.stats.evictions += keysToRemove.len
  cache.stats.totalEntries = cache.entries.len
  cache.stats.totalMemoryUsage = cache.currentSize

proc addEntry(cache: CompressionCache, key: string, data: string, compressedData: string, 
              algorithm: string, compressionTime: float, hints: CompressionAlgorithmHint) =
  ## キャッシュエントリの追加
  let currentTime = epochTime()
  let entrySize = compressedData.len
  
  # キャッシュサイズのチェックと必要に応じた解放
  if cache.currentSize + entrySize > cache.maxCacheSize:
    evictEntries(cache, entrySize)
  
  # それでも足りない場合は追加しない
  if cache.currentSize + entrySize > cache.maxCacheSize:
    return
  
  # エントリの作成
  let entry = CompressionCacheEntry(
    compressedData: compressedData,
    algorithm: algorithm,
    originalSize: data.len,
    compressedSize: compressedData.len,
    compressionRatio: if data.len > 0: compressedData.len.float / data.len.float else: 1.0,
    compressionTime: compressionTime,
    lastAccessed: currentTime,
    accessCount: 1,
    creationTime: currentTime,
    hints: hints
  )
  
  # キャッシュに追加
  cache.entries[key] = entry
  cache.currentSize += entrySize
  
  # LRU/LFUの更新
  updateLRU(cache, key)
  updateLFU(cache, key)
  
  # 統計情報の更新
  cache.stats.totalEntries = cache.entries.len
  cache.stats.totalMemoryUsage = cache.currentSize
  cache.stats.totalCompressedBytes += entrySize
  cache.stats.totalUncompressedBytes += data.len
  
  let totalCompressions = cache.stats.hits + cache.stats.misses
  if totalCompressions > 0:
    cache.stats.averageCompressionRatio = 
      ((cache.stats.averageCompressionRatio * (totalCompressions - 1)) + entry.compressionRatio) / 
      totalCompressions.float
    
    cache.stats.averageCompressionTime = 
      ((cache.stats.averageCompressionTime * (totalCompressions - 1)) + compressionTime) / 
      totalCompressions.float

proc updatePatternAnalysis(cache: CompressionCache, key: string, data: string) =
  ## パターン分析の更新（予測キャッシュ用）
  if cache.mode != ccmPredictive and cache.mode != ccmSmart:
    return
  
  let signature = extractSignature(data)
  
  # 既存パターンとの一致をチェック
  var patternFound = false
  for i, pattern in cache.patterns:
    # 簡易類似度チェック（より高度な類似度計算も実装可能）
    if pattern.pattern.len == signature.len:
      var matches = 0
      for j in 0..<signature.len:
        if abs(pattern.pattern[j].ord - signature[j].ord) < 10:
          inc matches
      
      let similarity = matches.float / signature.len.float
      if similarity > 0.8:  # 80%以上一致
        inc cache.patterns[i].frequency
        if key notin cache.patterns[i].associatedKeys:
          cache.patterns[i].associatedKeys.add(key)
        patternFound = true
        break
  
  # 新しいパターンの追加
  if not patternFound:
    cache.patterns.add(PatternEntry(
      pattern: signature,
      frequency: 1,
      associatedKeys: @[key]
    ))
  
  # パターン数が多すぎる場合は頻度の低いものを削除
  if cache.patterns.len > 100:  # 最大パターン数
    cache.patterns.sort(proc(a, b: PatternEntry): int =
      return b.frequency - a.frequency  # 頻度の高い順
    )
    cache.patterns.setLen(100)

proc predictRelatedEntries(cache: CompressionCache, data: string): seq[string] =
  ## 関連するエントリの予測
  result = @[]
  if cache.mode != ccmPredictive and cache.mode != ccmSmart:
    return
  
  let signature = extractSignature(data)
  
  # パターンマッチング
  for pattern in cache.patterns:
    if pattern.frequency >= MIN_CACHE_HITS_FOR_PREDICTION:
      # 簡易類似度チェック
      if pattern.pattern.len == signature.len:
        var matches = 0
        for i in 0..<signature.len:
          if abs(pattern.pattern[i].ord - signature[i].ord) < 10:
            inc matches
        
        let similarity = matches.float / signature.len.float
        if similarity > 0.7:  # 70%以上一致
          for key in pattern.associatedKeys:
            if key notin result:
              result.add(key)

proc updateStats(cache: CompressionCache) =
  ## 統計情報の更新
  let total = cache.stats.hits + cache.stats.misses
  if total > 0:
    cache.stats.hitRatio = cache.stats.hits.float / total.float

proc compress*(cache: CompressionCache, data: string, 
              algorithm: string = "", 
              hints: CompressionAlgorithmHint = cahNone): string =
  ## データを圧縮し、キャッシュに保存
  inc cache.operationCount
  
  # アルゴリズムヒントの自動検出
  let actualHints = 
    if hints == cahNone: detectDataType(data)
    else: hints
  
  # キャッシュキーの生成
  let key = generateCacheKey(data, algorithm)
  
  # キャッシュのチェック
  if key in cache.entries:
    # キャッシュヒット
    let entry = cache.entries[key]
    updateLRU(cache, key)
    updateLFU(cache, key)
    
    # 最終アクセス時間の更新
    var updatedEntry = entry
    updatedEntry.lastAccessed = epochTime()
    updatedEntry.accessCount += 1
    cache.entries[key] = updatedEntry
    
    inc cache.stats.hits
    updateStats(cache)
    
    return entry.compressedData
  
  # 予測キャッシングの確認
  let predictedKeys = predictRelatedEntries(cache, data)
  for predictedKey in predictedKeys:
    if predictedKey in cache.entries:
      let entry = cache.entries[predictedKey]
      # 高度な検証を行う場合はここで実装
      
      # 予測が正確だった場合
      updateLRU(cache, predictedKey)
      updateLFU(cache, predictedKey)
      
      var updatedEntry = entry
      updatedEntry.lastAccessed = epochTime()
      updatedEntry.accessCount += 1
      cache.entries[predictedKey] = updatedEntry
      
      inc cache.stats.hits
      updateStats(cache)
      
      return entry.compressedData
  
  # キャッシュミス - 圧縮の実行
  inc cache.stats.misses
  
  let startTime = epochTime()
  var compressedData: string
  
  # 適切なアルゴリズムの選択
  let actualAlgorithm = 
    if algorithm.len > 0: algorithm
    else:
      case actualHints:
        of cahText: "deflate"  # テキストデータに適した圧縮
        of cahBinary: "lz4"    # バイナリデータに適した圧縮
        of cahImage: "zstd"    # 画像データに適した圧縮
        of cahAudio, cahVideo: "zstd"  # メディアデータに適した圧縮
        of cahPreCompressed: "none"    # 既に圧縮済みの場合
        else: "auto"  # 自動選択
  
  # 圧縮アルゴリズムの実行
  if cache.useSimd and actualAlgorithm != "none":
    # SIMD圧縮の利用
    let options = newSimdCompressionOptions(
      level: 
        if actualHints == cahPreCompressed: sclFastest
        else: sclDefault
    )
    compressedData = compressSimd(data, options)
  else:
    # 通常の圧縮
    case actualAlgorithm:
      of "deflate":
        compressedData = compressDeflate(data, compressionLevel = 
          if cache.performanceMode == cpmSpeed: 1
          elif cache.performanceMode == cpmBalanced: 6
          else: 9)
      of "lz4":
        compressedData = compressLz4(data, accelerationFactor = 
          if cache.performanceMode == cpmSpeed: 8
          elif cache.performanceMode == cpmBalanced: 4
          else: 1)
      of "zstd":
        compressedData = compressZstd(data, compressionLevel = 
          if cache.performanceMode == cpmSpeed: 1
          elif cache.performanceMode == cpmBalanced: 3
          else: 19)
      of "brotli":
        compressedData = compressBrotli(data, quality = 
          if cache.performanceMode == cpmSpeed: 1
          elif cache.performanceMode == cpmBalanced: 5
          else: 11)
      of "none":
        compressedData = data
      of "auto":
        # データサイズに基づいた自動選択
        if data.len < 1024:  # 小さいデータ
          compressedData = compressLz4(data)
        elif data.len < 1_000_000:  # 中程度のデータ
          compressedData = compressZstd(data)
        else:  # 大きいデータ
          compressedData = compressBrotli(data)
      else:
        # デフォルトはzstd
        compressedData = compressZstd(data)
  
  let endTime = epochTime()
  let compressionTime = (endTime - startTime) * 1000.0  # ミリ秒
  
  # キャッシュに追加
  addEntry(cache, key, data, compressedData, actualAlgorithm, compressionTime, actualHints)
  
  # パターン分析の更新
  updatePatternAnalysis(cache, key, data)
  
  # 定期的なメンテナンス
  if cache.operationCount mod LRU_UPDATE_FREQUENCY == 0:
    evictEntries(cache)
  
  updateStats(cache)
  
  return compressedData

proc decompress*(cache: CompressionCache, compressedData: string): Option[string] =
  ## キャッシュから圧縮データを解凍
  if compressedData.len == 0:
    return none(string)
  
  # キャッシュからのデータ探索
  # 注: 実際の実装では、逆参照テーブルか別の検索方法が必要
  var foundEntry: Option[CompressionCacheEntry]
  var foundKey: string
  
  for key, entry in cache.entries:
    if entry.compressedData == compressedData:
      foundEntry = some(entry)
      foundKey = key
      break
  
  if foundEntry.isSome:
    # キャッシュヒット - エントリ情報の更新
    updateLRU(cache, foundKey)
    updateLFU(cache, foundKey)
    
    var updatedEntry = foundEntry.get
    updatedEntry.lastAccessed = epochTime()
    updatedEntry.accessCount += 1
    cache.entries[foundKey] = updatedEntry
    
    # ここでは圧縮データと元データの関連付けが既知と仮定
    # 実際には解凍処理が必要な場合もある
    
    inc cache.stats.hits
    updateStats(cache)
    
    # 元データの返却 (この例では単純化)
    return some("")  # 実際の実装では元データを返す
  
  # キャッシュミス - 解凍処理
  inc cache.stats.misses
  
  let startTime = epochTime()
  var decompressedData: string
  
  # SIMDが使用可能な場合はSIMD解凍を試みる
  if cache.useSimd:
    try:
      decompressedData = decompressSimd(compressedData)
    except:
      # SIMD解凍に失敗した場合、通常の解凍を試みる
      decompressedData = ""  # プレースホルダ
  else:
    # 通常の解凍（ここでは基本実装として簡略化）
    decompressedData = ""  # プレースホルダ
  
  let endTime = epochTime()
  let decompressionTime = (endTime - startTime) * 1000.0  # ミリ秒
  
  # 統計情報の更新
  let totalDecompressions = cache.stats.hits + cache.stats.misses
  if totalDecompressions > 0:
    cache.stats.averageDecompressionTime = 
      ((cache.stats.averageDecompressionTime * (totalDecompressions - 1)) + decompressionTime) / 
      totalDecompressions.float
  
  updateStats(cache)
  
  if decompressedData.len > 0:
    return some(decompressedData)
  else:
    return none(string)

proc getStats*(cache: CompressionCache): CompressionCacheStats =
  ## キャッシュの統計情報を取得
  updateStats(cache)
  return cache.stats

proc clearCache*(cache: CompressionCache) =
  ## キャッシュの完全クリア
  cache.entries.clear()
  cache.accessOrder.setLen(0)
  cache.accessCounters.clear()
  cache.patterns.setLen(0)
  cache.currentSize = 0
  
  # 統計情報のリセット
  cache.stats.totalEntries = 0
  cache.stats.totalMemoryUsage = 0
  cache.stats.evictions += cache.stats.totalEntries

proc removeEntry*(cache: CompressionCache, key: string): bool =
  ## 特定のキャッシュエントリを削除
  if key in cache.entries:
    let entrySize = cache.entries[key].compressedSize
    cache.currentSize -= entrySize
    cache.entries.del(key)
    
    let idx = cache.accessOrder.find(key)
    if idx != -1:
      cache.accessOrder.delete(idx)
    
    cache.accessCounters.del(key)
    
    # 統計情報の更新
    cache.stats.totalEntries = cache.entries.len
    cache.stats.totalMemoryUsage = cache.currentSize
    inc cache.stats.evictions
    
    return true
  
  return false

proc getCacheEntryInfo*(cache: CompressionCache, key: string): Option[tuple[
  originalSize: int, 
  compressedSize: int, 
  ratio: float, 
  algorithm: string,
  accessCount: int,
  lastAccessed: float
]] =
  ## キャッシュエントリの情報を取得
  if key in cache.entries:
    let entry = cache.entries[key]
    return some((
      originalSize: entry.originalSize,
      compressedSize: entry.compressedSize,
      ratio: entry.compressionRatio,
      algorithm: entry.algorithm,
      accessCount: entry.accessCount,
      lastAccessed: entry.lastAccessed
    ))
  
  return none(tuple[
    originalSize: int, 
    compressedSize: int, 
    ratio: float, 
    algorithm: string,
    accessCount: int,
    lastAccessed: float
  ])

proc optimizeCache*(cache: CompressionCache) =
  ## キャッシュの最適化
  # 未使用エントリの削除
  let currentTime = epochTime()
  var keysToRemove: seq[string] = @[]
  
  for key, entry in cache.entries:
    # 長時間アクセスされていないエントリを削除
    if currentTime - entry.lastAccessed > cache.entryTTL * 2:
      keysToRemove.add(key)
  
  # エントリの削除
  for key in keysToRemove:
    discard removeEntry(cache, key)
  
  # パターン分析の最適化
  cache.patterns.sort(proc(a, b: PatternEntry): int =
    return b.frequency - a.frequency  # 頻度の高い順
  )
  
  # 頻度の低いパターンを削除
  if cache.patterns.len > 50:
    cache.patterns.setLen(50)

proc resizeCache*(cache: CompressionCache, newSize: int64) =
  ## キャッシュサイズの変更
  if newSize < 0:
    return
  
  cache.maxCacheSize = newSize
  
  # サイズが縮小された場合、必要に応じてエントリを削除
  if cache.currentSize > cache.maxCacheSize:
    evictEntries(cache, cache.currentSize - cache.maxCacheSize)

proc getCacheMemoryUsage*(cache: CompressionCache): int64 =
  ## 現在のキャッシュメモリ使用量
  var totalUsage: int64 = cache.currentSize
  
  # 管理オーバーヘッドの追加
  totalUsage += sizeof(CompressionCache)
  totalUsage += sizeof(int) * cache.accessOrder.len
  totalUsage += sizeof(int) * 2 * cache.accessCounters.len
  totalUsage += sizeof(PatternEntry) * cache.patterns.len
  
  for pattern in cache.patterns:
    totalUsage += pattern.pattern.len
    totalUsage += sizeof(int) * pattern.associatedKeys.len
    for key in pattern.associatedKeys:
      totalUsage += key.len
  
  return totalUsage

proc getCompressionEfficiency*(cache: CompressionCache): float =
  ## 圧縮効率の計算
  if cache.stats.totalUncompressedBytes == 0:
    return 0.0
  
  return 1.0 - (cache.stats.totalCompressedBytes.float / cache.stats.totalUncompressedBytes.float) 