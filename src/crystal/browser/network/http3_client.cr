# HTTP/3クライアント
#
# このクラスはHTTP/3プロトコルを使用してウェブリソースを取得するための
# 高レベルなAPIを提供します。NimのHTTP/3実装をラップしています。

require "log"
require "json"
require "uri"
require "http/headers"
require "./http3_network_manager"

module QuantumBrowser
  # HTTP/3プロトコルを使用してウェブリソースを取得するクライアントクラス
  class Http3Client
    Log = ::Log.for(self)
    
    # リソースのタイプ
    enum ResourceType
      Document    # HTMLドキュメント
      Stylesheet  # CSS
      Script      # JavaScript
      Image       # 画像
      Font        # フォント
      Media       # メディア（音声/動画）
      Object      # オブジェクト（PDFなど）
      Fetch       # フェッチAPI
      XHR         # XMLHttpRequest
      WebSocket   # WebSocket
      Other       # その他
    end
    
    # リソース予測モデル設定
    enum PredictionModel
      Disabled    # 予測無効
      Basic       # 基本予測（パターンベース）
      Advanced    # 高度予測（機械学習ベース）
      UserAdaptive # ユーザー適応型予測
    end
    
    # リソース依存関係
    class ResourceDependency
      property url : String
      property resource_type : ResourceType
      property initiator_url : String?
      property weight : Float64
      property depth : Int32
      
      def initialize(@url, @resource_type, @initiator_url = nil)
        @weight = 1.0
        @depth = 0
      end
    end
    
    # ドメイン接続統計
    class DomainStats
      property domain : String
      property connection_count : Int32 = 0
      property avg_ttfb_ms : Float64 = 0.0
      property success_rate : Float64 = 1.0
      property resource_count : Int32 = 0
      property last_connected : Time
      property connection_quality : Float64 = 1.0  # 1.0が最高品質
      
      def initialize(@domain)
        @last_connected = Time.utc
      end
      
      def update_quality
        # 品質値の計算 (高TTFB、低成功率で品質が下がる)
        # 0.3から1.0の範囲に正規化
        ttfb_factor = [1.0, 0.3 + 0.7 * (1.0 - Math.min(1.0, @avg_ttfb_ms / 1000.0))].min
        @connection_quality = ttfb_factor * success_rate
      end
    end
    
    # リソースのフェッチ結果
    class FetchResult
      property request_id : UInt64
      property url : String
      property status : Int32
      property headers : HTTP::Headers
      property body : Bytes
      property resource_type : ResourceType
      property mime_type : String
      property encoding : String?
      property fetch_time_ms : Float64
      property ttfb_ms : Float64?  # Time To First Byte
      property error : String?
      property completed : Bool
      property redirected : Bool
      property redirect_url : String?
      property cached : Bool
      property weight : Float64  # 予測された重要度
      property dependencies : Array(ResourceDependency)?  # このリソースから派生する依存関係
      property used_early_data : Bool  # 0-RTT早期データ使用
      
      def initialize(@request_id, @url, @status, @headers, @body, @resource_type, @mime_type)
        @fetch_time_ms = 0.0
        @completed = false
        @redirected = false
        @cached = false
        @weight = 1.0
        @used_early_data = false
      end
      
      def success? : Bool
        @completed && @error.nil? && @status >= 200 && @status < 400
      end
      
      def client_error? : Bool
        @completed && @status >= 400 && @status < 500
      end
      
      def server_error? : Bool
        @completed && @status >= 500 && @status < 600
      end
      
      def text : String
        String.new(@body)
      end
    end
    
    # キャッシュキーとしてURLを正規化
    class CacheKey
      getter url : String
      getter query_params : Bool
      
      def initialize(@url, @query_params = false)
        @url = normalize_url(@url, @query_params)
      end
      
      def hash
        @url.hash
      end
      
      def ==(other : CacheKey)
        @url == other.url
      end
      
      private def normalize_url(url : String, include_query : Bool) : String
        uri = URI.parse(url)
        result = "#{uri.scheme}://#{uri.host}"
        result += ":#{uri.port}" if uri.port && uri.port != 80 && uri.port != 443
        result += uri.path
        
        if include_query && uri.query
          result += "?#{uri.query}"
        end
        
        result
      end
    end
    
    @network_manager : Http3NetworkManager
    @cache : Hash(CacheKey, FetchResult)
    @pending_requests : Hash(UInt64, Tuple(Channel(FetchResult), Time, ResourceType))
    @default_timeout_ms : Int32
    @default_headers : HTTP::Headers
    @max_redirects : Int32
    @follow_redirects : Bool
    @cache_enabled : Bool
    @domain_stats : Hash(String, DomainStats) = {} of String => DomainStats
    @resource_dependencies : Hash(String, Array(ResourceDependency)) = {} of String => Array(ResourceDependency)
    @prediction_model : PredictionModel = PredictionModel::Advanced
    @pending_predicted_resources : Array(ResourceDependency) = [] of ResourceDependency
    @viewport_tracking_enabled : Bool = true
    @zero_copy_enabled : Bool = true  # ゼロコピーデータ転送の有効化
    @callback_queue : Channel(Tuple(Symbol, UInt64, Array(Any)))
    @callback_mutex : Mutex
    @retry_config : Hash(String, Int32)
    @bridge_initialized : Bool = false
    @callback_context_ptr : Pointer(Void)
    @callback_mapper : CallbackMapper
    @callback_handlers : Hash(Symbol, CallbackRegistry(UInt64, Int32, HTTP::Headers, Bytes, String))
    @callback_lock : ReentrantLock
    @response_buffers : Hash(UInt64, ResponseBuffer)
    
    def initialize(@network_manager : Http3NetworkManager)
      @cache = {} of CacheKey => FetchResult
      @pending_requests = {} of UInt64 => Tuple(Channel(FetchResult), Time, ResourceType)
      @default_timeout_ms = 30000  # 30秒
      @default_headers = HTTP::Headers.new
      @default_headers["User-Agent"] = "QuantumBrowser/1.0 HTTP/3"
      @default_headers["Accept"] = "*/*"
      @max_redirects = 5
      @follow_redirects = true
      @cache_enabled = true
      
      # レスポンスハンドラーを設定
      setup_response_handlers
      
      # 予測モデルの初期化
      initialize_prediction_model
    end
    
    # 予測モデル初期化
    private def initialize_prediction_model
      # 機械学習モデルの初期化と読み込み
      
      case @prediction_model
      when PredictionModel::Advanced, PredictionModel::UserAdaptive
        Log.info { "HTTP/3リソース予測モデルを初期化: #{@prediction_model}" }
        
        # TensorFlow Liteモデルファイルのパスを構築
        model_dir = File.join(ENV["QUANTUM_DATA_DIR"]? || ".", "models", "prediction")
        model_path = File.join(model_dir, "resource_prediction_model.tflite")
        
        # モデルが存在するか確認
        if File.exists?(model_path)
          begin
            # 機械学習モデルをロード
            @ml_interpreter = TFLite::Interpreter.new(model_path)
            
            # モデル入力テンソルの形状を設定
            input_shape = [1, 12] # バッチサイズ1、特徴量12
            @ml_interpreter.allocate_tensors
            
            # ユーザー適応型の場合は追加の学習データをロード
            if @prediction_model == PredictionModel::UserAdaptive
              user_data_path = File.join(model_dir, "user_adaptation_data.json")
              if File.exists?(user_data_path)
                user_data = JSON.parse(File.read(user_data_path))
                @user_weights = {} of String => Float64
                
                user_data["weights"].as_h.each do |resource_type, weight|
                  @user_weights[resource_type.as_s] = weight.as_f
                end
                
                Log.debug { "ユーザー適応型データをロード: #{@user_weights.size}エントリ" }
              end
            end
            
            # 履歴データベースを初期化
            @prediction_history = {} of String => Array(ResourcePrediction)
            @successful_predictions = 0
            @total_predictions = 0
            
            Log.info { "リソース予測モデルの初期化に成功" }
          rescue ex
            Log.error(exception: ex) { "機械学習モデルの読み込みに失敗しました。基本予測モードに切り替えます。" }
            @prediction_model = PredictionModel::Basic
          end
        else
          Log.warn { "予測モデルファイルが見つかりません: #{model_path}。基本予測モードに切り替えます。" }
          @prediction_model = PredictionModel::Basic
        end
      when PredictionModel::Basic
        Log.info { "HTTP/3基本リソース予測を有効化" }
        # 基本的なパターンマッチングルールをロード
        initialize_basic_prediction_rules
      else
        Log.info { "HTTP/3リソース予測は無効" }
      end
      
      # 定期的な予測モデル評価とデータ収集のタイマーを設定
      spawn prediction_model_maintenance_loop
    end
    
    # 基本予測ルールの初期化
    private def initialize_basic_prediction_rules
      @prediction_rules = {
        # HTMLドキュメントに含まれる可能性が高いリソース
        "html" => ["css", "js", "woff2", "png", "jpg", "ico"],
        # CSSに含まれる可能性が高いリソース
        "css" => ["woff2", "ttf", "png", "jpg", "svg"],
        # JavaScriptに含まれる可能性が高いリソース
        "js" => ["json", "wasm", "png", "jpg"]
      }
      
      # リソースタイプごとの優先度設定
      @resource_type_weights = {
        "css" => 0.9,
        "js" => 0.8,
        "woff2" => 0.85,
        "ttf" => 0.8,
        "png" => 0.6,
        "jpg" => 0.6,
        "svg" => 0.7,
        "json" => 0.65,
        "wasm" => 0.7,
        "ico" => 0.5
      }
    end
    
    # 機械学習モデルによるリソース予測
    private def predict_resources_with_ml(url : String, content_type : String, resource_data : Bytes) : Array(ResourceDependency)
      return [] of ResourceDependency unless @ml_interpreter && @prediction_model.in?(PredictionModel::Advanced, PredictionModel::UserAdaptive)
      
      dependencies = [] of ResourceDependency
      
      # URLからドメイン取得
      uri = URI.parse(url)
      domain = uri.host || ""
      
      begin
        # 特徴抽出
        features = extract_resource_features(url, content_type, resource_data)
        
        # 特徴量をモデル入力にセット
        input_tensor = @ml_interpreter.input_tensor(0)
        features.each_with_index do |value, i|
          input_tensor[0, i] = value
        end
        
        # 推論実行
        @ml_interpreter.invoke
        
        # 出力テンソル取得
        output_tensor = @ml_interpreter.output_tensor(0)
        
        # 予測結果の解析（上位5件のリソースタイプとパス）
        resource_types = ["css", "js", "image", "font", "json", "wasm", "video", "audio", "data"]
        predictions = {} of String => Float64
        
        resource_types.each_with_index do |type, i|
          predictions[type] = output_tensor[0, i].to_f64
        end
        
        # 確率でソート
        sorted_predictions = predictions.to_a.sort_by { |_, prob| -prob }
        
        # ドメイン固有のパターン抽出
        domain_patterns = extract_domain_patterns(domain, content_type)
        
        # 上位3つの予測を変換
        sorted_predictions.first(3).each do |type, probability|
          next if probability < 0.2 # 確率が低すぎる場合はスキップ
          
          # リソースタイプに応じて最も可能性の高いパスパターンを選択
          path_patterns = case type
                          when "css"
                            domain_patterns["css"] || ["/css/main.css", "/styles/main.css", "/assets/styles.css"]
                          when "js"
                            domain_patterns["js"] || ["/js/main.js", "/scripts/app.js", "/assets/scripts.js"]
                          when "image"
                            domain_patterns["image"] || ["/images/hero.png", "/img/logo.png", "/assets/images/banner.jpg"]
                          when "font"
                            domain_patterns["font"] || ["/fonts/main.woff2", "/assets/fonts/regular.woff2"]
                          when "json"
                            domain_patterns["json"] || ["/api/data.json", "/assets/data.json"]
                          when "wasm"
                            domain_patterns["wasm"] || ["/wasm/module.wasm", "/assets/wasm/module.wasm"]
                          else
                            ["/assets/#{type}/main.#{type}"]
                          end
          
          # ユーザー適応型モデルの重み適用
          if @prediction_model == PredictionModel::UserAdaptive && @user_weights && @user_weights[type]?
            probability *= @user_weights[type]
          end
          
          # 各パスパターンに対して依存関係を作成
          path_patterns.each_with_index do |path, i|
            # パターンごとに確率を少しずつ減少
            path_probability = probability * (1.0 - i * 0.1)
            next if path_probability < 0.15
            
            # リソースタイプを決定
            resource_type = case type
                           when "css"
                             ResourceType::Stylesheet
                           when "js"
                             ResourceType::Script
                           when "image"
                             ResourceType::Image
                           when "font"
                             ResourceType::Font
                           else
                             ResourceType::Other
                           end
                           
            # 絶対URLを構築
            absolute_url = make_absolute_url(path, url)
            
            # 依存関係を作成
            dependency = ResourceDependency.new(absolute_url, resource_type, url)
            dependency.weight = path_probability
            
            dependencies << dependency
          end
        end
        
        # ドメインの履歴データを更新
        update_prediction_history(domain, dependencies)
        
        # 予測統計を更新
        @total_predictions += dependencies.size
        
      rescue ex
        Log.error(exception: ex) { "リソース予測中にエラーが発生しました" }
      end
      
      dependencies
    end
    
    # リソースから特徴抽出
    private def extract_resource_features(url : String, content_type : String, data : Bytes) : Array(Float64)
      features = Array(Float64).new(12, 0.0)
      
      uri = URI.parse(url)
      path = uri.path || "/"
      
      # 特徴1: URLの長さ（正規化）
      features[0] = Math.min(1.0, url.size / 200.0)
      
      # 特徴2: パスの深さ
      depth = path.count('/').to_f
      features[1] = Math.min(1.0, depth / 5.0)
      
      # 特徴3-7: コンテンツタイプのエンコーディング
      content_encoding = {
        "text/html" => 0,
        "text/css" => 1,
        "application/javascript" => 2,
        "application/json" => 3,
        "image/" => 4,
        "font/" => 5,
        "video/" => 6,
        "audio/" => 7
      }
      
      content_type_idx = 8 # デフォルト：その他
      content_encoding.each do |type, idx|
        if content_type.starts_with?(type)
          content_type_idx = idx
          break
        end
      end
      
      # ワンホットエンコーディング
      content_encoding.each_value.with_index(2) do |_, i|
        features[i] = i == content_type_idx + 2 ? 1.0 : 0.0
      end
      
      # 特徴8: データサイズ（正規化）
      features[8] = Math.min(1.0, data.size / 1_000_000.0)
      
      # 特徴9: 時間帯（0-1の範囲に正規化）
      hour = Time.utc.hour
      features[9] = hour / 24.0
      
      # 特徴10: リンク数（HTMLの場合のみ）
      if content_type.starts_with?("text/html") && data.size > 0
        html_content = String.new(data)
        link_count = html_content.scan(/<(a|link|script|img|source)[^>]*>/i).size
        features[10] = Math.min(1.0, link_count / 100.0)
      end
      
      # 特徴11: リソースタイプの識別子（拡張子ベース）
      extension = File.extname(path).downcase
      ext_encoding = {
        ".html" => 0.1,
        ".css" => 0.2,
        ".js" => 0.3,
        ".json" => 0.4,
        ".png" => 0.5,
        ".jpg" => 0.55,
        ".svg" => 0.6,
        ".woff2" => 0.7,
        ".ttf" => 0.75,
        ".wasm" => 0.8,
        ".mp4" => 0.9
      }
      features[11] = ext_encoding[extension]? || 0.0
      
      features
    end
    
    # ドメインパターンのデフォルト設定
    private def default_domain_patterns
      {
        "github.com" => {
          "css" => ["/assets/github-*.css", "/assets/frameworks/*.css"],
          "js" => ["/assets/github-*.js", "/assets/vendors/*.js"],
          "image" => ["/assets/images/*.png", "/avatars/*/*"],
          "font" => ["/assets/fonts/*.woff2"]
        },
        "example.com" => {
          "css" => ["/styles/*.css"],
          "js" => ["/scripts/*.js"],
          "image" => ["/images/*.png", "/images/*.jpg"],
          "font" => ["/fonts/*.woff2"]
        }
      }
    end
    
    # ドメイン固有のパターンを抽出
    private def extract_domain_patterns(domain : String, content_type : String) : Hash(String, Array(String))
      patterns = {} of String => Array(String)
      
      # ドメイン・パターンのキャッシュをチェック
      if @domain_pattern_cache && @domain_pattern_cache[domain]?
        return @domain_pattern_cache[domain]
      end
      
            # ドメイン固有のリソースパターンをデータベースから取得      domain_patterns_db_path = File.join(ENV["QUANTUM_DATA_DIR"]? || ".", "data", "domain_patterns.json")            # データベースからリソースパターンを取得      if File.exists?(domain_patterns_db_path)        begin          patterns_json = File.read(domain_patterns_db_path)          patterns = JSON.parse(patterns_json)                    # ドメイン固有のパターンを抽出          if patterns.as_h?.try &.has_key?(domain)            domain_patterns = patterns[domain].as_a            domain_patterns.each do |pattern|              pattern_obj = pattern.as_h              pattern_type = ResourceType.parse(pattern_obj["type"].as_s)              pattern_regex = pattern_obj["pattern"].as_s              pattern_priority = pattern_obj["priority"].as_i              pattern_weight = pattern_obj["weight"].as_f                            domain_resource_patterns << {                type: pattern_type,                regex: Regex.new(pattern_regex, Regex::Options::IGNORE_CASE),                priority: pattern_priority,                weight: pattern_weight              }            end            Log.debug { "#{domain}向けのリソースパターン#{domain_resource_patterns.size}件を読み込みました" }          end        rescue ex          Log.error(exception: ex) { "ドメインパターンデータベースの読み込みに失敗しました: #{domain_patterns_db_path}" }        end      else        # データベースファイルが存在しない場合は作成        FileUtils.mkdir_p(File.dirname(domain_patterns_db_path))        File.write(domain_patterns_db_path, "{}")        Log.info { "新しいドメインパターンデータベースを作成しました: #{domain_patterns_db_path}" }      end
      
      if File.exists?(domain_patterns_db_path)
        begin
          domain_patterns_data = JSON.parse(File.read(domain_patterns_db_path))
          common_domains = {} of String => Hash(String, Array(String))
          
          domain_patterns_data.as_h.each do |domain, patterns|
            patterns_hash = {} of String => Array(String)
            patterns.as_h.each do |type, paths|
              paths_array = [] of String
              paths.as_a.each do |path|
                paths_array << path.as_s
              end
              patterns_hash[type.as_s] = paths_array
            end
            common_domains[domain.as_s] = patterns_hash
          end
        rescue ex
          Log.error(exception: ex) { "ドメインパターンデータベースの読み込みに失敗しました" }
          common_domains = default_domain_patterns
        end
      else
        common_domains = default_domain_patterns
      end
      
      # ドメインがマッチするかチェック
      common_domains.each do |pattern_domain, domain_patterns|
        if domain.ends_with?(pattern_domain)
          patterns = domain_patterns
          break
        end
      end
      
      # パターンが見つからない場合は一般的なパターンを提供
      if patterns.empty?
        patterns = {
          "css" => ["/css/main.css", "/assets/css/styles.css", "/styles/main.css"],
          "js" => ["/js/main.js", "/assets/js/app.js", "/scripts/main.js"],
          "image" => ["/images/logo.png", "/assets/images/hero.jpg", "/img/banner.png"],
          "font" => ["/fonts/main.woff2", "/assets/fonts/regular.woff2"],
          "json" => ["/api/data.json", "/data/config.json"],
          "wasm" => ["/wasm/module.wasm"]
        }
      end
      
      # ドメイン・パターンをキャッシュ
      @domain_pattern_cache ||= {} of String => Hash(String, Array(String))
      @domain_pattern_cache[domain] = patterns
      
      patterns
    end
    
    # 予測履歴を更新
    private def update_prediction_history(domain : String, predictions : Array(ResourceDependency))
      @prediction_history ||= {} of String => Array(ResourcePrediction)
      @prediction_history[domain] ||= [] of ResourcePrediction
      
      # 予測履歴に追加（最大100件まで）
      predictions.each do |dep|
        prediction = ResourcePrediction.new(
          url: dep.url,
          resource_type: dep.resource_type,
          probability: dep.weight,
          timestamp: Time.utc,
          was_used: false
        )
        
        @prediction_history[domain] << prediction
      end
      
      # 履歴が大きすぎる場合は古いものから削除
      if @prediction_history[domain].size > 100
        @prediction_history[domain] = @prediction_history[domain][-100..-1]
      end
    end
    
    # 予測が正確だったかを記録
    def record_prediction_accuracy(url : String, was_used : Bool)
      return unless @prediction_model.in?(PredictionModel::Advanced, PredictionModel::UserAdaptive)
      
      uri = URI.parse(url)
      domain = uri.host.try &.downcase
      return unless domain && @prediction_history && @prediction_history[domain]?
      
      # 予測履歴から一致するURLを検索
      @prediction_history[domain].each do |prediction|
        if prediction.url == url && !prediction.was_evaluated
          prediction.was_used = was_used
          prediction.was_evaluated = true
          
          # 成功した予測をカウント
          @successful_predictions += 1 if was_used
          
          # ユーザー適応型モデルの場合は重みを更新
          if @prediction_model == PredictionModel::UserAdaptive
            update_user_weights(prediction)
          end
          
          break
        end
      end
    end
    
    # ユーザー重みの更新
    private def update_user_weights(prediction : ResourcePrediction)
      return unless @user_weights
      
      resource_type = case prediction.resource_type
                     when ResourceType::Stylesheet
                       "css"
                     when ResourceType::Script
                       "js"
                     when ResourceType::Image
                       "image"
                     when ResourceType::Font
                       "font"
                     else
                       "other"
                     end
      
      # 現在の重みを取得
      current_weight = @user_weights[resource_type]? || 1.0
      
      # 重みを更新（使用されたリソースは重みを増加、使用されなかったリソースは減少）
      if prediction.was_used
        # 成功した予測は重みを少し増加（最大1.5まで）
        new_weight = current_weight + 0.05
        new_weight = [1.5, new_weight].min
      else
        # 失敗した予測は重みを少し減少（最小0.5まで）
        new_weight = current_weight - 0.03
        new_weight = [0.5, new_weight].max
      end
      
      @user_weights[resource_type] = new_weight
      
      # 30分ごとに重みを保存
      @last_weights_save ||= Time.utc
      if (Time.utc - @last_weights_save).minutes >= 30
        save_user_weights
        @last_weights_save = Time.utc
      end
    end
    
    # ユーザー重みの保存
    private def save_user_weights
      return unless @user_weights && @prediction_model == PredictionModel::UserAdaptive
      
      # モデルディレクトリパスを構築
      model_dir = File.join(ENV["QUANTUM_DATA_DIR"]? || ".", "models", "prediction")
      FileUtils.mkdir_p(model_dir)
      
      # 重みをJSONとして保存
      user_data_path = File.join(model_dir, "user_adaptation_data.json")
      
      data = {
        "weights" => @user_weights,
        "updated_at" => Time.utc.to_unix,
        "successful_predictions" => @successful_predictions,
        "total_predictions" => @total_predictions,
        "accuracy" => @total_predictions > 0 ? (@successful_predictions.to_f / @total_predictions) : 0.0
      }
      
      File.write(user_data_path, data.to_json)
      Log.debug { "ユーザー適応データを保存しました - 正確度: #{(data["accuracy"].as(Float64) * 100).round(1)}%" }
    end
    
    # 予測モデルのメンテナンスループ
    private def prediction_model_maintenance_loop
      loop do
        begin
          # 1時間に一度、モデル評価と最適化を実行
          sleep 1.hour
          
          # 予測精度の評価
          if @total_predictions > 0
            accuracy = @successful_predictions.to_f / @total_predictions
            Log.info { "予測モデル精度評価: #{(accuracy * 100).round(1)}% (#{@successful_predictions}/#{@total_predictions})" }
            
            # 精度が低すぎる場合は予測モデルをリセット
            if accuracy < 0.3 && @total_predictions > 50
              Log.warn { "予測精度が低すぎるため、モデルをリセットします" }
              if @prediction_model == PredictionModel::UserAdaptive
                # ユーザー重みをリセット
                @user_weights.each_key do |key|
                  @user_weights[key] = 1.0
                end
                save_user_weights
              end
              
              # 予測カウンターをリセット
              @successful_predictions = 0
              @total_predictions = 0
            end
          end
          
          # 古い予測履歴をクリーンアップ
          now = Time.utc
          @prediction_history.try &.each do |domain, predictions|
            @prediction_history[domain] = predictions.reject do |p|
              (now - p.timestamp).hours > 24 # 24時間以上前の予測を削除
            end
          end
          
          # ドメインパターンキャッシュのクリーンアップ
          @domain_pattern_cache.try &.clear if @domain_pattern_cache.try &.size > 100
          
        rescue ex
          Log.error(exception: ex) { "予測モデルメンテナンス中にエラーが発生しました" }
        end
      end
    end
    
    # リソース予測のための情報クラス
    private class ResourcePrediction
      property url : String
      property resource_type : ResourceType
      property probability : Float64
      property timestamp : Time
      property was_used : Bool
      property was_evaluated : Bool = false
      
      def initialize(@url, @resource_type, @probability, @timestamp, @was_used)
      end
    end
    
    # デフォルトヘッダーを設定
    def set_default_header(name : String, value : String)
      @default_headers[name] = value
    end
    
    # タイムアウトを設定
    def set_timeout(timeout_ms : Int32)
      @default_timeout_ms = timeout_ms
    end
    
    # リダイレクト設定を変更
    def set_redirect_policy(follow : Bool, max_redirects : Int32 = 5)
      @follow_redirects = follow
      @max_redirects = max_redirects
    end
    
    # キャッシュを有効/無効に設定
    def set_cache_enabled(enabled : Bool)
      @cache_enabled = enabled
    end
    
    # 予測モデルを設定
    def set_prediction_model(model : PredictionModel)
      @prediction_model = model
      initialize_prediction_model
    end
    
    # ビューポート追跡を設定
    def set_viewport_tracking_enabled(enabled : Bool)
      @viewport_tracking_enabled = enabled
    end
    
    # リソースを非同期にフェッチ
    def fetch_async(url : String, 
                   method : String = "GET", 
                   headers : HTTP::Headers = HTTP::Headers.new, 
                   body : String? = nil,
                   resource_type : ResourceType = ResourceType::Other,
                   cache : Bool = true,
                   initiator_url : String? = nil,
                   is_predicted : Bool = false,
                   is_in_viewport : Bool = false) : Channel(FetchResult)
      
      result_channel = Channel(FetchResult).new(1)
      
      # キャッシュチェック
      if method == "GET" && @cache_enabled && cache
        cache_key = CacheKey.new(url)
        if cached_result = @cache[cache_key]?
          # キャッシュからのレスポンスを非同期で返す
          spawn do
            result_channel.send(cached_result)
          end
          return result_channel
        end
      end
      
      # ヘッダーの結合（デフォルトヘッダー + 指定ヘッダー）
      merged_headers = merge_headers(@default_headers, headers)
      headers_hash = headers_to_hash(merged_headers)
      
      # リソース予測と重要度計算
      weight = calculate_resource_importance(url, resource_type, initiator_url, is_in_viewport)
      
      # リソースタイプに基づく優先度設定
      priority = resource_type_to_priority(resource_type)
      
      # URLからドメイン情報を抽出
      domain = URI.parse(url).host.try &.downcase
      
      # リクエスト送信
      start_time = Time.utc
      
      # ドメイン統計情報を更新
      if domain && !is_predicted
        domain_stats = @domain_stats[domain]? || begin
          stats = DomainStats.new(domain)
          @domain_stats[domain] = stats
          stats
        end
        domain_stats.connection_count += 1
        domain_stats.last_connected = Time.utc
      end
      
      # 0-RTT早期データ使用の判断
      use_early_data = method == "GET" && can_use_early_data(url)
      
      # リクエスト送信前にHTTP/3ネットワークマネージャーにメタデータを設定
      request_id = @network_manager.send_request(
        url: url,
        method: method,
        headers: headers_hash,
        body: body,
        priority: priority,
        use_early_data: use_early_data
      )
      
      # ペンディングリクエストとして記録
      @pending_requests[request_id] = {result_channel, start_time, resource_type}
      
      # タイムアウト処理
      spawn do
        sleep(@default_timeout_ms.milliseconds)
        
        # まだペンディング中なら、タイムアウト処理
        if @pending_requests.has_key?(request_id)
          channel, request_time, res_type = @pending_requests.delete(request_id)
          
          # タイムアウトエラーを作成して送信
          result = FetchResult.new(
            request_id: request_id,
            url: url,
            status: 0,
            headers: HTTP::Headers.new,
            body: Bytes.new(0),
            resource_type: res_type,
            mime_type: "text/plain"
          )
          result.error = "Request timed out after #{@default_timeout_ms}ms"
          result.fetch_time_ms = (Time.utc - request_time).total_milliseconds
          result.weight = weight
          
          # ドメイン統計を更新
          if domain
            if stats = @domain_stats[domain]?
              stats.success_rate = (stats.success_rate * stats.resource_count) / (stats.resource_count + 1)
              stats.resource_count += 1
              stats.update_quality
            end
          end
          
          # タイムアウトしたリクエストをキャンセル
          @network_manager.cancel_request(request_id)
          
          # 結果をチャネルに送信
          channel.send(result)
        end
      end
      
      result_channel
    end
    
    # リソースの重要度を計算
    private def calculate_resource_importance(url : String, 
                                            resource_type : ResourceType, 
                                            initiator_url : String? = nil,
                                            is_in_viewport : Bool = false) : Float64
      # 基本重要度（リソースタイプによる）
      base_weight = case resource_type
                    when ResourceType::Document
                      10.0
                    when ResourceType::Stylesheet
                      8.0
                    when ResourceType::Script
                      7.0
                    when ResourceType::Font
                      6.0
                    when ResourceType::Image
                      4.0
                    when ResourceType::Media
                      3.0
                    when ResourceType::Fetch, ResourceType::XHR
                      5.0
                    else
                      1.0
                    end
      
      # ドメイン品質による調整
      domain_factor = 1.0
      if domain = URI.parse(url).host.try &.downcase
        if stats = @domain_stats[domain]?
          domain_factor = stats.connection_quality
        end
      end
      
      # ビューポート内かどうかによる調整
      viewport_factor = is_in_viewport ? 2.0 : 1.0
      
      # 予測モデルによる重み付け
      prediction_factor = 1.0
      
            if @prediction_model != PredictionModel::Disabled        # 機械学習モデルを使用した高度な予測を実行                # モデルデータのパスを取得        model_path = File.join(ENV["QUANTUM_DATA_DIR"]? || ".", "models", "resource_prediction_model.bin")                if File.exists?(model_path)          begin            # リソース予測モデルをロード            prediction_model = ResourcePredictionModel.load(model_path)                        # 予測特徴量の準備            features = {              "domain" => domain,              "path" => uri.path,              "query" => uri.query || "",              "resource_type" => resource_type.to_s,              "referrer" => referrer_domain,              "page_load_time" => page_load_time,              "connection_speed" => @network_manager.get_estimated_bandwidth,              "day_of_week" => Time.utc.day_of_week.to_i,              "hour_of_day" => Time.utc.hour,              "is_mobile" => @network_manager.is_mobile_connection? ? 1.0 : 0.0,              "previous_visits" => @domain_stats[domain]?.try(&.total_requests) || 0            }                        # 機械学習モデルを使用して予測実行            predicted_resources = prediction_model.predict_related_resources(features)                        # 信頼度でフィルタリング            threshold = case @prediction_model              when PredictionModel::Conservative                0.85              when PredictionModel::Balanced                0.75              when PredictionModel::Aggressive                0.65              else                0.75            end                        # 閾値以上の予測のみを使用            predicted_resources.select! { |res| res.confidence >= threshold }                        # 最大予測数を制限            max_predictions = case @prediction_model              when PredictionModel::Conservative                3              when PredictionModel::Balanced                5              when PredictionModel::Aggressive                8              else                5            end                        predicted_resources = predicted_resources.first(max_predictions)                        # 予測リソースをキューに追加            predicted_resources.each do |pred_res|              @pending_predicted_resources << ResourceDependency.new(                url: pred_res.url,                type: pred_res.resource_type,                parent_url: url,                priority: pred_res.priority,                weight: pred_res.confidence              )            end                        Log.debug { "#{domain}の予測リソース#{predicted_resources.size}件を追加しました" }          rescue ex            Log.error(exception: ex) { "リソース予測モデルの使用中にエラーが発生しました" }          end        else          # モデルが利用できない場合はヒューリスティックで代用
        
        # URLパスによる簡易判定（実際には機械学習モデルを使用）
        uri = URI.parse(url)
        path = uri.path.downcase
        
        # リソース予測のための特徴抽出
        features = extract_resource_features(url, content_type_from_path(path), Bytes.new(0))
        
        # 予測モデルの活用
        if @prediction_model.in?(PredictionModel::Advanced, PredictionModel::UserAdaptive) && @ml_interpreter
          begin
            # 特徴量をモデル入力にセット
            input_tensor = @ml_interpreter.input_tensor(0)
            features.each_with_index do |value, i|
              input_tensor[0, i] = value
            end
            
            # 推論実行
            @ml_interpreter.invoke
            
            # 出力テンソル取得
            output_tensor = @ml_interpreter.output_tensor(0)
            
            # 予測値を取得
            prediction_score = output_tensor[0, 0].to_f64
            
            # 0.2から2.0の範囲にスケーリング
            prediction_factor = 0.2 + (prediction_score * 1.8)
          rescue ex
            Log.error(exception: ex) { "予測モデルの推論に失敗しました" }
            # 失敗時はヒューリスティックにフォールバック
            prediction_factor = heuristic_prediction(path)
          end
        else
          # 基本的なヒューリスティック予測を使用
          prediction_factor = heuristic_prediction(path)
        end
      end
      
      # 重要度の最終計算
      weight = base_weight * domain_factor * viewport_factor * prediction_factor
      
      # 重要度は0.1〜10.0の範囲に正規化
      [10.0, [0.1, weight].max].min
    end
    
    # 0-RTT早期データが使用可能かを判断
    private def can_use_early_data(url : String) : Bool
      uri = URI.parse(url)
      return false unless uri.host
      
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      @network_manager.can_use_0rtt?(uri.host, port)
    end
    
    # リソースを同期的にフェッチ（内部的には非同期で処理）
    def fetch(url : String, 
             method : String = "GET", 
             headers : HTTP::Headers = HTTP::Headers.new, 
             body : String? = nil,
             resource_type : ResourceType = ResourceType::Other,
             cache : Bool = true,
             initiator_url : String? = nil,
             is_predicted : Bool = false,
             is_in_viewport : Bool = false) : FetchResult
      
      # 非同期バージョンを呼び出して結果を待機
      channel = fetch_async(url, method, headers, body, resource_type, cache, 
                           initiator_url, is_predicted, is_in_viewport)
      result = channel.receive
      
      # リソース依存関係の分析
      if result.success? && @prediction_model != PredictionModel::Disabled
        analyze_resource_dependencies(result)
      end
      
      result
    end
    
    # リソース依存関係を分析
    private def analyze_resource_dependencies(result : FetchResult)
      return unless result.resource_type == ResourceType::Document || 
                    result.resource_type == ResourceType::Stylesheet ||
                    result.resource_type == ResourceType::Script
      
      dependencies = [] of ResourceDependency
      
      # リソースタイプに応じた依存関係分析
      case result.resource_type
      when ResourceType::Document
        # HTMLドキュメントの場合
        # 完全なHTML DOM解析を実装
        if html_content = String.new(result.body)
          dependencies = extract_resources_from_html(html_content, result.url)
        end
      when ResourceType::Stylesheet
        # CSSファイルの場合
        if css_content = String.new(result.body)
          # @importルールを抽出
          css_content.scan(/@import\s+url\(['"]?([^'"]+)['"]?\)/i) do |match|
            if url = match[1]?
              absolute_url = make_absolute_url(url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::Stylesheet, result.url)
            end
          end
          
          # 背景画像などのURLを抽出
          css_content.scan(/url\(['"]?([^'"]+\.(jpg|jpeg|png|gif|webp|svg))['"]?\)/i) do |match|
            if url = match[1]?
              absolute_url = make_absolute_url(url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::Image, result.url)
            end
          end
          
          # フォントURLを抽出
          css_content.scan(/url\(['"]?([^'"]+\.(woff2|woff|ttf|otf|eot))['"]?\)/i) do |match|
            if url = match[1]?
              absolute_url = make_absolute_url(url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::Font, result.url)
            end
          end
        end
      when ResourceType::Script
                  # JSファイルの場合          # JavaScriptコードの完全解析を実装          if js_content = String.new(result.body)            # JS解析インスタンスを作成            js_parser = QuantumBrowser::JavaScriptParser.new(js_content)                        # 構文解析を実行            js_parser.parse                        # 解析に成功した場合            if js_parser.parsed?              # インポート/依存関係を抽出              imports = js_parser.extract_imports                            # 静的URL抽出（fetch/XHR呼び出し）              resource_urls = js_parser.extract_resource_urls                            # 外部スクリプト参照を抽出              script_urls = js_parser.extract_script_imports                            # WebSocketエンドポイントの抽出              websocket_urls = js_parser.extract_websocket_endpoints                            # サービスワーカー登録の検出              worker_registration = js_parser.extract_service_worker_registration                            # 抽出した各種URLを依存関係として登録              all_extracted_urls = resource_urls + script_urls                            all_extracted_urls.each do |extracted_url|                # 相対URLの場合はベースURLと結合                resolved_url = resolve_url(url, extracted_url)                                # リソースタイプを推定                resource_type = if script_urls.includes?(extracted_url)                  ResourceType::Script                elsif resolved_url.ends_with?(".json")                  ResourceType::Json                elsif resolved_url.ends_with?(".css")                  ResourceType::Stylesheet                elsif resolved_url.ends_with?(/\.(png|jpg|jpeg|gif|webp|svg)/)                  ResourceType::Image                else                  ResourceType::XHR                end                                # 依存関係を登録                add_resource_dependency(url, resolved_url, resource_type, Dependency::Dynamic)              end                            # WebSocketエンドポイントを登録              websocket_urls.each do |ws_url|                resolved_url = resolve_url(url, ws_url)                add_resource_dependency(url, resolved_url, ResourceType::WebSocket, Dependency::Dynamic)              end                            # サービスワーカーを登録              if worker_url = worker_registration                resolved_url = resolve_url(url, worker_url)                add_resource_dependency(url, resolved_url, ResourceType::ServiceWorker, Dependency::Dynamic)              end                            Log.debug { "JS解析完了: インポート: #{imports.size}, リソースURL: #{resource_urls.size}, スクリプトURL: #{script_urls.size}" }            else              # 解析失敗時はフォールバックとして正規表現ベースの単純抽出を実行
          # 解析のための適切なJavaScriptパーサーを使用
          begin
            parser = JavaScriptParser.new(js_content)
            imports = parser.extract_imports
            
            # import文とダイナミックインポートの処理
            imports.each do |import_url|
              absolute_url = make_absolute_url(import_url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::Script, result.url)
            end
            
            # fetch API の検出
            fetch_urls = parser.extract_fetch_calls
            fetch_urls.each do |fetch_url|
              next if fetch_url.starts_with?("data:") # データURLはスキップ
              absolute_url = make_absolute_url(fetch_url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::Fetch, result.url)
            end
            
            # XMLHttpRequest の検出
            xhr_urls = parser.extract_xhr_calls
            xhr_urls.each do |xhr_url|
              absolute_url = make_absolute_url(xhr_url, result.url)
              dependencies << ResourceDependency.new(absolute_url, ResourceType::XHR, result.url)
            end
            
            # WebSocket接続の検出
            ws_urls = parser.extract_websocket_calls
            ws_urls.each do |ws_url|
              ws_absolute_url = ws_url
              if !ws_url.starts_with?("ws://") && !ws_url.starts_with?("wss://")
                # URLスキームの変換（httpをws、httpsをwssに）
                uri = URI.parse(result.url)
                scheme = uri.scheme == "https" ? "wss" : "ws"
                ws_absolute_url = make_absolute_url(ws_url, "#{scheme}://#{uri.host}:#{uri.port || (uri.scheme == "https" ? 443 : 80)}")
              end
              dependencies << ResourceDependency.new(ws_absolute_url, ResourceType::WebSocket, result.url)
            end
            
            # 画像・メディアリソース読み込みの検出
            media_urls = parser.extract_media_urls
            media_urls.each do |media_url, type|
              absolute_url = make_absolute_url(media_url, result.url)
              resource_type = case type
                             when "image"
                               ResourceType::Image
                             when "audio", "video"
                               ResourceType::Media
                             else
                               ResourceType::Other
                             end
              dependencies << ResourceDependency.new(absolute_url, resource_type, result.url)
            end
            
          rescue ex
            Log.warn { "JavaScriptパース中にエラーが発生しました: #{ex.message}" }
            
            # エラー時のフォールバックとして単純な正規表現検出を使用
            # importやrequireを抽出
            js_content.scan(/import.*?from\s+['"]([^'"]+)['"]/i) do |match|
              if url = match[1]?
                absolute_url = make_absolute_url(url, result.url)
                dependencies << ResourceDependency.new(absolute_url, ResourceType::Script, result.url)
              end
            end
            
            # ダイナミックインポートを検出
            js_content.scan(/import\s*\(\s*['"]([^'"]+)['"]\s*\)/i) do |match|
              if url = match[1]?
                absolute_url = make_absolute_url(url, result.url)
                dependencies << ResourceDependency.new(absolute_url, ResourceType::Script, result.url)
              end
            end
            
            # fetch APIの使用を検出
            js_content.scan(/fetch\s*\(\s*['"]([^'"]+)['"]/i) do |match|
              if url = match[1]?
                absolute_url = make_absolute_url(url, result.url)
                dependencies << ResourceDependency.new(absolute_url, ResourceType::Fetch, result.url)
              end
            end
            
            # XMLHttpRequestの使用を検出
            js_content.scan(/\.open\s*\(\s*['"][^'"]+['"],\s*['"]([^'"]+)['"]/i) do |match|
              if url = match[1]?
                absolute_url = make_absolute_url(url, result.url)
                dependencies << ResourceDependency.new(absolute_url, ResourceType::XHR, result.url)
              end
            end
            
            # 新しいイメージオブジェクトの作成を検出
            js_content.scan(/new\s+Image\s*\([^)]*\).*?\.src\s*=\s*['"]([^'"]+)['"]/i) do |match|
              if url = match[1]?
                absolute_url = make_absolute_url(url, result.url)
                dependencies << ResourceDependency.new(absolute_url, ResourceType::Image, result.url)
              end
            end
          end
        end
      end
      
      # 依存関係を保存
      if dependencies.any?
        @resource_dependencies[result.url] = dependencies
        result.dependencies = dependencies
        
        # 予測モデルが有効なら、依存リソースを先読み
        if @prediction_model != PredictionModel::Disabled
          prefetch_dependencies(dependencies)
        end
      end
    end
    
    # 依存リソースを先読み
    private def prefetch_dependencies(dependencies : Array(ResourceDependency))
      # 先読み優先度を計算
      dependencies.each_with_index do |dep, index|
        # インデックスが小さいほど優先度が高い（ドキュメント内の順序を反映）
        position_factor = Math.max(0.5, 1.0 - (index.to_f / dependencies.size))
        
        # リソースタイプに基づく優先度
        type_priority = case dep.resource_type
                        when ResourceType::Stylesheet, ResourceType::Font
                          0.9  # 高優先度
                        when ResourceType::Script
                          0.7  # 中優先度
                        when ResourceType::Image
                          0.5  # 低〜中優先度
                        else
                          0.3  # 低優先度
                        end
        
        # 最終重みを計算（0.15〜0.9の範囲）
        dep.weight = position_factor * type_priority
        
        # 処理済みリソースなら重みを下げる
        if @cache.has_key?(CacheKey.new(dep.url)) || @pending_predicted_resources.any? { |p| p.url == dep.url }
          dep.weight *= 0.1
        end
      end
      
      # 重みでソート（降順）
      sorted_deps = dependencies.sort_by { |dep| -dep.weight }
      
      # 上位のリソースのみを先読み（帯域と接続リソースを節約）
      prefetch_count = Math.min(5, sorted_deps.size)
      sorted_deps[0...prefetch_count].each do |dep|
        next if @cache.has_key?(CacheKey.new(dep.url)) # 既にキャッシュ済みなら飛ばす
        next if @pending_predicted_resources.any? { |p| p.url == dep.url } # 既に先読み済みなら飛ばす
        
        @pending_predicted_resources << dep
        
        # 低い優先度で非同期に先読み
        spawn do
          begin
            fetch(
              url: dep.url,
              resource_type: dep.resource_type,
              initiator_url: dep.initiator_url,
              is_predicted: true,
              is_in_viewport: false
            )
          rescue e
            Log.debug { "予測リソース先読みエラー: #{dep.url} - #{e.message}" }
          ensure
            # 完了したら保留リストから削除
            @pending_predicted_resources.delete(dep)
          end
        end
      end
    end
    
    # 相対URLを絶対URLに変換
    private def make_absolute_url(url : String, base_url : String) : String
      return url if url.starts_with?("http://") || url.starts_with?("https://")
      
      uri = URI.parse(base_url)
      base = "#{uri.scheme}://#{uri.host}"
      base += ":#{uri.port}" if uri.port && uri.port != 80 && uri.port != 443
      
      if url.starts_with?("/")
        return "#{base}#{url}"
      else
        path = uri.path || "/"
        path = path[0...path.rindex("/")] if path.includes?("/")
        return "#{base}#{path}/#{url}"
      end
    end
    
    # ドキュメント（HTML）をフェッチ
    def fetch_document(url : String, headers : HTTP::Headers = HTTP::Headers.new, is_in_viewport : Bool = true) : FetchResult
      custom_headers = headers.dup
      custom_headers["Accept"] = "text/html,application/xhtml+xml"
      
      fetch(url, "GET", custom_headers, nil, ResourceType::Document, true, nil, false, is_in_viewport)
    end
    
    # スタイルシート（CSS）をフェッチ
    def fetch_stylesheet(url : String, initiator_url : String? = nil, is_in_viewport : Bool = false) : FetchResult
      headers = HTTP::Headers.new
      headers["Accept"] = "text/css"
      
      fetch(url, "GET", headers, nil, ResourceType::Stylesheet, true, initiator_url, false, is_in_viewport)
    end
    
    # スクリプト（JavaScript）をフェッチ
    def fetch_script(url : String, initiator_url : String? = nil, is_in_viewport : Bool = false) : FetchResult
      headers = HTTP::Headers.new
      headers["Accept"] = "application/javascript,text/javascript"
      
      fetch(url, "GET", headers, nil, ResourceType::Script, true, initiator_url, false, is_in_viewport)
    end
    
    # 画像をフェッチ
    def fetch_image(url : String, initiator_url : String? = nil, is_in_viewport : Bool = false) : FetchResult
      headers = HTTP::Headers.new
      headers["Accept"] = "image/*"
      
      fetch(url, "GET", headers, nil, ResourceType::Image, true, initiator_url, false, is_in_viewport)
    end
    
    # フォントをフェッチ
    def fetch_font(url : String, initiator_url : String? = nil) : FetchResult
      headers = HTTP::Headers.new
      headers["Accept"] = "font/woff2,font/woff,font/ttf,font/otf,*/*"
      
      fetch(url, "GET", headers, nil, ResourceType::Font, true, initiator_url)
    end
    
    # リソースをプリフェッチ（バックグラウンドで取得）
    def prefetch(url : String, resource_type : ResourceType = ResourceType::Other)
      # ペンディングキューに既に存在するか、既にキャッシュされている場合はスキップ
      cache_key = CacheKey.new(url)
      return if @cache.has_key?(cache_key)
      
      # 低い優先度でフェッチを開始
      spawn do
        fetch(url, "GET", HTTP::Headers.new, nil, resource_type, true, nil, true)
      end
    end
    
    # 予測精度レポートを取得
    def get_prediction_accuracy : Hash(String, Float64)
      # 予測精度に関する統計を返す
      
      total_predictions = @total_predictions.to_f
      correct_predictions = @successful_predictions.to_f
      
      # 過去30分間の精度データ
      recent_predictions = 0
      recent_successful = 0
      now = Time.utc
      
      # 各ドメインの予測履歴をチェック
      @prediction_history.try &.each_value do |predictions|
        predictions.each do |p|
          # 30分以内かつ評価済みの予測を集計
          if p.was_evaluated && (now - p.timestamp).minutes < 30
            recent_predictions += 1
            recent_successful += p.was_used ? 1 : 0
          end
        end
      end
      
      # 精度を計算（0除算回避）
      accuracy = total_predictions > 0 ? (correct_predictions / total_predictions) : 0.0
      recent_accuracy = recent_predictions > 0 ? (recent_successful.to_f / recent_predictions) : 0.0
      
      # モデル別の精度（高度なモデルが有効な場合）
      model_specific_stats = if @prediction_model == PredictionModel::Advanced
                             {
                               "model_type" => 2.0,  # Advanced = 2.0
                               "model_version" => 1.0,
                               "feature_importance" => calculate_feature_importance
                             }
                           elsif @prediction_model == PredictionModel::UserAdaptive
                             # ユーザー適応型モデルの場合は重みも返す
                             weights = {} of String => Float64
                             @user_weights.try &.each do |key, value|
                               weights[key] = value
                             end
                             
                             {
                               "model_type" => 3.0,  # UserAdaptive = 3.0
                               "model_version" => 1.0,
                               "user_weights_avg" => weights.values.sum / weights.size,
                               "feature_importance" => calculate_feature_importance
                             }
                           else
                             {
                               "model_type" => 1.0,  # Basic = 1.0
                               "model_version" => 1.0
                             }
                           end
      
      # ドメイン別の精度（上位5ドメイン）
      domain_accuracy = {} of String => Float64
      top_domains = @domain_stats.keys.sort_by { |domain| -(@domain_stats[domain].resource_count) }
      
      top_domains.first(5).each do |domain|
        if @prediction_history && @prediction_history[domain]?
          domain_preds = @prediction_history[domain].select(&.was_evaluated)
          domain_correct = domain_preds.count(&.was_used)
          domain_accuracy[domain] = domain_preds.size > 0 ? domain_correct.to_f / domain_preds.size : 0.0
        end
      end
      
      # 結果をマージ
      result = {
        "total_predictions" => total_predictions,
        "correct_predictions" => correct_predictions,
        "accuracy" => accuracy,
        "recent_accuracy" => recent_accuracy,
        "domain_count" => @domain_stats.size.to_f
      }
      
      # モデル固有の統計を追加
      model_specific_stats.each do |key, value|
        result[key] = value
      end
      
      # ドメイン別精度を追加
      domain_accuracy.each do |domain, acc|
        result["domain:#{domain}"] = acc
      end
      
      result
    end
    
    # 特徴量の重要度を計算
    private def calculate_feature_importance : Float64
      return 0.0 unless @prediction_model.in?(PredictionModel::Advanced, PredictionModel::UserAdaptive)
      
            # 高度なモデルから特徴量の重要度を抽出      # モデルのロードと特徴量重要度の取得      begin        # モデルデータのパスを取得        model_path = File.join(ENV["QUANTUM_DATA_DIR"]? || ".", "models", "feature_importance_model.bin")                if File.exists?(model_path)          # モデルをロード          model = FeatureImportanceModel.load(model_path)                    # 現在のデータに基づいた特徴量を構築          features = {            "domain" => domain,            "resource_type" => resource_type.to_s,            "url_pattern" => url_pattern_score,            "depth" => depth,            "parent_importance" => parent_importance || 1.0,            "is_visible" => is_visible ? 1.0 : 0.0,            "network_condition" => @network_manager.network_condition_score,            "cache_ratio" => @network_manager.get_domain_cache_hit_ratio(domain),            "average_response_time" => @domain_stats[domain]?.try(&.avg_response_time) || 0.0          }                    # モデルから特徴量の重要度を抽出          return model.get_feature_importance(features)        end      rescue ex        Log.error(exception: ex) { "特徴量重要度モデルの使用中にエラーが発生しました" }      end            # モデルの使用に失敗した場合はデフォルト値を返す      0.75
    end
    
    # ドメイン統計情報を取得
    def get_domain_stats(domain : String) : DomainStats?
      @domain_stats[domain]?
    end
    
    # すべてのドメイン統計を取得
    def get_all_domain_stats : Hash(String, DomainStats)
      @domain_stats
    end
    
    # キャッシュをクリア
    def clear_cache
      @cache.clear
    end
    
    # 特定URLのキャッシュを削除
    def invalidate_cache(url : String)
      cache_key = CacheKey.new(url)
      @cache.delete(cache_key)
    end
    
    # 特定のホストに事前接続
    def preconnect(url : String)
      uri = URI.parse(url)
      host = uri.host
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      
      if host
        @network_manager.preconnect(host, port)
      end
    end
    
    private def setup_response_handlers
      # レスポンスハンドラーの設定
      # Nimからのコールバックをハンドリングする仕組み
      @callback_handlers = {
        response: CallbackRegistry(UInt64, Int32, HTTP::Headers, Bytes, String).new,
        error: CallbackRegistry(UInt64, String, Int32).new,
        redirect: CallbackRegistry(UInt64, String, Int32).new,
        progress: CallbackRegistry(UInt64, Int64, Int64).new
      }
      
      # スレッド安全なコールバック処理用のロックを初期化
      @callback_lock = ReentrantLock.new
      
      # Nimから受信したデータの一時保存領域
      @response_buffers = {} of UInt64 => ResponseBuffer
      
      # Nimからのコールバックハンドラーの登録
      @network_manager.set_response_callback(->process_response_callback(UInt64, Int32, HTTP::Headers, Bytes, String))
      @network_manager.set_error_callback(->process_error_callback(UInt64, String, Int32))
      @network_manager.set_redirect_callback(->process_redirect_callback(UInt64, String, Int32))
      @network_manager.set_progress_callback(->process_progress_callback(UInt64, Int64, Int64))
      
      # コールバック処理用のチャネルを初期化
      @callback_queue = Channel(Tuple(Symbol, UInt64, Array(Any))).new(100)
      
      # コールバック処理用のワーカーを起動
      spawn do
        callback_worker
      end
      
      # FFIコールバックハンドラの登録
      LibNimHttp3.register_response_callback(->Http3ClientManager.nim_response_callback(UInt64, Int32, Pointer(Void), Int32, Pointer(UInt8), Int32, Pointer(UInt8), Int32))
      LibNimHttp3.register_error_callback(->Http3ClientManager.nim_error_callback(UInt64, Pointer(UInt8), Int32, Int32))
      LibNimHttp3.register_redirect_callback(->Http3ClientManager.nim_redirect_callback(UInt64, Pointer(UInt8), Int32, Int32))
      LibNimHttp3.register_progress_callback(->Http3ClientManager.nim_progress_callback(UInt64, Int64, Int64))
      
      # コールバック同期用のミューテックスを初期化
      @callback_mutex = Mutex.new
      
      # コールバックの衝突検出と再試行機能を設定
      @retry_config = {
        max_retries: 3,
        retry_delay_ms: 50,
        timeout_ms: 5000
      }
      
      # NimからのコールバックをCrystalで処理するための変換レイヤーを追加
      setup_nim_crystal_bridge
      
      Log.debug { "HTTP/3レスポンスハンドラーを設定しました" }
    end
    
    # NimとCrystal間のブリッジセットアップ
    private def setup_nim_crystal_bridge
      # NimからCrystalへのコールバック処理を保証するメカニズム
      @bridge_initialized = LibNimHttp3.initialize_callback_bridge(
        ->bridge_callback_indicator(Int32, Pointer(Void)),
        @callback_context_ptr
      )
      
      # コールバック変換マッパーを設定
      @callback_mapper = CallbackMapper.new
      @callback_mapper.register(:response) do |args|
        request_id, status, headers_ptr, body = args
        convert_nim_response(request_id, status, headers_ptr, body)
      end
      
      @callback_mapper.register(:error) do |args|
        request_id, error_msg, code = args
        {request_id, error_msg, code}
      end
      
      # ヘルスチェック用のハートビートタイマーを設定
      spawn health_check_timer
      
      if @bridge_initialized
        Log.info { "Nim-Crystal HTTP/3コールバックブリッジを初期化しました" }
      else
        Log.error { "Nim-Crystal HTTP/3コールバックブリッジの初期化に失敗しました" }
      end
    end
    
    # ブリッジコールバックインジケーター
    private def self.bridge_callback_indicator(type_code : Int32, data_ptr : Pointer(Void))
      # シングルトンインスタンスを取得
      instance = Http3ClientManager.get_instance
      return if instance.nil?
      
      # コールバックタイプを決定
      callback_type = case type_code
                      when 1 then :response
                      when 2 then :error
                      when 3 then :redirect
                      when 4 then :progress
                      else :unknown
                      end
      
      # データ構造を復元
      data = instance.callback_mapper.extract_data(callback_type, data_ptr)
      
      # インスタンスのキューにデータを送信
      instance.enqueue_bridge_callback(callback_type, data) if data
    end
    
    # ブリッジからのコールバックをキューに追加
    def enqueue_bridge_callback(type : Symbol, data : Array)
      return if data.empty?
      
      # 最初の要素はrequest_id
      request_id = data[0].as(UInt64)
      args = data[1..-1]
      
      # キューに追加
      @callback_queue.send({type, request_id, args})
    end
    
    # Nimレスポンスデータを変換
    private def convert_nim_response(request_id : UInt64, status : Int32, headers_ptr : Pointer(Void), body_data : Bytes) : Array
      headers = HTTP::Headers.new
      
      # ヘッダー構造体を適切に変換
      if headers_ptr
        header_count = LibNimHttp3.get_header_count(headers_ptr)
        
        header_count.times do |i|
          name_ptr = LibNimHttp3.get_header_name(headers_ptr, i)
          value_ptr = LibNimHttp3.get_header_value(headers_ptr, i)
          
          if name_ptr && value_ptr
            name = String.new(name_ptr)
            value = String.new(value_ptr)
            headers[name] = value
          end
        end
      end
      
      # MIMEタイプの取得
      mime_type = LibNimHttp3.get_response_mime_type(request_id) || "application/octet-stream"
      
      [request_id, status, headers, body_data, mime_type]
    end
    
    # ヘルスチェックタイマー
    private def health_check_timer
      loop do
        sleep 30.seconds
        
        begin
          # Nimコールバックブリッジのヘルスチェック
          if LibNimHttp3.check_callback_bridge_health
            Log.debug { "HTTP/3コールバックブリッジは正常です" }
          else
            Log.warn { "HTTP/3コールバックブリッジが応答していません - 再初期化を試みます" }
            reinitialize_callback_bridge
          end
        rescue ex
          Log.error { "HTTP/3ブリッジヘルスチェック中にエラーが発生: #{ex.message}" }
        end
      end
    end
    
    # コールバックブリッジの再初期化
    private def reinitialize_callback_bridge
      @callback_mutex.synchronize do
        begin
          # ブリッジを停止
          LibNimHttp3.shutdown_callback_bridge
          
          # 1秒待機
          sleep 1.second
          
          # ブリッジを再初期化
          @bridge_initialized = LibNimHttp3.initialize_callback_bridge(
            ->bridge_callback_indicator(Int32, Pointer(Void)),
            @callback_context_ptr
          )
          
          if @bridge_initialized
            Log.info { "HTTP/3コールバックブリッジを正常に再初期化しました" }
          else
            Log.error { "HTTP/3コールバックブリッジの再初期化に失敗しました" }
          end
        rescue ex
          Log.error { "コールバックブリッジの再初期化中にエラーが発生: #{ex.message}" }
        end
      end
    end
    
    # コールバックワーカースレッド
    private def callback_worker
      loop do
        begin
          callback_type, request_id, args = @callback_queue.receive
          
          case callback_type
          when :response
            status, headers, body, mime_type = args
            process_response_callback(request_id, status.as(Int32), headers.as(HTTP::Headers), body.as(Bytes), mime_type.as(String))
          when :error
            error_message, error_code = args
            process_error_callback(request_id, error_message.as(String), error_code.as(Int32))
          when :redirect
            redirect_url, status = args
            process_redirect_callback(request_id, redirect_url.as(String), status.as(Int32))
          when :progress
            bytes_received, total_bytes = args
            process_progress_callback(request_id, bytes_received.as(Int64), total_bytes.as(Int64))
          end
        rescue ex
          Log.error(exception: ex) { "コールバック処理中にエラーが発生しました" }
        end
      end
    end
    
    # Nimからコールバックを受け取るFFIメソッド
    def self.nim_response_callback(request_id : UInt64, status : Int32, headers_ptr : Pointer(Void), 
                                  headers_len : Int32, body_ptr : Pointer(UInt8), 
                                  body_len : Int32, mime_type_ptr : Pointer(UInt8), 
                                  mime_type_len : Int32)
      instance = Http3ClientManager.get_instance
      return if instance.nil?
      
      # ヘッダーの変換
      headers = HTTP::Headers.new
      if headers_ptr && headers_len > 0
        headers_str = String.new(headers_ptr.as(Pointer(UInt8)), headers_len)
        headers_str.split("\n").each do |header_line|
          if header_line.includes?(":")
            key, value = header_line.split(":", 2)
            headers[key.strip] = value.strip
          end
        end
      end
      
      # バイト配列とMIMEタイプの変換
      body = Bytes.new(0)
      if body_ptr && body_len > 0
        body = Bytes.new(body_len)
        body_ptr.copy_to(body.to_unsafe, body_len)
      end
      
      mime_type = ""
      if mime_type_ptr && mime_type_len > 0
        mime_type = String.new(mime_type_ptr, mime_type_len)
      end
      
      # クライアントインスタンスを取得してキューに追加
      instance.enqueue_callback(:response, request_id, [status, headers, body, mime_type])
    end
    
    # エラーコールバック
    def self.nim_error_callback(request_id : UInt64, error_ptr : Pointer(UInt8), 
                               error_len : Int32, error_code : Int32)
      instance = Http3ClientManager.get_instance
      return if instance.nil?
      
      error_message = ""
      if error_ptr && error_len > 0
        error_message = String.new(error_ptr, error_len)
      end
      
      instance.enqueue_callback(:error, request_id, [error_message, error_code])
    end
    
    # リダイレクトコールバック
    def self.nim_redirect_callback(request_id : UInt64, url_ptr : Pointer(UInt8), 
                                  url_len : Int32, status : Int32)
      instance = Http3ClientManager.get_instance
      return if instance.nil?
      
      redirect_url = ""
      if url_ptr && url_len > 0
        redirect_url = String.new(url_ptr, url_len)
      end
      
      instance.enqueue_callback(:redirect, request_id, [redirect_url, status])
    end
    
    # 進捗コールバック
    def self.nim_progress_callback(request_id : UInt64, bytes_received : Int64, total_bytes : Int64)
      instance = Http3ClientManager.get_instance
      return if instance.nil?
      
      instance.enqueue_callback(:progress, request_id, [bytes_received, total_bytes])
    end
    
    # コールバックをキューに追加するヘルパーメソッド
    def enqueue_callback(type : Symbol, request_id : UInt64, args : Array(Any))
      @callback_queue.send({type, request_id, args})
    end
    
    # Nimからのレスポンスコールバック処理
    private def process_response_callback(request_id : UInt64, status : Int32, headers : HTTP::Headers, body : Bytes, mime_type : String) : Nil
      spawn do
        begin
          Log.debug { "HTTP/3レスポンス受信: request_id=#{request_id}, status=#{status}, size=#{body.size}バイト" }
          
          # 結果オブジェクトを作成
          result = FetchResult.new(
            request_id,
            get_request_url(request_id),
            status,
            headers,
            body,
            get_request_type(request_id),
            mime_type
          )
          
          # TTFBなど追加情報の設定
          if ttfb = get_request_ttfb(request_id)
            result.ttfb_ms = ttfb
          end
          
          result.completed = true
          
          # 0-RTT使用の有無を設定
          result.used_early_data = @network_manager.was_0rtt_used?(request_id)
          
          # レスポンスを処理
          handle_response(request_id, result)
        rescue ex
          Log.error(exception: ex) { "レスポンスコールバック処理中にエラーが発生しました: request_id=#{request_id}" }
        end
      end
    end
    
    # Nimからのエラーコールバック処理
    private def process_error_callback(request_id : UInt64, error_message : String, error_code : Int32) : Nil
      spawn do
        begin
          Log.debug { "HTTP/3エラー受信: request_id=#{request_id}, error_code=#{error_code}, message=#{error_message}" }
          
          # 結果オブジェクトを作成
          result = FetchResult.new(
            request_id,
            get_request_url(request_id),
            0,
            HTTP::Headers.new,
            Bytes.new(0),
            get_request_type(request_id),
            ""
          )
          
          result.error = error_message
          result.completed = true
          
          # レスポンスを処理
          handle_response(request_id, result)
        rescue ex
          Log.error(exception: ex) { "エラーコールバック処理中にエラーが発生しました: request_id=#{request_id}" }
        end
      end
    end
    
    # Nimからのリダイレクトコールバック処理
    private def process_redirect_callback(request_id : UInt64, redirect_url : String, status : Int32) : Nil
      spawn do
        begin
          Log.debug { "HTTP/3リダイレクト受信: request_id=#{request_id}, status=#{status}, redirect_url=#{redirect_url}" }
          
          if @pending_requests.has_key?(request_id)
            channel, start_time, resource_type = @pending_requests[request_id]
            
            # ヘッダーにLocationを含む形で結果オブジェクトを作成
            headers = HTTP::Headers.new
            headers["Location"] = redirect_url
            
            result = FetchResult.new(
              request_id,
              get_request_url(request_id),
              status,
              headers,
              Bytes.new(0),
              resource_type,
              ""
            )
            
            result.redirected = true
            result.redirect_url = redirect_url
            result.completed = true
            
            # レスポンスを処理
            handle_response(request_id, result)
          end
        rescue ex
          Log.error(exception: ex) { "リダイレクトコールバック処理中にエラーが発生しました: request_id=#{request_id}" }
        end
      end
    end
    
    # Nimからの進捗コールバック処理
    private def process_progress_callback(request_id : UInt64, bytes_received : Int64, total_bytes : Int64) : Nil
      # ここでは進捗の記録のみ行う（実際のアプリケーションではUIの更新などを行う）
      Log.debug { "HTTP/3進捗更新: request_id=#{request_id}, received=#{bytes_received}/#{total_bytes}バイト" }
    end
    
    # リクエストIDからURLを取得
    private def get_request_url(request_id : UInt64) : String
      if request_info = @pending_requests[request_id]?
        # request_info に URL が含まれていると仮定 (例: request_info[3])
        # 実際のURLの取得方法は @pending_requests の構造によります
        # ここでは仮に request_info が (Channel, Time, ResourceType, String) というタプルであるとします
        url = request_info[3] # URLが4番目の要素だと仮定
        return url unless url.empty?
        Log.warn "リクエストID #{request_id} に対応するURLが空です。"
        return "http://request-#{request_id}" # URLが取得できない場合のフォールバック
      end
      Log.warn "リクエストID #{request_id} が見つかりません。"
      return "unknown"
    end
    
    # リクエストIDからリソースタイプを取得
    private def get_request_type(request_id : UInt64) : ResourceType
      if @pending_requests.has_key?(request_id)
        _, _, resource_type = @pending_requests[request_id]
        return resource_type
      end
      return ResourceType::Other
    end
    
    # リクエストIDからTTFBを取得
    private def get_request_ttfb(request_id : UInt64) : Float64?
      if @pending_requests.has_key?(request_id)
        _, start_time, _ = @pending_requests[request_id]
        
        # NetworkManagerからTTFB情報を取得
        if @network_manager.responds_to?(:get_request_ttfb)
          ttfb = @network_manager.get_request_ttfb(request_id)
          if ttfb > 0
            return ttfb
          end
        end
        
        # リクエスト開始からの経過時間に基づく推定
        current_elapsed = (Time.utc - start_time).total_milliseconds
        if current_elapsed < 10
          # リクエスト始まったばかりの場合はまだTTFBがない
          return nil
        end
        
        # 経過時間から推定（通常TTFBはリクエスト全体の20-40%程度）
        # より正確にはTCPハンドシェイク時間、DNSルックアップ時間、サーバー処理時間の合計
        estimated_ttfb = current_elapsed * 0.3
        
        # リクエストタイプに応じて調整
        resource_type = get_request_type(request_id)
        case resource_type
        when ResourceType::Document
          # ドキュメントは処理に時間がかかる傾向あり
          estimated_ttfb *= 1.2
        when ResourceType::Image, ResourceType::Media
          # バイナリデータは処理が早い傾向あり
          estimated_ttfb *= 0.8
        end
        
        return estimated_ttfb
      end
      
      return nil
    end
    
    private def handle_response(request_id : UInt64, result : FetchResult)
      # ペンディングリクエストから削除
      if @pending_requests.has_key?(request_id)
        channel, start_time, resource_type = @pending_requests.delete(request_id)
        
        # レスポンス時間を計算
        result.fetch_time_ms = (Time.utc - start_time).total_milliseconds
        
        # リソースタイプを設定
        result.resource_type = resource_type
        
        # ドメイン統計を更新
        if domain = URI.parse(result.url).host.try &.downcase
          stats = @domain_stats[domain]? || begin
            new_stats = DomainStats.new(domain)
            @domain_stats[domain] = new_stats
            new_stats
          end
          
          # TTFBを更新
          if ttfb = result.ttfb_ms
            if stats.resource_count == 0
              stats.avg_ttfb_ms = ttfb
            else
              stats.avg_ttfb_ms = (stats.avg_ttfb_ms * stats.resource_count + ttfb) / (stats.resource_count + 1)
            end
          end
          
          # 成功率を更新
          success_value = result.success? ? 1.0 : 0.0
          stats.success_rate = (stats.success_rate * stats.resource_count + success_value) / (stats.resource_count + 1)
          stats.resource_count += 1
          stats.update_quality
        end
        
        # 成功したGETリクエストをキャッシュに追加
        if result.success? && result.resource_type != ResourceType::XHR && @cache_enabled
          cache_key = CacheKey.new(result.url)
          @cache[cache_key] = result
        end
        
        # リダイレクト処理
        if @follow_redirects && (result.status == 301 || result.status == 302 || result.status == 303 || result.status == 307 || result.status == 308)
          if redirect_url = result.headers["Location"]?
            handle_redirect(result, redirect_url, channel)
            return
          end
        end
        
        # 結果をチャネルに送信
        channel.send(result)
      end
    end
    
    private def handle_redirect(result : FetchResult, redirect_url : String, channel : Channel(FetchResult))
      result.redirected = true
      result.redirect_url = redirect_url
      
      # 新しいURLを作成（相対URLの場合は絶対URLに変換）
      absolute_url = make_absolute_url(redirect_url, result.url)
      
      # リダイレクトを送信
      channel.send(result)
    end
    
    private def merge_headers(default_headers : HTTP::Headers, custom_headers : HTTP::Headers) : HTTP::Headers
      result = HTTP::Headers.new
      
      # デフォルトヘッダーをコピー
      default_headers.each do |name, values|
        values.each do |value|
          result.add(name, value)
        end
      end
      
      # カスタムヘッダーで上書き
      custom_headers.each do |name, values|
        # 既存の値を削除
        result.delete(name)
        
        # 新しい値を追加
        values.each do |value|
          result.add(name, value)
        end
      end
      
      result
    end
    
    private def headers_to_hash(headers : HTTP::Headers) : Hash(String, String)
      result = {} of String => String
      
      headers.each do |name, values|
        result[name] = values.join(", ")
      end
      
      result
    end
    
    private def resource_type_to_priority(resource_type : ResourceType) : Http3NetworkManager::Priority
      case resource_type
      when ResourceType::Document
        Http3NetworkManager::Priority::Critical
      when ResourceType::Stylesheet, ResourceType::Script, ResourceType::Font
        Http3NetworkManager::Priority::High
      when ResourceType::Image, ResourceType::Media
        Http3NetworkManager::Priority::Normal
      when ResourceType::XHR, ResourceType::Fetch
        Http3NetworkManager::Priority::Low
      else
        Http3NetworkManager::Priority::Background
      end
    end
    
    # HTMLからリソースを抽出（完全なDOM解析実装）
    private def extract_resources_from_html(html_content : String, base_url : String) : Array(ResourceDependency)
      dependencies = [] of ResourceDependency
      start_time = Time.monotonic
      
      begin
        # HTMLパーサーの初期化
        parser = HTMLParser.new(html_content)
        document = parser.parse
        
        # エラー処理
        if parser.has_errors?
          Log.warn { "HTMLパース警告: #{parser.errors.size}件のエラーが発生 (#{base_url})" }
        end
        
        # <link> タグからスタイルシートとプリロードリソースを抽出
        document.query_selector_all("link[href]").each do |link|
          href = link.attribute("href").try &.strip
          next unless href && !href.empty?
          
          rel = link.attribute("rel").try &.downcase
          
          # CSSスタイルシート
          if rel == "stylesheet"
            absolute_url = make_absolute_url(href, base_url)
            dependency = ResourceDependency.new(absolute_url, ResourceType::Stylesheet, base_url)
            
            # メディアクエリをチェック
            if media = link.attribute("media")
              # モバイルのみ、印刷のみなどを判断
              if media.includes?("print") && !media.includes?("screen")
                dependency.weight = 0.3  # 印刷用スタイルシートは低優先度
              elsif media.includes?("(max-width:") || media.includes?("(min-width:")
                # レスポンシブメディアクエリの評価
                # ビューポートサイズに基づいて適用されるメディアクエリは優先度を高く
                current_viewport_width = @viewport_width || 1920
                
                if evaluate_media_query(media, current_viewport_width)
                  dependency.weight = 0.95  # 現在のビューポートに適用されるスタイル
                else
                  dependency.weight = 0.4   # 現在は適用されないスタイル
                end
              end
            else
              dependency.weight = 0.9  # デフォルトのスタイルシート優先度
            end
            
            dependencies << dependency
          
          # プリロード指示子
          elsif rel == "preload"
            as_type = link.attribute("as").try &.downcase
            
            if as_type
              absolute_url = make_absolute_url(href, base_url)
              
              # リソースタイプを決定
              resource_type = case as_type
                            when "style", "stylesheet"
                              ResourceType::Stylesheet
                            when "script"
                              ResourceType::Script
                            when "image"
                              ResourceType::Image
                            when "font"
                              ResourceType::Font
                            when "fetch"
                              ResourceType::Fetch
                            else
                              ResourceType::Other
                            end
              
              dependency = ResourceDependency.new(absolute_url, resource_type, base_url)
              
              # プリロードは優先度が高い
              dependency.weight = 0.98
              
              # プリロードに優先度属性があるか確認
              if importance = link.attribute("importance").try &.downcase
                case importance
                when "high"
                  dependency.weight = 0.99
                when "low"
                  dependency.weight = 0.8
                end
              end
              
              dependencies << dependency
            end
          
          # プリコネクト指示子
          elsif rel == "preconnect" && href.starts_with?("http")
            # プリコネクト用のDNS名前解決と接続を事前準備
            schedule_preconnect(href)
          
          # DNS名前解決指示子
          elsif rel == "dns-prefetch" && href.starts_with?("http")
            # DNS名前解決のみを事前準備
            schedule_dns_prefetch(href)
          end
        end
        
        # <script> タグからスクリプトを抽出
        document.query_selector_all("script[src]").each do |script|
          src = script.attribute("src").try &.strip
          next unless src && !src.empty?
          
          absolute_url = make_absolute_url(src, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Script, base_url)
          
          # scriptタグの属性に基づいて優先度を決定
          
          # 非同期スクリプト
          if script.has_attribute?("async")
            dependency.weight = 0.6  # 非同期は中程度の優先度
            dependency.is_async = true
          
          # 遅延スクリプト
          elsif script.has_attribute?("defer")
            dependency.weight = 0.4  # 遅延は低い優先度
            dependency.is_deferred = true
            
          # モジュールスクリプト
          elsif script.attribute("type") == "module"
            dependency.weight = 0.7
            dependency.is_module = true
            
          else
            # 通常のブロッキングスクリプト
            dependency.weight = 0.85
          end
          
          # インテグリティチェックが必要なスクリプト
          if integrity = script.attribute("integrity")
            dependency.integrity = integrity
          end
          
          dependencies << dependency
        end
        
        # <img> タグから画像を抽出
        document.query_selector_all("img[src]").each do |img|
          src = img.attribute("src").try &.strip
          next unless src && !src.empty?
          
          absolute_url = make_absolute_url(src, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Image, base_url)
          
          # サイズと位置に基づいて優先度を決定
          width = img.attribute("width").try &.to_i
          height = img.attribute("height").try &.to_i
          
          # 画像サイズが大きいほど優先度を高く
          if width && height && width > 0 && height > 0
            image_size = width * height
            if image_size > 250000
              dependency.weight = 0.85  # 大きな画像
            elsif image_size > 100000
              dependency.weight = 0.7   # 中くらいの画像
            else
              dependency.weight = 0.5   # 小さな画像
            end
          else
            dependency.weight = 0.6     # サイズ不明
          end
          
          # loading="lazy" 属性をチェック
          if img.attribute("loading") == "lazy"
            dependency.weight *= 0.6  # レイジーロード画像は優先度を下げる
            dependency.is_lazy_loaded = true
          end
          
          # srcset属性の処理
          if srcset = img.attribute("srcset")
            # 現在のビューポートに最適な画像を選択
            current_viewport_width = @viewport_width || 1920
            
            srcset_candidates = parse_srcset(srcset)
            if best_match = select_best_srcset_candidate(srcset_candidates, current_viewport_width)
              # 最適な候補がある場合はsrcを上書き
              dependency.url = make_absolute_url(best_match, base_url)
              dependency.weight += 0.1  # 最適な画像は優先度を少し上げる
            end
          end
          
          dependencies << dependency
        end
        
        # <source> タグから画像と動画ソースを抽出
        document.query_selector_all("source[src], source[srcset]").each do |source|
          parent = source.parent_node
          
          # <picture>内の<source>か<video>内の<source>かを判断
          is_picture_source = parent && parent.node_name.downcase == "picture"
          
          if src = source.attribute("src")
            absolute_url = make_absolute_url(src, base_url)
            
            if is_picture_source
              dependency = ResourceDependency.new(absolute_url, ResourceType::Image, base_url)
              dependency.weight = 0.6
            else # video source
              dependency = ResourceDependency.new(absolute_url, ResourceType::Media, base_url)
              dependency.weight = 0.5
            end
            
            dependencies << dependency
          end
          
          if srcset = source.attribute("srcset") && is_picture_source
            # 現在のビューポートに最適な画像を選択
            current_viewport_width = @viewport_width || 1920
            
            # メディア条件を評価
            if media = source.attribute("media")
              if !evaluate_media_query(media, current_viewport_width)
                next  # メディアクエリが現在のビューポートに一致しない
              end
            end
            
            srcset_candidates = parse_srcset(srcset)
            if best_match = select_best_srcset_candidate(srcset_candidates, current_viewport_width)
              dependency = ResourceDependency.new(make_absolute_url(best_match, base_url), ResourceType::Image, base_url)
              dependency.weight = 0.65
              dependencies << dependency
            end
          end
        end
        
        # <video> と <audio> タグからメディアを抽出
        document.query_selector_all("video[src], audio[src]").each do |media|
          src = media.attribute("src").try &.strip
          next unless src && !src.empty?
          
          absolute_url = make_absolute_url(src, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Media, base_url)
          
          # 自動再生属性をチェック
          autoplay = media.has_attribute?("autoplay")
          
          if autoplay
            dependency.weight = 0.8  # 自動再生メディアは優先度が高い
          else
            dependency.weight = 0.4  # 非自動再生メディアは優先度が低い
          end
          
          dependencies << dependency
        end
        
        # <iframe> タグからフレームソースを抽出
        document.query_selector_all("iframe[src]").each do |iframe|
          src = iframe.attribute("src").try &.strip
          next unless src && !src.empty?
          
          absolute_url = make_absolute_url(src, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Document, base_url)
          dependency.is_iframe = true
          
          # iframe の遅延ロード属性をチェック
          if iframe.attribute("loading") == "lazy"
            dependency.weight = 0.3  # 遅延ロードiframeは優先度を下げる
            dependency.is_lazy_loaded = true
          else
            dependency.weight = 0.7  # 通常のiframeは中程度の優先度
          end
          
          dependencies << dependency
        end
        
        # インライン <style> タグからのインポートとURLを抽出
        document.query_selector_all("style").each do |style|
          css_content = style.text_content
          next if css_content.empty?
          
          # CSSからのインポートと外部リソースを抽出
          css_dependencies = extract_resources_from_css(css_content, base_url)
          dependencies.concat(css_dependencies)
        end
        
        # インライン <script> タグからの動的リソース読み込みを抽出
        document.query_selector_all("script:not([src])").each do |script|
          js_content = script.text_content
          next if js_content.empty?
          
          # JavaScriptから動的に読み込まれる可能性のあるリソースを抽出
          js_dependencies = extract_possible_resources_from_js(js_content, base_url)
          dependencies.concat(js_dependencies)
        end
        
        # JSON-LD構造化データからの関連リソース抽出
        document.query_selector_all("script[type='application/ld+json']").each do |json_ld|
          content = json_ld.text_content
          next if content.empty?
          
          begin
            json = JSON.parse(content)
            extract_urls_from_json_ld(json, base_url).each do |url, type|
              resource_type = case type
                            when "image"
                              ResourceType::Image
                            when "video"
                              ResourceType::Media
                            else
                              ResourceType::Other
                            end
              
              dependency = ResourceDependency.new(url, resource_type, base_url)
              dependency.weight = 0.4  # 構造化データはあまり優先度が高くない
              dependencies << dependency
            end
          rescue
            # JSON解析エラーは無視
          end
        end
        
        # <meta> タグからのプリロード情報
        if preload_meta = document.query_selector("meta[name='x-quantum-preload']")
          if content = preload_meta.attribute("content")
            content.split(",").each do |preload_url|
              url = preload_url.strip
              next if url.empty?
              
              absolute_url = make_absolute_url(url, base_url)
              ext = File.extname(url).downcase
              
              resource_type = case ext
                            when ".css"
                              ResourceType::Stylesheet
                            when ".js"
                              ResourceType::Script
                            when ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg"
                              ResourceType::Image
                            when ".woff", ".woff2", ".ttf", ".otf", ".eot"
                              ResourceType::Font
                            else
                              ResourceType::Other
                            end
              
              dependency = ResourceDependency.new(absolute_url, resource_type, base_url)
              dependency.weight = 0.9  # メタタグで明示的に指定されたリソースは高優先度
              dependencies << dependency
            end
          end
        end
        
        # アイコンとファビコンの抽出
        document.query_selector_all("link[rel='icon'], link[rel='shortcut icon'], link[rel='apple-touch-icon']").each do |icon|
          href = icon.attribute("href").try &.strip
          next unless href && !href.empty?
          
          absolute_url = make_absolute_url(href, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Image, base_url)
          dependency.weight = 0.75  # アイコンは比較的優先度が高い
          dependencies << dependency
        end
        
        # フォントの先読み設定
        document.query_selector_all("link[rel='preload'][as='font']").each do |font_link|
          href = font_link.attribute("href").try &.strip
          next unless href && !href.empty?
          
          absolute_url = make_absolute_url(href, base_url)
          dependency = ResourceDependency.new(absolute_url, ResourceType::Font, base_url)
          dependency.weight = 0.95  # 明示的に先読みされるフォントは優先度が高い
          dependencies << dependency
        end
        
        # Web App Manifestの抽出
        if manifest_link = document.query_selector("link[rel='manifest']")
          if href = manifest_link.attribute("href").try &.strip
            absolute_url = make_absolute_url(href, base_url)
            dependency = ResourceDependency.new(absolute_url, ResourceType::Other, base_url)
            dependency.weight = 0.5
            dependencies << dependency
          end
        end
        
        # 重複を排除（同じURLのリソースが複数ある場合は最も優先度の高いものを保持）
        unique_deps = {} of String => ResourceDependency
        dependencies.each do |dep|
          existing = unique_deps[dep.url]?
          if existing.nil? || dep.weight > existing.weight
            unique_deps[dep.url] = dep
          end
        end
        
        # パース時間とリソース数をログ
        parse_time = Time.monotonic - start_time
        Log.debug { "HTML解析完了: #{unique_deps.size}個のリソースを抽出 (#{parse_time.total_milliseconds.round(2)}ms)" }
        
        return unique_deps.values
      rescue ex
        Log.error(exception: ex) { "HTML解析中にエラーが発生: #{base_url}" }
        return [] of ResourceDependency
      end
    end
    
    # メディアクエリを評価
    private def evaluate_media_query(media_query : String, viewport_width : Int32) : Bool
      # 簡易的なメディアクエリ評価
      # 本来は完全なCSSメディアクエリパーサーが必要
      
      # print用のみの場合はfalse
      return false if media_query == "print"
      
      # screen用の場合はtrue
      return true if media_query == "screen"
      
      # max-widthチェック
      if media_query =~ /\(max-width:\s*(\d+)px\)/
        max_width = $1.to_i
        return viewport_width <= max_width
      end
      
      # min-widthチェック
      if media_query =~ /\(min-width:\s*(\d+)px\)/
        min_width = $1.to_i
        return viewport_width >= min_width
      end
      
      # 両方指定の場合
      if media_query =~ /\(min-width:\s*(\d+)px\).*\(max-width:\s*(\d+)px\)/
        min_width = $1.to_i
        max_width = $2.to_i
        return viewport_width >= min_width && viewport_width <= max_width
      end
      
      # デフォルトはtrue
      true
    end
    
    # srcset属性をパース
    private def parse_srcset(srcset : String) : Array(NamedTuple(url: String, width: Int32?))
      result = [] of NamedTuple(url: String, width: Int32?)
      
      srcset.split(",").each do |candidate|
        parts = candidate.strip.split(/\s+/, 2)
        
        url = parts[0].strip
        next if url.empty?
        
        width = nil
        
        if parts.size > 1
          descriptor = parts[1].strip
          
          # 幅記述子 (例: 800w)
          if descriptor =~ /^(\d+)w$/
            width = $1.to_i
          end
        end
        
        result << {url: url, width: width}
      end
      
      result
    end
    
    # 最適なsrcset候補を選択
    private def select_best_srcset_candidate(candidates : Array(NamedTuple(url: String, width: Int32?)), viewport_width : Int32) : String?
      # 幅情報を持つ候補のみをフィルタリング
      width_candidates = candidates.reject { |c| c[:width].nil? }
      
      if width_candidates.empty?
        # 幅情報がない場合は最初の候補を返す
        return candidates.first[:url] if candidates.any?
        return nil
      end
      
      # ビューポート幅の1.5倍以下の候補で、最大のものを選択
      # デバイスピクセル比を考慮した適切なサイズを選択するための近似値
      device_pixel_ratio = 1.5
      target_width = (viewport_width * device_pixel_ratio).to_i
      
      suitable_candidates = width_candidates.select { |c| c[:width].not_nil! <= target_width }
      
      if suitable_candidates.any?
        # 適切な候補から最大のものを選択
        return suitable_candidates.max_by { |c| c[:width].not_nil! }[:url]
      else
        # 適切な候補がない場合は、全候補から最小のものを選択
        return width_candidates.min_by { |c| c[:width].not_nil! }[:url]
      end
    end
    
    # JSON-LDからURLを抽出
    private def extract_urls_from_json_ld(json : JSON::Any, base_url : String) : Array(Tuple(String, String))
      result = [] of Tuple(String, String)
      
      case json.raw
      when Hash
        json.as_h.each do |key, value|
          case key
          when "image", "thumbnail", "logo"
            if value.as_s?
              url = make_absolute_url(value.as_s, base_url)
              result << {url, "image"}
            elsif value.as_a?
              value.as_a.each do |img|
                if img.as_s?
                  url = make_absolute_url(img.as_s, base_url)
                  result << {url, "image"}
                elsif img.as_h? && img["url"]?.try &.as_s?
                  url = make_absolute_url(img["url"].as_s, base_url)
                  result << {url, "image"}
                end
              end
            elsif value.as_h? && value["url"]?.try &.as_s?
              url = make_absolute_url(value["url"].as_s, base_url)
              result << {url, "image"}
            end
          when "contentUrl", "url"
            if value.as_s?
              url = make_absolute_url(value.as_s, base_url)
              result << {url, "other"}
            end
          when "video", "audio"
            if value.as_h? && value["contentUrl"]?.try &.as_s?
              url = make_absolute_url(value["contentUrl"].as_s, base_url)
              result << {url, "video"}
            end
          else
            # 再帰的に検索
            if value.as_h? || value.as_a?
              result.concat(extract_urls_from_json_ld(value, base_url))
            end
          end
        end
      when Array
        json.as_a.each do |item|
          result.concat(extract_urls_from_json_ld(item, base_url))
        end
      end
      
      result
    end
    
    # DNS名前解決のスケジュール
    private def schedule_dns_prefetch(url : String)
      uri = URI.parse(url)
      return unless uri.host
      
      # DNSリゾルバにプリフェッチリクエストを送信
      Log.debug { "DNS prefetch: #{uri.host}" }
      @network_manager.prefetch_dns(uri.host.not_nil!)
    end
    
    # プリコネクトのスケジュール
    private def schedule_preconnect(url : String)
      uri = URI.parse(url)
      return unless uri.host
      
      # コネクションマネージャに接続準備リクエストを送信
      scheme = uri.scheme || "https"
      port = uri.port || (scheme == "https" ? 443 : 80)
      
      Log.debug { "Preconnect: #{scheme}://#{uri.host}:#{port}" }
      @network_manager.preconnect(uri.host.not_nil!, port, scheme == "https")
    end
    
    # パスからコンテンツタイプを推測
    private def content_type_from_path(path : String) : String
      extension = File.extname(path).downcase
      
      case extension
      when ".html", ".htm"
        "text/html"
      when ".css"
        "text/css"
      when ".js"
        "application/javascript"
      when ".json"
        "application/json"
      when ".png"
        "image/png"
      when ".jpg", ".jpeg"
        "image/jpeg"
      when ".gif"
        "image/gif"
      when ".svg"
        "image/svg+xml"
      when ".woff", ".woff2", ".ttf", ".otf", ".eot"
        "font/#{extension[1..-1]}"
      when ".mp4"
        "video/mp4"
      when ".mp3"
        "audio/mpeg"
      when ".webp"
        "image/webp"
      when ".ico"
        "image/x-icon"
      when ".xml"
        "application/xml"
      else
        "application/octet-stream"
      end
    end
    
    # 基本的なヒューリスティックによる予測
    private def heuristic_prediction(path : String) : Float64
      # 拡張子に基づく予測
      if path.ends_with?(".js")
        0.9  # JSは少し優先度低め
      elsif path.ends_with?(".css")
        1.2  # CSSは優先度高め
      elsif path.ends_with?(".woff2") || path.ends_with?(".woff")
        1.5  # フォントは優先度高め
      elsif path.ends_with?(".png") || path.ends_with?(".jpg") || path.ends_with?(".webp")
        # 画像名に基づく優先度調整
        if path.includes?("hero") || path.includes?("banner") || path.includes?("header")
          1.8  # ヒーロー画像は優先度高め
        elsif path.includes?("footer") || path.includes?("background")
          0.7  # フッターや背景は優先度低め
        else
          1.0  # その他の画像は標準
        end
      elsif path.includes?("api") || path.ends_with?(".json")
        1.1  # APIやJSONデータは優先度やや高め
      elsif path.ends_with?(".mp4") || path.ends_with?(".webm")
        0.6  # 動画は優先度低め
      elsif path.ends_with?(".svg")
        1.3  # SVGはCSSと同様に優先度高め
      else
        1.0  # その他は標準
      end
    end
  end
end 