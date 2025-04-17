# 設定同期モジュール
# 複数デバイス間でのブラウザ設定の同期機能を提供します

import std/[
  os, 
  times, 
  strutils, 
  tables, 
  json, 
  options, 
  sequtils,
  sugar,
  asyncdispatch,
  httpclient,
  uri
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, files, encryption]
import ../../quantum_crypto/encryption as crypto_encrypt
import ./settings

type
  SyncStatus* = enum
    ## 同期ステータス
    ssIdle,          # アイドル状態
    ssSyncing,       # 同期中
    ssPaused,        # 一時停止
    ssError          # エラー発生
  
  SyncDirection* = enum
    ## 同期方向
    sdUpload,        # アップロード
    sdDownload,      # ダウンロード
    sdBoth           # 双方向

  SyncItem* = object
    ## 同期項目
    key*: string     # 設定キー
    localValue*: JsonNode  # ローカル値
    remoteValue*: JsonNode # リモート値
    timestamp*: DateTime   # タイムスタンプ
    conflicts*: bool  # 競合があるか
  
  SyncConfig* = object
    ## 同期設定
    enabled*: bool          # 有効/無効
    serverUrl*: string      # 同期サーバーURL
    userId*: string         # ユーザーID
    deviceId*: string       # デバイスID
    encryptionKey*: string  # 暗号化キー
    interval*: Duration     # 同期間隔
    lastSync*: DateTime     # 最終同期日時
    autoSync*: bool         # 自動同期の有効/無効
    
  SettingsSync* = ref object
    ## 設定同期オブジェクト
    settingsManager*: SettingsManager  # 設定マネージャ
    config*: SyncConfig      # 同期設定
    status*: SyncStatus      # 現在のステータス
    syncLog*: seq[string]    # 同期ログ
    httpClient*: AsyncHttpClient  # HTTPクライアント
    initialized*: bool       # 初期化済みフラグ

# ヘルパー関数
proc createAuthHeader(userId, deviceId, secret: string): HttpHeaders =
  ## 認証ヘッダーを作成
  let timestamp = $toUnix(now())
  let token = userId & ":" & deviceId & ":" & timestamp
  let signature = crypto_encrypt.hmacSha256(token, secret)
  
  result = newHttpHeaders({
    "X-Auth-User": userId,
    "X-Auth-Device": deviceId,
    "X-Auth-Timestamp": timestamp,
    "X-Auth-Signature": signature
  })

proc encryptPayload(data: JsonNode, key: string): string =
  ## ペイロードを暗号化
  let jsonStr = $data
  return crypto_encrypt.encryptString(jsonStr, key)

proc decryptPayload(encryptedData: string, key: string): JsonNode =
  ## 暗号化されたペイロードを復号
  let jsonStr = crypto_encrypt.decryptString(encryptedData, key)
  return parseJson(jsonStr)

# SettingsSyncの実装
proc newSettingsSync*(settingsManager: SettingsManager): SettingsSync =
  ## 新しい設定同期オブジェクトを作成
  let httpClient = newAsyncHttpClient()
  
  let config = SyncConfig(
    enabled: false,
    serverUrl: "",
    userId: "",
    deviceId: "",
    encryptionKey: "",
    interval: 30.minutes,
    lastSync: now() - 1.days,  # 初回実行時に必ず同期が走るようにする
    autoSync: false
  )
  
  result = SettingsSync(
    settingsManager: settingsManager,
    config: config,
    status: SyncStatus.ssIdle,
    syncLog: @[],
    httpClient: httpClient,
    initialized: true
  )
  
  info "Settings sync initialized"

proc loadConfig*(self: SettingsSync) =
  ## 設定マネージャから同期設定を読み込む
  if not self.initialized:
    error "Settings sync not initialized"
    return
  
  # 同期有効/無効
  self.config.enabled = self.settingsManager.getBool("sync.enabled", false)
  
  # サーバーURL
  self.config.serverUrl = self.settingsManager.getString("sync.server_url", "")
  
  # ユーザーID
  self.config.userId = self.settingsManager.getString("sync.user_id", "")
  
  # デバイスID
  let deviceId = self.settingsManager.getString("sync.device_id", "")
  if deviceId.len == 0:
    # 新しいデバイスIDを生成
    let newDeviceId = crypto_encrypt.generateRandomId(16)
    discard self.settingsManager.setString("sync.device_id", newDeviceId)
    self.config.deviceId = newDeviceId
  else:
    self.config.deviceId = deviceId
  
  # 暗号化キー
  self.config.encryptionKey = self.settingsManager.getString("sync.encryption_key", "")
  
  # 同期間隔（分）
  let intervalMinutes = self.settingsManager.getInt("sync.interval_minutes", 30)
  self.config.interval = intervalMinutes.minutes
  
  # 最終同期日時
  let lastSyncJson = self.settingsManager.getString("sync.last_sync", "")
  if lastSyncJson.len > 0:
    try:
      self.config.lastSync = parse(lastSyncJson, "yyyy-MM-dd'T'HH:mm:ss'Z'")
    except:
      self.config.lastSync = now() - 1.days
  
  # 自動同期
  self.config.autoSync = self.settingsManager.getBool("sync.auto_sync", false)
  
  # 同期が有効でも必要な設定が不足している場合は無効化
  if self.config.enabled and (self.config.serverUrl.len == 0 or 
                             self.config.userId.len == 0 or
                             self.config.encryptionKey.len == 0):
    self.config.enabled = false
    discard self.settingsManager.setBool("sync.enabled", false)
    error "Sync configuration incomplete, disabling sync"
  
  info "Sync config loaded", 
       enabled = self.config.enabled, 
       user_id = self.config.userId,
       server = self.config.serverUrl

proc saveConfig*(self: SettingsSync) =
  ## 同期設定を保存
  discard self.settingsManager.setBool("sync.enabled", self.config.enabled)
  discard self.settingsManager.setString("sync.server_url", self.config.serverUrl)
  discard self.settingsManager.setString("sync.user_id", self.config.userId)
  discard self.settingsManager.setString("sync.device_id", self.config.deviceId)
  discard self.settingsManager.setString("sync.encryption_key", self.config.encryptionKey)
  discard self.settingsManager.setInt("sync.interval_minutes", int(self.config.interval.inMinutes))
  discard self.settingsManager.setString("sync.last_sync", 
    self.config.lastSync.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  discard self.settingsManager.setBool("sync.auto_sync", self.config.autoSync)
  
  info "Sync config saved", enabled = self.config.enabled

proc setCredentials*(self: SettingsSync, userId: string, encryptionKey: string) =
  ## 同期認証情報を設定
  self.config.userId = userId
  self.config.encryptionKey = encryptionKey
  
  # 新しいデバイスIDを生成（必要に応じて）
  if self.config.deviceId.len == 0:
    self.config.deviceId = crypto_encrypt.generateRandomId(16)
  
  self.saveConfig()
  info "Sync credentials updated", user_id = userId

proc setServerUrl*(self: SettingsSync, url: string) =
  ## 同期サーバーURLを設定
  self.config.serverUrl = url
  self.saveConfig()
  info "Sync server URL updated", url = url

proc setEnabled*(self: SettingsSync, enabled: bool) =
  ## 同期の有効/無効を設定
  # 必要な設定が揃っているか確認
  if enabled and (self.config.serverUrl.len == 0 or 
                self.config.userId.len == 0 or
                self.config.encryptionKey.len == 0):
    error "Cannot enable sync: missing configuration"
    return
  
  self.config.enabled = enabled
  self.saveConfig()
  info "Sync enabled state updated", enabled = enabled

proc logSyncEvent(self: SettingsSync, message: string) =
  ## 同期イベントをログに記録
  let timestampedMessage = now().format("yyyy-MM-dd HH:mm:ss") & " - " & message
  self.syncLog.add(timestampedMessage)
  
  # ログが大きくなりすぎないよう制限
  if self.syncLog.len > 100:
    self.syncLog = self.syncLog[^100..^1]
  
  info "Sync event", message = message

proc getSyncableSettingsJson*(self: SettingsSync): JsonNode =
  ## 同期可能な設定をJSON形式で取得
  let syncableSettings = self.settingsManager.getSyncableSettings()
  var settingsObj = newJObject()
  
  for setting in syncableSettings:
    settingsObj[setting.key] = %*{
      "value": valueToJson(setting.currentValue),
      "timestamp": setting.lastModified.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
  
  result = %*{
    "device_id": self.config.deviceId,
    "timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "settings": settingsObj
  }

proc uploadSettings*(self: SettingsSync): Future[bool] {.async.} =
  ## 設定をサーバーにアップロード
  if not self.initialized or not self.config.enabled:
    return false
  
  self.status = SyncStatus.ssSyncing
  self.logSyncEvent("設定アップロード開始")
  
  try:
    # 同期可能な設定を取得
    let syncData = self.getSyncableSettingsJson()
    
    # ペイロードを暗号化
    let encryptedData = encryptPayload(syncData, self.config.encryptionKey)
    
    # 認証ヘッダー作成
    let headers = createAuthHeader(
      self.config.userId, 
      self.config.deviceId, 
      self.config.encryptionKey
    )
    
    # サーバーにアップロード
    let response = await self.httpClient.request(
      url = self.config.serverUrl & "/api/sync/upload",
      httpMethod = HttpPost,
      body = encryptedData,
      headers = headers
    )
    
    if response.code != Http200:
      let errorMsg = await response.body
      self.logSyncEvent("アップロード失敗: " & $response.code & " - " & errorMsg)
      self.status = SyncStatus.ssError
      return false
    
    # アップロード成功
    self.config.lastSync = now()
    self.saveConfig()
    self.logSyncEvent("設定アップロード完了")
    self.status = SyncStatus.ssIdle
    return true
    
  except:
    let errorMsg = getCurrentExceptionMsg()
    self.logSyncEvent("アップロードエラー: " & errorMsg)
    self.status = SyncStatus.ssError
    error "Settings upload failed", error = errorMsg
    return false

proc downloadSettings*(self: SettingsSync): Future[bool] {.async.} =
  ## サーバーから設定をダウンロード
  if not self.initialized or not self.config.enabled:
    return false
  
  self.status = SyncStatus.ssSyncing
  self.logSyncEvent("設定ダウンロード開始")
  
  try:
    # 認証ヘッダー作成
    let headers = createAuthHeader(
      self.config.userId, 
      self.config.deviceId, 
      self.config.encryptionKey
    )
    
    # サーバーからダウンロード
    let response = await self.httpClient.request(
      url = self.config.serverUrl & "/api/sync/download",
      httpMethod = HttpGet,
      headers = headers
    )
    
    if response.code != Http200:
      let errorMsg = await response.body
      self.logSyncEvent("ダウンロード失敗: " & $response.code & " - " & errorMsg)
      self.status = SyncStatus.ssError
      return false
    
    # レスポンスデータを取得
    let encryptedData = await response.body
    
    # データを復号
    let syncData = decryptPayload(encryptedData, self.config.encryptionKey)
    
    if not syncData.hasKey("settings"):
      self.logSyncEvent("無効な同期データ: settings キーがありません")
      self.status = SyncStatus.ssError
      return false
    
    # 設定を適用
    let settingsObj = syncData["settings"]
    var appliedCount = 0
    
    for key, valueObj in settingsObj:
      # 設定値を取得
      let value = valueObj["value"]
      let timestamp = parse(valueObj["timestamp"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
      
      # ローカル設定を取得
      let localSetting = self.settingsManager.getSetting(key)
      
      # タイムスタンプを比較して、より新しい方を適用
      if localSetting.isNone or localSetting.get().lastModified < timestamp:
        # 読み取り専用ではない設定のみ更新
        if localSetting.isNone or sfReadOnly notin localSetting.get().flags:
          # 型に応じて適切なメソッドで設定を更新
          if localSetting.isSome:
            let settingType = localSetting.get().valueType
            case settingType:
              of stBool:
                discard self.settingsManager.setBool(key, value.getBool())
              of stInt:
                discard self.settingsManager.setInt(key, value.getInt())
              of stFloat:
                discard self.settingsManager.setFloat(key, value.getFloat())
              of stString:
                discard self.settingsManager.setString(key, value.getStr())
              of stJson:
                discard self.settingsManager.setJson(key, value)
              of stBinary:
                # バイナリは通常同期しない
                discard
          else:
            # 新規設定の場合は型を推測
            if value.kind == JBool:
              discard self.settingsManager.setBool(key, value.getBool())
            elif value.kind == JInt:
              discard self.settingsManager.setInt(key, value.getInt())
            elif value.kind == JFloat:
              discard self.settingsManager.setFloat(key, value.getFloat())
            elif value.kind == JString:
              discard self.settingsManager.setString(key, value.getStr())
            elif value.kind == JObject or value.kind == JArray:
              discard self.settingsManager.setJson(key, value)
          
          appliedCount += 1
    
    # ダウンロード成功
    self.config.lastSync = now()
    self.saveConfig()
    self.logSyncEvent("設定ダウンロード完了: " & $appliedCount & "件の設定を更新")
    self.status = SyncStatus.ssIdle
    return true
    
  except:
    let errorMsg = getCurrentExceptionMsg()
    self.logSyncEvent("ダウンロードエラー: " & errorMsg)
    self.status = SyncStatus.ssError
    error "Settings download failed", error = errorMsg
    return false

proc syncSettings*(self: SettingsSync, direction: SyncDirection = SyncDirection.sdBoth): Future[bool] {.async.} =
  ## 設定を同期（アップロードとダウンロード）
  if not self.initialized or not self.config.enabled:
    return false
  
  self.status = SyncStatus.ssSyncing
  self.logSyncEvent("同期開始 - 方向: " & $direction)
  
  var success = true
  
  try:
    # 指定された方向に基づいて同期
    case direction:
      of SyncDirection.sdUpload:
        success = await self.uploadSettings()
        
      of SyncDirection.sdDownload:
        success = await self.downloadSettings()
        
      of SyncDirection.sdBoth:
        # 双方向同期の場合は、まずダウンロードしてからアップロード
        let downloadSuccess = await self.downloadSettings()
        if downloadSuccess:
          let uploadSuccess = await self.uploadSettings()
          success = uploadSuccess
        else:
          success = false
    
    if success:
      self.config.lastSync = now()
      self.saveConfig()
      self.logSyncEvent("同期完了")
      self.status = SyncStatus.ssIdle
    else:
      self.logSyncEvent("同期エラー")
      self.status = SyncStatus.ssError
    
    return success
    
  except:
    let errorMsg = getCurrentExceptionMsg()
    self.logSyncEvent("同期エラー: " & errorMsg)
    self.status = SyncStatus.ssError
    error "Settings sync failed", error = errorMsg
    return false

proc autoSyncTask*(self: SettingsSync) {.async.} =
  ## 自動同期タスク
  while true:
    await sleepAsync(1.minutes.inMilliseconds.int)
    
    if self.config.enabled and self.config.autoSync and 
       self.status != SyncStatus.ssSyncing and
       self.status != SyncStatus.ssPaused:
      
      # 前回の同期から設定間隔以上経過しているか確認
      let timeSinceLastSync = now() - self.config.lastSync
      if timeSinceLastSync >= self.config.interval:
        info "Auto-sync triggered"
        discard await self.syncSettings()

proc resolveSyncConflicts*(self: SettingsSync, resolution: Table[string, JsonNode]) =
  ## 同期の競合を解決
  if not self.initialized:
    return
  
  for key, value in resolution:
    # 設定を更新
    let setting = self.settingsManager.getSetting(key)
    if setting.isSome:
      let settingType = setting.get().valueType
      case settingType:
        of stBool:
          discard self.settingsManager.setBool(key, value.getBool())
        of stInt:
          discard self.settingsManager.setInt(key, value.getInt())
        of stFloat:
          discard self.settingsManager.setFloat(key, value.getFloat())
        of stString:
          discard self.settingsManager.setString(key, value.getStr())
        of stJson:
          discard self.settingsManager.setJson(key, value)
        of stBinary:
          # バイナリは通常同期しない
          discard
  
  self.logSyncEvent("競合解決: " & $resolution.len & "件の設定を更新")

proc getSyncLog*(self: SettingsSync): seq[string] =
  ## 同期ログを取得
  return self.syncLog

proc getSyncStatus*(self: SettingsSync): SyncStatus =
  ## 現在の同期ステータスを取得
  return self.status

proc resetSync*(self: SettingsSync) =
  ## 同期設定をリセット
  self.config.enabled = false
  self.config.userId = ""
  self.config.encryptionKey = ""
  self.config.lastSync = now() - 1.days
  self.status = SyncStatus.ssIdle
  self.syncLog = @[]
  
  self.saveConfig()
  self.logSyncEvent("同期設定をリセット")
  
  info "Sync reset"

proc close*(self: SettingsSync) =
  ## 同期オブジェクトを閉じる
  if not self.initialized:
    return
  
  self.httpClient.close()
  self.initialized = false
  info "Settings sync closed"

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testSettingsSync() {.async.} =
    # テンポラリデータベースを使用
    let dbPath = ":memory:"  # インメモリDBを使用
    
    # DB接続
    let db = open(dbPath, "", "", "")
    
    # 設定マネージャ作成
    let settingsManager = newSettingsManager(db, false, "")
    await settingsManager.initialize()
    
    # 同期オブジェクト作成
    let sync = newSettingsSync(settingsManager)
    
    # テスト用の同期設定
    sync.setServerUrl("https://example.com/sync")
    sync.setCredentials("test_user_123", "test_encryption_key")
    
    # 同期有効化（通常はここでエラーになるが、テスト用にmock responseを使用する場合）
    sync.setEnabled(true)
    
    # 設定内容を出力
    echo "Sync config:"
    echo "  Enabled: ", sync.config.enabled
    echo "  Server URL: ", sync.config.serverUrl
    echo "  User ID: ", sync.config.userId
    echo "  Device ID: ", sync.config.deviceId
    echo "  Last sync: ", sync.config.lastSync
    
    # 同期可能な設定の出力
    let syncableSettings = settingsManager.getSyncableSettings()
    echo "Syncable settings: ", syncableSettings.len
    
    # 同期JSONデータの出力
    let syncJson = sync.getSyncableSettingsJson()
    echo "Sync JSON: ", syncJson.pretty
    
    # リセット
    sync.resetSync()
    echo "After reset - Enabled: ", sync.config.enabled
    
    # クリーンアップ
    sync.close()
    await settingsManager.close()
    close(db)
  
  # テスト実行
  waitFor testSettingsSync() 