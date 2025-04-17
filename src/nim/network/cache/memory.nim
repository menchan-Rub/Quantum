import std/[tables, times, hashes, strutils, options, algorithm, sequtils]

type
  CacheEntryMetadata* = object
    contentType*: string        # コンテンツタイプ
    etag*: string               # ETag
    lastModified*: string       # 最終更新日時
    expires*: Time              # 有効期限
    maxAge*: int                # max-age（秒）
    headers*: Table[string, string] # 関連するHTTPヘッダー

  CacheEntry* = object
    content*: string            # キャッシュされているコンテンツ
    metadata*: CacheEntryMetadata # メタデータ
    created*: Time              # 作成日時
    expires*: Time              # 有効期限
    lastAccessed*: Time         # 最終アクセス日時
    accessCount*: int           # アクセス回数
    size*: int                  # エントリのサイズ（バイト）

  MemoryCache* = ref object
    entries*: Table[string, CacheEntry]
    maxSize*: int               # キャッシュの最大サイズ（バイト）
    currentSize*: int           # 現在のキャッシュサイズ（バイト）
    defaultTtl*: int            # デフォルトのTTL（秒）
    hitCount*: int              # ヒット数
    missCount*: int             # ミス数
    evictionCount*: int         # 追い出し数
    creationTime*: Time         # キャッシュの作成日時

proc newMemoryCache*(maxSizeMb: int = 100, defaultTtlSeconds: int = 3600): MemoryCache =
  ## 新しいメモリキャッシュを作成する
  ## maxSizeMb: キャッシュの最大サイズ（MB単位）
  ## defaultTtlSeconds: キャッシュエントリーのデフォルト有効期間（秒単位）
  result = MemoryCache(
    entries: initTable[string, CacheEntry](),
    maxSize: maxSizeMb * 1024 * 1024,  # MBをバイトに変換
    currentSize: 0,
    defaultTtl: defaultTtlSeconds,
    hitCount: 0,
    missCount: 0,
    evictionCount: 0,
    creationTime: getTime()
  )

proc getEntryMetadata*(self: MemoryCache, key: string): CacheEntryMetadata =
  ## エントリのメタデータを取得する
  if self.entries.hasKey(key):
    return self.entries[key].metadata
  else:
    return CacheEntryMetadata()

proc calculateEntrySize(key: string, entry: CacheEntry): int =
  ## エントリのメモリ使用量を概算する
  result = key.len + entry.content.len
  
  # メタデータサイズの概算
  result += entry.metadata.contentType.len
  result += entry.metadata.etag.len
  result += entry.metadata.lastModified.len
  
  # ヘッダーサイズの概算
  for k, v in entry.metadata.headers:
    result += k.len + v.len
  
  # 基本的なオブジェクトのオーバーヘッド（概算）
  result += 128

proc has*(self: MemoryCache, key: string): bool =
  ## キャッシュにキーが存在し、かつ有効期限内かを確認する
  if not self.entries.hasKey(key):
    return false
    
  let entry = self.entries[key]
  let now = getTime()
  
  # 期限切れかどうかを確認
  if now > entry.expires:
    # 自動的に期限切れのエントリを削除
    self.currentSize -= calculateEntrySize(key, entry)
    self.entries.del(key)
    return false
    
  return true

proc get*(self: MemoryCache, key: string): string =
  ## キャッシュからコンテンツを取得する
  if not self.has(key):
    self.missCount += 1
    return ""
    
  var entry = self.entries[key]
  # アクセス統計を更新
  entry.lastAccessed = getTime()
  entry.accessCount += 1
  self.entries[key] = entry
  
  self.hitCount += 1
  return entry.content

proc set*(self: MemoryCache, key: string, content: string, metadata: CacheEntryMetadata = CacheEntryMetadata(), ttl: int = -1) =
  ## コンテンツをキャッシュに保存する
  ## ttl: このエントリの有効期間（秒）。-1の場合はデフォルト値を使用
  
  # 新しいエントリを準備
  let now = getTime()
  let actualTtl = if ttl < 0: self.defaultTtl else: ttl
  
  let entry = CacheEntry(
    content: content,
    metadata: metadata,
    created: now,
    expires: now + initDuration(seconds = actualTtl),
    lastAccessed: now,
    accessCount: 0,
    size: content.len
  )
  
  let entrySize = calculateEntrySize(key, entry)
  
  # キャッシュサイズをチェック
  if entrySize > self.maxSize:
    # サイズが大きすぎる場合は保存しない
    return
  
  # 既存のエントリを削除して現在のサイズを調整
  if self.entries.hasKey(key):
    self.currentSize -= calculateEntrySize(key, self.entries[key])
    self.entries.del(key)
    
  # 期限切れのエントリをクリーンアップ
  self.prune()
    
  # スペースが足りないなら、最も古いエントリを削除
  while self.currentSize + entrySize > self.maxSize and self.entries.len > 0:
    var oldestKey = ""
    var oldestTime = now
    
    for k, v in self.entries:
      if v.lastAccessed < oldestTime:
        oldestTime = v.lastAccessed
        oldestKey = k
        
    if oldestKey != "":
      self.currentSize -= calculateEntrySize(oldestKey, self.entries[oldestKey])
      self.entries.del(oldestKey)
      self.evictionCount += 1
    else:
      break
      
  # 新しいエントリを追加
  self.entries[key] = entry
  self.currentSize += entrySize

proc set*(self: MemoryCache, key: string, content: string, ttl: int = -1) =
  ## コンテンツをキャッシュに保存する（簡易版）
  let metadata = CacheEntryMetadata()
  self.set(key, content, metadata, ttl)

proc remove*(self: MemoryCache, key: string): bool =
  ## キャッシュからエントリを削除する
  ## 戻り値: 削除に成功したかどうか
  if not self.entries.hasKey(key):
    return false
    
  self.currentSize -= calculateEntrySize(key, self.entries[key])
  self.entries.del(key)
  return true

proc clear*(self: MemoryCache) =
  ## キャッシュを完全にクリアする
  self.entries.clear()
  self.currentSize = 0

proc prune*(self: MemoryCache): int =
  ## 期限切れのエントリを削除する
  ## 戻り値: 削除されたエントリの数
  let now = getTime()
  var removedCount = 0
  var keysToRemove: seq[string] = @[]
  
  # 期限切れのエントリを特定
  for key, entry in self.entries:
    if now > entry.expires:
      keysToRemove.add(key)
  
  # 期限切れのエントリを削除
  for key in keysToRemove:
    self.currentSize -= calculateEntrySize(key, self.entries[key])
    self.entries.del(key)
    removedCount += 1
  
  return removedCount

proc getStats*(self: MemoryCache): tuple[entries: int, size: int, utilization: float, hitCount: int, missCount: int, hitRatio: float] =
  ## キャッシュの統計情報を取得する
  let utilization = if self.maxSize > 0: self.currentSize.float / self.maxSize.float * 100.0 else: 0.0
  let total = self.hitCount + self.missCount
  let hitRatio = if total > 0: self.hitCount.float / total.float * 100.0 else: 0.0
  
  return (
    entries: self.entries.len, 
    size: self.currentSize, 
    utilization: utilization,
    hitCount: self.hitCount,
    missCount: self.missCount,
    hitRatio: hitRatio
  )

proc getCurrentSize*(self: MemoryCache): int =
  ## 現在のキャッシュサイズを取得する
  return self.currentSize

proc getMaxSize*(self: MemoryCache): int =
  ## キャッシュの最大サイズを取得する
  return self.maxSize

proc setMaxSize*(self: MemoryCache, maxSizeMb: int) =
  ## キャッシュの最大サイズを設定する
  self.maxSize = maxSizeMb * 1024 * 1024
  
  # サイズ変更後に必要に応じてエントリを削除
  while self.currentSize > self.maxSize and self.entries.len > 0:
    var oldestKey = ""
    var oldestTime = getTime()
    
    for k, v in self.entries:
      if v.lastAccessed < oldestTime:
        oldestTime = v.lastAccessed
        oldestKey = k
        
    if oldestKey != "":
      self.currentSize -= calculateEntrySize(oldestKey, self.entries[oldestKey])
      self.entries.del(oldestKey)
      self.evictionCount += 1
    else:
      break

proc setDefaultTtl*(self: MemoryCache, ttlSeconds: int) =
  ## デフォルトのTTLを設定する
  self.defaultTtl = ttlSeconds

proc getKeysByAccessTime*(self: MemoryCache, ascending: bool = true): seq[string] =
  ## アクセス時間でソートされたキーのリストを取得する
  ## ascending: true=古い順、false=新しい順
  var keys: seq[tuple[key: string, time: Time]] = @[]
  
  for key, entry in self.entries:
    keys.add((key: key, time: entry.lastAccessed))
  
  if ascending:
    keys.sort(proc(x, y: tuple[key: string, time: Time]): int = cmp(x.time, y.time))
  else:
    keys.sort(proc(x, y: tuple[key: string, time: Time]): int = cmp(y.time, x.time))
  
  return keys.mapIt(it.key)

proc getKeysByCreateTime*(self: MemoryCache, ascending: bool = true): seq[string] =
  ## 作成時間でソートされたキーのリストを取得する
  ## ascending: true=古い順、false=新しい順
  var keys: seq[tuple[key: string, time: Time]] = @[]
  
  for key, entry in self.entries:
    keys.add((key: key, time: entry.created))
  
  if ascending:
    keys.sort(proc(x, y: tuple[key: string, time: Time]): int = cmp(x.time, y.time))
  else:
    keys.sort(proc(x, y: tuple[key: string, time: Time]): int = cmp(y.time, x.time))
  
  return keys.mapIt(it.key)

proc getKeysByAccessCount*(self: MemoryCache, ascending: bool = true): seq[string] =
  ## アクセス回数でソートされたキーのリストを取得する
  ## ascending: true=少ない順、false=多い順
  var keys: seq[tuple[key: string, count: int]] = @[]
  
  for key, entry in self.entries:
    keys.add((key: key, count: entry.accessCount))
  
  if ascending:
    keys.sort(proc(x, y: tuple[key: string, count: int]): int = cmp(x.count, y.count))
  else:
    keys.sort(proc(x, y: tuple[key: string, count: int]): int = cmp(y.count, x.count))
  
  return keys.mapIt(it.key)

proc getKeysBySize*(self: MemoryCache, ascending: bool = true): seq[string] =
  ## サイズでソートされたキーのリストを取得する
  ## ascending: true=小さい順、false=大きい順
  var keys: seq[tuple[key: string, size: int]] = @[]
  
  for key, entry in self.entries:
    keys.add((key: key, size: entry.size))
  
  if ascending:
    keys.sort(proc(x, y: tuple[key: string, size: int]): int = cmp(x.size, y.size))
  else:
    keys.sort(proc(x, y: tuple[key: string, size: int]): int = cmp(y.size, x.size))
  
  return keys.mapIt(it.key)

proc getEntryExpiration*(self: MemoryCache, key: string): Option[Time] =
  ## エントリの有効期限を取得する
  if not self.entries.hasKey(key):
    return none(Time)
  return some(self.entries[key].expires)

proc touchEntry*(self: MemoryCache, key: string): bool =
  ## エントリのアクセス時間を更新する
  ## 戻り値: 更新に成功したかどうか
  if not self.entries.hasKey(key):
    return false
    
  var entry = self.entries[key]
  entry.lastAccessed = getTime()
  entry.accessCount += 1
  self.entries[key] = entry
  return true

proc updateExpiration*(self: MemoryCache, key: string, ttl: int): bool =
  ## エントリの有効期限を更新する
  ## 戻り値: 更新に成功したかどうか
  if not self.entries.hasKey(key):
    return false
    
  var entry = self.entries[key]
  entry.expires = getTime() + initDuration(seconds = ttl)
  self.entries[key] = entry
  return true

proc getAllEntries*(self: MemoryCache): Table[string, CacheEntry] =
  ## 全てのエントリを取得する
  return self.entries

proc getOldestEntry*(self: MemoryCache): Option[tuple[key: string, entry: CacheEntry]] =
  ## 最も古いエントリを取得する
  if self.entries.len == 0:
    return none(tuple[key: string, entry: CacheEntry])
    
  var oldestKey = ""
  var oldestTime = getTime() + initDuration(days = 365*100)  # 100年後
  
  for key, entry in self.entries:
    if entry.created < oldestTime:
      oldestTime = entry.created
      oldestKey = key
  
  if oldestKey != "":
    return some((key: oldestKey, entry: self.entries[oldestKey]))
  
  return none(tuple[key: string, entry: CacheEntry])

proc getNewestEntry*(self: MemoryCache): Option[tuple[key: string, entry: CacheEntry]] =
  ## 最も新しいエントリを取得する
  if self.entries.len == 0:
    return none(tuple[key: string, entry: CacheEntry])
    
  var newestKey = ""
  var newestTime = getTime() - initDuration(days = 365*100)  # 100年前
  
  for key, entry in self.entries:
    if entry.created > newestTime:
      newestTime = entry.created
      newestKey = key
  
  if newestKey != "":
    return some((key: newestKey, entry: self.entries[newestKey]))
  
  return none(tuple[key: string, entry: CacheEntry])

when isMainModule:
  # テスト用のメイン関数
  proc testMemoryCache() =
    echo "メモリキャッシュのテスト"
    
    # メモリキャッシュの作成
    let cache = newMemoryCache(10, 3600)  # 10MB, 1時間
    
    # キャッシュにデータを設定
    echo "キャッシュにデータを設定中..."
    cache.set("key1", "バリュー1")
    cache.set("key2", "バリュー2")
    cache.set("key3", "バリュー3")
    
    # キャッシュからデータを取得
    echo "キャッシュからデータを取得中..."
    echo "key1: ", cache.get("key1")
    echo "key2: ", cache.get("key2")
    echo "key3: ", cache.get("key3")
    echo "key4: ", cache.get("key4")  # 存在しないキー
    
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
    
    # アクセス時間順にソート
    echo "アクセス時間でソートされたキー:"
    let sortedKeys = cache.getKeysByAccessTime()
    for key in sortedKeys:
      echo " - ", key
    
    # キャッシュのクリア
    echo "キャッシュをクリア中..."
    cache.clear()
    
    # クリア後の確認
    echo "クリア後、key1存在: ", cache.has("key1")
  
  # テスト実行
  testMemoryCache() 