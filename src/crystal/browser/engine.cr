require "./config"
require "../quantum_network/manager"
require "../quantum_storage/manager"
require "uri"
require "base64"

module QuantumCore
  # QuantumCore::Engine はブラウザコアエンジンを担当し、
  # DOM解析、JavaScript実行、レイアウト、レンダリング、ナビゲーションを総括します。
  class Engine
    # 外部から参照可能なプロパティ
    getter config : Config::CoreConfig
    getter dom_manager : DOMManager
    getter rendering_engine : RenderingEngine
    getter javascript_engine : JavaScriptEngine
    getter layout_engine : LayoutEngine
    getter network : QuantumNetwork::Manager
    getter storage : QuantumStorage::Manager
    getter performance_metrics : PerformanceMetrics
    getter current_page : Page?
    
    # 初期化メソッド
    # @param config [Config::CoreConfig] エンジンコア設定
    # @param network [QuantumNetwork::Manager] ネットワークマネージャ
    # @param storage [QuantumStorage::Manager] ストレージマネージャ
    # @return [Void]
    # @raise [InitializationError] 初期化失敗時
    def initialize(config : Config::CoreConfig, network : QuantumNetwork::Manager, storage : QuantumStorage::Manager)
      @config = config
      @network = network
      @storage = storage
      
      # パフォーマンスメトリクスの初期化
      @performance_metrics = PerformanceMetrics.new
      
      # 現在のページは初期状態ではnil
      @current_page = nil
      
      # エンジンコンポーネントの初期化
      @dom_manager = DOMManager.new(@config)
      @javascript_engine = JavaScriptEngine.new(@config, @dom_manager)
      @layout_engine = LayoutEngine.new(@config)
      @rendering_engine = RenderingEngine.new(@config, @layout_engine)
      
      # イベント処理の設定
      setup_event_handlers
    end
    
    # エンジン起動
    # リソース初期化、各コンポーネント起動、起動メトリクス記録、
    # ホームページのページ生成/読み込みを行います。
    # @return [Void]
    def start
      # 必要なリソースの初期化
      initialize_resources
      
      # エンジンコンポーネントの起動
      @dom_manager.start
      @javascript_engine.start
      @layout_engine.start
      @rendering_engine.start
      
      # 起動メトリクスの記録
      @performance_metrics.record_engine_start
      
      # 新しいページの作成とホームページの読み込み
      create_new_page unless @current_page
    end
    
    # エンジンシャットダウン
    # セッション保存、各コンポーネント停止、リソース解放、
    # シャットダウンメトリクス記録を行います。
    # @return [Void]
    def shutdown
      # ページの状態保存
      save_session_state if @current_page
      
      # エンジンコンポーネントの停止
      @rendering_engine.shutdown
      @layout_engine.shutdown
      @javascript_engine.shutdown
      @dom_manager.shutdown
      
      # リソースの解放
      cleanup_resources
      
      # シャットダウンメトリクスの記録
      @performance_metrics.record_engine_shutdown
    end
    
    # 新規ページ生成
    # 空白ドキュメントを初期化し、デフォルトスタイルシートを適用します。
    # @return [Page] 生成した Page オブジェクト
    def create_new_page
      @current_page = Page.new(@dom_manager, @javascript_engine, @layout_engine, @rendering_engine)
      @current_page.not_nil!.initialize_blank_document
      
      # デフォルトのスタイルシートの適用
      apply_default_stylesheets
      
      @current_page
    end
    
    # URL読み込み
    # 指定URLを正規化しナビゲーションを開始、
    # テキスト/JSON/画像を適切に処理します。
    # @param url [String?] 読み込むURL
    # @return [Void]
    def load_url(url : String?)
      return unless url
      
      # ページがなければ作成
      create_new_page unless @current_page
      
      # URLの正規化
      normalized_url = normalize_url(url)
      
      # 同じURLの場合はリロード
      if @current_page.try(&.url) == normalized_url
        reload
        return
      end
      
      # ページナビゲーションの開始
      @current_page.not_nil!.navigation_start(normalized_url)
      
      # ネットワークリクエストの作成
      request = QuantumNetwork::Request.new(
        url: normalized_url,
        method: "GET",
        headers: {"User-Agent" => @network.config.user_agent}
      )
      
      # リクエストの送信と応答の処理
      @network.send_request(request) do |response|
        handle_page_response(response)
      end
    end
    
    # ページ再読み込み
    # 現在ページの URL を再度リクエストします。
    # @param bypass_cache [Bool] キャッシュをバイパスする場合に true
    # @return [Void]
    def reload(bypass_cache = false)
      return unless current_page = @current_page
      
      # 現在のURL取得
      url = current_page.url
      return unless url
      
      # ナビゲーション開始
      current_page.navigation_start(url, is_reload: true)
      
      # ネットワークリクエストの作成（キャッシュバイパスの設定あり）
      headers = {"User-Agent" => @network.config.user_agent}
      headers["Cache-Control"] = "no-cache" if bypass_cache
      
      request = QuantumNetwork::Request.new(
        url: url,
        method: "GET",
        headers: headers,
        bypass_cache: bypass_cache
      )
      
      # リクエストの送信と応答の処理
      @network.send_request(request) do |response|
        handle_page_response(response)
      end
    end
    
    # ナビゲーション停止
    # 進行中リクエストをキャンセルし、読み込み状態をリセットします。
    # @return [Void]
    def stop_navigation
      return unless current_page = @current_page
      
      # 進行中のリクエストをキャンセル
      @network.cancel_requests_for_page(current_page.id)
      
      # ページの読み込み状態をリセット
      current_page.navigation_stopped
    end
    
    # 履歴戻る
    # ページ履歴を1つ戻して再読み込みします。
    # @return [Void]
    def navigate_back
      return unless current_page = @current_page
      
      # 戻れる履歴があるか確認
      if history_entry = current_page.history.go_back
        load_url(history_entry.url)
      end
    end
    
    # 履歴進む
    # ページ履歴を1つ進めて読み込みます。
    # @return [Void]
    def navigate_forward
      return unless current_page = @current_page
      
      # 進める履歴があるか確認
      if history_entry = current_page.history.go_forward
        load_url(history_entry.url)
      end
    end
    
    # JavaScript実行
    # ページコンテキスト内でスクリプトを評価します。
    # @param code [String] 実行するJSコード
    # @return [Any | Nil] 実行結果または nil
    def execute_javascript(code : String)
      return nil unless current_page = @current_page
      
      # JavaScriptエンジンでコードを実行
      @javascript_engine.execute(current_page.context, code)
    end
    
    # セッション保存
    # 現在のページ状態を永続ストレージに保存します。
    # @return [Void]
    def save_session_state
      return unless current_page = @current_page
      
      # 現在のセッション状態の保存
      session_data = {
        "url" => current_page.url,
        "title" => current_page.title,
        "scroll_position" => current_page.scroll_position,
        "history" => current_page.history.serialize
      }
      
      @storage.save_session_data(session_data)
    end
    
    # セッション復元
    # 保存されたセッションデータから前回の URL を読み込みます。
    # @return [Void]
    def restore_session_state
      # 保存されたセッションデータの取得
      if session_data = @storage.load_session_data
        # URLがあれば読み込み
        if url = session_data["url"]?.as?(String)
          load_url(url)
        end
      end
    end
    
    private def initialize_resources
      # メモリプールの初期化
      MemoryManager.initialize(@config.max_memory_usage_mb)
      
      # レンダリングコンテキストの初期化
      if @config.use_hardware_acceleration
        RenderingContext.initialize_hardware_accelerated
      else
        RenderingContext.initialize_software
      end
    end
    
    private def cleanup_resources
      # メモリプールの解放
      MemoryManager.cleanup
      
      # レンダリングコンテキストの解放
      RenderingContext.cleanup
    end
    
    private def setup_event_handlers
      # DOMイベントハンドラ
      @dom_manager.on_document_ready do |document|
        @performance_metrics.record_dom_content_loaded
      end
      
      # レンダリングイベントハンドラ
      @rendering_engine.on_first_paint do
        @performance_metrics.record_first_paint
      end
      
      @rendering_engine.on_first_contentful_paint do
        @performance_metrics.record_first_contentful_paint
      end
      
      # JavaScriptイベントハンドラ
      @javascript_engine.on_parse_error do |error|
        handle_javascript_error(error)
      end
    end
    
    private def handle_page_response(response)
      return unless current_page = @current_page
      
      # レスポンスのステータスコードに基づく処理
      case response.status_code
      when 200..299 # 成功
        # コンテンツタイプの確認
        content_type = response.headers["Content-Type"]? || "text/html"
        
        if content_type.includes?("text/html")
          # HTMLコンテンツの処理
          parse_and_render_html(current_page, response.body)
        elsif content_type.includes?("application/json")
          # JSONコンテンツの処理
          parse_and_render_json(current_page, response.body)
        elsif content_type.starts_with?("image/")
          # 画像コンテンツの処理
          render_image(current_page, response.body, content_type)
        else
          # その他のコンテンツはダウンロード扱い
          handle_download(response)
        end
        
        # ページのURLと履歴を更新
        current_page.navigation_complete(response.url)
        
      when 300..399 # リダイレクト
        # リダイレクト先URLの取得
        if redirect_url = response.headers["Location"]?
          # リダイレクト先に移動
          load_url(redirect_url)
        else
          # リダイレクト先がない場合はエラー
          show_error_page(current_page, "無効なリダイレクト", "リダイレクト先のURLが指定されていません")
        end
        
      when 400..599 # エラー
        # エラーページの表示
        show_error_page(current_page, "ページを読み込めませんでした", "エラー #{response.status_code}: #{response.status_message}")
        
      end
    end
    
    private def parse_and_render_html(page, html_content)
      # HTMLのパース
      document = @dom_manager.parse_html(html_content)
      
      # ページにドキュメントを設定
      page.set_document(document)
      
      # 外部リソース（CSS、JavaScript）の読み込み
      load_external_resources(page, document)
      
      # レイアウト計算
      @layout_engine.layout(document)
      
      # 画面へのレンダリング
      @rendering_engine.render(document)
      
      # DOMContentLoadedイベントの発火
      page.fire_dom_content_loaded
      
      # すべてのリソースが読み込まれた後にloadイベントを発火
      check_and_fire_load_event(page)
    end
    
    private def parse_and_render_json(page, json_content)
      # JSONビューワー用のHTMLテンプレート
      html_template = <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>JSON Viewer</title>
        <style>
          body { font-family: monospace; }
          .json-viewer { white-space: pre; }
        </style>
      </head>
      <body>
        <div class="json-viewer">#{html_escape(json_content)}</div>
        <script>
          try {
            const jsonData = #{json_content};
            const formattedJson = JSON.stringify(jsonData, null, 2);
            document.querySelector('.json-viewer').textContent = formattedJson;
          } catch (e) {
            document.querySelector('.json-viewer').textContent = 
              "JSONパースエラー: " + e.message + "\\n\\n" + document.querySelector('.json-viewer').textContent;
          }
        </script>
      </body>
      </html>
      HTML
      
      # HTMLとして処理
      parse_and_render_html(page, html_template)
    end
    
    private def render_image(page, image_data, content_type)
      # 画像ビューワー用のHTMLテンプレート
      html_template = <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>Image Viewer</title>
        <style>
          body {
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background: #f0f0f0;
          }
          img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
          }
        </style>
      </head>
      <body>
        <img src="data:#{content_type};base64,#{Base64.strict_encode(image_data)}" />
      </body>
      </html>
      HTML
      
      # HTMLとして処理
      parse_and_render_html(page, html_template)
    end
    
    private def handle_download(response)
      # ダウンロードマネージャーの取得
      download_manager = @storage.download_manager
      
      # ファイル名の推測
      filename = extract_filename_from_response(response)
      
      # ダウンロードの開始
      download_manager.start_download(response.url, filename, response.body, response.headers["Content-Type"]?)
    end
    
    private def extract_filename_from_response(response)
      # Content-Dispositionヘッダーからファイル名を取得
      if content_disposition = response.headers["Content-Disposition"]?
        if content_disposition.includes?("filename=")
          filename = content_disposition.split("filename=")[1].split(";")[0].strip
          filename = filename.gsub(/^"|"$/, "") # 引用符の削除
          return filename
        end
      end
      
      # URLからファイル名を抽出
      url_path = URI.parse(response.url).path
      filename = File.basename(url_path)
      
      # ファイル名が空または無効な場合は現在時刻をファイル名にする
      if filename.empty? || filename == "/"
        time = Time.utc.to_s("%Y%m%d%H%M%S")
        content_type = response.headers["Content-Type"]? || "application/octet-stream"
        extension = mime_type_to_extension(content_type)
        filename = "download_#{time}#{extension}"
      end
      
      filename
    end
    
    private def mime_type_to_extension(mime_type)
      # MIMEタイプから拡張子を推測
      case mime_type
      when .includes?("text/html")
        ".html"
      when .includes?("text/plain")
        ".txt"
      when .includes?("application/json")
        ".json"
      when .includes?("image/jpeg")
        ".jpg"
      when .includes?("image/png")
        ".png"
      when .includes?("image/gif")
        ".gif"
      when .includes?("application/pdf")
        ".pdf"
      when .includes?("application/zip")
        ".zip"
      else
        ".bin"
      end
    end
    
    private def show_error_page(page, title : String, message : String)
      # 簡易エラーページを表示します
      html = <<-HTML
      <html><body><h1>#{title}</h1><p>#{message}</p></body></html>
      HTML
      parse_and_render_html(page, html)
    end
    
    private def load_external_resources(page, document)
      # <link rel="stylesheet"> 要素からCSSを取得
      document.get_elements_by_tag_name("link").each do |link|
        if link.get_attribute("rel") == "stylesheet"
          href = link.get_attribute("href")
          request = QuantumNetwork::Request.new(url: href, method: "GET")
          @network.send_request(request) do |resp|
            if resp.status_code.between?(200, 299)
              page.add_stylesheet(resp.body)
            end
          end
        end
      end
      # <script src=> 要素からJSを取得し実行
      document.get_elements_by_tag_name("script").each do |script|
        src = script.get_attribute("src")
        next unless src
        request = QuantumNetwork::Request.new(url: src, method: "GET")
        @network.send_request(request) do |resp|
          if resp.status_code.between?(200, 299)
            @javascript_engine.execute(page.context, resp.body)
          end
        end
      end
    end
    
    private def check_and_fire_load_event(page)
      # ページロード完了イベント発火
      spawn do
        # リソース読み込み待機（必要に応じて適切な実装に置換）
        sleep 0.5
        page.fire_load
      end
    end
    
    private def html_escape(text)
      text.gsub(/[&<>"']/) do |char|
        case char
        when '&' then "&amp;"
        when '<' then "&lt;"
        when '>' then "&gt;"
        when '"' then "&quot;"
        when '\'' then "&#39;"
        else char
        end
      end
    end
    
    private def normalize_url(url : String) : String
      # URLを正規化します。
      begin
        uri = URI.parse(url)
        # スキームがない場合はHTTPを補完
        uri.scheme ? url : "http://#{url}"
      rescue ex
        # パース失敗時は元の文字列を返す
        url
      end
    end
    
    private def apply_default_stylesheets(page)
      # デフォルトスタイルを適用します
      css = <<-CSS
      body { margin: 0; padding: 0; }
      CSS
      encoded = Base64.strict_encode(css)
      page.add_stylesheet("data:text/css;base64,#{encoded}")
    end
    
    private def handle_javascript_error(error)
      # JSエラーのログ記録
      @performance_metrics.record_javascript_error(error)
      
      # 開発者モードの場合はコンソールにエラーを表示
      if @config.developer_mode
        puts "JavaScriptエラー: #{error.message} at #{error.filename}:#{error.line}:#{error.column}"
      end
    end
    
    # ユーザーエージェントのデフォルトスタイルシート
    DEFAULT_USER_AGENT_STYLESHEET = <<-CSS
    html, body {
      margin: 0;
      padding: 0;
      height: 100%;
    }
    
    body {
      font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;
      font-size: 16px;
      line-height: 1.5;
      color: #333;
    }
    
    h1 { font-size: 2em; margin: 0.67em 0; }
    h2 { font-size: 1.5em; margin: 0.75em 0; }
    h3 { font-size: 1.17em; margin: 0.83em 0; }
    h4 { font-size: 1em; margin: 1.12em 0; }
    h5 { font-size: 0.83em; margin: 1.5em 0; }
    h6 { font-size: 0.75em; margin: 1.67em 0; }
    
    p { margin: 1em 0; }
    
    a { color: #0066cc; text-decoration: underline; }
    a:visited { color: #551a8b; }
    a:hover { text-decoration: none; }
    
    ul, ol { margin: 1em 0; padding-left: 40px; }
    li { margin: 0.5em 0; }
    
    table { border-collapse: collapse; }
    th, td { border: 1px solid #ccc; padding: 0.5em; }
    
    pre, code { font-family: monospace; }
    
    img { max-width: 100%; height: auto; }
    CSS
  end
end 