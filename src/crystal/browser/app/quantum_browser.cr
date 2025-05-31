# --- 依存ライブラリの読み込み ---
# アプリケーションの動作に不可欠なライブラリ群を読み込みます。

# アプリケーションの中核機能（設定管理、パフォーマンス監視、ライフサイクル管理など）
require "./quantum_core/**"
# ユーザーインターフェース関連（ウィンドウ、ウィジェット、イベント処理など）
require "./quantum_ui/**"
# ネットワーク通信機能（主にNimで実装され、FFI/IPC経由で連携するラッパー等を読み込む想定）
require "./quantum_network/**" # 注意: Crystal側のラッパー実装が存在する場合に必要
# HTTP/3ネットワーク機能
require "../network/network_factory"
require "../network/http3_network_manager"
require "../network/http3_client"
require "../network/http3_performance_monitor"
# データ永続化機能（ブックマーク、履歴、設定などの保存・読み込み）
require "./quantum_storage/**" # 注意: Crystal側でストレージアクセスを実装する場合に必要

# コマンドライン引数の解析機能
require "option_parser"
# 標準的なログ出力機能
require "log"
# ファイルシステム操作（ファイル）
require "file"
# ファイルシステム操作（ディレクトリ）
require "dir"
# 設定ファイル（YAML形式）の解析機能
require "yaml"

# --- モジュール拡張 ---
# 既存のコアモジュールやUIモジュールに必要な機能を追加します。
# 注意: これらの拡張は、本来は各モジュールの定義ファイルで行うべきですが、
#       開発初期段階や特定の機能集約のために一時的にここに記述する場合があります。
#       最終的には適切なファイルへの移動を検討してください。

module QuantumCore
  # --- 設定クラス (QuantumCore::Config) の拡張 ---
  # アプリケーション全体の設定項目を管理するクラスに、
  # ブラウザ固有の設定や、他のモジュールとの連携に必要な設定を追加します。
  class Config
    # ログファイルのパスを取得します。
    # ユーザーデータディレクトリ配下の `logs` ディレクトリに配置することを想定しています。
    # パスが決定できない場合は nil を返します。
    #
    # 例:
    #   Linux:   ~/.local/share/QuantumBrowser/logs/quantum_browser.log
    #   macOS:   ~/Library/Application Support/QuantumBrowser/logs/quantum_browser.log
    #   Windows: %APPDATA%\QuantumBrowser\logs\quantum_browser.log
    #
    # Returns:
    #   ログファイルのフルパス (String) または nil
    def log_file_path : String?
      base_dir = default_user_data_dir
      return nil unless base_dir

      log_dir = File.join(base_dir, "logs")
      File.join(log_dir, "#{QuantumBrowser::APP_NAME.downcase}.log")
    rescue ex : ArgumentError
      # File.join で不正なパス文字などが含まれた場合
      Log.error(exception: ex) { "[Config] ログファイルパスの生成に失敗しました。" }
      nil
    end

    # ブラウザ起動時に最初に表示するホームページのURLを取得します。
    #
    # @return [String?] ホームページのURL または nil (未設定時)
    def homepage_url? : String?
      # プロパティ homepage を参照し、空文字列の場合は nil を返却
      if homepage && !homepage.empty?
        homepage
      else
        nil
      end
    end

    # アプリケーションのユーザーデータ（プロファイル、設定、キャッシュ等）を
    # 保存するためのデフォルトディレクトリパスを取得します。
    # 各プラットフォームの標準的な慣習に従います。
    #
    # Returns:
    #   ユーザーデータディレクトリのパス (String) または nil (取得失敗時)
    def default_user_data_dir : String?
      app_name = QuantumBrowser::APP_NAME
      base_path = find_platform_data_dir

      unless base_path
        Log.error { "[Config] プラットフォーム固有のデータディレクトリを特定できませんでした。環境変数を確認してください。" }
        return nil
      end

      # アプリケーション固有のディレクトリパスを構築
      begin
        File.join(base_path, app_name)
      rescue ex : ArgumentError
        Log.error(exception: ex) { "[Config] ユーザーデータディレクトリパスの生成に失敗しました。ベースパス: #{base_path}, アプリ名: #{app_name}" }
        nil
      end
    end

    private def find_platform_data_dir : String?
      if OS.linux?
        # XDG Base Directory Specification に従う
        # 1. $XDG_DATA_HOME を確認
        xdg_data_home = ENV["XDG_DATA_HOME"]?
        return xdg_data_home if xdg_data_home && !xdg_data_home.empty?

        # 2. $XDG_DATA_HOME が未設定なら $HOME/.local/share を使用
        home = ENV["HOME"]?
        return File.join(home, ".local", "share") if home && !home.empty?
      elsif OS.mac_os_x?
        # macOS の標準的な場所
        home = ENV["HOME"]?
        return File.join(home, "Library", "Application Support") if home && !home.empty?
      elsif OS.windows?
        # Windows の標準的な場所 (%APPDATA%)
        app_data = ENV["APPDATA"]?
        return app_data if app_data && !app_data.empty?
      else
        Log.warn { "[Config] 未対応のオペレーティングシステムです: #{OS.family}" }
      end

      # 上記いずれにも該当しない、または必要な環境変数が設定されていない場合
      nil
    end

    # 注意: 以下のメソッドは QuantumCore::Config の本体で定義されるべきものです。
    #       ここでは、他の拡張メソッドとの関連を示すためにコメントとして残しています。
    #
    # # 設定ファイルから設定を読み込むクラスメソッド
    # def self.from_file(path : String) : self
    #   # ... YAML.parse などを使ってファイルから読み込む ...
    # end
    #
    # # デフォルト設定を生成するクラスメソッド
    # def self.default : self
    #   # ... デフォルト値を設定したインスタンスを返す ...
    # end
    #
    # # デフォルトの設定ファイルパスを返すクラスメソッド
    # def self.default_path : String?
    #   # ... default_user_data_dir を使ってパスを決定 ...
    # end
  end
end

module QuantumCore
  # --- コアエンジン (QuantumCore::Engine) の拡張 ---
  # ブラウザの主要な動作（ページの読み込み、レンダリング指示など）を担うクラスに、
  # UI層からの要求に応えるためのメソッドを追加します。
  class Engine
    # 新しいタブやウィンドウで表示するための空白ページを読み込みます。
    # 一般的には "about:blank" が使用されます。
    def load_blank_page
      Log.debug { "[Core] 空白ページの読み込みを開始します。" }
      # 内部的にレンダリングエンジンに対して "about:blank" の読み込みを指示します。
      # 実際のレンダリングプロセスとの連携は、このメソッドの下位層で行われます。
      load_url("about:blank")
    end

    # 指定されたURLを現在のタブ（または指定されたターゲット）で読み込みます。
    # このメソッドは QuantumCore::Engine の本体に既に存在することを想定しています。
    # def load_url(url : String)
    #   Log.info { "[Core] URLの読み込みを開始します: #{url}" }
    #   # ... レンダリングエンジンへの指示、ネットワークリクエストの開始など ...
    # end
  end
end

module QuantumUI
  # --- UIマネージャ (QuantumUI::Manager) の拡張 ---
  # UI全体の管理（ウィンドウ、タブ、ダイアログなど）を行うクラスに、
  # アプリケーションの状態変化（特にエラー）をユーザーに通知する機能を追加します。
  class Manager
    # エラーメッセージをユーザーインターフェース上に表示します。
    # 具体的な表示方法はUIツールキット（例: GTK, Qt）に依存します。
    #
    # Args:
    #   message: 表示するエラーメッセージの文字列。
    def show_error_message(message : String)
      Log.error { "[UI] エラーメッセージを表示します: #{message}" }
      # ここで、使用しているUIツールキットのAPIを呼び出して、
      # エラーダイアログや通知を表示する処理を実装します。
      # 例 (GTKの場合):
      #   dialog = Gtk::MessageDialog.new(
      #     parent: @main_window, # 親ウィンドウがあれば指定
      #     flags: Gtk::DialogFlags::Modal | Gtk::DialogFlags::DestroyWithParent,
      #     type: Gtk::MessageType::Error,
      #     buttons: Gtk::ButtonsType::Ok,
      #     message_format: "エラーが発生しました" # メインメッセージ
      #   )
      #   dialog.secondary_text = message # 詳細メッセージ
      #   dialog.run
      #   dialog.destroy
      #
      # 実際のUI実装に合わせて上記のようなコードを追加してください。
      # 現時点ではログ出力のみ行います。
    end
  end
end

# --- QuantumBrowser: メイン実行モジュールとエントリーポイント ---
# QuantumBrowser モジュール: アプリケーション全体のエントリーポイントおよびライフサイクル管理を行う。
module QuantumBrowser
  # バージョン情報
  VERSION = "0.1.0"
  APP_NAME = "QuantumBrowser"
  BUILD_INFO = ENV["QUANTUM_BUILD_INFO"]? || "不明"

  # メインアプリケーションクラス
  class Application
    # クラス内の属性とゲッターセッター
    property engine : QuantumCore::Engine
    property ui_manager : QuantumUI::Manager
    property config : QuantumCore::Config
    property network_factory : QuantumBrowser::NetworkFactory? = nil

    # アプリケーションをセットアップして実行する
    # @param initial_url [String?] 初期URLがあれば指定
    def initialize(config_path : String? = nil, initial_url : String? = nil)
      # 設定ファイルの読み込み
      @config = config_path ? load_config(config_path) : QuantumCore::Config.default
      
      # コンポーネントの初期化
      @engine = initialize_engine
      @ui_manager = initialize_ui
      
      # ネットワークファクトリーの初期化
      initialize_network
      
      # 初期ページの読み込み
      load_initial_page(initial_url)
    end

    # ネットワークシステムを初期化
    private def initialize_network
      # ネットワークファクトリーの作成と初期化
      @network_factory = NetworkFactory.new(@config.network)
      @network_factory.try &.initialize_factory
      
      # HTTP/3サポートのログ出力
      if factory = @network_factory
        protocol_support = factory.get_protocol_support
        Log.info { "HTTP/3サポート: #{protocol_support.http3_enabled} (利用可能: #{protocol_support.http3_available})" }
        
        # HTTP/3が利用可能な場合はパフォーマンスモニターを開始
        if protocol_support.http3_available
          if monitor = factory.get_http3_performance_monitor
            monitor.start_monitoring
            monitor.start_battery_monitoring
            Log.info { "HTTP/3パフォーマンスモニターを開始しました" }
          end
        end
      end
    end

    # エンジンの初期化
    # Core Engine を初期化して返します
    private def initialize_engine
      Log.debug { "[App] Quantum Core Engineの初期化を開始します" }
      engine = QuantumCore::Engine.new(@config)
      Log.info { "[App] Quantum Core Engine初期化完了" }
      engine
    end

    # UIの初期化
    # UI Manager を初期化して返します
    private def initialize_ui
      Log.debug { "[App] Quantum UI Managerの初期化を開始します" }
      ui_manager = QuantumUI::Manager.new(@config, @engine)
      Log.info { "[App] Quantum UI Manager初期化完了" }
      ui_manager
    end

    # 初期ページを読み込む
    # @param initial_url [String?] コマンドラインから渡された初期URL
    private def load_initial_page(initial_url : String?)
      url_to_load = initial_url || @config.homepage_url? || "about:blank"
      
      # HTTP/3プリコネクションの実施
      if url = URI.parse(url_to_load) rescue nil
        if url.host && (url.scheme == "http" || url.scheme == "https")
          if factory = @network_factory
            factory.preconnect_http3(url.host, url.port || (url.scheme == "https" ? 443 : 80))
          end
        end
      end
      
      @engine.load_url(url_to_load)
      Log.info { "[App] 初期ページの読み込みを開始しました: #{url_to_load}" }
    end

    # 設定ファイルを読み込む
    # @param config_path [String] 設定ファイルのパス
    # @raise [QuantumCore::ConfigError] 設定ファイルの読み込みに失敗した場合
    private def load_config(config_path : String) : QuantumCore::Config
      begin
        Log.debug { "[App] 設定ファイルを読み込みます: #{config_path}" }
        config = QuantumCore::Config.from_file(config_path)
        Log.debug { "[App] 設定ファイルの読み込みが完了しました" }
        config
      rescue ex : QuantumCore::ConfigError
        Log.error(exception: ex) { "[App] 設定ファイルの読み込みに失敗しました: #{config_path}" }
        raise ex
      end
    end

    # アプリケーションのメインループを実行
    def run
      begin
        ui_main_loop
      rescue ex : Exception
        handle_fatal_error(ex)
      ensure
        cleanup
      end
    end

    # UIメインループ（UIフレームワークに依存）
    private def ui_main_loop
      Log.info { "[App] メインループを開始します" }
      @ui_manager.run_main_loop
      Log.info { "[App] メインループが終了しました" }
    end

    # 致命的エラーの処理
    private def handle_fatal_error(ex : Exception)
      Log.fatal(exception: ex) { "[App] 致命的なエラーが発生しました" }
      error_message = "致命的なエラー: #{ex.message}"
      
      # UIが初期化されていればエラーダイアログを表示
      begin
        @ui_manager.try &.show_error_message(error_message)
      rescue ui_ex : Exception
        # UIでのエラー表示自体が失敗した場合は標準エラー出力に表示
        STDERR.puts error_message
        STDERR.puts ex.backtrace.join("\n") if ex.backtrace.is_a?(Array)
      end
    end

    # 終了時のクリーンアップ処理
    private def cleanup
      Log.info { "[App] クリーンアップを開始します" }
      
      # HTTP/3関連リソースのクリーンアップ
      @network_factory.try &.shutdown
      
      # その他のリソース解放やプロセス終了処理
      @engine.try &.shutdown
      @ui_manager.try &.shutdown
      
      Log.info { "[App] クリーンアップが完了しました" }
    end
  end

  # メインエンジンを初期化し、引数解析、設定読み込み、起動シーケンスを実施する。
  # @param args [Array(String)] コマンドライン引数 (通常は ARGV)
  # @raise [QuantumCore::ConfigError, QuantumCore::InitializationError] 初期化失敗時
  def self.run(args : Array(String))
    config_path : String? = nil
    initial_url : String? = nil
    show_help = false
    show_version = false
    log_level : Log::Severity? = nil

    # --- コマンドライン引数の解析 ---
    # Crystal標準のOptionParserを使って、引数を安全に処理します。
    # 手作業でパースするよりずっと楽で、間違いも少ないです。
    parser = OptionParser.new do |opts|
      opts.banner = "使い方: #{APP_NAME.downcase} [オプション] [URL]"
      opts.separator("")
      opts.separator("#{APP_NAME} v#{VERSION} - Crystal/Nim/Zig ハイブリッドウェブブラウザ")
      opts.separator("新しい技術で、速くて安全なブラウジング体験を。")
      opts.separator("")
      opts.separator("オプション:")

      # 設定ファイルパスを指定するオプション (-c または --config)
      opts.on("-c PATH", "--config PATH", "使用する設定ファイルのパスを指定します。") do |path|
        config_path = path
      end

      # ログレベルを指定するオプション (--log-level)
      opts.on("--log-level LEVEL", "ログの詳細度を指定します (debug, info, warn, error, fatal)。") do |level_str|
        begin
          log_level = Log::Severity.parse(level_str.downcase)
        rescue ex : ArgumentError
          STDERR.puts "エラー: 無効なログレベルです: #{level_str}"
          STDERR.puts "指定可能なレベル: debug, info, warn, error, fatal"
          exit(1)
        end
      end

      # ヘルプメッセージを表示するオプション (-h または --help)
      opts.on("-h", "--help", "このヘルプメッセージを表示して終了します。") do
        show_help = true
      end

      # バージョン情報を表示するオプション (-v または --version)
      opts.on("-v", "--version", "バージョン情報を表示して終了します。") do
        show_version = true
      end

      # 他の便利なオプションを追加するならここに。
      # 例:
      # opts.on("--private", "プライベートブラウジングモードで起動します。") { |p| options[:private] = p }
      # opts.on("--profile NAME", "指定したユーザープロファイルで起動します。") { |n| options[:profile] = n }

      # 不明なオプションが指定されたときの処理
      opts.on_invalid_option do |option|
        STDERR.puts "エラー: 不明なオプションです: #{option}"
        STDERR.puts opts # ヘルプメッセージを表示して使い方を示す
        exit(1)
      end
    end

    # OptionParser 例外強化: 不正オプション/引数に備える
    begin
      remaining_args = parser.parse(args)
    rescue OptionParser::InvalidOption, OptionParser::MissingArgument => ex
      STDERR.puts "エラー: #{ex.message}"
      STDERR.puts parser
      exit(1)
    end

    # --- ヘルプ/バージョン表示の処理 ---
    if show_help
      puts parser # OptionParserが生成したヘルプメッセージを出力
      exit(0)
    end

    if show_version
      puts "#{APP_NAME} バージョン #{VERSION}"
      # ビルド情報（Gitコミットハッシュ、ビルド日時など）も表示
      # コンパイル時に `-D quantum_build_info="<info>"` のようにして埋め込むか、
      # 環境変数 `QUANTUM_BUILD_INFO` を設定します。
      puts "ビルド情報: #{BUILD_INFO}"
      exit(0)
    end

    # --- ログレベルの適用 ---
    # コマンドラインで指定されていれば、環境変数やデフォルトより優先します。
    if level = log_level
      # Log.dexter.level だと全てのバックエンドに影響するので注意。
      # ここではデフォルトのSTDERRバックエンドのレベルを変更する想定。
      # もし複数のバックエンドがあれば、それぞれ設定が必要。
      Log.dexter.reset # 一旦リセットして再設定する方が確実かも
      Log.dexter.configure(level, backend: Log::IOBackend.new(STDERR))
      # ファイルログも設定するなら、ここか設定読み込み後に行う
      Log.info { "[Main] コマンドライン引数により、ログレベルを #{level.to_s.upcase} に設定しました。" }
    end

    # --- 初期URLの特定 ---
    # オプション以外の最初の引数を、起動時に開くURLまたはファイルパスとみなします。
    if remaining_args.any?
      potential_url_or_path = remaining_args.first
      # 簡単なチェック: URLっぽいか (:// を含む)、またはローカルファイルとして存在するか
      is_url_like = potential_url_or_path.includes?("://")
      # File.exists? はシンボリックリンクを辿らないので注意。必要なら File.info を使う。
      is_local_file = !is_url_like && File.exists?(potential_url_or_path)

      # '-' で始まらない、かつ URLっぽいかファイルとして存在するなら採用
      if !potential_url_or_path.starts_with?('-') && (is_url_like || is_local_file)
        initial_url = potential_url_or_path
        # もしファイルパスなら、絶対パスに変換しておくと後々扱いやすい
        initial_url = File.expand_path(initial_url) if is_local_file && !initial_url.starts_with?('/') && !initial_url.starts_with?("file://")

        if remaining_args.size > 1
          Log.warn { "[Main] URL/ファイルが複数指定されましたが、最初の '#{initial_url}' のみを開きます。" }
        end
      else
        Log.warn { "[Main] 引数 '#{potential_url_or_path}' はURLまたはローカルファイルとして認識できませんでした。" }
      end
    end

    # --- 設定の読み込み ---
    # `load_config` ヘルパーを使って設定を読み込みます。
    # 失敗したらエラーメッセージを出して終了します。
    config = begin
      load_config(config_path)
    rescue ex : QuantumCore::ConfigError
      Log.fatal(exception: ex) { "[Main] 設定の読み込みに失敗しました！" }
      STDERR.puts "致命的エラー: 設定ファイルの読み込みに失敗しました。"
      STDERR.puts "詳細: #{ex.message}"
      # 原因となったエラーも表示するとデバッグしやすい
      if cause = ex.cause
        STDERR.puts "根本原因: #{cause.class}: #{cause.message}"
      end
      exit(1)
    end

    # --- ファイルロガーの設定 (設定読み込み後) ---
    # コマンドラインでログレベルが指定されていても、ファイルログは設定ファイルに従う。
    # (必要ならコマンドライン引数を setup_file_logging に渡すように変更)
    setup_file_logging(config)

    # --- エンジンの初期化 ---
    # 読み込んだ設定を使って、ブラウザエンジンを準備します。
    # これも失敗したらエラーメッセージを出して終了します。
    engine = begin
      Engine.new(config)
    rescue ex : QuantumCore::InitializationError
      Log.fatal(exception: ex) { "[Main] ブラウザエンジンの初期化に失敗しました！" }
      STDERR.puts "致命的エラー: ブラウザエンジンの初期化に失敗しました。"
      STDERR.puts "詳細: #{ex.message}"
      if cause = ex.cause
        STDERR.puts "根本原因: #{cause.class}: #{cause.message}"
        # 必要ならスタックトレースも表示
        # STDERR.puts cause.backtrace.join("\n") if cause.backtrace?
      end
      exit(1)
    end

    # --- 初期URLの読み込み ---
    # コマンドライン引数でURLが指定されていたら、それを開きます。
    if url = initial_url
      Log.info { "[Main] 初期URL/ファイル '#{url}' を読み込みます。" }
      begin
        # Core APIの `load_url` を呼び出し。
        # この処理は非同期かもしれないので注意（UIが表示される前に完了しないかも）。
        # UI が準備完了してからロードをトリガーする方が良い場合もある。
        # ここでは同期的にリクエストを投げると仮定。
        engine.core.load_url(url)
        Log.debug { "[Main] 初期URL/ファイル '#{url}' の読み込みリクエストを送信しました。" }
      rescue ex : Exception # 例: 無効なURL、Core内部エラーなど
        # URL読み込みに失敗しても、ブラウザ自体は起動を続けます。
        # エラーはログに残し、UIでユーザーに知らせます。
        error_message = "初期URL/ファイル '#{url}' の読み込み中にエラーが発生しました: #{ex.message}"
        Log.error(exception: ex) { "[Main] #{error_message}" }
        # UIを通じてユーザーにエラーを通知 (UIが利用可能か確認が必要な場合も)
        engine.ui.show_error_message(error_message) rescue nil # UI初期化失敗時を考慮
      end
    else
      # 初期URLが指定されなかった場合。ホームページか、空白ページを開くのが一般的。
      Log.info { "[Main] 初期URLは指定されていません。デフォルトページ（ホームページまたは空白ページ）を表示します。" }
      # 設定からホームページURLを取得 (修正されたメソッドを使用)
      homepage = engine.homepage_url?
      if homepage
        Log.info { "[Main] ホームページ '#{homepage}' を読み込みます。" }
        begin
          engine.core.load_url(homepage)
          Log.debug { "[Main] ホームページ '#{homepage}' の読み込みリクエストを送信しました。" }
        rescue ex : Exception
          error_message = "ホームページ '#{homepage}' の読み込み中にエラーが発生しました: #{ex.message}"
          Log.error(exception: ex) { "[Main] #{error_message}" }
          # ホームページの読み込み失敗時もエラー通知
          engine.ui.show_error_message(error_message) rescue nil
          # フォールバックとして空白ページを開く
          Log.info { "[Main] ホームページの読み込みに失敗したため、空白ページを開きます。" }
          begin
            engine.core.load_blank_page
          rescue ex_blank : Exception
            Log.error(exception: ex_blank) { "[Main] 空白ページの読み込みにも失敗しました。" }
            # ここまで来るとかなり問題だが、UIは起動を試みる
            engine.ui.show_error_message("空白ページの読み込みに失敗: #{ex_blank.message}") rescue nil
          end
        end
      else
        Log.info { "[Main] ホームページが設定されていないため、空白ページを表示します。" }
        begin
          engine.core.load_blank_page
        rescue ex : Exception
          Log.error(exception: ex) { "[Main] 空白ページの読み込み中にエラーが発生しました。" }
          # 空白ページの読み込み失敗時もエラー通知
          engine.ui.show_error_message("空白ページの読み込み中にエラーが発生しました: #{ex.message}") rescue nil
        end
      end
    end

    # --- ブラウザのメイン処理開始 ---
    # エンジンの `start` を呼び出して、ブラウザを起動！
    # この呼び出しは、ユーザーがブラウザを閉じるか、シャットダウンシグナルを受け取るまで
    # 通常は戻ってきません。
    engine.start

    # --- 正常終了 ---
    # `engine.start` が戻ってきたら、シャットダウン処理は完了しています。
    # プログラムは正常に終了したとみなします。
    Log.info { "[Main] #{APP_NAME} アプリケーションが正常に終了しました。" }
    # 正常終了を示す終了コード 0 でプロセスを終了します。
    exit(0)
  end # def self.run

  # --- 設定読み込みヘルパー (プライベートクラスメソッド) ---
  # 指定されたパス、またはデフォルトの場所から設定ファイルを読み込みます。
  # ファイルがない、形式が違うなどのエラーを適切に処理します。
  #
  # 引数:
  #   config_path: ユーザー指定の設定ファイルパス (String?)。nilならデフォルトパスを探します。
  #
  # 戻り値:
  #   QuantumCore::Config: 読み込んだ設定オブジェクト。
  #
  # 例外:
  #   QuantumCore::ConfigError: 設定ファイルの読み込みや解析に失敗した場合。
  private def self.load_config(config_path : String?) : QuantumCore::Config
    # 読み込むべきパスを決定。指定があればそれ、なければデフォルトパス。
    path_to_load = config_path || QuantumCore::Config.default_path

    if path_to_load.nil? && config_path.nil?
      # デフォルトパスも見つからなかった（または未定義だった）場合。
      # 組み込みのデフォルト設定を使用します。
      Log.warn { "[Config] 設定ファイルが見つかりません。デフォルト設定で動作します。" }
      begin
        return QuantumCore::Config.default
      rescue ex : Exception
        Log.error(exception: ex) { "[Config] 組み込みデフォルト設定の取得中にエラーが発生しました。" }
        raise QuantumCore::ConfigError.new("デフォルト設定の取得に失敗しました。", cause: ex)
      end
    elsif path_to_load.nil?
      # パスが指定されたが、それが無効だった場合（例: default_path が nil を返した）。
      # これは `QuantumCore::Config.default_path` の実装によります。
      Log.error { "[Config] 指定された設定パス '#{config_path}' は有効ではありません。" }
      raise QuantumCore::ConfigError.new("無効な設定ファイルパスです: #{config_path}")
    else
      # 有効なパス（指定パス or デフォルトパス）が見つかった場合。
      Log.info { "[Config] 設定ファイル '#{path_to_load}' を読み込みます。" }
      begin
        # `QuantumCore::Config.from_file` がファイルを読み込み、パースします。
        # IOエラーやパースエラー（YAML::ParseExceptionなど）を捕捉します。
        return QuantumCore::Config.from_file(path_to_load)
      rescue ex : IO::NotFoundError
        # ファイルが見つからない場合。警告してデフォルト設定を使う選択肢もありますが、
        # ここではエラーとして扱います（特にユーザーが明示的に指定した場合）。
        Log.error { "[Config] 設定ファイル '#{path_to_load}' が見つかりません。" }
        raise QuantumCore::ConfigError.new("設定ファイルが見つかりません: #{path_to_load}", cause: ex)
      rescue ex : YAML::ParseException # 設定ファイルがYAMLの場合のパースエラー例
        Log.error(exception: ex) { "[Config] 設定ファイル '#{path_to_load}' の解析に失敗しました。フォーマットを確認してください。" }
        raise QuantumCore::ConfigError.new("設定ファイルの解析に失敗しました: #{path_to_load}", cause: ex)
      rescue ex : Exception # その他の予期せぬエラー
        Log.error(exception: ex) { "[Config] 設定ファイル '#{path_to_load}' の読み込み中に予期せぬエラーが発生しました。" }
        raise QuantumCore::ConfigError.new("設定ファイルの読み込みに失敗しました: #{path_to_load}", cause: ex)
      end
    end
  end

  # --- ファイルロガーの設定 (プライベートクラスメソッド) ---
  # ファイルへのログ出力設定を行うメソッド
  private def self.setup_file_logging(config : QuantumCore::Config)
    log_file_path = config.log_file_path
    unless log_file_path
      Log.warn { "[Log] ログファイルパスが設定されていません。ファイルへのログ出力は行われません。" }
      return
    end

    begin
      # ログファイルが置かれるディレクトリを作成 (なければ)
      log_dir = File.dirname(log_file_path)
      Dir.mkdir_p(log_dir) unless Dir.exists?(log_dir)

      # DEBUGレベル以上をファイルに書き出す設定を追加
      # 既存のバックエンド（STDERR）はそのままに、ファイルバックエンドを追加する
      Log.dexter.configure(:debug, backend: Log::FileBackend.new(log_file_path))
      Log.info { "[Log] ログファイル '#{log_file_path}' への出力を開始しました (レベル: DEBUG以上)。" }
    rescue ex : IO::PermissionError
      Log.warn { "[Log] ログファイル '#{log_file_path}' またはディレクトリへの書き込み権限がありません。ファイルへのログ出力は無効になります。" }
    rescue ex : Exception
      Log.warn(exception: ex) { "[Log] ログファイル '#{log_file_path}' の設定中にエラーが発生しました。ファイルへのログ出力は無効になります。" }
    end
  end

  # Signal ハンドリングの設定、UI メインループ内での安全なシャットダウンを保証
  private def self.setup_signal_handlers
    # SIGINT (Interrupt Signal): ユーザーがターミナルで Ctrl+C を押したときなど。
    Signal::INT.trap do
      Log.warn { "[Signal] SIGINT (Ctrl+C) を受信。安全なシャットダウンを開始します..." }
      # シグナルハンドラ内では複雑な処理は避けるべきですが、
      # `shutdown` は冪等なので、ここで直接呼び出しても比較的安全です。
      shutdown
      # ハンドラ処理後、プロセスが正常終了するように exit(0) を呼びます。
      # これがないと、Crystalのデフォルトハンドラが動作することがあります。
      exit(0)
    end

    # SIGTERM (Termination Signal): `kill` コマンド（デフォルト）やシステムシャットダウン時など。
    # プログラムに終了準備の猶予を与える、より丁寧な終了要求です。
    Signal::TERM.trap do
      Log.warn { "[Signal] SIGTERM を受信。シャットダウンを開始します..." }
      shutdown
      # 同様に、正常終了コードで exit します。
      exit(0)
    end

    # 必要であれば他のシグナルハンドラもここに追加できます。
    # 例: SIGHUP で設定ファイルを再読み込みするなど。
    # Signal::HUP.trap do
    #   Log.info { "[Signal] SIGHUP を受信。設定を再読み込みします..." }
    #   # 設定再読み込みは影響範囲が大きい場合、別スレッドで行うのが安全かもしれません。
    #   spawn config.reload
    # end
  end
end

# --- アプリケーションのエントリーポイント ---
# このファイルが `crystal run src/crystal/browser/app/quantum_browser.cr` のように
# 直接実行された場合にのみ、以下のコードが実行されます。
# 他のファイルから `require` されただけでは実行されません。
if __FILE__ == $0
  # コマンドライン引数 (`ARGV`) を渡して、QuantumBrowserのメイン処理を開始します。
  QuantumBrowser.run(ARGV)
end
