require "json"
require "sqlite3"

module QuantumCore
  # 設定管理クラス
  class PreferencesManager
    DATABASE_FILE = "browser_preferences.db"
    
    # デフォルト設定の定義
    DEFAULT_PREFERENCES = {
      # 一般設定
      "homepage" => "about:home",
      "startup_mode" => "last_session", # "last_session", "homepage", "new_tab"
      "download_path" => "~/Downloads",
      "always_ask_download_location" => true,
      "restore_tabs_on_startup" => true,
      "default_search_engine" => "google",
      "show_bookmarks_bar" => true,
      "use_system_title_bar" => true,
      
      # プライバシー設定
      "enable_do_not_track" => true,
      "block_third_party_cookies" => false,
      "clear_history_on_exit" => false,
      "clear_cookies_on_exit" => false,
      "save_passwords" => true,
      "enable_autofill" => true,
      "incognito_mode_enabled" => false,
      
      # セキュリティ設定
      "enable_safe_browsing" => true,
      "warn_on_insecure_forms" => true,
      "enable_phishing_protection" => true,
      "enable_malware_protection" => true,
      
      # 同期設定
      "enable_sync" => false,
      "sync_bookmarks" => true,
      "sync_history" => true,
      "sync_passwords" => true,
      "sync_preferences" => true,
      "sync_interval_minutes" => 30,
      
      # 表示設定
      "theme" => "system", # "light", "dark", "system"
      "font_size" => 16,
      "font_family" => "Arial",
      "minimum_font_size" => 10,
      "page_zoom" => 100,
      "show_scrollbars" => true,
      "smooth_scrolling" => true,
      "enable_animations" => true,
      
      # パフォーマンス設定
      "hardware_acceleration" => true,
      "background_tabs_throttled" => true,
      "prefetch_pages" => true,
      "prerender_pages" => false,
      "memory_usage_limit_mb" => 0, # 0 = 無制限
      
      # 拡張機能設定
      "extensions_enabled" => true,
      "allow_incognito_extensions" => false,
      
      # 開発者設定
      "enable_developer_tools" => true,
      "enable_javascript_console" => true,
      "disable_cache" => false,
      "enable_gpu_debugging" => false,
      "user_agent_override" => ""
    }
    
    @db : DB::Database
    @preferences : Hash(String, JSON::Any) = {} of String => JSON::Any
    @modified : Bool = false
    @storage_manager : StorageManager
    
    # 推定サイズを計算するメソッド（バイト単位）
    def estimated_size : Int64
      size : Int64 = 0
      
      @preferences.each do |key, value|
        size += key.bytesize
        
        # 値のサイズを推定
        case value.raw
        when String
          size += value.as_s.bytesize
        when Int64, Int32, Float64
          size += 8
        when Bool
          size += 1
        when Array
          # 配列の要素ごとにサイズを推定
          value.as_a.each do |element|
            case element.raw
            when String
              size += element.as_s.bytesize
            when Int64, Int32, Float64
              size += 8
            when Bool
              size += 1
            end
          end
        when Hash
          # ハッシュの要素ごとにサイズを推定
          value.as_h.each do |k, v|
            size += k.bytesize
            case v.raw
            when String
              size += v.as_s.bytesize
            when Int64, Int32, Float64
              size += 8
            when Bool
              size += 1
            end
          end
        end
      end
      
      size
    end
    
    def initialize(@storage_manager : StorageManager)
      # SQLiteデータベースを開く
      @db = DB.open("sqlite3://#{DATABASE_FILE}")
      
      # テーブルが存在しない場合は作成
      create_tables
      
      # 設定を読み込む
      load
    end
    
    # テーブルを作成
    private def create_tables
      @db.exec "CREATE TABLE IF NOT EXISTS preferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        modified_at INTEGER NOT NULL
      )"
    end
    
    # 設定を読み込む
    def load
      @preferences.clear
      
      # デフォルト設定をロード
      DEFAULT_PREFERENCES.each do |key, value|
        @preferences[key] = JSON::Any.new(value)
      end
      
      # データベースから設定を読み込む
      @db.query "SELECT key, value FROM preferences" do |rs|
        rs.each do
          key = rs.read(String)
          value_str = rs.read(String)
          
          begin
            @preferences[key] = JSON.parse(value_str)
          rescue ex
            # JSON解析に失敗した場合は文字列として格納
            @preferences[key] = JSON::Any.new(value_str)
          end
        end
      end
      
      @modified = false
      
      # 設定読み込みイベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::PREFERENCES_CHANGED,
        data: {} of String => String
      ))
    end
    
    # 設定を保存
    def save
      return unless @modified
      
      # トランザクションを開始
      @db.transaction do |tx|
        # 各設定を保存
        @preferences.each do |key, value|
          # SQLiteの UPSERT 構文を使用
          @db.exec "INSERT INTO preferences (key, value, modified_at) VALUES (?, ?, ?) 
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, modified_at = excluded.modified_at",
            key, value.to_json, Time.utc.to_unix
        end
      end
      
      @modified = false
    end
    
    # 文字列設定を取得
    def get_string(key : String, default : String = "") : String
      if value = @preferences[key]?
        case value.raw
        when String
          return value.as_s
        else
          # 型が違う場合は文字列に変換して返す
          return value.to_s
        end
      end
      
      default
    end
    
    # 整数設定を取得
    def get_int(key : String, default : Int32 = 0) : Int32
      if value = @preferences[key]?
        case value.raw
        when Int64
          return value.as_i.to_i32
        when Int32
          return value.as_i
        when String
          # 文字列からの変換を試みる
          return value.as_s.to_i32? || default
        when Float64
          return value.as_f.to_i32
        end
      end
      
      default
    end
    
    # 浮動小数点設定を取得
    def get_float(key : String, default : Float64 = 0.0) : Float64
      if value = @preferences[key]?
        case value.raw
        when Float64
          return value.as_f
        when Int64, Int32
          return value.as_i.to_f64
        when String
          # 文字列からの変換を試みる
          return value.as_s.to_f64? || default
        end
      end
      
      default
    end
    
    # 真偽値設定を取得
    def get_bool(key : String, default : Bool = false) : Bool
      if value = @preferences[key]?
        case value.raw
        when Bool
          return value.as_bool
        when Int64, Int32
          return value.as_i != 0
        when String
          # 文字列からの変換を試みる
          str = value.as_s.downcase
          return str == "true" || str == "yes" || str == "1" || str == "on"
        end
      end
      
      default
    end
    
    # 配列設定を取得
    def get_array(key : String, default : Array(JSON::Any) = [] of JSON::Any) : Array(JSON::Any)
      if value = @preferences[key]?
        case value.raw
        when Array
          return value.as_a
        end
      end
      
      default
    end
    
    # オブジェクト設定を取得
    def get_object(key : String, default : Hash(String, JSON::Any) = {} of String => JSON::Any) : Hash(String, JSON::Any)
      if value = @preferences[key]?
        case value.raw
        when Hash
          return value.as_h
        end
      end
      
      default
    end
    
    # 文字列設定を設定
    def set_string(key : String, value : String)
      @preferences[key] = JSON::Any.new(value)
      @modified = true
      
      dispatch_preference_changed_event(key, value)
    end
    
    # 整数設定を設定
    def set_int(key : String, value : Int32)
      @preferences[key] = JSON::Any.new(value.to_i64)
      @modified = true
      
      dispatch_preference_changed_event(key, value.to_s)
    end
    
    # 浮動小数点設定を設定
    def set_float(key : String, value : Float64)
      @preferences[key] = JSON::Any.new(value)
      @modified = true
      
      dispatch_preference_changed_event(key, value.to_s)
    end
    
    # 真偽値設定を設定
    def set_bool(key : String, value : Bool)
      @preferences[key] = JSON::Any.new(value)
      @modified = true
      
      dispatch_preference_changed_event(key, value.to_s)
    end
    
    # 配列設定を設定
    def set_array(key : String, value : Array(JSON::Any))
      @preferences[key] = JSON::Any.new(value)
      @modified = true
      
      dispatch_preference_changed_event(key, value.to_json)
    end
    
    # オブジェクト設定を設定
    def set_object(key : String, value : Hash(String, JSON::Any))
      @preferences[key] = JSON::Any.new(value)
      @modified = true
      
      dispatch_preference_changed_event(key, value.to_json)
    end
    
    # 設定を削除
    def delete(key : String)
      if @preferences.has_key?(key)
        # デフォルト値がある場合はそれをセット
        if DEFAULT_PREFERENCES.has_key?(key)
          @preferences[key] = JSON::Any.new(DEFAULT_PREFERENCES[key])
        else
          @preferences.delete(key)
        end
        
        # データベースから削除
        @db.exec "DELETE FROM preferences WHERE key = ?", key
        
        @modified = true
        
        dispatch_preference_changed_event(key, "")
      end
    end
    
    # 設定変更イベントをディスパッチ
    private def dispatch_preference_changed_event(key : String, value : String)
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::PREFERENCES_CHANGED,
        data: {
          "key" => key,
          "value" => value
        }
      ))
    end
    
    # 設定をデフォルトにリセット
    def reset_to_defaults
      # データベースから全ての設定を削除
      @db.exec "DELETE FROM preferences"
      
      # デフォルト設定をロード
      @preferences.clear
      DEFAULT_PREFERENCES.each do |key, value|
        @preferences[key] = JSON::Any.new(value)
      end
      
      @modified = false
      
      # 設定変更イベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::PREFERENCES_CHANGED,
        data: {} of String => String
      ))
    end
    
    # すべての設定をハッシュとして取得
    def get_all : Hash(String, JSON::Any)
      @preferences.dup
    end
    
    # 設定をファイルにエクスポート
    def export(file_path : String) : Bool
      begin
        # 設定をJSONにシリアライズ
        json_data = @preferences.to_json
        
        # ファイルに書き込み
        File.write(file_path, json_data)
        
        return true
      rescue ex
        Log.error { "設定のエクスポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # 設定をファイルからインポート
    def import(file_path : String) : Bool
      begin
        # ファイルから読み込み
        json_data = File.read(file_path)
        
        # JSONから設定を解析
        parsed_preferences = JSON.parse(json_data).as_h
        
        # トランザクションを開始
        @db.transaction do |tx|
          # データベースから全ての設定を削除
          @db.exec "DELETE FROM preferences"
          
          # デフォルト設定をロード
          @preferences.clear
          DEFAULT_PREFERENCES.each do |key, value|
            @preferences[key] = JSON::Any.new(value)
          end
          
          # インポートした設定を適用
          parsed_preferences.each do |key, value|
            @preferences[key] = value
            
            # データベースに保存
            @db.exec "INSERT INTO preferences (key, value, modified_at) VALUES (?, ?, ?)",
              key, value.to_json, Time.utc.to_unix
          end
        end
        
        @modified = false
        
        # 設定変更イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::PREFERENCES_CHANGED,
          data: {} of String => String
        ))
        
        return true
      rescue ex
        Log.error { "設定のインポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # データベース接続を閉じる
    def finalize
      @db.close
    end
  end
end 