# optimization.nim
## 圧縮アルゴリズムのための共通最適化モジュール

import std/[cpuinfo, atomics, os, tables, hashes, locks, times, threadpool, options, strutils]
import ./compression_base

# 最適化定数
const
  # キャッシュ定数
  MAX_COMPRESSION_CACHE_SIZE* = 512  # キャッシュに保存する最大アイテム数
  MAX_SINGLE_CACHE_ENTRY_SIZE* = 10 * 1024 * 1024  # キャッシュに保存する最大サイズ (10MB)
  CACHE_THRESHOLD_SIZE* = 16 * 1024  # キャッシュを使用する最小サイズ (16KB)
  DEFAULT_PARALLELIZATION_THRESHOLD* = 256 * 1024  # 並列化を考慮する最小サイズ (256KB)
  
  # システム最適化定数
  MIN_CACHE_REUSE_TIME_MS* = 100     # キャッシュエントリを再利用する最短時間 (ms)
  MAX_COMPRESSION_WORKERS* = 8       # 圧縮タスクの最大ワーカー数
  CPU_UTILIZATION_TARGET* = 0.75     # ターゲットCPU使用率
  
# CPU機能検出
var
  supportsSSE2* = cpuinfo.hasSSE2()
  supportsSSE4* = cpuinfo.hasSSE4()
  supportsAVX* = cpuinfo.hasAVX()
  supportsAVX2* = cpuinfo.hasAVX2()
  supportsSIMD* = supportsSSE2 or supportsSSE4 or supportsAVX or supportsAVX2

# 自動チューニング用のパラメータ
var
  optimalThreadCount* = max(1, countProcessors() - 1)
  optimalBufferSize* = 64 * 1024  # 64KB（デフォルト）
  adaptiveCompression* = true     # 適応型圧縮を有効化
  prioritizeBandwidth* = false    # 帯域幅優先（falseの場合はレイテンシ優先）

# グローバル圧縮キャッシュ
var
  globalCache* = CompressionCache(
    maxEntries: 1000,
    entries: initTable[Hash, string](),
    stats: {
      cfGzip: (0, 0),
      cfDeflate: (0, 0),
      cfBrotli: (0, 0),
      cfZstd: (0, 0),
      cfNone: (0, 0)
    }.toTable()
  )

initLock(globalCache.lock)

# グローバルキャッシュ
type
  CompressionCacheEntry = object
    ## 圧縮結果のキャッシュエントリ
    data: string          # 圧縮/解凍されたデータ
    format: CompressionFormat  # 圧縮形式
    level: int            # 圧縮レベル
    lastUsed: Time        # 最後に使用された時間
    size: int             # 元のデータサイズ
    compressedSize: int   # 圧縮後のサイズ
    hashValue: Hash       # ハッシュ値

# キャッシュテーブル
var compressionCache = initTable[Hash, CompressionCacheEntry]()

# キャッシュ管理
proc clearCache*() =
  ## 圧縮キャッシュをクリア
  compressionCache.clear()

proc cacheSize*(): int =
  ## 現在のキャッシュエントリ数を取得
  result = compressionCache.len

proc cacheTotalMemoryUsage*(): int =
  ## キャッシュが使用している合計メモリ量を取得
  result = 0
  for entry in compressionCache.values:
    result += entry.data.len

# 最適なスレッド数を計算
var cachedOptimalThreadCount = -1

proc optimalThreadCount*(): int =
  ## システムに最適なスレッド数を計算
  if cachedOptimalThreadCount > 0:
    return cachedOptimalThreadCount
  
  let cpuCount = countProcessors()
  
  # 最低1スレッド、最大はMAX_COMPRESSION_WORKERSまたはCPU数の小さい方
  result = max(1, min(cpuCount, MAX_COMPRESSION_WORKERS))
  
  # システムメモリに基づいて調整
  # 低メモリ環境では並列処理を制限
  when defined(windows):
    # Windowsの場合、メモリ情報を取得
    type
      MEMORYSTATUSEX {.pure.} = object
        dwLength: int32
        dwMemoryLoad: int32
        ullTotalPhys: int64
        ullAvailPhys: int64
        ullTotalPageFile: int64
        ullAvailPageFile: int64
        ullTotalVirtual: int64
        ullAvailVirtual: int64
        ullAvailExtendedVirtual: int64
    
    proc GlobalMemoryStatusEx(lpBuffer: ptr MEMORYSTATUSEX): int32 
      {.stdcall, dynlib: "kernel32", importc: "GlobalMemoryStatusEx".}
    
    var memStatus = MEMORYSTATUSEX(dwLength: sizeof(MEMORYSTATUSEX).int32)
    if GlobalMemoryStatusEx(addr memStatus) != 0:
      let availMemoryGB = memStatus.ullAvailPhys div (1024 * 1024 * 1024)
      if availMemoryGB < 2:  # 2GB未満
        result = max(1, result div 2)
      elif availMemoryGB > 16:  # 16GB以上
        result = min(MAX_COMPRESSION_WORKERS, result + 1)
  
  elif defined(linux) or defined(macosx):
    # UNIX系OSの場合
    try:
      when defined(linux):
        let memInfoFile = "/proc/meminfo"
        if fileExists(memInfoFile):
          let content = readFile(memInfoFile)
          let memAvailLine = content.split('\n').filterIt(it.startsWith("MemAvailable:"))
          if memAvailLine.len > 0:
            let memAvailStr = memAvailLine[0].split(':')[1].strip().split(' ')[0]
            let memAvailKB = parseInt(memAvailStr)
            let memAvailGB = memAvailKB div (1024 * 1024)
            if memAvailGB < 2:  # 2GB未満
              result = max(1, result div 2)
            elif memAvailGB > 16:  # 16GB以上
              result = min(MAX_COMPRESSION_WORKERS, result + 1)
      
      elif defined(macosx):
        # macOSの場合はvmstatコマンドを実行
        let (output, exitCode) = execCmdEx("vm_stat")
        if exitCode == 0:
          let lines = output.split('\n')
          var freePages = 0
          for line in lines:
            if line.startsWith("Pages free:"):
              let parts = line.split(':')
              if parts.len > 1:
                let pagesStr = parts[1].strip().split('.')[0]
                freePages = parseInt(pagesStr)
                break
          
          # ページサイズは通常4KB
          let freeMemoryGB = (freePages * 4096) div (1024 * 1024 * 1024)
          if freeMemoryGB < 2:  # 2GB未満
            result = max(1, result div 2)
          elif freeMemoryGB > 16:  # 16GB以上
            result = min(MAX_COMPRESSION_WORKERS, result + 1)
    except:
      # エラーが発生した場合はデフォルト値を使用
      discard
  
  # キャッシュに結果を保存
  cachedOptimalThreadCount = result
  return result

# ハッシュ計算
proc calculateDataHash*(data: string): Hash =
  ## データのハッシュ値を計算（キャッシュキー生成用）
  # 高速ハッシュ計算（大きなデータの場合はサンプリング）
  if data.len < 4096:
    # 小さなデータは完全にハッシュ
    result = hash(data)
  else:
    # 大きなデータはサンプリングしてハッシュ
    var combinedHash: Hash = 0
    
    # 先頭4KB
    combinedHash = hash(data[0..<4096])
    
    # 中間から4KB
    let midPoint = data.len div 2
    let midSample = data[max(0, midPoint - 2048)..<min(data.len, midPoint + 2048)]
    combinedHash = combinedHash !& hash(midSample)
    
    # 末尾4KB
    if data.len > 8192:
      let tailSample = data[^4096..^1]
      combinedHash = combinedHash !& hash(tailSample)
    
    # データ長を組み合わせる
    combinedHash = combinedHash !& hash(data.len)
    
    result = !$combinedHash

# キャッシュ処理
proc cleanupCache() =
  ## 古いキャッシュエントリを削除
  if compressionCache.len <= MAX_COMPRESSION_CACHE_SIZE:
    return
  
  # 使用時間でソートしたエントリリストを取得
  var entries: seq[tuple[key: Hash, lastUsed: Time]] = @[]
  for key, entry in compressionCache:
    entries.add((key, entry.lastUsed))
  
  # 最後に使用された時間で並べ替え
  entries.sort(proc(x, y: tuple[key: Hash, lastUsed: Time]): int =
    result = cmp(x.lastUsed, y.lastUsed))
  
  # 古いエントリから削除（キャッシュサイズの20%程度）
  let removeCount = max(1, compressionCache.len div 5)
  for i in 0..<removeCount:
    if i < entries.len:
      compressionCache.del(entries[i].key)

proc generateCacheKey*(data: string, format: CompressionFormat, level: int): Hash =
  ## キャッシュキーを生成
  let dataHash = calculateDataHash(data)
  result = dataHash !& hash(format) !& hash(level)
  result = !$result

proc getCachedCompressionResult*(data: string, format: CompressionFormat, level: int): Option[string] =
  ## キャッシュから圧縮/解凍結果を取得
  # 小さすぎるデータはキャッシュを使用しない
  if data.len < CACHE_THRESHOLD_SIZE:
    return none(string)
  
  let key = generateCacheKey(data, format, level)
  
  if key in compressionCache:
    var entry = compressionCache[key]
    
    # 最終使用時間を更新
    entry.lastUsed = getTime()
    compressionCache[key] = entry
    
    return some(entry.data)
  
  return none(string)

proc cacheCompressionResult*(input, output: string, format: CompressionFormat, level: int) =
  ## 圧縮/解凍結果をキャッシュに保存
  # 大きすぎるデータや小さすぎるデータはキャッシュしない
  if input.len < CACHE_THRESHOLD_SIZE or output.len > MAX_SINGLE_CACHE_ENTRY_SIZE:
    return
  
  # キャッシュが最大サイズに達した場合、クリーンアップ
  if compressionCache.len >= MAX_COMPRESSION_CACHE_SIZE:
    cleanupCache()
  
  let key = generateCacheKey(input, format, level)
  
  # 新しいエントリを作成
  let entry = CompressionCacheEntry(
    data: output,
    format: format,
    level: level,
    lastUsed: getTime(),
    size: input.len,
    compressedSize: output.len,
    hashValue: key
  )
  
  compressionCache[key] = entry

# コンテンツ分析
proc estimateCompressionRatio*(data: string, sampleSize: int = 4096): float =
  ## データの圧縮率を推定
  let sampleData = if data.len <= sampleSize: data
                   else: data[0..<sampleSize]
  
  # 文字の頻度分布を取得
  var freqs = initTable[char, int]()
  for c in sampleData:
    if c in freqs:
      inc freqs[c]
    else:
      freqs[c] = 1
  
  # シャノンエントロピーを計算
  var entropy: float = 0.0
  let sampleLen = sampleData.len.float
  
  for freq in freqs.values:
    let p = freq.float / sampleLen
    entropy -= p * log2(p)
  
  # エントロピーから圧縮率を推定
  # 理論的な最大圧縮率はエントロピーから計算可能
  # 8ビット文字のエントロピーは0.0〜8.0の範囲
  
  # エントロピーが高いほど圧縮率は低い
  # エントロピーが8.0に近いと、ほとんど圧縮できない
  let estimatedRatio = 1.0 - (entropy / 8.0)
  
  let adjustedRatio = max(0.05, min(0.95, estimatedRatio * 0.8))
  
  return adjustedRatio

proc getRecommendedCompressionFormat*(data: string): CompressionFormat =
  ## データ特性に基づいて最適な圧縮形式を推奨
  # データサイズが小さい場合は軽量圧縮を使用
  if data.len < 1024:
    return cfDeflate
  
  # サンプルデータを取得
  let sampleSize = min(8192, data.len)
  let sample = if data.len <= sampleSize: data
               else: data[0..<sampleSize]
  
  # テキストデータか判定
  let textChars = {'\t', '\n', '\r', ' '..'}
  var textRatio = 0.0
  var binaryCount = 0
  
  for i in 0..<min(1024, sample.len):
    let c = sample[i]
    if c in textChars or (c >= ' ' and c <= '~'):
      textRatio += 1.0
    elif ord(c) < 32 and c notin {'\t', '\n', '\r'}:
      inc binaryCount
  
  textRatio /= min(1024, sample.len).float
  
  # バイナリデータの検出（制御文字の多さで判断）
  let binaryRatio = binaryCount.float / min(1024, sample.len).float
  
  # エントロピーを計算
  let entropy = estimateCompressionRatio(sample)
  
  # データ特性に基づいて圧縮形式を選択
  if textRatio > 0.9:
    # テキストデータ
    if data.len > 100 * 1024:  # 100KB以上
      return cfBrotli  # テキスト向け高圧縮率
    else:
      return cfGzip    # 小〜中サイズのテキスト
      
  elif binaryRatio > 0.3:
    # バイナリデータ
    if data.len > 1024 * 1024:  # 1MB以上
      return cfZstd    # 大きなバイナリデータに効果的
    else:
      return cfDeflate # 小さなバイナリデータに効率的
      
  elif entropy < 0.3:
    # 高エントロピーデータ（ランダムに近い）
    if data.len > 1024 * 1024:  # 1MB以上
      return cfZstd    # 辞書ベースで効率的
    else:
      return cfDeflate # オーバーヘッドが少ない
      
  else:
    # 一般的なケース
    if data.len > 10 * 1024 * 1024:  # 10MB以上
      return cfZstd
    elif data.len > 1 * 1024 * 1024:  # 1MB以上
      return cfBrotli
    else:
      return cfGzip

proc getRecommendedCompressionLevel*(data: string, format: CompressionFormat): int =
  ## データ特性に基づいて推奨圧縮レベルを取得
  # データサイズに基づく基本設定
  var baseLevel = case format
    of cfGzip: 6
    of cfDeflate: 5
    of cfBrotli: 4
    of cfZstd: 3
    else: 1
  
  # 1MB以上の大きなデータは低めのレベルを使用（速度優先）
  if data.len > 1024 * 1024:
    baseLevel = max(1, baseLevel - 2)
  
  # 小さなデータは高めのレベルを使用（圧縮率優先）
  elif data.len < 16 * 1024:
    baseLevel = min(9, baseLevel + 1)
  
  # データの複雑さで調整
  let compressionRatio = estimateCompressionRatio(data)
  
  if compressionRatio < 0.2:
    # 圧縮しにくいデータは低レベルに
    baseLevel = max(1, baseLevel - 1)
  elif compressionRatio > 0.7:
    # 圧縮しやすいデータは低レベルでも効果的
    baseLevel = max(1, baseLevel - 1)
  
  # フォーマット別の範囲に調整
  return case format
    of cfGzip, cfDeflate: clamp(baseLevel, 1, 9)
    of cfBrotli: clamp(baseLevel, 0, 11)
    of cfZstd: clamp(baseLevel, 1, 22)
    else: 1

var compressionThreadPool: seq[Thread[void]]
var taskQueue: Channel[CompressionTask]
var resultChannel: Channel[CompressionResult]
var shutdownFlag: Atomic[bool]

proc workerThread() {.thread.} =
  ## 圧縮ワーカースレッド
  while not shutdownFlag.load:
    var task: CompressionTask
    if taskQueue.tryRecv(task):
      let startTime = epochTime()
      var result: CompressionResult
      result.taskId = task.id
      result.originalSize = task.data.len
      
      try:
        # 圧縮または解凍を実行
        var processedData: string
        
        if task.direction == cdCompress:
          case task.format
          of cfGzip:
            import ../gzip/gzip
            processedData = gzip.compress(task.data, newGzipOption(level = GzipCompressionLevel(task.level)))
          of cfBrotli:
            import ../brotli/brotli
            processedData = brotli.compress(task.data, newBrotliOption(quality = task.level.BrotliCompressionLevel))
          of cfZstd:
            import ../zstd/zstd
            processedData = zstd.compress(task.data, newZstdOption(level = task.level.ZstdCompressionLevel))
          of cfDeflate:
            import std/zlib
            processedData = compress(task.data, task.level)
          of cfNone:
            processedData = task.data
        else:
          case task.format
          of cfGzip:
            import ../gzip/gzip
            processedData = gzip.decompress(task.data)
          of cfBrotli:
            import ../brotli/brotli
            processedData = brotli.decompress(task.data)
          of cfZstd:
            import ../zstd/zstd
            processedData = zstd.decompress(task.data)
          of cfDeflate:
            import std/zlib
            processedData = uncompress(task.data)
          of cfNone:
            processedData = task.data
        
        result.data = processedData
        result.resultSize = processedData.len
        result.ratio = if task.direction == cdCompress: processedData.len.float / task.data.len.float else: 0.0
      except Exception as e:
        result.error = e
      
      result.processingTimeMs = (epochTime() - startTime) * 1000
      discard resultChannel.trySend(result)
    
    else:
      # タスクがない場合は短時間スリープ
      sleep(1)

proc initCompressionThreadPool*(threadCount: int = 0) =
  ## 圧縮スレッドプールを初期化
  let threads = if threadCount <= 0: optimalThreadCount() else: threadCount
  
  # 既存のプールをシャットダウン
  if compressionThreadPool.len > 0:
    shutdownCompressionThreadPool()
  
  # チャネルを初期化
  taskQueue.open(maxItems = 1000)
  resultChannel.open(maxItems = 1000)
  
  # シャットダウンフラグをリセット
  shutdownFlag.store(false)
  
  # スレッドを作成
  compressionThreadPool = newSeq[Thread[void]](threads)
  for i in 0 ..< threads:
    createThread(compressionThreadPool[i], workerThread)

proc shutdownCompressionThreadPool*() =
  ## 圧縮スレッドプールをシャットダウン
  if compressionThreadPool.len == 0:
    return
  
  # シャットダウンフラグを設定
  shutdownFlag.store(true)
  
  # すべてのスレッドが終了するのを待機
  for thread in compressionThreadPool:
    joinThread(thread)
  
  # チャネルをクローズ
  taskQueue.close()
  resultChannel.close()
  
  # スレッドプールをクリア
  compressionThreadPool = @[]

proc compressAsync*(data: string, format: CompressionFormat = cfGzip, level: int = -1, priority: int = 0): Future[CompressionResult] {.async.} =
  ## 非同期圧縮を実行
  # スレッドプールが初期化されていない場合は初期化
  if compressionThreadPool.len == 0:
    initCompressionThreadPool()
  
  # 最適な圧縮レベルを使用（指定がない場合）
  let actualLevel = if level < 0: getRecommendedCompressionLevel(data, format) else: level
  
  # タスクを作成
  let task = CompressionTask(
    data: data,
    format: format,
    direction: cdCompress,
    level: actualLevel,
    priority: priority,
    id: getMonoTime().ticks,
    timestamp: getTime()
  )
  
  # タスクをキューに追加
  if not taskQueue.trySend(task):
    raise newException(ResourceExhaustedError, "圧縮タスクキューがいっぱいです")
  
  # 結果を待機
  while true:
    var result: CompressionResult
    if resultChannel.tryRecv(result):
      if result.taskId == task.id:
        return result
    
    await sleepAsync(1)

proc decompressAsync*(data: string, format: CompressionFormat = cfGzip, priority: int = 0): Future[CompressionResult] {.async.} =
  ## 非同期解凍を実行
  # スレッドプールが初期化されていない場合は初期化
  if compressionThreadPool.len == 0:
    initCompressionThreadPool()
  
  # タスクを作成
  let task = CompressionTask(
    data: data,
    format: format,
    direction: cdDecompress,
    level: 0,  # 解凍では使用しない
    priority: priority,
    id: getMonoTime().ticks,
    timestamp: getTime()
  )
  
  # タスクをキューに追加
  if not taskQueue.trySend(task):
    raise newException(ResourceExhaustedError, "解凍タスクキューがいっぱいです")
  
  # 結果を待機
  while true:
    var result: CompressionResult
    if resultChannel.tryRecv(result):
      if result.taskId == task.id:
        return result
    
    await sleepAsync(1)

# SIMD最適化バージョンのCRC32計算（AVX2/SSE4.2使用）
when defined(amd64) or defined(i386):
  proc crc32_sse42(crc: uint32, data: pointer, len: int): uint32 {.importc: "_mm_crc32_u8", header: "immintrin.h".}
  
  proc optimizedCrc32*(crc: uint32, data: openArray[byte]): uint32 =
    ## SSE4.2命令を使用した高速CRC32計算
    if supportsSSE4 and data.len > 0:
      result = crc
      var i = 0
      while i < data.len:
        result = crc32_sse42(result, unsafeAddr data[i], 1)
        inc i
    else:
      # フォールバック実装
      import std/hashes
      result = crc32(crc, cast[ptr uint8](unsafeAddr data[0]), data.len)
else:
  proc optimizedCrc32*(crc: uint32, data: openArray[byte]): uint32 =
    import std/hashes
    result = crc32(crc, cast[ptr uint8](unsafeAddr data[0]), data.len)

# 初期化
proc initOptimization*() =
  ## 最適化ユーティリティを初期化
  if optimalThreadCount() > 0:
    initCompressionThreadPool(optimalThreadCount())

# シャットダウン時のクリーンアップ
proc shutdownOptimization*() =
  ## 最適化ユーティリティのリソースを解放
  shutdownCompressionThreadPool()

# 事前定義された最適化設定
type OptimizationProfile* = enum
  opLatencyOptimized,   ## レイテンシ最適化（最速、低圧縮率）
  opBalanced,           ## バランス型（デフォルト）
  opBandwidthOptimized, ## 帯域幅最適化（低速、高圧縮率）
  opMemoryOptimized,    ## メモリ使用量最適化
  opBatteryOptimized    ## バッテリー使用量最適化

proc setOptimizationProfile*(profile: OptimizationProfile) =
  ## 最適化プロファイルを設定
  case profile
  of opLatencyOptimized:
    prioritizeBandwidth = false
    adaptiveCompression = true
    optimalBufferSize = 32 * 1024  # 小さめのバッファ
    optimalThreadCount = countProcessors() - 1  # 高スレッド数
    
  of opBalanced:
    prioritizeBandwidth = false
    adaptiveCompression = true
    optimalBufferSize = 64 * 1024  # 中程度のバッファ
    optimalThreadCount = max(1, countProcessors() div 2)  # バランスの取れたスレッド数
    
  of opBandwidthOptimized:
    prioritizeBandwidth = true
    adaptiveCompression = true
    optimalBufferSize = 128 * 1024  # 大きめのバッファ
    optimalThreadCount = 2  # 少ないスレッド数で高圧縮率優先
    
  of opMemoryOptimized:
    prioritizeBandwidth = false
    adaptiveCompression = true
    optimalBufferSize = 16 * 1024  # 小さいバッファ
    optimalThreadCount = 1  # 最小スレッド数
    globalCache.maxEntries = 100  # 小さいキャッシュ
    
  of opBatteryOptimized:
    prioritizeBandwidth = true
    adaptiveCompression = true
    optimalBufferSize = 64 * 1024  # 中程度のバッファ
    optimalThreadCount = 1  # 最小スレッド数で電力消費抑制
  
  # スレッドプールを再初期化
  if compressionThreadPool.len > 0:
    shutdownCompressionThreadPool()
    initCompressionThreadPool(optimalThreadCount())

proc getCompressionPoolStatus*(): CompressionPoolStatus =
  ## 圧縮プールの現在の状態を取得
  result.activeThreads = compressionThreadPool.len
  result.queuedTasks = taskQueue.peek()
  # 他の状態情報は実装により異なる
  
# 初期プロファイルとして「バランス型」を設定
setOptimizationProfile(opBalanced) 