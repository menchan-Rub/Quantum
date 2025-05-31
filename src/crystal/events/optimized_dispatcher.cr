module QuantumEvents
  # 高性能イベントディスパッチャーシステム
  # 入力レイテンシーを最小化し、効率的なイベント処理を実現
  class OptimizedDispatcher
    # イベント型定義
    enum EventType
      MouseMove
      MouseDown
      MouseUp
      MouseWheel
      KeyDown
      KeyUp
      Resize
      Focus
      Blur
      DragStart
      DragMove
      DragEnd
      Custom
    end
    
    # イベントフェーズ
    enum EventPhase
      Capture  # キャプチャフェーズ（トップダウン）
      Target   # ターゲットフェーズ
      Bubble   # バブリングフェーズ（ボトムアップ）
    end
    
    # 基本イベントクラス
    class Event
      property type : EventType
      property target : EventTarget?
      property current_target : EventTarget?
      property phase : EventPhase
      property timestamp : Int64
      property propagation_stopped : Bool = false
      property immediate_propagation_stopped : Bool = false
      property default_prevented : Bool = false
      
      def initialize(@type : EventType, @target : EventTarget? = nil)
        @phase = EventPhase::Target
        @timestamp = Time.monotonic.total_milliseconds.to_i64
        @current_target = @target
      end
      
      # 伝播を停止
      def stop_propagation : Void
        @propagation_stopped = true
      end
      
      # 即時伝播を停止
      def stop_immediate_propagation : Void
        @propagation_stopped = true
        @immediate_propagation_stopped = true
      end
      
      # デフォルト動作を防止
      def prevent_default : Void
        @default_prevented = true
      end
    end
    
    # マウスイベント
    class MouseEvent < Event
      property x : Int32
      property y : Int32
      property button : Int32
      property buttons : Int32
      property alt_key : Bool
      property ctrl_key : Bool
      property shift_key : Bool
      property meta_key : Bool
      
      def initialize(type : EventType, @x : Int32, @y : Int32, @button : Int32 = 0, @buttons : Int32 = 0, 
                     @alt_key : Bool = false, @ctrl_key : Bool = false, @shift_key : Bool = false, @meta_key : Bool = false,
                     target : EventTarget? = nil)
        super(type, target)
      end
    end
    
    # キーボードイベント
    class KeyboardEvent < Event
      property key : String
      property code : String
      property key_code : Int32
      property repeat : Bool
      property alt_key : Bool
      property ctrl_key : Bool
      property shift_key : Bool
      property meta_key : Bool
      
      def initialize(type : EventType, @key : String, @code : String, @key_code : Int32, @repeat : Bool = false,
                     @alt_key : Bool = false, @ctrl_key : Bool = false, @shift_key : Bool = false, @meta_key : Bool = false,
                     target : EventTarget? = nil)
        super(type, target)
      end
    end
    
    # カスタムイベント
    class CustomEvent < Event
      property detail : Hash(String, String)
      
      def initialize(type : EventType, @detail : Hash(String, String) = {} of String => String, target : EventTarget? = nil)
        super(type, target)
      end
    end
    
    # イベントリスナー型
    alias EventListener = Proc(Event, Void)
    
    # イベントターゲットインターフェース
    abstract class EventTarget
      # リスナーキャッシュ
      # 型ごとのリスナーリストを高速にルックアップするための最適化構造
      @listeners : Hash(EventType, Array(EventListener)) = {} of EventType => Array(EventListener)
      @capture_listeners : Hash(EventType, Array(EventListener)) = {} of EventType => Array(EventListener)
      
      # リスナー追加カウントの最適化（不要なアロケーションを避ける）
      @listener_count : Int32 = 0
      
      # 親ターゲット（イベント伝播用）
      property parent : EventTarget?
      
      # 子ターゲット（キャプチャフェーズ用）
      property children : Array(EventTarget) = [] of EventTarget
      
      # コンポーネント識別用
      property id : String = ""
      
      # イベントリスナーを追加
      def add_event_listener(type : EventType, listener : EventListener, capture : Bool = false) : Void
        if capture
          @capture_listeners[type] ||= [] of EventListener
          @capture_listeners[type] << listener
        else
          @listeners[type] ||= [] of EventListener
          @listeners[type] << listener
        end
        
        @listener_count += 1
      end
      
      # イベントリスナーを削除
      def remove_event_listener(type : EventType, listener : EventListener, capture : Bool = false) : Void
        target_hash = capture ? @capture_listeners : @listeners
        
        if target_hash.has_key?(type)
          original_size = target_hash[type].size
          target_hash[type].reject! { |l| l == listener }
          
          removed_count = original_size - target_hash[type].size
          @listener_count -= removed_count
          
          if target_hash[type].empty?
            target_hash.delete(type)
          end
        end
      end
      
      # イベントを発火
      def dispatch_event(event : Event) : Bool
        # イベントのターゲットを設定
        event.target = self
        
        # 伝播パスを構築
        propagation_path = build_propagation_path
        
        # キャプチャフェーズ（トップダウン）
        event.phase = EventPhase::Capture
        propagation_path.each do |target|
          next if target == self # ターゲット自身は別のフェーズで処理
          
          event.current_target = target
          target.process_event(event, true)
          
          break if event.propagation_stopped
        end
        
        return false if event.propagation_stopped
        
        # ターゲットフェーズ
        event.phase = EventPhase::Target
        event.current_target = self
        process_event(event, false)
        process_event(event, true)
        
        return false if event.propagation_stopped
        
        # バブリングフェーズ（ボトムアップ）
        event.phase = EventPhase::Bubble
        propagation_path.reverse.each do |target|
          next if target == self # ターゲット自身はすでに処理済み
          
          event.current_target = target
          target.process_event(event, false)
          
          break if event.propagation_stopped
        end
        
        !event.default_prevented
      end
      
      # イベント処理メソッド
      private def process_event(event : Event, capture : Bool) : Void
        target_hash = capture ? @capture_listeners : @listeners
        
        if target_hash.has_key?(event.type)
          # リスナーのコピーを作成（処理中にリスナーが変更される可能性に対処）
          listeners = target_hash[event.type].dup
          
          listeners.each do |listener|
            listener.call(event)
            
            break if event.immediate_propagation_stopped
          end
        end
      end
      
      # イベント伝播パスを構築
      private def build_propagation_path : Array(EventTarget)
        path = [] of EventTarget
        current = self.parent
        
        while current
          path.unshift(current)
          current = current.parent
        end
        
        path
      end
      
      # イベントを発生させる（ショートカットメソッド）
      def fire_event(type : EventType, detail : Hash(String, String) = {} of String => String) : Bool
        event = CustomEvent.new(type, detail, self)
        dispatch_event(event)
      end
      
      # このターゲットに対するマウスイベントを発生
      def fire_mouse_event(type : EventType, x : Int32, y : Int32, button : Int32 = 0, buttons : Int32 = 0,
                          alt_key : Bool = false, ctrl_key : Bool = false, shift_key : Bool = false, meta_key : Bool = false) : Bool
        event = MouseEvent.new(type, x, y, button, buttons, alt_key, ctrl_key, shift_key, meta_key, self)
        dispatch_event(event)
      end
      
      # このターゲットに対するキーボードイベントを発生
      def fire_keyboard_event(type : EventType, key : String, code : String, key_code : Int32, repeat : Bool = false,
                             alt_key : Bool = false, ctrl_key : Bool = false, shift_key : Bool = false, meta_key : Bool = false) : Bool
        event = KeyboardEvent.new(type, key, code, key_code, repeat, alt_key, ctrl_key, shift_key, meta_key, self)
        dispatch_event(event)
      end
    end
    
    # ルート要素（通常はウィンドウやドキュメント）
    class RootEventTarget < EventTarget
      def initialize
        @parent = nil
      end
    end
    
    # イベントドメイン（ツリーのルート。通常はアプリケーション単位）
    class EventDomain
      property root : RootEventTarget
      property active_element : EventTarget?
      
      # イベントキュー
      @event_queue : Deque(Event) = Deque(Event).new
      @processing_events : Bool = false
      
      # 高速イベントタイプ判別用キャッシュ
      @input_event_types : Set(EventType) = Set{
        EventType::MouseMove, EventType::MouseDown, EventType::MouseUp, 
        EventType::KeyDown, EventType::KeyUp, EventType::MouseWheel
      }
      
      def initialize
        @root = RootEventTarget.new
      end
      
      # イベントを追加
      def enqueue_event(event : Event) : Void
        # 入力イベントは最高優先度
        if @input_event_types.includes?(event.type)
          @event_queue.unshift(event) # キューの先頭に追加
        else
          @event_queue.push(event)    # キューの末尾に追加
        end
        
        # イベント処理がアイドル状態なら開始
        process_events unless @processing_events
      end
      
      # イベントキューを処理
      def process_events : Void
        @processing_events = true
        
        start_time = Time.monotonic
        
        while !@event_queue.empty?
          # フレーム時間を超えないように制限（16.6ms = 60fps）
          current_time = Time.monotonic
          if (current_time - start_time).total_milliseconds > 16.6
            # 次のフレームで残りを処理
            schedule_next_frame_processing
            break
          end
          
          event = @event_queue.shift
          
          if event.target
            event.target.not_nil!.dispatch_event(event)
          else
            # ターゲットがない場合はルートから伝播
            event.target = @root
            @root.dispatch_event(event)
          end
        end
        
        @processing_events = false
        
        # まだイベントが残っていれば次のフレームで処理
        if !@event_queue.empty?
          schedule_next_frame_processing
        end
      end
      
      # 次のフレームでの処理をスケジュール
      private def schedule_next_frame_processing : Void
        # レンダリングエンジンのフレーム更新時に再開するための登録
        QuantumCore::RenderScheduler.instance.add_frame_callback ->(delta_time : Float64) {
          # 次のフレームでイベント処理を再開
          if !@event_queue.empty? && !@processing_events
            process_events
          end
          
          # コールバックは一度だけ実行（必要に応じて再登録）
          false
        }
      end
      
      # ヒットテスト（座標に該当する要素を探索）
      def hit_test(x : Int32, y : Int32, root : EventTarget? = nil) : EventTarget?
        root ||= @root
        
        # 子要素から順にチェック（Zインデックス順）
        root.children.reverse.each do |child|
          # コンポーネントがhit_testメソッドを持つ場合
          if child.responds_to?(:hit_test)
            if target = child.hit_test(x, y)
              return target
            end
          else
            # 簡易ヒットテスト
            if child.responds_to?(:contains_point?) && child.contains_point?(x, y)
              # 子要素をさらにチェック
              if child.children.size > 0
                if target = hit_test(x, y, child)
                  return target
                end
              end
              return child
            end
          end
        end
        
        # いずれの子要素にもヒットしなかった場合
        root
      end
      
      # マウスイベントのディスパッチ処理
      def dispatch_mouse_event(type : EventType, x : Int32, y : Int32, button : Int32 = 0, buttons : Int32 = 0,
                              alt_key : Bool = false, ctrl_key : Bool = false, shift_key : Bool = false, meta_key : Bool = false) : Bool
        # 座標にあるターゲットを探す
        target = hit_test(x, y)
        
        # イベントの作成とディスパッチ
        event = MouseEvent.new(type, x, y, button, buttons, alt_key, ctrl_key, shift_key, meta_key, target)
        
        if target
          target.dispatch_event(event)
        else
          @root.dispatch_event(event)
        end
        
        !event.default_prevented
      end
      
      # キーボードイベントのディスパッチ処理
      def dispatch_keyboard_event(type : EventType, key : String, code : String, key_code : Int32, repeat : Bool = false,
                                 alt_key : Bool = false, ctrl_key : Bool = false, shift_key : Bool = false, meta_key : Bool = false) : Bool
        # アクティブ要素（フォーカスがある要素）をターゲットに
        target = @active_element || @root
        
        # イベントの作成とディスパッチ
        event = KeyboardEvent.new(type, key, code, key_code, repeat, alt_key, ctrl_key, shift_key, meta_key, target)
        target.dispatch_event(event)
        
        !event.default_prevented
      end
      
      # フォーカス変更処理
      def set_focus(target : EventTarget?) : Void
        old_focus = @active_element
        
        # 同じ要素なら何もしない
        return if old_focus == target
        
        # 古い要素からフォーカスを外す
        if old_focus
          blur_event = Event.new(EventType::Blur, old_focus)
          old_focus.dispatch_event(blur_event)
        end
        
        @active_element = target
        
        # 新しい要素にフォーカスを設定
        if target
          focus_event = Event.new(EventType::Focus, target)
          target.dispatch_event(focus_event)
        end
      end
    end
    
    # イベントの削減・バッチ処理
    class EventThrottler
      # 最終イベント発火時間
      @last_event_times : Hash(EventType, Int64) = {} of EventType => Int64
      
      # 抑制時間（ミリ秒）
      @throttle_intervals : Hash(EventType, Int64) = {
        EventType::MouseMove => 16, # 約60fps
        EventType::MouseWheel => 16,
        EventType::Resize => 100
      } of EventType => Int64
      
      # モーションイベントの値を一時保存
      @last_mouse_x : Int32 = 0
      @last_mouse_y : Int32 = 0
      
      # リサイズイベントの値を一時保存
      @last_width : Int32 = 0
      @last_height : Int32 = 0
      
      # イベントドメイン参照
      @domain : EventDomain
      
      def initialize(@domain : EventDomain)
      end
      
      # マウス移動イベントをスロットル
      def throttle_mouse_move(x : Int32, y : Int32, buttons : Int32,
                             alt_key : Bool, ctrl_key : Bool, shift_key : Bool, meta_key : Bool) : Bool
        now = Time.monotonic.total_milliseconds.to_i64
        type = EventType::MouseMove
        
        # 値を保存
        @last_mouse_x = x
        @last_mouse_y = y
        
        if !@last_event_times.has_key?(type) || (now - @last_event_times[type]) >= @throttle_intervals[type]
          # スロットル間隔を超えた場合、イベントを発火
          @last_event_times[type] = now
          return @domain.dispatch_mouse_event(type, x, y, 0, buttons, alt_key, ctrl_key, shift_key, meta_key)
        end
        
        true
      end
      
      # リサイズイベントをスロットル
      def throttle_resize(width : Int32, height : Int32) : Bool
        now = Time.monotonic.total_milliseconds.to_i64
        type = EventType::Resize
        
        # 値が変わっていない場合はスキップ
        return true if width == @last_width && height == @last_height
        
        # 値を保存
        @last_width = width
        @last_height = height
        
        if !@last_event_times.has_key?(type) || (now - @last_event_times[type]) >= @throttle_intervals[type]
          # スロットル間隔を超えた場合、イベントを発火
          @last_event_times[type] = now
          
          # リサイズイベントのディスパッチ（カスタムイベント）
          event = CustomEvent.new(
            type, 
            {"width" => width.to_s, "height" => height.to_s},
            @domain.root
          )
          
          @domain.root.dispatch_event(event)
          return !event.default_prevented
        end
        
        true
      end
      
      # スロットル間隔を設定
      def set_throttle_interval(type : EventType, interval_ms : Int64) : Void
        @throttle_intervals[type] = interval_ms
      end
      
      # 保留中のイベントを強制発火（例：ウィンドウがアクティブでなくなった時）
      def flush_pending_events : Void
        now = Time.monotonic.total_milliseconds.to_i64
        
        # 保留中のマウス移動イベント
        if @last_event_times.has_key?(EventType::MouseMove)
          @domain.dispatch_mouse_event(
            EventType::MouseMove, 
            @last_mouse_x, @last_mouse_y, 
            0, 0, false, false, false, false
          )
          @last_event_times[EventType::MouseMove] = now
        end
        
        # 保留中のリサイズイベント
        if @last_event_times.has_key?(EventType::Resize) && @last_width > 0 && @last_height > 0
          event = CustomEvent.new(
            EventType::Resize,
            {"width" => @last_width.to_s, "height" => @last_height.to_s},
            @domain.root
          )
          
          @domain.root.dispatch_event(event)
          @last_event_times[EventType::Resize] = now
        end
      end
    end
  end
end 