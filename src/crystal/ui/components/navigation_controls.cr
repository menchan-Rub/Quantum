require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../quantum_core/page_manager" # PageManagerを利用
require "../../events/**"
require "../../utils/logger"
require "../../utils/animation"
require "../../utils/math_utils"
require "../../quantum_core/performance"
require "../../utils/interaction_tracker"

module QuantumUI
  # ナビゲーションコントロールコンポーネント
  # 高度なアニメーション、インテリジェント機能、最適化されたレンダリングを備えた
  # 世界最高峰のブラウザナビゲーション実装
  # @since 1.0.0
  # @author QuantumTeam
  class NavigationControls < Component
    # ボタン種別
    enum ButtonType
      BACK          # 戻るボタン
      FORWARD       # 進むボタン
      RELOAD        # 再読み込みボタン
      STOP          # 読み込み中止ボタン
      HOME          # ホームボタン
      MENU          # メニューボタン
      READER_MODE   # リーダーモードボタン
      TRANSLATE     # 翻訳ボタン
      SHARE         # 共有ボタン
      BOOKMARK      # ブックマークボタン
      PRINT         # 印刷ボタン
      FIND          # ページ内検索ボタン
      DOWNLOADS     # ダウンロードボタン
    end
    
    # 表示スタイル
    enum DisplayStyle
      STANDARD      # 標準表示（すべてのボタン）
      COMPACT       # コンパクト表示（主要ボタンのみ）
      MINIMAL       # 最小表示（必須ボタンのみ）
      TOUCH         # タッチ操作向け（大きなボタン）
      CUSTOM        # カスタム配置
    end

    # アニメーションタイプ
    enum AnimationType
      NONE          # アニメーションなし
      FADE          # フェードイン/アウト
      SCALE         # 拡大/縮小
      BOUNCE        # バウンス効果
      RIPPLE        # リップル効果
      SLIDE         # スライドイン/アウト
      PULSE         # 明滅効果
      COMBINED      # 複合アニメーション
    end

    # ボタン状態を管理する拡張構造体
    private struct NavButton
      property type : ButtonType
      property enabled : Bool
      property active : Bool
      property visible : Bool
      property tooltip : String
      property shortcut : String?
      property position : Tuple(Int32, Int32)
      property size : Tuple(Int32, Int32)
      property icon : String
      property label : String?
      property color : UInt32?
      property hover_color : UInt32?
      property active_color : UInt32?
      property disabled_color : UInt32?
      property texture_cache : Concave::Texture?
      property animation_state : Float64
      property animation_type : AnimationType
      property last_click_time : Time?
      property long_press_started : Bool
      property ripple_position : Tuple(Int32, Int32)?
      property ripple_progress : Float64
      property badge_count : Int32?
      property badge_text : String?
      property badge_color : UInt32?
      property custom_render : Proc(Concave::Window, Int32, Int32, Int32, Int32, Nil)?
      property press_progress : Float64
      property usage_count : Int32
      property last_usage_time : Time
      property priority : Int32
      property hover_scale : Float64
      property active_scale : Float64
      
      def initialize(@type, @enabled = true, @active = false, @visible = true,
                    @tooltip = "", @shortcut = nil, @position = {0, 0}, @size = {32, 32},
                    @icon = "", @label = nil, @color = nil, @hover_color = nil,
                    @active_color = nil, @disabled_color = nil, @texture_cache = nil,
                    @animation_state = 0.0, @animation_type = AnimationType::FADE,
                    @last_click_time = nil, @long_press_started = false,
                    @ripple_position = nil, @ripple_progress = 0.0,
                    @badge_count = nil, @badge_text = nil, @badge_color = nil,
                    @custom_render = nil, @press_progress = 0.0, @usage_count = 0,
                    @last_usage_time = Time.monotonic, @priority = 0,
                    @hover_scale = 1.05, @active_scale = 0.95)
      end
      
      # 新しいプロパティを設定したボタンのコピーを作成
      def copy_with(**props)
        NavButton.new(
          type: props[:type]? || @type,
          enabled: props[:enabled]? || @enabled,
          active: props[:active]? || @active,
          visible: props[:visible]? || @visible,
          tooltip: props[:tooltip]? || @tooltip,
          shortcut: props[:shortcut]? || @shortcut,
          position: props[:position]? || @position,
          size: props[:size]? || @size,
          icon: props[:icon]? || @icon,
          label: props[:label]? || @label,
          color: props[:color]? || @color,
          hover_color: props[:hover_color]? || @hover_color,
          active_color: props[:active_color]? || @active_color,
          disabled_color: props[:disabled_color]? || @disabled_color,
          texture_cache: props[:texture_cache]? || @texture_cache,
          animation_state: props[:animation_state]? || @animation_state,
          animation_type: props[:animation_type]? || @animation_type,
          last_click_time: props[:last_click_time]? || @last_click_time,
          long_press_started: props[:long_press_started]? || @long_press_started,
          ripple_position: props[:ripple_position]? || @ripple_position,
          ripple_progress: props[:ripple_progress]? || @ripple_progress,
          badge_count: props[:badge_count]? || @badge_count,
          badge_text: props[:badge_text]? || @badge_text,
          badge_color: props[:badge_color]? || @badge_color,
          custom_render: props[:custom_render]? || @custom_render,
          press_progress: props[:press_progress]? || @press_progress,
          usage_count: props[:usage_count]? || @usage_count,
          last_usage_time: props[:last_usage_time]? || @last_usage_time,
          priority: props[:priority]? || @priority,
          hover_scale: props[:hover_scale]? || @hover_scale,
          active_scale: props[:active_scale]? || @active_scale
        )
      end
      
      # アニメーション状態をリセット
      def reset_animation
        @animation_state = 0.0
        @ripple_progress = 0.0
        @ripple_position = nil
        @press_progress = 0.0
      end
      
      # 使用回数を増加
      def increment_usage
        @usage_count += 1
        @last_usage_time = Time.monotonic
      end
      
      # ボタンの有効状態を設定
      def set_enabled(enabled : Bool)
        if @enabled != enabled
          @enabled = enabled
          @texture_cache = nil # キャッシュを無効化
        end
      end
      
      # ボタンの表示状態を設定
      def set_visible(visible : Bool)
        if @visible != visible
          @visible = visible
          reset_animation
        end
      end
      
      # リップルエフェクトを開始
      def start_ripple(x : Int32, y : Int32)
        @ripple_position = {x, y}
        @ripple_progress = 0.0
      end
      
      # プレスアニメーションを開始
      def start_press_animation
        @press_progress = 1.0
      end
      
      # バッジカウントを設定
      def set_badge_count(count : Int32?)
        @badge_count = count
        if count && count > 0
          @badge_text = count > 99 ? "99+" : count.to_s
        else
          @badge_text = nil
        end
      end
      
      # バッジテキストを設定
      def set_badge_text(text : String?)
        @badge_text = text
        @badge_count = nil
      end
      
      # 表示中かつ画面内に完全に収まっている場合にtrueを返す
      def fully_visible?(x_offset : Int32, panel_width : Int32) : Bool
        @visible && @position[0] + @size[0] <= panel_width - x_offset && @position[0] >= x_offset
      end
    end

    # ボタングループを管理する構造体
    private struct ButtonGroup
      property id : Symbol
      property buttons : Array(ButtonType)
      property visible : Bool
      property separator_before : Bool
      property separator_after : Bool
      property layout : Symbol # :horizontal, :vertical, :grid
      property position : Tuple(Int32, Int32)
      property size : Tuple(Int32, Int32)
      property spacing : Int32
      property animation_state : Float64
      property background_color : UInt32?
      
      def initialize(@id, @buttons = [] of ButtonType, @visible = true,
                    @separator_before = false, @separator_after = false,
                    @layout = :horizontal, @position = {0, 0}, @size = {0, 0},
                    @spacing = 2, @animation_state = 0.0, @background_color = nil)
      end
    end

    # ボタンのメタデータ管理
    private struct ButtonMetadata
      property icon : String
      property label : String
      property tooltip : String
      property shortcut : String?
      property default_visible : Bool
      property priority : Int32
      property group : Symbol
      
      def initialize(@icon, @label, @tooltip, @shortcut = nil, @default_visible = true, @priority = 0, @group = :main)
      end
    end

    # コンポーネント全体の状態
    @buttons : Array(NavButton)
    @button_groups : Array(ButtonGroup)
    @button_bounds : Array(Tuple(Int32, Int32, Int32, Int32))
    @button_metadata : Hash(ButtonType, ButtonMetadata)
    @display_style : DisplayStyle
    @animation_type : AnimationType
    @panel_background_color : UInt32?
    @theme_radius : Int32
    
    # パフォーマンス最適化
    @button_cache : Hash(String, Concave::Texture)
    @render_cache : Concave::Texture?
    @background_cache : Concave::Texture?
    @button_layout_changed : Bool = true
    @cache_key : String = ""
    @cache_ttl : Time?
    @performance_metrics : QuantumCore::PerformanceMetrics
    @last_render_time : Float64 = 0.0
    
    # アニメーションと視覚効果
    @animation_frame : Int32
    @animation_timer : Time
    @fade_animator : Animation::Animator
    @ripple_animator : Animation::Animator
    @pulse_animator : Animation::Animator
    @animation_manager : Animation::AnimationManager
    @animations_active : Bool = false
    @visual_effects_enabled : Bool = true
    @hover_fade_speed : Float64 = 0.15
    @press_animation_speed : Float64 = 0.25
    @adaptive_animations : Bool = true
    
    # インタラクション追跡
    @hover_button : ButtonType?
    @active_button : ButtonType?
    @long_press_timer : Time?
    @long_press_button : Int32?
    @button_usage_stats : Hash(ButtonType, Int32)
    @interaction_tracker : InteractionTracker
    @adaptive_layout : Bool = true
    @last_mouse_position : Tuple(Int32, Int32) = {0, 0}
    
    # ツールチップと通知
    @tooltip_visible : Bool = false
    @tooltip_text : String = ""
    @tooltip_position : Tuple(Int32, Int32) = {0, 0}
    @tooltip_timer : Time?
    @tooltip_fade : Float64 = 0.0
    @tooltip_width : Int32 = 0
    @tooltip_height : Int32 = 0
    
    # 機能状態
    @reader_mode_available : Bool = false
    @page_is_translatable : Bool = false
    @page_loading : Bool = false
    @page_has_history : Bool = false
    @page_has_forward_history : Bool = false
    @context_menu : ContextMenu?
    @current_page_url : String = ""
    @current_page_id : String = ""
    @history_preview_visible : Bool = false
    @history_preview_items : Array(String) = [] of String
    
    # カスタマイズと設定
    @custom_layout : Hash(ButtonType, Tuple(Int32, Int32))? # ボタンの位置をカスタマイズ
    @custom_button_order : Array(ButtonType)? # ボタンの順序をカスタマイズ
    @button_size : Int32
    @button_spacing : Int32
    @auto_hide_buttons : Bool
    @show_labels : Bool
    @show_tooltips : Bool
    @show_shortcuts : Bool
    @vibration_feedback : Bool
    @haptic_feedback_enabled : Bool = false
    
    # アクセシビリティ
    @keyboard_navigation_active : Bool = false
    @keyboard_focused_button : Int32 = -1
    @high_contrast_mode : Bool = false
    
    # 開発関連
    @debug_mode : Bool = false
    @render_count : Int32 = 0

    # @param config [QuantumCore::UIConfig] UI設定
    # @param core [QuantumCore::Engine] コアエンジン
    # @param theme [ThemeEngine] テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      # 基本設定の初期化
      @buttons = [] of NavButton
      @button_groups = [] of ButtonGroup
      @button_bounds = [] of Tuple(Int32, Int32, Int32, Int32)
      @button_metadata = setup_button_metadata
      @button_cache = {} of String => Concave::Texture
      @animation_frame = 0
      @animation_timer = Time.monotonic
      @button_usage_stats = {} of ButtonType => Int32
      @theme_radius = (@theme.font_size * 0.25).to_i
      @performance_metrics = QuantumCore::PerformanceMetrics.new
      @interaction_tracker = InteractionTracker.new
      
      # 設定から表示スタイルを設定
      @display_style = if @config.compact_navigation?
                        DisplayStyle::COMPACT
                      elsif @config.minimal_ui?
                        DisplayStyle::MINIMAL
                      elsif @config.touch_optimized?
                        DisplayStyle::TOUCH
                      else
                        DisplayStyle::STANDARD
                      end
      
      # 設定からアニメーションタイプを設定
      @animation_type = if !@config.enable_animations?
                         AnimationType::NONE
                       elsif @config.reduced_motion?
                         AnimationType::FADE
                       else
                         AnimationType::COMBINED
                       end
      
      # ボタンサイズの決定
      @button_size = case @display_style
                     when .TOUCH?     then 44
                     when .COMPACT?   then 28
                     when .MINIMAL?   then 24
                     else 32 # STANDARD
                     end
      
      # ボタン間の間隔を設定
      @button_spacing = case @display_style
                        when .TOUCH?     then 8
                        when .COMPACT?   then 2
                        when .MINIMAL?   then 1
                        else 4 # STANDARD
                        end
      
      # アニメーターの初期化
      @animation_manager = Animation::AnimationManager.new
      
      # フェードアニメーション
      @fade_animator = Animation::Animator.new(
        duration: 0.25,
        easing: Animation::EasingFunctions::CubicEaseOut.new
      )
      
      # リップルアニメーション
      @ripple_animator = Animation::Animator.new(
        duration: 0.6,
        easing: Animation::EasingFunctions::QuadraticEaseOut.new
      )
      
      # パルスアニメーション
      @pulse_animator = Animation::Animator.new(
        duration: 1.0,
        repeat: true,
        easing: Animation::EasingFunctions::SineEaseInOut.new
      )
      
      # UI設定から各種オプションを初期化
      @auto_hide_buttons = @config.auto_hide_buttons? || false
      @show_labels = @config.show_navigation_labels? || false
      @show_tooltips = @config.show_tooltips? || true
      @show_shortcuts = @config.show_shortcuts? || true
      @visual_effects_enabled = @config.enable_visual_effects? || true
      @vibration_feedback = @config.enable_vibration_feedback? || false
      @haptic_feedback_enabled = @config.enable_haptic_feedback? || false
      @high_contrast_mode = @config.high_contrast_mode? || false
      @debug_mode = @config.debug_mode? || false
      
      # ボタンとイベントリスナーのセットアップ
      setup_buttons
      setup_button_groups
      setup_event_listeners
      
      # アニメーションの開始
      start_animations if @animation_type != AnimationType::NONE
      
      Log.info "NavigationControls initialized with style: #{@display_style}, animations: #{@animation_type}, button size: #{@button_size}px"
    end

    # ボタンのメタデータをセットアップ
    private def setup_button_metadata : Hash(ButtonType, ButtonMetadata)
      {
        ButtonType::BACK => ButtonMetadata.new(
          icon: "◀", 
          label: "戻る", 
          tooltip: "前のページに戻る", 
          shortcut: "Alt+←",
          default_visible: true,
          priority: 100,
          group: :navigation
        ),
        ButtonType::FORWARD => ButtonMetadata.new(
          icon: "▶", 
          label: "進む", 
          tooltip: "次のページに進む", 
          shortcut: "Alt+→",
          default_visible: true,
          priority: 90,
          group: :navigation
        ),
        ButtonType::RELOAD => ButtonMetadata.new(
          icon: "⟳", 
          label: "再読込", 
          tooltip: "ページを再読み込み", 
          shortcut: "F5",
          default_visible: true,
          priority: 80,
          group: :navigation
        ),
        ButtonType::STOP => ButtonMetadata.new(
          icon: "✕", 
          label: "中止", 
          tooltip: "読み込みを中止", 
          shortcut: "Esc",
          default_visible: false,
          priority: 80,
          group: :navigation
        ),
        ButtonType::HOME => ButtonMetadata.new(
          icon: "🏠", 
          label: "ホーム", 
          tooltip: "ホームページに移動", 
          shortcut: "Alt+Home",
          default_visible: true,
          priority: 70,
          group: :navigation
        ),
        ButtonType::MENU => ButtonMetadata.new(
          icon: "☰", 
          label: "メニュー", 
          tooltip: "ブラウザメニューを開く",
          default_visible: true,
          priority: 20,
          group: :system
        ),
        ButtonType::READER_MODE => ButtonMetadata.new(
          icon: "📖", 
          label: "リーダー", 
          tooltip: "リーダーモードで表示", 
          shortcut: "Alt+R",
          default_visible: @display_style != DisplayStyle::MINIMAL,
          priority: 50,
          group: :features
        ),
        ButtonType::TRANSLATE => ButtonMetadata.new(
          icon: "🌐", 
          label: "翻訳", 
          tooltip: "ページを翻訳", 
          shortcut: "Alt+T",
          default_visible: @display_style != DisplayStyle::MINIMAL,
          priority: 40,
          group: :features
        ),
        ButtonType::SHARE => ButtonMetadata.new(
          icon: "↗️", 
          label: "共有", 
          tooltip: "ページを共有",
          default_visible: @display_style == DisplayStyle::STANDARD,
          priority: 30,
          group: :features
        ),
        ButtonType::BOOKMARK => ButtonMetadata.new(
          icon: "★", 
          label: "ブックマーク", 
          tooltip: "このページをブックマーク", 
          shortcut: "Ctrl+D",
          default_visible: @display_style != DisplayStyle::MINIMAL,
          priority: 60,
          group: :features
        ),
        ButtonType::PRINT => ButtonMetadata.new(
          icon: "🖨️", 
          label: "印刷", 
          tooltip: "ページを印刷", 
          shortcut: "Ctrl+P",
          default_visible: @display_style == DisplayStyle::STANDARD,
          priority: 25,
          group: :features
        ),
        ButtonType::FIND => ButtonMetadata.new(
          icon: "🔍", 
          label: "検索", 
          tooltip: "ページ内検索", 
          shortcut: "Ctrl+F",
          default_visible: @display_style != DisplayStyle::MINIMAL,
          priority: 35,
          group: :features
        ),
        ButtonType::DOWNLOADS => ButtonMetadata.new(
          icon: "📥", 
          label: "ダウンロード", 
          tooltip: "ダウンロード管理", 
          shortcut: "Ctrl+J",
          default_visible: @display_style != DisplayStyle::MINIMAL,
          priority: 45,
          group: :system
        )
      }
    end

    # イベントリスナーをセットアップ
    private def setup_event_listeners
      # ページナビゲーション更新イベント
      @core.subscribe(Events::PageHistoryUpdated) do |event|
        # ページヒストリー状態を更新
        @page_has_history = event.has_back_history
        @page_has_forward_history = event.has_forward_history
        
        # 戻るボタンと進むボタンの状態を更新
        update_navigation_buttons
        
        # キャッシュを無効化
        invalidate_cache
      end
      
      # ページ読み込み開始イベント
      @core.subscribe(Events::PageLoadStarted) do |event|
        # 読み込み状態を更新
        @page_loading = true
        
        # 再読み込みボタンを停止ボタンに切り替え
        toggle_reload_stop_buttons(true)
        
        # 現在のページ情報を更新
        @current_page_url = event.url || ""
        @current_page_id = event.page_id || ""
        
        # キャッシュを無効化
        invalidate_cache
      end
      
      # ページ読み込み完了イベント
      @core.subscribe(Events::PageLoadFinished) do |event|
        # 読み込み状態を更新
        @page_loading = false
        
        # 停止ボタンを再読み込みボタンに切り替え
        toggle_reload_stop_buttons(false)
        
        # リーダーモードの利用可能性をチェック
        @reader_mode_available = event.reader_mode_available || false
        
        # 翻訳の利用可能性をチェック
        @page_is_translatable = event.is_translatable || false
        
        # リーダーモードボタンと翻訳ボタンの状態を更新
        update_feature_buttons
        
        # キャッシュを無効化
        invalidate_cache
      end
      
      # ブックマーク状態更新イベント
      @core.subscribe(Events::BookmarkStatusChanged) do |event|
        # 現在のページIDとイベントのページIDが一致する場合のみ処理
        if @current_page_id == event.page_id
          # ブックマークボタンの状態を更新
          update_bookmark_button(event.is_bookmarked)
        end
      end
      
      # ダウンロードカウンター更新イベント
      @core.subscribe(Events::DownloadsCounterUpdated) do |event|
        # ダウンロードボタンのバッジを更新
        update_downloads_badge(event.active_count)
      end
      
      # テーマ変更イベント
      @core.subscribe(Events::ThemeChanged) do |event|
        # カラーを更新
        update_button_colors
        
        # キャッシュを完全に再生成
        clear_cache
      end
      
      # UI設定変更イベント
      @core.subscribe(Events::UIConfigChanged) do |event|
        # 設定に基づいて表示スタイルを更新
        update_display_style
        
        # キャッシュを完全に再生成
        clear_cache
      end
      
      # 共有メニュー表示イベント
      @core.subscribe(Events::ShareMenuRequested) do |event|
        # 共有ボタンの位置に基づいてメニューを表示
        show_share_menu if get_button_by_type(ButtonType::SHARE)
      end
    end
    
    # 再読み込み/停止ボタンの切り替え
    private def toggle_reload_stop_buttons(loading : Bool)
      reload_button = find_button_by_type(ButtonType::RELOAD)
      stop_button = find_button_by_type(ButtonType::STOP)
      
      return unless reload_button && stop_button
      
      if loading
        # 読み込み中は停止ボタンを表示、再読み込みボタンを非表示
        reload_button.set_visible(false)
        stop_button.set_visible(true)
      else
        # 読み込み完了時は再読み込みボタンを表示、停止ボタンを非表示
        reload_button.set_visible(true)
        stop_button.set_visible(false)
      end
      
      # レイアウトの更新を強制
      @button_layout_changed = true
    end
    
    # 戻る/進むボタンの状態を更新
    private def update_navigation_buttons
      back_button = find_button_by_type(ButtonType::BACK)
      forward_button = find_button_by_type(ButtonType::FORWARD)
      
      if back_button
        back_button.set_enabled(@page_has_history)
      end
      
      if forward_button
        forward_button.set_enabled(@page_has_forward_history)
      end
    end
    
    # リーダーモードと翻訳ボタンの状態を更新
    private def update_feature_buttons
      reader_button = find_button_by_type(ButtonType::READER_MODE)
      translate_button = find_button_by_type(ButtonType::TRANSLATE)
      
      if reader_button
        reader_button.set_enabled(@reader_mode_available)
      end
      
      if translate_button
        translate_button.set_enabled(@page_is_translatable)
      end
    end
    
    # ブックマークボタンの状態を更新
    private def update_bookmark_button(is_bookmarked : Bool)
      bookmark_button = find_button_by_type(ButtonType::BOOKMARK)
      return unless bookmark_button
      
      # ブックマーク状態に応じてアイコンと色を変更
      if is_bookmarked
        bookmark_button.icon = "★"
        bookmark_button.active = true
        bookmark_button.color = @theme.accent_color
      else
        bookmark_button.icon = "☆"
        bookmark_button.active = false
        bookmark_button.color = @theme.text_color
      end
      
      # テクスチャキャッシュを無効化
      bookmark_button.texture_cache = nil
    end
    
    # ダウンロードボタンのバッジを更新
    private def update_downloads_badge(count : Int32)
      downloads_button = find_button_by_type(ButtonType::DOWNLOADS)
      return unless downloads_button
      
      # アクティブなダウンロードがある場合のみバッジを表示
      if count > 0
        downloads_button.set_badge_count(count)
        downloads_button.badge_color = @theme.highlight_color
        
        # ダウンロード中はパルスアニメーションを開始
        if @animation_type != AnimationType::NONE
          downloads_button.animation_type = AnimationType::PULSE
        end
      else
        downloads_button.badge_count = nil
        
        # パルスアニメーションを停止
        if downloads_button.animation_type == AnimationType::PULSE
          downloads_button.animation_type = @animation_type
          downloads_button.reset_animation
        end
      end
      
      # テクスチャキャッシュを無効化
      downloads_button.texture_cache = nil
    end
    
    # ボタンのカラーを更新
    private def update_button_colors
      @buttons.each do |button|
        button.color = @theme.text_color
        button.hover_color = @theme.highlight_color
        button.active_color = @theme.accent_color
        button.disabled_color = @theme.disabled_color
        
        # アクティブなボタン（ブックマークなど）は特殊な色を適用
        if button.active
          button.color = @theme.accent_color
        end
        
        # テクスチャキャッシュを無効化
        button.texture_cache = nil
      end
    end
    
    # 表示スタイルを更新
    private def update_display_style
      # 設定から新しい表示スタイルを取得
      new_style = if @config.compact_navigation?
                    DisplayStyle::COMPACT
                  elsif @config.minimal_ui?
                    DisplayStyle::MINIMAL
                  elsif @config.touch_optimized?
                    DisplayStyle::TOUCH
                  else
                    DisplayStyle::STANDARD
                  end
      
      # スタイルが変更された場合のみ更新処理
      if new_style != @display_style
        @display_style = new_style
        
        # ボタンサイズの更新
        @button_size = case @display_style
                       when .TOUCH?     then 44
                       when .COMPACT?   then 28
                       when .MINIMAL?   then 24
                       else 32 # STANDARD
                       end
        
        # ボタン間の間隔を更新
        @button_spacing = case @display_style
                          when .TOUCH?     then 8
                          when .COMPACT?   then 2
                          when .MINIMAL?   then 1
                          else 4 # STANDARD
                          end
        
        # ボタンの可視性を更新
        update_button_visibility
        
        # グループの可視性を更新
        @button_groups.each do |group|
          group.visible = @display_style != DisplayStyle::MINIMAL || group.id == :navigation
        end
        
        # ボタンのサイズを更新
        @buttons.each do |button|
          button.size = {@button_size, @button_size}
        end
        
        # レイアウト更新を強制
        @button_layout_changed = true
      end
    end
    
    # 表示スタイルに基づいてボタンの可視性を更新
    private def update_button_visibility
      @buttons.each do |button|
        metadata = @button_metadata[button.type]
        
        visible = case @display_style
                  when .MINIMAL?
                    # 最小表示モードでは優先度が高いボタンのみ表示
                    metadata.priority >= 80
                  when .COMPACT?
                    # コンパクト表示モードでは中優先度以上のボタンを表示
                    metadata.priority >= 50
                  when .TOUCH?
                    # タッチ表示モードではほとんどのボタンを表示
                    metadata.priority >= 30
                  else
                    # 標準表示モードではメタデータの設定に従う
                    metadata.default_visible
                  end
        
        # 特殊ケース: 停止ボタンは読み込み中のみ表示
        if button.type == ButtonType::STOP
          visible = visible && @page_loading
        end
        
        # 特殊ケース: 再読み込みボタンは読み込み中は非表示
        if button.type == ButtonType::RELOAD
          visible = visible && !@page_loading
        end
        
        button.set_visible(visible)
      end
    end
    
    # ボタンの状態を更新
    private def update_button_states
      # ナビゲーションボタンの状態を更新
      update_navigation_buttons
      
      # 機能ボタンの状態を更新
      update_feature_buttons
      
      # 再読み込み/停止ボタンの状態を更新
      toggle_reload_stop_buttons(@page_loading)
    end
    
    # 指定されたタイプのボタンを検索
    private def find_button_by_type(type : ButtonType) : NavButton?
      @buttons.find { |button| button.type == type }
    end
    
    # ボタンのレイアウトを計算
    private def calculate_button_layout(x : Int32, y : Int32, width : Int32, height : Int32)
      return unless @button_layout_changed
      
      current_x = x
      @button_bounds.clear
      
      # 各グループ内のボタンを配置
      @button_groups.each do |group|
        next unless group.visible
        
        group_start_x = current_x
        group_width = 0
        group_height = height
        
        # グループ内の可視ボタンをフィルタリング
        visible_buttons = group.buttons.compact_map do |button_type|
          @buttons.find { |b| b.type == button_type && b.visible }
        end
        
        # セパレーター用の余白を追加
        if group.separator_before && current_x > x
          current_x += @button_spacing * 2
          
          # セパレーターを描画するための境界を保存
          separator_x = current_x - @button_spacing
          @button_bounds << {-1, separator_x, y, separator_x, y + height}
        end
        
        # 各ボタンの位置を設定
        visible_buttons.each_with_index do |button, index|
          # カスタムレイアウトがある場合は使用
          if @custom_layout && @custom_layout.has_key?(button.type)
            pos = @custom_layout[button.type]
            button.position = pos
            @button_bounds << {button.type.to_i, pos[0], pos[1], pos[0] + button.size[0], pos[1] + button.size[1]}
            next
          end
          
          # 標準的なボタン配置
          button_x = current_x
          button_y = y + (height - button.size[1]) // 2
          button.position = {button_x, button_y}
          
          # ボタンの境界を保存
          @button_bounds << {button.type.to_i, button_x, button_y, button_x + button.size[0], button_y + button.size[1]}
          
          # X座標を更新
          current_x += button.size[0] + @button_spacing
          group_width += button.size[0] + (index < visible_buttons.size - 1 ? @button_spacing : 0)
        end
        
        # グループのサイズを保存
        group.size = {group_width, group_height}
        group.position = {group_start_x, y}
        
        # セパレーター用の余白を追加
        if group.separator_after && !visible_buttons.empty?
          current_x += @button_spacing
          
          # セパレーターを描画するための境界を保存
          separator_x = current_x - @button_spacing
          @button_bounds << {-2, separator_x, y, separator_x, y + height}
        end
      end
      
      # レイアウト計算完了
      @button_layout_changed = false
    end
    
    # アニメーションを開始
    private def start_animations
      @animations_active = true
      
      # フェードアニメーションのセットアップ
      @animation_manager.add(@fade_animator)
      
      # リップルアニメーションのセットアップ
      @animation_manager.add(@ripple_animator)
      
      # パルスアニメーションのセットアップ
      @animation_manager.add(@pulse_animator)
    end
    
    # アニメーションを更新
    private def update_animations(delta_time : Float64)
      return unless @animations_active
      
      # アニメーションマネージャーを更新
      @animation_manager.update(delta_time)
      
      # アニメーションの状態に基づいて再描画が必要かどうかを判断
      needs_redraw = false
      
      # 各ボタンのアニメーション状態を更新
      @buttons.each do |button|
        # ホバー状態のアニメーション
        if button.type == @hover_button
          button.animation_state = Math.min(button.animation_state + @hover_fade_speed, 1.0)
          needs_redraw = true
        elsif button.animation_state > 0
          button.animation_state = Math.max(button.animation_state - @hover_fade_speed, 0.0)
          needs_redraw = true
        end
        
        # プレスアニメーション状態を更新
        if button.press_progress > 0
          button.press_progress = Math.max(button.press_progress - @press_animation_speed, 0.0)
          needs_redraw = true
        end
        
        # リップルエフェクトの更新
        if button.ripple_position && button.ripple_progress < 1.0
          button.ripple_progress = Math.min(button.ripple_progress + 0.05, 1.0)
          needs_redraw = true
        elsif button.ripple_progress >= 1.0
          button.ripple_position = nil
          button.ripple_progress = 0.0
        end
      end
      
      # ツールチップのフェードアニメーション
      if @tooltip_visible && @tooltip_fade < 1.0
        @tooltip_fade = Math.min(@tooltip_fade + 0.1, 1.0)
        needs_redraw = true
      elsif !@tooltip_visible && @tooltip_fade > 0
        @tooltip_fade = Math.max(@tooltip_fade - 0.1, 0.0)
        needs_redraw = true
      end
      
      # 再描画が必要な場合はキャッシュを無効化
      invalidate_cache if needs_redraw
    end
    
    # キャッシュキーを生成
    private def generate_cache_key : String
      # ボタンの状態やレイアウトに基づいてキャッシュキーを生成
      keys = [] of String
      
      # 表示スタイルとサイズ
      keys << "style:#{@display_style}"
      keys << "size:#{@button_size}"
      
      # 各ボタンの状態
      @buttons.each do |button|
        next unless button.visible
        keys << "btn:#{button.type}:#{button.enabled}:#{button.active}:#{button.animation_state.round(2)}:#{button.press_progress.round(2)}"
        
        # バッジがある場合
        if button.badge_text
          keys << "badge:#{button.badge_text}"
        end
        
        # リップルエフェクトがある場合
        if button.ripple_position
          keys << "ripple:#{button.ripple_progress.round(2)}"
        end
      end
      
      # ホバー状態
      if @hover_button
        keys << "hover:#{@hover_button}"
      end
      
      # ツールチップ
      if @tooltip_visible
        keys << "tooltip:#{@tooltip_text}:#{@tooltip_fade.round(2)}"
      end
      
      # デバッグモード
      if @debug_mode
        keys << "debug:true"
      end
      
      keys.join(":")
    end
    
    # キャッシュを無効化
    private def invalidate_cache
      @render_cache = nil
      @cache_key = ""
    end
    
    # キャッシュをクリア
    private def clear_cache
      @render_cache = nil
      @background_cache = nil
      @cache_key = ""
      
      # ボタンテクスチャキャッシュをクリア
      @button_cache.clear
      
      # 各ボタンのテクスチャキャッシュをクリア
      @buttons.each do |button|
        button.texture_cache = nil
      end
    end
    
    # ナビゲーションアクションを実行
    private def execute_navigation_action(button_type : ButtonType)
      case button_type
      when .BACK?
        @core.navigate_back
        Log.info "NavigationControls: Back button clicked"
      when .FORWARD?
        @core.navigate_forward
        Log.info "NavigationControls: Forward button clicked"
      when .RELOAD?
        @core.reload_page
        Log.info "NavigationControls: Reload button clicked"
      when .STOP?
        @core.stop_loading
        Log.info "NavigationControls: Stop button clicked"
      when .HOME?
        @core.navigate_to_home
        Log.info "NavigationControls: Home button clicked"
      when .READER_MODE?
        toggle_reader_mode
        Log.info "NavigationControls: Reader mode button clicked"
      when .TRANSLATE?
        translate_page
        Log.info "NavigationControls: Translate button clicked"
      when .SHARE?
        show_share_menu
        Log.info "NavigationControls: Share button clicked"
      when .BOOKMARK?
        toggle_bookmark
        Log.info "NavigationControls: Bookmark button clicked"
      when .PRINT?
        print_page
        Log.info "NavigationControls: Print button clicked"
      when .FIND?
        show_find_in_page
        Log.info "NavigationControls: Find button clicked"
      when .DOWNLOADS?
        show_downloads
        Log.info "NavigationControls: Downloads button clicked"
      when .MENU?
        show_browser_menu
        Log.info "NavigationControls: Menu button clicked"
      end
      
      # 使用統計を更新
      if @button_usage_stats.has_key?(button_type)
        @button_usage_stats[button_type] += 1
      else
        @button_usage_stats[button_type] = 1
      end
      
      # 対応するボタンを取得
      button = find_button_by_type(button_type)
      if button
        # 使用回数を増加
        button.increment_usage
        
        # プレスアニメーションを開始
        button.start_press_animation
        
        # 触覚フィードバック
        if @haptic_feedback_enabled
          @core.emit_haptic_feedback(HapticFeedbackType::ButtonPress)
        end
      end
    end
    
    # リーダーモードを切り替え
    private def toggle_reader_mode
      @core.toggle_reader_mode
    end
    
    # ページを翻訳
    private def translate_page
      @core.show_translation_panel
    end
    
    # シェアメニューを表示
    private def show_share_menu
      share_button = find_button_by_type(ButtonType::SHARE)
      return unless share_button
      
      # ボタンの位置に基づいてメニューを表示
      button_bounds = share_button.position
      @core.show_share_menu(@current_page_url, button_bounds[0], button_bounds[1] + share_button.size[1])
    end
    
    # ブックマークを切り替え
    private def toggle_bookmark
      @core.toggle_bookmark(@current_page_id)
    end
    
    # ページを印刷
    private def print_page
      @core.print_page
    end
    
    # ページ内検索を表示
    private def show_find_in_page
      @core.show_find_in_page
    end
    
    # ダウンロード管理を表示
    private def show_downloads
      @core.show_downloads_panel
    end
    
    # ブラウザメニューを表示
    private def show_browser_menu
      menu_button = find_button_by_type(ButtonType::MENU)
      return unless menu_button
      
      # ボタンの位置に基づいてメニューを表示
      button_bounds = menu_button.position
      @core.show_browser_menu(button_bounds[0], button_bounds[1] + menu_button.size[1])
    end
    
    # ツールチップを表示
    private def show_tooltip(text : String, x : Int32, y : Int32)
      return unless @show_tooltips
      
      @tooltip_text = text
      @tooltip_position = {x, y}
      @tooltip_visible = true
      
      # ツールチップのサイズを計算
      @tooltip_width = (@theme.text_width(text) + 20).to_i
      @tooltip_height = (@theme.font_size + 16).to_i
      
      # タイマーをリセット
      @tooltip_timer = Time.monotonic
    end
    
    # ツールチップを非表示
    private def hide_tooltip
      @tooltip_visible = false
    end

    # ボタンの設定
    private def setup_buttons
      ButtonType.values.each do |type|
        next unless @button_metadata.has_key?(type)
        metadata = @button_metadata[type]
        
        # 表示モードに基づいてボタンの可視性を決定
        visible = case @display_style
                  when .MINIMAL?
                    # 最小表示モードでは優先度が高いボタンのみ表示
                    metadata.priority >= 80
                  when .COMPACT?
                    # コンパクト表示モードでは中優先度以上のボタンを表示
                    metadata.priority >= 50
                  when .TOUCH?
                    # タッチ表示モードではほとんどのボタンを表示
                    metadata.priority >= 30
                  else
                    # 標準表示モードではメタデータの設定に従う
                    metadata.default_visible
                  end
        
        # ボタンのスタイル設定
        color = @theme.text_color
        hover_color = @theme.highlight_color
        active_color = @theme.accent_color
        disabled_color = @theme.disabled_color
        
        # ボタンを作成し配列に追加
        @buttons << NavButton.new(
          type: type,
          enabled: true, # 初期状態では有効
          active: false,
          visible: visible,
          tooltip: metadata.tooltip,
          shortcut: metadata.shortcut,
          position: {0, 0}, # 位置は後でレイアウト調整
          size: {@button_size, @button_size},
          icon: metadata.icon,
          label: @show_labels ? metadata.label : nil,
          color: color,
          hover_color: hover_color,
          active_color: active_color,
          disabled_color: disabled_color,
          animation_type: @animation_type,
          priority: metadata.priority
        )
        
        # 使用統計の初期化
        @button_usage_stats[type] = 0
      end
      
      # 初期状態の設定
      update_button_states
      
      # レイアウトの更新を強制
      @button_layout_changed = true
    end

    # ボタングループをセットアップ
    private def setup_button_groups
      # ナビゲーショングループ
      @button_groups << ButtonGroup.new(
        id: :navigation,
        buttons: [ButtonType::BACK, ButtonType::FORWARD, ButtonType::RELOAD, ButtonType::STOP, ButtonType::HOME],
        separator_after: true
      )
      
      # 機能グループ
      @button_groups << ButtonGroup.new(
        id: :features,
        buttons: [ButtonType::READER_MODE, ButtonType::TRANSLATE, ButtonType::SHARE, ButtonType::BOOKMARK, ButtonType::PRINT, ButtonType::FIND],
        separator_after: true
      )
      
      # システムグループ
      @button_groups << ButtonGroup.new(
        id: :system,
        buttons: [ButtonType::DOWNLOADS, ButtonType::MENU]
      )
      
      # スタイルに基づいたグループの可視性を設定
      @button_groups.each do |group|
        group.visible = @display_style != DisplayStyle::MINIMAL || group.id == :navigation
      end
    end

    # ナビゲーションコントロールを描画する
    override def render(window : Concave::Window)
      return unless bounds = @bounds
      
      # パフォーマンス計測開始
      render_start = Time.monotonic
      @render_count += 1
      
      # レイアウトが変更された場合は再計算
      if @button_layout_changed
        calculate_button_layout(bounds[0], bounds[1], bounds[2], bounds[3])
      end
      
      # キャッシュキー生成
      current_cache_key = generate_cache_key
      
      # キャッシュヒットするかチェック
      cache_hit = !@render_cache.nil? && current_cache_key == @cache_key && 
                  (!@tooltip_visible || @tooltip_fade < 0.01)
      
      # キャッシュが有効なら使用
      if cache_hit
        window.draw_texture(@render_cache.not_nil!, x: bounds[0], y: bounds[1])
        @performance_metrics.record_cache_hit(:navigation_controls)
      else
        # キャッシュが無効なら新規描画
        @performance_metrics.record_cache_miss(:navigation_controls)
        @cache_key = current_cache_key
        
        # オフスクリーンテクスチャに描画
        texture = Concave::Texture.create_empty(bounds[2], bounds[3], Concave::PixelFormat::RGBA)
        texture.with_draw_target do |ctx|
          # 背景（透明）
          ctx.set_draw_color(0x00_00_00_00, 0.0)
          ctx.clear
          
          # パネル背景（オプション）
          if color = @panel_background_color
            ctx.set_draw_color(color, 0.9)
            ctx.fill_rounded_rect(x: 0, y: 0, width: bounds[2], height: bounds[3], radius: @theme_radius)
          end
          
          # ボタングループの背景を描画
          render_button_groups(ctx, bounds[0], bounds[1])
          
          # 各ボタンを描画
          @button_bounds.each_with_index do |btn_bounds, index|
            button_type = btn_bounds[0]
            
            # セパレータの描画
            if button_type < 0
              render_separator(ctx, btn_bounds[1], btn_bounds[2], btn_bounds[4])
              next
            end
            
            # 通常のボタン描画
            button_index = @buttons.index { |b| b.type.to_i == button_type }
            if button_index && button_index < @buttons.size
              render_button(
                ctx, 
                @buttons[button_index], 
                btn_bounds[1] - bounds[0], 
                btn_bounds[2] - bounds[1], 
                btn_bounds[3] - btn_bounds[1], 
                btn_bounds[4] - btn_bounds[2]
              )
            end
          end
          
          # デバッグモード時は追加情報を描画
          render_debug_overlay(ctx, bounds[2], bounds[3]) if @debug_mode
        end
        
        # 描画結果をキャッシュ
        @render_cache = texture
        window.draw_texture(texture, x: bounds[0], y: bounds[1])
      end
      
      # ツールチップの描画（キャッシュ対象外）
      render_tooltip(window) if @tooltip_visible || @tooltip_fade > 0.01
      
      # アニメーションを更新
      delta_time = (Time.monotonic - render_start).total_seconds
      update_animations(delta_time)
      
      # パフォーマンス測定終了
      @last_render_time = delta_time
      
      # 複雑さのトラッキング
      @performance_metrics.track_complexity(:navigation_controls, @buttons.count(&.visible))
    rescue ex
      Log.error "NavigationControls render failed", exception: ex
    end

    # ボタングループを描画
    private def render_button_groups(ctx : Concave::Window, offset_x : Int32, offset_y : Int32)
      @button_groups.each do |group|
        next unless group.visible
        next if group.size[0] <= 0 || group.size[1] <= 0
        
        # グループに背景色が設定されている場合のみ描画
        if color = group.background_color
          # グループ背景を描画
          x = group.position[0] - offset_x
          y = group.position[1] - offset_y
          w = group.size[0]
          h = group.size[1]
          
          # フェードアニメーション付きの背景
          alpha = group.animation_state
          ctx.set_draw_color(color, 0.1 + 0.1 * alpha)
          ctx.fill_rounded_rect(x: x, y: y, width: w, height: h, radius: @theme_radius)
        end
      end
    end

    # セパレータを描画
    private def render_separator(ctx : Concave::Window, x : Int32, y : Int32, height : Int32)
      # セパレータラインの描画
      ctx.set_draw_color(@theme.colors.separator, 0.3)
      ctx.draw_line(x, y + 4, x, y + height - 4)
    end

    # ボタンを描画
    private def render_button(ctx : Concave::Window, button : NavButton, x : Int32, y : Int32, width : Int32, height : Int32)
      return unless button.visible
      
      # カスタムレンダラーがある場合はそれを使用
      if custom_render = button.custom_render
        custom_render.call(ctx, x, y, width, height)
        return
      end
      
      # キャッシュキーの生成
      cache_key = "btn_#{button.type}_#{button.enabled}_#{button.active}_#{button.animation_state.round(2)}_#{button.press_progress.round(2)}_#{width}_#{height}"
      
      # ボタンテクスチャキャッシュをチェック
      if button.texture_cache.nil? || !@button_cache.has_key?(cache_key)
        # キャッシュミス: 新しくボタンをレンダリング
        texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
        
        texture.with_draw_target do |btn_ctx|
          # 背景透明化
          btn_ctx.set_draw_color(0x00_00_00_00, 0.0)
          btn_ctx.clear
          
          # ボタン状態に応じた色を選択
          color = if !button.enabled
                    button.disabled_color || @theme.colors.disabled
                  elsif button.active
                    button.active_color || @theme.colors.accent
                  elsif button.type == @hover_button
                    button.hover_color || @theme.colors.highlight
                  else
                    button.color || @theme.colors.foreground
                  end
          
          # ホバー/プレス状態の視覚効果
          hover_alpha = button.animation_state
          press_scale = 1.0 - (button.press_progress * 0.05)
          
          # ホバー状態の背景
          if hover_alpha > 0.01
            btn_ctx.set_draw_color(@theme.colors.hover_background, hover_alpha * 0.2)
            btn_ctx.fill_rounded_rect(
              x: 1, y: 1, 
              width: width - 2, height: height - 2, 
              radius: @theme_radius
            )
          end
          
          # アクティブ状態の背景
          if button.active
            btn_ctx.set_draw_color(@theme.colors.accent, 0.2)
            btn_ctx.fill_rounded_rect(
              x: 1, y: 1, 
              width: width - 2, height: height - 2, 
              radius: @theme_radius
            )
          end
          
          # アイコンを描画（プレス状態ではわずかに縮小）
          icon_size = (Math.min(width, height) * 0.6 * press_scale).to_i
          icon_x = (width - icon_size) / 2
          icon_y = (height - icon_size) / 2
          
          btn_ctx.set_draw_color(color, 1.0)
          btn_ctx.draw_text(
            button.icon, 
            x: icon_x, y: icon_y, 
            size: icon_size, 
            font: @theme.icon_font_family || @theme.font_family
          )
          
          # ラベルを描画（設定されている場合のみ）
          if label = button.label
            label_size = (@theme.font_size * 0.85).to_i
            label_width = btn_ctx.measure_text(label, size: label_size, font: @theme.font_family).x
            label_x = (width - label_width) / 2
            label_y = height - label_size - 4
            
            btn_ctx.set_draw_color(color, 0.9)
            btn_ctx.draw_text(
              label, 
              x: label_x, y: label_y, 
              size: label_size, 
              font: @theme.font_family
            )
          end
          
          # バッジを描画（設定されている場合のみ）
          if badge_text = button.badge_text
            badge_color = button.badge_color || @theme.colors.notification
            badge_size = badge_text.size > 1 ? 16 : 12
            badge_x = width - badge_size - 2
            badge_y = 2
            
            # バッジ背景
            btn_ctx.set_draw_color(badge_color, 1.0)
            btn_ctx.fill_circle(
              x: badge_x + badge_size / 2, 
              y: badge_y + badge_size / 2, 
              radius: badge_size / 2
            )
            
            # バッジテキスト
            btn_ctx.set_draw_color(@theme.colors.on_accent, 1.0)
            badge_text_size = (badge_size * 0.7).to_i
            badge_text_width = btn_ctx.measure_text(badge_text, size: badge_text_size, font: @theme.font_family).x
            badge_text_x = badge_x + (badge_size - badge_text_width) / 2
            badge_text_y = badge_y + (badge_size - badge_text_size) / 2
            
            btn_ctx.draw_text(
              badge_text, 
              x: badge_text_x, y: badge_text_y, 
              size: badge_text_size, 
              font: @theme.font_family
            )
          end
          
          # リップルエフェクト（クリック時）
          if ripple_pos = button.ripple_position
            ripple_x, ripple_y = ripple_pos
            ripple_progress = button.ripple_progress
            ripple_radius = (Math.sqrt(width * width + height * height) * ripple_progress).to_i
            
            btn_ctx.set_draw_color(color, 0.2 * (1.0 - ripple_progress))
            btn_ctx.fill_circle(x: ripple_x, y: ripple_y, radius: ripple_radius)
          end
        end
        
        # キャッシュに保存
        @button_cache[cache_key] = texture
        button.texture_cache = texture
      end
      
      # キャッシュされたボタンテクスチャを描画
      if texture = button.texture_cache || @button_cache[cache_key]?
        # ホバー時の拡大表示（オプション）
        scale = 1.0
        if button.type == @hover_button && @animation_type != AnimationType::NONE
          scale = 1.0 + (button.animation_state * 0.05)
        elsif button.press_progress > 0.01
          scale = 1.0 - (button.press_progress * 0.05)
        end
        
        if scale != 1.0
          # スケーリングを適用（中心を維持）
          scaled_width = (width * scale).to_i
          scaled_height = (height * scale).to_i
          scale_offset_x = (scaled_width - width) / 2
          scale_offset_y = (scaled_height - height) / 2
          
          ctx.draw_texture(
            texture, 
            x: x - scale_offset_x, 
            y: y - scale_offset_y, 
            width: scaled_width, 
            height: scaled_height
          )
        else
          # 標準描画
          ctx.draw_texture(texture, x: x, y: y)
        end
      end
    end

    # ツールチップを描画
    private def render_tooltip(window : Concave::Window)
      return unless @tooltip_text.size > 0
      
      # ツールチップが非表示状態でフェード中なら
      if !@tooltip_visible && @tooltip_fade <= 0.01
        return
      end
      
      alpha = @tooltip_visible ? @tooltip_fade : (1.0 - @tooltip_fade)
      return if alpha <= 0.01
      
      # ツールチップのサイズを取得または計算
      if @tooltip_width == 0 || @tooltip_height == 0
        text_size = window.measure_text(@tooltip_text, size: @theme.font_size, font: @theme.font_family)
        @tooltip_width = text_size.x.to_i + 20  # 余白を追加
        @tooltip_height = (@theme.font_size + 16).to_i
      end
      
      # ツールチップの位置を調整（画面外にならないように）
      x = @tooltip_position[0]
      y = @tooltip_position[1] + 22 # カーソルの下に表示
      
      # 画面の端を考慮
      if bounds = @bounds
        bounds_right = bounds[0] + bounds[2]
        
        # 右端をチェック
        if x + @tooltip_width > bounds_right
          x = bounds_right - @tooltip_width - 5
        end
        
        # 左端をチェック
        if x < bounds[0]
          x = bounds[0] + 5
        end
      end
      
      # ツールチップの背景
      window.set_draw_color(@theme.colors.tooltip_background, alpha * 0.9)
      window.fill_rounded_rect(x: x, y: y, width: @tooltip_width, height: @tooltip_height, radius: 4)
      
      # ツールチップの境界線
      window.set_draw_color(@theme.colors.tooltip_border, alpha * 0.3)
      window.draw_rounded_rect(x: x, y: y, width: @tooltip_width, height: @tooltip_height, radius: 4)
      
      # テキスト
      window.set_draw_color(@theme.colors.tooltip_text, alpha)
      text_x = x + 10
      text_y = y + (@tooltip_height - @theme.font_size) / 2
      window.draw_text(@tooltip_text, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
      
      # ショートカットキーがある場合は表示
      if @show_shortcuts && @tooltip_text.includes?(": ")
        parts = @tooltip_text.split(": ", 2)
        if parts.size > 1 && parts[1].size > 0
          # ショートカットを右寄せで表示
          shortcut_text = parts[1]
          shortcut_width = window.measure_text(shortcut_text, size: @theme.font_size, font: @theme.font_family).x
          shortcut_x = x + @tooltip_width - shortcut_width - 10
          window.set_draw_color(@theme.colors.accent, alpha)
          window.draw_text(shortcut_text, x: shortcut_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
        end
      end
    end

    # デバッグオーバーレイを描画
    private def render_debug_overlay(ctx : Concave::Window, width : Int32, height : Int32)
      # 基本情報
      debug_info = [
        "NavigationControls",
        "Render count: #{@render_count}",
        "Last render: #{(@last_render_time * 1000).round(2)}ms",
        "Buttons: #{@buttons.count(&.visible)}/#{@buttons.size}",
        "Cache hits: #{@performance_metrics.cache_hit_ratio(:navigation_controls).round(2) * 100}%"
      ]
      
      # 背景
      overlay_height = (@theme.font_size + 4) * debug_info.size + 10
      overlay_width = 180
      
      ctx.set_draw_color(0x00_00_00, 0.7)
      ctx.fill_rect(x: 10, y: height - overlay_height - 10, width: overlay_width, height: overlay_height)
      
      # テキスト
      ctx.set_draw_color(0xFF_FF_FF, 0.9)
      debug_info.each_with_index do |info, idx|
        y = height - overlay_height - 5 + idx * (@theme.font_size + 4)
        ctx.draw_text(info, x: 15, y: y, size: @theme.font_size, font: @theme.font_family)
      end
    end

    # アニメーションを開始
    private def start_animations
      @animations_active = true
      
      # 定期的にアニメーションを更新するためのタイマー
      spawn do
        last_time = Time.monotonic
        
        loop do
          # アニメーションが不要になったら終了
          break unless @animations_active
          
          current_time = Time.monotonic
          delta = (current_time - last_time).total_seconds
          last_time = current_time
          
          # アニメーションを更新
          if @animation_type != AnimationType::NONE
            needs_update = false
            
            # ボタンアニメーション状態の更新
            @buttons.each do |button|
              if button.type == @hover_button && button.animation_state < 1.0
                button.animation_state = Math.min(1.0, button.animation_state + @hover_fade_speed)
                needs_update = true
              elsif button.type != @hover_button && button.animation_state > 0.0
                button.animation_state = Math.max(0.0, button.animation_state - @hover_fade_speed)
                needs_update = true
              end
              
              # プレスアニメーションの更新
              if button.press_progress > 0.0
                button.press_progress = Math.max(0.0, button.press_progress - @press_animation_speed)
                needs_update = true
              end
              
              # リップルアニメーションの更新
              if button.ripple_position && button.ripple_progress < 1.0
                button.ripple_progress = Math.min(1.0, button.ripple_progress + 0.05)
                needs_update = true
              elsif button.ripple_progress >= 1.0
                button.ripple_position = nil
                button.ripple_progress = 0.0
              end
            end
            
            # ツールチップフェードの更新
            if @tooltip_visible && @tooltip_fade < 1.0
              @tooltip_fade = Math.min(1.0, @tooltip_fade + 0.1)
              needs_update = true
            elsif !@tooltip_visible && @tooltip_fade > 0.0
              @tooltip_fade = Math.max(0.0, @tooltip_fade - 0.1)
              needs_update = true
            end
            
            # 更新が必要な場合は再描画をリクエスト
            if needs_update
              # キャッシュを無効化
              invalidate_cache
              
              # 再描画をトリガー
              QuantumEvents::EventDispatcher.instance.publish(
                QuantumEvents::Event.new(
                  type: QuantumEvents::EventType::UI_REDRAW_REQUEST,
                  data: nil
                )
              )
            end
          end
          
          # フレームレートを制限
          sleep(1.0 / 60)
        end
      end
    end

    # マウスイベント処理
    override def handle_event(event : QuantumEvents::Event) : Bool
      case event.type
      when QuantumEvents::EventType::MOUSE_MOVE
        # マウスホバー処理
        return handle_mouse_move(event)
      when QuantumEvents::EventType::MOUSE_DOWN
        # マウスクリック処理
        return handle_mouse_down(event)
      when QuantumEvents::EventType::MOUSE_UP
        # マウスリリース処理
        return handle_mouse_up(event)
      when QuantumEvents::EventType::MOUSE_LEAVE
        # マウスが領域を離れた
        return handle_mouse_leave(event)
      end
      
      false
    end

    # マウス移動処理
    private def handle_mouse_move(event : QuantumEvents::Event) : Bool
      return false unless bounds = @bounds
      
      # 相対座標の計算
      x = event.mouse_x - bounds[0]
      y = event.mouse_y - bounds[1]
      
      # ボタン上にあるか確認
      hover_changed = false
      old_hover = @hover_button
      @hover_button = nil
      
      @button_bounds.each do |btn_bounds|
        btn_x = btn_bounds[1] - bounds[0]
        btn_y = btn_bounds[2] - bounds[1]
        btn_width = btn_bounds[3] - btn_bounds[1]
        btn_height = btn_bounds[4] - btn_bounds[2]
        
        if x >= btn_x && x < btn_x + btn_width && y >= btn_y && y < btn_y + btn_height
          btn_type = ButtonType.new(btn_bounds[0])
          button = find_button_by_type(btn_type)
          
          # ボタンが有効かつ表示中の場合のみホバー状態に
          if button && button.visible && button.enabled
            @hover_button = btn_type
            
            # ツールチップ表示
            if @show_tooltips && (!@tooltip_visible || @tooltip_text != button.tooltip)
              show_tooltip(button.tooltip, event.mouse_x, event.mouse_y)
            end
            
            hover_changed = (old_hover != @hover_button)
            break
          end
        end
      end
      
      # ホバー状態が変わった場合はキャッシュを無効化
      if hover_changed
        invalidate_cache
        
        # ホバー状態から外れた場合はツールチップを隠す
        if @hover_button.nil? && @tooltip_visible
          hide_tooltip
        end
      end
      
      # 長押し処理の更新
      if @long_press_button && @long_press_timer
        elapsed = (Time.monotonic - @long_press_timer.not_nil!).total_seconds
        if elapsed >= 0.5 # 0.5秒以上の長押しで実行
          button_index = @long_press_button.not_nil!
          if button_index < @buttons.size
            button = @buttons[button_index]
            if !button.long_press_started && button.enabled
              # 長押しアクションを実行
              show_navigation_context_menu(button_index, @last_mouse_position[0], @last_mouse_position[1])
              
              # フラグをセット（二重実行防止）
              button.long_press_started = true
            end
          end
        end
      end
      
      # マウス位置を記録
      @last_mouse_position = {event.mouse_x, event.mouse_y}
      
      # インタラクションの追跡
      @interaction_tracker.record_mouse_move
      
      hover_changed
    end

    # マウスダウン処理
    private def handle_mouse_down(event : QuantumEvents::Event) : Bool
      return false unless bounds = @bounds
      return false unless event.mouse_button == QuantumEvents::MouseButton::LEFT
      
      # 相対座標の計算
      x = event.mouse_x - bounds[0]
      y = event.mouse_y - bounds[1]
      
      # クリックされたボタンを特定
      clicked_button_index = -1
      clicked_button_type = nil
      
      @button_bounds.each_with_index do |btn_bounds, index|
        next if btn_bounds[0] < 0 # セパレータはスキップ
        
        btn_x = btn_bounds[1] - bounds[0]
        btn_y = btn_bounds[2] - bounds[1]
        btn_width = btn_bounds[3] - btn_bounds[1]
        btn_height = btn_bounds[4] - btn_bounds[2]
        
        if x >= btn_x && x < btn_x + btn_width && y >= btn_y && y < btn_y + btn_height
          button_index = @buttons.index { |b| b.type.to_i == btn_bounds[0] }
          if button_index && button_index < @buttons.size
            button = @buttons[button_index]
            if button.visible && button.enabled
              clicked_button_index = button_index
              clicked_button_type = button.type
              break
            end
          end
        end
      end
      
      # ボタンがクリックされた場合
      if clicked_button_index >= 0 && clicked_button_type
        button = @buttons[clicked_button_index]
        
        # クリック時間を記録
        button.last_click_time = Time.monotonic
        
        # プレスアニメーションを開始
        button.start_press_animation
        
        # リップルエフェクトを開始（マウス座標から）
        rel_x = event.mouse_x - (bounds[0] + button.position[0])
        rel_y = event.mouse_y - (bounds[1] + button.position[1])
        button.start_ripple(rel_x, rel_y)
        
        # 長押し検出用タイマーをセット
        @long_press_button = clicked_button_index
        @long_press_timer = Time.monotonic
        @active_button = clicked_button_type
        
        # キャッシュを無効化
        invalidate_cache
        
        return true
      end
      
      false
    end

    # マウスアップ処理
    private def handle_mouse_up(event : QuantumEvents::Event) : Bool
      # 長押しタイマーをクリア
      @long_press_timer = nil
      long_press_btn = @long_press_button
      @long_press_button = nil
      
      # アクティブボタンを取得
      active_type = @active_button
      @active_button = nil
      
      return false unless active_type
      return false unless bounds = @bounds
      
      # 相対座標の計算
      x = event.mouse_x - bounds[0]
      y = event.mouse_y - bounds[1]
      
      # リリースされたボタンを特定
      released_on_button = false
      
      @button_bounds.each do |btn_bounds|
        next if btn_bounds[0] < 0 # セパレータはスキップ
        next if ButtonType.new(btn_bounds[0]) != active_type
        
        btn_x = btn_bounds[1] - bounds[0]
        btn_y = btn_bounds[2] - bounds[1]
        btn_width = btn_bounds[3] - btn_bounds[1]
        btn_height = btn_bounds[4] - btn_bounds[2]
        
        if x >= btn_x && x < btn_x + btn_width && y >= btn_y && y < btn_y + btn_height
          released_on_button = true
          break
        end
      end
      
      # ボタン上でリリースされた場合のみアクションを実行
      if released_on_button && !@buttons[long_press_btn.not_nil!].long_press_started
        execute_navigation_action(active_type)
        
        # 触覚フィードバック
        if @haptic_feedback_enabled
          QuantumEvents::EventDispatcher.instance.publish(
            QuantumEvents::Event.new(
              type: QuantumEvents::EventType::HAPTIC_FEEDBACK,
              data: {
                strength: "medium",
                duration: 10
              }
            )
          )
        end
        
        return true
      end
      
      # 長押しフラグをリセット
      if long_press_btn && @buttons[long_press_btn]
        @buttons[long_press_btn].long_press_started = false
      end
      
      false
    end

    # マウスリーブ処理
    private def handle_mouse_leave(event : QuantumEvents::Event) : Bool
      # ホバー状態をクリア
      if @hover_button
        @hover_button = nil
        invalidate_cache
      end
      
      # ツールチップを隠す
      if @tooltip_visible
        hide_tooltip
      end
      
      # 長押しをキャンセル
      @long_press_timer = nil
      @long_press_button = nil
      
      # アクティブボタンをリセット
      @active_button = nil
      
      true
    end

    # コンポーネントのサイズ設定
    override def preferred_size : Tuple(Int32, Int32)
      # ボタンのレイアウトに基づいてサイズを計算
      total_width = 0
      max_height = 0
      
      @button_bounds.each do |bounds|
        button_right = bounds[3]
        button_bottom = bounds[4]
        
        total_width = Math.max(total_width, button_right)
        max_height = Math.max(max_height, button_bottom)
      end
      
      # 最低サイズを保証
      total_width = Math.max(total_width, 200)
      max_height = Math.max(max_height, @button_size)
      
      {total_width, max_height}
    end
  end
end 