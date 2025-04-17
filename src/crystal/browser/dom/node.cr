module QuantumCore
  # DOMノードの基本クラス
  abstract class Node
    # ノードタイプの列挙型
    enum NodeType
      Element
      Text
      Comment
      Document
      DocumentType
      ProcessingInstruction
      DocumentFragment
    end
    
    getter parent : Node?
    getter children : Array(Node)
    getter node_type : NodeType
    
    def initialize(@node_type : NodeType)
      @parent = nil
      @children = [] of Node
    end
    
    # 子ノードの追加
    def append_child(child : Node)
      # 既存の親からの削除
      if child.parent
        child.parent.not_nil!.remove_child(child)
      end
      
      # 子ノードの親を設定
      child.parent = self
      
      # 子ノードリストに追加
      @children << child
      
      # 追加した子ノードを返す
      child
    end
    
    # 子ノードの削除
    def remove_child(child : Node) : Node
      index = @children.index(child)
      
      if index
        # 子ノードリストから削除
        @children.delete_at(index)
        
        # 子ノードの親をnilに設定
        child.parent = nil
        
        # 削除した子ノードを返す
        child
      else
        # 子ノードが見つからない場合はエラー
        raise "指定された子ノードが見つかりません"
      end
    end
    
    # 子ノードの全削除
    def remove_all_children
      @children.dup.each do |child|
        remove_child(child)
      end
    end
    
    # 子ノードの挿入
    def insert_before(new_child : Node, reference_child : Node) : Node
      # 参照子ノードのインデックスを取得
      index = @children.index(reference_child)
      
      if index
        # 既存の親からの削除
        if new_child.parent
          new_child.parent.not_nil!.remove_child(new_child)
        end
        
        # 子ノードの親を設定
        new_child.parent = self
        
        # 子ノードリストに挿入
        @children.insert(index, new_child)
        
        # 挿入した子ノードを返す
        new_child
      else
        # 参照子ノードが見つからない場合は最後に追加
        append_child(new_child)
      end
    end
    
    # 全子孫ノードに対して処理を適用
    def walk(&block : Node -> Nil)
      # 自身に処理を適用
      yield self
      
      # 子ノードに再帰的に適用
      @children.each do |child|
        child.walk(&block)
      end
    end
    
    # テキスト内容の取得（再帰的）
    def text_content : String
      # 子ノードのテキスト内容を結合
      result = ""
      
      @children.each do |child|
        case child
        when TextNode
          result += child.text
        else
          result += child.text_content
        end
      end
      
      result
    end
    
    # 最初の子ノードを取得
    def first_child : Node?
      @children.first?
    end
    
    # 最後の子ノードを取得
    def last_child : Node?
      @children.last?
    end
    
    # 次の兄弟ノードを取得
    def next_sibling : Node?
      return nil unless parent = @parent
      
      siblings = parent.children
      index = siblings.index(self)
      
      return nil unless index
      
      siblings[index + 1]?
    end
    
    # 前の兄弟ノードを取得
    def previous_sibling : Node?
      return nil unless parent = @parent
      
      siblings = parent.children
      index = siblings.index(self)
      
      return nil unless index || index == 0
      
      siblings[index - 1]?
    end
    
    # CSSセレクタによる要素の検索
    def query_selector(selector : String) : Element?
      selector_engine = SelectorEngine.new
      selector_engine.query_selector(self, selector)
    end
    
    # CSSセレクタによる全要素の検索
    def query_selector_all(selector : String) : Array(Element)
      selector_engine = SelectorEngine.new
      selector_engine.query_selector_all(self, selector)
    end
    
    # 親ノードの設定（内部用）
    protected def parent=(parent : Node?)
      @parent = parent
    end
  end
  
  # ドキュメントノード
  class Document < Node
    def initialize
      super(NodeType::Document)
    end
    
    # ドキュメント要素（HTML要素）の取得
    def document_element : Element?
      @children.find { |child| child.is_a?(Element) }.as(Element?)
    end
    
    # head要素の取得
    def head : Element?
      document_element.try &.query_selector("head")
    end
    
    # body要素の取得
    def body : Element?
      document_element.try &.query_selector("body")
    end
    
    # タイトルの取得
    def title : String
      title_element = document_element.try &.query_selector("title")
      title_element ? title_element.text_content : ""
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
  end
  
  # 要素ノード
  class Element < Node
    getter tag_name : String
    getter attributes : Hash(String, String)
    
    def initialize(@tag_name : String)
      super(NodeType::Element)
      @attributes = {} of String => String
    end
    
    # 属性の取得
    def [](name : String) : String?
      @attributes[name]?
    end
    
    # 属性の設定
    def []=(name : String, value : String)
      @attributes[name] = value
    end
    
    # 属性の存在確認
    def has_attribute?(name : String) : Bool
      @attributes.has_key?(name)
    end
    
    # 属性の削除
    def remove_attribute(name : String)
      @attributes.delete(name)
    end
    
    # すべての属性の取得
    def get_attribute_names : Array(String)
      @attributes.keys
    end
    
    # ID属性の取得
    def id : String?
      self["id"]?
    end
    
    # ID属性の設定
    def id=(value : String)
      self["id"] = value
    end
    
    # クラス属性の取得
    def class_name : String?
      self["class"]?
    end
    
    # クラス属性の設定
    def class_name=(value : String)
      self["class"] = value
    end
    
    # クラスリストの取得
    def class_list : Array(String)
      class_name ? class_name.not_nil!.split(/\s+/).reject(&.empty?) : [] of String
    end
    
    # クラスの存在確認
    def has_class?(class_name : String) : Bool
      class_list.includes?(class_name)
    end
    
    # クラスの追加
    def add_class(class_name : String)
      current_classes = class_list
      unless current_classes.includes?(class_name)
        current_classes << class_name
        self.class_name = current_classes.join(" ")
      end
    end
    
    # クラスの削除
    def remove_class(class_name : String)
      current_classes = class_list
      if current_classes.includes?(class_name)
        current_classes.delete(class_name)
        self.class_name = current_classes.join(" ")
      end
    end
    
    # HTMLの内容を設定
    def inner_html=(html : String)
      # 現在の子ノードをすべて削除
      remove_all_children
      
      # HTMLパーサーの作成
      parser = HTMLParser.new(html)
      
      # フラグメントの解析
      fragment = parser.parse_fragment
      
      # 解析された子ノードを追加
      fragment.children.each do |child|
        append_child(child)
      end
    end
    
    # HTMLの内容を取得
    def inner_html : String
      serializer = HTMLSerializer.new
      
      # 子ノードをシリアライズ
      result = ""
      children.each do |child|
        result += serializer.serialize(child)
      end
      
      result
    end
    
    # テキスト内容を設定
    def text_content=(text : String)
      # 現在の子ノードをすべて削除
      remove_all_children
      
      # テキストノードを作成して追加
      append_child(TextNode.new(text))
    end
  end
  
  # テキストノード
  class TextNode < Node
    getter text : String
    
    def initialize(@text : String)
      super(NodeType::Text)
    end
    
    # テキスト内容の更新
    def text=(value : String)
      @text = value
    end
    
    # テキスト内容の取得
    def text_content : String
      @text
    end
  end
  
  # コメントノード
  class CommentNode < Node
    getter text : String
    
    def initialize(@text : String)
      super(NodeType::Comment)
    end
    
    # コメント内容の更新
    def text=(value : String)
      @text = value
    end
  end
  
  # HTMLパーサー（フラグメント解析機能を追加）
  private class HTMLParser
    def initialize(@html_content : String)
      @current_position = 0
      @length = @html_content.size
    end
    
    # HTMLフラグメントの解析
    def parse_fragment : DocumentFragment
      fragment = DocumentFragment.new
      
      while @current_position < @length
        if peek_char == '<'
          if peek_next_char == '/'
            skip_end_tag
          elsif peek_next_char == '!'
            if is_comment_start
              fragment.append_child(parse_comment)
            else
              # DOCTYPE等の特殊タグをスキップ
              skip_until('>')
              advance
            end
          else
            element = parse_element
            fragment.append_child(element) if element
          end
        else
          fragment.append_child(parse_text)
        end
      end
      
      fragment
    end
    
    private def parse_element : Element?
      advance # '<'を消費
      
      # タグ名の解析
      tag_name = parse_identifier
      return nil if tag_name.empty?
      
      element = Element.new(tag_name)
      
      # 属性の解析
      parse_attributes(element)
      
      # 自己終了タグの処理
      if peek_char == '/' && peek_next_char == '>'
        advance(2) # '/>'を消費
        return element
      end
      
      # 開始タグの終了
      if peek_char == '>'
        advance # '>'を消費
        
        # 子要素の解析（終了タグまで）
        parse_children(element, tag_name)
      end
      
      element
    end
    
    private def parse_attributes(element : Element)
      while @current_position < @length
        skip_whitespace
        
        # 属性解析終了条件
        break if peek_char == '>' || peek_char == '/' && peek_next_char == '>'
        
        # 属性名
        attr_name = parse_identifier
        break if attr_name.empty?
        
        # 属性値
        attr_value = ""
        if peek_char == '='
          advance # '='を消費
          attr_value = parse_attribute_value
        end
        
        element.set_attribute(attr_name, attr_value)
      end
    end
    
    private def parse_attribute_value : String
      skip_whitespace
      
      if peek_char == '"' || peek_char == '\''
        quote = current_char
        advance # 引用符を消費
        
        value = parse_until { |c| c == quote }
        advance # 終了引用符を消費
        
        return value
      else
        # 引用符なしの属性値
        return parse_until { |c| c.whitespace? || c == '>' || c == '/' }
      end
    end
    
    private def parse_children(parent : Element, parent_tag : String)
      while @current_position < @length
        if peek_char == '<' && peek_next_char == '/'
          # 終了タグの確認
          pos = @current_position
          advance(2) # '</'を消費
          tag_name = parse_identifier
          
          if tag_name.downcase == parent_tag.downcase
            skip_until('>')
            advance # '>'を消費
            break
          else
            # 不一致の終了タグは無視してテキストとして扱う
            @current_position = pos
            parent.append_child(parse_text)
          end
        elsif peek_char == '<'
          if peek_next_char == '!'
            if is_comment_start
              parent.append_child(parse_comment)
            else
              # DOCTYPE等の特殊タグをスキップ
              skip_until('>')
              advance
            end
          else
            element = parse_element
            parent.append_child(element) if element
          end
        else
          parent.append_child(parse_text)
        end
      end
    end
    
    private def parse_text : TextNode
      text = parse_until { |c| c == '<' }
      TextNode.new(text)
    end
    
    private def parse_comment : CommentNode
      advance(4) # '<!--'を消費
      
      comment_text = ""
      while @current_position < @length
        if current_char == '-' && peek_next_char == '-' && peek_char(2) == '>'
          break
        end
        comment_text += current_char
        advance
      end
      
      advance(3) # '-->'を消費
      CommentNode.new(comment_text)
    end
    
    private def is_comment_start : Bool
      @current_position + 3 < @length &&
        peek_char == '<' && 
        peek_next_char == '!' && 
        peek_char(2) == '-' && 
        peek_char(3) == '-'
    end
    
    private def parse_identifier : String
      identifier = ""
      while @current_position < @length
        c = current_char
        break unless c.alphanumeric? || c == '-' || c == '_' || c == ':'
        identifier += c
        advance
      end
      identifier
    end
    
    private def parse_until(&block : Char -> Bool) : String
      result = ""
      while @current_position < @length
        c = current_char
        break if yield(c)
        result += c
        advance
      end
      result
    end
    
    private def skip_until(char : Char)
      while @current_position < @length && current_char != char
        advance
      end
    end
    
    private def skip_end_tag
      advance(2) # '</'を消費
      while @current_position < @length && current_char != '>'
        advance
      end
      advance if @current_position < @length # '>'を消費
    end
    
    private def skip_whitespace
      while @current_position < @length && current_char.whitespace?
        advance
      end
    end
    
    private def current_char : Char
      @html_content[@current_position]
    end
    
    private def peek_char(offset = 0) : Char
      pos = @current_position + offset
      pos < @length ? @html_content[pos] : '\0'
    end
    
    private def peek_next_char : Char
      peek_char(1)
    end
    
    private def advance(count = 1)
      @current_position += count
    end
  end
  
  # ドキュメントフラグメント
  class DocumentFragment < Node
    def initialize
      super(NodeType::DocumentFragment)
    end
    
    # フラグメントからHTML文字列を生成
    def to_html : String
      serializer = HTMLSerializer.new
      serializer.serialize(self)
    end
    
    # 指定されたセレクタに一致する最初の要素を検索
    def query_selector(selector : String) : Element?
      SelectorEngine.new.query_selector(self, selector)
    end
    
    # 指定されたセレクタに一致するすべての要素を検索
    def query_selector_all(selector : String) : Array(Element)
      SelectorEngine.new.query_selector_all(self, selector)
    end
    
    # HTML文字列からフラグメントを作成する便利メソッド
    def self.from_html(html : String) : DocumentFragment
      parser = HTMLParser.new(html)
      parser.parse_fragment
    end
  end
  
  # セレクタエンジン
  private class SelectorEngine
    # セレクタに一致する最初の要素を返す
    def query_selector(root : Node, selector : String) : Element?
      selectors = parse_selectors(selector)
      
      # 深さ優先探索で最初に一致する要素を見つける
      visit_nodes(root) do |node|
        next unless node.is_a?(Element)
        
        # いずれかのセレクタに一致するか確認
        selectors.each do |sel|
          return node.as(Element) if matches_selector?(node.as(Element), sel)
        end
      end
      
      nil
    end
    
    # セレクタに一致するすべての要素を返す
    def query_selector_all(root : Node, selector : String) : Array(Element)
      selectors = parse_selectors(selector)
      results = [] of Element
      
      # 深さ優先探索ですべての一致要素を見つける
      visit_nodes(root) do |node|
        next unless node.is_a?(Element)
        
        # いずれかのセレクタに一致するか確認
        selectors.each do |sel|
          results << node.as(Element) if matches_selector?(node.as(Element), sel)
        end
      end
      
      results
    end
    
    private def visit_nodes(node : Node, &block : Node -> Void)
      block.call(node)
      
      node.children.each do |child|
        visit_nodes(child, &block)
      end
    end
    
    private def parse_selectors(selector_text : String) : Array(String)
      # カンマで区切られた複数のセレクタを処理
      selector_text.split(',').map(&.strip)
    end
    
    private def matches_selector?(element : Element, selector : String) : Bool
      # 基本的なセレクタマッチング実装
      
      # IDセレクタ (#id)
      if selector.starts_with?('#')
        id_value = selector[1..]
        return element.id == id_value
      end
      
      # クラスセレクタ (.class)
      if selector.starts_with?('.')
        class_name = selector[1..]
        return element.has_class?(class_name)
      end
      
      # タグセレクタ (div)
      if selector.matches?(/^[a-zA-Z][a-zA-Z0-9]*$/)
        return element.tag_name.downcase == selector.downcase
      end
      
      # 属性セレクタ ([attr], [attr=value])
      if selector.starts_with?('[') && selector.ends_with?(']')
        attr_selector = selector[1...-1]
        
        if attr_selector.includes?('=')
          parts = attr_selector.split('=', 2)
          attr_name = parts[0].strip
          attr_value = parts[1].strip.gsub(/^["']|["']$/, "") # 引用符を削除
          
          return element.has_attribute?(attr_name) && element.get_attribute(attr_name) == attr_value
        else
          return element.has_attribute?(attr_selector.strip)
        end
      end
      
      # 複合セレクタは現在サポートされていない
      false
    end
  end
  
  # HTML文字列化クラス
  private class HTMLSerializer
    # ノードのシリアライズ
    def serialize(node : Node) : String
      case node.node_type
      when NodeType::Element
        serialize_element(node.as(Element))
      when NodeType::Text
        serialize_text(node.as(TextNode))
      when NodeType::Comment
        serialize_comment(node.as(CommentNode))
      when NodeType::DocumentFragment
        serialize_fragment(node.as(DocumentFragment))
      else
        ""
      end
    end
    
    private def serialize_element(element : Element) : String
      result = "<#{element.tag_name}"
      
      # 属性の追加
      element.attributes.each do |name, value|
        result += " #{name}"
        result += "=\"#{escape_attribute(value)}\"" unless value.empty?
      end
      
      # 自己終了タグの処理
      if element.children.empty? && is_void_element?(element.tag_name)
        result += " />"
        return result
      end
      
      result += ">"
      
      # 子要素の処理
      element.children.each do |child|
        result += serialize(child)
      end
      
      # 終了タグ
      result += "</#{element.tag_name}>"
      result
    end
    
    private def serialize_text(text_node : TextNode) : String
      escape_html(text_node.text)
    end
    
    private def serialize_comment(comment_node : CommentNode) : String
      "<!--#{comment_node.text}-->"
    end
    
    private def serialize_fragment(fragment : DocumentFragment) : String
      result = ""
      fragment.children.each do |child|
        result += serialize(child)
      end
      result
    end
    
    private def escape_html(text : String) : String
      text.gsub(/[&<>]/) do |match|
        case match
        when '&' then "&amp;"
        when '<' then "&lt;"
        when '>' then "&gt;"
        else match
        end
      end
    end
    
    private def escape_attribute(value : String) : String
      value.gsub(/[&"<>]/) do |match|
        case match
        when '&' then "&amp;"
        when '"' then "&quot;"
        when '<' then "&lt;"
        when '>' then "&gt;"
        else match
        end
      end
    end
    
    private def is_void_element?(tag_name : String) : Bool
      # HTML5の空要素（自己終了タグ）
      void_elements = ["area", "base", "br", "col", "embed", "hr", "img", "input", 
                       "link", "meta", "param", "source", "track", "wbr"]
      void_elements.includes?(tag_name.downcase)
    end
  end
end 