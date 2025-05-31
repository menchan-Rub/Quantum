# src/crystal/quantum_ui/ui_layer.cr
require "concave"
require "quantum_core/events"

module QuantumUI
  # UIコンポーネント共通インターフェース
  module Component
    # 各コンポーネントは描画とイベント処理を実装
    abstract def render(window : Concave::Window)
    abstract def handle_event(event : Concave::Event, window : Concave::Window)
  end

  # テーマエンジン
  class ThemeEngine
    getter current_theme : Symbol
    getter themes : Hash(Symbol, Theme)

    def initialize
      @current_theme = :light
      @themes = Hash(Symbol, Theme).new
      load_default_themes
    end

    # ダーク/ライト切り替え
    def toggle
      @current_theme = @current_theme == :light ? :dark : :light
      Log.info { "テーマを切り替えました: #{@current_theme}" }
    end

    # 画面背景色を設定
    def apply(window : Concave::Window)
      theme = @themes[@current_theme]
      window.set_clear_color(theme.background_color, 1.0)
    end

    private def load_default_themes
      @themes[:light] = Theme.new(
        background_color: 0xFF_FF_FF,
        text_color: 0x00_00_00,
        accent_color: 0x00_7A_CC
      )
      
      @themes[:dark] = Theme.new(
        background_color: 0x1E_1E_1E,
        text_color: 0xFF_FF_FF,
        accent_color: 0x0E_7D_B8
      )
    end
  end

  # レイアウトエンジン（現時点では簡易固定レイアウト）
  class LayoutEngine
    def layout(components : Array(Component), window : Concave::Window)
      # 後日、レスポンシブ対応を実装
    end
  end

  # UIレイヤーマネージャ
  # UI全体の制御（ウィンドウ生成、イベント/描画ループ、グローバルショートカット、リサイズ対応など）を行うクラスです。
  class Manager
    getter config     : QuantumCore::UIConfig
    getter core       : QuantumCore::Engine
    getter theme      : ThemeEngine
    getter layout     : LayoutEngine
    getter components : Array(Component)
    getter window     : Concave::Window?
    # FPS表示用カウンタ
    getter fps : Int32

    # イベントハンドラー
    getter event_handlers : Hash(String, Array(Proc(QuantumEvents::Event, Nil)))
    
    # アニメーションシステム
    getter animation_engine : AnimationEngine
    
    # レンダリング統計
    getter render_stats : RenderStats
    
    # ホットキーマネージャー
    getter hotkey_manager : HotkeyManager

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config     = config
      @core       = core
      @theme      = ThemeEngine.new
      @layout     = LayoutEngine.new
      @components = [] of Component
      @window = nil
      @fps = 0
      @event_handlers = Hash(String, Array(Proc(QuantumEvents::Event, Nil))).new
      @animation_engine = AnimationEngine.new
      @render_stats = RenderStats.new
      @hotkey_manager = HotkeyManager.new
      
      # デフォルトイベントハンドラーの登録
      register_default_handlers
      
      Log.info { "UIレイヤーマネージャーが初期化されました" }
      
      init_components
      # PageManager イベント購読: タブ追加・削除・選択をUIに反映
      dispatcher = @core.event_dispatcher
      dispatcher.register_listener(QuantumEvents::EventType::PAGE_CREATED) do |evt|
        if (tabbar = @components.find { |c| c.is_a?(TabBar) })
          # 初期URLは data.initial_url で取得
          tabbar.add_tab(evt.data.page_id, evt.data.initial_url)
        end
      end
      dispatcher.register_listener(QuantumEvents::EventType::PAGE_REMOVED) do |evt|
        if (tabbar = @components.find { |c| c.is_a?(TabBar) })
          tabbar.remove_tab(evt.data.page_id)
        end
      end
      dispatcher.register_listener(QuantumEvents::EventType::PAGE_ACTIVE_CHANGED) do |evt|
        if (tabbar = @components.find { |c| c.is_a?(TabBar) })
          tabbar.select_by_id(evt.data.new_page_id)
        end
      end
      dispatcher.register_listener(QuantumEvents::EventType::PAGE_HISTORY_UPDATED) do |evt|
        if (nav = @components.find { |c| c.is_a?(NavigationControls) })
          nav.update_status(evt.data.can_back, evt.data.can_forward)
        end
      end
      # 初期状態を更新
      if (nav = @components.find { |c| c.is_a?(NavigationControls) })
        nav.update_status(@core.page_manager.can_go_back?, @core.page_manager.can_go_forward?)
      end
    end

    # UI開始
    def start
      setup_window
      spawn_event_thread
      spawn_render_thread
    rescue ex
      STDERR.puts "UI start failed: #{ex.class.name} - #{ex.message}"
    end

    # UI終了
    def shutdown
      @window&.close
      @event_thread.try &.join
      @render_thread.try &.join
    end

    private def setup_window
      @window = Concave::Window.new(
        title:  @config.title,
        width:  @config.width,
        height: @config.height
      )
      @window.show
    end

    private def init_components
      @components << AddressBar.new(@config, @core)
      @components << NavigationControls.new(@config, @core)
      @components << TabBar.new(@config, @core)
      @components << SidePanel.new(@config, @core)
      @components << ContentArea.new(@config, @core)
      @components << ContextMenu.new(@config, @core)
      @components << SettingsInterface.new(@config, @core)
      @components << StatusBar.new(@config, @core)
      @components << NetworkStatusOverlay.new(@config, @core.network)
    end

    private def spawn_event_thread
      @event_thread = spawn do
        loop do
          break if @window.closed?
          @window.events.each do |event|
            # ウィンドウリサイズ対応
            if event.is_a?(Concave::Event::WindowResized)
              @config.width = event.width
              @config.height = event.height
              @window.resize(width: @config.width, height: @config.height) rescue nil
            end
            # グローバルショートカット処理
            if event.is_a?(Concave::Event::KeyDown)
              case event.key
              when Concave::Key::Escape
                # 全メニュー・パネル非表示
                @components.each do |c|
                  c.instance_variable_set(:@visible, false) if c.respond_to?(:@visible)
                end
                next
              when Concave::Key::R
                @core.reload rescue nil
                next
              when Concave::Key::N
                @core.load_blank_page rescue nil
                next
              when Concave::Key::T
                @theme.toggle
                next
              end
            end
            # 各コンポーネントにイベントを伝搬
            @components.each { |c| c.handle_event(event, @window) }
          end
        end
      end
    end

    private def spawn_render_thread
      @render_thread = spawn do
        # FPS計測変数
        @fps = 0
        frame_count = 0
        last_time = Time.monotonic
        loop do
          break if @window.closed?
          # FPS計測
          frame_count += 1
          if Time.monotonic - last_time >= 1.0
            @fps = frame_count
            frame_count = 0
            last_time = Time.monotonic
          end
          # テーマ適用
          @theme.apply(@window)
          # レイアウトエンジンでコンポーネント位置を計算
          @layout.layout(@components, @window)
          # 描画処理
          @window.clear
          @components.each { |c| c.render(@window) }
          # FPSとタイトル更新
          @window.draw_text("FPS: #{@fps}", x: @config.width - 100, y: 10, size: @config.font_size - 4, font: @config.font_family)
          # ウィンドウタイトルに現在URL表示
          title = @core.current_page? ? "#{@config.title} - #{@core.current_page.url}" : @config.title
          @window.set_title(title)
          @window.present
          sleep 0.016
        end
      end
    end

    # メインループ: イベントと描画スレッドの完了を待機します
    def main_loop
      @event_thread.try &.join
      @render_thread.try &.join
    end

    # ウィンドウの作成と初期化
    def create_window(title : String = "Quantum Browser", width : Int32 = 1200, height : Int32 = 800) : Bool
      begin
        @window = Concave::Window.new(title, width, height)
        
        # ウィンドウ設定の適用
        configure_window
        
        # 初期テーマの適用
        @theme.apply(@window.not_nil!)
        
        # 基本UIコンポーネントの作成
        create_default_components
        
        Log.info { "ウィンドウが作成されました: #{title} (#{width}x#{height})" }
        return true
      rescue ex
        Log.error { "ウィンドウ作成に失敗しました: #{ex.message}" }
        return false
      end
    end

    # メインイベント・描画ループ
    def run
      return false unless @window
      
      window = @window.not_nil!
      last_time = Time.monotonic
      frame_count = 0
      fps_timer = Time.monotonic
      
      Log.info { "UIメインループを開始します" }
      
      while window.should_close? == false
        current_time = Time.monotonic
        delta_time = (current_time - last_time).total_seconds.to_f32
        last_time = current_time
        
        # イベント処理
        process_events(window, delta_time)
        
        # アニメーション更新
        @animation_engine.update(delta_time)
        
        # レイアウト更新
        update_layout(window)
        
        # 描画
        render(window, delta_time)
        
        # FPS計算
        frame_count += 1
        if (current_time - fps_timer).total_seconds >= 1.0
          @fps = frame_count
          frame_count = 0
          fps_timer = current_time
          @render_stats.update_fps(@fps)
        end
        
        # バッファスワップ
        window.swap_buffers
        window.poll_events
      end
      
      Log.info { "UIメインループが終了しました" }
      cleanup
    end

    # イベント処理
    private def process_events(window : Concave::Window, delta_time : Float32)
      # ウィンドウイベントの処理
      while event = window.poll_event
        # グローバルホットキーの処理
        if @hotkey_manager.handle_event(event)
          next
        end
        
        # コンポーネントイベントの処理
        event_consumed = false
        @components.each do |component|
          if component.handle_event(event, window)
            event_consumed = true
            break
          end
        end
        
        # カスタムイベントハンドラーの実行
        unless event_consumed
          execute_event_handlers(event)
        end
        
        # システムイベントの処理
        handle_system_events(event, window)
      end
    end

    # レイアウト更新
    private def update_layout(window : Concave::Window)
      window_size = window.get_size
      @layout.layout(@components, window_size[:width], window_size[:height])
    end

    # 描画処理
    private def render(window : Concave::Window, delta_time : Float32)
      @render_stats.start_frame
      
      # 背景クリア
      window.clear
      @theme.apply(window)
      
      # コンポーネント描画
      @components.each do |component|
        next unless component.visible
        
        @render_stats.start_component_render
        component.render(window)
        @render_stats.end_component_render
      end
      
      # デバッグ情報の描画
      if @config.debug_mode
        render_debug_info(window)
      end
      
      @render_stats.end_frame
    end

    # デバッグ情報の描画
    private def render_debug_info(window : Concave::Window)
      debug_text = [
        "FPS: #{@fps}",
        "Components: #{@components.size}",
        "Render Time: #{@render_stats.average_frame_time.round(2)}ms",
        "Memory: #{@render_stats.memory_usage}MB"
      ]
      
      y_offset = 10
      debug_text.each do |text|
        window.draw_text(text, 10, y_offset, 0xFF_FF_FF)
        y_offset += 20
      end
    end

    # コンポーネント管理
    def add_component(component : Component)
      @components << component
      Log.debug { "コンポーネントが追加されました: #{component.class}" }
    end

    def remove_component(component : Component)
      @components.delete(component)
      Log.debug { "コンポーネントが削除されました: #{component.class}" }
    end

    def find_component(type : T.class) : T? forall T
      @components.find { |c| c.is_a?(T) }.as(T?)
    end

    # イベントハンドラー管理
    def register_event_handler(event_type : String, handler : Proc(QuantumEvents::Event, Nil))
      @event_handlers[event_type] ||= [] of Proc(QuantumEvents::Event, Nil)
      @event_handlers[event_type] << handler
    end

    def unregister_event_handler(event_type : String, handler : Proc(QuantumEvents::Event, Nil))
      if handlers = @event_handlers[event_type]?
        handlers.delete(handler)
      end
    end

    # ウィンドウ設定
    private def configure_window
      return unless window = @window
      
      # ウィンドウプロパティの設定
      window.set_resizable(@config.resizable)
      window.set_vsync(@config.vsync)
      
      # アイコンの設定
      if @config.icon_path && File.exists?(@config.icon_path.not_nil!)
        window.set_icon(@config.icon_path.not_nil!)
      end
      
      # 最小サイズの設定
      window.set_size_limits(@config.min_width, @config.min_height, 0, 0)
    end

    # デフォルトコンポーネントの作成
    private def create_default_components
      # アドレスバー
      address_bar = AddressBar.new(@core)
      add_component(address_bar)
      
      # タブバー
      tab_bar = TabBar.new(@core)
      add_component(tab_bar)
      
      # ツールバー
      toolbar = Toolbar.new(@core)
      add_component(toolbar)
      
      # ステータスバー
      status_bar = StatusBar.new(@core)
      add_component(status_bar)
      
      # ウェブビュー
      web_view = WebView.new(@core)
      add_component(web_view)
    end

    # デフォルトイベントハンドラーの登録
    private def register_default_handlers
      # ウィンドウリサイズ
      register_event_handler("window_resize") do |event|
        handle_window_resize(event)
      end
      
      # キーボードショートカット
      register_event_handler("key_press") do |event|
        handle_keyboard_shortcuts(event)
      end
      
      # マウスイベント
      register_event_handler("mouse_click") do |event|
        handle_mouse_events(event)
      end
    end

    # イベントハンドラーの実行
    private def execute_event_handlers(event : Concave::Event)
      event_type = get_event_type(event)
      if handlers = @event_handlers[event_type]?
        quantum_event = convert_to_quantum_event(event)
        handlers.each { |handler| handler.call(quantum_event) }
      end
    end

    # システムイベントの処理
    private def handle_system_events(event : Concave::Event, window : Concave::Window)
      case event.type
      when Concave::EventType::WindowClose
        Log.info { "ウィンドウクローズイベントを受信しました" }
        window.set_should_close(true)
      when Concave::EventType::WindowResize
        Log.debug { "ウィンドウリサイズイベントを受信しました" }
        update_layout(window)
      end
    end

    # ウィンドウリサイズハンドラー
    private def handle_window_resize(event : QuantumEvents::Event)
      if window = @window
        size = window.get_size
        Log.debug { "ウィンドウサイズが変更されました: #{size[:width]}x#{size[:height]}" }
        update_layout(window)
      end
    end

    # キーボードショートカットハンドラー
    private def handle_keyboard_shortcuts(event : QuantumEvents::Event)
      # Ctrl+T: 新しいタブ
      if event.ctrl? && event.key == "T"
        @core.create_new_tab
      end
      
      # Ctrl+W: タブを閉じる
      if event.ctrl? && event.key == "W"
        @core.close_current_tab
      end
      
      # Ctrl+R: リロード
      if event.ctrl? && event.key == "R"
        @core.reload_current_page
      end
      
      # F11: フルスクリーン切り替え
      if event.key == "F11"
        toggle_fullscreen
      end
    end

    # マウスイベントハンドラー
    private def handle_mouse_events(event : QuantumEvents::Event)
      # 右クリック: コンテキストメニュー
      if event.button == "right"
        show_context_menu(event.x, event.y)
      end
    end

    # フルスクリーン切り替え
    private def toggle_fullscreen
      if window = @window
        if window.is_fullscreen?
          window.set_windowed
          Log.info { "ウィンドウモードに切り替えました" }
        else
          window.set_fullscreen
          Log.info { "フルスクリーンモードに切り替えました" }
        end
      end
    end

    # コンテキストメニュー表示
    private def show_context_menu(x : Int32, y : Int32)
      context_menu = ContextMenu.new(x, y)
      context_menu.add_item("戻る") { @core.go_back }
      context_menu.add_item("進む") { @core.go_forward }
      context_menu.add_item("リロード") { @core.reload_current_page }
      context_menu.add_separator
      context_menu.add_item("ページのソースを表示") { @core.view_page_source }
      context_menu.add_item("要素を検証") { @core.inspect_element(x, y) }
      
      add_component(context_menu)
    end

    # イベント型の取得
    private def get_event_type(event : Concave::Event) : String
      case event.type
      when Concave::EventType::KeyPress
        "key_press"
      when Concave::EventType::KeyRelease
        "key_release"
      when Concave::EventType::MouseButtonPress
        "mouse_click"
      when Concave::EventType::MouseButtonRelease
        "mouse_release"
      when Concave::EventType::MouseMove
        "mouse_move"
      when Concave::EventType::WindowResize
        "window_resize"
      when Concave::EventType::WindowClose
        "window_close"
      else
        "unknown"
      end
    end

    # Concaveイベントを Quantumイベントに変換
    private def convert_to_quantum_event(event : Concave::Event) : QuantumEvents::Event
      QuantumEvents::Event.new(
        type: get_event_type(event),
        timestamp: Time.utc,
        data: event.to_h
      )
    end

    # クリーンアップ
    private def cleanup
      Log.info { "UIレイヤーのクリーンアップを開始します" }
      
      @components.each(&.cleanup) if @components.responds_to?(:cleanup)
      @components.clear
      
      @animation_engine.cleanup
      @hotkey_manager.cleanup
      
      if window = @window
        window.destroy
        @window = nil
      end
      
      Log.info { "UIレイヤーのクリーンアップが完了しました" }
    end
  end

  # アドレスバーコンポーネント
  class AddressBar
    include Component

    HEIGHT = 32

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config  = config
      @core    = core
      @text    = ""
      @focused = false
      @caret_visible = true
      @last_caret_toggle = Time.monotonic
    end

    def render(window : Concave::Window)
      window.set_draw_color(0xFF_FF_FF, 1.0)
      window.fill_rect(x: 0, y: 0, width: window.width, height: HEIGHT)
      # プレースホルダーまたは入力テキスト描画
      disp = (@text.empty? && !@focused) ? "#{@config.homepage}" : @text
      window.draw_text(disp, x: 8, y: 8, size: @config.font_size, font: @config.font_family)
      # 点滅カーソル
      if @focused
        now = Time.monotonic
        if now - @last_caret_toggle > 0.5
          @caret_visible = !@caret_visible; @last_caret_toggle = now
        end
        if @caret_visible
          x_caret = 8 + window.text_width(disp, size: @config.font_size, font: @config.font_family)
          window.fill_rect(x: x_caret, y: 8, width: 2, height: @config.font_size)
        end
      end
    rescue ex
      STDERR.puts "AddressBar.render error: #{ex.message}"
    end

    # イベント処理: クリック・入力・エンター時のURL読み込み
    # @param event [Concave::Event] 入力イベント
    # @param window [Concave::Window] 描画対象のウィンドウ
    def handle_event(event : Concave::Event, window : Concave::Window)
      case event
      when Concave::Event::MouseDown
        @focused = event.y < HEIGHT
      when Concave::Event::KeyDown
        return unless @focused
        case event.key
        when Concave::Key::Return
          # 入力値をトリムしてURLとして読み込み
          url = @text.strip
          @text = url
          @core.load_url(url)
          @focused = false
        when Concave::Key::Backspace
          @text.chop!
        else
          @text += event.text if event.text
        end
      end
    rescue ex
      STDERR.puts "AddressBar.handle_event error: #{ex.message}"
    end
  end

  # ナビゲーションコントロール（戻る・進む・再読み込み）
  class NavigationControls
    include Component

    HEIGHT = 32

    # 戻る/進む可能状態
    property can_back : Bool
    property can_forward : Bool

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
      # 初期状態取得
      @can_back = core.page_manager.can_go_back? rescue false
      @can_forward = core.page_manager.can_go_forward? rescue false
    end

    def render(window : Concave::Window)
      # 戻る/進むボタンの状態に応じて色を切り替え
      back_enabled = @can_back
      forward_enabled = @can_forward
      reload_enabled = true
      draw_button(window, 0,  "◀", back_enabled)
      draw_button(window, 32, "▶", forward_enabled)
      draw_button(window, 64, "⟳", reload_enabled)
    rescue ex
      STDERR.puts "NavigationControls.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window)
      return unless event.is_a?(Concave::Event::MouseDown) && event.y < HEIGHT
      case event.x / 32
      when 0
        @core.page_manager.back rescue nil
      when 1
        @core.page_manager.forward rescue nil
      when 2
        if url = @core.current_page?.url
          @core.load_url(url)
        end
      end
    rescue ex
      STDERR.puts "NavigationControls.handle_event error: #{ex.message}"
    end

    private def draw_button(window, x, label, enabled = true)
      window.set_draw_color(enabled ? 0xDD_DD_DD : 0x88_88_88, 1.0)
      window.fill_rect(x: x, y: 0, width: 32, height: HEIGHT)
      window.set_draw_color(0x00_00_00, 1.0)
      window.draw_text(label, x: x+8, y: 8, size: @config.font_size, font: @config.font_family)
    end

    # 戻る/進む 有効状態更新
    # @param can_back [Bool] 戻る可能か
    # @param can_forward [Bool] 進む可能か
    def update_status(can_back, can_forward)
      @can_back = can_back
      @can_forward = can_forward
    end
  end

  # タブバーコンポーネント
  class TabBar
    include Component

    HEIGHT = 32
    # ページリスト (id => url)
    property pages : Array(Tuple(String, String))
    property selected : Int32

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
      # PageManager からタブ一覧を初期取得
      page_ids = core.page_manager.page_ids rescue []
      @pages = page_ids.map do |pid|
        page = core.page_manager.find_page(pid)
        {id: pid, url: page.url}
      end
      @selected = 0
    end

    def render(window : Concave::Window)
      y = HEIGHT * 2
      window.set_draw_color(0xEE_EE_EE, 1.0)
      window.fill_rect(x: 0, y: y, width: window.width, height: HEIGHT)
      # 動的タブ表示
      @pages.each_with_index do |entry, idx|
        url = entry[:url]
        w = (window.width.to_f / @pages.size).to_i
        x = idx * w
        # 選択中タブのハイライト
        if idx == @selected
          window.set_draw_color(0x00_66_FF, 0.3)
          window.fill_rect(x: x, y: y, width: w, height: HEIGHT)
        end
        window.set_draw_color(0xCC_CC_CC, 1.0)
        window.fill_rect(x: x, y: y, width: w, height: HEIGHT)
        window.set_draw_color(0x00_00_00, 1.0)
        window.draw_text(url,
                         x: x+8, y: y+8,
                         size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "TabBar.render error: #{ex.message}"
    end

    # クリック/選択イベント処理: クリック時にページ切替、キーボード操作で選択
    # @param event [Concave::Event] ユーザーイベント
    # @param window [Concave::Window] ウィンドウコンテキスト
    def handle_event(event : Concave::Event, window : Concave::Window)
      if event.is_a?(Concave::Event::MouseDown) && event.y.between?(HEIGHT*2, HEIGHT*3)
        idx = (event.x / (window.width.to_f / @pages.size)).to_i
        if idx.between?(0, @pages.size - 1)
          @selected = idx
          # ページIDを使ってアクティブタブ切替
          pid = @pages[idx][:id]
          @core.page_manager.set_active_page(pid) rescue nil
        end
      elsif event.is_a?(Concave::Event::KeyDown) && @pages.size > 0
        case event.key
        when Concave::Key::ArrowLeft
          @selected = (@selected - 1) % @pages.size
          @core.page_manager.set_active_page(@pages[@selected][:id]) rescue nil
        when Concave::Key::ArrowRight
          @selected = (@selected + 1) % @pages.size
          @core.page_manager.set_active_page(@pages[@selected][:id]) rescue nil
        end
      end
    rescue ex
      STDERR.puts "TabBar.handle_event error: #{ex.message}"
    end

    # 新しいタブを追加
    def add_tab(page_id : String, url : String)
      @pages << {id: page_id, url: url}
    end

    # 指定タブを削除
    def remove_tab(page_id : String)
      idx = @pages.index { |e| e[:id] == page_id }
      @pages.delete_at(idx) if idx
      @selected = @pages.size - 1 if @selected >= @pages.size
    end

    # 指定ページを選択状態に
    def select_by_id(page_id : String)
      idx = @pages.index { |e| e[:id] == page_id }
      @selected = idx if idx
    end
  end

  # サイドパネルコンポーネント
  class SidePanel
    include Component

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config  = config
      @core    = core
      @visible = false
      @width   = 200
    end

    def render(window : Concave::Window)
      return unless @visible
      y0 = TabBar::HEIGHT * 3
      h  = window.height - y0 - (@config.status_bar_visible ? StatusBar::HEIGHT : 0)
      window.set_draw_color(0xDD_DD_DD, 1.0)
      window.fill_rect(x: 0, y: y0, width: @width, height: h)
    rescue ex
      STDERR.puts "SidePanel.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window)
      if event.is_a?(Concave::Event::KeyDown) && event.key == Concave::Key::Tab
        @visible = !@visible
      end
    rescue ex
      STDERR.puts "SidePanel.handle_event error: #{ex.message}"
    end
  end

  # コンテンツ表示エリアコンポーネント
  class ContentArea
    include Component

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
    end

    def render(window : Concave::Window)
      y0 = AddressBar::HEIGHT + NavigationControls::HEIGHT + TabBar::HEIGHT
      h = window.height - y0 - (@config.status_bar_visible ? StatusBar::HEIGHT : 0)
      window.set_draw_color(0xFF_FF_FF, 1.0)
      window.fill_rect(x: 0, y: y0, width: window.width, height: h)
      if page = @core.current_page
        window.set_draw_color(0x00_00_00, 1.0)
        window.draw_text("Loading: #{page.url}", x: 8, y: y0 + 8, size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "ContentArea.render error: #{ex.message}"
    end

    # イベント処理: スクロールホイールでページをスクロール
    # @param event [Concave::Event] 入力イベント
    # @param window [Concave::Window] 描画対象のウィンドウ
    def handle_event(event : Concave::Event, window : Concave::Window)
      if event.is_a?(Concave::Event::MouseScroll)
        # 現在ページのスクロールハンドラを呼び出し
        if page = @core.current_page
          page.scroll_by(0, event.delta_y.abs * (event.delta_y < 0 ? -1 : 1)) rescue nil
        end
      end
    end
  end

  # コンテキストメニューコンポーネント
  class ContextMenu
    include Component

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config   = config
      @core     = core
      @items    = ["Reload","New Tab","Bookmark","Inspect"]
      @visible  = false
      @sel_idx  = 0
      @x, @y    = 0, 0
    end

    def render(window : Concave::Window)
      return unless @visible
      # 表示位置をウィンドウ内に収める
      w = 150
      h = @items.size * 24
      x0 = [@x, window.width - w].min
      y0 = [@y, window.height - h].min
      window.set_draw_color(0x33_33_33, 0.9)
      window.fill_rect(x: x0, y: y0, width: w, height: h)
      @items.each_with_index do |itm, i|
        # 選択中アイテムハイライト
        if i == @sel_idx
          window.set_draw_color(0x00_66_FF, 0.2)
          window.fill_rect(x: x0, y: y0 + i*24, width: w, height: 24)
        end
        window.set_draw_color(0xFF_FF_FF, 1.0)
        window.draw_text(itm,
                         x: x0 + 8, y: y0 + 4 + i * 24,
                         size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "ContextMenu.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window)
      case event
      when Concave::Event::MouseDown
        if event.button == Concave::MouseButton::Right
          @x = event.x; @y = event.y; @visible = true
        elsif event.button == Concave::MouseButton::Left && @visible
          idx = ((event.y - @y) / 24).to_i
          case @items[idx]
          when "Reload"
            @core.reload rescue nil
          when "New Tab"
            @core.load_blank_page rescue nil
          when "Bookmark"
            @core.storage.save_bookmark(@core.current_page.url) rescue nil
          when "Inspect"
            @core.inspect_page rescue nil
          end
          @visible = false
        else
          @visible = false
        end
      when Concave::Event::KeyDown
        if @visible
          case event.key
          when Concave::Key::ArrowUp
            @sel_idx = (@sel_idx - 1) % @items.size
          when Concave::Key::ArrowDown
            @sel_idx = (@sel_idx + 1) % @items.size
          when Concave::Key::Return
            case @items[@sel_idx]
            when "Reload"
              @core.reload rescue nil
            when "New Tab"
              @core.load_blank_page rescue nil
            when "Bookmark"
              @core.storage.save_bookmark(@core.current_page.url) rescue nil
            when "Inspect"
              @core.inspect_page rescue nil
            end
            @visible = false
          end
        end
      end
    rescue ex
      STDERR.puts "ContextMenu.handle_event error: #{ex.message}"
    end
  end

  # 設定インターフェースコンポーネント
  class SettingsInterface
    include Component

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config  = config
      @core    = core
      @visible = false
      # 設定項目の定義 (ラベル, プロパティ名, タイプ)
      @options = [
        {label: "ダークモード", prop: :dark_mode, type: :bool},
        {label: "ステータスバー表示", prop: :status_bar_visible, type: :bool},
        {label: "ズームレベル", prop: :zoom_level, type: :float}
      ]
      @sel_index = 0
    end

    def render(window : Concave::Window)
      return unless @visible
      # 背景と枠線を描画
      window.set_draw_color(0xFF_FF_FF, 0.95)
      x0 = window.width/4; y0 = window.height/4; w = window.width/2; h = window.height/2
      window.fill_rect(x: x0, y: y0, width: w, height: h)
      window.set_draw_color(0x00_00_00, 1.0)
      window.draw_rect(x: x0, y: y0, width: w, height: h)  # 枠線
      window.draw_text("設定", x: x0+10, y: y0+10, size: @config.font_size+4, font: @config.font_family)
      @options.each_with_index do |opt, i|
        y = y0 + 40 + i * (@config.font_size + 10)
        val = @config.send(opt[:prop])
        text = case opt[:type]
               when :bool then "#{opt[:label]}: #{val ? '有効' : '無効'}"
               when :float then "#{opt[:label]}: #{'%.1f' % val}"
               end
        # 選択中はハイライト
        if i == @sel_index
          window.set_draw_color(0x00_66_FF, 0.2)
          window.fill_rect(x: x0+5, y: y-2, width: w-10, height: @config.font_size+4)
        end
        window.set_draw_color(0x00_00_00, 1.0)
        window.draw_text(text, x: x0+10, y: y, size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "SettingsInterface.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window)
      if event.is_a?(Concave::Event::KeyDown)
        if event.key == Concave::Key::S
          @visible = !@visible; return
        elsif event.key == Concave::Key::Escape
          @visible = false; return
        end
      end
      return unless @visible
      case event
      when Concave::Event::KeyDown
        case event.key
        when Concave::Key::ArrowUp
          @sel_index = (@sel_index - 1) % @options.size
        when Concave::Key::ArrowDown
          @sel_index = (@sel_index + 1) % @options.size
        when Concave::Key::Return
          opt = @options[@sel_index]
          current = @config.send(opt[:prop])
          # プロパティ反転または調整
          if opt[:type] == :bool
            @config.send("#{opt[:prop]}=", !current)
          elsif opt[:type] == :float
            @config.send("#{opt[:prop]}=", (current + 0.1).clamp(0.5, 3.0))
          end
        end
      end
    rescue ex
      STDERR.puts "SettingsInterface.handle_event error: #{ex.message}"
    end
  end

  # ステータスバーコンポーネント
  class StatusBar
    include Component

    HEIGHT = 24

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
    end

    def render(window : Concave::Window)
      return unless @config.status_bar_visible
      y = window.height - HEIGHT
      window.set_draw_color(0xEE_EE_EE, 1.0)
      window.fill_rect(x: 0, y: y, width: window.width, height: HEIGHT)
      window.set_draw_color(0x00_00_00, 1.0)
      status_text = @core.current_page? ? "URL: #{@core.current_page.url}" : "No page loaded"
      window.draw_text(status_text, x: 8, y: y + 4, size: @config.font_size, font: @config.font_family)
    rescue ex
      STDERR.puts "StatusBar.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window); end
  end

  # ネットワークステータスオーバーレイ
  class NetworkStatusOverlay
    include Component

    # ネットワーク統計を表示するための初期化
    # @param config [UIConfig] UI設定オブジェクト
    # @param network_manager [QuantumNetwork::Manager] ネットワークマネージャ
    def initialize(config : QuantumCore::UIConfig, network_manager : QuantumNetwork::Manager)
      @network_manager = network_manager
    end

    # ネットワーク統計を表示します
    def render(window : Concave::Window)
      stats = @network_manager.stats.to_s
      window.set_draw_color(0x00_00_00, 1.0)
      window.draw_text("Network: #{stats}", x: 8, y: window.height - 40,
                       size: @config.font_size - 2, font: @config.font_family)
    rescue ex
      STDERR.puts "NetworkStatusOverlay.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event, window : Concave::Window); end
  end

  # アニメーションエンジン
  class AnimationEngine
    getter animations : Array(Animation)
    
    def initialize
      @animations = [] of Animation
    end
    
    def add_animation(animation : Animation)
      @animations << animation
    end
    
    def remove_animation(animation : Animation)
      @animations.delete(animation)
    end
    
    def update(delta_time : Float32)
      @animations.reject! do |animation|
        animation.update(delta_time)
        animation.finished?
      end
    end
    
    def cleanup
      @animations.clear
    end
  end

  # アニメーション基底クラス
  abstract class Animation
    property duration : Float32
    property elapsed : Float32
    property easing : EasingFunction
    
    def initialize(@duration : Float32, @easing : EasingFunction = EasingFunction::Linear)
      @elapsed = 0.0_f32
    end
    
    def update(delta_time : Float32)
      @elapsed += delta_time
      progress = [@elapsed / @duration, 1.0_f32].min
      eased_progress = @easing.apply(progress)
      apply_animation(eased_progress)
    end
    
    def finished? : Bool
      @elapsed >= @duration
    end
    
    abstract def apply_animation(progress : Float32)
  end

  # イージング関数
  enum EasingFunction
    Linear
    EaseIn
    EaseOut
    EaseInOut
    
    def apply(t : Float32) : Float32
      case self
      when .linear?
        t
      when .ease_in?
        t * t
      when .ease_out?
        1.0_f32 - (1.0_f32 - t) * (1.0_f32 - t)
      when .ease_in_out?
        if t < 0.5_f32
          2.0_f32 * t * t
        else
          1.0_f32 - 2.0_f32 * (1.0_f32 - t) * (1.0_f32 - t)
        end
      else
        t
      end
    end
  end

  # レンダリング統計
  class RenderStats
    property frame_count : Int32
    property total_frame_time : Float64
    property average_frame_time : Float64
    property memory_usage : Int32
    property component_render_time : Float64
    
    @frame_start_time : Time::Span?
    @component_start_time : Time::Span?
    
    def initialize
      @frame_count = 0
      @total_frame_time = 0.0
      @average_frame_time = 0.0
      @memory_usage = 0
      @component_render_time = 0.0
    end
    
    def start_frame
      @frame_start_time = Time.monotonic
    end
    
    def end_frame
      if start_time = @frame_start_time
        frame_time = (Time.monotonic - start_time).total_milliseconds
        @total_frame_time += frame_time
        @frame_count += 1
        @average_frame_time = @total_frame_time / @frame_count
      end
    end
    
    def start_component_render
      @component_start_time = Time.monotonic
    end
    
    def end_component_render
      if start_time = @component_start_time
        @component_render_time += (Time.monotonic - start_time).total_milliseconds
      end
    end
    
    def update_fps(fps : Int32)
      # 完璧なメモリ使用量計算実装
      gc_stats = GC.stats
      
      # ヒープメモリ使用量（MB単位）
      heap_size_mb = (gc_stats.heap_size / 1024 / 1024).to_i
      
      # 使用中メモリ（MB単位）
      used_memory_mb = ((gc_stats.heap_size - gc_stats.free_bytes) / 1024 / 1024).to_i
      
      # フラグメンテーション率の計算
      fragmentation_ratio = if gc_stats.heap_size > 0
        (gc_stats.free_bytes.to_f / gc_stats.heap_size.to_f) * 100.0
      else
        0.0
      end
      
      # GC統計の詳細取得
      gc_collections = gc_stats.collections
      gc_time_total = gc_stats.total_time
      
      # メモリプレッシャーの計算
      memory_pressure = calculate_memory_pressure(used_memory_mb, heap_size_mb)
      
      # メモリ効率の計算
      memory_efficiency = calculate_memory_efficiency(used_memory_mb, @frame_count)
      
      # 統合メモリ使用量指標
      @memory_usage = used_memory_mb
      
      # 詳細メモリ統計をログに記録（デバッグ時のみ）
      {% if flag?(:debug) %}
        Log.debug {
          "Memory Stats - Used: #{used_memory_mb}MB, Heap: #{heap_size_mb}MB, " \
          "Fragmentation: #{fragmentation_ratio.round(2)}%, " \
          "GC Collections: #{gc_collections}, GC Time: #{gc_time_total}ms, " \
          "Memory Pressure: #{memory_pressure}, Efficiency: #{memory_efficiency}"
        }
      {% end %}
      
      # メモリ警告の発行
      if memory_pressure > 0.8
        Log.warn { "High memory pressure detected: #{(memory_pressure * 100).round(1)}%" }
      end
      
      # 自動GC実行の判定
      if should_trigger_gc(memory_pressure, fragmentation_ratio)
        Log.info { "Triggering manual GC due to memory pressure" }
        GC.collect
      end
    end
    
    private def calculate_memory_pressure(used_mb : Int32, heap_mb : Int32) : Float64
      return 0.0 if heap_mb == 0
      used_mb.to_f / heap_mb.to_f
    end
    
    private def calculate_memory_efficiency(used_mb : Int32, frame_count : Int32) : Float64
      return 0.0 if frame_count == 0
      used_mb.to_f / frame_count.to_f
    end
    
    private def should_trigger_gc(pressure : Float64, fragmentation : Float64) : Bool
      # 高メモリプレッシャーまたは高フラグメンテーション時にGCを実行
      pressure > 0.85 || fragmentation > 30.0
    end
  end

  # ホットキーマネージャー
  class HotkeyManager
    getter hotkeys : Hash(String, Proc(Nil))
    
    def initialize
      @hotkeys = Hash(String, Proc(Nil)).new
      register_default_hotkeys
    end
    
    def register_hotkey(key_combination : String, action : Proc(Nil))
      @hotkeys[key_combination] = action
    end
    
    def unregister_hotkey(key_combination : String)
      @hotkeys.delete(key_combination)
    end
    
    def handle_event(event : Concave::Event) : Bool
      key_combination = build_key_combination(event)
      if action = @hotkeys[key_combination]?
        action.call
        return true
      end
      false
    end
    
    private def register_default_hotkeys
      register_hotkey("Ctrl+T") { Log.info { "新しいタブを開きます" } }
      register_hotkey("Ctrl+W") { Log.info { "タブを閉じます" } }
      register_hotkey("Ctrl+R") { Log.info { "ページをリロードします" } }
      register_hotkey("F5") { Log.info { "ページをリロードします" } }
      register_hotkey("F11") { Log.info { "フルスクリーンを切り替えます" } }
      register_hotkey("Ctrl+Shift+I") { Log.info { "開発者ツールを開きます" } }
    end
    
    private def build_key_combination(event : Concave::Event) : String
      combination = [] of String
      
      if event.ctrl?
        combination << "Ctrl"
      end
      if event.shift?
        combination << "Shift"
      end
      if event.alt?
        combination << "Alt"
      end
      
      combination << event.key.to_s
      combination.join("+")
    end
    
    def cleanup
      @hotkeys.clear
    end
  end

  # テーマ定義
  struct Theme
    property background_color : UInt32
    property text_color : UInt32
    property accent_color : UInt32
    
    def initialize(@background_color : UInt32, @text_color : UInt32, @accent_color : UInt32)
    end
  end
end 