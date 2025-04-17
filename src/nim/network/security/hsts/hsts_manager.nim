# HTTP Strict Transport Security (HSTS) マネージャー
#
# このモジュールは、HSTS (HTTP Strict Transport Security) の管理機能を提供します。
# HSTS は、Webサイトが HTTPS 接続のみを使用するよう強制するセキュリティメカニズムです。
# HSTS ヘッダーを送信するサイトは、指定された期間、常に HTTPS で接続されます。

import std/[tables, sets, strutils, strformat, times, options, uri, json, hashes, os]
import ../../../logging
import ../../../utils/file_utils
import ../../../config/config_manager

type
  HstsState* = enum
    hstsEnabled = "enabled"    # HSTS有効
    hstsDisabled = "disabled"  # HSTS無効

  HstsEntry* = object
    host*: string              # ホスト名
    includeSubdomains*: bool   # サブドメインを含むか
    expire*: DateTime          # 有効期限
    lastAccessed*: DateTime    # 最終アクセス日時
    source*: HstsSource        # エントリのソース

  HstsSource* = enum
    hstsPersisted = "persisted"      # 永続化された
    hstsHeader = "header"            # ヘッダーから
    hstsPreloaded = "preloaded"      # プリロードリストから
    hstsUserDefined = "user-defined" # ユーザー定義

  HstsConfig* = ref object
    state*: HstsState                 # HSTS状態
    persistentStorage*: bool          # 永続化ストレージを使用するか
    storageLocation*: string          # ストレージの場所
    maxAge*: int                      # デフォルトの最大有効期間 (秒)
    enforcedHosts*: HashSet[string]   # 強制的にHSTSを適用するホスト
    bypassedHosts*: HashSet[string]   # HSTSをバイパスするホスト
    cleanupInterval*: int             # クリーンアップ間隔 (秒)
    preloadedListEnabled*: bool       # プリロードリストを有効にするか
    preloadedListPath*: string        # プリロードリスト格納場所

  HstsManager* = ref object
    config*: HstsConfig                                  # HSTS設定
    entries*: Table[string, HstsEntry]                   # HSTSエントリ
    preloadedHosts*: HashSet[string]                     # プリロードされたホスト
    preloadedIncludeSubdomains*: HashSet[string]         # サブドメインを含むプリロードされたホスト
    lastCleanupTime*: DateTime                           # 最後のクリーンアップ時間
    allowedPorts*: seq[int]                              # 許可されたポート（デフォルトは443のみ）

# プリロードリストの定数
const DefaultPreloadedListPath* = "data/security/hsts_preload_list.json"

# 許可されたデフォルトポート (HTTPS)
const DefaultAllowedPorts* = @[443]

# デフォルトの最大有効期間 (180日)
const DefaultMaxAge* = 60 * 60 * 24 * 180

# デフォルトのクリーンアップ間隔 (1日)
const DefaultCleanupInterval* = 60 * 60 * 24

# ストレージのデフォルトの場所
const DefaultStorageLocation* = "data/security/hsts_entries.json"

# 新しいHSTS設定を作成
proc newHstsConfig*(
  state: HstsState = hstsEnabled,
  persistentStorage: bool = true,
  storageLocation: string = DefaultStorageLocation,
  maxAge: int = DefaultMaxAge,
  enforcedHosts: HashSet[string] = initHashSet[string](),
  bypassedHosts: HashSet[string] = initHashSet[string](),
  cleanupInterval: int = DefaultCleanupInterval,
  preloadedListEnabled: bool = true,
  preloadedListPath: string = DefaultPreloadedListPath
): HstsConfig =
  result = HstsConfig(
    state: state,
    persistentStorage: persistentStorage,
    storageLocation: storageLocation,
    maxAge: maxAge,
    enforcedHosts: enforcedHosts,
    bypassedHosts: bypassedHosts,
    cleanupInterval: cleanupInterval,
    preloadedListEnabled: preloadedListEnabled,
    preloadedListPath: preloadedListPath
  )

# 新しいHSTSマネージャーを作成
proc newHstsManager*(config: HstsConfig = nil): HstsManager =
  let actualConfig = if config.isNil: newHstsConfig() else: config
  
  result = HstsManager(
    config: actualConfig,
    entries: initTable[string, HstsEntry](),
    preloadedHosts: initHashSet[string](),
    preloadedIncludeSubdomains: initHashSet[string](),
    lastCleanupTime: now(),
    allowedPorts: DefaultAllowedPorts
  )

# HSTSマネージャーの初期化
proc init*(manager: HstsManager) =
  # プリロードリストの読み込み
  if manager.config.preloadedListEnabled:
    try:
      manager.loadPreloadedList()
    except:
      let e = getCurrentException()
      let msg = getCurrentExceptionMsg()
      log(lvlError, fmt"HSTSプリロードリストの読み込みに失敗しました: {msg}")
  
  # 永続化されたエントリの読み込み
  if manager.config.persistentStorage:
    try:
      manager.loadEntries()
    except:
      let e = getCurrentException()
      let msg = getCurrentExceptionMsg()
      log(lvlError, fmt"HSTS永続化エントリの読み込みに失敗しました: {msg}")
  
  log(lvlInfo, "HSTSマネージャーが初期化されました")

# HSTS状態を設定
proc setState*(manager: HstsManager, state: HstsState) =
  manager.config.state = state
  log(lvlInfo, fmt"HSTS状態が設定されました: {state}")

# ホストにHSTSエントリを追加
proc addHstsHost*(
  manager: HstsManager,
  host: string,
  maxAge: int = -1,
  includeSubdomains: bool = false,
  source: HstsSource = hstsHeader
) =
  # HSITが無効な場合は無視
  if manager.config.state == hstsDisabled:
    return
  
  # ホストをバイパスリストで確認
  if host in manager.config.bypassedHosts:
    log(lvlInfo, fmt"ホスト {host} はHSTSバイパスリストにあるため、追加されません")
    return
  
  let actualMaxAge = if maxAge < 0: manager.config.maxAge else: maxAge
  
  # maxAgeが0の場合、エントリを削除
  if actualMaxAge == 0:
    if host in manager.entries:
      manager.entries.del(host)
      log(lvlInfo, fmt"HSTS エントリが削除されました: {host}")
    return
  
  # 新しいエントリを作成
  let entry = HstsEntry(
    host: host,
    includeSubdomains: includeSubdomains,
    expire: now() + initDuration(seconds = actualMaxAge),
    lastAccessed: now(),
    source: source
  )
  
  # エントリを追加
  manager.entries[host] = entry
  log(lvlInfo, fmt"HSTS エントリが追加されました: {host} (有効期限: {entry.expire.format(\"yyyy-MM-dd HH:mm:ss\")})")
  
  # 永続化
  if manager.config.persistentStorage and source != hstsPreloaded:
    manager.saveEntries()

# HSTS ヘッダーを処理
proc processHstsHeader*(
  manager: HstsManager,
  host: string,
  headerValue: string
) =
  # HSITが無効な場合は無視
  if manager.config.state == hstsDisabled:
    return
  
  var maxAge = -1
  var includeSubdomains = false
  
  # ヘッダーをパース
  let directives = headerValue.split(';')
  for directive in directives:
    let trimmed = directive.strip()
    if trimmed.toLowerAscii() == "includesubdomains":
      includeSubdomains = true
    elif trimmed.startsWith("max-age="):
      try:
        maxAge = parseInt(trimmed[8..^1])
      except:
        log(lvlError, fmt"無効なmax-age値: {trimmed}")
        maxAge = manager.config.maxAge
  
  # エントリを追加
  manager.addHstsHost(host, maxAge, includeSubdomains, hstsHeader)

# ホストがHSTSに登録されているか確認
proc isHstsHost*(
  manager: HstsManager,
  host: string,
  port: int = 443
): bool =
  # HSITが無効な場合は常にfalse
  if manager.config.state == hstsDisabled:
    return false
  
  # 強制的に適用するホストリストをチェック
  if host in manager.config.enforcedHosts:
    return true
  
  # ポートをチェック
  if port notin manager.allowedPorts:
    return false
  
  # エントリを直接チェック
  if host in manager.entries:
    let entry = manager.entries[host]
    if now() <= entry.expire:
      # 最終アクセス時間を更新
      var updatedEntry = entry
      updatedEntry.lastAccessed = now()
      manager.entries[host] = updatedEntry
      
      return true
    else:
      # 期限切れのエントリを削除
      manager.entries.del(host)
      if manager.config.persistentStorage:
        manager.saveEntries()
  
  # プリロードリストをチェック
  if manager.config.preloadedListEnabled:
    if host in manager.preloadedHosts:
      return true
  
  # サブドメインをチェック
  let hostParts = host.split('.')
  if hostParts.len > 2:
    var domain = hostParts[^2] & "." & hostParts[^1]
    
    # エントリをチェック
    if domain in manager.entries:
      let entry = manager.entries[domain]
      if entry.includeSubdomains and now() <= entry.expire:
        # 最終アクセス時間を更新
        var updatedEntry = entry
        updatedEntry.lastAccessed = now()
        manager.entries[domain] = updatedEntry
        
        return true
    
    # プリロードリストをチェック
    if manager.config.preloadedListEnabled:
      if domain in manager.preloadedIncludeSubdomains:
        return true
    
    # さらに上位ドメインをチェック（多段階サブドメインの場合）
    for i in 3..hostParts.len:
      domain = hostParts[^i..^1].join(".")
      
      # エントリをチェック
      if domain in manager.entries:
        let entry = manager.entries[domain]
        if entry.includeSubdomains and now() <= entry.expire:
          # 最終アクセス時間を更新
          var updatedEntry = entry
          updatedEntry.lastAccessed = now()
          manager.entries[domain] = updatedEntry
          
          return true
      
      # プリロードリストをチェック
      if manager.config.preloadedListEnabled:
        if domain in manager.preloadedIncludeSubdomains:
          return true
  
  return false

# URLがHSTSに登録されているか確認
proc isHstsUrl*(
  manager: HstsManager,
  url: string
): bool =
  try:
    let parsedUrl = parseUri(url)
    
    # スキームが既にHTTPSであれば、HSTSは関係ない
    if parsedUrl.scheme == "https":
      return false
    
    # HTTPでない場合も関係ない
    if parsedUrl.scheme != "http":
      return false
    
    # ホストが空の場合は無視
    if parsedUrl.hostname == "":
      return false
    
    # ポートを取得
    var port = 80
    if parsedUrl.port != "":
      try:
        port = parseInt(parsedUrl.port)
      except:
        return false
    
    # HSTS登録確認
    return manager.isHstsHost(parsedUrl.hostname, port)
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTS URL確認中にエラーが発生しました: {msg}")
    return false

# URLをHTTPSにアップグレード（必要な場合）
proc upgradeUrlToHttps*(
  manager: HstsManager,
  url: string
): string =
  if not manager.isHstsUrl(url):
    return url
  
  try:
    var parsedUrl = parseUri(url)
    
    # スキームをHTTPSに変更
    parsedUrl.scheme = "https"
    
    # ポートを443に変更（明示的に指定されている場合のみ）
    if parsedUrl.port == "80":
      parsedUrl.port = "443"
    
    return $parsedUrl
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTS URLアップグレード中にエラーが発生しました: {msg}")
    return url

# 期限切れのエントリをクリーンアップ
proc cleanupExpiredEntries*(manager: HstsManager) =
  let currentTime = now()
  
  # 最後のクリーンアップから十分な時間が経過していない場合はスキップ
  if (currentTime - manager.lastCleanupTime).inSeconds < manager.config.cleanupInterval:
    return
  
  var expiredKeys: seq[string] = @[]
  
  # 期限切れエントリを検索
  for host, entry in manager.entries:
    if currentTime > entry.expire:
      expiredKeys.add(host)
  
  # 期限切れエントリを削除
  for host in expiredKeys:
    manager.entries.del(host)
  
  # クリーンアップ情報をログに記録
  if expiredKeys.len > 0:
    log(lvlInfo, fmt"{expiredKeys.len} 個の期限切れHSTSエントリを削除しました")
    
    # 永続化
    if manager.config.persistentStorage:
      manager.saveEntries()
  
  # 最後のクリーンアップ時間を更新
  manager.lastCleanupTime = currentTime

# プリロードリストを読み込み
proc loadPreloadedList*(manager: HstsManager) =
  if not fileExists(manager.config.preloadedListPath):
    log(lvlWarn, fmt"HSTSプリロードリストが見つかりません: {manager.config.preloadedListPath}")
    return
  
  try:
    let jsonContent = readFile(manager.config.preloadedListPath)
    let jsonNode = parseJson(jsonContent)
    
    if jsonNode.kind != JObject:
      log(lvlError, "無効なHSTSプリロードリスト形式: オブジェクトが予期されました")
      return
    
    # 通常のホストのリスト
    if jsonNode.hasKey("hosts") and jsonNode["hosts"].kind == JArray:
      for item in jsonNode["hosts"]:
        if item.kind == JString:
          manager.preloadedHosts.incl(item.getStr())
    
    # サブドメインを含むホストのリスト
    if jsonNode.hasKey("includeSubdomains") and jsonNode["includeSubdomains"].kind == JArray:
      for item in jsonNode["includeSubdomains"]:
        if item.kind == JString:
          let host = item.getStr()
          manager.preloadedHosts.incl(host)
          manager.preloadedIncludeSubdomains.incl(host)
    
    log(lvlInfo, fmt"HSTSプリロードリストを読み込みました: {manager.preloadedHosts.len} ホスト, {manager.preloadedIncludeSubdomains.len} サブドメイン含む")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTSプリロードリストの読み込みに失敗しました: {msg}")

# エントリをJSONとして保存
proc saveEntries*(manager: HstsManager) =
  if not manager.config.persistentStorage:
    return
  
  try:
    # ディレクトリを作成
    let dir = parentDir(manager.config.storageLocation)
    createDir(dir)
    
    # JSONを作成
    var entriesArray = newJArray()
    
    for host, entry in manager.entries:
      # プリロードリストからのエントリは保存しない
      if entry.source == hstsPreloaded:
        continue
      
      var entryObj = newJObject()
      entryObj["host"] = %entry.host
      entryObj["includeSubdomains"] = %entry.includeSubdomains
      entryObj["expire"] = %entry.expire.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      entryObj["lastAccessed"] = %entry.lastAccessed.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      entryObj["source"] = %($entry.source)
      
      entriesArray.add(entryObj)
    
    # ファイルに保存
    let jsonContent = $entriesArray
    writeFile(manager.config.storageLocation, jsonContent)
    
    log(lvlInfo, fmt"HSTSエントリを保存しました: {entriesArray.len} エントリ")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTSエントリの保存に失敗しました: {msg}")

# エントリをJSONから読み込み
proc loadEntries*(manager: HstsManager) =
  if not manager.config.persistentStorage:
    return
  
  if not fileExists(manager.config.storageLocation):
    log(lvlInfo, fmt"HSTS永続化ファイルが見つかりません: {manager.config.storageLocation}")
    return
  
  try:
    let jsonContent = readFile(manager.config.storageLocation)
    let jsonNode = parseJson(jsonContent)
    
    if jsonNode.kind != JArray:
      log(lvlError, "無効なHSTS永続化ファイル形式: 配列が予期されました")
      return
    
    var loadedCount = 0
    let currentTime = now()
    
    for item in jsonNode:
      if item.kind != JObject:
        continue
      
      # 必須フィールドのチェック
      if not (item.hasKey("host") and item.hasKey("expire")):
        continue
      
      let host = item["host"].getStr()
      
      # 有効期限をパース
      var expire: DateTime
      try:
        expire = parse(item["expire"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        # 無効な日付形式の場合はスキップ
        continue
      
      # 期限切れの場合はスキップ
      if currentTime > expire:
        continue
      
      # includeSubdomainsをパース
      let includeSubdomains = if item.hasKey("includeSubdomains"): item["includeSubdomains"].getBool() else: false
      
      # lastAccessedをパース
      var lastAccessed = currentTime
      if item.hasKey("lastAccessed"):
        try:
          lastAccessed = parse(item["lastAccessed"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
        except:
          # 無効な日付形式の場合はデフォルト使用
          discard
      
      # ソースをパース
      var source = hstsPersisted
      if item.hasKey("source"):
        try:
          source = parseEnum[HstsSource](item["source"].getStr())
        except:
          # 無効なソース形式の場合はデフォルト使用
          discard
      
      # プリロードリストからのエントリは読み込まない
      if source == hstsPreloaded:
        continue
      
      # エントリを作成
      let entry = HstsEntry(
        host: host,
        includeSubdomains: includeSubdomains,
        expire: expire,
        lastAccessed: lastAccessed,
        source: source
      )
      
      # エントリを追加
      manager.entries[host] = entry
      inc(loadedCount)
    
    log(lvlInfo, fmt"HSTS永続化エントリを読み込みました: {loadedCount} エントリ")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTS永続化エントリの読み込みに失敗しました: {msg}")

# ホストを強制的にHSTS適用リストに追加
proc addEnforcedHost*(manager: HstsManager, host: string) =
  manager.config.enforcedHosts.incl(host)
  log(lvlInfo, fmt"ホスト {host} をHSTS強制適用リストに追加しました")

# ホストを強制的にHSTS適用リストから削除
proc removeEnforcedHost*(manager: HstsManager, host: string) =
  manager.config.enforcedHosts.excl(host)
  log(lvlInfo, fmt"ホスト {host} をHSTS強制適用リストから削除しました")

# ホストをHSTSバイパスリストに追加
proc addBypassedHost*(manager: HstsManager, host: string) =
  manager.config.bypassedHosts.incl(host)
  
  # 既存のエントリを削除
  if host in manager.entries:
    manager.entries.del(host)
    if manager.config.persistentStorage:
      manager.saveEntries()
  
  log(lvlInfo, fmt"ホスト {host} をHSTSバイパスリストに追加しました")

# ホストをHSTSバイパスリストから削除
proc removeBypassedHost*(manager: HstsManager, host: string) =
  manager.config.bypassedHosts.excl(host)
  log(lvlInfo, fmt"ホスト {host} をHSTSバイパスリストから削除しました")

# 許可されたポートを設定
proc setAllowedPorts*(manager: HstsManager, ports: seq[int]) =
  manager.allowedPorts = ports
  log(lvlInfo, fmt"HSTS許可ポートを設定しました: {ports}")

# 設定をJSONに変換
proc toJson*(config: HstsConfig): JsonNode =
  result = newJObject()
  result["state"] = %($config.state)
  result["persistent_storage"] = %config.persistentStorage
  result["storage_location"] = %config.storageLocation
  result["max_age"] = %config.maxAge
  result["cleanup_interval"] = %config.cleanupInterval
  result["preloaded_list_enabled"] = %config.preloadedListEnabled
  result["preloaded_list_path"] = %config.preloadedListPath
  
  var enforcedArray = newJArray()
  for host in config.enforcedHosts:
    enforcedArray.add(%host)
  result["enforced_hosts"] = enforcedArray
  
  var bypassedArray = newJArray()
  for host in config.bypassedHosts:
    bypassedArray.add(%host)
  result["bypassed_hosts"] = bypassedArray

# JSONから設定を作成
proc fromJson*(jsonNode: JsonNode): HstsConfig =
  if jsonNode.kind != JObject:
    return newHstsConfig()
  
  result = newHstsConfig()
  
  if jsonNode.hasKey("state"):
    try:
      result.state = parseEnum[HstsState](jsonNode["state"].getStr())
    except:
      discard
  
  if jsonNode.hasKey("persistent_storage"):
    try:
      result.persistentStorage = jsonNode["persistent_storage"].getBool()
    except:
      discard
  
  if jsonNode.hasKey("storage_location"):
    result.storageLocation = jsonNode["storage_location"].getStr()
  
  if jsonNode.hasKey("max_age"):
    try:
      result.maxAge = jsonNode["max_age"].getInt()
    except:
      discard
  
  if jsonNode.hasKey("cleanup_interval"):
    try:
      result.cleanupInterval = jsonNode["cleanup_interval"].getInt()
    except:
      discard
  
  if jsonNode.hasKey("preloaded_list_enabled"):
    try:
      result.preloadedListEnabled = jsonNode["preloaded_list_enabled"].getBool()
    except:
      discard
  
  if jsonNode.hasKey("preloaded_list_path"):
    result.preloadedListPath = jsonNode["preloaded_list_path"].getStr()
  
  # 強制適用ホストの読み込み
  if jsonNode.hasKey("enforced_hosts") and jsonNode["enforced_hosts"].kind == JArray:
    for item in jsonNode["enforced_hosts"]:
      if item.kind == JString:
        result.enforcedHosts.incl(item.getStr())
  
  # バイパスホストの読み込み
  if jsonNode.hasKey("bypassed_hosts") and jsonNode["bypassed_hosts"].kind == JArray:
    for item in jsonNode["bypassed_hosts"]:
      if item.kind == JString:
        result.bypassedHosts.incl(item.getStr())
  
  return result

# 設定を保存
proc saveConfig*(manager: HstsManager, configPath: string): bool =
  try:
    # ディレクトリを作成
    let dir = parentDir(configPath)
    createDir(dir)
    
    # JSONに変換
    let jsonNode = manager.config.toJson()
    let jsonContent = pretty(jsonNode)
    
    # ファイルに保存
    writeFile(configPath, jsonContent)
    
    log(lvlInfo, fmt"HSTS設定を保存しました: {configPath}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTS設定の保存に失敗しました: {msg}")
    return false

# 設定を読み込み
proc loadConfig*(manager: HstsManager, configPath: string): bool =
  if not fileExists(configPath):
    log(lvlWarn, fmt"HSTS設定ファイルが見つかりません: {configPath}")
    return false
  
  try:
    let jsonContent = readFile(configPath)
    let jsonNode = parseJson(jsonContent)
    
    # 設定を更新
    manager.config = fromJson(jsonNode)
    
    log(lvlInfo, fmt"HSTS設定を読み込みました: {configPath}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"HSTS設定の読み込みに失敗しました: {msg}")
    return false

# 全てのエントリをクリア
proc clearAllEntries*(manager: HstsManager) =
  manager.entries.clear()
  
  if manager.config.persistentStorage:
    manager.saveEntries()
  
  log(lvlInfo, "全てのHSTSエントリをクリアしました")

# HSTSの統計情報を取得
proc getStats*(manager: HstsManager): JsonNode =
  result = newJObject()
  
  # 総エントリ数
  result["total_entries"] = %manager.entries.len
  
  # プリロードエントリ数
  result["preloaded_hosts"] = %manager.preloadedHosts.len
  result["preloaded_includesubdomains"] = %manager.preloadedIncludeSubdomains.len
  
  # 強制適用ホスト数
  result["enforced_hosts"] = %manager.config.enforcedHosts.len
  
  # バイパスホスト数
  result["bypassed_hosts"] = %manager.config.bypassedHosts.len
  
  # ソース別エントリ数
  var sourceCounts = initTable[string, int]()
  for host, entry in manager.entries:
    let source = $entry.source
    if source in sourceCounts:
      inc(sourceCounts[source])
    else:
      sourceCounts[source] = 1
  
  var sourceObj = newJObject()
  for source, count in sourceCounts:
    sourceObj[source] = %count
  
  result["sources"] = sourceObj
  
  # 有効期限ごとのエントリ数
  var expiryCounts = initTable[string, int]()
  let currentTime = now()
  
  for host, entry in manager.entries:
    let daysRemaining = (entry.expire - currentTime).inDays
    let bucket = if daysRemaining < 7:
                   "< 7 days"
                 elif daysRemaining < 30:
                   "< 30 days"
                 elif daysRemaining < 90:
                   "< 90 days"
                 elif daysRemaining < 180:
                   "< 180 days"
                 else:
                   ">= 180 days"
    
    if bucket in expiryCounts:
      inc(expiryCounts[bucket])
    else:
      expiryCounts[bucket] = 1
  
  var expiryObj = newJObject()
  for bucket, count in expiryCounts:
    expiryObj[bucket] = %count
  
  result["expiry"] = expiryObj

# サブドメインを含むエントリのリストを取得
proc getIncludeSubdomainsEntries*(manager: HstsManager): seq[string] =
  result = @[]
  
  for host, entry in manager.entries:
    if entry.includeSubdomains:
      result.add(host)
  
  return result

# バージョン情報
const HstsManagerVersion* = "1.0.0" 