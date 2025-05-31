# src/crystal/ui/components/settings_interface.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"

module QuantumUI
  # 設定画面コンポーネント (モーダル表示を想定)
  class SettingsInterface < Component
    # 設定カテゴリ
    enum SettingCategory
      General
      Appearance
      Privacy
      Network
      Extensions
      Advanced
    end

    # 設定項目の基底クラス
    abstract class SettingItem
      property label : String
      property description : String
      property category : SettingCategory

      def initialize(@label : String, @description : String, @category : SettingCategory)
      end

      abstract def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
      abstract def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
      abstract def get_value : String
      abstract def set_value(value : String) : Bool
    end

    # トグル設定項目
    class ToggleSetting < SettingItem
      property enabled : Bool
      property on_change : Proc(Bool, Nil)?

      def initialize(label : String, description : String, category : SettingCategory, @enabled : Bool = false, @on_change : Proc(Bool, Nil)? = nil)
        super(label, description, category)
      end

      def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
        # ラベル描画
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(@label, x: x, y: y, size: theme.font_size, font: theme.font_family)
        
        # 説明文（小さめのフォント）
        if !@description.empty?
          window.draw_text(@description, x: x, y: y + theme.font_size + 4, size: theme.font_size - 2, font: theme.font_family, alpha: 0.7)
        end
        
        # トグルスイッチ描画
        toggle_width = 40
        toggle_height = 20
        toggle_x = x + width - toggle_width - 10
        toggle_y = y + 2
        
        # トグル背景
        bg_color = @enabled ? theme.colors.accent : theme.colors.secondary
        window.set_draw_color(bg_color, 1.0)
        window.fill_rounded_rect(x: toggle_x, y: toggle_y, width: toggle_width, height: toggle_height, radius: toggle_height / 2)
        
        # トグルハンドル
        handle_size = toggle_height - 4
        handle_x = toggle_x + (@enabled ? toggle_width - handle_size - 2 : 2)
        handle_y = toggle_y + 2
        window.set_draw_color(theme.colors.background, 1.0)
        window.fill_circle(x: handle_x + handle_size / 2, y: handle_y + handle_size / 2, radius: handle_size / 2)
        
        # 項目の高さを返す
        return @description.empty? ? theme.font_size + 10 : theme.font_size * 2 + 14
      end

      def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
        toggle_width = 40
        toggle_x = x + y - toggle_width - 10
        
        if mouse_x >= toggle_x && mouse_x <= toggle_x + toggle_width
          @enabled = !@enabled
          @on_change.try &.call(@enabled)
          return true
        end
        
        return false
      end

      def get_value : String
        @enabled.to_s
      end

      def set_value(value : String) : Bool
        case value.downcase
        when "true", "1", "on", "yes"
          @enabled = true
          return true
        when "false", "0", "off", "no"
          @enabled = false
          return true
        else
          return false
        end
      end
    end

    # 選択設定項目
    class SelectSetting < SettingItem
      property options : Array(String)
      property selected_index : Int32
      property on_change : Proc(String, Nil)?
      
      def initialize(label : String, description : String, category : SettingCategory, @options : Array(String), @selected_index : Int32 = 0, @on_change : Proc(String, Nil)? = nil)
        super(label, description, category)
      end

      def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
        # ラベル描画
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(@label, x: x, y: y, size: theme.font_size, font: theme.font_family)
        
        # 説明文
        if !@description.empty?
          window.draw_text(@description, x: x, y: y + theme.font_size + 4, size: theme.font_size - 2, font: theme.font_family, alpha: 0.7)
        end
        
        # セレクトボックス描画
        select_width = 150
        select_height = 28
        select_x = x + width - select_width - 10
        select_y = y
        
        # セレクトボックス背景
        window.set_draw_color(theme.colors.secondary, 1.0)
        window.fill_rect(x: select_x, y: select_y, width: select_width, height: select_height)
        
        # 選択中の値
        selected_text = @options[@selected_index]
        text_x = select_x + 10
        text_y = select_y + (select_height - theme.font_size) / 2
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(selected_text, x: text_x, y: text_y, size: theme.font_size, font: theme.font_family)
        
        # 下向き矢印
        arrow_size = 8
        arrow_x = select_x + select_width - arrow_size - 10
        arrow_y = select_y + (select_height - arrow_size) / 2
        window.set_draw_color(theme.colors.foreground, 0.8)
        window.draw_triangle(
          x1: arrow_x, y1: arrow_y,
          x2: arrow_x + arrow_size, y2: arrow_y,
          x3: arrow_x + arrow_size / 2, y3: arrow_y + arrow_size
        )
        
        # 枠線
        window.set_draw_color(theme.colors.foreground, 0.3)
        window.draw_rect(x: select_x, y: select_y, width: select_width, height: select_height)
        
        # 項目の高さを返す
        return @description.empty? ? theme.font_size + 28 : theme.font_size * 2 + 32
      end

      def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
        select_width = 150
        select_height = 28
        select_x = x + width - select_width - 10
        select_y = y
        
        if mouse_x >= select_x && mouse_x <= select_x + select_width && mouse_y >= select_y && mouse_y <= select_y + select_height
          # 次の選択肢に進む（循環）
          @selected_index = (@selected_index + 1) % @options.size
          @on_change.try &.call(@options[@selected_index])
          return true
        end
        
        return false
      end

      def get_value : String
        @options[@selected_index]
      end

      def set_value(value : String) : Bool
        index = @options.index(value)
        if index
          @selected_index = index
          return true
        end
        return false
      end
    end

    # 入力フィールド設定項目
    class InputSetting < SettingItem
      property value : String
      property placeholder : String
      property on_change : Proc(String, Nil)?
      property max_length : Int32
      
      def initialize(label : String, description : String, category : SettingCategory, @value : String = "", @placeholder : String = "", @max_length : Int32 = 100, @on_change : Proc(String, Nil)? = nil)
        super(label, description, category)
      end

      def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
        # ラベル描画
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(@label, x: x, y: y, size: theme.font_size, font: theme.font_family)
        
        # 説明文
        if !@description.empty?
          window.draw_text(@description, x: x, y: y + theme.font_size + 4, size: theme.font_size - 2, font: theme.font_family, alpha: 0.7)
        end
        
        # 入力フィールド描画
        input_width = 200
        input_height = 28
        input_x = x + width - input_width - 10
        input_y = y
        
        # 入力フィールド背景
        window.set_draw_color(theme.colors.background_alt, 1.0)
        window.fill_rect(x: input_x, y: input_y, width: input_width, height: input_height)
        
        # 入力テキスト
        display_text = @value.empty? ? @placeholder : @value
        text_alpha = @value.empty? ? 0.5 : 1.0
        text_x = input_x + 8
        text_y = input_y + (input_height - theme.font_size) / 2
        window.set_draw_color(theme.colors.foreground, text_alpha)
        window.draw_text(display_text, x: text_x, y: text_y, size: theme.font_size, font: theme.font_family)
        
        # 枠線
        window.set_draw_color(theme.colors.foreground, 0.3)
        window.draw_rect(x: input_x, y: input_y, width: input_width, height: input_height)
        
        # 項目の高さを返す
        return @description.empty? ? theme.font_size + 28 : theme.font_size * 2 + 32
      end

      def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
        input_width = 200
        input_height = 28
        input_x = x + width - input_width - 10
        input_y = y
        
        if mouse_x >= input_x && mouse_x <= input_x + input_width && mouse_y >= input_y && mouse_y <= input_y + input_height
          # テキスト入力モードに遷移
          QuantumUI::TextInputManager.instance.start_input(field_id: @current_field)
          return true
        end
        
        return false
      end

      def get_value : String
        @value
      end

      def set_value(value : String) : Bool
        if value.size <= @max_length
          @value = value
          return true
        end
        return false
      end
    end

    # 設定項目のコンテナ
    class SettingsContainer
      property items : Hash(SettingCategory, Array(SettingItem))
      property current_category : SettingCategory
      
      def initialize
        @items = Hash(SettingCategory, Array(SettingItem)).new { |h, k| h[k] = [] of SettingItem }
        @current_category = SettingCategory::General
      end
      
      def add_item(item : SettingItem)
        @items[item.category] << item
      end
      
      def get_items(category : SettingCategory) : Array(SettingItem)
        @items[category]
      end
      
      def all_categories : Array(SettingCategory)
        @items.keys
      end
    end

    # @param config [QuantumCore::UIConfig] UI設定
    # @param core [QuantumCore::Engine] コアエンジン
    # @param theme [ThemeEngine] テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @visible = false
      @settings = SettingsContainer.new
      @scroll_offset = 0
      @max_scroll = 0
      @dragging = false
      @last_mouse_y = 0
      
      # 設定項目の初期化
      initialize_settings
    end

    # 設定項目を初期化
    private def initialize_settings
      # 一般設定
      @settings.add_item(ToggleSetting.new(
        "起動時に前回のセッションを復元", 
        "ブラウザを起動したときに前回開いていたタブを復元します", 
        SettingCategory::General, 
        @config.restore_session,
        ->(enabled : Bool) { @config.restore_session = enabled; nil }
      ))
      
      @settings.add_item(ToggleSetting.new(
        "ホームページを設定", 
        "新しいタブを開いたときに表示するページを設定します", 
        SettingCategory::General, 
        !@config.homepage.empty?,
        ->(enabled : Bool) { 
          @config.homepage = enabled ? "about:newtab" : ""
          nil
        }
      ))
      
      @settings.add_item(InputSetting.new(
        "ホームページURL", 
        "新しいタブで開くURLを入力してください", 
        SettingCategory::General, 
        @config.homepage,
        "https://example.com",
        200,
        ->(value : String) { @config.homepage = value; nil }
      ))
      
      # 外観設定
      @settings.add_item(SelectSetting.new(
        "テーマ", 
        "ブラウザの外観テーマを選択します", 
        SettingCategory::Appearance, 
        ["ライト", "ダーク", "システム設定に合わせる"],
        @theme.current_theme == ThemeEngine::ThemeType::LIGHT ? 0 : 1,
        ->(value : String) {
          case value
          when "ライト"
            @theme.switch_theme(ThemeEngine::ThemeType::LIGHT)
          when "ダーク"
            @theme.switch_theme(ThemeEngine::ThemeType::DARK)
          when "システム設定に合わせる"
            # システム設定の取得処理が必要
            @theme.switch_theme(ThemeEngine::ThemeType::LIGHT)
          end
          nil
        }
      ))
      
      @settings.add_item(SelectSetting.new(
        "フォントサイズ", 
        "テキストの表示サイズを調整します", 
        SettingCategory::Appearance, 
        ["小", "中", "大"],
        1,
        ->(value : String) {
          case value
          when "小"
            @config.font_size = 12
          when "中"
            @config.font_size = 14
          when "大"
            @config.font_size = 16
          end
          nil
        }
      ))
      
      # プライバシー設定
      @settings.add_item(ToggleSetting.new(
        "トラッキング防止", 
        "ウェブサイトによるトラッキングをブロックします", 
        SettingCategory::Privacy, 
        @config.block_trackers,
        ->(enabled : Bool) { @config.block_trackers = enabled; nil }
      ))
      
      @settings.add_item(ToggleSetting.new(
        "Cookie制限", 
        "サードパーティCookieをブロックします", 
        SettingCategory::Privacy, 
        @config.block_third_party_cookies,
        ->(enabled : Bool) { @config.block_third_party_cookies = enabled; nil }
      ))
      
      # ネットワーク設定
      @settings.add_item(ToggleSetting.new(
        "プリフェッチを有効化", 
        "リンク先のページを事前に読み込み、表示を高速化します", 
        SettingCategory::Network, 
        @config.enable_prefetch,
        ->(enabled : Bool) { @config.enable_prefetch = enabled; nil }
      ))
      
      @settings.add_item(ToggleSetting.new(
        "プロキシを使用", 
        "ネットワーク接続にプロキシサーバーを使用します", 
        SettingCategory::Network, 
        @config.use_proxy,
        ->(enabled : Bool) { @config.use_proxy = enabled; nil }
      ))
      
      @settings.add_item(InputSetting.new(
        "プロキシサーバー", 
        "プロキシサーバーのアドレスとポートを入力してください", 
        SettingCategory::Network, 
        @config.proxy_address,
        "127.0.0.1:8080",
        100,
        ->(value : String) { @config.proxy_address = value; nil }
      ))
    end

    # 設定画面を描画する
    override def render(window : Concave::Window)
      return unless visible? && (bounds = @bounds)
      x, y, w, h = bounds

      # 背景 (モーダルなので少し暗くする)
      window.set_draw_color(0x00_00_00, 0.5)
      window.fill_rect(x: 0, y: 0, width: window.width, height: window.height)

      # 設定パネル本体の背景
      window.set_draw_color(@theme.colors.background, 1.0)
      window.fill_rect(x: x, y: y, width: w, height: h)

      # タイトル
      title = "設定"
      title_x = x + 20
      title_y = y + 20
      window.set_draw_color(@theme.colors.foreground, 1.0)
      window.draw_text(title, x: title_x, y: title_y, size: @theme.font_size + 6, font: @theme.font_family)

      # カテゴリタブ
      tab_y = y + 60
      tab_height = 40
      tab_width = 120
      tab_x = x + 20
      
      @settings.all_categories.each_with_index do |category, index|
        is_active = category == @settings.current_category
        
        # タブ背景
        bg_color = is_active ? @theme.colors.accent : @theme.colors.secondary
        window.set_draw_color(bg_color, is_active ? 1.0 : 0.7)
        window.fill_rect(x: tab_x, y: tab_y, width: tab_width, height: tab_height)
        
        # タブラベル
        label = category.to_s
        label_x = tab_x + tab_width / 2 - label.size * @theme.font_size / 4
        label_y = tab_y + (tab_height - @theme.font_size) / 2
        window.set_draw_color(is_active ? @theme.colors.background : @theme.colors.foreground, 1.0)
        window.draw_text(label, x: label_x, y: label_y, size: @theme.font_size, font: @theme.font_family)
        
        tab_x += tab_width + 10
      end

      # 設定項目エリア
      content_x = x + 20
      content_y = y + 110
      content_width = w - 40
      content_height = h - 170  # 閉じるボタン用に下部にスペースを残す
      
      # コンテンツエリア背景
      window.set_draw_color(@theme.colors.background_alt, 0.3)
      window.fill_rect(x: content_x, y: content_y, width: content_width, height: content_height)
      
      # 設定項目の描画
      items = @settings.get_items(@settings.current_category)
      item_y = content_y + 10 - @scroll_offset
      
      # スクロール可能領域を設定
      window.set_clip_rect(content_x, content_y, content_width, content_height)
      
      items.each do |item|
        # 表示範囲内の項目のみ描画
        if item_y + 50 >= content_y && item_y <= content_y + content_height
          item_height = item.render(window, content_x + 10, item_y, content_width - 20, @theme)
          item_y += item_height + 15
        else
          # 非表示項目の高さだけ加算
          item_y += 50  # 平均的な高さを仮定
        end
      end
      
      # 最大スクロール量を計算
      @max_scroll = Math.max(0, item_y - content_y - content_height + 10)
      
      # スクロールバー
      if @max_scroll > 0
        scrollbar_width = 8
        scrollbar_height = (content_height * content_height / (item_y - content_y + @scroll_offset)).to_i
        scrollbar_x = content_x + content_width - scrollbar_width - 5
        scrollbar_y = content_y + (@scroll_offset * content_height / (item_y - content_y))
        
        window.set_draw_color(@theme.colors.foreground, 0.3)
        window.fill_rounded_rect(x: scrollbar_x, y: scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
      
      # クリップ領域をリセット
      window.reset_clip_rect
      
      # 閉じるボタン
      close_button_width = 120
      close_button_height = 36
      close_button_x = x + w / 2 - close_button_width / 2
      close_button_y = y + h - close_button_height - 20
      
      window.set_draw_color(@theme.colors.accent, 1.0)
      window.fill_rounded_rect(x: close_button_x, y: close_button_y, width: close_button_width, height: close_button_height, radius: 4)
      
      close_label = "閉じる"
      close_label_x = close_button_x + close_button_width / 2 - close_label.size * @theme.font_size / 4
      close_label_y = close_button_y + (close_button_height - @theme.font_size) / 2
      window.set_draw_color(@theme.colors.background, 1.0)
      window.draw_text(close_label, x: close_label_x, y: close_label_y, size: @theme.font_size, font: @theme.font_family)
      
      # テーマ切り替えボタン
      theme_button_width = 150
      theme_button_height = 36
      theme_button_x = x + w - theme_button_width - 20
      theme_button_y = y + 20
      
      window.set_draw_color(@theme.colors.secondary, 1.0)
      window.fill_rounded_rect(x: theme_button_x, y: theme_button_y, width: theme_button_width, height: theme_button_height, radius: 4)
      
      theme_label = @theme.current_theme == ThemeEngine::ThemeType::LIGHT ? "ダークモードに切替" : "ライトモードに切替"
      theme_label_x = theme_button_x + theme_button_width / 2 - theme_label.size * @theme.font_size / 4
      theme_label_y = theme_button_y + (theme_button_height - @theme.font_size) / 2
      window.set_draw_color(@theme.colors.foreground, 1.0)
      window.draw_text(theme_label, x: theme_label_x, y: theme_label_y, size: @theme.font_size, font: @theme.font_family)
    rescue ex
      Log.error "設定インターフェース描画に失敗しました", exception: ex
    end

    # イベント処理
    override def handle_event(event : QuantumEvents::Event) : Bool
      return false unless visible?

      case event.type
      when QuantumEvents::EventType::UI_KEY_DOWN
        key_event = event.data.as(Concave::Event::KeyDown)
        # ESCキーで閉じる
        if key_event.key == Concave::Key::Escape
          hide
          return true
        end
      when QuantumEvents::EventType::UI_MOUSE_DOWN
        mouse_event = event.data.as(Concave::Event::MouseDown)
        @dragging = true
        @last_mouse_y = mouse_event.y
        return true if handle_mouse_click(mouse_event)
      when QuantumEvents::EventType::UI_MOUSE_UP
        @dragging = false
        return true
      when QuantumEvents::EventType::UI_MOUSE_MOVE
        mouse_event = event.data.as(Concave::Event::MouseMove)
        if @dragging && @max_scroll > 0
          delta_y = @last_mouse_y - mouse_event.y
          @scroll_offset = Math.max(0, Math.min(@max_scroll, @scroll_offset + delta_y))
          @last_mouse_y = mouse_event.y
          return true
        end
      when QuantumEvents::EventType::UI_MOUSE_WHEEL
        wheel_event = event.data.as(Concave::Event::MouseWheel)
        if @max_scroll > 0 && bounds = @bounds
          x, y, w, h = bounds
          content_y = y + 110
          content_height = h - 170
          
          # マウスがコンテンツエリア内にあるか確認
          if wheel_event.x >= x + 20 && wheel_event.x <= x + w - 20 &&
             wheel_event.y >= content_y && wheel_event.y <= content_y + content_height
            # スクロール処理
            @scroll_offset = Math.max(0, Math.min(@max_scroll, @scroll_offset + wheel_event.y_offset * 20))
            return true
          end
        end
      end

      # モーダル表示中は他のコンポーネントにイベントを渡さない
      true
    rescue ex
      Log.error "設定インターフェースのイベント処理に失敗しました", exception: ex
      true # エラーでもイベントは消費
    end

    # 推奨サイズ
    override def preferred_size : Tuple(Int32, Int32)
      {700, 500} # 設定画面に適したサイズ
    end

    # 表示/非表示を切り替える
    def toggle_visibility
      if @visible
        hide
      else
        show
      end
    end

    def show
      @visible = true
      @focused = true # モーダルは常にフォーカスを持つ
      @scroll_offset = 0 # スクロール位置をリセット
      
      # ウィンドウの中央に配置
      if window_size = @core.window_size
        window_width, window_height = window_size
        pref_w, pref_h = preferred_size
        @bounds = {(window_width - pref_w) / 2, (window_height - pref_h) / 2, pref_w, pref_h}
      end
      
      Log.info "設定インターフェースを表示しました"
    end

    def hide
      @visible = false
      @focused = false
      @bounds = nil
      
      # 設定変更を保存
      save_settings
      
      Log.info "設定インターフェースを非表示にしました"
    end

    # 設定を保存
    private def save_settings
      # 設定をファイルに保存
      @core.save_config(@config)
      
      # 設定変更イベントを発火
      @core.dispatch_event(QuantumEvents::Event.new(
        QuantumEvents::EventType::CONFIG_CHANGED,
        nil
      ))
    end

    # --- ヘルパー --- #

    # マウスクリック処理
    private def handle_mouse_click(event_data : Concave::Event::MouseDown) : Bool
      return false unless bounds = @bounds
      x, y, w, h = bounds

      # カテゴリタブのクリック処理
      tab_y = y + 60
      tab_height = 40
      tab_width = 120
      tab_x = x + 20
      
      @settings.all_categories.each_with_index do |category, index|
        if event_data.x >= tab_x && event_data.x <= tab_x + tab_width &&
           event_data.y >= tab_y && event_data.y <= tab_y + tab_height
          @settings.current_category = category
          @scroll_offset = 0 # カテゴリ変更時にスクロールをリセット
          return true
        end
        
        tab_x += tab_width + 10
      end

      # 設定項目エリア
      content_x = x + 20
      content_y = y + 110
      content_width = w - 40
      content_height = h - 170
      
      # 設定項目内のクリック
      if event_data.x >= content_x && event_data.x <= content_x + content_width &&
         event_data.y >= content_y && event_data.y <= content_y + content_height
        
        # 各設定項目のクリック処理
        items = @settings.get_items(@settings.current_category)
        item_y = content_y + 10 - @scroll_offset
        
        items.each do |item|
          item_height = item.calculate_height(@theme)
          
          if event_data.y >= item_y && event_data.y <= item_y + item_height
            # 設定項目内部のクリック処理を委譲
            if item.handle_click(event_data.x - content_x - 10, event_data.y - item_y, content_width - 20)
              return true
            end
          end
          
          item_y += item_height + 15
        end
        
        return true # コンテンツエリア内のクリックはイベントを消費
      end

      # テーマ切り替えボタン
      theme_button_width = 150
      theme_button_height = 36
      theme_button_x = x + w - theme_button_width - 20
      theme_button_y = y + 20
      
      if event_data.x >= theme_button_x && event_data.x <= theme_button_x + theme_button_width &&
         event_data.y >= theme_button_y && event_data.y <= theme_button_y + theme_button_height
        # テーマ切り替え
        new_theme = @theme.current_theme == ThemeEngine::ThemeType::LIGHT ? ThemeEngine::ThemeType::DARK : ThemeEngine::ThemeType::LIGHT
        @theme.switch_theme(new_theme)
        # 設定に反映
        @config.theme = new_theme.to_s.downcase
        return true
      end

      # 閉じるボタン
      close_button_width = 120
      close_button_height = 36
      close_button_x = x + w / 2 - close_button_width / 2
      close_button_y = y + h - close_button_height - 20
      
      if event_data.x >= close_button_x && event_data.x <= close_button_x + close_button_width &&
         event_data.y >= close_button_y && event_data.y <= close_button_y + close_button_height
        hide
        return true
      end

      # 設定パネル領域内のクリックはイベントを消費
      if event_data.x >= x && event_data.x <= x + w &&
         event_data.y >= y && event_data.y <= y + h
        return true
      end

      false
    end
  end
end 