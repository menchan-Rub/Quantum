require "yaml"
require "json"
require "log"

module QuantumCore
  class ConfigError < Exception
    def initialize(message : String, cause : Exception? = nil)
      super(message, cause)
    end
  end

  # ブラウザの設定を管理するクラス
  class Config
    # 基本設定
    property user_agent : String
    property homepage : String
    property download_directory : String
    property cache_enabled : Bool
    property javascript_enabled : Bool
    property cookie_policy : CookiePolicy
    property language : String
    
    # ネットワーク設定
    property network : NetworkConfig
    
    # UI設定
    property ui : UIConfig
    
    # ストレージ設定
    property storage : StorageConfig
    
    # コア設定
    property core : CoreConfig
    
    # Cookie ポリシー
    enum CookiePolicy
      ACCEPT_ALL
      REJECT_THIRD_PARTY
      REJECT_ALL
      ASK
    end
    
    def initialize(
      @user_agent : String = "QuantumBrowser/#{QuantumBrowser::VERSION} (Crystal)",
      @homepage : String = "https://www.quantum-browser.org/",
      @download_directory : String = "~/Downloads",
      @cache_enabled : Bool = true,
      @javascript_enabled : Bool = true,
      @cookie_policy : CookiePolicy = CookiePolicy::REJECT_THIRD_PARTY,
      @language : String = "ja",
      @network : NetworkConfig = NetworkConfig.new,
      @ui : UIConfig = UIConfig.new,
      @storage : StorageConfig = StorageConfig.new,
      @core : CoreConfig = CoreConfig.new
    )
    end
    
    # デフォルト設定を取得
    def self.default
      new
    end
    
    # ファイルから設定を読み込む
    def self.from_file(file_path : String) : Config
      config = nil
      
      # ファイル拡張子に基づいて解析
      if file_path.ends_with?(".yml") || file_path.ends_with?(".yaml")
        config_yaml = File.read(file_path)
        config = from_yaml(config_yaml)
      elsif file_path.ends_with?(".json")
        config_json = File.read(file_path)
        config = from_json(config_json)
      else
        # デフォルトはYAMLとして試行
        begin
          config_yaml = File.read(file_path)
          config = from_yaml(config_yaml)
        rescue
          # YAMLとして解析できなければJSONを試行
          config_json = File.read(file_path)
          config = from_json(config_json)
        end
      end
      
      config || default
    end
    
    # YAMLから設定を読み込む
    def self.from_yaml(yaml_string : String) : Config
      config_data = YAML.parse(yaml_string)
      
      # YAML構造からConfigオブジェクトを構築
      config = default
      
      # 基本設定
      config.user_agent = config_data["user_agent"].as_s if config_data["user_agent"]?
      config.homepage = config_data["homepage"].as_s if config_data["homepage"]?
      config.download_directory = config_data["download_directory"].as_s if config_data["download_directory"]?
      config.cache_enabled = config_data["cache_enabled"].as_bool if config_data["cache_enabled"]?
      config.javascript_enabled = config_data["javascript_enabled"].as_bool if config_data["javascript_enabled"]?
      
      if config_data["cookie_policy"]?
        case config_data["cookie_policy"].as_s
        when "accept_all"
          config.cookie_policy = CookiePolicy::ACCEPT_ALL
        when "reject_third_party"
          config.cookie_policy = CookiePolicy::REJECT_THIRD_PARTY
        when "reject_all"
          config.cookie_policy = CookiePolicy::REJECT_ALL
        when "ask"
          config.cookie_policy = CookiePolicy::ASK
        end
      end
      
      config.language = config_data["language"].as_s if config_data["language"]?
      
      # ネットワーク設定
      if config_data["network"]?
        config.network = NetworkConfig.from_yaml_node(config_data["network"])
      end
      
      # UI設定
      if config_data["ui"]?
        config.ui = UIConfig.from_yaml_node(config_data["ui"])
      end
      
      # ストレージ設定
      if config_data["storage"]?
        config.storage = StorageConfig.from_yaml_node(config_data["storage"])
      end
      
      # コア設定
      if config_data["core"]?
        config.core = CoreConfig.from_yaml_node(config_data["core"])
      end
      
      config
    end
    
    # JSONから設定を読み込む
    def self.from_json(json_string : String) : Config
      config_data = JSON.parse(json_string)
      
      # JSON構造からConfigオブジェクトを構築
      config = default
      
      # 基本設定
      config.user_agent = config_data["user_agent"].as_s if config_data["user_agent"]?
      config.homepage = config_data["homepage"].as_s if config_data["homepage"]?
      config.download_directory = config_data["download_directory"].as_s if config_data["download_directory"]?
      config.cache_enabled = config_data["cache_enabled"].as_bool if config_data["cache_enabled"]?
      config.javascript_enabled = config_data["javascript_enabled"].as_bool if config_data["javascript_enabled"]?
      
      if config_data["cookie_policy"]?
        case config_data["cookie_policy"].as_s
        when "accept_all"
          config.cookie_policy = CookiePolicy::ACCEPT_ALL
        when "reject_third_party"
          config.cookie_policy = CookiePolicy::REJECT_THIRD_PARTY
        when "reject_all"
          config.cookie_policy = CookiePolicy::REJECT_ALL
        when "ask"
          config.cookie_policy = CookiePolicy::ASK
        end
      end
      
      config.language = config_data["language"].as_s if config_data["language"]?
      
      # ネットワーク設定
      if config_data["network"]?
        config.network = NetworkConfig.from_json_node(config_data["network"])
      end
      
      # UI設定
      if config_data["ui"]?
        config.ui = UIConfig.from_json_node(config_data["ui"])
      end
      
      # ストレージ設定
      if config_data["storage"]?
        config.storage = StorageConfig.from_json_node(config_data["storage"])
      end
      
      # コア設定
      if config_data["core"]?
        config.core = CoreConfig.from_json_node(config_data["core"])
      end
      
      config
    end
    
    # 設定をYAMLに変換
    def to_yaml
      YAML.build do |yaml|
        to_yaml(yaml)
      end
    end
    
    # 設定をYAMLノードに変換
    def to_yaml(yaml : YAML::Builder)
      yaml.mapping do
        yaml.scalar "user_agent"
        yaml.scalar @user_agent
        
        yaml.scalar "homepage"
        yaml.scalar @homepage
        
        yaml.scalar "download_directory"
        yaml.scalar @download_directory
        
        yaml.scalar "cache_enabled"
        yaml.scalar @cache_enabled
        
        yaml.scalar "javascript_enabled"
        yaml.scalar @javascript_enabled
        
        yaml.scalar "cookie_policy"
        yaml.scalar @cookie_policy.to_s.downcase
        
        yaml.scalar "language"
        yaml.scalar @language
        
        yaml.scalar "network"
        @network.to_yaml(yaml)
        
        yaml.scalar "ui"
        @ui.to_yaml(yaml)
        
        yaml.scalar "storage"
        @storage.to_yaml(yaml)
        
        yaml.scalar "core"
        @core.to_yaml(yaml)
      end
    end
    
    # 設定をJSONに変換
    def to_json
      JSON.build do |json|
        to_json(json)
      end
    end
    
    # 設定をJSONビルダーに変換
    def to_json(json : JSON::Builder)
      json.object do
        json.field "user_agent", @user_agent
        json.field "homepage", @homepage
        json.field "download_directory", @download_directory
        json.field "cache_enabled", @cache_enabled
        json.field "javascript_enabled", @javascript_enabled
        json.field "cookie_policy", @cookie_policy.to_s.downcase
        json.field "language", @language
        
        json.field "network" do
          @network.to_json(json)
        end
        
        json.field "ui" do
          @ui.to_json(json)
        end
        
        json.field "storage" do
          @storage.to_json(json)
        end
        
        json.field "core" do
          @core.to_json(json)
        end
      end
    end
  end
  
  # ネットワーク設定
  class NetworkConfig
    property max_connections : Int32
    property timeout : Int32
    property retries : Int32
    property proxy_enabled : Bool
    property proxy_url : String?
    property user_agent_override : String?
    property dns_prefetch : Bool
    property http_cache_size_mb : Int32
    
    # HTTP/3関連設定を追加
    property enable_http3 : Bool
    property enable_quic : Bool
    property enable_http2 : Bool
    property http3_priority_enabled : Bool
    property http3_early_data_enabled : Bool
    property http3_settings_profiles : Hash(String, Http3SettingsProfile)
    
    # HTTP/3設定
    class HTTP3Settings
      property enable_http3 : Bool = true
      property enable_quic : Bool = true
      property max_concurrent_streams : Int32 = 100
      property enable_0rtt : Bool = true
      property qpack_table_capacity : Int32 = 4096    # 4KB
      property max_field_section_size : Int32 = 65536 # 64KB
      property qpack_blocked_streams : Int32 = 16
      property flow_control_window : Int32 = 16777216 # 16MB
      property idle_timeout_ms : Int32 = 30000        # 30秒
      property multipath_mode : String = "dynamic"    # disabled, handover, aggregation, dynamic
      property enable_adaptive_pacing : Bool = true
      property congestion_controller : String = "cubic" # cubic, bbr, prague
      property default_rtt_ms : Int32 = 100           # 100ms
      property enable_datagram : Bool = true
      property max_streams_bidi : Int32 = 100
      property max_streams_uni : Int32 = 100

      # ゼロコピー設定
      property enable_zero_copy : Bool = true
      property zero_copy_threshold : Int32 = 16384  # 16KB以上でゼロコピー有効

      # 暗号化設定
      property enable_hardware_crypto : Bool = true  # ハードウェア支援暗号化
      property tls_ciphers : Array(String) = [
        "TLS_AES_128_GCM_SHA256",
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256"
      ]

      def initialize
      end

      def initialize(yaml : YAML::Any)
        if http3 = yaml["http3"]?
          @enable_http3 = http3["enable"].as_bool if http3["enable"]?
          @enable_quic = http3["enable_quic"].as_bool if http3["enable_quic"]?
          @max_concurrent_streams = http3["max_concurrent_streams"].as_i if http3["max_concurrent_streams"]?
          @enable_0rtt = http3["enable_0rtt"].as_bool if http3["enable_0rtt"]?
          @qpack_table_capacity = http3["qpack_table_capacity"].as_i if http3["qpack_table_capacity"]?
          @max_field_section_size = http3["max_field_section_size"].as_i if http3["max_field_section_size"]?
          @qpack_blocked_streams = http3["qpack_blocked_streams"].as_i if http3["qpack_blocked_streams"]?
          @flow_control_window = http3["flow_control_window"].as_i if http3["flow_control_window"]?
          @idle_timeout_ms = http3["idle_timeout_ms"].as_i if http3["idle_timeout_ms"]?
          @multipath_mode = http3["multipath_mode"].as_s if http3["multipath_mode"]?
          @enable_adaptive_pacing = http3["enable_adaptive_pacing"].as_bool if http3["enable_adaptive_pacing"]?
          @congestion_controller = http3["congestion_controller"].as_s if http3["congestion_controller"]?
          @default_rtt_ms = http3["default_rtt_ms"].as_i if http3["default_rtt_ms"]?
          @enable_datagram = http3["enable_datagram"].as_bool if http3["enable_datagram"]?
          @max_streams_bidi = http3["max_streams_bidi"].as_i if http3["max_streams_bidi"]?
          @max_streams_uni = http3["max_streams_uni"].as_i if http3["max_streams_uni"]?
          
          if zero_copy = http3["zero_copy"]?
            @enable_zero_copy = zero_copy["enable"].as_bool if zero_copy["enable"]?
            @zero_copy_threshold = zero_copy["threshold"].as_i if zero_copy["threshold"]?
          end
          
          if crypto = http3["crypto"]?
            @enable_hardware_crypto = crypto["enable_hardware"].as_bool if crypto["enable_hardware"]?
            @tls_ciphers = crypto["ciphers"].as_a.map(&.as_s) if crypto["ciphers"]?
          end
        end
      end
      
      def to_yaml(yaml : YAML::Nodes::Builder)
        yaml.mapping do
          yaml.scalar "enable"
          yaml.scalar @enable_http3.to_s
          
          yaml.scalar "enable_quic"
          yaml.scalar @enable_quic.to_s
          
          yaml.scalar "max_concurrent_streams"
          yaml.scalar @max_concurrent_streams.to_s
          
          yaml.scalar "enable_0rtt"
          yaml.scalar @enable_0rtt.to_s
          
          yaml.scalar "qpack_table_capacity"
          yaml.scalar @qpack_table_capacity.to_s
          
          yaml.scalar "max_field_section_size"
          yaml.scalar @max_field_section_size.to_s
          
          yaml.scalar "qpack_blocked_streams"
          yaml.scalar @qpack_blocked_streams.to_s
          
          yaml.scalar "flow_control_window"
          yaml.scalar @flow_control_window.to_s
          
          yaml.scalar "idle_timeout_ms"
          yaml.scalar @idle_timeout_ms.to_s
          
          yaml.scalar "multipath_mode"
          yaml.scalar @multipath_mode
          
          yaml.scalar "enable_adaptive_pacing"
          yaml.scalar @enable_adaptive_pacing.to_s
          
          yaml.scalar "congestion_controller"
          yaml.scalar @congestion_controller
          
          yaml.scalar "default_rtt_ms"
          yaml.scalar @default_rtt_ms.to_s
          
          yaml.scalar "enable_datagram"
          yaml.scalar @enable_datagram.to_s
          
          yaml.scalar "max_streams_bidi"
          yaml.scalar @max_streams_bidi.to_s
          
          yaml.scalar "max_streams_uni"
          yaml.scalar @max_streams_uni.to_s
          
          yaml.scalar "zero_copy"
          yaml.mapping do
            yaml.scalar "enable"
            yaml.scalar @enable_zero_copy.to_s
            
            yaml.scalar "threshold"
            yaml.scalar @zero_copy_threshold.to_s
          end
          
          yaml.scalar "crypto"
          yaml.mapping do
            yaml.scalar "enable_hardware"
            yaml.scalar @enable_hardware_crypto.to_s
            
            yaml.scalar "ciphers"
            yaml.sequence do
              @tls_ciphers.each do |cipher|
                yaml.scalar cipher
              end
            end
          end
        end
      end
    end
    
    # リソース予測設定
    class ResourcePredictionSettings
      property enable_prediction : Bool = true
      property prediction_model : String = "advanced" # disabled, basic, advanced, user_adaptive
      property enable_viewport_tracking : Bool = true
      property prefetch_limit : Int32 = 5
      property prefetch_threshold : Float64 = 0.7
      property max_prediction_depth : Int32 = 3
      property prediction_mode : String = "aggressive" # conservative, moderate, aggressive
      
      def initialize
      end
      
      def initialize(yaml : YAML::Any)
        if prediction = yaml["prediction"]?
          @enable_prediction = prediction["enable"].as_bool if prediction["enable"]?
          @prediction_model = prediction["model"].as_s if prediction["model"]?
          @enable_viewport_tracking = prediction["viewport_tracking"].as_bool if prediction["viewport_tracking"]?
          @prefetch_limit = prediction["prefetch_limit"].as_i if prediction["prefetch_limit"]?
          @prefetch_threshold = prediction["prefetch_threshold"].as_f if prediction["prefetch_threshold"]?
          @max_prediction_depth = prediction["max_depth"].as_i if prediction["max_depth"]?
          @prediction_mode = prediction["mode"].as_s if prediction["mode"]?
        end
      end
      
      def to_yaml(yaml : YAML::Nodes::Builder)
        yaml.mapping do
          yaml.scalar "enable"
          yaml.scalar @enable_prediction.to_s
          
          yaml.scalar "model"
          yaml.scalar @prediction_model
          
          yaml.scalar "viewport_tracking"
          yaml.scalar @enable_viewport_tracking.to_s
          
          yaml.scalar "prefetch_limit"
          yaml.scalar @prefetch_limit.to_s
          
          yaml.scalar "prefetch_threshold"
          yaml.scalar @prefetch_threshold.to_s
          
          yaml.scalar "max_depth"
          yaml.scalar @max_prediction_depth.to_s
          
          yaml.scalar "mode"
          yaml.scalar @prediction_mode
        end
      end
    end
    
    # 一般的なネットワーク設定
    property enable_http2 : Bool = true
    property default_protocol : String = "auto" # http1, http2, http3, auto
    property connection_pool_size : Int32 = 30
    property connection_timeout_ms : Int32 = 30000
    property user_agent : String = "QuantumBrowser/1.0"
    
    # HTTP/3 詳細設定
    property http3 : HTTP3Settings = HTTP3Settings.new
    
    # リソース予測設定
    property resource_prediction : ResourcePredictionSettings = ResourcePredictionSettings.new
    
    # データグラム・マルチキャスト
    property enable_websocket : Bool = true
    property enable_webrtc : Bool = true
    property enable_sse : Bool = true
    
    def initialize(
      @max_connections : Int32 = 10,
      @timeout : Int32 = 30,
      @retries : Int32 = 3,
      @proxy_enabled : Bool = false,
      @proxy_url : String? = nil,
      @user_agent_override : String? = nil,
      @dns_prefetch : Bool = true,
      @http_cache_size_mb : Int32 = 100,
      
      # HTTP/3設定のデフォルト値
      @enable_http3 : Bool = true,
      @enable_quic : Bool = true,
      @enable_http2 : Bool = true,
      @http3_priority_enabled : Bool = true,
      @http3_early_data_enabled : Bool = true,
      @http3_settings_profiles : Hash(String, Http3SettingsProfile) = default_http3_profiles
    )
    end
    
    # HTTP/3設定プロファイル
    class Http3SettingsProfile
      property name : String
      property qpack_table_capacity : Int32
      property max_field_section_size : Int32
      property qpack_blocked_streams : Int32
      property flow_control_window : Int32
      property max_concurrent_streams : Int32
      property initial_rtt : Int32
      property idle_timeout : Int32
      
      def initialize(
        @name : String,
        @qpack_table_capacity : Int32 = 4096,
        @max_field_section_size : Int32 = 65536,
        @qpack_blocked_streams : Int32 = 16,
        @flow_control_window : Int32 = 16777216,
        @max_concurrent_streams : Int32 = 100,
        @initial_rtt : Int32 = 100,
        @idle_timeout : Int32 = 30000
      )
      end
      
      def self.from_yaml_node(node) : Http3SettingsProfile
        profile = new(
          name: node["name"]?.try(&.as_s) || "default"
        )
        
        profile.qpack_table_capacity = node["qpack_table_capacity"].as_i if node["qpack_table_capacity"]?
        profile.max_field_section_size = node["max_field_section_size"].as_i if node["max_field_section_size"]?
        profile.qpack_blocked_streams = node["qpack_blocked_streams"].as_i if node["qpack_blocked_streams"]?
        profile.flow_control_window = node["flow_control_window"].as_i if node["flow_control_window"]?
        profile.max_concurrent_streams = node["max_concurrent_streams"].as_i if node["max_concurrent_streams"]?
        profile.initial_rtt = node["initial_rtt"].as_i if node["initial_rtt"]?
        profile.idle_timeout = node["idle_timeout"].as_i if node["idle_timeout"]?
        
        profile
      end
      
      def self.from_json_node(node) : Http3SettingsProfile
        profile = new(
          name: node["name"]?.try(&.as_s) || "default"
        )
        
        profile.qpack_table_capacity = node["qpack_table_capacity"].as_i if node["qpack_table_capacity"]?
        profile.max_field_section_size = node["max_field_section_size"].as_i if node["max_field_section_size"]?
        profile.qpack_blocked_streams = node["qpack_blocked_streams"].as_i if node["qpack_blocked_streams"]?
        profile.flow_control_window = node["flow_control_window"].as_i if node["flow_control_window"]?
        profile.max_concurrent_streams = node["max_concurrent_streams"].as_i if node["max_concurrent_streams"]?
        profile.initial_rtt = node["initial_rtt"].as_i if node["initial_rtt"]?
        profile.idle_timeout = node["idle_timeout"].as_i if node["idle_timeout"]?
        
        profile
      end
    end
    
    # デフォルトのHTTP/3プロファイルを生成
    def self.default_http3_profiles : Hash(String, Http3SettingsProfile)
      profiles = {} of String => Http3SettingsProfile
      
      # バランス型（デフォルト）
      profiles["balanced"] = Http3SettingsProfile.new(
        name: "balanced",
        qpack_table_capacity: 4096,
        max_field_section_size: 65536,
        qpack_blocked_streams: 16,
        flow_control_window: 16777216,
        max_concurrent_streams: 100,
        initial_rtt: 100,
        idle_timeout: 30000
      )
      
      # 低遅延型
      profiles["low_latency"] = Http3SettingsProfile.new(
        name: "low_latency",
        qpack_table_capacity: 8192,
        max_field_section_size: 65536,
        qpack_blocked_streams: 32,
        flow_control_window: 16777216,
        max_concurrent_streams: 200,
        initial_rtt: 50,
        idle_timeout: 15000
      )
      
      # 高スループット型
      profiles["high_throughput"] = Http3SettingsProfile.new(
        name: "high_throughput",
        qpack_table_capacity: 65536,
        max_field_section_size: 262144,
        qpack_blocked_streams: 64,
        flow_control_window: 67108864,
        max_concurrent_streams: 500,
        initial_rtt: 100,
        idle_timeout: 60000
      )
      
      # 低帯域型
      profiles["low_bandwidth"] = Http3SettingsProfile.new(
        name: "low_bandwidth",
        qpack_table_capacity: 1024,
        max_field_section_size: 16384,
        qpack_blocked_streams: 4,
        flow_control_window: 4194304,
        max_concurrent_streams: 10,
        initial_rtt: 300,
        idle_timeout: 30000
      )
      
      # バッテリー効率型
      profiles["battery_efficient"] = Http3SettingsProfile.new(
        name: "battery_efficient",
        qpack_table_capacity: 2048,
        max_field_section_size: 32768,
        qpack_blocked_streams: 8,
        flow_control_window: 8388608,
        max_concurrent_streams: 20,
        initial_rtt: 150,
        idle_timeout: 15000
      )
      
      profiles
    end
    
    # YAMLノードから設定を読み込む
    def self.from_yaml_node(node) : NetworkConfig
      config = new
      
      config.max_connections = node["max_connections"].as_i if node["max_connections"]?
      config.timeout = node["timeout"].as_i if node["timeout"]?
      config.retries = node["retries"].as_i if node["retries"]?
      config.proxy_enabled = node["proxy_enabled"].as_bool if node["proxy_enabled"]?
      config.proxy_url = node["proxy_url"].as_s if node["proxy_url"]?
      config.user_agent_override = node["user_agent_override"].as_s if node["user_agent_override"]?
      config.dns_prefetch = node["dns_prefetch"].as_bool if node["dns_prefetch"]?
      config.http_cache_size_mb = node["http_cache_size_mb"].as_i if node["http_cache_size_mb"]?
      
      # HTTP/3設定の読み込み
      config.enable_http3 = node["enable_http3"].as_bool if node["enable_http3"]?
      config.enable_quic = node["enable_quic"].as_bool if node["enable_quic"]?
      config.enable_http2 = node["enable_http2"].as_bool if node["enable_http2"]?
      config.http3_priority_enabled = node["http3_priority_enabled"].as_bool if node["http3_priority_enabled"]?
      config.http3_early_data_enabled = node["http3_early_data_enabled"].as_bool if node["http3_early_data_enabled"]?
      
      # HTTP/3プロファイルの読み込み
      if node["http3_settings_profiles"]?
        profiles = {} of String => Http3SettingsProfile
        
        node["http3_settings_profiles"].as_h.each do |name, profile_node|
          profile = Http3SettingsProfile.from_yaml_node(profile_node)
          profiles[name.as_s] = profile
        end
        
        config.http3_settings_profiles = profiles unless profiles.empty?
      end
      
      config
    end
    
    # JSONノードから設定を読み込む
    def self.from_json_node(node) : NetworkConfig
      config = new
      
      config.max_connections = node["max_connections"].as_i if node["max_connections"]?
      config.timeout = node["timeout"].as_i if node["timeout"]?
      config.retries = node["retries"].as_i if node["retries"]?
      config.proxy_enabled = node["proxy_enabled"].as_bool if node["proxy_enabled"]?
      config.proxy_url = node["proxy_url"].as_s if node["proxy_url"]?
      config.user_agent_override = node["user_agent_override"].as_s if node["user_agent_override"]?
      config.dns_prefetch = node["dns_prefetch"].as_bool if node["dns_prefetch"]?
      config.http_cache_size_mb = node["http_cache_size_mb"].as_i if node["http_cache_size_mb"]?
      
      # HTTP/3設定の読み込み
      config.enable_http3 = node["enable_http3"].as_bool if node["enable_http3"]?
      config.enable_quic = node["enable_quic"].as_bool if node["enable_quic"]?
      config.enable_http2 = node["enable_http2"].as_bool if node["enable_http2"]?
      config.http3_priority_enabled = node["http3_priority_enabled"].as_bool if node["http3_priority_enabled"]?
      config.http3_early_data_enabled = node["http3_early_data_enabled"].as_bool if node["http3_early_data_enabled"]?
      
      # HTTP/3プロファイルの読み込み
      if node["http3_settings_profiles"]?
        profiles = {} of String => Http3SettingsProfile
        
        node["http3_settings_profiles"].as_h.each do |name, profile_node|
          profile = Http3SettingsProfile.from_json_node(profile_node)
          profiles[name.as_s] = profile
        end
        
        config.http3_settings_profiles = profiles unless profiles.empty?
      end
      
      config
    end
    
    # 設定をYAMLノードに変換
    def to_yaml(yaml : YAML::Builder)
      yaml.mapping do
        yaml.scalar "max_connections"
        yaml.scalar @max_connections
        
        yaml.scalar "timeout"
        yaml.scalar @timeout
        
        yaml.scalar "retries"
        yaml.scalar @retries
        
        yaml.scalar "proxy_enabled"
        yaml.scalar @proxy_enabled
        
        if @proxy_url
          yaml.scalar "proxy_url"
          yaml.scalar @proxy_url
        end
        
        if @user_agent_override
          yaml.scalar "user_agent_override"
          yaml.scalar @user_agent_override
        end
        
        yaml.scalar "dns_prefetch"
        yaml.scalar @dns_prefetch
        
        yaml.scalar "http_cache_size_mb"
        yaml.scalar @http_cache_size_mb
      end
    end
    
    # 設定をJSONビルダーに変換
    def to_json(json : JSON::Builder)
      json.object do
        json.field "max_connections", @max_connections
        json.field "timeout", @timeout
        json.field "retries", @retries
        json.field "proxy_enabled", @proxy_enabled
        json.field "proxy_url", @proxy_url if @proxy_url
        json.field "dns_prefetch", @dns_prefetch
        json.field "http_cache_size_mb", @http_cache_size_mb
      end
    end
  end
  
  # UI設定
  class UIConfig
    property theme : String
    property font_family : String
    property font_size : Int32
    property tab_position : TabPosition
    property toolbar_visible : Bool
    property bookmarks_visible : Bool
    property status_bar_visible : Bool
    property dark_mode : Bool
    property zoom_level : Float64
    # ウィンドウタイトル
    property title : String
    # ウィンドウ幅 (ピクセル)
    property width : Int32
    # ウィンドウ高さ (ピクセル)
    property height : Int32
    
    # タブの位置
    enum TabPosition
      TOP
      BOTTOM
      LEFT
      RIGHT
    end
    
    def initialize(
      @title : String = "QuantumBrowser",
      @width : Int32 = 1280,
      @height : Int32 = 720,
      @theme : String = "default",
      @font_family : String = "Noto Sans",
      @font_size : Int32 = 16,
      @tab_position : TabPosition = TabPosition::TOP,
      @toolbar_visible : Bool = true,
      @bookmarks_visible : Bool = true,
      @status_bar_visible : Bool = true,
      @dark_mode : Bool = false,
      @zoom_level : Float64 = 1.0
    )
    end
    
    # YAMLノードから設定を読み込む
    def self.from_yaml_node(node)
      config = new
      
      config.title = node["title"].as_s if node["title"]?
      config.width = node["width"].as_i if node["width"]?
      config.height = node["height"].as_i if node["height"]?
      config.theme = node["theme"].as_s if node["theme"]?
      config.font_family = node["font_family"].as_s if node["font_family"]?
      config.font_size = node["font_size"].as_i if node["font_size"]?
      
      if node["tab_position"]?
        case node["tab_position"].as_s
        when "top"
          config.tab_position = TabPosition::TOP
        when "bottom"
          config.tab_position = TabPosition::BOTTOM
        when "left"
          config.tab_position = TabPosition::LEFT
        when "right"
          config.tab_position = TabPosition::RIGHT
        end
      end
      
      config.toolbar_visible = node["toolbar_visible"].as_bool if node["toolbar_visible"]?
      config.bookmarks_visible = node["bookmarks_visible"].as_bool if node["bookmarks_visible"]?
      config.status_bar_visible = node["status_bar_visible"].as_bool if node["status_bar_visible"]?
      config.dark_mode = node["dark_mode"].as_bool if node["dark_mode"]?
      config.zoom_level = node["zoom_level"].as_f if node["zoom_level"]?
      
      config
    end
    
    # JSONノードから設定を読み込む
    def self.from_json_node(node)
      config = new
      
      config.title = node["title"].as_s if node["title"]?
      config.width = node["width"].as_i if node["width"]?
      config.height = node["height"].as_i if node["height"]?
      config.theme = node["theme"].as_s if node["theme"]?
      config.font_family = node["font_family"].as_s if node["font_family"]?
      config.font_size = node["font_size"].as_i if node["font_size"]?
      
      if node["tab_position"]?
        case node["tab_position"].as_s
        when "top"
          config.tab_position = TabPosition::TOP
        when "bottom"
          config.tab_position = TabPosition::BOTTOM
        when "left"
          config.tab_position = TabPosition::LEFT
        when "right"
          config.tab_position = TabPosition::RIGHT
        end
      end
      
      config.toolbar_visible = node["toolbar_visible"].as_bool if node["toolbar_visible"]?
      config.bookmarks_visible = node["bookmarks_visible"].as_bool if node["bookmarks_visible"]?
      config.status_bar_visible = node["status_bar_visible"].as_bool if node["status_bar_visible"]?
      config.dark_mode = node["dark_mode"].as_bool if node["dark_mode"]?
      config.zoom_level = node["zoom_level"].as_f if node["zoom_level"]?
      
      config
    end
    
    # 設定をYAMLノードに変換
    def to_yaml(yaml : YAML::Builder)
      yaml.mapping do
        yaml.scalar "title"
        yaml.scalar @title
        yaml.scalar "width"
        yaml.scalar @width
        yaml.scalar "height"
        yaml.scalar @height
        yaml.scalar "theme"
        yaml.scalar @theme
        yaml.scalar "font_family"
        yaml.scalar @font_family
        yaml.scalar "font_size"
        yaml.scalar @font_size
        yaml.scalar "tab_position"
        yaml.scalar @tab_position.to_s.downcase
        yaml.scalar "toolbar_visible"
        yaml.scalar @toolbar_visible
        yaml.scalar "bookmarks_visible"
        yaml.scalar @bookmarks_visible
        yaml.scalar "status_bar_visible"
        yaml.scalar @status_bar_visible
        yaml.scalar "dark_mode"
        yaml.scalar @dark_mode
        yaml.scalar "zoom_level"
        yaml.scalar @zoom_level
      end
    end
    
    # 設定をJSONビルダーに変換
    def to_json(json : JSON::Builder)
      json.object do
        json.field "title", @title
        json.field "width", @width
        json.field "height", @height
        json.field "theme", @theme
        json.field "font_family", @font_family
        json.field "font_size", @font_size
        json.field "tab_position", @tab_position.to_s.downcase
        json.field "toolbar_visible", @toolbar_visible
        json.field "bookmarks_visible", @bookmarks_visible
        json.field "status_bar_visible", @status_bar_visible
        json.field "dark_mode", @dark_mode
        json.field "zoom_level", @zoom_level
      end
    end
  end
  
  # ストレージ設定
  class StorageConfig
    property profile_directory : String
    property enable_sync : Bool
    property sync_interval : Int32
    property max_history_items : Int32
    property clear_history_on_exit : Bool
    property cookie_storage_policy : CookieStoragePolicy
    property password_storage_policy : PasswordStoragePolicy
    
    # Cookieストレージポリシー
    enum CookieStoragePolicy
      ALLOW_ALL
      BLOCK_THIRD_PARTY
      BLOCK_ALL
      SESSION_ONLY
    end
    
    # パスワードストレージポリシー
    enum PasswordStoragePolicy
      STORE_ENCRYPTED
      NEVER_STORE
      ASK_BEFORE_STORE
    end
    
    def initialize(
      @profile_directory : String = "~/.quantum_browser",
      @enable_sync : Bool = false,
      @sync_interval : Int32 = 60,
      @max_history_items : Int32 = 10000,
      @clear_history_on_exit : Bool = false,
      @cookie_storage_policy : CookieStoragePolicy = CookieStoragePolicy::BLOCK_THIRD_PARTY,
      @password_storage_policy : PasswordStoragePolicy = PasswordStoragePolicy::ASK_BEFORE_STORE
    )
    end
    
    # YAMLノードから設定を読み込む
    def self.from_yaml_node(node)
      config = new
      
      config.profile_directory = node["profile_directory"].as_s if node["profile_directory"]?
      config.enable_sync = node["enable_sync"].as_bool if node["enable_sync"]?
      config.sync_interval = node["sync_interval"].as_i if node["sync_interval"]?
      config.max_history_items = node["max_history_items"].as_i if node["max_history_items"]?
      config.clear_history_on_exit = node["clear_history_on_exit"].as_bool if node["clear_history_on_exit"]?
      
      if node["cookie_storage_policy"]?
        case node["cookie_storage_policy"].as_s
        when "allow_all"
          config.cookie_storage_policy = CookieStoragePolicy::ALLOW_ALL
        when "block_third_party"
          config.cookie_storage_policy = CookieStoragePolicy::BLOCK_THIRD_PARTY
        when "block_all"
          config.cookie_storage_policy = CookieStoragePolicy::BLOCK_ALL
        when "session_only"
          config.cookie_storage_policy = CookieStoragePolicy::SESSION_ONLY
        end
      end
      
      if node["password_storage_policy"]?
        case node["password_storage_policy"].as_s
        when "store_encrypted"
          config.password_storage_policy = PasswordStoragePolicy::STORE_ENCRYPTED
        when "never_store"
          config.password_storage_policy = PasswordStoragePolicy::NEVER_STORE
        when "ask_before_store"
          config.password_storage_policy = PasswordStoragePolicy::ASK_BEFORE_STORE
        end
      end
      
      config
    end
    
    # JSONノードから設定を読み込む
    def self.from_json_node(node)
      config = new
      
      config.profile_directory = node["profile_directory"].as_s if node["profile_directory"]?
      config.enable_sync = node["enable_sync"].as_bool if node["enable_sync"]?
      config.sync_interval = node["sync_interval"].as_i if node["sync_interval"]?
      config.max_history_items = node["max_history_items"].as_i if node["max_history_items"]?
      config.clear_history_on_exit = node["clear_history_on_exit"].as_bool if node["clear_history_on_exit"]?
      
      if node["cookie_storage_policy"]?
        case node["cookie_storage_policy"].as_s
        when "allow_all"
          config.cookie_storage_policy = CookieStoragePolicy::ALLOW_ALL
        when "block_third_party"
          config.cookie_storage_policy = CookieStoragePolicy::BLOCK_THIRD_PARTY
        when "block_all"
          config.cookie_storage_policy = CookieStoragePolicy::BLOCK_ALL
        when "session_only"
          config.cookie_storage_policy = CookieStoragePolicy::SESSION_ONLY
        end
      end
      
      if node["password_storage_policy"]?
        case node["password_storage_policy"].as_s
        when "store_encrypted"
          config.password_storage_policy = PasswordStoragePolicy::STORE_ENCRYPTED
        when "never_store"
          config.password_storage_policy = PasswordStoragePolicy::NEVER_STORE
        when "ask_before_store"
          config.password_storage_policy = PasswordStoragePolicy::ASK_BEFORE_STORE
        end
      end
      
      config
    end
    
    # 設定をYAMLノードに変換
    def to_yaml(yaml : YAML::Builder)
      yaml.mapping do
        yaml.scalar "profile_directory"
        yaml.scalar @profile_directory
        
        yaml.scalar "enable_sync"
        yaml.scalar @enable_sync
        
        yaml.scalar "sync_interval"
        yaml.scalar @sync_interval
        
        yaml.scalar "max_history_items"
        yaml.scalar @max_history_items
        
        yaml.scalar "clear_history_on_exit"
        yaml.scalar @clear_history_on_exit
        
        yaml.scalar "cookie_storage_policy"
        yaml.scalar @cookie_storage_policy.to_s.downcase
        
        yaml.scalar "password_storage_policy"
        yaml.scalar @password_storage_policy.to_s.downcase
      end
    end
    
    # 設定をJSONビルダーに変換
    def to_json(json : JSON::Builder)
      json.object do
        json.field "profile_directory", @profile_directory
        json.field "enable_sync", @enable_sync
        json.field "sync_interval", @sync_interval
        json.field "max_history_items", @max_history_items
        json.field "clear_history_on_exit", @clear_history_on_exit
        json.field "cookie_storage_policy", @cookie_storage_policy.to_s.downcase
        json.field "password_storage_policy", @password_storage_policy.to_s.downcase
      end
    end
  end
  
  # コア設定
  class CoreConfig
    property rendering_mode : RenderingMode
    property javascript_enabled : Bool
    property webgl_enabled : Bool
    property webrtc_enabled : Bool
    property hardware_acceleration : Bool
    property worker_threads : Int32
    property memory_cache_size_mb : Int32
    property process_model : ProcessModel
    
    # 革新的な機能：量子最適化関連の設定
    property enable_quantum_acceleration : Bool     # 量子アルゴリズムによる最適化を有効化
    property parallel_task_factor : Float64         # 並列タスク処理の積極度係数
    property random_seed : Int64?                   # 量子エントロピーソースのシード値（nilの場合はシステム時刻）
    property adaptive_scheduling : Bool             # 適応型タスクスケジューリングの有効化
    property enable_task_prediction : Bool          # タスク予測機能の有効化
    property task_queue_size : Int32                # タスクキューの最大サイズ
    
    # メモリ管理関連の設定
    property gc_threshold_mb : Int32                # GCを自動トリガーするメモリ閾値（MB）
    property memory_limit_mb : Int32                # メモリ使用上限（MB）
    property auto_optimize_memory : Bool            # メモリ自動最適化の有効化
    property memory_check_interval_seconds : Int32  # メモリチェック間隔（秒）
    property memory_warning_threshold_mb : Int32    # メモリ警告閾値（MB）
    property memory_critical_threshold_mb : Int32   # メモリ危機閾値（MB）
    property adaptive_memory_management : Bool      # 適応型メモリ管理の有効化
    
    # 並列処理関連の設定
    property parallel_init : Bool                   # 初期化を並列実行するかどうか
    property max_parallel_downloads : Int32         # 最大並列ダウンロード数
    property io_threadpool_size : Int32             # I/O処理スレッドプールサイズ
    
    # ログ関連の設定
    property log_level : ::Log::Severity            # ログレベル
    
    # レンダリングモード
    enum RenderingMode
      NORMAL
      PERFORMANCE
      BATTERY_SAVING
    end
    
    # プロセスモデル
    enum ProcessModel
      SINGLE_PROCESS
      PROCESS_PER_SITE
      PROCESS_PER_SITE_INSTANCE
    end
    
    def initialize(
      @rendering_mode : RenderingMode = RenderingMode::NORMAL,
      @javascript_enabled : Bool = true,
      @webgl_enabled : Bool = true,
      @webrtc_enabled : Bool = true,
      @hardware_acceleration : Bool = true,
      @worker_threads : Int32 = 4,
      @memory_cache_size_mb : Int32 = 256,
      @process_model : ProcessModel = ProcessModel::PROCESS_PER_SITE,
      
      # 革新的機能の初期値
      @enable_quantum_acceleration : Bool = true,
      @parallel_task_factor : Float64 = 1.75,
      @random_seed : Int64? = nil,
      @adaptive_scheduling : Bool = true,
      @enable_task_prediction : Bool = true,
      @task_queue_size : Int32 = 2000,
      
      # メモリ管理
      @gc_threshold_mb : Int32 = 500,
      @memory_limit_mb : Int32 = 2048,
      @auto_optimize_memory : Bool = true,
      @memory_check_interval_seconds : Int32 = 30,
      @memory_warning_threshold_mb : Int32 = 1536,
      @memory_critical_threshold_mb : Int32 = 1920,
      @adaptive_memory_management : Bool = true,
      
      # 並列処理
      @parallel_init : Bool = true,
      @max_parallel_downloads : Int32 = 8,
      @io_threadpool_size : Int32 = 8,
      
      # ログ
      @log_level : ::Log::Severity = ::Log::Severity::Info
    )
    end
    
    # YAMLノードから設定を読み込む
    def self.from_yaml_node(node)
      config = new
      
      if node["rendering_mode"]?
        case node["rendering_mode"].as_s
        when "normal"
          config.rendering_mode = RenderingMode::NORMAL
        when "performance"
          config.rendering_mode = RenderingMode::PERFORMANCE
        when "battery_saving"
          config.rendering_mode = RenderingMode::BATTERY_SAVING
        end
      end
      
      config.javascript_enabled = node["javascript_enabled"].as_bool if node["javascript_enabled"]?
      config.webgl_enabled = node["webgl_enabled"].as_bool if node["webgl_enabled"]?
      config.webrtc_enabled = node["webrtc_enabled"].as_bool if node["webrtc_enabled"]?
      config.hardware_acceleration = node["hardware_acceleration"].as_bool if node["hardware_acceleration"]?
      config.worker_threads = node["worker_threads"].as_i if node["worker_threads"]?
      config.memory_cache_size_mb = node["memory_cache_size_mb"].as_i if node["memory_cache_size_mb"]?
      
      # 革新的機能の読み込み
      config.enable_quantum_acceleration = node["enable_quantum_acceleration"].as_bool if node["enable_quantum_acceleration"]?
      config.parallel_task_factor = node["parallel_task_factor"].as_f if node["parallel_task_factor"]?
      config.random_seed = node["random_seed"].as_i64 if node["random_seed"]?
      config.adaptive_scheduling = node["adaptive_scheduling"].as_bool if node["adaptive_scheduling"]?
      config.enable_task_prediction = node["enable_task_prediction"].as_bool if node["enable_task_prediction"]?
      config.task_queue_size = node["task_queue_size"].as_i if node["task_queue_size"]?
      
      # メモリ管理設定の読み込み
      config.gc_threshold_mb = node["gc_threshold_mb"].as_i if node["gc_threshold_mb"]?
      config.memory_limit_mb = node["memory_limit_mb"].as_i if node["memory_limit_mb"]?
      config.auto_optimize_memory = node["auto_optimize_memory"].as_bool if node["auto_optimize_memory"]?
      config.memory_check_interval_seconds = node["memory_check_interval_seconds"].as_i if node["memory_check_interval_seconds"]?
      config.memory_warning_threshold_mb = node["memory_warning_threshold_mb"].as_i if node["memory_warning_threshold_mb"]?
      config.memory_critical_threshold_mb = node["memory_critical_threshold_mb"].as_i if node["memory_critical_threshold_mb"]?
      config.adaptive_memory_management = node["adaptive_memory_management"].as_bool if node["adaptive_memory_management"]?
      
      # 並列処理設定の読み込み
      config.parallel_init = node["parallel_init"].as_bool if node["parallel_init"]?
      config.max_parallel_downloads = node["max_parallel_downloads"].as_i if node["max_parallel_downloads"]?
      config.io_threadpool_size = node["io_threadpool_size"].as_i if node["io_threadpool_size"]?
      
      # ログ設定の読み込み
      if node["log_level"]?
        case node["log_level"].as_s
        when "trace"
          config.log_level = ::Log::Severity::Trace
        when "debug"
          config.log_level = ::Log::Severity::Debug
        when "info"
          config.log_level = ::Log::Severity::Info
        when "notice"
          config.log_level = ::Log::Severity::Notice
        when "warn"
          config.log_level = ::Log::Severity::Warn
        when "error"
          config.log_level = ::Log::Severity::Error
        when "fatal"
          config.log_level = ::Log::Severity::Fatal
        end
      end
      
      if node["process_model"]?
        case node["process_model"].as_s
        when "single_process"
          config.process_model = ProcessModel::SINGLE_PROCESS
        when "process_per_site"
          config.process_model = ProcessModel::PROCESS_PER_SITE
        when "process_per_site_instance"
          config.process_model = ProcessModel::PROCESS_PER_SITE_INSTANCE
        end
      end
      
      config
    end
    
    # JSONノードから設定を読み込む
    def self.from_json_node(node)
      config = new
      
      if node["rendering_mode"]?
        case node["rendering_mode"].as_s
        when "normal"
          config.rendering_mode = RenderingMode::NORMAL
        when "performance"
          config.rendering_mode = RenderingMode::PERFORMANCE
        when "battery_saving"
          config.rendering_mode = RenderingMode::BATTERY_SAVING
        end
      end
      
      config.javascript_enabled = node["javascript_enabled"].as_bool if node["javascript_enabled"]?
      config.webgl_enabled = node["webgl_enabled"].as_bool if node["webgl_enabled"]?
      config.webrtc_enabled = node["webrtc_enabled"].as_bool if node["webrtc_enabled"]?
      config.hardware_acceleration = node["hardware_acceleration"].as_bool if node["hardware_acceleration"]?
      config.worker_threads = node["worker_threads"].as_i if node["worker_threads"]?
      config.memory_cache_size_mb = node["memory_cache_size_mb"].as_i if node["memory_cache_size_mb"]?
      
      # 革新的機能の読み込み
      config.enable_quantum_acceleration = node["enable_quantum_acceleration"].as_bool if node["enable_quantum_acceleration"]?
      config.parallel_task_factor = node["parallel_task_factor"].as_f if node["parallel_task_factor"]?
      config.random_seed = node["random_seed"].as_i64 if node["random_seed"]?
      config.adaptive_scheduling = node["adaptive_scheduling"].as_bool if node["adaptive_scheduling"]?
      config.enable_task_prediction = node["enable_task_prediction"].as_bool if node["enable_task_prediction"]?
      config.task_queue_size = node["task_queue_size"].as_i if node["task_queue_size"]?
      
      # メモリ管理設定の読み込み
      config.gc_threshold_mb = node["gc_threshold_mb"].as_i if node["gc_threshold_mb"]?
      config.memory_limit_mb = node["memory_limit_mb"].as_i if node["memory_limit_mb"]?
      config.auto_optimize_memory = node["auto_optimize_memory"].as_bool if node["auto_optimize_memory"]?
      config.memory_check_interval_seconds = node["memory_check_interval_seconds"].as_i if node["memory_check_interval_seconds"]?
      config.memory_warning_threshold_mb = node["memory_warning_threshold_mb"].as_i if node["memory_warning_threshold_mb"]?
      config.memory_critical_threshold_mb = node["memory_critical_threshold_mb"].as_i if node["memory_critical_threshold_mb"]?
      config.adaptive_memory_management = node["adaptive_memory_management"].as_bool if node["adaptive_memory_management"]?
      
      # 並列処理設定の読み込み
      config.parallel_init = node["parallel_init"].as_bool if node["parallel_init"]?
      config.max_parallel_downloads = node["max_parallel_downloads"].as_i if node["max_parallel_downloads"]?
      config.io_threadpool_size = node["io_threadpool_size"].as_i if node["io_threadpool_size"]?
      
      # ログ設定の読み込み
      if node["log_level"]?
        case node["log_level"].as_s
        when "trace"
          config.log_level = ::Log::Severity::Trace
        when "debug"
          config.log_level = ::Log::Severity::Debug
        when "info"
          config.log_level = ::Log::Severity::Info
        when "notice"
          config.log_level = ::Log::Severity::Notice
        when "warn"
          config.log_level = ::Log::Severity::Warn
        when "error"
          config.log_level = ::Log::Severity::Error
        when "fatal"
          config.log_level = ::Log::Severity::Fatal
        end
      end
      
      if node["process_model"]?
        case node["process_model"].as_s
        when "single_process"
          config.process_model = ProcessModel::SINGLE_PROCESS
        when "process_per_site"
          config.process_model = ProcessModel::PROCESS_PER_SITE
        when "process_per_site_instance"
          config.process_model = ProcessModel::PROCESS_PER_SITE_INSTANCE
        end
      end
      
      config
    end
    
    # 設定をYAMLノードに変換
    def to_yaml(yaml : YAML::Builder)
      yaml.mapping do
        yaml.scalar "rendering_mode"
        yaml.scalar @rendering_mode.to_s.downcase
        
        yaml.scalar "javascript_enabled"
        yaml.scalar @javascript_enabled
        
        yaml.scalar "webgl_enabled"
        yaml.scalar @webgl_enabled
        
        yaml.scalar "webrtc_enabled"
        yaml.scalar @webrtc_enabled
        
        yaml.scalar "hardware_acceleration"
        yaml.scalar @hardware_acceleration
        
        yaml.scalar "worker_threads"
        yaml.scalar @worker_threads
        
        yaml.scalar "memory_cache_size_mb"
        yaml.scalar @memory_cache_size_mb
        
        yaml.scalar "process_model"
        yaml.scalar @process_model.to_s.downcase
        
        # 革新的機能の出力
        yaml.scalar "enable_quantum_acceleration"
        yaml.scalar @enable_quantum_acceleration
        
        yaml.scalar "parallel_task_factor"
        yaml.scalar @parallel_task_factor
        
        if @random_seed
          yaml.scalar "random_seed"
          yaml.scalar @random_seed
        end
        
        yaml.scalar "adaptive_scheduling"
        yaml.scalar @adaptive_scheduling
        
        yaml.scalar "enable_task_prediction"
        yaml.scalar @enable_task_prediction
        
        yaml.scalar "task_queue_size"
        yaml.scalar @task_queue_size
        
        # メモリ管理設定の出力
        yaml.scalar "gc_threshold_mb"
        yaml.scalar @gc_threshold_mb
        
        yaml.scalar "memory_limit_mb"
        yaml.scalar @memory_limit_mb
        
        yaml.scalar "auto_optimize_memory"
        yaml.scalar @auto_optimize_memory
        
        yaml.scalar "memory_check_interval_seconds"
        yaml.scalar @memory_check_interval_seconds
        
        yaml.scalar "memory_warning_threshold_mb"
        yaml.scalar @memory_warning_threshold_mb
        
        yaml.scalar "memory_critical_threshold_mb"
        yaml.scalar @memory_critical_threshold_mb
        
        yaml.scalar "adaptive_memory_management"
        yaml.scalar @adaptive_memory_management
        
        # 並列処理設定の出力
        yaml.scalar "parallel_init"
        yaml.scalar @parallel_init
        
        yaml.scalar "max_parallel_downloads"
        yaml.scalar @max_parallel_downloads
        
        yaml.scalar "io_threadpool_size"
        yaml.scalar @io_threadpool_size
        
        # ログ設定の出力
        yaml.scalar "log_level"
        case @log_level
        when ::Log::Severity::Trace
          yaml.scalar "trace"
        when ::Log::Severity::Debug
          yaml.scalar "debug"
        when ::Log::Severity::Info
          yaml.scalar "info"
        when ::Log::Severity::Notice
          yaml.scalar "notice"
        when ::Log::Severity::Warn
          yaml.scalar "warn"
        when ::Log::Severity::Error
          yaml.scalar "error"
        when ::Log::Severity::Fatal
          yaml.scalar "fatal"
        end
      end
    end
    
    # 設定をJSONビルダーに変換
    def to_json(json : JSON::Builder)
      json.object do
        json.field "rendering_mode", @rendering_mode.to_s.downcase
        json.field "javascript_enabled", @javascript_enabled
        json.field "webgl_enabled", @webgl_enabled
        json.field "webrtc_enabled", @webrtc_enabled
        json.field "hardware_acceleration", @hardware_acceleration
        json.field "worker_threads", @worker_threads
        json.field "memory_cache_size_mb", @memory_cache_size_mb
        json.field "process_model", @process_model.to_s.downcase
        
        # 革新的機能の出力
        json.field "enable_quantum_acceleration", @enable_quantum_acceleration
        json.field "parallel_task_factor", @parallel_task_factor
        json.field "random_seed", @random_seed if @random_seed
        json.field "adaptive_scheduling", @adaptive_scheduling
        json.field "enable_task_prediction", @enable_task_prediction
        json.field "task_queue_size", @task_queue_size
        
        # メモリ管理設定の出力
        json.field "gc_threshold_mb", @gc_threshold_mb
        json.field "memory_limit_mb", @memory_limit_mb
        json.field "auto_optimize_memory", @auto_optimize_memory
        json.field "memory_check_interval_seconds", @memory_check_interval_seconds
        json.field "memory_warning_threshold_mb", @memory_warning_threshold_mb
        json.field "memory_critical_threshold_mb", @memory_critical_threshold_mb
        json.field "adaptive_memory_management", @adaptive_memory_management
        
        # 並列処理設定の出力
        json.field "parallel_init", @parallel_init
        json.field "max_parallel_downloads", @max_parallel_downloads
        json.field "io_threadpool_size", @io_threadpool_size
        
        # ログ設定の出力
        json.field "log_level", case @log_level
          when ::Log::Severity::Trace then "trace"
          when ::Log::Severity::Debug then "debug"
          when ::Log::Severity::Info then "info"
          when ::Log::Severity::Notice then "notice"
          when ::Log::Severity::Warn then "warn"
          when ::Log::Severity::Error then "error"
          when ::Log::Severity::Fatal then "fatal"
          else "info"
        end
      end
    end
  end
end 