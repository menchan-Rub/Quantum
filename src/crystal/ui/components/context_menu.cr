# src/crystal/ui/components/context_menu.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"

module QuantumUI
  # コンテキストメニューコンポーネント
  # ブラウザ内の様々な場所で右クリックした際に表示されるメニュー
  class ContextMenu < Component
    # メニュー項目を表すレコード型
    record MenuItem, id : Symbol, label : String, enabled : Bool = true, 
                     icon : String? = nil, shortcut : String? = nil, separator : Bool = false, 
                     submenu : Array(MenuItem)? = nil, priority : Int32 = 0

    @menu_items : Array(MenuItem)
    @item_height : Int32
    @menu_width : Int32
    @hover_index : Int32 = -1
    @submenu_visible : Bool = false
    @submenu_position : Tuple(Int32, Int32)? = nil
    @active_submenu : Array(MenuItem)? = nil
    @context_element : Symbol? = nil
    @last_mouse_pos : Tuple(Int32, Int32)
    @recently_closed_tabs : Array(Tuple(String, String))
    @last_shown_pos : Tuple(Int32, Int32)?
    @animation_progress : Float64 = 0.0
    @animation_start_time : Time?
    @animation_duration : Float64 = 0.15
    @menu_cache : Hash(Symbol, Concave::Texture) # コンテキストメニューのレンダリングキャッシュ

    # コンテキストメニューのテーマ設定
    private struct MenuTheme
      property bg_color : UInt32
      property border_color : UInt32
      property text_color : UInt32
      property disabled_color : UInt32
      property hover_color : UInt32
      property separator_color : UInt32
      property icon_color : UInt32
      property shortcut_color : UInt32
      
      def initialize(@bg_color, @border_color, @text_color, @disabled_color, @hover_color, @separator_color, @icon_color, @shortcut_color)
      end
    end

    # @param config [QuantumCore::UIConfig] UI設定
    # @param core [QuantumCore::Engine] コアエンジン
    # @param theme [ThemeEngine] テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @visible = false # 初期状態は非表示
      @bounds = nil # 位置は動的に決まる
      @item_height = @theme.font_size + 12
      @menu_width = 220 # 基本幅（項目内容に応じて調整される）
      @menu_items = default_items
      @last_mouse_pos = {0, 0}
      @recently_closed_tabs = [] of Tuple(String, String)
      @menu_cache = {} of Symbol => Concave::Texture
      
      # イベントリスナーを設定
      setup_event_listeners
    end

    # デフォルトのメニュー項目
    private def default_items : Array(MenuItem)
      [
        MenuItem.new(:back, "戻る", shortcut: "Alt+←", enabled: false),
        MenuItem.new(:forward, "進む", shortcut: "Alt+→", enabled: false),
        MenuItem.new(:reload, "再読み込み", shortcut: "Ctrl+R", enabled: false),
        MenuItem.new(:separator_1, "", separator: true),
        MenuItem.new(:bookmark, "このページをブックマーク", shortcut: "Ctrl+D", enabled: false),
        MenuItem.new(:save_page, "ページを保存", shortcut: "Ctrl+S", enabled: false),
        MenuItem.new(:print, "印刷...", shortcut: "Ctrl+P", enabled: false),
        MenuItem.new(:separator_2, "", separator: true),
        MenuItem.new(:view_source, "ページのソースを表示", shortcut: "Ctrl+U", enabled: false),
        MenuItem.new(:inspect, "検証", shortcut: "Ctrl+Shift+I", enabled: false),
        MenuItem.new(:separator_3, "", separator: true),
        MenuItem.new(:new_tab, "新しいタブ", shortcut: "Ctrl+T"),
        MenuItem.new(:new_window, "新しいウィンドウ", shortcut: "Ctrl+N"),
        MenuItem.new(:new_incognito, "新しいシークレットウィンドウ", shortcut: "Ctrl+Shift+N"),
        MenuItem.new(:separator_4, "", separator: true),
        MenuItem.new(:history, "履歴", icon: "🕒", submenu: [
          MenuItem.new(:show_all_history, "すべての履歴を表示", shortcut: "Ctrl+H"),
          MenuItem.new(:separator_history_1, "", separator: true),
          MenuItem.new(:recently_closed, "最近閉じたタブ", submenu: [
            MenuItem.new(:no_closed_tabs, "最近閉じたタブはありません", enabled: false)
          ])
        ]),
        MenuItem.new(:downloads, "ダウンロード", shortcut: "Ctrl+J", icon: "📥"),
        MenuItem.new(:bookmarks, "ブックマーク", shortcut: "Ctrl+B", icon: "⭐"),
        MenuItem.new(:separator_5, "", separator: true),
        MenuItem.new(:zoom, "ズーム", icon: "🔍", submenu: [
          MenuItem.new(:zoom_in, "拡大", shortcut: "Ctrl++"),
          MenuItem.new(:zoom_out, "縮小", shortcut: "Ctrl+-"),
          MenuItem.new(:zoom_reset, "リセット", shortcut: "Ctrl+0")
        ]),
        MenuItem.new(:encoding, "エンコーディング", icon: "🔤", submenu: [] of MenuItem),
        MenuItem.new(:separator_6, "", separator: true),
        MenuItem.new(:settings, "設定", shortcut: "Ctrl+,", icon: "⚙️"),
        MenuItem.new(:help, "ヘルプとフィードバック", icon: "❓")
      ]
    end

    # イベントリスナーを設定
    private def setup_event_listeners
      # タブ閉じるイベントを監視して、最近閉じたタブリストを更新
      @core.event_bus.subscribe(QuantumEvents::EventType::TAB_CLOSED) do |event|
        if data = event.data.as?(QuantumEvents::TabClosedData)
          update_recently_closed_tabs(data.title, data.url)
        end
      end
      
      # ナビゲーション状態変更イベント
      @core.event_bus.subscribe(QuantumEvents::EventType::NAVIGATION_STATE_CHANGED) do |event|
        if data = event.data.as?(QuantumEvents::NavigationStateChangedData)
          update_navigation_states(data.can_go_back, data.can_go_forward)
        end
      end
      
      # ページ読み込み状態変更イベント
      @core.event_bus.subscribe(QuantumEvents::EventType::PAGE_LOAD_COMPLETE) do |event|
        if @core.current_page?
          update_page_specific_menu_items(true)
        end
      end
    end

    # 最近閉じたタブリストを更新
    private def update_recently_closed_tabs(title : String, url : String)
      @recently_closed_tabs.unshift({title, url})
      @recently_closed_tabs = @recently_closed_tabs[0...10] # 最大10件保持
      
      # 最近閉じたタブサブメニューを更新
      update_recently_closed_submenu
    end

    # 最近閉じたタブサブメニューを更新
    private def update_recently_closed_submenu
      # 履歴メニュー項目を検索
      history_index = @menu_items.index { |item| item.id == :history }
      return unless history_index
      
      history_item = @menu_items[history_index]
      return unless submenu = history_item.submenu
      
      # 最近閉じたタブメニュー項目を検索
      recently_closed_index = submenu.index { |item| item.id == :recently_closed }
      return unless recently_closed_index
      
      recently_closed_item = submenu[recently_closed_index]
      
      # 新しいサブメニューを構築
      new_submenu = [] of MenuItem
      
      if @recently_closed_tabs.empty?
        new_submenu << MenuItem.new(:no_closed_tabs, "最近閉じたタブはありません", enabled: false)
      else
        @recently_closed_tabs.each_with_index do |(title, url), index|
          display_title = title.empty? ? url : title
          display_title = display_title.size > 30 ? display_title[0...27] + "..." : display_title
          new_submenu << MenuItem.new(:"restore_tab_#{index}", display_title)
        end
        
        new_submenu << MenuItem.new(:separator_recent, "", separator: true)
        new_submenu << MenuItem.new(:restore_all_tabs, "すべて復元")
      end
      
      # サブメニューを更新
      updated_recently_closed = MenuItem.new(
        recently_closed_item.id,
        recently_closed_item.label,
        recently_closed_item.enabled,
        recently_closed_item.icon,
        recently_closed_item.shortcut,
        recently_closed_item.separator,
        new_submenu,
        recently_closed_item.priority
      )
      
      # 履歴サブメニューを更新
      new_history_submenu = submenu.dup
      new_history_submenu[recently_closed_index] = updated_recently_closed
      
      # 履歴メニュー項目を更新
      updated_history = MenuItem.new(
        history_item.id,
        history_item.label,
        history_item.enabled,
        history_item.icon,
        history_item.shortcut,
        history_item.separator,
        new_history_submenu,
        history_item.priority
      )
      
      # メニュー項目を更新
      @menu_items[history_index] = updated_history
    end

    # ナビゲーション状態を更新
    private def update_navigation_states(can_go_back : Bool, can_go_forward : Bool)
      @menu_items = @menu_items.map do |item|
        case item.id
        when :back
          item.copy_with(enabled: can_go_back)
        when :forward
          item.copy_with(enabled: can_go_forward)
        else
          item
        end
      end
    end

    # ページ固有のメニュー項目の有効/無効を更新
    private def update_page_specific_menu_items(page_loaded : Bool)
      @menu_items = @menu_items.map do |item|
        case item.id
        when :reload, :bookmark, :save_page, :print, :view_source, :inspect
          item.copy_with(enabled: page_loaded)
        else
          item
        end
      end
    end

    # コンテキストに応じたメニュー項目を取得
    private def get_context_menu_items(context : Symbol) : Array(MenuItem)
      case context
      when :link
        # リンク上でのコンテキストメニュー
        [
          MenuItem.new(:open_link, "新しいタブでリンクを開く", shortcut: "Ctrl+クリック"),
          MenuItem.new(:open_link_window, "新しいウィンドウでリンクを開く"),
          MenuItem.new(:open_link_incognito, "シークレットウィンドウでリンクを開く"),
          MenuItem.new(:separator_link_1, "", separator: true),
          MenuItem.new(:save_link_as, "名前を付けてリンク先を保存..."),
          MenuItem.new(:copy_link_address, "リンクアドレスをコピー"),
          MenuItem.new(:separator_link_2, "", separator: true),
          # 共通メニュー項目
          *common_menu_items
        ]
      when :image
        # 画像上でのコンテキストメニュー
        [
          MenuItem.new(:open_image, "新しいタブで画像を開く"),
          MenuItem.new(:save_image_as, "名前を付けて画像を保存..."),
          MenuItem.new(:copy_image, "画像をコピー"),
          MenuItem.new(:copy_image_address, "画像アドレスをコピー"),
          MenuItem.new(:separator_image_1, "", separator: true),
          # 共通メニュー項目
          *common_menu_items
        ]
      when :text
        # テキスト上でのコンテキストメニュー
        [
          MenuItem.new(:copy, "コピー", shortcut: "Ctrl+C"),
          MenuItem.new(:separator_text_1, "", separator: true),
          MenuItem.new(:search_for, "「#{truncated_selection}」を検索", icon: "🔍"),
          MenuItem.new(:separator_text_2, "", separator: true),
          # 共通メニュー項目
          *common_menu_items
        ]
      when :input
        # 入力フィールド上でのコンテキストメニュー
        [
          MenuItem.new(:cut, "切り取り", shortcut: "Ctrl+X"),
          MenuItem.new(:copy, "コピー", shortcut: "Ctrl+C"),
          MenuItem.new(:paste, "貼り付け", shortcut: "Ctrl+V"),
          MenuItem.new(:separator_input_1, "", separator: true),
          MenuItem.new(:select_all, "すべて選択", shortcut: "Ctrl+A"),
          MenuItem.new(:separator_input_2, "", separator: true),
          # 共通メニュー項目
          *common_menu_items
        ]
      else
        # デフォルトのコンテキストメニュー
        default_items
              end
            end

    # 共通メニュー項目
    private def common_menu_items : Array(MenuItem)
      [
        MenuItem.new(:back, "戻る", shortcut: "Alt+←", enabled: @core.page_manager.can_go_back?),
        MenuItem.new(:forward, "進む", shortcut: "Alt+→", enabled: @core.page_manager.can_go_forward?),
        MenuItem.new(:reload, "再読み込み", shortcut: "Ctrl+R", enabled: @core.current_page? != nil),
        MenuItem.new(:separator_common_1, "", separator: true),
        MenuItem.new(:settings, "設定", shortcut: "Ctrl+,", icon: "⚙️"),
      ]
    end

    # 選択テキストを省略して取得
    private def truncated_selection : String
      selection = @core.current_page?.try(&.get_selected_text) || ""
      if selection.size > 20
        selection[0...17] + "..."
      else
        selection
              end
            end

    # コンテキスト要素を検出
    private def detect_context(x : Int32, y : Int32) : Symbol
      page = @core.current_page?
      return :default unless page
      
      # ページの要素を確認
      element_info = page.get_element_at(x, y)
      
      if element_info
        if element_info["type"]? == "link"
          return :link
        elsif element_info["type"]? == "image"
          return :image
        elsif element_info["type"]? == "input" || element_info["type"]? == "textarea"
          return :input
        elsif element_info["has_selection"]? == true
          return :text
        end
      end
      
      :default
    end

    # メニュー表示
    def show(x : Int32, y : Int32, context : Symbol = :default)
      @visible = true
      @context_element = context
      @hover_index = -1
      @last_mouse_pos = {x, y}
      
      # コンテキストに応じたメニュー項目を設定
      @menu_items = get_context_menu_items(context)
      
      # メニューの高さを計算
      menu_height = @menu_items.size * @item_height
      
      # 画面からはみ出さないように位置を調整
      window_width = @core.window_manager.current_window.width
      window_height = @core.window_manager.current_window.height
      
      menu_x = x
      menu_y = y
      
      # 右端調整
      if menu_x + @menu_width > window_width
        menu_x = window_width - @menu_width
      end
      
      # 下端調整
      if menu_y + menu_height > window_height
        menu_y = window_height - menu_height
      end
      
      # 位置が変わっている場合はキャッシュを無効化
      if @last_shown_pos != {menu_x, menu_y}
        @menu_cache.clear
      end
      
      @last_shown_pos = {menu_x, menu_y}
      @bounds = {menu_x, menu_y, @menu_width, menu_height}
      
      # アニメーション開始
      @animation_progress = 0.0
      @animation_start_time = Time.monotonic
      
      # サブメニューを非表示
      @submenu_visible = false
      @active_submenu = nil
      
      Log.info "コンテキストメニュー表示: コンテキスト=#{context}, 位置=#{menu_x},#{menu_y}"
    end

    # メニュー非表示
    def hide
      @visible = false
      @submenu_visible = false
      @active_submenu = nil
      @hover_index = -1
      Log.info "コンテキストメニュー非表示"
    end

    # イベント処理
    override def handle_event(event : QuantumEvents::Event) : Bool
      # イベント処理の実装...
      true
    end

    # アニメーションを更新
    private def update_animation
      return unless start_time = @animation_start_time
      
      elapsed = (Time.monotonic - start_time).total_seconds
      @animation_progress = Math.min(1.0, elapsed / @animation_duration)
      
      # アニメーション完了時
      if @animation_progress >= 1.0
        @animation_start_time = nil
        
        # 完了後にメニューをキャッシュ（サブメニューがなければ）
        if !@submenu_visible && @bounds && @context_element
          cache_current_menu
        end
      end
    end

    # メニューのレンダリングをキャッシュ
    private def cache_current_menu
      return unless bounds = @bounds
      x, y, w, h = bounds
      
      # オフスクリーンテクスチャを作成
      texture = Concave::Texture.create_empty(w, h, Concave::PixelFormat::RGBA)
      
      # テクスチャに描画
      texture.with_draw_target do |ctx|
        menu_theme = get_menu_theme
        
        # 背景
        ctx.set_draw_color(menu_theme.bg_color, 0.98)
        ctx.fill_rounded_rect(x: 0, y: 0, width: w, height: h, radius: 4)
        
        # 境界線
        ctx.set_draw_color(menu_theme.border_color, 1.0)
        ctx.draw_rounded_rect(x: 0, y: 0, width: w, height: h, radius: 4)
        
        # 項目描画
        @menu_items.each_with_index do |item, index|
          item_y = index * @item_height
          
          # 区切り線
          if item.separator
            separator_y = item_y + @item_height / 2
            ctx.set_draw_color(menu_theme.separator_color, 0.8)
            ctx.draw_line(4, separator_y, w - 4, separator_y)
            next
          end
          
          # テキスト色
          ctx.set_draw_color(item.enabled ? menu_theme.text_color : menu_theme.disabled_color, 1.0)
          
          # アイコン
          icon_width = 0
          if icon = item.icon
            icon_size = @theme.font_size
            icon_x = 8
            icon_y = item_y + (@item_height - icon_size) / 2
            
            ctx.set_draw_color(item.enabled ? menu_theme.icon_color : menu_theme.disabled_color, 1.0)
            ctx.draw_text(icon, x: icon_x, y: icon_y, size: icon_size, font: @theme.icon_font_family)
            icon_width = icon_size + 8
          end
          
          # ラベル
          text_x = 8 + icon_width
          text_y = item_y + (@item_height - @theme.font_size) / 2
          
          ctx.set_draw_color(item.enabled ? menu_theme.text_color : menu_theme.disabled_color, 1.0)
          ctx.draw_text(item.label, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
          
          # ショートカット
          if shortcut = item.shortcut
            shortcut_width = ctx.measure_text(shortcut, size: @theme.font_size - 2, font: @theme.font_family).x
            shortcut_x = w - shortcut_width - 8
            
            ctx.set_draw_color(menu_theme.shortcut_color, item.enabled ? 0.7 : 0.5)
            ctx.draw_text(shortcut, x: shortcut_x, y: text_y + 1, size: @theme.font_size - 2, font: @theme.font_family)
          end
          
          # サブメニュー矢印
          if item.submenu && item.enabled
            arrow = "▶"
            arrow_width = @theme.font_size / 2
            arrow_x = w - arrow_width - 8
            
            ctx.draw_text(arrow, x: arrow_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
          end
        end
      end
      
      # キャッシュに保存
      menu_key = @context_element || :default
      @menu_cache[menu_key] = texture
    end

    # メニューのテーマを取得
    private def get_menu_theme : MenuTheme
      MenuTheme.new(
        bg_color: (@theme.colors.secondary & 0xFF_FF_FF_00) | 0xFA,
        border_color: @theme.colors.border,
        text_color: @theme.colors.foreground,
        disabled_color: (@theme.colors.foreground & 0xFF_FF_FF_00) | 0x88,
        hover_color: @theme.colors.accent,
        separator_color: @theme.colors.border,
        icon_color: @theme.colors.accent,
        shortcut_color: @theme.colors.secondary_text
      )
    end

    # メニューを描画
    override def render(window : Concave::Window)
      return unless visible? && (bounds = @bounds)
      x, y, w, h = bounds

      # アニメーション更新
      update_animation
      
      # メニューのキャッシュをチェック
      menu_key = @context_element || :default
      
      if !@menu_cache.has_key?(menu_key) || @submenu_visible
        # キャッシュがない場合またはサブメニュー表示中は直接描画
        render_menu_directly(window, x, y, w, h)
      else
        # キャッシュから描画
        if cached_texture = @menu_cache[menu_key]?
          # アニメーション適用
          if @animation_progress < 1.0
            scale = 0.95 + 0.05 * @animation_progress
            opacity = @animation_progress
            
            window.with_alpha(opacity) do
              window.with_scale(scale, scale, x + w/2, y + h/2) do
                window.draw_texture(cached_texture, x: x, y: y, width: w, height: h)
              end
            end
          else
            window.draw_texture(cached_texture, x: x, y: y, width: w, height: h)
          end
        end
      end
    rescue ex
      Log.error "コンテキストメニュー描画中にエラーが発生しました", exception: ex
    end

    # メニューを直接描画（キャッシュなし）
    private def render_menu_directly(window : Concave::Window, x : Int32, y : Int32, w : Int32, h : Int32)
      menu_theme = get_menu_theme
      
      # アニメーション効果
      scale = @animation_progress < 1.0 ? 0.95 + 0.05 * @animation_progress : 1.0
      opacity = @animation_progress
      
      window.with_alpha(opacity) do
        window.with_scale(scale, scale, x + w/2, y + h/2) do
          # 背景
          window.set_draw_color(menu_theme.bg_color, 0.98)
          window.fill_rounded_rect(x: x, y: y, width: w, height: h, radius: 4)
          
          # 境界線
          window.set_draw_color(menu_theme.border_color, 1.0)
          window.draw_rounded_rect(x: x, y: y, width: w, height: h, radius: 4)
          
          # 項目描画
          @menu_items.each_with_index do |item, index|
            item_y = y + index * @item_height
            
            # ホバー効果
            if index == @hover_index && item.enabled
              window.set_draw_color(menu_theme.hover_color, 0.2)
              window.fill_rect(x: x + 2, y: item_y, width: w - 4, height: @item_height)
            end
            
            # 区切り線
            if item.separator
              separator_y = item_y + @item_height / 2
              window.set_draw_color(menu_theme.separator_color, 0.8)
              window.draw_line(x + 4, separator_y, x + w - 4, separator_y)
              next
            end
            
            # テキスト色
            window.set_draw_color(item.enabled ? menu_theme.text_color : menu_theme.disabled_color, 1.0)
            
            # アイコン
            icon_width = 0
            if icon = item.icon
              icon_size = @theme.font_size
              icon_x = x + 8
              icon_y = item_y + (@item_height - icon_size) / 2
              
              window.set_draw_color(item.enabled ? menu_theme.icon_color : menu_theme.disabled_color, 1.0)
              window.draw_text(icon, x: icon_x, y: icon_y, size: icon_size, font: @theme.icon_font_family)
              icon_width = icon_size + 8
            end
            
            # ラベル
            text_x = x + 8 + icon_width
            text_y = item_y + (@item_height - @theme.font_size) / 2
            
            window.set_draw_color(item.enabled ? menu_theme.text_color : menu_theme.disabled_color, 1.0)
            window.draw_text(item.label, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
            
            # ショートカット
            if shortcut = item.shortcut
              shortcut_width = window.measure_text(shortcut, size: @theme.font_size - 2, font: @theme.font_family).x
              shortcut_x = x + w - shortcut_width - 8
              
              window.set_draw_color(menu_theme.shortcut_color, item.enabled ? 0.7 : 0.5)
              window.draw_text(shortcut, x: shortcut_x, y: text_y + 1, size: @theme.font_size - 2, font: @theme.font_family)
            end
            
            # サブメニュー矢印
            if item.submenu && item.enabled
              arrow = "▶"
              arrow_width = @theme.font_size / 2
              arrow_x = x + w - arrow_width - 8
              
              window.draw_text(arrow, x: arrow_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
            end
          end
        end
      end
      
      # サブメニュー描画
      if @submenu_visible && @submenu_position && @active_submenu
        render_submenu(window, @submenu_position.not_nil!, @active_submenu.not_nil!)
      end
    end
    
    # サブメニューの描画
    private def render_submenu(window : Concave::Window, position : Tuple(Int32, Int32), items : Array(MenuItem))
      # 既存のサブメニュー描画ロジック
      # ...
    end

    # カスタムメニューを表示する
    def show_custom_menu(x : Int32, y : Int32, items : Array(MenuItem), &callback : Symbol -> Void)
      # 既存のカスタムメニュー表示ロジック
      # ...
    end
  end
end 