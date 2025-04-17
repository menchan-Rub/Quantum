# 混合コンテンツ検出モジュール
#
# このモジュールは、ブラウザの混合コンテンツ（HTTPSページ上のHTTPリソース）を
# 検出および処理するための機能を提供します。

import std/[options, strutils, tables, uri, json, sets]
import ../../logging

type
  MixedContentType* = enum
    mctPassive = "passive"     # 受動的混合コンテンツ（画像、音声、動画など）
    mctActive = "active"       # 能動的混合コンテンツ（スクリプト、iframe、オブジェクトなど）
    mctOptionallyBlockable = "optionally-blockable"  # オプションでブロック可能
    mctBlockable = "blockable" # 常にブロック

  MixedContentPolicy* = enum
    mcpBlock = "block"         # すべての混合コンテンツをブロック
    mcpBlockActive = "block-active"  # 能動的コンテンツのみブロック
    mcpAllowAll = "allow-all"  # すべての混合コンテンツを許可
    mcpUpgrade = "upgrade"     # 可能であればHTTPSにアップグレード

  MixedContentHandler* = enum
    mchBlock            # コンテンツをブロック
    mchAllow            # コンテンツを許可
    mchUpgrade          # HTTPSにアップグレード
    mchWarn             # 警告のみ（許可する）
    mchPromptUser       # ユーザーに確認

  ResourceCategory* = enum
    rcScript            # script タグ
    rcStylesheet        # stylesheet (link[rel=stylesheet])
    rcImage             # img タグ
    rcMedia             # audio/video タグ
    rcObject            # object/embed タグ
    rcFont              # @font-face
    rcFrame             # iframe/frame タグ
    rcXhr               # XMLHttpRequest/Fetch
    rcWebSocket         # WebSocket
    rcForm              # form タグ
    rcWorker            # Worker/ServiceWorker
    rcBeacon            # navigator.sendBeacon()
    rcTrack             # track タグ
    rcEventSource       # EventSource
    rcOther             # その他

  MixedContentInfo* = object
    url*: string              # 混合コンテンツのURL
    baseUrl*: string          # 基本URL（親ページ）
    resourceType*: ResourceCategory  # リソースの種類
    contentType*: MixedContentType    # 混合コンテンツの種類
    blocked*: bool            # ブロックされたかどうか
    upgraded*: bool           # HTTPSにアップグレードされたかどうか
    warningShown*: bool       # 警告が表示されたかどうか

  MixedContentDetector* = ref object
    policy*: MixedContentPolicy  # 混合コンテンツポリシー
    detectedContents*: seq[MixedContentInfo]  # 検出された混合コンテンツ
    upgradeableHosts*: HashSet[string]  # HTTPSにアップグレード可能なホスト

# リソースカテゴリに基づいて混合コンテンツタイプを判定
proc determineMixedContentType*(resourceCategory: ResourceCategory): MixedContentType =
  case resourceCategory:
    of rcScript, rcStylesheet, rcObject, rcFrame, rcXhr, rcWebSocket, 
       rcForm, rcWorker, rcBeacon, rcEventSource:
      return mctActive
    of rcImage, rcMedia, rcFont, rcTrack:
      return mctPassive
    of rcOther:
      # デフォルトでは能動的混合コンテンツとして扱う
      return mctActive

# URLが混合コンテンツかどうかを判定
proc isMixedContent*(baseUrl: string, resourceUrl: string): bool =
  # ベースURLが空の場合は混合コンテンツではない
  if baseUrl.len == 0:
    return false
  
  # リソースURLが相対URLの場合は混合コンテンツではない
  if not resourceUrl.contains("://"):
    return false
  
  # ベースURLがHTTPSでない場合は混合コンテンツではない
  let baseUri = parseUri(baseUrl)
  if baseUri.scheme.toLowerAscii() != "https":
    return false
  
  # リソースURLがHTTPSでない場合は混合コンテンツ
  let resourceUri = parseUri(resourceUrl)
  return resourceUri.scheme.toLowerAscii() == "http"

# 新しい混合コンテンツ検出器を作成
proc newMixedContentDetector*(policy: MixedContentPolicy = mcpBlockActive): MixedContentDetector =
  result = MixedContentDetector(
    policy: policy,
    detectedContents: @[],
    upgradeableHosts: initHashSet[string]()
  )

# 混合コンテンツの種類に基づいて処理方法を決定
proc determineHandler*(detector: MixedContentDetector, contentType: MixedContentType): MixedContentHandler =
  case detector.policy:
    of mcpBlock:
      # すべての混合コンテンツをブロック
      return mchBlock
    
    of mcpBlockActive:
      # 能動的混合コンテンツのみブロック
      if contentType == mctActive:
        return mchBlock
      else:
        return mchWarn
    
    of mcpAllowAll:
      # すべての混合コンテンツを許可
      return mchWarn
    
    of mcpUpgrade:
      # 可能であればHTTPSにアップグレード
      return mchUpgrade

# アップグレード可能なホストを追加
proc addUpgradeableHost*(detector: MixedContentDetector, host: string) =
  detector.upgradeableHosts.incl(host)

# URLがアップグレード可能かどうかを判定
proc isUpgradeable*(detector: MixedContentDetector, url: string): bool =
  let uri = parseUri(url)
  return uri.hostname in detector.upgradeableHosts

# 混合コンテンツを検出
proc detectMixedContent*(
  detector: MixedContentDetector,
  baseUrl: string,
  resourceUrl: string,
  resourceType: ResourceCategory
): Option[MixedContentInfo] =
  # 混合コンテンツかどうかを判定
  if not isMixedContent(baseUrl, resourceUrl):
    return none(MixedContentInfo)
  
  # 混合コンテンツの種類を判定
  let contentType = determineMixedContentType(resourceType)
  
  # 処理方法を決定
  let handler = detector.determineHandler(contentType)
  
  # 処理結果を生成
  var info = MixedContentInfo(
    url: resourceUrl,
    baseUrl: baseUrl,
    resourceType: resourceType,
    contentType: contentType,
    blocked: false,
    upgraded: false,
    warningShown: false
  )
  
  # 処理方法に基づいて情報を更新
  case handler:
    of mchBlock:
      info.blocked = true
      log(lvlWarn, "混合コンテンツをブロックしました: " & resourceUrl)
      detector.metrics.blockedCount.inc()
    
    of mchAllow:
      log(lvlInfo, "混合コンテンツを許可しました: " & resourceUrl)
      detector.metrics.allowedCount.inc()
    
    of mchUpgrade:
      if detector.isUpgradeable(resourceUrl):
        # HTTPSにアップグレード
        let uri = parseUri(resourceUrl)
        var upgradedUrl = "https://" & uri.hostname
        
        # パスとクエリパラメータを保持
        if uri.path.len > 0:
          upgradedUrl &= uri.path
        if uri.query.len > 0:
          upgradedUrl &= "?" & uri.query
        if uri.anchor.len > 0:
          upgradedUrl &= "#" & uri.anchor
          
        info.url = upgradedUrl
        info.upgraded = true
        log(lvlInfo, "混合コンテンツをアップグレードしました: " & resourceUrl & " -> " & upgradedUrl)
        detector.metrics.upgradedCount.inc()
        
        # アップグレード履歴に追加
        detector.upgradeHistory.add((
          originalUrl: resourceUrl,
          upgradedUrl: upgradedUrl,
          timestamp: getTime()
        ))
      else:
        # アップグレードできない場合はポリシーに基づいて処理
        if detector.policy == mcpStrict:
          info.blocked = true
          log(lvlWarn, "アップグレードできない混合コンテンツをブロックしました: " & resourceUrl)
          detector.metrics.blockedCount.inc()
        else:
          info.warningShown = true
          log(lvlWarn, "アップグレードできない混合コンテンツに警告を表示: " & resourceUrl)
          detector.metrics.warnedCount.inc()
    
    of mchWarn:
      info.warningShown = true
      log(lvlWarn, "混合コンテンツに関する警告を表示: " & resourceUrl)
      detector.metrics.warnedCount.inc()
      
      # 警告履歴に追加
      detector.warningHistory.add((
        url: resourceUrl,
        baseUrl: baseUrl,
        resourceType: resourceType,
        timestamp: getTime()
      ))
    
    of mchPromptUser:
      # ユーザープロンプト履歴に追加
      let promptId = $genUUID()
      detector.pendingPrompts[promptId] = (
        url: resourceUrl,
        baseUrl: baseUrl,
        resourceType: resourceType,
        contentType: contentType,
        timestamp: getTime()
      )
      
      info.warningShown = true
      info.promptId = some(promptId)
      log(lvlInfo, "混合コンテンツについてユーザーに確認: " & resourceUrl & " (PromptID: " & promptId & ")")
      detector.metrics.promptedCount.inc()
  
  # 検出された混合コンテンツを記録
  detector.detectedContents.add(info)
  
  # 統計情報を更新
  detector.metrics.totalDetections.inc()
  detector.metrics.lastDetectionTime = getTime()
  
  # コンテンツタイプ別のカウンターを更新
  case contentType:
    of mctActive:
      detector.metrics.activeContentCount.inc()
    of mctPassive:
      detector.metrics.passiveContentCount.inc()
  
  return some(info)

# 混合コンテンツ情報をJSONに変換
proc toJson*(info: MixedContentInfo): JsonNode =
  result = newJObject()
  result["url"] = %info.url
  result["baseUrl"] = %info.baseUrl
  result["resourceType"] = %($info.resourceType)
  result["contentType"] = %($info.contentType)
  result["blocked"] = %info.blocked
  result["upgraded"] = %info.upgraded
  result["warningShown"] = %info.warningShown

# 検出器の状態をJSONに変換
proc toJson*(detector: MixedContentDetector): JsonNode =
  result = newJObject()
  result["policy"] = %($detector.policy)
  
  var contentsArray = newJArray()
  for info in detector.detectedContents:
    contentsArray.add(info.toJson())
  
  result["detectedContents"] = contentsArray
  
  var hostsArray = newJArray()
  for host in detector.upgradeableHosts:
    hostsArray.add(%host)
  
  result["upgradeableHosts"] = hostsArray

# 混合コンテンツをチェックして処理
proc checkAndHandleResource*(
  detector: MixedContentDetector,
  baseUrl: string,
  resourceUrl: string,
  resourceType: ResourceCategory
): tuple[allowResource: bool, modifiedUrl: string] =
  let detectionResult = detector.detectMixedContent(baseUrl, resourceUrl, resourceType)
  
  if detectionResult.isNone():
    # 混合コンテンツでない場合はそのまま許可
    return (true, resourceUrl)
  
  let info = detectionResult.get()
  
  if info.blocked:
    # ブロックされた場合
    return (false, resourceUrl)
  
  if info.upgraded:
    # アップグレードされた場合
    return (true, info.url)
  
  # その他の場合は許可
  return (true, resourceUrl)

# ポリシーを変更
proc setPolicy*(detector: MixedContentDetector, policy: MixedContentPolicy) =
  detector.policy = policy
  log(lvlInfo, "混合コンテンツポリシーを変更しました: " & $policy)

# 統計情報を取得
proc getStatistics*(detector: MixedContentDetector): tuple[
  totalDetected: int,
  blocked: int,
  upgraded: int,
  warned: int
] =
  result.totalDetected = detector.detectedContents.len
  
  for info in detector.detectedContents:
    if info.blocked:
      inc(result.blocked)
    elif info.upgraded:
      inc(result.upgraded)
    elif info.warningShown:
      inc(result.warned)

# 検出結果をクリア
proc clearDetections*(detector: MixedContentDetector) =
  detector.detectedContents = @[]

# HTTPSにアップグレード可能なURLを推測して追加
proc addUpgradeableHostsFromHistory*(detector: MixedContentDetector, httpsUrlHistory: seq[string]) =
  for url in httpsUrlHistory:
    try:
      let uri = parseUri(url)
      if uri.scheme.toLowerAscii() == "https":
        detector.upgradeableHosts.incl(uri.hostname)
    except:
      discard 