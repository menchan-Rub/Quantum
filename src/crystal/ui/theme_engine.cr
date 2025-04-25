# src/crystal/ui/theme_engine.cr
require "concave"
require "../utils/logger"
require "../events/event_dispatcher"
require "../events/event_types"

module QuantumUI
  # テーマ管理エンジン
  # UIコンポーネントのスタイル（色、フォント等）を一元管理する
  class ThemeEngine
    # サポートするテーマ
    enum ThemeType
      LIGHT
      DARK
      SYSTEM # OS設定に追従
    end

    # テーマの色定義
    record ColorScheme, 
      background : UInt32,  # 背景色
      foreground : UInt32,  # 前景色（テキスト）
      accent : UInt32,      # アクセント色（強調、選択）
      secondary : UInt32,   # 二次背景色（パネル、ボタン）
      border : UInt32,      # 境界線の色
      link : UInt32,        # リンク色
      visited_link : UInt32 # 訪問済みリンク色

    getter current_theme : ThemeType
    getter colors : ColorScheme
    getter font_family : String
    getter font_size : Int32
    
    # テーマ変更時のコールバック
    @theme_change_callbacks : Array(Proc(Nil))

    # @param default_theme [ThemeType] 初期テーマ
    # @param font_family [String] デフォルトフォント
    # @param font_size [Int32] デフォルトフォントサイズ
    def initialize(default_theme : ThemeType = ThemeType::LIGHT,
                   font_family : String = "Noto Sans",
                   font_size : Int32 = 14)
      @current_theme = default_theme
      @font_family = font_family
      @font_size = font_size
      @theme_change_callbacks = [] of Proc(Nil)
      @colors = load_colors(@current_theme)
      
      # システムテーマの場合は実際のテーマを検出
      if @current_theme == ThemeType::SYSTEM
        detect_system_theme
      end
      
      Log.info "テーマエンジンを初期化しました（テーマ: #{@current_theme}）"
    end

    # テーマを切り替える
    def switch_theme(theme : ThemeType)
      return if theme == @current_theme
      
      @current_theme = theme
      if @current_theme == ThemeType::SYSTEM
        detect_system_theme
      else
        @colors = load_colors(@current_theme)
      end
      
      Log.info "テーマを切り替えました: #{@current_theme}"
      
      # テーマ変更イベントを発行
      QuantumEvents::EventDispatcher.instance.dispatch(
        QuantumEvents::Event.new(
          type: QuantumEvents::EventType::UI_THEME_CHANGED,
          data: {
            "theme" => @current_theme.to_s
          }
        )
      )
      
      # 登録されたコールバックを実行
      @theme_change_callbacks.each &.call
    end

    # テーマ変更時のコールバックを登録
    def on_theme_change(&callback : -> Nil)
      @theme_change_callbacks << callback
    end

    # 現在のテーマに基づいてウィンドウのクリア色を適用する
    def apply_clear_color(window : Concave::Window)
      window.set_clear_color(@colors.background, 1.0)
    end

    # フォントサイズを変更する
    def set_font_size(size : Int32)
      return if size < 8 || size > 32 # 極端なサイズを防止
      
      @font_size = size
      Log.info "フォントサイズを変更しました: #{@font_size}px"
      
      # フォント変更イベントを発行
      QuantumEvents::EventDispatcher.instance.dispatch(
        QuantumEvents::Event.new(
          type: QuantumEvents::EventType::UI_FONT_CHANGED,
          data: {
            "font_size" => @font_size
          }
        )
      )
      
      # 登録されたコールバックを実行
      @theme_change_callbacks.each &.call
    end

    # フォントファミリーを変更する
    def set_font_family(family : String)
      @font_family = family
      Log.info "フォントファミリーを変更しました: #{@font_family}"
      
      # フォント変更イベントを発行
      QuantumEvents::EventDispatcher.instance.dispatch(
        QuantumEvents::Event.new(
          type: QuantumEvents::EventType::UI_FONT_CHANGED,
          data: {
            "font_family" => @font_family
          }
        )
      )
      
      # 登録されたコールバックを実行
      @theme_change_callbacks.each &.call
    end

    # システムテーマを検出して適用する
    private def detect_system_theme
      # 各OSごとのシステムテーマ検出ロジック
      {% if flag?(:darwin) %}
        # macOSの場合
        result = `defaults read -g AppleInterfaceStyle 2>/dev/null`.strip
        is_dark = result == "Dark"
      {% elsif flag?(:linux) %}
        # Linuxの場合（GTK3/4を想定）
        result = `gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null`.strip
        is_dark = result.includes?("dark")
        
        # 上記で取得できない場合の代替手段
        if result.empty?
          result = `gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null`.strip
          is_dark = result.downcase.includes?("dark")
        end
      {% elsif flag?(:windows) %}
        # Windowsの場合
        begin
          # PowerShellを使用してレジストリからテーマ設定を取得
          cmd = %{powershell -command "[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize', 'AppsUseLightTheme', 1)"}
          result = `#{cmd}`.strip
          is_dark = result == "0"
        rescue
          is_dark = false
        end
      {% else %}
        # その他のプラットフォーム
        is_dark = false
      {% end %}
      
      @colors = load_colors(is_dark ? ThemeType::DARK : ThemeType::LIGHT)
      Log.info "システムテーマを検出しました: #{is_dark ? "ダーク" : "ライト"}"
    end

    private def load_colors(theme : ThemeType) : ColorScheme
      case theme
      when ThemeType::LIGHT
        ColorScheme.new(
          background: 0xFF_FF_FF_FF,   # 白
          foreground: 0x33_33_33_FF,   # 濃いグレー
          accent:     0x00_7A_FF_FF,   # 青
          secondary:  0xF5_F5_F5_FF,   # 薄いグレー
          border:     0xDD_DD_DD_FF,   # 中間グレー
          link:       0x00_66_CC_FF,   # 青リンク
          visited_link: 0x55_11_AA_FF  # 紫リンク
        )
      when ThemeType::DARK
        ColorScheme.new(
          background: 0x1E_1E_1E_FF,   # 濃いグレー
          foreground: 0xE8_E8_E8_FF,   # 明るいグレー
          accent:     0x00_7A_FF_FF,   # 青
          secondary:  0x2D_2D_2D_FF,   # 中間グレー
          border:     0x44_44_44_FF,   # 薄いグレー
          link:       0x4D_A6_FF_FF,   # 明るい青リンク
          visited_link: 0xBB_77_DD_FF  # 明るい紫リンク
        )
      when ThemeType::SYSTEM
        # システムテーマはdetect_system_themeで処理されるため、
        # ここではライトテーマをデフォルトとして返す
        load_colors(ThemeType::LIGHT)
      end
    end

    # 色を Concave が期待する Float RGBA タプルに変換するヘルパー
    def color_to_floats(color_hex : UInt32) : Tuple(Float64, Float64, Float64, Float64)
      r = ((color_hex >> 24) & 0xFF) / 255.0
      g = ((color_hex >> 16) & 0xFF) / 255.0
      b = ((color_hex >> 8) & 0xFF) / 255.0
      a = (color_hex & 0xFF) / 255.0
      {r, g, b, a}
    end
    
    # 色を明るくする（ハイライト効果など）
    def lighten_color(color : UInt32, amount : Float64 = 0.1) : UInt32
      r = Math.min(255, ((color >> 24) & 0xFF) + (255 * amount).to_i)
      g = Math.min(255, ((color >> 16) & 0xFF) + (255 * amount).to_i)
      b = Math.min(255, ((color >> 8) & 0xFF) + (255 * amount).to_i)
      a = (color & 0xFF)
      
      (r << 24) | (g << 16) | (b << 8) | a
    end
    
    # 色を暗くする（シャドウ効果など）
    def darken_color(color : UInt32, amount : Float64 = 0.1) : UInt32
      r = Math.max(0, ((color >> 24) & 0xFF) - (255 * amount).to_i)
      g = Math.max(0, ((color >> 16) & 0xFF) - (255 * amount).to_i)
      b = Math.max(0, ((color >> 8) & 0xFF) - (255 * amount).to_i)
      a = (color & 0xFF)
      
      (r << 24) | (g << 16) | (b << 8) | a
    end
  end
end