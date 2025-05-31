@[Link("quantum_nim_net")]
lib NimNetwork
  # Nimネットワークライブラリとのバインディング
  
  # エラーコード
  enum ErrorCode
    NoError          = 0
    ConnectionFailed = 1
    Timeout          = 2
    InvalidRequest   = 3
    InvalidResponse  = 4
    ProtocolError    = 5
    TLSError         = 6
    DNSError         = 7
    InternalError    = 99
  end
  
  # HTTPメソッド
  enum HttpMethod
    GET     = 0
    POST    = 1
    PUT     = 2
    DELETE  = 3
    HEAD    = 4
    OPTIONS = 5
    PATCH   = 6
  end
  
  # HTTPプロトコルバージョン
  enum HttpVersion
    HTTP1  = 0
    HTTP2  = 1
    HTTP3  = 2
  end
  
  # リクエスト優先度
  enum RequestPriority
    Lowest  = 0
    Low     = 1
    Normal  = 2
    High    = 3
    Highest = 4
  end
  
  # HTTPヘッダ構造体
  struct HttpHeader
    key : LibC::Char*
    value : LibC::Char*
  end
  
  # HTTPリクエスト構造体
  struct HttpRequest
    id : LibC::ULongLong
    method : HttpMethod
    url : LibC::Char*
    headers : HttpHeader*
    header_count : LibC::UInt
    body : LibC::Char*
    body_length : LibC::ULongLong
    version : HttpVersion
    priority : RequestPriority
    timeout_ms : LibC::UInt
  end
  
  # HTTPレスポンス構造体
  struct HttpResponse
    request_id : LibC::ULongLong
    status_code : LibC::UInt
    headers : HttpHeader*
    header_count : LibC::UInt
    body : LibC::Char*
    body_length : LibC::ULongLong
    error_code : ErrorCode
    error_message : LibC::Char*
    timing_total_ms : LibC::UInt
    timing_dns_ms : LibC::UInt
    timing_connect_ms : LibC::UInt
    timing_tls_ms : LibC::UInt
    timing_first_byte_ms : LibC::UInt
  end
  
  # ネットワークマネージャの初期化と破棄
  fun initialize_network(max_connections : LibC::UInt, max_connections_per_host : LibC::UInt) : Void*
  fun shutdown_network(network : Void*) : Void
  
  # 接続プール管理
  fun set_connection_pool_params(network : Void*, max_connections_per_host : LibC::UInt, 
                                 connection_timeout : LibC::UInt, idle_timeout : LibC::UInt) : LibC::Int
  fun get_connection_stats(network : Void*, active : LibC::UInt*, idle : LibC::UInt*, total : LibC::UInt*) : Void
  fun clear_connection_pool(network : Void*) : Void
  
  # HTTPリクエスト処理
  fun create_request(network : Void*) : HttpRequest*
  fun destroy_request(network : Void*, request : HttpRequest*) : Void
  fun send_request(network : Void*, request : HttpRequest*, callback : LibC::Void*, user_data : Void*) : LibC::Int
  fun send_request_sync(network : Void*, request : HttpRequest*, response : HttpResponse**) : LibC::Int
  fun cancel_request(network : Void*, request_id : LibC::ULongLong) : LibC::Int
  
  # HTTPレスポンス処理
  fun destroy_response(network : Void*, response : HttpResponse*) : Void
  
  # メモリ管理用
  fun alloc_string(network : Void*, size : LibC::ULongLong) : LibC::Char*
  fun free_string(network : Void*, str : LibC::Char*) : Void
  fun alloc_headers(network : Void*, count : LibC::UInt) : HttpHeader*
  fun free_headers(network : Void*, headers : HttpHeader*, count : LibC::UInt) : Void
  
  # DNS操作
  fun prefetch_dns(network : Void*, hostname : LibC::Char*) : LibC::Int
  fun clear_dns_cache(network : Void*) : Void
  
  # 統計情報
  fun get_network_stats(network : Void*, request_count : LibC::ULongLong*, total_bytes : LibC::ULongLong*, 
                        avg_latency_ms : LibC::Float*) : Void
  fun reset_network_stats(network : Void*) : Void
  
  # WebSocketサポート
  fun create_websocket(network : Void*, url : LibC::Char*) : Void*
  fun destroy_websocket(network : Void*, websocket : Void*) : Void
  fun websocket_connect(network : Void*, websocket : Void*, callback : LibC::Void*, user_data : Void*) : LibC::Int
  fun websocket_send(network : Void*, websocket : Void*, data : LibC::Char*, length : LibC::ULongLong) : LibC::Int
  fun websocket_close(network : Void*, websocket : Void*, code : LibC::UShort, reason : LibC::Char*) : Void
end

module QuantumNetwork
  # HTTPレスポンスコールバック型
  alias ResponseCallback = Proc(HttpResponse, Void*)
  
  # Crystal側のHTTPヘッダ
  class HttpHeader
    property key : String
    property value : String
    
    def initialize(@key : String, @value : String)
    end
  end
  
  # Crystal側のHTTPリクエスト
  class HttpRequest
    property id : UInt64
    property method : NimNetwork::HttpMethod
    property url : String
    property headers : Array(HttpHeader)
    property body : Bytes?
    property version : NimNetwork::HttpVersion
    property priority : NimNetwork::RequestPriority
    property timeout_ms : UInt32
    
    def initialize(@url : String, @method = NimNetwork::HttpMethod::GET)
      @id = 0_u64
      @headers = [] of HttpHeader
      @body = nil
      @version = NimNetwork::HttpVersion::HTTP1
      @priority = NimNetwork::RequestPriority::Normal
      @timeout_ms = 30000_u32 # 30秒
    end
    
    # ヘッダー追加
    def add_header(key : String, value : String) : Void
      @headers << HttpHeader.new(key, value)
    end
    
    # POSTリクエスト向けのコンビニエンスメソッド
    def self.post(url : String, body : String, content_type : String = "application/json") : HttpRequest
      req = new(url, NimNetwork::HttpMethod::POST)
      req.add_header("Content-Type", content_type)
      req.body = body.to_slice
      req
    end
    
    # GETリクエスト向けのコンビニエンスメソッド
    def self.get(url : String) : HttpRequest
      new(url, NimNetwork::HttpMethod::GET)
    end
  end
  
  # Crystal側のHTTPレスポンス
  class HttpResponse
    property request_id : UInt64
    property status_code : UInt32
    property headers : Array(HttpHeader)
    property body : Bytes
    property error_code : NimNetwork::ErrorCode
    property error_message : String
    property timing : ResponseTiming
    
    # レスポンスタイミング情報
    struct ResponseTiming
      property total_ms : UInt32
      property dns_ms : UInt32
      property connect_ms : UInt32
      property tls_ms : UInt32
      property first_byte_ms : UInt32
      
      def initialize(@total_ms = 0_u32, @dns_ms = 0_u32, @connect_ms = 0_u32,
                     @tls_ms = 0_u32, @first_byte_ms = 0_u32)
      end
    end
    
    def initialize(@request_id = 0_u64, @status_code = 0_u32)
      @headers = [] of HttpHeader
      @body = Bytes.new(0)
      @error_code = NimNetwork::ErrorCode::NoError
      @error_message = ""
      @timing = ResponseTiming.new
    end
    
    # ボディをUTF-8文字列として取得
    def body_text : String
      String.new(@body)
    end
    
    # 成功したかどうか
    def success? : Bool
      @error_code == NimNetwork::ErrorCode::NoError && (200..299).includes?(@status_code)
    end
    
    # 指定ヘッダーの値を取得
    def get_header(key : String) : String?
      @headers.find { |h| h.key.downcase == key.downcase }.try &.value
    end
  end
  
  # Nimネットワークマネージャのラッパー
  class NetworkManager
    # Nimネットワークマネージャへのポインタ
    @network : Void*
    
    # コールバック登録用
    @callbacks : Hash(UInt64, ResponseCallback)
    
    # スレッドセーフロック
    @lock : Mutex
    
    # リクエストIDカウンタ
    @next_request_id : UInt64
    
    # 初期化
    def initialize(max_connections : Int32 = 32, max_connections_per_host : Int32 = 6)
      @network = NimNetwork.initialize_network(max_connections.to_u32, max_connections_per_host.to_u32)
      
      if @network.null?
        raise "Nimネットワークマネージャの初期化に失敗しました"
      end
      
      @callbacks = {} of UInt64 => ResponseCallback
      @lock = Mutex.new
      @next_request_id = 1_u64
    end
    
    # リソース解放
    def finalize
      unless @network.null?
        NimNetwork.shutdown_network(@network)
      end
    end
    
    # 接続プールの設定
    def set_connection_pool_params(max_connections_per_host : Int32, connection_timeout : Int32, idle_timeout : Int32) : Bool
      result = NimNetwork.set_connection_pool_params(
        @network,
        max_connections_per_host.to_u32,
        connection_timeout.to_u32,
        idle_timeout.to_u32
      )
      
      result == 0
    end
    
    # 接続プールの統計情報取得
    def get_connection_stats : {active: UInt32, idle: UInt32, total: UInt32}
      active = uninitialized UInt32
      idle = uninitialized UInt32
      total = uninitialized UInt32
      
      NimNetwork.get_connection_stats(@network, pointerof(active), pointerof(idle), pointerof(total))
      
      {active: active, idle: idle, total: total}
    end
    
    # 接続プールのクリア
    def clear_connection_pool : Void
      NimNetwork.clear_connection_pool(@network)
    end
    
    # 非同期リクエスト送信
    def send_request(request : HttpRequest, &callback : HttpResponse -> Void) : Bool
      next_id = @lock.synchronize do
        id = @next_request_id
        @next_request_id += 1
        id
      end
      
      # Nim用のリクエスト構造体を作成
      nim_request = create_nim_request(request, next_id)
      return false unless nim_request
      
      # コールバックを保存
      cb = ->(response : HttpResponse, user_data : Void*) {
        callback.call(response)
      }
      
      @lock.synchronize do
        @callbacks[next_id] = cb
      end
      
      # 非同期リクエスト送信
      result = NimNetwork.send_request(@network, nim_request, callback_dispatcher, nil)
      
      if result != 0
        @lock.synchronize do
          @callbacks.delete(next_id)
        end
        NimNetwork.destroy_request(@network, nim_request)
        return false
      end
      
      # リクエストIDを設定
      request.id = next_id
      
      true
    end
    
    # 同期リクエスト送信
    def send_request_sync(request : HttpRequest) : HttpResponse
      next_id = @lock.synchronize do
        id = @next_request_id
        @next_request_id += 1
        id
      end
      
      # Nim用のリクエスト構造体を作成
      nim_request = create_nim_request(request, next_id)
      
      response = HttpResponse.new(next_id)
      
      if nim_request.null?
        response.error_code = NimNetwork::ErrorCode::InvalidRequest
        response.error_message = "リクエストの作成に失敗しました"
        return response
      end
      
      # 同期リクエスト送信
      nim_response = uninitialized NimNetwork::HttpResponse*
      result = NimNetwork.send_request_sync(@network, nim_request, pointerof(nim_response))
      
      if result != 0 || nim_response.null?
        response.error_code = NimNetwork::ErrorCode::ConnectionFailed
        response.error_message = "リクエストの送信に失敗しました"
        NimNetwork.destroy_request(@network, nim_request)
        return response
      end
      
      # レスポンスをCrystal側の構造体に変換
      response = convert_nim_response(nim_response)
      
      # Nimリソースを解放
      NimNetwork.destroy_response(@network, nim_response)
      NimNetwork.destroy_request(@network, nim_request)
      
      response
    end
    
    # リクエストキャンセル
    def cancel_request(request_id : UInt64) : Bool
      @lock.synchronize do
        @callbacks.delete(request_id)
      end
      
      result = NimNetwork.cancel_request(@network, request_id)
      result == 0
    end
    
    # DNS事前解決
    def prefetch_dns(hostname : String) : Bool
      result = NimNetwork.prefetch_dns(@network, hostname.to_unsafe)
      result == 0
    end
    
    # DNSキャッシュクリア
    def clear_dns_cache : Void
      NimNetwork.clear_dns_cache(@network)
    end
    
    # ネットワーク統計情報取得
    def get_network_stats : {request_count: UInt64, total_bytes: UInt64, avg_latency_ms: Float32}
      request_count = uninitialized UInt64
      total_bytes = uninitialized UInt64
      avg_latency = uninitialized Float32
      
      NimNetwork.get_network_stats(@network, pointerof(request_count), pointerof(total_bytes), pointerof(avg_latency))
      
      {request_count: request_count, total_bytes: total_bytes, avg_latency_ms: avg_latency}
    end
    
    # 統計情報リセット
    def reset_network_stats : Void
      NimNetwork.reset_network_stats(@network)
    end
    
    # WebSocket作成
    def create_websocket(url : String) : WebSocket
      WebSocket.new(self, url)
    end
    
    # 内部処理：Nim用リクエスト構造体作成
    private def create_nim_request(request : HttpRequest, id : UInt64) : NimNetwork::HttpRequest*
      nim_request = NimNetwork.create_request(@network)
      return nil if nim_request.null?
      
      # URLをNim側にコピー
      url_ptr = NimNetwork.alloc_string(@network, request.url.bytesize + 1)
      url_ptr.copy_from(request.url.to_unsafe, request.url.bytesize)
      url_ptr[request.url.bytesize] = 0_u8
      
      # ヘッダーをNim側にコピー
      headers_ptr = NimNetwork.alloc_headers(@network, request.headers.size.to_u32)
      
      request.headers.each_with_index do |header, i|
        # キーをコピー
        key_ptr = NimNetwork.alloc_string(@network, header.key.bytesize + 1)
        key_ptr.copy_from(header.key.to_unsafe, header.key.bytesize)
        key_ptr[header.key.bytesize] = 0_u8
        
        # 値をコピー
        value_ptr = NimNetwork.alloc_string(@network, header.value.bytesize + 1)
        value_ptr.copy_from(header.value.to_unsafe, header.value.bytesize)
        value_ptr[header.value.bytesize] = 0_u8
        
        # ヘッダー構造体に設定
        headers_ptr[i].key = key_ptr
        headers_ptr[i].value = value_ptr
      end
      
      # ボディがある場合はコピー
      body_ptr = nil
      body_length = 0_u64
      
      if body = request.body
        body_ptr = NimNetwork.alloc_string(@network, body.size.to_u64)
        body_ptr.copy_from(body.to_unsafe, body.size)
        body_length = body.size.to_u64
      end
      
      # リクエスト構造体にデータを設定
      nim_request.value.id = id
      nim_request.value.method = request.method
      nim_request.value.url = url_ptr
      nim_request.value.headers = headers_ptr
      nim_request.value.header_count = request.headers.size.to_u32
      nim_request.value.body = body_ptr
      nim_request.value.body_length = body_length
      nim_request.value.version = request.version
      nim_request.value.priority = request.priority
      nim_request.value.timeout_ms = request.timeout_ms
      
      nim_request
    end
    
    # 内部処理：Nim用レスポンス構造体からCrystal側に変換
    private def convert_nim_response(nim_response : NimNetwork::HttpResponse*) : HttpResponse
      response = HttpResponse.new(nim_response.value.request_id, nim_response.value.status_code)
      
      # エラー情報をコピー
      response.error_code = nim_response.value.error_code
      
      if nim_response.value.error_message != nil
        response.error_message = String.new(nim_response.value.error_message)
      end
      
      # タイミング情報をコピー
      response.timing = HttpResponse::ResponseTiming.new(
        nim_response.value.timing_total_ms,
        nim_response.value.timing_dns_ms,
        nim_response.value.timing_connect_ms,
        nim_response.value.timing_tls_ms,
        nim_response.value.timing_first_byte_ms
      )
      
      # ヘッダーをコピー
      header_count = nim_response.value.header_count
      headers_ptr = nim_response.value.headers
      
      header_count.times do |i|
        key = headers_ptr[i].key ? String.new(headers_ptr[i].key) : ""
        value = headers_ptr[i].value ? String.new(headers_ptr[i].value) : ""
        response.headers << HttpHeader.new(key, value)
      end
      
      # ボディをコピー
      if nim_response.value.body != nil && nim_response.value.body_length > 0
        body_length = nim_response.value.body_length.to_i32
        response.body = Bytes.new(body_length)
        response.body.copy_from(nim_response.value.body.as(Pointer(UInt8)), body_length)
      end
      
      response
    end
    
    # コールバックディスパッチャ（C側から呼び出されるコールバック）
    private def callback_dispatcher(nim_response : NimNetwork::HttpResponse, user_data : Void*) : Void
      request_id = nim_response.request_id
      
      # レスポンスをCrystal側の構造体に変換
      response = convert_nim_response(nim_response)
      
      # 登録されたコールバックを呼び出し
      callback = @lock.synchronize do
        @callbacks.delete(request_id)
      end
      
      if callback
        callback.call(response, user_data)
      end
    end
  end
  
  # WebSocketクラス
  class WebSocket
    @manager : NetworkManager
    @websocket : Void*
    @url : String
    @connected : Bool
    
    def initialize(@manager : NetworkManager, @url : String)
      @websocket = NimNetwork.create_websocket(@manager.@network, @url.to_unsafe)
      @connected = false
      
      if @websocket.null?
        raise "WebSocketの作成に失敗しました"
      end
    end
    
    def finalize
      close unless @websocket.null?
    end
    
    # 接続
    def connect(&callback : -> Void) : Bool
      return false if @connected
      
      cb = ->(user_data : Void*) {
        @connected = true
        callback.call
      }
      
      result = NimNetwork.websocket_connect(@manager.@network, @websocket, callback, nil)
      result == 0
    end
    
    # データ送信
    def send(data : String) : Bool
      return false unless @connected
      
      result = NimNetwork.websocket_send(@manager.@network, @websocket, data.to_unsafe, data.bytesize.to_u64)
      result == 0
    end
    
    # クローズ
    def close(code : UInt16 = 1000, reason : String = "") : Void
      return unless @connected
      
      NimNetwork.websocket_close(@manager.@network, @websocket, code, reason.to_unsafe)
      @connected = false
      
      unless @websocket.null?
        NimNetwork.destroy_websocket(@manager.@network, @websocket)
        @websocket = Pointer(Void).null
      end
    end
    
    # 接続状態チェック
    def connected? : Bool
      @connected
    end
  end
end 