import std/[times, tables, strutils, options, unittest]
import ../memory/memory_cache
import ../disk/disk_cache
import ../http_cache_manager
import ../policy/cache_policy

proc testMemoryCache() =
  echo "メモリキャッシュのテスト"
  
  # キャッシュを作成（最大10MB）
  var cache = newMemoryCache(10)
  
  # テスト用のエントリを作成
  var entry = CacheEntry(
    url: "https://example.com/",
    method: "GET",
    statusCode: 200,
    headers: {"Cache-Control": "max-age=3600"}.toTable,
    body: "Hello, World!",
    timestamp: getTime(),
    expires: getTime() + initDuration(hours = 1),
    lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
    etag: "\"33a64df551425fcc55e4d42aab7957529b243b9b\"",
    varyHeaders: initTable[string, string]()
  )
  
  # エントリをキャッシュに保存
  cache.put("test_key", entry)
  
  # キャッシュから取得
  let retrieved = cache.get("test_key")
  check(retrieved.isSome)
  if retrieved.isSome:
    let cached = retrieved.get()
    check(cached.url == entry.url)
    check(cached.statusCode == entry.statusCode)
    check(cached.body == entry.body)
  
  # 統計情報を表示
  echo cache.getStats()
  
  # キャッシュをクリア
  cache.clear()
  check(cache.entries.len == 0)
  check(cache.currentSizeBytes == 0)

proc testDiskCache() =
  echo "ディスクキャッシュのテスト"
  
  # キャッシュ設定を作成
  let config = newCacheConfig(
    maxDiskSizeMb = 100,
    defaultTtlSeconds = 3600,
    compressionEnabled = true,
    cacheDir = "test_cache"
  )
  
  # キャッシュを作成
  var cache = newDiskCache(config)
  
  # テスト用のエントリを作成
  var entry = CacheEntry(
    url: "https://example.com/",
    method: "GET",
    statusCode: 200,
    headers: {"Cache-Control": "max-age=3600"}.toTable,
    body: "Hello, World!",
    timestamp: getTime(),
    expires: getTime() + initDuration(hours = 1),
    lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
    etag: "\"33a64df551425fcc55e4d42aab7957529b243b9b\"",
    varyHeaders: initTable[string, string]()
  )
  
  # エントリをキャッシュに保存
  cache.put("test_key", entry)
  
  # キャッシュから取得
  let retrieved = cache.get("test_key")
  check(retrieved.isSome)
  if retrieved.isSome:
    let cached = retrieved.get()
    check(cached.url == entry.url)
    check(cached.statusCode == entry.statusCode)
    check(cached.body == entry.body)
  
  # 統計情報を表示
  echo cache.getStats()
  
  # キャッシュをクリア
  cache.clear()
  check(cache.index.len == 0)
  check(cache.currentSizeBytes == 0)

proc testHttpCacheManager() =
  echo "HTTPキャッシュマネージャのテスト"
  
  # キャッシュマネージャを作成
  let config = newCacheConfig(
    maxMemorySizeMb = 100,
    maxDiskSizeMb = 1000,
    defaultTtlSeconds = 3600,
    compressionEnabled = true,
    cacheDir = "test_cache"
  )
  var manager = newHttpCacheManager(config)
  
  # テスト用のエントリを作成
  var entry = CacheEntry(
    url: "https://example.com/",
    method: "GET",
    statusCode: 200,
    headers: {"Cache-Control": "max-age=3600"}.toTable,
    body: "Hello, World!",
    timestamp: getTime(),
    expires: getTime() + initDuration(hours = 1),
    lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
    etag: "\"33a64df551425fcc55e4d42aab7957529b243b9b\"",
    varyHeaders: initTable[string, string]()
  )
  
  # エントリをキャッシュに保存
  manager.put(entry)
  
  # キャッシュから取得
  let retrieved = manager.get(entry.url)
  check(retrieved.isSome)
  if retrieved.isSome:
    let cached = retrieved.get()
    check(cached.url == entry.url)
    check(cached.statusCode == entry.statusCode)
    check(cached.body == entry.body)
  
  # 統計情報を表示
  echo manager.getStats()
  
  # キャッシュをクリア
  manager.clear()
  check(manager.memoryCache.entries.len == 0)
  check(manager.diskCache.index.len == 0)

proc testCachePolicy() =
  echo "キャッシュポリシーのテスト"
  
  # Cache-Controlヘッダーのパース
  let header1 = "max-age=3600, must-revalidate"
  let policy1 = parseCacheControl(header1)
  check(policy1.maxAgeSec == 3600)
  check(ccfMustRevalidate in policy1.flags)
  
  let header2 = "no-store, no-cache"
  let policy2 = parseCacheControl(header2)
  check(ccfNoStore in policy2.flags)
  check(ccfNoCache in policy2.flags)
  
  # フレッシュネスの計算
  let now = getTime()
  let responseTime = now - initDuration(minutes = 30)
  let lastModified = some(now - initDuration(days = 2))
  let expires = some(now + initDuration(hours = 1))
  
  let freshness1 = calculateFreshnessLifetime(responseTime, 3600, none(Time), none(Time))
  check(freshness1 == 3600)
  
  let freshness2 = calculateFreshnessLifetime(responseTime, -1, expires, none(Time))
  check(freshness2 == 3600)
  
  let freshness3 = calculateFreshnessLifetime(responseTime, -1, none(Time), lastModified)
  check(freshness3 > 0)
  
  # フレッシュかどうかのチェック
  let age1 = 1800  # 30分経過
  let age2 = 7200  # 2時間経過
  check(isFresh(age1, 3600))
  check(not isFresh(age2, 3600))
  
  # ポリシー評価
  var reqPolicy = newCachePolicy()
  reqPolicy.maxStaleSec = 600  # 最大10分の古さを許容
  
  var respPolicy = newCachePolicy()
  respPolicy.maxAgeSec = 3600  # 1時間のフレッシュネス
  
  let result1 = evaluateCachePolicy(
    reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
  )
  check(result1 == cprCanUseStored)
  
  respPolicy.flags.incl(ccfNoCache)
  let result2 = evaluateCachePolicy(
    reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
  )
  check(result2 == cprMustRevalidate)
  
  respPolicy.flags.excl(ccfNoCache)
  respPolicy.flags.incl(ccfNoStore)
  let result3 = evaluateCachePolicy(
    reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
  )
  check(result3 == cprMustFetch)
  
  # キャッシュキーの生成
  var varyHeaders = {"Accept-Encoding": "gzip", "User-Agent": "TestBrowser"}.toTable
  let key1 = generateCacheKey("https://example.com/", "GET", varyHeaders, true)
  check(key1.len > 0)
  
  let key2 = generateCacheKey("https://example.com/", "GET", initTable[string, string](), true)
  check(key2.len > 0)
  
  # Varyヘッダーのパース
  let varyHeader = "Accept-Encoding, User-Agent, Accept-Language"
  let varyFields = parseVaryHeader(varyHeader)
  check(varyFields.len == 3)
  
  # レスポンスをキャッシュすべきか
  let headers = {"Cache-Control": "max-age=3600"}.toTable
  check(shouldCacheResponse(200, "GET", headers))
  check(shouldCacheResponse(404, "GET", headers))
  check(not shouldCacheResponse(500, "GET", headers))
  check(not shouldCacheResponse(200, "POST", headers))

when isMainModule:
  # テストを実行
  testMemoryCache()
  testDiskCache()
  testHttpCacheManager()
  testCachePolicy() 