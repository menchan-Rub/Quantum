require "json"
require "sqlite3"

module QuantumCore
  # ブックマークフォルダクラス
  class BookmarkFolder
    include JSON::Serializable
    
    property id : Int64
    property title : String
    property parent_id : Int64?
    property created_at : Time
    property modified_at : Time
    property children : Array(BookmarkFolder | Bookmark)
    
    def initialize(@title : String, @parent_id : Int64? = nil, @id : Int64 = -1, @created_at : Time = Time.utc, @modified_at : Time = Time.utc)
      @children = [] of (BookmarkFolder | Bookmark)
    end
    
    # JSONシリアライズのためのカスタムトゥーJSON
    def to_json(json : JSON::Builder)
      json.object do
        json.field "id", @id
        json.field "title", @title
        json.field "parent_id", @parent_id
        json.field "created_at", @created_at.to_unix
        json.field "modified_at", @modified_at.to_unix
        json.field "type", "folder"
        json.field "children" do
          json.array do
            @children.each do |child|
              child.to_json(json)
            end
          end
        end
      end
    end
  end
  
  # ブックマークエントリクラス
  class Bookmark
    include JSON::Serializable
    
    property id : Int64
    property url : String
    property title : String
    property favicon : String?
    property parent_id : Int64?
    property created_at : Time
    property modified_at : Time
    property tags : Array(String)
    
    def initialize(@url : String, @title : String, @parent_id : Int64? = nil, @favicon : String? = nil, @id : Int64 = -1, @created_at : Time = Time.utc, @modified_at : Time = Time.utc)
      @tags = [] of String
    end
    
    # JSONシリアライズのためのカスタムトゥーJSON
    def to_json(json : JSON::Builder)
      json.object do
        json.field "id", @id
        json.field "url", @url
        json.field "title", @title
        json.field "favicon", @favicon
        json.field "parent_id", @parent_id
        json.field "created_at", @created_at.to_unix
        json.field "modified_at", @modified_at.to_unix
        json.field "type", "bookmark"
        json.field "tags", @tags
      end
    end
  end
  
  # JSONデシリアライズのためのヘルパーモジュール
  module BookmarkDeserializer
    def self.from_json(json_object : JSON::Any) : BookmarkFolder | Bookmark
      type = json_object["type"].as_s
      
      if type == "folder"
        folder = BookmarkFolder.new(
          title: json_object["title"].as_s,
          parent_id: json_object["parent_id"]?.try &.as_i64?,
          id: json_object["id"].as_i64,
          created_at: Time.unix(json_object["created_at"].as_i64),
          modified_at: Time.unix(json_object["modified_at"].as_i64)
        )
        
        if json_object["children"]?
          json_object["children"].as_a.each do |child_json|
            folder.children << from_json(child_json)
          end
        end
        
        return folder
      else
        bookmark = Bookmark.new(
          url: json_object["url"].as_s,
          title: json_object["title"].as_s,
          parent_id: json_object["parent_id"]?.try &.as_i64?,
          favicon: json_object["favicon"]?.try &.as_s?,
          id: json_object["id"].as_i64,
          created_at: Time.unix(json_object["created_at"].as_i64),
          modified_at: Time.unix(json_object["modified_at"].as_i64)
        )
        
        if json_object["tags"]?
          bookmark.tags = json_object["tags"].as_a.map(&.as_s)
        end
        
        return bookmark
      end
    end
  end
  
  # ブックマーク管理クラス
  class BookmarkManager
    DATABASE_FILE = "browser_bookmarks.db"
    
    @db : DB::Database
    @root_folder : BookmarkFolder
    @bookmarks_by_id : Hash(Int64, Bookmark) = {} of Int64 => Bookmark
    @folders_by_id : Hash(Int64, BookmarkFolder) = {} of Int64 => BookmarkFolder
    @bookmarks_by_url : Hash(String, Bookmark) = {} of String => Bookmark
    @initialized : Bool = false
    @storage_manager : StorageManager
    
    # ブックマークエントリ数を取得するゲッター
    def entry_count : Int32
      initialize_if_needed
      @bookmarks_by_id.size
    end
    
    # 推定サイズを計算するメソッド（バイト単位）
    def estimated_size : Int64
      initialize_if_needed
      size : Int64 = 0
      
      # ブックマークのサイズを計算
      @bookmarks_by_id.each_value do |bookmark|
        size += bookmark.url.bytesize
        size += bookmark.title.bytesize
        size += bookmark.favicon.try(&.bytesize) || 0
        
        # タグのサイズを追加
        bookmark.tags.each do |tag|
          size += tag.bytesize
        end
        
        # その他のフィールドのサイズを追加（推定値）
        size += 8 * 3 # id, created_at, modified_at (8バイトずつ)
        size += 8     # parent_id (8バイト)
      end
      
      # フォルダのサイズを計算
      @folders_by_id.each_value do |folder|
        size += folder.title.bytesize
        
        # その他のフィールドのサイズを追加（推定値）
        size += 8 * 3 # id, created_at, modified_at (8バイトずつ)
        size += 8     # parent_id (8バイト)
      end
      
      size
    end
    
    def initialize(@storage_manager : StorageManager)
      # SQLiteデータベースを開く
      @db = DB.open("sqlite3://#{DATABASE_FILE}")
      
      # ルートフォルダを作成
      @root_folder = BookmarkFolder.new("Root", nil, 0)
      @folders_by_id[0] = @root_folder
      
      # テーブルが存在しない場合は作成
      create_tables
      
      # 初期データをロード
      load_data
    end
    
    # テーブルを作成
    private def create_tables
      # ブックマークフォルダテーブル
      @db.exec "CREATE TABLE IF NOT EXISTS bookmark_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        parent_id INTEGER,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        FOREIGN KEY (parent_id) REFERENCES bookmark_folders(id) ON DELETE CASCADE
      )"
      
      # ブックマークテーブル
      @db.exec "CREATE TABLE IF NOT EXISTS bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        favicon TEXT,
        parent_id INTEGER,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        FOREIGN KEY (parent_id) REFERENCES bookmark_folders(id) ON DELETE CASCADE
      )"
      
      # タグテーブル
      @db.exec "CREATE TABLE IF NOT EXISTS bookmark_tags (
        bookmark_id INTEGER NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY (bookmark_id, tag),
        FOREIGN KEY (bookmark_id) REFERENCES bookmarks(id) ON DELETE CASCADE
      )"
      
      # インデックスを作成
      @db.exec "CREATE INDEX IF NOT EXISTS idx_bookmarks_url ON bookmarks (url)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_bookmarks_parent_id ON bookmarks (parent_id)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_bookmark_folders_parent_id ON bookmark_folders (parent_id)"
    end
    
    # 初期化が必要な場合に初期化
    private def initialize_if_needed
      return if @initialized
      
      load_data
    end
    
    # データを読み込み
    private def load_data
      # ハッシュマップをクリア
      @bookmarks_by_id.clear
      @folders_by_id.clear
      @bookmarks_by_url.clear
      
      # ルートフォルダを再設定
      @root_folder = BookmarkFolder.new("Root", nil, 0)
      @folders_by_id[0] = @root_folder
      
      # まずすべてのフォルダを読み込む
      @db.query "SELECT id, title, parent_id, created_at, modified_at FROM bookmark_folders ORDER BY id" do |rs|
        rs.each do
          id = rs.read(Int64)
          title = rs.read(String)
          parent_id = rs.read(Int64?)
          created_at = Time.unix(rs.read(Int64))
          modified_at = Time.unix(rs.read(Int64))
          
          # IDが0のフォルダはルートフォルダなのでスキップ
          next if id == 0
          
          folder = BookmarkFolder.new(title, parent_id, id, created_at, modified_at)
          @folders_by_id[id] = folder
          
          # 親フォルダに追加
          if parent_id && @folders_by_id.has_key?(parent_id)
            @folders_by_id[parent_id].children << folder
          end
        end
      end
      
      # 次にブックマークを読み込む
      @db.query "SELECT id, url, title, favicon, parent_id, created_at, modified_at FROM bookmarks" do |rs|
        rs.each do
          id = rs.read(Int64)
          url = rs.read(String)
          title = rs.read(String)
          favicon = rs.read(String?)
          parent_id = rs.read(Int64?)
          created_at = Time.unix(rs.read(Int64))
          modified_at = Time.unix(rs.read(Int64))
          
          bookmark = Bookmark.new(url, title, parent_id, favicon, id, created_at, modified_at)
          
          # ブックマークをハッシュマップに追加
          @bookmarks_by_id[id] = bookmark
          @bookmarks_by_url[url] = bookmark
          
          # 親フォルダに追加
          if parent_id && @folders_by_id.has_key?(parent_id)
            @folders_by_id[parent_id].children << bookmark
          else
            # 親フォルダがない場合はルートフォルダに追加
            @root_folder.children << bookmark
          end
        end
      end
      
      # タグを読み込む
      @db.query "SELECT bookmark_id, tag FROM bookmark_tags" do |rs|
        rs.each do
          bookmark_id = rs.read(Int64)
          tag = rs.read(String)
          
          if @bookmarks_by_id.has_key?(bookmark_id)
            @bookmarks_by_id[bookmark_id].tags << tag
          end
        end
      end
      
      @initialized = true
    end
    
    # ブックマークを追加
    def add_bookmark(url : String, title : String, parent_id : Int64? = nil, favicon : String? = nil) : Bookmark
      initialize_if_needed
      
      # URLが既に存在するか確認
      if existing = @bookmarks_by_url[url]?
        # 既存のブックマークを更新
        existing.title = title
        existing.favicon = favicon
        existing.modified_at = Time.utc
        
        # データベースを更新
        @db.exec "UPDATE bookmarks SET title = ?, favicon = ?, modified_at = ? WHERE id = ?",
          title, favicon, existing.modified_at.to_unix, existing.id
        
        # ブックマーク更新イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::BOOKMARK_UPDATED,
          data: {
            "id" => existing.id.to_s,
            "url" => url,
            "title" => title
          }
        ))
        
        return existing
      end
      
      # 親フォルダが存在するか確認
      unless parent_id.nil? || @folders_by_id.has_key?(parent_id)
        parent_id = 0 # ルートフォルダを使用
      end
      
      # 現在の時刻
      current_time = Time.utc
      
      # 新しいブックマークを作成
      bookmark = Bookmark.new(
        url: url,
        title: title,
        parent_id: parent_id,
        favicon: favicon,
        created_at: current_time,
        modified_at: current_time
      )
      
      # データベースに挿入
      @db.exec "INSERT INTO bookmarks (url, title, favicon, parent_id, created_at, modified_at) VALUES (?, ?, ?, ?, ?, ?)",
        url, title, favicon, parent_id, current_time.to_unix, current_time.to_unix
      
      # 生成されたIDを取得
      bookmark.id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
      
      # ハッシュマップに追加
      @bookmarks_by_id[bookmark.id] = bookmark
      @bookmarks_by_url[url] = bookmark
      
      # 親フォルダに追加
      if parent_id && @folders_by_id.has_key?(parent_id)
        @folders_by_id[parent_id].children << bookmark
      else
        @root_folder.children << bookmark
      end
      
      # ブックマーク追加イベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::BOOKMARK_ADDED,
        data: {
          "id" => bookmark.id.to_s,
          "url" => url,
          "title" => title,
          "parent_id" => (parent_id || 0).to_s
        }
      ))
      
      bookmark
    end
    
    # ブックマークを削除
    def delete_bookmark(id : Int64) : Bool
      initialize_if_needed
      
      return false unless @bookmarks_by_id.has_key?(id)
      
      bookmark = @bookmarks_by_id[id]
      
      # データベースから削除
      @db.exec "DELETE FROM bookmarks WHERE id = ?", id
      
      # タグを削除
      @db.exec "DELETE FROM bookmark_tags WHERE bookmark_id = ?", id
      
      # 親フォルダから削除
      if parent_id = bookmark.parent_id
        if parent = @folders_by_id[parent_id]?
          parent.children.reject! { |child| child.is_a?(Bookmark) && child.id == id }
        end
      else
        @root_folder.children.reject! { |child| child.is_a?(Bookmark) && child.id == id }
      end
      
      # ハッシュマップから削除
      @bookmarks_by_url.delete(bookmark.url)
      @bookmarks_by_id.delete(id)
      
      # ブックマーク削除イベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::BOOKMARK_REMOVED,
        data: {
          "id" => id.to_s,
          "url" => bookmark.url,
          "title" => bookmark.title
        }
      ))
      
      true
    end
    
    # フォルダを作成
    def create_folder(title : String, parent_id : Int64? = nil) : BookmarkFolder
      initialize_if_needed
      
      # 親フォルダが存在するか確認
      unless parent_id.nil? || @folders_by_id.has_key?(parent_id)
        parent_id = 0 # ルートフォルダを使用
      end
      
      # 現在の時刻
      current_time = Time.utc
      
      # 新しいフォルダを作成
      folder = BookmarkFolder.new(
        title: title,
        parent_id: parent_id,
        created_at: current_time,
        modified_at: current_time
      )
      
      # データベースに挿入
      @db.exec "INSERT INTO bookmark_folders (title, parent_id, created_at, modified_at) VALUES (?, ?, ?, ?)",
        title, parent_id, current_time.to_unix, current_time.to_unix
      
      # 生成されたIDを取得
      folder.id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
      
      # ハッシュマップに追加
      @folders_by_id[folder.id] = folder
      
      # 親フォルダに追加
      if parent_id && @folders_by_id.has_key?(parent_id)
        @folders_by_id[parent_id].children << folder
      else
        @root_folder.children << folder
      end
      
      folder
    end
    
    # フォルダを削除（再帰的に削除）
    def delete_folder(id : Int64) : Bool
      initialize_if_needed
      
      # ルートフォルダは削除できない
      return false if id == 0
      
      return false unless @folders_by_id.has_key?(id)
      
      folder = @folders_by_id[id]
      
      # トランザクションを開始
      @db.transaction do |tx|
        # フォルダとその子を再帰的に削除
        delete_folder_recursive(folder)
      end
      
      # 親フォルダから削除
      if parent_id = folder.parent_id
        if parent = @folders_by_id[parent_id]?
          parent.children.reject! { |child| child.is_a?(BookmarkFolder) && child.id == id }
        end
      else
        @root_folder.children.reject! { |child| child.is_a?(BookmarkFolder) && child.id == id }
      end
      
      # ハッシュマップから削除
      @folders_by_id.delete(id)
      
      true
    end
    
    # フォルダを再帰的に削除
    private def delete_folder_recursive(folder : BookmarkFolder)
      # 子フォルダを再帰的に削除
      folder.children.each do |child|
        if child.is_a?(BookmarkFolder)
          delete_folder_recursive(child)
        elsif child.is_a?(Bookmark)
          # ブックマークを削除
          @db.exec "DELETE FROM bookmark_tags WHERE bookmark_id = ?", child.id
          @db.exec "DELETE FROM bookmarks WHERE id = ?", child.id
          
          # ハッシュマップから削除
          @bookmarks_by_url.delete(child.url)
          @bookmarks_by_id.delete(child.id)
          
          # ブックマーク削除イベントをディスパッチ
          @storage_manager.engine.dispatch_event(Event.new(
            type: EventType::BOOKMARK_REMOVED,
            data: {
              "id" => child.id.to_s,
              "url" => child.url,
              "title" => child.title
            }
          ))
        end
      end
      
      # フォルダを削除
      @db.exec "DELETE FROM bookmark_folders WHERE id = ?", folder.id
    end
    
    # ブックマークにタグを追加
    def add_tag(bookmark_id : Int64, tag : String) : Bool
      initialize_if_needed
      
      return false unless @bookmarks_by_id.has_key?(bookmark_id)
      
      bookmark = @bookmarks_by_id[bookmark_id]
      
      # すでにタグが存在する場合はスキップ
      return true if bookmark.tags.includes?(tag)
      
      # タグを追加
      bookmark.tags << tag
      
      # データベースに挿入
      @db.exec "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag) VALUES (?, ?)",
        bookmark_id, tag
      
      true
    end
    
    # ブックマークからタグを削除
    def remove_tag(bookmark_id : Int64, tag : String) : Bool
      initialize_if_needed
      
      return false unless @bookmarks_by_id.has_key?(bookmark_id)
      
      bookmark = @bookmarks_by_id[bookmark_id]
      
      # タグが存在しない場合はスキップ
      return true unless bookmark.tags.includes?(tag)
      
      # タグを削除
      bookmark.tags.delete(tag)
      
      # データベースから削除
      @db.exec "DELETE FROM bookmark_tags WHERE bookmark_id = ? AND tag = ?",
        bookmark_id, tag
      
      true
    end
    
    # URLでブックマークを検索
    def find_by_url(url : String) : Bookmark?
      initialize_if_needed
      @bookmarks_by_url[url]?
    end
    
    # IDでブックマークを検索
    def find_by_id(id : Int64) : Bookmark?
      initialize_if_needed
      @bookmarks_by_id[id]?
    end
    
    # タイトルでブックマークを検索（部分一致）
    def search_by_title(query : String, limit : Int32 = 10) : Array(Bookmark)
      initialize_if_needed
      
      @bookmarks_by_id.values
        .select { |bookmark| bookmark.title.downcase.includes?(query.downcase) }
        .sort_by(&.title)
        .first(limit)
    end
    
    # タグでブックマークを検索
    def search_by_tag(tag : String) : Array(Bookmark)
      initialize_if_needed
      
      @bookmarks_by_id.values
        .select { |bookmark| bookmark.tags.includes?(tag) }
        .sort_by(&.title)
    end
    
    # フォルダ内のブックマークを取得
    def get_bookmarks_in_folder(folder_id : Int64) : Array(Bookmark)
      initialize_if_needed
      
      if folder = @folders_by_id[folder_id]?
        return folder.children
          .select { |child| child.is_a?(Bookmark) }
          .map { |child| child.as(Bookmark) }
      end
      
      [] of Bookmark
    end
    
    # フォルダ内のサブフォルダを取得
    def get_subfolders(folder_id : Int64) : Array(BookmarkFolder)
      initialize_if_needed
      
      if folder = @folders_by_id[folder_id]?
        return folder.children
          .select { |child| child.is_a?(BookmarkFolder) }
          .map { |child| child.as(BookmarkFolder) }
      end
      
      [] of BookmarkFolder
    end
    
    # ルートフォルダを取得
    def get_root_folder : BookmarkFolder
      initialize_if_needed
      @root_folder
    end
    
    # ブックマークをすべて削除
    def clear
      # データベースからすべて削除
      @db.exec "DELETE FROM bookmark_tags"
      @db.exec "DELETE FROM bookmarks"
      @db.exec "DELETE FROM bookmark_folders WHERE id != 0"
      
      # メモリ上のデータをクリア
      load_data
    end
    
    # ブックマークをファイルにエクスポート
    def export(file_path : String) : Bool
      initialize_if_needed
      
      begin
        # ルートフォルダをJSON形式でエクスポート
        json_data = @root_folder.to_json
        
        File.write(file_path, json_data)
        return true
      rescue ex
        Log.error { "ブックマークのエクスポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # ブックマークをファイルからインポート
    def import(file_path : String) : Bool
      begin
        json_data = File.read(file_path)
        root_json = JSON.parse(json_data)
        
        # インポートする前に一時的にトランザクションを開始
        @db.transaction do |tx|
          if root_json["children"]?
            root_json["children"].as_a.each do |child_json|
              import_item(child_json, 0)
            end
          end
        end
        
        # データを再読み込み
        load_data
        
        return true
      rescue ex
        Log.error { "ブックマークのインポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # JSONデータからアイテムをインポート
    private def import_item(json_item : JSON::Any, parent_id : Int64)
      type = json_item["type"].as_s
      
      if type == "folder"
        # フォルダをインポート
        title = json_item["title"].as_s
        
        @db.exec "INSERT INTO bookmark_folders (title, parent_id, created_at, modified_at) VALUES (?, ?, ?, ?)",
          title, parent_id, Time.utc.to_unix, Time.utc.to_unix
        
        folder_id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
        
        # 子アイテムを再帰的にインポート
        if json_item["children"]?
          json_item["children"].as_a.each do |child_json|
            import_item(child_json, folder_id)
          end
        end
      else
        # ブックマークをインポート
        url = json_item["url"].as_s
        title = json_item["title"].as_s
        favicon = json_item["favicon"]?.try &.as_s?
        
        # 既存のブックマークがあるか確認
        existing = @db.query_one? "SELECT id FROM bookmarks WHERE url = ?", url, as: Int64
        
        if existing
          # 既存のブックマークを更新
          @db.exec "UPDATE bookmarks SET title = ?, favicon = ?, parent_id = ?, modified_at = ? WHERE id = ?",
            title, favicon, parent_id, Time.utc.to_unix, existing
          
          bookmark_id = existing
        else
          # 新しいブックマークを挿入
          @db.exec "INSERT INTO bookmarks (url, title, favicon, parent_id, created_at, modified_at) VALUES (?, ?, ?, ?, ?, ?)",
            url, title, favicon, parent_id, Time.utc.to_unix, Time.utc.to_unix
          
          bookmark_id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
        end
        
        # タグをインポート
        if json_item["tags"]?
          json_item["tags"].as_a.each do |tag_json|
            tag = tag_json.as_s
            @db.exec "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag) VALUES (?, ?)",
              bookmark_id, tag
          end
        end
      end
    end
    
    # データを保存
    def save
      # SQLiteデータベースは自動的に永続化されるため、特に何もする必要はない
      # ただし、念のためにデータベースの変更をディスクに強制的に書き込む
      @db.exec "PRAGMA wal_checkpoint(FULL)"
    end
    
    # データベース接続を閉じる
    def finalize
      @db.close
    end
  end
end 