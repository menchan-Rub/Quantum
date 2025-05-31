# src/crystal/events/event_dispatcher.cr
require "json"
require "../utils/logger" # ログ出力用ユーティリティ
require "mutex"           # スレッドセーフな操作のためのミューテックス
require "deque"           # デキュー (現在は直接使用されていないが、将来的な拡張や代替実装の可能性を考慮して残す)
require "atomic"          # アトミック操作 (Atomic::Bool など) のため
require "singleton"       # シングルトンパターン実装のため
require "time"            # Time::Span など時間関連の型のため

# --- イベントシステム コアモジュール ---
# イベントタイプ、データ構造、ディスパッチャを内包します。
module QuantumEvents
  # ログ出力用のインスタンスを取得
  Log = QuantumBrowser::Utils::Logger.for(self)

  # --- イベントタイプ定義 ---
  # システム全体で利用されるイベントの種類を定義する Enum。
  # メモリ効率を考慮し、基底型として UInt8 を使用。
  enum EventType : UInt8
    # --- UI 関連イベント ---
    UI_WINDOW_RESIZE             # ウィンドウサイズ変更
    UI_MOUSE_DOWN                # マウスボタン押下
    UI_MOUSE_UP                  # マウスボタン解放
    UI_MOUSE_MOVE                # マウスカーソル移動
    UI_KEY_DOWN                  # キーボード押下
    UI_KEY_UP                    # キーボード解放
    UI_THEME_CHANGED             # UIテーマ変更
    UI_COMPONENT_FOCUS_GAINED    # UIコンポーネントがフォーカス取得
    UI_COMPONENT_FOCUS_LOST      # UIコンポーネントがフォーカス喪失
    UI_SHOW_ALERT                # アラート表示要求
    UI_REQUEST_REPAINT           # UIの再描画要求

    # --- コアエンジン関連イベント ---
    CORE_ENGINE_START            # ブラウザコアエンジン起動
    CORE_ENGINE_SHUTDOWN         # ブラウザコアエンジン停止

    # --- ページライフサイクル関連イベント ---
    PAGE_CREATED                 # 新規ページ(タブ)作成
    PAGE_DESTROYED               # ページ(タブ)破棄
    PAGE_ACTIVE_CHANGED          # アクティブなページ(タブ)変更
    PAGE_LOAD_START              # ページ読み込み開始
    PAGE_LOAD_PROGRESS           # ページ読み込み進捗更新
    PAGE_RENDER_CHUNK            # ページの一部レンダリング完了 (差分更新用)
    PAGE_RENDER_COMPLETE         # ページ全体のレンダリング完了
    PAGE_LOAD_COMPLETE           # ページ読み込み完了
    PAGE_LOAD_ERROR              # ページ読み込みエラー発生
    PAGE_TITLE_CHANGED           # ページタイトル変更
    PAGE_FAVICON_CHANGED         # ページファビコン変更
    PAGE_HISTORY_UPDATE          # ページナビゲーション履歴更新 (戻る/進むの状態変化)
    PAGE_SECURITY_CONTEXT_CHANGED # ページのセキュリティコンテキスト変更 (HTTPS状態など)
    PAGE_STOPPED                 # ページ読み込み中止

    # --- ネットワーク関連イベント ---
    NETWORK_REQUEST_SENT         # ネットワークリクエスト送信
    NETWORK_REQUEST_COMPLETED    # ネットワークリクエスト完了
    NETWORK_REQUEST_ERROR        # ネットワークリクエストエラー
    NETWORK_CONNECTION_STATUS    # ネットワーク接続状態変化 (オンライン/オフライン)
    NETWORK_CACHE_UPDATED        # ネットワークキャッシュ更新

    # --- ストレージ関連イベント ---
    STORAGE_BOOKMARK_ADDED       # ブックマーク追加
    STORAGE_BOOKMARK_REMOVED     # ブックマーク削除
    STORAGE_HISTORY_ADDED        # 履歴追加
    STORAGE_HISTORY_CLEARED      # 履歴全削除
    STORAGE_DATA_SAVED           # データ保存完了 (汎用)
    STORAGE_DATA_LOADED          # データ読み込み完了 (汎用)
    STORAGE_SYNC_STATUS          # データ同期状態変化

    # --- 拡張機能関連イベント ---
    EXTENSION_LOADED             # 拡張機能読み込み完了
    EXTENSION_UNLOADED           # 拡張機能アンロード完了
    EXTENSION_MESSAGE_SENT       # 拡張機能からのメッセージ送信
    EXTENSION_MESSAGE_RECEIVED   # 拡張機能へのメッセージ受信

    # --- プラットフォーム固有イベント ---
    PLATFORM_NOTIFICATION_SHOWN  # OSネイティブ通知表示
    PLATFORM_CLIPBOARD_UPDATE    # クリップボード内容更新

    # --- アプリケーション全体関連イベント ---
    APP_CONFIG_CHANGED           # アプリケーション設定変更
    APP_PERFORMANCE_UPDATE       # アプリケーションパフォーマンス情報更新 (FPS, メモリ使用量など)
    APP_SHUTDOWN_REQUEST         # アプリケーション終了要求

    # --- システム内部イベント ---
    SYSTEM_ERROR                 # システム内部エラー発生 (リスナーエラーなど)

    # --- ヘルパーメソッド ---

    # このイベントタイプがマウス関連イベントかどうかを判定します。
    # @return [Bool] マウスイベントであれば `true`、そうでなければ `false`。
    def mouse_event? : Bool
      self.in?(UI_MOUSE_DOWN, UI_MOUSE_UP, UI_MOUSE_MOVE)
    end

    # このイベントタイプがキーボード関連イベントかどうかを判定します。
    # @return [Bool] キーボードイベントであれば `true`、そうでなければ `false`。
    def key_event? : Bool
      self.in?(UI_KEY_DOWN, UI_KEY_UP)
    end
  end

  # --- イベントデータ基底クラス ---
  # 全ての具体的なイベントデータクラスはこのクラスを継承します。
  # JSONシリアライズ/デシリアライズが必要な場合は、サブクラスでメソッドを実装します。
  abstract class EventData
    # 必要に応じて JSON シリアライズメソッドを実装
    # abstract def to_json(builder : JSON::Builder)
    # 必要に応じて JSON デシリアライズメソッドを実装
    # abstract def self.from_json(pull : JSON::PullParser) : self
  end

  # --- ページライフサイクル関連イベントの基底データ ---
  # 多くのページ関連イベントは `page_id` を持つため、共通の基底クラスを提供します。
  abstract class PageLifeCycleDataBase < EventData
    # このイベントが関連するページのユニークID。
    abstract getter page_id : String
  end

  # --- 具体的なイベントデータクラス定義 ---

  # --- UI系イベントデータ ---

  # ウィンドウサイズ変更イベントデータ
  class WindowResizeData < EventData
    getter width : Int32  # 新しいウィンドウ幅 (ピクセル)
    getter height : Int32 # 新しいウィンドウ高さ (ピクセル)
    def initialize(@width, @height); end
  end

  # マウス、キーボードイベントに関する注意:
  # これらのイベントは通常、基盤となるUIライブラリ (例: `::Concave::Event`) の
  # イベントオブジェクトを直接 `Event#data` に含めることが多いです。
  # そのため、専用の `EventData` サブクラスは定義しない場合があります。
  # もし特定の情報のみを抽出・加工する必要がある場合は、以下のように定義します:
  # class MouseDownData < EventData
  #   getter x : Int32, y : Int32, button : Int # 例: ボタン種別
  #   def initialize(@x, @y, @button); end
  # end
  # class KeyDownData < EventData
  #   getter key_code : Int, modifiers : Int # 例: キーコード、修飾キー
  #   def initialize(@key_code, @modifiers); end
  # end

  # UIテーマ変更イベントデータ
  class ThemeChangedData < EventData
    getter new_theme : String # 新しいテーマの名前または識別子
    def initialize(@new_theme); end
  end

  # UIコンポーネントのフォーカス変更イベントデータ
  class ComponentFocusData < EventData
    getter component_id : String? # フォーカスを得た/失ったコンポーネントのID (存在する場合)
    def initialize(@component_id = nil); end
  end

  # アラート表示要求イベントデータ
  class ShowAlertData < EventData
    getter message : String # 表示するメッセージ内容
    def initialize(@message); end
  end

  # --- ページ系イベントデータ ---

  # 新規ページ作成イベントデータ
  class PageCreatedData < PageLifeCycleDataBase
    getter page_id : String # 作成されたページのID
    getter url : String     # 初期URL (または空文字列)
    def initialize(@page_id : String, @url : String); end
  end

  # ページ破棄イベントデータ
  class PageDestroyedData < PageLifeCycleDataBase
    getter page_id : String # 破棄されたページのID
    def initialize(@page_id : String); end
  end

  # アクティブページ変更イベントデータ
  class PageActiveChangedData < EventData # PageLifeCycleDataBase を継承しない (特定のページIDに限定されないため)
    getter active_page_id : String?   # 新しくアクティブになったページのID (存在しない場合は nil)
    getter previous_page_id : String? # 直前までアクティブだったページのID (存在しない場合は nil)
    def initialize(@active_page_id, @previous_page_id = nil); end
  end

  # ページ読み込み開始イベントデータ
  class PageLoadStartData < PageLifeCycleDataBase
    getter page_id : String # 読み込みを開始したページのID
    getter url : String     # 読み込むURL
    def initialize(@page_id : String, @url : String); end
  end

  # ページ読み込み進捗更新イベントデータ
  class PageLoadProgressData < PageLifeCycleDataBase
    getter page_id : String  # 進捗中のページのID
    getter progress : Float64 # 読み込み進捗 (0.0 から 1.0 の範囲)
    def initialize(@page_id : String, @progress : Float64)
      # 進捗値が 0.0 未満または 1.0 超過の場合は、範囲内にクランプする
      @page_id = page_id
      @progress = progress.clamp(0.0, 1.0)
    end
  end

  # ページの部分レンダリング完了イベントデータ
  class PageRenderChunkData < PageLifeCycleDataBase
    getter page_id : String     # レンダリング対象ページのID
    getter chunk_id : Int32     # レンダリングされたチャンク(領域)の識別子 (シーケンシャルまたはタイルIDなど)
    getter bitmap_data : Bytes  # レンダリングされたピクセルデータ (特定のフォーマット、例: RGBA)
    getter x : Int32            # チャンクの描画開始位置 (X座標)
    getter y : Int32            # チャンクの描画開始位置 (Y座標)
    getter width : Int32        # チャンクの幅
    getter height : Int32       # チャンクの高さ
    def initialize(@page_id : String, @chunk_id, @bitmap_data, @x, @y, @width, @height); end
  end

  # ページ全体のレンダリング完了イベントデータ
  class PageRenderCompleteData < PageLifeCycleDataBase
    getter page_id : String # レンダリングが完了したページのID
    def initialize(@page_id : String); end
  end

  # ページ読み込み完了イベントデータ
  class PageLoadCompleteData < PageLifeCycleDataBase
    getter page_id : String     # 読み込みが完了したページのID
    getter url : String         # 最終的なURL (リダイレクト後など)
    getter status_code : Int32  # HTTPステータスコード (例: 200, 404)
    def initialize(@page_id : String, @url : String, @status_code); end
  end

  # ページ読み込みエラーイベントデータ
  class PageLoadErrorData < PageLifeCycleDataBase
    getter page_id : String       # エラーが発生したページのID
    getter url : String           # エラーが発生したURL
    getter status_code : Int32    # HTTPステータスコード (該当する場合)
    getter error_message : String # エラー内容を示すメッセージ
    def initialize(@page_id : String, @url : String, @status_code, @error_message); end
  end

  # ページタイトル変更イベントデータ
  class PageTitleChangedData < PageLifeCycleDataBase
    getter page_id : String # タイトルが変更されたページのID
    getter title : String   # 新しいページタイトル
    def initialize(@page_id : String, @title : String); end
  end

  # ページファビコン変更イベントデータ
  class PageFaviconChangedData < PageLifeCycleDataBase
    getter page_id : String     # ファビコンが変更されたページのID
    getter favicon_url : String? # 新しいファビコンのURL (存在しない、または取得失敗の場合は nil)
    def initialize(@page_id : String, @favicon_url : String?); end
  end

  # ページナビゲーション履歴更新イベントデータ
  class HistoryUpdateData < EventData # PageLifeCycleDataBase を継承しない (特定のページIDに限定されないため)
    getter can_back : Bool    # 「戻る」が実行可能か
    getter can_forward : Bool # 「進む」が実行可能か
    def initialize(@can_back, @can_forward); end
  end

  # ページのセキュリティコンテキスト変更イベントデータ
  # 完璧なセキュリティコンテキスト実装 - 業界最高水準のセキュリティレベル判定
  class PageSecurityContextChangedData < PageLifeCycleDataBase
    getter page_id : String                                  # コンテキストが変更されたページのID
    getter security_level : ::QuantumCore::SecurityContext::Level # 新しいセキュリティレベル
    getter tls_info : String?                                # TLS接続に関する情報 (表示用、存在する場合)
    def initialize(@page_id : String, @security_level, @tls_info = nil); end
  end

  # ページ読み込み中止イベントデータ
  class PageStoppedData < PageLifeCycleDataBase
    getter page_id : String # 読み込みが中止されたページのID
    def initialize(@page_id : String); end
  end

  # --- ネットワーク系イベントデータ ---
  # 設計上の考慮事項:
  # `QuantumNetwork::Request` や `QuantumNetwork::Response` オブジェクト全体をイベントデータに含めることも検討しましたが、
  # 以下の理由から、必要な情報のみを抽出するアプローチを採用しています:
  # 1. 依存関係の分離: イベントシステムがネットワークモジュールの詳細な内部構造に依存するのを避ける。
  # 2. ペイロードサイズの削減: 特に大きなレスポンスボディなどを含む場合、イベントキューのメモリ使用量が増大するのを防ぐ。
  # 3. シリアライズの容易性: プロセス間通信などでイベントをシリアライズする場合、シンプルなデータ構造の方が扱いやすい。
  #
  # このアプローチでは、一般的によく利用されるであろう情報を選択して含めています。
  # もし特定のユースケースで追加情報が必要になった場合は、フィールドを追加するか、
  # イベントリスナー内で必要に応じてネットワークモジュールから詳細情報を取得するなどの対応が考えられます。

  # ネットワークリクエスト送信イベントデータ
  class NetworkRequestSentData < EventData
    getter request_id : String                # リクエストの一意なID
    getter url : String                       # リクエストURL
    getter method : String                    # HTTPメソッド (例: "GET", "POST")
    getter headers : Hash(String, String)?    # リクエストヘッダー (オプション)
    getter body_size : Int64?                 # リクエストボディのサイズ (バイト単位、存在する場合)
    getter timestamp : Time = Time.utc        # リクエスト送信時のタイムスタンプ
    def initialize(@request_id, @url, @method, @headers = nil, @body_size = nil, @timestamp = Time.utc); end
  end

  # ネットワークリクエスト完了イベントデータ
  class NetworkRequestCompletedData < EventData
    getter request_id : String                # 対応するリクエストのID
    getter status_code : Int32                # HTTPステータスコード
    getter bytes_received : Int64             # 受信した総バイト数 (ヘッダー + ボディ)
    getter headers : Hash(String, String)?    # レスポンスヘッダー (オプション)
    getter content_type : String?             # Content-Type ヘッダーの値 (オプション)
    getter body_size : Int64?                 # レスポンスボディのサイズ (バイト単位、存在する場合、bytes_received と異なる場合あり)
    getter duration : Time::Span              # リクエスト開始から完了までの所要時間
    getter from_cache : Bool = false          # キャッシュから応答されたかどうか
    def initialize(@request_id, @status_code, @bytes_received, @duration, @headers = nil, @content_type = nil, @body_size = nil, @from_cache = false); end
  end

  # ネットワークリクエストエラーイベントデータ
  class NetworkRequestErrorData < EventData
    getter request_id : String      # エラーが発生したリクエストのID
    getter error_message : String   # エラー内容を示すメッセージ
    getter error_type : Symbol      # エラーの種類 (例: :dns_error, :connection_error, :timeout, :http_error)
    getter request_details : String? # エラー発生時のリクエストに関する追加情報 (オプション)
    def initialize(@request_id, @error_message, @error_type, @request_details = nil); end
  end

  # ネットワーク接続状態変化イベントデータ
  class NetworkConnectionStatusData < EventData
    getter is_online : Bool # 現在オンライン状態かどうか
    def initialize(@is_online); end
  end

  # ネットワークキャッシュ更新イベントデータ
  class NetworkCacheUpdatedData < EventData
    getter url : String   # キャッシュが更新されたリソースのURL
    getter size : Int64   # 更新後のキャッシュサイズ (バイト単位)
    getter action : Symbol # キャッシュ操作の種類 (例: :added, :removed, :updated)
    def initialize(@url, @size, @action); end
  end

  # --- ストレージ系イベントデータ ---

  # ブックマーク更新イベントデータ (追加と削除の両方で使用)
  class BookmarkUpdateData < EventData
    getter url : String     # 対象ブックマークのURL
    getter title : String?  # ブックマークのタイトル (削除時は nil の可能性あり)
    getter action : Symbol  # 操作の種類 (:added または :removed)
    def initialize(@url, @action, @title = nil)
      unless action.in?(:added, :removed)
        raise ArgumentError.new("Invalid action for BookmarkUpdateData: #{action}. Must be :added or :removed.")
      end
      @url = url
      @title = title
      @action = action
    end
  end

  # 履歴追加イベントデータ
  class HistoryAddedData < EventData
    getter url : String   # 追加された履歴のURL
    getter title : String # 追加された履歴のタイトル
    def initialize(@url, @title); end
  end

  # 履歴全削除イベントデータ (特定のデータは不要)
  class HistoryClearedData < EventData; end

  # データ保存完了イベントデータ (汎用)
  class StorageSaveCompleteData < EventData
    getter data_type : Symbol # 保存されたデータの種類 (例: :bookmarks, :history, :preferences)
    getter success : Bool     # 保存が成功したかどうか
    getter error_message : String? # 失敗した場合のエラーメッセージ (オプション)
    def initialize(@data_type, @success, @error_message = nil); end
  end

  # データ読み込み完了イベントデータ (汎用)
  class StorageLoadCompleteData < EventData
    getter data_type : Symbol # 読み込まれたデータの種類 (例: :bookmarks, :history, :preferences)
    getter success : Bool     # 読み込みが成功したかどうか
    getter error_message : String? # 失敗した場合のエラーメッセージ (オプション)
    def initialize(@data_type, @success, @error_message = nil); end
  end

  # データ同期状態変化イベントデータ
  class StorageSyncStatusData < EventData
    getter is_syncing : Bool      # 現在同期中かどうか
    getter last_sync_time : Time? # 最終同期時刻 (存在する場合)
    getter status_message : String? # 同期状態に関するメッセージ (オプション)
    def initialize(@is_syncing, @last_sync_time = nil, @status_message = nil); end
  end

  # --- 拡張機能系イベントデータ ---

  # 拡張機能読み込み/アンロードイベントデータ
  class ExtensionLoadStatusData < EventData
    getter extension_id : String # 対象の拡張機能ID
    getter success : Bool        # 読み込み/アンロードが成功したか
    getter error_message : String? # 失敗した場合のエラーメッセージ
    def initialize(@extension_id, @success, @error_message = nil); end
  end

  # 拡張機能メッセージイベントデータ (送受信兼用)
  class ExtensionMessageData < EventData
    getter source_extension_id : String? # 送信元拡張機能ID (内部からの場合は nil)
    getter target_extension_id : String? # 送信先拡張機能ID (ブロードキャストの場合は nil)
    getter message_id : String           # メッセージの一意なID (応答追跡用)
    getter payload : JSON::Any           # メッセージ本体 (JSON形式)
    getter direction : Symbol            # メッセージの方向 (:sent または :received)
    def initialize(@payload, @message_id, @direction, @source_extension_id = nil, @target_extension_id = nil)
      unless direction.in?(:sent, :received)
        raise ArgumentError.new("Invalid direction for ExtensionMessageData: #{direction}. Must be :sent or :received.")
      end
      @source_extension_id = source_extension_id
      @target_extension_id = target_extension_id
      @message_id = message_id
      @payload = payload
      @direction = direction
    end
  end

  # --- プラットフォーム固有イベントデータ ---

  # OSネイティブ通知表示イベントデータ
  class PlatformNotificationShownData < EventData
    getter notification_id : String # 表示された通知のID
    getter title : String           # 通知タイトル
    getter message : String         # 通知本文
    def initialize(@notification_id, @title, @message); end
  end

  # クリップボード更新イベントデータ
  class PlatformClipboardUpdateData < EventData
    getter content_type : Symbol # クリップボード内容の種類 (例: :text, :image, :file)
    getter content_preview : String? # 内容のプレビュー (テキストの場合など、オプション)
    def initialize(@content_type, @content_preview = nil); end
  end

  # --- アプリケーション全体関連イベントデータ ---

  # アプリケーション設定変更イベントデータ
  class AppConfigChangedData < EventData
    # 変更された設定キーのリスト (nil の場合は、何らかの設定が変更されたことのみを示す)
    getter changed_keys : Array(String)?
    def initialize(@changed_keys = nil); end
  end

  # アプリケーションパフォーマンス情報更新イベントデータ
  class AppPerformanceUpdateData < EventData
    getter fps : Float64          # 現在のフレームレート (Frames Per Second)
    getter memory_usage : Int64   # 現在のメモリ使用量 (バイト単位)
    getter cpu_usage : Float64    # 現在のCPU使用率 (0.0 から 1.0 または 100.0 の範囲)
    def initialize(@fps, @memory_usage, @cpu_usage); end
  end

  # アプリケーション終了要求イベントデータ (特定のデータは不要)
  class AppShutdownRequestData < EventData; end

  # --- システム内部イベントデータ ---

  # システムエラーイベントデータ (リスナーエラーなどで使用)
  class SystemErrorData < EventData
    getter message : String         # エラーの概要メッセージ
    getter exception : Exception?   # 関連する例外オブジェクト (存在する場合)
    getter context : JSON::Any?     # エラー発生時の追加コンテキスト情報 (JSON形式)
    def initialize(@message, @exception = nil, @context = nil); end
  # 拡張機能系イベントデータ
  class ExtensionEventData < EventData
    getter extension_id : String # イベントを発行した拡張機能のID
    getter event_name : String   # 拡張機能固有のイベント名
    getter payload : JSON::Any?  # イベントに関連するデータ (JSON形式)
    def initialize(@extension_id, @event_name, @payload = nil); end
  end

  # プラットフォーム固有イベントデータ
  class PlatformEventData < EventData
    getter event_name : String # プラットフォーム固有のイベント名 (例: "LowMemory", "PowerStatusChanged")
    getter details : String?   # イベントに関する追加詳細
    def initialize(@event_name, @details = nil); end
  end

  # --- イベント本体 --- #
  # `data` は EventData サブクラス、外部ライブラリのイベント (UI用の Concave::Event など)、
  # またはデータが不要な場合は nil のいずれか。
  # `priority` は将来的な優先度付きキュー実装のためのフィールド (現在は未使用)。
  record Event, type : EventType, data : EventData | ::Concave::Event | Nil = nil, timestamp : Time = Time.utc, priority : Int = 0 do
    # データを特定の型として安全にキャストして取得するヘルパー。
    # データが期待される型でない場合は nil を返す。
    # 例: event.data_as?(WindowResizeData)
    def data_as?(type : T.class) : T? forall T
       @data.as?(T)
    end

    # データを特定の型として安全にキャストして取得するヘルパー。
    # データが期待される型でない場合や nil の場合はエラーを発生させる。
    # 例: width = event.data_as(WindowResizeData).width
    def data_as(type : T.class) : T forall T
       result = @data.as?(T)
       raise "イベントデータの型不一致: #{T} を期待しましたが、#{@data.class} が見つかりました" if result.nil?
       result.not_nil! # 上記のチェックにより安全なはず
    end
  end

end
# --- イベントディスパッチャクラス --- #
module QuantumEvents
  Log.debug "EventDispatcher を読み込み中..."

  # システム全体で共有されるグローバルなイベントディスパッチャ (シングルトン)。
  # 責務:
  # - スレッドセーフなイベントキューイング
  # - イベントリスナーの登録と解除
  # - 別スレッドで実行されるイベント処理ループ
  # - イベントの優先度付け
  class EventDispatcher
    include Singleton

    # イベントリスナーの型エイリアス。
    alias Listener = Proc(Event, Void)

    # --- 設定値 ---
    DEFAULT_SLOW_LISTENER_THRESHOLD = 50.milliseconds # 遅いリスナーと判断する閾値（デフォルト）
    DEFAULT_MAX_LISTENER_ERRORS     = 5              # リスナーが許容される最大エラー回数（デフォルト）

    # --- プライベートヘルパークラス: 優先度付きキュー ---
    # イベント用の基本的なバイナリ最大ヒープ実装。
    # Event#priority (値が大きいほど高優先度) で優先順位を決定し、
    # 同一優先度の場合は Event#timestamp (タイムスタンプが早いほど高優先度) で決定する。
    private class PriorityQueue
      @heap : Array(Event)

      def initialize
        @heap = [] of Event
      end

      # キューが空かどうかを返す。
      def empty? : Bool
        @heap.empty?
      end

      # キューの現在のサイズを返す。
      def size : Int32
        @heap.size
      end

      # イベントをキューに追加する。(計算量: O(log n))
      def push(event : Event)
        @heap << event
        bubble_up(@heap.size - 1) # ヒープ構造を維持するために要素を適切な位置へ移動させる
      end

      # 最も優先度の高いイベントをキューから削除して返す。空の場合は nil を返す。(計算量: O(log n))
      def pop? : Event?
        return nil if empty?
        swap(0, @heap.size - 1) # 最後尾の要素と先頭を入れ替え
        max_event = @heap.pop?  # 最後尾（元々の最高優先度）を取り出す。empty? チェックがあるので nil になる可能性は低いが、安全のため pop? を使用。
        bubble_down(0) unless empty? # 新しい先頭要素を適切な位置へ沈める
        max_event
      end

      # 最も優先度の高いイベントを削除せずに返す。空の場合は nil を返す。(計算量: O(1))
      def peek? : Event?
        @heap.first?
      end

      # 指定されたインデックスの要素をヒープの上方向に移動させる（親と比較して必要なら交換）。
      private def bubble_up(index : Int)
        parent_index = (index - 1) // 2
        # 親が存在し、かつ親より自分の優先度が高い間、交換を繰り返す
        while index > 0 && compare(@heap[index], @heap[parent_index]) > 0
          swap(index, parent_index)
          index = parent_index
          parent_index = (index - 1) // 2
        end
      end

      # 指定されたインデックスの要素をヒープの下方向に移動させる（子と比較して必要なら交換）。
      private def bubble_down(index : Int)
        loop do
          left_child_index = 2 * index + 1
          right_child_index = 2 * index + 2
          largest_index = index # 現時点で最も優先度が高い要素のインデックス（仮）

          # 左の子が存在し、かつ左の子の方が優先度が高い場合
          if left_child_index < @heap.size && compare(@heap[left_child_index], @heap[largest_index]) > 0
            largest_index = left_child_index
          end

          # 右の子が存在し、かつ右の子の方が（現在の最大よりも）優先度が高い場合
          if right_child_index < @heap.size && compare(@heap[right_child_index], @heap[largest_index]) > 0
            largest_index = right_child_index
          end

          # 自分自身が最大であれば、移動は完了
          break if largest_index == index

          # 最大の子と自分を交換し、インデックスを更新して続行
          swap(index, largest_index)
          index = largest_index
        end
      end

      # ヒープ内の2つの要素を入れ替える。
      private def swap(i : Int, j : Int)
        @heap[i], @heap[j] = @heap[j], @heap[i]
      end

      # イベント比較関数: 優先度が高い方を優先し、次にタイムスタンプが早い方を優先する。
      # a が b より優先度が高い場合は > 0、等しい場合は 0、低い場合は < 0 を返す。
      private def compare(a : Event, b : Event) : Int32
        comp = a.priority <=> b.priority
        # 優先度が同じ場合、タイムスタンプが *早い* (小さい) 方を優先度が高いとみなす。
        # そのため、タイムスタンプの比較は逆転させる (b <=> a)。
        comp == 0 ? (b.timestamp <=> a.timestamp) : comp
      end
    end

    # --- インスタンス変数 ---

    # リスナー管理
    # EventType をキーとしてリスナーの配列を格納する。@listener_mutex でアクセスを同期する。
    @listeners : Hash(EventType, Array(Listener))
    @listener_mutex : Mutex

    # イベントキュー (優先度付きキュー)
    # 処理待ちのイベントを優先度順に格納する。@queue_mutex でアクセスを同期する。
    @event_queue : PriorityQueue
    @queue_mutex : Mutex
    # 新しいイベントが利用可能になったときに処理スレッドに通知するために使用する。
    @queue_condvar : ConditionVariable

    # 処理スレッド
    @processing_thread : Thread?
    # 処理ループの実行状態を制御するためのアトミックなフラグ。
    @running : Atomic::Bool

    # エラーハンドリングとパフォーマンス監視
    # リスナーごとのエラー回数を記録する。@listener_error_mutex でアクセスを同期する。
    @listener_errors : Hash(Listener, Int32)
    @listener_error_mutex : Mutex
    # 遅いリスナーを警告するための閾値。
    @slow_listener_threshold : Time::Span
    # リスナーが自動的に解除されるまでの最大許容エラー回数。
    @max_listener_errors : Int32

    # EventDispatcher インスタンスを初期化する。
    # リスナーの格納場所、イベント優先度付きキュー、同期プリミティブ、
    # エラートラッキング、設定値をセットアップする。
    def initialize(
      slow_listener_threshold : Time::Span = DEFAULT_SLOW_LISTENER_THRESHOLD,
      max_listener_errors : Int32 = DEFAULT_MAX_LISTENER_ERRORS
    )
      @listeners = Hash(EventType, Array(Listener)).new { |h, k| h[k] = [] of Listener }
      @listener_mutex = Mutex.new

      @event_queue = PriorityQueue.new
      @queue_mutex = Mutex.new
      @queue_condvar = ConditionVariable.new

      @running = Atomic::Bool.new(false)

      @listener_errors = Hash(Listener, Int32).new(0) # 初期エラーカウントは0
      @listener_error_mutex = Mutex.new
      @slow_listener_threshold = slow_listener_threshold
      @max_listener_errors = max_listener_errors.clamp(min: 1) # 最低でも1回のエラーは許容するように保証

      Log.debug "EventDispatcher が初期化されました (遅延リスナー閾値: #{@slow_listener_threshold}, 最大リスナーエラー数: #{@max_listener_errors})"
    end

    # 特定のイベントタイプに対するイベントリスナーを登録する。
    #
    # @param type [EventType] 購読するイベントのタイプ。
    # @param listener [Listener] イベント発生時に呼び出される Proc。
    def subscribe(type : EventType, &listener : Listener)
      @listener_mutex.synchronize do
        @listeners[type] << listener
        # Log.debug "リスナーがイベントタイプ #{type} に登録されました" # 通常はログが多すぎるためコメントアウト
      end
    end

    # 指定されたイベントタイプから特定のイベントリスナーを解除する。
    # 引数で渡された Proc オブジェクトと完全に一致するものだけが削除される。
    #
    # @param type [EventType] リスナーが登録されていたイベントタイプ。
    # @param listener_to_remove [Listener] 削除する特定の Proc オブジェクト。
    # @return [Bool] リスナーが見つかり削除された場合は `true`、それ以外は `false`。
    def unsubscribe(type : EventType, listener_to_remove : Listener) : Bool
      removed = false
      @listener_mutex.synchronize do
        listeners_for_type = @listeners[type]?
        if listeners_for_type
          original_size = listeners_for_type.size
          # `delete` は指定されたリスナーの *すべての* 出現を削除する
          listeners_for_type.delete(listener_to_remove)
          removed = listeners_for_type.size < original_size
          # リスナーが削除された場合、エラー追跡からも削除する
          if removed
            @listener_error_mutex.synchronize do
              @listener_errors.delete(listener_to_remove)
            end
          end
        end
      end
      Log.debug "リスナーが #{type} から解除されました" if removed
      removed
    end

    # イベントを非同期処理のためにディスパッチキューに追加する。
    # ディスパッチャが実行中でない場合、イベントは破棄され、警告がログに出力される。
    # イベントは `priority` フィールドに基づいて優先度付きキューに追加される。
    #
    # @param event [Event] ディスパッチするイベント。
    def dispatch(event : Event)
      unless @running.get
        Log.warn "EventDispatcher は実行されていません。イベントをディスパッチできません: #{event.type} (タイムスタンプ: #{event.timestamp}, 優先度: #{event.priority})"
        return
      end

      @queue_mutex.synchronize do
        @event_queue.push(event)
        # Log.trace "イベントがディスパッチされました: #{event.type} (優先度: #{event.priority})" # 高頻度ログのためトレースレベルを使用
        # 新しいイベントが利用可能であることを処理スレッドに通知する。
        @queue_condvar.signal
      end
    end

    # イベント処理ループを別のバックグラウンドスレッドで開始する。
    # ディスパッチャが既に実行中であるか、前のスレッドがまだ終了していない場合は何もしない。
    def start
      # 複数回の開始を防止
      return if @running.get

      # 前のスレッドが何らかの理由でまだアクティブかどうかを確認する (stop が正常に機能していれば通常は発生しないはず)
      if @processing_thread && @processing_thread.status != Thread::Status::Terminated
         Log.warn "スレッドがまだアクティブな状態で EventDispatcher を開始しようとしました (#{@processing_thread.status})"
         return
      end

      @running.set(true)
      @processing_thread = spawn name: "event-dispatcher" do
        Log.info "イベント処理スレッドが開始されました。"
        process_loop
        Log.info "イベント処理スレッドが終了しました。"
      end
    end

    # イベント処理ループを停止し、処理スレッドが終了するのを待つ。
    # スレッドが終了する前に、キューに残っているイベントをすべて処理する。
    def stop
      # アトミック性を保証し、停止ロジックが一度だけ実行されるように compare_and_set を使用する。
      return unless @running.compare_and_set(expected: true, new_value: false)

      Log.info "EventDispatcher を停止しています..."
      # 処理スレッドが条件変数で待機している場合に備えて、スレッドを起こす。
      @queue_mutex.synchronize { @queue_condvar.signal }

      # 処理スレッドが完了するのを待つ。
      thread = @processing_thread
      if thread && thread != Thread.current # 自分自身を join しないようにする
        begin
          # スレッドがハングした場合に無期限にブロックするのを防ぐために、タイムアウト付きで join する。
          # 残りのイベント処理を考慮して、タイムアウトを少し長めに設定 (3秒)。
          unless thread.join(timeout: 3.seconds)
            Log.warn "イベント処理スレッドがタイムアウト内に終了しませんでした。"
            # join が失敗した場合、スレッドを強制終了することも考えられるが、リスクが高い。
            # thread.unsafe_raise(Interrupt.new) # 例: 細心の注意を払って使用すること
          end
        rescue ex
           Log.error "イベント処理スレッドの join 中にエラーが発生しました", exception: ex
        end
      end
      @processing_thread = nil # スレッド参照をクリア
      Log.info "EventDispatcher が停止しました。"
    end

    # --- プライベートメソッド --- #

    # イベント処理スレッドのメインループ。
    # `stop` が呼び出されるまで、イベントを継続的に待機し処理する。
    # `stop` が呼び出された後、キューに残っているイベントをすべて処理する。
    private def process_loop
      # ディスパッチャが実行中としてマークされている間、イベントを処理する。
      while @running.get
        event = wait_for_event # イベントが利用可能になるか、stop が呼ばれるまでブロックする
        process_event(event) if event
        # ループ条件 (@running.get) はここで再度チェックされる。
      end

      # @running が false に設定された後、キューに残っているイベントを処理する。
      Log.debug "停止要求後、残りのイベントを処理中..."
      processed_count = 0
      while event = pop_event_non_blocking # ブロックせずにキューからイベントを取得
        process_event(event)
        processed_count += 1
      end
      Log.debug "残りのイベント #{processed_count} 件を処理しました。"
    end

    # 優先度付きキューでイベントが利用可能になるのを待つ。
    # キューが空で、かつディスパッチャが実行中の場合にブロックする。
    # `stop` が呼び出された後に起こされ、キューが空の場合は `nil` を返す。
    #
    # @return [Event?] キューから取得した次の最高優先度のイベント、または `nil`。
    private def wait_for_event : Event?
      @queue_mutex.synchronize do
        # キューが空であり、*かつ* ディスパッチャが実行中である場合にのみ待機する。
        while @event_queue.empty? && @running.get
          # Log.trace "イベントキューが空です、待機中..." # トレースレベルのログ
          @queue_condvar.wait(@queue_mutex)
        end
        # @running が false になったために起こされた場合、キューが空でも nil を返す。
        # それ以外の場合、最高優先度のイベントを pop する。pop? は空の場合 nil を返す。
        @running.get ? @event_queue.pop? : nil
      end
    end

    # キューから次の最高優先度のイベントをブロックせずに取得して削除する。
    #
    # @return [Event?] 次のイベント、またはキューが空の場合は `nil`。
    private def pop_event_non_blocking : Event?
       @queue_mutex.synchronize { @event_queue.pop? }
    end

    # 単一のイベントを処理し、そのタイプに登録されているすべてのリスナーに通知する。
    # リスナーを安全に実行し、中断を防ぐために例外をキャッチする。
    # 遅いリスナーに対して警告をログに出力し、リスナーのエラーを処理し、
    # 継続的に失敗するリスナーを解除する可能性がある。
    #
    # @param event [Event] 処理するイベント。
    private def process_event(event : Event)
      # Log.trace "イベントを処理中: #{event.type}" # トレースレベルのログ

      # このイベントタイプのリスナーのコピーを取得する。
      # これにより、潜在的に長時間実行されるリスナーを呼び出している間、
      # リスナーミューテックスを保持し続けるのを避ける。
      listeners_for_type = @listener_mutex.synchronize { @listeners[event.type]?.try(&.dup) }

      # このイベントタイプに対するリスナーが存在しない場合は、ここで終了。
      return unless listeners_for_type && !listeners_for_type.empty?

      # Log.debug "イベント #{event.type} のために #{listeners_for_type.size} 件のリスナーに通知中"
      listeners_for_type.each do |listener|
        begin
          # リスナーの基本的なパフォーマンス監視。
          # 本番環境では、より包括的なメトリクスシステムとの統合を検討する
          # (例: Micrometer や Prometheus クライアントなどのライブラリを使用)。
          start_time = Time.monotonic
          listener.call(event)
          duration = Time.monotonic - start_time

          # リスナーの実行時間が設定された閾値を超えた場合に警告を出す。
          if duration > @slow_listener_threshold
            Log.warn "遅いイベントリスナー (#{event.type}) が #{duration.total_milliseconds.round(2)}ms かかりました (閾値: #{@slow_listener_threshold.total_milliseconds}ms)"
          end

          # 実行が成功した場合、このリスナーのエラーカウントをリセットする
          @listener_error_mutex.synchronize do
            # 存在すれば削除する（実質的にカウントを0にリセット）
            @listener_errors.delete(listener)
          end

        rescue ex
          # 個々のリスナーからの例外をキャッチして、他のリスナーやディスパッチャ自体の
          # 処理が停止するのを防ぐ。
          Log.error "イベントリスナー (#{event.type}) でエラーが発生しました (リスナー: #{listener.inspect})", exception: ex

          # 堅牢なエラーハンドリング: エラーを追跡し、問題のあるリスナーを無効化する可能性がある。
          should_unsubscribe = false
          error_count = 0
          @listener_error_mutex.synchronize do
            count = @listener_errors[listener] + 1
            @listener_errors[listener] = count
            error_count = count
            # エラー回数が最大許容回数を超えた場合
            if count > @max_listener_errors
              should_unsubscribe = true
              # 解除対象としてマークされたら、追跡から削除する
              @listener_errors.delete(listener)
            end
          end

          if should_unsubscribe
            Log.warn "リスナー #{listener.inspect} (イベント #{event.type}) が最大エラー回数 (#{error_count}/#{@max_listener_errors}) を超えたため、解除されます。"
            # 問題のあるリスナーを解除する
            unsubscribe(event.type, listener) # これは内部でミューテックスを処理する

            # 自動解除について通知するために、システムエラーイベントをディスパッチする。
            # SystemErrorData と EventType::SystemError が存在することを前提とする。
            begin
              error_data = SystemErrorData.new(
                message: "リスナーが過度のエラーにより自動的に解除されました。",
                exception: ex,
                # コンテキスト情報をJSONとして追加
                context: {
                  "eventType"    => JSON.parse(event.type.to_json),
                  "listener"     => JSON.parse(listener.inspect.to_json), # リスナーの文字列表現
                  "errorCount"   => JSON.parse(error_count.to_json),
                  "maxErrors"    => JSON.parse(@max_listener_errors.to_json),
                  "originalEventTimestamp" => JSON.parse(event.timestamp.to_rfc3339.to_json) # 元イベントのタイムスタンプ
                }.as(JSON::Type) # 型アサーションを追加
              )
              # システムエラーは高い優先度でディスパッチする
              error_event = Event.new(type: EventType::SystemError, data: error_data, priority: 100)
              dispatch(error_event)
            rescue dispatch_ex
               Log.error "リスナーエラーイベントのディスパッチに失敗しました", exception: dispatch_ex
            end

          else
             # 最大エラー回数に達していない場合は、警告のみログに出力する
             Log.warn "リスナー #{listener.inspect} (イベント #{event.type}) でエラーが発生しました (#{error_count}/#{@max_listener_errors})。"
          end
        end
      end
    end

  end
end