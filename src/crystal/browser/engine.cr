require "./config"
require "../quantum_network/manager"
require "../quantum_storage/manager"

module QuantumCore
  # ブラウザエンジンのコア部分
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
    
    # エンジンの起動
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
    
    # エンジンのシャットダウン
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
    
    # 新しいページの作成
    def create_new_page
      @current_page = Page.new(@dom_manager, @javascript_engine, @layout_engine, @rendering_engine)
      @current_page.not_nil!.initialize_blank_document
      
      # デフォルトのスタイルシートの適用
      apply_default_stylesheets
      
      @current_page
    end
    
    # URLのロード
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
    
    # ページのリロード
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
    
    # ナビゲーションの停止
    def stop_navigation
      return unless current_page = @current_page
      
      # 進行中のリクエストをキャンセル
      @network.cancel_requests_for_page(current_page.id)
      
      # ページの読み込み状態をリセット
      current_page.navigation_stopped
    end
    
    # 戻る操作
    def navigate_back
      return unless current_page = @current_page
      
      # 戻れる履歴があるか確認
      if history_entry = current_page.history.go_back
        load_url(history_entry.url)
      end
    end
    
    # 進む操作
    def navigate_forward
      return unless current_page = @current_page
      
      # 進める履歴があるか確認
      if history_entry = current_page.history.go_forward
        load_url(history_entry.url)
      end
    end
    
    # JavaScriptの実行
    def execute_javascript(code : String)
      return nil unless current_page = @current_page
      
      # JavaScriptエンジンでコードを実行
      @javascript_engine.execute(current_page.context, code)
    end
    
    # セッション状態の保存
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
    
    # セッション状態の復元
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
    
    private def show_error_page(page, title, message)
      # エラーページのHTMLテンプレート
      html_template = <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>#{html_escape(title)}</title>
        <style>
          body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            margin: 0;
            padding: 20px;
            text-align: center;
            background-color: #f8f9fa;
            color: #343a40;
          }
          .error-container {
            max-width: 600px;
            padding: 40px;
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
          }
          h1 {
            font-size: 24px;
            margin-bottom: 20px;
            color: #e63946;
          }
          p {
            font-size: 16px;
            line-height: 1.5;
            margin-bottom: 20px;
          }
          button {
            background-color: #4361ee;
            color: white;
            border: none;
            padding: 10px 20px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 14px;
            transition: background-color 0.2s;
          }
          button:hover {
            background-color: #3a56e4;
          }
        </style>
      </head>
      <body>
        <div class="error-container">
          <h1>#{html_escape(title)}</h1>
          <p>#{html_escape(message)}</p>
          <button onclick="window.location.reload()">再読み込み</button>
        </div>
      </body>
      </html>
      HTML
      
      # HTMLとして処理
      parse_and_render_html(page, html_template)
    end
    
    private def load_external_resources(page, document)
      # CSS リンクの検出とロード
      css_links = document.query_selector_all("link[rel=stylesheet]")
      css_links.each do |link|
        if href = link["href"]?
          url = resolve_url(page.url, href)
          load_stylesheet(page, url)
        end
      end
      
      # スクリプトの検出とロード
      scripts = document.query_selector_all("script[src]")
      scripts.each do |script|
        if src = script["src"]?
          url = resolve_url(page.url, src)
          load_script(page, url)
        end
      end
      
      # 画像の検出と先読み
      images = document.query_selector_all("img[src]")
      images.each do |img|
        if src = img["src"]?
          url = resolve_url(page.url, src)
          preload_image(url)
        end
      end
    end
    
    private def load_stylesheet(page, url)
      # CSSの読み込みリクエスト
      request = QuantumNetwork::Request.new(
        url: url,
        method: "GET",
        headers: {"User-Agent" => @network.config.user_agent}
      )
      
      # リクエストの送信と応答の処理
      @network.send_request(request) do |response|
        if response.status_code >= 200 && response.status_code < 300
          # CSSのパース
          stylesheet = @dom_manager.parse_css(response.body)
          
          # スタイルシートの適用
          page.add_stylesheet(stylesheet)
          
          # レイアウトの再計算
          @layout_engine.layout(page.document)
          
          # 再レンダリング
          @rendering_engine.render(page.document)
          
          # リソース読み込み状態の更新
          page.resource_loaded(url)
        else
          # エラー処理
          page.resource_failed(url, "ステータスコード: #{response.status_code}")
        end
      end
    end
    
    private def load_script(page, url)
      # JavaScriptの読み込みリクエスト
      request = QuantumNetwork::Request.new(
        url: url,
        method: "GET",
        headers: {"User-Agent" => @network.config.user_agent}
      )
      
      # リクエストの送信と応答の処理
      @network.send_request(request) do |response|
        if response.status_code >= 200 && response.status_code < 300
          # JavaScriptの実行
          @javascript_engine.execute(page.context, response.body, url)
          
          # リソース読み込み状態の更新
          page.resource_loaded(url)
        else
          # エラー処理
          page.resource_failed(url, "ステータスコード: #{response.status_code}")
        end
      end
    end
    
    private def preload_image(url)
      # 画像の先読みリクエスト
      request = QuantumNetwork::Request.new(
        url: url,
        method: "GET",
        headers: {"User-Agent" => @network.config.user_agent}
      )
      
      # リクエストの送信（応答は単にキャッシュに格納）
      @network.send_request(request) do |_|
        # 応答の処理は特に何もしない（キャッシュに格納されるだけ）
      end
    end
    
    private def check_and_fire_load_event(page)
      # すべてのリソースの読み込み状況を確認
      if page.all_resources_loaded?
        # すべてのリソースがロードされた時のイベント発火
        page.fire_load_event
        
        # パフォーマンスメトリクスの記録
        @performance_metrics.record_page_loaded
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
    
    private def normalize_url(url)
      # 相対URL、スキーム無しURLの正規化
      if url.starts_with?("//")
        # スキーム無しのURLにhttpsを追加
        return "https:#{url}"
      elsif !url.includes?("://")
        # URLスキームが無ければhttpsを追加
        if url.starts_with?("http")
          url = "https://#{url.sub(/^http/, "")}"
        else
          url = "https://#{url}"
        end
      end
      
      url
    end
    
    private def resolve_url(base_url, relative_url)
      # 絶対URLの場合はそのまま返す
      return relative_url if relative_url.includes?("://")
      
      # ベースURLが無い場合は相対URLをそのまま返す
      return relative_url unless base_url
      
      # ベースURLからのパス解決
      base_uri = URI.parse(base_url)
      
      if relative_url.starts_with?("/")
        # ルート相対パス
        "#{base_uri.scheme}://#{base_uri.host}#{relative_url}"
      else
        # 相対パス
        base_path = base_uri.path
        base_dir = base_path.rindex('/') ? base_path[0...base_path.rindex('/')] : ""
        "#{base_uri.scheme}://#{base_uri.host}#{base_dir}/#{relative_url}".gsub(/\/\.\//, "/").gsub(/[^\/]+\/\.\.\//, "")
      end
    end
    
    private def apply_default_stylesheets
      return unless current_page = @current_page
      
      # ユーザーエージェントのデフォルトスタイルシート
      user_agent_stylesheet = @dom_manager.parse_css(DEFAULT_USER_AGENT_STYLESHEET)
      current_page.add_stylesheet(user_agent_stylesheet, priority: :user_agent)
      
      # ユーザー設定のスタイルシート
      if user_stylesheet = @storage.load_user_stylesheet
        user_defined_stylesheet = @dom_manager.parse_css(user_stylesheet)
        current_page.add_stylesheet(user_defined_stylesheet, priority: :user)
      end
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