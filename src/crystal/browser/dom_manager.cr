require "./config"
require "./dom/*"

module QuantumCore
  # DOMツリーの管理と操作を担当するクラス
  class DOMManager
    # イベントコールバックの型定義
    alias DocumentReadyCallback = Proc(Document, Nil)
    
    getter config : Config::CoreConfig
    
    def initialize(@config : Config::CoreConfig)
      @document_ready_callbacks = [] of DocumentReadyCallback
    end
    
    # DOMマネージャーの起動
    def start
      # 必要なリソースの初期化
    end
    
    # DOMマネージャーのシャットダウン
    def shutdown
      # リソースの解放
    end
    
    # HTMLの解析
    def parse_html(html_content : String) : Document
      # HTMLパーサーの初期化
      parser = HTMLParser.new(html_content)
      
      # HTMLの解析
      document = parser.parse
      
      # ドキュメント準備完了イベントの通知
      notify_document_ready(document)
      
      document
    end
    
    # CSSの解析
    def parse_css(css_content : String) : Stylesheet
      # CSSパーサーの初期化
      parser = CSSParser.new(css_content)
      
      # CSSの解析
      parser.parse
    end
    
    # ドキュメント準備完了コールバックの登録
    def on_document_ready(&callback : DocumentReadyCallback)
      @document_ready_callbacks << callback
    end
    
    # 要素の作成
    def create_element(tag_name : String) : Element
      Element.new(tag_name)
    end
    
    # テキストノードの作成
    def create_text_node(text : String) : TextNode
      TextNode.new(text)
    end
    
    # コメントノードの作成
    def create_comment(text : String) : CommentNode
      CommentNode.new(text)
    end
    
    # CSSセレクタによる要素の検索
    def query_selector(root : Node, selector : String) : Element?
      selector_engine = SelectorEngine.new
      selector_engine.query_selector(root, selector)
    end
    
    # CSSセレクタによる全要素の検索
    def query_selector_all(root : Node, selector : String) : Array(Element)
      selector_engine = SelectorEngine.new
      selector_engine.query_selector_all(root, selector)
    end
    
    # HTMLの文字列化
    def serialize_to_html(node : Node) : String
      serializer = HTMLSerializer.new
      serializer.serialize(node)
    end
    
    private def notify_document_ready(document : Document)
      @document_ready_callbacks.each do |callback|
        callback.call(document)
      end
    end
  end
  
  # HTML解析を担当するクラス
  private class HTMLParser
    def initialize(@html_content : String)
      @current_position = 0
      @current_token = Token.new(TokenType::EOF, "")
    end
    
    # HTMLの解析処理
    def parse : Document
      document = Document.new
      
      # ドキュメントタイプの解析
      parse_doctype
      
      # HTML要素の解析
      html_element = parse_element("html") || Element.new("html")
      document.append_child(html_element)
      
      # head要素が無ければ作成
      head_element = html_element.query_selector("head") || begin
        head = Element.new("head")
        html_element.append_child(head)
        head
      end
      
      # body要素が無ければ作成
      body_element = html_element.query_selector("body") || begin
        body = Element.new("body")
        html_element.append_child(body)
        body
      end
      
      document
    end
    
    private def parse_doctype
      # DOCTYPE宣言の解析
      skip_whitespace
      
      if @current_position + 9 <= @html_content.size && @html_content[@current_position, 9].downcase == "<!doctype"
        @current_position += 9
        skip_whitespace
        
        # DOCTYPE名の取得（通常は "html"）
        doctype_name = ""
        while @current_position < @html_content.size && !is_whitespace?(@html_content[@current_position]) && @html_content[@current_position] != '>'
          doctype_name += @html_content[@current_position]
          @current_position += 1
        end
        
        # 残りのDOCTYPE宣言をスキップ
        while @current_position < @html_content.size && @html_content[@current_position] != '>'
          @current_position += 1
        end
        
        # 終了タグをスキップ
        @current_position += 1 if @current_position < @html_content.size
        
        @current_token = Token.new(TokenType::Doctype, doctype_name)
      end
    end
    
    private def parse_element(tag_name : String) : Element?
      element = Element.new(tag_name)
      
      # 開始タグの解析
      if consume_if_match("<#{tag_name}")
        # 属性の解析
        parse_attributes(element)
        
        # 自己終了タグかチェック
        if consume_if_match("/>")
          return element
        end
        
        # 通常の開始タグの終了
        consume_if_match(">")
        
        # 子要素と内容の解析
        parse_children(element)
        
        # 終了タグの解析
        consume_if_match("</#{tag_name}>")
      else
        return nil
      end
      
      element
    end
    
    private def parse_attributes(element : Element)
      skip_whitespace
      
      while @current_position < @html_content.size && !is_tag_end?
        # 属性名の解析
        attr_name = ""
        while @current_position < @html_content.size && !is_whitespace? && @html_content[@current_position] != '=' && !is_tag_end?
          attr_name += @html_content[@current_position]
          @current_position += 1
        end
        
        skip_whitespace
        
        # 属性値の解析
        attr_value = ""
        if consume_if_match("=")
          skip_whitespace
          
          # 引用符の種類を確認
          quote = @html_content[@current_position]? || ' '
          if quote == '"' || quote == '\''
            @current_position += 1
            
            # 引用符内の値を取得
            while @current_position < @html_content.size && @html_content[@current_position] != quote
              attr_value += @html_content[@current_position]
              @current_position += 1
            end
            
            # 終了引用符をスキップ
            @current_position += 1 if @current_position < @html_content.size
          else
            # 引用符なしの属性値
            while @current_position < @html_content.size && !is_whitespace? && !is_tag_end?
              attr_value += @html_content[@current_position]
              @current_position += 1
            end
          end
        end
        
        # 空でない属性名の場合、要素に属性を追加
        if !attr_name.empty?
          element.set_attribute(attr_name, attr_value)
        end
        
        skip_whitespace
      end
    end
    
    private def parse_children(element : Element)
      while @current_position < @html_content.size
        # 終了タグのチェック
        if @current_position + 2 + element.tag_name.size <= @html_content.size &&
           @html_content[@current_position, 2 + element.tag_name.size] == "</#{element.tag_name}"
          break
        end
        
        # 子要素の開始タグをチェック
        if @html_content[@current_position] == '<' && @current_position + 1 < @html_content.size && 
           @html_content[@current_position + 1] != '/'
          
          # タグ名の取得
          @current_position += 1
          child_tag_name = ""
          while @current_position < @html_content.size && !is_whitespace? && @html_content[@current_position] != '>' && @html_content[@current_position] != '/'
            child_tag_name += @html_content[@current_position]
            @current_position += 1
          end
          
          # 現在位置を戻す
          @current_position -= (child_tag_name.size + 1)
          
          # 子要素の解析
          if child_element = parse_element(child_tag_name)
            element.append_child(child_element)
          end
        else
          # テキストノードの解析
          text_content = parse_text
          if !text_content.empty?
            text_node = TextNode.new(text_content)
            element.append_child(text_node)
          end
        end
      end
    end
    
    private def parse_text : String
      text = ""
      while @current_position < @html_content.size && @html_content[@current_position] != '<'
        text += @html_content[@current_position]
        @current_position += 1
      end
      text
    end
    
    private def skip_whitespace
      while @current_position < @html_content.size && is_whitespace?(@html_content[@current_position])
        @current_position += 1
      end
    end
    
    private def is_whitespace?(char : Char) : Bool
      char == ' ' || char == '\t' || char == '\n' || char == '\r'
    end
    
    private def is_whitespace? : Bool
      @current_position < @html_content.size && is_whitespace?(@html_content[@current_position])
    end
    
    private def is_tag_end? : Bool
      @current_position < @html_content.size && (@html_content[@current_position] == '>' || (@html_content[@current_position] == '/' && @current_position + 1 < @html_content.size && @html_content[@current_position + 1] == '>'))
    end
    
    private def consume_if_match(str : String) : Bool
      if @current_position + str.size <= @html_content.size && @html_content[@current_position, str.size] == str
        @current_position += str.size
        return true
      end
      false
    end
    
    # トークンタイプの定義
    private enum TokenType
      StartTag
      EndTag
      Text
      Comment
      Doctype
      EOF
    end
    
    # トークンの定義
    private class Token
      getter type : TokenType
      getter value : String
      getter attributes : Hash(String, String)?
      
      def initialize(@type, @value, @attributes = nil)
      end
    end
  end
  
  # CSS解析を担当するクラス
  private class CSSParser
    def initialize(@css_content : String)
      @current_position = 0
    end
    
    # CSSの解析処理
    def parse : Stylesheet
      stylesheet = Stylesheet.new
      
      # スタイルルールの解析
      while !eof?
        # コメントのスキップ
        skip_whitespace_and_comments
        
        break if eof?
        
        # セレクタの解析
        selectors = parse_selectors
        
        # 宣言ブロックの解析
        declarations = parse_declarations
        
        # スタイルルールの作成と追加
        if !selectors.empty? && !declarations.empty?
          rule = StyleRule.new(selectors, declarations)
          stylesheet.add_rule(rule)
        end
      end
      
      stylesheet
    end
    # セレクタの解析処理
    private def parse_selectors : Array(Selector)
      selectors = [] of Selector
      
      while !eof?
        skip_whitespace_and_comments
        
        # カンマで区切られた複数のセレクタを処理
        selector = parse_single_selector
        selectors << selector if selector
        
        skip_whitespace_and_comments
        
        # カンマがあれば次のセレクタへ
        if peek_char == ','
          consume_char
        else
          # カンマがなければセレクタリストの終了
          break
        end
      end
      
      selectors
    end
    
    # 単一セレクタの解析
    private def parse_single_selector : Selector?
      selector = Selector.new
      
      while !eof? && peek_char != ',' && peek_char != '{'
        skip_whitespace_and_comments
        
        # セレクタの種類に応じた解析
        case peek_char
        when '#'
          # IDセレクタ
          consume_char # '#'を消費
          id = parse_identifier
          selector.add_condition(IDCondition.new(id))
        when '.'
          # クラスセレクタ
          consume_char # '.'を消費
          class_name = parse_identifier
          selector.add_condition(ClassCondition.new(class_name))
        when '['
          # 属性セレクタ
          consume_char # '['を消費
          attr_selector = parse_attribute_selector
          selector.add_condition(attr_selector)
          expect_char(']')
        when ':'
          # 疑似クラス/要素
          consume_char # ':'を消費
          if peek_char == ':'
            consume_char # 2つ目の':'を消費
            pseudo_element = parse_identifier
            selector.add_pseudo_element(pseudo_element)
          else
            pseudo_class = parse_identifier
            selector.add_pseudo_class(pseudo_class)
          end
        when '>'
          # 子孫セレクタ
          consume_char
          selector.combinator = Combinator::Child
        when '+'
          # 隣接兄弟セレクタ
          consume_char
          selector.combinator = Combinator::AdjacentSibling
        when '~'
          # 一般兄弟セレクタ
          consume_char
          selector.combinator = Combinator::GeneralSibling
        when '*'
          # ユニバーサルセレクタ
          consume_char
          selector.is_universal = true
        else
          # 要素セレクタ
          if is_identifier_start(peek_char)
            tag_name = parse_identifier
            selector.tag_name = tag_name
          end
        end
        
        skip_whitespace_and_comments
      end
      
      selector
    end
    
    # 宣言ブロックの解析
    private def parse_declarations : Array(Declaration)
      declarations = [] of Declaration
      
      # 宣言ブロックの開始
      expect_char('{')
      
      while !eof?
        skip_whitespace_and_comments
        
        # 宣言ブロックの終了
        break if peek_char == '}'
        
        # プロパティ名
        property = parse_identifier
        
        skip_whitespace_and_comments
        
        # コロン
        expect_char(':')
        
        skip_whitespace_and_comments
        
        # 値
        value = parse_value
        
        skip_whitespace_and_comments
        
        # セミコロン（オプション）
        if peek_char == ';'
          consume_char
        end
        
        # 宣言の追加
        declarations << Declaration.new(property, value)
      end
      
      # 宣言ブロックの終了
      expect_char('}')
      
      declarations
    end
    
    # CSS値の解析
    private def parse_value : String
      value = ""
      
      while !eof? && peek_char != ';' && peek_char != '}'
        value += consume_char
      end
      
      value.strip
    end
    
    # 属性セレクタの解析
    private def parse_attribute_selector : AttributeCondition
      skip_whitespace_and_comments
      
      # 属性名
      attr_name = parse_identifier
      
      skip_whitespace_and_comments
      
      # 属性演算子がない場合は存在チェック
      if peek_char == ']'
        return AttributeCondition.new(attr_name)
      end
      
      # 属性演算子
      operator = ""
      case peek_char
      when '='
        operator = "="
        consume_char
      when '^', '$', '*', '~', '|'
        operator = consume_char
        expect_char('=')
        operator += "="
      else
        # 無効な演算子
        raise "Invalid attribute selector operator at position #{@current_position}"
      end
      
      skip_whitespace_and_comments
      
      # 属性値
      attr_value = ""
      if peek_char == '"' || peek_char == '\''
        quote = consume_char
        while !eof? && peek_char != quote
          attr_value += consume_char
        end
        expect_char(quote)
      else
        while !eof? && is_identifier_char(peek_char)
          attr_value += consume_char
        end
      end
      
      AttributeCondition.new(attr_name, operator, attr_value)
    end
    
    # 識別子の解析
    private def parse_identifier : String
      identifier = ""
      
      # 識別子の開始文字
      if !is_identifier_start(peek_char)
        raise "Expected identifier at position #{@current_position}"
      end
      
      # 識別子の文字列を収集
      while !eof? && is_identifier_char(peek_char)
        identifier += consume_char
      end
      
      identifier
    end
    
    # 空白文字とコメントのスキップ
    private def skip_whitespace_and_comments
      loop do
        # 空白文字のスキップ
        while !eof? && is_whitespace(peek_char)
          consume_char
        end
        
        # コメントのスキップ
        if !eof? && peek_char == '/' && peek_next_char == '*'
          consume_char # '/'を消費
          consume_char # '*'を消費
          
          # コメント終了を探す
          while !eof? && !(peek_char == '*' && peek_next_char == '/')
            consume_char
          end
          
          if !eof?
            consume_char # '*'を消費
            consume_char # '/'を消費
          end
          
          continue
        end
        
        break
      end
    end
    
    # 次の文字を取得（消費しない）
    private def peek_char : Char
      return '\0' if eof?
      @css_content[@current_position]
    end
    
    # 次の次の文字を取得（消費しない）
    private def peek_next_char : Char
      return '\0' if @current_position + 1 >= @css_content.size
      @css_content[@current_position + 1]
    end
    
    # 文字を消費して次に進む
    private def consume_char : Char
      char = peek_char
      @current_position += 1
      char
    end
    
    # 期待する文字かチェック
    private def expect_char(expected : Char)
      if peek_char != expected
        raise "Expected '#{expected}' at position #{@current_position}, got '#{peek_char}'"
      end
      consume_char
    end
    
    # 識別子の開始文字かチェック
    private def is_identifier_start(c : Char) : Bool
      c.letter? || c == '_' || c == '-'
    end
    
    # 識別子の文字かチェック
    private def is_identifier_char(c : Char) : Bool
      is_identifier_start(c) || c.number?
    end
    
    # 空白文字かチェック
    private def is_whitespace(c : Char) : Bool
      c == ' ' || c == '\t' || c == '\n' || c == '\r'
    end
    
    # EOFチェック
    private def eof? : Bool
      @current_position >= @css_content.size
    end
  end
  
  # CSSセレクタエンジン
  private class SelectorEngine
    # セレクタに一致する最初の要素を返す
    def query_selector(root : Node, selector : String) : Element?
      results = query_selector_all(root, selector, 1)
      results.first?
    end
    
    # セレクタに一致するすべての要素を返す
    def query_selector_all(root : Node, selector : String, limit : Int32 = Int32::MAX) : Array(Element)
      # セレクタの解析
      parsed_selectors = parse_selectors(selector)
      
      # 要素の検索
      results = [] of Element
      
      # 根要素から開始して再帰的に要素を検索
      collect_matching_elements(root, parsed_selectors, results, limit)
      
      results
    end
    
    private def parse_selectors(selector_text : String) : Array(Selector)
      parser = CSSParser.new(selector_text)
      parser.parse.rules.map(&.selectors).flatten
    end
    
    private def collect_matching_elements(node : Node, selectors : Array(Selector), results : Array(Element), limit : Int32)
      # 要素のみを対象に
      return unless node.is_a?(Element)
      
      # セレクタとのマッチング確認
      if matches_any_selector?(node, selectors)
        results << node.as(Element)
        return if results.size >= limit
      end
      
      # 子ノードに対して再帰的に適用
      node.children.each do |child|
        collect_matching_elements(child, selectors, results, limit)
        break if results.size >= limit
      end
    end
    
    private def matches_any_selector?(element : Element, selectors : Array(Selector)) : Bool
      selectors.any? { |selector| matches_selector?(element, selector) }
    end
    
    private def matches_selector?(element : Element, selector : Selector) : Bool
      # タグ名のチェック
      return false if !selector.tag_name.empty? && selector.tag_name != element.tag_name && !selector.is_universal
      
      # 条件のチェック
      selector.conditions.all? do |condition|
        case condition
        when IDCondition
          element.id == condition.id
        when ClassCondition
          element.has_class?(condition.class_name)
        when AttributeCondition
          matches_attribute?(element, condition)
        else
          false
        end
      end
    end
    
    private def matches_attribute?(element : Element, condition : AttributeCondition) : Bool
      # 属性の存在チェック
      return element.has_attribute?(condition.name) if condition.operator.empty?
      
      # 属性値のチェック
      return false unless element.has_attribute?(condition.name)
      
      attr_value = element.get_attribute(condition.name)
      return false if attr_value.nil?
      
      # 演算子に応じたマッチング
      case condition.operator
      when "="
        # 完全一致
        attr_value == condition.value
      when "^="
        # 前方一致
        attr_value.starts_with?(condition.value)
      when "$="
        # 後方一致
        attr_value.ends_with?(condition.value)
      when "*="
        # 部分一致
        attr_value.includes?(condition.value)
      when "~="
        # 空白区切りの単語一致
        attr_value.split.includes?(condition.value)
      when "|="
        # ハイフン区切りの前置一致
        attr_value == condition.value || attr_value.starts_with?("#{condition.value}-")
      else
        false
      end
    end
  end
  
  # HTML文字列化クラス
  private class HTMLSerializer
    def serialize(node : Node) : String
      io = IO::Memory.new
      serialize_node(node, io)
      io.to_s
    end
    
    private def serialize_node(node : Node, io : IO)
      case node
      when Document
        # XML宣言と文書型宣言
        io << "<!DOCTYPE html>\n"
        
        # 子ノードをシリアライズ
        node.children.each do |child|
          serialize_node(child, io)
        end
        
      when Element
        element = node.as(Element)
        
        # 開始タグ
        io << "<" << element.tag_name
        
        # 属性
        element.attributes.each do |name, value|
          io << " " << name << "=\"" << escape_attribute(value) << "\""
        end
        
        # 子ノードがない場合は自己終了タグ
        if element.children.empty? && is_void_element?(element.tag_name)
          io << " />"
          return
        end
        
        io << ">"
        
        # 子ノード
        element.children.each do |child|
          serialize_node(child, io)
        end
        
        # 終了タグ
        io << "</" << element.tag_name << ">"
        
      when TextNode
        text_node = node.as(TextNode)
        io << escape_text(text_node.text)
        
      when CommentNode
        comment_node = node.as(CommentNode)
        io << "<!--" << comment_node.text << "-->"
      end
    end
    
    private def escape_text(text : String) : String
      text.gsub(/[&<>]/) do |char|
        case char
        when '&' then "&amp;"
        when '<' then "&lt;"
        when '>' then "&gt;"
        else char
        end
      end
    end
    
    private def escape_attribute(value : String) : String
      value.gsub(/[&<>"']/) do |char|
        case char
        when '&' then "&amp;"
        when '<' then "&lt;"
        when '>' then "&gt;"
        when '"' then "&quot;"
        when '\'' then "&#39;"
        else char
        end
      end
    end
    
    private def is_void_element?(tag_name : String) : Bool
      # HTML5の空要素リスト
      %w(area base br col embed hr img input link meta param source track wbr).includes?(tag_name.downcase)
    end
  end
end