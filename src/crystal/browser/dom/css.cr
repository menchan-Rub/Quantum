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
    enum PseudoType
      Static    # 静的な状態（構造に基づく）
      Dynamic   # 動的な状態（ユーザーインタラクションに基づく）
      Form      # フォーム要素の状態
      Language  # 言語関連
      Location  # ナビゲーション関連
    end
    
    getter name : String
    getter argument : String?
    getter pseudo_type : PseudoType
    
    def initialize(@name : String, @argument : String? = nil)
      @pseudo_type = determine_pseudo_type(@name)
    end
    
    private def determine_pseudo_type(name : String) : PseudoType
      case name
      when "first-child", "last-child", "nth-child", "nth-last-child", "only-child",
           "first-of-type", "last-of-type", "nth-of-type", "nth-last-of-type", "only-of-type",
           "root", "empty", "not", "has", "is", "where"
        PseudoType::Static
      when "hover", "active", "focus", "focus-within", "focus-visible", "target", "visited"
        PseudoType::Dynamic
      when "enabled", "disabled", "checked", "indeterminate", "valid", "invalid", "required", "optional", "read-only", "read-write"
        PseudoType::Form
      when "lang", "dir"
        PseudoType::Language
      when "link", "any-link", "local-link"
        PseudoType::Location
      else
        PseudoType::Static
      end
    end
    
    # 擬似クラスによるマッチング
    def matches?(element : Element) : Bool
      case @name
      # 構造的擬似クラス
      when "first-child"
        element.parent.try { |p| p.children.first? == element } || false
      when "last-child"
        element.parent.try { |p| p.children.last? == element } || false
      when "only-child"
        element.parent.try { |p| p.children.size == 1 && p.children.first? == element } || false
      when "nth-child"
        parse_and_match_nth_expression(element, @argument, false, false)
      when "nth-last-child"
        parse_and_match_nth_expression(element, @argument, true, false)
      when "first-of-type"
        element.parent.try do |p|
          siblings_of_type = p.children.select { |c| c.tag_name == element.tag_name }
          siblings_of_type.first? == element
        end || false
      when "last-of-type"
        element.parent.try do |p|
          siblings_of_type = p.children.select { |c| c.tag_name == element.tag_name }
          siblings_of_type.last? == element
        end || false
      when "only-of-type"
        element.parent.try do |p|
          siblings_of_type = p.children.select { |c| c.tag_name == element.tag_name }
          siblings_of_type.size == 1 && siblings_of_type.first? == element
        end || false
      when "nth-of-type"
        parse_and_match_nth_expression(element, @argument, false, true)
      when "nth-last-of-type"
        parse_and_match_nth_expression(element, @argument, true, true)
      when "root"
        element.tag_name == "html"
      when "empty"
        element.children.empty? && element.text_content.strip.empty?
      
      # 動的擬似クラス
      when "hover"
        element.is_hovered?
      when "active"
        element.is_active?
      when "focus"
        element.is_focused?
      when "focus-within"
        element.is_focused? || element.descendants.any?(&.is_focused?)
      when "focus-visible"
        element.is_focused? && element.is_keyboard_focused?
      when "target"
        document_url = element.owner_document.try(&.url)
        return false unless document_url
        
        fragment = URI.parse(document_url).fragment
        return false unless fragment
        
        element.id == fragment
      when "visited"
        return false unless element.tag_name == "a" && element.has_attribute?("href")
        href = element["href"]
        element.owner_document.try(&.browser_context.try(&.history.is_visited?(href))) || false
      
      # フォーム関連擬似クラス
      when "enabled"
        !element.has_attribute?("disabled") && ["input", "button", "select", "textarea", "optgroup", "option", "fieldset"].includes?(element.tag_name)
      when "disabled"
        element.has_attribute?("disabled") && ["input", "button", "select", "textarea", "optgroup", "option", "fieldset"].includes?(element.tag_name)
      when "checked"
        (element.tag_name == "input" && ["checkbox", "radio"].includes?(element["type"]?) && element.has_attribute?("checked")) ||
        (element.tag_name == "option" && element.has_attribute?("selected"))
      when "indeterminate"
        (element.tag_name == "input" && element["type"]? == "checkbox" && element.is_indeterminate?) ||
        (element.tag_name == "progress" && !element.has_attribute?("value"))
      when "valid"
        element.is_valid_form_element?
      when "invalid"
        element.is_invalid_form_element?
      when "required"
        ["input", "select", "textarea"].includes?(element.tag_name) && element.has_attribute?("required")
      when "optional"
        ["input", "select", "textarea"].includes?(element.tag_name) && !element.has_attribute?("required")
      when "read-only"
        (["input", "textarea"].includes?(element.tag_name) && element.has_attribute?("readonly")) ||
        !["input", "textarea", "select"].includes?(element.tag_name)
      when "read-write"
        (["input", "textarea"].includes?(element.tag_name) && !element.has_attribute?("readonly") && !element.has_attribute?("disabled"))
      
      # 言語関連擬似クラス
      when "lang"
        return false unless @argument
        element_lang = find_lang_attribute(element)
        return false unless element_lang
        element_lang.starts_with?(@argument) && (element_lang.size == @argument.size || element_lang[@argument.size] == '-')
      when "dir"
        return false unless @argument
        element_dir = find_dir_attribute(element)
        element_dir == @argument
      
      # 否定・関数型擬似クラス
      when "not"
        return false unless @argument
        # 引数のセレクタをパースして、それに一致しないかチェック
        parsed_selector = SelectorParser.parse(@argument)
        !parsed_selector.matches?(element)
      when "has"
        return false unless @argument
        # 引数のセレクタをパースして、子孫に一致する要素があるかチェック
        parsed_selector = SelectorParser.parse(@argument)
        element.descendants.any? { |desc| parsed_selector.matches?(desc) }
      when "is", "where"
        return false unless @argument
        # カンマ区切りのセレクタリストをパースして、いずれかに一致するかチェック
        @argument.split(',').any? do |selector_str|
          parsed_selector = SelectorParser.parse(selector_str.strip)
          parsed_selector.matches?(element)
        end
      
      # リンク関連擬似クラス
      when "link", "any-link"
        (element.tag_name == "a" || element.tag_name == "area") && element.has_attribute?("href")
      when "local-link"
        return false unless element.tag_name == "a" && element.has_attribute?("href")
        href = element["href"]
        document_url = element.owner_document.try(&.url)
        return false unless document_url
        
        begin
          href_uri = URI.parse(href)
          doc_uri = URI.parse(document_url)
          href_uri.host == doc_uri.host
        rescue
          false
        end
      
      else
        # 未実装または不明な擬似クラス
        false
      end
    end
    
    # nth-child/nth-of-type式のパースと評価
    private def parse_and_match_nth_expression(element : Element, expression : String?, reverse : Bool, of_type : Bool) : Bool
      return false unless expression && element.parent
      
      # 特殊キーワードの処理
      case expression.strip
      when "odd"
        a, b = 2, 1
      when "even"
        a, b = 2, 0
      else
        # an+b 形式の式をパース
        if expression =~ /^([+-]?\d*)?n([+-]\d+)?$/i
          a_str = $1
          b_str = $2
          
          a = if a_str.nil? || a_str.empty?
                1
              elsif a_str == "-"
                -1
              else
                a_str.to_i
              end
          
          b = b_str ? b_str.to_i : 0
        elsif expression =~ /^([+-]?\d+)$/
          # 単純な数値
          a, b = 0, $1.to_i
        else
          # 無効な式
          return false
        end
      end
      
      # 要素のインデックスを取得
      parent = element.parent.not_nil!
      siblings = of_type ? parent.children.select { |c| c.tag_name == element.tag_name } : parent.children
      
      index = siblings.index(element)
      return false unless index
      
      # 逆順の場合はインデックスを反転
      position = reverse ? siblings.size - index : index + 1
      
      # an+b 式の評価
      if a == 0
        # 単純な位置一致
        position == b
      else
        # 一般式の評価: position = an + b を満たすnが存在するか
        # (position - b) / a = n となるnが整数かつn ≥ 0であることを確認
        diff = position - b
        a != 0 && diff % a == 0 && diff / a >= 0
      end
    end
    
    # 要素とその祖先から言語属性を見つける
    private def find_lang_attribute(element : Element) : String?
      current = element
      while current
        if current.has_attribute?("lang")
          return current["lang"]
        end
        current = current.parent
      end
      
      # HTML要素のlang属性が見つからない場合、Content-Languageヘッダーを確認
      element.owner_document.try(&.content_language)
    end
    
    # 要素とその祖先から方向属性を見つける
    private def find_dir_attribute(element : Element) : String?
      current = element
      while current
        if current.has_attribute?("dir")
          return current["dir"]
        end
        current = current.parent
      end
      nil
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
      # 通常のマッチングでは常にfalseを返す
      # レンダリングエンジンが描画時に特別処理する
      case @name
      when "before", "after"
        # ::before, ::afterは内容生成のためにレンダリング時に処理
        # content プロパティが設定されているかどうかを確認
        element.computed_style.try { |style| style.has_property?("content") } || false
      when "first-line"
        # テキストの最初の行に適用される擬似要素
        # ブロックレベル要素かつテキストコンテナであることを確認
        element.is_block_element? && element.is_text_container?
      when "first-letter"
        # テキストの最初の文字に適用される擬似要素
        # ブロックレベル要素かつテキストコンテンツが存在することを確認
        element.is_block_element? && element.is_text_container? && 
          element.text_content.strip.size > 0
      when "selection"
        # 選択されたテキストに適用される擬似要素
        # 選択状態はレンダリング時に動的に評価される
        element.is_selectable?
      when "marker"
        # リスト項目のマーカーに適用される擬似要素
        element.tag_name == "li" || 
          (element.computed_style.try { |style| style.get_property("display") == "list-item" } || false)
      when "placeholder"
        # 入力フィールドのプレースホルダーテキストに適用
        ["input", "textarea"].includes?(element.tag_name) && 
          element.has_attribute?("placeholder")
      when "backdrop"
        # フルスクリーン要素の背後に表示される擬似要素
        element.is_fullscreen? || false
      when "cue", "cue-region"
        # WebVTTキューに適用される擬似要素
        element.tag_name == "track" || element.parent.try(&.tag_name) == "track"
      when "file-selector-button"
        # input[type=file]のファイル選択ボタンに適用
        element.tag_name == "input" && element.get_attribute("type") == "file"
      when "part"
        # Shadow DOMのパーツに適用
        @argument.try { |part_name| element.has_part?(part_name) } || false
      when "slotted"
        # スロットに割り当てられた要素に適用
        element.assigned_slot? || false
      when "target"
        # URLのフラグメント識別子がこの要素を指している場合
        element.has_attribute?("id") && element.get_attribute("id") == element.document.fragment_target
      when "highlight"
        # ハイライト擬似要素（CSS Highlight API）
        @argument.try { |highlight_name| element.has_highlight?(highlight_name) } || false
      when "spelling-error"
        # スペルミスのテキストに適用される擬似要素
        element.has_spelling_errors?
      when "grammar-error"
        # 文法エラーのテキストに適用される擬似要素
        element.has_grammar_errors?
      else
        # 未知の擬似要素は常にfalse
        false
      end
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