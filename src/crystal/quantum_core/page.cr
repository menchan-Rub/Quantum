require "./engine"
require "./security_context"
require "../events/**"
require "../utils/logger"
require "random"
require "uri"
require "log"
require "weak_ref" # weak_ref を使用するために追加

require "../common/*"
require "../events/event_dispatcher" # Use the unified dispatcher
require "./resource_scheduler"
require "./navigation_history"

module QuantumCore
  # QuantumCore::Page: ページの状態、ライフサイクル、ナビゲーション、インタラクションを管理するクラス。
  # 単一のブラウザページ（タブ）に対応。
  class Page
    Log = ::Log.for(self) # Crystal の Log モジュールを使用

    # ページの可能な読み込み状態を定義します。
    enum LoadState
      Idle         # 初期状態、または停止/失敗/完了後。
      Navigating   # ナビゲーション開始、リクエストスケジュール済み。
      Loading      # レスポンス受信中およびリソース読み込み中。
      Interactive  # メインドキュメント解析済み、インタラクション可能 (推定)。
      Complete     # 既知のすべてのリソースが正常に読み込まれました。
      Failed       # ナビゲーションまたは読み込みが致命的に失敗しました。
    end

    # --- Public Getters --- #
    getter id : UInt64                       # ページの一意な識別子。
    getter url : URI?                        # 現在読み込まれている URL (初期状態または失敗後は nil)。
    getter title : String                    # 現在のページタイトル。
    getter load_state : LoadState            # 現在の読み込み状態。
    getter load_progress : Float64           # 読み込み進捗 (0.0 から 1.0)。
    getter security_context : SecurityContext # 現在のセキュリティコンテキスト。
    getter history : NavigationHistory       # ページ固有のナビゲーション履歴。
    getter is_crashed : Bool                 # 関連するレンダラプロセスがクラッシュしたかどうかを示します。
    getter pending_url : URI?                # 現在ナビゲーション中の URL を取得

    # --- Internal State --- #
    @mutex : Mutex                           # ページ状態へのスレッドセーフなアクセスのための Mutex。
    @event_dispatcher : QuantumEvents::EventDispatcher # 注入された依存関係。
    @resource_scheduler : ResourceScheduler           # 注入された依存関係。
    @logger : ::Log::Context                 # ページごとのロガーコンテキスト。

    # 必要に応じてネットワークイベントデータを一時的に保存するためのプロパティを追加
    @current_request_id : UInt64? # メインリソースリクエストのIDを追跡
    @favicon_url : String? # ファビコンのURLを保存
    @error_state : Tuple(Int32, String)? # 最後のエラー詳細を保存
    @expected_content_length : Int64? # 進捗計算のために期待されるコンテンツ長を保存
    @received_bytes : Int64        # これまでに受信したバイト数を保存
    @chunk_counter : Int32         # データチャンクID用カウンタ

    # 購読解除のためにイベントリスナー参照を保存
    @listener_references = {} of QuantumEvents::EventType => Proc(QuantumEvents::Event, Nil)

    # 新しい Page インスタンスを初期化します。
    # @param id [UInt64] PageManager から提供されるユニークページID
    # @param event_dispatcher [QuantumEvents::EventDispatcher] イベントディスパッチャ
    # @param resource_scheduler [ResourceScheduler] リソース取得スケジューラ
    # @param initial_url [String?] 初期読み込みURL（省略時はabout:blank）
    def initialize(@id : UInt64, @event_dispatcher : QuantumEvents::EventDispatcher, @resource_scheduler : ResourceScheduler, initial_url : String? = nil)
      @mutex = Mutex.new
      @url = nil
      @pending_url = nil
      @title = "New Tab" # 新しいページのデフォルトタイトル
      @load_state = LoadState::Idle
      @load_progress = 0.0
      @security_context = SecurityContext.new(@id.to_s, @event_dispatcher)
      @history = NavigationHistory.new
      @is_crashed = false
      @logger = Log.for("Page<#{@id}>")
      @logger.level = ::Log::Severity.parse(ENV.fetch("LOG_LEVEL", "INFO"))
      @current_request_id = nil
      @favicon_url = nil
      @error_state = nil
      @expected_content_length = nil
      @received_bytes = 0_i64
      @chunk_counter = 0_i32

      @logger.info { "Initialized." }
      # このページインスタンスに関連するネットワークイベントを購読
      setup_network_event_listeners
      # PageCreated イベントをディスパッチ
      @event_dispatcher.dispatch(QuantumEvents::Event.new(
        QuantumEvents::EventType::PAGE_CREATED,
        QuantumEvents::PageCreatedData.new(@id.to_s, initial_url || "about:blank")
      ))

      # URL が指定されている場合、初期ナビゲーションを開始
      if url_str = initial_url
        unless url_str.empty? || url_str == "about:blank"
            navigate(url_str, is_user_initiated: false)
        end
      else
          @logger.debug { "No initial URL provided, remaining idle." }
      end
    end

    # --- Public API Methods --- #

    # 指定されたURLへナビゲーションを開始します。
    # @param url_string [String] ナビゲート先のURL
    # @param is_user_initiated [Bool] ユーザー操作による起動かどうか
    # @param bypass_cache [Bool] キャッシュをバイパスする場合はtrue
    def navigate(url_string : String, is_user_initiated : Bool = true, bypass_cache : Bool = false)
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        should_dispatch_history_update = false
        new_uri : URI? = nil

        # 1. URL の解析と検証 (潜在的な例外のため mutex の外で実行)
        begin
            parsed_uri = URI.parse(url_string)
            # 基本的な検証
            unless parsed_uri.scheme && (parsed_uri.host || parsed_uri.scheme == "file")
                raise URI::Error.new("Scheme and host required (or file:// scheme)")
            end
            new_uri = parsed_uri
        rescue ex : URI::Error
            @logger.error(exception: ex) { "Invalid URL format: '#{url_string}'" }
            # 状態を更新し、エラーをディスパッチ (mutex が必要)
            @mutex.synchronize do
                update_state_internal(LoadState::Failed)
                dispatch_load_error(url_string, 400, "Invalid URL format")
            end
            return
        end

        # 続行する前に new_uri が nil でないことを確認
        current_navigation_uri = new_uri.not_nil!

        @mutex.synchronize do
            @logger.info { "Navigation requested: '#{url_string}', User initiated: #{is_user_initiated}" }

            # 2. 既存の読み込みプロセスを停止
            stoppable_states = [LoadState::Navigating, LoadState::Loading, LoadState::Interactive]
            if stoppable_states.includes?(@load_state)
                @logger.debug { "Stopping previous load (state: #{@load_state}) before navigating." }
                stop_loading_internal(dispatch_event: false)
            end

            # 3. 新しいナビゲーションのためにページ状態をリセット
            @pending_url = current_navigation_uri # ターゲット URL を保存
            @is_crashed = false
            @current_request_id = nil # 新しいナビゲーションのためにリクエスト ID をリセット
            update_state_internal(LoadState::Navigating)
            @load_progress = 0.0
            @expected_content_length = nil # 進捗追跡をリセット
            @received_bytes = 0_i64
            update_title_internal(url_string) # タイトルを初期的に URL に設定
            reset_security_context_internal
            # @favicon_url = nil # ファビコンをリセットするか？ 古いものを保持するか？
            @error_state = nil # 以前のエラー状態をクリア

            # 4. ユーザーが開始した場合、履歴を更新
            # 注意: 履歴エントリは `handle_network_completion` で正常に完了したときに追加されるようになりました

            # 5. Load Start イベントをディスパッチ
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::PAGE_LOAD_START,
                QuantumEvents::PageLoadStartData.new(@id.to_s, url_string)
            ))

            # 6. ResourceScheduler を介してリソース取得をスケジュール
            @logger.debug { "Requesting resource fetch for: #{current_navigation_uri}" }
            begin
                # ResourceScheduler はネットワークリクエストの開始を担当します
                # そして、コールバック (イベント経由) が最終的にこのページ ID に対してトリガーされることを保証します。
                @current_request_id = @resource_scheduler.request_main_resource(@id, current_navigation_uri, bypass_cache)
                if @current_request_id
                    @logger.debug { "Resource request scheduled with ID: #{@current_request_id}" }
                    update_state_internal(LoadState::Loading) # Loading 状態に遷移
                else
                    # スケジューラが即座に失敗/拒否した場合のケースを処理
                    raise "ResourceScheduler failed to schedule main resource for #{current_navigation_uri}"
                end
            rescue ex # スケジューリング中に発生する可能性のあるエラーをキャッチ
                @logger.error(exception: ex) { "Failed to schedule resource request for '#{current_navigation_uri}'" }
                update_state_internal(LoadState::Failed)
                dispatch_load_error(url_string, 500, "Failed to schedule resource request")
                return # ナビゲーションを停止
            end
        end # mutex 同期終了

        # 履歴更新は handle_network_completion で処理されるようになりました
        # # 7. 必要に応じて履歴更新をディスパッチ (mutex の外で)
        # if should_dispatch_history_update
        #     dispatch_history_update_if_changed(previous_history_state)
        # end
    end

    # 履歴を一つ戻ります。
    # @return [Void]
    def go_back
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        url_to_navigate = nil
        @mutex.synchronize do
            entry = @history.go_back
            if entry
                @logger.info { "Navigating back to: #{entry.url}" }
                url_to_navigate = entry.url.to_s # URI から文字列 URL を取得
            else
                @logger.debug { "Cannot go back, already at the beginning of history." }
            end
        end
        # mutex の外でナビゲーションを実行し、イベントをディスパッチ
        if url = url_to_navigate
            navigate(url, is_user_initiated: false, bypass_cache: false) # ユーザーが開始していないナビゲーションを実行
            # ここで履歴更新をディスパッチする必要はありません。ナビゲーションが完了時に処理します
      end
    end
    
    # 履歴を一つ進みます。
    # @return [Void]
    def go_forward
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        url_to_navigate = nil
        @mutex.synchronize do
            entry = @history.go_forward
            if entry
                @logger.info { "Navigating forward to: #{entry.url}" }
                url_to_navigate = entry.url.to_s # URI から文字列 URL を取得
            else
                @logger.debug { "Cannot go forward, already at the end of history." }
            end
        end
        # mutex の外でナビゲーションを実行し、イベントをディスパッチ
        if url = url_to_navigate
            navigate(url, is_user_initiated: false, bypass_cache: false) # ユーザーが開始していないナビゲーションを実行
             # ここで履歴更新をディスパッチする必要はありません。ナビゲーションが完了時に処理します
        end
    end

    # 現在のページをリロードします。
    # @param bypass_cache [Bool] キャッシュをバイパスする場合はtrue
    def reload(bypass_cache = false)
        url_to_reload : String? = nil
        @mutex.synchronize do
            # 利用可能な場合は現在のコミットされた URL を使用し、それ以外の場合は最後の保留中の URL を使用します。
            current_uri = @url || @pending_url
            url_to_reload = current_uri.to_s if current_uri
        end

        if current_url = url_to_reload
          unless current_url.empty?
            @logger.info { "Reloading: #{current_url}, Bypass cache: #{bypass_cache}" }
            navigate(current_url, is_user_initiated: false, bypass_cache: bypass_cache)
          else
            @logger.warn { "Cannot reload, no current or pending URL available." }
          end
        else
            @logger.warn { "Cannot reload, no current or pending URL available." }
        end
    end

    # 現在のページロードを停止します。
    # @return [Void]
    def stop_loading
        @mutex.synchronize do
            stop_loading_internal(dispatch_event: true)
        end
    end

    # ページリソースをクリーンアップし、終了イベントをディスパッチします。
    # @return [Void]
    def cleanup
      @logger.info { "Cleaning up page resources." }
      # 最初にリスナーの購読を解除
      unsubscribe_network_event_listeners
      @mutex.synchronize do
        stop_loading_internal(dispatch_event: false)
        # PageDestroyed イベントをディスパッチ
        @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::PAGE_DESTROYED,
            QuantumEvents::PageDestroyedData.new(@id.to_s)
        ))
        # ResourceScheduler にこのページに関連付けられたリソースを解放するよう通知
        @resource_scheduler.page_closed(@id)
        # 内部状態をクリア
        clear_internal_state
      end
      @logger.debug { "Cleanup complete." }
    end

    # --- ネットワークイベントハンドラ (EventDispatcher によって呼び出される) --- #

    # このページに関連するネットワークイベントのリスナーを設定します。
    private def setup_network_event_listeners
        # Page が何かへの参照を保持し、それが EventDispatcher への参照を保持している場合にサイクルを避けるために WeakRef を使用
        page_ref = WeakRef.new(self)

        # ハンドラを proc として定義し、購読解除のために参照を保存
        @listener_references[QuantumEvents::EventType::NETWORK_RESPONSE_RECEIVED] = ->(event : QuantumEvents::Event) do
            page = page_ref.target
            return unless page # ページがまだ存在するかどうかを確認

            if data = event.data_as?(QuantumEvents::NetworkResponseReceivedData)
                # 比較のためにイベント文字列から page_id を UInt64 に変換
                event_page_id = data.page_id.to_u64?
                if event_page_id && event_page_id == page.id
                    page.handle_network_response(data)
                end
            end
        rescue ex # ハンドラ内の潜在的なエラーをキャッチ
            page = page_ref.target
            page.logger.error(exception: ex) { "Error handling NETWORK_RESPONSE_RECEIVED" } if page
        end

        @listener_references[QuantumEvents::EventType::NETWORK_DATA_RECEIVED] = ->(event : QuantumEvents::Event) do
            page = page_ref.target
            return unless page

            if data = event.data_as?(QuantumEvents::NetworkDataReceivedData)
                event_page_id = data.page_id.to_u64?
                if event_page_id && event_page_id == page.id
                    page.handle_network_data(data)
                end
            end
        rescue ex
            page = page_ref.target
            page.logger.error(exception: ex) { "Error handling NETWORK_DATA_RECEIVED" } if page
        end

        @listener_references[QuantumEvents::EventType::NETWORK_REQUEST_COMPLETED] = ->(event : QuantumEvents::Event) do
            page = page_ref.target
            return unless page

            if data = event.data_as?(QuantumEvents::NetworkRequestCompletedData)
                event_page_id = data.page_id.to_u64?
                event_request_id = data.request_id.to_u64?
                # ページ ID が一致し、かつ (リクエスト ID が現在のものと一致するか、特定のリクエスト ID が追跡されていない場合) に処理
                if event_page_id && event_page_id == page.id && (page.current_request_id.nil? || event_request_id == page.current_request_id)
                    page.handle_network_completion(data, success: true)
                end
            end
        rescue ex
            page = page_ref.target
            page.logger.error(exception: ex) { "Error handling NETWORK_REQUEST_COMPLETED" } if page
        end

        @listener_references[QuantumEvents::EventType::NETWORK_REQUEST_FAILED] = ->(event : QuantumEvents::Event) do
            page = page_ref.target
            return unless page

            if data = event.data_as?(QuantumEvents::NetworkRequestErrorData)
                event_page_id = data.page_id.to_u64?
                event_request_id = data.request_id.to_u64?
                 # ページ ID が一致し、かつ (リクエスト ID が現在のものと一致するか、特定のリクエスト ID が追跡されていない場合) に処理
                if event_page_id && event_page_id == page.id && (page.current_request_id.nil? || event_request_id == page.current_request_id)
                     page.handle_network_completion(data, success: false)
                end
            end
        rescue ex
            page = page_ref.target
            page.logger.error(exception: ex) { "Error handling NETWORK_REQUEST_FAILED" } if page
        end

        # 定義された proc を使用して購読
        @listener_references.each do |type, handler|
            @event_dispatcher.subscribe(type, &handler)
        end
        @logger.debug { "Network event listeners subscribed." }
    end

    # このページに関連付けられたすべてのネットワークイベントリスナーの購読を解除します。
    private def unsubscribe_network_event_listeners
        count = 0
        @listener_references.each do |type, handler|
            if @event_dispatcher.unsubscribe(type, handler)
                count += 1
            else
                 @logger.warn { "Could not unsubscribe handler for event type: #{type}" }
            end
        end
        @listener_references.clear # 保存された参照をクリア
        @logger.debug { "Unsubscribed #{count} network event listeners." }
    end


    # 初期ネットワーク応答 (ヘッダー、ステータス、セキュリティ) を処理します。
    private def handle_network_response(data : QuantumEvents::NetworkResponseReceivedData)
        redirect_url : String? = nil

        @mutex.synchronize do
            # Loading 状態であり、かつリクエスト ID が現在のメインリクエストと一致する場合にのみ処理
            current_req_id = @current_request_id
            event_req_id = data.request_id.to_u64?

            # 状態が適切であり、かつリクエスト ID が一致する場合にのみ処理
            unless @load_state == LoadState::Loading && event_req_id == current_req_id
                @logger.warn { "Ignoring network response for Request #{event_req_id}: Mismatched state (#{@load_state}) or request ID (Expected: #{current_req_id})" }
                return
            end

            @logger.debug { "Handling network response for Request #{event_req_id} (Status: #{data.status_code})" }

            # リダイレクトを確認 (3xx ステータスコード)
            if data.status_code >= 300 && data.status_code < 400
               location = data.headers["Location"]? || data.headers["location"]?
               if location
                   @logger.info { "Handling redirect (Status #{data.status_code}) to: #{location}" }
                   # 現在の保留中の URL を基準にリダイレクト URL を解決
                   resolved_location = resolve_redirect_url(location)
                   redirect_url = resolved_location # mutex の外でのナビゲーションのために保存
                   # リダイレクトのヘッダー/セキュリティは処理せず、ナビゲーションの準備のみを行う
                   return
               else
                   @logger.warn { "Received redirect status #{data.status_code} but no Location header found. Treating as failure." }
                   # エラーとして扱う - 状態を設定し、エラーをディスパッチ
                   update_state_internal(LoadState::Failed)
                   dispatch_load_error(@pending_url?.to_s, data.status_code, "Redirect missing Location header")
                   return
               end
            end

            # リダイレクトではない、現在のナビゲーションのレスポンス処理を続行

            # 進捗計算のために期待されるコンテンツ長を保存
            content_length_str = data.headers["Content-Length"]? || data.headers["content-length"]?
            if content_length_str
                @expected_content_length = content_length_str.to_i64?
                @logger.debug { "Expected content length: #{@expected_content_length || "Unknown"}" }
            else
                @expected_content_length = nil # 不明な長さを示す
            end
            @received_bytes = 0_i64 # このレスポンスのために受信バイト数をリセット

            # レスポンスに基づいてセキュリティコンテキストを更新
            level = if @pending_url?.try(&.scheme) == "https"
                QuantumEvents::SecurityLevel::Secure
            else
                QuantumEvents::SecurityLevel::Insecure
            end
            
            # セキュリティ情報の詳細を取得
            security_info = data.security_details
            security_summary = if level == QuantumEvents::SecurityLevel::Secure
                if security_info
                    "Secure connection (#{security_info.protocol} #{security_info.cipher})"
                else
                    "Secure connection (HTTPS)"
                end
            else
                "Insecure connection"
            end
            
            update_security_context(level, security_summary)

            # ヘッダー受信を示すために進捗をわずかに更新
            update_progress(0.05)

            # コンテンツタイプに基づいて早期インタラクティブ状態への移行を判断
            content_type = data.headers["Content-Type"]? || data.headers["content-type"]?
            if content_type && content_type.starts_with?("text/html")
                # HTMLコンテンツの場合、早期にインタラクティブ状態に移行
                update_state_internal(LoadState::Interactive)
            end

            # キャッシュ制御ヘッダーの処理
            cache_control = data.headers["Cache-Control"]? || data.headers["cache-control"]?
            if cache_control
                # キャッシュ設定を適用（将来的にキャッシュシステムと連携）
                @logger.debug { "Cache-Control header: #{cache_control}" }
                # キャッシュ関連の処理をここに実装
            end
        end # mutex 同期終了

        # 必要に応じて mutex の外でリダイレクトナビゲーションを実行
        if location = redirect_url
            # イベントハンドラスレッドのブロックを避けるために spawn を使用
            spawn navigate(location, is_user_initiated: false)
        end
    end

    # 受信データチャンクを処理します (進捗更新、レンダラーへのストリーミングの可能性あり)。
    private def handle_network_data(data : QuantumEvents::NetworkDataReceivedData)
         @mutex.synchronize do
             # Loading 状態であり、かつリクエスト ID が一致する場合にのみ処理
             current_req_id = @current_request_id
             event_req_id = data.request_id.to_u64?

             unless @load_state == LoadState::Loading && event_req_id == current_req_id
                 @logger.trace { "Ignoring network data for Request #{event_req_id}: Mismatched state (#{@load_state}) or request ID (Expected: #{current_req_id})" }
                 return
             end

             @logger.trace { "Received #{data.data_chunk.bytesize} bytes for Request #{event_req_id}" }
             @received_bytes += data.data_chunk.bytesize

             # 期待されるコンテンツ長と受信バイト数に基づいて進捗を更新
             if expected = @expected_content_length
                 if expected > 0
                    progress = @received_bytes.to_f / expected.to_f
                    update_progress(progress) # 計算された進捗で更新
                 else
                    # Content-Length が 0 だった場合、進捗をわずかに更新するか？ それとも完了を待つか？
                    update_progress(0.5) # 任意の進捗上昇
                 end
             else
                 # 不明なコンテンツ長、受信チャンクに基づいて進捗を更新 (精度は低い)
                 # 単純なアプローチ: 各チャンクで進捗をわずかに増加
                 new_progress = @load_progress + 0.05 # 増加係数
                 update_progress(new_progress)
             end

             # データを受信した場合、初期ナビゲーションフェーズは過ぎている可能性が高い
             if @load_state == LoadState::Loading
                 # データがいくつか到着したら Interactive 状態への移行を検討する、
                 # 特に HTML の場合 (ここではコンテンツタイプをチェックしません)
                 update_state_internal(LoadState::Interactive)
             end

             # データチャンクをチャンクIDと共にPAGE_RENDER_CHUNKイベントとしてディスパッチ
             chunk_id = @chunk_counter
             @chunk_counter += 1
             @event_dispatcher.dispatch(QuantumEvents::Event.new(
               QuantumEvents::EventType::PAGE_RENDER_CHUNK,
               QuantumEvents::PageRenderChunkData.new(
                 @id.to_s,
                 chunk_id,
                 data.data_chunk,
                 0, 0,
                 data.data_chunk.bytesize,
                 1
               )
             ))
         end
    end
    
    # メインネットワークリクエストの完了または失敗を処理します。
    private def handle_network_completion(data : QuantumEvents::NetworkRequestCompletedData | QuantumEvents::NetworkRequestErrorData, success : Bool)
        url_str : String? = nil
        status_code : Int32 = 0
        error_msg : String? = nil
        final_url_uri : URI? = nil

        # 最初に mutex 内で状態をキャプチャ
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        final_title : String? = nil # 成功時に設定
        should_add_history = false

        @mutex.synchronize do
            # この完了が追跡していたナビゲーションに対応することを確認します。
            # 主に pending_url と照合します。
            # pending_url が早期にクリアされた場合 (例: stop によって)、@url をフォールバックとして使用します。
            url_str = @pending_url?.to_s || @url?.to_s

            # 冗長な更新を避けるために、すでに完了、失敗、またはアイドル状態かどうかを確認します
            return if @load_state.in?(LoadState::Complete, LoadState::Failed, LoadState::Idle)

            # 成功/失敗に基づいて詳細を抽出
            case data
            when QuantumEvents::NetworkRequestCompletedData
                status_code = data.status_code
                # ステータスがエラー (例: 4xx, 5xx) を示さない限り、完了は成功を意味すると仮定します
                was_successful = status_code >= 200 && status_code < 300 # 基本的な成功チェック
                if !was_successful
                    success = false # ステータスコードがエラーを示す場合、成功フラグを上書きします
                    error_msg = "Request completed with error status: #{status_code}"
                end
            when QuantumEvents::NetworkRequestErrorData
                success = false # 明示的に失敗
                status_code = data.status_code? || 500 # 利用可能であればデータからステータスを使用し、それ以外の場合は一般的なサーバーエラーを使用します
                error_msg = data.error_message || "Network request failed"
            end

            # --- コアページ状態の更新 --- #
            new_state = success ? LoadState::Complete : LoadState::Failed
            update_state_internal(new_state)

            if success
                @load_progress = 1.0
                final_url_uri = @pending_url # 正常に読み込まれた URL
                @url = final_url_uri         # 保留中の URL を現在の URL としてコミット
                @pending_url = nil           # 保留中の URL をクリア
                # 最終的なタイトルは読み込み中に JS によって更新された可能性があるため、現在のタイトルを保持します。
                final_title = @title
                should_add_history = true    # 履歴追加をマーク

                @logger.info { "Load complete for: #{url_str} (Status: #{status_code})" }
                # 完了イベントをディスパッチ
                @event_dispatcher.dispatch(QuantumEvents::Event.new(
                    QuantumEvents::EventType::PAGE_LOAD_COMPLETE,
                    QuantumEvents::PageLoadCompleteData.new(@id.to_s, url_str, status_code)
                ))
                # 最終進捗更新をディスパッチ
                dispatch_progress_update(1.0)

            else
                @logger.warn { "Load failed for: #{url_str} (Status: #{status_code}, Error: #{error_msg})" }
                @error_state = {status_code, error_msg.not_nil!}
                # 失敗時に URL をコミットしません。以前の @url があれば保持します
                @pending_url = nil # 保留中の URL を関係なくクリア
                final_url_str = @url?.to_s || url_str.not_nil! # イベントには最後の正常な URL または失敗した URL を使用
                update_title_internal("Error Loading Page") # エラーを反映するようにタイトルを更新
                # エラーイベントをディスパッチ
                dispatch_load_error(final_url_str, status_code, error_msg.not_nil!)
                # 最終進捗更新をディスパッチ (任意、最後の既知の進捗のままでも可)
                dispatch_progress_update(@load_progress) # 現在の進捗をディスパッチ
            end
        end # mutex 同期終了

        # --- Mutex 後の操作 --- #

        # mutex が解放され、成功した場合に *のみ* 履歴エントリを追加
        if should_add_history && (committed_uri = final_url_uri) && (committed_title = final_title)
            # 履歴操作は内部的に同期されます
            @history.add_entry(committed_uri, committed_title)
            # can_go_back/forward が変更された場合に *のみ* 履歴更新イベントをディスパッチ
            dispatch_history_update_if_changed(previous_history_state)
        elsif !success
            # 失敗時、変更された場合は履歴状態表示を更新する必要があるかもしれません
            # (例: 戻るナビゲーション中に失敗した場合)。
            dispatch_history_update_if_changed(previous_history_state)
        end
    end

    # --- 以前は外部コンポーネントから呼び出されていたが、現在は内部の可能性のあるメソッド --- #

    # タイトルを更新するために外部から (例: レンダラー/JavaScript ブリッジによって) 呼び出されます。
    def update_title(new_title : String)
        updated = false
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        @mutex.synchronize do
            # コンテンツが処理または表示されている状態の場合にのみ、タイトル更新を許可します
            if @load_state.in?(LoadState::Loading, LoadState::Interactive, LoadState::Complete)
                 updated = update_title_internal(new_title)
            else
                @logger.debug { "Ignoring title update ('#{new_title}') in state: #{@load_state}"}
            end
        end
        # タイトル変更が現在の履歴エントリのタイトルに影響した場合にのみ、履歴更新をディスパッチします
        dispatch_history_update_if_changed(previous_history_state) if updated # チェックは現在冗長かもしれません
    end

    # ファビコンを更新するために外部から (例: レンダラー/JavaScript ブリッジによって) 呼び出されます。
    def update_favicon(new_favicon_url : String?)
         @mutex.synchronize do
             # ほとんどのアクティブな状態でファビコン更新を許可します
             if @load_state.in?(LoadState::Loading, LoadState::Interactive, LoadState::Complete)
                 if @favicon_url != new_favicon_url
                     @favicon_url = new_favicon_url
                     @event_dispatcher.dispatch(QuantumEvents::Event.new(
                         QuantumEvents::EventType::PAGE_FAVICON_CHANGED,
                         QuantumEvents::PageFaviconChangedData.new(@id.to_s, new_favicon_url)
                     ))
                     @logger.debug { "Favicon updated to '#{new_favicon_url || "None"}'" }
                 end
             else
                 @logger.debug { "Ignoring favicon update in state: #{@load_state}"}
             end
         end
    end

    # 進捗を更新し、イベントをディスパッチする内部ヘルパー、クランプを保証します。
    private def update_progress(progress : Float64)
        # mutex が保持されていると仮定します
        clamped_progress = {0.0, progress, 1.0}.sort[1]
        relevant_states = [LoadState::Loading, LoadState::Interactive]
        if @load_progress != clamped_progress && relevant_states.includes?(@load_state)
            @load_progress = clamped_progress
            @logger.trace { "Load progress: #{(@load_progress * 100).round(1)}%" }
            # パフォーマンスのために mutex の外でイベントをディスパッチすることが推奨されますが、ここではより単純です
            dispatch_progress_update(@load_progress)
        end
    end

    # 進捗更新イベントをディスパッチするヘルパー。
    private def dispatch_progress_update(progress : Float64)
         # ディスパッチャはスレッドセーフです
         @event_dispatcher.dispatch(QuantumEvents::Event.new(
             QuantumEvents::EventType::PAGE_LOAD_PROGRESS,
             QuantumEvents::PageLoadProgressData.new(@id.to_s, progress)
         ))
    end

    # セキュリティコンテキストが変更されたときに外部または内部から呼び出されます。
    def update_security_context(level : QuantumEvents::SecurityLevel, summary : String, details : String = "")
        @mutex.synchronize do
            new_context = SecurityContext.new(level, summary, details)
            if @security_context != new_context
                @logger.debug { "Security context updated: #{level} (#{summary})" }
                @security_context = new_context
                @event_dispatcher.dispatch(QuantumEvents::Event.new(
                    QuantumEvents::EventType::PAGE_SECURITY_CONTEXT_CHANGED,
                    QuantumEvents::PageSecurityContextChangedData.new(@id.to_s, level, summary)
                ))
            end
        end
    end

    # 関連するレンダラプロセスがクラッシュしたときに Engine または Process Monitor によって呼び出されます。
    def handle_crash
        previous_history_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        @mutex.synchronize do
            return if @is_crashed
            @logger.error { "Renderer process for page #{@id} crashed!" }
            @is_crashed = true
            crashed_url = (@pending_url || @url).to_s
            # このページに関連する進行中のネットワークアクティビティを停止します
            @resource_scheduler.cancel_requests_for_page(@id)
            update_state_internal(LoadState::Failed)
            update_title_internal("Aw, Snap!") # クラッシュを示すようにタイトルを更新します
            error_msg = "Renderer process crashed"
            @error_state = {500, error_msg} # クラッシュには 500 またはカスタムコードを使用します
            # 読み込みエラーイベントをディスパッチします
            dispatch_load_error(crashed_url, 500, error_msg)
            # 保留中の URL がクリアされることを確認します
            @pending_url = nil
        end
        # 必要に応じて履歴ボタンの状態を更新します (通常、クラッシュ時には変更なし)
        dispatch_history_update_if_changed(previous_history_state)
    end

    # ページをクラッシュ状態としてマークし、ロードを失敗状態に移行します。
    # @param reason [String] クラッシュ理由
    def mark_as_crashed(reason : String)
      @mutex.synchronize do
        return if @is_crashed
        @is_crashed = true
        update_state_internal(LoadState::Failed)
        update_title_internal("クラッシュ: #{reason}")
      end
      # クラッシュイベントをディスパッチ
      @event_dispatcher.dispatch(QuantumEvents::Event.new(
        QuantumEvents::EventType::PAGE_CRASHED,
        QuantumEvents::PageCrashedData.new(@id.to_s, reason)
      ))
    end

    # --- 内部ヘルパーメソッド --- #

    # 内部: 読み込みを停止し、リクエストをキャンセルし、状態を更新します。mutex が保持されていると仮定します。
    private def stop_loading_internal(dispatch_event : Bool)
        stoppable_states = [LoadState::Navigating, LoadState::Loading, LoadState::Interactive]
        return unless stoppable_states.includes?(@load_state)

        stopped_url = (@pending_url || @url).to_s
        @logger.info { "Stopping page load internally for #{stopped_url} (State: #{@load_state})" }

        # 現在のページ ID の ResourceScheduler にキャンセルを通知します
        # これにより、@current_request_id で識別されるリクエストが設定されている場合にキャンセルされることを確認します
        @resource_scheduler.cancel_requests_for_page(@id)
        # レンダラプロセスへの停止通知はDOMマネージャに委譲されます

        previous_state = @load_state
        update_state_internal(LoadState::Idle) # Idle 状態に戻します
        @pending_url = nil # 保留中のナビゲーションターゲットをクリアします
        @current_request_id = nil # 追跡されたリクエスト ID をクリアします

        # 状態が実際に停止可能な状態から変更された場合にのみ PageStopped をディスパッチします
        if dispatch_event && previous_state != LoadState::Idle
            # 推奨される場合は mutex の外でイベントをディスパッチします
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::PAGE_STOPPED,
                QuantumEvents::PageStoppedData.new(@id.to_s)
            ))
        end
    end

    # 内部: 読み込み状態を更新し、関連する状態リセットを処理します。mutex が保持されていると仮定します。
    private def update_state_internal(new_state : LoadState)
        if @load_state != new_state
            old_state = @load_state
            @load_state = new_state
            @logger.debug { "Load state changed: #{old_state} -> #{new_state}" }
            # 非終端/非読み込み状態に移行するときに、進捗/エラー/追跡をリセットします
            if new_state.in?(LoadState::Idle, LoadState::Navigating)
                @load_progress = 0.0
                @expected_content_length = nil
                @received_bytes = 0_i64
                 # 失敗状態を離れるか、明示的にリセットする場合にのみエラーをクリアします
                @error_state = nil unless old_state == LoadState::Failed && new_state != LoadState::Idle
            elsif new_state == LoadState::Failed && @error_state.nil?
                # 明示的なエラーなしで Failed に移行する場合、エラー状態が設定されることを確認します
                 @error_state = {-1, "Unknown load failure"}
            elsif new_state.in?(LoadState::Loading, LoadState::Interactive, LoadState::Complete)
                # 読み込みを正常に開始または進行するときにエラー状態をクリアします
                @error_state = nil
            end
      end
    end
    
    # 内部: タイトルを更新し、イベントをディスパッチし、履歴エントリを更新します。mutex が保持されていると仮定します。
    private def update_title_internal(new_title : String) : Bool
        changed = false
        # タイトルが実際に異なり、空でない場合にのみ更新します
        if !new_title.empty? && @title != new_title
            old_title = @title
            @title = new_title
            # ページ URL が現在の履歴エントリの URL と一致する場合に *のみ*、対応する履歴エントリのタイトルを更新します。
            # これにより、戻る/進むナビゲーションの読み込み中に過去のエントリのタイトルが更新されるのを防ぎます。
            current_history_entry = @history.current_entry?
            page_url_str = @url?.to_s # マッチングには *コミットされた* URL を使用します
            if current_history_entry && page_url_str == current_history_entry.url.to_s
               # 履歴の同期メソッドを使用します
               @history.update_current_entry_title(new_title)
            end
            # イベントをディスパッチします
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::PAGE_TITLE_CHANGED,
                QuantumEvents::PageTitleChangedData.new(@id.to_s, new_title)
            ))
            @logger.debug { "Title updated internally from '#{old_title}' to '#{new_title}'" }
            changed = true
        end
        changed
    end

    # 内部: セキュリティコンテキストをデフォルト (None) にリセットします。mutex が保持されていると仮定します。
    private def reset_security_context_internal
        default_context = SecurityContext.new(QuantumEvents::SecurityLevel::None, "", "")
        if @security_context != default_context
            old_level = @security_context.level
            @security_context = default_context
            @logger.debug { "Security context reset to None." }
            # 非デフォルト状態からリセットする場合にのみイベントをディスパッチします
            if old_level != QuantumEvents::SecurityLevel::None
                @event_dispatcher.dispatch(QuantumEvents::Event.new(
                    QuantumEvents::EventType::PAGE_SECURITY_CONTEXT_CHANGED,
                    QuantumEvents::PageSecurityContextChangedData.new(@id.to_s, default_context.level, default_context.summary)
                ))
            end
      end
    end
    
    # 内部: PAGE_LOAD_ERROR イベントをディスパッチします。適切な場合に呼び出されると仮定します。
    private def dispatch_load_error(url_str : String, status_code : Int32, message : String)
         # mutex を保持しているかどうかに関わらず呼び出すことができます。ディスパッチャはスレッドセーフです
         @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::PAGE_LOAD_ERROR,
            QuantumEvents::PageLoadErrorData.new(@id.to_s, url_str, status_code, message)
        ))
    end

    # 内部: can_go_back/forward が変更された場合、PAGE_HISTORY_UPDATE をディスパッチします。
    private def dispatch_history_update_if_changed(previous_state)
        # mutex の外で呼び出されます。履歴メソッドは内部的に同期されます
        current_state = {can_back: @history.can_go_back?, can_forward: @history.can_go_forward?}
        if previous_state != current_state
            @logger.debug { "Dispatching History Update: Back: #{current_state[:can_back]}, Forward: #{current_state[:can_forward]}" }
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::PAGE_HISTORY_UPDATE,
                QuantumEvents::HistoryUpdateData.new(@id.to_s, current_state[:can_back], current_state[:can_forward]) # ページ ID を追加
            ))
      end
    end
    
    # 内部: 主要な状態変数をクリアします。mutex が保持されていると仮定します。
    private def clear_internal_state
        @load_state = LoadState::Idle
        @url = nil
        @pending_url = nil
        @title = "Closed Tab"
        @load_progress = 0.0
        @security_context.reset
        @history.clear
        @is_crashed = false
        @error_state = nil
        @favicon_url = nil
        @current_request_id = nil
        @expected_content_length = nil
        @received_bytes = 0_i64
        @chunk_counter = 0_i32
    end

    # リダイレクト URL を解決するためのヘルパー (相対パスを処理します)。ベース URI が既知の場合に呼び出されると仮定します。
    private def resolve_redirect_url(location : String) : String
        # @pending_url が設定されており、mutex が保持されているか、URL が安定していると仮定します
        base_uri = @pending_url
        unless base_uri
            @logger.error { "Cannot resolve redirect URL '#{location}' without a base URI (pending_url is nil)." }
            return location # 解決できません、元の場所を返します
        end

        begin
            resolved_uri = base_uri.resolve(URI.parse(location))
            return resolved_uri.to_s
        rescue ex : URI::Error
            @logger.warn(exception: ex) { "Failed to parse or resolve redirect URL '#{location}' relative to '#{base_uri}'. Using location as is." }
            return location # フォールバックとして location をそのまま使用します
      end
    end

end # クラス Page 終了
end # モジュール QuantumCore 終了
end # モジュール QuantumCore 終了