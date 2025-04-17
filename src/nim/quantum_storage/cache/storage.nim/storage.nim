# キャッシュストレージモジュール
# ブラウザのキャッシュデータを管理します

import std/[
  os, 
  times, 
  strutils, 
  strformat, 
  tables, 
  hashes, 
  json, 
  options, 
  streams,
  algorithm,
  sugar,
  sequtils,
  md5,
  base64,
  asyncdispatch,
  uri
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, files]
import ../common/base

type
  CacheEntryType* = enum
    ## キャッシュエントリタイプ
    cetHtml,      # HTML
    cetCss,       # CSS
    cetJs,        # JavaScript
    cetImage,     # 画像
    cetFont,      # フォント
    cetJson,      # JSON
    cetXml,       # XML
    cetText,      # テキスト
    cetBinary,    # バイナリデータ
    cetOther      # その他

  CacheValidationMethod* = enum
    ## キャッシュ検証方法
    cvmNone,      # 検証なし
    cvmEtag,      # ETAGによる検証
    cvmLastModified  # 最終更新日時による検証

  CachePriority* = enum
    ## キャッシュ優先度
    cpNormal,     # 通常優先度
    cpHigh,       # 高優先度
    cpLow         # 低優先度

  CacheEntryMetadata* = object
    ## キャッシュエントリのメタデータ
    key*: string                # キャッシュキー (URL+パラメータのハッシュ)
    url*: string                # 元のURL
    contentType*: string        # Content-Type
    contentLength*: int         # Content-Length
    lastAccessed*: DateTime     # 最終アクセス日時
    created*: DateTime          # 作成日時
    expires*: Option[DateTime]  # 有効期限
    headers*: Table[string, string]  # レスポンスヘッダ
    entryType*: CacheEntryType  # エントリタイプ
    etag*: string               # ETag値
    lastModified*: string       # Last-Modified値
    validationMethod*: CacheValidationMethod  # 検証方法
    priority*: CachePriority    # 優先度

  CacheEntry* = object
    ## キャッシュエントリ（メタデータ+データ）
    metadata*: CacheEntryMetadata  # メタデータ
    data*: string               # キャッシュデータ（通常はファイルパス、インメモリならデータそのもの）

  StorageType* = enum
    ## ストレージタイプ
    stFileSystem,  # ファイルシステム
    stMemory,      # メモリ内
    stHybrid       # ハイブリッド

  CacheStats* = object
    ## キャッシュ統計情報
    hits*: int           # ヒット数
    misses*: int         # ミス数
    entries*: int        # エントリ数
    totalSize*: int64    # 合計サイズ
    oldestEntry*: DateTime  # 最古のエントリ
    newestEntry*: DateTime  # 最新のエントリ

  CacheStoragePolicy* = object
    ## キャッシュストレージポリシー
    maxSize*: int64      # 最大サイズ (バイト)
    maxEntries*: int     # 最大エントリ数
    maxAge*: Duration    # 最大保持期間
    cleanupInterval*: Duration  # クリーンアップ間隔

  CacheStorage* = ref object
    ## キャッシュストレージ
    baseDir*: string     # ベースディレクトリ (ファイルシステムの場合)
    entries*: Table[string, CacheEntryMetadata]  # キャッシュエントリのメタデータテーブル
    memoryCache*: Table[string, string]  # メモリ内キャッシュ
    storageType*: StorageType  # ストレージタイプ
    policy*: CacheStoragePolicy  # ストレージポリシー
    stats*: CacheStats     # 統計情報
    initialized*: bool     # 初期化済みフラグ

const
  DEFAULT_MAX_CACHE_SIZE* = 100 * 1024 * 1024  # 100MB
  DEFAULT_MAX_ENTRIES* = 10000  # 最大エントリ数
  DEFAULT_MAX_AGE* = 7.days     # 7日間
  DEFAULT_CLEANUP_INTERVAL* = 1.hours  # 1時間ごとにクリーンアップ
  INDEX_FILE_NAME = "cache_index.json"  # インデックスファイル名
  
  # Content-Typeからエントリタイプへのマッピング
  CONTENT_TYPE_MAP = {
    "text/html": CacheEntryType.cetHtml,
    "text/css": CacheEntryType.cetCss,
    "application/javascript": CacheEntryType.cetJs,
    "text/javascript": CacheEntryType.cetJs,
    "image/jpeg": CacheEntryType.cetImage,
    "image/png": CacheEntryType.cetImage,
    "image/gif": CacheEntryType.cetImage,
    "image/webp": CacheEntryType.cetImage,
    "image/svg+xml": CacheEntryType.cetImage,
    "font/woff": CacheEntryType.cetFont,
    "font/woff2": CacheEntryType.cetFont,
    "font/ttf": CacheEntryType.cetFont,
    "font/otf": CacheEntryType.cetFont,
    "application/json": CacheEntryType.cetJson,
    "application/xml": CacheEntryType.cetXml,
    "text/xml": CacheEntryType.cetXml,
    "text/plain": CacheEntryType.cetText
  }.toTable

# ヘルパー関数
proc generateCacheKey*(url: string): string =
  ## URLからキャッシュキーを生成
  result = getMD5(url)

proc guessEntryTypeFromContentType*(contentType: string): CacheEntryType =
  ## Content-TypeからエントリタイプをGuess
  let baseType = contentType.split(';')[0].strip()
  if CONTENT_TYPE_MAP.hasKey(baseType):
    return CONTENT_TYPE_MAP[baseType]
  
  # 部分一致で判定
  for ct, entryType in CONTENT_TYPE_MAP.pairs:
    if baseType.startsWith(ct.split('/')[0]):
      return entryType
  
  # バイナリ判定
  if baseType.startsWith("application/"):
    return CacheEntryType.cetBinary
    
  return CacheEntryType.cetOther

proc getDataPath(self: CacheStorage, key: string): string =
  ## キャッシュキーからデータファイルパスを取得
  result = self.baseDir / key[0..1] / key

proc isExpired(metadata: CacheEntryMetadata): bool =
  ## エントリが期限切れかどうかをチェック
  if metadata.expires.isNone:
    return false
  return metadata.expires.get() < now()

proc calculateEntriesSize(self: CacheStorage): int64 =
  ## すべてのエントリのサイズを計算
  result = 0'i64
  for meta in self.entries.values:
    result += meta.contentLength.int64

# CacheStorageの実装
proc newCacheStorage*(baseDir: string, 
                     storageType: StorageType = StorageType.stFileSystem,
                     policy: CacheStoragePolicy = CacheStoragePolicy()): CacheStorage =
  ## 新しいキャッシュストレージを作成
  result = CacheStorage(
    baseDir: baseDir,
    entries: initTable[string, CacheEntryMetadata](),
    memoryCache: initTable[string, string](),
    storageType: storageType,
    policy: policy,
    stats: CacheStats(
      hits: 0,
      misses: 0,
      entries: 0,
      totalSize: 0,
      oldestEntry: now(),
      newestEntry: now()
    ),
    initialized: false
  )
  
  # ポリシーのデフォルト値を設定
  if result.policy.maxSize == 0:
    result.policy.maxSize = DEFAULT_MAX_CACHE_SIZE
  if result.policy.maxEntries == 0:
    result.policy.maxEntries = DEFAULT_MAX_ENTRIES
  if result.policy.maxAge == Duration():
    result.policy.maxAge = DEFAULT_MAX_AGE
  if result.policy.cleanupInterval == Duration():
    result.policy.cleanupInterval = DEFAULT_CLEANUP_INTERVAL

  # ファイルシステムの準備
  if storageType in [StorageType.stFileSystem, StorageType.stHybrid]:
    try:
      # ベースディレクトリの作成
      createDir(baseDir)
      
      # サブディレクトリの作成（00～ff）
      for i in 0..255:
        let hexDir = i.toHex(2).toLowerAscii()
        createDir(baseDir / hexDir)
      
      # インデックスの読み込み
      let indexPath = baseDir / INDEX_FILE_NAME
      if fileExists(indexPath):
        let indexJson = parseFile(indexPath)
        for key, entryJson in indexJson.pairs:
          try:
            var metadata = CacheEntryMetadata(
              key: key,
              url: entryJson["url"].getStr(),
              contentType: entryJson["contentType"].getStr(),
              contentLength: entryJson["contentLength"].getInt(),
              lastAccessed: parse(entryJson["lastAccessed"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"),
              created: parse(entryJson["created"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"),
              headers: initTable[string, string](),
              entryType: parseEnum[CacheEntryType](entryJson["entryType"].getStr()),
              etag: entryJson["etag"].getStr(),
              lastModified: entryJson["lastModified"].getStr(),
              validationMethod: parseEnum[CacheValidationMethod](entryJson["validationMethod"].getStr()),
              priority: parseEnum[CachePriority](entryJson["priority"].getStr())
            )
            
            # 有効期限
            if entryJson.hasKey("expires") and entryJson["expires"].getStr() != "":
              metadata.expires = some(parse(entryJson["expires"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
            
            # ヘッダー
            if entryJson.hasKey("headers"):
              for headerName, headerValue in entryJson["headers"].pairs:
                metadata.headers[headerName] = headerValue.getStr()
                
            # データファイルの存在確認
            let dataPath = result.getDataPath(key)
            if fileExists(dataPath):
              result.entries[key] = metadata
              
          except:
            error "Failed to parse cache entry", key = key, error = getCurrentExceptionMsg()
      
      # 統計情報の更新
      let entriesSeq = toSeq(result.entries.values)
      result.stats.entries = entriesSeq.len
      result.stats.totalSize = result.calculateEntriesSize()
      
      if entriesSeq.len > 0:
        let sortedByTime = entriesSeq.sortedByIt(it.created)
        result.stats.oldestEntry = sortedByTime[0].created
        result.stats.newestEntry = sortedByTime[^1].created
      
    except:
      error "Failed to initialize cache storage", 
            baseDir = baseDir, error = getCurrentExceptionMsg()
  
  result.initialized = true
  info "Cache storage initialized", type = $storageType, entries = result.stats.entries

proc saveIndex(self: CacheStorage) =
  ## キャッシュインデックスを保存
  if self.storageType == StorageType.stMemory:
    return
    
  try:
    var indexJson = newJObject()
    
    for key, metadata in self.entries.pairs:
      var entryJson = %*{
        "url": metadata.url,
        "contentType": metadata.contentType,
        "contentLength": metadata.contentLength,
        "lastAccessed": metadata.lastAccessed.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        "created": metadata.created.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        "entryType": $metadata.entryType,
        "etag": metadata.etag,
        "lastModified": metadata.lastModified,
        "validationMethod": $metadata.validationMethod,
        "priority": $metadata.priority
      }
      
      # 有効期限
      if metadata.expires.isSome:
        entryJson["expires"] = %(metadata.expires.get().format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
      else:
        entryJson["expires"] = %""
      
      # ヘッダー
      var headersJson = newJObject()
      for name, value in metadata.headers.pairs:
        headersJson[name] = %value
      
      entryJson["headers"] = headersJson
      indexJson[key] = entryJson
    
    writeFile(self.baseDir / INDEX_FILE_NAME, $indexJson)
    info "Cache index saved", entries = self.entries.len
  except:
    error "Failed to save cache index", error = getCurrentExceptionMsg()

proc enforcePolicy(self: CacheStorage) =
  ## ポリシーに従ってキャッシュサイズを制限
  # サイズ制限
  if self.stats.totalSize > self.policy.maxSize or
     self.stats.entries > self.policy.maxEntries:
    # アクセス日時でソート
    var entriesByAccess = toSeq(self.entries.pairs)
    entriesByAccess.sort(proc(a, b: (string, CacheEntryMetadata)): int =
      result = cmp(a[1].lastAccessed, b[1].lastAccessed)
      # 同じアクセス日時なら優先度を考慮
      if result == 0:
        result = cmp(ord(a[1].priority), ord(b[1].priority))
    )
    
    # サイズか数が制限内になるまで削除
    var removedSize = 0'i64
    var removedCount = 0
    
    for i in 0..<entriesByAccess.len:
      # 目標達成したら終了
      if self.stats.totalSize - removedSize <= self.policy.maxSize and
         self.stats.entries - removedCount <= self.policy.maxEntries:
        break
      
      let (key, metadata) = entriesByAccess[i]
      
      # メモリキャッシュの場合
      if self.storageType in [StorageType.stMemory, StorageType.stHybrid]:
        self.memoryCache.del(key)
      
      # ファイルキャッシュの場合
      if self.storageType in [StorageType.stFileSystem, StorageType.stHybrid]:
        let dataPath = self.getDataPath(key)
        try:
          removeFile(dataPath)
        except:
          error "Failed to remove cache file", 
                path = dataPath, error = getCurrentExceptionMsg()
      
      # エントリ削除
      self.entries.del(key)
      removedSize += metadata.contentLength.int64
      inc removedCount
    
    # 統計更新
    self.stats.totalSize -= removedSize
    self.stats.entries -= removedCount
    
    info "Cleaned up cache entries", 
         removed_entries = removedCount, removed_size = removedSize

proc put*(self: CacheStorage, url: string, data: string, contentType: string, 
         headers: Table[string, string] = initTable[string, string](),
         expires: Option[DateTime] = none(DateTime),
         priority: CachePriority = CachePriority.cpNormal): string =
  ## データをキャッシュに格納し、キャッシュキーを返す
  let key = generateCacheKey(url)
  let entryType = guessEntryTypeFromContentType(contentType)
  let currentTime = now()
  
  # 検証方法の判定
  var 
    validationMethod = CacheValidationMethod.cvmNone
    etag = ""
    lastModified = ""
  
  if headers.hasKey("ETag"):
    validationMethod = CacheValidationMethod.cvmEtag
    etag = headers["ETag"]
  elif headers.hasKey("Last-Modified"):
    validationMethod = CacheValidationMethod.cvmLastModified
    lastModified = headers["Last-Modified"]
  
  # メタデータ作成
  let metadata = CacheEntryMetadata(
    key: key,
    url: url,
    contentType: contentType,
    contentLength: data.len,
    lastAccessed: currentTime,
    created: currentTime,
    expires: expires,
    headers: headers,
    entryType: entryType,
    etag: etag,
    lastModified: lastModified,
    validationMethod: validationMethod,
    priority: priority
  )
  
  # 既存エントリがあれば削除
  if self.entries.hasKey(key):
    let oldSize = self.entries[key].contentLength
    self.stats.totalSize -= oldSize.int64
  else:
    inc self.stats.entries
  
  # メタデータ保存
  self.entries[key] = metadata
  
  # データ保存
  case self.storageType:
    of StorageType.stMemory:
      self.memoryCache[key] = data
      
    of StorageType.stFileSystem:
      let dataPath = self.getDataPath(key)
      try:
        writeFile(dataPath, data)
      except:
        error "Failed to write cache file", 
              path = dataPath, error = getCurrentExceptionMsg()
              
    of StorageType.stHybrid:
      # メモリとファイルシステムの両方に保存
      self.memoryCache[key] = data
      let dataPath = self.getDataPath(key)
      try:
        writeFile(dataPath, data)
      except:
        error "Failed to write cache file", 
              path = dataPath, error = getCurrentExceptionMsg()
  
  # 統計更新
  self.stats.totalSize += data.len.int64
  self.stats.newestEntry = currentTime
  if self.stats.entries == 1:  # 最初のエントリの場合
    self.stats.oldestEntry = currentTime
  
  # インデックス保存
  self.saveIndex()
  
  # ポリシー適用
  self.enforcePolicy()
  
  info "Item cached", url = url, key = key, size = data.len, type = $entryType
  return key

proc get*(self: CacheStorage, key: string): Option[CacheEntry] =
  ## キャッシュからデータを取得
  if not self.entries.hasKey(key):
    inc self.stats.misses
    return none(CacheEntry)
  
  var metadata = self.entries[key]
  
  # 期限切れチェック
  if isExpired(metadata):
    self.entries.del(key)
    
    # メモリキャッシュの場合
    if self.storageType in [StorageType.stMemory, StorageType.stHybrid]:
      self.memoryCache.del(key)
    
    # ファイルキャッシュの場合
    if self.storageType in [StorageType.stFileSystem, StorageType.stHybrid]:
      let dataPath = self.getDataPath(key)
      try:
        removeFile(dataPath)
      except:
        error "Failed to remove expired cache file", 
              path = dataPath, error = getCurrentExceptionMsg()
              
    self.saveIndex()
    inc self.stats.misses
    return none(CacheEntry)
  
  # データ取得
  var data: string
  case self.storageType:
    of StorageType.stMemory:
      if not self.memoryCache.hasKey(key):
        inc self.stats.misses
        return none(CacheEntry)
      data = self.memoryCache[key]
      
    of StorageType.stFileSystem:
      let dataPath = self.getDataPath(key)
      try:
        data = readFile(dataPath)
      except:
        error "Failed to read cache file", 
              path = dataPath, error = getCurrentExceptionMsg()
        inc self.stats.misses
        return none(CacheEntry)
    
    of StorageType.stHybrid:
      # まずメモリから
      if self.memoryCache.hasKey(key):
        data = self.memoryCache[key]
      else:
        # ファイルから
        let dataPath = self.getDataPath(key)
        try:
          data = readFile(dataPath)
          # メモリにも格納
          self.memoryCache[key] = data
        except:
          error "Failed to read cache file", 
                path = dataPath, error = getCurrentExceptionMsg()
          inc self.stats.misses
          return none(CacheEntry)
  
  # 最終アクセス日時更新
  metadata.lastAccessed = now()
  self.entries[key] = metadata
  
  inc self.stats.hits
  return some(CacheEntry(
    metadata: metadata,
    data: data
  ))

proc getByUrl*(self: CacheStorage, url: string): Option[CacheEntry] =
  ## URLでキャッシュ検索
  let key = generateCacheKey(url)
  return self.get(key)

proc delete*(self: CacheStorage, key: string): bool =
  ## キャッシュエントリを削除
  if not self.entries.hasKey(key):
    return false
  
  let metadata = self.entries[key]
  
  # メモリキャッシュの場合
  if self.storageType in [StorageType.stMemory, StorageType.stHybrid]:
    self.memoryCache.del(key)
  
  # ファイルキャッシュの場合
  if self.storageType in [StorageType.stFileSystem, StorageType.stHybrid]:
    let dataPath = self.getDataPath(key)
    try:
      removeFile(dataPath)
    except:
      error "Failed to remove cache file", 
            path = dataPath, error = getCurrentExceptionMsg()
  
  # エントリ削除
  self.entries.del(key)
  
  # 統計更新
  dec self.stats.entries
  self.stats.totalSize -= metadata.contentLength.int64
  
  # インデックス保存
  self.saveIndex()
  
  info "Cache entry deleted", key = key
  return true

proc deleteByUrl*(self: CacheStorage, url: string): bool =
  ## URLでキャッシュエントリを削除
  let key = generateCacheKey(url)
  return self.delete(key)

proc clear*(self: CacheStorage) =
  ## すべてのキャッシュをクリア
  # メモリキャッシュの場合
  if self.storageType in [StorageType.stMemory, StorageType.stHybrid]:
    self.memoryCache.clear()
  
  # ファイルキャッシュの場合
  if self.storageType in [StorageType.stFileSystem, StorageType.stHybrid]:
    for key in self.entries.keys:
      let dataPath = self.getDataPath(key)
      try:
        removeFile(dataPath)
      except:
        error "Failed to remove cache file during clear", 
              path = dataPath, error = getCurrentExceptionMsg()
  
  # エントリクリア
  self.entries.clear()
  
  # 統計リセット
  self.stats.entries = 0
  self.stats.totalSize = 0
  self.stats.hits = 0
  self.stats.misses = 0
  
  # インデックス保存
  self.saveIndex()
  
  info "Cache cleared"

proc touch*(self: CacheStorage, key: string): bool =
  ## キャッシュエントリのアクセス日時を更新
  if not self.entries.hasKey(key):
    return false
  
  var metadata = self.entries[key]
  metadata.lastAccessed = now()
  self.entries[key] = metadata
  
  return true

proc purgeExpired*(self: CacheStorage): int =
  ## 期限切れのキャッシュを削除し、削除数を返す
  var keysToDelete: seq[string] = @[]
  
  # 期限切れのエントリをリストアップ
  for key, metadata in self.entries.pairs:
    if isExpired(metadata):
      keysToDelete.add(key)
  
  # 削除実行
  for key in keysToDelete:
    discard self.delete(key)
  
  if keysToDelete.len > 0:
    self.saveIndex()
    
  info "Purged expired cache entries", count = keysToDelete.len
  return keysToDelete.len

proc updateStats*(self: CacheStorage) =
  ## 統計情報を更新
  # エントリ数とサイズ
  self.stats.entries = self.entries.len
  self.stats.totalSize = self.calculateEntriesSize()
  
  # 最古・最新の更新日時
  if self.stats.entries > 0:
    let entriesSeq = toSeq(self.entries.values)
    
    let oldestEntry = entriesSeq.sortedByIt(it.created)[0]
    let newestEntry = entriesSeq.sortedByIt(it.created)[^1]
    
    self.stats.oldestEntry = oldestEntry.created
    self.stats.newestEntry = newestEntry.created

proc cleanupTask*(self: CacheStorage) {.async.} =
  ## 定期クリーンアップタスク
  while true:
    # 指定間隔待機
    await sleepAsync(self.policy.cleanupInterval.inMilliseconds.int)
    
    # 期限切れの削除
    discard self.purgeExpired()
    
    # ポリシー適用
    self.enforcePolicy()
    
    # 統計更新
    self.updateStats()
    
    info "Cache cleanup completed", 
         entries = self.stats.entries, 
         size = self.stats.totalSize

proc getStatsJson*(self: CacheStorage): JsonNode =
  ## 統計情報をJSON形式で取得
  self.updateStats()
  
  var typeStats: Table[string, int] = initTable[string, int]()
  for entryType in CacheEntryType:
    typeStats[$entryType] = 0
  
  # エントリタイプ別統計
  for metadata in self.entries.values:
    typeStats[$metadata.entryType] += 1
  
  var typeStatsJson = newJObject()
  for typeName, count in typeStats.pairs:
    typeStatsJson[typeName] = %count
  
  result = %*{
    "entries": self.stats.entries,
    "totalSize": self.stats.totalSize,
    "hits": self.stats.hits,
    "misses": self.stats.misses,
    "hitRatio": if self.stats.hits + self.stats.misses > 0: 
                  self.stats.hits.float / (self.stats.hits + self.stats.misses).float
                else: 0.0,
    "oldestEntry": if self.stats.entries > 0: 
                     self.stats.oldestEntry.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
                   else: "",
    "newestEntry": if self.stats.entries > 0: 
                     self.stats.newestEntry.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
                   else: "",
    "typeBreakdown": typeStatsJson
  }

proc close*(self: CacheStorage) =
  ## キャッシュストレージを閉じる
  self.saveIndex()
  info "Cache storage closed"

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testCacheStorage() =
    # テンポラリディレクトリを使用
    let tempDir = getTempDir() / "cache_test"
    createDir(tempDir)
    
    # キャッシュストレージ作成
    let policy = CacheStoragePolicy(
      maxSize: 10 * 1024 * 1024,  # 10MB
      maxEntries: 1000,
      maxAge: 1.days,
      cleanupInterval: 10.minutes
    )
    
    let cache = newCacheStorage(tempDir, StorageType.stHybrid, policy)
    
    # テストデータ
    let testUrl = "https://example.com/test"
    let testData = "This is test cache data"
    let testType = "text/plain"
    let testHeaders = {"Content-Type": "text/plain", "ETag": "\"123456\""}.toTable
    
    # キャッシュに格納
    let key = cache.put(testUrl, testData, testType, testHeaders)
    echo "Cached with key: ", key
    
    # 取得
    let entry = cache.get(key)
    if entry.isSome:
      echo "Retrieved cache: ", entry.get().data
      echo "Content-Type: ", entry.get().metadata.contentType
      echo "ETag: ", entry.get().metadata.etag
    
    # URLで取得
    let urlEntry = cache.getByUrl(testUrl)
    if urlEntry.isSome:
      echo "Retrieved by URL: ", urlEntry.get().data
    
    # 統計表示
    let stats = cache.getStatsJson()
    echo "Cache stats: ", stats.pretty
    
    # クリーンアップ
    echo "Purging expired: ", cache.purgeExpired()
    
    # 削除
    let deleted = cache.delete(key)
    echo "Deleted: ", deleted
    
    # クリア
    cache.clear()
    echo "Cache cleared"
    
    # クローズ
    cache.close()
    
    # テンポラリディレクトリ削除
    removeDir(tempDir)
  
  # テスト実行
  testCacheStorage() 