require "../css/manager"
require "../css/layout"
require "../../utils/logger"

module QuantumCore::DOM
  
  # ロガー
  Log = ::Log.for(self)
  
  # --- イベントターゲット機能 ---
  module EventTarget
    alias Listener = Proc(QuantumEvents::Event, Void)

    # イベントリスナーを登録
    def addEventListener(event_type : QuantumEvents::EventType, &listener : Listener)
      @listeners ||= Hash(QuantumEvents::EventType, Array(Listener)).new { |h, k| h[k] = [] of Listener }
      @listeners[event_type] << listener
    end

    # イベントリスナーを解除
    def removeEventListener(event_type : QuantumEvents::EventType, &listener : Listener)
      return unless @listeners && @listeners[event_type]
      @listeners[event_type].delete(listener)
    end

    # イベントをディスパッチ
    def dispatchEvent(event : QuantumEvents::Event)
      # キャプチャフェーズ省略: ターゲットとバブリングのみ実装
      if @listeners && @listeners[event.type]
        @listeners[event.type].each do |l|
          begin
            l.call(event)
          rescue ex
            Log.error { "Event listener error: #{ex.message}" }
          end
        end
      end
      # バブリング: 親ノードへ伝播
      if respond_to?(:parent) && parent
        parent.dispatchEvent(event)
      end
    end
  end

  # --- DOM ノード基底クラス ---
  abstract class Node
    include EventTarget

    getter parent : Node?
    getter children : Array(Node)

    def initialize
      @children = [] of Node
      @parent = nil
    end

    # 子ノードを追加
    def appendChild(child : Node)
      child.remove() if child.parent
      child.instance_variable_set(:@parent, self)
      @children << child
      child
    end

    # 指定ノードを削除
    def removeChild(child : Node)
      idx = @children.index(child)
      raise IndexError.new("Node not a child") unless idx
      @children.delete_at(idx)
      child.instance_variable_set(:@parent, nil)
      child
    end

    # ノード自身を削除
    def remove
      parent.try &.removeChild(self)
    end

    # 子を clone して返す
    def cloneNode(deep : Bool = false) : Node
      clone = self.copy_instance
      if deep
        @children.each do |c|
          clone.appendChild(c.cloneNode(true))
        end
      end
      clone
    end

    # ノード固有のコピーを作成 (サブクラスで override)
    protected def copy_instance : Node
      raise NotImplementedError
    end

    # getElementById (修正済み)
    def getElementById(target_id : String) : Element?
      if self.is_a?(Element) && self.as(Element).getAttribute("id") == target_id
        return self.as(Element)
      end
      @children.each do |c|
        if found = c.getElementById(target_id)
          return found
        end
      end
      nil
    end

    # getElementsByTagName
    def getElementsByTagName(tag_name : String) : Array(Element)
      results = [] of Element
      if self.is_a?(Element) && self.as(Element).tag_name == tag_name.downcase
        results << self.as(Element)
      end
      @children.each do |c|
        results.concat(c.getElementsByTagName(tag_name))
      end
      results
    end

    # querySelectorAll (単純なセレクタ: タグ、#id、.class、[attr=value])
    def querySelectorAll(selector : String) : Array(Element)
      results = [] of Element
      if self.is_a?(Element) && self.as(Element).matches(selector)
        results << self.as(Element)
      end
      @children.each do |c|
        results.concat(c.querySelectorAll(selector))
      end
      results
    end

    def querySelector(selector : String) : Element?
      querySelectorAll(selector).first?
    end

    # getElementsByClassName (追加)
    def getElementsByClassName(class_name : String) : Array(Element)
      results = [] of Element
      if self.is_a?(Element) && self.as(Element).class_list.includes(class_name)
        results << self.as(Element)
      end
      @children.each do |c|
        results.concat(c.getElementsByClassName(class_name))
      end
      results
    end

    # HTML文字列に変換 (全ノード共通)
    def to_html : String
      if self.is_a?(Element)
        self.as(Element).outerHTML
      elsif self.is_a?(TextNode)
        self.as(TextNode).text_content
      else
        ""
      end
    end
  end

  # --- DOM 要素クラス ---
  class Element < Node
    getter tag_name : String
    getter attributes : Hash(String, String)
    getter class_list : Array(String)
    # 計算済みスタイル (プロパティ名 => 値)
    getter computed_style : Hash(String, String)

    def initialize(tag_name : String)
      super()
      @tag_name = tag_name.downcase
      @attributes = {} of String => String
      @class_list = [] of String
      @computed_style = {} of String => String
    end

    def copy_instance : Node
      e = Element.new(@tag_name)
      @attributes.each { |k,v| e.setAttribute(k, v) }
      @children.each { |c| e.appendChild(c.cloneNode(false)) }
      e
    end

    # 属性操作
    def getAttribute(name : String) : String?
      @attributes[name]
    end

    def setAttribute(name : String, value : String)
      @attributes[name] = value
      if name == "class"
        @class_list = value.split(" ").compact.reject(&.empty?)
      end
    end

    def removeAttribute(name : String)
      @attributes.delete(name)
      if name == "class"
        @class_list.clear
      end
    end

    # DOMTokenList のようなクラス操作
    def addClass(cls : String)
      @class_list << cls unless @class_list.includes?(cls)
      @attributes["class"] = @class_list.join(" ")
    end

    def removeClass(cls : String)
      @class_list.delete(cls)
      @attributes["class"] = @class_list.join(" ")
    end

    # セレクタマッチング
    def matches(selector : String) : Bool
      case selector[0]
      when '#'
        getAttribute("id")? == selector[1..]
      when '.'
        @class_list.includes?(selector[1..])
      when '['
        m = \A\[([^=\]]+)=['"]?([^'"\]]+)['"]?\]\z.match(selector)
        m ? getAttribute(m[1]) == m[2] : false
      else
        @tag_name == selector.downcase
      end
    end

    # innerHTML (取得/設定)
    def innerHTML : String
      @children.map(&.to_html).join
    end
    def innerHTML=(html : String)
      @children.clear
      fragment = createDocumentFragment
      fragment.load_html(html)
      fragment.children.each { |c| appendChild(c) }
    end

    # outerHTML
    def outerHTML : String
      "<#{@tag_name}#{attributes_string}>#{innerHTML}</#{@tag_name}>"
    end
    private def attributes_string : String
      @attributes.map { |k,v| " #{k}=\"#{v}\"" }.join
    end

    # getElementsByClassName 呼び出しを委譲
    def getElementsByClassName(class_name : String) : Array(Element)
      super
    end

    # スクリプト実行サポート (Dom Managerの呼び出しを想定)
    def executeScript(js_engine : JavaScript::Engine)
      @children.each do |c|
        if c.is_a?(TextNode)
          js_engine.evaluate(c.as(TextNode).text_content)
        end
      end
    end
  end

  # --- テキストノード ---
  class TextNode < Node
    getter text_content : String

    def initialize(text : String)
      super()
      @text_content = text
    end

    def copy_instance : Node
      TextNode.new(@text_content)
    end
  end

  # --- ドキュメントフラグメント ---
  class DocumentFragment < Node
    # HTMLをパースしてフラグメント化
    def load_html(html : String)
      doc = DOMParser.parse(html)
      doc.children.each { |c| appendChild(c.cloneNode(true)) }
    end
    # HTML文字列に変換
    def to_html : String
      @children.map(&.to_html).join
    end
  end

  # --- ドキュメントノード ---
  class Document < Node
    # ドキュメントのルート要素に相当
    def documentElement : Element?
      @children.first.as?(Element)
    end

    def createElement(tag_name : String) : Element
      Element.new(tag_name)
    end

    def createTextNode(text : String) : TextNode
      TextNode.new(text)
    end

    def copy_instance : Node
      Document.new
    end

    # DocumentFragmentを作成
    def createDocumentFragment : DocumentFragment
      DocumentFragment.new
    end
  end

  # --- HTML パーサ ---
  class DOMParser
    SELF_CLOSING = ["img", "br", "hr", "meta", "link", "input"] of String

    # HTML 文字列をパースして Document を返す
    def self.parse(html : String) : Document
      doc = Document.new
      stack = [doc]
      scanner = Regex.new("<(\\/?)([a-zA-Z][a-zA-Z0-9]*)?([^>]*)>|([^<]+)")
      html.scan(scanner) do |closing, tag, attr_string, text|
        if text
          node = create_text_node(text, stack.last)
          stack.last.appendChild(node)
        elsif tag
          tag_down = tag.downcase
          if closing == "/"
            # 閉じタグ: スタックからポップ
            stack.pop if stack.size > 1
          else
            element = Element.new(tag_down)
            parse_attributes(attr_string, element)
            stack.last.appendChild(element)
            # 自己終了タグでなければスタックにプッシュ
            unless SELF_CLOSING.includes?(tag_down) || attr_string.includes("/")
              stack.push(element)
            end
          end
        end
      end
      doc
    end

    private def self.create_text_node(text : String, parent : Node) : TextNode
      # 改行やタブを含む空白は折りたたむ
      trimmed = text.gsub(/\s+/, " ").strip
      return TextNode.new(trimmed) unless trimmed.empty?
      TextNode.new(trimmed)
    end

    private def self.parse_attributes(attr_str : String, element : Element)
      # 属性名=値 形式を逐次読み取り
      attr_str.scan(/([a-zA-Z_:][a-zA-Z0-9_:\-]*)\s*(=\s*(['"])(.*?)\3)?/) do |name, eq, _q, val|
        element.setAttribute(name, val || "")
      end
    end
  end

  # --- DOM マネージャ ---
  class Manager
    # 現在パースされた Document
    getter document : Document?
    # CSS マネージャー
    getter css_manager : ::QuantumCore::CSS::Manager
    # レイアウトエンジン
    getter layout_engine : Module
    # JavaScript エンジン
    getter js_engine : JavaScript::Engine
    # レンダリングエンジン
    getter rendering_engine : Rendering::Engine
    # ペアリングしている Engine
    getter engine : Engine

    # @param engine [QuantumCore::Engine]
    # @param js_engine [JavaScript::Engine]
    # @param rendering_engine [Rendering::Engine]
    def initialize(engine : Engine, js_engine : JavaScript::Engine, rendering_engine : Rendering::Engine)
      @engine = engine
      @js_engine = js_engine
      @rendering_engine = rendering_engine
      @layout_engine = ::QuantumCore::CSS
      @css_manager = ::QuantumCore::CSS::Manager.new
      @document = nil
      Log.debug { "DOM Manager initialized." }
    end

    # HTML をパースして Document を構築
    def load_html(html : String)
      # DOMの構築
      @document = DOMParser.parse(html)
      Log.debug { "HTML parsed into DOM." }
      # <style>タグ内のCSSを自動追加
      @document.querySelectorAll("style").each do |style_el|
        # テキストノードの結合
        css_text = style_el.children.map { |c| c.is_a?(::QuantumCore::DOM::TextNode) ? c.text_content : "" }.join
        @css_manager.add_stylesheet(css_text)
        Log.debug { "Inline <style> CSS added." }
      end
      # <link rel="stylesheet">要素を検出してファイル読み込み
      @document.querySelectorAll("link").select do |link_el|
        link_el.getAttribute("rel")&.downcase == "stylesheet"
      end.each do |link_el|
        href = link_el.getAttribute("href")
        if href && File.file?(href)
          @css_manager.add_stylesheet_file(href)
          Log.debug { "External CSS loaded from #{href}" }
        end
      end
    end

    # CSS 文字列を追加してパース
    def load_css(css : String)
      @css_manager.add_stylesheet(css)
      Log.debug { "CSS stylesheet loaded." }
    end

    # CSS ファイルを読み込んでパース
    def load_css_file(path : String)
      @css_manager.add_stylesheet_file(path)
      Log.debug { "CSS file loaded: #{path}" }
    end

    # DOM に対して CSS を適用し、レイアウトツリーを構築
    # @param containing_width [Float64]
    # @return [Css::LayoutBox]
    def layout(containing_width : Float64)
      return nil unless @document
      @css_manager.apply_to(@document)
      styled = @layout_engine.style_tree(@document, @css_manager)
      layout_root = @layout_engine.layout_tree(styled, containing_width)
      Log.debug { "Layout tree constructed." }
      layout_root
    end

    # レンダリングエンジンを用いてレイアウトツリーを描画
    # @param layout_root [CSS::LayoutBox]
    def render_layout(layout_root)
      # ここでレンダリングエンジン API を呼び出し、レンダリング処理を行う
      @rendering_engine.render(layout_root)
      Log.debug { "Layout rendered." }
    end

    # Document を取得
    def get_document : Document?
      @document
    end

    # シンプルなクエリ
    def query(selector : String) : Element?
      @document?.querySelector(selector)
    end

    # 複数要素のクエリ
    def queryAll(selector : String) : Array(Element)
      @document?.querySelectorAll(selector) || [] of Element
    end
  end
end 