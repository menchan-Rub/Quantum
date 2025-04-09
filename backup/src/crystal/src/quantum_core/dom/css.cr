module QuantumCore
  # CSSスタイルシート
  class Stylesheet
    # 優先度を表す列挙型
    enum Priority
      UserAgent
      User
      Author
    end
    
    getter rules : Array(StyleRule)
    getter priority : Priority
    
    def initialize(@priority = Priority::Author)
      @rules = [] of StyleRule
    end
    
    # スタイルルールの追加
    def add_rule(rule : StyleRule)
      @rules << rule
    end
    
    # スタイルシートの結合
    def merge(other : Stylesheet)
      result = Stylesheet.new
      
      # 自身のルールをコピー
      @rules.each do |rule|
        result.add_rule(rule)
      end
      
      # 他のスタイルシートのルールをコピー
      other.rules.each do |rule|
        result.add_rule(rule)
      end
      
      result
    end
  end
  
  # CSSスタイルルール
  class StyleRule
    getter selectors : Array(Selector)
    getter declarations : Array(Declaration)
    
    def initialize(@selectors : Array(Selector), @declarations : Array(Declaration))
    end
    
    # 要素に適用可能か判定
    def applies_to_element?(element : Element) : Bool
      @selectors.any? { |selector| selector.matches?(element) }
    end
    
    # ルールの詳細度（specificity）を計算
    def specificity : Int32
      # 最も詳細度の高いセレクタを使用
      @selectors.map(&.specificity).max || 0
    end
  end
  
  # CSSセレクタ
  abstract class Selector
    # 要素がセレクタにマッチするか判定
    abstract def matches?(element : Element) : Bool
    
    # セレクタの詳細度を計算
    abstract def specificity : Int32
  end
  
  # タイプセレクタ（要素名によるセレクタ）
  class TypeSelector < Selector
    getter element_name : String
    
    def initialize(@element_name : String)
    end
    
    # 要素名によるマッチング
    def matches?(element : Element) : Bool
      element.tag_name.downcase == @element_name.downcase
    end
    
    # タイプセレクタの詳細度は 0,0,1
    def specificity : Int32
      1
    end
  end
  
  # IDセレクタ
  class IdSelector < Selector
    getter id : String
    
    def initialize(@id : String)
    end
    
    # ID属性によるマッチング
    def matches?(element : Element) : Bool
      element.id == @id
    end
    
    # IDセレクタの詳細度は 1,0,0
    def specificity : Int32
      100
    end
  end
  
  # クラスセレクタ
  class ClassSelector < Selector
    getter class_name : String
    
    def initialize(@class_name : String)
    end
    
    # クラス属性によるマッチング
    def matches?(element : Element) : Bool
      element.has_class?(@class_name)
    end
    
    # クラスセレクタの詳細度は 0,1,0
    def specificity : Int32
      10
    end
  end
  
  # 属性セレクタ
  class AttributeSelector < Selector
    # 属性マッチング方法の列挙型
    enum MatchType
      Exists        # [attr]
      Equals        # [attr=val]
      Contains      # [attr~=val]
      StartsWith    # [attr^=val]
      EndsWith      # [attr$=val]
      Substring     # [attr*=val]
      DashedPrefix  # [attr|=val]
    end
    
    getter attribute_name : String
    getter attribute_value : String?
    getter match_type : MatchType
    
    def initialize(@attribute_name : String, @attribute_value : String? = nil, @match_type = MatchType::Exists)
    end
    
    # 属性によるマッチング
    def matches?(element : Element) : Bool
      # 属性が存在するかチェック
      attr_value = element[@attribute_name]?
      return false unless attr_value || @match_type == MatchType::Exists
      
      # 属性値によるマッチング
      case @match_type
      when MatchType::Exists
        # 属性が存在すればOK
        return true
      when MatchType::Equals
        # 属性値が完全一致
        return attr_value == @attribute_value
      when MatchType::Contains
        # スペースで区切られた値のいずれかにマッチ
        return attr_value.split(/\s+/).includes?(@attribute_value)
      when MatchType::StartsWith
        # 前方一致
        return attr_value.starts_with?(@attribute_value.not_nil!)
      when MatchType::EndsWith
        # 後方一致
        return attr_value.ends_with?(@attribute_value.not_nil!)
      when MatchType::Substring
        # 部分一致
        return attr_value.includes?(@attribute_value.not_nil!)
      when MatchType::DashedPrefix
        # ハイフン区切りの前置詞一致
        return attr_value == @attribute_value || attr_value.starts_with?("#{@attribute_value.not_nil!}-")
      end
      
      false
    end
    
    # 属性セレクタの詳細度は 0,1,0
    def specificity : Int32
      10
    end
  end
  
  # 擬似クラスセレクタ
  class PseudoClassSelector < Selector
    getter name : String
    getter argument : String?
    
    def initialize(@name : String, @argument : String? = nil)
    end
    
    # 擬似クラスによるマッチング
    def matches?(element : Element) : Bool
      case @name
      when "first-child"
        # 最初の子要素かチェック
        element.parent.try { |p| p.children.first? == element }
      when "last-child"
        # 最後の子要素かチェック
        element.parent.try { |p| p.children.last? == element }
      when "nth-child"
        # nth-child の実装は複雑なので省略
        false
      when "hover"
        # 動的状態なのでレンダリング時に評価
        false
      when "active"
        # 動的状態なのでレンダリング時に評価
        false
      when "focus"
        # 動的状態なのでレンダリング時に評価
        false
      else
        # 未実装の擬似クラス
        false
      end
    end
    
    # 擬似クラスセレクタの詳細度は 0,1,0
    def specificity : Int32
      10
    end
  end
  
  # 擬似要素セレクタ
  class PseudoElementSelector < Selector
    getter name : String
    
    def initialize(@name : String)
    end
    
    # 擬似要素によるマッチング
    def matches?(element : Element) : Bool
      # 擬似要素は実際のDOMノードではなく、CSSで生成される仮想的な要素なので
      # ここでの評価は常にfalse。レンダリング時に特別処理される。
      false
    end
    
    # 擬似要素セレクタの詳細度は 0,0,1
    def specificity : Int32
      1
    end
  end
  
  # 結合子（コンビネータ）
  enum Combinator
    Descendant  # 子孫結合子（スペース）
    Child       # 直接の子結合子（>）
    Adjacent    # 隣接兄弟結合子（+）
    General     # 一般兄弟結合子（~）
  end
  
  # 複合セレクタ
  class CompoundSelector < Selector
    getter components : Array(Selector)
    
    def initialize(@components = [] of Selector)
    end
    
    # 複合セレクタのマッチング（すべてのコンポーネントがマッチする必要がある）
    def matches?(element : Element) : Bool
      @components.all? { |selector| selector.matches?(element) }
    end
    
    # 複合セレクタの詳細度は各コンポーネントの詳細度の合計
    def specificity : Int32
      @components.sum(&.specificity)
    end
    
    # コンポーネントの追加
    def add(selector : Selector)
      @components << selector
    end
  end
  
  # 複数セレクタ（カンマ区切りのセレクタリスト）
  class SelectorList < Selector
    getter selectors : Array(Selector)
    
    def initialize(@selectors = [] of Selector)
    end
    
    # 複数セレクタのマッチング（いずれかのセレクタがマッチすればOK）
    def matches?(element : Element) : Bool
      @selectors.any? { |selector| selector.matches?(element) }
    end
    
    # 複数セレクタの詳細度は最も詳細なセレクタの詳細度
    def specificity : Int32
      @selectors.map(&.specificity).max || 0
    end
    
    # セレクタの追加
    def add(selector : Selector)
      @selectors << selector
    end
  end
  
  # CSS宣言
  class Declaration
    getter property : String
    getter value : String
    getter important : Bool
    
    def initialize(@property : String, @value : String, @important = false)
    end
    
    # 優先度（!importantがあれば高い）
    def priority : Int32
      @important ? 1 : 0
    end
  end
  
  # 計算スタイル（要素に適用された最終的なスタイル）
  class ComputedStyle
    getter styles : Hash(String, String)
    
    def initialize
      @styles = {} of String => String
    end
    
    # スタイルの取得
    def [](property : String) : String?
      @styles[property]?
    end
    
    # スタイルの設定
    def []=(property : String, value : String)
      @styles[property] = value
    end
    
    # スタイルのマージ
    def merge!(other : ComputedStyle)
      other.styles.each do |property, value|
        @styles[property] = value
      end
    end
    
    # スタイルのコピーを作成
    def clone : ComputedStyle
      result = ComputedStyle.new
      @styles.each do |property, value|
        result[property] = value
      end
      result
    end
  end
  
  # CSSカスケードを適用するクラス
  class StyleResolver
    def initialize(@stylesheets : Array(Stylesheet))
    end
    
    # 要素の計算スタイルを取得
    def compute_style(element : Element) : ComputedStyle
      # 計算スタイルの初期化
      computed_style = ComputedStyle.new
      
      # 要素に適用されるすべての宣言を収集
      declarations = collect_declarations(element)
      
      # 宣言を適用
      declarations.each do |declaration|
        computed_style[declaration.property] = declaration.value
      end
      
      computed_style
    end
    
    private def collect_declarations(element : Element) : Array(Declaration)
      # 適用可能なすべての宣言を収集
      applicable_declarations = [] of Tuple(Declaration, StyleRule, Stylesheet::Priority)
      
      # スタイルシートを優先度順に走査
      @stylesheets.each do |stylesheet|
        stylesheet.rules.each do |rule|
          # ルールが要素に適用可能か確認
          if rule.applies_to_element?(element)
            # ルールの宣言を収集
            rule.declarations.each do |declaration|
              applicable_declarations << {declaration, rule, stylesheet.priority}
            end
          end
        end
      end
      
      # 宣言をソート（カスケード順）
      sorted_declarations = sort_declarations(applicable_declarations)
      
      # 最終的な宣言リストを返す
      sorted_declarations.map { |tuple| tuple[0] }
    end
    
    private def sort_declarations(declarations : Array(Tuple(Declaration, StyleRule, Stylesheet::Priority))) : Array(Tuple(Declaration, StyleRule, Stylesheet::Priority))
      # CSS カスケーディングルールに従ってソート
      declarations.sort do |a, b|
        decl_a, rule_a, priority_a = a
        decl_b, rule_b, priority_b = b
        
        # 1. !important の宣言が優先
        if decl_a.important && !decl_b.important
          -1
        elsif !decl_a.important && decl_b.important
          1
        else
          # 2. スタイルシートの優先度
          if priority_a != priority_b
            priority_b.to_i <=> priority_a.to_i
          else
            # 3. セレクタの詳細度
            if rule_a.specificity != rule_b.specificity
              rule_b.specificity <=> rule_a.specificity
            else
              # 4. 宣言順（後のものが優先）
              0 # ここでは宣言順は考慮していない
            end
          end
        end
      end
    end
  end
end 