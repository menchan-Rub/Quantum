# src/crystal/quantum_core/css/layout.cr

require "../dom/manager"
require "./parser"

module QuantumCore::CSS
  # --- スタイル付きノード ---
  class StyledNode
    getter node            : ::QuantumCore::DOM::Node
    getter computed_style  : Hash(String, String)
    getter children        : Array(StyledNode)

    def initialize(node : ::QuantumCore::DOM::Node,
                   computed_style : Hash(String, String),
                   children : Array(StyledNode))
      @node           = node
      @computed_style = computed_style
      @children       = children
    end

    # プロパティ値を取得
    def value(name : String) : String?
      @computed_style[name]
    end

    # display プロパティ判定
    def display : String
      case value("display")
      when "none" then "none"
      when "inline" then "inline"
      else "block"
      end
    end
  end

  # --- ボックスタイプ ---
  enum BoxType
    Block
    Inline
    AnonymousBlock
  end

  # --- レイアウトボックス ---
  class LayoutBox
    getter box_type    : BoxType
    getter styled_node : StyledNode?
    getter children    : Array(LayoutBox)
    getter dimensions  : Dimensions

    def initialize(box_type : BoxType, styled_node : StyledNode? = nil)
      @box_type    = box_type
      @styled_node = styled_node
      @children    = [] of LayoutBox
      @dimensions  = Dimensions.new
    end

    def add_child(child : LayoutBox)
      @children << child
    end
  end

  # --- ボックスモデル基礎構造 ---
  struct Rect
    getter x        : Float64
    getter y        : Float64
    getter width    : Float64
    getter height   : Float64
    def initialize(@x, @y, @width, @height); end
  end

  struct EdgeSizes
    getter top      : Float64
    getter right    : Float64
    getter bottom   : Float64
    getter left     : Float64
    def initialize(@top, @right, @bottom, @left); end
  end

  class Dimensions
    getter content  : Rect
    getter padding  : EdgeSizes
    getter border   : EdgeSizes
    getter margin   : EdgeSizes

    def initialize
      @content = Rect.new(0.0, 0.0, 0.0, 0.0)
      @padding = EdgeSizes.new(0.0, 0.0, 0.0, 0.0)
      @border  = EdgeSizes.new(0.0, 0.0, 0.0, 0.0)
      @margin  = EdgeSizes.new(0.0, 0.0, 0.0, 0.0)
    end

    # パディングを含む矩形
    def padding_box : Rect
      Rect.new(
        content.x - padding.left,
        content.y - padding.top,
        content.width + padding.left + padding.right,
        content.height + padding.top + padding.bottom
      )
    end

    # ボーダーを含む矩形
    def border_box : Rect
      pb = padding_box
      Rect.new(
        pb.x - border.left,
        pb.y - border.top,
        pb.width + border.left + border.right,
        pb.height + border.top + border.bottom
      )
    end

    # マージンを含む矩形
    def margin_box : Rect
      bb = border_box
      Rect.new(
        bb.x - margin.left,
        bb.y - margin.top,
        bb.width + margin.left + margin.right,
        bb.height + margin.top + margin.bottom
      )
    end
  end

  # --- スタイルツリー構築 ---
  def self.style_tree(node : ::QuantumCore::DOM::Node, css_manager : Manager) : StyledNode
    # 計算済みスタイルをマッピング
    styles = {} of String => String
    if node.is_a?(::QuantumCore::DOM::Element)
      el = node.as(::QuantumCore::DOM::Element)
      el.computed_style.each { |k, v| styles[k] = v }
    end
    # 子ノードも再帰的にスタイルツリー化
    children = node.children.map { |c| style_tree(c, css_manager) }
    StyledNode.new(node, styles, children)
  end

  # --- レイアウトツリー構築 ---
  def self.build_layout_tree(root : StyledNode) : LayoutBox
    root_box = LayoutBox.new(BoxType::Block, root)
    root.children.each do |child|
      case child.display
      when "block"
        root_box.add_child(build_layout_tree(child))
      when "inline"
        container = find_inline_container(root_box)
        container.add_child(build_layout_tree(child))
      when "none"
        # 表示なしはスキップ
      end
    end
    root_box
  end

  private def self.find_inline_container(parent : LayoutBox) : LayoutBox
    last = parent.children.last
    if !last || last.box_type != BoxType::AnonymousBlock
      anon = LayoutBox.new(BoxType::AnonymousBlock)
      parent.add_child(anon)
      anon
    else
      last
    end
  end

  # --- レイアウト計算 ---
  def self.layout_tree(root : StyledNode, containing_width : Float64) : LayoutBox
    layout_root = build_layout_tree(root)
    cb = Dimensions.new
    cb.content.x      = 0.0
    cb.content.y      = 0.0
    cb.content.width  = containing_width
    cb.content.height = 0.0
    do_layout(layout_root, cb)
    layout_root
  end

  private def self.do_layout(box : LayoutBox, container : Dimensions)
    calculate_width(box, container)
    calculate_position(box, container)
    layout_children(box)
    calculate_height(box)
  end

  private def self.calculate_width(box : LayoutBox, container : Dimensions)
    return unless box.styled_node
    style = box.styled_node
    d = box.dimensions
    # 算出用ユーティリティ
    ml = px(style.value("margin-left")) || 0.0
    mr = px(style.value("margin-right")) || 0.0
    pl = px(style.value("padding-left")) || 0.0
    pr = px(style.value("padding-right")) || 0.0
    bl = px(style.value("border-left-width")) || 0.0
    br = px(style.value("border-right-width")) || 0.0
    total = ml + mr + pl + pr + bl + br
    # 幅
    if style.value("width")?
      d.content.width = px(style.value("width")!) || 0.0
    else
      d.content.width = container.content.width - total
    end
    # 上下左右ボックスマージン/パディング/ボーダー設定
    d.margin  = EdgeSizes.new(px(style.value("margin-top")) || 0.0,
                              mr,
                              px(style.value("margin-bottom")) || 0.0,
                              ml)
    d.padding = EdgeSizes.new(px(style.value("padding-top")) || 0.0,
                              pr,
                              px(style.value("padding-bottom")) || 0.0,
                              pl)
    d.border  = EdgeSizes.new(px(style.value("border-top-width")) || 0.0,
                              br,
                              px(style.value("border-bottom-width")) || 0.0,
                              bl)
  end

  private def self.calculate_position(box : LayoutBox, container : Dimensions)
    return unless box.styled_node
    d = box.dimensions
    # x: コンテナのコンテント下段 + マージン
    d.content.x = container.content.x + container.padding.left + container.border.left + d.margin.left
    # y: コンテナの下端 + パディング + ボーダー + マージン
    d.content.y = container.content.y + container.content.height + container.padding.top + container.border.top + d.margin.top
  end

  private def self.layout_children(box : LayoutBox)
    d = box.dimensions
    box.children.each do |child|
      do_layout(child, d)
      # コンテント高さを子のマージンボックス下端まで拡張
      mb = child.dimensions.margin_box
      d.content.height = [d.content.height, mb.y + mb.height - d.content.y].max
    end
  end

  private def self.calculate_height(box : LayoutBox)
    return unless box.styled_node
    style = box.styled_node
    if style.value("height")?
      box.dimensions.content.height = px(style.value("height")!) || box.dimensions.content.height
    end
  end

  # px単位パース
  private def self.px(str : String?) : Float64?
    return nil unless str
    if m = /\A(\d+(?:\.\d+)?)(px)?\z/.match(str)
      m[1].to_f64
    else
      # Log.warn "CSS: Cannot parse as px: #{str}"
      nil
    end
  end

  # --- ラインボックス ---
  # インラインレベルの要素を行の中に配置・管理するためのクラス
  class LineBox
    getter children : Array(::QuantumCore::DOM::Node) # このラインに含まれるDOMノード（インライン要素、テキストノードなど）
    getter x : Float64       # ラインボックスの開始X座標 (親要素のコンテントエリア基準)
    getter y : Float64       # ラインボックスの開始Y座標 (親要素のコンテントエリア基準)
    getter width : Float64     # 現在のラインの幅
    getter height : Float64    # 現在のラインの高さ (含まれる要素の最大高に基づく)
    property max_width : Float64 # このラインボックスが取りうる最大の幅 (親コンテナの幅)

    def initialize(@x : Float64, @y : Float64, @max_width : Float64)
      @children = [] of ::QuantumCore::DOM::Node
      @width = 0.0
      @height = 0.0 # 初期高さは0。要素が追加されると更新される
    end

    # ラインに要素を追加できるか試行
    # @param element_width [Float64] 追加しようとする要素の幅
    # @return [Bool] 追加可能ならtrue
    def can_add?(element_width : Float64) : Bool
      # 既に要素があり、スペースがない場合は追加不可
      # (最初の要素は必ず追加できるように、widthが0の場合は常にtrue)
      @width == 0.0 || (@width + element_width <= @max_width)
    end

    # ラインに要素を追加
    # @param node [::QuantumCore::DOM::Node] 追加するDOMノード
    # @param element_layout [CSS::LayoutData] 追加する要素のレイアウト情報
    def add_element(node : ::QuantumCore::DOM::Node, element_layout : CSS::LayoutData)
      @children << node
      
      # 要素の実際のX座標は、このLineBoxの開始X座標 + LineBox内での現在の幅オフセット
      element_layout.x = @x + @width
      # 要素のY座標はこのLineBoxのY座標に合わせる (ベースライン調整は別途必要)
      element_layout.y = @y 

      @width += element_layout.width # 要素の幅を加算
      @height = Math.max(@height, element_layout.height) # ラインの高さを更新
    end

    # ラインがいっぱいかどうか
    def full? : Bool
      @width >= @max_width && @width > 0 # 幅が0の場合はfullとしない
    end

    # ラインが空かどうか
    def empty? : Bool
      @children.empty?
    end
  end
end 