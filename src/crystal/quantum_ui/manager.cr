# src/crystal/quantum_ui/manager.cr
require "concave"

module QuantumUI
  # UIコンポーネント共通インターフェース
  module Component
    # コンポーネントを描画します
    abstract def render(window : Concave::Window)
    # イベントを処理します
    abstract def handle_event(event : Concave::Event)
  end

  # UIレイヤーのメインマネージャ
  class Manager
    getter config : QuantumCore::UIConfig
    getter core   : QuantumCore::Engine
    getter components   : Array(Component)
    getter theme_engine : ThemeEngine

    # @!visibility private
    getter window : Concave::Window?

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config       = config
      @core         = core
      @window       = nil
      @components   = [] of Component
      @theme_engine = ThemeEngine.new(@config.theme, @config.dark_mode)

      # ツールバー (ナビゲーション + アドレスバー)
      if @config.toolbar_visible
        @components << NavigationControls.new(@config, @core)
        @components << AddressBar.new(@config, @core)
      end

      # タブバー (位置に応じて前後に配置)
      case @config.tab_position
      when QuantumCore::UIConfig::TabPosition::TOP, QuantumCore::UIConfig::TabPosition::LEFT
        @components.insert(0, TabBar.new(@config, @core))
      when QuantumCore::UIConfig::TabPosition::BOTTOM, QuantumCore::UIConfig::TabPosition::RIGHT
        @components << TabBar.new(@config, @core)
      end

      # ブックマークパネル
      @components << BookmarksPanel.new(@config, @core) if @config.bookmarks_visible
      # コンテンツ領域
      @components << ContentArea.new(@config, @core)
      # ステータスバー
      @components << StatusBar.new(@config, @core) if @config.status_bar_visible

      # 高度機能：サイドパネル、設定画面、コンテキストメニュー
      @components << SidePanel.new(@config, @core)
      @components << SettingsInterface.new(@config, @core)
      @components << ContextMenu.new(@config, @core)
    end

    # UIを開始します (イベントスレッド＋レンダリングスレッド)
    def start
      setup_window
      @core.start
      @core.load_url(nil)

      # イベントスレッド
      @event_thread = spawn do
        loop do
          break if @window.closed?
          handle_events
        end
      end

      # レンダリングスレッド (60fps固定)
      @render_thread = spawn do
        loop do
          break if @window.closed?
          @theme_engine.apply(@window)
          render_frame
          sleep 0.016
        end
      end
    rescue ex
      STDERR.puts "UI start failed: \\#{ex.class.name} - \\#{ex.message}"
    end

    # シャットダウン処理
    def shutdown
      @window&.close
      @event_thread.try &.join
      @render_thread.try &.join
    end

    private def setup_window
      # ウィンドウサイズはズームレベルを考慮
      width  = (@config.width  * @config.zoom_level).to_i
      height = (@config.height * @config.zoom_level).to_i
      @window = Concave::Window.new(
        title:  @config.theme,
        width:  width,
        height: height
      )
      @window.enable_acceleration
      @window.show
    end

    private def handle_events
      @window.events.each do |event|
        # グローバルショートカット
        if event.is_a?(Concave::Event::KeyDown)
          case event.key
          when Concave::Key::F11
            @theme_engine.toggle
            next
          when Concave::Key::F5
            @core.current_page.try &.reload
            next
          when Concave::Key::Backspace
            @core.navigate_back
            next
          when Concave::Key::Forward
            @core.navigate_forward
            next
          when Concave::Key::L if event.mod & Concave::Mod::CONTROL != 0
            # Ctrl+L: アドレスバーにフォーカス
            @components.find { |c| c.is_a?(AddressBar) }&.focus
            next
          end
        end

        # 各コンポーネントへイベント伝播 (バブリング)
        @components.each do |c|
          c.handle_event(event)
        end
      end
    end

    private def render_frame
      @window.clear
      @components.each do |c|
        c.render(@window)
      end
      @window.present
    end
  end

  # ナビゲーションボタン (戻る, 進む, 更新, ホーム)
  class NavigationControls
    include Component
    getter config      : QuantumCore::UIConfig
    getter core        : QuantumCore::Engine
    getter button_size : Int32 = 32

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
    end

    def render(window : Concave::Window)
      x = 0; y = 0; h = button_size
      labels = ["←", "→", "⟳", "⌂"]
      labels.each_with_index do |lbl, i|
        bx = x + i * button_size
        window.set_draw_color(0xDDDDDD, 1.0)
        window.fill_rect(x: bx, y: y, width: button_size, height: h)
        window.set_draw_color(0x000000, 1.0)
        window.draw_text(lbl, x: bx + 8, y: y + 8,
                         size: @config.font_size,
                         font: @config.font_family)
      end
    rescue ex
      STDERR.puts "NavigationControls.render error: #{ex.message}"
    end

    def handle_event(event : Concave::Event)
      return unless event.is_a?(Concave::Event::MouseDown)
      if event.y < button_size
        idx = (event.x / button_size).to_i
        case idx
        when 0 then @core.navigate_back
        when 1 then @core.navigate_forward
        when 2 then @core.current_page.try &.reload
        when 3 then @core.load_url(@config.homepage)
        end
      end
    rescue ex
      STDERR.puts "NavigationControls.handle_event error: #{ex.message}"
    end
  end

  # 以下に他のコンポーネント (AddressBar, TabBar など) は既に個別ファイルで実装済みです
end 