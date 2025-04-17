import std/[tables, hashes, times, strutils, sequtils]
import entry
import ../records

type
  DnsCacheKey* = object
    ## DNSキャッシュのキー
    domain*: string
    recordType*: DnsRecordType

  DnsCache* = ref object
    ## DNSレコードのキャッシュ
    entries*: Table[DnsCacheKey, seq[DnsRecord]]
    maxSize*: int  # 最大エントリ数
    pruneThreshold*: int  # プルーニングのしきい値
    negativeExpirySeconds: int # 否定的キャッシュの有効期間（秒）
    stats: DnsCacheStats

  DnsCacheStats* = object
    ## キャッシュ統計情報
    hits*: int             # キャッシュヒット数
    misses*: int           # キャッシュミス数
    inserts*: int          # 挿入数
    evictions*: int        # 追い出し数
    prunings*: int         # 自動削除数
    negativeCached*: int   # 否定的キャッシュエントリ数

proc hash*(key: DnsCacheKey): Hash =
  ## DNSCacheKeyのハッシュ関数
  var h: Hash = 0
  h = h !& hash(key.domain)
  h = h !& hash(key.recordType.int)
  result = !$h

proc `==`*(a, b: DnsCacheKey): bool =
  ## DNSCacheKeyの等価比較
  return a.domain == b.domain and a.recordType == b.recordType

proc makeKey(domain: string, recordType: DnsRecordType): string =
  ## キャッシュキーの生成
  return domain.toLowerAscii() & "|" & $recordType

proc newDnsCache*(maxSize: int = 1000, pruneThreshold: int = 1200, negativeExpirySeconds = 60): DnsCache =
  ## 新しいDNSキャッシュを作成
  result = DnsCache(
    entries: initTable[DnsCacheKey, seq[DnsRecord]](),
    maxSize: maxSize,
    pruneThreshold: pruneThreshold,
    negativeExpirySeconds: negativeExpirySeconds,
    stats: DnsCacheStats()
  )

proc size*(cache: DnsCache): int =
  ## キャッシュサイズを取得
  return cache.entries.len

proc clear*(cache: DnsCache) =
  ## キャッシュをクリア
  cache.entries.clear()
  # 統計情報はリセットしない

proc resetStats*(cache: DnsCache) =
  ## 統計情報をリセット
  cache.stats = DnsCacheStats()

proc getStats*(cache: DnsCache): DnsCacheStats =
  ## 統計情報を取得
  return cache.stats

proc pruneExpiredRecords*(cache: DnsCache) =
  ## 期限切れのレコードを削除
  var keys: seq[DnsCacheKey] = @[]
  
  # 期限切れのレコードを削除
  for key, records in cache.entries.mpairs:
    records.keepItIf(not it.isExpired())
    if records.len == 0:
      keys.add(key)
  
  # 空のエントリを削除
  for key in keys:
    cache.entries.del(key)

proc pruneCache*(cache: DnsCache) =
  ## キャッシュのサイズが閾値を超えた場合、プルーニングを実行
  if cache.entries.len >= cache.pruneThreshold:
    # まず期限切れのレコードを削除
    cache.pruneExpiredRecords()
    
    # それでもサイズが大きすぎる場合、最も古いエントリを削除
    if cache.entries.len > cache.maxSize:
      var oldestKeys: seq[DnsCacheKey] = @[]
      var oldestTimes: seq[Time] = @[]
      
      # 各エントリで最も古いタイムスタンプを見つける
      for key, records in cache.entries:
        if records.len > 0:
          var oldestTime = records[0].timestamp
          for record in records:
            if record.timestamp < oldestTime:
              oldestTime = record.timestamp
          
          oldestKeys.add(key)
          oldestTimes.add(oldestTime)
      
      # 削除するエントリ数を計算
      let toRemove = cache.entries.len - cache.maxSize
      
      # 最も古いエントリを特定
      var timeKeyPairs = zip(oldestTimes, oldestKeys)
      timeKeyPairs.sort() # 最も古い順にソート
      
      # 最古のエントリから指定数削除
      for i in 0..<min(toRemove, timeKeyPairs.len):
        let (_, key) = timeKeyPairs[i]
        cache.entries.del(key)

proc put*(cache: DnsCache, records: seq[DnsRecord]) =
  ## レコードをキャッシュに追加
  for record in records:
    let key = DnsCacheKey(domain: record.domain, recordType: record.recordType)
    
    if not cache.entries.hasKey(key):
      cache.entries[key] = @[]
    
    # 既存の同じレコードを更新または新しいレコードを追加
    var found = false
    for i in 0..<cache.entries[key].len:
      if cache.entries[key][i].data == record.data:
        cache.entries[key][i] = record
        found = true
        break
    
    if not found:
      cache.entries[key].add(record)
  
  # キャッシュサイズが閾値を超えたらプルーニング
  if cache.entries.len >= cache.pruneThreshold:
    cache.pruneCache()

proc get*(cache: DnsCache, domain: string, recordType: DnsRecordType): seq[DnsRecord] =
  ## ドメインとレコードタイプに基づいてキャッシュからレコードを取得
  let key = DnsCacheKey(domain: domain, recordType: recordType)
  
  if not cache.entries.hasKey(key):
    return @[]
  
  # 期限切れのレコードをフィルタリング
  var validRecords: seq[DnsRecord] = @[]
  for record in cache.entries[key]:
    if not record.isExpired():
      validRecords.add(record)
  
  # エントリを更新
  if validRecords.len != cache.entries[key].len:
    if validRecords.len > 0:
      cache.entries[key] = validRecords
    else:
      cache.entries.del(key)
  
  return validRecords

proc contains*(cache: DnsCache, domain: string, recordType: DnsRecordType): bool =
  ## 指定したドメインとレコードタイプのキャッシュエントリが存在するか確認
  let cachedRecords = cache.get(domain, recordType)
  return cachedRecords.len > 0

proc getAllEntries*(cache: DnsCache): seq[DnsCacheEntry] =
  ## すべてのキャッシュエントリを取得
  result = @[]
  for entry in cache.entries.values:
    result.add(entry)

proc getDomainEntries*(cache: DnsCache, domain: string): seq[DnsCacheEntry] =
  ## 指定ドメインのすべてのエントリを取得
  result = @[]
  let domainLower = domain.toLowerAscii()
  
  for key, entry in cache.entries:
    if entry.domain.toLowerAscii() == domainLower:
      result.add(entry)

proc dumpStats*(cache: DnsCache): string =
  ## キャッシュ統計情報を文字列として出力
  result = "DNS Cache Stats:\n"
  result &= "  Size: " & $cache.size() & "/" & $cache.maxSize & "\n"
  result &= "  Hits: " & $cache.stats.hits & "\n"
  result &= "  Misses: " & $cache.stats.misses & "\n" 
  result &= "  Hit ratio: " & (if cache.stats.hits + cache.stats.misses > 0: 
    $((cache.stats.hits.float / (cache.stats.hits + cache.stats.misses).float) * 100) & "%" 
    else: "N/A") & "\n"
  result &= "  Inserts: " & $cache.stats.inserts & "\n"
  result &= "  Evictions: " & $cache.stats.evictions & "\n"
  result &= "  Prunings: " & $cache.stats.prunings & "\n"
  result &= "  Negative entries: " & $cache.stats.negativeCached 