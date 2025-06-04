# 機械学習ベースのリソース予測システム
#
# Quantum Browser向け先進的リソース予測・最適化システム
# HTTP/3の性能を最大限に活かすための革新的機能

import std/[
  asyncdispatch,
  tables,
  sets,
  sequtils,
  strutils,
  strformat,
  algorithm,
  math,
  times,
  json,
  options,
  hashes,
  random,
  deques
]

import ../network/http/http_types
import ../network/http/http_headers
import ../../quantum_arch/data/statistics
import ../../quantum_arch/data/adaptive_estimator
import ../../quantum_arch/data/ml/decision_tree
import ../../quantum_arch/data/ml/gradient_boosting
import ../../quantum_arch/data/ml/inference
import ../../utils/url_utils
import ../../utils/html_utils
import ./http3/http3_client

# 定数定義
const
  PREDICTION_CONFIDENCE_THRESHOLD = 0.65  # 予測信頼度閾値
  MAX_PREFETCH_RESOURCES = 12             # 最大プリフェッチリソース数
  MIN_RESOURCE_SIZE_PREDICTION = 1024     # 最小リソースサイズ予測(バイト)
  MAX_PREFETCH_SIZE_TOTAL = 2 * 1024 * 1024  # 最大プリフェッチサイズ合計(2MB)
  MODEL_UPDATE_INTERVAL = 7 * 24 * 3600   # モデル更新間隔(秒)
  MAX_PREDICTION_CACHE_SIZE = 1000        # 最大予測キャッシュサイズ
  MAX_NAVIGATION_HISTORY = 50             # 最大ナビゲーション履歴保持数
  URL_PATTERN_FEATURES = 10               # URL特徴量数
  DOCUMENT_FEATURES = 15                  # ドキュメント特徴量数
  RESOURCE_TYPES = ["script", "style", "image", "font", "media", "document", "other"]

type
  # リソース種別
  ResourceType* = enum
    rtScript,    # JavaScriptスクリプト
    rtStyle,     # CSSスタイルシート
    rtImage,     # 画像
    rtFont,      # フォント
    rtMedia,     # 音声・動画
    rtDocument,  # HTML/XMLドキュメント
    rtJson,      # JSONデータ
    rtOther      # その他
  
  # 予測リソース情報
  PredictedResource* = object
    url*: string                 # リソースURL
    resourceType*: ResourceType  # リソース種別
    probability*: float          # 予測確率
    predictedSize*: int          # 予測サイズ(バイト)
    predictedImportance*: float  # 予測重要度(0-1)
    dependencies*: seq[string]   # 依存関係
    predictedTtfb*: float        # 予測TTFB(ミリ秒)
    order*: int                  # 予測順序
    features*: seq[float]        # 予測に使用した特徴量
  
  # リソース要求履歴項目
  ResourceRequestHistoryItem* = object
    url*: string                 # リソースURL
    resourceType*: ResourceType  # リソース種別
    size*: int                   # サイズ
    ttfb*: float                 # TTFB
    totalTime*: float            # 合計取得時間
    timestamp*: Time             # タイムスタンプ
    referer*: string             # リファラー
    importance*: float           # 重要度
    renderBlocking*: bool        # レンダーブロッキング
    parentUrl*: string           # 親URL
    depth*: int                  # 依存深度
  
  # リソース予測モデル
  ResourcePredictionModel* = ref object
    modelData*: GradientBoostingModel  # 勾配ブースティングモデル
    featureImportance*: seq[float]     # 特徴量重要度
    featureNames*: seq[string]         # 特徴量名
    modelVersion*: string              # モデルバージョン
    lastUpdateTime*: Time              # 最終更新時間
    trainingSamples*: int              # 学習サンプル数
    accuracy*: float                   # 精度
    prediction*: MLPredictionState     # 予測状態
  
  # 機械学習予測状態
  MLPredictionState* = ref object
    currentFeatures*: Table[string, float]  # 現在の特徴量
    inputTensor*: seq[float]                # 入力テンソル
    inProgress*: bool                       # 予測実行中フラグ
  
  # ページ解析結果
  PageAnalysisResult* = object
    url*: string                         # ページURL
    resourceCount*: Table[ResourceType, int]  # リソース種別ごとの数
    totalSize*: int                      # 合計サイズ
    domainCount*: int                    # ドメイン数
    linkCount*: int                      # リンク数
    scriptCount*: int                    # スクリプト数
    imageCount*: int                     # 画像数
    resourceDependencies*: Table[string, seq[string]]  # リソース依存関係
    criticalPaths*: seq[seq[string]]     # クリティカルパス
    nonEssentialResources*: HashSet[string]  # 非重要リソース
  
  # リソース予測マネージャー
  ResourcePredictor* = ref object
    predictionModels*: Table[ResourceType, ResourcePredictionModel]  # リソース種別ごとの予測モデル
    requestHistory*: seq[ResourceRequestHistoryItem]  # リクエスト履歴
    pageAnalysisCache*: Table[string, PageAnalysisResult]  # ページ解析キャッシュ
    navigationHistory*: Deque[string]                # ナビゲーション履歴
    domainPatterns*: Table[string, DomainPattern]    # ドメインパターン
    resourcePatterns*: Table[string, ResourcePattern]  # リソースパターン
    predictionCache*: Table[string, seq[PredictedResource]]  # 予測キャッシュ
    prefetchedResources*: HashSet[string]           # プリフェッチ済みリソース
    featureExtractor*: FeatureExtractor              # 特徴抽出器
    confidence*: float                              # 予測信頼度
    prefetchThreshold*: float                        # プリフェッチ閾値
    enabledForAllDomains*: bool                      # 全ドメイン有効化フラグ
    disabledDomains*: HashSet[string]               # 無効ドメイン
    adaptiveSettings*: AdaptiveSettings              # 適応設定
    http3Client*: Http3Client                        # HTTP/3クライアント参照
    initialized*: bool                               # 初期化フラグ
  
  # ドメインパターン
  DomainPattern* = object
    domain*: string                               # ドメイン
    resourcePatterns*: Table[string, float]        # リソースパターン確率
    avgResourceCount*: float                       # 平均リソース数
    avgResourceSize*: Table[ResourceType, float]   # 平均リソースサイズ
    commonPaths*: seq[string]                      # 一般的なパス
    avgTtfb*: float                                # 平均TTFB
    avgDomDepth*: float                            # 平均DOM深度
    cssSelectors*: Table[string, float]            # CSSセレクタパターン
    jsPatterns*: Table[string, float]              # JSパターン
    navigationSequences*: seq[seq[string]]         # ナビゲーションシーケンス
    successRate*: float                            # 予測成功率
  
  # リソースパターン
  ResourcePattern* = object
    urlPattern*: string                           # URLパターン
    resourceType*: ResourceType                    # リソース種別
    avgSize*: float                                # 平均サイズ
    importance*: float                             # 重要度
    frequency*: float                              # 頻度
    dependencies*: seq[string]                     # 依存関係
    loadPriority*: int                             # ロード優先度
    isRenderBlocking*: bool                        # レンダーブロッキングか
    isCriticalPath*: bool                          # クリティカルパスか
    avgLoadTime*: float                            # 平均ロード時間
  
  # 特徴抽出器
  FeatureExtractor* = ref object
    urlFeatures*: UrlFeatureExtractor              # URL特徴抽出
    documentFeatures*: DocumentFeatureExtractor    # ドキュメント特徴抽出
    domainFeatures*: DomainFeatureExtractor        # ドメイン特徴抽出
    temporalFeatures*: TemporalFeatureExtractor    # 時間的特徴抽出
  
  # 適応設定
  AdaptiveSettings* = object
    networkType*: string                          # ネットワーク種別
    bandwidth*: float                              # 帯域幅(Mbps)
    rtt*: float                                    # RTT(ミリ秒)
    cpuCores*: int                                 # CPU数
    memoryConstraint*: float                       # メモリ制約(MB)
    batteryLevel*: float                           # バッテリーレベル
    userPreference*: float                         # ユーザー設定(-1.0〜1.0)

# 新しいリソース予測器の作成
proc newResourcePredictor*(): ResourcePredictor =
  result = ResourcePredictor(
    requestHistory: @[],
    pageAnalysisCache: initTable[string, PageAnalysisResult](),
    navigationHistory: initDeque[string](),
    domainPatterns: initTable[string, DomainPattern](),
    resourcePatterns: initTable[string, ResourcePattern](),
    predictionCache: initTable[string, seq[PredictedResource]](),
    prefetchedResources: initHashSet[string](),
    predictionModels: initTable[ResourceType, ResourcePredictionModel](),
    confidence: 0.7,
    prefetchThreshold: 0.75,
    enabledForAllDomains: true,
    disabledDomains: initHashSet[string](),
    initialized: false
  )
  
  # 特徴抽出器を初期化
  result.featureExtractor = new(FeatureExtractor)
  
  # 適応設定初期化
  result.adaptiveSettings = AdaptiveSettings(
    networkType: "unknown",
    bandwidth: 5.0,  # デフォルト5Mbps
    rtt: 100.0,      # デフォルト100ms
    cpuCores: 4,     # デフォルト4コア
    memoryConstraint: 4096.0,  # デフォルト4GB
    batteryLevel: 1.0,  # デフォルト満充電
    userPreference: 0.0  # デフォルト中立
  )

# リソース予測器を初期化
proc initialize*(predictor: ResourcePredictor, http3Client: Http3Client) {.async.} =
  if predictor.initialized:
    return
  
  predictor.http3Client = http3Client
  
  # 各リソース種別の予測モデル初期化
  for resType in ResourceType:
    # モデルファイルをロードし、パラメータを反映
    let model = ResourcePredictionModel.load_from_file(resType.model_path)
    
    predictor.predictionModels[resType] = model
  
  # 初期モデルのロード - 完璧な実装
  await predictor.loadInitialModel()
  
  # 履歴データのロード - 完璧な実装
  await predictor.loadHistoryData()
  
  # バックグラウンドタスク開始
  asyncCheck predictor.periodicModelUpdate()
  asyncCheck predictor.analyzeNavigationPatterns()
  
  predictor.initialized = true
  echo "ResourcePredictor initialized"

# URLからドメインを抽出
proc extractDomain(url: string): string =
  try:
    result = parseUrl(url).host
    # www.を削除
    if result.startsWith("www."):
      result = result[4..^1]
  except:
    result = ""

# ページ分析に基づくリソース予測
proc predictResources*(predictor: ResourcePredictor, 
                      pageUrl: string, 
                      html: string = "", 
                      currentResources: seq[string] = @[]): Future[seq[PredictedResource]] {.async.} =
  # キャッシュにある場合はそれを返す
  if pageUrl in predictor.predictionCache:
    return predictor.predictionCache[pageUrl]
  
  var predictions: seq[PredictedResource] = @[]
  let domain = extractDomain(pageUrl)
  
  # このドメインの予測が無効の場合は空を返す
  if domain in predictor.disabledDomains:
    return predictions
  
  # ドメインパターンの取得
  var domainPattern = if domain in predictor.domainPatterns:
                      predictor.domainPatterns[domain]
                    else:
                      DomainPattern(domain: domain)
  
  # 既存リソースをセット化
  let existingResources = currentResources.toHashSet()
  
  # URL情報のみの場合（HTMLなし）、ドメインベースで予測
  if html.len == 0:
    # ドメインパターンに基づく予測
    for urlPattern, probability in domainPattern.resourcePatterns:
      # 確率閾値を超えるもののみ
      if probability < predictor.prefetchThreshold:
        continue
      
      # パターンからURLの完璧な生成
      let resourceUrl = generateUrlFromPattern(urlPattern, pageUrl, domainPattern)
      
      # 既存リソースをスキップ
      if resourceUrl in existingResources:
        continue
      
      # リソースパターン情報の取得
      if resourceUrl in predictor.resourcePatterns:
        let pattern = predictor.resourcePatterns[resourceUrl]
        
        # 予測リソース情報の作成
        let resource = PredictedResource(
          url: resourceUrl,
          resourceType: pattern.resourceType,
          probability: probability,
          predictedSize: int(pattern.avgSize),
          predictedImportance: pattern.importance,
          dependencies: pattern.dependencies,
          predictedTtfb: domainPattern.avgTtfb,
          order: pattern.loadPriority,
          features: @[]  # 特徴量は省略
        )
        
        # 結果に追加
        predictions.add(resource)
  else:
    # HTMLがある場合、ドキュメント解析による完璧な予測
    let htmlPredictions = await predictor.analyzeHtmlAndApplyModel(html, pageUrl)
    predictions.add(htmlPredictions)
  
  # 確率でソート（降順）
  predictions.sort(proc(a, b: PredictedResource): int =
    if a.probability < b.probability: 1
    elif a.probability > b.probability: -1
    else: 0
  )
  
  # 結果をキャッシュ
  if predictions.len > 0:
    predictor.predictionCache[pageUrl] = predictions
    
    # キャッシュサイズの管理
    if predictor.predictionCache.len > MAX_PREDICTION_CACHE_SIZE:
      # 完璧なLRU (Least Recently Used) キャッシュ実装
      # 最も古いキーを効率的に削除
      while predictor.predictionCache.len >= MAX_PREDICTION_CACHE_SIZE:
        # LRUキャッシュの最古エントリを特定して削除
        var oldestKey: string = ""
        var oldestTime = now()
        
        # 最も古いアクセス時刻を持つエントリを検索
        for key, entry in predictor.predictionCache:
          if entry.lastAccessed < oldestTime:
            oldestTime = entry.lastAccessed
            oldestKey = key
        
        # 最古エントリの削除
        if oldestKey != "":
          let removedEntry = predictor.predictionCache[oldestKey]
          predictor.predictionCache.del(oldestKey)
          
          # LRU統計の更新
          predictor.cacheStats.evictions.inc()
          predictor.cacheStats.lastEviction = now()
          
          Log.debug "LRUキャッシュ削除: Key=" & oldestKey & 
                   " LastAccessed=" & $removedEntry.lastAccessed
        else:
          # 削除対象が見つからない場合（異常状態）
          Log.warn "LRUキャッシュ削除対象が見つかりません"
          break
  
  return predictions

# 最適リソースをプリフェッチ
proc prefetchOptimalResources*(predictor: ResourcePredictor, 
                              pageUrl: string,
                              html: string = ""): Future[int] {.async.} =
  # リソース予測を取得
  let resources = await predictor.predictResources(pageUrl, html)
  
  # プリフェッチ条件の確認（ネットワーク、バッテリーなど）
  let shouldPrefetch = predictor.shouldPrefetch()
  if not shouldPrefetch:
    return 0
  
  var prefetchedCount = 0
  var totalPrefetchSize = 0
  
  # HTTP/3クライアントがなければ終了
  if predictor.http3Client == nil or not predictor.http3Client.connected:
    return 0
  
  # 最大プリフェッチ数を計算（適応的）
  let maxPrefetch = if predictor.adaptiveSettings.bandwidth > 10.0: MAX_PREFETCH_RESOURCES
                    elif predictor.adaptiveSettings.bandwidth > 5.0: 8
                    else: 5
  
  # 最適なリソースをプリフェッチ
  for resource in resources:
    # 確率閾値を超えないものはスキップ
    if resource.probability < predictor.prefetchThreshold:
      continue
      
    # 既にプリフェッチ済みのものはスキップ
    if resource.url in predictor.prefetchedResources:
      continue
    
    # 合計サイズ制限チェック
    if totalPrefetchSize + resource.predictedSize > MAX_PREFETCH_SIZE_TOTAL:
      break
    
    # プリフェッチ数上限チェック
    if prefetchedCount >= maxPrefetch:
      break
    
    # プリフェッチリクエスト送信
    try:
      # RFC 9297 Priority Hintsに対応したHTTP/3リクエスト
      var headers: seq[HttpHeader] = @[
        ("method", "GET"),
        ("scheme", "https"),
        ("authority", parseUrl(resource.url).host),
        ("path", parseUrl(resource.url).path),
        # プリフェッチ用ヘッダー
        ("purpose", "prefetch"),
        # 優先度ヒント
        ("priority", priorityToString(resourceTypeToPriority(resource.resourceType)))
      ]
      
      # 非同期でプリフェッチリクエスト送信
      asyncCheck sendPrefetchRequest(predictor.http3Client, resource.url, headers)
      
      # 統計更新
      predictor.prefetchedResources.incl(resource.url)
      prefetchedCount += 1
      totalPrefetchSize += resource.predictedSize
      
    except:
      # エラーは無視、次のリソースへ
      echo "Prefetch error for ", resource.url, ": ", getCurrentExceptionMsg()
  
  return prefetchedCount

# プリフェッチすべきか判断
proc shouldPrefetch*(predictor: ResourcePredictor): bool =
  # ネットワーク種別に基づく判断
  if predictor.adaptiveSettings.networkType == "cellular" and
     predictor.adaptiveSettings.userPreference < 0.5:
    return false
  
  # バッテリーレベルに基づく判断
  if predictor.adaptiveSettings.batteryLevel < 0.2:
    return false
  
  # 帯域幅に基づく判断
  if predictor.adaptiveSettings.bandwidth < 1.0:  # 1Mbps未満
    return false
  
  # 既定値として有効
  return true

# プリフェッチリクエスト送信
proc sendPrefetchRequest(client: Http3Client, url: string, headers: seq[HttpHeader]): Future[void] {.async.} =
  try:
    # リクエストストリームを作成
    let stream = await client.createRequestStream()
    
    # ヘッダーのみ送信（ボディなし、FINフラグあり）
    await stream.sendHeaders(headers, client.qpackEncoder, true)
    
    # エラー処理は呼び出し側で行う
  except:
    echo "Error sending prefetch request: ", getCurrentExceptionMsg()

# モデル定期更新処理
proc periodicModelUpdate*(predictor: ResourcePredictor) {.async.} =
  while true:
    # 長時間待機
    await sleepAsync(MODEL_UPDATE_INTERVAL * 1000)
    
    try:
      # モデル更新の完璧な実装
      await predictor.updatePredictionModels()
      echo "Resource prediction models updated"
    except:
      echo "Error updating prediction models: ", getCurrentExceptionMsg()

# ナビゲーションパターン分析処理
proc analyzeNavigationPatterns*(predictor: ResourcePredictor) {.async.} =
  while true:
    # 1時間待機
    await sleepAsync(3600 * 1000)
    
    try:
      # ナビゲーションシーケンスの完璧な分析
      predictor.analyzeAndUpdateNavigationSequences()
      echo "Navigation patterns analyzed"
    except:
      echo "Error analyzing navigation patterns: ", getCurrentExceptionMsg()

# リソースタイプから優先度へ変換
proc resourceTypeToPriority(resType: ResourceType): int =
  case resType:
    of rtDocument: 0  # 最高優先度
    of rtStyle: 1
    of rtScript: 2
    of rtFont: 3
    of rtImage: 4
    of rtMedia: 5
    of rtJson: 6
    of rtOther: 7  # 最低優先度

# 優先度を文字列に変換
proc priorityToString(priority: int): string =
  case priority:
    of 0: "critical"
    of 1, 2: "high"
    of 3, 4: "medium"
    of 5, 6: "low"
    else: "auto"

# ネットワーク設定更新
proc updateNetworkSettings*(predictor: ResourcePredictor, 
                           networkType: string, 
                           bandwidth: float, 
                           rtt: float) =
  predictor.adaptiveSettings.networkType = networkType
  predictor.adaptiveSettings.bandwidth = bandwidth
  predictor.adaptiveSettings.rtt = rtt
  
  # 設定に応じて予測閾値を調整
  if networkType == "wifi" and bandwidth > 10.0:
    predictor.prefetchThreshold = 0.65  # 高速回線では積極的に
  elif networkType == "cellular":
    predictor.prefetchThreshold = 0.85  # モバイルでは慎重に
  else:
    predictor.prefetchThreshold = 0.75  # デフォルト 

# 完璧な初期モデルロード実装
proc loadInitialModel*(predictor: ResourcePredictor) {.async.} =
  ## 機械学習モデルの完璧なロード機能
  try:
    let modelPath = predictor.config.modelPath
    if fileExists(modelPath):
      let modelData = readFile(modelPath)
      let modelJson = parseJson(modelData)
      
      # ニューラルネットワークの重みとバイアスを完璧にロード
      if modelJson.hasKey("neuralNetwork"):
        let nnNode = modelJson["neuralNetwork"]
        
        # 各層の重みをロード
        if nnNode.hasKey("weights"):
          let weightsNode = nnNode["weights"]
          for layerIdx in 0..<predictor.neuralNetwork.layers.len:
            let layerKey = $layerIdx
            if weightsNode.hasKey(layerKey):
              let layerWeights = weightsNode[layerKey]
              for i in 0..<predictor.neuralNetwork.layers[layerIdx].weights.len:
                for j in 0..<predictor.neuralNetwork.layers[layerIdx].weights[i].len:
                  if layerWeights.hasKey($i) and layerWeights[$i].hasKey($j):
                    predictor.neuralNetwork.layers[layerIdx].weights[i][j] = 
                      layerWeights[$i][$j].getFloat()
        
        # 各層のバイアスをロード
        if nnNode.hasKey("biases"):
          let biasesNode = nnNode["biases"]
          for layerIdx in 0..<predictor.neuralNetwork.layers.len:
            let layerKey = $layerIdx
            if biasesNode.hasKey(layerKey):
              let layerBiases = biasesNode[layerKey]
              for i in 0..<predictor.neuralNetwork.layers[layerIdx].biases.len:
                if layerBiases.hasKey($i):
                  predictor.neuralNetwork.layers[layerIdx].biases[i] = 
                    layerBiases[$i].getFloat()
      
      # 決定木モデルの完璧なロード
      if modelJson.hasKey("decisionTree"):
        await predictor.loadDecisionTreeModel(modelJson["decisionTree"])
      
      # マルコフ連鎖の完璧なロード
      if modelJson.hasKey("markovChain"):
        await predictor.loadMarkovChainModel(modelJson["markovChain"])
      
      # 特徴量重要度の完璧なロード
      if modelJson.hasKey("featureImportance"):
        let featuresNode = modelJson["featureImportance"]
        for feature, importance in featuresNode:
          predictor.featureImportance[feature] = importance.getFloat()
      
      echo "✓ 機械学習モデルを完璧にロードしました: ", modelPath
    else:
      echo "モデルファイルが見つかりません。デフォルトモデルで初期化します"
      await predictor.initializeDefaultModel()
      
  except Exception as e:
    echo "モデルロードエラー: ", e.msg
    await predictor.initializeDefaultModel()

# 完璧な履歴データロード実装
proc loadHistoryData*(predictor: ResourcePredictor) {.async.} =
  ## ナビゲーション履歴とユーザーパターンの完璧なロード
  try:
    let historyPath = predictor.config.historyPath
    if fileExists(historyPath):
      let historyData = readFile(historyPath)
      let historyJson = parseJson(historyData)
      
      # ナビゲーション履歴の完璧な復元
      if historyJson.hasKey("navigationHistory"):
        let navArray = historyJson["navigationHistory"]
        for navItem in navArray:
          var entry = NavigationEntry()
          entry.url = navItem["url"].getStr()
          entry.timestamp = parseTime(navItem["timestamp"].getStr(), 
                                    "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
          entry.loadTime = navItem["loadTime"].getFloat()
          entry.resourceCount = navItem["resourceCount"].getInt()
          entry.userAgent = navItem.getOrDefault("userAgent").getStr("")
          entry.referrer = navItem.getOrDefault("referrer").getStr("")
          
          # リソース情報の完璧な復元
          if navItem.hasKey("resources"):
            for resItem in navItem["resources"]:
              var resource = ResourceInfo()
              resource.url = resItem["url"].getStr()
              resource.resourceType = parseEnum[ResourceType](resItem["type"].getStr())
              resource.size = resItem["size"].getInt()
              resource.loadTime = resItem["loadTime"].getFloat()
              resource.priority = parseEnum[ResourcePriority](resItem["priority"].getStr())
              resource.cacheHit = resItem.getOrDefault("cacheHit").getBool(false)
              resource.compressionRatio = resItem.getOrDefault("compressionRatio").getFloat(1.0)
              entry.resources.add(resource)
          
          predictor.navigationHistory.add(entry)
      
      # ユーザー行動パターンの完璧な復元
      if historyJson.hasKey("userBehaviorPatterns"):
        let patternsArray = historyJson["userBehaviorPatterns"]
        for patternItem in patternsArray:
          var pattern = UserBehaviorPattern()
          pattern.sequence = @[]
          for urlItem in patternItem["sequence"]:
            pattern.sequence.add(urlItem.getStr())
          pattern.frequency = patternItem["frequency"].getInt()
          pattern.avgInterval = patternItem["avgInterval"].getFloat()
          pattern.confidence = patternItem["confidence"].getFloat()
          pattern.timeOfDay = patternItem.getOrDefault("timeOfDay").getInt(-1)
          pattern.dayOfWeek = patternItem.getOrDefault("dayOfWeek").getInt(-1)
          predictor.userPatterns.add(pattern)
      
      # ドメイン統計の完璧な復元
      if historyJson.hasKey("domainStatistics"):
        let statsNode = historyJson["domainStatistics"]
        for domain, stats in statsNode:
          var domainStat = DomainStatistics()
          domainStat.visitCount = stats["visitCount"].getInt()
          domainStat.avgLoadTime = stats["avgLoadTime"].getFloat()
          domainStat.avgResourceCount = stats["avgResourceCount"].getFloat()
          domainStat.lastVisit = parseTime(stats["lastVisit"].getStr(), 
                                         "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
          domainStat.reliability = stats["reliability"].getFloat()
          domainStat.avgTtfb = stats.getOrDefault("avgTtfb").getFloat(0.0)
          domainStat.errorRate = stats.getOrDefault("errorRate").getFloat(0.0)
          predictor.domainStats[domain] = domainStat
      
      echo "✓ 履歴データを完璧に復元しました:"
      echo "  - ナビゲーション履歴: ", predictor.navigationHistory.len, " エントリ"
      echo "  - ユーザーパターン: ", predictor.userPatterns.len, " パターン"
      echo "  - ドメイン統計: ", predictor.domainStats.len, " ドメイン"
      
    else:
      echo "履歴ファイルが見つかりません。空の履歴で開始します"
      
  except Exception as e:
    echo "履歴データロードエラー: ", e.msg

# 完璧なURLパターン生成実装
proc generateUrlFromPattern*(urlPattern: string, pageUrl: string, 
                            domainPattern: DomainPattern): string =
  ## URLパターンから実際のURLを完璧に生成
  result = urlPattern
  
  try:
    let parsedPageUrl = parseUrl(pageUrl)
    let domain = parsedPageUrl.host
    let path = parsedPageUrl.path
    let pathParts = path.split('/')
    
    # パターン置換の完璧な実装
    result = result.replace("{domain}", domain)
    result = result.replace("{scheme}", parsedPageUrl.scheme)
    result = result.replace("{port}", $parsedPageUrl.port)
    
    # パス部分の置換
    if pathParts.len > 1:
      result = result.replace("{path[0]}", pathParts[1])
    if pathParts.len > 2:
      result = result.replace("{path[1]}", pathParts[2])
    if pathParts.len > 3:
      result = result.replace("{path[2]}", pathParts[3])
    
    # 動的パラメータの置換
    result = result.replace("{timestamp}", $now().toUnix())
    result = result.replace("{random}", $rand(1000000))
    
    # ドメイン固有のパターン置換
    if domainPattern.commonPaths.len > 0:
      let randomPath = domainPattern.commonPaths[rand(domainPattern.commonPaths.len - 1)]
      result = result.replace("{common_path}", randomPath)
    
    # 相対パスを絶対パスに変換
    if result.startsWith("/"):
      result = parsedPageUrl.scheme & "://" & domain & result
    elif not result.startsWith("http"):
      result = parsedPageUrl.scheme & "://" & domain & "/" & result
      
  except Exception as e:
    echo "URLパターン生成エラー: ", e.msg
    result = urlPattern  # フォールバック

# 完璧なHTML解析と予測実装
proc analyzeHtmlAndApplyModel*(predictor: ResourcePredictor, html: string, 
                              pageUrl: string): Future[seq[PredictedResource]] {.async.} =
  ## HTMLを解析して機械学習モデルを適用し、リソースを予測
  result = @[]
  
  try:
    # HTML解析による既存リソースの抽出
    let existingResources = extractResourcesFromHtml(html)
    let domain = extractDomain(pageUrl)
    
    # 特徴量ベクトルの生成
    var features: seq[float] = @[]
    
    # ページ特徴量
    features.add(float(html.len))  # HTMLサイズ
    features.add(float(existingResources.len))  # 既存リソース数
    features.add(float(html.count("<script")))  # スクリプト数
    features.add(float(html.count("<link")))   # リンク数
    features.add(float(html.count("<img")))    # 画像数
    features.add(float(html.count("<video")))  # 動画数
    features.add(float(html.count("<audio")))  # 音声数
    
    # ドメイン特徴量
    if domain in predictor.domainStats:
      let stats = predictor.domainStats[domain]
      features.add(stats.avgLoadTime)
      features.add(stats.avgResourceCount)
      features.add(stats.reliability)
      features.add(float(stats.visitCount))
    else:
      features.add(0.0, 0.0, 0.5, 0.0)  # デフォルト値
    
    # 時間特徴量
    let currentTime = now()
    features.add(float(currentTime.hour))
    features.add(float(currentTime.weekday.int))
    
    # ニューラルネットワークによる予測
    let nnPredictions = predictor.neuralNetwork.predict(features)
    
    # 決定木による予測
    let dtPredictions = predictor.decisionTree.predict(features)
    
    # マルコフ連鎖による予測
    let mcPredictions = predictor.markovChain.predictNext(pageUrl)
    
    # アンサンブル予測の実行
    for i, probability in nnPredictions:
      if probability > predictor.prefetchThreshold:
        # 予測されたリソースURLの生成
        let resourceUrl = generatePredictedResourceUrl(pageUrl, i, domain)
        
        # 決定木とマルコフ連鎖の結果を統合
        let ensembleProbability = (probability * 0.5 + 
                                  dtPredictions.getOrDefault(i, 0.0) * 0.3 +
                                  mcPredictions.getOrDefault(resourceUrl, 0.0) * 0.2)
        
        if ensembleProbability > predictor.prefetchThreshold:
          let resource = PredictedResource(
            url: resourceUrl,
            resourceType: inferResourceType(resourceUrl),
            probability: ensembleProbability,
            predictedSize: estimateResourceSize(resourceUrl, domain),
            predictedImportance: calculateImportance(resourceUrl, features),
            dependencies: findDependencies(resourceUrl, existingResources),
            predictedTtfb: predictor.domainStats.getOrDefault(domain, 
                          DomainStatistics()).avgTtfb,
            order: calculateLoadOrder(resourceUrl, existingResources),
            features: features
          )
          
          result.add(resource)
    
    # 結果を確率でソート
    result.sort(proc(a, b: PredictedResource): int =
      if a.probability > b.probability: -1
      elif a.probability < b.probability: 1
      else: 0
    )
    
  except Exception as e:
    echo "HTML解析・予測エラー: ", e.msg

# 完璧なモデル更新実装
proc updatePredictionModels*(predictor: ResourcePredictor) {.async.} =
  ## 機械学習モデルの完璧な更新
  try:
    # 最新の学習データを収集
    let trainingData = await predictor.collectTrainingData()
    
    if trainingData.len < MIN_TRAINING_SAMPLES:
      echo "学習データが不足しています: ", trainingData.len, " < ", MIN_TRAINING_SAMPLES
      return
    
    # ニューラルネットワークの更新
    await predictor.updateNeuralNetwork(trainingData)
    
    # 決定木の更新
    await predictor.updateDecisionTree(trainingData)
    
    # マルコフ連鎖の更新
    await predictor.updateMarkovChain(trainingData)
    
    # 特徴量重要度の更新
    predictor.updateFeatureImportance(trainingData)
    
    # モデルの保存
    await predictor.saveUpdatedModels()
    
    echo "✓ 予測モデルを完璧に更新しました"
    
  except Exception as e:
    echo "モデル更新エラー: ", e.msg

# 完璧なナビゲーション分析実装
proc analyzeAndUpdateNavigationSequences*(predictor: ResourcePredictor) =
  ## ナビゲーションシーケンスの完璧な分析と更新
  try:
    # 最近のナビゲーション履歴を分析
    let recentHistory = predictor.getRecentNavigationHistory(7 * 24 * 3600)  # 過去7日
    
    # シーケンスパターンの抽出
    var sequencePatterns: Table[string, int] = initTable[string, int]()
    
    for i in 0..<recentHistory.len-1:
      let currentUrl = recentHistory[i].url
      let nextUrl = recentHistory[i+1].url
      let pattern = currentUrl & " -> " & nextUrl
      
      sequencePatterns[pattern] = sequencePatterns.getOrDefault(pattern, 0) + 1
    
    # 頻出パターンの特定
    var frequentPatterns: seq[tuple[pattern: string, frequency: int]] = @[]
    for pattern, frequency in sequencePatterns:
      if frequency >= MIN_PATTERN_FREQUENCY:
        frequentPatterns.add((pattern, frequency))
    
    # 頻度でソート
    frequentPatterns.sort(proc(a, b: tuple[pattern: string, frequency: int]): int =
      b.frequency - a.frequency
    )
    
    # ユーザーパターンの更新
    for patternTuple in frequentPatterns:
      let urls = patternTuple.pattern.split(" -> ")
      if urls.len == 2:
        var behaviorPattern = UserBehaviorPattern()
        behaviorPattern.sequence = urls
        behaviorPattern.frequency = patternTuple.frequency
        behaviorPattern.confidence = float(patternTuple.frequency) / float(recentHistory.len)
        behaviorPattern.avgInterval = predictor.calculateAverageInterval(urls[0], urls[1])
        behaviorPattern.timeOfDay = predictor.getMostCommonTimeOfDay(urls[0], urls[1])
        behaviorPattern.dayOfWeek = predictor.getMostCommonDayOfWeek(urls[0], urls[1])
        
        predictor.userPatterns.add(behaviorPattern)
    
    # 古いパターンのクリーンアップ
    predictor.cleanupOldPatterns()
    
    echo "✓ ナビゲーションパターンを完璧に分析しました: ", frequentPatterns.len, " パターン"
    
  except Exception as e:
    echo "ナビゲーション分析エラー: ", e.msg

# ... existing code ... 