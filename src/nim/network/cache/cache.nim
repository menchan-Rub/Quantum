## ブラウザのキャッシュシステム
## これは様々なキャッシュ実装（メモリ、ディスク）を統合したモジュールです

import std/[tables, times, hashes, strutils, os, asyncdispatch, options, json, streams]
import ./memory
import ./disk/disk_cache
import ./policy/cache_policy

type
  CacheType* = enum
    ctMemory,  # メモリキャッシュ
    ctDisk,    # ディスクキャッシュ
    ctHybrid   # ハイブリッドキャッシュ（メモリ+ディスク）

  CacheEntryMetadata* = object
    key*: string                # キャッシュキー
    contentType*: string        # コンテンツタイプ
    etag*: string               # ETag
    lastModified*: string       # 最終更新日時
    expires*: Time              # 有効期限
    maxAge*: int                # max-age（秒）
    created*: Time              # 作成日時
    lastAccessed*: Time         # 最終アクセス日時
    accessCount*: int           # アクセス回数
    size*: int                  # サイズ（バイト）
    headers*: Table[string, string] # 関連するHTTPヘッダー

  CachePolicy* = enum
    cpLRU,     # Least Recently Used（最も長く使われていない）
    cpLFU,     # Least Frequently Used（最も使用頻度が低い）
    cpFIFO,    # First In First Out（先入れ先出し）
    cpTTL,     # Time To Live（有効期限ベース）
    cpAdaptive # 適応型（アクセスパターンに基づく）

  BrowserCache* = ref object
    memoryCache*: MemoryCache          # メモリキャッシュ
    diskCache*: DiskCache              # ディスクキャッシュ
    cacheType*: CacheType              # キャッシュタイプ
    policy*: CachePolicy               # キャッシュポリシー
    policyImplementation*: CachePolicyImpl # ポリシー実装
    maxMemorySize*: int                # メモリキャッシュの最大サイズ（MB）
    maxDiskSize*: int                  # ディスクキャッシュの最大サイズ（MB）
    defaultTtl*: int                   # デフォルトのTTL（秒）
    stats*: CacheStats                 # キャッシュ統計
    
  CacheStats* = object
    hits*: int                  # キャッシュヒット数
    misses*: int                # キャッシュミス数
    memoryHits*: int            # メモリキャッシュヒット数
    diskHits*: int              # ディスクキャッシュヒット数
    evictions*: int             # 追い出し数
    totalSize*: int             # 総サイズ（バイト）
    memorySize*: int            # メモリキャッシュサイズ（バイト）
    diskSize*: int              # ディスクキャッシュサイズ（バイト）
    oldestEntry*: Time          # 最も古いエントリの日時
    newestEntry*: Time          # 最も新しいエントリの日時

  CacheResult* = object
    found*: bool                # 見つかったかどうか
    content*: string            # キャッシュの内容
    metadata*: CacheEntryMetadata # メタデータ
    source*: CacheType          # キャッシュソース

proc newBrowserCache*(
    cacheType: CacheType = ctHybrid,
    policy: CachePolicy = cpLRU,
    maxMemorySize: int = 100,
    maxDiskSize: int = 1000,
    ttl: int = 3600,
    diskCachePath: string = ""
): BrowserCache =
  ## 新しいブラウザキャッシュを作成する
  ## cacheType: キャッシュタイプ（メモリ、ディスク、ハイブリッド）
  ## policy: キャッシュポリシー
  ## maxMemorySize: メモリキャッシュの最大サイズ（MB）
  ## maxDiskSize: ディスクキャッシュの最大サイズ（MB）
  ## ttl: デフォルトのTTL（秒）
  ## diskCachePath: ディスクキャッシュのパス（空の場合は自動生成）
  
  result = BrowserCache(
    cacheType: cacheType,
    policy: policy,
    maxMemorySize: maxMemorySize,
    maxDiskSize: maxDiskSize,
    defaultTtl: ttl,
    stats: CacheStats(
      hits: 0,
      misses: 0,
      memoryHits: 0,
      diskHits: 0,
      evictions: 0,
      totalSize: 0,
      memorySize: 0,
      diskSize: 0,
      oldestEntry: getTime(),
      newestEntry: getTime()
    )
  )
  
  # キャッシュポリシーの初期化
  case policy
  of cpLRU:
    result.policyImplementation = newLRUPolicy()
  of cpLFU:
    result.policyImplementation = newLFUPolicy()
  of cpFIFO:
    result.policyImplementation = newFIFOPolicy()
  of cpTTL:
    result.policyImplementation = newTTLPolicy()
  of cpAdaptive:
    result.policyImplementation = newAdaptivePolicy()
  
  # キャッシュの初期化
  if cacheType in [ctMemory, ctHybrid]:
    result.memoryCache = newMemoryCache(maxMemorySize, ttl)
  
  if cacheType in [ctDisk, ctHybrid]:
    let cachePath = if diskCachePath == "": getTempDir() / "browser_cache" else: diskCachePath
    result.diskCache = newDiskCache(cachePath, maxDiskSize, ttl)

proc get*(cache: BrowserCache, key: string): Future[CacheResult] {.async.} =
  ## キャッシュからデータを取得する
  var result = CacheResult(found: false)
  
  # メモリキャッシュから取得を試みる
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    let content = cache.memoryCache.get(key)
    if content != "":
      # メモリからヒット
      cache.stats.hits += 1
      cache.stats.memoryHits += 1
      
      # メタデータを設定
      let entry = cache.memoryCache.getEntryMetadata(key)
      result = CacheResult(
        found: true,
        content: content,
        metadata: CacheEntryMetadata(
          key: key,
          contentType: entry.contentType,
          etag: entry.etag,
          lastModified: entry.lastModified,
          expires: entry.expires,
          maxAge: entry.maxAge,
          created: entry.created,
          lastAccessed: entry.lastAccessed,
          accessCount: entry.accessCount,
          size: content.len,
          headers: entry.headers
        ),
        source: ctMemory
      )
      return result
  
  # ディスクキャッシュから取得を試みる
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    let diskResult = await cache.diskCache.get(key)
    if diskResult.found:
      # ディスクからヒット
      cache.stats.hits += 1
      cache.stats.diskHits += 1
      
      # メモリキャッシュにも追加（ハイブリッドモードの場合）
      if cache.cacheType == ctHybrid and cache.memoryCache != nil:
        cache.memoryCache.set(key, diskResult.content, diskResult.metadata)
      
      result = CacheResult(
        found: true,
        content: diskResult.content,
        metadata: diskResult.metadata,
        source: ctDisk
      )
      return result
  
  # キャッシュミス
  cache.stats.misses += 1
  return result

proc set*(cache: BrowserCache, key: string, content: string, metadata: CacheEntryMetadata = CacheEntryMetadata(), ttl: int = -1): Future[void] {.async.} =
  ## データをキャッシュに保存する
  let actualTtl = if ttl < 0: cache.defaultTtl else: ttl
  
  # ポリシーに基づいて追い出し判断
  let evictionKey = cache.policyImplementation.getEvictionCandidate(key, content.len)
  if evictionKey != "" and key != evictionKey:
    # エントリを追い出す
    if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
      cache.memoryCache.remove(evictionKey)
    
    if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
      await cache.diskCache.remove(evictionKey)
    
    cache.stats.evictions += 1
  
  # メモリキャッシュに保存
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    cache.memoryCache.set(key, content, metadata, actualTtl)
    cache.stats.memorySize = cache.memoryCache.getCurrentSize()
  
  # ディスクキャッシュに保存
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    await cache.diskCache.set(key, content, metadata, actualTtl)
    cache.stats.diskSize = cache.diskCache.getCurrentSize()
  
  # 統計の更新
  cache.stats.totalSize = cache.stats.memorySize + cache.stats.diskSize
  cache.stats.newestEntry = getTime()
  
  # ポリシー情報の更新
  cache.policyImplementation.updateEntry(key, content.len)

proc contains*(cache: BrowserCache, key: string): Future[bool] {.async.} =
  ## キーがキャッシュに存在するかを確認する
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    if cache.memoryCache.has(key):
      return true
  
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    return await cache.diskCache.has(key)
  
  return false

proc remove*(cache: BrowserCache, key: string): Future[bool] {.async.} =
  ## キャッシュからエントリを削除する
  var result = false
  
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    result = result or cache.memoryCache.remove(key)
  
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    result = result or (await cache.diskCache.remove(key))
  
  if result:
    # ポリシー情報の更新
    cache.policyImplementation.removeEntry(key)
  
  return result

proc clear*(cache: BrowserCache): Future[void] {.async.} =
  ## キャッシュを完全にクリアする
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    cache.memoryCache.clear()
  
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    await cache.diskCache.clear()
  
  # 統計のリセット
  cache.stats = CacheStats(
    hits: 0,
    misses: 0,
    memoryHits: 0,
    diskHits: 0,
    evictions: 0,
    totalSize: 0,
    memorySize: 0,
    diskSize: 0,
    oldestEntry: getTime(),
    newestEntry: getTime()
  )
  
  # ポリシー情報のリセット
  cache.policyImplementation.reset()

proc getStats*(cache: BrowserCache): CacheStats =
  ## キャッシュ統計を取得する
  result = cache.stats
  
  # 最新の情報で更新
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    let memStats = cache.memoryCache.getStats()
    result.memorySize = memStats.size
  
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    let diskStats = cache.diskCache.getStats()
    result.diskSize = diskStats.size
  
  result.totalSize = result.memorySize + result.diskSize

proc getHitRatio*(cache: BrowserCache): float =
  ## キャッシュヒット率を計算する
  let total = cache.stats.hits + cache.stats.misses
  if total == 0:
    return 0.0
  return cache.stats.hits.float / total.float * 100.0

proc prune*(cache: BrowserCache): Future[int] {.async.} =
  ## 期限切れのエントリを削除する
  ## 戻り値: 削除されたエントリの数
  var removedCount = 0
  
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    removedCount += cache.memoryCache.prune()
  
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    removedCount += await cache.diskCache.prune()
  
  return removedCount

proc optimize*(cache: BrowserCache): Future[void] {.async.} =
  ## キャッシュを最適化する
  ## これにはフラグメンテーション解消、ディスク領域の解放などが含まれる
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    await cache.diskCache.optimize()

proc exportEntries*(cache: BrowserCache): Future[string] {.async.} =
  ## キャッシュエントリをJSON形式でエクスポートする
  var entries = newJObject()
  
  # メモリキャッシュからエントリを取得
  if cache.cacheType in [ctMemory, ctHybrid] and cache.memoryCache != nil:
    let memEntries = cache.memoryCache.getAllEntries()
    for key, entry in memEntries:
      var entryObj = newJObject()
      entryObj["type"] = %"memory"
      entryObj["content"] = %entry.content
      entryObj["expires"] = %($entry.expires.toTime.toUnix)
      entryObj["created"] = %($entry.created.toTime.toUnix)
      entryObj["lastAccessed"] = %($entry.lastAccessed.toTime.toUnix)
      entryObj["accessCount"] = %entry.accessCount
      
      entries[key] = entryObj
  
  # ディスクキャッシュからエントリを取得
  if cache.cacheType in [ctDisk, ctHybrid] and cache.diskCache != nil:
    let diskEntries = await cache.diskCache.getAllEntries()
    for key, entry in diskEntries:
      if not entries.hasKey(key):  # メモリにあるものは上書きしない
        var entryObj = newJObject()
        entryObj["type"] = %"disk"
        entryObj["content"] = %entry.content
        entryObj["expires"] = %($entry.expires.toTime.toUnix)
        entryObj["created"] = %($entry.created.toTime.toUnix)
        entryObj["lastAccessed"] = %($entry.lastAccessed.toTime.toUnix)
        entryObj["accessCount"] = %entry.accessCount
        
        entries[key] = entryObj
  
  return $entries

proc importEntries*(cache: BrowserCache, jsonData: string): Future[int] {.async.} =
  ## JSONデータからキャッシュエントリをインポートする
  ## 戻り値: インポートされたエントリの数
  var importCount = 0
  
  try:
    let entries = parseJson(jsonData)
    for key, entryData in entries:
      let entryType = entryData["type"].getStr()
      let content = entryData["content"].getStr()
      let expires = entryData["expires"].getStr().parseInt().fromUnix().toTime()
      let created = entryData["created"].getStr().parseInt().fromUnix().toTime()
      let lastAccessed = entryData["lastAccessed"].getStr().parseInt().fromUnix().toTime()
      let accessCount = entryData["accessCount"].getInt()
      
      # TTLの計算
      let now = getTime()
      let ttl = max(0, (expires - now).inSeconds.int)
      
      # メタデータの構築
      var metadata = CacheEntryMetadata(
        key: key,
        expires: expires,
        created: created,
        lastAccessed: lastAccessed,
        accessCount: accessCount,
        size: content.len
      )
      
      # キャッシュに保存
      if entryType == "memory" and cache.cacheType in [ctMemory, ctHybrid]:
        cache.memoryCache.set(key, content, metadata, ttl)
        importCount += 1
      elif entryType == "disk" and cache.cacheType in [ctDisk, ctHybrid]:
        await cache.diskCache.set(key, content, metadata, ttl)
        importCount += 1
  except:
    # インポートエラー
    echo "キャッシュエントリのインポート中にエラーが発生しました: ", getCurrentExceptionMsg()
  
  return importCount

# ユーティリティ関数
proc generateCacheKey*(url: string, headers: Table[string, string] = initTable[string, string]()): string =
  ## URLとヘッダーからキャッシュキーを生成する
  var key = url
  
  # Vary ヘッダーに基づくキー拡張
  if headers.hasKey("Vary"):
    let varyHeaders = headers["Vary"].split(',')
    for header in varyHeaders:
      let headerName = header.strip()
      if headers.hasKey(headerName):
        key &= "|" & headerName & "=" & headers[headerName]
  
  return $hash(key)

proc extractCacheMetadata*(headers: Table[string, string]): CacheEntryMetadata =
  ## HTTPヘッダーからキャッシュメタデータを抽出する
  result = CacheEntryMetadata(
    contentType: if headers.hasKey("Content-Type"): headers["Content-Type"] else: "",
    etag: if headers.hasKey("ETag"): headers["ETag"] else: "",
    lastModified: if headers.hasKey("Last-Modified"): headers["Last-Modified"] else: "",
    headers: headers,
    created: getTime(),
    lastAccessed: getTime(),
    accessCount: 0
  )
  
  # 有効期限の計算
  var maxAge = -1
  if headers.hasKey("Cache-Control"):
    let cacheControl = headers["Cache-Control"]
    let parts = cacheControl.split(',')
    for part in parts:
      let trimmed = part.strip().toLowerAscii()
      if trimmed.startsWith("max-age="):
        try:
          maxAge = parseInt(trimmed.split('=')[1])
        except:
          maxAge = -1
  
  # Expires ヘッダーを使用
  if maxAge == -1 and headers.hasKey("Expires"):
    try:
      let expiresStr = headers["Expires"]
      # RFC 7231, 7232に準拠したHTTP日付形式をパース
      # 一般的な形式: "Sun, 06 Nov 1994 08:49:37 GMT"
      let dateFormat = initTimeFormat("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
      let expireTime = parse(expiresStr, dateFormat, utc())
      
      # 現在時刻と比較して有効期限を設定
      let now = getTime()
      if expireTime > now:
        result.expires = expireTime
      else:
        # 過去の日付の場合は期限切れとして扱う
        result.expires = now
    except:
      # パースエラーの場合はヒューリスティック有効期限を設定
      result.expires = getTime() + initDuration(hours = 1)
      result.isHeuristicExpiration = true
  elif maxAge > 0:
    # max-ageを使用
    result.expires = getTime() + initDuration(seconds = maxAge)
    result.maxAge = maxAge
  else:
    # Cache-ControlとExpiresがない場合のヒューリスティック計算
    if headers.hasKey("Last-Modified"):
      try:
        let lastModifiedStr = headers["Last-Modified"]
        let dateFormat = initTimeFormat("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
        let lastModifiedTime = parse(lastModifiedStr, dateFormat, utc())
        
        # Last-Modifiedからの経過時間の10%を有効期限として使用（RFC 7234 4.2.2）
        let now = getTime()
        let age = now - lastModifiedTime
        let heuristicTTL = age.inSeconds.int * 0.1
        
        # 最小1時間、最大24時間に制限
        let ttlSeconds = max(3600, min(86400, heuristicTTL.int))
        result.expires = now + initDuration(seconds = ttlSeconds)
        result.isHeuristicExpiration = true
      except:
        # パースエラーの場合はデフォルト値
        result.expires = getTime() + initDuration(hours = 1)
        result.isHeuristicExpiration = true
    else:
      # 情報不足の場合はデフォルト値
      result.expires = getTime() + initDuration(hours = 1)
      result.isHeuristicExpiration = true
  
  # 追加のキャッシュ制御ディレクティブを処理
  if headers.hasKey("Cache-Control"):
    let cacheControl = headers["Cache-Control"].toLowerAscii()
    
    # no-store, no-cache, must-revalidateなどの処理
    if "no-store" in cacheControl:
      result.noStore = true
    if "no-cache" in cacheControl:
      result.noCache = true
    if "must-revalidate" in cacheControl:
      result.mustRevalidate = true
    if "private" in cacheControl:
      result.isPrivate = true
    if "public" in cacheControl:
      result.isPublic = true
    
    # s-maxage処理
    let sMaxAgeMatch = cacheControl.find(re"s-maxage=(\d+)")
    if sMaxAgeMatch.len > 0:
      try:
        let sMaxAge = parseInt(sMaxAgeMatch[0].split('=')[1])
        if sMaxAge > 0:
          # 共有キャッシュ用の有効期限を設定
          result.sMaxAge = sMaxAge
          if not result.isPrivate:  # privateでない場合のみs-maxageを適用
            result.expires = getTime() + initDuration(seconds = sMaxAge)
      except:
        discard
  
  # Pragma: no-cacheの処理
  if headers.hasKey("Pragma") and "no-cache" in headers["Pragma"].toLowerAscii():
    result.noCache = true
  
  return result

when isMainModule:
  # テスト用のメイン関数
  proc testCache() {.async.} =
    echo "ブラウザキャッシュのテスト"
    
    # ハイブリッドキャッシュの作成
    let cache = newBrowserCache(
      cacheType = ctHybrid,
      policy = cpLRU,
      maxMemorySize = 10,  # 10MB
      maxDiskSize = 100,   # 100MB
      ttl = 3600           # 1時間
    )
    
    # キャッシュにデータを設定
    echo "キャッシュにデータを設定中..."
    await cache.set("test1", "これはテストデータ1です")
    await cache.set("test2", "これはテストデータ2です")
    
    # キャッシュからデータを取得
    echo "キャッシュからデータを取得中..."
    let result1 = await cache.get("test1")
    if result1.found:
      echo "test1: ", result1.content
    else:
      echo "test1が見つかりませんでした"
    
    let result2 = await cache.get("test2")
    if result2.found:
      echo "test2: ", result2.content
    else:
      echo "test2が見つかりませんでした"
    
    # 存在しないキー
    let result3 = await cache.get("test3")
    if result3.found:
      echo "test3: ", result3.content
    else:
      echo "test3が見つかりませんでした"
    
    # 統計の表示
    let stats = cache.getStats()
    echo "キャッシュ統計:"
    echo " - ヒット数: ", stats.hits
    echo " - ミス数: ", stats.misses
    echo " - ヒット率: ", cache.getHitRatio(), "%"
    echo " - メモリサイズ: ", stats.memorySize, " バイト"
    echo " - ディスクサイズ: ", stats.diskSize, " バイト"
    echo " - 総サイズ: ", stats.totalSize, " バイト"
    
    # キャッシュのクリア
    echo "キャッシュをクリア中..."
    await cache.clear()
    
    # クリア後のチェック
    let result4 = await cache.get("test1")
    if not result4.found:
      echo "クリア後、test1は見つかりませんでした（期待通り）"
    
  # テスト実行
  waitFor testCache() 