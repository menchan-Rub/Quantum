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
    end
    
    # HTMLフラグメントの解析
    def parse_fragment : DocumentFragment
      fragment = DocumentFragment.new
      
      # フラグメントの解析処理（省略）
      
      fragment
    end
  end
  
  # ドキュメントフラグメント
  class DocumentFragment < Node
    def initialize
      super(NodeType::DocumentFragment)
    end
  end
  
  # セレクタエンジン
  private class SelectorEngine
    # セレクタに一致する最初の要素を返す
    def query_selector(root : Node, selector : String) : Element?
      # 実装は省略
      nil
    end
    
    # セレクタに一致するすべての要素を返す
    def query_selector_all(root : Node, selector : String) : Array(Element)
      # 実装は省略
      [] of Element
    end
  end
  
  # HTML文字列化クラス
  private class HTMLSerializer
    # ノードのシリアライズ
    def serialize(node : Node) : String
      # 実装は省略
      ""
    end
  end
end 