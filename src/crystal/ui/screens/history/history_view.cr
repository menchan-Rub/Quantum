# src/crystal/ui/screens/history/history_view.cr
require "concave"
require "../../component"
require "../../theme_engine"
require "../../../quantum_core/engine"
require "../../../quantum_core/config"
require "../../../events/**"
require "../../../utils/logger"
require "../../../storage/history/history_manager"

module QuantumUI
  # 履歴画面コンポーネント
  class HistoryView < Component
    enum ViewMode
      Timeline  # 時系列表示
      Grouped   # サイト/ドメインでグループ化
      Frequency # 訪問頻度順
      Search    # 検索結果
    end

    property visible : Bool = false
    property current_mode : ViewMode = ViewMode::Timeline
    property search_query : String = ""
    property selected_date_range : String = "全期間"
    property selected_index : Int32 = -1
    property scroll_offset : Int32 = 0
    property items_per_page : Int32 = 50
    property current_page : Int32 = 0
    
    @filtered_history : Array(QuantumStorage::HistoryEntry) = [] of QuantumStorage::HistoryEntry
    @grouped_items : Hash(String, Array(QuantumStorage::HistoryEntry)) = {} of String => Array(QuantumStorage::HistoryEntry)
    @date_ranges = ["今日", "昨日", "先週", "先月", "全期間"]
    @search_focused : Bool = false
    @history_manager : QuantumStorage::HistoryManager
    @item_height : Int32 = 48
    @group_header_height : Int32 = 32
    
    def initialize(@history_manager : QuantumStorage::HistoryManager)
      super()
      load_history
    end
    
    def load_history
      case @current_mode
      when ViewMode::Timeline
        @filtered_history = filter_by_date_range(@history_manager.get_all_entries)
      when ViewMode::Grouped
        group_history_items
      when ViewMode::Frequency
        @filtered_history = filter_by_date_range(@history_manager.get_entries_by_frequency)
      when ViewMode::Search
        if @search_query.empty?
          @filtered_history = [] of QuantumStorage::HistoryEntry
        else
          @filtered_history = @history_manager.search_entries(@search_query)
        end
      end
    end
    
    def filter_by_date_range(entries)
      return entries if @selected_date_range == "全期間"
      
      now = Time.utc
      cutoff_time = case @selected_date_range
        when "今日"
          now.at_beginning_of_day
        when "昨日"
          (now - 1.day).at_beginning_of_day
        when "先週"
          (now - 7.days).at_beginning_of_day
        when "先月"
          (now - 30.days).at_beginning_of_day
        else
          Time.unix(0)
        end
        
      entries.select { |entry| entry.timestamp >= cutoff_time }
    end
    
    def group_history_items
      @grouped_items.clear
      entries = filter_by_date_range(@history_manager.get_all_entries)
      
      entries.each do |entry|
        domain = URI.parse(entry.url).host.to_s
        @grouped_items[domain] ||= [] of QuantumStorage::HistoryEntry
        @grouped_items[domain] << entry
      end
      
      # 各グループ内で時間順にソート
      @grouped_items.each do |domain, items|
        @grouped_items[domain] = items.sort_by(&.timestamp).reverse
      end
    end
    
    def toggle_visibility
      @visible = !@visible
      if @visible
        load_history
      end
    end
    
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32, theme : ThemeEngine) : Nil
      return unless @visible
      
      # 履歴モーダルの背景
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
      window.draw_text("履歴", x: x + 20, y: y + 15, size: theme.font_size + 4, font: theme.font_family)
      
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
      # 簡易的な検索アイコン（実際には適切なアイコンを使用）
      window.draw_circle(x: search_x + 18, y: search_y + search_height / 2, radius: 6)
      window.draw_line(
        x1: search_x + 22, y1: search_y + search_height / 2 + 4,
        x2: search_x + 26, y2: search_y + search_height / 2 + 8
      )
      
      # 検索テキスト
      display_text = @search_query.empty? ? "履歴を検索..." : @search_query
      text_color = @search_query.empty? ? 0.5 : 1.0
      window.set_draw_color(theme.colors.foreground, text_color)
      window.draw_text(display_text, x: search_x + 30, y: search_y + 8, size: theme.font_size, font: theme.font_family)
      
      # タブ/フィルターエリア
      tabs_y = y + header_height
      tabs_height = 40
      tab_width = width / 4
      
      window.set_draw_color(theme.colors.background_lighter, 1.0)
      window.fill_rect(x: x, y: tabs_y, width: width, height: tabs_height)
      
      # モードタブ
      modes = ["時系列", "サイト別", "頻度順", "検索結果"]
      modes.each_with_index do |mode, index|
        tab_x = x + tab_width * index
        is_active = index == @current_mode.value
        
        if is_active
          window.set_draw_color(theme.colors.accent, 1.0)
          window.fill_rect(x: tab_x, y: tabs_y, width: tab_width, height: tabs_height)
          window.set_draw_color(theme.colors.background, 1.0)
          window.fill_rect(x: tab_x + 2, y: tabs_y + 2, width: tab_width - 4, height: tabs_height - 4)
        end
        
        text_color = is_active ? 1.0 : 0.7
        window.set_draw_color(theme.colors.foreground, text_color)
        text_width = window.measure_text(mode, size: theme.font_size, font: theme.font_family)
        window.draw_text(mode, x: tab_x + (tab_width - text_width) / 2, y: tabs_y + (tabs_height - theme.font_size) / 2, size: theme.font_size, font: theme.font_family)
      end
      
      # 日付範囲フィルター
      filter_y = tabs_y + tabs_height
      filter_height = 40
      
      window.set_draw_color(theme.colors.background_lighter, 0.8)
      window.fill_rect(x: x, y: filter_y, width: width, height: filter_height)
      
      # 各日付範囲オプション
      range_width = width / @date_ranges.size
      @date_ranges.each_with_index do |range, index|
        range_x = x + range_width * index
        is_selected = range == @selected_date_range
        
        if is_selected
          window.set_draw_color(theme.colors.accent, 0.3)
          window.fill_rect(x: range_x, y: filter_y, width: range_width, height: filter_height)
        end
        
        text_color = is_selected ? 1.0 : 0.7
        window.set_draw_color(theme.colors.foreground, text_color)
        text_width = window.measure_text(range, size: theme.font_size - 1, font: theme.font_family)
        window.draw_text(range, x: range_x + (range_width - text_width) / 2, y: filter_y + (filter_height - theme.font_size + 1) / 2, size: theme.font_size - 1, font: theme.font_family)
      end
      
      # コンテンツエリア
      content_y = filter_y + filter_height
      content_height = height - content_y + y
      
      # スクロール可能なコンテンツ領域
      case @current_mode
      when ViewMode::Timeline, ViewMode::Frequency, ViewMode::Search
        render_timeline_view(window, x, content_y, width, content_height, theme)
      when ViewMode::Grouped
        render_grouped_view(window, x, content_y, width, content_height, theme)
      end
      
      # クローズボタン
      close_size = 20
      close_x = x + width - close_size - 10
      close_y = y + 10
      
      window.set_draw_color(theme.colors.foreground, 0.7)
      window.draw_line(x1: close_x, y1: close_y, x2: close_x + close_size, y2: close_y + close_size)
      window.draw_line(x1: close_x, y1: close_y + close_size, x2: close_x + close_size, y2: close_y)
    end
    
    def render_timeline_view(window, x, y, width, height, theme)
      # 履歴がない場合のメッセージ
      if @filtered_history.empty?
        message = @current_mode == ViewMode::Search ? "検索結果はありません" : "表示できる履歴がありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
        return
      end
      
      # ページネーション管理
      total_pages = (@filtered_history.size - 1) / @items_per_page + 1
      @current_page = 0 if @current_page >= total_pages
      
      start_index = @current_page * @items_per_page
      end_index = Math.min(start_index + @items_per_page, @filtered_history.size) - 1
      
      # アイテム描画
      item_y = y - @scroll_offset
      @filtered_history[start_index..end_index].each_with_index do |entry, index|
        actual_index = start_index + index
        is_selected = actual_index == @selected_index
        
        # アイテム背景
        bg_color = is_selected ? theme.colors.accent : (index.even? ? theme.colors.background : theme.colors.background_lighter)
        window.set_draw_color(bg_color, is_selected ? 0.3 : 1.0)
        window.fill_rect(x: x, y: item_y, width: width, height: @item_height)
        
        # タイムスタンプ
        time_format = entry.timestamp.to_s("%Y-%m-%d %H:%M")
        window.set_draw_color(theme.colors.foreground, 0.6)
        window.draw_text(time_format, x: x + 20, y: item_y + 8, size: theme.font_size - 2, font: theme.font_family)
        
        # ページタイトル
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(entry.title, x: x + 20, y: item_y + 26, size: theme.font_size, font: theme.font_family)
        
        # URL
        url_width = window.measure_text(entry.url, size: theme.font_size - 2, font: theme.font_family)
        display_url = url_width > (width - 150) ? "#{entry.url[0, 60]}..." : entry.url
        window.set_draw_color(theme.colors.foreground, 0.5)
        window.draw_text(display_url, x: x + width - 20 - url_width, y: item_y + 8, size: theme.font_size - 2, font: theme.font_family)
        
        item_y += @item_height
      end
      
      # スクロールバー
      if @filtered_history.size > @items_per_page
        scrollbar_width = 8
        scrollbar_height = (height * (@items_per_page.to_f / @filtered_history.size)).to_i
        scrollbar_max_y = height - scrollbar_height
        scrollbar_y = (scrollbar_max_y * (@scroll_offset.to_f / ((@filtered_history.size - @items_per_page) * @item_height))).to_i
        
        window.set_draw_color(theme.colors.foreground, 0.2)
        window.fill_rounded_rect(x: x + width - scrollbar_width - 4, y: y + scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
      
      # ページネーションコントロール
      if total_pages > 1
        pagination_y = y + height - 30
        window.set_draw_color(theme.colors.background_lighter, 1.0)
        window.fill_rect(x: x, y: pagination_y, width: width, height: 30)
        
        # 前のページ
        prev_disabled = @current_page == 0
        prev_color = prev_disabled ? 0.3 : 0.7
        window.set_draw_color(theme.colors.foreground, prev_color)
        window.draw_text("◀ 前のページ", x: x + 20, y: pagination_y + 8, size: theme.font_size - 1, font: theme.font_family)
        
        # ページ表示
        page_text = "#{@current_page + 1} / #{total_pages}"
        text_width = window.measure_text(page_text, size: theme.font_size, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(page_text, x: x + (width - text_width) / 2, y: pagination_y + 8, size: theme.font_size - 1, font: theme.font_family)
        
        # 次のページ
        next_disabled = @current_page >= total_pages - 1
        next_color = next_disabled ? 0.3 : 0.7
        window.set_draw_color(theme.colors.foreground, next_color)
        next_text = "次のページ ▶"
        next_width = window.measure_text(next_text, size: theme.font_size - 1, font: theme.font_family)
        window.draw_text(next_text, x: x + width - 20 - next_width, y: pagination_y + 8, size: theme.font_size - 1, font: theme.font_family)
      end
    end
    
    def render_grouped_view(window, x, y, width, height, theme)
      # グループがない場合のメッセージ
      if @grouped_items.empty?
        message = "表示できるグループがありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
        return
      end
      
      # グループ描画
      current_y = y - @scroll_offset
      @grouped_items.each do |domain, entries|
        # ドメイン見出し
        window.set_draw_color(theme.colors.accent, 0.2)
        window.fill_rect(x: x, y: current_y, width: width, height: @group_header_height)
        
        window.set_draw_color(theme.colors.foreground, 0.9)
        domain_display = "#{domain} (#{entries.size}項目)"
        window.draw_text(domain_display, x: x + 15, y: current_y + (@group_header_height - theme.font_size) / 2, size: theme.font_size, font: theme.font_family)
        
        current_y += @group_header_height
        
        # グループ内エントリー
        entries.each_with_index do |entry, index|
          # アイテム背景
          bg_color = index.even? ? theme.colors.background : theme.colors.background_lighter
          window.set_draw_color(bg_color, 1.0)
          window.fill_rect(x: x, y: current_y, width: width, height: @item_height)
          
          # タイムスタンプ
          time_format = entry.timestamp.to_s("%Y-%m-%d %H:%M")
          window.set_draw_color(theme.colors.foreground, 0.6)
          window.draw_text(time_format, x: x + 30, y: current_y + 8, size: theme.font_size - 2, font: theme.font_family)
          
          # ページタイトル
          window.set_draw_color(theme.colors.foreground, 1.0)
          window.draw_text(entry.title, x: x + 30, y: current_y + 26, size: theme.font_size, font: theme.font_family)
          
          current_y += @item_height
        end
      end
      
      # スクロールバー（グループビュー用）
      total_height = @grouped_items.sum { |_, entries| @group_header_height + (entries.size * @item_height) }
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
      end
    end
    
    def handle_mouse_event(event)
      # 履歴モーダル内での座標計算
      # イベント処理ロジックを実装
    end
    
    def handle_key_event(event)
      # キーボードショートカット処理
      # イベント処理ロジックを実装
    end
    
    def switch_mode(mode : ViewMode)
      @current_mode = mode
      @scroll_offset = 0
      @selected_index = -1
      load_history
    end
    
    def clear_all_history
      if @history_manager.clear_all
        @filtered_history.clear
        @grouped_items.clear
      end
    end
    
    def clear_selected_items
      # 選択アイテムの削除機能
    end
  end
end 