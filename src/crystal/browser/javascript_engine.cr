require "./config"
require "./dom_manager"
require "uuid"

module QuantumCore
  # JavaScriptエンジンインターフェース
  class JavaScriptEngine
    # JavaScript実行コンテキスト
    class JavaScriptContext
      getter id : String
      getter page : Page?
      getter global_object : JSValue
      getter current_script_url : String?
      
      def initialize(@engine : JavaScriptEngine, @page : Page?)
        @id = UUID.random.to_s
        @global_object = JSValue.new(JSValueType::Object, {} of String => JSValue)
        @current_script_url = nil
      end
      
      # オブジェクトへのプロパティ設定
      def set_property(object : JSValue, name : String, value : JSValue)
        return unless object.type == JSValueType::Object
        
        object.value.as(Hash(String, JSValue))[name] = value
      end
      
      # オブジェクトからのプロパティ取得
      def get_property(object : JSValue, name : String) : JSValue
        return JSValue.undefined unless object.type == JSValueType::Object
        
        if properties = object.value.as?(Hash(String, JSValue))
          properties[name]? || JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      # カレントスクリプトURLの設定
      def set_current_script_url(url : String?)
        @current_script_url = url
      end
      
      # グローバルオブジェクトへのプロパティ設定
      def set_global_property(name : String, value : JSValue)
        set_property(@global_object, name, value)
      end
      
      # グローバルオブジェクトからのプロパティ取得
      def get_global_property(name : String) : JSValue
        get_property(@global_object, name)
      end
    end
    
    # JavaScript値の型
    enum JSValueType
      Undefined
      Null
      Boolean
      Number
      String
      Object
      Function
      Symbol
      BigInt
    end
    
    # JavaScript値
    class JSValue
      getter type : JSValueType
      getter value : String | Bool | Float64 | Int64 | Hash(String, JSValue) | Nil
      
      def initialize(@type : JSValueType, @value = nil)
      end
      
      # 未定義値の作成
      def self.undefined
        self.new(JSValueType::Undefined)
      end
      
      # null値の作成
      def self.null
        self.new(JSValueType::Null)
      end
      
      # 真偽値の作成
      def self.boolean(value : Bool)
        self.new(JSValueType::Boolean, value)
      end
      
      # 数値の作成
      def self.number(value : Float64)
        self.new(JSValueType::Number, value)
      end
      
      # 文字列の作成
      def self.string(value : String)
        self.new(JSValueType::String, value)
      end
      
      # オブジェクトの作成
      def self.object(properties = {} of String => JSValue)
        self.new(JSValueType::Object, properties)
      end
    end
    
    # JavaScript実行エラー
    class JSError
      getter message : String
      getter filename : String?
      getter line : Int32
      getter column : Int32
      getter stack_trace : String?
      
      def initialize(@message : String, @filename : String? = nil, @line : Int32 = 0, @column : Int32 = 0, @stack_trace : String? = nil)
      end
    end
    
    # パースエラーのコールバック型
    alias ParseErrorCallback = Proc(JSError, Nil)
    
    getter config : Config::CoreConfig
    
    def initialize(@config : Config::CoreConfig, @dom_manager : DOMManager)
      @contexts = {} of String => JavaScriptContext
      @parse_error_callbacks = [] of ParseErrorCallback
      
      # Zigの実装からJavaScriptエンジンをロード
      load_js_engine
    end
    
    # エンジンの起動
    def start
      # 必要なリソースの初期化
    end
    
    # エンジンのシャットダウン
    def shutdown
      # コンテキストのクリーンアップ
      @contexts.clear
      
      # リソースの解放
      unload_js_engine
    end
    
    # JavaScript実行コンテキストの作成
    def create_context(page : Page? = nil) : JavaScriptContext
      context = JavaScriptContext.new(self, page)
      
      # コンテキストの初期化
      initialize_context(context)
      
      # コンテキストの登録
      @contexts[context.id] = context
      
      context
    end
    
    # コンテキストのリセット
    def reset_context(context : JavaScriptContext)
      # グローバルオブジェクトをリセット
      context.global_object = JSValue.object
      
      # コンテキストの再初期化
      initialize_context(context)
    end
    
    # JavaScriptの実行
    def execute(context : JavaScriptContext, code : String, filename : String? = nil) : JSValue
      context.set_current_script_url(filename)
      
      begin
        # JavaScriptコードの解析
        ast = parse_js(code, filename)
        
        # ASTの評価
        evaluate_js(context, ast)
      rescue e : JSError
        # エラーの通知
        notify_parse_error(e)
        JSValue.undefined
      ensure
        context.set_current_script_url(nil)
      end
    end
    
    # イベントの発火
    def fire_event(context : JavaScriptContext, target : Element, event_name : String, event_data = {} of String => JSValue)
      # イベントオブジェクトの作成
      event = create_event_object(context, event_name, event_data)
      
      # イベントハンドラーの取得と実行
      handler_name = "on#{event_name.downcase}"
      
      # インラインハンドラー
      if handler_code = target[handler_name]?
        handler_code = "(() => { #{handler_code} }).call(this, event)"
        execute(context, handler_code)
      end
      
      # addEventListener で登録されたハンドラー
      if event_listeners = get_event_listeners(target, event_name)
        event_listeners.each do |listener|
          # リスナーの実行
          call_function(context, listener, [event])
        end
      end
      
      # イベントのバブリング
      unless event_data["bubbles"]? == JSValue.boolean(false)
        if parent = target.parent
          if parent.is_a?(Element)
            fire_event(context, parent, event_name, event_data)
          end
        end
      end
    end
    
    # 要素変更の監視
    def observe_element_changes(context : JavaScriptContext, element : Element, &block)
      # MutationObserverのエミュレート
      observer_id = UUID.random.to_s
      
      # コールバックの登録
      register_mutation_callback(observer_id, block)
      
      # 監視設定
      observe_element(element, observer_id)
    end
    
    # パースエラーコールバックの登録
    def on_parse_error(&callback : ParseErrorCallback)
      @parse_error_callbacks << callback
    end
    
    private def initialize_context(context : JavaScriptContext)
      # グローバルオブジェクトの設定
      setup_global_object(context)
      
      # DOMオブジェクトのバインド
      if page = context.page
        if document = page.document
          bind_document_to_context(context, document)
        end
      end
    end
    
    private def setup_global_object(context : JavaScriptContext)
      # window オブジェクト (グローバルオブジェクトの別名)
      context.set_global_property("window", context.global_object)
      
      # コンソールオブジェクト
      console = JSValue.object
      
      # console.log
      log_fn = create_native_function do |args|
        # コンソール出力の処理
        args_str = args.map { |arg| js_value_to_string(arg) }.join(" ")
        puts "JS Console: #{args_str}"
        JSValue.undefined
      end
      
      context.set_property(console, "log", log_fn)
      context.set_property(console, "info", log_fn)
      context.set_property(console, "warn", log_fn)
      context.set_property(console, "error", log_fn)
      
      context.set_global_property("console", console)
      
      # setTimeout / setInterval
      setTimeout = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::Function && args[1].type == JSValueType::Number
          callback = args[0]
          timeout = args[1].value.as(Float64).to_i
          
          # タイマーIDの生成
          timer_id = register_timer(context, callback, timeout, false)
          
          # タイマーIDを返す
          JSValue.number(timer_id.to_f64)
        else
          JSValue.undefined
        end
      end
      
      setInterval = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::Function && args[1].type == JSValueType::Number
          callback = args[0]
          interval = args[1].value.as(Float64).to_i
          
          # タイマーIDの生成
          timer_id = register_timer(context, callback, interval, true)
          
          # タイマーIDを返す
          JSValue.number(timer_id.to_f64)
        else
          JSValue.undefined
        end
      end
      
      clearTimeout = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::Number
          timer_id = args[0].value.as(Float64).to_i
          
          # タイマーの解除
          clear_timer(timer_id)
          
          JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      clearInterval = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::Number
          timer_id = args[0].value.as(Float64).to_i
          
          # タイマーの解除
          clear_timer(timer_id)
          
          JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      context.set_global_property("setTimeout", setTimeout)
      context.set_global_property("setInterval", setInterval)
      context.set_global_property("clearTimeout", clearTimeout)
      context.set_global_property("clearInterval", clearInterval)
      
      # location オブジェクト
      location = JSValue.object
      
      if page = context.page
        if url = page.url
          uri = URI.parse(url)
          
          context.set_property(location, "href", JSValue.string(url))
          context.set_property(location, "protocol", JSValue.string("#{uri.scheme}:"))
          context.set_property(location, "host", JSValue.string(uri.host.to_s))
          context.set_property(location, "hostname", JSValue.string(uri.host.to_s))
          context.set_property(location, "port", JSValue.string(uri.port ? uri.port.to_s : ""))
          context.set_property(location, "pathname", JSValue.string(uri.path))
          context.set_property(location, "search", JSValue.string(uri.query ? "?#{uri.query}" : ""))
          context.set_property(location, "hash", JSValue.string(uri.fragment ? "##{uri.fragment}" : ""))
          
          # locationのメソッド
          reload = create_native_function do |_args|
            if p = page
              p.reload
            end
            JSValue.undefined
          end
          
          context.set_property(location, "reload", reload)
        end
      end
      
      context.set_global_property("location", location)
    end
    
    private def bind_document_to_context(context : JavaScriptContext, document : Document)
      # documentオブジェクトの作成
      doc_obj = JSValue.object
      
      # document.getElementById
      get_element_by_id = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          id = args[0].value.as(String)
          
          if element = document.query_selector("##{id}")
            wrap_dom_element(context, element)
          else
            JSValue.null
          end
        else
          JSValue.null
        end
      end
      
      # document.querySelector
      query_selector = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          selector = args[0].value.as(String)
          
          if element = document.query_selector(selector)
            wrap_dom_element(context, element)
          else
            JSValue.null
          end
        else
          JSValue.null
        end
      end
      
      # document.querySelectorAll
      query_selector_all = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          selector = args[0].value.as(String)
          
          elements = document.query_selector_all(selector)
          
          # NodeListの作成（配列風オブジェクト）
          node_list = JSValue.object
          
          # 要素を追加
          elements.each_with_index do |element, index|
            context.set_property(node_list, index.to_s, wrap_dom_element(context, element))
          end
          
          # 長さプロパティを設定
          context.set_property(node_list, "length", JSValue.number(elements.size.to_f64))
          
          # forEach メソッドの実装
          for_each = create_native_function do |callback_args|
            if callback_args.size >= 1 && callback_args[0].type == JSValueType::Function
              callback = callback_args[0]
              elements.each_with_index do |element, index|
                # コールバック関数を呼び出し (element, index, nodeList)
                context.call_function(
                  callback,
                  [wrap_dom_element(context, element), JSValue.number(index.to_f64), node_list]
                )
              end
            end
            JSValue.undefined
          end
          context.set_property(node_list, "forEach", for_each)
          
          # item メソッドの実装
          item = create_native_function do |item_args|
            if item_args.size >= 1 && item_args[0].type == JSValueType::Number
              index = item_args[0].value.as(Float64).to_i
              if index >= 0 && index < elements.size
                wrap_dom_element(context, elements[index])
              else
                JSValue.null
              end
            else
              JSValue.null
            end
          end
          context.set_property(node_list, "item", item)
          
          # entries, keys, values メソッドの実装（イテレータ）
          entries = create_native_function do |_|
            iterator = JSValue.object
            current_index = 0
            
            next_method = create_native_function do |_|
              result = JSValue.object
              if current_index < elements.size
                entry = JSValue.array(2)
                context.set_property(entry, "0", JSValue.number(current_index.to_f64))
                context.set_property(entry, "1", wrap_dom_element(context, elements[current_index]))
                context.set_property(result, "value", entry)
                context.set_property(result, "done", JSValue.boolean(false))
                current_index += 1
              else
                context.set_property(result, "done", JSValue.boolean(true))
              end
              result
            end
            
            context.set_property(iterator, "next", next_method)
            iterator
          end
          context.set_property(node_list, "entries", entries)
          
          node_list
        else
          JSValue.null
        end
      end
      
      # documentのプロパティ設定
      context.set_property(doc_obj, "getElementById", get_element_by_id)
      context.set_property(doc_obj, "querySelector", query_selector)
      context.set_property(doc_obj, "querySelectorAll", query_selector_all)
      
      # title プロパティ
      title_getter = create_native_function do |_args|
        JSValue.string(document.title)
      end
      
      title_setter = create_native_function do |args|
        if args.size >= 1
          new_title = js_value_to_string(args[0])
          
          if title_element = document.query_selector("title")
            title_element.text_content = new_title
          else
            # titleタグが存在しない場合は作成
            if head = document.head
              title_element = document.create_element("title")
              title_element.text_content = new_title
              head.append_child(title_element)
            end
          end
        end
        
        JSValue.undefined
      end
      
      # getter/setterの実装
      setup_property_accessor(context, doc_obj, "title", title_getter, title_setter)
      
      # readyState プロパティ
      if page = context.page
        ready_state = case page.load_state
                     when Page::LoadState::Initial, Page::LoadState::Loading
                       "loading"
                     when Page::LoadState::Interactive
                       "interactive"
                     when Page::LoadState::Complete
                       "complete"
                     else
                       "loading"
                     end
        
        context.set_property(doc_obj, "readyState", JSValue.string(ready_state))
        
        # DOMContentLoaded イベント
        if page.load_state >= Page::LoadState::Interactive
          # すでにInteractive状態以上なら、非同期でDOMContentLoadedイベントを発火
          spawn do
            event = document.create_event("DOMContentLoaded")
            document.dispatch_event(event)
          end
        else
          # ページロード状態の変更を監視
          page.on_load_state_change do |new_state|
            if new_state >= Page::LoadState::Interactive
              event = document.create_event("DOMContentLoaded")
              document.dispatch_event(event)
            end
          end
        end
      end
      
      # cookie プロパティの実装
      cookie_getter = create_native_function do |_args|
        if page = context.page
          JSValue.string(page.cookies.to_cookie_string)
        else
          JSValue.string("")
        end
      end
      
      cookie_setter = create_native_function do |args|
        if args.size >= 1 && page = context.page
          cookie_str = js_value_to_string(args[0])
          page.set_cookie(cookie_str)
        end
        JSValue.undefined
      end
      
      setup_property_accessor(context, doc_obj, "cookie", cookie_getter, cookie_setter)
      
      # createElement メソッド
      create_element = create_native_function do |args|
        if args.size >= 1
          tag_name = js_value_to_string(args[0])
          if element = document.create_element(tag_name)
            wrap_dom_element(context, element)
          else
            JSValue.null
          end
        else
          JSValue.null
        end
      end
      
      context.set_property(doc_obj, "createElement", create_element)
      
      # グローバルスコープに document を設定
      context.set_global_property("document", doc_obj)
    end
    
    private def wrap_dom_element(context : JavaScriptContext, element : Element) : JSValue
      # 要素をJavaScriptオブジェクトとしてラップ
      el_obj = JSValue.object
      
      # 基本プロパティ
      context.set_property(el_obj, "tagName", JSValue.string(element.tag_name.upcase))
      context.set_property(el_obj, "id", JSValue.string(element.id || ""))
      
      # className プロパティ
      class_name_getter = create_native_function do |_args|
        JSValue.string(element.class_name || "")
      end
      
      class_name_setter = create_native_function do |args|
        if args.size >= 1
          element.class_name = js_value_to_string(args[0])
        end
        JSValue.undefined
      end
      
      setup_property_accessor(context, el_obj, "className", class_name_getter, class_name_setter)
      
      # classList プロパティ
      class_list = JSValue.object
      
      context.set_property(class_list, "add", create_native_function do |args|
        args.each do |arg|
          if arg.type == JSValueType::String
            element.add_class(arg.value.as(String))
          end
        end
        JSValue.undefined
      end)
      
      context.set_property(class_list, "remove", create_native_function do |args|
        args.each do |arg|
          if arg.type == JSValueType::String
            element.remove_class(arg.value.as(String))
          end
        end
        JSValue.undefined
      end)
      
      context.set_property(class_list, "toggle", create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          class_name = args[0].value.as(String)
          
          if element.has_class?(class_name)
            element.remove_class(class_name)
            JSValue.boolean(false)
          else
            element.add_class(class_name)
            JSValue.boolean(true)
          end
        else
          JSValue.undefined
        end
      end)
      
      context.set_property(class_list, "contains", create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          class_name = args[0].value.as(String)
          JSValue.boolean(element.has_class?(class_name))
        else
          JSValue.boolean(false)
        end
      end)
      
      context.set_property(el_obj, "classList", class_list)
      
      # innerHTML プロパティ
      inner_html_getter = create_native_function do |_args|
        JSValue.string(element.inner_html)
      end
      
      inner_html_setter = create_native_function do |args|
        if args.size >= 1
          element.inner_html = js_value_to_string(args[0])
        end
        JSValue.undefined
      end
      
      setup_property_accessor(context, el_obj, "innerHTML", inner_html_getter, inner_html_setter)
      
      # addEventListener メソッド
      add_event_listener = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::String && args[1].type == JSValueType::Function
          event_name = args[0].value.as(String)
          callback = args[1]
          
          # イベントリスナーの登録
          add_event_listener_to_element(element, event_name, callback)
          
          JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      context.set_property(el_obj, "addEventListener", add_event_listener)
      
      # removeEventListener メソッド
      remove_event_listener = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::String && args[1].type == JSValueType::Function
          event_name = args[0].value.as(String)
          callback = args[1]
          
          # イベントリスナーの削除
          remove_event_listener_from_element(element, event_name, callback)
          
          JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      context.set_property(el_obj, "removeEventListener", remove_event_listener)
      
      # getAttribute/setAttribute/hasAttribute メソッド
      get_attribute = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          name = args[0].value.as(String)
          
          if value = element[name]?
            JSValue.string(value)
          else
            JSValue.null
          end
        else
          JSValue.null
        end
      end
      
      set_attribute = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::String
          name = args[0].value.as(String)
          value = js_value_to_string(args[1])
          
          element[name] = value
          
          JSValue.undefined
        else
          JSValue.undefined
        end
      end
      
      has_attribute = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::String
          name = args[0].value.as(String)
          
          JSValue.boolean(element.has_attribute?(name))
        else
          JSValue.boolean(false)
        end
      end
      
      context.set_property(el_obj, "getAttribute", get_attribute)
      context.set_property(el_obj, "setAttribute", set_attribute)
      context.set_property(el_obj, "hasAttribute", has_attribute)
      
      el_obj
    end
    
    private def setup_property_accessor(context : JavaScriptContext, object : JSValue, property_name : String, getter : JSValue, setter : JSValue)
      # プロパティディスクリプタオブジェクトの作成
      descriptor = JSValue.object
      
      context.set_property(descriptor, "get", getter)
      context.set_property(descriptor, "set", setter)
      context.set_property(descriptor, "enumerable", JSValue.boolean(true))
      context.set_property(descriptor, "configurable", JSValue.boolean(true))
      
      # Object.defineProperty の呼び出し
      define_property = context.get_global_property("Object")
      
      if define_property.type == JSValueType::Object
        if define_property_fn = context.get_property(define_property, "defineProperty")
          call_function(context, define_property_fn, [object, JSValue.string(property_name), descriptor])
        end
      end
    end
    
    private def create_native_function(&block : Array(JSValue) -> JSValue) : JSValue
      # ネイティブ関数をJavaScript関数としてラップ
      JSValue.new(JSValueType::Function, block)
    end
    
    private def call_function(context : JavaScriptContext, func : JSValue, args : Array(JSValue)) : JSValue
      if func.type == JSValueType::Function
        if callback = func.value.as?(Array(JSValue) -> JSValue)
          begin
            callback.call(args)
          rescue ex : Exception
            # 例外をJavaScriptのエラーに変換
            context.throw_error("NativeError", ex.message || "Unknown native error")
            JSValue.undefined
          end
        else
          # JavaScriptエンジンの関数呼び出し
          context.call_function(func, args)
        end
      else
        context.throw_type_error("Not a function")
        JSValue.undefined
      end
    end
    
    private def setup_event_target_methods(context : JavaScriptContext, target : JSValue)
      # イベントリスナーを保持するための内部ストレージ
      listeners = {} of String => Array(JSValue)
      
      # addEventListener実装
      add_listener = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::String && args[1].type == JSValueType::Function
          event_name = args[0].value.as(String)
          callback = args[1]
          
          listeners[event_name] ||= [] of JSValue
          listeners[event_name] << callback
        end
        JSValue.undefined
      end
      
      # removeEventListener実装
      remove_listener = create_native_function do |args|
        if args.size >= 2 && args[0].type == JSValueType::String && args[1].type == JSValueType::Function
          event_name = args[0].value.as(String)
          callback = args[1]
          
          if event_listeners = listeners[event_name]?
            listeners[event_name] = event_listeners.reject { |listener| listener.object_id == callback.object_id }
          end
        end
        JSValue.undefined
      end
      
      # dispatchEvent実装
      dispatch_event = create_native_function do |args|
        if args.size >= 1 && args[0].type == JSValueType::Object
          event = args[0]
          event_type = context.get_property(event, "type")
          
          if event_type.type == JSValueType::String
            type_name = event_type.value.as(String)
            
            # イベントのターゲットを設定
            context.set_property(event, "target", target)
            context.set_property(event, "currentTarget", target)
            
            # リスナーを呼び出し
            if event_listeners = listeners[type_name]?
              event_listeners.each do |listener|
                call_function(context, listener, [event])
                
                # イベント伝播が停止された場合
                if context.get_property(event, "propagationStopped").value.as?(Bool) == true
                  break
                end
              end
            end
            
            # デフォルトのイベント処理が阻止されたかどうかを返す
            default_prevented = context.get_property(event, "defaultPrevented")
            if default_prevented.type == JSValueType::Boolean
              JSValue.boolean(!default_prevented.value.as(Bool))
            else
              JSValue.boolean(true)
            end
          else
            context.throw_type_error("Event object has no type")
            JSValue.boolean(false)
          end
        else
          context.throw_type_error("Not an Event object")
          JSValue.boolean(false)
        end
      end
      
      # メソッドをターゲットに設定
      context.set_property(target, "addEventListener", add_listener)
      context.set_property(target, "removeEventListener", remove_listener)
      context.set_property(target, "dispatchEvent", dispatch_event)
      
      # イベントリスナーストレージへの参照を保持
      context.set_private_data(target, "eventListeners", listeners)
    end
    
    private def js_value_to_string(value : JSValue) : String
      case value.type
      when JSValueType::String
        value.value.as(String)
      when JSValueType::Number
        value.value.as(Float64).to_s
      when JSValueType::Boolean
        value.value.as(Bool).to_s
      when JSValueType::Null
        "null"
      when JSValueType::Undefined
        "undefined"
      else
        "[object Object]" # 簡易な文字列化
      end
    end
    
    private def create_event_object(context : JavaScriptContext, event_name : String, event_data : Hash(String, JSValue)) : JSValue
      event = JSValue.object
      
      # 基本プロパティ
      context.set_property(event, "type", JSValue.string(event_name))
      context.set_property(event, "bubbles", event_data["bubbles"]? || JSValue.boolean(true))
      context.set_property(event, "cancelable", event_data["cancelable"]? || JSValue.boolean(true))
      context.set_property(event, "composed", event_data["composed"]? || JSValue.boolean(false))
      
      # タイムスタンプ
      context.set_property(event, "timeStamp", JSValue.number(Time.utc.to_unix_ms.to_f64))
      
      # メソッド
      stop_propagation = create_native_function do |_args|
        context.set_property(event, "bubbles", JSValue.boolean(false))
        JSValue.undefined
      end
      
      prevent_default = create_native_function do |_args|
        context.set_property(event, "defaultPrevented", JSValue.boolean(true))
        JSValue.undefined
      end
      
      context.set_property(event, "stopPropagation", stop_propagation)
      context.set_property(event, "preventDefault", prevent_default)
      context.set_property(event, "defaultPrevented", JSValue.boolean(false))
      
      # イベント固有のデータをコピー
      event_data.each do |key, value|
        unless %w(type bubbles cancelable composed).includes?(key)
          context.set_property(event, key, value)
        end
      end
      
      event
    end
    
    private def parse_js(code : String, filename : String? = nil) : JSAst
      # JavaScriptコードの解析（Zigエンジンとの連携）
      begin
        result = LibJavaScriptEngine.parse_js_code(code, filename || "anonymous")
        if result.error?
          error = JSError.new(
            message: result.error_message,
            line: result.error_line,
            column: result.error_column,
            source: code,
            filename: filename
          )
          notify_parse_error(error)
          raise error
        end
        
        JSAst.new(result.ast_handle)
      rescue ex
        error = JSError.new(
          message: ex.message || "Unknown parsing error",
          line: 0,
          column: 0,
          source: code,
          filename: filename
        )
        notify_parse_error(error)
        raise error
      end
    end
    
    private def evaluate_js(context : JavaScriptContext, ast : JSAst) : JSValue
      # ASTの評価（Zigエンジンとの連携）
      begin
        result = LibJavaScriptEngine.evaluate_js_ast(context.id, ast.handle)
        if result.error?
          error = JSError.new(
            message: result.error_message,
            line: result.error_line,
            column: result.error_column,
            source: "",
            filename: ast.filename
          )
          context.last_error = error
          raise error
        end
        
        JSValue.from_handle(result.value_handle)
      rescue ex
        error = JSError.new(
          message: ex.message || "Evaluation error",
          line: 0,
          column: 0,
          source: "",
          filename: ast.filename
        )
        context.last_error = error
        raise error
      end
    end
    
    private def notify_parse_error(error : JSError) : Nil
      @parse_error_callbacks.each do |callback|
        begin
          callback.call(error)
        rescue ex
          @logger.error("Error in parse error callback: #{ex.message}")
        end
      end
    end
    
    private def register_timer(context : JavaScriptContext, callback : JSValue, time : Int32, repeat : Bool) : Int32
      # タイマーの登録（Zigエンジンとの連携）
      timer_id = LibJavaScriptEngine.register_js_timer(context.id, callback.handle, time, repeat)
      
      # タイマーIDをコンテキストに関連付け
      context.timers << timer_id
      
      # タイマーIDをグローバルマップに登録
      @timer_mutex.synchronize do
        @timers[timer_id] = {context: context, callback: callback}
      end
      
      timer_id
    end
    
    private def clear_timer(timer_id : Int32) : Nil
      # タイマーの解除（Zigエンジンとの連携）
      LibJavaScriptEngine.clear_js_timer(timer_id)
      
      # グローバルマップから削除
      @timer_mutex.synchronize do
        if timer_info = @timers[timer_id]?
          timer_info[:context].timers.delete(timer_id)
          @timers.delete(timer_id)
        end
      end
    end
    
    private def add_event_listener_to_element(element : Element, event_name : String, callback : JSValue) : Nil
      # イベントリスナーの登録（Zigエンジンとの連携）
      element_id = element.object_id
      
      # イベントリスナーマップに登録
      @event_listener_mutex.synchronize do
        @event_listeners[element_id] ||= {} of String => Array(JSValue)
        @event_listeners[element_id][event_name] ||= [] of JSValue
        @event_listeners[element_id][event_name] << callback
      end
      
      # Zigエンジンに通知
      LibJavaScriptEngine.add_js_event_listener(element_id, event_name, callback.handle)
    end
    
    private def remove_event_listener_from_element(element : Element, event_name : String, callback : JSValue) : Nil
      # イベントリスナーの削除（Zigエンジンとの連携）
      element_id = element.object_id
      
      # イベントリスナーマップから削除
      removed = false
      @event_listener_mutex.synchronize do
        if listeners = @event_listeners[element_id]?
          if event_listeners = listeners[event_name]?
            removed = event_listeners.delete(callback)
            if event_listeners.empty?
              listeners.delete(event_name)
            end
            if listeners.empty?
              @event_listeners.delete(element_id)
            end
          end
        end
      end
      
      # Zigエンジンに通知（リスナーが見つかった場合のみ）
      if removed
        LibJavaScriptEngine.remove_js_event_listener(element_id, event_name, callback.handle)
      end
    end
    
    private def get_event_listeners(element : Element, event_name : String) : Array(JSValue)?
      # イベントリスナーの取得
      element_id = element.object_id
      
      @event_listener_mutex.synchronize do
        if listeners = @event_listeners[element_id]?
          if event_listeners = listeners[event_name]?
            return event_listeners.dup
          end
        end
      end
      
      nil
    end
    
    private def register_mutation_callback(observer_id : String, callback : Proc(Array(MutationRecord), MutationObserver, Nil)) : Nil
      # 変異オブザーバーコールバックの登録
      @mutation_observer_mutex.synchronize do
        @mutation_observers[observer_id] = callback
      end
      
      # Zigエンジンに通知
      callback_wrapper = ->(records_handle : Pointer(Void), observer_handle : Pointer(Void)) {
        records = LibJavaScriptEngine.get_mutation_records(records_handle)
        observer = MutationObserver.from_handle(observer_handle)
        callback.call(records, observer)
      }
      
      LibJavaScriptEngine.register_js_mutation_callback(observer_id, callback_wrapper)
    end
    
    private def observe_element(element : Element, observer_id : String, options : MutationObserverInit) : Nil
      # 要素の監視設定（Zigエンジンとの連携）
      element_id = element.object_id
      
      # 監視対象要素マップに登録
      @mutation_observer_mutex.synchronize do
        @observed_elements[element_id] ||= {} of String => MutationObserverInit
        @observed_elements[element_id][observer_id] = options
      end
      
      # Zigエンジンに通知
      LibJavaScriptEngine.observe_js_element(element_id, observer_id, options.to_unsafe)
    end
    
    private def load_js_engine : Nil
      # JavaScriptエンジンのロード（Zigエンジンとの連携）
      result = LibJavaScriptEngine.load_javascript_engine(@config.javascript_threads)
      
      if !result.success?
        @logger.error("Failed to load JavaScript engine: #{result.error_message}")
        raise JSEngineError.new("Failed to load JavaScript engine: #{result.error_message}")
      end
      
      @engine_loaded = true
      @logger.info("JavaScript engine loaded successfully with #{@config.javascript_threads} threads")
    end
    
    private def unload_js_engine : Nil
      return unless @engine_loaded
      
      # すべてのコンテキストを破棄
      @contexts.each_value do |context|
        destroy_context(context)
      end
      
      # タイマーをクリア
      @timer_mutex.synchronize do
        @timers.each_key do |timer_id|
          LibJavaScriptEngine.clear_js_timer(timer_id)
        end
        @timers.clear
      end
      
      # JavaScriptエンジンの解放（Zigエンジンとの連携）
      LibJavaScriptEngine.unload_javascript_engine
      
      @engine_loaded = false
      @logger.info("JavaScript engine unloaded successfully")
    end
  end
  
  # コンテキストの型エイリアス
  alias JavaScriptContext = JavaScriptEngine::JavaScriptContext
end 