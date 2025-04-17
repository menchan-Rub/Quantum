import std/[asyncdispatch, tables, times, json, os, hashes, strutils, options, math, algorithm, random]
import ../resolver

const
  DEFAULT_CACHE_FILE = "dns_cache.json"
  DEFAULT_MAX_ENTRIES = 10000
  DEFAULT_ENTRY_TTL = 3600 # 1時間
  DEFAULT_NEGATIVE_TTL = 300 # 5分（解決失敗時のキャッシュ有効期間）
  DEFAULT_MIN_TTL = 60 # 最小TTL
  DEFAULT_MAX_TTL = 86400 # 最大TTL（1日）
  DEFAULT_CACHE_CLEANUP_INTERVAL = 600 # キャッシュクリーンアップ間隔（10分）
  DEFAULT_PREFETCH_THRESHOLD = 0.8 # TTLの何%を過ぎたらプリフェッチするか
  DEFAULT_LRU_SIZE = 1000 # LRUキャッシュのサイズ

type
  # DNSレコードタイプ
  DnsRecordType* = enum
    A, AAAA, CNAME, MX, TXT, NS, SRV, PTR, SOA, DNSKEY, DS, RRSIG, NSEC, NSEC3

  # 各タイプのDNSレコードデータ
  DnsRecordData* = object
    case recordType*: DnsRecordType
    of A:
      ipv4*: string
    of AAAA:
      ipv6*: string
    of CNAME:
      cname*: string
    of MX:
      preference*: int
      exchange*: string
    of TXT:
      text*: string
    of NS:
      nameserver*: string
    of SRV:
      priority*: int
      weight*: int
      port*: int
      target*: string
    of PTR:
      ptrdname*: string
    of SOA:
      mname*: string
      rname*: string
      serial*: uint32
      refresh*: int
      retry*: int
      expire*: int
      minimum*: int
    of DNSKEY, DS, RRSIG, NSEC, NSEC3:
      rawData*: string # DNSSECレコードのバイナリデータを文字列として格納

  # 拡張されたDNSレコード
  EnhancedDnsRecord* = object
    data*: DnsRecordData
    ttl*: int
    timestamp*: Time
    accessCount*: int # LRU用アクセスカウント

  # DNSキャッシュマネージャー
  DnsCacheManager* = ref object
    cache*: Table[string, Table[DnsRecordType, seq[EnhancedDnsRecord]]]
    negativeCacheTable*: Table[string, Time] # 解決に失敗したホスト名とその有効期限
    maxEntries*: int
    defaultTtl*: int
    negativeTtl*: int
    minTtl*: int
    maxTtl*: int
    prefetchThreshold*: float
    cacheFile*: string
    lastCleanupTime*: Time
    cleanupInterval*: int
    memoryUsage*: int64 # 推定メモリ使用量（バイト）
    hitCount*: int      # キャッシュヒット回数
    missCount*: int     # キャッシュミス回数
    lruQueue*: seq[tuple[key: string, recordType: DnsRecordType, accessTime: Time]]
    lruSize*: int

# ユーティリティ関数
proc hash*(recordType: DnsRecordType): Hash =
  ## DNSレコードタイプのハッシュ関数
  result = hash(int(recordType))

proc newDnsCacheManager*(
  cacheFile: string = DEFAULT_CACHE_FILE,
  maxEntries: int = DEFAULT_MAX_ENTRIES,
  defaultTtl: int = DEFAULT_ENTRY_TTL,
  negativeTtl: int = DEFAULT_NEGATIVE_TTL,
  cleanupInterval: int = DEFAULT_CACHE_CLEANUP_INTERVAL,
  prefetchThreshold: float = DEFAULT_PREFETCH_THRESHOLD,
  lruSize: int = DEFAULT_LRU_SIZE
): DnsCacheManager =
  ## 新しいDNSキャッシュマネージャーを作成
  result = DnsCacheManager(
    cache: initTable[string, Table[DnsRecordType, seq[EnhancedDnsRecord]]](),
    negativeCacheTable: initTable[string, Time](),
    maxEntries: maxEntries,
    defaultTtl: defaultTtl,
    negativeTtl: negativeTtl,
    minTtl: min(DEFAULT_MIN_TTL, defaultTtl),
    maxTtl: max(DEFAULT_MAX_TTL, defaultTtl),
    prefetchThreshold: clamp(prefetchThreshold, 0.0, 1.0),
    cacheFile: cacheFile,
    lastCleanupTime: getTime(),
    cleanupInterval: cleanupInterval,
    memoryUsage: 0,
    hitCount: 0,
    missCount: 0,
    lruQueue: @[],
    lruSize: lruSize
  )
  
  # キャッシュファイルから読み込み
  result.loadFromFile()

proc estimateRecordSize(record: EnhancedDnsRecord): int =
  ## レコードのおおよそのメモリサイズを推定（バイト単位）
  result = 24 # 基本的なオブジェクトサイズ

  case record.data.recordType:
    of A:
      result += record.data.ipv4.len + 8
    of AAAA:
      result += record.data.ipv6.len + 8
    of CNAME:
      result += record.data.cname.len + 8
    of MX:
      result += record.data.exchange.len + 16
    of TXT:
      result += record.data.text.len + 8
    of NS:
      result += record.data.nameserver.len + 8
    of SRV:
      result += record.data.target.len + 24
    of PTR:
      result += record.data.ptrdname.len + 8
    of SOA:
      result += record.data.mname.len + record.data.rname.len + 40
    of DNSKEY, DS, RRSIG, NSEC, NSEC3:
      result += record.data.rawData.len + 8

proc addToLruQueue(self: DnsCacheManager, hostname: string, recordType: DnsRecordType) =
  ## LRUキューにエントリを追加または更新
  let now = getTime()
  
  # 既存のエントリを検索し削除
  for i in 0..<self.lruQueue.len:
    if self.lruQueue[i].key == hostname and self.lruQueue[i].recordType == recordType:
      self.lruQueue.delete(i)
      break
  
  # 新しいエントリを追加
  self.lruQueue.add((key: hostname, recordType: recordType, accessTime: now))
  
  # サイズ制限を超えたら最も古いエントリを削除
  if self.lruQueue.len > self.lruSize:
    # アクセス時間でソート
    self.lruQueue.sort(proc(x, y: tuple[key: string, recordType: DnsRecordType, accessTime: Time]): int =
      if x.accessTime < y.accessTime: -1
      elif x.accessTime > y.accessTime: 1
      else: 0
    )
    
    # 最も古いエントリを削除
    let oldest = self.lruQueue[0]
    self.lruQueue.delete(0)
    
    # キャッシュからも削除（対応するレコードが存在する場合）
    if self.cache.hasKey(oldest.key) and self.cache[oldest.key].hasKey(oldest.recordType):
      let records = self.cache[oldest.key][oldest.recordType]
      for record in records:
        self.memoryUsage -= estimateRecordSize(record)
      
      self.cache[oldest.key].del(oldest.recordType)
      if self.cache[oldest.key].len == 0:
        self.cache.del(oldest.key)

proc sanitizeRecord(record: var EnhancedDnsRecord) =
  ## レコードデータの検証と正規化
  # TTLの正規化
  record.ttl = clamp(record.ttl, DEFAULT_MIN_TTL, DEFAULT_MAX_TTL)
  
  # タイムスタンプが未来の場合は現在時刻に修正
  let now = getTime()
  if record.timestamp > now:
    record.timestamp = now
  
  # レコードタイプに応じたデータの検証
  case record.data.recordType:
    of A:
      # IPv4アドレスの形式を簡易チェック
      if not record.data.ipv4.contains(".") or record.data.ipv4.len < 7:
        record.data.ipv4 = "0.0.0.0"
    of AAAA:
      # IPv6アドレスの形式を簡易チェック
      if not record.data.ipv6.contains(":") or record.data.ipv6.len < 5:
        record.data.ipv6 = "::"
    of CNAME:
      # ホスト名の簡易チェック
      if record.data.cname.len == 0:
        record.data.cname = "."
    of MX:
      # MXの簡易チェック
      if record.data.exchange.len == 0:
        record.data.exchange = "."
      record.data.preference = max(0, record.data.preference)
    of TXT:
      # TXTレコードの簡易チェック
      if record.data.text.len == 0:
        record.data.text = ""
    of NS:
      # NSレコードの簡易チェック
      if record.data.nameserver.len == 0:
        record.data.nameserver = "."
    of SRV:
      # SRVレコードの簡易チェック
      if record.data.target.len == 0:
        record.data.target = "."
      record.data.priority = max(0, record.data.priority)
      record.data.weight = max(0, record.data.weight)
      record.data.port = clamp(record.data.port, 0, 65535)
    of PTR:
      # PTRレコードの簡易チェック
      if record.data.ptrdname.len == 0:
        record.data.ptrdname = "."
    of SOA:
      # SOAレコードの簡易チェック
      if record.data.mname.len == 0:
        record.data.mname = "."
      if record.data.rname.len == 0:
        record.data.rname = "."
    of DNSKEY, DS, RRSIG, NSEC, NSEC3:
      # DNSSEC関連レコードの簡易チェック
      if record.data.rawData.len == 0:
        record.data.rawData = ""

proc toJson(record: EnhancedDnsRecord): JsonNode =
  ## DNSレコードをJSON形式に変換
  result = %*{
    "ttl": record.ttl,
    "timestamp": record.timestamp.toUnix(),
    "accessCount": record.accessCount,
    "recordType": $record.data.recordType
  }
  
  # レコードタイプによってデータフィールドを追加
  case record.data.recordType:
    of A:
      result["ipv4"] = %record.data.ipv4
    of AAAA:
      result["ipv6"] = %record.data.ipv6
    of CNAME:
      result["cname"] = %record.data.cname
    of MX:
      result["preference"] = %record.data.preference
      result["exchange"] = %record.data.exchange
    of TXT:
      result["text"] = %record.data.text
    of NS:
      result["nameserver"] = %record.data.nameserver
    of SRV:
      result["priority"] = %record.data.priority
      result["weight"] = %record.data.weight
      result["port"] = %record.data.port
      result["target"] = %record.data.target
    of PTR:
      result["ptrdname"] = %record.data.ptrdname
    of SOA:
      result["mname"] = %record.data.mname
      result["rname"] = %record.data.rname
      result["serial"] = %record.data.serial
      result["refresh"] = %record.data.refresh
      result["retry"] = %record.data.retry
      result["expire"] = %record.data.expire
      result["minimum"] = %record.data.minimum
    of DNSKEY, DS, RRSIG, NSEC, NSEC3:
      result["rawData"] = %record.data.rawData

proc fromJson(json: JsonNode): Option[EnhancedDnsRecord] =
  ## JSON形式からDNSレコードを復元
  try:
    var record: EnhancedDnsRecord
    
    # 基本フィールドの復元
    record.ttl = json["ttl"].getInt()
    record.timestamp = fromUnix(json["timestamp"].getInt())
    record.accessCount = if json.hasKey("accessCount"): json["accessCount"].getInt() else: 0
    
    # レコードタイプの復元
    let recordTypeStr = json["recordType"].getStr()
    record.data.recordType = parseEnum[DnsRecordType](recordTypeStr)
    
    # レコードタイプ特有のデータの復元
    case record.data.recordType:
      of A:
        record.data.ipv4 = json["ipv4"].getStr()
      of AAAA:
        record.data.ipv6 = json["ipv6"].getStr()
      of CNAME:
        record.data.cname = json["cname"].getStr()
      of MX:
        record.data.preference = json["preference"].getInt()
        record.data.exchange = json["exchange"].getStr()
      of TXT:
        record.data.text = json["text"].getStr()
      of NS:
        record.data.nameserver = json["nameserver"].getStr()
      of SRV:
        record.data.priority = json["priority"].getInt()
        record.data.weight = json["weight"].getInt()
        record.data.port = json["port"].getInt()
        record.data.target = json["target"].getStr()
      of PTR:
        record.data.ptrdname = json["ptrdname"].getStr()
      of SOA:
        record.data.mname = json["mname"].getStr()
        record.data.rname = json["rname"].getStr()
        record.data.serial = uint32(json["serial"].getInt())
        record.data.refresh = json["refresh"].getInt()
        record.data.retry = json["retry"].getInt()
        record.data.expire = json["expire"].getInt()
        record.data.minimum = json["minimum"].getInt()
      of DNSKEY, DS, RRSIG, NSEC, NSEC3:
        record.data.rawData = json["rawData"].getStr()
    
    # データの検証と正規化
    sanitizeRecord(record)
    
    return some(record)
  except:
    return none(EnhancedDnsRecord)

proc saveToFile*(self: DnsCacheManager) =
  ## キャッシュをファイルに保存
  try:
    # キャッシュをJSONに変換
    var cacheJson = newJObject()
    
    # 通常のキャッシュ
    var recordsJson = newJObject()
    for hostname, recordTypes in self.cache:
      var hostnameJson = newJObject()
      
      for recordType, records in recordTypes:
        var recordsArray = newJArray()
        for record in records:
          recordsArray.add(toJson(record))
          
        hostnameJson[$recordType] = recordsArray
      
      recordsJson[hostname] = hostnameJson
    
    cacheJson["records"] = recordsJson
    
    # ネガティブキャッシュ
    var negativeJson = newJObject()
    for hostname, expiry in self.negativeCacheTable:
      negativeJson[hostname] = %expiry.toUnix()
    
    cacheJson["negativecache"] = negativeJson
    
    # 統計情報
    var statsJson = newJObject()
    statsJson["hitCount"] = %self.hitCount
    statsJson["missCount"] = %self.missCount
    statsJson["memoryUsage"] = %self.memoryUsage
    statsJson["lastCleanupTime"] = %self.lastCleanupTime.toUnix()
    
    cacheJson["stats"] = statsJson
    
    # ファイルに書き込み
    writeFile(self.cacheFile, $cacheJson)
  except:
    echo "DNSキャッシュの保存に失敗しました: ", getCurrentExceptionMsg()

proc loadFromFile*(self: DnsCacheManager) =
  ## ファイルからキャッシュを読み込み
  if not fileExists(self.cacheFile):
    echo "DNSキャッシュファイルが存在しません: ", self.cacheFile
    return
  
  try:
    let jsonStr = readFile(self.cacheFile)
    let cacheJson = parseJson(jsonStr)
    
    # 通常のキャッシュを読み込み
    if cacheJson.hasKey("records"):
      let recordsJson = cacheJson["records"]
      for hostname, hostnameJson in recordsJson:
        var recordTypes = initTable[DnsRecordType, seq[EnhancedDnsRecord]]()
        
        for recordTypeStr, recordsArray in hostnameJson:
          let recordType = parseEnum[DnsRecordType](recordTypeStr)
          var records: seq[EnhancedDnsRecord] = @[]
          
          for recordJson in recordsArray:
            let recordOpt = fromJson(recordJson)
            if recordOpt.isSome:
              records.add(recordOpt.get)
              self.memoryUsage += estimateRecordSize(recordOpt.get)
          
          if records.len > 0:
            recordTypes[recordType] = records
        
        if recordTypes.len > 0:
          self.cache[hostname] = recordTypes
    
    # ネガティブキャッシュを読み込み
    if cacheJson.hasKey("negativecache"):
      let negativeJson = cacheJson["negativecache"]
      for hostname, expiryJson in negativeJson:
        let expiry = fromUnix(expiryJson.getInt())
        if expiry > getTime():  # 有効期限内のみ読み込み
          self.negativeCacheTable[hostname] = expiry
    
    # 統計情報を読み込み
    if cacheJson.hasKey("stats"):
      let statsJson = cacheJson["stats"]
      if statsJson.hasKey("hitCount"):
        self.hitCount = statsJson["hitCount"].getInt()
      if statsJson.hasKey("missCount"):
        self.missCount = statsJson["missCount"].getInt()
      if statsJson.hasKey("lastCleanupTime"):
        self.lastCleanupTime = fromUnix(statsJson["lastCleanupTime"].getInt())
    
    echo "DNSキャッシュをファイルから読み込みました: エントリ数=", self.cache.len, 
         ", ネガティブキャッシュ=", self.negativeCacheTable.len
  except:
    echo "DNSキャッシュの読み込みに失敗しました: ", getCurrentExceptionMsg()

proc cleanup*(self: DnsCacheManager) =
  ## 期限切れのキャッシュエントリを削除
  let now = getTime()
  var expiredHosts: seq[string] = @[]
  var expiredRecords: Table[string, seq[DnsRecordType]] = initTable[string, seq[DnsRecordType]]()
  var totalRemoved = 0
  
  # 期限切れの通常キャッシュエントリを探す
  for hostname, recordTypes in self.cache:
    var hasValidRecords = false
    var expiredTypes: seq[DnsRecordType] = @[]
    
    for recordType, records in recordTypes:
      var validRecords: seq[EnhancedDnsRecord] = @[]
      
      for record in records:
        let elapsedSecs = (now - record.timestamp).inSeconds.int
        if elapsedSecs < record.ttl:
          validRecords.add(record)
        else:
          self.memoryUsage -= estimateRecordSize(record)
          totalRemoved += 1
      
      if validRecords.len > 0:
        self.cache[hostname][recordType] = validRecords
        hasValidRecords = true
      else:
        expiredTypes.add(recordType)
    
    # 期限切れのレコードタイプを削除
    for recordType in expiredTypes:
      self.cache[hostname].del(recordType)
    
    # ホスト名にレコードが何も残っていなければリストに追加
    if self.cache[hostname].len == 0:
      expiredHosts.add(hostname)
    
    # 期限切れのレコードタイプをテーブルに記録
    if expiredTypes.len > 0:
      expiredRecords[hostname] = expiredTypes
  
  # 期限切れのホスト名を削除
  for hostname in expiredHosts:
    self.cache.del(hostname)
  
  # 期限切れのネガティブキャッシュエントリを削除
  var expiredNegative: seq[string] = @[]
  for hostname, expiry in self.negativeCacheTable:
    if now > expiry:
      expiredNegative.add(hostname)
  
  for hostname in expiredNegative:
    self.negativeCacheTable.del(hostname)
  
  # LRUキューからも期限切れのエントリを削除
  self.lruQueue.keepIf(proc(item: tuple[key: string, recordType: DnsRecordType, accessTime: Time]): bool =
    return not (item.key in expiredHosts) and
           not (item.key in expiredRecords and item.recordType in expiredRecords[item.key])
  )
  
  self.lastCleanupTime = now
  
  echo "DNSキャッシュのクリーンアップ完了: 削除件数=", totalRemoved, 
       ", 残りキャッシュ=", self.cache.len, ", 残りネガティブキャッシュ=", self.negativeCacheTable.len

proc add*(self: DnsCacheManager, hostname: string, recordType: DnsRecordType, 
          record: EnhancedDnsRecord, saveImmediately: bool = false) =
  ## キャッシュにレコードを追加
  # レコードの検証と正規化
  var validRecord = record
  sanitizeRecord(validRecord)
  
  # ホスト名のエントリがなければ作成
  if not self.cache.hasKey(hostname):
    self.cache[hostname] = initTable[DnsRecordType, seq[EnhancedDnsRecord]]()
  
  # レコードタイプのエントリがなければ作成
  if not self.cache[hostname].hasKey(recordType):
    self.cache[hostname][recordType] = @[]
  
  # 同じ内容のレコードが既にある場合は更新、なければ追加
  var found = false
  for i in 0..<self.cache[hostname][recordType].len:
    var existingRecord = self.cache[hostname][recordType][i]
    
    if existingRecord.data == validRecord.data:
      # メモリ使用量の更新
      self.memoryUsage -= estimateRecordSize(existingRecord)
      self.memoryUsage += estimateRecordSize(validRecord)
      
      # レコードを更新
      self.cache[hostname][recordType][i] = validRecord
      found = true
      break
  
  if not found:
    # 新しいレコードを追加
    self.cache[hostname][recordType].add(validRecord)
    self.memoryUsage += estimateRecordSize(validRecord)
  
  # ネガティブキャッシュから削除（もし存在すれば）
  if self.negativeCacheTable.hasKey(hostname):
    self.negativeCacheTable.del(hostname)
  
  # LRUキューに追加または更新
  self.addToLruQueue(hostname, recordType)
  
  # キャッシュサイズチェック
  if self.cache.len > self.maxEntries:
    self.enforceCacheLimit()
  
  # クリーンアップ時間チェック
  let now = getTime()
  if (now - self.lastCleanupTime).inSeconds.int > self.cleanupInterval:
    self.cleanup()
  
  # 即座に保存が要求された場合
  if saveImmediately:
    self.saveToFile()

proc addNegative*(self: DnsCacheManager, hostname: string, saveImmediately: bool = false) =
  ## ネガティブキャッシュに追加（解決に失敗したホスト名）
  let now = getTime()
  let expiry = now + initDuration(seconds = self.negativeTtl)
  
  self.negativeCacheTable[hostname] = expiry
  
  # 即座に保存が要求された場合
  if saveImmediately:
    self.saveToFile()

proc get*(self: DnsCacheManager, hostname: string, recordType: DnsRecordType): seq[EnhancedDnsRecord] =
  ## キャッシュからレコードを取得
  result = @[]
  let now = getTime()
  
  # ネガティブキャッシュをチェック
  if self.negativeCacheTable.hasKey(hostname):
    let expiry = self.negativeCacheTable[hostname]
    if now < expiry:
      # まだ有効期限内の場合は空のリストを返す
      self.hitCount += 1
      return result
    else:
      # 期限切れの場合はネガティブキャッシュから削除
      self.negativeCacheTable.del(hostname)
  
  # 通常のキャッシュをチェック
  if self.cache.hasKey(hostname) and self.cache[hostname].hasKey(recordType):
    var validRecords: seq[EnhancedDnsRecord] = @[]
    
    for record in self.cache[hostname][recordType]:
      let elapsedSecs = (now - record.timestamp).inSeconds.int
      if elapsedSecs < record.ttl:
        # アクセスカウントを増やす
        var updatedRecord = record
        updatedRecord.accessCount += 1
        validRecords.add(updatedRecord)
        
        # LRUキューを更新
        self.addToLruQueue(hostname, recordType)
    
    # 有効なレコードを返す
    if validRecords.len > 0:
      self.hitCount += 1
      self.cache[hostname][recordType] = validRecords
      return validRecords
  
  # キャッシュミス
  self.missCount += 1
  return result

proc getIpAddresses*(self: DnsCacheManager, hostname: string): seq[string] =
  ## ホスト名に対応するIPアドレス（IPv4とIPv6）を取得
  result = @[]
  
  # Aレコード（IPv4）を取得
  let aRecords = self.get(hostname, A)
  for record in aRecords:
    result.add(record.data.ipv4)
  
  # AAAAレコード（IPv6）を取得
  let aaaaRecords = self.get(hostname, AAAA)
  for record in aaaaRecords:
    result.add(record.data.ipv6)
  
  return result

proc shouldPrefetch*(self: DnsCacheManager, hostname: string, recordType: DnsRecordType): bool =
  ## レコードをプリフェッチすべきかどうかを判断
  if not self.cache.hasKey(hostname) or not self.cache[hostname].hasKey(recordType):
    return false
  
  let now = getTime()
  let records = self.cache[hostname][recordType]
  
  for record in records:
    let elapsedSecs = (now - record.timestamp).inSeconds.int
    let thresholdSecs = (record.ttl.float * self.prefetchThreshold).int
    
    if elapsedSecs >= thresholdSecs:
      return true
  
  return false

proc enforceCacheLimit*(self: DnsCacheManager) =
  ## キャッシュサイズの制限を適用
  if self.cache.len <= self.maxEntries:
    return
  
  # 削除する必要があるエントリ数
  let toRemove = self.cache.len - self.maxEntries
  
  # LRUキューをアクセス時間でソート
  self.lruQueue.sort(proc(x, y: tuple[key: string, recordType: DnsRecordType, accessTime: Time]): int =
    if x.accessTime < y.accessTime: -1
    elif x.accessTime > y.accessTime: 1
    else: 0
  )
  
  # 古いエントリから削除
  var removed = 0
  var i = 0
  while i < self.lruQueue.len and removed < toRemove:
    let entry = self.lruQueue[i]
    
    if self.cache.hasKey(entry.key) and self.cache[entry.key].hasKey(entry.recordType):
      # メモリ使用量を更新
      for record in self.cache[entry.key][entry.recordType]:
        self.memoryUsage -= estimateRecordSize(record)
      
      # レコードタイプを削除
      self.cache[entry.key].del(entry.recordType)
      
      # ホスト名のエントリが空になったら削除
      if self.cache[entry.key].len == 0:
        self.cache.del(entry.key)
      
      # LRUキューからエントリを削除
      self.lruQueue.delete(i)
      removed += 1
    else:
      i += 1
  
  echo "DNSキャッシュのサイズ制限を適用: 削除数=", removed, ", 残りキャッシュ=", self.cache.len

proc getCacheStats*(self: DnsCacheManager): JsonNode =
  ## キャッシュの統計情報を取得
  let now = getTime()
  var stats = %*{
    "entries": self.cache.len,
    "negativeEntries": self.negativeCacheTable.len,
    "memoryUsage": self.memoryUsage,
    "memoryUsageMB": self.memoryUsage.float / (1024 * 1024),
    "hitCount": self.hitCount,
    "missCount": self.missCount,
    "hitRatio": if self.hitCount + self.missCount > 0: 
                  self.hitCount.float / (self.hitCount + self.missCount).float 
                else: 0.0,
    "lastCleanupTime": formatTime(self.lastCleanupTime, "yyyy-MM-dd HH:mm:ss"),
    "timeSinceCleanup": (now - self.lastCleanupTime).inSeconds.int,
    "recordTypeCounts": newJObject()
  }
  
  # レコードタイプごとの数をカウント
  var typeCounts: Table[DnsRecordType, int] = initTable[DnsRecordType, int]()
  for hostname, recordTypes in self.cache:
    for recordType, records in recordTypes:
      if not typeCounts.hasKey(recordType):
        typeCounts[recordType] = 0
      typeCounts[recordType] += records.len
  
  # レコードタイプごとの数をJSONに追加
  var recordTypeCounts = newJObject()
  for recordType, count in typeCounts:
    recordTypeCounts[$recordType] = %count
  
  stats["recordTypeCounts"] = recordTypeCounts
  
  return stats

proc clear*(self: DnsCacheManager) =
  ## キャッシュを完全にクリア
  self.cache.clear()
  self.negativeCacheTable.clear()
  self.lruQueue.setLen(0)
  self.memoryUsage = 0
  self.lastCleanupTime = getTime()
  
  # 統計情報はリセットしない
  
  echo "DNSキャッシュをクリアしました"