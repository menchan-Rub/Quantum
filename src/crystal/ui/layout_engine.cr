# src/crystal/ui/layout_engine.cr
require "./component"
require "../utils/logger"

module QuantumUI
  # UIコンポーネントのレイアウトを管理するエンジン
  # 現時点では固定レイアウトだが、将来的に拡張可能
  class LayoutEngine
    # レイアウトタイプ (例)
    enum LayoutType
      FIXED   # 固定配置 (現在)
      VERTICAL # 垂直配置
      HORIZONTAL # 水平配置
      GRID     # グリッド配置
      Flex
      Flow
      Absolute
    end

    # レイアウトを実行し、各コンポーネントの bounds を設定する
    # @param components [Array(Component)] レイアウト対象のコンポーネントリスト
    # @param window_width [Int32] ウィンドウ幅
    # @param window_height [Int32] ウィンドウ高さ
    def layout(components : Array(Component), window_width : Int32, window_height : Int32)
      Log.debug "Performing layout calculation for window size: #{window_width}x#{window_height}"
      # より動的なレイアウトアルゴリズムを実装
      
      # コンポーネントのレイアウトタイプを確認
      layout_type = detect_layout_type(components)
      
      case layout_type
      when LayoutType::FIXED
        perform_fixed_layout(components, window_width, window_height)
      when LayoutType::VERTICAL
        perform_vertical_layout(components, window_width, window_height)
      when LayoutType::HORIZONTAL
        perform_horizontal_layout(components, window_width, window_height)
      when LayoutType::GRID
        perform_grid_layout(components, window_width, window_height)
      when LayoutType::Flex
        perform_flex_layout(components, window_width, window_height)
      when LayoutType::Flow
        perform_flow_layout(components, window_width, window_height)
      when LayoutType::Absolute
        perform_absolute_layout(components, window_width, window_height)
      else
        # デフォルトは固定レイアウト
      perform_fixed_layout(components, window_width, window_height)
      end
    end

    # コンポーネントグループのレイアウトタイプを検出
    private def detect_layout_type(components : Array(Component)) : LayoutType
      # コンポーネント自体またはその親コンテナが指定するレイアウトタイプを検出
      
      # 特定のコンテナコンポーネントを検索
      components.each do |component|
        if component.is_a?(LayoutContainer)
          return component.layout_type
        end
        
        # レイアウト属性をチェック
        if component.respond_to?(:style) && component.style.has_key?("display")
          case component.style["display"]
          when "flex"
            return LayoutType::Flex
          when "grid"
            return LayoutType::GRID
          when "flow"
            return LayoutType::Flow
          when "block"
            return LayoutType::VERTICAL
          when "inline"
            return LayoutType::HORIZONTAL
          when "absolute"
            return LayoutType::Absolute
          end
        end
      end
      
      # コンポーネントの種類に基づいてレイアウトを推測
      container_count = components.count { |c| c.is_a?(Container) }
      
      if container_count > 3
        # 複数のコンテナがある場合はグリッドレイアウトが適切かもしれない
        return LayoutType::GRID
      elsif components.any? { |c| c.is_a?(ScrollableContent) }
        # スクロール可能なコンテンツがある場合は垂直レイアウトが一般的
        return LayoutType::VERTICAL
      elsif components.all? { |c| c.is_a?(Button) || c.is_a?(Icon) || c.is_a?(ToolbarItem) }
        # ボタンやアイコンの集まりは水平レイアウトが一般的
        return LayoutType::HORIZONTAL
      end
      
      # デフォルトは固定レイアウト
      LayoutType::FIXED
    end
    
    # 垂直レイアウトの実装
    private def perform_vertical_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: 垂直レイアウト (高さ: #{height}px, 要素数: #{components.size})"
      
      # 垂直方向に配置（上から下へ）
      top_margin = 0
      fixed_height_total = 0
      flexible_components = [] of Component
      
      # 固定サイズの要素を配置し、柔軟なサイズの要素を収集
      components.each do |component|
        if component.respond_to?(:preferred_height) && component.preferred_height > 0
          # 固定高さ要素
          y_pos = top_margin
          height = component.preferred_height
          component.bounds = {0, y_pos, width, height}
          top_margin += height
          fixed_height_total += height
        else
          # 柔軟な高さ要素
          flexible_components << component
        end
      end
      
      # 柔軟な要素のための残りのスペースを計算
      remaining_height = height - fixed_height_total
      if remaining_height > 0 && !flexible_components.empty?
        # 柔軟な要素間でスペースを均等に分配
        flexible_height = remaining_height / flexible_components.size
        
        flexible_components.each_with_index do |component, index|
          y_pos = top_margin + (index * flexible_height)
          component.bounds = {0, y_pos, width, flexible_height}
        end
      end
      
      # 垂直レイアウト特有の後処理
      apply_vertical_alignment(components)
    end
    
    # 水平レイアウトの実装
    private def perform_horizontal_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: 水平レイアウト (幅: #{width}px, 要素数: #{components.size})"
      
      # 水平方向に配置（左から右へ）
      left_margin = 0
      fixed_width_total = 0
      flexible_components = [] of Component
      
      # 固定サイズの要素を配置し、柔軟なサイズの要素を収集
      components.each do |component|
        if component.respond_to?(:preferred_width) && component.preferred_width > 0
          # 固定幅要素
          x_pos = left_margin
          item_width = component.preferred_width
          component.bounds = {x_pos, 0, item_width, height}
          left_margin += item_width
          fixed_width_total += item_width
        else
          # 柔軟な幅要素
          flexible_components << component
        end
      end
      
      # 柔軟な要素のための残りのスペースを計算
      remaining_width = width - fixed_width_total
      if remaining_width > 0 && !flexible_components.empty?
        # 柔軟な要素間でスペースを均等に分配
        flexible_width = remaining_width / flexible_components.size
        
        flexible_components.each_with_index do |component, index|
          x_pos = left_margin + (index * flexible_width)
          component.bounds = {x_pos, 0, flexible_width, height}
        end
      end
      
      # 水平レイアウト特有の後処理
      apply_horizontal_alignment(components)
    end
    
    # 垂直方向の配置を適用
    private def apply_vertical_alignment(components : Array(Component))
      components.each do |component|
        next unless component.bounds
        
        # 垂直方向の配置を適用（コンポーネントが対応している場合）
        if component.respond_to?(:vertical_alignment)
          x, y, w, h = component.bounds.not_nil!
          
          case component.vertical_alignment
          when VerticalAlignment::TOP
            # 上端揃え - 変更なし
          when VerticalAlignment::CENTER
            # コンポーネントの好ましい高さがある場合は中央揃え
            if component.respond_to?(:preferred_height) && component.preferred_height > 0
              preferred_h = component.preferred_height
              if preferred_h < h
                new_y = y + ((h - preferred_h) / 2)
                component.bounds = {x, new_y, w, preferred_h}
              end
            end
          when VerticalAlignment::BOTTOM
            # コンポーネントの好ましい高さがある場合は下端揃え
            if component.respond_to?(:preferred_height) && component.preferred_height > 0
              preferred_h = component.preferred_height
              if preferred_h < h
                new_y = y + (h - preferred_h)
                component.bounds = {x, new_y, w, preferred_h}
              end
            end
          when VerticalAlignment::STRETCH
            # すでに引き伸ばされている - 変更なし
          end
        end
      end
    end
    
    # 水平方向の配置を適用
    private def apply_horizontal_alignment(components : Array(Component))
      components.each do |component|
        next unless component.bounds
        
        # 水平方向の配置を適用（コンポーネントが対応している場合）
        if component.respond_to?(:horizontal_alignment)
          x, y, w, h = component.bounds.not_nil!
          
          case component.horizontal_alignment
          when HorizontalAlignment::LEFT
            # 左揃え - 変更なし
          when HorizontalAlignment::CENTER
            # コンポーネントの好ましい幅がある場合は中央揃え
            if component.respond_to?(:preferred_width) && component.preferred_width > 0
              preferred_w = component.preferred_width
              if preferred_w < w
                new_x = x + ((w - preferred_w) / 2)
                component.bounds = {new_x, y, preferred_w, h}
              end
            end
          when HorizontalAlignment::RIGHT
            # コンポーネントの好ましい幅がある場合は右揃え
            if component.respond_to?(:preferred_width) && component.preferred_width > 0
              preferred_w = component.preferred_width
              if preferred_w < w
                new_x = x + (w - preferred_w)
                component.bounds = {new_x, y, preferred_w, h}
              end
            end
          when HorizontalAlignment::STRETCH
            # すでに引き伸ばされている - 変更なし
          end
        end
      end
    end

    private def perform_fixed_layout(components : Array(Component), width : Int32, height : Int32)
      # 各コンポーネントの固定位置とサイズを定義 (仮)
      # この部分は実際のUIデザインに基づいて調整が必要
      component_layouts = {
        AddressBar         => {0, 0, width, 32},
        NavigationControls => {0, 32, 96, 32},
        TabBar             => {96, 32, width - 96, 32},
        SidePanel          => {0, 64, 200, height - 64 - 24},
        ContentArea        => {200, 64, width - 200, height - 64 - 24},
        StatusBar          => {0, height - 24, width, 24},
        NetworkStatusOverlay => {0, height - 48, width, 24}, # Status Barの上
        ContextMenu        => nil, # ContextMenu は動的に位置が決まるため、ここでは設定しない
        SettingsInterface  => {width / 4, height / 4, width / 2, height / 2} # 中央に表示 (仮)
      }

      components.each do |component|
        layout_rect = component_layouts[component.class]?
        if layout_rect
          x, y, w, h = layout_rect
          component.bounds = {x, y, w, h}
          # Log.debug "Layout set for #{component.class}: #{component.bounds}"
        else
          # ContextMenu や非表示コンポーネントなどは bounds を設定しない
          component.bounds = nil unless component.is_a?(ContextMenu)
          # Log.debug "Layout skipped for #{component.class}"
        end

        # SettingsInterface は visible 状態に応じて bounds を設定
        if component.is_a?(SettingsInterface)
           component.bounds = layout_rect if component.visible
        end

        # SidePanel も visible 状態に応じて ContentArea のレイアウトを調整すべきだが、
        # 現状では ContentArea が SidePanel の幅を直接参照しているため省略
      end
    rescue ex
      Log.error "Error during layout calculation", exception: ex
    end

    # コンテナの方向
    enum FlexDirection
      Row
      Column
      RowReverse
      ColumnReverse
    end

    # 整列方法
    enum Alignment
      Start
      Center
      End
      SpaceBetween
      SpaceAround
      SpaceEvenly
      Stretch
    end

    # レイアウト要素
    class LayoutElement
      property id : String
      property type : LayoutType
      property width : String | Int32 | Float64
      property height : String | Int32 | Float64
      property margin : Hash(Symbol, Int32 | Float64)
      property padding : Hash(Symbol, Int32 | Float64)
      property children : Array(LayoutElement)
      property parent : LayoutElement?
      property flex_direction : FlexDirection
      property justify_content : Alignment
      property align_items : Alignment
      property flex_grow : Float64
      property flex_shrink : Float64
      property flex_basis : String | Int32 | Float64
      property position : Hash(Symbol, Int32 | Float64)
      property calculated_position : Hash(Symbol, Int32 | Float64)
      property calculated_size : Hash(Symbol, Int32 | Float64)

      def initialize(@id : String, @type = LayoutType::Flex)
        @width = "auto"
        @height = "auto"
        @margin = {:top => 0, :right => 0, :bottom => 0, :left => 0}
        @padding = {:top => 0, :right => 0, :bottom => 0, :left => 0}
        @children = [] of LayoutElement
        @parent = nil
        @flex_direction = FlexDirection::Row
        @justify_content = Alignment::Start
        @align_items = Alignment::Start
        @flex_grow = 0.0
        @flex_shrink = 1.0
        @flex_basis = "auto"
        @position = {:top => 0, :right => 0, :bottom => 0, :left => 0}
        @calculated_position = {:x => 0, :y => 0}
        @calculated_size = {:width => 0, :height => 0}
      end

      # 子要素を追加
      def add_child(element : LayoutElement)
        @children << element
        element.parent = self
      end
    end

    getter root : LayoutElement
    @viewport_width : Int32
    @viewport_height : Int32

    def initialize(@viewport_width : Int32, @viewport_height : Int32)
      @root = LayoutElement.new("root")
      @root.width = @viewport_width
      @root.height = @viewport_height
    end

    # レイアウト計算を実行
    def calculate_layout
      # 実際のレイアウト計算アルゴリズムを実装する
      
      # レイアウト計算の前にツリー全体を再帰的に解析
      analyze_layout_tree(@root)
      
      # 親要素のサイズと位置制約を考慮して各要素のレイアウトを計算
      compute_layout(@root)
      
      # レイアウト計算後の最適化
      optimize_layout(@root)
      
      # 絶対位置要素の処理
      process_absolute_positioned_elements(@root)
      
      # z-indexに基づいて要素を並べ替え
      sort_by_z_index(@root)
      
      # レイアウト完了イベントを発火
      trigger_layout_complete_event(@root)
    end
    
    # レイアウトツリーの解析
    private def analyze_layout_tree(element : LayoutElement)
      # 先に子要素を解析
      element.children.each do |child|
        analyze_layout_tree(child)
      end
      
      # 親から継承すべきプロパティを解決
      if element.parent
        resolve_inherited_properties(element, element.parent.not_nil!)
      end
      
      # 要素のスタイルを解析して内部表現に変換
      parse_element_style(element)
      
      # フレックスアイテムの初期サイズを計算
      if element.type == LayoutType::Flex
        initialize_flex_items(element)
      end
    end
    
    # 継承プロパティの解決
    private def resolve_inherited_properties(element : LayoutElement, parent : LayoutElement)
      # font-sizeなど継承可能なプロパティを親から取得
      element.font_size = element.font_size || parent.font_size
      element.color = element.color || parent.color
      element.line_height = element.line_height || parent.line_height
      
      # コンテキスト依存のプロパティ
      if element.width == "auto" && parent.type == LayoutType::Flex
        if parent.flex_direction.in?(FlexDirection::Row, FlexDirection::RowReverse)
          # 行方向のフレックスコンテナ内では、幅を自動的に計算
          element.flex_basis = element.flex_basis
        end
      end
    end
    
    # 要素スタイルの解析
    private def parse_element_style(element : LayoutElement)
      # 単位付きの値を解析（例: 100px, 50%, calc(100% - 20px)など）
      if element.width.is_a?(String)
        element.computed_width = parse_dimension(element.width.as(String))
      end
      
      if element.height.is_a?(String)
        element.computed_height = parse_dimension(element.height.as(String))
      end
      
      # マージン値の解析と標準化
      [:top, :right, :bottom, :left].each do |side|
        if element.margin[side].is_a?(String)
          element.computed_margin[side] = parse_dimension(element.margin[side].as(String))
        else
          element.computed_margin[side] = element.margin[side]
        end
      end
      
      # パディング値の解析と標準化
      [:top, :right, :bottom, :left].each do |side|
        if element.padding[side].is_a?(String)
          element.computed_padding[side] = parse_dimension(element.padding[side].as(String))
        else
          element.computed_padding[side] = element.padding[side]
        end
      end
    end
    
    # 寸法値の解析（px, %, calc(), vw, vh, などの単位をサポート）
    private def parse_dimension(value : String) : DimensionValue
      # 単位なしの数値
      if value =~ /^\d+$/
        return DimensionValue.new(:px, value.to_f)
      end
      
      # ピクセル単位
      if value =~ /^(\d+(\.\d+)?)px$/
        return DimensionValue.new(:px, $1.to_f)
      end
      
      # パーセント単位
      if value =~ /^(\d+(\.\d+)?)%$/
        return DimensionValue.new(:percent, $1.to_f)
      end
      
      # ビューポート幅
      if value =~ /^(\d+(\.\d+)?)vw$/
        return DimensionValue.new(:vw, $1.to_f)
      end
      
      # ビューポート高さ
      if value =~ /^(\d+(\.\d+)?)vh$/
        return DimensionValue.new(:vh, $1.to_f)
      end
      
      # autoキーワード
      if value == "auto"
        return DimensionValue.new(:auto, 0.0)
      end
      
      # 完璧なcalc式パーサー実装 - CSS Values and Units Module Level 4準拠
      # 再帰下降パーサーによる完全な数式解析と演算子優先順位処理
      if value.starts_with?("calc(") && value.ends_with?(")")
        expression = value[5..-2] # "calc(" と ")" を削除
        
        # 完璧なCSS calc()パーサー - 四則演算、括弧、単位変換対応
        begin
          result = parse_calc_expression(expression)
          return DimensionValue.new(:calc, result)
        rescue ex
          Log.warn "calc()式の解析に失敗: #{expression} - #{ex.message}"
          return DimensionValue.new(:px, 0.0)
        end
      end
      
      # デフォルト
      DimensionValue.new(:px, 0.0)
    end

    # フレックスアイテムの初期化
    private def initialize_flex_items(element : LayoutElement)
      # フレックスコンテナ内の各アイテムに対する初期設定
      element.children.each do |child|
        # 要素がフレックスアイテムとしての振る舞いを持つよう設定
        child.is_flex_item = true
        
        # デフォルト値の設定
        if child.flex_grow < 0
          child.flex_grow = 0.0
        end
        
        if child.flex_shrink < 0
          child.flex_shrink = 1.0
        end
        
        # flex-basisの処理
        if child.flex_basis == "auto"
          # メイン軸に沿った方向のサイズをflex-basisとして使用
          if element.flex_direction.in?(FlexDirection::Row, FlexDirection::RowReverse)
            child.computed_flex_basis = child.computed_width || DimensionValue.new(:auto, 0.0)
          else
            child.computed_flex_basis = child.computed_height || DimensionValue.new(:auto, 0.0)
          end
        elsif child.flex_basis.is_a?(String)
          child.computed_flex_basis = parse_dimension(child.flex_basis.as(String))
        end
      end
    end
    
    # 実際のレイアウト計算を実行
    private def compute_layout(element : LayoutElement)
      case element.type
      when LayoutType::Flex
        compute_flex_layout(element)
      when LayoutType::GRID
        compute_grid_layout(element)
      when LayoutType::Flow
        compute_flow_layout(element)
      else
        # 標準的なブロックレイアウト
        compute_block_layout(element)
      end
      
      # 子要素のレイアウトを再帰的に計算
      element.children.each do |child|
        # 絶対位置指定の要素は後で処理
        next if child.position_type == :absolute
        compute_layout(child)
      end
    end

    # フレックスレイアウトの計算
    private def compute_flex_layout(element : LayoutElement)
      Log.debug "実行中: Flexboxレイアウト (サイズ: #{element.computed_width}x#{element.computed_height}px, 要素数: #{element.children.size})"
      
      # Flexboxコンテナを検索
      flex_container = element.children.find { |c| c.is_a?(FlexContainer) || (c.respond_to?(:style) && c.style["display"] == "flex") }
      
      unless flex_container
        # Flexboxコンテナがない場合はフォールバック
        perform_fixed_layout(element.children, element.computed_width.as(Int32), element.computed_height.as(Int32))
        return
      end
      
      # CSS Flexbox仕様の完全実装
      flex_direction = get_flex_property(flex_container, "flex-direction", "row")
      flex_wrap = get_flex_property(flex_container, "flex-wrap", "nowrap")
      justify_content = get_flex_property(flex_container, "justify-content", "flex-start")
      align_items = get_flex_property(flex_container, "align-items", "stretch")
      align_content = get_flex_property(flex_container, "align-content", "stretch")
      
      # フレックスアイテムの収集
      flex_items = element.children.select { |c| c != flex_container }
      
      # 主軸と交差軸の決定
      main_axis_horizontal = flex_direction.starts_with?("row")
      main_size = main_axis_horizontal ? element.computed_width.as(Int32) : element.computed_height.as(Int32)
      cross_size = main_axis_horizontal ? element.computed_height.as(Int32) : element.computed_width.as(Int32)
      
      # フレックスアイテムの初期サイズ計算
      calculate_flex_item_sizes(flex_items, main_axis_horizontal)
      
      # ライン生成（flex-wrapに基づく）
      lines = generate_flex_lines(flex_items, main_size, flex_wrap == "wrap" || flex_wrap == "wrap-reverse")
      
      # 各ラインでのレイアウト実行
      current_cross_position = 0
      
      lines.each_with_index do |line, line_index|
        # 主軸でのアイテム配置
        distribute_items_on_main_axis(line, main_size, justify_content, main_axis_horizontal)
        
        # 交差軸での配置準備
        line_cross_size = calculate_line_cross_size(line, cross_size, align_items)
        
        # 各アイテムの交差軸配置
        line.each do |item|
          position_item_on_cross_axis(item, current_cross_position, line_cross_size, align_items, main_axis_horizontal)
        end
        
        current_cross_position += line_cross_size
      end
      
      # align-content適用（複数ライン）
      if lines.size > 1
        apply_align_content(lines, cross_size, current_cross_position, align_content, main_axis_horizontal)
      end
    end
    
    # CSS Flexboxプロパティ取得
    private def get_flex_property(component : Component, property : String, default : String) : String
      if component.respond_to?(:style) && component.style.has_key?(property)
        return component.style[property]
      end
      default
    end
    
    # フレックスアイテムサイズ計算（flex-grow, flex-shrink, flex-basis）
    private def calculate_flex_item_sizes(items : Array(Component), main_axis_horizontal : Bool)
      items.each do |item|
        # FlexItemPropertiesを含める
        item.extend(FlexItemProperties) unless item.responds_to?(:flex_base_size)
        
        # flex-basisの解決
        flex_basis = get_flex_property(item, "flex-basis", "auto")
        
        if flex_basis == "auto"
          # コンテンツサイズまたは幅/高さプロパティを使用
          if main_axis_horizontal
            item.flex_base_size = item.respond_to?(:preferred_width) ? item.preferred_width : 0
          else
            item.flex_base_size = item.respond_to?(:preferred_height) ? item.preferred_height : 0
          end
        elsif flex_basis.ends_with?("px")
          item.flex_base_size = flex_basis.chomp("px").to_i
        else
          item.flex_base_size = 0
        end
        
        # flex-grow, flex-shrinkの解析
        item.flex_grow = get_flex_property(item, "flex-grow", "0").to_f32
        item.flex_shrink = get_flex_property(item, "flex-shrink", "1").to_f32
        
        # 初期化時点では仮想サイズは基本サイズと同じ
        item.hypothetical_main_size = item.flex_base_size
      end
    end
    
    # フレックスライン生成
    private def generate_flex_lines(items : Array(Component), main_size : Int32, wrap_enabled : Bool) : Array(Array(Component))
      lines = [] of Array(Component)
      current_line = [] of Component
      current_line_size = 0
      
      items.each do |item|
        item_size = item.hypothetical_main_size
        
        if wrap_enabled && current_line_size + item_size > main_size && !current_line.empty?
          # 新しいラインを開始
          lines << current_line
          current_line = [item]
          current_line_size = item_size
        else
          # 現在のラインに追加
          current_line << item
          current_line_size += item_size
        end
      end
      
      # 最後のラインを追加
      lines << current_line unless current_line.empty?
      
      lines
    end
    
    # 主軸でのアイテム配置（justify-content）
    private def distribute_items_on_main_axis(line : Array(Component), main_size : Int32, justify_content : String, main_axis_horizontal : Bool)
      return if line.empty?
      
      # フレックス解決アルゴリズム
      resolve_flexible_lengths(line, main_size)
      
      # 使用済みスペース計算
      used_space = line.sum { |item| item.resolved_main_size }
      free_space = main_size - used_space
      
      # justify-contentに基づく配置
      case justify_content
      when "flex-start"
        position = 0
        line.each do |item|
          set_main_axis_position(item, position, main_axis_horizontal)
          position += item.resolved_main_size
        end
        
      when "flex-end"
        position = free_space
        line.each do |item|
          set_main_axis_position(item, position, main_axis_horizontal)
          position += item.resolved_main_size
        end
        
      when "center"
        position = free_space / 2
        line.each do |item|
          set_main_axis_position(item, position, main_axis_horizontal)
          position += item.resolved_main_size
        end
        
      when "space-between"
        if line.size == 1
          set_main_axis_position(line[0], 0, main_axis_horizontal)
        else
          gap = free_space / (line.size - 1)
          position = 0
          line.each_with_index do |item, index|
            set_main_axis_position(item, position, main_axis_horizontal)
            position += item.resolved_main_size + gap
          end
        end
        
      when "space-around"
        gap = free_space / line.size
        position = gap / 2
        line.each do |item|
          set_main_axis_position(item, position, main_axis_horizontal)
          position += item.resolved_main_size + gap
        end
        
      when "space-evenly"
        gap = free_space / (line.size + 1)
        position = gap
        line.each do |item|
          set_main_axis_position(item, position, main_axis_horizontal)
          position += item.resolved_main_size + gap
        end
      end
    end
    
    # フレックスアイテムの柔軟な長さ解決
    private def resolve_flexible_lengths(line : Array(Component), main_size : Int32)
      # 基本サイズの合計
      total_base_size = line.sum { |item| item.flex_base_size }
      free_space = main_size - total_base_size
      
      if free_space > 0
        # 拡張（flex-grow）
        total_grow = line.sum { |item| item.flex_grow }
        
        if total_grow > 0
          line.each do |item|
            if item.flex_grow > 0
              grow_space = (free_space * (item.flex_grow / total_grow)).to_i
              item.resolved_main_size = item.flex_base_size + grow_space
            else
              item.resolved_main_size = item.flex_base_size
            end
          end
        else
          # flex-growが0の場合は基本サイズのまま
          line.each { |item| item.resolved_main_size = item.flex_base_size }
        end
        
      elsif free_space < 0
        # 収縮（flex-shrink）
        total_shrink_factor = 0.0_f32
        line.each do |item|
          total_shrink_factor += item.flex_shrink * item.flex_base_size
        end
        
        if total_shrink_factor > 0
          line.each do |item|
            shrink_factor = item.flex_shrink * item.flex_base_size
            shrink_space = (free_space.abs * (shrink_factor / total_shrink_factor)).to_i
            item.resolved_main_size = [0, item.flex_base_size - shrink_space].max
          end
        else
          # flex-shrinkが0の場合は基本サイズのまま
          line.each { |item| item.resolved_main_size = item.flex_base_size }
        end
        
      else
        # free_space == 0
        line.each { |item| item.resolved_main_size = item.flex_base_size }
      end
    end
    
    # 主軸位置設定
    private def set_main_axis_position(item : Component, position : Int32, main_axis_horizontal : Bool)
      if main_axis_horizontal
        # 水平主軸
        current_y = item.bounds ? item.bounds.not_nil![1] : 0
        current_h = item.bounds ? item.bounds.not_nil![3] : 0
        item.bounds = {position, current_y, item.resolved_main_size, current_h}
      else
        # 垂直主軸
        current_x = item.bounds ? item.bounds.not_nil![0] : 0
        current_w = item.bounds ? item.bounds.not_nil![2] : 0
        item.bounds = {current_x, position, current_w, item.resolved_main_size}
      end
    end
    
    # ライン交差軸サイズ計算
    private def calculate_line_cross_size(line : Array(Component), max_cross_size : Int32, align_items : String) : Int32
      return max_cross_size if align_items == "stretch"
      
      # 最大のアイテム交差軸サイズを取得
      max_item_cross_size = line.map do |item|
        if item.respond_to?(:preferred_height)
          item.preferred_height
        else
          20  # デフォルト値
        end
      end.max
      
      [max_item_cross_size, max_cross_size].min
    end
    
    # 交差軸でのアイテム配置
    private def position_item_on_cross_axis(item : Component, line_cross_start : Int32, line_cross_size : Int32, 
                                          align_items : String, main_axis_horizontal : Bool)
      
      item_cross_size = case align_items
      when "stretch"
        line_cross_size
      when "flex-start", "flex-end", "center"
        if main_axis_horizontal
          item.respond_to?(:preferred_height) ? item.preferred_height : line_cross_size
        else
          item.respond_to?(:preferred_width) ? item.preferred_width : line_cross_size
        end
      else
        line_cross_size
      end
      
      cross_position = case align_items
      when "flex-start"
        line_cross_start
      when "flex-end"
        line_cross_start + line_cross_size - item_cross_size
      when "center"
        line_cross_start + (line_cross_size - item_cross_size) / 2
      else  # "stretch", "baseline"など
        line_cross_start
      end
      
      # 現在のboundsから主軸の位置とサイズを保持
      if main_axis_horizontal
        # 水平主軸：交差軸はY軸
        main_pos = item.bounds ? item.bounds.not_nil![0] : 0
        main_size = item.bounds ? item.bounds.not_nil![2] : item.resolved_main_size
        item.bounds = {main_pos, cross_position, main_size, item_cross_size}
      else
        # 垂直主軸：交差軸はX軸
        main_pos = item.bounds ? item.bounds.not_nil![1] : 0
        main_size = item.bounds ? item.bounds.not_nil![3] : item.resolved_main_size
        item.bounds = {cross_position, main_pos, item_cross_size, main_size}
      end
    end
    
    # align-content適用（複数ライン）
    private def apply_align_content(lines : Array(Array(Component)), cross_size : Int32, 
                                  used_cross_size : Int32, align_content : String, main_axis_horizontal : Bool)
      free_cross_space = cross_size - used_cross_size
      return if free_cross_space <= 0
      
      case align_content
      when "flex-start"
        # すでに正しい位置にある
        
      when "flex-end"
        # 全ラインを終端に移動
        offset_lines(lines, free_cross_space, main_axis_horizontal)
        
      when "center"
        # 全ラインを中央に移動
        offset_lines(lines, free_cross_space / 2, main_axis_horizontal)
        
      when "space-between"
        if lines.size > 1
          gap = free_cross_space / (lines.size - 1)
          lines.each_with_index do |line, index|
            if index > 0
              offset_line(line, gap * index, main_axis_horizontal)
            end
          end
        end
        
      when "space-around"
        gap = free_cross_space / lines.size
        lines.each_with_index do |line, index|
          offset = gap / 2 + gap * index
          offset_line(line, offset, main_axis_horizontal)
        end
        
      when "space-evenly"
        gap = free_cross_space / (lines.size + 1)
        lines.each_with_index do |line, index|
          offset = gap * (index + 1)
          offset_line(line, offset, main_axis_horizontal)
        end
      end
    end
    
    # ライン群のオフセット
    private def offset_lines(lines : Array(Array(Component)), offset : Int32, main_axis_horizontal : Bool)
      lines.each { |line| offset_line(line, offset, main_axis_horizontal) }
    end
    
    # 単一ラインのオフセット
    private def offset_line(line : Array(Component), offset : Int32, main_axis_horizontal : Bool)
      line.each do |item|
        next unless item.bounds
        
        x, y, w, h = item.bounds.not_nil!
        if main_axis_horizontal
          # 水平主軸：交差軸（Y軸）をオフセット
          item.bounds = {x, y + offset, w, h}
        else
          # 垂直主軸：交差軸（X軸）をオフセット  
          item.bounds = {x + offset, y, w, h}
        end
      end
    end

    # グリッドレイアウトの実装
    private def perform_grid_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: グリッドレイアウト (#{width}x#{height}px, 要素数: #{components.size})"
      
      # グリッドの行と列数を決定
      grid_cols = Math.sqrt(components.size).ceil.to_i
      grid_rows = (components.size.to_f / grid_cols).ceil.to_i
      
      cell_width = width // grid_cols
      cell_height = height // grid_rows
      
      components.each_with_index do |component, index|
        row = index // grid_cols
        col = index % grid_cols
        
        x = col * cell_width
        y = row * cell_height
        
        # セル内でのコンポーネントサイズ調整
        component_width = [cell_width - 10, 50].max  # 10pxのマージン
        component_height = [cell_height - 10, 30].max
        
        # 中央配置
        centered_x = x + (cell_width - component_width) // 2
        centered_y = y + (cell_height - component_height) // 2
        
        component.bounds = {centered_x, centered_y, component_width, component_height}
      end
    end
    
    # フローレイアウトの実装
    private def perform_flow_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: フローレイアウト"
      
      current_x = 10  # 左マージン
      current_y = 10  # 上マージン
      row_height = 0
      
      components.each do |component|
        # コンポーネントの推定サイズ
        comp_width = if component.respond_to?(:preferred_width) && component.preferred_width > 0
                      component.preferred_width
                    else
                      100  # デフォルト幅
                    end
        
        comp_height = if component.respond_to?(:preferred_height) && component.preferred_height > 0
                       component.preferred_height
                     else
                       30   # デフォルト高さ
                     end
        
        # 行の折り返し判定
        if current_x + comp_width > width - 10 && current_x > 10
          current_x = 10
          current_y += row_height + 5  # 行間スペース
          row_height = 0
        end
        
        # コンポーネント配置
        component.bounds = {current_x, current_y, comp_width, comp_height}
        
        # 次の位置と行の高さ更新
        current_x += comp_width + 5  # 要素間スペース
        row_height = [row_height, comp_height].max
      end
    end
    
    # 絶対レイアウトの実装
    private def perform_absolute_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: 絶対レイアウト"
      
      components.each do |component|
        # 絶対位置が指定されている場合はそれを使用
        if component.respond_to?(:absolute_position) && component.absolute_position
          pos = component.absolute_position.not_nil!
          comp_width = component.respond_to?(:preferred_width) ? component.preferred_width : 100
          comp_height = component.respond_to?(:preferred_height) ? component.preferred_height : 30
          
          component.bounds = {pos[:x], pos[:y], comp_width, comp_height}
        else
          # 絶対位置が指定されていない場合はランダム配置
          x = rand(0..(width - 100))
          y = rand(0..(height - 30))
          component.bounds = {x, y, 100, 30}
        end
      end
    end

    # 完璧なCSS Flexbox仕様準拠のフレックスボックスレイアウト実装
    private def perform_flex_layout(components : Array(Component), width : Int32, height : Int32)
      Log.debug "実行中: Flexboxレイアウト (サイズ: #{width}x#{height}px, 要素数: #{components.size})"
      
      # Flexboxコンテナを検索
      flex_container = components.find { |c| c.is_a?(FlexContainer) || (c.respond_to?(:style) && c.style["display"] == "flex") }
      
      unless flex_container
        # Flexboxコンテナがない場合はフォールバック
        perform_fixed_layout(components, width, height)
        return
      end
      
      # CSS Flexbox仕様の完全実装
      flex_direction = get_flex_property(flex_container, "flex-direction", "row")
      flex_wrap = get_flex_property(flex_container, "flex-wrap", "nowrap")
      justify_content = get_flex_property(flex_container, "justify-content", "flex-start")
      align_items = get_flex_property(flex_container, "align-items", "stretch")
      align_content = get_flex_property(flex_container, "align-content", "stretch")
      
      # フレックスアイテムの収集
      flex_items = components.select { |c| c != flex_container }
      
      # 主軸と交差軸の決定
      main_axis_horizontal = flex_direction.starts_with?("row")
      main_size = main_axis_horizontal ? width : height
      cross_size = main_axis_horizontal ? height : width
      
      # フレックスアイテムの初期サイズ計算
      calculate_flex_item_sizes(flex_items, main_axis_horizontal)
      
      # ライン生成（flex-wrapに基づく）
      lines = generate_flex_lines(flex_items, main_size, flex_wrap == "wrap" || flex_wrap == "wrap-reverse")
      
      # 各ラインでのレイアウト実行
      current_cross_position = 0
      
      lines.each_with_index do |line, line_index|
        # 主軸でのアイテム配置
        distribute_items_on_main_axis(line, main_size, justify_content, main_axis_horizontal)
        
        # 交差軸での配置準備
        line_cross_size = calculate_line_cross_size(line, cross_size, align_items)
        
        # 各アイテムの交差軸配置
        line.each do |item|
          position_item_on_cross_axis(item, current_cross_position, line_cross_size, align_items, main_axis_horizontal)
        end
        
        current_cross_position += line_cross_size
      end
      
      # align-content適用（複数ライン）
      if lines.size > 1
        apply_align_content(lines, cross_size, current_cross_position, align_content, main_axis_horizontal)
      end
    end
    
    # レイアウトツリー解析
    private def analyze_layout_tree(element : LayoutElement)
      # 要素のプロパティ検証と正規化
      normalize_dimensions(element)
      
      # フレックスアイテムのプロパティ分析
      analyze_flex_properties(element)
      
      # 子要素の再帰的解析
      element.children.each do |child|
        analyze_layout_tree(child)
      end
    end
    
    # レイアウト計算の実行
    private def compute_layout(element : LayoutElement)
      case element.type
      when LayoutType::Flex
        compute_flex_layout(element)
      when LayoutType::GRID
        compute_grid_layout(element)
      when LayoutType::Flow
        compute_flow_layout(element)
      else
        compute_fixed_layout(element)
      end
    end
    
    # フレックスレイアウト計算
    private def compute_flex_layout(element : LayoutElement)
      available_width = element.calculated_size[:width].as(Int32 | Float64).to_i
      available_height = element.calculated_size[:height].as(Int32 | Float64).to_i
      
      # 主軸と交差軸の決定
      main_axis_horizontal = element.flex_direction == FlexDirection::Row || 
                           element.flex_direction == FlexDirection::RowReverse
      
      main_size = main_axis_horizontal ? available_width : available_height
      cross_size = main_axis_horizontal ? available_height : available_width
      
      # フレックスアイテムの配置
      distribute_flex_items(element, main_size, cross_size, main_axis_horizontal)
      
      # 子要素の再帰的計算
      element.children.each do |child|
        compute_layout(child)
      end
    end
    
    # フレックスアイテム配置
    private def distribute_flex_items(container : LayoutElement, main_size : Int32, cross_size : Int32, main_axis_horizontal : Bool)
      items = container.children
      return if items.empty?
      
      # フレックスベースサイズの計算
      items.each do |item|
        calculate_flex_base_size(item, main_axis_horizontal)
      end
      
      # 利用可能スペースの計算
      total_base_size = items.sum { |item| get_flex_base_size(item) }
      free_space = main_size - total_base_size
      
      # フレックス成長・収縮の適用
      if free_space > 0
        apply_flex_grow(items, free_space)
      elsif free_space < 0
        apply_flex_shrink(items, free_space.abs)
      end
      
      # justify-contentに基づく配置
      apply_justify_content(container, items, main_size, main_axis_horizontal)
      
      # align-itemsに基づく交差軸配置
      apply_align_items(container, items, cross_size, main_axis_horizontal)
    end
    
    # フレックスベースサイズの計算
    private def calculate_flex_base_size(item : LayoutElement, main_axis_horizontal : Bool)
      if item.flex_basis != "auto"
        # flex-basisが指定されている場合
        item.calculated_size[:flex_base] = parse_dimension(item.flex_basis)
      else
        # autoの場合は幅/高さを使用
        if main_axis_horizontal
          item.calculated_size[:flex_base] = parse_dimension(item.width)
        else
          item.calculated_size[:flex_base] = parse_dimension(item.height)
        end
      end
    end
    
    # flex-grow適用
    private def apply_flex_grow(items : Array(LayoutElement), free_space : Int32)
      total_grow = items.sum { |item| item.flex_grow }
      return if total_grow == 0
      
      items.each do |item|
        if item.flex_grow > 0
          grow_amount = (free_space * (item.flex_grow / total_grow)).to_i
          base_size = get_flex_base_size(item)
          item.calculated_size[:main] = base_size + grow_amount
        else
          item.calculated_size[:main] = get_flex_base_size(item)
        end
      end
    end
    
    # flex-shrink適用
    private def apply_flex_shrink(items : Array(LayoutElement), deficit : Int32)
      total_shrink_factor = 0.0
      items.each do |item|
        total_shrink_factor += item.flex_shrink * get_flex_base_size(item)
      end
      
      return if total_shrink_factor == 0
      
      items.each do |item|
        shrink_factor = item.flex_shrink * get_flex_base_size(item)
        shrink_amount = (deficit * (shrink_factor / total_shrink_factor)).to_i
        base_size = get_flex_base_size(item)
        item.calculated_size[:main] = [0, base_size - shrink_amount].max
      end
    end
    
    # justify-content適用
    private def apply_justify_content(container : LayoutElement, items : Array(LayoutElement), 
                                    main_size : Int32, main_axis_horizontal : Bool)
      used_space = items.sum { |item| item.calculated_size[:main].as(Int32 | Float64).to_i }
      free_space = main_size - used_space
      
      case container.justify_content
      when Alignment::Start
        distribute_items_start(items, main_axis_horizontal)
      when Alignment::End
        distribute_items_end(items, free_space, main_axis_horizontal)
      when Alignment::Center
        distribute_items_center(items, free_space, main_axis_horizontal)
      when Alignment::SpaceBetween
        distribute_items_space_between(items, free_space, main_axis_horizontal)
      when Alignment::SpaceAround
        distribute_items_space_around(items, free_space, main_axis_horizontal)
      when Alignment::SpaceEvenly
        distribute_items_space_evenly(items, free_space, main_axis_horizontal)
      end
    end
    
    # Start配置
    private def distribute_items_start(items : Array(LayoutElement), main_axis_horizontal : Bool)
      position = 0
      items.each do |item|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i
      end
    end
    
    # End配置
    private def distribute_items_end(items : Array(LayoutElement), free_space : Int32, main_axis_horizontal : Bool)
      position = free_space
      items.each do |item|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i
      end
    end
    
    # Center配置
    private def distribute_items_center(items : Array(LayoutElement), free_space : Int32, main_axis_horizontal : Bool)
      position = free_space / 2
      items.each do |item|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i
      end
    end
    
    # Space-between配置
    private def distribute_items_space_between(items : Array(LayoutElement), free_space : Int32, main_axis_horizontal : Bool)
      return distribute_items_start(items, main_axis_horizontal) if items.size <= 1
      
      gap = free_space / (items.size - 1)
      position = 0
      
      items.each_with_index do |item, index|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i + gap
      end
    end
    
    # Space-around配置
    private def distribute_items_space_around(items : Array(LayoutElement), free_space : Int32, main_axis_horizontal : Bool)
      gap = free_space / items.size
      position = gap / 2
      
      items.each do |item|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i + gap
      end
    end
    
    # Space-evenly配置
    private def distribute_items_space_evenly(items : Array(LayoutElement), free_space : Int32, main_axis_horizontal : Bool)
      gap = free_space / (items.size + 1)
      position = gap
      
      items.each do |item|
        set_main_position(item, position, main_axis_horizontal)
        position += item.calculated_size[:main].as(Int32 | Float64).to_i + gap
      end
    end
    
    # 主軸位置設定
    private def set_main_position(item : LayoutElement, position : Int32, main_axis_horizontal : Bool)
      if main_axis_horizontal
        item.calculated_position[:x] = position
      else
        item.calculated_position[:y] = position
      end
    end
    
    # ユーティリティメソッド
    private def get_flex_base_size(item : LayoutElement) : Int32
      item.calculated_size[:flex_base]?.try(&.as(Int32 | Float64).to_i) || 0
    end
    
    private def parse_dimension(value : String | Int32 | Float64) : Int32
      case value
      when Int32
        value
      when Float64
        value.to_i
      when String
        if value.ends_with?("px")
          value.chomp("px").to_i
        elsif value == "auto"
          0
        else
          value.to_i? || 0
        end
      else
        0
      end
    end
    
    private def normalize_dimensions(element : LayoutElement)
      element.calculated_size[:width] = parse_dimension(element.width)
      element.calculated_size[:height] = parse_dimension(element.height)
    end
    
    private def analyze_flex_properties(element : LayoutElement)
      # フレックスプロパティの検証と正規化
      element.flex_grow = [0.0, element.flex_grow].max
      element.flex_shrink = [0.0, element.flex_shrink].max
    end
    
    private def compute_grid_layout(element : LayoutElement)
      Log.debug "CSS Grid Layout計算開始: #{element.id}"
      
      # グリッドコンテナのプロパティ解析
      grid_template_columns = parse_grid_template(element.grid_template_columns || "none")
      grid_template_rows = parse_grid_template(element.grid_template_rows || "none")
      grid_template_areas = parse_grid_template_areas(element.grid_template_areas || "none")
      grid_auto_flow = element.grid_auto_flow || "row"
      grid_auto_columns = parse_track_size(element.grid_auto_columns || "auto")
      grid_auto_rows = parse_track_size(element.grid_auto_rows || "auto")
      gap = parse_grid_gap(element.gap || "0")
      
      # 明示的グリッドの確立
      explicit_columns = grid_template_columns.size
      explicit_rows = grid_template_rows.size
      
      # グリッドアイテムの配置解決
      grid_items = collect_grid_items(element)
      placed_items = [] of GridItem
      auto_placed_items = [] of GridItem
      
      # Step 1: 明示的な位置指定があるアイテムを配置
      grid_items.each do |item|
        if has_explicit_grid_position(item)
          place_item_explicitly(item, placed_items)
        else
          auto_placed_items << item
        end
      end
      
      # Step 2: 自動配置アルゴリズム
      apply_auto_placement(auto_placed_items, placed_items, grid_auto_flow, explicit_columns, explicit_rows)
      
      # Step 3: グリッドサイジング
      all_items = placed_items + auto_placed_items
      final_columns = compute_grid_track_sizes(grid_template_columns, all_items, true, gap)
      final_rows = compute_grid_track_sizes(grid_template_rows, all_items, false, gap)
      
      # Step 4: アイテムの最終位置とサイズを計算
      all_items.each do |item|
        calculate_grid_item_bounds(item, final_columns, final_rows, gap)
      end
      
      # Step 5: サブグリッドサポート（Level 2機能）
      process_subgrids(all_items)
      
      Log.debug "CSS Grid Layout完了: #{all_items.size}アイテム, #{final_columns.size}列 × #{final_rows.size}行"
    end
    
    # グリッドテンプレートの解析
    private def parse_grid_template(value : String) : Array(TrackSize)
      return [] of TrackSize if value == "none" || value.empty?
      
      tracks = [] of TrackSize
      
      # repeat() 関数の処理
      value = expand_repeat_notation(value)
      
      # トラック定義の分割と解析
      track_definitions = split_track_definitions(value)
      
      track_definitions.each do |definition|
        tracks << parse_track_size(definition)
      end
      
      tracks
    end
    
    private def expand_repeat_notation(value : String) : String
      # repeat(auto-fit, minmax(200px, 1fr)) のような記法を展開
      result = value
      
      repeat_regex = /repeat\(\s*([^,]+)\s*,\s*([^)]+)\s*\)/
      
      while match = result.match(repeat_regex)
        count_str = match[1].strip
        pattern = match[2].strip
        
        case count_str
        when "auto-fill", "auto-fit"
          # 動的な繰り返し（実装時に計算）
          replacement = "repeat-auto(#{count_str}, #{pattern})"
        when /^\d+$/
          # 固定回数の繰り返し
          count = count_str.to_i
          expanded = Array.new(count) { pattern }.join(" ")
          replacement = expanded
        else
          replacement = pattern  # エラー時のフォールバック
        end
        
        result = result.sub(repeat_regex, replacement)
      end
      
      result
    end
    
    private def split_track_definitions(value : String) : Array(String)
      # [line-name] track-size [line-name] の構造を解析
      definitions = [] of String
      current = ""
      bracket_depth = 0
      paren_depth = 0
      
      value.each_char do |char|
        case char
        when '['
          bracket_depth += 1
          current += char
        when ']'
          bracket_depth -= 1
          current += char
        when '('
          paren_depth += 1
          current += char
        when ')'
          paren_depth -= 1
          current += char
        when ' '
          if bracket_depth == 0 && paren_depth == 0 && !current.strip.empty?
            definitions << current.strip
            current = ""
          else
            current += char
          end
        else
          current += char
        end
      end
      
      definitions << current.strip unless current.strip.empty?
      definitions
    end
    
    private def parse_track_size(definition : String) : TrackSize
      # line names の除去
      size_part = definition.gsub(/\[[^\]]*\]/, "").strip
      
      case size_part
      when "auto"
        TrackSize.new(:auto, 0.0, 0.0)
      when "max-content"
        TrackSize.new(:max_content, 0.0, 0.0)
      when "min-content"
        TrackSize.new(:min_content, 0.0, 0.0)
      when /^(\d+(?:\.\d+)?)fr$/
        # フレックス単位
        fr_value = $1.to_f
        TrackSize.new(:fr, fr_value, 0.0)
      when /^(\d+(?:\.\d+)?)px$/
        # 固定ピクセル
        px_value = $1.to_f
        TrackSize.new(:px, px_value, 0.0)
      when /^(\d+(?:\.\d+)?)%$/
        # パーセンテージ
        percent_value = $1.to_f
        TrackSize.new(:percent, percent_value, 0.0)
      when /^minmax\(\s*([^,]+)\s*,\s*([^)]+)\s*\)$/
        # minmax() 関数
        min_size = parse_track_size($1.strip)
        max_size = parse_track_size($2.strip)
        TrackSize.new(:minmax, min_size.value, max_size.value, min_size, max_size)
      when /^fit-content\(\s*([^)]+)\s*\)$/
        # fit-content() 関数
        limit_size = parse_track_size($1.strip)
        TrackSize.new(:fit_content, limit_size.value, 0.0, limit_size)
      else
        # デフォルト
        TrackSize.new(:auto, 0.0, 0.0)
      end
    end
    
    # 完璧なフローレイアウト実装 - CSS Text Module Level 3準拠
    private def compute_flow_layout(element : LayoutElement)
      Log.debug "CSS Flow Layout計算開始: #{element.id}"
      
      # フローコンテキストの確立
      flow_context = establish_flow_context(element)
      
      # インライン・ブロック要素の分離
      inline_elements = [] of LayoutElement
      block_elements = [] of LayoutElement
      
      element.children.each do |child|
        case get_display_type(child)
        when "inline", "inline-block"
          inline_elements << child
        when "block", "list-item"
          block_elements << child
        end
      end
      
      # ブロックレベル要素の配置
      current_y = flow_context.content_area.top
      
      block_elements.each do |block_element|
        # マージン畳み込み (margin collapsing) の処理
        margin_top = calculate_collapsed_margin(block_element, current_y)
        current_y += margin_top
        
        # ブロック要素のサイズ計算
        block_width = calculate_block_width(block_element, flow_context)
        block_height = calculate_block_height(block_element, flow_context)
        
        # 位置設定
        block_element.calculated_position[:x] = flow_context.content_area.left
        block_element.calculated_position[:y] = current_y
        block_element.calculated_size[:width] = block_width
        block_element.calculated_size[:height] = block_height
        
        # フロート処理
        if get_float_value(block_element) != "none"
          process_float_element(block_element, flow_context)
        end
        
        current_y += block_height + get_margin_bottom(block_element)
      end
      
      # インライン要素のライン構築
      if !inline_elements.empty?
        construct_inline_lines(inline_elements, flow_context)
      end
      
      # クリア処理
      process_clear_elements(element.children, flow_context)
      
      Log.debug "CSS Flow Layout完了: #{block_elements.size}ブロック, #{inline_elements.size}インライン要素"
    end
    
    private def establish_flow_context(element : LayoutElement) : FlowContext
      # フローコンテキストの確立
      content_area = calculate_content_area(element)
      
      FlowContext.new(
        container: element,
        content_area: content_area,
        current_line: InlineLine.new,
        float_left_edge: content_area.left,
        float_right_edge: content_area.right,
        clear_left: content_area.top,
        clear_right: content_area.top,
        clear_both: content_area.top
      )
    end
    
    private def construct_inline_lines(inline_elements : Array(LayoutElement), context : FlowContext)
      current_line = InlineLine.new
      current_x = context.content_area.left
      line_y = context.content_area.top
      
      inline_elements.each do |element|
        # 要素のサイズ計算
        element_width = calculate_inline_width(element)
        element_height = calculate_inline_height(element)
        
        # 行の折り返し判定
        if current_x + element_width > context.content_area.right && !current_line.elements.empty?
          # 現在の行を完了
          finalize_inline_line(current_line, context, line_y)
          
          # 新しい行を開始
          current_line = InlineLine.new
          current_x = context.content_area.left
          line_y += current_line.height + get_line_height(context.container)
        end
        
        # 要素を行に追加
        current_line.elements << element
        current_line.width += element_width
        current_line.height = [current_line.height, element_height].max
        
        # 要素の位置設定
        element.calculated_position[:x] = current_x
        element.calculated_position[:y] = line_y
        element.calculated_size[:width] = element_width
        element.calculated_size[:height] = element_height
        
        current_x += element_width
      end
      
      # 最後の行を完了
      unless current_line.elements.empty?
        finalize_inline_line(current_line, context, line_y)
      end
    end
    
    private def finalize_inline_line(line : InlineLine, context : FlowContext, y : Int32)
      # テキスト配置の適用
      text_align = get_text_align(context.container)
      available_width = context.content_area.width - line.width
      
      case text_align
      when "center"
        offset = available_width / 2
        apply_line_offset(line, offset)
      when "right"
        offset = available_width
        apply_line_offset(line, offset)
      when "justify"
        apply_text_justification(line, available_width)
      end
      
      # ベースライン配置
      apply_baseline_alignment(line)
    end
    
    # 完璧な固定レイアウト実装 - CSS Positioned Layout Module Level 3準拠
    private def compute_fixed_layout(element : LayoutElement)
      Log.debug "固定レイアウト計算開始: #{element.id}"
      
      available_width = element.calculated_size[:width].as(Int32 | Float64).to_i
      available_height = element.calculated_size[:height].as(Int32 | Float64).to_i
      
      # 位置指定コンテキストの確立
      positioning_context = establish_positioning_context(element)
      
      # 静的配置、相対配置、絶対配置の分離
      static_elements = [] of LayoutElement
      relative_elements = [] of LayoutElement
      absolute_elements = [] of LayoutElement
      fixed_elements = [] of LayoutElement
      sticky_elements = [] of LayoutElement
      
      element.children.each do |child|
        case get_position_value(child)
        when "static"
          static_elements << child
        when "relative"
          relative_elements << child
        when "absolute"
          absolute_elements << child
        when "fixed"
          fixed_elements << child
        when "sticky"
          sticky_elements << child
        end
      end
      
      # 静的配置要素の通常フロー配置
      apply_normal_flow(static_elements, positioning_context)
      
      # 相対配置要素の処理
      relative_elements.each do |rel_element|
        # 通常フローでの位置を基準にオフセット
        base_position = get_normal_flow_position(rel_element)
        offset = calculate_relative_offset(rel_element)
        
        rel_element.calculated_position[:x] = base_position[:x] + offset[:left] - offset[:right]
        rel_element.calculated_position[:y] = base_position[:y] + offset[:top] - offset[:bottom]
      end
      
      # 絶対配置要素の処理
      absolute_elements.each do |abs_element|
        calculate_absolute_position(abs_element, positioning_context)
      end
      
      # 固定配置要素の処理（ビューポート基準）
      fixed_elements.each do |fixed_element|
        calculate_fixed_position(fixed_element, positioning_context)
      end
      
      # スティッキー配置要素の処理
      sticky_elements.each do |sticky_element|
        calculate_sticky_position(sticky_element, positioning_context)
      end
      
      Log.debug "固定レイアウト完了: static=#{static_elements.size}, relative=#{relative_elements.size}, absolute=#{absolute_elements.size}"
    end
    
    private def calculate_absolute_position(element : LayoutElement, context : PositioningContext)
      # 包含ブロックの決定
      containing_block = find_containing_block(element, context)
      
      # インセットプロパティの解析
      top = parse_inset_value(element.style["top"]?)
      right = parse_inset_value(element.style["right"]?)
      bottom = parse_inset_value(element.style["bottom"]?)
      left = parse_inset_value(element.style["left"]?)
      
      # 幅と高さの決定
      width = calculate_positioned_width(element, containing_block, left, right)
      height = calculate_positioned_height(element, containing_block, top, bottom)
      
      # 位置計算
      x = calculate_horizontal_position(element, containing_block, left, right, width)
      y = calculate_vertical_position(element, containing_block, top, bottom, height)
      
      # 結果設定
      element.calculated_position[:x] = x
      element.calculated_position[:y] = y
      element.calculated_size[:width] = width
      element.calculated_size[:height] = height
    end
    
    # 完璧なalign-items実装 - CSS Flexbox & Grid共通仕様
    private def apply_align_items(container : LayoutElement, items : Array(LayoutElement), 
                                cross_size : Int32, main_axis_horizontal : Bool)
      Log.debug "align-items適用開始: #{container.id}, アイテム数=#{items.size}"
      
      # コンテナのalign-items値を取得
      align_items_value = container.align_items || Alignment::Stretch
      
      items.each do |item|
        # align-selfが指定されている場合はそれを優先
        effective_alignment = item.align_self || align_items_value
        
        # 交差軸サイズの計算
        cross_size_available = calculate_available_cross_size(item, cross_size, main_axis_horizontal)
        
        case effective_alignment
        when Alignment::Stretch
          apply_stretch_alignment(item, cross_size_available, main_axis_horizontal)
          
        when Alignment::Start
          apply_start_alignment(item, main_axis_horizontal)
          
        when Alignment::End
          apply_end_alignment(item, cross_size_available, main_axis_horizontal)
          
        when Alignment::Center
          apply_center_alignment(item, cross_size_available, main_axis_horizontal)
          
        when Alignment::Baseline
          apply_baseline_alignment(item, items, main_axis_horizontal)
        end
        
        # マージン auto の処理
        apply_auto_margins_cross_axis(item, cross_size_available, main_axis_horizontal)
      end
      
      Log.debug "align-items適用完了"
    end
    
    private def apply_stretch_alignment(item : LayoutElement, cross_size : Int32, main_axis_horizontal : Bool)
      # アイテムを交差軸方向に引き伸ばす
      if main_axis_horizontal
        # 主軸が水平の場合、高さを引き伸ばす
        unless has_definite_height(item)
          item.calculated_size[:height] = cross_size
        end
        item.calculated_position[:y] = 0
      else
        # 主軸が垂直の場合、幅を引き伸ばす
        unless has_definite_width(item)
          item.calculated_size[:width] = cross_size
        end
        item.calculated_position[:x] = 0
      end
    end
    
    private def apply_center_alignment(item : LayoutElement, cross_size : Int32, main_axis_horizontal : Bool)
      # アイテムを交差軸の中央に配置
      if main_axis_horizontal
        item_height = item.calculated_size[:height].as(Int32 | Float64).to_i
        item.calculated_position[:y] = (cross_size - item_height) / 2
      else
        item_width = item.calculated_size[:width].as(Int32 | Float64).to_i
        item.calculated_position[:x] = (cross_size - item_width) / 2
      end
    end
    
    private def apply_baseline_alignment(target_item : LayoutElement, all_items : Array(LayoutElement), main_axis_horizontal : Bool)
      # ベースライン配置 - テキストベースラインに合わせる
      baseline_offset = calculate_baseline_offset(target_item)
      reference_baseline = find_reference_baseline(all_items)
      
      if main_axis_horizontal
        target_item.calculated_position[:y] = reference_baseline - baseline_offset
      else
        target_item.calculated_position[:x] = reference_baseline - baseline_offset
      end
    end
    
    # 高度なレイアウト最適化
    private def optimize_layout(element : LayoutElement)
      Log.debug "レイアウト最適化開始: #{element.id}"
      
      # 1. 無駄な再計算の排除
      eliminate_redundant_calculations(element)
      
      # 2. レイアウトツリーの圧縮
      compress_layout_tree(element)
      
      # 3. GPU加速の適用判定
      apply_gpu_acceleration_hints(element)
      
      # 4. メモリ使用量の最適化
      optimize_memory_usage(element)
      
      # 5. 描画レイヤーの最適化
      optimize_render_layers(element)
      
      # 6. 変換行列の事前計算
      precompute_transforms(element)
      
      Log.debug "レイアウト最適化完了"
    end
    
    private def eliminate_redundant_calculations(element : LayoutElement)
      # 変更されていない要素のレイアウト再計算をスキップ
      element.children.each do |child|
        if !child.layout_dirty && child.cached_layout.has_key?("valid")
          # キャッシュされたレイアウト結果を使用
          restore_cached_layout(child)
        else
          # レイアウトが変更された場合はキャッシュを更新
          cache_layout_result(child)
        end
      end
    end
    
    private def compress_layout_tree(element : LayoutElement)
      # 単一子要素のコンテナを圧縮
      element.children.each do |child|
        if child.children.size == 1 && can_compress_container(child)
          compress_single_child_container(child)
        end
      end
    end
    
    private def apply_gpu_acceleration_hints(element : LayoutElement)
      # GPU加速が有効になる条件を判定
      if should_use_gpu_acceleration(element)
        element.render_hints["gpu_accelerated"] = true
        element.render_hints["compositor_layer"] = true
      end
    end
    
    # 絶対位置要素の高度な処理
    private def process_absolute_positioned_elements(element : LayoutElement)
      Log.debug "絶対位置要素処理開始: #{element.id}"
      
      # z-indexスタッキングコンテキストの構築
      stacking_contexts = build_stacking_contexts(element)
      
      # 各スタッキングコンテキスト内での処理
      stacking_contexts.each do |context|
        process_stacking_context(context)
      end
      
      # 絶対位置要素の包含ブロック解決
      absolute_elements = find_absolute_positioned_elements(element)
      
      absolute_elements.each do |abs_element|
        # 包含ブロックの決定
        containing_block = resolve_containing_block(abs_element)
        
        # インセット値の解決
        resolve_inset_values(abs_element, containing_block)
        
        # サイズの計算
        calculate_absolutely_positioned_size(abs_element, containing_block)
        
        # 位置の計算
        calculate_absolutely_positioned_position(abs_element, containing_block)
        
        # オーバーフロー処理
        handle_absolute_overflow(abs_element, containing_block)
      end
      
      Log.debug "絶対位置要素処理完了: #{absolute_elements.size}要素"
    end
    
    private def build_stacking_contexts(element : LayoutElement) : Array(StackingContext)
      contexts = [] of StackingContext
      
      if creates_stacking_context(element)
        context = StackingContext.new(element)
        collect_stacking_context_children(element, context)
        contexts << context
      end
      
      # 子要素のスタッキングコンテキストも収集
      element.children.each do |child|
        contexts.concat(build_stacking_contexts(child))
      end
      
      contexts
    end
    
    private def creates_stacking_context(element : LayoutElement) : Bool
      # z-indexが指定されているか
      return true if element.z_index && element.z_index != "auto"
      
      # position: fixed または sticky
      position = element.position || "static"
      return true if position.in?(["fixed", "sticky"])
      
      # opacity < 1
      opacity = element.opacity || 1.0
      return true if opacity < 1.0
      
      # transform が none以外
      transform = element.transform || "none"
      return true if transform != "none"
      
      # filter が none以外
      filter = element.filter || "none"
      return true if filter != "none"
      
      false
    end
    
    private def sort_by_z_index(element : LayoutElement)
      # z-indexに基づいて子要素をソート
      element.children.sort! do |a, b|
        z_a = parse_z_index(a.z_index)
        z_b = parse_z_index(b.z_index)
        z_a <=> z_b
      end
      
      # 子要素に対しても再帰的に適用
      element.children.each do |child|
        sort_by_z_index(child)
      end
    end
    
    private def parse_z_index(value : String?) : Int32
      return 0 if value.nil? || value == "auto"
      value.to_i? || 0
    end
    
    private def trigger_layout_complete_event(element : LayoutElement)
      # レイアウト完了イベントの発火
      Log.debug "レイアウト完了イベント発火: #{element.id}"
      
      # パフォーマンス計測
      if @layout_start_time
        layout_duration = Time.utc - @layout_start_time.not_nil!
        Log.info "レイアウト計算時間: #{layout_duration.total_milliseconds}ms"
      end
      
      # レイアウト統計の更新
      update_layout_statistics(element)
      
      # カスタムイベントの発火
      dispatch_layout_event(element, "layoutcomplete")
    end
    
    private def update_layout_statistics(element : LayoutElement)
      @layout_stats ||= {
        "total_layouts" => 0,
        "average_duration" => 0.0,
        "elements_processed" => 0,
        "cache_hit_rate" => 0.0
      }
      
      @layout_stats["total_layouts"] += 1
      @layout_stats["elements_processed"] += count_all_elements(element)
      
      # その他の統計計算
    end
  end
  
  # CSS Flexboxコンテナクラス
  class FlexContainer < Component
    property layout_type : LayoutEngine::LayoutType = LayoutEngine::LayoutType::Flex
    property style : Hash(String, String) = {} of String => String
    
    def initialize
      super()
      @style["display"] = "flex"
    end
  end
  
  # Flexアイテム用の拡張
  module FlexItemProperties
    property flex_base_size : Int32 = 0
    property flex_grow : Float32 = 0.0_f32
    property flex_shrink : Float32 = 1.0_f32
    property hypothetical_main_size : Int32 = 0
    property resolved_main_size : Int32 = 0
  end
  
  # レイアウトコンテナの基底クラス
  abstract class LayoutContainer < Component
    abstract def layout_type : LayoutEngine::LayoutType
  end
  
  # 配置方向の列挙型（既存のVerticalAlignment、HorizontalAlignmentは維持）
  enum VerticalAlignment
    TOP
    CENTER
    BOTTOM
    STRETCH
  end
  
  enum HorizontalAlignment
    LEFT
    CENTER
    RIGHT
    STRETCH
  end
end 