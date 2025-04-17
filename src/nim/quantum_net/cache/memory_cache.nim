## quantum_net/cache/memory_cache.nim
## 
## HTTP/3メモリキャッシュ実装
## 高速なメモリベースのキャッシュシステム

import std/[
  times,
  options,
  tables,
  hashes,
  strutils,
  uri,
  asyncdispatch,
  algorithm,
  heapqueue,
  json,
  locks,
  atomics
]

import cache_interface

type
  CacheMetadata = object
    ## キャッシュエントリのメタデータ
    key: string                 ## キャッシュキー（通常はURL）
    size: int                   ## エントリのサイズ
    accessTime: Time            ## 最終アクセス時間
    createTime: Time            ## 作成時間
    expireTime: Time            ## 有効期限
    accessCount: int            ## アクセス回数
    priority: CachePriority     ## 優先度
    entryType: CacheEntryType   ## エントリタイプ

  LRUEntry = object
    ## LRUキャッシュエントリ
    key: string
    accessTime: Time

  MemoryCache* = ref object of CacheInterface
    ## メモリキャッシュ実装
    cache: Table[string, CacheEntry]  ## キャッシュデータ
    metadata: Table[string, CacheMetadata] ## メタデータ
    currentSize: int               ## 現在のキャッシュサイズ
    lruQueue: HeapQueue[LRUEntry]  ## LRUキュー
    lock: Lock                     ## スレッドセーフのためのロック
    isInitialized: Atomic[bool]    ## 初期化済みフラグ

# LRUキューの比較演算子
proc `<`(a, b: LRUEntry): bool =
  return a.accessTime < b.accessTime

# メモリキャッシュ実装

proc newMemoryCache*(options: CacheOptions = defaultCacheOptions()): MemoryCache =
  ## 新しいメモリキャッシュを作成
  result = MemoryCache(
    options: options,
    stats: CacheStats(
      hits: 0,
      misses: 0,
      entries: 0,
      size: 0,
      maxSize: options.maxSize,
      insertions: 0,
      evictions: 0,
      invalidations: 0,
      hitRatio: 0.0
    ),
    cache: initTable[string, CacheEntry](),
    metadata: initTable[string, CacheMetadata](),
    currentSize: 0,
    lruQueue: initHeapQueue[LRUEntry]()
  )
  
  # ロックの初期化
  initLock(result.lock)
  result.isInitialized.store(true)

proc `=destroy`(cache: var MemoryCache) =
  ## メモリキャッシュのデストラクタ
  if cache.isInitialized.load():
    deinitLock(cache.lock)

proc evictEntries(cache: MemoryCache, sizeNeeded: int): int =
  ## 必要なサイズを確保するためにエントリを削除
  ## 戻り値: 削除されたエントリの数
  
  if cache.currentSize + sizeNeeded <= cache.options.maxSize:
    return 0  # 削除不要
  
  var sizeToFree = sizeNeeded - (cache.options.maxSize - cache.currentSize)
  if sizeToFree <= 0:
    return 0
  
  var freedSize = 0
  var evictedCount = 0
  
  # ポリシーに基づいて削除
  case cache.options.evictionPolicy
  of cepLRU:
    # LRUポリシー: 最も古いアクセス時間のエントリから削除
    var entriesToRemove: seq[string] = @[]
    while freedSize < sizeToFree and cache.lruQueue.len > 0:
      let oldest = cache.lruQueue.pop()
      if cache.cache.hasKey(oldest.key) and cache.metadata.hasKey(oldest.key):
        entriesToRemove.add(oldest.key)
        freedSize += cache.metadata[oldest.key].size
        evictedCount.inc
    
    # 削除実行
    for key in entriesToRemove:
      discard cache.cache.hasKeyOrPut(key, nil)
      discard cache.metadata.hasKeyOrPut(key, CacheMetadata())
      cache.currentSize -= cache.metadata[key].size
      cache.cache.del(key)
      cache.metadata.del(key)
  
  of cepLFU:
    # LFUポリシー: 最も使用頻度の低いエントリから削除
    var entries: seq[tuple[key: string, count: int]] = @[]
    for key, meta in cache.metadata:
      entries.add((key: key, count: meta.accessCount))
    
    # アクセス回数でソート
    entries.sort(proc(x, y: tuple[key: string, count: int]): int =
      result = cmp(x.count, y.count)
      if result == 0:
        # 同じアクセス回数ならアクセス時間でソート
        result = cmp(cache.metadata[x.key].accessTime, 
                     cache.metadata[y.key].accessTime)
    )
    
    # 削除実行
    for entry in entries:
      if freedSize >= sizeToFree:
        break
      if cache.cache.hasKey(entry.key) and cache.metadata.hasKey(entry.key):
        freedSize += cache.metadata[entry.key].size
        cache.currentSize -= cache.metadata[entry.key].size
        cache.cache.del(entry.key)
        cache.metadata.del(entry.key)
        evictedCount.inc
  
  of cepFIFO:
    # FIFOポリシー: 最も古い作成時間のエントリから削除
    var entries: seq[tuple[key: string, time: Time]] = @[]
    for key, meta in cache.metadata:
      entries.add((key: key, time: meta.createTime))
    
    # 作成時間でソート
    entries.sort(proc(x, y: tuple[key: string, time: Time]): int =
      result = cmp(x.time, y.time)
    )
    
    # 削除実行
    for entry in entries:
      if freedSize >= sizeToFree:
        break
      if cache.cache.hasKey(entry.key) and cache.metadata.hasKey(entry.key):
        freedSize += cache.metadata[entry.key].size
        cache.currentSize -= cache.metadata[entry.key].size
        cache.cache.del(entry.key)
        cache.metadata.del(entry.key)
        evictedCount.inc
  
  of cepWeight:
    # 重み付けポリシー: サイズ、優先度、有効期限を考慮
    var entries: seq[tuple[key: string, weight: float]] = @[]
    let now = getTime()
    
    for key, meta in cache.metadata:
      # 重みの計算
      let timeWeight = 1.0 - min(1.0, (now - meta.accessTime).inSeconds.float / 86400.0)
      let sizeWeight = meta.size.float / max(1.0, cache.currentSize.float)
      let priorityWeight = case meta.priority
        of cpLowest: 0.2
        of cpLow: 0.4
        of cpNormal: 0.6
        of cpHigh: 0.8
        of cpHighest: 1.0
      
      let remainingTtl = max(0.0, (meta.expireTime - now).inSeconds.float)
      let ttlWeight = min(1.0, remainingTtl / 3600.0)  # 1時間を基準
      
      # 総合重み（低いほど削除候補）
      let weight = (timeWeight * 0.4) + (priorityWeight * 0.3) + 
                   (ttlWeight * 0.2) - (sizeWeight * 0.1)
      
      entries.add((key: key, weight: weight))
    
    # 重みでソート（低い順）
    entries.sort(proc(x, y: tuple[key: string, weight: float]): int =
      result = cmp(x.weight, y.weight)
    )
    
    # 削除実行
    for entry in entries:
      if freedSize >= sizeToFree:
        break
      if cache.cache.hasKey(entry.key) and cache.metadata.hasKey(entry.key):
        freedSize += cache.metadata[entry.key].size
        cache.currentSize -= cache.metadata[entry.key].size
        cache.cache.del(entry.key)
        cache.metadata.del(entry.key)
        evictedCount.inc
  
  cache.stats.evictions += evictedCount
  return evictedCount

proc updateLRU(cache: MemoryCache, key: string) =
  ## LRUキューを更新
  let now = getTime()
  
  # 新しいエントリをキューに追加
  cache.lruQueue.push(LRUEntry(key: key, accessTime: now))
  
  # キューが大きくなりすぎないようにたまに整理
  if cache.lruQueue.len > cache.cache.len * 2:
    # 現在のキャッシュに存在するキーのみを保持
    var newQueue = initHeapQueue[LRUEntry]()
    var seen = initTable[string, bool]()
    
    while cache.lruQueue.len > 0:
      let entry = cache.lruQueue.pop()
      if cache.cache.hasKey(entry.key) and not seen.hasKey(entry.key):
        newQueue.push(entry)
        seen[entry.key] = true
    
    cache.lruQueue = newQueue

method get*(cache: MemoryCache, url: string): Future[Option[CacheEntry]] {.async.} =
  ## URL指定でキャッシュエントリを取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if cache.cache.hasKey(url):
    let entry = cache.cache[url]
    let status = getEntryStatus(entry)
    
    # 統計情報の更新
    cache.stats.hits.inc
    let totalRequests = cache.stats.hits + cache.stats.misses
    cache.stats.hitRatio = cache.stats.hits.float / max(1, totalRequests).float
    
    # 有効なエントリのみを返す
    if status == cesValid:
      # メタデータの更新
      if cache.metadata.hasKey(url):
        var meta = cache.metadata[url]
        meta.accessTime = getTime()
        meta.accessCount.inc
        cache.metadata[url] = meta
      
      # エントリの更新
      updateLastAccessed(entry)
      
      # LRUキューの更新
      updateLRU(cache, url)
      
      return some(entry)
    elif status == cesStale:
      # 古いエントリは条件付きで返す
      updateLastAccessed(entry)
      updateLRU(cache, url)
      return some(entry)
  
  # キャッシュミス
  cache.stats.misses.inc
  let totalRequests = cache.stats.hits + cache.stats.misses
  cache.stats.hitRatio = cache.stats.hits.float / max(1, totalRequests).float
  
  return none(CacheEntry)

method put*(cache: MemoryCache, entry: CacheEntry): Future[bool] {.async.} =
  ## キャッシュエントリを保存
  if entry.isNil or entry.url.len == 0:
    return false
  
  if entry.policy == cpNoStore:
    return false  # No-Store指示があるものはキャッシュしない
  
  acquire(cache.lock)
  defer: release(cache.lock)
  
  # エントリのサイズを計算
  var entrySize = entry.size
  if entrySize == 0:
    # サイズが設定されていない場合は推定
    case entry.entryType
    of cetResource:
      let resourceEntry = ResourceCacheEntry(entry)
      entrySize = resourceEntry.data.len
    of cetResponse:
      let responseEntry = ResponseCacheEntry(entry)
      entrySize = responseEntry.body.len + 
                 responseEntry.headers.len * 64  # ヘッダーの概算
    of cetHeader:
      let headerEntry = HeaderCacheEntry(entry)
      entrySize = headerEntry.headers.len * 64   # ヘッダーの概算
    of cetPushPromise:
      let pushEntry = PushPromiseCacheEntry(entry)
      entrySize = pushEntry.headers.len * 64     # ヘッダーの概算
    of cetWebTransport:
      let wtEntry = WebTransportCacheEntry(entry)
      entrySize = wtEntry.data.len
  
  # 古いエントリを削除（存在する場合）
  if cache.cache.hasKey(entry.url):
    let oldSize = if cache.metadata.hasKey(entry.url): cache.metadata[entry.url].size else: 0
    cache.currentSize -= oldSize
    cache.cache.del(entry.url)
    cache.metadata.del(entry.url)
    cache.stats.entries.dec
  
  # 空き容量が不足している場合、古いエントリを削除
  let _ = evictEntries(cache, entrySize)
  
  # それでも容量が足りない場合は失敗
  if entrySize > cache.options.maxSize:
    return false  # エントリが大きすぎる
  
  # 最大エントリ数をチェック
  if cache.cache.len >= cache.options.maxEntries and not cache.cache.hasKey(entry.url):
    let _ = evictEntries(cache, entrySize)
    
    if cache.cache.len >= cache.options.maxEntries:
      return false  # 最大エントリ数に達している
  
  # メタデータ作成
  let metadata = CacheMetadata(
    key: entry.url,
    size: entrySize,
    accessTime: getTime(),
    createTime: entry.created,
    expireTime: entry.expiresAt,
    accessCount: 0,
    priority: entry.priority,
    entryType: entry.entryType
  )
  
  # キャッシュに追加
  cache.cache[entry.url] = entry
  cache.metadata[entry.url] = metadata
  cache.currentSize += entrySize
  
  # 統計情報の更新
  cache.stats.insertions.inc
  cache.stats.entries.inc
  cache.stats.size = cache.currentSize
  
  # LRUキューの更新
  updateLRU(cache, entry.url)
  
  return true

method delete*(cache: MemoryCache, url: string): Future[bool] {.async.} =
  ## URL指定でキャッシュエントリを削除
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if not cache.cache.hasKey(url):
    return false
  
  # サイズを調整
  if cache.metadata.hasKey(url):
    cache.currentSize -= cache.metadata[url].size
    cache.metadata.del(url)
  
  # エントリを削除
  cache.cache.del(url)
  
  # 統計情報の更新
  cache.stats.entries.dec
  cache.stats.invalidations.inc
  cache.stats.size = cache.currentSize
  
  return true

method clear*(cache: MemoryCache): Future[void] {.async.} =
  ## キャッシュをクリア
  acquire(cache.lock)
  defer: release(cache.lock)
  
  cache.cache.clear()
  cache.metadata.clear()
  cache.lruQueue = initHeapQueue[LRUEntry]()
  cache.currentSize = 0
  
  # 統計情報のリセット
  cache.stats.entries = 0
  cache.stats.size = 0
  cache.stats.evictions = 0
  cache.stats.invalidations = 0
  cache.stats.insertions = 0
  # ヒット/ミス統計はリセットしない

method contains*(cache: MemoryCache, url: string): Future[bool] {.async.} =
  ## URL指定でキャッシュエントリが存在するか確認
  acquire(cache.lock)
  defer: release(cache.lock)
  
  return cache.cache.hasKey(url)

method refresh*(cache: MemoryCache, url: string, newData: CacheEntry): Future[bool] {.async.} =
  ## キャッシュエントリを更新
  return await cache.put(newData)

method getStatus*(cache: MemoryCache, url: string): Future[CacheEntryStatus] {.async.} =
  ## URL指定でキャッシュエントリのステータスを取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if not cache.cache.hasKey(url):
    return cesInvalid
  
  let entry = cache.cache[url]
  return getEntryStatus(entry)

method purgeExpired*(cache: MemoryCache): Future[int] {.async.} =
  ## 期限切れのキャッシュエントリを削除
  ## 戻り値: 削除されたエントリの数
  acquire(cache.lock)
  defer: release(cache.lock)
  
  let now = getTime()
  var purgedCount = 0
  var keysToDelete: seq[string] = @[]
  
  # 期限切れのエントリを見つける
  for url, meta in cache.metadata:
    if meta.expireTime <= now:
      keysToDelete.add(url)
  
  # 削除を実行
  for url in keysToDelete:
    if cache.cache.hasKey(url):
      let entrySize = cache.metadata[url].size
      cache.currentSize -= entrySize
      cache.cache.del(url)
      cache.metadata.del(url)
      purgedCount.inc
  
  # 統計情報の更新
  cache.stats.entries -= purgedCount
  cache.stats.invalidations += purgedCount
  cache.stats.size = cache.currentSize
  
  return purgedCount

method persist*(cache: MemoryCache): Future[bool] {.async.} =
  ## キャッシュを永続化
  if not cache.options.persistenceEnabled or cache.options.persistencePath.len == 0:
    return false
  
  acquire(cache.lock)
  defer: release(cache.lock)
  
  try:
    # メタデータのみを永続化
    var metadataJson = newJObject()
    for key, meta in cache.metadata:
      var entryJson = newJObject()
      entryJson["size"] = newJInt(meta.size)
      entryJson["accessTime"] = newJInt(meta.accessTime.toUnix())
      entryJson["createTime"] = newJInt(meta.createTime.toUnix())
      entryJson["expireTime"] = newJInt(meta.expireTime.toUnix())
      entryJson["accessCount"] = newJInt(meta.accessCount)
      entryJson["priority"] = newJInt(ord(meta.priority))
      entryJson["entryType"] = newJInt(ord(meta.entryType))
      
      metadataJson[key] = entryJson
    
    # 統計情報
    var statsJson = newJObject()
    statsJson["hits"] = newJInt(cache.stats.hits)
    statsJson["misses"] = newJInt(cache.stats.misses)
    statsJson["entries"] = newJInt(cache.stats.entries)
    statsJson["size"] = newJInt(cache.stats.size)
    statsJson["maxSize"] = newJInt(cache.stats.maxSize)
    statsJson["insertions"] = newJInt(cache.stats.insertions)
    statsJson["evictions"] = newJInt(cache.stats.evictions)
    statsJson["invalidations"] = newJInt(cache.stats.invalidations)
    statsJson["hitRatio"] = newJFloat(cache.stats.hitRatio)
    
    # 設定
    var optionsJson = newJObject()
    optionsJson["maxSize"] = newJInt(cache.options.maxSize)
    optionsJson["maxEntries"] = newJInt(cache.options.maxEntries)
    optionsJson["defaultTtl"] = newJInt(cache.options.defaultTtl)
    optionsJson["storageType"] = newJInt(ord(cache.options.storageType))
    optionsJson["evictionPolicy"] = newJInt(ord(cache.options.evictionPolicy))
    optionsJson["compressionEnabled"] = newJBool(cache.options.compressionEnabled)
    
    # ルートオブジェクト
    var rootJson = newJObject()
    rootJson["metadata"] = metadataJson
    rootJson["stats"] = statsJson
    rootJson["options"] = optionsJson
    rootJson["timestamp"] = newJInt(getTime().toUnix())
    
    # ファイルに書き込み
    writeFile(cache.options.persistencePath, $rootJson)
    return true
  except:
    return false

method restore*(cache: MemoryCache): Future[bool] {.async.} =
  ## キャッシュを復元
  if not cache.options.persistenceEnabled or cache.options.persistencePath.len == 0:
    return false
  
  if not fileExists(cache.options.persistencePath):
    return false
  
  acquire(cache.lock)
  defer: release(cache.lock)
  
  try:
    # キャッシュをクリア
    cache.cache.clear()
    cache.metadata.clear()
    cache.lruQueue = initHeapQueue[LRUEntry]()
    cache.currentSize = 0
    
    # ファイルから読み込み
    let jsonStr = readFile(cache.options.persistencePath)
    let rootJson = parseJson(jsonStr)
    
    # メタデータの復元
    if rootJson.hasKey("metadata"):
      let metadataJson = rootJson["metadata"]
      for key, value in metadataJson:
        var meta: CacheMetadata
        meta.key = key
        meta.size = value["size"].getInt()
        meta.accessTime = fromUnix(value["accessTime"].getInt())
        meta.createTime = fromUnix(value["createTime"].getInt())
        meta.expireTime = fromUnix(value["expireTime"].getInt())
        meta.accessCount = value["accessCount"].getInt()
        meta.priority = CachePriority(value["priority"].getInt())
        meta.entryType = CacheEntryType(value["entryType"].getInt())
        
        cache.metadata[key] = meta
        cache.currentSize += meta.size
        
        # LRUキューの更新
        cache.lruQueue.push(LRUEntry(key: key, accessTime: meta.accessTime))
    
    # 統計情報の復元
    if rootJson.hasKey("stats"):
      let statsJson = rootJson["stats"]
      cache.stats.hits = statsJson["hits"].getInt()
      cache.stats.misses = statsJson["misses"].getInt()
      cache.stats.entries = statsJson["entries"].getInt()
      cache.stats.size = statsJson["size"].getInt()
      cache.stats.maxSize = statsJson["maxSize"].getInt()
      cache.stats.insertions = statsJson["insertions"].getInt()
      cache.stats.evictions = statsJson["evictions"].getInt()
      cache.stats.invalidations = statsJson["invalidations"].getInt()
      cache.stats.hitRatio = statsJson["hitRatio"].getFloat()
    
    # 設定の復元
    if rootJson.hasKey("options"):
      let optionsJson = rootJson["options"]
      cache.options.maxSize = optionsJson["maxSize"].getInt()
      cache.options.maxEntries = optionsJson["maxEntries"].getInt()
      cache.options.defaultTtl = optionsJson["defaultTtl"].getInt()
      cache.options.storageType = CacheStorageType(optionsJson["storageType"].getInt())
      cache.options.evictionPolicy = CacheEvictionPolicy(optionsJson["evictionPolicy"].getInt())
      cache.options.compressionEnabled = optionsJson["compressionEnabled"].getBool()
    
    return true
  except:
    return false

proc getMetadata*(cache: MemoryCache, url: string): Option[CacheMetadata] =
  ## キャッシュエントリのメタデータを取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if cache.metadata.hasKey(url):
    return some(cache.metadata[url])
  return none(CacheMetadata)

proc setEntryPriority*(cache: MemoryCache, url: string, priority: CachePriority): bool =
  ## キャッシュエントリの優先度を設定
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if not cache.cache.hasKey(url) or not cache.metadata.hasKey(url):
    return false
  
  var meta = cache.metadata[url]
  meta.priority = priority
  cache.metadata[url] = meta
  
  if cache.cache.hasKey(url):
    var entry = cache.cache[url]
    entry.priority = priority
    cache.cache[url] = entry
  
  return true

proc touchEntry*(cache: MemoryCache, url: string): bool =
  ## キャッシュエントリのアクセス時間を更新
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if not cache.cache.hasKey(url) or not cache.metadata.hasKey(url):
    return false
  
  var meta = cache.metadata[url]
  meta.accessTime = getTime()
  meta.accessCount.inc
  cache.metadata[url] = meta
  
  # LRUキューの更新
  updateLRU(cache, url)
  
  if cache.cache.hasKey(url):
    updateLastAccessed(cache.cache[url])
  
  return true

proc getEntryAccessCount*(cache: MemoryCache, url: string): int =
  ## キャッシュエントリのアクセス回数を取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if cache.metadata.hasKey(url):
    return cache.metadata[url].accessCount
  return 0

proc getEntryCreationTime*(cache: MemoryCache, url: string): Option[Time] =
  ## キャッシュエントリの作成時間を取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if cache.metadata.hasKey(url):
    return some(cache.metadata[url].createTime)
  return none(Time)

proc getCacheSnapshot*(cache: MemoryCache): seq[string] =
  ## キャッシュの現在の状態のスナップショットを取得
  acquire(cache.lock)
  defer: release(cache.lock)
  
  for key in cache.cache.keys:
    result.add(key)

proc getCacheSizeByType*(cache: MemoryCache): Table[CacheEntryType, int] =
  ## タイプごとのキャッシュサイズを取得
  result = initTable[CacheEntryType, int]()
  
  acquire(cache.lock)
  defer: release(cache.lock)
  
  for _, meta in cache.metadata:
    if result.hasKey(meta.entryType):
      result[meta.entryType] += meta.size
    else:
      result[meta.entryType] = meta.size

# サンプル使用
when isMainModule:
  proc testMemoryCache() {.async.} =
    # キャッシュオプションを設定
    var options = defaultCacheOptions()
    options.maxSize = 10 * 1024 * 1024  # 10MB
    options.maxEntries = 1000
    options.evictionPolicy = cepLRU
    
    # メモリキャッシュを作成
    let cache = newMemoryCache(options)
    
    # テストデータ
    let url1 = "https://example.com/test1.html"
    let data1 = cast[seq[byte]]("This is test data 1")
    let entry1 = createResourceEntry(url1, data1, "text/html", 3600)
    
    let url2 = "https://example.com/test2.html"
    let data2 = cast[seq[byte]]("This is test data 2")
    let entry2 = createResourceEntry(url2, data2, "text/html", 60)
    
    # キャッシュに追加
    echo "Adding entry 1..."
    let result1 = await cache.put(entry1)
    echo "Result: ", result1
    
    echo "Adding entry 2..."
    let result2 = await cache.put(entry2)
    echo "Result: ", result2
    
    # キャッシュから取得
    echo "Getting entry 1..."
    let getResult1 = await cache.get(url1)
    if getResult1.isSome:
      let cachedEntry = getResult1.get()
      let resourceEntry = ResourceCacheEntry(cachedEntry)
      echo "Found entry: ", cast[string](resourceEntry.data)
    else:
      echo "Entry not found"
    
    # キャッシュ統計を表示
    echo "Cache stats:"
    let stats = cache.getStats()
    echo "  Hits: ", stats.hits
    echo "  Misses: ", stats.misses
    echo "  Entries: ", stats.entries
    echo "  Size: ", stats.size, " bytes"
    echo "  Hit ratio: ", stats.hitRatio * 100, "%"
    
    # 期限切れエントリをパージ
    await sleepAsync(65 * 1000)  # 65秒待機
    echo "Purging expired entries..."
    let purged = await cache.purgeExpired()
    echo "Purged ", purged, " entries"
    
    # 再度取得を試みる
    echo "Getting entry 2 (should be expired)..."
    let getResult2 = await cache.get(url2)
    if getResult2.isSome:
      echo "Found entry (unexpected)"
    else:
      echo "Entry not found (as expected)"
    
    # キャッシュをクリア
    echo "Clearing cache..."
    await cache.clear()
    echo "Cache cleared"
    
  waitFor testMemoryCache()