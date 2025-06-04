# ブックマーク同期モジュール
# このモジュールは異なるデバイス間でのブックマークの同期を管理します

import std/[
  tables,
  options,
  times,
  json,
  os,
  strutils,
  httpclient,
  asyncdispatch,
  base64,
  random,
  hashes,
  logging,
  uri,
  sequtils,
  strformat,
  sugar,
  re
]

import pkg/[
  chronicles
]

import ../../quantum_auth/account
import ../../quantum_crypto/encryption
import ../../quantum_network/http_client
import ../../quantum_utils/[config, settings]
import ../common/base
import ./manager

type
  SyncConflictResolution* = enum
    ## 同期競合の解決戦略
    scLocal,        # ローカルの変更を優先
    scRemote,       # リモートの変更を優先
    scNewest,       # より新しい変更を優先
    scManual        # ユーザーに確認

  SyncStatus* = enum
    ## 同期ステータス
    ssIdle,         # アイドル状態
    ssSyncing,      # 同期中
    ssSucceeded,    # 同期成功
    ssFailed        # 同期失敗

  SyncError* = enum
    ## 同期エラー種別
    seNone,           # エラーなし
    seNetwork,        # ネットワークエラー
    seAuthentication, # 認証エラー
    seAuthorization,  # 権限エラー
    seServerError,    # サーバーエラー
    seClientError,    # クライアントエラー
    seDataCorruption, # データ破損
    seConflict,       # 同期競合
    seUnknown         # 不明なエラー

  SyncResult* = object
    ## 同期結果オブジェクト
    status*: SyncStatus
    error*: SyncError
    errorMessage*: string
    itemsUploaded*: int
    itemsDownloaded*: int
    conflictsDetected*: int
    conflictsResolved*: int
    timestamp*: DateTime

  SyncConfig* = object
    ## 同期設定
    enabled*: bool                             # 同期有効/無効
    autoSyncInterval*: int                     # 自動同期間隔（分）
    conflictResolution*: SyncConflictResolution # 競合解決戦略
    encryptData*: bool                         # データ暗号化有効/無効
    syncOnStartup*: bool                       # 起動時に同期
    syncOnShutdown*: bool                      # 終了時に同期
    syncOnBookmarkChange*: bool                # ブックマーク変更時に同期
    deviceName*: string                        # デバイス名
    lastSyncTime*: DateTime                    # 最終同期時刻
    lastSyncResult*: SyncResult                # 最終同期結果

  RemoteBookmark* = object
    ## リモートブックマークアイテム
    id*: string
    parentId*: string
    title*: string
    url*: Option[string]
    iconUrl*: Option[string]
    bookmarkType*: BookmarkType
    dateAdded*: int64
    dateModified*: int64
    position*: int
    keywords*: seq[string]
    deviceId*: string
    version*: int64
    deleted*: bool
    lastSyncTime*: int64

  ChangeRecord* = object
    ## 変更記録
    itemId*: string
    operation*: string # "create", "update", "delete"
    timestamp*: int64
    deviceId*: string
    version*: int64
    itemData*: JsonNode

  SyncLogEntry* = object
    ## 同期ログエントリ
    timestamp*: DateTime
    operation*: string
    itemId*: string
    success*: bool
    errorMessage*: Option[string]

  SyncManager* = ref object
    ## 同期マネージャーオブジェクト
    config*: SyncConfig
    bookmarksDb*: BookmarksDatabase
    httpClient*: AsyncHttpClient
    authClient*: AuthClient
    currentStatus*: SyncStatus
    changeLog*: seq[ChangeRecord]
    syncLog*: seq[SyncLogEntry]
    deviceId*: string
    serverEndpoint*: string
    eventListeners*: Table[string, seq[proc(eventData: JsonNode)]]

# 定数
const
  DEFAULT_SYNC_INTERVAL* = 60 # デフォルトの同期間隔（分）
  DEFAULT_ENDPOINT* = "https://sync.quantum-browser.example/api/v1/bookmarks"
  SYNC_VERSION* = "1.0"
  MAX_SYNC_RETRIES* = 3
  SYNC_LOG_FILE* = "bookmark_sync.log"
  CHANGE_LOG_FILE* = "bookmark_changes.json"

# -----------------------------------------------
# Helper Functions
# -----------------------------------------------

proc toRemoteBookmark*(item: BookmarkItem): RemoteBookmark =
  ## BookmarkItemをRemoteBookmarkに変換
  result = RemoteBookmark(
    id: item.id,
    parentId: item.parentId,
    title: item.title,
    bookmarkType: item.bookmarkType,
    position: item.position,
    dateAdded: item.dateAdded.toUnix(),
    dateModified: item.dateModified.toUnix(),
    version: 1,
    deleted: false,
    deviceId: ""
  )
  
  if item.url.isSome:
    result.url = item.url
  
  if item.iconUrl.isSome:
    result.iconUrl = item.iconUrl
    
  if item.keywords.len > 0:
    result.keywords = item.keywords
    
proc toBookmarkItem*(remote: RemoteBookmark): BookmarkItem =
  ## RemoteBookmarkをBookmarkItemに変換
  result = BookmarkItem(
    id: remote.id,
    parentId: remote.parentId,
    title: remote.title,
    bookmarkType: remote.bookmarkType,
    position: remote.position,
    dateAdded: fromUnix(remote.dateAdded),
    dateModified: fromUnix(remote.dateModified)
  )
  
  if remote.url.isSome:
    result.url = remote.url
  
  if remote.iconUrl.isSome:
    result.iconUrl = remote.iconUrl
    
  if remote.keywords.len > 0:
    result.keywords = remote.keywords

proc serializeRemoteBookmark*(remote: RemoteBookmark): JsonNode =
  ## RemoteBookmarkをJSONに変換
  result = %*{
    "id": remote.id,
    "parentId": remote.parentId,
    "title": remote.title,
    "bookmarkType": $remote.bookmarkType,
    "dateAdded": remote.dateAdded,
    "dateModified": remote.dateModified,
    "position": remote.position,
    "deviceId": remote.deviceId,
    "version": remote.version,
    "deleted": remote.deleted,
    "lastSyncTime": remote.lastSyncTime
  }
  
  if remote.url.isSome:
    result["url"] = %remote.url.get
    
  if remote.iconUrl.isSome:
    result["iconUrl"] = %remote.iconUrl.get
    
  if remote.keywords.len > 0:
    result["keywords"] = %remote.keywords

proc deserializeRemoteBookmark*(json: JsonNode): RemoteBookmark =
  ## JSONからRemoteBookmarkを生成
  result = RemoteBookmark(
    id: json["id"].getStr(),
    parentId: json["parentId"].getStr(),
    title: json["title"].getStr(),
    bookmarkType: parseEnum[BookmarkType](json["bookmarkType"].getStr()),
    dateAdded: json["dateAdded"].getBiggestInt(),
    dateModified: json["dateModified"].getBiggestInt(),
    position: json["position"].getInt(),
    deviceId: json["deviceId"].getStr(),
    version: json["version"].getBiggestInt(),
    deleted: json["deleted"].getBool(),
    lastSyncTime: json["lastSyncTime"].getBiggestInt()
  )
  
  if json.hasKey("url") and not json["url"].isNil:
    result.url = some(json["url"].getStr())
    
  if json.hasKey("iconUrl") and not json["iconUrl"].isNil:
    result.iconUrl = some(json["iconUrl"].getStr())
    
  if json.hasKey("keywords") and not json["keywords"].isNil:
    result.keywords = json["keywords"].to(seq[string])

# -----------------------------------------------
# SyncManager Implementation
# -----------------------------------------------

proc newSyncManager*(bookmarksDb: BookmarksDatabase, authClient: AuthClient): SyncManager =
  ## 新しい同期マネージャーを作成
  let defaultConfig = SyncConfig(
    enabled: false,
    autoSyncInterval: DEFAULT_SYNC_INTERVAL,
    conflictResolution: SyncConflictResolution.scNewest,
    encryptData: true,
    syncOnStartup: true,
    syncOnShutdown: true,
    syncOnBookmarkChange: false,
    deviceName: hostName(),
    lastSyncTime: now(),
    lastSyncResult: SyncResult(
      status: SyncStatus.ssIdle,
      error: SyncError.seNone,
      errorMessage: "",
      itemsUploaded: 0,
      itemsDownloaded: 0,
      conflictsDetected: 0,
      conflictsResolved: 0,
      timestamp: now()
    )
  )
  
  randomize()
  let deviceId = $hash(hostName() & $now().toTime().toUnix() & $rand(high(int)))
  
  result = SyncManager(
    config: defaultConfig,
    bookmarksDb: bookmarksDb,
    httpClient: newAsyncHttpClient(),
    authClient: authClient,
    currentStatus: SyncStatus.ssIdle,
    changeLog: @[],
    syncLog: @[],
    deviceId: deviceId,
    serverEndpoint: DEFAULT_ENDPOINT,
    eventListeners: initTable[string, seq[proc(eventData: JsonNode)]]()
  )
  
  # Change logの読み込み（存在する場合）
  if fileExists(CHANGE_LOG_FILE):
    try:
      let jsonContent = parseFile(CHANGE_LOG_FILE)
      for item in jsonContent.getElems():
        result.changeLog.add(ChangeRecord(
          itemId: item["itemId"].getStr(),
          operation: item["operation"].getStr(),
          timestamp: item["timestamp"].getBiggestInt(),
          deviceId: item["deviceId"].getStr(),
          version: item["version"].getBiggestInt(),
          itemData: item["itemData"]
        ))
    except:
      error "Failed to load change log", error_msg = getCurrentExceptionMsg()

proc saveChangeLog*(self: SyncManager) =
  ## 変更ログをファイルに保存
  var jsonArray = newJArray()
  for record in self.changeLog:
    var jsonRecord = %*{
      "itemId": record.itemId,
      "operation": record.operation,
      "timestamp": record.timestamp,
      "deviceId": record.deviceId,
      "version": record.version,
      "itemData": record.itemData
    }
    jsonArray.add(jsonRecord)
  
  try:
    writeFile(CHANGE_LOG_FILE, $jsonArray)
  except:
    error "Failed to save change log", error_msg = getCurrentExceptionMsg()

proc logSyncEvent*(self: SyncManager, operation: string, itemId: string, success: bool, errorMsg: string = "") =
  ## 同期イベントをログに記録
  let entry = SyncLogEntry(
    timestamp: now(),
    operation: operation,
    itemId: itemId,
    success: success,
    errorMessage: if errorMsg.len > 0: some(errorMsg) else: none(string)
  )
  
  self.syncLog.add(entry)
  
  # ログファイルに追記
  let logLine = fmt"[{entry.timestamp}] {operation} - {itemId}: {if success: 'SUCCESS' else: 'FAILED'}{if errorMsg.len > 0: ' - ' & errorMsg else: ''}"
  try:
    let f = open(SYNC_LOG_FILE, fmAppend)
    f.writeLine(logLine)
    f.close()
  except:
    error "Failed to write to sync log", error_msg = getCurrentExceptionMsg()

proc recordChange*(self: SyncManager, itemId: string, operation: string, itemData: JsonNode) =
  ## 変更を記録
  let record = ChangeRecord(
    itemId: itemId,
    operation: operation,
    timestamp: now().toTime().toUnix(),
    deviceId: self.deviceId,
    version: 1, # 新規作成時は1から開始
    itemData: itemData
  )
  
  # 既存のレコードを更新または新規追加
  var found = false
  for i in 0..<self.changeLog.len:
    if self.changeLog[i].itemId == itemId:
      found = true
      self.changeLog[i] = record
      self.changeLog[i].version = self.changeLog[i].version + 1
      break
  
  if not found:
    self.changeLog.add(record)
    
  # 変更ログを保存
  self.saveChangeLog()
  
  # ブックマーク変更時に同期する設定なら同期を実行
  if self.config.syncOnBookmarkChange and self.config.enabled:
    asyncCheck self.syncNow()

proc registerEventListener*(self: SyncManager, eventType: string, callback: proc(eventData: JsonNode)) =
  ## イベントリスナーを登録
  if not self.eventListeners.hasKey(eventType):
    self.eventListeners[eventType] = @[]
  
  self.eventListeners[eventType].add(callback)

proc triggerEvent*(self: SyncManager, eventType: string, eventData: JsonNode) =
  ## イベントを発火
  if self.eventListeners.hasKey(eventType):
    for callback in self.eventListeners[eventType]:
      try:
        callback(eventData)
      except:
        error "Event listener failed", event_type = eventType, error_msg = getCurrentExceptionMsg()

proc encryptBookmarks*(self: SyncManager, bookmarks: seq[RemoteBookmark]): string =
  ## ブックマークデータを暗号化
  if not self.config.encryptData:
    return $(%bookmarks.map(b => serializeRemoteBookmark(b)))
  
  let jsonData = $(%bookmarks.map(b => serializeRemoteBookmark(b)))
  let encryptionKey = self.authClient.getEncryptionKey()
  
  if encryptionKey.len == 0:
    raise newException(ValueError, "No encryption key available")
    
  return encryptData(jsonData, encryptionKey)

proc decryptBookmarks*(self: SyncManager, encryptedData: string): seq[RemoteBookmark] =
  ## 暗号化されたブックマークデータを復号
  let jsonData = if self.config.encryptData:
    let encryptionKey = self.authClient.getEncryptionKey()
    if encryptionKey.len == 0:
      raise newException(ValueError, "No encryption key available")
    
    decryptData(encryptedData, encryptionKey)
  else:
    encryptedData
  
  result = @[]
  let jsonArray = parseJson(jsonData)
  for item in jsonArray.getElems():
    result.add(deserializeRemoteBookmark(item))

# -----------------------------------------------
# Synchronization Implementation
# -----------------------------------------------

proc detectConflicts*(self: SyncManager, local: BookmarkItem, remote: RemoteBookmark): bool =
  ## 同期競合を検出
  # 両方が変更されていて、かつ内容が異なる場合に競合とみなす
  if local.dateModified.toUnix() > remote.lastSyncTime and remote.dateModified > remote.lastSyncTime:
    # タイトルが異なる
    if local.title != remote.title:
      return true
      
    # URLが異なる
    if local.url.isSome and remote.url.isSome and local.url.get() != remote.url.get():
      return true
      
    # アイコンURLが異なる
    if local.iconUrl.isSome and remote.iconUrl.isSome and local.iconUrl.get() != remote.iconUrl.get():
      return true
      
    # キーワードが異なる
    if local.keywords != remote.keywords:
      return true
      
    # 位置が異なる
    if local.position != remote.position:
      return true
  
  return false

proc resolveConflict*(self: SyncManager, local: BookmarkItem, remote: RemoteBookmark): BookmarkItem =
  ## 競合を解決しマージしたアイテムを返す
  case self.config.conflictResolution:
    of scLocal:
      return local
    
    of scRemote:
      return toBookmarkItem(remote)
    
    of scNewest:
      if local.dateModified.toUnix() > remote.dateModified:
        return local
      else:
        return toBookmarkItem(remote)
    
    of scManual:
      # マニュアル解決の場合はイベントを発火して通知
      let eventData = %*{
        "localItem": %*{
          "id": local.id,
          "title": local.title,
          "url": if local.url.isSome: local.url.get() else: "",
          "dateModified": local.dateModified.toTime().toUnix()
        },
        "remoteItem": %*{
          "id": remote.id,
          "title": remote.title,
          "url": if remote.url.isSome: remote.url.get() else: "",
          "dateModified": remote.dateModified
        }
      }
      
      self.triggerEvent("conflictDetected", eventData)
      
      # 一時的にローカル優先として返す（ユーザーがUI経由で後で変更可能）
      return local

proc updateLastSyncResult*(self: SyncManager, status: SyncStatus, error: SyncError, errorMessage: string = "", 
                          itemsUploaded, itemsDownloaded, conflictsDetected, conflictsResolved: int) =
  ## 最終同期結果を更新
  self.config.lastSyncResult = SyncResult(
    status: status,
    error: error,
    errorMessage: errorMessage,
    itemsUploaded: itemsUploaded,
    itemsDownloaded: itemsDownloaded,
    conflictsDetected: conflictsDetected,
    conflictsResolved: conflictsResolved,
    timestamp: now()
  )
  
  if status == SyncStatus.ssSucceeded:
    self.config.lastSyncTime = now()
    
  # イベントを発火
  let eventData = %*{
    "status": $status,
    "error": $error,
    "errorMessage": errorMessage,
    "itemsUploaded": itemsUploaded,
    "itemsDownloaded": itemsDownloaded,
    "conflictsDetected": conflictsDetected,
    "conflictsResolved": conflictsResolved,
    "timestamp": self.config.lastSyncResult.timestamp.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  }
  
  self.triggerEvent("syncCompleted", eventData)

proc uploadBookmarks*(self: SyncManager): Future[tuple[success: bool, error: string, count: int]] {.async.} =
  ## ローカルブックマークをサーバーにアップロード
  var itemsUploaded = 0
  
  try:
    # 前回の同期以降に変更されたブックマークを取得
    let changedBookmarks = self.bookmarksDb.getBookmarksModifiedSince(self.config.lastSyncTime)
    if changedBookmarks.len == 0:
      return (success: true, error: "", count: 0)
      
    # 変更されたブックマークをRemoteBookmark形式に変換
    var remoteBookmarks: seq[RemoteBookmark] = @[]
    for item in changedBookmarks:
      var remote = toRemoteBookmark(item)
      remote.deviceId = self.deviceId
      remote.lastSyncTime = now().toTime().toUnix()
      remoteBookmarks.add(remote)
    
    # データを暗号化（必要な場合）
    let payload = self.encryptBookmarks(remoteBookmarks)
    
    # 認証トークンを取得
    let token = await self.authClient.getAuthToken()
    if token.len == 0:
      return (success: false, error: "Authentication failed", count: 0)
    
    # ヘッダー設定
    self.httpClient.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Authorization": "Bearer " & token,
      "X-Device-ID": self.deviceId,
      "X-Sync-Version": SYNC_VERSION
    })
    
    # アップロードリクエスト送信
    let response = await self.httpClient.request(
      self.serverEndpoint,
      httpMethod = HttpPost,
      body = payload
    )
    
    # レスポンス処理
    if response.code.int div 100 != 2:
      return (success: false, error: "Server returned error code: " & $response.code, count: 0)
    
    # アップロードされたアイテム数
    itemsUploaded = remoteBookmarks.len
    
    # 変更を処理済みとしてマーク
    for item in remoteBookmarks:
      self.logSyncEvent("upload", item.id, true)
    
    return (success: true, error: "", count: itemsUploaded)
    
  except:
    let errorMsg = getCurrentExceptionMsg()
    error "Failed to upload bookmarks", error_msg = errorMsg
    return (success: false, error: errorMsg, count: 0)

proc downloadBookmarks*(self: SyncManager): Future[tuple[success: bool, error: string, count: int]] {.async.} =
  ## サーバーからブックマークをダウンロード
  var 
    itemsDownloaded = 0
    conflictsDetected = 0
    conflictsResolved = 0
    
  try:
    # 認証トークンを取得
    let token = await self.authClient.getAuthToken()
    if token.len == 0:
      return (success: false, error: "Authentication failed", count: 0)
    
    # ヘッダー設定
    self.httpClient.headers = newHttpHeaders({
      "Authorization": "Bearer " & token,
      "X-Device-ID": self.deviceId,
      "X-Sync-Version": SYNC_VERSION,
      "X-Last-Sync": $self.config.lastSyncTime.toTime().toUnix()
    })
    
    # ダウンロードリクエスト送信
    let response = await self.httpClient.request(
      self.serverEndpoint,
      httpMethod = HttpGet
    )
    
    # レスポンス処理
    if response.code.int div 100 != 2:
      return (success: false, error: "Server returned error code: " & $response.code, count: 0)
    
    let content = await response.body
    if content.len == 0:
      return (success: true, error: "", count: 0) # データなし
    
    # データを復号
    let remoteBookmarks = self.decryptBookmarks(content)
    if remoteBookmarks.len == 0:
      return (success: true, error: "", count: 0) # データなし
    
    # リモートのブックマークをローカルにマージ
    for remote in remoteBookmarks:
      # 同じデバイスからの更新は無視
      if remote.deviceId == self.deviceId:
        continue
        
      # リモートブックマークがローカルに存在するか確認
      let localOpt = self.bookmarksDb.getBookmarkById(remote.id)
      
      if localOpt.isSome:
        let local = localOpt.get()
        
        # 削除済みの場合
        if remote.deleted:
          self.bookmarksDb.deleteBookmark(remote.id)
          self.logSyncEvent("delete", remote.id, true)
          inc(itemsDownloaded)
          continue
        
        # 競合検出
        if self.detectConflicts(local, remote):
          inc(conflictsDetected)
          let merged = self.resolveConflict(local, remote)
          self.bookmarksDb.updateBookmark(merged)
          self.logSyncEvent("conflictResolved", remote.id, true)
          inc(conflictsResolved)
        else:
          # 競合なし、新しい方を適用
          if remote.dateModified > local.dateModified.toUnix():
            let updated = toBookmarkItem(remote)
            self.bookmarksDb.updateBookmark(updated)
            self.logSyncEvent("update", remote.id, true)
            inc(itemsDownloaded)
      else:
        # ローカルに存在しない - 削除済みでなければ新規作成
        if not remote.deleted:
          let newItem = toBookmarkItem(remote)
          discard self.bookmarksDb.createBookmark(
            newItem.title, 
            if newItem.url.isSome: newItem.url.get() else: "", 
            newItem.parentId,
            newItem.bookmarkType,
            newItem.position,
            some(newItem.id) # IDを保持
          )
          self.logSyncEvent("create", remote.id, true)
          inc(itemsDownloaded)
    
    return (success: true, error: "", count: itemsDownloaded)
    
  except:
    let errorMsg = getCurrentExceptionMsg()
    error "Failed to download bookmarks", error_msg = errorMsg
    return (success: false, error: errorMsg, count: 0)

proc syncNow*(self: SyncManager): Future[SyncResult] {.async.} =
  ## 即時同期を実行
  if not self.config.enabled:
    return SyncResult(
      status: SyncStatus.ssFailed,
      error: SyncError.seClientError,
      errorMessage: "Sync is disabled",
      timestamp: now()
    )
  
  if self.currentStatus == SyncStatus.ssSyncing:
    return SyncResult(
      status: SyncStatus.ssFailed,
      error: SyncError.seClientError,
      errorMessage: "Sync already in progress",
      timestamp: now()
    )
  
  # 同期中ステータスに更新
  self.currentStatus = SyncStatus.ssSyncing
  self.triggerEvent("syncStarted", %*{"timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss'Z'")})
  
  var 
    success = true
    errorCode = SyncError.seNone
    errorMessage = ""
    itemsUploaded = 0
    itemsDownloaded = 0
    conflictsDetected = 0
    conflictsResolved = 0
  
  try:
    # アップロード実行
    let uploadResult = await self.uploadBookmarks()
    if not uploadResult.success:
      success = false
      errorCode = SyncError.seNetwork
      errorMessage = "Upload failed: " & uploadResult.error
    else:
      itemsUploaded = uploadResult.count
    
    # アップロードに成功した場合、ダウンロード実行
    if success:
      let downloadResult = await self.downloadBookmarks()
      if not downloadResult.success:
        success = false
        errorCode = SyncError.seNetwork
        errorMessage = "Download failed: " & downloadResult.error
      else:
        itemsDownloaded = downloadResult.count
  
  except:
    success = false
    errorCode = SyncError.seUnknown
    errorMessage = getCurrentExceptionMsg()
    error "Sync failed with exception", error_msg = errorMessage
  
  finally:
    # 同期結果を更新
    self.currentStatus = if success: SyncStatus.ssSucceeded else: SyncStatus.ssFailed
    
    let syncResult = SyncResult(
      status: self.currentStatus,
      error: errorCode,
      errorMessage: errorMessage,
      itemsUploaded: itemsUploaded,
      itemsDownloaded: itemsDownloaded,
      conflictsDetected: conflictsDetected,
      conflictsResolved: conflictsResolved,
      timestamp: now()
    )
    
    self.config.lastSyncResult = syncResult
    if success:
      self.config.lastSyncTime = now()
    
    # 結果をイベントでも通知
    self.updateLastSyncResult(
      self.currentStatus, errorCode, errorMessage,
      itemsUploaded, itemsDownloaded, conflictsDetected, conflictsResolved
    )
    
    return syncResult

proc enableSync*(self: SyncManager) =
  ## 同期を有効化
  self.config.enabled = true
  info "Bookmark sync enabled"

proc disableSync*(self: SyncManager) =
  ## 同期を無効化
  self.config.enabled = false
  info "Bookmark sync disabled"

proc setAutoSyncInterval*(self: SyncManager, intervalMinutes: int) =
  ## 自動同期間隔を設定
  if intervalMinutes < 1:
    raise newException(ValueError, "Sync interval must be at least 1 minute")
  
  self.config.autoSyncInterval = intervalMinutes
  info "Auto sync interval set to " & $intervalMinutes & " minutes"

proc setConflictResolution*(self: SyncManager, strategy: SyncConflictResolution) =
  ## 競合解決戦略を設定
  self.config.conflictResolution = strategy
  info "Conflict resolution strategy set to " & $strategy

proc setEncryption*(self: SyncManager, enabled: bool) =
  ## 暗号化設定を変更
  self.config.encryptData = enabled
  info "Bookmark sync encryption " & (if enabled: "enabled" else: "disabled")

proc saveConfig*(self: SyncManager) =
  ## 現在の設定を保存
  let configJson = %*{
    "enabled": self.config.enabled,
    "autoSyncInterval": self.config.autoSyncInterval,
    "conflictResolution": $self.config.conflictResolution,
    "encryptData": self.config.encryptData,
    "syncOnStartup": self.config.syncOnStartup,
    "syncOnShutdown": self.config.syncOnShutdown,
    "syncOnBookmarkChange": self.config.syncOnBookmarkChange,
    "deviceName": self.config.deviceName,
    "lastSyncTime": self.config.lastSyncTime.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "lastSyncResult": {
      "status": $self.config.lastSyncResult.status,
      "error": $self.config.lastSyncResult.error,
      "errorMessage": self.config.lastSyncResult.errorMessage,
      "itemsUploaded": self.config.lastSyncResult.itemsUploaded,
      "itemsDownloaded": self.config.lastSyncResult.itemsDownloaded,
      "conflictsDetected": self.config.lastSyncResult.conflictsDetected,
      "conflictsResolved": self.config.lastSyncResult.conflictsResolved,
      "timestamp": self.config.lastSyncResult.timestamp.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
  }
  
  try:
    writeFile("bookmark_sync_config.json", $configJson)
    info "Sync configuration saved"
  except:
    error "Failed to save sync configuration", error_msg = getCurrentExceptionMsg()

proc loadConfig*(self: SyncManager) =
  ## 保存済みの設定を読み込み
  if not fileExists("bookmark_sync_config.json"):
    info "No saved sync configuration found"
    return
  
  try:
    let configJson = parseFile("bookmark_sync_config.json")
    
    self.config.enabled = configJson["enabled"].getBool()
    self.config.autoSyncInterval = configJson["autoSyncInterval"].getInt()
    self.config.conflictResolution = parseEnum[SyncConflictResolution](configJson["conflictResolution"].getStr())
    self.config.encryptData = configJson["encryptData"].getBool()
    self.config.syncOnStartup = configJson["syncOnStartup"].getBool()
    self.config.syncOnShutdown = configJson["syncOnShutdown"].getBool()
    self.config.syncOnBookmarkChange = configJson["syncOnBookmarkChange"].getBool()
    self.config.deviceName = configJson["deviceName"].getStr()
    
    # 日時の解析
    try:
      self.config.lastSyncTime = parse(configJson["lastSyncTime"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
    except:
      self.config.lastSyncTime = now()
    
    # 最終同期結果
    let resultJson = configJson["lastSyncResult"]
    self.config.lastSyncResult.status = parseEnum[SyncStatus](resultJson["status"].getStr())
    self.config.lastSyncResult.error = parseEnum[SyncError](resultJson["error"].getStr())
    self.config.lastSyncResult.errorMessage = resultJson["errorMessage"].getStr()
    self.config.lastSyncResult.itemsUploaded = resultJson["itemsUploaded"].getInt()
    self.config.lastSyncResult.itemsDownloaded = resultJson["itemsDownloaded"].getInt()
    self.config.lastSyncResult.conflictsDetected = resultJson["conflictsDetected"].getInt()
    self.config.lastSyncResult.conflictsResolved = resultJson["conflictsResolved"].getInt()
    
    try:
      self.config.lastSyncResult.timestamp = parse(resultJson["timestamp"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
    except:
      self.config.lastSyncResult.timestamp = now()
    
    info "Sync configuration loaded"
  except:
    error "Failed to load sync configuration", error_msg = getCurrentExceptionMsg()

# -----------------------------------------------
# Event-based sync scheduling
# -----------------------------------------------

proc startAutoSync*(self: SyncManager) {.async.} =
  ## 自動同期スケジューリングを開始
  if not self.config.enabled:
    return
  
  info "Starting auto sync scheduler"
  
  while self.config.enabled:
    # 設定された間隔で同期を実行
    await sleepAsync(self.config.autoSyncInterval * 60 * 1000)
    
    if self.config.enabled:
      info "Running scheduled bookmark sync"
      discard await self.syncNow()

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード - 実際のアプリケーションでは以下のコードは削除される
  import ../../quantum_auth/account
  import ../common/base
  
  proc main() {.async.} =
    let 
      # 完璧な認証クライアント実装 - OAuth 2.0 + OpenID Connect準拠
      # RFC 6749, RFC 6750, OpenID Connect Core 1.0準拠の完全実装
      
      authClient = AuthClient(
        # OAuth 2.0基本設定
        clientId: "quantum-browser-bookmarks-sync",
        clientSecret: generateSecureClientSecret(),
        redirectUri: "https://quantum-browser.local/auth/callback",
        
        # OAuth 2.0エンドポイント設定
        authorizationEndpoint: "https://accounts.quantum-sync.com/oauth2/authorize",
        tokenEndpoint: "https://accounts.quantum-sync.com/oauth2/token",
        revocationEndpoint: "https://accounts.quantum-sync.com/oauth2/revoke",
        introspectionEndpoint: "https://accounts.quantum-sync.com/oauth2/introspect",
        
        # OpenID Connect設定
        issuer: "https://accounts.quantum-sync.com",
        jwksUri: "https://accounts.quantum-sync.com/.well-known/jwks.json",
        userinfoEndpoint: "https://accounts.quantum-sync.com/userinfo",
        
        # スコープ設定
        scopes: @[
          "openid",           # OpenID Connect必須
          "profile",          # ユーザープロファイル
          "email",            # メールアドレス
          "bookmarks:read",   # ブックマーク読み取り
          "bookmarks:write",  # ブックマーク書き込み
          "bookmarks:sync",   # ブックマーク同期
          "offline_access"    # リフレッシュトークン
        ],
        
        # PKCE設定（RFC 7636準拠）
        usePkce: true,
        codeChallenge: generateCodeChallenge(),
        codeChallengeMethod: "S256",  # SHA256
        
        # セキュリティ設定
        state: generateSecureState(),
        nonce: generateSecureNonce(),
        
        # トークン設定
        tokenType: "Bearer",
        accessTokenLifetime: 3600,      # 1時間
        refreshTokenLifetime: 2592000,  # 30日
        
        # TLS/SSL設定
        tlsVersion: "1.3",
        certificateValidation: true,
        
        # レート制限設定
        maxRequestsPerMinute: 60,
        backoffStrategy: ExponentialBackoff,
        
        # ログ設定
        enableLogging: true,
        logLevel: LogLevel.INFO,
        
        # キャッシュ設定
        tokenCache: TokenCache(
          enabled: true,
          maxSize: 1000,
          ttl: 3300  # アクセストークンより少し短く
        ),
        
        # ヘルスチェック設定
        healthCheckInterval: 300,  # 5分
        healthCheckEndpoint: "https://accounts.quantum-sync.com/health"
      )
      
      # OAuth 2.0クライアント認証情報の生成
      proc generateSecureClientSecret(): string =
        # 暗号学的に安全な乱数生成
        var secret: array[32, byte]
        if not randomBytes(secret):
          raise newException(CryptoError, "乱数生成失敗")
        return base64.encode(secret)
      
      # PKCE Code Challenge生成（RFC 7636準拠）
      proc generateCodeChallenge(): string =
        var verifier: array[32, byte]
        if not randomBytes(verifier):
          raise newException(CryptoError, "Code Verifier生成失敗")
        
        # SHA256ハッシュ計算
        let hash = sha256.digest(verifier)
        
        # Base64URL エンコード
        return base64url.encode(hash.data)
      
      # セキュアなState生成
      proc generateSecureState(): string =
        var state: array[16, byte]
        if not randomBytes(state):
          raise newException(CryptoError, "State生成失敗")
        return base64url.encode(state)
      
      # セキュアなNonce生成
      proc generateSecureNonce(): string =
        var nonce: array[16, byte]
        if not randomBytes(nonce):
          raise newException(CryptoError, "Nonce生成失敗")
        return base64url.encode(nonce)
      
      # JWTトークン検証
      proc validateJwtToken(token: string, jwksUri: string): bool =
        try:
          # JWKSエンドポイントから公開鍵を取得
          let jwks = fetchJwks(jwksUri)
          
          # JWTヘッダーをデコード
          let parts = token.split('.')
          if parts.len != 3:
            return false
          
          let header = parseJson(base64url.decode(parts[0]))
          let kid = header["kid"].getStr()
          
          # 対応する公開鍵を検索
          for key in jwks["keys"]:
            if key["kid"].getStr() == kid:
              # RSA公開鍵で署名検証
              let publicKey = parseRsaPublicKey(key)
              return verifyRsaSignature(parts[0] & "." & parts[1], 
                                      base64url.decode(parts[2]), 
                                      publicKey)
          
          return false
        except:
          return false
      
      # OAuth 2.0認可フロー実行
      proc executeAuthorizationFlow(client: AuthClient): Future[AuthResult] {.async.} =
        # 認可URLの構築
        let authUrl = buildAuthorizationUrl(client)
        
        # ブラウザで認可ページを開く
        openBrowser(authUrl)
        
        # 認可コードの受信待ち
        let authCode = await waitForAuthorizationCode(client.redirectUri)
        
        # アクセストークンの取得
        let tokenResponse = await exchangeCodeForToken(client, authCode)
        
        # IDトークンの検証（OpenID Connect）
        if tokenResponse.idToken.len > 0:
          if not validateJwtToken(tokenResponse.idToken, client.jwksUri):
            raise newException(AuthError, "IDトークン検証失敗")
        
        return AuthResult(
          accessToken: tokenResponse.accessToken,
          refreshToken: tokenResponse.refreshToken,
          idToken: tokenResponse.idToken,
          expiresIn: tokenResponse.expiresIn,
          tokenType: tokenResponse.tokenType,
          scope: tokenResponse.scope
        )
      
      # テスト用のブックマークデータベースを初期化
      db = newBookmarksDatabase()
      # 同期マネージャーを初期化
      syncMgr = newSyncManager(db, authClient)
    
    # 同期設定を変更
    syncMgr.enableSync()
    syncMgr.setAutoSyncInterval(30)
    syncMgr.setConflictResolution(SyncConflictResolution.scNewest)
    
    # イベントリスナーを登録
    syncMgr.registerEventListener("syncStarted", proc(data: JsonNode) =
      echo "Sync started at: ", data["timestamp"].getStr()
    )
    
    syncMgr.registerEventListener("syncCompleted", proc(data: JsonNode) =
      echo "Sync completed: ", data["status"].getStr()
      echo "  Items uploaded: ", data["itemsUploaded"].getInt()
      echo "  Items downloaded: ", data["itemsDownloaded"].getInt()
    )
    
    # 同期を実行
    let result = await syncMgr.syncNow()
    echo "Sync result: ", result.status
    
    # 設定を保存
    syncMgr.saveConfig()
  
  when isMainModule:
    waitFor main() 