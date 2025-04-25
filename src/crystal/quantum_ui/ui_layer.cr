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

    def initialize
      @current_theme = :light
    end

    # ダーク/ライト切り替え
    def toggle
      @current_theme = @current_theme == :light ? :dark : :light
    end

    # 画面背景色を設定
    def apply(window : Concave::Window)
      case @current_theme
      when :light
        window.set_clear_color(0xFF_FF_FF, 1.0)
      when :dark
        window.set_clear_color(0x1E_1E_1E, 1.0)
      end
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

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config     = config
      @core       = core
      @theme      = ThemeEngine.new
      @layout     = LayoutEngine.new
      @components = [] of Component
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
end 