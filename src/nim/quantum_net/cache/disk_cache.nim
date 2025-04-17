## quantum_net/cache/disk_cache.nim
## 
## HTTP/3ディスクキャッシュ実装
## 持続性のあるディスクベースのキャッシュシステム

import std/[
  times,
  options,
  tables,
  hashes,
  strutils,
  uri,
  asyncdispatch,
  os,
  json,
  sha1,
  locks,
  atomics,
  base64,
  streams,
  asyncfile
]

import cache_interface

const
  CACHE_INDEX_FILE = "cache_index.json"
  TEMP_INDEX_FILE = "cache_index.tmp.json"
  MAX_OPEN_FILES = 100          # 同時オープンファイルの最大数
  MAX_FILE_CACHE_SIZE = 4096    # ファイルキャッシュの最大サイズ (KB)
  CLEANUP_INTERVAL = 3600       # クリーンアップ間隔 (秒)
  VERSION = "1.0.0"             # キャッシュバージョン

type
  DiskCacheEntry = object
    ## ディスクキャッシュエントリ
    url: string                 ## URL
    filePath: string            ## ファイルパス
    entryType: CacheEntryType   ## エントリタイプ
    created: int64              ## 作成時間（Unix時間）
    lastAccessed: int64         ## 最終アクセス時間（Unix時間）
    expiresAt: int64            ## 有効期限（Unix時間）
    size: int                   ## サイズ (バイト)
    accessCount: int            ## アクセス回数
    policy: CachePolicy         ## キャッシュポリシー
    priority: CachePriority     ## 優先度
    contentType: string         ## コンテンツタイプ
    etag: string                ## ETag
    lastModified: string        ## 最終更新日時
    variantId: string           ## バリアントID

  CacheIndexData = object
    ## キャッシュインデックスデータ
    entries: Table[string, DiskCacheEntry]  ## URLをキーとするエントリマップ
    stats: CacheStats                       ## 統計情報
    version: string                         ## キャッシュバージョン
    lastCleanup: int64                      ## 最後のクリーンアップ時間

  FileHandle = object
    ## ファイルハンドル
    file: AsyncFile
    lastUsed: Time
    path: string
    isOpen: bool

  DiskCache* = ref object of CacheInterface
    ## ディスクキャッシュ実装
    cachePath: string                  ## キャッシュディレクトリパス
    indexData: CacheIndexData          ## インデックスデータ
    openFiles: Table[string, FileHandle] ## 開いているファイルのキャッシュ
    lock: Lock                         ## スレッドセーフのためのロック
    isInitialized: Atomic[bool]        ## 初期化済みフラグ
    lastSaveTime: Time                 ## 最後のインデックス保存時間
    dirty: bool                        ## インデックスが変更されたフラグ

proc generateFilePath(url: string): string =
  ## URLからファイルパスを生成
  var hash = $secureHash(url)
  # URLエンコードされていない文字のみを使用
  result = hash.replace("/", "_").replace("+", "-").replace("=", "")
  # 階層的なパスを作成 (例: abc/def/abcdef1234...)
  if result.len >= 6:
    result = result[0..2] & "/" & result[3..5] & "/" & result

proc joinCachePath(cache: DiskCache, relativePath: string): string =
  ## キャッシュディレクトリと相対パスを結合
  result = cache.cachePath / relativePath

proc ensureDirectoryExists(path: string): bool =
  ## ディレクトリが存在することを確認し、必要なら作成
  try:
    if not dirExists(path):
      createDir(path)
    return true
  except:
    return false

proc saveIndex(cache: DiskCache): Future[bool] {.async.} =
  ## インデックスをディスクに保存
  acquire(cache.lock)
  defer: release(cache.lock)
  
  if not cache.dirty:
    return true  # 変更がなければ何もしない
  
  let indexPath = cache.joinCachePath(CACHE_INDEX_FILE)
  let tempPath = cache.joinCachePath(TEMP_INDEX_FILE)
  
  try:
    # JSONオブジェクトを作成
    var entriesObj = newJObject()
    for url, entry in cache.indexData.entries:
      var entryObj = newJObject()
      entryObj["url"] = newJString(entry.url)
      entryObj["filePath"] = newJString(entry.filePath)
      entryObj["entryType"] = newJInt(ord(entry.entryType))
      entryObj["created"] = newJInt(entry.created)
      entryObj["lastAccessed"] = newJInt(entry.lastAccessed)
      entryObj["expiresAt"] = newJInt(entry.expiresAt)
      entryObj["size"] = newJInt(entry.size)
      entryObj["accessCount"] = newJInt(entry.accessCount)
      entryObj["policy"] = newJInt(ord(entry.policy))
      entryObj["priority"] = newJInt(ord(entry.priority))
      entryObj["contentType"] = newJString(entry.contentType)
      entryObj["etag"] = newJString(entry.etag)
      entryObj["lastModified"] = newJString(entry.lastModified)
      entryObj["variantId"] = newJString(entry.variantId)
      
      entriesObj[url] = entryObj
    
    # 統計情報
    var statsObj = newJObject()
    statsObj["hits"] = newJInt(cache.stats.hits)
    statsObj["misses"] = newJInt(cache.stats.misses)
    statsObj["entries"] = newJInt(cache.stats.entries)
    statsObj["size"] = newJInt(cache.stats.size)
    statsObj["maxSize"] = newJInt(cache.stats.maxSize)
    statsObj["insertions"] = newJInt(cache.stats.insertions)
    statsObj["evictions"] = newJInt(cache.stats.evictions)
    statsObj["invalidations"] = newJInt(cache.stats.invalidations)
    statsObj["hitRatio"] = newJFloat(cache.stats.hitRatio)
    
    # ルートオブジェクト
    var rootObj = newJObject()
    rootObj["entries"] = entriesObj
    rootObj["stats"] = statsObj
    rootObj["version"] = newJString(VERSION)
    rootObj["lastCleanup"] = newJInt(cache.indexData.lastCleanup)
    
    # 一時ファイルに書き込み
    let jsonStr = $rootObj
    writeFile(tempPath, jsonStr)
    
    # 一時ファイルを本番ファイルに移動
    if fileExists(indexPath):
      removeFile(indexPath)
    moveFile(tempPath, indexPath)
    
    cache.dirty = false
    cache.lastSaveTime = getTime()
    return true
  except:
    return false

proc loadIndex(cache: DiskCache): Future[bool] {.async.} =
  ## インデックスをディスクから読み込み
  acquire(cache.lock)
  defer: release(cache.lock)
  
  let indexPath = cache.joinCachePath(CACHE_INDEX_FILE)
  
  # インデックスファイルが存在しない場合は新規作成
  if not fileExists(indexPath):
    cache.indexData = CacheIndexData(
      entries: initTable[string, DiskCacheEntry](),
      version: VERSION,
      lastCleanup: getTime().toUnix(),
      stats: CacheStats(
        hits: 0,
        misses: 0,
        entries: 0,
        size: 0,
        maxSize: cache.options.maxSize,
        insertions: 0,
        evictions: 0,
        invalidations: 0,
        hitRatio: 0.0
      )
    )
    cache.dirty = true
    return true
  
  try:
    # JSONファイルを読み込み
    let jsonStr = readFile(indexPath)
    let rootObj = parseJson(jsonStr)
    
    # エントリを読み込み
    var entries = initTable[string, DiskCacheEntry]()
    
    if rootObj.hasKey("entries"):
      let entriesObj = rootObj["entries"]
      for url, entryObj in entriesObj:
        var entry = DiskCacheEntry(
          url: entryObj["url"].getStr(),
          filePath: entryObj["filePath"].getStr(),
          entryType: CacheEntryType(entryObj["entryType"].getInt()),
          created: entryObj["created"].getInt(),
          lastAccessed: entryObj["lastAccessed"].getInt(),
          expiresAt: entryObj["expiresAt"].getInt(),
          size: entryObj["size"].getInt(),
          accessCount: entryObj["accessCount"].getInt(),
          policy: CachePolicy(entryObj["policy"].getInt()),
          priority: CachePriority(entryObj["priority"].getInt()),
          contentType: entryObj["contentType"].getStr(),
          etag: entryObj["etag"].getStr(),
          lastModified: entryObj["lastModified"].getStr(),
          variantId: entryObj["variantId"].getStr()
        )
        entries[url] = entry
    
    # 統計情報を読み込み
    var stats = CacheStats()
    
    if rootObj.hasKey("stats"):
      let statsObj = rootObj["stats"]
      stats.hits = statsObj["hits"].getInt()
      stats.misses = statsObj["misses"].getInt()
      stats.entries = statsObj["entries"].getInt()
      stats.size = statsObj["size"].getInt()
      stats.maxSize = statsObj["maxSize"].getInt()
      stats.insertions = statsObj["insertions"].getInt()
      stats.evictions = statsObj["evictions"].getInt()
      stats.invalidations = statsObj["invalidations"].getInt()
      stats.hitRatio = statsObj["hitRatio"].getFloat()
    else:
      stats.maxSize = cache.options.maxSize
    
    # バージョンとクリーンアップ時間を読み込み
    let version = if rootObj.hasKey("version"): rootObj["version"].getStr() else: "1.0.0"
    let lastCleanup = if rootObj.hasKey("lastCleanup"): rootObj["lastCleanup"].getInt() else: 0
    
    # インデックスデータを更新
    cache.indexData = CacheIndexData(
      entries: entries,
      stats: stats,
      version: version,
      lastCleanup: lastCleanup
    )
    
    # 統計情報をキャッシュオブジェクトにコピー
    cache.stats = stats
    
    return true
  except:
    # ファイルが破損している場合は新規作成
    cache.indexData = CacheIndexData(
      entries: initTable[string, DiskCacheEntry](),
      version: VERSION,
      lastCleanup: getTime().toUnix(),
      stats: CacheStats(
        hits: 0,
        misses: 0,
        entries: 0,
        size: 0,
        maxSize: cache.options.maxSize,
        insertions: 0,
        evictions: 0,
        invalidations: 0,
        hitRatio: 0.0
      )
    )
    cache.dirty = true
    return false

proc closeFileHandles(cache: DiskCache) =
  ## 開いているファイルハンドルを閉じる
  for path, handle in cache.openFiles:
    if handle.isOpen:
      try:
        handle.file.close()
      except:
        discard

proc calculateEntryFilePath(cache: DiskCache, url: string): string =
  ## エントリのファイルパスを計算
  let hash = generateFilePath(url)
  let dirPath = cache.joinCachePath(hash.split('/')[0..1].join("/"))
  
  # ディレクトリが存在することを確認
  if not ensureDirectoryExists(dirPath):
    return ""
  
  return cache.joinCachePath(hash)

proc getFileHandle(cache: DiskCache, path: string, mode: FileMode = fmRead): Future[Option[AsyncFile]] {.async.} =
  ## ファイルハンドルを取得
  acquire(cache.lock)
  
  # ファイルハンドルのキャッシュをチェック
  if cache.openFiles.hasKey(path) and cache.openFiles[path].isOpen:
    var handle = cache.openFiles[path]
    handle.lastUsed = getTime()
    cache.openFiles[path] = handle
    release(cache.lock)
    return some(handle.file)
  
  # キャッシュサイズをチェック
  if cache.openFiles.len >= MAX_OPEN_FILES:
    # 最も古いハンドルを閉じる
    var oldest: tuple[path: string, time: Time] = ("", high(int64).int64.fromUnix)
    for p, h in cache.openFiles:
      if h.isOpen and h.lastUsed < oldest.time:
        oldest = (p, h.lastUsed)
    
    if oldest.path != "":
      try:
        cache.openFiles[oldest.path].file.close()
        cache.openFiles[oldest.path].isOpen = false
        cache.openFiles.del(oldest.path)
      except:
        discard
  
  release(cache.lock)
  
  # 新しいファイルハンドルを開く
  try:
    let file = await openAsync(path, mode)
    
    acquire(cache.lock)
    # ハンドルをキャッシュに追加
    cache.openFiles[path] = FileHandle(
      file: file,
      lastUsed: getTime(),
      path: path,
      isOpen: true
    )
    release(cache.lock)
    
    return some(file)
  except:
    return none(AsyncFile)

proc entryToCache(diskEntry: DiskCacheEntry): CacheEntry =
  ## ディスクキャッシュエントリからメモリキャッシュエントリに変換
  let now = getTime()
  
  # エントリタイプに基づいて適切なサブタイプを作成
  case diskEntry.entryType
  of cetResource:
    result = ResourceCacheEntry(
      url: diskEntry.url,
      entryType: diskEntry.entryType,
      created: fromUnix(diskEntry.created),
      lastAccessed: fromUnix(diskEntry.lastAccessed),
      expiresAt: fromUnix(diskEntry.expiresAt),
      size: diskEntry.size,
      accessCount: diskEntry.accessCount,
      policy: diskEntry.policy,
      priority: diskEntry.priority,
      validator: CacheValidator(
        etag: diskEntry.etag,
        lastModified: if diskEntry.lastModified.len > 0: some(parseTime(diskEntry.lastModified, "ddd, dd MMM yyyy HH:mm:ss 'GMT'")) else: none(Time)
      ),
      isCompressed: false,
      variantId: diskEntry.variantId,
      directives: @[],
      data: @[],  # データはまだロードしていない
      contentType: diskEntry.contentType,
      contentEncoding: ""
    )
  
  of cetResponse:
    result = ResponseCacheEntry(
      url: diskEntry.url,
      entryType: diskEntry.entryType,
      created: fromUnix(diskEntry.created),
      lastAccessed: fromUnix(diskEntry.lastAccessed),
      expiresAt: fromUnix(diskEntry.expiresAt),
      size: diskEntry.size,
      accessCount: diskEntry.accessCount,
      policy: diskEntry.policy,
      priority: diskEntry.priority,
      validator: CacheValidator(
        etag: diskEntry.etag,
        lastModified: if diskEntry.lastModified.len > 0: some(parseTime(diskEntry.lastModified, "ddd, dd MMM yyyy HH:mm:ss 'GMT'")) else: none(Time)
      ),
      isCompressed: false,
      variantId: diskEntry.variantId,
      directives: @[],
      statusCode: 200,  # デフォルト値
      headers: @[],     # ヘッダーはファイルから読み込まれる
      body: @[]         # ボディはファイルから読み込まれる
    )
  
  else:
    # その他のタイプ（ヘッダー、プッシュプロミス、WebTransport）
    # 必要に応じて実装
    result = CacheEntry(
      url: diskEntry.url,
      entryType: diskEntry.entryType,
      created: fromUnix(diskEntry.created),
      lastAccessed: fromUnix(diskEntry.lastAccessed),
      expiresAt: fromUnix(diskEntry.expiresAt),
      size: diskEntry.size,
      accessCount: diskEntry.accessCount,
      policy: diskEntry.policy,
      priority: diskEntry.priority,
      validator: CacheValidator(
        etag: diskEntry.etag,
        lastModified: if diskEntry.lastModified.len > 0: some(parseTime(diskEntry.lastModified, "ddd, dd MMM yyyy HH:mm:ss 'GMT'")) else: none(Time)
      ),
      isCompressed: false,
      variantId: diskEntry.variantId,
      directives: @[]
    )

proc deleteEntryFile(cache: DiskCache, entry: DiskCacheEntry): Future[bool] {.async.} =
  ## エントリファイルを削除
  let path = cache.joinCachePath(entry.filePath)
  
  if not fileExists(path):
    return true
  
  # ファイルハンドルをクローズ
  acquire(cache.lock)
  if cache.openFiles.hasKey(path) and cache.openFiles[path].isOpen:
    try:
      cache.openFiles[path].file.close()
      cache.openFiles[path].isOpen = false
      cache.openFiles.del(path)
    except:
      discard
  release(cache.lock)
  
  # ファイルを削除
  try:
    removeFile(path)
    return true
  except:
    return false 

proc newDiskCache*(cachePath: string, options: CacheOptions = CacheOptions()): Future[DiskCache] {.async.} =
  ## 新しいディスクキャッシュを作成
  if not ensureDirectoryExists(cachePath):
    return nil
  
  var cache = DiskCache(
    cachePath: cachePath,
    options: options,
    openFiles: initTable[string, FileHandle](),
    isInitialized: Atomic[bool](false),
    lastSaveTime: getTime(),
    dirty: false
  )
  
  initLock(cache.lock)
  
  # インデックスを読み込み
  if not await cache.loadIndex():
    # インデックスのロードに失敗した場合
    echo "Warning: Failed to load cache index, creating a new one."
  
  # 期限切れのエントリをクリーンアップ
  discard await cache.purgeExpired()
  
  cache.isInitialized.store(true)
  return cache

method init*(cache: DiskCache): Future[bool] {.async.} =
  ## キャッシュを初期化
  if cache.isInitialized.load():
    return true
  
  # インデックスを読み込み
  if not await cache.loadIndex():
    return false
  
  # 期限切れのエントリをクリーンアップ
  discard await cache.purgeExpired()
  
  cache.isInitialized.store(true)
  return true

method get*(cache: DiskCache, url: string, variantId: string = ""): Future[Option[CacheEntry]] {.async.} =
  ## URLに対応するエントリを取得
  if not cache.isInitialized.load():
    if not await cache.init():
      return none(CacheEntry)
  
  # インデックスからエントリを検索
  acquire(cache.lock)
  if not cache.indexData.entries.hasKey(url):
    # エントリが見つからない場合
    cache.stats.misses += 1
    release(cache.lock)
    return none(CacheEntry)
  
  var diskEntry = cache.indexData.entries[url]
  
  # バリアントIDが指定されていてマッチしない場合はスキップ
  if variantId.len > 0 and diskEntry.variantId != variantId:
    cache.stats.misses += 1
    release(cache.lock)
    return none(CacheEntry)
  
  # 期限切れのエントリをチェック
  let now = getTime().toUnix()
  if diskEntry.expiresAt > 0 and diskEntry.expiresAt < now:
    # 期限切れのエントリを削除
    cache.stats.misses += 1
    discard await cache.deleteEntryFile(diskEntry)
    cache.indexData.entries.del(url)
    cache.stats.size -= diskEntry.size
    cache.stats.entries -= 1
    cache.dirty = true
    release(cache.lock)
    return none(CacheEntry)
  
  # ファイルパスを取得
  let filePath = cache.joinCachePath(diskEntry.filePath)
  
  # エントリの更新
  diskEntry.lastAccessed = now
  diskEntry.accessCount += 1
  cache.indexData.entries[url] = diskEntry
  
  # 更新されたエントリをメモリキャッシュエントリに変換
  var entry = entryToCache(diskEntry)
  
  # ヒット統計を更新
  cache.stats.hits += 1
  release(cache.lock)
  
  # ファイルからデータを読み込み
  let fileHandleOpt = await cache.getFileHandle(filePath)
  if fileHandleOpt.isNone:
    # ファイルが開けない場合
    return none(CacheEntry)
  
  let file = fileHandleOpt.get()
  
  # ファイルサイズを取得
  let fileSize = await file.getFileSize()
  if fileSize <= 0:
    return none(CacheEntry)
  
  try:
    # データを読み込む
    var data = newSeq[byte](fileSize)
    let bytesRead = await file.readBuffer(addr data[0], fileSize)
    
    # エントリタイプに応じて適切なフィールドにデータを設定
    case entry.entryType
    of cetResource:
      var resourceEntry = ResourceCacheEntry(entry)
      resourceEntry.data = data
      return some(CacheEntry(resourceEntry))
    
    of cetResponse:
      var responseEntry = ResponseCacheEntry(entry)
      
      # ヘッダーとボディを分離する処理
      # 最初の行に JSONヘッダーを格納し、残りをボディとする
      var stream = newStringStream(cast[string](data))
      let headerLine = stream.readLine()
      
      try:
        # ヘッダーをJSONからパース
        let headersJson = parseJson(headerLine)
        var headers: seq[tuple[name: string, value: string]] = @[]
        
        for h in headersJson:
          headers.add((h["name"].getStr(), h["value"].getStr()))
        
        responseEntry.headers = headers
        
        # ステータスコードを取得
        for h in headers:
          if h.name.toLowerAscii() == ":status":
            responseEntry.statusCode = parseInt(h.value)
            break
      except:
        # ヘッダーのパースに失敗した場合はデフォルト値を使用
        responseEntry.headers = @[]
        responseEntry.statusCode = 200
      
      # 残りのデータをボディとして設定
      var body = newSeq[byte](fileSize - headerLine.len - 2)  # \r\nのため2バイト引く
      let bodyRead = await file.readBuffer(addr body[0], body.len)
      responseEntry.body = body[0..<bodyRead]
      
      return some(CacheEntry(responseEntry))
    
    else:
      # その他のタイプ（ヘッダー、プッシュプロミス、WebTransport）
      # 必要に応じて実装
      return some(entry)
  except:
    return none(CacheEntry)

method put*(cache: DiskCache, entry: CacheEntry): Future[bool] {.async.} =
  ## エントリをキャッシュに追加
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  # URLからファイルパスを生成
  let relFilePath = generateFilePath(entry.url)
  let filePath = cache.joinCachePath(relFilePath)
  
  # ディレクトリが存在することを確認
  let dirPath = filePath.parentDir()
  if not ensureDirectoryExists(dirPath):
    return false
  
  # エントリのサイズを計算
  var dataSize = 0
  var data: seq[byte] = @[]
  
  case entry.entryType
  of cetResource:
    let resourceEntry = ResourceCacheEntry(entry)
    dataSize = resourceEntry.data.len
    data = resourceEntry.data
  
  of cetResponse:
    let responseEntry = ResponseCacheEntry(entry)
    
    # ヘッダーをJSONとして保存
    var headersJson = newJArray()
    for header in responseEntry.headers:
      var headerObj = newJObject()
      headerObj["name"] = newJString(header.name)
      headerObj["value"] = newJString(header.value)
      headersJson.add(headerObj)
    
    let headersStr = $headersJson & "\r\n"
    dataSize = headersStr.len + responseEntry.body.len
    
    # ヘッダーとボディを結合
    data = cast[seq[byte]](headersStr) & responseEntry.body
  
  else:
    # その他のタイプ（ヘッダー、プッシュプロミス、WebTransport）
    # 必要に応じて実装
    dataSize = 0
  
  # 最大キャッシュサイズをチェック
  acquire(cache.lock)
  if cache.stats.size + dataSize > cache.stats.maxSize:
    # 古いエントリを削除してスペースを確保
    discard await cache.prune(dataSize)
  
  # 古いエントリが存在する場合は削除
  var oldSize = 0
  if cache.indexData.entries.hasKey(entry.url):
    let oldEntry = cache.indexData.entries[entry.url]
    oldSize = oldEntry.size
    discard await cache.deleteEntryFile(oldEntry)
    cache.stats.size -= oldSize
    cache.stats.entries -= 1
  
  # ディスクキャッシュエントリを作成
  let diskEntry = DiskCacheEntry(
    url: entry.url,
    filePath: relFilePath,
    entryType: entry.entryType,
    created: getTime().toUnix(),
    lastAccessed: getTime().toUnix(),
    expiresAt: entry.expiresAt.toUnix(),
    size: dataSize,
    accessCount: 0,
    policy: entry.policy,
    priority: entry.priority,
    contentType: case entry.entryType
                  of cetResource: ResourceCacheEntry(entry).contentType
                  else: "",
    etag: entry.validator.etag,
    lastModified: if entry.validator.lastModified.isSome: entry.validator.lastModified.get().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'") else: "",
    variantId: entry.variantId
  )
  
  # ファイルに書き込み
  let fileHandleOpt = await cache.getFileHandle(filePath, fmWrite)
  if fileHandleOpt.isNone:
    release(cache.lock)
    return false
  
  let file = fileHandleOpt.get()
  try:
    # データを書き込む
    await file.writeBytes(data, 0, data.len)
    
    # エントリをインデックスに追加
    cache.indexData.entries[entry.url] = diskEntry
    cache.stats.size += dataSize
    cache.stats.entries += 1
    cache.stats.insertions += 1
    cache.dirty = true
    
    # 定期的にインデックスを保存
    let now = getTime()
    if now - cache.lastSaveTime > initDuration(minutes = 5):
      discard await cache.saveIndex()
    
    release(cache.lock)
    return true
  except:
    release(cache.lock)
    return false

method delete*(cache: DiskCache, url: string): Future[bool] {.async.} =
  ## URLに対応するエントリを削除
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  acquire(cache.lock)
  
  # エントリが存在するかチェック
  if not cache.indexData.entries.hasKey(url):
    release(cache.lock)
    return false
  
  # エントリを取得
  let entry = cache.indexData.entries[url]
  
  # ファイルを削除
  discard await cache.deleteEntryFile(entry)
  
  # インデックスからエントリを削除
  cache.indexData.entries.del(url)
  cache.stats.size -= entry.size
  cache.stats.entries -= 1
  cache.stats.invalidations += 1
  cache.dirty = true
  
  # 定期的にインデックスを保存
  let now = getTime()
  if now - cache.lastSaveTime > initDuration(minutes = 5):
    discard await cache.saveIndex()
  
  release(cache.lock)
  return true

method purgeExpired*(cache: DiskCache): Future[int] {.async.} =
  ## 期限切れのエントリを削除
  if not cache.isInitialized.load():
    if not await cache.init():
      return 0
  
  acquire(cache.lock)
  
  var expiredCount = 0
  let now = getTime().toUnix()
  var toDelete: seq[string] = @[]
  
  # 期限切れのエントリを特定
  for url, entry in cache.indexData.entries:
    if entry.expiresAt > 0 and entry.expiresAt < now:
      toDelete.add(url)
  
  # 期限切れのエントリを削除
  for url in toDelete:
    let entry = cache.indexData.entries[url]
    discard await cache.deleteEntryFile(entry)
    cache.indexData.entries.del(url)
    cache.stats.size -= entry.size
    cache.stats.entries -= 1
    cache.stats.evictions += 1
    expiredCount += 1
  
  # インデックスが変更された場合は保存
  if expiredCount > 0:
    cache.dirty = true
    cache.indexData.lastCleanup = now
    discard await cache.saveIndex()
  
  release(cache.lock)
  return expiredCount

method prune*(cache: DiskCache, neededSpace: int = 0): Future[int] {.async.} =
  ## キャッシュから古いエントリを削除
  if not cache.isInitialized.load():
    if not await cache.init():
      return 0
  
  acquire(cache.lock)
  
  # すでに十分なスペースがある場合は何もしない
  if neededSpace > 0 and cache.stats.size + neededSpace <= cache.stats.maxSize:
    release(cache.lock)
    return 0
  
  var freedSpace = 0
  var prunedCount = 0
  
  # 必要なスペースを計算
  let targetSize = if neededSpace > 0: max(0, cache.stats.maxSize - neededSpace) else: (cache.stats.maxSize * 80) div 100
  
  # LRUアルゴリズムでエントリをソート
  var entries: seq[DiskCacheEntry] = @[]
  for _, entry in cache.indexData.entries:
    entries.add(entry)
  
  # 最終アクセス時間の昇順でソート（最も古いものが先頭）
  entries.sort(proc(a, b: DiskCacheEntry): int =
    result = cmp(a.lastAccessed, b.lastAccessed)
    if result == 0:
      # 同じ時間の場合は優先度でソート
      result = cmp(ord(a.priority), ord(b.priority))
  )
  
  # 必要なだけエントリを削除
  var i = 0
  while i < entries.len and cache.stats.size - freedSpace > targetSize:
    let entry = entries[i]
    
    # 高優先度のエントリはスキップ（オプション）
    if entry.priority == cpCritical or entry.priority == cpHigh:
      i += 1
      continue
    
    # エントリを削除
    discard await cache.deleteEntryFile(entry)
    cache.indexData.entries.del(entry.url)
    freedSpace += entry.size
    prunedCount += 1
    cache.stats.evictions += 1
    i += 1
  
  # 統計情報を更新
  cache.stats.size -= freedSpace
  cache.stats.entries -= prunedCount
  
  # インデックスが変更された場合は保存
  if prunedCount > 0:
    cache.dirty = true
    discard await cache.saveIndex()
  
  release(cache.lock)
  return prunedCount

method clear*(cache: DiskCache): Future[bool] {.async.} =
  ## キャッシュをクリア
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  acquire(cache.lock)
  
  # すべてのファイルハンドルを閉じる
  cache.closeFileHandles()
  
  # すべてのエントリファイルを削除
  for _, entry in cache.indexData.entries:
    discard await cache.deleteEntryFile(entry)
  
  # インデックスをリセット
  cache.indexData.entries = initTable[string, DiskCacheEntry]()
  cache.stats.size = 0
  cache.stats.entries = 0
  cache.stats.evictions += cache.stats.entries
  cache.dirty = true
  
  # インデックスファイルを削除
  let indexPath = cache.joinCachePath(CACHE_INDEX_FILE)
  let tempPath = cache.joinCachePath(TEMP_INDEX_FILE)
  
  if fileExists(indexPath):
    try:
      removeFile(indexPath)
    except:
      discard
  
  if fileExists(tempPath):
    try:
      removeFile(tempPath)
    except:
      discard
  
  # 新しいインデックスを保存
  discard await cache.saveIndex()
  
  release(cache.lock)
  return true

method close*(cache: DiskCache): Future[bool] {.async.} =
  ## キャッシュを閉じる
  if not cache.isInitialized.load():
    return true
  
  # インデックスを保存
  discard await cache.saveIndex()
  
  acquire(cache.lock)
  
  # すべてのファイルハンドルを閉じる
  cache.closeFileHandles()
  
  # ロックを解放
  release(cache.lock)
  
  # ロックを破棄
  deinitLock(cache.lock)
  
  cache.isInitialized.store(false)
  return true

method getStats*(cache: DiskCache): Future[CacheStats] {.async.} =
  ## キャッシュの統計情報を取得
  if not cache.isInitialized.load():
    if not await cache.init():
      return CacheStats()
  
  acquire(cache.lock)
  let stats = cache.stats
  release(cache.lock)
  
  return stats

method resize*(cache: DiskCache, newSize: int): Future[bool] {.async.} =
  ## キャッシュのサイズを変更
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  acquire(cache.lock)
  
  # サイズが小さくなる場合は古いエントリを削除
  if newSize < cache.stats.size:
    cache.stats.maxSize = newSize
    release(cache.lock)
    discard await cache.prune()
    acquire(cache.lock)
  
  # 新しいサイズを設定
  cache.stats.maxSize = newSize
  cache.dirty = true
  
  release(cache.lock)
  return true

method contains*(cache: DiskCache, url: string): Future[bool] {.async.} =
  ## URLがキャッシュに存在するかどうかを確認
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  acquire(cache.lock)
  let exists = cache.indexData.entries.hasKey(url)
  release(cache.lock)
  
  return exists

method touch*(cache: DiskCache, url: string): Future[bool] {.async.} =
  ## URLのアクセス時間を更新
  if not cache.isInitialized.load():
    if not await cache.init():
      return false
  
  acquire(cache.lock)
  
  # エントリが存在するかチェック
  if not cache.indexData.entries.hasKey(url):
    release(cache.lock)
    return false
  
  # アクセス時間を更新
  var entry = cache.indexData.entries[url]
  entry.lastAccessed = getTime().toUnix()
  entry.accessCount += 1
  cache.indexData.entries[url] = entry
  cache.dirty = true
  
  release(cache.lock)
  return true

method vacuum*(cache: DiskCache): Future[int] {.async.} =
  ## キャッシュの最適化と不要ファイルの削除
  if not cache.isInitialized.load():
    if not await cache.init():
      return 0
  
  # まず期限切れのエントリを削除
  var removed = await cache.purgeExpired()
  
  # ファイルシステムと整合性をチェック
  acquire(cache.lock)
  
  var orphaned = 0
  var missing = 0
  
  # インデックスに存在するが実際のファイルが存在しないエントリをチェック
  var toDelete: seq[string] = @[]
  for url, entry in cache.indexData.entries:
    let filePath = cache.joinCachePath(entry.filePath)
    if not fileExists(filePath):
      toDelete.add(url)
      missing += 1
  
  # 見つからないエントリを削除
  for url in toDelete:
    cache.indexData.entries.del(url)
    cache.stats.entries -= 1
    # サイズは正確に計算できないが、推定値を引く
    cache.stats.size -= cache.indexData.entries[url].size
    removed += 1
  
  # キャッシュディレクトリ内の孤立ファイルをチェック（オプション）
  # このロジックはキャッシュディレクトリの構造によって異なる
  
  # インデックスが変更された場合は保存
  if removed > 0 or orphaned > 0:
    cache.dirty = true
    discard await cache.saveIndex()
  
  release(cache.lock)
  return removed + orphaned 