require "./quantum_core/**"
require "./quantum_ui/**"

module QuantumBrowser
  VERSION = "0.1.0"

  # ブラウザエンジンの起動ポイント
  class Engine
    getter core : QuantumCore::Engine
    getter ui : QuantumUI::Manager
    getter network : QuantumNetwork::Manager
    getter storage : QuantumStorage::Manager
    
    def initialize(config_path : String? = nil)
      # 設定の読み込み
      config = if config_path
        QuantumCore::Config.from_file(config_path)
      else
        QuantumCore::Config.default
      end
      
      # 各コンポーネントの初期化
      @storage = QuantumStorage::Manager.new(config.storage)
      @network = QuantumNetwork::Manager.new(config.network, @storage)
      @core = QuantumCore::Engine.new(config.core, @network, @storage)
      @ui = QuantumUI::Manager.new(config.ui, @core)
      
      # パフォーマンスモニターの初期化
      @performance_monitor = QuantumCore::PerformanceMonitor.new(@core, @ui, @network, @storage)
      
      # シグナルハンドラの設定
      setup_signal_handlers
    end
    
    def start
      # コンポーネントの起動
      @storage.start
      @network.start
      @core.start
      @ui.start
      
      # パフォーマンスモニターの開始
      @performance_monitor.start
      
      # メインループの開始
      @ui.main_loop
    end
    
    def shutdown
      # 正常終了の処理
      @ui.shutdown
      @core.shutdown
      @network.shutdown
      @storage.shutdown
      @performance_monitor.shutdown
    end
    
    private def setup_signal_handlers
      # Ctrl+C などのシグナル処理
      Signal::INT.trap do
        puts "QuantumBrowser: シャットダウンしています..."
        shutdown
        exit(0)
      end
      
      Signal::TERM.trap do
        puts "QuantumBrowser: 強制終了シグナルを受信しました。シャットダウンしています..."
        shutdown
        exit(0)
      end
    end
  end
end

# コマンドライン引数の処理
if ARGV.size > 0 && (ARGV[0] == "-h" || ARGV[0] == "--help")
  puts "QuantumBrowser v#{QuantumBrowser::VERSION}"
  puts "使用方法: quantum_browser [オプション] [URL]"
  puts "オプション:"
  puts "  -c, --config CONFIG_PATH  設定ファイルのパスを指定"
  puts "  -h, --help                このヘルプメッセージを表示"
  puts "  -v, --version             バージョン情報を表示"
  exit(0)
elsif ARGV.size > 0 && (ARGV[0] == "-v" || ARGV[0] == "--version")
  puts "QuantumBrowser v#{QuantumBrowser::VERSION}"
  exit(0)
end

# 設定ファイルのパスを取得
config_path = nil
initial_url = nil

i = 0
while i < ARGV.size
  arg = ARGV[i]
  
  case arg
  when "-c", "--config"
    if i + 1 < ARGV.size
      config_path = ARGV[i + 1]
      i += 1
    else
      STDERR.puts "エラー: --config オプションには引数が必要です"
      exit(1)
    end
  else
    # URLと認識
    initial_url = arg if initial_url.nil? && !arg.starts_with?("-")
  end
  
  i += 1
end

# エンジンの初期化と起動
engine = QuantumBrowser::Engine.new(config_path)

# 初期URLが指定されていれば読み込む
engine.core.load_url(initial_url) if initial_url

# ブラウザの起動
engine.start 