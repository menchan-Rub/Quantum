# HTTP/3パフォーマンスモニター
#
# このモジュールはHTTP/3接続のパフォーマンスを監視・分析し、
# 最適化のためのリアルタイムデータを提供します。

require "log"
require "json"
require "time"
require "./http3_network_manager"

module QuantumBrowser
  # HTTP/3プロトコルのパフォーマンスを監視するクラス
  class Http3PerformanceMonitor
    Log = ::Log.for(self)
    
    # ネットワーク環境の種類
    enum NetworkType
      Unknown     # 不明
      Wifi        # Wi-Fi
      Ethernet    # 有線LAN
      Cellular4G  # 4G携帯回線
      Cellular5G  # 5G携帯回線
      Cellular3G  # 3G携帯回線
      Satellite   # 衛星回線
      VPN         # VPN
    end
    
    # 最適化プロファイル
    enum OptimizationProfile
      Balanced        # バランス型
      LowLatency      # 低遅延型
      HighThroughput  # 高スループット型
      LowBandwidth    # 低帯域型
      BatteryEfficient # バッテリー効率型
      Mobile          # モバイル型
      Desktop         # デスクトップ型
    end
    
    # パフォーマンス指標
    class PerformanceMetrics
      property avg_rtt : Float64 = 0.0               # 平均RTT (ミリ秒)
      property min_rtt : Float64 = Float64::MAX      # 最小RTT (ミリ秒)
      property max_rtt : Float64 = 0.0               # 最大RTT (ミリ秒)
      property rtt_variance : Float64 = 0.0          # RTT分散
      property avg_ttfb : Float64 = 0.0              # 平均Time To First Byte (ミリ秒)
      property throughput : Float64 = 0.0            # スループット (バイト/秒)
      property request_success_rate : Float64 = 1.0  # リクエスト成功率 (0-1)
      property avg_header_size : Float64 = 0.0       # 平均ヘッダーサイズ (バイト)
      property avg_response_size : Float64 = 0.0     # 平均レスポンスサイズ (バイト)
      property header_compression_ratio : Float64 = 0.0 # ヘッダー圧縮率
      property total_requests : Int32 = 0            # 総リクエスト数
      property successful_requests : Int32 = 0       # 成功リクエスト数
      property failed_requests : Int32 = 0           # 失敗リクエスト数
      property connection_errors : Int32 = 0         # 接続エラー数
      property stream_resets : Int32 = 0             # ストリームリセット数
      property flow_control_limited : Int32 = 0      # フロー制御制限回数
      property packet_loss_estimated : Float64 = 0.0 # 推定パケットロス率 (0-1)
      property jitter_estimated : Float64 = 0.0      # 推定ジッター (ミリ秒)
      property network_type : NetworkType = NetworkType::Unknown # ネットワークタイプ
      property battery_powered : Bool = false        # バッテリー電源使用フラグ
      property battery_level : Float64 = 1.0         # バッテリーレベル (0-1)
      property signal_strength : Float64? = nil      # 信号強度 (0-1)
      property consecutive_timeouts : Int32 = 0      # 連続タイムアウト数
      property samples : Int32 = 0                   # サンプル数
      
      def initialize
      end
      
      # メトリクスを更新
      def update_with_request(rtt : Float64, ttfb : Float64, request_size : Int64, response_size : Int64, success : Bool)
        @samples += 1
        
        # RTT統計
        if @samples == 1
          @avg_rtt = rtt
          @min_rtt = rtt
          @max_rtt = rtt
        else
          # 移動平均の更新
          @avg_rtt = (@avg_rtt * (@samples - 1) + rtt) / @samples
          @min_rtt = [rtt, @min_rtt].min
          @max_rtt = [rtt, @max_rtt].max
          
          # 分散計算
          @rtt_variance = ((@rtt_variance * (@samples - 2) + (rtt - @avg_rtt) ** 2)) / (@samples - 1) if @samples > 1
        end
        
        # TTFB
        @avg_ttfb = (@avg_ttfb * (@samples - 1) + ttfb) / @samples
        
        # サイズ統計
        @avg_header_size = (@avg_header_size * (@samples - 1) + request_size) / @samples
        @avg_response_size = (@avg_response_size * (@samples - 1) + response_size) / @samples
        
        # スループット計算 (時間あたりのデータ量)
        if rtt > 0
          request_throughput = response_size / (rtt / 1000.0)
          @throughput = (@throughput * (@samples - 1) + request_throughput) / @samples
        end
        
        # リクエスト統計
        @total_requests += 1
        if success
          @successful_requests += 1
          @consecutive_timeouts = 0
        else
          @failed_requests += 1
          @consecutive_timeouts += 1
        end
        
        # 成功率更新
        @request_success_rate = @successful_requests.to_f / @total_requests
      end
      
      # ネットワーク条件の推定
      def estimate_network_conditions
        # RTTとジッターからネットワークタイプを推定
        @network_type = if @avg_rtt < 20
                          NetworkType::Ethernet
                        elsif @avg_rtt < 50
                          NetworkType::Wifi
                        elsif @avg_rtt < 100
                          NetworkType::Cellular5G
                        elsif @avg_rtt < 150
                          NetworkType::Cellular4G
                        elsif @avg_rtt < 300
                          NetworkType::Cellular3G
                        elsif @avg_rtt > 500
                          NetworkType::Satellite
                        else
                          NetworkType::Unknown
                        end
        
        # パケットロス率の推定
        # 失敗率と成功率からラフに推定
        @packet_loss_estimated = Math.min(0.8, 1.0 - @request_success_rate)
        
        # ジッターの推定（RTTの標準偏差を使用）
        @jitter_estimated = Math.sqrt(@rtt_variance)
      end
      
      # JSON形式での出力
      def to_json(json : JSON::Builder)
        json.object do
          json.field "avg_rtt", @avg_rtt
          json.field "min_rtt", @min_rtt
          json.field "max_rtt", @max_rtt
          json.field "rtt_variance", @rtt_variance
          json.field "avg_ttfb", @avg_ttfb
          json.field "throughput", @throughput
          json.field "request_success_rate", @request_success_rate
          json.field "avg_header_size", @avg_header_size
          json.field "avg_response_size", @avg_response_size
          json.field "header_compression_ratio", @header_compression_ratio
          json.field "total_requests", @total_requests
          json.field "successful_requests", @successful_requests
          json.field "failed_requests", @failed_requests
          json.field "connection_errors", @connection_errors
          json.field "stream_resets", @stream_resets
          json.field "flow_control_limited", @flow_control_limited
          json.field "packet_loss_estimated", @packet_loss_estimated
          json.field "jitter_estimated", @jitter_estimated
          json.field "network_type", @network_type.to_s
          json.field "battery_powered", @battery_powered
          json.field "battery_level", @battery_level
          json.field "consecutive_timeouts", @consecutive_timeouts
          json.field "samples", @samples
          
          if signal_strength = @signal_strength
            json.field "signal_strength", signal_strength
          else
            json.field "signal_strength", nil
          end
        end
      end
    end
    
    # 最適化推奨事項
    class OptimizationRecommendation
      property profile : OptimizationProfile
      property qpack_table_capacity : Int32
      property max_field_section_size : Int32
      property qpack_blocked_streams : Int32
      property flow_control_window : Int32
      property max_concurrent_streams : Int32
      property initial_rtt : Int32
      property idle_timeout : Int32
      property explanation : String
      
      def initialize(@profile)
        # デフォルト値
        @qpack_table_capacity = 4096    # 4KB
        @max_field_section_size = 65536 # 64KB
        @qpack_blocked_streams = 16
        @flow_control_window = 16777216 # 16MB
        @max_concurrent_streams = 100
        @initial_rtt = 100              # 100ms
        @idle_timeout = 30000           # 30秒
        @explanation = "バランスの取れたデフォルト設定"
      end
      
      # JSON形式での出力
      def to_json(json : JSON::Builder)
        json.object do
          json.field "profile", @profile.to_s
          json.field "qpack_table_capacity", @qpack_table_capacity
          json.field "max_field_section_size", @max_field_section_size
          json.field "qpack_blocked_streams", @qpack_blocked_streams
          json.field "flow_control_window", @flow_control_window
          json.field "max_concurrent_streams", @max_concurrent_streams
          json.field "initial_rtt", @initial_rtt
          json.field "idle_timeout", @idle_timeout
          json.field "explanation", @explanation
        end
      end
    end
    
    # 接続ごとのパフォーマンス情報
    class ConnectionPerformance
      property host : String
      property port : Int32
      property first_connection_time : Time
      property last_connection_time : Time
      property connection_count : Int32 = 0
      property metrics : PerformanceMetrics
      property is_active : Bool = false
      
      def initialize(@host, @port)
        @first_connection_time = Time.utc
        @last_connection_time = Time.utc
        @metrics = PerformanceMetrics.new
      end
    end
    
    @http3_manager : Http3NetworkManager
    @connections : Hash(String, ConnectionPerformance)
    @global_metrics : PerformanceMetrics
    @monitor_active : Bool = false
    @last_update_time : Time
    @update_interval_seconds : Int32 = 10
    @battery_monitor_active : Bool = false
    
    def initialize(@http3_manager : Http3NetworkManager)
      @connections = {} of String => ConnectionPerformance
      @global_metrics = PerformanceMetrics.new
      @last_update_time = Time.utc
      
      # バックグラウンドでモニタリングを開始
      # start_monitoring
    end
    
    # モニタリングを開始
    def start_monitoring
      return if @monitor_active
      
      @monitor_active = true
      spawn do
        while @monitor_active
          update_metrics
          sleep @update_interval_seconds.seconds
        end
      end
      
      Log.info { "HTTP/3パフォーマンスモニター開始" }
    end
    
    # モニタリングを停止
    def stop_monitoring
      @monitor_active = false
      Log.info { "HTTP/3パフォーマンスモニター停止" }
    end
    
    # バッテリーモニタリングを開始
    def start_battery_monitoring
      return if @battery_monitor_active
      
      @battery_monitor_active = true
      spawn do
        while @battery_monitor_active
          update_battery_info
          sleep 60.seconds  # バッテリー情報は1分ごとに更新
        end
      end
    end
    
    # バッテリーモニタリングを停止
    def stop_battery_monitoring
      @battery_monitor_active = false
    end
    
    # リクエスト情報でメトリクスを更新
    def update_with_request(host : String, port : Int32, 
                          rtt : Float64, ttfb : Float64, 
                          request_size : Int64, response_size : Int64, 
                          success : Bool)
      connection_key = "#{host}:#{port}"
      
      # コネクション固有のメトリクスを更新
      connection = @connections[connection_key]? || begin
        conn = ConnectionPerformance.new(host, port)
        @connections[connection_key] = conn
        conn
      end
      
      connection.last_connection_time = Time.utc
      connection.connection_count += 1
      connection.metrics.update_with_request(rtt, ttfb, request_size, response_size, success)
      
      # グローバルメトリクスも更新
      @global_metrics.update_with_request(rtt, ttfb, request_size, response_size, success)
    end
    
    # 現在のメトリクスを取得
    def get_current_metrics : PerformanceMetrics
      @global_metrics
    end
    
    # 特定ホストのメトリクスを取得
    def get_host_metrics(host : String, port : Int32 = 443) : PerformanceMetrics?
      connection_key = "#{host}:#{port}"
      @connections[connection_key]?.try &.metrics
    end
    
    # すべてのホストのメトリクスを取得
    def get_all_host_metrics : Hash(String, PerformanceMetrics)
      result = {} of String => PerformanceMetrics
      
      @connections.each do |key, connection|
        result[key] = connection.metrics
      end
      
      result
    end
    
    # 最適化推奨事項を取得
    def get_optimization_recommendation : OptimizationRecommendation
      metrics = @global_metrics
      
      # ネットワーク条件の推定
      metrics.estimate_network_conditions
      
      # プロファイル選択のロジック
      profile = case
      when metrics.battery_powered && metrics.battery_level < 0.3
        # バッテリー残量が少ない場合はバッテリー効率優先
        OptimizationProfile::BatteryEfficient
      when metrics.avg_rtt < 30 && metrics.throughput > 5_000_000
        # 低遅延・高スループットなら高スループットモード
        OptimizationProfile::HighThroughput
      when metrics.avg_rtt < 50 && metrics.jitter_estimated < 10
        # 低遅延・低ジッターなら低遅延モード
        OptimizationProfile::LowLatency
      when metrics.avg_rtt > 200 || metrics.packet_loss_estimated > 0.05
        # 高遅延・高パケットロスなら低帯域モード
        OptimizationProfile::LowBandwidth
      when metrics.network_type == NetworkType::Cellular3G || 
           metrics.network_type == NetworkType::Cellular4G ||
           metrics.network_type == NetworkType::Cellular5G
        # モバイル回線ならモバイルモード
        OptimizationProfile::Mobile
      when metrics.network_type == NetworkType::Ethernet || metrics.network_type == NetworkType::Wifi
        # 有線/WiFiならデスクトップモード
        OptimizationProfile::Desktop
      else
        # それ以外はバランスモード
        OptimizationProfile::Balanced
      end
      
      # 推奨事項を作成
      recommendation = OptimizationRecommendation.new(profile)
      
      # プロファイルごとの設定
      case profile
      when OptimizationProfile::BatteryEfficient
        recommendation.qpack_table_capacity = 2048   # 2KB
        recommendation.flow_control_window = 8388608 # 8MB
        recommendation.max_concurrent_streams = 20
        recommendation.idle_timeout = 15000          # 15秒
        recommendation.explanation = "バッテリーの省電力化のために最適化されています。リソース使用量を抑えています。"
      
      when OptimizationProfile::HighThroughput
        recommendation.qpack_table_capacity = 65536   # 64KB
        recommendation.max_field_section_size = 262144 # 256KB
        recommendation.qpack_blocked_streams = 64
        recommendation.flow_control_window = 67108864 # 64MB
        recommendation.max_concurrent_streams = 500
        recommendation.idle_timeout = 60000           # 60秒
        recommendation.explanation = "高速ネットワークでの並列ダウンロードを最大化するために最適化されています。"
      
      when OptimizationProfile::LowLatency
        recommendation.qpack_table_capacity = 8192    # 8KB
        recommendation.qpack_blocked_streams = 32
        recommendation.initial_rtt = 50               # 50ms
        recommendation.explanation = "低遅延環境での応答性を高めるために最適化されています。"
      
      when OptimizationProfile::LowBandwidth
        recommendation.qpack_table_capacity = 1024    # 1KB
        recommendation.max_field_section_size = 16384 # 16KB
        recommendation.qpack_blocked_streams = 4
        recommendation.flow_control_window = 4194304  # 4MB
        recommendation.max_concurrent_streams = 10
        recommendation.initial_rtt = 300              # 300ms
        recommendation.explanation = "低帯域幅環境での信頼性を高めるために最適化されています。"
      
      when OptimizationProfile::Mobile
        recommendation.qpack_table_capacity = 4096    # 4KB
        recommendation.max_field_section_size = 32768 # 32KB
        recommendation.flow_control_window = 8388608  # 8MB
        recommendation.max_concurrent_streams = 50
        recommendation.initial_rtt = 150              # 150ms
        recommendation.explanation = "モバイル環境でのパフォーマンスとバッテリー効率のバランスを取るために最適化されています。"
      
      when OptimizationProfile::Desktop
        recommendation.qpack_table_capacity = 16384   # 16KB
        recommendation.flow_control_window = 33554432 # 32MB
        recommendation.max_concurrent_streams = 200
        recommendation.initial_rtt = 80               # 80ms
        recommendation.explanation = "デスクトップ環境での高速な閲覧体験のために最適化されています。"
      
      when OptimizationProfile::Balanced
        # デフォルト値を使用
        recommendation.explanation = "バランスのとれたパフォーマンスと信頼性のために最適化されています。"
      end
      
      # BDPベースのフロー制御ウィンドウサイズ調整（帯域遅延積）
      if metrics.avg_rtt > 0 && metrics.throughput > 0
        # BDP = 帯域幅 * RTT
        bdp = metrics.throughput * (metrics.avg_rtt / 1000.0)
        # BDPの1.5倍をウィンドウサイズに（余裕を持たせる）
        optimal_window = (bdp * 1.5).to_i32
        
        # 極端な値にならないよう制限
        if optimal_window > 4194304 && optimal_window < 134217728  # 4MB〜128MB
          recommendation.flow_control_window = optimal_window
        end
      end
      
      # パケットロスが多い場合は同時ストリーム数を減らす
      if metrics.packet_loss_estimated > 0.05
        recommendation.max_concurrent_streams = (recommendation.max_concurrent_streams * 0.7).to_i32
        recommendation.initial_rtt = (recommendation.initial_rtt * 1.2).to_i32  # RTT推定値も余裕を持たせる
      end
      
      recommendation
    end
    
    # 特定ホストへの推奨事項を適用
    def apply_recommendation_to_host(host : String, port : Int32 = 443) : Bool
      return false unless @http3_manager.http3_enabled?
      
      recommendation = get_optimization_recommendation
      
      begin
        # Nimバックエンドに設定更新リクエストを送信
        response = @http3_manager.ipc_client.call("update_http3_settings", {
          "host" => host,
          "port" => port,
          "qpack_max_table_capacity" => recommendation.qpack_table_capacity,
          "max_field_section_size" => recommendation.max_field_section_size,
          "qpack_blocked_streams" => recommendation.qpack_blocked_streams,
          "flow_control_window" => recommendation.flow_control_window,
          "max_concurrent_streams" => recommendation.max_concurrent_streams,
          "initial_rtt" => recommendation.initial_rtt,
          "idle_timeout" => recommendation.idle_timeout,
          "profile" => recommendation.profile.to_s
        })
        
        if response["success"] == true
          Log.info { "HTTP/3設定を更新しました: #{host}:#{port} プロファイル=#{recommendation.profile}" }
          return true
        else
          Log.warn { "HTTP/3設定更新失敗: #{host}:#{port} - #{response["error"]}" }
        end
      rescue e
        Log.error(exception: e) { "HTTP/3設定更新エラー: #{host}:#{port}" }
      end
      
      false
    end
    
    # すべてのホストに推奨事項を適用
    def apply_recommendation_to_all_hosts : Int32
      success_count = 0
      
      @connections.each_key do |connection_key|
        host, port = connection_key.split(":")
        port_number = port.to_i
        
        if apply_recommendation_to_host(host, port_number)
          success_count += 1
        end
      end
      
      success_count
    end
    
    # バッテリー情報を更新
      private def update_battery_info    # OSごとにバッテリー情報を取得    case RUBY_PLATFORM    when /win32|mingw/      update_battery_info_windows    when /darwin/      update_battery_info_macos    when /linux/      update_battery_info_linux    else      # 対応していないプラットフォームの場合、デフォルト値を設定      @battery_level = 1.0      @is_charging = true    end  end    private def update_battery_info_windows    begin      # WindowsのPowerCFG.exeコマンドを使用してバッテリー情報を取得      output = `powercfg /batteryreport /format:csv /output:"%TEMP%\\battery_report.csv"`      if File.exists?(ENV["TEMP"] + "\\battery_report.csv")        report_data = File.read(ENV["TEMP"] + "\\battery_report.csv")        lines = report_data.split("\n")                # 最新のバッテリー情報を抽出        current_capacity_line = lines.find { |line| line.include?("BATTERY 1") && line.include?("CURRENT CAPACITY") }        full_capacity_line = lines.find { |line| line.include?("BATTERY 1") && line.include?("DESIGN CAPACITY") }                if current_capacity_line && full_capacity_line          current_capacity = current_capacity_line.split(",")[2].to_i          full_capacity = full_capacity_line.split(",")[2].to_i                    if full_capacity > 0            @battery_level = current_capacity.to_f / full_capacity          end        end                # 充電状態を確認        status_line = lines.find { |line| line.include?("BATTERY 1") && line.include?("STATUS") }        if status_line          @is_charging = status_line.include?("Charging")        end                # 一時ファイルを削除        File.delete(ENV["TEMP"] + "\\battery_report.csv")      end    rescue Exception => e      Log.error { "バッテリー情報取得エラー（Windows）: #{e.message}" }      # エラー時はデフォルト値を設定      @battery_level = 1.0      @is_charging = true    end  end    private def update_battery_info_macos    begin      # macOSのpmsetコマンドを使用してバッテリー情報を取得      output = `pmset -g batt`            # バッテリーレベルの抽出      if output =~ /(\d+)%/        percentage = $1.to_i        @battery_level = percentage / 100.0      end            # 充電状態の確認      @is_charging = output.include?("charging") || output.include?("AC Power")          rescue Exception => e      Log.error { "バッテリー情報取得エラー（macOS）: #{e.message}" }      # エラー時はデフォルト値を設定      @battery_level = 1.0      @is_charging = true    end  end    private def update_battery_info_linux    begin      # Linuxの場合 - /sys/class/powerコマンドを使用      if File.exists?("/sys/class/power_supply/BAT0")        bat_path = "/sys/class/power_supply/BAT0"      elsif File.exists?("/sys/class/power_supply/BAT1")        bat_path = "/sys/class/power_supply/BAT1"      else        # バッテリーが見つからない場合        @battery_level = 1.0        @is_charging = true        return      end            # 現在の容量と最大容量を取得      current_now = File.read("#{bat_path}/charge_now").to_i rescue File.read("#{bat_path}/energy_now").to_i      full_design = File.read("#{bat_path}/charge_full").to_i rescue File.read("#{bat_path}/energy_full").to_i            if full_design > 0        @battery_level = current_now.to_f / full_design      end            # 充電状態を確認      status = File.read("#{bat_path}/status").strip      @is_charging = (status == "Charging" || status == "Full")          rescue Exception => e      Log.error { "バッテリー情報取得エラー（Linux）: #{e.message}" }      # エラー時はデフォルト値を設定      @battery_level = 1.0      @is_charging = true    end  end
      begin
        battery_info = get_system_battery_info
        battery_powered = battery_info[:battery_powered]
        battery_level = battery_info[:battery_level]
        
        Log.debug { "バッテリー情報更新: battery_powered=#{battery_powered}, level=#{(battery_level * 100).round(1)}%" }
        
        @global_metrics.battery_powered = battery_powered
        @global_metrics.battery_level = battery_level
        
        # シグナル強度情報も更新（WiFiまたはモバイル）
        update_signal_strength_info if battery_powered
      rescue ex
        Log.error { "バッテリー情報取得に失敗しました: #{ex.message}" }
      end
    end
    
    # システムのバッテリー情報を取得
    private def get_system_battery_info : {battery_powered: Bool, battery_level: Float64}
      # OSタイプを検出
      os_type = detect_os_type
      
      case os_type
      when :windows
        # Windowsの場合
        get_windows_battery_info
      when :macos
        # macOSの場合
        get_macos_battery_info
      when :linux
        # Linuxの場合
        get_linux_battery_info
      when :android
        # Androidの場合
        get_android_battery_info
      else
        # その他のOSの場合はデフォルト値を使用
        Log.debug { "未サポートのOS：バッテリー情報を取得できません" }
        {battery_powered: false, battery_level: 1.0}
      end
    rescue ex
      Log.error { "バッテリー情報取得中にエラーが発生しました: #{ex.message}" }
      {battery_powered: false, battery_level: 1.0}
    end

    # Windows用バッテリー情報取得の詳細実装
    private def get_windows_battery_info : {battery_powered: Bool, battery_level: Float64}
      battery_powered = false
      battery_level = 1.0
      
      begin
        # WMIコマンドをPowerShellから呼び出す
        # システムバッテリー状態を照会
        command = %(powershell -NoProfile -NonInteractive -Command ")
        command += %(try { )
        command += %($batteries = Get-WmiObject -Class Win32_Battery; )
        command += %(if ($batteries -and $batteries.Count -gt 0) { )
        command += %($batteryStatus = $batteries[0].BatteryStatus; ) # 1=放電中、2=AC電源
        command += %($chargeRemaining = $batteries[0].EstimatedChargeRemaining; )
        command += %(Write-Host "$batteryStatus,$chargeRemaining"; } )
        command += %(else { Write-Host "no_battery"; } )
        command += %(} catch { Write-Host "error: $($_.Exception.Message)" })
        command += %(")
        
        output = IO::Memory.new
        process = Process.new(command, shell: true, output: output)
        status = process.wait
        
        if status.success?
          result = output.to_s.strip
          
          if result == "no_battery"
            # バッテリーがない（デスクトップPCなど）
            battery_powered = false
            battery_level = 1.0
          elsif result.starts_with?("error:")
            # エラーが発生した場合はログに記録
            Log.error { "Windowsバッテリー情報取得エラー: #{result}" }
          else
            # 結果をパース
            parts = result.split(",")
            if parts.size >= 2
              status_code = parts[0].to_i
              charge_level = parts[1].to_i
              
              # BatteryStatus: 1=放電中(バッテリー使用中)、2=AC電源
              battery_powered = status_code == 1
              
              # EstimatedChargeRemaining: 0-100のバッテリー残量
              battery_level = charge_level / 100.0
            end
          end
        else
          # プロセス実行失敗
          Log.error { "Windowsバッテリー情報取得コマンド実行失敗" }
        end
      rescue ex
        Log.error { "Windows バッテリー情報取得エラー: #{ex.message}" }
        # エラー時はデフォルト値を使用
      end
      
      return {battery_powered: battery_powered, battery_level: battery_level}
    end

    # macOS用バッテリー情報取得の詳細実装
    private def get_macos_battery_info : {battery_powered: Bool, battery_level: Float64}
      battery_powered = false
      battery_level = 1.0
      
      begin
        # pmsetコマンドを使用してバッテリー情報を取得
        command = "pmset -g batt"
        output = IO::Memory.new
        process = Process.new(command, shell: true, output: output)
        status = process.wait
        
        if status.success?
          output_str = output.to_s
          
          # 出力フォーマット例:
          # Now drawing from 'Battery Power'
          # -InternalBattery-0 (id=12345)    67%; discharging; 3:21 remaining present: true
          
          # "InternalBattery" 行があればバッテリーが存在
          if output_str.includes?("InternalBattery")
            # 電源の状態を確認
            battery_powered = output_str.includes?("'Battery Power'") || !output_str.includes?("AC Power")
            
            # バッテリー残量を抽出
            if output_str =~ /(\d+)%/
              percentage = $1.to_i
              battery_level = percentage / 100.0
            end
          end
          
          # より詳細な情報を取得するためにIOKit APIの結果も検証
          # これにはシステムの拡張が必要なため、pmsetの結果を主として使用
          ioreg_command = "ioreg -l -n AppleSmartBattery | grep -E '(MaxCapacity|CurrentCapacity)'"
          ioreg_output = IO::Memory.new
          ioreg_process = Process.new(ioreg_command, shell: true, output: ioreg_output)
          
          if ioreg_process.wait.success?
            ioreg_result = ioreg_output.to_s
            
            # 最大容量と現在の容量を抽出
            max_capacity = 0
            current_capacity = 0
            
            if ioreg_result =~ /"MaxCapacity"\s*=\s*(\d+)/
              max_capacity = $1.to_i
            end
            
            if ioreg_result =~ /"CurrentCapacity"\s*=\s*(\d+)/
              current_capacity = $1.to_i
            end
            
            # より正確なバッテリーレベルを計算（もし値が有効なら）
            if max_capacity > 0 && current_capacity > 0
              calculated_level = current_capacity / max_capacity.to_f
              
              # pmsetと大きく異なる場合のみ置き換え（冗長性）
              if (calculated_level - battery_level).abs > 0.05
                battery_level = calculated_level
              end
            end
          end
        end
      rescue ex
        Log.error { "macOS バッテリー情報取得エラー: #{ex.message}" }
        # エラー時はデフォルト値を使用
      end
      
      return {battery_powered: battery_powered, battery_level: battery_level}
    end

    # Linux用バッテリー情報取得の詳細実装
    private def get_linux_battery_info : {battery_powered: Bool, battery_level: Float64}
      battery_powered = false
      battery_level = 1.0
      
      begin
        # /sys/class/powerからバッテリー情報を取得
        if Dir.exists?("/sys/class/power_supply")
          # バッテリーディレクトリの検索
          battery_dirs = Dir.glob("/sys/class/power_supply/BAT*")
          
          if battery_dirs.size > 0
            # 複数のバッテリーがある場合は最初のものを使用
            battery_dir = battery_dirs[0]
            
            # バッテリー状態の確認（Charging, Discharging, Full, Unknown）
            if File.exists?("#{battery_dir}/status")
              status = File.read("#{battery_dir}/status").strip
              battery_powered = (status == "Discharging")
            end
            
            # バッテリー残量の取得方法（capacityファイルがある場合）
            if File.exists?("#{battery_dir}/capacity")
              capacity = File.read("#{battery_dir}/capacity").strip.to_i
              battery_level = capacity / 100.0
            # 代替方法（energy_nowとenergy_fullがある場合）
            elsif File.exists?("#{battery_dir}/energy_now") && File.exists?("#{battery_dir}/energy_full")
              energy_now = File.read("#{battery_dir}/energy_now").strip.to_i
              energy_full = File.read("#{battery_dir}/energy_full").strip.to_i
              battery_level = energy_full > 0 ? energy_now.to_f / energy_full : 1.0
            # さらに代替方法（charge_nowとcharge_fullがある場合）
            elsif File.exists?("#{battery_dir}/charge_now") && File.exists?("#{battery_dir}/charge_full")
              charge_now = File.read("#{battery_dir}/charge_now").strip.to_i
              charge_full = File.read("#{battery_dir}/charge_full").strip.to_i
              battery_level = charge_full > 0 ? charge_now.to_f / charge_full : 1.0
            end
            
            # デバッグ情報の追加
            Log.debug { "Linux バッテリー検出: #{battery_dir}, powered=#{battery_powered}, level=#{battery_level}" }
          else
            # バッテリーが見つからない場合はデスクトップPCと想定
            Log.debug { "Linux バッテリーが見つかりません - デスクトップPCの可能性" }
          end
        else
          Log.debug { "Linux パワーサプライディレクトリが見つかりません" }
        end
      rescue ex
        Log.error { "Linux バッテリー情報取得エラー: #{ex.message}" }
        # エラー時はデフォルト値を使用
      end
      
      return {battery_powered: battery_powered, battery_level: battery_level}
    end

    # Android用バッテリー情報取得
    private def get_android_battery_info : {battery_powered: Bool, battery_level: Float64}
      battery_powered = true  # Androidはほぼ常にバッテリー駆動と想定
      battery_level = 0.5     # デフォルト値
      
      begin
        # Androidのバッテリー情報へのパス
        battery_path = "/sys/class/power_supply/battery"
        
        # 代替パスの可能性
        if !Dir.exists?(battery_path)
          alt_paths = [
            "/sys/class/power_supply/Battery",
            "/sys/class/power_supply/bms",
            "/sys/class/power_supply/main-battery"
          ]
          
          alt_paths.each do |path|
            if Dir.exists?(path)
              battery_path = path
              break
            end
          end
        end
        
        # ステータスチェック
        if File.exists?("#{battery_path}/status")
          status = File.read("#{battery_path}/status").strip
          battery_powered = (status != "Charging" && status != "Full")
        end
        
        # 容量チェック
        if File.exists?("#{battery_path}/capacity")
          capacity = File.read("#{battery_path}/capacity").strip.to_i
          battery_level = capacity / 100.0
        end
        
        Log.debug { "Android バッテリー情報: status=#{status}, level=#{battery_level}" }
      rescue ex
        Log.error { "Android バッテリー情報取得エラー: #{ex.message}" }
      end
      
      return {battery_powered: battery_powered, battery_level: battery_level}
    end
    
    # シグナル強度情報の更新
    private def update_signal_strength_info
      begin
        os_type = detect_os_type
        signal_strength = case os_type
                         when :windows
                           get_windows_signal_strength
                         when :macos
                           get_macos_signal_strength
                         when :linux, :android
                           get_linux_signal_strength
                         else
                           nil
                         end
        
        @global_metrics.signal_strength = signal_strength
        
        if signal_strength
          Log.debug { "ネットワークシグナル強度: #{(signal_strength * 100).round(1)}%" }
        end
      rescue ex
        Log.error { "シグナル強度取得中にエラーが発生しました: #{ex.message}" }
      end
    end

    # OSタイプを検出
    private def detect_os_type : Symbol
      {% if flag?(:win32) %}
        return :windows
      {% elsif flag?(:darwin) %}
        return :macos
      {% elsif flag?(:linux) %}
        # Androidの場合はさらに検出が必要
        if File.exists?("/system/build.prop") || Dir.exists?("/system/app") || Dir.exists?("/system/priv-app")
          return :android
        end
        return :linux
      {% else %}
        return :unknown
      {% end %}
    end

    # Windows用シグナル強度取得
    private def get_windows_signal_strength : Float64?
      begin
        # PowerShellでWiFiシグナル強度を取得
        command = "powershell -Command \"(netsh wlan show interfaces) | Select-String 'Signal' | ForEach-Object { $_.ToString().Split(':')[1].Trim().Replace('%', '') }\""
        output = IO::Memory.new
        process = Process.new(command, shell: true, output: output)
        status = process.wait
        
        if status.success?
          signal_str = output.to_s.strip
          if signal_str =~ /\d+/
            signal_percent = signal_str.to_i
            return signal_percent / 100.0
          end
        end
      rescue ex
        Log.error { "Windows シグナル強度取得エラー: #{ex.message}" }
      end
      
      return nil
    end
    
    # macOS用シグナル強度取得
    private def get_macos_signal_strength : Float64?
      begin
        # airport コマンドを使用してWiFiシグナル強度を取得
        command = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | grep agrCtlRSSI | awk '{print $2}'"
        output = IO::Memory.new
        process = Process.new(command, shell: true, output: output)
        status = process.wait
        
        if status.success?
          rssi_str = output.to_s.strip
          if rssi_str =~ /-?\d+/
            rssi = rssi_str.to_i
            # RSSIを0-1の範囲に変換（-30dBm = 最大、-90dBm = 最小）
            signal_strength = (rssi.to_f + 90) / 60
            return [1.0, [0.0, signal_strength].max].min
          end
        end
      rescue ex
        Log.error { "macOS シグナル強度取得エラー: #{ex.message}" }
      end
      
      return nil
    end
    
    # Linux/Android用シグナル強度取得
    private def get_linux_signal_strength : Float64?
      begin
        # iw コマンドを使用してWiFiシグナル強度を取得
        command = "iw dev | grep -A 5 'Interface' | grep 'signal' | awk '{print $2}'"
        output = IO::Memory.new
        process = Process.new(command, shell: true, output: output)
        status = process.wait
        
        if status.success?
          signal_str = output.to_s.strip
          if signal_str =~ /-?\d+/
            # dBm値をパース
            dbm = signal_str.to_i
            # dBmを0-1の範囲に変換（-30dBm = 最大、-90dBm = 最小）
            signal_strength = (dbm.to_f + 90) / 60
            return [1.0, [0.0, signal_strength].max].min
          end
        end
        
        # WiFi情報が取得できなかった場合はモバイルネットワークを確認
        if File.exists?("/sys/class/net/wwan0") || Dir.exists?("/dev/cdc-wdm0")
          # モバイルネットワークのシグナル強度を取得
          command = "mmcli -m 0 | grep 'signal quality' | awk '{print $4}'"
          output = IO::Memory.new
          process = Process.new(command, shell: true, output: output)
          status = process.wait
          
          if status.success?
            signal_str = output.to_s.strip
            if signal_str =~ /\d+/
              signal_percent = signal_str.to_i
              return signal_percent / 100.0
            end
          end
        end
      rescue ex
        Log.error { "Linux シグナル強度取得エラー: #{ex.message}" }
      end
      
      return nil
    end
    
    # 定期的なメトリクス更新
    private def update_metrics
      # HTTP/3マネージャから統計情報を取得
      stats = @http3_manager.get_stats
      
      # アクティブな接続数を更新
      @global_metrics.active_connections = stats.active_connections
      
      # 現在のアクティブホストを更新
      @connections.each_value do |connection|
        connection.is_active = false
      end
      
      # その他の統計情報更新
      # 実装の詳細に応じて追加
      
      @last_update_time = Time.utc
    end
  end
end 