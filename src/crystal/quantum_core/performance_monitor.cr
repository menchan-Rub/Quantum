module QuantumCore
  # パフォーマンスモニタークラス
  # ブラウザの各コンポーネントのパフォーマンスを監視する
  class PerformanceMonitor
    # メモリ使用量の情報
    class MemoryUsage
      property total_bytes : Int64
      property component_bytes : Hash(String, Int64)
      
      def initialize
        @total_bytes = 0_i64
        @component_bytes = {} of String => Int64
      end
      
      def to_s
        "合計: #{format_bytes(total_bytes)} (#{component_bytes.map { |k, v| "#{k}: #{format_bytes(v)}" }.join(", ")})"
      end
      
      private def format_bytes(bytes : Int64) : String
        if bytes < 1024
          "#{bytes}B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)}KB"
        elsif bytes < 1024 * 1024 * 1024
          "#{(bytes / 1024.0 / 1024.0).round(2)}MB"
        else
          "#{(bytes / 1024.0 / 1024.0 / 1024.0).round(2)}GB"
        end
      end
    end
    
    # CPU使用率の情報
    class CPUUsage
      property total_percent : Float64
      property component_percent : Hash(String, Float64)
      
      def initialize
        @total_percent = 0.0
        @component_percent = {} of String => Float64
      end
      
      def to_s
        "合計: #{total_percent.round(2)}% (#{component_percent.map { |k, v| "#{k}: #{v.round(2)}%" }.join(", ")})"
      end
    end
    
    # FPS測定の情報
    class FPSMeasurement
      property current_fps : Float64
      property avg_fps : Float64
      property min_fps : Float64
      property max_fps : Float64
      property frame_times : Array(Float64)
      property frame_time_history_size : Int32
      
      def initialize(@frame_time_history_size : Int32 = 60)
        @current_fps = 0.0
        @avg_fps = 0.0
        @min_fps = Float64::MAX
        @max_fps = 0.0
        @frame_times = [] of Float64
      end
      
      def add_frame_time(time_ms : Float64)
        if time_ms > 0
          fps = 1000.0 / time_ms
          
          @current_fps = fps
          @avg_fps = calculate_avg_fps(fps)
          @min_fps = fps if fps < @min_fps
          @max_fps = fps if fps > @max_fps
          
          # フレーム時間の履歴を更新
          @frame_times.unshift(time_ms)
          if @frame_times.size > @frame_time_history_size
            @frame_times.pop
          end
        end
      end
      
      private def calculate_avg_fps(current_fps : Float64) : Float64
        if @frame_times.empty?
          current_fps
        else
          avg_frame_time = @frame_times.sum / @frame_times.size
          1000.0 / avg_frame_time
        end
      end
      
      def to_s
        "現在: #{@current_fps.round(2)} FPS, 平均: #{@avg_fps.round(2)} FPS, 最小: #{@min_fps.round(2)} FPS, 最大: #{@max_fps.round(2)} FPS"
      end
    end
    
    # ネットワーク統計の情報
    class NetworkStats
      property bytes_received : Int64
      property bytes_sent : Int64
      property requests_sent : Int32
      property requests_completed : Int32
      property requests_failed : Int32
      property avg_response_time_ms : Float64
      property active_connections : Int32
      
      def initialize
        @bytes_received = 0_i64
        @bytes_sent = 0_i64
        @requests_sent = 0
        @requests_completed = 0
        @requests_failed = 0
        @avg_response_time_ms = 0.0
        @active_connections = 0
      end
      
      def add_request(bytes_sent : Int64, response_time_ms : Float64)
        @bytes_sent += bytes_sent
        @requests_sent += 1
        
        # 平均応答時間の更新
        @avg_response_time_ms = ((@avg_response_time_ms * (@requests_completed - 1)) + response_time_ms) / @requests_completed if @requests_completed > 0
      end
      
      def add_response(bytes_received : Int64, success : Bool)
        @bytes_received += bytes_received
        
        if success
          @requests_completed += 1
        else
          @requests_failed += 1
        end
      end
      
      def to_s
        "送信: #{format_bytes(@bytes_sent)}, 受信: #{format_bytes(@bytes_received)}, " +
        "リクエスト: #{@requests_sent}, 完了: #{@requests_completed}, 失敗: #{@requests_failed}, " +
        "平均応答時間: #{@avg_response_time_ms.round(2)}ms, アクティブ接続: #{@active_connections}"
      end
      
      private def format_bytes(bytes : Int64) : String
        if bytes < 1024
          "#{bytes}B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)}KB"
        elsif bytes < 1024 * 1024 * 1024
          "#{(bytes / 1024.0 / 1024.0).round(2)}MB"
        else
          "#{(bytes / 1024.0 / 1024.0 / 1024.0).round(2)}GB"
        end
      end
    end
    
    @engine : Engine
    @ui_manager : QuantumUI::Manager
    @network_manager : QuantumNetwork::Manager
    @storage_manager : QuantumStorage::Manager
    
    @memory_usage : MemoryUsage = MemoryUsage.new
    @cpu_usage : CPUUsage = CPUUsage.new
    @fps_measurement : FPSMeasurement = FPSMeasurement.new
    @network_stats : NetworkStats = NetworkStats.new
    
    @running : Bool = false
    @monitoring_thread : Thread? = nil
    @monitoring_interval : Float64 = 1.0 # 監視間隔（秒）
    
    @last_frame_time : Time? = nil
    @performance_warnings : Array(String) = [] of String
    
    # 監視対象のメトリクス
    enum MetricsType
      MEMORY
      CPU
      FPS
      NETWORK
      ALL
    end
    
    # 性能ボトルネックの種類
    enum BottleneckType
      NONE
      MEMORY
      CPU
      GPU
      NETWORK
      DISK
      UNKNOWN
    end
    
    def initialize(@engine : Engine, @ui_manager : QuantumUI::Manager, @network_manager : QuantumNetwork::Manager, @storage_manager : QuantumStorage::Manager)
      # イベントリスナーを登録
      setup_event_listeners
    end
    
    # パフォーマンスモニタリングを開始
    def start
      return if @running
      
      @running = true
      
      # モニタリングスレッドを開始
      @monitoring_thread = spawn do
        monitoring_loop
      end
      
      Log.info { "PerformanceMonitor: モニタリングを開始しました" }
    end
    
    # パフォーマンスモニタリングを停止
    def shutdown
      return unless @running
      
      @running = false
      
      # モニタリングスレッドの終了を待機
      if thread = @monitoring_thread
        thread.join
      end
      
      Log.info { "PerformanceMonitor: モニタリングを停止しました" }
    end
    
    # モニタリングループ
    private def monitoring_loop
      while @running
        # メモリ使用量の測定
        measure_memory_usage
        
        # CPU使用率の測定
        measure_cpu_usage
        
        # ネットワーク統計の更新
        update_network_stats
        
        # ボトルネックの検出
        detect_bottlenecks
        
        # メトリクスをログに出力（デバッグモードの場合）
        log_metrics if @engine.config.core.debugging_enabled
        
        # 監視間隔だけ待機
        sleep @monitoring_interval
      end
    end
    
    # メモリ使用量の測定
    private def measure_memory_usage
      # 実際の実装では、OSのAPIやGCの情報を使用してメモリ使用量を取得
      # ここでは簡易的な実装
      
      # トータルメモリ使用量（仮の値）
      @memory_usage.total_bytes = 100_000_000_i64
      
      # コンポーネント別メモリ使用量（仮の値）
      @memory_usage.component_bytes["ui"] = 30_000_000_i64
      @memory_usage.component_bytes["network"] = 10_000_000_i64
      @memory_usage.component_bytes["storage"] = 20_000_000_i64
      @memory_usage.component_bytes["renderer"] = 40_000_000_i64
    end
    
    # CPU使用率の測定
    private def measure_cpu_usage
      # 実際の実装では、OSのAPIを使用してCPU使用率を取得
      # ここでは簡易的な実装
      
      # トータルCPU使用率（仮の値）
      @cpu_usage.total_percent = 20.0
      
      # コンポーネント別CPU使用率（仮の値）
      @cpu_usage.component_percent["ui"] = 5.0
      @cpu_usage.component_percent["network"] = 3.0
      @cpu_usage.component_percent["storage"] = 2.0
      @cpu_usage.component_percent["renderer"] = 10.0
    end
    
    # フレーム時間の測定
    def measure_frame_time
      current_time = Time.utc
      
      if last_time = @last_frame_time
        # 前回のフレームからの経過時間（ミリ秒）
        frame_time_ms = (current_time - last_time).total_milliseconds
        
        # FPS測定を更新
        @fps_measurement.add_frame_time(frame_time_ms)
        
        # フレーム時間が長すぎる場合は警告
        if frame_time_ms > 33.33 # 30FPS未満
          @performance_warnings << "低FPS検出: #{@fps_measurement.current_fps.round(2)} FPS"
        end
      end
      
      @last_frame_time = current_time
    end
    
    # ネットワーク統計の更新
    private def update_network_stats
      # 実際の実装では、ネットワークマネージャーから統計情報を取得
      # ここでは簡易的な実装
      
      # 現在のアクティブ接続数
      @network_stats.active_connections = 3 # 仮の値
    end
    
    # ボトルネックの検出
    private def detect_bottlenecks
      bottleneck = BottleneckType::NONE
      bottleneck_info = ""
      
      # メモリボトルネックの検出
      if @memory_usage.total_bytes > 500_000_000_i64 # 500MB以上
        bottleneck = BottleneckType::MEMORY
        bottleneck_info = "メモリ使用量が高すぎます: #{format_bytes(@memory_usage.total_bytes)}"
      end
      
      # CPU使用率ボトルネックの検出
      if @cpu_usage.total_percent > 80.0
        bottleneck = BottleneckType::CPU
        bottleneck_info = "CPU使用率が高すぎます: #{@cpu_usage.total_percent.round(2)}%"
      end
      
      # FPSボトルネックの検出
      if @fps_measurement.avg_fps < 30.0
        bottleneck = BottleneckType::GPU
        bottleneck_info = "FPSが低すぎます: #{@fps_measurement.avg_fps.round(2)} FPS"
      end
      
      # ネットワークボトルネックの検出
      if @network_stats.avg_response_time_ms > 500.0
        bottleneck = BottleneckType::NETWORK
        bottleneck_info = "ネットワーク応答時間が長すぎます: #{@network_stats.avg_response_time_ms.round(2)}ms"
      end
      
      # ボトルネックが検出された場合はログに記録
      if bottleneck != BottleneckType::NONE
        Log.warning { "PerformanceMonitor: パフォーマンスボトルネック検出 - #{bottleneck} - #{bottleneck_info}" }
        
        # 性能警告を追加
        @performance_warnings << bottleneck_info
        
        # 警告が多すぎる場合は古い警告を削除
        while @performance_warnings.size > 10
          @performance_warnings.shift
        end
      end
    end
    
    # 現在のパフォーマンスメトリクスをログに出力
    private def log_metrics
      Log.debug { "メモリ使用量: #{@memory_usage}" }
      Log.debug { "CPU使用率: #{@cpu_usage}" }
      Log.debug { "FPS: #{@fps_measurement}" }
      Log.debug { "ネットワーク統計: #{@network_stats}" }
    end
    
    # 指定したタイプのメトリクスを取得
    def get_metrics(type : MetricsType) : String
      case type
      when MetricsType::MEMORY
        "メモリ使用量: #{@memory_usage}"
      when MetricsType::CPU
        "CPU使用率: #{@cpu_usage}"
      when MetricsType::FPS
        "FPS: #{@fps_measurement}"
      when MetricsType::NETWORK
        "ネットワーク統計: #{@network_stats}"
      when MetricsType::ALL
        "メモリ使用量: #{@memory_usage}\n" +
        "CPU使用率: #{@cpu_usage}\n" +
        "FPS: #{@fps_measurement}\n" +
        "ネットワーク統計: #{@network_stats}"
      else
        "不明なメトリクスタイプ: #{type}"
      end
    end
    
    # 現在の性能警告を取得
    def get_performance_warnings : Array(String)
      @performance_warnings.dup
    end
    
    # イベントリスナーを設定
    private def setup_event_listeners
      # フレームレンダリング完了イベントでフレーム時間を測定
      frame_listener = SimpleEventListener.new(
        ->(event : Event) {
          measure_frame_time
          nil
        },
        [EventType::PAGE_RENDER_COMPLETE]
      )
      
      # ネットワークリクエスト関連イベントを監視
      network_listener = SimpleEventListener.new(
        ->(event : Event) {
          case event.type
          when EventType::RESOURCE_LOAD_START
            # リクエスト開始時の処理
            # 実際の実装ではリクエストサイズなどを取得
            nil
          when EventType::RESOURCE_LOAD_COMPLETE
            # リクエスト完了時の処理
            # 実際の実装ではレスポンスサイズなどを取得
            nil
          when EventType::RESOURCE_LOAD_ERROR
            # リクエストエラー時の処理
            nil
          end
          nil
        },
        [
          EventType::RESOURCE_LOAD_START,
          EventType::RESOURCE_LOAD_COMPLETE,
          EventType::RESOURCE_LOAD_ERROR
        ]
      )
      
      # イベントリスナーをエンジンに登録
      @engine.event_dispatcher.add_listener(frame_listener)
      @engine.event_dispatcher.add_listener(network_listener)
    end
    
    # バイト数を読みやすい形式にフォーマット
    private def format_bytes(bytes : Int64) : String
      if bytes < 1024
        "#{bytes}B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(2)}KB"
      elsif bytes < 1024 * 1024 * 1024
        "#{(bytes / 1024.0 / 1024.0).round(2)}MB"
      else
        "#{(bytes / 1024.0 / 1024.0 / 1024.0).round(2)}GB"
      end
    end
  end
end 