# src/crystal/ui/screens/bookmarks/bookmarks_view.cr
require "concave"
require "../../component"
require "../../theme_engine"
require "../../../quantum_core/engine"
require "../../../quantum_core/config"
require "../../../events/**"
require "../../../utils/logger"
require "../../../storage/bookmarks/**"

module QuantumUI
  # ブックマーク画面コンポーネント
  class BookmarksView < Component
    enum ViewMode
      List     # リスト表示
      Grid     # グリッド表示
      Tree     # ツリー表示
      Tags     # タグ表示
    end
    
    property visible : Bool = false
    property current_mode : ViewMode = ViewMode::Tree
    property search_query : String = ""
    property selected_folder : String = ""
    property selected_item_id : String? = nil
    property expanded_folders : Set(String) = Set(String).new
    property scroll_offset : Int32 = 0
    
    @search_focused : Bool = false
    @bookmark_manager : QuantumStorage::BookmarkManager
    @filtered_bookmarks : Array(QuantumStorage::BookmarkItem) = [] of QuantumStorage::BookmarkItem
    @current_path : Array(QuantumStorage::BookmarkFolder) = [] of QuantumStorage::BookmarkFolder
    @drag_item_id : String? = nil
    @drag_start_x : Int32 = 0
    @drag_start_y : Int32 = 0
    @item_height : Int32 = 36
    @folder_height : Int32 = 32
    @grid_item_size : Int32 = 120
    @grid_columns : Int32 = 5
    @tag_list : Array(String) = [] of String
    
    def initialize(@bookmark_manager : QuantumStorage::BookmarkManager)
      super()
      @expanded_folders << "root"  # ルートフォルダは常に展開
      refresh_data
    end
    
    def refresh_data
      case @current_mode
      when ViewMode::List, ViewMode::Grid, ViewMode::Tree
        if @search_query.empty?
          if @selected_folder.empty?
            @filtered_bookmarks = @bookmark_manager.get_all_bookmarks
          else
            @filtered_bookmarks = @bookmark_manager.get_bookmarks_in_folder(@selected_folder)
          end
          update_current_path
        else
          @filtered_bookmarks = @bookmark_manager.search_bookmarks(@search_query)
        end
      when ViewMode::Tags
        if @search_query.empty?
          update_tag_list
          if @selected_folder.empty?
            @filtered_bookmarks = [] of QuantumStorage::BookmarkItem
          else
            # 選択されたタグでフィルタリング
            @filtered_bookmarks = @bookmark_manager.get_bookmarks_with_tag(@selected_folder)
          end
        else
          @filtered_bookmarks = @bookmark_manager.search_bookmarks(@search_query)
        end
      end
    end
    
    def update_current_path
      @current_path.clear
      return if @selected_folder.empty? || @selected_folder == "root"
      
      current_folder_id = @selected_folder
      while current_folder_id && current_folder_id != "root"
        folder = @bookmark_manager.get_folder(current_folder_id)
        if folder
          @current_path.unshift(folder)
          current_folder_id = folder.parent_id
        else
          break
        end
      end
    end
    
    def update_tag_list
      @tag_list = @bookmark_manager.get_all_tags
    end
    
    def toggle_visibility
      @visible = !@visible
      if @visible
        refresh_data
      end
    end
    
    def render(window : Concave::Window, x : Int32, y : Int32, width : Int32, height : Int32, theme : ThemeEngine) : Nil
      return unless @visible
      
      # ブックマークモーダルの背景
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
      window.draw_text("ブックマーク", x: x + 20, y: y + 15, size: theme.font_size + 4, font: theme.font_family)
      
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
      display_text = @search_query.empty? ? "ブックマークを検索..." : @search_query
      text_color = @search_query.empty? ? 0.5 : 1.0
      window.set_draw_color(theme.colors.foreground, text_color)
      window.draw_text(display_text, x: search_x + 30, y: search_y + 8, size: theme.font_size, font: theme.font_family)
      
      # タブ/表示モードエリア
      tabs_y = y + header_height
      tabs_height = 40
      tab_width = width / 4
      
      window.set_draw_color(theme.colors.background_lighter, 1.0)
      window.fill_rect(x: x, y: tabs_y, width: width, height: tabs_height)
      
      # 表示モードタブ
      modes = ["ツリー表示", "リスト表示", "グリッド表示", "タグ表示"]
      modes.each_with_index do |mode, index|
        tab_x = x + tab_width * index
        is_active = case index
          when 0 then @current_mode == ViewMode::Tree
          when 1 then @current_mode == ViewMode::List
          when 2 then @current_mode == ViewMode::Grid
          when 3 then @current_mode == ViewMode::Tags
          else false
        end
        
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
      
      # パンくずリスト/現在位置
      breadcrumb_y = tabs_y + tabs_height
      breadcrumb_height = 36
      
      window.set_draw_color(theme.colors.background_lighter, 0.8)
      window.fill_rect(x: x, y: breadcrumb_y, width: width, height: breadcrumb_height)
      
      # ルートアイコン
      window.set_draw_color(theme.colors.foreground, 0.7)
      window.draw_text("🏠", x: x + 15, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
      
      # パンくずリスト描画
      crumb_x = x + 40
      if @current_mode == ViewMode::Tags && !@selected_folder.empty?
        # タグモードの場合は選択中のタグを表示
        window.set_draw_color(theme.colors.foreground, 0.5)
        window.draw_text("タグ:", x: crumb_x, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
        crumb_x += 40
        
        window.set_draw_color(theme.colors.accent, 1.0)
        window.draw_text(@selected_folder, x: crumb_x, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
      elsif @current_mode == ViewMode::Tree || @current_mode == ViewMode::List
        # フォルダパスを表示
        if @current_path.empty?
          window.set_draw_color(theme.colors.foreground, 0.7)
          window.draw_text("すべてのブックマーク", x: crumb_x, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
        else
          @current_path.each_with_index do |folder, index|
            window.set_draw_color(theme.colors.foreground, 0.7)
            window.draw_text(">", x: crumb_x, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
            crumb_x += 20
            
            text_color = index == @current_path.size - 1 ? 1.0 : 0.7
            window.set_draw_color(theme.colors.foreground, text_color)
            window.draw_text(folder.name, x: crumb_x, y: breadcrumb_y + 10, size: theme.font_size, font: theme.font_family)
            crumb_x += window.measure_text(folder.name, size: theme.font_size, font: theme.font_family) + 10
          end
        end
      end
      
      # コンテンツエリア
      content_y = breadcrumb_y + breadcrumb_height
      content_height = height - content_y + y
      
      # 現在のモードに応じたコンテンツ表示
      case @current_mode
      when ViewMode::Tree
        render_tree_view(window, x, content_y, width, content_height, theme)
      when ViewMode::List
        render_list_view(window, x, content_y, width, content_height, theme)
      when ViewMode::Grid
        render_grid_view(window, x, content_y, width, content_height, theme)
      when ViewMode::Tags
        render_tags_view(window, x, content_y, width, content_height, theme)
      end
      
      # アクションボタン（新規追加、フォルダ作成など）
      action_button_size = 50
      action_button_y = y + height - action_button_size - 20
      action_button_x = x + width - action_button_size - 20
      
      window.set_draw_color(theme.colors.accent, 1.0)
      window.fill_circle(x: action_button_x + action_button_size / 2, y: action_button_y + action_button_size / 2, radius: action_button_size / 2)
      
      # プラスアイコン
      window.set_draw_color(theme.colors.background, 1.0)
      plus_size = 20
      window.draw_line(
        x1: action_button_x + action_button_size / 2 - plus_size / 2, 
        y1: action_button_y + action_button_size / 2,
        x2: action_button_x + action_button_size / 2 + plus_size / 2, 
        y2: action_button_y + action_button_size / 2,
        thickness: 3
      )
      window.draw_line(
        x1: action_button_x + action_button_size / 2, 
        y1: action_button_y + action_button_size / 2 - plus_size / 2,
        x2: action_button_x + action_button_size / 2, 
        y2: action_button_y + action_button_size / 2 + plus_size / 2,
        thickness: 3
      )
      
      # クローズボタン
      close_size = 20
      close_x = x + width - close_size - 10
      close_y = y + 10
      
      window.set_draw_color(theme.colors.foreground, 0.7)
      window.draw_line(x1: close_x, y1: close_y, x2: close_x + close_size, y2: close_y + close_size)
      window.draw_line(x1: close_x, y1: close_y + close_size, x2: close_x + close_size, y2: close_y)
    end
    
    def render_tree_view(window, x, y, width, height, theme)
      # ツリー表示の場合は左側にフォルダツリー、右側にブックマークリスト
      tree_width = width * 0.3
      content_width = width - tree_width
      
      # フォルダツリー部分
      window.set_draw_color(theme.colors.background_lighter, 1.0)
      window.fill_rect(x: x, y: y, width: tree_width, height: height)
      
      # フォルダツリーの描画
      folders = @bookmark_manager.get_all_folders
      root_folders = folders.select { |f| f.parent_id == "root" }
      
      tree_y = y - @scroll_offset
      draw_folder_tree(window, x, tree_y, tree_width, theme, root_folders, 0)
      
      # 区切り線
      window.set_draw_color(theme.colors.border, 1.0)
      window.draw_line(x1: x + tree_width, y1: y, x2: x + tree_width, y2: y + height)
      
      # ブックマークリスト部分
      bookmarks_x = x + tree_width + 1
      bookmarks_width = content_width - 1
      
      if @filtered_bookmarks.empty?
        message = "このフォルダにはブックマークがありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: bookmarks_x + (bookmarks_width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
      else
        render_bookmarks_list(window, bookmarks_x, y, bookmarks_width, height, theme)
      end
    end
    
    def draw_folder_tree(window, x, y, width, theme, folders, indent_level)
      current_y = y
      indent_width = 20
      
      folders.each do |folder|
        item_x = x + indent_level * indent_width
        item_width = width - indent_level * indent_width
        
        is_selected = folder.id == @selected_folder
        is_expanded = @expanded_folders.includes?(folder.id)
        has_children = @bookmark_manager.has_subfolders(folder.id)
        
        # フォルダアイテム背景
        if is_selected
          window.set_draw_color(theme.colors.accent, 0.3)
          window.fill_rect(x: x, y: current_y, width: width, height: @folder_height)
        end
        
        # 展開/折りたたみアイコン
        if has_children
          icon_x = item_x + 5
          icon_y = current_y + @folder_height / 2
          icon_size = 8
          
          window.set_draw_color(theme.colors.foreground, 0.7)
          if is_expanded
            # 展開中（▼）
            window.fill_triangle(
              x1: icon_x, y1: icon_y - icon_size / 2,
              x2: icon_x + icon_size, y2: icon_y - icon_size / 2,
              x3: icon_x + icon_size / 2, y3: icon_y + icon_size / 2
            )
          else
            # 折りたたみ中（▶）
            window.fill_triangle(
              x1: icon_x, y1: icon_y - icon_size / 2,
              x2: icon_x, y2: icon_y + icon_size / 2,
              x3: icon_x + icon_size, y3: icon_y
            )
          end
        end
        
        # フォルダアイコン
        folder_icon_x = item_x + (has_children ? 18 : 5)
        folder_icon_y = current_y + (@folder_height - theme.font_size) / 2
        window.set_draw_color(theme.colors.foreground, 0.8)
        window.draw_text("📁", x: folder_icon_x, y: folder_icon_y, size: theme.font_size, font: theme.font_family)
        
        # フォルダ名
        folder_name_x = folder_icon_x + 25
        window.set_draw_color(theme.colors.foreground, is_selected ? 1.0 : 0.9)
        window.draw_text(folder.name, x: folder_name_x, y: folder_icon_y, size: theme.font_size, font: theme.font_family)
        
        current_y += @folder_height
        
        # サブフォルダの描画（展開されている場合）
        if is_expanded && has_children
          subfolders = @bookmark_manager.get_subfolders(folder.id)
          current_y = draw_folder_tree(window, x, current_y, width, theme, subfolders, indent_level + 1)
        end
      end
      
      return current_y
    end
    
    def render_list_view(window, x, y, width, height, theme)
      if @filtered_bookmarks.empty?
        message = "表示できるブックマークがありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
      else
        render_bookmarks_list(window, x, y, width, height, theme)
      end
    end
    
    def render_bookmarks_list(window, x, y, width, height, theme)
      current_y = y - @scroll_offset
      
      @filtered_bookmarks.each_with_index do |bookmark, index|
        is_selected = bookmark.id == @selected_item_id
        
        # アイテム背景
        bg_color = is_selected ? theme.colors.accent : (index.even? ? theme.colors.background : theme.colors.background_lighter)
        window.set_draw_color(bg_color, is_selected ? 0.3 : 1.0)
        window.fill_rect(x: x, y: current_y, width: width, height: @item_height)
        
        # ファビコン (実際にはサイトのファビコンを表示)
        icon_x = x + 15
        icon_y = current_y + (@item_height - theme.font_size) / 2
        window.set_draw_color(theme.colors.foreground, 0.8)
        window.draw_text("🌐", x: icon_x, y: icon_y, size: theme.font_size, font: theme.font_family)
        
        # タイトル
        title_x = icon_x + 30
        window.set_draw_color(theme.colors.foreground, 1.0)
        title_width = width - 40
        window.draw_text(bookmark.title, x: title_x, y: icon_y, size: theme.font_size, font: theme.font_family, max_width: title_width)
        
        # URL
        url_x = title_x
        url_y = icon_y + theme.font_size + 2
        url_width = window.measure_text(bookmark.url, size: theme.font_size - 2, font: theme.font_family)
        display_url = url_width > (width - 40) ? "#{bookmark.url[0, 60]}..." : bookmark.url
        window.set_draw_color(theme.colors.foreground, 0.5)
        window.draw_text(display_url, x: url_x, y: url_y, size: theme.font_size - 2, font: theme.font_family)
        
        current_y += @item_height
      end
      
      # スクロールバー
      total_height = @filtered_bookmarks.size * @item_height
      if total_height > height
        scrollbar_width = 8
        scrollbar_height = (height * (height.to_f / total_height)).to_i
        scrollbar_max_y = height - scrollbar_height
        scrollbar_y = (scrollbar_max_y * (@scroll_offset.to_f / (total_height - height))).to_i
        
        window.set_draw_color(theme.colors.foreground, 0.2)
        window.fill_rounded_rect(x: x + width - scrollbar_width - 4, y: y + scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
    end
    
    def render_grid_view(window, x, y, width, height, theme)
      if @filtered_bookmarks.empty?
        message = "表示できるブックマークがありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
        return
      end
      
      # グリッドレイアウト
      @grid_columns = (width / @grid_item_size).to_i
      @grid_columns = 1 if @grid_columns < 1
      
      horizontal_spacing = 20
      remaining_width = width - (@grid_columns * @grid_item_size)
      horizontal_margin = remaining_width / (@grid_columns + 1)
      
      current_y = y - @scroll_offset
      row = 0
      
      @filtered_bookmarks.each_with_index do |bookmark, index|
        col = index % @grid_columns
        if col == 0 && index > 0
          row += 1
          current_y += @grid_item_size + 10
        end
        
        is_selected = bookmark.id == @selected_item_id
        item_x = x + horizontal_margin + col * (@grid_item_size + horizontal_spacing)
        
        # アイテム背景
        if is_selected
          window.set_draw_color(theme.colors.accent, 0.3)
          window.fill_rounded_rect(x: item_x - 5, y: current_y - 5, width: @grid_item_size + 10, height: @grid_item_size + 10, radius: 5)
        end
        
        # ファビコン (サイトのアイコン)
        icon_size = 48
        icon_x = item_x + (@grid_item_size - icon_size) / 2
        icon_y = current_y + 10
        
        window.set_draw_color(theme.colors.foreground, 0.8)
        window.fill_rounded_rect(x: icon_x, y: icon_y, width: icon_size, height: icon_size, radius: 5)
        window.set_draw_color(theme.colors.background, 1.0)
        window.draw_text("🌐", x: icon_x + 14, y: icon_y + 12, size: 24, font: theme.font_family)
        
        # タイトル
        title_x = item_x
        title_y = icon_y + icon_size + 10
        title_width = @grid_item_size
        
        title = bookmark.title
        if window.measure_text(title, size: theme.font_size, font: theme.font_family) > title_width
          # タイトルが長すぎる場合は短縮
          while title.size > 3 && window.measure_text("#{title}...", size: theme.font_size, font: theme.font_family) > title_width
            title = title[0..-2]
          end
          title = "#{title}..."
        end
        
        text_width = window.measure_text(title, size: theme.font_size, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 1.0)
        window.draw_text(title, x: title_x + (@grid_item_size - text_width) / 2, y: title_y, size: theme.font_size, font: theme.font_family)
      end
      
      # スクロールバー
      total_rows = (@filtered_bookmarks.size - 1) / @grid_columns + 1
      total_height = total_rows * (@grid_item_size + 10)
      
      if total_height > height
        scrollbar_width = 8
        scrollbar_height = (height * (height.to_f / total_height)).to_i
        scrollbar_max_y = height - scrollbar_height
        scrollbar_y = (scrollbar_max_y * (@scroll_offset.to_f / (total_height - height))).to_i
        
        window.set_draw_color(theme.colors.foreground, 0.2)
        window.fill_rounded_rect(x: x + width - scrollbar_width - 4, y: y + scrollbar_y, width: scrollbar_width, height: scrollbar_height, radius: scrollbar_width / 2)
      end
    end
    
    def render_tags_view(window, x, y, width, height, theme)
      # 左側にタグリスト、右側にブックマークリスト
      tags_width = width * 0.25
      bookmarks_width = width - tags_width
      
      # タグリスト部分
      window.set_draw_color(theme.colors.background_lighter, 1.0)
      window.fill_rect(x: x, y: y, width: tags_width, height: height)
      
      if @tag_list.empty?
        message = "タグがありません"
        message_width = window.measure_text(message, size: theme.font_size, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: x + (tags_width - message_width) / 2, y: y + 50, size: theme.font_size, font: theme.font_family)
      else
        tag_y = y - @scroll_offset
        @tag_list.each do |tag|
          is_selected = tag == @selected_folder
          
          if is_selected
            window.set_draw_color(theme.colors.accent, 0.3)
            window.fill_rect(x: x, y: tag_y, width: tags_width, height: @folder_height)
          end
          
          # タグアイコン
          icon_x = x + 15
          icon_y = tag_y + (@folder_height - theme.font_size) / 2
          window.set_draw_color(theme.colors.foreground, 0.8)
          window.draw_text("🏷️", x: icon_x, y: icon_y, size: theme.font_size, font: theme.font_family)
          
          # タグ名
          tag_name_x = icon_x + 25
          window.set_draw_color(theme.colors.foreground, is_selected ? 1.0 : 0.9)
          window.draw_text(tag, x: tag_name_x, y: icon_y, size: theme.font_size, font: theme.font_family)
          
          tag_y += @folder_height
        end
      end
      
      # 区切り線
      window.set_draw_color(theme.colors.border, 1.0)
      window.draw_line(x1: x + tags_width, y1: y, x2: x + tags_width, y2: y + height)
      
      # ブックマークリスト部分
      bookmarks_x = x + tags_width + 1
      
      if @selected_folder.empty?
        message = "タグを選択してください"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: bookmarks_x + (bookmarks_width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
      elsif @filtered_bookmarks.empty?
        message = "このタグのブックマークはありません"
        message_width = window.measure_text(message, size: theme.font_size + 2, font: theme.font_family)
        window.set_draw_color(theme.colors.foreground, 0.7)
        window.draw_text(message, x: bookmarks_x + (bookmarks_width - message_width) / 2, y: y + height / 2, size: theme.font_size + 2, font: theme.font_family)
      else
        render_bookmarks_list(window, bookmarks_x, y, bookmarks_width, height, theme)
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
      # マウスイベント処理
    end
    
    def handle_key_event(event)
      # キーボードイベント処理
    end
    
    def switch_mode(mode : ViewMode)
      @current_mode = mode
      @scroll_offset = 0
      @selected_item_id = nil
      refresh_data
    end
    
    def add_bookmark(url : String, title : String)
      folder_id = @selected_folder.empty? ? "root" : @selected_folder
      if @bookmark_manager.add_bookmark(url, title, folder_id)
        refresh_data
        return true
      end
      return false
    end
    
    def add_folder(name : String)
      parent_id = @selected_folder.empty? ? "root" : @selected_folder
      if @bookmark_manager.add_folder(name, parent_id)
        refresh_data
        return true
      end
      return false
    end
    
    def delete_selected_item
      if @selected_item_id
        if @bookmark_manager.delete_bookmark(@selected_item_id)
          @selected_item_id = nil
          refresh_data
          return true
        end
      end
      return false
    end
    
    def move_bookmark(bookmark_id : String, new_folder_id : String)
      if @bookmark_manager.move_bookmark(bookmark_id, new_folder_id)
        refresh_data
        return true
      end
      return false
    end
    
    def add_tag_to_bookmark(bookmark_id : String, tag : String)
      if @bookmark_manager.add_tag(bookmark_id, tag)
        if @current_mode == ViewMode::Tags
          refresh_data
        end
        return true
      end
      return false
    end
    
    def remove_tag_from_bookmark(bookmark_id : String, tag : String)
      if @bookmark_manager.remove_tag(bookmark_id, tag)
        if @current_mode == ViewMode::Tags && @selected_folder == tag
          refresh_data
        end
        return true
      end
      return false
    end
  end
end 