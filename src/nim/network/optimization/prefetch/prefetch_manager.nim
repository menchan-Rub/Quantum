import std/[tables, sets, asyncdispatch, httpclient, net, strutils, uri, times, options, hashes, asyncfile, os]
import ../../cache/http_cache_manager
import ../preconnect/preconnect_manager

type
  PrefetchPriority* = enum
    ppVeryLow = 0,    # 非常に低い優先度
    ppLow = 25,       # 低い優先度
    ppNormal = 50,    # 通常の優先度
    ppHigh = 75,      # 高い優先度
    ppVeryHigh = 100  # 非常に高い優先度

  PrefetchStatus* = enum
    psNone,           # 未開始
    psQueued,         # キュー待ち
    psPreconnecting,  # 事前接続中
    psFetching,       # 取得中
    psCompleted,      # 完了
    psCancelled,      # キャンセル
    psFailed          # 失敗

  ResourceType* = enum
    rtHTML,           # HTMLファイル
    rtCSS,            # CSSファイル
    rtJavaScript,     # JavaScriptファイル
    rtImage,          # 画像ファイル
    rtFont,           # フォントファイル
    rtAudio,          # 音声ファイル
    rtVideo,          # 動画ファイル
    rtJSON,           # JSONファイル
    rtXML,            # XMLファイル
    rtOther           # その他

  FetchOptions* = object
    ## フェッチオプション
    headers*: Table[string, string]  # リクエストヘッダー
    method*: string                 # HTTPメソッド
    timeout*: int                   # タイムアウト（ミリ秒）
    followRedirects*: bool          # リダイレクトをフォローするかどうか
    maxRedirects*: int              # 最大リダイレクト回数
    validateCertificates*: bool     # 証明書を検証するかどうか

  PrefetchRequest* = object
    ## 事前フェッチリクエスト
    url*: string                    # URL
    resourceType*: ResourceType     # リソースタイプ
    priority*: PrefetchPriority     # 優先度
    status*: PrefetchStatus         # ステータス
    options*: FetchOptions          # フェッチオプション
    createdAt*: Time                # 作成時刻
    startedAt*: Option[Time]        # 開始時刻
    completedAt*: Option[Time]      # 完了時刻
    error*: Option[string]          # エラーメッセージ
    parentUrl*: Option[string]      # 親URL
    bytesFetched*: int              # 取得したバイト数
    totalBytes*: int                # 合計バイト数
    preconnectOnly*: bool           # 事前接続のみを行うかどうか

  PrefetchManager* = object
    ## 事前フェッチマネージャー
    preconnectManager*: PreconnectManager  # 事前接続マネージャー
    cacheManager*: HttpCacheManager       # キャッシュマネージャー
    activeRequests*: Table[string, PrefetchRequest]  # アクティブなリクエスト
    queuedRequests*: Table[string, PrefetchRequest]  # キュー待ちのリクエスト
    completedRequests*: Table[string, PrefetchRequest]  # 完了したリクエスト
    failedRequests*: Table[string, PrefetchRequest]  # 失敗したリクエスト
    maxConcurrentFetches*: int     # 最大同時フェッチ数
    userAgent*: string             # ユーザーエージェント
    acceptHeader*: string          # Acceptヘッダー
    maxQueueSize*: int             # 最大キューサイズ
    prefetchTimeout*: int          # 事前フェッチタイムアウト（ミリ秒）
    prefetchDirectory*: string     # 事前フェッチディレクトリ
    enableDiskCache*: bool         # ディスクキャッシュを有効にするかどうか
    autoCleanupInterval*: int      # 自動クリーンアップ間隔（ミリ秒）
    lastCleanupTime*: Time         # 最後のクリーンアップ時刻
    isRunning*: bool               # 実行中かどうか

proc hash*(request: PrefetchRequest): Hash =
  ## PrefetchRequestのハッシュ関数
  var h: Hash = 0
  h = h !& hash(request.url)
  h = h !& hash(request.resourceType)
  h = h !& hash(request.priority)
  result = !$h

proc defaultFetchOptions*(): FetchOptions =
  ## デフォルトのフェッチオプションを取得する
  result = FetchOptions(
    headers: {"Accept": "*/*"}.toTable,
    method: "GET",
    timeout: 30000,  # 30秒
    followRedirects: true,
    maxRedirects: 10,
    validateCertificates: true
  )

proc newPrefetchManager*(
  preconnectManager: PreconnectManager,
  cacheManager: HttpCacheManager,
  maxConcurrentFetches: int = 6,
  userAgent: string = "NimBrowser/1.0 Prefetch",
  acceptHeader: string = "*/*",
  maxQueueSize: int = 100,
  prefetchTimeout: int = 30000,  # 30秒
  prefetchDirectory: string = "prefetch",
  enableDiskCache: bool = true,
  autoCleanupInterval: int = 300000  # 5分
): PrefetchManager =
  ## 新しいPrefetchManagerを作成する
  
  # 事前フェッチディレクトリを作成
  if enableDiskCache and not dirExists(prefetchDirectory):
    createDir(prefetchDirectory)
  
  result = PrefetchManager(
    preconnectManager: preconnectManager,
    cacheManager: cacheManager,
    activeRequests: initTable[string, PrefetchRequest](),
    queuedRequests: initTable[string, PrefetchRequest](),
    completedRequests: initTable[string, PrefetchRequest](),
    failedRequests: initTable[string, PrefetchRequest](),
    maxConcurrentFetches: maxConcurrentFetches,
    userAgent: userAgent,
    acceptHeader: acceptHeader,
    maxQueueSize: maxQueueSize,
    prefetchTimeout: prefetchTimeout,
    prefetchDirectory: prefetchDirectory,
    enableDiskCache: enableDiskCache,
    autoCleanupInterval: autoCleanupInterval,
    lastCleanupTime: getTime(),
    isRunning: false
  )

proc guessResourceType*(url: string): ResourceType =
  ## URLからリソースタイプを推測する
  let parsedUrl = parseUri(url)
  let path = parsedUrl.path.toLowerAscii()
  
  if path.endsWith(".html") or path.endsWith(".htm"):
    return rtHTML
  elif path.endsWith(".css"):
    return rtCSS
  elif path.endsWith(".js"):
    return rtJavaScript
  elif path.endsWith(".jpg") or path.endsWith(".jpeg") or 
       path.endsWith(".png") or path.endsWith(".gif") or 
       path.endsWith(".webp") or path.endsWith(".svg"):
    return rtImage
  elif path.endsWith(".woff") or path.endsWith(".woff2") or 
       path.endsWith(".ttf") or path.endsWith(".otf") or 
       path.endsWith(".eot"):
    return rtFont
  elif path.endsWith(".mp3") or path.endsWith(".wav") or 
       path.endsWith(".ogg") or path.endsWith(".aac"):
    return rtAudio
  elif path.endsWith(".mp4") or path.endsWith(".webm") or 
       path.endsWith(".ogv") or path.endsWith(".avi"):
    return rtVideo
  elif path.endsWith(".json"):
    return rtJSON
  elif path.endsWith(".xml"):
    return rtXML
  else:
    return rtOther

proc getPriorityForResourceType*(resourceType: ResourceType): PrefetchPriority =
  ## リソースタイプに基づいて優先度を取得する
  case resourceType
  of rtHTML:
    return ppVeryHigh
  of rtCSS, rtJavaScript:
    return ppHigh
  of rtFont:
    return ppNormal
  of rtImage:
    return ppLow
  of rtJSON, rtXML:
    return ppNormal
  of rtAudio, rtVideo:
    return ppVeryLow
  else:
    return ppLow

proc createPrefetchRequest*(
  url: string, 
  resourceType: ResourceType = rtOther,
  priority: PrefetchPriority = ppNormal,
  options: FetchOptions = defaultFetchOptions(),
  parentUrl: Option[string] = none(string),
  preconnectOnly: bool = false
): PrefetchRequest =
  ## 新しいPrefetchRequestを作成する
  let actualResourceType = if resourceType == rtOther: guessResourceType(url) else: resourceType
  let actualPriority = if priority == ppNormal: getPriorityForResourceType(actualResourceType) else: priority
  
  result = PrefetchRequest(
    url: url,
    resourceType: actualResourceType,
    priority: actualPriority,
    status: psNone,
    options: options,
    createdAt: getTime(),
    startedAt: none(Time),
    completedAt: none(Time),
    error: none(string),
    parentUrl: parentUrl,
    bytesFetched: 0,
    totalBytes: 0,
    preconnectOnly: preconnectOnly
  )

proc enqueue*(manager: var PrefetchManager, request: PrefetchRequest): bool =
  ## リクエストをキューに追加する
  if manager.queuedRequests.len >= manager.maxQueueSize:
    # キューがいっぱいの場合、最も優先度の低いリクエストを見つけて比較
    var lowestPriorityKey = ""
    var lowestPriority = high(int)
    
    for key, req in manager.queuedRequests:
      if ord(req.priority) < lowestPriority:
        lowestPriority = ord(req.priority)
        lowestPriorityKey = key
    
    # 新しいリクエストの優先度が最も低いものより低い場合は拒否
    if ord(request.priority) <= lowestPriority:
      return false
    
    # 最も優先度の低いリクエストを削除
    if lowestPriorityKey != "":
      manager.queuedRequests.del(lowestPriorityKey)
  
  # キューに追加
  var newRequest = request
  newRequest.status = psQueued
  manager.queuedRequests[request.url] = newRequest
  return true

proc prefetch*(manager: var PrefetchManager, url: string, 
              priority: PrefetchPriority = ppNormal,
              preconnectOnly: bool = false,
              parentUrl: Option[string] = none(string)): Future[PrefetchRequest] {.async.} =
  ## URLを事前フェッチする
  if not manager.isRunning:
    manager.isRunning = true
  
  # 既にキャッシュにあるかチェック
  let cached = manager.cacheManager.get(url)
  if cached.isSome:
    let (entry, _) = cached.get()
    var request = createPrefetchRequest(
      url = url,
      resourceType = guessResourceType(url),
      priority = priority,
      options = defaultFetchOptions(),
      parentUrl = parentUrl,
      preconnectOnly = preconnectOnly
    )
    request.status = psCompleted
    request.completedAt = some(getTime())
    request.bytesFetched = entry.contentLength
    request.totalBytes = entry.contentLength
    
    # 完了したリクエストに追加
    manager.completedRequests[url] = request
    return request
  
  # リクエストを作成
  var request = createPrefetchRequest(
    url = url,
    resourceType = guessResourceType(url),
    priority = priority,
    options = defaultFetchOptions(),
    parentUrl = parentUrl,
    preconnectOnly = preconnectOnly
  )
  
  # 事前接続のみの場合
  if preconnectOnly:
    request.status = psPreconnecting
    request.startedAt = some(getTime())
    
    # URLを解析
    let parsedUrl = parseUri(url)
    let preconnectUrl = $parsedUrl.scheme & "://" & parsedUrl.hostname
    
    # 事前接続を実行
    let connectionInfo = await manager.preconnectManager.preconnect(preconnectUrl, ord(priority))
    
    # 結果を設定
    if connectionInfo.state == csEstablished:
      request.status = psCompleted
      request.completedAt = some(getTime())
      manager.completedRequests[url] = request
    else:
      request.status = psFailed
      request.error = connectionInfo.error
      manager.failedRequests[url] = request
    
    return request
  
  # アクティブなフェッチ数をチェック
  if manager.activeRequests.len >= manager.maxConcurrentFetches:
    # キューに追加
    if manager.enqueue(request):
      return request
    else:
      # キューに入れられなかった場合
      request.status = psFailed
      request.error = some("キューがいっぱいです。優先度が低すぎます。")
      manager.failedRequests[url] = request
      return request
  
  # 事前フェッチを実行
  request.status = psFetching
  request.startedAt = some(getTime())
  manager.activeRequests[url] = request
  
  try:
    # HTTPクライアントを作成
    var client = newAsyncHttpClient(
      userAgent = manager.userAgent,
      timeout = request.options.timeout,
      maxRedirects = request.options.maxRedirects
    )
    
    # ヘッダーを設定
    client.headers = newHttpHeaders({
      "Accept": manager.acceptHeader,
      "Purpose": "prefetch",
      "X-Moz-Preload": "1"  # Firefox互換ヘッダー
    })
    
    # リクエストのヘッダーを追加
    for key, value in request.options.headers:
      client.headers[key] = value
    
    # リクエストを送信
    let response = await client.get(url)
    
    # 成功した場合
    if response.code.is2xx or response.code.is3xx:
      # レスポンスボディを読み込む
      let body = await response.body
      let contentLength = body.len
      
      # リクエスト情報を更新
      request.bytesFetched = contentLength
      request.totalBytes = contentLength
      
      # キャッシュに保存
      let cacheEntry = newHttpCacheEntry(
        url = url,
        statusCode = response.code.int,
        headers = response.headers,
        body = body,
        expires = none(Time),
        lastModified = none(Time),
        etag = none(string),
        contentType = response.headers.getOrDefault("content-type"),
        contentLength = contentLength,
        fetchTime = getTime()
      )
      
      manager.cacheManager.put(url, cacheEntry)
      
      # ディスクキャッシュが有効な場合、ディスクにも保存
      if manager.enableDiskCache:
        let urlHash = $hash(url)
        let cachePath = manager.prefetchDirectory / urlHash
        
        # メタデータを保存
        let metaPath = cachePath & ".meta"
        var metaFile = open(metaPath, fmWrite)
        metaFile.write($cacheEntry)
        metaFile.close()
        
        # コンテンツを保存
        let contentPath = cachePath & ".data"
        var contentFile = open(contentPath, fmWrite)
        contentFile.write(body)
        contentFile.close()
      
      # 完了状態に更新
      request.status = psCompleted
      request.completedAt = some(getTime())
      
      # アクティブリクエストから完了リクエストに移動
      manager.activeRequests.del(url)
      manager.completedRequests[url] = request
    else:
      # エラーの場合
      request.status = psFailed
      request.error = some("HTTPエラー: " & $response.code.int)
      
      # アクティブリクエストから失敗リクエストに移動
      manager.activeRequests.del(url)
      manager.failedRequests[url] = request
    
    # クライアントを閉じる
    client.close()
  
  except Exception as e:
    # 例外が発生した場合
    request.status = psFailed
    request.error = some("例外: " & e.msg)
    
    # アクティブリクエストから失敗リクエストに移動
    manager.activeRequests.del(url)
    manager.failedRequests[url] = request
  
  # 次のキューされたリクエストを処理
  if manager.queuedRequests.len > 0 and manager.activeRequests.len < manager.maxConcurrentFetches:
    proc processNextQueuedRequest() {.async.} =
      # 優先度順でソートされたキーのリスト
      var sortedKeys: seq[string] = @[]
      for key in manager.queuedRequests.keys:
        sortedKeys.add(key)
      
      sortedKeys.sort(proc(a, b: string): int =
        result = ord(manager.queuedRequests[b].priority) - ord(manager.queuedRequests[a].priority)
      )
      
      if sortedKeys.len > 0:
        let nextKey = sortedKeys[0]
        let nextRequest = manager.queuedRequests[nextKey]
        manager.queuedRequests.del(nextKey)
        
        discard await manager.prefetch(
          nextRequest.url,
          nextRequest.priority,
          nextRequest.preconnectOnly,
          nextRequest.parentUrl
        )
    
    asyncCheck processNextQueuedRequest()
  
  # 定期的なクリーンアップを実行
  let currentTime = getTime()
  if (currentTime - manager.lastCleanupTime).inMilliseconds >= manager.autoCleanupInterval:
    manager.cleanupCompletedRequests()
    manager.lastCleanupTime = currentTime
  
  return request

proc cleanupCompletedRequests*(manager: var PrefetchManager) =
  ## 完了したリクエストをクリーンアップする
  let currentTime = getTime()
  var keysToRemove: seq[string] = @[]
  
  # 1時間以上前に完了したリクエストをクリーンアップ
  for key, request in manager.completedRequests:
    if request.completedAt.isSome:
      let completedAt = request.completedAt.get()
      if (currentTime - completedAt).inHours >= 1:
        keysToRemove.add(key)
  
  # キーを削除
  for key in keysToRemove:
    manager.completedRequests.del(key)
  
  # 失敗したリクエストもクリーンアップ
  keysToRemove = @[]
  for key, request in manager.failedRequests:
    if request.completedAt.isSome or request.startedAt.isSome:
      let checkTime = if request.completedAt.isSome: request.completedAt.get() else: request.startedAt.get()
      if (currentTime - checkTime).inHours >= 1:
        keysToRemove.add(key)
  
  # キーを削除
  for key in keysToRemove:
    manager.failedRequests.del(key)

proc cancelRequest*(manager: var PrefetchManager, url: string) =
  ## リクエストをキャンセルする
  if url in manager.queuedRequests:
    var request = manager.queuedRequests[url]
    request.status = psCancelled
    manager.queuedRequests.del(url)
    manager.failedRequests[url] = request
  
  elif url in manager.activeRequests:
    var request = manager.activeRequests[url]
    request.status = psCancelled
    manager.activeRequests.del(url)
    manager.failedRequests[url] = request

proc cancelAll*(manager: var PrefetchManager) =
  ## すべてのリクエストをキャンセルする
  for url in toSeq(manager.queuedRequests.keys):
    manager.cancelRequest(url)
  
  for url in toSeq(manager.activeRequests.keys):
    manager.cancelRequest(url)

proc stop*(manager: var PrefetchManager) =
  ## マネージャーを停止する
  manager.isRunning = false
  manager.cancelAll()

proc getRequestStatus*(manager: PrefetchManager, url: string): PrefetchStatus =
  ## リクエストのステータスを取得する
  if url in manager.completedRequests:
    return manager.completedRequests[url].status
  elif url in manager.activeRequests:
    return manager.activeRequests[url].status
  elif url in manager.queuedRequests:
    return manager.queuedRequests[url].status
  elif url in manager.failedRequests:
    return manager.failedRequests[url].status
  else:
    return psNone

proc getRequestStats*(manager: PrefetchManager): tuple[
  active: int, queued: int, completed: int, failed: int, totalBytes: int
] =
  ## リクエストの統計情報を取得する
  var totalBytes = 0
  
  for _, request in manager.completedRequests:
    totalBytes += request.bytesFetched
  
  return (
    active: manager.activeRequests.len,
    queued: manager.queuedRequests.len,
    completed: manager.completedRequests.len,
    failed: manager.failedRequests.len,
    totalBytes: totalBytes
  )

proc analyzePrefetchPerformance*(manager: PrefetchManager): tuple[
  successRate: float, avgFetchTimeMs: int, bytesPerSecond: float, hitRate: float, 
  cacheEfficiency: float, resourceSavings: int, predictiveAccuracy: float, overheadRatio: float
] =
  ## 事前フェッチのパフォーマンスを分析する
  ## 詳細な統計情報と効率性指標を提供する
  
  # 基本的な成功率の計算
  let totalRequests = manager.completedRequests.len + manager.failedRequests.len
  let successRate = if totalRequests > 0: float(manager.completedRequests.len) / float(totalRequests) else: 0.0
  
  var totalFetchTimeMs = 0
  var totalBytes = 0
  var completedCount = 0
  var totalWaitTime = 0  # キューでの待機時間
  var totalNetworkTime = 0  # 実際のネットワーク転送時間
  var totalOverhead = 0  # プリフェッチ処理のオーバーヘッド
  
  for url, request in manager.completedRequests:
    if request.startedAt.isSome and request.completedAt.isSome:
      let fetchTimeMs = (request.completedAt.get() - request.startedAt.get()).inMilliseconds
      totalFetchTimeMs += fetchTimeMs
      totalBytes += request.bytesFetched
      
      # キュー待機時間の計算（キューに入れられた時間から開始時間を引く）
      if request.queuedAt.isSome:
        totalWaitTime += (request.startedAt.get() - request.queuedAt.get()).inMilliseconds
      
      # ネットワーク転送時間の推定（全体の80%と仮定）
      totalNetworkTime += int(fetchTimeMs * 0.8)
      
      # オーバーヘッド時間の計算（全体の20%と仮定）
      totalOverhead += int(fetchTimeMs * 0.2)
      
      completedCount += 1
  
  # 平均フェッチ時間（ミリ秒）
  let avgFetchTimeMs = if completedCount > 0: totalFetchTimeMs div completedCount else: 0
  
  # バイト/秒のスループット計算
  let bytesPerSecond = if totalFetchTimeMs > 0: (totalBytes.float / (totalFetchTimeMs.float / 1000.0)) else: 0.0
  
  # キャッシュ効率性（キャッシュヒット数 / 総リクエスト数）
  var cacheHits = 0
  for url, request in manager.completedRequests:
    if request.fromCache:
      cacheHits += 1
  
  let cacheEfficiency = if totalRequests > 0: float(cacheHits) / float(totalRequests) else: 0.0
  
  # リソース節約量（バイト）- プリフェッチによって節約された帯域幅の推定
  var resourceSavings = 0
  for url, request in manager.completedRequests:
    if request.wasUsed:
      resourceSavings += request.bytesFetched
  
  # 予測精度 - プリフェッチされたリソースのうち実際に使用された割合
  var usedResources = 0
  for url, request in manager.completedRequests:
    if request.wasUsed:
      usedResources += 1
  
  let predictiveAccuracy = if completedCount > 0: float(usedResources) / float(completedCount) else: 0.0
  
  # オーバーヘッド比率 - プリフェッチ処理に費やされた時間の割合
  let overheadRatio = if totalFetchTimeMs > 0: float(totalOverhead) / float(totalFetchTimeMs) else: 0.0
  
  # ヒット率の計算 - 実際のページロード時に事前フェッチされたリソースが使用された割合
  let hitRate = if manager.accessedResources > 0: 
                  float(manager.prefetchHits) / float(manager.accessedResources) 
                else: 0.0
  
  return (
    successRate: successRate,
    avgFetchTimeMs: avgFetchTimeMs,
    bytesPerSecond: bytesPerSecond,
    hitRate: hitRate,
    cacheEfficiency: cacheEfficiency,
    resourceSavings: resourceSavings,
    predictiveAccuracy: predictiveAccuracy,
    overheadRatio: overheadRatio
  )

when isMainModule:
  # テスト用コード
  import asyncdispatch
  
  proc testPrefetch() {.async.} =
    echo "PrefetchManagerのテスト"
    
    # PreconnectManagerを作成
    let dnsResolver = newDnsResolver()
    let preconnectManager = newPreconnectManager(dnsResolver = dnsResolver)
    
    # HttpCacheManagerを作成
    let cacheManager = newHttpCacheManager()
    
    # PrefetchManagerを作成
    var prefetchManager = newPrefetchManager(
      preconnectManager = preconnectManager,
      cacheManager = cacheManager,
      maxConcurrentFetches = 3,
      prefetchDirectory = "test_prefetch",
      enableDiskCache = true
    )
    
    # URLを事前フェッチ
    let request1 = await prefetchManager.prefetch(
      url = "https://example.com",
      priority = ppHigh
    )
    
    echo "リクエスト1のステータス: ", request1.status
    
    if request1.status == psCompleted:
      echo "完了しました！"
      echo "取得したバイト数: ", request1.bytesFetched
    else:
      echo "失敗しました："
      if request1.error.isSome:
        echo request1.error.get()
    
    # 統計情報を表示
    let stats = prefetchManager.getRequestStats()
    echo "統計情報："
    echo "  アクティブ: ", stats.active
    echo "  キュー待ち: ", stats.queued
    echo "  完了: ", stats.completed
    echo "  失敗: ", stats.failed
    echo "  合計バイト数: ", stats.totalBytes
    
    # パフォーマンス分析
    let perf = prefetchManager.analyzePrefetchPerformance()
    echo "パフォーマンス："
    echo "  成功率: ", perf.successRate * 100, "%"
    echo "  平均フェッチ時間: ", perf.avgFetchTimeMs, "ms"
    echo "  バイト/秒: ", perf.bytesPerSecond
    
    # マネージャーを停止
    prefetchManager.stop()
  
  waitFor testPrefetch() 