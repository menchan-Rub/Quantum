## quantum_net/cache/cache_interface.nim
## 
## HTTP/3キャッシュインターフェース
## 高性能でスケーラブルなキャッシュシステムの基礎を定義

import std/[
  times,
  options,
  tables,
  hashes,
  strutils,
  uri,
  asyncdispatch
]

type
  CacheEntryStatus* = enum
    ## キャッシュエントリのステータス
    cesValid,        ## 有効
    cesStale,        ## 古い (期限切れだが条件付きで使用可能)
    cesExpired,      ## 期限切れ
    cesInvalid,      ## 無効
    cesError         ## エラー

  CachePolicy* = enum
    ## キャッシュポリシー
    cpNoStore,       ## キャッシュしない
    cpNoCache,       ## 毎回再検証が必要
    cpPublic,        ## 共有キャッシュにキャッシュ可能
    cpPrivate,       ## プライベートキャッシュにのみキャッシュ可能
    cpImmutable      ## 不変（将来変更されない）

  CachePriority* = enum
    ## キャッシュの優先度
    cpLowest = 0,    ## 最低優先度
    cpLow = 25,      ## 低優先度
    cpNormal = 50,   ## 通常優先度
    cpHigh = 75,     ## 高優先度
    cpHighest = 100  ## 最高優先度

  CacheEntryType* = enum
    ## キャッシュエントリのタイプ
    cetResource,     ## リソース (HTML, CSS, JS, 画像など)
    cetResponse,     ## HTTPレスポンス
    cetHeader,       ## HTTPヘッダー
    cetPushPromise,  ## HTTPプッシュプロミス
    cetWebTransport  ## WebTransportデータ

  CacheDirective* = object
    ## キャッシュ指示
    name*: string
    value*: string

  CacheValidator* = object
    ## キャッシュ検証情報
    etag*: string                ## Entity Tag
    lastModified*: Option[Time]  ## 最終更新時間

  CacheEntry* = ref object of RootObj
    ## キャッシュエントリ基底クラス
    url*: string                 ## URL
    entryType*: CacheEntryType   ## エントリタイプ
    created*: Time               ## 作成時間
    lastAccessed*: Time          ## 最終アクセス時間
    expiresAt*: Time             ## 有効期限
    size*: int                   ## サイズ (バイト)
    accessCount*: int            ## アクセス回数
    policy*: CachePolicy         ## キャッシュポリシー
    priority*: CachePriority     ## 優先度
    validator*: CacheValidator   ## 検証情報
    isCompressed*: bool          ## 圧縮されているか
    variantId*: string           ## バリアントID (コンテンツネゴシエーション用)
    directives*: seq[CacheDirective] ## キャッシュ指示

  ResourceCacheEntry* = ref object of CacheEntry
    ## リソースキャッシュエントリ
    data*: seq[byte]             ## リソースデータ
    contentType*: string         ## コンテンツタイプ
    contentEncoding*: string     ## コンテンツエンコーディング

  ResponseCacheEntry* = ref object of CacheEntry
    ## HTTPレスポンスキャッシュエントリ
    statusCode*: int             ## ステータスコード
    headers*: seq[tuple[name: string, value: string]] ## レスポンスヘッダー
    body*: seq[byte]             ## レスポンスボディ

  HeaderCacheEntry* = ref object of CacheEntry
    ## HTTPヘッダーキャッシュエントリ
    headers*: seq[tuple[name: string, value: string]] ## HTTPヘッダー

  PushPromiseCacheEntry* = ref object of CacheEntry
    ## HTTPプッシュプロミスキャッシュエントリ
    headers*: seq[tuple[name: string, value: string]] ## プロミスヘッダー
    referrerUrl*: string         ## 参照元URL

  WebTransportCacheEntry* = ref object of CacheEntry
    ## WebTransportキャッシュエントリ
    sessionId*: string           ## セッションID
    data*: seq[byte]             ## セッションデータ

  CacheStorageType* = enum
    ## キャッシュストレージタイプ
    cstMemory,                   ## メモリキャッシュ
    cstDisk,                     ## ディスクキャッシュ
    cstHybrid                    ## ハイブリッドキャッシュ

  CacheEvictionPolicy* = enum
    ## キャッシュ削除ポリシー
    cepLRU,                      ## Least Recently Used (最近最も使われていないものを削除)
    cepLFU,                      ## Least Frequently Used (最も使用頻度が低いものを削除)
    cepFIFO,                     ## First In First Out (最初に入ったものを最初に削除)
    cepWeight                    ## 重み付け (サイズ、優先度、有効期限などの複合要素)

  CacheStats* = object
    ## キャッシュ統計情報
    hits*: int                   ## ヒット数
    misses*: int                 ## ミス数
    entries*: int                ## エントリ数
    size*: int                   ## 使用サイズ (バイト)
    maxSize*: int                ## 最大サイズ (バイト)
    insertions*: int             ## 挿入数
    evictions*: int              ## 削除数
    invalidations*: int          ## 無効化数
    hitRatio*: float             ## ヒット率

  CacheOptions* = object
    ## キャッシュオプション
    maxSize*: int                ## 最大サイズ (バイト)
    maxEntries*: int             ## 最大エントリ数
    defaultTtl*: int             ## デフォルトのTTL (秒)
    storageType*: CacheStorageType ## ストレージタイプ
    evictionPolicy*: CacheEvictionPolicy ## 削除ポリシー
    compressionEnabled*: bool    ## 圧縮が有効か
    persistenceEnabled*: bool    ## 永続化が有効か
    persistencePath*: string     ## 永続化パス

  CacheInterface* = ref object of RootObj
    ## キャッシュインターフェース
    options*: CacheOptions       ## キャッシュオプション
    stats*: CacheStats           ## 統計情報

# キャッシュインターフェースのメソッド（抽象メソッド）

method get*(cache: CacheInterface, url: string): Future[Option[CacheEntry]] {.base, async.} =
  ## URL指定でキャッシュエントリを取得
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method put*(cache: CacheInterface, entry: CacheEntry): Future[bool] {.base, async.} =
  ## キャッシュエントリを保存
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method delete*(cache: CacheInterface, url: string): Future[bool] {.base, async.} =
  ## URL指定でキャッシュエントリを削除
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method clear*(cache: CacheInterface): Future[void] {.base, async.} =
  ## キャッシュをクリア
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method size*(cache: CacheInterface): Future[int] {.base, async.} =
  ## キャッシュサイズを取得
  raise newException(NotImplementedError, "Method not implemented")

method contains*(cache: CacheInterface, url: string): Future[bool] {.base, async.} =
  ## URLがキャッシュに存在するかチェック
  raise newException(NotImplementedError, "Method not implemented")

method getStats*(cache: CacheInterface): Future[CacheStats] {.base, async.} =
  ## キャッシュ統計情報を取得
  raise newException(NotImplementedError, "Method not implemented")

method cleanup*(cache: CacheInterface): Future[void] {.base, async.} =
  ## 期限切れエントリのクリーンアップ
  raise newException(NotImplementedError, "Method not implemented")

# 具体的なキャッシュ実装クラス

type
  MemoryCacheInterface* = ref object of CacheInterface
    ## メモリベースのキャッシュ実装
    entries*: Table[string, CacheEntry]
    accessTimes*: Table[string, Time]
    currentSize*: int

  DiskCacheInterface* = ref object of CacheInterface
    ## ディスクベースのキャッシュ実装
    cacheDir*: string
    indexFile*: string
    entries*: Table[string, CacheEntry]

  HybridCacheInterface* = ref object of CacheInterface
    ## ハイブリッド（メモリ+ディスク）キャッシュ実装
    memoryCache*: MemoryCacheInterface
    diskCache*: DiskCacheInterface
    memoryThreshold*: int

# MemoryCacheInterface の実装

proc newMemoryCacheInterface*(options: CacheOptions): MemoryCacheInterface =
  ## メモリキャッシュインターフェースを作成
  result = MemoryCacheInterface(
    options: options,
    stats: CacheStats(),
    entries: initTable[string, CacheEntry](),
    accessTimes: initTable[string, Time](),
    currentSize: 0
  )

method get*(cache: MemoryCacheInterface, url: string): Future[Option[CacheEntry]] {.async.} =
  ## メモリキャッシュからエントリを取得
  cache.stats.requests += 1
  
  if url in cache.entries:
    let entry = cache.entries[url]
    
    # 有効期限チェック
    if isEntryValid(entry):
      cache.stats.hits += 1
      cache.accessTimes[url] = getTime()
      return some(entry)
    else:
      # 期限切れエントリを削除
      cache.entries.del(url)
      cache.accessTimes.del(url)
      cache.currentSize -= entry.size
  
  cache.stats.misses += 1
  return none(CacheEntry)

method put*(cache: MemoryCacheInterface, entry: CacheEntry): Future[bool] {.async.} =
  ## メモリキャッシュにエントリを保存
  try:
    # サイズ制限チェック
    if cache.currentSize + entry.size > cache.options.maxSize:
      await evictEntries(cache, entry.size)
    
    # エントリ数制限チェック
    if cache.entries.len >= cache.options.maxEntries:
      await evictOldestEntry(cache)
    
    # エントリを保存
    cache.entries[entry.url] = entry
    cache.accessTimes[entry.url] = getTime()
    cache.currentSize += entry.size
    cache.stats.stores += 1
    
    return true
  except:
    cache.stats.errors += 1
    return false

method delete*(cache: MemoryCacheInterface, url: string): Future[bool] {.async.} =
  ## メモリキャッシュからエントリを削除
  if url in cache.entries:
    let entry = cache.entries[url]
    cache.entries.del(url)
    cache.accessTimes.del(url)
    cache.currentSize -= entry.size
    cache.stats.deletions += 1
    return true
  return false

method clear*(cache: MemoryCacheInterface): Future[void] {.async.} =
  ## メモリキャッシュをクリア
  cache.entries.clear()
  cache.accessTimes.clear()
  cache.currentSize = 0
  cache.stats = CacheStats()

method size*(cache: MemoryCacheInterface): Future[int] {.async.} =
  ## メモリキャッシュのサイズを取得
  return cache.entries.len

method contains*(cache: MemoryCacheInterface, url: string): Future[bool] {.async.} =
  ## URLがメモリキャッシュに存在するかチェック
  return url in cache.entries and isEntryValid(cache.entries[url])

method getStats*(cache: MemoryCacheInterface): Future[CacheStats] {.async.} =
  ## メモリキャッシュの統計情報を取得
  cache.stats.currentSize = cache.currentSize
  cache.stats.entryCount = cache.entries.len
  return cache.stats

method cleanup*(cache: MemoryCacheInterface): Future[void] {.async.} =
  ## 期限切れエントリのクリーンアップ
  var expiredUrls: seq[string] = @[]
  
  for url, entry in cache.entries:
    if not isEntryValid(entry):
      expiredUrls.add(url)
  
  for url in expiredUrls:
    discard await cache.delete(url)

# DiskCacheInterface の実装

proc newDiskCacheInterface*(options: CacheOptions): DiskCacheInterface =
  ## ディスクキャッシュインターフェースを作成
  result = DiskCacheInterface(
    options: options,
    stats: CacheStats(),
    cacheDir: options.persistencePath,
    indexFile: options.persistencePath / "index.json",
    entries: initTable[string, CacheEntry]()
  )
  
  # キャッシュディレクトリを作成
  createDir(result.cacheDir)
  
  # インデックスファイルを読み込み
  asyncCheck result.loadIndex()

method get*(cache: DiskCacheInterface, url: string): Future[Option[CacheEntry]] {.async.} =
  ## ディスクキャッシュからエントリを取得
  cache.stats.requests += 1
  
  if url in cache.entries:
    let entry = cache.entries[url]
    
    # 有効期限チェック
    if isEntryValid(entry):
      # ディスクからデータを読み込み
      let filePath = cache.cacheDir / entry.hash
      if fileExists(filePath):
        let data = readFile(filePath)
        var fullEntry = entry
        fullEntry.data = data.toBytes()
        
        cache.stats.hits += 1
        return some(fullEntry)
    else:
      # 期限切れエントリを削除
      discard await cache.delete(url)
  
  cache.stats.misses += 1
  return none(CacheEntry)

method put*(cache: DiskCacheInterface, entry: CacheEntry): Future[bool] {.async.} =
  ## ディスクキャッシュにエントリを保存
  try:
    # ファイルパスを生成
    let filePath = cache.cacheDir / entry.hash
    
    # データをディスクに保存
    writeFile(filePath, entry.data.toString())
    
    # インデックスに追加
    var indexEntry = entry
    indexEntry.data = @[]  # インデックスにはデータを保存しない
    cache.entries[entry.url] = indexEntry
    
    # インデックスファイルを更新
    await cache.saveIndex()
    
    cache.stats.stores += 1
    return true
  except:
    cache.stats.errors += 1
    return false

method delete*(cache: DiskCacheInterface, url: string): Future[bool] {.async.} =
  ## ディスクキャッシュからエントリを削除
  if url in cache.entries:
    let entry = cache.entries[url]
    let filePath = cache.cacheDir / entry.hash
    
    # ファイルを削除
    if fileExists(filePath):
      removeFile(filePath)
    
    # インデックスから削除
    cache.entries.del(url)
    await cache.saveIndex()
    
    cache.stats.deletions += 1
    return true
  return false

method clear*(cache: DiskCacheInterface): Future[void] {.async.} =
  ## ディスクキャッシュをクリア
  # すべてのキャッシュファイルを削除
  for url, entry in cache.entries:
    let filePath = cache.cacheDir / entry.hash
    if fileExists(filePath):
      removeFile(filePath)
  
  # インデックスをクリア
  cache.entries.clear()
  await cache.saveIndex()
  cache.stats = CacheStats()

method size*(cache: DiskCacheInterface): Future[int] {.async.} =
  ## ディスクキャッシュのサイズを取得
  return cache.entries.len

method contains*(cache: DiskCacheInterface, url: string): Future[bool] {.async.} =
  ## URLがディスクキャッシュに存在するかチェック
  return url in cache.entries and isEntryValid(cache.entries[url])

method getStats*(cache: DiskCacheInterface): Future[CacheStats] {.async.} =
  ## ディスクキャッシュの統計情報を取得
  cache.stats.entryCount = cache.entries.len
  return cache.stats

method cleanup*(cache: DiskCacheInterface): Future[void] {.async.} =
  ## 期限切れエントリのクリーンアップ
  var expiredUrls: seq[string] = @[]
  
  for url, entry in cache.entries:
    if not isEntryValid(entry):
      expiredUrls.add(url)
  
  for url in expiredUrls:
    discard await cache.delete(url)

# HybridCacheInterface の実装

proc newHybridCacheInterface*(options: CacheOptions): HybridCacheInterface =
  ## ハイブリッドキャッシュインターフェースを作成
  var memoryOptions = options
  memoryOptions.maxSize = options.maxSize div 4  # メモリは全体の1/4
  
  var diskOptions = options
  diskOptions.maxSize = options.maxSize  # ディスクは全体サイズ
  
  result = HybridCacheInterface(
    options: options,
    stats: CacheStats(),
    memoryCache: newMemoryCacheInterface(memoryOptions),
    diskCache: newDiskCacheInterface(diskOptions),
    memoryThreshold: 1024 * 1024  # 1MB以下はメモリに保存
  )

method get*(cache: HybridCacheInterface, url: string): Future[Option[CacheEntry]] {.async.} =
  ## ハイブリッドキャッシュからエントリを取得
  cache.stats.requests += 1
  
  # まずメモリキャッシュを確認
  let memoryResult = await cache.memoryCache.get(url)
  if memoryResult.isSome:
    cache.stats.hits += 1
    return memoryResult
  
  # 次にディスクキャッシュを確認
  let diskResult = await cache.diskCache.get(url)
  if diskResult.isSome:
    let entry = diskResult.get()
    
    # 小さなエントリはメモリにプロモート
    if entry.size <= cache.memoryThreshold:
      discard await cache.memoryCache.put(entry)
    
    cache.stats.hits += 1
    return diskResult
  
  cache.stats.misses += 1
  return none(CacheEntry)

method put*(cache: HybridCacheInterface, entry: CacheEntry): Future[bool] {.async.} =
  ## ハイブリッドキャッシュにエントリを保存
  if entry.size <= cache.memoryThreshold:
    # 小さなエントリはメモリに保存
    let result = await cache.memoryCache.put(entry)
    if result:
      cache.stats.stores += 1
    else:
      cache.stats.errors += 1
    return result
  else:
    # 大きなエントリはディスクに保存
    let result = await cache.diskCache.put(entry)
    if result:
      cache.stats.stores += 1
    else:
      cache.stats.errors += 1
    return result

method delete*(cache: HybridCacheInterface, url: string): Future[bool] {.async.} =
  ## ハイブリッドキャッシュからエントリを削除
  let memoryResult = await cache.memoryCache.delete(url)
  let diskResult = await cache.diskCache.delete(url)
  
  if memoryResult or diskResult:
    cache.stats.deletions += 1
    return true
  return false

method clear*(cache: HybridCacheInterface): Future[void] {.async.} =
  ## ハイブリッドキャッシュをクリア
  await cache.memoryCache.clear()
  await cache.diskCache.clear()
  cache.stats = CacheStats()

method size*(cache: HybridCacheInterface): Future[int] {.async.} =
  ## ハイブリッドキャッシュのサイズを取得
  let memorySize = await cache.memoryCache.size()
  let diskSize = await cache.diskCache.size()
  return memorySize + diskSize

method contains*(cache: HybridCacheInterface, url: string): Future[bool] {.async.} =
  ## URLがハイブリッドキャッシュに存在するかチェック
  let memoryContains = await cache.memoryCache.contains(url)
  if memoryContains:
    return true
  return await cache.diskCache.contains(url)

method getStats*(cache: HybridCacheInterface): Future[CacheStats] {.async.} =
  ## ハイブリッドキャッシュの統計情報を取得
  let memoryStats = await cache.memoryCache.getStats()
  let diskStats = await cache.diskCache.getStats()
  
  cache.stats.hits = memoryStats.hits + diskStats.hits
  cache.stats.misses = memoryStats.misses + diskStats.misses
  cache.stats.stores = memoryStats.stores + diskStats.stores
  cache.stats.deletions = memoryStats.deletions + diskStats.deletions
  cache.stats.errors = memoryStats.errors + diskStats.errors
  cache.stats.entryCount = memoryStats.entryCount + diskStats.entryCount
  cache.stats.currentSize = memoryStats.currentSize + diskStats.currentSize
  
  return cache.stats

method cleanup*(cache: HybridCacheInterface): Future[void] {.async.} =
  ## 期限切れエントリのクリーンアップ
  await cache.memoryCache.cleanup()
  await cache.diskCache.cleanup()

# ヘルパー関数

proc evictEntries(cache: MemoryCacheInterface, requiredSize: int): Future[void] {.async.} =
  ## LRU方式でエントリを削除
  var sortedEntries: seq[tuple[url: string, time: Time]] = @[]
  
  for url, time in cache.accessTimes:
    sortedEntries.add((url, time))
  
  sortedEntries.sort(proc(a, b: tuple[url: string, time: Time]): int =
    cmp(a.time, b.time)
  )
  
  var freedSize = 0
  for entry in sortedEntries:
    if freedSize >= requiredSize:
      break
    
    let cacheEntry = cache.entries[entry.url]
    freedSize += cacheEntry.size
    discard await cache.delete(entry.url)

proc evictOldestEntry(cache: MemoryCacheInterface): Future[void] {.async.} =
  ## 最も古いエントリを削除
  var oldestUrl = ""
  var oldestTime = getTime()
  
  for url, time in cache.accessTimes:
    if time < oldestTime:
      oldestTime = time
      oldestUrl = url
  
  if oldestUrl != "":
    discard await cache.delete(oldestUrl)

proc loadIndex(cache: DiskCacheInterface): Future[void] {.async.} =
  ## インデックスファイルを読み込み
  if fileExists(cache.indexFile):
    try:
      let content = readFile(cache.indexFile)
      let jsonNode = parseJson(content)
      
      for url, entryNode in jsonNode:
        let entry = CacheEntry(
          url: url,
          hash: entryNode["hash"].getStr(),
          headers: initTable[string, string](),
          data: @[],
          size: entryNode["size"].getInt(),
          createdAt: fromUnix(entryNode["createdAt"].getInt()),
          expiresAt: fromUnix(entryNode["expiresAt"].getInt()),
          lastModified: if entryNode.hasKey("lastModified"): some(fromUnix(entryNode["lastModified"].getInt())) else: none(Time),
          etag: if entryNode.hasKey("etag"): some(entryNode["etag"].getStr()) else: none(string)
        )
        
        # ヘッダーを復元
        if entryNode.hasKey("headers"):
          for key, value in entryNode["headers"]:
            entry.headers[key] = value.getStr()
        
        cache.entries[url] = entry
    except:
      # インデックスファイルが破損している場合は無視
      discard

proc saveIndex(cache: DiskCacheInterface): Future[void] {.async.} =
  ## インデックスファイルを保存
  var jsonNode = newJObject()
  
  for url, entry in cache.entries:
    var entryNode = newJObject()
    entryNode["hash"] = newJString(entry.hash)
    entryNode["size"] = newJInt(entry.size)
    entryNode["createdAt"] = newJInt(entry.createdAt.toUnix())
    entryNode["expiresAt"] = newJInt(entry.expiresAt.toUnix())
    
    if entry.lastModified.isSome:
      entryNode["lastModified"] = newJInt(entry.lastModified.get().toUnix())
    
    if entry.etag.isSome:
      entryNode["etag"] = newJString(entry.etag.get())
    
    # ヘッダーを保存
    var headersNode = newJObject()
    for key, value in entry.headers:
      headersNode[key] = newJString(value)
    entryNode["headers"] = headersNode
    
    jsonNode[url] = entryNode
  
  writeFile(cache.indexFile, $jsonNode)

# エクスポート
export CacheInterface, MemoryCacheInterface, DiskCacheInterface, HybridCacheInterface
export newMemoryCacheInterface, newDiskCacheInterface, newHybridCacheInterface 