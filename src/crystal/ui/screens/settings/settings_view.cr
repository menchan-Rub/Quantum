# src/crystal/ui/screens/settings/settings_view.cr
require "concave"
require "../../component"
require "../../theme_engine"
require "../../../quantum_core/engine"
require "../../../quantum_core/config"
require "../../../events/**"
require "../../../utils/logger"
require "./settings_panels/**"

module QuantumUI
  # 設定画面コンポーネント
  class SettingsView < Component
    # 設定カテゴリ
    enum SettingCategory
      General
      Appearance
      Privacy
      Network
      Extensions
      Advanced
      Developer
    end
    
    property visible : Bool = false
    property current_category : SettingCategory = SettingCategory::General
    property scroll_offset : Int32 = 0
    
    @config_manager : QuantumCore::ConfigManager
    @search_query : String = ""
    @search_focused : Bool = false
    @needs_restart : Bool = false
    @panels : Hash(SettingCategory, SettingsPanel) = {} of SettingCategory => SettingsPanel
    
    def initialize(@config_manager : QuantumCore::ConfigManager)
      super()
      initialize_panels
    end
    
    private def initialize_panels
      @panels[SettingCategory::General] = GeneralSettingsPanel.new(@config_manager)
      @panels[SettingCategory::Appearance] = AppearanceSettingsPanel.new(@config_manager)
      @panels[SettingCategory::Privacy] = PrivacySettingsPanel.new(@config_manager)
      @panels[SettingCategory::Network] = NetworkSettingsPanel.new(@config_manager)
      @panels[SettingCategory::Extensions] = ExtensionsSettingsPanel.new(@config_manager)
      @panels[SettingCategory::Advanced] = AdvancedSettingsPanel.new(@config_manager)
      @panels[SettingCategory::Developer] = DeveloperSettingsPanel.new(@config_manager)
    end
    
    def toggle_visibility
      @visible = !@visible
      if @visible
        # 設定画面を開く時にすべてのパネルを更新
        @panels.each_value &.refresh
      end
    end
    
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32, theme : ThemeEngine) : Nil
      return unless @visible
      
      # 設定モーダルの背景
      window.set_draw_color(theme.colors.background, 0.98)
      window.fill_rect(x: x, y: y, width: width, height: height)
      window.set_draw_color(theme.colors.border, 1.0)
      window.draw_rect(x: x, y: y, width: width, height: height)
      
      # ヘッダー部分
      header_height = 60
      window.set_draw_color(theme.colors.background_variant, 1.0)
      window.fill_rect(x: x, y: y, width: width, height: header_height)
      
      # タイトル
      window.set_draw_color(theme.colors.foreground, 1.0)
      window.draw_text("設定", x: x + 20, y: y + 15, size: theme.font_size + 4, font: theme.font_family)
      
      # 検索ボックス
      search_width = 300
      search_height = 32
      search_x = x + width - search_width - 20
      search_y = y + (header_height - search_height) / 2
      
      # 検索ボックスの背景
      border_color = @search_focused ? theme.colors.accent : theme.colors.border
      window.set_draw_color(theme.colors.background, 1.0)
      window.fill_rect(x: search_x, y: search_y, width: search_width, height: search_height)
      window.set_draw_color(border_color, 1.0)
      window.draw_rect(x: search_x, y: search_y, width: search_width, height: search_height)
      
      # 検索アイコン
      icon_size = 16
      window.set_draw_color(theme.colors.foreground, 0.7)
      # 簡易的な検索アイコン
      window.draw_circle(x: search_x + 18, y: search_y + search_height / 2, radius: 6)
      window.draw_line(
        x1: search_x + 22, y1: search_y + search_height / 2 + 4,
        x2: search_x + 26, y2: search_y + search_height / 2 + 8
      )
      
      # 検索テキスト
      display_text = @search_query.empty? ? "設定を検索..." : @search_query
      text_color = @search_query.empty? ? 0.5 : 1.0
      window.set_draw_color(theme.colors.foreground, text_color)
      window.draw_text(display_text, x: search_x + 30, y: search_y + 8, size: theme.font_size, font: theme.font_family)
      
      # サイドバーとコンテンツエリア
      sidebar_width = 200
      content_x = x + sidebar_width
      content_width = width - sidebar_width
      content_y = y + header_height
      content_height = height - header_height
      
      # サイドバー背景
      window.set_draw_color(theme.colors.background_lighter, 1.0)
      window.fill_rect(x: x, y: content_y, width: sidebar_width, height: content_height)
      
      # カテゴリーリスト
      categories = [
        {SettingCategory::General, "一般", "🔧"},
        {SettingCategory::Appearance, "外観", "🎨"},
        {SettingCategory::Privacy, "プライバシー", "🔒"},
        {SettingCategory::Network, "ネットワーク", "🌐"},
        {SettingCategory::Extensions, "拡張機能", "🧩"},
        {SettingCategory::Advanced, "詳細設定", "⚙️"},
        {SettingCategory::Developer, "開発者", "💻"}
      ]
      
      category_height = 40
      categories.each_with_index do |(category, label, icon), index|
        cat_y = content_y + index * category_height
        is_selected = category == @current_category
        
        if is_selected
          window.set_draw_color(theme.colors.accent, 0.2)
          window.fill_rect(x: x, y: cat_y, width: sidebar_width, height: category_height)
          window.set_draw_color(theme.colors.accent, 1.0)
          window.fill_rect(x: x, y: cat_y, width: 4, height: category_height)
        end
        
        # アイコン
        window.set_draw_color(theme.colors.foreground, 0.8)
        window.draw_text(icon, x: x + 15, y: cat_y + 10, size: theme.font_size, font: theme.font_family)
        
        # カテゴリ名
        window.set_draw_color(theme.colors.foreground, is_selected ? 1.0 : 0.7)
        window.draw_text(label, x: x + 45, y: cat_y + 10, size: theme.font_size, font: theme.font_family)
      end
      
      # 区切り線
      window.set_draw_color(theme.colors.border, 1.0)
      window.draw_line(x1: content_x, y1: content_y, x2: content_x, y2: content_y + content_height)
      
      # コンテンツエリア
      if @search_query.empty?
        # 通常表示（カテゴリ選択）
        render_category_panel(window, content_x, content_y, content_width, content_height, theme)
      else
        # 検索結果表示
        render_search_results(window, content_x, content_y, content_width, content_height, theme)
      end
      
      # 再起動が必要な場合の通知バナー
      if @needs_restart
        banner_height = 36
        banner_y = y + height - banner_height
        
        window.set_draw_color({r: 255, g: 153, b: 0}, 0.9)  # オレンジ色の背景
        window.fill_rect(x: x, y: banner_y, width: width, height: banner_height)
        
        window.set_draw_color(theme.colors.background, 1.0)
        message = "変更を完全に適用するには、ブラウザの再起動が必要です。"
        window.draw_text(message, x: x + 20, y: banner_y + 10, size: theme.font_size, font: theme.font_family)
        
        # 再起動ボタン
        button_width = 100
        button_height = 26
        button_x = x + width - button_width - 20
        button_y = banner_y + (banner_height - button_height) / 2
        
        window.set_draw_color(theme.colors.background, 1.0)
        window.fill_rounded_rect(x: button_x, y: button_y, width: button_width, height: button_height, radius: 3)
        
        window.set_draw_color({r: 255, g: 153, b: 0}, 1.0)
        text = "今すぐ再起動"
        text_width = window.measure_text(text, size: theme.font_size - 1, font: theme.font_family)
        window.draw_text(text, x: button_x + (button_width - text_width) / 2, y: button_y + 5, size: theme.font_size - 1, font: theme.font_family)
      end
      
      # クローズボタン
      close_size = 20
      close_x = x + width - close_size - 10
      close_y = y + 10
      
      window.set_draw_color(theme.colors.foreground, 0.7)
      window.draw_line(x1: close_x, y1: close_y, x2: close_x + close_size, y2: close_y + close_size)
      window.draw_line(x1: close_x, y1: close_y + close_size, x2: close_x + close_size, y2: close_y)
    end
    
    private def render_category_panel(window, x, y, width, height, theme)
      # 現在のカテゴリに対応するパネルを表示
      panel = @panels[@current_category]
      panel.render(window, x, y, width, height, theme, @scroll_offset)
    end
    
    private def render_search_results(window, x, y, width, height, theme)
      found_items = [] of {SettingsPanel, SettingItem, String}
      
      # すべてのパネルから検索クエリにマッチする設定項目を検索
      @panels.each_value do |panel|
        panel.search(@search_query).each do |item, category_name|
          found_items << {panel, item, category_name}
        end
      end
      
      if found_items.empty?
        # 検索結果がない場合
        message = "「#{@search_query}」に一致する設定は見つかりませんでした"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
        return
      end
      
      # 検索結果の表示
      current_y = y - @scroll_offset
      item_padding = 15
      
      found_items.each_with_index do |(panel, item, category_name), index|
        # カテゴリラベル
        if index == 0 || found_items[index - 1][2] != category_name
          window.set_draw_color(theme.colors.foreground, 0.6)
          window.draw_text(category_name, x: x + 20, y: current_y + 15, size: theme.font_size, font: theme.font_family)
          current_y += 30
        end
        
        # 設定項目を表示
        item_height = item.render(window, x + 20, current_y + item_padding, width - 40, theme)
        current_y += item_height + item_padding * 2
        
        # 区切り線
        window.set_draw_color(theme.colors.border, 0.3)
        window.draw_line(x1: x + 20, y1: current_y, x2: x + width - 20, y2: current_y)
      end
      
      # スクロールバー
      total_height = found_items.sum do |(panel, item, category_name)|
        item.height + item_padding * 2
      end
      
      if total_height > height
        scrollbar_width = 8
        scrollbar_height = (height * (height.to_f / total_height)).to_i
        scrollbar_max_y = height - scrollbar_height
        scrollbar_y = (scrollbar_max_y * (@scroll_offset.to_f / (total_height - height))).to_i
        
        window.set_draw_color(theme.colors.foreground, 0.2)
        window.fill_rounded_rect(x: x + width - scrollbar_width - 4, y: y + scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
    end
    
    def handle_event(event)
      return unless @visible
      
      case event
      when Events::MouseEvent
        handle_mouse_event(event)
      when Events::KeyEvent
        handle_key_event(event)
      when Events::ScrollEvent
        handle_scroll_event(event)
      end
      
      # 現在のパネルにもイベントを渡す
      if @search_query.empty?
        @panels[@current_category].handle_event(event)
      end
    end
    
    private def handle_mouse_event(event)
      # マウスイベント処理
    end
    
    private def handle_key_event(event)
      # キーボードイベント処理
    end
    
    private def handle_scroll_event(event)
      # スクロールイベント処理
      @scroll_offset += event.delta_y * 30
      @scroll_offset = 0 if @scroll_offset < 0
      
      # 最大スクロール量を制限
      if @search_query.empty?
        panel = @panels[@current_category]
        max_scroll = panel.content_height - panel.visible_height
        @scroll_offset = max_scroll if @scroll_offset > max_scroll && max_scroll > 0
      end
    end
    
    def set_category(category : SettingCategory)
      @current_category = category
      @scroll_offset = 0
      @search_query = ""
    end
    
    def set_search_query(query : String)
      @search_query = query
      @scroll_offset = 0
    end
    
    def notify_restart_needed
      @needs_restart = true
    end
    
    def restart_browser
      # ブラウザ再起動のロジック
      @needs_restart = false
    end
  end
end 