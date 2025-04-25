require "json"
require "sqlite3"

module QuantumCore
  # 履歴エントリクラス
  class HistoryEntry
    include JSON::Serializable
    
    property id : Int64
    property url : String
    property title : String
    property visit_time : Time
    property visit_count : Int32
    property last_visit_time : Time
    
    def initialize(@url : String, @title : String, @visit_time : Time, @visit_count : Int32 = 1, @last_visit_time : Time? = nil, @id : Int64 = -1)
      @last_visit_time = @last_visit_time || @visit_time
    end
    
    # JSONシリアライズのためのカスタムトゥーJSON
    def to_json(json : JSON::Builder)
      json.object do
        json.field "id", @id
        json.field "url", @url
        json.field "title", @title
        json.field "visit_time", @visit_time.to_unix
        json.field "visit_count", @visit_count
        json.field "last_visit_time", @last_visit_time.to_unix
      end
    end
    
    # JSONデシリアライズのためのカスタムフロムJSON
    def self.from_json(json_object : JSON::Any) : HistoryEntry
      id = json_object["id"].as_i64
      url = json_object["url"].as_s
      title = json_object["title"].as_s
      visit_time = Time.unix(json_object["visit_time"].as_i64)
      visit_count = json_object["visit_count"].as_i
      last_visit_time = Time.unix(json_object["last_visit_time"].as_i64)
      
      HistoryEntry.new(url, title, visit_time, visit_count, last_visit_time, id)
    end
  end
  
  # 履歴管理クラス
  class HistoryManager
    DATABASE_FILE = "browser_history.db"
    MAX_HISTORY_ENTRIES = 10000
    
    @db : DB::Database
    @entries_cache : Hash(String, HistoryEntry) = {} of String => HistoryEntry
    @cache_loaded : Bool = false
    @storage_manager : StorageManager
    
    # 履歴エントリ数を取得するゲッター
    def entry_count : Int32
      ensure_cache_loaded
      @entries_cache.size
    end
    
    # 推定サイズを計算するメソッド（バイト単位）
    def estimated_size : Int64
      ensure_cache_loaded
      size : Int64 = 0
      
      @entries_cache.each do |url, entry|
        # URLとタイトルのサイズを計算
        size += url.bytesize
        size += entry.title.bytesize
        
        # その他のフィールドのサイズを追加（推定値）
        size += 8 * 3 # id, visit_time, last_visit_time (8バイトずつ)
        size += 4     # visit_count (4バイト)
      end
      
      size
    end
    
    def initialize(@storage_manager : StorageManager)
      # SQLiteデータベースを開く
      @db = DB.open("sqlite3://#{DATABASE_FILE}")
      
      # テーブルが存在しない場合は作成
      create_tables
    end
    
    # テーブルを作成
    private def create_tables
      @db.exec "CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        visit_time INTEGER NOT NULL,
        visit_count INTEGER NOT NULL DEFAULT 1,
        last_visit_time INTEGER NOT NULL
      )"
      
      # インデックスを作成
      @db.exec "CREATE INDEX IF NOT EXISTS idx_history_url ON history (url)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_history_visit_time ON history (visit_time DESC)"
      @db.exec "CREATE INDEX IF NOT EXISTS idx_history_last_visit_time ON history (last_visit_time DESC)"
    end
    
    # キャッシュが読み込まれていることを確認
    private def ensure_cache_loaded
      return if @cache_loaded
      
      load_cache
    end
    
    # キャッシュを読み込む
    private def load_cache
      @entries_cache.clear
      
      @db.query "SELECT id, url, title, visit_time, visit_count, last_visit_time FROM history ORDER BY last_visit_time DESC" do |rs|
        rs.each do
          id = rs.read(Int64)
          url = rs.read(String)
          title = rs.read(String)
          visit_time = Time.unix(rs.read(Int64))
          visit_count = rs.read(Int32)
          last_visit_time = Time.unix(rs.read(Int64))
          
          entry = HistoryEntry.new(url, title, visit_time, visit_count, last_visit_time, id)
          @entries_cache[url] = entry
        end
      end
      
      @cache_loaded = true
    end
    
    # 閲覧履歴を追加
    def add_visit(url : String, title : String) : HistoryEntry
      ensure_cache_loaded
      
      current_time = Time.utc
      
      if existing_entry = @entries_cache[url]?
        # 既存のエントリを更新
        existing_entry.visit_count += 1
        existing_entry.last_visit_time = current_time
        
        # データベースを更新
        @db.exec "UPDATE history SET visit_count = ?, last_visit_time = ?, title = ? WHERE id = ?",
          existing_entry.visit_count, existing_entry.last_visit_time.to_unix, title, existing_entry.id
        
        # 履歴更新イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::HISTORY_UPDATED,
          data: {
            "url" => url,
            "title" => title
          }
        ))
        
        return existing_entry
      else
        # 新しいエントリを作成
        entry = HistoryEntry.new(url, title, current_time)
        
        # データベースに挿入
        @db.exec "INSERT INTO history (url, title, visit_time, visit_count, last_visit_time) VALUES (?, ?, ?, ?, ?)",
          url, title, current_time.to_unix, 1, current_time.to_unix
        
        # 生成されたIDを取得
        entry.id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
        
        # キャッシュに追加
        @entries_cache[url] = entry
        
        # 最大エントリ数を超えた場合、古いエントリを削除
        prune_old_entries if @entries_cache.size > MAX_HISTORY_ENTRIES
        
        # 履歴更新イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::HISTORY_UPDATED,
          data: {
            "url" => url,
            "title" => title
          }
        ))
        
        return entry
      end
    end
    
    # 古いエントリを削除
    private def prune_old_entries
      # 最大数を超えた分を削除
      entries_to_remove = @entries_cache.size - MAX_HISTORY_ENTRIES
      return if entries_to_remove <= 0
      
      # 訪問時間でソートし、古い順に削除対象を選択
      entries_to_delete = @entries_cache.values
        .sort_by(&.last_visit_time)
        .first(entries_to_remove)
      
      entries_to_delete.each do |entry|
        delete_entry(entry.id)
      end
    end
    
    # エントリを削除
    def delete_entry(id : Int64) : Bool
      ensure_cache_loaded
      
      # IDからURLを探す
      url_to_delete = nil
      @entries_cache.each do |url, entry|
        if entry.id == id
          url_to_delete = url
          break
        end
      end
      
      return false unless url_to_delete
      
      # データベースから削除
      @db.exec "DELETE FROM history WHERE id = ?", id
      
      # キャッシュから削除
      @entries_cache.delete(url_to_delete)
      
      true
    end
    
    # URLでエントリを検索
    def find_by_url(url : String) : HistoryEntry?
      ensure_cache_loaded
      @entries_cache[url]?
    end
    
    # タイトルでエントリを検索（部分一致）
    def search_by_title(query : String, limit : Int32 = 10) : Array(HistoryEntry)
      ensure_cache_loaded
      
      query_pattern = /%#{query.downcase}%/
      
      @entries_cache.values
        .select { |entry| entry.title.downcase.includes?(query.downcase) }
        .sort_by(&.last_visit_time)
        .reverse
        .first(limit)
    end
    
    # URLでエントリを検索（部分一致）
    def search_by_url(query : String, limit : Int32 = 10) : Array(HistoryEntry)
      ensure_cache_loaded
      
      @entries_cache.values
        .select { |entry| entry.url.downcase.includes?(query.downcase) }
        .sort_by(&.last_visit_time)
        .reverse
        .first(limit)
    end
    
    # 期間で検索
    def search_by_date_range(start_time : Time, end_time : Time, limit : Int32 = 100) : Array(HistoryEntry)
      ensure_cache_loaded
      
      @entries_cache.values
        .select { |entry| entry.last_visit_time >= start_time && entry.last_visit_time <= end_time }
        .sort_by(&.last_visit_time)
        .reverse
        .first(limit)
    end
    
    # 最近の履歴を取得
    def get_recent_history(limit : Int32 = 20) : Array(HistoryEntry)
      ensure_cache_loaded
      
      @entries_cache.values
        .sort_by(&.last_visit_time)
        .reverse
        .first(limit)
    end
    
    # よく訪問するサイトを取得
    def get_most_visited(limit : Int32 = 10) : Array(HistoryEntry)
      ensure_cache_loaded
      
      @entries_cache.values
        .sort_by(&.visit_count)
        .reverse
        .first(limit)
    end
    
    # 履歴を消去
    def clear
      # データベースからすべての履歴を削除
      @db.exec "DELETE FROM history"
      
      # キャッシュをクリア
      @entries_cache.clear
      @cache_loaded = true
    end
    
    # 特定の期間の履歴を削除
    def clear_range(start_time : Time, end_time : Time)
      # データベースから期間内の履歴を削除
      @db.exec "DELETE FROM history WHERE last_visit_time >= ? AND last_visit_time <= ?",
        start_time.to_unix, end_time.to_unix
      
      # キャッシュを更新
      load_cache
    end
    
    # 履歴をファイルにエクスポート
    def export(file_path : String) : Bool
      ensure_cache_loaded
      
      begin
        entries = @entries_cache.values
        json_data = entries.to_json
        
        File.write(file_path, json_data)
        return true
      rescue ex
        Log.error { "履歴のエクスポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # 履歴をファイルからインポート
    def import(file_path : String) : Bool
      begin
        json_data = File.read(file_path)
        entries = Array(HistoryEntry).from_json(json_data)
        
        # インポートする前に一時的にトランザクションを開始
        @db.transaction do |tx|
          entries.each do |entry|
            # 既存のエントリがあるか確認
            existing = @db.query_one? "SELECT id, visit_count FROM history WHERE url = ?", entry.url, as: {Int64, Int32}
            
            if existing
              id, visit_count = existing
              # 既存のエントリを更新
              @db.exec "UPDATE history SET visit_count = ?, last_visit_time = ? WHERE id = ?",
                visit_count + entry.visit_count, entry.last_visit_time.to_unix, id
            else
              # 新しいエントリを挿入
              @db.exec "INSERT INTO history (url, title, visit_time, visit_count, last_visit_time) VALUES (?, ?, ?, ?, ?)",
                entry.url, entry.title, entry.visit_time.to_unix, entry.visit_count, entry.last_visit_time.to_unix
            end
          end
        end
        
        # キャッシュを更新
        load_cache
        
        return true
      rescue ex
        Log.error { "履歴のインポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # データを保存（キャッシュを同期）
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