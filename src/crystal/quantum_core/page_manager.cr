require "./page"
require "../events/**"
require "../utils/logger"
require "mutex"
require "uuid"
require "log"
require "deque"

module QuantumCore
  # ページ (タブ) のライフサイクル、履歴、アクティブ状態を管理するクラス。
  # ページIDには文字列形式のUUIDを使用します。
  class PageManager
    Log = ::Log.for(self)

    # セッションデータ永続化用のキー
    private SESSION_KEY = "pagemanager_session"

    @engine : Engine                   # 親エンジンへの参照
    @pages : Hash(String, Page)       # page_id => Page マッピング
    @history : Deque(String)          # ページIDの履歴スタック
    @current_history_index : Int32    # 履歴内の現在位置インデックス
    @mutex : Mutex                    # スレッドセーフ用

    getter engine : Engine
    getter event_dispatcher : EventDispatcher

    # 初期化
    def initialize(@engine : Engine, @event_dispatcher : EventDispatcher, private @resource_scheduler : ResourceScheduler)
      @pages = {} of String => Page
      @history = Deque(String).new
      @current_history_index = -1
      @mutex = Mutex.new
      @logger = Log.for(self.class.name)
      @logger.level = ::Log::Severity.parse(ENV.fetch("LOG_LEVEL", "INFO"))
      @logger.info { "PageManager を初期化しました。" }
    end

    # 新しいページを作成
    def create_new_page(initial_url : String? = nil, activate : Bool = true) : Page
      page_id = generate_new_page_id
      @logger.info { "新しいページを作成します (ID: #{page_id})..." }
      begin
        page = Page.new(@engine, page_id, @event_dispatcher, @resource_scheduler, initial_url: initial_url || @engine.config.homepage)
        @mutex.synchronize do
          @pages[page_id] = page
        end
        dispatch_event(QuantumEvents::EventType::PAGE_CREATED, QuantumEvents::PageCreatedData.new(page_id, page.url))
        set_active_page(page_id) if activate
        page
      rescue ex
        @logger.fatal(exception: ex) { "ページ (ID: #{page_id}) の作成に失敗しました。" }
        @mutex.synchronize { @pages.delete(page_id) }
        raise RuntimeError.new("ページ作成に失敗しました。", cause: ex)
      end
    end

    # ページ検索
    def find_page(page_id : String) : Page?
      @mutex.synchronize { @pages[page_id]? }
    end

    # 現在アクティブなページ
    def current_page : Page?
      active_id = active_page_id
      active_id ? find_page(active_id) : nil
    end

    # 現在アクティブページID
    def active_page_id : String?
      @mutex.synchronize do
        if @current_history_index >= 0 && @current_history_index < @history.size
          @history[@current_history_index]? 
        else
          nil
        end
      end
    end

    # アクティブページ設定
    def set_active_page(page_id : String)
      page = find_page(page_id)
      raise ArgumentError.new("ページが見つかりません: #{page_id}") unless page
      @mutex.synchronize do
        old_id = active_page_id
        idx = @history.index(page_id)
        if idx
          @current_history_index = idx
        else
          while @history.size > @current_history_index + 1
            @history.pop
          end
          @history.push(page_id)
          @current_history_index = @history.size - 1
        end
        if old_id != page_id
          dispatch_active_page_changed(page_id, old_id)
          dispatch_history_updated
        end
      end
    end

    # ナビゲーション登録 (履歴追加)
    def register_navigation(page_id : String, url : String)
      @logger.debug { "ページ (ID: #{page_id}) ナビゲート登録 (URL: #{url})" }
      set_active_page(page_id)
    end

    # ページ削除
    def remove_page(page_id : String)
      @logger.info { "ページ (ID: #{page_id}) 削除..." }
      page_to_remove = nil
      old_id = nil
      new_id = nil
      @mutex.synchronize do
        page_to_remove = @pages.delete(page_id)
        return unless page_to_remove
        old_id = active_page_id
        removed = false
        if idx = @history.index(page_id)
          @history.delete_at(idx)
          removed = true
          if idx == @current_history_index
            @current_history_index = [idx - 1, 0].max
          elsif idx < @current_history_index
            @current_history_index -= 1
          end
          new_id = active_page_id
        end
      end
      page_to_remove.cleanup
      dispatch_event(QuantumEvents::EventType::PAGE_REMOVED, QuantumEvents::PageRemovedData.new(page_id))
      dispatch_active_page_changed(new_id, old_id) if old_id != new_id
      dispatch_history_updated if removed || old_id != new_id
    end

    # 履歴戻る
    def back
      @mutex.synchronize do
        return unless can_go_back?
        old_id = active_page_id
        @current_history_index -= 1
        new_id = active_page_id
        dispatch_active_page_changed(new_id, old_id)
        dispatch_history_updated
      end
    end

    # 履歴進む
    def forward
      @mutex.synchronize do
        return unless can_go_forward?
        old_id = active_page_id
        @current_history_index += 1
        new_id = active_page_id
        dispatch_active_page_changed(new_id, old_id)
        dispatch_history_updated
      end
    end

    def can_go_back? : Bool
      @mutex.synchronize { @current_history_index > 0 }
    end
    def can_go_forward? : Bool
      @mutex.synchronize { @current_history_index < @history.size - 1 }
    end

    # クリーンアップ (シャットダウン時)
    def cleanup
      save_session
      @mutex.synchronize do
        @pages.each { |_, p| p.cleanup rescue @logger.error { "ページクリーンアップエラー" } }
        @pages.clear
        @history.clear
        @current_history_index = -1
      end
    end

    # 全ページのIDリストを取得します
    # @return [Array(String)] 登録されているすべてのページID
    def page_ids : Array(String)
      @mutex.synchronize { @pages.keys }
    end

    # セッション読み込み
    private def load_session
      return unless @engine.storage_manager.ready?
      data = @engine.storage_manager.get(SESSION_KEY)
      return unless data
      parsed = JSON.parse(data) rescue return
      hist = parsed["history"]? as_a? rescue nil
      idx  = parsed["active_index"]? as_i? rescue nil
      return unless hist
      @mutex.synchronize do
        @history.clear
        @pages.clear
        hist.each do |pid|
          begin
            pg = Page.new(@engine, pid, @event_dispatcher, @resource_scheduler, initial_url: "about:blank")
            @pages[pid] = pg
            @history.push(pid)
          rescue
          end
        end
        @current_history_index = (idx && idx < @history.size) ? idx : (@history.empty? ? -1 : 0)
      end
      dispatch_active_page_changed(active_page_id, nil)
      dispatch_history_updated
    end

    # セッション保存
    private def save_session
      return unless @engine.storage_manager.ready?
      syn = @mutex.synchronize do
        { "history" => @history.to_a, "active_index" => @current_history_index }
      end
      @engine.storage_manager.put(SESSION_KEY, syn.to_json) rescue @logger.error { "セッション保存エラー" }
    end

    # UUID生成
    private def generate_new_page_id : String
      UUID.random.to_s
    end

    # イベント発行ヘルパー
    private def dispatch_active_page_changed(new_id : String?, old_id : String?)
      return if new_id == old_id
      dispatch_event(QuantumEvents::EventType::PAGE_ACTIVE_CHANGED, QuantumEvents::PageActiveChangedData.new(new_id, old_id))
    end
    private def dispatch_history_updated
      dispatch_event(QuantumEvents::EventType::PAGE_HISTORY_UPDATED, QuantumEvents::PageHistoryUpdatedData.new(can_go_back?, can_go_forward?))
    end
    private def dispatch_event(type, data=nil)
      @event_dispatcher.dispatch(QuantumEvents::Event.new(type, data)) rescue @logger.error { "イベント#{type}発行エラー" }
    end

    class Error < Exception; end
  end
end

module QuantumEvents
  class PageHistoryUpdatedData < EventData
    getter can_back : Bool
    getter can_forward : Bool
    def initialize(@can_back, @can_forward); end
  end
  class PageCreatedData < EventData
    getter page_id : String
    getter initial_url : String?
    def initialize(@page_id, @initial_url); end
  end
  class PageRemovedData < EventData
    getter page_id : String
    def initialize(@page_id); end
  end
  class PageActiveChangedData < EventData
    getter new_page_id : String?
    getter old_page_id : String?
    def initialize(@new_page_id, @old_page_id); end
  end
end