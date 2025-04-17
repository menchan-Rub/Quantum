require "yaml"
require "json"

module QuantumCore
  # ブラウザエンジン全体の設定を管理するクラス
  class Config
    class CoreConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property render_threads : Int32 = 4
      property javascript_threads : Int32 = 2
      property max_memory_usage_mb : Int32 = 512
      property use_hardware_acceleration : Bool = true
      property developer_mode : Bool = false
      property experimental_features : Bool = false
      property process_isolation : Bool = true
      property memory_compression : Bool = true
      property gc_interval_ms : Int32 = 30000
      property startup_optimization : Bool = true
      property crash_reporting : Bool = true
      property telemetry_enabled : Bool = false
    end
    
    class NetworkConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property max_connections : Int32 = 6
      property connection_timeout_ms : Int32 = 30000
      property dns_cache_size : Int32 = 100
      property max_redirects : Int32 = 20
      property user_agent : String = "QuantumBrowser/0.1.0"
      property proxy_settings : Hash(String, String) = {} of String => String
      property enable_http2 : Bool = true
      property enable_http3 : Bool = false
      property connection_pool_size : Int32 = 100
      property dns_prefetching : Bool = true
      property tcp_fast_open : Bool = true
      property socket_recv_buffer_size : Int32 = 256 * 1024
      property socket_send_buffer_size : Int32 = 128 * 1024
      property enable_quic : Bool = false
      property tls_session_cache_size : Int32 = 100
      property enable_brotli : Bool = true
      property enable_websocket : Bool = true
      property websocket_max_message_size : Int32 = 16 * 1024 * 1024
    end
    
    class StorageConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property cache_size_mb : Int32 = 50
      property cookies_enabled : Bool = true
      property local_storage_size_mb : Int32 = 5
      property session_storage_size_mb : Int32 = 5
      property database_path : String = "~/.quantum/storage"
      property clear_cache_on_exit : Bool = false
      property indexed_db_enabled : Bool = true
      property indexed_db_size_mb : Int32 = 50
      property cache_compression : Bool = true
      property cache_strategy : String = "adaptive"
      property history_retention_days : Int32 = 90
      property sync_enabled : Bool = false
      property sync_interval_minutes : Int32 = 30
      property backup_enabled : Bool = true
      property backup_interval_days : Int32 = 7
    end
    
    class UIConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property theme : String = "system"
      property font_size : Int32 = 16
      property tab_position : String = "top"
      property show_bookmarks_bar : Bool = true
      property smooth_scrolling : Bool = true
      property enable_animations : Bool = true
      property ui_scale_factor : Float64 = 1.0
      property toolbar_style : String = "modern"
      property default_zoom : Float64 = 1.0
      property custom_css_enabled : Bool = false
      property custom_css_path : String = ""
      property tab_width_mode : String = "dynamic"
      property show_tab_previews : Bool = true
      property enable_picture_in_picture : Bool = true
      property reader_mode_enabled : Bool = true
      property reader_mode_font : String = "serif"
      property sidebar_enabled : Bool = true
      property sidebar_position : String = "left"
      property keyboard_shortcuts_enabled : Bool = true
    end
    
    class SecurityConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property sandbox_enabled : Bool = true
      property content_isolation : Bool = true
      property strict_site_isolation : Bool = true
      property webrtc_ip_handling_policy : String = "default_public_and_private_interfaces"
      property block_third_party_cookies : Bool = true
      property enable_tracking_protection : Bool = true
      property tracking_protection_level : String = "standard"
      property https_only_mode : Bool = false
      property certificate_verification : Bool = true
      property enable_xss_auditor : Bool = true
      property enable_referrer_control : Bool = true
      property referrer_policy : String = "strict-origin-when-cross-origin"
      property enable_content_security_policy : Bool = true
      property enable_mixed_content_blocking : Bool = true
    end
    
    class PerformanceConfig
      include YAML::Serializable
      include JSON::Serializable
      
      property preload_enabled : Bool = true
      property preconnect_enabled : Bool = true
      property prefetch_enabled : Bool = true
      property speculative_rendering : Bool = true
      property lazy_load_images : Bool = true
      property lazy_load_iframes : Bool = true
      property throttle_background_tabs : Bool = true
      property background_tab_throttle_factor : Float64 = 0.5
      property enable_resource_hints : Bool = true
      property enable_early_hints : Bool = false
      property enable_service_worker : Bool = true
      property enable_web_workers : Bool = true
      property enable_shared_workers : Bool = true
      property enable_webassembly : Bool = true
      property enable_webassembly_threads : Bool = true
      property enable_webgpu : Bool = false
    end
    
    include YAML::Serializable
    include JSON::Serializable
    
    property core : CoreConfig = CoreConfig.new
    property network : NetworkConfig = NetworkConfig.new
    property storage : StorageConfig = StorageConfig.new
    property ui : UIConfig = UIConfig.new
    property security : SecurityConfig = SecurityConfig.new
    property performance : PerformanceConfig = PerformanceConfig.new
    property extensions_enabled : Bool = true
    property extensions_path : String = "~/.quantum/extensions"
    property update_channel : String = "stable"
    property auto_update : Bool = true
    property locale : String = "auto"
    property accessibility_features_enabled : Bool = true
    
    # デフォルト設定を返す
    def self.default
      self.new
    end
    
    # ファイルから設定を読み込む
    def self.from_file(path : String)
      content = File.read(path)
      
      case File.extname(path).downcase
      when ".yml", ".yaml"
        self.from_yaml(content)
      when ".json"
        self.from_json(content)
      else
        raise "サポートされていない設定ファイル形式です: #{path}"
      end
    rescue e : Exception
      Log.error { "設定ファイルの読み込みに失敗しました: #{e.message}" }
      self.default
    end
    
    # 設定をファイルに保存
    def save_to_file(path : String)
      content = case File.extname(path).downcase
               when ".yml", ".yaml"
                 self.to_yaml
               when ".json"
                 self.to_json
               else
                 raise "サポートされていない設定ファイル形式です: #{path}"
               end
      
      # ディレクトリが存在しない場合は作成
      dir = File.dirname(path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      
      File.write(path, content)
    rescue e : Exception
      Log.error { "設定ファイルの保存に失敗しました: #{e.message}" }
      false
    end
    
    # 設定の検証
    def validate
      # メモリ使用量の最小値チェック
      if core.max_memory_usage_mb < 128
        raise "最小メモリ使用量は128MB以上である必要があります"
      end
      
      # ネットワーク設定の検証
      if network.max_connections < 1
        raise "最大接続数は1以上である必要があります"
      end
      
      if network.connection_timeout_ms < 1000
        raise "接続タイムアウトは1000ms以上である必要があります"
      end
      
      if network.websocket_max_message_size < 1024
        raise "WebSocketの最大メッセージサイズは1KB以上である必要があります"
      end
      
      # ストレージ設定の検証
      if storage.cache_size_mb < 0
        raise "キャッシュサイズは0以上である必要があります"
      end
      
      if storage.history_retention_days < 0
        raise "履歴保持日数は0以上である必要があります"
      end
      
      # UI設定の検証
      if ui.font_size < 8 || ui.font_size > 72
        raise "フォントサイズは8〜72の範囲内である必要があります"
      end
      
      if ui.default_zoom <= 0
        raise "デフォルトズームは正の値である必要があります"
      end
      
      # パフォーマンス設定の検証
      if performance.background_tab_throttle_factor < 0 || performance.background_tab_throttle_factor > 1
        raise "バックグラウンドタブのスロットル係数は0〜1の範囲内である必要があります"
      end
      
      true
    end
    
    # 環境変数から設定を上書き
    def apply_environment_variables
      # 環境変数からの設定上書き
      core.developer_mode = ENV["QUANTUM_DEVELOPER_MODE"]? == "true" if ENV.has_key?("QUANTUM_DEVELOPER_MODE")
      core.experimental_features = ENV["QUANTUM_EXPERIMENTAL"]? == "true" if ENV.has_key?("QUANTUM_EXPERIMENTAL")
      
      network.user_agent = ENV["QUANTUM_USER_AGENT"] if ENV.has_key?("QUANTUM_USER_AGENT")
      
      # プロキシ設定
      if ENV.has_key?("QUANTUM_PROXY_URL")
        network.proxy_settings["url"] = ENV["QUANTUM_PROXY_URL"]
      end
      
      # ロケール設定
      self.locale = ENV["QUANTUM_LOCALE"] if ENV.has_key?("QUANTUM_LOCALE")
      
      self
    end
    
    # 設定をマージする
    def merge(other : Config)
      # 他の設定オブジェクトから値をマージ
      result = self.dup
      
      # 各セクションの設定をマージ
      {% for section in ["core", "network", "storage", "ui", "security", "performance"] %}
        other.{{section.id}}.to_json.try do |json|
          temp = {{section.id.camelcase}}Config.from_json(json)
          result.{{section.id}} = temp
        end
      {% end %}
      
      # トップレベルのプロパティをマージ
      result.extensions_enabled = other.extensions_enabled
      result.extensions_path = other.extensions_path
      result.update_channel = other.update_channel
      result.auto_update = other.auto_update
      result.locale = other.locale
      result.accessibility_features_enabled = other.accessibility_features_enabled
      
      result
    end
    
    # 設定をリセット
    def reset
      @core = CoreConfig.new
      @network = NetworkConfig.new
      @storage = StorageConfig.new
      @ui = UIConfig.new
      @security = SecurityConfig.new
      @performance = PerformanceConfig.new
      @extensions_enabled = true
      @extensions_path = "~/.quantum/extensions"
      @update_channel = "stable"
      @auto_update = true
      @locale = "auto"
      @accessibility_features_enabled = true
      self
    end
  end
end