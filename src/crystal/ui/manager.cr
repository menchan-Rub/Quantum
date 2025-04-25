# src/crystal/ui/manager.cr
require "concave" # UIライブラリ
require "../quantum_core/engine"
require "../quantum_core/page_manager"
require "../quantum_core/config"
require "../events/event_dispatcher"
require "../utils/logger"
require "./component"
require "./theme_engine"
require "./layout_engine"
require "./focus_manager"
require "./components/**" # 各コンポーネントを読み込む

module QuantumUI
  # UIレイヤー全体の管理クラス
  # ウィンドウ管理、コンポーネント管理、イベント処理、レンダリングを担当
  class Manager
    Log = ::Log.for(self.class.name)

    getter config     : QuantumCore::UIConfig
    getter core       : QuantumCore::Engine
    getter theme      : ThemeEngine
    getter layout     : LayoutEngine
    getter focus_manager : FocusManager
    getter components : Array(Component)
    getter window     : Concave::Window?

    @event_dispatcher : QuantumEvents::EventDispatcher
    @event_thread : Thread?
    @render_thread : Thread?
    @needs_repaint : Bool # 再描画フラグ
    @mouse_down_component : Component? # マウスダウン時のコンポーネント追跡用
    @hover_component : Component? # ホバー中のコンポーネント

    # @param config [QuantumCore::UIConfig] UI設定
    # @param core   [QuantumCore::Engine] コアエンジンインスタンス
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine)
      Log.info "Initializing QuantumUI::Manager..."
      @theme = ThemeEngine.new(
        default_theme: @config.dark_mode ? ThemeEngine::ThemeType::DARK : ThemeEngine::ThemeType::LIGHT,
        font_family: @config.font_family,
        font_size: @config.font_size
      )
      @layout = LayoutEngine.new
      @focus_manager = FocusManager.new
      @components = [] of Component
      @window = nil
      @event_dispatcher = QuantumEvents::EventDispatcher.instance
      @needs_repaint = true # 初期描画必要
      @mouse_down_component = nil
      @hover_component = nil
      init_components
      setup_core_event_listeners
      Log.info "QuantumUI::Manager initialized."
    end

    # UIを開始し、ウィンドウを表示してイベント/レンダリングループを開始する
    def start
      Log.info "Starting QuantumUI::Manager..."
      setup_window
      perform_initial_layout # ウィンドウサイズ確定後にレイアウト実行
      spawn_event_thread
      spawn_render_thread
      Log.info "QuantumUI::Manager started successfully."
    rescue ex
      Log.fatal "UI start failed!", exception: ex
      show_error_dialog("UIの起動に失敗しました", ex.message || "不明なエラー")
    end

    # UIをシャットダウンし、ウィンドを閉じてスレッドを停止する
    def shutdown
      Log.info "Shutting down QuantumUI::Manager..."
      @window.try &.close
      @event_thread.try &.join(timeout: 1.second)
      @render_thread.try &.join(timeout: 1.second)
      Log.info "QuantumUI::Manager shut down gracefully."
    rescue ex
      Log.error "Error during UI shutdown", exception: ex
    end

    # メインループ: イベントと描画スレッドの完了を待機する
    # アプリケーションのメインスレッドが終了しないようにブロックする
    def main_loop
      Log.debug "Entering UI main loop (blocking)..."
      @event_thread.try &.join
      @render_thread.try &.join
      Log.debug "Exiting UI main loop."
    end

    # 他のコンポーネントや外部から再描画を要求するメソッド
    def request_repaint
        @needs_repaint = true
    end

    # --- Private Methods --- #

    # ウィンドウを初期化・設定する
    private def setup_window
      Log.debug "Setting up UI window..."
      @window = Concave::Window.new(
        title: @config.window_title || "Quantum Browser",
        width: @config.initial_width || 1280,
        height: @config.initial_height || 720,
        resizable: true,
        borderless: false
      )
      
      @window.not_nil!.on_resize do |width, height|
        Log.info "Window resized to: #{width}x#{height}"
        dispatch_ui_event(QuantumEvents::EventType::UI_WINDOW_RESIZE, QuantumEvents::WindowResizeData.new(width, height))
        perform_layout(width, height)
        request_repaint
      end
      
      @window.not_nil!.on_close do
        Log.info "Window close requested"
        dispatch_ui_event(QuantumEvents::EventType::UI_WINDOW_CLOSE)
      end
      
      @window.not_nil!.show
      Log.debug "UI window created and shown."
    end

    # UIコンポーネントを初期化し、リストに追加する
    private def init_components
      Log.debug "Initializing UI components..."
      # UIマネージャーインスタンスを必要なコンポーネントに渡す
      @components << AddressBar.new(@config, @core, @theme, self)
      @components << NavigationControls.new(@config, @core, @theme, self)
      @components << TabBar.new(@config, @core, @theme, self)
      @components << SidePanel.new(@config, @core, @theme, self)
      @components << ContentArea.new(@config, @core, @theme, self)
      @components << ContextMenu.new(@config, @core, @theme, self)
      @components << SettingsInterface.new(@config, @core, @theme, self)
      @components << StatusBar.new(@config, @core, @theme, self)
      @components << NetworkStatusOverlay.new(@config, @core, @theme, self)
      @components << ErrorDialog.new(@config, @core, @theme, self)
      Log.debug "#{components.size} UI components initialized."
    end

    # コア (Engine) からのイベントを購読する設定
    private def setup_core_event_listeners
      Log.debug "Setting up core event listeners..."

      # --- ページライフサイクルイベント --- #
      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_CREATED) do |event|
        if data = event.data_as?(QuantumEvents::PageCreatedData)
          find_component(TabBar).try(&.add_tab(data.page_id, data.url, false))
          request_repaint
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_DESTROYED) do |event|
        if data = event.data_as?(QuantumEvents::PageDestroyedData)
          find_component(TabBar).try(&.remove_tab(data.page_id))
          request_repaint
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_ACTIVE_CHANGED) do |event|
        if data = event.data_as?(QuantumEvents::PageActiveChangedData)
          active_id = data.active_page_id
          find_component(TabBar).try(&.set_active_tab(active_id))
          find_component(AddressBar).try(&.update_for_page(active_id, @core.page_manager))
          find_component(ContentArea).try(&.set_active_page(active_id))
          
          if active_id && (page = @core.page_manager.find_page(active_id.to_u64))
             update_nav_controls(page.history.can_go_back?, page.history.can_go_forward?)
          else
            update_nav_controls(false, false)
          end
          request_repaint
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_TITLE_CHANGED) do |event|
        if data = event.data_as?(QuantumEvents::PageTitleChangedData)
          find_component(TabBar).try(&.update_tab_title(data.page_id, data.title))
          request_repaint
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_FAVICON_CHANGED) do |event|
        if data = event.data_as?(QuantumEvents::PageFaviconChangedData)
          find_component(TabBar).try(&.update_tab_favicon(data.page_id, data.favicon_url))
          request_repaint
        end
      end

      # --- ページ読み込みイベント --- #
      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_LOAD_START) do |event|
        if data = event.data_as?(QuantumEvents::PageLoadStartData)
          if data.page_id == @core.page_manager.active_page_id.to_s?
            find_component(AddressBar).try(&.update_load_state(true, nil))
            find_component(StatusBar).try(&.set_status("#{data.url} を読み込み中..."))
            find_component(NetworkStatusOverlay).try(&.show_loading_indicator)
            request_repaint
          end
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_LOAD_PROGRESS) do |event|
        if data = event.data_as?(QuantumEvents::PageLoadProgressData)
          if data.page_id == @core.page_manager.active_page_id.to_s?
            find_component(AddressBar).try(&.update_load_progress(data.progress))
            find_component(StatusBar).try(&.update_progress(data.progress))
            find_component(NetworkStatusOverlay).try(&.update_progress(data.progress))
            request_repaint
          end
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_LOAD_COMPLETE) do |event|
        if data = event.data_as?(QuantumEvents::PageLoadCompleteData)
          if data.page_id == @core.page_manager.active_page_id.to_s?
            find_component(AddressBar).try(&.update_load_state(false, true))
            find_component(StatusBar).try(&.set_status("読み込み完了"))
            find_component(NetworkStatusOverlay).try(&.hide_loading_indicator)
            request_repaint
          end
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_LOAD_ERROR) do |event|
        if data = event.data_as?(QuantumEvents::PageLoadErrorData)
          if data.page_id == @core.page_manager.active_page_id.to_s?
            find_component(AddressBar).try(&.update_load_state(false, false))
            find_component(StatusBar).try(&.set_status("エラー: #{data.error_message}"))
            find_component(NetworkStatusOverlay).try(&.show_error(data.error_message))
            request_repaint
          end
        end
      end

      # --- セキュリティと履歴 --- #
      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_SECURITY_CONTEXT_CHANGED) do |event|
        if data = event.data_as?(QuantumEvents::PageSecurityContextChangedData)
          if data.page_id == @core.page_manager.active_page_id.to_s?
            find_component(AddressBar).try(&.update_security_indicator(data.security_level, data.tls_info))
            request_repaint
          end
        end
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::PAGE_HISTORY_UPDATE) do |event|
          if data = event.data_as?(QuantumEvents::HistoryUpdateData)
              update_nav_controls(data.can_back, data.can_forward)
              request_repaint
          end
      end

      # --- UI固有イベント --- #
      @event_dispatcher.subscribe(QuantumEvents::EventType::UI_REQUEST_REPAINT) do |_event|
          request_repaint
      end

      @event_dispatcher.subscribe(QuantumEvents::EventType::UI_WINDOW_CLOSE) do |_event|
        Log.info "UI_WINDOW_CLOSE event received. Initiating core shutdown."
        @core.shutdown
      end

      Log.debug "Core event listeners set up."
    end

    # イベント処理スレッドを開始する
    private def spawn_event_thread
      @event_thread = Thread.new do
        Log.info "Event processing thread started."
        begin
          process_events until @window.nil? || @window.not_nil!.closed?
        rescue ex
          Log.error "Exception in event thread!", exception: ex
          show_error_dialog("イベント処理エラー", ex.message || "不明なエラー")
        ensure
          Log.info "Event processing thread finished."
        end
      end
    end

    # レンダリングスレッドを開始する
    private def spawn_render_thread
      @render_thread = Thread.new do
        Log.info "Rendering thread started."
        begin
          render_loop until @window.nil? || @window.not_nil!.closed?
        rescue ex
          Log.error "Exception in render thread!", exception: ex
          show_error_dialog("描画エラー", ex.message || "不明なエラー")
        ensure
          Log.info "Rendering thread finished."
        end
        end
    end

    # UI イベントを内部ディスパッチャ経由で発行する
    private def dispatch_ui_event(type : QuantumEvents::EventType, data = nil)
      @event_dispatcher.dispatch(QuantumEvents::Event.new(type: type, data: data))
    end

    # イベントループ (イベントスレッドで実行)
    private def process_events
      # イベントポーリング (約60fps)
      unless Concave::Event.poll(timeout: 16.milliseconds)
        # タイムアウト時の処理（必要なら）
        return
      end

      # イベント処理
      while event = Concave::Event.next
        handle_ui_event(event)
      end
    end

    # 個々のUIイベントを処理する
    private def handle_ui_event(event : Concave::Event::Type)
      case event
      when Concave::Event::Quit
        Log.info "Quit event received. Initiating core shutdown."
        @core.shutdown
      when Concave::Event::WindowClose
        Log.info "Window close event received. Initiating core shutdown."
        @core.shutdown
      when Concave::Event::KeyDown
        Log.debug "Key Down: #{event.key_code}, Mod: #{event.modifiers}"
        key_event = QuantumEvents::KeyEventData.new(
          key_code: event.key_code,
          modifiers: event.modifiers,
          repeat: event.repeat,
          char: event.char
        )
        
        # グローバルショートカットを処理
        unless handle_global_shortcuts(key_event)
          # フォーカスコンポーネントにイベントを渡す
          if comp = @focus_manager.focused_component
            comp.handle_key_down(key_event) if comp.responds_to?(:handle_key_down)
          end
        end
        
      when Concave::Event::KeyUp
        Log.debug "Key Up: #{event.key_code}, Mod: #{event.modifiers}"
        key_event = QuantumEvents::KeyEventData.new(
          key_code: event.key_code,
          modifiers: event.modifiers,
          repeat: false,
          char: event.char
        )
        
        if comp = @focus_manager.focused_component
          comp.handle_key_up(key_event) if comp.responds_to?(:handle_key_up)
        end
        
      when Concave::Event::TextInput
        Log.debug "Text Input: #{event.text}"
        if comp = @focus_manager.focused_component
          comp.handle_text_input(event.text) if comp.responds_to?(:handle_text_input)
        end
        
      when Concave::Event::MouseDown
        Log.debug "Mouse Down: Button #{event.button}, Pos (#{event.x}, #{event.y})"
        mouse_event = QuantumEvents::MouseEventData.new(
          x: event.x,
          y: event.y,
          button: event.button,
          modifiers: event.modifiers
        )
        handle_mouse_down(mouse_event)
        
      when Concave::Event::MouseUp
        Log.debug "Mouse Up: Button #{event.button}, Pos (#{event.x}, #{event.y})"
        mouse_event = QuantumEvents::MouseEventData.new(
          x: event.x,
          y: event.y,
          button: event.button,
          modifiers: event.modifiers
        )
        handle_mouse_up(mouse_event)
        
      when Concave::Event::MouseMove
        mouse_event = QuantumEvents::MouseEventData.new(
          x: event.x,
          y: event.y,
          button: Concave::MouseButton::None,
          modifiers: event.modifiers
        )
        handle_mouse_move(mouse_event)
        
      when Concave::Event::Scroll
        Log.debug "Scroll: Delta (#{event.x_delta}, #{event.y_delta})"
        scroll_event = QuantumEvents::ScrollEventData.new(
          x_delta: event.x_delta,
          y_delta: event.y_delta,
          x: event.x,
          y: event.y
        )
        
        # スクロールイベントはマウス位置にあるコンポーネントに送る
        target = find_component_at(event.x, event.y)
        if target && target.responds_to?(:handle_scroll)
          target.handle_scroll(scroll_event)
        elsif comp = @focus_manager.focused_component
          comp.handle_scroll(scroll_event) if comp.responds_to?(:handle_scroll)
        end
        
      when Concave::Event::WindowResize
        Log.debug "Window Resize: #{event.width}x#{event.height}"
        # on_resizeコールバックで処理済み
        
      when Concave::Event::WindowFocus
        Log.debug "Window Focus: #{event.focused ? "Gained" : "Lost"}"
        # ウィンドウフォーカス変更時の処理
        if !event.focused
          @focus_manager.store_focus_state
        else
          @focus_manager.restore_focus_state
          request_repaint
        end
        
      else
        Log.debug "Unhandled UI event type: #{event.class}"
      end
    end

    # グローバルショートカットを処理する
    private def handle_global_shortcuts(event : QuantumEvents::KeyEventData) : Bool
      # Ctrl+T: 新しいタブ
      if event.modifiers.ctrl? && event.key_code == Concave::KeyCode::T
        @core.page_manager.create_new_page("about:blank")
        return true
      # Ctrl+W: タブを閉じる
      elsif event.modifiers.ctrl? && event.key_code == Concave::KeyCode::W
        if active_id = @core.page_manager.active_page_id
          @core.page_manager.close_page(active_id)
        end
        return true
      # Ctrl+Tab: 次のタブへ
      elsif event.modifiers.ctrl? && event.key_code == Concave::KeyCode::Tab
        find_component(TabBar).try(&.select_next_tab)
        return true
      # Ctrl+Shift+Tab: 前のタブへ
      elsif event.modifiers.ctrl? && event.modifiers.shift? && event.key_code == Concave::KeyCode::Tab
        find_component(TabBar).try(&.select_previous_tab)
        return true
      # F5: 再読み込み
      elsif event.key_code == Concave::KeyCode::F5
        if active_id = @core.page_manager.active_page_id
          if page = @core.page_manager.find_page(active_id)
            page.reload
          end
        end
        return true
      # Esc: ダイアログを閉じるなど
      elsif event.key_code == Concave::KeyCode::Escape
        # 開いているダイアログやメニューを閉じる
        if menu = find_component(ContextMenu)
          if menu.visible?
            menu.hide
            request_repaint
            return true
          end
        end
        
        if dialog = find_component(ErrorDialog)
          if dialog.visible?
            dialog.hide
            request_repaint
            return true
          end
        end
        
        if settings = find_component(SettingsInterface)
          if settings.visible?
            settings.hide
            request_repaint
            return true
          end
        end
      end
      
      return false
    end

    # マウスダウンイベントの処理 (ヒットテストと委譲)
    private def handle_mouse_down(event : QuantumEvents::MouseEventData)
      # Zオーダー (描画順 = components の逆順) でヒットテスト
      target_component = @components.reverse.find do |comp|
        comp.visible? && comp.bounds && comp.contains?(event.x, event.y)
      end

      if target_component
        Log.debug "Mouse down hit: #{target_component.class} at (#{event.x}, #{event.y})"
        @mouse_down_component = target_component
        
        # フォーカスを更新
        @focus_manager.set_focus(target_component)
        
        # イベントをコンポーネントに委譲
        target_component.handle_mouse_down(event) if target_component.responds_to?(:handle_mouse_down)
        request_repaint
      else
        Log.debug "Mouse down missed all components at (#{event.x}, #{event.y})"
        @mouse_down_component = nil
        @focus_manager.clear_focus
        request_repaint
      end

      # 右クリックでコンテキストメニューを表示
      if event.button == Concave::MouseButton::Right
        show_context_menu(event.x, event.y, target_component)
        end
    end

    # マウスアップイベントの処理
    private def handle_mouse_up(event : QuantumEvents::MouseEventData)
      # マウスダウン時のコンポーネントがあれば、そこにイベントを送る
      if comp = @mouse_down_component
        comp.handle_mouse_up(event) if comp.responds_to?(:handle_mouse_up)
        
        # クリックイベントの生成（マウスダウンとマウスアップが同じコンポーネント上なら）
        if comp.contains?(event.x, event.y)
          comp.handle_click(event) if comp.responds_to?(:handle_click)
        end
      end
      
      # 現在のマウス位置にあるコンポーネントにもイベントを送る
      current_comp = find_component_at(event.x, event.y)
      if current_comp && current_comp != @mouse_down_component
        current_comp.handle_mouse_up(event) if current_comp.responds_to?(:handle_mouse_up)
      end
      
      @mouse_down_component = nil
    end

    # マウスムーブイベントの処理
    private def handle_mouse_move(event : QuantumEvents::MouseEventData)
      # ドラッグ処理
      if comp = @mouse_down_component
        comp.handle_drag(event) if comp.responds_to?(:handle_drag)
      end
      
      # ホバー効果
      current_hover = find_component_at(event.x, event.y)
      
      # 前回のホバーコンポーネントと異なる場合
      if current_hover != @hover_component
        # 前回のホバーコンポーネントにマウス離脱イベントを送る
        if prev = @hover_component
          prev.handle_mouse_leave(event) if prev.responds_to?(:handle_mouse_leave)
        end
        
        # 新しいホバーコンポーネントにマウス進入イベントを送る
        if current_hover
          current_hover.handle_mouse_enter(event) if current_hover.responds_to?(:handle_mouse_enter)
        end
        
        @hover_component = current_hover
        request_repaint
    end

      # 現在のホバーコンポーネントにマウス移動イベントを送る
      if comp = @hover_component
        comp.handle_mouse_move(event, true) if comp.responds_to?(:handle_mouse_move)
      end
      
      # カーソル形状の更新
      update_cursor(current_hover)
    end

    # カーソル形状を更新する
    private def update_cursor(component : Component?)
      return unless @window
      
      if component && component.responds_to?(:cursor_type)
        cursor = component.cursor_type
        @window.not_nil!.set_cursor(cursor)
      else
        @window.not_nil!.set_cursor(Concave::CursorType::Default)
      end
    end

    # 指定座標にあるコンポーネントを検索する
    private def find_component_at(x : Int32, y : Int32) : Component?
      @components.reverse.find do |comp|
        comp.visible? && comp.bounds && comp.contains?(x, y)
      end
    end

    # レンダリングループ (レンダリングスレッドで実行)
    private def render_loop
      return unless @window && !@window.not_nil!.closed?

      # 約60FPSを目指す
      sleep 16.milliseconds

      # 再描画が必要な場合のみ描画
      if @needs_repaint
        begin
          window = @window.not_nil!
          painter = Concave::Painter.new(window)

          # 背景クリア
          @theme.apply_clear_color(window)
          painter.clear
          # コンポーネント描画 (リスト順 = 奥から手前)
          @components.each do |component|
            next unless component.visible? && component.bounds
            
            painter.save do
              # コンポーネントの境界に基づいてクリッピング領域を設定
              b = component.bounds.not_nil!
              painter.clip(b.x, b.y, b.width, b.height)
              
              # コンポーネントの描画処理を呼び出し
              component.draw(painter)
              
              # デバッグモードの場合、コンポーネント境界を表示
              if @config.debug_mode
                painter.stroke_color = Concave::Color.new(255, 0, 255, 100)
                painter.stroke_width = 1
                painter.draw_rect(b.x, b.y, b.width, b.height)
                
                # コンポーネント名を小さく表示
                painter.font_size = 10
                painter.fill_color = Concave::Color.new(255, 255, 0, 200)
                painter.draw_text(component.class.name.to_s, b.x + 2, b.y + 12)
              end
            end
          end
          
          # オーバーレイコンポーネントの描画（常に最前面）
          @overlay_components.each do |overlay|
            next unless overlay.visible? && overlay.bounds
            
            painter.save do
              b = overlay.bounds.not_nil!
              painter.clip(b.x, b.y, b.width, b.height)
              overlay.draw(painter)
            end
          end

          # ホバー中のコンポーネントにハイライト効果を適用
          if @config.highlight_hover && (hover = @hover_component)
            if hover.visible? && hover.bounds
              painter.save do
                b = hover.bounds.not_nil!
                painter.stroke_color = @theme.hover_highlight_color
                painter.stroke_width = 2
                painter.draw_rect(b.x, b.y, b.width, b.height)
              end
            end
          end

          # フォーカス中のコンポーネントにフォーカス効果を適用
          if @config.highlight_focus && (focus = @focus_manager.focused_component)
            if focus.visible? && focus.bounds
              painter.save do
                b = focus.bounds.not_nil!
                painter.stroke_color = @theme.focus_highlight_color
                painter.stroke_width = 2
                painter.stroke_dash = [4, 2]
                painter.draw_rect(b.x, b.y, b.width, b.height)
                painter.stroke_dash = nil
              end
            end
          end

          # デバッグ情報描画（開発モード時のみ）
          draw_debug_info(painter) if @config.debug_mode

          # フレーム完了
          painter.flush
          window.swap_buffers
          @needs_repaint = false
        rescue ex : Concave::Error
          Log.error "Concaveレンダリングエラー", exception: ex
          # 一時的なエラーなら次フレームで再試行
          @needs_repaint = true
        rescue ex
          Log.error "レンダーループ内で予期せぬエラーが発生", exception: ex
          show_error_dialog("描画エラー", ex.message || "不明なエラー")
        end
        end
    end

    # デバッグ情報を描画する
    private def draw_debug_info(painter : Concave::Painter)
      return unless @window
      
      window = @window.not_nil!
      w, h = window.size
      
      painter.save do
        painter.font = "monospace"
        painter.font_size = 12
        painter.fill_color = Concave::Color.new(255, 255, 0, 200)
        
        # FPS情報
        fps = calculate_fps
        painter.draw_text("FPS: #{fps}", 10, 20)
        
        # メモリ使用量
        mem = GC.stats
        painter.draw_text("メモリ: #{mem.heap_size / 1024}KB", 10, 40)
        
        # アクティブコンポーネント情報
        if comp = @focus_manager.focused_component
          painter.draw_text("フォーカス: #{comp.class.name}", 10, 60)
        end
        
        # アクティブページ情報
        if page_id = @core.page_manager.active_page_id
          if page = @core.page_manager.find_page(page_id)
            painter.draw_text("ページ: #{page.url} (#{page_id})", 10, 80)
          end
        end
        
        # レイアウト情報
        painter.draw_text("ウィンドウ: #{w}x#{h}", 10, 100)
        
        # コンポーネント数
        painter.draw_text("コンポーネント数: #{@components.size}", 10, 120)
        
        # 描画時間（ミリ秒）
        painter.draw_text("描画時間: #{@last_render_time.to_f.round(2)}ms", 10, 140)
        end
    end

    # FPSを計算する
    private def calculate_fps : Int32
      current_time = Time.monotonic
      
      if @last_fps_update.nil? || (current_time - @last_fps_update.not_nil!) > 1.seconds
        @last_fps_update = current_time
        @frame_count = 0
      end
      
      @frame_count = (@frame_count || 0) + 1
      
      # 直近1秒間のフレーム数から計算
      elapsed = (current_time - (@last_fps_time || current_time)).total_seconds
      @last_fps_time = current_time
      
      if elapsed > 0
        @current_fps = (@current_fps || 60.0) * 0.9 + (1.0 / elapsed) * 0.1
      end
      
      return @current_fps.not_nil!.to_i
    end

    # レイアウトを実行する
    private def perform_layout(width : Int32, height : Int32)
      Log.debug "#{width}x#{height}のサイズでレイアウトを実行中..."
      
      # レイアウト開始時間を記録
      start_time = Time.monotonic
      
      # メインレイアウトを実行
      @layout.layout(@components, width, height)
      
      # 特殊コンポーネントの位置調整
      if settings = find_component(SettingsInterface)
        settings.bounds = {width / 4, height / 4, width / 2, height / 2} if settings.visible?
      end
      
      if dialog = find_component(ErrorDialog)
        dialog.bounds = {width / 3, height / 3, width / 3, height / 3} if dialog.visible?
      end
      
      if menu = find_component(ContextMenu)
        # コンテキストメニューは表示時に位置設定されるため、ここでは調整しない
      end
      
      # オーバーレイコンポーネントのレイアウト
      @overlay_components.each do |overlay|
        if overlay.responds_to?(:layout)
          overlay.layout(width, height)
        end
    end

      # レイアウト完了時間を記録
      end_time = Time.monotonic
      layout_time = (end_time - start_time).total_milliseconds
      
      Log.debug "レイアウト完了 (#{layout_time.round(2)}ms)"
      
      # レイアウト変更イベントを発火
      fire_event(LayoutChangedEvent.new(width, height))
      
      request_repaint
    end

    # 初期レイアウトを実行する (ウィンドウ作成直後)
    private def perform_initial_layout
        return unless @window
        w, h = @window.not_nil!.size
        perform_layout(w, h)
    end

    # 型でコンポーネントを検索するヘルパー
    private def find_component(klass : T.class) : T? forall T
        @components.find { |c| c.is_a?(klass) }.as?(T)
    end

    # ナビゲーションコントロールの状態を更新するヘルパー
    private def update_nav_controls(can_back : Bool, can_forward : Bool)
        if nav_controls = find_component(NavigationControls)
            nav_controls.update_state(can_back, can_forward)
        end
    end

    # コンテキストメニューを表示する
    private def show_context_menu(x : Int32, y : Int32, items : Array(MenuItem))
       if menu = find_component(ContextMenu)
           menu.set_items(items)
           menu.show_at(x, y)
           @focus_manager.set_focus(menu) # メニューにフォーカスを移す
           request_repaint
       end
    end
