require "json"
require "http/client"
require "base64"
require "openssl/cipher"
require "log"

module QuantumCore
  # クラウド同期マネージャー
  # ブラウザデータを複数デバイス間で同期する機能を提供
  class SyncManager
    enum SyncStatus
      IDLE      # 同期待機中
      SYNCING   # 同期中
      ERROR     # エラー発生
      DISABLED  # 無効
    end

    enum ConflictResolution
      LOCAL_WINS  # ローカルデータを優先
      REMOTE_WINS # リモートデータを優先
      MANUAL      # 手動解決
      MERGE       # マージ
    end

    SYNC_API_URL = "https://api.quantum-browser.example/sync"
    SYNC_INTERVAL = 30 * 60 # 30分（秒単位）
    
    @storage_manager : StorageManager
    @sync_token : String?
    @sync_device_id : String?
    @last_sync_time : Time?
    @sync_thread : Fiber?
    @running : Bool = false
    @sync_enabled : Bool = false
    @sync_status : SyncStatus
    @conflict_resolution : ConflictResolution
    @device_id : String
    @encrypted : Bool
    @encryption_key : String?
    @sync_queue : Array(SyncOperation)
    @sync_lock : Mutex
    
    # 同期操作を表す構造体
    private struct SyncOperation
      property operation_type : String
      property data_type : String
      property item_id : String
      property data : String
      property timestamp : Time

      def initialize(@operation_type, @data_type, @item_id, @data, @timestamp = Time.utc)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "operation_type", @operation_type
          json.field "data_type", @data_type
          json.field "item_id", @item_id
          json.field "data", @data
          json.field "timestamp", @timestamp.to_unix
        end
      end

      def self.from_json(json_string : String) : SyncOperation
        pull = JSON::PullParser.new(json_string)
        from_json(pull)
      end

      def self.from_json(pull : JSON::PullParser) : SyncOperation
        operation_type = ""
        data_type = ""
        item_id = ""
        data = ""
        timestamp = Time.unix(0)

        pull.read_object do |key|
          case key
          when "operation_type"
            operation_type = pull.read_string
          when "data_type"
            data_type = pull.read_string
          when "item_id"
            item_id = pull.read_string
          when "data"
            data = pull.read_string
          when "timestamp"
            timestamp = Time.unix(pull.read_int)
          else
            pull.skip
          end
        end

        SyncOperation.new(
          operation_type: operation_type,
          data_type: data_type,
          item_id: item_id,
          data: data,
          timestamp: timestamp
        )
      end
    end

    getter sync_status : SyncStatus
    getter last_sync_time : Time
    getter device_id : String

    def initialize(@storage_manager : StorageManager, 
                   @user_id : String, 
                   @auth_token : String, 
                   @api_endpoint : String = "https://sync.quantumbrowser.example/api/v1",
                   @sync_interval : Time::Span = 15.minutes,
                   @conflict_resolution : ConflictResolution = ConflictResolution::MERGE,
                   @encrypted : Bool = true,
                   encryption_key : String? = nil)
      
      @last_sync_time = Time.unix(0)
      @sync_status = SyncStatus::IDLE
      @sync_enabled = true
      @sync_thread = nil
      @sync_queue = [] of SyncOperation
      @sync_lock = Mutex.new
      
      # デバイスIDを生成または取得
      @device_id = generate_or_load_device_id
      
      # 暗号化が有効で鍵が提供されていない場合は生成
      if @encrypted && encryption_key.nil?
        @encryption_key = generate_encryption_key
      else
        @encryption_key = encryption_key
      end
      
      # 初回登録
      register_device unless device_registered?
      
      # 同期スレッドを開始
      start_sync_thread
    end
    
    # 同期設定を読み込む
    private def load_sync_settings
      # ユーザーの設定を読み込む
      preferences = @storage_manager.preferences_manager
      
      @sync_enabled = preferences.get_bool("enable_sync", false)
      @sync_token = preferences.get_string("sync_token", nil)
      @sync_device_id = preferences.get_string("sync_device_id", nil)
      
      # 前回の同期時刻を読み込む
      last_sync_unix = preferences.get_int("last_sync_time", 0)
      @last_sync_time = last_sync_unix > 0 ? Time.unix(last_sync_unix) : nil
    end
    
    # 同期設定を保存
    private def save_sync_settings
      # ユーザーの設定を更新
      preferences = @storage_manager.preferences_manager
      
      preferences.set_bool("enable_sync", @sync_enabled)
      preferences.set_string("sync_token", @sync_token || "")
      preferences.set_string("sync_device_id", @sync_device_id || "")
      
      # 前回の同期時刻を保存
      if last_time = @last_sync_time
        preferences.set_int("last_sync_time", last_time.to_unix.to_i32)
      else
        preferences.set_int("last_sync_time", 0)
      end
      
      preferences.save
    end
    
    # 同期スレッドを開始
    private def start_sync_thread
      return if @running || !@sync_enabled
      
      @running = true
      
      # 同期スレッドを作成
      @sync_thread = spawn do
        while @running
          begin
            # 同期を実行
            sync if @sync_enabled
            
            # 同期間隔を待機
            sleep SYNC_INTERVAL
          rescue ex
            Log.error { "同期スレッドでエラーが発生しました: #{ex.message}" }
            sleep 60 # エラー発生時は1分待機してから再試行
          end
        end
      end
    end
    
    # 同期スレッドを停止
    private def stop_sync_thread
      @running = false
      # スレッドが終了するまで待機する場合はここで join できる
      # @sync_thread.try &.join
    end
    
    # 同期を有効にする
    def enable(username : String, password : String) : Bool
      # すでに有効な場合は何もしない
      return true if @sync_enabled && @sync_token
      
      # 認証を行い、同期トークンを取得
      token = authenticate(username, password)
      return false unless token
      
      # デバイスIDがない場合は新しく生成
      @sync_device_id ||= generate_device_id
      
      # 同期トークンを保存
      @sync_token = token
      @sync_enabled = true
      
      # 設定を保存
      save_sync_settings
      
      # 同期スレッドを開始
      start_sync_thread
      
      # 初回同期を実行
      sync
      
      true
    end
    
    # 同期を無効にする
    def disable : Bool
      # すでに無効な場合は何もしない
      return true unless @sync_enabled
      
      # 同期スレッドを停止
      stop_sync_thread
      
      # 同期設定をクリア
      @sync_enabled = false
      @sync_token = nil
      
      # 設定を保存
      save_sync_settings
      
      true
    end
    
    # 認証を行い、同期トークンを取得
    private def authenticate(username : String, password : String) : String?
      begin
        # 認証リクエストを作成
        auth_data = {
          "username" => username,
          "password" => password,
          "device_name" => get_device_name,
          "device_id" => @sync_device_id || generate_device_id,
          "client_version" => "1.0.0"
        }.to_json
        
        # 認証APIにリクエストを送信
        response = HTTP::Client.post(
          "#{SYNC_API_URL}/auth",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: auth_data
        )
        
        # レスポンスを解析
        if response.success?
          data = JSON.parse(response.body)
          return data["token"].as_s
        else
          Log.error { "同期認証に失敗しました: #{response.status_code} #{response.body}" }
          return nil
        end
      rescue ex
        Log.error { "同期認証中にエラーが発生しました: #{ex.message}" }
        return nil
      end
    end
    
    # デバイスIDを生成
    private def generate_device_id : String
      # ランダムなUUIDを生成
      UUID.random.to_s
    end
    
    # デバイス名を取得
    private def get_device_name : String
      # ホスト名を取得
      hostname = `hostname`.strip
      
      # OS情報を取得
      os_info = `uname -sr`.strip
      
      "#{hostname} (#{os_info})"
    end
    
    # 同期を実行
    def sync : Bool
      return false unless @sync_enabled && @sync_token
      
      # 同期開始イベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::SYNC_STARTED,
        data: {} of String => String
      ))
      
      begin
        # 前回の同期以降の変更を取得
        changes = get_changes_since_last_sync
        
        # 変更をサーバーに送信
        push_result = push_changes(changes)
        
        # サーバーからの変更を取得
        pull_result = pull_changes
        
        # 変更を適用
        if pull_result && pull_result["changes"]?
          apply_changes(pull_result["changes"])
        end
        
        # 最後の同期時刻を更新
        @last_sync_time = Time.utc
        save_sync_settings
        
        # 同期完了イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::SYNC_COMPLETED,
          data: {} of String => String
        ))
        
        return true
      rescue ex
        Log.error { "同期中にエラーが発生しました: #{ex.message}" }
        
        # 同期エラーイベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::SYNC_ERROR,
          data: {
            "error" => ex.message || "Unknown error"
          }
        ))
        
        return false
      end
    end
    
    # 前回の同期以降の変更を取得
    private def get_changes_since_last_sync : Hash(String, JSON::Any)
      changes = {} of String => JSON::Any
      
      # 設定から同期するデータ種別を取得
      preferences = @storage_manager.preferences_manager
      sync_bookmarks = preferences.get_bool("sync_bookmarks", true)
      sync_history = preferences.get_bool("sync_history", true)
      sync_passwords = preferences.get_bool("sync_passwords", true)
      sync_preferences = preferences.get_bool("sync_preferences", true)
      
      # 各データ種別の変更を収集
      if sync_bookmarks
        bookmarks_data = collect_bookmarks_changes
        changes["bookmarks"] = JSON::Any.new(bookmarks_data)
      end
      
      if sync_history
        history_data = collect_history_changes
        changes["history"] = JSON::Any.new(history_data)
      end
      
      if sync_passwords
        passwords_data = collect_passwords_changes
        changes["passwords"] = JSON::Any.new(passwords_data)
      end
      
      if sync_preferences
        preferences_data = collect_preferences_changes
        changes["preferences"] = JSON::Any.new(preferences_data)
      end
      
      JSON::Any.new(changes).as_h
    end
    
    # ブックマークの変更を収集
    private def collect_bookmarks_changes : Hash(String, JSON::Any)
      data = {} of String => JSON::Any
      
      begin
        # ルートフォルダを取得
        root_folder = @storage_manager.bookmark_manager.get_root_folder
        
        # JSON形式に変換
        root_json = JSON.parse(root_folder.to_json)
        
        data["root"] = root_json
      rescue ex
        Log.error { "ブックマークの変更収集中にエラーが発生しました: #{ex.message}" }
      end
      
      JSON::Any.new(data).as_h
    end
    
    # 履歴の変更を収集
    private def collect_history_changes : Hash(String, JSON::Any)
      data = {} of String => JSON::Any
      
      begin
        # 前回の同期以降の履歴エントリを取得
        since = @last_sync_time || Time.unix(0)
        
        # 過去30日間の履歴を同期（あまりに古い履歴は同期しない）
        thirty_days_ago = Time.utc - 30.days
        since = thirty_days_ago if since < thirty_days_ago
        
        entries = @storage_manager.history_manager.search_by_date_range(since, Time.utc, 1000)
        
        # JSON形式に変換
        entries_json = JSON.parse(entries.to_json)
        
        data["entries"] = entries_json
      rescue ex
        Log.error { "履歴の変更収集中にエラーが発生しました: #{ex.message}" }
      end
      
      JSON::Any.new(data).as_h
    end
    
    # パスワードの変更を収集
    private def collect_passwords_changes : Hash(String, JSON::Any)
      data = {} of String => JSON::Any
      
      begin
        # 全てのパスワードエントリを取得
        # 実際の実装では、前回の同期以降に変更されたエントリのみを取得するロジックを追加すべき
        # また、パスワードは転送前に暗号化する必要がある
        
        # 同期APIで使用する暗号化キーを取得または生成
        sync_key = get_sync_encryption_key
        
        # パスワードをエクスポート（一時ファイルに）
        temp_file = File.tempfile("passwords")
        begin
          @storage_manager.password_manager.export(temp_file.path)
          
          # ファイルの内容を読み込み
          json_data = File.read(temp_file.path)
          
          # データを暗号化
          encrypted_data = encrypt_sensitive_data(json_data, sync_key)
          
          data["encrypted"] = JSON::Any.new(encrypted_data)
        ensure
          # 一時ファイルを削除
          temp_file.delete
        end
      rescue ex
        Log.error { "パスワードの変更収集中にエラーが発生しました: #{ex.message}" }
      end
      
      JSON::Any.new(data).as_h
    end
    
    # 設定の変更を収集
    private def collect_preferences_changes : Hash(String, JSON::Any)
      data = {} of String => JSON::Any
      
      begin
        # 同期する設定を指定
        sync_keys = [
          "homepage",
          "startup_mode",
          "default_search_engine",
          "show_bookmarks_bar",
          "theme",
          "font_size",
          "font_family",
          "smooth_scrolling",
          "enable_animations"
        ]
        
        # 指定した設定のみを取得
        preferences = @storage_manager.preferences_manager.get_all
        sync_preferences = {} of String => JSON::Any
        
        sync_keys.each do |key|
          if preferences.has_key?(key)
            sync_preferences[key] = preferences[key]
          end
        end
        
        data["settings"] = JSON::Any.new(sync_preferences)
      rescue ex
        Log.error { "設定の変更収集中にエラーが発生しました: #{ex.message}" }
      end
      
      JSON::Any.new(data).as_h
    end
    
    # 変更をサーバーに送信
    private def push_changes(changes : Hash(String, JSON::Any)) : Bool
      return false unless @sync_token
      
      begin
        # 変更データを作成
        push_data = {
          "device_id" => @sync_device_id,
          "timestamp" => Time.utc.to_unix,
          "changes" => changes
        }.to_json
        
        # 同期APIにリクエストを送信
        response = HTTP::Client.post(
          "#{SYNC_API_URL}/push",
          headers: HTTP::Headers{
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{@sync_token}"
          },
          body: push_data
        )
        
        # レスポンスを解析
        if response.success?
          return true
        else
          Log.error { "同期の変更送信に失敗しました: #{response.status_code} #{response.body}" }
          return false
        end
      rescue ex
        Log.error { "同期の変更送信中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # サーバーからの変更を取得
    private def pull_changes : Hash(String, JSON::Any)?
      return nil unless @sync_token
      
      begin
        # 前回の同期時刻を取得
        since = (@last_sync_time || Time.unix(0)).to_unix
        
        # 同期APIにリクエストを送信
        response = HTTP::Client.get(
          "#{SYNC_API_URL}/pull?since=#{since}&device_id=#{@sync_device_id}",
          headers: HTTP::Headers{
            "Authorization" => "Bearer #{@sync_token}"
          }
        )
        
        # レスポンスを解析
        if response.success?
          data = JSON.parse(response.body).as_h
          return data
        else
          Log.error { "同期の変更取得に失敗しました: #{response.status_code} #{response.body}" }
          return nil
        end
      rescue ex
        Log.error { "同期の変更取得中にエラーが発生しました: #{ex.message}" }
        return nil
      end
    end
    
    # サーバーからの変更を適用
    private def apply_changes(changes : JSON::Any)
      # 各データ種別の変更を適用
      if changes["bookmarks"]?
        apply_bookmark_changes(changes["bookmarks"])
      end
      
      if changes["history"]?
        apply_history_changes(changes["history"])
      end
      
      if changes["passwords"]?
        apply_password_changes(changes["passwords"])
      end
      
      if changes["preferences"]?
        apply_preference_changes(changes["preferences"])
      end
    end
    
    # ブックマークの変更を適用
    private def apply_bookmark_changes(changes : JSON::Any)
      if root = changes["root"]?
        # 一時ファイルに書き込み
        temp_file = File.tempfile("bookmarks")
        begin
          File.write(temp_file.path, root.to_json)
          
          # ブックマークをインポート
          @storage_manager.bookmark_manager.import(temp_file.path)
        ensure
          # 一時ファイルを削除
          temp_file.delete
        end
      end
    end
    
    # 履歴の変更を適用
    private def apply_history_changes(changes : JSON::Any)
      if entries = changes["entries"]?
        # 一時ファイルに書き込み
        temp_file = File.tempfile("history")
        begin
          File.write(temp_file.path, entries.to_json)
          
          # 履歴をインポート
          @storage_manager.history_manager.import(temp_file.path)
        ensure
          # 一時ファイルを削除
          temp_file.delete
        end
      end
    end
    
    # パスワードの変更を適用
    private def apply_password_changes(changes : JSON::Any)
      if encrypted = changes["encrypted"]?
        begin
          # 同期APIで使用する暗号化キーを取得
          sync_key = get_sync_encryption_key
          
          # 暗号化されたデータを復号化
          decrypted_data = decrypt_sensitive_data(encrypted.as_s, sync_key)
          
          # 一時ファイルに書き込み
          temp_file = File.tempfile("passwords")
          begin
            File.write(temp_file.path, decrypted_data)
            
            # パスワードをインポート
            @storage_manager.password_manager.import(temp_file.path)
          ensure
            # 一時ファイルを削除
            temp_file.delete
          end
        rescue ex
          Log.error { "パスワードの変更適用中にエラーが発生しました: #{ex.message}" }
        end
      end
    end
    
    # 設定の変更を適用
    private def apply_preference_changes(changes : JSON::Any)
      if settings = changes["settings"]?
        settings.as_h.each do |key, value|
          case value.raw
          when String
            @storage_manager.preferences_manager.set_string(key, value.as_s)
          when Int64
            @storage_manager.preferences_manager.set_int(key, value.as_i.to_i32)
          when Float64
            @storage_manager.preferences_manager.set_float(key, value.as_f)
          when Bool
            @storage_manager.preferences_manager.set_bool(key, value.as_bool)
          end
        end
        
        # 設定を保存
        @storage_manager.preferences_manager.save
      end
    end
    
    # 同期暗号化キーを取得または生成
    private def get_sync_encryption_key : String
      # 設定から暗号化キーを取得
      preferences = @storage_manager.preferences_manager
      sync_key = preferences.get_string("sync_encryption_key", "")
      
      # キーがなければ新しく生成
      if sync_key.empty?
        sync_key = Random.new.random_bytes(32).hexstring
        preferences.set_string("sync_encryption_key", sync_key)
        preferences.save
      end
      
      sync_key
    end
    
    # 機密データを暗号化
    private def encrypt_sensitive_data(data : String, key : String) : String
      # 暗号化アルゴリズムを初期化
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      
      # キーとIVを設定
      cipher.key = derive_key(key)
      iv = Random.new.random_bytes(16)
      cipher.iv = iv
      
      # 暗号化
      encrypted = cipher.update(data)
      encrypted = encrypted + cipher.final
      
      # IV + 暗号文をBase64エンコード
      "#{iv.hexstring}:#{Base64.strict_encode(encrypted)}"
    end
    
    # 機密データを復号化
    private def decrypt_sensitive_data(encrypted : String, key : String) : String
      # IV と 暗号文を分離
      parts = encrypted.split(":")
      return encrypted if parts.size != 2
      
      iv_hex = parts[0]
      data_base64 = parts[1]
      
      # IV をバイナリに変換
      iv = iv_hex.hexbytes
      
      # 暗号文をデコード
      data = Base64.decode(data_base64)
      
      # 復号化アルゴリズムを初期化
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      
      # キーとIVを設定
      cipher.key = derive_key(key)
      cipher.iv = iv
      
      # 復号化
      decrypted = cipher.update(data)
      decrypted = decrypted + cipher.final
      
      String.new(decrypted)
    end
    
    # キー導出関数
    private def derive_key(password : String) : Bytes
      # 単純なハッシュ化でキーを導出
      # 実際の実装では、より強力なPBKDF2などのキー導出関数を使用すべき
      digest = OpenSSL::Digest.new("sha256")
      digest.update(password)
      digest.final
    end
    
    # デバイスIDを生成または読み込み
    private def generate_or_load_device_id : String
      device_id_path = File.join(@storage_manager.storage_directory, "device_id.txt")
      
      if File.exists?(device_id_path)
        # 既存のデバイスIDを読み込み
        File.read(device_id_path).strip
      else
        # 新しいデバイスIDを生成
        require "uuid"
        device_id = UUID.random.to_s
        
        # デバイスIDを保存
        File.write(device_id_path, device_id)
        
        device_id
      end
    end

    # 暗号化キーを生成
    private def generate_encryption_key : String
      require "random/secure"
      bytes = Bytes.new(32)
      Random::Secure.random_bytes(bytes)
      bytes.hexstring
    end

    # デバイスが登録済みかどうかを確認
    private def device_registered? : Bool
      begin
        response = HTTP::Client.get(
          "#{@api_endpoint}/devices/#{@device_id}",
          headers: auth_headers
        )
        
        return response.status_code == 200
      rescue ex
        Log.error { "デバイス登録状態の確認中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end

    # デバイスを登録
    private def register_device : Bool
      begin
        # OSとブラウザバージョンを取得
        os_name = {% if flag?(:win32) %}
          "Windows"
        {% elsif flag?(:darwin) %}
          "macOS"
        {% elsif flag?(:linux) %}
          "Linux"
        {% else %}
          "Unknown OS"
        {% end %}
        
        browser_version = @storage_manager.engine.version
        
        # 登録データを準備
        register_data = {
          "device_id" => @device_id,
          "user_id" => @user_id,
          "device_name" => "#{os_name} Device",
          "device_type" => "desktop",
          "os_name" => os_name,
          "browser_version" => browser_version,
          "register_time" => Time.utc.to_unix
        }
        
        # リクエストを送信
        response = HTTP::Client.post(
          "#{@api_endpoint}/devices/register",
          headers: auth_headers,
          body: register_data.to_json
        )
        
        if response.status_code == 200 || response.status_code == 201
          Log.info { "デバイスが正常に登録されました: #{@device_id}" }
          return true
        else
          Log.error { "デバイス登録中にエラーが発生しました: #{response.status_code} - #{response.body}" }
          return false
        end
      rescue ex
        Log.error { "デバイス登録中に例外が発生しました: #{ex.message}" }
        return false
      end
    end

    # 認証ヘッダーを生成
    private def auth_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Content-Type"] = "application/json"
      headers["Authorization"] = "Bearer #{@auth_token}"
      headers["X-Device-ID"] = @device_id
      headers["X-User-ID"] = @user_id
      headers
    end

    # 同期マネージャーのリソースを解放
    def finalize
      # 同期スレッドを停止
      stop_sync_thread
    end
  end
end 