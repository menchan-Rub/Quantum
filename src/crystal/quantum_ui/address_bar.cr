# src/crystal/quantum_ui/address_bar.cr
require "concave"

module QuantumUI
  # アドレスバーコンポーネント
  #
  # ユーザーによるURL入力とナビゲーションを提供します
  class AddressBar
    include Component

    # UI設定
    getter config : QuantumCore::UIConfig
    # コアエンジン
    getter core   : QuantumCore::Engine
    # 入力テキスト
    getter text   : String
    # フォーカス状態
    getter focused : Bool

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config  = config
      @core    = core
      @text     = ""
      @focused  = false
    end

    # アドレスバーを描画します
    def render(window : Concave::Window)
      height = 32
      window.set_draw_color(0xFF_FF_FF, 1.0)
      window.fill_rect(x: 0, y: 0, width: window.width, height: height)
      window.set_draw_color(0x00_00_00, 1.0)
      window.draw_text(@text,
                       x: 8, y: 8,
                       size: @config.font_size, font: @config.font_family)
      if @focused
        window.set_draw_color(0x00_66_FF, 1.0)
        window.fill_rect(x: 0, y: height - 2, width: window.width, height: 2)
      end
    rescue ex
      STDERR.puts "AddressBar.render error: #{ex.message}"
    end

    # イベントを処理します
    def handle_event(event : Concave::Event)
      case event
      when Concave::Event::MouseDown
        @focused = event.y < 32
      when Concave::Event::KeyDown
        return unless @focused
        case event.key
        when Concave::Key::Return
          @core.load_url(@text)
          @focused = false
        when Concave::Key::Backspace
          @text = @text[0...-1] if @text.size > 0
        else
          @text += event.text if event_text = event.text
        end
      end
    rescue ex
      STDERR.puts "AddressBar.handle_event error: #{ex.message}"
    end
  end
end 