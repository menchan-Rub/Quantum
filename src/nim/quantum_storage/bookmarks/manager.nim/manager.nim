# manager.nim
## ブックマーク管理モジュール
## ブラウザのブックマーク管理機能を提供します

import std/[
  options,
  tables,
  sets,
  hashes,
  strutils,
  strformat,
  sequtils,
  algorithm,
  times,
  uri,
  json,
  os,
  logging,
  asyncdispatch,
  db_sqlite,
  base64
]

import ../../../utils/[logging, errors, db_utils]
import ../storage_types
import ./sync

type
  BookmarkType* = enum
    ## ブックマークタイプ
    btUrl,        ## URL
    btFolder,     ## フォルダ
    btSeparator   ## 区切り線

  BookmarkItem* = ref object
    ## ブックマーク項目
    id*: string                  ## 一意のID
    title*: string               ## タイトル
    parentId*: Option[string]    ## 親ID
    position*: int               ## 表示位置
    dateAdded*: Time             ## 追加日時
    dateModified*: Time          ## 更新日時
    case itemType*: BookmarkType ## 項目タイプ
    of btUrl:
      url*: string                 ## URL
      iconUrl*: Option[string]     ## アイコンURL
      visitCount*: int             ## 訪問回数
      keywords*: seq[string]       ## キーワード（検索用）
    of btFolder:
      children*: seq[string]       ## 子アイテムID
    of btSeparator:
      discard

  ImportFormat* = enum
    ## インポート形式
    ifHTML,      ## Netscape HTML形式
    ifJSON,      ## JSON形式
    ifAuto       ## 自動検出

  ExportFormat* = enum
    ## エクスポート形式
    efHTML,      ## Netscape HTML形式
    efJSON       ## JSON形式

  SortOrder* = enum
    ## ソート順
    soTitle,     ## タイトル順
    soNewest,    ## 新しい順
    soOldest,    ## 古い順
    soVisits,    ## 訪問回数順
    soCustom     ## カスタム順（位置指定）

  SearchOptions* = object
    ## 検索オプション
    query*: string              ## 検索クエリ
    caseSensitive*: bool        ## 大文字小文字区別
    searchUrls*: bool           ## URLも検索
    searchTags*: bool           ## タグも検索
    maxResults*: int            ## 最大結果数
    excludeFolders*: bool       ## フォルダを除外
    includeRecent*: bool        ## 最近のみ含める

  BookmarksDatabase* = ref object
    ## ブックマークデータベース
    db*: DbConn                      ## データベース接続
    logger: Logger                   ## ロガー
    rootFolder*: string              ## ルートフォルダID
    menuFolder*: string              ## メニューフォルダID
    toolbarFolder*: string           ## ツールバーフォルダID
    mobileFolder*: string            ## モバイルフォルダID
    otherFolder*: string             ## その他フォルダID
    recentBookmarks*: seq[string]    ## 最近のブックマークID
    cache*: Table[string, BookmarkItem] ## キャッシュ
    path*: string                    ## データベースパス
    syncManager*: BookmarkSyncManager ## 同期管理
    enableSync*: bool                ## 同期有効フラグ

const
  DB_VERSION = 1
  DEFAULT_FAVICON = "resource://default-favicon.png"
  ROOT_BOOKMARK_ID = "root________"
  MENU_FOLDER_ID = "menu________"
  TOOLBAR_FOLDER_ID = "toolbar_____"
  MOBILE_FOLDER_ID = "mobile______"
  OTHER_FOLDER_ID = "other_______"

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc initDatabase(bm: BookmarksDatabase, reset: bool = false) =
  ## データベースを初期化
  if reset and fileExists(bm.path):
    removeFile(bm.path)
  
  bm.db = openDatabase(bm.path)
  
  # テーブル作成
  bm.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS bookmarks (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      parent_id TEXT,
      position INTEGER NOT NULL,
      item_type INTEGER NOT NULL,
      url TEXT,
      icon_url TEXT,
      visit_count INTEGER DEFAULT 0,
      date_added INTEGER NOT NULL,
      date_modified INTEGER NOT NULL,
      FOREIGN KEY (parent_id) REFERENCES bookmarks(id) ON DELETE CASCADE
    )
  """)
  
  bm.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS keywords (
      bookmark_id TEXT NOT NULL,
      keyword TEXT NOT NULL,
      PRIMARY KEY (bookmark_id, keyword),
      FOREIGN KEY (bookmark_id) REFERENCES bookmarks(id) ON DELETE CASCADE
    )
  """)
  
  bm.db.exec(sql"""
    CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  
  # インデックス作成
  bm.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_bookmarks_parent ON bookmarks(parent_id)")
  bm.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_bookmarks_type ON bookmarks(item_type)")
  bm.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks(url)")
  bm.db.exec(sql"CREATE INDEX IF NOT EXISTS idx_keywords_keyword ON keywords(keyword)")
  
  # バージョン情報の保存
  let version = bm.db.getValueOrDefault(sql"SELECT value FROM metadata WHERE key = ?", "version", "0")
  if version == "0":
    bm.db.exec(sql"INSERT INTO metadata (key, value) VALUES (?, ?)", "version", $DB_VERSION)
  elif parseInt(version) < DB_VERSION:
    # マイグレーション処理を行う場合はここに記述
    bm.db.exec(sql"UPDATE metadata SET value = ? WHERE key = ?", $DB_VERSION, "version")

proc createDefaultFolders(bm: BookmarksDatabase) =
  ## デフォルトフォルダを作成
  let now = getTime()
  
  # ルートフォルダがない場合は作成
  let rootExists = bm.db.getValue(sql"SELECT count(*) FROM bookmarks WHERE id = ?", ROOT_BOOKMARK_ID)
  if rootExists == "0":
    bm.db.exec(sql"""
      INSERT INTO bookmarks (id, title, parent_id, position, item_type, date_added, date_modified)
      VALUES (?, ?, NULL, 0, ?, ?, ?)
    """, ROOT_BOOKMARK_ID, "Root", int(btFolder), now.toUnix(), now.toUnix())
    
    # 主要フォルダを作成
    bm.db.exec(sql"""
      INSERT INTO bookmarks (id, title, parent_id, position, item_type, date_added, date_modified)
      VALUES (?, ?, ?, 0, ?, ?, ?)
    """, MENU_FOLDER_ID, "ブックマークメニュー", ROOT_BOOKMARK_ID, int(btFolder), now.toUnix(), now.toUnix())
    
    bm.db.exec(sql"""
      INSERT INTO bookmarks (id, title, parent_id, position, item_type, date_added, date_modified)
      VALUES (?, ?, ?, 1, ?, ?, ?)
    """, TOOLBAR_FOLDER_ID, "ブックマークツールバー", ROOT_BOOKMARK_ID, int(btFolder), now.toUnix(), now.toUnix())
    
    bm.db.exec(sql"""
      INSERT INTO bookmarks (id, title, parent_id, position, item_type, date_added, date_modified)
      VALUES (?, ?, ?, 2, ?, ?, ?)
    """, MOBILE_FOLDER_ID, "モバイルのブックマーク", ROOT_BOOKMARK_ID, int(btFolder), now.toUnix(), now.toUnix())
    
    bm.db.exec(sql"""
      INSERT INTO bookmarks (id, title, parent_id, position, item_type, date_added, date_modified)
      VALUES (?, ?, ?, 3, ?, ?, ?)
    """, OTHER_FOLDER_ID, "その他のブックマーク", ROOT_BOOKMARK_ID, int(btFolder), now.toUnix(), now.toUnix())
  
  # フォルダIDをセット
  bm.rootFolder = ROOT_BOOKMARK_ID
  bm.menuFolder = MENU_FOLDER_ID
  bm.toolbarFolder = TOOLBAR_FOLDER_ID
  bm.mobileFolder = MOBILE_FOLDER_ID
  bm.otherFolder = OTHER_FOLDER_ID

proc loadBookmarkFromRow(row: Row): BookmarkItem =
  ## データベース行からブックマークアイテムを読み込み
  let itemType = BookmarkType(parseInt(row[4]))
  
  result = BookmarkItem(
    id: row[0],
    title: row[1],
    position: parseInt(row[3]),
    itemType: itemType,
    dateAdded: fromUnix(parseInt(row[8])),
    dateModified: fromUnix(parseInt(row[9]))
  )
  
  # 親IDがある場合は設定
  if row[2] != "":
    result.parentId = some(row[2])
  else:
    result.parentId = none(string)
  
  # タイプ別の追加情報
  case itemType
  of btUrl:
    result.url = row[5]
    if row[6] != "":
      result.iconUrl = some(row[6])
    else:
      result.iconUrl = none(string)
    result.visitCount = parseInt(row[7])
    result.keywords = @[]
  of btFolder:
    result.children = @[]
  of btSeparator:
    discard

proc loadKeywords(bm: BookmarksDatabase, bookmarkId: string): seq[string] =
  ## ブックマークのキーワードを読み込み
  result = @[]
  for row in bm.db.getAllRows(sql"SELECT keyword FROM keywords WHERE bookmark_id = ?", bookmarkId):
    result.add(row[0])

proc generateId(): string =
  ## 一意のIDを生成
  let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  result = ""
  for i in 0..<12:
    result.add(chars[rand(chars.len-1)])

proc newBookmarksDatabase*(path: string, enableSync: bool = false): BookmarksDatabase =
  ## 新しいブックマークデータベースを作成
  randomize()
  
  result = BookmarksDatabase(
    path: path,
    logger: newLogger("BookmarksDatabase"),
    cache: initTable[string, BookmarkItem](),
    recentBookmarks: @[],
    enableSync: enableSync
  )
  
  # ディレクトリがなければ作成
  let dir = parentDir(path)
  if not dirExists(dir):
    createDir(dir)
  
  # データベース初期化
  result.initDatabase()
  result.createDefaultFolders()
  
  # 同期マネージャー初期化
  if enableSync:
    result.syncManager = newBookmarkSyncManager(result)
  
  result.logger.info("ブックマークデータベースを初期化しました: " & path)

#----------------------------------------
# ブックマーク操作
#----------------------------------------

proc getBookmark*(bm: BookmarksDatabase, id: string): Option[BookmarkItem] =
  ## 指定IDのブックマークを取得
  # キャッシュチェック
  if id in bm.cache:
    return some(bm.cache[id])
  
  # データベースから取得
  let row = bm.db.getRow(sql"SELECT * FROM bookmarks WHERE id = ?", id)
  if row[0] == "":
    return none(BookmarkItem)
  
  let item = loadBookmarkFromRow(row)
  
  # URLの場合はキーワードを読み込み
  if item.itemType == btUrl:
    item.keywords = bm.loadKeywords(id)
  
  # フォルダの場合は子アイテムIDを読み込み
  if item.itemType == btFolder:
    for childRow in bm.db.getAllRows(sql"""
      SELECT id FROM bookmarks 
      WHERE parent_id = ? 
      ORDER BY position
    """, id):
      item.children.add(childRow[0])
  
  # キャッシュに追加
  bm.cache[id] = item
  
  return some(item)

proc getFolderContents*(bm: BookmarksDatabase, folderId: string): seq[BookmarkItem] =
  ## フォルダの中身を取得
  result = @[]
  
  let folderOpt = bm.getBookmark(folderId)
  if folderOpt.isNone or folderOpt.get().itemType != btFolder:
    return result
  
  let folder = folderOpt.get()
  
  # 子アイテムIDから順番にブックマークを取得
  for childId in folder.children:
    let childOpt = bm.getBookmark(childId)
    if childOpt.isSome:
      result.add(childOpt.get())

proc createBookmark*(bm: BookmarksDatabase, title: string, url: string, parentId: string = MENU_FOLDER_ID, 
                   position: int = -1, iconUrl: string = ""): string =
  ## 新しいブックマークを作成
  # 親フォルダのチェック
  let parentOpt = bm.getBookmark(parentId)
  if parentOpt.isNone or parentOpt.get().itemType != btFolder:
    raise newException(BookmarkError, "親フォルダが存在しないか無効です: " & parentId)
  
  let parent = parentOpt.get()
  
  # 位置の決定（デフォルトは最後）
  var pos = position
  if pos < 0:
    pos = parent.children.len
  
  # 位置の調整（既存の項目を後ろにずらす）
  if pos < parent.children.len:
    bm.db.exec(sql"""
      UPDATE bookmarks 
      SET position = position + 1 
      WHERE parent_id = ? AND position >= ?
    """, parentId, pos)
  
  # IDを生成
  let id = generateId()
  let now = getTime()
  
  # ブックマークをデータベースに追加
  bm.db.exec(sql"""
    INSERT INTO bookmarks 
    (id, title, parent_id, position, item_type, url, icon_url, date_added, date_modified)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  """, id, title, parentId, pos, int(btUrl), url, iconUrl, now.toUnix(), now.toUnix())
  
  # 親フォルダの子リストを更新
  var newChildren = parent.children
  if pos >= newChildren.len:
    newChildren.add(id)
  else:
    newChildren.insert(id, pos)
  
  # 親フォルダを更新
  var updatedParent = parent
  updatedParent.children = newChildren
  updatedParent.dateModified = now
  bm.cache[parentId] = updatedParent
  
  # 更新時刻を設定
  bm.db.exec(sql"UPDATE bookmarks SET date_modified = ? WHERE id = ?", now.toUnix(), parentId)
  
  # 新しいブックマークをキャッシュに追加
  let newBookmark = BookmarkItem(
    id: id,
    title: title,
    parentId: some(parentId),
    position: pos,
    itemType: btUrl,
    url: url,
    iconUrl: if iconUrl.len > 0: some(iconUrl) else: none(string),
    visitCount: 0,
    keywords: @[],
    dateAdded: now,
    dateModified: now
  )
  bm.cache[id] = newBookmark
  
  # 最近のブックマークに追加
  bm.recentBookmarks.insert(id, 0)
  if bm.recentBookmarks.len > 10:
    bm.recentBookmarks.setLen(10)
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemAdded(id)
  
  return id

proc createFolder*(bm: BookmarksDatabase, title: string, parentId: string = MENU_FOLDER_ID, 
                 position: int = -1): string =
  ## 新しいフォルダを作成
  # 親フォルダのチェック
  let parentOpt = bm.getBookmark(parentId)
  if parentOpt.isNone or parentOpt.get().itemType != btFolder:
    raise newException(BookmarkError, "親フォルダが存在しないか無効です: " & parentId)
  
  let parent = parentOpt.get()
  
  # 位置の決定（デフォルトは最後）
  var pos = position
  if pos < 0:
    pos = parent.children.len
  
  # 位置の調整（既存の項目を後ろにずらす）
  if pos < parent.children.len:
    bm.db.exec(sql"""
      UPDATE bookmarks 
      SET position = position + 1 
      WHERE parent_id = ? AND position >= ?
    """, parentId, pos)
  
  # IDを生成
  let id = generateId()
  let now = getTime()
  
  # フォルダをデータベースに追加
  bm.db.exec(sql"""
    INSERT INTO bookmarks 
    (id, title, parent_id, position, item_type, date_added, date_modified)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  """, id, title, parentId, pos, int(btFolder), now.toUnix(), now.toUnix())
  
  # 親フォルダの子リストを更新
  var newChildren = parent.children
  if pos >= newChildren.len:
    newChildren.add(id)
  else:
    newChildren.insert(id, pos)
  
  # 親フォルダを更新
  var updatedParent = parent
  updatedParent.children = newChildren
  updatedParent.dateModified = now
  bm.cache[parentId] = updatedParent
  
  # 更新時刻を設定
  bm.db.exec(sql"UPDATE bookmarks SET date_modified = ? WHERE id = ?", now.toUnix(), parentId)
  
  # 新しいフォルダをキャッシュに追加
  let newFolder = BookmarkItem(
    id: id,
    title: title,
    parentId: some(parentId),
    position: pos,
    itemType: btFolder,
    children: @[],
    dateAdded: now,
    dateModified: now
  )
  bm.cache[id] = newFolder
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemAdded(id)
  
  return id

proc createSeparator*(bm: BookmarksDatabase, parentId: string = MENU_FOLDER_ID, 
                    position: int = -1): string =
  ## 新しい区切り線を作成
  # 親フォルダのチェック
  let parentOpt = bm.getBookmark(parentId)
  if parentOpt.isNone or parentOpt.get().itemType != btFolder:
    raise newException(BookmarkError, "親フォルダが存在しないか無効です: " & parentId)
  
  let parent = parentOpt.get()
  
  # 位置の決定（デフォルトは最後）
  var pos = position
  if pos < 0:
    pos = parent.children.len
  
  # 位置の調整（既存の項目を後ろにずらす）
  if pos < parent.children.len:
    bm.db.exec(sql"""
      UPDATE bookmarks 
      SET position = position + 1 
      WHERE parent_id = ? AND position >= ?
    """, parentId, pos)
  
  # IDを生成
  let id = generateId()
  let now = getTime()
  
  # 区切り線をデータベースに追加
  bm.db.exec(sql"""
    INSERT INTO bookmarks 
    (id, title, parent_id, position, item_type, date_added, date_modified)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  """, id, "--------", parentId, pos, int(btSeparator), now.toUnix(), now.toUnix())
  
  # 親フォルダの子リストを更新
  var newChildren = parent.children
  if pos >= newChildren.len:
    newChildren.add(id)
  else:
    newChildren.insert(id, pos)
  
  # 親フォルダを更新
  var updatedParent = parent
  updatedParent.children = newChildren
  updatedParent.dateModified = now
  bm.cache[parentId] = updatedParent
  
  # 更新時刻を設定
  bm.db.exec(sql"UPDATE bookmarks SET date_modified = ? WHERE id = ?", now.toUnix(), parentId)
  
  # 新しい区切り線をキャッシュに追加
  let newSeparator = BookmarkItem(
    id: id,
    title: "--------",
    parentId: some(parentId),
    position: pos,
    itemType: btSeparator,
    dateAdded: now,
    dateModified: now
  )
  bm.cache[id] = newSeparator
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemAdded(id)
  
  return id 

proc updateBookmark*(bm: BookmarksDatabase, id: string, title: string = "", url: string = "", 
                   iconUrl: string = ""): bool =
  ## ブックマークを更新
  let bookmarkOpt = bm.getBookmark(id)
  if bookmarkOpt.isNone:
    return false
  
  let bookmark = bookmarkOpt.get()
  if bookmark.itemType != btUrl:
    return false
  
  let now = getTime()
  
  # 更新するフィールドを作成
  var newTitle = bookmark.title
  if title.len > 0:
    newTitle = title
  
  var newUrl = bookmark.url
  if url.len > 0:
    newUrl = url
  
  var newIconUrl = if bookmark.iconUrl.isSome: bookmark.iconUrl.get() else: ""
  if iconUrl.len > 0:
    newIconUrl = iconUrl
  
  # データベース更新
  bm.db.exec(sql"""
    UPDATE bookmarks
    SET title = ?, url = ?, icon_url = ?, date_modified = ?
    WHERE id = ?
  """, newTitle, newUrl, newIconUrl, now.toUnix(), id)
  
  # キャッシュ更新
  var updatedBookmark = bookmark
  updatedBookmark.title = newTitle
  updatedBookmark.url = newUrl
  if iconUrl.len > 0:
    updatedBookmark.iconUrl = some(newIconUrl)
  updatedBookmark.dateModified = now
  
  bm.cache[id] = updatedBookmark
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemChanged(id)
  
  return true

proc updateFolder*(bm: BookmarksDatabase, id: string, title: string): bool =
  ## フォルダを更新
  let folderOpt = bm.getBookmark(id)
  if folderOpt.isNone or folderOpt.get().itemType != btFolder:
    return false
  
  let folder = folderOpt.get()
  let now = getTime()
  
  # システムフォルダは更新不可
  if id in [ROOT_BOOKMARK_ID]:
    return false
  
  # データベース更新
  bm.db.exec(sql"""
    UPDATE bookmarks
    SET title = ?, date_modified = ?
    WHERE id = ?
  """, title, now.toUnix(), id)
  
  # キャッシュ更新
  var updatedFolder = folder
  updatedFolder.title = title
  updatedFolder.dateModified = now
  
  bm.cache[id] = updatedFolder
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemChanged(id)
  
  return true

proc moveItem*(bm: BookmarksDatabase, id: string, newParentId: string, newPosition: int = -1): bool =
  ## アイテムを移動
  let itemOpt = bm.getBookmark(id)
  if itemOpt.isNone:
    return false
  
  let item = itemOpt.get()
  
  # ルートは移動不可
  if id == ROOT_BOOKMARK_ID:
    return false
  
  # 親IDが同じでポジションも変わらない場合は何もしない
  if item.parentId.isSome and item.parentId.get() == newParentId and 
     (newPosition < 0 or newPosition == item.position):
    return true
  
  # 新しい親フォルダのチェック
  let newParentOpt = bm.getBookmark(newParentId)
  if newParentOpt.isNone or newParentOpt.get().itemType != btFolder:
    return false
  
  let newParent = newParentOpt.get()
  
  # 自分自身のフォルダには移動できない（循環参照になるため）
  if item.itemType == btFolder and id == newParentId:
    return false
  
  # 自分の子孫フォルダには移動できない
  if item.itemType == btFolder:
    var checkStack = item.children
    while checkStack.len > 0:
      let checkId = checkStack.pop()
      if checkId == newParentId:
        return false
      
      let childOpt = bm.getBookmark(checkId)
      if childOpt.isSome and childOpt.get().itemType == btFolder:
        checkStack.add(childOpt.get().children)
  
  # 元の親フォルダから削除
  if item.parentId.isSome:
    let oldParentId = item.parentId.get()
    let oldParentOpt = bm.getBookmark(oldParentId)
    
    if oldParentOpt.isSome:
      let oldParent = oldParentOpt.get()
      var newChildren = oldParent.children
      let oldPos = newChildren.find(id)
      
      if oldPos >= 0:
        newChildren.delete(oldPos)
        
        # 古い親の子リストを更新
        var updatedOldParent = oldParent
        updatedOldParent.children = newChildren
        updatedOldParent.dateModified = getTime()
        bm.cache[oldParentId] = updatedOldParent
        
        # 古い親フォルダ内のアイテムの位置を調整
        bm.db.exec(sql"""
          UPDATE bookmarks
          SET position = position - 1
          WHERE parent_id = ? AND position > ?
        """, oldParentId, oldPos)
  
  # 新しい位置の決定（デフォルトは最後）
  var newPos = newPosition
  if newPos < 0:
    newPos = newParent.children.len
  elif newPos > newParent.children.len:
    newPos = newParent.children.len
  
  # 新しい親フォルダ内のアイテムの位置を調整
  bm.db.exec(sql"""
    UPDATE bookmarks
    SET position = position + 1
    WHERE parent_id = ? AND position >= ?
  """, newParentId, newPos)
  
  # アイテムを更新
  let now = getTime()
  bm.db.exec(sql"""
    UPDATE bookmarks
    SET parent_id = ?, position = ?, date_modified = ?
    WHERE id = ?
  """, newParentId, newPos, now.toUnix(), id)
  
  # 新しい親の子リストを更新
  var newChildren = newParent.children
  if newPos >= newChildren.len:
    newChildren.add(id)
  else:
    newChildren.insert(id, newPos)
  
  var updatedNewParent = newParent
  updatedNewParent.children = newChildren
  updatedNewParent.dateModified = now
  bm.cache[newParentId] = updatedNewParent
  
  # アイテムのキャッシュを更新
  var updatedItem = item
  updatedItem.parentId = some(newParentId)
  updatedItem.position = newPos
  updatedItem.dateModified = now
  bm.cache[id] = updatedItem
  
  # 同期が有効ならイベント通知
  if bm.enableSync:
    bm.syncManager.notifyItemMoved(id)
  
  return true

proc deleteItem*(bm: BookmarksDatabase, id: string): bool =
  ## アイテムを削除
  let itemOpt = bm.getBookmark(id)
  if itemOpt.isNone:
    return false
  
  let item = itemOpt.get()
  
  # ルートフォルダと基本フォルダは削除不可
  if id in [ROOT_BOOKMARK_ID, MENU_FOLDER_ID, TOOLBAR_FOLDER_ID, MOBILE_FOLDER_ID, OTHER_FOLDER_ID]:
    return false
  
  # 削除対象がフォルダの場合は再帰的に削除
  if item.itemType == btFolder:
    var toDelete = item.children
    while toDelete.len > 0:
      let deleteId = toDelete.pop()
      let childOpt = bm.getBookmark(deleteId)
      
      if childOpt.isSome and childOpt.get().itemType == btFolder:
        toDelete.add(childOpt.get().children)
      
      # キャッシュから削除
      bm.cache.del(deleteId)
  
  # 親フォルダから削除
  if item.parentId.isSome:
    let parentId = item.parentId.get()
    let parentOpt = bm.getBookmark(parentId)
    
    if parentOpt.isSome:
      let parent = parentOpt.get()
      var newChildren = parent.children
      let pos = newChildren.find(id)
      
      if pos >= 0:
        newChildren.delete(pos)
        
        # 親の子リストを更新
        var updatedParent = parent
        updatedParent.children = newChildren
        updatedParent.dateModified = getTime()
        bm.cache[parentId] = updatedParent
        
        # 親フォルダ内のアイテムの位置を調整
        bm.db.exec(sql"""
          UPDATE bookmarks
          SET position = position - 1
          WHERE parent_id = ? AND position > ?
        """, parentId, pos)
        
        # 同期が有効ならイベント通知
        if bm.enableSync:
          bm.syncManager.notifyItemRemoved(id)
  
  # データベースから削除（CASCADE制約により関連レコードも削除される）
  bm.db.exec(sql"DELETE FROM bookmarks WHERE id = ?", id)
  
  # キャッシュから削除
  bm.cache.del(id)
  
  # 最近のブックマークからも削除
  let recentIndex = bm.recentBookmarks.find(id)
  if recentIndex >= 0:
    bm.recentBookmarks.delete(recentIndex)
  
  return true

proc searchBookmarks*(bm: BookmarksDatabase, options: SearchOptions): seq[BookmarkItem] =
  ## ブックマークを検索
  result = @[]
  
  if options.query.len == 0:
    return result
  
  var queryStr = options.query
  if not options.caseSensitive:
    queryStr = queryStr.toLowerAscii()
  
  var whereClause = ""
  var queryLike = "%" & queryStr & "%"
  
  # 検索条件の作成
  var conditions: seq[string] = @[]
  
  # タイトル検索
  if options.caseSensitive:
    conditions.add("title LIKE ?")
  else:
    conditions.add("LOWER(title) LIKE ?")
  
  # URL検索
  if options.searchUrls:
    if options.caseSensitive:
      conditions.add("url LIKE ?")
    else:
      conditions.add("LOWER(url) LIKE ?")
  
  # フォルダ除外
  if options.excludeFolders:
    whereClause = "item_type = " & $int(btUrl) & " AND (" & conditions.join(" OR ") & ")"
  else:
    whereClause = "(" & conditions.join(" OR ") & ")"
  
  # SQL実行
  var params: seq[string] = @[]
  for i in 0..<conditions.len:
    params.add(queryLike)
  
  var queryResults: seq[Row]
  
  if options.caseSensitive:
    queryResults = bm.db.getAllRows(sql("SELECT * FROM bookmarks WHERE " & whereClause & " ORDER BY date_modified DESC"), params)
  else:
    queryResults = bm.db.getAllRows(sql("SELECT * FROM bookmarks WHERE " & whereClause & " ORDER BY date_modified DESC"), params)
  
  # 検索結果を処理
  for row in queryResults:
    let item = loadBookmarkFromRow(row)
    
    # URLの場合はキーワードを検索
    if options.searchTags and item.itemType == btUrl:
      let keywords = bm.loadKeywords(item.id)
      item.keywords = keywords
      
      # キーワードに一致するかチェック
      var keywordMatch = false
      for keyword in keywords:
        var k = keyword
        if not options.caseSensitive:
          k = k.toLowerAscii()
        
        if k.contains(queryStr):
          keywordMatch = true
          break
      
      if keywordMatch:
        result.add(item)
        continue
    
    result.add(item)
    
    # 最大結果数に達したら終了
    if options.maxResults > 0 and result.len >= options.maxResults:
      break

proc addKeyword*(bm: BookmarksDatabase, bookmarkId: string, keyword: string): bool =
  ## キーワードを追加
  let bookmarkOpt = bm.getBookmark(bookmarkId)
  if bookmarkOpt.isNone or bookmarkOpt.get().itemType != btUrl:
    return false
  
  let bookmark = bookmarkOpt.get()
  
  # すでに同じキーワードがあるかチェック
  if keyword in bookmark.keywords:
    return true
  
  # データベースに追加
  try:
    bm.db.exec(sql"INSERT INTO keywords (bookmark_id, keyword) VALUES (?, ?)", bookmarkId, keyword)
    
    # キャッシュを更新
    var updatedBookmark = bookmark
    updatedBookmark.keywords.add(keyword)
    bm.cache[bookmarkId] = updatedBookmark
    
    return true
  except:
    return false

proc removeKeyword*(bm: BookmarksDatabase, bookmarkId: string, keyword: string): bool =
  ## キーワードを削除
  let bookmarkOpt = bm.getBookmark(bookmarkId)
  if bookmarkOpt.isNone or bookmarkOpt.get().itemType != btUrl:
    return false
  
  let bookmark = bookmarkOpt.get()
  
  # キーワードが存在するかチェック
  let keywordIndex = bookmark.keywords.find(keyword)
  if keywordIndex < 0:
    return false
  
  # データベースから削除
  bm.db.exec(sql"DELETE FROM keywords WHERE bookmark_id = ? AND keyword = ?", bookmarkId, keyword)
  
  # キャッシュを更新
  var updatedBookmark = bookmark
  updatedBookmark.keywords.delete(keywordIndex)
  bm.cache[bookmarkId] = updatedBookmark
  
  return true

proc incrementVisitCount*(bm: BookmarksDatabase, id: string): bool =
  ## 訪問回数を増加
  let bookmarkOpt = bm.getBookmark(id)
  if bookmarkOpt.isNone or bookmarkOpt.get().itemType != btUrl:
    return false
  
  let bookmark = bookmarkOpt.get()
  
  # データベース更新
  bm.db.exec(sql"UPDATE bookmarks SET visit_count = visit_count + 1 WHERE id = ?", id)
  
  # キャッシュ更新
  var updatedBookmark = bookmark
  updatedBookmark.visitCount += 1
  bm.cache[id] = updatedBookmark
  
  return true

proc findBookmarkByUrl*(bm: BookmarksDatabase, url: string): Option[BookmarkItem] =
  ## URLからブックマークを検索
  let row = bm.db.getRow(sql"SELECT * FROM bookmarks WHERE url = ? AND item_type = ? LIMIT 1", url, int(btUrl))
  if row[0] == "":
    return none(BookmarkItem)
  
  let item = loadBookmarkFromRow(row)
  
  # キーワードを読み込み
  item.keywords = bm.loadKeywords(item.id)
  
  # キャッシュに追加
  bm.cache[item.id] = item
  
  return some(item)

proc getRecentBookmarks*(bm: BookmarksDatabase, limit: int = 10): seq[BookmarkItem] =
  ## 最近追加したブックマークを取得
  result = @[]
  let recentIds = bm.recentBookmarks
  
  for id in recentIds:
    let bookmarkOpt = bm.getBookmark(id)
    if bookmarkOpt.isSome:
      result.add(bookmarkOpt.get())
      
      # 制限に達したら終了
      if result.len >= limit:
        break
  
  # 最近のIDリストにないものも取得
  if result.len < limit:
    let rows = bm.db.getAllRows(sql"""
      SELECT * FROM bookmarks 
      WHERE item_type = ? 
      ORDER BY date_added DESC 
      LIMIT ?
    """, int(btUrl), limit * 2)
    
    for row in rows:
      let item = loadBookmarkFromRow(row)
      
      # すでに含まれているかチェック
      var exists = false
      for existing in result:
        if existing.id == item.id:
          exists = true
          break
      
      if not exists:
        # キーワードを読み込み
        item.keywords = bm.loadKeywords(item.id)
        
        # キャッシュに追加
        bm.cache[item.id] = item
        
        result.add(item)
        
        # 制限に達したら終了
        if result.len >= limit:
          break

proc getMostVisitedBookmarks*(bm: BookmarksDatabase, limit: int = 10): seq[BookmarkItem] =
  ## 最も訪問回数の多いブックマークを取得
  result = @[]
  
  let rows = bm.db.getAllRows(sql"""
    SELECT * FROM bookmarks 
    WHERE item_type = ? AND visit_count > 0
    ORDER BY visit_count DESC 
    LIMIT ?
  """, int(btUrl), limit)
  
  for row in rows:
    let item = loadBookmarkFromRow(row)
    
    # キーワードを読み込み
    item.keywords = bm.loadKeywords(item.id)
    
    # キャッシュに追加
    bm.cache[item.id] = item
    
    result.add(item)

#----------------------------------------
# インポート/エクスポート
#----------------------------------------

proc exportToJson*(bm: BookmarksDatabase): JsonNode =
  ## ブックマークをJSONに出力
  result = newJObject()
  
  # メタデータ
  var meta = newJObject()
  meta["version"] = %1
  meta["date"] = %($getTime())
  meta["type"] = %"bookmarks"
  result["meta"] = meta
  
  # ルートフォルダを取得
  let rootOpt = bm.getBookmark(ROOT_BOOKMARK_ID)
  if rootOpt.isNone:
    return result
  
  # 再帰的にブックマークをJSONに変換する関数
  proc convertToJson(itemId: string): JsonNode =
    let itemOpt = bm.getBookmark(itemId)
    if itemOpt.isNone:
      return newJNull()
    
    let item = itemOpt.get()
    var itemJson = newJObject()
    
    # 共通プロパティ
    itemJson["id"] = %item.id
    itemJson["title"] = %item.title
    if item.parentId.isSome:
      itemJson["parentId"] = %item.parentId.get()
    itemJson["position"] = %item.position
    itemJson["dateAdded"] = %($item.dateAdded)
    itemJson["dateModified"] = %($item.dateModified)
    
    # タイプ別プロパティ
    case item.itemType
    of btUrl:
      itemJson["type"] = %"url"
      itemJson["url"] = %item.url
      if item.iconUrl.isSome:
        itemJson["iconUrl"] = %item.iconUrl.get()
      itemJson["visitCount"] = %item.visitCount
      
      var keywords = newJArray()
      for keyword in item.keywords:
        keywords.add(%keyword)
      itemJson["keywords"] = keywords
      
    of btFolder:
      itemJson["type"] = %"folder"
      
      var children = newJArray()
      for childId in item.children:
        children.add(convertToJson(childId))
      itemJson["children"] = children
      
    of btSeparator:
      itemJson["type"] = %"separator"
    
    return itemJson
  
  # ルートから始めて全ブックマークを出力
  result["bookmarks"] = convertToJson(ROOT_BOOKMARK_ID)
  
  return result

proc exportToHtml*(bm: BookmarksDatabase): string =
  ## ブックマークをNetscape HTML形式に出力
  result = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
"""
  
  # 再帰的にブックマークをHTML形式に変換する関数
  proc convertToHtml(itemId: string, indent: int): string =
    let indentStr = "    ".repeat(indent)
    let itemOpt = bm.getBookmark(itemId)
    if itemOpt.isNone:
      return ""
    
    let item = itemOpt.get()
    
    case item.itemType
    of btUrl:
      result = indentStr & "<DT><A HREF=\"" & item.url & "\""
      if item.dateAdded != Time():
        result &= " ADD_DATE=\"" & $item.dateAdded.toUnix() & "\""
      if item.visitCount > 0:
        result &= " LAST_VISIT=\"" & $item.dateModified.toUnix() & "\""
      result &= ">" & xmlEncode(item.title) & "</A>\n"
      
    of btFolder:
      result = indentStr & "<DT><H3"
      if item.dateAdded != Time():
        result &= " ADD_DATE=\"" & $item.dateAdded.toUnix() & "\""
      if item.dateModified != Time():
        result &= " LAST_MODIFIED=\"" & $item.dateModified.toUnix() & "\""
      result &= ">" & xmlEncode(item.title) & "</H3>\n"
      result &= indentStr & "<DL><p>\n"
      
      for childId in item.children:
        result &= convertToHtml(childId, indent + 1)
      
      result &= indentStr & "</DL><p>\n"
      
    of btSeparator:
      result = indentStr & "<HR>\n"
  
  # ルートフォルダの内容を出力
  let rootOpt = bm.getBookmark(ROOT_BOOKMARK_ID)
  if rootOpt.isSome:
    for childId in rootOpt.get().children:
      result &= convertToHtml(childId, 1)
  
  result &= "</DL><p>\n"
  
  return result

proc importFromJson*(bm: BookmarksDatabase, json: JsonNode): bool =
  ## JSONからブックマークをインポート
  if not json.hasKey("bookmarks"):
    return false
  
  # トランザクション開始
  bm.db.exec(sql"BEGIN TRANSACTION")
  
  try:
    # ルート要素がすでに存在するか確認
    if json["bookmarks"].hasKey("type") and json["bookmarks"]["type"].getStr() == "folder":
      let rootData = json["bookmarks"]
      
      # 再帰的にJSONからブックマークをインポートする関数
      proc importItem(data: JsonNode, parentId: string): string =
        if not data.hasKey("type"):
          return ""
        
        let itemType = data["type"].getStr()
        var id = ""
        
        case itemType
        of "url":
          let title = data["title"].getStr()
          let url = data["url"].getStr()
          var iconUrl = ""
          
          if data.hasKey("iconUrl"):
            iconUrl = data["iconUrl"].getStr()
          
          id = bm.createBookmark(title, url, parentId, -1, iconUrl)
          
          # キーワードが設定されている場合は追加
          if data.hasKey("keywords") and data["keywords"].kind == JArray:
            for keyword in data["keywords"]:
              if keyword.kind == JString:
                discard bm.addKeyword(id, keyword.getStr())
          
          # 訪問回数が設定されている場合は更新
          if data.hasKey("visitCount") and data["visitCount"].kind == JInt:
            let count = data["visitCount"].getInt()
            bm.db.exec(sql"UPDATE bookmarks SET visit_count = ? WHERE id = ?", count, id)
            
            # キャッシュ更新
            let itemOpt = bm.getBookmark(id)
            if itemOpt.isSome:
              var updatedItem = itemOpt.get()
              updatedItem.visitCount = count
              bm.cache[id] = updatedItem
          
        of "folder":
          let title = data["title"].getStr()
          id = bm.createFolder(title, parentId)
          
          # 子要素が設定されている場合は再帰的に処理
          if data.hasKey("children") and data["children"].kind == JArray:
            for child in data["children"]:
              discard importItem(child, id)
          
        of "separator":
          id = bm.createSeparator(parentId)
        
        else:
          return ""
        
        return id
      
      # 既存のブックマークを保持するかどうかを判定
      let menuOpt = bm.getBookmark(MENU_FOLDER_ID)
      let toolbarOpt = bm.getBookmark(TOOLBAR_FOLDER_ID)
      let otherOpt = bm.getBookmark(OTHER_FOLDER_ID)
      
      if rootData.hasKey("children") and rootData["children"].kind == JArray:
        for child in rootData["children"]:
          if child.hasKey("id"):
            let childId = child["id"].getStr()
            
            # 標準フォルダの内容を置き換える
            if childId.startsWith("menu") and menuOpt.isSome:
              # メニューフォルダの内容を置き換え
              let menuFolder = menuOpt.get()
              
              # 既存の内容を削除
              for oldChildId in menuFolder.children:
                discard bm.deleteItem(oldChildId)
              
              # 新しい内容をインポート
              if child.hasKey("children") and child["children"].kind == JArray:
                for grandchild in child["children"]:
                  discard importItem(grandchild, MENU_FOLDER_ID)
            
            elif childId.startsWith("toolbar") and toolbarOpt.isSome:
              # ツールバーフォルダの内容を置き換え
              let toolbarFolder = toolbarOpt.get()
              
              # 既存の内容を削除
              for oldChildId in toolbarFolder.children:
                discard bm.deleteItem(oldChildId)
              
              # 新しい内容をインポート
              if child.hasKey("children") and child["children"].kind == JArray:
                for grandchild in child["children"]:
                  discard importItem(grandchild, TOOLBAR_FOLDER_ID)
            
            elif childId.startsWith("other") and otherOpt.isSome:
              # その他フォルダの内容を置き換え
              let otherFolder = otherOpt.get()
              
              # 既存の内容を削除
              for oldChildId in otherFolder.children:
                discard bm.deleteItem(oldChildId)
              
              # 新しい内容をインポート
              if child.hasKey("children") and child["children"].kind == JArray:
                for grandchild in child["children"]:
                  discard importItem(grandchild, OTHER_FOLDER_ID)
            else:
              # その他のアイテムはメニューフォルダに追加
              discard importItem(child, MENU_FOLDER_ID)
          else:
            # IDがない場合はメニューフォルダに追加
            discard importItem(child, MENU_FOLDER_ID)
    
    # トランザクションをコミット
    bm.db.exec(sql"COMMIT")
    return true
  except:
    # エラー発生時はロールバック
    bm.db.exec(sql"ROLLBACK")
    return false

proc importFromHtml*(bm: BookmarksDatabase, html: string): bool =
  ## Netscape HTML形式からブックマークをインポート
  # 簡易的なHTMLパーサーを使用
  try:
    var parser = "<html><body>" & html & "</body></html>"
    
    # トランザクション開始
    bm.db.exec(sql"BEGIN TRANSACTION")
    
    # 再帰的にHTMLからブックマークをインポートする関数
    proc processNode(node: XmlNode, parentId: string): bool =
      for child in node:
        case child.tag
        of "dt":
          for dtChild in child:
            if dtChild.tag == "a" and dtChild.attrs.hasKey("href"):
              let url = dtChild.attrs["href"]
              let title = if dtChild.innerText.len > 0: dtChild.innerText else: url
              
              var dateAdded = getTime()
              if dtChild.attrs.hasKey("add_date"):
                try:
                  dateAdded = fromUnix(parseInt(dtChild.attrs["add_date"]))
                except: discard
              
              let bookmarkId = bm.createBookmark(title, url, parentId)
              
              # 日付を設定
              bm.db.exec(sql"UPDATE bookmarks SET date_added = ? WHERE id = ?", dateAdded.toUnix(), bookmarkId)
              
              # キャッシュ更新
              let bookmarkOpt = bm.getBookmark(bookmarkId)
              if bookmarkOpt.isSome:
                var updatedBookmark = bookmarkOpt.get()
                updatedBookmark.dateAdded = dateAdded
                bm.cache[bookmarkId] = updatedBookmark
            
            elif dtChild.tag == "h3":
              let title = if dtChild.innerText.len > 0: dtChild.innerText else: "フォルダ"
              
              var dateAdded = getTime()
              if dtChild.attrs.hasKey("add_date"):
                try:
                  dateAdded = fromUnix(parseInt(dtChild.attrs["add_date"]))
                except: discard
              
              var dateModified = getTime()
              if dtChild.attrs.hasKey("last_modified"):
                try:
                  dateModified = fromUnix(parseInt(dtChild.attrs["last_modified"]))
                except: discard
              
              let folderId = bm.createFolder(title, parentId)
              
              # 日付を設定
              bm.db.exec(sql"""
                UPDATE bookmarks 
                SET date_added = ?, date_modified = ?
                WHERE id = ?
              """, dateAdded.toUnix(), dateModified.toUnix(), folderId)
              
              # キャッシュ更新
              let folderOpt = bm.getBookmark(folderId)
              if folderOpt.isSome:
                var updatedFolder = folderOpt.get()
                updatedFolder.dateAdded = dateAdded
                updatedFolder.dateModified = dateModified
                bm.cache[folderId] = updatedFolder
              
              # 次のDLを処理
              for sibling in child:
                if sibling.tag == "dl":
                  discard processNode(sibling, folderId)
        
        of "dl":
          discard processNode(child, parentId)
        
        of "hr":
          discard bm.createSeparator(parentId)
        
        else:
          continue
      
      return true
    
    # HTMLをパース
    let doc = parseHtml(parser)
    
    # ブックマークをメニューフォルダにインポート
    discard processNode(doc, MENU_FOLDER_ID)
    
    # トランザクションをコミット
    bm.db.exec(sql"COMMIT")
    return true
  except:
    # エラー発生時はロールバック
    bm.db.exec(sql"ROLLBACK")
    return false

#----------------------------------------
# ユーティリティ関数
#----------------------------------------

proc xmlEncode*(s: string): string =
  ## XML特殊文字をエスケープ
  result = s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")

proc close*(bm: BookmarksDatabase) =
  ## データベース接続を閉じる
  bm.db.close()
  bm.logger.info("ブックマークデータベースを閉じました")

when isMainModule:
  # テスト用コード
  echo "ブックマーク機能のテスト"
  
  let dbPath = getTempDir() / "test_bookmarks.db"
  if fileExists(dbPath):
    removeFile(dbPath)
  
  let bm = newBookmarksDatabase(dbPath)
  
  # 基本的なブックマーク操作のテスト
  let folderId = bm.createFolder("テストフォルダ", MENU_FOLDER_ID)
  echo "フォルダ作成: ", folderId
  
  let bookmark1 = bm.createBookmark("テストブックマーク1", "https://example.com", folderId)
  echo "ブックマーク作成: ", bookmark1
  
  let bookmark2 = bm.createBookmark("テストブックマーク2", "https://example.org", folderId)
  echo "ブックマーク作成: ", bookmark2
  
  let sepId = bm.createSeparator(folderId)
  echo "区切り線作成: ", sepId
  
  # フォルダの内容を取得
  let contents = bm.getFolderContents(folderId)
  echo "フォルダの内容: ", contents.len, " アイテム"
  
  for item in contents:
    echo "  ", item.title, " (", item.itemType, ")"
  
  # ブックマークを更新
  discard bm.updateBookmark(bookmark1, "更新されたブックマーク", "https://example.com/updated")
  
  # フォルダを更新
  discard bm.updateFolder(folderId, "更新されたフォルダ")
  
  # キーワードを追加
  discard bm.addKeyword(bookmark1, "テスト")
  discard bm.addKeyword(bookmark1, "サンプル")
  
  # 検索
  let searchResults = bm.searchBookmarks(SearchOptions(
    query: "テスト",
    caseSensitive: false,
    searchUrls: true,
    searchTags: true,
    maxResults: 10,
    excludeFolders: false
  ))
  
  echo "検索結果: ", searchResults.len, " アイテム"
  for item in searchResults:
    echo "  ", item.title
  
  # エクスポート
  let jsonData = bm.exportToJson()
  echo "JSONエクスポート: ", jsonData.len, " バイト"
  
  let htmlData = bm.exportToHtml()
  echo "HTMLエクスポート: ", htmlData.len, " バイト"
  
  # クリーンアップ
  bm.close()
  removeFile(dbPath)
  echo "テスト完了" 