require "./dom_manager"
require "./javascript_engine"
require "./layout_engine"
require "./rendering_engine"
require "uuid"
require "log"

module QuantumCore
  # ブラウザの1つのページを表現するクラス
  class Page
    # リソースの読み込み状態を表す型
    enum ResourceState
      Loading
      Loaded
      Failed
    end
    
    # ページの読み込み状態を表す型
    enum LoadState
      Initial
      Loading
      Interactive
      Complete
      Failed
    end
    
    # ナビゲーション種別
    enum NavigationType
      Navigate   # 新規ナビゲーション
      Reload     # リロード
      BackForward  # 履歴移動
    end
    
    # エラー種別
    enum ErrorType
      NetworkError      # ネットワークエラー
      ParseError        # パースエラー
      JavaScriptError   # JavaScriptエラー
      ResourceError     # リソースエラー
      SecurityError     # セキュリティエラー
      InternalError     # 内部エラー
    end
    
    # エラーオブジェクト
    class PageError
      getter type : ErrorType
      getter message : String
      getter url : String?
      getter time : Time
      getter recoverable : Bool
      
      def initialize(@type : ErrorType, @message : String, @url : String? = nil, @recoverable : Bool = false)
        @time = Time.utc
      end
      
      def to_s : String
        url_part = @url ? " (#{@url})" : ""
        recovery_part = @recoverable ? "[回復可能]" : "[回復不可]"
        "[#{@type}] #{@message}#{url_part} #{recovery_part}"
      end
    end
    
    # パフォーマンスメトリクスクラス
    class PerformanceMetrics
      getter navigation_start_time : Time
      getter dom_content_loaded_time : Time?
      getter load_time : Time?
      getter time_to_first_byte : Time?
      getter time_to_first_paint : Time?
      getter time_to_first_contentful_paint : Time?
      getter time_to_interactive : Time?
      
      property resource_load_times : Hash(String, Float64)
      property js_execution_times : Array(Float64)
      property layout_times : Array(Float64)
      property paint_times : Array(Float64)
      
      def initialize
        @navigation_start_time = Time.utc
        @dom_content_loaded_time = nil
        @load_time = nil
        @time_to_first_byte = nil
        @time_to_first_paint = nil
        @time_to_first_contentful_paint = nil
        @time_to_interactive = nil
        
        @resource_load_times = {} of String => Float64
        @js_execution_times = [] of Float64
        @layout_times = [] of Float64
        @paint_times = [] of Float64
      end
      
      # ナビゲーション開始時間の設定
      def set_navigation_start
        @navigation_start_time = Time.utc
      end
      
      # 最初のバイト受信時間の設定
      def set_time_to_first_byte
        @time_to_first_byte = Time.utc
      end
      
      # DOMContentLoaded時間の設定
      def set_dom_content_loaded
        @dom_content_loaded_time = Time.utc
      end
      
      # ロード完了時間の設定
      def set_load_complete
        @load_time = Time.utc
      end
      
      # 最初の描画時間の設定
      def set_first_paint
        @time_to_first_paint = Time.utc
      end
      
      # 最初のコンテンツ描画時間の設定
      def set_first_contentful_paint
        @time_to_first_contentful_paint = Time.utc
      end
      
      # インタラクティブになった時間の設定
      def set_time_to_interactive
        @time_to_interactive = Time.utc
      end
      
      # リソース読み込み時間の記録
      def record_resource_load_time(url : String, duration_ms : Float64)
        @resource_load_times[url] = duration_ms
      end
      
      # JavaScript実行時間の記録
      def record_js_execution_time(duration_ms : Float64)
        @js_execution_times << duration_ms
      end
      
      # レイアウト計算時間の記録
      def record_layout_time(duration_ms : Float64)
        @layout_times << duration_ms
      end
      
      # 描画時間の記録
      def record_paint_time(duration_ms : Float64)
        @paint_times << duration_ms
      end
      
      # DOMContentLoadedまでの経過時間（ミリ秒）
      def dom_content_loaded_duration : Float64?
        return nil if @dom_content_loaded_time.nil?
        (@dom_content_loaded_time.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # ロード完了までの経過時間（ミリ秒）
      def load_duration : Float64?
        return nil if @load_time.nil?
        (@load_time.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # 最初のバイトまでの経過時間（ミリ秒）
      def ttfb_duration : Float64?
        return nil if @time_to_first_byte.nil?
        (@time_to_first_byte.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # 最初の描画までの経過時間（ミリ秒）
      def first_paint_duration : Float64?
        return nil if @time_to_first_paint.nil?
        (@time_to_first_paint.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # 最初のコンテンツ描画までの経過時間（ミリ秒）
      def first_contentful_paint_duration : Float64?
        return nil if @time_to_first_contentful_paint.nil?
        (@time_to_first_contentful_paint.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # インタラクティブになるまでの経過時間（ミリ秒）
      def time_to_interactive_duration : Float64?
        return nil if @time_to_interactive.nil?
        (@time_to_interactive.not_nil! - @navigation_start_time).total_milliseconds
      end
      
      # 平均JavaScript実行時間
      def average_js_execution_time : Float64
        return 0.0 if @js_execution_times.empty?
        @js_execution_times.sum / @js_execution_times.size
      end
      
      # 平均レイアウト計算時間
      def average_layout_time : Float64
        return 0.0 if @layout_times.empty?
        @layout_times.sum / @layout_times.size
      end
      
      # 平均描画時間
      def average_paint_time : Float64
        return 0.0 if @paint_times.empty?
        @paint_times.sum / @paint_times.size
      end
      
      # メトリクスのサマリーを取得
      def summary : String
        parts = [] of String
        
        parts << "TTFB: #{ttfb_duration.try(&.round(2)) || "N/A"}ms"
        parts << "DOM Content Loaded: #{dom_content_loaded_duration.try(&.round(2)) || "N/A"}ms"
        parts << "Load: #{load_duration.try(&.round(2)) || "N/A"}ms"
        parts << "First Paint: #{first_paint_duration.try(&.round(2)) || "N/A"}ms"
        parts << "First Contentful Paint: #{first_contentful_paint_duration.try(&.round(2)) || "N/A"}ms"
        parts << "Time to Interactive: #{time_to_interactive_duration.try(&.round(2)) || "N/A"}ms"
        
        if !@resource_load_times.empty?
          parts << "リソース数: #{@resource_load_times.size}"
          parts << "平均リソース読み込み時間: #{(@resource_load_times.values.sum / @resource_load_times.size).round(2)}ms"
        end
        
        if !@js_execution_times.empty?
          parts << "平均JS実行時間: #{average_js_execution_time.round(2)}ms"
        end
        
        if !@layout_times.empty?
          parts << "平均レイアウト計算時間: #{average_layout_time.round(2)}ms"
        end
        
        if !@paint_times.empty?
          parts << "平均描画時間: #{average_paint_time.round(2)}ms"
        end
        
        parts.join(", ")
      end
      
      # メトリクスの詳細情報
      def details : Hash(String, String)
        result = {} of String => String
        
        result["TTFB"] = "#{ttfb_duration.try(&.round(2)) || "N/A"}ms"
        result["DOMContentLoaded"] = "#{dom_content_loaded_duration.try(&.round(2)) || "N/A"}ms"
        result["Load"] = "#{load_duration.try(&.round(2)) || "N/A"}ms"
        result["FirstPaint"] = "#{first_paint_duration.try(&.round(2)) || "N/A"}ms"
        result["FirstContentfulPaint"] = "#{first_contentful_paint_duration.try(&.round(2)) || "N/A"}ms"
        result["TimeToInteractive"] = "#{time_to_interactive_duration.try(&.round(2)) || "N/A"}ms"
        
        result["ResourceCount"] = @resource_load_times.size.to_s
        
        if !@resource_load_times.empty?
          result["AvgResourceLoadTime"] = "#{(@resource_load_times.values.sum / @resource_load_times.size).round(2)}ms"
          
          # 最も遅いリソース
          slowest_resource = @resource_load_times.max_by? { |_, time| time }
          if slowest_resource
            result["SlowestResource"] = "#{slowest_resource[0]} (#{slowest_resource[1].round(2)}ms)"
          end
        end
        
        result["AvgJSExecutionTime"] = "#{average_js_execution_time.round(2)}ms"
        result["AvgLayoutTime"] = "#{average_layout_time.round(2)}ms"
        result["AvgPaintTime"] = "#{average_paint_time.round(2)}ms"
        
        result
      end
      
      # JSONシリアライズ可能な形式に変換
      def to_json_data
        {
          "navigationStart" => @navigation_start_time.to_unix_ms,
          "domContentLoaded" => @dom_content_loaded_time.try(&.to_unix_ms),
          "load" => @load_time.try(&.to_unix_ms),
          "ttfb" => @time_to_first_byte.try(&.to_unix_ms),
          "firstPaint" => @time_to_first_paint.try(&.to_unix_ms),
          "firstContentfulPaint" => @time_to_first_contentful_paint.try(&.to_unix_ms),
          "timeToInteractive" => @time_to_interactive.try(&.to_unix_ms),
          "resources" => @resource_load_times,
          "jsExecutionTimes" => @js_execution_times,
          "layoutTimes" => @layout_times,
          "paintTimes" => @paint_times
        }
      end
    end
    
    # ページの状態を保存するためのクラス
    class PageState
      getter scroll_position : Tuple(Float64, Float64)
      getter form_data : Hash(String, String)
      getter selected_elements : Array(String)
      getter js_state : String?
      
      def initialize(
        @scroll_position : Tuple(Float64, Float64) = {0.0, 0.0},
        @form_data : Hash(String, String) = {} of String => String,
        @selected_elements : Array(String) = [] of String,
        @js_state : String? = nil
      )
      end
      
      # JSONシリアライズ可能な形式に変換
      def to_json_data
        {
          "scrollPosition" => {
            "x" => @scroll_position[0],
            "y" => @scroll_position[1]
          },
          "formData" => @form_data,
          "selectedElements" => @selected_elements,
          "jsState" => @js_state
        }
      end
      
      # JSON文字列からPageStateを生成
      def self.from_json(json_string : String) : PageState
        data = JSON.parse(json_string)
        
        scroll_x = 0.0
        scroll_y = 0.0
        
        if scroll_pos = data["scrollPosition"]?
          scroll_x = scroll_pos["x"].as_f? || 0.0
          scroll_y = scroll_pos["y"].as_f? || 0.0
        end
        
        form_data = {} of String => String
        if form_data_json = data["formData"]?
          form_data_json.as_h?.try do |hash|
            hash.each do |key, value|
              form_data[key.to_s] = value.to_s
            end
          end
        end
        
        selected_elements = [] of String
        if selected_json = data["selectedElements"]?
          selected_json.as_a?.try do |array|
            array.each do |item|
              selected_elements << item.to_s
            end
          end
        end
        
        js_state = data["jsState"]?.try(&.to_s)
        
        PageState.new({scroll_x, scroll_y}, form_data, selected_elements, js_state)
      end
    end
    
    # リソースの優先度を表す型
    enum ResourcePriority
      Critical    # 即座に読み込むべき重要なリソース
      High        # 高優先度（早く読み込むべき）
      Medium      # 中優先度（標準的な優先度）
      Low         # 低優先度（遅延読み込み可能）
      Lazy        # 非常に低い優先度（表示領域に入ったときのみ読み込み）
    end
    
    # リソース情報を管理するクラス
    class ResourceInfo
      getter url : String
      getter type : String
      getter priority : ResourcePriority
      property state : ResourceState
      property start_time : Time?
      property end_time : Time?
      property size : Int64?
      property dependency_of : Array(String)
      
      def initialize(@url : String, @type : String, @priority : ResourcePriority = ResourcePriority::Medium)
        @state = ResourceState::Loading
        @start_time = nil
        @end_time = nil
        @size = nil
        @dependency_of = [] of String
      end
      
      # リソースが完了したかどうか
      def completed? : Bool
        @state == ResourceState::Loaded || @state == ResourceState::Failed
      end
      
      # 読み込み時間を計算（ミリ秒）
      def load_time : Float64?
        return nil if @start_time.nil? || @end_time.nil?
        (@end_time.not_nil! - @start_time.not_nil!).total_milliseconds
      end
    end
    
    # プログレッシブレンダリング状態
    class RenderingProgress
      getter is_progressive_enabled : Bool
      property layout_complete : Bool
      property critical_resources_loaded : Bool
      property is_rendering : Bool
      property render_count : Int32
      
      def initialize(@is_progressive_enabled : Bool = true)
        @layout_complete = false
        @critical_resources_loaded = false
        @is_rendering = false
        @render_count = 0
      end
      
      # 中間レンダリングを実行すべきかどうか
      def should_perform_intermediate_render? : Bool
        return false unless @is_progressive_enabled
        @layout_complete && @critical_resources_loaded && !@is_rendering
      end
    end
    
    # サンドボックスセキュリティレベル
    enum SandboxLevel
      None         # サンドボックスなし（信頼済みページ）
      Permissive   # 制限が緩いサンドボックス（特定の機能のみ許可）
      Restrictive  # 制限が厳しいサンドボックス（最小限の機能のみ許可）
      Isolated     # 完全に隔離されたサンドボックス（ほぼすべてを禁止）
    end
    
    # サンドボックス設定
    class SandboxSettings
      property level : SandboxLevel
      property allow_scripts : Bool
      property allow_forms : Bool
      property allow_popups : Bool
      property allow_same_origin : Bool
      property allow_top_navigation : Bool
      property allow_pointer_lock : Bool
      property allow_downloads : Bool
      property allow_modals : Bool
      property allow_orientation_lock : Bool
      property allow_presentation : Bool
      property allow_storage : Bool
      
      def initialize(@level : SandboxLevel = SandboxLevel::Restrictive)
        case @level
        when SandboxLevel::None
          # すべてを許可
          @allow_scripts = true
          @allow_forms = true
          @allow_popups = true
          @allow_same_origin = true
          @allow_top_navigation = true
          @allow_pointer_lock = true
          @allow_downloads = true
          @allow_modals = true
          @allow_orientation_lock = true
          @allow_presentation = true
          @allow_storage = true
        when SandboxLevel::Permissive
          # スクリプト、フォーム、同一オリジンを許可
          @allow_scripts = true
          @allow_forms = true
          @allow_popups = false
          @allow_same_origin = true
          @allow_top_navigation = false
          @allow_pointer_lock = false
          @allow_downloads = true
          @allow_modals = true
          @allow_orientation_lock = false
          @allow_presentation = false
          @allow_storage = true
        when SandboxLevel::Restrictive
          # 最小限の機能のみ許可
          @allow_scripts = false
          @allow_forms = false
          @allow_popups = false
          @allow_same_origin = false
          @allow_top_navigation = false
          @allow_pointer_lock = false
          @allow_downloads = false
          @allow_modals = false
          @allow_orientation_lock = false
          @allow_presentation = false
          @allow_storage = false
        when SandboxLevel::Isolated
          # すべてを禁止
          @allow_scripts = false
          @allow_forms = false
          @allow_popups = false
          @allow_same_origin = false
          @allow_top_navigation = false
          @allow_pointer_lock = false
          @allow_downloads = false
          @allow_modals = false
          @allow_orientation_lock = false
          @allow_presentation = false
          @allow_storage = false
        end
      end
      
      # 許可属性文字列の生成（HTMLサンドボックス属性用）
      def to_attribute_string : String
        attrs = [] of String
        
        attrs << "allow-scripts" if @allow_scripts
        attrs << "allow-forms" if @allow_forms
        attrs << "allow-popups" if @allow_popups
        attrs << "allow-same-origin" if @allow_same_origin
        attrs << "allow-top-navigation" if @allow_top_navigation
        attrs << "allow-pointer-lock" if @allow_pointer_lock
        attrs << "allow-downloads" if @allow_downloads
        attrs << "allow-modals" if @allow_modals
        attrs << "allow-orientation-lock" if @allow_orientation_lock
        attrs << "allow-presentation" if @allow_presentation
        attrs << "allow-storage-access-by-user-activation" if @allow_storage
        
        attrs.join(" ")
      end
      
      # CSP (Content Security Policy) ヘッダの生成
      def to_csp_header : String
        policies = [] of String
        
        # スクリプトソース制限
        unless @allow_scripts
          policies << "script-src 'none'"
        else
          policies << "script-src 'self'"
        end
        
        # フォーム制限
        unless @allow_forms
          policies << "form-action 'none'"
        end
        
        # フレーム制限
        policies << "frame-ancestors 'self'"
        
        # ポップアップ制限
        unless @allow_popups
          policies << "popup 'none'"
        end
        
        # オブジェクト制限
        policies << "object-src 'none'"
        
        # 基本制限
        policies << "default-src 'self'"
        
        policies.join("; ")
      end
    end
    
    # スクリーンショット設定
    class ScreenshotOptions
      property width : Int32?
      property height : Int32?
      property format : String
      property quality : Int32
      property full_page : Bool
      property element_selector : String?
      
      def initialize(
        @width : Int32? = nil,
        @height : Int32? = nil,
        @format : String = "png",
        @quality : Int32 = 90,
        @full_page : Bool = false,
        @element_selector : String? = nil
      )
      end
    end
    
    # スクリーンショット結果
    class Screenshot
      getter data : Bytes
      getter mime_type : String
      getter width : Int32
      getter height : Int32
      getter timestamp : Time
      
      def initialize(@data : Bytes, @mime_type : String, @width : Int32, @height : Int32)
        @timestamp = Time.utc
      end
      
      # ファイルに保存
      def save_to_file(path : String) : Bool
        begin
          File.write(path, @data)
          true
        rescue ex
          false
        end
      end
    end
    
    # 超最適化レベル
    enum OptimizationLevel
      Standard    # 標準的な最適化
      Aggressive  # 積極的な最適化（パフォーマンス優先）
      MaxMemory   # メモリ使用量を最小化
      MaxSpeed    # 速度を最大化
      Balanced    # バランスの取れた最適化
      Adaptive    # 状況に応じて適応的に最適化
    end
    
    # 先読み戦略
    enum PrefetchStrategy
      None          # 先読みなし
      Conservative  # 保守的（明示的に指定されたリソースのみ）
      Moderate      # 中程度（リンクやスクリプト依存関係）
      Aggressive    # 積極的（ユーザーが訪問する可能性のあるページも先読み）
      Predictive    # AI予測ベース（ユーザー行動予測に基づく先読み）
    end
    
    # レンダリングプロファイル
    enum RenderingProfile
      Standard      # 標準的なレンダリング
      HighFPS       # 高FPSを優先
      PowerSaving   # 省電力モード
      UltraSmooth   # 超滑らかなアニメーション
      MinimalFlash  # フラッシュを最小限に
    end
    
    # 並列処理構成
    class ParallelProcessingConfig
      property parsing_threads : Int32
      property layout_threads : Int32
      property rendering_threads : Int32
      property max_workers : Int32
      property task_chunk_size : Int32
      property priority_boost_enabled : Bool
      
      def initialize(
        @parsing_threads : Int32 = 2,
        @layout_threads : Int32 = 2,
        @rendering_threads : Int32 = 2,
        @max_workers : Int32 = 4,
        @task_chunk_size : Int32 = 1000,
        @priority_boost_enabled : Bool = true
      )
      end
      
      # ハードウェア情報に基づいて最適な設定を生成
      def self.optimal_for_hardware : ParallelProcessingConfig
        # CPUコア数を取得
        cpu_cores = System.cpu_count
        
        # アーキテクチャに基づいてワーカー数を調整
        # CPU効率を最適化するために、コア数の3/4を使用（一部をシステムに残す）
        workers = {(cpu_cores * 0.75).to_i, 1}.max
        
        # メモリに基づいてスレッド数を調整
        available_memory = System.memory_info.available
        
        # メモリが少ない場合はスレッド数を削減
        thread_count = if available_memory < 512_000_000 # 512MB未満
                        1
                      elsif available_memory < 2_000_000_000 # 2GB未満
                        2
                      else
                        {(cpu_cores * 0.5).to_i, 1}.max
                      end
        
        # タスクチャンクサイズもメモリに基づいて調整
        chunk_size = if available_memory < 1_000_000_000 # 1GB未満
                      500
                    else
                      1000
                    end
        
        ParallelProcessingConfig.new(
          parsing_threads: thread_count,
          layout_threads: thread_count,
          rendering_threads: thread_count,
          max_workers: workers,
          task_chunk_size: chunk_size
        )
      end
    end
    
    # 超最適化設定
    class HyperOptimizationSettings
      property level : OptimizationLevel
      property prefetch_strategy : PrefetchStrategy
      property rendering_profile : RenderingProfile
      property parallel_config : ParallelProcessingConfig
      property memory_pressure_threshold : Float64
      property speculative_jit_enabled : Bool
      property zero_copy_rendering : Bool
      property compressed_dom : Bool
      property layout_recycling : Bool
      property content_adaptive_refresh : Bool
      
      def initialize(
        @level : OptimizationLevel = OptimizationLevel::Balanced,
        @prefetch_strategy : PrefetchStrategy = PrefetchStrategy::Moderate,
        @rendering_profile : RenderingProfile = RenderingProfile::Standard,
        @parallel_config : ParallelProcessingConfig = ParallelProcessingConfig.new,
        @memory_pressure_threshold : Float64 = 0.8,
        @speculative_jit_enabled : Bool = true,
        @zero_copy_rendering : Bool = true,
        @compressed_dom : Bool = true,
        @layout_recycling : Bool = true,
        @content_adaptive_refresh : Bool = true
      )
      end
      
      # モバイルデバイス向けの最適化設定
      def self.for_mobile : HyperOptimizationSettings
        config = ParallelProcessingConfig.new(
          parsing_threads: 1,
          layout_threads: 1,
          rendering_threads: 2,
          max_workers: 2,
          task_chunk_size: 500
        )
        
        HyperOptimizationSettings.new(
          level: OptimizationLevel::MaxMemory,
          prefetch_strategy: PrefetchStrategy::Conservative,
          rendering_profile: RenderingProfile::PowerSaving,
          parallel_config: config,
          memory_pressure_threshold: 0.6,
          speculative_jit_enabled: false
        )
      end
      
      # 高性能デスクトップ向けの最適化設定
      def self.for_high_performance : HyperOptimizationSettings
        config = ParallelProcessingConfig.new(
          parsing_threads: 4,
          layout_threads: 4,
          rendering_threads: 4,
          max_workers: 8,
          task_chunk_size: 2000
        )
        
        HyperOptimizationSettings.new(
          level: OptimizationLevel::MaxSpeed,
          prefetch_strategy: PrefetchStrategy::Aggressive,
          rendering_profile: RenderingProfile::UltraSmooth,
          parallel_config: config,
          memory_pressure_threshold: 0.9
        )
      end
      
      # 低スペックデバイス向けの最適化設定
      def self.for_low_end : HyperOptimizationSettings
        config = ParallelProcessingConfig.new(
          parsing_threads: 1,
          layout_threads: 1,
          rendering_threads: 1,
          max_workers: 1,
          task_chunk_size: 300
        )
        
        HyperOptimizationSettings.new(
          level: OptimizationLevel::MaxMemory,
          prefetch_strategy: PrefetchStrategy::None,
          rendering_profile: RenderingProfile::PowerSaving,
          parallel_config: config,
          memory_pressure_threshold: 0.5,
          speculative_jit_enabled: false,
          zero_copy_rendering: true,
          compressed_dom: true,
          layout_recycling: true,
          content_adaptive_refresh: false
        )
      end
    end
    
    # コンテンツ分析結果
    class ContentAnalysis
      property content_complexity : Float64
      property interactive_elements_count : Int32
      property animation_complexity : Float64
      property text_to_media_ratio : Float64
      property viewport_coverage : Float64
      property critical_elements : Array(String)
      property predicted_scroll_areas : Array(String)
      property ai_predicted_focus_elements : Array(String)
      property content_category : String
      property readability_score : Float64
      
      def initialize
        @content_complexity = 0.0
        @interactive_elements_count = 0
        @animation_complexity = 0.0
        @text_to_media_ratio = 0.0
        @viewport_coverage = 0.0
        @critical_elements = [] of String
        @predicted_scroll_areas = [] of String
        @ai_predicted_focus_elements = [] of String
        @content_category = "unknown"
        @readability_score = 0.0
      end
      
      # 解析済みかどうか
      def analyzed? : Bool
        @content_complexity > 0.0
      end
    end
    
    # 先読みエンジン
    class PrefetchEngine
      property strategy : PrefetchStrategy
      property max_prefetch_resources : Int32
      property max_prefetch_depth : Int32
      property prefetched_urls : Set(String)
      property prefetch_priority_queue : Array(Tuple(String, Float64))
      property ai_predicted_resources : Hash(String, Float64)
      
      def initialize(
        @strategy : PrefetchStrategy = PrefetchStrategy::Moderate,
        @max_prefetch_resources : Int32 = 10,
        @max_prefetch_depth : Int32 = 1
      )
        @prefetched_urls = Set(String).new
        @prefetch_priority_queue = [] of Tuple(String, Float64)
        @ai_predicted_resources = {} of String => Float64
      end
      
      # 先読み候補の追加
      def add_candidate(url : String, priority : Float64) : Bool
        return false if @prefetched_urls.includes?(url)
        
        @prefetch_priority_queue << {url, priority}
        # 優先度順にソート（高いものが先頭）
        @prefetch_priority_queue.sort! { |a, b| b[1] <=> a[1] }
        
        # キューが大きすぎる場合は優先度の低いものを削除
        if @prefetch_priority_queue.size > @max_prefetch_resources * 2
          @prefetch_priority_queue = @prefetch_priority_queue[0...@max_prefetch_resources]
        end
        
        true
      end
      
      # ドキュメントからリンクを分析して先読み候補を追加
      def analyze_document(document : Document) : Int32
        return 0 if @strategy == PrefetchStrategy::None
        
        count = 0
        
        # <link rel="preload"> や <link rel="prefetch"> タグの処理
        document.query_selector_all("link[rel='preload'], link[rel='prefetch']").each do |link|
          href = link.get_attribute("href")
          next if href.nil? || href.empty?
          
          # プリロードは高優先度、プリフェッチは低優先度
          priority = link.get_attribute("rel") == "preload" ? 0.9 : 0.6
          if add_candidate(href, priority)
            count += 1
          end
        end
        
        # より積極的な戦略の場合はリンクも分析
        if @strategy >= PrefetchStrategy::Moderate
          # <a> タグのhref属性を分析
          document.query_selector_all("a[href]").each do |anchor|
            href = anchor.get_attribute("href")
            next if href.nil? || href.empty? || href.starts_with?("#")
            
            # ビューポート内のリンクは優先度が高い
            priority = is_in_viewport?(anchor) ? 0.7 : 0.3
            if add_candidate(href, priority)
              count += 1
              break if count >= @max_prefetch_resources && @strategy != PrefetchStrategy::Aggressive
            end
          end
        end
        
        # 予測的な先読みを行う場合
        if @strategy == PrefetchStrategy::Predictive && !@ai_predicted_resources.empty?
          @ai_predicted_resources.each do |url, probability|
            # 確率が50%以上のリソースのみを候補に追加
            if probability >= 0.5
              if add_candidate(url, probability)
                count += 1
              end
            end
          end
        end
        
        count
      end
      
      # 要素がビューポート内にあるかどうかを判定
      private def is_in_viewport?(element : DOM::Element) : Bool
        # 要素の位置情報を取得
        rect = element.get_bounding_client_rect
        return false if rect.nil?
        
        # ビューポートのサイズを取得
        viewport_width = @document.default_view.inner_width
        viewport_height = @document.default_view.inner_height
        
        # 要素が少なくとも一部でもビューポート内にあるかチェック
        # 完全に画面外にある場合はfalse
        !(rect.right < 0 || 
          rect.bottom < 0 || 
          rect.left > viewport_width || 
          rect.top > viewport_height)
      end
      # 次の先読みURLを取得
      def next_prefetch_url : String?
        return nil if @prefetch_priority_queue.empty?
        
        url, _ = @prefetch_priority_queue.shift
        @prefetched_urls << url
        url
      end
      
      # 先読みURLリストをクリア
      def clear : Nil
        @prefetched_urls.clear
        @prefetch_priority_queue.clear
      end
      
      # AI予測リソースを設定
      def set_ai_predictions(predictions : Hash(String, Float64)) : Nil
        @ai_predicted_resources = predictions
      end
    end
    
    # 並列タスク処理エンジン
    class ParallelTaskEngine
      property config : ParallelProcessingConfig
      property active_tasks : Int32
      property task_queue : Deque(Proc(Nil))
      property high_priority_queue : Deque(Proc(Nil))
      property completed_tasks : Int32
      property error_count : Int32
      
      def initialize(@config : ParallelProcessingConfig)
        @active_tasks = 0
        @task_queue = Deque(Proc(Nil)).new
        @high_priority_queue = Deque(Proc(Nil)).new
        @completed_tasks = 0
        @error_count = 0
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end
      
      # タスクをキューに追加
      def schedule(task : -> Nil, high_priority : Bool = false) : Nil
        @mutex.synchronize do
          if high_priority
            @high_priority_queue << task
          else
            @task_queue << task
          end
          @condition.signal
        end
      end
      
      # 処理実行（非ブロッキング）
      def process_async : Nil
        worker_count = @config.max_workers
        
        # ワーカースレッドの起動
        worker_count.times do
          spawn do
            loop do
              task = nil
              
              @mutex.synchronize do
                # 高優先度キューからタスクを取得
                if !@high_priority_queue.empty?
                  task = @high_priority_queue.shift
                # 通常キューからタスクを取得
                elsif !@task_queue.empty?
                  task = @task_queue.shift
                end
                
                if task
                  @active_tasks += 1
                end
              end
              
              # タスクがなければ待機
              if task.nil?
                @mutex.synchronize do
                  # キューが空でかつ実行中のタスクがなければ終了
                  if @task_queue.empty? && @high_priority_queue.empty? && @active_tasks == 0
                    break
                  end
                  # そうでなければ条件変数で待機
                  @condition.wait(@mutex)
                end
                next
              end
              
              # タスクの実行
              begin
                task.call
                @mutex.synchronize do
                  @completed_tasks += 1
                end
              rescue ex
                @mutex.synchronize do
                  @error_count += 1
                end
              ensure
                @mutex.synchronize do
                  @active_tasks -= 1
                  @condition.signal if @active_tasks == 0
                end
              end
            end
          end
        end
      end
      
      # すべてのタスクが完了するまで待機
      def wait_for_completion : Bool
        @mutex.synchronize do
          while !(@task_queue.empty? && @high_priority_queue.empty? && @active_tasks == 0)
            @condition.wait(@mutex)
          end
        end
        
        @error_count == 0
      end
      
      # キューのクリア
      def clear : Nil
        @mutex.synchronize do
          @task_queue.clear
          @high_priority_queue.clear
          @completed_tasks = 0
          @error_count = 0
        end
      end
    end
    
    getter id : String
    getter url : String?
    getter title : String
    getter document : Document?
    getter history : History
    getter load_state : LoadState
    getter navigation_type : NavigationType
    getter context : JavaScriptContext
    getter stylesheets : Array(Stylesheet)
    getter scroll_position : Tuple(Float64, Float64)
    getter errors : Array(PageError)
    getter performance : PerformanceMetrics
    getter state : PageState
    
    protected setter url : String?
    protected setter title : String
    protected setter document : Document?
    protected setter load_state : LoadState
    protected setter navigation_type : NavigationType
    protected setter scroll_position : Tuple(Float64, Float64)
    protected setter state : PageState
    
    # 新しいフィールドを追加
    @resource_infos : Hash(String, ResourceInfo)
    @preload_queue : Array(String)
    @rendering_progress : RenderingProgress
    @memory_pool : ResourcePool
    @sandbox_settings : SandboxSettings
    @hyper_optimization : HyperOptimizationSettings
    @content_analysis : ContentAnalysis
    @prefetch_engine : PrefetchEngine
    @parallel_engine : ParallelTaskEngine
    
    def initialize(@dom_manager : DOMManager, @javascript_engine : JavaScriptEngine, @layout_engine : LayoutEngine, @rendering_engine : RenderingEngine)
      @id = UUID.random.to_s
      @url = nil
      @title = ""
      @document = nil
      @load_state = LoadState::Initial
      @navigation_type = NavigationType::Navigate
      @scroll_position = {0.0, 0.0}
      
      # 履歴管理
      @history = History.new
      
      # JavaScript実行コンテキスト
      @context = @javascript_engine.create_context(self)
      
      # スタイルシート
      @stylesheets = [] of Stylesheet
      
      # リソース読み込み状態
      @resources = {} of String => ResourceState
      
      # イベントリスナー
      @dom_content_loaded_listeners = [] of ->
      @load_listeners = [] of ->
      @title_change_listeners = [] of String ->
      @error_listeners = [] of PageError ->
      @performance_listeners = [] of PerformanceMetrics ->
      
      # エラー履歴
      @errors = [] of PageError
      
      # パフォーマンス計測
      @performance = PerformanceMetrics.new
      
      # ページ状態
      @state = PageState.new
      
      # 新しいフィールドの初期化
      @resource_infos = {} of String => ResourceInfo
      @preload_queue = [] of String
      @rendering_progress = RenderingProgress.new
      @memory_pool = ResourcePool.new
      
      # サンドボックス設定
      @sandbox_settings = SandboxSettings.new
      
      # 新しいフィールドの初期化
      @hyper_optimization = HyperOptimizationSettings.new
      @content_analysis = ContentAnalysis.new
      @prefetch_engine = PrefetchEngine.new
      @parallel_engine = ParallelTaskEngine.new(ParallelProcessingConfig.optimal_for_hardware)
      
      # ログの設定
      @logger = Log.for("quantum_core.page")
    end
    
    # 空白ドキュメントの初期化
    def initialize_blank_document
      html = <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>New Page</title>
      </head>
      <body>
      </body>
      </html>
      HTML
      
      @document = @dom_manager.parse_html(html)
      @title = "New Page"
    rescue ex
      handle_error(ErrorType::ParseError, "空白ドキュメントの初期化に失敗しました", nil, ex)
      # 最小限のフォールバックドキュメント
      @document = Document.new
      @title = "Error Page"
    end
    
    # ナビゲーション開始
    def navigation_start(url : String, navigation_type : NavigationType = NavigationType::Navigate) : Bool
      @logger.info { "ナビゲーション開始: #{url} [#{navigation_type}]" }
      
      # 既存のリソースとエラーをクリア
      @resources.clear
      
      # パフォーマンス計測を開始
      @performance = PerformanceMetrics.new
      @performance.set_navigation_start
      
      # 状態を更新
      @url = url
      @navigation_type = navigation_type
      @load_state = LoadState::Loading

      # ドキュメントのクリア（新しい空のドキュメントを作成）
      @document = @dom_manager.create_document
      
      # JavaScript実行コンテキストをリセット
      @context = @javascript_engine.create_context(self)
      
      # スタイルシートをクリア
      @stylesheets.clear
      
      # スクロール位置をリセット
      @scroll_position = {0.0, 0.0}
      
      # 履歴の更新
      case navigation_type
      when NavigationType::Navigate
        @history.add_entry(@url.not_nil!, @state)
      when NavigationType::Reload
        # リロード時は履歴を更新しない
      when NavigationType::BackForward
        # 履歴の移動は既に行われているはず
      end
      
      # 先読みエンジンとパラレルエンジンをリセット
      @prefetch_engine.clear
      @parallel_engine.clear
      
      # 適応型最適化の場合はデフォルト設定に戻す
      if @hyper_optimization.level == OptimizationLevel::Adaptive
        @hyper_optimization.rendering_profile = RenderingProfile::Standard
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Moderate
      end
      
      # 並列タスク処理を非同期で開始
      @parallel_engine.process_async
      
      true
    end
    
    # ナビゲーション完了
    def navigation_complete : Bool
      return false if @url.nil? || @document.nil?
      
      @logger.info { "ナビゲーション完了: #{@url}" }
      
      # コンテンツ分析を実行
      analyze_content
      
      # 最適化設定を適用
      apply_optimization_settings
      
      # リソース読み込みの最適化
      optimize_resource_loading
      
      # ドキュメントのレイアウトを計算
      @layout_engine.layout(@document.not_nil!)
      
      # レンダリング
      @rendering_engine.render(@document.not_nil!)
      
      # 状態を更新
      @load_state = LoadState::Complete
      
      # DOMContentLoadedとLoadイベントを発火
      fire_dom_content_loaded
      fire_load_event
      
      # パフォーマンスデータの更新
      @performance.set_load_complete
      
      # パフォーマンスリスナーに通知
      @performance_listeners.each &.call(@performance)
      
      true
    end
    
    # ナビゲーション停止
    def navigation_stopped(reason : String) : Bool
      @logger.info { "ナビゲーション停止: #{reason}" }
      
      # エラーの追加
      add_error(ErrorType::NetworkError, "ナビゲーションが停止されました: #{reason}", @url)
      
      # 状態を更新
      @load_state = LoadState::Failed
      
      true
    end
    
    # リソースの優先度推定
    private def estimate_resource_priority(url : String, type : String) : ResourcePriority
      # URLが現在のページURLなら最重要
      return ResourcePriority::Critical if url == @url
      
      # リソースタイプに基づいて優先度を設定
      case type
      when "text/html"
        ResourcePriority::Critical
      when "text/css", "application/javascript"
        if url.includes?("critical") || url.includes?("main")
          ResourcePriority::High
        else
          ResourcePriority::Medium
        end
      when .starts_with?("image/")
        if url.includes?("hero") || url.includes?("logo") || url.includes?("header")
          ResourcePriority::High
        elsif url.includes?("lazy") || url.includes?("footer")
          ResourcePriority::Lazy
        else
          ResourcePriority::Low
        end
      when "font/"
        ResourcePriority::Medium
      else
        ResourcePriority::Low
      end
    end
    
    # リソースプリロードのスケジュール
    def schedule_preload(url : String, type : String, as_type : String? = nil) : Bool
      return false if url.empty? || @url.nil?
      
      # すでに読み込み中または完了しているかチェック
      return false if @resource_infos.has_key?(url)
      
      # 優先度の推定
      priority = estimate_resource_priority(url, type)
      
      # リソース情報の作成
      resource_info = ResourceInfo.new(url, type, priority)
      @resource_infos[url] = resource_info
      
      # プリロードキューに追加
      @preload_queue << url unless priority == ResourcePriority::Lazy
      
      # 高優先度リソースは即時読み込み
      if priority == ResourcePriority::Critical || priority == ResourcePriority::High
        start_resource_loading(url)
      end
      
      true
    end
    
    # プリロードキューの処理
    def process_preload_queue(max_concurrent : Int32 = 6) : Nil
      # 現在読み込み中のリソース数をカウント
      loading_count = @resource_infos.count do |_, info|
        info.state == ResourceState::Loading
      end
      
      # 利用可能なスロット数
      available_slots = max_concurrent - loading_count
      return if available_slots <= 0
      
      # 優先度順にキューからリソースを取得
      resources_to_load = @preload_queue.select do |url|
        info = @resource_infos[url]?
        info && info.state == ResourceState::Loading && !info.start_time
      end
      
      # 優先度でソート
      resources_to_load.sort! do |a, b|
        info_a = @resource_infos[a]
        info_b = @resource_infos[b]
        info_a.priority.value <=> info_b.priority.value
      end
      
      # 利用可能なスロット数だけ読み込みを開始
      resources_to_load.first(available_slots).each do |url|
        start_resource_loading(url)
      end
    end
    
    # リソース読み込みの開始
    def start_resource_loading(url : String) : Bool
      return false if @url.nil?
      
      @logger.debug { "リソース読み込み開始: #{url}" }
      
      # リソース情報を取得または作成
      resource_info = @resource_infos[url]? || begin
        info = ResourceInfo.new(url, "unknown", ResourcePriority::Medium)
        @resource_infos[url] = info
        info
      end
      
      # 読み込み開始時間を記録
      resource_info.start_time = Time.utc
      
      # リソース状態を更新
      resource_info.state = ResourceState::Loading
      @resources[url] = ResourceState::Loading
      
      # プリロードキューから削除
      @preload_queue.delete(url)
      
      true
    end
    
    # リソース読み込み通知
    def resource_loaded(url : String, start_time : Time, end_time : Time) : Bool
      return false if @url.nil?
      
      @logger.debug { "リソース読み込み完了: #{url}" }
      
      # リソース情報を取得または作成
      resource_info = @resource_infos[url]? || begin
        info = ResourceInfo.new(url, "unknown", ResourcePriority::Medium)
        @resource_infos[url] = info
        info
      end
      
      # リソース状態を更新
      resource_info.state = ResourceState::Loaded
      resource_info.start_time = start_time if resource_info.start_time.nil?
      resource_info.end_time = end_time
      @resources[url] = ResourceState::Loaded
      
      # 最初のリソース読み込み時にはTTFBを記録
      if url == @url && @performance.time_to_first_byte.nil?
        @performance.set_time_to_first_byte
      end
      
      # パフォーマンスに読み込み時間を記録
      duration_ms = (end_time - start_time).total_milliseconds
      @performance.record_resource_load_time(url, duration_ms)
      
      # クリティカルリソースが読み込み完了したかチェック
      check_critical_resources_loaded
      
      # 次のプリロードを処理
      process_preload_queue
      
      # プログレッシブレンダリングの実行
      try_progressive_render
      
      # すべてのリソースが読み込み完了したかチェック
      if check_all_resources_loaded
        navigation_complete
      end
      
      true
    end
    
    # クリティカルリソースが読み込み完了したかチェック
    private def check_critical_resources_loaded : Bool
      all_critical_loaded = true
      
      @resource_infos.each do |_, info|
        if info.priority == ResourcePriority::Critical && !info.completed?
          all_critical_loaded = false
          break
        end
      end
      
      if all_critical_loaded && !@rendering_progress.critical_resources_loaded
        @rendering_progress.critical_resources_loaded = true
        try_progressive_render
      end
      
      all_critical_loaded
    end
    
    # プログレッシブレンダリングの試行
    private def try_progressive_render : Bool
      return false unless @rendering_progress.should_perform_intermediate_render?
      return false if @document.nil?
      
      @rendering_progress.is_rendering = true
      
      # 中間レンダリングのタイミング計測開始
      render_start = Time.monotonic
      
      begin
        # レイアウトエンジンにプログレッシブレンダリングフラグを設定
        @layout_engine.set_progressive_mode(true)
        
        # 部分的なレイアウト計算とレンダリング
        @layout_engine.layout(@document.not_nil!, progressive: true)
        @rendering_engine.render(@document.not_nil!, progressive: true)
        
        # レンダリングカウントを更新
        @rendering_progress.render_count += 1
        
        # 最初のコンテンツ描画としてマーク（最初のプログレッシブレンダリング時）
        if @rendering_progress.render_count == 1
          notify_first_contentful_paint
        end
        
        # レンダリング時間を記録
        render_time = (Time.monotonic - render_start).total_milliseconds
        @performance.record_paint_time(render_time)
        
        @logger.debug { "プログレッシブレンダリング実行 ##{@rendering_progress.render_count} (#{render_time.round(2)}ms)" }
        true
      rescue ex
        @logger.error { "プログレッシブレンダリング失敗: #{ex.message}" }
        false
      ensure
        @rendering_progress.is_rendering = false
      end
    end
    
    # レイアウト完了通知
    def notify_layout_complete : Nil
      @rendering_progress.layout_complete = true
      try_progressive_render
    end
    
    # リソース依存関係の追加
    def add_resource_dependency(resource_url : String, dependent_on : String) : Bool
      return false unless @resource_infos.has_key?(resource_url) && @resource_infos.has_key?(dependent_on)
      
      @resource_infos[dependent_on].dependency_of << resource_url
      true
    end
    
    # リソースサイズの設定
    def set_resource_size(url : String, size : Int64) : Bool
      return false unless @resource_infos.has_key?(url)
      
      @resource_infos[url].size = size
      true
    end
    
    # エラーの追加
    def add_error(type : ErrorType, message : String, url : String? = nil, recoverable : Bool = false) : PageError
      error = PageError.new(type, message, url, recoverable)
      @errors << error
      
      # エラーリスナーに通知
      @error_listeners.each &.call(error)
      
      error
    end
    
    # JavaScriptエラーの追加
    def add_js_error(message : String, url : String? = nil, line : Int32? = nil, column : Int32? = nil, stack : String? = nil) : PageError
      location_info = ""
      location_info += " at line #{line}" if line
      location_info += ":#{column}" if column && line
      
      full_message = "JavaScriptエラー: #{message}#{location_info}"
      full_message += "\nスタックトレース:\n#{stack}" if stack
      
      error = add_error(ErrorType::JavaScriptError, full_message, url, true)
      error
    end
    
    # すべてのリソースが読み込み完了しているかチェック
    private def check_all_resources_loaded : Bool
      return false if @resources.empty?
      
      @resources.all? do |_, state|
        state == ResourceState::Loaded || state == ResourceState::Failed
      end
    end
    
    # DOMContentLoadedイベントの発火
    def fire_dom_content_loaded : Nil
      @logger.debug { "DOMContentLoadedイベント発火" }
      
      # パフォーマンス計測を更新
      @performance.set_dom_content_loaded
      
      # インタラクティブ状態に更新
      @load_state = LoadState::Interactive
      
      # リスナーに通知
      @dom_content_loaded_listeners.each &.call
      
      # ドキュメントにDOMContentLoadedイベントを発火
      if doc = @document
        doc.dispatch_event("DOMContentLoaded", {"target" => doc})
      end
    end
    
    # Loadイベントの発火
    def fire_load_event : Nil
      @logger.debug { "Loadイベント発火" }
      
      # リスナーに通知
      @load_listeners.each &.call
      
      # ドキュメントにloadイベントを発火
      if doc = @document
        doc.dispatch_event("load", {"target" => doc})
      end
      
      # インタラクティブ時間を記録
      @performance.set_time_to_interactive
    end
    
    # 最初の描画通知
    def notify_first_paint : Nil
      @logger.debug { "最初の描画" }
      
      # パフォーマンス計測を更新
      @performance.set_first_paint
    end
    
    # 最初のコンテンツ描画通知
    def notify_first_contentful_paint : Nil
      @logger.debug { "最初のコンテンツ描画" }
      
      # パフォーマンス計測を更新
      @performance.set_first_contentful_paint
    end
    
    # タイトル変更
    def set_title(new_title : String) : Nil
      @title = new_title
      
      # リスナーに通知
      @title_change_listeners.each &.call(@title)
    end
    
    # スクロール位置の設定
    def set_scroll_position(x : Float64, y : Float64) : Nil
      @scroll_position = {x, y}
      
      # 現在の状態を更新
      @state = PageState.new(@scroll_position, @state.form_data, @state.selected_elements, @state.js_state)
      
      # ドキュメントにスクロールイベントを発火
      if doc = @document
        doc.dispatch_event("scroll", {"target" => doc})
      end
    end
    
    # スタイルシートの追加
    def add_stylesheet(stylesheet : Stylesheet) : Nil
      @stylesheets << stylesheet
    end
    
    # ページの再読み込み
    def reload(bypass_cache : Bool = false) : Bool
      return false if @url.nil?
      
      @logger.info { "ページ再読み込み: #{@url} (キャッシュバイパス: #{bypass_cache})" }
      
      # 現在のURLで新しいナビゲーションを開始
      navigation_start(@url.not_nil!, NavigationType::Reload)
    end
    
    # 履歴の前へ移動
    def go_back : Bool
      prev_entry = @history.go_back
      return false unless prev_entry
      
      @logger.info { "履歴を戻る: #{prev_entry.url}" }
      
      # 状態を復元
      @state = prev_entry.state
      
      # 前のURLで新しいナビゲーションを開始
      navigation_start(prev_entry.url, NavigationType::BackForward)
    end
    
    # 履歴の次へ移動
    def go_forward : Bool
      next_entry = @history.go_forward
      return false unless next_entry
      
      @logger.info { "履歴を進む: #{next_entry.url}" }
      
      # 状態を復元
      @state = next_entry.state
      
      # 次のURLで新しいナビゲーションを開始
      navigation_start(next_entry.url, NavigationType::BackForward)
    end
    
    # 履歴内の特定の位置へ移動
    def go(steps : Int32) : Bool
      entry = @history.go(steps)
      return false unless entry
      
      @logger.info { "履歴内移動(#{steps}): #{entry.url}" }
      
      # 状態を復元
      @state = entry.state
      
      # 指定されたURLで新しいナビゲーションを開始
      navigation_start(entry.url, NavigationType::BackForward)
    end
    
    # DOMContentLoadedイベントリスナーの追加
    def add_dom_content_loaded_listener(listener : ->) : Nil
      @dom_content_loaded_listeners << listener
    end
    
    # Loadイベントリスナーの追加
    def add_load_listener(listener : ->) : Nil
      @load_listeners << listener
    end
    
    # タイトル変更リスナーの追加
    def add_title_change_listener(listener : String ->) : Nil
      @title_change_listeners << listener
    end
    
    # エラーリスナーの追加
    def add_error_listener(listener : PageError ->) : Nil
      @error_listeners << listener
    end
    
    # パフォーマンスリスナーの追加
    def add_performance_listener(listener : PerformanceMetrics ->) : Nil
      @performance_listeners << listener
    end
    
    # ページ状態のスナップショットを保存
    def save_state : PageState
      # フォームデータの収集
      form_data = {} of String => String
      if doc = @document
        doc.query_selector_all("input, textarea, select").each do |elem|
          id = elem.get_attribute("id")
          next if id.nil? || id.empty?
          
          value = case elem.tag_name.downcase
          when "select"
            selected_option = elem.query_selector("option[selected]")
            selected_option ? selected_option.get_attribute("value") || "" : ""
          when "textarea"
            elem.text_content || ""
          else
            elem.get_attribute("value") || ""
          end
          
          form_data[id] = value
        end
      end
      
      # 選択されている要素のIDを収集
      selected_elements = [] of String
      if doc = @document
        doc.query_selector_all("[selected], [checked], :focus").each do |elem|
          id = elem.get_attribute("id")
          next if id.nil? || id.empty?
          
          selected_elements << id
        end
      end
      
      # スクロール位置の詳細な保存（ネストされたスクロール可能要素も含む）
      scroll_positions = {} of String => Tuple(Int32, Int32)
      scroll_positions["main"] = @scroll_position
      
      if doc = @document
        doc.query_selector_all("[id][style*='overflow']").each do |elem|
          id = elem.get_attribute("id")
          next if id.nil? || id.empty?
          
          # スクロール可能要素のスクロール位置を取得
          scroll_x = elem.scroll_left.to_i
          scroll_y = elem.scroll_top.to_i
          scroll_positions[id] = {scroll_x, scroll_y}
        end
      end
      
      # JavaScript状態のシリアライズ（JavaScriptエンジンによる実装が必要）
      js_state = @context.serialize_state
      
      # 新しい状態オブジェクトを作成（拡張版）
      @state = PageState.new(
        scroll_position: @scroll_position,
        scroll_positions: scroll_positions,
        form_data: form_data,
        selected_elements: selected_elements,
        js_state: js_state,
        timestamp: Time.utc
      )
    end
    
    # ページ状態の復元
    def restore_state(state : PageState) : Bool
      return false if @document.nil?
      
      @logger.info { "状態を復元: #{state.timestamp}" }
      
      # メインスクロール位置の復元
      @scroll_position = state.scroll_position
      
      # ネストされたスクロール位置の復元
      if doc = @document
        state.scroll_positions.each do |id, pos|
          next if id == "main" # メインスクロールは別途処理
          
          if elem = doc.get_element_by_id(id)
            elem.scroll_to(pos[0], pos[1])
          end
        end
      end
      
      # フォームデータの復元
      state.form_data.each do |id, value|
        if elem = @document.not_nil!.get_element_by_id(id)
          case elem.tag_name.downcase
          when "input"
            elem_type = elem.get_attribute("type")?.to_s.downcase
            
            case elem_type
            when "checkbox", "radio"
              # チェックボックスとラジオボタンは値ではなくチェック状態を設定
              if value == "true" || value == "checked"
                elem.set_attribute("checked", "true")
              else
                elem.remove_attribute("checked")
              end
            else
              # 通常の入力フィールド
              elem.set_attribute("value", value)
            end
          when "textarea"
            # テキストエリアは内容を設定
            elem.text_content = value
          when "select"
            # セレクトボックスは選択オプションを設定
            elem.query_selector_all("option").each do |option|
              option_value = option.get_attribute("value") || ""
              if option_value == value
                option.set_attribute("selected", "true")
              else
                option.remove_attribute("selected")
              end
            end
          end
        end
      end
      
      # 選択状態の復元
      state.selected_elements.each do |id|
        if elem = @document.not_nil!.get_element_by_id(id)
          elem_type = elem.get_attribute("type")?.to_s.downcase
          
          case elem.tag_name.downcase
          when "input"
            if elem_type == "checkbox" || elem_type == "radio"
              elem.set_attribute("checked", "true")
            end
          when "option"
            elem.set_attribute("selected", "true")
            
            # 親のselectエレメントも更新
            if parent = elem.parent_element
              if parent.tag_name.downcase == "select"
                # selectの値を更新するためのイベント発火
                @context.execute_script("
                  const select = document.getElementById('#{parent.get_attribute("id")}');
                  if (select) {
                    const event = new Event('change', { bubbles: true });
                    select.dispatchEvent(event);
                  }
                ")
              end
            end
          end
        end
      end
      
      # フォーカス状態の復元
      if focus_id = state.selected_elements.find { |id| @document.not_nil!.get_element_by_id(id)?.try &.matches(":focus") }
        if focus_elem = @document.not_nil!.get_element_by_id(focus_id)
          @context.execute_script("document.getElementById('#{focus_id}').focus()")
        end
      end
      
      # JavaScript状態の復元（JavaScriptエンジンによる実装が必要）
      if js_state = state.js_state
        @context.deserialize_state(js_state)
      end
      
      # 状態復元後のイベント発火
      @context.execute_script("
        document.dispatchEvent(new CustomEvent('staterestored', { 
          detail: { timestamp: '#{state.timestamp}' }
        }));
      ")
      
      # 現在の状態を更新
      @state = state
      
      true
    end
    # ページのクリーンアップ
    def cleanup : Nil
      @logger.info { "ページのクリーンアップ" }
      
      # イベントリスナーのクリア
      @dom_content_loaded_listeners.clear
      @load_listeners.clear
      @title_change_listeners.clear
      @error_listeners.clear
      @performance_listeners.clear
      
      # JavaScript実行コンテキストの破棄
      @javascript_engine.destroy_context(@context)
      
      # リソースの解放
      @resources.clear
      @resource_infos.clear
      @preload_queue.clear
      @stylesheets.clear
      @errors.clear
      
      # メモリプールのリセット
      @memory_pool.reset
      
      # ドキュメントの参照をクリア
      @document = nil
    end
    
    # ページのシリアライズ（キャッシュや状態保存のため）
    def serialize : String
      data = {
        "id" => @id,
        "url" => @url,
        "title" => @title,
        "loadState" => @load_state.to_s,
        "scrollPosition" => {
          "x" => @scroll_position[0],
          "y" => @scroll_position[1]
        },
        "state" => @state.to_json_data,
        "performance" => @performance.to_json_data
      }
      
      data.to_json
    end
    
    # シリアライズされたデータからページを復元（静的メソッド）
    def self.deserialize(
      json_string : String,
      dom_manager : DOMManager,
      javascript_engine : JavaScriptEngine,
      layout_engine : LayoutEngine,
      rendering_engine : RenderingEngine
    ) : Page
      data = JSON.parse(json_string)
      
      page = Page.new(dom_manager, javascript_engine, layout_engine, rendering_engine)
      
      # 基本情報の復元
      if id = data["id"]?.try(&.as_s?)
        page.instance_variable_set("@id", id)
      end
      
      if url = data["url"]?.try(&.as_s?)
        page.url = url
      end
      
      if title = data["title"]?.try(&.as_s?)
        page.title = title
      end
      
      if load_state_str = data["loadState"]?.try(&.as_s?)
        page.load_state = LoadState.parse(load_state_str)
      end
      
      # スクロール位置の復元
      if scroll_pos = data["scrollPosition"]?
        scroll_x = scroll_pos["x"].as_f? || 0.0
        scroll_y = scroll_pos["y"].as_f? || 0.0
        page.scroll_position = {scroll_x, scroll_y}
      end
      
      # ページ状態の復元
      if state_data = data["state"]?
        page.state = PageState.new(
          page.scroll_position,
          {} of String => String,
          [] of String,
          nil
        )
      end
      
      page
    end
    
    # サンドボックスレベルの設定
    def set_sandbox_level(level : SandboxLevel) : Nil
      @sandbox_settings = SandboxSettings.new(level)
      apply_sandbox_settings
    end
    
    # サンドボックス設定の適用
    private def apply_sandbox_settings : Nil
      return if @document.nil?
      
      doc = @document.not_nil!
      
      # HTML要素にサンドボックス属性を設定
      html_elem = doc.query_selector("html")
      if html_elem
        # CSP (Content-Security-Policy) メタタグを追加
        head_elem = doc.query_selector("head")
        if head_elem
          # 既存のCSPメタタグを削除
          existing_csp = head_elem.query_selector("meta[http-equiv='Content-Security-Policy']")
          existing_csp.try(&.remove)
          
          # 新しいCSPメタタグを追加
          csp_meta = doc.create_element("meta")
          csp_meta.set_attribute("http-equiv", "Content-Security-Policy")
          csp_meta.set_attribute("content", @sandbox_settings.to_csp_header)
          head_elem.append_child(csp_meta)
        end
      end
      
      # JavaScript実行の制限を適用
      @context.set_execution_allowed(@sandbox_settings.allow_scripts)
      
      # フォーム送信の制限を適用
      if doc.query_selector_all("form").size > 0
        unless @sandbox_settings.allow_forms
          doc.query_selector_all("form").each do |form|
            form.set_attribute("onsubmit", "return false;")
          end
        end
      end
    end
    
    # スクリーンショットの取得
    def take_screenshot(options : ScreenshotOptions = ScreenshotOptions.new) : Screenshot?
      return nil if @document.nil?
      
      @logger.info { "スクリーンショットを取得" }
      
      begin
        # レンダリングエンジンにスクリーンショット取得を依頼
        screenshot_data = @rendering_engine.capture_screenshot(
          @document.not_nil!,
          options.width,
          options.height,
          options.format,
          options.quality,
          options.full_page,
          options.element_selector
        )
        
        return nil unless screenshot_data
        
        # MIMEタイプを決定
        mime_type = case options.format.downcase
                    when "png"
                      "image/png"
                    when "jpeg", "jpg"
                      "image/jpeg"
                    when "webp"
                      "image/webp"
                    else
                      "application/octet-stream"
                    end
        
        # 幅と高さを取得
        width = options.width || @rendering_engine.viewport_width
        height = options.height || @rendering_engine.viewport_height
        
        Screenshot.new(screenshot_data, mime_type, width, height)
      rescue ex
        @logger.error { "スクリーンショット取得エラー: #{ex.message}" }
        nil
      end
    end
    
    # 特定の要素のスクリーンショットを取得
    def take_element_screenshot(selector : String, format : String = "png") : Screenshot?
      options = ScreenshotOptions.new(
        format: format,
        element_selector: selector
      )
      take_screenshot(options)
    end
    
    # フルページスクリーンショットを取得
    def take_full_page_screenshot(format : String = "png") : Screenshot?
      options = ScreenshotOptions.new(
        format: format,
        full_page: true
      )
      take_screenshot(options)
    end
    
    # 超最適化レベルの設定
    def set_optimization_level(level : OptimizationLevel) : Nil
      case level
      when OptimizationLevel::Standard
        @hyper_optimization.level = level
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Moderate
        @hyper_optimization.rendering_profile = RenderingProfile::Standard
      when OptimizationLevel::Aggressive
        @hyper_optimization.level = level
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Aggressive
        @hyper_optimization.rendering_profile = RenderingProfile::HighFPS
      when OptimizationLevel::MaxMemory
        @hyper_optimization.level = level
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Conservative
        @hyper_optimization.rendering_profile = RenderingProfile::PowerSaving
        @hyper_optimization.compressed_dom = true
      when OptimizationLevel::MaxSpeed
        @hyper_optimization.level = level
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Aggressive
        @hyper_optimization.rendering_profile = RenderingProfile::UltraSmooth
        @hyper_optimization.speculative_jit_enabled = true
      when OptimizationLevel::Balanced
        @hyper_optimization.level = level
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Moderate
        @hyper_optimization.rendering_profile = RenderingProfile::Standard
      when OptimizationLevel::Adaptive
        @hyper_optimization.level = level
        # 適応モードでは状況に応じて設定が変化
        adapt_optimization_to_content
      end
      
      # 設定に応じてエンジンを構成
      apply_optimization_settings
    end
    
    # 最適化設定の適用
    private def apply_optimization_settings : Nil
      # レイアウトエンジンに設定を適用
      @layout_engine.set_optimization_level(@hyper_optimization.level.to_i)
      @layout_engine.set_threading(@hyper_optimization.parallel_config.layout_threads)
      @layout_engine.set_layout_recycling(@hyper_optimization.layout_recycling)
      
      # レンダリングエンジンに設定を適用
      @rendering_engine.set_zero_copy(@hyper_optimization.zero_copy_rendering)
      @rendering_engine.set_threading(@hyper_optimization.parallel_config.rendering_threads)
      
      case @hyper_optimization.rendering_profile
      when RenderingProfile::HighFPS
        @rendering_engine.set_target_fps(90)
      when RenderingProfile::PowerSaving
        @rendering_engine.set_target_fps(30)
      when RenderingProfile::UltraSmooth
        @rendering_engine.set_target_fps(120)
      when RenderingProfile::MinimalFlash
        @rendering_engine.set_content_change_threshold(0.05)
      else
        @rendering_engine.set_target_fps(60)
      end
      
      # DOMマネージャに設定を適用
      @dom_manager.set_compressed_mode(@hyper_optimization.compressed_dom)
      @dom_manager.set_threading(@hyper_optimization.parallel_config.parsing_threads)
      
      # JavaScriptエンジンに設定を適用
      @javascript_engine.set_jit_mode(@hyper_optimization.speculative_jit_enabled)
      
      # 先読みエンジンに設定を適用
      @prefetch_engine.strategy = @hyper_optimization.prefetch_strategy
    end
    
    # コンテンツに基づいて最適化を調整
    private def adapt_optimization_to_content : Nil
      return if @document.nil? || !@content_analysis.analyzed?
      
      # コンテンツの複雑さに基づいて調整
      if @content_analysis.content_complexity > 0.8
        # 複雑なコンテンツの場合はメモリ使用量を最適化
        @hyper_optimization.rendering_profile = RenderingProfile::Standard
        @hyper_optimization.compressed_dom = true
        @hyper_optimization.speculative_jit_enabled = false if @content_analysis.content_complexity > 0.95
      elsif @content_analysis.content_complexity < 0.3
        # シンプルなコンテンツの場合は速度重視
        @hyper_optimization.rendering_profile = RenderingProfile::UltraSmooth
        @hyper_optimization.compressed_dom = false
        @hyper_optimization.speculative_jit_enabled = true
      end
      
      # アニメーション複雑さに基づいて調整
      if @content_analysis.animation_complexity > 0.7
        @hyper_optimization.rendering_profile = RenderingProfile::HighFPS
      elsif @content_analysis.animation_complexity < 0.2
        @hyper_optimization.rendering_profile = RenderingProfile::PowerSaving
      end
      
      # インタラクティブ要素数に基づいて調整
      if @content_analysis.interactive_elements_count > 50
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Aggressive
      elsif @content_analysis.interactive_elements_count < 10
        @hyper_optimization.prefetch_strategy = PrefetchStrategy::Conservative
      end
    end
    
    # ドキュメントコンテンツの分析
    private def analyze_content : Nil
      return if @document.nil?
      
      @content_analysis = ContentAnalysis.new
      doc = @document.not_nil!
      
      # 並列タスクとしてコンテンツ分析を実行
      @parallel_engine.schedule(->do
        # インタラクティブ要素のカウント
        @content_analysis.interactive_elements_count = doc.query_selector_all("a, button, input, select, textarea").size
        
        # アニメーション複雑さの計算
        animation_elements = doc.query_selector_all("video, canvas, [style*='animation'], [class*='animate']").size
        @content_analysis.animation_complexity = {animation_elements / 10.0, 1.0}.min
        
        # テキスト/メディア比の計算
        text_content = doc.body ? doc.body.not_nil!.text_content.size : 0
        media_elements = doc.query_selector_all("img, video, canvas, svg").size
        @content_analysis.text_to_media_ratio = media_elements > 0 ? text_content / (media_elements * 1000.0) : 10.0
        
        # コンテンツの複雑さを推定
        dom_size = doc.query_selector_all("*").size
        style_complexity = doc.query_selector_all("[style]").size
        js_complexity = doc.query_selector_all("script").size
        
        # 複雑さスコアの計算（0.0-1.0のスケール）
        @content_analysis.content_complexity = {
          (dom_size / 1000.0 + style_complexity / 100.0 + js_complexity / 10.0) / 3.0,
          1.0
        }.min
        
        # 重要な要素の特定
        doc.query_selector_all("h1, h2, nav, header, main, [role='main']").each do |elem|
          id = elem.get_attribute("id") || "quantum-critical-#{Random.rand(10000)}"
          @content_analysis.critical_elements << id
        end
        
        # コンテンツカテゴリの推定
        if doc.query_selector_all("article, .post, .blog").size > 0
          @content_analysis.content_category = "article"
        elsif doc.query_selector_all("form, input[type='submit']").size > 0
          @content_analysis.content_category = "form"
        elsif doc.query_selector_all("table, th, td").size > (dom_size * 0.1)
          @content_analysis.content_category = "data"
        elsif doc.query_selector_all("product, .product, .item, [itemtype*='Product']").size > 0
          @content_analysis.content_category = "ecommerce"
        else
          @content_analysis.content_category = "general"
        end
        
        # 最適化設定に分析結果を反映
        if @hyper_optimization.level == OptimizationLevel::Adaptive
          adapt_optimization_to_content
        end
      end)
      
      # 先読みエンジンにドキュメントを解析させる
      @prefetch_engine.analyze_document(doc)
    end
    
    # リソース読み込みの最適化
    def optimize_resource_loading : Nil
      # 先読みキューから次のURLを取得して読み込みをスケジュール
      if @prefetch_engine.strategy != PrefetchStrategy::None
        while prefetch_url = @prefetch_engine.next_prefetch_url
          # リソースタイプを推測
          resource_type = guess_resource_type(prefetch_url)
          
          # 低優先度でプリロードをスケジュール
          schedule_preload(prefetch_url, resource_type, "prefetch")
          
          # 最大5つまでプリフェッチを行う（バッチ処理）
          break if @prefetch_engine.prefetched_urls.size >= 5
        end
      end
      
      # クリティカルリソースの処理を優先
      process_preload_queue(
        max_concurrent: @hyper_optimization.parallel_config.max_workers * 2
      )
    end
    
    # URLからリソースタイプを推測
    private def guess_resource_type(url : String) : String
      # 拡張子に基づいてリソースタイプを推測
      extension = File.extname(url).downcase
      
      case extension
      when ".html", ".htm"
        "text/html"
      when ".css"
        "text/css"
      when ".js"
        "application/javascript"
      when ".jpg", ".jpeg"
        "image/jpeg"
      when ".png"
        "image/png"
      when ".svg"
        "image/svg+xml"
      when ".webp"
        "image/webp"
      when ".gif"
        "image/gif"
      when ".webm"
        "video/webm"
      when ".mp4"
        "video/mp4"
      when ".woff", ".woff2"
        "font/#{extension[1..]}"
      when ".json"
        "application/json"
      else
        "application/octet-stream"
      end
    end
    
    # ナフォーマンスイベントのトラッキングを強化
    def track_performance_event(event_name : String, duration_ms : Float64) : Nil
      @logger.debug { "パフォーマンスイベント: #{event_name} (#{duration_ms.round(2)}ms)" }
      
      case event_name
      when "layout"
        @performance.record_layout_time(duration_ms)
      when "paint"
        @performance.record_paint_time(duration_ms)
      when "script"
        @performance.record_js_execution_time(duration_ms)
      end
    end
  end
  
  # 履歴エントリ
  class HistoryEntry
    getter url : String
    getter state : Page::PageState
    getter timestamp : Time
    
    def initialize(@url : String, @state : Page::PageState)
      @timestamp = Time.utc
    end
  end
  
  # 履歴管理クラス
  class History
    getter entries : Array(HistoryEntry)
    getter current_index : Int32
    
    def initialize
      @entries = [] of HistoryEntry
      @current_index = -1
    end
    
    # エントリの追加
    def add_entry(url : String, state : Page::PageState) : HistoryEntry
      # 現在位置以降のエントリを削除
      if @current_index < @entries.size - 1
        @entries = @entries[0..@current_index]
      end
      
      entry = HistoryEntry.new(url, state)
      @entries << entry
      @current_index = @entries.size - 1
      
      entry
    end
    
    # 現在のエントリの置き換え
    def replace_entry(url : String, state : Page::PageState) : HistoryEntry?
      return nil if @entries.empty?
      
      entry = HistoryEntry.new(url, state)
      @entries[@current_index] = entry
      
      entry
    end
    
    # 後方に移動
    def go_back : HistoryEntry?
      return nil if @current_index <= 0
      
      @current_index -= 1
      @entries[@current_index]
    end
    
    # 前方に移動
    def go_forward : HistoryEntry?
      return nil if @current_index >= @entries.size - 1
      
      @current_index += 1
      @entries[@current_index]
    end
    
    # 特定のステップ数移動
    def go(steps : Int32) : HistoryEntry?
      new_index = @current_index + steps
      
      return nil if new_index < 0 || new_index >= @entries.size
      
      @current_index = new_index
      @entries[@current_index]
    end
    
    # 現在のエントリを取得
    def current_entry : HistoryEntry?
      return nil if @current_index < 0 || @entries.empty?
      
      @entries[@current_index]
    end
    
    # 戻れるかどうか
    def can_go_back? : Bool
      @current_index > 0
    end
    
    # 進めるかどうか
    def can_go_forward? : Bool
      @current_index < @entries.size - 1
    end
    
    # 履歴の長さ
    def length : Int32
      @entries.size
    end
    
    # 履歴のクリア
    def clear : Nil
      @entries.clear
      @current_index = -1
    end
  end
  
  # リソースプールクラス（メモリ管理用）
  class ResourcePool
    getter allocated_size : UInt64
    
    def initialize
      @resources = {} of String => Bytes
      @allocated_size = 0_u64
    end
    
    # リソースの割り当て
    def allocate_resource(key : String, size : UInt64) : Bytes?
      return @resources[key]? if @resources.has_key?(key)
      
      begin
        buffer = Bytes.new(size)
        @resources[key] = buffer
        @allocated_size += size
        buffer
      rescue ex
        nil
      end
    end
    
    # リソースの解放
    def release_resource(key : String) : Bool
      if @resources.has_key?(key)
        size = @resources[key].size.to_u64
        @resources.delete(key)
        @allocated_size -= size
        true
      else
        false
      end
    end
    
    # 特定のサイズ以上のリソースを解放
    def release_resources_larger_than(threshold_size : UInt64) : Int32
      count = 0
      
      @resources.each do |key, buffer|
        if buffer.size >= threshold_size
          @allocated_size -= buffer.size.to_u64
          @resources.delete(key)
          count += 1
        end
      end
      
      count
    end
    
    # プールのリセット
    def reset : Nil
      @resources.clear
      @allocated_size = 0_u64
    end
  end
end 