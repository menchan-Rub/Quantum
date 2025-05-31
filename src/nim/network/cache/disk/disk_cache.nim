import std/[os, tables, times, json, streams, hashes, strutils, options, algorithm, sequtils, asyncdispatch]
import ../memory
import ../policy/cache_policy

type
  DiskCacheConfig* = object
    cacheDir*: string             # キャッシュディレクトリのパス
    maxSizeMb*: int               # キャッシュの最大サイズ（MB）
    defaultTtlSeconds*: int       # デフォルトのTTL（秒）
    flushInterval*: int           # インデックスの保存間隔（秒）
    compressionEnabled*: bool     # 圧縮を有効にするかどうか

  CacheIndex = object
    keys: Table[string, string]   # キー -> ファイル名のマッピング
    metadata: Table[string, CacheEntryMetadata]  # ファイル名 -> メタデータのマッピング
    created: Table[string, Time]  # ファイル名 -> 作成時間のマッピング
    expires: Table[string, Time]  # ファイル名 -> 有効期限のマッピング
    accessed: Table[string, Time] # ファイル名 -> 最終アクセス時間のマッピング
    counts: Table[string, int]    # ファイル名 -> アクセス回数のマッピング
    sizes: Table[string, int]     # ファイル名 -> サイズのマッピング

  DiskCache* = object
    config: DiskCacheConfig       # キャッシュの設定
    index: CacheIndex             # キャッシュインデックス
    memoryCache: MemoryCache      # メモリキャッシュ（頻繁にアクセスされるエントリ用）
    lastFlush: Time               # 最後にインデックスを保存した時間
    totalSize: int                # 現在のディスクキャッシュサイズ（バイト）
    hitCount: int                 # ヒット数
    missCount: int                # ミス数
    evictionCount: int            # 追い出し数
    creationTime: Time            # キャッシュの作成日時
    dirty: bool                   # インデックスが変更されたかどうか
    indexFile: string            # インデックスファイルのパス
    currentSizeBytes: int         # 現在のサイズ（バイト）

proc newDiskCacheConfig*(cacheDir: string = getTempDir() / "browser_cache",
                         maxSizeMb: int = 1000,
                         defaultTtlSeconds: int = 86400,
                         flushInterval: int = 60,
                         compressionEnabled: bool = true): DiskCacheConfig =
  ## 新しいディスクキャッシュの設定を作成する
  result = DiskCacheConfig(
    cacheDir: cacheDir,
    maxSizeMb: maxSizeMb,
    defaultTtlSeconds: defaultTtlSeconds,
    flushInterval: flushInterval,
    compressionEnabled: compressionEnabled
  )

proc generateFileName(key: string): string =
  ## キーからファイル名を生成する
  result = $hash(key)

proc loadIndex(indexPath: string): CacheIndex =
  ## インデックスファイルから読み込む
  result = CacheIndex(
    keys: initTable[string, string](),
    metadata: initTable[string, CacheEntryMetadata](),
    created: initTable[string, Time](),
    expires: initTable[string, Time](),
    accessed: initTable[string, Time](),
    counts: initTable[string, int](),
    sizes: initTable[string, int]()
  )
  
  if not fileExists(indexPath):
    return result
    
  try:
    let jsonStr = readFile(indexPath)
    let jsonNode = parseJson(jsonStr)
    
    # キーマッピングの読み込み
    if jsonNode.hasKey("keys"):
      for k, v in jsonNode["keys"].fields:
        result.keys[k] = v.getStr()
    
    # メタデータの読み込み
    if jsonNode.hasKey("metadata"):
      for k, v in jsonNode["metadata"].fields:
        var meta = CacheEntryMetadata()
        if v.hasKey("contentType"): meta.contentType = v["contentType"].getStr()
        if v.hasKey("etag"): meta.etag = v["etag"].getStr()
        if v.hasKey("lastModified"): meta.lastModified = v["lastModified"].getStr()
        if v.hasKey("expires"): meta.expires = fromUnix(v["expires"].getInt())
        if v.hasKey("maxAge"): meta.maxAge = v["maxAge"].getInt()
        
        if v.hasKey("headers") and v["headers"].kind == JObject:
          meta.headers = initTable[string, string]()
          for hk, hv in v["headers"].fields:
            meta.headers[hk] = hv.getStr()
            
        result.metadata[k] = meta
    
    # タイムスタンプの読み込み
    if jsonNode.hasKey("created"):
      for k, v in jsonNode["created"].fields:
        result.created[k] = fromUnix(v.getInt())
    
    if jsonNode.hasKey("expires"):
      for k, v in jsonNode["expires"].fields:
        result.expires[k] = fromUnix(v.getInt())
    
    if jsonNode.hasKey("accessed"):
      for k, v in jsonNode["accessed"].fields:
        result.accessed[k] = fromUnix(v.getInt())
    
    # アクセス回数の読み込み
    if jsonNode.hasKey("counts"):
      for k, v in jsonNode["counts"].fields:
        result.counts[k] = v.getInt()
    
    # サイズの読み込み
    if jsonNode.hasKey("sizes"):
      for k, v in jsonNode["sizes"].fields:
        result.sizes[k] = v.getInt()
  except:
    # エラー時は空のインデックスを返す
    echo "キャッシュインデックスの読み込みに失敗しました: ", getCurrentExceptionMsg()
    result = CacheIndex(
      keys: initTable[string, string](),
      metadata: initTable[string, CacheEntryMetadata](),
      created: initTable[string, Time](),
      expires: initTable[string, Time](),
      accessed: initTable[string, Time](),
      counts: initTable[string, int](),
      sizes: initTable[string, int]()
    )

proc saveIndex(self: DiskCache) =
  ## インデックスをファイルに保存する
  let indexPath = self.config.cacheDir / "index.json"
  
  try:
    var jsonNode = newJObject()
    
    # キーマッピングの保存
    var keysNode = newJObject()
    for k, v in self.index.keys:
      keysNode[k] = newJString(v)
    jsonNode["keys"] = keysNode
    
    # メタデータの保存
    var metadataNode = newJObject()
    for k, v in self.index.metadata:
      var metaNode = newJObject()
      metaNode["contentType"] = newJString(v.contentType)
      metaNode["etag"] = newJString(v.etag)
      metaNode["lastModified"] = newJString(v.lastModified)
      metaNode["expires"] = newJInt(v.expires.toUnix())
      metaNode["maxAge"] = newJInt(v.maxAge)
      
      var headersNode = newJObject()
      for hk, hv in v.headers:
        headersNode[hk] = newJString(hv)
      metaNode["headers"] = headersNode
      
      metadataNode[k] = metaNode
    jsonNode["metadata"] = metadataNode
    
    # タイムスタンプの保存
    var createdNode = newJObject()
    for k, v in self.index.created:
      createdNode[k] = newJInt(v.toUnix())
    jsonNode["created"] = createdNode
    
    var expiresNode = newJObject()
    for k, v in self.index.expires:
      expiresNode[k] = newJInt(v.toUnix())
    jsonNode["expires"] = expiresNode
    
    var accessedNode = newJObject()
    for k, v in self.index.accessed:
      accessedNode[k] = newJInt(v.toUnix())
    jsonNode["accessed"] = accessedNode
    
    # アクセス回数の保存
    var countsNode = newJObject()
    for k, v in self.index.counts:
      countsNode[k] = newJInt(v)
    jsonNode["counts"] = countsNode
    
    # サイズの保存
    var sizesNode = newJObject()
    for k, v in self.index.sizes:
      sizesNode[k] = newJInt(v)
    jsonNode["sizes"] = sizesNode
    
    # JSONの書き込み
    writeFile(indexPath, $jsonNode)
    self.dirty = false
    self.lastFlush = getTime()
  except:
    echo "キャッシュインデックスの保存に失敗しました: ", getCurrentExceptionMsg()

proc newDiskCache*(config: DiskCacheConfig): DiskCache =
  ## 新しいディスクキャッシュを作成する
  
  # キャッシュディレクトリの作成
  createDir(config.cacheDir)
  createDir(config.cacheDir / "data")
  
  let indexPath = config.cacheDir / "index.json"
  let index = loadIndex(indexPath)
  
  # メモリキャッシュの作成（頻繁にアクセスされるエントリ用）
  let memCacheSize = min(100, config.maxSizeMb div 10)  # 全体の10%をメモリキャッシュに割り当て
  let memoryCache = newMemoryCache(memCacheSize, config.defaultTtlSeconds)
  
  # 現在のキャッシュサイズを計算
  var totalSize = 0
  for _, size in index.sizes:
    totalSize += size
  
  result = DiskCache(
    config: config,
    index: index,
    memoryCache: memoryCache,
    lastFlush: getTime(),
    totalSize: totalSize,
    hitCount: 0,
    missCount: 0,
    evictionCount: 0,
    creationTime: getTime(),
    dirty: false,
    indexFile: indexPath,
    currentSizeBytes: totalSize
  )

proc checkFlush(self: DiskCache) =
  ## 必要に応じてインデックスを保存する
  if self.dirty and (getTime() - self.lastFlush).inSeconds >= self.config.flushInterval:
    self.saveIndex()

proc calculateDiskUsage(self: DiskCache): int =
  ## ディスクキャッシュの現在の使用量を計算する
  result = 0
  
  let dataDir = self.config.cacheDir / "data"
  if not dirExists(dataDir):
    return 0
  
  # ディレクトリ内のすべてのファイルサイズを合計
  for kind, path in walkDir(dataDir):
    if kind == pcFile:
      try:
        result += getFileSize(path)
      except:
        discard  # ファイルにアクセスできなかった場合は無視

proc cleanupOldEntries(self: var DiskCache, bytesToFree: int = 0) {.async.} =
  ## 古いエントリをクリーンアップする
  ## bytesToFreeが指定された場合、少なくともその容量を解放しようとする
  
  # 1. 有効期限切れのエントリーを削除
  var expiredFiles: seq[string] = @[]
  let now = getTime()
  
  for fileName, expireTime in self.index.expires:
    if expireTime <= now:
      expiredFiles.add(fileName)
  
  var freedBytes = 0
  for fileName in expiredFiles:
    let filePath = self.config.cacheDir / "data" / fileName
    if fileExists(filePath):
      try:
        let fileSize = getFileSize(filePath)
        removeFile(filePath)
        freedBytes += fileSize
        
        # インデックスから削除
        for key, fn in self.index.keys:
          if fn == fileName:
            self.index.keys.del(key)
            break
        
        self.index.metadata.del(fileName)
        self.index.created.del(fileName)
        self.index.expires.del(fileName)
        self.index.accessed.del(fileName)
        self.index.counts.del(fileName)
        self.index.sizes.del(fileName)
        
        self.dirty = true
        self.totalSize -= fileSize
      except:
        echo "キャッシュファイルの削除に失敗しました: ", filePath
  
  # 有効期限切れの削除だけで十分な空き容量が確保できた場合は終了
  if freedBytes >= bytesToFree:
    self.checkFlush()
    return
  
  # 2. 十分な容量が確保できなかった場合、アクセス頻度・時間に基づいて追加で削除
  let stillNeeded = bytesToFree - freedBytes
  if stillNeeded <= 0:
    return
  
  # ファイル名、アクセス回数、最終アクセス時間、サイズのタプルのリストを作成
  var fileScores: seq[tuple[fileName: string, score: float, size: int]] = @[]
  
  for fileName, accessCount in self.index.counts:
    if not self.index.accessed.hasKey(fileName) or not self.index.sizes.hasKey(fileName):
      continue
    
    let lastAccess = self.index.accessed[fileName]
    let size = self.index.sizes[fileName]
    
    # スコア計算: アクセス数が少なく、最終アクセスが古いほど高スコア（削除優先度が高い）
    let ageScore = (now - lastAccess).inSeconds.float / 86400.0  # 日数
    let countScore = 1.0 / max(1, accessCount).float
    let score = (ageScore * 0.7) + (countScore * 0.3)  # 日数70%、アクセス回数30%で重み付け
    
    fileScores.add((fileName, score, size))
  
  # スコアの高い順（削除優先度の高い順）にソート
  fileScores.sort(proc(a, b: tuple[fileName: string, score: float, size: int]): int =
    result = cmp(b.score, a.score)  # 降順
  )
  
  # 必要な容量を確保するまで削除
  var additionalFreed = 0
  for entry in fileScores:
    if additionalFreed >= stillNeeded:
      break
    
    let filePath = self.config.cacheDir / "data" / entry.fileName
    if fileExists(filePath):
      try:
        removeFile(filePath)
        additionalFreed += entry.size
        
        # インデックスから削除
        for key, fn in self.index.keys:
          if fn == entry.fileName:
            self.index.keys.del(key)
            break
        
        self.index.metadata.del(entry.fileName)
        self.index.created.del(entry.fileName)
        self.index.expires.del(entry.fileName)
        self.index.accessed.del(entry.fileName)
        self.index.counts.del(entry.fileName)
        self.index.sizes.del(entry.fileName)
        
        self.dirty = true
        self.totalSize -= entry.size
        self.evictionCount += 1
      except:
        echo "キャッシュファイルの削除に失敗しました: ", filePath
  
  self.checkFlush()

proc ensureSpace(self: var DiskCache, requiredBytes: int): Future[bool] {.async.} =
  ## キャッシュに指定されたバイト数の空き容量を確保する
  
  # 現在の使用量を再計算
  self.totalSize = self.calculateDiskUsage()
  
  # 最大キャッシュサイズ（バイト）
  let maxBytes = self.config.maxSizeMb * 1024 * 1024
  
  # 現在の使用量 + 必要なバイト数が最大サイズ以下なら追加の操作は不要
  if self.totalSize + requiredBytes <= maxBytes:
    return true
  
  # 確保する必要のある容量
  let bytesToFree = (self.totalSize + requiredBytes) - maxBytes
  if bytesToFree <= 0:
    return true
  
  # 古いエントリーをクリーンアップ
  await self.cleanupOldEntries(bytesToFree)
  
  # 再度容量を確認
  return (self.totalSize + requiredBytes) <= maxBytes

proc put*(self: var DiskCache, key: string, data: string, metadata: CacheEntryMetadata): Future[bool] {.async.} =
  ## キャッシュにデータを保存する
  
  let fileName = generateFileName(key)
  let filePath = self.config.cacheDir / "data" / fileName
  let dataSize = data.len
  
  # 古いエントリが存在する場合は削除
  if self.index.keys.hasKey(key):
    let oldFileName = self.index.keys[key]
    let oldFilePath = self.config.cacheDir / "data" / oldFileName
    
    try:
      if fileExists(oldFilePath):
        let oldSize = getFileSize(oldFilePath)
        removeFile(oldFilePath)
        self.totalSize -= oldSize
    except:
      echo "古いキャッシュファイルの削除に失敗しました: ", oldFilePath
  
  # 十分な空き容量を確保
  if not await self.ensureSpace(dataSize):
    return false
  
  # メモリキャッシュにも保存
  self.memoryCache.put(key, data, metadata)
  
  # ディスクに保存
  try:
    writeFile(filePath, data)
    
    # インデックスを更新
    self.index.keys[key] = fileName
    self.index.metadata[fileName] = metadata
    self.index.created[fileName] = getTime()
    self.index.expires[fileName] = metadata.expires
    self.index.accessed[fileName] = getTime()
    self.index.counts[fileName] = 1
    self.index.sizes[fileName] = dataSize
    
    self.totalSize += dataSize
    self.dirty = true
    self.checkFlush()
    
    return true
  except:
    echo "キャッシュファイルの書き込みに失敗しました: ", filePath
    return false

proc get*(self: var DiskCache, key: string): Future[Option[tuple[data: string, metadata: CacheEntryMetadata]]] {.async.} =
  ## キャッシュからデータを取得する
  
  # まずメモリキャッシュを確認
  let memResult = self.memoryCache.get(key)
  if memResult.isSome:
    self.hitCount += 1
    return memResult
  
  # ディスクキャッシュを確認
  if not self.index.keys.hasKey(key):
    self.missCount += 1
    return none(tuple[data: string, metadata: CacheEntryMetadata])
  
  let fileName = self.index.keys[key]
  let filePath = self.config.cacheDir / "data" / fileName
  
  try:
    if not fileExists(filePath):
      # ファイルが存在しない場合はインデックスから削除
      self.index.keys.del(key)
      self.index.metadata.del(fileName)
      self.index.created.del(fileName)
      self.index.expires.del(fileName)
      self.index.accessed.del(fileName)
      self.index.counts.del(fileName)
      self.index.sizes.del(fileName)
      
      self.dirty = true
      self.missCount += 1
      return none(tuple[data: string, metadata: CacheEntryMetadata])
    
    # メタデータが存在しない場合
    if not self.index.metadata.hasKey(fileName):
      self.missCount += 1
      return none(tuple[data: string, metadata: CacheEntryMetadata])
    
    # 有効期限をチェック
    if self.index.expires.hasKey(fileName) and getTime() > self.index.expires[fileName]:
      # 有効期限切れの場合はクリーンアップ対象としてマーク
      asyncCheck self.cleanupOldEntries()
      self.missCount += 1
      return none(tuple[data: string, metadata: CacheEntryMetadata])
    
    # ファイルからデータを読み込む
    let data = readFile(filePath)
    let metadata = self.index.metadata[fileName]
    
    # アクセス統計を更新
    self.index.accessed[fileName] = getTime()
    if self.index.counts.hasKey(fileName):
      self.index.counts[fileName] += 1
    else:
      self.index.counts[fileName] = 1
    
    self.dirty = true
    self.hitCount += 1
    
    # メモリキャッシュに追加（次回のアクセスを高速化）
    self.memoryCache.put(key, data, metadata)
    
    return some((data, metadata))
  except:
    echo "キャッシュファイルの読み込みに失敗しました: ", filePath
    self.missCount += 1
    return none(tuple[data: string, metadata: CacheEntryMetadata])

proc delete*(self: var DiskCache, key: string): Future[bool] {.async.} =
  ## キャッシュからエントリを削除する
  
  # メモリキャッシュから削除
  discard self.memoryCache.delete(key)
  
  # ディスクキャッシュから削除
  if not self.index.keys.hasKey(key):
    return false
  
  let fileName = self.index.keys[key]
  let filePath = self.config.cacheDir / "data" / fileName
  
  try:
    if fileExists(filePath):
      let fileSize = getFileSize(filePath)
      removeFile(filePath)
      self.totalSize -= fileSize
    
    # インデックスから削除
    self.index.keys.del(key)
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
    
    self.dirty = true
    self.checkFlush()
    
    return true
  except:
    echo "キャッシュファイルの削除に失敗しました: ", filePath
    return false

proc clear*(self: var DiskCache): Future[void] {.async.} =
  ## キャッシュを完全にクリアする
  
  # メモリキャッシュをクリア
  self.memoryCache.clear()
  
  # ディスクキャッシュをクリア
  let dataDir = self.config.cacheDir / "data"
  if dirExists(dataDir):
    try:
      # すべてのファイルを削除
      for kind, path in walkDir(dataDir):
        if kind == pcFile:
          removeFile(path)
      
      # ディレクトリを再作成（空の状態に）
      removeDir(dataDir)
      createDir(dataDir)
    except:
      echo "キャッシュディレクトリのクリアに失敗しました: ", dataDir
  
  # インデックスをリセット
  self.index = CacheIndex(
    keys: initTable[string, string](),
    metadata: initTable[string, CacheEntryMetadata](),
    created: initTable[string, Time](),
    expires: initTable[string, Time](),
    accessed: initTable[string, Time](),
    counts: initTable[string, int](),
    sizes: initTable[string, int]()
  )
  
  self.totalSize = 0
  self.dirty = true
  self.saveIndex()

proc vacuum*(self: var DiskCache): Future[int] {.async.} =
  ## 未使用のファイルを削除し、キャッシュをコンパクトにする
  ## 解放されたバイト数を返す
  
  var freedBytes = 0
  
  # 1. 有効なファイル名のセットを作成
  var validFiles = initHashSet[string]()
  for _, fileName in self.index.keys:
    validFiles.incl(fileName)
  
  # 2. ディスク上の実際のファイルをスキャン
  let dataDir = self.config.cacheDir / "data"
  if dirExists(dataDir):
    for kind, path in walkDir(dataDir):
      if kind == pcFile:
        let fileName = extractFilename(path)
        
        # インデックスに存在しないファイルを削除
        if not validFiles.contains(fileName):
          try:
            let fileSize = getFileSize(path)
            removeFile(path)
            freedBytes += fileSize
          except:
            echo "不要なキャッシュファイルの削除に失敗しました: ", path
  
  # 3. インデックスのインテグリティチェック
  var orphanedEntries: seq[string] = @[]
  
  for key, fileName in self.index.keys:
    let filePath = self.config.cacheDir / "data" / fileName
    if not fileExists(filePath):
      orphanedEntries.add(key)
  
  # 存在しないファイルの参照をインデックスから削除
  for key in orphanedEntries:
    let fileName = self.index.keys[key]
    self.index.keys.del(key)
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
    
    self.dirty = true
  
  # 4. ファイルサイズの再計算
  self.totalSize = self.calculateDiskUsage()
  
  # 5. インデックスの保存
  self.saveIndex()
  
  return freedBytes

proc optimize*(self: var DiskCache): Future[void] {.async.} =
  ## キャッシュを最適化する
  ## - 未使用ファイルの削除
  ## - 有効期限切れエントリの削除
  ## - インデックスの整合性確保
  ## - ディスク使用量の最適化
  
  # 1. 未使用のファイルを削除
  discard await self.vacuum()
  
  # 2. 有効期限切れのエントリを削除
  await self.cleanupOldEntries()
  
  # 3. メモリキャッシュの最適化
  self.memoryCache.optimize()
  
  # 4. ディスク容量が上限に近い場合、追加の削除を実行
  let maxBytes = self.config.maxSizeMb * 1024 * 1024
  let usageRatio = self.totalSize.float / maxBytes.float
  
  if usageRatio > 0.9:  # 90%以上使用している場合
    # 20%の容量を確保するように削除
    let bytesToFree = (self.totalSize - (maxBytes * 0.8).int)
    if bytesToFree > 0:
      await self.cleanupOldEntries(bytesToFree)
  
  # 5. インデックスの最終保存
  self.saveIndex()

when isMainModule:
  # テスト用のメイン関数
  proc testDiskCache() {.async.} =
    echo "ディスクキャッシュのテスト"
    
    # テスト用の設定
    let config = newDiskCacheConfig(
      cacheDir = getTempDir() / "disk_cache_test",
      maxSizeMb = 10,
      defaultTtlSeconds = 30,
      flushInterval = 5
    )
    
    # 既存のキャッシュディレクトリを削除
    if dirExists(config.cacheDir):
      try:
        removeDir(config.cacheDir)
      except:
        discard
    
    # ディスクキャッシュの作成
    let cache = newDiskCache(config)
    
    # キャッシュにデータを設定
    echo "キャッシュにデータを設定中..."
    cache.set("key1", "バリュー1")
    cache.set("key2", "バリュー2")
    cache.set("key3", "バリュー3")
    
    # カスタムメタデータでエントリを設定
    var meta = CacheEntryMetadata(
      contentType: "text/plain",
      etag: "abc123",
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT"
    )
    cache.set("key4", "バリュー4", meta, 60)
    
    # キャッシュからデータを取得
    echo "キャッシュからデータを取得中..."
    
    let result1 = cache.get("key1")
    echo "key1: ", if result1.isSome: result1.get().data else: "<見つかりません>"
    
    let result2 = cache.get("key2")
    echo "key2: ", if result2.isSome: result2.get().data else: "<見つかりません>"
    
    # 簡易版のget
    echo "key3: ", cache.get("key3", "<見つかりません>")
    echo "key5: ", cache.get("key5", "<見つかりません>")  # 存在しないキー
    
    # メタデータの取得
    let meta4 = cache.getMetadata("key4")
    echo "key4 メタデータ:"
    echo " - Content-Type: ", meta4.contentType
    echo " - ETag: ", meta4.etag
    echo " - Last-Modified: ", meta4.lastModified
    
    # 統計の表示
    let stats = cache.getStats()
    echo "キャッシュ統計:"
    echo " - エントリ数: ", stats.entries
    echo " - サイズ: ", stats.size, " バイト"
    echo " - 使用率: ", stats.utilization, "%"
    echo " - ヒット数: ", stats.hitCount
    echo " - ミス数: ", stats.missCount
    echo " - ヒット率: ", stats.hitRatio, "%"
    
    # エントリの削除
    echo "キャッシュからkey2を削除中..."
    discard cache.delete("key2")
    
    # キャッシュの内容を確認
    echo "key1存在: ", cache.has("key1")
    echo "key2存在: ", cache.has("key2")
    echo "key3存在: ", cache.has("key3")
    
    # 有効期限の更新
    echo "key3の有効期限を更新中..."
    discard cache.updateExpiration("key3", 120)
    
    # インデックスを強制的に保存
    cache.saveIndex()
    
    # 少し待ってキャッシュの最適化
    echo "キャッシュを最適化中..."
    await cache.optimize()
    
    # キャッシュをクリア
    echo "キャッシュをクリア中..."
    cache.clear()
    
    # クリア後の確認
    echo "クリア後、key1存在: ", cache.has("key1")
    
    # キャッシュを閉じる
    cache.close()
  
  # テスト実行
  waitFor testDiskCache() 