module QuantumCore
  # パフォーマンスモニタリングシステム
  # すべてのコンポーネントの性能指標を集計、分析、最適化するための中枢システム
  class PerformanceMonitor
    # シングルトンインスタンス
    @@instance : PerformanceMonitor?
    
    # パフォーマンス指標の収集間隔（ミリ秒）
    COLLECTION_INTERVAL = 1000
    
    # 履歴保持期間（秒）
    HISTORY_DURATION = 60
    
    # オーバーヘッド警告しきい値（ミリ秒）
    OVERHEAD_WARNING_THRESHOLD = 0.5
    
    # メトリクス型定義
    alias MetricValue = Float64 | Int32 | Int64
    
    # 収集データ
    @render_metrics : Hash(String, Deque(MetricValue))
    @network_metrics : Hash(String, Deque(MetricValue))
    @memory_metrics : Hash(String, Deque(MetricValue))
    @js_metrics : Hash(String, Deque(MetricValue))
    
    # 最終収集時刻
    @last_collection_time : Time
    
    # 監視状態
    @monitoring_active : Bool
    
    # データポイント数
    @data_points_per_history : Int32
    
    # 統計処理用の一時変数
    @temp_metrics : Hash(String, MetricValue)
    
    # コンポーネント参照
    @engine : QuantumCore::Engine?
    @ui_manager : QuantumUI::Manager?
    @network_manager : QuantumNetwork::Manager?
    @storage_manager : QuantumStorage::Manager?
    
    # インスタンス取得メソッド
    def self.instance : PerformanceMonitor
      @@instance ||= new
    end
    
    # 初期化処理
    private def initialize
      @render_metrics = Hash(String, Deque(MetricValue)).new { |h, k| h[k] = Deque(MetricValue).new }
      @network_metrics = Hash(String, Deque(MetricValue)).new { |h, k| h[k] = Deque(MetricValue).new }
      @memory_metrics = Hash(String, Deque(MetricValue)).new { |h, k| h[k] = Deque(MetricValue).new }
      @js_metrics = Hash(String, Deque(MetricValue)).new { |h, k| h[k] = Deque(MetricValue).new }
      
      @last_collection_time = Time.monotonic
      @monitoring_active = false
      @data_points_per_history = (HISTORY_DURATION * 1000) / COLLECTION_INTERVAL
      @temp_metrics = Hash(String, MetricValue).new
    end
    
    # コンポーネント参照設定
    def set_components(engine : QuantumCore::Engine?, ui_manager : QuantumUI::Manager?, 
                      network_manager : QuantumNetwork::Manager?, 
                      storage_manager : QuantumStorage::Manager?)
      @engine = engine
      @ui_manager = ui_manager
      @network_manager = network_manager
      @storage_manager = storage_manager
    end
    
    # モニタリング開始
    def start
      return if @monitoring_active
      
      @monitoring_active = true
      @last_collection_time = Time.monotonic
      
      # バックグラウンドでの定期収集を開始
      spawn do
        while @monitoring_active
          collect_metrics
          sleep(COLLECTION_INTERVAL / 1000.0)
        end
      end
      
      Log.info { "パフォーマンスモニタリングを開始しました (間隔: #{COLLECTION_INTERVAL}ms, 履歴: #{HISTORY_DURATION}秒)" }
    end
    
    # モニタリング停止
    def stop
      @monitoring_active = false
      Log.info { "パフォーマンスモニタリングを停止しました" }
    end
    
    # レンダリング統計報告
    def report_render_stats(frame_time : Float64, fps : Float64, jank_count : Int32) : Void
      @temp_metrics["frame_time"] = frame_time
      @temp_metrics["fps"] = fps
      @temp_metrics["jank_count"] = jank_count
    end
    
    # ネットワーク統計報告
    def report_network_stats(request_count : Int32, total_bytes : Int64, avg_latency : Float64) : Void
      @temp_metrics["request_count"] = request_count
      @temp_metrics["total_bytes"] = total_bytes
      @temp_metrics["avg_latency"] = avg_latency
    end
    
    # メモリ統計報告
    def report_memory_stats(used_memory : Int64, object_count : Int32, gc_pause_time : Float64) : Void
      @temp_metrics["used_memory"] = used_memory
      @temp_metrics["object_count"] = object_count
      @temp_metrics["gc_pause_time"] = gc_pause_time
    end
    
    # JavaScript統計報告
    def report_js_stats(execution_time : Float64, compile_time : Float64, gc_time : Float64) : Void
      @temp_metrics["js_execution_time"] = execution_time
      @temp_metrics["js_compile_time"] = compile_time
      @temp_metrics["js_gc_time"] = gc_time
    end
    
    # 指標収集処理
    private def collect_metrics
      start_time = Time.monotonic
      
      # 各コンポーネントからメトリクスを収集
      collect_from_ui_manager
      collect_from_network_manager
      collect_from_storage_manager
      collect_from_engine
      
      # 一時指標を永続化
      store_metrics
      
      # 履歴データの整理（古いデータを削除）
      prune_old_metrics
      
      # 定期的な分析と最適化提案
      if (Time.monotonic - @last_collection_time).total_seconds >= 10
        analyze_performance
        @last_collection_time = Time.monotonic
      end
      
      # 収集処理のオーバーヘッドをチェック
      end_time = Time.monotonic
      overhead_ms = (end_time - start_time).total_milliseconds
      
      if overhead_ms > OVERHEAD_WARNING_THRESHOLD
        Log.warning { "パフォーマンスモニタのオーバーヘッドが高すぎます: #{overhead_ms.round(2)}ms" }
      end
    end
    
    # UIマネージャからの指標収集
    private def collect_from_ui_manager
      return unless ui_manager = @ui_manager
      
      # UIレイヤーからパフォーマンス指標を取得
      ui_metrics = QuantumUI::Manager.instance.get_performance_metrics
    end
    
    # ネットワークマネージャからの指標収集
    private def collect_from_network_manager
      return unless network_manager = @network_manager
      
      # ネットワークレイヤーからパフォーマンス指標を取得
      net_metrics = QuantumNet::Manager.instance.get_performance_metrics
    end
    
    # ストレージマネージャからの指標収集
    private def collect_from_storage_manager
      return unless storage_manager = @storage_manager
      
      # ストレージレイヤーからパフォーマンス指標を取得
      storage_metrics = QuantumStorage::Manager.instance.get_performance_metrics
    end
    
    # エンジンからの指標収集
    private def collect_from_engine
      return unless engine = @engine
      
      # コアエンジンからパフォーマンス指標を取得
      engine_metrics = QuantumCore::Engine.instance.get_performance_metrics
    end
    
    # 指標を永続化
    private def store_metrics
      # レンダリング指標
      @temp_metrics.each do |key, value|
        case key
        when .starts_with?("frame_"), .starts_with?("fps"), .starts_with?("jank_")
          @render_metrics[key] << value
        when .starts_with?("request_"), .starts_with?("bytes"), .starts_with?("latency")
          @network_metrics[key] << value
        when .starts_with?("memory"), .starts_with?("object_"), .starts_with?("gc_")
          @memory_metrics[key] << value
        when .starts_with?("js_")
          @js_metrics[key] << value
        end
      end
      
      @temp_metrics.clear
    end
    
    # 古い指標を削除
    private def prune_old_metrics
      # 履歴の長さを制限
      [@render_metrics, @network_metrics, @memory_metrics, @js_metrics].each do |metrics_hash|
        metrics_hash.each do |key, values|
          while values.size > @data_points_per_history
            values.shift?
          end
        end
      end
    end
    
    # パフォーマンス分析
    private def analyze_performance
      analyze_render_performance
      analyze_network_performance
      analyze_memory_usage
      analyze_js_performance
      
      # 総合分析
      analyze_overall_performance
    end
    
    # レンダリングパフォーマンス分析
    private def analyze_render_performance
      return if @render_metrics["fps"].empty?
      
      # 平均FPSの計算
      avg_fps = calculate_average(@render_metrics["fps"]) rescue 0.0
      
      # ジャンク（フレームスキップ）の分析
      jank_rate = calculate_average(@render_metrics["jank_count"]) rescue 0.0
      
      if avg_fps < 55.0
        Log.warning { "レンダリングパフォーマンスが低下しています: #{avg_fps.round(1)} FPS" }
        suggest_render_optimizations(avg_fps, jank_rate)
      end
    end
    
    # ネットワークパフォーマンス分析
    private def analyze_network_performance
      return if @network_metrics["avg_latency"].empty?
      
      # 平均レイテンシの計算
      avg_latency = calculate_average(@network_metrics["avg_latency"]) rescue 0.0
      
      if avg_latency > 150.0
        Log.warning { "ネットワークレイテンシが高くなっています: #{avg_latency.round(0)}ms" }
        suggest_network_optimizations(avg_latency)
      end
    end
    
    # メモリ使用分析
    private def analyze_memory_usage
      return if @memory_metrics["used_memory"].empty?
      
      # メモリ使用量の計算
      memory_usage_mb = (calculate_average(@memory_metrics["used_memory"]) rescue 0.0) / (1024 * 1024)
      
      if memory_usage_mb > 300.0
        Log.warning { "メモリ使用量が多くなっています: #{memory_usage_mb.round(1)} MB" }
        suggest_memory_optimizations(memory_usage_mb)
      end
    end
    
    # JavaScript性能分析
    private def analyze_js_performance
      return if @js_metrics["js_execution_time"].empty?
      
      # JS実行時間の計算
      js_exec_time = calculate_average(@js_metrics["js_execution_time"]) rescue 0.0
      
      if js_exec_time > 10.0
        Log.warning { "JavaScript実行に時間がかかっています: #{js_exec_time.round(1)}ms" }
        suggest_js_optimizations(js_exec_time)
      end
    end
    
    # 総合パフォーマンス分析
    private def analyze_overall_performance
      # 各指標を総合的に評価
      fps = calculate_average(@render_metrics["fps"]) rescue 0.0
      latency = calculate_average(@network_metrics["avg_latency"]) rescue 0.0
      memory_mb = (calculate_average(@memory_metrics["used_memory"]) rescue 0.0) / (1024 * 1024)
      js_time = calculate_average(@js_metrics["js_execution_time"]) rescue 0.0
      
      # 総合スコアの計算 (0-100)
      fps_score = Math.min(100, fps * 100 / 60)
      latency_score = Math.max(0, 100 - (latency / 3))
      memory_score = Math.max(0, 100 - (memory_mb / 5))
      js_score = Math.max(0, 100 - (js_time / 0.5))
      
      total_score = (fps_score + latency_score + memory_score + js_score) / 4
      
      Log.info { "総合パフォーマンススコア: #{total_score.round(1)}/100" }
      
      if total_score < 60
        Log.warning { "全体的なパフォーマンスが低下しています。最適化が必要です。" }
      elsif total_score > 90
        Log.info { "パフォーマンスは最適な状態です。" }
      end
    end
    
    # レンダリング最適化提案
    private def suggest_render_optimizations(fps : Float64, jank_rate : Float64)
      suggestions = [] of String
      
      if fps < 30
        suggestions << "描画処理をメインスレッドから分離してください"
        suggestions << "レンダリングレイヤーのGPU使用率を確認してください"
      end
      
      if jank_rate > 2
        suggestions << "アニメーションの複雑さを削減してください"
        suggestions << "不要なレイアウト再計算を避けてください"
      end
      
      unless suggestions.empty?
        Log.info { "レンダリング最適化提案:" }
        suggestions.each { |s| Log.info { " - #{s}" } }
      end
    end
    
    # ネットワーク最適化提案
    private def suggest_network_optimizations(latency : Float64)
      suggestions = [] of String
      
      if latency > 300
        suggestions << "接続プールの使用を検討してください"
        suggestions << "HTTP/3 (QUIC) への切り替えを検討してください"
      end
      
      if latency > 150
        suggestions << "リソースのプリフェッチを実装してください"
        suggestions << "圧縮レベルを最適化してください"
      end
      
      unless suggestions.empty?
        Log.info { "ネットワーク最適化提案:" }
        suggestions.each { |s| Log.info { " - #{s}" } }
      end
    end
    
    # メモリ最適化提案
    private def suggest_memory_optimizations(memory_mb : Float64)
      suggestions = [] of String
      
      if memory_mb > 500
        suggestions << "メモリリークの可能性を確認してください"
        suggestions << "アイドル状態のタブのメモリを解放してください"
      end
      
      if memory_mb > 300
        suggestions << "オブジェクトプーリングの使用を検討してください"
        suggestions << "画像キャッシュのサイズを制限してください"
      end
      
      unless suggestions.empty?
        Log.info { "メモリ最適化提案:" }
        suggestions.each { |s| Log.info { " - #{s}" } }
      end
    end
    
    # JavaScript最適化提案
    private def suggest_js_optimizations(exec_time : Float64)
      suggestions = [] of String
      
      if exec_time > 20
        suggestions << "重いJavaScript処理をWeb Workerに移動してください"
        suggestions << "JITコンパイラの最適化を確認してください"
      end
      
      if exec_time > 10
        suggestions << "不要なDOMアクセスを削減してください"
        suggestions << "イベントハンドラの効率を改善してください"
      end
      
      unless suggestions.empty?
        Log.info { "JavaScript最適化提案:" }
        suggestions.each { |s| Log.info { " - #{s}" } }
      end
    end
    
    # 平均値計算ヘルパー
    private def calculate_average(values : Deque(MetricValue)) : Float64
      return 0.0 if values.empty?
      
      sum = values.sum { |v| v.to_f }
      sum / values.size
    end
    
    # 最終的なシャットダウン処理
    def shutdown
      stop
      
      # 最終レポートの出力
      generate_final_report
      
      Log.info { "パフォーマンスモニターをシャットダウンしました" }
    end
    
    # 最終レポート生成
    private def generate_final_report
      Log.info { "=== パフォーマンス最終レポート ===" }
      
      # レンダリング統計
      avg_fps = calculate_average(@render_metrics["fps"]) rescue 0.0
      Log.info { "平均FPS: #{avg_fps.round(1)}" }
      
      # ネットワーク統計
      avg_latency = calculate_average(@network_metrics["avg_latency"]) rescue 0.0
      Log.info { "平均レイテンシ: #{avg_latency.round(1)}ms" }
      
      # メモリ統計
      avg_memory = (calculate_average(@memory_metrics["used_memory"]) rescue 0.0) / (1024 * 1024)
      Log.info { "平均メモリ使用量: #{avg_memory.round(1)} MB" }
      
      # JavaScript統計
      avg_js_time = calculate_average(@js_metrics["js_execution_time"]) rescue 0.0
      Log.info { "平均JavaScript実行時間: #{avg_js_time.round(1)}ms" }
      
      Log.info { "===============================" }
    end
    
    # 最新の指標取得
    def get_latest_metrics : Hash(String, MetricValue)
      result = Hash(String, MetricValue).new
      
      # 各カテゴリの最新値を取得
      [@render_metrics, @network_metrics, @memory_metrics, @js_metrics].each do |metrics_hash|
        metrics_hash.each do |key, values|
          result[key] = values.last? || 0.0 unless values.empty?
        end
      end
      
      result
    end
    
    # 期間指定での指標取得
    def get_metrics_history(duration_seconds : Int32) : Hash(String, Array(MetricValue))
      result = Hash(String, Array(MetricValue)).new { |h, k| h[k] = [] of MetricValue }
      
      # 指定期間分のデータポイント数
      points = (duration_seconds * 1000) / COLLECTION_INTERVAL
      
      # 各カテゴリの履歴を取得
      [@render_metrics, @network_metrics, @memory_metrics, @js_metrics].each do |metrics_hash|
        metrics_hash.each do |key, values|
          # 指定期間分の値だけを取得
          result[key] = values.to_a.last(points)
        end
      end
      
      result
    end
  end
end 