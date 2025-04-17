## DNS Cache Analytics Module
## DNSキャッシュの分析と最適化のためのモジュール

import std/[tables, times, sets, strutils, json, algorithm, options, strformat, hashes, random, math]
import std/[locks, atomics]
import ./dns_cache

type
  DomainCategory* = enum
    dcInfrastructure    # インフラストラクチャドメイン
    dcCDN               # コンテンツ配信ネットワーク
    dcSecurity          # セキュリティ関連
    dcAnalytics         # アナリティクス
    dcSocial            # ソーシャルメディア
    dcAdvertising       # 広告
    dcMedia             # メディア
    dcStatic            # 静的コンテンツ
    dcDynamic           # 動的コンテンツ
    dcAPI               # API
    dcUnknown           # 不明

  DomainPattern* = object
    pattern*: string    # パターン（ワイルドカード対応）
    category*: DomainCategory

  DomainAnalytics* = object
    domain*: string
    category*: DomainCategory
    accessCount*: int
    lastAccess*: Time
    avgResponseTime*: float
    prefetchCount*: int
    hitCount*: int
    missCount*: int
    importance*: float  # 重要度スコア
    patterns*: seq[string]  # マッチしたパターン

  CacheAnalytics* = ref object
    lock*: Lock
    domains*: Table[string, DomainAnalytics]
    domainPatterns*: seq[DomainPattern]
    globalHits*: int
    globalMisses*: int
    startTime*: Time
    lastOptimization*: Time
    optimizationInterval*: Duration

  PerformanceMetrics* = object
    queryCount*: int
    cacheHitRate*: float
    avgQueryTime*: float
    prefetchHitRate*: float
    memoryUsage*: int64
    entriesCount*: int
    expiredCount*: int
    evictedCount*: int

# カテゴリごとのパターンデータ
const defaultDomainPatterns = [
  # インフラストラクチャ
  DomainPattern(pattern: "*.dns.*", category: dcInfrastructure),
  DomainPattern(pattern: "*.root-servers.*", category: dcInfrastructure),
  # CDN
  DomainPattern(pattern: "*.cloudfront.net", category: dcCDN),
  DomainPattern(pattern: "*.akamai.*", category: dcCDN),
  DomainPattern(pattern: "*.fastly.*", category: dcCDN),
  # セキュリティ
  DomainPattern(pattern: "*.security.*", category: dcSecurity),
  DomainPattern(pattern: "*.trust.*", category: dcSecurity),
  # アナリティクス
  DomainPattern(pattern: "*.analytics.*", category: dcAnalytics),
  DomainPattern(pattern: "*.stats.*", category: dcAnalytics),
  # ソーシャル
  DomainPattern(pattern: "*.facebook.*", category: dcSocial),
  DomainPattern(pattern: "*.twitter.*", category: dcSocial),
  # 広告
  DomainPattern(pattern: "*.ads.*", category: dcAdvertising),
  DomainPattern(pattern: "*.doubleclick.*", category: dcAdvertising),
  # メディア
  DomainPattern(pattern: "*.video.*", category: dcMedia),
  DomainPattern(pattern: "*.audio.*", category: dcMedia),
  # 静的コンテンツ
  DomainPattern(pattern: "*.static.*", category: dcStatic),
  DomainPattern(pattern: "*.assets.*", category: dcStatic),
  # 動的コンテンツ 
  DomainPattern(pattern: "*.dynamic.*", category: dcDynamic),
  DomainPattern(pattern: "*.api.*", category: dcAPI)
]

proc newCacheAnalytics*(): CacheAnalytics =
  ## 新しいキャッシュ分析インスタンスを作成
  result = CacheAnalytics(
    domains: initTable[string, DomainAnalytics](),
    domainPatterns: @defaultDomainPatterns,
    globalHits: 0,
    globalMisses: 0,
    startTime: getTime(),
    lastOptimization: getTime(),
    optimizationInterval: initDuration(minutes=30)
  )
  initLock(result.lock)

proc matchPattern(domain: string, pattern: string): bool =
  ## ドメインがパターンに一致するかチェック
  if pattern == "*":
    return true
  
  let parts = pattern.split("*")
  if parts.len == 1:
    return domain == pattern
  
  var pos = 0
  for i, part in parts:
    if part == "":
      continue
    
    let newPos = domain.find(part, pos)
    if newPos == -1:
      return false
    
    if i == 0 and newPos != 0 and part != "":
      return false
    
    if i == parts.high and part != "" and newPos + part.len != domain.len:
      return false
    
    pos = newPos + part.len
  
  return true

proc categorize*(analytics: CacheAnalytics, domain: string): DomainCategory =
  ## ドメインをカテゴリに分類
  for pattern in analytics.domainPatterns:
    if matchPattern(domain, pattern.pattern):
      return pattern.category
  
  return dcUnknown

proc getDomainAnalytics*(analytics: CacheAnalytics, domain: string): DomainAnalytics =
  ## ドメインの分析データを取得
  withLock analytics.lock:
    if domain in analytics.domains:
      result = analytics.domains[domain]
    else:
      var matchedPatterns: seq[string] = @[]
      for pattern in analytics.domainPatterns:
        if matchPattern(domain, pattern.pattern):
          matchedPatterns.add(pattern.pattern)
      
      result = DomainAnalytics(
        domain: domain,
        category: analytics.categorize(domain),
        accessCount: 0,
        lastAccess: getTime(),
        avgResponseTime: 0.0,
        prefetchCount: 0,
        hitCount: 0,
        missCount: 0,
        importance: 0.0,
        patterns: matchedPatterns
      )
      analytics.domains[domain] = result

proc recordAccess*(analytics: CacheAnalytics, domain: string, isHit: bool, responseTime: float) =
  ## ドメインアクセスを記録
  withLock analytics.lock:
    var domainData = analytics.getDomainAnalytics(domain)
    domainData.accessCount += 1
    domainData.lastAccess = getTime()
    
    # 平均応答時間を更新
    domainData.avgResponseTime = (domainData.avgResponseTime * (domainData.accessCount.float - 1) + 
                                 responseTime) / domainData.accessCount.float
    
    if isHit:
      domainData.hitCount += 1
      analytics.globalHits += 1
    else:
      domainData.missCount += 1
      analytics.globalMisses += 1
    
    # 重要度スコアを計算
    let recencyFactor = 1.0 / max(1, (getTime() - domainData.lastAccess).inSeconds.float / 3600.0)
    let frequencyFactor = min(10.0, domainData.accessCount.float / 10.0)
    let hitRateFactor = if domainData.accessCount > 0: domainData.hitCount.float / domainData.accessCount.float else: 0.0
    
    domainData.importance = recencyFactor * 0.4 + frequencyFactor * 0.4 + hitRateFactor * 0.2
    
    # 更新したデータを保存
    analytics.domains[domain] = domainData

proc recordPrefetch*(analytics: CacheAnalytics, domain: string) =
  ## プリフェッチを記録
  withLock analytics.lock:
    var domainData = analytics.getDomainAnalytics(domain)
    domainData.prefetchCount += 1
    analytics.domains[domain] = domainData

proc getHighImportanceDomains*(analytics: CacheAnalytics, threshold: float = 0.5): seq[string] =
  ## 重要度の高いドメインのリストを取得
  result = @[]
  withLock analytics.lock:
    for domain, data in analytics.domains:
      if data.importance >= threshold:
        result.add(domain)
  
  # 重要度順にソート
  result.sort(proc(a, b: string): int =
    let impA = analytics.domains[a].importance
    let impB = analytics.domains[b].importance
    if impA < impB: return 1
    if impA > impB: return -1
    return 0
  )

proc getTopAccessedDomains*(analytics: CacheAnalytics, limit: int = 10): seq[tuple[domain: string, count: int]] =
  ## 最もアクセスの多いドメインのリストを取得
  result = @[]
  withLock analytics.lock:
    for domain, data in analytics.domains:
      result.add((domain, data.accessCount))
  
  # アクセス数順にソート
  result.sort(proc(a, b: tuple[domain: string, count: int]): int =
    if a.count < b.count: return 1
    if a.count > b.count: return -1
    return 0
  )
  
  if result.len > limit:
    result = result[0..<limit]

proc calculateOptimalTTL*(analytics: CacheAnalytics, domain: string, recordType: string, originalTTL: int): int =
  ## 最適なTTL値を計算
  let domainData = analytics.getDomainAnalytics(domain)
  
  case domainData.category:
    of dcInfrastructure:
      # インフラストラクチャドメインは長めのTTLを推奨
      result = max(originalTTL, 3600) # 最低1時間
    
    of dcCDN:
      # CDNは中程度のTTL、頻繁に変更される可能性がある
      result = min(max(originalTTL, 300), 1800) # 5分〜30分
    
    of dcSecurity:
      # セキュリティドメインは短めのTTL
      result = min(originalTTL, 600) # 最大10分
    
    of dcAnalytics, dcAdvertising:
      # 分析や広告は中程度のTTL
      result = min(max(originalTTL, 300), 1200) # 5分〜20分
    
    of dcStatic:
      # 静的コンテンツは長めのTTL
      result = max(originalTTL, 3600) # 最低1時間
    
    of dcDynamic, dcAPI:
      # 動的コンテンツやAPIは短めのTTL
      result = min(max(originalTTL, 60), 300) # 1分〜5分
    
    else:
      # デフォルトは元のTTL
      result = originalTTL
  
  # レコードタイプに基づく調整
  if recordType == "A" or recordType == "AAAA":
    # IPアドレスは変更が多いので短めに
    result = min(result, 1800) # 最大30分
  
  elif recordType == "CNAME":
    # CNAMEは比較的安定しているので長めに
    result = max(result, 1800) # 最低30分
  
  elif recordType == "MX":
    # メールサーバーは変更が少ないので長めに
    result = max(result, 3600) # 最低1時間
  
  elif recordType == "NS" or recordType == "SOA":
    # 権威情報は長めに
    result = max(result, 86400) # 最低1日
  
  # アクセスパターンに基づく調整
  if domainData.accessCount > 10:
    # 頻繁にアクセスされるドメインは長めのTTL
    result = (result * 1.2).int
  
  if domainData.importance > 0.8:
    # 重要度の高いドメインは長めのTTL
    result = (result * 1.3).int
  
  # 最終的な制限
  result = min(max(result, 60), 86400) # 1分〜1日

proc shouldPrefetch*(analytics: CacheAnalytics, domain: string, remainingTTL: int): bool =
  ## ドメインをプリフェッチすべきか判断
  let domainData = analytics.getDomainAnalytics(domain)
  
  # 重要度が低いドメインはプリフェッチしない
  if domainData.importance < 0.3:
    return false
  
  # 既にプリフェッチが多いドメインは制限
  if domainData.prefetchCount > 5:
    return domainData.importance > 0.7
  
  # TTLが切れる前にプリフェッチすべきか
  if remainingTTL < 300 and domainData.accessCount > 3:
    return true
  
  # カテゴリ別の判断
  case domainData.category:
    of dcInfrastructure, dcSecurity:
      # 重要なインフラやセキュリティドメインは積極的にプリフェッチ
      return remainingTTL < 600
    
    of dcCDN, dcStatic:
      # CDNや静的コンテンツは中程度にプリフェッチ
      return remainingTTL < 300 and domainData.accessCount > 2
    
    of dcAPI, dcDynamic:
      # APIや動的コンテンツは控えめにプリフェッチ
      return remainingTTL < 120 and domainData.accessCount > 5
    
    else:
      # その他は通常のルール
      return remainingTTL < 180 and domainData.importance > 0.5

proc getPerformanceMetrics*(analytics: CacheAnalytics, cache: DNSCache): PerformanceMetrics =
  ## キャッシュのパフォーマンスメトリクスを取得
  let totalQueries = analytics.globalHits + analytics.globalMisses
  
  result.queryCount = totalQueries
  result.cacheHitRate = if totalQueries > 0: analytics.globalHits.float / totalQueries.float else: 0.0
  
  # プリフェッチヒット率の計算
  var prefetchHits = 0
  var prefetchCount = 0
  
  withLock analytics.lock:
    for _, data in analytics.domains:
      prefetchCount += data.prefetchCount
  
  result.prefetchHitRate = if prefetchCount > 0: prefetchHits.float / prefetchCount.float else: 0.0
  
  # キャッシュからその他のメトリクスを取得
  result.entriesCount = cache.getEntriesCount()
  result.memoryUsage = cache.getEstimatedMemoryUsage()

proc toJson*(analytics: CacheAnalytics): JsonNode =
  ## 分析データをJSONに変換
  result = newJObject()
  
  var domainsJson = newJArray()
  withLock analytics.lock:
    for domain, data in analytics.domains:
      var domainJson = newJObject()
      domainJson["domain"] = newJString(data.domain)
      domainJson["category"] = newJString($data.category)
      domainJson["accessCount"] = newJInt(data.accessCount)
      domainJson["lastAccess"] = newJString($data.lastAccess)
      domainJson["avgResponseTime"] = newJFloat(data.avgResponseTime)
      domainJson["prefetchCount"] = newJInt(data.prefetchCount)
      domainJson["hitCount"] = newJInt(data.hitCount)
      domainJson["missCount"] = newJInt(data.missCount)
      domainJson["importance"] = newJFloat(data.importance)
      
      var patternsJson = newJArray()
      for pattern in data.patterns:
        patternsJson.add(newJString(pattern))
      
      domainJson["patterns"] = patternsJson
      domainsJson.add(domainJson)
  
  result["domains"] = domainsJson
  result["globalHits"] = newJInt(analytics.globalHits)
  result["globalMisses"] = newJInt(analytics.globalMisses)
  result["startTime"] = newJString($analytics.startTime)
  result["lastOptimization"] = newJString($analytics.lastOptimization)
  result["optimizationInterval"] = newJString($analytics.optimizationInterval)
  
  var patternsJson = newJArray()
  for pattern in analytics.domainPatterns:
    var patternJson = newJObject()
    patternJson["pattern"] = newJString(pattern.pattern)
    patternJson["category"] = newJString($pattern.category)
    patternsJson.add(patternJson)
  
  result["domainPatterns"] = patternsJson

proc loadFromJson*(analytics: var CacheAnalytics, jsonData: JsonNode) =
  ## JSONから分析データを読み込む
  if jsonData.hasKey("globalHits"):
    analytics.globalHits = jsonData["globalHits"].getInt()
  
  if jsonData.hasKey("globalMisses"):
    analytics.globalMisses = jsonData["globalMisses"].getInt()
  
  if jsonData.hasKey("startTime"):
    let timeStr = jsonData["startTime"].getStr()
    try:
      analytics.startTime = parse(timeStr, "yyyy-MM-dd HH:mm:sszzz")
    except:
      analytics.startTime = getTime()
  
  if jsonData.hasKey("lastOptimization"):
    let timeStr = jsonData["lastOptimization"].getStr()
    try:
      analytics.lastOptimization = parse(timeStr, "yyyy-MM-dd HH:mm:sszzz")
    except:
      analytics.lastOptimization = getTime()
  
  if jsonData.hasKey("optimizationInterval"):
    let durationStr = jsonData["optimizationInterval"].getStr()
    try:
      let minutes = parseInt(durationStr.split("minutes=")[1].split(")")[0])
      analytics.optimizationInterval = initDuration(minutes=minutes)
    except:
      analytics.optimizationInterval = initDuration(minutes=30)
  
  if jsonData.hasKey("domainPatterns"):
    var patterns: seq[DomainPattern] = @[]
    for patternJson in jsonData["domainPatterns"]:
      try:
        let pattern = patternJson["pattern"].getStr()
        let categoryStr = patternJson["category"].getStr()
        let category = parseEnum[DomainCategory](categoryStr)
        patterns.add(DomainPattern(pattern: pattern, category: category))
      except:
        continue
    
    if patterns.len > 0:
      analytics.domainPatterns = patterns
  
  if jsonData.hasKey("domains"):
    withLock analytics.lock:
      for domainJson in jsonData["domains"]:
        try:
          let domain = domainJson["domain"].getStr()
          var data = DomainAnalytics(
            domain: domain,
            category: dcUnknown,
            accessCount: 0,
            lastAccess: getTime(),
            avgResponseTime: 0.0,
            prefetchCount: 0,
            hitCount: 0,
            missCount: 0,
            importance: 0.0,
            patterns: @[]
          )
          
          if domainJson.hasKey("category"):
            try:
              data.category = parseEnum[DomainCategory](domainJson["category"].getStr())
            except:
              data.category = dcUnknown
          
          if domainJson.hasKey("accessCount"):
            data.accessCount = domainJson["accessCount"].getInt()
          
          if domainJson.hasKey("lastAccess"):
            let timeStr = domainJson["lastAccess"].getStr()
            try:
              data.lastAccess = parse(timeStr, "yyyy-MM-dd HH:mm:sszzz")
            except:
              data.lastAccess = getTime()
          
          if domainJson.hasKey("avgResponseTime"):
            data.avgResponseTime = domainJson["avgResponseTime"].getFloat()
          
          if domainJson.hasKey("prefetchCount"):
            data.prefetchCount = domainJson["prefetchCount"].getInt()
          
          if domainJson.hasKey("hitCount"):
            data.hitCount = domainJson["hitCount"].getInt()
          
          if domainJson.hasKey("missCount"):
            data.missCount = domainJson["missCount"].getInt()
          
          if domainJson.hasKey("importance"):
            data.importance = domainJson["importance"].getFloat()
          
          if domainJson.hasKey("patterns"):
            for patternJson in domainJson["patterns"]:
              data.patterns.add(patternJson.getStr())
          
          analytics.domains[domain] = data
        except:
          continue

proc runOptimization*(analytics: CacheAnalytics, cache: DNSCache) =
  ## キャッシュの最適化を実行
  withLock analytics.lock:
    # 最適化の実行間隔をチェック
    if getTime() - analytics.lastOptimization < analytics.optimizationInterval:
      return
    
    analytics.lastOptimization = getTime()
  
  # 重要度の高いドメインのTTLを最適化
  let importantDomains = analytics.getHighImportanceDomains(0.3)
  for domain in importantDomains:
    # キャッシュ内のドメインのTTLを最適化
    cache.optimizeTTLForDomain(domain, proc(domain: string, recordType: string, originalTTL: int): int =
      return analytics.calculateOptimalTTL(domain, recordType, originalTTL)
    )
  
  # アクセス頻度の低いドメインを削除
  var cleanupCandidates: seq[string] = @[]
  withLock analytics.lock:
    for domain, data in analytics.domains:
      # 最終アクセスから1週間以上経過したドメイン
      if getTime() - data.lastAccess > initDuration(days=7):
        # 重要度が低く、アクセス数も少ないもの
        if data.importance < 0.2 and data.accessCount < 3:
          cleanupCandidates.add(domain)
  
  # 分析データから削除
  withLock analytics.lock:
    for domain in cleanupCandidates:
      analytics.domains.del(domain)

proc generateReport*(analytics: CacheAnalytics, cache: DNSCache): string =
  ## キャッシュのパフォーマンスレポートを生成
  let metrics = analytics.getPerformanceMetrics(cache)
  let uptime = getTime() - analytics.startTime
  let uptimeHours = uptime.inHours.float
  
  var topDomains = analytics.getTopAccessedDomains(5)
  
  result = &"""DNS Cache Performance Report
==========================
総クエリ数: {metrics.queryCount}
キャッシュヒット率: {metrics.cacheHitRate:.2f}
エントリ数: {metrics.entriesCount}
推定メモリ使用量: {metrics.memoryUsage / 1024}KB
稼働時間: {uptimeHours:.1f}時間

Top 5 ドメイン (アクセス数):
"""
  
  for i, (domain, count) in topDomains:
    result &= &"  {i+1}. {domain} ({count}回)\n"
  
  result &= &"""
グローバル統計:
  ヒット: {analytics.globalHits}
  ミス: {analytics.globalMisses}
  最終最適化: {analytics.lastOptimization}
""" 