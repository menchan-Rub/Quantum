# HTTP/3ネットワークマネージャー
#
# このクラスはQuantumブラウザのHTTP/3ネットワーク機能を管理し、
# NimのHTTP/3実装との連携を担当します。

require "log"
require "json"
require "uri"
require "http/headers"
require "../quantum_core/config"
require "../../utils/ipc_client"

module QuantumBrowser
  # HTTP/3プロトコルとの通信を管理するクラス
  class Http3NetworkManager
    Log = ::Log.for(self)

    # コールバック関数タイプ
    alias ResponseCallback = Proc(UInt64, Int32, HTTP::Headers, Bytes, String, Nil)
    alias ErrorCallback = Proc(UInt64, String, Int32, Nil)
    alias RedirectCallback = Proc(UInt64, String, Int32, Nil)
    alias ProgressCallback = Proc(UInt64, Int64, Int64, Nil)
    
    # シングルトンインスタンスへのアクセス（コールバック用）
    @@instance : Http3NetworkManager? = nil
    
    def self.get_instance : Http3NetworkManager?
      @@instance
    end

    # HTTP/3リクエストの優先度
    enum Priority
      Critical    # クリティカルリソース（HTML, CSS, JS）
      High        # 重要なリソース（フォント等）
      Normal      # 通常リソース（画像等）
      Low         # 低優先度リソース（非表示画像等）
      Background  # バックグラウンドリソース（プリフェッチ等）
    end

    # HTTP/3リクエスト状態
    enum RequestState
      Queued      # キュー待ち
      Connecting  # 接続中
      Active      # アクティブ
      Completed   # 完了
      Failed      # 失敗
      Cancelled   # キャンセル
    end
    
    # マルチパスQUIC設定
    enum MultiPathMode
      Disabled    # 無効
      Handover    # フェイルオーバーのみ
      Aggregation # 帯域集約（複数パス同時使用）
      Dynamic     # 状況に応じて動的に切り替え
    end
    
    # 接続パスの情報
    class ConnectionPath
      property id : UInt32
      property local_addr : String
      property remote_addr : String
      property rtt_ms : Float64
      property congestion_window : UInt64
      property bandwidth_estimate : UInt64
      property active : Bool
      property error_count : Int32
      
      def initialize(@id, @local_addr, @remote_addr)
        @rtt_ms = 0.0
        @congestion_window = 0_u64
        @bandwidth_estimate = 0_u64
        @active = false
        @error_count = 0
      end
    end

    # HTTP/3リクエスト情報
    class Request
      property id : UInt64
      property url : String
      property method : String
      property headers : Hash(String, String)
      property body : String?
      property priority : Priority
      property state : RequestState
      property start_time : Time
      property end_time : Time?
      property response : Response?
      property stream_id : UInt64?
      property error : String?
      property early_data : Bool # 0-RTT早期データフラグ
      property predicted_weight : Float64 # 予測重要度（機械学習による）
      property visible_in_viewport : Bool # 表示領域内かどうか
      
      def initialize(@id, @url, @method, @headers, @body, @priority)
        @state = RequestState::Queued
        @start_time = Time.utc
        @early_data = false
        @predicted_weight = 1.0
        @visible_in_viewport = false
      end
    end

    # HTTP/3レスポンス情報
    class Response
      property status : Int32
      property headers : Hash(String, String)
      property body : Bytes
      property received_time : Time
      property stream_id : UInt64
      property ttfb : Float64? # Time To First Byte (ms)
      property received_with_0rtt : Bool # 0-RTTで受信したか
      
      def initialize(@status, @headers, @body, @stream_id)
        @received_time = Time.utc
        @received_with_0rtt = false
      end
      
      def content_type : String
        @headers["content-type"]? || "application/octet-stream"
      end
      
      def content_length : Int32
        (@headers["content-length"]? || "0").to_i
      end
    end

    # HTTP/3統計情報
    class Http3Stats
      property requests_total : Int32 = 0
      property requests_success : Int32 = 0
      property requests_error : Int32 = 0
      property bytes_sent : Int64 = 0
      property bytes_received : Int64 = 0
      property active_connections : Int32 = 0
      property active_streams : Int32 = 0
      property handshake_rtt_avg_ms : Float64 = 0.0
      property ttfb_avg_ms : Float64 = 0.0
      property zero_rtt_success : Int32 = 0
      property zero_rtt_rejected : Int32 = 0
    end

    # セッション再開情報
    class SessionTicket
      property host : String
      property port : Int32
      property ticket_data : Bytes
      property issued_time : Time
      property expiry_time : Time
      property cipher_suite : String
      property transport_params : Hash(String, String)
      
      def initialize(@host, @port, @ticket_data, @cipher_suite)
        @issued_time = Time.utc
        @expiry_time = @issued_time + 24.hours
        @transport_params = {} of String => String
      end
      
      def valid? : Bool
        Time.utc < @expiry_time
      end
    end

    # HTTP/3接続設定オプション
    class ConnectionSettings
      property max_connections_per_host : Int32 = 8
      property idle_timeout_ms : Int32 = 30000
      property max_streams_bidi : Int32 = 100
      property max_streams_uni : Int32 = 100
      property initial_max_data : Int32 = 10_485_760 # 10MB
      property initial_max_stream_data_bidi_local : Int32 = 1_048_576 # 1MB
      property initial_max_stream_data_bidi_remote : Int32 = 1_048_576 # 1MB
      property initial_max_stream_data_uni : Int32 = 1_048_576 # 1MB
      property datagram_enabled : Bool = true
      property enable_early_data : Bool = true
      property max_early_data_size : Int32 = 14_200 # 通常のTCP初期ウィンドウサイズに近い
      property retry_without_early_data : Bool = true
      property multiplex_factor : Int32 = 2
      property connection_flow_control_window : Int32 = 15_728_640 # 15MB
      property packet_coalescing : Bool = true
      property optimize_delayed_ack : Bool = true
    end
    
    # HTTP/3ヘッダー圧縮オプション
    class QPACKSettings
      property table_size : Int32 = 4096
      property blocked_streams : Int32 = 100
      property use_huffman : Bool = true
    end

    @ipc_client : IPCClient
    @requests : Hash(UInt64, Request)
    @next_request_id : UInt64
    @stats : Http3Stats
    @config : QuantumCore::Config::NetworkConfig
    @enabled : Bool
    @initialized : Bool = false
    @preconnect_hosts : Set(String) = Set(String).new
    @session_tickets : Hash(String, SessionTicket) = {} of String => SessionTicket
    @connection_paths : Hash(String, Array(ConnectionPath)) = {} of String => Array(ConnectionPath)
    @multipath_mode : MultiPathMode = MultiPathMode::Dynamic
    @zero_rtt_enabled : Bool = true
    @adaptive_pacing : Bool = true
    @congestion_controller : String = "cubic" # 輻輳制御アルゴリズム: cubic, bbr, prague
    @response_callback : ResponseCallback? = nil
    @error_callback : ErrorCallback? = nil
    @redirect_callback : RedirectCallback? = nil
    @progress_callback : ProgressCallback? = nil
    @connection_settings : ConnectionSettings
    @qpack_settings : QPACKSettings
    @is_initialized : Bool = false
    @nim_initialized : Bool = false
    @last_request_id : UInt64 = 0
    @active_requests : Hash(UInt64, Bool) = {} of UInt64 => Bool
    @connection_cache : Hash(String, UInt64) = {} of String => UInt64
    @early_data_usage : Hash(UInt64, Bool) = {} of UInt64 => Bool
    
    def initialize(@config)
      @ipc_client = IPCClient.new("http3")
      @requests = {} of UInt64 => Request
      @next_request_id = 1_u64
      @stats = Http3Stats.new
      @enabled = @config.enable_http3
      @connection_settings = ConnectionSettings.new
      @qpack_settings = QPACKSettings.new
      
      # シングルトンインスタンスを設定（コールバック用）
      @@instance = self
      
      Log.info { "HTTP/3ネットワークマネージャー初期化: 有効=#{@enabled}" }
    end
    
    # リソース解放
    def finalize
      shutdown
      @@instance = nil
    end
    
    # HTTP/3ネットワークシステムを初期化
    def initialize_http3 : Bool
      return true if @is_initialized
      
      Log.info { "HTTP/3サブシステムを初期化中..." }
      
      # セッション管理ディレクトリを作成
      session_dir = File.join(Dir.tempdir, "quantum", "http3_sessions")
      FileUtils.mkdir_p(session_dir)
      
      # Nimバックエンドを初期化
      begin
        # Nimバイナリのパスを取得
        nim_binary = find_nim_binary
        
        # IPCクライアントを初期化
        if @ipc_client.connect
          # 初期化コマンドを送信
          init_params = {
            "session_dir" => session_dir,
            "log_level" => @config.log_level.to_s.downcase,
            "max_connections" => @connection_settings.max_connections_per_host,
            "idle_timeout_ms" => @connection_settings.idle_timeout_ms,
            "enable_0rtt" => @connection_settings.enable_early_data,
            "datagram_enabled" => @connection_settings.datagram_enabled,
            "qpack_table_size" => @qpack_settings.table_size,
            "qpack_blocked_streams" => @qpack_settings.blocked_streams,
            "congestion_control" => @congestion_controller,
            "multiplex_factor" => @connection_settings.multiplex_factor
          }
          
          response = @ipc_client.send_request("initialize", init_params)
          
          if response["success"].as_bool
            @nim_initialized = true
            Log.info { "HTTP/3サブシステム初期化成功" }
            
            # コールバックを登録
            register_nim_callbacks
          else
            Log.error { "HTTP/3サブシステム初期化失敗: #{response["error"]}" }
            return false
          end
        else
          Log.error { "HTTP/3 IPCクライアント接続失敗" }
          return false
        end
        
        @is_initialized = true
        Log.info { "HTTP/3サブシステム準備完了" }
        return true
        
      rescue ex
        Log.error(exception: ex) { "HTTP/3サブシステム初期化エラー" }
        return false
      end
    end
    
    # Nimバイナリを探索
    private def find_nim_binary : String
      # 実行可能ファイルと同じディレクトリ内を検索
      app_dir = File.dirname(Process.executable_path || "")
      bin_paths = [
        File.join(app_dir, "nim", "http3_service"),
        File.join(app_dir, "lib", "nim", "http3_service"),
        File.join(app_dir, "..", "lib", "nim", "http3_service"),
        File.join(app_dir, "..", "share", "quantum", "nim", "http3_service")
      ]
      
      # 環境変数で指定されたパス
      if env_path = ENV["QUANTUM_NIM_PATH"]?
        bin_paths.unshift(File.join(env_path, "http3_service"))
      end
      
      # 各パスをチェック
      bin_paths.each do |path|
        if File.exists?(path) && File.executable?(path)
          return path
        end
        
        # Windowsの場合は.exeを追加
        if File.exists?("#{path}.exe") && File.executable?("#{path}.exe")
          return "#{path}.exe"
        end
      end
      
      # デフォルトパスを返す（プロセス起動時にエラーが検出される）
      return "http3_service"
    end
    
    # Nimコールバックを登録
    private def register_nim_callbacks
      begin
        # コールバック関数を登録
        callback_params = {
          "response_callback" => "Http3Client.nim_response_callback",
          "error_callback" => "Http3Client.nim_error_callback",
          "redirect_callback" => "Http3Client.nim_redirect_callback",
          "progress_callback" => "Http3Client.nim_progress_callback"
        }
        
        response = @ipc_client.send_request("register_callbacks", callback_params)
        
        if response["success"].as_bool
          Log.info { "HTTP/3コールバック登録成功" }
        else
          Log.error { "HTTP/3コールバック登録失敗: #{response["error"]}" }
        end
      rescue ex
        Log.error(exception: ex) { "HTTP/3コールバック登録エラー" }
      end
    end
    
    # HTTP/3システムをシャットダウン
    def shutdown
      return unless @is_initialized
      
      Log.info { "HTTP/3サブシステムをシャットダウン中..." }
      
      # アクティブな接続をすべて閉じる
      close_all_connections
      
      # Nimバックエンドをシャットダウン
      if @nim_initialized
        begin
          response = @ipc_client.send_request("shutdown", {} of String => String)
          
          if response["success"].as_bool
            Log.info { "HTTP/3サブシステムシャットダウン成功" }
          else
            Log.error { "HTTP/3サブシステムシャットダウン失敗: #{response["error"]}" }
          end
        rescue ex
          Log.error(exception: ex) { "HTTP/3サブシステムシャットダウンエラー" }
        end
      end
      
      # IPCクライアントを切断
      @ipc_client.disconnect
      
      # 状態をリセット
      @is_initialized = false
      @nim_initialized = false
      
      Log.info { "HTTP/3サブシステムシャットダウン完了" }
    end
    
    # すべての接続を閉じる
    private def close_all_connections
      # キャッシュされたすべての接続をクローズ
      @connection_cache.each do |host_key, conn_id|
        begin
          close_params = {
            "connection_id" => conn_id.to_s
          }
          
          response = @ipc_client.send_request("close_connection", close_params)
          
          if !response["success"].as_bool
            Log.warn { "接続クローズ失敗: #{host_key}, error: #{response["error"]}" }
          end
        rescue ex
          Log.error(exception: ex) { "接続クローズエラー: #{host_key}" }
        end
      end
      
      # 接続キャッシュをクリア
      @connection_cache.clear
      
      # 統計情報を更新
      @stats.active_connections = 0
    end
    
    # HTTP/3が利用可能かテスト
    def test_http3_capability : Bool
      return false unless @is_initialized
      
      Log.info { "HTTP/3対応をテスト中..." }
      
      begin
        # テスト用の接続を試行
        test_params = {
          "url" => "https://www.cloudflare.com/",
          "timeout_ms" => "5000",
          "max_retries" => "2"
        }
        
        response = @ipc_client.send_request("test_capability", test_params)
        
        result = response["success"].as_bool
        if result
          Log.info { "HTTP/3対応テスト成功: HTTP/3が利用可能です" }
        else
          Log.warn { "HTTP/3対応テスト失敗: #{response["error"]}" }
        end
        
        return result
      rescue ex
        Log.error(exception: ex) { "HTTP/3対応テストエラー" }
        return false
      end
    end
    
    # HTTP/3ネットワークシステムを初期化
    def initialize_http3
      return if @initialized || !@enabled
      
      begin
        # NimのHTTP/3システムを初期化
        response = @ipc_client.call("init_http3", {
          "max_concurrent_streams" => @config.connection_pool_size,
          "idle_timeout" => @config.connection_timeout_ms / 1000,
          "enable_quic" => @config.enable_quic,
          "user_agent" => @config.user_agent,
          "zero_rtt_enabled" => @zero_rtt_enabled,
          "multipath_mode" => @multipath_mode.to_s,
          "adaptive_pacing" => @adaptive_pacing,
          "congestion_controller" => @congestion_controller
        })
        
        if response["success"] == true
          @initialized = true
          Log.info { "HTTP/3システム初期化成功" }
          
          # 保存されたセッションチケットの読み込み
          load_session_tickets
          
          # マルチインターフェース検出と初期化
          if @multipath_mode != MultiPathMode::Disabled
            initialize_multipath
          end
        else
          Log.error { "HTTP/3システム初期化失敗: #{response["error"]}" }
        end
      rescue e
        Log.error(exception: e) { "HTTP/3システム初期化エラー" }
      end
    end
    
    # マルチパスQUIC初期化
    private def initialize_multipath
      begin
        response = @ipc_client.call("init_multipath_quic", {
          "mode" => @multipath_mode.to_s
        })
        
        if response["success"] == true
          available_interfaces = response["interfaces"].as(Array)
          Log.info { "マルチパスQUIC初期化成功: #{available_interfaces.size}個のインターフェース検出" }
          
          # 利用可能なインターフェースを記録
          available_interfaces.each do |interface_info|
            interface_data = interface_info.as(Hash)
            Log.debug { "利用可能なネットワークインターフェース: #{interface_data["name"]} (#{interface_data["type"]})" }
          end
        else
          Log.warn { "マルチパスQUIC初期化失敗: #{response["error"]}" }
          
          # マルチパスが利用できない場合は無効に設定
          @multipath_mode = MultiPathMode::Disabled
        end
      rescue e
        Log.error(exception: e) { "マルチパスQUIC初期化エラー" }
        @multipath_mode = MultiPathMode::Disabled
      end
    end
    
    # HTTP/3サポートが有効かどうか
    def http3_enabled? : Bool
      @enabled && @initialized
    end
    
    # 0-RTT Early Dataが利用可能かチェック
    def can_use_0rtt?(host : String, port : Int32 = 443) : Bool
      return false unless http3_enabled? && @zero_rtt_enabled
      
      host_key = "#{host}:#{port}"
      if ticket = @session_tickets[host_key]?
        return ticket.valid?
      end
      
      false
    end
    
    # パスログ取得（マルチパスQUIC）
    def get_path_stats(host : String, port : Int32 = 443) : Array(ConnectionPath)?
      host_key = "#{host}:#{port}"
      @connection_paths[host_key]?
    end
    
    # セッションチケットを保存
    private def store_session_ticket(host : String, port : Int32, ticket_data : Bytes, cipher_suite : String)
      host_key = "#{host}:#{port}"
      ticket = SessionTicket.new(host, port, ticket_data, cipher_suite)
      @session_tickets[host_key] = ticket
      
      # 永続化（ファイルなどに保存）
      persist_session_tickets
      
      Log.debug { "新しいセッションチケットを保存: #{host}:#{port}" }
    end
    
    # セッションチケットを読み込み
    private def load_session_tickets
            # ファイルなどから永続化されたチケットを読み込む      tickets_dir = File.join(Dir.tempdir, "quantum", "http3_sessions")      tickets_file = File.join(tickets_dir, "session_tickets.json")            if File.exists?(tickets_file)        begin          # ファイルからJSONを読み込み          tickets_json = File.read(tickets_file)          tickets_data = JSON.parse(tickets_json)                    # チケットデータを復元          tickets_array = tickets_data.as_a          tickets_array.each do |ticket_entry|            ticket_obj = ticket_entry.as_h            host = ticket_obj["host"].as_s            port = ticket_obj["port"].as_i                        # チケットデータをバイナリに変換            ticket_data = Base64.decode(ticket_obj["ticket_data"].as_s)            cipher_suite = ticket_obj["cipher_suite"].as_s                        # SessionTicketオブジェクトを作成            ticket = SessionTicket.new(host, port, ticket_data, cipher_suite)                        # タイムスタンプを復元            if issued_time = ticket_obj["issued_time"]?              ticket.issued_time = Time.unix(issued_time.as_i64)            end                        if expiry_time = ticket_obj["expiry_time"]?              ticket.expiry_time = Time.unix(expiry_time.as_i64)            end                        # トランスポートパラメータを復元            if params = ticket_obj["transport_params"]?              params.as_h.each do |k, v|                ticket.transport_params[k] = v.as_s              end            end                        # 有効なチケットのみ追加            if ticket.valid?              @session_tickets["#{host}:#{port}"] = ticket              Log.debug { "セッションチケット読み込み: #{host}:#{port}" }            end          end                    Log.info { "セッションチケット読み込み完了: #{@session_tickets.size}件" }        rescue ex          Log.error(exception: ex) { "セッションチケット読み込みエラー: #{ex.message}" }        end      end
      
      Log.debug { "保存されたセッションチケットを読み込み: #{@session_tickets.size}件" }
    end
    
    # セッションチケットを永続化
    private def persist_session_tickets
            # チケットをファイルなどに保存      tickets_dir = File.join(Dir.tempdir, "quantum", "http3_sessions")      tickets_file = File.join(tickets_dir, "session_tickets.json")            # ディレクトリが存在しなければ作成      FileUtils.mkdir_p(tickets_dir)            # JSONとして保存するデータ配列      tickets_array = [] of JSON::Any            # 有効なチケットのみを保存      @session_tickets.each do |key, ticket|        if ticket.valid?          # JSONオブジェクトとして構築          transport_params = {} of String => JSON::Any          ticket.transport_params.each do |k, v|            transport_params[k] = JSON::Any.new(v)          end                    ticket_obj = {            "host" => JSON::Any.new(ticket.host),            "port" => JSON::Any.new(ticket.port),            "ticket_data" => JSON::Any.new(Base64.strict_encode(ticket.ticket_data)),            "cipher_suite" => JSON::Any.new(ticket.cipher_suite),            "issued_time" => JSON::Any.new(ticket.issued_time.to_unix),            "expiry_time" => JSON::Any.new(ticket.expiry_time.to_unix),            "transport_params" => JSON::Any.new(transport_params)          }                    tickets_array << JSON::Any.new(ticket_obj)        end      end            # JSONに変換して保存      tickets_json = JSON.build do |json|        json.array do          tickets_array.each do |ticket|            ticket.to_json(json)          end        end      end            begin        File.write(tickets_file, tickets_json)        Log.debug { "セッションチケットを保存しました: #{tickets_array.size}件" }      rescue ex        Log.error(exception: ex) { "セッションチケット保存エラー: #{ex.message}" }      end    end
    
    # HTTP/3リクエストを送信
    def send_request(url : String, method : String = "GET", 
                   headers : Hash(String, String) = {} of String => String,
                   body : String? = nil, priority : Priority = Priority::Normal,
                   use_early_data : Bool = true) : UInt64
      request_id = @next_request_id
      @next_request_id += 1
      
      # リクエストオブジェクトを作成
      request = Request.new(request_id, url, method, headers, body, priority)
      @requests[request_id] = request
      
      # HTTP/3が無効の場合は失敗として記録
      unless http3_enabled?
        request.state = RequestState::Failed
        request.error = "HTTP/3が無効です"
        request.end_time = Time.utc
        @stats.requests_total += 1
        @stats.requests_error += 1
        return request_id
      end
      
      # URLからホスト・ポートを抽出
      uri = URI.parse(url)
      host = uri.host.not_nil!
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      
      # 0-RTTが利用可能かチェック
      can_use_0rtt = use_early_data && can_use_0rtt?(host, port)
      request.early_data = can_use_0rtt
      
      # 非同期でリクエストを送信
      spawn do
        begin
          request.state = RequestState::Connecting
          
          # Nimバックエンドにリクエストを送信
          response = @ipc_client.call("send_http3_request", {
            "request_id" => request_id,
            "url" => url,
            "method" => method,
            "headers" => headers,
            "body" => body || "",
            "priority" => priority.to_s,
            "use_early_data" => can_use_0rtt,
            "visible_in_viewport" => request.visible_in_viewport,
            "predicted_weight" => request.predicted_weight
          })
          
          if response["success"] == true
            request.state = RequestState::Active
            request.stream_id = response["stream_id"].as(Int64).to_u64
            
            # 送信バイト数を記録
            sent_bytes = (body ? body.bytesize : 0) + headers.sum { |k, v| k.bytesize + v.bytesize }
            @stats.bytes_sent += sent_bytes
            
            # 0-RTT情報を記録
            if response["used_0rtt"] == true
              @stats.zero_rtt_success += 1
            elsif can_use_0rtt && response["0rtt_rejected"] == true
              @stats.zero_rtt_rejected += 1
            end
            
            # マルチパス情報を更新
            if response.has_key?("active_paths")
              update_connection_paths(host, port, response["active_paths"].as(Array))
            end
          else
            request.state = RequestState::Failed
            request.error = response["error"].as(String)
            request.end_time = Time.utc
            @stats.requests_error += 1
          end
        rescue e
          request.state = RequestState::Failed
          request.error = e.message
          request.end_time = Time.utc
          Log.error(exception: e) { "HTTP/3リクエスト送信エラー: #{url}" }
          @stats.requests_error += 1
        end
      end
      
      @stats.requests_total += 1
      request_id
    end
    
    # マルチパスQUIC接続情報の更新
    private def update_connection_paths(host : String, port : Int32, paths_data : Array)
      host_key = "#{host}:#{port}"
      
      # 新しいパス情報のリストを作成
      new_paths = [] of ConnectionPath
      
      paths_data.each do |path_data|
        path_info = path_data.as(Hash)
        path_id = path_info["id"].as(Int64).to_u32
        
        # 既存のパス情報を探す
        existing_paths = @connection_paths[host_key]? || [] of ConnectionPath
        existing_path = existing_paths.find { |p| p.id == path_id }
        
        if existing_path
          # 既存のパス情報を更新
          existing_path.rtt_ms = path_info["rtt_ms"].as(Float64)
          existing_path.congestion_window = path_info["cwnd"].as(Int64).to_u64
          existing_path.bandwidth_estimate = path_info["bandwidth"].as(Int64).to_u64
          existing_path.active = path_info["active"] == true
          
          new_paths << existing_path
        else
          # 新しいパス情報を作成
          path = ConnectionPath.new(
            path_id,
            path_info["local_addr"].as(String),
            path_info["remote_addr"].as(String)
          )
          path.rtt_ms = path_info["rtt_ms"].as(Float64)
          path.congestion_window = path_info["cwnd"].as(Int64).to_u64
          path.bandwidth_estimate = path_info["bandwidth"].as(Int64).to_u64
          path.active = path_info["active"] == true
          
          new_paths << path
        end
      end
      
      # パス切り替えを検出
      if @connection_paths.has_key?(host_key)
        old_active = @connection_paths[host_key].count { |p| p.active }
        new_active = new_paths.count { |p| p.active }
        
        if old_active != new_active || 
           (@connection_paths[host_key].find { |p| p.active }.try(&.id) != new_paths.find { |p| p.active }.try(&.id))
          @stats.active_streams += 1
          Log.debug { "マルチパスQUIC: #{host}:#{port} でパス切り替えが発生 (#{new_paths.count { |p| p.active }}個のアクティブパス)" }
        end
      end
      
      # 更新された情報を保存
      @connection_paths[host_key] = new_paths
    end
    
    # リクエストの状態を取得
    def get_request_state(request_id : UInt64) : RequestState?
      @requests[request_id]?.try &.state
    end
    
    # リクエストのレスポンスを取得
    def get_response(request_id : UInt64) : Response?
      @requests[request_id]?.try &.response
    end
    
    # レスポンスを処理（Nim側からのコールバック用）
    def handle_response(request_id : UInt64, status : Int32, 
                       headers : Hash(String, String), body : Bytes, 
                       stream_id : UInt64, ttfb : Float64? = nil, used_0rtt : Bool = false) : Bool
      request = @requests[request_id]?
      return false unless request
      
      # レスポンスオブジェクトを作成
      response = Response.new(status, headers, body, stream_id)
      response.ttfb = ttfb
      response.received_with_0rtt = used_0rtt
      request.response = response
      request.state = RequestState::Completed
      request.end_time = Time.utc
      
      # 統計情報を更新
      @stats.requests_success += 1
      @stats.bytes_received += body.size
      
      # レスポンス時間を計算
      if request.end_time && request.start_time
        response_time = (request.end_time.not_nil! - request.start_time).total_milliseconds
        # 移動平均を更新
        if @stats.requests_success == 1
          @stats.handshake_rtt_avg_ms = response_time
        else
          @stats.handshake_rtt_avg_ms = (@stats.handshake_rtt_avg_ms * (@stats.requests_success - 1) + response_time) / @stats.requests_success
        end
      end
      
      # TTFBの統計を更新
      if ttfb_value = ttfb
        if @stats.requests_success == 1
          @stats.ttfb_avg_ms = ttfb_value
        else
          @stats.ttfb_avg_ms = (@stats.ttfb_avg_ms * (@stats.requests_success - 1) + ttfb_value) / @stats.requests_success
        end
      end
      
      # 新しいセッションチケットを処理（存在する場合）
      if headers.has_key?("quic-session-ticket") && headers.has_key?("quic-cipher-suite")
        ticket_data = Base64.decode(headers["quic-session-ticket"])
        cipher_suite = headers["quic-cipher-suite"]
        
        uri = URI.parse(request.url)
        if host = uri.host
          port = uri.port || (uri.scheme == "https" ? 443 : 80)
          store_session_ticket(host, port, ticket_data, cipher_suite)
        end
      end
      
      true
    end
    
    # エラーを処理（Nim側からのコールバック用）
    def handle_error(request_id : UInt64, error : String, error_code : Int32 = 0) : Bool
      request = @requests[request_id]?
      return false unless request
      
      request.state = RequestState::Failed
      request.error = error
      request.end_time = Time.utc
      
      # 統計情報を更新
      @stats.requests_error += 1
      
      # エラーコードに基づく追加処理
      if error_code == 0x3 # QUIC_PROTOCOL_VIOLATION
        @stats.active_connections += 1
      elsif error_code == 0x2 # QUIC_INTERNAL_ERROR
        # 内部エラー処理
      elsif error_code == 0x1 # CONGESTION
        @stats.active_streams += 1
      end
      
      true
    end
    
    # リクエストをキャンセル
    def cancel_request(request_id : UInt64) : Bool
      request = @requests[request_id]?
      return false unless request
      
      # すでに完了または失敗している場合はキャンセル不可
      return false if request.state == RequestState::Completed || 
                      request.state == RequestState::Failed ||
                      request.state == RequestState::Cancelled
      
      begin
        # Nim側にキャンセルリクエストを送信
        if request.stream_id
          response = @ipc_client.call("cancel_http3_request", {
            "request_id" => request_id,
            "stream_id" => request.stream_id
          })
          
          if response["success"] == true
            request.state = RequestState::Cancelled
            request.end_time = Time.utc
            return true
          end
        else
          # まだストリームIDがない場合は単にキャンセル状態に設定
          request.state = RequestState::Cancelled
          request.end_time = Time.utc
          return true
        end
      rescue e
        Log.error(exception: e) { "HTTP/3リクエストキャンセルエラー: #{request_id}" }
      end
      
      false
    end
    
    # 統計情報を取得
    def get_stats : Http3Stats
      @stats
    end
    
    # ホストへのプリコネクトを実行
    def preconnect(host : String, port : Int32 = 443) : Bool
      return false unless http3_enabled?
      
      # 既にプリコネクト済みなら何もしない
      host_key = "#{host}:#{port}"
      return true if @preconnect_hosts.includes?(host_key)
      
      begin
        # 0-RTTが利用可能かチェック
        can_use_0rtt = can_use_0rtt?(host, port)
        
        response = @ipc_client.call("http3_preconnect", {
          "host" => host,
          "port" => port,
          "use_0rtt" => can_use_0rtt,
          "multipath" => @multipath_mode != MultiPathMode::Disabled
        })
        
        if response["success"] == true
          @preconnect_hosts.add(host_key)
          
          # マルチパス情報を更新
          if response.has_key?("active_paths")
            update_connection_paths(host, port, response["active_paths"].as(Array))
          end
          
          Log.info { "HTTP/3プリコネクト成功: #{host}:#{port} (0-RTT: #{can_use_0rtt})" }
          return true
        else
          Log.warn { "HTTP/3プリコネクト失敗: #{host}:#{port} - #{response["error"]}" }
        end
      rescue e
        Log.error(exception: e) { "HTTP/3プリコネクトエラー: #{host}:#{port}" }
      end
      
      false
    end
    
    # マルチパスモードを設定
    def set_multipath_mode(mode : MultiPathMode) : Bool
      return false unless http3_enabled?
      
      begin
        response = @ipc_client.call("set_multipath_mode", {
          "mode" => mode.to_s
        })
        
        if response["success"] == true
          @multipath_mode = mode
          Log.info { "マルチパスQUICモードを変更: #{mode}" }
          return true
        else
          Log.warn { "マルチパスQUICモード変更失敗: #{response["error"]}" }
        end
      rescue e
        Log.error(exception: e) { "マルチパスQUICモード変更エラー" }
      end
      
      false
    end
    
    # 0-RTT設定を変更
    def set_0rtt_enabled(enabled : Bool) : Bool
      @zero_rtt_enabled = enabled
      
      if http3_enabled?
        begin
          response = @ipc_client.call("set_0rtt_enabled", {
            "enabled" => enabled
          })
          
          if response["success"] == true
            Log.info { "0-RTT設定を変更: #{enabled}" }
            return true
          else
            Log.warn { "0-RTT設定変更失敗: #{response["error"]}" }
          end
        rescue e
          Log.error(exception: e) { "0-RTT設定変更エラー" }
        end
      end
      
      false
    end
    
    # パケットペーシング設定を変更
    def set_adaptive_pacing(enabled : Bool) : Bool
      @adaptive_pacing = enabled
      
      if http3_enabled?
        begin
          response = @ipc_client.call("set_adaptive_pacing", {
            "enabled" => enabled
          })
          
          if response["success"] == true
            Log.info { "適応型パケットペーシング設定を変更: #{enabled}" }
            return true
          else
            Log.warn { "適応型パケットペーシング設定変更失敗: #{response["error"]}" }
          end
        rescue e
          Log.error(exception: e) { "適応型パケットペーシング設定変更エラー" }
        end
      end
      
      false
    end
    
    # 輻輳制御アルゴリズムを設定
    def set_congestion_controller(algorithm : String) : Bool
      return false unless ["cubic", "bbr", "prague"].includes?(algorithm)
      
      @congestion_controller = algorithm
      
      if http3_enabled?
        begin
          response = @ipc_client.call("set_congestion_controller", {
            "algorithm" => algorithm
          })
          
          if response["success"] == true
            Log.info { "輻輳制御アルゴリズムを変更: #{algorithm}" }
            return true
          else
            Log.warn { "輻輳制御アルゴリズム変更失敗: #{response["error"]}" }
          end
        rescue e
          Log.error(exception: e) { "輻輳制御アルゴリズム変更エラー" }
        end
      end
      
      false
    end
    
    # 接続プールをクリーンアップ
    def cleanup_connections
      return unless http3_enabled?
      
      begin
        @ipc_client.call("cleanup_http3_connections", {} of String => String)
        Log.debug { "HTTP/3接続プールクリーンアップ完了" }
      rescue e
        Log.error(exception: e) { "HTTP/3接続プールクリーンアップエラー" }
      end
    end
  end
end 