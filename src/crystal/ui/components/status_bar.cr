# src/crystal/ui/components/status_bar.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"
require "../../quantum_core/performance"
require "../../utils/animation"

module QuantumUI
  # ステータスバーコンポーネント - ブラウザの下部に表示される情報バー
  # @since 1.0.0
  # @author QuantumTeam
  class StatusBar < Component
    # ステータスバーの表示モード
    enum DisplayMode
      NORMAL    # 通常表示（ステータステキストのみ）
      PROGRESS  # 進捗表示
      ERROR     # エラー表示
      WARNING   # 警告表示
      SUCCESS   # 成功通知表示
      INFO      # 情報通知表示
      CUSTOM    # カスタム表示（独自の色と動作）
    end
    
    # ステータスアイテムの構造体 - 右側に表示される固定情報要素
    private struct StatusItem
      include JSON::Serializable
      
      property id : Symbol
      property icon : String?
      property text : String
      property tooltip : String?
      property color : UInt32?
      property click_handler : Proc(Nil)?
      property double_click_handler : Proc(Nil)?
      property context_menu_handler : Proc(Array(ContextMenuItem))?
      property width : Int32
      property visible : Bool
      property badge_count : Int32?
      property badge_color : UInt32?
      property priority : Int32
      property animation : AnimationState?
      
      # アニメーション状態を管理する構造体
      struct AnimationState
        property active : Bool
        property start_time : Time
        property duration : Float64
        property type : Symbol # :pulse, :fade, :bounce, :flash
        
        def initialize(@type = :pulse, @duration = 1.0)
          @active = false
          @start_time = Time.monotonic
        end
        
        def start
          @active = true
          @start_time = Time.monotonic
        end
        
        def stop
          @active = false
        end
        
        def progress
          return 0.0 unless @active
          elapsed = (Time.monotonic - @start_time).total_seconds
          normalized = (elapsed % @duration) / @duration
          case @type
          when :pulse
            Math.sin(normalized * Math::PI * 2) * 0.5 + 0.5
          when :fade
            normalized
          when :bounce
            if normalized < 0.5
              4 * normalized * normalized * normalized
            else
              1 - ((-2 * normalized + 2) ** 3) / 2
            end
          when :flash
            normalized < 0.5 ? 1.0 : 0.0
          else
            normalized
          end
        end
      end
      
      def initialize(@id, @text, @icon = nil, @color = nil, @tooltip = nil, 
                    @click_handler = nil, @double_click_handler = nil, 
                    @context_menu_handler = nil, @width = 0, @visible = true, 
                    @badge_count = nil, @badge_color = nil, @priority = 0)
        @animation = nil
      end
      
      # アニメーション開始
      def start_animation(type : Symbol = :pulse, duration : Float64 = 1.0)
        @animation = AnimationState.new(type, duration)
        @animation.not_nil!.start
      end
      
      # アニメーション停止
      def stop_animation
        if anim = @animation
          anim.stop
        end
      end
      
      # アニメーション中かどうか
      def animating?
        if anim = @animation
          anim.active
        else
          false
        end
      end
    end

    # コンテキストメニュー項目
    record ContextMenuItem, 
      id : Symbol, 
      text : String, 
      icon : String? = nil, 
      shortcut : String? = nil, 
      handler : Proc(Nil)? = nil, 
      separator_before : Bool = false, 
      checked : Bool = false,
      disabled : Bool = false
    
    @status_text : String
    @progress : Float64?
    @active_tab_id : String?
    @display_mode : DisplayMode
    @mode_start_time : Time
    @mode_duration : Time::Span
    @status_items : Array(StatusItem)
    @hover_item_index : Int32?
    @active_item_index : Int32?
    @render_cache : Concave::Texture?
    @render_cache_key : String = ""
    @render_cache_expiry : Time?
    @cache_needs_update : Bool = true
    @fade_animation : Float64 = 1.0
    @animation_timer : Time
    @tooltip_text : String?
    @tooltip_position : Tuple(Int32, Int32)?
    @tooltip_visible : Bool = false
    @tooltip_fade : Float64 = 0.0
    @tooltip_width : Int32 = 0
    @tooltip_height : Int32 = 0
    @tooltip_timeout : Time?
    @last_mouse_position : Tuple(Int32, Int32) = {0, 0}
    @last_network_status : Tuple(Bool, Int32, Int32)?  # 接続状態、ping、速度
    @download_progress_items : Hash(String, Tuple(String, Float64, String)) = {} # id => {filename, progress, status}
    @context_menu : ContextMenu?
    @double_click_timer : Time?
    @double_click_item_id : Symbol?
    @double_click_threshold : Float64 = 0.3 # 秒
    @performance_metrics : QuantumCore::PerformanceMetrics
    @adaptive_cache_ttl : Float64 = 1.0 # キャッシュの有効期間（秒）
    @last_render_time : Float64 = 0.0
    @custom_color : UInt32? # カスタムモード用の色
    @notification_queue : Deque(Tuple(String, DisplayMode, Time::Span)) = Deque(Tuple(String, DisplayMode, Time::Span)).new
    @processing_notification : Bool = false
    @visible_items_limit : Int32 = 5 # 同時に表示するステータスアイテムの上限
    @progress_animation : Animation::Animator

    # @param config UI設定
    # @param core コアエンジン
    # @param theme テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @status_text = "準備完了"
      @progress = nil
      @display_mode = DisplayMode::NORMAL
      @mode_start_time = Time.monotonic
      @mode_duration = 0.seconds
      @animation_timer = Time.monotonic
      @performance_metrics = QuantumCore::PerformanceMetrics.new
      @status_items = setup_status_items
      @progress_animation = Animation::Animator.new(
        duration: 2.0,
        repeat: true,
        easing: Animation::EasingFunctions::LinearEasing.new
      )
      @progress_animation.start
      setup_event_listeners
    end

    # 初期ステータスアイテムのセットアップ
    private def setup_status_items : Array(StatusItem)
      [
        StatusItem.new(
          id: :connection_status,
          icon: "🔌",
          text: "接続済み",
          tooltip: "ネットワーク接続の状態と速度を表示します。クリックで詳細表示。",
          color: @theme.colors.success,
          width: 100,
          priority: 100,
          click_handler: ->{ show_network_diagnostics },
          context_menu_handler: ->{ network_context_menu_items }
        ),
        StatusItem.new(
          id: :downloads,
          icon: "📥",
          text: "0 件",
          tooltip: "ダウンロードマネージャー。クリックで表示。",
          width: 80,
          priority: 90,
          click_handler: ->{ toggle_downloads_panel },
          badge_count: 0,
          badge_color: @theme.colors.accent
        ),
        StatusItem.new(
          id: :security,
          icon: "🔒",
          text: "安全",
          tooltip: "現在のページのセキュリティ状態。クリックで詳細表示。",
          color: @theme.colors.success,
          width: 80,
          priority: 80,
          click_handler: ->{ show_security_info }
        ),
        StatusItem.new(
          id: :zoom,
          icon: "🔍",
          text: "100%",
          tooltip: "ページのズーム設定。クリックで調整メニューを表示。",
          width: 70,
          priority: 70,
          click_handler: ->{ show_zoom_menu },
          context_menu_handler: ->{ zoom_context_menu_items }
        ),
        StatusItem.new(
          id: :encoding,
          icon: "🌐",
          text: "UTF-8",
          tooltip: "ページの文字エンコーディング。クリックで変更。",
          width: 80,
          priority: 60,
          click_handler: ->{ show_encoding_menu }
        ),
        StatusItem.new(
          id: :adblocker,
          icon: "🛡️",
          text: "0",
          tooltip: "広告ブロッカーの状態。数字はブロックされた要素数を示します。",
          width: 70,
          priority: 50,
          visible: true,
          click_handler: ->{ toggle_adblocker }
        ),
        StatusItem.new(
          id: :memory_usage,
          icon: "📊",
          text: "0MB",
          tooltip: "メモリ使用量。クリックでガベージコレクションを実行。",
          width: 90,
          priority: 40,
          visible: @config.debug_mode,
          click_handler: ->{ trigger_garbage_collection }
        ),
        StatusItem.new(
          id: :dark_mode,
          icon: "🌙",
          text: "ダーク",
          tooltip: "ダークモードの切り替え。",
          width: 80,
          priority: 30,
          visible: true,
          click_handler: ->{ toggle_dark_mode }
        )
      ]
    end

    # ステータスバーを描画する
    override def render(window : Concave::Window)
      return unless visible? && (bounds = @bounds)
      x, y, w, h = bounds

      render_start_time = Time.monotonic
      # キャッシュキーの生成（状態に基づく）
      current_cache_key = generate_cache_key(w, h)
      
      # キャッシュを使用（表示内容が変わらない場合）
      if !@cache_needs_update && 
         current_cache_key == @render_cache_key && 
         (cache = @render_cache) && 
         (@render_cache_expiry.nil? || Time.monotonic < @render_cache_expiry.not_nil!)
           
        window.draw_texture(cache, x: x, y: y)
        
        # 進行中のアニメーションやツールチップのみ追加描画
        if @progress || @display_mode != DisplayMode::NORMAL || has_animated_items?
          render_animated_content(window, x, y, w, h)
        end
        
        # ツールチップ描画
        render_tooltip(window) if @tooltip_visible
        
        # パフォーマンス測定を更新（キャッシュヒット）
        @performance_metrics.add_metric("status_bar_render_cached", 
                                        (Time.monotonic - render_start_time).total_milliseconds)
        return
      end
      
      # 新規描画（またはキャッシュ更新）
      texture = Concave::Texture.create_empty(w, h, Concave::PixelFormat::RGBA)
      texture.with_draw_target do |ctx|
        # 背景 - 表示モードに応じたグラデーション
        render_background(ctx, w, h)
        
        # 境界線
        ctx.set_draw_color(@theme.colors.border, 0.5)
        ctx.draw_line(x1: 0, y1: 0, x2: w, y2: 0) # 上の境界線
        
        # メインステータステキスト部分
        text_y = (h - @theme.font_size) / 2
        text_color = case @display_mode
                     when .ERROR?   then @theme.colors.error
                     when .WARNING? then @theme.colors.warning
                     when .SUCCESS? then @theme.colors.success
                     when .INFO?    then @theme.colors.info
                     when .CUSTOM?  then @custom_color || @theme.colors.foreground
                     else @theme.colors.foreground
                     end
        
        # 重要なメッセージの場合はアイコンを追加
        icon_text = case @display_mode
                    when .ERROR?   then "⚠️ "
                    when .WARNING? then "⚡ "
                    when .SUCCESS? then "✅ "
                    when .INFO?    then "ℹ️ "
                    else ""
                    end
        
        full_text = icon_text + @status_text
        
        # テキストをトリミング（幅に合わせる）
        available_width = w - status_items_total_width - 20
        trimmed_text = trim_text_to_width(full_text, available_width, @theme.font_size, @theme.font_family)
        
        ctx.set_draw_color(text_color, 1.0)
        ctx.draw_text(trimmed_text, x: 8, y: text_y, size: @theme.font_size, font: @theme.font_family)
        
        # 固定ステータスアイテムを描画（右側から並べる）
        render_status_items(ctx, w, h)
      end
      
      # キャッシュを保存
      @render_cache = texture
      @render_cache_key = current_cache_key
      
      # キャッシュ有効期限の設定（アダプティブTTL）
      ttl = calculate_adaptive_cache_ttl
      @render_cache_expiry = Time.monotonic + ttl.seconds
      @cache_needs_update = false
      
      # テクスチャを描画
      window.draw_texture(texture, x: x, y: y)
      
      # キャッシュしない要素（アニメーション）を描画
      if @progress || @display_mode != DisplayMode::NORMAL || has_animated_items?
        render_animated_content(window, x, y, w, h)
      end
      
      # ツールチップ描画
      render_tooltip(window) if @tooltip_visible
      
      # パフォーマンス測定を更新（キャッシュミス）
      render_time = (Time.monotonic - render_start_time).total_milliseconds
      @last_render_time = render_time
      @performance_metrics.add_metric("status_bar_render_uncached", render_time)
    rescue ex
      Log.error "ステータスバーの描画に失敗しました", exception: ex
    end

    # 背景を描画（モードに応じたグラデーション）
    private def render_background(ctx, w, h)
      # ベースカラーを決定
      base_color = case @display_mode
                   when .ERROR?   then blend_colors(@theme.colors.secondary, @theme.colors.error, 0.15)
                   when .WARNING? then blend_colors(@theme.colors.secondary, @theme.colors.warning, 0.15)
                   when .SUCCESS? then blend_colors(@theme.colors.secondary, @theme.colors.success, 0.15)
                   when .INFO?    then blend_colors(@theme.colors.secondary, @theme.colors.info, 0.15)
                   when .CUSTOM?  then blend_colors(@theme.colors.secondary, @custom_color || @theme.colors.accent, 0.15)
                   else @theme.colors.secondary
                   end
      
      # グラデーションの終点色
      end_color = darken_color(base_color, 0.1)
      
      # 左から右へのグラデーション
      (0...w).step(2) do |x_pos|
        factor = x_pos.to_f / w
        color = blend_colors(base_color, end_color, factor)
        
        ctx.set_draw_color(color, 1.0)
        ctx.draw_line(x1: x_pos, y1: 0, x2: x_pos, y2: h)
      end
    end

    # ステータスアイテムを描画
    private def render_status_items(ctx, w, h)
      # 優先度に基づいてソート
      sorted_items = @status_items.sort_by { |item| -item.priority }
      
      # 表示数を制限（画面サイズに応じて調整）
      visible_items = sorted_items.select(&.visible)[0...@visible_items_limit]
      
      total_fixed_width = 0
      visible_items.reverse_each do |item|
        item_width = item.width > 0 ? item.width : 100
        item_x = w - total_fixed_width - item_width
        
        # 項目の背景（ホバー状態で変化）
        hover_index = @status_items.index { |i| i.id == item.id }
        
        # 背景ベース
        ctx.set_draw_color(@theme.colors.secondary_alt, 0.3)
        ctx.fill_rect(x: item_x, y: 0, width: item_width, height: h)
        
        if @hover_item_index == hover_index
          # ホバー効果
          ctx.set_draw_color(@theme.colors.hover, 0.25)
          ctx.fill_rect(x: item_x, y: 0, width: item_width, height: h)
          
          # アンダーライン
          ctx.set_draw_color(@theme.colors.accent, 0.8)
          ctx.fill_rect(x: item_x, y: h - 2, width: item_width, height: 2)
        elsif @active_item_index == hover_index
          # アクティブアイテム
          ctx.set_draw_color(@theme.colors.accent, 0.2)
          ctx.fill_rect(x: item_x, y: 0, width: item_width, height: h)
          
          # アンダーライン（アクティブ時）
          ctx.set_draw_color(@theme.colors.accent, 1.0)
          ctx.fill_rect(x: item_x, y: h - 2, width: item_width, height: 2)
        end
        
        # アニメーション効果（点滅など）
        if item.animating?
          anim = item.animation.not_nil!
          alpha = anim.progress
          
          case anim.type
          when :pulse, :fade
            ctx.set_draw_color(@theme.colors.accent, alpha * 0.3)
            ctx.fill_rect(x: item_x, y: 0, width: item_width, height: h)
          when :flash
            if alpha > 0.5
              ctx.set_draw_color(0xFFFFFF, 0.2)
              ctx.fill_rect(x: item_x, y: 0, width: item_width, height: h)
            end
          when :bounce
            bounce_offset = (1.0 - alpha) * 3
            ctx.set_draw_color(@theme.colors.accent, 0.3)
            ctx.fill_rect(x: item_x, y: bounce_offset.to_i, width: item_width, height: h - bounce_offset.to_i)
          end
        end
        
        # 分離線
        ctx.set_draw_color(@theme.colors.border, 0.3)
        ctx.draw_line(x1: item_x, y1: 0, x2: item_x, y2: h)
        
        # アイコン描画
        if icon = item.icon
          icon_size = @theme.font_size + 2
          icon_x = item_x + 6
          icon_y = (h - icon_size) / 2
          
          # アニメーション効果がある場合は色を調整
          icon_color = if item.animating?
                        anim = item.animation.not_nil!
                        if anim.type == :pulse
                          blend_colors(item.color || @theme.colors.foreground, @theme.colors.accent, anim.progress)
                        else
                          item.color || @theme.colors.foreground
                        end
                      else
                        item.color || @theme.colors.foreground
                      end
          
          ctx.set_draw_color(icon_color, 1.0)
          ctx.draw_text(icon, x: icon_x, y: icon_y, size: icon_size, font: @theme.icon_font_family || @theme.font_family)
        end
        
        # テキスト描画
        text_x = item_x + (icon ? 26 : 8)
        text_y = (h - @theme.font_size) / 2
        ctx.set_draw_color(item.color || @theme.colors.foreground, 1.0)
        ctx.draw_text(item.text, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
        
        # バッジ（未読カウンタなど）
        if (badge_count = item.badge_count) && badge_count > 0
          badge_x = item_x + item_width - 14
          badge_y = 4
          badge_radius = 8
          badge_color = item.badge_color || @theme.colors.error
          
          # バッジの背景
          ctx.set_draw_color(badge_color, 1.0)
          ctx.fill_circle(cx: badge_x, cy: badge_y, radius: badge_radius)
          
          # バッジのテキスト（数字）
          badge_text = badge_count > 99 ? "99+" : badge_count.to_s
          ctx.set_draw_color(0xFFFFFF, 1.0)
          ctx.draw_text(badge_text, 
                      x: badge_x - (badge_text.size * 3), 
                      y: badge_y - 5, 
                      size: @theme.font_size - 4, 
                      font: @theme.font_family)
        end
        
        total_fixed_width += item_width
      end
    end

    # アニメーション要素を描画（プログレスバーなど）
    private def render_animated_content(window, x, y, w, h)
      # プログレスバー (読み込み中など)
      if prog = @progress
        progress_width = (w * prog).to_i
        
        # グラデーションの進行度合い
        animation_progress = @progress_animation.current_value
        gradient_offset = animation_progress
        
        # グラデーションプログレスバー
        progress_color = case @display_mode
                         when .ERROR?   then @theme.colors.error
                         when .WARNING? then @theme.colors.warning
                         when .SUCCESS? then @theme.colors.success
                         when .INFO?    then @theme.colors.info
                         when .CUSTOM?  then @custom_color || @theme.colors.accent
                         else @theme.colors.accent
                         end
        
        # 背景
        window.set_draw_color(progress_color, 0.15)
        window.fill_rect(x: x, y: y + h - 3, width: w, height: 3)
        
        # 進捗部分
        progress_width = (w * prog).to_i
        window.set_draw_color(progress_color, 0.7)
        window.fill_rect(x: x, y: y + h - 3, width: progress_width, height: 3)
        
        # ハイライト効果（アニメーション）
        highlight_width = w * 0.2
        highlight_pos = (w - highlight_width) * gradient_offset
        
        if max_width > 0
          window.set_draw_color(blend_colors(progress_color, 0xFFFFFF, 0.2), 0.4)
          window.fill_rect(
            x: x + highlight_pos.to_i,
            y: y + h - 3,
            width: highlight_width.to_i,
            height: 3
          )
        end
      end
      
      # ステータスモード変更時の表示アニメーション
      if @display_mode != DisplayMode::NORMAL
        elapsed = (Time.monotonic - @mode_start_time).total_seconds
        total_duration = @mode_duration.total_seconds
        
        if elapsed < total_duration
          # フェードイン/アウトアニメーション
          progress = elapsed / total_duration
          
          if progress < 0.3
            # フェードイン
            fade_alpha = progress / 0.3
          elsif progress > 0.8
            # フェードアウト
            fade_alpha = (1.0 - progress) / 0.2
          else
            # 表示中
            fade_alpha = 1.0
          end
          
          @fade_animation = fade_alpha
          
          # 背景効果（通知強調）
          accent_color = case @display_mode
                         when .ERROR?   then @theme.colors.error
                         when .WARNING? then @theme.colors.warning
                         when .SUCCESS? then @theme.colors.success
                         when .INFO?    then @theme.colors.info
                         when .CUSTOM?  then @custom_color || @theme.colors.accent
                         else @theme.colors.accent
                         end
          
          # 背景エフェクト
          window.set_draw_color(accent_color, 0.1 * fade_alpha)
          window.fill_rect(x: x, y: y, width: w, height: h - 3)
          
          # キラキラエフェクト（成功時）
          if @display_mode == DisplayMode::SUCCESS
            # 散布する光の粒子
            particles_count = 5
            particles_count.times do |i|
              particle_x = x + (w * (i.to_f / particles_count.to_f + gradient_offset) % 1.0).to_i
              particle_y = y + (h * 0.5 * Math.sin(i.to_f / 2.0 + gradient_offset * Math::PI * 2) + h * 0.3).to_i
              particle_size = (4.0 * fade_alpha).to_i
              
              window.set_draw_color(accent_color, 0.7 * fade_alpha)
              window.fill_circle(cx: particle_x, cy: particle_y, radius: particle_size)
            end
          end
          
          # 揺れエフェクト（警告/エラー時）
          if @display_mode == DisplayMode::WARNING || @display_mode == DisplayMode::ERROR
            shake_amplitude = 2.0 * fade_alpha
            shake_offset = (Math.sin(gradient_offset * Math::PI * 16) * shake_amplitude).to_i
            
            # 警告バーを揺らす
            window.set_draw_color(accent_color, 0.4 * fade_alpha)
            window.fill_rect(x: x + shake_offset, y: y, width: 3, height: h)
            window.fill_rect(x: x + w - 3 - shake_offset, y: y, width: 3, height: h)
          end
        else
          # 表示時間終了、通常モードに戻す
          if @notification_queue.empty?
            @display_mode = DisplayMode::NORMAL
            @cache_needs_update = true
          else
            # 次の通知を表示
            process_next_notification
          end
        end
      end
      
      # アニメーションアイテムの更新
      update_animated_items
    end
    
    # アニメーション中のステータスアイテムを更新
    private def update_animated_items
      @status_items.each do |item|
        if item.animating?
          @cache_needs_update = true
        end
      end
    end
    
    # ツールチップを描画
    private def render_tooltip(window)
      return unless @tooltip_visible && @tooltip_position && @tooltip_text
      
      # ツールチップのフェードイン
      if @tooltip_fade < 1.0
        @tooltip_fade = Math.min(1.0, @tooltip_fade + 0.1)
      end
      
      x, y = @tooltip_position.not_nil!
      
      # ツールチップのサイズを計算（初回のみ）
      if @tooltip_width == 0 || @tooltip_height == 0
        text = @tooltip_text.not_nil!
        font_size = @theme.font_size - 1
        line_height = font_size + 2
        
        # 複数行のツールチップに対応
        lines = text.split("\n")
        @tooltip_height = line_height * lines.size + 8
        
        # 各行の幅を計算して最大値を使用
        line_widths = lines.map { |line| window.measure_text(line, size: font_size, font: @theme.font_family)[0] }
        @tooltip_width = line_widths.max + 16
      end
      
      # 画面からはみ出さないように位置調整
      if x + @tooltip_width > window.width
        x = window.width - @tooltip_width - 5
      end
      
      if y + @tooltip_height > window.height
        y = y - @tooltip_height - 5
      end
      
      # 背景（少し透明）
      window.set_draw_color(@theme.colors.tooltip_bg, 0.95 * @tooltip_fade)
      window.fill_rect_rounded(
        x: x,
        y: y,
        width: @tooltip_width,
        height: @tooltip_height,
        radius: 4
      )
      
      # 枠線
      window.set_draw_color(@theme.colors.border, 0.3 * @tooltip_fade)
      window.draw_rect_rounded(
        x: x,
        y: y,
        width: @tooltip_width,
        height: @tooltip_height,
        radius: 4
      )
      
      # テキスト
      window.set_draw_color(@theme.colors.tooltip_text, @tooltip_fade)
      
      # 複数行のテキストを描画
      @tooltip_text.not_nil!.split("\n").each_with_index do |line, i|
        line_y = y + 4 + ((@theme.font_size - 1) + 2) * i
        window.draw_text(
          line,
          x: x + 8,
          y: line_y,
          size: @theme.font_size - 1,
          font: @theme.font_family
        )
      end
    end
    
    # イベント処理
    override def handle_event(event : QuantumEvents::Event) : Bool
      case event.type
      when QuantumEvents::EventType::UI_MOUSE_MOTION
        # マウス移動イベント
        motion_event = event.data.as(Concave::Event::MouseMotion)
        mx, my = motion_event.x, motion_event.y
        @last_mouse_position = {mx, my}
        
        if bounds = @bounds
          x, y, w, h = bounds
          
          if mx >= x && mx < x + w && my >= y && my < y + h
            # ホバーアイテムの検出
            item_index = find_item_at_position(mx - x, my - y)
            
            if @hover_item_index != item_index
              @hover_item_index = item_index
              @cache_needs_update = true
              
              # ホバー項目があればツールチップを表示
              if item_index && (item = @status_items[item_index])
                if tooltip = item.tooltip
                  show_tooltip(tooltip, {mx, my})
                else
                  hide_tooltip
                end
              else
                hide_tooltip
              end
            end
            
            return true
          else
            if @hover_item_index
              @hover_item_index = nil
              @cache_needs_update = true
            end
            
            hide_tooltip
          end
        end
        
      when QuantumEvents::EventType::UI_MOUSE_BUTTON_DOWN
        button_event = event.data.as(Concave::Event::MouseButtonDown)
        mx, my = button_event.x, button_event.y
        
        if bounds = @bounds
          x, y, w, h = bounds
          
          if mx >= x && mx < x + w && my >= y && my < y + h
            item_index = find_item_at_position(mx - x, my - y)
            
            if item_index && (item = @status_items[item_index])
              @active_item_index = item_index
              @cache_needs_update = true
              
              # 右クリックの場合はコンテキストメニュー
              if button_event.button == Concave::MouseButton::RIGHT
                if context_menu_handler = item.context_menu_handler
                  show_context_menu(context_menu_handler.call, {mx, my})
                  return true
                end
              elsif button_event.button == Concave::MouseButton::LEFT
                # 左クリック：シングルクリックとダブルクリックの処理
                if @double_click_timer && 
                   @double_click_item_id == item.id &&
                   (Time.monotonic - @double_click_timer.not_nil!).total_seconds < @double_click_threshold
                  
                  # ダブルクリック処理
                  if double_click_handler = item.double_click_handler
                    double_click_handler.call
                    @double_click_timer = nil
                    @double_click_item_id = nil
                    return true
                  end
                end
                
                # シングルクリックのタイマーを開始
                @double_click_timer = Time.monotonic
                @double_click_item_id = item.id
                
                # シングルクリック処理
                if click_handler = item.click_handler
                  click_handler.call
                  return true
                end
              end
            end
          end
        end
        
      when QuantumEvents::EventType::UI_MOUSE_BUTTON_UP
        @active_item_index = nil
        @cache_needs_update = true
        
      when QuantumEvents::EventType::TAB_SWITCHED
        tab_event = event.data.as(QuantumEvents::TabSwitchedEvent)
        @active_tab_id = tab_event.tab_id
        update_for_current_tab
        @cache_needs_update = true
        
      when QuantumEvents::EventType::ZOOM_CHANGED
        zoom_event = event.data.as(QuantumEvents::ZoomChangedEvent)
        if zoom_event.tab_id == @active_tab_id
          update_zoom_level(zoom_event.zoom_level)
        end
        
      when QuantumEvents::EventType::ENCODING_CHANGED
        encoding_event = event.data.as(QuantumEvents::EncodingChangedEvent)
        if encoding_event.tab_id == @active_tab_id
          update_encoding(encoding_event.encoding)
        end
        
      when QuantumEvents::EventType::NETWORK_STATUS_CHANGED
        network_event = event.data.as(QuantumEvents::NetworkStatusEvent)
        update_network_status(network_event.status)
        
      when QuantumEvents::EventType::SECURITY_STATUS_CHANGED
        security_event = event.data.as(QuantumEvents::SecurityStatusEvent)
        if security_event.tab_id == @active_tab_id
          update_security_status(security_event.status)
        end
        
      when QuantumEvents::EventType::DOWNLOAD_STARTED
        download_event = event.data.as(QuantumEvents::DownloadEvent)
        add_download(
          id: download_event.id,
          filename: download_event.filename,
          progress: 0.0,
          status: "開始"
        )
        
      when QuantumEvents::EventType::DOWNLOAD_PROGRESS
        download_event = event.data.as(QuantumEvents::DownloadProgressEvent)
        update_download(
          id: download_event.id,
          progress: download_event.progress,
          status: "#{(download_event.progress * 100).to_i}%"
        )
        
      when QuantumEvents::EventType::DOWNLOAD_COMPLETE, QuantumEvents::EventType::DOWNLOAD_FAILED
        download_event = event.data.as(QuantumEvents::DownloadEvent)
        complete = event.type == QuantumEvents::EventType::DOWNLOAD_COMPLETE
        update_download(
          id: download_event.id,
          progress: complete ? 1.0 : 0.0,
          status: complete ? "完了" : "失敗"
        )
        
      when QuantumEvents::EventType::ADBLOCK_STATS_UPDATED
        adblock_event = event.data.as(QuantumEvents::AdBlockStatsEvent)
        if adblock_event.tab_id == @active_tab_id
          update_adblock_count(adblock_event.blocked_count)
        end
        
      when QuantumEvents::EventType::MEMORY_USAGE_UPDATED
        memory_event = event.data.as(QuantumEvents::MemoryUsageEvent)
        update_memory_usage(memory_event.usage_mb)
      end
      
      false
    end
    
    # ステータスアイテムの合計幅を計算
    private def status_items_total_width : Int32
      sorted_items = @status_items.sort_by { |item| -item.priority }
      visible_items = sorted_items.select(&.visible)[0...@visible_items_limit]
      
      visible_items.sum { |item| item.width > 0 ? item.width : 100 }
    end
    
    # 位置に対応するステータスアイテムのインデックスを検索
    private def find_item_at_position(x, y) : Int32?
      return nil unless bounds = @bounds
      full_width = bounds[2]
      
      sorted_items = @status_items.sort_by { |item| -item.priority }
      visible_items = sorted_items.select(&.visible)[0...@visible_items_limit]
      
      total_width = 0
      visible_items.reverse_each.with_index do |item, rev_idx|
        item_width = item.width > 0 ? item.width : 100
        item_x = full_width - total_width - item_width
        
        if x >= item_x && x < item_x + item_width
          # 逆順インデックスから実際のインデックスを取得
          return @status_items.index { |i| i.id == item.id }
        end
        
        total_width += item_width
      end
      
      nil
    end
    
    # ツールチップの表示
    private def show_tooltip(text : String, position : Tuple(Int32, Int32))
      @tooltip_text = text
      
      # ポインタの少し上に表示
      x, y = position
      @tooltip_position = {x, y - 25}
      
      @tooltip_visible = true
      @tooltip_fade = 0.0
      @tooltip_width = 0  # サイズ再計算のためリセット
      @tooltip_height = 0
      
      # 一定時間後に自動的に非表示
      @tooltip_timeout = Time.monotonic + 5.seconds
    end
    
    # ツールチップの非表示
    private def hide_tooltip
      @tooltip_visible = false
      @tooltip_timeout = nil
    end
    
    # コンテキストメニューの表示
    private def show_context_menu(items : Array(ContextMenuItem), position : Tuple(Int32, Int32))
      # ContextMenuコンポーネントを生成して表示
      menu_items = items.map do |item|
        ContextMenu::MenuItem.new(
          id: item.id.to_s,
          label: item.text,
          icon: item.icon,
          shortcut: item.shortcut,
          separator_before: item.separator_before,
          checked: item.checked,
          disabled: item.disabled
        )
      end
      
      # ContextMenuコンポーネントを作成・登録
      if @context_menu.nil?
        @context_menu = ContextMenu.new(@theme, menu_items)
        # UIマネージャに登録（実装依存）
        # @core.ui_manager.add_overlay(@context_menu)
      else
        @context_menu.not_nil!.update_items(menu_items)
      end
      
      # メニュー表示位置を設定
      @context_menu.not_nil!.show(position[0], position[1])
      
      # クリックイベントのハンドラ登録
      @context_menu.not_nil!.on_item_click do |item_id|
        menu_item = items.find { |i| i.id.to_s == item_id }
        if menu_item && (handler = menu_item.handler)
          handler.call
        end
      end
    end
    
    # キャッシュキーを生成（画面サイズ・状態に基づく）
    private def generate_cache_key(width, height) : String
      components = [
        "w#{width}h#{height}",
        "mode#{@display_mode}",
        "text#{@status_text.hash}",
        "items#{@status_items.map(&.text).join.hash}"
      ]
      
      components.join(":")
    end
    
    # アダプティブキャッシュTTLを計算
    private def calculate_adaptive_cache_ttl : Float64
      # レンダリング時間に基づいてキャッシュ寿命を調整
      # 時間がかかるほど長くキャッシュする
      if @last_render_time > 10.0
        5.0  # 重いレンダリングは長くキャッシュ
      elsif @last_render_time > 5.0
        2.0
      elsif @last_render_time > 1.0
        1.0
      else
        0.5  # 軽いレンダリングは短くキャッシュ
      end
    end
    
    # アニメーション中のステータスアイテムがあるか
    private def has_animated_items? : Bool
      @status_items.any?(&.animating?)
    end
    
    # テキストを指定幅に収まるようにトリミング
    private def trim_text_to_width(text : String, width : Int32, font_size : Int32, font_family : String) : String
      if text.empty? || width <= 0
        return text
      end
      
      # テキストが長すぎる場合は省略
      ellipsis = "..."
      # 完璧な省略記号幅測定実装 - フォントメトリクス使用
      ellipsis_width = measure_text_width_precise(ellipsis, font_size, font_family)
      
      available_width = width - ellipsis_width
      
      # 1文字ずつ減らして試す
      1.upto(text.size - 1) do |i|
        trimmed = text[0...text.size - i]
        # 完璧なトリミングテキスト幅測定実装 - フォントメトリクス使用
        trimmed_width = measure_text_width_precise(trimmed, font_size, font_family)
        
        if trimmed_width <= available_width
          return trimmed + ellipsis
        end
      end
      
      # どうしても収まらない場合
      ellipsis
    end
    
    # 現在のタブに基づいて情報を更新
    private def update_for_current_tab
      return unless tab_id = @active_tab_id
      
      # タブ情報を取得
      tab_info = @core.get_tab_info(tab_id)
      return unless tab_info
      
      # 各種ステータスを更新
      update_security_status(tab_info.security_status)
      update_zoom_level(tab_info.zoom_level)
      update_encoding(tab_info.encoding)
      update_adblock_count(tab_info.adblock_count)
    end
  end
end