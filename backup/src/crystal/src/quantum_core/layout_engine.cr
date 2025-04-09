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
        # 簡略化したベジェ曲線の実装
        # 実際のブラウザではより正確な実装が必要
        cx = 3.0 * x1
        bx = 3.0 * (x2 - x1) - cx
        ax = 1.0 - cx - bx
        
        cy = 3.0 * y1
        by = 3.0 * (y2 - y1) - cy
        ay = 1.0 - cy - by
        
        # y値を求める（tをx値として使用）
        ((ay * t + by) * t + cy) * t
      end
      
      # アニメーションの更新
      def update(delta_time : Float64) : Nil
        return if @play_state != "running"
        
        @current_time += delta_time
        
        # ディレイ中は何もしない
        return if @current_time < @delay
        
        # 実際の経過時間（ディレイを除く）
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
        
        # 実際の経過時間（ディレイを除く）
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
        # 簡略化したベジェ曲線の実装
        # 実際のブラウザではより正確な実装が必要
        cx = 3.0 * x1
        bx = 3.0 * (x2 - x1) - cx
        ax = 1.0 - cx - bx
        
        cy = 3.0 * y1
        by = 3.0 * (y2 - y1) - cy
        ay = 1.0 - cy - by
        
        # y値を求める（tをx値として使用）
        ((ay * t + by) * t + cy) * t
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
        # アニメーションとトランジションの両方が適用されている場合は、
        # 後に開始したものを優先（簡略化した実装）
        
        current_value = base_value
        
        # アニメーションの確認
        if animations = @animations[box]?
          animations.each do |animation|
            if animation.property_name == property_name
              progress = animation.current_progress
              if progress > 0.0 || animation.fill_mode == "backwards" || animation.fill_mode == "both"
                current_value = animation.interpolate(progress)
              end
            end
          end
        end
        
        # トランジションの確認
        if transitions = @transitions[box]?
          transitions.each do |transition|
            if transition.property_name == property_name && transition.is_running
              current_value = transition.update(@current_time)
            end
          end
        end
        
        current_value
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
        # 簡略化した実装
        # 実際のブラウザではUnicode Bidirectional Algorithmを実装する必要がある
        
        # RTLマーカーを含むかどうかをチェック
        contains_rtl = text.includes?("\u200F") || text.matches?(/[\u0591-\u07FF\uFB1D-\uFDFF\uFE70-\uFEFC]/)
        
        if contains_rtl
          # RTLマーカーを含む場合、文字を反転（簡略化した実装）
          if base_direction == TextDirection::LTR
            # LTR文脈でのRTLテキスト
            process_mixed_direction_text(text)
          else
            # RTL文脈
            text
          end
        else
          # RTLマーカーを含まない場合、そのまま返す
          text
        end
      end
      
      # 混合方向テキストの処理
      private def process_mixed_direction_text(text : String) : String
        # 簡略化した実装
        # 実際のブラウザではより複雑なアルゴリズムが必要
        
        # 単語単位で分割
        words = text.split(/\s+/)
        
        # 各単語の方向を判定して処理
        processed_words = words.map do |word|
          if word.matches?(/[\u0591-\u07FF\uFB1D-\uFDFF\uFE70-\uFEFC]/)
            # RTL文字を含む単語
            "\u200F#{word}\u200F"
          else
            # LTR文字の単語
            "\u200E#{word}\u200E"
          end
        end
        
        # 単語を結合して返す
        processed_words.join(" ")
      end
      
      # ハイフネーション処理
      def hyphenate(text : String, max_width : Float64, font_metrics : FontMetrics) : String
        return text unless @hyphenation_enabled
        
        # 簡略化したハイフネーション
        # 実際のブラウザではより高度な言語固有のアルゴリズムが必要
        
        # 単語単位で分割
        words = text.split(/\s+/)
        
        # 各単語をハイフネーション処理
        hyphenated_words = words.map do |word|
          if word.size > 6 && font_metrics.calculate_text_width(word) > max_width
            # 単語の中央付近でハイフンを挿入（簡略化）
            middle = word.size / 2
            "#{word[0...middle]}-#{word[middle..]}"
          else
            word
          end
        end
        
        # 単語を結合して返す
        hyphenated_words.join(" ")
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
      
      # 外部スタイルシートとインラインスタイルの処理
      document.query_selector_all("link[rel=stylesheet], style").each do |elem|
        case elem.tag_name.downcase
        when "link"
          # 外部スタイルシートのメディアクエリの確認
          media_attr = elem.get_attribute("media") || "all"
          
          if media_attr == "all" || evaluate_media_query(media_attr)
            # メディアクエリに一致する場合のみ追加
            if href = elem.get_attribute("href")
              # 実際の実装ではネットワークからスタイルシートを取得する処理が必要
              # 簡略化のため、ここではスキップ
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
                filtered_rules = [] of StyleRule
                
                author_sheet.rules.each do |rule|
                  if rule.media_query.nil? || rule.media_query.empty? || evaluate_media_query(rule.media_query)
                    filtered_rules << rule
                  end
                end
                
                author_sheet.rules = filtered_rules
                sheets << author_sheet
              rescue ex
                @logger.error { "スタイルシート解析エラー: #{ex.message}" }
              end
            end
          end
        end
      end
      
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
          # 変換を適用（簡略化）
          return {x, y} # 実際の実装ではここで変換を適用
        end
        
        {x * scale[0], y * scale[1]}
      end
      
      abstract def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
    end
    
    class SVGRectElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        x = (@element.get_attribute("x") || "0").to_f64
        y = (@element.get_attribute("y") || "0").to_f64
        width = (@element.get_attribute("width") || "0").to_f64
        height = (@element.get_attribute("height") || "0").to_f64
        rx = (@element.get_attribute("rx") || "0").to_f64
        ry = (@element.get_attribute("ry") || "0").to_f64
        
        # 座標変換
        scaled_x = origin_x + x * scale[0]
        scaled_y = origin_y + y * scale[1]
        scaled_width = width * scale[0]
        scaled_height = height * scale[1]
        scaled_rx = rx * scale[0]
        scaled_ry = ry * scale[1]
        
        # スタイル設定
        fill = @style["fill"]? || "black"
        stroke = @style["stroke"]?
        stroke_width = (@style["stroke-width"]? || "1").to_f64 * Math.min(scale[0], scale[1])
        
        # 実際のレンダリング
        context.fill_rect(scaled_x, scaled_y, scaled_width, scaled_height, fill) if fill != "none"
        context.stroke_rect(scaled_x, scaled_y, scaled_width, scaled_height, stroke, stroke_width) if stroke && stroke != "none"
      end
    end
    
    class SVGCircleElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        cx = (@element.get_attribute("cx") || "0").to_f64
        cy = (@element.get_attribute("cy") || "0").to_f64
        r = (@element.get_attribute("r") || "0").to_f64
        
        # 座標変換
        scaled_cx = origin_x + cx * scale[0]
        scaled_cy = origin_y + cy * scale[1]
        scaled_r = r * Math.min(scale[0], scale[1])
        
        # スタイル設定
        fill = @style["fill"]? || "black"
        stroke = @style["stroke"]?
        stroke_width = (@style["stroke-width"]? || "1").to_f64 * Math.min(scale[0], scale[1])
        
        # 実際のレンダリング
        context.fill_circle(scaled_cx, scaled_cy, scaled_r, fill) if fill != "none"
        context.stroke_circle(scaled_cx, scaled_cy, scaled_r, stroke, stroke_width) if stroke && stroke != "none"
      end
    end
    
    class SVGEllipseElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 楕円要素の実装
        element = @element
        
        cx = parse_float_attribute(element, "cx", 0.0)
        cy = parse_float_attribute(element, "cy", 0.0)
        rx = parse_float_attribute(element, "rx", 0.0)
        ry = parse_float_attribute(element, "ry", 0.0)
        
        return if rx <= 0.0 || ry <= 0.0
        
        # スケーリングとオフセットの適用
        scaled_cx = origin_x + cx * scale[0]
        scaled_cy = origin_y + cy * scale[1]
        scaled_rx = rx * scale[0]
        scaled_ry = ry * scale[1]
        
        # スタイル属性の取得
        fill = element.get_attribute("fill") || "#000000"
        stroke = element.get_attribute("stroke")
        stroke_width = parse_float_attribute(element, "stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # 実際のレンダリング
        context.fill_ellipse(scaled_cx, scaled_cy, scaled_rx, scaled_ry, fill) if fill != "none"
        context.stroke_ellipse(scaled_cx, scaled_cy, scaled_rx, scaled_ry, stroke, stroke_width) if stroke && stroke != "none"
      end
    end
    
    class SVGLineElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 線要素の実装
        element = @element
        
        x1 = parse_float_attribute(element, "x1", 0.0)
        y1 = parse_float_attribute(element, "y1", 0.0)
        x2 = parse_float_attribute(element, "x2", 0.0)
        y2 = parse_float_attribute(element, "y2", 0.0)
        
        # スケーリングとオフセットの適用
        scaled_x1 = origin_x + x1 * scale[0]
        scaled_y1 = origin_y + y1 * scale[1]
        scaled_x2 = origin_x + x2 * scale[0]
        scaled_y2 = origin_y + y2 * scale[1]
        
        # スタイル属性の取得
        stroke = element.get_attribute("stroke") || "#000000"
        stroke_width = parse_float_attribute(element, "stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # 実際のレンダリング
        context.draw_line(scaled_x1, scaled_y1, scaled_x2, scaled_y2, stroke, stroke_width) if stroke && stroke != "none"
      end
    end
    
    class SVGPolylineElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 折れ線要素の実装
        element = @element
        
        points_str = element.get_attribute("points") || ""
        return if points_str.empty?
        
        # 座標点の解析
        points = parse_points(points_str)
        return if points.size < 2
        
        # スタイル属性の取得
        stroke = element.get_attribute("stroke") || "#000000"
        stroke_width = parse_float_attribute(element, "stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        fill = element.get_attribute("fill")
        
        # 座標点のスケーリングとオフセット適用
        scaled_points = points.map do |point|
          {origin_x + point[0] * scale[0], origin_y + point[1] * scale[1]}
        end
        
        # 実際のレンダリング
        if fill && fill != "none"
          context.fill_polygon(scaled_points, fill)
        end
        
        if stroke && stroke != "none"
          context.draw_polyline(scaled_points, stroke, stroke_width)
        end
      end
      
      private def parse_points(points_str : String) : Array(Tuple(Float64, Float64))
        result = [] of Tuple(Float64, Float64)
        
        # カンマまたは空白で区切られた座標文字列を解析
        coords = points_str.split(/[\s,]+/).reject(&.empty?).map(&.to_f)
        
        # 座標ペアを構築
        i = 0
        while i + 1 < coords.size
          result << {coords[i], coords[i + 1]}
          i += 2
        end
        
        result
      end
    end
    
    class SVGPolygonElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # 多角形要素の実装（ポリラインと同様だが、常に閉じた形状）
        element = @element
        
        points_str = element.get_attribute("points") || ""
        return if points_str.empty?
        
        # 座標点の解析
        points = parse_points(points_str)
        return if points.size < 3
        
        # スタイル属性の取得
        fill = element.get_attribute("fill") || "#000000"
        stroke = element.get_attribute("stroke")
        stroke_width = parse_float_attribute(element, "stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # 座標点のスケーリングとオフセット適用
        scaled_points = points.map do |point|
          {origin_x + point[0] * scale[0], origin_y + point[1] * scale[1]}
        end
        
        # 実際のレンダリング
        context.fill_polygon(scaled_points, fill) if fill != "none"
        context.draw_polygon(scaled_points, stroke, stroke_width) if stroke && stroke != "none"
      end
      
      private def parse_points(points_str : String) : Array(Tuple(Float64, Float64))
        result = [] of Tuple(Float64, Float64)
        
        # カンマまたは空白で区切られた座標文字列を解析
        coords = points_str.split(/[\s,]+/).reject(&.empty?).map(&.to_f)
        
        # 座標ペアを構築
        i = 0
        while i + 1 < coords.size
          result << {coords[i], coords[i + 1]}
          i += 2
        end
        
        result
      end
    end
    
    class SVGPathElement < SVGElement
      def render(context : RenderContext, origin_x : Float64, origin_y : Float64, scale : Tuple(Float64, Float64))
        # パス要素の実装
        element = @element
        
        d = element.get_attribute("d") || ""
        return if d.empty?
        
        # スタイル属性の取得
        fill = element.get_attribute("fill") || "#000000"
        stroke = element.get_attribute("stroke")
        stroke_width = parse_float_attribute(element, "stroke-width", 1.0) * ((scale[0] + scale[1]) / 2.0)
        
        # パスコマンドの解析と実行
        path_commands = parse_path_commands(d)
        
        # 実際のレンダリング
        if path_commands.size > 0
          # スケーリングを適用したパスコマンドを生成
          scaled_commands = scale_path_commands(path_commands, origin_x, origin_y, scale)
          
          # パスのレンダリング
          context.fill_path(scaled_commands, fill) if fill != "none"
          context.stroke_path(scaled_commands, stroke, stroke_width) if stroke && stroke != "none"
        end
      end
      
      private def parse_path_commands(d : String) : Array(PathCommand)
        commands = [] of PathCommand
        # SVGパス文法の解析（実際の実装では複雑なパーサーが必要）
        # ここではシンプルな実装のみを示す
        
        # パスコマンド文字列を解析
        segments = d.scan(/([MLHVCSQTAZmlhvcsqtaz])([^MLHVCSQTAZmlhvcsqtaz]*)/)
        
        current_x = 0.0
        current_y = 0.0
        
        segments.each do |segment|
          cmd = segment[1]
          params_str = segment[2].strip
          params = params_str.split(/[\s,]+/).reject(&.empty?).map(&.to_f)
          
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
            
          when "Z", "z"
            commands << PathCommand::ClosePath.new
            
          # 曲線コマンド（Bezier, Arc等）は複雑なので、実際の実装ではさらに追加
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
        
        # 実際のレンダリング
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
          # 実際の実装では行列変換の処理が必要
          # ここでは簡略化
          context.save_state
          
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
      
      private def can_merge?(box1 : LayoutBox, box2 : LayoutBox) : Bool
        # テキストノードで、同じスタイルを持つ連続するノードをマージ可能かチェック
        return false unless box1.node && box2.node
        return false unless box1.node.node_type == DOM::NodeType::TEXT_NODE && box2.node.node_type == DOM::NodeType::TEXT_NODE
        
        # スタイルをチェック（フォント、色など）
        # 簡略化のため、完全一致の場合のみマージ可能とする
        box1.computed_style == box2.computed_style
      end
      
      private def merge_boxes(box1 : LayoutBox, box2 : LayoutBox)
        # テキストノードの内容をマージ
        if box1.node && box2.node && box1.node.node_type == DOM::NodeType::TEXT_NODE && box2.node.node_type == DOM::NodeType::TEXT_NODE
          text_node1 = box1.node.as(DOM::Text)
          text_node2 = box2.node.as(DOM::Text)
          text_node1.data += text_node2.data
        end
        
        # ディメンションを調整
        box1.dimensions.content_width += box2.dimensions.content_width
      end
      
      private def count_boxes(box : LayoutBox) : Int32
        count = 1 # 自分自身
        box.children.each do |child|
          count += count_boxes(child)
        end
        count
      end
    end
    
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
    
    # レンダリングコンテキストインターフェース（実際の実装はレンダラーで行う）
    abstract class RenderContext
      abstract def fill_rect(x : Float64, y : Float64, width : Float64, height : Float64, color : String)
      abstract def stroke_rect(x : Float64, y : Float64, width : Float64, height : Float64, color : String?, line_width : Float64)
      abstract def fill_circle(cx : Float64, cy : Float64, r : Float64, color : String)
      abstract def stroke_circle(cx : Float64, cy : Float64, r : Float64, color : String?, line_width : Float64)
      abstract def fill_path(commands : Array(PathCommand), color : String)
      abstract def stroke_path(commands : Array(PathCommand), color : String?, line_width : Float64)
      abstract def draw_text(x : Float64, y : Float64, text : String, font : String, color : String)
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
        # 実際のプラットフォームによって実装が異なる
        # 簡略化のためにハードウェアアクセラレーションがあると仮定
        
        @available_acceleration = AccelerationType::Hardware2D
        @available_apis = [RenderingAPI::Canvas2D, RenderingAPI::WebGL]
        @supports_multithreading = true
        @max_texture_size = 8192
        @gpu_memory_limit = 512 * 1024 * 1024 # 512MB
        
        # 機能フラグを設定
        @feature_flags["path_rendering"] = true
        @feature_flags["filter_effects"] = true
        @feature_flags["compositing"] = true
        @feature_flags["image_smoothing"] = true
        @feature_flags["hdr_rendering"] = false
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
              task.call
            rescue ex
              # エラーログ（実際の実装ではより詳細に）
              puts "Layout thread #{thread_id} error: #{ex.message}"
            end
            
            # タスク完了後の処理
            @task_mutex.synchronize do
              @active_threads -= 1
              @completed_tasks += 1
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
          sleep 0.01 # シンプルなポーリング（実際の実装では条件変数を使用）
          
          completed = false
          @task_mutex.synchronize do
            completed = @task_queue.empty? && @active_threads == 0
          end
          
          break if completed
        end
      end
      
      # 要素がブロック要素かどうかの判定
      private def is_block_element(element : DOM::Element) : Bool
        # 単純化された実装（実際にはスタイル計算に基づく）
        block_elements = ["div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "form", "section", "article", "header", "footer", "main", "nav", "aside"]
        block_elements.includes?(element.tag_name.downcase)
      end
      
      # 個別の要素のレイアウト計算
      private def layout_element(element : DOM::Element) : LayoutBox
        # 実際のレイアウト計算を行う
        box = LayoutBox.new(element)
        
        # 子要素のレイアウト
        element.children.each do |child|
          next unless child.is_a?(DOM::Element)
          child_box = layout_element(child.as(DOM::Element))
          box.children << child_box
        end
        
        # ここで実際の寸法計算を行う（単純化）
        # 実際の実装ではCSSに基づいて複雑な計算を行う
        calculate_dimensions(box)
        
        box
      end
      
      # ボックスの寸法を計算
      private def calculate_dimensions(box : LayoutBox)
        # 単純化された寸法計算（実際にはCSSに基づく）
        box.dimensions.content_width = 100.0
        box.dimensions.content_height = 20.0
        
        # 子ボックスの配置
        y_offset = 0.0
        box.children.each do |child|
          child.x = 0.0
          child.y = y_offset
          y_offset += child.dimensions.margin_box_height
        end
        
        # 親ボックスのサイズを子ボックスに基づいて調整
        if box.children.size > 0
          max_width = box.children.max_of { |child| child.x + child.dimensions.margin_box_width }
          max_height = y_offset
          
          box.dimensions.content_width = max_width
          box.dimensions.content_height = max_height
        end
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
        # 実際の実装ではプラットフォーム固有のAPIを使用
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
    
    # 画像のプリロード
    def preload_images(urls : Array(String)) : Nil
      urls.each do |url|
        # すでにキャッシュにある場合はスキップ
        next if @image_cache.get_image(url)
        
        # 実際のプリロード処理（実装は省略）
        # 実際にはネットワークリクエストや非同期処理が必要
      end
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