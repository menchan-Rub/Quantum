require "yaml"
require "json"

module QuantumCore
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
    
    def initialize(
      @max_connections : Int32 = 10,
      @timeout : Int32 = 30,
      @retries : Int32 = 3,
      @proxy_enabled : Bool = false,
      @proxy_url : String? = nil,
      @user_agent_override : String? = nil,
      @dns_prefetch : Bool = true,
      @http_cache_size_mb : Int32 = 100
    )
    end
    
    # YAMLノードから設定を読み込む
    def self.from_yaml_node(node)
      config = new
      
      config.max_connections = node["max_connections"].as_i if node["max_connections"]?
      config.timeout = node["timeout"].as_i if node["timeout"]?
      config.retries = node["retries"].as_i if node["retries"]?
      config.proxy_enabled = node["proxy_enabled"].as_bool if node["proxy_enabled"]?
      config.proxy_url = node["proxy_url"].as_s if node["proxy_url"]?
      config.user_agent_override = node["user_agent_override"].as_s if node["user_agent_override"]?
      config.dns_prefetch = node["dns_prefetch"].as_bool if node["dns_prefetch"]?
      config.http_cache_size_mb = node["http_cache_size_mb"].as_i if node["http_cache_size_mb"]?
      
      config
    end
    
    # JSONノードから設定を読み込む
    def self.from_json_node(node)
      config = new
      
      config.max_connections = node["max_connections"].as_i if node["max_connections"]?
      config.timeout = node["timeout"].as_i if node["timeout"]?
      config.retries = node["retries"].as_i if node["retries"]?
      config.proxy_enabled = node["proxy_enabled"].as_bool if node["proxy_enabled"]?
      config.proxy_url = node["proxy_url"].as_s if node["proxy_url"]?
      config.user_agent_override = node["user_agent_override"].as_s if node["user_agent_override"]?
      config.dns_prefetch = node["dns_prefetch"].as_bool if node["dns_prefetch"]?
      config.http_cache_size_mb = node["http_cache_size_mb"].as_i if node["http_cache_size_mb"]?
      
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
        json.field "user_agent_override", @user_agent_override if @user_agent_override
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
      @process_model : ProcessModel = ProcessModel::PROCESS_PER_SITE
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
      end
    end
  end
end 