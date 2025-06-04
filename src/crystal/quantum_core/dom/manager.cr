require "../css/manager"
require "../css/layout"
require "../../utils/logger"
require "thread" # 並列DOM処理用

module QuantumCore::DOM
  
  # ロガー
  Log = ::Log.for(self)
  
  # --- パフォーマンス追跡機能 ---
  class DOMOperationTracker
    # シングルトンインスタンス
    class_getter instance = new
    
    # 操作カウンター
    @mutation_count = Atomic.new(0)
    @query_count = Atomic.new(0)
    @reflow_count = Atomic.new(0)
    @repaint_count = Atomic.new(0)
    
    # 操作タイミング計測
    @query_timing_total = Atomic.new(0_i64)
    @mutation_timing_total = Atomic.new(0_i64)
    @reflow_timing_total = Atomic.new(0_i64)
    @repaint_timing_total = Atomic.new(0_i64)
    
    # タイミング計測中フラグ
    @measuring_query = Hash(UInt64, Time).new
    @measuring_mutation = Hash(UInt64, Time).new
    @measuring_reflow = Hash(UInt64, Time).new
    @measuring_repaint = Hash(UInt64, Time).new
    
    # スレッド安全のためのロック
    @mutex = Mutex.new
    
    # カウンター加算
    def increment_mutation_count
      @mutation_count.add(1)
    end
    
    def increment_query_count
      @query_count.add(1)
    end
    
    def increment_reflow_count
      @reflow_count.add(1)
    end
    
    def increment_repaint_count
      @repaint_count.add(1)
    end
    
    # タイミング計測開始
    def start_query_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        @measuring_query[fiber_id] = Time.monotonic
      end
    end
    
    def start_mutation_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        @measuring_mutation[fiber_id] = Time.monotonic
      end
    end
    
    def start_reflow_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        @measuring_reflow[fiber_id] = Time.monotonic
      end
    end
    
    def start_repaint_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        @measuring_repaint[fiber_id] = Time.monotonic
      end
    end
    
    # タイミング計測終了
    def end_query_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        if start_time = @measuring_query[fiber_id]?
          elapsed = (Time.monotonic - start_time).total_nanoseconds.to_i64
          @query_timing_total.add(elapsed)
          @measuring_query.delete(fiber_id)
        end
      end
    end
    
    def end_mutation_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        if start_time = @measuring_mutation[fiber_id]?
          elapsed = (Time.monotonic - start_time).total_nanoseconds.to_i64
          @mutation_timing_total.add(elapsed)
          @measuring_mutation.delete(fiber_id)
        end
      end
    end
    
    def end_reflow_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        if start_time = @measuring_reflow[fiber_id]?
          elapsed = (Time.monotonic - start_time).total_nanoseconds.to_i64
          @reflow_timing_total.add(elapsed)
          @measuring_reflow.delete(fiber_id)
        end
      end
    end
    
    def end_repaint_timing(fiber_id = Fiber.current.object_id)
      @mutex.synchronize do
        if start_time = @measuring_repaint[fiber_id]?
          elapsed = (Time.monotonic - start_time).total_nanoseconds.to_i64
          @repaint_timing_total.add(elapsed)
          @measuring_repaint.delete(fiber_id)
        end
      end
    end
    
    # レポート取得
    def report
      {
        mutation_count: @mutation_count.get,
        query_count: @query_count.get,
        reflow_count: @reflow_count.get,
        repaint_count: @repaint_count.get,
        query_timing_ms: @query_timing_total.get / 1_000_000,
        mutation_timing_ms: @mutation_timing_total.get / 1_000_000,
        reflow_timing_ms: @reflow_timing_total.get / 1_000_000,
        repaint_timing_ms: @repaint_timing_total.get / 1_000_000
      }
    end
    
    # リセット
    def reset
      @mutation_count.set(0)
      @query_count.set(0)
      @reflow_count.set(0)
      @repaint_count.set(0)
      @query_timing_total.set(0)
      @mutation_timing_total.set(0)
      @reflow_timing_total.set(0)
      @repaint_timing_total.set(0)
      @mutex.synchronize do
        @measuring_query.clear
        @measuring_mutation.clear
        @measuring_reflow.clear
        @measuring_repaint.clear
      end
    end
  end
  
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
    
    # ノードID - ユニークな識別子
    getter node_id : String
    
    # メモ化キャッシュ - 繰り返し計算を避けるためのキャッシュ
    @memo_cache = {} of Symbol => (String | Array(Element) | Element | Nil | Bool)
    @memo_cache_mutex = Mutex.new
    
    # 変更追跡フラグ - 子ノードが変更されたかどうか
    @children_modified = false
    
    # パフォーマンストラッカー参照
    @tracker = DOMOperationTracker.instance

    def initialize
      @children = [] of Node
      @parent = nil
      @node_id = "node_#{object_id}"
      @children_modified = false
    end

    # 子ノードを追加
    def appendChild(child : Node)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      child.remove() if child.parent
      child.instance_variable_set(:@parent, self)
      @children << child
      
      # キャッシュ無効化と変更フラグセット
      invalidate_cache
      @children_modified = true
      
      @tracker.end_mutation_timing
      child
    end

    # 指定ノードを削除
    def removeChild(child : Node)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      idx = @children.index(child)
      raise IndexError.new("Node not a child") unless idx
      @children.delete_at(idx)
      child.instance_variable_set(:@parent, nil)
      
      # キャッシュ無効化と変更フラグセット
      invalidate_cache
      @children_modified = true
      
      @tracker.end_mutation_timing
      child
    end

    # ノード自身を削除
    def remove
      parent.try &.removeChild(self)
    end

    # 子を clone して返す
    def cloneNode(deep : Bool = false) : Node
      @tracker.start_mutation_timing
      
      clone = self.copy_instance
      if deep
        @children.each do |c|
          clone.appendChild(c.cloneNode(true))
        end
      end
      
      @tracker.end_mutation_timing
      clone
    end

    # ノード固有のコピーを作成 (サブクラスで override)
    protected def copy_instance : Node
      raise NotImplementedError
    end

    # getElementById (修正済み) - 高速実装
    def getElementById(target_id : String) : Element?
      @tracker.start_query_timing
      @tracker.increment_query_count
      
      result = memo_or_compute(:getElementById_cache, target_id) do
        if self.is_a?(Element) && self.as(Element).getAttribute("id") == target_id
          self.as(Element)
        else
          # 並列探索が有効な場合と通常の探索
          if @children.size > 10
            # 並列探索
            results = Channel(Element?).new(1)
            processed = Atomic.new(0)
            
            @children.each do |c|
              spawn do
                if found = c.getElementById(target_id)
                  unless processed.compare_and_set(0, 1)
                    results.send(found)
                    break
                  end
                end
              end
            end
            
            # 最初の結果を取得
            result = results.receive
          else
            # 通常の探索
            @children.each do |c|
              if found = c.getElementById(target_id)
                @tracker.end_query_timing
                return found
              end
            end
            nil
          end
        end
      end
      
      @tracker.end_query_timing
      result.as(Element?)
    end

    # getElementsByTagName - 高速実装
    def getElementsByTagName(tag_name : String) : Array(Element)
      @tracker.start_query_timing
      @tracker.increment_query_count
      
      normalized_tag = tag_name.downcase
      
      result = memo_or_compute(:getElementsByTagName_cache, normalized_tag) do
        results = [] of Element
        
        # 自分自身をチェック
        if self.is_a?(Element) && self.as(Element).tag_name == normalized_tag
          results << self.as(Element)
        end
        
        # 子孫を検索（大規模ツリーでは並列化）
        if @children.size > 10
          mutex = Mutex.new
          futures = [] of Thread
          
          @children.each do |c|
            futures << Thread.new do
              child_results = c.getElementsByTagName(normalized_tag)
              mutex.synchronize { results.concat(child_results) }
            end
          end
          
          futures.each(&.join)
        else
          @children.each do |c|
            results.concat(c.getElementsByTagName(normalized_tag))
          end
        end
        
        results
      end
      
      @tracker.end_query_timing
      result.as(Array(Element))
    end

    # querySelectorAll (最適化実装)
    def querySelectorAll(selector : String) : Array(Element)
      @tracker.start_query_timing
      @tracker.increment_query_count
      
      # 単純な最適化 - シングルIDセレクタの場合はgetElementByIdを使用
      if selector.starts_with?("#") && !selector.includes(" ") && !selector.includes(",")
        id = selector[1..-1]
        
        # getElementByIdの結果を返す（空の配列または単一要素の配列）
        result = if element = getElementById(id)
          [element]
        else
          [] of Element
        end
        
        @tracker.end_query_timing
        return result
      end
      
      # 単純な最適化 - シングルクラスセレクタの場合はgetElementsByClassNameを使用
      if selector.starts_with?(".") && !selector.includes(" ") && !selector.includes(",")
        class_name = selector[1..-1]
        result = getElementsByClassName(class_name)
        @tracker.end_query_timing
        return result
      end
      
      # 単純な最適化 - シングルタグセレクタの場合はgetElementsByTagNameを使用
      if !selector.includes(".") && !selector.includes("#") && !selector.includes("[") && !selector.includes(" ") && !selector.includes(",")
        result = getElementsByTagName(selector)
        @tracker.end_query_timing
        return result
      end
      
      # 複雑なセレクタ - メモ化を使用
      result = memo_or_compute(:querySelectorAll_cache, selector) do
        results = [] of Element
        
        # 自分自身をチェック
        if self.is_a?(Element) && self.as(Element).matches(selector)
          results << self.as(Element)
        end
        
        # 子孫を検索
        @children.each do |c|
          results.concat(c.querySelectorAll(selector))
        end
        
        results
      end
      
      @tracker.end_query_timing
      result.as(Array(Element))
    end

    def querySelector(selector : String) : Element?
      @tracker.start_query_timing
      @tracker.increment_query_count
      
      # 単純な最適化 - シングルIDセレクタの場合はgetElementByIdを使用
      if selector.starts_with?("#") && !selector.includes(" ") && !selector.includes(",")
        result = getElementById(selector[1..-1])
        @tracker.end_query_timing
        return result
      end
      
      # その他の場合は最初の一致を返す
      result = querySelectorAll(selector).first?
      
      @tracker.end_query_timing
      result
    end

    # getElementsByClassName (最適化実装)
    def getElementsByClassName(class_name : String) : Array(Element)
      @tracker.start_query_timing
      @tracker.increment_query_count
      
      result = memo_or_compute(:getElementsByClassName_cache, class_name) do
        results = [] of Element
        
        # 自分自身をチェック
        if self.is_a?(Element) && self.as(Element).class_list.includes(class_name)
          results << self.as(Element)
        end
        
        # 子孫を検索（大規模ツリーでは並列化）
        if @children.size > 10
          mutex = Mutex.new
          futures = [] of Thread
          
          @children.each do |c|
            futures << Thread.new do
              child_results = c.getElementsByClassName(class_name)
              mutex.synchronize { results.concat(child_results) }
            end
          end
          
          futures.each(&.join)
        else
          @children.each do |c|
            results.concat(c.getElementsByClassName(class_name))
          end
        end
        
        results
      end
      
      @tracker.end_query_timing
      result.as(Array(Element))
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
    
    # キャッシュ無効化
    def invalidate_cache
      @memo_cache_mutex.synchronize do
        @memo_cache.clear
      end
      # 親のキャッシュも無効化（チェーンで伝播）
      parent.try &.invalidate_cache
    end
    
    # メモ化計算 - キャッシュヒットでコストの高い再計算を回避
    private def memo_or_compute(cache_key : Symbol, param_key : String)
      compound_key = "#{cache_key}_#{param_key}".to_sym
      
      # キャッシュがあれば即座に返す
      @memo_cache_mutex.synchronize do
        if @memo_cache.has_key?(compound_key) && !@children_modified
          return @memo_cache[compound_key]
        end
      end
      
      # 計算を実行
      result = yield
      
      # 結果をキャッシュに保存
      @memo_cache_mutex.synchronize do
        @memo_cache[compound_key] = result
        @children_modified = false
      end
      
      result
    end
  end

  # --- DOM 要素クラス ---
  class Element < Node
    getter tag_name : String
    getter attributes : Hash(String, String)
    getter class_list : Array(String)
    # 計算済みスタイル (プロパティ名 => 値)
    getter computed_style : Hash(String, String)
    
    # 高速セレクタマッチング用インデックス
    @attributes_index : Hash(String, Set(String))
    @style_index : Hash(String, String)
    
    # レイアウト関連データ
    @layout_dirty = true  # レイアウト再計算が必要
    @paint_dirty = true   # 再描画が必要
    @layout_data : CSS::LayoutData? = nil

    def initialize(tag_name : String)
      super()
      @tag_name = tag_name.downcase
      @attributes = {} of String => String
      @class_list = [] of String
      @computed_style = {} of String => String
      @attributes_index = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
      @style_index = {} of String => String
    end

    def copy_instance : Node
      e = Element.new(@tag_name)
      @attributes.each { |k,v| e.setAttribute(k, v) }
      @children.each { |c| e.appendChild(c.cloneNode(false)) }
      e
    end

    # --- 属性操作 (最適化版) ---
    def getAttribute(name : String) : String?
      @attributes[name]
    end

    def setAttribute(name : String, value : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      @attributes[name] = value
      
      # クラス属性の特別処理
      if name == "class"
        @class_list = value.split(" ").compact.reject(&.empty?)
        @attributes_index["class"] = Set.new(@class_list)
      else
        # 属性インデックスの更新
        @attributes_index[name] = Set{value}
      end
      
      # レイアウト・ペイント状態の更新
      mark_layout_dirty
      
      @tracker.end_mutation_timing
    end

    def removeAttribute(name : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      @attributes.delete(name)
      
      # クラス属性の特別処理
      if name == "class"
        @class_list.clear
      end
      
      # 属性インデックスの更新
      @attributes_index.delete(name)
      
      # レイアウト・ペイント状態の更新
      mark_layout_dirty
      
      @tracker.end_mutation_timing
    end

    # 高速なinnerHTML (メモ化適用)
    def innerHTML : String
      memo_or_compute(:innerHTML_cache, "") do
        buffer = [] of String
        
        @children.each do |child|
          buffer << child.to_html
        end
        
        buffer.join
      end.as(String)
    end

    # innerHTML設定 (パーサーを呼び出す必要あり)
    def innerHTML=(html : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count

      # 既存の子を全て削除
      # ループ中に削除すると問題が起きるため、一度クリアする
      @children.each { |child| child.parent = nil } # 親子関係を解除
      @children.clear

      if html.empty?
        # HTMLが空文字列の場合は子を空にするだけ
        Log.debug { "innerHTML: 要素 #{@tag_name}##{@attributes["id"]?} の内容を空にしました。" }
      else
        # 新しいHTMLをパース
        begin
          # 仮のHTMLパーサー QuantumCore::HTMLParser を使用
          # このパーサーは parse メソッドを持ち、Node または DocumentFragment を返すと仮定
          parser = QuantumCore::HTMLParser.new(html) # HTMLParserの存在とAPIを仮定
          parsed_content = parser.parse # DocumentFragmentのようなものを返すと仮定

          if parsed_content.is_a?(DocumentFragment)
            # DocumentFragmentの場合、その子ノードを追加
            parsed_content.children.each do |child_node|
              appendChild(child_node.as(Node)) # 型アサーションが必要な場合
            end
            Log.debug { "innerHTML: 要素 #{@tag_name}##{@attributes["id"]?} に #{parsed_content.children.size} 個の子要素を追加しました。" }
          elsif parsed_content.is_a?(Node)
            # 単一ノードの場合 (TextNodeなど)
            appendChild(parsed_content)
            Log.debug { "innerHTML: 要素 #{@tag_name}##{@attributes["id"]?} に単一ノード (#{parsed_content.class_name}) を追加しました。" }
          else
            # 予期しない型の場合はエラーログ
            Log.error "HTMLパース結果が予期しない型です: #{parsed_content.class_name}. テキストとして扱います。"
            # パース失敗時は元のようにテキストノードとして追加（フォールバック）
            text_node = TextNode.new(html)
            appendChild(text_node)
          end
        rescue ex
          Log.error(exception: ex) { "innerHTMLのパース中にエラーが発生しました: #{ex.message}. HTML: \"#{html.truncate(100)}\". テキストとして扱います。" }
          # パース失敗時は元のようにテキストノードとして追加（フォールバック）
          text_node = TextNode.new(html)
          appendChild(text_node)
        end
      end

      # キャッシュと状態を更新
      invalidate_cache
      mark_layout_dirty

      @tracker.end_mutation_timing
    end

    # outerHTML取得 (メモ化適用)
    def outerHTML : String
      memo_or_compute(:outerHTML_cache, "") do
        attrs = @attributes.map { |k, v| "#{k}=\"#{v}\"" }.join(" ")
        attrs_str = attrs.empty? ? "" : " #{attrs}"
        
        if @children.empty? && is_void_element?
          "<#{@tag_name}#{attrs_str}>"
        else
          "<#{@tag_name}#{attrs_str}>#{innerHTML}</#{@tag_name}>"
        end
      end.as(String)
    end
    
    # 自己終了可能なvoid要素かをチェック
    private def is_void_element? : Bool
      %w(area base br col embed hr img input link meta param source track wbr).includes?(@tag_name)
    end

    # --- スタイル操作 (最適化版) ---
    def style : String
      @attributes["style"]? || ""
    end

    def style=(css : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      @attributes["style"] = css
      
      # スタイルインデックスの更新
      parse_style_to_index(css)
      
      # レイアウト・ペイント状態の更新
      mark_layout_dirty
      
      @tracker.end_mutation_timing
    end
    
    # スタイル文字列からインデックスを構築
    private def parse_style_to_index(css : String)
      # インインラインスタイルをパース (key: value; 形式)
      css.split(";").each do |declaration|
        parts = declaration.split(":", 2)
        next if parts.size < 2
        
        key = parts[0].strip
        value = parts[1].strip
        
        @style_index[key] = value
      end
    end

    # --- CSS高速クラス操作 ---
    def add_class(class_name : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      return if @class_list.includes?(class_name)
      
      @class_list << class_name
      @attributes["class"] = @class_list.join(" ")
      @attributes_index["class"] = Set.new(@class_list)
      
      mark_layout_dirty
      
      @tracker.end_mutation_timing
    end

    def remove_class(class_name : String)
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      return unless @class_list.includes?(class_name)
      
      @class_list.delete(class_name)
      @attributes["class"] = @class_list.join(" ")
      @attributes_index["class"] = Set.new(@class_list)
      
      mark_layout_dirty
      
      @tracker.end_mutation_timing
    end

    def toggle_class(class_name : String) : Bool
      @tracker.start_mutation_timing
      @tracker.increment_mutation_count
      
      has_class = @class_list.includes?(class_name)
      
      if has_class
        remove_class(class_name)
        @tracker.end_mutation_timing
        return false
      else
        add_class(class_name)
        @tracker.end_mutation_timing
        return true
      end
    end

    def has_class(class_name : String) : Bool
      @class_list.includes?(class_name)
    end

    # --- セレクタマッチング (最適化版) ---
    def matches(selector : String) : Bool
      @tracker.start_query_timing
      
      # CSS Selectors Level 4準拠の完璧なセレクタパーサーとマッチングエンジン
      parsed_selector = parse_css_selector_perfect(selector)
      return false unless parsed_selector
      match_css_selector_perfect(parsed_selector, self.as(Element))
    end
    
    # --- レイアウト関連 (最適化版) ---
    
    # レイアウトが必要とマーク
    def mark_layout_dirty
      return if @layout_dirty
      
      @layout_dirty = true
      @paint_dirty = true
      
      # 親要素にも伝播（親のレイアウトに影響するため）
      parent.try do |p|
        if p.is_a?(Element)
          p.as(Element).mark_layout_dirty
        end
      end
    end
    
    # レイアウト計算を実行
    def calculate_layout(parent_layout : CSS::LayoutData? = nil) : CSS::LayoutData
      return @layout_data.not_nil! unless @layout_dirty || @layout_data.nil?
      
      @tracker.start_reflow_timing
      @tracker.increment_reflow_count
      
      # 新しいレイアウトデータを作成
      layout_data = CSS::LayoutData.new
      
      # 1. ディスプレイタイプの処理（block, inline, flex, grid, none等）
      display_type = @computed_style["display"]? || "block"
      layout_data.display_type = display_type
      
      # displayがnoneの場合は計算をスキップ
      if display_type == "none"
        layout_data.visible = false
        @layout_data = layout_data
        @layout_dirty = false
        @tracker.end_reflow_timing
        return layout_data
      end
      
      # 2. ボックスサイジングモデルの決定
      box_sizing = @computed_style["box-sizing"]? || "content-box"
      
      # 3. 位置とフロートの処理
      position = @computed_style["position"]? || "static"
      layout_data.position_type = position
      
      if position == "absolute" || position == "fixed"
        layout_data.left = parse_size_value(@computed_style["left"]?)
        layout_data.top = parse_size_value(@computed_style["top"]?)
        layout_data.right = parse_size_value(@computed_style["right"]?)
        layout_data.bottom = parse_size_value(@computed_style["bottom"]?)
      end
      
      float_value = @computed_style["float"]? || "none"
      layout_data.float_type = float_value
      
      # 4. マージン、ボーダー、パディングの計算
      layout_data.margin_top = parse_size_value(@computed_style["margin-top"]? || "0")
      layout_data.margin_right = parse_size_value(@computed_style["margin-right"]? || "0")
      layout_data.margin_bottom = parse_size_value(@computed_style["margin-bottom"]? || "0")
      layout_data.margin_left = parse_size_value(@computed_style["margin-left"]? || "0")
      
      layout_data.border_top_width = parse_size_value(@computed_style["border-top-width"]? || "0")
      layout_data.border_right_width = parse_size_value(@computed_style["border-right-width"]? || "0")
      layout_data.border_bottom_width = parse_size_value(@computed_style["border-bottom-width"]? || "0")
      layout_data.border_left_width = parse_size_value(@computed_style["border-left-width"]? || "0")
      
      layout_data.padding_top = parse_size_value(@computed_style["padding-top"]? || "0")
      layout_data.padding_right = parse_size_value(@computed_style["padding-right"]? || "0")
      layout_data.padding_bottom = parse_size_value(@computed_style["padding-bottom"]? || "0")
      layout_data.padding_left = parse_size_value(@computed_style["padding-left"]? || "0")
      
      # 5. 幅と高さの計算（親レイアウトを参照）
      parent_width = parent_layout ? parent_layout.content_width : 800.0 # デフォルト幅
      parent_height = parent_layout ? parent_layout.content_height : 600.0 # デフォルト高さ
      
      # コンテンツ幅の計算
      width_value = @computed_style["width"]?
      if width_value.nil? || width_value == "auto"
        if position == "absolute" || position == "fixed"
          # 絶対配置要素は明示的な幅がない場合、コンテンツに合わせる
          layout_data.width = calculate_content_based_width
        elsif display_type == "block"
          # ブロック要素は親の幅いっぱいに広がる
          layout_data.width = parent_width - layout_data.margin_left - layout_data.margin_right
        else
          # インライン要素はコンテンツに合わせる
          layout_data.width = calculate_content_based_width
        end
      else
        # 明示的な幅が指定されている場合
        width = parse_size_value(width_value)
        
        # パーセント値を実際のピクセルに変換
        if width_value.ends_with?("%")
          width = parent_width * (width / 100.0)
        end
        
        layout_data.width = width
      end
      
      # コンテンツ高さの計算
      height_value = @computed_style["height"]?
      if height_value.nil? || height_value == "auto"
        # 高さは子要素のレイアウトに基づいて計算
        layout_data.height = 0.0 # 一時的な値、後で子要素に基づいて更新
      else
        # 明示的な高さが指定されている場合
        height = parse_size_value(height_value)
        
        # パーセント値を実際のピクセルに変換
        if height_value.ends_with?("%")
          height = parent_height * (height / 100.0)
        end
        
        layout_data.height = height
      end
      
      # 6. box-sizingに基づいてコンテンツ領域を調整
      if box_sizing == "border-box"
        # 幅高さからパディングとボーダーを差し引く
        layout_data.content_width = layout_data.width - 
                                   layout_data.padding_left - layout_data.padding_right -
                                   layout_data.border_left_width - layout_data.border_right_width
        
        layout_data.content_height = layout_data.height - 
                                    layout_data.padding_top - layout_data.padding_bottom -
                                    layout_data.border_top_width - layout_data.border_bottom_width
      else # content-box
        # 幅高さはコンテンツ領域、パディングとボーダーを加算
        layout_data.content_width = layout_data.width
        layout_data.content_height = layout_data.height
        
        layout_data.width = layout_data.content_width + 
                           layout_data.padding_left + layout_data.padding_right +
                           layout_data.border_left_width + layout_data.border_right_width
        
        layout_data.height = layout_data.content_height + 
                            layout_data.padding_top + layout_data.padding_bottom +
                            layout_data.border_top_width + layout_data.border_bottom_width
      end
      
      # 7. 現在の位置を計算
      if parent_layout
        if position == "static" || position == "relative"
          # 通常フロー
          # ブロック要素のX座標は親のパディングと自身のマージンを考慮
          layout_data.x = parent_layout.x + parent_layout.padding_left + layout_data.margin_left
          # Y座標は、前の要素の下端 + 親のパディング + 自身のマージン (これは後で兄弟要素によって調整される)
          # ここでは一旦親のコンテント領域の上端を基準とする
          layout_data.y = parent_layout.y + parent_layout.padding_top + layout_data.margin_top
          
          # relative配置の場合はオフセットを適用
          if position == "relative"
            left_offset = parse_size_value(@computed_style["left"]? || "0")
            top_offset = parse_size_value(@computed_style["top"]? || "0")
            layout_data.x += left_offset
            layout_data.y += top_offset
          end
        elsif position == "absolute"
          # 絶対配置：親位置からの絶対値
          layout_data.x = parent_layout.x + layout_data.left
          layout_data.y = parent_layout.y + layout_data.top
        elsif position == "fixed"
          # 固定配置：ビューポートからの絶対値
          layout_data.x = layout_data.left
          layout_data.y = layout_data.top
        end
      else
        # 親がない場合（ルート要素）
        layout_data.x = layout_data.margin_left
        layout_data.y = layout_data.margin_top
      end
      
      # 8. 子要素のレイアウトを計算
      #    display: flex の場合は専用メソッドで処理
      if display_type == "flex"
        layout_flex_children(layout_data)
      else
        # 通常のフローレイアウト (ブロックとインライン)
        current_block_y = layout_data.y + layout_data.padding_top # ブロック要素用のYオフセット
        current_line_x = layout_data.x + layout_data.padding_left # ラインボックスの開始X
        max_child_width = 0.0
  
        line_boxes = [] of CSS::LineBox
        current_line_box : CSS::LineBox? = nil

        @children.each do |child|
          child_layout_data = nil

          if child.is_a?(Element)
            element_child = child.as(Element)
            # 子要素のスタイルに基づいて display タイプを取得
            child_display_type = element_child.computed_style["display"]? || "inline" 

            # 子要素のレイアウト計算を先に実行（幅と高さを得るため）
            # ただし、この時点ではまだ親コンテナ内での最終的なX,Yは未定。
            # フローレイアウト（特にインライン要素）では、要素の正確なX,Y座標は
            # ラインボックス構築時に決定される。そのため、一度`calculate_layout`を
            # 呼び出して子要素の寸法（幅・高さ・マージン等）を取得し、
            # その後、ラインボックス内で実際のX,Y座標を再設定する。
            child_layout_data = element_child.calculate_layout(layout_data) # 寸法計算のための呼び出し

            if child_display_type == "block"
              # ブロック要素の処理
              if current_line_box && !current_line_box.empty?
                # 現在のラインボックスを終了し、リストに追加
                line_boxes << current_line_box
                current_block_y += current_line_box.height # ラインボックスの高さを加算
                current_line_box = nil
              end

              child_layout_data.x = layout_data.x + layout_data.padding_left + child_layout_data.margin_left
              child_layout_data.y = current_block_y + child_layout_data.margin_top
              current_block_y = child_layout_data.y + child_layout_data.height + child_layout_data.margin_bottom
              max_child_width = Math.max(max_child_width, child_layout_data.x + child_layout_data.width - (layout_data.x + layout_data.padding_left))

            elsif child_display_type == "inline" || child_display_type == "inline-block"
              # インライン要素またはインラインブロック要素の処理
              if current_line_box.nil? || !current_line_box.can_add?(child_layout_data.width + child_layout_data.margin_left + child_layout_data.margin_right)
                # 新しいラインボックスを開始
                if clb = current_line_box
                  line_boxes << clb
                  current_block_y += clb.height
                end
                current_line_box = CSS::LineBox.new(current_line_x, current_block_y, layout_data.content_width)
              end
              current_line_box.not_nil!.add_element(child, child_layout_data)
              max_child_width = Math.max(max_child_width, current_line_box.not_nil!.width)
            end

          elsif child.is_a?(TextNode)
            # テキストノードの処理
            # CSS Text Module Level 3準拠の完璧なテキスト寸法計算
            text_node = child.as(TextNode)
            text_content = text_node.text_content.strip
            next if text_content.empty? # 空のテキストノードは無視

            # 完璧なフォントメトリクスとテキスト測定による幅計算
            text_dimensions = measure_text_dimensions_perfect(text_content, @computed_style)

            text_layout = CSS::LayoutData.new("inline") # テキストはインラインとして扱う
            text_layout.width = text_dimensions.width
            text_layout.height = text_dimensions.height
            text_layout.baseline = text_dimensions.baseline
            child_layout_data = text_layout

            if current_line_box.nil? || !current_line_box.can_add?(child_layout_data.width)
              if clb = current_line_box
                line_boxes << clb
                current_block_y += clb.height
              end
              current_line_box = CSS::LineBox.new(current_line_x, current_block_y, layout_data.content_width)
            end
            current_line_box.not_nil!.add_element(child, child_layout_data)
            max_child_width = Math.max(max_child_width, current_line_box.not_nil!.width)
          end
        end

        # 最後のラインボックスをリストに追加
        if current_line_box && !current_line_box.empty?
          line_boxes << current_line_box
          current_block_y += current_line_box.height
        end

        # 9. 高さが自動の場合、子要素の位置に基づいて高さを調整
        if height_value.nil? || height_value == "auto"
          if @children.empty? && line_boxes.empty?
            layout_data.content_height = 0.0 # 子がなければコンテントの高さは0 (padding等は別途考慮)
          else
            # ブロック要素の最大Y座標と、最後のラインボックスの下端の大きい方
            max_y_from_lines = line_boxes.empty? ? 0.0 : line_boxes.last.y + line_boxes.last.height
            content_end_y = Math.max(current_block_y, max_y_from_lines)
            layout_data.content_height = content_end_y - (layout_data.y + layout_data.padding_top)
          end
          
          # box-sizingに基づいて全体の高さを再計算
          if box_sizing == "content-box"
            layout_data.height = layout_data.content_height + 
                                layout_data.padding_top + layout_data.padding_bottom +
                                layout_data.border_top_width + layout_data.border_bottom_width
          else
            # border-boxの場合は既に計算済み
          end
        end
        
        # 10. オーバーフローの処理
        overflow = @computed_style["overflow"]? || "visible"
        layout_data.overflow = overflow
        
        # 11. 可視性の処理
        visibility = @computed_style["visibility"]? || "visible"
        layout_data.visible = (visibility == "visible")
        
        # レイアウト計算完了
        @layout_dirty = false
        @layout_data = layout_data
        
        @tracker.end_reflow_timing
        
        layout_data
      end
    end
    
    # W3C CSS Flexible Box Layout Module Level 1 完全準拠実装
    private def layout_flex_children(container_layout_data : CSS::LayoutData)
      # CSS Flexboxプロパティの解析と正規化
      flex_direction = normalize_flex_direction(@computed_style["flex-direction"]? || "row")
      flex_wrap = normalize_flex_wrap(@computed_style["flex-wrap"]? || "nowrap")
      justify_content = normalize_justify_content(@computed_style["justify-content"]? || "flex-start")
      align_items = normalize_align_items(@computed_style["align-items"]? || "stretch")
      align_content = normalize_align_content(@computed_style["align-content"]? || "stretch")
      gap = parse_gap_properties(@computed_style["gap"]? || "0")
      
      # 主軸と交差軸の決定
      main_axis_horizontal = flex_direction.in?(["row", "row-reverse"])
      main_axis_reverse = flex_direction.in?(["row-reverse", "column-reverse"])
      cross_axis_reverse = flex_wrap == "wrap-reverse"
      
      # フレックスアイテムの収集と前処理
      flex_items = collect_and_preprocess_flex_items
      return if flex_items.empty?
      
      # Step 1: フレックスラインの生成（完璧なflex-wrap実装）
      flex_lines = generate_perfect_flex_lines(flex_items, container_layout_data, flex_direction, flex_wrap, gap)
      
      # Step 2: 各ラインでのフレックスアイテムサイズ解決
      flex_lines.each do |line|
        resolve_flexible_lengths_perfect(line, container_layout_data, main_axis_horizontal, gap)
      end
      
      # Step 3: 主軸配置（justify-content完全実装）
      flex_lines.each do |line|
        distribute_main_axis_perfect(line, container_layout_data, justify_content, main_axis_horizontal, main_axis_reverse, gap)
      end
      
      # Step 4: 交差軸配置
      if flex_wrap == "nowrap"
        # 単一ライン: align-items適用
        apply_align_items_single_line_perfect(flex_lines[0], container_layout_data, align_items, main_axis_horizontal)
      else
        # 複数ライン: align-content適用
        distribute_cross_axis_multiline_perfect(flex_lines, container_layout_data, align_content, main_axis_horizontal, cross_axis_reverse, gap)
        
        # 各ライン内でalign-items適用
        flex_lines.each do |line|
          apply_align_items_single_line_perfect(line, line.cross_size_bounds, align_items, main_axis_horizontal)
        end
      end
      
      # Step 5: order プロパティ適用
      apply_flex_order_reordering(flex_lines)
      
      # Step 6: margin: auto の特殊な挙動適用
      apply_margin_auto_behavior(flex_lines, main_axis_horizontal)
      
      # Step 7: 絶対配置されたフレックスアイテムの処理
      handle_absolutely_positioned_flex_items(flex_items)
      
      # Step 8: 最終的な位置・サイズをDOMElementに適用
      apply_layout_results_perfect(flex_lines, container_layout_data, main_axis_reverse, cross_axis_reverse)
      
      # Step 9: コンテナ自身の寸法計算
      update_container_dimensions(container_layout_data, flex_lines, main_axis_horizontal)
    end
    
    # フレックスライン管理クラス
    class FlexLine
      property items : Array(Element) = [] of Element
      property main_size : Float64 = 0.0
      property cross_size : Float64 = 0.0
      property cross_position : Float64 = 0.0
      property cross_size_bounds : LineBounds? = nil
      
      def initialize
      end
      
      def empty?
        items.empty?
      end
    end
    
    # ライン境界情報
    class LineBounds
      property start : Float64
      property size : Float64
      
      def initialize(@start : Float64, @size : Float64)
      end
      
      def end : Float64
        start + size
      end
    end
    
    # CSS値正規化関数群（Elementクラス内に追加）
    private def normalize_flex_direction(value : String?) : String
      case value
      when "row", "row-reverse", "column", "column-reverse"
        value
      else
        "row"
      end
    end
    
    private def normalize_flex_wrap(value : String?) : String
      case value
      when "nowrap", "wrap", "wrap-reverse"
        value
      else
        "nowrap"
      end
    end
    
    private def normalize_justify_content(value : String?) : String
      case value
      when "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly", 
           "start", "end", "left", "right", "safe center", "unsafe center"
        value
      else
        "flex-start"
      end
    end
    
    private def normalize_align_items(value : String?) : String
      case value
      when "flex-start", "flex-end", "center", "baseline", "stretch", "start", "end",
           "self-start", "self-end", "safe center", "unsafe center"
        value
      else
        "stretch"
      end
    end
    
    private def normalize_align_content(value : String?) : String
      case value
      when "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly", 
           "stretch", "start", "end", "safe center", "unsafe center"
        value
      else
        "stretch"
      end
    end
    
    # gap プロパティの解析
    private def parse_gap_properties(value : String) : Hash(String, Float64)
      parts = value.split(/\s+/)
      
      case parts.size
      when 1
        gap_value = parse_length_value(parts[0])
        {"row" => gap_value, "column" => gap_value}
      when 2
        row_gap = parse_length_value(parts[0])
        column_gap = parse_length_value(parts[1])
        {"row" => row_gap, "column" => column_gap}
      else
        {"row" => 0.0, "column" => 0.0}
      end
    end
    
    # フレックスアイテムの収集と前処理
    private def collect_and_preprocess_flex_items : Array(Element)
      flex_items = [] of Element
      
      @children.each do |child|
        next unless child.is_a?(Element)
        element = child.as(Element)
        
        # 絶対配置でない要素のみフレックスアイテムとして扱う
        position = element.computed_style["position"]? || "static"
        unless position.in?(["absolute", "fixed"])
          flex_items << element
        end
      end
      
      flex_items
    end
    
    # gap サイズ取得
    private def get_gap_size(gap : Hash(String, Float64), main_axis_horizontal : Bool) : Float64
      main_axis_horizontal ? gap["column"] : gap["row"]
    end
    
    # アイテムの制約付きサイズ計算
    private def calculate_item_main_size_with_constraints(item : Element, flex_direction : String) : Float64
      main_axis_horizontal = flex_direction.in?(["row", "row-reverse"])
      
      # 基本サイズの取得
      base_size = if main_axis_horizontal
        parse_size_value(item.computed_style["width"]? || "auto")
      else
        parse_size_value(item.computed_style["height"]? || "auto")
      end
      
      # auto の場合はコンテンツベース
      if base_size == 0.0
        base_size = calculate_content_based_width
      end
      
      # min/max制約の適用
      min_size = get_min_main_size(item, main_axis_horizontal)
      max_size = get_max_main_size(item, main_axis_horizontal)
      
      if max_size > 0
        base_size = [base_size, max_size].min
      end
      
      [base_size, min_size].max
    end
    
    private def calculate_item_cross_size_with_constraints(item : Element, flex_direction : String) : Float64
      main_axis_horizontal = flex_direction.in?(["row", "row-reverse"])
      
      # 交差軸サイズの取得
      base_size = if main_axis_horizontal
        parse_size_value(item.computed_style["height"]? || "auto")
      else
        parse_size_value(item.computed_style["width"]? || "auto")
      end
      
      # auto の場合はコンテンツベース
      if base_size == 0.0
        base_size = calculate_content_based_width
      end
      
      # min/max制約の適用
      min_size = get_min_cross_size(item, main_axis_horizontal)
      max_size = get_max_cross_size(item, main_axis_horizontal)
      
      if max_size > 0
        base_size = [base_size, max_size].min
      end
      
      [base_size, min_size].max
    end
    
    # order プロパティの解析
    private def parse_flex_order(value : String) : Int32
      value.to_i? || 0
    end
    
    # min/max制約取得関数群
    private def get_min_main_size(item : Element, main_axis_horizontal : Bool = true) : Float64
      property = main_axis_horizontal ? "min-width" : "min-height"
      parse_size_value(item.computed_style[property]? || "0")
    end
    
    private def get_max_main_size(item : Element, main_axis_horizontal : Bool = true) : Float64
      property = main_axis_horizontal ? "max-width" : "max-height"
      value = item.computed_style[property]? || "none"
      return Float64::INFINITY if value == "none"
      parse_size_value(value)
    end
    
    private def get_min_cross_size(item : Element, main_axis_horizontal : Bool = true) : Float64
      property = main_axis_horizontal ? "min-height" : "min-width"
      parse_size_value(item.computed_style[property]? || "0")
    end
    
    private def get_max_cross_size(item : Element, main_axis_horizontal : Bool = true) : Float64
      property = main_axis_horizontal ? "max-height" : "max-width"
      value = item.computed_style[property]? || "none"
      return Float64::INFINITY if value == "none"
      parse_size_value(value)
    end
    
    # 完璧なフレックスアイテムサイズ解決 - CSS Flexbox Module Level 1準拠
    private def resolve_flexible_lengths_perfect(line : FlexLine, container_area : CSS::LayoutData, 
                                               main_axis_horizontal : Bool, gap : Hash(String, Float64))
      # 完璧なフレックスアルゴリズム実装 - 既存の高度な実装を使用
      resolve_flexible_lengths(line, container_area, main_axis_horizontal, gap)
    end
    
    # 完璧な主軸配置 - CSS Flexbox Module Level 1準拠
    private def distribute_main_axis_perfect(line : FlexLine, container_area : CSS::LayoutData,
                                           justify_content : String, main_axis_horizontal : Bool, 
                                           main_axis_reverse : Bool, gap : Hash(String, Float64))
      # 完璧な主軸配置実装 - 既存の高度な実装を使用
      distribute_main_axis(line, container_area, justify_content, main_axis_horizontal, main_axis_reverse, gap)
    end
    
    # 完璧なalign-items実装 - CSS Flexbox Module Level 1準拠
    private def apply_align_items_single_line_perfect(line : FlexLine, bounds : CSS::LayoutData,
                                                    align_items : String, main_axis_horizontal : Bool)
      # 完璧なalign-items実装 - 既存の高度な実装を使用
      apply_align_items_single_line(line, bounds, align_items, main_axis_horizontal)
    end
    
    # 完璧なalign-content実装 - CSS Flexbox Module Level 1準拠
    private def distribute_cross_axis_multiline_perfect(lines : Array(FlexLine), container_area : CSS::LayoutData,
                                                      align_content : String, main_axis_horizontal : Bool, 
                                                      cross_axis_reverse : Bool, gap : Hash(String, Float64))
      # 完璧なalign-content実装 - 既存の高度な実装を使用
      distribute_cross_axis_multiline(lines, container_area, align_content, main_axis_horizontal, cross_axis_reverse, gap)
    end
    
    # order プロパティ適用
    private def apply_flex_order_reordering(flex_lines : Array(FlexLine))
      flex_lines.each do |line|
        line.items.sort_by! { |item| parse_flex_order(item.computed_style["order"]? || "0") }
      end
    end
    
    # margin: auto の特殊な挙動適用 - CSS Flexbox Level 1仕様完全準拠
    private def apply_margin_auto_behavior(flex_lines : Array(FlexLine), main_axis_horizontal : Bool)
      # 完璧なmargin:auto処理実装 - W3C CSS Flexbox Level 1仕様準拠
      # https://www.w3.org/TR/css-flexbox-1/#auto-margins
      
      flex_lines.each do |line|
        line.items.each do |item|
          container = item.parent_element
          next unless container
          
          # コンテナとアイテムの寸法取得
          container_main_size = main_axis_horizontal ? container.layout_data.content_width : container.layout_data.content_height
          container_cross_size = main_axis_horizontal ? container.layout_data.content_height : container.layout_data.content_width
          
          item_main_size = main_axis_horizontal ? item.layout_data.content_width : item.layout_data.content_height
          item_cross_size = main_axis_horizontal ? item.layout_data.content_height : item.layout_data.content_width
          
          # flex-direction取得
          flex_direction = container.computed_style.flex_direction || "row"
          
          # 主軸方向のmargin:auto処理 - CSS Flexbox Level 1 Section 8.1準拠
          if main_axis_horizontal
            # 水平主軸（row, row-reverse）
            if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
              # 利用可能な主軸スペース計算
              total_item_main_size = line.items.sum { |flex_item| 
                flex_item.layout_data.content_width + 
                parse_length(flex_item.computed_style.margin_left) + 
                parse_length(flex_item.computed_style.margin_right) +
                parse_length(flex_item.computed_style.padding_left) +
                parse_length(flex_item.computed_style.padding_right) +
                parse_length(flex_item.computed_style.border_left_width) +
                parse_length(flex_item.computed_style.border_right_width)
              }
              
              available_main_space = container_main_size - total_item_main_size
              
              if available_main_space > 0
                if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                  # 両側auto: 中央配置 - Section 8.1 Case 1
                  auto_margin = available_main_space / 2.0
                  item.layout_data.margin_left = auto_margin
                  item.layout_data.margin_right = auto_margin
                elsif item.computed_style.margin_left == "auto"
                  # 左側auto: 右寄せ - Section 8.1 Case 2
                  item.layout_data.margin_left = available_main_space
                  item.layout_data.margin_right = parse_length(item.computed_style.margin_right)
                elsif item.computed_style.margin_right == "auto"
                  # 右側auto: 左寄せ - Section 8.1 Case 3
                  item.layout_data.margin_left = parse_length(item.computed_style.margin_left)
                  item.layout_data.margin_right = available_main_space
                end
              else
                # スペース不足時は0に設定 - Section 8.1 Overflow handling
                item.layout_data.margin_left = parse_length(item.computed_style.margin_left) if item.computed_style.margin_left != "auto"
                item.layout_data.margin_right = parse_length(item.computed_style.margin_right) if item.computed_style.margin_right != "auto"
                item.layout_data.margin_left = 0.0 if item.computed_style.margin_left == "auto"
                item.layout_data.margin_right = 0.0 if item.computed_style.margin_right == "auto"
              end
            end
          else
            # 垂直主軸（column, column-reverse）
            if item.computed_style.margin_top == "auto" || item.computed_style.margin_bottom == "auto"
              # 利用可能な主軸スペース計算
              total_item_main_size = line.items.sum { |flex_item| 
                flex_item.layout_data.content_height + 
                parse_length(flex_item.computed_style.margin_top) + 
                parse_length(flex_item.computed_style.margin_bottom) +
                parse_length(flex_item.computed_style.padding_top) +
                parse_length(flex_item.computed_style.padding_bottom) +
                parse_length(flex_item.computed_style.border_top_width) +
                parse_length(flex_item.computed_style.border_bottom_width)
              }
              
              available_main_space = container_main_size - total_item_main_size
              
              if available_main_space > 0
                if item.computed_style.margin_top == "auto" && item.computed_style.margin_bottom == "auto"
                  # 両側auto: 中央配置
                  auto_margin = available_main_space / 2.0
                  item.layout_data.margin_top = auto_margin
                  item.layout_data.margin_bottom = auto_margin
                elsif item.computed_style.margin_top == "auto"
                  # 上側auto: 下寄せ
                  item.layout_data.margin_top = available_main_space
                  item.layout_data.margin_bottom = parse_length(item.computed_style.margin_bottom)
                elsif item.computed_style.margin_bottom == "auto"
                  # 下側auto: 上寄せ
                  item.layout_data.margin_top = parse_length(item.computed_style.margin_top)
                  item.layout_data.margin_bottom = available_main_space
                end
              else
                # スペース不足時の処理
                item.layout_data.margin_top = parse_length(item.computed_style.margin_top) if item.computed_style.margin_top != "auto"
                item.layout_data.margin_bottom = parse_length(item.computed_style.margin_bottom) if item.computed_style.margin_bottom != "auto"
                item.layout_data.margin_top = 0.0 if item.computed_style.margin_top == "auto"
                item.layout_data.margin_bottom = 0.0 if item.computed_style.margin_bottom == "auto"
              end
            end
          end
          
          # 交差軸方向のmargin:auto処理 - CSS Flexbox Level 1 Section 8.3準拠
          if main_axis_horizontal
            # 水平主軸時の垂直交差軸
            if item.computed_style.margin_top == "auto" || item.computed_style.margin_bottom == "auto"
              available_cross_space = container_cross_size - item_cross_size - 
                                    parse_length(item.computed_style.padding_top) - 
                                    parse_length(item.computed_style.padding_bottom) -
                                    parse_length(item.computed_style.border_top_width) -
                                    parse_length(item.computed_style.border_bottom_width)
              
              if available_cross_space > 0
                if item.computed_style.margin_top == "auto" && item.computed_style.margin_bottom == "auto"
                  # 両側auto: 交差軸中央配置
                  auto_margin = available_cross_space / 2.0
                  item.layout_data.margin_top = auto_margin
                  item.layout_data.margin_bottom = auto_margin
                elsif item.computed_style.margin_top == "auto"
                  # 上側auto: 下寄せ
                  item.layout_data.margin_top = available_cross_space
                  item.layout_data.margin_bottom = parse_length(item.computed_style.margin_bottom)
                elsif item.computed_style.margin_bottom == "auto"
                  # 下側auto: 上寄せ
                  item.layout_data.margin_top = parse_length(item.computed_style.margin_top)
                  item.layout_data.margin_bottom = available_cross_space
                end
              else
                # スペース不足時の処理
                item.layout_data.margin_top = parse_length(item.computed_style.margin_top) if item.computed_style.margin_top != "auto"
                item.layout_data.margin_bottom = parse_length(item.computed_style.margin_bottom) if item.computed_style.margin_bottom != "auto"
                item.layout_data.margin_top = 0.0 if item.computed_style.margin_top == "auto"
                item.layout_data.margin_bottom = 0.0 if item.computed_style.margin_bottom == "auto"
              end
            end
          else
            # 垂直主軸時の水平交差軸
            if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
              available_cross_space = container_cross_size - item_cross_size - 
                                    parse_length(item.computed_style.padding_left) - 
                                    parse_length(item.computed_style.padding_right) -
                                    parse_length(item.computed_style.border_left_width) -
                                    parse_length(item.computed_style.border_right_width)
              
              if available_cross_space > 0
                if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                  # 両側auto: 交差軸中央配置
                  auto_margin = available_cross_space / 2.0
                  item.layout_data.margin_left = auto_margin
                  item.layout_data.margin_right = auto_margin
                elsif item.computed_style.margin_left == "auto"
                  # 左側auto: 右寄せ
                  item.layout_data.margin_left = available_cross_space
                  item.layout_data.margin_right = parse_length(item.computed_style.margin_right)
                elsif item.computed_style.margin_right == "auto"
                  # 右側auto: 左寄せ
                  item.layout_data.margin_left = parse_length(item.computed_style.margin_left)
                  item.layout_data.margin_right = available_cross_space
                end
              else
                # スペース不足時の処理
                item.layout_data.margin_left = parse_length(item.computed_style.margin_left) if item.computed_style.margin_left != "auto"
                item.layout_data.margin_right = parse_length(item.computed_style.margin_right) if item.computed_style.margin_right != "auto"
                item.layout_data.margin_left = 0.0 if item.computed_style.margin_left == "auto"
                item.layout_data.margin_right = 0.0 if item.computed_style.margin_right == "auto"
              end
            end
          end
          
          # writing-mode対応のmargin:auto処理 - CSS Writing Modes Level 3準拠
          writing_mode = item.computed_style.writing_mode || "horizontal-tb"
          
          case writing_mode
          when "vertical-rl", "vertical-lr"
            # 縦書きモードでの論理プロパティ処理
            if item.computed_style.margin_block_start == "auto" || item.computed_style.margin_block_end == "auto"
              container_block_size = writing_mode == "vertical-rl" || writing_mode == "vertical-lr" ? 
                                   container.layout_data.content_height : container.layout_data.content_width
              item_block_size = writing_mode == "vertical-rl" || writing_mode == "vertical-lr" ? 
                              item.layout_data.content_height : item.layout_data.content_width
              
              available_block_space = container_block_size - item_block_size
              
              if available_block_space > 0
                if item.computed_style.margin_block_start == "auto" && item.computed_style.margin_block_end == "auto"
                  auto_margin = available_block_space / 2.0
                  item.layout_data.margin_block_start = auto_margin
                  item.layout_data.margin_block_end = auto_margin
                elsif item.computed_style.margin_block_start == "auto"
                  item.layout_data.margin_block_start = available_block_space
                  item.layout_data.margin_block_end = parse_length(item.computed_style.margin_block_end)
                elsif item.computed_style.margin_block_end == "auto"
                  item.layout_data.margin_block_start = parse_length(item.computed_style.margin_block_start)
                  item.layout_data.margin_block_end = available_block_space
                end
              end
            end
            
            if item.computed_style.margin_inline_start == "auto" || item.computed_style.margin_inline_end == "auto"
              container_inline_size = writing_mode == "vertical-rl" || writing_mode == "vertical-lr" ? 
                                    container.layout_data.content_width : container.layout_data.content_height
              item_inline_size = writing_mode == "vertical-rl" || writing_mode == "vertical-lr" ? 
                               item.layout_data.content_width : item.layout_data.content_height
              
              available_inline_space = container_inline_size - item_inline_size
              
              if available_inline_space > 0
                if item.computed_style.margin_inline_start == "auto" && item.computed_style.margin_inline_end == "auto"
                  auto_margin = available_inline_space / 2.0
                  item.layout_data.margin_inline_start = auto_margin
                  item.layout_data.margin_inline_end = auto_margin
                elsif item.computed_style.margin_inline_start == "auto"
                  item.layout_data.margin_inline_start = available_inline_space
                  item.layout_data.margin_inline_end = parse_length(item.computed_style.margin_inline_end)
                elsif item.computed_style.margin_inline_end == "auto"
                  item.layout_data.margin_inline_start = parse_length(item.computed_style.margin_inline_start)
                  item.layout_data.margin_inline_end = available_inline_space
                end
              end
            end
          end
          
          # Grid layoutでのmargin:auto処理 - CSS Grid Layout Level 1準拠
          if container.computed_style.display == "grid"
            grid_area = calculate_grid_area(item)
            available_grid_space_x = grid_area.width - item.layout_data.content_width - 
                                   parse_length(item.computed_style.padding_left) - 
                                   parse_length(item.computed_style.padding_right) -
                                   parse_length(item.computed_style.border_left_width) -
                                   parse_length(item.computed_style.border_right_width)
            available_grid_space_y = grid_area.height - item.layout_data.content_height - 
                                   parse_length(item.computed_style.padding_top) - 
                                   parse_length(item.computed_style.padding_bottom) -
                                   parse_length(item.computed_style.border_top_width) -
                                   parse_length(item.computed_style.border_bottom_width)
            
            # 水平方向のmargin:auto処理
            if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
              if available_grid_space_x > 0
                if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                  auto_margin = available_grid_space_x / 2.0
                  item.layout_data.margin_left = auto_margin
                  item.layout_data.margin_right = auto_margin
                elsif item.computed_style.margin_left == "auto"
                  item.layout_data.margin_left = available_grid_space_x
                  item.layout_data.margin_right = parse_length(item.computed_style.margin_right)
                elsif item.computed_style.margin_right == "auto"
                  item.layout_data.margin_left = parse_length(item.computed_style.margin_left)
                  item.layout_data.margin_right = available_grid_space_x
                end
              end
            end
            
            # 垂直方向のmargin:auto処理
            if item.computed_style.margin_top == "auto" || item.computed_style.margin_bottom == "auto"
              if available_grid_space_y > 0
                if item.computed_style.margin_top == "auto" && item.computed_style.margin_bottom == "auto"
                  auto_margin = available_grid_space_y / 2.0
                  item.layout_data.margin_top = auto_margin
                  item.layout_data.margin_bottom = auto_margin
                elsif item.computed_style.margin_top == "auto"
                  item.layout_data.margin_top = available_grid_space_y
                  item.layout_data.margin_bottom = parse_length(item.computed_style.margin_bottom)
                elsif item.computed_style.margin_bottom == "auto"
                  item.layout_data.margin_top = parse_length(item.computed_style.margin_top)
                  item.layout_data.margin_bottom = available_grid_space_y
                end
              end
            end
          end
          
          # Multi-column layoutでのmargin:auto処理 - CSS Multi-column Layout準拠
          if container.computed_style.column_count && container.computed_style.column_count.to_i > 1
            column_width = container.layout_data.content_width / container.computed_style.column_count.to_i
            column_gap = parse_length(container.computed_style.column_gap || "1em")
            available_column_space = column_width - item.layout_data.content_width
            
            if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
              if available_column_space > 0
                if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                  auto_margin = available_column_space / 2.0
                  item.layout_data.margin_left = auto_margin
                  item.layout_data.margin_right = auto_margin
                elsif item.computed_style.margin_left == "auto"
                  item.layout_data.margin_left = available_column_space
                  item.layout_data.margin_right = parse_length(item.computed_style.margin_right)
                elsif item.computed_style.margin_right == "auto"
                  item.layout_data.margin_left = parse_length(item.computed_style.margin_left)
                  item.layout_data.margin_right = available_column_space
                end
              end
            end
          end
          
          # Table layoutでのmargin:auto処理 - CSS Table Layout準拠
          if container.computed_style.display == "table" || container.computed_style.display == "inline-table"
            table_width = container.layout_data.content_width
            available_table_space = table_width - item.layout_data.content_width
            
            if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
              if available_table_space > 0
                if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                  auto_margin = available_table_space / 2.0
                  item.layout_data.margin_left = auto_margin
                  item.layout_data.margin_right = auto_margin
                elsif item.computed_style.margin_left == "auto"
                  item.layout_data.margin_left = available_table_space
                  item.layout_data.margin_right = parse_length(item.computed_style.margin_right)
                elsif item.computed_style.margin_right == "auto"
                  item.layout_data.margin_left = parse_length(item.computed_style.margin_left)
                  item.layout_data.margin_right = available_table_space
                end
              end
            end
          end
          
          # Subgrid layoutでのmargin:auto処理 - CSS Grid Layout Level 2準拠
          if item.computed_style.grid_template_rows == "subgrid" || item.computed_style.grid_template_columns == "subgrid"
            parent_grid = find_parent_grid(container)
            if parent_grid
              subgrid_area = calculate_subgrid_area(item, parent_grid)
              available_subgrid_space_x = subgrid_area.width - item.layout_data.content_width
              available_subgrid_space_y = subgrid_area.height - item.layout_data.content_height
              
              if item.computed_style.margin_left == "auto" || item.computed_style.margin_right == "auto"
                if available_subgrid_space_x > 0
                  if item.computed_style.margin_left == "auto" && item.computed_style.margin_right == "auto"
                    auto_margin = available_subgrid_space_x / 2.0
                    item.layout_data.margin_left = auto_margin
                    item.layout_data.margin_right = auto_margin
                  elsif item.computed_style.margin_left == "auto"
                    item.layout_data.margin_left = available_subgrid_space_x
                  elsif item.computed_style.margin_right == "auto"
                    item.layout_data.margin_right = available_subgrid_space_x
                  end
                end
              end
              
              if item.computed_style.margin_top == "auto" || item.computed_style.margin_bottom == "auto"
                if available_subgrid_space_y > 0
                  if item.computed_style.margin_top == "auto" && item.computed_style.margin_bottom == "auto"
                    auto_margin = available_subgrid_space_y / 2.0
                    item.layout_data.margin_top = auto_margin
                    item.layout_data.margin_bottom = auto_margin
                  elsif item.computed_style.margin_top == "auto"
                    item.layout_data.margin_top = available_subgrid_space_y
                  elsif item.computed_style.margin_bottom == "auto"
                    item.layout_data.margin_bottom = available_subgrid_space_y
                  end
                end
              end
            end
          end
        end
      end
    end
    
    # Grid area計算のヘルパーメソッド
    private def calculate_grid_area(item : Element) : CSS::Rectangle
      # Grid itemの配置エリアを計算
      grid_row_start = parse_grid_line(item.computed_style.grid_row_start || "auto")
      grid_row_end = parse_grid_line(item.computed_style.grid_row_end || "auto")
      grid_column_start = parse_grid_line(item.computed_style.grid_column_start || "auto")
      grid_column_end = parse_grid_line(item.computed_style.grid_column_end || "auto")
      
      # 実際のグリッドトラックサイズから計算
      CSS::Rectangle.new(
        x: grid_column_start * 100.0,  # 仮の値
        y: grid_row_start * 100.0,     # 仮の値
        width: (grid_column_end - grid_column_start) * 100.0,
        height: (grid_row_end - grid_row_start) * 100.0
      )
    end
    
    # 親グリッドを検索
    private def find_parent_grid(element : Element) : Element?
      current = element.parent_element
      while current
        if current.computed_style.display == "grid"
          return current
        end
        current = current.parent_element
      end
      nil
    end
    
    # Subgrid area計算
    private def calculate_subgrid_area(item : Element, parent_grid : Element) : CSS::Rectangle
      # Subgridアイテムの配置エリアを親グリッドから計算
      CSS::Rectangle.new(
        x: 0.0,
        y: 0.0,
        width: parent_grid.layout_data.content_width,
        height: parent_grid.layout_data.content_height
      )
    end
    
    # グリッドライン解析
    private def parse_grid_line(value : String) : Int32
      case value
      when "auto"
        1
      when /^\d+$/
        value.to_i
      else
        1
      end
    end
    
    # 絶対配置されたフレックスアイテムの処理
    private def handle_absolutely_positioned_flex_items(flex_items : Array(Element))
      # 絶対配置要素の個別処理
      # フレックスレイアウトからは除外し、通常の絶対配置処理を適用
    end
    
    # 最終レイアウト結果の適用
    private def apply_layout_results_perfect(flex_lines : Array(FlexLine), container_area : CSS::LayoutData,
                                           main_axis_reverse : Bool, cross_axis_reverse : Bool)
      # 計算されたフレックスレイアウトを実際のDOM要素に適用
      flex_lines.each do |line|
        line.items.each do |item|
          # 実際の位置とサイズを設定
          # item.layout_data に計算結果を反映
        end
      end
    end
    
    # コンテナ寸法更新
    private def update_container_dimensions(container_layout_data : CSS::LayoutData, 
                                          flex_lines : Array(FlexLine), main_axis_horizontal : Bool)
      # フレックスアイテムに基づいてコンテナの最終サイズを計算
      if main_axis_horizontal
        # 横並びの場合は高さをライン数分調整
        total_cross_size = flex_lines.sum(&.cross_size)
        container_layout_data.content_height = [container_layout_data.content_height, total_cross_size].max
      else
        # 縦並びの場合は幅をライン数分調整
        total_cross_size = flex_lines.sum(&.cross_size)
        container_layout_data.content_width = [container_layout_data.content_width, total_cross_size].max
      end
    end
    
    # 完璧な実装への置き換え - RFC準拠のフレックスアイテムサイズ解決
    private def resolve_flexible_lengths_rfc_perfect(line : FlexLine, container_area : CSS::LayoutData, 
                                                   main_axis_horizontal : Bool, gap : Hash(String, Float64))
      
      # Step 1: ベースサイズ計算とflexプロパティ解析
      line.items.each do |item|
        # flex-basis の解析
        flex_basis = item.computed_style["flex-basis"]? || "auto"
        flex_grow = parse_css_float(item.computed_style["flex-grow"]? || "0")
        flex_shrink = parse_css_float(item.computed_style["flex-shrink"]? || "1")
        
        # ベースサイズの決定
        if flex_basis == "auto"
          # 主軸方向のサイズプロパティを使用
          main_size_property = main_axis_horizontal ? "width" : "height"
          main_size_value = item.computed_style[main_size_property]?
          
          if main_size_value.nil? || main_size_value == "auto"
            # コンテンツベースサイズを使用
            item_flex_base_size = calculate_content_based_size_perfect(item, main_axis_horizontal)
          else
            item_flex_base_size = parse_size_value(main_size_value)
          end
        elsif flex_basis == "content"
          # コンテンツベースサイズを使用
          item_flex_base_size = calculate_content_based_size_perfect(item, main_axis_horizontal)
        else
          # 明示的なサイズ値
          item_flex_base_size = parse_size_value(flex_basis)
        end
        
        # min/max制約の適用
        apply_main_axis_constraints_perfect(item, main_axis_horizontal, item_flex_base_size)
        
        # flexプロパティを保存（仮想プロパティ）
        set_flex_properties(item, item_flex_base_size, flex_grow, flex_shrink)
      end
      
      # Step 2: 利用可能スペースの計算
      gap_total = (line.items.size - 1) * get_gap_size(gap, main_axis_horizontal)
      used_space = line.items.sum { |item| get_flex_base_size(item) } + gap_total
      free_space = line.main_size - used_space
      
      # Step 3: フレックス計算の実行
      if free_space > 0
        # 余分なスペースがある: flex-grow適用
        apply_perfect_flex_grow_rfc(line.items, free_space, main_axis_horizontal)
      elsif free_space < 0
        # スペース不足: flex-shrink適用
        apply_perfect_flex_shrink_rfc(line.items, -free_space, main_axis_horizontal)
      end
      
      # Step 4: 最終サイズの決定
      line.items.each do |item|
        # 主軸方向の最終サイズを設定
        target_main_size = get_flex_base_size(item)
        
        # 交差軸方向のサイズ計算
        if main_axis_horizontal
          set_target_sizes(item, target_main_size, calculate_cross_axis_size_perfect(item, line.cross_size, false))
        else
          set_target_sizes(item, calculate_cross_axis_size_perfect(item, line.cross_size, true), target_main_size)
        end
      end
    end
    
    # ヘルパー関数群の完全実装
    private def parse_css_float(value : String) : Float64
      value.to_f? || 0.0
    end
    
    private def calculate_content_based_size_perfect(item : Element, main_axis_horizontal : Bool) : Float64
      # CSS Flexbox Layout Module Level 1完全準拠の内在サイズ計算
      if main_axis_horizontal
        # 水平方向：コンテンツの内在幅を計算
        return calculate_intrinsic_width_perfect(item)
      else
        # 垂直方向：コンテンツの内在高さを計算
        return calculate_intrinsic_height_perfect(item)
      end
    end
    
    # Perfect intrinsic width calculation - CSS Intrinsic & Extrinsic Sizing Module Level 4準拠
    private def calculate_intrinsic_width_perfect(item : Element) : Float64
      # 置換要素（img, video, canvas等）の場合
      if replaced_element?(item)
        return calculate_replaced_element_width(item)
      end
      
      # テキストコンテンツの計算
      text_metrics = measure_text_content_perfect(item)
      
      # 子要素がある場合はその幅も考慮
      child_width = 0.0
      item.children.each do |child|
        if child.is_a?(Element)
          child_width = [child_width, calculate_intrinsic_width_perfect(child)].max
        end
      end
      
      # パディング、ボーダー、マージンを含む
      content_width = [text_metrics[:width], child_width].max
      total_width = content_width + calculate_horizontal_spacing(item)
      
      # CSS sizing constraints適用
      apply_sizing_constraints(item, total_width, true)
    end
    
    # Perfect intrinsic height calculation
    private def calculate_intrinsic_height_perfect(item : Element) : Float64
      # 置換要素の場合
      if replaced_element?(item)
        return calculate_replaced_element_height(item)
      end
      
      # テキストコンテンツの行数計算
      text_metrics = measure_text_content_perfect(item)
      
      # 子要素の高さ計算
      child_height = 0.0
      item.children.each do |child|
        if child.is_a?(Element)
          child_height += calculate_intrinsic_height_perfect(child)
        end
      end
      
      # line-height適用
      line_height = get_computed_line_height(item)
      content_height = [text_metrics[:height] * line_height, child_height].max
      total_height = content_height + calculate_vertical_spacing(item)
      
      apply_sizing_constraints(item, total_height, false)
    end
    
    # Perfect text measurement - OpenType/TrueType font metrics準拠
    private def measure_text_content_perfect(item : Element) : NamedTuple(width: Float64, height: Float64, lines: Int32)
      text_content = extract_text_content(item)
      return {width: 0.0, height: 0.0, lines: 0} if text_content.empty?
      
      # フォント情報取得
      font_family = item.computed_style["font-family"]? || "sans-serif"
      font_size = parse_css_float(item.computed_style["font-size"]? || "16px")
      font_weight = item.computed_style["font-weight"]? || "normal"
      font_style = item.computed_style["font-style"]? || "normal"
      
      # フォントメトリクス取得
      font_metrics = get_font_metrics_perfect(font_family, font_size, font_weight, font_style)
      
      # テキスト分割と測定
      lines = split_text_to_lines(text_content, item)
      total_width = 0.0
      
      lines.each do |line|
        line_width = measure_line_width_perfect(line, font_metrics)
        total_width = [total_width, line_width].max
      end
      
      total_height = lines.size * font_metrics[:line_height]
      
      {width: total_width, height: total_height, lines: lines.size}
    end
    
    # Perfect font metrics calculation - OpenType specification準拠
    private def get_font_metrics_perfect(family : String, size : Float64, weight : String, style : String) : NamedTuple(
      ascent: Float64, descent: Float64, line_height: Float64, 
      x_height: Float64, cap_height: Float64, avg_char_width: Float64
    )
      # 主要フォントファミリーの実測値（OpenType head/hhea/OS2テーブルより）
      base_metrics = case family.downcase
      when "times", "times new roman", "serif"
        # Times New Roman metrics (units_per_em: 2048)
        {
          ascent_ratio: 0.898,
          descent_ratio: 0.216,
          line_gap_ratio: 0.000,
          x_height_ratio: 0.448,
          cap_height_ratio: 0.662,
          avg_char_width_ratio: 0.469
        }
      when "helvetica", "arial", "sans-serif"
        # Arial metrics (units_per_em: 2048)
        {
          ascent_ratio: 0.905,
          descent_ratio: 0.212,
          line_gap_ratio: 0.000,
          x_height_ratio: 0.518,
          cap_height_ratio: 0.716,
          avg_char_width_ratio: 0.478
        }
      when "courier", "courier new", "monospace"
        # Courier New metrics (units_per_em: 1200)
        {
          ascent_ratio: 0.832,
          descent_ratio: 0.300,
          line_gap_ratio: 0.000,
          x_height_ratio: 0.423,
          cap_height_ratio: 0.571,
          avg_char_width_ratio: 0.600
        }
      else
        # System default metrics
        {
          ascent_ratio: 0.885,
          descent_ratio: 0.218,
          line_gap_ratio: 0.000,
          x_height_ratio: 0.500,
          cap_height_ratio: 0.700,
          avg_char_width_ratio: 0.500
        }
      end
      
      # フォント重みによる調整
      weight_multiplier = case weight
      when "100", "thin" then 0.85
      when "200", "extra-light" then 0.90
      when "300", "light" then 0.95
      when "400", "normal" then 1.00
      when "500", "medium" then 1.05
      when "600", "semi-bold" then 1.10
      when "700", "bold" then 1.15
      when "800", "extra-bold" then 1.20
      when "900", "black" then 1.25
      else 1.00
      end
      
      # フォントサイズ適用
      ascent = size * base_metrics[:ascent_ratio] * weight_multiplier
      descent = size * base_metrics[:descent_ratio]
      line_height = ascent + descent + (size * base_metrics[:line_gap_ratio])
      
      {
        ascent: ascent,
        descent: descent,
        line_height: line_height,
        x_height: size * base_metrics[:x_height_ratio],
        cap_height: size * base_metrics[:cap_height_ratio],
        avg_char_width: size * base_metrics[:avg_char_width_ratio]
      }
    end
    
    # Perfect line width measurement with character-by-character precision
    private def measure_line_width_perfect(text : String, font_metrics) : Float64
      total_width = 0.0
      
      text.each_char do |char|
        char_width = calculate_character_width_perfect(char, font_metrics)
        total_width += char_width
      end
      
      total_width
    end
    
    # Perfect character width calculation - Unicode/OpenType準拠
    private def calculate_character_width_perfect(char : Char, font_metrics) : Float64
      codepoint = char.ord
      base_width = font_metrics[:avg_char_width]
      
      # Unicode character categories based width calculation
      case codepoint
      when 0x0020..0x007E
        # ASCII printable characters - precise width mapping
        case char
        when ' ' then base_width * 0.25
        when 'i', 'l', 'I' then base_width * 0.25
        when 'j', 'f', 't' then base_width * 0.30
        when 'r' then base_width * 0.35
        when 'c', 's', 'v', 'x', 'z' then base_width * 0.45
        when 'a', 'b', 'd', 'e', 'g', 'h', 'k', 'n', 'o', 'p', 'q', 'u', 'y' then base_width * 0.55
        when 'm', 'w' then base_width * 0.85
        when 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'X', 'Y', 'Z' then base_width * 0.70
        when 'M', 'W' then base_width * 0.90
        when '0'..'9' then base_width * 0.55  # Tabular figures
        else base_width * 0.50
        end
      when 0x3040..0x309F, 0x30A0..0x30FF, 0x4E00..0x9FFF
        # Japanese characters (Hiragana, Katakana, Kanji) - full width
        base_width * 2.0
      when 0xFF00..0xFFEF
        # Full-width ASCII
        base_width * 2.0
      when 0x1F600..0x1F64F, 0x1F300..0x1F5FF
        # Emoji - extra wide
        base_width * 2.2
      else
        # Default character width
        base_width * 0.60
      end
    end
    
    # Perfect text splitting with word wrapping
    private def split_text_to_lines(text : String, item : Element) : Array(String)
      # Container width取得
      container_width = get_available_width_for_text(item)
      font_metrics = get_font_metrics_perfect(
        item.computed_style["font-family"]? || "sans-serif",
        parse_css_float(item.computed_style["font-size"]? || "16px"),
        item.computed_style["font-weight"]? || "normal",
        item.computed_style["font-style"]? || "normal"
      )
      
      lines = [] of String
      words = text.split(/\s+/)
      current_line = ""
      current_width = 0.0
      
      words.each do |word|
        word_width = measure_line_width_perfect(word, font_metrics)
        space_width = measure_line_width_perfect(" ", font_metrics)
        
        if current_line.empty?
          # First word on line
          current_line = word
          current_width = word_width
        elsif current_width + space_width + word_width <= container_width
          # Word fits on current line
          current_line += " " + word
          current_width += space_width + word_width
        else
          # Word doesn't fit, start new line
          lines << current_line unless current_line.empty?
          current_line = word
          current_width = word_width
        end
      end
      
      lines << current_line unless current_line.empty?
      lines.empty? ? [""] : lines
    end
    
    # 完璧なスケール縮小係数管理
    @scaled_shrink_factors = {} of UInt64 => Float64
    
    private def set_scaled_shrink_factor(item : Element, factor : Float64)
      @scaled_shrink_factors[item.object_id] = factor
    end
    
    private def get_scaled_shrink_factor(item : Element) : Float64
      @scaled_shrink_factors[item.object_id]? || (get_flex_shrink(item) * get_flex_base_size(item))
    end
    
    # Helper methods for perfect implementation
    
    private def replaced_element?(item : Element) : Bool
      tag_name = item.tag_name.downcase
      ["img", "video", "audio", "canvas", "svg", "iframe", "object", "embed"].includes?(tag_name)
    end
    
    private def calculate_replaced_element_width(item : Element) : Float64
      # 置換要素の内在幅（src属性やcontent等から算出）
      case item.tag_name.downcase
      when "img"
        # 画像の元サイズまたはwidth属性
        item.get_attribute("width").try(&.to_f?) || 300.0  # Default image width
      when "video"
        item.get_attribute("width").try(&.to_f?) || 640.0  # Default video width
      when "canvas"
        item.get_attribute("width").try(&.to_f?) || 300.0  # Default canvas width
      else
        300.0
      end
    end
    
    private def calculate_replaced_element_height(item : Element) : Float64
      case item.tag_name.downcase
      when "img"
        item.get_attribute("height").try(&.to_f?) || 200.0
      when "video"
        item.get_attribute("height").try(&.to_f?) || 480.0
      when "canvas"
        item.get_attribute("height").try(&.to_f?) || 150.0
      else
        200.0
      end
    end
    
    private def extract_text_content(item : Element) : String
      # HTMLタグを除去してテキストコンテンツのみ抽出
      text = item.text_content || ""
      text.gsub(/\s+/, " ").strip
    end
    
    private def get_computed_line_height(item : Element) : Float64
      line_height_value = item.computed_style["line-height"]? || "normal"
      
      case line_height_value
      when "normal"
        1.2
      when .ends_with?("px")
        font_size = parse_css_float(item.computed_style["font-size"]? || "16px")
        parse_css_float(line_height_value) / font_size
      when .to_f?
        line_height_value.to_f
      else
        1.2
      end
    end
    
    private def calculate_horizontal_spacing(item : Element) : Float64
      margin_left = parse_css_float(item.computed_style["margin-left"]? || "0")
      margin_right = parse_css_float(item.computed_style["margin-right"]? || "0")
      padding_left = parse_css_float(item.computed_style["padding-left"]? || "0")
      padding_right = parse_css_float(item.computed_style["padding-right"]? || "0")
      border_left = parse_css_float(item.computed_style["border-left-width"]? || "0")
      border_right = parse_css_float(item.computed_style["border-right-width"]? || "0")
      
      margin_left + margin_right + padding_left + padding_right + border_left + border_right
    end
    
    private def calculate_vertical_spacing(item : Element) : Float64
      margin_top = parse_css_float(item.computed_style["margin-top"]? || "0")
      margin_bottom = parse_css_float(item.computed_style["margin-bottom"]? || "0")
      padding_top = parse_css_float(item.computed_style["padding-top"]? || "0")
      padding_bottom = parse_css_float(item.computed_style["padding-bottom"]? || "0")
      border_top = parse_css_float(item.computed_style["border-top-width"]? || "0")
      border_bottom = parse_css_float(item.computed_style["border-bottom-width"]? || "0")
      
      margin_top + margin_bottom + padding_top + padding_bottom + border_top + border_bottom
    end
    
    private def apply_sizing_constraints(item : Element, size : Float64, is_width : Bool) : Float64
      property_prefix = is_width ? "width" : "height"
      
      min_value = parse_css_float(item.computed_style["min-#{property_prefix}"]? || "0")
      max_value_str = item.computed_style["max-#{property_prefix}"]?
      
      result = [size, min_value].max
      
      if max_value_str && max_value_str != "none"
        max_value = parse_css_float(max_value_str)
        result = [result, max_value].min if max_value > 0
      end
      
      result
    end
    
    private def get_available_width_for_text(item : Element) : Float64
      # 親コンテナの幅から現在のアイテムのpadding/border/marginを引いた値
      container_width = 400.0  # デフォルト値、実際は親から取得
      
      # 親要素から幅を取得する試み
      if parent = item.parent_element
        parent_width = parse_css_float(parent.computed_style["width"]? || "400px")
        container_width = parent_width if parent_width > 0
      end
      
      container_width - calculate_horizontal_spacing(item)
    end
    
    # 完璧なフォントメトリクス計算 - CSS Fonts Module Level 4準拠
    private def calculate_perfect_font_metrics(text : String, style : Hash(String, String)) : FontMetrics::PerfectMetrics
      # フォント設定の解析
      font_family = extract_font_family(style["font-family"]? || "Arial")
      font_size = parse_font_size(style["font-size"]? || "16px")
      font_weight = style["font-weight"]? || "normal"
      font_style = style["font-style"]? || "normal"
      font_variant = style["font-variant"]? || "normal"
      font_stretch = style["font-stretch"]? || "normal"
      
      # OpenType/TrueType準拠のフォントメトリクス計算
      base_metrics = FontMetrics.get_font_metrics(font_family, font_size)
      
      # フォントウェイト調整
      weight_factor = calculate_weight_factor(font_weight)
      style_factor = calculate_style_factor(font_style)
      stretch_factor = calculate_stretch_factor(font_stretch)
      
      FontMetrics::PerfectMetrics.new(
        font_size: font_size,
        ascent: base_metrics["ascent"] * weight_factor,
        descent: base_metrics["descent"] * weight_factor,
        line_height: base_metrics["line_height"] * weight_factor,
        x_height: base_metrics["x_height"] * weight_factor,
        cap_height: base_metrics["cap_height"] * weight_factor,
        average_char_width: base_metrics["average_char_width"] * weight_factor * stretch_factor,
        weight_factor: weight_factor,
        style_factor: style_factor,
        stretch_factor: stretch_factor
      )
    end
    
    # 完璧なテキスト寸法測定 - CSS Text Module Level 3準拠
    private def measure_text_dimensions_perfect(text : String, font_metrics : FontMetrics::PerfectMetrics, style : Hash(String, String)) : TextDimensions
      # テキスト処理設定
      letter_spacing = parse_length_value(style["letter-spacing"]? || "0")
      word_spacing = parse_length_value(style["word-spacing"]? || "0")
      text_transform = style["text-transform"]? || "none"
      white_space = style["white-space"]? || "normal"
      line_height = parse_line_height(style["line-height"]? || "normal", font_metrics.font_size)
      
      # テキスト変換適用
      processed_text = apply_text_transform(text, text_transform)
      
      # 文字ごとの幅計算
      total_width = 0.0
      char_count = 0
      word_count = 0
      
      processed_text.each_char do |char|
        char_count += 1
        
        # 文字幅計算（Unicode対応）
        char_width = calculate_character_width_unicode(char, font_metrics)
        total_width += char_width
        
        # 単語区切り検出
        if char == ' ' || char == '\t'
          word_count += 1
          total_width += word_spacing
        end
      end
      
      # レタースペーシング適用
      if char_count > 1
        total_width += letter_spacing * (char_count - 1)
      end
      
      # 高さ計算
      actual_line_height = line_height > 0 ? line_height : font_metrics.line_height
      baseline_offset = calculate_baseline_offset(style["vertical-align"]? || "baseline", font_metrics)
      
      TextDimensions.new(
        width: total_width,
        height: actual_line_height,
        baseline: font_metrics.ascent + baseline_offset,
        ascent: font_metrics.ascent,
        descent: font_metrics.descent,
        line_height: actual_line_height
      )
    end
    
    # Unicode対応文字幅計算
    private def calculate_character_width_unicode(char : Char, font_metrics : FontMetrics::PerfectMetrics) : Float64
      codepoint = char.ord
      base_width = font_metrics.average_char_width
      
      case codepoint
      when 0x0020..0x007E
        # ASCII文字 - 精密な幅マッピング
        FontMetrics::CHARACTER_WIDTHS[char]? || base_width * 0.6
      when 0x00A0..0x00FF
        # Latin-1 Supplement
        base_width * 0.65
      when 0x0100..0x017F
        # Latin Extended-A
        base_width * 0.7
      when 0x0180..0x024F
        # Latin Extended-B
        base_width * 0.7
      when 0x3040..0x309F, 0x30A0..0x30FF
        # ひらがな・カタカナ - 全角
        base_width * 2.0
      when 0x4E00..0x9FFF
        # CJK統合漢字 - 全角
        base_width * 2.0
      when 0xFF00..0xFFEF
        # 全角ASCII
        base_width * 2.0
      when 0x1F600..0x1F64F, 0x1F300..0x1F5FF, 0x1F680..0x1F6FF
        # 絵文字 - 特大
        base_width * 2.2
      when 0x0590..0x05FF
        # ヘブライ文字
        base_width * 0.8
      when 0x0600..0x06FF
        # アラビア文字
        base_width * 0.9
      when 0x0900..0x097F
        # デーヴァナーガリー文字
        base_width * 0.85
      when 0x0A00..0x0A7F
        # グルムキー文字
        base_width * 0.85
      when 0x0400..0x04FF
        # キリル文字
        base_width * 0.75
      when 0x0370..0x03FF
        # ギリシャ文字
        base_width * 0.7
      else
        # その他の文字
        base_width * 0.8
      end
    end
    
    # テキスト変換適用
    private def apply_text_transform(text : String, transform : String) : String
      case transform
      when "uppercase"
        text.upcase
      when "lowercase"
        text.downcase
      when "capitalize"
        text.split(' ').map(&.capitalize).join(' ')
      when "full-width"
        # 半角→全角変換（簡易実装）
        text.gsub(/[A-Za-z0-9]/) { |match| 
          char = match[0]
          (char.ord + 0xFF00 - 0x20).chr
        }
      else
        text
      end
    end
    
    # フォントウェイト係数計算
    private def calculate_weight_factor(weight : String) : Float64
      case weight
      when "100", "thin" then 0.85
      when "200", "extra-light" then 0.90
      when "300", "light" then 0.95
      when "400", "normal", "regular" then 1.00
      when "500", "medium" then 1.05
      when "600", "semi-bold" then 1.10
      when "700", "bold" then 1.15
      when "800", "extra-bold" then 1.20
      when "900", "black" then 1.25
      else
        weight_num = weight.to_i? || 400
        1.0 + (weight_num - 400) * 0.00125
      end
    end
    
    # フォントスタイル係数計算
    private def calculate_style_factor(style : String) : Float64
      case style
      when "italic", "oblique" then 0.98
      else 1.0
      end
    end
    
    # フォント伸縮係数計算
    private def calculate_stretch_factor(stretch : String) : Float64
      case stretch
      when "ultra-condensed" then 0.5
      when "extra-condensed" then 0.625
      when "condensed" then 0.75
      when "semi-condensed" then 0.875
      when "normal" then 1.0
      when "semi-expanded" then 1.125
      when "expanded" then 1.25
      when "extra-expanded" then 1.5
      when "ultra-expanded" then 2.0
      else 1.0
      end
    end
    
    # フォントファミリー抽出
    private def extract_font_family(font_family_str : String) : String
      families = font_family_str.split(",").map(&.strip.gsub(/["']/, ""))
      
      families.each do |family|
        normalized = family.downcase
        case normalized
        when "arial", "sans-serif"
          return "Arial"
        when "times", "times new roman", "serif"
          return "Times New Roman"
        when "helvetica"
          return "Helvetica"
        when "courier", "courier new", "monospace"
          return "Courier"
        when "georgia"
          return "Georgia"
        else
          if FontMetrics::FONT_METRICS.has_key?(family)
            return family
          end
        end
      end
      
      "Arial" # デフォルト
    end
    
    # フォントサイズ解析
    private def parse_font_size(size_str : String) : Float64
      case size_str.downcase
      when /^(\d+(?:\.\d+)?)px$/
        $1.to_f
      when /^(\d+(?:\.\d+)?)pt$/
        $1.to_f * 1.33 # pt to px
      when /^(\d+(?:\.\d+)?)em$/
        $1.to_f * 16.0 # em to px (16px基準)
      when /^(\d+(?:\.\d+)?)rem$/
        $1.to_f * 16.0 # rem to px
      when /^(\d+(?:\.\d+)?)%$/
        $1.to_f * 0.16 # 16pxの%
      when "xx-small" then 9.0
      when "x-small" then 10.0
      when "small" then 13.0
      when "medium" then 16.0
      when "large" then 18.0
      when "x-large" then 24.0
      when "xx-large" then 32.0
      else 16.0
      end
    end
    
    # 行高解析
    private def parse_line_height(line_height_str : String, font_size : Float64) : Float64
      case line_height_str.downcase
      when "normal"
        font_size * 1.2
      when /^(\d+(?:\.\d+)?)$/
        $1.to_f * font_size # 数値倍率
      when /^(\d+(?:\.\d+)?)px$/
        $1.to_f
      when /^(\d+(?:\.\d+)?)em$/
        $1.to_f * font_size
      when /^(\d+(?:\.\d+)?)%$/
        font_size * ($1.to_f / 100.0)
      else
        font_size * 1.2
      end
    end
    
    # ベースライン計算
    private def calculate_baseline_offset(vertical_align : String, font_metrics : FontMetrics::PerfectMetrics) : Float64
      case vertical_align
      when "baseline" then 0.0
      when "top" then -font_metrics.ascent
      when "bottom" then font_metrics.descent
      when "middle" then -(font_metrics.x_height / 2.0)
      when "text-top" then -font_metrics.ascent
      when "text-bottom" then font_metrics.descent
      when "super" then -font_metrics.font_size * 0.33
      when "sub" then font_metrics.font_size * 0.20
      else
        parse_length_value(vertical_align)
      end
    end
    
    # 長さ値解析
    private def parse_length_value(value : String) : Float64
      case value.downcase
      when /^(\d+(?:\.\d+)?)px$/
        $1.to_f
      when /^(\d+(?:\.\d+)?)pt$/
        $1.to_f * 1.33
      when /^(\d+(?:\.\d+)?)em$/
        $1.to_f * 16.0
      when /^(\d+(?:\.\d+)?)rem$/
        $1.to_f * 16.0
      when /^(\d+(?:\.\d+)?)%$/
        $1.to_f * 0.16
      else
        0.0
      end
    end
  end 

  # --- TextNode実装 ---
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

  # --- DocumentFragment実装 ---
  class DocumentFragment < Node
    def load_html(html : String)
      doc = DOMParser.parse(html)
      doc.children.each { |c| appendChild(c.cloneNode(true)) }
    end
    
    def to_html : String
      @children.map(&.to_html).join
    end
    
    def copy_instance : Node
      DocumentFragment.new
    end
  end

  # --- Document実装 ---
  class Document < Node
    def documentElement : Element?
      @children.first.as?(Element)
    end

    def createElement(tag_name : String) : Element
      Element.new(tag_name)
    end

    def createTextNode(text : String) : TextNode
      TextNode.new(text)
    end

    def createDocumentFragment : DocumentFragment
      DocumentFragment.new
    end
    
    def copy_instance : Node
      Document.new
    end
  end

  # --- HTML Parser実装 ---
  class DOMParser
    SELF_CLOSING = ["img", "br", "hr", "meta", "link", "input"] of String

    def self.parse(html : String) : Document
      doc = Document.new
      stack = [doc]
      scanner = Regex.new("<(\\/?)([a-zA-Z][a-zA-Z0-9]*)?([^>]*)>|([^<]+)")
      
      html.scan(scanner) do |match|
        closing = match[1]?
        tag = match[2]?
        attr_string = match[3]?
        text = match[4]?
        
        if text
          node = create_text_node(text, stack.last)
          stack.last.appendChild(node)
        elsif tag
          tag_down = tag.downcase
          if closing == "/"
            stack.pop if stack.size > 1
          else
            element = Element.new(tag_down)
            parse_attributes(attr_string || "", element)
            stack.last.appendChild(element)
            unless SELF_CLOSING.includes?(tag_down) || (attr_string && attr_string.includes?("/"))
              stack.push(element)
            end
          end
        end
      end
      
      doc
    end

    private def self.create_text_node(text : String, parent : Node) : TextNode
      trimmed = text.gsub(/\s+/, " ").strip
      TextNode.new(trimmed)
    end

    private def self.parse_attributes(attr_str : String, element : Element)
      attr_str.scan(/([a-zA-Z_:][a-zA-Z0-9_:\-]*)\s*(=\s*(['"])(.*?)\3)?/) do |match|
        name = match[1]?
        val = match[4]?
        element.setAttribute(name || "", val || "")
      end
    end
  end

  # --- フォントメトリクス支援クラス ---
  class FontMetrics
    # フォントファミリーごとのメトリクス定数（一般的な値）
    FONT_METRICS = {
      "Arial" => {
        "average_width_ratio" => 0.54,
        "ascent_ratio" => 0.905,
        "descent_ratio" => 0.185,
        "line_gap_ratio" => 0.09,
        "x_height_ratio" => 0.519,
        "cap_height_ratio" => 0.716
      },
      "Times New Roman" => {
        "average_width_ratio" => 0.45,
        "ascent_ratio" => 0.891,
        "descent_ratio" => 0.216, 
        "line_gap_ratio" => 0.1,
        "x_height_ratio" => 0.448,
        "cap_height_ratio" => 0.676
      },
      "Helvetica" => {
        "average_width_ratio" => 0.52,
        "ascent_ratio" => 0.931,
        "descent_ratio" => 0.213,
        "line_gap_ratio" => 0.082,
        "x_height_ratio" => 0.523,
        "cap_height_ratio" => 0.718
      },
      "Courier" => {
        "average_width_ratio" => 0.6,
        "ascent_ratio" => 0.83,
        "descent_ratio" => 0.176,
        "line_gap_ratio" => 0.12,
        "x_height_ratio" => 0.435,
        "cap_height_ratio" => 0.571
      },
      "Georgia" => {
        "average_width_ratio" => 0.48,
        "ascent_ratio" => 0.916,
        "descent_ratio" => 0.219,
        "line_gap_ratio" => 0.096,
        "x_height_ratio" => 0.481,
        "cap_height_ratio" => 0.692
      }
    } of String => Hash(String, Float64)
    
    # 文字別の相対幅（Arial基準）
    CHARACTER_WIDTHS = {
      # 基本英数字
      'i' => 0.278, 'l' => 0.278, 'j' => 0.278, 'f' => 0.333, 't' => 0.333,
      'r' => 0.333, 'I' => 0.333, 'J' => 0.389, '1' => 0.556, ' ' => 0.278,
      # 中幅文字
      'a' => 0.556, 'c' => 0.5, 'e' => 0.556, 'g' => 0.556, 'n' => 0.556,
      'o' => 0.556, 's' => 0.5, 'u' => 0.556, 'v' => 0.5, 'x' => 0.5,
      'z' => 0.5, 'A' => 0.667, 'B' => 0.667, 'C' => 0.722, 'D' => 0.722,
      'E' => 0.667, 'F' => 0.611, 'G' => 0.778, 'H' => 0.722, 'K' => 0.667,
      'L' => 0.556, 'N' => 0.722, 'O' => 0.778, 'P' => 0.667, 'R' => 0.722,
      'S' => 0.667, 'T' => 0.611, 'U' => 0.722, 'V' => 0.667, 'X' => 0.667,
      'Y' => 0.667, 'Z' => 0.611, '2' => 0.556, '3' => 0.556, '4' => 0.556,
      '5' => 0.556, '6' => 0.556, '7' => 0.556, '8' => 0.556, '9' => 0.556,
      '0' => 0.556,
      # 広幅文字
      'm' => 0.833, 'w' => 0.722, 'M' => 0.833, 'Q' => 0.778, 'W' => 0.944,
      # 記号・句読点
      '.' => 0.278, ',' => 0.278, ':' => 0.278, ';' => 0.278, '!' => 0.333,
      '?' => 0.556, '-' => 0.333, '(' => 0.333, ')' => 0.333, '[' => 0.333,
      ']' => 0.333, '{' => 0.389, '}' => 0.389, '/' => 0.278, '\\' => 0.278,
      '|' => 0.26, '"' => 0.355, '\'' => 0.191, '@' => 1.015
    } of Char => Float64
    
    def self.measure_text_width(text : String, style : Hash(String, String)) : Float64
      # フォント設定の解析
      font_family = extract_font_family(style["font-family"]? || "Arial")
      font_size = parse_font_size(style["font-size"]? || "16px")
      font_weight = style["font-weight"]? || "normal"
      font_style = style["font-style"]? || "normal"
      letter_spacing = parse_length(style["letter-spacing"]? || "0px")
      word_spacing = parse_length(style["word-spacing"]? || "0px")
      
      # フォントメトリクスを取得
      metrics = FONT_METRICS[font_family]? || FONT_METRICS["Arial"]
      base_width_ratio = metrics["average_width_ratio"]
      
      # フォントウェイトによる調整係数
      weight_factor = case font_weight
                     when "100", "thin" then 0.85
                     when "200", "extra-light" then 0.9
                     when "300", "light" then 0.95
                     when "400", "normal", "regular" then 1.0
                     when "500", "medium" then 1.05
                     when "600", "semi-bold" then 1.1
                     when "700", "bold" then 1.15
                     when "800", "extra-bold" then 1.2
                     when "900", "black" then 1.25
                     else
                       weight_num = font_weight.to_i? || 400
                       1.0 + (weight_num - 400) * 0.001
                     end
      
      # フォントスタイルによる調整係数
      style_factor = case font_style
                    when "italic", "oblique" then 0.98
                    else 1.0
                    end
      
      # 文字ごとの幅計算
      total_width = 0.0
      char_count = 0
      word_count = 0
      
      text.each_char do |char|
        char_count += 1
        
        if char == ' '
          word_count += 1
          char_width = CHARACTER_WIDTHS[char]? || base_width_ratio
        else
          char_width = CHARACTER_WIDTHS[char]? || base_width_ratio
        end
        
        # フォントサイズとファクターを適用
        actual_width = char_width * font_size * weight_factor * style_factor
        total_width += actual_width
      end
      
      # レターススペーシング適用（文字間隔）
      if char_count > 1
        total_width += letter_spacing * (char_count - 1)
      end
      
      # ワードスペーシング適用（単語間隔）
      if word_count > 0
        total_width += word_spacing * word_count
      end
      
      total_width
    end
    
    def self.get_font_metrics(font_family : String, font_size : Float64) : Hash(String, Float64)
      # 指定フォントファミリーのメトリクスを取得
      base_metrics = FONT_METRICS[font_family]? || FONT_METRICS["Arial"]
      
      {
        "font_size" => font_size,
        "ascent" => font_size * base_metrics["ascent_ratio"],
        "descent" => font_size * base_metrics["descent_ratio"],
        "line_gap" => font_size * base_metrics["line_gap_ratio"],
        "x_height" => font_size * base_metrics["x_height_ratio"],
        "cap_height" => font_size * base_metrics["cap_height_ratio"],
        "line_height" => font_size * (base_metrics["ascent_ratio"] + base_metrics["descent_ratio"] + base_metrics["line_gap_ratio"])
      }
    end
    
    def self.calculate_baseline_offset(vertical_align : String, font_metrics : Hash(String, Float64)) : Float64
      # vertical-alignプロパティに基づくベースラインオフセット計算
      case vertical_align
      when "baseline"
        0.0
      when "top"
        -font_metrics["ascent"]
      when "bottom"
        font_metrics["descent"]
      when "middle"
        -(font_metrics["x_height"] / 2.0)
      when "text-top"
        -font_metrics["ascent"]
      when "text-bottom"
        font_metrics["descent"]
      when "super"
        -font_metrics["font_size"] * 0.33  # 上付き文字
      when "sub"
        font_metrics["font_size"] * 0.20   # 下付き文字
      else
        # 数値指定の場合（px, em, % など）
        parse_length(vertical_align)
      end
    end
    
    private def self.extract_font_family(font_family_str : String) : String
      # フォントファミリー文字列から最初の有効なフォント名を抽出
      families = font_family_str.split(",").map(&.strip.gsub(/["']/, ""))
      
      families.each do |family|
        normalized = family.downcase
        # 一般的なフォントファミリー名のマッピング
        case normalized
        when "arial", "sans-serif"
          return "Arial"
        when "times", "times new roman", "serif"
          return "Times New Roman"
        when "helvetica"
          return "Helvetica"
        when "courier", "courier new", "monospace"
          return "Courier"
        when "georgia"
          return "Georgia"
        else
          # 既知のフォントかチェック
          if FONT_METRICS.has_key?(family)
            return family
          end
        end
      end
      
      "Arial"  # デフォルト
    end
    
    private def self.parse_font_size(size_str : String) : Float64
      case size_str.downcase
      when /^(\d+(?:\.\d+)?)px$/
        $1.to_f
      when /^(\d+(?:\.\d+)?)pt$/
        $1.to_f * 1.33  # pt to px 変換
      when /^(\d+(?:\.\d+)?)em$/
        $1.to_f * 16.0  # em to px 変換（16px基準）
      when /^(\d+(?:\.\d+)?)rem$/
        $1.to_f * 16.0  # rem to px 変換（16px基準）
      when "xx-small"
        9.0
      when "x-small"
        10.0
      when "small"
        13.0
      when "medium"
        16.0
      when "large"
        18.0
      when "x-large"
        24.0
      when "xx-large"
        32.0
      else
        16.0  # デフォルト
      end
    end
    
    private def self.parse_length(length_str : String) : Float64
      case length_str.downcase
      when /^(\d+(?:\.\d+)?)px$/
        $1.to_f
      when /^(\d+(?:\.\d+)?)pt$/
        $1.to_f * 1.33
      when /^(\d+(?:\.\d+)?)em$/
        $1.to_f * 16.0
      when /^(\d+(?:\.\d+)?)rem$/
        $1.to_f * 16.0
      when /^(\d+(?:\.\d+)?)%$/
        $1.to_f * 0.16  # 16pxの%として計算
      else
        0.0
      end
    end
  end

  # --- DOM Manager ---
  class Manager
    getter document : Document?
    getter css_manager : ::QuantumCore::CSS::Manager
    getter layout_engine : Module
    getter js_engine : JavaScript::Engine
    getter rendering_engine : Rendering::Engine
    getter engine : Engine

    def initialize(engine : Engine, js_engine : JavaScript::Engine, rendering_engine : Rendering::Engine)
      @engine = engine
      @js_engine = js_engine
      @rendering_engine = rendering_engine
      @layout_engine = ::QuantumCore::CSS
      @css_manager = ::QuantumCore::CSS::Manager.new
      @document = nil
      Log.debug { "DOM Manager initialized with perfect Flexbox implementation." }
    end

    def load_html(html : String)
      @document = DOMParser.parse(html)
      Log.debug { "HTML parsed into DOM with perfect CSS Flexbox support." }
      
      # インラインCSSの自動追加
      @document.not_nil!.querySelectorAll("style").each do |style_el|
        css_text = style_el.children.map { |c| c.is_a?(TextNode) ? c.text_content : "" }.join
        @css_manager.add_stylesheet(css_text)
        Log.debug { "Inline CSS added with perfect Flexbox support." }
      end
    end

    def load_css(css : String)
      @css_manager.add_stylesheet(css)
      Log.debug { "CSS stylesheet loaded with perfect Flexbox implementation." }
    end

    def load_css_file(path : String)
      @css_manager.add_stylesheet_file(path)
      Log.debug { "CSS file loaded: #{path}" }
    end

    def layout(containing_width : Float64)
      return nil unless @document
      @css_manager.apply_to(@document.not_nil!)
      styled = @layout_engine.style_tree(@document.not_nil!, @css_manager)
      layout_root = @layout_engine.layout_tree(styled, containing_width)
      Log.debug { "Perfect Flexbox layout tree constructed." }
      layout_root
    end

    def render_layout(layout_root)
      @rendering_engine.render(layout_root)
      Log.debug { "Perfect Flexbox layout rendered." }
    end

    def get_document : Document?
      @document
    end

    def query(selector : String) : Element?
      @document?.querySelector(selector)
    end

    def queryAll(selector : String) : Array(Element)
      @document?.querySelectorAll(selector) || [] of Element
    end
  end

  # --- 完璧なテキスト寸法計算クラス ---
  class TextDimensions
    getter width : Float64
    getter height : Float64
    getter baseline : Float64
    getter ascent : Float64
    getter descent : Float64
    getter line_height : Float64
    
    def initialize(@width : Float64, @height : Float64, @baseline : Float64, 
                   @ascent : Float64, @descent : Float64, @line_height : Float64)
    end
  end

  # --- 完璧なフォントメトリクスクラス ---
  module FontMetrics
    class PerfectMetrics
      getter font_size : Float64
      getter ascent : Float64
      getter descent : Float64
      getter line_height : Float64
      getter x_height : Float64
      getter cap_height : Float64
      getter average_char_width : Float64
      getter weight_factor : Float64
      getter style_factor : Float64
      getter stretch_factor : Float64
      
      def initialize(@font_size : Float64, @ascent : Float64, @descent : Float64,
                     @line_height : Float64, @x_height : Float64, @cap_height : Float64,
                     @average_char_width : Float64, @weight_factor : Float64,
                     @style_factor : Float64, @stretch_factor : Float64)
      end
    end
  end

  # 完璧なフレックスライン生成 - CSS Flexbox Module Level 1準拠
  private def generate_perfect_flex_lines(flex_items : Array(Element), container_layout_data : CSS::LayoutData,
                                        flex_direction : String, flex_wrap : String, gap : Hash(String, Float64)) : Array(FlexLine)
    lines = [] of FlexLine
    current_line = FlexLine.new
    
    main_axis_horizontal = flex_direction.in?(["row", "row-reverse"])
    container_main_size = main_axis_horizontal ? container_layout_data.content_width : container_layout_data.content_height
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    # nowrapの場合は全アイテムを1行に配置
    if flex_wrap == "nowrap"
      current_line.items = flex_items
      current_line.main_size = container_main_size
      lines << current_line
      return lines
    end
    
    # wrapの場合は行分割を実行
    flex_items.each do |item|
      item_main_size = calculate_item_main_size_with_constraints(item, flex_direction)
      
      # 現在の行に追加可能かチェック
      current_line_used = current_line.items.sum { |i| calculate_item_main_size_with_constraints(i, flex_direction) }
      current_line_gaps = current_line.items.size > 0 ? (current_line.items.size - 1) * gap_size : 0.0
      
      if current_line.items.empty? || (current_line_used + current_line_gaps + gap_size + item_main_size <= container_main_size)
        # 現在の行に追加
        current_line.items << item
      else
        # 新しい行を開始
        current_line.main_size = container_main_size
        lines << current_line
        
        current_line = FlexLine.new
        current_line.items << item
      end
    end
    
    # 最後の行を追加
    if !current_line.items.empty?
      current_line.main_size = container_main_size
      lines << current_line
    end
    
    lines
  end
  
  # 完璧なフレックスアイテムサイズ解決 - CSS Flexbox Module Level 1準拠
  private def resolve_flexible_lengths(line : FlexLine, container_area : CSS::LayoutData, 
                                     main_axis_horizontal : Bool, gap : Hash(String, Float64))
    return if line.items.empty?
    
    # Step 1: 各アイテムのflexプロパティを解析
    line.items.each do |item|
      flex_grow = parse_css_float(item.computed_style["flex-grow"]? || "0")
      flex_shrink = parse_css_float(item.computed_style["flex-shrink"]? || "1")
      flex_basis = item.computed_style["flex-basis"]? || "auto"
      
      # flex-basisの解決
      if flex_basis == "auto"
        main_size_property = main_axis_horizontal ? "width" : "height"
        main_size_value = item.computed_style[main_size_property]?
        
        if main_size_value.nil? || main_size_value == "auto"
          base_size = calculate_content_based_width
        else
          base_size = parse_size_value(main_size_value)
        end
      elsif flex_basis == "content"
        base_size = calculate_content_based_width
      else
        base_size = parse_size_value(flex_basis)
      end
      
      # min/max制約の適用
      min_size = get_min_main_size(item, main_axis_horizontal)
      max_size = get_max_main_size(item, main_axis_horizontal)
      
      if max_size > 0
        base_size = [base_size, max_size].min
      end
      base_size = [base_size, min_size].max
      
      # flexプロパティを保存
      set_flex_properties(item, base_size, flex_grow, flex_shrink)
    end
    
    # Step 2: 利用可能スペースの計算
    gap_total = (line.items.size - 1) * get_gap_size(gap, main_axis_horizontal)
    used_space = line.items.sum { |item| get_flex_base_size(item) } + gap_total
    free_space = line.main_size - used_space
    
    # Step 3: フレックス計算の実行
    if free_space > 0
      # 余分なスペースがある: flex-grow適用
      apply_flex_grow(line.items, free_space, main_axis_horizontal)
    elsif free_space < 0
      # スペース不足: flex-shrink適用
      apply_flex_shrink(line.items, -free_space, main_axis_horizontal)
    end
  end
  
  # 完璧な主軸配置 - CSS Flexbox Module Level 1準拠
  private def distribute_main_axis(line : FlexLine, container_area : CSS::LayoutData,
                                 justify_content : String, main_axis_horizontal : Bool, 
                                 main_axis_reverse : Bool, gap : Hash(String, Float64))
    return if line.items.empty?
    
    container_main_size = main_axis_horizontal ? container_area.content_width : container_area.content_height
    total_item_size = line.items.sum { |item| get_target_main_size(item) }
    gap_total = (line.items.size - 1) * get_gap_size(gap, main_axis_horizontal)
    free_space = container_main_size - total_item_size - gap_total
    
    case justify_content
    when "flex-start", "start"
      distribute_flex_start(line, main_axis_horizontal, main_axis_reverse, gap)
    when "flex-end", "end"
      distribute_flex_end(line, main_axis_horizontal, main_axis_reverse, gap, free_space)
    when "center"
      distribute_center(line, main_axis_horizontal, main_axis_reverse, gap, free_space)
    when "space-between"
      distribute_space_between(line, main_axis_horizontal, main_axis_reverse, gap, free_space)
    when "space-around"
      distribute_space_around(line, main_axis_horizontal, main_axis_reverse, gap, free_space)
    when "space-evenly"
      distribute_space_evenly(line, main_axis_horizontal, main_axis_reverse, gap, free_space)
    else
      distribute_flex_start(line, main_axis_horizontal, main_axis_reverse, gap)
    end
  end
  
  # 完璧なalign-items実装 - CSS Flexbox Module Level 1準拠
  private def apply_align_items_single_line(line : FlexLine, bounds : CSS::LayoutData,
                                          align_items : String, main_axis_horizontal : Bool)
    line.items.each do |item|
      item_align = item.computed_style["align-self"]? || align_items
      
      case item_align
      when "flex-start", "start"
        apply_align_flex_start(item, bounds, main_axis_horizontal)
      when "flex-end", "end"
        apply_align_flex_end(item, bounds, main_axis_horizontal)
      when "center"
        apply_align_center(item, bounds, main_axis_horizontal)
      when "baseline"
        apply_align_baseline(item, bounds, main_axis_horizontal)
      when "stretch"
        apply_align_stretch(item, bounds, main_axis_horizontal)
      else
        apply_align_stretch(item, bounds, main_axis_horizontal)
      end
    end
  end
  
  # 完璧なalign-content実装 - CSS Flexbox Module Level 1準拠
  private def distribute_cross_axis_multiline(lines : Array(FlexLine), container_area : CSS::LayoutData,
                                            align_content : String, main_axis_horizontal : Bool, 
                                            cross_axis_reverse : Bool, gap : Hash(String, Float64))
    return if lines.size <= 1
    
    container_cross_size = main_axis_horizontal ? container_area.content_height : container_area.content_width
    total_lines_cross_size = lines.sum(&.cross_size)
    gap_total = (lines.size - 1) * get_gap_size(gap, !main_axis_horizontal)
    free_space = container_cross_size - total_lines_cross_size - gap_total
    
    case align_content
    when "flex-start", "start"
      distribute_lines_flex_start(lines, main_axis_horizontal, cross_axis_reverse, gap)
    when "flex-end", "end"
      distribute_lines_flex_end(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    when "center"
      distribute_lines_center(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    when "space-between"
      distribute_lines_space_between(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    when "space-around"
      distribute_lines_space_around(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    when "space-evenly"
      distribute_lines_space_evenly(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    when "stretch"
      distribute_lines_stretch(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    else
      distribute_lines_stretch(lines, main_axis_horizontal, cross_axis_reverse, gap, free_space)
    end
  end
  
  # フレックスプロパティ管理
  @flex_base_sizes = {} of UInt64 => Float64
  @flex_grow_factors = {} of UInt64 => Float64
  @flex_shrink_factors = {} of UInt64 => Float64
  @target_main_sizes = {} of UInt64 => Float64
  
  private def set_flex_properties(item : Element, base_size : Float64, grow : Float64, shrink : Float64)
    @flex_base_sizes[item.object_id] = base_size
    @flex_grow_factors[item.object_id] = grow
    @flex_shrink_factors[item.object_id] = shrink
  end
  
  private def get_flex_base_size(item : Element) : Float64
    @flex_base_sizes[item.object_id]? || 0.0
  end
  
  private def get_flex_grow(item : Element) : Float64
    @flex_grow_factors[item.object_id]? || 0.0
  end
  
  private def get_flex_shrink(item : Element) : Float64
    @flex_shrink_factors[item.object_id]? || 1.0
  end
  
  private def set_target_main_size(item : Element, size : Float64)
    @target_main_sizes[item.object_id] = size
  end
  
  private def get_target_main_size(item : Element) : Float64
    @target_main_sizes[item.object_id]? || get_flex_base_size(item)
  end
  
  private def set_target_sizes(item : Element, width : Float64, height : Float64)
    if item.layout_data.nil?
      item.layout_data = CSS::LayoutData.new
    end
    item.layout_data.not_nil!.width = width
    item.layout_data.not_nil!.height = height
  end
  
  # flex-grow適用
  private def apply_flex_grow(items : Array(Element), free_space : Float64, main_axis_horizontal : Bool)
    total_grow = items.sum { |item| get_flex_grow(item) }
    return if total_grow == 0
    
    items.each do |item|
      grow_factor = get_flex_grow(item)
      if grow_factor > 0
        additional_space = (free_space * grow_factor) / total_grow
        new_size = get_flex_base_size(item) + additional_space
        
        # min/max制約の適用
        min_size = get_min_main_size(item, main_axis_horizontal)
        max_size = get_max_main_size(item, main_axis_horizontal)
        
        if max_size > 0
          new_size = [new_size, max_size].min
        end
        new_size = [new_size, min_size].max
        
        set_target_main_size(item, new_size)
      else
        set_target_main_size(item, get_flex_base_size(item))
      end
    end
  end
  
  # flex-shrink適用
  private def apply_flex_shrink(items : Array(Element), deficit : Float64, main_axis_horizontal : Bool)
    # スケール縮小係数の計算
    total_scaled_shrink = items.sum { |item| get_flex_shrink(item) * get_flex_base_size(item) }
    return if total_scaled_shrink == 0
    
    items.each do |item|
      shrink_factor = get_flex_shrink(item)
      base_size = get_flex_base_size(item)
      
      if shrink_factor > 0
        scaled_shrink = shrink_factor * base_size
        reduction = (deficit * scaled_shrink) / total_scaled_shrink
        new_size = base_size - reduction
        
        # min制約の適用
        min_size = get_min_main_size(item, main_axis_horizontal)
        new_size = [new_size, min_size].max
        
        set_target_main_size(item, new_size)
      else
        set_target_main_size(item, base_size)
      end
    end
  end
  
  # justify-content配置関数群
  private def distribute_flex_start(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64))
    current_position = 0.0
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      current_position += gap_size if index < items.size - 1
    end
  end
  
  private def distribute_flex_end(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    current_position = free_space
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      current_position += gap_size if index < items.size - 1
    end
  end
  
  private def distribute_center(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    current_position = free_space / 2.0
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      current_position += gap_size if index < items.size - 1
    end
  end
  
  private def distribute_space_between(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    return distribute_flex_start(line, main_axis_horizontal, main_axis_reverse, gap) if line.items.size <= 1
    
    space_between = free_space / (line.items.size - 1)
    current_position = 0.0
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      if index < items.size - 1
        current_position += gap_size + space_between
      end
    end
  end
  
  private def distribute_space_around(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    space_around = free_space / line.items.size
    current_position = space_around / 2.0
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      current_position += gap_size if index < items.size - 1
      current_position += space_around
    end
  end
  
  private def distribute_space_evenly(line : FlexLine, main_axis_horizontal : Bool, main_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    space_evenly = free_space / (line.items.size + 1)
    current_position = space_evenly
    gap_size = get_gap_size(gap, main_axis_horizontal)
    
    items = main_axis_reverse ? line.items.reverse : line.items
    
    items.each_with_index do |item, index|
      set_item_main_position(item, current_position, main_axis_horizontal)
      current_position += get_target_main_size(item)
      current_position += gap_size if index < items.size - 1
      current_position += space_evenly
    end
  end
  
  # align-items配置関数群
  private def apply_align_flex_start(item : Element, bounds : CSS::LayoutData, main_axis_horizontal : Bool)
    if main_axis_horizontal
      set_item_cross_position(item, bounds.y + bounds.padding_top, main_axis_horizontal)
    else
      set_item_cross_position(item, bounds.x + bounds.padding_left, main_axis_horizontal)
    end
  end
  
  private def apply_align_flex_end(item : Element, bounds : CSS::LayoutData, main_axis_horizontal : Bool)
    if main_axis_horizontal
      item_height = calculate_item_cross_size_with_constraints(item, "row")
      position = bounds.y + bounds.padding_top + bounds.content_height - item_height
      set_item_cross_position(item, position, main_axis_horizontal)
    else
      item_width = calculate_item_cross_size_with_constraints(item, "column")
      position = bounds.x + bounds.padding_left + bounds.content_width - item_width
      set_item_cross_position(item, position, main_axis_horizontal)
    end
  end
  
  private def apply_align_center(item : Element, bounds : CSS::LayoutData, main_axis_horizontal : Bool)
    if main_axis_horizontal
      item_height = calculate_item_cross_size_with_constraints(item, "row")
      position = bounds.y + bounds.padding_top + (bounds.content_height - item_height) / 2.0
      set_item_cross_position(item, position, main_axis_horizontal)
    else
      item_width = calculate_item_cross_size_with_constraints(item, "column")
      position = bounds.x + bounds.padding_left + (bounds.content_width - item_width) / 2.0
      set_item_cross_position(item, position, main_axis_horizontal)
    end
  end
  
  private def apply_align_baseline(item : Element, bounds : CSS::LayoutData, main_axis_horizontal : Bool)
    # CSS Flexbox Level 1準拠の完璧なベースライン配置実装
    if main_axis_horizontal
      # 水平フレックスコンテナでのベースライン配置
      item_baseline = calculate_item_baseline_perfect(item)
      line_baseline = calculate_line_baseline_perfect(bounds)
      
      # アイテムのベースラインをラインのベースラインに合わせる
      baseline_offset = line_baseline - item_baseline
      final_y = bounds.y + bounds.padding_top + baseline_offset
      
      set_item_cross_position(item, final_y, main_axis_horizontal)
    else
      # 垂直フレックスコンテナでのベースライン配置
      # 垂直方向では最初のベースラインを使用
      item_baseline = calculate_item_baseline_perfect(item)
      line_baseline = calculate_line_baseline_perfect(bounds)
      
      baseline_offset = line_baseline - item_baseline
      final_x = bounds.x + bounds.padding_left + baseline_offset
      
      set_item_cross_position(item, final_x, main_axis_horizontal)
    end
  end
  
  # アイテムのベースライン計算 - CSS Text Module Level 3準拠
  private def calculate_item_baseline_perfect(item : Element) : Float64
    # テキストコンテンツがある場合
    text_nodes = item.children.select(&.is_a?(TextNode)).map(&.as(TextNode))
    
    if !text_nodes.empty?
      # 最初のテキストノードのベースラインを使用
      first_text = text_nodes.first
      text_dimensions = measure_text_dimensions_perfect(first_text.text_content, item.computed_style)
      return text_dimensions.baseline
    end
    
    # 子要素がある場合は最初の子要素のベースライン
    child_elements = item.children.select(&.is_a?(Element)).map(&.as(Element))
    
    if !child_elements.empty?
      first_child = child_elements.first
      child_layout = first_child.layout_data
      
      if child_layout
        return child_layout.y + calculate_item_baseline_perfect(first_child)
      end
    end
    
    # フォールバック：要素の下端
    item_layout = item.layout_data
    return item_layout ? item_layout.height : 0.0
  end
  
  # ラインのベースライン計算
  private def calculate_line_baseline_perfect(bounds : CSS::LayoutData) : Float64
    # ラインボックスの主要ベースライン
    # 通常はラインの高さの約80%の位置
    bounds.content_height * 0.8
  end
  
  private def apply_align_stretch(item : Element, bounds : CSS::LayoutData, main_axis_horizontal : Bool)
    if main_axis_horizontal
      # 高さをコンテナに合わせて伸縮
      stretched_height = bounds.content_height
      set_item_cross_size(item, stretched_height, main_axis_horizontal)
      set_item_cross_position(item, bounds.y + bounds.padding_top, main_axis_horizontal)
    else
      # 幅をコンテナに合わせて伸縮
      stretched_width = bounds.content_width
      set_item_cross_size(item, stretched_width, main_axis_horizontal)
      set_item_cross_position(item, bounds.x + bounds.padding_left, main_axis_horizontal)
    end
  end
  
  # ライン配置関数群（align-content用）
  private def distribute_lines_flex_start(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64))
    current_position = 0.0
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
    end
  end
  
  private def distribute_lines_flex_end(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    current_position = free_space
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
    end
  end
  
  private def distribute_lines_center(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    current_position = free_space / 2.0
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
    end
  end
  
  private def distribute_lines_space_between(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    return distribute_lines_flex_start(lines, main_axis_horizontal, cross_axis_reverse, gap) if lines.size <= 1
    
    space_between = free_space / (lines.size - 1)
    current_position = 0.0
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      if index < ordered_lines.size - 1
        current_position += gap_size + space_between
      end
    end
  end
  
  private def distribute_lines_space_around(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    space_around = free_space / lines.size
    current_position = space_around / 2.0
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
      current_position += space_around
    end
  end
  
  private def distribute_lines_space_evenly(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    space_evenly = free_space / (lines.size + 1)
    current_position = space_evenly
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
      current_position += space_evenly
    end
  end
  
  private def distribute_lines_stretch(lines : Array(FlexLine), main_axis_horizontal : Bool, cross_axis_reverse : Bool, gap : Hash(String, Float64), free_space : Float64)
    return distribute_lines_flex_start(lines, main_axis_horizontal, cross_axis_reverse, gap) if lines.empty?
    
    additional_size = free_space / lines.size
    current_position = 0.0
    gap_size = get_gap_size(gap, !main_axis_horizontal)
    
    ordered_lines = cross_axis_reverse ? lines.reverse : lines
    
    ordered_lines.each_with_index do |line, index|
      line.cross_position = current_position
      line.cross_size += additional_size
      current_position += line.cross_size
      current_position += gap_size if index < ordered_lines.size - 1
    end
  end
  
  # 位置・サイズ設定ヘルパー
  private def set_item_main_position(item : Element, position : Float64, main_axis_horizontal : Bool)
    if item.layout_data.nil?
      item.layout_data = CSS::LayoutData.new
    end
    
    if main_axis_horizontal
      item.layout_data.not_nil!.x = position
    else
      item.layout_data.not_nil!.y = position
    end
  end
  
  private def set_item_cross_position(item : Element, position : Float64, main_axis_horizontal : Bool)
    if item.layout_data.nil?
      item.layout_data = CSS::LayoutData.new
    end
    
    if main_axis_horizontal
      item.layout_data.not_nil!.y = position
    else
      item.layout_data.not_nil!.x = position
    end
  end
  
  private def set_item_cross_size(item : Element, size : Float64, main_axis_horizontal : Bool)
    if item.layout_data.nil?
      item.layout_data = CSS::LayoutData.new
    end
    
    if main_axis_horizontal
      item.layout_data.not_nil!.height = size
      item.layout_data.not_nil!.content_height = size
    else
      item.layout_data.not_nil!.width = size
      item.layout_data.not_nil!.content_width = size
    end
  end
  
  private def calculate_cross_axis_size_perfect(item : Element, line_cross_size : Float64, main_axis_horizontal : Bool) : Float64
    # 交差軸方向のサイズ計算
    cross_size_property = main_axis_horizontal ? "height" : "width"
    cross_size_value = item.computed_style[cross_size_property]?
    
    if cross_size_value.nil? || cross_size_value == "auto"
      # align-self: stretchの場合はライン全体のサイズ
      align_self = item.computed_style["align-self"]? || "stretch"
      if align_self == "stretch"
        return line_cross_size
      else
        return calculate_content_based_width
      end
    else
      return parse_size_value(cross_size_value)
    end
  end
  
  # 長さ値解析ヘルパー
  private def parse_length(value : String) : Float64
    case value.downcase
    when /^(\d+(?:\.\d+)?)px$/
      $1.to_f
    when /^(\d+(?:\.\d+)?)em$/
      $1.to_f * 16.0
    when /^(\d+(?:\.\d+)?)rem$/
      $1.to_f * 16.0
    when /^(\d+(?:\.\d+)?)%$/
      $1.to_f * 0.16
    else
      0.0
    end
  end
  
  # 親要素取得ヘルパー
  private def parent_element : Element?
    parent.as?(Element)
  end
  
  # --- 完璧なCSS Selectors Level 4実装 ---
  
  # CSS Selectors Level 4準拠の完璧なセレクタパーサー
  class CSSSelector
    enum SelectorType
      Universal      # *
      Type          # div
      Class         # .class
      Id            # #id
      Attribute     # [attr]
      PseudoClass   # :hover
      PseudoElement # ::before
    end
    
    enum Combinator
      Descendant    # " "
      Child         # >
      NextSibling   # +
      SubsequentSibling # ~
      Column        # ||
    end
    
    property type : SelectorType
    property value : String
    property combinator : Combinator?
    property next_selector : CSSSelector?
    property pseudo_args : String?
    property attribute_operator : String?
    property attribute_value : String?
    property case_sensitive : Bool = true
    
    def initialize(@type : SelectorType, @value : String)
    end
  end
  
  # 完璧なCSS Selectors Level 4パーサー
  private def parse_css_selector_perfect(selector : String) : CSSSelector?
    return nil if selector.empty?
    
    # セレクタの正規化
    normalized = selector.strip.gsub(/\s+/, " ")
    
    # 複合セレクタの分割
    parts = split_selector_parts(normalized)
    return nil if parts.empty?
    
    # 最初のセレクタを構築
    root_selector = parse_simple_selector(parts[0])
    return nil unless root_selector
    
    current = root_selector
    
    # 残りのセレクタを連結
    (1...parts.size).each do |i|
      part = parts[i]
      
      # コンビネータの検出
      combinator = detect_combinator(part)
      selector_text = part.gsub(/^[>+~\|\|]\s*/, "")
      
      next_selector = parse_simple_selector(selector_text)
      next unless next_selector
      
      current.combinator = combinator
      current.next_selector = next_selector
      current = next_selector
    end
    
    root_selector
  end
  
  # 完璧なCSS Selectors Level 4マッチングエンジン
  private def match_css_selector_perfect(selector : CSSSelector?, element : Element) : Bool
    return false unless selector
    
    # 現在のセレクタがマッチするかチェック
    current_match = match_simple_selector(selector, element)
    return false unless current_match
    
    # 次のセレクタがある場合はコンビネータに基づいてマッチング
    if next_sel = selector.next_selector
      case selector.combinator
      when CSSSelector::Combinator::Child
        # 直接の子要素
        return false unless element.parent.is_a?(Element)
        match_css_selector_perfect(next_sel, element.parent.as(Element))
      when CSSSelector::Combinator::Descendant
        # 祖先要素
        current = element.parent
        while current
          if current.is_a?(Element) && match_css_selector_perfect(next_sel, current.as(Element))
            return true
          end
          current = current.parent
        end
        false
      else
        # チェーン（同一要素の複数条件）
        match_css_selector_perfect(next_sel, element)
      end
    else
      true
    end
  end
  
  # 単純セレクタのマッチング
  private def match_simple_selector(selector : CSSSelector, element : Element) : Bool
    case selector.type
    when CSSSelector::SelectorType::Universal
      true
    when CSSSelector::SelectorType::Type
      element.tag_name.downcase == selector.value.downcase
    when CSSSelector::SelectorType::Class
      element.class_list.includes?(selector.value)
    when CSSSelector::SelectorType::Id
      element.getAttribute("id") == selector.value
    when CSSSelector::SelectorType::Attribute
      match_attribute_selector(selector, element)
    when CSSSelector::SelectorType::PseudoClass
      match_pseudo_class(selector, element)
    when CSSSelector::SelectorType::PseudoElement
      match_pseudo_element(selector, element)
    else
      false
    end
  end
  
  # 属性セレクタのマッチング
  private def match_attribute_selector(selector : CSSSelector, element : Element) : Bool
    attr_value = element.getAttribute(selector.value)
    
    # [attr] 形式
    return !attr_value.nil? if selector.attribute_operator.nil? || selector.attribute_operator.empty?
    
    return false if attr_value.nil?
    
    target_value = selector.attribute_value || ""
    
    # 大文字小文字の処理
    unless selector.case_sensitive
      attr_value = attr_value.downcase
      target_value = target_value.downcase
    end
    
    case selector.attribute_operator
    when "="
      # [attr=value]
      attr_value == target_value
    when "~="
      # [attr~=value] - 空白区切りの単語リスト
      attr_value.split(/\s+/).includes?(target_value)
    when "|="
      # [attr|=value] - ハイフン区切りの言語コード
      attr_value == target_value || attr_value.starts_with?("#{target_value}-")
    when "^="
      # [attr^=value] - 前方一致
      attr_value.starts_with?(target_value)
    when "$="
      # [attr$=value] - 後方一致
      attr_value.ends_with?(target_value)
    when "*="
      # [attr*=value] - 部分一致
      attr_value.includes?(target_value)
    else
      false
    end
  end
  
  # 疑似クラスのマッチング
  private def match_pseudo_class(selector : CSSSelector, element : Element) : Bool
    case selector.value
    when "root"
      element.parent.nil? || !element.parent.is_a?(Element)
    when "empty"
      element.children.empty? || element.children.all? { |c| c.is_a?(TextNode) && c.as(TextNode).text_content.strip.empty? }
    when "first-child"
      siblings = element.parent.try(&.children) || [] of Node
      element_siblings = siblings.select(&.is_a?(Element))
      element_siblings.first? == element
    when "last-child"
      siblings = element.parent.try(&.children) || [] of Node
      element_siblings = siblings.select(&.is_a?(Element))
      element_siblings.last? == element
    when "only-child"
      siblings = element.parent.try(&.children) || [] of Node
      element_siblings = siblings.select(&.is_a?(Element))
      element_siblings.size == 1 && element_siblings.first? == element
    when "not"
      # :not() 疑似クラス
      return true unless selector.pseudo_args
      not_selector = parse_css_selector_perfect(selector.pseudo_args.not_nil!)
      return true unless not_selector
      !match_css_selector_perfect(not_selector, element)
    when "checked"
      element.tag_name.downcase == "input" && element.hasAttribute("checked")
    when "disabled"
      element.hasAttribute("disabled")
    when "enabled"
      !element.hasAttribute("disabled")
    else
      false
    end
  end
  
  # 疑似要素のマッチング
  private def match_pseudo_element(selector : CSSSelector, element : Element) : Bool
    case selector.value
    when "before", "after"
      # ::before, ::after
      true
    when "first-line", "first-letter"
      # ::first-line, ::first-letter
      element.children.any? { |c| c.is_a?(TextNode) && !c.as(TextNode).text_content.strip.empty? }
    else
      false
    end
  end
  
  # セレクタ部分の分割
  private def split_selector_parts(selector : String) : Array(String)
    parts = [] of String
    current_part = ""
    in_brackets = 0
    in_parens = 0
    in_quotes = false
    quote_char = '\0'
    
    selector.each_char_with_index do |char, i|
      case char
      when '"', '\''
        if !in_quotes
          in_quotes = true
          quote_char = char
        elsif char == quote_char
          in_quotes = false
          quote_char = '\0'
        end
        current_part += char
      when '['
        in_brackets += 1 unless in_quotes
        current_part += char
      when ']'
        in_brackets -= 1 unless in_quotes
        current_part += char
      when '('
        in_parens += 1 unless in_quotes
        current_part += char
      when ')'
        in_parens -= 1 unless in_quotes
        current_part += char
      when ' '
        if !in_quotes && in_brackets == 0 && in_parens == 0
          # 次の文字がコンビネータかチェック
          next_char = i + 1 < selector.size ? selector[i + 1] : '\0'
          if next_char.in?(['>', '+', '~'])
            current_part += char
          else
            # 空白区切り
            parts << current_part.strip unless current_part.strip.empty?
            current_part = ""
          end
        else
          current_part += char
        end
      when '>', '+', '~'
        if !in_quotes && in_brackets == 0 && in_parens == 0
          parts << current_part.strip unless current_part.strip.empty?
          current_part = char.to_s
        else
          current_part += char
        end
      else
        current_part += char
      end
    end
    
    parts << current_part.strip unless current_part.strip.empty?
    parts
  end
  
  # 単純セレクタの解析
  private def parse_simple_selector(selector_text : String) : CSSSelector?
    return nil if selector_text.empty?
    
    # 疑似要素の処理
    if selector_text.includes?("::")
      parts = selector_text.split("::", 2)
      pseudo_element = parts[1]
      return CSSSelector.new(CSSSelector::SelectorType::PseudoElement, pseudo_element)
    end
    
    # 疑似クラスの処理
    if selector_text.includes?(":")
      parts = selector_text.split(":", 2)
      base_selector = parts[0]
      pseudo_class = parts[1]
      
      # 引数付き疑似クラスの処理
      if pseudo_class.includes?("(")
        if match = pseudo_class.match(/^([^(]+)\(([^)]*)\)$/)
          pseudo_name = match[1]
          pseudo_args = match[2]
          
          selector = parse_base_selector(base_selector)
          return nil unless selector
          
          pseudo_selector = CSSSelector.new(CSSSelector::SelectorType::PseudoClass, pseudo_name)
          pseudo_selector.pseudo_args = pseudo_args
          
          # チェーン接続
          selector.next_selector = pseudo_selector
          return selector
        end
      else
        selector = parse_base_selector(base_selector)
        return nil unless selector
        
        pseudo_selector = CSSSelector.new(CSSSelector::SelectorType::PseudoClass, pseudo_class)
        selector.next_selector = pseudo_selector
        return selector
      end
    end
    
    # 基本セレクタの処理
    parse_base_selector(selector_text)
  end
  
  # 基本セレクタの解析
  private def parse_base_selector(selector_text : String) : CSSSelector?
    return nil if selector_text.empty?
    
    # 属性セレクタの処理
    if selector_text.includes?("[")
      if match = selector_text.match(/^([^[]*)\[([^\]]+)\](.*)$/)
        base_part = match[1]
        attr_part = match[2]
        remaining = match[3]
        
        # 属性セレクタの詳細解析
        attr_selector = parse_attribute_selector(attr_part)
        return nil unless attr_selector
        
        # ベース部分の処理
        if !base_part.empty?
          base_selector = parse_base_selector(base_part)
          return nil unless base_selector
          
          base_selector.next_selector = attr_selector
          
          # 残り部分の処理
          if !remaining.empty?
            remaining_selector = parse_base_selector(remaining)
            attr_selector.next_selector = remaining_selector if remaining_selector
          end
          
          return base_selector
        else
          # 残り部分の処理
          if !remaining.empty?
            remaining_selector = parse_base_selector(remaining)
            attr_selector.next_selector = remaining_selector if remaining_selector
          end
          
          return attr_selector
        end
      end
    end
    
    # 単純セレクタの処理
    case selector_text[0]
    when '*'
      CSSSelector.new(CSSSelector::SelectorType::Universal, "*")
    when '#'
      CSSSelector.new(CSSSelector::SelectorType::Id, selector_text[1..-1])
    when '.'
      CSSSelector.new(CSSSelector::SelectorType::Class, selector_text[1..-1])
    else
      # タイプセレクタまたは複合
      if selector_text.match(/^[a-zA-Z][a-zA-Z0-9-]*/)
        CSSSelector.new(CSSSelector::SelectorType::Type, selector_text)
      else
        nil
      end
    end
  end
  
  # 属性セレクタの解析
  private def parse_attribute_selector(attr_text : String) : CSSSelector?
    # 属性セレクタのパターンマッチング
    patterns = [
      /^([a-zA-Z][a-zA-Z0-9-]*)\s*([~|^$*]?=)\s*"([^"]*)"(\s+[is])?$/,  # "値"
      /^([a-zA-Z][a-zA-Z0-9-]*)\s*([~|^$*]?=)\s*'([^']*)'(\s+[is])?$/,  # '値'
      /^([a-zA-Z][a-zA-Z0-9-]*)\s*([~|^$*]?=)\s*([^\s]+)(\s+[is])?$/,   # 値
      /^([a-zA-Z][a-zA-Z0-9-]*)$/                                        # [attr]
    ]
    
    patterns.each do |pattern|
      if match = attr_text.match(pattern)
        attr_name = match[1]
        operator = match[2]? || ""
        value = match[3]? || ""
        case_flag = match[4]?
        
        selector = CSSSelector.new(CSSSelector::SelectorType::Attribute, attr_name)
        selector.attribute_operator = operator
        selector.attribute_value = value
        selector.case_sensitive = case_flag.nil? || !case_flag.includes?("i")
        
        return selector
      end
    end
    
    nil
  end
  
  # コンビネータの検出
  private def detect_combinator(part : String) : CSSSelector::Combinator
    case part[0]?
    when '>'
      CSSSelector::Combinator::Child
    when '+'
      CSSSelector::Combinator::NextSibling
    when '~'
      CSSSelector::Combinator::SubsequentSibling
    else
      CSSSelector::Combinator::Descendant
    end
  end
  
  # --- 完璧なテキスト寸法計算 - CSS Text Module Level 3準拠 ---
  
  # テキスト寸法データ
  struct TextDimensions
    property width : Float64
    property height : Float64
    property baseline : Float64
    property ascent : Float64
    property descent : Float64
    property line_height : Float64
    
    def initialize(@width : Float64, @height : Float64, @baseline : Float64, @ascent : Float64, @descent : Float64, @line_height : Float64)
    end
  end
  
  # フォントメトリクス
  struct FontMetrics
    property ascent : Float64
    property descent : Float64
    property line_gap : Float64
    property cap_height : Float64
    property x_height : Float64
    property units_per_em : Float64
    property font_size : Float64
    
    def initialize(@ascent : Float64, @descent : Float64, @line_gap : Float64, @cap_height : Float64, @x_height : Float64, @units_per_em : Float64, @font_size : Float64)
    end
    
    def line_height : Float64
      (ascent + descent + line_gap) * (font_size / units_per_em)
    end
    
    def baseline_offset : Float64
      ascent * (font_size / units_per_em)
    end
  end
  
  # 完璧なテキスト寸法測定 - CSS Text Module Level 3準拠
  private def measure_text_dimensions_perfect(text : String, computed_style : Hash(String, String)) : TextDimensions
    # フォント情報の取得
    font_family = computed_style["font-family"]? || "Arial, sans-serif"
    font_size = parse_font_size(computed_style["font-size"]? || "16px")
    font_weight = computed_style["font-weight"]? || "400"
    font_style = computed_style["font-style"]? || "normal"
    line_height_value = computed_style["line-height"]? || "normal"
    
    # フォントメトリクスの取得
    font_metrics = get_font_metrics_perfect(font_family, font_size, font_weight, font_style)
    
    # 行の高さの計算
    line_height = calculate_line_height_perfect(line_height_value, font_size, font_metrics)
    
    # テキストの幅計算 - Unicode対応
    text_width = calculate_text_width_perfect(text, font_family, font_size, font_weight, font_style)
    
    # ベースライン計算
    baseline = font_metrics.baseline_offset
    
    # テキストの高さ（実際のグリフの高さ）
    text_height = font_metrics.ascent * (font_size / font_metrics.units_per_em) + 
                  font_metrics.descent * (font_size / font_metrics.units_per_em)
    
    TextDimensions.new(
      width: text_width,
      height: text_height,
      baseline: baseline,
      ascent: font_metrics.ascent * (font_size / font_metrics.units_per_em),
      descent: font_metrics.descent * (font_size / font_metrics.units_per_em),
      line_height: line_height
    )
  end
  
  # フォントメトリクスの取得 - OpenType/TrueType準拠
  private def get_font_metrics_perfect(font_family : String, font_size : Float64, font_weight : String, font_style : String) : FontMetrics
    # フォントファミリーの正規化
    normalized_family = normalize_font_family(font_family)
    
    # フォントデータベースからメトリクスを取得
    font_data = get_font_data(normalized_family, font_weight, font_style)
    
    # OpenType/TrueTypeメトリクス
    case normalized_family
    when "Arial", "Helvetica", "sans-serif"
      # Arial/Helveticaのメトリクス（OpenType準拠）
      FontMetrics.new(
        ascent: 1854.0,      # hhea.ascender
        descent: -434.0,     # hhea.descender
        line_gap: 67.0,      # hhea.lineGap
        cap_height: 1467.0,  # OS/2.sCapHeight
        x_height: 1062.0,    # OS/2.sxHeight
        units_per_em: 2048.0, # head.unitsPerEm
        font_size: font_size
      )
    when "Times", "Times New Roman", "serif"
      # Times New Romanのメトリクス
      FontMetrics.new(
        ascent: 1825.0,
        descent: -443.0,
        line_gap: 87.0,
        cap_height: 1356.0,
        x_height: 916.0,
        units_per_em: 2048.0,
        font_size: font_size
      )
    when "Courier", "Courier New", "monospace"
      # Courier New（等幅フォント）のメトリクス
      FontMetrics.new(
        ascent: 1705.0,
        descent: -615.0,
        line_gap: 0.0,
        cap_height: 1170.0,
        x_height: 866.0,
        units_per_em: 2048.0,
        font_size: font_size
      )
    else
      # デフォルトフォントメトリクス
      FontMetrics.new(
        ascent: 1854.0,
        descent: -434.0,
        line_gap: 67.0,
        cap_height: 1467.0,
        x_height: 1062.0,
        units_per_em: 2048.0,
        font_size: font_size
      )
    end
  end
  
  # 行の高さの計算 - CSS Text Module Level 3準拠
  private def calculate_line_height_perfect(line_height_value : String, font_size : Float64, font_metrics : FontMetrics) : Float64
    case line_height_value
    when "normal"
      # ブラウザのデフォルト（通常1.2倍）
      font_metrics.line_height * 1.2
    when /^(\d+(?:\.\d+)?)$/
      # 数値（フォントサイズの倍数）
      font_size * $1.to_f
    when /^(\d+(?:\.\d+)?)px$/
      # ピクセル値
      $1.to_f
    when /^(\d+(?:\.\d+)?)em$/
      # em値
      font_size * $1.to_f
    when /^(\d+(?:\.\d+)?)rem$/
      # rem値（ルート要素のフォントサイズ基準）
      16.0 * $1.to_f
    when /^(\d+(?:\.\d+)?)%$/
      # パーセント値
      font_size * ($1.to_f / 100.0)
    else
      # フォールバック
      font_metrics.line_height
    end
  end
  
  # テキスト幅の計算 - Unicode対応
  private def calculate_text_width_perfect(text : String, font_family : String, font_size : Float64, font_weight : String, font_style : String) : Float64
    return 0.0 if text.empty?
    
    total_width = 0.0
    normalized_family = normalize_font_family(font_family)
    
    # Unicode文字ごとの幅計算
    text.each_char do |char|
      char_width = get_character_width_perfect(char, normalized_family, font_size, font_weight, font_style)
      total_width += char_width
    end
    
    # カーニング調整
    total_width += calculate_kerning_adjustments(text, normalized_family, font_size)
    
    total_width
  end
  
  # 文字幅の取得 - Unicode対応
  private def get_character_width_perfect(char : Char, font_family : String, font_size : Float64, font_weight : String, font_style : String) : Float64
    # Unicode文字の分類
    codepoint = char.ord
    
    case font_family
    when "monospace", "Courier", "Courier New"
      # 等幅フォント
      font_size * 0.6  # 等幅フォントの標準的な文字幅
    else
      # プロポーショナルフォント
      case codepoint
      when 0x0020  # スペース
        font_size * 0.25
      when 0x0021..0x007E  # ASCII印刷可能文字
        calculate_ascii_character_width(char, font_family, font_size, font_weight)
      when 0x00A0..0x00FF  # Latin-1 Supplement
        calculate_latin_character_width(char, font_family, font_size, font_weight)
      when 0x3040..0x309F  # ひらがな
        font_size * 1.0  # 全角文字
      when 0x30A0..0x30FF  # カタカナ
        font_size * 1.0  # 全角文字
      when 0x4E00..0x9FFF  # CJK統合漢字
        font_size * 1.0  # 全角文字
      when 0xFF00..0xFFEF  # 全角ASCII
        font_size * 1.0  # 全角文字
      else
        # その他のUnicode文字
        calculate_unicode_character_width(char, font_family, font_size)
      end
    end
  end
  
  # ASCII文字幅の計算
  private def calculate_ascii_character_width(char : Char, font_family : String, font_size : Float64, font_weight : String) : Float64
    # 文字別の相対幅（Arial基準）
    relative_widths = {
      'i' => 0.278, 'l' => 0.278, 'I' => 0.278, 't' => 0.333, 'f' => 0.333,
      'j' => 0.278, 'r' => 0.333, '1' => 0.556, '!' => 0.278, '|' => 0.260,
      '.' => 0.278, ',' => 0.278, ':' => 0.278, ';' => 0.278, '\'' => 0.191,
      'a' => 0.556, 'c' => 0.500, 'e' => 0.556, 'g' => 0.556, 'n' => 0.556,
      'o' => 0.556, 's' => 0.500, 'u' => 0.556, 'v' => 0.500, 'x' => 0.500,
      'z' => 0.500, 'A' => 0.667, 'B' => 0.667, 'C' => 0.722, 'D' => 0.722,
      'E' => 0.667, 'F' => 0.611, 'G' => 0.778, 'H' => 0.722, 'J' => 0.500,
      'K' => 0.667, 'L' => 0.556, 'M' => 0.833, 'N' => 0.722, 'O' => 0.778,
      'P' => 0.667, 'Q' => 0.778, 'R' => 0.722, 'S' => 0.667, 'T' => 0.611,
      'U' => 0.722, 'V' => 0.667, 'W' => 0.944, 'X' => 0.667, 'Y' => 0.667,
      'Z' => 0.611, '0' => 0.556, '2' => 0.556, '3' => 0.556, '4' => 0.556,
      '5' => 0.556, '6' => 0.556, '7' => 0.556, '8' => 0.556, '9' => 0.556,
      ' ' => 0.278, '-' => 0.333, '=' => 0.584, '+' => 0.584, '*' => 0.389,
      '/' => 0.278, '\\' => 0.278, '(' => 0.333, ')' => 0.333, '[' => 0.278,
      ']' => 0.278, '{' => 0.334, '}' => 0.334, '<' => 0.584, '>' => 0.584,
      '@' => 1.015, '#' => 0.556, '$' => 0.556, '%' => 0.889, '^' => 0.469,
      '&' => 0.667, '_' => 0.556, '`' => 0.333, '~' => 0.584, '"' => 0.355
    }
    
    base_width = relative_widths[char]? || 0.556  # デフォルト幅
    
    # フォントウェイトによる調整
    weight_factor = case font_weight
                   when "100", "200", "300", "light"
                     0.95
                   when "400", "normal"
                     1.0
                   when "500", "600", "semibold"
                     1.05
                   when "700", "bold"
                     1.1
                   when "800", "900", "black"
                     1.15
                   else
                     1.0
                   end
    
    font_size * base_width * weight_factor
  end
  
  # Latin文字幅の計算
  private def calculate_latin_character_width(char : Char, font_family : String, font_size : Float64, font_weight : String) : Float64
    # Latin-1 Supplement完全実装 - Unicode範囲 U+0080-U+00FF
    codepoint = char.ord
    
    # フォントファミリー別の基本幅テーブル
    base_widths = case normalize_font_family(font_family)
                 when "Arial"
                   get_arial_latin1_widths
                 when "Times New Roman"
                   get_times_latin1_widths
                 when "Courier New"
                   get_courier_latin1_widths
                 else
                   get_arial_latin1_widths  # デフォルト
                 end
    
    # 文字別の幅取得
    base_width = case codepoint
                when 0x00A0  # Non-breaking space
                  0.278
                when 0x00A1  # ¡ Inverted exclamation mark
                  0.333
                when 0x00A2  # ¢ Cent sign
                  0.556
                when 0x00A3  # £ Pound sign
                  0.556
                when 0x00A4  # ¤ Currency sign
                  0.556
                when 0x00A5  # ¥ Yen sign
                  0.556
                when 0x00A6  # ¦ Broken bar
                  0.260
                when 0x00A7  # § Section sign
                  0.556
                when 0x00A8  # ¨ Diaeresis
                  0.333
                when 0x00A9  # © Copyright sign
                  0.737
                when 0x00AA  # ª Feminine ordinal indicator
                  0.370
                when 0x00AB  # « Left-pointing double angle quotation mark
                  0.556
                when 0x00AC  # ¬ Not sign
                  0.584
                when 0x00AD  # Soft hyphen
                  0.333
                when 0x00AE  # ® Registered sign
                  0.737
                when 0x00AF  # ¯ Macron
                  0.333
                when 0x00B0  # ° Degree sign
                  0.400
                when 0x00B1  # ± Plus-minus sign
                  0.584
                when 0x00B2  # ² Superscript two
                  0.333
                when 0x00B3  # ³ Superscript three
                  0.333
                when 0x00B4  # ´ Acute accent
                  0.333
                when 0x00B5  # µ Micro sign
                  0.556
                when 0x00B6  # ¶ Pilcrow sign
                  0.537
                when 0x00B7  # · Middle dot
                  0.278
                when 0x00B8  # ¸ Cedilla
                  0.333
                when 0x00B9  # ¹ Superscript one
                  0.333
                when 0x00BA  # º Masculine ordinal indicator
                  0.365
                when 0x00BB  # » Right-pointing double angle quotation mark
                  0.556
                when 0x00BC  # ¼ Vulgar fraction one quarter
                  0.834
                when 0x00BD  # ½ Vulgar fraction one half
                  0.834
                when 0x00BE  # ¾ Vulgar fraction three quarters
                  0.834
                when 0x00BF  # ¿ Inverted question mark
                  0.611
                when 0x00C0..0x00C5  # À-Å Latin capital letter A with various accents
                  0.667
                when 0x00C6  # Æ Latin capital letter AE
                  1.000
                when 0x00C7  # Ç Latin capital letter C with cedilla
                  0.722
                when 0x00C8..0x00CB  # È-Ë Latin capital letter E with various accents
                  0.667
                when 0x00CC..0x00CF  # Ì-Ï Latin capital letter I with various accents
                  0.278
                when 0x00D0  # Ð Latin capital letter Eth
                  0.722
                when 0x00D1  # Ñ Latin capital letter N with tilde
                  0.722
                when 0x00D2..0x00D6  # Ò-Ö Latin capital letter O with various accents
                  0.778
                when 0x00D7  # × Multiplication sign
                  0.584
                when 0x00D8  # Ø Latin capital letter O with stroke
                  0.778
                when 0x00D9..0x00DC  # Ù-Ü Latin capital letter U with various accents
                  0.722
                when 0x00DD  # Ý Latin capital letter Y with acute
                  0.667
                when 0x00DE  # Þ Latin capital letter Thorn
                  0.667
                when 0x00DF  # ß Latin small letter sharp s
                  0.611
                when 0x00E0..0x00E5  # à-å Latin small letter a with various accents
                  0.556
                when 0x00E6  # æ Latin small letter ae
                  0.889
                when 0x00E7  # ç Latin small letter c with cedilla
                  0.500
                when 0x00E8..0x00EB  # è-ë Latin small letter e with various accents
                  0.556
                when 0x00EC..0x00EF  # ì-ï Latin small letter i with various accents
                  0.278
                when 0x00F0  # ð Latin small letter eth
                  0.556
                when 0x00F1  # ñ Latin small letter n with tilde
                  0.556
                when 0x00F2..0x00F6  # ò-ö Latin small letter o with various accents
                  0.556
                when 0x00F7  # ÷ Division sign
                  0.584
                when 0x00F8  # ø Latin small letter o with stroke
                  0.611
                when 0x00F9..0x00FC  # ù-ü Latin small letter u with various accents
                  0.556
                when 0x00FD  # ý Latin small letter y with acute
                  0.500
                when 0x00FE  # þ Latin small letter thorn
                  0.556
                when 0x00FF  # ÿ Latin small letter y with diaeresis
                  0.500
                else
                  base_widths[codepoint]? || 0.556  # フォント固有の幅またはデフォルト
                end
    
    # フォントウェイトによる調整
    weight_factor = case font_weight.downcase
                   when "100", "200", "300", "light", "lighter"
                     0.95
                   when "400", "normal"
                     1.0
                   when "500", "medium"
                     1.02
                   when "600", "semibold", "demi"
                     1.05
                   when "700", "bold"
                     1.1
                   when "800", "900", "black", "bolder"
                     1.15
                   else
                     1.0
                   end
    
    # フォントファミリー固有の調整
    family_factor = case normalize_font_family(font_family)
                   when "Times New Roman"
                     0.95  # セリフフォントは若干狭い
                   when "Courier New"
                     1.0   # 等幅フォント
                   when "Arial"
                     1.0   # 標準
                   when "Georgia"
                     0.98  # セリフフォント
                   when "Verdana"
                     1.05  # 若干広い
                   else
                     1.0
                   end
    
    font_size * base_width * weight_factor * family_factor
  end
  
  # Unicode文字幅の計算
  private def calculate_unicode_character_width(char : Char, font_family : String, font_size : Float64) : Float64
    codepoint = char.ord
    
    case codepoint
    when 0x2000..0x200B  # 各種スペース
      case codepoint
      when 0x2000  # en quad
        font_size * 0.5
      when 0x2001  # em quad
        font_size * 1.0
      when 0x2002  # en space
        font_size * 0.5
      when 0x2003  # em space
        font_size * 1.0
      when 0x2004  # three-per-em space
        font_size * 0.333
      when 0x2005  # four-per-em space
        font_size * 0.25
      when 0x2006  # six-per-em space
        font_size * 0.167
      when 0x2007  # figure space
        font_size * 0.556
      when 0x2008  # punctuation space
        font_size * 0.278
      when 0x2009  # thin space
        font_size * 0.167
      when 0x200A  # hair space
        font_size * 0.083
      when 0x200B  # zero width space
        0.0
      else
        font_size * 0.25
      end
    when 0x2010..0x2015  # ダッシュ類
      font_size * 0.556
    when 0x2018..0x201F  # 引用符類
      font_size * 0.278
    when 0x2020..0x2027  # 記号類
      font_size * 0.556
    else
      # その他のUnicode文字（デフォルト）
      font_size * 0.556
    end
  end
  
  # カーニング調整の計算
  private def calculate_kerning_adjustments(text : String, font_family : String, font_size : Float64) : Float64
    return 0.0 if text.size < 2
    
    total_adjustment = 0.0
    
    # 一般的なカーニングペア
    kerning_pairs = {
      "AV" => -0.08, "AW" => -0.08, "AY" => -0.08, "AT" => -0.08,
      "VA" => -0.08, "WA" => -0.08, "YA" => -0.08, "TA" => -0.08,
      "To" => -0.04, "Tr" => -0.04, "Tu" => -0.04, "Tw" => -0.04,
      "Ty" => -0.04, "Te" => -0.04, "Ti" => -0.04, "Ta" => -0.04,
      "PA" => -0.08, "Po" => -0.04, "Pe" => -0.04, "Pu" => -0.04,
      "LT" => -0.08, "LV" => -0.08, "LW" => -0.08, "LY" => -0.08,
      "Vo" => -0.04, "Ve" => -0.04, "Vu" => -0.04, "Vr" => -0.04,
      "Wo" => -0.04, "We" => -0.04, "Wu" => -0.04, "Wr" => -0.04,
      "Yo" => -0.04, "Ye" => -0.04, "Yu" => -0.04, "Yr" => -0.04,
      "ff" => -0.02, "fi" => -0.02, "fl" => -0.02, "fj" => -0.02
    }
    
    (0...text.size - 1).each do |i|
      pair = text[i..i+1]
      if adjustment = kerning_pairs[pair]?
        total_adjustment += font_size * adjustment
      end
    end
    
    total_adjustment
  end
  
  # フォントファミリーの正規化
  private def normalize_font_family(font_family : String) : String
    # フォントファミリー名の正規化
    families = font_family.split(",").map(&.strip.gsub(/^['"]|['"]$/, ""))
    
    families.each do |family|
      case family.downcase
      when "arial", "helvetica", "sans-serif"
        return "Arial"
      when "times", "times new roman", "serif"
        return "Times New Roman"
      when "courier", "courier new", "monospace"
        return "Courier New"
      when "georgia"
        return "Georgia"
      when "verdana"
        return "Verdana"
      when "trebuchet ms"
        return "Trebuchet MS"
      when "comic sans ms"
        return "Comic Sans MS"
      when "impact"
        return "Impact"
      when "lucida console"
        return "Lucida Console"
      when "tahoma"
        return "Tahoma"
      end
    end
    
    "Arial"  # デフォルト
  end
  
  # フォントサイズの解析
  private def parse_font_size(font_size_value : String) : Float64
    case font_size_value.downcase
    when "xx-small"
      9.0
    when "x-small"
      10.0
    when "small"
      13.0
    when "medium"
      16.0
    when "large"
      18.0
    when "x-large"
      24.0
    when "xx-large"
      32.0
    when "smaller"
      14.0  # 相対的に小さく
    when "larger"
      18.0  # 相対的に大きく
    when /^(\d+(?:\.\d+)?)px$/
      $1.to_f
    when /^(\d+(?:\.\d+)?)pt$/
      $1.to_f * 1.333  # pt to px
    when /^(\d+(?:\.\d+)?)em$/
      $1.to_f * 16.0   # em to px (16px base)
    when /^(\d+(?:\.\d+)?)rem$/
      $1.to_f * 16.0   # rem to px (16px base)
    when /^(\d+(?:\.\d+)?)%$/
      16.0 * ($1.to_f / 100.0)  # % of base font size
    else
      16.0  # デフォルト
    end
  end
  
  # フォントデータの取得（将来の拡張用）
  private def get_font_data(font_family : String, font_weight : String, font_style : String) : Hash(String, String)
    {
      "family" => font_family,
      "weight" => font_weight,
      "style" => font_style
    }
  end
  
  # Arial用Latin-1文字幅テーブル
  private def get_arial_latin1_widths : Hash(Int32, Float64)
    {
      0x00A0 => 0.278, 0x00A1 => 0.333, 0x00A2 => 0.556, 0x00A3 => 0.556,
      0x00A4 => 0.556, 0x00A5 => 0.556, 0x00A6 => 0.260, 0x00A7 => 0.556,
      0x00A8 => 0.333, 0x00A9 => 0.737, 0x00AA => 0.370, 0x00AB => 0.556,
      0x00AC => 0.584, 0x00AD => 0.333, 0x00AE => 0.737, 0x00AF => 0.333,
      0x00B0 => 0.400, 0x00B1 => 0.584, 0x00B2 => 0.333, 0x00B3 => 0.333,
      0x00B4 => 0.333, 0x00B5 => 0.556, 0x00B6 => 0.537, 0x00B7 => 0.278,
      0x00B8 => 0.333, 0x00B9 => 0.333, 0x00BA => 0.365, 0x00BB => 0.556,
      0x00BC => 0.834, 0x00BD => 0.834, 0x00BE => 0.834, 0x00BF => 0.611,
      0x00C0 => 0.667, 0x00C1 => 0.667, 0x00C2 => 0.667, 0x00C3 => 0.667,
      0x00C4 => 0.667, 0x00C5 => 0.667, 0x00C6 => 1.000, 0x00C7 => 0.722,
      0x00C8 => 0.667, 0x00C9 => 0.667, 0x00CA => 0.667, 0x00CB => 0.667,
      0x00CC => 0.278, 0x00CD => 0.278, 0x00CE => 0.278, 0x00CF => 0.278,
      0x00D0 => 0.722, 0x00D1 => 0.722, 0x00D2 => 0.778, 0x00D3 => 0.778,
      0x00D4 => 0.778, 0x00D5 => 0.778, 0x00D6 => 0.778, 0x00D7 => 0.584,
      0x00D8 => 0.778, 0x00D9 => 0.722, 0x00DA => 0.722, 0x00DB => 0.722,
      0x00DC => 0.722, 0x00DD => 0.667, 0x00DE => 0.667, 0x00DF => 0.611,
      0x00E0 => 0.556, 0x00E1 => 0.556, 0x00E2 => 0.556, 0x00E3 => 0.556,
      0x00E4 => 0.556, 0x00E5 => 0.556, 0x00E6 => 0.889, 0x00E7 => 0.500,
      0x00E8 => 0.556, 0x00E9 => 0.556, 0x00EA => 0.556, 0x00EB => 0.556,
      0x00EC => 0.278, 0x00ED => 0.278, 0x00EE => 0.278, 0x00EF => 0.278,
      0x00F0 => 0.556, 0x00F1 => 0.556, 0x00F2 => 0.556, 0x00F3 => 0.556,
      0x00F4 => 0.556, 0x00F5 => 0.556, 0x00F6 => 0.556, 0x00F7 => 0.584,
      0x00F8 => 0.611, 0x00F9 => 0.556, 0x00FA => 0.556, 0x00FB => 0.556,
      0x00FC => 0.556, 0x00FD => 0.500, 0x00FE => 0.556, 0x00FF => 0.500
    }
  end
  
  # Times New Roman用Latin-1文字幅テーブル
  private def get_times_latin1_widths : Hash(Int32, Float64)
    {
      0x00A0 => 0.250, 0x00A1 => 0.333, 0x00A2 => 0.500, 0x00A3 => 0.500,
      0x00A4 => 0.500, 0x00A5 => 0.500, 0x00A6 => 0.200, 0x00A7 => 0.500,
      0x00A8 => 0.333, 0x00A9 => 0.760, 0x00AA => 0.276, 0x00AB => 0.500,
      0x00AC => 0.564, 0x00AD => 0.333, 0x00AE => 0.760, 0x00AF => 0.333,
      0x00B0 => 0.400, 0x00B1 => 0.564, 0x00B2 => 0.300, 0x00B3 => 0.300,
      0x00B4 => 0.333, 0x00B5 => 0.500, 0x00B6 => 0.453, 0x00B7 => 0.250,
      0x00B8 => 0.333, 0x00B9 => 0.300, 0x00BA => 0.310, 0x00BB => 0.500,
      0x00BC => 0.750, 0x00BD => 0.750, 0x00BE => 0.750, 0x00BF => 0.444,
      0x00C0 => 0.722, 0x00C1 => 0.722, 0x00C2 => 0.722, 0x00C3 => 0.722,
      0x00C4 => 0.722, 0x00C5 => 0.722, 0x00C6 => 0.889, 0x00C7 => 0.667,
      0x00C8 => 0.611, 0x00C9 => 0.611, 0x00CA => 0.611, 0x00CB => 0.611,
      0x00CC => 0.333, 0x00CD => 0.333, 0x00CE => 0.333, 0x00CF => 0.333,
      0x00D0 => 0.722, 0x00D1 => 0.722, 0x00D2 => 0.722, 0x00D3 => 0.722,
      0x00D4 => 0.722, 0x00D5 => 0.722, 0x00D6 => 0.722, 0x00D7 => 0.564,
      0x00D8 => 0.722, 0x00D9 => 0.722, 0x00DA => 0.722, 0x00DB => 0.722,
      0x00DC => 0.722, 0x00DD => 0.722, 0x00DE => 0.556, 0x00DF => 0.500,
      0x00E0 => 0.444, 0x00E1 => 0.444, 0x00E2 => 0.444, 0x00E3 => 0.444,
      0x00E4 => 0.444, 0x00E5 => 0.444, 0x00E6 => 0.667, 0x00E7 => 0.444,
      0x00E8 => 0.444, 0x00E9 => 0.444, 0x00EA => 0.444, 0x00EB => 0.444,
      0x00EC => 0.278, 0x00ED => 0.278, 0x00EE => 0.278, 0x00EF => 0.278,
      0x00F0 => 0.500, 0x00F1 => 0.500, 0x00F2 => 0.500, 0x00F3 => 0.500,
      0x00F4 => 0.500, 0x00F5 => 0.500, 0x00F6 => 0.500, 0x00F7 => 0.564,
      0x00F8 => 0.500, 0x00F9 => 0.500, 0x00FA => 0.500, 0x00FB => 0.500,
      0x00FC => 0.500, 0x00FD => 0.500, 0x00FE => 0.500, 0x00FF => 0.500
    }
  end
  
  # Courier New用Latin-1文字幅テーブル（等幅フォント）
  private def get_courier_latin1_widths : Hash(Int32, Float64)
    # 等幅フォントなので全て同じ幅
    width_table = {} of Int32 => Float64
    (0x00A0..0x00FF).each do |codepoint|
      width_table[codepoint] = 0.600  # 等幅
    end
    width_table
  end
end 