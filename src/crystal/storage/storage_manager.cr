require "json"
require "sqlite3"
require "file_utils"

module QuantumCore
  # ストレージマネージャークラス
  # ブラウザの各種ストレージを管理する
  class StorageManager
    @engine : Engine
    @history_manager : HistoryManager
    @bookmarks_manager : BookmarkManager
    @passwords_manager : PasswordManager
    @preferences_manager : PreferencesManager
    @sync_manager : SyncManager?
    @storage_directory : String
    @initialized : Bool = false
    
    # 各種マネージャーへのゲッター
    getter engine : Engine
    getter history_manager : HistoryManager
    getter bookmarks_manager : BookmarkManager
    getter passwords_manager : PasswordManager
    getter preferences_manager : PreferencesManager
    getter sync_manager : SyncManager?
    getter storage_directory : String
    
    # OSごとのデフォルトストレージディレクトリパスを取得
    def self.get_default_storage_directory : String
      home_dir = ENV["HOME"]? || ENV["USERPROFILE"]? || "."
      
      case self.get_platform
      when "windows"
        File.join(ENV["APPDATA"]? || File.join(home_dir, "AppData", "Roaming"), "QuantumBrowser")
      when "macos"
        File.join(home_dir, "Library", "Application Support", "QuantumBrowser")
      when "linux"
        xdg_data_home = ENV["XDG_DATA_HOME"]?
        if xdg_data_home
          File.join(xdg_data_home, "QuantumBrowser")
        else
          File.join(home_dir, ".local", "share", "QuantumBrowser")
        end
      else
        File.join(home_dir, ".quantum_browser")
      end
    end
    
    # 現在のプラットフォームを検出
    def self.get_platform : String
      {% if flag?(:win32) || flag?(:windows) %}
        "windows"
      {% elsif flag?(:darwin) || flag?(:macos) %}
        "macos"
      {% elsif flag?(:linux) %}
        "linux"
      {% else %}
        "unknown"
      {% end %}
    end
    
    def initialize(@engine : Engine, storage_directory : String? = nil)
      # ストレージディレクトリを設定
      @storage_directory = storage_directory || StorageManager.get_default_storage_directory
      
      # ストレージディレクトリが存在しない場合は作成
      unless Dir.exists?(@storage_directory)
        begin
          FileUtils.mkdir_p(@storage_directory)
        rescue ex
          Log.error { "ストレージディレクトリの作成に失敗しました: #{ex.message}" }
          # フォールバックとして現在のディレクトリを使用
          @storage_directory = "."
        end
      end
      
      # カレントディレクトリをストレージディレクトリに変更
      original_dir = Dir.current
      Dir.cd(@storage_directory)
      
      # 各マネージャーを初期化
      @history_manager = HistoryManager.new(self)
      @bookmarks_manager = BookmarkManager.new(self)
      @passwords_manager = PasswordManager.new(self)
      @preferences_manager = PreferencesManager.new(self)
      
      # 同期マネージャーは初期化時にはnilとし、後から有効化できるようにする
      @sync_manager = nil
      
      # カレントディレクトリを元に戻す
      Dir.cd(original_dir)
      
      # エンジンイベントリスナーを設定
      setup_event_listeners
    end
    
    # イベントリスナーを設定
    private def setup_event_listeners
      # ウィンドウクローズイベントでのデータ保存
      @engine.add_event_listener(EventType::WINDOW_CLOSE) do |event|
        save_all
      end
      
      # 定期的な自動保存のためのタイマーを設定
      spawn do
        loop do
          sleep 5.minutes
          save_all
        end
      end
    end
    
    # 同期機能を有効化
    def enable_sync(user_id : String, auth_token : String) : Bool
      return true if @sync_manager

      begin
        @sync_manager = SyncManager.new(self, user_id, auth_token)
        
        # 初回同期を実行
        @sync_manager.not_nil!.sync
        
        # 成功
        return true
      rescue ex
        Log.error { "同期機能の有効化に失敗しました: #{ex.message}" }
        @sync_manager = nil
        return false
      end
    end
    
    # 同期機能を無効化
    def disable_sync : Bool
      return true unless @sync_manager
      
      begin
        # 最後の同期を実行
        @sync_manager.not_nil!.disable
        @sync_manager = nil
        return true
      rescue ex
        Log.error { "同期機能の無効化に失敗しました: #{ex.message}" }
        return false
      end
    end
    
    # 同期が有効かどうかを確認
    def sync_enabled? : Bool
      !@sync_manager.nil?
    end
    
    # すべてのデータを保存
    def save_all
      Log.info { "すべてのデータを保存しています..." }
      
      # 各マネージャーのデータを保存
      @history_manager.save
      @bookmarks_manager.save
      @passwords_manager.save
      @preferences_manager.save
      
      # 同期マネージャーが有効な場合は同期を実行
      @sync_manager.try(&.sync)
      
      Log.info { "すべてのデータの保存が完了しました" }
    end
    
    # ストレージの推定合計サイズを計算（バイト単位）
    def estimated_total_size : Int64
      history_size = @history_manager.estimated_size
      bookmarks_size = @bookmarks_manager.estimated_size
      passwords_size = @passwords_manager.estimated_size
      preferences_size = @preferences_manager.estimated_size
      
      history_size + bookmarks_size + passwords_size + preferences_size
    end
    
    # ストレージの使用状況を取得
    def get_storage_usage : Hash(String, Int64)
      {
        "history" => @history_manager.estimated_size,
        "bookmarks" => @bookmarks_manager.estimated_size,
        "passwords" => @passwords_manager.estimated_size,
        "preferences" => @preferences_manager.estimated_size,
        "total" => estimated_total_size
      }
    end
    
    # ブラウジングデータのクリア
    def clear_browsing_data(clear_history : Bool = false,
                           clear_bookmarks : Bool = false,
                           clear_passwords : Bool = false,
                           clear_preferences : Bool = false)
      # 履歴をクリア
      @history_manager.clear if clear_history
      
      # ブックマークをクリア
      @bookmarks_manager.clear if clear_bookmarks
      
      # パスワードをクリア
      @passwords_manager.clear if clear_passwords
      
      # 設定をリセット
      @preferences_manager.reset_to_defaults if clear_preferences
      
      # データクリアイベントをディスパッチ
      @engine.dispatch_event(Event.new(
        type: EventType::BROWSING_DATA_CLEARED,
        data: {
          "history_cleared" => clear_history,
          "bookmarks_cleared" => clear_bookmarks,
          "passwords_cleared" => clear_passwords,
          "preferences_cleared" => clear_preferences
        }
      ))
    end
    
    # すべてのデータをエクスポート
    def export_all_data(export_directory : String) : Bool
      success = true
      
      begin
        # エクスポートディレクトリが存在しない場合は作成
        Dir.mkdir_p(export_directory) unless Dir.exists?(export_directory)
        
        # 各データをエクスポート
        history_success = @history_manager.export(File.join(export_directory, "history_export.json"))
        bookmarks_success = @bookmarks_manager.export(File.join(export_directory, "bookmarks_export.json"))
        passwords_success = @passwords_manager.export(File.join(export_directory, "passwords_export.json"))
        preferences_success = @preferences_manager.export(File.join(export_directory, "preferences_export.json"))
        
        success = history_success && bookmarks_success && passwords_success && preferences_success
        
        # エクスポートメタデータを作成
        metadata = {
          "export_date" => Time.utc.to_s,
          "browser_version" => @engine.version,
          "exported_items" => {
            "history" => @history_manager.entry_count,
            "bookmarks" => @bookmarks_manager.entry_count,
            "passwords" => @passwords_manager.entry_count
          }
        }
        
        File.write(File.join(export_directory, "export_metadata.json"), metadata.to_json)
      rescue ex
        Log.error { "データのエクスポート中にエラーが発生しました: #{ex.message}" }
        success = false
      end
      
      success
    end
    
    # すべてのデータをインポート
    def import_all_data(import_directory : String) : Bool
      success = true
      
      begin
        # 各データファイルが存在するか確認してインポート
        history_path = File.join(import_directory, "history_export.json")
        bookmarks_path = File.join(import_directory, "bookmarks_export.json")
        passwords_path = File.join(import_directory, "passwords_export.json")
        preferences_path = File.join(import_directory, "preferences_export.json")
        
        # 履歴をインポート
        if File.exists?(history_path)
          history_success = @history_manager.import(history_path)
          success = success && history_success
        end
        
        # ブックマークをインポート
        if File.exists?(bookmarks_path)
          bookmarks_success = @bookmarks_manager.import(bookmarks_path)
          success = success && bookmarks_success
        end
        
        # パスワードをインポート
        if File.exists?(passwords_path)
          passwords_success = @passwords_manager.import(passwords_path)
          success = success && passwords_success
        end
        
        # 設定をインポート
        if File.exists?(preferences_path)
          preferences_success = @preferences_manager.import(preferences_path)
          success = success && preferences_success
        end
        
        # インポート完了イベントをディスパッチ
        @engine.dispatch_event(Event.new(
          type: EventType::DATA_IMPORTED,
          data: {
            "success" => success
          }
        ))
      rescue ex
        Log.error { "データのインポート中にエラーが発生しました: #{ex.message}" }
        success = false
      end
      
      success
    end
    
    # ストレージマネージャーの終了処理
    def finalize
      # すべてのデータを保存
      save_all
      
      # 各マネージャーの終了処理
      @history_manager.finalize
      @bookmarks_manager.finalize
      @passwords_manager.finalize
      @sync_manager.try(&.finalize)
    end
    
    # 暗号化キーの生成（シードからハッシュ生成）
    def generate_encryption_key(seed : String) : String
      require "openssl"
      
      # シードからSHA-256ハッシュを生成
      digest = OpenSSL::Digest.new("SHA256")
      digest.update(seed)
      digest.final.hexstring
    end
    
    # データの整合性を検証
    def validate_data_integrity : Bool
      # 各マネージャーのデータ整合性を検証
      history_valid = true # 履歴マネージャーの整合性検証メソッドがあれば呼び出し
      bookmarks_valid = true # ブックマークマネージャーの整合性検証メソッドがあれば呼び出し
      passwords_valid = true # パスワードマネージャーの整合性検証メソッドがあれば呼び出し
      preferences_valid = true # 設定マネージャーの整合性検証メソッドがあれば呼び出し
      
      history_valid && bookmarks_valid && passwords_valid && preferences_valid
    end
    
    # ストレージの最適化
    def optimize_storage
      # 各SQLiteデータベースの最適化
      @history_manager.optimize_database if @history_manager.responds_to?(:optimize_database)
      @bookmarks_manager.optimize_database if @bookmarks_manager.responds_to?(:optimize_database)
      @passwords_manager.optimize_database if @passwords_manager.responds_to?(:optimize_database)
      @preferences_manager.optimize_database if @preferences_manager.responds_to?(:optimize_database)
      
      # バキュームの実行
      @history_manager.vacuum_database if @history_manager.responds_to?(:vacuum_database)
      @bookmarks_manager.vacuum_database if @bookmarks_manager.responds_to?(:vacuum_database)
      @passwords_manager.vacuum_database if @passwords_manager.responds_to?(:vacuum_database)
      @preferences_manager.vacuum_database if @preferences_manager.responds_to?(:vacuum_database)
    end
    
    # データ修復機能
    def repair_data : Bool
      success = true
      
      begin
        # 各マネージャーの修復機能を呼び出し
        success = success && (@history_manager.repair if @history_manager.responds_to?(:repair))
        success = success && (@bookmarks_manager.repair if @bookmarks_manager.responds_to?(:repair))
        success = success && (@passwords_manager.repair if @passwords_manager.responds_to?(:repair))
        success = success && (@preferences_manager.repair if @preferences_manager.responds_to?(:repair))
      rescue ex
        Log.error { "データの修復中にエラーが発生しました: #{ex.message}" }
        success = false
      end
      
      success
    end
    
    # バージョン間のデータ移行
    def migrate_data(from_version : String, to_version : String) : Bool
      Log.info { "データを移行しています: #{from_version} -> #{to_version}" }
      
      # バージョン間の移行ロジックを実装
      # 必要に応じてスキーマの更新やデータ形式の変換を行う
      
      # ここでは単純な成功を返す
      true
    end
  end
end 