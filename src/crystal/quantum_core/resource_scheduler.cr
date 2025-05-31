# src/crystal/quantum_core/resource_scheduler.cr
require "http/client" # CrystalのHTTPクライアントを使用
require "openssl"     # HTTPSに必要
require "../utils/logger"
require "../events/event_dispatcher"
# require "./nim_bridge" # 現時点ではNimブリッジ依存を削除
require "deque"
require "mutex"
require "uri"
require "fiber" # バックグラウンドタスク用
require "atomic"

module QuantumCore
  # 優先度と同時実行制限に基づいてネットワークリソースリクエストをスケジュールし実行する。
  # Crystal's HTTP::Clientを使用して直接ネットワークI/Oを処理する。
  class ResourceScheduler
    Log = ::Log.for(self)

    # リクエスト優先度レベル
    enum Priority
      HIGHEST  # メインHTMLドキュメント、重要なCSS/JS
      HIGH     # フォント、同期JS、CSSインポート
      MEDIUM   # 画像（ビューポート内）、非同期JS
      LOW      # 画像（ビューポート外）、メディア
      LOWEST   # プリフェッチ、バックグラウンド同期
    end

    # キューで待機中または処理中のリクエストを表す
    private record RequestItem,
      request_id : UInt64,
      page_id : UInt64,
      url : URI,
      priority : Priority,
      timestamp : Time,
      bypass_cache : Bool,
      fiber : Fiber?, # このリクエストを実行しているFiber
      cancelled : Atomic::Bool = Atomic::Bool.new(false) # キャンセルフラグ

    # --- インスタンス変数 --- #
    @queues : Hash(Priority, Deque(RequestItem))
    @mutex : Mutex
    @active_requests : Hash(UInt64, RequestItem) # キャンセル用にrequest_idでRequestItemを保存
    @max_concurrent_requests : Int32
    @request_id_counter : UInt64
    @logger : ::Log::Context

    # 依存関係
    # @nim_bridge : NimNetworkBridge # 削除済み
    @event_dispatcher : QuantumEvents::EventDispatcher # ネットワークイベント配信用

    def initialize(@event_dispatcher : QuantumEvents::EventDispatcher,
                   max_concurrent : Int32 = 6) # デフォルト同時実行数
      @queues = Hash(Priority, Deque(RequestItem)).new
      Priority.each { |p| @queues[p] = Deque(RequestItem).new }
      @mutex = Mutex.new
      @active_requests = Hash(UInt64, RequestItem).new
      @max_concurrent_requests = max_concurrent
      @request_id_counter = 0_u64
      @logger = Log.for("Scheduler")
      @logger.level = ::Log::Severity.parse(ENV.fetch("LOG_LEVEL", "INFO"))

      # Nimブリッジコールバック登録は不要になった
      # @nim_bridge.register_completion_callback(...)

      @logger.info { "ResourceSchedulerが初期化されました（最大同時実行数: #{@max_concurrent_requests}、モード: 直接HTTP）" }
    end

    # --- 公開API --- #

    # ページのメインリソースリクエストをスケジュール（最高優先度）
    # 生成されたrequest_idを返す
    def request_main_resource(page_id : UInt64, url : URI, bypass_cache = false) : UInt64
      add_request(page_id, url, Priority::HIGHEST, bypass_cache)
    end

    # 指定された優先度でページのサブリソースリクエストをスケジュール
    # 生成されたrequest_idを返す
    def request_sub_resource(page_id : UInt64, url : URI, priority : Priority, bypass_cache = false) : UInt64
      add_request(page_id, url, priority, bypass_cache)
    end

    # ページに関連する保留中および実行中のすべてのリクエストをキャンセル
    def cancel_requests_for_page(page_id : UInt64)
      cancelled_pending_count = 0
      active_items_to_cancel = [] of RequestItem
      
      @mutex.synchronize do
        # 保留中のリクエストをキャンセル
        @queues.each do |priority, queue|
          queue.reject! do |item|
            if item.page_id == page_id
              cancelled_pending_count += 1
              @logger.debug { "保留中のリクエストをキャンセルしました: #{item.url} (優先度: #{priority})" }
              true
            else
              false
            end
          end
        end
        
        # 実行中のリクエストを収集
        @active_requests.each do |request_id, item|
          if item.page_id == page_id
            active_items_to_cancel << item
          end
        end
      end
      
      # 実行中のリクエストをキャンセル
      active_items_to_cancel.each do |item|
        cancel_active_request(item.request_id)
      end
      
      @logger.info { "ページ #{page_id} のリクエストをキャンセルしました（保留中: #{cancelled_pending_count}、実行中: #{active_items_to_cancel.size}）" }
    end

    # 特定のリクエストをキャンセル
    def cancel_request(request_id : UInt64) : Bool
      @mutex.synchronize do
        # 保留中のリクエストから検索・削除
        @queues.each do |priority, queue|
          if queue.any? { |item| item.request_id == request_id }
            queue.reject! { |item| item.request_id == request_id }
            @logger.debug { "保留中のリクエスト #{request_id} をキャンセルしました" }
            return true
          end
        end
        
        # 実行中のリクエストから検索・キャンセル
        if @active_requests.has_key?(request_id)
          cancel_active_request(request_id)
          return true
        end
      end
      
      false
    end

    # 統計情報の取得
    def get_statistics : NamedTuple(
      pending_requests: Int32,
      active_requests: Int32,
      total_completed: UInt64,
      total_failed: UInt64,
      average_response_time: Float64
    )
      @mutex.synchronize do
        pending_count = @queues.values.sum(&.size)
        active_count = @active_requests.size
        
        {
          pending_requests: pending_count,
          active_requests: active_count,
          total_completed: @total_completed,
          total_failed: @total_failed,
          average_response_time: @average_response_time
        }
      end
    end

    # 優先度の変更
    def change_priority(request_id : UInt64, new_priority : Priority) : Bool
      @mutex.synchronize do
        # 保留中のリクエストから検索
        @queues.each do |current_priority, queue|
          if item_index = queue.index { |item| item.request_id == request_id }
            item = queue.delete_at(item_index)
            item.priority = new_priority
            @queues[new_priority].push(item)
            @logger.debug { "リクエスト #{request_id} の優先度を #{current_priority} から #{new_priority} に変更しました" }
            return true
          end
        end
      end
      
      false
    end

    # --- 内部実装 --- #

    # リクエストをキューに追加
    private def add_request(page_id : UInt64, url : URI, priority : Priority, bypass_cache : Bool) : UInt64
      request_id = generate_request_id
      
      item = RequestItem.new(
        request_id: request_id,
        page_id: page_id,
        url: url,
        priority: priority,
        bypass_cache: bypass_cache,
        created_at: Time.utc,
        retry_count: 0
      )
      
      @mutex.synchronize do
        @queues[priority].push(item)
        @logger.debug { "リクエストをキューに追加しました: #{url} (ID: #{request_id}, 優先度: #{priority})" }
      end
      
      # 即座に処理を試行
      process_queue
      
      request_id
    end

    # リクエストIDの生成
    private def generate_request_id : UInt64
      @mutex.synchronize do
        @request_id_counter += 1
        @request_id_counter
      end
    end

    # キューの処理
    private def process_queue
      spawn do
        loop do
          item = get_next_request
          break unless item
          
          execute_request(item)
        end
      end
    end

    # 次のリクエストを取得
    private def get_next_request : RequestItem?
      @mutex.synchronize do
        return nil if @active_requests.size >= @max_concurrent_requests
        
        # 優先度順にキューをチェック
        Priority.each do |priority|
          queue = @queues[priority]
          unless queue.empty?
            item = queue.shift
            @active_requests[item.request_id] = item
            return item
          end
        end
        
        nil
      end
    end

    # リクエストの実行
    private def execute_request(item : RequestItem)
      start_time = Time.utc
      
      begin
        @logger.debug { "リクエストを実行中: #{item.url} (ID: #{item.request_id})" }
        
        # HTTP リクエストの実行
        response = perform_http_request(item)
        
        # 成功時の処理
        handle_request_success(item, response, start_time)
        
      rescue ex : Exception
        # エラー時の処理
        handle_request_error(item, ex, start_time)
      ensure
        # アクティブリクエストから削除
        @mutex.synchronize do
          @active_requests.delete(item.request_id)
        end
        
        # 次のリクエストを処理
        process_queue
      end
    end

    # HTTP リクエストの実行
    private def perform_http_request(item : RequestItem) : HTTP::Client::Response
      # HTTPクライアントの設定
      client = HTTP::Client.new(item.url.host.not_nil!, item.url.port)
      client.connect_timeout = 10.seconds
      client.read_timeout = 30.seconds
      
      # ヘッダーの設定
      headers = HTTP::Headers.new
      headers["User-Agent"] = "Quantum Browser/1.0"
      headers["Accept"] = "*/*"
      headers["Accept-Encoding"] = "gzip, deflate, br"
      headers["Connection"] = "keep-alive"
      
      # キャッシュ制御
      if item.bypass_cache
        headers["Cache-Control"] = "no-cache"
        headers["Pragma"] = "no-cache"
      end
      
      # リクエストの実行
      path = item.url.path.empty? ? "/" : item.url.path
      if query = item.url.query
        path += "?" + query
      end
      
      response = client.get(path, headers)
      
      # レスポンスの検証
      validate_response(response)
      
      response
    end

    # レスポンスの検証
    private def validate_response(response : HTTP::Client::Response)
      # ステータスコードのチェック
      unless response.success?
        case response.status_code
        when 404
          raise Exception.new("リソースが見つかりません (404)")
        when 403
          raise Exception.new("アクセスが拒否されました (403)")
        when 500..599
          raise Exception.new("サーバーエラー (#{response.status_code})")
        else
          raise Exception.new("HTTPエラー (#{response.status_code})")
        end
      end
      
      # コンテンツタイプのチェック
      content_type = response.headers["Content-Type"]?
      if content_type && !is_supported_content_type(content_type)
        @logger.warn { "サポートされていないコンテンツタイプ: #{content_type}" }
      end
    end

    # サポートされているコンテンツタイプかチェック
    private def is_supported_content_type(content_type : String) : Bool
      supported_types = [
        "text/html",
        "text/css",
        "text/javascript",
        "application/javascript",
        "application/json",
        "image/",
        "font/",
        "application/font"
      ]
      
      supported_types.any? { |type| content_type.starts_with?(type) }
    end

    # リクエスト成功時の処理
    private def handle_request_success(item : RequestItem, response : HTTP::Client::Response, start_time : Time)
      duration = (Time.utc - start_time).total_milliseconds
      
      @mutex.synchronize do
        @total_completed += 1
        update_average_response_time(duration)
      end
      
      @logger.info { "リクエストが完了しました: #{item.url} (#{duration.round(2)}ms, #{response.status_code})" }
      
      # イベントの発火
      @event_dispatcher.dispatch(QuantumEvents::ResourceLoadedEvent.new(
        request_id: item.request_id,
        page_id: item.page_id,
        url: item.url.to_s,
        status_code: response.status_code,
        content_type: response.headers["Content-Type"]?,
        content_length: response.body.bytesize,
        duration: duration,
        from_cache: false
      ))
    end

    # リクエストエラー時の処理
    private def handle_request_error(item : RequestItem, error : Exception, start_time : Time)
      duration = (Time.utc - start_time).total_milliseconds
      
      @mutex.synchronize do
        @total_failed += 1
      end
      
      @logger.error { "リクエストが失敗しました: #{item.url} - #{error.message} (#{duration.round(2)}ms)" }
      
      # リトライ処理
      if should_retry(item, error)
        retry_request(item)
      else
        # 最終的な失敗イベントの発火
        @event_dispatcher.dispatch(QuantumEvents::ResourceFailedEvent.new(
          request_id: item.request_id,
          page_id: item.page_id,
          url: item.url.to_s,
          error_message: error.message,
          retry_count: item.retry_count,
          duration: duration
        ))
      end
    end

    # リトライが必要かチェック
    private def should_retry(item : RequestItem, error : Exception) : Bool
      return false if item.retry_count >= MAX_RETRY_COUNT
      
      # 一時的なエラーの場合のみリトライ
      case error.message
      when /timeout/i, /connection/i, /network/i
        true
      when /5\d\d/  # 5xx サーバーエラー
        true
      else
        false
      end
    end

    # リクエストのリトライ
    private def retry_request(item : RequestItem)
      item.retry_count += 1
      retry_delay = calculate_retry_delay(item.retry_count)
      
      @logger.info { "リクエストを #{retry_delay}秒後にリトライします: #{item.url} (試行回数: #{item.retry_count})" }
      
      spawn do
        sleep retry_delay.seconds
        
        @mutex.synchronize do
          @queues[item.priority].push(item)
        end
        
        process_queue
      end
    end

    # リトライ遅延の計算（指数バックオフ）
    private def calculate_retry_delay(retry_count : Int32) : Float64
      base_delay = 1.0
      max_delay = 30.0
      
      delay = base_delay * (2 ** (retry_count - 1))
      [delay, max_delay].min
    end

    # 実行中のリクエストをキャンセル
    private def cancel_active_request(request_id : UInt64)
      @mutex.synchronize do
        if item = @active_requests.delete(request_id)
          @logger.debug { "実行中のリクエスト #{request_id} をキャンセルしました" }
          
          # キャンセルイベントの発火
          @event_dispatcher.dispatch(QuantumEvents::ResourceCancelledEvent.new(
            request_id: request_id,
            page_id: item.page_id,
            url: item.url.to_s
          ))
        end
      end
    end

    # 平均レスポンス時間の更新
    private def update_average_response_time(duration : Float64)
      if @total_completed == 1
        @average_response_time = duration
      else
        # 移動平均の計算
        @average_response_time = (@average_response_time * 0.9) + (duration * 0.1)
      end
    end

    # 定期的なクリーンアップタスク
    private def start_cleanup_task
      spawn do
        loop do
          sleep 60.seconds  # 1分間隔
          cleanup_expired_requests
        end
      end
    end

    # 期限切れリクエストのクリーンアップ
    private def cleanup_expired_requests
      expired_count = 0
      current_time = Time.utc
      
      @mutex.synchronize do
        @queues.each do |priority, queue|
          original_size = queue.size
          queue.reject! do |item|
            age = (current_time - item.created_at).total_seconds
            if age > REQUEST_TIMEOUT_SECONDS
              expired_count += 1
              @logger.debug { "期限切れリクエストを削除しました: #{item.url} (経過時間: #{age.round(2)}秒)" }
              true
            else
              false
            end
          end
        end
      end
      
      if expired_count > 0
        @logger.info { "期限切れリクエストを #{expired_count} 件削除しました" }
      end
    end

    # パフォーマンス統計の出力
    def log_performance_stats
      stats = get_statistics
      
      @logger.info do
        "リソーススケジューラー統計: " \
        "保留中: #{stats[:pending_requests]}, " \
        "実行中: #{stats[:active_requests]}, " \
        "完了: #{stats[:total_completed]}, " \
        "失敗: #{stats[:total_failed]}, " \
        "平均レスポンス時間: #{stats[:average_response_time].round(2)}ms"
      end
    end

    # 定期的な統計出力タスク
    private def start_stats_task
      spawn do
        loop do
          sleep 300.seconds  # 5分間隔
          log_performance_stats
        end
      end
    end

    # 初期化時の追加設定
    private def initialize_background_tasks
      start_cleanup_task
      start_stats_task
      
      @logger.info { "バックグラウンドタスクを開始しました" }
    end

    # 設定の更新
    def update_configuration(max_concurrent : Int32? = nil, timeout : Int32? = nil)
      @mutex.synchronize do
        if max_concurrent
          @max_concurrent_requests = max_concurrent
          @logger.info { "最大同時実行数を #{max_concurrent} に更新しました" }
        end
        
        if timeout
          @request_timeout = timeout
          @logger.info { "リクエストタイムアウトを #{timeout}秒 に更新しました" }
        end
      end
    end

    # ヘルスチェック
    def health_check : NamedTuple(status: String, details: Hash(String, String | Int32))
      stats = get_statistics
      
      status = if stats[:active_requests] < @max_concurrent_requests && stats[:pending_requests] < 100
                 "healthy"
               elsif stats[:pending_requests] < 500
                 "warning"
               else
                 "critical"
               end
      
      details = {
        "status" => status,
        "pending_requests" => stats[:pending_requests],
        "active_requests" => stats[:active_requests],
        "max_concurrent" => @max_concurrent_requests,
        "total_completed" => stats[:total_completed].to_i32,
        "total_failed" => stats[:total_failed].to_i32,
        "success_rate" => calculate_success_rate.to_s
      }
      
      {status: status, details: details}
    end

    # 成功率の計算
    private def calculate_success_rate : Float64
      total = @total_completed + @total_failed
      return 100.0 if total == 0
      
      (@total_completed.to_f64 / total.to_f64) * 100.0
    end

    # 緊急停止
    def emergency_stop
      @logger.warn { "緊急停止が要求されました" }
      
      @mutex.synchronize do
        # 全ての保留中リクエストをクリア
        @queues.each { |_, queue| queue.clear }
        
        # 実行中リクエストをキャンセル
        @active_requests.keys.each { |request_id| cancel_active_request(request_id) }
      end
      
      @logger.info { "緊急停止が完了しました" }
    end
  end

  # リクエストアイテム構造体
  struct RequestItem
    property request_id : UInt64
    property page_id : UInt64
    property url : URI
    property priority : ResourceScheduler::Priority
    property bypass_cache : Bool
    property created_at : Time
    property retry_count : Int32
    
    def initialize(@request_id : UInt64, @page_id : UInt64, @url : URI, 
                   @priority : ResourceScheduler::Priority, @bypass_cache : Bool, 
                   @created_at : Time, @retry_count : Int32 = 0)
    end
  end

  # 定数定義
  private MAX_RETRY_COUNT = 3
  private REQUEST_TIMEOUT_SECONDS = 300  # 5分
  
  # インスタンス変数の追加
  @total_completed : UInt64 = 0_u64
  @total_failed : UInt64 = 0_u64
  @average_response_time : Float64 = 0.0
  @request_timeout : Int32 = 30
end