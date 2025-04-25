# src/crystal/ui/components/network_status_overlay.cr
require "concave"
require "../component"
require "../theme_engine"
require "../../quantum_core/network"
require "../../quantum_core/config"
require "../../events/**"
require "../../utils/logger"

module QuantumUI
  # ネットワークステータス表示オーバーレイコンポーネント
  class NetworkStatusOverlay < Component
    # 表示モード設定
    enum DisplayMode
      MINIMAL   # 最小限表示（基本情報のみ）
      STANDARD  # 標準表示（基本 + 統計情報）
      DETAILED  # 詳細表示（全情報）
    end
    
    @stats_text : String
    @last_update : Time
    @render_cache : Concave::Texture? # レンダリングキャッシュ
    @cache_needs_update : Bool = true # キャッシュ更新フラグ
    @display_mode : DisplayMode = DisplayMode::STANDARD
    @connection_status : Symbol = :unknown # :connected, :disconnected, :slow, :unstable
    @update_interval : Float64 = 1.0 # 更新間隔（秒）
    @performance_metrics : Hash(Symbol, Float64) = {} # パフォーマンス測定用
    @last_network_check : Time # 最終ネットワークチェック時間

    # @param config [QuantumCore::UIConfig] UI設定 (テーマ用)
    # @param network_manager [QuantumNetwork::Manager] ネットワークマネージャ
    # @param theme [ThemeEngine] テーマエンジン
    def initialize(@config : QuantumCore::UIConfig, @network_manager : QuantumNetwork::Manager, @theme : ThemeEngine)
      @visible = false # デフォルトは非表示 (デバッグ用)
      @stats_text = "ネットワーク: 初期化中..."
      @last_update = Time.monotonic
      @last_network_check = Time.monotonic
      setup_event_listeners
    end

    # オーバーレイを描画する
    override def render(window : Concave::Window)
      return unless visible? && (bounds = @bounds)
      x, y, w, h = bounds
      
      render_start_time = Time.monotonic
      
      # キャッシュが有効で更新不要ならキャッシュから描画
      if !@cache_needs_update && (cache = @render_cache)
        window.draw_texture(cache, x: x, y: y)
        
        # パフォーマンス測定（キャッシュヒット）
        @performance_metrics[:render_time_cached] = (Time.monotonic - render_start_time).total_seconds * 1000
        return
      end
      
      # 新規描画（キャッシュ作成）
      texture = Concave::Texture.create_empty(w, h, Concave::PixelFormat::RGBA)
      texture.with_draw_target do |ctx|
        # 背景グラデーション
        draw_background(ctx, w, h)
        
        # ボーダー
        ctx.set_draw_color(0x44_44_44, 0.8)
        ctx.draw_rect(x: 0, y: 0, width: w, height: h)
        
        # 接続ステータスアイコン
        draw_status_icon(ctx, 8, 4, @connection_status)
        
        # テキスト描画
        line_height = @theme.font_size
        ctx.set_draw_color(0xFF_FF_FF, 1.0)
        
        # 基本情報（常に表示）
        ctx.draw_text(@stats_text, x: 30, y: 6, size: @theme.font_size - 2, font: @theme.font_family)
        
        # 詳細モードの場合は追加情報表示
        if @display_mode == DisplayMode::DETAILED
          # 詳細統計情報
          detailed_stats = get_detailed_stats
          y_offset = line_height + 6
          
          detailed_stats.each do |line|
            ctx.draw_text(line, x: 8, y: y_offset, size: @theme.font_size - 2, font: @theme.font_family)
            y_offset += line_height
          end
        end
      end
      
      # キャッシュを保存
      @render_cache = texture
      @cache_needs_update = false
      
      # 画面に描画
      window.draw_texture(texture, x: x, y: y)
      
      # パフォーマンス測定（キャッシュミス）
      @performance_metrics[:render_time_uncached] = (Time.monotonic - render_start_time).total_seconds * 1000
    rescue ex
      Log.error "NetworkStatusOverlay render failed", exception: ex
    end

    # 背景グラデーションを描画
    private def draw_background(ctx, w, h)
      # ステータスに基づいて背景色を決定
      bg_color = case @connection_status
                 when :connected
                   0x00_44_00 # 緑系（接続良好）
                 when :slow
                   0x44_44_00 # 黄色系（遅い）
                 when :unstable
                   0x44_22_00 # オレンジ系（不安定）
                 when :disconnected
                   0x44_00_00 # 赤系（切断）
                 else
                   0x22_22_33 # 青系（不明/初期状態）
                 end
      
      # グラデーション背景
      start_color = bg_color
      end_color = darken_color(bg_color, 0.5)
      
      # 上から下へのグラデーション
      (0...h).each do |y_pos|
        alpha = 0.8 # 透明度は一定
        factor = y_pos.to_f / h
        color = blend_colors(start_color, end_color, factor)
        
        ctx.set_draw_color(color, alpha)
        ctx.draw_line(x1: 0, y1: y_pos, x2: w, y2: y_pos)
      end
    end

    # 接続ステータスアイコンを描画
    private def draw_status_icon(ctx, x, y, status)
      icon = case status
             when :connected  then "●" # 接続良好
             when :slow       then "◐" # 遅い
             when :unstable   then "◑" # 不安定
             when :disconnected then "○" # 切断
             else "◌" # 不明/初期状態
             end
      
      color = case status
              when :connected     then 0x00_FF_00 # 緑
              when :slow          then 0xFF_FF_00 # 黄
              when :unstable      then 0xFF_88_00 # オレンジ
              when :disconnected  then 0xFF_00_00 # 赤
              else 0x88_88_FF # 青
              end
      
      ctx.set_draw_color(color, 1.0)
      ctx.draw_text(icon, x: x, y: y, size: @theme.font_size, font: @theme.icon_font_family || @theme.font_family)
    end

    # イベント処理 (例: Ctrl+N で表示切り替え, Ctrl+Shift+N でモード切り替え)
    override def handle_event(event : QuantumEvents::Event) : Bool
      if event.type == QuantumEvents::EventType::UI_KEY_DOWN
        key_event = event.data.as(Concave::Event::KeyDown)
        if key_event.key == Concave::Key::N && key_event.mod.control?
          if key_event.mod.shift?
            # Ctrl+Shift+N: 表示モード切り替え
            @display_mode = DisplayMode.values[(@display_mode.to_i + 1) % DisplayMode.values.size]
            Log.info "NetworkStatusOverlay display mode: #{@display_mode}"
          else
            # Ctrl+N: 表示切り替え
            @visible = !@visible
            Log.info "NetworkStatusOverlay visibility toggled: #{@visible}"
          end
          @cache_needs_update = true
          return true
        end
      elsif event.type == QuantumEvents::EventType::NETWORK_STATUS_CHANGED
        # ネットワークステータス変更イベントを受信
        @cache_needs_update = true
        return true
      end
      false
    end

    # 推奨サイズ (幅は可変、高さはモードによって可変)
    override def preferred_size : Tuple(Int32, Int32)
      height = case @display_mode
               when .MINIMAL?  then @theme.font_size + 10
               when .STANDARD? then @theme.font_size + 10
               when .DETAILED? then @theme.font_size * 6 + 10
               end
      
      {0, height}
    end

    # 表示モードを設定
    def set_display_mode(mode : DisplayMode)
      @display_mode = mode
      @cache_needs_update = true
    end

    # 可視性を設定
    def set_visible(visible : Bool)
      @visible = visible
      @cache_needs_update = true
    end

    # 接続ステータスを更新
    def update_connection_status(status : Symbol)
      return if @connection_status == status # 変更がなければ何もしない
      
      @connection_status = status
      @cache_needs_update = true
      
      # イベント発行（他のコンポーネントに通知）
      QuantumEvents::EventDispatcher.instance.publish(
        QuantumEvents::Event.new(
          type: QuantumEvents::EventType::NETWORK_STATUS_CHANGED,
          data: {"status" => status.to_s}
        )
      )
    end

    private def setup_event_listeners
      dispatcher = QuantumEvents::EventDispatcher.instance
      
      # ネットワークステータス変更イベントを購読
      dispatcher.subscribe(QuantumEvents::EventType::NETWORK_STATUS_CHANGED) do |event|
        @cache_needs_update = true
      end
      
      # パフォーマンス更新イベントを購読
      dispatcher.subscribe(QuantumEvents::EventType::APP_PERFORMANCE_UPDATE) do |event|
        if @visible && (Time.monotonic - @last_update).total_seconds >= @update_interval
          update_stats
        end
      end
      
      # 定期的なネットワークチェック
      spawn name: "network-status-checker" do
        loop do
          sleep @update_interval.seconds
          
          next unless @visible # 非表示時は更新しない
          
          # 最後のチェックから一定時間経過していれば更新
          if (Time.monotonic - @last_network_check).total_seconds >= @update_interval
            check_network_status
            @last_network_check = Time.monotonic
          end
        end
      end
    end

    # ネットワークマネージャから統計を取得してテキストを更新
    private def update_stats
      stats = @network_manager.stats # Managerに `stats` メソッドが必要
      
      # 基本的な統計情報を整形
      @stats_text = "転送: ↑#{format_bytes(stats.bytes_sent)} ↓#{format_bytes(stats.bytes_received)} | リクエスト: #{stats.requests_completed}/#{stats.requests_sent} | 接続: #{stats.active_connections} | 応答: #{stats.avg_response_time_ms.round(1)}ms"
      
      @last_update = Time.monotonic
      @cache_needs_update = true
    rescue ex
      Log.warn "Failed to update network stats", exception: ex
      @stats_text = "ネットワーク: 統計情報更新エラー"
      @cache_needs_update = true
    end
    
    # 詳細な統計情報を取得
    private def get_detailed_stats : Array(String)
      begin
        stats = @network_manager.stats
        detailed = [] of String
        
        detailed << "送信: #{format_bytes(stats.bytes_sent)} (#{stats.requests_sent}リクエスト)"
        detailed << "受信: #{format_bytes(stats.bytes_received)} (#{stats.requests_completed}完了)"
        detailed << "接続: #{stats.active_connections}件 (最大: #{stats.peak_connections})"
        detailed << "応答時間: 平均#{stats.avg_response_time_ms.round(1)}ms (最長: #{stats.max_response_time_ms.round(1)}ms)"
        detailed << "キャッシュヒット率: #{(stats.cache_hit_rate * 100).round(1)}%"
        
        return detailed
      rescue ex
        Log.warn "Failed to get detailed stats", exception: ex
        return ["詳細情報の取得に失敗しました"]
      end
    end
    
    # ネットワーク状態をチェック
    private def check_network_status
      # ネットワークマネージャから最新の状態を取得
      begin
        ping_ms = @network_manager.current_ping_ms
        packet_loss = @network_manager.packet_loss_percentage
        connection_active = @network_manager.is_connected?
        
        # 接続状態を判断
        new_status = if !connection_active
                       :disconnected
                     elsif packet_loss > 10
                       :unstable
                     elsif ping_ms > 300
                       :slow
                     else
                       :connected
                     end
        
        # 状態が変わった場合のみ更新
        update_connection_status(new_status)
      rescue ex
        Log.warn "Failed to check network status", exception: ex
        update_connection_status(:unknown)
      end
    end

    # バイト数を読みやすい形式にフォーマット
    private def format_bytes(bytes : Int64) : String
      if bytes < 1024
        "#{bytes}B"
      elsif bytes < 1024 * 1024
        "#{(bytes / 1024.0).round(1)}K"
      elsif bytes < 1024 * 1024 * 1024
        "#{(bytes / (1024.0 ** 2)).round(1)}M"
      else
        "#{(bytes / (1024.0 ** 3)).round(1)}G"
      end
    end
    
    # 色を暗くする
    private def darken_color(color : UInt32, factor : Float64) : UInt32
      r = (color >> 16) & 0xFF
      g = (color >> 8) & 0xFF
      b = color & 0xFF
      
      r = (r * (1.0 - factor)).to_u8
      g = (g * (1.0 - factor)).to_u8
      b = (b * (1.0 - factor)).to_u8
      
      (r.to_u32 << 16) | (g.to_u32 << 8) | b.to_u32
    end
    
    # 2つの色を混ぜる
    private def blend_colors(color1 : UInt32, color2 : UInt32, factor : Float64) : UInt32
      r1 = (color1 >> 16) & 0xFF
      g1 = (color1 >> 8) & 0xFF
      b1 = color1 & 0xFF
      
      r2 = (color2 >> 16) & 0xFF
      g2 = (color2 >> 8) & 0xFF
      b2 = color2 & 0xFF
      
      r = (r1 * (1.0 - factor) + r2 * factor).to_u8
      g = (g1 * (1.0 - factor) + g2 * factor).to_u8
      b = (b1 * (1.0 - factor) + b2 * factor).to_u8
      
      (r.to_u32 << 16) | (g.to_u32 << 8) | b.to_u32
    end
  end
end 