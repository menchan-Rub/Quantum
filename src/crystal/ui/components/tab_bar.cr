# src/crystal/ui/components/tab_bar.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"

module QuantumUI
  # タブ管理コンポーネント
  # マルチタブブラウザの核となる要素で、タブの追加、削除、並べ替え、表示を管理する
  class TabBar < Component
    # タブ情報
    record TabInfo, id : String, title : String, url : String, favicon : String?, loading : Bool = true, pinned : Bool = false, muted : Bool = false, private_mode : Bool = false

    # ボタン種別
    enum ButtonType
      TAB
      NEW_TAB
      CLOSE_TAB
      CONTEXT_MENU
      PIN_TAB
      AUDIO_TOGGLE
    end

    # 描画要素 (タブ、新規タブボタン、閉じるボタンなど)
    record DrawElement, type : ButtonType, bounds : Tuple(Int32, Int32, Int32, Int32), tab_index : Int32?

    @tabs : Array(TabInfo)
    @active_tab_index : Int32
    @draw_elements : Array(DrawElement)
    @scroll_offset : Int32 = 0
    @drag_start_x : Int32? = nil
    @drag_tab_index : Int32? = nil
    @drag_current_x : Int32? = nil
    @animations : Hash(String, NamedTuple(start_pos: Int32, end_pos: Int32, start_time: Time, duration: Float64))
    @tab_width : Int32
    @tab_min_width : Int32
    @tab_max_width : Int32
    @pinned_tab_width : Int32
    @visible_tab_count : Int32
    @hover_tab_index : Int32? = nil
    @hover_close_button_index : Int32? = nil
    @saved_tab_states : Hash(String, NamedTuple(position: Int32, width: Int32))
    @last_mouse_x : Int32? = nil
    @last_mouse_y : Int32? = nil
    @tab_cache : Hash(String, Concave::Texture) # タブのレンダリングキャッシュ
    @button_usage_stats : Hash(ButtonType, Int32) = {} of ButtonType => Int32

    # UI設定、コアエンジン、テーマエンジンを受け取り初期化
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @tabs = [] of TabInfo
      @active_tab_index = -1
      @draw_elements = [] of DrawElement
      @animations = {} of String => NamedTuple(start_pos: Int32, end_pos: Int32, start_time: Time, duration: Float64)
      @tab_width = 200
      @tab_min_width = 100
      @tab_max_width = 240
      @pinned_tab_width = 40
      @visible_tab_count = 0
      @saved_tab_states = {} of String => NamedTuple(position: Int32, width: Int32)
      @tab_cache = {} of String => Concave::Texture
      
      add_new_tab(@config.homepage) # 初期タブ

      setup_event_listeners
    end

    # イベントリスナーをセットアップ
    private def setup_event_listeners
      # コアイベントを購読してタブ状態を更新
      @core.event_bus.subscribe(QuantumEvents::EventType::PAGE_TITLE_CHANGED) do |event|
        if event_data = event.data.as?(QuantumEvents::PageTitleChangedData)
          update_tab_title(event_data.page_id, event_data.title)
        end
      end

      @core.event_bus.subscribe(QuantumEvents::EventType::PAGE_FAVICON_CHANGED) do |event|
        if event_data = event.data.as?(QuantumEvents::PageFaviconChangedData)
          update_tab_favicon(event_data.page_id, event_data.favicon_path)
          invalidate_tab_cache(event_data.page_id)
        end
      end

      @core.event_bus.subscribe(QuantumEvents::EventType::PAGE_LOADING_STATE_CHANGED) do |event|
        if event_data = event.data.as?(QuantumEvents::PageLoadingStateChangedData)
          update_tab_loading_state(event_data.page_id, event_data.loading)
          invalidate_tab_cache(event_data.page_id)
        end
      end
      
      @core.event_bus.subscribe(QuantumEvents::EventType::PAGE_AUDIO_STATE_CHANGED) do |event|
        if event_data = event.data.as?(QuantumEvents::PageAudioStateChangedData)
          update_tab_audio_state(event_data.page_id, event_data.playing, event_data.muted)
          invalidate_tab_cache(event_data.page_id)
        end
      end
    end

    # タブキャッシュを無効化する
    private def invalidate_tab_cache(tab_id : String)
      @tab_cache.each_key do |key|
        if key.starts_with?(tab_id)
          @tab_cache.delete(key)
        end
      end
    end

    # タブキャッシュを全て無効化する
    private def invalidate_all_tab_cache
      @tab_cache.clear
    end

    # タブの位置情報を保存する
    private def save_tab_states
      @tabs.each_with_index do |tab, index|
        if element = find_tab_element(index)
          @saved_tab_states[tab.id] = {
            position: element.bounds[0],
            width: element.bounds[2]
          }
        end
      end
    end

    # タブバーを描画
    override def render(window : Concave::Window)
      # 境界がない場合は何もしない
      return unless bounds = @bounds
      
      # パフォーマンス計測開始
      render_start = Time.monotonic
      
      # 表示範囲
      x, y, width, height = bounds
      
      # タブの配置を更新（必要な場合のみ）
      update_tab_layout if @layout_needs_update
      
      # キャッシュキーを生成（状態に応じたユニークな文字列）
      cache_key = generate_cache_key(width, height)
      
      # キャッシュが有効かチェック
      if @render_cache && @cache_key == cache_key && !@animation_active
        # キャッシュヒット: キャッシュからレンダリング
        window.draw_texture(@render_cache.not_nil!, x: x, y: y)
      else
        # キャッシュミス: 新規描画とキャッシュ更新
        @cache_key = cache_key
        
        # オフスクリーン描画用のテクスチャを作成
        texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
        
        texture.with_draw_target do |ctx|
          # 背景（テーマ色または設定された背景色）
          bg_color = @tab_bar_background || @theme.colors.tab_bar_background || @theme.colors.surface
          ctx.set_draw_color(bg_color, 1.0)
          ctx.fill_rect(x: 0, y: 0, width: width, height: height)
          
          # 境界線（下部）
          border_color = @theme.colors.tab_bar_border || @theme.colors.divider
          ctx.set_draw_color(border_color, 0.5)
          ctx.draw_line(0, height - 1, width, height - 1)
          
          # スクロールボタンの描画（タブがスクロール可能な場合）
          if @scroll_offset > 0
            render_scroll_button(ctx, :left, 0, 0, @scroll_button_width, height)
          end
          
          if @total_tabs_width > width - (@add_tab_button_width + @scroll_button_width * 2)
            render_scroll_button(ctx, :right, width - @scroll_button_width, 0, @scroll_button_width, height)
          end
          
          # タブの描画
          @tabs.each_with_index do |tab, index|
            tab_bounds = @tab_bounds[index]
            next unless tab_bounds
            
            # スクロールオフセットを適用
            tab_x = tab_bounds[0] - @scroll_offset
            tab_width = tab_bounds[2]
            
            # 表示範囲内のタブのみ描画
            if tab_x + tab_width > @scroll_button_width && tab_x < width - @scroll_button_width - @add_tab_button_width
              render_tab(
                ctx,
                tab,
                tab_x,
                tab_bounds[1],
                tab_width,
                tab_bounds[3],
                index == @active_tab_index,
                index == @hover_tab_index
              )
            end
          end
          
          # 新規タブボタンの描画
          if @show_add_tab_button
            add_button_x = width - @add_tab_button_width
            render_add_tab_button(ctx, add_button_x, 0, @add_tab_button_width, height)
          end
          
          # ドラッグ中のタブを最前面に描画
          if @dragging_tab && @drag_tab_index >= 0 && @drag_tab_index < @tabs.size
            tab = @tabs[@drag_tab_index]
            tab_width = calculate_tab_width(tab)
            
            # ドラッグ中のタブの位置を計算
            drag_x = @drag_position_x - @drag_offset_x
            
            # タブがスクロール範囲外にドラッグされた場合の処理
            if drag_x < @scroll_button_width
              drag_x = @scroll_button_width
            elsif drag_x + tab_width > width - @scroll_button_width - @add_tab_button_width
              drag_x = width - @scroll_button_width - @add_tab_button_width - tab_width
            end
            
            # ドラッグ中のタブを半透明で描画
            render_tab(
              ctx,
              tab,
              drag_x,
              0,
              tab_width,
              height,
              @drag_tab_index == @active_tab_index,
              false,
              true # ドラッグ中フラグ
            )
          end
          
          # デバッグモードの場合、追加情報を表示
          render_debug_info(ctx, width, height) if @debug_mode
        end
        
        # レンダリング結果をキャッシュに保存
        @render_cache = texture
        window.draw_texture(texture, x: x, y: y)
      end
      
      # アニメーションの更新
      update_animations((Time.monotonic - render_start).total_seconds)
    rescue ex
      Log.error "タブバーのレンダリングに失敗しました", exception: ex
    end
    
    # タブを描画
    private def render_tab(ctx : Concave::Window, tab : TabInfo, x : Int32, y : Int32, width : Int32, height : Int32, active : Bool, hovered : Bool, dragging : Bool = false)
      # タブのキャッシュキーを生成
      cache_key = "tab_#{tab.id}_#{width}_#{height}_#{active}_#{hovered}_#{tab.loading}_#{dragging}_#{tab.pinned}"
      
      # ファビコンのハッシュを追加（変更検出用）
      if favicon = tab.favicon
        cache_key += "_#{favicon.hash}"
      end
      
      # タブが閉じるアニメーション中かどうか
      closing = @tabs_being_closed.includes?(tab.id)
      if closing
        cache_key += "_closing_#{@close_animation_progress.round(2)}"
      end
      
      # タブが新規作成アニメーション中かどうか
      opening = @tabs_being_opened.includes?(tab.id)
      if opening
        cache_key += "_opening_#{@open_animation_progress.round(2)}"
      end
      
      # キャッシュに存在しない場合、または状態が変化した場合は再描画
      if !@tab_cache.has_key?(cache_key) || closing || opening
        # タブのテクスチャを作成
        tab_texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
        
        tab_texture.with_draw_target do |tab_ctx|
          # 背景を透明に
          tab_ctx.set_draw_color(0x00_00_00_00, 0.0)
          tab_ctx.clear
          
          # タブの背景色を決定
          bg_alpha = 1.0
          
          if closing
            # 閉じるアニメーション中は徐々に透明に
            bg_alpha = 1.0 - @close_animation_progress
          elsif opening
            # 開くアニメーション中は徐々に不透明に
            bg_alpha = @open_animation_progress
          elsif dragging
            # ドラッグ中は半透明
            bg_alpha = 0.8
          end
          
          # スケーリング係数（ホバーやアクティブ時に少し拡大）
          scale = 1.0
          if hovered && !active
            scale = 1.02
          end
          
          # アクティブタブと非アクティブタブで異なる背景色とスタイルを適用
          if active
            # アクティブタブの背景
            tab_ctx.set_draw_color(@theme.colors.tab_active, bg_alpha)
            
            # タブの形状（角丸長方形、上部の角だけ丸める）
            radius = @tab_radius
            tab_ctx.fill_custom_rounded_rect(
              x: 0, y: 0,
              width: width, height: height,
              top_left_radius: radius, top_right_radius: radius,
              bottom_left_radius: 0, bottom_right_radius: 0
            )
            
            # アクティブタブのインジケーター（上部）
            indicator_height = 3
            tab_ctx.set_draw_color(@theme.colors.tab_indicator, bg_alpha)
            tab_ctx.fill_rect(x: 0, y: 0, width: width, height: indicator_height)
          else
            # 非アクティブタブの背景
            bg_color = hovered ? @theme.colors.tab_hover : @theme.colors.tab_inactive
            tab_ctx.set_draw_color(bg_color, bg_alpha * 0.9)
            
            # タブの形状（角丸長方形、上部の角だけ丸める）
            radius = @tab_radius
            tab_ctx.fill_custom_rounded_rect(
              x: 0, y: 0,
              width: width, height: height - 1, # 下部に1px空ける
              top_left_radius: radius, top_right_radius: radius,
              bottom_left_radius: 0, bottom_right_radius: 0
            )
          end
          
          # タブの内容を描画（ファビコン、タイトル、閉じるボタンなど）
          padding = tab.pinned ? 4 : 8
          content_y = (height - @tab_content_height) / 2
          
          # 現在の描画位置
          current_x = padding
          
          # ファビコンの描画
          favicon_size = tab.pinned ? @tab_content_height : @favicon_size
          if favicon = tab.favicon
            # ファビコンがある場合は描画
            tab_ctx.draw_texture(
              favicon,
              x: current_x,
              y: content_y + (@tab_content_height - favicon_size) / 2,
              width: favicon_size,
              height: favicon_size
            )
          elsif tab.loading
            # ロード中はローディングアイコンを描画
            draw_loading_spinner(
              tab_ctx,
              current_x + favicon_size / 2,
              content_y + @tab_content_height / 2,
              favicon_size / 2
            )
          else
            # ファビコンがない場合はデフォルトアイコン
            default_icon = tab.private_mode ? "🕶️" : "🌐"
            tab_ctx.set_draw_color(@theme.colors.icon, bg_alpha)
            tab_ctx.draw_text(
              default_icon,
              x: current_x,
              y: content_y,
              size: favicon_size,
              font: @theme.icon_font_family || @theme.font_family
            )
          end
          
          # ファビコン後の位置を更新
          current_x += favicon_size + padding
          
          # ピン留めタブの場合はここで終了（アイコンだけ表示）
          if tab.pinned
            # ピン留めタブの場合はタイトルを省略
          else
            # タイトルの描画
            title_width = width - current_x - padding - @close_button_size - padding
            
            if title_width > 0
              title_color = active ? @theme.colors.tab_text_active : @theme.colors.tab_text
              tab_ctx.set_draw_color(title_color, bg_alpha)
              
              # タイトルがない場合は「新しいタブ」と表示
              display_title = tab.title.empty? ? "新しいタブ" : tab.title
              
              # 長すぎるタイトルを省略
              if tab_ctx.measure_text(display_title, size: @theme.font_size, font: @theme.font_family).x > title_width
                # タイトルを省略して「...」を追加
                truncated_title = truncate_text(tab_ctx, display_title, title_width - 15)
                display_title = truncated_title + "..."
              end
              
              tab_ctx.draw_text(
                display_title,
                x: current_x,
                y: content_y + (@tab_content_height - @theme.font_size) / 2,
                size: @theme.font_size,
                font: @theme.font_family
              )
            end
            
            # 閉じるボタンの描画
            close_x = width - @close_button_size - padding
            close_y = content_y + (@tab_content_height - @close_button_size) / 2
            
            # マウスがクローズボタン上にあるかどうか
            close_hover = @hover_tab_index == @tabs.index(tab) && @hover_close_button
            
            # 閉じるボタンの背景（ホバー時のみ）
            if close_hover
              tab_ctx.set_draw_color(@theme.colors.close_button_hover_bg, bg_alpha)
              tab_ctx.fill_circle(close_x + @close_button_size / 2, close_y + @close_button_size / 2, @close_button_size / 2)
            end
            
            # ×アイコン
            close_color = close_hover ? @theme.colors.close_button_hover : @theme.colors.close_button
            tab_ctx.set_draw_color(close_color, bg_alpha)
            
            # バツ印を描画
            line_width = 2
            padding = @close_button_size / 4
            
            # 左上から右下への線
            tab_ctx.draw_line(
              close_x + padding, close_y + padding,
              close_x + @close_button_size - padding, close_y + @close_button_size - padding,
              line_width
            )
            
            # 右上から左下への線
            tab_ctx.draw_line(
              close_x + @close_button_size - padding, close_y + padding,
              close_x + padding, close_y + @close_button_size - padding,
              line_width
            )
          end
          
          # ミュート状態のアイコンを表示
          if tab.muted
            mute_icon = "🔇"
            mute_size = favicon_size
            mute_x = current_x
            mute_y = content_y + (@tab_content_height - mute_size) / 2
            
            tab_ctx.set_draw_color(@theme.colors.icon, bg_alpha)
            tab_ctx.draw_text(
              mute_icon,
              x: mute_x,
              y: mute_y,
              size: mute_size,
              font: @theme.icon_font_family || @theme.font_family
            )
          end
          
          # プライベートモードの場合は表示
          if tab.private_mode && !tab.pinned
            private_icon = "🔒"
            private_size = favicon_size * 0.7
            private_x = current_x
            private_y = content_y
            
            tab_ctx.set_draw_color(@theme.colors.private_mode, bg_alpha)
            tab_ctx.draw_text(
              private_icon,
              x: private_x,
              y: private_y,
              size: private_size.to_i,
              font: @theme.icon_font_family || @theme.font_family
            )
          end
        end
        
        # キャッシュに保存
        @tab_cache[cache_key] = tab_texture
      end
      
      # キャッシュからタブを描画
      if tab_texture = @tab_cache[cache_key]?
        # アニメーション中の場合は適切な変形を適用
        if closing
          # 閉じるアニメーション（縮小効果）
          scale = 1.0 - @close_animation_progress
          scaled_width = (width * scale).to_i
          scaled_height = (height * scale).to_i
          offset_x = (width - scaled_width) / 2
          offset_y = (height - scaled_height) / 2
          
          ctx.draw_texture(
            tab_texture,
            x: x + offset_x,
            y: y + offset_y,
            width: scaled_width,
            height: scaled_height
          )
        elsif opening
          # 開くアニメーション（拡大効果）
          scale = @open_animation_progress
          scaled_width = (width * scale).to_i
          scaled_height = (height * scale).to_i
          offset_x = (width - scaled_width) / 2
          offset_y = (height - scaled_height) / 2
          
          ctx.draw_texture(
            tab_texture,
            x: x + offset_x,
            y: y + offset_y,
            width: scaled_width,
            height: scaled_height
          )
        else
          # 通常描画
          ctx.draw_texture(tab_texture, x: x, y: y)
        end
      end
    end
    
    # 左右スクロールボタンの描画
    private def render_scroll_button(ctx : Concave::Window, direction : Symbol, x : Int32, y : Int32, width : Int32, height : Int32)
      # キャッシュキーを生成
      cache_key = "scroll_#{direction}_#{width}_#{height}_#{@scroll_hover == direction}"
      
      # キャッシュに存在しない場合は描画
      if !@button_cache.has_key?(cache_key)
        texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
        
        texture.with_draw_target do |btn_ctx|
          # 背景を透明に
          btn_ctx.set_draw_color(0x00_00_00_00, 0.0)
          btn_ctx.clear
          
          # ボタンの背景
          hover = @scroll_hover == direction
          bg_color = hover ? @theme.colors.button_hover : @theme.colors.button
          btn_ctx.set_draw_color(bg_color, hover ? 0.3 : 0.2)
          btn_ctx.fill_rect(x: 0, y: 0, width: width, height: height)
          
          # 矢印アイコン
          arrow = direction == :left ? "◀" : "▶"
          arrow_size = width / 2
          arrow_x = (width - arrow_size) / 2
          arrow_y = (height - arrow_size) / 2
          
          btn_ctx.set_draw_color(@theme.colors.button_text, 1.0)
          btn_ctx.draw_text(
            arrow,
            x: arrow_x,
            y: arrow_y,
            size: arrow_size,
            font: @theme.icon_font_family || @theme.font_family
          )
        end
        
        # キャッシュに保存
        @button_cache[cache_key] = texture
      end
      
      # キャッシュからボタンを描画
      if btn_texture = @button_cache[cache_key]?
        ctx.draw_texture(btn_texture, x: x, y: y)
      end
    end
    
    # 新規タブボタンの描画
    private def render_add_tab_button(ctx : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32)
      # キャッシュキーを生成
      cache_key = "add_tab_#{width}_#{height}_#{@hover_add_button}"
      
      # キャッシュに存在しない場合は描画
      if !@button_cache.has_key?(cache_key)
        texture = Concave::Texture.create_empty(width, height, Concave::PixelFormat::RGBA)
        
        texture.with_draw_target do |btn_ctx|
          # 背景を透明に
          btn_ctx.set_draw_color(0x00_00_00_00, 0.0)
          btn_ctx.clear
          
          # ボタンの背景
          hover = @hover_add_button
          bg_color = hover ? @theme.colors.button_hover : @theme.colors.button
          btn_ctx.set_draw_color(bg_color, hover ? 0.3 : 0.2)
          
          # 円形のボタン
          center_x = width / 2
          center_y = height / 2
          radius = Math.min(width, height) / 3
          
          if hover
            # ホバー時は円形の背景
            btn_ctx.fill_circle(center_x, center_y, radius)
          end
          
          # プラスアイコン
          btn_ctx.set_draw_color(@theme.colors.button_text, 1.0)
          
          # 横線
          line_width = 2
          line_length = radius * 1.2
          btn_ctx.fill_rect(
            x: center_x - line_length / 2,
            y: center_y - line_width / 2,
            width: line_length.to_i,
            height: line_width
          )
          
          # 縦線
          btn_ctx.fill_rect(
            x: center_x - line_width / 2,
            y: center_y - line_length / 2,
            width: line_width,
            height: line_length.to_i
          )
        end
        
        # キャッシュに保存
        @button_cache[cache_key] = texture
      end
      
      # キャッシュからボタンを描画
      if btn_texture = @button_cache[cache_key]?
        ctx.draw_texture(btn_texture, x: x, y: y)
      end
    end
    
    # ローディングスピナーの描画
    private def draw_loading_spinner(ctx : Concave::Window, center_x : Int32, center_y : Int32, radius : Int32)
      # アニメーションフレームに基づいて回転角度を計算
      angle = (@animation_frame % 360) * Math::PI / 180
      
      # スピナーの外周を描画
      ctx.set_draw_color(@theme.colors.spinner_track, 0.3)
      ctx.draw_circle(center_x, center_y, radius, 2)
      
      # スピナーのインジケーターを描画（一部の円弧）
      ctx.set_draw_color(@theme.colors.spinner, 1.0)
      
      # 円弧の開始と終了の角度
      start_angle = angle
      end_angle = angle + Math::PI * 0.75
      
      # 円弧を描画
      ctx.draw_arc(center_x, center_y, radius, start_angle, end_angle, 2)
    end
    
    # テキストの長さを制限して省略用の文字列を生成
    private def truncate_text(ctx : Concave::Window, text : String, max_width : Int32) : String
      return text if text.empty?
      
      # 文字列が指定幅に収まるまで短くする
      result = text
      while result.size > 1
        width = ctx.measure_text(result, size: @theme.font_size, font: @theme.font_family).x
        break if width <= max_width
        
        # 末尾の文字を削除
        result = result[0..-2]
      end
      
      result
    end
    
    # アニメーションの更新
    private def update_animations(delta_time : Float64)
      # アニメーションが有効かどうかチェック
      return unless @animations_enabled
      
      # ローディングアニメーションの更新
      @animation_frame += 1
      
      # アニメーションアクティブフラグをリセット
      @animation_active = false
      
      # タブ閉じるアニメーションの更新
      if !@tabs_being_closed.empty?
        @close_animation_progress += delta_time * 4 # アニメーション速度調整
        
        if @close_animation_progress >= 1.0
          # アニメーション完了、実際にタブを閉じる
          @tabs_being_closed.each do |tab_id|
            close_tab_immediately(tab_id)
          end
          @tabs_being_closed.clear
          @close_animation_progress = 0.0
        else
          # アニメーション継続中
          @animation_active = true
        end
      end
      
      # タブ作成アニメーションの更新
      if !@tabs_being_opened.empty?
        @open_animation_progress += delta_time * 4 # アニメーション速度調整
        
        if @open_animation_progress >= 1.0
          # アニメーション完了
          @tabs_being_opened.clear
          @open_animation_progress = 0.0
        else
          # アニメーション継続中
          @animation_active = true
        end
      end
      
      # 継続的なアニメーションがある場合は再描画をリクエスト
      if @animation_active
        invalidate_cache
        
        # 再描画リクエスト
        QuantumEvents::EventDispatcher.instance.publish(
          QuantumEvents::Event.new(
            type: QuantumEvents::EventType::UI_REDRAW_REQUEST,
            data: nil
          )
        )
      end
    end
    
    # キャッシュキーの生成
    private def generate_cache_key(width : Int32, height : Int32) : String
      components = [
        "w#{width}",
        "h#{height}",
        "active#{@active_tab_index}",
        "hover#{@hover_tab_index}",
        "scroll#{@scroll_offset}",
        "count#{@tabs.size}"
      ]
      
      # アクティブタブのIDを追加
      if @active_tab_index >= 0 && @active_tab_index < @tabs.size
        components << "activeId#{@tabs[@active_tab_index].id}"
      end
      
      # アニメーション状態を追加
      if !@tabs_being_closed.empty?
        components << "closing#{@tabs_being_closed.join(",")}_#{@close_animation_progress.round(2)}"
      end
      
      if !@tabs_being_opened.empty?
        components << "opening#{@tabs_being_opened.join(",")}_#{@open_animation_progress.round(2)}"
      end
      
      components.join("_")
    end
    
    # キャッシュの無効化
    private def invalidate_cache
      @render_cache = nil
      @cache_key = ""
    end
    
    # デバッグ情報の表示
    private def render_debug_info(ctx : Concave::Window, width : Int32, height : Int32)
      # デバッグ情報
      debug_lines = [
        "Tabs: #{@tabs.size}",
        "Active: #{@active_tab_index}",
        "Total width: #{@total_tabs_width}",
        "Visible width: #{width - @add_tab_button_width - @scroll_button_width * 2}",
        "Scroll: #{@scroll_offset}"
      ]
      
      # 背景
      debug_bg_height = (debug_lines.size * (@theme.font_size + 4) + 8).to_i
      ctx.set_draw_color(0x00_00_00, 0.7)
      ctx.fill_rect(x: 4, y: 4, width: 200, height: debug_bg_height)
      
      # テキスト
      ctx.set_draw_color(0xFF_FF_FF, 1.0)
      
      debug_lines.each_with_index do |line, index|
        y = 8 + index * (@theme.font_size + 4)
        ctx.draw_text(line, x: 8, y: y, size: @theme.font_size, font: @theme.font_family)
      end
    end
  end
end