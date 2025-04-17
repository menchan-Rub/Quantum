import std/[asyncdispatch, httpclient, unittest, times, strutils, os, tables, options]
import ../memory/memory_cache
import ../disk/disk_cache
import ../http_cache_manager
import ../compression/compression
import ../policy/cache_policy

# テスト用のユーティリティ
proc createTestHttpClient(): HttpClient =
  result = newHttpClient()
  result.headers = newHttpHeaders({
    "User-Agent": "Nim Cache Test Client/1.0",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.7,en;q=0.3",
    "Accept-Encoding": "gzip, deflate"
  })

proc createTestCacheManager(): HttpCacheManager =
  # キャッシュディレクトリを作成
  let cacheDir = "test_cache"
  if dirExists(cacheDir):
    try:
      removeDir(cacheDir)
    except:
      echo "警告: 既存のキャッシュディレクトリを削除できませんでした"
  
  createDir(cacheDir)
  
  # キャッシュ設定を作成
  let config = newCacheConfig(
    maxMemorySizeMb = 10,          # テスト用に小さいサイズに
    maxDiskSizeMb = 20,
    defaultTtlSeconds = 3600,
    compressionEnabled = true,
    compressionLevel = clDefault,
    cacheDir = cacheDir,
    partitionByDomain = true,
    validateCacheOnStart = true,
    logLevel = llInfo
  )
  
  return newHttpCacheManager(config)

proc testBasicCaching() =
  test "基本的なキャッシュ機能のテスト":
    var manager = createTestCacheManager()
    
    # テスト用のエントリを作成
    var entry = CacheEntry(
      url: "https://example.com/",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=3600", 
        "ETag": "\"123456\"",
        "Content-Type": "text/html"
      }.toTable,
      body: "<html><body>Test Content</body></html>",
      timestamp: getTime(),
      expires: getTime() + initDuration(hours = 1),
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"123456\"",
      varyHeaders: initTable[string, string](),
      isCompressed: false
    )
    
    # キャッシュに保存
    manager.put(entry)
    
    # キャッシュから取得
    let result = manager.get(entry.url)
    check(result.isSome)
    
    if result.isSome:
      let (cached, needsRevalidation) = result.get()
      check(cached.url == entry.url)
      check(cached.body == entry.body)
      check(not needsRevalidation)

proc testCacheCompression() =
  test "キャッシュ圧縮機能のテスト":
    var manager = createTestCacheManager()
    
    # 圧縮に適した大きなコンテンツを作成
    var largeContent = "<html><body><h1>Large Content</h1>"
    for i in 1..100:
      largeContent &= "<p>This is paragraph " & $i & " with some content that should compress well.</p>"
    largeContent &= "</body></html>"
    
    # テスト用のエントリを作成
    var entry = CacheEntry(
      url: "https://example.com/large",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=3600", 
        "Content-Type": "text/html"
      }.toTable,
      body: largeContent,
      timestamp: getTime(),
      expires: getTime() + initDuration(hours = 1),
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"abcdef\"",
      varyHeaders: initTable[string, string](),
      isCompressed: false
    )
    
    # 圧縮前のサイズを記録
    let originalSize = entry.body.len
    
    # キャッシュに保存（圧縮あり）
    manager.put(entry, "gzip, deflate")
    
    # 圧縮が行われたことを確認
    check(entry.isCompressed)
    check(entry.headers.hasKey("Content-Encoding"))
    check(entry.body.len < originalSize)
    
    # 圧縮をサポートするクライアントのリクエスト
    let compressedResult = manager.get(entry.url, "GET", {"Accept-Encoding": "gzip, deflate"}.toTable)
    check(compressedResult.isSome)
    
    if compressedResult.isSome:
      let (cached, _) = compressedResult.get()
      check(cached.isCompressed)
      check(cached.headers.hasKey("Content-Encoding"))
      check(cached.body.len < originalSize)
    
    # 圧縮をサポートしないクライアントのリクエスト
    let uncompressedResult = manager.get(entry.url)
    check(uncompressedResult.isSome)
    
    if uncompressedResult.isSome:
      let (cached, _) = uncompressedResult.get()
      check(not cached.isCompressed)
      check(not cached.headers.hasKey("Content-Encoding"))
      check(cached.body.len == originalSize)
      check(cached.body == largeContent)

proc testConditionalRequest() =
  test "条件付きリクエストのテスト":
    var manager = createTestCacheManager()
    
    # テスト用のエントリを作成
    var entry = CacheEntry(
      url: "https://example.com/conditional",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=0, must-revalidate", 
        "ETag": "\"conditional-etag\"",
        "Content-Type": "text/plain"
      }.toTable,
      body: "Original content",
      timestamp: getTime() - initDuration(hours = 2),  # 期限切れのエントリ
      expires: getTime() - initDuration(hours = 1),    # 1時間前に期限切れ
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"conditional-etag\"",
      varyHeaders: initTable[string, string](),
      isCompressed: false
    )
    
    # キャッシュに保存
    manager.put(entry)
    
    # キャッシュから取得（再検証が必要なはず）
    let result = manager.get(entry.url)
    check(result.isSome)
    
    if result.isSome:
      let (cached, needsRevalidation) = result.get()
      check(needsRevalidation)  # 再検証が必要
      
      # 条件付きリクエスト用のヘッダーを生成
      let conditionalHeaders = createConditionalRequestHeaders(cached)
      check(conditionalHeaders.hasKey("If-None-Match"))
      check(conditionalHeaders["If-None-Match"] == "\"conditional-etag\"")
      check(conditionalHeaders.hasKey("If-Modified-Since"))
      
      # 304 Not Modified応答をシミュレート
      let notModifiedHeaders = {
        "Date": formatHttpTime(getTime()),
        "ETag": "\"conditional-etag\"",
        "Cache-Control": "max-age=3600"
      }.toTable
      
      # 再検証でエントリを更新
      let updatedEntry = manager.updateWithRevalidationResponse(cached, 304, notModifiedHeaders)
      
      # 更新されたエントリをチェック
      check(updatedEntry.etag == "\"conditional-etag\"")
      check(updatedEntry.body == "Original content")
      check(updatedEntry.timestamp > cached.timestamp)  # タイムスタンプが更新されたか
      
      # 新しい有効期限が設定されたか
      check(updatedEntry.expires > getTime())

proc testVaryHeader() =
  test "Varyヘッダーのテスト":
    var manager = createTestCacheManager()
    
    # 英語版コンテンツを作成
    var englishEntry = CacheEntry(
      url: "https://example.com/multilang",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=3600", 
        "Content-Type": "text/plain",
        "Vary": "Accept-Language"
      }.toTable,
      body: "Hello, World!",
      timestamp: getTime(),
      expires: getTime() + initDuration(hours = 1),
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"english-version\"",
      varyHeaders: {"Accept-Language": "en-US"}.toTable,
      isCompressed: false
    )
    
    # 日本語版コンテンツを作成
    var japaneseEntry = CacheEntry(
      url: "https://example.com/multilang",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=3600", 
        "Content-Type": "text/plain",
        "Vary": "Accept-Language"
      }.toTable,
      body: "こんにちは、世界！",
      timestamp: getTime(),
      expires: getTime() + initDuration(hours = 1),
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"japanese-version\"",
      varyHeaders: {"Accept-Language": "ja"}.toTable,
      isCompressed: false
    )
    
    # 両方のエントリをキャッシュに保存
    manager.put(englishEntry)
    manager.put(japaneseEntry)
    
    # 英語版をリクエスト
    let englishResult = manager.get(englishEntry.url, "GET", {"Accept-Language": "en-US"}.toTable)
    check(englishResult.isSome)
    
    if englishResult.isSome:
      let (cached, _) = englishResult.get()
      check(cached.body == "Hello, World!")
      check(cached.etag == "\"english-version\"")
    
    # 日本語版をリクエスト
    let japaneseResult = manager.get(japaneseEntry.url, "GET", {"Accept-Language": "ja"}.toTable)
    check(japaneseResult.isSome)
    
    if japaneseResult.isSome:
      let (cached, _) = japaneseResult.get()
      check(cached.body == "こんにちは、世界！")
      check(cached.etag == "\"japanese-version\"")

proc testCacheEviction() =
  test "キャッシュ追い出しのテスト":
    # 小さいサイズのキャッシュを作成
    let cacheDir = "eviction_test_cache"
    if dirExists(cacheDir):
      removeDir(cacheDir)
    createDir(cacheDir)
    
    let config = newCacheConfig(
      maxMemorySizeMb = 1,     # 非常に小さいメモリキャッシュ (1MB)
      maxDiskSizeMb = 2,       # 非常に小さいディスクキャッシュ (2MB)
      defaultTtlSeconds = 3600,
      compressionEnabled = false,  # テストを単純化するために圧縮を無効化
      cacheDir = cacheDir
    )
    
    var manager = newHttpCacheManager(config)
    
    # 十分な大きさのデータを生成
    let largeData = "X".repeat(500 * 1024)  # 500KB
    
    # 5つのエントリをキャッシュに追加（合計約2.5MB）
    for i in 1..5:
      var entry = CacheEntry(
        url: "https://example.com/large" & $i,
        method: "GET",
        statusCode: 200,
        headers: {"Cache-Control": "max-age=3600"}.toTable,
        body: largeData,
        timestamp: getTime(),
        expires: getTime() + initDuration(hours = 1),
        etag: "\"large" & $i & "\"",
        varyHeaders: initTable[string, string](),
        isCompressed: false
      )
      
      manager.put(entry)
      
      # 少し待機（アクセス時刻を確実に異なるものにするため）
      sleep(100)
    
    # 最初のエントリが追い出されているか確認
    let result1 = manager.get("https://example.com/large1")
    check(result1.isNone)
    
    # 最後のエントリはまだキャッシュに残っているはず
    let result5 = manager.get("https://example.com/large5")
    check(result5.isSome)

proc runTests() =
  suite "HTTPキャッシュマネージャー統合テスト":
    testBasicCaching()
    testCacheCompression()
    testConditionalRequest()
    testVaryHeader()
    testCacheEviction()

when isMainModule:
  echo "HTTPキャッシュマネージャー統合テストを開始します..."
  runTests()
  echo "統合テストが完了しました。" 