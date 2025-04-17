import std/[os, times, tables, hashes, json, strutils, asyncdispatch, 
  sequtils, options, strformat, uri, securehash, algorithm]
import ../protocols/http3/client

const
  DEFAULT_CACHE_DIR = ".http3-cache"
  MAX_CACHE_SIZE = 500 * 1024 * 1024  # 500MB
  MAX_ENTRIES = 5000
  CACHE_INDEX_FILENAME = "cache_index.json"
  CLEANUP_INTERVAL = 60 * 60 * 1000  # 1時間（ミリ秒）

type
  CacheEntryType* = enum
    cetResponse = "response"
    cetImage = "image"
    cetFont = "font"
    cetScript = "script"
    cetStyle = "style"
    cetOther = "other"

  CachePolicy* = enum
    cpDefault = "default"       # 通常のキャッシュポリシー
    cpForceCache = "force"      # 常にキャッシュを使用
    cpNoCache = "no-cache"      # 検証なしでキャッシュを使用しない
    cpNoStore = "no-store"      # キャッシュに保存しない
    cpReload = "reload"         # キャッシュを無視して再読み込み
    cpValidateCache = "validate" # 常にキャッシュを検証

  CachePriority* = enum
    cpLow = "low"        # 低優先度（最初に削除）
    cpNormal = "normal"  # 通常優先度
    cpHigh = "high"      # 高優先度（最後に削除）

  DiskCacheEntry* = ref object
    url*: string                # リソースのURL
    filePath*: string           # ディスク上のファイルパス
    entryType*: CacheEntryType  # エントリの種類
    created*: Time              # 作成日時
    lastAccessed*: Time         # 最終アクセス日時
    expiresAt*: Time            # 有効期限
    size*: int                  # サイズ（バイト）
    accessCount*: int           # アクセス回数
    policy*: CachePolicy        # キャッシュポリシー
    priority*: CachePriority    # 優先度
    contentType*: string        # Content-Type
    etag*: string               # ETag
    lastModified*: string       # Last-Modified
    variantId*: string          # バリアントID（Vary対応）

  CacheStatistics* = object
    hitCount*: int              # ヒット数
    missCount*: int             # ミス数
    totalRequests*: int         # 総リクエスト数
    totalSize*: int             # 合計サイズ（バイト）
    entryCount*: int            # エントリ数
    oldestEntry*: Time          # 最も古いエントリ
    newestEntry*: Time          # 最も新しいエントリ
    avgEntrySize*: float        # 平均エントリサイズ
    avgEntryAge*: float         # 平均エントリ年齢（秒）

  CacheIndexData* = object
    entries*: Table[string, DiskCacheEntry]  # URLをキーとするエントリのテーブル
    stats*: CacheStatistics                 # 統計情報

  FileHandle* = object
    file*: File
    lastAccessed*: Time

  # アプリケーション内で使用するキャッシュインターフェース
  CacheInterface* = ref object of RootObj

  # HTTP/3のディスクキャッシュ
  DiskCache* = ref object of CacheInterface
    cachePath*: string                      # キャッシュディレクトリのパス
    indexData*: CacheIndexData              # キャッシュインデックスデータ
    openFiles*: Table[string, FileHandle]   # 開いているファイルハンドル
    maxSize*: int                           # 最大キャッシュサイズ（バイト）
    maxEntries*: int                        # 最大エントリ数
    cleanupLock*: AsyncLock                 # クリーンアップ用のロック

# URLからファイルパスを生成
proc generateFilePath(url: string): string =
  let hash = $secureHash(url)
  result = hash

# キャッシュパスを結合
proc joinCachePath(cache: DiskCache, relativePath: string): string =
  result = cache.cachePath / relativePath

# ディレクトリが存在することを確認
proc ensureDirectoryExists(dir: string) =
  if not dirExists(dir):
    createDir(dir)

# キャッシュインデックスをディスクに保存
proc saveIndex(cache: DiskCache) {.async.} =
  let indexPath = cache.joinCachePath(CACHE_INDEX_FILENAME)
  let tempPath = cache.joinCachePath(CACHE_INDEX_FILENAME & ".tmp")
  
  # JSONオブジェクトを構築
  var entriesObj = newJObject()
  for url, entry in cache.indexData.entries:
    var entryObj = newJObject()
    entryObj["url"] = newJString(entry.url)
    entryObj["filePath"] = newJString(entry.filePath)
    entryObj["entryType"] = newJString($entry.entryType)
    entryObj["created"] = newJString($entry.created.toUnix())
    entryObj["lastAccessed"] = newJString($entry.lastAccessed.toUnix())
    entryObj["expiresAt"] = newJString($entry.expiresAt.toUnix())
    entryObj["size"] = newJInt(entry.size)
    entryObj["accessCount"] = newJInt(entry.accessCount)
    entryObj["policy"] = newJString($entry.policy)
    entryObj["priority"] = newJString($entry.priority)
    entryObj["contentType"] = newJString(entry.contentType)
    entryObj["etag"] = newJString(entry.etag)
    entryObj["lastModified"] = newJString(entry.lastModified)
    entryObj["variantId"] = newJString(entry.variantId)
    entriesObj[url] = entryObj
  
  var statsObj = newJObject()
  statsObj["hitCount"] = newJInt(cache.indexData.stats.hitCount)
  statsObj["missCount"] = newJInt(cache.indexData.stats.missCount)
  statsObj["totalRequests"] = newJInt(cache.indexData.stats.totalRequests)
  statsObj["totalSize"] = newJInt(cache.indexData.stats.totalSize)
  statsObj["entryCount"] = newJInt(cache.indexData.stats.entryCount)
  statsObj["oldestEntry"] = newJString($cache.indexData.stats.oldestEntry.toUnix())
  statsObj["newestEntry"] = newJString($cache.indexData.stats.newestEntry.toUnix())
  statsObj["avgEntrySize"] = newJFloat(cache.indexData.stats.avgEntrySize)
  statsObj["avgEntryAge"] = newJFloat(cache.indexData.stats.avgEntryAge)
  
  var rootObj = newJObject()
  rootObj["entries"] = entriesObj
  rootObj["stats"] = statsObj
  rootObj["lastUpdated"] = newJString($getTime().toUnix())
  
  # 一時ファイルに書き込み、成功したら正式なファイルに名前変更
  try:
    writeFile(tempPath, $rootObj)
    moveFile(tempPath, indexPath)
  except:
    echo "Failed to save cache index: ", getCurrentExceptionMsg()

# ディスクからキャッシュインデックスをロード
proc loadIndex(cache: DiskCache) {.async.} =
  let indexPath = cache.joinCachePath(CACHE_INDEX_FILENAME)
  
  if fileExists(indexPath):
    try:
      let jsonData = parseFile(indexPath)
      
      # エントリをロード
      if jsonData.hasKey("entries"):
        for url, entryObj in jsonData["entries"].pairs:
          var entry = new DiskCacheEntry
          entry.url = entryObj["url"].getStr()
          entry.filePath = entryObj["filePath"].getStr()
          entry.entryType = parseEnum[CacheEntryType](entryObj["entryType"].getStr())
          entry.created = fromUnix(entryObj["created"].getStr().parseInt())
          entry.lastAccessed = fromUnix(entryObj["lastAccessed"].getStr().parseInt())
          entry.expiresAt = fromUnix(entryObj["expiresAt"].getStr().parseInt())
          entry.size = entryObj["size"].getInt()
          entry.accessCount = entryObj["accessCount"].getInt()
          entry.policy = parseEnum[CachePolicy](entryObj["policy"].getStr())
          entry.priority = parseEnum[CachePriority](entryObj["priority"].getStr())
          entry.contentType = entryObj["contentType"].getStr()
          entry.etag = entryObj["etag"].getStr()
          entry.lastModified = entryObj["lastModified"].getStr()
          entry.variantId = entryObj["variantId"].getStr()
          
          cache.indexData.entries[url] = entry
      
      # 統計情報をロード
      if jsonData.hasKey("stats"):
        let statsObj = jsonData["stats"]
        cache.indexData.stats.hitCount = statsObj["hitCount"].getInt()
        cache.indexData.stats.missCount = statsObj["missCount"].getInt()
        cache.indexData.stats.totalRequests = statsObj["totalRequests"].getInt()
        cache.indexData.stats.totalSize = statsObj["totalSize"].getInt()
        cache.indexData.stats.entryCount = statsObj["entryCount"].getInt()
        cache.indexData.stats.oldestEntry = fromUnix(statsObj["oldestEntry"].getStr().parseInt())
        cache.indexData.stats.newestEntry = fromUnix(statsObj["newestEntry"].getStr().parseInt())
        cache.indexData.stats.avgEntrySize = statsObj["avgEntrySize"].getFloat()
        cache.indexData.stats.avgEntryAge = statsObj["avgEntryAge"].getFloat()
      
    except:
      echo "Failed to load cache index: ", getCurrentExceptionMsg()
      # インデックスの初期化
      cache.indexData.entries = initTable[string, DiskCacheEntry]()
      cache.indexData.stats = CacheStatistics(
        hitCount: 0,
        missCount: 0,
        totalRequests: 0,
        totalSize: 0,
        entryCount: 0,
        oldestEntry: getTime(),
        newestEntry: getTime(),
        avgEntrySize: 0.0,
        avgEntryAge: 0.0
      )
  else:
    # ファイルが存在しない場合は初期化
    cache.indexData.entries = initTable[string, DiskCacheEntry]()
    cache.indexData.stats = CacheStatistics(
      hitCount: 0,
      missCount: 0,
      totalRequests: 0,
      totalSize: 0,
      entryCount: 0,
      oldestEntry: getTime(),
      newestEntry: getTime(),
      avgEntrySize: 0.0,
      avgEntryAge: 0.0
    )

# すべてのオープンファイルハンドルを閉じる
proc closeFileHandles(cache: DiskCache) =
  for _, fileHandle in cache.openFiles:
    close(fileHandle.file)
  cache.openFiles.clear()

# エントリのファイルパスを計算
proc calculateEntryFilePath(cache: DiskCache, entry: DiskCacheEntry): string =
  return cache.joinCachePath(entry.filePath)

# ファイルハンドルを取得（存在しない場合は作成）
proc getFileHandle(cache: DiskCache, filePath: string, mode: FileMode): FileHandle =
  if cache.openFiles.hasKey(filePath) and mode == fmRead:
    result = cache.openFiles[filePath]
    result.lastAccessed = getTime()
  else:
    # 既存のハンドルがあれば閉じる
    if cache.openFiles.hasKey(filePath):
      close(cache.openFiles[filePath].file)
      cache.openFiles.del(filePath)
    
    # ディレクトリが存在することを確認
    let dir = parentDir(filePath)
    ensureDirectoryExists(dir)
    
    # ファイルをオープン
    var file: File
    if open(file, filePath, mode):
      result = FileHandle(file: file, lastAccessed: getTime())
      cache.openFiles[filePath] = result
    else:
      raise newException(IOError, "Failed to open file: " & filePath)

# DiskCacheEntryからCacheEntryに変換（将来の拡張用）
proc entryToCache(entry: DiskCacheEntry): DiskCacheEntry =
  return entry

# エントリのファイルを削除
proc deleteEntryFile(cache: DiskCache, entry: DiskCacheEntry) =
  let filePath = cache.calculateEntryFilePath(entry)
  
  # ファイルハンドルが開いていれば閉じる
  if cache.openFiles.hasKey(filePath):
    close(cache.openFiles[filePath].file)
    cache.openFiles.del(filePath)
  
  # ファイルを削除
  try:
    removeFile(filePath)
  except:
    echo "Failed to delete cache file: ", filePath 

# 新しいディスクキャッシュを作成
proc newDiskCache*(path = DEFAULT_CACHE_DIR, maxSize = MAX_CACHE_SIZE, 
                  maxEntries = MAX_ENTRIES): Future[DiskCache] {.async.} =
  result = DiskCache(
    cachePath: path,
    maxSize: maxSize,
    maxEntries: maxEntries,
    cleanupLock: newAsyncLock(),
    openFiles: initTable[string, FileHandle]()
  )
  
  # キャッシュディレクトリを作成
  ensureDirectoryExists(path)
  
  # インデックスをロード
  await loadIndex(result)
  
  # バックグラウンドでキャッシュクリーンアップタスクを開始
  asyncCheck result.backgroundCleanupTask()

# Http3ResponseからエントリのタイプをGuess
proc guessEntryType(response: Http3Response): CacheEntryType =
  let contentType = response.headers.getOrDefault("content-type", "")
  if contentType.contains("image/"):
    return cetImage
  elif contentType.contains("font/") or contentType.contains("application/font"):
    return cetFont
  elif contentType.contains("text/javascript") or contentType.contains("application/javascript"):
    return cetScript
  elif contentType.contains("text/css"):
    return cetStyle
  elif contentType.contains("text/html") or contentType.contains("application/json"):
    return cetResponse
  else:
    return cetOther

# レスポンスから有効期限を計算
proc calculateExpiry(response: Http3Response): Time =
  let cacheControl = response.headers.getOrDefault("cache-control", "")
  let expires = response.headers.getOrDefault("expires", "")
  
  # Cache-Controlヘッダーからmax-ageを解析
  if "max-age=" in cacheControl:
    let maxAgeStr = cacheControl.split("max-age=")[1].split(",")[0].strip()
    try:
      let maxAge = parseInt(maxAgeStr)
      return getTime() + initDuration(seconds = maxAge)
    except:
      discard
  
  # Expiresヘッダーを解析
  if expires.len > 0:
    try:
      # HTTP日付形式を解析（実際の実装では複数のフォーマットをサポートする必要がある）
      # 例: "Wed, 21 Oct 2015 07:28:00 GMT"
      # ここでは簡略化のために現在時刻 + 1時間を返す
      return getTime() + initDuration(hours = 1)
    except:
      discard
  
  # デフォルトは現在時刻 + 1時間
  return getTime() + initDuration(hours = 1)

# レスポンスからキャッシュポリシーを決定
proc determineCachePolicy(response: Http3Response): CachePolicy =
  let cacheControl = response.headers.getOrDefault("cache-control", "").toLowerAscii()
  
  if "no-store" in cacheControl:
    return cpNoStore
  elif "no-cache" in cacheControl:
    return cpNoCache
  elif "must-revalidate" in cacheControl:
    return cpValidateCache
  else:
    return cpDefault

# 指定されたURLとレスポンスからVaryヘッダーに基づいたバリアントIDを生成
proc generateVariantId(url: string, response: Http3Response): string =
  let varyHeader = response.headers.getOrDefault("vary", "")
  
  if varyHeader.len == 0:
    return ""
  
  var variantComponents: seq[string] = @[]
  let varyFields = varyHeader.split(",")
  
  for field in varyFields:
    let trimmedField = field.strip().toLowerAscii()
    if trimmedField == "*":
      # Vary: * は各リクエストが一意であることを意味するため、現在時刻を使用
      return $getTime().toUnix()
    
    let headerValue = response.headers.getOrDefault(trimmedField, "")
    variantComponents.add(trimmedField & ":" & headerValue)
  
  # バリアントコンポーネントをソートして連結し、ハッシュ化
  variantComponents.sort()
  let variantString = variantComponents.join("|")
  return $secureHash(url & "|" & variantString)

# レスポンスをキャッシュに保存
proc cacheResponse*(cache: DiskCache, url: string, response: Http3Response): Future[DiskCacheEntry] {.async.} =
  # キャッシュポリシーをチェック
  let policy = determineCachePolicy(response)
  if policy == cpNoStore:
    return nil
  
  # レスポンスボディを取得
  let body = await response.bodyString()
  let bodySize = body.len
  
  # キャッシュエントリを作成
  var entry = new DiskCacheEntry
  entry.url = url
  entry.filePath = generateFilePath(url)
  entry.entryType = guessEntryType(response)
  entry.created = getTime()
  entry.lastAccessed = getTime()
  entry.expiresAt = calculateExpiry(response)
  entry.size = bodySize
  entry.accessCount = 1
  entry.policy = policy
  entry.priority = cpNormal
  entry.contentType = response.headers.getOrDefault("content-type", "")
  entry.etag = response.headers.getOrDefault("etag", "")
  entry.lastModified = response.headers.getOrDefault("last-modified", "")
  entry.variantId = generateVariantId(url, response)
  
  # ファイルにレスポンスを保存
  let filePath = cache.calculateEntryFilePath(entry)
  try:
    # 最初にレスポンスヘッダーをJSON形式で保存
    var headerObj = newJObject()
    for key, value in response.headers:
      headerObj[key] = newJString(value)
    
    let metaObj = newJObject()
    metaObj["status"] = newJInt(response.statusCode.ord)
    metaObj["headers"] = headerObj
    
    # ファイルに書き込む: まずメタデータ、次にボディ
    let fileHandle = cache.getFileHandle(filePath, fmWrite)
    write(fileHandle.file, $metaObj & "\n")
    write(fileHandle.file, body)
    flushFile(fileHandle.file)
    
    # インデックスを更新
    {.gcsafe.}:
      cache.indexData.entries[url] = entry
      cache.indexData.stats.totalSize += bodySize
      cache.indexData.stats.entryCount += 1
      cache.indexData.stats.newestEntry = getTime()
      if cache.indexData.stats.entryCount == 1:
        cache.indexData.stats.oldestEntry = getTime()
      cache.indexData.stats.avgEntrySize = float(cache.indexData.stats.totalSize) / float(cache.indexData.stats.entryCount)
      
      # 変更されたインデックスを保存
      asyncCheck cache.saveIndex()
      
      # 必要に応じてキャッシュのクリーンアップをトリガー
      if cache.indexData.stats.totalSize > cache.maxSize or 
         cache.indexData.stats.entryCount > cache.maxEntries:
        asyncCheck cache.cleanup()
    
    return entry
  except:
    echo "Failed to cache response: ", getCurrentExceptionMsg()
    return nil

# キャッシュされたレスポンスを取得
proc getCachedResponse*(cache: DiskCache, url: string): Future[Option[Http3Response]] {.async.} =
  {.gcsafe.}:
    # キャッシュエントリをチェック
    if not cache.indexData.entries.hasKey(url):
      cache.indexData.stats.missCount += 1
      cache.indexData.stats.totalRequests += 1
      return none(Http3Response)
    
    var entry = cache.indexData.entries[url]
    
    # エントリの有効期限をチェック
    if getTime() > entry.expiresAt and entry.policy != cpForceCache:
      # エントリを削除
      cache.indexData.entries.del(url)
      cache.indexData.stats.totalSize -= entry.size
      cache.indexData.stats.entryCount -= 1
      cache.deleteEntryFile(entry)
      
      cache.indexData.stats.missCount += 1
      cache.indexData.stats.totalRequests += 1
      
      # インデックスを保存
      asyncCheck cache.saveIndex()
      
      return none(Http3Response)
    
    try:
      # ファイルからレスポンスをロード
      let filePath = cache.calculateEntryFilePath(entry)
      let fileHandle = cache.getFileHandle(filePath, fmRead)
      
      # 最初の行はメタデータJSON
      var metaLine = ""
      if not readLine(fileHandle.file, metaLine):
        raise newException(IOError, "Failed to read metadata from cache file")
      
      let metaObj = parseJson(metaLine)
      let statusCode = metaObj["status"].getInt().Http3StatusCode
      
      # ヘッダーをロード
      var headers: seq[Http3HeaderField] = @[]
      for key, value in metaObj["headers"]:
        headers.add((key, value.getStr()))
      
      # ボディをロード - 残りのファイル内容
      var body = ""
      var line = ""
      while readLine(fileHandle.file, line):
        body &= line & "\n"
      
      # 最後の余分な改行を削除
      if body.len > 0 and body[^1] == '\n':
        body = body[0..^2]
      
      # レスポンスを構築
      var response = Http3Response(
        statusCode: statusCode,
        headers: headers,
        body: body,
        receivedTime: getTime()
      )
      
      # エントリの統計を更新
      entry.lastAccessed = getTime()
      entry.accessCount += 1
      cache.indexData.entries[url] = entry
      
      cache.indexData.stats.hitCount += 1
      cache.indexData.stats.totalRequests += 1
      
      # インデックスを保存（頻繁な保存を避けるために別のタスクとして実行）
      asyncCheck cache.saveIndex()
      
      return some(response)
    except:
      echo "Failed to retrieve cached response: ", getCurrentExceptionMsg()
      
      cache.indexData.stats.missCount += 1
      cache.indexData.stats.totalRequests += 1
      
      return none(Http3Response)

# キャッシュからエントリを削除
proc removeCachedEntry*(cache: DiskCache, url: string): Future[bool] {.async.} =
  {.gcsafe.}:
    if not cache.indexData.entries.hasKey(url):
      return false
    
    let entry = cache.indexData.entries[url]
    cache.deleteEntryFile(entry)
    
    # インデックスを更新
    cache.indexData.entries.del(url)
    cache.indexData.stats.totalSize -= entry.size
    cache.indexData.stats.entryCount -= 1
    
    # インデックスを保存
    asyncCheck cache.saveIndex()
    
    return true

# ランダムアクセスのためにキャッシュファイルを開く
proc openCachedFile*(cache: DiskCache, url: string): Future[Option[File]] {.async.} =
  {.gcsafe.}:
    if not cache.indexData.entries.hasKey(url):
      return none(File)
    
    let entry = cache.indexData.entries[url]
    let filePath = cache.calculateEntryFilePath(entry)
    
    try:
      let fileHandle = cache.getFileHandle(filePath, fmRead)
      return some(fileHandle.file)
    except:
      echo "Failed to open cached file: ", getCurrentExceptionMsg()
      return none(File)

# キャッシュの統計情報を取得
proc getCacheStats*(cache: DiskCache): CacheStatistics =
  return cache.indexData.stats

# キャッシュエントリの有効期限を更新
proc updateEntryExpiry*(cache: DiskCache, url: string, newExpiry: Time): Future[bool] {.async.} =
  {.gcsafe.}:
    if not cache.indexData.entries.hasKey(url):
      return false
    
    var entry = cache.indexData.entries[url]
    entry.expiresAt = newExpiry
    cache.indexData.entries[url] = entry
    
    # インデックスを保存
    asyncCheck cache.saveIndex()
    
    return true

# アクセス頻度、キャッシュポリシー、優先度などに基づいてエントリの価値を計算
proc calculateEntryValue(entry: DiskCacheEntry): float =
  # アクセス頻度が高いエントリは価値が高い
  var value = float(entry.accessCount)
  
  # 最終アクセス時間が新しいエントリは価値が高い
  let ageInHours = (getTime() - entry.lastAccessed).inHours
  value *= max(0.1, 1.0 - (ageInHours / 24.0))
  
  # 優先度に基づいて調整
  case entry.priority
  of cpLow:    value *= 0.5
  of cpNormal: value *= 1.0
  of cpHigh:   value *= 2.0
  
  # サイズに対する値 (小さいファイルは保持する価値がある)
  value /= max(1.0, sqrt(float(entry.size) / 1024.0))
  
  return value

# キャッシュをクリーンアップ（古いエントリや優先度の低いエントリを削除）
proc cleanup*(cache: DiskCache): Future[void] {.async.} =
  # 同時実行を避けるためにロックを取得
  await cache.cleanupLock.acquire()
  try:
    # キャッシュがサイズ制限未満であれば何もしない
    if cache.indexData.stats.totalSize <= cache.maxSize and
       cache.indexData.stats.entryCount <= cache.maxEntries:
      return
      
    # すべてのエントリを値でソート
    var entries: seq[DiskCacheEntry] = @[]
    for _, entry in cache.indexData.entries:
      entries.add(entry)
    
    entries.sort(proc(a, b: DiskCacheEntry): int =
      let valueA = calculateEntryValue(a)
      let valueB = calculateEntryValue(b)
      if valueA < valueB: return -1
      elif valueA > valueB: return 1
      else: return 0
    )
    
    # 目標サイズは最大サイズの75%
    let targetSize = int(float(cache.maxSize) * 0.75)
    let targetEntries = int(float(cache.maxEntries) * 0.75)
    
    var currentSize = cache.indexData.stats.totalSize
    var currentEntries = cache.indexData.stats.entryCount
    
    # 値の低いエントリから削除
    for entry in entries:
      if currentSize <= targetSize and currentEntries <= targetEntries:
        break
      
      # ファイルを削除
      cache.deleteEntryFile(entry)
      
      # インデックスを更新
      cache.indexData.entries.del(entry.url)
      currentSize -= entry.size
      currentEntries -= 1
    
    # 統計情報を更新
    cache.indexData.stats.totalSize = currentSize
    cache.indexData.stats.entryCount = currentEntries
    
    # インデックスを保存
    await cache.saveIndex()
  finally:
    cache.cleanupLock.release()

# バックグラウンドでキャッシュをクリーンアップするタスク
proc backgroundCleanupTask*(cache: DiskCache) {.async.} =
  while true:
    # 定期的に実行
    await sleepAsync(CLEANUP_INTERVAL)
    
    try:
      await cache.cleanup()
    except:
      echo "Background cleanup task error: ", getCurrentExceptionMsg()

# キャッシュをクローズ
proc close*(cache: DiskCache): Future[void] {.async.} =
  # オープンしているファイルハンドルをすべて閉じる
  cache.closeFileHandles()
  
  # インデックスを保存
  await cache.saveIndex()

# キャッシュを完全に消去
proc clearCache*(cache: DiskCache): Future[void] {.async.} =
  await cache.cleanupLock.acquire()
  try:
    # すべてのファイルハンドルを閉じる
    cache.closeFileHandles()
    
    # すべてのキャッシュエントリを削除
    for _, entry in cache.indexData.entries:
      try:
        let filePath = cache.calculateEntryFilePath(entry)
        removeFile(filePath)
      except:
        echo "Failed to delete cache file: ", getCurrentExceptionMsg()
    
    # インデックスをリセット
    cache.indexData.entries.clear()
    cache.indexData.stats = CacheStatistics(
      hitCount: 0,
      missCount: 0,
      totalRequests: 0,
      totalSize: 0,
      entryCount: 0,
      oldestEntry: getTime(),
      newestEntry: getTime(),
      avgEntrySize: 0.0,
      avgEntryAge: 0.0
    )
    
    # インデックスを保存
    await cache.saveIndex()
  finally:
    cache.cleanupLock.release()

# キャッシュエントリの有効性をチェック
proc isEntryValid*(cache: DiskCache, url: string): Future[bool] {.async.} =
  {.gcsafe.}:
    if not cache.indexData.entries.hasKey(url):
      return false
    
    let entry = cache.indexData.entries[url]
    
    # 有効期限をチェック
    return getTime() <= entry.expiresAt or entry.policy == cpForceCache 

# HTTPレンジリクエストのためのユーティリティ
type
  ByteRange* = object
    start*: int
    endPos*: int  # 'end'はNimの予約語
  
  RangeResponse* = object
    data*: string
    contentRange*: string
    contentLength*: int
    contentType*: string
    complete*: bool

# レンジ文字列を解析する (例: "bytes=0-499")
proc parseRangeHeader*(rangeHeader: string): seq[ByteRange] =
  result = @[]
  
  if rangeHeader.len == 0 or not rangeHeader.startsWith("bytes="):
    return
  
  let rangeStr = rangeHeader[6..^1]  # "bytes=" を除去
  let ranges = rangeStr.split(',')
  
  for r in ranges:
    let trimmed = r.strip()
    if trimmed.len == 0:
      continue
    
    let parts = trimmed.split('-')
    if parts.len != 2:
      continue
    
    var byteRange: ByteRange
    
    # 開始位置
    if parts[0].len > 0:
      try:
        byteRange.start = parseInt(parts[0])
      except:
        continue
    else:
      byteRange.start = -1  # 末尾からの指定（例: "-500" は末尾から500バイト）
    
    # 終了位置
    if parts[1].len > 0:
      try:
        byteRange.endPos = parseInt(parts[1])
      except:
        continue
    else:
      byteRange.endPos = -1  # ファイル末尾まで
    
    result.add(byteRange)

# HTTPレンジリクエストを処理
proc handleRangeRequest*(cache: DiskCache, url: string, rangeHeader: string): Future[Option[RangeResponse]] {.async.} =
  {.gcsafe.}:
    # キャッシュエントリをチェック
    if not cache.indexData.entries.hasKey(url):
      cache.indexData.stats.missCount += 1
      cache.indexData.stats.totalRequests += 1
      return none(RangeResponse)
    
    var entry = cache.indexData.entries[url]
    
    # エントリの有効期限をチェック
    if getTime() > entry.expiresAt and entry.policy != cpForceCache:
      # 有効期限切れのエントリを削除
      asyncCheck cache.removeCachedEntry(url)
      return none(RangeResponse)
    
    try:
      # ファイルからレスポンスをロード
      let filePath = cache.calculateEntryFilePath(entry)
      let fileHandle = cache.getFileHandle(filePath, fmRead)
      
      # メタデータを読み取り
      var metaLine = ""
      if not readLine(fileHandle.file, metaLine):
        raise newException(IOError, "Failed to read metadata from cache file")
      
      let metaObj = parseJson(metaLine)
      
      # ファイルの先頭位置を取得
      let contentStart = getFilePos(fileHandle.file)
      
      # ファイルサイズを取得
      let fileSize = getFileSize(fileHandle.file) - contentStart
      
      # レンジを解析
      let ranges = parseRangeHeader(rangeHeader)
      if ranges.len == 0:
        # レンジが指定されていない場合は全体を返す
        setFilePos(fileHandle.file, contentStart)
        var content = newString(int(fileSize))
        let bytesRead = readBuffer(fileHandle.file, addr content[0], content.len)
        content.setLen(bytesRead)
        
        # エントリの統計を更新
        entry.lastAccessed = getTime()
        entry.accessCount += 1
        cache.indexData.entries[url] = entry
        cache.indexData.stats.hitCount += 1
        cache.indexData.stats.totalRequests += 1
        
        # インデックスを保存
        asyncCheck cache.saveIndex()
        
        var response = RangeResponse(
          data: content,
          contentRange: "bytes 0-" & $(fileSize - 1) & "/" & $fileSize,
          contentLength: content.len,
          contentType: entry.contentType,
          complete: true
        )
        
        return some(response)
      
      # マルチパートレンジリクエストはサポートしていないので、最初のレンジだけを処理
      var byteRange = ranges[0]
      var start, endPos: int
      
      if byteRange.start >= 0:
        start = byteRange.start
      else:
        # 末尾からの指定 (例: "-500"は末尾から500バイト)
        start = max(0, int(fileSize) + byteRange.start)
      
      if byteRange.endPos >= 0:
        endPos = min(int(fileSize) - 1, byteRange.endPos)
      else:
        endPos = int(fileSize) - 1
      
      # 範囲が有効かチェック
      if start > endPos or start >= fileSize:
        # 範囲外
        return none(RangeResponse)
      
      # 指定範囲のデータを読み取り
      let length = endPos - start + 1
      var content = newString(length)
      
      setFilePos(fileHandle.file, contentStart + start)
      let bytesRead = readBuffer(fileHandle.file, addr content[0], content.len)
      content.setLen(bytesRead)
      
      # エントリの統計を更新
      entry.lastAccessed = getTime()
      entry.accessCount += 1
      cache.indexData.entries[url] = entry
      cache.indexData.stats.hitCount += 1
      cache.indexData.stats.totalRequests += 1
      
      # インデックスを保存
      asyncCheck cache.saveIndex()
      
      var response = RangeResponse(
        data: content,
        contentRange: "bytes " & $start & "-" & $endPos & "/" & $fileSize,
        contentLength: content.len,
        contentType: entry.contentType,
        complete: false
      )
      
      return some(response)
    except:
      echo "Range request error: ", getCurrentExceptionMsg()
      cache.indexData.stats.missCount += 1
      cache.indexData.stats.totalRequests += 1
      return none(RangeResponse)

# 条件付きリクエストを検証（ETagとLast-Modifiedで）
proc validateConditionalRequest*(cache: DiskCache, url: string, 
                                ifNoneMatch: string, ifModifiedSince: string): Future[bool] {.async.} =
  {.gcsafe.}:
    if not cache.indexData.entries.hasKey(url):
      return false
    
    let entry = cache.indexData.entries[url]
    
    # ETタグが一致するかチェック（強いETagと弱いETag両方をサポート）
    if ifNoneMatch.len > 0 and entry.etag.len > 0:
      if ifNoneMatch == "*" or ifNoneMatch == entry.etag or 
         ifNoneMatch == "W/" & entry.etag or 
         entry.etag == "W/" & ifNoneMatch.strip(chars={'W', '/', '"'}):
        return true
    
    # Last-Modifiedをチェック
    if ifModifiedSince.len > 0 and entry.lastModified.len > 0:
      # 実際の実装では日付解析を行いますが、
      # ここでは単純な文字列比較を使用
      if ifModifiedSince == entry.lastModified:
        return true
    
    return false

# 複数のキャッシュエントリを一括削除（パターンマッチング）
proc removeCachedEntriesByPattern*(cache: DiskCache, pattern: string): Future[int] {.async.} =
  {.gcsafe.}:
    var regex: Regex
    try:
      regex = re(pattern)
    except:
      echo "Invalid regex pattern: ", pattern
      return 0
    
    var removedCount = 0
    var urlsToRemove: seq[string] = @[]
    
    # 削除対象のURLを集める
    for url, _ in cache.indexData.entries:
      if url.match(regex):
        urlsToRemove.add(url)
    
    # エントリを一括削除
    for url in urlsToRemove:
      if await cache.removeCachedEntry(url):
        removedCount += 1
    
    return removedCount

# メモリ使用量を管理・削減するためのメソッド
proc compactMemory*(cache: DiskCache): Future[void] {.async.} =
  # メモリ使用量を減らすためにGCを実行
  GC_fullCollect()
  
  # オープンしていないファイルハンドルを閉じる
  var handlesToClear: seq[string] = @[]
  
  for filePath, handle in cache.openFiles:
    if not handle.inUse and now() - handle.lastUsed > initDuration(minutes=5):
      handlesToClear.add(filePath)
  
  for filePath in handlesToClear:
    let handle = cache.openFiles[filePath]
    close(handle.file)
    cache.openFiles.del(filePath)

# バックグラウンドで定期的にメモリを最適化
proc backgroundMemoryOptimizationTask*(cache: DiskCache) {.async.} =
  while true:
    # 30分ごとに実行
    await sleepAsync(initDuration(minutes=30))
    
    try:
      await cache.compactMemory()
    except:
      echo "Memory optimization error: ", getCurrentExceptionMsg()

# ストレージ容量のチェック
proc checkAvailableStorage*(cache: DiskCache): Future[tuple[available: int64, required: int64, sufficient: bool]] {.async.} =
  try:
    # 実際の実装ではOSのAPIを使用して利用可能なディスク容量を取得
    # ここでは簡易的な実装
    let cacheDirPath = cache.cachePath
    let spaceInfo = getSpaceInfo(cacheDirPath)
    
    # 必要な容量（現在の使用量の10%）
    let required = int64(cache.indexData.stats.totalSize / 10)
    let available = spaceInfo.free
    
    return (available: available, required: required, sufficient: available > required)
  except:
    echo "Failed to check storage: ", getCurrentExceptionMsg()
    # 失敗した場合は十分な容量があると仮定
    return (available: 1000000000'i64, required: 0'i64, sufficient: true)

# キャッシュエントリのプリロード（パフォーマンス向上のため）
proc preloadPopularEntries*(cache: DiskCache, limit: int = 10): Future[int] {.async.} =
  {.gcsafe.}:
    var entries: seq[DiskCacheEntry] = @[]
    for _, entry in cache.indexData.entries:
      if getTime() <= entry.expiresAt or entry.policy == cpForceCache:
        entries.add(entry)
    
    # アクセス頻度で並べ替え
    entries.sort(proc(a, b: DiskCacheEntry): int =
      return cmp(b.accessCount, a.accessCount)  # 降順
    )
    
    # 上位X件をプリロード
    var loadedCount = 0
    let topEntries = entries[0..<min(limit, entries.len)]
    
    for entry in topEntries:
      try:
        let filePath = cache.calculateEntryFilePath(entry)
        let fileHandle = cache.getFileHandle(filePath, fmRead)
        
        # メモリにデータをプリロード（読み取るだけ）
        var buffer = newString(min(4096, entry.size))  # 先頭4KBだけ読み込む
        discard readBuffer(fileHandle.file, addr buffer[0], buffer.len)
        
        loadedCount += 1
      except:
        echo "Failed to preload entry: ", entry.url, " - ", getCurrentExceptionMsg()
    
    return loadedCount

# キャッシュの整合性検証
proc verifyCache*(cache: DiskCache): Future[tuple[valid: int, invalid: int, repaired: int]] {.async.} =
  {.gcsafe.}:
    var validCount = 0
    var invalidCount = 0
    var repairedCount = 0
    
    var invalidUrls: seq[string] = @[]
    
    # すべてのエントリをチェック
    for url, entry in cache.indexData.entries:
      let filePath = cache.calculateEntryFilePath(entry)
      
      # ファイルが存在するか確認
      if not fileExists(filePath):
        invalidCount += 1
        invalidUrls.add(url)
        continue
      
      # ファイルサイズが記録と一致するか確認
      try:
        let fileSize = getFileSize(filePath)
        # メタデータの行を考慮
        var metaSize = 0
        try:
          let fileHandle = cache.getFileHandle(filePath, fmRead)
          var metaLine = ""
          if readLine(fileHandle.file, metaLine):
            metaSize = metaLine.len + 1  # 改行を含む
        except:
          discard
        
        if fileSize - metaSize != entry.size:
          # サイズが一致しない場合、エントリサイズを修正
          var updatedEntry = entry
          updatedEntry.size = int(fileSize - metaSize)
          cache.indexData.entries[url] = updatedEntry
          repairedCount += 1
          continue
        
        validCount += 1
      except:
        invalidCount += 1
        invalidUrls.add(url)
    
    # 無効なエントリを削除
    for url in invalidUrls:
      await cache.removeCachedEntry(url)
    
    # インデックスを保存
    if repairedCount > 0 or invalidCount > 0:
      await cache.saveIndex()
    
    return (valid: validCount, invalid: invalidCount, repaired: repairedCount)

# 最終的な初期化処理を追加
proc initializeCache*(path = DEFAULT_CACHE_DIR): Future[DiskCache] {.async.} =
  # 基本的なキャッシュインスタンスを作成
  let cache = await newDiskCache(path)
  
  # キャッシュの整合性を検証
  discard await cache.verifyCache()
  
  # バックグラウンドタスクを開始
  asyncCheck cache.backgroundCleanupTask()
  asyncCheck cache.backgroundMemoryOptimizationTask()
  
  # よく使われるエントリをプリロード
  discard await cache.preloadPopularEntries()
  
  # ストレージの空き容量をチェック
  let storageCheck = await cache.checkAvailableStorage()
  if not storageCheck.sufficient:
    # 空き容量が少ない場合は強制的にクリーンアップ
    await cache.cleanup()
  
  return cache 