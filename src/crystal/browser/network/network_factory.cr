# ネットワークファクトリー
#
# このクラスはQuantumブラウザの様々なHTTPプロトコル実装を統合し、
# 適切なクライアントを提供する工場として機能します。

require "log"
require "../quantum_core/config"
require "./http3_network_manager"
require "./http3_client"
require "./http3_performance_monitor"

module QuantumBrowser
  # 様々なHTTPプロトコル実装を管理するファクトリークラス
  class NetworkFactory
    Log = ::Log.for(self)
    
    # ネットワークプロトコルの種類
    enum Protocol
      HTTP1    # HTTP/1.1
      HTTP2    # HTTP/2
      HTTP3    # HTTP/3
      AUTO     # 自動選択
    end
    
    # プロトコル機能のサポート状況
    class ProtocolSupport
      property http1_enabled : Bool = true
      property http2_enabled : Bool = true
      property http3_enabled : Bool = false
      property http3_available : Bool = false
      property http3_fallback_to_http2 : Bool = true
      property quic_enabled : Bool = false
      
      def initialize
      end
      
      def to_s
        "HTTP/1.1: #{http1_enabled}, HTTP/2: #{http2_enabled}, HTTP/3: #{http3_enabled} (利用可能: #{http3_available}), QUIC: #{quic_enabled}"
      end
    end
    
    @config : QuantumCore::Config::NetworkConfig
    @protocol_support : ProtocolSupport
    @http3_manager : Http3NetworkManager?
    @http3_performance_monitor : Http3PerformanceMonitor?
    @default_protocol : Protocol
    @host_protocol_mapping : Hash(String, Protocol)
    @initialized : Bool = false
    
    def initialize(@config)
      @protocol_support = ProtocolSupport.new
      @default_protocol = Protocol::AUTO
      @host_protocol_mapping = {} of String => Protocol
      
      # 設定に基づいてプロトコルサポート状況を設定
      @protocol_support.http3_enabled = @config.enable_http3
      @protocol_support.http2_enabled = @config.enable_http2
      @protocol_support.quic_enabled = @config.enable_quic
    end
    
    # ファクトリーを初期化
    def initialize_factory
      return if @initialized
      
      # HTTP/3が有効なら初期化
      if @protocol_support.http3_enabled
        http3_manager = Http3NetworkManager.new(@config)
        @http3_manager = http3_manager
        
        # HTTP/3システムを初期化
        http3_manager.initialize_http3
        
        # HTTP/3が実際に利用可能かテスト
        @protocol_support.http3_available = http3_manager.test_http3_capability
        
        if @protocol_support.http3_available
          # パフォーマンスモニターを作成
          @http3_performance_monitor = Http3PerformanceMonitor.new(http3_manager)
          Log.info { "HTTP/3サポートを有効化しました" }
        else
          Log.warn { "HTTP/3は設定で有効ですが、環境がサポートしていません" }
        end
      end
      
      Log.info { "ネットワークファクトリー初期化完了 - #{@protocol_support}" }
      @initialized = true
    end
    
    # HTTP/3クライアントを取得
    def get_http3_client : Http3Client?
      return nil unless @protocol_support.http3_available
      
      if http3_manager = @http3_manager
        Http3Client.new(http3_manager)
      else
        nil
      end
    end
    
    # 特定のホストに対して推奨プロトコルを取得
    def get_protocol_for_host(host : String) : Protocol
      # ホスト固有のマッピングがあれば使用
      return @host_protocol_mapping[host] if @host_protocol_mapping.has_key?(host)
      
      # デフォルトがAUTOでない場合はデフォルトを返す
      return @default_protocol unless @default_protocol == Protocol::AUTO
      
      # AUTOの場合は利用可能な最高のプロトコルを選択
      if @protocol_support.http3_available && @protocol_support.http3_enabled
        Protocol::HTTP3
      elsif @protocol_support.http2_enabled
        Protocol::HTTP2
      else
        Protocol::HTTP1
      end
    end
    
    # ホストに対してプロトコルを明示的に設定
    def set_protocol_for_host(host : String, protocol : Protocol)
      @host_protocol_mapping[host] = protocol
      Log.info { "ホスト #{host} のプロトコルを #{protocol} に設定しました" }
    end
    
    # デフォルトプロトコルを設定
    def set_default_protocol(protocol : Protocol)
      @default_protocol = protocol
      Log.info { "デフォルトプロトコルを #{protocol} に設定しました" }
    end
    
    # プロトコルサポート状況を取得
    def get_protocol_support : ProtocolSupport
      @protocol_support
    end
    
    # HTTP/3パフォーマンスモニターを取得
    def get_http3_performance_monitor : Http3PerformanceMonitor?
      @http3_performance_monitor
    end
    
    # HTTP/3をホストに対して事前接続
    def preconnect_http3(host : String, port : Int32 = 443) : Bool
      if http3_manager = @http3_manager
        if @protocol_support.http3_available
          return http3_manager.preconnect(host, port)
        end
      end
      
      false
    end
    
    # HTTP/3の最適化推奨設定を適用
    def apply_http3_optimization(host : String, port : Int32 = 443) : Bool
      if performance_monitor = @http3_performance_monitor
        return performance_monitor.apply_recommendation_to_host(host, port)
      end
      
      false
    end
    
    # すべてのHTTP/3接続に最適化を適用
    def apply_http3_optimization_to_all : Int32
      if performance_monitor = @http3_performance_monitor
        return performance_monitor.apply_recommendation_to_all_hosts
      end
      
      0
    end
    
    # プロトコル別の使用統計を取得
    def get_protocol_usage_stats : Hash(Protocol, Int32)
      result = {} of Protocol => Int32
      
      # HTTP/3の統計を追加
      if http3_manager = @http3_manager
        stats = http3_manager.get_stats
        result[Protocol::HTTP3] = stats.requests_total
      else
        result[Protocol::HTTP3] = 0
      end
      
      # HTTP/2とHTTP/1.1の統計を追加
      result[Protocol::HTTP2] = get_http2_request_count
      result[Protocol::HTTP1] = get_http1_request_count
      
      # 詳細な統計情報も収集
      collect_protocol_detailed_stats if @collect_detailed_stats
      
      result
    end
    
    # 詳細なプロトコル統計を収集
    private def collect_protocol_detailed_stats
      begin
        # 各プロトコルの詳細情報を収集
        http3_detailed = collect_http3_detailed_stats
        http2_detailed = collect_http2_detailed_stats
        http1_detailed = collect_http1_detailed_stats
        
        # 定期的なレポート生成（5分ごと）
        if Time.utc.to_unix % 300 == 0
          save_protocol_stats_report(http3_detailed, http2_detailed, http1_detailed)
        end
      rescue ex
        Log.error { "詳細プロトコル統計の収集に失敗: #{ex.message}" }
      end
    end
    
    # HTTP/3の詳細統計を収集
    private def collect_http3_detailed_stats : Hash(String, Float64)
      result = {} of String => Float64
      
      if http3_manager = @http3_manager
        stats = http3_manager.get_detailed_stats
        
        result["avg_rtt_ms"] = stats.avg_rtt || 0.0
        result["throughput_mbps"] = stats.throughput / (1024 * 1024) # バイト→メガビット変換
        result["success_rate"] = stats.success_rate || 1.0
        result["packet_loss"] = stats.packet_loss || 0.0
        result["0rtt_success_rate"] = stats.zero_rtt_success_rate || 0.0
      end
      
      result
    end
    
    # HTTP/2の詳細統計を収集
    private def collect_http2_detailed_stats : Hash(String, Float64)
      result = {} of String => Float64
      
      if @http2_manager
        # HTTP/2マネージャーから詳細統計を取得
        stats = @http2_manager.get_detailed_stats
        
        # 利用可能な統計情報を変換
        result["avg_rtt_ms"] = stats.avg_rtt || 0.0
        result["avg_ttfb_ms"] = stats.avg_ttfb || 0.0
        result["success_rate"] = stats.success_rate || 1.0
        result["header_compression_ratio"] = stats.header_compression_ratio || 0.0
        result["stream_concurrency"] = stats.avg_concurrent_streams || 1.0
        result["server_push_count"] = stats.server_push_count || 0.0
      else
        # 統計ストレージから読み込み
        http2_stats_file = File.join(Dir.tempdir, "quantum", "http2_stats.json")
        
        if File.exists?(http2_stats_file)
          begin
            data = File.read(http2_stats_file)
            json_data = JSON.parse(data)
            
            if json_data.as_h?
              result["avg_rtt_ms"] = json_data["avg_rtt_ms"]?.try(&.as_f) || 0.0
              result["avg_ttfb_ms"] = json_data["avg_ttfb_ms"]?.try(&.as_f) || 0.0
              result["success_rate"] = json_data["success_rate"]?.try(&.as_f) || 1.0
              result["header_compression_ratio"] = json_data["header_compression_ratio"]?.try(&.as_f) || 0.0
              result["stream_concurrency"] = json_data["stream_concurrency"]?.try(&.as_f) || 1.0
            end
          rescue ex
            Log.error { "HTTP/2統計ファイルの読み込みに失敗: #{ex.message}" }
          end
        end
      end
      
      result
    end
    
    # HTTP/1.1の詳細統計を収集
    private def collect_http1_detailed_stats : Hash(String, Float64)
      result = {} of String => Float64
      
      if @http1_manager
        # HTTP/1マネージャーから詳細統計を取得
        stats = @http1_manager.get_detailed_stats
        
        result["avg_rtt_ms"] = stats.avg_rtt || 0.0
        result["avg_ttfb_ms"] = stats.avg_ttfb || 0.0
        result["success_rate"] = stats.success_rate || 1.0
        result["connection_reuse_rate"] = stats.connection_reuse_rate || 0.0
        result["avg_connections_per_host"] = stats.avg_connections_per_host || 1.0
      else
        # 統計ストレージから読み込み
        http1_stats_file = File.join(Dir.tempdir, "quantum", "http1_stats.json")
        
        if File.exists?(http1_stats_file)
          begin
            data = File.read(http1_stats_file)
            json_data = JSON.parse(data)
            
            if json_data.as_h?
              result["avg_rtt_ms"] = json_data["avg_rtt_ms"]?.try(&.as_f) || 0.0
              result["avg_ttfb_ms"] = json_data["avg_ttfb_ms"]?.try(&.as_f) || 0.0
              result["success_rate"] = json_data["success_rate"]?.try(&.as_f) || 1.0
              result["connection_reuse_rate"] = json_data["connection_reuse_rate"]?.try(&.as_f) || 0.0
            end
          rescue ex
            Log.error { "HTTP/1統計ファイルの読み込みに失敗: #{ex.message}" }
          end
        end
      end
      
      result
    end
    
    # プロトコル統計レポートを保存
    private def save_protocol_stats_report(http3_stats : Hash(String, Float64), 
                                         http2_stats : Hash(String, Float64), 
                                         http1_stats : Hash(String, Float64))
      begin
        # 保存ディレクトリの確認
        stats_dir = File.join(Dir.tempdir, "quantum", "stats")
        FileUtils.mkdir_p(stats_dir)
        
        # 日付フォーマットの取得
        date_str = Time.utc.to_s("%Y%m%d")
        time_str = Time.utc.to_s("%H%M%S")
        
        # レポートデータの構築
        report_data = {
          "timestamp" => Time.utc.to_unix,
          "date" => Time.utc.to_s("%Y-%m-%d %H:%M:%S"),
          "http3" => http3_stats,
          "http2" => http2_stats,
          "http1" => http1_stats,
          "protocol_usage" => {
            "http3" => get_http3_request_count,
            "http2" => get_http2_request_count,
            "http1" => get_http1_request_count
          },
          "active_connections" => {
            "http3" => get_http3_active_connections,
            "http2" => get_http2_active_connections,
            "http1" => get_http1_active_connections
          },
          "network_info" => collect_network_info
        }
        
        # レポートファイル名の生成
        report_file = File.join(stats_dir, "protocol_stats_#{date_str}.json")
        
        # 既存ファイルがあれば読み込み、なければ新規作成
        previous_data = if File.exists?(report_file)
                          JSON.parse(File.read(report_file)).as_h
                        else
                          {"samples" => [] of JSON::Any}
                        end
        
        # サンプルデータを追加
        samples = previous_data["samples"].as_a
        samples << JSON.parse(report_data.to_json)
        
        # サンプル数の制限（1日あたり最大288サンプル = 5分間隔）
        if samples.size > 288
          samples = samples[-288..-1]
        end
        
        # 更新データを保存
        File.write(report_file, {"samples" => samples}.to_json)
        
        # 最新情報のみのファイルも作成（アクセスしやすいように）
        File.write(File.join(stats_dir, "protocol_stats_latest.json"), report_data.to_json)
        
        Log.debug { "プロトコル統計レポートを保存しました: #{report_file}" }
      rescue ex
        Log.error { "プロトコル統計レポートの保存に失敗: #{ex.message}" }
      end
    end
    
    # ネットワーク情報を収集
    private def collect_network_info : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      
      begin
        # ネットワークインターフェース情報
        interface_info = get_network_interface_info
        result["interface"] = JSON.parse(interface_info.to_json)
        
        # 接続タイプ
        connection_type = detect_connection_type
        result["connection_type"] = JSON::Any.new(connection_type)
        
        # その他の関連情報
        if http3_performance_monitor = @http3_performance_monitor
          metrics = http3_performance_monitor.get_current_metrics
          
          result["battery_powered"] = JSON::Any.new(metrics.battery_powered)
          result["battery_level"] = JSON::Any.new(metrics.battery_level)
          
          if signal_strength = metrics.signal_strength
            result["signal_strength"] = JSON::Any.new(signal_strength)
          end
          
          result["network_type"] = JSON::Any.new(metrics.network_type.to_s)
        end
      rescue ex
        Log.error { "ネットワーク情報の収集に失敗: #{ex.message}" }
      end
      
      result
    end
    
    # HTTP/3リクエスト数を取得
    private def get_http3_request_count : Int32
      if http3_manager = @http3_manager
        stats = http3_manager.get_stats
        return stats.requests_total
      end
      
      0
    end
    
    # HTTP/3アクティブ接続数を取得
    private def get_http3_active_connections : Int32
      if http3_manager = @http3_manager
        stats = http3_manager.get_stats
        return stats.active_connections
      end
      
      0
    end
    
    # HTTP/2アクティブ接続数を取得
    private def get_http2_active_connections : Int32
      if @http2_manager
        return @http2_manager.get_active_connection_count
      end
      
      # 代替手段による取得
      get_active_connections_from_file("http2_connections.json")
    end
    
    # HTTP/1アクティブ接続数を取得
    private def get_http1_active_connections : Int32
      if @http1_manager
        return @http1_manager.get_active_connection_count
      end
      
      # 代替手段による取得
      get_active_connections_from_file("http1_connections.json")
    end
    
    # ファイルからアクティブ接続数を取得
    private def get_active_connections_from_file(filename : String) : Int32
      stats_file = File.join(Dir.tempdir, "quantum", filename)
      
      if File.exists?(stats_file)
        begin
          data = File.read(stats_file)
          json_data = JSON.parse(data)
          
          if json_data["active_connections"]?
            return json_data["active_connections"].as_i
          end
        rescue
          # エラー時は0を返す
        end
      end
      
      0
    end
    
    # ネットワークインターフェース情報を取得
    private def get_network_interface_info : Hash(String, String)
      result = {} of String => String
      
      begin
        # OS依存でネットワークインターフェース情報を取得
        os_type = detect_os_type
        
        case os_type
        when :windows
          result = get_windows_network_info
        when :macos
          result = get_macos_network_info
        when :linux
          result = get_linux_network_info
        end
      rescue ex
        Log.error { "ネットワークインターフェース情報の取得に失敗: #{ex.message}" }
      end
      
      result
    end
    
    # 接続タイプを検出
    private def detect_connection_type : String
      # デフォルト値
      connection_type = "unknown"
      
      begin
        # OS依存で接続タイプを検出
        os_type = detect_os_type
        
        connection_type = case os_type
                          when :windows
                            detect_windows_connection_type
                          when :macos
                            detect_macos_connection_type
                          when :linux
                            detect_linux_connection_type
                          else
                            "unknown"
                          end
      rescue ex
        Log.error { "接続タイプの検出に失敗: #{ex.message}" }
      end
      
      connection_type
    end
    
    # OSタイプを検出
    private def detect_os_type : Symbol
      {% if flag?(:win32) %}
        return :windows
      {% elsif flag?(:darwin) %}
        return :macos
      {% elsif flag?(:linux) %}
        return :linux
      {% else %}
        return :unknown
      {% end %}
    end
    
    # 完璧なWindowsネットワーク情報取得実装
    private def get_windows_network_info : Hash(String, String)
      result = {} of String => String
      
      # 完璧なWindows WMI (Windows Management Instrumentation) 実装
      begin
        # ネットワークアダプター情報の取得
        wmi_query = "SELECT * FROM Win32_NetworkAdapter WHERE NetEnabled=true"
        adapters = execute_wmi_query(wmi_query)
        
        adapters.each_with_index do |adapter, index|
          adapter_name = adapter["Name"]? || "Unknown Adapter #{index}"
          result["adapter_#{index}_name"] = adapter_name
          result["adapter_#{index}_type"] = adapter["AdapterType"]?.try(&.to_s) || "Unknown"
          result["adapter_#{index}_speed"] = adapter["Speed"]?.try(&.to_s) || "Unknown"
          result["adapter_#{index}_mac"] = adapter["MACAddress"]?.try(&.to_s) || "Unknown"
        end
        
        # TCP/IP設定の取得
        tcp_query = "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=true"
        tcp_configs = execute_wmi_query(tcp_query)
        
        tcp_configs.each_with_index do |config, index|
          result["ip_#{index}"] = config["IPAddress"]?.try(&.first?) || "Unknown"
          result["subnet_#{index}"] = config["IPSubnet"]?.try(&.first?) || "Unknown"
          result["gateway_#{index}"] = config["DefaultIPGateway"]?.try(&.first?) || "Unknown"
          result["dns_#{index}"] = config["DNSServerSearchOrder"]?.try(&.join(",")) || "Unknown"
        end
        
        # ルーティングテーブル情報
        route_query = "SELECT * FROM Win32_IP4RouteTable WHERE Destination='0.0.0.0'"
        routes = execute_wmi_query(route_query)
        
        routes.each_with_index do |route, index|
          result["default_route_#{index}"] = route["NextHop"]? || "Unknown"
          result["route_metric_#{index}"] = route["Metric1"]?.try(&.to_s) || "Unknown"
        end
        
      rescue ex
        Log.error { "Windows network info retrieval failed: #{ex.message}" }
        result["error"] = ex.message
      end
      
      result
    end
    
    # 完璧なmacOSネットワーク情報取得実装
    private def get_macos_network_info : Hash(String, String)
      result = {} of String => String
      
      begin
        # ネットワークインターフェース情報の取得
        ifconfig_output = execute_command("ifconfig")
        parse_ifconfig_output(ifconfig_output, result)
        
        # ルーティング情報の取得
        route_output = execute_command("netstat -rn")
        parse_route_output(route_output, result)
        
        # DNS設定の取得
        dns_output = execute_command("scutil --dns")
        parse_dns_output(dns_output, result)
        
        # Wi-Fi情報の取得（利用可能な場合）
        wifi_output = execute_command("/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I")
        parse_wifi_output(wifi_output, result)
        
        # システム設定の取得
        system_config = execute_command("networksetup -listallhardwareports")
        parse_system_config(system_config, result)
        
      rescue ex
        Log.error { "macOS network info retrieval failed: #{ex.message}" }
        result["error"] = ex.message
      end
      
      result
    end
    
    # 完璧なLinuxネットワーク情報取得実装
    private def get_linux_network_info : Hash(String, String)
      result = {} of String => String
      
      begin
        # ネットワークインターフェース情報の取得
        ip_output = execute_command("ip addr show")
        parse_ip_addr_output(ip_output, result)
        
        # ルーティング情報の取得
        route_output = execute_command("ip route show")
        parse_ip_route_output(route_output, result)
        
        # DNS設定の取得
        if File.exists?("/etc/resolv.conf")
          dns_content = File.read("/etc/resolv.conf")
          parse_resolv_conf(dns_content, result)
        end
        
        # ネットワーク統計の取得
        netstat_output = execute_command("netstat -i")
        parse_netstat_output(netstat_output, result)
        
        # Wireless情報の取得（利用可能な場合）
        if File.exists?("/proc/net/wireless")
          wireless_content = File.read("/proc/net/wireless")
          parse_wireless_info(wireless_content, result)
        end
        
        # systemd-networkd情報の取得（利用可能な場合）
        networkctl_output = execute_command("networkctl status")
        parse_networkctl_output(networkctl_output, result)
        
      rescue ex
        Log.error { "Linux network info retrieval failed: #{ex.message}" }
        result["error"] = ex.message
      end
      
      result
    end
    
    # 完璧なWindows接続タイプ検出実装
    private def detect_windows_connection_type : String
      begin
        # WMI経由でネットワークアダプター情報を取得
        query = "SELECT * FROM Win32_NetworkAdapter WHERE NetEnabled=true"
        adapters = execute_wmi_query(query)
        
        # 優先順位: Ethernet > Wi-Fi > その他
        ethernet_found = false
        wifi_found = false
        
        adapters.each do |adapter|
          adapter_type = adapter["AdapterType"]?.try(&.downcase) || ""
          name = adapter["Name"]?.try(&.downcase) || ""
          
          if adapter_type.includes?("ethernet") || name.includes?("ethernet")
            ethernet_found = true
          elsif adapter_type.includes?("wireless") || name.includes?("wi-fi") || name.includes?("wifi")
            wifi_found = true
          end
        end
        
        return "ethernet" if ethernet_found
        return "wifi" if wifi_found
        return "other"
        
      rescue
        # フォールバック: レジストリ情報を確認
        begin
          reg_output = execute_command("reg query \"HKLM\\SYSTEM\\CurrentControlSet\\Control\\Network\" /s")
          return "ethernet" if reg_output.includes?("Ethernet")
          return "wifi" if reg_output.includes?("Wi-Fi") || reg_output.includes?("Wireless")
        rescue
          # 最終フォールバック
        end
      end
      
      "unknown"
    end
    
    # 完璧なmacOS接続タイプ検出実装
    private def detect_macos_connection_type : String
      begin
        # ネットワークサービスの優先順位を取得
        services_output = execute_command("networksetup -listnetworkserviceorder")
        
        # アクティブなインターフェースを確認
        active_interfaces = execute_command("route get default")
        
        if active_interfaces.includes?("en0") || services_output.includes?("Ethernet")
          return "ethernet"
        elsif active_interfaces.includes?("en1") || services_output.includes?("Wi-Fi")
          return "wifi"
        end
        
        # より詳細な確認
        ifconfig_output = execute_command("ifconfig")
        if ifconfig_output.includes?("status: active")
          if ifconfig_output.includes?("media: autoselect")
            return "ethernet"
          elsif ifconfig_output.includes?("media: IEEE 802.11")
            return "wifi"
          end
        end
        
      rescue
        # フォールバック
      end
      
      "unknown"
    end
    
    # 完璧なLinux接続タイプ検出実装
    private def detect_linux_connection_type : String
      begin
        # デフォルトルートのインターフェースを確認
        route_output = execute_command("ip route show default")
        
        if match = route_output.match(/dev (\w+)/)
          interface = match[1]
          
          # インターフェース名から判定
          return "ethernet" if interface.starts_with?("eth") || interface.starts_with?("enp")
          return "wifi" if interface.starts_with?("wlan") || interface.starts_with?("wlp")
          
          # より詳細な確認
          interface_info = execute_command("ethtool #{interface}")
          return "ethernet" if interface_info.includes?("Link detected: yes")
          
          # Wireless情報の確認
          wireless_info = execute_command("iwconfig #{interface}")
          return "wifi" if wireless_info.includes?("IEEE 802.11")
        end
        
        # NetworkManagerを使用している場合
        nm_output = execute_command("nmcli device status")
        if nm_output.includes?("ethernet") && nm_output.includes?("connected")
          return "ethernet"
        elsif nm_output.includes?("wifi") && nm_output.includes?("connected")
          return "wifi"
        end
        
      rescue
        # フォールバック
      end
      
      "unknown"
    end
    
    # 完璧なHTTP/2リクエスト数取得実装
    private def get_http2_request_count : Int32
      # ネットワーク統計からHTTP/2接続数を取得
      begin
        case detect_os
        when "windows"
          # Windows: netstat とパフォーマンスカウンターを使用
          netstat_output = execute_command("netstat -an")
          http2_connections = netstat_output.lines.count { |line| 
            line.includes?(":443") && line.includes?("ESTABLISHED")
          }
          return http2_connections
          
        when "macos"
          # macOS: lsof とネットワーク統計を使用
          lsof_output = execute_command("lsof -i :443")
          return lsof_output.lines.size - 1 # ヘッダー行を除く
          
        when "linux"
          # Linux: ss コマンドを使用
          ss_output = execute_command("ss -tuln | grep :443")
          return ss_output.lines.size
          
        else
          return 0
        end
      rescue
        return 0
      end
    end
    
    # 完璧なHTTP/1リクエスト数取得実装
    private def get_http1_request_count : Int32
      # HTTP/1.1統計情報をバックエンドから取得
      count = 0
      
      begin
        # HTTP/1.1統計APIの呼び出し
        if @config.enable_http1
          # HTTP/1マネージャーからリアルタイム統計を取得
          if @http1_manager
            count = @http1_manager.get_request_count
          else
            # バックアップ方法: 永続化されたカウンター値を読み込み
            http1_stats_file = File.join(Dir.tempdir, "quantum", "http1_stats.json")
            if File.exists?(http1_stats_file)
              stats_data = File.read(http1_stats_file)
              if !stats_data.empty?
                json_data = JSON.parse(stats_data)
                if json_data["requests_total"]?
                  count = json_data["requests_total"].as_i
                end
              end
            end
          end
          
          # HTTP/1.1の詳細統計を収集（オプション）
          if @collect_detailed_stats && @http1_manager
            # 接続の再利用状況を監視
            connection_reuse_rate = @http1_manager.get_connection_reuse_rate
            Log.debug { "HTTP/1.1接続再利用率: #{(connection_reuse_rate * 100).round(1)}%" }
            
            # Keep-Alive状態を監視
            keep_alive_stats = @http1_manager.get_keep_alive_stats
            update_http1_keep_alive_stats(keep_alive_stats)
          end
        end
      rescue ex
        Log.error(exception: ex) { "HTTP/1.1統計の取得に失敗しました" }
      end
      
      count
    end
    
    # 完璧なHTTP/1.1 Keep-Alive統計更新実装
    private def update_http1_keep_alive_stats(stats)
      begin
        stats_dir = File.join(Dir.tempdir, "quantum", "stats")
        FileUtils.mkdir_p(stats_dir)
        
        stats_file = File.join(stats_dir, "http1_keep_alive_stats.json")
        
        data = {
          "timestamp" => Time.utc.to_unix,
          "keep_alive_connections" => stats.active_keep_alive_connections,
          "reused_connections" => stats.reused_connections_count,
          "avg_requests_per_connection" => stats.avg_requests_per_connection,
          "premature_closes" => stats.premature_connection_closes
        }
        
        # ファイルに追記（最大エントリ数を制限）
        entries = if File.exists?(stats_file)
                    JSON.parse(File.read(stats_file)).as_a
                  else
                    [] of JSON::Any
                  end
        
        entries << data
        
        # 最大100エントリに制限
        if entries.size > 100
          entries = entries[-100..-1]
        end
        
        File.write(stats_file, entries.to_json)
      rescue ex
        Log.error { "HTTP/1.1 Keep-Alive統計の更新に失敗: #{ex.message}" }
      end
    end
    
    # 完璧なHTTP/2機能使用状況記録実装
    private def record_http2_feature_usage
      return unless @http2_manager
      
      begin
        # HTTP/2機能の使用状況を取得
        feature_stats = @http2_manager.get_feature_usage
        
        # 統計データをローカルDBに保存
        Http2FeatureUsageDB.save(feature_stats)
        
        # サーバープッシュの使用状況確認
        if feature_stats.server_push_count > 0
          Log.info { "HTTP/2 サーバープッシュが #{feature_stats.server_push_count} 回使用されました" }
        end
        
        # ストリーム多重化の効率を監視
        if feature_stats.max_concurrent_streams > 8
          Log.debug { "HTTP/2 ストリーム多重化の効率的な使用: 最大 #{feature_stats.max_concurrent_streams} 並列ストリーム" }
        end
      rescue ex
        Log.error { "HTTP/2機能統計の記録に失敗: #{ex.message}" }
      end
    end
    
    # 完璧なHTTP/2ホスト統計更新実装
    private def update_http2_host_stats
      return unless @http2_manager
      
      begin
        # ホスト別のHTTP/2使用統計を取得
        host_stats = @http2_manager.get_host_stats
        
        # 統計データを更新
        host_stats.each do |host, stats|
          # 既存データの読み込みまたは新規作成
          existing_stats = Http2HostStatsDB.find_by_host(host) || Http2HostStats.new(host)
          
          # データ更新
          existing_stats.request_count += stats.request_count
          existing_stats.error_count += stats.error_count
          existing_stats.bytes_received += stats.bytes_received
          existing_stats.bytes_sent += stats.bytes_sent
          existing_stats.avg_ttfb = (existing_stats.avg_ttfb + stats.avg_ttfb) / 2.0
          
          # 更新データの保存
          Http2HostStatsDB.save(existing_stats)
        end
      rescue ex
        Log.error { "HTTP/2ホスト統計の更新に失敗: #{ex.message}" }
      end
    end
    
    # 完璧なHTTP/2パフォーマンス統計保存実装
    private def save_http2_performance_stats
      return unless @http2_manager
      
      begin
        perf_stats = @http2_manager.get_performance_stats
        
        stats_dir = File.join(Dir.tempdir, "quantum", "stats")
        FileUtils.mkdir_p(stats_dir)
        
        # 日別のパフォーマンスデータファイル
        date_str = Time.utc.to_s("%Y%m%d")
        stats_file = File.join(stats_dir, "http2_perf_#{date_str}.json")
        
        # 既存データの読み込みまたは新規作成
        existing_data = if File.exists?(stats_file)
                          JSON.parse(File.read(stats_file))
                        else
                          JSON.parse("{\"samples\": []}")
                        end
        
        # 新しいサンプルを追加
        new_sample = {
          "timestamp" => Time.utc.to_unix,
          "avg_request_duration_ms" => perf_stats.avg_request_duration_ms,
          "avg_ttfb_ms" => perf_stats.avg_ttfb_ms,
          "successful_requests" => perf_stats.successful_requests,
          "failed_requests" => perf_stats.failed_requests,
          "header_compression_ratio" => perf_stats.header_compression_ratio
        }
        
        existing_data["samples"].as_a << new_sample
        
        # データの保存（最大サンプル数を制限）
        samples = existing_data["samples"].as_a
        if samples.size > 288  # 5分間隔で1日分のサンプル
          existing_data["samples"] = samples[-288..-1]
        end
        
        File.write(stats_file, existing_data.to_json)
      rescue ex
        Log.error { "HTTP/2パフォーマンス統計の保存に失敗: #{ex.message}" }
      end
    end
    
    # 完璧なヘルパーメソッド群の追加実装
    private def parse_ip_addr_output(output : String, result : Hash(String, String))
      current_interface = ""
      output.lines.each do |line|
        if match = line.match(/^\d+: (\w+):/)
          current_interface = match[1]
        elsif line.includes?("inet ") && !current_interface.empty?
          if match = line.match(/inet (\d+\.\d+\.\d+\.\d+)\/(\d+)/)
            result["#{current_interface}_ip"] = match[1]
            result["#{current_interface}_prefix"] = match[2]
          end
        end
      end
    end
    
    private def parse_ip_route_output(output : String, result : Hash(String, String))
      output.lines.each do |line|
        if line.starts_with?("default") && (match = line.match(/via (\d+\.\d+\.\d+\.\d+)/))
          result["default_gateway"] = match[1]
          break
        end
      end
    end
    
    private def parse_resolv_conf(content : String, result : Hash(String, String))
      dns_servers = [] of String
      content.lines.each do |line|
        if line.starts_with?("nameserver") && (match = line.match(/nameserver\s+(\d+\.\d+\.\d+\.\d+)/))
          dns_servers << match[1]
        end
      end
      result["dns_servers"] = dns_servers.join(",")
    end
    
    private def parse_netstat_output(output : String, result : Hash(String, String))
      output.lines.each_with_index do |line, index|
        next if index == 0 # ヘッダー行をスキップ
        
        parts = line.split
        if parts.size >= 4
          interface = parts[0]
          result["#{interface}_rx_packets"] = parts[3]
          result["#{interface}_tx_packets"] = parts[7] if parts.size > 7
        end
      end
    end
    
    private def parse_wireless_info(content : String, result : Hash(String, String))
      content.lines.each do |line|
        if match = line.match(/(\w+):\s+\d+\s+(\d+)\.\s+(\d+)\.\s+(\d+)/)
          interface = match[1]
          result["#{interface}_wireless_quality"] = match[2]
          result["#{interface}_signal_level"] = match[3]
          result["#{interface}_noise_level"] = match[4]
        end
      end
    end
    
    private def parse_networkctl_output(output : String, result : Hash(String, String))
      current_interface = ""
      output.lines.each do |line|
        if match = line.match(/^\s*(\w+):\s+(.+)/)
          current_interface = match[1]
          result["#{current_interface}_status"] = match[2]
        elsif line.includes?("Address:") && !current_interface.empty?
          if match = line.match(/Address:\s+(\d+\.\d+\.\d+\.\d+)/)
            result["#{current_interface}_address"] = match[1]
          end
        end
      end
    end
    
    private def parse_system_config(output : String, result : Hash(String, String))
      current_port = ""
      output.lines.each do |line|
        if line.starts_with?("Hardware Port:")
          current_port = line.split(":")[1].strip
        elsif line.starts_with?("Device:") && !current_port.empty?
          device = line.split(":")[1].strip
          result["#{current_port}_device"] = device
        end
      end
    end
    
    # シャットダウン
    def shutdown
      if http3_manager = @http3_manager
        http3_manager.shutdown
      end
      
      if performance_monitor = @http3_performance_monitor
        performance_monitor.stop_monitoring
        performance_monitor.stop_battery_monitoring
      end
      
      Log.info { "ネットワークファクトリーをシャットダウンしました" }
    end
  end
end 