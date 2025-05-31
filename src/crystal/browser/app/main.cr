# ==============================================================================
# 依存ライブラリとコンポーネントの読み込み
# ==============================================================================
# ブラウザの根幹を成す機能、ユーザーインターフェース、データ永続化、
# プラットフォーム固有機能、そして外部言語（Nim, Zig）との連携に必要な
# モジュール群をここで一括して読み込みます。
# 依存関係を明確にし、アプリケーション全体の構造を把握しやすくします。
# ------------------------------------------------------------------------------
require "../config/config"                      # アプリケーション設定管理
require "../session/session_manager"            # ウィンドウやタブの状態を管理するセッション管理
require "../commands/command_registry"          # コマンドパターン実装のためのレジストリ
require "../commands/*"                         # 各種コマンド実装（例: 新規タブ、ナビゲーション等）
require "../../ui/components/window_manager"    # GUIウィンドウの生成・管理
require "../../ui/components/tabs/tab"          # ブラウザタブの表現（UIコンポーネント）
require "../../ui/components/window"            # ブラウザウィンドウの表現（UIコンポーネント）
require "../../events/dispatcher/event_dispatcher" # アプリケーション内イベントの集約と配信
require "../../events/types/*"                  # イベント種別の定義（例: ネットワーク、UI、ストレージ）
require "../../events/handlers/*"               # 各イベントに対応する処理ロジック
require "../../storage/preferences/user_preferences" # ユーザー設定の永続化
require "../../storage/history/history_manager" # ブラウジング履歴の管理
require "../../storage/bookmarks/bookmark_manager" # ブックマークの管理
require "../../platform/platform_detector"      # 実行中OSの検出と情報取得
require "../../platform/platform_interface"     # プラットフォーム固有機能のインターフェース
require "../../bindings/nim/network_binding"    # Nim言語で実装されたネットワーク機能との連携
require "../../bindings/zig/engine_binding"     # Zig言語で実装されたレンダリングエンジンとの連携
require "../../extensions/manager/extension_manager" # ブラウザ拡張機能の管理
require "../../core/utils/crash_reporter"       # クラッシュ発生時のレポート生成・送信
require "../../core/commands/*"                 # コア機能に関連するコマンド実装 (追加の可能性)
require "log"                                   # 標準のロギングライブラリ
require "signal"                                # OSシグナル処理用
require "../quantum_browser"
require "../network/http3_network_manager"
require "../network/http3_client"
require "../network/http3_performance_monitor"
require "../network/network_factory"
require "option_parser"
require "log"

# ==============================================================================
# ブラウザアプリケーション モジュール
# ==============================================================================
# アプリケーション全体を包括するメインの名前空間です。
# 定数、主要クラス、エントリーポイントを定義します。
# ------------------------------------------------------------------------------
module Browser
  # アプリケーションのバージョン情報。
  # セマンティックバージョニング (例: MAJOR.MINOR.PATCH) に従うことを強く推奨します。
  VERSION = "0.1.0"
  # アプリケーションの正式名称。ユーザーに表示される名前です。
  APP_NAME = "MyHybridBrowser" # 必要に応じて、より洗練された名前に変更してください。

  # ============================================================================
  # Application クラス
  # ============================================================================
  # ブラウザアプリケーションの中核となるクラスです。
  # 全ての主要コンポーネント（設定、セッション、UI、イベント等）を統合管理し、
  # アプリケーションの起動から終了までのライフサイクル全体を制御します。
  # ----------------------------------------------------------------------------
  class Application
    # --- インスタンス変数とアクセサ ---
    # 各主要コンポーネントへのアクセスを提供します。getterにより読み取り専用アクセスを許可します。

    # アプリケーション全体の設定情報（デフォルト設定、ユーザー設定など）を保持します。
    getter config : Config
    # 現在のブラウジングセッション（開いているウィンドウ、タブ、その状態）を管理します。
    getter session_manager : SessionManager
    # ユーザー操作（メニュー選択、ボタンクリック、ショートカットキー）や内部イベントによって
    # 実行されるべき「コマンド」を登録し、実行を仲介します。
    getter command_registry : CommandRegistry
    # ブラウザのメインウィンドウやダイアログなど、GUI要素の生成と管理を行います。
    getter window_manager : UI::Components::WindowManager
    # アプリケーション内で発生する様々なイベント（ネットワーク応答、UI操作、拡張機能からの通知など）を
    # 一元的に受け取り、適切なハンドラにディスパッチ（配信）します。
    getter event_dispatcher : Events::EventDispatcher
    # インストールされたブラウザ拡張機能の読み込み、有効化/無効化、実行、およびライフサイクル管理を行います。
    getter extension_manager : Extensions::ExtensionManager
    # ユーザーが訪れたウェブページの履歴を記録し、検索や削除などの機能を提供します。
    getter history_manager : Storage::HistoryManager
    # ユーザーがお気に入りのウェブページを保存（ブックマーク）し、管理するための機能を提供します。
    getter bookmark_manager : Storage::BookmarkManager
    # アプリケーションが現在実行中かどうかを示すフラグ。主にイベントループの制御に使用されます。
    @running : Bool

    # --- 初期化プロセス ---

    # `Application`クラスの新しいインスタンスを生成し、アプリケーションの実行に必要な
    # 全ての初期設定とコンポーネントのセットアップを実行します。
    # このプロセスには、設定ファイルの読み込み、各マネージャクラスのインスタンス化、
    # 外部言語（Nim, Zig）で実装されたモジュールとの連携確立などが含まれます。
    # 初期化中に致命的なエラーが発生した場合は、ログに記録し、アプリケーションを終了します。
    def initialize
      Log.info { "#{APP_NAME} アプリケーションの初期化プロセスを開始します (バージョン: #{VERSION})" }

      # 1. 実行環境のプラットフォーム（OS）を特定します。
      # これにより、OS固有のAPI呼び出しや挙動の違いに適切に対応できます。
      platform = Platform::PlatformDetector.detect
      Log.info { "実行プラットフォームを検出しました: #{platform.name} #{platform.version}" }
      # プラットフォーム固有の初期化処理を実行します（例: macOSのメニューバー設定、WindowsのCOM初期化など）。
      begin
        platform.initialize_platform_specific_features if platform.responds_to?(:initialize_platform_specific_features)
        Log.debug { "プラットフォーム固有の初期化処理を実行しました。" }
      rescue ex : Exception
        Log.warn(exception: ex) { "プラットフォーム固有の初期化中にエラーが発生しました。一部機能が利用できない可能性があります。" }
      end

      # 2. 設定ファイルを読み込みます。
      # まずアプリケーション組み込みのデフォルト設定を適用し、
      # その後、ユーザー固有の設定ファイル（存在する場合）で上書きします。
      @config = initialize_configuration
      Log.info { "設定ファイルの読み込みが完了しました。" }

      # 3. 主要な管理コンポーネントを初期化します。
      # コンポーネント間の依存関係を考慮し、適切な順序でインスタンス化します。
      # 例えば、多くのコンポーネントがイベントを発行するため、EventDispatcherを先に初期化します。
      @event_dispatcher = Events::EventDispatcher.new
      Log.debug { "イベントディスパッチャを初期化しました。" }

      # WindowManagerはイベントを受け取る可能性があるため、EventDispatcherを渡します。
      @window_manager = UI::Components::WindowManager.new(@event_dispatcher)
      Log.debug { "ウィンドウマネージャを初期化しました。" }

      @command_registry = CommandRegistry.new
      Log.debug { "コマンドレジストリを初期化しました。" }

      # SessionManagerは設定（例: 保存場所）に依存する可能性があります。
      @session_manager = SessionManager.new(@config)
      Log.debug { "セッションマネージャを初期化しました。" }

      # ExtensionManagerは設定（例: 拡張機能ディレクトリ）とイベントディスパッチャに依存します。
      @extension_manager = Extensions::ExtensionManager.new(@config, @event_dispatcher)
      Log.debug { "拡張機能マネージャを初期化しました。" }

      # HistoryManagerとBookmarkManagerは設定（例: 保存場所）に依存します。
      @history_manager = Storage::HistoryManager.new(@config)
      Log.debug { "履歴マネージャを初期化しました。" }
      @bookmark_manager = Storage::BookmarkManager.new(@config)
      Log.debug { "ブックマークマネージャを初期化しました。" }

      # 4. 外部言語（Nim, Zig）バインディングを初期化します。
      # これにより、CrystalからNimのネットワーク機能やZigのレンダリング機能を呼び出せるようになります。
      initialize_external_bindings

      # 5. コアとなるブラウザコマンドを登録します。
      # これにより、UI要素やショートカットキーから「新しいタブを開く」「戻る」などの操作が可能になります。
      register_core_commands

      # 6. グローバルイベントハンドラを登録します。
      # アプリケーション全体で発生する可能性のあるイベント（例: ネットワークエラー、UIテーマ変更）に対応します。
      register_global_event_handlers

      # 7. 実行中フラグを初期化します。
      @running = false # runメソッドが呼ばれるまで実行中ではない

      Log.info { "#{APP_NAME} アプリケーションの初期化が正常に完了しました。" }

    rescue ex : Exception
      # 初期化プロセス中に予期せぬ重大なエラーが発生した場合の処理です。
      Log.fatal(exception: ex) { "アプリケーションの初期化中に回復不能なエラーが発生しました。起動を中止します。" }
      # 可能であればクラッシュレポートを生成・送信します。
      # この時点では一部コンポーネント（Configなど）が初期化されていない可能性があるため、限定的なレポートになる場合があります。
      # report_crash(ex) # ここで呼ぶと config が nil の可能性があるため、start メソッド側で処理する方が安全
      # アプリケーションを異常終了させます。
      exit(1) # エラーコード 1 は一般的な異常終了を示します。
    end

    # --- アプリケーションの実行とライフサイクル管理 ---

    # アプリケーションのメイン実行ロジックを開始します。
    # このメソッドは、アプリケーションが終了するまで通常はブロックし続けます。
    # 実行プロセスには、拡張機能の読み込み、前回のセッション状態の復元、
    # メインブラウザウィンドウの表示、そしてイベント処理ループの開始が含まれます。
    def run
      Log.info { "#{APP_NAME} アプリケーションの実行を開始します..." }
      @running = true # 実行状態に遷移

      # 1. インストールされている拡張機能を読み込み、有効化します。
      # 拡張機能の読み込みエラーは、他の機能に影響を与えない限り、
      # アプリケーション全体の起動を妨げないようにします。
      begin
        @extension_manager.load_extensions
        Log.info { "拡張機能の読み込みが完了しました。" }
      rescue ex : Exception
        Log.error(exception: ex) { "拡張機能の読み込み中にエラーが発生しましたが、アプリケーションの起動は続行します。" }
        # ここでユーザーに通知するUI処理を追加することも検討できます。
        # 例: @window_manager.show_warning_notification("一部の拡張機能が読み込めませんでした。")
      end

      # 2. 前回のセッション状態を復元します。
      # ユーザーが前回終了時に開いていたウィンドウやタブを再現しようと試みます。
      # 復元に失敗した場合や、設定で無効になっている場合は、新しい空のセッションで開始します。
      begin
        restored = @session_manager.restore_last_session
        if restored
          Log.info { "前回のセッションを正常に復元しました。" }
        else
          Log.info { "復元可能なセッションが見つからないか、設定で無効化されています。新しいセッションを開始します。" }
          # 新しいセッションを開始する必要があれば、ここで行う
          # @session_manager.start_new_session # restore_last_session内で失敗時に呼ばれる想定なら不要
        end
      rescue ex : Exception
        Log.error(exception: ex) { "セッションの復元中にエラーが発生しました。安全のため、新しいセッションで開始します。" }
        # エラーが発生した場合でも、必ず新しいセッションを開始してアプリケーションを継続させます。
        @session_manager.start_new_session
      end

      # 3. メインのブラウザウィンドウを作成し、画面に表示します。
      # ウィンドウの作成はGUIの根幹であるため、失敗した場合はアプリケーションを続行できません。
      main_window = create_and_show_main_window

      # 4. スタートアップページを開きます。
      # 設定に基づいて、ホームページ、空白ページ、または前回開いていたページなどを開きます。
      # セッション復元で既にタブが開かれている場合でも、設定によってはホームページを強制的に開くこともあります。
      # (ここでは、タブが空の場合、または常にホームページを開く設定の場合に開くようにしています)
      should_open_startup_page = main_window.tabs.empty? || @config.get_bool("browser.startup.always_open_homepage", default: false)
      if should_open_startup_page
        open_startup_page(main_window)
      end

      Log.info { "#{APP_NAME} の起動シーケンスが完了し、メインイベントループに移行します。" }

      # 5. アプリケーションのメインイベントループを開始します。
      # このループは、ユーザーからの入力（クリック、キーボード操作）、ネットワークからのデータ受信、
      # タイマーイベント、OSからの通知などを継続的に監視し、適切に処理します。
      # アプリケーションが終了するまで、このループ内で待機し続けます。
      run_event_loop

    rescue ex : Exception
      # `run`メソッドの初期段階（イベントループ開始前）で致命的なエラーが発生した場合の処理です。
      Log.fatal(exception: ex) { "アプリケーションの実行開始プロセス中に致命的なエラーが発生しました。" }
      # クラッシュレポートの生成を試みます。
      report_crash(ex)
      # アプリケーションを異常終了させます。
      @running = false # 念のためフラグを倒す
      exit(1)
    end

    # アプリケーションの終了処理（シャットダウン）を実行します。
    # このメソッドは、イベントループが終了した後、または終了シグナルを受け取った際に呼び出されます。
    # 実行中の処理を安全に停止し、必要なデータを保存し、確保したリソースを解放します。
    def shutdown
      # すでにシャットダウン処理が開始されている場合は何もしない（二重呼び出し防止）
      return unless @running
      @running = false # シャットダウン状態へ

      Log.info { "#{APP_NAME} のシャットダウンプロセスを開始します..." }

      # 1. 現在のセッション状態を保存します。
      # 次回起動時に復元できるよう、開いているウィンドウやタブの情報をディスクに書き込みます。
      begin
        @session_manager.save_current_session
        Log.info { "現在のセッション状態を保存しました。" }
      rescue ex : Exception
        Log.error(exception: ex) { "セッションの保存中にエラーが発生しました。次回起動時に状態が復元されない可能性があります。" }
      end

      # 2. 各管理コンポーネントの終了処理を呼び出します。
      # 初期化とは逆の順序（依存関係の少ないものから）でシャットダウンするのが一般的に安全です。
      # 例えば、ウィンドウを閉じてから拡張機能を停止するなど。
      safely_shutdown_component(@extension_manager, "拡張機能マネージャ")
      safely_shutdown_component(@window_manager, "ウィンドウマネージャ")
      safely_shutdown_component(@history_manager, "履歴マネージャ") # HistoryManagerにもshutdownが必要な場合
      safely_shutdown_component(@bookmark_manager, "ブックマークマネージャ") # BookmarkManagerにもshutdownが必要な場合
      # 他のコンポーネント（例: ダウンロードマネージャなど）があれば、ここに追加します。

      # 3. 外部言語バインディングを解放します。
      # NimやZigのモジュールが確保しているメモリやリソースを解放します。
      safely_shutdown_binding(Bindings::Zig::EngineBinding, "Zigレンダリングエンジン")
      safely_shutdown_binding(Bindings::Nim::NetworkBinding, "Nimネットワークスタック")

      Log.info { "#{APP_NAME} のシャットダウンプロセスが正常に完了しました。" }
    end

    # --- プライベートヘルパーメソッド ---
    # クラス内部でのみ使用される補助的なメソッド群です。

    # 設定ファイルを読み込み、Configオブジェクトを初期化して返します。
    # デフォルト設定とユーザー設定をマージします。
    private def initialize_configuration : Config
      config = Config.new
      # デフォルト設定の読み込み試行
      begin
        config.load_defaults
        Log.debug { "アプリケーションのデフォルト設定を読み込みました。" }
      rescue ex : Exception
        # デフォルト設定ファイルが見つからない、または破損している場合。
        # これは通常、アプリケーションの配布物に問題がある可能性を示唆します。
        Log.warn(exception: ex) { "デフォルト設定の読み込みに失敗しました。組み込みの最低限のデフォルト値を使用します。" }
        # ここで、最低限必要なデフォルト値をプログラム的に設定することも検討できます。
        # config.set_defaults_programmatically
      end
      # ユーザー設定の読み込み試行
      begin
        config.load_user_preferences
        Log.debug { "ユーザー固有の設定を読み込み、デフォルト設定にマージしました。" }
      rescue ex : IO::NotFoundError
        # ユーザー設定ファイルがまだ存在しない場合は正常なケースです。
        Log.info { "ユーザー設定ファイルが見つかりません。デフォルト設定のみを使用します。" }
      rescue ex : Exception
        # ユーザー設定ファイルが破損しているなどの場合。
        Log.warn(exception: ex) { "ユーザー設定の読み込みに失敗しました。デフォルト設定のみが使用されます。" }
        # 破損したファイルをバックアップするなどの処理を追加することも検討できます。
      end
      config
    end

    # NimおよびZigで実装された外部モジュールとの連携を初期化します。
    # これには、共有ライブラリの読み込みや初期化関数の呼び出しが含まれる場合があります。
    # 初期化に失敗した場合、関連する機能（ネットワーク、レンダリング）が利用できなくなる可能性があります。
    private def initialize_external_bindings
      Log.info { "外部言語（Nim, Zig）バインディングの初期化を開始します..." }

      # Nimネットワークスタックの初期化
      begin
        Bindings::Nim::NetworkBinding.initialize(@config)
        Log.info { "Nim ネットワークスタックのバインディングを正常に初期化しました。" }
      rescue ex : Exception
        Log.error(exception: ex) { "Nim ネットワークスタックの初期化に失敗しました。ネットワーク関連機能が利用できない可能性があります。" }
        # ユーザーへの通知（例：起動時に警告ダイアログを表示）
        # @window_manager.show_error_dialog("ネットワーク初期化エラー", "ネットワーク機能が利用できません。", ex.message)
        # または、ネットワーク機能を無効化するフラグを設定するなど
        # @network_disabled = true
      end

      # Zigレンダリングエンジンの初期化
      begin
        Bindings::Zig::EngineBinding.initialize(@config)
        Log.info { "Zig レンダリングエンジンのバインディングを正常に初期化しました。" }
      rescue ex : Exception
        Log.error(exception: ex) { "Zig レンダリングエンジンの初期化に失敗しました。ウェブページの表示ができない可能性があります。" }
        # ユーザーへの通知
        # @window_manager.show_error_dialog("レンダリングエンジン初期化エラー", "ページの表示機能が利用できません。", ex.message)
        # または、レンダリング機能を無効化するフラグを設定
        # @rendering_disabled = true
      end
      Log.info { "外部言語バインディングの初期化プロセスが完了しました。" }
    end

    # ブラウザの基本的な操作に対応するコマンドオブジェクトを生成し、
    # コマンドレジストリに登録します。これにより、UI要素（メニュー項目、ツールバーボタン）や
    # キーボードショートカットから、これらの機能を統一的なインターフェースで呼び出せるようになります。
    private def register_core_commands
      Log.debug { "コアブラウザコマンドの登録を開始します..." }
      # 各コマンドは、関連するマネージャ（WindowManager, BookmarkManagerなど）への参照を持ち、
      # 実行時にそのマネージャのメソッドを呼び出して具体的な処理を行います。
      @command_registry.register("browser.tab.new", Commands::NewTabCommand.new(@window_manager))
      @command_registry.register("browser.tab.close", Commands::CloseTabCommand.new(@window_manager))
      @command_registry.register("browser.navigation.navigate", Commands::NavigateCommand.new(@window_manager))
      @command_registry.register("browser.navigation.back", Commands::BackCommand.new(@window_manager))
      @command_registry.register("browser.navigation.forward", Commands::ForwardCommand.new(@window_manager))
      @command_registry.register("browser.navigation.reload", Commands::ReloadCommand.new(@window_manager))
      @command_registry.register("browser.navigation.stop", Commands::StopCommand.new(@window_manager))
      @command_registry.register("browser.bookmarks.add", Commands::BookmarkCommand.new(@bookmark_manager))
      # --- 追加のコアコマンド ---
      # 履歴表示コマンド (WindowManagerとHistoryManagerに依存)
      @command_registry.register("browser.history.show", Commands::ShowHistoryCommand.new(@window_manager, @history_manager))
      # 設定画面表示コマンド (WindowManagerに依存)
      @command_registry.register("browser.settings.show", Commands::ShowSettingsCommand.new(@window_manager))
      # ズームインコマンド (WindowManagerまたはアクティブなタブに依存)
      @command_registry.register("browser.view.zoom_in", Commands::ZoomInCommand.new(@window_manager))
      # ズームアウトコマンド (WindowManagerまたはアクティブなタブに依存)
      @command_registry.register("browser.view.zoom_out", Commands::ZoomOutCommand.new(@window_manager))
      # ズームリセットコマンド
      @command_registry.register("browser.view.zoom_reset", Commands::ZoomResetCommand.new(@window_manager))
      # 開発者ツール表示コマンド
      @command_registry.register("browser.developer.toggle_tools", Commands::ToggleDevToolsCommand.new(@window_manager))
      # 印刷コマンド
      @command_registry.register("browser.file.print", Commands::PrintCommand.new(@window_manager))
      # 終了コマンド
      @command_registry.register("browser.application.quit", Commands::QuitApplicationCommand.new(self))

      # 今後追加される可能性のあるコマンドの例:
      # - ダウンロードマネージャ表示
      # - 拡張機能管理画面表示
      # - ページ内検索
      # - フルスクリーン切り替え
      Log.debug { "コアブラウザコマンドの登録が完了しました。" }
    end

    # アプリケーション全体で発生しうるグローバルなイベントに対応するためのハンドラを
    # イベントディスパッチャに登録します。これにより、特定のイベントが発生した際に、
    # 登録されたハンドラの処理が自動的に呼び出されるようになります。
    # イベント駆動アーキテクチャの根幹部分です。
    private def register_global_event_handlers
      Log.debug { "グローバルイベントハンドラの登録を開始します..." }
      # 各イベントタイプ（例: NetworkEvent, RenderEvent）に対して、
      # そのイベントを処理する責務を持つハンドラクラスのインスタンスを登録します。
      # ハンドラは、イベントに含まれる情報に基づいて、UIの更新、データの保存、
      # 他のコンポーネントへの通知など、適切なアクションを実行します。
      @event_dispatcher.register(Events::Types::NetworkEvent, Events::Handlers::NetworkEventHandler.new)
      @event_dispatcher.register(Events::Types::RenderEvent, Events::Handlers::RenderEventHandler.new)
      # UI関連イベント（例: ウィンドウリサイズ、テーマ変更）はUIハンドラが処理
      @event_dispatcher.register(Events::Types::UserInterfaceEvent, Events::Handlers::UserInterfaceEventHandler.new(@window_manager))
      # 拡張機能からのイベント（例: バックグラウンドからのメッセージ）は拡張機能ハンドラが処理
      @event_dispatcher.register(Events::Types::ExtensionEvent, Events::Handlers::ExtensionEventHandler.new(@extension_manager))
      # ストレージ関連イベント（例: 履歴項目追加、ブックマーク削除）はストレージハンドラが処理
      @event_dispatcher.register(Events::Types::StorageEvent, Events::Handlers::StorageEventHandler.new(@history_manager, @bookmark_manager))

      # --- 将来的な拡張のためのイベントハンドラの例 ---
      # @event_dispatcher.register(Events::Types::DownloadEvent, Events::Handlers::DownloadEventHandler.new(@download_manager))
      # @event_dispatcher.register(Events::Types::PrintEvent, Events::Handlers::PrintEventHandler.new)
      # @event_dispatcher.register(Events::Types::SecurityEvent, Events::Handlers::SecurityEventHandler.new)
      # カスタムイベントタイプを定義し、それに対応するハンドラを登録することも可能です。
      # 例: @event_dispatcher.register(MyCustomEvent, MyCustomEventHandler.new)

      Log.debug { "グローバルイベントハンドラの登録が完了しました。" }
    end

    # メインとなるブラウザウィンドウを作成し、画面上に表示します。
    # ウィンドウの作成や表示に失敗した場合は、アプリケーションの続行が不可能と判断し、
    # 例外を発生させて呼び出し元（runメソッド）にエラーを伝播させます。
    # 戻り値として、作成されたWindowオブジェクトを返します。
    private def create_and_show_main_window : UI::Components::Window
      Log.debug { "メインブラウザウィンドウの作成と表示を開始します..." }
      begin
        # WindowManagerにウィンドウの作成を依頼します。
        main_window = @window_manager.create_main_window
        # 作成されたウィンドウを表示状態にします。
        main_window.show
        Log.info { "メインブラウザウィンドウが正常に作成され、表示されました。" }
        # 成功したら、作成されたウィンドウオブジェクトを返します。
        return main_window
      rescue ex : Exception
        # ウィンドウの作成または表示プロセスでエラーが発生した場合。
        Log.fatal(exception: ex) { "メインウィンドウの作成または表示に致命的な失敗が発生しました。アプリケーションを続行できません。" }
        # エラーを上位に伝播させ、アプリケーションの終了処理を促します。
        raise ex
      end
    end

    # 設定に基づいて決定されたスタートアップページ（ホームページ、空白ページなど）を
    # 指定されたウィンドウ内に新しいタブとして開きます。
    # URLの読み込み中にエラーが発生した場合でも、アプリケーションがクラッシュしないように、
    # エラーを捕捉し、ログに記録した上で、可能であれば代替として空白ページを開きます。
    private def open_startup_page(window : UI::Components::Window)
      # 設定からスタートアップページのURLを取得します。デフォルトは "about:welcome" です。
      start_url_setting = @config.get_string("browser.startup.homepage", default: "about:welcome")
      # 設定値が空文字列の場合は、"about:blank" を使用します。
      start_url = start_url_setting.empty? ? "about:blank" : start_url_setting

      Log.info { "設定に基づき、スタートアップページを開きます: #{start_url}" }
      begin
        # Windowオブジェクトに新しいタブの作成を依頼します。
        # 実装によっては WindowManager を経由する方が適切な場合もあります。
        # new_tab = @window_manager.create_new_tab(window)
        new_tab = window.create_new_tab
        # 作成された新しいタブで、指定されたURLへのナビゲーションを開始します。
        new_tab.navigate(start_url)
        Log.debug { "スタートアップページの読み込みを開始しました: #{start_url}" }
      rescue ex : Exception
        # スタートアップページのURLへのナビゲーション中にエラーが発生した場合。
        Log.error(exception: ex) { "スタートアップページ '#{start_url}' の読み込み中にエラーが発生しました。" }
        # フォールバックとして、空白ページ ("about:blank") を開くことを試みます。
        # ただし、ウィンドウに既にタブが存在する場合のみ（無限ループ防止）。
        begin
          if window.tabs.any? # すでにタブがある場合のみ試行
             Log.info { "フォールバックとして空白ページを開きます。" }
             fallback_tab = window.create_new_tab
             fallback_tab.navigate("about:blank")
          else
             Log.warn { "ウィンドウにタブが存在しないため、フォールバックの空白ページは開きません。" }
          end
        rescue inner_ex : Exception
          # フォールバックの空白ページを開くことすら失敗した場合。
          Log.error(exception: inner_ex) { "エラー発生後のフォールバック処理（空白タブの作成）にも失敗しました。" }
          # この段階でさらにエラーダイアログを表示することも検討できます。
        end
      end
    end


    # アプリケーションの心臓部であるメインイベントループです。
    # このループは、アプリケーションが終了するまで（`@running`フラグが`false`になるまで）、
    # または致命的なエラーが発生するまで、継続的に実行されます。
    # ループ内で、保留中のイベント処理、UIの更新、バックグラウンドタスクの実行などを行います。
    private def run_event_loop
      Log.debug { "メインイベントループを開始します。アプリケーションを終了するには、ウィンドウを閉じるか、終了シグナル (Ctrl+C, TERM) を送信してください。" }

      # --- OSシグナルハンドラの設定 ---
      # ユーザーがCtrl+Cを押した場合 (SIGINT) や、OSがシャットダウンを要求した場合 (SIGTERM) に、
      # アプリケーションを安全に終了（Graceful Shutdown）できるようにハンドラを設定します。
      setup_signal_handlers

      # --- イベントループ本体 ---
      while @running
        begin
          # 1. 保留中のイベントを処理します。
          # これには、GUIツールキットからのイベント（クリック、キー入力）、
          # ネットワークソケットからのデータ到着、タイマーイベントなどが含まれます。
          # `process_events`は、イベントがあれば処理し、なければすぐに戻る（ノンブロッキング）か、
          # 次のイベントが発生するまで待機する（ブロッキング）ように実装されます。
          @event_dispatcher.process_events

          # 2. UIの状態を更新します。
          # 必要に応じて画面の再描画を行ったり、アニメーションを更新したりします。
          # GUIツールキットによっては、`process_events`内で自動的に行われる場合もあります。
          @window_manager.update

          # 3. 拡張機能のバックグラウンド処理を実行します。
          # 定期的に実行する必要があるタスク（例: RSSフィードのチェック）などがあれば、ここで行います。
          @extension_manager.update

          # 4. セッション状態の自動保存（設定が有効な場合）。
          # 定期的に、または変更があった場合に、現在のセッション状態をディスクに保存し、
          # 不意のクラッシュに備えます。
          if @config.get_bool("browser.session.autosave.enabled", default: true) && @session_manager.needs_save?
             @session_manager.auto_save
             # 保存が成功した場合のみデバッグログを出力（頻繁なログ出力を避けるため）
             Log.debug { "セッション状態を自動保存しました。" } if @session_manager.last_save_successful?
          end

          # 5. テスト環境用の早期終了ロジック。
          # 自動テストなどでイベントループを1回だけ実行したい場合に利用します。
          if ENV["TESTING"]? == "true"
            Log.info { "テスト環境フラグ (TESTING=true) が検出されたため、イベントループを1回実行後に終了します。" }
            @running = false
          end

          # 6. CPU使用率の抑制（簡易的な方法）。
          # イベント処理や更新処理が非常に早く完了した場合、ループがCPUを100%消費してしまうのを防ぐため、
          # 短い待機時間を挿入します。
          # **注意:** これは非常に基本的な実装です。実際のGUIアプリケーションでは、
          # GUIツールキットが提供する、より効率的なイベント待機メカニズム
          # (例: `Gtk.main_iteration_do(blocking: true)` や `QApplication::exec()`) を
          # 使用するべきです。`process_events`がブロッキングであれば、この`sleep`は不要かもしれません。
          # 適切な待機時間はアプリケーションの応答性とCPU負荷のバランスを見て調整が必要です。
          sleep @config.get_float("browser.event_loop.sleep_interval_seconds", default: 0.01) # 設定可能にする

        rescue ex : Exception
          # イベントループ内で捕捉されなかった予期せぬ例外は、致命的なエラーとみなします。
          Log.fatal(exception: ex) { "イベントループの実行中に致命的なエラーが発生しました。アプリケーションを強制終了します。" }
          # クラッシュレポートを試みます。
          report_crash(ex)
          # ループを強制的に終了させます。
          @running = false
          # エラーコードで終了します。
          exit(1)
        end
      end

      # --- イベントループ終了後の処理 ---
      # `@running`フラグが`false`になった後（正常終了またはシグナルによる終了要求）、
      # 最終的なシャットダウン処理を実行します。
      Log.info { "メインイベントループが終了しました。シャットダウン処理を実行します..." }
      shutdown
    end

    # OSからの終了シグナル (SIGINT, SIGTERM) を捕捉し、
    # 安全なシャットダウンプロセスを開始するためのハンドラを設定します。
    private def setup_signal_handlers
      Log.debug { "終了シグナル (INT, TERM) のハンドラを設定します。" }
      # SIGINT (通常は Ctrl+C で送信される)
      Signal::INT.trap do
        if @running # 既にシャットダウン中でなければ
          Log.info { "終了シグナル (SIGINT) を受信しました。シャットダウンを開始します..." }
          @running = false # イベントループを終了させる
        else
          Log.warn { "シャットダウン中にSIGINTを再度受信しました。強制終了します。" }
          exit(1) # 強制終了
        end
      end

      # SIGTERM (通常は kill コマンドやOSのシャットダウンプロセスから送信される)
      Signal::TERM.trap do
        if @running # 既にシャットダウン中でなければ
          Log.info { "終了シグナル (SIGTERM) を受信しました。シャットダウンを開始します..." }
          @running = false # イベントループを終了させる
        else
          Log.warn { "シャットダウン中にSIGTERMを再度受信しました。強制終了します。" }
          exit(1) # 強制終了
        end
      end
    end

    # 指定されたコンポーネントオブジェクトに対して、安全にシャットダウン処理を試みます。
    # コンポーネントが `shutdown` メソッドを持っている場合のみ呼び出し、
    # 処理中に発生した例外はログに記録しますが、全体のシャットダウンプロセスは続行します。
    private def safely_shutdown_component(component, name : String)
      # コンポーネントがnilでないか、かつshutdownメソッドに応答するかを確認
      if component && component.responds_to?(:shutdown)
        Log.debug { "#{name} のシャットダウン処理を開始します..." }
        begin
          # shutdownメソッドを呼び出し
          component.shutdown
          Log.info { "#{name} のシャットダウン処理が正常に完了しました。" }
        rescue ex : Exception
          # シャットダウン中にエラーが発生した場合
          Log.error(exception: ex) { "#{name} のシャットダウン中にエラーが発生しました。" }
          # エラーが発生しても、他のコンポーネントのシャットダウンは続行します。
        end
      else
        # shutdownメソッドが存在しない、またはコンポーネントがnilの場合
        Log.debug { "#{name} にはシャットダウン処理が存在しないか、初期化されていません。スキップします。" }
      end
    end

    # 指定された外部言語バインディングモジュールに対して、安全にシャットダウン処理を試みます。
    # モジュールが `shutdown` クラスメソッドを持っている場合のみ呼び出し、
    # 処理中に発生した例外はログに記録しますが、全体のシャットダウンプロセスは続行します。
    private def safely_shutdown_binding(binding_module, name : String)
      # モジュールがshutdownクラスメソッドに応答するかを確認
      if binding_module.responds_to?(:shutdown)
        Log.debug { "#{name} バインディングのシャットダウン処理を開始します..." }
        begin
          # shutdownクラスメソッドを呼び出し
          binding_module.shutdown
          Log.info { "#{name} バインディングのシャットダウン処理が正常に完了しました。" }
        rescue ex : Exception
          # シャットダウン中にエラーが発生した場合
          Log.error(exception: ex) { "#{name} バインディングのシャットダウン中にエラーが発生しました。" }
        end
      else
        # shutdownクラスメソッドが存在しない場合
        Log.debug { "#{name} バインディングにはシャットダウン処理が存在しません。スキップします。" }
      end
    end

    # 回復不能なエラー（クラッシュ）が発生した場合に、その情報を記録し、
    # 可能であればユーザーに通知するためのメソッドです。
    # クラッシュレポートの生成や、エラーダイアログの表示を試みます。
    private def report_crash(exception : Exception)
      # まず、詳細なエラー情報をログに出力します。
      Log.error(exception: exception) { "回復不能なエラー（クラッシュ）が発生しました。" }

      # テスト実行中は、通常クラッシュレポートの生成やUI表示は行いません。
      if ENV["TESTING"]? == "true"
        Log.warn { "テスト環境下のため、クラッシュレポートの生成とUI通知はスキップされます。" }
        return
      end

      # クラッシュレポート生成の試行
      report_path : String? = nil
      begin
        # CrashReporterクラスが存在し、適切に実装されていることを前提とします。
        # CrashReporterは設定情報、バージョン、アプリ名を使ってレポートを生成します。
        crash_reporter = Core::Util::CrashReporter.new(@config, VERSION, APP_NAME)
        report_path = crash_reporter.generate_report(exception)
        if report_path
          Log.info { "クラッシュレポートを生成しました: #{report_path}" }
        else
          Log.warn { "クラッシュレポートの生成に失敗しました（CrashReporterがnilを返しました）。" }
        end
      rescue reporter_ex : Exception
        # クラッシュレポートの生成自体でエラーが発生した場合。
        Log.error(exception: reporter_ex) { "クラッシュレポートの生成中に予期せぬエラーが発生しました。" }
        STDERR.puts "致命的エラー: クラッシュレポートの生成に失敗しました。"
      end

      # ユーザーへの通知（GUI環境の場合）
      begin
        # WindowManagerが初期化済みで、ダイアログ表示機能を持っているか確認します。
        if @window_manager && @window_manager.responds_to?(:can_show_dialog?) && @window_manager.can_show_dialog?
          # エラーメッセージを組み立てます。
          error_message = exception.message || "原因不明の致命的なエラーが発生しました。"
          detailed_message = "アプリケーションは予期せず終了しました。\n" \
                             "詳細な情報はログファイルを確認してください。\n"
          detailed_message += "生成されたクラッシュレポート: #{report_path}" if report_path

          # WindowManagerにエラーダイアログの表示を依頼します。
          @window_manager.show_error_dialog("#{APP_NAME} - クラッシュ報告", error_message, detailed_message)
          Log.info { "ユーザーにクラッシュ情報を通知するダイアログを表示しました。" }
        else
          # GUIが利用できない（CUI環境やWindowManager初期化前など）場合は、標準エラー出力にメッセージを表示します。
          Log.warn { "GUIダイアログを表示できません。標準エラー出力にメッセージを出力します。" }
          STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
          STDERR.puts "!! #{APP_NAME} は予期せず終了しました"
          STDERR.puts "!! エラー: #{exception.message}"
          STDERR.puts "!! 詳細な情報はログファイルを確認してください。"
          STDERR.puts "!! #{report_path ? "クラッシュレポート: " + report_path : ""}"
          STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        end
      rescue dialog_ex : Exception
        # エラーダイアログの表示中にさらにエラーが発生した場合。
        Log.error(exception: dialog_ex) { "クラッシュ通知ダイアログの表示中にさらにエラーが発生しました。" }
        STDERR.puts "致命的エラー: クラッシュ通知の表示に失敗しました。"
      end
    end

  end # class Application

  # --- アプリケーション エントリーポイント ---

  # アプリケーションを起動するためのメインメソッド（クラスメソッド）。
  # このメソッドが呼び出されると、ロギングシステムが設定され、
  # `Application`クラスのインスタンスが生成・初期化され、`run`メソッドが呼び出されて
  # アプリケーションの実行が開始されます。
  # トップレベルでの例外処理もここで行い、予期せぬクラッシュ時にもログ記録や
  # クラッシュレポートの試行ができるようにします。
  def self.start
    # アプリケーションインスタンスを保持する変数（スコープを広げるため）
    app : Application? = nil
    config : Config? = nil # configure_logging で使うため

    begin
      # 1. 設定オブジェクトを早期に初期化（ログ設定で使用するため）
      # ここでのエラーは configure_logging 前なので限定的なログになる
      begin
        temp_config = Config.new
        temp_config.load_defaults rescue nil # エラーは無視して進む
        temp_config.load_user_preferences rescue nil # エラーは無視して進む
        config = temp_config
      rescue ex
        STDERR.puts "警告: 設定の初期読み込みに失敗しました。デフォルトのログ設定を使用します。エラー: #{ex.message}"
      end

      # 2. ロギングシステムを設定します。
      # 設定ファイルや環境変数に基づいて、ログレベルや出力先（コンソール、ファイル）を決定します。
      # この処理は Application インスタンス生成前に行う必要があります。
      configure_logging(config) # 設定オブジェクトを渡す

      Log.info { "--- #{APP_NAME} v#{VERSION} を起動しています ---" }

      # 3. メインのアプリケーションインスタンスを作成し、初期化します。
      # `Application.new`内で、設定の再読み込みや全コンポーネントの初期化が行われます。
      app = Application.new

      # 4. アプリケーションの実行を開始します。
      # `app.run`メソッドは、イベントループを開始し、アプリケーションが終了するまで制御を返しません。
      app.run

      # 5. 正常終了時の処理。
      # `app.run`が正常に終了した場合（通常は`shutdown`が内部で呼ばれた後）、ここに到達します。
      Log.info { "--- #{APP_NAME} は正常に終了しました ---" }
      exit(0) # 正常終了コード 0 でプロセスを終了します。

    rescue ex : Exception
      # `Application.new`の呼び出し中、または`app.run`の初期段階（イベントループ開始前）、
      # あるいはイベントループ終了後から`exit(0)`までの間に発生した、
      # 捕捉されなかった致命的な例外をここで捕捉します。
      # (イベントループ内の例外は`run_event_loop`内で処理され、`report_crash`が呼ばれる想定です)
      Log.fatal(exception: ex) { "アプリケーションの実行中に捕捉されなかった致命的なエラーが発生しました。" }

      # アプリケーションインスタンスが生成されていれば、それを使ってクラッシュレポートを試みます。
      # `app.new`で失敗した場合は`app`は`nil`のままです。
      if current_app = app
        begin
          current_app.report_crash(ex)
        rescue report_ex : Exception
          Log.error(exception: report_ex) { "トップレベル例外ハンドラでのクラッシュレポート試行中にさらにエラーが発生しました。" }
          STDERR.puts "致命的エラー: クラッシュレポートの生成/通知に失敗しました。"
        end
      else
        # Applicationインスタンスがない場合、限定的な情報のみ出力
        STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        STDERR.puts "!! #{APP_NAME} は初期化中に致命的なエラーで終了しました"
        STDERR.puts "!! エラー: #{ex.message}"
        STDERR.puts "!! 詳細な情報はログファイル（設定されていれば）を確認してください。"
        STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        # ここで基本的なクラッシュ情報（スタックトレースなど）をファイルに書き出す処理を追加することも検討できます。
      end

      # エラーコードでプロセスを終了します。
      exit(1) # 異常終了を示すコード 1 で終了します。
    end
  end

  # ロギングシステムを設定します。
  # 設定オブジェクト (`Config`) や環境変数に基づいて、ログレベルや出力先を決定します。
  # `Application`インスタンス生成前に呼び出す必要があるため、クラスメソッドとして定義します。
  private def self.configure_logging(config : Config?)
    # --- ログレベルの決定 ---
    default_level = Log::Severity::Info # デフォルトはINFOレベル
    log_level_str = "INFO" # デフォルト文字列

    # 1. 設定ファイルからログレベルを読み取る試み
    if cfg = config
      log_level_str = cfg.get_string("logging.level", default: log_level_str)
    end
    # 2. 環境変数 `LOG_LEVEL` があれば、設定ファイルの値より優先する
    log_level_str = ENV["LOG_LEVEL"]? || log_level_str

    # 文字列から Log::Severity に変換
    begin
      final_level = Log::Severity.parse(log_level_str.upcase)
    rescue ex : ArgumentError
      STDERR.puts "警告: 無効なログレベル '#{log_level_str}' が指定されました。デフォルトの #{default_level} レベルを使用します。"
      final_level = default_level
    end

    # --- ログ出力先の決定 ---
    log_backend : Log::Backend = Log::IOBackend.new(STDOUT) # デフォルトは標準出力
    log_target_info = "標準出力"

    # 設定ファイルからログファイルパスを読み取る試み
    if cfg = config
      log_file_path = cfg.get_string("logging.file_path", default: "")
      unless log_file_path.empty?
        begin
          # ファイルを開く（追記モード "a"）
          log_file = File.open(log_file_path, "a")
          # ファイルへのIOBackendを作成
          log_backend = Log::IOBackend.new(log_file)
          log_target_info = "ファイル (#{log_file_path})"
        rescue ex : Exception
          STDERR.puts "警告: ログファイル '#{log_file_path}' を開けませんでした。標準出力にフォールバックします。エラー: #{ex.message}"
          # エラーが発生したら標準出力のままにする
        end
      end
    end

    # --- Log モジュールの設定 ---
    Log.setup do |settings|
      # デフォルトのバインディング（全てのログソース）を設定
      settings.bind("*", final_level, log_backend)

      # 特定のモジュールに対して異なるレベルを設定することも可能
      # 例: ネットワーク関連のログをデバッグレベルで出力したい場合
      # network_debug_level = cfg.try &.get_string("logging.levels.network", default: "")
      # unless network_debug_level.empty?
      #   begin
      #     net_level = Log::Severity.parse(network_debug_level.upcase)
      #     settings.bind("Browser::Bindings::Nim::NetworkBinding", net_level, log_backend)
      #     settings.bind("Browser::Events::Handlers::NetworkEventHandler", net_level, log_backend)
      #   rescue ArgumentError
      #      Log.warn { "設定内のネットワークログレベル '#{network_debug_level}' は無効です。" }
      #   end
      # end

      # 開発モードやデバッグフラグが有効な場合に、強制的にデバッグレベルにする
      is_debug_mode = ENV["DEBUG"]? == "true" || ENV["CRYSTAL_ENV"]? == "development"
      if is_debug_mode && final_level > Log::Severity::Debug
        settings.bind("*", Log::Severity::Debug, log_backend)
        # ログ設定完了前にLogを使うと設定が反映されないため、ここではSTDERRを使うか、
        # ログ設定完了後にLog.infoでメッセージを出す
        # Log.info { "デバッグモードが有効です。ログレベルを DEBUG に設定しました。" }
      end
    end

    # ログ設定が完了したことを（設定されたログシステムを使って）記録
    Log.info { "ロギングシステムが初期化されました。レベル: #{final_level}, 出力先: #{log_target_info}" }
    # デバッグモード有効時のメッセージ
    if ENV["DEBUG"]? == "true" || ENV["CRYSTAL_ENV"]? == "development"
       Log.info { "デバッグモードまたは開発環境が有効です。詳細なログが出力される可能性があります。" }
    end

  rescue ex : Exception
    # ロギング設定自体でエラーが発生した場合の最終手段
    STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    STDERR.puts "!! 致命的エラー: ロギングシステムの初期化に失敗しました。"
    STDERR.puts "!! エラー: #{ex.message}"
    STDERR.puts "!! スタックトレース:"
    STDERR.puts ex.inspect_with_backtrace
    STDERR.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    # このエラーは非常に深刻なので、アプリケーションを続行しない方が良い場合がある
    exit(1)
  end

end # module Browser

# ==============================================================================
# スクリプト実行ガード
# ==============================================================================
# このファイルが直接 `crystal run src/crystal/browser/app/main.cr` のように実行された場合にのみ、
# `Browser.start` を呼び出してアプリケーションを起動します。
# `require` によって他のファイルから読み込まれた場合や、
# テスト環境（環境変数 `TESTING=true` が設定されている場合）では起動しません。
# これにより、テスト実行時に意図せずアプリケーションが起動してしまうのを防ぎます。
# ------------------------------------------------------------------------------
if __FILE__ == $0 && ENV["TESTING"]? != "true"
  Browser.start
end