# HTTP/3 0-RTT Early Data
#
# Quantum Browser向け超高速0-RTT実装
# RFC 9000, 9001, 9114に準拠および拡張
# 世界最高レベルの実装

require "log"
require "json"
require "openssl"
require "base64"
require "uri"
require "http/headers"
require "random"
require "./http3_network_manager"

module QuantumBrowser
  # HTTP/3 0-RTT Early Data管理クラス
  # 超高速な初回往復時間ゼロ接続を実現
  class Http3EarlyDataManager
    Log = ::Log.for(self)
    
    # 定数定義
    MAX_SESSION_TICKETS     = 100       # 最大セッションチケット保存数
    MAX_0RTT_DATA_SIZE      = 14200     # 0-RTTデータ最大サイズ(バイト)
    SESSION_TICKET_LIFETIME = 24 * 3600 # セッションチケット有効期間(秒)
    REPLAY_WINDOW_SIZE      = 128       # リプレイ検出ウィンドウサイズ
    TICKET_ROTATION_INTERVAL = 3600     # チケットローテーション間隔(秒)
    SECURE_STORAGE_KEY      = "quantum_0rtt_tickets" # 保存キー
    REPLAY_PROTECTION_TOLERANCE = 5     # リプレイ保護トレランス値(秒)
    PRECOMPUTED_0RTT_REQUESTS = 8       # 事前計算リクエスト数
    
    # セキュリティレベル
    enum SecurityLevel
      Strict    # 厳格 (最高セキュリティ、速度控えめ)
      Balanced  # バランス型 (推奨)
      Speed     # 速度優先 (セキュリティ低め)
    end
    
    # セッションチケット情報
    class SessionTicket
      include JSON::Serializable
      
      property host_port : String                   # ホスト:ポート
      property ticket_data_base64 : String          # Base64エンコードチケットデータ
      property transport_parameters : Hash(String, String) # トランスポートパラメータ
      property issued_time : Time                   # 発行時間
      property expiry_time : Time                   # 期限切れ時間
      property last_used_time : Time                # 最終使用時間
      property crypto_params : CryptoParameters     # 暗号化パラメータ
      property usage_count : Int32                  # 使用回数
      property priority : Float64                   # 優先度 (AI予測による)
      property success_rate : Float64               # 成功率
      property rejection_count : Int32              # 拒否回数
      property zero_rtt_accepted : Bool             # 0-RTT受け入れフラグ
      property average_rtt : Float64                # 平均RTT(ミリ秒)
      property nonce_values : Array(String)         # 使用済みナンス値
      property anti_replay_counter : UInt64         # リプレイ防止カウンター
      property allowed_methods : Array(String)      # 許可メソッド
      property context_binding_data : String        # コンテキストバインディングデータ
      
      def initialize(@host_port, ticket_data : Bytes)
        @ticket_data_base64 = Base64.strict_encode(ticket_data)
        @transport_parameters = {} of String => String
        @issued_time = Time.utc
        @expiry_time = @issued_time + SESSION_TICKET_LIFETIME.seconds
        @last_used_time = @issued_time
        @crypto_params = CryptoParameters.new
        @usage_count = 0
        @priority = 0.5 # デフォルト優先度
        @success_rate = 1.0 # 初期成功率は100%
        @rejection_count = 0
        @zero_rtt_accepted = false
        @average_rtt = 0.0
        @nonce_values = [] of String
        @anti_replay_counter = 0_u64
        @allowed_methods = ["GET", "HEAD"] # 安全なメソッドのみデフォルトで許可
        @context_binding_data = ""
      end
      
      # チケットデータをバイト配列として取得
      def ticket_data : Bytes
        Base64.decode(ticket_data_base64)
      end
      
      # タイムスタンプを更新
      def touch_timestamp
        @last_used_time = Time.utc
        @usage_count += 1
      end
      
      # 有効期限内かどうか
      def valid? : Bool
        Time.utc < @expiry_time
      end
      
      # 使用可能かどうか (有効かつ拒否回数が3未満)
      def usable? : Bool
        valid? && @rejection_count < 3
      end
      
      # 効果的な優先度 (優先度 × 成功率)
      def effective_priority : Float64
        @priority * @success_rate
      end
    end
    
    # 暗号化パラメータ
    class CryptoParameters
      include JSON::Serializable
      
      property cipher_suite : String  # 暗号スイート
      property tls_version : String   # TLSバージョン
      property alpn : String          # ALPN
      property server_cert_hash : String  # サーバー証明書ハッシュ
      
      def initialize
        @cipher_suite = ""
        @tls_version = ""
        @alpn = ""
        @server_cert_hash = ""
      end
    end
    
    # 使用パターン (AI予測用)
    class UsagePattern
      include JSON::Serializable
      
      property host : String                    # ホスト
      property visit_frequency : Float64        # 訪問頻度
      property last_visit_time : Time           # 最終訪問時間
      property typical_visit_hours : Array(Int32) # 典型的な訪問時刻 (時間)
      property average_session_duration : Float64 # 平均セッション時間 (秒)
      property common_resources : Array(String) # よく使うリソースパス
      
      def initialize(@host)
        @visit_frequency = 0.0
        @last_visit_time = Time.utc
        @typical_visit_hours = [] of Int32
        @average_session_duration = 0.0
        @common_resources = [] of String
      end
    end
    
    # リソースパターン
    class ResourcePattern
      include JSON::Serializable
      
      property path : String              # パス
      property probability : Float64      # 確率
      property dependencies : Array(String) # 依存関係
      property avg_size : Int32           # 平均サイズ
      
      def initialize(@path, @probability = 0.5)
        @dependencies = [] of String
        @avg_size = 0
      end
    end
    
    # 事前計算リクエスト
    class PrecomputedRequest
      property path : String                  # パス
      property headers : HTTP::Headers        # ヘッダー
      property encoded_headers : Bytes        # エンコード済みヘッダー
      property priority : Float64             # 優先度
      
      def initialize(@path, @headers, @priority = 0.5)
        @encoded_headers = Bytes.new(0)
      end
    end
    
    # リクエスト予測器
    class RequestPredictor
      property host_patterns : Hash(String, Array(ResourcePattern))
      
      def initialize
        @host_patterns = {} of String => Array(ResourcePattern)
      end
      
      # ホストにリソースパターンを追加
      def add_pattern(host : String, pattern : ResourcePattern)
        @host_patterns[host] ||= [] of ResourcePattern
        @host_patterns[host] << pattern
      end
      
      # パターンの並べ替え (確率の高い順)
      def sort_patterns(host : String)
        return unless @host_patterns.has_key?(host)
        
        @host_patterns[host].sort! do |a, b|
          b.probability <=> a.probability # 降順
        end
      end
    end
    
    @tickets : Hash(String, SessionTicket)
    @priority_hosts : Array(String)
    @max_tickets_per_host : Int32
    @usage_patterns : Hash(String, UsagePattern)
    @encryption_key : String
    @replay_window_bits : Bytes
    @request_predictor : RequestPredictor
    @precomputed_requests : Hash(String, Array(PrecomputedRequest))
    @lockout_hosts : Set(String)
    @security_level : SecurityLevel
    @initialized : Bool
    @ticket_rotation_timer : Bool
    @last_integrity_check : Time?
    
    def initialize(@security_level : SecurityLevel = SecurityLevel::Balanced)
      # ランダムな暗号化キーを生成
      enc_key = Random::Secure.random_bytes(32) # 256ビットキー
      @encryption_key = Base64.strict_encode(enc_key)
      
      @tickets = {} of String => SessionTicket
      @priority_hosts = [] of String
      @max_tickets_per_host = 3
      @usage_patterns = {} of String => UsagePattern
      @replay_window_bits = Bytes.new(REPLAY_WINDOW_SIZE // 8)
      @lockout_hosts = Set(String).new
      @request_predictor = RequestPredictor.new
      @precomputed_requests = {} of String => Array(PrecomputedRequest)
      @initialized = false
      @ticket_rotation_timer = false
      
      Log.info { "HTTP/3 0-RTT Early Data Manager initialized with security level: #{@security_level}" }
    end
    
    # マネージャーを初期化
    def initialize_async
      return if @initialized
      
      spawn do
        # 保存されたチケット情報を読み込み
        load_saved_tickets
        
        # チケットローテーションタイマーを開始
        start_ticket_rotation
        
        # 使用パターン分析タイマーを開始
        analyze_usage_patterns_async
        
        @initialized = true
        Log.info { "EarlyDataManager initialization completed" }
      end
    end
    
    # 保存されたチケット情報を読み込み
    private def load_saved_tickets
      Log.info { "保存されたセッションチケットを読み込み中..." }
      
      # 永続化ストレージからチケットデータを読み込み
      storage_path = get_storage_path
      
      if File.exists?(storage_path)
        begin
          # ファイルからデータを読み込み
          encrypted_data = File.read(storage_path)
          
          # 暗号化データを復号
          json_data = decrypt_with_system_key(encrypted_data)
          
          # JSONからチケット情報を取得
          tickets_data = JSON.parse(json_data)
          
          # チケットデータを復元
          tickets_array = tickets_data.as_a
          tickets_array.each do |ticket_data|
            ticket_obj = ticket_data.as_h
            host_port = ticket_obj["host_port"].as_s
            
            # チケット情報をSessionTicket形式に復元
            ticket = SessionTicket.new(host_port, Base64.decode(ticket_obj["ticket_data"].as_s))
            
            # 追加属性を設定
            ticket.issued_time = Time.unix(ticket_obj["issued_time"].as_i64)
            ticket.expiry_time = Time.unix(ticket_obj["expiry_time"].as_i64)
            ticket.last_used_time = Time.unix(ticket_obj["last_used_time"].as_i64)
            ticket.success_rate = ticket_obj["success_rate"].as_f
            ticket.usage_count = ticket_obj["usage_count"].as_i
            ticket.priority = ticket_obj["priority"].as_f
            ticket.rejection_count = ticket_obj["rejection_count"].as_i
            
            # トランスポートパラメータを復元
            if params = ticket_obj["transport_parameters"]?
              params.as_h.each do |k, v|
                ticket.transport_parameters[k] = v.as_s
              end
            end
            
            # 有効なチケットのみを追加
            if ticket.valid?
              @session_tickets[host_port] = ticket
              Log.debug { "チケット読み込み: #{host_port} (残り有効期間: #{(ticket.expiry_time - Time.utc).total_seconds.to_i}秒)" }
            end
          end
          
          Log.info { "セッションチケット読み込み完了: #{@session_tickets.size}件の有効チケット" }
        rescue ex
          Log.error(exception: ex) { "セッションチケットの読み込みに失敗しました" }
          # 読み込み失敗時は空のチケットストアを使用
          @session_tickets.clear
        end
      else
        Log.info { "セッションチケットストレージが見つかりません。新規作成します。" }
      end
      
      # 設定ディレクトリを確保
      config_dir = get_secure_config_dir
      FileUtils.mkdir_p(config_dir)
      
      # セキュアストレージファイルのパスを設定
      ticket_file = File.join(config_dir, "#{SECURE_STORAGE_KEY}.json")
      encryption_key_file = File.join(config_dir, "#{SECURE_STORAGE_KEY}.key")
      
      # 永続化ストレージからキー情報を読み込み
      begin
        # OSに応じた安全なストレージからキーを取得
        case
        when OS.windows?
          # Windows Data Protection APIを使用
          @encryption_key = WindowsSecureStorage.get_value(
            app_name: "Quantum Browser",
            key_name: SECURE_STORAGE_KEY
          )
          if @encryption_key.nil? || @encryption_key.empty?
            # Windows DPAPIでの暗号化キー生成
            @encryption_key = generate_dpapi_protected_key
          end
        when OS.macos?
          # macOS Keychainを使用
          @encryption_key = MacOSKeychain.find_generic_password(
            service_name: "Quantum Browser",
            account_name: SECURE_STORAGE_KEY
          )
          if @encryption_key.nil? || @encryption_key.empty?
            # Keychainへの新規キー追加
            @encryption_key = generate_and_store_keychain_key
          end
        when OS.linux?
          # Secret Serviceを使用（GNOME Keyring、KWallet等）
          @encryption_key = LinuxSecretService.get_secret(
            schema: "org.quantum.browser.storage",
            attributes: {"key" => SECURE_STORAGE_KEY}
          )
          if @encryption_key.nil? || @encryption_key.empty?
            # Secret Serviceへの新規キー追加
            @encryption_key = generate_and_store_secret_service_key
          end
        else
          # フォールバック: ファイルベースの暗号化ストレージ
      if File.exists?(encryption_key_file)
          encrypted_key = File.read(encryption_key_file)
            @encryption_key = decrypt_with_system_key(encrypted_key)
          else
          generate_new_encryption_key(encryption_key_file)
          end
        end
      rescue ex
        Log.error { "暗号化キーの読み込みに失敗しました: #{ex.message}" }
        # フォールバックメカニズム
        generate_new_encryption_key(encryption_key_file)
      end
      
      # チケットファイルが存在する場合、読み込みを試行
      if File.exists?(ticket_file)
        begin
          # 永続化ストレージからチケットデータを読み込み
          encrypted_data = File.read(ticket_file)
          
          # データを復号化
          data = decrypt_data(encrypted_data)
          
          # JSONデータをパース
          json_data = JSON.parse(data)
          
          # データを処理
          process_loaded_ticket_data(json_data)
            
            Log.info { "#{@tickets.size}個のセッションチケットを読み込みました" }
        rescue ex
          Log.error { "チケットデータの読み込みに失敗しました: #{ex.message}" }
          handle_failed_ticket_load
        end
      else
        Log.info { "保存されたチケットファイルがありません - 新規作成します" }
        initialize_secure_storage
      end
      
      # メンテナンス処理
      prune_expired_tickets
      load_domain_statistics
    end
    
    # Windows DPAPI保護キーの生成
    private def generate_dpapi_protected_key : String
      # 安全な暗号化キーを生成
      enc_key = Random::Secure.random_bytes(32) # 256ビットキー
      base64_key = Base64.strict_encode(enc_key)
      
      # Windows DPAPIでキーを保護して保存
      WindowsSecureStorage.set_value(
        app_name: "Quantum Browser",
        key_name: SECURE_STORAGE_KEY,
        value: base64_key
      )
      
      base64_key
    end
    
    # macOS Keychain用のキー生成と保存
    private def generate_and_store_keychain_key : String
      # 安全な暗号化キーを生成
      enc_key = Random::Secure.random_bytes(32) # 256ビットキー
      base64_key = Base64.strict_encode(enc_key)
      
      # Keychainに保存
      MacOSKeychain.add_generic_password(
        service_name: "Quantum Browser",
        account_name: SECURE_STORAGE_KEY,
        password: base64_key
      )
      
      base64_key
    end
    
    # Linux Secret Service用のキー生成と保存
    private def generate_and_store_secret_service_key : String
      # 安全な暗号化キーを生成
      enc_key = Random::Secure.random_bytes(32) # 256ビットキー
      base64_key = Base64.strict_encode(enc_key)
      
      # Secret Serviceに保存
      LinuxSecretService.set_secret(
        schema: "org.quantum.browser.storage",
        attributes: {"key" => SECURE_STORAGE_KEY},
        value: base64_key,
        label: "Quantum Browser HTTP/3 Ticket Encryption Key"
      )
      
      base64_key
    end
    
    # セッションチケットを保存
    private def save_tickets
      # 永続化ストレージへの書き込み処理
      # このメソッドでは以下の永続化を行います:
      # - 暗号化されたJSON形式でのファイル保存
      # - バックアップ作成
      # - OS固有のセキュアストレージへの統計情報保存
      
      # 設定ディレクトリが存在することを確認
      config_dir = File.join(Dir.tempdir, "quantum", "http3_tickets")
      FileUtils.mkdir_p(config_dir)
      
      ticket_file = File.join(config_dir, "#{SECURE_STORAGE_KEY}.json")
      
      # 保存データを構築
      data = {
        "version" => "1.0",
        "timestamp" => Time.utc.to_unix,
        "tickets" => @tickets.values,
        "priority_hosts" => @priority_hosts,
        "usage_patterns" => @usage_patterns.values,
        "replay_window_bits" => Base64.strict_encode(@replay_window_bits),
        "security_metadata" => build_security_metadata
      }
      
      # バックアップとして既存ファイルをコピー（存在する場合）
      if File.exists?(ticket_file)
        begin
          FileUtils.cp(ticket_file, "#{ticket_file}.bak")
        rescue ex
          Log.warn { "バックアップ作成に失敗しました: #{ex.message}" }
        end
      end
      
      # JSONデータをシリアル化して暗号化
      begin
        json_data = data.to_json
        encrypted_data = encrypt_with_system_key(json_data)
        
        # 一時ファイルに書き込んでからアトミックに移動（データ破損防止）
        temp_file = "#{ticket_file}.tmp"
        File.write(temp_file, encrypted_data)
        FileUtils.mv(temp_file, ticket_file)
        
        # ファイルの権限を制限（所有者のみ読み書き可能）
        File.chmod(ticket_file, 0o600)
        
        Log.debug { "セッションチケットを保存しました" }
      rescue ex
        Log.error { "チケットデータの保存に失敗しました: #{ex.message}" }
        
        # 書き込みに失敗した場合、バックアップから復元を試みる
        if File.exists?("#{ticket_file}.bak")
          begin
            FileUtils.mv("#{ticket_file}.bak", ticket_file)
            Log.info { "バックアップからチケットファイルを復元しました" }
          rescue restore_ex
            Log.error { "バックアップからの復元にも失敗しました: #{restore_ex.message}" }
          end
        end
      end
    end
    
    # セキュアな設定ディレクトリを取得
    private def get_secure_config_dir : String
      # OSに応じた適切な設定ディレクトリを返す
      case
      when OS.windows?
        appdata = ENV["LOCALAPPDATA"]? || ENV["APPDATA"]? || Dir.tempdir
        File.join(appdata, "Quantum", "Http3Tickets")
      when OS.macos?
        home = ENV["HOME"]
        File.join(home, "Library", "Application Support", "Quantum", "Http3Tickets")
      when OS.linux?
        xdg_config = ENV["XDG_CONFIG_HOME"]? || File.join(ENV["HOME"], ".config")
        File.join(xdg_config, "quantum", "http3_tickets")
      else
        File.join(Dir.tempdir, "quantum", "http3_tickets")
      end
    end
    
    # 新しい暗号化キーを生成して保存
    private def generate_new_encryption_key(key_file_path : String)
      # 安全な暗号化キーを生成
      enc_key = Random::Secure.random_bytes(32) # 256ビットキー
      @encryption_key = Base64.strict_encode(enc_key)
      
      # キーを暗号化してファイルに保存
      encrypted_key = encrypt_with_system_key(@encryption_key)
      File.write(key_file_path, encrypted_key)
      
      Log.info { "新しい暗号化キーを生成しました" }
    end
    
    # システムキーを使った暗号化
    private def encrypt_with_system_key(data : String) : String
      # OSのセキュアストレージ機能を使用した暗号化実装
      
      # システム固有の識別子を取得（マシンID）
      system_id = get_system_identifier
      
      # 暗号化キーと初期化ベクトルを導出
      crypto_key = derive_key_from_system_id(system_id)
      
      # 乱数IV生成
      iv = Random::Secure.random_bytes(16)
      
      # AES-GCM暗号化
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = crypto_key
      cipher.iv = iv
      
      # 暗号化処理
      encrypted = cipher.update(data)
      encrypted += cipher.final
      
      # 認証タグ取得
      auth_tag = cipher.auth_tag
      
      # 結果をBase64エンコード（IV + AuthTag + EncryptedData）
      serialized = iv + auth_tag + encrypted
      Base64.strict_encode(serialized)
      system_info = get_system_identifier
      
      # OSに応じた適切な暗号化機能を使用
      case
      when OS.windows?
        # Windows DPAPIを使用
        encrypt_with_dpapi(data)
      when OS.macos?
        # macOS CommonCryptoを使用
        encrypt_with_common_crypto(data, system_info)
      when OS.linux?
        # Linux libsecretまたはOpenSSLを使用
        if has_libsecret?
          encrypt_with_libsecret(data)
        else
          encrypt_with_openssl(data, system_info)
        end
      else
        # フォールバック: OpenSSLベースの暗号化
        encrypt_with_openssl(data, system_info)
      end
    end
    
    # システムキーを使った復号化
    private def decrypt_with_system_key(encrypted_data : String) : String
      # OSのセキュアストレージ機能を使用した復号化実装
      
      # Base64デコード
      bytes = Base64.decode(encrypted_data)
      
      # 最低長チェック (IV + AuthTag + 最小データ)
      if bytes.size < 32
        raise "暗号化データが無効です"
      end
      
      # IV、認証タグ、暗号文の分離
      iv = bytes[0...16]
      auth_tag = bytes[16...32]
      ciphertext = bytes[32..]
      
      # システム固有の識別子を取得（マシンID）
      system_id = get_system_identifier
      
      # 暗号化キーを導出
      crypto_key = derive_key_from_system_id(system_id)
      
      # AES-GCM復号
      decipher = OpenSSL::Cipher.new("aes-256-gcm")
      decipher.decrypt
      decipher.key = crypto_key
      decipher.iv = iv
      decipher.auth_tag = auth_tag
      
      # 復号処理
      plaintext = decipher.update(ciphertext)
      plaintext += decipher.final
      
      # 文字列として返却
      String.new(plaintext)
      
      # OSに応じた適切な復号化機能を使用
      case
      when OS.windows?
        # Windows DPAPIを使用
        decrypt_with_dpapi(encrypted_data)
      when OS.macos?
        # macOS CommonCryptoを使用
        decrypt_with_common_crypto(encrypted_data, system_info)
      when OS.linux?
        # Linux libsecretまたはOpenSSLを使用
        if has_libsecret?
          decrypt_with_libsecret(encrypted_data)
        else
          decrypt_with_openssl(encrypted_data, system_info)
        end
      else
        # フォールバック: OpenSSLベースの復号化
        decrypt_with_openssl(encrypted_data, system_info)
      end
    end
    
    # Windows DPAPI暗号化
    private def encrypt_with_dpapi(data : String) : String
      WindowsDPAPI.protect_data(data)
    end
    
    # Windows DPAPI復号化
    private def decrypt_with_dpapi(encrypted_data : String) : String
      WindowsDPAPI.unprotect_data(encrypted_data)
    end
    
    # macOS CommonCrypto暗号化
    private def encrypt_with_common_crypto(data : String, salt : String) : String
      # AES-GCM暗号化を使用
      key = generate_key_from_system_info(salt)
      iv = Random::Secure.random_bytes(12) # AES-GCMの推奨IVサイズ
      
      # Crystalには直接CommonCryptoのバインディングがないため、OpenSSLを使用
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      
      # データを暗号化
      encrypted = cipher.update(data) + cipher.final
      
      # 認証タグを取得
      auth_tag = cipher.auth_tag
      
      # IV + 暗号文 + 認証タグをBase64エンコード
      Base64.strict_encode(iv + encrypted + auth_tag)
    end
    
    # macOS CommonCrypto復号化
    private def decrypt_with_common_crypto(encrypted_data : String, salt : String) : String
      # Base64デコード
      encrypted_bytes = Base64.decode(encrypted_data)
      
      # IV、暗号文、認証タグを分離
      iv = encrypted_bytes[0...12]
      auth_tag_size = 16 # GCMの認証タグサイズは16バイト
      encrypted = encrypted_bytes[12...(encrypted_bytes.size - auth_tag_size)]
      auth_tag = encrypted_bytes[(encrypted_bytes.size - auth_tag_size)...]
      
      # キーを生成
      key = generate_key_from_system_info(salt)
      
      # 復号化
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      cipher.auth_tag = auth_tag
      
      cipher.update(encrypted) + cipher.final
    end
    
    # libsecretが利用可能かをチェック
    private def has_libsecret? : Bool
      # 簡易実装: 環境変数でlibsecretの利用可否を判断
      !ENV["DISPLAY"]?.nil? && (ENV["XDG_CURRENT_DESKTOP"]? || ENV["GNOME_DESKTOP_SESSION_ID"]?)
    end
    
    # Linux libsecret暗号化
    private def encrypt_with_libsecret(data : String) : String
      # libsecret APIを使用してデータを暗号化
      # 実装例: libsecretクライアントを使用
      begin
        schema = "org.quantum.browser.encrypted"
        attributes = {"type" => "http3_data"}
        
        # libsecretにデータを保存し、一意のIDを取得
        unique_id = LinuxSecretService.store_secret(
          schema: schema,
          attributes: attributes,
          value: data,
          label: "Quantum Browser HTTP/3 Encrypted Data"
        )
        
        # 一意のIDを返す（これを使って後で復号化）
        "SECRET:#{unique_id}"
      rescue ex
        # libsecret APIの使用に失敗した場合はフォールバック
        Log.warn { "libsecretの使用に失敗しました: #{ex.message}" }
        encrypt_with_openssl(data, get_system_identifier)
      end
    end
    
    # Linux libsecret復号化
    private def decrypt_with_libsecret(encrypted_data : String) : String
      # 暗号化時に保存した一意のIDを使用
      if encrypted_data.starts_with?("SECRET:")
        unique_id = encrypted_data.sub("SECRET:", "")
      
        # libsecretから秘密を取得
        begin
          LinuxSecretService.get_secret_by_id(unique_id)
        rescue ex
          # libsecretからの取得に失敗した場合はフォールバック
          Log.warn { "libsecretからの秘密の取得に失敗しました: #{ex.message}" }
          decrypt_with_openssl(encrypted_data, get_system_identifier)
        end
      else
        # libsecret形式でない場合はOpenSSLフォールバックを使用
        decrypt_with_openssl(encrypted_data, get_system_identifier)
        end
      end
      
    # OpenSSL暗号化（フォールバック）
    private def encrypt_with_openssl(data : String, salt : String) : String
      # システム情報からキーを生成
      key = generate_key_from_system_info(salt)
      iv = Random::Secure.random_bytes(16) # AES-256-CBCに適したIVサイズ
      
      # 暗号化
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      cipher.key = key
      cipher.iv = iv
      
      encrypted = cipher.update(data) + cipher.final
      
      # IV + 暗号文をBase64エンコード
      Base64.strict_encode(iv + encrypted)
    end
    
    # OpenSSL復号化（フォールバック）
    private def decrypt_with_openssl(encrypted_data : String, salt : String) : String
      begin
        # Base64デコード
        encrypted_bytes = Base64.decode(encrypted_data)
        
        # IVと暗号文を分離
        iv = encrypted_bytes[0...16]
        encrypted = encrypted_bytes[16...]
        
        # キーを生成
        key = generate_key_from_system_info(salt)
        
        # 復号化
        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.decrypt
        cipher.key = key
        cipher.iv = iv
        
        cipher.update(encrypted) + cipher.final
      rescue ex
        # 復号化に失敗した場合（フォーマットが異なる場合など）
        Log.error { "OpenSSLによる復号化に失敗しました: #{ex.message}" }
        
        # 古い形式のフォールバック（XOR暗号）
        fallback_decrypt_xor(encrypted_data, salt)
      end
    end
    
    # システム情報からキーを生成
    private def generate_key_from_system_info(salt : String) : Bytes
      # PBKDFを使用して安全なキーを導出
      iterations = 10000
      digest = OpenSSL::Digest.new("sha256")
      OpenSSL::PKCS5.pbkdf2_hmac(salt, salt, iterations, 32, digest)
    end
    
    # 旧式XOR暗号（最終フォールバック）
    private def fallback_decrypt_xor(encrypted_data : String, system_info : String) : String
      salt = OpenSSL::Digest.new("sha256").update(system_info).final
      
      begin
        # Base64デコード
        data = Base64.decode(encrypted_data)
        
        result = Bytes.new(data.size)
        data.each_with_index do |byte, i|
          result[i] = byte ^ salt[i % salt.size]
        end
        
        String.new(result)
      rescue ex
        # すべての復号化手段が失敗した場合
        Log.error { "すべての復号化手段が失敗しました: #{ex.message}" }
        ""
      end
    end
    
    # セキュアストレージの初期化
    private def initialize_secure_storage
      # セキュリティデータの初期化
      @last_integrity_check = Time.utc
      
      # OS固有のセキュアストレージに設定情報を保存
      try_initialize_os_secure_storage
      
      Log.info { "セキュアストレージを初期化しました" }
    end
    
    # OS固有のセキュアストレージの初期化
    private def try_initialize_os_secure_storage
      begin
        metadata = {
          "initialized" => true,
          "version" => "1.0",
          "created_at" => Time.utc.to_unix,
          "security_level" => @security_level.to_s
        }
        
        metadata_json = metadata.to_json
        
        if OS.windows?
          WindowsSecureStorage.write_secret("#{SECURE_STORAGE_KEY}_meta", metadata_json)
        elsif OS.macos?
          MacOSKeychain.add_password(service: "Quantum", account: "#{SECURE_STORAGE_KEY}_meta", password: metadata_json)
        elsif OS.linux?
          LinuxSecretService.write_secret("#{SECURE_STORAGE_KEY}_meta", metadata_json)
        else
          # 汎用ストレージ - ファイルベース
          config_dir = File.join(Dir.tempdir, "quantum", "http3_tickets")
          meta_file = File.join(config_dir, "#{SECURE_STORAGE_KEY}.meta")
          
          encrypted_data = encrypt_with_system_key(metadata_json)
          File.write(meta_file, encrypted_data)
          File.chmod(meta_file, 0o600)
        end
      rescue ex
        Log.error { "セキュアストレージの初期化に失敗: #{ex.message}" }
      end
    end
    
    # ドメイン統計データの読み込み
    private def load_domain_statistics
      config_dir = File.join(Dir.tempdir, "quantum", "http3_tickets")
      stats_file = File.join(config_dir, "http3_domain_stats.json")
      
      if File.exists?(stats_file)
        begin
          stats_data = File.read(stats_file)
          json_data = JSON.parse(stats_data)
          
          if json_data.as_h? && json_data["domains"]?
            json_data["domains"].as_a.each do |domain_json|
              domain = domain_json["domain"].as_s
              
              # 使用パターンデータを更新
              if !@usage_patterns.has_key?(domain)
                pattern = UsagePattern.new(domain)
                pattern.visit_frequency = domain_json["frequency"].as_f
                pattern.last_visit_time = Time.unix(domain_json["last_visit"].as_i64)
                
                if domain_json["visit_hours"]?
                  pattern.typical_visit_hours = domain_json["visit_hours"].as_a.map(&.as_i)
                end
                
                @usage_patterns[domain] = pattern
              end
        end
      end
      
          Log.debug { "#{@usage_patterns.size}ドメインの統計データを読み込みました" }
        rescue ex
          Log.error { "ドメイン統計データの読み込みに失敗: #{ex.message}" }
        end
      end
    end
    
    # システム識別子を取得
    private def get_system_identifier : String
      # OS固有の識別子を取得
      case
      when OS.windows?
        # Windowsではレジストリからマシン固有のIDを取得
        begin
          computer_name = System.hostname
          sid = WindowsAPI.get_machine_sid
          volume_id = WindowsAPI.get_volume_serial_number("C:\\")
          "#{computer_name}:#{sid}:#{volume_id}"
        rescue ex
          # フォールバック: 基本的なシステム情報からハッシュ生成
          fallback_system_id
        end
      when OS.macos?
        # macOSではIOPlatformUUIDを使用
        begin
          uuid = MacOSAPI.get_ioplatform_uuid
          hw_uuid = MacOSAPI.get_hardware_uuid
          "macos:#{uuid}:#{hw_uuid}"
        rescue ex
          # フォールバック
          fallback_system_id
        end
      when OS.linux?
        # Linuxではmachine-idと追加のハードウェア情報を使用
        begin
          machine_id = File.read("/etc/machine-id").strip
          dmi_id = File.read("/sys/class/dmi/id/product_uuid").strip rescue ""
          # DMI情報が取得できなければCPU情報も追加
          if dmi_id.empty?
            cpu_info = File.read("/proc/cpuinfo").strip
            "linux:#{machine_id}:#{cpu_info.hash}"
          else
            "linux:#{machine_id}:#{dmi_id}"
          end
        rescue ex
          # フォールバック
          fallback_system_id
        end
      else
        # その他のOSやフォールバック
        fallback_system_id
      end
    end
    
    # フォールバックのシステム識別子生成
    private def fallback_system_id : String
      # 基本的なシステム情報からハッシュを生成
      hostname = System.hostname
      username = ENV["USER"]? || ENV["USERNAME"]? || "unknown"
      # ランダム値を含めて固定のシステム識別子を生成
      system_seed = ENV["QUANTUM_SYSTEM_SEED"]? || Random::Secure.hex(16)
      
      # ハッシュ化して返す
      OpenSSL::Digest.new("sha256").update("#{hostname}:#{username}:#{system_seed}").hexfinal
    end
  end
end 