import std/[times, tables, strutils, options]
import ../policy/cache_policy

type
  MemoryCache* = object
    ## メモリキャッシュ
    maxSizeMb*: int                    # 最大サイズ（MB）
    currentSizeBytes*: int             # 現在のサイズ（バイト）
    entries*: Table[string, CacheEntry]  # キャッシュエントリ
    accessOrder*: seq[string]          # アクセス順序（LRU実装用）

  CacheStats* = object
    ## キャッシュの統計情報
    hits*: int                         # ヒット数
    misses*: int                       # ミス数
    evictions*: int                    # 追い出し数
    currentSizeBytes*: int             # 現在のサイズ（バイト）
    maxSizeBytes*: int                 # 最大サイズ（バイト）

proc newMemoryCache*(maxSizeMb: int): MemoryCache =
  ## 新しいメモリキャッシュを作成する
  result = MemoryCache(
    maxSizeMb: maxSizeMb,
    currentSizeBytes: 0,
    entries: initTable[string, CacheEntry](),
    accessOrder: @[]
  )

proc calculateEntrySize*(entry: CacheEntry): int =
  ## エントリのサイズを計算する（概算）
  var size = 0
  
  # URL
  size += entry.url.len
  
  # メソッド
  size += entry.method.len
  
  # ヘッダー
  for k, v in entry.headers:
    size += k.len + v.len
  
  # ボディ
  size += entry.body.len
  
  # その他のメタデータ
  size += entry.lastModified.len
  size += entry.etag.len
  
  # Varyヘッダー
  for k, v in entry.varyHeaders:
    size += k.len + v.len
  
  return size

proc updateAccessOrder*(cache: var MemoryCache, key: string) =
  ## アクセス順序を更新する
  # 既存のエントリを削除
  let index = cache.accessOrder.find(key)
  if index >= 0:
    cache.accessOrder.delete(index)
  
  # 先頭に追加
  cache.accessOrder.insert(key, 0)

proc evictEntries*(cache: var MemoryCache, requiredBytes: int) =
  ## 必要なバイト数を確保するためにエントリを追い出す
  var bytesToFree = requiredBytes
  
  while bytesToFree > 0 and cache.accessOrder.len > 0:
    # 最も古いエントリを取得
    let oldestKey = cache.accessOrder.pop()
    let entry = cache.entries[oldestKey]
    
    # エントリのサイズを計算
    let entrySize = calculateEntrySize(entry)
    
    # エントリを削除
    cache.entries.del(oldestKey)
    cache.currentSizeBytes -= entrySize
    bytesToFree -= entrySize

proc put*(cache: var MemoryCache, key: string, entry: CacheEntry) =
  ## エントリをキャッシュに保存する
  let entrySize = calculateEntrySize(entry)
  
  # 既存のエントリがある場合は削除
  if cache.entries.hasKey(key):
    let oldEntry = cache.entries[key]
    let oldSize = calculateEntrySize(oldEntry)
    cache.currentSizeBytes -= oldSize
    
    # アクセス順序から削除
    let index = cache.accessOrder.find(key)
    if index >= 0:
      cache.accessOrder.delete(index)
  
  # サイズ制限をチェック
  let maxSizeBytes = cache.maxSizeMb * 1024 * 1024
  if cache.currentSizeBytes + entrySize > maxSizeBytes:
    # 必要なバイト数を計算
    let requiredBytes = cache.currentSizeBytes + entrySize - maxSizeBytes
    evictEntries(cache, requiredBytes)
  
  # エントリを保存
  cache.entries[key] = entry
  cache.currentSizeBytes += entrySize
  
  # アクセス順序を更新
  updateAccessOrder(cache, key)

proc get*(cache: var MemoryCache, key: string): Option[CacheEntry] =
  ## キャッシュからエントリを取得する
  if cache.entries.hasKey(key):
    let entry = cache.entries[key]
    
    # アクセス順序を更新
    updateAccessOrder(cache, key)
    
    return some(entry)
  
  return none(CacheEntry)

proc hasKey*(cache: MemoryCache, key: string): bool =
  ## キーが存在するかどうかを確認する
  return cache.entries.hasKey(key)

proc remove*(cache: var MemoryCache, key: string) =
  ## エントリをキャッシュから削除する
  if cache.entries.hasKey(key):
    let entry = cache.entries[key]
    let entrySize = calculateEntrySize(entry)
    
    # エントリを削除
    cache.entries.del(key)
    cache.currentSizeBytes -= entrySize
    
    # アクセス順序から削除
    let index = cache.accessOrder.find(key)
    if index >= 0:
      cache.accessOrder.delete(index)

proc clear*(cache: var MemoryCache) =
  ## キャッシュをクリアする
  cache.entries.clear()
  cache.accessOrder.setLen(0)
  cache.currentSizeBytes = 0

proc getStats*(cache: MemoryCache): string =
  ## キャッシュの統計情報を取得する
  result = "メモリキャッシュの統計情報:\n"
  result &= "エントリ数: " & $cache.entries.len & "\n"
  result &= "現在のサイズ: " & $(cache.currentSizeBytes / 1024 / 1024) & " MB\n"
  result &= "最大サイズ: " & $cache.maxSizeMb & " MB\n"

when isMainModule:
  # テスト用のメイン関数
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
    if retrieved.isSome:
      let cached = retrieved.get()
      echo "キャッシュから取得: ", cached.url
      echo "ステータスコード: ", cached.statusCode
      echo "ボディ: ", cached.body
    else:
      echo "キャッシュから取得できませんでした"
    
    # 統計情報を表示
    echo cache.getStats()
    
    # キャッシュをクリア
    cache.clear()
    echo "キャッシュをクリアしました"
  
  # テスト実行
  testMemoryCache() 