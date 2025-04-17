# 履歴ストアモジュール
# ブラウザの閲覧履歴を管理します

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
  uri,
  hashes,
  algorithm,
  asyncdispatch
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, files, encryption]
import ../../quantum_crypto/encryption as crypto_encrypt
import ../common/base

type
  VisitType* = enum
    ## 訪問タイプ
    vtLink,         # リンクをクリック
    vtTyped,        # URLを直接入力
    vtBookmark,     # ブックマークから
    vtReload,       # リロード
    vtBackForward,  # 戻る/進む
    vtFormSubmit,   # フォーム送信
    vtAutoComplete, # オートコンプリート
    vtRedirect,     # リダイレクト
    vtStartPage,    # スタートページ
    vtOther         # その他

  PageVisit* = object
    ## ページ訪問情報
    id*: int64                  # 訪問ID
    pageId*: int64              # ページID
    visitTime*: DateTime        # 訪問日時
    visitType*: VisitType       # 訪問タイプ
    referringVisitId*: Option[int64] # 参照元の訪問ID
    transitionFlags*: int        # 遷移フラグ

  HistoryPage* = object
    ## 履歴ページ情報
    id*: int64                  # ページID
    url*: string                # URL
    title*: string              # タイトル
    lastVisitTime*: DateTime    # 最終訪問日時
    visitCount*: int            # 訪問回数
    typedCount*: int            # 直接入力回数
    hidden*: bool               # 非表示フラグ
    favicon*: string            # ファビコンURL
    visits*: seq[PageVisit]     # 訪問リスト

  SearchOptions* = object
    ## 検索オプション
    text*: string               # 検索テキスト
    startTime*: Option[DateTime] # 開始日時
    endTime*: Option[DateTime]  # 終了日時
    maxResults*: int            # 最大結果数
    orderByTime*: bool          # 時間順ソート
    onlyTyped*: bool            # 直接入力のみ
    includeHidden*: bool        # 非表示項目も含める
    domain*: string             # ドメイン指定

  StorageOptions* = object
    ## ストレージオプション
    encryptionEnabled*: bool    # 暗号化の有効/無効
    encryptionKey*: string      # 暗号化キー
    autoCleanupEnabled*: bool   # 自動クリーンアップの有効/無効
    retentionDays*: int         # 保持期間（日）
    syncEnabled*: bool          # 同期の有効/無効

  HistoryStore* = ref object
    ## 履歴ストア
    db*: DbConn                 # データベース接続
    options*: StorageOptions    # ストレージオプション
    initialized*: bool          # 初期化済みフラグ

const
  DB_FILE_NAME = "history.db"   # データベースファイル名
  DB_VERSION = 1                # データベースバージョン
  
  DEFAULT_RETENTION_DAYS = 90   # デフォルト保持期間（日）
  DEFAULT_MAX_RESULTS = 100     # デフォルト最大結果数
  
  # 遷移フラグ
  TRANSITION_FORWARD_BACK = 1   # 前/後ボタン
  TRANSITION_FROM_ADDRESS_BAR = 2 # アドレスバーから
  TRANSITION_HOME_PAGE = 4      # ホームページ
  TRANSITION_FROM_LINK = 8      # リンクから
  TRANSITION_FORM_SUBMIT = 16   # フォーム送信
  TRANSITION_RELOAD = 32        # リロード
  TRANSITION_CHAIN_START = 64   # 遷移チェーン開始
  TRANSITION_CHAIN_END = 128    # 遷移チェーン終了

# ヘルパー関数
proc hashUrl(url: string): string =
  ## URLのハッシュ値を計算
  return getMD5(url)

proc sanitizeUrl(url: string): string =
  ## URLをサニタイズ
  # URLをキャノニカライズするため、URI解析して再構築
  try:
    let parsedUri = parseUri(url)
    result = $parsedUri
    
    # fragmentを除去（オプション）
    # result = parsedUri.scheme & "://" & parsedUri.hostname & parsedUri.port & parsedUri.path & 
    #         (if parsedUri.query.len > 0: "?" & parsedUri.query else: "")
  except:
    # 解析に失敗した場合は元のURLを使用
    result = url

proc encryptString(text, key: string): string =
  ## 文字列を暗号化
  try:
    result = crypto_encrypt.encryptString(text, key)
  except:
    error "Failed to encrypt string", error_msg = getCurrentExceptionMsg()
    result = text

proc decryptString(encryptedText, key: string): string =
  ## 暗号化された文字列を復号
  try:
    result = crypto_encrypt.decryptString(encryptedText, key)
  except:
    error "Failed to decrypt string", error_msg = getCurrentExceptionMsg()
    result = encryptedText

proc rowToHistoryPage(row: seq[string], decryptionKey: string, includeVisits: bool = false): HistoryPage =
  ## DBレコードからHistoryPageオブジェクトを作成
  result = HistoryPage(
    id: parseInt(row[0]).int64,
    url: if row[1].len > 0: decryptString(row[1], decryptionKey) else: "",
    title: if row[2].len > 0: decryptString(row[2], decryptionKey) else: "",
    lastVisitTime: fromUnix(parseInt(row[3])),
    visitCount: parseInt(row[4]),
    typedCount: parseInt(row[5]),
    hidden: row[6] == "1",
    favicon: row[7],
    visits: @[]
  )

proc rowToPageVisit(row: seq[string]): PageVisit =
  ## DBレコードからPageVisitオブジェクトを作成
  result = PageVisit(
    id: parseInt(row[0]).int64,
    pageId: parseInt(row[1]).int64,
    visitTime: fromUnix(parseInt(row[2])),
    visitType: parseEnum[VisitType](row[3]),
    transitionFlags: parseInt(row[4])
  )
  
  if row[5] != "":
    result.referringVisitId = some(parseInt(row[5]).int64)

# HistoryStoreの実装
proc createTables(self: HistoryStore) =
  ## データベースのテーブルを作成
  # ページテーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS pages (
      id INTEGER PRIMARY KEY,
      url TEXT NOT NULL,
      url_hash TEXT NOT NULL,
      title TEXT,
      last_visit_time INTEGER NOT NULL,
      visit_count INTEGER DEFAULT 0,
      typed_count INTEGER DEFAULT 0,
      hidden INTEGER DEFAULT 0,
      favicon TEXT,
      is_encrypted INTEGER DEFAULT 0
    )
  """)
  
  # 訪問テーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS visits (
      id INTEGER PRIMARY KEY,
      page_id INTEGER NOT NULL,
      visit_time INTEGER NOT NULL,
      visit_type TEXT NOT NULL,
      transition_flags INTEGER DEFAULT 0,
      referring_visit_id INTEGER,
      FOREIGN KEY (page_id) REFERENCES pages (id) ON DELETE CASCADE
    )
  """)
  
  # インデックス作成
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_pages_url_hash ON pages(url_hash)")
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_pages_last_visit ON pages(last_visit_time)")
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_visits_page_id ON visits(page_id)")
  self.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_visits_time ON visits(visit_time)")
  
  # メタデータテーブル
  self.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  
  # バージョン情報設定
  self.db.exec(sql"INSERT OR REPLACE INTO metadata (key, value) VALUES ('version', ?)",
    $DB_VERSION)

proc newHistoryStore*(dbPath: string = "", options: StorageOptions = StorageOptions()): HistoryStore =
  ## 新しい履歴ストアを作成
  # デフォルト値を設定
  var opts = options
  if opts.retentionDays == 0:
    opts.retentionDays = DEFAULT_RETENTION_DAYS
  
  # 暗号化設定の確認
  if opts.encryptionEnabled and opts.encryptionKey.len == 0:
    warn "Encryption enabled but no key provided. Disabling encryption."
    opts.encryptionEnabled = false
  
  # データベースパスの設定
  let finalDbPath = if dbPath.len > 0: dbPath 
                    else: getAppDir() / DB_FILE_NAME
  
  result = HistoryStore(
    db: open(finalDbPath, "", "", ""),
    options: opts,
    initialized: false
  )
  
  # テーブル作成
  result.createTables()
  
  # プラグマ設定
  result.db.exec(sql"PRAGMA foreign_keys = ON")
  
  result.initialized = true
  info "History store initialized", db_path = finalDbPath, encryption = opts.encryptionEnabled

proc close*(self: HistoryStore) =
  ## 履歴ストアを閉じる
  if self.db != nil:
    close(self.db)
    self.initialized = false
    info "History store closed"

proc addPageVisit*(self: HistoryStore, url: string, title: string, 
                  visitType: VisitType = VisitType.vtLink,
                  referringVisitId: Option[int64] = none(int64),
                  transitionFlags: int = 0,
                  visitTime: DateTime = now()): (int64, int64) =
  ## 訪問を追加し、(pageId, visitId)のタプルを返す
  if not self.initialized:
    error "History store not initialized"
    return (-1, -1)
  
  # URLの正規化とハッシュ化
  let 
    sanitizedUrl = sanitizeUrl(url)
    urlHash = hashUrl(sanitizedUrl)
  
  # 暗号化
  let 
    encryptedUrl = if self.options.encryptionEnabled: encryptString(sanitizedUrl, self.options.encryptionKey) else: sanitizedUrl
    encryptedTitle = if self.options.encryptionEnabled: encryptString(title, self.options.encryptionKey) else: title
    isEncrypted = if self.options.encryptionEnabled: 1 else: 0
  
  var pageId: int64 = -1
  let visitTimestamp = visitTime.toTime().toUnix()
  
  # トランザクション開始
  self.db.exec(sql"BEGIN TRANSACTION")
  
  try:
    # 既存ページをチェック
    let row = self.db.getRow(sql"SELECT id, visit_count, typed_count FROM pages WHERE url_hash = ?", urlHash)
    
    if row[0] != "":
      # 既存ページを更新
      pageId = parseInt(row[0]).int64
      let 
        visitCount = parseInt(row[1]) + 1
        typedCount = parseInt(row[2]) + (if visitType == VisitType.vtTyped: 1 else: 0)
      
      self.db.exec(sql"""
        UPDATE pages SET 
          title = ?, 
          last_visit_time = ?, 
          visit_count = ?, 
          typed_count = ?
        WHERE id = ?
      """, encryptedTitle, $visitTimestamp, $visitCount, $typedCount, $pageId)
    else:
      # 新規ページを作成
      self.db.exec(sql"""
        INSERT INTO pages (
          url, url_hash, title, last_visit_time, visit_count, typed_count, hidden, is_encrypted
        ) VALUES (?, ?, ?, ?, ?, ?, 0, ?)
      """, 
        encryptedUrl, urlHash, encryptedTitle, $visitTimestamp, 
        "1", $ord(visitType == VisitType.vtTyped), $isEncrypted)
      
      pageId = self.db.lastInsertRowId()
    
    # 訪問を追加
    self.db.exec(sql"""
      INSERT INTO visits (
        page_id, visit_time, visit_type, transition_flags, referring_visit_id
      ) VALUES (?, ?, ?, ?, ?)
    """, 
      $pageId, $visitTimestamp, $visitType, $transitionFlags, 
      if referringVisitId.isSome: $referringVisitId.get() else: nil)
    
    let visitId = self.db.lastInsertRowId()
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    info "Added page visit", url = sanitizedUrl, page_id = pageId, visit_id = visitId
    return (pageId, visitId)
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to add page visit", 
          url = sanitizedUrl, 
          error = getCurrentExceptionMsg()
    return (-1, -1)

proc getPageById*(self: HistoryStore, pageId: int64, includeVisits: bool = false): Option[HistoryPage] =
  ## IDによりページを取得
  if not self.initialized:
    error "History store not initialized"
    return none(HistoryPage)
  
  try:
    let row = self.db.getRow(sql"""
      SELECT id, url, title, last_visit_time, visit_count, typed_count, hidden, favicon
      FROM pages
      WHERE id = ?
    """, $pageId)
    
    if row[0] == "":
      return none(HistoryPage)
    
    var page = rowToHistoryPage(row, self.options.encryptionKey)
    
    # 訪問情報を取得（必要な場合）
    if includeVisits:
      let visits = self.db.getAllRows(sql"""
        SELECT id, page_id, visit_time, visit_type, transition_flags, referring_visit_id
        FROM visits
        WHERE page_id = ?
        ORDER BY visit_time DESC
      """, $pageId)
      
      for vrow in visits:
        page.visits.add(rowToPageVisit(vrow))
    
    return some(page)
    
  except:
    error "Failed to get page by ID", 
          id = pageId, 
          error = getCurrentExceptionMsg()
    return none(HistoryPage)

proc getPageByUrl*(self: HistoryStore, url: string, includeVisits: bool = false): Option[HistoryPage] =
  ## URLによりページを取得
  if not self.initialized:
    error "History store not initialized"
    return none(HistoryPage)
  
  # URLの正規化とハッシュ化
  let 
    sanitizedUrl = sanitizeUrl(url)
    urlHash = hashUrl(sanitizedUrl)
  
  try:
    let row = self.db.getRow(sql"""
      SELECT id, url, title, last_visit_time, visit_count, typed_count, hidden, favicon
      FROM pages
      WHERE url_hash = ?
    """, urlHash)
    
    if row[0] == "":
      return none(HistoryPage)
    
    let pageId = parseInt(row[0]).int64
    var page = rowToHistoryPage(row, self.options.encryptionKey)
    
    # 訪問情報を取得（必要な場合）
    if includeVisits:
      let visits = self.db.getAllRows(sql"""
        SELECT id, page_id, visit_time, visit_type, transition_flags, referring_visit_id
        FROM visits
        WHERE page_id = ?
        ORDER BY visit_time DESC
      """, $pageId)
      
      for vrow in visits:
        page.visits.add(rowToPageVisit(vrow))
    
    return some(page)
    
  except:
    error "Failed to get page by URL", 
          url = sanitizedUrl, 
          error = getCurrentExceptionMsg()
    return none(HistoryPage)

proc searchHistory*(self: HistoryStore, options: SearchOptions): seq[HistoryPage] =
  ## 履歴を検索
  result = @[]
  
  if not self.initialized:
    error "History store not initialized"
    return result
  
  var 
    queryParts: seq[string] = @[]
    queryParams: seq[string] = @[]
    orderBy = if options.orderByTime: "p.last_visit_time DESC" else: "p.visit_count DESC"
    limit = if options.maxResults > 0: options.maxResults else: DEFAULT_MAX_RESULTS
  
  queryParts.add("1=1") # 常に真の条件（後でANDで他の条件を追加するため）
  
  # テキスト検索
  if options.text.len > 0:
    let searchText = "%" & options.text & "%"
    queryParts.add("(p.url LIKE ? OR p.title LIKE ?)")
    queryParams.add(searchText)
    queryParams.add(searchText)
  
  # 時間範囲
  if options.startTime.isSome:
    let startTimestamp = options.startTime.get().toTime().toUnix()
    queryParts.add("p.last_visit_time >= ?")
    queryParams.add($startTimestamp)
  
  if options.endTime.isSome:
    let endTimestamp = options.endTime.get().toTime().toUnix()
    queryParts.add("p.last_visit_time <= ?")
    queryParams.add($endTimestamp)
  
  # 直接入力のみ
  if options.onlyTyped:
    queryParts.add("p.typed_count > 0")
  
  # 非表示項目の除外
  if not options.includeHidden:
    queryParts.add("p.hidden = 0")
  
  # ドメイン指定
  if options.domain.len > 0:
    queryParts.add("p.url LIKE ?")
    queryParams.add("%" & options.domain & "%")
  
  # クエリ構築
  let whereClause = queryParts.join(" AND ")
  
  let query = fmt"""
    SELECT p.id, p.url, p.title, p.last_visit_time, p.visit_count, p.typed_count, p.hidden, p.favicon
    FROM pages p
    WHERE {whereClause}
    ORDER BY {orderBy}
    LIMIT {limit}
  """
  
  try:
    let rows = self.db.getAllRows(sql(query), queryParams)
    
    for row in rows:
      var page = rowToHistoryPage(row, self.options.encryptionKey)
      result.add(page)
    
  except:
    error "Failed to search history", 
          query = query, 
          error = getCurrentExceptionMsg()
  
  info "History search completed", 
       text = options.text, 
       results = result.len

proc getMostVisitedPages*(self: HistoryStore, limit: int = 10): seq[HistoryPage] =
  ## 最もよく訪問されたページを取得
  result = @[]
  
  if not self.initialized:
    error "History store not initialized"
    return result
  
  try:
    let rows = self.db.getAllRows(sql"""
      SELECT id, url, title, last_visit_time, visit_count, typed_count, hidden, favicon
      FROM pages
      WHERE hidden = 0
      ORDER BY visit_count DESC
      LIMIT ?
    """, $limit)
    
    for row in rows:
      result.add(rowToHistoryPage(row, self.options.encryptionKey))
    
  except:
    error "Failed to get most visited pages", 
          error = getCurrentExceptionMsg()
  
  return result

proc getRecentPages*(self: HistoryStore, limit: int = 20): seq[HistoryPage] =
  ## 最近訪問したページを取得
  result = @[]
  
  if not self.initialized:
    error "History store not initialized"
    return result
  
  try:
    let rows = self.db.getAllRows(sql"""
      SELECT id, url, title, last_visit_time, visit_count, typed_count, hidden, favicon
      FROM pages
      WHERE hidden = 0
      ORDER BY last_visit_time DESC
      LIMIT ?
    """, $limit)
    
    for row in rows:
      result.add(rowToHistoryPage(row, self.options.encryptionKey))
    
  except:
    error "Failed to get recent pages", 
          error = getCurrentExceptionMsg()
  
  return result

proc getVisitsForPage*(self: HistoryStore, pageId: int64): seq[PageVisit] =
  ## ページの訪問履歴を取得
  result = @[]
  
  if not self.initialized:
    error "History store not initialized"
    return result
  
  try:
    let rows = self.db.getAllRows(sql"""
      SELECT id, page_id, visit_time, visit_type, transition_flags, referring_visit_id
      FROM visits
      WHERE page_id = ?
      ORDER BY visit_time DESC
    """, $pageId)
    
    for row in rows:
      result.add(rowToPageVisit(row))
    
  except:
    error "Failed to get visits for page", 
          page_id = pageId, 
          error = getCurrentExceptionMsg()
  
  return result

proc deletePageById*(self: HistoryStore, pageId: int64): bool =
  ## ページを削除
  if not self.initialized:
    error "History store not initialized"
    return false
  
  try:
    # トランザクション開始
    self.db.exec(sql"BEGIN TRANSACTION")
    
    # 関連する訪問を削除
    self.db.exec(sql"DELETE FROM visits WHERE page_id = ?", $pageId)
    
    # ページを削除
    self.db.exec(sql"DELETE FROM pages WHERE id = ?", $pageId)
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    info "Deleted page", page_id = pageId
    return true
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to delete page", 
          page_id = pageId, 
          error = getCurrentExceptionMsg()
    return false

proc deletePageByUrl*(self: HistoryStore, url: string): bool =
  ## URLでページを削除
  if not self.initialized:
    error "History store not initialized"
    return false
  
  # URLの正規化とハッシュ化
  let 
    sanitizedUrl = sanitizeUrl(url)
    urlHash = hashUrl(sanitizedUrl)
  
  try:
    # ページIDを取得
    let row = self.db.getRow(sql"SELECT id FROM pages WHERE url_hash = ?", urlHash)
    if row[0] == "":
      return false
    
    let pageId = parseInt(row[0]).int64
    return self.deletePageById(pageId)
    
  except:
    error "Failed to delete page by URL", 
          url = sanitizedUrl, 
          error = getCurrentExceptionMsg()
    return false

proc setPageHidden*(self: HistoryStore, pageId: int64, hidden: bool): bool =
  ## ページの非表示設定を変更
  if not self.initialized:
    error "History store not initialized"
    return false
  
  try:
    self.db.exec(sql"UPDATE pages SET hidden = ? WHERE id = ?",
      if hidden: "1" else: "0", $pageId)
    
    info "Set page hidden state", page_id = pageId, hidden = hidden
    return true
    
  except:
    error "Failed to set page hidden state", 
          page_id = pageId, 
          error = getCurrentExceptionMsg()
    return false

proc setFavicon*(self: HistoryStore, pageId: int64, faviconUrl: string): bool =
  ## ページのファビコンURLを設定
  if not self.initialized:
    error "History store not initialized"
    return false
  
  try:
    self.db.exec(sql"UPDATE pages SET favicon = ? WHERE id = ?",
      faviconUrl, $pageId)
    
    info "Set page favicon", page_id = pageId, favicon = faviconUrl
    return true
    
  except:
    error "Failed to set page favicon", 
          page_id = pageId, 
          error = getCurrentExceptionMsg()
    return false

proc deleteHistory*(self: HistoryStore, startTime: Option[DateTime] = none(DateTime), 
                   endTime: Option[DateTime] = none(DateTime)): int =
  ## 期間内の履歴を削除し、削除件数を返す
  if not self.initialized:
    error "History store not initialized"
    return 0
  
  var 
    whereClause = "1=1"
    params: seq[string] = @[]
  
  # 時間範囲の条件
  if startTime.isSome:
    whereClause &= " AND last_visit_time >= ?"
    params.add($startTime.get().toTime().toUnix())
  
  if endTime.isSome:
    whereClause &= " AND last_visit_time <= ?"
    params.add($endTime.get().toTime().toUnix())
  
  try:
    # 削除前のカウント
    let beforeCount = self.db.getRow(sql"SELECT COUNT(*) FROM pages")[0].parseInt()
    
    # トランザクション開始
    self.db.exec(sql"BEGIN TRANSACTION")
    
    # 関連する訪問を削除
    var visitQuery = fmt"DELETE FROM visits WHERE page_id IN (SELECT id FROM pages WHERE {whereClause})"
    self.db.exec(sql(visitQuery), params)
    
    # ページを削除
    var pageQuery = fmt"DELETE FROM pages WHERE {whereClause}"
    self.db.exec(sql(pageQuery), params)
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    # 削除後のカウント
    let afterCount = self.db.getRow(sql"SELECT COUNT(*) FROM pages")[0].parseInt()
    let deletedCount = beforeCount - afterCount
    
    info "Deleted history", 
         deleted_count = deletedCount,
         start_time = if startTime.isSome: $startTime.get() else: "none",
         end_time = if endTime.isSome: $endTime.get() else: "none"
    
    return deletedCount
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to delete history", 
          error = getCurrentExceptionMsg()
    return 0

proc clearAllHistory*(self: HistoryStore): bool =
  ## すべての履歴を削除
  if not self.initialized:
    error "History store not initialized"
    return false
  
  try:
    # トランザクション開始
    self.db.exec(sql"BEGIN TRANSACTION")
    
    # すべての訪問を削除
    self.db.exec(sql"DELETE FROM visits")
    
    # すべてのページを削除
    self.db.exec(sql"DELETE FROM pages")
    
    # トランザクション完了
    self.db.exec(sql"COMMIT")
    
    info "Cleared all history"
    return true
    
  except:
    # エラー時はロールバック
    self.db.exec(sql"ROLLBACK")
    error "Failed to clear all history", 
          error = getCurrentExceptionMsg()
    return false

proc cleanupOldHistory*(self: HistoryStore): int =
  ## 古い履歴を削除し、削除件数を返す
  if not self.initialized or not self.options.autoCleanupEnabled:
    return 0
  
  let cutoffTime = now() - self.options.retentionDays.days
  return self.deleteHistory(none(DateTime), some(cutoffTime))

proc cleanupTask*(self: HistoryStore) {.async.} =
  ## 定期クリーンアップタスク
  while self.initialized and self.options.autoCleanupEnabled:
    # 1日に1回実行
    await sleepAsync(24 * 60 * 60 * 1000)
    
    let deletedCount = self.cleanupOldHistory()
    info "History cleanup completed", deleted_count = deletedCount
    
# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testHistoryStore() =
    # テンポラリデータベースを使用
    let dbPath = getTempDir() / "history_test.db"
    
    # ストアオプション
    let options = StorageOptions(
      encryptionEnabled: true,
      encryptionKey: "test_encryption_key",
      autoCleanupEnabled: true,
      retentionDays: 90,
      syncEnabled: false
    )
    
    # ストア作成
    let store = newHistoryStore(dbPath, options)
    
    # テストURL
    let 
      url1 = "https://example.com"
      url2 = "https://example.com/page1"
      url3 = "https://test.com"
    
    # 訪問追加
    let (pageId1, visitId1) = store.addPageVisit(url1, "Example Domain", VisitType.vtTyped)
    echo "Added visit: Page ID = ", pageId1, ", Visit ID = ", visitId1
    
    let (pageId2, _) = store.addPageVisit(url2, "Example Page 1", VisitType.vtLink)
    let (pageId3, _) = store.addPageVisit(url3, "Test Site", VisitType.vtBookmark)
    
    # 再訪問
    discard store.addPageVisit(url1, "Example Domain", VisitType.vtLink)
    
    # ページ取得
    let page1 = store.getPageById(pageId1, true)
    if page1.isSome:
      let p = page1.get()
      echo "Retrieved page: ", p.title, " (", p.url, ")"
      echo "Visit count: ", p.visitCount
      echo "Visits: ", p.visits.len
    
    # URL検索
    let page2 = store.getPageByUrl(url2)
    if page2.isSome:
      echo "Found by URL: ", page2.get().title
    
    # 検索
    let searchOpts = SearchOptions(
      text: "example",
      maxResults: 10,
      orderByTime: true,
      includeHidden: false
    )
    
    let results = store.searchHistory(searchOpts)
    echo "Search results: ", results.len
    for page in results:
      echo "  ", page.title, " (", page.url, ") - Visits: ", page.visitCount
    
    # 最もよく訪問したページ
    let popular = store.getMostVisitedPages()
    echo "Most visited: ", popular.len
    
    # 非表示設定
    discard store.setPageHidden(pageId3, true)
    
    # 削除
    let deleted = store.deletePageById(pageId2)
    echo "Deleted page: ", deleted
    
    # クリーンアップ
    let cleaned = store.cleanupOldHistory()
    echo "Cleaned old history: ", cleaned
    
    # 統計
    let totalPages = store.db.getRow(sql"SELECT COUNT(*) FROM pages")[0].parseInt()
    let totalVisits = store.db.getRow(sql"SELECT COUNT(*) FROM visits")[0].parseInt()
    
    echo "Total pages: ", totalPages
    echo "Total visits: ", totalVisits
    
    # ストアを閉じる
    store.close()
    
    # テスト後にテンポラリDBを削除
    removeFile(dbPath)
  
  # テスト実行
  testHistoryStore() 