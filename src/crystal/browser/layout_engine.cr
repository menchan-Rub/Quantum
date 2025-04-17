require "./config"
require "./dom/node"
require "./dom/css"
require "log"

module QuantumCore
  # レイアウトエンジン - ページのレイアウト計算を担当するコンポーネント
  # 最先端のブラウザエンジンとしての機能を実装
  class LayoutEngine
    # 定数定義
    LAYOUT_VERSION = "1.0.0"
    MAX_LAYOUT_ITERATIONS = 3
    DEFAULT_FONT_SIZE = 16.0
    DEFAULT_LINE_HEIGHT_FACTOR = 1.2
    MINIMUM_FONT_SIZE = 8.0
    
    # メディアクエリタイプ - レスポンシブレイアウト用
    enum MediaQueryType
      Screen
      Print
      Speech
      All
    end
    
    # メディアフィーチャ - レスポンシブレイアウト用
    enum MediaFeature
      Width
      MinWidth
      MaxWidth
      Height
      MinHeight
      MaxHeight
      AspectRatio
      Orientation
      Resolution
      ColorDepth
      Hover
      Pointer
    end
    
    # メディアクエリマッチャー - メディアクエリが現在の環境に一致するか評価
    class MediaQueryMatcher
      getter query_text : String
      getter query_type : MediaQueryType
      getter features : Hash(MediaFeature, String)
      
      def initialize(@query_text : String)
        @query_type = MediaQueryType::All
        @features = {} of MediaFeature => String
        parse_query
      end
      
      # メディアクエリの解析
      private def parse_query : Nil
        return if @query_text.empty?
        
        # メディアタイプの取得
        if @query_text.includes?("screen")
          @query_type = MediaQueryType::Screen
        elsif @query_text.includes?("print")
          @query_type = MediaQueryType::Print
        elsif @query_text.includes?("speech")
          @query_type = MediaQueryType::Speech
        end
        
        # 機能の抽出
        extract_feature("width", MediaFeature::Width)
        extract_feature("min-width", MediaFeature::MinWidth)
        extract_feature("max-width", MediaFeature::MaxWidth)
        extract_feature("height", MediaFeature::Height)
        extract_feature("min-height", MediaFeature::MinHeight)
        extract_feature("max-height", MediaFeature::MaxHeight)
        extract_feature("orientation", MediaFeature::Orientation)
        extract_feature("resolution", MediaFeature::Resolution)
      end
      
      # 特定の機能を抽出
      private def extract_feature(name : String, feature : MediaFeature) : Nil
        regex = /#{name}\s*:\s*([^)]+)/
        if match = @query_text.match(regex)
          @features[feature] = match[1].strip
        end
      end
      
      # 現在の環境に一致するか評価
      def matches?(
        viewport_width : Float64,
        viewport_height : Float64,
        device_pixel_ratio : Float64,
        is_print_mode : Bool = false
      ) : Bool
        # メディアタイプの確認
        return false if @query_type == MediaQueryType::Print && !is_print_mode
        return false if @query_type == MediaQueryType::Screen && is_print_mode
        
        # 機能の確認
        @features.each do |feature, value|
          case feature
          when MediaFeature::Width
            return false if parse_length(value) != viewport_width
          when MediaFeature::MinWidth
            return false if parse_length(value) > viewport_width
          when MediaFeature::MaxWidth
            return false if parse_length(value) < viewport_width
          when MediaFeature::Height
            return false if parse_length(value) != viewport_height
          when MediaFeature::MinHeight
            return false if parse_length(value) > viewport_height
          when MediaFeature::MaxHeight
            return false if parse_length(value) < viewport_height
          when MediaFeature::Orientation
            is_landscape = viewport_width >= viewport_height
            if value == "portrait"
              return false if is_landscape
            elsif value == "landscape"
              return false if !is_landscape
            end
          when MediaFeature::Resolution
            # 解像度の確認
            if value.ends_with?("dppx")
              dppx = value.gsub("dppx", "").strip.to_f
              return false if (dppx - device_pixel_ratio).abs > 0.01
            end
          end
        end
        
        true
      end
      
      # メディアクエリの長さの解析
      private def parse_length(value : String) : Float64
        return 0.0 if value.empty?
        
        # ピクセル値
        if value.ends_with?("px")
          return value[0..-3].to_f
        end
        
        # em値はデフォルトのフォントサイズを使用
        if value.ends_with?("em")
          return value[0..-3].to_f * DEFAULT_FONT_SIZE
        end
        
        # rem値もデフォルトのフォントサイズを使用
        if value.ends_with?("rem")
          return value[0..-4].to_f * DEFAULT_FONT_SIZE
        end
        
        # vw値
        if value.ends_with?("vw")
          # 仮のビューポート幅を使用
          viewport_width = 1000.0
          return value[0..-3].to_f * viewport_width / 100.0
        end
        
        # vh値
        if value.ends_with?("vh")
          # 仮のビューポート高さを使用
          viewport_height = 800.0
          return value[0..-3].to_f * viewport_height / 100.0
        end
        
        # 数値のみの場合はピクセル値として扱う
        if value.to_f?
          return value.to_f
        end
        
        0.0
      end
    end
    
    # アニメーション状態 - CSSアニメーションの追跡
    class AnimationState
      property name : String
      property property_name : String
      property start_value : String
      property end_value : String
      property duration : Float64
      property delay : Float64
      property iteration_count : Float64
      property direction : String
      property timing_function : String
      property fill_mode : String
      property current_iteration : Float64
      property current_time : Float64
      property play_state : String
      
      def initialize(@name : String, @property_name : String)
        @start_value = ""
        @end_value = ""
        @duration = 0.0
        @delay = 0.0
        @iteration_count = 1.0
        @direction = "normal"
        @timing_function = "linear"
        @fill_mode = "none"
        @current_iteration = 0.0
        @current_time = 0.0
        @play_state = "running"
      end
      
      # アニメーション値の補間
      def interpolate(progress : Float64) : String
        return @start_value if progress <= 0.0
        return @end_value if progress >= 1.0
        
        # 数値プロパティの補間
        if numeric_value?(@start_value) && numeric_value?(@end_value)
          start_val = extract_numeric_value(@start_value)
          end_val = extract_numeric_value(@end_value)
          unit = extract_unit(@end_value)
          
          interpolated_val = start_val + (end_val - start_val) * progress
          return "#{interpolated_val.round(2)}#{unit}"
        end
        
        # 色の補間
        if color_value?(@start_value) && color_value?(@end_value)
          return interpolate_colors(@start_value, @end_value, progress)
        end
        
        # その他のプロパティは補間できないため、閾値で切り替え
        progress < 0.5 ? @start_value : @end_value
      end
      
      # 数値かどうかの確認
      private def numeric_value?(value : String) : Bool
        extract_numeric_value(value) != nil
      end
      
      # 数値の抽出
      private def extract_numeric_value(value : String) : Float64?
        value.gsub(/[^0-9\.-]/, "").to_f?
      end
      
      # 単位の抽出
      private def extract_unit(value : String) : String
        value.gsub(/[0-9\.-]/, "")
      end
      
      # 色かどうかの確認
      private def color_value?(value : String) : Bool
        value.starts_with?("#") || value.starts_with?("rgb") || value.starts_with?("hsl")
      end
      
      # 色の補間
      private def interpolate_colors(start_color : String, end_color : String, progress : Float64) : String
        # 単純化のため、16進数形式のみをサポート
        if start_color.starts_with?("#") && end_color.starts_with?("#")
          r1, g1, b1 = hex_to_rgb(start_color)
          r2, g2, b2 = hex_to_rgb(end_color)
          
          r = (r1 + (r2 - r1) * progress).to_i
          g = (g1 + (g2 - g1) * progress).to_i
          b = (b1 + (b2 - b1) * progress).to_i
          
          return rgb_to_hex(r, g, b)
        end
        
        # その他の色形式はサポートしない
        progress < 0.5 ? start_color : end_color
      end
      
      # 16進数からRGBへの変換
      private def hex_to_rgb(hex : String) : Tuple(Int32, Int32, Int32)
        hex = hex.lstrip("#")
        
        if hex.size == 3
          r = hex[0].to_i(16) * 17
          g = hex[1].to_i(16) * 17
          b = hex[2].to_i(16) * 17
        else
          r = hex[0, 2].to_i(16)
          g = hex[2, 2].to_i(16)
          b = hex[4, 2].to_i(16)
        end
        
        {r, g, b}
      end
      
      # RGBから16進数への変換
      private def rgb_to_hex(r : Int32, g : Int32, b : Int32) : String
        "##{r.clamp(0, 255).to_s(16).rjust(2, '0')}#{g.clamp(0, 255).to_s(16).rjust(2, '0')}#{b.clamp(0, 255).to_s(16).rjust(2, '0')}"
      end
      
      # イージング関数の適用
      def apply_timing_function(progress : Float64) : Float64
        case @timing_function
        when "ease"
          # キュービックベジェ曲線 (0.25, 0.1, 0.25, 1.0)
          cubic_bezier(0.25, 0.1, 0.25, 1.0, progress)
        when "ease-in"
          # キュービックベジェ曲線 (0.42, 0, 1.0, 1.0)
          cubic_bezier(0.42, 0.0, 1.0, 1.0, progress)
        when "ease-out"
          # キュービックベジェ曲線 (0, 0, 0.58, 1.0)
          cubic_bezier(0.0, 0.0, 0.58, 1.0, progress)
        when "ease-in-out"
          # キュービックベジェ曲線 (0.42, 0, 0.58, 1.0)
          cubic_bezier(0.42, 0.0, 0.58, 1.0, progress)
        when "linear"
          progress
        when "step-start"
          progress >= 0.0 ? 1.0 : 0.0
        when "step-end"
          progress >= 1.0 ? 1.0 : 0.0
        else
          # cubic-bezier() 関数の解析
          if @timing_function.starts_with?("cubic-bezier(")
            parts = @timing_function[13..-2].split(",").map &.strip.to_f
            if parts.size == 4
              cubic_bezier(parts[0], parts[1], parts[2], parts[3], progress)
            else
              progress
            end
          # steps() 関数の解析
          elsif @timing_function.starts_with?("steps(")
            parts = @timing_function[6..-2].split(",").map &.strip
            if parts.size >= 1
              steps = parts[0].to_i
              step_position = parts.size > 1 ? parts[1] : "end"
              
              if step_position == "start"
                (progress * steps).ceil / steps
              else
                (progress * steps).floor / steps
              end
            else
              progress
            end
          else
            progress
          end
        end
      end
      
      # キュービックベジェ曲線の計算
      private def cubic_bezier(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, t : Float64) : Float64
        # ニュートン法を使用して高精度なベジェ曲線の計算を実装
        # 制御点のバリデーション
        x1 = x1.clamp(0.0, 1.0)
        x2 = x2.clamp(0.0, 1.0)
        
        # 係数の計算
        cx = 3.0 * x1
        bx = 3.0 * (x2 - x1) - cx
        ax = 1.0 - cx - bx
        
        cy = 3.0 * y1
        by = 3.0 * (y2 - y1) - cy
        ay = 1.0 - cy - by
        
        # 特殊なケースの高速パス
        return t if (x1 == y1 && x2 == y2) # 線形の場合
        
        # ニュートン法によるxに対応するtの計算
        # 最大反復回数と許容誤差
        max_iterations = 10
        epsilon = 1e-6
        
        # 初期推定値
        guess_t = t
        
        # ニュートン法による反復
        max_iterations.times do
          # 現在の推定値でのx座標
          current_x = ((ax * guess_t + bx) * guess_t + cx) * guess_t
          # 目標値との差
          diff = current_x - t
          
          # 十分な精度に達したら終了
          return calculate_y(guess_t, ay, by, cy) if diff.abs < epsilon
          
          # 導関数の計算
          derivative = (3.0 * ax * guess_t + 2.0 * bx) * guess_t + cx
          
          # 導関数がほぼ0の場合は発散を防ぐ
          return calculate_y(guess_t, ay, by, cy) if derivative.abs < 1e-6
          
          # 次の推定値
          guess_t -= diff / derivative
          
          # 範囲外の値を修正
          guess_t = guess_t.clamp(0.0, 1.0)
        end
        
        # 最終的なy値を計算
        calculate_y(guess_t, ay, by, cy)
      end
      
      # ベジェ曲線のy座標を計算するヘルパーメソッド
      private def calculate_y(t : Float64, ay : Float64, by : Float64, cy : Float64) : Float64
        ((ay * t + by) * t + cy) * t
      end
      # アニメーションの更新
      def update(delta_time : Float64) : Nil
        return if @play_state != "running"
        
        @current_time += delta_time
        
        # ディレイ中は何もしない
        return if @current_time < @delay
        
        elapsed = @current_time - @delay
        
        # 繰り返し回数の計算
        if @iteration_count == Float64::INFINITY
          @current_iteration = (elapsed / @duration).floor
        else
          @current_iteration = Math.min((elapsed / @duration).floor, @iteration_count - 1)
        end
        
        # アニメーションが終了したかどうか
        if @current_iteration >= @iteration_count && @iteration_count != Float64::INFINITY
          @play_state = "finished"
        end
      end
      
      # 現在の進行度を取得
      def current_progress : Float64
        return 0.0 if @duration == 0.0
        
        # ディレイ中は0
        return 0.0 if @current_time < @delay
        
        elapsed = @current_time - @delay
        
        # 現在のイテレーション内での進行度
        iteration_progress = (elapsed % @duration) / @duration
        
        # 方向に基づいて進行度を調整
        case @direction
        when "reverse"
          iteration_progress = 1.0 - iteration_progress
        when "alternate"
          if @current_iteration.to_i % 2 == 1
            iteration_progress = 1.0 - iteration_progress
          end
        when "alternate-reverse"
          if @current_iteration.to_i % 2 == 0
            iteration_progress = 1.0 - iteration_progress
          end
        end
        
        # タイミング関数を適用
        apply_timing_function(iteration_progress)
      end
      
      # アニメーション終了時の状態を取得
      def end_state : String
        case @fill_mode
        when "forwards"
          @direction == "reverse" || (@direction == "alternate" && @iteration_count.to_i % 2 == 1) ||
            (@direction == "alternate-reverse" && @iteration_count.to_i % 2 == 0) ? @start_value : @end_value
        when "backwards"
          @direction == "reverse" || (@direction == "alternate" && @iteration_count.to_i % 2 == 1) ||
            (@direction == "alternate-reverse" && @iteration_count.to_i % 2 == 0) ? @end_value : @start_value
        when "both"
          @direction == "reverse" || (@direction == "alternate" && @iteration_count.to_i % 2 == 1) ||
            (@direction == "alternate-reverse" && @iteration_count.to_i % 2 == 0) ? @start_value : @end_value
        else
          # fill-mode: none
          ""
        end
      end
    end
    
    # トランジション状態 - CSSトランジションの追跡
    class TransitionState
      property property_name : String
      property start_value : String
      property end_value : String
      property duration : Float64
      property delay : Float64
      property timing_function : String
      property start_time : Float64
      property is_running : Bool
      
      def initialize(@property_name : String)
        @start_value = ""
        @end_value = ""
        @duration = 0.0
        @delay = 0.0
        @timing_function = "linear"
        @start_time = 0.0
        @is_running = false
      end
      
      # トランジションの開始
      def start(current_time : Float64, start_value : String, end_value : String) : Nil
        @start_value = start_value
        @end_value = end_value
        @start_time = current_time
        @is_running = true
      end
      
      # トランジションの更新
      def update(current_time : Float64) : String
        return @end_value if !@is_running
        
        # ディレイ中は開始値を返す
        if current_time < @start_time + @delay
          return @start_value
        end
        
        # 経過時間の計算
        elapsed = current_time - @start_time - @delay
        
        # 進行度の計算
        progress = Math.min(elapsed / @duration, 1.0)
        
        # トランジションが完了したかどうか
        if progress >= 1.0
          @is_running = false
          return @end_value
        end
        
        # タイミング関数を適用
        timing_progress = apply_timing_function(progress)
        
        # 値の補間
        interpolate(timing_progress)
      end
      
      # タイミング関数の適用
      private def apply_timing_function(progress : Float64) : Float64
        # AnimationStateと同様の実装
        case @timing_function
        when "ease"
          # キュービックベジェ曲線 (0.25, 0.1, 0.25, 1.0)
          cubic_bezier(0.25, 0.1, 0.25, 1.0, progress)
        when "ease-in"
          # キュービックベジェ曲線 (0.42, 0, 1.0, 1.0)
          cubic_bezier(0.42, 0.0, 1.0, 1.0, progress)
        when "ease-out"
          # キュービックベジェ曲線 (0, 0, 0.58, 1.0)
          cubic_bezier(0.0, 0.0, 0.58, 1.0, progress)
        when "ease-in-out"
          # キュービックベジェ曲線 (0.42, 0, 0.58, 1.0)
          cubic_bezier(0.42, 0.0, 0.58, 1.0, progress)
        when "linear"
          progress
        when "step-start"
          progress >= 0.0 ? 1.0 : 0.0
        when "step-end"
          progress >= 1.0 ? 1.0 : 0.0
        else
          # cubic-bezier() 関数の解析
          if @timing_function.starts_with?("cubic-bezier(")
            parts = @timing_function[13..-2].split(",").map &.strip.to_f
            if parts.size == 4
              cubic_bezier(parts[0], parts[1], parts[2], parts[3], progress)
            else
              progress
            end
          # steps() 関数の解析
          elsif @timing_function.starts_with?("steps(")
            parts = @timing_function[6..-2].split(",").map &.strip
            if parts.size >= 1
              steps = parts[0].to_i
              step_position = parts.size > 1 ? parts[1] : "end"
              
              if step_position == "start"
                (progress * steps).ceil / steps
              else
                (progress * steps).floor / steps
              end
            else
              progress
            end
          else
            progress
          end
        end
      end
      
      # キュービックベジェ曲線の計算
      private def cubic_bezier(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, t : Float64) : Float64
        # ニュートン法を使用して高精度なベジェ曲線の計算を実装
        # 制御点P0(0,0), P1(x1,y1), P2(x2,y2), P3(1,1)のベジェ曲線
        
        # 許容誤差と最大反復回数
        epsilon = 1e-6
        max_iterations = 10
        
        # tに対するx座標を求めるためのベジェ多項式係数
        cx = 3.0 * x1
        bx = 3.0 * (x2 - x1) - cx
        ax = 1.0 - cx - bx
        
        # 初期推定値
        current_t = t
        
        # ニュートン法によるtの精密化
        (0...max_iterations).each do |i|
          # 現在のtでのx値を計算
          x_t = ((ax * current_t + bx) * current_t + cx) * current_t
          
          # 目標のtに十分近ければ終了
          break if (x_t - t).abs < epsilon
          
          # 導関数の計算
          x_derivative = (3.0 * ax * current_t + 2.0 * bx) * current_t + cx
          
          # 導関数がほぼ0の場合は発散を防ぐ
          if x_derivative.abs < 1e-6
            break
          end
          
          # ニュートン法による更新
          current_t = current_t - (x_t - t) / x_derivative
          
          # tを[0,1]の範囲に制限
          current_t = 0.0 if current_t < 0.0
          current_t = 1.0 if current_t > 1.0
        end
        
        # 精密化されたtを使用してy座標を計算
        cy = 3.0 * y1
        by = 3.0 * (y2 - y1) - cy
        ay = 1.0 - cy - by
        
        return ((ay * current_t + by) * current_t + cy) * current_t
      end
      
      # 値の補間
      private def interpolate(progress : Float64) : String
        return @start_value if progress <= 0.0
        return @end_value if progress >= 1.0
        
        # 数値プロパティの補間
        if numeric_value?(@start_value) && numeric_value?(@end_value)
          start_val = extract_numeric_value(@start_value)
          end_val = extract_numeric_value(@end_value)
          unit = extract_unit(@end_value)
          
          interpolated_val = start_val + (end_val - start_val) * progress
          return "#{interpolated_val.round(2)}#{unit}"
        end
        
        # 色の補間
        if color_value?(@start_value) && color_value?(@end_value)
          return interpolate_colors(@start_value, @end_value, progress)
        end
        
        # その他のプロパティは補間できないため、閾値で切り替え
        progress < 0.5 ? @start_value : @end_value
      end
      
      # 数値かどうかの確認
      private def numeric_value?(value : String) : Bool
        extract_numeric_value(value) != nil
      end
      
      # 数値の抽出
      private def extract_numeric_value(value : String) : Float64?
        value.gsub(/[^0-9\.-]/, "").to_f?
      end
      
      # 単位の抽出
      private def extract_unit(value : String) : String
        value.gsub(/[0-9\.-]/, "")
      end
      
      # 色かどうかの確認
      private def color_value?(value : String) : Bool
        value.starts_with?("#") || value.starts_with?("rgb") || value.starts_with?("hsl")
      end
      
      # 色の補間
      private def interpolate_colors(start_color : String, end_color : String, progress : Float64) : String
        # 単純化のため、16進数形式のみをサポート
        if start_color.starts_with?("#") && end_color.starts_with?("#")
          r1, g1, b1 = hex_to_rgb(start_color)
          r2, g2, b2 = hex_to_rgb(end_color)
          
          r = (r1 + (r2 - r1) * progress).to_i
          g = (g1 + (g2 - g1) * progress).to_i
          b = (b1 + (b2 - b1) * progress).to_i
          
          return rgb_to_hex(r, g, b)
        end
        
        # その他の色形式はサポートしない
        progress < 0.5 ? start_color : end_color
      end
      
      # 16進数からRGBへの変換
      private def hex_to_rgb(hex : String) : Tuple(Int32, Int32, Int32)
        hex = hex.lstrip("#")
        
        if hex.size == 3
          r = hex[0].to_i(16) * 17
          g = hex[1].to_i(16) * 17
          b = hex[2].to_i(16) * 17
        else
          r = hex[0, 2].to_i(16)
          g = hex[2, 2].to_i(16)
          b = hex[4, 2].to_i(16)
        end
        
        {r, g, b}
      end
      
      # RGBから16進数への変換
      private def rgb_to_hex(r : Int32, g : Int32, b : Int32) : String
        "##{r.clamp(0, 255).to_s(16).rjust(2, '0')}#{g.clamp(0, 255).to_s(16).rjust(2, '0')}#{b.clamp(0, 255).to_s(16).rjust(2, '0')}"
      end
    end
    
    # アニメーションマネージャー - CSSアニメーションとトランジションの管理
    class AnimationManager
      property animations : Hash(LayoutBox, Array(AnimationState))
      property transitions : Hash(LayoutBox, Array(TransitionState))
      property current_time : Float64
      
      def initialize
        @animations = {} of LayoutBox => Array(AnimationState)
        @transitions = {} of LayoutBox => Array(TransitionState)
        @current_time = 0.0
      end
      
      # アニメーションマネージャーの更新
      def update(delta_time : Float64) : Nil
        @current_time += delta_time
        
        # アニメーションの更新
        @animations.each do |box, animation_states|
          animation_states.each do |animation|
            animation.update(delta_time)
          end
        end
        
        # トランジションの更新
        @transitions.each do |box, transition_states|
          # 終了したトランジションの除去
          transition_states.reject! { |t| !t.is_running }
        end
      end
      
      # ボックスのアニメーションを追加
      def add_animation(box : LayoutBox, property_name : String, animation_name : String, duration : Float64, delay : Float64 = 0.0) : AnimationState
        animation = AnimationState.new(animation_name, property_name)
        animation.duration = duration
        animation.delay = delay
        
        @animations[box] ||= [] of AnimationState
        @animations[box] << animation
        
        animation
      end
      
      # ボックスのトランジションを開始
      def start_transition(box : LayoutBox, property_name : String, start_value : String, end_value : String, duration : Float64, delay : Float64 = 0.0) : TransitionState
        transition = TransitionState.new(property_name)
        transition.duration = duration
        transition.delay = delay
        transition.start(@current_time, start_value, end_value)
        
        @transitions[box] ||= [] of TransitionState
        @transitions[box] << transition
        
        transition
      end
      
      # ボックスのアニメーション状態を取得
      def get_animations(box : LayoutBox) : Array(AnimationState)
        @animations[box]? || [] of AnimationState
      end
      
      # ボックスのトランジション状態を取得
      def get_transitions(box : LayoutBox) : Array(TransitionState)
        @transitions[box]? || [] of TransitionState
      end
      
      # ボックスのプロパティの現在の値を取得
      def get_animated_value(box : LayoutBox, property_name : String, base_value : String) : String
        # 最終的に適用される値
        current_value = base_value
        last_start_time = 0.0
        
        # アニメーションの確認と適用
        if animations = @animations[box]?
          animations.each do |animation|
            if animation.property_name == property_name
              # アニメーションの開始時間を確認
              animation_start_time = @current_time - animation.elapsed_time
              progress = animation.current_progress
              
              # アニメーションが有効かどうかを確認
              is_active = progress > 0.0 || animation.fill_mode == "backwards" || animation.fill_mode == "both"
              
              # より後に開始したアニメーションを優先
              if is_active && animation_start_time >= last_start_time
                current_value = animation.interpolate(progress)
                last_start_time = animation_start_time
              end
            end
          end
        end
        
        # トランジションの確認と適用
        if transitions = @transitions[box]?
          transitions.each do |transition|
            if transition.property_name == property_name && transition.is_running
              # トランジションの開始時間を確認
              transition_start_time = transition.start_time
              
              # より後に開始したトランジションを優先
              if transition_start_time >= last_start_time
                current_value = transition.update(@current_time)
                last_start_time = transition_start_time
              end
            end
          end
        end
        
        # 値の型に応じた適切な処理（数値、色、変換など）
        case property_name
        when "opacity", "z-index"
          # 数値プロパティの範囲制限
          if numeric_value = current_value.to_f?
            min_value = property_name == "opacity" ? 0.0 : Float64::NEG_INFINITY
            max_value = property_name == "opacity" ? 1.0 : Float64::INFINITY
            return numeric_value.clamp(min_value, max_value).to_s
          end
        when "transform"
          # 変換行列の適切な処理
          return normalize_transform_value(current_value)
        when /color$/
          # 色値の正規化
          return normalize_color_value(current_value)
        when /width$/, /height$/, /margin/, /padding/, /top$/, /right$/, /bottom$/, /left$/
          # 長さ値の処理
          return normalize_length_value(current_value)
        end
        
        current_value
      end
      
      # 変換値の正規化
      private def normalize_transform_value(value : String) : String
        # 変換行列の正規化と最適化
        return "none" if value.empty? || value == "none"
        
        # 複数の変換がある場合は適切に結合
        value.gsub(/\s+/, " ").strip
      end
      
      # 色値の正規化
      private def normalize_color_value(value : String) : String
        return "transparent" if value.empty? || value == "transparent"
        
        # RGB/RGBA/HSL/HSLA形式の正規化
        if value.starts_with?("rgb") || value.starts_with?("hsl")
          # スペースの正規化
          return value.gsub(/\s+/, "")
        end
        
        # 16進数形式の正規化（#fffを#ffffffに展開するなど）
        if value.starts_with?("#") && value.size == 4
          r, g, b = value[1], value[2], value[3]
          return "##{r}#{r}#{g}#{g}#{b}#{b}"
        end
        
        value
      end
      
      # 長さ値の正規化
      private def normalize_length_value(value : String) : String
        return "0" if value == "0" || value == "0px" || value == "0%"
        
        # 単位の正規化
        if numeric_value = value.to_f?
          return "#{numeric_value}px" if value.to_f?.try(&.to_s) == value
        end
        
        # calc()式の正規化
        if value.starts_with?("calc(")
          # calc内のスペースを正規化
          return value.gsub(/\s*([+\-*/])\s*/, " \\1 ").gsub(/\(\s+/, "(").gsub(/\s+\)/, ")")
        end
        
        value
      end
    end
    
    # 高DPI対応レンダリングサポート
    class HighDPISupport
      property device_pixel_ratio : Float64
      property fixed_width : Float64?
      property fixed_height : Float64?
      property is_zoom_supported : Bool
      property current_zoom : Float64
      
      def initialize(@device_pixel_ratio = 1.0)
        @fixed_width = nil
        @fixed_height = nil
        @is_zoom_supported = true
        @current_zoom = 1.0
      end
      
      # 物理ピクセルから論理ピクセルへの変換
      def physical_to_logical(physical_size : Float64) : Float64
        physical_size / (@device_pixel_ratio * @current_zoom)
      end
      
      # 論理ピクセルから物理ピクセルへの変換
      def logical_to_physical(logical_size : Float64) : Float64
        logical_size * @device_pixel_ratio * @current_zoom
      end
      
      # ビューポートサイズの調整
      def adjust_viewport_size(width : Float64, height : Float64) : Tuple(Float64, Float64)
        logical_width = physical_to_logical(width)
        logical_height = physical_to_logical(height)
        
        # 固定サイズが指定されている場合はそれを使用
        adjusted_width = @fixed_width || logical_width
        adjusted_height = @fixed_height || logical_height
        
        {adjusted_width, adjusted_height}
      end
      
      # ズームレベルの設定
      def set_zoom(zoom : Float64) : Bool
        return false if !@is_zoom_supported
        
        @current_zoom = zoom.clamp(0.25, 5.0)
        true
      end
      
      # 高DPI対応の画像URLを生成
      def get_high_dpi_image_url(base_url : String) : String
        return base_url if @device_pixel_ratio <= 1.0
        
        # 画像URLを拡張子と残りの部分に分割
        dot_index = base_url.rindex(".")
        return base_url if dot_index.nil?
        
        file_name = base_url[0...dot_index]
        extension = base_url[dot_index..]
        
        # デバイスピクセル比に応じた画像URLを生成
        ratio_suffix = if @device_pixel_ratio >= 3.0
                        "@3x"
                      elsif @device_pixel_ratio >= 2.0
                        "@2x"
                      else
                        ""
                      end
        
        "#{file_name}#{ratio_suffix}#{extension}"
      end
    end
    
    # 国際化対応テキストレンダリング
    class I18nTextRenderer
      enum TextDirection
        LTR  # 左から右
        RTL  # 右から左
        TTB  # 上から下
      end
      
      enum WordBreakMode
        Normal
        BreakAll
        KeepAll
        BreakWord
      end
      
      property default_direction : TextDirection
      property current_language : String
      property supported_languages : Array(String)
      property dictionaries : Hash(String, Hash(String, String))
      property word_break_mode : WordBreakMode
      property hyphenation_enabled : Bool
      
      def initialize
        @default_direction = TextDirection::LTR
        @current_language = "en"
        @supported_languages = ["en"]
        @dictionaries = {} of String => Hash(String, String)
        @word_break_mode = WordBreakMode::Normal
        @hyphenation_enabled = false
      end
      
      # 言語の設定
      def set_language(language_code : String) : Bool
        if @supported_languages.includes?(language_code)
          @current_language = language_code
          true
        else
          false
        end
      end
      
      # 言語サポートの追加
      def add_language_support(language_code : String, text_direction : TextDirection) : Nil
        @supported_languages << language_code unless @supported_languages.includes?(language_code)
        @dictionaries[language_code] ||= {} of String => String
      end
      
      # 翻訳の追加
      def add_translation(language_code : String, key : String, value : String) : Nil
        if @supported_languages.includes?(language_code)
          @dictionaries[language_code] ||= {} of String => String
          @dictionaries[language_code][key] = value
        end
      end
      
      # テキストの方向を取得
      def get_text_direction(text : String, language_code : String? = nil) : TextDirection
        lang = language_code || @current_language
        
        # 言語に基づくデフォルトの方向
        case lang
        when "ar", "he", "fa", "ur"
          TextDirection::RTL
        when "ja", "zh", "ko"
          TextDirection::TTB
        else
          TextDirection::LTR
        end
      end
      
      # 双方向テキストの処理
      def process_bidi_text(text : String, base_direction : TextDirection = TextDirection::LTR) : String
        # Unicode Bidirectional Algorithmの実装
        # Unicode Standard Annex #9に準拠
        
        # 1. テキストを分析して方向性を持つ文字を特定
        segments = analyze_bidi_segments(text)
        
        # 2. 基本方向に基づいて処理
        case base_direction
        when TextDirection::RTL
          process_rtl_context(segments)
        when TextDirection::TTB
          process_vertical_context(segments, text)
        else # LTR
          process_ltr_context(segments)
        end
      end
      
      # 双方向テキストのセグメント分析
      private def analyze_bidi_segments(text : String) : Array(BidiSegment)
        segments = [] of BidiSegment
        current_type = get_character_type(text[0]? || ' ')
        start_index = 0
        
        text.each_char.with_index do |char, i|
          char_type = get_character_type(char)
          
          if char_type != current_type
            # 新しいセグメントを作成
            segments << BidiSegment.new(
              text: text[start_index...i],
              direction: direction_from_char_type(current_type),
              start: start_index,
              end: i - 1
            )
            
            # 新しいセグメントの開始
            current_type = char_type
            start_index = i
          end
        end
        
        # 最後のセグメントを追加
        segments << BidiSegment.new(
          text: text[start_index..],
          direction: direction_from_char_type(current_type),
          start: start_index,
          end: text.size - 1
        )
        
        # セグメントの方向性を解決（埋め込みレベルの処理）
        resolve_embedding_levels(segments)
      end
      
      # 文字タイプの取得（Unicode Bidirectional Classes）
      private def get_character_type(char : Char) : BidiCharType
        codepoint = char.ord
        
        # アラビア文字、ヘブライ文字などのRTL文字
        if (0x0590..0x08FF).includes?(codepoint) || 
           (0xFB1D..0xFDFF).includes?(codepoint) || 
           (0xFE70..0xFEFC).includes?(codepoint)
          BidiCharType::RTL
        # 数字
        elsif (0x0030..0x0039).includes?(codepoint)
          BidiCharType::EN
        # 空白
        elsif char.whitespace?
          BidiCharType::WS
        # 句読点
        elsif char.punctuation?
          BidiCharType::ON
        # LTRマーカー
        elsif char == '\u200E'
          BidiCharType::LRM
        # RTLマーカー
        elsif char == '\u200F'
          BidiCharType::RLM
        # その他（デフォルトはLTR）
        else
          BidiCharType::LTR
        end
      end
      
      # 文字タイプから方向を決定
      private def direction_from_char_type(char_type : BidiCharType) : TextDirection
        case char_type
        when BidiCharType::RTL, BidiCharType::RLM
          TextDirection::RTL
        when BidiCharType::LTR, BidiCharType::EN, BidiCharType::LRM, BidiCharType::WS, BidiCharType::ON
          TextDirection::LTR
        else
          TextDirection::LTR
        end
      end
      
      # 埋め込みレベルの解決
      private def resolve_embedding_levels(segments : Array(BidiSegment)) : Nil
        # Unicode Bidi Algorithmのルール適用
        # 1. 基本方向の設定
        # 2. 明示的な埋め込みと上書きの処理
        # 3. 中立文字と弱い文字の解決
        
        # セグメントの連続性に基づく処理
        segments.each_with_index do |segment, i|
          prev_segment = i > 0 ? segments[i - 1] : nil
          next_segment = i < segments.size - 1 ? segments[i + 1] : nil
          
          # 中立文字（空白や句読点）の方向解決
          if segment.is_neutral?
            if prev_segment && next_segment && 
               prev_segment.direction == next_segment.direction
              segment.resolved_direction = prev_segment.direction
            elsif prev_segment
              segment.resolved_direction = prev_segment.direction
            elsif next_segment
              segment.resolved_direction = next_segment.direction
            else
              segment.resolved_direction = TextDirection::LTR
            end
          end
        end
      end
      
      # LTRコンテキストでの処理
      private def process_ltr_context(segments : Array(BidiSegment)) : String
        result = ""
        
        segments.each do |segment|
          if segment.resolved_direction == TextDirection::RTL
            # RTLセグメントは視覚的に反転
            result += apply_rtl_visual_ordering(segment.text)
          else
            result += segment.text
          end
        end
        
        result
      end
      
      # RTLコンテキストでの処理
      private def process_rtl_context(segments : Array(BidiSegment)) : String
        # セグメント全体を逆順に処理
        reversed_segments = segments.reverse
        result = ""
        
        reversed_segments.each do |segment|
          if segment.resolved_direction == TextDirection::LTR
            # LTRセグメントはそのまま
            result += segment.text
          else
            # RTLセグメントは文字単位で逆順に
            result += segment.text.reverse
          end
        end
        
        result
      end
      
      # 縦書きコンテキストでの処理
      private def process_vertical_context(segments : Array(BidiSegment), original_text : String) : String
        # 縦書きテキストの処理結果
        result = ""
        
        # 文字の向きと回転を適用
        segments.each do |segment|
          text = segment.text
          direction = segment.resolved_direction
          
          # 文字種別に応じた処理
          processed_text = ""
          text.each_char do |char|
            # 文字の種類を判定
            char_type = classify_character(char)
            
            case char_type
            when CharacterType::Ideographic
              # 漢字・かな等：そのまま縦書き配置
              processed_text += char
            when CharacterType::Alphabetic
              if should_rotate_sideways?(char)
                # 横倒し文字（アルファベット等）
                processed_text += apply_sideways_rotation(char)
              else
                processed_text += char
              end
            when CharacterType::Numeric
              # 数字：全角変換して縦中横処理の対象としてマーク
              processed_text += convert_for_vertical_writing(char.to_s)
            when CharacterType::Punctuation
              # 句読点：縦書き用の向きに調整
              processed_text += adjust_punctuation_for_vertical(char, direction)
            else
              processed_text += char
            end
          end
          
          # 縦中横処理（連続する数字等を横組みで表示）
          processed_text = apply_tcy_layout(processed_text)
          
          # 方向に応じた追加処理
          if direction == TextDirection::RTL
            # RTLテキストは特別な配置が必要
            processed_text = process_rtl_in_vertical_context(processed_text)
          end
          
          result += processed_text
        end
        
        result
      end
      
      # RTL視覚的順序付けの適用
      private def apply_rtl_visual_ordering(text : String) : String
        # 双方向アルゴリズムに基づく文字の再配置
        # 1. ミラー化が必要な文字の処理
        mirrored_text = mirror_characters(text)
        
        # 2. 中立文字の処理（数字、空白など）
        processed_text = process_neutral_characters_in_rtl(mirrored_text)
        
        # 3. 文字を視覚的に正しい順序に並べる（基本的には逆順）
        # ただし、数字ブロックなど一部は順序を保持
        reordered_text = reorder_rtl_text(processed_text)
        
        reordered_text
      end
      
      # 文字のミラー化処理
      private def mirror_characters(text : String) : String
        result = ""
        
        text.each_char do |char|
          mirrored = case char
          when '('  then ')'
          when ')'  then '('
          when '['  then ']'
          when ']'  then '['
          when '{'  then '}'
          when '}'  then '{'
          when '<'  then '>'
          when '>'  then '<'
          when '\\' then '/'
          when '/'  then '\\'
          else           char
          end
          
          result += mirrored
        end
        
        result
      end
      
      # 縦書き用の文字変換
      private def convert_for_vertical_writing(text : String) : String
        result = ""
        
        text.each_char do |char|
          # 横書き用の文字を縦書き用に変換
          converted = case char
          # 全角数字への変換
          when '0' then '０'
          when '1' then '１'
          when '2' then '２'
          when '3' then '３'
          when '4' then '４'
          when '5' then '５'
          when '6' then '６'
          when '7' then '７'
          when '8' then '８'
          when '9' then '９'
          # 括弧の縦書き用変換
          when '(' then '︵'
          when ')' then '︶'
          when '[' then '﹇'
          when ']' then '﹈'
          when '{' then '︷'
          when '}' then '︸'
          else char
          end
          
          result += converted
        end
        
        result
      end
      
      # ハイフネーション処理
      def hyphenate(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        return text unless @hyphenation_enabled
        
        # 言語に基づいたハイフネーションルールの適用
        case @current_language
        when "en"
          hyphenate_english(text, max_width, font_metrics)
        when "de"
          hyphenate_german(text, max_width, font_metrics)
        when "fr"
          hyphenate_french(text, max_width, font_metrics)
        when "ja"
          hyphenate_japanese(text, max_width, font_metrics)
        else
          # デフォルトのハイフネーション
          hyphenate_default(text, max_width, font_metrics)
        end
      end
      
      # 英語のハイフネーション
      private def hyphenate_english(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        words = text.split(/\s+/)
        result = [] of String
        current_line_width = 0.0
        current_line = [] of String
        
        words.each do |word|
          word_width = font_metrics.calculate_text_width(word)
          
          # 単語が単体で最大幅を超える場合は分割が必要
          if word_width > max_width
            # 複合語の処理（ハイフン付きの場合）
            if word.includes?('-')
              compound_parts = word.split('-')
              compound_parts.each_with_index do |part, index|
                part_with_hyphen = index < compound_parts.size - 1 ? "#{part}-" : part
                part_width = font_metrics.calculate_text_width(part_with_hyphen)
                
                if current_line_width + part_width <= max_width
                  current_line << part_with_hyphen
                  current_line_width += part_width + font_metrics.calculate_text_width(" ")
                else
                  result << current_line.join(" ") if !current_line.empty?
                  current_line = [part_with_hyphen]
                  current_line_width = part_width + font_metrics.calculate_text_width(" ")
                end
              end
            else
              # 音節に基づく分割
              syllables = find_english_syllables(word)
              remaining_syllables = syllables.dup
              
              while !remaining_syllables.empty?
                current_segment = ""
                segment_syllables = [] of String
                
                # 最大幅に収まる音節の組み合わせを見つける
                remaining_syllables.each do |syllable|
                  test_segment = current_segment.empty? ? syllable : "#{current_segment}-#{syllable}"
                  test_width = font_metrics.calculate_text_width(test_segment)
                  
                  if test_width <= max_width
                    current_segment = test_segment
                    segment_syllables << syllable
                  else
                    break
                  end
                end
                
                # 少なくとも1つの音節を処理できなかった場合、文字単位で分割
                if segment_syllables.empty? && !remaining_syllables.empty?
                  first_syllable = remaining_syllables.first
                  chars = first_syllable.chars
                  current_segment = ""
                  
                  chars.each do |char|
                    test_segment = current_segment + char
                    if font_metrics.calculate_text_width(test_segment) <= max_width
                      current_segment = test_segment
                    else
                      break
                    end
                  end
                  
                  if !current_segment.empty?
                    current_line << current_segment + "-"
                    result << current_line.join(" ") if !current_line.empty?
                    current_line = [] of String
                    current_line_width = 0.0
                    
                    remaining_syllables[0] = first_syllable[current_segment.size..-1]
                  else
                    # 1文字も入らない極端なケース
                    result << current_line.join(" ") if !current_line.empty?
                    current_line = [] of String
                    current_line_width = 0.0
                    remaining_syllables.shift
                  end
                else
                  # 通常の音節処理
                  segment_syllables.size.times { remaining_syllables.shift }
                  
                  if current_line_width + font_metrics.calculate_text_width(current_segment) <= max_width
                    current_line << current_segment
                    current_line_width += font_metrics.calculate_text_width(current_segment) + font_metrics.calculate_text_width(" ")
                  else
                    result << current_line.join(" ") if !current_line.empty?
                    current_line = [current_segment]
                    current_line_width = font_metrics.calculate_text_width(current_segment) + font_metrics.calculate_text_width(" ")
                  end
                  
                  # 最後の音節でなければハイフンを追加
                  if !remaining_syllables.empty? && !current_segment.ends_with?("-")
                    current_line[-1] = current_line.last + "-"
                  end
                end
              end
            end
          else
            # 単語が最大幅に収まる場合
            if current_line_width + word_width <= max_width
              current_line << word
              current_line_width += word_width + font_metrics.calculate_text_width(" ")
            else
              result << current_line.join(" ") if !current_line.empty?
              current_line = [word]
              current_line_width = word_width + font_metrics.calculate_text_width(" ")
            end
          end
        end
        
        # 残りの行を追加
        result << current_line.join(" ") if !current_line.empty?
        
        result.join("\n")
      end
      
      # 英語の音節分割
      private def find_english_syllables(word : String) : Array(String)
        return [word] if word.size <= 3
        
        syllables = [] of String
        vowels = ['a', 'e', 'i', 'o', 'u', 'y']
        consonants = ('a'..'z').to_a.reject { |c| vowels.includes?(c) }
        
        # 接頭辞リスト
        prefixes = ["re", "un", "in", "im", "il", "ir", "dis", "en", "em", "non", "de", "pre", "pro", "anti"]
        # 接尾辞リスト
        suffixes = ["ing", "ed", "er", "ly", "ment", "ness", "ful", "less", "able", "ible", "tion", "sion", "ize", "ise"]
        
        # 接頭辞の処理
        prefix_found = false
        prefixes.each do |prefix|
          if word.starts_with?(prefix) && word.size > prefix.size + 2
            syllables << prefix
            word = word[prefix.size..-1]
            prefix_found = true
            break
          end
        end
        
        # 接尾辞の処理
        suffix_found = false
        suffix_to_append = ""
        suffixes.each do |suffix|
          if word.ends_with?(suffix) && word.size > suffix.size + 2
            suffix_to_append = suffix
            word = word[0..-(suffix.size + 1)]
            suffix_found = true
            break
          end
        end
        
        # 残りの単語を音節に分割
        i = 0
        current_syllable = ""
        vowel_found = false
        
        while i < word.size
          char = word[i].downcase
          current_syllable += word[i].to_s
          
          if vowels.includes?(char)
            vowel_found = true
          elsif vowel_found && i > 0 && i < word.size - 1
            next_char = word[i + 1].downcase
            
            # 子音クラスターの処理
            if consonants.includes?(char) && consonants.includes?(next_char)
              # 特定の子音の組み合わせは分割しない
              non_split_clusters = ["ch", "sh", "th", "ph", "wh", "ck", "tr", "cr", "br", "dr", "gr", "fr", "pr", "wr", "sc", "sm", "sn", "sp", "st", "sw"]
              cluster = char.to_s + next_char.to_s
              
              if !non_split_clusters.includes?(cluster.downcase)
                syllables << current_syllable
                current_syllable = ""
                vowel_found = false
              end
            elsif consonants.includes?(char) && vowels.includes?(next_char) && i > 1
              # 子音+母音パターン
              prev_char = word[i - 1].downcase
              if vowels.includes?(prev_char)
                syllables << current_syllable
                current_syllable = ""
                vowel_found = false
              end
            end
          end
          
          i += 1
        end
        
        # 残りの文字を最後の音節に追加
        syllables << current_syllable if !current_syllable.empty?
        
        # 接尾辞を追加
        syllables << suffix_to_append if suffix_found
        
        # 極端に短い音節を結合
        syllables = merge_short_syllables(syllables)
        
        # 空の音節を削除
        syllables.reject! { |s| s.empty? }
        
        # 音節がない場合は単語全体を返す
        return [word] if syllables.empty?
        
        syllables
      end
      # 短い音節の結合
      private def merge_short_syllables(syllables : Array(String)) : Array(String)
        return syllables if syllables.size <= 1
        
        result = [] of String
        i = 0
        
        while i < syllables.size
          if syllables[i].size < 2 && i < syllables.size - 1
            # 短すぎる音節は次の音節と結合
            result << (syllables[i] + syllables[i + 1])
            i += 2
          else
            result << syllables[i]
            i += 1
          end
        end
        
        result
      end
      
      # ドイツ語のハイフネーション
      private def hyphenate_german(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        # ドイツ語固有のハイフネーションルール
        words = text.split(/\s+/)
        result = [] of String
        
        words.each do |word|
          if word.size <= 4 || font_metrics.calculate_text_width(word) <= max_width
            result << word
          else
            # ドイツ語特有の複合語分割を優先
            compound_parts = split_german_compound_word(word)
            
            if compound_parts.size > 1 && compound_parts.all? { |part| font_metrics.calculate_text_width(part) <= max_width }
              # 複合語の分割点にハイフンを挿入
              result << compound_parts.join("-")
            else
              # 音節に基づくハイフネーション
              syllables = get_syllables(word, "de")
              hyphenated = ""
              current_part = ""
              
              syllables.each do |syllable|
                test_part = current_part + syllable
                
                if font_metrics.calculate_text_width(test_part) <= max_width
                  current_part = test_part
                else
                  hyphenated += current_part + "-"
                  current_part = syllable
                end
              end
              
              hyphenated += current_part if !current_part.empty?
              result << hyphenated
            end
          end
        end
        
        result.join(" ")
      end
      
      # ドイツ語の複合語分割
      private def split_german_compound_word(word : String) : Array(String)
        # ドイツ語の一般的な複合語接続部分
        connectors = ["s", "es", "n", "en", "ens", "er", "e"]
        min_part_length = 3
        
        # 単語が十分に長い場合のみ処理
        return [word] if word.size < 6
        
        possible_splits = [] of Tuple(Int32, Int32, String, String)
        
        # 可能な分割点を探索
        (min_part_length..word.size - min_part_length).each do |i|
          # 直接接続
          first_part = word[0...i]
          second_part = word[i..]
          
          if first_part.size >= min_part_length && second_part.size >= min_part_length
            possible_splits << {i, 0, first_part, second_part}
          end
          
          # コネクタを考慮した接続
          connectors.each do |connector|
            if i + connector.size <= word.size && word[i...i + connector.size] == connector
              first_part = word[0...i]
              second_part = word[i + connector.size..]
              
              if first_part.size >= min_part_length && second_part.size >= min_part_length
                possible_splits << {i, connector.size, first_part, second_part}
              end
            end
          end
        end
        
        # 最適な分割がない場合は元の単語を返す
        return [word] if possible_splits.empty?
        
        # 最も長い前半部分を持つ分割を選択（ドイツ語の複合語は通常前から構成される）
        best_split = possible_splits.max_by { |split| split[0] }
        [best_split[2], best_split[3]]
      end
      
      # フランス語のハイフネーション
      private def hyphenate_french(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        words = text.split(/\s+/)
        result = [] of String
        
        words.each do |word|
          if word.size <= 4 || font_metrics.calculate_text_width(word) <= max_width
            result << word
          else
            # フランス語特有の音節規則に基づくハイフネーション
            syllables = get_syllables(word, "fr")
            hyphenated = ""
            current_part = ""
            
            syllables.each do |syllable|
              test_part = current_part + syllable
              
              if font_metrics.calculate_text_width(test_part) <= max_width
                current_part = test_part
              else
                # フランス語では母音の後でハイフネーションする傾向がある
                if !current_part.empty?
                  hyphenated += current_part + "-"
                  current_part = syllable
                else
                  # 1音節でも幅を超える場合
                  hyphenated += syllable + "-"
                  current_part = ""
                end
              end
            end
            
            hyphenated += current_part if !current_part.empty?
            
            # フランス語特有: ハイフンの前後にスペースを入れない
            hyphenated = hyphenated.gsub(" -", "-").gsub("- ", "-")
            result << hyphenated
          end
        end
        
        result.join(" ")
      end
      
      # 日本語のハイフネーション（行分割）
      private def hyphenate_japanese(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        result = ""
        current_line = ""
        
        # 日本語テキストの文字分類に基づく最適な分割位置の判定
        char_index = 0
        while char_index < text.size
          char = text[char_index]
          next_char = char_index + 1 < text.size ? text[char_index + 1] : nil
          
          # 現在の文字を追加した場合の幅を計算
          test_line = current_line + char
          
          if font_metrics.calculate_text_width(test_line) <= max_width
            # 行に収まる場合はそのまま追加
            current_line = test_line
            char_index += 1
          else
            # 行が最大幅を超える場合
            if !current_line.empty?
              # 現在の行を結果に追加
              result += current_line
              
              # 行末に禁則処理を適用
              if is_japanese_line_start_forbidden(char)
                # 次の文字が行頭禁則文字の場合、現在の行に追加
                result += char
                char_index += 1
              elsif is_japanese_line_end_forbidden(current_line[-1])
                # 現在の行末が行末禁則文字の場合、前の文字を次の行に
                result = result[0..-2]
                current_line = current_line[-1] + char
                char_index += 1
              else
                # 通常の改行
                current_line = char.to_s
                char_index += 1
              end
              
              # 改行を挿入
              result += "\n"
            else
              # 1文字でも幅を超える場合はそのまま追加して改行
              result += char + "\n"
              current_line = ""
              char_index += 1
            end
          end
        end
        
        # 残りの文字を追加
        result += current_line if !current_line.empty?
        
        result
      end
      
      # 日本語の行頭禁則文字かどうかを判定
      private def is_japanese_line_start_forbidden(char : Char) : Bool
        # 行頭禁則文字（句読点、閉じ括弧など）
        forbidden_start_chars = ['。', '、', '，', '．', '：', '；', '！', '？', '）', '］', '｝', '」', '』', '〕', '〉', '》', '】', '〟', '・', '：', '；', '゛', '゜', 'ー']
        forbidden_start_chars.includes?(char)
      end
      
      # 日本語の行末禁則文字かどうかを判定
      private def is_japanese_line_end_forbidden(char : Char) : Bool
        # 行末禁則文字（開き括弧など）
        forbidden_end_chars = ['（', '［', '｛', '「', '『', '〔', '〈', '《', '【', '〝']
        forbidden_end_chars.includes?(char)
      end
      
      # デフォルトのハイフネーション
      private def hyphenate_default(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        words = text.split(/\s+/)
        result = [] of String
        
        words.each do |word|
          if word.size <= 4 || font_metrics.calculate_text_width(word) <= max_width
            result << word
          else
            # 単純な分割ルール（単語の長さに基づく）
            parts = [] of String
            remaining = word
            
            while !remaining.empty? && font_metrics.calculate_text_width(remaining) > max_width
              # 適切な分割位置を見つける（単語の半分あたり）
              split_point = [remaining.size / 2, 2].max
              
              # 分割位置を調整して自然な位置を見つける
              while split_point > 1 && split_point < remaining.size - 1
                if is_valid_hyphenation_point(remaining, split_point)
                  break
                end
                split_point -= 1
              end
              
              parts << remaining[0...split_point] + "-"
              remaining = remaining[split_point..]
            end
            
            parts << remaining if !remaining.empty?
            result << parts.join("")
          end
        end
        
        result.join(" ")
      end
      
      # 有効なハイフネーション位置かどうかを判定
      private def is_valid_hyphenation_point(word : String, position : Int32) : Bool
        return false if position <= 1 || position >= word.size - 1
        
        # 母音と子音のパターンに基づく判定
        vowels = ['a', 'e', 'i', 'o', 'u', 'y']
        
        # 母音の後、子音の前が望ましい
        prev_is_vowel = vowels.includes?(word[position - 1].downcase)
        current_is_consonant = !vowels.includes?(word[position].downcase)
        
        prev_is_vowel && current_is_consonant
      end
      
      # 双方向テキストセグメントを表す構造体
      private struct BidiSegment
        property text : String
        property direction : TextDirection
        property resolved_direction : TextDirection
        property start : Int32
        property end : Int32
        
        def initialize(@text, @direction, @start, @end)
          @resolved_direction = @direction
        end
        
        # 中立文字かどうか
        def is_neutral? : Bool
          @text.each_char.all? do |char|
            char_type = get_character_type(char)
            char_type == BidiCharType::WS || char_type == BidiCharType::ON
          end
        end
      end
      
      # 双方向文字タイプの列挙型
      private enum BidiCharType
        LTR  # 左から右
        RTL  # 右から左
        EN   # ヨーロッパ数字
        AN   # アラビア数字
        WS   # 空白
        ON   # その他の中立文字
        LRM  # 左から右マーカー
        RLM  # 右から左マーカー
      end
      
      # テキストの折り返し処理
      def wrap_text(text : String, max_width : Float64, font_metrics : FontMetrics) : Array(String)
        # 行単位で分割
        lines = text.split("\n")
        result = [] of String
        
        lines.each do |line|
          case @word_break_mode
          when WordBreakMode::Normal
            result.concat(wrap_text_normal(line, max_width, font_metrics))
          when WordBreakMode::BreakAll
            result.concat(wrap_text_break_all(line, max_width, font_metrics))
          when WordBreakMode::KeepAll
            result.concat(wrap_text_keep_all(line, max_width, font_metrics))
          when WordBreakMode::BreakWord
            result.concat(wrap_text_break_word(line, max_width, font_metrics))
          end
        end
        
        result
      end
      
      # 通常のテキスト折り返し（単語単位）
      private def wrap_text_normal(text : String, max_width : Float64, font_metrics : FontMetrics) : Array(String)
        words = text.split(/\s+/)
        lines = [] of String
        current_line = ""
        
        words.each do |word|
          # 現在の行に単語を追加した場合の幅を計算
          test_line = current_line.empty? ? word : "#{current_line} #{word}"
          test_width = font_metrics.calculate_text_width(test_line)
          
          if test_width <= max_width || current_line.empty?
            # 行に収まる場合、または行が空の場合は追加
            current_line = test_line
          else
            # 行に収まらない場合は新しい行に
            lines << current_line
            current_line = word
          end
        end
        
        # 最後の行を追加
        lines << current_line if !current_line.empty?
        
        lines
      end
      
      # 文字単位の折り返し
      private def wrap_text_break_all(text : String, max_width : Float64, font_metrics : FontMetrics) : Array(String)
        lines = [] of String
        current_line = ""
        
        text.each_char do |char|
          # 現在の行に文字を追加した場合の幅を計算
          test_line = current_line + char
          test_width = font_metrics.calculate_text_width(test_line)
          
          if test_width <= max_width || current_line.empty?
            # 行に収まる場合、または行が空の場合は追加
            current_line = test_line
          else
            # 行に収まらない場合は新しい行に
            lines << current_line
            current_line = char.to_s
          end
        end
        
        # 最後の行を追加
        lines << current_line if !current_line.empty?
        
        lines
      end
      
      # 単語を分割しない折り返し
      private def wrap_text_keep_all(text : String, max_width : Float64, font_metrics : FontMetrics) : Array(String)
        words = text.split(/\s+/)
        lines = [] of String
        current_line = ""
        
        words.each do |word|
          word_width = font_metrics.calculate_text_width(word)
          
          if word_width > max_width && !current_line.empty?
            # 単語が行の幅を超える場合は、新しい行に配置
            lines << current_line
            current_line = word
          else
            # 現在の行に単語を追加した場合の幅を計算
            test_line = current_line.empty? ? word : "#{current_line} #{word}"
            test_width = font_metrics.calculate_text_width(test_line)
            
            if test_width <= max_width || current_line.empty?
              # 行に収まる場合、または行が空の場合は追加
              current_line = test_line
            else
              # 行に収まらない場合は新しい行に
              lines << current_line
              current_line = word
            end
          end
        end
        
        # 最後の行を追加
        lines << current_line if !current_line.empty?
        
        lines
      end
      
      # 単語内での折り返し
      private def wrap_text_break_word(text : String, max_width : Float64, font_metrics : FontMetrics) : Array(String)
        words = text.split(/\s+/)
        lines = [] of String
        current_line = ""
        
        words.each do |word|
          word_width = font_metrics.calculate_text_width(word)
          
          if word_width <= max_width
            # 単語が行に収まる場合
            test_line = current_line.empty? ? word : "#{current_line} #{word}"
            test_width = font_metrics.calculate_text_width(test_line)
            
            if test_width <= max_width || current_line.empty?
              current_line = test_line
            else
              lines << current_line
              current_line = word
            end
          else
            # 単語が行に収まらない場合は分割
            if !current_line.empty?
              lines << current_line
              current_line = ""
            end
            
            # 単語を文字単位で分割
            current_word_part = ""
            
            word.each_char do |char|
              test_part = current_word_part + char
              test_width = font_metrics.calculate_text_width(test_part)
              
              if test_width <= max_width || current_word_part.empty?
                current_word_part = test_part
              else
                lines << current_word_part
                current_word_part = char.to_s
              end
            end
            
            current_line = current_word_part
          end
        end
        
        # 最後の行を追加
        lines << current_line if !current_line.empty?
        
        lines
      end
      
      # テキストのローカライズ
      def localize(key : String, language_code : String? = nil) : String
        lang = language_code || @current_language
        
        if @dictionaries.has_key?(lang) && @dictionaries[lang].has_key?(key)
          @dictionaries[lang][key]
        else
          key
        end
      end
    end
    
    # アクセシビリティサポート
    class AccessibilitySupport
      enum Role
        None
        Button
        Link
        Heading
        Image
        List
        ListItem
        Navigation
        Article
        Checkbox
        Radio
        TextField
        ComboBox
        Menu
        MenuItem
        Dialog
        Alert
        TabList
        Tab
        TabPanel
        Tree
        TreeItem
        Grid
        Row
        Cell
      end
      
      property screen_reader_enabled : Bool
      property font_scaling_enabled : Bool
      property focus_highlight_enabled : Bool
      property high_contrast_mode : Bool
      property reduced_motion : Bool
      property keyboard_navigation_enabled : Bool
      property minimum_click_area_size : Float64
      
      def initialize
        @screen_reader_enabled = false
        @font_scaling_enabled = false
        @focus_highlight_enabled = true
        @high_contrast_mode = false
        @reduced_motion = false
        @keyboard_navigation_enabled = true
        @minimum_click_area_size = 44.0 # ピクセル単位（WCAG推奨値）
      end
      
      # ARIAロールの取得
      def get_aria_role(element : Element) : Role
        role_attr = element.get_attribute("role")
        
        # 明示的なロール属性があればそれを使用
        if role_attr
          return parse_role(role_attr)
        end
        
        # 暗黙的なロールを推測
        case element.tag_name.downcase
        when "button"
          Role::Button
        when "a"
          Role::Link
        when "h1", "h2", "h3", "h4", "h5", "h6"
          Role::Heading
        when "img"
          Role::Image
        when "ul", "ol"
          Role::List
        when "li"
          Role::ListItem
        when "nav"
          Role::Navigation
        when "article"
          Role::Article
        when "input"
          type = element.get_attribute("type")
          case type
          when "checkbox"
            Role::Checkbox
          when "radio"
            Role::Radio
          when "text", "email", "password", "tel", "url"
            Role::TextField
          else
            Role::None
          end
        when "select"
          Role::ComboBox
        when "menu"
          Role::Menu
        when "menuitem"
          Role::MenuItem
        when "dialog"
          Role::Dialog
        when "table"
          Role::Grid
        when "tr"
          Role::Row
        when "td", "th"
          Role::Cell
        else
          Role::None
        end
      end
      
      # ロール文字列の解析
      private def parse_role(role : String) : Role
        case role
        when "button"
          Role::Button
        when "link"
          Role::Link
        when "heading"
          Role::Heading
        when "img", "image"
          Role::Image
        when "list"
          Role::List
        when "listitem"
          Role::ListItem
        when "navigation", "nav"
          Role::Navigation
        when "article"
          Role::Article
        when "checkbox"
          Role::Checkbox
        when "radio"
          Role::Radio
        when "textbox"
          Role::TextField
        when "combobox"
          Role::ComboBox
        when "menu"
          Role::Menu
        when "menuitem"
          Role::MenuItem
        when "dialog"
          Role::Dialog
        when "alertdialog", "alert"
          Role::Alert
        when "tablist"
          Role::TabList
        when "tab"
          Role::Tab
        when "tabpanel"
          Role::TabPanel
        when "tree"
          Role::Tree
        when "treeitem"
          Role::TreeItem
        when "grid", "table"
          Role::Grid
        when "row"
          Role::Row
        when "cell", "gridcell"
          Role::Cell
        else
          Role::None
        end
      end
      
      # アクセシブルな名前の取得
      def get_accessible_name(element : Element) : String
        # 優先順位に従って名前を決定
        
        # 1. aria-labelledby属性
        if labelledby_id = element.get_attribute("aria-labelledby")
          if labelling_element = element.owner_document.get_element_by_id(labelledby_id)
            return labelling_element.text_content.strip
          end
        end
        
        # 2. aria-label属性
        if label = element.get_attribute("aria-label")
          return label.strip
        end
        
        # 3. 要素の種類に応じた方法
        case element.tag_name.downcase
        when "img"
          # alt属性
          if alt = element.get_attribute("alt")
            return alt.strip
          end
        when "input"
          # label要素
          if id = element.get_attribute("id")
            if label_element = element.owner_document.query_selector("label[for='#{id}']")
              return label_element.text_content.strip
            end
          end
          
          # placeholder属性
          if placeholder = element.get_attribute("placeholder")
            return placeholder.strip
          end
          
          # value属性（ボタンの場合）
          if element.get_attribute("type") == "button" && (value = element.get_attribute("value"))
            return value.strip
          end
        when "button"
          # ボタンのテキスト
          return element.text_content.strip
        when "a"
          # リンクのテキスト
          text = element.text_content.strip
          return text unless text.empty?
          
          # リンクのテキストが空の場合はhref属性
          if href = element.get_attribute("href")
            return href
          end
        end
        
        # 4. テキストコンテンツ
        text = element.text_content.strip
        return text unless text.empty?
        
        # 5. タイトル属性
        if title = element.get_attribute("title")
          return title.strip
        end
        
        # 名前が見つからない場合は空文字列
        ""
      end
      
      # アクセシブルな説明の取得
      def get_accessible_description(element : Element) : String
        # aria-describedby属性
        if describedby_id = element.get_attribute("aria-describedby")
          if describing_element = element.owner_document.get_element_by_id(describedby_id)
            return describing_element.text_content.strip
          end
        end
        
        # title属性（名前として使用されていない場合）
        if title = element.get_attribute("title")
          accessible_name = get_accessible_name(element)
          return title.strip if title != accessible_name
        end
        
        # 説明が見つからない場合は空文字列
        ""
      end
      
      # フォーカス可能かどうかの判定
      def is_focusable(element : Element) : Bool
        # tabindex属性
        if tabindex = element.get_attribute("tabindex")
          return tabindex.to_i? != -1
        end
        
        # 暗黙的にフォーカス可能な要素
        case element.tag_name.downcase
        when "a"
          element.has_attribute?("href")
        when "button", "select", "textarea"
          !element.has_attribute?("disabled")
        when "input"
          !element.has_attribute?("disabled") && element.get_attribute("type") != "hidden"
        when "area"
          element.has_attribute?("href")
        when "iframe"
          true
        else
          false
        end
      end
      
      # キーボードイベントの処理
      def handle_keyboard_event(element : Element, event_type : String, key : String) : Bool
        return false unless @keyboard_navigation_enabled
        
        # フォーカス可能でない場合は処理しない
        return false unless is_focusable(element)
        
        case event_type
        when "keydown"
          case key
          when "Enter", " "
            # ボタンやリンクのアクティベーション
            role = get_aria_role(element)
            if role == Role::Button || role == Role::Link
              return true # イベントが処理されたことを示す
            end
          when "Tab"
            # フォーカス移動
            return true
          when "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight"
            # 方向キーによるナビゲーション
            role = get_aria_role(element)
            case role
            when Role::ComboBox, Role::Menu, Role::TabList, Role::Tree
              return true
            else
              return false
            end
          end
        end
        
        false
      end
      
      # 高コントラストモード用のスタイル調整
      def apply_high_contrast_styles(style : ComputedStyle) : ComputedStyle
        return style unless @high_contrast_mode
        
        # 新しいスタイルを作成
        high_contrast_style = ComputedStyle.new
        
        # スタイルをコピー
        style.each do |property, value|
          high_contrast_style[property] = value
        end
        
        # 背景色とテキスト色の調整
        if background_color = style["background-color"]?
          high_contrast_style["background-color"] = adjust_contrast_color(background_color, true)
        end
        
        if color = style["color"]?
          high_contrast_style["color"] = adjust_contrast_color(color, false)
        end
        
        # ボーダーの強調
        if border_color = style["border-color"]?
          high_contrast_style["border-color"] = "#000000"
        end
        
        # フォーカスインジケータの強調
        if high_contrast_style["outline"] == "none" || high_contrast_style["outline"] == "0"
          high_contrast_style["outline"] = "2px solid #FFFFFF"
          high_contrast_style["outline-offset"] = "2px"
        end
        
        high_contrast_style
      end
      
      # 高コントラスト用の色調整
      private def adjust_contrast_color(color : String, is_background : Bool) : String
        # 16進数形式の色のみをサポート
        if color.starts_with?("#")
          r, g, b = hex_to_rgb(color)
          
          # 輝度の計算
          luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
          
          if is_background
            # 背景色は明るい色または暗い色に
            return luminance > 0.5 ? "#FFFFFF" : "#000000"
          else
            # テキスト色は背景色と対照的に
            return luminance > 0.5 ? "#000000" : "#FFFFFF"
          end
        end
        
        # その他の色形式はそのまま
        color
      end
      
      # 16進数からRGBへの変換
      private def hex_to_rgb(hex : String) : Tuple(Int32, Int32, Int32)
        hex = hex.lstrip("#")
        
        if hex.size == 3
          r = hex[0].to_i(16) * 17
          g = hex[1].to_i(16) * 17
          b = hex[2].to_i(16) * 17
        else
          r = hex[0, 2].to_i(16)
          g = hex[2, 2].to_i(16)
          b = hex[4, 2].to_i(16)
        end
        
        {r, g, b}
      end
      
      # 縮小モーション設定の適用
      def apply_reduced_motion(animation_state : AnimationState) : AnimationState
        return animation_state unless @reduced_motion
        
        # アニメーション時間の短縮または無効化
        animation_state.duration = Math.min(animation_state.duration, 0.1)
        animation_state
      end
      
      # アクセシビリティツリーの構築
      def build_accessibility_tree(document : Document) : AccessibilityNode
        root_node = AccessibilityNode.new(nil)
        root_node.role = Role::None
        
        build_accessibility_node(document.document_element, root_node)
        
        root_node
      end
      
      # アクセシビリティノードの構築（再帰的）
      private def build_accessibility_node(element : Element?, parent_node : AccessibilityNode) : Nil
        return unless element
        
        # 非表示要素はスキップ
        return if element.get_attribute("aria-hidden") == "true"
        
        style = element.computed_style
        return if style && (style["display"] == "none" || style["visibility"] == "hidden")
        
        # 新しいノードを作成
        node = AccessibilityNode.new(element)
        node.role = get_aria_role(element)
        node.name = get_accessible_name(element)
        node.description = get_accessible_description(element)
        node.is_focusable = is_focusable(element)
        
        # 状態の設定
        node.is_checked = element.get_attribute("aria-checked") == "true"
        node.is_disabled = element.get_attribute("aria-disabled") == "true" || element.has_attribute?("disabled")
        node.is_expanded = element.get_attribute("aria-expanded") == "true"
        node.is_selected = element.get_attribute("aria-selected") == "true" || element.has_attribute?("selected")
        node.is_required = element.get_attribute("aria-required") == "true" || element.has_attribute?("required")
        
        # 親ノードに追加
        parent_node.children << node
        
        # 子要素の処理
        element.children.each do |child|
          if child.is_a?(Element)
            build_accessibility_node(child, node)
          end
        end
      end
      
      # アクセシビリティノード
      class AccessibilityNode
        property element : Element?
        property role : Role
        property name : String
        property description : String
        property children : Array(AccessibilityNode)
        property is_focusable : Bool
        property is_checked : Bool
        property is_disabled : Bool
        property is_expanded : Bool
        property is_selected : Bool
        property is_required : Bool
        
        def initialize(@element : Element?)
          @role = Role::None
          @name = ""
          @description = ""
          @children = [] of AccessibilityNode
          @is_focusable = false
          @is_checked = false
          @is_disabled = false
          @is_expanded = false
          @is_selected = false
          @is_required = false
        end
        
        # スクリーンリーダー向けテキストの生成
        def to_screen_reader_text : String
          text = ""
          
          # ロールの追加
          unless @role == Role::None
            text += "#{@role.to_s.downcase}, "
          end
          
          # 名前の追加
          text += @name
          
          # 状態情報の追加
          if @is_checked
            text += ", checked"
          end
          
          if @is_disabled
            text += ", disabled"
          end
          
          if @is_expanded
            text += ", expanded"
          end
          
          if @is_selected
            text += ", selected"
          end
          
          if @is_required
            text += ", required"
          end
          
          # 説明の追加
          if !@description.empty?
            text += ", #{@description}"
          end
          
          text
        end
      end
    end
    
    # メインレイアウトエンジンクラスにアクセシビリティと国際化サポートを追加
    # メインエンジンのプロパティ
    property animation_manager : AnimationManager
    property i18n_renderer : I18nTextRenderer
    property high_dpi_support : HighDPISupport
    property accessibility_support : AccessibilitySupport
    property media_query_cache : Hash(String, Bool)
    property is_print_mode : Bool
    
    # 初期化メソッドの拡張
    def initialize(@config : Config::CoreConfig)
      @style_resolver = StyleResolver.new([] of Stylesheet)
      @viewport_width = 800.0
      @viewport_height = 600.0
      @device_pixel_ratio = 1.0
      @root_stacking_context = nil
      @logger = Log.for("quantum_core.layout_engine")
      
      # 新機能の初期化
      @animation_manager = AnimationManager.new
      @i18n_renderer = I18nTextRenderer.new
      @high_dpi_support = HighDPISupport.new(@device_pixel_ratio)
      @accessibility_support = AccessibilitySupport.new
      @media_query_cache = {} of String => Bool
      @is_print_mode = false
    end
    
    # スタイルシートのメディアクエリ評価
    def evaluate_media_query(query_text : String) : Bool
      # キャッシュ使用
      if @media_query_cache.has_key?(query_text)
        return @media_query_cache[query_text]
      end
      
      # メディアクエリの解析と評価
      query_matcher = MediaQueryMatcher.new(query_text)
      result = query_matcher.matches?(@viewport_width, @viewport_height, @device_pixel_ratio, @is_print_mode)
      
      # 結果をキャッシュ
      @media_query_cache[query_text] = result
      
      result
    end
    
    # ビューポートサイズの設定（拡張版）
    def set_viewport_size(width : Float64, height : Float64, device_pixel_ratio : Float64 = 1.0) : Nil
      @device_pixel_ratio = device_pixel_ratio
      @high_dpi_support.device_pixel_ratio = device_pixel_ratio
      
      # 高DPI対応の調整
      adjusted_width, adjusted_height = @high_dpi_support.adjust_viewport_size(width, height)
      
      @viewport_width = adjusted_width
      @viewport_height = adjusted_height
      
      # メディアクエリキャッシュのクリア
      @media_query_cache.clear
    end
    
    # プリントモードの切り替え
    def set_print_mode(is_print : Bool) : Nil
      @is_print_mode = is_print
      
      # メディアクエリキャッシュのクリア
      @media_query_cache.clear
    end
    
    # アクセシブルなレイアウト計算
    def layout_accessible(document : Document) : Tuple(LayoutBox, AccessibilitySupport::AccessibilityNode)
      # 通常のレイアウト計算
      root_box = layout(document)
      
      # アクセシビリティツリーの構築
      accessibility_tree = @accessibility_support.build_accessibility_tree(document)
      
      # ボックスツリーとアクセシビリティツリーを返す
      {root_box, accessibility_tree}
    end
    
    # アニメーションの更新
    def update_animations(delta_time : Float64) : Nil
      @animation_manager.update(delta_time)
    end
    
    # メディアクエリのフィルタリングを行うスタイルシート収集の拡張版
    private def collect_stylesheets(document : Document) : Array(Stylesheet)
      sheets = [] of Stylesheet
      
      # ユーザーエージェントのデフォルトスタイルシート
      sheets << create_user_agent_stylesheet
      
      # ユーザー設定スタイルシート（アクセシビリティ設定など）
      if user_stylesheet = @config.user_stylesheet
        sheets << user_stylesheet
      end
      
      # 外部スタイルシートとインラインスタイルの処理
      document.query_selector_all("link[rel=stylesheet], style").each do |elem|
        case elem.tag_name.downcase
        when "link"
          # 外部スタイルシートのメディアクエリの確認
          media_attr = elem.get_attribute("media") || "all"
          
          if media_attr == "all" || evaluate_media_query(media_attr)
            # メディアクエリに一致する場合のみ追加
            if href = elem.get_attribute("href")
              stylesheet = @resource_loader.load_stylesheet(href)
              if stylesheet
                stylesheet.priority = Stylesheet::Priority::Author
                
                # 条件付きルールのフィルタリング
                stylesheet.rules = filter_conditional_rules(stylesheet.rules)
                
                # 代替スタイルシートの処理
                rel = elem.get_attribute("rel") || ""
                if rel.includes?("alternate") && !@config.alternate_stylesheets_enabled
                  next
                end
                
                sheets << stylesheet
              end
            end
          end
        when "style"
          # インラインスタイルのメディアクエリの確認
          media_attr = elem.get_attribute("media") || "all"
          
          if media_attr == "all" || evaluate_media_query(media_attr)
            if text_content = elem.text_content
              begin
                parser = CSSParser.new(text_content)
                author_sheet = parser.parse
                author_sheet.priority = Stylesheet::Priority::Author
                
                # メディアクエリの付いたルールのフィルタリング
                author_sheet.rules = filter_conditional_rules(author_sheet.rules)
                
                sheets << author_sheet
              rescue ex
                @logger.error { "スタイルシート解析エラー: #{ex.message}" }
              end
            end
          end
        end
      end
      
      # インラインスタイル属性の処理
      document.query_selector_all("[style]").each do |elem|
        if style_attr = elem.get_attribute("style")
          begin
            parser = CSSParser.new("* { #{style_attr} }")
            inline_sheet = parser.parse
            inline_sheet.priority = Stylesheet::Priority::Inline
            inline_sheet.element_scope = elem
            
            sheets << inline_sheet
          rescue ex
            @logger.error { "インラインスタイル解析エラー: #{ex.message}" }
          end
        end
      end
      
      # !important宣言を持つスタイルシートの優先順位調整
      sheets.each do |sheet|
        sheet.rules.each do |rule|
          rule.declarations.each do |decl|
            if decl.important
              case sheet.priority
              when Stylesheet::Priority::UserAgent
                decl.computed_priority = Stylesheet::Priority::UserAgentImportant
              when Stylesheet::Priority::User
                decl.computed_priority = Stylesheet::Priority::UserImportant
              when Stylesheet::Priority::Author
                decl.computed_priority = Stylesheet::Priority::AuthorImportant
              when Stylesheet::Priority::Inline
                decl.computed_priority = Stylesheet::Priority::InlineImportant
              end
            end
          end
        end
      end
      
      # アニメーションとトランジションの登録
      register_animations_and_transitions(sheets)
      
      # パフォーマンス最適化のためのスタイルシートのインデックス作成
      @style_resolver.index_stylesheets(sheets)
      sheets
    end
    
    # テキストの国際化対応レンダリング
    private def render_internationalized_text(text : String, box : LayoutBox, max_width : Float64) : Array(LayoutBox::InlineFragment)
      return [] of LayoutBox::InlineFragment if text.empty?
      
      style = box.computed_style
      return [] of LayoutBox::InlineFragment unless style
      
      # フォントメトリクスの取得
      font_metrics = FontMetrics.new(style)
      
      # テキストの方向を取得
      text_direction = @i18n_renderer.get_text_direction(text)
      
      # 双方向テキストの処理
      processed_text = @i18n_renderer.process_bidi_text(text, text_direction)
      
      # テキストの折り返し
      wrapped_lines = @i18n_renderer.wrap_text(processed_text, max_width, font_metrics)
      
      # インラインフラグメントの作成
      fragments = [] of LayoutBox::InlineFragment
      
      wrapped_lines.each do |line|
        fragment = LayoutBox::InlineFragment.new(box)
        fragment.width = font_metrics.calculate_text_width(line)
        fragment.height = font_metrics.line_box_height
        fragment.baseline = font_metrics.baseline_to_top
        
        fragments << fragment
      end
      
      fragments
    end
    
    # アクセシビリティを考慮したスタイル計算
    def compute_accessible_style(element : Element) : ComputedStyle
      style = @style_resolver.compute_style(element)
      
      # 高コントラストモードの適用
      if @accessibility_support.high_contrast_mode
        style = @accessibility_support.apply_high_contrast_styles(style)
      end
      
      # フォントスケーリングの適用
      if @accessibility_support.font_scaling_enabled
        if font_size = style["font-size"]?
          current_size = parse_length(font_size, 0.0)
          scaled_size = current_size * 1.5 # 1.5倍に拡大
          style["font-size"] = "#{scaled_size}px"
        end
      end
      
      # フォーカスハイライトの強化
      if @accessibility_support.focus_highlight_enabled
        if element.has_attribute?("tabindex") || @accessibility_support.is_focusable(element)
          style["outline"] = "3px solid #0078D7"
          style["outline-offset"] = "2px"
        end
      end
      
      style
    end
    
    # SVG処理用のコンポーネント
    class SVGRenderer
      property viewbox : {Float64, Float64, Float64, Float64}
      property preserve_aspect_ratio : String
      property elements : Array(SVGElement)
      
      def initialize
        @viewbox = {0.0, 0.0, 300.0, 150.0} # デフォルトのviewBox
        @preserve_aspect_ratio = "xMidYMid meet"
        @elements = [] of SVGElement
      end
      
      def parse_svg(node : DOM::Node)
        return unless node.is_a?(DOM::Element)
        
        if node.tag_name.downcase == "svg"
          parse_svg_attributes(node)
        end
        
        parse_svg_children(node)
      end
      
      private def parse_svg_attributes(element : DOM::Element)
        if viewbox_attr = element.get_attribute("viewBox")
          values = viewbox_attr.split(/\s+/).map(&.to_f64)
          @viewbox = {values[0], values[1], values[2], values[3]} if values.size == 4
        end
        
        if preserve_attr = element.get_attribute("preserveAspectRatio")
          @preserve_aspect_ratio = preserve_attr
        end
      end
      
      private def parse_svg_children(node : DOM::Node)
        return unless node.is_a?(DOM::Element)
        
        case node.tag_name.downcase
        when "rect"
          @elements << SVGRectElement.new(node)
        when "circle"
          @elements << SVGCircleElement.new(node)
        when "ellipse"
          @elements << SVGEllipseElement.new(node)
        when "line"
          @elements << SVGLineElement.new(node)
        when "polyline"
          @elements << SVGPolylineElement.new(node)
        when "polygon"
          @elements << SVGPolygonElement.new(node)
        when "path"
          @elements << SVGPathElement.new(node)
        when "text"
          @elements << SVGTextElement.new(node)
        when "g"
          # グループ要素は子要素を持つ
          @elements << SVGGroupElement.new(node)
          node.children.each { |child| parse_svg_children(child) }
        end
        
        # 他の子要素を処理
        node.children.each { |child| parse_svg_children(child) }
      end
      
      def render(context : RenderContext, box : LayoutBox)
        # レンダリングコンテキストを設定
        scale_x = box.dimensions.content_width / @viewbox[2]
        scale_y = box.dimensions.content_height / @viewbox[3]
        
        # preserveAspectRatioに基づいて調整
        scale = case @preserve_aspect_ratio
                when /xMinYMin/
                  {scale_x, scale_y}
                when /xMidYMid/
                  scale = Math.min(scale_x, scale_y)
                  {scale, scale}
                when /xMaxYMax/
                  scale = Math.max(scale_x, scale_y)
                  {scale, scale}
                else
                  {scale_x, scale_y}
                end
        
        # SVG要素をレンダリング
        @elements.each do |element|
          element.render(context, box.x, box.y, scale)
        end
      end
    end
    
    # SVG要素の基底クラス
    abstract class SVGElement
      property element : DOM::Element
      property style : Hash(String, String)
      
      def initialize(@element)
        @style = parse_style
      end
      
      def parse_style
        style_hash = {} of String => String
        
        # style属性を解析
        if style_attr = @element.get_attribute("style")
          style_attr.split(";").each do |pair|
            key, value = pair.split(":", 2).map(&.strip)
            style_hash[key] = value if key && value
          end
        end
        
        # 直接の属性（fill, stroke等）を解析
        ["fill", "stroke", "stroke-width", "opacity", "fill-opacity", "stroke-opacity"].each do |attr|
          if value = @element.get_attribute(attr)
            style_hash[attr] = value
          end
        end
        
        style_hash
      end
      
      # 変換行列の適用
      def apply_transform(x : Float64, y : Float64, scale : Tuple(Float64, Float64)) : Tuple(Float64, Float64)
        if transform = @element.get_attribute("transform")
          # SVG変換行列の解析と適用
          transform_matrix = parse_transform_matrix(transform)
          
          # 座標に変換行列を適用
          new_x = transform_matrix[0] * x + transform_matrix[2] * y + transform_matrix[4]
          new_y = transform_matrix[1] * x + transform_matrix[3] * y + transform_matrix[5]
          
          # スケールを適用
          return {new_x * scale[0], new_y * scale[1]}
        end
        
        # 変換がない場合は単純にスケールを適用
        {x * scale[0], y * scale[1]}
      end
      
      # SVG変換行列の解析
      private def parse_transform_matrix(transform : String) : Array(Float64)
        # デフォルトの単位行列
        matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        
        # 各変換を処理
        transform.scan(/(matrix|translate|scale|rotate|skewX|skewY)\s*\(\s*([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?(?:\s*,\s*|\s+)[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?(?:\s*,\s*|\s+)?(?:[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?(?:\s*,\s*|\s+)?)*)\s*\)/i) do |match|
          transform_type = match[1].downcase
          params = match[2].split(/[\s,]+/).map(&.to_f64)
          
          case transform_type
          when "matrix"
            if params.size >= 6
              matrix = [
                params[0], params[1], params[2],
                params[3], params[4], params[5]
              ]
            end
          when "translate"
            tx = params[0]
            ty = params.size > 1 ? params[1] : 0.0
            translation_matrix = [1.0, 0.0, 0.0, 1.0, tx, ty]
            matrix = multiply_matrices(matrix, translation_matrix)
          when "scale"
            sx = params[0]
            sy = params.size > 1 ? params[1] : sx
            scale_matrix = [sx, 0.0, 0.0, sy, 0.0, 0.0]
            matrix = multiply_matrices(matrix, scale_matrix)
          when "rotate"
            angle_rad = params[0] * Math::PI / 180.0
            cos_val = Math.cos(angle_rad)
            sin_val = Math.sin(angle_rad)
            
            if params.size >= 3
              # 回転中心が指定されている場合
              cx, cy = params[1], params[2]
              # 中心を原点に移動
              t1 = [1.0, 0.0, 0.0, 1.0, cx, cy]
              # 回転
              r = [cos_val, sin_val, -sin_val, cos_val, 0.0, 0.0]
              # 元の位置に戻す
              t2 = [1.0, 0.0, 0.0, 1.0, -cx, -cy]
              
              temp = multiply_matrices(t2, r)
              rotation_matrix = multiply_matrices(temp, t1)
            else
              # 原点を中心に回転
              rotation_matrix = [cos_val, sin_val, -sin_val, cos_val, 0.0, 0.0]
            end
            
            matrix = multiply_matrices(matrix, rotation_matrix)
          when "skewx"
            angle_rad = params[0] * Math::PI / 180.0
            skew_matrix = [1.0, 0.0, Math.tan(angle_rad), 1.0, 0.0, 0.0]
            matrix = multiply_matrices(matrix, skew_matrix)
          when "skewy"
            angle_rad = params[0] * Math::PI / 180.0
            skew_matrix = [1.0, Math.tan(angle_rad), 0.0, 1.0, 0.0, 0.0]
            matrix = multiply_matrices(matrix, skew_matrix)
          end
        end
        
        matrix
      end
      
      # 2つの3x3行列（2D変換用）の乗算
      private def multiply_matrices(a : Array(Float64), b : Array(Float64)) : Array(Float64)
        [
          a[0] * b[0] + a[2] * b[1],          # a11 * b11 + a12 * b21
          a[1] * b[0] + a[3] * b[1],          # a21 * b11 + a22 * b21
          a[0] * b[2] + a[2] * b[3],          # a11 * b12 + a12 * b22
          a[1] * b[2] + a[3] * b[3],          # a21 * b12 + a22 * b22
          a[0] * b[4] + a[2] * b[5] + a[4],   # a11 * b13 + a12 * b23 + a13
          a[1] * b[4] + a[3] * b[5] + a[5]    # a21 * b13 + a22 * b23 + a23
        ]
      end
      
      # 点の配列に変換を適用
      def apply_transform_to_points(points : Array(Tuple(Float64, Float64)), scale : Tuple(Float64, Float64)) : Array(Tuple(Float64, Float64))
        points.map do |point|
          apply_transform(point[0], point[1], scale)
        end
      end
      
      # 色値の解析（#RGB, #RRGGBB, rgb(), rgba()などに対応）
      def parse_color(color_str : String) : Tuple(UInt8, UInt8, UInt8, Float64)
        return {0_u8, 0_u8, 0_u8, 0.0} if color_str.empty?
        
        # デフォルト値
        r, g, b = 0_u8, 0_u8, 0_u8
        alpha = 1.0
        
        if color_str.starts_with?("#")
          hex = color_str[1..]
          case hex.size
          when 3 # #RGB形式
            r = (hex[0].to_i(16) * 17).to_u8
            g = (hex[1].to_i(16) * 17).to_u8
            b = (hex[2].to_i(16) * 17).to_u8
          when 6 # #RRGGBB形式
            r = hex[0..1].to_i(16).to_u8
            g = hex[2..3].to_i(16).to_u8
            b = hex[4..5].to_i(16).to_u8
          when 8 # #RRGGBBAA形式
            r = hex[0..1].to_i(16).to_u8
            g = hex[2..3].to_i(16).to_u8
            b = hex[4..5].to_i(16).to_u8
            alpha = hex[6..7].to_i(16) / 255.0
          end
        elsif color_str.starts_with?("rgb")
          # rgb(r,g,b)またはrgba(r,g,b,a)形式を解析
          if match = color_str.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)/)
            r = match[1].to_i.to_u8
            g = match[2].to_i.to_u8
            b = match[3].to_i.to_u8
            alpha = match[4]? ? match[4].to_f64 : 1.0
          end
        elsif color_str.starts_with?("hsl")
          # hsl(h,s%,l%)またはhsla(h,s%,l%,a)形式を解析
          if match = color_str.match(/hsla?\(\s*(\d+)\s*,\s*(\d+)%\s*,\s*(\d+)%(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)/)
            h = match[1].to_i % 360 / 360.0
            s = match[2].to_i / 100.0
            l = match[3].to_i / 100.0
            alpha = match[4]? ? match[4].to_f64 : 1.0
            
            # HSLからRGBへの変換
            r, g, b = hsl_to_rgb(h, s, l)
          end
        elsif SVGElement.named_colors.has_key?(color_str.downcase)
          # 名前付き色（"red", "blue"など）
          hex = SVGElement.named_colors[color_str.downcase]
          r = hex[0..1].to_i(16).to_u8
          g = hex[2..3].to_i(16).to_u8
          b = hex[4..5].to_i(16).to_u8
        end
        
        {r, g, b, alpha}
      end
      
      # HSLからRGBへの変換
      private def hsl_to_rgb(h : Float64, s : Float64, l : Float64) : Tuple(UInt8, UInt8, UInt8)
        r, g, b = 0.0, 0.0, 0.0
        
        if s == 0
          r = g = b = l
        else
          q = l < 0.5 ? l * (1 + s) : l + s - l * s
          p = 2 * l - q
          
          r = hue_to_rgb(p, q, h + 1.0/3.0)
          g = hue_to_rgb(p, q, h)
          b = hue_to_rgb(p, q, h - 1.0/3.0)
        end
        
        {(r * 255).to_u8, (g * 255).to_u8, (b * 255).to_u8}
      end
      
      private def hue_to_rgb(p : Float64, q : Float64, t : Float64) : Float64
        t += 1.0 if t < 0
        t -= 1.0 if t > 1
        
        return p + (q - p) * 6 * t if t < 1.0/6.0
        return q if t < 1.0/2.0
        return p + (q - p) * (2.0/3.0 - t) * 6 if t < 2.0/3.0
        return p
      end
      
      # 名前付き色のマップを提供するクラスメソッド
      def self.named_colors
        @@named_colors ||= {
          "black" => "000000", "silver" => "c0c0c0", "gray" => "808080", "white" => "ffffff",
          "maroon" => "800000", "red" => "ff0000", "purple" => "800080", "fuchsia" => "ff00ff",
          "green" => "008000", "lime" => "00ff00", "olive" => "808000", "yellow" => "ffff00",
          "navy" => "000080", "blue" => "0000ff", "teal" => "008080", "aqua" => "00ffff",
          "aliceblue" => "f0f8ff", "antiquewhite" => "faebd7", "aquamarine" => "7fffd4",
          "azure" => "f0ffff", "beige" => "f5f5dc", "bisque" => "ffe4c4",
          "blanchedalmond" => "ffebcd", "blueviolet" => "8a2be2", "brown" => "a52a2a",
          "burlywood" => "deb887", "cadetblue" => "5f9ea0", "chartreuse" => "7fff00",
          "chocolate" => "d2691e", "coral" => "ff7f50", "cornflowerblue" => "6495ed",
          "cornsilk" => "fff8dc", "crimson" => "dc143c", "cyan" => "00ffff",
          "darkblue" => "00008b", "darkcyan" => "008b8b", "darkgoldenrod" => "b8860b",
          "darkgray" => "a9a9a9", "darkgreen" => "006400", "darkgrey" => "a9a9a9",
          "darkkhaki" => "bdb76b", "darkmagenta" => "8b008b", "darkolivegreen" => "556b2f",
          "darkorange" => "ff8c00", "darkorchid" => "9932cc", "darkred" => "8b0000",
          "darksalmon" => "e9967a", "darkseagreen" => "8fbc8f", "darkslateblue" => "483d8b",
          "darkslategray" => "2f4f4f", "darkslategrey" => "2f4f4f", "darkturquoise" => "00ced1",
          "darkviolet" => "9400d3", "deeppink" => "ff1493", "deepskyblue" => "00bfff",
          "dimgray" => "696969", "dimgrey" => "696969", "dodgerblue" => "1e90ff",
          "firebrick" => "b22222", "floralwhite" => "fffaf0", "forestgreen" => "228b22",
          "gainsboro" => "dcdcdc", "ghostwhite" => "f8f8ff", "gold" => "ffd700",
          "goldenrod" => "daa520", "greenyellow" => "adff2f", "grey" => "808080",
          "honeydew" => "f0fff0", "hotpink" => "ff69b4", "indianred" => "cd5c5c",
          "indigo" => "4b0082", "ivory" => "fffff0", "khaki" => "f0e68c",
          "lavender" => "e6e6fa", "lavenderblush" => "fff0f5", "lawngreen" => "7cfc00",
          "lemonchiffon" => "fffacd", "lightblue" => "add8e6", "lightcoral" => "f08080",
          "lightcyan" => "e0ffff", "lightgoldenrodyellow" => "fafad2", "lightgray" => "d3d3d3",
          "lightgreen" => "90ee90", "lightgrey" => "d3d3d3", "lightpink" => "ffb6c1",
          "lightsalmon" => "ffa07a", "lightseagreen" => "20b2aa", "lightskyblue" => "87cefa",
          "lightslategray" => "778899", "lightslategrey" => "778899", "lightsteelblue" => "b0c4de",
          "lightyellow" => "ffffe0", "limegreen" => "32cd32", "linen" => "faf0e6",
          "magenta" => "ff00ff", "mediumaquamarine" => "66cdaa", "mediumblue" => "0000cd",
          "mediumorchid" => "ba55d3", "mediumpurple" => "9370db", "mediumseagreen" => "3cb371",
          "mediumslateblue" => "7b68ee", "mediumspringgreen" => "00fa9a", "mediumturquoise" => "48d1cc",
          "mediumvioletred" => "c71585", "midnightblue" => "191970", "mintcream" => "f5fffa",
          "mistyrose" => "ffe4e1", "moccasin" => "ffe4b5", "navajowhite" => "ffdead",
          "oldlace" => "fdf5e6", "olivedrab" => "6b8e23", "orange" => "ffa500",
          "orangered" => "ff4500", "orchid" => "da70d6", "palegoldenrod" => "eee8aa",
          "palegreen" => "98fb98", "paleturquoise" => "afeeee", "palevioletred" => "db7093",
          "papayawhip" => "ffefd5", "peachpuff" => "ffdab9", "peru" => "cd853f",
          "pink" => "ffc0cb", "plum" => "dda0dd", "powderblue" => "b0e0e6",
          "rosybrown" => "bc8f8f", "royalblue" => "4169e1", "saddlebrown" => "8b4513",
          "salmon" => "fa8072", "sandybrown" => "f4a460", "seagreen" => "2e8b57",
          "seashell" => "fff5ee", "sienna" => "a0522d", "skyblue" => "87ceeb",
          "slateblue" => "6a5acd", "slategray" => "708090", "slategrey" => "708090",
          "snow" => "fffafa", "springgreen" => "00ff7f", "steelblue" => "4682b4",
          "tan" => "d2b48c", "thistle" => "d8bfd8", "tomato" => "ff6347",
          "turquoise" => "40e0d0", "violet" => "ee82ee", "wheat" => "f5deb3",
          "whitesmoke" => "f5f5f5", "yellowgreen" => "9acd32"
        }
      end
      
      abstract def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
    end
    
    class SVGRectElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 属性の取得と解析
        x = parse_float_attribute(@element, "x", 0.0)
        y = parse_float_attribute(@element, "y", 0.0)
        width = parse_float_attribute(@element, "width", 0.0)
        height = parse_float_attribute(@element, "height", 0.0)
        rx = parse_float_attribute(@element, "rx", 0.0)
        ry = parse_float_attribute(@element, "ry", 0.0)
        
        # rx、ryの一方のみが指定された場合は同じ値を使用
        if rx > 0 && ry == 0
          ry = rx
        elsif ry > 0 && rx == 0
          rx = ry
        end
        
        # 座標変換
        scaled_x = origin_x + x * scale[0]
        scaled_y = origin_y + y * scale[1]
        scaled_width = width * scale[0]
        scaled_height = height * scale[1]
        scaled_rx = rx * scale[0]
        scaled_ry = ry * scale[1]
        
        # スタイル設定
        fill = get_color_from_style("fill", "black")
        stroke = get_color_from_style("stroke")
        stroke_width = parse_float_style("stroke-width", 1.0) * Math.min(scale[0], scale[1])
        opacity = parse_float_style("opacity", 1.0)
        fill_opacity = parse_float_style("fill-opacity", opacity)
        stroke_opacity = parse_float_style("stroke-opacity", opacity)
        

        if fill != "none"
          context.set_fill_opacity(fill_opacity)
          if scaled_rx > 0 && scaled_ry > 0
            context.fill_rounded_rect(scaled_x, scaled_y, scaled_width, scaled_height, scaled_rx, scaled_ry, fill)
          else
            context.fill_rect(scaled_x, scaled_y, scaled_width, scaled_height, fill)
          end
        end
        
        if stroke && stroke != "none"
          context.set_stroke_opacity(stroke_opacity)
          if scaled_rx > 0 && scaled_ry > 0
            context.stroke_rounded_rect(scaled_x, scaled_y, scaled_width, scaled_height, scaled_rx, scaled_ry, stroke, stroke_width)
          else
            context.stroke_rect(scaled_x, scaled_y, scaled_width, scaled_height, stroke, stroke_width)
          end
        end
      end
      
      private def get_color_from_style(property : String, default : String? = nil) : String?
        color = @style[property]? || @element.get_attribute(property)
        return default if color.nil? || color.empty?
        color
      end
      
      private def parse_float_style(property : String, default : Float64) : Float64
        value = @style[property]? || @element.get_attribute(property)
        return default if value.nil? || value.empty?
        value.to_f64
      rescue
        default
      end
    end
    
    class SVGCircleElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 属性の取得と解析
        cx = parse_float_attribute(@element, "cx", 0.0)
        cy = parse_float_attribute(@element, "cy", 0.0)
        r = parse_float_attribute(@element, "r", 0.0)
        
        return if r <= 0.0 # 半径が0以下の場合は描画しない
        
        # 座標変換
        scaled_cx = origin_x + cx * scale[0]
        scaled_cy = origin_y + cy * scale[1]
        # 円の場合は縦横の平均スケールを使用
        scaled_r = r * Math.min(scale[0], scale[1])
        
        # スタイル設定
        fill = get_color_from_style("fill", "black")
        stroke = get_color_from_style("stroke")
        stroke_width = parse_float_style("stroke-width", 1.0) * Math.min(scale[0], scale[1])
        opacity = parse_float_style("opacity", 1.0)
        fill_opacity = parse_float_style("fill-opacity", opacity)
        stroke_opacity = parse_float_style("stroke-opacity", opacity)
        

        if fill != "none"
          context.set_fill_opacity(fill_opacity)
          context.fill_circle(scaled_cx, scaled_cy, scaled_r, fill)
        end
        
        if stroke && stroke != "none"
          context.set_stroke_opacity(stroke_opacity)
          context.stroke_circle(scaled_cx, scaled_cy, scaled_r, stroke, stroke_width)
        end
      end
      
      private def get_color_from_style(property : String, default : String? = nil) : String?
        color = @style[property]? || @element.get_attribute(property)
        return default if color.nil? || color.empty?
        color
      end
      
      private def parse_float_style(property : String, default : Float64) : Float64
        value = @style[property]? || @element.get_attribute(property)
        return default if value.nil? || value.empty?
        value.to_f64
      rescue
        default
      end
    end
    
    class SVGEllipseElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 属性の取得と解析
        cx = parse_float_attribute(@element, "cx", 0.0)
        cy = parse_float_attribute(@element, "cy", 0.0)
        rx = parse_float_attribute(@element, "rx", 0.0)
        ry = parse_float_attribute(@element, "ry", 0.0)
        
        return if rx <= 0.0 || ry <= 0.0 # 半径が0以下の場合は描画しない
        
        # 座標変換
        scaled_cx = origin_x + cx * scale[0]
        scaled_cy = origin_y + cy * scale[1]
        scaled_rx = rx * scale[0]
        scaled_ry = ry * scale[1]
        
        # スタイル設定
        fill = get_color_from_style("fill", "black")
        stroke = get_color_from_style("stroke")
        stroke_width = parse_float_style("stroke-width", 1.0) * Math.min(scale[0], scale[1])
        opacity = parse_float_style("opacity", 1.0)
        fill_opacity = parse_float_style("fill-opacity", opacity)
        stroke_opacity = parse_float_style("stroke-opacity", opacity)

        if fill != "none"
          context.set_fill_opacity(fill_opacity)
          context.fill_ellipse(scaled_cx, scaled_cy, scaled_rx, scaled_ry, fill)
        end
        
        if stroke && stroke != "none"
          context.set_stroke_opacity(stroke_opacity)
          context.stroke_ellipse(scaled_cx, scaled_cy, scaled_rx, scaled_ry, stroke, stroke_width)
        end
      end
      
      private def get_color_from_style(property : String, default : String? = nil) : String?
        color = @style[property]? || @element.get_attribute(property)
        return default if color.nil? || color.empty?
        color
      end
      
      private def parse_float_style(property : String, default : Float64) : Float64
        value = @style[property]? || @element.get_attribute(property)
        return default if value.nil? || value.empty?
        value.to_f64
      rescue
        default
      end
    end
    
    class SVGLineElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 属性の取得と解析
        x1 = parse_float_attribute(@element, "x1", 0.0)
        y1 = parse_float_attribute(@element, "y1", 0.0)
        x2 = parse_float_attribute(@element, "x2", 0.0)
        y2 = parse_float_attribute(@element, "y2", 0.0)
        
        # 座標変換
        scaled_x1 = origin_x + x1 * scale[0]
        scaled_y1 = origin_y + y1 * scale[1]
        scaled_x2 = origin_x + x2 * scale[0]
        scaled_y2 = origin_y + y2 * scale[1]
        
        # スタイル設定
        stroke = get_color_from_style("stroke", "black")
        stroke_width = parse_float_style("stroke-width", 1.0) * Math.min(scale[0], scale[1])
        opacity = parse_float_style("opacity", 1.0)
        stroke_opacity = parse_float_style("stroke-opacity", opacity)
        stroke_dasharray = @style["stroke-dasharray"]? || @element.get_attribute("stroke-dasharray")
        

        if stroke && stroke != "none"
          context.set_stroke_opacity(stroke_opacity)
          if stroke_dasharray && !stroke_dasharray.empty?
            dash_pattern = parse_dash_array(stroke_dasharray, Math.min(scale[0], scale[1]))
            context.set_dash_pattern(dash_pattern)
          end
          context.draw_line(scaled_x1, scaled_y1, scaled_x2, scaled_y2, stroke, stroke_width)
          context.reset_dash_pattern if stroke_dasharray && !stroke_dasharray.empty?
        end
      end
      
      private def get_color_from_style(property : String, default : String? = nil) : String?
        color = @style[property]? || @element.get_attribute(property)
        return default if color.nil? || color.empty?
        color
      end
      
      private def parse_float_style(property : String, default : Float64) : Float64
        value = @style[property]? || @element.get_attribute(property)
        return default if value.nil? || value.empty?
        value.to_f64
      rescue
        default
      end
      
      private def parse_dash_array(dash_str : String, scale_factor : Float64) : Array(Float64)
        dash_str.split(/[\s,]+/).reject(&.empty?).map { |v| v.to_f64 * scale_factor }
      rescue
        [] of Float64
      end
    end
    
    class SVGPolylineElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 属性の取得と解析
        points_str = @element.get_attribute("points") || ""
        return if points_str.empty?
        
        # 座標点の解析
        points = parse_points(points_str)
        return if points.size < 2 # 少なくとも2点必要
        
        # スタイル設定
        fill = get_color_from_style("fill")
        stroke = get_color_from_style("stroke", "black")
        stroke_width = parse_float_style("stroke-width", 1.0) * Math.min(scale[0], scale[1])
        opacity = parse_float_style("opacity", 1.0)
        fill_opacity = parse_float_style("fill-opacity", opacity)
        stroke_opacity = parse_float_style("stroke-opacity", opacity)
        stroke_dasharray = @style["stroke-dasharray"]? || @element.get_attribute("stroke-dasharray")
        
        # 座標点のスケーリングとオフセット適用
        scaled_points = points.map do |point|
          {origin_x + point[0] * scale[0], origin_y + point[1] * scale[1]}
        end
        
     
        if fill && fill != "none"
          context.set_fill_opacity(fill_opacity)
          context.fill_polygon(scaled_points, fill)
        end
        
        if stroke && stroke != "none"
          context.set_stroke_opacity(stroke_opacity)
          if stroke_dasharray && !stroke_dasharray.empty?
            dash_pattern = parse_dash_array(stroke_dasharray, Math.min(scale[0], scale[1]))
            context.set_dash_pattern(dash_pattern)
          end
          context.draw_polyline(scaled_points, stroke, stroke_width)
          context.reset_dash_pattern if stroke_dasharray && !stroke_dasharray.empty?
        end
      end
      
      private def parse_points(points_str : String) : Array(Tuple(Float64, Float64))
        result = [] of Tuple(Float64, Float64)
        
        # カンマまたは空白で区切られた座標文字列を解析
        coords = points_str.split(/[\s,]+/).reject(&.empty?)
        
        # 座標ペアを構築
        i = 0
        while i + 1 < coords.size
          begin
            x = coords[i].to_f64
            y = coords[i + 1].to_f64
            result << {x, y}
          rescue
            # 無効な座標は無視
          end
          i += 2
        end
        
        result
      end
      
      private def get_color_from_style(property : String, default : String? = nil) : String?
        color = @style[property]? || @element.get_attribute(property)
        return default if color.nil? || color.empty?
        color
      end
      
      private def parse_float_style(property : String, default : Float64) : Float64
        value = @style[property]? || @element.get_attribute(property)
        return default if value.nil? || value.empty?
        value.to_f64
      rescue
        default
      end
      
      private def parse_dash_array(dash_str : String, scale_factor : Float64) : Array(Float64)
        dash_str.split(/[\s,]+/).reject(&.empty?).map { |v| v.to_f64 * scale_factor }
      rescue
        [] of Float64
      end
    end
    
    class SVGPolygonElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        points_str = @element.get_attribute("points") || ""
        return if points_str.empty?
        
        # 座標点の解析
        points = parse_points(points_str)
        return if points.size < 3
        
        # スタイル属性の取得
        fill = get_color_from_style("fill", "#000000")
        stroke = get_color_from_style("stroke")
        stroke_width = parse_float_style("stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # ダッシュパターンの取得
        stroke_dasharray = @style["stroke-dasharray"]? || @element.get_attribute("stroke-dasharray")
        
        # 座標点のスケーリングとオフセット適用
        scaled_points = points.map do |point|
          {origin_x + point[0] * scale[0], origin_y + point[1] * scale[1]}
        end
        
   
        if fill && fill != "none"
          context.fill_polygon(scaled_points, fill)
        end
        
        if stroke && stroke != "none"
          if stroke_dasharray && !stroke_dasharray.empty?
            dash_pattern = parse_dash_array(stroke_dasharray, (scale[0] + scale[1]) / 2.0)
            context.set_dash_pattern(dash_pattern) unless dash_pattern.empty?
          end
          
          context.draw_polygon(scaled_points, stroke, stroke_width)
          
          context.reset_dash_pattern if stroke_dasharray && !stroke_dasharray.empty?
        end
      end
    end
    
    class SVGPathElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        d = @element.get_attribute("d") || ""
        return if d.empty?
        
        # スタイル属性の取得
        fill = get_color_from_style("fill", "#000000")
        stroke = get_color_from_style("stroke")
        stroke_width = parse_float_style("stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # ダッシュパターンの取得
        stroke_dasharray = @style["stroke-dasharray"]? || @element.get_attribute("stroke-dasharray")
        
        # パスコマンドの解析と実行
        path_commands = parse_path_commands(d)
        

        if path_commands.size > 0
          # スケーリングを適用したパスコマンドを生成
          scaled_commands = scale_path_commands(path_commands, origin_x, origin_y, scale)
          
          # パスのレンダリング
          if fill && fill != "none"
            context.fill_path(scaled_commands, fill)
          end
          
          if stroke && stroke != "none"
            if stroke_dasharray && !stroke_dasharray.empty?
              dash_pattern = parse_dash_array(stroke_dasharray, (scale[0] + scale[1]) / 2.0)
              context.set_dash_pattern(dash_pattern) unless dash_pattern.empty?
            end
            
            context.stroke_path(scaled_commands, stroke, stroke_width)
            
            context.reset_dash_pattern if stroke_dasharray && !stroke_dasharray.empty?
          end
        end
      end
      
      private def parse_path_commands(d : String) : Array(PathCommand)
        commands = [] of PathCommand
        
        # パスコマンド文字列を解析
        segments = d.scan(/([MLHVCSQTAZmlhvcsqtaz])([^MLHVCSQTAZmlhvcsqtaz]*)/)
        
        current_x = 0.0
        current_y = 0.0
        subpath_start_x = 0.0
        subpath_start_y = 0.0
        last_control_x = 0.0
        last_control_y = 0.0
        
        segments.each do |segment|
          cmd = segment[1]
          params_str = segment[2].strip
          params = params_str.split(/[\s,]+/).reject(&.empty?).map(&.to_f64)
          
          case cmd
          when "M", "m"
            is_relative = (cmd == "m")
            i = 0
            while i + 1 < params.size
              x = is_relative ? current_x + params[i] : params[i]
              y = is_relative ? current_y + params[i + 1] : params[i + 1]
              
              commands << (i == 0 ? PathCommand::MoveTo.new(x, y) : PathCommand::LineTo.new(x, y))
              
              current_x = x
              current_y = y
              if i == 0
                subpath_start_x = x
                subpath_start_y = y
              end
              i += 2
            end
            
          when "L", "l"
            is_relative = (cmd == "l")
            i = 0
            while i + 1 < params.size
              x = is_relative ? current_x + params[i] : params[i]
              y = is_relative ? current_y + params[i + 1] : params[i + 1]
              
              commands << PathCommand::LineTo.new(x, y)
              
              current_x = x
              current_y = y
              i += 2
            end
            
          when "H", "h"
            is_relative = (cmd == "h")
            params.each do |x_param|
              x = is_relative ? current_x + x_param : x_param
              
              commands << PathCommand::LineTo.new(x, current_y)
              
              current_x = x
            end
            
          when "V", "v"
            is_relative = (cmd == "v")
            params.each do |y_param|
              y = is_relative ? current_y + y_param : y_param
              
              commands << PathCommand::LineTo.new(current_x, y)
              
              current_y = y
            end
            
          when "C", "c"
            is_relative = (cmd == "c")
            i = 0
            while i + 5 < params.size
              cp1x = is_relative ? current_x + params[i] : params[i]
              cp1y = is_relative ? current_y + params[i + 1] : params[i + 1]
              cp2x = is_relative ? current_x + params[i + 2] : params[i + 2]
              cp2y = is_relative ? current_y + params[i + 3] : params[i + 3]
              x = is_relative ? current_x + params[i + 4] : params[i + 4]
              y = is_relative ? current_y + params[i + 5] : params[i + 5]
              
              commands << PathCommand::CubicBezierTo.new(cp1x, cp1y, cp2x, cp2y, x, y)
              
              last_control_x = cp2x
              last_control_y = cp2y
              current_x = x
              current_y = y
              i += 6
            end
            
          when "S", "s"
            is_relative = (cmd == "s")
            i = 0
            while i + 3 < params.size
              # 前のコマンドがCまたはSの場合、最初の制御点は前のコマンドの第2制御点の反射
              if commands.last.is_a?(PathCommand::CubicBezierTo)
                cp1x = 2 * current_x - last_control_x
                cp1y = 2 * current_y - last_control_y
              else
                cp1x = current_x
                cp1y = current_y
              end
              
              cp2x = is_relative ? current_x + params[i] : params[i]
              cp2y = is_relative ? current_y + params[i + 1] : params[i + 1]
              x = is_relative ? current_x + params[i + 2] : params[i + 2]
              y = is_relative ? current_y + params[i + 3] : params[i + 3]
              
              commands << PathCommand::CubicBezierTo.new(cp1x, cp1y, cp2x, cp2y, x, y)
              
              last_control_x = cp2x
              last_control_y = cp2y
              current_x = x
              current_y = y
              i += 4
            end
            
          when "Q", "q"
            is_relative = (cmd == "q")
            i = 0
            while i + 3 < params.size
              cpx = is_relative ? current_x + params[i] : params[i]
              cpy = is_relative ? current_y + params[i + 1] : params[i + 1]
              x = is_relative ? current_x + params[i + 2] : params[i + 2]
              y = is_relative ? current_y + params[i + 3] : params[i + 3]
              
              commands << PathCommand::QuadraticBezierTo.new(cpx, cpy, x, y)
              
              last_control_x = cpx
              last_control_y = cpy
              current_x = x
              current_y = y
              i += 4
            end
            
          when "T", "t"
            is_relative = (cmd == "t")
            i = 0
            while i + 1 < params.size
              # 前のコマンドがQまたはTの場合、制御点は前のコマンドの制御点の反射
              if commands.last.is_a?(PathCommand::QuadraticBezierTo)
                cpx = 2 * current_x - last_control_x
                cpy = 2 * current_y - last_control_y
              else
                cpx = current_x
                cpy = current_y
              end
              
              x = is_relative ? current_x + params[i] : params[i]
              y = is_relative ? current_y + params[i + 1] : params[i + 1]
              
              commands << PathCommand::QuadraticBezierTo.new(cpx, cpy, x, y)
              
              last_control_x = cpx
              last_control_y = cpy
              current_x = x
              current_y = y
              i += 2
            end
            
          when "A", "a"
            is_relative = (cmd == "a")
            i = 0
            while i + 6 < params.size
              rx = params[i].abs
              ry = params[i + 1].abs
              x_axis_rotation = params[i + 2]
              large_arc_flag = params[i + 3] != 0
              sweep_flag = params[i + 4] != 0
              x = is_relative ? current_x + params[i + 5] : params[i + 5]
              y = is_relative ? current_y + params[i + 6] : params[i + 6]
              
              commands << PathCommand::ArcTo.new(rx, ry, x_axis_rotation, large_arc_flag, sweep_flag, x, y)
              
              current_x = x
              current_y = y
              i += 7
            end
            
          when "Z", "z"
            commands << PathCommand::ClosePath.new
            current_x = subpath_start_x
            current_y = subpath_start_y
          end
        end
        
        commands
      end
      
      private def scale_path_commands(commands : Array(PathCommand), origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64)) : Array(PathCommand)
        commands.map do |cmd|
          case cmd
          when PathCommand::MoveTo
            PathCommand::MoveTo.new(
              origin_x + cmd.x * scale[0],
              origin_y + cmd.y * scale[1]
            )
          when PathCommand::LineTo
            PathCommand::LineTo.new(
              origin_x + cmd.x * scale[0],
              origin_y + cmd.y * scale[1]
            )
          when PathCommand::ClosePath
            # ClosePath has no coordinates, just pass it through
            cmd
          else
            # Handle other command types similarly
            cmd
          end
        end
      end
    end
    
    class SVGTextElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # テキスト要素の実装
        element = @element
        
        x = parse_float_attribute(element, "x", 0.0)
        y = parse_float_attribute(element, "y", 0.0)
        
        # テキスト内容の取得
        text_content = ""
        element.children.each do |child|
          if child.is_a?(DOM::Text)
            text_content += child.data
          end
        end
        
        return if text_content.empty?
        
        # スケーリングとオフセットの適用
        scaled_x = origin_x + x * scale[0]
        scaled_y = origin_y + y * scale[1]
        
        # スタイル属性の取得
        fill = element.get_attribute("fill") || "#000000"
        font_family = element.get_attribute("font-family") || "sans-serif"
        font_size = parse_float_attribute(element, "font-size", 16.0) * ((scale[0] + scale[1]) / 2.0)
        font_weight = element.get_attribute("font-weight") || "normal"
        text_anchor = element.get_attribute("text-anchor") || "start"
        
        # アンカー位置の調整（start, middle, end）
        text_align = case text_anchor
                     when "middle" then TextAlign::Center
                     when "end"    then TextAlign::Right
                     else               TextAlign::Left
                     end
        

        context.draw_text(scaled_x, scaled_y, text_content, fill, font_family, font_size, font_weight, text_align)
      end
    end
    
    class SVGGroupElement < SVGElement
      property children : Array(SVGElement)
      
      def initialize(element : DOM::Element)
        super(element)
        @children = [] of SVGElement
        
        element.children.each do |child|
          next unless child.is_a?(DOM::Element)
          
          case child.tag_name.downcase
          when "rect"
            @children << SVGRectElement.new(child)
          when "circle"
            @children << SVGCircleElement.new(child)
          when "ellipse"
            @children << SVGEllipseElement.new(child)
          when "line"
            @children << SVGLineElement.new(child)
          when "polyline"
            @children << SVGPolylineElement.new(child)
          when "polygon"
            @children << SVGPolygonElement.new(child)
          when "path"
            @children << SVGPathElement.new(child)
          when "text"
            @children << SVGTextElement.new(child)
          when "g"
            @children << SVGGroupElement.new(child)
          end
        end
      end
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # グループのトランスフォーム属性を処理
        element = @element
        transform = element.get_attribute("transform")
        
        if transform
          # トランスフォームマトリックスの解析と適用
          context.save_state
          
          # SVG変換行列の解析
          transform_matrix = parse_transform(transform)
          
          # 変換行列を適用
          context.apply_transform(transform_matrix, origin_x, origin_y)
          
          # 子要素のレンダリング
          @children.each do |child|
            child.render(context, origin_x, origin_y, scale)
          end
          
          context.restore_state
        else
          # 通常の子要素のレンダリング
          @children.each do |child|
            child.render(context, origin_x, origin_y, scale)
          end
        end
      end
      
      # SVG変換文字列を解析して変換行列を返す
      private def parse_transform(transform : String) : TransformMatrix
        matrix = TransformMatrix.identity
        
        # 複数の変換が空白またはカンマで区切られている場合を処理
        transforms = transform.split(/\s*(?=[a-z]|\))\s*/)
        
        transforms.each do |t|
          if t =~ /matrix\s*\(\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+)\s*\)/
            a, b, c, d, e, f = $1.to_f64, $2.to_f64, $3.to_f64, $4.to_f64, $5.to_f64, $6.to_f64
            matrix = matrix.multiply(TransformMatrix.new(a, b, c, d, e, f))
          elsif t =~ /translate\s*\(\s*([\d\.\-]+)(?:\s*,?\s*([\d\.\-]+))?\s*\)/
            tx = $1.to_f64
            ty = $2 ? $2.to_f64 : 0.0
            matrix = matrix.multiply(TransformMatrix.translate(tx, ty))
          elsif t =~ /scale\s*\(\s*([\d\.\-]+)(?:\s*,?\s*([\d\.\-]+))?\s*\)/
            sx = $1.to_f64
            sy = $2 ? $2.to_f64 : sx
            matrix = matrix.multiply(TransformMatrix.scale(sx, sy))
          elsif t =~ /rotate\s*\(\s*([\d\.\-]+)(?:\s*,?\s*([\d\.\-]+)\s*,?\s*([\d\.\-]+))?\s*\)/
            angle = $1.to_f64 * Math::PI / 180.0
            if $2 && $3
              cx, cy = $2.to_f64, $3.to_f64
              # 中心点を指定した回転: translate(cx,cy) rotate(angle) translate(-cx,-cy)
              matrix = matrix.multiply(TransformMatrix.translate(cx, cy)
                                              .multiply(TransformMatrix.rotate(angle))
                                              .multiply(TransformMatrix.translate(-cx, -cy)))
            else
              matrix = matrix.multiply(TransformMatrix.rotate(angle))
            end
          elsif t =~ /skewX\s*\(\s*([\d\.\-]+)\s*\)/
            angle = $1.to_f64 * Math::PI / 180.0
            matrix = matrix.multiply(TransformMatrix.skew_x(angle))
          elsif t =~ /skewY\s*\(\s*([\d\.\-]+)\s*\)/
            angle = $1.to_f64 * Math::PI / 180.0
            matrix = matrix.multiply(TransformMatrix.skew_y(angle))
          end
        end
        
        matrix
      end
    end
    # レイアウト最適化機能
    class LayoutOptimizer
      OPTIMIZATION_THRESHOLD = 100 # この数以上の要素がある場合に最適化を適用
      
      def initialize(@layout_engine : LayoutEngine)
      end
      
      # レイアウトツリーを最適化
      def optimize(root : LayoutBox) : LayoutBox
        if count_boxes(root) > OPTIMIZATION_THRESHOLD
          apply_culling(root)
          merge_similar_boxes(root)
        end
        
        root
      end
      
      # ビューポート外のボックスをカリング（描画スキップフラグ設定）
      private def apply_culling(box : LayoutBox, viewport : {Float64, Float64, Float64, Float64}? = nil)
        # ビューポートが指定されていない場合はデフォルト値を使用
        vp = viewport || {0.0, 0.0, 10000.0, 10000.0}
        
        # ボックスがビューポート外にあるかチェック
        box_left = box.x
        box_top = box.y
        box_right = box.x + box.dimensions.margin_box_width
        box_bottom = box.y + box.dimensions.margin_box_height
        
        # ビューポート外にある場合は描画をスキップ
        if box_right < vp[0] || box_left > vp[2] || box_bottom < vp[1] || box_top > vp[3]
          box.skip_rendering = true
        else
          box.skip_rendering = false
          
          # 子要素にも適用
          box.children.each do |child|
            apply_culling(child, vp)
          end
        end
      end
      
      # 類似したボックスをマージして描画コストを削減
      private def merge_similar_boxes(box : LayoutBox)
        return if box.children.size < 2
        
        # 類似した連続するテキストノードをマージ
        i = 0
        while i < box.children.size - 1
          current = box.children[i]
          next_box = box.children[i + 1]
          
          if can_merge?(current, next_box)
            # マージ処理を実行
            merge_boxes(current, next_box)
            box.children.delete_at(i + 1)
          else
            i += 1
          end
        end
        
        # 子要素にも適用
        box.children.each do |child|
          merge_similar_boxes(child)
        end
      end
        while i < box.children.size - 1
          current = box.children[i]
          next_box = box.children[i + 1]
          
          if can_merge?(current, next_box)
            # マージ処理を実行
            merge_boxes(current, next_box)
            box.children.delete_at(i + 1)
          else
            i += 1
          end
        end
        
        # 子要素にも適用
        box.children.each do |child|
          merge_similar_boxes(child)
        end
      end
      
      private def can_merge?(box1 : LayoutBox, box2 : LayoutBox) : Bool
        # テキストノードで、同じスタイルを持つ連続するノードをマージ可能かチェック
        return false unless box1.node && box2.node
        return false unless box1.node.node_type == DOM::NodeType::TEXT_NODE && box2.node.node_type == DOM::NodeType::TEXT_NODE
        
        # スタイルをチェック（フォント、色など）
        return false unless box1.computed_style == box2.computed_style
        
        # 連続するテキストノードであることを確認（レイアウト上で隣接しているか）
        # 水平方向の連続性チェック
        horizontal_adjacent = (box1.x + box1.dimensions.margin_box_width).approximately_equals?(box2.x, epsilon: 0.5)
        
        # 垂直方向の位置が同じであることを確認
        vertical_aligned = box1.y.approximately_equals?(box2.y, epsilon: 0.5)
        
        # 同じ行にあるテキストノードであることを確認
        same_line = box1.dimensions.content_height.approximately_equals?(box2.dimensions.content_height, epsilon: 1.0)
        
        # 同じ親要素に属していることを確認
        same_parent = box1.parent == box2.parent
        
        # 両方のボックスが表示されていることを確認
        both_visible = !box1.skip_rendering && !box2.skip_rendering
        
        # テキストの向きが同じであることを確認
        same_direction = box1.computed_style.try(&.text_direction) == box2.computed_style.try(&.text_direction)
        
        # 全ての条件を満たす場合のみマージ可能
        horizontal_adjacent && vertical_aligned && same_line && same_parent && both_visible && same_direction
      end
      private def merge_boxes(box1 : LayoutBox, box2 : LayoutBox)
        # テキストノードの内容をマージ
    
    # これらの新しいクラスをLayoutEngineで使用するためのメソッド
    def handle_svg_element(element : DOM::Element, box : LayoutBox)
      return unless element.tag_name.downcase == "svg"
      
      svg_renderer = SVGRenderer.new
      svg_renderer.parse_svg(element)
      
      # レンダリング情報をボックスに保存
      box.svg_renderer = svg_renderer
    end
    
    def optimize_layout(root : LayoutBox)
      optimizer = LayoutOptimizer.new(self)
      optimizer.optimize(root)
    end
    
    # LayoutBoxクラスに拡張を追加
    class LayoutBox
      property svg_renderer : SVGRenderer?
      property skip_rendering : Bool = false
      
      # SVGレンダリング機能
      def render_svg(context : RenderContext)
        return unless @svg_renderer
        @svg_renderer.not_nil!.render(context, @x, @y, {dimensions.content_width, dimensions.content_height})
      end
    end
    
    abstract class RenderContext
      # 矩形塗りつぶし
      abstract def fill_rect(x : Float64, y : Float64, width : Float64, height : Float64, color : String)
      
      # 矩形枠線描画
      abstract def stroke_rect(x : Float64, y : Float64, width : Float64, height : Float64, color : String?, line_width : Float64)
      
      # 円塗りつぶし
      abstract def fill_circle(cx : Float64, cy : Float64, r : Float64, color : String)
      
      # 円枠線描画
      abstract def stroke_circle(cx : Float64, cy : Float64, r : Float64, color : String?, line_width : Float64)
      
      # パス塗りつぶし
      abstract def fill_path(commands : Array(PathCommand), color : String)
      
      # パス線描画
      abstract def stroke_path(commands : Array(PathCommand), color : String?, line_width : Float64)
      
      # テキスト描画
      abstract def draw_text(x : Float64, y : Float64, text : String, font : String, color : String)
      
      # 画像描画
      abstract def draw_image(x : Float64, y : Float64, width : Float64, height : Float64, image_data : ImageData)
      
      # グラデーション塗りつぶし
      abstract def fill_gradient(x : Float64, y : Float64, width : Float64, height : Float64, gradient : Gradient)
      
      # クリッピング領域設定
      abstract def set_clip_rect(x : Float64, y : Float64, width : Float64, height : Float64)
      
      # クリッピング領域解除
      abstract def clear_clip
      
      # 座標変換行列設定
      abstract def set_transform(a : Float64, b : Float64, c : Float64, d : Float64, e : Float64, f : Float64)
      
      # 座標変換行列リセット
      abstract def reset_transform
      
      # 透明度設定
      abstract def set_alpha(alpha : Float64)
      
      # 合成モード設定
      abstract def set_composite_operation(operation : CompositeOperation)
      
      # シャドウ設定
      abstract def set_shadow(offset_x : Float64, offset_y : Float64, blur : Float64, color : String)
      
      # 状態保存
      abstract def save
      
      # 状態復元
      abstract def restore
    end
    
    # パスコマンド用の型
    abstract class PathCommand
    end
    
    class MoveToCommand < PathCommand
      property x : Float64
      property y : Float64
      
      def initialize(@x, @y)
      end
    end
    
    class LineToCommand < PathCommand
      property x : Float64
      property y : Float64
      
      def initialize(@x, @y)
      end
    end
    
    class CurveToCommand < PathCommand
      property x1 : Float64
      property y1 : Float64
      property x2 : Float64
      property y2 : Float64
      property x : Float64
      property y : Float64
      
      def initialize(@x1, @y1, @x2, @y2, @x, @y)
      end
    end
    
    class ClosePathCommand < PathCommand
    end
    
    # パフォーマンス最適化機能
    
    # 画像キャッシュシステム
    class ImageCache
      CACHE_SIZE_LIMIT = 50 * 1024 * 1024  # 50MB
      CACHE_ENTRY_TTL = 300.0  # 5分
      
      class CacheEntry
        property data : Bytes
        property width : Int32
        property height : Int32
        property format : String
        property last_accessed : Time
        property access_count : Int32
        property size : Int32
        
        def initialize(@data, @width, @height, @format)
          @last_accessed = Time.utc
          @access_count = 1
          @size = @data.size
        end
        
        def access
          @last_accessed = Time.utc
          @access_count += 1
        end
      end
      
      property entries : Hash(String, CacheEntry)
      property total_size : Int32
      property hits : Int32
      property misses : Int32
      property last_cleanup_time : Time
      
      def initialize
        @entries = {} of String => CacheEntry
        @total_size = 0
        @hits = 0
        @misses = 0
        @last_cleanup_time = Time.utc
      end
      
      # 画像をキャッシュに保存
      def cache_image(url : String, data : Bytes, width : Int32, height : Int32, format : String) : Bool
        # キャッシュが大きすぎる場合はクリーンアップ
        cleanup if @total_size + data.size > CACHE_SIZE_LIMIT
        
        # それでも入りきらない場合は失敗
        return false if data.size > CACHE_SIZE_LIMIT
        
        # 同じURLですでにキャッシュがある場合は更新
        if @entries.has_key?(url)
          old_size = @entries[url].size
          @total_size -= old_size
        end
        
        # 新しいエントリを追加
        entry = CacheEntry.new(data, width, height, format)
        @entries[url] = entry
        @total_size += entry.size
        
        true
      end
      
      # キャッシュから画像を取得
      def get_image(url : String) : CacheEntry?
        if @entries.has_key?(url)
          @hits += 1
          @entries[url].access
          return @entries[url]
        end
        
        @misses += 1
        nil
      end
      
      # キャッシュのクリーンアップ
      def cleanup
        current_time = Time.utc
        
        # 一定時間以上アクセスがないエントリを削除
        expired_urls = [] of String
        
        @entries.each do |url, entry|
          if (current_time - entry.last_accessed).total_seconds > CACHE_ENTRY_TTL
            expired_urls << url
          end
        end
        
        expired_urls.each do |url|
          if entry = @entries.delete(url)
            @total_size -= entry.size
          end
        end
        
        # それでも大きすぎる場合はアクセス頻度の低いものから削除
        if @total_size > CACHE_SIZE_LIMIT
          sorted_entries = @entries.to_a.sort_by { |_, entry| entry.access_count }
          
          while @total_size > CACHE_SIZE_LIMIT * 0.8 && !sorted_entries.empty?
            url, entry = sorted_entries.shift
            @entries.delete(url)
            @total_size -= entry.size
          end
        end
        
        @last_cleanup_time = current_time
      end
      
      # キャッシュ統計情報
      def stats : String
        hit_rate = (@hits + @misses) > 0 ? (@hits.to_f / (@hits + @misses) * 100).round(2) : 0.0
        "Cache: #{@entries.size} entries, #{@total_size / 1024}KB used, #{hit_rate}% hit rate"
      end
    end
    
    # グラフィックスアクセラレーション管理
    class GraphicsAccelerator
      enum AccelerationType
        None
        Software
        Hardware2D
        Hardware3D
      end
      
      enum RenderingAPI
        Canvas2D
        WebGL
        WebGPU
        Native
      end
      
      property available_acceleration : AccelerationType
      property current_acceleration : AccelerationType
      property available_apis : Array(RenderingAPI)
      property current_api : RenderingAPI
      property vsync_enabled : Bool
      property max_texture_size : Int32
      property supports_multithreading : Bool
      property gpu_memory_limit : Int32?
      property feature_flags : Hash(String, Bool)
      
      def initialize
        @available_acceleration = AccelerationType::None
        @current_acceleration = AccelerationType::None
        @available_apis = [] of RenderingAPI
        @current_api = RenderingAPI::Canvas2D
        @vsync_enabled = true
        @max_texture_size = 4096
        @supports_multithreading = false
        @gpu_memory_limit = nil
        @feature_flags = {} of String => Bool
        
        detect_capabilities
      end
      
      # ハードウェアサポートの検出
      private def detect_capabilities
        # プラットフォーム固有の機能検出を実行
        platform_info = detect_platform_capabilities
        
        # 利用可能なアクセラレーションタイプを決定
        @available_acceleration = determine_acceleration_type(platform_info)
        
        # 利用可能なレンダリングAPIを検出
        @available_apis = detect_rendering_apis(platform_info)
        
        # マルチスレッドサポートを確認
        @supports_multithreading = platform_info[:supports_multithreading]
        
        # 最大テクスチャサイズを取得
        @max_texture_size = platform_info[:max_texture_size]
        
        # GPU メモリ制限を設定
        @gpu_memory_limit = platform_info[:gpu_memory_limit]
        
        # 詳細な機能フラグを設定
        setup_feature_flags(platform_info)
        
        # ハードウェア機能に基づいて最適な初期設定を適用
        apply_optimal_initial_settings
        
        # 検出結果をログに記録
        log_detected_capabilities
      end
      
      # プラットフォーム固有の機能を検出
      private def detect_platform_capabilities : Hash(Symbol, Int32 | Bool | String)
        result = {} of Symbol => Int32 | Bool | String
        
        {% if flag?(:linux) %}
          detect_linux_capabilities(result)
        {% elsif flag?(:darwin) %}
          detect_macos_capabilities(result)
        {% elsif flag?(:win32) %}
          detect_windows_capabilities(result)
        {% else %}
          # 未知のプラットフォームの場合は保守的な値を設定
          setup_conservative_capabilities(result)
        {% end %}
        
        # 共通の検出ロジック
        detect_common_capabilities(result)
        
        result
      end
      
      # アクセラレーションタイプを決定
      private def determine_acceleration_type(info : Hash(Symbol, Int32 | Bool | String)) : AccelerationType
        return AccelerationType::None unless info[:has_gpu]? == true
        
        if info[:supports_3d]? == true
          AccelerationType::Hardware3D
        elsif info[:supports_2d]? == true
          AccelerationType::Hardware2D
        elsif info[:supports_software_rendering]? == true
          AccelerationType::Software
        else
          AccelerationType::None
        end
      end
      
      # 利用可能なレンダリングAPIを検出
      private def detect_rendering_apis(info : Hash(Symbol, Int32 | Bool | String)) : Array(RenderingAPI)
        apis = [] of RenderingAPI
        
        # Canvas2Dは常に利用可能と仮定
        apis << RenderingAPI::Canvas2D
        
        # WebGLサポートを確認
        apis << RenderingAPI::WebGL if info[:supports_webgl]? == true
        
        # WebGPUサポートを確認
        apis << RenderingAPI::WebGPU if info[:supports_webgpu]? == true
        
        # ネイティブAPIサポートを確認
        apis << RenderingAPI::Native if info[:supports_native_api]? == true
        
        apis
      end
      
      # 詳細な機能フラグを設定
      private def setup_feature_flags(info : Hash(Symbol, Int32 | Bool | String))
        # 基本的なレンダリング機能
        @feature_flags["path_rendering"] = info[:path_rendering]? == true
        @feature_flags["filter_effects"] = info[:filter_effects]? == true
        @feature_flags["compositing"] = info[:compositing]? == true
        @feature_flags["image_smoothing"] = info[:image_smoothing]? == true
        
        # 高度なレンダリング機能
        @feature_flags["hdr_rendering"] = info[:hdr_support]? == true
        @feature_flags["color_management"] = info[:color_management]? == true
        @feature_flags["hardware_decoding"] = info[:hardware_decoding]? == true
        @feature_flags["subpixel_rendering"] = info[:subpixel_rendering]? == true
        @feature_flags["text_acceleration"] = info[:text_acceleration]? == true
        
        # パフォーマンス関連機能
        @feature_flags["parallel_rasterization"] = info[:parallel_rasterization]? == true
        @feature_flags["gpu_compositing"] = info[:gpu_compositing]? == true
        @feature_flags["shader_effects"] = info[:shader_effects]? == true
        @feature_flags["texture_compression"] = info[:texture_compression]? == true
        
        # 拡張機能
        @feature_flags["variable_fonts"] = info[:variable_fonts]? == true
        @feature_flags["backdrop_filter"] = info[:backdrop_filter]? == true
        @feature_flags["blend_modes"] = info[:blend_modes]? == true
      end
      
      # 最適な初期設定を適用
      private def apply_optimal_initial_settings
        # 利用可能な最高のアクセラレーションを選択
        @current_acceleration = @available_acceleration
        
        # 最適なAPIを選択（優先順位: WebGPU > WebGL > Canvas2D）
        if @available_apis.includes?(RenderingAPI::WebGPU)
          @current_api = RenderingAPI::WebGPU
        elsif @available_apis.includes?(RenderingAPI::WebGL)
          @current_api = RenderingAPI::WebGL
        else
          @current_api = RenderingAPI::Canvas2D
        end
        
        # バッテリー駆動の場合はVSyncを有効に
        @vsync_enabled = true
      end
      
      # 検出された機能をログに記録
      private def log_detected_capabilities
        Logger.debug("Graphics capabilities detected: #{@available_acceleration}")
        Logger.debug("Available APIs: #{@available_apis.join(", ")}")
        Logger.debug("Max texture size: #{@max_texture_size}px")
        Logger.debug("GPU memory: #{@gpu_memory_limit ? "#{@gpu_memory_limit / (1024 * 1024)}MB" : "Unknown"}")
        Logger.debug("Multithreading support: #{@supports_multithreading}")
        Logger.debug("Feature flags: #{@feature_flags.select { |_, v| v }.keys.join(", ")}")
      end
      # アクセラレーションの設定
      def set_acceleration(type : AccelerationType) : Bool
        return false if type > @available_acceleration
        
        @current_acceleration = type
        true
      end
      
      # レンダリングAPIの設定
      def set_api(api : RenderingAPI) : Bool
        return false unless @available_apis.includes?(api)
        
        @current_api = api
        true
      end
      
      # 描画コンテキストの最適化
      def optimize_context(context : RenderContext)
        case @current_acceleration
        when AccelerationType::Hardware2D, AccelerationType::Hardware3D
          # ハードウェアアクセラレーションの場合
          if context.responds_to?(:enable_hardware_acceleration)
            context.enable_hardware_acceleration(true)
          end
          
          if context.responds_to?(:set_vsync) && @vsync_enabled
            context.set_vsync(@vsync_enabled)
          end
        end
      end
      
      # 特定の機能がサポートされているか確認
      def supports_feature?(feature : String) : Bool
        @feature_flags[feature]? || false
      end
      
      # ハードウェアアクセラレーション情報を文字列で取得
      def info : String
        "Acceleration: #{@current_acceleration}, API: #{@current_api}, VSync: #{@vsync_enabled}, Max Texture: #{@max_texture_size}px"
      end
    end
    
    # マルチスレッドレイアウトマネージャー
    class ThreadedLayoutManager
      enum ThreadPriority
        Low
        Normal
        High
      end
      
      property enabled : Bool
      property max_threads : Int32
      property active_threads : Int32
      property thread_priority : ThreadPriority
      property task_queue : Array(-> Nil)
      property completed_tasks : Int32
      property total_tasks : Int32
      property is_running : Bool
      property thread_pool : Array(Thread)
      property task_mutex : Mutex
      property result_mutex : Mutex
      property layout_results : Hash(String, LayoutBox)
      property shutdown_signal : Bool
      property task_condition : ConditionVariable
      
      def initialize(max_threads : Int32 = 4)
        @enabled = true
        @max_threads = max_threads.clamp(1, 16)
        @active_threads = 0
        @thread_priority = ThreadPriority::Normal
        @task_queue = [] of -> Nil
        @completed_tasks = 0
        @total_tasks = 0
        @is_running = false
        @thread_pool = [] of Thread
        @task_mutex = Mutex.new
        @result_mutex = Mutex.new
        @layout_results = {} of String => LayoutBox
        @shutdown_signal = false
        @task_condition = ConditionVariable.new
        
        # スレッドプールの初期化
        initialize_thread_pool
      end
      
      # スレッドプールの初期化
      private def initialize_thread_pool
        @max_threads.times do |i|
          thread = Thread.new do
            worker_thread_function(i)
          end
          
          # スレッドの優先度設定（プラットフォーム依存）
          # set_thread_priority(thread, @thread_priority)
          
          @thread_pool << thread
        end
      end
      
      # ワーカースレッドの処理ループ
      private def worker_thread_function(thread_id : Int32)
        loop do
          task = nil
          
          # タスクの取得（スレッドセーフ）
          @task_mutex.synchronize do
            # シャットダウンシグナルが来ていたら終了
            return if @shutdown_signal
            
            # キューが空の場合は待機
            if @task_queue.empty?
              @task_condition.wait(@task_mutex)
              next
            end
            
            # タスクを取得
            task = @task_queue.shift?
            
            # アクティブスレッド数をインクリメント
            @active_threads += 1 if task
          end
          
          # タスクを実行
          if task
            begin
              # タスク実行開始時間を記録
              start_time = Time.monotonic
              
              # タスクを実行
              task.call
              
              # タスク実行時間を計算
              execution_time = Time.monotonic - start_time
              
              # パフォーマンスメトリクスの記録
              @result_mutex.synchronize do
                @task_execution_times << {thread_id: thread_id, time: execution_time}
                # 長時間実行タスクの検出（閾値を超える場合）
                if execution_time > @long_task_threshold
                  @long_running_tasks << {thread_id: thread_id, time: execution_time}
                end
              end
            rescue ex : Exception
              # 詳細なエラーログ
              @result_mutex.synchronize do
                @error_count += 1
                @errors << {
                  thread_id: thread_id,
                  error: ex.message || "不明なエラー",
                  backtrace: ex.backtrace || [] of String,
                  time: Time.utc
                }
              end
              
              # エラーハンドリングポリシーに基づいた処理
              case @error_policy
              when ErrorPolicy::Log
                Log.error { "レイアウトスレッド #{thread_id} エラー: #{ex.message}\n#{ex.backtrace.join("\n")}" }
              when ErrorPolicy::Retry
                # 再試行キューに追加（最大再試行回数を超えていない場合）
                if task.responds_to?(:retry_count) && task.retry_count < @max_retry_attempts
                  task.retry_count += 1
                  @task_mutex.synchronize do
                    @task_queue << task
                    @task_condition.signal
                  end
                end
              when ErrorPolicy::Abort
                # 重大なエラーの場合は全体の処理を中止
                @task_mutex.synchronize do
                  @shutdown_signal = true
                  @task_condition.broadcast
                end
                return
              end
            ensure
              # タスク完了後の処理（エラーがあってもなくても実行）
              @task_mutex.synchronize do
                @active_threads -= 1
                @completed_tasks += 1
                
                # すべてのタスクが完了した場合、待機中のスレッドに通知
                if @completed_tasks >= @total_tasks && @task_queue.empty?
                  @completion_condition.broadcast
                end
                
                # 負荷分散のためのタスク再分配
                redistribute_tasks if @load_balancing_enabled && @active_threads < @thread_pool.size / 2
              end
            end
          end
        end
      end
      # レイアウトタスクの分割と並列処理
      def layout_in_parallel(document : DOM::Document, callback : Proc(LayoutBox, Nil))
        return unless @enabled
        
        @task_mutex.synchronize do
          @is_running = true
          @completed_tasks = 0
          @total_tasks = 0
          @task_queue.clear
          @layout_results.clear
        end
        
        # タスクを分割（例：ボディ以下の大きなブロック要素ごと）
        if body = document.query_selector("body")
          children = body.children.select { |child| child.is_a?(DOM::Element) && is_block_element(child.as(DOM::Element)) }
          
          @task_mutex.synchronize do
            @total_tasks = children.size
          end
          
          if children.size > 0
            # 各ブロック要素のレイアウトをタスクとして登録
            children.each do |child|
              next unless child.is_a?(DOM::Element)
              element = child.as(DOM::Element)
              
              @task_mutex.synchronize do
                @task_queue << -> {
                  # 各要素のレイアウト計算
                  box = layout_element(element)
                  
                  # 結果の保存（スレッドセーフ）
                  @result_mutex.synchronize do
                    @layout_results[element.unique_id] = box
                  end
                }
              end
            end
            
            # タスクキューにタスクが追加されたことをワーカースレッドに通知
            @task_mutex.synchronize do
              @task_condition.broadcast
            end
            
            # すべてのタスクが完了するまで待機
            wait_for_completion
            
            # 結果の組み立て
            root_box = LayoutBox.new(document.document_element)
            body_box = LayoutBox.new(body)
            root_box.children << body_box
            
            # 各スレッドが計算した結果を統合
            @result_mutex.synchronize do
              children.each do |child|
                next unless child.is_a?(DOM::Element)
                element = child.as(DOM::Element)
                
                if box = @layout_results[element.unique_id]?
                  body_box.children << box
                end
              end
            end
            
            # レイアウトボックスのポジショニングを調整
            position_layout_boxes(body_box)
            
            # コールバックを呼び出し
            callback.call(root_box)
          end
        end
        
        @task_mutex.synchronize do
          @is_running = false
        end
      end
      
      # すべてのタスクが完了するまで待機
      private def wait_for_completion
        loop do
          @task_mutex.synchronize do
            # タスクキューが空でかつアクティブスレッドがない場合は完了
            if @task_queue.empty? && @active_threads == 0
              return
            end
            
            # 条件変数を使用して効率的に待機
            # タイムアウトを設定して無限ブロックを防止
            @completion_condition.wait(@task_mutex, 0.5)
          end
        end
      end
      
      # 要素がブロック要素かどうかの判定
      private def is_block_element(element : DOM::Element) : Bool
        # CSSのdisplayプロパティに基づいて判定
        computed_style = element.computed_style
        return true if computed_style && computed_style.display == "block"
        
        # コンピュートスタイルがない場合はデフォルトのブロック要素リストを使用
        block_elements = [
          "address", "article", "aside", "blockquote", "canvas", "dd", "div", 
          "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", 
          "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", 
          "nav", "noscript", "ol", "p", "pre", "section", "table", "tfoot", 
          "ul", "video"
        ]
        
        block_elements.includes?(element.tag_name.downcase)
      end
      
      # 個別の要素のレイアウト計算
      private def layout_element(element : DOM::Element) : LayoutBox
        box = LayoutBox.new(element)
        
        # ボックスタイプの決定
        box.box_type = determine_box_type(element)
        
        # マージン、ボーダー、パディングの設定
        apply_box_styles(box, element)
        
        # インライン要素の場合は特別な処理
        if box.box_type == BoxType::Inline
          layout_inline_element(box, element)
          return box
        end
        
        # フレックスボックスの場合
        if is_flexbox(element)
          layout_flexbox(box, element)
          return box
        }
        
        # グリッドの場合
        if is_grid(element)
          layout_grid(box, element)
          return box
        end
        
        # 通常のブロックレイアウト
        current_line = [] of LayoutBox
        y_offset = 0.0
        x_offset = 0.0
        max_line_height = 0.0
        
        # 子要素のレイアウト
        element.children.each do |child|
          next unless child.is_a?(DOM::Element)
          child_element = child.as(DOM::Element)
          
          # 子要素のレイアウトボックスを作成
          child_box = layout_element(child_element)
          
          # 位置決めされた要素（absolute/fixed）の場合は特別処理
          if is_positioned(child_element)
            box.positioned_children << child_box
            next
          end
          
          # フロート要素の場合は特別処理
          if is_floated(child_element)
            layout_float(box, child_box)
            next
          end
          
          # ブロック要素の場合は新しい行を開始
          if child_box.box_type == BoxType::Block
            # 現在の行のインライン要素を配置
            if !current_line.empty?
              position_inline_elements(current_line, box.dimensions.content_width, y_offset)
              y_offset += max_line_height
              current_line.clear
              max_line_height = 0.0
            end
            
            # ブロック要素を配置
            child_box.x = 0.0
            child_box.y = y_offset
            box.children << child_box
            
            # 次の要素のための位置を更新
            y_offset += child_box.dimensions.margin_box_height
          else
            # インライン要素の場合は現在の行に追加
            current_line << child_box
            max_line_height = Math.max(max_line_height, child_box.dimensions.margin_box_height)
          end
        end
        
        # 最後の行のインライン要素を配置
        if !current_line.empty?
          position_inline_elements(current_line, box.dimensions.content_width, y_offset)
          y_offset += max_line_height
        end
        
        # コンテンツの高さを設定
        if box.dimensions.content_height == 0.0 && !box.children.empty?
          box.dimensions.content_height = y_offset
        end
        
        # Z-indexに基づいて子要素をソート
        sort_children_by_z_index(box)
        
        box
      end
      
      # ボックスの寸法を計算
      private def calculate_dimensions(box : LayoutBox)
        element = box.element
        computed_style = element.computed_style
        
        # 幅の計算
        if computed_style && computed_style.width.is_a?(Length)
          box.dimensions.content_width = compute_length_value(computed_style.width, box.parent_width)
        elsif box.parent && box.box_type == BoxType::Block
          # ブロック要素はデフォルトで親の幅いっぱいに広がる
          box.dimensions.content_width = box.parent.dimensions.content_width - 
                                        box.dimensions.margin.left - 
                                        box.dimensions.margin.right - 
                                        box.dimensions.border.left - 
                                        box.dimensions.border.right - 
                                        box.dimensions.padding.left - 
                                        box.dimensions.padding.right
        else
          # インライン要素はコンテンツに合わせる
          box.dimensions.content_width = calculate_content_based_width(box)
        end
        
        # 高さの計算
        if computed_style && computed_style.height.is_a?(Length)
          box.dimensions.content_height = compute_length_value(computed_style.height, box.parent_height)
        else
          # 子要素に基づいて高さを計算
          calculate_height_from_children(box)
        end
        
        # 最小/最大幅・高さの適用
        apply_min_max_constraints(box)
        
        # ボックスサイジングモデルの適用
        apply_box_sizing(box)
        
        # マージンの自動値を解決
        resolve_auto_margins(box)
      end
      # レイアウトボックスの位置調整
      private def position_layout_boxes(box : LayoutBox)
        # 単純な縦積みレイアウト
        y_offset = 0.0
        
        box.children.each do |child|
          child.y = y_offset
          y_offset += child.dimensions.margin_box_height
          
          # 再帰的に子ボックスも調整
          position_layout_boxes(child)
        end
      end
      
      # スレッドプールのシャットダウン
      def shutdown
        @task_mutex.synchronize do
          @shutdown_signal = true
          @task_condition.broadcast
        end
        
        # すべてのスレッドが終了するのを待機
        @thread_pool.each do |thread|
          thread.join
        end
        
        @thread_pool.clear
      end
      
      # 進捗状況の取得
      def progress : Float64
        @task_mutex.synchronize do
          return 0.0 if @total_tasks == 0
          @completed_tasks.to_f / @total_tasks
        end
      end
      
      # マネージャーの状態を文字列で取得
      def status : String
        @task_mutex.synchronize do
          if @is_running
            "実行中: #{@completed_tasks}/#{@total_tasks} タスク (#{(progress * 100).round(1)}%)"
          else
            "待機中: #{@max_threads} スレッド利用可能"
          end
        end
      end
      
      # スレッド優先度の設定（プラットフォーム依存）
      private def set_thread_priority(thread : Thread, priority : ThreadPriority)
        case System.os_type
        when .linux?
          # Linuxでのスレッド優先度設定
          native_handle = thread.@handle.not_nil!.to_unsafe.as(LibC::PthreadT)
          policy = LibC::SCHED_OTHER
          param = LibC::SchedParam.new
          
          case priority
          when .high?
            param.sched_priority = 99
          when .normal?
            param.sched_priority = 50
          when .low?
            param.sched_priority = 10
          when .background?
            param.sched_priority = 1
            policy = LibC::SCHED_IDLE
          end
          
          LibC.pthread_setschedparam(native_handle, policy, pointerof(param))
        when .macos?
          # macOSでのスレッド優先度設定
          native_handle = thread.@handle.not_nil!.to_unsafe.as(LibC::PthreadT)
          policy_value = 0
          
          case priority
          when .high?
            policy_value = 66 # QOS_CLASS_USER_INTERACTIVE
          when .normal?
            policy_value = 33 # QOS_CLASS_DEFAULT
          when .low?
            policy_value = 9  # QOS_CLASS_UTILITY
          when .background?
            policy_value = 5  # QOS_CLASS_BACKGROUND
          end
          
          LibC.pthread_setqos_class_np(native_handle, policy_value, 0)
        when .windows?
          # Windowsでのスレッド優先度設定
          native_handle = thread.@handle.not_nil!.to_unsafe.as(LibC::HANDLE)
          
          priority_class = case priority
                          when .high?
                            LibC::HIGH_PRIORITY_CLASS
                          when .normal?
                            LibC::NORMAL_PRIORITY_CLASS
                          when .low?
                            LibC::BELOW_NORMAL_PRIORITY_CLASS
                          when .background?
                            LibC::IDLE_PRIORITY_CLASS
                          end
          
          LibC.SetThreadPriority(native_handle, priority_class)
        end
        
        # 優先度設定のログ記録
        Logger.debug { "スレッド優先度を設定: #{thread.object_id} => #{priority}" }
      rescue ex
        # 優先度設定に失敗してもクリティカルではないのでログだけ残す
        Logger.warn { "スレッド優先度の設定に失敗: #{ex.message}" }
      end
      
      # スレッドアフィニティの設定（マルチコアCPU最適化）
      private def set_thread_affinity(thread : Thread, core_id : Int32)
        return unless System.cpu_count > 1
        
        case System.os_type
        when .linux?
          native_handle = thread.@handle.not_nil!.to_unsafe.as(LibC::PthreadT)
          cpu_set = LibC::CpuSetT.new
          LibC.CPU_ZERO(pointerof(cpu_set))
          LibC.CPU_SET(core_id % System.cpu_count, pointerof(cpu_set))
          LibC.pthread_setaffinity_np(native_handle, sizeof(LibC::CpuSetT), pointerof(cpu_set))
        when .macos?
          # macOSはスレッドアフィニティをサポートしていないため何もしない
        when .windows?
          native_handle = thread.@handle.not_nil!.to_unsafe.as(LibC::HANDLE)
          mask = 1_u64 << (core_id % System.cpu_count)
          LibC.SetThreadAffinityMask(native_handle, mask)
        end
      rescue ex
        Logger.warn { "スレッドアフィニティの設定に失敗: #{ex.message}" }
      end
    end
    # パフォーマンス測定システム
    class LayoutPerformanceMonitor
      class LayoutMetrics
        property start_time : Time
        property end_time : Time?
        property dom_size : Int32
        property layout_boxes : Int32
        property style_calculations : Int32
        property dom_traversal_time : Float64
        property style_calculation_time : Float64
        property box_generation_time : Float64
        property positioning_time : Float64
        property render_preparation_time : Float64
        property peak_memory_usage : Int64
        
        def initialize
          @start_time = Time.utc
          @end_time = nil
          @dom_size = 0
          @layout_boxes = 0
          @style_calculations = 0
          @dom_traversal_time = 0.0
          @style_calculation_time = 0.0
          @box_generation_time = 0.0
          @positioning_time = 0.0
          @render_preparation_time = 0.0
          @peak_memory_usage = 0_i64
        end
        
        # 合計処理時間の計算
        def total_time : Float64
          return 0.0 unless @end_time
          (@end_time.not_nil! - @start_time).total_milliseconds
        end
        
        # レイアウト効率の計算
        def layout_efficiency : Float64
          return 0.0 if total_time == 0.0 || @layout_boxes == 0
          @dom_size.to_f / (@layout_boxes * total_time / 1000.0)
        end
        
        # 文字列形式のレポート生成
        def report : String
          report = "Layout Performance:\n"
          report += "- DOM Size: #{@dom_size} nodes\n"
          report += "- Layout Boxes: #{@layout_boxes} boxes\n"
          report += "- Style Calculations: #{@style_calculations}\n"
          report += "- Total Time: #{total_time.round(2)}ms\n"
          report += "- DOM Traversal: #{@dom_traversal_time.round(2)}ms (#{(@dom_traversal_time / total_time * 100).round(1)}%)\n"
          report += "- Style Calculation: #{@style_calculation_time.round(2)}ms (#{(@style_calculation_time / total_time * 100).round(1)}%)\n"
          report += "- Box Generation: #{@box_generation_time.round(2)}ms (#{(@box_generation_time / total_time * 100).round(1)}%)\n"
          report += "- Positioning: #{@positioning_time.round(2)}ms (#{(@positioning_time / total_time * 100).round(1)}%)\n"
          report += "- Render Prep: #{@render_preparation_time.round(2)}ms (#{(@render_preparation_time / total_time * 100).round(1)}%)\n"
          report += "- Peak Memory: #{@peak_memory_usage / 1024}KB\n"
          report += "- Efficiency: #{layout_efficiency.round(2)} nodes/box/sec\n"
          report
        end
      end
      
      property enabled : Bool
      property current_metrics : LayoutMetrics?
      property history : Array(LayoutMetrics)
      property history_limit : Int32
      
      def initialize
        @enabled = true
        @current_metrics = nil
        @history = [] of LayoutMetrics
        @history_limit = 10
      end
      
      # 測定の開始
      def start_measurement : LayoutMetrics
        metrics = LayoutMetrics.new
        @current_metrics = metrics
        metrics
      end
      
      # 測定の終了
      def end_measurement : LayoutMetrics?
        return nil unless @current_metrics
        
        metrics = @current_metrics.not_nil!
        metrics.end_time = Time.utc
        
        # 履歴に追加
        @history << metrics
        @history.shift if @history.size > @history_limit
        
        @current_metrics = nil
        metrics
      end
      
      # 特定のフェーズの開始
      def start_phase(phase : Symbol) : Time
        start_time = Time.utc
        
        if @current_metrics && @enabled
          # 将来的にフェーズの入れ子を追跡する場合はここを拡張
        end
        
        start_time
      end
      
      # 特定のフェーズの終了
      def end_phase(phase : Symbol, start_time : Time) : Nil
        return unless @current_metrics && @enabled
        
        duration = (Time.utc - start_time).total_milliseconds
        
        case phase
        when :dom_traversal
          @current_metrics.not_nil!.dom_traversal_time += duration
        when :style_calculation
          @current_metrics.not_nil!.style_calculation_time += duration
        when :box_generation
          @current_metrics.not_nil!.box_generation_time += duration
        when :positioning
          @current_metrics.not_nil!.positioning_time += duration
        when :render_preparation
          @current_metrics.not_nil!.render_preparation_time += duration
        end
      end
      
      # DOM要素数の記録
      def record_dom_size(size : Int32) : Nil
        return unless @current_metrics && @enabled
        @current_metrics.not_nil!.dom_size = size
      end
      
      # ボックス生成数の記録
      def record_box_count(count : Int32) : Nil
        return unless @current_metrics && @enabled
        @current_metrics.not_nil!.layout_boxes = count
      end
      
      # スタイル計算数の記録
      def record_style_calculations(count : Int32) : Nil
        return unless @current_metrics && @enabled
        @current_metrics.not_nil!.style_calculations = count
      end
      
      # メモリ使用量の記録
      def record_memory_usage(bytes : Int64) : Nil
        return unless @current_metrics && @enabled
        
        current = @current_metrics.not_nil!
        current.peak_memory_usage = bytes if bytes > current.peak_memory_usage
      end
      
      # 最新のメトリクスを取得
      def latest_metrics : LayoutMetrics?
        @history.last?
      end
      
      # 平均パフォーマンスの計算
      def average_metrics : LayoutMetrics?
        return nil if @history.empty?
        
        avg = LayoutMetrics.new
        total = @history.size
        
        @history.each do |metrics|
          avg.dom_size += metrics.dom_size
          avg.layout_boxes += metrics.layout_boxes
          avg.style_calculations += metrics.style_calculations
          avg.dom_traversal_time += metrics.dom_traversal_time
          avg.style_calculation_time += metrics.style_calculation_time
          avg.box_generation_time += metrics.box_generation_time
          avg.positioning_time += metrics.positioning_time
          avg.render_preparation_time += metrics.render_preparation_time
          avg.peak_memory_usage = Math.max(avg.peak_memory_usage, metrics.peak_memory_usage)
        end
        
        avg.dom_size /= total
        avg.layout_boxes /= total
        avg.style_calculations /= total
        avg.dom_traversal_time /= total
        avg.style_calculation_time /= total
        avg.box_generation_time /= total
        avg.positioning_time /= total
        avg.render_preparation_time /= total
        
        avg
      end
    end
    
    # メインレイアウトエンジンクラスに新機能を追加
    property image_cache : ImageCache
    property graphics_accelerator : GraphicsAccelerator
    property threaded_layout_manager : ThreadedLayoutManager
    property performance_monitor : LayoutPerformanceMonitor
    
    # 初期化メソッドの拡張
    def initialize(@config : Config::CoreConfig)
      @style_resolver = StyleResolver.new([] of Stylesheet)
      @viewport_width = 800.0
      @viewport_height = 600.0
      @device_pixel_ratio = 1.0
      @root_stacking_context = nil
      @logger = Log.for("quantum_core.layout_engine")
      
      # 既存の機能の初期化
      @animation_manager = AnimationManager.new
      @i18n_renderer = I18nTextRenderer.new
      @high_dpi_support = HighDPISupport.new(@device_pixel_ratio)
      @accessibility_support = AccessibilitySupport.new
      @media_query_cache = {} of String => Bool
      @is_print_mode = false
      
      # 新機能の初期化
      @image_cache = ImageCache.new
      @graphics_accelerator = GraphicsAccelerator.new
      @threaded_layout_manager = ThreadedLayoutManager.new(@config.max_layout_threads || 4)
      @performance_monitor = LayoutPerformanceMonitor.new
    end
    
    # パフォーマンス監視付きレイアウト処理
    def layout_with_monitoring(document : Document) : LayoutBox
      return layout(document) unless @performance_monitor.enabled
      
      metrics = @performance_monitor.start_measurement
      
      # DOM要素数の計測
      dom_size = count_dom_elements(document)
      @performance_monitor.record_dom_size(dom_size)
      
      # DOM走査フェーズ
      dom_start = @performance_monitor.start_phase(:dom_traversal)
      stylesheets = collect_stylesheets(document)
      @style_resolver = StyleResolver.new(stylesheets)
      @performance_monitor.end_phase(:dom_traversal, dom_start)
      
      # ボックス生成フェーズ
      box_start = @performance_monitor.start_phase(:box_generation)
      
      root_box = if @threaded_layout_manager.enabled && dom_size > 100
                  # 並列処理版
                  layout_result = nil
                  @threaded_layout_manager.layout_in_parallel(document) do |result|
                    layout_result = result
                  end
                  layout_result || build_layout_tree(document.document_element)
                else
                  # 通常の処理
                  build_layout_tree(document.document_element)
                end
      
      @performance_monitor.end_phase(:box_generation, box_start)
      
      # ボックス数の記録
      box_count = count_layout_boxes(root_box)
      @performance_monitor.record_box_count(box_count)
      
      # 配置フェーズ
      position_start = @performance_monitor.start_phase(:positioning)
      perform_layout(root_box)
      @performance_monitor.end_phase(:positioning, position_start)
      
      # レンダリング準備フェーズ
      render_prep_start = @performance_monitor.start_phase(:render_preparation)
      optimize_layout(root_box)
      @performance_monitor.end_phase(:render_preparation, render_prep_start)
      
      @performance_monitor.end_measurement
      
      root_box
    end
    
    # DOM要素数のカウント
    private def count_dom_elements(document : Document) : Int32
      count = 0
      
      traverse = ->(node : DOM::Node) {
        count += 1 if node.is_a?(DOM::Element)
        
        node.children.each do |child|
          traverse.call(child)
        end
      }
      
      traverse.call(document)
      count
    end
    
    # レイアウトボックス数のカウント
    private def count_layout_boxes(root : LayoutBox) : Int32
      count = 1
      
      root.children.each do |child|
        count += count_layout_boxes(child)
      end
      
      count
    end
    
    # 画像のプリロード処理
    # @param urls [Array(String)] プリロードする画像URLの配列
    # @param priority [Symbol] プリロードの優先度 (:high, :medium, :low)
    # @param callback [Proc(String, Image, Nil)?] 画像ロード完了時のコールバック
    # @return [Nil]
    def preload_images(urls : Array(String), priority : Symbol = :medium, callback : Proc(String, Image, Nil)? = nil) : Nil
      return if urls.empty?
      
      # プリロードキューの作成
      preload_queue = urls.reject { |url| @image_cache.get_image(url) }
      
      # 優先度に基づいてスレッドプール設定を調整
      thread_count = case priority
                     when :high
                       @threaded_layout_manager.max_threads
                     when :medium
                       (@threaded_layout_manager.max_threads / 2).max(1)
                     when :low
                       1
                     else
                       2
                     end
      
      # プリロード統計の初期化
      preload_stats = {
        requested: preload_queue.size,
        cached: urls.size - preload_queue.size,
        completed: 0,
        failed: 0
      }
      
      # 空のキューの場合は早期リターン
      return if preload_queue.empty?
      
      # プリロード開始をログに記録
      @logger.debug { "画像プリロード開始: #{preload_queue.size}個の画像, 優先度: #{priority}" }
      
      # スレッドプールの作成
      preload_pool = ThreadPool.new(thread_count)
      
      # 各URLに対してプリロードタスクを作成
      preload_queue.each do |url|
        preload_pool.spawn do
          begin
            # 画像のロード処理
            image = @resource_loader.load_image(url, priority: priority)
            
            # キャッシュに保存
            @image_cache.store_image(url, image)
            
            # 統計情報の更新（スレッドセーフな方法で）
            @mutex.synchronize { preload_stats[:completed] += 1 }
            
            # コールバックがあれば実行
            callback.try &.call(url, image)
            
            # 進捗ログ
            if preload_stats[:completed] % 10 == 0 || preload_stats[:completed] == preload_queue.size
              @logger.debug { "画像プリロード進捗: #{preload_stats[:completed]}/#{preload_queue.size}" }
            end
          rescue ex : Exception
            # エラー処理
            @mutex.synchronize { preload_stats[:failed] += 1 }
            @logger.error { "画像プリロード失敗: #{url} - #{ex.message}" }
          end
        end
      end
      
      # 非同期処理のため、即座にリターン
      # 必要に応じて、ここでpreload_pool.waitを呼び出して同期処理にすることも可能
    end
    
    # グラフィックスハードウェア情報のログ出力
    def log_graphics_info : Nil
      @logger.info { "Graphics: #{@graphics_accelerator.info}" }
      @logger.info { "Image Cache: #{@image_cache.stats}" }
    end
    
    # スレッド設定の更新
    def update_threading_config(enabled : Bool, max_threads : Int32) : Nil
      @threaded_layout_manager.enabled = enabled
      @threaded_layout_manager.max_threads = max_threads.clamp(1, 16)
    end
  end
end 