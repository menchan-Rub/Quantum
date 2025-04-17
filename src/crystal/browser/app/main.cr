require "../config/config"
require "../session/session_manager"
require "../commands/command_registry"
require "../../ui/components/window_manager"
require "../../events/dispatcher/event_dispatcher"
require "../../storage/preferences/user_preferences"
require "../../platform/platform_detector"
require "../../bindings/nim/network_binding"
require "../../bindings/zig/engine_binding"
require "../../extensions/manager/extension_manager"
require "../../storage/history/history_manager"
require "../../storage/bookmarks/bookmark_manager"
require "log"

# メインアプリケーションの起動ポイント
module Browser
  VERSION = "0.1.0"
  
  # ブラウザのグローバル状態を管理するクラス
  class Application
    getter config : Config
    getter session_manager : SessionManager
    getter command_registry : CommandRegistry
    getter window_manager : UI::Components::WindowManager
    getter event_dispatcher : Events::EventDispatcher
    getter extension_manager : Extensions::ExtensionManager
    getter history_manager : Storage::HistoryManager
    getter bookmark_manager : Storage::BookmarkManager
    
    def initialize
      Log.info { "ブラウザアプリケーションの初期化を開始" }
      
      # プラットフォーム検出
      platform = Platform::PlatformDetector.detect
      Log.info { "検出されたプラットフォーム: #{platform.name} #{platform.version}" }
      
      # 設定の読み込み
      @config = Config.new
      @config.load_defaults
      @config.load_user_preferences
      
      # 各マネージャの初期化
      @session_manager = SessionManager.new(@config)
      @command_registry = CommandRegistry.new
      @event_dispatcher = Events::EventDispatcher.new
      @window_manager = UI::Components::WindowManager.new(@event_dispatcher)
      @extension_manager = Extensions::ExtensionManager.new(@config, @event_dispatcher)
      @history_manager = Storage::HistoryManager.new(@config)
      @bookmark_manager = Storage::BookmarkManager.new(@config)
      
      # バインディングの初期化
      initialize_bindings
      
      # コマンドの登録
      register_commands
      
      # イベントハンドラの登録
      register_event_handlers
      
      Log.info { "ブラウザアプリケーションの初期化が完了" }
    end
    
    private def initialize_bindings
      # Nimネットワークスタックの初期化
      Bindings::Nim::NetworkBinding.initialize(@config)
      
      # Zigレンダリングエンジンの初期化
      Bindings::Zig::EngineBinding.initialize(@config)
    end
    
    private def register_commands
      # 基本的なブラウザコマンドを登録
      @command_registry.register("new_tab", Commands::NewTabCommand.new(@window_manager))
      @command_registry.register("close_tab", Commands::CloseTabCommand.new(@window_manager))
      @command_registry.register("navigate", Commands::NavigateCommand.new(@window_manager))
      @command_registry.register("back", Commands::BackCommand.new(@window_manager))
      @command_registry.register("forward", Commands::ForwardCommand.new(@window_manager))
      @command_registry.register("reload", Commands::ReloadCommand.new(@window_manager))
      @command_registry.register("stop", Commands::StopCommand.new(@window_manager))
      @command_registry.register("bookmark", Commands::BookmarkCommand.new(@bookmark_manager))
    end
    
    private def register_event_handlers
      # イベントハンドラを登録
      @event_dispatcher.register(Events::Types::NetworkEvent, Events::Handlers::NetworkEventHandler.new)
      @event_dispatcher.register(Events::Types::RenderEvent, Events::Handlers::RenderEventHandler.new)
      @event_dispatcher.register(Events::Types::UserEvent, Events::Handlers::UserEventHandler.new)
      @event_dispatcher.register(Events::Types::ExtensionEvent, Events::Handlers::ExtensionEventHandler.new)
    end
    
    # アプリケーションの起動
    def run
      Log.info { "ブラウザアプリケーションを起動中..." }
      
      # 拡張機能の読み込み
      @extension_manager.load_extensions
      
      # 前回のセッションを復元
      @session_manager.restore_last_session
      
      # メインウィンドウの表示
      main_window = @window_manager.create_main_window
      main_window.show
      
      # スタートページを開く（設定に基づく）
      start_url = @config.get_string("browser.startup.homepage", "about:welcome")
      main_window.active_tab.navigate(start_url)
      
      Log.info { "ブラウザの起動が完了しました" }
      
      # イベントループ
      run_event_loop
    end
    
    private def run_event_loop
      Log.debug { "イベントループを開始" }
      
      loop do
        # イベントの処理
        @event_dispatcher.process_events
        
        # UIの更新
        @window_manager.update
        
        # 拡張機能の更新
        @extension_manager.update
        
        # セッション状態の自動保存
        @session_manager.auto_save if @session_manager.needs_save?
        
        # テスト環境での早期終了
        break if ENV["TESTING"]? == "true"
        
        # CPUリソースの節約
        sleep(0.01)
      end
      
      # 終了処理
      shutdown
    end
    
    # アプリケーションの終了処理
    def shutdown
      Log.info { "ブラウザを終了中..." }
      
      # セッションの保存
      @session_manager.save_current_session
      
      # 各マネージャの終了処理
      @extension_manager.shutdown
      @window_manager.shutdown
      
      # バインディングの終了処理
      Bindings::Zig::EngineBinding.shutdown
      Bindings::Nim::NetworkBinding.shutdown
      
      Log.info { "ブラウザの終了処理が完了しました" }
    end
  end

  # アプリケーションのエントリポイント
  def self.start
    # ロギングの初期化
    Log.setup do |c|
      c.bind("browser.*", :info, Log::IOBackend.new)
      c.bind("browser.debug.*", :debug, Log::IOBackend.new) if ENV["DEBUG"]? == "true"
    end
    
    Log.info { "次世代ブラウザ v#{VERSION} を起動中..." }
    
    # 例外ハンドリング
    begin
      app = Application.new
      app.run
    rescue ex
      Log.error(exception: ex) { "ブラウザの実行中に致命的なエラーが発生しました" }
      
      # クラッシュレポートの生成
      if ENV["TESTING"]? != "true"
        crash_reporter = Util::CrashReporter.new
        crash_reporter.generate_report(ex)
        crash_reporter.show_error_dialog("ブラウザがクラッシュしました", ex.message || "不明なエラー")
      end
      
      exit(1)
    end
  end
end

# アプリケーションの起動（直接実行された場合）
Browser.start unless ENV["TESTING"]? == "true"