import std/[tables, sets, strutils, uri, times, options, hashes, algorithm, sequtils]
import ../prefetch/prefetch_manager

type
  PriorityLevel* = enum
    plHighest = 0,     # 最高優先度
    plVeryHigh = 1,    # 非常に高い優先度
    plHigh = 2,        # 高い優先度
    plMediumHigh = 3,  # 中高優先度
    plMedium = 4,      # 中程度の優先度
    plMediumLow = 5,   # 中低優先度
    plLow = 6,         # 低い優先度
    plVeryLow = 7,     # 非常に低い優先度
    plLowest = 8       # 最低優先度

  PriorityHint* = enum
    phHighest,         # 最高優先度のヒント
    phHigh,            # 高い優先度のヒント
    phNormal,          # 通常の優先度のヒント
    phLow,             # 低い優先度のヒント
    phLowest           # 最低優先度のヒント

  ResourcePriority* = object
    ## リソース優先度
    url*: string                # URL
    level*: PriorityLevel       # 優先度レベル
    weight*: float              # 重み (0.0〜1.0)
    dependsOn*: seq[string]     # 依存リソースのURL
    renderBlocking*: bool       # レンダリングブロッキングかどうか
    userHint*: Option[PriorityHint]  # ユーザー指定のヒント
    resourceType*: ResourceType # リソースタイプ
    inViewport*: bool           # ビューポート内かどうか
    loadTime*: Option[Time]     # 読み込み時間
    size*: Option[int]          # サイズ（バイト）
    isPreload*: bool            # プリロードリソースかどうか
    isCriticalPath*: bool       # クリティカルパス上かどうか

  DependencyGraph* = object
    ## 依存関係グラフ
    nodes*: Table[string, seq[string]]  # ノード（URL）から依存先への辺
    reverseNodes*: Table[string, seq[string]]  # 依存先からノードへの逆辺

  ResourcePrioritizer* = object
    ## リソース優先順位付けマネージャー
    priorities*: Table[string, ResourcePriority]  # URLごとの優先度
    dependencyGraph*: DependencyGraph  # 依存関係グラフ
    criticalResources*: HashSet[string]  # クリティカルリソース
    viewportResources*: HashSet[string]  # ビューポート内リソース
    resourceOrder*: seq[string]  # リソース読み込み順序
    lastPrioritizationTime*: Time  # 最後の優先順位付け時間
    mediaTypes*: Table[string, string]  # URLごとのメディアタイプ

proc hash*(priority: ResourcePriority): Hash =
  ## ResourcePriorityのハッシュ関数
  var h: Hash = 0
  h = h !& hash(priority.url)
  h = h !& hash(priority.level)
  h = h !& hash(priority.renderBlocking)
  result = !$h

proc newResourcePrioritizer*(): ResourcePrioritizer =
  ## 新しいResourcePrioritizerを作成する
  result = ResourcePrioritizer(
    priorities: initTable[string, ResourcePriority](),
    dependencyGraph: DependencyGraph(
      nodes: initTable[string, seq[string]](),
      reverseNodes: initTable[string, seq[string]]()
    ),
    criticalResources: initHashSet[string](),
    viewportResources: initHashSet[string](),
    resourceOrder: @[],
    lastPrioritizationTime: getTime(),
    mediaTypes: initTable[string, string]()
  )

proc guessMediaType*(url: string): string =
  ## URLからメディアタイプを推測する
  let resourceType = guessResourceType(url)
  
  case resourceType
  of rtHTML:
    return "text/html"
  of rtCSS:
    return "text/css"
  of rtJavaScript:
    return "application/javascript"
  of rtJSON:
    return "application/json"
  of rtXML:
    return "application/xml"
  of rtImage:
    # 拡張子からより詳細なメディアタイプを推測
    let path = parseUri(url).path.toLowerAscii()
    if path.endsWith(".jpg") or path.endsWith(".jpeg"):
      return "image/jpeg"
    elif path.endsWith(".png"):
      return "image/png"
    elif path.endsWith(".gif"):
      return "image/gif"
    elif path.endsWith(".webp"):
      return "image/webp"
    elif path.endsWith(".svg"):
      return "image/svg+xml"
    else:
      return "image/*"
  of rtFont:
    # フォント形式を推測
    let path = parseUri(url).path.toLowerAscii()
    if path.endsWith(".woff2"):
      return "font/woff2"
    elif path.endsWith(".woff"):
      return "font/woff"
    elif path.endsWith(".ttf"):
      return "font/ttf"
    elif path.endsWith(".otf"):
      return "font/otf"
    else:
      return "font/*"
  of rtAudio:
    return "audio/*"
  of rtVideo:
    return "video/*"
  else:
    return "application/octet-stream"

proc getDefaultPriorityLevel*(resourceType: ResourceType, isInViewport: bool = false): PriorityLevel =
  ## リソースタイプに基づいてデフォルトの優先度レベルを取得する
  case resourceType
  of rtHTML:
    return plHighest
  of rtCSS:
    return plVeryHigh
  of rtJavaScript:
    if isInViewport:
      return plHigh
    else:
      return plMediumHigh
  of rtFont:
    return plMediumHigh
  of rtImage:
    if isInViewport:
      return plMedium
    else:
      return plMediumLow
  of rtJSON, rtXML:
    return plMedium
  of rtAudio:
    return plLow
  of rtVideo:
    if isInViewport:
      return plMedium
    else:
      return plLow
  else:
    return plVeryLow

proc createResourcePriority*(
  url: string,
  resourceType: ResourceType = rtOther,
  isInViewport: bool = false,
  renderBlocking: bool = false,
  userHint: Option[PriorityHint] = none(PriorityHint),
  size: Option[int] = none(int),
  dependsOn: seq[string] = @[]
): ResourcePriority =
  ## リソース優先度を作成する
  let actualResourceType = if resourceType == rtOther: guessResourceType(url) else: resourceType
  var level = getDefaultPriorityLevel(actualResourceType, isInViewport)
  
  # ユーザーヒントがある場合は優先度を調整
  if userHint.isSome:
    case userHint.get()
    of phHighest:
      level = plHighest
    of phHigh:
      level = plHigh
    of phNormal:
      level = plMedium
    of phLow:
      level = plLow
    of phLowest:
      level = plLowest
  
  # レンダリングブロッキングリソースは高い優先度
  if renderBlocking:
    if level > plHigh:  # 現在の優先度がplHigh以下の場合のみ上げる
      level = plHigh
  
  # クリティカルパスチェック
  let isCriticalPath = actualResourceType in [rtHTML, rtCSS] or renderBlocking
  
  result = ResourcePriority(
    url: url,
    level: level,
    weight: 1.0,  # デフォルトの重み
    dependsOn: dependsOn,
    renderBlocking: renderBlocking,
    userHint: userHint,
    resourceType: actualResourceType,
    inViewport: isInViewport,
    loadTime: none(Time),
    size: size,
    isPreload: false,
    isCriticalPath: isCriticalPath
  )

proc addResource*(prioritizer: var ResourcePrioritizer, priority: ResourcePriority) =
  ## リソースをプライオリタイザーに追加する
  prioritizer.priorities[priority.url] = priority
  
  # 依存関係グラフに追加
  if priority.dependsOn.len > 0:
    prioritizer.dependencyGraph.nodes[priority.url] = priority.dependsOn
    
    # 逆方向のエッジも追加
    for dep in priority.dependsOn:
      if not prioritizer.dependencyGraph.reverseNodes.hasKey(dep):
        prioritizer.dependencyGraph.reverseNodes[dep] = @[]
      
      prioritizer.dependencyGraph.reverseNodes[dep].add(priority.url)
  
  # クリティカルリソースの場合は追加
  if priority.isCriticalPath:
    prioritizer.criticalResources.incl(priority.url)
  
  # ビューポート内リソースの場合は追加
  if priority.inViewport:
    prioritizer.viewportResources.incl(priority.url)
  
  # メディアタイプを設定
  prioritizer.mediaTypes[priority.url] = guessMediaType(priority.url)

proc prioritize*(prioritizer: var ResourcePrioritizer) =
  ## リソースの優先順位付けを実行する
  var priorityGroups: array[PriorityLevel.low..PriorityLevel.high, seq[string]] 
  
  # リソースを優先度グループに分類
  for url, priority in prioritizer.priorities:
    priorityGroups[priority.level].add(url)
  
  # 優先度の高いグループから順番に処理
  var newOrder: seq[string] = @[]
  for level in PriorityLevel.low..PriorityLevel.high:
    var currentGroup = priorityGroups[level]
    
    # 同じ優先度内でさらにソート
    currentGroup.sort(proc(a, b: string): int =
      let prioA = prioritizer.priorities[a]
      let prioB = prioritizer.priorities[b]
      
      # ビューポート内のリソースを優先
      if prioA.inViewport and not prioB.inViewport:
        return -1
      elif not prioA.inViewport and prioB.inViewport:
        return 1
      
      # レンダリングブロッキングリソースを優先
      if prioA.renderBlocking and not prioB.renderBlocking:
        return -1
      elif not prioA.renderBlocking and prioB.renderBlocking:
        return 1
      
      # 重みによるソート（大きいほど優先）
      if prioA.weight > prioB.weight:
        return -1
      elif prioA.weight < prioB.weight:
        return 1
      
      # タイプによるソート（HTMLやCSSを優先）
      if ord(prioA.resourceType) < ord(prioB.resourceType):
        return -1
      elif ord(prioA.resourceType) > ord(prioB.resourceType):
        return 1
      
      # それ以外の場合はURLで比較（一貫性のためのフォールバック）
      return cmp(a, b)
    )
    
    # このグループのリソースを追加
    newOrder.add(currentGroup)
  
  # 平坦化した順序を設定
  prioritizer.resourceOrder = newOrder.concat()
  
  # 依存関係に基づいて順序を調整
  prioritizer.adjustOrderByDependencies()
  
  # 最後の優先順位付け時間を更新
  prioritizer.lastPrioritizationTime = getTime()

proc adjustOrderByDependencies*(prioritizer: var ResourcePrioritizer) =
  ## 依存関係に基づいて順序を調整する
  # 依存関係チェック
  var adjustedOrder: seq[string] = @[]
  var processedUrls = initHashSet[string]()
  
  # トポロジカルソート
  proc visit(url: string) =
    if url in processedUrls:
      return
    
    # 依存するリソースを先に処理
    if prioritizer.dependencyGraph.nodes.hasKey(url):
      for dep in prioritizer.dependencyGraph.nodes[url]:
        visit(dep)
    
    # このリソースを追加
    if url notin processedUrls:
      adjustedOrder.add(url)
      processedUrls.incl(url)
  
  # 現在の順序でリソースを走査
  for url in prioritizer.resourceOrder:
    visit(url)
  
  # 調整された順序を設定
  prioritizer.resourceOrder = adjustedOrder

proc calculateResourceWeight*(prioritizer: var ResourcePrioritizer, url: string) =
  ## リソースの重みを計算する
  if url notin prioritizer.priorities:
    return
  
  var priority = prioritizer.priorities[url]
  var weight = 1.0
  
  # ビューポート内リソースは重みを増加
  if priority.inViewport:
    weight *= 1.5
  
  # レンダリングブロッキングリソースは重みを増加
  if priority.renderBlocking:
    weight *= 2.0
  
  # 依存されるリソースは重みを増加
  if prioritizer.dependencyGraph.reverseNodes.hasKey(url):
    weight *= 1.0 + (0.2 * prioritizer.dependencyGraph.reverseNodes[url].len.float)
  
  # 依存するリソースが多いものは重みを減少
  if prioritizer.dependencyGraph.nodes.hasKey(url):
    weight *= 1.0 / (1.0 + (0.1 * prioritizer.dependencyGraph.nodes[url].len.float))
  
  # サイズが大きいリソースは重みを減少
  if priority.size.isSome and priority.size.get() > 100 * 1024:  # 100KB以上
    weight *= 0.9
  
  # クリティカルパス上のリソースは重みを増加
  if priority.isCriticalPath:
    weight *= 1.5
  
  # リソースタイプに基づく重み調整
  case priority.resourceType
  of rtHTML:
    weight *= 1.5
  of rtCSS:
    weight *= 1.3
  of rtJavaScript:
    weight *= 1.2
  of rtFont:
    weight *= 1.1
  else:
    discard
  
  # プリロードリソースは重みを増加
  if priority.isPreload:
    weight *= 1.2
  
  # 重みを更新
  priority.weight = weight
  prioritizer.priorities[url] = priority

proc calculateAllWeights*(prioritizer: var ResourcePrioritizer) =
  ## すべてのリソースの重みを計算する
  for url in prioritizer.priorities.keys:
    prioritizer.calculateResourceWeight(url)

proc findCriticalPath*(prioritizer: var ResourcePrioritizer) =
  ## クリティカルパスを特定する
  # クリティカルリソースを初期化
  prioritizer.criticalResources = initHashSet[string]()
  
  # ベースとなるクリティカルリソースを特定
  for url, priority in prioritizer.priorities:
    if priority.renderBlocking or
       priority.resourceType == rtHTML or
       priority.resourceType == rtCSS or
       (priority.resourceType == rtJavaScript and priority.inViewport) or
       (priority.resourceType == rtFont and priority.inViewport):
      prioritizer.criticalResources.incl(url)
  
  # 依存関係の解析
  var newCriticalResources = true
  while newCriticalResources:
    newCriticalResources = false
    
    let currentCritical = prioritizer.criticalResources
    for criticalUrl in currentCritical:
      # このクリティカルリソースに依存するリソースを追加
      if prioritizer.dependencyGraph.reverseNodes.hasKey(criticalUrl):
        for dependentUrl in prioritizer.dependencyGraph.reverseNodes[criticalUrl]:
          if dependentUrl notin prioritizer.criticalResources:
            prioritizer.criticalResources.incl(dependentUrl)
            newCriticalResources = true
      
      # このクリティカルリソースが依存するリソースを追加
      if prioritizer.dependencyGraph.nodes.hasKey(criticalUrl):
        for dependencyUrl in prioritizer.dependencyGraph.nodes[criticalUrl]:
          if dependencyUrl notin prioritizer.criticalResources:
            prioritizer.criticalResources.incl(dependencyUrl)
            newCriticalResources = true

proc updateLoadTime*(prioritizer: var ResourcePrioritizer, url: string, loadTime: Time) =
  ## リソースの読み込み時間を更新する
  if url in prioritizer.priorities:
    var priority = prioritizer.priorities[url]
    priority.loadTime = some(loadTime)
    prioritizer.priorities[url] = priority

proc updateSize*(prioritizer: var ResourcePrioritizer, url: string, size: int) =
  ## リソースのサイズを更新する
  if url in prioritizer.priorities:
    var priority = prioritizer.priorities[url]
    priority.size = some(size)
    prioritizer.priorities[url] = priority
    
    # サイズが更新されたら重みを再計算
    prioritizer.calculateResourceWeight(url)

proc markAsPreload*(prioritizer: var ResourcePrioritizer, url: string) =
  ## リソースをプリロードとしてマークする
  if url in prioritizer.priorities:
    var priority = prioritizer.priorities[url]
    priority.isPreload = true
    prioritizer.priorities[url] = priority
    
    # プリロードとしてマークされたら重みを再計算
    prioritizer.calculateResourceWeight(url)

proc getHighestPriorityResources*(prioritizer: ResourcePrioritizer, count: int = 10): seq[string] =
  ## 最も優先度の高いリソースを取得する
  let maxCount = min(count, prioritizer.resourceOrder.len)
  return prioritizer.resourceOrder[0..<maxCount]

proc getCriticalResources*(prioritizer: ResourcePrioritizer): seq[string] =
  ## クリティカルリソースを取得する
  for url in prioritizer.criticalResources:
    result.add(url)

proc getResourceMediaType*(prioritizer: ResourcePrioritizer, url: string): string =
  ## リソースのメディアタイプを取得する
  if url in prioritizer.mediaTypes:
    return prioritizer.mediaTypes[url]
  else:
    return guessMediaType(url)

proc getDependentResources*(prioritizer: ResourcePrioritizer, url: string): seq[string] =
  ## 指定されたリソースに依存するリソースを取得する
  if url in prioritizer.dependencyGraph.reverseNodes:
    return prioritizer.dependencyGraph.reverseNodes[url]
  else:
    return @[]

proc getDependencies*(prioritizer: ResourcePrioritizer, url: string): seq[string] =
  ## 指定されたリソースが依存するリソースを取得する
  if url in prioritizer.dependencyGraph.nodes:
    return prioritizer.dependencyGraph.nodes[url]
  else:
    return @[]

proc generatePreloadUrls*(prioritizer: ResourcePrioritizer, count: int = 5): seq[tuple[url: string, `as`: string]] =
  ## プリロードURLを生成する
  result = @[]
  var preloadCount = 0
  
  for url in prioritizer.resourceOrder:
    if preloadCount >= count:
      break
    
    if url in prioritizer.criticalResources:
      let priority = prioritizer.priorities[url]
      let mediaType = prioritizer.getResourceMediaType(url)
      
      var asAttribute = ""
      case priority.resourceType
      of rtCSS:
        asAttribute = "style"
      of rtJavaScript:
        asAttribute = "script"
      of rtFont:
        asAttribute = "font"
      of rtImage:
        asAttribute = "image"
      of rtAudio:
        asAttribute = "audio"
      of rtVideo:
        asAttribute = "video"
      else:
        asAttribute = "fetch"
      
      result.add((url: url, `as`: asAttribute))
      preloadCount += 1

proc estimateNetworkTime*(prioritizer: ResourcePrioritizer, url: string, connectionSpeed: float): int =
  ## リソースのネットワーク時間を推定する（ミリ秒）
  if url notin prioritizer.priorities:
    return 0
  
  let priority = prioritizer.priorities[url]
  let size = if priority.size.isSome: priority.size.get() else: 100 * 1024  # デフォルト100KB
  
  # 推定RTTを考慮（仮定値）
  let estimatedRtt = 50  # 50ms
  
  # 並列ダウンロードの数を考慮（仮定値）
  let parallelConnections = 6
  
  # サイズに基づく転送時間の計算（MB/s）
  let transferTimeMs = (size.float / (connectionSpeed * 1024 * 1024 / 8)) * 1000
  
  # TCPスロースタートを簡易的に考慮
  let slowStartFactor = 1.5
  
  # 最終的な推定時間（接続確立とダウンロード）
  let estimatedTime = int((estimatedRtt.float * 2) + (transferTimeMs * slowStartFactor / parallelConnections.float))
  
  return max(10, estimatedTime)  # 最低10msを保証

when isMainModule:
  # テスト用コード
  echo "ResourcePrioritizerのテスト"
  
  var prioritizer = newResourcePrioritizer()
  
  # リソースを追加
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/",
    resourceType = rtHTML,
    isInViewport = true,
    renderBlocking = true
  ))
  
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/styles.css",
    resourceType = rtCSS,
    isInViewport = true,
    renderBlocking = true,
    dependsOn = @["https://example.com/"]
  ))
  
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/main.js",
    resourceType = rtJavaScript,
    isInViewport = true,
    renderBlocking = false,
    dependsOn = @["https://example.com/"]
  ))
  
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/logo.png",
    resourceType = rtImage,
    isInViewport = true,
    renderBlocking = false,
    dependsOn = @["https://example.com/styles.css"]
  ))
  
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/background.jpg",
    resourceType = rtImage,
    isInViewport = false,
    renderBlocking = false
  ))
  
  prioritizer.addResource(createResourcePriority(
    url = "https://example.com/font.woff2",
    resourceType = rtFont,
    isInViewport = true,
    renderBlocking = false,
    dependsOn = @["https://example.com/styles.css"]
  ))
  
  # 優先順位付けを実行
  prioritizer.calculateAllWeights()
  prioritizer.findCriticalPath()
  prioritizer.prioritize()
  
  # 結果を表示
  echo "リソース順序:"
  for i, url in prioritizer.resourceOrder:
    let priority = prioritizer.priorities[url]
    echo i+1, ". ", url, " (レベル: ", priority.level, ", 重み: ", priority.weight, ")"
  
  echo "\nクリティカルリソース:"
  for url in prioritizer.criticalResources:
    echo "- ", url
  
  echo "\nプリロードURL:"
  for preload in prioritizer.generatePreloadUrls():
    echo "- ", preload.url, " as ", preload.`as`
  
  # 依存関係の表示
  echo "\n依存関係:"
  for url, deps in prioritizer.dependencyGraph.nodes:
    if deps.len > 0:
      echo url, " depends on:"
      for dep in deps:
        echo "  - ", dep 