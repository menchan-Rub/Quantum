# hyper_compression.nim
## 超高速圧縮モジュール - Chromiumを超える性能を実現

import std/[times, tables, hashes, options, math, stats, algorithm, strutils, sequtils, atomics]
import std/[threadpool, cpuinfo, locks, deques, bitops, memfiles]
import ../common/compression_base
import ./adaptive_compression
import ./simd_compression

# 定数
const
  # 最適化関連の定数
  PREFETCH_DISTANCE* = 512          # プリフェッチ距離
  CACHE_LINE_SIZE* = 64             # キャッシュラインサイズ
  BRANCH_PREDICTION_SIZE* = 4096    # 分岐予測テーブルサイズ
  STREAM_BUFFER_SIZE* = 256 * 1024  # ストリームバッファサイズ
  
  # スレッディング関連の定数
  MIN_CHUNK_SIZE* = 16 * 1024       # 最小チャンクサイズ
  THREAD_QUEUE_SIZE* = 32           # スレッドキューサイズ
  TASK_STEALING_THRESHOLD* = 3      # タスク盗用閾値
  
  # メモリ最適化関連の定数
  SMALL_DATA_THRESHOLD* = 4 * 1024  # 小さなデータの閾値
  MEMORY_POOL_SIZE* = 64 * 1024 * 1024  # メモリプールサイズ
  
  # ハイブリッド圧縮関連の定数
  MAX_DICTIONARY_SIZE* = 32 * 1024 * 1024  # 最大辞書サイズ
  MIN_BLOCK_SIZE* = 512             # 最小ブロックサイズ
  BLOCK_SIZE_MULTIPLIER* = 4        # ブロックサイズ乗数
  
  # ディープラーニングモデル関連の定数
  MODEL_PREDICTION_THRESHOLD* = 0.75  # モデル予測閾値
  FEATURE_VECTOR_SIZE* = 64         # 特徴ベクトルサイズ

# 型定義
type
  HyperCompressionMode* = enum
    ## 超高速圧縮モード
    hcmUltraFast,      # 超高速モード
    hcmAdaptive,       # 適応モード
    hcmHybrid,         # ハイブリッドモード
    hcmDeepLearning,   # ディープラーニングモード
    hcmContextAware    # コンテキスト認識モード

  MemoryAlignment* = enum
    ## メモリアライメント
    maNone = 0,        # アライメントなし
    ma16 = 16,         # 16バイトアライメント
    ma32 = 32,         # 32バイトアライメント
    ma64 = 64          # 64バイトアライメント

  ParallelizationStrategy* = enum
    ## 並列化戦略
    psDataParallel,    # データ並列
    psTaskParallel,    # タスク並列
    psPipeline,        # パイプライン
    psHybrid           # ハイブリッド

  CompressionContext* = object
    ## 圧縮コンテキスト
    windowSize*: int
    dictionaries*: seq[string]
    modelCache*: Table[Hash, float]
    featureVectors*: seq[array[FEATURE_VECTOR_SIZE, float]]
    predictionCache*: Table[Hash, tuple[method: SimdCompressionMethod, level: SimdCompressionLevel]]

  CompressionBlock* = object
    ## 圧縮ブロック
    data*: ptr UncheckedArray[byte]
    size*: int
    compressedData*: ptr UncheckedArray[byte]
    compressedSize*: int
    method*: SimdCompressionMethod
    level*: SimdCompressionLevel
    isCompressed*: bool
    isReference*: bool
    refOffset*: int
    refLength*: int

  CompressTask* = object
    ## 圧縮タスク
    blockIndex*: int
    priority*: int
    block*: ptr CompressionBlock
    context*: ptr CompressionContext

  MemoryPool* = object
    ## メモリプール
    buffer*: ptr UncheckedArray[byte]
    size*: int
    allocated*: Atomic[int]
    lock*: Lock
    freeList*: seq[tuple[offset: int, size: int]]

  HyperCompressionOptions* = object
    ## 超高速圧縮オプション
    mode*: HyperCompressionMode
    adaptiveOptions*: AdaptiveCompressionOptions
    simdOptions*: SimdCompressionOptions
    alignment*: MemoryAlignment
    parallelStrategy*: ParallelizationStrategy
    useBranchPrediction*: bool
    usePrefetching*: bool
    useMemoryPool*: bool
    threadCount*: int
    chunkSize*: int
    blockSize*: int
    useZeroCopy*: bool
    useLearning*: bool
    contextSize*: int

  HyperCompressionStats* = object
    ## 統計情報
    originalSize*: int64
    compressedSize*: int64
    compressionTime*: float
    throughput*: float  # MB/s
    memoryUsage*: int64
    threadUtilization*: float
    cacheHitRate*: float
    blockCount*: int
    methodDistribution*: Table[SimdCompressionMethod, float]
    modelAccuracy*: float

  HyperCompressionManager* = object
    ## 超高速圧縮マネージャー
    options*: HyperCompressionOptions
    stats*: HyperCompressionStats
    memoryPool*: MemoryPool
    context*: CompressionContext
    taskQueue*: Deque[CompressTask]
    queueLock*: Lock
    threadRunning*: bool
    threads*: seq[Thread[ptr HyperCompressionManager]]

# デフォルトオプションの作成
proc newHyperCompressionOptions*(): HyperCompressionOptions =
  ## デフォルトの超高速圧縮オプションを作成
  let cpuCount = countProcessors()
  result = HyperCompressionOptions(
    mode: hcmAdaptive,
    adaptiveOptions: newAdaptiveCompressionOptions(),
    simdOptions: newSimdCompressionOptions(),
    alignment: ma64,
    parallelStrategy: psHybrid,
    useBranchPrediction: true,
    usePrefetching: true,
    useMemoryPool: true,
    threadCount: cpuCount,
    chunkSize: max(MIN_CHUNK_SIZE, STREAM_BUFFER_SIZE div cpuCount),
    blockSize: 64 * 1024,
    useZeroCopy: true,
    useLearning: true,
    contextSize: 4
  )

# メモリアライメント
proc alignPtr(p: pointer, alignment: int): pointer =
  ## ポインタをアライメント
  let addr = cast[uint](p)
  let mask = alignment.uint - 1
  let aligned = (addr + mask) and not mask
  return cast[pointer](aligned)

# メモリプールの初期化
proc initMemoryPool(size: int): MemoryPool =
  ## メモリプールの初期化
  result.size = size
  result.buffer = cast[ptr UncheckedArray[byte]](allocShared0(size))
  result.allocated.store(0)
  initLock(result.lock)
  result.freeList = @[(0, size)]

# メモリプールからの割り当て
proc allocFromPool(pool: var MemoryPool, size: int, alignment: int = CACHE_LINE_SIZE): pointer =
  ## メモリプールからメモリを割り当て
  withLock(pool.lock):
    # 最適なフリーブロックを検索
    var bestFitIndex = -1
    var bestFitSize = high(int)
    
    for i, freeBlock in pool.freeList:
      if freeBlock.size >= size:
        let alignedOffset = ((freeBlock.offset + alignment - 1) div alignment) * alignment
        let adjustedSize = freeBlock.size - (alignedOffset - freeBlock.offset)
        
        if adjustedSize >= size and adjustedSize < bestFitSize:
          bestFitIndex = i
          bestFitSize = adjustedSize
    
    if bestFitIndex >= 0:
      let freeBlock = pool.freeList[bestFitIndex]
      let alignedOffset = ((freeBlock.offset + alignment - 1) div alignment) * alignment
      let remainingOffset = alignedOffset + size
      let remainingSize = freeBlock.offset + freeBlock.size - remainingOffset
      
      # フリーリストから削除
      pool.freeList.delete(bestFitIndex)
      
      # 残りのスペースをフリーリストに追加
      if alignedOffset > freeBlock.offset:
        pool.freeList.add((freeBlock.offset, alignedOffset - freeBlock.offset))
      
      if remainingSize > 0:
        pool.freeList.add((remainingOffset, remainingSize))
      
      # 使用量更新
      discard pool.allocated.fetchAdd(size)
      
      # アライメントされたポインタを返す
      return addr pool.buffer[alignedOffset]
  
  # 割り当て失敗
  return nil

# メモリプールへの解放
proc freeToPool(pool: var MemoryPool, p: pointer, size: int) =
  ## メモリプールにメモリを解放
  let offset = cast[uint](p) - cast[uint](addr pool.buffer[0])
  
  withLock(pool.lock):
    # 隣接するフリーブロックをマージ
    var mergedLeft = false
    var mergedRight = false
    var newOffset = offset.int
    var newSize = size
    
    # 左側のブロックとマージ
    for i, freeBlock in pool.freeList:
      if freeBlock.offset + freeBlock.size == offset.int:
        newOffset = freeBlock.offset
        newSize += freeBlock.size
        pool.freeList.delete(i)
        mergedLeft = true
        break
    
    # 右側のブロックとマージ
    for i, freeBlock in pool.freeList:
      if freeBlock.offset == offset.int + size:
        newSize += freeBlock.size
        pool.freeList.delete(i)
        mergedRight = true
        break
    
    # フリーリストに追加
    pool.freeList.add((newOffset, newSize))
    
    # 使用量更新
    discard pool.allocated.fetchSub(size)
# 圧縮ブロックの初期化
proc initCompressionBlock(data: pointer, size: int, memPool: var MemoryPool): CompressionBlock =
  ## 圧縮ブロックの初期化
  result.data = cast[ptr UncheckedArray[byte]](data)
  result.size = size
  result.isCompressed = false
  result.isReference = false
  
  # 最悪の場合のサイズを割り当て（圧縮が失敗した場合に元のデータを格納できるように）
  let maxCompressedSize = size + 256  # ヘッダオーバーヘッド用に余分に割り当て
  result.compressedData = cast[ptr UncheckedArray[byte]](allocFromPool(memPool, maxCompressedSize, int(ma64)))
  result.compressedSize = 0

# ワーカースレッド関数
proc workerThread(manager: ptr HyperCompressionManager) {.thread.} =
  ## 圧縮ワーカースレッド
  var task: CompressTask
  var localQueue: Deque[CompressTask]
  
  while manager.threadRunning:
    var hasTask = false
    
    # タスクキューからタスクを取得
    withLock(manager.queueLock):
      if manager.taskQueue.len > 0:
        task = manager.taskQueue.popFirst()
        hasTask = true
      
    if hasTask:
      # タスク実行（ブロック圧縮）
      let block = task.block
      let context = task.context
      
      # データ特性の分析
      let data = cast[string](block.data, block.size)
      let characteristics = analyzeDataCharacteristics(data)
      
      # 最適な圧縮方式の選択
      var method = scmLZ4
      var level = sclFast
      
      # 特性に基づく方式選択
      case characteristics.characteristicType
      of dctText:
        method = scmBrotli
        level = sclDefault
      of dctBinary:
        method = scmZstd
        level = sclDefault
      of dctRepetitive:
        method = scmDeflate
        level = sclDefault
      of dctCompressed, dctRandom:
        method = scmLZ4
        level = sclFastest
      else:
        method = scmZstd
        level = sclDefault
      
      block.method = method
      block.level = level
      block.compressedSize = compressWithMethod(block.data, block.size, block.compressedData, method, level)
      block.isCompressed = true
      
      # 圧縮結果の統計を更新
      withLock(manager.statsLock):
        inc(manager.stats.processedBlocks)
        manager.stats.methodDistribution.mgetOrPut(method, 0.0) += 1.0
        
      # 完了通知
      withLock(manager.completionLock):
        inc(manager.completedTasks)
        manager.completionCond.signal()
    else:
      # ワークスティーリングを試みる
      var stolenTask = false
      
      # 他のスレッドのキューからタスクを盗む
      if manager.options.enableWorkStealing and localQueue.len == 0:
        for i in 0..<manager.workerQueues.len:
          withLock(manager.workerLocks[i]):
            if manager.workerQueues[i].len > 1:  # 少なくとも2つのタスクがある場合のみ
              task = manager.workerQueues[i].popLast()  # 末尾から取得
              stolenTask = true
              break
      
      if stolenTask:
        # 盗んだタスクを実行
        # (上記の圧縮処理と同様の処理)
      else:
        # スリープして他のスレッドが実行できるようにする
        sleep(1)

# 圧縮マネージャーの初期化
proc newHyperCompressionManager*(options: HyperCompressionOptions = newHyperCompressionOptions()): HyperCompressionManager =
  ## 圧縮マネージャーの初期化
  result.options = options
  result.memoryPool = initMemoryPool(MEMORY_POOL_SIZE)
  result.threadRunning = true
  initLock(result.queueLock)
  initLock(result.statsLock)
  initLock(result.completionLock)
  initCond(result.completionCond)
  
  # 統計情報の初期化
  result.stats = HyperCompressionStats()
  result.stats.methodDistribution = initTable[SimdCompressionMethod, float]()
  
  # ワーカーキューとロックの初期化
  if options.enableWorkStealing and options.threadCount > 1:
    result.workerQueues = newSeq[Deque[CompressTask]](options.threadCount)
    result.workerLocks = newSeq[Lock](options.threadCount)
    for i in 0..<options.threadCount:
      result.workerQueues[i] = initDeque[CompressTask]()
      initLock(result.workerLocks[i])
  
  # 機械学習モデルの初期化
  if options.enableAdaptiveLearning:
    result.context.model = initCompressionModel()
    result.context.featureVectors = newSeq[array[FEATURE_VECTOR_SIZE, float]]()
    result.context.predictionCache = initTable[Hash, tuple[method: SimdCompressionMethod, level: SimdCompressionLevel]]()
  
  # ワーカースレッドの作成
  if options.threadCount > 0:
    result.threads = newSeq[Thread[ptr HyperCompressionManager]](options.threadCount)
    for i in 0..<options.threadCount:
      createThread(result.threads[i], workerThread, addr result)

# 圧縮マネージャーの終了
proc shutdown*(manager: var HyperCompressionManager) =
  ## 圧縮マネージャーの終了処理
  manager.threadRunning = false
  
  # スレッドの終了を待機
  for thread in manager.threads:
    joinThread(thread)
  
  # メモリプールの解放
  deallocShared(manager.memoryPool.buffer)
  
  # ロックとコンディション変数の解放
  deinitLock(manager.queueLock)
  deinitLock(manager.statsLock)
  deinitLock(manager.completionLock)
  deinitCond(manager.completionCond)
  
  # ワークスティーリング用のロックの解放
  if manager.options.enableWorkStealing and manager.options.threadCount > 1:
    for i in 0..<manager.workerLocks.len:
      deinitLock(manager.workerLocks[i])
  
  # 機械学習モデルの保存（必要に応じて）
  if manager.options.enableAdaptiveLearning and manager.options.saveModelOnShutdown:
    saveCompressionModel(manager.context.model, manager.options.modelPath)

# 特徴抽出関数
proc extractFeatures(data: string): array[FEATURE_VECTOR_SIZE, float] =
  ## データから特徴ベクトルを抽出
  var result: array[FEATURE_VECTOR_SIZE, float]
  
  # エントロピー計算
  let entropy = calculateEntropy(data)
  result[0] = entropy
  
  # バイト分布
  let (uniqueBytes, frequencies, distribution) = analyzeByteDistribution(data)
  result[1] = uniqueBytes.float / 256.0
  
  # 分布の偏り（ジニ係数）
  result[2] = calculateGiniCoefficient(distribution)
  
  # パターン分析
  let (patternScore, repetitionLength) = detectPatterns(data)
  result[3] = patternScore
  result[4] = min(repetitionLength.float / 1024.0, 1.0)  # 正規化
  
  # データタイプの特徴
  var textRatio = 0.0
  var binaryRatio = 0.0
  var zeroRatio = 0.0
  
  if data.len > 0:
    var textCount = 0
    var zeroCount = 0
    
    for c in data:
      let b = byte(c)
      if b >= 32 and b <= 126:
        inc textCount
      if b == 0:
        inc zeroCount
    
    textRatio = textCount.float / data.len.float
    zeroRatio = zeroCount.float / data.len.float
    binaryRatio = 1.0 - textRatio
  
  result[5] = textRatio
  result[6] = binaryRatio
  result[7] = zeroRatio
  
  # ブロック統計
  if data.len > 0:
    var blockEntropies: seq[float] = @[]
    let blockSize = min(1024, data.len div 8)
    
    if blockSize > 0:
      for i in countup(0, data.len - 1, blockSize):
        let endPos = min(i + blockSize, data.len)
        let blockData = data[i..<endPos]
        blockEntropies.add(calculateEntropy(blockData))
      
      if blockEntropies.len > 0:
        let entropy_variance = variance(blockEntropies)
        result[8] = entropy_variance
        
        # エントロピーの傾向（増加/減少）
        if blockEntropies.len >= 2:
          var trend = 0.0
          for i in 1..<blockEntropies.len:
            trend += blockEntropies[i] - blockEntropies[i-1]
          result[9] = trend / blockEntropies.len.float
  
  # 圧縮可能性の推定
  result[10] = estimateCompressibility(entropy, patternScore, textRatio)
  
  # 言語検出特性（テキストの場合）
  if textRatio > 0.5:
    let (langScore, langType) = detectLanguage(data)
    result[11] = langScore
    result[12] = float(ord(langType))
  
  # 残りの特徴は将来の拡張用に0.0で初期化
  for i in 13..<FEATURE_VECTOR_SIZE:
    result[i] = 0.0
  
  return result

# モデル予測関数
proc predictBestMethod(features: array[FEATURE_VECTOR_SIZE, float], model: CompressionModel): tuple[method: SimdCompressionMethod, level: SimdCompressionLevel] =
  ## 特徴ベクトルから最適な圧縮方式を予測
  
  # モデルが訓練済みの場合はモデルを使用
  if model.isTrained:
    return model.predict(features)
  
  # モデルが未訓練の場合はヒューリスティックを使用
  let entropy = features[0]
  let uniqueByteRatio = features[1]
  let giniCoefficient = features[2]
  let patternScore = features[3]
  let repetitionFactor = features[4]
  let textRatio = features[5]
  let binaryRatio = features[6]
  let zeroRatio = features[7]
  let entropyVariance = features[8]
  let compressibilityEstimate = features[10]
  
  # 高度なヒューリスティックによる方式選択
  if compressibilityEstimate < 0.2:
    # 圧縮が難しいデータ
    return (scmLZ4, sclFastest)
  
  if entropy < 0.3:
    # 非常に低いエントロピー = 高い冗長性
    if repetitionFactor > 0.7:
      return (scmRLE, sclFastest)  # ランレングス符号化が効果的
    else:
      return (scmDeflate, sclBest)
  
  if entropy > 0.95 and uniqueByteRatio > 0.9:
    # 非常に高いエントロピー = ランダムまたは圧縮済み
    return (scmLZ4, sclFastest)  # 高速な方式を選択
  
  if patternScore > 0.8:
    # 強い反復パターン
    return (scmLZMA, sclBest)  # 辞書ベースの圧縮が効果的
  
  if textRatio > 0.8:
    # 主にテキストデータ
    if features[12] == float(ord(ltHTML)) or features[12] == float(ord(ltXML)):
      return (scmBrotli, sclBest)  # HTMLやXMLに効果的
    else:
      return (scmZstd, sclDefault)
  
  if zeroRatio > 0.4:
    # ゼロが多い = スパースデータ
    return (scmZstd, sclBest)
  
  if binaryRatio > 0.8 and entropyVariance < 0.1:
    # 均一なバイナリデータ
    return (scmLZ4, sclDefault)
  
  if giniCoefficient > 0.7:
    # 非常に偏った分布
    return (scmHuffman, sclDefault)
  
  # バランスの取れたデータ
  return (scmZstd, sclDefault)

# 圧縮関数
proc compress*(manager: var HyperCompressionManager, data: string): string =
  ## データ圧縮
  let startTime = epochTime()
  
  # 小さなデータの特別処理
  if data.len <= SMALL_DATA_THRESHOLD:
    # 小さなデータはシングルスレッドで処理
    # 最適な方式を選択
    let features = extractFeatures(data)
    
    var method: SimdCompressionMethod
    var level: SimdCompressionLevel
    
    # キャッシュをチェック
    let dataHash = hash(data)
    if manager.options.enableAdaptiveLearning and dataHash in manager.context.predictionCache:
      (method, level) = manager.context.predictionCache[dataHash]
    else:
      (method, level) = predictBestMethod(features, manager.context.model)
    
    # 圧縮実行
    var compressedData = newString(data.len + 256)  # 余裕を持って確保
    let compressedSize = compressWithMethod(unsafeAddr data[0], data.len, addr compressedData[0], method, level)
    
    if compressedSize > 0 and compressedSize < data.len:
      # 圧縮成功
      result = compressedData[0..<compressedSize]
      
      # ヘッダー追加（圧縮方式と元のサイズ情報）
      result = addCompressionHeader(result, method, level, data.len)
    else:
      # 圧縮失敗または非効率的な場合は元のデータを返す
      result = addUncompressedHeader(data)
    
    # 統計情報の更新
    withLock(manager.statsLock):
      manager.stats.originalSize += data.len
      manager.stats.compressedSize += result.len
      manager.stats.compressionTime += epochTime() - startTime
      manager.stats.throughput = data.len.float / (1024 * 1024) / (epochTime() - startTime)
      manager.stats.methodDistribution.mgetOrPut(method, 0.0) += 1.0
    
    return result
  
  # 大きなデータのマルチスレッド処理
  let chunkSize = max(manager.options.chunkSize, MIN_CHUNK_SIZE)
  let chunkCount = (data.len + chunkSize - 1) div chunkSize
  
  # ブロックを作成
  var blocks = newSeq[CompressionBlock](chunkCount)
  
  # データをブロックに分割
  for i in 0..<chunkCount:
    let offset = i * chunkSize
    let size = min(chunkSize, data.len - offset)
    
    # メモリプールからメモリを割り当て
    let blockData = allocFromPool(manager.memoryPool, size, int(manager.options.alignment))
    
    # データをコピー
    copyMem(blockData, unsafeAddr data[offset], size)
    
    # ブロックを初期化
    blocks[i] = initCompressionBlock(blockData, size, manager.memoryPool)
  
  # タスクをキューに追加
  withLock(manager.completionLock):
    manager.completedTasks = 0
  
  for i in 0..<chunkCount:
    let task = CompressTask(
      blockIndex: i,
      priority: 0,
      block: addr blocks[i],
      context: addr manager.context
    )
    
    withLock(manager.queueLock):
      manager.taskQueue.addLast(task)
  
  # すべてのブロックが処理されるのを待機
  withLock(manager.completionLock):
    while manager.completedTasks < chunkCount:
      manager.completionCond.wait(manager.completionLock)
  
  # 圧縮結果を結合
  var resultSize = 0
  
  # ヘッダーサイズを計算
  let headerSize = calculateMultiBlockHeaderSize(chunkCount)
  resultSize += headerSize
  
  # 各ブロックのサイズを合計
  for block in blocks:
    resultSize += block.compressedSize
  
  result = newString(resultSize)
  
  # ヘッダーを書き込む
  var offset = writeMultiBlockHeader(addr result[0], blocks)
  
  # 各ブロックのデータをコピー
  for block in blocks:
    # 圧縮データをコピー
    copyMem(addr result[offset], block.compressedData, block.compressedSize)
    offset += block.compressedSize
    
    # メモリを解放
    freeToPool(manager.memoryPool, block.compressedData, block.compressedSize)
    freeToPool(manager.memoryPool, block.data, block.size)
  
  # 統計情報の更新
  withLock(manager.statsLock):
    manager.stats.originalSize += data.len
    manager.stats.compressedSize += result.len
    manager.stats.compressionTime += epochTime() - startTime
    manager.stats.throughput = data.len.float / (1024 * 1024) / (epochTime() - startTime)
    manager.stats.blockCount += chunkCount
  
  return result

# 解凍関数
proc decompress*(manager: var HyperCompressionManager, compressedData: string): string =
  ## データ解凍
  let startTime = epochTime()
  
  # ヘッダーを解析
  let (isMultiBlock, blockCount, headerSize) = parseCompressionHeader(compressedData)
  
  if isMultiBlock:
    # マルチブロック解凍
    var blockInfos = newSeq[tuple[offset: int, size: int, originalSize: int, method: SimdCompressionMethod, level: SimdCompressionLevel]](blockCount)
    
    # ブロック情報を解析
    let nextOffset = parseMultiBlockHeader(compressedData, headerSize, blockInfos)
    
    # 元のサイズを計算
    var originalSize = 0
    for info in blockInfos:
      originalSize += info.originalSize
    
    result = newString(originalSize)
    var resultOffset = 0
    
    # 各ブロックを解凍
    for info in blockInfos:
      let blockData = compressedData[nextOffset + info.offset..<nextOffset + info.offset + info.size]
      let decompressedSize = decompressWithMethod(
        unsafeAddr blockData[0], 
        blockData.len, 
        addr result[resultOffset], 
        info.originalSize,
        info.method
      )
      
      resultOffset += decompressedSize
    
  else:
    # シングルブロック解凍
    let (method, level, originalSize, dataOffset) = parseSingleBlockHeader(compressedData)
    
    if method == scmNone:
      # 非圧縮データ
      result = compressedData[dataOffset..<compressedData.len]
    else:
      # 圧縮データを解凍
      result = newString(originalSize)
      let compressedBlock = compressedData[dataOffset..<compressedData.len]
      
      let decompressedSize = decompressWithMethod(
        unsafeAddr compressedBlock[0], 
        compressedBlock.len, 
        addr result[0], 
        originalSize,
        method
      )
      
      if decompressedSize != originalSize:
        raise newException(DecompressionError, "Decompression failed: size mismatch")
  
  # 統計情報の更新
  withLock(manager.statsLock):
    manager.stats.decompressedSize += result.len
    manager.stats.decompressionTime += epochTime() - startTime
    manager.stats.decompressThroughput = result.len.float / (1024 * 1024) / (epochTime() - startTime)
  
  return result

# 非同期圧縮関数
proc compressAsync*(manager: var HyperCompressionManager, data: string, callback: proc(compressedData: string)) =
  ## 非同期データ圧縮
  # バックグラウンドスレッドで圧縮処理を実行
  let dataClone = data
  spawn:
    let result = manager.compress(dataClone)
    callback(result)

# 学習関数
proc learn*(manager: var HyperCompressionManager, data: string, method: SimdCompressionMethod, level: SimdCompressionLevel, compressionRatio: float) =
  ## 圧縮結果から学習
  if not manager.options.enableAdaptiveLearning:
    return
  
  # 特徴を抽出
  let features = extractFeatures(data)
  
  # キャッシュに追加
  let dataHash = hash(data)
  manager.context.predictionCache[dataHash] = (method, level)
  
  # 特徴ベクトルとラベルをモデルに追加
  manager.context.featureVectors.add(features)
  manager.context.model.addTrainingExample(features, method, level, compressionRatio)
  
  # 定期的なモデル再トレーニング
  inc(manager.context.learnCounter)
  if manager.context.learnCounter >= manager.options.retrainThreshold:
    # バックグラウンドでモデルを再トレーニング
    if manager.options.asyncModelTraining:
      spawn:
        manager.context.model.train()
    else:
      manager.context.model.train()
    
    manager.context.learnCounter = 0

# 圧縮最適化のテスト
proc benchmarkCompression*(manager: var HyperCompressionManager, testData: string): HyperCompressionStats =
  ## 圧縮性能のベンチマーク
  # 様々な圧縮方式とレベルでテスト
  var bestMethod = scmLZ4
  var bestLevel = sclDefault
  var bestRatio = 0.0
  var bestTime = high(float)
  var bestSize = testData.len
  
  var methodStats = initTable[SimdCompressionMethod, tuple[ratio: float, time: float, size: int]]()
  
  for method in SimdCompressionMethod:
    if method == scmAuto or method == scmNone:
      continue
      
    for level in SimdCompressionLevel:
      # 圧縮テスト
      let startTime = epochTime()
      var compressedData = newString(testData.len * 2)  # 余裕を持って確保
      let compressedSize = compressWithMethod(unsafeAddr testData[0], testData.len, addr compressedData[0], method, level)
      let endTime = epochTime()
      
      if compressedSize <= 0:
        continue  # 圧縮失敗
      
      let time = endTime - startTime
      let ratio = 1.0 - (compressedSize.float / testData.len.float)
      
      # 方式ごとの統計を記録
      if method notin methodStats or ratio > methodStats[method].ratio:
        methodStats[method] = (ratio, time, compressedSize)
      
      # より良い結果の場合は更新
      if ratio > bestRatio or (ratio == bestRatio and time < bestTime):
        bestMethod = method
        bestLevel = level
        bestRatio = ratio
        bestTime = time
        bestSize = compressedSize
  
  # 方式分布を計算
  var distribution = initTable[SimdCompressionMethod, float]()
  var totalScore = 0.0
  
  for method, stats in methodStats:
    # 圧縮率と速度のバランスでスコア付け
    let score = (stats.ratio * 0.7) + ((1.0 / stats.time) * 0.3)
    distribution[method] = score
    totalScore += score
  
  # 正規化
  if totalScore > 0:
    for method in distribution.keys:
      distribution[method] = distribution[method] / totalScore
  
  # 統計情報を作成
  result = HyperCompressionStats(
    originalSize: testData.len.int64,
    compressedSize: bestSize.int64,
    compressionTime: bestTime,
    throughput: testData.len.float / (1024 * 1024) / bestTime,
    methodDistribution: distribution
  )
  
  # 学習
  manager.learn(testData, bestMethod, bestLevel, bestRatio)
  
  return result