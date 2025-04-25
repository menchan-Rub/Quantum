# CSS パーサとスタイル適用のコア実装
# src/crystal/quantum_core/css/parser.cr

require "../dom/manager"

module QuantumCore::CSS
  # 計算済みスタイル用の構造体 (プロパティ、値、特異度、ソース順)
  struct ComputedDeclaration
    getter property : String
    getter value    : String
    getter specificity : Int32
    getter order : Int32
    def initialize(@property : String, @value : String, @specificity : Int32, @order : Int32); end
  end

  # --- CSS宣言 (property: value) ---
  class Declaration
    getter property : String
    getter value    : String
    # @param property CSSプロパティ名
    # @param value CSSプロパティの値 (文字列)
    def initialize(@property : String, @value : String); end
  end

  # --- セレクタの抽象基底 ---
  abstract class Selector
    # 要素がこのセレクタにマッチするか判定
    abstract def match?(element : ::QuantumCore::DOM::Element) : Bool
    # セレクタの特異度 (ID:100, Class:10, Type:1)
    abstract def specificity : Int32
  end

  # タイプセレクタ (タグ名)
  class TypeSelector < Selector
    getter tag_name : String
    def initialize(@tag_name : String)
      @tag_name = @tag_name.downcase
    end
    def match?(element) : Bool
      element.tag_name == @tag_name
    end
    def specificity : Int32
      1
    end
  end

  # クラスセレクタ (.class)
  class ClassSelector < Selector
    getter class_name : String
    def initialize(@class_name : String); end
    def match?(element) : Bool
      element.class_list.includes(@class_name)
    end
    def specificity : Int32
      10
    end
  end

  # IDセレクタ (#id)
  class IdSelector < Selector
    getter id : String
    def initialize(@id : String); end
    def match?(element) : Bool
      element.getAttribute("id")? == @id
    end
    def specificity : Int32
      100
    end
  end

  # 属性セレクタ ([attr] or [attr=value])
  class AttributeSelector < Selector
    getter name  : String
    getter value : String?
    def initialize(@name : String, @value : String? = nil); end
    def match?(element) : Bool
      val = element.getAttribute(name)
      if value
        val? == value
      else
        !!val?
      end
    end
    def specificity : Int32
      10
    end
  end

  # ワイルドカードセレクタ (*)
  class UniversalSelector < Selector
    def initialize; end
    def match?(element) : Bool
      true
    end
    def specificity : Int32
      0
    end
  end

  # --- ルールセット (セレクタ群 + 宣言群) ---
  class Rule
    getter selectors    : Array(Selector)
    getter declarations : Array(Declaration)

    def initialize(@selectors : Array(Selector), @declarations : Array(Declaration)); end
  end

  # --- スタイルシート ---
  class Stylesheet
    getter rules : Array(Rule)
    def initialize(@rules : Array(Rule)); end

    # CSS文字列をパースしてStylesheetを返す
    def self.parse(css : String) : Stylesheet
      # コメントを除去して解析用文字列を準備
      clean_css = css.gsub(/\/\*[\s\S]*?\*\//, "")
      rules = [] of Rule
      # シンプルなルールブロック検出 (selectors { declarations })
      scanner = Regex.new("(.*?)\\{(.*?)\\}", Regex::MULTILINE)
      clean_css.scan(scanner) do |selector_text, decl_text|
        # セレクタをカンマで分割
        sels = selector_text.split(",").map(&.strip).map do |sel|
          case sel[0]
          when '*'
            UniversalSelector.new
          when '['
            m = /\[([^=\]]+)(?:=(['"]?)(.*?)\2)?\]/.match(sel)
            if m
              name = m[1]
              val = m[3] && !m[3].empty? ? m[3] : nil
              AttributeSelector.new(name, val)
            else
              TypeSelector.new(sel)
            end
          when '#'
            IdSelector.new(sel[1..])
          when '.'
            ClassSelector.new(sel[1..])
          else
            TypeSelector.new(sel)
          end
        end
        # 宣言をセミコロンで分割
        decls = [] of Declaration
        decl_text.split(";").map(&.strip).each do |d|
          next if d.empty?
          prop, val = d.split(":", 2).map(&.strip)
          decls << Declaration.new(prop, val)
        end
        rules << Rule.new(sels, decls)
      end
      Stylesheet.new(rules)
    end

    # インライン style 属性文字列をパースして Declaration の配列を返す
    private def self.parse_inline_style(style_str : String) : Array(Declaration)
      decls = [] of Declaration
      style_str.split(";").map(&.strip).each do |d|
        next if d.empty?
        prop, val = d.split(":", 2).map(&.strip)
        decls << Declaration.new(prop, val)
      end
      decls
    end

    # DOM全体にスタイルを適用し、Element#computed_styleを更新する
    def apply_to(document : ::QuantumCore::DOM::Document) : Void
      apply_node(document)
    end

    private def apply_node(node : ::QuantumCore::DOM::Node) : Void
      if node.is_a?(::QuantumCore::DOM::Element)
        apply_to_element(node.as(::QuantumCore::DOM::Element))
      end
      node.children.each do |child|
        apply_node(child)
      end
    end

    private def apply_to_element(element : ::QuantumCore::DOM::Element) : Void
      # マッチするルールから ComputedDeclaration を収集
      decls = [] of ComputedDeclaration
      @rules.each_with_index do |rule, r_index|
        rule.selectors.each do |sel|
          if sel.match?(element)
            rule.declarations.each do |d|
              decls << ComputedDeclaration.new(d.property, d.value, sel.specificity, r_index)
            end
            break
          end
        end
      end
      # インライン style 属性を最優先で適用 (specificity=1000, order=-1)
      if inline = element.getAttribute("style")
        self.class.parse_inline_style(inline).each do |d|
          decls << ComputedDeclaration.new(d.property, d.value, 1000, -1)
        end
      end
      # 既存の計算済みスタイルをクリア
      element.computed_style.clear
      # プロパティごとに特異度とソース順で最適な宣言を選択
      decls.group_by { |d| d.property }.each do |prop, ds|
        best = ds.max_by { |d| [d.specificity, d.order] }
        element.computed_style[prop] = best.value
      end
    end
  end
end 