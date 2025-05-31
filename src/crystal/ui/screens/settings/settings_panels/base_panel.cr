# src/crystal/ui/screens/settings/settings_panels/base_panel.cr
require "concave"
require "../../../theme_engine"
require "../../../../quantum_core/config"

module QuantumUI
  # 設定項目の基底クラス
  abstract class SettingItem
    property label : String
    property description : String
    property category : String
    property visible : Bool = true
    property height : Int32
    
    def initialize(@label : String, @description : String, @category : String)
      @height = 0
    end
    
    # 設定項目を描画し、使用した高さを返す
    abstract def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
    
    # クリックイベントを処理
    abstract def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
    
    # 設定値を文字列で取得
    abstract def get_value : String
    
    # 文字列から設定値を設定
    abstract def set_value(value : String) : Bool
    
    # 検索クエリとマッチするかどうか判定
    def matches?(query : String) : Bool
      query = query.downcase
      @label.downcase.includes?(query) || 
      @description.downcase.includes?(query) ||
      @category.downcase.includes?(query) ||
      get_value.downcase.includes?(query)
    end
  end
  
  # トグル設定項目
  class ToggleSetting < SettingItem
    property enabled : Bool
    property on_change : Proc(Bool, Nil)?
    
    def initialize(label : String, description : String, category : String, @enabled : Bool = false, @on_change : Proc(Bool, Nil)? = nil)
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
      height = @description.empty? ? theme.font_size + 10 : theme.font_size * 2 + 14
      @height = height
      return height
    end
    
    def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
      toggle_width = 40
      toggle_x = x + width - toggle_width - 10
      
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
    
    def initialize(label : String, description : String, category : String, @options : Array(String), @selected_index : Int32 = 0, @on_change : Proc(String, Nil)? = nil)
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
      window.fill_triangle(
        x1: arrow_x, y1: arrow_y,
        x2: arrow_x + arrow_size, y2: arrow_y,
        x3: arrow_x + arrow_size / 2, y3: arrow_y + arrow_size
      )
      
      # 枠線
      window.set_draw_color(theme.colors.foreground, 0.3)
      window.draw_rect(x: select_x, y: select_y, width: select_width, height: select_height)
      
      # 項目の高さを返す
      height = @description.empty? ? theme.font_size + 28 : theme.font_size * 2 + 32
      @height = height
      return height
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
    property focused : Bool = false
    
    def initialize(label : String, description : String, category : String, @value : String = "", @placeholder : String = "", @on_change : Proc(String, Nil)? = nil)
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
      border_color = @focused ? theme.colors.accent : theme.colors.secondary
      window.set_draw_color(theme.colors.background, 1.0)
      window.fill_rect(x: input_x, y: input_y, width: input_width, height: input_height)
      window.set_draw_color(border_color, 1.0)
      window.draw_rect(x: input_x, y: input_y, width: input_width, height: input_height)
      
      # 入力テキスト／プレースホルダー
      text_x = input_x + 10
      text_y = input_y + (input_height - theme.font_size) / 2
      
      if @value.empty?
        window.set_draw_color(theme.colors.foreground, 0.5)
        window.draw_text(@placeholder, x: text_x, y: text_y, size: theme.font_size, font: theme.font_family)
      else
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(@value, x: text_x, y: text_y, size: theme.font_size, font: theme.font_family)
      end
      
      # 項目の高さを返す
      height = @description.empty? ? theme.font_size + 28 : theme.font_size * 2 + 32
      @height = height
      return height
    end
    
    def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
      input_width = 200
      input_height = 28
      input_x = x + width - input_width - 10
      input_y = y
      
      if mouse_x >= input_x && mouse_x <= input_x + input_width && mouse_y >= input_y && mouse_y <= input_y + input_height
        @focused = true
        return true
      else
        @focused = false
        return false
      end
    end
    
    def handle_key_event(event : Events::KeyEvent) : Bool
      return false unless @focused
      
      case event.key
      when Events::Key::Backspace
        @value = @value[0..-2] if !@value.empty?
        @on_change.try &.call(@value)
        return true
      when Events::Key::Return, Events::Key::Tab
        @focused = false
        return true
      else
        if event.char && event.char.ord >= 32 && event.char.ord <= 126
          @value += event.char
          @on_change.try &.call(@value)
          return true
        end
      end
      
      return false
    end
    
    def get_value : String
      @value
    end
    
    def set_value(value : String) : Bool
      @value = value
      @on_change.try &.call(@value)
      return true
    end
  end
  
  # ボタン設定項目
  class ButtonSetting < SettingItem
    property label_text : String
    property button_text : String
    property on_click : Proc(Nil)
    
    def initialize(label : String, description : String, category : String, @button_text : String, @on_click : Proc(Nil))
      super(label, description, category)
      @label_text = label
    end
    
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
      # ラベル描画
      window.set_draw_color(theme.colors.foreground, 1.0)
      window.draw_text(@label_text, x: x, y: y, size: theme.font_size, font: theme.font_family)
      
      # 説明文
      if !@description.empty?
        window.draw_text(@description, x: x, y: y + theme.font_size + 4, size: theme.font_size - 2, font: theme.font_family, alpha: 0.7)
      end
      
      # ボタン描画
      button_width = 120
      button_height = 30
      button_x = x + width - button_width - 10
      button_y = y
      
      # ボタン背景
      window.set_draw_color(theme.colors.accent, 1.0)
      window.fill_rounded_rect(x: button_x, y: button_y, width: button_width, height: button_height, radius: 4)
      
      # ボタンテキスト
      text_width = window.measure_text(@button_text, size: theme.font_size, font: theme.font_family)
      text_x = button_x + (button_width - text_width) / 2
      text_y = button_y + (button_height - theme.font_size) / 2
      
      window.set_draw_color(theme.colors.background, 1.0)
      window.draw_text(@button_text, x: text_x, y: text_y, size: theme.font_size, font: theme.font_family)
      
      # 項目の高さを返す
      height = @description.empty? ? theme.font_size + 30 : theme.font_size * 2 + 34
      @height = height
      return height
    end
    
    def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
      button_width = 120
      button_height = 30
      button_x = x + width - button_width - 10
      button_y = y
      
      if mouse_x >= button_x && mouse_x <= button_x + button_width && mouse_y >= button_y && mouse_y <= button_y + button_height
        @on_click.call
        return true
      end
      
      return false
    end
    
    def get_value : String
      @button_text
    end
    
    def set_value(value : String) : Bool
      @button_text = value
      return true
    end
  end
  
  # セクションヘッダー
  class SectionHeader < SettingItem
    def initialize(label : String, category : String)
      super(label, "", category)
    end
    
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, theme : ThemeEngine) : Int32
      # セクションタイトル
      window.set_draw_color(theme.colors.accent, 1.0)
      window.draw_text(@label, x: x, y: y, size: theme.font_size + 1, font: theme.font_family)
      
      # 下線
      window.set_draw_color(theme.colors.accent, 0.5)
      window.draw_line(x1: x, y1: y + theme.font_size + 6, x2: x + width, y2: y + theme.font_size + 6)
      
      # 項目の高さを返す
      @height = theme.font_size + 16
      return @height
    end
    
    def handle_click(x : Int32, y : Int32, mouse_x : Int32, mouse_y : Int32) : Bool
      return false  # ヘッダーはクリック不可
    end
    
    def get_value : String
      ""
    end
    
    def set_value(value : String) : Bool
      false  # 設定変更不可
    end
  end
  
  # 設定パネルの基底クラス
  abstract class SettingsPanel
    property items : Array(SettingItem) = [] of SettingItem
    property content_height : Int32 = 0
    property visible_height : Int32 = 0
    
    def initialize(@config_manager : QuantumCore::ConfigManager)
      setup_items
    end
    
    # 各パネルで設定項目を初期化
    protected abstract def setup_items
    
    # 設定値を更新
    def refresh
      # 継承クラスでオーバーライド可能
    end
    
    # パネルを描画
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32, theme : ThemeEngine, scroll_offset : Int32) : Nil
      @visible_height = height
      
      current_y = y - scroll_offset
      total_height = 0
      
      # タイトル
      window.set_draw_color(theme.colors.foreground, 1.0)
      window.draw_text(panel_title, x: x + 20, y: current_y + 20, size: theme.font_size + 2, font: theme.font_family)
      current_y += 50
      
      # 設定項目の描画
      item_padding = 15
      
      @items.each do |item|
        next unless item.visible
        
        item_height = item.render(window, x + 20, current_y + item_padding, width - 40, theme)
        current_y += item_height + item_padding * 2
        total_height += item_height + item_padding * 2
        
        # 区切り線（セクションヘッダーの場合は描画しない）
        unless item.is_a?(SectionHeader)
          window.set_draw_color(theme.colors.border, 0.3)
          window.draw_line(x1: x + 20, y1: current_y, x2: x + width - 20, y2: current_y)
        end
      end
      
      @content_height = total_height + 50  # タイトル部分の高さを加算
      
      # スクロールバー
      if @content_height > height
        scrollbar_width = 8
        scrollbar_height = (height * (height.to_f / @content_height)).to_i
        scrollbar_max_y = height - scrollbar_height
        scrollbar_y = (scrollbar_max_y * (scroll_offset.to_f / (@content_height - height))).to_i
        
        window.set_draw_color(theme.colors.foreground, 0.2)
        window.fill_rounded_rect(x: x + width - scrollbar_width - 4, y: y + scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
    end
    
    # イベント処理
    def handle_event(event)
      case event
      when Events::MouseEvent
        handle_mouse_event(event)
      when Events::KeyEvent
        handle_key_event(event)
      end
    end
    
    # マウスイベント処理
    def handle_mouse_event(event : Events::MouseEvent)
      # 実装はサブクラスで
    end
    
    # キーボードイベント処理
    def handle_key_event(event : Events::KeyEvent)
      # 入力フィールドの処理
      @items.each do |item|
        if item.is_a?(InputSetting)
          return if item.handle_key_event(event)
        end
      end
    end
    
    # パネルのタイトル
    def panel_title : String
      "設定"
    end
    
    # 検索でマッチする項目を返す
    def search(query : String) : Array({SettingItem, String})
      return [] of {SettingItem, String} if query.empty?
      
      result = [] of {SettingItem, String}
      @items.each do |item|
        if item.matches?(query) && !item.is_a?(SectionHeader)
          result << {item, panel_title}
        end
      end
      
      result
    end
  end
end 