## Quantum Storage
## 
## ブラウザのデータ保存システム。ブックマーク、履歴、Cookie、キャッシュ、
## 設定などのデータを安全かつ効率的に管理します。

import std/[os, times, options, strutils, tables]
import std/[asyncdispatch, json, logging]
import db_sqlite

# サブモジュールのインポート
import quantum_storage/bookmarks/manager as bookmarks_manager
import quantum_storage/cache/manager as cache_manager
import quantum_storage/cookies/store as cookies_store
import quantum_storage/cookies/policy as cookies_policy
import quantum_storage/history/store as history_store
import quantum_storage/preferences/manager as preferences_manager

# 定数
const
  DATABASE_VERSION* = 1
  DATABASE_FILENAME* = "quantum_browser.db"

# 型定義
type
  StorageManager* = ref object
    dbPath*: string
    db*: DbConn
    isInitialized*: bool
    logger*: Logger
    
    # 各サブシステムのマネージャー
    bookmarksManager*: bookmarks_manager.BookmarksManager
    cacheManager*: cache_manager.CacheManager
    cookiesStore*: cookies_store.CookieStore
    cookiesPolicy*: cookies_policy.CookiePolicy
    historyStore*: history_store.HistoryStore
    preferencesManager*: preferences_manager.PreferencesManager

proc newStorageManager*(dataDir: string, logger: Logger = nil): StorageManager =
  ## 新しいストレージマネージャーを作成する
  result = StorageManager(
    dbPath: dataDir / DATABASE_FILENAME,
    isInitialized: false,
    logger: if logger == nil: newConsoleLogger() else: logger
  )
  
  # データディレクトリが存在することを確認
  if not dirExists(dataDir):
    createDir(dataDir)
    result.logger.log(lvlInfo, "Created data directory: " & dataDir)

proc initialize*(self: StorageManager) {.async.} =
  ## ストレージマネージャーを初期化する
  if self.isInitialized:
    return
  
  try:
    # データベース接続を開く
    self.db = open(self.dbPath, "", "", "")
    
    # 各サブシステムを初期化
    self.bookmarksManager = bookmarks_manager.newBookmarksManager(self.db, self.logger)
    await self.bookmarksManager.initialize()
    
    self.cacheManager = cache_manager.newCacheManager(self.db, self.logger)
    await self.cacheManager.initialize()
    
    self.cookiesStore = cookies_store.newCookieStore(self.db, self.logger)
    await self.cookiesStore.initialize()
    
    self.cookiesPolicy = cookies_policy.newCookiePolicy(self.logger)
    
    self.historyStore = history_store.newHistoryStore(self.db, self.logger)
    await self.historyStore.initialize()
    
    self.preferencesManager = preferences_manager.newPreferencesManager(self.db, self.logger)
    await self.preferencesManager.initialize()
    
    self.isInitialized = true
    self.logger.log(lvlInfo, "Storage manager initialized successfully")
    
  except:
    let e = getCurrentException()
    self.logger.log(lvlError, "Failed to initialize storage manager: " & e.msg)
    raise e

proc close*(self: StorageManager) {.async.} =
  ## ストレージマネージャーを閉じる
  if not self.isInitialized:
    return
  
  try:
    # 各サブシステムを閉じる
    await self.bookmarksManager.close()
    await self.cacheManager.close()
    await self.cookiesStore.close()
    await self.historyStore.close()
    await self.preferencesManager.close()
    
    # データベース接続を閉じる
    self.db.close()
    self.isInitialized = false
    self.logger.log(lvlInfo, "Storage manager closed successfully")
    
  except:
    let e = getCurrentException()
    self.logger.log(lvlError, "Failed to close storage manager: " & e.msg)
    raise e

proc clearAllData*(self: StorageManager) {.async.} =
  ## すべてのストレージデータをクリアする
  if not self.isInitialized:
    raise newException(IOError, "Storage manager not initialized")
  
  try:
    await self.bookmarksManager.clearAllData()
    await self.cacheManager.clearAllData()
    await self.cookiesStore.clearAllData()
    await self.historyStore.clearAllData()
    await self.preferencesManager.clearAllData()
    
    self.logger.log(lvlInfo, "All storage data cleared successfully")
    
  except:
    let e = getCurrentException()
    self.logger.log(lvlError, "Failed to clear all storage data: " & e.msg)
    raise e

proc exportData*(self: StorageManager, exportDir: string): Future[string] {.async.} =
  ## すべてのストレージデータをエクスポートする
  if not self.isInitialized:
    raise newException(IOError, "Storage manager not initialized")
  
  let timestamp = format(now(), "yyyy-MM-dd-HH-mm-ss")
  let exportPath = exportDir / "quantum_browser_export_" & timestamp
  
  try:
    # エクスポートディレクトリが存在することを確認
    if not dirExists(exportDir):
      createDir(exportDir)
    
    createDir(exportPath)
    
    # 各サブシステムのデータをエクスポート
    await self.bookmarksManager.exportData(exportPath / "bookmarks")
    await self.cacheManager.exportData(exportPath / "cache")
    await self.cookiesStore.exportData(exportPath / "cookies")
    await self.historyStore.exportData(exportPath / "history")
    await self.preferencesManager.exportData(exportPath / "preferences")
    
    self.logger.log(lvlInfo, "All storage data exported successfully to: " & exportPath)
    return exportPath
    
  except:
    let e = getCurrentException()
    self.logger.log(lvlError, "Failed to export storage data: " & e.msg)
    raise e

proc importData*(self: StorageManager, importPath: string) {.async.} =
  ## エクスポートされたデータをインポートする
  if not self.isInitialized:
    raise newException(IOError, "Storage manager not initialized")
  
  try:
    # インポートパスが存在することを確認
    if not dirExists(importPath):
      raise newException(IOError, "Import path does not exist: " & importPath)
    
    # 各サブシステムのデータをインポート
    if dirExists(importPath / "bookmarks"):
      await self.bookmarksManager.importData(importPath / "bookmarks")
    
    if dirExists(importPath / "cache"):
      await self.cacheManager.importData(importPath / "cache")
    
    if dirExists(importPath / "cookies"):
      await self.cookiesStore.importData(importPath / "cookies")
    
    if dirExists(importPath / "history"):
      await self.historyStore.importData(importPath / "history")
    
    if dirExists(importPath / "preferences"):
      await self.preferencesManager.importData(importPath / "preferences")
    
    self.logger.log(lvlInfo, "All storage data imported successfully from: " & importPath)
    
  except:
    let e = getCurrentException()
    self.logger.log(lvlError, "Failed to import storage data: " & e.msg)
    raise e

# ユーティリティ関数
proc getVersionInfo*(self: StorageManager): JsonNode =
  ## ストレージシステムのバージョン情報を取得する
  result = %* {
    "database_version": DATABASE_VERSION,
    "database_path": self.dbPath,
    "initialized": self.isInitialized,
    "subsystems": {
      "bookmarks": self.bookmarksManager.getVersionInfo(),
      "cache": self.cacheManager.getVersionInfo(),
      "cookies": self.cookiesStore.getVersionInfo(),
      "history": self.historyStore.getVersionInfo(),
      "preferences": self.preferencesManager.getVersionInfo()
    }
  } 