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
    record RequestItem, request_id : UInt64, page_id : UInt64, url : URI, priority : Priority, timestamp : Time, bypass_cache : Bool, fiber : Fiber? do
      # スケジューラによって生成された一意のrequest_idを使用
      # キャッシュバイパスフラグを追加
      # キャンセル用にリクエストを処理するFiberを保存
    end

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
        Priority.each do |priority|
          queue = @queues[priority]
          items_to_keep = queue.reject do |item|
            if item.page_id == page_id
              cancelled_pending_count += 1
              @logger.trace { "ページ#{page_id}の保留中リクエストID #{item.request_id}をキャンセル中" }
              true # キューから削除
            else
              false # キューに保持
            end
          end
          # フィルタリングされたアイテムでキューを置き換え（可能であればDeque内部で効率的に処理、そうでなければ再構築）
          @queues[priority] = Deque(RequestItem).concat(items_to_keep)
        end

        # このページのアクティブなリクエストを特定
        active_items_to_cancel = @active_requests.values.select { |item| item.page_id == page_id }
      end

      @logger.info { "ページ#{page_id}の保留中リクエスト#{cancelled_pending_count}件をキャンセルしました" } if cancelled_pending_count > 0

      # アクティブなリクエストをキャンセル（ミューテックス外で）
      if active_items_to_cancel.any?
          @logger.info { "ページ#{page_id}のアクティブなリクエスト#{active_items_to_cancel.size}件のキャンセルを要求中" }
          active_items_to_cancel.each do |item|
              cancel_active_request(item)
          end
      end
    end

    # 特定のアクティブなリクエストをキャンセル
    private def cancel_active_request(item : RequestItem)
      @logger.debug { "アクティブなリクエストID #{item.request_id}のキャンセルを試行中（Fiber: #{item.fiber.inspect}）" }
      # HTTPリクエストを実行しているFiberに停止を通知する方法が必要
      # 選択肢1: Fiberで例外を発生させる（可能かつ安全な場合）
      # 選択肢2: Fiber内のループでチェックする共有フラグ（例：Atomic Boolean）を使用
      # 選択肢3: 基礎となるIO（client.close）を閉じる - クライアントアクセスが必要かもしれない

      # 簡単のため、例外を発生させてみましょう。これは脆弱かもしれません。
      begin
        item.fiber.try &.raise(Fiber::Cancelled.new("リクエストがスケジューラによってキャンセルされました"))
      rescue ex
        @logger.warn(exception: ex) { "リクエスト#{item.request_id}のFiberでキャンセルを発生させることに失敗しました" }
      end

      # キャンセル信号の成功に関わらず、スケジューラスロットを解放し、
      # さらなる処理/イベント配信を防ぐために、すぐに完了としてマーク
      handle_request_finished(item.request_id, cancelled: true)
    end


    # ページが閉じられたときに呼び出され、そのリクエストをキャンセルする
    def page_closed(page_id : UInt64)
      @logger.debug { "ページ#{page_id}が閉じられました。関連するリクエストをキャンセルします。" }
      cancel_requests_for_page(page_id)
    end

    # --- リクエスト実行（Nimブリッジとの相互作用に代わるもの） --- #

    # 別のFiberでHTTPリクエストを実行
    private def execute_request(item : RequestItem)
      spawn name: "http_req_#{item.request_id}" do
        client : HTTP::Client? = nil
        response : HTTP::Client::Response? = nil
        begin
          # 1. HTTPクライアントを作成
          client = HTTP::Client.new(item.url, tls: item.url.scheme == "https")
          client.read_timeout = 30.seconds # タイムアウト例
          client.connect_timeout = 15.seconds

          # bypass_cacheがtrueの場合、キャッシュ制御ヘッダーを追加
          headers = HTTP::Headers.new
          if item.bypass_cache
            headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
            headers["Pragma"] = "no-cache" # HTTP/1.0互換性のため
            headers["Expires"] = "0"
          end
          
          # ブラウザのユーザーエージェントとその他の標準ヘッダーを設定
          headers["User-Agent"] = "QuantumBrowser/1.0 Crystal/#{Crystal::VERSION}"
          headers["Accept"] = "*/*"
          headers["Accept-Language"] = "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"
          headers["Connection"] = "keep-alive"
          
          # 将来的にはCookieストアからCookieを取得して追加する
          # headers["Cookie"] = get_cookies_for_domain(item.url.host.to_s)

          # 2. リクエストを実行（現時点ではGET）
          @logger.debug { "リクエスト#{item.request_id}のHTTP GETを実行中、URL: #{item.url}" }
          response = client.get(item.url.request_target, headers: headers)
          @logger.debug { "リクエスト#{item.request_id}のレスポンスヘッダーを受信（ステータス: #{response.status_code}）" }

          # 3. レスポンス受信イベントを配信
          security_info = {
            "protocol" => client.tls.try(&.protocol) || "none",
            "cipher" => client.tls.try(&.cipher) || "none",
            "cert_verified" => client.tls.try(&.verified) || false
          }
          
          dispatch_network_event(
            QuantumEvents::EventType::NETWORK_RESPONSE_RECEIVED,
            QuantumEvents::NetworkResponseReceivedData.new(
              request_id: item.request_id.to_s,
              page_id: item.page_id.to_s,
              url: item.url.to_s,
              status_code: response.status_code,
              headers: response.headers.to_h, # 単純なHashに変換
              security_info: security_info
            )
          )

          # 4. レスポンスボディを処理（ストリーミング）
          body = response.body_io
          if body
            buffer = Bytes.new(8192) # チャンクで読み込み
            total_bytes_read = 0
            start_time = Time.monotonic
            
            while (bytes_read = body.read(buffer)) > 0
              # データを配信する前にキャンセル要求をチェック
              # これにはAtomicBoolやFiberステータスをチェックするようなメカニズムが必要
              # 簡略化：現時点では続行
              chunk = buffer[0, bytes_read]
              total_bytes_read += bytes_read
              
              @logger.trace { "リクエスト#{item.request_id}の#{bytes_read}バイトのデータを配信中" }
              dispatch_network_event(
                QuantumEvents::EventType::NETWORK_DATA_RECEIVED,
                QuantumEvents::NetworkDataReceivedData.new(
                  request_id: item.request_id.to_s,
                  page_id: item.page_id.to_s,
                  data_chunk: chunk, # 実際のバイトを送信
                  bytes_received: bytes_read,
                  total_bytes: total_bytes_read
                )
              )
            end
            
            elapsed_time = Time.monotonic - start_time
            @logger.debug { "リクエスト#{item.request_id}のボディ読み込みが完了（#{total_bytes_read}バイト、#{elapsed_time.total_milliseconds.round(2)}ms）" }
          else
             @logger.debug { "リクエスト#{item.request_id}にはボディコンテンツがありません" }
          end

          # 5. 完了イベントを配信
          @logger.debug { "リクエスト#{item.request_id}の正常完了を配信中" }
          
          # タイミング情報を計算
          timing_info = {
            "total_time" => (Time.utc - item.timestamp).total_milliseconds.round(2),
            "content_type" => response.headers["Content-Type"]? || "unknown"
          }
          
          dispatch_network_event(
            QuantumEvents::EventType::NETWORK_REQUEST_COMPLETED,
            QuantumEvents::NetworkRequestCompletedData.new(
              request_id: item.request_id.to_s,
              page_id: item.page_id.to_s,
              url: item.url.to_s,
              status_code: response.status_code,
              encoded_data_length: response.content_length? || -1, # 利用可能な場合はcontent_lengthを使用
              timing_info: timing_info
            )
          )

        rescue ex : Fiber::Cancelled
          # リクエストは外部からキャンセルされた（例：cancel_active_requestによって）
          # handle_request_finished(cancelled: true)は既に呼び出されている
          @logger.info { "HTTPリクエストFiber #{item.request_id}がキャンセルされました: #{ex.message}" }
          # ここではさらにイベントを配信しない

        rescue ex : IO::TimeoutError
          @logger.warn(exception: ex) { "URL #{item.url}のHTTPリクエスト#{item.request_id}がタイムアウトしました" }
          dispatch_network_event(
            QuantumEvents::EventType::NETWORK_REQUEST_FAILED,
            QuantumEvents::NetworkRequestErrorData.new(
              request_id: item.request_id.to_s,
              page_id: item.page_id.to_s,
              url: item.url.to_s,
              error_message: "リクエストがタイムアウトしました: #{ex.message}",
              status_code: response.try(&.status_code), # ヘッダーが受信された場合はステータスを含める
              error_type: "timeout"
            )
          )
        rescue ex : OpenSSL::Error # TLS/SSLエラーをキャッチ
            @logger.error(exception: ex) { "リクエスト#{item.request_id}、URL #{item.url}のTLS/SSLエラー" }
            dispatch_network_event(
                QuantumEvents::EventType::NETWORK_REQUEST_FAILED,
                QuantumEvents::NetworkRequestErrorData.new(
                    request_id: item.request_id.to_s,
                    page_id: item.page_id.to_s,
                    url: item.url.to_s,
                    error_message: "TLS/SSLエラー: #{ex.message}",
                    error_type: "ssl"
                )
            )
        rescue ex : Socket::Error # DNS解決、接続拒否などのソケットエラー
          @logger.error(exception: ex) { "リクエスト#{item.request_id}、URL #{item.url}のソケットエラー" }
          dispatch_network_event(
            QuantumEvents::EventType::NETWORK_REQUEST_FAILED,
            QuantumEvents::NetworkRequestErrorData.new(
              request_id: item.request_id.to_s,
              page_id: item.page_id.to_s,
              url: item.url.to_s,
              error_message: "ネットワークエラー: #{ex.message}",
              error_type: "network"
            )
          )
        rescue ex # その他の潜在的なエラーをキャッチ
          @logger.error(exception: ex) { "URL #{item.url}のHTTPリクエスト#{item.request_id}が失敗しました" }
          dispatch_network_event(
            QuantumEvents::EventType::NETWORK_REQUEST_FAILED,
            QuantumEvents::NetworkRequestErrorData.new(
              request_id: item.request_id.to_s,
              page_id: item.page_id.to_s,
              url: item.url.to_s,
              error_message: "リクエストが失敗しました: #{ex.message}",
              status_code: response.try(&.status_code),
              error_type: "general"
            )
          )
        ensure
          # 6. クライアントをクリーンアップし、スケジューラでリクエストを完了としてマーク
          client.try &.close
          # 外部からキャンセルされた場合を*除いて*完了としてマーク
          # handle_request_finishedは成功/失敗/外部キャンセルの両方で呼び出される
          unless ex.is_a?(Fiber::Cancelled)
            handle_request_finished(item.request_id)
          end
        end
      end
    end

    # EventDispatcherを介してネットワークイベントを配信するヘルパー
    private def dispatch_network_event(type : QuantumEvents::EventType, data : QuantumEvents::EventData)
        begin
            @event_dispatcher.dispatch(QuantumEvents::Event.new(type, data))
        rescue ex
             @logger.error(exception: ex) { "ネットワークイベントの配信に失敗しました: タイプ=#{type}, データ=#{data.inspect}" }
        end
    end


    # リクエストが完了したとき（成功、エラー、またはキャンセル）に内部的に呼び出される
    private def handle_request_finished(request_id : UInt64, cancelled = false)
      removed_item : RequestItem? = nil
      @mutex.synchronize do
        removed_item = @active_requests.delete(request_id)
      end
      if removed_item
        status = cancelled ? "キャンセル" : "完了"
        @logger.debug { "リクエスト#{request_id}が#{status}しました。アクティブ: #{@active_requests.size}。キューをチェック中。" }
        # スロットが空いたので、次の待機中リクエストのディスパッチを試みる
        try_dispatch_next
      else
        # これはキャンセルが自然完了と同時に発生した場合に起こる可能性がある
        @logger.warn { "不明または既に非アクティブなリクエストID: #{request_id}の完了信号を受信しました" }
      end
    end

    # --- 内部ロジック --- #

    # リクエストを適切な優先度キューに追加し、リクエストIDを返す
    private def add_request(page_id : UInt64, url : URI, priority : Priority, bypass_cache : Bool) : UInt64
      request_id = generate_request_id
      # 最初、fiberはnilです。リクエストがディスパッチされるときに設定されます。
      item = RequestItem.new(request_id, page_id, url, priority, Time.utc, bypass_cache, nil)
      @mutex.synchronize do
        @queues[priority].push(item)
        @logger.debug { "リクエストがキューに追加されました: ID #{request_id}, ページ #{page_id}, URL #{url} (優先度: #{priority}, キャッシュ: #{bypass_cache ? 'バイパス' : '使用'})" }
      end
      try_dispatch_next
      request_id # 生成されたIDを返す
    end

    # 同時実行制限が許可する場合、次の最高優先度リクエストのディスパッチを試みる
    private def try_dispatch_next
      item_to_dispatch : RequestItem? = nil
      can_dispatch = false

      @mutex.synchronize do
        can_dispatch = @active_requests.size < @max_concurrent_requests
        if can_dispatch
          Priority.each do |priority|
            queue = @queues[priority]
            unless queue.empty?
              # ディスパッチするアイテムをキューから取り出す
              item = queue.shift.not_nil!
              # 新しいFiberでリクエストを実行し、Fiber参照を保存
              executing_fiber = execute_request(item)
              # アイテムをFiber参照で更新し、アクティブリクエストに追加
              item_with_fiber = item.copy(fiber: executing_fiber)
              @active_requests[item.request_id] = item_with_fiber
              item_to_dispatch = item_with_fiber # ミューテックス外でのログ用
              break # ディスパッチするアイテムが見つかった
            end
          end
        end
      end

      # ディスパッチをログに記録（ミューテックス外で）
      if item = item_to_dispatch
        @logger.info { "リクエストをディスパッチ中: ID #{item.request_id}, ページ #{item.page_id}, URL #{item.url} (優先度: #{item.priority})。アクティブ: #{@active_requests.size}" }
        # 実際の実行はミューテックス内のexecute_request呼び出しによって既に開始されている
      end
    end

    # 新しいリクエスト用の一意のIDを生成
    private def generate_request_id : UInt64
      @mutex.synchronize do
        @request_id_counter += 1
        @request_id_counter
      end
    end

    # 優先度変更ロジック（直接実行モデルでは大幅な再作業が必要）
    def change_priority(request_id : UInt64, new_priority : Priority)
      item_found = false
      
      @mutex.synchronize do
        # アクティブリクエスト内でアイテムを検索
        if @active_requests.has_key?(request_id)
          @logger.info { "アクティブなリクエスト#{request_id}の優先度を#{new_priority}に変更しようとしましたが、実行中のリクエストの優先度は変更できません" }
          item_found = true
          # 実行中のリクエストの優先度は変更できないため、何もしない
          return
        end
        
        # キュー内でアイテムを検索
        Priority.each do |current_priority|
          queue = @queues[current_priority]
          item_index = queue.index { |item| item.request_id == request_id }
          
          if item_index
            item = queue[item_index]
            # 現在の優先度と新しい優先度が同じ場合は何もしない
            if current_priority == new_priority
              @logger.debug { "リクエスト#{request_id}は既に優先度#{new_priority}です" }
              item_found = true
              return
            end
            
            # キューからアイテムを削除
            queue.delete_at(item_index)
            
            # 新しい優先度キューにアイテムを追加
            updated_item = item.copy(priority: new_priority)
            @queues[new_priority].push(updated_item)
            
            @logger.info { "リクエスト#{request_id}の優先度を#{current_priority}から#{new_priority}に変更しました" }
            item_found = true
            
            # 優先度が上がった場合は、次のディスパッチを試みる
            if new_priority.value < current_priority.value
              try_dispatch_next
            end
            
            return
          end
        end
      end
      
      unless item_found
        @logger.warn { "優先度変更: リクエストID #{request_id}が見つかりません" }
      end
    end

  end # ResourceSchedulerクラス終了
end # QuantumCoreモジュール終了