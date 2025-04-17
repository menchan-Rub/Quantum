# DNS Cache Implementation
#
# 高性能なDNSキャッシュシステム
# IPv4/IPv6アドレス、CNAME、MX、TXTなどの各種レコードタイプをサポート

import std/[tables, times, options, hashes, algorithm, asyncdispatch, strutils, sequtils]
import std/[sets, sugar, random, locks]

type
  DnsRecordType* = enum
    A = 1      # IPv4アドレス
    NS = 2     # ネームサーバー
    CNAME = 5  # 正規名
    SOA = 6    # 権威の開始
    PTR = 12   # ポインタ
    MX = 15    # メール交換
    TXT = 16   # テキスト
    AAAA = 28  # IPv6アドレス
    SRV = 33   # サービス
    OPT = 41   # EDNS0オプション
    ANY = 255  # すべてのレコード
  
  DnsRecord* = object
    case recordType*: DnsRecordType
    of A:
      ipv4*: string           # IPv4アドレス (例: "93.184.216.34")
    of AAAA:
      ipv6*: string           # IPv6アドレス (例: "2606:2800:220:1:248:1893:25c8:1946")
    of CNAME, NS, PTR:
      target*: string         # ターゲットドメイン
    of MX:
      preference*: uint16     # 優先度
      exchange*: string       # メールサーバー
    of TXT:
      text*: seq[string]      # テキストレコード
    of SRV:
      priority*: uint16       # 優先度
      weight*: uint16         # 重み
      port*: uint16           # ポート
      host*: string           # ホスト名
    of SOA:
      mname*: string          # プライマリネームサーバー
      rname*: string          # 責任者のメールアドレス
      serial*: uint32         # シリアル番号
      refresh*: uint32        # リフレッシュ間隔
      retry*: uint32          # リトライ間隔
      expire*: uint32         # 有効期限
      minimum*: uint32        # 最小TTL
    of OPT:
      udpPayloadSize*: uint16 # UDPペイロードサイズ
      highByte*: uint8        # 拡張RCODEの上位バイト
      version*: uint8         # EDNSバージョン
      flags*: uint16          # フラグ
      data*: seq[byte]        # OPTデータ
    of ANY:
      discard
  
  DnsCacheEntry* = object
    domain*: string           # ドメイン名
    recordType*: DnsRecordType # レコードタイプ
    ttl*: int                 # TTL（秒）
    expiresAt*: Time          # 有効期限
    records*: seq[DnsRecord]  # DNSレコード
    negativeTtl*: bool        # 否定的応答（レコードが存在しない）
    lastAccessed*: Time       # 最終アクセス時刻
    accessCount*: int         # アクセス回数
    secure*: bool            # セキュアなエントリかどうか
  
  DnsCacheKey* = object
    domain*: string
    recordType*: DnsRecordType
  
  DnsCache* = ref object
    entries*: Table[DnsCacheKey, DnsCacheEntry]
    maxEntries*: int          # 最大エントリ数
    cleanupInterval*: int     # クリーンアップ間隔（秒）
    lastCleanup*: Time        # 最後のクリーンアップ時刻
    lock*: Lock               # スレッド安全のためのロック
    negativeMaxTtl*: int      # 否定的キャッシュの最大TTL（秒）
    stats*: DnsCacheStats     # キャッシュの統計情報
    shards*: seq[DnsCacheShard] # シャードのシーケンス
    globalLock*: Lock         # グローバルなロック

# DnsCacheKeyのハッシュ関数
proc hash(key: DnsCacheKey): Hash =
  var h: Hash = 0
  h = h !& hash(key.domain.toLowerAscii())
  h = h !& hash(key.recordType)
  result = !$h

# DnsCacheKeyの比較演算子
proc `==`(a, b: DnsCacheKey): bool =
  a.domain.toLowerAscii() == b.domain.toLowerAscii() and a.recordType == b.recordType

# 新しいDNSキャッシュの作成
proc newDnsCache*(maxEntries: int = 1000, cleanupInterval: int = 300, negativeMaxTtl: int = 300): DnsCache =
  result = DnsCache(
    entries: initTable[DnsCacheKey, DnsCacheEntry](),
    maxEntries: maxEntries,
    cleanupInterval: cleanupInterval,
    lastCleanup: getTime(),
    negativeMaxTtl: negativeMaxTtl
  )
  initLock(result.lock)

# キャッシュへのエントリ追加（シャーディング対応・スレッド安全）
proc add*(cache: DnsCache, domain: string, recordType: DnsRecordType, records: seq[DnsRecord], ttl: int, secure: bool = false) =
  let normalizedDomain = domain.toLowerAscii()
  let key = DnsCacheKey(domain: normalizedDomain, recordType: recordType)
  let shardIdx = cache.shardIndex(key)
  let shard = cache.shards[shardIdx]
  
  # TTLの最適化（上限・下限の適用）
  let optimizedTtl = clamp(ttl, MIN_TTL, MAX_TTL)
  
  # エントリ作成
  let now = getTime()
  let expiresAt = now + initDuration(seconds = optimizedTtl)
  let entry = DnsCacheEntry(
    domain: normalizedDomain,
    recordType: recordType,
    ttl: optimizedTtl,
    expiresAt: expiresAt,
    lastAccessed: getMonoTime(),
    records: records,
    negativeTtl: records.len == 0,
    secure: secure,
    accessCount: 1
  )
  
  # シャード単位のロック
  withLock(shard.lock):
    shard.entries[key] = entry
  
  # 統計更新
  atomicInc(cache.stats.insertions)
  
  # クリーンアップが必要か確認
  let totalEntries = cache.getTotalEntries()
  if totalEntries > cache.maxEntries:
    cache.evictEntries(totalEntries - cache.maxEntries)
  
  # 期限切れエントリの自動クリーンアップ（定期的）
  if (now - cache.lastCleanup).inSeconds >= cache.cleanupInterval:
    # 非同期でクリーンアップを実行
    asyncCheck cache.asyncCleanup()

# 否定的キャッシュエントリの追加（存在しないレコードの効率的なキャッシング）
proc addNegative*(cache: DnsCache, domain: string, recordType: DnsRecordType, ttl: int = 0) =
  let actualTtl = if ttl <= 0: cache.negativeMaxTtl else: min(ttl, cache.negativeMaxTtl)
  cache.add(domain, recordType, @[], actualTtl)

# キャッシュからのエントリ検索（高速ルックアップ・統計追跡）
proc lookup*(cache: DnsCache, domain: string, recordType: DnsRecordType): Option[DnsCacheEntry] =
  # ルックアップ時間の測定開始
  let startTime = getMonoTime()
  
  let normalizedDomain = domain.toLowerAscii()
  let key = DnsCacheKey(domain: normalizedDomain, recordType: recordType)
  let shardIdx = cache.shardIndex(key)
  let shard = cache.shards[shardIdx]
  
  var resultEntry: Option[DnsCacheEntry]
  
  withLock(shard.lock):
    if shard.entries.hasKey(key):
      let entry = shard.entries[key]
      let now = getTime()
      
      # 期限切れのエントリは返さない
      if now < entry.expiresAt:
        # LRU情報の更新（ただし頻繁な更新を避けるためにインターバルを設ける）
        let currentMono = getMonoTime()
        if (currentMono - entry.lastAccessed).inSeconds >= LRU_UPDATE_INTERVAL:
          var updatedEntry = entry
          updatedEntry.lastAccessed = currentMono
          updatedEntry.accessCount.inc
          shard.entries[key] = updatedEntry
        
        # 残りのTTLを調整して返す
        var updatedEntry = entry
        updatedEntry.ttl = max(1, (entry.expiresAt - now).inSeconds.int)
        resultEntry = some(updatedEntry)
        
        # ヒット統計の更新
        atomicInc(cache.stats.hits)
      else:
        # 期限切れのエントリを削除
        shard.entries.del(key)
        # 期限切れ統計の更新
        atomicInc(cache.stats.expirations)
        atomicInc(cache.stats.misses)
    else:
      # ミス統計の更新
      atomicInc(cache.stats.misses)
  
  # ルックアップ時間の測定終了と統計の更新
  let endTime = getMonoTime()
  let duration = (endTime - startTime).inNanoseconds
  
  withLock(cache.globalLock):
    cache.stats.totalLookupTime += duration
    cache.stats.lookupCount.inc
    cache.stats.averageLookupTime = cache.stats.totalLookupTime.float / max(1, cache.stats.lookupCount).float
  
  return resultEntry

# キャッシュからのCNAMEチェーン解決（再帰的・パフォーマンス最適化）
proc resolveCnameChain*(cache: DnsCache, domain: string, recordType: DnsRecordType, depth: int = 0): Option[DnsCacheEntry] =
  # 再帰の深さ制限（無限ループ防止）
  if depth >= MAX_CNAME_CHAIN:
    return none(DnsCacheEntry)
  
  # まず直接レコードを検索
  let directResult = cache.lookup(domain, recordType)
  if directResult.isSome:
    return directResult
  
  # CNAMEレコードを検索
  let cnameResult = cache.lookup(domain, CNAME)
  if cnameResult.isSome and cnameResult.get.records.len > 0:
    let target = cnameResult.get.records[0].target
    
    # CNAMEのターゲットが元のドメインと同じ場合は無限ループを防止
    if target.toLowerAscii == domain.toLowerAscii:
      return none(DnsCacheEntry)
    
    # CNAMEのターゲットに対して再帰的に検索
    let recursiveResult = cache.resolveCnameChain(target, recordType, depth + 1)
    if recursiveResult.isSome:
      return recursiveResult
  
  return none(DnsCacheEntry)

# キャッシュの手動クリーンアップ（期限切れエントリの削除）
proc cleanup*(cache: DnsCache) =
  let now = getTime()
  var totalExpired = 0
  
  # 各シャードを個別にクリーンアップ
  for shard in cache.shards:
    var expiredKeys: seq[DnsCacheKey] = @[]
    
    withLock(shard.lock):
      for key, entry in shard.entries:
        if now >= entry.expiresAt:
          expiredKeys.add(key)
      
      # 期限切れエントリの削除
      for key in expiredKeys:
        shard.entries.del(key)
      
      totalExpired += expiredKeys.len
  
  # 統計の更新
  withLock(cache.globalLock):
    cache.stats.expirations += totalExpired.int64
    cache.stats.cleanups.inc
    cache.lastCleanup = now

# 非同期クリーンアップ処理
proc asyncCleanup*(cache: DnsCache): Future[void] {.async.} =
  cache.cleanup()
  
  # 永続化の確認
  let now = getTime()
  if cache.persistPath.len > 0 and (now - cache.lastPersist).inSeconds >= cache.persistInterval:
    await cache.asyncSaveToDisk()

# キャッシュのサイズ制限に基づくエントリ削除（LRU + 頻度ベース）
proc evictEntries*(cache: DnsCache, count: int) =
  # スコアリングベースのキャッシュ削除（LRU + 頻度ベース）
  type EntryScore = object
    key: DnsCacheKey
    shard: int
    score: float
  
  var candidates: seq[EntryScore] = @[]
  let now = getMonoTime()
  
  # 各シャードからの候補収集
  for i, shard in cache.shards:
    withLock(shard.lock):
      for key, entry in shard.entries:
        # 否定的キャッシュエントリはより削除されやすくする
        let negativeFactor = if entry.negativeTtl: 2.0 else: 1.0
        
        # アクセス頻度が高いほどスコアは低く（削除されにくい）
        let frequencyFactor = 1.0 / max(1.0, sqrt(entry.accessCount.float))
        
        # 最終アクセスからの経過時間（古いほどスコアは高く＝削除されやすい）
        let ageFactor = (now - entry.lastAccessed).inSeconds.float / 3600.0
        
        # 安全なエントリ（DNSSEC検証済み）はより保持されやすく
        let securityFactor = if entry.secure: 0.5 else: 1.0
        
        # スコア計算: 高いほど削除候補
        let score = ageFactor * frequencyFactor * negativeFactor * securityFactor
        
        candidates.add(EntryScore(key: key, shard: i, score: score))
  
  # スコアの高い順にソート（削除候補）
  candidates.sort(proc(a, b: EntryScore): int = 
    if a.score > b.score: -1
    elif a.score < b.score: 1
    else: 0
  )
  
  # 必要な数だけ削除
  var removed = 0
  for candidate in candidates:
    if removed >= count:
      break
    
    let shard = cache.shards[candidate.shard]
    withLock(shard.lock):
      if shard.entries.hasKey(candidate.key):
        shard.entries.del(candidate.key)
        removed.inc
  
  # 統計の更新
  atomicInc(cache.stats.evictions, removed.int64)

# キャッシュの完全クリア
proc clear*(cache: DnsCache) =
  # 全シャードのクリア
  for shard in cache.shards:
    withLock(shard.lock):
      shard.entries.clear()
  
  # 統計情報のリセット
  withLock(cache.globalLock):
    cache.stats = DnsCacheStats()
    cache.lastCleanup = getTime()
    cache.lastPersist = getTime()

# キャッシュのエントリ総数を取得
proc getTotalEntries*(cache: DnsCache): int =
  result = 0
  for shard in cache.shards:
    withLock(shard.lock):
      result += shard.entries.len

# 特定ドメインのすべてのキャッシュエントリをクリア
proc clearDomain*(cache: DnsCache, domain: string) =
  let normalizedDomain = domain.toLowerAscii()
  
  for shard in cache.shards:
    var keysToRemove: seq[DnsCacheKey] = @[]
    
    withLock(shard.lock):
      for key in shard.entries.keys:
        if key.domain == normalizedDomain:
          keysToRemove.add(key)
      
      for key in keysToRemove:
        shard.entries.del(key)

# DNSレコードタイプから文字列への変換
proc `$`*(recordType: DnsRecordType): string =
  case recordType
  of A: "A"
  of NS: "NS"
  of CNAME: "CNAME"
  of SOA: "SOA"
  of PTR: "PTR"
  of MX: "MX"
  of TXT: "TXT"
  of AAAA: "AAAA"
  of SRV: "SRV"
  of OPT: "OPT"
  of ANY: "ANY"

# DNSレコードの文字列表現
proc `$`*(record: DnsRecord): string =
  case record.recordType
  of A:
    result = "A: " & record.ipv4
  of AAAA:
    result = "AAAA: " & record.ipv6
  of CNAME:
    result = "CNAME: " & record.target
  of NS:
    result = "NS: " & record.target
  of PTR:
    result = "PTR: " & record.target
  of MX:
    result = "MX: " & $record.preference & " " & record.exchange
  of TXT:
    result = "TXT: " & record.text.join("; ")
  of SRV:
    result = "SRV: " & $record.priority & " " & $record.weight & " " & $record.port & " " & record.host
  of SOA:
    result = "SOA: " & record.mname & " " & record.rname & " " & $record.serial
  of OPT:
    result = "OPT: " & $record.udpPayloadSize
  of DNSKEY:
    result = "DNSKEY: " & $record.flags & " " & $record.protocol & " " & $record.algorithm
  of RRSIG:
    result = "RRSIG: " & $record.typeCovered & " " & $record.sigAlgorithm
  of DS, NSEC, NSEC3, CAA:
    result = $record.recordType & ": " & record.rawData
  of ANY:
    result = "ANY"

# キャッシュエントリの文字列表現
proc `$`*(entry: DnsCacheEntry): string =
  let recordsStr = entry.records.map(proc(r: DnsRecord): string = $r).join(", ")
  let ttlStr = $entry.ttl & "s"
  let expiresStr = $entry.expiresAt
  let secureStr = if entry.secure: "安全" else: "未検証"
  
  result = "DnsCacheEntry(ドメイン: " & entry.domain & ", タイプ: " & $entry.recordType & 
           ", TTL: " & ttlStr & ", 期限: " & expiresStr & 
           ", 否定的: " & $entry.negativeTtl & ", セキュリティ: " & secureStr &
           ", アクセス数: " & $entry.accessCount & ", レコード: [" & recordsStr & "])"

# TTLの最適化（特定のドメインやレコードタイプに対する特別なTTL設定）
proc optimizeTtl*(originalTtl: int, domain: string, recordType: DnsRecordType): int =
  # 特定のドメインやレコードタイプに対してカスタムTTL値を設定
  
  # 最小・最大TTLの適用
  var ttl = clamp(originalTtl, MIN_TTL, MAX_TTL)
  
  # 重要なインフラドメインは短いTTLにする（変更に素早く対応するため）
  if domain.endsWith(".root-servers.net") or domain == "root-servers.net":
    return min(ttl, 1800)  # 最大30分
  
  # CDNドメインはより短いTTLが望ましい
  if domain.contains("cdn") or domain.contains("static") or 
     domain.contains("assets") or domain.contains("media"):
    return min(ttl, 300)  # 最大5分
  
  # ブラウザのセキュリティに関わるドメインは短いTTLが好ましい
  if domain.contains("update") or domain.contains("security") or
     domain.contains("safebrowsing") or domain.contains("cert"):
    return min(ttl, 600)  # 最大10分
  
  # SOAレコードは短めのTTLが良い
  if recordType == SOA:
    return min(ttl, 3600)  # 最大1時間
  
  # ホストのAやAAAAレコードもより頻繁に更新されることがある
  if (recordType == A or recordType == AAAA) and not domain.startsWith("www."):
    return min(ttl, 1800)  # 最大30分
  
  # MXレコードはメール配信に重要なため中程度のTTL
  if recordType == MX:
    return min(ttl, 3600)  # 最大1時間
  
  # TXTレコードはSPF/DKIM/DMARCなど頻繁に変更される可能性あり
  if recordType == TXT:
    return min(ttl, 1800)  # 最大30分
  
  # DNSSECに関連するレコードは頻繁に更新されることは少ない
  if recordType in [DNSKEY, DS, RRSIG]:
    ttl = max(ttl, 3600)  # 最小1時間
  
  # 否定的応答のTTL最適化（短めに設定）
  if originalTtl == 0:
    return 60  # 最小1分
  
  return ttl

# プリフェッチ判定（頻繁にアクセスされるドメインを事前に解決すべきか）
proc shouldPrefetch*(cache: DnsCache, domain: string, recordType: DnsRecordType): bool =
  let normalizedDomain = domain.toLowerAscii()
  let key = DnsCacheKey(domain: normalizedDomain, recordType: recordType)
  let shardIdx = cache.shardIndex(key)
  let shard = cache.shards[shardIdx]
  
  withLock(shard.lock):
    if shard.entries.hasKey(key):
      let entry = shard.entries[key]
      let now = getTime()
      
      # 否定的応答や期限切れエントリはプリフェッチしない
      if entry.negativeTtl or now >= entry.expiresAt:
        return false
      
      # 残りTTLの割合を計算
      let totalTtl = entry.ttl
      let elapsed = (now - (entry.expiresAt - initDuration(seconds = totalTtl))).inSeconds
      let elapsedPercent = elapsed.float / totalTtl.float
      
      # アクセス頻度が高いほどプリフェッチの可能性が高くなる
      let accessThreshold = if entry.accessCount > 10: PREFETCH_THRESHOLD * 0.9
                            elif entry.accessCount > 5: PREFETCH_THRESHOLD * 0.95
                            else: PREFETCH_THRESHOLD
      
      # DNSSECで検証済みの重要なレコードはより積極的にプリフェッチ
      let securityFactor = if entry.secure: 0.9 else: 1.0
      
      # TTLの一定割合が経過している場合はプリフェッチすべき
      return elapsedPercent >= (accessThreshold * securityFactor)
  
  return false

# 実際のプリフェッチ処理（非同期）
proc prefetchDomain*(cache: DnsCache, resolver: proc (domain: string, recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.},
                    domain: string, recordType: DnsRecordType): Future[bool] {.async.} =
  # プリフェッチが必要か判定
  if not cache.shouldPrefetch(domain, recordType):
    return false
  
  try:
    # 解決を実行
    let records = await resolver(domain, recordType)
    
    # 解決結果をキャッシュに追加
    if records.len > 0:
      let normalizedDomain = domain.toLowerAscii()
      let key = DnsCacheKey(domain: normalizedDomain, recordType: recordType)
      let shardIdx = cache.shardIndex(key)
      let shard = cache.shards[shardIdx]
      
      withLock(shard.lock):
        # 現在のエントリを取得
        if shard.entries.hasKey(key):
          let currentEntry = shard.entries[key]
          
          # TTLを計算（現在のものより大きければ更新）
          let originalTtl = (if records.len > 0 and records[0].ttl > 0: records[0].ttl else: 300)
          let ttl = optimizeTtl(originalTtl, domain, recordType)
          
          # 新しいエントリを作成
          let now = getTime()
          let expiresAt = now + initDuration(seconds = ttl)
          
          # アクセス情報を保持
          let entry = DnsCacheEntry(
            domain: normalizedDomain,
            recordType: recordType,
            ttl: ttl,
            expiresAt: expiresAt,
            lastAccessed: currentEntry.lastAccessed,  # 元のアクセス時刻を保持
            records: records,
            negativeTtl: false,
            secure: currentEntry.secure,  # セキュリティステータスを保持
            accessCount: currentEntry.accessCount  # アクセスカウントを保持
          )
          
          # エントリを更新
          shard.entries[key] = entry
      
      # 統計を更新
      atomicInc(cache.stats.prefetches)
      return true
    
    return false
  except:
    # プリフェッチエラーは無視
    return false

# プリフェッチタスク（バックグラウンド実行用）
proc backgroundPrefetchTask*(cache: DnsCache, resolver: proc (domain: string, recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.}): Future[void] {.async.} =
  # 一定間隔でプリフェッチ候補を探して実行
  while true:
    # 最大同時プリフェッチ数を設定
    const MAX_CONCURRENT_PREFETCH = 5
    var prefetchCount = 0
    
    # 各シャードから候補を収集
    type PrefetchCandidate = object
      domain: string
      recordType: DnsRecordType
      accessCount: int
    
    var candidates: seq[PrefetchCandidate] = @[]
    
    for shard in cache.shards:
      var shardCandidates: seq[PrefetchCandidate] = @[]
      
      withLock(shard.lock):
        for key, entry in shard.entries:
          if cache.shouldPrefetch(key.domain, key.recordType):
            shardCandidates.add(PrefetchCandidate(
              domain: key.domain,
              recordType: key.recordType,
              accessCount: entry.accessCount
            ))
      
      # 候補をメインリストに追加
      candidates.add(shardCandidates)
    
    # アクセス数でソート
    candidates.sort(proc(a, b: PrefetchCandidate): int =
      if a.accessCount > b.accessCount: -1
      elif a.accessCount < b.accessCount: 1
      else: 0
    )
    
    # 最も重要な候補のみプリフェッチ
    var prefetchTasks: seq[Future[bool]] = @[]
    for candidate in candidates:
      if prefetchCount >= MAX_CONCURRENT_PREFETCH:
        break
      
      prefetchTasks.add(cache.prefetchDomain(resolver, candidate.domain, candidate.recordType))
      inc(prefetchCount)
    
    # 全てのプリフェッチが完了するのを待つ
    if prefetchTasks.len > 0:
      await all(prefetchTasks)
    
    # 一定時間待機
    await sleepAsync(10000)  # 10秒間隔

# DNSSEC検証付きの結果をキャッシュに追加
proc addSecure*(cache: DnsCache, domain: string, recordType: DnsRecordType, records: seq[DnsRecord], ttl: int) =
  cache.add(domain, recordType, records, ttl, secure = true)

# ドメインの重要度スコアを計算（キャッシュポリシーに影響）
proc domainImportanceScore*(cache: DnsCache, domain: string): float =
  let normalizedDomain = domain.toLowerAscii()
  var totalScore = 0.0
  var entryCount = 0
  
  # 全シャードを調査
  for shard in cache.shards:
    withLock(shard.lock):
      for key, entry in shard.entries:
        if key.domain == normalizedDomain:
          # アクセス頻度の重み付け
          let accessFactor = sqrt(entry.accessCount.float)
          
          # レコードタイプによる重要度
          let typeFactor = case entry.recordType:
            of A, AAAA: 1.0  # 基本的なアドレスレコード
            of CNAME: 0.8    # エイリアス
            of MX: 0.7       # メール関連
            of TXT: 0.5      # テキストレコード
            of NS, SOA: 1.2  # 重要な管理レコード
            of DNSKEY, DS, RRSIG: 1.5  # セキュリティ関連
            else: 0.5
          
          # セキュリティ検証の重み付け
          let securityFactor = if entry.secure: 1.2 else: 1.0
          
          # 否定的応答は重要度低
          let negativeFactor = if entry.negativeTtl: 0.3 else: 1.0
          
          # スコア計算と追加
          let entryScore = accessFactor * typeFactor * securityFactor * negativeFactor
          totalScore += entryScore
          entryCount += 1
  
  # 平均スコアを返す
  if entryCount > 0:
    return totalScore / entryCount.float
  else:
    return 0.0

# ドメイン分析（複数のレコードタイプの有無に基づく）
proc analyzeDomain*(cache: DnsCache, domain: string): tuple[
  hasA: bool, hasAAAA: bool, hasMX: bool, hasTXT: bool, hasNS: bool,
  hasDNSKEY: bool, hasDS: bool, secure: bool, importance: float
] =
  let normalizedDomain = domain.toLowerAscii()
  var result = (
    hasA: false, hasAAAA: false, hasMX: false, hasTXT: false,
    hasNS: false, hasDNSKEY: false, hasDS: false, 
    secure: false, importance: 0.0
  )
  
  # 各レコードタイプの存在を確認
  for recordType in [A, AAAA, MX, TXT, NS, DNSKEY, DS]:
    let entry = cache.lookup(normalizedDomain, recordType)
    if entry.isSome and entry.get.records.len > 0:
      case recordType:
        of A: result.hasA = true
        of AAAA: result.hasAAAA = true
        of MX: result.hasMX = true
        of TXT: result.hasTXT = true
        of NS: result.hasNS = true
        of DNSKEY: result.hasDNSKEY = true
        of DS: result.hasDS = true
        else: discard
      
      # セキュア設定があれば記録
      if entry.get.secure:
        result.secure = true
  
  # 重要度スコアの計算
  result.importance = cache.domainImportanceScore(normalizedDomain)
  
  return result

# キャッシュ内の全ドメインリストを取得
proc getAllDomains*(cache: DnsCache): seq[string] =
  var domains = initHashSet[string]()
  
  for shard in cache.shards:
    var shardDomains: seq[string] = @[]
    
    withLock(shard.lock):
      for key, _ in shard.entries:
        shardDomains.add(key.domain)
    
    for domain in shardDomains:
      domains.incl(domain)
  
  result = toSeq(domains)

# 優先度の高いドメインを特定（キャッシュ戦略用）
proc getHighPriorityDomains*(cache: DnsCache, threshold: float = 1.0): seq[string] =
  var domainScores = initTable[string, float]()
  
  # 全ドメインのスコアを計算
  for domain in cache.getAllDomains():
    let score = cache.domainImportanceScore(domain)
    domainScores[domain] = score
  
  # 閾値以上のドメインをフィルタリング
  for domain, score in domainScores:
    if score >= threshold:
      result.add(domain)
  
  # スコア降順でソート
  result.sort(proc(a, b: string): int =
    let scoreA = domainScores[a]
    let scoreB = domainScores[b]
    if scoreA > scoreB: -1
    elif scoreA < scoreB: 1
    else: 0
  )

# DNSSECのサポート状況を確認
proc hasDnssecSupport*(cache: DnsCache, domain: string): bool =
  let normalizedDomain = domain.toLowerAscii()
  
  # DS, DNSKEY, RRSIGレコードのいずれかが存在するか確認
  for recordType in [DS, DNSKEY, RRSIG]:
    let entry = cache.lookup(normalizedDomain, recordType)
    if entry.isSome and entry.get.records.len > 0:
      return true
  
  return false

# ドメイン解決結果をマージ（複数のレコードタイプをまとめて処理）
proc mergeRecords*(cache: DnsCache, domain: string, recordTypes: seq[DnsRecordType]): Table[DnsRecordType, seq[DnsRecord]] =
  result = initTable[DnsRecordType, seq[DnsRecord]]()
  let normalizedDomain = domain.toLowerAscii()
  
  for recordType in recordTypes:
    let entry = cache.lookup(normalizedDomain, recordType)
    if entry.isSome:
      result[recordType] = entry.get.records

# 非同期クリーンアップ処理（バックグラウンド実行用）
proc asyncCleanupTask*(cache: DnsCache) {.async.} =
  while true:
    # キャッシュのクリーンアップ間隔に基づいて待機
    await sleepAsync(cache.cleanupInterval * 1000)
    
    # クリーンアップを実行
    await cache.asyncCleanup()

# バックグラウンドでクリーンアップタスクを開始
proc startBackgroundCleanup*(cache: DnsCache) =
  asyncCheck asyncCleanupTask(cache)

# リゾルバから直接レコードを取得してキャッシュに追加
proc resolveAndCache*(cache: DnsCache, 
                     resolver: proc (domain: string, recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.},
                     domain: string, 
                     recordType: DnsRecordType): Future[seq[DnsRecord]] {.async.} =
  # まずキャッシュをチェック
  let cachedEntry = cache.lookup(domain, recordType)
  if cachedEntry.isSome:
    return cachedEntry.get.records
  
  # キャッシュに無ければ解決を実行
  let records = await resolver(domain, recordType)
  
  # 結果をキャッシュに追加
  if records.len > 0:
    # レコードのTTLから最小値を取得（全レコードが同じTTLとは限らない）
    var minTtl = high(int)
    for record in records:
      if record.ttl > 0 and record.ttl < minTtl:
        minTtl = record.ttl
    
    # デフォルトTTL（レコードにTTLが設定されていない場合）
    if minTtl == high(int):
      minTtl = 300  # 5分
    
    # TTLを最適化
    let optimizedTtl = optimizeTtl(minTtl, domain, recordType)
    
    # キャッシュに追加
    cache.add(domain, recordType, records, optimizedTtl)
  else:
    # 否定的応答を追加
    cache.addNegative(domain, recordType)
  
  return records 