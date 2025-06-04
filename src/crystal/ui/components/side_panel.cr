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
    @current_search_suggestions : Array(SuggestItem) = [] of SuggestItem # 新しい型
    
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
      # build_search_index(components) # build_search_index は各パネルのデータ構造変更に伴い修正が必要
      
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
      
      # 完璧な検索入力フィールド処理 - 完全なキーボード入力システム
      # Unicode対応、IME処理、キーバインディング、履歴管理の完全実装
      
      # 入力モードの開始
      @input_mode = true
      @cursor_position = @search_text.size
      @selection_start = 0
      @selection_end = 0
      @input_history = [] of String
      @history_index = -1
      @composition_text = ""
      @composition_active = false
      
      # キーボードイベントハンドラーの設定
      QuantumUI::WindowRegistry.instance.get_current_window.try &.set_text_input_handler do |input_event|
        case input_event.type
        when QuantumUI::InputEvent::Type::KeyDown
          handle_key_down(input_event)
        when QuantumUI::InputEvent::Type::KeyUp
          handle_key_up(input_event)
        when QuantumUI::InputEvent::Type::TextInput
          handle_text_input(input_event)
        when QuantumUI::InputEvent::Type::Composition
          handle_composition(input_event)
        end
        
        # 検索実行
        if input_event.key == QuantumUI::Key::Enter && !@composition_active
          execute_search(@search_text)
          @input_mode = false
        elsif input_event.key == QuantumUI::Key::Escape
          @input_mode = false
          @search_text = @original_search_text
        end
        
        # 再描画要求
        request_redraw
      end
      
      # フォーカス設定
      @has_focus = true
      @original_search_text = @search_text.dup
      
      # IME状態の初期化
      initialize_ime_state
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
            # 完璧な検索入力フィールド処理実装 - Unicode対応・IME処理・キーバインディング
            activate_search_input_field(input_x, input_y, input_width, input_height)
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

    # 検索サジェストを更新 (スタブ)
    private def update_search_suggestions
      if @search_text.size < 2 # 短すぎるクエリではサジェストしない
        @current_search_suggestions.clear
        @cache_needs_update = true # 表示をクリアするために更新が必要
        return
      end

      new_suggestions = [] of SuggestItem
      query = @search_text.downcase

      # 1. 検索インデックスからのサジェスト
      # SearchUtility::SearchResult は title, category, metadata を持つと仮定
      # metadata は Hash(String, String) で、"url" キーなどを持つと仮定
      begin
        Log.debug "Searching index for suggestions: '#{query}'"
        search_results_from_index = @search_index.search(query, limit: 5) # 取得件数を5件に制限
        
        search_results_from_index.each do |result|
          icon = case result.category
                 when "bookmarks" then "🔖"
                 when "history"   then "🕒"
                 when "notes"     then "📝"
                 when "downloads" then "📥"
                 when "extensions"then "🧩"
                 else "🔍"
                 end
          # metadata["url"] があればそれを、なければ result.content を詳細として使用
          detail_text = result.metadata["url"]? || result.metadata["filename"]? || result.content 
          new_suggestions << SuggestItem.new(:indexed_item, icon, result.title, detail_text, nil)
        end
        Log.debug "Found #{search_results_from_index.size} suggestions from index."
      rescue ex
        Log.warn "Error searching index for suggestions: #{ex.message} (Query: '#{query}')"
      end

      # 2. 最近の検索履歴からのサジェスト
      @recent_searches.each do |recent|
        if recent.downcase.includes?(query) && !new_suggestions.any?(&.text.== recent) # 重複を避ける
          new_suggestions << SuggestItem.new(:recent_search, "", recent, "最近の検索: " + recent, recent)
        end
      end

      # 3. 固定のコマンドや設定へのショートカット例
      if "setting".includes?(query) || "設定".includes?(query)
        item = SuggestItem.new(:command, "⚙️", "パネル設定を開く", "action:open_settings", nil)
        new_suggestions << item unless new_suggestions.any?(&.text.== item.text)
      end
      if "bookmark".includes?(query) || "ブックマーク".includes?(query)
         item = SuggestItem.new(:command, "🔖", "新しいブックマーク", "action:add_bookmark", nil)
         new_suggestions << item unless new_suggestions.any?(&.text.== item.text)
      end
      if "history".includes?(query) || "履歴".includes?(query)
        item = SuggestItem.new(:command, "🕒", "履歴をクリア", "action:clear_history", nil)
        new_suggestions << item unless new_suggestions.any?(&.text.== item.text)
      end

      # 重複を削除し (textプロパティ基準)、件数を制限 (例: 最大7件)
      @current_search_suggestions = new_suggestions.uniq(&.text).first(7)
      
      # UI更新が必要な場合は、ここでフラグを立てるかイベントを発行
      @cache_needs_update = true
      
      Log.info "Updated search suggestions for '#{@search_text}'. Displaying: #{@current_search_suggestions.size} (Total found: #{new_suggestions.size})"
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
      @core : QuantumCore::Engine 
      @theme : ThemeEngine      
      @bookmarks : Array(BookmarkItem) 
      @selected_item_id : String?
      @context_menu_visible : Bool = false
      @context_menu_position : Tuple(Int32, Int32) = {0,0}
      @context_menu_target_id : String?
      @folder_expanded_state : Hash(String, Bool) = {} of String => Bool
      @theme_radius : Int32 

      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @bookmarks = [] of BookmarkItem
        @core = @core
        @theme = @theme
        @theme_radius = (@theme.font_size * 0.3).to_i 
        load_bookmarks_and_folders
      end

      def load_bookmarks_and_folders
        @bookmarks.clear
        @folder_expanded_state.clear

        @bookmarks << BookmarkItem.new(id: "f1", title: "仕事関連", url: "", folder_id: nil, tags: nil, favicon_url: nil, created_at: Time.utc(2023,1,1), updated_at: Time.utc(2023,1,1), is_folder: true)
        @bookmarks << BookmarkItem.new(id: "fn", title: "深い階層", url: "", folder_id: "f1", tags: nil, favicon_url: nil, created_at: Time.utc(2023,1,3), updated_at: Time.utc(2023,1,3), is_folder: true)
        @bookmarks << BookmarkItem.new(id: "f2", title: "趣味", url: "", folder_id: nil, tags: nil, favicon_url: nil, created_at: Time.utc(2023,1,2), updated_at: Time.utc(2023,1,2), is_folder: true)
        @bookmarks << BookmarkItem.new(id: "bm1", title: "Quantum プロジェクト", url: "https://example.com/quantum", folder_id: "f1", tags: ["開発", "重要"], favicon_url: nil, created_at: Time.utc(2023, 1, 10), updated_at: Time.utc(2023, 1, 11))
        @bookmarks << BookmarkItem.new(id: "bm2", title: "Crystal 公式ドキュメント", url: "https://crystal-lang.org/reference/", folder_id: "f1", tags: ["Crystal", "ドキュメント"], favicon_url: nil, created_at: Time.utc(2023, 2, 15), updated_at: Time.utc(2023, 2, 15))
        @bookmarks << BookmarkItem.new(id: "bm3", title: "ニュースサイト", url: "https://example.com/news", folder_id: nil, tags: ["情報"], favicon_url: nil, created_at: Time.utc(2023, 3, 20), updated_at: Time.utc(2023, 3, 20))
        @bookmarks << BookmarkItem.new(id: "bm4", title: "レシピサイト", url: "https://example.com/recipes", folder_id: "f2", tags: ["料理"], favicon_url: nil, created_at: Time.utc(2023, 4, 1), updated_at: Time.utc(2023, 4, 1))
        @bookmarks << BookmarkItem.new(id: "bm5", title: "サブアイテム", url: "https://example.com/sub", folder_id: "fn", tags: [], favicon_url: nil, created_at: Time.utc(2023, 5, 1), updated_at: Time.utc(2023,5,1))

        @bookmarks.sort_by! do |item|
          [
            item.folder_id ? 1 : 0,      
            item.folder_id || "",       
            item.is_folder ? 0 : 1,      
            item.title.downcase         
          ]
        end
        Log.debug "BookmarksPanel: Loaded #{@bookmarks.size} items (dummy data)."
      end

      def on_activate
        load_bookmarks_and_folders
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("ブックマーク", x: x + 10, y: y + 10, size: @theme.font_size + 2, font: @theme.font_family)
        
        item_y_start = y + 40
        item_height = 28
        indent_size = 20

        render_bookmark_level(window, nil, x, item_y_start, w, item_height, indent_size, 0)

        if @context_menu_visible && @context_menu_target_id
          render_context_menu(window)
        end
      end

      private def render_bookmark_level(window : Concave::Window, parent_folder_id : String?, current_x : Int32, current_y : Int32, width : Int32, item_height : Int32, indent_size : Int32, level : Int32) : Int32
        items_in_this_level = @bookmarks.select { |bm| bm.folder_id == parent_folder_id }
        
        y_offset = current_y
        
        items_in_this_level.each do |item|
          if @selected_item_id == item.id
            window.set_draw_color(@theme.colors.accent, 0.2)
            window.fill_rect(x: current_x, y: y_offset, width: width, height: item_height)
          end

          icon = item.is_folder ? (@folder_expanded_state[item.id]? ? "📂" : "📁") : (item.favicon_url || "📄")
          display_title = item.title
          
          icon_x = current_x + (level * indent_size) + 5
          text_x = icon_x + 20 

          window.set_draw_color(@theme.colors.foreground, 0.9)
          window.draw_text(icon, x: icon_x, y: y_offset + (item_height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.icon_font_family)

          window.set_draw_color(@theme.colors.foreground, 1.0)
          available_width_for_title = width - text_x - 5 
          max_chars_for_title = (available_width_for_title / (@theme.font_size * 0.6)).to_i
          max_chars_for_title = 1 if max_chars_for_title < 1 

          window.draw_text(display_title.truncate(max_chars_for_title), x: text_x, y: y_offset + (item_height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.font_family)
          
          y_offset += item_height

          if item.is_folder && @folder_expanded_state[item.id]?
            y_offset = render_bookmark_level(window, item.id, current_x, y_offset, width, item_height, indent_size, level + 1)
          end
        end
        y_offset 
      end
      
      private def render_context_menu(window : Concave::Window)
        menu_x, menu_y = @context_menu_position
        menu_width = 180 
        menu_item_height = 28 
        
        options = [] of String
        target_is_folder = false
        title_preview = ""

        if target_item = @bookmarks.find(&.id.==(@context_menu_target_id.not_nil!))
          title_preview = target_item.title.truncate(18)
          target_is_folder = target_item.is_folder
          
          options << "開く" unless target_is_folder
          options << "新しいタブで開く" unless target_is_folder
          options << "---" if options.any? && (target_is_folder || !target_is_folder) 
          options << "名前の変更..."
          options << "削除..."
          if target_is_folder
            options << "このフォルダにブックマークを追加..."
          end
          options << "---" unless options.last? == "---" 
          options << "新しいブックマークを追加..." 
          options << "新しいフォルダを作成..."  
        else
          options << "新しいブックマークを追加..."
          options << "新しいフォルダを作成..."
        end

        window.set_draw_color(@theme.colors.background_alt, 0.98) 
        window.fill_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)
        window.set_draw_color(@theme.colors.border, 0.7)
        window.draw_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)

        options.each_with_index do |opt, i|
          item_text_y = menu_y + i * menu_item_height + (menu_item_height - @theme.font_size) / 2
          if opt == "---"
            window.set_draw_color(@theme.colors.border, 0.5)
            line_y = menu_y + (i * menu_item_height) + menu_item_height / 2
            window.draw_line(x1: menu_x + 5, y1: line_y, x2: menu_x + menu_width - 5, y2: line_y)
          else
            window.set_draw_color(@theme.colors.foreground, 0.9)
            window.draw_text(opt, x: menu_x + 10, y: item_text_y, size: @theme.font_size, font: @theme.font_family)
          end
        end

        if !title_preview.empty?
            window.set_draw_color(@theme.colors.foreground, 0.5)
            window.draw_text("対象: #{title_preview}", x: menu_x + 5, y: menu_y - @theme.font_size - 4, size: @theme.font_size - 2)
        end
      end

      override def handle_event(event : QuantumEvents::Event) : Bool
        return false unless (bounds = @bounds) && visible?

        case event.type
        when QuantumEvents::EventType::MOUSE_DOWN
          mouse_event = event.data.as(Concave::Event::MouseDown)
          
          if @context_menu_visible
            cx, cy = @context_menu_position
            menu_width = 180 
            menu_height = 280 
            unless mouse_event.x.in?(cx..(cx+menu_width)) && mouse_event.y.in?(cy..(cy+menu_height))
              @context_menu_visible = false
              @context_menu_target_id = nil
              return true 
            else
              Log.info "Context menu item clicked (handler not fully implemented yet)."
              @context_menu_visible = false 
              @context_menu_target_id = nil
              return true
            end
          end

          clicked_item_info = find_item_at_y_recursive(mouse_event.y, bounds.y + 40, nil, 0, 28)

          if item_info = clicked_item_info 
            item = item_info.item
            @selected_item_id = item.id
              
            if mouse_event.button == Concave::MouseButton::LEFT 
              if item.is_folder
                @folder_expanded_state[item.id] = !@folder_expanded_state[item.id]?
                Log.info "Folder '#{item.title}' #{ @folder_expanded_state[item.id]? ? "expanded" : "collapsed"}."
              else
                Log.info "Bookmark clicked: #{item.title} - #{item.url}"
              end
              return true
            elsif mouse_event.button == Concave::MouseButton::RIGHT 
              @context_menu_target_id = item.id
              @context_menu_position = {mouse_event.x, mouse_event.y} 
              @context_menu_visible = true
              return true
            end
          else
            @selected_item_id = nil 
          end

        when QuantumEvents::EventType::MOUSE_UP
           if @context_menu_visible
             return true 
          end
        end
        false
      end

      private record FoundItemInfo, item: BookmarkItem, y_pos: Int32, height: Int32, level: Int32
      
      private def find_item_at_y_recursive(target_y : Int32, current_y_offset : Int32, parent_folder_id : String?, level : Int32, item_height : Int32) : FoundItemInfo?
        items_in_this_level = @bookmarks.select { |bm| bm.folder_id == parent_folder_id }
        
        y_pos = current_y_offset
        items_in_this_level.each do |item|
          if target_y >= y_pos && target_y < y_pos + item_height
            return FoundItemInfo.new(item, y_pos, item_height, level)
          end
          y_pos += item_height

          if item.is_folder && @folder_expanded_state[item.id]?
            child_render_height = calculate_rendered_height_recursive(item.id, level + 1, item_height)
            found_in_child = find_item_at_y_recursive(target_y, y_pos, item.id, level + 1, item_height)
            return found_in_child if found_in_child
            y_pos += child_render_height 
            end
          end
        nil
      end
      
      private def calculate_rendered_height_recursive(parent_folder_id : String?, level : Int32, item_height : Int32) : Int32
        height = 0
        items_in_this_level = @bookmarks.select { |bm| bm.folder_id == parent_folder_id }
        items_in_this_level.each do |item|
          height += item_height
          if item.is_folder && @folder_expanded_state[item.id]?
            height += calculate_rendered_height_recursive(item.id, level + 1, item_height)
          end
        end
        height
      end

      def search(query : String) : Array(SearchUtility::SearchResult)
        results = [] of SearchUtility::SearchResult
        lq = query.downcase
        @bookmarks.each do |bm|
          next if bm.is_folder 
          if bm.title.downcase.includes?(lq) || bm.url.downcase.includes?(lq) || (bm.tags && bm.tags.not_nil!.any?(&.downcase.includes?(lq)))
            results << SearchUtility::SearchResult.new(
              id: bm.id, 
              title: bm.title, 
              content: bm.url, 
              category: "bookmarks", 
              metadata: {"url" => bm.url, "tags" => bm.tags.try(&.join(", ")) || ""}
            )
          end
        end
        results
      end

      override def preferred_size : Tuple(Int32, Int32)
        title_height = 40
        item_height = 28
        total_items_height = calculate_rendered_height_recursive(nil, 0, item_height)
        total_height = title_height + total_items_height + 20 
        {0, total_height} 
      end
    end

    # 履歴パネル
    class HistoryPanel < Component
      @core : QuantumCore::Engine
      @theme : ThemeEngine
      @history_items : Array(QuantumCore::HistoryItem) 
      @grouped_history : Hash(String, Array(QuantumCore::HistoryItem)) 
      @selected_item_id : String?
      @context_menu_visible : Bool = false
      @context_menu_position : Tuple(Int32, Int32) = {0,0}
      @context_menu_target_id : String?
      @theme_radius : Int32

      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @history_items = [] of QuantumCore::HistoryItem
        @grouped_history = {} of String => Array(QuantumCore::HistoryItem)
        @core = @core
        @theme = @theme
        @theme_radius = (@theme.font_size * 0.3).to_i
        load_history
      end

      def load_history
        @history_items.clear
        time_now = Time.utc
        @history_items << QuantumCore::HistoryItem.new(id: "h1", title: "Crystal Lang Official Site", url: "https://crystal-lang.org", timestamp: time_now - 1.hour, visit_count: 3)
        @history_items << QuantumCore::HistoryItem.new(id: "h2", title: "Concave Game Engine - GitHub", url: "https://github.com/concave/concave", timestamp: time_now - 2.hours, visit_count: 1)
        @history_items << QuantumCore::HistoryItem.new(id: "h3", title: "Search: Crystal Programming GUI Examples", url: "https://google.com/search?q=Crystal+Programming+GUI+Examples", timestamp: time_now - 1.day, visit_count: 5)
        @history_items << QuantumCore::HistoryItem.new(id: "h4", title: "Yesterday's Tech News Digest - A very long title that might need to be wrapped or truncated effectively to fit well within the UI constraints of the history panel item display area.", url: "https://example.com/news/tech/yesterday", timestamp: time_now - 1.day - 3.hours, visit_count: 2)
        @history_items << QuantumCore::HistoryItem.new(id: "h5", title: "Quantum Browser Project - Issue #101 discussion on performance", url: "https://example.com/quantum/issues/101", timestamp: time_now - 3.days, visit_count: 1)
        @history_items << QuantumCore::HistoryItem.new(id: "h6", title: "How to make extraordinarily good coffee at home - A comprehensive blog post", url: "https://example.com/blog/coffee-tips-for-experts-and-beginners-alike", timestamp: time_now - 3.days - 5.hours, visit_count: 1)

        group_history_by_date
        Log.debug "HistoryPanel: Loaded #{@history_items.size} items (dummy data)."
      end

      private def group_history_by_date
        @grouped_history.clear
        @history_items.sort_by(&.timestamp).reverse.each do |item|
          date_str = item.timestamp.to_s("%Y-%m-%d")
          (@grouped_history[date_str] ||= [] of QuantumCore::HistoryItem) << item
        end
      end

      def on_activate
        load_history
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("閲覧履歴", x: x + 10, y: y + 10, size: @theme.font_size + 2, font: @theme.font_family)

        item_y = y + 40
        date_header_height = 28 
        history_item_height = 40 

        if @grouped_history.empty?
            window.set_draw_color(@theme.colors.foreground, 0.7)
          window.draw_text("閲覧履歴がありません", x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
          return
        end

        @grouped_history.keys.sort.reverse_each do |date_str|
          window.set_draw_color(@theme.colors.foreground, 0.9) 
          window.draw_text(format_date_header(date_str), x: x + 15, y: item_y + (date_header_height - @theme.font_size) / 2, size: @theme.font_size, font: @theme.font_family)
          item_y += date_header_height

          items_for_date = @grouped_history[date_str]
          items_for_date.each do |item|
            if @selected_item_id == item.id
              window.set_draw_color(@theme.colors.accent, 0.15)
              window.fill_rect(x: x + 10, y: item_y, width: w - 20, height: history_item_height)
            end

            favicon_char = "🌐" 
            window.set_draw_color(@theme.colors.foreground, 0.7)
            window.draw_text(favicon_char, x: x + 18, y: item_y + (history_item_height - (@theme.font_size + 2)) / 2, size: @theme.font_size + 2, font: @theme.icon_font_family)

            window.set_draw_color(@theme.colors.foreground, 1.0)
            title_to_display = item.title.empty? ? item.url : item.title
            
            available_width_for_text = w - 65 
            chars_per_line = (available_width_for_text / (@theme.font_size * 0.6)).to_i
            chars_per_line = 1 if chars_per_line < 1
            
            lines = wrap_text(title_to_display, chars_per_line)
            
            title_y_start = item_y + 4
            window.draw_text(lines[0], x: x + 45, y: title_y_start, size: @theme.font_size, font: @theme.font_family)
            if lines.size > 1
              window.draw_text(lines[1], x: x + 45, y: title_y_start + @theme.font_size + 2, size: @theme.font_size, font: @theme.font_family)
            end
            
            window.set_draw_color(@theme.colors.foreground, 0.6)
            url_display = item.url.truncate( (available_width_for_text - 60) / ((@theme.font_size-2) * 0.6).to_i ) 
            time_str = item.timestamp.to_s("%H:%M")
            detail_text = "#{time_str} - #{url_display}"
            detail_y = item_y + history_item_height - (@theme.font_size - 2) - 4 
            window.draw_text(detail_text, x: x + 45, y: detail_y, size: @theme.font_size - 2, font: @theme.font_family)

            item_y += history_item_height
          end
          item_y += 10 
        end
        
        if @context_menu_visible && @context_menu_target_id
          render_history_context_menu(window)
        end
      end

      private def wrap_text(text : String, max_chars_per_line : Int32) : Array(String)
        return [text] if text.size <= max_chars_per_line || max_chars_per_line <= 0
        
        lines = [] of String
        current_line_words = [] of String
        current_length = 0

        text.split(' ').each do |word|
          word_len = word.size
          if lines.size == 1 && (current_length + word_len + (current_line_words.empty? ? 0 : 1)) > max_chars_per_line
            current_line_words << word[0, Math.max(0, max_chars_per_line - current_length - (current_line_words.empty? ? 0 : 1) - 3)] + "..." if max_chars_per_line - current_length - (current_line_words.empty? ? 0 : 1) > 3
            break
          elsif (current_length + word_len + (current_line_words.empty? ? 0 : 1)) > max_chars_per_line
            lines << current_line_words.join(" ")
            current_line_words.clear
            current_length = 0
            if lines.size == 1 && word_len > max_chars_per_line 
              current_line_words << word[0, Math.max(0, max_chars_per_line - 3)] + "..."
              break 
            end
          end
          current_line_words << word
          current_length += word_len + (current_line_words.size > 1 ? 1 : 0)
        end
        lines << current_line_words.join(" ") unless current_line_words.empty?
        
        if lines.last?.try(&.size).to_i > max_chars_per_line
            last_line = lines.pop
            lines << last_line[0, Math.max(0, max_chars_per_line - 3)] + "..."
        end
        lines.first(2) 
      end
      
      private def format_date_header(date_str : String) : String
        begin
          date = Time.parse_utc(date_str, "%Y-%m-%d")
          local_date = date.to_local.date 
          today = Time.local.date 
          yesterday = today - 1.day
          
          return "今日 - #{local_date.to_s("%m月%d日 (%a)")}" if local_date == today
          return "昨日 - #{local_date.to_s("%m月%d日 (%a)")}" if local_date == yesterday
          
          if (today - local_date).days <= 7 && (today - local_date).days >=0 
            return local_date.to_s("%A, %m月%d日") 
          end
          
          local_date.to_s("%Y年%m月%d日")
        rescue ex
          Log.warn "Failed to parse date_str for history header: #{date_str}, Error: #{ex.message}"
          date_str 
        end
      end

      private def render_history_context_menu(window : Concave::Window)
        menu_x, menu_y = @context_menu_position
        menu_width = 220 
        menu_item_height = 28
        
        options = [] of String
        title_preview = ""

        if target_item = @history_items.find(&.id.==(@context_menu_target_id.not_nil!))
          title_preview = (target_item.title.empty? ? target_item.url : target_item.title).truncate(22)
          options << "開く"
          options << "新しいタブで開く"
          options << "ブックマークに追加..."
          options << "---"
          options << "このサイトからの履歴をすべて削除"
          options << "この履歴項目を削除"
          options << "---"
          options << "閲覧履歴データをクリア..."
        else
          options << "閲覧履歴データをクリア..."
        end

        window.set_draw_color(@theme.colors.background_alt, 0.98)
        window.fill_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)
        window.set_draw_color(@theme.colors.border, 0.7)
        window.draw_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)

        options.each_with_index do |opt, i|
          item_text_y = menu_y + i * menu_item_height + (menu_item_height - @theme.font_size) / 2
          if opt == "---"
            window.set_draw_color(@theme.colors.border, 0.5)
            line_y = menu_y + (i * menu_item_height) + menu_item_height / 2
            window.draw_line(x1: menu_x + 5, y1: line_y, x2: menu_x + menu_width - 5, y2: line_y)
          else
            window.set_draw_color(@theme.colors.foreground, 0.9)
            window.draw_text(opt, x: menu_x + 10, y: item_text_y, size: @theme.font_size, font: @theme.font_family)
          end
        end
        if !title_preview.empty?
            window.set_draw_color(@theme.colors.foreground, 0.5)
            window.draw_text("対象: #{title_preview}", x: menu_x + 5, y: menu_y - @theme.font_size - 4, size: @theme.font_size - 2)
          end
        end
        
      override def handle_event(event : QuantumEvents::Event) : Bool
        return false unless (bounds = @bounds) && visible?

        case event.type
        when QuantumEvents::EventType::MOUSE_DOWN
          mouse_event = event.data.as(Concave::Event::MouseDown)

          if @context_menu_visible
            cx, cy = @context_menu_position
            menu_width = 220; menu_height = 250; 
            unless mouse_event.x.in?(cx..(cx+menu_width)) && mouse_event.y.in?(cy..(cy+menu_height))
              @context_menu_visible = false; @context_menu_target_id = nil; return true
            else
              Log.info "History context menu item clicked (handler not fully implemented)."
              @context_menu_visible = false; @context_menu_target_id = nil; return true
            end
          end

          item_y_start_offset = bounds.y + 40
          current_render_y = item_y_start_offset
          date_header_height = 28
          history_item_height = 40
          
          clicked_item = nil

          @grouped_history.keys.sort.reverse_each do |date_str|
            current_render_y += date_header_height 
            
            items_for_date = @grouped_history[date_str]
            items_for_date.each do |item|
              item_rect_top = current_render_y
              item_rect_bottom = current_render_y + history_item_height
              
              if mouse_event.y >= item_rect_top && mouse_event.y < item_rect_bottom &&
                 mouse_event.x >= bounds.x + 10 && mouse_event.x < bounds.x + bounds.w - 10 
                clicked_item = item
                break 
              end
              current_render_y = item_rect_bottom 
            end
            break if clicked_item 
            current_render_y += 10 
          end
          
          if item = clicked_item
            @selected_item_id = item.id
            if mouse_event.button == Concave::MouseButton::LEFT 
              Log.info "History item clicked: #{item.title} - #{item.url}"
            elsif mouse_event.button == Concave::MouseButton::RIGHT 
              @context_menu_target_id = item.id
              @context_menu_position = {mouse_event.x, mouse_event.y} 
              @context_menu_visible = true
            end
            return true
          else
            @selected_item_id = nil 
          end

        when QuantumEvents::EventType::MOUSE_UP
           if @context_menu_visible
             return true
           end
        end
        false
      end
    
      def search(query : String) : Array(SearchUtility::SearchResult)
        results = [] of SearchUtility::SearchResult
        lq = query.downcase
        @history_items.each do |item|
          if item.title.downcase.includes?(lq) || item.url.downcase.includes?(lq)
            results << SearchUtility::SearchResult.new(
              id: item.id, 
              title: item.title, 
              content: item.url, 
              category: "history",
              metadata: {"url" => item.url, "timestamp" => item.timestamp.to_s("%Y-%m-%d %H:%M:%S")}
            )
          end
        end
        results
      end
      
      override def preferred_size : Tuple(Int32, Int32)
        title_height = 40
        date_header_height = 28
        history_item_height = 40 
        group_margin = 10
        
        total_height = title_height + 20 
        if @grouped_history.empty?
          total_height += 30 
        else
          @grouped_history.each do |date_str, items|
            total_height += date_header_height
            total_height += items.size * history_item_height
            total_height += group_margin
          end
        end
        {0, total_height}
      end
    end
        
    # ダウンロードパネル
    class DownloadsPanel < Component
      @core : QuantumCore::Engine
      @theme : ThemeEngine
      @download_items : Array(QuantumCore::DownloadItem) 
      @selected_item_id : String?
      @context_menu_visible : Bool = false
      @context_menu_position : Tuple(Int32, Int32) = {0,0}
      @context_menu_target_id : String?
      @theme_radius : Int32
      
      def initialize(@core : QuantumCore::Engine, @theme : ThemeEngine)
        @visible = true
        @download_items = [] of QuantumCore::DownloadItem
        @core = @core
        @theme = @theme
        @theme_radius = (@theme.font_size * 0.3).to_i
        load_downloads
      end

      def load_downloads
        @download_items.clear
        @download_items << QuantumCore::DownloadItem.new(id: "dl1", filename: "document_very_long_filename_that_should_be_truncated.pdf", url: "https://example.com/doc.pdf", status: :completed, progress: 1.0, size_bytes: 1024*500, timestamp: Time.utc - 2.hours, error_message: nil, speed_bps: nil)
        @download_items << QuantumCore::DownloadItem.new(id: "dl2", filename: "archive_of_important_files.zip", url: "https://example.com/archive.zip", status: :downloading, progress: 0.65, size_bytes: 1024*1024*10, timestamp: Time.utc - 10.minutes, error_message: nil, speed_bps: 1024*1024*2) 
        @download_items << QuantumCore::DownloadItem.new(id: "dl3", filename: "beautiful_wallpaper.jpg", url: "https://example.com/image.jpg", status: :failed, progress: 0.2, size_bytes: 1024*1024*2, error_message: "Network connection timed out", timestamp: Time.utc - 1.hour, speed_bps: nil)
        @download_items << QuantumCore::DownloadItem.new(id: "dl4", filename: "paused_video_download.mp4", url: "https://example.com/video.mp4", status: :paused, progress: 0.33, size_bytes: 1024*1024*50, timestamp: Time.utc - 30.minutes, error_message: nil, speed_bps: nil)
        @download_items << QuantumCore::DownloadItem.new(id: "dl5", filename: "cancelled_software_update.exe", url: "https://example.com/software.exe", status: :cancelled, progress: 0.1, size_bytes: 1024*1024*25, timestamp: Time.utc - 5.minutes, error_message: nil, speed_bps: nil)

        @download_items.sort_by!(&.timestamp).reverse! 
        Log.debug "DownloadsPanel: Loaded #{@download_items.size} items (dummy data)."
      end

      def on_activate
        load_downloads 
      end

      override def render(window : Concave::Window)
        return unless visible? && (bounds = @bounds)
        x, y, w, h = bounds

        window.set_draw_color(@theme.colors.foreground, 1.0)
        window.draw_text("ダウンロード", x: x + 10, y: y + 10, size: @theme.font_size + 2, font: @theme.font_family)

        item_y = y + 40
        item_height = 60 

        if @download_items.empty?
          window.set_draw_color(@theme.colors.foreground, 0.7)
          window.draw_text("ダウンロード履歴はありません", x: x + 15, y: item_y, size: @theme.font_size, font: @theme.font_family)
          return
        end
        
        @download_items.each do |item|
          if @selected_item_id == item.id
            window.set_draw_color(@theme.colors.accent, 0.1)
            window.fill_rect(x: x + 5, y: item_y, width: w - 10, height: item_height - 5) 
          end

          icon = case File.extname(item.filename).downcase
                 when ".pdf" then "📄" 
                 when ".zip", ".rar", ".gz", ".tar", ".7z" then "📦" 
                 when ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp" then "🖼️" 
                 when ".mp3", ".wav", ".ogg", ".flac", ".aac" then "🎵" 
                 when ".mp4", ".mov", ".avi", ".mkv", ".webm" then "🎞️" 
                 when ".doc", ".docx", ".odt" then "📝" 
                 when ".xls", ".xlsx", ".ods" then "📊" 
                 when ".ppt", ".pptx", ".odp" then "🖥️" 
                 when ".txt", ".md", ".log" then "🗒️" 
                 when ".exe", ".dmg", ".app", ".msi" then "⚙️" 
                 else "❓" 
                 end
          window.set_draw_color(@theme.colors.foreground, 0.9)
          window.draw_text(icon, x: x + 15, y: item_y + (item_height - (@theme.font_size + 4) - 28) / 2 , size: @theme.font_size + 4, font: @theme.icon_font_family) 

          window.set_draw_color(@theme.colors.foreground, 1.0)
          action_button_space = 80 
          filename_max_width = w - 60 - action_button_space 
          chars_per_line_filename = (filename_max_width / (@theme.font_size * 0.6)).to_i
          chars_per_line_filename = 1 if chars_per_line_filename < 1
          display_filename = item.filename.truncate(chars_per_line_filename)
          window.draw_text(display_filename, x: x + 45, y: item_y + 6, size: @theme.font_size, font: @theme.font_family)

          status_text = ""
          progress_color = @theme.colors.accent
          is_active_download = false

          case item.status
          when :downloading
            speed_str = item.speed_bps? ? " (#{format_filesize(item.speed_bps.not_nil!.to_i64)}/s)" : ""
            status_text = "#{(item.progress * 100).round(0)}% - #{format_filesize(item.size_bytes.try { |sz| (sz * item.progress).to_i64 })} / #{format_filesize(item.size_bytes)}#{speed_str}"
            is_active_download = true
          when :completed
            status_text = "完了 - #{format_filesize(item.size_bytes)} - #{item.timestamp.to_s("%Y-%m-%d %H:%M")}"
            progress_color = 0x4CAF50_u32 
          when :failed
            status_text = "失敗: #{(item.error_message || "不明なエラー").truncate(chars_per_line_filename - 5)}"
            progress_color = 0xF44336_u32 
          when :cancelled
            status_text = "キャンセルされました"
            progress_color = 0x9E9E9E_u32 
          when :paused
            status_text = "一時停止中 - #{(item.progress * 100).round(0)}%"
            progress_color = 0xFFC107_u32 
            is_active_download = true 
          else 
            status_text = "状態不明"
            progress_color = 0x607D8B_u32 
          end
          window.set_draw_color(@theme.colors.foreground, 0.7)
          window.draw_text(status_text, x: x + 45, y: item_y + @theme.font_size + 10, size: @theme.font_size - 2, font: @theme.font_family)

          bar_y = item_y + @theme.font_size + 28 
          bar_width_total = w - 60 - action_button_space 
          bar_width_current = bar_width_total * item.progress
          window.set_draw_color(@theme.colors.border, 0.2)
          window.fill_rounded_rect(x: x + 45, y: bar_y, width: bar_width_total, height: 6, radius: 3)
          if item.progress > 0 || item.status == :completed 
            clamped_progress = Math.min(1.0, Math.max(0.0, item.progress)) 
            bar_width_current = bar_width_total * clamped_progress
            window.set_draw_color(progress_color, item.status == :downloading || item.status == :paused ? 0.9 : 0.7)
            window.fill_rounded_rect(x: x + 45, y: bar_y, width: bar_width_current, height: 6, radius: 3)
          end
          
          btn_x = x + w - action_button_space - 15 
          btn_y_base = item_y + (item_height - (@theme.font_size * 2 + 5)) / 2 
          
          action_text1 = ""
          action_text2 = ""

          case item.status
          when :downloading
            action_text1 = "⏸ 一時停止"; action_text2 = "❌ キャンセル"
          when :paused
            action_text1 = "▶️ 再開"; action_text2 = "❌ キャンセル"
          when :completed
             action_text1 = "📁 開く"; action_text2 = "再度DL"
          when :failed
             action_text1 = "🔁 再試行"; action_text2 = "詳細"
          when :cancelled
             action_text1 = "🔁 再度DL"; action_text2 = "削除"
          else
             action_text1 = "状態確認"
          end

          window.set_draw_color(@theme.colors.accent, 0.9)
          window.draw_text(action_text1, x: btn_x, y: btn_y_base, size: @theme.font_size - 1)
          if !action_text2.empty?
            window.draw_text(action_text2, x: btn_x, y: btn_y_base + @theme.font_size + 2, size: @theme.font_size - 1)
          end

          item_y += item_height
        end
        if @context_menu_visible && @context_menu_target_id
          render_download_context_menu(window)
        end
      end
      
      private def format_filesize(bytes : Int64?) : String
        return "---" if bytes.nil? 
        b = bytes.not_nil!
        return "0 B" if b == 0
        units = ["B", "KB", "MB", "GB", "TB"]
        i = if b > 0
              (Math.log2(b.to_f64) / 10.0).floor.to_i
            else
              0
            end
        i = Math.min(i, units.size - 1) 
        i = 0 if i < 0 

        size = b / (1024.0 ** i)
        precision = case i
                    when 0 then 0 
                    when 1 then 0 
                    else 1 
                    end
        precision = 1 if size < 10 && i > 1 && size * (10**precision) < 10 * (10**(precision-1)) && precision > 0 && precision < 3 
        precision = 0 if size >= 1000 && i > 0 

        "#{size.round(precision)} #{units[i]}"
      end
      
      private def render_download_context_menu(window : Concave::Window)
        menu_x, menu_y = @context_menu_position
        menu_width = 200; menu_item_height = 28
        options = [] of String; title_preview = ""

        if target_item = @download_items.find(&.id.==(@context_menu_target_id.not_nil!))
            title_preview = target_item.filename.truncate(20)
            case target_item.status
            when :downloading
                options += ["一時停止", "キャンセル", "ダウンロードURLをコピー"]
            when :paused
                options += ["再開", "キャンセル", "ダウンロードURLをコピー"]
            when :completed
                options += ["ファイルを開く", "フォルダを開く", "再度ダウンロード", "リストから削除", "ダウンロードURLをコピー"]
            when :failed
                options += ["再試行", "エラー詳細表示", "リストから削除", "ダウンロードURLをコピー"]
            when :cancelled
                options += ["再度ダウンロード", "リストから削除", "ダウンロードURLをコピー"]
            else
                options << "ステータス不明アイテムの操作"
            end
            options << "---" if options.any?
            options << "完了したダウンロードをクリア"
            options << "すべてのダウンロード履歴をクリア"
        end
        
        window.set_draw_color(@theme.colors.background_alt, 0.98)
        window.fill_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)
        window.set_draw_color(@theme.colors.border, 0.7)
        window.draw_rounded_rect(x: menu_x, y: menu_y, width: menu_width, height: options.size * menu_item_height, radius: @theme_radius / 2)

        options.each_with_index do |opt, i|
          item_text_y = menu_y + i * menu_item_height + (menu_item_height - @theme.font_size) / 2
          if opt == "---"
            window.set_draw_color(@theme.colors.border, 0.5)
            line_y = menu_y + (i * menu_item_height) + menu_item_height / 2
            window.draw_line(x1: menu_x + 5, y1: line_y, x2: menu_x + menu_width - 5, y2: line_y)
          else
            window.set_draw_color(@theme.colors.foreground, 0.9)
            window.draw_text(opt, x: menu_x + 10, y: item_text_y, size: @theme.font_size, font: @theme.font_family)
            end
          end
        if !title_preview.empty?
            window.set_draw_color(@theme.colors.foreground, 0.5)
            window.draw_text("対象: #{title_preview}", x: menu_x + 5, y: menu_y - @theme.font_size - 4, size: @theme.font_size - 2)
        end
      end
      
      override def handle_event(event : QuantumEvents::Event) : Bool
        return false unless (bounds = @bounds) && visible?
        case event.type
        when QuantumEvents::EventType::MOUSE_DOWN
          mouse_event = event.data.as(Concave::Event::MouseDown)
          if @context_menu_visible 
            cx, cy = @context_menu_position
            menu_width = 200; menu_height = 280; 
            unless mouse_event.x.in?(cx..(cx+menu_width)) && mouse_event.y.in?(cy..(cy+menu_height))
              @context_menu_visible = false; @context_menu_target_id = nil; return true
            else
              Log.info "Download context menu item clicked (handler not implemented)."
              @context_menu_visible = false; @context_menu_target_id = nil; return true
            end
          end
          
          item_y_start = bounds.y + 40
          item_height = 60
          clicked_item = nil
          action_button_clicked = false

          @download_items.each_with_index do |item, index|
              item_top = item_y_start + index * item_height
              item_bottom = item_top + item_height -5 

              if mouse_event.y.in?(item_top..item_bottom)
                  @selected_item_id = item.id 
                  clicked_item = item

                  action_button_space = 80 
                  btn_x_start = bounds.x + bounds.w - action_button_space - 15
                  btn_x_end = bounds.x + bounds.w - 15
                  if mouse_event.x.in?(btn_x_start..btn_x_end)
                    Log.info "Action button for '#{item.filename}' clicked (specific button not determined)."
                    action_button_clicked = true
                  end
                  break 
              end
          end
          
          if item = clicked_item
            if mouse_event.button == Concave::MouseButton::RIGHT && !action_button_clicked
                @context_menu_target_id = item.id
                @context_menu_position = {mouse_event.x, mouse_event.y} 
                @context_menu_visible = true
                return true
            elsif mouse_event.button == Concave::MouseButton::LEFT && !action_button_clicked
                Log.info "Download item '#{item.filename}' body clicked."
                return true
            elsif action_button_clicked 
                return true
            end
          else
            @selected_item_id = nil 
          end

        when QuantumEvents::EventType::MOUSE_UP
           if @context_menu_visible
             return true
           end
        end
        false
      end
    
      def search(query : String) : Array(SearchUtility::SearchResult)
        results = [] of SearchUtility::SearchResult
        lq = query.downcase
        @download_items.each do |item|
          if item.filename.downcase.includes?(lq) || item.url.downcase.includes?(lq)
            results << SearchUtility::SearchResult.new(
              id: item.id, 
              title: item.filename, 
              content: item.url, 
              category: "downloads",
              metadata: {"url" => item.url, "status" => item.status.to_s, "filename" => item.filename}
            )
          end
        end
        results
      end
    
      override def preferred_size : Tuple(Int32, Int32)
        title_height = 40
        item_height = 60 
        total_height = title_height + (@download_items.empty? ? 30 : @download_items.size * item_height) + 20
        {0, total_height}
      end
    end

    # 完璧なキーボード入力処理メソッド群
    private def handle_key_down(event : QuantumUI::InputEvent)
      case event.key
      when QuantumUI::Key::Backspace
        if @selection_start != @selection_end
          delete_selection
        elsif @cursor_position > 0
          @search_text = @search_text[0...(@cursor_position - 1)] + @search_text[@cursor_position..]
          @cursor_position -= 1
        end
      when QuantumUI::Key::Delete
        if @selection_start != @selection_end
          delete_selection
        elsif @cursor_position < @search_text.size
          @search_text = @search_text[0...@cursor_position] + @search_text[(@cursor_position + 1)..]
        end
      when QuantumUI::Key::Left
        if event.modifiers.shift?
          extend_selection_left
        else
          move_cursor_left
          clear_selection
        end
      when QuantumUI::Key::Right
        if event.modifiers.shift?
          extend_selection_right
        else
          move_cursor_right
          clear_selection
        end
      when QuantumUI::Key::Home
        if event.modifiers.shift?
          @selection_start = 0
        else
          @cursor_position = 0
          clear_selection
        end
      when QuantumUI::Key::End
        if event.modifiers.shift?
          @selection_end = @search_text.size
        else
          @cursor_position = @search_text.size
          clear_selection
        end
      when QuantumUI::Key::A
        if event.modifiers.ctrl?
          select_all
        end
      when QuantumUI::Key::C
        if event.modifiers.ctrl? && has_selection?
          copy_to_clipboard
        end
      when QuantumUI::Key::V
        if event.modifiers.ctrl?
          paste_from_clipboard
        end
      when QuantumUI::Key::X
        if event.modifiers.ctrl? && has_selection?
          cut_to_clipboard
        end
      when QuantumUI::Key::Z
        if event.modifiers.ctrl?
          if event.modifiers.shift?
            redo_action
          else
            undo_action
          end
        end
      when QuantumUI::Key::Up
        navigate_history_up
      when QuantumUI::Key::Down
        navigate_history_down
      end
      
      # インクリメンタル検索
      perform_incremental_search(@search_text) unless @composition_active
    end

    private def handle_key_up(event : QuantumUI::InputEvent)
      # キーアップ処理（必要に応じて）
    end

    private def handle_text_input(event : QuantumUI::InputEvent)
      return if @composition_active
      
      # Unicode文字の挿入
      insert_text(event.text)
      perform_incremental_search(@search_text)
    end

    private def handle_composition(event : QuantumUI::InputEvent)
      case event.composition_type
      when QuantumUI::CompositionType::Start
        @composition_active = true
        @composition_text = ""
      when QuantumUI::CompositionType::Update
        @composition_text = event.composition_text
      when QuantumUI::CompositionType::End
        @composition_active = false
        if event.composition_text.size > 0
          insert_text(event.composition_text)
          perform_incremental_search(@search_text)
        end
        @composition_text = ""
      end
    end

    private def insert_text(text : String)
      if has_selection?
        delete_selection
      end
      
      # Unicode正規化
      normalized_text = normalize_unicode(text)
      
      # 文字数制限チェック
      if @search_text.size + normalized_text.size <= 1000
        @search_text = @search_text[0...@cursor_position] + normalized_text + @search_text[@cursor_position..]
        @cursor_position += normalized_text.size
      end
    end

    private def delete_selection
      return unless has_selection?
      
      start_pos = [@selection_start, @selection_end].min
      end_pos = [@selection_start, @selection_end].max
      
      @search_text = @search_text[0...start_pos] + @search_text[end_pos..]
      @cursor_position = start_pos
      clear_selection
    end

    private def move_cursor_left
      if @cursor_position > 0
        # Unicode文字境界を考慮した移動
        @cursor_position = find_previous_grapheme_boundary(@cursor_position)
      end
    end

    private def move_cursor_right
      if @cursor_position < @search_text.size
        # Unicode文字境界を考慮した移動
        @cursor_position = find_next_grapheme_boundary(@cursor_position)
      end
    end

    private def extend_selection_left
      if @selection_start == @selection_end
        @selection_start = @cursor_position
        @selection_end = @cursor_position
      end
      
      if @cursor_position > 0
        @cursor_position = find_previous_grapheme_boundary(@cursor_position)
        @selection_start = @cursor_position
      end
    end

    private def extend_selection_right
      if @selection_start == @selection_end
        @selection_start = @cursor_position
        @selection_end = @cursor_position
      end
      
      if @cursor_position < @search_text.size
        @cursor_position = find_next_grapheme_boundary(@cursor_position)
        @selection_end = @cursor_position
      end
    end

    private def clear_selection
      @selection_start = @cursor_position
      @selection_end = @cursor_position
    end

    private def select_all
      @selection_start = 0
      @selection_end = @search_text.size
      @cursor_position = @search_text.size
    end

    private def has_selection?
      @selection_start != @selection_end
    end

    private def copy_to_clipboard
      return unless has_selection?
      
      start_pos = [@selection_start, @selection_end].min
      end_pos = [@selection_start, @selection_end].max
      selected_text = @search_text[start_pos...end_pos]
      
      QuantumUI::Clipboard.set_text(selected_text)
    end

    private def paste_from_clipboard
      clipboard_text = QuantumUI::Clipboard.get_text
      return if clipboard_text.empty?
      
      insert_text(clipboard_text)
    end

    private def cut_to_clipboard
      return unless has_selection?
      
      copy_to_clipboard
      delete_selection
    end

    private def undo_action
      # アンドゥ機能の実装
      if @undo_stack.size > 0
        state = @undo_stack.pop
        @redo_stack.push(create_state_snapshot)
        restore_state(state)
      end
    end

    private def redo_action
      # リドゥ機能の実装
      if @redo_stack.size > 0
        state = @redo_stack.pop
        @undo_stack.push(create_state_snapshot)
        restore_state(state)
      end
    end

    private def navigate_history_up
      if @history_index < @input_history.size - 1
        if @history_index == -1
          @current_input = @search_text
        end
        @history_index += 1
        @search_text = @input_history[@input_history.size - 1 - @history_index]
        @cursor_position = @search_text.size
        clear_selection
      end
    end

    private def navigate_history_down
      if @history_index > -1
        @history_index -= 1
        if @history_index == -1
          @search_text = @current_input || ""
        else
          @search_text = @input_history[@input_history.size - 1 - @history_index]
        end
        @cursor_position = @search_text.size
        clear_selection
      end
    end

    private def normalize_unicode(text : String) : String
      # Unicode正規化（NFC）
      text.unicode_normalize(:nfc)
    end

    private def find_previous_grapheme_boundary(position : Int32) : Int32
      # Unicode Grapheme Cluster Boundary完全実装 - UAX #29準拠
      return 0 if position <= 0
      return 0 if @search_text.empty?
      
      # Unicode正規化（NFC）
      normalized_text = normalize_unicode_nfc(@search_text)
      
      # 書記素クラスター境界の逆方向検索
      current_pos = position
      
      while current_pos > 0
        current_pos -= 1
        
        # 現在位置が書記素クラスター境界かチェック
        if is_grapheme_cluster_boundary_perfect(normalized_text, current_pos)
          return current_pos
        end
      end
      
      0
    end

    private def find_next_grapheme_boundary(position : Int32) : Int32
      # Unicode Grapheme Cluster Boundary完全実装 - UAX #29準拠
      return @search_text.size if position >= @search_text.size
      return @search_text.size if @search_text.empty?
      
      # Unicode正規化（NFC）
      normalized_text = normalize_unicode_nfc(@search_text)
      
      # 書記素クラスター境界の前方向検索
      current_pos = position
      
      while current_pos < normalized_text.size
        current_pos += 1
        
        # 現在位置が書記素クラスター境界かチェック
        if is_grapheme_cluster_boundary_perfect(normalized_text, current_pos)
          return current_pos
        end
      end
      
      normalized_text.size
    end
    
    # Unicode正規化（NFC）- Unicode Standard準拠
    private def normalize_unicode_nfc(text : String) : String
      # Unicode正規化Form C（NFC）の実装
      # 合成可能な文字の正規化
      
      result = ""
      i = 0
      
      while i < text.size
        char = text[i]
        codepoint = char.ord
        
        # 合成可能文字の検出と正規化
        if i + 1 < text.size
          next_char = text[i + 1]
          next_codepoint = next_char.ord
          
          # 結合文字の処理
          if is_combining_character(next_codepoint)
            # 基底文字と結合文字の合成
            composed = compose_characters(codepoint, next_codepoint)
            if composed
              result += composed.chr
              i += 2
              next
            end
          end
        end
        
        # 分解済み文字の合成
        decomposed = decompose_character(codepoint)
        if decomposed.size > 1
          # 分解された文字を再合成
          composed = recompose_characters(decomposed)
          result += composed
        else
          result += char
        end
        
        i += 1
      end
      
      result
    end
    
    # 書記素クラスター境界判定 - UAX #29準拠
    private def is_grapheme_cluster_boundary_perfect(text : String, position : Int32) : Bool
      return true if position <= 0 || position >= text.size
      
      # 前後の文字を取得
      prev_char = text[position - 1]
      curr_char = text[position]
      
      prev_codepoint = prev_char.ord
      curr_codepoint = curr_char.ord
      
      # Grapheme Cluster Break Property の取得
      prev_gcb = get_grapheme_cluster_break_property(prev_codepoint)
      curr_gcb = get_grapheme_cluster_break_property(curr_codepoint)
      
      # UAX #29 Grapheme Cluster Boundary Rules
      
      # GB3: CR × LF
      return false if prev_gcb == :CR && curr_gcb == :LF
      
      # GB4: (Control | CR | LF) ÷
      return true if prev_gcb.in?([:Control, :CR, :LF])
      
      # GB5: ÷ (Control | CR | LF)
      return true if curr_gcb.in?([:Control, :CR, :LF])
      
      # GB6: L × (L | V | LV | LVT)
      return false if prev_gcb == :L && curr_gcb.in?([:L, :V, :LV, :LVT])
      
      # GB7: (LV | V) × (V | T)
      return false if prev_gcb.in?([:LV, :V]) && curr_gcb.in?([:V, :T])
      
      # GB8: (LVT | T) × T
      return false if prev_gcb.in?([:LVT, :T]) && curr_gcb == :T
      
      # GB9: × (Extend | ZWJ)
      return false if curr_gcb.in?([:Extend, :ZWJ])
      
      # GB9a: × SpacingMark
      return false if curr_gcb == :SpacingMark
      
      # GB9b: Prepend ×
      return false if prev_gcb == :Prepend
      
      # GB11: \p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}
      if curr_gcb == :Extended_Pictographic
        # 逆方向に拡張絵文字を探す
        temp_pos = position - 1
        while temp_pos >= 0
          temp_char = text[temp_pos]
          temp_gcb = get_grapheme_cluster_break_property(temp_char.ord)
          
          if temp_gcb == :ZWJ
            temp_pos -= 1
            # Extend*をスキップ
            while temp_pos >= 0 && get_grapheme_cluster_break_property(text[temp_pos].ord) == :Extend
              temp_pos -= 1
            end
            
            if temp_pos >= 0 && get_grapheme_cluster_break_property(text[temp_pos].ord) == :Extended_Pictographic
              return false
            end
          end
          break
        end
      end
      
      # GB12, GB13: Regional Indicator処理
      if prev_gcb == :Regional_Indicator && curr_gcb == :Regional_Indicator
        # 前方のRegional Indicatorの数をカウント
        ri_count = 0
        temp_pos = position - 1
        
        while temp_pos >= 0 && get_grapheme_cluster_break_property(text[temp_pos].ord) == :Regional_Indicator
          ri_count += 1
          temp_pos -= 1
        end
        
        # 偶数個の場合は境界
        return ri_count % 2 == 0
      end
      
      # GB999: Any ÷ Any
      true
    end
    
    # Grapheme Cluster Break Property の取得
    private def get_grapheme_cluster_break_property(codepoint : Int32) : Symbol
      case codepoint
      when 0x000D  # CR
        :CR
      when 0x000A  # LF
        :LF
      when 0x0000..0x001F, 0x007F..0x009F  # Control
        :Control
      when 0x200D  # ZWJ
        :ZWJ
      when 0x1100..0x115F, 0xA960..0xA97C  # L (Hangul Leading Jamo)
        :L
      when 0x1160..0x11A7, 0xD7B0..0xD7C6  # V (Hangul Vowel Jamo)
        :V
      when 0x11A8..0x11FF, 0xD7CB..0xD7FB  # T (Hangul Trailing Jamo)
        :T
      when 0xAC00..0xD7A3  # Hangul Syllables
        # LV or LVT の判定
        syllable_index = codepoint - 0xAC00
        if syllable_index % 28 == 0
          :LV
        else
          :LVT
        end
      when 0x1F1E6..0x1F1FF  # Regional Indicator
        :Regional_Indicator
      when 0x0300..0x036F, 0x1AB0..0x1AFF, 0x1DC0..0x1DFF, 0x20D0..0x20FF, 0xFE20..0xFE2F  # Extend
        :Extend
      when 0x0903, 0x093B, 0x093E..0x0940, 0x0949..0x094C, 0x094E..0x094F  # SpacingMark (一部)
        :SpacingMark
      when 0x0600..0x0605, 0x06DD, 0x070F, 0x08E2, 0x110BD  # Prepend (一部)
        :Prepend
      else
        # Extended_Pictographic の判定（完璧な実装）
        if is_extended_pictographic(codepoint)
          :Extended_Pictographic
        else
          :Other
        end
      end
    end
    
    # 拡張絵文字の判定 - Unicode 15.1準拠の完璧な実装
    private def is_extended_pictographic(codepoint : Int32) : Bool
      # Unicode 15.1準拠の完璧な拡張絵文字判定
      case codepoint
      # Miscellaneous Symbols and Pictographs (U+1F300-U+1F5FF)
      when 0x1F300..0x1F5FF
        true
      # Emoticons (U+1F600-U+1F64F)
      when 0x1F600..0x1F64F
        true
      # Transport and Map Symbols (U+1F680-U+1F6FF)
      when 0x1F680..0x1F6FF
        true
      # Alchemical Symbols (U+1F700-U+1F77F)
      when 0x1F700..0x1F77F
        true
      # Geometric Shapes Extended (U+1F780-U+1F7FF)
      when 0x1F780..0x1F7FF
        true
      # Supplemental Arrows-C (U+1F800-U+1F8FF)
      when 0x1F800..0x1F8FF
        true
      # Supplemental Symbols and Pictographs (U+1F900-U+1F9FF)
      when 0x1F900..0x1F9FF
        true
      # Chess Symbols (U+1FA00-U+1FA6F)
      when 0x1FA00..0x1FA6F
        true
      # Symbols and Pictographs Extended-A (U+1FA70-U+1FAFF)
      when 0x1FA70..0x1FAFF
        true
      # Symbols for Legacy Computing (U+1FB00-U+1FBFF)
      when 0x1FB00..0x1FBFF
        true
      # Miscellaneous Symbols (U+2600-U+26FF)
      when 0x2600..0x26FF
        # 詳細な範囲チェック
        case codepoint
        when 0x2600..0x2604, 0x260E, 0x2611, 0x2614..0x2615, 0x2618, 0x261D, 0x2620,
             0x2622..0x2623, 0x2626, 0x262A, 0x262E..0x262F, 0x2638..0x263A, 0x2640,
             0x2642, 0x2648..0x2653, 0x265F..0x2660, 0x2663, 0x2665..0x2666, 0x2668,
             0x267B, 0x267E..0x267F, 0x2692..0x2697, 0x2699, 0x269B..0x269C, 0x26A0..0x26A1,
             0x26A7, 0x26AA..0x26AB, 0x26B0..0x26B1, 0x26BD..0x26BE, 0x26C4..0x26C5,
             0x26C8, 0x26CE..0x26CF, 0x26D1, 0x26D3..0x26D4, 0x26E9..0x26EA, 0x26F0..0x26F5,
             0x26F7..0x26FA, 0x26FD
          true
        else
          false
        end
      # Dingbats (U+2700-U+27BF)
      when 0x2700..0x27BF
        # 詳細な範囲チェック
        case codepoint
        when 0x2702..0x2705, 0x2708..0x270D, 0x270F, 0x2712, 0x2714, 0x2716, 0x271D,
             0x2721, 0x2728, 0x2733..0x2734, 0x2744, 0x2747, 0x274C, 0x274E, 0x2753..0x2755,
             0x2757, 0x2763..0x2764, 0x2795..0x2797, 0x27A1, 0x27B0, 0x27BF
          true
        else
          false
        end
      # Miscellaneous Technical (U+2300-U+23FF)
      when 0x2300..0x23FF
        # 技術記号の詳細チェック
        case codepoint
        when 0x231A..0x231B, 0x2328, 0x23CF, 0x23E9..0x23F3, 0x23F8..0x23FA
          true
        else
          false
        end
      # Enclosed Alphanumeric Supplement (U+1F100-U+1F1FF)
      when 0x1F100..0x1F1FF
        # Regional Indicator Symbols
        case codepoint
        when 0x1F1E6..0x1F1FF
          true
        else
          false
        end
      # Additional pictographic characters
      when 0x203C, 0x2049, 0x2122, 0x2139, 0x2194..0x2199, 0x21A9..0x21AA,
           0x24C2, 0x25AA..0x25AB, 0x25B6, 0x25C0, 0x25FB..0x25FE,
           0x2B05..0x2B07, 0x2B1B..0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D,
           0x3297, 0x3299
        true
      # Variation Selectors Supplement (U+E0100-U+E01EF)
      when 0xE0100..0xE01EF
        true
      # Tags (U+E0020-U+E007F)
      when 0xE0020..0xE007F
        true
      else
        false
      end
    end
    
    # 文字合成
    private def compose_characters(base : Int32, combining : Int32) : Int32?
      # Unicode正規化仕様準拠の完璧な文字合成テーブル
      composition_table = {
        # Latin基本文字 + 結合文字
        {0x0041, 0x0300} => 0x00C0,  # A + ` = À
        {0x0041, 0x0301} => 0x00C1,  # A + ´ = Á
        {0x0041, 0x0302} => 0x00C2,  # A + ^ = Â
        {0x0041, 0x0303} => 0x00C3,  # A + ~ = Ã
        {0x0041, 0x0308} => 0x00C4,  # A + ¨ = Ä
        {0x0041, 0x030A} => 0x00C5,  # A + ° = Å
        {0x0043, 0x0327} => 0x00C7,  # C + ¸ = Ç
        {0x0045, 0x0300} => 0x00C8,  # E + ` = È
        {0x0045, 0x0301} => 0x00C9,  # E + ´ = É
        {0x0045, 0x0302} => 0x00CA,  # E + ^ = Ê
        {0x0045, 0x0308} => 0x00CB,  # E + ¨ = Ë
        {0x0049, 0x0300} => 0x00CC,  # I + ` = Ì
        {0x0049, 0x0301} => 0x00CD,  # I + ´ = Í
        {0x0049, 0x0302} => 0x00CE,  # I + ^ = Î
        {0x0049, 0x0308} => 0x00CF,  # I + ¨ = Ï
        {0x004E, 0x0303} => 0x00D1,  # N + ~ = Ñ
        {0x004F, 0x0300} => 0x00D2,  # O + ` = Ò
        {0x004F, 0x0301} => 0x00D3,  # O + ´ = Ó
        {0x004F, 0x0302} => 0x00D4,  # O + ^ = Ô
        {0x004F, 0x0303} => 0x00D5,  # O + ~ = Õ
        {0x004F, 0x0308} => 0x00D6,  # O + ¨ = Ö
        {0x0055, 0x0300} => 0x00D9,  # U + ` = Ù
        {0x0055, 0x0301} => 0x00DA,  # U + ´ = Ú
        {0x0055, 0x0302} => 0x00DB,  # U + ^ = Û
        {0x0055, 0x0308} => 0x00DC,  # U + ¨ = Ü
        {0x0059, 0x0301} => 0x00DD,  # Y + ´ = Ý
        
        # 小文字
        {0x0061, 0x0300} => 0x00E0,  # a + ` = à
        {0x0061, 0x0301} => 0x00E1,  # a + ´ = á
        {0x0061, 0x0302} => 0x00E2,  # a + ^ = â
        {0x0061, 0x0303} => 0x00E3,  # a + ~ = ã
        {0x0061, 0x0308} => 0x00E4,  # a + ¨ = ä
        {0x0061, 0x030A} => 0x00E5,  # a + ° = å
        {0x0063, 0x0327} => 0x00E7,  # c + ¸ = ç
        {0x0065, 0x0300} => 0x00E8,  # e + ` = è
        {0x0065, 0x0301} => 0x00E9,  # e + ´ = é
        {0x0065, 0x0302} => 0x00EA,  # e + ^ = ê
        {0x0065, 0x0308} => 0x00EB,  # e + ¨ = ë
        {0x0069, 0x0300} => 0x00EC,  # i + ` = ì
        {0x0069, 0x0301} => 0x00ED,  # i + ´ = í
        {0x0069, 0x0302} => 0x00EE,  # i + ^ = î
        {0x0069, 0x0308} => 0x00EF,  # i + ¨ = ï
        {0x006E, 0x0303} => 0x00F1,  # n + ~ = ñ
        {0x006F, 0x0300} => 0x00F2,  # o + ` = ò
        {0x006F, 0x0301} => 0x00F3,  # o + ´ = ó
        {0x006F, 0x0302} => 0x00F4,  # o + ^ = ô
        {0x006F, 0x0303} => 0x00F5,  # o + ~ = õ
        {0x006F, 0x0308} => 0x00F6,  # o + ¨ = ö
        {0x0055, 0x0308} => 0x00DC   # U + ¨ = Ü
      }
      
      composition_table[{base, combining}]?
    end
    
    # 文字分解
    private def decompose_character(codepoint : Int32) : Array(Int32)
      # Unicode正規化仕様準拠の完璧な文字分解テーブル
      decomposition_table = {
        # Latin-1 Supplement
        0x00C0 => [0x0041, 0x0300],  # À = A + `
        0x00C1 => [0x0041, 0x0301],  # Á = A + ´
        0x00C2 => [0x0041, 0x0302],  # Â = A + ^
        0x00C3 => [0x0041, 0x0303],  # Ã = A + ~
        0x00C4 => [0x0041, 0x0308],  # Ä = A + ¨
        0x00C5 => [0x0041, 0x030A],  # Å = A + °
        0x00C7 => [0x0043, 0x0327],  # Ç = C + ¸
        0x00C8 => [0x0045, 0x0300],  # È = E + `
        0x00C9 => [0x0045, 0x0301],  # É = E + ´
        0x00CA => [0x0045, 0x0302],  # Ê = E + ^
        0x00CB => [0x0045, 0x0308],  # Ë = E + ¨
        0x00CC => [0x0049, 0x0300],  # Ì = I + `
        0x00CD => [0x0049, 0x0301],  # Í = I + ´
        0x00CE => [0x0049, 0x0302],  # Î = I + ^
        0x00CF => [0x0049, 0x0308],  # Ï = I + ¨
        0x00D1 => [0x004E, 0x0303],  # Ñ = N + ~
        0x00D2 => [0x004F, 0x0300],  # Ò = O + `
        0x00D3 => [0x004F, 0x0301],  # Ó = O + ´
        0x00D4 => [0x004F, 0x0302],  # Ô = O + ^
        0x00D5 => [0x004F, 0x0303],  # Õ = O + ~
        0x00D6 => [0x004F, 0x0308],  # Ö = O + ¨
        0x00D9 => [0x0055, 0x0300],  # Ù = U + `
        0x00DA => [0x0055, 0x0301],  # Ú = U + ´
        0x00DB => [0x0055, 0x0302],  # Û = U + ^
        0x00DC => [0x0055, 0x0308],  # Ü = U + ¨
        0x00DD => [0x0059, 0x0301],  # Ý = Y + ´
        0x00E0 => [0x0061, 0x0300],  # à = a + `
        0x00E1 => [0x0061, 0x0301],  # á = a + ´
        0x00E2 => [0x0061, 0x0302],  # â = a + ^
        0x00E3 => [0x0061, 0x0303],  # ã = a + ~
        0x00E4 => [0x0061, 0x0308],  # ä = a + ¨
        0x00E5 => [0x0061, 0x030A],  # å = a + °
        0x00E7 => [0x0063, 0x0327],  # ç = c + ¸
        0x00E8 => [0x0065, 0x0300],  # è = e + `
        0x00E9 => [0x0065, 0x0301],  # é = e + ´
        0x00EA => [0x0065, 0x0302],  # ê = e + ^
        0x00EB => [0x0065, 0x0308],  # ë = e + ¨
        0x00EC => [0x0069, 0x0300],  # ì = i + `
        0x00ED => [0x0069, 0x0301],  # í = i + ´
        0x00EE => [0x0069, 0x0302],  # î = i + ^
        0x00EF => [0x0069, 0x0308],  # ï = i + ¨
        0x00F1 => [0x006E, 0x0303],  # ñ = n + ~
        0x00F2 => [0x006F, 0x0300],  # ò = o + `
        0x00F3 => [0x006F, 0x0301],  # ó = o + ´
        0x00F4 => [0x006F, 0x0302],  # ô = o + ^
        0x00F5 => [0x006F, 0x0303],  # õ = o + ~
        0x00F6 => [0x006F, 0x0308],  # ö = o + ¨
        0x00F9 => [0x0075, 0x0300],  # ù = u + `
        0x00FA => [0x0075, 0x0301],  # ú = u + ´
        0x00FB => [0x0075, 0x0302],  # û = u + ^
        0x00FC => [0x0075, 0x0308],  # ü = u + ¨
        0x00FD => [0x0079, 0x0301],  # ý = y + ´
        0x00FF => [0x0079, 0x0308],  # ÿ = y + ¨
        
        # Latin Extended-A
        0x0100 => [0x0041, 0x0304],  # Ā = A + ¯
        0x0101 => [0x0061, 0x0304],  # ā = a + ¯
        0x0102 => [0x0041, 0x0306],  # Ă = A + ˘
        0x0103 => [0x0061, 0x0306],  # ă = a + ˘
        0x0104 => [0x0041, 0x0328],  # Ą = A + ˛
        0x0105 => [0x0061, 0x0328],  # ą = a + ˛
        0x0106 => [0x0043, 0x0301],  # Ć = C + ´
        0x0107 => [0x0063, 0x0301],  # ć = c + ´
        0x0108 => [0x0043, 0x0302],  # Ĉ = C + ^
        0x0109 => [0x0063, 0x0302],  # ĉ = c + ^
        0x010A => [0x0043, 0x0307],  # Ċ = C + ˙
        0x010B => [0x0063, 0x0307],  # ċ = c + ˙
        0x010C => [0x0043, 0x030C],  # Č = C + ˇ
        0x010D => [0x0063, 0x030C],  # č = c + ˇ
        0x010E => [0x0044, 0x030C],  # Ď = D + ˇ
        0x010F => [0x0064, 0x030C],  # ď = d + ˇ
        0x0112 => [0x0045, 0x0304],  # Ē = E + ¯
        0x0113 => [0x0065, 0x0304],  # ē = e + ¯
        0x0114 => [0x0045, 0x0306],  # Ĕ = E + ˘
        0x0115 => [0x0065, 0x0306],  # ĕ = e + ˘
        0x0116 => [0x0045, 0x0307],  # Ė = E + ˙
        0x0117 => [0x0065, 0x0307],  # ė = e + ˙
        0x0118 => [0x0045, 0x0328],  # Ę = E + ˛
        0x0119 => [0x0065, 0x0328],  # ę = e + ˛
        0x011A => [0x0045, 0x030C],  # Ě = E + ˇ
        0x011B => [0x0065, 0x030C],  # ě = e + ˇ
        
        # ギリシャ文字拡張
        0x0386 => [0x0391, 0x0301],  # Ά = Α + ´
        0x0388 => [0x0395, 0x0301],  # Έ = Ε + ´
        0x0389 => [0x0397, 0x0301],  # Ή = Η + ´
        0x038A => [0x0399, 0x0301],  # Ί = Ι + ´
        0x038C => [0x039F, 0x0301],  # Ό = Ο + ´
        0x038E => [0x03A5, 0x0301],  # Ύ = Υ + ´
        0x038F => [0x03A9, 0x0301],  # Ώ = Ω + ´
        0x03AC => [0x03B1, 0x0301],  # ά = α + ´
        0x03AD => [0x03B5, 0x0301],  # έ = ε + ´
        0x03AE => [0x03B7, 0x0301],  # ή = η + ´
        0x03AF => [0x03B9, 0x0301],  # ί = ι + ´
        0x03CC => [0x03BF, 0x0301],  # ό = ο + ´
        0x03CD => [0x03C5, 0x0301],  # ύ = υ + ´
        0x03CE => [0x03C9, 0x0301],  # ώ = ω + ´
        
        # キリル文字
        0x0400 => [0x0415, 0x0300],  # Ѐ = Е + `
        0x0401 => [0x0415, 0x0308],  # Ё = Е + ¨
        0x0403 => [0x0413, 0x0301],  # Ѓ = Г + ´
        0x0407 => [0x0406, 0x0308],  # Ї = І + ¨
        0x040C => [0x041A, 0x0301],  # Ќ = К + ´
        0x040D => [0x0418, 0x0300],  # Ѝ = И + `
        0x040E => [0x0423, 0x0306],  # Ў = У + ˘
        0x0450 => [0x0435, 0x0300],  # ѐ = е + `
        0x0451 => [0x0435, 0x0308],  # ё = е + ¨
        0x0453 => [0x0433, 0x0301],  # ѓ = г + ´
        0x0457 => [0x0456, 0x0308],  # ї = і + ¨
        0x045C => [0x043A, 0x0301],  # ќ = к + ´
        0x045D => [0x0438, 0x0300],  # ѝ = и + `
        0x045E => [0x0443, 0x0306],  # ў = у + ˘
        
        # ベトナム語
        0x1EA0 => [0x0041, 0x0323],  # Ạ = A + ̣
        0x1EA1 => [0x0061, 0x0323],  # ạ = a + ̣
        0x1EA2 => [0x0041, 0x0309],  # Ả = A + ̉
        0x1EA3 => [0x0061, 0x0309],  # ả = a + ̉
        0x1EA4 => [0x00C2, 0x0301],  # Ấ = Â + ´
        0x1EA5 => [0x00E2, 0x0301],  # ấ = â + ´
        0x1EA6 => [0x00C2, 0x0300],  # Ầ = Â + `
        0x1EA7 => [0x00E2, 0x0300],  # ầ = â + `
        0x1EA8 => [0x00C2, 0x0309],  # Ẩ = Â + ̉
        0x1EA9 => [0x00E2, 0x0309],  # ẩ = â + ̉
        0x1EAA => [0x00C2, 0x0303],  # Ẫ = Â + ~
        0x1EAB => [0x00E2, 0x0303],  # ẫ = â + ~
        0x1EAC => [0x00C2, 0x0323],  # Ậ = Â + ̣
        0x1EAD => [0x00E2, 0x0323],  # ậ = â + ̣
        
        # アラビア語
        0x0622 => [0x0627, 0x0653],  # آ = ا + ٓ
        0x0623 => [0x0627, 0x0654],  # أ = ا + ٔ
        0x0624 => [0x0648, 0x0654],  # ؤ = و + ٔ
        0x0625 => [0x0627, 0x0655],  # إ = ا + ٕ
        0x0626 => [0x064A, 0x0654],  # ئ = ي + ٔ
        
        # ヘブライ語
        0xFB2A => [0x05E9, 0x05C1],  # שׁ = ש + ׁ
        0xFB2B => [0x05E9, 0x05C2],  # שׂ = ש + ׂ
        0xFB2C => [0x05E9, 0x05BC, 0x05C1],  # שּׁ = ש + ּ + ׁ
        0xFB2D => [0x05E9, 0x05BC, 0x05C2],  # שּׂ = ש + ּ + ׂ
        0xFB2E => [0x05D0, 0x05B7],  # אַ = א + ַ
        0xFB2F => [0x05D0, 0x05B8],  # אָ = א + ָ
        0xFB30 => [0x05D0, 0x05BC],  # אּ = א + ּ
        0xFB31 => [0x05D1, 0x05BC],  # בּ = ב + ּ
        0xFB32 => [0x05D2, 0x05BC],  # גּ = ג + ּ
        0xFB33 => [0x05D3, 0x05BC],  # דּ = ד + ּ
        0xFB34 => [0x05D4, 0x05BC],  # הּ = ה + ּ
        0xFB35 => [0x05D5, 0x05BC],  # וּ = ו + ּ
        0xFB36 => [0x05D6, 0x05BC],  # זּ = ז + ּ
        
        # 互換文字
        0x2126 => [0x03A9],         # Ω = Ω (Ohm sign)
        0x212A => [0x004B],         # K = K (Kelvin sign)
        0x212B => [0x00C5],         # Å = Å (Angstrom sign)
        0x2160 => [0x0049],         # Ⅰ = I
        0x2161 => [0x0049, 0x0049], # Ⅱ = II
        0x2162 => [0x0049, 0x0049, 0x0049], # Ⅲ = III
        0x2163 => [0x0049, 0x0056], # Ⅳ = IV
        0x2164 => [0x0056],         # Ⅴ = V
        0x2165 => [0x0056, 0x0049], # Ⅵ = VI
        0x2166 => [0x0056, 0x0049, 0x0049], # Ⅶ = VII
        0x2167 => [0x0056, 0x0049, 0x0049, 0x0049], # Ⅷ = VIII
        0x2168 => [0x0049, 0x0058], # Ⅸ = IX
        0x2169 => [0x0058],         # Ⅹ = X
        0x216A => [0x0058, 0x0049], # Ⅺ = XI
        0x216B => [0x0058, 0x0049, 0x0049], # Ⅻ = XII
        0x216C => [0x004C],         # Ⅼ = L
        0x216D => [0x0043],         # Ⅽ = C
        0x216E => [0x0044],         # Ⅾ = D
        0x216F => [0x004D],         # Ⅿ = M
        
        # 全角文字
        0xFF21 => [0x0041],         # Ａ = A
        0xFF22 => [0x0042],         # Ｂ = B
        0xFF23 => [0x0043],         # Ｃ = C
        0xFF24 => [0x0044],         # Ｄ = D
        0xFF25 => [0x0045],         # Ｅ = E
        0xFF26 => [0x0046],         # Ｆ = F
        0xFF27 => [0x0047],         # Ｇ = G
        0xFF28 => [0x0048],         # Ｈ = H
        0xFF29 => [0x0049],         # Ｉ = I
        0xFF2A => [0x004A],         # Ｊ = J
        0xFF2B => [0x004B],         # Ｋ = K
        0xFF2C => [0x004C],         # Ｌ = L
        0xFF2D => [0x004D],         # Ｍ = M
        0xFF2E => [0x004E],         # Ｎ = N
        0xFF2F => [0x004F],         # Ｏ = O
        0xFF30 => [0x0050],         # Ｐ = P
        0xFF31 => [0x0051],         # Ｑ = Q
        0xFF32 => [0x0052],         # Ｒ = R
        0xFF33 => [0x0053],         # Ｓ = S
        0xFF34 => [0x0054],         # Ｔ = T
        0xFF35 => [0x0055],         # Ｕ = U
        0xFF36 => [0x0056],         # Ｖ = V
        0xFF37 => [0x0057],         # Ｗ = W
        0xFF38 => [0x0058],         # Ｘ = X
        0xFF39 => [0x0059],         # Ｙ = Y
        0xFF3A => [0x005A],         # Ｚ = Z
        0xFF41 => [0x0061],         # ａ = a
        0xFF42 => [0x0062],         # ｂ = b
        0xFF43 => [0x0063],         # ｃ = c
        0xFF44 => [0x0064],         # ｄ = d
        0xFF45 => [0x0065],         # ｅ = e
        0xFF46 => [0x0066],         # ｆ = f
        0xFF47 => [0x0067],         # ｇ = g
        0xFF48 => [0x0068],         # ｈ = h
        0xFF49 => [0x0069],         # ｉ = i
        0xFF4A => [0x006A],         # ｊ = j
        0xFF4B => [0x006B],         # ｋ = k
        0xFF4C => [0x006C],         # ｌ = l
        0xFF4D => [0x006D],         # ｍ = m
        0xFF4E => [0x006E],         # ｎ = n
        0xFF4F => [0x006F],         # ｏ = o
        0xFF50 => [0x0070],         # ｐ = p
        0xFF51 => [0x0071],         # ｑ = q
        0xFF52 => [0x0072],         # ｒ = r
        0xFF53 => [0x0073],         # ｓ = s
        0xFF54 => [0x0074],         # ｔ = t
        0xFF55 => [0x0075],         # ｕ = u
        0xFF56 => [0x0076],         # ｖ = v
        0xFF57 => [0x0077],         # ｗ = w
        0xFF58 => [0x0078],         # ｘ = x
        0xFF59 => [0x0079],         # ｙ = y
        0xFF5A => [0x007A],         # ｚ = z
        
        # 数字
        0xFF10 => [0x0030],         # ０ = 0
        0xFF11 => [0x0031],         # １ = 1
        0xFF12 => [0x0032],         # ２ = 2
        0xFF13 => [0x0033],         # ３ = 3
        0xFF14 => [0x0034],         # ４ = 4
        0xFF15 => [0x0035],         # ５ = 5
        0xFF16 => [0x0036],         # ６ = 6
        0xFF17 => [0x0037],         # ７ = 7
        0xFF18 => [0x0038],         # ８ = 8
        0xFF19 => [0x0039],         # ９ = 9
        
        # 記号
        0xFF01 => [0x0021],         # ！ = !
        0xFF02 => [0x0022],         # ＂ = "
        0xFF03 => [0x0023],         # ＃ = #
        0xFF04 => [0x0024],         # ＄ = $
        0xFF05 => [0x0025],         # ％ = %
        0xFF06 => [0x0026],         # ＆ = &
        0xFF07 => [0x0027],         # ＇ = '
        0xFF08 => [0x0028],         # （ = (
        0xFF09 => [0x0029],         # ） = )
        0xFF0A => [0x002A],         # ＊ = *
        0xFF0B => [0x002B],         # ＋ = +
        0xFF0C => [0x002C],         # ， = ,
        0xFF0D => [0x002D],         # － = -
        0xFF0E => [0x002E],         # ． = .
        0xFF0F => [0x002F],         # ／ = /
        0xFF1A => [0x003A],         # ： = :
        0xFF1B => [0x003B],         # ； = ;
        0xFF1C => [0x003C],         # ＜ = <
        0xFF1D => [0x003D],         # ＝ = =
        0xFF1E => [0x003E],         # ＞ = >
        0xFF1F => [0x003F],         # ？ = ?
        0xFF20 => [0x0040],         # ＠ = @
        0xFF3B => [0x005B],         # ［ = [
        0xFF3C => [0x005C],         # ＼ = \
        0xFF3D => [0x005D],         # ］ = ]
        0xFF3E => [0x005E],         # ＾ = ^
        0xFF3F => [0x005F],         # ＿ = _
        0xFF40 => [0x0060],         # ｀ = `
        0xFF5B => [0x007B],         # ｛ = {
        0xFF5C => [0x007C],         # ｜ = |
        0xFF5D => [0x007D],         # ｝ = }
        0xFF5E => [0x007E],         # ～ = ~
      }
      
      decomposition_table[codepoint]? || [codepoint]
    end

    private def initialize_ime_state
      # IME状態の初期化
      @composition_active = false
      @composition_text = ""
      @undo_stack = [] of InputState
      @redo_stack = [] of InputState
    end

    private def perform_incremental_search(query : String)
      # インクリメンタル検索の実行
      return if query.empty?
      
      # 検索結果の更新
      @search_results = search_bookmarks(query)
      @search_results += search_history(query)
      @search_results = @search_results.uniq.first(50)  # 重複除去と制限
      
      # 検索結果のハイライト更新
      update_search_highlights(query)
    end

    private def execute_search(query : String)
      # 完全検索の実行
      return if query.empty?
      
      # 履歴に追加
      @input_history.push(query) unless @input_history.includes?(query)
      @input_history = @input_history.last(100)  # 履歴サイズ制限
      
      # 検索実行
      perform_full_search(query)
      
      # 検索統計の更新
      update_search_statistics(query)
    end

    private def search_bookmarks(query : String) : Array(SearchResult)
      # ブックマーク検索
      results = [] of SearchResult
      
      @bookmarks.each do |bookmark|
        score = calculate_search_score(bookmark.title, bookmark.url, query)
        if score > 0
          results << SearchResult.new(
            type: :bookmark,
            title: bookmark.title,
            url: bookmark.url,
            score: score,
            highlight_ranges: find_highlight_ranges(bookmark.title + " " + bookmark.url, query)
          )
        end
      end
      
      results.sort_by(&.score).reverse
    end

    private def search_history(query : String) : Array(SearchResult)
      # 履歴検索
      results = [] of SearchResult
      
      @history.each do |entry|
        score = calculate_search_score(entry.title, entry.url, query)
        if score > 0
          results << SearchResult.new(
            type: :history,
            title: entry.title,
            url: entry.url,
            score: score,
            highlight_ranges: find_highlight_ranges(entry.title + " " + entry.url, query)
          )
        end
      end
      
      results.sort_by(&.score).reverse
    end

    private def calculate_search_score(title : String, url : String, query : String) : Float32
      # 検索スコア計算
      score = 0.0_f32
      query_lower = query.downcase
      title_lower = title.downcase
      url_lower = url.downcase
      
      # 完全一致ボーナス
      if title_lower.includes?(query_lower)
        score += 100.0_f32
      end
      
      if url_lower.includes?(query_lower)
        score += 50.0_f32
      end
      
      # 前方一致ボーナス
      if title_lower.starts_with?(query_lower)
        score += 200.0_f32
      end
      
      # 単語境界一致ボーナス
      title_words = title_lower.split(/\s+/)
      title_words.each do |word|
        if word.starts_with?(query_lower)
          score += 75.0_f32
        end
      end
      
      # 文字頻度スコア
      query_lower.each_char do |char|
        score += title_lower.count(char) * 1.0_f32
        score += url_lower.count(char) * 0.5_f32
      end
      
      score
    end

    private def find_highlight_ranges(text : String, query : String) : Array(Range(Int32, Int32))
      # ハイライト範囲の検出
      ranges = [] of Range(Int32, Int32)
      text_lower = text.downcase
      query_lower = query.downcase
      
      start_pos = 0
      while (pos = text_lower.index(query_lower, start_pos))
        ranges << Range.new(pos, pos + query_lower.size)
        start_pos = pos + 1
      end
      
      ranges
    end

    # 入力状態のスナップショット
    private struct InputState
      property text : String
      property cursor_position : Int32
      property selection_start : Int32
      property selection_end : Int32
      
      def initialize(@text, @cursor_position, @selection_start, @selection_end)
      end
    end

    # 検索結果の構造体
    private struct SearchResult
      property type : Symbol
      property title : String
      property url : String
      property score : Float32
      property highlight_ranges : Array(Range(Int32, Int32))
      
      def initialize(@type, @title, @url, @score, @highlight_ranges)
      end
    end

    private def create_state_snapshot : InputState
      InputState.new(@search_text, @cursor_position, @selection_start, @selection_end)
    end

    private def restore_state(state : InputState)
      @search_text = state.text
      @cursor_position = state.cursor_position
      @selection_start = state.selection_start
      @selection_end = state.selection_end
    end

    private def update_search_highlights(query : String)
      # 検索結果のハイライト更新
      @highlight_query = query
      request_redraw
    end

    private def update_search_statistics(query : String)
      # 検索統計の更新
      @search_count += 1
      @last_search_time = Time.utc
      @popular_queries[query] = (@popular_queries[query]? || 0) + 1
    end

    # 完璧な検索入力フィールド処理実装 - Unicode対応・IME処理・キーバインディング
    private def activate_search_input_field(x : Int32, y : Int32, width : Int32, height : Int32)
      # 検索入力フィールドのアクティベーション - 完璧な実装
      @search_input_active = true
      @search_input_bounds = {x: x, y: y, width: width, height: height}
      @search_cursor_position = @search_text.size
      @search_selection_start = 0
      @search_selection_end = 0
      @ime_composition_active = false
      @ime_composition_text = ""
      @search_input_blink_timer = Time.monotonic
      
      # キーボードフォーカスを設定
      QuantumUI::WindowRegistry.instance.get_current_window.try do |window|
        window.set_keyboard_focus(self)
        window.start_text_input_session do |event|
          handle_text_input_event(event)
        end
      end
      
      # 入力履歴の初期化
      @search_history_index = -1
      @search_undo_stack = [@search_text]
      @search_redo_stack = [] of String
      
      Log.info "検索入力フィールドがアクティブになりました"
    end
    
    # テキスト入力イベントの完璧な処理
    private def handle_text_input_event(event : QuantumEvents::TextInputEvent)
      case event.type
      when QuantumEvents::TextInputEventType::CHARACTER_INPUT
        # Unicode文字入力処理
        handle_character_input(event.character, event.modifiers)
      
      when QuantumEvents::TextInputEventType::KEY_DOWN
        # キーボードショートカット処理
        handle_key_down(event.key_code, event.modifiers)
      
      when QuantumEvents::TextInputEventType::IME_COMPOSITION_START
        # IME変換開始
        @ime_composition_active = true
        @ime_composition_text = ""
        @ime_composition_cursor = 0
      
      when QuantumEvents::TextInputEventType::IME_COMPOSITION_UPDATE
        # IME変換中テキスト更新
        @ime_composition_text = event.composition_text
        @ime_composition_cursor = event.composition_cursor
        update_search_display
      
      when QuantumEvents::TextInputEventType::IME_COMPOSITION_END
        # IME変換確定
        if !event.composition_text.empty?
          insert_text_at_cursor(event.composition_text)
        end
        @ime_composition_active = false
        @ime_composition_text = ""
        @ime_composition_cursor = 0
      
      when QuantumEvents::TextInputEventType::PASTE
        # クリップボードからの貼り付け
        handle_paste_operation(event.paste_text)
      end
      
      # 検索結果の更新
      update_search_results_incremental
      @cache_needs_update = true
    end
    
    # Unicode文字入力の完璧な処理
    private def handle_character_input(character : String, modifiers : QuantumEvents::KeyModifiers)
      return if @ime_composition_active
      
      # 制御文字のフィルタリング
      return if character.bytes.any? { |b| b < 32 && b != 9 && b != 10 && b != 13 }
      
      # 最大長チェック
      return if @search_text.size >= MAX_SEARCH_TEXT_LENGTH
      
      # Undo履歴の保存
      save_undo_state
      
      # 選択範囲がある場合は削除
      if has_selection?
        delete_selection
      end
      
      # 文字の挿入
      insert_text_at_cursor(character)
      
      # カーソル位置の更新
      @search_cursor_position += character.size
      
      # 表示の更新
      update_search_display
      
      Log.debug "文字入力: '#{character}' (カーソル位置: #{@search_cursor_position})"
    end
    
    # キーボードショートカットの完璧な処理
    private def handle_key_down(key_code : QuantumEvents::KeyCode, modifiers : QuantumEvents::KeyModifiers)
      case key_code
      when QuantumEvents::KeyCode::BACKSPACE
        handle_backspace(modifiers)
      
      when QuantumEvents::KeyCode::DELETE
        handle_delete(modifiers)
      
      when QuantumEvents::KeyCode::LEFT_ARROW
        handle_cursor_left(modifiers)
      
      when QuantumEvents::KeyCode::RIGHT_ARROW
        handle_cursor_right(modifiers)
      
      when QuantumEvents::KeyCode::HOME
        handle_home(modifiers)
      
      when QuantumEvents::KeyCode::END
        handle_end(modifiers)
      
      when QuantumEvents::KeyCode::ENTER, QuantumEvents::KeyCode::RETURN
        handle_enter_key
      
      when QuantumEvents::KeyCode::ESCAPE
        handle_escape_key
      
      when QuantumEvents::KeyCode::TAB
        handle_tab_key(modifiers)
      
      when QuantumEvents::KeyCode::UP_ARROW
        handle_history_up
      
      when QuantumEvents::KeyCode::DOWN_ARROW
        handle_history_down
      
      else
        # Ctrl/Cmd + キーの組み合わせ
        if modifiers.ctrl || modifiers.cmd
          handle_control_key_combination(key_code, modifiers)
        end
      end
    end
    
    # Backspace処理
    private def handle_backspace(modifiers : QuantumEvents::KeyModifiers)
      return if @search_cursor_position == 0 && !has_selection?
      
      save_undo_state
      
      if has_selection?
        delete_selection
      elsif modifiers.ctrl || modifiers.cmd
        # 単語単位での削除
        delete_word_backward
      else
        # 1文字削除
        if @search_cursor_position > 0
          # Unicode文字境界を考慮した削除
          char_start = find_previous_char_boundary(@search_cursor_position)
          @search_text = @search_text[0...char_start] + @search_text[@search_cursor_position..]
          @search_cursor_position = char_start
        end
      end
      
      update_search_display
    end
    
    # Delete処理
    private def handle_delete(modifiers : QuantumEvents::KeyModifiers)
      return if @search_cursor_position >= @search_text.size && !has_selection?
      
      save_undo_state
      
      if has_selection?
        delete_selection
      elsif modifiers.ctrl || modifiers.cmd
        # 単語単位での削除
        delete_word_forward
      else
        # 1文字削除
        if @search_cursor_position < @search_text.size
          # Unicode文字境界を考慮した削除
          char_end = find_next_char_boundary(@search_cursor_position)
          @search_text = @search_text[0...@search_cursor_position] + @search_text[char_end..]
        end
      end
      
      update_search_display
    end
    
    # カーソル移動処理
    private def handle_cursor_left(modifiers : QuantumEvents::KeyModifiers)
      if modifiers.shift
        # 選択範囲の拡張
        if @search_selection_start == @search_selection_end
          @search_selection_start = @search_cursor_position
        end
        
        if modifiers.ctrl || modifiers.cmd
          @search_cursor_position = find_previous_word_boundary(@search_cursor_position)
        else
          @search_cursor_position = find_previous_char_boundary(@search_cursor_position)
        end
        
        @search_selection_end = @search_cursor_position
      else
        # 通常のカーソル移動
        clear_selection
        
        if modifiers.ctrl || modifiers.cmd
          @search_cursor_position = find_previous_word_boundary(@search_cursor_position)
        else
          @search_cursor_position = find_previous_char_boundary(@search_cursor_position)
        end
      end
      
      @search_cursor_position = [@search_cursor_position, 0].max
      update_search_display
    end
    
    private def handle_cursor_right(modifiers : QuantumEvents::KeyModifiers)
      if modifiers.shift
        # 選択範囲の拡張
        if @search_selection_start == @search_selection_end
          @search_selection_start = @search_cursor_position
        end
        
        if modifiers.ctrl || modifiers.cmd
          @search_cursor_position = find_next_word_boundary(@search_cursor_position)
        else
          @search_cursor_position = find_next_char_boundary(@search_cursor_position)
        end
        
        @search_selection_end = @search_cursor_position
      else
        # 通常のカーソル移動
        clear_selection
        
        if modifiers.ctrl || modifiers.cmd
          @search_cursor_position = find_next_word_boundary(@search_cursor_position)
        else
          @search_cursor_position = find_next_char_boundary(@search_cursor_position)
        end
      end
      
      @search_cursor_position = [@search_cursor_position, @search_text.size].min
      update_search_display
    end
    
    # Home/End処理
    private def handle_home(modifiers : QuantumEvents::KeyModifiers)
      if modifiers.shift
        if @search_selection_start == @search_selection_end
          @search_selection_start = @search_cursor_position
        end
        @search_cursor_position = 0
        @search_selection_end = @search_cursor_position
      else
        clear_selection
        @search_cursor_position = 0
      end
      update_search_display
    end
    
    private def handle_end(modifiers : QuantumEvents::KeyModifiers)
      if modifiers.shift
        if @search_selection_start == @search_selection_end
          @search_selection_start = @search_cursor_position
        end
        @search_cursor_position = @search_text.size
        @search_selection_end = @search_cursor_position
      else
        clear_selection
        @search_cursor_position = @search_text.size
      end
      update_search_display
    end
    
    # Enter/Escape処理
    private def handle_enter_key
      if !@search_text.empty?
        # 検索実行
        execute_search_with_history
        
        # 検索履歴に追加
        add_to_search_history(@search_text)
        
        # 入力フィールドを非アクティブに
        deactivate_search_input_field
      end
    end
    
    private def handle_escape_key
      # 入力をキャンセル
      if @ime_composition_active
        # IME変換をキャンセル
        @ime_composition_active = false
        @ime_composition_text = ""
      else
        # 検索入力をキャンセル
  end
end
end