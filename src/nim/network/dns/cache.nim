import std/[tables, times, hashes, os, json, strutils, streams]
import records

type
  DnsCacheStats* = object
    ## DNSキャッシュの統計情報
    hits*: int         # キャッシュヒット数
    misses*: int       # キャッシュミス数
    insertions*: int   # キャッシュ挿入数
    evictions*: int    # キャッシュ削除数
    expirations*: int  # 期限切れ数

  DnsCache* = ref object
    ## DNSキャッシュ
    records: Table[string, seq[DnsRecord]]  # ドメイン名をキーとするDNSレコードのテーブル
    stats: DnsCacheStats                    # キャッシュ統計情報
    maxEntries: int                         # キャッシュの最大エントリ数
    persistPath: string                     # キャッシュ永続化のパス

proc newDnsCache*(maxEntries: int = 1000, persistPath: string = ""): DnsCache =
  ## 新しいDNSキャッシュを生成
  result = DnsCache(
    records: initTable[string, seq[DnsRecord]](),
    stats: DnsCacheStats(),
    maxEntries: maxEntries,
    persistPath: persistPath
  )

proc generateCacheKey(domain: string, recordType: DnsRecordType): string =
  ## キャッシュキーを生成
  result = domain.toLowerAscii & "|" & $recordType

proc add*(cache: DnsCache, record: DnsRecord) =
  ## キャッシュにレコードを追加
  let domain = record.domain.toLowerAscii
  
  # ドメインのレコードリストを取得または作成
  if not cache.records.hasKey(domain):
    cache.records[domain] = @[]
  
  # 既存の同じタイプのレコードを削除
  var recordsOfSameType = 0
  cache.records[domain] = cache.records[domain].filterIt(
    it.recordType != record.recordType or (
      inc(recordsOfSameType);
      false
    )
  )
  
  # 新しいレコードを追加
  cache.records[domain].add(record)
  inc(cache.stats.insertions)
  
  # キャッシュサイズ制限を適用
  if cache.records.len > cache.maxEntries:
    # 最も古いエントリを削除
    var oldestDomain = ""
    var oldestTime = high(Time)
    
    for domain, records in cache.records:
      for record in records:
        if record.timestamp < oldestTime:
          oldestTime = record.timestamp
          oldestDomain = domain
    
    if oldestDomain != "":
      cache.records.del(oldestDomain)
      inc(cache.stats.evictions)

proc get*(cache: DnsCache, domain: string, recordType: DnsRecordType): seq[DnsRecord] =
  ## ドメインと指定されたレコードタイプに一致するキャッシュエントリを取得
  let domain = domain.toLowerAscii
  result = @[]
  
  if cache.records.hasKey(domain):
    let now = getTime()
    var expiredRecords = 0
    
    # 指定タイプの有効なレコードをフィルタリング
    for record in cache.records[domain]:
      if record.recordType == recordType:
        let expiryTime = record.timestamp + initDuration(seconds = record.ttl)
        if now <= expiryTime:
          result.add(record)
        else:
          inc(expiredRecords)
    
    # 期限切れのレコードがある場合、統計を更新
    if expiredRecords > 0:
      inc(cache.stats.expirations, expiredRecords)
    
    # 結果に基づいて統計を更新
    if result.len > 0:
      inc(cache.stats.hits)
    else:
      inc(cache.stats.misses)
  else:
    inc(cache.stats.misses)

proc getAllForDomain*(cache: DnsCache, domain: string): seq[DnsRecord] =
  ## ドメインに一致する全てのキャッシュエントリを取得
  let domain = domain.toLowerAscii
  result = @[]
  
  if cache.records.hasKey(domain):
    let now = getTime()
    var validRecords: seq[DnsRecord] = @[]
    var expiredRecords = 0
    
    # 有効なレコードをフィルタリング
    for record in cache.records[domain]:
      let expiryTime = record.timestamp + initDuration(seconds = record.ttl)
      if now <= expiryTime:
        validRecords.add(record)
      else:
        inc(expiredRecords)
    
    # キャッシュ更新と統計更新
    if validRecords.len > 0:
      cache.records[domain] = validRecords
      inc(cache.stats.hits)
      result = validRecords
    else:
      cache.records.del(domain)  # 全てのレコードが期限切れならエントリを削除
      inc(cache.stats.misses)
    
    # 期限切れのレコードがある場合、統計を更新
    if expiredRecords > 0:
      inc(cache.stats.expirations, expiredRecords)
  else:
    inc(cache.stats.misses)

proc clear*(cache: DnsCache) =
  ## キャッシュを消去
  cache.records.clear()
  cache.stats = DnsCacheStats()

proc getStats*(cache: DnsCache): DnsCacheStats =
  ## キャッシュ統計を取得
  return cache.stats

proc getSize*(cache: DnsCache): int =
  ## キャッシュに含まれるドメイン数を取得
  return cache.records.len

proc getTotalRecords*(cache: DnsCache): int =
  ## キャッシュ内の総レコード数を取得
  result = 0
  for domain, records in cache.records:
    result += records.len

proc saveToDisk*(cache: DnsCache) =
  ## キャッシュをディスクに保存
  if cache.persistPath == "":
    return
  
  try:
    # 親ディレクトリを作成
    createDir(parentDir(cache.persistPath))
    
    # キャッシュデータをJSONに変換
    var jsonData = newJObject()
    
    # レコードデータを追加
    var recordsArray = newJArray()
    for domain, records in cache.records:
      for record in records:
        var recordObj = newJObject()
        recordObj["domain"] = %record.domain
        recordObj["recordType"] = %($record.recordType)
        recordObj["ttl"] = %record.ttl
        recordObj["data"] = %record.data
        recordObj["timestamp"] = %($record.timestamp)
        recordsArray.add(recordObj)
    
    jsonData["records"] = recordsArray
    
    # 統計情報を追加
    var statsObj = newJObject()
    statsObj["hits"] = %cache.stats.hits
    statsObj["misses"] = %cache.stats.misses
    statsObj["insertions"] = %cache.stats.insertions
    statsObj["evictions"] = %cache.stats.evictions
    statsObj["expirations"] = %cache.stats.expirations
    
    jsonData["stats"] = statsObj
    jsonData["maxEntries"] = %cache.maxEntries
    
    # JSONをファイルに書き込み
    let file = newFileStream(cache.persistPath, fmWrite)
    if file != nil:
      file.write($jsonData)
      file.close()
  except:
    # 保存エラーは無視
    discard

proc loadFromDisk*(cache: DnsCache): bool =
  ## ディスクからキャッシュを読み込み
  if cache.persistPath == "" or not fileExists(cache.persistPath):
    return false
  
  try:
    # ファイルからJSONを読み込み
    let file = newFileStream(cache.persistPath, fmRead)
    if file == nil:
      return false
    
    let jsonStr = file.readAll()
    file.close()
    
    let jsonData = parseJson(jsonStr)
    
    # レコードデータを読み込み
    cache.records.clear()
    let recordsArray = jsonData["records"]
    for recordItem in recordsArray:
      let domain = recordItem["domain"].getStr()
      let recordTypeStr = recordItem["recordType"].getStr()
      let ttl = recordItem["ttl"].getInt()
      let data = recordItem["data"].getStr()
      let timestampStr = recordItem["timestamp"].getStr()
      
      # レコードタイプを文字列から列挙型に変換
      var recordType: DnsRecordType
      try:
        recordType = parseEnum[DnsRecordType](recordTypeStr)
      except:
        continue  # 無効なレコードタイプは無視
      
      # タイムスタンプを解析
      var timestamp: Time
      try:
        timestamp = parse(timestampStr, "yyyy-MM-dd'T'HH:mm:sszzz")
      except:
        timestamp = getTime()  # 解析エラー時は現在時刻を使用
      
      # レコードの作成と追加
      let record = DnsRecord(
        domain: domain,
        recordType: recordType,
        ttl: ttl,
        data: data,
        timestamp: timestamp
      )
      
      if not cache.records.hasKey(domain):
        cache.records[domain] = @[]
      
      cache.records[domain].add(record)
    
    # 統計情報を読み込み
    if jsonData.hasKey("stats"):
      let statsObj = jsonData["stats"]
      cache.stats.hits = statsObj["hits"].getInt()
      cache.stats.misses = statsObj["misses"].getInt()
      cache.stats.insertions = statsObj["insertions"].getInt()
      cache.stats.evictions = statsObj["evictions"].getInt()
      cache.stats.expirations = statsObj["expirations"].getInt()
    
    # 最大エントリ数を読み込み
    if jsonData.hasKey("maxEntries"):
      cache.maxEntries = jsonData["maxEntries"].getInt()
    
    return true
  except:
    # 読み込みエラーは無視し、空のキャッシュを使用
    return false

proc cleanup*(cache: DnsCache) =
  ## 期限切れのレコードをクリーンアップ
  let now = getTime()
  var domainsToRemove: seq[string] = @[]
  var expiredRecords = 0
  
  # 全てのドメインをチェック
  for domain, records in cache.records:
    var validRecords: seq[DnsRecord] = @[]
    
    # 有効なレコードをフィルタリング
    for record in records:
      let expiryTime = record.timestamp + initDuration(seconds = record.ttl)
      if now <= expiryTime:
        validRecords.add(record)
      else:
        inc(expiredRecords)
    
    # 有効なレコードがある場合は更新、なければ削除マーク
    if validRecords.len > 0:
      cache.records[domain] = validRecords
    else:
      domainsToRemove.add(domain)
  
  # 削除マークされたドメインを削除
  for domain in domainsToRemove:
    cache.records.del(domain)
  
  # 統計を更新
  if expiredRecords > 0:
    inc(cache.stats.expirations, expiredRecords)

proc dumpStats*(cache: DnsCache): string =
  ## キャッシュ統計情報を文字列に変換
  result = "DNS Cache Statistics:\n"
  result &= "  Domains in cache: " & $cache.records.len & "\n"
  result &= "  Total records: " & $cache.getTotalRecords() & "\n"
  result &= "  Hits: " & $cache.stats.hits & "\n"
  result &= "  Misses: " & $cache.stats.misses & "\n"
  result &= "  Hit ratio: " & (if cache.stats.hits + cache.stats.misses > 0: 
    formatFloat(cache.stats.hits.float / (cache.stats.hits + cache.stats.misses).float * 100, ffDecimal, 2) & "%" 
    else: "N/A") & "\n"
  result &= "  Insertions: " & $cache.stats.insertions & "\n"
  result &= "  Evictions: " & $cache.stats.evictions & "\n"
  result &= "  Expirations: " & $cache.stats.expirations 