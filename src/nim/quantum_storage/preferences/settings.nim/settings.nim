# 設定管理モジュール
# ブラウザの各種設定の保存と管理を行います

import std/[
  os, 
  times, 
  strutils, 
  strformat, 
  tables, 
  json, 
  options, 
  sequtils,
  sugar,
  db_sqlite,
  asyncdispatch,
  sets
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, files, encryption]
import ../../quantum_crypto/encryption as crypto_encrypt

type
  SettingCategory* = enum
    ## 設定カテゴリ
    scGeneral,         # 一般設定
    scAppearance,      # 外観
    scPrivacy,         # プライバシー
    scSecurity,        # セキュリティ
    scDownloads,       # ダウンロード
    scSearch,          # 検索
    scStartup,         # 起動
    scAdvanced,        # 詳細設定
    scExtensions,      # 拡張機能
    scSync,            # 同期
    scAccessibility,   # アクセシビリティ
    scDeveloper        # 開発者

  SettingType* = enum
    ## 設定値の型
    stBool,            # 真偽値
    stInt,             # 整数
    stFloat,           # 浮動小数点
    stString,          # 文字列
    stJson,            # JSON
    stBinary           # バイナリデータ

  SettingFlags* = enum
    ## 設定フラグ
    sfEncrypted,       # 暗号化する
    sfSyncable,        # 同期可能
    sfReadOnly,        # 読み取り専用
    sfHidden,          # UI非表示
    sfRequiresRestart, # 再起動が必要
    sfDeprecated       # 非推奨

  SettingValue* = object
    ## 設定値
    case valueType*: SettingType
    of stBool:
      boolValue*: bool
    of stInt:
      intValue*: int
    of stFloat:
      floatValue*: float
    of stString:
      stringValue*: string
    of stJson:
      jsonValue*: JsonNode
    of stBinary:
      binaryValue*: seq[byte]

  Setting* = object
    ## 設定項目
    key*: string                # 設定キー
    name*: string               # 表示名
    description*: string        # 説明
    category*: SettingCategory  # カテゴリ
    defaultValue*: SettingValue # デフォルト値
    currentValue*: SettingValue # 現在の値
    valueType*: SettingType     # 値の型
    flags*: set[SettingFlags]   # フラグ
    lastModified*: DateTime     # 最終更新日時

  SettingsManager* = ref object
    ## 設定マネージャ
    db*: DbConn                 # データベース接続
    encryptionEnabled*: bool    # 暗号化の有効/無効
    encryptionKey*: string      # 暗号化キー
    settings*: Table[string, Setting]  # 設定テーブル
    changeCallbacks*: Table[string, seq[proc(key: string, value: SettingValue)]]  # 変更通知コールバック
    initialized*: bool          # 初期化済みフラグ

const
  DB_VERSION = 1                # データベースバージョン
  
# ヘルパー関数
proc valueToJson(value: SettingValue): JsonNode =
  ## 設定値をJSONに変換
  case value.valueType:
    of stBool:
      result = %* value.boolValue
    of stInt:
      result = %* value.intValue
    of stFloat:
      result = %* value.floatValue
    of stString:
      result = %* value.stringValue
    of stJson:
      result = value.jsonValue
    of stBinary:
      # バイナリデータはBase64エンコード
      result = %* base64.encode(value.binaryValue)

proc jsonToValue(json: JsonNode, valueType: SettingType): SettingValue =
  ## JSONから設定値に変換
  result.valueType = valueType
  
  case valueType:
    of stBool:
      result.boolValue = json.getBool()
    of stInt:
      result.intValue = json.getInt()
    of stFloat:
      result.floatValue = json.getFloat()
    of stString:
      result.stringValue = json.getStr()
    of stJson:
      result.jsonValue = json
    of stBinary:
      # Base64デコード
      result.binaryValue = base64.decode(json.getStr())

proc encryptValue(value: string, key: string): string =
  ## 値を暗号化
  try:
    result = crypto_encrypt.encryptString(value, key)
  except:
    error "Failed to encrypt value", error_msg = getCurrentExceptionMsg()
    result = value

proc decryptValue(encryptedValue: string, key: string): string =
  ## 暗号化された値を復号
  try:
    result = crypto_encrypt.decryptString(encryptedValue, key)
  except:
    error "Failed to decrypt value", error_msg = getCurrentExceptionMsg()
    result = encryptedValue

proc settingToJson*(setting: Setting): JsonNode =
  ## 設定項目をJSONに変換
  result = %*{
    "key": setting.key,
    "name": setting.name,
    "description": setting.description,
    "category": $setting.category,
    "valueType": $setting.valueType,
    "flags": @[],
    "value": valueToJson(setting.currentValue),
    "defaultValue": valueToJson(setting.defaultValue),
    "lastModified": setting.lastModified.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  }
  
  # フラグの追加
  var flagsArray = newJArray()
  for flag in SettingFlags:
    if flag in setting.flags:
      flagsArray.add(%* $flag)
  
  result["flags"] = flagsArray

proc settingFromJson*(json: JsonNode): Setting =
  ## JSONから設定項目に変換
  let valueType = parseEnum[SettingType](json["valueType"].getStr())
  
  var flags: set[SettingFlags] = {}
  for flagItem in json["flags"]:
    let flag = parseEnum[SettingFlags](flagItem.getStr())
    flags.incl(flag)
  
  result = Setting(
    key: json["key"].getStr(),
    name: json["name"].getStr(),
    description: json["description"].getStr(),
    category: parseEnum[SettingCategory](json["category"].getStr()),
    valueType: valueType,
    flags: flags,
    currentValue: jsonToValue(json["value"], valueType),
    defaultValue: jsonToValue(json["defaultValue"], valueType),
    lastModified: parse(json["lastModified"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'")
  )

proc createTables(self: SettingsManager) =
  ## データベースのテーブルを作成
  # 設定テーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT,
      category TEXT NOT NULL,
      value_type TEXT NOT NULL,
      value TEXT NOT NULL,
      flags TEXT NOT NULL,
      is_encrypted INTEGER DEFAULT 0,
      last_modified INTEGER NOT NULL
    )
  """)
  
  # デフォルト値テーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS default_settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  
  # メタデータテーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS settings_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  
  # バージョン情報設定
  self.db.exec(sql"INSERT OR REPLACE INTO settings_metadata (key, value) VALUES ('version', ?)",
    $DB_VERSION)

proc newSettingsManager*(db: DbConn, encryptionEnabled: bool = false, encryptionKey: string = ""): SettingsManager =
  ## 新しい設定マネージャを作成
  result = SettingsManager(
    db: db,
    encryptionEnabled: encryptionEnabled,
    encryptionKey: encryptionKey,
    settings: initTable[string, Setting](),
    changeCallbacks: initTable[string, seq[proc(key: string, value: SettingValue)]](),
    initialized: false
  )
  
  # テーブル作成
  result.createTables()
  
  result.initialized = true
  info "Settings manager initialized", 
       encryption = encryptionEnabled

proc loadSettings(self: SettingsManager) =
  ## 設定をデータベースから読み込み
  if not self.initialized:
    error "Settings manager not initialized"
    return
  
  # 設定をクリア
  self.settings.clear()
  
  try:
    # 全設定を取得
    let rows = self.db.getAllRows(sql"""
      SELECT key, name, description, category, value_type, value, flags, is_encrypted, last_modified
      FROM settings
    """)
    
    for row in rows:
      let 
        key = row[0]
        name = row[1]
        description = row[2]
        category = parseEnum[SettingCategory](row[3])
        valueType = parseEnum[SettingType](row[4])
        rawValue = row[5]
        flagsStr = row[6]
        isEncrypted = row[7] == "1"
        lastModified = fromUnix(parseInt(row[8]))
      
      # 値の復号化
      var valueStr = rawValue
      if isEncrypted and self.encryptionEnabled:
        valueStr = decryptValue(rawValue, self.encryptionKey)
      
      # 値の変換
      var value: JsonNode
      case valueType:
        of stBool:
          value = %* (valueStr == "true")
        of stInt:
          value = %* parseInt(valueStr)
        of stFloat:
          value = %* parseFloat(valueStr)
        of stString:
          value = %* valueStr
        of stJson:
          value = parseJson(valueStr)
        of stBinary:
          value = %* valueStr  # Base64エンコード済み
      
      # フラグの解析
      var flags: set[SettingFlags] = {}
      for flagStr in flagsStr.split(','):
        if flagStr.len > 0:
          flags.incl(parseEnum[SettingFlags](flagStr))
      
      # デフォルト値の取得
      let defaultRow = self.db.getRow(sql"SELECT value FROM default_settings WHERE key = ?", key)
      var defaultValue: JsonNode
      
      if defaultRow[0] != "":
        case valueType:
          of stBool:
            defaultValue = %* (defaultRow[0] == "true")
          of stInt:
            defaultValue = %* parseInt(defaultRow[0])
          of stFloat:
            defaultValue = %* parseFloat(defaultRow[0])
          of stString:
            defaultValue = %* defaultRow[0]
          of stJson:
            defaultValue = parseJson(defaultRow[0])
          of stBinary:
            defaultValue = %* defaultRow[0]
      else:
        # デフォルト値が無い場合は現在値と同じに
        defaultValue = value
      
      # 設定オブジェクト作成
      let setting = Setting(
        key: key,
        name: name,
        description: description,
        category: category,
        valueType: valueType,
        currentValue: jsonToValue(value, valueType),
        defaultValue: jsonToValue(defaultValue, valueType),
        flags: flags,
        lastModified: lastModified
      )
      
      self.settings[key] = setting
    
    info "Settings loaded", count = self.settings.len
    
  except:
    error "Failed to load settings", 
          error = getCurrentExceptionMsg() 

proc getSetting*(self: SettingsManager, key: string): Option[Setting] =
  ## 設定項目を取得
  if not self.initialized:
    error "Settings manager not initialized"
    return none(Setting)
  
  if self.settings.hasKey(key):
    return some(self.settings[key])
  else:
    return none(Setting)

proc getBool*(self: SettingsManager, key: string, defaultValue: bool = false): bool =
  ## 真偽値設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stBool:
    return setting.get().currentValue.boolValue
  else:
    return defaultValue

proc getInt*(self: SettingsManager, key: string, defaultValue: int = 0): int =
  ## 整数設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stInt:
    return setting.get().currentValue.intValue
  else:
    return defaultValue

proc getFloat*(self: SettingsManager, key: string, defaultValue: float = 0.0): float =
  ## 浮動小数点設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stFloat:
    return setting.get().currentValue.floatValue
  else:
    return defaultValue

proc getString*(self: SettingsManager, key: string, defaultValue: string = ""): string =
  ## 文字列設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stString:
    return setting.get().currentValue.stringValue
  else:
    return defaultValue

proc getJson*(self: SettingsManager, key: string, defaultValue: JsonNode = newJNull()): JsonNode =
  ## JSON設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stJson:
    return setting.get().currentValue.jsonValue
  else:
    return defaultValue

proc getBinary*(self: SettingsManager, key: string, defaultValue: seq[byte] = @[]): seq[byte] =
  ## バイナリデータ設定を取得
  let setting = self.getSetting(key)
  if setting.isSome and setting.get().valueType == stBinary:
    return setting.get().currentValue.binaryValue
  else:
    return defaultValue

proc getValue*(self: SettingsManager, key: string): Option[SettingValue] =
  ## 設定値を取得
  let setting = self.getSetting(key)
  if setting.isSome:
    return some(setting.get().currentValue)
  else:
    return none(SettingValue)

proc saveSetting(self: SettingsManager, setting: Setting) =
  ## 設定をデータベースに保存
  if not self.initialized:
    error "Settings manager not initialized"
    return
  
  # 値の文字列表現
  var valueStr = ""
  let isEncrypted = sfEncrypted in setting.flags
  
  case setting.valueType:
    of stBool:
      valueStr = if setting.currentValue.boolValue: "true" else: "false"
    of stInt:
      valueStr = $setting.currentValue.intValue
    of stFloat:
      valueStr = $setting.currentValue.floatValue
    of stString:
      valueStr = setting.currentValue.stringValue
    of stJson:
      valueStr = $setting.currentValue.jsonValue
    of stBinary:
      valueStr = base64.encode(setting.currentValue.binaryValue)
  
  # 暗号化
  if isEncrypted and self.encryptionEnabled:
    valueStr = encryptValue(valueStr, self.encryptionKey)
  
  # フラグの文字列化
  var flagsStr = ""
  for flag in SettingFlags:
    if flag in setting.flags:
      if flagsStr.len > 0:
        flagsStr &= ","
      flagsStr &= $flag
  
  # 最終更新日時
  let lastModified = now().toTime().toUnix()
  
  try:
    # トランザクション開始
    self.db.exec(sql"BEGIN TRANSACTION")
    
    # 設定保存
    self.db.exec(sql"""
      INSERT OR REPLACE INTO settings 
      (key, name, description, category, value_type, value, flags, is_encrypted, last_modified)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, 
      setting.key, setting.name, setting.description, $setting.category,
      $setting.valueType, valueStr, flagsStr, 
      if isEncrypted: "1" else: "0", $lastModified)
    
    # デフォルト値保存
    var defaultValueStr = ""
    case setting.valueType:
      of stBool:
        defaultValueStr = if setting.defaultValue.boolValue: "true" else: "false"
      of stInt:
        defaultValueStr = $setting.defaultValue.intValue
      of stFloat:
        defaultValueStr = $setting.defaultValue.floatValue
      of stString:
        defaultValueStr = setting.defaultValue.stringValue
      of stJson:
        defaultValueStr = $setting.defaultValue.jsonValue
      of stBinary:
        defaultValueStr = base64.encode(setting.defaultValue.binaryValue)
    
    self.db.exec(sql"INSERT OR REPLACE INTO default_settings (key, value) VALUES (?, ?)",
      setting.key, defaultValueStr)
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    # インメモリデータ更新
    var updatedSetting = setting
    updatedSetting.lastModified = fromUnix(lastModified)
    self.settings[setting.key] = updatedSetting
    
    info "Setting saved", key = setting.key, type = $setting.valueType
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to save setting", 
          key = setting.key, 
          error = getCurrentExceptionMsg()

proc registerSetting*(self: SettingsManager, 
                    key: string, 
                    name: string, 
                    description: string, 
                    category: SettingCategory,
                    defaultValue: SettingValue,
                    flags: set[SettingFlags] = {}): bool =
  ## 新しい設定を登録
  if not self.initialized:
    error "Settings manager not initialized"
    return false
  
  # 既存設定のチェック
  let existingSetting = self.getSetting(key)
  if existingSetting.isSome:
    # 既存設定がある場合はデフォルト値だけ更新
    var setting = existingSetting.get()
    setting.defaultValue = defaultValue
    
    # 名前/説明/カテゴリも更新
    if setting.name != name:
      setting.name = name
    if setting.description != description:
      setting.description = description
    if setting.category != category:
      setting.category = category
    
    self.saveSetting(setting)
    return true
  
  # 新しい設定作成
  let now = now()
  let setting = Setting(
    key: key,
    name: name,
    description: description,
    category: category,
    valueType: defaultValue.valueType,
    defaultValue: defaultValue,
    currentValue: defaultValue,  # 初期値はデフォルト値と同じ
    flags: flags,
    lastModified: now
  )
  
  self.saveSetting(setting)
  return true

proc setBool*(self: SettingsManager, key: string, value: bool): bool =
  ## 真偽値設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stBool:
      error "Type mismatch for setting", key = key, expected = "bool", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.boolValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,  # 一時的な名前
      description: "",
      category: scGeneral,  # デフォルトカテゴリ
      valueType: stBool,
      defaultValue: SettingValue(valueType: stBool, boolValue: value),
      currentValue: SettingValue(valueType: stBool, boolValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc setInt*(self: SettingsManager, key: string, value: int): bool =
  ## 整数設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stInt:
      error "Type mismatch for setting", key = key, expected = "int", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.intValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,
      description: "",
      category: scGeneral,
      valueType: stInt,
      defaultValue: SettingValue(valueType: stInt, intValue: value),
      currentValue: SettingValue(valueType: stInt, intValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc setFloat*(self: SettingsManager, key: string, value: float): bool =
  ## 浮動小数点設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stFloat:
      error "Type mismatch for setting", key = key, expected = "float", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.floatValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,
      description: "",
      category: scGeneral,
      valueType: stFloat,
      defaultValue: SettingValue(valueType: stFloat, floatValue: value),
      currentValue: SettingValue(valueType: stFloat, floatValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc setString*(self: SettingsManager, key: string, value: string): bool =
  ## 文字列設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stString:
      error "Type mismatch for setting", key = key, expected = "string", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.stringValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,
      description: "",
      category: scGeneral,
      valueType: stString,
      defaultValue: SettingValue(valueType: stString, stringValue: value),
      currentValue: SettingValue(valueType: stString, stringValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc setJson*(self: SettingsManager, key: string, value: JsonNode): bool =
  ## JSON設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stJson:
      error "Type mismatch for setting", key = key, expected = "json", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.jsonValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,
      description: "",
      category: scGeneral,
      valueType: stJson,
      defaultValue: SettingValue(valueType: stJson, jsonValue: value),
      currentValue: SettingValue(valueType: stJson, jsonValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc setBinary*(self: SettingsManager, key: string, value: seq[byte]): bool =
  ## バイナリ設定を設定
  # 既存設定のチェック
  var setting: Setting
  let existingSetting = self.getSetting(key)
  
  if existingSetting.isSome:
    setting = existingSetting.get()
    
    # 型チェック
    if setting.valueType != stBinary:
      error "Type mismatch for setting", key = key, expected = "binary", actual = $setting.valueType
      return false
    
    # 読み取り専用チェック
    if sfReadOnly in setting.flags:
      error "Cannot modify read-only setting", key = key
      return false
    
    # 値の更新
    setting.currentValue.binaryValue = value
  else:
    # 新規設定
    setting = Setting(
      key: key,
      name: key,
      description: "",
      category: scGeneral,
      valueType: stBinary,
      defaultValue: SettingValue(valueType: stBinary, binaryValue: value),
      currentValue: SettingValue(valueType: stBinary, binaryValue: value),
      flags: {},
      lastModified: now()
    )
  
  # 保存
  self.saveSetting(setting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, setting.currentValue)
  
  return true

proc deleteSetting*(self: SettingsManager, key: string): bool =
  ## 設定を削除
  if not self.initialized:
    error "Settings manager not initialized"
    return false
  
  if not self.settings.hasKey(key):
    return false
  
  try:
    # トランザクション開始
    self.db.exec(sql"BEGIN TRANSACTION")
    
    # 設定削除
    self.db.exec(sql"DELETE FROM settings WHERE key = ?", key)
    
    # デフォルト値削除
    self.db.exec(sql"DELETE FROM default_settings WHERE key = ?", key)
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    # インメモリデータからも削除
    self.settings.del(key)
    
    info "Setting deleted", key = key
    return true
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to delete setting", 
          key = key, 
          error = getCurrentExceptionMsg()
    return false

proc resetToDefault*(self: SettingsManager, key: string): bool =
  ## 設定をデフォルト値にリセット
  let setting = self.getSetting(key)
  if setting.isNone:
    return false
  
  var updatedSetting = setting.get()
  
  # 読み取り専用チェック
  if sfReadOnly in updatedSetting.flags:
    error "Cannot reset read-only setting", key = key
    return false
  
  # デフォルト値に戻す
  updatedSetting.currentValue = updatedSetting.defaultValue
  
  # 保存
  self.saveSetting(updatedSetting)
  
  # コールバック通知
  if self.changeCallbacks.hasKey(key):
    for callback in self.changeCallbacks[key]:
      callback(key, updatedSetting.currentValue)
  
  info "Setting reset to default", key = key
  return true

proc resetAllToDefaults*(self: SettingsManager): bool =
  ## すべての設定をデフォルト値にリセット
  if not self.initialized:
    error "Settings manager not initialized"
    return false
  
  var success = true
  for key, _ in self.settings:
    if not self.resetToDefault(key):
      success = false
  
  info "All settings reset to defaults"
  return success

proc addChangeCallback*(self: SettingsManager, key: string, callback: proc(key: string, value: SettingValue)) =
  ## 設定変更通知コールバックを追加
  if not self.changeCallbacks.hasKey(key):
    self.changeCallbacks[key] = @[]
  
  self.changeCallbacks[key].add(callback)

proc removeChangeCallback*(self: SettingsManager, key: string, callback: proc(key: string, value: SettingValue)) =
  ## 設定変更通知コールバックを削除
  if not self.changeCallbacks.hasKey(key):
    return
  
  let callbackAddr = cast[int](callback)
  var foundIdx = -1
  
  for i, cb in self.changeCallbacks[key]:
    if cast[int](cb) == callbackAddr:
      foundIdx = i
      break
  
  if foundIdx >= 0:
    self.changeCallbacks[key].delete(foundIdx) 

proc getSettingsByCategory*(self: SettingsManager, category: SettingCategory): seq[Setting] =
  ## カテゴリ別に設定を取得
  result = @[]
  
  for _, setting in self.settings.pairs:
    if setting.category == category:
      result.add(setting)
  
  # 名前順にソート
  result.sort(proc(a, b: Setting): int = cmp(a.name, b.name))

proc getSettingsJson*(self: SettingsManager): JsonNode =
  ## すべての設定をJSON形式で取得
  var settingsArray = newJArray()
  
  for _, setting in self.settings.pairs:
    # 非表示フラグがついている設定は除外
    if sfHidden notin setting.flags:
      settingsArray.add(settingToJson(setting))
  
  result = %* {
    "settings": settingsArray
  }

proc getSettingsJsonByCategory*(self: SettingsManager): JsonNode =
  ## カテゴリ別に設定をJSON形式で取得
  var categoriesObj = newJObject()
  
  # カテゴリごとに配列を初期化
  for category in SettingCategory:
    categoriesObj[$category] = newJArray()
  
  # 各設定をカテゴリ別に追加
  for _, setting in self.settings.pairs:
    # 非表示フラグがついている設定は除外
    if sfHidden notin setting.flags:
      let categoryStr = $setting.category
      categoriesObj[categoryStr].add(settingToJson(setting))
  
  result = %* {
    "categories": categoriesObj
  }

proc getSyncableSettings*(self: SettingsManager): seq[Setting] =
  ## 同期可能な設定を取得
  result = @[]
  
  for _, setting in self.settings.pairs:
    if sfSyncable in setting.flags:
      result.add(setting)

proc getChangedSettings*(self: SettingsManager, since: DateTime): seq[Setting] =
  ## 指定日時以降に変更された設定を取得
  result = @[]
  
  for _, setting in self.settings.pairs:
    if setting.lastModified > since:
      result.add(setting)

proc importFromJson*(self: SettingsManager, json: JsonNode): (int, int) =
  ## JSONから設定をインポート
  ## 戻り値は（更新された設定数、エラー数）
  
  var updatedCount = 0
  var errorCount = 0
  
  if not json.hasKey("settings"):
    return (0, 1)
  
  let settingsArray = json["settings"]
  if settingsArray.kind != JArray:
    return (0, 1)
  
  for settingJson in settingsArray:
    try:
      let setting = settingFromJson(settingJson)
      
      # 既存設定のチェック
      let existingSetting = self.getSetting(setting.key)
      
      if existingSetting.isSome:
        # 読み取り専用の設定は更新しない
        if sfReadOnly in existingSetting.get().flags:
          continue
          
        # 既存設定の更新
        var updatedSetting = existingSetting.get()
        updatedSetting.currentValue = setting.currentValue
        
        # 保存
        self.saveSetting(updatedSetting)
        
        # コールバック通知
        if self.changeCallbacks.hasKey(setting.key):
          for callback in self.changeCallbacks[setting.key]:
            callback(setting.key, updatedSetting.currentValue)
      else:
        # 新規設定として追加
        self.saveSetting(setting)
      
      updatedCount += 1
      
    except:
      error "Failed to import setting", 
            error = getCurrentExceptionMsg()
      errorCount += 1
  
  info "Settings imported from JSON", 
       updated = updatedCount, 
       errors = errorCount
       
  return (updatedCount, errorCount)

proc exportToFile*(self: SettingsManager, filePath: string): bool =
  ## 設定をファイルにエクスポート
  try:
    let json = self.getSettingsJson()
    writeFile(filePath, json.pretty)
    
    info "Settings exported to file", 
         file = filePath, 
         settings = self.settings.len
    return true
    
  except:
    error "Failed to export settings to file", 
          file = filePath, 
          error = getCurrentExceptionMsg()
    return false

proc importFromFile*(self: SettingsManager, filePath: string): (int, int) =
  ## ファイルから設定をインポート
  try:
    let jsonStr = readFile(filePath)
    let json = parseJson(jsonStr)
    
    return self.importFromJson(json)
    
  except:
    error "Failed to import settings from file", 
          file = filePath, 
          error = getCurrentExceptionMsg()
    return (0, 1)

# デフォルト設定の定義
proc createDefaultBoolSetting(key, name, description: string, category: SettingCategory, 
                             value: bool, flags: set[SettingFlags] = {}): Setting =
  result = Setting(
    key: key,
    name: name,
    description: description,
    category: category,
    valueType: stBool,
    defaultValue: SettingValue(valueType: stBool, boolValue: value),
    currentValue: SettingValue(valueType: stBool, boolValue: value),
    flags: flags,
    lastModified: now()
  )

proc createDefaultIntSetting(key, name, description: string, category: SettingCategory, 
                           value: int, flags: set[SettingFlags] = {}): Setting =
  result = Setting(
    key: key,
    name: name,
    description: description,
    category: category,
    valueType: stInt,
    defaultValue: SettingValue(valueType: stInt, intValue: value),
    currentValue: SettingValue(valueType: stInt, intValue: value),
    flags: flags,
    lastModified: now()
  )

proc createDefaultStringSetting(key, name, description: string, category: SettingCategory, 
                              value: string, flags: set[SettingFlags] = {}): Setting =
  result = Setting(
    key: key,
    name: name,
    description: description,
    category: category,
    valueType: stString,
    defaultValue: SettingValue(valueType: stString, stringValue: value),
    currentValue: SettingValue(valueType: stString, stringValue: value),
    flags: flags,
    lastModified: now()
  )

proc registerDefaultSettings*(self: SettingsManager) =
  ## デフォルト設定を登録
  # 一般設定
  self.saveSetting(createDefaultStringSetting(
    "general.locale", "言語", "ブラウザの表示言語", 
    scGeneral, "auto", {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "general.show_home_button", "ホームボタンを表示", "ツールバーにホームボタンを表示する", 
    scGeneral, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "general.restore_session", "前回のセッションを復元", "起動時に前回のタブを復元する", 
    scGeneral, true, {sfSyncable}))
  
  self.saveSetting(createDefaultStringSetting(
    "general.homepage", "ホームページ", "ホームボタンをクリックしたときに表示するページ", 
    scGeneral, "about:home", {sfSyncable}))
  
  self.saveSetting(createDefaultStringSetting(
    "general.startup_page", "起動時のページ", "ブラウザ起動時に表示するページ", 
    scGeneral, "about:home", {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "general.show_bookmarks_bar", "ブックマークバーを表示", "ブックマークバーを表示する", 
    scGeneral, true, {sfSyncable}))
  
  # 外観設定
  self.saveSetting(createDefaultStringSetting(
    "appearance.theme", "テーマ", "ブラウザのテーマ", 
    scAppearance, "system", {sfSyncable}))
  
  self.saveSetting(createDefaultIntSetting(
    "appearance.font_size", "フォントサイズ", "ページのデフォルトフォントサイズ", 
    scAppearance, 16, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "appearance.smooth_scrolling", "スムーススクロール", "スムーススクロールを有効にする", 
    scAppearance, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "appearance.animations", "アニメーション", "UIアニメーションを有効にする", 
    scAppearance, true, {sfSyncable}))
  
  self.saveSetting(createDefaultStringSetting(
    "appearance.tab_position", "タブの位置", "タブバーの位置", 
    scAppearance, "top", {sfSyncable}))
  
  # プライバシー設定
  self.saveSetting(createDefaultBoolSetting(
    "privacy.do_not_track", "トラッキング拒否", "Webサイトにトラッキング拒否を通知する", 
    scPrivacy, false, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "privacy.block_third_party_cookies", "サードパーティCookieをブロック", "サードパーティCookieをブロックする", 
    scPrivacy, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "privacy.clear_history_on_exit", "終了時に履歴を消去", "ブラウザ終了時に閲覧履歴を消去する", 
    scPrivacy, false, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "privacy.clear_cookies_on_exit", "終了時にCookieを消去", "ブラウザ終了時にCookieを消去する", 
    scPrivacy, false, {sfSyncable}))
  
  self.saveSetting(createDefaultIntSetting(
    "privacy.cookie_policy", "Cookieポリシー", "Cookieの受け入れポリシー", 
    scPrivacy, 1, {sfSyncable}))  # 0:すべて拒否, 1:セッションのみ, 2:すべて許可
  
  # セキュリティ設定
  self.saveSetting(createDefaultBoolSetting(
    "security.block_dangerous_downloads", "危険なダウンロードをブロック", "潜在的に危険なファイルのダウンロードをブロックする", 
    scSecurity, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "security.safe_browsing", "セーフブラウジング", "フィッシングサイトや不正サイトを警告する", 
    scSecurity, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "security.webrtc_ip_handling_policy", "WebRTCのIPアドレス処理", "WebRTCのIPアドレス処理ポリシー", 
    scSecurity, true, {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "security.https_only_mode", "HTTPSのみモード", "HTTPSのみのモードを有効にする", 
    scSecurity, false, {sfSyncable, sfRequiresRestart}))
  
  # ダウンロード設定
  self.saveSetting(createDefaultStringSetting(
    "downloads.location", "ダウンロード先", "ファイルのダウンロード先フォルダ", 
    scDownloads, getHomeDir() / "Downloads", {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "downloads.ask_before_download", "ダウンロード前に確認", "ダウンロード開始前に保存先を確認する", 
    scDownloads, true, {sfSyncable}))
  
  # 検索設定
  self.saveSetting(createDefaultStringSetting(
    "search.default_engine", "デフォルト検索エンジン", "デフォルトの検索エンジン", 
    scSearch, "google", {sfSyncable}))
  
  self.saveSetting(createDefaultBoolSetting(
    "search.show_suggestions", "検索候補を表示", "検索バーで検索候補を表示する", 
    scSearch, true, {sfSyncable}))
  
  # 同期設定
  self.saveSetting(createDefaultBoolSetting(
    "sync.enabled", "同期を有効にする", "ブラウザデータの同期を有効にする", 
    scSync, false, {sfSyncable}))
  
  self.saveSetting(createDefaultIntSetting(
    "sync.interval_minutes", "同期間隔", "自動同期の間隔（分）", 
    scSync, 30, {sfSyncable}))
  
  # アクセシビリティ設定
  self.saveSetting(createDefaultBoolSetting(
    "accessibility.high_contrast", "ハイコントラスト", "高コントラストモードを有効にする", 
    scAccessibility, false, {sfSyncable}))
  
  self.saveSetting(createDefaultIntSetting(
    "accessibility.minimum_font_size", "最小フォントサイズ", "ページの最小フォントサイズ", 
    scAccessibility, 0, {sfSyncable}))  # 0は制限なし
  
  # 詳細設定
  self.saveSetting(createDefaultBoolSetting(
    "advanced.hardware_acceleration", "ハードウェアアクセラレーション", "ハードウェアアクセラレーションを有効にする", 
    scAdvanced, true, {sfSyncable, sfRequiresRestart}))
  
  self.saveSetting(createDefaultBoolSetting(
    "advanced.developer_tools", "開発者ツール", "開発者ツールを有効にする", 
    scAdvanced, false, {sfSyncable}))

proc initialize*(self: SettingsManager) {.async.} =
  ## 設定マネージャを初期化
  if not self.initialized:
    error "Settings manager not initialized"
    return
  
  # 設定を読み込み
  self.loadSettings()
  
  # デフォルト設定を登録
  self.registerDefaultSettings()
  
  info "Settings manager initialized", settings_count = self.settings.len

proc close*(self: SettingsManager) {.async.} =
  ## 設定マネージャを閉じる
  if not self.initialized:
    return
  
  info "Settings manager closed"

proc getVersionInfo*(self: SettingsManager): JsonNode =
  ## バージョン情報を取得
  return %* {
    "version": DB_VERSION,
    "count": self.settings.len,
    "encryption": self.encryptionEnabled
  }

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testSettingsManager() {.async.} =
    # テンポラリデータベースを使用
    let dbPath = ":memory:"  # インメモリDBを使用
    
    # DB接続
    let db = open(dbPath, "", "", "")
    
    # 設定マネージャ作成
    let manager = newSettingsManager(db, false, "")
    
    # 初期化
    await manager.initialize()
    
    echo "登録済み設定数: ", manager.settings.len
    
    # 設定の取得と設定
    let homepageKey = "general.homepage"
    echo "ホームページ設定: ", manager.getString(homepageKey)
    
    discard manager.setString(homepageKey, "https://nim-lang.org")
    echo "ホームページ設定（変更後）: ", manager.getString(homepageKey)
    
    # 設定のリセット
    discard manager.resetToDefault(homepageKey)
    echo "ホームページ設定（リセット後）: ", manager.getString(homepageKey)
    
    # 新しい設定の追加
    let customKey = "test.custom_setting"
    discard manager.setString(customKey, "テスト値")
    echo "カスタム設定: ", manager.getString(customKey)
    
    # JSONエクスポート
    let tempFile = getTempDir() / "settings_test.json"
    discard manager.exportToFile(tempFile)
    echo "設定をエクスポート: ", tempFile
    
    # 設定変更
    discard manager.setString(customKey, "新しいテスト値")
    
    # JSONインポート
    let (updated, errors) = manager.importFromFile(tempFile)
    echo "設定をインポート: 更新 = ", updated, ", エラー = ", errors
    
    # カテゴリ別設定の取得
    let generalSettings = manager.getSettingsByCategory(scGeneral)
    echo "一般設定の数: ", generalSettings.len
    
    # 変更済み設定の取得
    let changedSettings = manager.getChangedSettings(now() - 1.hours)
    echo "最近変更された設定の数: ", changedSettings.len
    
    # 同期可能な設定の取得
    let syncableSettings = manager.getSyncableSettings()
    echo "同期可能な設定の数: ", syncableSettings.len
    
    # コールバックテスト
    proc settingChanged(key: string, value: SettingValue) =
      echo "設定変更通知: ", key
    
    manager.addChangeCallback(homepageKey, settingChanged)
    discard manager.setString(homepageKey, "https://example.com")
    
    # クリーンアップ
    await manager.close()
    close(db)
    
    # テンポラリファイル削除
    removeFile(tempFile)
  
  # テスト実行
  waitFor testSettingsManager() 