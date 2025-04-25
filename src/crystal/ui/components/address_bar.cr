# src/crystal/ui/components/address_bar.cr
require "concave"
require "uri"
require "../component"
require "../theme_engine"
require "../../quantum_core/engine"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"
require "../../storage/history"
require "../../security/site_security"

module QuantumUI
  # アドレスバーコンポーネント - ウェブアドレス入力、ナビゲーション、セキュリティ状態表示
  class AddressBar < Component
    # セキュリティ状態を表す列挙型
    enum SecurityStatus
      Unknown     # 不明
      Insecure    # 安全でない
      Secure      # 安全
      EV          # 拡張検証済み
      MixedContent # 混合コンテンツ
      InternalPage # 内部ページ
      FileSystem   # ファイルシステム
    end

    # サジェスト項目を表す構造体
    private struct Suggestion
      property type : Symbol  # :history, :bookmark, :search, :url_completion
      property title : String
      property url : String
      property icon : Concave::Texture?
      property score : Float64  # 関連性スコア
      property highlighted_ranges : Array(Range(Int32, Int32))? # ハイライト範囲

      def initialize(@type, @title, @url, @icon = nil, @score = 0.0, @highlighted_ranges = nil)
      end
    end

    @text : String
    @placeholder : String
    @suggestions : Array(Suggestion)
    @security_status : SecurityStatus
    @history_service : QuantumCore::Storage::HistoryService
    @security_service : QuantumCore::Security::SiteSecurityService
    @bookmark_service : QuantumCore::Storage::BookmarkService
    @cursor_position : Int32
    @selection_start : Int32
    @selection_end : Int32
    @has_selection : Bool
    @suggestion_visible : Bool
    @max_suggestions : Int32
    @icons : Hash(Symbol, Concave::Texture?)
    @last_mouse_x : Int32?
    @last_mouse_y : Int32?
    @selected_suggestion_index : Int32
    @url_parser : QuantumCore::Security::URLParser
    @animation_frame : Int32
    @animation_timer : Time
    @last_key_input_time : Time
    @render_cache : Hash(String, Concave::Texture) # レンダリングキャッシュ
    @suggestion_cache : Hash(String, Array(Suggestion)) # サジェストキャッシュ
    @performance_metrics : Hash(Symbol, Float64) # パフォーマンス計測用

    # @param config [QuantumCore::UIConfig] UI設定
    # @param core [QuantumCore::Engine] コアエンジン
    # @param theme [ThemeEngine] テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @core : QuantumCore::Engine, @theme : ThemeEngine)
      @text = ""
      @placeholder = "URLを入力するか検索..."
      @suggestions = [] of Suggestion
      @security_status = SecurityStatus::Unknown
      @history_service = QuantumCore::Storage::HistoryService.instance
      @security_service = QuantumCore::Security::SiteSecurityService.instance
      @bookmark_service = QuantumCore::Storage::BookmarkService.instance
      @cursor_position = 0
      @selection_start = 0
      @selection_end = 0
      @has_selection = false
      @suggestion_visible = false
      @max_suggestions = 8
      @icons = load_icons
      @last_mouse_x = nil
      @last_mouse_y = nil
      @selected_suggestion_index = -1
      @url_parser = QuantumCore::Security::URLParser.new
      @animation_frame = 0
      @animation_timer = Time.monotonic
      @last_key_input_time = Time.monotonic
      @render_cache = {} of String => Concave::Texture
      @suggestion_cache = {} of String => Array(Suggestion)
      @performance_metrics = {} of Symbol => Float64

      # イベントリスナーのセットアップ
      setup_event_listeners
    end

    # アイコンを読み込む
    private def load_icons
      {
        secure: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/secure.png"),
        insecure: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/insecure.png"),
        ev: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/ev_secure.png"),
        unknown: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/unknown.png"),
        mixed_content: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/mixed_content.png"),
        internal: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/internal.png"),
        file: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/file.png"),
        reload: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/reload.png"),
        search: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/search.png"),
        history: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/history.png"),
        bookmark: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/bookmark.png"),
        star: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/star.png"),
        star_filled: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/star_filled.png"),
        clear: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/clear.png"),
        copy: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/copy.png"),
        paste: Concave::Texture.from_file("#{@config.assets_path}/icons/ui/paste.png")
      }
    rescue ex
      Log.error "アイコン読み込み失敗", exception: ex
      {} of Symbol => Concave::Texture?
    end

    # アドレスバーを描画する
    override def render(window : Concave::Window)
      return unless bounds = @bounds # レイアウト未確定 or 非表示なら描画しない
      
      start_time = Time.monotonic
      
      # キャッシュ用のキーを生成
      cache_key = "#{@text}_#{@security_status}_#{focused?}_#{@suggestion_visible}"
      
      # キャッシュがあればそれを使用
      if @render_cache.has_key?(cache_key) && !@suggestion_visible
        window.draw_texture(@render_cache[cache_key], x: bounds[0], y: bounds[1])
        
        # パフォーマンス計測（キャッシュヒット時）
        end_time = Time.monotonic
        @performance_metrics[:cached_render_time] = (end_time - start_time).total_milliseconds
        return
      end
      
      # 以下、通常の描画処理
      x, y, w, h = bounds

      # キャッシュなしの場合は新規描画
      if !@suggestion_visible # サジェスト表示中はキャッシュしない
        texture = Concave::Texture.create_empty(w, h, Concave::PixelFormat::RGBA)
        texture.with_draw_target do |ctx|
          render_address_bar(ctx, 0, 0, w, h)
        end
        
        # キャッシュに保存
        @render_cache[cache_key] = texture
        
        # キャッシュが大きくなりすぎないようにする
        if @render_cache.size > 20
          old_keys = @render_cache.keys.sort_by { |k| @render_cache[k].width * @render_cache[k].height }[0...10]
          old_keys.each { |k| @render_cache.delete(k) }
        end
        
        window.draw_texture(texture, x: x, y: y)
      else
        # 直接描画
        render_address_bar(window, x, y, w, h)
      end
      
      # サジェストリストの描画
      render_suggestions(window) if @suggestion_visible && !@suggestions.empty?
      
      # パフォーマンス計測（キャッシュミス時）
      end_time = Time.monotonic
      @performance_metrics[:uncached_render_time] = (end_time - start_time).total_milliseconds
    rescue ex
      Log.error "アドレスバー描画失敗", exception: ex
    end

    # アドレスバー本体の描画（キャッシュ対応）
    private def render_address_bar(ctx, x, y, w, h)
      # 背景
      bg_color = focused? ? @theme.colors.input_active : @theme.colors.secondary
      ctx.set_draw_color(bg_color, 1.0)
      ctx.fill_rounded_rect(x: x, y: y, width: w, height: h, radius: 4)
      
      # 角丸の境界線
      border_radius = 4
      border_color = focused? ? @theme.colors.accent : @theme.colors.border
      ctx.set_draw_color(border_color, 1.0)
      ctx.draw_rounded_rect(x: x, y: y, width: w, height: h, radius: border_radius)

      # セキュリティアイコンの描画
      icon_size = h - 16
      icon_x = x + 8
      icon_y = y + (h - icon_size) / 2
      
      if icon = get_security_icon
        ctx.draw_texture(icon, x: icon_x, y: icon_y, width: icon_size, height: icon_size)
      end

      # URLプロトコル部分の特別な表示
      text_x = icon_x + icon_size + 8
      text_width = w - icon_size - 78 # リロードとブックマークとクリアボタン用のスペースを確保
      text_y = y + (h - @theme.font_size) / 2
      
      if @text.empty? && !focused?
        # プレースホルダー表示
        ctx.set_draw_color(@theme.colors.placeholder, 0.7)
        ctx.draw_text(@placeholder, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
      else
        # URLプロトコル部分を識別して異なるスタイルで表示
        if !focused? && !@text.empty?
          # URLを解析してパーツに分割
          url_parts = parse_url_parts(@text)
          
          if url_parts[:scheme]?
            current_x = text_x
            
            # スキーム部分
            scheme_text = url_parts[:scheme]
            scheme_width = text_width_to(scheme_text)
            ctx.set_draw_color(@theme.colors.secondary_text, 0.8)
            ctx.draw_text(scheme_text, x: current_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
            current_x += scheme_width
            
            # セパレータ
            if url_parts[:separator]?
              separator_text = url_parts[:separator]
              separator_width = text_width_to(separator_text)
              ctx.set_draw_color(@theme.colors.secondary_text, 0.8)
              ctx.draw_text(separator_text, x: current_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
              current_x += separator_width
            end
            
            # ドメイン（強調表示）
            if url_parts[:domain]?
              domain_text = url_parts[:domain]
              domain_width = text_width_to(domain_text)
              ctx.set_draw_color(@theme.colors.foreground, 1.0)
              ctx.draw_text(domain_text, x: current_x, y: text_y, size: @theme.font_size, font: @theme.font_family, bold: true)
              current_x += domain_width
            end
            
            # パス部分
            if url_parts[:path]?
              path_text = url_parts[:path]
              ctx.set_draw_color(@theme.colors.foreground, 0.9)
              ctx.draw_text(path_text, x: current_x, y: text_y, size: @theme.font_size, font: @theme.font_family)
            end
          else
            # パース不能の場合は通常表示
            ctx.set_draw_color(@theme.colors.foreground, 1.0)
            ctx.draw_text(@text, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family, max_width: text_width)
          end
        else
          # フォーカス時（編集モード）
          
        # 選択範囲の描画
        if @has_selection && focused?
          selection_start_x = text_x + text_width_to(@text[0...@selection_start])
          selection_width = text_width_to(@text[@selection_start...@selection_end])
            ctx.set_draw_color(@theme.colors.selection, 0.5)
            ctx.fill_rect(x: selection_start_x, y: text_y, width: selection_width, height: @theme.font_size)
        end
        
        # テキスト描画
          ctx.set_draw_color(@theme.colors.foreground, 1.0)
          ctx.draw_text(@text, x: text_x, y: text_y, size: @theme.font_size, font: @theme.font_family, max_width: text_width)
        
        # カーソル描画（フォーカス時のみ）
          if focused? && !@has_selection
            # アニメーション
            blink = (Time.monotonic - @animation_timer).total_milliseconds / 500 % 2 < 1
            if blink
          cursor_x = text_x + text_width_to(@text[0...@cursor_position])
              ctx.set_draw_color(@theme.colors.foreground, 1.0)
              ctx.fill_rect(x: cursor_x, y: text_y, width: 2, height: @theme.font_size)
            end
          end
        end
      end

      # クリアボタンの描画（テキスト入力時のみ）
      if focused? && !@text.empty?
        clear_btn_size = icon_size - 4
        clear_btn_x = x + w - clear_btn_size - 65
        clear_btn_y = y + (h - clear_btn_size) / 2
        
        if @icons[:clear]?
          ctx.draw_texture(@icons[:clear], x: clear_btn_x, y: clear_btn_y, width: clear_btn_size, height: clear_btn_size)
        end
      end

      # ブックマークボタンの描画
      bookmark_x = x + w - icon_size - 35
      is_bookmarked = @security_service.is_bookmarked?(get_normalized_url)
      bookmark_icon = is_bookmarked ? @icons[:star_filled] : @icons[:star]
      
      if bookmark_icon
        ctx.draw_texture(bookmark_icon, x: bookmark_x, y: icon_y, width: icon_size, height: icon_size)
      end

      # リロードボタンの描画（右端）
      reload_x = x + w - icon_size - 8
      if @icons[:reload]?
        ctx.draw_texture(@icons[:reload], x: reload_x, y: icon_y, width: icon_size, height: icon_size)
      end
    end

    # URLをパースして表示用のパーツに分ける
    private def parse_url_parts(url : String) : Hash(Symbol, String)
      result = {} of Symbol => String
      
      # プロトコル部分とそれ以降に分ける
      if protocol_match = url.match(/^([a-z]+:\/\/)(.+)/)
        result[:scheme] = protocol_match[1]
        remaining = protocol_match[2]
        
        # ドメインとパスを分ける
        if domain_match = remaining.match(/^([^\/]+)(\/.*)/)
          result[:domain] = domain_match[1]
          result[:path] = domain_match[2]
        else
          # パスがない場合
          result[:domain] = remaining
        end
      elsif url.starts_with?("about:") || url.starts_with?("chrome:") || url.starts_with?("quantum:")
        # 内部スキームの場合
        if scheme_match = url.match(/^([a-z]+:)(.+)/)
          result[:scheme] = scheme_match[1]
          result[:separator] = ""
          result[:domain] = scheme_match[2]
        end
      else
        # 特殊形式のURLではない場合
        result[:domain] = url
      end
      
      result
    end

    # URLを正規化する（URLパーシング用）
    private def get_normalized_url : String
      return @text if @text.empty?
      
      # URLスキームを含むかチェック
      if @text.includes?("://") || @text.starts_with?("about:") || @text.starts_with?("quantum:")
        return @text
      end
      
      # ローカルファイルパスっぽいかチェック
      if @text.starts_with?("/") || @text.includes?(":\\") || @text.includes?(":/")
        return "file://#{@text}"
      end
      
      # IPアドレスっぽいかチェック
      if @text.matches?(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?$/)
        return "http://#{@text}"
      end
      
      # ドメイン名っぽいかチェック (例: example.com, sub.example.co.jp)
      if @text.matches?(/^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+/)
        return "http://#{@text}"
      end
      
      # 検索クエリと判断
      search_url = @config.search_url.gsub("%s", URI.encode_www_form(@text))
      return search_url
    end

    # サジェストリストを描画
    private def render_suggestions(window : Concave::Window)
      return unless bounds = @bounds
      x, y, w, _ = bounds
      
      suggestion_height = @theme.font_size * 2 + 16
      total_height = Math.min(@suggestions.size, @max_suggestions) * suggestion_height
      
      # サジェストボックスの背景
      suggest_y = y + bounds[3]
      window.set_draw_color(@theme.colors.dropdown_bg, 0.95)
      window.fill_rounded_rect(x: x, y: suggest_y, width: w, height: total_height, radius: 4)
      
      # 境界線
      window.set_draw_color(@theme.colors.border, 1.0)
      window.draw_rounded_rect(x: x, y: suggest_y, width: w, height: total_height, radius: 4)
      
      # 各サジェスト項目の描画
      @suggestions.each_with_index do |suggestion, index|
        break if index >= @max_suggestions
        
        item_y = suggest_y + index * suggestion_height
        
        # 選択状態またはホバー効果
        is_selected = index == @selected_suggestion_index
        is_hovered = mouse_over_suggestion?(index)
        
        if is_selected || is_hovered
          highlight_color = is_selected ? @theme.colors.accent : @theme.colors.hover
          alpha = is_selected ? 0.3 : 0.2
          window.set_draw_color(highlight_color, alpha)
          window.fill_rect(x: x + 2, y: item_y, width: w - 4, height: suggestion_height)
        end
        
        # アイコン描画
        icon_size = suggestion_height - 16
        icon_x = x + 12
        icon_y = item_y + 8
        
        icon = case suggestion.type
               when :history
                 @icons[:history]?
               when :bookmark
                 @icons[:bookmark]?
               when :search
                 @icons[:search]?
               when :url_completion
                 get_favicon_for_url(suggestion.url)
               else
                 suggestion.icon
               end
        
        if icon
          window.draw_texture(icon, x: icon_x, y: icon_y, width: icon_size, height: icon_size)
        end
        
        # タイトルとURL描画
        text_x = icon_x + icon_size + 12
        title_y = item_y + 8
        url_y = title_y + @theme.font_size + 4
        
        # タイトル（太字）
        window.set_draw_color(@theme.colors.foreground, 1.0)
        
        # ハイライト付きテキスト描画
        if highlight_ranges = suggestion.highlighted_ranges
          draw_highlighted_text(window, suggestion.title, highlight_ranges, text_x, title_y, @theme.font_size, true)
        else
        window.draw_text(suggestion.title, x: text_x, y: title_y, size: @theme.font_size, font: @theme.font_family, bold: true)
        end
        
        # URL（小さく、薄く）
        window.set_draw_color(@theme.colors.secondary_text, 0.8)
        window.draw_text(suggestion.url, x: text_x, y: url_y, size: @theme.font_size - 2, font: @theme.font_family)
      end
    end

    # ハイライト付きテキストを描画する
    private def draw_highlighted_text(ctx, text : String, highlight_ranges : Array(Range(Int32, Int32)), x : Int32, y : Int32, size : Int32, bold : Bool = false)
      current_x = x
      last_end = 0
      
      # 各ハイライト範囲を処理
      highlight_ranges.sort_by(&.begin).each do |range|
        # ハイライト前のテキスト
        if range.begin > last_end
          normal_text = text[last_end...range.begin]
          width = ctx.measure_text(normal_text, size: size, font: @theme.font_family, bold: bold).x
          ctx.set_draw_color(@theme.colors.foreground, 1.0)
          ctx.draw_text(normal_text, x: current_x, y: y, size: size, font: @theme.font_family, bold: bold)
          current_x += width
        end
        
        # ハイライト部分
        highlight_text = text[range]
        width = ctx.measure_text(highlight_text, size: size, font: @theme.font_family, bold: true).x
        
        # ハイライト背景
        ctx.set_draw_color(@theme.colors.accent, 0.2)
        ctx.fill_rect(x: current_x, y: y, width: width, height: size)
        
        # ハイライトテキスト
        ctx.set_draw_color(@theme.colors.accent, 1.0)
        ctx.draw_text(highlight_text, x: current_x, y: y, size: size, font: @theme.font_family, bold: true)
        
        current_x += width
        last_end = range.end
      end
      
      # 残りのテキスト
      if last_end < text.size
        normal_text = text[last_end..-1]
        ctx.set_draw_color(@theme.colors.foreground, 1.0)
        ctx.draw_text(normal_text, x: current_x, y: y, size: size, font: @theme.font_family, bold: bold)
      end
    end

    # マウスがサジェスト項目の上にあるかチェック
    private def mouse_over_suggestion?(index : Int32) : Bool
      return false unless mouse_x = @last_mouse_x
      return false unless mouse_y = @last_mouse_y
      return false unless bounds = @bounds
      
      x, y, w, _ = bounds
      suggestion_height = @theme.font_size * 2 + 16
      suggest_y = y + bounds[3]
      item_y = suggest_y + index * suggestion_height
      
      mouse_x >= x && mouse_x <= x + w &&
        mouse_y >= item_y && mouse_y <= item_y + suggestion_height
    end

    # セキュリティステータスに応じたアイコンを取得
    private def get_security_icon : Concave::Texture?
      case @security_status
      when SecurityStatus::Secure
        @icons[:secure]?
      when SecurityStatus::Insecure
        @icons[:insecure]?
      when SecurityStatus::EV
        @icons[:ev]?
      when SecurityStatus::MixedContent
        @icons[:mixed_content]?
      when SecurityStatus::InternalPage
        @icons[:internal]?
      when SecurityStatus::FileSystem
        @icons[:file]?
      else
        @icons[:unknown]?
      end
    end

    # URLのプロトコルとドメインを解析して適切なセキュリティステータスを設定
    def update_security_status(url : String)
      return if url.empty?
      
      begin
        parsed_url = URI.parse(url)
        
        case parsed_url.scheme
        when "https"
          cert_info = @security_service.get_certificate_info(url)
          
          if cert_info.nil?
            @security_status = SecurityStatus::Unknown
          elsif cert_info.is_ev?
            @security_status = SecurityStatus::EV
          elsif cert_info.is_valid?
            if @security_service.has_mixed_content?(url)
              @security_status = SecurityStatus::MixedContent
            else
              @security_status = SecurityStatus::Secure
            end
          else
            @security_status = SecurityStatus::Insecure
          end
        when "http"
          @security_status = SecurityStatus::Insecure
        when "file"
          @security_status = SecurityStatus::FileSystem
        when "about", "quantum", "chrome", "edge", "firefox"
          @security_status = SecurityStatus::InternalPage
        else
          @security_status = SecurityStatus::Unknown
        end
      rescue e
        Log.warn "URL解析エラー: #{e.message}"
        @security_status = SecurityStatus::Unknown
      end
      
      # セキュリティステータスが変わったらレンダリングキャッシュをクリア
      @render_cache.clear
    end

    # 入力テキストが変更されたときにサジェストを更新
    private def update_suggestions
      @suggestions = generate_suggestions(@text)
      @suggestion_visible = !@suggestions.empty?
      @selected_suggestion_index = -1
    end

    # テキスト入力処理
    def handle_text_input(text : String)
      # テキストが変更された場合は選択を解除
      @has_selection = false
      
      # カーソル位置にテキストを挿入
      if @has_selection
        # 選択範囲を置き換え
        @text = @text[0...@selection_start] + text + @text[@selection_end..-1]
        @cursor_position = @selection_start + text.size
        @has_selection = false
      else
        # 通常挿入
        @text = @text[0...@cursor_position] + text + @text[@cursor_position..-1]
        @cursor_position += text.size
      end
      
      # 入力時間を記録（タイピング検出用）
      @last_key_input_time = Time.monotonic
      
      # 更新後に新しいサジェストを生成（ただし入力が停止してから少し待つ）
      if @text.size >= 2 || @text.empty?
        update_suggestions
      end
      
      # レンダリングキャッシュをクリア
      @render_cache.clear
    end

    # キー入力処理
    def handle_key_input(key : QuantumEvents::KeyCode, modifiers : QuantumEvents::KeyModifiers) : Bool
      # アニメーションタイマーをリセット（カーソル点滅用）
      @animation_timer = Time.monotonic
      
      # 修飾キーのチェック
      ctrl_pressed = modifiers.ctrl?
      shift_pressed = modifiers.shift?
      
      # カット・コピー・ペースト処理
      if ctrl_pressed
        case key
        when .v? # ペースト
          if clipboard_text = @core.get_clipboard_text
            handle_text_input(clipboard_text)
          end
            return true
        when .c? # コピー
          if @has_selection
            @core.set_clipboard_text(@text[@selection_start...@selection_end])
          end
          return true
        when .x? # カット
          if @has_selection
            @core.set_clipboard_text(@text[@selection_start...@selection_end])
            handle_text_input("")
          end
          return true
        when .a? # 全選択
          @selection_start = 0
          @selection_end = @text.size
          @has_selection = @text.size > 0
          @render_cache.clear
          return true
        end
      end
      
      # サジェスト選択の処理
      if @suggestion_visible
        case key
        when .down?
          @selected_suggestion_index = (@selected_suggestion_index + 1) % Math.min(@suggestions.size, @max_suggestions)
          return true
        when .up?
          @selected_suggestion_index = (@selected_suggestion_index - 1) % Math.min(@suggestions.size, @max_suggestions)
          @selected_suggestion_index += Math.min(@suggestions.size, @max_suggestions) if @selected_suggestion_index < 0
          return true
        when .enter?
          if @selected_suggestion_index >= 0 && @selected_suggestion_index < @suggestions.size
            apply_suggestion(@suggestions[@selected_suggestion_index])
            return true
          end
        when .escape?
          # サジェストを閉じる
          @suggestion_visible = false
              return true
            end
          end
      
      # その他の特殊キー処理
        case key
      when .enter?
        # URLの確定
        navigate_to_current_url
          return true
      when .escape?
        # フォーカス解除
        blur
        return true
      when .backspace?
        # バックスペース処理
          if @has_selection
          # 選択範囲を削除
          @text = @text[0...@selection_start] + @text[@selection_end..-1]
          @cursor_position = @selection_start
          @has_selection = false
          elsif @cursor_position > 0
          # 1文字削除
          @text = @text[0...(@cursor_position - 1)] + @text[@cursor_position..-1]
            @cursor_position -= 1
          end
        
        # サジェスト更新
          update_suggestions
        @render_cache.clear
          return true
      when .delete?
        # Delete処理
          if @has_selection
          # 選択範囲を削除
          @text = @text[0...@selection_start] + @text[@selection_end..-1]
          @cursor_position = @selection_start
          @has_selection = false
          elsif @cursor_position < @text.size
          # 1文字削除
          @text = @text[0...@cursor_position] + @text[(@cursor_position + 1)..-1]
          end
        
        # サジェスト更新
          update_suggestions
        @render_cache.clear
          return true
      when .left?
        # 左方向カーソル移動
        if shift_pressed
          # 選択範囲を変更
          if !@has_selection
              @selection_start = @cursor_position
            @selection_end = @cursor_position
          end
          
          if @cursor_position > 0
            @cursor_position -= 1
            @selection_start = @cursor_position
          end
          
          @has_selection = @selection_start != @selection_end
        else
          # 通常移動
          if @has_selection
            # 選択範囲がある場合は左端へ
            @cursor_position = @selection_start
            @has_selection = false
          elsif @cursor_position > 0
            @cursor_position -= 1
          end
        end
        
        @render_cache.clear
          return true
      when .right?
        # 右方向カーソル移動
        if shift_pressed
          # 選択範囲を変更
          if !@has_selection
              @selection_start = @cursor_position
            @selection_end = @cursor_position
            end
          
          if @cursor_position < @text.size
            @cursor_position += 1
            @selection_end = @cursor_position
          end
          
          @has_selection = @selection_start != @selection_end
        else
          # 通常移動
          if @has_selection
            # 選択範囲がある場合は右端へ
            @cursor_position = @selection_end
            @has_selection = false
          elsif @cursor_position < @text.size
            @cursor_position += 1
          end
        end
        
        @render_cache.clear
          return true
      when .home?
        # Home処理（先頭へ）
        if shift_pressed
          if !@has_selection
              @selection_start = @cursor_position
            @selection_end = @cursor_position
            end
          
            @cursor_position = 0
          @selection_start = 0
          @has_selection = @selection_start != @selection_end
          else
            @cursor_position = 0
            @has_selection = false
          end
        
        @render_cache.clear
          return true
      when .end?
        # End処理（末尾へ）
        if shift_pressed
          if !@has_selection
              @selection_start = @cursor_position
            @selection_end = @cursor_position
            end
          
            @cursor_position = @text.size
          @selection_end = @text.size
          @has_selection = @selection_start != @selection_end
          else
            @cursor_position = @text.size
            @has_selection = false
          end
        
        @render_cache.clear
            return true
          end
      
      # レンダリングキャッシュをクリア
      @render_cache.clear
      
      false
    end

    # サジェストを適用
    private def apply_suggestion(suggestion : Suggestion)
      # URLを設定
      @text = suggestion.url
            @cursor_position = @text.size
      @has_selection = false
      
      # サジェストリストを閉じる
      @suggestion_visible = false
      
      # ナビゲーション実行
      navigate_to_current_url
      
      # レンダリングキャッシュをクリア
      @render_cache.clear
    end

    # インテリジェントサジェスト生成
    private def generate_suggestions(query : String) : Array(Suggestion)
      # 短時間に連続入力している場合はサジェスト生成を遅延
      elapsed_since_input = (Time.monotonic - @last_key_input_time).total_milliseconds
      if elapsed_since_input < 200 && !query.empty? && query.size >= 2
        return @suggestions # 前回の結果を継続利用
      end
      
      # キャッシュをチェック
      if @suggestion_cache.has_key?(query)
        return @suggestion_cache[query]
      end
      
      result = [] of Suggestion
      
      # 空文字列の場合は履歴からよく訪れるサイトを表示
      if query.empty?
        top_sites = @history_service.get_top_sites(5)
        top_sites.each do |site|
          result << Suggestion.new(
            type: :history,
            title: site.title,
            url: site.url,
            icon: get_favicon_for_url(site.url),
            score: site.visit_count / 100.0
          )
        end
        
        @suggestion_cache[query] = result
        return result
      end
      
      # 検索文字列の正規化
      normalized_query = query.downcase.strip
      
      # 履歴から候補を検索
      history_items = @history_service.search(normalized_query, limit: 10)
      history_items.each do |item|
        # 検索文字列との関連度に基づいてスコア計算
        title_score = calculate_relevance(item.title, normalized_query)
        url_score = calculate_relevance(item.url, normalized_query)
        score = Math.max(title_score, url_score) * (0.7 + 0.3 * (item.visit_count / 100.0))
        
        # ハイライト範囲を計算
        title_ranges = find_match_ranges(item.title, normalized_query)
        
        result << Suggestion.new(
          type: :history,
          title: item.title,
          url: item.url,
          icon: get_favicon_for_url(item.url),
          score: score,
          highlighted_ranges: title_ranges
        )
      end
      
      # ブックマークから候補を検索
      bookmarks = @bookmark_service.search(normalized_query, limit: 5)
      bookmarks.each do |bookmark|
        title_score = calculate_relevance(bookmark.title, normalized_query)
        url_score = calculate_relevance(bookmark.url, normalized_query)
        score = Math.max(title_score, url_score) * 1.2 # ブックマークは少し優先度を上げる
        
        # ハイライト範囲を計算
        title_ranges = find_match_ranges(bookmark.title, normalized_query)
        
        result << Suggestion.new(
          type: :bookmark,
          title: bookmark.title,
          url: bookmark.url,
          icon: get_favicon_for_url(bookmark.url),
          score: score,
          highlighted_ranges: title_ranges
        )
      end
      
      # URL補完候補（example.comの入力で https://example.com/ を提案）
      if normalized_query.includes?(".") && !normalized_query.includes?(" ")
        url_completion = get_normalized_url
        result << Suggestion.new(
          type: :url_completion,
          title: "#{url_completion} にアクセス",
          url: url_completion,
          icon: get_favicon_for_url(url_completion),
          score: 1.5 # URL補完を最優先
        )
      end
      
      # 検索エンジン候補
      search_title = "「#{normalized_query}」を検索"
      search_url = @config.search_url.gsub("%s", URI.encode_www_form(normalized_query))
      result << Suggestion.new(
        type: :search,
        title: search_title,
        url: search_url,
        icon: @icons[:search],
        score: 1.3 # URL補完の次に検索を優先
      )
      
      # スコアで降順ソート
      result.sort_by! { |s| -s.score }
      
      # 上位8件を返す
      result = result[0...@max_suggestions]
      
      # キャッシュに保存（キャッシュサイズの制限）
      @suggestion_cache[query] = result
      if @suggestion_cache.size > 20
        oldest_queries = @suggestion_cache.keys.sort_by { |k| k.size }[0...5]
        oldest_queries.each { |k| @suggestion_cache.delete(k) }
      end
      
      result
    end

    # テキスト内での検索語のマッチ位置を検出する
    private def find_match_ranges(text : String, query : String) : Array(Range(Int32, Int32))
      result = [] of Range(Int32, Int32)
      text_lower = text.downcase
      
      # 完全一致を確認
      if start_pos = text_lower.index(query)
        result << (start_pos...(start_pos + query.size))
        return result
      end
      
      # 単語ごとに分割して部分一致を確認
      query_words = query.split(/\s+/)
      query_words.each do |word|
        next if word.size < 2 # 1文字の単語はスキップ
        
        pos = 0
        while (start_pos = text_lower.index(word, pos))
          result << (start_pos...(start_pos + word.size))
          pos = start_pos + word.size
        end
      end
      
      result
    end

    # 検索語との関連度を計算
    private def calculate_relevance(text : String, query : String) : Float64
      text_lower = text.downcase
      
      # 完全一致なら最高スコア
      return 1.0 if text_lower == query
      
      # 前方一致なら高スコア
      return 0.9 if text_lower.starts_with?(query)
      
      # 部分一致なら中スコア
      return 0.7 if text_lower.includes?(query)
      
      # 単語ごとに部分一致を確認
      query_words = query.split(/\s+/)
      matched_words = 0
      
      query_words.each do |word|
        matched_words += 1 if text_lower.includes?(word)
      end
      
      # 単語の一致率に基づくスコア
      if query_words.size > 0
        return 0.5 * (matched_words.to_f / query_words.size)
      end
      
      # マッチしない場合は低スコア
      return 0.1
    end

    # URLドメインに対応するファビコンを取得
    private def get_favicon_for_url(url : String) : Concave::Texture?
      begin
        parsed_url = URI.parse(url)
        domain = parsed_url.host.to_s
        
        # ファビコンキャッシュから取得（実際の実装ではファビコンキャッシュサービスを利用）
        favicon_path = @core.get_favicon_path(domain)
        
        if favicon_path && File.exists?(favicon_path)
          return Concave::Texture.from_file(favicon_path)
        end
    rescue ex
        Log.warn "ファビコン取得エラー: #{ex.message}"
      end
      
      # デフォルトアイコンを返す
      @icons[:unknown]?
    end

    # ナビゲーション実行
    private def navigate_to_current_url
      # 実際のナビゲーション実装
    end

    # イベントリスナーをセットアップ
    private def setup_event_listeners
      # ページロード完了イベント
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::PAGE_LOAD_COMPLETE) do |event|
        if url = event.data["url"]?.as?(String)
          if @core.current_page? && !focused?
            @text = url
            update_security_status(url)
            @render_cache.clear
          end
        end
      end
      
      # セキュリティ状態更新イベント
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::SECURITY_STATUS_CHANGED) do |event|
        if url = event.data["url"]?.as?(String)
          if @text == url
            update_security_status(url)
            @render_cache.clear
          end
        end
      end
      
      # タブアクティベーションイベント
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::TAB_ACTIVATED) do |event|
        if tab = event.data["tab"]?
          if tab_url = tab.as?(QuantumCore::Tab).url
            @text = tab_url
            update_security_status(tab_url)
            @render_cache.clear
          end
        end
      end
      
      # クリップボード変更イベント（URL検出のため）
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::CLIPBOARD_CHANGED) do |event|
        if text = event.data["text"]?.as?(String)
          # URLっぽい文字列がコピーされた場合に特別処理（オプション機能）
          if @config.detect_url_in_clipboard && !focused? && url_like?(text)
            @core.show_notification("URLがクリップボードにコピーされました", "貼り付けて開く：#{text}", 3000, "clipboard_url")
          end
        end
      end
      
      # 検索エンジン変更イベント
      QuantumEvents::EventDispatcher.instance.subscribe(QuantumEvents::EventType::SEARCH_ENGINE_CHANGED) do |event|
        # サジェストキャッシュをクリア（検索URL変更の反映のため）
        @suggestion_cache.clear
      end
    end

    # イベントを処理する
    override def handle_event(event : QuantumEvents::Event) : Bool
      case event.type
      when QuantumEvents::EventType::MOUSE_DOWN
        if event.mouse_button == QuantumEvents::MouseButton::LEFT
          if bounds = @bounds
            x, y, w, h = bounds
            
            if event.mouse_x.between?(x, x + w) && event.mouse_y.between?(y, y + h)
              # アドレスバー内でのクリック
              
              # クリアボタンのクリック
              if focused? && !@text.empty?
                clear_btn_size = (h - 16) - 4
                clear_btn_x = x + w - clear_btn_size - 65
                clear_btn_y = y + (h - clear_btn_size) / 2
                
                if event.mouse_x.between?(clear_btn_x, clear_btn_x + clear_btn_size) &&
                   event.mouse_y.between?(clear_btn_y, clear_btn_y + clear_btn_size)
                  # テキストをクリア
                  @text = ""
                  @cursor_position = 0
      @has_selection = false
                  update_suggestions
                  @render_cache.clear
                  return true
                end
              end
              
              # リロードボタンのクリック
              reload_size = h - 16
              reload_x = x + w - reload_size - 8
              reload_y = y + (h - reload_size) / 2
              
              if event.mouse_x.between?(reload_x, reload_x + reload_size) &&
                 event.mouse_y.between?(reload_y, reload_y + reload_size)
                reload_current_page
                return true
              end
              
              # ブックマークボタンのクリック
              bookmark_size = h - 16
              bookmark_x = x + w - bookmark_size - 35
              bookmark_y = y + (h - bookmark_size) / 2
              
              if event.mouse_x.between?(bookmark_x, bookmark_x + bookmark_size) &&
                 event.mouse_y.between?(bookmark_y, bookmark_y + bookmark_size)
                toggle_bookmark
                return true
              end
              
              # フォーカス取得とカーソル位置設定
              if !focused?
                focus
              end
              
              # テキスト領域内のクリック位置にカーソルを設定
              text_x = x + (h - 16) + 16
              if event.mouse_x >= text_x
                relative_x = event.mouse_x - text_x
                @cursor_position = get_cursor_position_at(relative_x)
                @has_selection = false
                @render_cache.clear
              end
              
              return true
            end
          end
          
          # サジェスト項目のクリック処理
          if @suggestion_visible
            @suggestions.each_with_index do |suggestion, index|
              if mouse_over_suggestion?(index)
                apply_suggestion(suggestion)
                return true
              end
            end
          end
        elsif event.mouse_button == QuantumEvents::MouseButton::RIGHT
          # 右クリックメニュー表示
          if bounds = @bounds
            x, y, w, h = bounds
            
            if event.mouse_x.between?(x, x + w) && event.mouse_y.between?(y, y + h)
              show_context_menu(event.mouse_x, event.mouse_y)
              return true
            end
          end
        end
        
      when QuantumEvents::EventType::MOUSE_MOVE
        # マウス位置を記録（サジェストのホバー検出用）
        @last_mouse_x = event.mouse_x
        @last_mouse_y = event.mouse_y
        
        # サジェストアイテム上でのホバーを検出
        if @suggestion_visible
          @suggestions.each_with_index do |_, index|
            if mouse_over_suggestion?(index)
              if @selected_suggestion_index != index
                @selected_suggestion_index = index
                return true
              end
            end
          end
        end
        
      when QuantumEvents::EventType::MOUSE_UP
        # ドラッグによるテキスト選択の終了処理
        if @drag_selecting && bounds = @bounds
          x, y, w, h = bounds
          
          if event.mouse_x.between?(x, x + w) && event.mouse_y.between?(y, y + h)
            # 選択範囲の終了位置
            text_x = x + (h - 16) + 16
            if event.mouse_x >= text_x
              relative_x = event.mouse_x - text_x
              @selection_end = get_cursor_position_at(relative_x)
              
              # 選択開始位置と終了位置を順序付け
              if @selection_start > @selection_end
                @selection_start, @selection_end = @selection_end, @selection_start
              end
              
              @has_selection = @selection_start != @selection_end
              @cursor_position = @selection_end
              @render_cache.clear
            end
          end
          
          @drag_selecting = false
          return true
        end
        
      when QuantumEvents::EventType::MOUSE_DRAG
        # テキスト選択
        if focused? && bounds = @bounds
          x, y, w, h = bounds
          
          if event.mouse_x.between?(x, x + w) && event.mouse_y.between?(y, y + h)
            # 選択開始（最初のドラッグ）
            if !@drag_selecting
              text_x = x + (h - 16) + 16
              if event.mouse_x >= text_x
                relative_x = event.mouse_x - text_x
                @selection_start = get_cursor_position_at(relative_x)
                @drag_selecting = true
              end
            end
            
            # 選択範囲の更新
            text_x = x + (h - 16) + 16
            if event.mouse_x >= text_x
              relative_x = event.mouse_x - text_x
              @selection_end = get_cursor_position_at(relative_x)
              @has_selection = @selection_start != @selection_end
              @cursor_position = @selection_end
              @render_cache.clear
            end
            
            return true
          end
        end
        
      when QuantumEvents::EventType::KEY_DOWN
        # キー入力
        if focused?
          return handle_key_input(event.key_code, event.key_modifiers)
        end
        
      when QuantumEvents::EventType::TEXT_INPUT
        # テキスト入力
        if focused?
          handle_text_input(event.text)
          return true
        end
        
      when QuantumEvents::EventType::FOCUS_GAINED
        # フォーカス獲得時
        select_all_text if @config.select_all_on_focus
        @render_cache.clear
        return true
        
      when QuantumEvents::EventType::FOCUS_LOST
        # フォーカス喪失時
      @has_selection = false
      @suggestion_visible = false
        @render_cache.clear
        return true
      end
      
      false
    end

    # マウス座標からカーソル位置を計算
    private def get_cursor_position_at(x : Int32) : Int32
      return 0 if @text.empty?
      
      # 各文字の幅を考慮してカーソル位置を計算
      total_width = 0
      @text.size.times do |i|
        char_width = text_width_to(@text[i].to_s)
        if total_width + (char_width / 2) >= x
          return i
        end
        total_width += char_width
      end
      
      @text.size
    end

    # テキストの幅を計算（ピクセル単位）
    private def text_width_to(text : String) : Int32
      # サイズが変わらないよう固定フォントを想定
      text.size * (@theme.font_size / 2)
    end

    # テキスト全選択
    private def select_all_text
      @selection_start = 0
      @selection_end = @text.size
      @has_selection = @text.size > 0
      @cursor_position = @text.size
    end

    # コンテキストメニューを表示
    private def show_context_menu(x : Int32, y : Int32)
      menu_items = [] of ContextMenu::MenuItem
      
      # クリップボード操作
      if @has_selection
        menu_items << ContextMenu::MenuItem.new(id: :cut, label: "切り取り", shortcut: "Ctrl+X")
        menu_items << ContextMenu::MenuItem.new(id: :copy, label: "コピー", shortcut: "Ctrl+C")
      end
      
      if @core.has_clipboard_text?
        menu_items << ContextMenu::MenuItem.new(id: :paste, label: "貼り付け", shortcut: "Ctrl+V")
      end
      
      menu_items << ContextMenu::MenuItem.new(id: :separator1, label: "", separator: true)
      menu_items << ContextMenu::MenuItem.new(id: :select_all, label: "すべて選択", shortcut: "Ctrl+A")
      
      # アドレスバー特有のオプション
      menu_items << ContextMenu::MenuItem.new(id: :separator2, label: "", separator: true)
      
      if !@text.empty?
        menu_items << ContextMenu::MenuItem.new(id: :copy_url, label: "URLをコピー")
      end
      
      if @security_service.is_bookmarked?(get_normalized_url)
        menu_items << ContextMenu::MenuItem.new(id: :remove_bookmark, label: "ブックマークを削除")
      else
        menu_items << ContextMenu::MenuItem.new(id: :add_bookmark, label: "ブックマークに追加", shortcut: "Ctrl+D")
      end
      
      # メニューを表示
      context_menu = @core.get_component(ComponentType::CONTEXT_MENU)
      if context_menu.is_a?(ContextMenu)
        context_menu.show_custom_menu(x, y, menu_items) do |item_id|
          case item_id
          when :cut
            if @has_selection
              @core.set_clipboard_text(@text[@selection_start...@selection_end])
              handle_text_input("")
            end
          when :copy
            if @has_selection
              @core.set_clipboard_text(@text[@selection_start...@selection_end])
            end
          when :paste
            if clipboard_text = @core.get_clipboard_text
              handle_text_input(clipboard_text)
            end
          when :select_all
            select_all_text
            @render_cache.clear
          when :copy_url
            @core.set_clipboard_text(get_normalized_url)
          when :add_bookmark
            add_bookmark
          when :remove_bookmark
            remove_bookmark
          end
        end
      end
    end

    # URLを判定
    private def url_like?(text : String) : Bool
      text = text.strip
      
      # URLスキーム
      return true if text.matches?(/^[a-z]+:\/\//)
      
      # ドメイン名（.を含む）
      return true if text.includes?(".") && text.matches?(/^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+/)
      
      false
    end

    # ブックマークの追加/削除を切り替え
    private def toggle_bookmark
      current_url = get_normalized_url
      
      if @security_service.is_bookmarked?(current_url)
        remove_bookmark
      else
        add_bookmark
      end
    end

    # ブックマークを追加
    private def add_bookmark
      current_url = get_normalized_url
      current_title = @core.current_page_title || current_url
      
      @security_service.add_bookmark(current_url, current_title)
      @render_cache.clear
      
      # 通知
      @core.show_notification("ブックマークに追加しました", current_title, 2000)
    end

    # ブックマークを削除
    private def remove_bookmark
      current_url = get_normalized_url
      
      @security_service.remove_bookmark(current_url)
      @render_cache.clear
      
      # 通知
      @core.show_notification("ブックマークを削除しました", "", 2000)
    end

    # ページを再読み込み
    private def reload_current_page
      @core.reload_current_page
    end

    # パフォーマンスメトリクスを取得
    def get_performance_metrics : Hash(Symbol, Float64)
      @performance_metrics
    end

    # アクセシビリティサポート - スクリーンリーダー用のテキスト取得
    def get_accessibility_text : String
      case @security_status
      when SecurityStatus::Secure
        "安全な接続：#{@text}"
      when SecurityStatus::Insecure
        "安全でない接続：#{@text}"
      when SecurityStatus::EV
        "拡張検証済み接続：#{@text}"
      when SecurityStatus::MixedContent
        "混合コンテンツ：#{@text}"
      when SecurityStatus::InternalPage
        "内部ページ：#{@text}"
      when SecurityStatus::FileSystem
        "ファイルシステム：#{@text}"
      else
        "アドレスバー：#{@text}"
      end
    end
  end
end