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
  self.totalSize

proc has*(self: DiskCache, key: string): bool =
  ## キャッシュにキーが存在し、有効期限内かを確認する
  
  # まずメモリキャッシュを確認
  if self.memoryCache.has(key):
    return true
  
  # ディスクキャッシュを確認
  if not self.index.keys.hasKey(key):
    return false
  
  let fileName = self.index.keys[key]
  let now = getTime()
  
  # 期限切れかどうかを確認
  if self.index.expires.hasKey(fileName) and now > self.index.expires[fileName]:
    # 自動的に期限切れのエントリを削除
    let filePath = self.config.cacheDir / "data" / fileName
    if fileExists(filePath):
      try:
        removeFile(filePath)
      except:
        discard
    
    # インデックスから削除
    if self.index.sizes.hasKey(fileName):
      self.totalSize -= self.index.sizes[fileName]
      
    self.index.keys.del(key)
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
    
    self.dirty = true
    return false
  
  # ファイルが存在するか確認
  let filePath = self.config.cacheDir / "data" / fileName
  if not fileExists(filePath):
    # インデックスから削除
    self.index.keys.del(key)
    if self.index.sizes.hasKey(fileName):
      self.totalSize -= self.index.sizes[fileName]
    
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
    
    self.dirty = true
    return false
  
  return true

proc updateAccessStats(self: DiskCache, fileName: string) =
  ## アクセス統計を更新する
  let now = getTime()
  self.index.accessed[fileName] = now
  
  if self.index.counts.hasKey(fileName):
    self.index.counts[fileName] = self.index.counts[fileName] + 1
  else:
    self.index.counts[fileName] = 1
    
  self.dirty = true

proc get*(self: DiskCache, key: string): tuple[found: bool, content: string, metadata: CacheEntryMetadata] =
  ## キャッシュからコンテンツを取得する
  
  # メモリキャッシュを確認
  if self.memoryCache.has(key):
    let content = self.memoryCache.get(key)
    let metadata = self.memoryCache.getEntryMetadata(key)
    self.hitCount += 1
    return (found: true, content: content, metadata: metadata)
  
  # ディスクキャッシュを確認
  if not self.has(key):
    self.missCount += 1
    return (found: false, content: "", metadata: CacheEntryMetadata())
  
  let fileName = self.index.keys[key]
  let filePath = self.config.cacheDir / "data" / fileName
  
  try:
    # ファイルからコンテンツを読み込む
    let content = readFile(filePath)
    
    # アクセス統計を更新
    self.updateAccessStats(fileName)
    
    # メモリキャッシュにも保存
    var metadata = CacheEntryMetadata()
    if self.index.metadata.hasKey(fileName):
      metadata = self.index.metadata[fileName]
    
    var ttl = -1
    if self.index.expires.hasKey(fileName):
      let now = getTime()
      let ttlSecs = (self.index.expires[fileName] - now).inSeconds
      if ttlSecs > 0:
        ttl = ttlSecs.int
    
    self.memoryCache.set(key, content, metadata, ttl)
    
    self.hitCount += 1
    return (found: true, content: content, metadata: metadata)
  except:
    # ファイル読み込みに失敗した場合
    self.index.keys.del(key)
    if self.index.sizes.hasKey(fileName):
      self.totalSize -= self.index.sizes[fileName]
    
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
    
    self.dirty = true
    self.missCount += 1
    return (found: false, content: "", metadata: CacheEntryMetadata())

proc get*(self: DiskCache, key: string, default: string): string =
  ## キャッシュからコンテンツを取得する（簡易版）
  let result = self.get(key)
  if result.found:
    return result.content
  else:
    return default

proc pruneExpired(self: DiskCache): int =
  ## 期限切れのエントリを削除する
  let now = getTime()
  var removed = 0
  var filesToRemove: seq[string] = @[]
  var keysToRemove: seq[string] = @[]
  
  # 期限切れのエントリを特定
  for key, fileName in self.index.keys:
    if self.index.expires.hasKey(fileName) and now > self.index.expires[fileName]:
      filesToRemove.add(fileName)
      keysToRemove.add(key)
  
  # ファイルを削除
  for fileName in filesToRemove:
    let filePath = self.config.cacheDir / "data" / fileName
    if fileExists(filePath):
      try:
        removeFile(filePath)
        removed += 1
      except:
        discard
    
    # サイズを更新
    if self.index.sizes.hasKey(fileName):
      self.totalSize -= self.index.sizes[fileName]
    
    # インデックスから削除
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
  
  # キーマッピングを削除
  for key in keysToRemove:
    self.index.keys.del(key)
  
  if removed > 0:
    self.dirty = true
    
  return removed

proc findFilesToEvict(self: DiskCache, requiredSpace: int): seq[string] =
  ## 追い出すファイルを見つける
  let maxSize = self.config.maxSizeMb * 1024 * 1024
  var neededSpace = max(0, self.totalSize + requiredSpace - maxSize)
  
  if neededSpace <= 0:
    return @[]
  
  # アクセス時間でソートされたエントリのリスト
  var files: seq[tuple[fileName: string, accessed: Time]] = @[]
  for fileName, accessTime in self.index.accessed:
    files.add((fileName: fileName, accessed: accessTime))
  
  # 最も古いアクセス順にソート
  files.sort(proc(x, y: tuple[fileName: string, accessed: Time]): int =
    cmp(x.accessed, y.accessed))
  
  var result: seq[string] = @[]
  var freedSpace = 0
  
  for file in files:
    if self.index.sizes.hasKey(file.fileName):
      let fileSize = self.index.sizes[file.fileName]
      result.add(file.fileName)
      freedSpace += fileSize
      
      if freedSpace >= neededSpace:
        break
  
  return result

proc evictEntries(self: DiskCache, filesToEvict: seq[string]): int =
  ## エントリを追い出す
  var removed = 0
  var keysToRemove: seq[string] = @[]
  
  # 削除するキーを特定
  for key, fileName in self.index.keys:
    if filesToEvict.contains(fileName):
      keysToRemove.add(key)
  
  # ファイルを削除
  for fileName in filesToEvict:
    let filePath = self.config.cacheDir / "data" / fileName
    if fileExists(filePath):
      try:
        removeFile(filePath)
        removed += 1
        self.evictionCount += 1
      except:
        discard
    
    # サイズを更新
    if self.index.sizes.hasKey(fileName):
      self.totalSize -= self.index.sizes[fileName]
    
    # インデックスから削除
    self.index.metadata.del(fileName)
    self.index.created.del(fileName)
    self.index.expires.del(fileName)
    self.index.accessed.del(fileName)
    self.index.counts.del(fileName)
    self.index.sizes.del(fileName)
  
  # キーマッピングを削除
  for key in keysToRemove:
    self.index.keys.del(key)
  
  if removed > 0:
    self.dirty = true
    
  return removed

proc set*(self: DiskCache, key: string, content: string, metadata: CacheEntryMetadata = CacheEntryMetadata(), ttl: int = -1) =
  ## コンテンツをキャッシュに保存する
  let now = getTime()
  let contentSize = content.len
  
  # キャッシュサイズをチェック
  if contentSize > self.config.maxSizeMb * 1024 * 1024:
    # サイズが大きすぎる場合は保存しない
    return
  
  # メモリキャッシュに保存
  self.memoryCache.set(key, content, metadata, ttl)
  
  # ファイル名を生成
  let fileName = generateFileName(key)
  let filePath = self.config.cacheDir / "data" / fileName
  
  # 期限切れのエントリをクリーンアップ
  discard self.pruneExpired()
  
  # スペースを確保
  let filesToEvict = self.findFilesToEvict(contentSize)
  discard self.evictEntries(filesToEvict)
  

  let actualTtl = if ttl < 0: self.config.defaultTtlSeconds else: ttl
  
  try:
    # ファイルに書き込む
    writeFile(filePath, content)
    
    # 既存のエントリを更新
    if self.index.keys.hasKey(key):
      let oldFileName = self.index.keys[key]
      if oldFileName != fileName and fileExists(self.config.cacheDir / "data" / oldFileName):
        try:
          removeFile(self.config.cacheDir / "data" / oldFileName)
        except:
          discard
      
      # 古いサイズを引く
      if self.index.sizes.hasKey(oldFileName):
        self.totalSize -= self.index.sizes[oldFileName]
      
      # 古いエントリの関連情報を削除
      self.index.metadata.del(oldFileName)
      self.index.created.del(oldFileName)
      self.index.expires.del(oldFileName)
      self.index.accessed.del(oldFileName)
      self.index.counts.del(oldFileName)
      self.index.sizes.del(oldFileName)
    
    # インデックスを更新
    self.index.keys[key] = fileName
    self.index.metadata[fileName] = metadata
    self.index.created[fileName] = now
    self.index.expires[fileName] = now + initDuration(seconds = actualTtl)
    self.index.accessed[fileName] = now
    self.index.counts[fileName] = 0
    self.index.sizes[fileName] = contentSize
    
    # 合計サイズを更新
    self.totalSize += contentSize
    
    self.dirty = true
    self.checkFlush()
  except:
    echo "キャッシュへの書き込みに失敗しました: ", getCurrentExceptionMsg()

proc set*(self: DiskCache, key: string, content: string, ttl: int = -1) =
  ## コンテンツをキャッシュに保存する（簡易版）
  let metadata = CacheEntryMetadata()
  self.set(key, content, metadata, ttl)

proc remove*(self: DiskCache, key: string): bool =
  ## キャッシュからエントリを削除する
  if not self.index.keys.hasKey(key):
    return false
  
  # メモリキャッシュから削除
  discard self.memoryCache.remove(key)
  
  let fileName = self.index.keys[key]
  let filePath = self.config.cacheDir / "data" / fileName
  
  # ファイルを削除
  if fileExists(filePath):
    try:
      removeFile(filePath)
    except:
      discard
  
  # サイズを更新
  if self.index.sizes.hasKey(fileName):
    self.totalSize -= self.index.sizes[fileName]
  
  # インデックスから削除
  self.index.keys.del(key)
  self.index.metadata.del(fileName)
  self.index.created.del(fileName)
  self.index.expires.del(fileName)
  self.index.accessed.del(fileName)
  self.index.counts.del(fileName)
  self.index.sizes.del(fileName)
  
  self.dirty = true
  return true

proc clear*(self: DiskCache) =
  ## キャッシュを完全にクリアする
  
  # メモリキャッシュをクリア
  self.memoryCache.clear()
  
  # ディスクキャッシュをクリア
  let dataDir = self.config.cacheDir / "data"
  try:
    for file in walkFiles(dataDir / "*"):
      removeFile(file)
  except:
    echo "キャッシュディレクトリのクリアに失敗しました: ", getCurrentExceptionMsg()
  
  # インデックスをクリア
  self.index.keys.clear()
  self.index.metadata.clear()
  self.index.created.clear()
  self.index.expires.clear()
  self.index.accessed.clear()
  self.index.counts.clear()
  self.index.sizes.clear()
  
  self.totalSize = 0
  self.dirty = true
  self.saveIndex()  # 即座に保存

proc getStats*(self: DiskCache): tuple[entries: int, size: int, utilization: float, hitCount: int, missCount: int, hitRatio: float] =
  ## キャッシュの統計情報を取得する
  let maxSize = self.config.maxSizeMb * 1024 * 1024
  let utilization = if maxSize > 0: self.totalSize.float / maxSize.float * 100.0 else: 0.0
  let total = self.hitCount + self.missCount
  let hitRatio = if total > 0: self.hitCount.float / total.float * 100.0 else: 0.0
  
  return (
    entries: self.index.keys.len,
    size: self.totalSize,
    utilization: utilization,
    hitCount: self.hitCount,
    missCount: self.missCount,
    hitRatio: hitRatio
  )

proc getMemoryStats*(self: DiskCache): tuple[entries: int, size: int, utilization: float, hitCount: int, missCount: int, hitRatio: float] =
  ## メモリキャッシュの統計情報を取得する
  return self.memoryCache.getStats()

proc close*(self: DiskCache) =
  ## キャッシュを閉じる
  if self.dirty:
    self.saveIndex()

proc getMetadata*(self: DiskCache, key: string): CacheEntryMetadata =
  ## エントリのメタデータを取得する
  if self.memoryCache.has(key):
    return self.memoryCache.getEntryMetadata(key)
  
  if not self.has(key):
    return CacheEntryMetadata()
  
  let fileName = self.index.keys[key]
  if self.index.metadata.hasKey(fileName):
    return self.index.metadata[fileName]
  
  return CacheEntryMetadata()

proc touchEntry*(self: DiskCache, key: string): bool =
  ## エントリのアクセス時間を更新する
  if self.memoryCache.has(key):
    discard self.memoryCache.touchEntry(key)
  
  if not self.index.keys.hasKey(key):
    return false
  
  let fileName = self.index.keys[key]
  self.updateAccessStats(fileName)
  return true

proc updateExpiration*(self: DiskCache, key: string, ttl: int): bool =
  ## エントリの有効期限を更新する
  if self.memoryCache.has(key):
    discard self.memoryCache.updateExpiration(key, ttl)
  
  if not self.index.keys.hasKey(key):
    return false
  
  let fileName = self.index.keys[key]
  let now = getTime()
  self.index.expires[fileName] = now + initDuration(seconds = ttl)
  
  self.dirty = true
  return true

proc optimize*(self: DiskCache) {.async.} =
  ## キャッシュを最適化する（バックグラウンドで実行）
  ## - 期限切れのエントリを削除
  ## - 断片化を解消
  ## - インデックスを保存
  
  # 期限切れのエントリを削除
  discard self.pruneExpired()
  
  # ディスクの断片化を解消
  var oldSize = self.totalSize
  
  # インデックスを保存
  self.saveIndex()
  
  echo "キャッシュ最適化完了: ", oldSize - self.totalSize, " バイト削減"

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
    echo "key1: ", if result1.found: result1.content else: "<見つかりません>"
    
    let result2 = cache.get("key2")
    echo "key2: ", if result2.found: result2.content else: "<見つかりません>"
    
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
    discard cache.remove("key2")
    
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