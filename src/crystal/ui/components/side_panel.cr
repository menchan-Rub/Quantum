# src/crystal/ui/components/side_panel.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"
require "../../utils/animation"
require "../../utils/search_utility"
require "../../quantum_core/performance"

module QuantumUI
  # サイドパネルコンポーネント (ブックマーク、履歴等を表示)
  # ブラウザの左側に表示されるパネルで、ブックマーク、履歴、ダウンロード等の管理を行う
  # @since 1.0.0
  # @author QuantumTeam
  class SidePanel < Component
    # 表示モード
    enum PanelMode
      BOOKMARKS  # ブックマーク管理
      HISTORY    # 閲覧履歴
      DOWNLOADS  # ダウンロード管理
      EXTENSIONS # 拡張機能管理
      NOTES      # メモ帳機能
      DEVELOPER  # 開発者ツール
      SETTINGS   # パネル設定
      
      # モード名を取得
      def to_display_name : String
        case self
        when BOOKMARKS
          "ブックマーク"
        when HISTORY
          "閲覧履歴" 
        when DOWNLOADS
          "ダウンロード"
        when EXTENSIONS
          "拡張機能"
        when NOTES
          "メモ帳"
        when DEVELOPER
          "開発者ツール"
        when SETTINGS
          "設定"
        else
          "不明"
        end
      end
      
      # アイコンを取得
      def to_icon : String
        case self
        when BOOKMARKS
          "🔖"
        when HISTORY
          "🕒"
        when DOWNLOADS
          "📥"
        when EXTENSIONS
          "🧩"
        when NOTES
          "📝"
        when DEVELOPER
          "🔧"
        when SETTINGS
          "⚙️"
        else
          "❓"
        end
      end
      
      # テーマカラーを取得
      def to_color : UInt32
        case self
        when BOOKMARKS
          0x4C_AF_50  # 緑系
        when HISTORY
          0x21_96_F3  # 青系
        when DOWNLOADS
          0x9C_27_B0  # 紫系
        when EXTENSIONS
          0xFF_98_00  # オレンジ系
        when NOTES
          0xFF_C1_07  # 黄色系
        when DEVELOPER
          0x60_7D_8B  # グレー系
        when SETTINGS
          0x78_90_9C  # 青グレー系
        else
          0x90_90_90  # デフォルトグレー
        end
      end
      
      # 説明文を取得
      def to_description : String
        case self
        when BOOKMARKS
          "ブックマークの管理、整理、検索ができます"
        when HISTORY
          "閲覧履歴の表示、検索、削除ができます"
        when DOWNLOADS
          "ダウンロードファイルの管理と表示ができます"
        when EXTENSIONS
          "拡張機能の管理と設定ができます"
        when NOTES
          "ウェブページに関するメモを作成・管理できます"
        when DEVELOPER
          "開発者向けツールとデバッグ機能を提供します"
        when SETTINGS
          "パネルの設定と表示オプションを変更できます"
        else
          "詳細情報がありません"
        end
      end
    end
    
    # タブアニメーション状態を管理する構造体
    private struct TabAnimationState
      property hover_state : Float64 # ホバーアニメーション状態 (0.0-1.0)
      property bounce_state : Float64 # バウンスアニメーション状態 (0.0-1.0)
      property animation_active : Bool # アニメーション実行中フラグ
      property last_update : Time # 最終更新時間
      property color_shift : Float64 # 色変化アニメーション (0.0-1.0)
      property glow_effect : Float64 # 光るエフェクト (0.0-1.0)
      
      def initialize
        @hover_state = 0.0
        @bounce_state = 0.0
        @animation_active = false
        @last_update = Time.monotonic
        @color_shift = 0.0
        @glow_effect = 0.0
      end
      
      # アニメーションを更新
      def update(delta_time : Float64, is_hover : Bool) : Bool
        needs_update = false
        
        # ホバー状態の更新
        target_hover = is_hover ? 1.0 : 0.0
        if @hover_state != target_hover
          if is_hover
            @hover_state = Math.min(1.0, @hover_state + delta_time * 5)
          else
            @hover_state = Math.max(0.0, @hover_state - delta_time * 5)
          end
          needs_update = true
        end
        
        # バウンスアニメーションの更新
        if @bounce_state > 0
          @bounce_state = Math.max(0.0, @bounce_state - delta_time * 4)
          needs_update = true
        end
        
        # 色変化とグローエフェクトの更新
        if is_hover || @bounce_state > 0
          @color_shift = (Math.sin(Time.monotonic.to_unix_ms / 1000.0 * 2) + 1) / 2
          @glow_effect = @bounce_state * 0.8 + @hover_state * 0.2
          needs_update = true
        end
        
        @last_update = Time.monotonic
        @animation_active = needs_update
        needs_update
      end
    end
    
# src/crystal/ui/components/side_panel.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"
require "../../utils/animation"
require "../../utils/search_utility"
require "../../quantum_core/performance"

module QuantumUI
  # サイドパネルコンポーネント (ブックマーク、履歴等を表示)
  # ブラウザの左側に表示されるパネルで、ブックマーク、履歴、ダウンロード等の管理を行う
  # @since 1.0.0
  # @author QuantumTeam
  class SidePanel < Component
    # 表示モード
    enum PanelMode
      BOOKMARKS  # ブックマーク管理
      HISTORY    # 閲覧履歴
      DOWNLOADS  # ダウンロード管理
      EXTENSIONS # 拡張機能管理
      NOTES      # メモ帳機能
      DEVELOPER  # 開発者ツール
      SETTINGS   # パネル設定
      
      # モード名を取得
      def to_display_name : String
        case self
        when BOOKMARKS
          "ブックマーク"
        when HISTORY
          "閲覧履歴" 
        when DOWNLOADS
          "ダウンロード"
        when EXTENSIONS
          "拡張機能"
        when NOTES
          "メモ帳"
        when DEVELOPER
          "開発者ツール"
        when SETTINGS
          "設定"
        else
          "不明"
        end
      end
      
      # アイコンを取得
      def to_icon : String
        case self
        when BOOKMARKS
          "🔖"
        when HISTORY
          "🕒"
        when DOWNLOADS
          "📥"
        when EXTENSIONS
          "🧩"
        when NOTES
          "📝"
        when DEVELOPER
          "🔧"
        when SETTINGS
          "⚙️"
        else
          "❓"
        end
      end
      
      # テーマカラーを取得
      def to_color : UInt32
        case self
        when BOOKMARKS
          0x4C_AF_50  # 緑系
        when HISTORY
          0x21_96_F3  # 青系
        when DOWNLOADS
          0x9C_27_B0  # 紫系
        when EXTENSIONS
          0xFF_98_00  # オレンジ系
        when NOTES
          0xFF_C1_07  # 黄色系
        when DEVELOPER
          0x60_7D_8B  # グレー系
        when SETTINGS
          0x78_90_9C  # 青グレー系
        else
          0x90_90_90  # デフォルトグレー
        end
      end
      
      # 説明文を取得
      def to_description : String
        case self
        when BOOKMARKS
          "ブックマークの管理、整理、検索ができます"
        when HISTORY
          "閲覧履歴の表示、検索、削除ができます"
        when DOWNLOADS
          "ダウンロードファイルの管理と表示ができます"
        when EXTENSIONS
          "拡張機能の管理と設定ができます"
        when NOTES
          "ウェブページに関するメモを作成・管理できます"
        when DEVELOPER
          "開発者向けツールとデバッグ機能を提供します"
        when SETTINGS
          "パネルの設定と表示オプションを変更できます"
        else
          "詳細情報がありません"
        end
      end
    end
    
    # タブアニメーション状態を管理する構造体
    private struct TabAnimationState
      property hover_state : Float64 # ホバーアニメーション状態 (0.0-1.0)
      property bounce_state : Float64 # バウンスアニメーション状態 (0.0-1.0)
      property animation_active : Bool # アニメーション実行中フラグ
      property last_update : Time # 最終更新時間
      property color_shift : Float64 # 色変化アニメーション (0.0-1.0)
      property glow_effect : Float64 # 光るエフェクト (0.0-1.0)
      
      def initialize
        @hover_state = 0.0
        @bounce_state = 0.0
        @animation_active = false
        @last_update = Time.monotonic
        @color_shift = 0.0
        @glow_effect = 0.0
      end
      
      # アニメーションを更新
      def update(delta_time : Float64, is_hover : Bool) : Bool
        needs_update = false
        
        # ホバー状態の更新
        target_hover = is_hover ? 1.0 : 0.0
        if @hover_state != target_hover
          if is_hover
            @hover_state = Math.min(1.0, @hover_state + delta_time * 5)
          else
            @hover_state = Math.max(0.0, @hover_state - delta_time * 5)
          end
          needs_update = true
        end
        
        # バウンスアニメーションの更新
        if @bounce_state > 0
          @bounce_state = Math.max(0.0, @bounce_state - delta_time * 4)
          needs_update = true
        end
        
        # 色変化とグローエフェクトの更新
        if is_hover || @bounce_state > 0
          @color_shift = (Math.sin(Time.monotonic.to_unix_ms / 1000.0 * 2) + 1) / 2
          @glow_effect = @bounce_state * 0.8 + @hover_state * 0.2
          needs_update = true
        end
        
        @last_update = Time.monotonic
        @animation_active = needs_update
        needs_update
      end
    end
    
    # レンダリングキャッシュ管理用構造体
    private struct CacheEntry
      property texture : Concave::Texture # キャッシュテクスチャ
      property created_at : Time # 作成時間
      property last_used : Time # 最終使用時間
      property hit_count : Int32 # ヒット回数
      property size : Int32 # メモリサイズ (バイト)
      property key : String # キャッシュキー
      
      def initialize(@texture, @size, @key)
        @created_at = Time.monotonic
        @last_used = @created_at
        @hit_count = 0
      end
      
      # キャッシュヒット時に呼び出し
      def hit
        @hit_count += 1
        @last_used = Time.monotonic
      end
      
      # エントリの有効期限チェック
      def expired?(ttl_seconds : Float64, usage_weight : Bool = true) : Bool
        # 使用頻度による有効期限の調整
        effective_ttl = if usage_weight
                         # 使用頻度が高いほど有効期限を延長
                         weight = Math.min(0.8, @hit_count / 100.0)
                         ttl_seconds * (1.0 + weight)
                       else
                         ttl_seconds
                       end
        
        # 最終使用時間からの経過時間をチェック
        (Time.monotonic - @last_used).total_seconds > effective_ttl
      end
      
      # キャッシュエントリの重要度スコア（キャッシュクリーンアップ用）
      def importance_score : Float64
        # 最近使用されたか、使用頻度が高いキャッシュは残す
        recency = 1.0 / Math.max(1.0, (Time.monotonic - @last_used).total_seconds)
        frequency = Math.log(@hit_count + 1)
        size_factor = 1.0 / Math.max(1.0, @size / 1_000_000.0) # サイズが大きいほど重要度低下
        
        recency * 0.5 + frequency * 0.3 + size_factor * 0.2
      end
    end
    
    # パフォーマンス統計用構造体
    private struct RenderStats
      property render_time : Float64 # 描画時間（ミリ秒）
      property cache_hits : Int32 # キャッシュヒット数
      property cache_misses : Int32 # キャッシュミス数
      property total_renders : Int32 # 合計描画回数
      property last_update : Time # 最終更新時間
      property animation_fps : Float64 # アニメーションFPS
      property frame_times : Array(Float64) # 直近のフレーム時間
      property memory_usage : Int64 # キャッシュメモリ使用量
      property texture_count : Int32 # テクスチャ数
      property last_gc_time : Time # 最後のガベージコレクション時間
      property gc_count : Int32 # ガベージコレクション実行回数
      
      def initialize
        @render_time = 0.0
        @cache_hits = 0
        @cache_misses = 0
        @total_renders = 0
        @last_update = Time.monotonic
        @animation_fps = 0.0
        @frame_times = [] of Float64
        @memory_usage = 0_i64
        @texture_count = 0
        @last_gc_time = Time.monotonic
        @gc_count = 0
      end
      
      # フレーム時間を記録（直近10フレーム）
      def record_frame_time(time_ms : Float64)
        @frame_times << time_ms
        if @frame_times.size > 10
          @frame_times.shift
        end
        
        # FPS計算更新
        if @frame_times.size > 0
          avg_frame_time = @frame_times.sum / @frame_times.size
          @animation_fps = avg_frame_time > 0 ? 1000.0 / avg_frame_time : 0.0
        end
      end
      
      # キャッシュヒット率を計算
      def cache_hit_ratio : Float64
        total = @cache_hits + @cache_misses
        total > 0 ? (@cache_hits.to_f / total) : 0.0
      end
      
      # GC間隔を計算（秒）
      def gc_interval : Float64
        (Time.monotonic - @last_gc_time).total_seconds
      end
      
      # 1秒あたりの描画回数
      def renders_per_second : Float64
        last_second_frames = @frame_times.count { |time| time < 1000.0 }
        last_second_frames.to_f
      end
      
      # パフォーマンス評価（0.0-1.0）
      def performance_score : Float64
        factors = [] of Float64
        
        # キャッシュヒット率
        factors << cache_hit_ratio
        
        # FPSの理想値（60fps）との比率
        fps_ratio = Math.min(1.0, @animation_fps / 60.0)
        factors << fps_ratio
        
        # 描画時間の逆比例（16ms以下が理想）
        avg_render_time = @frame_times.empty? ? @render_time : @frame_times.sum / @frame_times.size
        render_time_factor = Math.min(1.0, 16.0 / Math.max(1.0, avg_render_time))
        factors << render_time_factor
        
        # 合計
        factors.sum / factors.size
      end
      
      # パフォーマンスレベルを取得
      def performance_level : Symbol
        score = performance_score
        
        if score > 0.9
          :excellent
        elsif score > 0.75
          :good
        elsif score > 0.5
          :fair
        else
          :poor
        end
      end
      
      # 統計情報をリセット
      def reset
        @cache_hits = 0
        @cache_misses = 0
        @total_renders = 0
        @frame_times.clear
        @animation_fps = 0.0
        @memory_usage = 0_i64
        @texture_count = 0
      end
      
      # ガベージコレクション実行を記録
      def record_gc
        @last_gc_time = Time.monotonic
        @gc_count += 1
      end
    end

    getter width : Int32
    getter current_mode : PanelMode
    getter visible : Bool
    
    # UI構成要素
    @sub_components : Hash(PanelMode, Component) # 各モードの表示コンポーネント
    @content_scroll_position : Hash(PanelMode, Int32) = {} of PanelMode => Int32 # 各モードのスクロール位置
    @search_results_component : SearchResultsComponent? # 検索結果表示用コンポーネント
    @scrollbar_hover : Bool = false # スクロールバーのホバー状態
    
    # レンダリングキャッシュ
    @render_cache : Hash(String, CacheEntry) # レンダリングキャッシュ（キーベース）
    @tab_render_cache : CacheEntry? # タブ部分のレンダリングキャッシュ
    @header_render_cache : CacheEntry? # ヘッダー部分のレンダリングキャッシュ
    @search_bar_cache : CacheEntry? # 検索バー部分のキャッシュ
    @content_cache : Hash(PanelMode, CacheEntry) # コンテンツ部分のキャッシュ
    @last_panel_size : Int32 = 0 # 前回のパネルサイズ（キャッシュ更新判定用）
    @last_header_width : Int32 = 0 # 前回のヘッダー幅
    @cache_needs_update : Bool = true
    @tab_cache_needs_update : Bool = true
    @header_cache_needs_update : Bool = true
    @search_bar_cache_needs_update : Bool = true
    @max_cache_memory : Int64 = 50_000_000 # 最大キャッシュメモリ（約50MB）
    @cache_ttl : Float64 = 5.0 # キャッシュの有効期限（秒）
    @adaptive_cache_ttl : Bool = true # 使用頻度に応じてTTLを調整
    @cache_key : String = "" # 現在のキャッシュキー
    
    # サイズと位置
    @min_width : Int32
    @max_width : Int32
    @saved_width : Int32 # 非表示→表示時に元のサイズに戻すために保存
    @tab_height : Int32 = 36
    @header_height : Int32 = 36
    @search_bar_height : Int32 = 36
    @content_padding : Int32 = 12
    @last_size : Tuple(Int32, Int32) = {0, 0} # 前回のサイズ
    
    # ドラッグとリサイズ
    @drag_resize_active : Bool = false
    @drag_start_x : Int32 = 0
    @start_width : Int32 = 0
    @resize_hover : Bool = false
    @resize_handle_width : Int32 = 4
    @resize_handle_hover_width : Int32 = 8
    
    # アニメーション
    @panel_animation : Animation::Animator # パネル全体のアニメーション
    @tab_animations : Hash(Int32, TabAnimationState) = {} of Int32 => TabAnimationState # タブのアニメーション状態
    @hover_tab_index : Int32 = -1
    @last_hover_tab_index : Int32 = -1
    @active_tab_animation : Animation::Animator? # 現在アクティブなタブのアニメーション
    @animation_state : Float64 = 0.0 # アニメーション状態 (0.0-1.0)
    @animation_easing : Animation::EasingFunctions::EasingFunction
    @ripple_animations : Array(Tuple(Int32, Int32, Float64, UInt32)) = [] of Tuple(Int32, Int32, Float64, UInt32) # x, y, progress, color
    @background_animation_offset : Float64 = 0.0 # 背景アニメーションのオフセット
    @last_animation_update : Time = Time.monotonic # 最後のアニメーション更新時間
    @animation_quality : Symbol = :high # アニメーション品質設定（:low, :medium, :high）
    @animation_paused : Bool = false # アニメーション一時停止フラグ
    @animation_frame : Int32 = 0 # アニメーションフレームカウンター
    @animation_active : Bool = false # 何らかのアニメーションがアクティブかどうか
    
    # 検索機能
    @search_active : Bool = false
    @search_focused : Bool = false
    @search_text : String = ""
    @search_results : Hash(PanelMode, Array(SearchUtility::SearchResult)) = {} of PanelMode => Array(SearchUtility::SearchResult)
    @search_filter_mode : Symbol = :all # :all, :current_mode, :custom
    @search_result_count : Int32 = 0
    @last_search_text : String = ""
    @search_placeholder : String = "検索..."
    @recent_searches : Array(String) = [] of String
    @search_suggestions : Array(String) = [] of String
    @search_history_visible : Bool = false
    @search_index : SearchUtility::SearchIndex = SearchUtility::SearchIndex.new # 高速検索インデックス
    @search_highlight_elements : Array(Tuple(Int32, Int32, Int32, Int32)) = [] of Tuple(Int32, Int32, Int32, Int32) # 検索ハイライト要素
    
    # テーマとスタイル
    @theme_radius : Int32
    @panel_title : String
    @use_blur_effect : Bool # 背景ぼかし効果を使用するか
    @blur_strength : Float64 = 5.0 # ぼかし強度
    @use_shadows : Bool # 影効果を使用するか
    @shadow_offset : Int32 = 2 # 影のオフセット
    @shadow_blur : Float64 = 3.0 # 影のぼかし
    @tab_radius : Int32 = 4 # タブの角丸半径
    @theme_transition : Animation::Animator? # テーマ切替アニメーション
    @old_theme_colors : NamedTuple(primary: UInt32, secondary: UInt32, accent: UInt32)? # 前回のテーマ色
    
    # ツールチップ
    @tooltip_text : String = ""
    @tooltip_position : Tuple(Int32, Int32) = {0, 0}
    @tooltip_visible : Bool = false
    @tooltip_animation : Float64 = 0.0 # ツールチップ表示アニメーション (0.0-1.0)
    @tooltip_delay_timer : Float64 = 0.0 # ツールチップ表示遅延タイマー
    
    # パフォーマンス測定
    @performance_metrics : QuantumCore::PerformanceMetrics
    @render_stats : RenderStats # 描画統計情報
    @adaptive_performance : Bool = true # 自動パフォーマンス調整
    @debug_overlay_visible : Bool = false # デバッグ情報表示
    @fps_limit : Int32 = 60 # 最大FPS制限
    @min_frame_time : Float64 = 1.0 / 60.0 # 最小フレーム時間（秒）

    # レンダリングのキャッシュを管理するための変数
    @render_cache : Hash(String, CachedRender) = {} of String => CachedRender
    @last_render_time : Time = Time.monotonic
    @render_fps_tracker : Array(Float64) = [] of Float64
    @last_update_metrics_time : Time = Time.monotonic
    @frame_count : Int32 = 0
    @render_metrics : RenderMetrics = RenderMetrics.new

    # レンダリングキャッシュを管理するための構造体
    private record CachedRender,
      surface : Cairo::Surface,
      timestamp : Time,
      mode : PanelMode,
      width : Float64,
      height : Float64,
      scroll_position : Float64

    # レンダリングメトリクスを追跡するための構造体
    private record RenderMetrics,
      cache_hits : Int32 = 0,
      cache_misses : Int32 = 0,
      render_time_total : Float64 = 0.0,
      render_count : Int32 = 0

    # スマートスクロール処理のための変数
    @scroll_momentum : Float64 = 0.0
    @scroll_target : Float64 = 0.0
    @last_scroll_time : Time = Time.monotonic
    @scroll_animation_active : Bool = false
    @scroll_animation_start_time : Time = Time.monotonic
    @scroll_animation_start_position : Float64 = 0.0
    @scroll_animation_target : Float64 = 0.0
    @scroll_animation_duration : Float64 = 0.3 # 秒
    @scroll_bar_hover : Bool = false
    @scroll_bar_dragging : Bool = false
    @scroll_bar_drag_start_y : Float64 = 0.0
    @scroll_bar_drag_start_position : Float64 = 0.0

    # @param config UI設定
    # @param core コアエンジン
    # @param theme テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @visible = @config.side_panel_visible_by_default? || false
      @width = @config.side_panel_width? || 280
      @saved_width = @width
      @current_mode = PanelMode::BOOKMARKS
      @min_width = @config.side_panel_min_width? || 180
      @max_width = @config.side_panel_max_width? || 500
      @sub_components = init_sub_components
      @render_cache = {} of String => CacheEntry
      @content_cache = {} of PanelMode => CacheEntry
      @theme_radius = (@theme.font_size * 0.3).to_i
      @panel_title = @current_mode.to_display_name
      @performance_metrics = QuantumCore::PerformanceMetrics.new
      @render_stats = RenderStats.new
      
      # 視覚効果の設定
      @use_blur_effect = @config.use_blur_effects? || false
      @use_shadows = @config.use_shadow_effects? || true
      
      # アニメーション初期化
      @animation_easing = Animation::EasingFunctions::CubicEaseInOut.new
      @panel_animation = Animation::Animator.new(
        duration: 0.25,
        easing: @animation_easing
      )
      
      # FPS制限設定
      if refresh_rate = @config.target_refresh_rate?
        @fps_limit = refresh_rate
        @min_frame_time = 1.0 / refresh_rate
      end
      
      # アニメーション品質設定
      set_animation_quality(@config.animation_quality || :high)
      
      # 初期状態
      init_tab_animations
      setup_event_listeners
      
      # パフォーマンス測定の開始
      @performance_metrics.start_tracking("side_panel")
      
      Log.info "サイドパネルを初期化しました (表示状態: #{@visible}, 幅: #{@width}px)"
    end

    # アニメーション品質を設定
    private def set_animation_quality(quality : Symbol)
      @animation_quality = quality
      
      case quality
      when :low
        # 低品質設定
        @cache_ttl = 10.0
        @adaptive_cache_ttl = false
        @max_cache_memory = 20_000_000 # 20MB
        @use_blur_effect = false
        @use_shadows = false
      when :medium
        # 中品質設定
        @cache_ttl = 7.0
        @adaptive_cache_ttl = true
        @max_cache_memory = 35_000_000 # 35MB
        @use_blur_effect = false
        @use_shadows = true
      when :high
        # 高品質設定
        @cache_ttl = 5.0
        @adaptive_cache_ttl = true
        @max_cache_memory = 50_000_000 # 50MB
        @use_blur_effect = @config.use_blur_effects? || false
        @use_shadows = @config.use_shadow_effects? || true
      end
      
      # キャッシュを更新
      invalidate_all_caches
      
      # バージョン情報とともにログ出力
      Log.info "アニメーション品質を設定: #{quality} (Concave v#{Concave::VERSION})"
    end

    # タブアニメーション状態を初期化
    private def init_tab_animations
      PanelMode.values.size.times do |i|
        @tab_animations[i] = TabAnimationState.new
      end
    end

    # サブコンポーネントを初期化
    private def init_sub_components : Hash(PanelMode, Component)
      components = {} of PanelMode => Component
      
      # サブコンポーネントの初期化開始ログ
      Log.debug "サイドパネルのサブコンポーネントを初期化します"
      
      # 各モードのコンポーネントを生成
      PanelMode.values.each do |mode|
        # 開発者モードは開発中のみ表示
        next if mode == PanelMode::DEVELOPER && !@config.debug_mode?
        
        # 各モードに対応するコンポーネントを生成
        component = case mode
                    when PanelMode::BOOKMARKS
                      BookmarksPanel.new(@core, @theme)
                    when PanelMode::HISTORY
                      HistoryPanel.new(@core, @theme)
                    when PanelMode::DOWNLOADS
                      DownloadsPanel.new(@core, @theme)
                    when PanelMode::EXTENSIONS
                      ExtensionsPanel.new(@core, @theme)
                    when PanelMode::NOTES
                      NotesPanel.new(@core, @theme)
                    when PanelMode::DEVELOPER
                      DeveloperPanel.new(@core, @theme)
                    when PanelMode::SETTINGS
                      SettingsPanel.new(@core, @theme)
                    else
                      # 不明なモードの場合は空のコンポーネント
                      EmptyPanel.new(@theme)
                    end
        
        # コンポーネントを登録
        components[mode] = component
        
        # 各コンポーネントの初期スクロール位置を0に設定
        @content_scroll_position[mode] = 0
        
        Log.debug "サブコンポーネント初期化: #{mode.to_display_name}"
      end
      
      # 検索インデックスの初期構築
      build_search_index(components)
      
      # 初期化完了ログ
      Log.info "サブコンポーネント初期化完了: #{components.size}個のコンポーネントを登録"
      
      components
    end

    # 検索インデックスの構築
    private def build_search_index(components : Hash(PanelMode, Component))
      start_time = Time.monotonic
      
      # 検索インデックスをクリア
      @search_index.clear
      
      # 各パネルのコンテンツから検索用データをインデックス化
      PanelMode.values.each do |mode|
        # 開発者モードは開発中のみ処理
        next if mode == PanelMode::DEVELOPER && !@config.debug_mode?
        
        if component = components[mode]?
          case mode
          when PanelMode::BOOKMARKS
            index_bookmarks(component.as(BookmarksPanel))
          when PanelMode::HISTORY
            index_history(component.as(HistoryPanel))
          when PanelMode::DOWNLOADS
            index_downloads(component.as(DownloadsPanel))
          when PanelMode::EXTENSIONS
            index_extensions(component.as(ExtensionsPanel))
          when PanelMode::NOTES
            index_notes(component.as(NotesPanel))
          end
        end
      end
      
      # インデックス構築の最適化
      @search_index.optimize
      
      # 構築時間を計測
      build_time = (Time.monotonic - start_time).total_milliseconds
      doc_count = @search_index.document_count
      
      Log.info "検索インデックス構築完了: #{doc_count}件のドキュメントをインデックス化 (#{build_time.round(1)}ms)"
    end

    # ブックマークをインデックス化
    private def index_bookmarks(panel : BookmarksPanel)
      # インデックス開始ログ
      Log.debug "ブックマークをインデックス化します"
      count = 0
      
      # ブックマークをインデックスに追加
      panel.bookmarks.each do |bookmark|
        # メタデータを準備
        timestamp = bookmark.timestamp.to_s("%Y-%m-%d %H:%M:%S")
        metadata = {
          "url" => bookmark.url,
          "timestamp" => timestamp,
          "folder" => bookmark.folder || "",
          "tags" => bookmark.tags?.try(&.join(",")) || ""
        }
        
        # 検索キーワードを追加
        keywords = ["ブックマーク"]
        keywords << bookmark.folder if bookmark.folder
        keywords.concat(bookmark.tags?) if bookmark.tags?
        
        # ドキュメントをインデックスに追加
        @search_index.add_document(
          id: "bookmark:#{bookmark.id}",
          title: bookmark.title,
          content: bookmark.url,
          category: "bookmarks",
          keywords: keywords.join(" "),
          metadata: metadata,
          boost: bookmark.visit_count?.try { |c| Math.log(c + 1) * 0.1 } || 0.0
        )
        
        count += 1
      end
      
      Log.debug "ブックマークのインデックス化完了: #{count}件"
    end

    # 履歴をインデックス化
    private def index_history(panel : HistoryPanel)
      # インデックス開始ログ
      Log.debug "閲覧履歴をインデックス化します"
      count = 0
      
      # 閲覧履歴をインデックスに追加
      panel.history_items.each do |item|
        # メタデータを準備
        timestamp = item.timestamp.to_s("%Y-%m-%d %H:%M:%S")
        date_str = item.timestamp.to_s("%Y-%m-%d")
        time_str = item.timestamp.to_s("%H:%M")
        
        metadata = {
          "url" => item.url,
          "timestamp" => timestamp,
          "date" => date_str,
          "time" => time_str,
          "visit_count" => item.visit_count.to_s
        }
        
        # 検索ブースト値（訪問回数と新しさに基づく）
        days_ago = (Time.utc - item.timestamp).total_days
        recency_boost = Math.max(0.0, 1.0 - (days_ago / 30.0)) # 30日で効果が0になる
        visit_boost = Math.log(item.visit_count + 1) * 0.1
        boost = recency_boost * 0.7 + visit_boost * 0.3
        
        # 検索キーワードを追加
        keywords = ["履歴", date_str]
        
        # ドキュメントをインデックスに追加
        @search_index.add_document(
          id: "history:#{item.id}",
          title: item.title,
          content: item.url,
          category: "history",
          keywords: keywords.join(" "),
          metadata: metadata,
          boost: boost
        )
        
        count += 1
      end
      
      Log.debug "閲覧履歴のインデックス化完了: #{count}件"
    end

    # ダウンロードをインデックス化
    private def index_downloads(panel : DownloadsPanel)
      # インデックス開始ログ
      Log.debug "ダウンロードをインデックス化します"
      count = 0
      
      # ダウンロードをインデックスに追加
      panel.downloads.each do |download|
        # 拡張子を抽出
        extension = File.extname(download.filename).downcase
        
        # ファイルタイプを判定
        file_type = case extension
                    when ".pdf"
                      "PDF文書"
                    when ".doc", ".docx"
                      "Word文書"
                    when ".xls", ".xlsx"
                      "Excel表計算"
                    when ".ppt", ".pptx"
                      "PowerPointプレゼン"
                    when ".jpg", ".jpeg", ".png", ".gif", ".bmp"
                      "画像"
                    when ".mp3", ".wav", ".ogg", ".flac"
                      "音楽"
                    when ".mp4", ".avi", ".mov", ".wmv"
                      "動画"
                    when ".zip", ".rar", ".7z", ".tar", ".gz"
                      "圧縮ファイル"
                    when ".exe", ".msi", ".dmg", ".app"
                      "実行ファイル"
                    else
                      extension.empty? ? "不明" : extension
                    end
        
        # メタデータを準備
        timestamp = download.timestamp.to_s("%Y-%m-%d %H:%M:%S")
        date_str = download.timestamp.to_s("%Y-%m-%d")
        
        metadata = {
          "url" => download.url,
          "filename" => download.filename,
          "extension" => extension,
          "file_type" => file_type,
          "timestamp" => timestamp,
          "date" => date_str,
          "status" => download.status,
          "progress" => download.progress.to_s,
          "size" => download.size?.try(&.to_s) || "0"
        }
        
        # 検索キーワードを追加
        keywords = ["ダウンロード", file_type, extension, date_str]
        
        # 検索ブースト（完了済みファイルを優先）
        boost = download.completed? ? 0.5 : 0.0
        
        # ドキュメントをインデックスに追加
        @search_index.add_document(
          id: "download:#{download.id}",
          title: download.filename,
          content: download.url,
          category: "downloads",
          keywords: keywords.join(" "),
          metadata: metadata,
          boost: boost
        )
        
        count += 1
      end
      
      Log.debug "ダウンロードのインデックス化完了: #{count}件"
    end
    
    # 拡張機能をインデックス化
    private def index_extensions(panel : ExtensionsPanel)
      # インデックス開始ログ
      Log.debug "拡張機能をインデックス化します"
      count = 0
      
      # 拡張機能をインデックスに追加
      panel.extensions.each do |extension|
        # メタデータを準備
        metadata = {
          "id" => extension.id,
          "name" => extension.name,
          "version" => extension.version,
          "author" => extension.author || "",
          "enabled" => extension.enabled.to_s,
          "description" => extension.description || ""
        }
        
        # 検索キーワードを追加
        keywords = ["拡張機能"]
        keywords << "有効" if extension.enabled
        keywords << "無効" unless extension.enabled
        keywords << extension.author if extension.author
        
        # 検索ブースト（有効な拡張機能を優先）
        boost = extension.enabled ? 0.3 : 0.0
        
        # ドキュメントをインデックスに追加
        @search_index.add_document(
          id: "extension:#{extension.id}",
          title: extension.name,
          content: extension.description || "",
          category: "extensions",
          keywords: keywords.join(" "),
          metadata: metadata,
          boost: boost
        )
        
        count += 1
      end
      
      Log.debug "拡張機能のインデックス化完了: #{count}件"
    end
    
    # メモをインデックス化
    private def index_notes(panel : NotesPanel)
      # インデックス開始ログ
      Log.debug "メモをインデックス化します"
      count = 0
      
      # メモをインデックスに追加
      panel.notes.each do |note|
        # メタデータを準備
        timestamp = note.timestamp.to_s("%Y-%m-%d %H:%M:%S")
        date_str = note.timestamp.to_s("%Y-%m-%d")
        
        metadata = {
          "timestamp" => timestamp,
          "date" => date_str,
          "url" => note.url || "",
          "tags" => note.tags?.try(&.join(",")) || ""
        }
        
        # 検索キーワードを追加
        keywords = ["メモ", date_str]
        keywords.concat(note.tags?) if note.tags?
        
        # 検索ブースト（新しいメモを優先）
        days_ago = (Time.utc - note.timestamp).total_days
        boost = Math.max(0.0, 1.0 - (days_ago / 14.0)) # 14日で効果が0になる
        
        # ドキュメントをインデックスに追加
        @search_index.add_document(
          id: "note:#{note.id}",
          title: note.title,
          content: note.content,
          category: "notes",
          keywords: keywords.join(" "),
          metadata: metadata,
          boost: boost
        )
        
        count += 1
      end
      
      Log.debug "メモのインデックス化完了: #{count}件"
    end
    
    # 空のパネル（プレースホルダー用）
    class EmptyPanel < Component
      def initialize(@theme : ThemeEngine)
        @visible = true
      end
      
      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds
        
        # 何も表示しない
      end
      
      override def handle_event(event : QuantumEvents::Event) : Bool
        false # イベント処理なし
      end
      
      override def preferred_size : Tuple(Int32, Int32)
        {0, 0} # 推奨サイズなし
      end
    end

    # サイドパネルを描画する
    override def render(window : Concave::Window)
      return unless (bounds = @bounds)
      render_start_time = Time.monotonic
      
      x, y, w, h = bounds
      w = @width # パネル幅を使用（バウンズ幅は無視）

      # アニメーション状態の更新
      update_animations
      
      # アニメーションに基づいて実際の表示位置を計算
      actual_x = x
      if !fully_visible?
        # スライドアニメーション中
        actual_x = x - (@width * (1.0 - @animation_state)).to_i
      end
      
      # キャッシュキーの生成（パネルの状態に基づく）
      cache_key = "panel_#{@current_mode}_#{w}_#{h}_#{@animation_state}_#{@search_active}"
      
      # キャッシュの使用判断
      if !@cache_needs_update && @render_cache.has_key?(cache_key)
        # キャッシュから描画
        cache_entry = @render_cache[cache_key]
        window.draw_texture(cache_entry.texture, x: actual_x, y: y)
        cache_entry.hit
        @render_stats.cache_hits += 1
        
        # アニメーション効果だけ常に最新の状態で描画
        render_animation_effects(window, actual_x, y, w, h)
        
        # パフォーマンス測定を更新
        render_time = (Time.monotonic - render_start_time).total_milliseconds
        @render_stats.record_frame_time(render_time)
        @performance_metrics.add_metric("side_panel_render_time_cached", render_time)
        
        return
      end
      
      # キャッシュミスカウント
      @render_stats.cache_misses += 1
      
      # ここから実際の描画処理
      # 新しいテクスチャを作成して描画
      panel_texture = Concave::Texture.create_empty(w, h, Concave::PixelFormat::RGBA)
      
      panel_texture.with_draw_target do |ctx|
        # 背景（グラデーション）
        render_background(ctx, 0, 0, w, h)
        
        # 境界線
        ctx.set_draw_color(@theme.colors.border, 0.6)
        ctx.draw_line(x1: w - 1, y1: 0, x2: w - 1, y2: h)
        
        # モード切替タブを描画
        render_mode_tabs(ctx, 0, 0, w, @tab_height)
        
        # タイトルを描画
        render_header(ctx, 0, @tab_height, w, @header_height)
        
        # コンテンツ領域のY座標とサイズを計算
        content_y = @tab_height + @header_height
        content_height = h - @tab_height - @header_height
        
        # 検索バーが表示されている場合、コンテンツ領域を調整
        if @search_active
          content_height -= @search_bar_height
        end
        
        # 現在のモードに応じたサブコンポーネントを描画
        render_content(ctx, 0, content_y, w, content_height)
        
        # リサイズハンドル
        render_resize_handle(ctx, 0, 0, w, h)
        
        # 検索バーが表示されている場合
        if @search_active
          search_y = h - @search_bar_height
          render_search_bar(ctx, 0, search_y, w, @search_bar_height)
        end
        
        # デバッグ情報表示
        if @debug_overlay_visible && @config.debug_mode?
          render_debug_overlay(ctx, 0, 0, w, h)
        end
      end
      
      # テクスチャをウィンドウに描画
      window.draw_texture(panel_texture, x: actual_x, y: y)
      
      # キャッシュの更新
      texture_size = w * h * 4 # RGBAの各チャネルは1バイト
      new_cache_entry = CacheEntry.new(panel_texture, texture_size, cache_key)
      @render_cache[cache_key] = new_cache_entry
      @cache_needs_update = false
      
      # テクスチャ用の推定メモリ使用量を追加
      @render_stats.memory_usage += texture_size
      
      # アニメーションエフェクト（リップルなど）
      render_animation_effects(window, actual_x, y, w, h)
      
      # パフォーマンス測定を更新
      render_time = (Time.monotonic - render_start_time).total_milliseconds
      @render_stats.render_time = render_time
      @render_stats.total_renders += 1
      @render_stats.record_frame_time(render_time)
      @performance_metrics.add_metric("side_panel_render_time", render_time)
      
      # 定期的なキャッシュクリーンアップ
      cleanup_expired_caches if @render_stats.total_renders % 100 == 0
      
      # パフォーマンス適応処理
      adapt_performance if @adaptive_performance && @render_stats.total_renders % 50 == 0
    rescue ex
      Log.error "サイドパネルの描画に失敗しました", exception: ex
    end

    # グラデーション背景を描画
    private def render_background(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # パネル背景（グラデーション）
      bg_base = @theme.colors.secondary
      bg_dark = darken_color(bg_base, 0.03) # 少し暗く
      
      # 上から下へのグラデーション
      (0...height).step(2) do |offset_y|
        progress = offset_y.to_f / height
        color = blend_colors(bg_base, bg_dark, progress)
        
        ctx.set_draw_color(color, 1.0)
        ctx.draw_line(x1: x, y1: y + offset_y, x2: x + width, y2: y + offset_y)
      end
      
      # 現在のモードに応じたアクセントカラーのわずかな効果
      accent_color = @panel_colors[@current_mode]
      ctx.set_draw_color(accent_color, 0.03)
      ctx.fill_rect(x: x, y: y, width: width, height: height)
    end

    # モード切替タブを描画
    private def render_mode_tabs(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # キャッシュを使用するか判断
      if !@tab_cache_needs_update && @tab_render_cache
        # キャッシュから描画
        cache = @tab_render_cache.not_nil!
        ctx.draw_texture(cache.texture, x: x, y: y)
        
        # アニメーション状態のハイライトを追加描画（常に最新に）
        render_tab_highlights(ctx, x, y, width, height)
        return
      end
      
      # キャッシュを作成または更新
      tab_texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
      tab_texture.with_draw_target do |ctx|
        # 背景（少し暗い）
        bg_color = darken_color(@theme.colors.secondary, 0.05)
        ctx.set_draw_color(bg_color, 1.0)
        ctx.fill_rect(x: 0, y: 0, width: width, height: height)
        
        # 下境界線
        ctx.set_draw_color(@theme.colors.border, 0.5)
        ctx.draw_line(x1: 0, y1: height - 1, x2: width, y2: height - 1)
        
        # 表示するタブ項目（DEVELOPER モードはデバッグモードでのみ表示）
        visible_modes = if @config.debug_mode?
                          PanelMode.values
                        else
                          PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                        end
        
        tab_width = width / visible_modes.size
        
        # 各タブを描画
        visible_modes.each_with_index do |mode, index|
          tab_x = index * tab_width
          
          # タブの基本背景
          tab_bg_color = blend_colors(bg_color, @panel_colors[mode], 0.03)
          ctx.set_draw_color(tab_bg_color, 1.0)
          ctx.fill_rect(x: tab_x, y: 0, width: tab_width, height: height)
          
          # 選択中タブの背景
          if mode == @current_mode
            active_bg = blend_colors(tab_bg_color, @panel_colors[mode], 0.15)
            ctx.set_draw_color(active_bg, 1.0)
            ctx.fill_rect(x: tab_x, y: 0, width: tab_width, height: height)
            
            # 下部インジケーター
            accent_color = @panel_colors[mode]
            ctx.set_draw_color(accent_color, 1.0)
            ctx.fill_rect(x: tab_x, y: height - 3, width: tab_width, height: 3)
          end
          
          # タブアイコン
          if icon = @panel_icons[mode]?
            icon_size = height * 0.42
            icon_x = tab_x + (tab_width - icon_size) / 2
            icon_y = 4
            
            # アイコンカラー
            icon_color = if mode == @current_mode
                          @panel_colors[mode]
                        else
                          blend_colors(@theme.colors.foreground, @panel_colors[mode], 0.3)
                        end
            
            ctx.set_draw_color(icon_color, mode == @current_mode ? 1.0 : 0.8)
            ctx.draw_text(icon, x: icon_x, y: icon_y, size: icon_size.to_i, font: @theme.icon_font_family || @theme.font_family)
          end
          
          # タブラベル
          label = mode.to_s.capitalize
          text_color = if mode == @current_mode
                        @theme.colors.foreground
                      else
                        darken_color(@theme.colors.foreground, 0.2)
                      end
          
          # テキストを中央に配置
          text_size = @theme.font_size - 3
          ctx.set_draw_color(text_color, mode == @current_mode ? 1.0 : 0.7)
          
          # テキスト幅を測定して中央配置
          text_width = ctx.measure_text(label, size: text_size, font: @theme.font_family)[0]
          text_x = tab_x + (tab_width - text_width) / 2
          text_y = height - text_size - 2
          
          ctx.draw_text(label, x: text_x, y: text_y, size: text_size, font: @theme.font_family)
        end
      end
      
      # キャッシュを保存
      @tab_render_cache = tab_texture
      @tab_cache_needs_update = false
      
      # キャッシュから描画
      ctx.draw_texture(tab_texture, x: x, y: y)
      
      # アニメーション状態のハイライトを追加描画
      render_tab_highlights(ctx, x, y, width, height)
    end
    
    # タブのハイライト効果（アニメーション）を描画
    private def render_tab_highlights(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # 表示するタブ項目
      visible_modes = if @config.debug_mode?
                        PanelMode.values
                      else
                        PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                      end
      
      tab_width = width / visible_modes.size
      
      # 各タブのアニメーション状態を描画
      visible_modes.each_with_index do |mode, index|
        tab_x = x + (index * tab_width)
        
        if anim_state = @tab_animations[index]?
          # ホバーエフェクト
          if anim_state.hover_state > 0
            hover_color = blend_colors(@theme.colors.hover, @panel_colors[mode], 0.5)
            ctx.set_draw_color(hover_color, anim_state.hover_state * 0.2)
            ctx.fill_rect(x: tab_x, y: y, width: tab_width, height: height)
          end
          
          # バウンスエフェクト
          if anim_state.bounce_state > 0
            # アイコンを少し大きく表示
            if icon = @panel_icons[mode]?
              bounce_scale = 1.0 + (anim_state.bounce_state * 0.2)
              icon_base_size = height * 0.42
              icon_size = (icon_base_size * bounce_scale).to_i
              
              # 中心位置を計算
              center_x = tab_x + tab_width / 2
              center_y = y + 4 + icon_base_size / 2
              
              # 拡大したサイズでアイコンを描画
              icon_x = center_x - icon_size / 2
              icon_y = center_y - icon_size / 2
              
              icon_color = @panel_colors[mode]
              ctx.set_draw_color(icon_color, 1.0)
              ctx.draw_text(
                icon, 
                x: icon_x, 
                y: icon_y, 
                size: icon_size, 
                font: @theme.icon_font_family || @theme.font_family
              )
            end
          end
        end
      end
    end

    # ヘッダー部分を描画
    private def render_header(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # 背景
      ctx.set_draw_color(@theme.colors.secondary - 0x03_03_03_00, 1.0)
      ctx.fill_rect(x: x, y: y, width: width, height: height)
      
      # 下境界線
      ctx.set_draw_color(@theme.colors.border, 0.3)
      ctx.draw_line(x1: x, y1: y + height - 1, x2: x + width, y2: y + height - 1)
      
      # タイトル
      ctx.set_draw_color(@theme.colors.foreground, 1.0)
      ctx.draw_text(@panel_title, x: x + 12, y: y + (height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.font_family)
      
      # 検索ボタン
      search_icon = "🔍"
      search_icon_size = height * 0.6
      search_x = x + width - 30
      search_y = y + (height - search_icon_size) / 2
      
      search_color = @search_active ? @theme.colors.accent : @theme.colors.foreground
      ctx.set_draw_color(search_color, @search_active ? 1.0 : 0.8)
      ctx.draw_text(search_icon, x: search_x, y: search_y, size: search_icon_size, font: @theme.icon_font_family || @theme.font_family)
    end

    # 検索バーを描画
    private def render_search_bar(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # 背景
      ctx.set_draw_color(@theme.colors.secondary + 0x05_05_05_00, 1.0)
      ctx.fill_rect(x: x, y: y, width: width, height: height)
      
      # 上境界線
      ctx.set_draw_color(@theme.colors.border, 0.5)
      ctx.draw_line(x1: x, y1: y, x2: x + width, y2: y)
      
      # 検索入力フィールド
      input_width = width - 50
      input_height = height - 10
      input_x = x + 8
      input_y = y + 5
      
      # 入力フィールドの背景
      ctx.set_draw_color(@theme.colors.background_alt, 1.0)
      ctx.fill_rounded_rect(x: input_x, y: input_y, width: input_width, height: input_height, radius: @theme_radius)
      
      # 入力テキスト
      if @search_text.empty?
        # プレースホルダーテキスト
        placeholder = "検索..."
        ctx.set_draw_color(@theme.colors.foreground, 0.5)
        ctx.draw_text(placeholder, x: input_x + 8, y: input_y + (input_height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.font_family)
      else
        # 検索テキスト
        ctx.set_draw_color(@theme.colors.foreground, 1.0)
        ctx.draw_text(@search_text, x: input_x + 8, y: input_y + (input_height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.font_family)
      end
      
      # クリアボタン
      if !@search_text.empty?
        clear_icon = "✕"
        clear_icon_size = height * 0.4
        clear_x = input_x + input_width - 20
        clear_y = input_y + (input_height - clear_icon_size) / 2
        
        ctx.set_draw_color(@theme.colors.foreground, 0.7)
        ctx.draw_text(clear_icon, x: clear_x, y: clear_y, size: clear_icon_size, font: @theme.icon_font_family || @theme.font_family)
      end
      
      # 検索結果カウント
      if !@search_text.empty? && (@search_results.has_key?(@current_mode) || !@last_search_text.empty?)
        result_count = @search_results[@current_mode]?.size || 0
        result_text = "#{result_count}件"
        ctx.set_draw_color(@theme.colors.foreground, 0.8)
        ctx.draw_text(result_text, x: input_x + input_width + 5, y: input_y + (input_height - @theme.font_size) / 2, size: @theme.font_size - 2, font: @theme.font_family)
      end
    end

    # イベント処理
    override def handle_event(event : QuantumEvents::Event) : Bool
      # アニメーション中はイベントを消費（クリックスルー防止）
      if @animation_start_time
        return true
      end

      # リサイズ処理
      if handle_resize(event)
        return true
      end
      
      # キーボードショートカットで表示/非表示切り替え (Ctrl+B)
      if event.type == QuantumEvents::EventType::KEY_DOWN
        if event.key_code == Concave::Key::B && event.key_modifiers.control?
          toggle_visibility
          return true # イベント消費
        elsif event.key_code == Concave::Key::F && event.key_modifiers.control? && visible?
          # 検索ショートカット
          toggle_search
          return true
        elsif event.key_code == Concave::Key::ESCAPE && @search_active
          # ESCで検索を閉じる
          @search_active = false
          @search_text = ""
          @last_search_text = ""
          @search_results.clear
          @cache_needs_update = true
          return true
        end
      end

      # 表示中でなければイベント処理しない
      return false unless visible?
      
      # 検索バーのイベント処理
      if @search_active && handle_search_events(event)
        return true
      }

      # タブクリックでモード切替
      if event.type == QuantumEvents::EventType::MOUSE_DOWN && (bounds = @bounds)
        x, y, w, h = bounds
        
        # タブ領域内のクリックか確認
        tab_height = 36
        if event.mouse_y >= y && event.mouse_y <= y + tab_height && 
           event.mouse_x >= x && event.mouse_x <= x + w
          
          # クリックされたタブを特定
          tab_width = w / PanelMode.values.size
          tab_index = ((event.mouse_x - x) / tab_width).to_i
          
          if tab_index >= 0 && tab_index < PanelMode.values.size
            new_mode = PanelMode.values[tab_index]
            switch_mode(new_mode)
            return true # イベント消費
          end
        end
        
        # ヘッダー領域内の検索ボタンクリックか確認
        header_y = y + tab_height
        header_height = 30
        search_button_x = x + w - 30
        search_button_width = 30
        
        if event.mouse_y >= header_y && event.mouse_y <= header_y + header_height &&
           event.mouse_x >= search_button_x && event.mouse_x <= search_button_x + search_button_width
          toggle_search
          return true
        end
        
        # 検索バーのクリアボタンクリックか確認
        if @search_active
          search_y = y + h - 36
          input_x = x + 8
          input_width = w - 50
          clear_x = input_x + input_width - 20
          clear_width = 20
          
          if event.mouse_y >= search_y + 5 && event.mouse_y <= search_y + 31 &&
             event.mouse_x >= clear_x && event.mouse_x <= clear_x + clear_width && !@search_text.empty?
            # 検索テキストをクリア
            @search_text = ""
            @last_search_text = ""
            @search_results.clear
            @cache_needs_update = true
            return true
          end
        end
      end
      
      # マウスホバーでタブハイライト
      if event.type == QuantumEvents::EventType::MOUSE_MOVE && (bounds = @bounds)
        x, y, w, h = bounds
        
        # タブ領域内のホバーか確認
        tab_height = 36
        if event.mouse_y >= y && event.mouse_y <= y + tab_height && 
           event.mouse_x >= x && event.mouse_x <= x + w
          
          # ホバーされたタブを特定
          tab_width = w / PanelMode.values.size
          tab_index = ((event.mouse_x - x) / tab_width).to_i
          
          if tab_index >= 0 && tab_index < PanelMode.values.size && tab_index != @hover_tab_index
            old_hover = @hover_tab_index
            @hover_tab_index = tab_index
            
            # 現在のモードのタブではない場合のみハイライト
            if PanelMode.values[tab_index] != @current_mode
              # ホバーアニメーションを開始
              @tab_animations[tab_index].hover_state = 0.0
              @tab_animations[tab_index].animation_active = true
              @tab_animations[tab_index].last_update = Time.monotonic
              @tab_cache_needs_update = true
            end
            
            if old_hover >= 0 && old_hover < PanelMode.values.size && 
               PanelMode.values[old_hover] != @current_mode
              # 以前のホバーアニメーションをリセット
              @tab_animations[old_hover].hover_state = 0.0
              @tab_animations[old_hover].animation_active = false
              @tab_animations[old_hover].last_update = Time.monotonic
              @tab_cache_needs_update = true
            end
            
            @tab_cache_needs_update = true
            return true
          end
        elsif @hover_tab_index >= 0
          # タブ領域外に出た場合、ホバー状態をリセット
          old_hover = @hover_tab_index
          @hover_tab_index = -1
          
          if old_hover >= 0 && old_hover < PanelMode.values.size && 
             PanelMode.values[old_hover] != @current_mode
            # 以前のホバーアニメーションをリセット
            @tab_animations[old_hover].hover_state = 0.0
            @tab_animations[old_hover].animation_active = false
            @tab_animations[old_hover].last_update = Time.monotonic
            @tab_cache_needs_update = true
          end
        end
      end
      
      # スクロールイベントのプロキシ
      if event.type == QuantumEvents::EventType::MOUSE_WHEEL
        if sub_component = @sub_components[@current_mode]?
          return sub_component.handle_event(event)
        end
      end

      # 現在のモードのサブコンポーネントにイベントを委譲
      if sub_component = @sub_components[@current_mode]?
        # サブコンポーネントの描画領域を考慮してイベント座標を調整
        tab_height = 36
        header_height = 30
        content_y = y + tab_height + header_height
        
        # 検索バーが表示されている場合はさらに調整
        content_height = h - tab_height - header_height
        if @search_active
          content_height -= 36
        end
        
        # コンテンツ領域内のクリックか確認
        if event.mouse_y >= content_y && event.mouse_y <= content_y + content_height
          # サブコンポーネントの座標系に変換したイベントを作成
          adjusted_event = event.clone_with_position(
            event.mouse_x - x,
            event.mouse_y - content_y
          )
          
          return sub_component.handle_event(adjusted_event)
        end
      end

      false
    end

    # リサイズハンドリング
    private def handle_resize(event : QuantumEvents::Event) : Bool
      return false unless bounds = @bounds
      x, y, w, h = bounds
      
      # リサイズハンドル領域の定義
      handle_width = 8 # クリック判定用は少し広めに
      handle_x = x + w - handle_width
      
      case event.type
      when QuantumEvents::EventType::MOUSE_DOWN
        if event.mouse_button == QuantumEvents::MouseButton::LEFT &&
           event.mouse_x >= handle_x && event.mouse_x <= x + w &&
           event.mouse_y >= y && event.mouse_y <= y + h
          # リサイズ開始
          @drag_resize_active = true
          @drag_start_x = event.mouse_x
          @start_width = @width
          return true
        end
      when QuantumEvents::EventType::MOUSE_UP
        if @drag_resize_active
          # リサイズ終了
          @drag_resize_active = false
          # 設定を保存
          @config.save_side_panel_width(@width)
          return true
        end
      when QuantumEvents::EventType::MOUSE_MOVE
        if @drag_resize_active
          # リサイズ中
          delta_x = event.mouse_x - @drag_start_x
          new_width = @start_width + delta_x
          # 最小・最大幅を制限
          @width = Math.clamp(new_width, @min_width, @max_width)
          
          # レイアウト再計算イベントを発行
          QuantumEvents::EventDispatcher.instance.publish(
            QuantumEvents::Event.new(
              type: QuantumEvents::EventType::UI_LAYOUT_CHANGED,
              data: nil
            )
          )
          return true
        else
          # リサイズハンドル上にホバーしているか
          old_hover = @resize_hover
          @resize_hover = event.mouse_x >= handle_x && event.mouse_x <= x + w &&
                         event.mouse_y >= y && event.mouse_y <= y + h
          
          # ホバー状態が変化した場合はカーソルを変更
          if old_hover != @resize_hover
            cursor = @resize_hover ? Concave::Cursor::SIZEWE : Concave::Cursor::DEFAULT
            window = QuantumUI::WindowRegistry.instance.get_current_window
            window.set_cursor(cursor) if window
            return true
          end
        end
      end
      
      false
    end

    # 検索関連のイベント処理
    private def handle_search_events(event : QuantumEvents::Event) : Bool
      return false unless bounds = @bounds
      x, y, w, h = bounds
      
      # 検索バーの領域
      search_y = y + h - 36
      search_height = 36
      
      # 検索バー内のクリックか確認
      if event.type == QuantumEvents::EventType::MOUSE_DOWN
        if event.mouse_y >= search_y && event.mouse_y <= search_y + search_height &&
           event.mouse_x >= x && event.mouse_x <= x + w
          # 検索バー内のクリック
          
          # 入力フィールドの領域
          input_x = x + 8
          input_width = w - 50
          input_y = search_y + 5
          input_height = search_height - 10
          
          if event.mouse_x >= input_x && event.mouse_x <= input_x + input_width &&
             event.mouse_y >= input_y && event.mouse_y <= input_y + input_height
            # 検索入力フィールドクリック - キーボード入力モードに（実際の実装は省略）
            QuantumUI::WindowRegistry.instance.get_current_window.try &.start_text_input(@search_text) do |new_text|
              if new_text != @search_text
                @search_text = new_text
                update_search_results if @search_text.size >= 2 # 2文字以上で検索開始
              end
            end
            return true
          end
        end
      elsif event.type == QuantumEvents::EventType::KEY_DOWN && event.key_code == Concave::Key::ENTER
        # Enterキーで検索実行
        execute_search if !@search_text.empty?
        return true
      end

      false
    end

    # 推奨サイズ (幅は固定、高さは可変)
    override def preferred_size : Tuple(Int32, Int32)
      {@width, 0}
    end

    # 表示/非表示を切り替える
    def toggle_visibility
      if @visible
        # 非表示アニメーションを開始
        @animation_direction = false
        @animation_start_time = Time.monotonic
        @animation_state = 1.0
      else
        # 表示状態に設定してからアニメーション開始
        @visible = true
        @animation_direction = true
        @animation_start_time = Time.monotonic
        @animation_state = 0.0
      end
      
      Log.info "サイドパネルの表示状態を切り替えました: #{@visible}"
      
      # レイアウト再計算イベントを発行
      QuantumEvents::EventDispatcher.instance.publish(
        QuantumEvents::Event.new(
          type: QuantumEvents::EventType::UI_LAYOUT_CHANGED,
          data: nil
        )
      )
    end

    # 表示モードを切り替える
    def switch_mode(mode : PanelMode)
      return if mode == @current_mode
      @current_mode = mode
      @panel_title = get_panel_title(mode)
      Log.info "サイドパネルのモードを切り替えました: #{mode}"
      
      # サブコンポーネントに通知
      if sub_component = @sub_components[@current_mode]?
        sub_component.on_activate if sub_component.responds_to?(:on_activate)
      end
      
      # キャッシュ更新フラグをセット
      @tab_cache_needs_update = true
    end

    # タブのモードに応じたタイトルを取得
    private def get_panel_title(mode : PanelMode) : String
      case mode
      when .BOOKMARKS? then "ブックマーク"
      when .HISTORY?   then "閲覧履歴"
      when .DOWNLOADS? then "ダウンロード"
      when .EXTENSIONS? then "拡張機能"
      when .NOTES? then "メモ"
      else "サイドパネル"
      end
    end
    
    # 検索機能の表示/非表示を切り替え
    private def toggle_search
      @search_active = !@search_active
      if !@search_active
        # 検索を閉じるときはテキストをクリア
        @search_text = ""
        @last_search_text = ""
        @search_results.clear
      end
      @cache_needs_update = true
    end
    
    # 検索を実行
    private def execute_search
      return if @search_text.empty?
      return if @search_text == @last_search_text
      
      @last_search_text = @search_text
      search_query = @search_text.downcase
      
      # 現在のモードのサブコンポーネントで検索実行
      if sub_component = @sub_components[@current_mode]?
        if sub_component.responds_to?(:search)
          result_count = sub_component.search(search_query)
          @search_results[@current_mode] = result_count
        end
      end
      
      @cache_needs_update = true
    end
    
    # 検索結果を更新（インクリメンタルサーチ）
    private def update_search_results
      return if @search_text.empty?
      
      # 最小2文字以上で検索
      if @search_text.size >= 2
        search_query = @search_text.downcase
        
        # 現在のモードのサブコンポーネントで検索実行
        if sub_component = @sub_components[@current_mode]?
          if sub_component.responds_to?(:search)
            result_count = sub_component.search(search_query)
            @search_results[@current_mode] = result_count
            @cache_needs_update = true
          end
        end
      else
        # 検索クエリが短すぎる場合は結果をクリア
        @search_results.delete(@current_mode)
        @cache_needs_update = true
      end
    end

    # アニメーション状態の更新
    private def update_animations
      if @animation_start_time
        elapsed = (Time.monotonic - @animation_start_time).total_milliseconds
        duration = 200.0  # アニメーション時間 (ms)
        progress = Math.min(1.0, elapsed / duration)
        
        if @animation_direction
          # 表示アニメーション
          @animation_state = progress
        else
          # 非表示アニメーション
          @animation_state = 1.0 - progress
        end
        
        # アニメーション完了
        if progress >= 1.0
          @animation_start_time = nil
          
          # 非表示完了なら実際に非表示に
          if !@animation_direction
            @visible = false
          end
        end
      end
    end

    # イベントリスナーをセットアップ
    private def setup_event_listeners
      # テーマ変更イベント
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::THEME_CHANGED) do |_event|
        @theme_radius = (@theme.font_size * 0.3).to_i
        @render_cache.clear
        @tab_render_cache = nil
        @tab_cache_needs_update = true
        @cache_needs_update = true
      end
    end

    # コンテンツ部分を描画
    private def render_content(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      # パネルが非表示なら何もしない
      return unless @visible
        
      # コンテンツのキャッシュキー生成
      content_key = "content_#{@current_mode}_#{width}_#{height}_#{@content_scroll_position[@current_mode]}"
      
      # コンテンツキャッシュを使うかどうか判断
      if @content_cache.has_key?(@current_mode) && !@cache_needs_update
        cache_entry = @content_cache[@current_mode]
        # キャッシュのサイズがマッチするか確認
        if cache_entry.texture.width == width && cache_entry.texture.height == height
          ctx.draw_texture(cache_entry.texture, x: x, y: y)
          cache_entry.hit
          @render_stats.cache_hits += 1
          return
        end
      end
      
      @render_stats.cache_misses += 1
      
      # 現在のモードのコンポーネントを取得
      component = @sub_components[@current_mode]?
      return unless component
      
      # テクスチャを作成
      content_texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
      
      content_texture.with_draw_target do |ctx2|
        # 背景（必要に応じて）
        
        # コンポーネントの境界を設定
        component.bounds = {x, y, width, height}
        
        # 表示領域を設定（スクロール対応）
        content_height = component.preferred_size[1]
        scroll_y = @content_scroll_position[@current_mode]
        
        # スクロール位置を制限（下端が見えるようにする）
        max_scroll = Math.max(0, content_height - height)
        scroll_y = Math.min(scroll_y, max_scroll)
        @content_scroll_position[@current_mode] = scroll_y
        
        # スクロールオフセットを適用
        ctx2.save_state
        ctx2.clip_rect(x: 0, y: 0, width: width, height: height)
        ctx2.translate(0, -scroll_y)
        
        # サブコンポーネントを描画
        component.render(ctx2.target)
        
        # スクロールバーを描画
        if content_height > height
          ctx2.restore_state
          render_scrollbar(ctx2, 0, 0, width, height, scroll_y, content_height)
        else
          ctx2.restore_state
        end
        
        # もし検索が有効で、かつ結果がある場合は、ハイライト表示
        if @search_active && !@search_text.empty?
          highlight_search_results(ctx2, 0, 0, width, height, scroll_y)
        end
      end
      
      # 描画したテクスチャを表示
      ctx.draw_texture(content_texture, x: x, y: y)
      
      # キャッシュに保存
      texture_size = width * height * 4 # RGBA 4バイト
      new_cache_entry = CacheEntry.new(content_texture, texture_size, content_key)
      @content_cache[@current_mode] = new_cache_entry
      @render_stats.memory_usage += texture_size
    rescue ex
      Log.error "コンテンツ描画に失敗しました", exception: ex
    end
    
    # 検索結果をハイライト表示
    private def highlight_search_results(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32, scroll_y : Int32)
      return unless @search_results.has_key?(@current_mode)
      
      results = @search_results[@current_mode]
      return if results.empty?
      
      # 各結果をハイライト
      results.each do |result|
        # 結果の位置を確認（画面内にあるかどうか）
        result_y = result.position.y - scroll_y
        if result_y >= 0 && result_y < height
          # ハイライト背景
          ctx.set_draw_color(@theme.colors.accent, 0.2)
          ctx.fill_rounded_rect(
            x: result.position.x, 
            y: result_y, 
            width: result.width, 
            height: result.height, 
            radius: 2
          )
          
          # 結果をアニメーション効果でさらに目立たせる
          time = Time.monotonic.to_unix_ms / 1000.0
          pulse = (Math.sin(time * 3) + 1) / 2 * 0.2 + 0.2
          ctx.set_draw_color(@theme.colors.accent, pulse)
          ctx.draw_rounded_rect(
            x: result.position.x, 
            y: result_y, 
            width: result.width, 
            height: result.height, 
            radius: 2
          )
        end
      end
    end
    
    # スクロールバーを描画
    private def render_scrollbar(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32, scroll_y : Int32, content_height : Int32)
      # スクロールバーのサイズと位置を計算
      scrollbar_width = 4
      scrollbar_x = width - scrollbar_width - 2
      scrollbar_height = height * height / content_height
      scrollbar_min_height = 30 # 最小高さ
      scrollbar_height = Math.max(scrollbar_height, scrollbar_min_height)
      
      # スクロールバーの位置比率
      scroll_ratio = scroll_y.to_f / (content_height - height)
      scrollbar_y = (height - scrollbar_height) * scroll_ratio
      
      # トラック（背景）
      ctx.set_draw_color(@theme.colors.border, 0.2)
      ctx.fill_rounded_rect(
        x: scrollbar_x, 
        y: 0, 
        width: scrollbar_width, 
        height: height, 
        radius: scrollbar_width / 2
      )
      
      # スクロールバー本体
      ctx.set_draw_color(@theme.colors.accent, 0.5)
      ctx.fill_rounded_rect(
        x: scrollbar_x, 
        y: scrollbar_y, 
        width: scrollbar_width, 
        height: scrollbar_height, 
        radius: scrollbar_width / 2
      )
      
      # スクロールバーのホバーエフェクト
      if @scrollbar_hover
        ctx.set_draw_color(@theme.colors.accent, 0.7)
        ctx.fill_rounded_rect(
          x: scrollbar_x - 1, 
          y: scrollbar_y - 1, 
          width: scrollbar_width + 2, 
          height: scrollbar_height + 2, 
          radius: (scrollbar_width + 2) / 2
        )
      end
    end
    
    # リサイズハンドルを描画
    private def render_resize_handle(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      handle_width = @resize_hover ? @resize_handle_hover_width : @resize_handle_width
      handle_x = width - handle_width
      
      # リサイズハンドルを描画
      alpha = @resize_hover ? 0.3 : 0.1
      ctx.set_draw_color(@theme.colors.border, alpha)
      ctx.fill_rect(x: handle_x, y: y, width: handle_width, height: height)
      
      # ドラッグ中の強調表示
      if @drag_resize_active
        # ドラッグ中は強調表示
        ctx.set_draw_color(@theme.colors.accent, 0.5)
        ctx.fill_rect(x: handle_x, y: y, width: handle_width, height: height)
      end
      
      # ホバー中のハイライト
      if @resize_hover && !@drag_resize_active
        # ハンドルの中央にドットパターンを描画
        accent_color = @panel_colors[@current_mode]
        dot_color = blend_colors(@theme.colors.foreground, accent_color, 0.5)
        dot_size = 2
        dot_spacing = 6
        dot_count = height / dot_spacing
        
        ctx.set_draw_color(dot_color, 0.7)
        
        # ドット列を描画
        dot_count.times do |i|
          dot_y = y + (i * dot_spacing) + (dot_spacing / 2)
          ctx.fill_rect(
            x: handle_x + (handle_width / 2) - (dot_size / 2), 
            y: dot_y - (dot_size / 2), 
            width: dot_size, 
            height: dot_size
          )
        end
      end
    end
    
    # アニメーション効果を描画（リップルなど）
    private def render_animation_effects(window : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32)
      time_now = Time.monotonic
      
      # リップルアニメーション
      @ripple_animations.each_with_index do |ripple, index|
        ripple_x, ripple_y, progress, color = ripple
        
        # リップルの最大半径（パネル幅の半分）
        max_radius = width * 0.5
        current_radius = max_radius * progress
        
        # リップルの透明度（進行に応じて減衰）
        alpha = (1.0 - progress) * 0.4
        
        # リップルを描画
        window.set_draw_color(color, alpha)
        window.draw_circle(
          x: x + ripple_x, 
          y: y + ripple_y, 
          radius: current_radius
        )
      end
      
      # 完了したリップルを削除
      @ripple_animations.reject! { |ripple| ripple[2] >= 1.0 }
      
      # リップルの進行を更新
      delta_time = (time_now - @last_animation_update).total_seconds
      @ripple_animations.map! do |ripple|
        x, y, progress, color = ripple
        new_progress = progress + delta_time * 1.5 # 速度係数
        {x, y, new_progress, color}
      end
      
      @last_animation_update = time_now
    end
    
    # デバッグオーバーレイを描画
    private def render_debug_overlay(ctx : Concave::DrawContext, x : Int32, y : Int32, width : Int32, height : Int32)
      return unless @config.debug_mode?
      
      # 背景
      ctx.set_draw_color(0x00_00_00, 0.7)
      ctx.fill_rect(x: x, y: y, width: width, height: 120)
      
      # 境界線
      ctx.set_draw_color(0xFF_FF_FF, 0.3)
      ctx.draw_rect(x: x, y: y, width: width, height: 120)
      
      # タイトル
      ctx.set_draw_color(0xFF_FF_FF, 1.0)
      ctx.draw_text("デバッグ情報", x: x + 5, y: y + 5, size: @theme.font_size - 1, font: @theme.font_family)
      
      # パフォーマンス情報
      text_y = y + 25
      line_height = @theme.font_size + 2
      
      # 描画時間
      render_time = "描画時間: #{@render_stats.render_time.round(2)}ms"
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      ctx.draw_text(render_time, x: x + 5, y: text_y, size: @theme.font_size - 2, font: @theme.font_family)
      text_y += line_height
      
      # FPS
      fps_text = "アニメーションFPS: #{@render_stats.animation_fps.round(1)}"
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      ctx.draw_text(fps_text, x: x + 5, y: text_y, size: @theme.font_size - 2, font: @theme.font_family)
      text_y += line_height
      
      # キャッシュヒット率
      hit_ratio = (@render_stats.cache_hit_ratio * 100).round(1)
      cache_text = "キャッシュヒット率: #{hit_ratio}% (#{@render_stats.cache_hits}/#{@render_stats.cache_hits + @render_stats.cache_misses})"
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      ctx.draw_text(cache_text, x: x + 5, y: text_y, size: @theme.font_size - 2, font: @theme.font_family)
      text_y += line_height
      
      # メモリ使用量
      memory_mb = (@render_stats.memory_usage / 1024.0 / 1024.0).round(2)
      memory_text = "キャッシュメモリ: #{memory_mb}MB"
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      ctx.draw_text(memory_text, x: x + 5, y: text_y, size: @theme.font_size - 2, font: @theme.font_family)
      text_y += line_height
      
      # アニメーション品質
      quality_text = "アニメーション品質: #{@animation_quality}"
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      ctx.draw_text(quality_text, x: x + 5, y: text_y, size: @theme.font_size - 2, font: @theme.font_family)
    end
    
    # パフォーマンスに応じて設定を適応的に調整
    private def adapt_performance
      return unless @adaptive_performance
      
      # 平均描画時間を取得
      avg_render_time = @render_stats.frame_times.sum / @render_stats.frame_times.size
      
      # 描画時間に基づいてアニメーション品質を調整
      if avg_render_time > 16.0 # 60FPS未満
        # パフォーマンスが低い場合、品質を下げる
        if @animation_quality == :high
          set_animation_quality(:medium)
          Log.info "パフォーマンス最適化: アニメーション品質を medium に変更しました (平均描画時間: #{avg_render_time.round(2)}ms)"
        elsif @animation_quality == :medium && avg_render_time > 25.0
          set_animation_quality(:low)
          Log.info "パフォーマンス最適化: アニメーション品質を low に変更しました (平均描画時間: #{avg_render_time.round(2)}ms)"
        end
      elsif avg_render_time < 8.0 # 120FPS以上
        # パフォーマンスに余裕がある場合、品質を上げる
        if @animation_quality == :low
          set_animation_quality(:medium)
          Log.info "パフォーマンス最適化: アニメーション品質を medium に変更しました (平均描画時間: #{avg_render_time.round(2)}ms)"
        elsif @animation_quality == :medium
          set_animation_quality(:high)
          Log.info "パフォーマンス最適化: アニメーション品質を high に変更しました (平均描画時間: #{avg_render_time.round(2)}ms)"
        end
      end
      
      # メモリ使用量を監視し、必要に応じてキャッシュをクリア
      if @render_stats.memory_usage > @max_cache_memory
        Log.info "メモリ最適化: キャッシュサイズ上限 (#{@max_cache_memory / 1024 / 1024}MB) を超えたためキャッシュをクリア"
        cleanup_all_caches
      end
    end
    
    # 期限切れのキャッシュをクリーンアップ
    private def cleanup_expired_caches
      # メインレンダリングキャッシュの期限切れエントリをクリア
      expired_keys = [] of String
      @render_cache.each do |key, entry|
        if entry.expired?(@cache_ttl)
          expired_keys << key
          @render_stats.memory_usage -= entry.size
        end
      end
      
      expired_keys.each do |key|
        @render_cache.delete(key)
      end
      
      Log.debug "キャッシュクリーンアップ: #{expired_keys.size}個のエントリをクリア"
    end
    
    # 全てのキャッシュをクリア
    private def cleanup_all_caches
      @render_cache.clear
      @content_cache.clear
      @tab_render_cache = nil
      @header_render_cache = nil
      @search_bar_cache = nil
      @cache_needs_update = true
      @tab_cache_needs_update = true
      @header_cache_needs_update = true
      @search_bar_cache_needs_update = true
      @render_stats.memory_usage = 0
      
      Log.info "全キャッシュをクリアしました"
    end

    # ブックマークパネル
    class BookmarksPanel < Component
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @bookmarks = [] of QuantumCore::Bookmark
        load_bookmarks
      end

      def load_bookmarks
        @bookmarks = @core.bookmark_manager.list_bookmarks
      end

      def on_activate
        # パネルがアクティブになった時にブックマークを再読込
        load_bookmarks
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        # 背景（透明）
        
        # タイトル
        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("ブックマーク", x: x + 10, y: y + 20, size: @theme.font_size + 2, font: @theme.font_family)
        
        # ブックマークリスト
        if @bookmarks.empty?
          window.draw_text("ブックマークがありません", x: x + 15, y: y + 60, size: @theme.font_size, font: @theme.font_family)
        else
          @bookmarks.each_with_index do |bookmark, index|
            item_y = y + 60 + (index * 30)
            
            # 項目の背景（マウスオーバー時にハイライト表示する場合に使用）
            
            # ブックマークタイトル
            window.draw_text(bookmark.title, x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
            
            # URL（省略表示）
            url_display = bookmark.url.size > 30 ? "#{bookmark.url[0..27]}..." : bookmark.url
            window.set_draw_color(@theme.colors.foreground, 0.7)
            window.draw_text(url_display, x: x + 15, y: item_y + 18, size: @theme.font_size - 2, font: @theme.font_family)
          end
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        if event.type == QuantumEvents::EventType::UI_MOUSE_DOWN && (bounds = @bounds)
          mouse_event = event.data.as(Concave::Event::MouseDown)
          x, y, w, h = bounds
          
          # ブックマークリスト内のクリックを処理
          if mouse_event.x >= x && mouse_event.x <= x + w && mouse_event.y >= y + 60
            item_index = ((mouse_event.y - (y + 60)) / 30).to_i
            
            if item_index >= 0 && item_index < @bookmarks.size
              # ブックマークをクリックした時の処理
              bookmark = @bookmarks[item_index]
              @core.navigate_to(bookmark.url)
              return true
            end
          end
        end
        
        false
      end
    end

    # 履歴パネル
    class HistoryPanel < Component
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @history_items = [] of QuantumCore::HistoryItem
        load_history
      end

      def load_history
        @history_items = @core.history_manager.get_recent_history(50) # 最新50件を表示
      end

      def on_activate
        # パネルがアクティブになった時に履歴を再読込
        load_history
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        # タイトル
        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("閲覧履歴", x: x + 10, y: y + 20, size: @theme.font_size + 2, font: @theme.font_family)
        
        # 履歴リスト
        if @history_items.empty?
          window.draw_text("閲覧履歴がありません", x: x + 15, y: y + 60, size: @theme.font_size, font: @theme.font_family)
        else
          @history_items.each_with_index do |item, index|
            item_y = y + 60 + (index * 40)
            
            # 訪問日時
            date_str = item.timestamp.to_s("%Y/%m/%d %H:%M")
            window.set_draw_color(@theme.colors.foreground, 0.6)
            window.draw_text(date_str, x: x + 15, y: item_y, size: @theme.font_size - 2, font: @theme.font_family)
            
            # ページタイトル
            window.set_draw_color(@theme.colors.foreground, 1.0)
            window.draw_text(item.title, x: x + 15, y: item_y + 16, size: @theme.font_size, font: @theme.font_family)
          end
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        if event.type == QuantumEvents::EventType::UI_MOUSE_DOWN && (bounds = @bounds)
          mouse_event = event.data.as(Concave::Event::MouseDown)
          x, y, w, h = bounds
          
          # 履歴リスト内のクリックを処理
          if mouse_event.x >= x && mouse_event.x <= x + w && mouse_event.y >= y + 60
            item_index = ((mouse_event.y - (y + 60)) / 40).to_i
            
            if item_index >= 0 && item_index < @history_items.size
              # 履歴項目をクリックした時の処理
              history_item = @history_items[item_index]
              @core.navigate_to(history_item.url)
              return true
            end
          end
        end
        
        false
      end
    end

    # ダウンロードパネル
    class DownloadsPanel < Component
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @downloads = [] of QuantumCore::DownloadItem
        load_downloads
      end

      def load_downloads
        @downloads = @core.download_manager.list_downloads
      end

      def on_activate
        # パネルがアクティブになった時にダウンロード情報を再読込
        load_downloads
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        # タイトル
        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("ダウンロード", x: x + 10, y: y + 20, size: @theme.font_size + 2, font: @theme.font_family)
        
        # ダウンロードリスト
        if @downloads.empty?
          window.draw_text("ダウンロード履歴がありません", x: x + 15, y: y + 60, size: @theme.font_size, font: @theme.font_family)
        else
          @downloads.each_with_index do |download, index|
            item_y = y + 60 + (index * 60)
            
            # ファイル名
            window.set_draw_color(@theme.colors.foreground, 1.0)
            window.draw_text(download.filename, x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
            
            # 進捗状況
            progress_text = download.completed? ? "完了" : "#{(download.progress * 100).to_i}%"
            status_text = "#{progress_text} - #{download.status}"
            window.set_draw_color(@theme.colors.foreground, 0.7)
            window.draw_text(status_text, x: x + 15, y: item_y + 20, size: @theme.font_size - 2, font: @theme.font_family)
            
            # プログレスバー
            progress_width = (w - 30) * download.progress
            window.set_draw_color(@theme.colors.border, 0.3)
            window.fill_rect(x: x + 15, y: item_y + 40, width: w - 30, height: 6)
            window.set_draw_color(@theme.colors.primary, 1.0)
            window.fill_rect(x: x + 15, y: item_y + 40, width: progress_width.to_i, height: 6)
          end
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        if event.type == QuantumEvents::EventType::UI_MOUSE_DOWN && (bounds = @bounds)
          mouse_event = event.data.as(Concave::Event::MouseDown)
          x, y, w, h = bounds
          
          # ダウンロードリスト内のクリックを処理
          if mouse_event.x >= x && mouse_event.x <= x + w && mouse_event.y >= y + 60
            item_index = ((mouse_event.y - (y + 60)) / 60).to_i
            
            if item_index >= 0 && item_index < @downloads.size
              # ダウンロード項目をクリックした時の処理（完了したファイルを開くなど）
              download = @downloads[item_index]
              if download.completed?
                @core.open_downloaded_file(download.id)
                return true
              end
            end
          end
        end
        
        false
      end
    end

    # 開発者パネル
    class DeveloperPanel < Component
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        # 初期化処理
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        # タイトル
        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("開発者ツール", x: x + 10, y: y + 20, size: @theme.font_size + 2, font: @theme.font_family)
        
        # ツールリスト
        if @tools.empty?
          window.draw_text("開発者ツールがありません", x: x + 15, y: y + 60, size: @theme.font_size, font: @theme.font_family)
        else
          @tools.each_with_index do |tool, index|
            item_y = y + 60 + (index * 40)
            
            # ツール名
            window.draw_text(tool.name, x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
            
            # ツールの説明
            window.set_draw_color(@theme.colors.foreground, 0.7)
            window.draw_text(tool.description, x: x + 15, y: item_y + 18, size: @theme.font_size - 2, font: @theme.font_family)
          end
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        if event.type == QuantumEvents::EventType::UI_MOUSE_DOWN && (bounds = @bounds)
          mouse_event = event.data.as(Concave::Event::MouseDown)
          x, y, w, h = bounds
          
          # ツールリスト内のクリックを処理
          if mouse_event.x >= x && mouse_event.x <= x + w && mouse_event.y >= y + 60
            item_index = ((mouse_event.y - (y + 60)) / 40).to_i
            
            if item_index >= 0 && item_index < @tools.size
              # ツールをクリックした時の処理
              tool = @tools[item_index]
              tool.execute(@core)
              return true
            end
          end
        end
        
        false
      end
    end

    # 設定パネル
    class SettingsPanel < Component
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        # 初期化処理
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        # タイトル
        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("パネル設定", x: x + 10, y: y + 20, size: @theme.font_size + 2, font: @theme.font_family)
        
        # 設定リスト
        if @settings.empty?
          window.draw_text("設定項目がありません", x: x + 15, y: y + 60, size: @theme.font_size, font: @theme.font_family)
        else
          @settings.each_with_index do |setting, index|
            item_y = y + 60 + (index * 40)
            
            # 設定名
            window.draw_text(setting.name, x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
            
            # 設定の説明
            window.set_draw_color(@theme.colors.foreground, 0.7)
            window.draw_text(setting.description, x: x + 15, y: item_y + 18, size: @theme.font_size - 2, font: @theme.font_family)
          end
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        if event.type == QuantumEvents::EventType::UI_MOUSE_DOWN && (bounds = @bounds)
          mouse_event = event.data.as(Concave::Event::MouseDown)
          x, y, w, h = bounds
          
          # 設定リスト内のクリックを処理
          if mouse_event.x >= x && mouse_event.x <= x + w && mouse_event.y >= y + 60
            item_index = ((mouse_event.y - (y + 60)) / 40).to_i
            
            if item_index >= 0 && item_index < @settings.size
              # 設定をクリックした時の処理
              setting = @settings[item_index]
              setting.execute(@core)
              return true
            end
          end
        end
        
        false
      end
    end

    # マウスダウンイベントを処理
    private def handle_mouse_down(event : QuantumEvents::Event) : Bool
      return false unless (bounds = @bounds) && @visible
      mouse_event = event.data.as(Concave::Event::MouseDown)
      
      x, y, w, h = bounds
      actual_x = x
      
      # アニメーション中は実際の表示位置を考慮
      if !fully_visible?
        actual_x = x - (@width * (1.0 - @animation_state)).to_i
      end
      
      # マウス座標がパネル内かチェック
      return false unless mouse_event.x >= actual_x && mouse_event.x <= actual_x + @width && mouse_event.y >= y && mouse_event.y <= y + h
      
      # パネル内座標に変換
      panel_x = mouse_event.x - actual_x
      panel_y = mouse_event.y - y
      
      # タブエリアのクリック
      if panel_y < @tab_height
        # 表示するタブ項目
        visible_modes = if @config.debug_mode?
                          PanelMode.values
                        else
                          PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                        end
        
        tab_width = @width / visible_modes.size
        tab_index = panel_x / tab_width
        
        if tab_index >= 0 && tab_index < visible_modes.size
          # タブ選択
          selected_mode = visible_modes[tab_index]
          if selected_mode != @current_mode
            switch_mode(selected_mode)
          else
            # 同じタブを再クリックした場合はバウンスアニメーション
            if anim_state = @tab_animations[tab_index]?
              anim_state.bounce_state = 1.0
              anim_state.animation_active = true
            end
          end
          return true
        end
      
      # ヘッダーエリアのクリック
      elsif panel_y < @tab_height + @header_height
        header_y = panel_y - @tab_height
        
        # 検索ボタンのクリック判定
        search_icon_size = @header_height * 0.6
        search_x = @width - 30
        search_y = (@header_height - search_icon_size) / 2
        
        if panel_x >= search_x - 10 && 
           panel_x <= search_x + search_icon_size + 10 && 
           header_y >= search_y - 10 && 
           header_y <= search_y + search_icon_size + 10
          # 検索ボタンクリック
          toggle_search
          return true
        end
      
      # 検索バーエリアのクリック（検索バーが表示されている場合）
      elsif @search_active && panel_y >= h - @search_bar_height
        # 検索入力フィールドの位置とサイズ
        input_padding = 8
        input_height = @search_bar_height - (input_padding * 2)
        input_width = @width - (input_padding * 4) - 30 # 右側に余白を確保
        input_x = input_padding
        input_y = h - @search_bar_height + input_padding
        
        # クリア（X）ボタンの位置とサイズ
        if !@search_text.empty?
          clear_icon_size = input_height * 0.7
          clear_x = input_x + input_width - clear_icon_size - 4
          clear_y = input_y + (input_height - clear_icon_size) / 2
          
          if panel_x >= clear_x - 5 && 
             panel_x <= clear_x + clear_icon_size + 5 && 
             panel_y >= clear_y - 5 && 
             panel_y <= clear_y + clear_icon_size + 5
            # クリアボタンクリック
            @search_text = ""
            update_search_results
            return true
          end
        end
        
        # 入力フィールドをクリック
        if panel_x >= input_x && 
           panel_x <= input_x + input_width && 
           panel_y >= input_y && 
           panel_y <= input_y + input_height
          # 検索フィールドにフォーカス
          @search_focused = true
          
          # 仮想キーボードを表示（モバイルデバイスの場合）
          @core.show_virtual_keyboard(@search_text)
          
          return true
        else
          # 入力フィールド外をクリック
          @search_focused = false
        end
      
      # コンテンツエリアのクリック
      else
        content_y = @tab_height + @header_height
        content_height = h - @tab_height - @header_height
        
        if @search_active
          content_height -= @search_bar_height
        end
        
        # リサイズハンドル領域のクリック
        resize_handle_width = @resize_hover ? @resize_handle_hover_width : @resize_handle_width
        if panel_x >= @width - resize_handle_width
          # リサイズハンドルクリック（ドラッグリサイズ開始）
          @drag_resize_active = true
          @drag_start_x = mouse_event.x
          @start_width = @width
          return true
        end
        
        # 現在のモードのコンポーネントにイベントを渡す
        if component = @sub_components[@current_mode]? && panel_y >= content_y && panel_y < content_y + content_height
          # スクロール値を考慮したイベントに変換
          scroll_y = @content_scroll_position[@current_mode]
          scrolled_event = event.clone
          scrolled_event.data = mouse_event.clone
          scrolled_event.data.as(Concave::Event::MouseDown).y += scroll_y
          
          if component.handle_event(scrolled_event)
            return true
          end
        end
      end
      
      # リップルエフェクト追加
      add_ripple(panel_x, panel_y, @panel_colors[@current_mode])
      
      true
    end
    
    # マウスアップイベントを処理
    private def handle_mouse_up(event : QuantumEvents::Event) : Bool
      return false unless @visible && @bounds
      
      # ドラッグリサイズが終了
      if @drag_resize_active
        @drag_resize_active = false
        return true
      end
      
      # 現在のモードのコンポーネントにイベントを渡す
      if component = @sub_components[@current_mode]?
        # スクロール値を考慮したイベントに変換
        mouse_event = event.data.as(Concave::Event::MouseUp)
        scroll_y = @content_scroll_position[@current_mode]
        
        scrolled_event = event.clone
        scrolled_event.data = mouse_event.clone
        scrolled_event.data.as(Concave::Event::MouseUp).y += scroll_y
        
        if component.handle_event(scrolled_event)
          return true
        end
      end
      
      false
    end
    
    # マウス移動イベントを処理
    private def handle_mouse_move(event : QuantumEvents::Event) : Bool
      return false unless (bounds = @bounds) && @visible
      mouse_event = event.data.as(Concave::Event::MouseMove)
      
      x, y, w, h = bounds
      actual_x = x
      
      # アニメーション中は実際の表示位置を考慮
      if !fully_visible?
        actual_x = x - (@width * (1.0 - @animation_state)).to_i
      end
      
      # マウス座標がパネル内かチェック
      mouse_in_panel = mouse_event.x >= actual_x && mouse_event.x <= actual_x + @width && mouse_event.y >= y && mouse_event.y <= y + h
      
      # ドラッグリサイズ処理
      if @drag_resize_active
        # リサイズ処理
        delta_x = mouse_event.x - @drag_start_x
        new_width = @start_width + delta_x
        self.width = new_width
        return true
      end
      
      # マウスがパネル外にある場合の処理
      unless mouse_in_panel
        # ホバー状態をリセット
        if @hover_tab_index >= 0
          @last_hover_tab_index = @hover_tab_index
          @hover_tab_index = -1
          
          if anim_state = @tab_animations[@last_hover_tab_index]?
            anim_state.animation_active = true
          end
        end
        
        @resize_hover = false
        return false
      end
      
      # パネル内座標に変換
      panel_x = mouse_event.x - actual_x
      panel_y = mouse_event.y - y
      
      # リサイズハンドルのホバー状態を更新
      @resize_hover = panel_x >= @width - @resize_handle_width
      
      # タブエリアのホバー状態を更新
      if panel_y < @tab_height
        # 表示するタブ項目
        visible_modes = if @config.debug_mode?
                          PanelMode.values
                        else
                          PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                        end
        
        tab_width = @width / visible_modes.size
        tab_index = (panel_x / tab_width).to_i
        
        if tab_index >= 0 && tab_index < visible_modes.size
          if tab_index != @hover_tab_index
            @last_hover_tab_index = @hover_tab_index
            @hover_tab_index = tab_index
            
            if anim_state = @tab_animations[tab_index]?
              anim_state.animation_active = true
            end
            
            if @last_hover_tab_index >= 0 && anim_state = @tab_animations[@last_hover_tab_index]?
              anim_state.animation_active = true
            end
          end
        end
      else
        # タブ領域外のホバー状態をリセット
        if @hover_tab_index >= 0
          @last_hover_tab_index = @hover_tab_index
          @hover_tab_index = -1
          
          if anim_state = @tab_animations[@last_hover_tab_index]?
            anim_state.animation_active = true
          end
        end
        
        # コンテンツエリアのマウス移動
        content_y = @tab_height + @header_height
        content_height = h - @tab_height - @header_height
        
        if @search_active
          content_height -= @search_bar_height
        end
        
        # 現在のモードのコンポーネントにイベントを渡す
        if component = @sub_components[@current_mode]? && panel_y >= content_y && panel_y < content_y + content_height
          # スクロール値を考慮したイベントに変換
          scroll_y = @content_scroll_position[@current_mode]
          scrolled_event = event.clone
          scrolled_event.data = mouse_event.clone
          scrolled_event.data.as(Concave::Event::MouseMove).y += scroll_y
          
          if component.handle_event(scrolled_event)
            return true
          end
        end
      end
      
      # カーソルスタイルを更新
      if @resize_hover || @drag_resize_active
        @core.set_cursor(:ew_resize)
      else
        @core.set_cursor(:default)
      end
      
      true
    end
    
    # マウスホイールイベントを処理
    private def handle_mouse_wheel(event : QuantumEvents::Event) : Bool
      return false unless @visible && (bounds = @bounds)
      mouse_event = event.data.as(Concave::Event::MouseWheel)
      
      x, y, w, h = bounds
      actual_x = x
      
      # アニメーション中は実際の表示位置を考慮
      if !fully_visible?
        actual_x = x - (@width * (1.0 - @animation_state)).to_i
      end
      
      # マウス座標がパネル内かチェック
      return false unless mouse_event.x >= actual_x && mouse_event.x <= actual_x + @width && mouse_event.y >= y && mouse_event.y <= y + h
      
      # コンテンツ領域のスクロール
      content_y = y + @tab_height + @header_height
      content_height = h - @tab_height - @header_height
      
      if @search_active
        content_height -= @search_bar_height
      end
      
      # パネル内座標に変換
      panel_y = mouse_event.y - y
      
      # コンテンツ領域内のホイールイベント
      if panel_y >= @tab_height + @header_height && panel_y < content_y + content_height
        # ホイールイベントによるスクロール
        scroll_amount = if @config.smooth_scrolling?
                          (mouse_event.scroll_y * @config.scroll_speed).to_i
                        else
                          # 行単位スクロールの場合は1行=20px程度
                          (mouse_event.scroll_y * 20).to_i
                        end
        
        # スクロール処理
        scroll_content(scroll_amount)
        return true
      end
      
      false
    end
    
    # キーダウンイベントを処理
    private def handle_key_down(event : QuantumEvents::Event) : Bool
      return false unless @visible && @bounds
      key_event = event.data.as(Concave::Event::KeyDown)
      
      # 検索フィールドが有効かつフォーカスされている場合のキー処理
      if @search_active && @search_focused
        case key_event.key
        when Concave::KeyCode::RETURN, Concave::KeyCode::KP_ENTER
          # Enterキー：検索実行
          update_search_results
          
          # 最近の検索クエリに追加
          if !@search_text.empty? && !@recent_searches.includes?(@search_text)
            @recent_searches.unshift(@search_text)
            if @recent_searches.size > 10
              @recent_searches.pop
            end
          end
          
          return true
        when Concave::KeyCode::ESCAPE
          # ESCキー：検索を閉じる
          toggle_search
          return true
        when Concave::KeyCode::BACKSPACE
          # Backspace：1文字削除
          if !@search_text.empty?
            @search_text = @search_text[0...(@search_text.size - 1)]
            update_search_results
          end
          return true
        else
          # その他のキー：入力処理
          if key_event.is_printable_key? && @search_text.size < 100
            char = key_event.to_char
            if char && !char.empty?
              @search_text += char
              update_search_results
            end
          end
          return true
        end
      end
      
      # 通常のキーボードナビゲーション
      case key_event.key
      when Concave::KeyCode::F
        # F キー: 検索切り替え
        if key_event.mod.control?
          toggle_search
          return true
        end
      when Concave::KeyCode::TAB
        # Tab キー: 次/前のタブへ移動
        visible_modes = if @config.debug_mode?
                          PanelMode.values
                        else
                          PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                        end
        
        current_idx = visible_modes.index(@current_mode) || 0
        next_idx = key_event.mod.shift? ? current_idx - 1 : current_idx + 1
        
        # 範囲内に収める
        next_idx = next_idx % visible_modes.size
        next_mode = visible_modes[next_idx]
        
        # モード切替
        switch_mode(next_mode)
        return true
      when Concave::KeyCode::ESCAPE
        # ESC キー: パネルを閉じる
        hide
        return true
      when Concave::KeyCode::UP, Concave::KeyCode::K
        # 上へスクロール
        scroll_content(-30)
        return true
      when Concave::KeyCode::DOWN, Concave::KeyCode::J
        # 下へスクロール
        scroll_content(30)
        return true
      when Concave::KeyCode::PAGE_UP
        # ページアップ
        if bounds = @bounds
          _, _, _, h = bounds
          content_height = h - @tab_height - @header_height
          if @search_active
            content_height -= @search_bar_height
          end
          
          scroll_content(-(content_height * 0.8).to_i)
        end
        return true
      when Concave::KeyCode::PAGE_DOWN
        # ページダウン
        if bounds = @bounds
          _, _, _, h = bounds
          content_height = h - @tab_height - @header_height
          if @search_active
            content_height -= @search_bar_height
          end
          
          scroll_content((content_height * 0.8).to_i)
        end
        return true
      when Concave::KeyCode::HOME
        # ホーム：先頭へスクロール
        @content_scroll_position[@current_mode] = 0
        invalidate_content_cache
        return true
      when Concave::KeyCode::END
        # エンド：最後へスクロール
        if bounds = @bounds
          _, _, _, h = bounds
          content_height = h - @tab_height - @header_height
          if @search_active
            content_height -= @search_bar_height
          end
          
          if component = @sub_components[@current_mode]?
            total_height = component.preferred_size[1]
            max_scroll = Math.max(0, total_height - content_height)
            @content_scroll_position[@current_mode] = max_scroll
            invalidate_content_cache
          end
        end
        return true
      when Concave::KeyCode::NUMBER_1, Concave::KeyCode::NUMBER_2, Concave::KeyCode::NUMBER_3,
           Concave::KeyCode::NUMBER_4, Concave::KeyCode::NUMBER_5, Concave::KeyCode::NUMBER_6,
           Concave::KeyCode::NUMBER_7
        # 数字キー(1-7)：対応するタブに切り替え
        visible_modes = if @config.debug_mode?
                          PanelMode.values
                        else
                          PanelMode.values.reject { |mode| mode == PanelMode::DEVELOPER }
                        end
        
        # キーコードから数字を抽出（1-7）
        num = case key_event.key
              when Concave::KeyCode::NUMBER_1 then 1
              when Concave::KeyCode::NUMBER_2 then 2
              when Concave::KeyCode::NUMBER_3 then 3
              when Concave::KeyCode::NUMBER_4 then 4
              when Concave::KeyCode::NUMBER_5 then 5
              when Concave::KeyCode::NUMBER_6 then 6
              when Concave::KeyCode::NUMBER_7 then 7
              else 0
              end
        
        # インデックスは0ベース
        tab_idx = num - 1
        
        if tab_idx >= 0 && tab_idx < visible_modes.size
          switch_mode(visible_modes[tab_idx])
          return true
        end
      end
      
      # 現在のモードのコンポーネントにイベントを渡す
      if component = @sub_components[@current_mode]?
        if component.handle_event(event)
          return true
        end
      end
      
      false
    end
    
    # キーアップイベントを処理
    private def handle_key_up(event : QuantumEvents::Event) : Bool
      return false unless @visible && @bounds
      
      # 現在のモードのコンポーネントにイベントを渡す
      if component = @sub_components[@current_mode]?
        if component.handle_event(event)
          return true
        end
      end
      
      false
    end
    
    # 推奨サイズを返す
    override def preferred_size : Tuple(Int32, Int32)
      {@width, 0} # 幅は固定、高さはコンテナに合わせる
    end
  end
end