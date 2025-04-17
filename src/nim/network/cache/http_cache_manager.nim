import std/[times, tables, strutils, options, asyncdispatch, os, parseutils, uri]
import ./memory/memory_cache
import ./disk/disk_cache
import ./policy/cache_policy
import ./compression/compression

type
  HttpCacheManager* = object
    ## HTTPキャッシュマネージャ
    memoryCache*: MemoryCache    # メモリキャッシュ
    diskCache*: DiskCache        # ディスクキャッシュ
    config*: CacheConfig         # キャッシュ設定
    stats*: CacheStats           # キャッシュ統計情報
    compressionConfig*: CompressionConfig  # 圧縮設定

  CacheConfig* = object
    ## キャッシュ設定
    maxMemorySizeMb*: int        # メモリキャッシュの最大サイズ（MB）
    maxDiskSizeMb*: int          # ディスクキャッシュの最大サイズ（MB）
    defaultTtlSeconds*: int      # デフォルトのTTL（秒）
    compressionEnabled*: bool    # 圧縮を有効にするかどうか
    compressionLevel*: CompressionLevel  # 圧縮レベル
    cacheDir*: string            # キャッシュディレクトリ
    partitionByDomain*: bool     # ドメインごとにキャッシュを分割するかどうか
    validateCacheOnStart*: bool  # 起動時にキャッシュの整合性を検証するかどうか
    logLevel*: LogLevel          # ログレベル

  CacheEntry* = object
    ## キャッシュエントリ
    url*: string                 # URL
    method*: string              # HTTPメソッド
    statusCode*: int             # ステータスコード
    headers*: Table[string, string]  # レスポンスヘッダー
    body*: string                # レスポンスボディ
    timestamp*: Time             # キャッシュされた時刻
    expires*: Time               # 有効期限
    lastModified*: string        # Last-Modifiedヘッダー
    etag*: string                # ETagヘッダー
    varyHeaders*: Table[string, string]  # Varyヘッダー
    isCompressed*: bool          # 圧縮されているかどうか

  CacheStats* = object
    ## キャッシュ統計情報
    hits*: int                   # ヒット数
    misses*: int                 # ミス数
    servingStale*: int           # 古いレスポンスの提供回数
    revalidations*: int          # 再検証回数
    revalidationHits*: int       # 再検証ヒット数（304応答）
    revalidationMisses*: int     # 再検証ミス数（新しいコンテンツ取得）
    evictions*: int              # 追い出し数
    errors*: int                 # エラー数
    compressionCount*: int       # 圧縮回数
    compressionSavings*: int     # 圧縮による節約バイト数

  ConditionalRequestInfo* = object
    ## 条件付きリクエストの情報
    etag*: string                # ETag
    lastModified*: string        # Last-Modified
    needsRevalidation*: bool     # 再検証が必要かどうか

  LogLevel* = enum
    llError, llWarn, llInfo, llDebug

# HTTPタイムスタンプフォーマット (RFC 7231)
const HTTP_TIME_FORMAT = "ddd, dd MMM yyyy HH:mm:ss 'GMT'"

proc newCacheConfig*(
  maxMemorySizeMb: int = 100,
  maxDiskSizeMb: int = 1000,
  defaultTtlSeconds: int = 3600,
  compressionEnabled: bool = true,
  compressionLevel: CompressionLevel = clDefault,
  cacheDir: string = "cache",
  partitionByDomain: bool = true,
  validateCacheOnStart: bool = true,
  logLevel: LogLevel = llInfo
): CacheConfig =
  ## 新しいキャッシュ設定を作成する
  result = CacheConfig(
    maxMemorySizeMb: maxMemorySizeMb,
    maxDiskSizeMb: maxDiskSizeMb,
    defaultTtlSeconds: defaultTtlSeconds,
    compressionEnabled: compressionEnabled,
    compressionLevel: compressionLevel,
    cacheDir: cacheDir,
    partitionByDomain: partitionByDomain,
    validateCacheOnStart: validateCacheOnStart,
    logLevel: logLevel
  )

proc newHttpCacheManager*(config: CacheConfig): HttpCacheManager =
  ## 新しいHTTPキャッシュマネージャを作成する
  
  # キャッシュディレクトリを作成
  if not dirExists(config.cacheDir):
    createDir(config.cacheDir)
  
  # 圧縮設定を作成
  let compressionConfig = newCompressionConfig(
    enabled = config.compressionEnabled,
    defaultType = ctGzip,
    level = config.compressionLevel,
    minSizeToCompress = 1024,  # 1KB
    excludedTypes = @["image/", "video/", "audio/", "application/octet-stream"]
  )
  
  result = HttpCacheManager(
    memoryCache: newMemoryCache(config.maxMemorySizeMb),
    diskCache: newDiskCache(config),
    config: config,
    stats: CacheStats(),
    compressionConfig: compressionConfig
  )
  
  # 起動時にキャッシュの整合性を検証
  if config.validateCacheOnStart:
    result.validateCache()

proc validateCache*(manager: HttpCacheManager) =
  ## キャッシュの整合性を検証し、必要に応じて修復する
  let startTime = getTime()
  var entriesChecked = 0
  var entriesRepaired = 0
  var entriesRemoved = 0
  
  # ディスクキャッシュの検証
  for entry in manager.diskCache.getAllEntries():
    inc(entriesChecked)
    
    # メタデータと実際のコンテンツの整合性チェック
    if not manager.diskCache.validateEntry(entry):
      # 修復可能な場合は修復
      if manager.diskCache.repairEntry(entry):
        inc(entriesRepaired)
      else:
        # 修復不可能な場合は削除
        manager.diskCache.removeEntry(entry.url, entry.method)
        inc(entriesRemoved)
    
    # 期限切れエントリーの削除
    if entry.isExpired() and not entry.canServeStale():
      manager.diskCache.removeEntry(entry.url, entry.method)
      inc(entriesRemoved)
  
  # メモリキャッシュの検証（期限切れエントリーの削除のみ）
  for entry in manager.memoryCache.getAllEntries():
    inc(entriesChecked)
    if entry.isExpired() and not entry.canServeStale():
      manager.memoryCache.removeEntry(entry.url, entry.method)
      inc(entriesRemoved)
  
  # ログ出力
  if manager.config.logLevel >= llInfo:
    let duration = getTime() - startTime
    echo fmt"キャッシュ検証完了: {entriesChecked}エントリーをチェック、{entriesRepaired}エントリーを修復、{entriesRemoved}エントリーを削除 ({duration.inMilliseconds()}ms)"

proc parseHttpTime*(timeStr: string): Time =
  ## HTTP日付形式を解析してTimeオブジェクトを返す
  ## 例: "Wed, 21 Oct 2015 07:28:00 GMT"
  try:
    # RFC 7231フォーマット
    result = parse(timeStr, HTTP_TIME_FORMAT, utc())
  except:
    try:
      # RFC 850フォーマット
      result = parse(timeStr, "dddd, dd-MMM-yy HH:mm:ss 'GMT'", utc())
    except:
      try:
        # asctime()フォーマット
        result = parse(timeStr, "ddd MMM d HH:mm:ss yyyy", utc())
      except:
        # 解析に失敗した場合は現在時刻を返す
        result = getTime()

proc formatHttpTime*(t: Time): string =
  ## TimeオブジェクトをHTTP日付形式に変換する
  ## 例: "Wed, 21 Oct 2015 07:28:00 GMT"
  return format(t, HTTP_TIME_FORMAT, utc())

proc getDomainFromUrl*(url: string): string =
  ## URLからドメイン部分を取得する
  try:
    let uri = parseUri(url)
    return uri.hostname
  except:
    return ""

proc getCachePath*(manager: HttpCacheManager, url: string): string =
  ## URLに基づいてキャッシュパスを生成する
  if not manager.config.partitionByDomain:
    return manager.config.cacheDir
  
  let domain = getDomainFromUrl(url)
  if domain.len == 0:
    return manager.config.cacheDir
  
  let domainDir = manager.config.cacheDir / domain
  if not dirExists(domainDir):
    createDir(domainDir)
  
  return domainDir

proc generateCacheKey*(entry: CacheEntry): string =
  ## キャッシュキーを生成する
  result = entry.method & ":" & entry.url
  
  # Varyヘッダーに応じてキーを変化させる
  if entry.varyHeaders.len > 0:
    var varyParts: seq[string] = @[]
    for k, v in entry.varyHeaders:
      varyParts.add(k & "=" & v)
    
    # ソートして順序を一定に
    varyParts.sort()
    result &= ":" & varyParts.join("|")

proc shouldCache*(manager: HttpCacheManager, entry: CacheEntry): bool =
  ## エントリをキャッシュすべきかどうかを判断する
  result = shouldCacheResponse(entry.statusCode, entry.method, entry.headers)

proc getConditionalRequestInfo*(entry: CacheEntry): ConditionalRequestInfo =
  ## 条件付きリクエストのための情報を取得する
  result.needsRevalidation = false
  
  # ETagがある場合
  if entry.etag.len > 0:
    result.etag = entry.etag
    result.needsRevalidation = true
  
  # Last-Modifiedがある場合
  if entry.lastModified.len > 0:
    result.lastModified = entry.lastModified
    result.needsRevalidation = true

proc createConditionalRequestHeaders*(entry: CacheEntry): Table[string, string] =
  ## エントリに基づいて条件付きリクエスト用のヘッダーを作成する
  result = initTable[string, string]()
  
  # ETagがある場合はIf-None-Matchヘッダーを追加
  if entry.etag.len > 0:
    result["If-None-Match"] = entry.etag
  
  # Last-Modifiedがある場合はIf-Modified-Sinceヘッダーを追加
  if entry.lastModified.len > 0:
    result["If-Modified-Since"] = entry.lastModified

proc put*(manager: var HttpCacheManager, entry: var CacheEntry, acceptEncoding: string = "gzip, deflate") =
  ## エントリをキャッシュに保存する
  if not manager.shouldCache(entry):
    return
  
  # コンテンツタイプを取得
  let contentType = if entry.headers.hasKey("Content-Type"): entry.headers["Content-Type"] else: "application/octet-stream"
  
  # 圧縮が有効で、まだ圧縮されていない場合
  if manager.config.compressionEnabled and not entry.isCompressed:
    let (compressedData, encoding, compressed) = compressForCache(
      manager.compressionConfig, entry.body, contentType, acceptEncoding
    )
    
    if compressed:
      # 圧縮されたデータで更新
      entry.body = compressedData
      entry.isCompressed = true
      
      # Content-Encodingヘッダーを追加
      entry.headers["Content-Encoding"] = encoding
      
      # 統計情報を更新
      manager.stats.compressionCount += 1
      manager.stats.compressionSavings += (entry.body.len - compressedData.len)
  
  let key = generateCacheKey(entry)
  
  # メモリキャッシュに保存
  manager.memoryCache.put(key, entry)
  
  # ディスクキャッシュに保存
  manager.diskCache.put(key, entry)

proc get*(manager: var HttpCacheManager, url: string, method: string = "GET", requestHeaders: Table[string, string] = initTable[string, string]()): Option[tuple[entry: CacheEntry, needsRevalidation: bool]] =
  ## キャッシュからエントリを取得する
  ## 戻り値: エントリと再検証が必要かどうかのフラグのタプル
  
  let result = manager.retrieveFromCache(url, method, requestHeaders)
  if result.isNone:
    return result
  
  var (entry, needsRevalidation) = result.get()
  
  # 圧縮されているかどうかを確認
  if entry.isCompressed and entry.headers.hasKey("Content-Encoding"):
    let encoding = entry.headers["Content-Encoding"]
    var compressionType = ctNone
    
    # エンコーディングに対応する圧縮タイプを特定
    case encoding.toLowerAscii()
    of "gzip": compressionType = ctGzip
    of "deflate": compressionType = ctDeflate
    of "br": compressionType = ctBrotli
    else: compressionType = ctNone
    
    # クライアントがこの圧縮タイプを受け入れるかどうかを確認
    let acceptEncoding = if requestHeaders.hasKey("Accept-Encoding"): requestHeaders["Accept-Encoding"] else: ""
    if acceptEncoding.len > 0 and acceptEncoding.toLowerAscii().contains(encoding.toLowerAscii()):
      # クライアントは圧縮を受け入れる - 圧縮されたままで返す
      return some((entry, needsRevalidation))
    else:
      # クライアントは圧縮を受け入れない - 展開する必要がある
      try:
        let decompressedBody = decompressData(entry.body, compressionType)
        entry.body = decompressedBody
        entry.isCompressed = false
        entry.headers.del("Content-Encoding")
      except:
        # 展開に失敗した場合はそのまま返す
        manager.stats.errors += 1
  
  return some((entry, needsRevalidation))

proc retrieveFromCache*(manager: var HttpCacheManager, url: string, method: string = "GET", requestHeaders: Table[string, string] = initTable[string, string]()): Option[tuple[entry: CacheEntry, needsRevalidation: bool]] =
  ## キャッシュからエントリを取得する内部メソッド
  
  # メモリキャッシュを確認
  let memoryKey = method & ":" & url
  if manager.memoryCache.hasKey(memoryKey):
    let entry = manager.memoryCache.get(memoryKey)
    if entry.isSome:
      var cacheEntry = entry.get()
      
      # Varyヘッダーがある場合は、リクエストヘッダーと一致するか確認
      if cacheEntry.headers.hasKey("Vary"):
        let varyFields = parseVaryHeader(cacheEntry.headers["Vary"])
        
        # リクエストヘッダーからVaryフィールドを抽出
        let requestVaryHeaders = extractVaryHeadersFromRequest(requestHeaders, varyFields)
        
        # キーを生成し直す
        let varyKey = method & ":" & url & ":" & requestVaryHeaders.join("|")
        
        # バリエーションが一致しなければ別のエントリを探す
        if varyKey != memoryKey and manager.memoryCache.hasKey(varyKey):
          let varyEntry = manager.memoryCache.get(varyKey)
          if varyEntry.isSome:
            cacheEntry = varyEntry.get()
      
      # キャッシュポリシーを評価
      let metadata = CacheEntryMetadata(
        etag: cacheEntry.etag,
        lastModified: cacheEntry.lastModified,
        expires: cacheEntry.expires,
        headers: cacheEntry.headers
      )
      
      let policy = evaluateCacheResponse(metadata, requestHeaders)
      case policy
      of cprCanUseStored:
        # キャッシュヒット
        manager.stats.hits += 1
        return some((cacheEntry, false))
      of cprMustRevalidate:
        # 再検証が必要
        manager.stats.revalidations += 1
        return some((cacheEntry, true))
      of cprMustFetch:
        # キャッシュ不可
        manager.stats.misses += 1
        return none(tuple[entry: CacheEntry, needsRevalidation: bool])
  
  # ディスクキャッシュを確認（メモリキャッシュに見つからなかった場合）
  let diskKey = method & ":" & url
  if manager.diskCache.hasKey(diskKey):
    let entry = manager.diskCache.get(diskKey)
    if entry.isSome:
      var cacheEntry = entry.get()
      
      # Varyヘッダーがある場合は、リクエストヘッダーと一致するか確認
      if cacheEntry.headers.hasKey("Vary"):
        let varyFields = parseVaryHeader(cacheEntry.headers["Vary"])
        
        # リクエストヘッダーからVaryフィールドを抽出
        let requestVaryHeaders = extractVaryHeadersFromRequest(requestHeaders, varyFields)
        
        # キーを生成し直す
        let varyKey = method & ":" & url & ":" & requestVaryHeaders.join("|")
        
        # バリエーションが一致しなければ別のエントリを探す
        if varyKey != diskKey and manager.diskCache.hasKey(varyKey):
          let varyEntry = manager.diskCache.get(varyKey)
          if varyEntry.isSome:
            cacheEntry = varyEntry.get()
      
      # メモリキャッシュに移動
      manager.memoryCache.put(diskKey, cacheEntry)
      
      # キャッシュポリシーを評価
      let metadata = CacheEntryMetadata(
        etag: cacheEntry.etag,
        lastModified: cacheEntry.lastModified,
        expires: cacheEntry.expires,
        headers: cacheEntry.headers
      )
      
      let policy = evaluateCacheResponse(metadata, requestHeaders)
      case policy
      of cprCanUseStored:
        # キャッシュヒット
        manager.stats.hits += 1
        return some((cacheEntry, false))
      of cprMustRevalidate:
        # 再検証が必要
        manager.stats.revalidations += 1
        return some((cacheEntry, true))
      of cprMustFetch:
        # キャッシュ不可
        manager.stats.misses += 1
        return none(tuple[entry: CacheEntry, needsRevalidation: bool])
  
  # キャッシュミス
  manager.stats.misses += 1
  return none(tuple[entry: CacheEntry, needsRevalidation: bool])

proc updateWithRevalidationResponse*(manager: var HttpCacheManager, original: CacheEntry, statusCode: int, responseHeaders: Table[string, string], body: string = ""): CacheEntry =
  ## 再検証レスポンスでエントリを更新する
  var updated = original
  
  if statusCode == 304:  # Not Modified
    # 再検証ヒット
    manager.stats.revalidationHits += 1
    
    # 一部のヘッダーを更新
    for key, value in responseHeaders:
      case key.toLowerAscii()
      of "date", "expires", "cache-control", "etag", "last-modified":
        updated.headers[key] = value
      else:
        discard
    
    # 有効期限を更新
    if responseHeaders.hasKey("Expires"):
      updated.expires = parseHttpTime(responseHeaders["Expires"])
    
    # ETagを更新
    if responseHeaders.hasKey("ETag"):
      updated.etag = responseHeaders["ETag"]
    
    # Last-Modifiedを更新
    if responseHeaders.hasKey("Last-Modified"):
      updated.lastModified = responseHeaders["Last-Modified"]
    
    # タイムスタンプを更新
    updated.timestamp = getTime()
    
    # キャッシュに保存
    let key = generateCacheKey(updated)
    manager.memoryCache.put(key, updated)
    manager.diskCache.put(key, updated)
  else:
    # 再検証ミス（新しいコンテンツ）
    manager.stats.revalidationMisses += 1
    
    # 新しいエントリを作成
    updated = CacheEntry(
      url: original.url,
      method: original.method,
      statusCode: statusCode,
      headers: responseHeaders,
      body: body,
      timestamp: getTime(),
      expires: getTime() + initDuration(seconds = manager.config.defaultTtlSeconds),
      lastModified: if responseHeaders.hasKey("Last-Modified"): responseHeaders["Last-Modified"] else: "",
      etag: if responseHeaders.hasKey("ETag"): responseHeaders["ETag"] else: "",
      varyHeaders: original.varyHeaders,
      isCompressed: original.isCompressed
    )
    
    # Cache-Controlがある場合は有効期限を設定
    if responseHeaders.hasKey("Cache-Control"):
      let policy = parseCacheControl(responseHeaders["Cache-Control"])
      if policy.maxAgeSec >= 0:
        updated.expires = getTime() + initDuration(seconds = policy.maxAgeSec)
    
    # Expiresヘッダーがある場合は有効期限を設定
    if responseHeaders.hasKey("Expires"):
      updated.expires = parseHttpTime(responseHeaders["Expires"])
    
    # キャッシュに保存
    let key = generateCacheKey(updated)
    manager.memoryCache.put(key, updated)
    manager.diskCache.put(key, updated)
  
  return updated

proc remove*(manager: var HttpCacheManager, url: string, method: string = "GET") =
  ## エントリをキャッシュから削除する
  let key = method & ":" & url
  
  # メモリキャッシュから削除
  manager.memoryCache.remove(key)
  
  # ディスクキャッシュから削除
  manager.diskCache.remove(key)

proc clear*(manager: var HttpCacheManager) =
  ## キャッシュをクリアする
  manager.memoryCache.clear()
  manager.diskCache.clear()
  
  # 統計情報をリセット
  manager.stats = CacheStats()

proc getStats*(manager: HttpCacheManager): string =
  ## キャッシュの統計情報を取得する
  result = "HTTPキャッシュマネージャの統計情報:\n"
  result &= "ヒット数: " & $manager.stats.hits & "\n"
  result &= "ミス数: " & $manager.stats.misses & "\n"
  result &= "ヒット率: " & $(if manager.stats.hits + manager.stats.misses > 0: 
      manager.stats.hits.float / (manager.stats.hits + manager.stats.misses).float * 100.0 else: 0.0) & "%\n"
  result &= "再検証回数: " & $manager.stats.revalidations & "\n"
  result &= "再検証ヒット数: " & $manager.stats.revalidationHits & "\n"
  result &= "再検証ミス数: " & $manager.stats.revalidationMisses & "\n"
  result &= "古いレスポンスの提供回数: " & $manager.stats.servingStale & "\n"
  result &= "追い出し数: " & $manager.stats.evictions & "\n"
  result &= "エラー数: " & $manager.stats.errors & "\n"
  
  # 圧縮に関する統計情報
  if manager.config.compressionEnabled:
    result &= "圧縮回数: " & $manager.stats.compressionCount & "\n"
    result &= "圧縮による節約: " & $(manager.stats.compressionSavings / 1024.0) & " KB\n"
    result &= "平均圧縮率: " & $(if manager.stats.compressionCount > 0: 
        manager.stats.compressionSavings.float / manager.stats.compressionCount.float else: 0.0) & " バイト/エントリ\n"
  
  result &= "\nメモリキャッシュ:\n"
  result &= manager.memoryCache.getStats()
  result &= "\nディスクキャッシュ:\n"
  result &= manager.diskCache.getStats()

when isMainModule:
  # テスト用のメイン関数
  proc testHttpCacheManager() =
    echo "HTTPキャッシュマネージャのテスト"
    
    # キャッシュマネージャを作成
    let config = newCacheConfig(
      maxMemorySizeMb = 100,
      maxDiskSizeMb = 1000,
      defaultTtlSeconds = 3600,
      compressionEnabled = true,
      compressionLevel = clDefault,
      cacheDir = "test_cache",
      partitionByDomain = true,
      validateCacheOnStart = true,
      logLevel = llInfo
    )
    var manager = newHttpCacheManager(config)
    
    # テスト用のエントリを作成
    var entry = CacheEntry(
      url: "https://example.com/",
      method: "GET",
      statusCode: 200,
      headers: {
        "Cache-Control": "max-age=3600", 
        "ETag": "\"33a64df551425fcc55e4d42aab7957529b243b9b\"",
        "Content-Type": "text/html"
      }.toTable,
      body: "<!DOCTYPE html><html><head><title>Test Page</title></head><body><h1>Hello, World!</h1>" & "<p>This is a test page.</p>".repeat(100) & "</body></html>",
      timestamp: getTime(),
      expires: getTime() + initDuration(hours = 1),
      lastModified: "Wed, 21 Oct 2015 07:28:00 GMT",
      etag: "\"33a64df551425fcc55e4d42aab7957529b243b9b\"",
      varyHeaders: initTable[string, string](),
      isCompressed: false
    )
    
    # エントリをキャッシュに保存（圧縮あり）
    manager.put(entry, "gzip, deflate")
    
    # 圧縮が行われたか確認
    if entry.isCompressed:
      echo "エントリが圧縮されました"
      echo "圧縮タイプ: ", entry.headers["Content-Encoding"]
      echo "圧縮前のサイズ: ", "<!DOCTYPE html><html><head><title>Test Page</title></head><body><h1>Hello, World!</h1>" & "<p>This is a test page.</p>".repeat(100) & "</body></html>".len
      echo "圧縮後のサイズ: ", entry.body.len
    
    # キャッシュから取得（圧縮をサポートするクライアント）
    let retrievedCompressed = manager.get(entry.url, "GET", {"Accept-Encoding": "gzip, deflate"}.toTable)
    if retrievedCompressed.isSome:
      let (cached, needsRevalidation) = retrievedCompressed.get()
      echo "圧縮をサポートするクライアント - キャッシュから取得: ", cached.url
      echo "圧縮されている: ", cached.isCompressed
      if cached.isCompressed and cached.headers.hasKey("Content-Encoding"):
        echo "エンコーディング: ", cached.headers["Content-Encoding"]
      echo "ボディサイズ: ", cached.body.len
      echo "再検証が必要: ", needsRevalidation
    
    # キャッシュから取得（圧縮をサポートしないクライアント）
    let retrievedUncompressed = manager.get(entry.url)
    if retrievedUncompressed.isSome:
      let (cached, needsRevalidation) = retrievedUncompressed.get()
      echo "圧縮をサポートしないクライアント - キャッシュから取得: ", cached.url
      echo "圧縮されている: ", cached.isCompressed
      echo "ボディサイズ: ", cached.body.len
      echo "再検証が必要: ", needsRevalidation
    
    # 統計情報を表示
    echo manager.getStats()
    
    # キャッシュをクリア
    manager.clear()
    echo "キャッシュをクリアしました"
  
  # テスト実行
  testHttpCacheManager() 