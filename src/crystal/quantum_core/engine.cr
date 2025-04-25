require "./config"
# require "./nim_bridge" # 削除済み
require "./storage/manager"
require "./page_manager"
require "./page"
require "./security_context"
require "./resource_scheduler"
# require "./performance_monitor" # オプション、今はコメントアウトのまま
# require "./rendering/engine" # Zigコンポーネントのプレースホルダ
# require "./javascript/engine" # Zigコンポーネントのプレースホルダ
# require "./dom/manager" # Zigコンポーネントのプレースホルダ
require "../events/**"
require "../utils/logger"
# require "deque" # ここでは直接使用しない
require "mutex"
# require "json" # ここでは直接使用しない
require "log"
require "fiber" # バックグラウンドタスク生成用
require "file_utils" # 設定再読み込みの可能性のため
require "atomic" # アトミックフラグ用

module QuantumCore
  # ==============================================================================
  #                              Engine クラス
  # ==============================================================================
  # QuantumCore::Engine: ブラウザのコアサブシステムを統括し、ライフサイクルを管理するクラス。
  # UI、ネットワーク、ストレージ、パフォーマンスモニターなどを初期化、起動、停止します。
  class Engine
    # Crystal組み込みのLogモジュールを使用。クラス/インスタンスごとに設定可能。
    Log = ::Log.for(self)

    # ------------------------------------------------------------------
    #                           エンジンの状態
    # ------------------------------------------------------------------
    # コアエンジンの取りうる動作状態を表します。
    enum State
      # 初期化が始まる前の初期状態。
      Stopped
      # エンジンが現在初期化シーケンスを実行中。
      Initializing
      # エンジンが正常に初期化され、動作可能。
      Running
      # エンジンがシャットダウンシーケンスを実行中。
      ShuttingDown
      # エンジン起動が致命的に失敗した。
      Failed
    end

    # ------------------------------------------------------------------
    #                           コアコンポーネント
    # ------------------------------------------------------------------
    # これらはEngineによって調整される主要なマネージャーとサービスです。
    # Engineはこれらのコンポーネントのライフサイクル（初期化、シャットダウン）を管理します。

    # ブラウザの設定情報へのアクセスを提供します。
    getter config : Config
    # 永続ストレージ（履歴、Cookie、設定など）を管理します。
    getter storage_manager : Storage::Manager
    # ブラウザページ（タブ）のライフサイクルとコレクションを管理します。
    getter page_manager : PageManager
    # ネットワークリクエストのスケジューリングと実行を処理します。
    getter resource_scheduler : ResourceScheduler
    # ブラウザ全体でイベントをディスパッチおよび購読するための中心的なハブです。
    getter event_dispatcher : QuantumEvents::EventDispatcher

    # --- プレースホルダコンポーネント (将来の実装) ---
    # これらのコンポーネントは計画中または概念的なもので、外部（例: Zig）で
    # 実装されるか、開発サイクルの後半で実装される可能性があります。
    # Engineはこれらのコンポーネントへの参照を保持し、必要に応じて調整します。

    # レンダリングエンジンへのインターフェース (おそらくFFI/IPC経由でZig)。
    # getter rendering_engine : Rendering::Engine # プレースホルダ
    # JavaScript実行エンジンへのインターフェース (おそらくFFI/IPC経由でZig)。
    # getter javascript_engine : JavaScript::Engine # プレースホルダ
    # Document Object Model (DOM) を管理します (おそらくFFI/IPC経由でZig)。
    # getter dom_manager : DOM::Manager # プレースホルダ
    # パフォーマンスメトリクスを追跡し報告します。
    # getter performance_monitor : PerformanceMonitor # プレースホルダ
    # ファイルダウンロードを管理します。
    # getter download_manager : DownloadManager # プレースホルダ
    # ウェブサイトの権限（位置情報、通知など）を管理します。
    # getter permission_manager : PermissionManager # プレースホルダ
    # ブラウザ拡張機能を管理します。
    # getter extension_manager : ExtensionManager # プレースホルダ
    # レンダラープロセスやユーティリティプロセスを管理します (マルチプロセスアーキテクチャ用)。
    # getter process_manager : ProcessManager # プレースホルダ

    # ------------------------------------------------------------------
    #                         公開ヘルパーゲッター
    # ------------------------------------------------------------------
    # エンジンの外部からアクセス可能な便利な情報を提供します。

    # 現在アクティブなページへの便利なゲッター。
    getter current_page : Page? { @page_manager.current_page }
    # エンジンの現在の動作状態を返します。
    getter state : State { @state.get }
    # エンジンが完全に初期化され、動作可能であるかを示します。
    def running? : Bool
      @state.get == State::Running
    end

    # ------------------------------------------------------------------
    #                           内部状態
    # ------------------------------------------------------------------
    # エンジンの内部状態を管理するための変数群です。

    # エンジン状態と操作へのスレッドセーフなアクセスを保証するためのMutex。
    @mutex : Mutex
    # Engine専用のロガーインスタンス。
    @logger : ::Log::Context
    # エンジンの現在の動作状態を保持します。Atomicでスレッドセーフにアクセス可能。
    @state : Atomic(State)
    # シャットダウンシーケンスが要求されたかを示すフラグ。Atomic::Flagでスレッドセーフ。
    @shutdown_requested : Atomic::Flag
    # エンジンが起動した時刻 (診断用)。
    @start_time : Time? = nil

    # ==============================================================================
    #                             初期化
    # ==============================================================================
    # コアブラウザエンジンとその必須コンポーネントを初期化します。
    # このメソッドは、Engineインスタンスが作成される際に一度だけ呼び出されます。
    #
    # 初期化の順序:
    # 1. 基本的な状態変数 (mutex, logger, state flags)。
    # 2. EventDispatcher (後続のコンポーネントがディスパッチ/購読できるように最初に必要)。
    # 3. StorageManager (セッション復元/設定のために早期に必要)。
    # 4. ResourceScheduler (EventDispatcher, Configに依存)。
    # 5. PageManager (EventDispatcher, ResourceSchedulerに依存)。
    # 6. プレースホルダコンポーネント (レンダリング, JS, DOMなど - 遅延または概念的)。
    # 7. 内部イベントリスナーの設定。
    #
    # 注: 実際の起動 (外部コンポーネントの初期化を含む) は `start` メソッドで処理されます。
    #
    # @param config [QuantumCore::Config] 全体設定オブジェクト
    # @raise [QuantumCore::InitializationError] 初期化に失敗した場合
    def initialize(@config : QuantumCore::Config)
      # まず基本的な状態を初期化します。
      @mutex = Mutex.new
      @state = Atomic.new(State::Stopped) # 初期状態はStopped
      @shutdown_requested = Atomic::Flag.new
      @logger = Log.for("Engine")
      configure_logging(@config.core.log_level)
      # QuantumBrowser::VERSIONが定義されていれば、より詳細なバージョン文字列を使用します。
      version_string = defined?(QuantumBrowser::VERSION) ? QuantumBrowser::VERSION : "開発版"
      @logger.info { "QuantumCore::Engine を初期化中 (バージョン: #{version_string})..." }

      # --- コアマネージャーの初期化 --- #
      begin
        # 1. イベントディスパッチャを初期化します。
        @logger.debug { "EventDispatcher を初期化中..." }
        @event_dispatcher = QuantumEvents::EventDispatcher.instance
        @event_dispatcher.start # ディスパッチャのスレッド/ループを開始します。
        @logger.info { "EventDispatcher が開始されました。" }

        # 2. ストレージマネージャーを初期化します。
        @logger.debug { "StorageManager を初期化中 (プロファイル: '#{@config.storage.profile_directory}')..." }
        @storage_manager = Storage::Manager.new(@config.storage.profile_directory, @event_dispatcher)
        # ストレージのセットアップを即座に試みます。これはDBの準備ができるか失敗するまでブロックします。
        unless @storage_manager.setup_storage
          # これが致命的かどうかを判断します。今のところ、エラーをログに記録して続行します。
          # アプリケーションは履歴やCookieなどなしで実行される可能性があります。
          @logger.error { "Storage Manager のデータベースセットアップに失敗しました！永続化機能は利用できません。" }
          # 必要に応じてグローバルエラーイベントをディスパッチすることも検討できます。
          @event_dispatcher.dispatch(QuantumEvents::Event.new(QuantumEvents::EventType::GLOBAL_ERROR, 
            QuantumEvents::ErrorData.new("ストレージの初期化に失敗しました", severity: :high)))
        else
           @logger.info { "StorageManager が初期化され、データベースが正常に開かれました。" }
           # 成功したことがわかったので、STORAGE_READY イベントをディスパッチします。
           @event_dispatcher.dispatch(QuantumEvents::Event.new(QuantumEvents::EventType::STORAGE_READY))
        end

        # 3. リソーススケジューラを初期化します。
        @logger.debug { "ResourceScheduler を初期化中..." }
        max_concurrent = @config.network.max_connections
        timeout_settings = NetworkTimeoutSettings.new(
          connect_timeout: @config.network.connect_timeout,
          read_timeout: @config.network.read_timeout,
          write_timeout: @config.network.write_timeout
        )
        proxy_config = @config.network.proxy_enabled ? 
          ProxyConfiguration.new(
            type: @config.network.proxy_type,
            host: @config.network.proxy_host,
            port: @config.network.proxy_port,
            username: @config.network.proxy_username,
            password: @config.network.proxy_password
          ) : nil
        @resource_scheduler = ResourceScheduler.new(
          @event_dispatcher, 
          max_concurrent, 
          timeout_settings: timeout_settings,
          proxy_config: proxy_config
        )
        @logger.info { "ResourceScheduler が初期化されました (最大同時接続数: #{max_concurrent})。" }

        # 4. ページマネージャーを初期化します。
        @logger.debug { "PageManager を初期化中..." }
        @page_manager = PageManager.new(@event_dispatcher, @resource_scheduler)
        @logger.info { "PageManager が初期化されました。" }

        # 5. パフォーマンスモニターを初期化します
        @logger.debug { "PerformanceMonitor を初期化中..." }
        @performance_monitor = PerformanceMonitor.new(self, @event_dispatcher)
        @performance_monitor.start_monitoring
        @logger.info { "PerformanceMonitor が初期化されました。" }

        # 6. ダウンロードマネージャーを初期化します
        @logger.debug { "DownloadManager を初期化中..." }
        @download_manager = DownloadManager.new(
          self, 
          @event_dispatcher, 
          @resource_scheduler, 
          @storage_manager, 
          @config.downloads.default_directory
        )
        @logger.info { "DownloadManager が初期化されました。" }

        # 7. 権限マネージャーを初期化します
        @logger.debug { "PermissionManager を初期化中..." }
        @permission_manager = PermissionManager.new(
          self, 
          @event_dispatcher, 
          @storage_manager
        )
        @logger.info { "PermissionManager が初期化されました。" }

        # 8. 拡張機能マネージャーを初期化します
        @logger.debug { "ExtensionManager を初期化中..." }
        @extension_manager = ExtensionManager.new(
          self, 
          @event_dispatcher, 
          @config.extensions.directory
        )
        @logger.info { "ExtensionManager が初期化されました。" }

        # 9. プロセスマネージャーを初期化します（マルチプロセスモード用）
        @logger.debug { "ProcessManager を初期化中..." }
        @process_manager = ProcessManager.new(
          self, 
          @event_dispatcher, 
          @config.process.max_processes
        )
        @logger.info { "ProcessManager が初期化されました。" }

        # 10. 外部コンポーネントへのインターフェースを初期化します
        @logger.debug { "外部コンポーネントインターフェースを初期化中..." }
        @rendering_engine = Rendering::Engine.new(
          self, 
          @config.rendering.hardware_acceleration,
          @config.rendering.vsync_enabled
        )
        @javascript_engine = JavaScript::Engine.new(
          self,
          @config.javascript.jit_enabled,
          @config.javascript.memory_limit
        )
        @dom_manager = DOM::Manager.new(
          self,
          @javascript_engine,
          @rendering_engine
        )
        @logger.info { "外部コンポーネントインターフェースが初期化されました。" }

        # 11. 内部イベントリスナーを設定します。
        # エンジンを管理対象コンポーネントやUIからのイベントに接続します。
        setup_internal_event_listeners

        @logger.info { "QuantumCore::Engine のコアコンポーネントが正常に初期化されました。" }
        # 注: エンジンの状態は `start` が呼び出されるまで Stopped のままです。

      rescue ex : Exception
        # コアマネージャーの初期化フェーズ中に予期せぬエラーを捕捉します。
        # これはエンジンにとって致命的なエラーと見なされます。
        @logger.fatal(exception: ex) { "コアコンポーネントの初期化中に壊滅的な失敗が発生しました。エンジンは続行できません。" }
        # 部分的に初期化された可能性のあるものをクリーンアップしようと試みます。
        graceful_shutdown_attempt_on_init_failure
        # 状態を Failed に設定します。
        @state.set(State::Failed)
        # 特定のエンジンエラーとして再発生させます。
        raise EngineInitializationError.new("コアコンポーネントの初期化に失敗しました", cause: ex)
      end
    end

    # 設定に基づいてロギングを設定するヘルパーメソッドです。
    # これは、異なるログ形式、出力などを処理するように拡張できます。
    private def configure_logging(log_level_str : String)
      begin
        level = ::Log::Severity.parse(log_level_str)
        @logger.level = level
        
        # グローバルログレベルを設定
        Log.level = level
        
        # ログファイルへの出力を設定
        if @config.core.log_to_file
          log_file = File.open(@config.core.log_file_path || "browser.log", "a")
          Log.backend = Log::IOBackend.new(log_file)
        end
        
        @logger.info { "エンジンのログレベルを #{level} に設定しました。" }
      rescue ex
        @logger.level = ::Log::Severity::Info # 解析エラー時のデフォルトレベル
        @logger.warn(exception: ex) { "設定からのログレベル '#{log_level_str}' の解析に失敗しました。INFO にデフォルト設定します。" }
      end
    end

    # プレースホルダマネージャーを初期化するヘルパーメソッドです。
    # これにより、メインのinitializeメソッドがよりクリーンになり、将来の実装に備えることができます。
    private def initialize_placeholder_managers
      @logger.debug { "追加のマネージャーを初期化中..." }
      
      # キャッシュマネージャーの初期化
      @cache_manager = CacheManager.new(
        @config.cache.max_size_mb,
        @config.cache.directory,
        @event_dispatcher
      )
      
      # セキュリティマネージャーの初期化
      @security_manager = SecurityManager.new(
        @event_dispatcher,
        @storage_manager,
        @config.security.certificate_store_path
      )
      
      # ブックマークマネージャーの初期化
      @bookmark_manager = BookmarkManager.new(
        @storage_manager,
        @event_dispatcher
      )
      
      # 履歴マネージャーの初期化
      @history_manager = HistoryManager.new(
        @storage_manager,
        @event_dispatcher,
        @config.privacy.history_retention_days
      )
      
      # 自動入力マネージャーの初期化
      @autofill_manager = AutofillManager.new(
        @storage_manager,
        @event_dispatcher,
        @security_manager
      )
      
      @logger.debug { "追加のマネージャーの初期化が完了しました。" }
    end

    # 初期化が途中で失敗した場合にリソースをクリーンアップしようと試みます。
    # `initialize` の rescue ブロックからのみ呼び出されます。
    private def graceful_shutdown_attempt_on_init_failure
        @logger.warn { "初期化失敗後に正常なシャットダウンを試みています..." }
        # 初期化された可能性のあるコンポーネントを、可能であれば逆順で閉じます。
        
        # プロセスマネージャーのクリーンアップ
        @process_manager.try &.terminate_all_processes
        
        # 拡張機能マネージャーのクリーンアップ
        @extension_manager.try &.unload_all_extensions
        
        # 外部エンジンのクリーンアップ
        @javascript_engine.try &.shutdown
        @rendering_engine.try &.shutdown
        @dom_manager.try &.shutdown
        
        # パフォーマンスモニターの停止
        @performance_monitor.try &.stop_monitoring
        
        # ダウンロードマネージャーのクリーンアップ
        @download_manager.try &.cancel_all_downloads
        
        # ページマネージャーのクリーンアップ
        @page_manager.try &.cleanup
        
        # リソーススケジューラーのクリーンアップ
        @resource_scheduler.try &.shutdown
        
        # ストレージマネージャーのクリーンアップ
        @storage_manager.try &.close
        
        # イベントディスパッチャーの停止
        @event_dispatcher.try &.stop
        
        @logger.warn { "初期化失敗後の部分的なクリーンアップを試みました。エンジンの状態は Failed に設定されました。" }
    end


    # ==============================================================================
    #                           エンジン起動シーケンス
    # ==============================================================================
    # エンジンを完全に動作可能にするための最終ステップを実行します。これには
    # 外部コンポーネント (Zigなど) の初期化が含まれます。このメソッドは冪等です。
    # 状態遷移: Stopped -> Initializing -> Running (成功時) または Failed。
    #
    # @raise [EngineStartupError] 致命的なステップが失敗した場合。
    # @return [Nil] 成功時または既に実行中の場合は nil を返します。
    def start : Nil
      # 既に実行中の場合は、Mutexなしで高速チェックを行います。
      return if @state.get == State::Running

      # 起動シーケンスの原子性を保証するために、主要な起動ロジックにMutexを使用します。
      @mutex.synchronize do
        # 競合状態を処理するために、Mutex内で状態を再チェックします。
        current_state = @state.get
        if current_state == State::Running
          @logger.warn { "エンジンの起動が要求されましたが、既に実行中です。" }
          return
        elsif current_state.in?(State::ShuttingDown, State::Failed)
           # これらの状態からは起動できません。
           @logger.error { "エンジンの起動が要求されましたが、無効な状態です: #{current_state}。起動できません。" }
           raise EngineStartupError.new("状態 #{current_state} からエンジンを起動できません")
        elsif current_state == State::Initializing
            # Initializing 中に再度呼び出された場合でも続行を許可します (Mutexがあるため可能性は低いですが)。
            @logger.warn { "Initializing 中にエンジンの起動が呼び出されました。続行します..."}
        else # current_state == State::Stopped
            # 状態を Initializing に設定します - 起動シーケンスが進行中であることを示します。
            @state.set(State::Initializing)
            @logger.info { "QuantumCore::Engine の動作シーケンスを開始します..." }
            @start_time = Time.monotonic # 起動時刻を記録します。
        end


        # --- 外部コンポーネント (Zigなど) の初期化 ---
        begin
          @logger.info { "外部コンポーネント (レンダリング, DOM, JS) の初期化を開始します..." }

          # --- レンダリングエンジンの初期化 ---
          begin
            component_name = "レンダリングエンジン"
            @logger.debug { "#{component_name} を初期化中..." }
            
            # レンダリングエンジンの初期化
            unless @rendering_engine.initialize_context(@config.rendering)
              raise ExternalComponentError.new("#{component_name} の初期化に失敗しました")
            end
            
            # レンダリングエンジンのパフォーマンス設定を適用
            @rendering_engine.set_vsync(@config.rendering.vsync_enabled)
            @rendering_engine.set_hardware_acceleration(@config.rendering.hardware_acceleration)
            @rendering_engine.set_animation_quality(@config.rendering.animation_quality)
            @rendering_engine.set_texture_compression(@config.rendering.texture_compression_enabled)
            
            @logger.info { "#{component_name} の初期化が完了しました。" }
          rescue ex : ExternalComponentError
            raise ex # 具体的なエラーとして再raiseします。
          rescue ex # その他の予期せぬエラーを捕捉します。
            raise ExternalComponentError.new("レンダリングエンジンの初期化中に予期せぬエラーが発生しました", cause: ex)
          end

          # --- DOMマネージャーの初期化 ---
          begin
            component_name = "DOMマネージャー"
            @logger.debug { "#{component_name} を初期化中..." }
            
            # DOMマネージャーの初期化
            unless @dom_manager.initialize_environment
              raise ExternalComponentError.new("#{component_name} の初期化に失敗しました")
            end
            
            # DOMイベントハンドラーの登録
            @dom_manager.register_event_handlers(@event_dispatcher)
            
            # DOMパーサーの設定
            @dom_manager.configure_parser(
              strict_mode: @config.dom.strict_parsing,
              error_recovery: @config.dom.error_recovery_enabled
            )
            
            @logger.info { "#{component_name} の初期化が完了しました。" }
          rescue ex : ExternalComponentError
            raise ex # 具体的なエラーとして再raiseします。
          rescue ex # その他の予期せぬエラーを捕捉します。
            raise ExternalComponentError.new("DOMマネージャーの初期化中に予期せぬエラーが発生しました", cause: ex)
          end

          # --- JavaScriptエンジンの初期化 ---
          begin
            component_name = "JavaScriptエンジン"
            @logger.debug { "#{component_name} を初期化中..." }
            
            # JavaScriptエンジンの初期化
            unless @javascript_engine.initialize_runtime(@config.javascript)
              raise ExternalComponentError.new("#{component_name} の初期化に失敗しました")
            end
            
            # JITコンパイラの設定
            if @config.javascript.jit_enabled
              @javascript_engine.configure_jit(
                optimization_level: @config.javascript.jit_optimization_level,
                threshold: @config.javascript.jit_threshold
              )
            end
            
            # メモリ制限の設定
            @javascript_engine.set_memory_limit(@config.javascript.memory_limit)
            
            # タイムアウト設定
            @javascript_engine.set_execution_timeout(@config.javascript.execution_timeout_ms)
            
            @logger.info { "#{component_name} の初期化が完了しました。" }
          rescue ex : ExternalComponentError
            raise ex # 具体的なエラーとして再raiseします。
          rescue ex # その他の予期せぬエラーを捕捉します。
            raise ExternalComponentError.new("JavaScriptエンジンの初期化中に予期せぬエラーが発生しました", cause: ex)
          end

          # --- 拡張機能の初期化 ---
          begin
            component_name = "拡張機能システム"
            @logger.debug { "#{component_name} を初期化中..." }
            
            # 拡張機能マネージャーの初期化
            @extension_manager.initialize_extension_environment(
              @javascript_engine,
              @dom_manager
            )
            
            # コア拡張機能のロード
            if @config.extensions.load_core_extensions
              @extension_manager.load_core_extensions
            end
            
            # ユーザー拡張機能のロード
            if @config.extensions.load_user_extensions
              @extension_manager.load_user_extensions
            end
            
            @logger.info { "#{component_name} の初期化が完了しました。" }
          rescue ex
            # 拡張機能の初期化エラーは致命的ではないため、ログに記録して続行
            @logger.error(exception: ex) { "拡張機能システムの初期化中にエラーが発生しましたが、続行します。" }
          end

          @logger.info { "すべての外部コンポーネントの初期化が正常に完了しました。" }

        rescue ex : ExternalComponentError # 外部コンポーネント固有のエラーを捕捉します。
          error_message = "外部コンポーネントの初期化に失敗しました: #{ex.message}。起動を中止します。"
          @logger.fatal { error_message }
          
          # 外部コンポーネントのクリーンアップを実行
          cleanup_after_startup_failure("外部コンポーネント", ex)
          
          @state.set(State::Failed) # エンジンを失敗状態に設定します。
          raise EngineStartupError.new(error_message, cause: ex)
        rescue ex # 外部初期化中のその他の予期せぬエラー (例: FFIリンクエラー) を捕捉します。
          error_message = "外部コンポーネントの初期化中に予期せぬエラーが発生しました。起動を中止します。"
          @logger.fatal(exception: ex) { error_message }
          @state.set(State::Failed) # エンジンを失敗状態に設定します。
          @shutdown_requested.clear # エラー時でもフラグをクリアして、再起動の試みを可能にするか、設定したままにするかは設計によります。ここではクリアします。
          raise EngineStartupError.new(error_message, cause: ex) # EngineStartupError でラップしてから raise します。
        end

        # --- 最終処理 ---
        # すべての必須な内部・外部コンポーネントが初期化され、実行中になりました。
        @state.set(State::Running) # 状態を Running に遷移させます。
        @shutdown_requested.clear # 正常起動時にはシャットダウンフラグをクリアします。
        @logger.info { "QuantumCore::Engine が正常に起動し、現在実行中です。" }

        # アプリケーションの他の部分 (例: UIレイヤー) に通知するためのイベントを発行します。
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
          QuantumEvents::EventType::CORE_ENGINE_START,
          QuantumEvents::EngineStartData.new(
            version: defined?(QuantumBrowser::VERSION) ? QuantumBrowser::VERSION : "開発版",
            startup_time_ms: (Time.monotonic - @start_time.not_nil!).total_milliseconds.to_i
          )
        ))
      end
    rescue ex : EngineStartupError
      # 同期ブロック内で明示的に発生した起動エラーを捕捉します。
      @logger.fatal { "エンジン起動に失敗しました: #{ex.message}" }
      # エラーハンドリング中にまだ設定されていなければ、状態が失敗を反映するようにします。
      @state.compare_and_swap(State::Initializing, State::Failed)
      raise ex # 上位レベルでのハンドリング (例: アプリケーション終了) のために再raiseします。
    rescue ex # 同期ブロック自体の実行中に予期せぬエラーが発生した場合を捕捉します。
      @logger.fatal(exception: ex) { "エンジン起動シーケンス中に予期せぬ致命的なエラーが発生しました。" }
      @state.set(State::Failed) # 状態が Failed であることを保証します。
      @shutdown_requested.clear # エラー時でもフラグをクリアして、再起動の試みを可能にするか、設定したままにするかは設計によります。ここではクリアします。
      # アプリケーションの設計によっては、再raise するか、単にログに記録するだけかもしれません。
      raise EngineStartupError.new("予期せぬエンジン起動失敗", cause: ex) # EngineStartupError でラップしてから raise します。
    end

    # 起動失敗後のクリーンアップを行います
    private def cleanup_after_startup_failure(component_type : String, error : Exception)
      @logger.warn { "#{component_type}の起動失敗後にクリーンアップを実行しています..." }
      
      # 初期化された外部コンポーネントをシャットダウン
      @javascript_engine.try &.shutdown
      @dom_manager.try &.shutdown
      @rendering_engine.try &.shutdown
      
      # 拡張機能のアンロード
      @extension_manager.try &.unload_all_extensions
      
      @logger.warn { "起動失敗後のクリーンアップが完了しました。" }
    end

    # ==============================================================================
    #                           エンジンシャットダウンシーケンス
    # ==============================================================================
    # エンジンとそのコンポーネントの正常なシャットダウンを開始します。
    # このメソッドは冪等 (複数回呼び出しても安全) であり、スレッドセーフです。
    # 状態遷移: Running/Initializing -> ShuttingDown -> Stopped (または Failed)。
    #
    # @param reason [String?] シャットダウン理由 (ログ用、任意)。
    def shutdown(reason : String? = nil)
      # まずシャットダウン要求フラグをアトミックに設定します。
      # test_and_set が true を返した場合、フラグは既に設定されており、
      # 別のシャットダウンシーケンスが進行中か、同時に要求された可能性があります。
      return unless @shutdown_requested.test_and_set

      @logger.info { "シャットダウンが要求されました。理由: #{reason || "指定なし"}。現在の状態: #{@state.get}" }

      # 主要なシャットダウンロジックの干渉を防ぐために mutex を使用します。
      @mutex.synchronize do
        current_state = @state.get
        # Running または Initializing (起動が途中で失敗した場合) 状態からのシャットダウンを許可します。
        # 既に Stopped または Failed の場合は、ログに記録し、アクションは不要なためフラグをクリアします。
        if current_state.in?(State::Stopped, State::Failed)
          @logger.warn { "シャットダウンが要求されましたが、エンジンは既に #{current_state} 状態です。アクションは実行されません。" }
          @shutdown_requested.clear # アクションが実行されないためフラグをクリアします。
          return
        elsif current_state == State::ShuttingDown
           @logger.warn { "シャットダウンが要求されましたが、既に進行中です。" }
           # フラグはクリアせず、元のシャットダウンが完了するのを待ちます。
           return
        end

        # 状態を ShuttingDown に設定します - クリーンアップが進行中であることを示します。
        @state.set(State::ShuttingDown)
        @logger.info { "QuantumCore::Engine シャットダウンシーケンスを開始します..." }

        # --- シャットダウンシーケンス ---
        # 初期化の逆順で依存関係を考慮しながらシャットダウンを実行します
        # エラーが発生してもできるだけ多くのコンポーネントをクリーンアップするため
        # シャットダウンシーケンスは継続します

        # 1. シャットダウンイベントを発行
        @logger.debug { "CORE_ENGINE_SHUTDOWN イベントを発行中..." }
        begin
           @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::CORE_ENGINE_SHUTDOWN,
            QuantumEvents::EngineShutdownData.new(
              reason: reason || "通常終了",
              uptime_seconds: @start_time ? (Time.monotonic - @start_time.not_nil!).total_seconds.to_i : 0
            )
           ))
        rescue ex
           @logger.error(exception: ex) { "シャットダウン中に CORE_ENGINE_SHUTDOWN イベントの発行でエラーが発生しました。" }
        end

        # 2. 新しい作業の受け入れを停止
        begin
          @logger.debug { "新しい作業の受け入れを停止中..." }
          @page_manager.stop_accepting_new_pages
          @resource_scheduler.pause_queueing
          @download_manager.pause_new_downloads
          @logger.debug { "新しい作業の受け入れを停止しました。" }
        rescue ex
          @logger.error(exception: ex) { "新しい作業の受け入れ停止中にエラーが発生しました。" }
        end

        # 3. 拡張機能のシャットダウン
        begin
          @logger.info { "拡張機能をアンロード中..." }
          @extension_manager.unload_all_extensions
          @logger.debug { "すべての拡張機能がアンロードされました。" }
        rescue ex
          @logger.error(exception: ex) { "拡張機能のアンロード中にエラーが発生しました。" }
        end

        # 4. 外部コンポーネント (Zigなど) のクリーンアップ
        @logger.info { "外部コンポーネントをシャットダウン中..." }
        begin
          # 依存関係の順序を考慮してシャットダウン
          if js_engine = @javascript_engine
            js_engine.shutdown
            @logger.debug { "JavaScriptエンジンのシャットダウンが完了しました。" }
          end
          
          if dom = @dom_manager
            dom.shutdown
            @logger.debug { "DOMマネージャーのシャットダウンが完了しました。" }
          end
          
          if renderer = @rendering_engine
            renderer.shutdown
            @logger.debug { "レンダリングエンジンのシャットダウンが完了しました。" }
          end
        rescue ex
          @logger.error(exception: ex) { "外部コンポーネントのシャットダウン中にエラーが発生しました。" }
        end

        # 5. 内部マネージャーのクリーンアップ
        @logger.info { "内部マネージャーをクリーンアップ中..." }

        # PageManager: すべてのページをクリーンアップし、ネットワークリクエストをキャンセル
        begin
          @logger.debug { "PageManagerとすべてのページをクリーンアップ中..." }
          @page_manager.cleanup
          @logger.debug { "PageManagerのクリーンアップが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "PageManagerのクリーンアップ中にエラーが発生しました。" }
        end

        # ResourceScheduler: バックグラウンドファイバーの終了処理
        begin
          @logger.debug { "ResourceSchedulerをシャットダウン中..." }
          @resource_scheduler.shutdown
          @logger.debug { "ResourceSchedulerのシャットダウンが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "ResourceSchedulerのシャットダウン中にエラーが発生しました。" }
        end

        # DownloadManager: 進行中のダウンロードを適切に終了
        begin
          @logger.debug { "DownloadManagerをシャットダウン中..." }
          @download_manager.shutdown
          @logger.debug { "DownloadManagerのシャットダウンが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "DownloadManagerのシャットダウン中にエラーが発生しました。" }
        end

        # PermissionManager: 権限キャッシュをフラッシュ
        begin
          @logger.debug { "PermissionManagerをシャットダウン中..." }
          @permission_manager.shutdown
          @logger.debug { "PermissionManagerのシャットダウンが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "PermissionManagerのシャットダウン中にエラーが発生しました。" }
        end

        # PerformanceMonitor: モニタリングスレッドを停止
        begin
          @logger.debug { "PerformanceMonitorをシャットダウン中..." }
          @performance_monitor.shutdown
          @logger.debug { "PerformanceMonitorのシャットダウンが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "PerformanceMonitorのシャットダウン中にエラーが発生しました。" }
        end

        # ProcessManager: 子プロセスを適切に終了
        begin
          @logger.debug { "ProcessManagerをシャットダウン中..." }
          @process_manager.shutdown
          @logger.debug { "ProcessManagerのシャットダウンが完了しました。" }
        rescue ex
          @logger.error(exception: ex) { "ProcessManagerのシャットダウン中にエラーが発生しました。" }
        end

        # StorageManager: データベース接続を閉じる
        begin
          @logger.debug { "StorageManagerのデータベース接続を閉じています..." }
          @storage_manager.close
          @logger.debug { "StorageManagerが閉じられました。" }
        rescue ex
          @logger.error(exception: ex) { "StorageManagerを閉じる際にエラーが発生しました。" }
        end

        # 6. EventDispatcher を最後に停止
        @logger.info { "EventDispatcherを停止中..." }
        begin
          @event_dispatcher.stop
          @logger.debug { "EventDispatcherが停止しました。" }
        rescue ex
          @logger.error(exception: ex) { "EventDispatcherの停止中にエラーが発生しました。" }
        end

        # 7. 最終的な状態遷移
        @state.set(State::Stopped)
        @shutdown_requested.clear
        @start_time = nil
        @logger.info { "QuantumCore::Engineのシャットダウンが完了しました。" }
      end
    rescue ex
      @logger.fatal(exception: ex) { "エンジンシャットダウンシーケンス中に予期せぬ致命的なエラーが発生しました。エンジンの状態が矛盾している可能性があります。" }
      @state.set(State::Failed)
      @shutdown_requested.clear
    end

    # ==============================================================================
    #                      内部イベントリスナーの設定
    # ==============================================================================
    # UI や他のコアコンポーネントからの関連イベントに Engine を購読させます。
    # この設定は、エンジンがユーザーアクションや内部状態の変化にどのように反応するかを定義します。
    private def setup_internal_event_listeners
      @logger.debug { "内部エンジンイベントリスナーを設定中..." }

      # --- UI イベントハンドリング ---
      # UI レイヤーから発生するリクエスト (例: ユーザーアクション) をリッスンします。
      # 各ハンドラは `subscribe_async` を使用して新しい Fiber を生成し、
      # EventDispatcher スレッドをブロックせず、潜在的なエラーを適切に処理します。

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_NEW_TAB) do |event|
        @logger.debug { "UI_REQUEST_NEW_TAB イベントを処理中" }
        # 適切な処理と状態チェックのために、公開 API メソッド `create_page` を使用します。
        create_page(initial_url: @config.homepage, activate: true)
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_CLOSE_TAB) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestCloseTabData)
            page_id = data.page_id
            @logger.debug { "ページ #{page_id} の UI_REQUEST_CLOSE_TAB イベントを処理中" }
            # 削除を試みる前にエンジンが実行中であることを確認します。
            if running?
              @page_manager.remove_page(page_id)
            else
              @logger.warn { "エンジンが実行中でないため、UI_REQUEST_CLOSE_TAB を無視します。" }
            end
         else
            log_invalid_event_data(event)
         end
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_NAVIGATE) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestNavigateData)
            page_id = data.page_id
            url = data.url
            @logger.debug { "ページ #{page_id} の UI_REQUEST_NAVIGATE イベントを処理中 (URL: #{url})" }
            if running?
              page = @page_manager.find_page(page_id)
              if page
                  # ナビゲーションを Page インスタンスに委譲します。
                  page.navigate(url, is_user_initiated: true)
              else
                   @logger.warn { "ナビゲートできません: UI リクエストに対してページ #{page_id} が見つかりません。" }
              end
            else
               @logger.warn { "エンジンが実行中でないため、UI_REQUEST_NAVIGATE を無視します。" }
            end
         else
            log_invalid_event_data(event)
         end
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_RELOAD) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestReloadData)
            page_id = data.page_id
            bypass_cache = data.bypass_cache
            @logger.debug { "ページ #{page_id} の UI_REQUEST_RELOAD イベントを処理中 (キャッシュバイパス: #{bypass_cache})" }
            if running?
              page = @page_manager.find_page(page_id)
              # ページが見つかればリロード、なければ何もしない (try &. を使用)
              page.try &.reload(bypass_cache)
            else
               @logger.warn { "エンジンが実行中でないため、UI_REQUEST_RELOAD を無視します。" }
            end
         else
           log_invalid_event_data(event)
         end
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_STOP) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestStopData)
            page_id = data.page_id
            @logger.debug { "ページ #{page_id} の UI_REQUEST_STOP イベントを処理中" }
             if running?
               page = @page_manager.find_page(page_id)
               # ページが見つかれば読み込み停止、なければ何もしない (try &. を使用)
               page.try &.stop_loading
             else
                @logger.warn { "エンジンが実行中でないため、UI_REQUEST_STOP を無視します。" }
             end
         else
           log_invalid_event_data(event)
         end
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_GO_BACK) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestGoBackData)
            page_id = data.page_id
            @logger.debug { "ページ #{page_id} の UI_REQUEST_GO_BACK イベントを処理中" }
            if running?
              page = @page_manager.find_page(page_id)
              # リクエストがアクティブページに対するものか確認するか、直接処理するか？
              # UI が意図したページコンテキストでこれを送信すると仮定します。
              if page
                page.go_back
              else
                @logger.warn { "戻れません: ページ #{page_id} が見つかりません。" }
              end
            else
               @logger.warn { "エンジンが実行中でないため、UI_REQUEST_GO_BACK を無視します。" }
            end
         else
           log_invalid_event_data(event)
         end
      end

      subscribe_async(QuantumEvents::EventType::UI_REQUEST_GO_FORWARD) do |event|
         if data = event.data_as?(QuantumEvents::UiRequestGoForwardData)
            page_id = data.page_id
            @logger.debug { "ページ #{page_id} の UI_REQUEST_GO_FORWARD イベントを処理中" }
            if running?
              page = @page_manager.find_page(page_id)
              if page
                page.go_forward
              else
                @logger.warn { "進めません: ページ #{page_id} が見つかりません。" }
              end
            else
               @logger.warn { "エンジンが実行中でないため、UI_REQUEST_GO_FORWARD を無視します。" }
            end
            end
         else
            log_invalid_event_data(event)
         end
      end

      # --- コアコンポーネントイベントハンドリング ---
      # 他のマネージャーやコンポーネントによって発行されたイベントをリッスンし、
      # アクションを調整したり、内部状態の変化に対応したりします。
      # ==============================================================================
      #                     内部エンジンイベントリスナー設定
      # ==============================================================================
      # コアコンポーネント（StorageManager, PageManagerなど）や他のマネージャーから
      # ディスパッチされる内部イベントを購読し、エンジン全体の協調動作や状態遷移を管理します。

      # --- ストレージ関連イベント ---
      # ==============================================================================
      # STORAGE_READY イベントハンドラ
      # ==============================================================================
      # StorageManagerが初期化され、永続化ストレージへのアクセスが可能になったことを通知します。
      # このイベントをトリガーとして、以前のセッション状態（開いていたタブ、ウィンドウ位置など）を
      # 復元するプロセスを開始します。セッション復元は潜在的に時間のかかるI/O操作を含むため、
      # アプリケーションの応答性を維持するために、専用のファイバーで非同期に実行されます。
      @event_dispatcher.subscribe(QuantumEvents::EventType::STORAGE_READY) do |event|
        @logger.info { "[Engine] STORAGE_READY イベントを受信しました。永続化ストレージが利用可能です。" }

        # セッション復元処理を非同期で実行するためのファイバーを生成します。
        # ファイバーに名前を付けることで、デバッグや監視が容易になります。
        spawn name: "engine_session_restorer" do
          # ファイバー実行開始時点でのエンジン状態を再度確認します。
          # イベント受信時とファイバー実行開始時の間に状態が変化する可能性があるため、
          # ここでのチェックは競合状態を防ぐために重要です。
          current_state = @state.get
          unless current_state == State::Running
            @logger.warn { "[Engine] セッション復元ファイバー開始時にエンジンが実行状態ではありませんでした (現在の状態: #{current_state})。復元処理を中止します。" }
            next # ファイバーの処理をここで終了します。
          end

          @logger.info { "[Engine] セッション復元プロセスを開始します..." }
          start_time = Time.monotonic

          begin
            # --- セッション復元ロジックの実行 ---
            # restore_sessionメソッドは、ストレージから前回のセッションデータを読み込み、
            # PageManagerなどを介してタブやウィンドウの状態を再構築する責務を持ちます。
            # このメソッドは潜在的に多くの例外を発生させる可能性があるため、
            # 包括的なエラーハンドリングが不可欠です。
            restore_session # 実装はプライベートメソッド restore_session に委譲

            # --- 成功時の処理 ---
            end_time = Time.monotonic
            duration = end_time - start_time
            @logger.info { "[Engine] セッション復元プロセスが正常に完了しました。(所要時間: #{duration.total_milliseconds.round(2)}ms)" }

            # オプション: セッション復元完了を他のコンポーネント（UIなど）に通知するイベントを発行
            # @event_dispatcher.dispatch(QuantumEvents::Event.new(QuantumEvents::EventType::SESSION_RESTORE_COMPLETED))

          rescue ex : Exception
            # ==============================================================================
            # セッション復元中の例外処理
            # ==============================================================================
            # セッション復元プロセス中に予期せぬ例外が発生した場合の処理を定義します。
            # このブロックは、復元処理の堅牢性を確保し、失敗した場合でも
            # アプリケーションが安全な状態に遷移できるように設計されています。

            # --- 処理時間計測とエラー情報の記録 ---
            end_time = Time.monotonic
            duration = end_time - start_time
            # エラーメッセージには、発生した例外の種類、メッセージ、および処理時間を詳細に含めます。
            error_message = "セッション復元プロセス中に予期せぬエラーが発生しました。" \
                            " (所要時間: #{duration.total_milliseconds.round(2)}ms)" \
                            " エラータイプ: #{ex.class.name}" \
                            " メッセージ: #{ex.message}"

            # エラーログには、例外オブジェクト全体とスタックトレースを含め、デバッグに必要な情報を最大限記録します。
            @logger.error(exception: ex) do
              "[Engine] #{error_message}\nスタックトレース:\n#{ex.backtrace.join("\n")}"
            end

            # --- エラー通知イベントの発行 ---
            # セッション復元に失敗したことを、他のシステムコンポーネント（特にUI層）に通知するための
            # イベントを発行します。これにより、ユーザーへのエラー通知や代替処理の開始が可能になります。
            begin
              # イベントデータには、エラーメッセージ、例外オブジェクト、スタックトレースを含めます。
              # これにより、イベント受信側で詳細なエラー情報を利用できます。
              failure_data = QuantumEvents::SessionRestoreFailedData.new(
                error_message: error_message,
                exception: ex,
                stack_trace: ex.backtrace.join("\n") # スタックトレースもデータに含める
              )
              failure_event = QuantumEvents::Event.new(
                QuantumEvents::EventType::SESSION_RESTORE_FAILED,
                failure_data
              )

              # イベントディスパッチャを通じてイベントを発行します。
              @event_dispatcher.dispatch(failure_event)
              @logger.info { "[Engine] SESSION_RESTORE_FAILED イベントを正常に発行しました。" }

            rescue dispatch_ex : Exception
              # --- イベントディスパッチ失敗時の最終防衛ライン ---
              # SESSION_RESTORE_FAILED イベントの発行自体に失敗した場合の処理です。
              # これはイベントシステム自体に問題がある可能性を示唆しており、極めて深刻な状況です。
              @logger.fatal(exception: dispatch_ex) do
                "[Engine] SESSION_RESTORE_FAILED イベントのディスパッチ中に致命的なエラーが発生しました。" \
                " セッション復元の失敗を通知できません。" \
                " ディスパッチエラータイプ: #{dispatch_ex.class.name}" \
                " メッセージ: #{dispatch_ex.message}\nスタックトレース:\n#{dispatch_ex.backtrace.join("\n")}"
              end
              # この段階でのエラーは回復が困難である可能性が高いです。
              # アプリケーションの安定性を最優先し、安全なシャットダウンプロセスを開始することを検討します。
              # initiate_emergency_shutdown("Failed to dispatch SESSION_RESTORE_FAILED event due to: #{dispatch_ex.message}")
              # 緊急シャットダウンが実装されていない場合は、少なくともログに致命的エラーとして記録し、
              # 可能な限り動作を継続しようと試みるか、あるいはプロセスを終了させます。
              # 現時点では、ログ記録に留め、後続のフォールバック処理に進みますが、
              # 本番環境ではより積極的なエラーハンドリング（例：プロセスの再起動要求）が必要です。
            end

            # --- フォールバック戦略の実行 ---
            # セッション復元に失敗した場合の代替処理を実行します。
            # ここでは、専用のハンドラメソッド `handle_session_restore_failure` を呼び出し、
            # 失敗後の具体的な挙動（例: 空のセッションで開始、エラー画面の表示指示など）を委譲します。
            @logger.warn { "[Engine] セッション復元に失敗したため、フォールバック処理を実行します..." }
            begin
              # handle_session_restore_failure メソッドは、例外オブジェクトを引数として受け取り、
              # 失敗の種類や深刻度に応じて適切な対応を行います。
              # 例えば、設定ファイルが破損している場合はデフォルト設定で起動する、
              # 一時的なエラーであれば空のセッションで起動するなど、状況に応じた戦略を実装します。
              handle_session_restore_failure(ex)

              @logger.info { "[Engine] セッション復元失敗後のフォールバック処理が完了しました。" }
            rescue fallback_ex : Exception
              # フォールバック処理自体でエラーが発生した場合、これは非常に深刻な状況です。
              # アプリケーションの初期化プロセスが続行不可能である可能性が高いです。
              @logger.fatal(exception: fallback_ex) do
                "[Engine] セッション復元失敗後のフォールバック処理中に致命的なエラーが発生しました。" \
                " アプリケーションの初期化を安全に継続できません。" \
                " フォールバックエラータイプ: #{fallback_ex.class.name}" \
                " メッセージ: #{fallback_ex.message}\nスタックトレース:\n#{fallback_ex.backtrace.join("\n")}"
              end
              # この時点で、アプリケーションは不安定な状態にある可能性が高いため、
              # 安全なシャットダウンを試みるべきです。
              # initiate_emergency_shutdown("Fatal error during session restore fallback: #{fallback_ex.message}")
              # ここでのエラーは、アプリケーションの起動自体を妨げる可能性があるため、
              # 可能な限り早期にプロセスを終了させるか、ユーザーに重大な問題を通知する必要があります。
            end

          end # end rescue ex : Exception
        end # end spawn
      end # end @event_dispatcher.subscribe(STORAGE_READY)
      # End of Selection

      # STORAGE_ERROR: StorageManagerが致命的または非致命的なエラーを検出したことを示すイベント。
      # ストレージエラーはシステムの安定性に直接影響する可能性があるため、同期的に処理します。
      # これにより、エラー発生時に即座に対応し、データ破損のリスクを最小限に抑えます。
      @event_dispatcher.subscribe(QuantumEvents::EventType::STORAGE_ERROR) do |event|
        begin
          # イベントデータが期待される型であることを確認します。
          # QuantumCore::Storage::StorageErrorData はエラーメッセージと致命的かどうかを示すフラグを含むと仮定します。
          if data = event.data_as?(QuantumCore::Storage::StorageErrorData)
            @logger.error { "STORAGE_ERROR イベント受信: #{data.message} (致命的: #{data.is_fatal})" }
            # エラー処理のコアロジックは専用のプライベートメソッドに委譲します。
            handle_storage_error(data.message, data.is_fatal)
          else
            # 期待しないデータ形式の場合、警告ログを出力します。
            log_invalid_event_data(event)
          end
        rescue ex
          # 同期ハンドラ自体の内部でエラーが発生した場合も捕捉します。
          @logger.fatal(exception: ex) { "STORAGE_ERROR イベントハンドラ自体の処理中に致命的なエラーが発生しました。" }
          # ハンドラ自体の失敗は重大な問題を示す可能性があるため、エンジンのシャットダウンを検討します。
          # ここで即時シャットダウンをトリガーするか、より高度なエラー回復メカニズムに委ねるかは設計判断となります。
          # 例: initiate_emergency_shutdown("STORAGE_ERROR handler failure")
        end
      end

      # --- ページ管理関連イベント ---

      # PAGE_CRASHED: ページのレンダリングプロセスが予期せず終了したことを示すイベント。
      # 通常、単一のページに影響が限定されるため、非同期で処理し、ブラウザ全体の応答性を維持します。
      subscribe_async(QuantumEvents::EventType::PAGE_CRASHED) do |event|
        # QuantumCore::PageCrashedData はクラッシュした page_id と理由 (オプション) を含むと仮定します。
        if data = event.data_as?(QuantumCore::PageCrashedData)
          page_id = data.page_id
          reason = data.reason || "不明な理由" # reasonがnilの場合はデフォルトメッセージを使用
          @logger.warn { "PAGE_CRASHED イベント受信: ページ #{page_id} がクラッシュしました。理由: #{reason}" }
          # ページクラッシュ処理のコアロジックを専用メソッドに委譲します。
          handle_page_crash(page_id, reason)
          # handle_page_crash 内で、UIにクラッシュ状態を表示するための別のイベント
          # (例: UI_UPDATE_PAGE_STATE) がディスパッチされることを想定しています。
        else
          log_invalid_event_data(event)
        end
      end

      # --- 設定関連イベント ---

      # CONFIG_RELOAD_REQUESTED: 設定ファイルの動的な再読み込み要求を示すイベント。
      # 設定の再読み込みはファイルI/Oや複雑な状態更新を伴う可能性があるため、非同期で処理します。
      # トリガーメカニズム（ファイル監視、IPCなど）はこのリスナーの外部で実装される必要があります。
      subscribe_async(QuantumEvents::EventType::CONFIG_RELOAD_REQUESTED) do |event|
        # 設定再読み込みイベントには、特定のデータが含まれない場合が多いと想定します。
        # 必要であれば、QuantumEvents::ConfigReloadRequestedData のような型を定義します。
        @logger.info { "CONFIG_RELOAD_REQUESTED イベント受信: 設定の再読み込みを開始します。" }
        # 設定再読み込みのコアロジックを専用メソッドに委譲します。
        reload_configuration
      end

      # --- ネットワーク状態関連イベント ---

      # NETWORK_CONNECTIVITY_CHANGED: ネットワーク接続状態の変更を示すイベント。
      # ネットワーク状態の監視とこのイベントのディスパッチは、専用のネットワーク監視コンポーネントが担当します。
      subscribe_async(QuantumEvents::EventType::NETWORK_CONNECTIVITY_CHANGED) do |event|
        # QuantumEvents::NetworkConnectivityData はオンライン状態を示す is_online: Bool を含むと仮定します。
        if data = event.data_as?(QuantumEvents::NetworkConnectivityData)
          is_online = data.is_online
          status_string = is_online ? "オンライン" : "オフライン"
          @logger.info { "NETWORK_CONNECTIVITY_CHANGED イベント受信: ネットワーク状態が #{status_string} に変更されました。" }
          # ネットワーク状態変更に伴う処理（UI更新、リクエストの再試行など）を専用メソッドに委譲します。
          handle_network_change(is_online)
        else
          log_invalid_event_data(event)
      end
    end
    
      # --- ダウンロード管理イベント ---

      # DOWNLOAD_STARTED: 新しいダウンロードが開始されたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::DOWNLOAD_STARTED) do |event|
        # QuantumEvents::DownloadStartedData は download_id, url, file_path などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::DownloadStartedData)
          @logger.info { "DOWNLOAD_STARTED イベント受信: ダウンロード #{data.download_id} を開始しました (#{data.url})。" }
          handle_download_started(data)
        else
          log_invalid_event_data(event)
        end
      end

      # DOWNLOAD_PROGRESS: ダウンロードの進捗状況を示すイベント。
      subscribe_async(QuantumEvents::EventType::DOWNLOAD_PROGRESS) do |event|
        # QuantumEvents::DownloadProgressData は download_id, bytes_downloaded, total_bytes などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::DownloadProgressData)
          # 進捗ログはデバッグレベルに留めるか、頻度を調整することを検討します。
          @logger.debug { "DOWNLOAD_PROGRESS イベント受信: ダウンロード #{data.download_id} - #{data.bytes_downloaded} / #{data.total_bytes || '不明'} バイト" }
          handle_download_progress(data)
        else
          log_invalid_event_data(event)
        end
      end
      # DOWNLOAD_COMPLETED: ダウンロードが正常に完了したことを示すイベント。
      subscribe_async(QuantumEvents::EventType::DOWNLOAD_COMPLETED) do |event|
        # QuantumEvents::DownloadCompletedData は download_id, file_path などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::DownloadCompletedData)
          @logger.info { "DOWNLOAD_COMPLETED イベント受信: ダウンロード #{data.download_id} が完了しました (#{data.file_path})。" }
          handle_download_completed(data)
        else
          log_invalid_event_data(event)
        end
      end

      # DOWNLOAD_FAILED: ダウンロードが失敗したことを示すイベント。
      subscribe_async(QuantumEvents::EventType::DOWNLOAD_FAILED) do |event|
        # QuantumEvents::DownloadFailedData は download_id, error_message などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::DownloadFailedData)
          @logger.error { "DOWNLOAD_FAILED イベント受信: ダウンロード #{data.download_id} が失敗しました。理由: #{data.error_message}" }
          handle_download_failed(data)
        else
          log_invalid_event_data(event)
        end
      end

      # --- 権限管理イベント ---

      # PERMISSION_REQUESTED: Webページが特定の権限（位置情報、通知など）をリクエストしたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::PERMISSION_REQUESTED) do |event|
        # QuantumEvents::PermissionRequestedData は request_id, page_id, permission_type, origin などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::PermissionRequestedData)
          @logger.info { "PERMISSION_REQUESTED イベント受信: ページ #{data.page_id} (#{data.origin}) が権限 '#{data.permission_type}' をリクエストしました (リクエストID: #{data.request_id})。" }
          # UIプロンプトを表示する可能性のあるハンドラーに委譲します。
          handle_permission_request(data)
        else
          log_invalid_event_data(event)
        end
      end

      # PERMISSION_GRANTED: ユーザーまたはポリシーによって権限が許可されたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::PERMISSION_GRANTED) do |event|
        # QuantumEvents::PermissionGrantedData は page_id, permission_type, origin などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::PermissionGrantedData)
          @logger.info { "PERMISSION_GRANTED イベント受信: 権限 '#{data.permission_type}' が #{data.origin} (ページ #{data.page_id}) に許可されました。" }
          # 権限状態を更新する可能性のあるハンドラーに委譲します。
          handle_permission_granted(data)
        else
          log_invalid_event_data(event)
        end
      end

      # PERMISSION_DENIED: ユーザーまたはポリシーによって権限が拒否されたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::PERMISSION_DENIED) do |event|
        # QuantumEvents::PermissionDeniedData は page_id, permission_type, origin などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::PermissionDeniedData)
          @logger.info { "PERMISSION_DENIED イベント受信: 権限 '#{data.permission_type}' が #{data.origin} (ページ #{data.page_id}) に対して拒否されました。" }
          # 権限状態を更新する可能性のあるハンドラーに委譲します。
          handle_permission_denied(data)
        else
          log_invalid_event_data(event)
        end
      end

      # --- 拡張機能管理イベント ---

      # EXTENSION_LOADED: 拡張機能が正常に読み込まれたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::EXTENSION_LOADED) do |event|
        # QuantumEvents::ExtensionLoadedData は extension_id, name, version などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::ExtensionLoadedData)
          @logger.info { "EXTENSION_LOADED イベント受信: 拡張機能 '#{data.name}' (ID: #{data.extension_id}, バージョン: #{data.version}) が読み込まれました。" }
          handle_extension_loaded(data)
        else
          log_invalid_event_data(event)
        end
      end

      # EXTENSION_UNLOADED: 拡張機能がアンロードされたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::EXTENSION_UNLOADED) do |event|
        # QuantumEvents::ExtensionUnloadedData は extension_id などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::ExtensionUnloadedData)
          @logger.info { "EXTENSION_UNLOADED イベント受信: 拡張機能 (ID: #{data.extension_id}) がアンロードされました。" }
          handle_extension_unloaded(data)
        else
          log_invalid_event_data(event)
        end
      end

      # EXTENSION_MESSAGE_RECEIVED: 拡張機能からメッセージが送信されたことを示すイベント（例：バックグラウンドスクリプト → ブラウザプロセス）。
      subscribe_async(QuantumEvents::EventType::EXTENSION_MESSAGE_RECEIVED) do |event|
        # QuantumEvents::ExtensionMessageReceivedData は source_extension_id, target (オプション), message_content などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::ExtensionMessageReceivedData)
          @logger.debug { "EXTENSION_MESSAGE_RECEIVED イベント受信: 拡張機能 #{data.source_extension_id} からのメッセージ。" }
          handle_extension_message(data)
        else
          log_invalid_event_data(event)
        end
      end

      # --- パフォーマンス監視イベント ---

      # PERFORMANCE_WARNING: パフォーマンス関連の警告（高CPU使用率、長時間タスクなど）を示すイベント。
      subscribe_async(QuantumEvents::EventType::PERFORMANCE_WARNING) do |event|
        # QuantumEvents::PerformanceWarningData は warning_type, details, affected_component (オプション) などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::PerformanceWarningData)
          @logger.warn { "PERFORMANCE_WARNING イベント受信: タイプ '#{data.warning_type}'、詳細: #{data.details}" }
          handle_performance_warning(data)
        else
          log_invalid_event_data(event)
        end
      end

      # HIGH_MEMORY_USAGE: メモリ使用量が高いレベルに達したことを示すイベント。
      subscribe_async(QuantumEvents::EventType::HIGH_MEMORY_USAGE) do |event|
        # QuantumEvents::HighMemoryUsageData は usage_mb, limit_mb, process_type (オプション) などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::HighMemoryUsageData)
          @logger.warn { "HIGH_MEMORY_USAGE イベント受信: メモリ使用量 #{data.usage_mb}MB (制限: #{data.limit_mb}MB)" }
          # メモリクリーンアップを試みたり、ユーザーに通知したりする可能性のあるハンドラーに委譲します。
          handle_high_memory_usage(data)
        else
          log_invalid_event_data(event)
        end
      end

      # --- プロセス管理イベント ---

      # PROCESS_LAUNCHED: 新しいプロセス（レンダラー、拡張機能など）が開始されたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::PROCESS_LAUNCHED) do |event|
        # QuantumEvents::ProcessLaunchedData は process_id, process_type, associated_id (例：page_id, extension_id) などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::ProcessLaunchedData)
          @logger.info { "PROCESS_LAUNCHED イベント受信: プロセス #{data.process_id} (タイプ: #{data.process_type}) が開始されました。" }
          handle_process_launched(data)
        else
          log_invalid_event_data(event)
        end
      end

      # PROCESS_EXITED: プロセスが終了したことを示すイベント（クラッシュ以外の終了を含む）。
      subscribe_async(QuantumEvents::EventType::PROCESS_EXITED) do |event|
        # QuantumEvents::ProcessExitedData は process_id, exit_code, reason などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::ProcessExitedData)
          @logger.info { "PROCESS_EXITED イベント受信: プロセス #{data.process_id} が終了しました (コード: #{data.exit_code})。理由: #{data.reason || "不明"}" }
          # 通常の終了または他の非クラッシュ終了を処理します（PAGE_CRASHEDとは区別）。
          handle_process_exited(data)
        else
          log_invalid_event_data(event)
        end
      end

      # --- 履歴管理イベント ---

      # HISTORY_ITEM_ADDED: 閲覧履歴に新しい項目が追加されたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::HISTORY_ITEM_ADDED) do |event|
        # QuantumEvents::HistoryItemAddedData は url, title, timestamp などを含むと仮定します。
        if data = event.data_as?(QuantumEvents::HistoryItemAddedData)
          # 履歴の追加は頻繁に発生する可能性があるため、デフォルトではデバッグレベルでログを記録します。
          @logger.debug { "HISTORY_ITEM_ADDED イベント受信: '#{data.title}' (#{data.url}) が履歴に追加されました。" }
          # UI更新や同期プロセスをトリガーする可能性のあるハンドラーに委譲します。
          handle_history_item_added(data)
        else
          log_invalid_event_data(event)
        end
      end

      # HISTORY_CLEARED: 閲覧履歴がクリアされたことを示すイベント。
      subscribe_async(QuantumEvents::EventType::HISTORY_CLEARED) do |event|
        # QuantumEvents::HistoryClearedData は time_range (オプション) などを含む可能性があると仮定します。
        @logger.info { "HISTORY_CLEARED イベント受信: 履歴がクリアされました。" }
        # UI更新をトリガーする可能性のあるハンドラーに委譲します。
        handle_history_cleared(event.data_as?(QuantumEvents::HistoryClearedData))
      end

      # --- Cookie管理イベント ---

      # COOKIES_CHANGED: Cookieストアに変更が発生したことを示すイベント。
      subscribe_async(QuantumEvents::EventType::COOKIES_CHANGED) do |event|
        # QuantumEvents::CookiesChangedData は変更に関する詳細（追加、削除、更新されたCookie、ドメインなど）を含むと仮定します。
        # 変更は頻繁に発生する可能性があるため、より低いレベル（デバッグ）でログを記録します。
        if data = event.data_as?(QuantumEvents::CookiesChangedData)
          # デバッグに必要な場合は詳細をログに記録します。本番環境では重要な情報のみをログに記録することを検討してください。
          @logger.debug { "COOKIES_CHANGED イベント受信: Cookieストアの変更。詳細: #{data.inspect}" }
          # 関連するUIを更新したり、拡張機能に通知したりする可能性のあるハンドラーに委譲します。
           handle_cookies_changed(data)
        else
          # データがなくても何かが確実に変更されたため、イベントをログに記録します。
          @logger.debug { "COOKIES_CHANGED イベント受信: Cookieストアの変更（具体的なデータなし）。" }
           handle_cookies_changed(nil)
        end
      end

      # --- リスナー設定完了ログ ---
      @logger.info { "すべての内部エンジンイベントリスナーが設定されました。" }
    end

    # イベントタイプをサブスクライブし、そのハンドラーを新しいFiber内で非同期に実行するヘルパー。
    # エンジンが実行中であることを確認し、エラー処理を含みます。
    #
    # @param event_type [QuantumEvents::EventType] サブスクライブするイベントのタイプ。
    # @param handler [Proc(QuantumEvents::Event, Void)] イベント受信時に実行するブロック。
    private def subscribe_async(event_type : QuantumEvents::EventType, &handler : QuantumEvents::Event -> Void)
      @event_dispatcher.subscribe(event_type) do |event|
        # ディスパッチャースレッドをブロックせずにイベントを処理するための新しいFiberを生成します。
        spawn name: "engine_handler_#{event_type}" do
          begin
            # エンジンが現在Running状態の場合のみイベントを処理します。
            # これにより、起動中、シャットダウン中、または障害発生後のイベント処理を防ぎます。
            if @state.get == State::Running
              handler.call(event)
            else
              @logger.debug { "エンジンがRunning状態ではないため、#{event_type}の非同期イベントハンドラーをスキップします（現在の状態: #{@state.get}）。" }
            end
          rescue ex
            # イベントハンドラーFiber内で発生した例外をログに記録します。
            @logger.error(exception: ex) { "イベントの非同期ハンドラー実行中にエラーが発生しました: #{event_type}" }
            # 監視または潜在的な回復アクションのための一般的な内部エラーイベントをディスパッチします。
            # QuantumEvents::InternalErrorDataが存在するか、他の場所で定義されていると仮定します。
            internal_error_data = QuantumEvents::InternalErrorData.new(
              context: "#{event_type}の非同期イベントハンドラー",
              error_message: ex.message,
              backtrace: ex.backtrace.join("\n"),
              original_event_type: event.type,
              original_event_data: event.data.inspect # 機密データのログ記録には注意してください
            )
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
              QuantumEvents::EventType::INTERNAL_ERROR,
              internal_error_data
            ))
          end
        end
      end
    end

    # 予期されたフォーマットまたはタイプと一致しないデータでイベントが受信された場合に
    # 標準化された警告をログに記録するヘルパーメソッド。
    #
    # @param event [QuantumEvents::Event] 予期しないデータを持つイベント。
    private def log_invalid_event_data(event : QuantumEvents::Event)
      @logger.warn { "予期しないまたは無効なデータフォーマットでイベント '#{event.type}' を受信しました: #{event.data.inspect}" }
    end

    # ==============================================================================
    #                     特定のイベントハンドラーメソッド
    # ==============================================================================
    # これらのプライベートメソッドには、エンジンのイベントリスナーが受信する特定の内部
    # イベントを処理するためのコアロジックが含まれています。

    # StorageManagerから報告されたクリティカルなストレージエラーを処理します。
    # このメソッドはSTORAGE_ERRORイベントリスナーから同期的に呼び出されます。
    #
    # @param message [String] StorageManagerからのエラーメッセージ。
    # @param is_fatal [Bool] StorageManagerがエラーを致命的と見なすかどうかを示します。
    private def handle_storage_error(message : String, is_fatal : Bool)
      @logger.error { "ストレージエラーの処理: '#{message}' (致命的と報告: #{is_fatal})" }

      # UIレイヤーにエラーを通知します。
      # UIレイヤーがこのイベントタイプをリッスンし、適切なメッセージを表示できると仮定します。
      @event_dispatcher.dispatch(QuantumEvents::Event.new(
        QuantumEvents::EventType::UI_SHOW_ERROR_MESSAGE, # 想定されるイベントタイプ
        QuantumEvents::UiShowErrorMessageData.new(       # 想定されるデータクラス
          title: "ストレージエラー",
          message: "重大なストレージエラーが発生しました: #{message}。一部のブラウザ機能（履歴やCookieなど）が利用できないか、正しく機能しない可能性があります。",
          is_fatal: is_fatal
        )
      ))

      # エラーの性質に基づいてより洗練されたエラー処理を実装します：
      if is_fatal
        # ストレージマネージャーがエラーを致命的と報告した場合、潜在的なデータ破損を防ぐために
        # エンジンのシャットダウンを開始します。
        @logger.fatal { "致命的なストレージエラーが発生しました。緊急シャットダウンを試みます。" }
        # シャットダウンを非同期に開始するためにspawnを使用します。これにより、シャットダウン
        # シーケンスに必要なロックを保持している可能性のあるコンテキストからこのハンドラーが
        # トリガーされた場合の潜在的なデッドロックを回避します。また、現在のイベント処理を
        # 完了させることも可能にします。
        spawn name: "engine_fatal_shutdown" do
          shutdown("致命的なストレージエラー: #{message}")
        end
      else
        # 致命的でないエラーの場合：
        # 1. 影響を受ける機能を特定：失敗しているストレージコンポーネント（履歴、Cookie、
        #    ローカルストレージなど）に依存するブラウザ機能を特定します。
        #    @logger.warn { "ストレージエラーが影響するコンポーネント: [コンポーネントリスト]" }
        #
        # 2. 機能を選択的に無効化：状態を悪化させたり、不整合なデータにつながる可能性のある
        #    操作を防止します。
        #    # 例: @history_manager.disable_writes
        #    # 例: @cookie_manager.set_read_only
        #    @logger.warn { "影響を受けるストレージコンポーネントの書き込みを無効化します。" }
        #
        # 3. 回復を試みる（該当する場合）：一部のエラーは回復可能かもしれません。
        #    # 例: 一時的な問題に対するバックオフを伴う再試行メカニズム。
        #    # 例: クリーンアップまたは検証タスクをトリガーする。
        #    @logger.info { "ストレージエラーの回復アクションを試みています..." }
        #
        # 4. 具体的なユーザーガイダンスを提供：より詳細なUIイベントをディスパッチします。
        #    @event_dispatcher.dispatch(QuantumEvents::Event.new(
        #      QuantumEvents::EventType::UI_SHOW_WARNING_MESSAGE, # 想定されるイベントタイプ
        #      QuantumEvents::UiShowWarningMessageData.new( # 想定されるデータクラス
        #        title: "ストレージの問題",
        #        message: "ストレージの問題により履歴を保存できませんでした。閲覧履歴が不完全になる可能性があります。",
        #        details: message
        #      )
        #    ))
        @logger.warn { "致命的でないストレージエラーが発生しました。予防措置を講じています。" }
      end
    end

    # ページプロセス（またはレンダリングコンテキスト）がクラッシュしたという通知を処理します。
    # このメソッドはPAGE_CRASHEDイベントリスナーから非同期的に呼び出されます。
    #
    # @param page_id [String] クラッシュしたページの一意の識別子。
    # @param reason [String?] クラッシュの理由を説明するオプションの文字列（利用可能な場合）。
    private def handle_page_crash(page_id : String, reason : String?)
      crash_reason = reason.presence || "理由が提供されていません"
      @logger.warn { "ページ #{page_id} のクラッシュを処理しています。理由: #{crash_reason}" }

      # まだ存在する場合は、PageManagerのPageオブジェクトの状態を更新します。
      # これは内部的にページのステータスを追跡するのに役立ちます。
      begin
        page = @page_manager.find_page(page_id)
        if page
          page.mark_as_crashed(crash_reason) # Pageに`mark_as_crashed`メソッドがあると仮定します
          @logger.debug { "ページ #{page_id} をPageManagerでクラッシュとしてマークしました。" }
        else
          @logger.warn { "クラッシュとしてマークするためのページ #{page_id} をPageManagerで見つけられませんでした。" }
        end
      rescue ex
        @logger.error(exception: ex) { "クラッシュしたページ #{page_id} のPageManager状態更新中にエラーが発生しました。" }
      end

      # UIレイヤーに特定のタブのクラッシュ情報を表示するよう通知します。
      @event_dispatcher.dispatch(QuantumEvents::Event.new(
        QuantumEvents::EventType::UI_SHOW_CRASH_SCREEN, # 想定されるイベントタイプ
        QuantumEvents::UiShowCrashScreenData.new(       # 想定されるデータクラス
          page_id: page_id,
          reason: crash_reason # 処理された理由を渡します
        )
      ))

      # デバッグのためにクラッシュの詳細をより広範囲にログに記録します。
      # これには、クラッシュイベントデータから利用可能な場合、より多くのコンテキスト
      # （終了コード、特定のエラーメッセージ、部分的なスタックトレースなど）を収集することが含まれる場合があります。
      # 例：別のクラッシュレポートファイルまたはサービスにログを記録します。
      @logger.info { "ページ #{page_id} の詳細なクラッシュログ: [利用可能な場合は終了コード、シグナルなどの詳細を追加]" }

      # 設定またはヒューリスティックに基づいて自動再読み込みを検討します。
      # 例：自動再読み込みが有効かどうかを設定で確認します。
      # if @config.auto_reload_crashed_tabs?
      #   @logger.info { "クラッシュしたページ #{page_id} の自動再読み込みを試みています..." }
      #   # PageManagerまたは別のイベントを介して再読み込みをトリガーするメカニズムが必要です。
      #   # @page_manager.reload_page(page_id, reason: "クラッシュ後の自動再読み込み")
      # end
    end

    # --- 実装されたハンドラー（以前はプレースホルダー） --- #

    # ネットワーク接続の変更を処理します。
    # NETWORK_CONNECTIVITY_CHANGEDを受信したときに非同期的に呼び出されます。
    #
    # @param is_online [Bool] ネットワークがオンラインと見なされる場合はtrue、それ以外の場合はfalse。
    private def handle_network_change(is_online : Bool)
      # このハンドラーは非同期的に実行されますが、重要な操作にはエンジンが
      # 有効な状態である必要がある場合があります。
      # ensure_running! # spawnの後に必要な場合は、ここで状態を再評価します。subscribe_asyncは既に状態をチェックしています。

      status_string = is_online ? "オンライン" : "オフライン"
      @logger.info { "ネットワーク接続の変更を処理しています。現在 #{status_string} です。" }

      # 関連するコアコンポーネントにネットワークステータスの変更を通知します。
      # これらのコンポーネントはそれに応じて動作を調整する場合があります。

      # 1. リソーススケジューラー：ネットワークリクエストの一時停止/再開、接続プールのクリアなど。
      if @resource_scheduler.responds_to?(:set_online_status)
        @resource_scheduler.set_online_status(is_online)
        @logger.debug { "ResourceSchedulerにネットワークステータスを通知しました: #{status_string}。" }
      else
        @logger.warn { "ResourceSchedulerはset_online_statusに応答しません。" }
      end

      # 2. ページマネージャー/個別ページ：ページはオフラインインジケーターの表示、特定の
      #    アクティビティの停止、またはオンラインに戻ったときの再読み込みの試行について
      #    通知される必要がある場合があります。
      #    これには、アクティブなページを反復処理するか、別のイベントをディスパッチすることが含まれる場合があります。
      #    例：
      #    @page_manager.notify_pages_network_status(is_online)
      @logger.debug { "ネットワークステータスの変更についてPageManager/Pagesに通知する必要があります。" }


      # 3. UIイベントのディスパッチ：視覚的なインジケーターを更新するためにUIレイヤーに通知します。
      @event_dispatcher.dispatch(QuantumEvents::Event.new(
        QuantumEvents::EventType::UI_UPDATE_NETWORK_STATUS, # 想定されるイベントタイプ
        QuantumEvents::UiUpdateNetworkStatusData.new(is_online: is_online) # 想定されるデータクラス
      ))
      @logger.debug { "UI_UPDATE_NETWORK_STATUSイベントをディスパッチしました（is_online: #{is_online}）。" }

      # オンラインに戻ったときに同期プロセスをトリガーするなど、他の必要なロジックを追加します。
    end

    # エンジンの設定再読み込みリクエストを処理します。
    # CONFIG_RELOAD_REQUESTEDを受信したときに非同期的に呼び出されます。
    private def reload_configuration
      # 潜在的に破壊的な操作を試みる前に、エンジンが実行中であることを確認します。
      # subscribe_asyncでのチェックで十分かもしれませんが、ここで再確認することで安全性が高まります。
      unless @state.get == State::Running
        @logger.warn { "エンジンが実行中でないため設定の再読み込みをスキップします（状態: #{@state.get}）。" }
        return
      end

      @logger.info { "設定の再読み込みを試みています..." }

      # 設定ファイルのパスを取得
      config_path = @config.config_file_path?
      unless config_path
        @logger.error { "設定を再読み込みできません：ソースファイルパスが不明です。" }
        # UIエラーイベントをディスパッチ
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
          QuantumEvents::EventType::UI_SHOW_ERROR,
          QuantumEvents::UiErrorData.new(
            title: "設定再読み込みエラー",
            message: "設定ファイルのパスが見つかりませんでした。",
            level: QuantumEvents::ErrorLevel::Warning
          )
        ))
        return
      end

      begin
        # 設定アクセスをロック
        @config_mutex.synchronize do
          # 1. 新しい設定ファイルを読み込む
          @logger.debug { "新しい設定を読み込み中: #{config_path}" }
          new_config = Config.load(config_path)

          # 2. 古い設定と新しい設定の差分を計算
          @logger.debug { "設定の変更を適用中..." }
          apply_configuration_changes(@config, new_config)

          # 3. エンジンの設定参照を更新
          @config = new_config
          @logger.info { "設定が正常に再読み込みされました。" }

          # 4. 成功通知をディスパッチ
          @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::UI_SHOW_NOTIFICATION,
            QuantumEvents::UiNotificationData.new(
              title: "設定更新",
              message: "ブラウザ設定が正常に更新されました。",
              level: QuantumEvents::NotificationLevel::Info,
              timeout: 3000 # ミリ秒
            )
          ))
        end
      rescue ex : Config::Error
        @logger.error(exception: ex) { "設定の再読み込みに失敗しました: #{ex.message}" }
        # UIエラーイベントをディスパッチ
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
          QuantumEvents::EventType::UI_SHOW_ERROR,
          QuantumEvents::UiErrorData.new(
            title: "設定再読み込みエラー",
            message: "設定ファイルの読み込み中にエラーが発生しました: #{ex.message}",
            level: QuantumEvents::ErrorLevel::Error
          )
        ))
      rescue ex
        @logger.error(exception: ex) { "設定再読み込み中に予期しないエラーが発生しました。" }
        # UIエラーイベントをディスパッチ
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
          QuantumEvents::EventType::UI_SHOW_ERROR,
          QuantumEvents::UiErrorData.new(
            title: "設定再読み込みエラー",
            message: "予期しないエラーが発生しました: #{ex.message}",
            level: QuantumEvents::ErrorLevel::Error
          )
        ))
      end
    end

    # 古い設定と新しい設定の間の変更を関連するマネージャーに適用します。
    private def apply_configuration_changes(old_config : Config, new_config : Config)
      # プロキシ設定の変更を確認
      if old_config.proxy_settings != new_config.proxy_settings
        @logger.debug { "プロキシ設定の更新を適用中..." }
        @network_manager.update_proxy_settings(new_config.proxy_settings)
      end

      # ログレベルの変更を確認
      if old_config.log_level != new_config.log_level
        @logger.debug { "ログレベルを #{new_config.log_level} に更新中..." }
        update_log_level(new_config.log_level)
      end

      # キャッシュサイズの変更を確認
      if old_config.cache_settings != new_config.cache_settings
        @logger.debug { "キャッシュ設定の更新を適用中..." }
        @cache_manager.update_settings(new_config.cache_settings)
      end

      # プライバシー設定の変更を確認
      if old_config.privacy_settings != new_config.privacy_settings
        @logger.debug { "プライバシー設定の更新を適用中..." }
        @privacy_manager.update_settings(new_config.privacy_settings)
      end

      # 拡張機能設定の変更を確認
      if old_config.extension_settings != new_config.extension_settings
        @logger.debug { "拡張機能設定の更新を適用中..." }
        @extension_manager.update_settings(new_config.extension_settings)
      end

      # パフォーマンス設定の変更を確認
      if old_config.performance_settings != new_config.performance_settings
        @logger.debug { "パフォーマンス設定の更新を適用中..." }
        @resource_scheduler.update_performance_settings(new_config.performance_settings)
      end

      # セキュリティ設定の変更を確認
      if old_config.security_settings != new_config.security_settings
        @logger.debug { "セキュリティ設定の更新を適用中..." }
        @security_manager.update_settings(new_config.security_settings)
      end

      # UI設定の変更を確認し、UIレイヤーに通知
      if old_config.ui_settings != new_config.ui_settings
        @logger.debug { "UI設定の変更を通知中..." }
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
          QuantumEvents::EventType::UI_SETTINGS_CHANGED,
          QuantumEvents::UiSettingsChangedData.new(
            settings: new_config.ui_settings
          )
        ))
      end

      # その他の設定変更に対する処理を追加
    end

    # ロガーの設定を更新します
    private def update_log_level(new_level : LogLevel)
      # ロガーの再構成またはレベル更新APIを使用
      @logger.level = new_level
      
      # 子ロガーも更新
      @component_loggers.each do |component, logger|
        logger.level = new_level
        @logger.debug { "#{component}ロガーのレベルを#{new_level}に更新しました" }
      end
    end
    # ==============================================================================
    #                           公開APIメソッド
    # ==============================================================================
    # エンジンの外部（通常はUIレイヤーやメインアプリケーションコントローラー）との
    # 主要なインターフェースを提供します。

    # 新しいブラウザページ（タブ）を作成し、任意で初期URLを読み込み、
    # さらに任意で現在フォーカスされているページとしてアクティブ化します。
    # このメソッドはエンジンが実行中であることを確認し、主要な処理は
    # PageManagerに委譲します。
    #
    # @param initial_url [String?] 新しいページで読み込むURL。指定がない場合は設定ファイルのホームページが使われます。
    # @param activate [Bool] trueの場合、新しく作成されたページがすぐにアクティブページになります。
    # @return [Page] 新しく作成されたPageインスタンス。
    # @raise [EngineError] エンジンが `Running` 状態でない場合、またはページの作成/アクティブ化に失敗した場合。
    def create_page(initial_url : String? = nil, activate : Bool = true) : Page
      # ページを作成する前に、エンジンが完全に動作可能であることを確認します。
      ensure_running!

      target_url = initial_url || @config.homepage
      @logger.debug { "新しいページの作成をリクエスト (URL: #{target_url.inspect}, アクティブ化: #{activate})" }

      begin
        # 作成プロセスはPageManagerに任せます。
        # PageManagerは、Pageオブジェクトの初期化、必要なリソース（レンダリングプロセスなど）との
        # 関連付け、および内部での登録を担当します。
        page = @page_manager.create_new_page(initial_url: target_url)

        # PageManagerは失敗時にエラーを発生させるべきですが、予期せぬ内部状態に対する
        # 防御策としてnilチェックも行います。
        unless page
          raise EngineError.new("PageManagerがページ作成中に有効なPageインスタンスを返しませんでした。")
        end

        @logger.info { "新しいページが正常に作成されました (ID: #{page.id})" }

        # 要求された場合、新しいページをアクティブにします。これもPageManagerに委譲します。
        # PageManagerはアクティブページの状態を管理し、必要に応じてイベントをディスパッチする必要があります。
        if activate
          @logger.debug { "新しく作成されたページをアクティブ化: #{page.id}" }
          # IDは文字列キーとして変換/使用可能であると仮定します
          @page_manager.set_active_page(page.id.to_s)
        end

        # 作成されたPageオブジェクトを返します。
        page

      rescue ex : PageManager::Error # PageManagerから予期される特定のエラーをキャッチします。
        @logger.error(exception: ex) { "ページ作成/アクティブ化中のPageManagerエラー: #{ex.message}" }
        # 一貫したAPIエラータイプを提供するためにEngineErrorとして再発生させます。
        raise EngineError.new("PageManager経由でのページの作成またはアクティブ化に失敗しました: #{ex.message}", cause: ex)
      rescue ex # プロセス中に発生したその他の予期せぬ例外をキャッチします。
        @logger.error(exception: ex) { "ページ作成/アクティブ化中に予期せぬエラーが発生しました" }
        raise EngineError.new("ページ作成/アクティブ化中に予期せぬ障害が発生しました", cause: ex)
      end
    end

    # --- その他の公開APIメソッド ---
    # エンジンの公開契約を形成する他のメソッドをここに追加します。
    # 必要に応じて `ensure_running!` を使用してエンジン状態を確認してください。

    # ファイルダウンロードを開始します。
    #
    # @param url [String] ダウンロードするファイルのURL。
    # @param target_directory [String?] ダウンロード先のディレクトリ。nilの場合は設定のデフォルトディレクトリが使用されます。
    # @param suggested_filename [String?] 推奨されるファイル名。nilの場合はURLなどから推測されます。
    # @return [String] 開始されたダウンロードの一意なID。
    # @raise [EngineError] エンジンが実行中でない場合、DownloadManagerが利用できない場合、またはダウンロード開始に失敗した場合。
    def start_download(url : String, target_directory : String? = nil, suggested_filename : String? = nil) : String
      ensure_running!
      @logger.debug { "ダウンロード開始リクエスト URL: #{url}" }

      # DownloadManagerが初期化され、利用可能であることを確認します。
      download_manager = @download_manager || raise EngineError.new("DownloadManagerが利用できません")

      # DownloadManagerに処理を委譲します。
      download_id = download_manager.start_new_download(
        url: url,
        # 設定されたデフォルトを使用
        directory: target_directory || @config.download_directory,
        filename: suggested_filename
      )
      download_id
    rescue ex : DownloadManager::Error
      @logger.error(exception: ex) { "ダウンロードの開始に失敗しました: #{ex.message}" }
      raise EngineError.new("ダウンロードの開始に失敗しました: #{ex.message}", cause: ex)
    rescue ex # 予期せぬエラー
      @logger.error(exception: ex) { "ダウンロード開始中に予期せぬエラーが発生しました" }
      raise EngineError.new("ダウンロード開始中に予期せぬ障害が発生しました", cause: ex)
    end

    # 進行中のダウンロードをキャンセルします。
    #
    # @param download_id [String] キャンセルするダウンロードのID。
    # @return [Bool] キャンセルが正常に要求された場合はtrue、それ以外はfalse（ただし、通常はエラーが発生します）。
    # @raise [EngineError] エンジンが実行中でない場合、DownloadManagerが利用できない場合、またはキャンセルに失敗した場合。
    def cancel_download(download_id : String) : Bool
      ensure_running!
      @logger.debug { "ダウンロードキャンセルリクエスト ID: #{download_id}" }

      download_manager = @download_manager || raise EngineError.new("DownloadManagerが利用できません")

      # DownloadManagerに処理を委譲します。
      # DownloadManager#cancel_download は成功時に true を返すことを期待します。
      # 失敗時は DownloadManager::Error が発生することを想定しています。
      download_manager.cancel_download(download_id)
    rescue ex : DownloadManager::Error
      # キャンセル失敗は警告レベルに留めることも考えられますが、APIとしてはエラーの方が明確かもしれません。
      @logger.warn(exception: ex) { "ダウンロード #{download_id} のキャンセルに失敗しました: #{ex.message}" }
      raise EngineError.new("ダウンロードのキャンセルに失敗しました: #{ex.message}", cause: ex)
    rescue ex # 予期せぬエラー
      @logger.error(exception: ex) { "ダウンロードキャンセル中に予期せぬエラーが発生しました (ID: #{download_id})" }
      raise EngineError.new("ダウンロードキャンセル中に予期せぬ障害が発生しました", cause: ex)
    end

    # 特定のページに関連付けられたオリジンに対して、特定の権限を要求します。
    #
    # @param page_id [String] 権限要求のコンテキストとなるページのID。
    # @param permission_type [PermissionManager::Type] 要求する権限の種類 (例: `Geolocation`, `Notifications`)。
    # @return [Nil] 権限要求が正常に開始された場合。結果は非同期にイベント経由で通知される可能性があります。
    # @raise [EngineError] エンジンが実行中でない場合、ページが見つからない場合、ページのURL/オリジンが無効な場合、
    #                      PermissionManagerが利用できない場合、または権限要求の開始に失敗した場合。
    def request_permission(page_id : String, permission_type : PermissionManager::Type) : Nil
      ensure_running!

      page = @page_manager.find_page(page_id)
      unless page
        @logger.warn { "権限を要求できません: ページ #{page_id} が見つかりません。" }
        # false/nilを返すか、エラーを発生させるか？ APIの設計によりますが、ここではエラーにします。
        raise EngineError.new("権限を要求できません: ページが見つかりません。")
      end

      # Pageが現在のURLを取得するメソッドを持っていると仮定します
      page_url = page.current_url
      origin = page_url.try &.origin.try &.to_s

      unless origin
        @logger.warn { "権限を要求できません: ページ #{page_id} に有効なURL/オリジンがありません ('#{page_url}')" }
        # false/nilを返すか、エラーを発生させるか？
        raise EngineError.new("権限を要求できません: ページに有効なオリジンがありません。")
      end

      @logger.debug { "ページ #{page_id} に関連付けられたオリジン '#{origin}' の権限 '#{permission_type}' を要求します" }

      permission_manager = @permission_manager || raise EngineError.new("PermissionManagerが利用できません")

      # PermissionManagerに処理を委譲します。これはイベント経由でUIプロンプトをトリガーする可能性があります。
      # コンテキストのために page_id を渡します
      permission_manager.request(origin, permission_type, page_id)

      nil # 要求が正常に開始されたことを示します (結果は非同期)

    rescue ex : PermissionManager::Error
      @logger.error(exception: ex) { "ページ #{page_id}、オリジン '#{origin || "N/A"}' の権限要求に失敗しました: #{ex.message}" }
      raise EngineError.new("権限要求に失敗しました: #{ex.message}", cause: ex)
    rescue ex : URI::Error # URL解析/オリジン抽出からの潜在的なエラーをキャッチします
      @logger.error(exception: ex) { "ページ #{page_id} のURLエラーのため権限を要求できません: #{ex.message}" }
      raise EngineError.new("ページのURLが無効なため、権限を要求できません。", cause: ex)
    rescue ex # 予期せぬエラー
      @logger.error(exception: ex) { "権限要求中に予期せぬエラーが発生しました (Page: #{page_id}, Type: #{permission_type})" }
      raise EngineError.new("権限要求中に予期せぬ障害が発生しました", cause: ex)
    end

    # ブラウザエンジン全体のステータスまたは診断情報を取得します。
    #
    # @return [Hash(String, JSON::Any)] エンジンの状態、バージョン、リソース使用状況などを含む診断情報のハッシュ。
    def get_diagnostics : Hash(String, JSON::Any)
      # 診断情報は完全に 'Running' でなくても利用可能にすべきか検討します。
      # ensure_running! # 初期化中や停止中の状態でも許可するかもしれません。

      current_state = @state.get
      # PageManagerが存在しない場合でも安全にアクセスします
      page_count = @page_manager.try(&.page_count) || 0
      active_page_id = @page_manager.try(&.active_page_id)
      # ResourceSchedulerが存在しない場合でも安全にアクセスします
      active_requests = @resource_scheduler.try(&.active_request_count) || 0
      # StorageManagerが存在しない場合でも安全にアクセスします
      storage_status = @storage_manager.try(&.status) || "不明"
      # DownloadManagerが存在しない場合でも安全にアクセスします
      active_downloads = @download_manager.try(&.active_download_count) || 0
      # PerformanceMonitorが存在しない場合でも安全にアクセスします (仮)
      # memory_usage_mb = @performance_monitor.try(&.memory_usage_mb)
      # cpu_usage_percent = @performance_monitor.try(&.cpu_usage_percent)

      # @start_time が設定されていると仮定します
      uptime = @start_time ? (Time.monotonic - @start_time).total_seconds.round(2) : nil

      diagnostics = {
        "engine_version" => defined?(QuantumBrowser::VERSION) ? QuantumBrowser::VERSION : "開発版",
        "engine_state"   => current_state.to_s,
        "uptime_seconds" => uptime,
        "active_page_id" => active_page_id,
        "page_count"     => page_count,
        "active_network_requests" => active_requests,
        "storage_status" => storage_status.to_s,
        "active_downloads" => active_downloads,
        # 他のマネージャーからの診断情報を追加:
        # "memory_usage_mb" => memory_usage_mb,
        # "cpu_usage_percent" => cpu_usage_percent,
      }

      # JSON::Anyに変換します。nil値はJSON::Any::Nullになります。
      # 各値を明示的に変換するか、ヘルパーメソッドが必要です。
      # ここでは手動で変換します。
      result = Hash(String, JSON::Any).new
      diagnostics.each do |key, value|
        result[key] = JSON.parse(value.to_json) rescue JSON::Any::Null # 安全策
      end
      result
    end

    # ==============================================================================
    #                           ユーティリティメソッド
    # ==============================================================================

    # エンジンが現在 'Running' 状態であることを保証します。
    # これは、エンジンとそのコンポーネントが完全に初期化され、動作可能である必要がある
    # 公開APIメソッドや内部操作にとって重要です。
    #
    # @raise [EngineError] エンジンの状態が `State::Running` でない場合。
    private def ensure_running!
      current_state = @state.get
      unless current_state == State::Running
        message = "エンジンの操作には 'Running' 状態が必要ですが、現在の状態は '#{current_state}' です。"
        @logger.error { message }
        # 複雑な状態の問題をデバッグするために、ここでコールスタックをログに出力することを検討します。
        # @logger.error { caller.join("\n") }
        raise EngineError.new(message)
      end
    end

    # ==============================================================================
    #                           エラー処理クラス
    # ==============================================================================
    # カスタム例外クラスは、エンジンまたはそのコア操作内で発生した問題について、
    # より具体的なエラーコンテキストを提供します。

    # すべてのエンジン固有の例外の基本エラークラス。
    # 標準ライブラリや依存関係のエラーと区別しながら、一般的なエンジンの問題を
    # キャッチできるようにします。
    class EngineError < Exception
      getter cause : Exception?

      def initialize(message : String, @cause : Exception? = nil)
        super(message)
      end

      # デフォルトのメッセージをオーバーライドして、原因となった例外の詳細を含めます。
      # これにより、デバッグのためのエラー連鎖がより明確になります。
      # 例: "Engine operation failed\n  Caused by: (PageManager::Error) Failed to create process"
      def message : String
        base = super()
        if cause = @cause
          # 明確さのためにクラス名を含めます
          "#{base}\n  原因: (#{cause.class}) #{cause.message}"
        else
          base
        end
      end
    end

    # エンジンの初期 `initialize` フェーズ中に特に発生するエラー。
    # `start` が呼び出される前に、基本的な内部構造の設定に失敗したことを示します。
    class EngineInitializationError < EngineError
    end

    # `start` メソッド中に発生するエラー。
    # エンジンが完全に動作可能になるために必要なコアマネージャーや外部コンポーネントの
    # 初期化または起動中に失敗したことを示します。
    class EngineStartupError < EngineError
    end

    # 外部コンポーネントとの相互作用に関連するエラー。例えば、プロセス間通信（IPC）、
    # 外部関数インターフェース（FFI）、または外部ヘルパープロセスに関する問題。
    # (現在はプレースホルダーです)。
    class ExternalComponentError < EngineError
    end

  end # クラス Engine の終わり
end # モジュール QuantumCore の終わり

# ==============================================================================
#                           イベントデータクラス
# ==============================================================================
# エンジンとその他のコンポーネント間で交換されるイベントデータの定義

# ストレージマネージャー関連のイベントデータ
module QuantumCore::Storage
  # ストレージエラー発生時のイベントデータ
  # ストレージマネージャーが致命的なエラーを検出した際に使用
  class StorageErrorData < QuantumEvents::EventData
    # エラーの詳細メッセージ
    getter message : String
    # 致命的エラーかどうかのフラグ
    # true の場合、エンジンの再起動やデータ復旧処理が必要
    getter is_fatal : Bool

    def initialize(@message : String, @is_fatal : Bool); end
  end
  
  # ストレージ最適化完了時のイベントデータ
  class StorageOptimizationData < QuantumEvents::EventData
    # 最適化によって解放された容量（バイト）
    getter bytes_freed : Int64
    # 最適化にかかった時間（ミリ秒）
    getter duration_ms : Int32
    
    def initialize(@bytes_freed : Int64, @duration_ms : Int32); end
  end
end

# ページ関連のイベントデータ
module QuantumCore
  # ページクラッシュ時のイベントデータ
  class PageCrashedData < QuantumEvents::EventData
    # クラッシュしたページの識別子
    getter page_id : String
    # クラッシュの原因（可能な場合）
    getter reason : String?
    # クラッシュ時のメモリ使用量（KB）
    getter memory_usage_kb : Int32?
    # クラッシュ時のCPU使用率（%）
    getter cpu_usage_percent : Float32?

    def initialize(@page_id : String, @reason : String? = nil, @memory_usage_kb : Int32? = nil, @cpu_usage_percent : Float32? = nil); end
  end
  
  # ページナビゲーション完了時のイベントデータ
  class PageNavigationCompletedData < QuantumEvents::EventData
    # ナビゲーション対象のページID
    getter page_id : String
    # 読み込まれたURL
    getter url : String
    # 読み込み時間（ミリ秒）
    getter load_time_ms : Int32
    # HTTPステータスコード
    getter status_code : Int32
    
    def initialize(@page_id : String, @url : String, @load_time_ms : Int32, @status_code : Int32); end
  end
end

# UIインタラクションイベントデータ
module QuantumEvents
  # エラーメッセージ表示要求のイベントデータ
  class UiShowErrorMessageData < EventData
    # エラーダイアログのタイトル
    getter title : String
    # 表示するエラーメッセージ
    getter message : String
    # 致命的エラーかどうか
    getter is_fatal : Bool
    # エラーコード（診断用）
    getter error_code : String?

    def initialize(@title : String, @message : String, @is_fatal : Bool, @error_code : String? = nil); end
  end

  # クラッシュ画面表示要求のイベントデータ
  class UiShowCrashScreenData < EventData
    # クラッシュしたページの識別子
    getter page_id : String
    # クラッシュの理由
    getter reason : String?
    # 再読み込み可能かどうか
    getter can_reload : Bool
    # デバッグ情報（開発者向け）
    getter debug_info : Hash(String, String)?

    def initialize(@page_id : String, @reason : String? = nil, @can_reload : Bool = true, @debug_info : Hash(String, String)? = nil); end
  end
  
  # 進捗表示要求のイベントデータ
  class UiShowProgressData < EventData
    # 進捗を示す操作の種類
    getter operation_type : String
    # 進捗率（0-100）
    getter percent : Float32
    # 表示するメッセージ
    getter message : String?
    # キャンセル可能かどうか
    getter can_cancel : Bool
    
    def initialize(@operation_type : String, @percent : Float32, @message : String? = nil, @can_cancel : Bool = false); end
  end
end

# ネットワーク関連のイベントデータ
module QuantumEvents
  # ネットワーク接続状態変更のイベントデータ
  class NetworkConnectivityData < EventData
    # オンライン状態
    getter is_online : Bool
    # 接続タイプ（wifi, cellular, ethernet等）
    getter connection_type : String?
    # 接続品質の推定値（0-100、高いほど良い）
    getter connection_quality : Int32?
    
    def initialize(@is_online : Bool, @connection_type : String? = nil, @connection_quality : Int32? = nil); end
  end
  
  # ネットワークリクエスト完了のイベントデータ
  class NetworkRequestCompletedData < EventData
    # リクエストの一意識別子
    getter request_id : String
    # リクエストURL
    getter url : String
    # HTTPステータスコード
    getter status_code : Int32
    # レスポンスサイズ（バイト）
    getter response_size : Int64
    # リクエスト完了までの時間（ミリ秒）
    getter duration_ms : Int32
    
    def initialize(@request_id : String, @url : String, @status_code : Int32, @response_size : Int64, @duration_ms : Int32); end
  end
end

# セキュリティ関連のイベントデータ
module QuantumEvents
  # セキュリティ警告のイベントデータ
  class SecurityWarningData < EventData
    # 警告の種類（証明書エラー、混合コンテンツなど）
    getter warning_type : String
    # 関連するURL
    getter url : String
    # 詳細メッセージ
    getter details : String
    # 重大度（low, medium, high, critical）
    getter severity : String
    
    def initialize(@warning_type : String, @url : String, @details : String, @severity : String); end
  end
end