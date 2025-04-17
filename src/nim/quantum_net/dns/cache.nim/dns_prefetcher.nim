## DNS Prefetcher Module
## DNSプリフェッチャーモジュール

import std/[tables, times, sets, strutils, json, algorithm, options, strformat, hashes, random, math]
import std/[locks, asyncdispatch, atomics]
import ./dns_cache
import ./cache_analytics

type
  PrefetchPriority* = enum
    ppLow        # 低優先度
    ppNormal     # 通常優先度
    ppHigh       # 高優先度
    ppCritical   # 重要優先度

  PrefetchTask* = object
    domain*: string
    recordType*: string
    priority*: PrefetchPriority
    scheduleTime*: Time
    ttlExpiration*: Time
    attempts*: int
    lastAttempt*: Time

  DNSPrefetcher* = ref object
    cache*: DNSCache
    analytics*: CacheAnalytics
    prefetchQueue*: seq[PrefetchTask]
    activeTasks*: int
    lock*: Lock
    enabled*: bool
    maxConcurrentTasks*: int
    maxQueueLength*: int
    minTTLThreshold*: int  # プリフェッチを開始するTTLのしきい値（秒）
    prefetchInterval*: Duration
    resolver*: proc (domain: string, recordType: string): Future[seq[DNSRecord]] {.async.}

# プリフェッチのための閾値と設定
const 
  DEFAULT_MIN_TTL_THRESHOLD = 300   # デフォルトプリフェッチ開始閾値: 5分
  DEFAULT_MAX_QUEUE_LENGTH = 100    # デフォルトキュー最大長
  DEFAULT_MAX_CONCURRENT_TASKS = 4  # デフォルト同時実行タスク数
  DEFAULT_PREFETCH_INTERVAL = 60    # デフォルトプリフェッチ間隔: 60秒

proc newDNSPrefetcher*(cache: DNSCache, analytics: CacheAnalytics, 
                      resolver: proc (domain: string, recordType: string): Future[seq[DNSRecord]] {.async.}): DNSPrefetcher =
  ## 新しいDNSプリフェッチャーを作成
  result = DNSPrefetcher(
    cache: cache,
    analytics: analytics,
    prefetchQueue: @[],
    activeTasks: 0,
    enabled: true,
    maxConcurrentTasks: DEFAULT_MAX_CONCURRENT_TASKS,
    maxQueueLength: DEFAULT_MAX_QUEUE_LENGTH,
    minTTLThreshold: DEFAULT_MIN_TTL_THRESHOLD,
    prefetchInterval: initDuration(seconds=DEFAULT_PREFETCH_INTERVAL),
    resolver: resolver
  )
  initLock(result.lock)

proc getPriority(prefetcher: DNSPrefetcher, domain: string, recordType: string, remainingTTL: int): PrefetchPriority =
  ## ドメインのプリフェッチ優先度を決定
  let analytics = prefetcher.analytics
  let domainData = analytics.getDomainAnalytics(domain)
  
  # 重要度によるベース優先度設定
  var basePriority = ppLow
  if domainData.importance > 0.8:
    basePriority = ppCritical
  elif domainData.importance > 0.6:
    basePriority = ppHigh
  elif domainData.importance > 0.3:
    basePriority = ppNormal
  
  # TTLの残り時間による調整
  if remainingTTL < 60:  # 1分未満
    return ppCritical  # TTLが切れる直前は最高優先度
  elif remainingTTL < 300:  # 5分未満
    if basePriority == ppLow:
      return ppNormal
    else:
      return PrefetchPriority(ord(basePriority) + 1)  # 一段階上げる
  
  # カテゴリによる調整
  let category = domainData.category
  if category in {dcSecurity, dcInfrastructure}:
    # セキュリティ関連は優先度を上げる
    if basePriority != ppCritical:
      return PrefetchPriority(ord(basePriority) + 1)
  
  return basePriority

proc sortQueue(prefetcher: DNSPrefetcher) =
  ## プリフェッチキューを優先度と時間に基づいてソート
  withLock prefetcher.lock:
    prefetcher.prefetchQueue.sort(proc(a, b: PrefetchTask): int =
      # 優先度順（高いものが先）
      if ord(a.priority) > ord(b.priority): return -1
      if ord(a.priority) < ord(b.priority): return 1
      
      # 同じ優先度の場合、TTLの期限が近いものが先
      if a.ttlExpiration < b.ttlExpiration: return -1
      if a.ttlExpiration > b.ttlExpiration: return 1
      
      # 最後は試行回数が少ないものを優先
      if a.attempts < b.attempts: return -1
      if a.attempts > b.attempts: return 1
      
      return 0
    )

proc scheduleTask*(prefetcher: DNSPrefetcher, domain: string, recordType: string, 
                  remainingTTL: int, ttlExpiration: Time) =
  ## プリフェッチタスクをスケジュール
  let priority = prefetcher.getPriority(domain, recordType, remainingTTL)
  let task = PrefetchTask(
    domain: domain,
    recordType: recordType,
    priority: priority,
    scheduleTime: getTime(),
    ttlExpiration: ttlExpiration,
    attempts: 0,
    lastAttempt: Time()
  )
  
  withLock prefetcher.lock:
    # キューがいっぱいの場合は低優先度のタスクを削除
    if prefetcher.prefetchQueue.len >= prefetcher.maxQueueLength:
      prefetcher.sortQueue()
      var removed = false
      
      # 最も優先度の低いタスクを見つけて削除
      for i in countdown(prefetcher.prefetchQueue.high, 0):
        if ord(prefetcher.prefetchQueue[i].priority) < ord(priority):
          prefetcher.prefetchQueue.delete(i)
          removed = true
          break
      
      # 削除できなかった場合は追加しない
      if not removed and prefetcher.prefetchQueue.len >= prefetcher.maxQueueLength:
        return
    
    # 同じドメインとレコードタイプの既存タスクを更新または追加
    var found = false
    for i in 0..<prefetcher.prefetchQueue.len:
      if prefetcher.prefetchQueue[i].domain == domain and 
         prefetcher.prefetchQueue[i].recordType == recordType:
        # 既存タスクを更新（優先度が高い方を採用）
        if ord(priority) > ord(prefetcher.prefetchQueue[i].priority):
          prefetcher.prefetchQueue[i].priority = priority
        
        prefetcher.prefetchQueue[i].ttlExpiration = ttlExpiration
        prefetcher.prefetchQueue[i].scheduleTime = getTime()
        found = true
        break
    
    if not found:
      prefetcher.prefetchQueue.add(task)
    
    # キューを優先度順にソート
    prefetcher.sortQueue()

proc executePrefetchTask(prefetcher: DNSPrefetcher, task: PrefetchTask) {.async.} =
  ## プリフェッチタスクを実行
  if not prefetcher.enabled:
    return
  
  # アクティブなタスク数をインクリメント
  atomicInc(prefetcher.activeTasks)
  defer: atomicDec(prefetcher.activeTasks)
  
  let domain = task.domain
  let recordType = task.recordType
  
  # プリフェッチを分析に記録
  prefetcher.analytics.recordPrefetch(domain)
  
  # DNSルックアップを実行
  try:
    let records = await prefetcher.resolver(domain, recordType)
    if records.len > 0:
      # キャッシュに結果を保存
      for record in records:
        prefetcher.cache.addOrUpdate(record)
      
      # デバッグログ
      when defined(debug):
        echo &"[Prefetch] 成功: {domain} ({recordType}), レコード数: {records.len}"
  except Exception as e:
    # エラーログ
    when defined(debug):
      echo &"[Prefetch] エラー: {domain} ({recordType}): {e.msg}"
    
    # 再試行管理
    withLock prefetcher.lock:
      for i in 0..<prefetcher.prefetchQueue.len:
        if prefetcher.prefetchQueue[i].domain == domain and 
           prefetcher.prefetchQueue[i].recordType == recordType:
          prefetcher.prefetchQueue[i].attempts += 1
          prefetcher.prefetchQueue[i].lastAttempt = getTime()
          
          # 試行回数の多いものは優先度を下げる
          if prefetcher.prefetchQueue[i].attempts > 3:
            if prefetcher.prefetchQueue[i].priority != ppLow:
              prefetcher.prefetchQueue[i].priority = PrefetchPriority(ord(prefetcher.prefetchQueue[i].priority) - 1)
          
          break

proc processPendingTasks*(prefetcher: DNSPrefetcher) {.async.} =
  ## 保留中のプリフェッチタスクを処理
  if not prefetcher.enabled:
    return
  
  var tasksToExecute: seq[PrefetchTask] = @[]
  
  # 実行すべきタスクを選定
  withLock prefetcher.lock:
    if prefetcher.prefetchQueue.len == 0:
      return
    
    # キューをソート
    prefetcher.sortQueue()
    
    # 現時点でのアクティブタスク数
    let currentActive = atomicLoad(prefetcher.activeTasks)
    let availableSlots = prefetcher.maxConcurrentTasks - currentActive
    
    if availableSlots <= 0:
      return
    
    # 実行するタスクを選択
    var tasksCount = 0
    var i = 0
    while i < prefetcher.prefetchQueue.len and tasksCount < availableSlots:
      let task = prefetcher.prefetchQueue[i]
      
      # 最後の試行から少なくとも10秒経っていることを確認
      if task.lastAttempt == Time() or getTime() - task.lastAttempt > initDuration(seconds=10):
        tasksToExecute.add(task)
        prefetcher.prefetchQueue.delete(i)
        tasksCount += 1
      else:
        i += 1
  
  # 選択したタスクを非同期に実行
  var futures: seq[Future[void]] = @[]
  for task in tasksToExecute:
    futures.add(prefetcher.executePrefetchTask(task))
  
  # すべてのタスクが完了するのを待つ
  if futures.len > 0:
    await all(futures)

proc runPrefetchCycle*(prefetcher: DNSPrefetcher) {.async.} =
  ## プリフェッチサイクルを実行
  if not prefetcher.enabled:
    return
  
  # キャッシュから間もなく期限切れになるエントリを探す
  let entriesNearExpiration = prefetcher.cache.getEntriesNearExpiration(
    prefetcher.minTTLThreshold
  )
  
  # プリフェッチする価値があるエントリをスケジュール
  for entry in entriesNearExpiration:
    let remainingTTL = entry.remainingTTL
    let shouldPrefetch = prefetcher.analytics.shouldPrefetch(
      entry.domain, remainingTTL
    )
    
    if shouldPrefetch:
      prefetcher.scheduleTask(
        entry.domain,
        entry.recordType,
        remainingTTL,
        entry.expirationTime
      )
  
  # タスクを処理
  await prefetcher.processPendingTasks()

proc startPrefetcher*(prefetcher: DNSPrefetcher) {.async.} =
  ## プリフェッチャーを開始
  prefetcher.enabled = true
  
  while prefetcher.enabled:
    try:
      await prefetcher.runPrefetchCycle()
    except Exception as e:
      when defined(debug):
        echo &"[Prefetcher] エラー: {e.msg}"
    
    # 間隔を空けて次のサイクルを実行
    await sleepAsync(prefetcher.prefetchInterval.inMilliseconds.int)

proc stopPrefetcher*(prefetcher: DNSPrefetcher) =
  ## プリフェッチャーを停止
  prefetcher.enabled = false

proc setMaxConcurrentTasks*(prefetcher: DNSPrefetcher, value: int) =
  ## 同時実行タスクの最大数を設定
  prefetcher.maxConcurrentTasks = max(1, value)

proc setMaxQueueLength*(prefetcher: DNSPrefetcher, value: int) =
  ## キューの最大長を設定
  prefetcher.maxQueueLength = max(10, value)

proc setMinTTLThreshold*(prefetcher: DNSPrefetcher, seconds: int) =
  ## プリフェッチを開始するTTLの閾値を設定
  prefetcher.minTTLThreshold = max(10, seconds)

proc setPrefetchInterval*(prefetcher: DNSPrefetcher, seconds: int) =
  ## プリフェッチ間隔を設定
  prefetcher.prefetchInterval = initDuration(seconds=max(10, seconds))

proc getQueueLength*(prefetcher: DNSPrefetcher): int =
  ## 現在のキュー長を取得
  withLock prefetcher.lock:
    result = prefetcher.prefetchQueue.len

proc getActiveTasksCount*(prefetcher: DNSPrefetcher): int =
  ## アクティブなタスク数を取得
  result = atomicLoad(prefetcher.activeTasks)

proc clearQueue*(prefetcher: DNSPrefetcher) =
  ## キューをクリア
  withLock prefetcher.lock:
    prefetcher.prefetchQueue.setLen(0)

proc manualPrefetch*(prefetcher: DNSPrefetcher, domain: string, recordType: string): Future[bool] {.async.} =
  ## 手動でドメインをプリフェッチ
  if not prefetcher.enabled:
    return false
  
  # 既にキャッシュに最新データがある場合はスキップ
  let cached = prefetcher.cache.lookup(domain, recordType)
  if cached.len > 0 and cached[0].remainingTTL > prefetcher.minTTLThreshold * 2:
    return true
  
  let task = PrefetchTask(
    domain: domain,
    recordType: recordType,
    priority: ppCritical,  # 手動プリフェッチは常に最高優先度
    scheduleTime: getTime(),
    ttlExpiration: getTime() + initDuration(seconds=60),  # 仮の期限
    attempts: 0,
    lastAttempt: Time()
  )
  
  try:
    await prefetcher.executePrefetchTask(task)
    return true
  except:
    return false 