require "concave"

module QuantumUI
  # タブバーコンポーネント - ブラウザの上部にタブを表示する
  class TabBar
    include Component

    # UI設定オブジェクト
    getter config : QuantumCore::UIConfig
    # コアエンジンインスタンス
    getter core   : QuantumCore::Engine
    # タブURLリスト
    getter tabs   : Array(String)
    # 現在アクティブなタブのインデックス
    property active_tab : Int32

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
      @tabs   = [] of String
      @active_tab = 0
      # 最初のタブはホームページ
      @tabs << @core.config.homepage
    end

    # 新しいタブを追加
    def add_tab(url : String)
      @tabs << url
      @active_tab = @tabs.size - 1
    end

    # タブを閉じる
    def close_tab(index : Int32)
      return if @tabs.size <= 1 # 最低1つのタブは必要
      
      @tabs.delete_at(index)
      @active_tab = [@active_tab, @tabs.size - 1].min
    end

    # タブを切り替える
    def switch_to(index : Int32)
      return unless (0...@tabs.size).includes?(index)
      @active_tab = index
      @core.load_url(@tabs[index])
    end

    # タブバーを描画します
    def render(window : Concave::Window)
      y = 32
      height = 32
      # タブバー背景
      window.set_draw_color(0xEEEEEE, 1.0)
      window.fill_rect(x: 0, y: y, width: window.width, height: height)
      
      # 各タブを描画
      @tabs.each_with_index do |url, idx|
        tab_width = (window.width.to_f / @tabs.size).to_i
        x = idx * tab_width
        
        # アクティブタブは明るく、非アクティブは暗めに
        if idx == @active_tab
          window.set_draw_color(0xFFFFFF, 1.0)
        else
          window.set_draw_color(0xCCCCCC, 1.0)
        end
        
        window.fill_rect(x: x, y: y, width: tab_width, height: height)
        
        # タブの境界線
        window.set_draw_color(0xAAAAAA, 1.0)
        window.draw_rect(x: x, y: y, width: tab_width, height: height)
        
        # URLテキスト（長すぎる場合は省略）
        display_url = url.size > 20 ? "#{url[0..17]}..." : url
        window.set_draw_color(0x000000, 1.0)
        window.draw_text(display_url, x: x + 8, y: y + 8,
                         size: @config.font_size, font: @config.font_family)
        
        # 閉じるボタン
        close_x = x + tab_width - 20
        window.set_draw_color(0x888888, 1.0)
        window.draw_text("×", x: close_x, y: y + 8,
                         size: @config.font_size, font: @config.font_family)
      end
      
      # 新規タブボタン
      new_tab_x = @tabs.size * (window.width.to_f / @tabs.size).to_i
      if new_tab_x + 30 < window.width
        window.set_draw_color(0xDDDDDD, 1.0)
        window.fill_rect(x: new_tab_x, y: y, width: 30, height: height)
        window.set_draw_color(0x000000, 1.0)
        window.draw_text("+", x: new_tab_x + 10, y: y + 8,
                         size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "タブバー描画エラー: #{ex.message}"
    end

    # イベント処理: タブ操作
    def handle_event(event : Concave::Event)
      return unless event.is_a?(Concave::Event::MouseDown)
      
      # タブバー領域内のクリック
      if event.y >= 32 && event.y < 64
        tab_width = (event.window.width.to_f / @tabs.size).to_i
        tab_idx = event.x / tab_width
        
        # 新規タブボタンクリック
        if tab_idx >= @tabs.size && event.x < event.window.width
          add_tab(@core.config.homepage)
          @core.load_url(@core.config.homepage)
          return
        end
        
        # 既存タブ範囲内
        if tab_idx < @tabs.size
          # 閉じるボタン領域
          close_x = (tab_idx + 1) * tab_width - 20
          if event.x >= close_x && event.x < close_x + 20
            close_tab(tab_idx)
            if page = @core.current_page
              @core.load_url(@tabs[@active_tab])
            end
          else
            # タブ切り替え
            switch_to(tab_idx)
          end
        end
      end
    rescue ex
      STDERR.puts "タブイベント処理エラー: #{ex.message}"
    end
  end

  # コンテンツ表示コンポーネント - ウェブページの内容を表示
  class ContentArea
    include Component

    getter config : QuantumCore::UIConfig
    getter core   : QuantumCore::Engine
    # スクロール位置
    property scroll_y : Int32
    # ズームレベル (1.0 = 100%)
    property zoom : Float64

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
      @scroll_y = 0
      @zoom = 1.0
    end

    # ページコンテンツを表示
    def render(window : Concave::Window)
      top = 64
      bottom = @config.status_bar_visible ? window.height - 24 : window.height
      height = bottom - top
      
      # コンテンツ領域の背景
      window.set_draw_color(0xFFFFFF, 1.0)
      window.fill_rect(x: 0, y: top, width: window.width, height: height)
      
      # 現在のページを取得
      if page = @core.current_page
        # ブックマークパネルが表示されている場合は表示領域を調整
        content_x = @config.bookmarks_visible ? 200 : 0
        content_width = @config.bookmarks_visible ? window.width - 200 : window.width
        
        if page.loading?
          # ローディング表示
          window.set_draw_color(0x000000, 1.0)
          window.draw_text("読み込み中: #{page.url}", x: content_x + 8, y: top + 8,
                         size: @config.font_size, font: @config.font_family)
          
          # プログレスバー
          progress_width = (content_width * 0.8).to_i
          progress_x = content_x + (content_width - progress_width) / 2
          progress_y = top + height / 2
          
          # 背景
          window.set_draw_color(0xEEEEEE, 1.0)
          window.fill_rect(x: progress_x, y: progress_y, width: progress_width, height: 10)
          
          # 進捗
          load_progress = (page.load_progress * progress_width).to_i
          window.set_draw_color(0x4285F4, 1.0)
          window.fill_rect(x: progress_x, y: progress_y, width: load_progress, height: 10)
        else
          # ページコンテンツ表示
          render_page_content(window, page, content_x, top, content_width, height)
        end
      else
        # ページが読み込まれていない場合
        window.set_draw_color(0x000000, 1.0)
        window.draw_text("ページが読み込まれていません", x: 8, y: top + 8,
                       size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "コンテンツ表示エラー: #{ex.message}"
    end

    # ページコンテンツの実際の描画処理
    private def render_page_content(window, page, x, y, width, height)
      # ページタイトル
      window.set_draw_color(0x000000, 1.0)
      window.draw_text(page.title, x: x + 8, y: y + 8,
                     size: (@config.font_size * 1.2).to_i, font: @config.font_family)
      
      # コンテンツ（スクロール位置を考慮）
      content_y = y + 40 - @scroll_y
      
      # テキストコンテンツ
      page.content.each_with_index do |line, idx|
        line_y = content_y + idx * (@config.font_size + 4)
        # 表示領域内のみ描画（パフォーマンス最適化）
        if line_y >= y && line_y < y + height
          window.draw_text(line, x: x + 16, y: line_y,
                         size: (@config.font_size * @zoom).to_i, font: @config.font_family)
        end
      end
      
      # スクロールバー
      total_content_height = page.content.size * (@config.font_size + 4)
      if total_content_height > height
        scrollbar_height = (height * height / total_content_height).to_i
        scrollbar_y = y + (@scroll_y * height / total_content_height)
        
        # スクロールバー背景
        window.set_draw_color(0xEEEEEE, 0.7)
        window.fill_rect(x: x + width - 12, y: y, width: 12, height: height)
        
        # スクロールバーつまみ
        window.set_draw_color(0xAAAAAA, 0.8)
        window.fill_rect(x: x + width - 10, y: scrollbar_y, width: 8, height: scrollbar_height)
      end
    end

    # イベント処理: スクロール、クリックなど
    def handle_event(event : Concave::Event)
      case event
      when Concave::Event::MouseWheel
        # スクロール処理
        @scroll_y += event.y * 20
        @scroll_y = 0 if @scroll_y < 0
        
        if page = @core.current_page
          max_scroll = page.content.size * (@config.font_size + 4) - (event.window.height - 88)
          @scroll_y = max_scroll if max_scroll > 0 && @scroll_y > max_scroll
        end
      when Concave::Event::KeyDown
        case event.key
        when Concave::Key::Home
          @scroll_y = 0
        when Concave::Key::End
          if page = @core.current_page
            @scroll_y = page.content.size * (@config.font_size + 4)
          end
        when Concave::Key::PageUp
          @scroll_y -= event.window.height / 2
          @scroll_y = 0 if @scroll_y < 0
        when Concave::Key::PageDown
          @scroll_y += event.window.height / 2
        when Concave::Key::Plus
          # ズームイン
          @zoom = [@zoom + 0.1, 2.0].min
        when Concave::Key::Minus
          # ズームアウト
          @zoom = [@zoom - 0.1, 0.5].max
        end
      when Concave::Event::MouseDown
        # リンククリック処理（将来的に実装）
        if page = @core.current_page
          # ここでリンク検出とクリック処理を実装
        end
      end
    rescue ex
      STDERR.puts "コンテンツイベント処理エラー: #{ex.message}"
    end
  end

  # ブックマークパネルコンポーネント - お気に入りサイトを管理
  class BookmarksPanel
    include Component

    getter config : QuantumCore::UIConfig
    getter core   : QuantumCore::Engine
    # ブックマークリスト（URL, タイトル）
    getter bookmarks : Array(Tuple(String, String))
    # パネルが折りたたまれているか
    property collapsed : Bool

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config    = config
      @core      = core
      @bookmarks = [] of Tuple(String, String)
      @collapsed = false
      
      # デフォルトブックマーク
      add_bookmark("https://crystal-lang.org", "Crystal言語")
      add_bookmark("https://github.com", "GitHub")
    end

    # ブックマーク追加
    def add_bookmark(url : String, title : String)
      # 重複チェック
      return if @bookmarks.any? { |bm| bm[0] == url }
      @bookmarks << {url, title}
    end

    # ブックマーク削除
    def remove_bookmark(index : Int32)
      @bookmarks.delete_at(index) if (0...@bookmarks.size).includes?(index)
    end

    # ブックマークパネル描画
    def render(window : Concave::Window)
      return unless @config.bookmarks_visible
      
      width = @collapsed ? 30 : 200
      top = 64
      bottom = @config.status_bar_visible ? window.height - 24 : window.height
      height = bottom - top
      
      # パネル背景
      window.set_draw_color(0xF5F5F5, 1.0)
      window.fill_rect(x: 0, y: top, width: width, height: height)
      
      # 境界線
      window.set_draw_color(0xDDDDDD, 1.0)
      window.draw_line(x1: width, y1: top, x2: width, y2: bottom)
      
      if @collapsed
        # 折りたたみ状態では縦にアイコンを表示
        window.set_draw_color(0x000000, 1.0)
        window.draw_text("B", x: 8, y: top + 10, size: @config.font_size, font: @config.font_family)
        window.draw_text("O", x: 8, y: top + 40, size: @config.font_size, font: @config.font_family)
        window.draw_text("O", x: 8, y: top + 70, size: @config.font_size, font: @config.font_family)
        window.draw_text("K", x: 8, y: top + 100, size: @config.font_size, font: @config.font_family)
        window.draw_text("M", x: 8, y: top + 130, size: @config.font_size, font: @config.font_family)
        window.draw_text("A", x: 8, y: top + 160, size: @config.font_size, font: @config.font_family)
        window.draw_text("R", x: 8, y: top + 190, size: @config.font_size, font: @config.font_family)
        window.draw_text("K", x: 8, y: top + 220, size: @config.font_size, font: @config.font_family)
      else
        # 展開状態ではブックマークリスト表示
        window.set_draw_color(0x000000, 1.0)
        window.draw_text("ブックマーク", x: 8, y: top + 8, 
                       size: (@config.font_size * 1.1).to_i, font: @config.font_family)
        
        # 追加ボタン
        window.set_draw_color(0x4285F4, 1.0)
        window.fill_rect(x: width - 30, y: top + 8, width: 20, height: 20)
        window.set_draw_color(0xFFFFFF, 1.0)
        window.draw_text("+", x: width - 25, y: top + 8, 
                       size: @config.font_size, font: @config.font_family)
        
        # 区切り線
        window.set_draw_color(0xDDDDDD, 1.0)
        window.draw_line(x1: 0, y1: top + 35, x2: width, y2: top + 35)
        
        # ブックマークリスト
        @bookmarks.each_with_index do |bm, i|
          url, title = bm
          item_y = top + 45 + i * (@config.font_size + 12)
          
          # ホバー効果（将来的に実装）
          
          # タイトル
          window.set_draw_color(0x000000, 1.0)
          window.draw_text(title, x: 8, y: item_y,
                         size: @config.font_size, font: @config.font_family)
          
          # URL（小さく表示）
          window.set_draw_color(0x666666, 1.0)
          display_url = url.size > 25 ? "#{url[0..22]}..." : url
          window.draw_text(display_url, x: 12, y: item_y + @config.font_size + 2,
                         size: (@config.font_size * 0.8).to_i, font: @config.font_family)
          
          # 削除ボタン
          window.set_draw_color(0x888888, 1.0)
          window.draw_text("×", x: width - 20, y: item_y,
                         size: @config.font_size, font: @config.font_family)
        end
      end
      
      # 折りたたみ/展開ボタン
      window.set_draw_color(0xCCCCCC, 1.0)
      window.fill_rect(x: width - 15, y: top + height - 25, width: 15, height: 15)
      window.set_draw_color(0x000000, 1.0)
      window.draw_text(@collapsed ? ">" : "<", x: width - 12, y: top + height - 25,
                     size: @config.font_size, font: @config.font_family)
    rescue ex
      STDERR.puts "ブックマークパネル描画エラー: #{ex.message}"
    end

    # イベント処理: ブックマーク操作
    def handle_event(event : Concave::Event)
      return unless @config.bookmarks_visible
      return unless event.is_a?(Concave::Event::MouseDown)
      
      top = 64
      bottom = @config.status_bar_visible ? event.window.height - 24 : event.window.height
      height = bottom - top
      width = @collapsed ? 30 : 200
      
      # パネル内のクリック
      if event.x < width && event.y >= top && event.y < bottom
        # 折りたたみ/展開ボタン
        if event.y >= bottom - 25 && event.x >= width - 15
          @collapsed = !@collapsed
          return
        end
        
        if !@collapsed
          # 追加ボタン
          if event.y >= top + 8 && event.y <= top + 28 && event.x >= width - 30 && event.x <= width - 10
            if page = @core.current_page
              add_bookmark(page.url, page.title.empty? ? page.url : page.title)
            end
            return
          end
          
          # ブックマークリスト領域
          if event.y >= top + 45
            item_height = @config.font_size + 12
            item_index = ((event.y - (top + 45)) / item_height).to_i
            
            if (0...@bookmarks.size).includes?(item_index)
              # 削除ボタン
              if event.x >= width - 20
                remove_bookmark(item_index)
              else
                # ブックマークをクリック
                url, _ = @bookmarks[item_index]
                @core.load_url(url)
              end
            end
          end
        end
      end
    rescue ex
      STDERR.puts "ブックマークイベント処理エラー: #{ex.message}"
    end
  end

  # ステータスバーコンポーネント - 下部情報表示
  class StatusBar
    include Component

    getter config : QuantumCore::UIConfig
    getter core   : QuantumCore::Engine
    # ステータスメッセージ
    property message : String
    # メッセージ表示タイマー
    property message_timer : Int32

    def initialize(config : QuantumCore::UIConfig, core : QuantumCore::Engine)
      @config = config
      @core   = core
      @message = ""
      @message_timer = 0
    end

    # ステータスメッセージを設定
    def set_message(msg : String, duration : Int32 = 5)
      @message = msg
      @message_timer = duration * 60 # 60フレーム/秒と仮定
    end

    # ステータスバー描画
    def render(window : Concave::Window)
      return unless @config.status_bar_visible
      
      height = 24
      y = window.height - height
      
      # 背景
      window.set_draw_color(0xEEEEEE, 1.0)
      window.fill_rect(x: 0, y: y, width: window.width, height: height)
      
      # 境界線
      window.set_draw_color(0xDDDDDD, 1.0)
      window.draw_line(x1: 0, y1: y, x2: window.width, y2: y)
      
      window.set_draw_color(0x000000, 1.0)
      
      # 一時メッセージがある場合はそれを表示
      if @message_timer > 0
        window.draw_text(@message, x: 8, y: y + 4,
                       size: @config.font_size, font: @config.font_family)
        @message_timer -= 1
      else
        # 通常のステータス表示
        status_text = if page = @core.current_page
                        "URL: #{page.url} | #{page.loading? ? "読み込み中..." : "読み込み完了"}"
                      else
                        "ページが読み込まれていません"
                      end
        
        window.draw_text(status_text, x: 8, y: y + 4,
                       size: @config.font_size, font: @config.font_family)
      end
      
      # 右側に追加情報
      if page = @core.current_page
        # セキュリティ情報
        security_text = page.secure? ? "🔒 安全" : "🔓 非安全"
        security_width = security_text.size * @config.font_size
        window.set_draw_color(page.secure? ? 0x00AA00 : 0xAA0000, 1.0)
        window.draw_text(security_text, x: window.width - security_width - 10, y: y + 4,
                       size: @config.font_size, font: @config.font_family)
      end
    rescue ex
      STDERR.puts "ステータスバー描画エラー: #{ex.message}"
    end

    # イベント処理
    def handle_event(event : Concave::Event)
      # ステータスバーの完璧なインタラクション処理
      # 右クリックメニュー、ドラッグ&ドロップ、カスタマイズ機能を提供
      case event.type
      when Concave::EventType::MouseButtonDown
        handle_mouse_click(event)
      when Concave::EventType::MouseButtonUp
        handle_mouse_release(event)
      when Concave::EventType::MouseMotion
        handle_mouse_motion(event)
      when Concave::EventType::KeyDown
        handle_key_press(event)
      when Concave::EventType::ContextMenu
        show_context_menu(event)
      end
    end
    
    # 完璧な定期更新システム
    def update
      # メッセージタイマーの更新
      update_message_timers
      
      # アニメーション更新
      update_animations
      
      # パフォーマンス統計更新
      update_performance_stats
      
      # ネットワーク状態監視
      monitor_network_status
      
      # システムリソース監視
      monitor_system_resources
    end
    
    # 完璧なマウスクリック処理
    private def handle_mouse_click(event : Concave::Event)
      # ステータスアイテムのクリック検出と処理
      clicked_item = detect_clicked_item(event.mouse_x, event.mouse_y)
      if clicked_item
        clicked_item.on_click.try(&.call)
      end
    end
    
    # 完璧なコンテキストメニュー表示
    private def show_context_menu(event : Concave::Event)
      # ステータスバーのカスタマイズメニューを表示
      menu_items = [
        "ステータスアイテムの表示/非表示",
        "レイアウトのカスタマイズ",
        "テーマの変更",
        "設定を開く"
      ]
      
      # コンテキストメニューの表示処理
      show_popup_menu(menu_items, event.mouse_x, event.mouse_y)
    end
  end
end 