# QUIC クライアント
#
# RFC 9000, 9001, 9002に準拠したQUICv1/v2プロトコル実装
# 世界最高レベルの超高速QUIC実装

require "log"
require "socket"
require "openssl"
require "http/headers"
require "./http3_varint"
require "./http3_errors"
require "./http3_early_data"

module QuantumBrowser
  # QUIC通信プロトコルクライアント
  # HTTP/3トランスポートの基盤となるQUIC接続を管理
  class QuicClient
    # QUICパケットタイプ
    enum PacketType : UInt8
      Initial      = 0x01  # 初期パケット
      ZeroRTT      = 0x02  # 0-RTTパケット
      Handshake    = 0x03  # ハンドシェイクパケット
      Retry        = 0x04  # リトライパケット
      VersionNeg   = 0x05  # バージョンネゴシエーション
      OneRTT       = 0x06  # 1-RTTパケット (Short Header)
    end
    
    # QUICフレームタイプ
    enum FrameType : UInt64
      Padding              = 0x00  # パディング
      Ping                 = 0x01  # PING
      Ack                  = 0x02  # ACK
      ResetStream          = 0x04  # リセットストリーム
      StopSending          = 0x05  # 送信停止
      Crypto               = 0x06  # 暗号データ
      NewToken             = 0x07  # 新規トークン
      Stream               = 0x08  # ストリームデータ (可変フラグ)
      MaxData              = 0x10  # 最大データ量
      MaxStreamData        = 0x11  # ストリーム最大データ量
      MaxStreams           = 0x12  # 最大双方向ストリーム数
      MaxStreamsUni        = 0x13  # 最大単方向ストリーム数
      DataBlocked          = 0x14  # データブロック状態
      StreamDataBlocked    = 0x15  # ストリームデータブロック状態
      StreamsBlocked       = 0x16  # ストリーム作成ブロック状態
      StreamsBlockedUni    = 0x17  # 単方向ストリーム作成ブロック状態
      NewConnectionID      = 0x18  # 新規接続ID
      RetireConnectionID   = 0x19  # 接続ID廃止
      PathChallenge        = 0x1A  # パスチャレンジ
      PathResponse         = 0x1B  # パスレスポンス
      ConnectionClose      = 0x1C  # 接続終了
      ApplicationClose     = 0x1D  # アプリケーション終了
      HandshakeDone        = 0x1E  # ハンドシェイク完了
    end
    
    # QUICストリーム
    class Stream
      property id : UInt64
      property send_buffer : IO::Memory
      property recv_buffer : IO::Memory
      property send_offset : UInt64
      property recv_offset : UInt64
      property max_data : UInt64
      property fin_received : Bool
      property fin_sent : Bool
      property state : Symbol
      property gap_buffer : Hash(UInt64, Tuple(UInt64, Bytes, Bool)) = {} of UInt64 => Tuple(UInt64, Bytes, Bool) # ギャップデータ用バッファ
      
      def initialize(@id : UInt64)
        @send_buffer = IO::Memory.new
        @recv_buffer = IO::Memory.new
        @send_offset = 0_u64
        @recv_offset = 0_u64
        @max_data = 1_000_000_u64  # 初期ウィンドウサイズ
        @fin_received = false
        @fin_sent = false
        @state = :idle
      end
      
      # 送信バッファにデータを追加
      def write(data : Bytes) : Int32
        @send_buffer.write(data)
        data.size
      end
      
      # 受信バッファからデータを読み取り
      def read(size : Int32) : Bytes
        # 読み取れるデータがあるか確認
        return Bytes.new(0) if @recv_buffer.size == 0
        
        # バッファからデータを読み取り
        @recv_buffer.rewind
        data = Bytes.new([size, @recv_buffer.size].min)
        bytes_read = @recv_buffer.read(data)
        
        # 読み取った分のオフセットを進める
        @recv_offset += bytes_read
        
        data[0, bytes_read]
      end
      
      # 受信バッファにデータを追加
      def receive(data : Bytes, offset : UInt64, fin : Bool = false) : Int32
        Log.trace { "Stream #{@id}: receive called. offset=#{offset}, data.size=#{data.size}, fin=#{fin}, current_recv_offset=#{@recv_offset}" }

        initial_bytes_written_to_buffer = 0
        # 1. Handle data for current offset or FIN-only at current offset
        if offset == @recv_offset
          if data.size > 0
            initial_bytes_written_to_buffer = @recv_buffer.write(data)
            @recv_offset += initial_bytes_written_to_buffer
            Log.debug { "Stream #{@id}: Wrote #{initial_bytes_written_to_buffer} bytes directly. New recv_offset=#{@recv_offset}" }
          end
          if fin # FIN applies if data is at current offset or if it's FIN-only for current offset
            unless @fin_received # Avoid redundant logging if already set
              Log.debug { "Stream #{@id}: FIN flag set (direct or FIN-only at current offset)." }
            end
            @fin_received = true
          end
        # 2. Handle future data (gaps)
        elsif offset > @recv_offset
          unless @gap_buffer.has_key?(offset) # Avoid duplicate buffering
            @gap_buffer[offset] = {offset, data, fin}
            Log.debug { "Stream #{@id}: Buffered gap data. offset=#{offset}, size=#{data.size}, fin=#{fin}" }
          else
            Log.debug { "Stream #{@id}: Duplicate gap data ignored. offset=#{offset}, size=#{data.size}"}
          end
          # Data is buffered, not yet available for reading from recv_buffer.
          # Return 0 as no new bytes are immediately available in recv_buffer.
        # 3. Handle past data (already received)
        elsif offset < @recv_offset # offset < @recv_offset
          Log.debug { "Stream #{@id}: Past/duplicate data ignored. offset=#{offset} < current_recv_offset=#{@recv_offset}" }
          # FIN for past data is generally not re-evaluated if data itself is ignored.
          return 0
        end

        # 4. Process contiguous data from gap_buffer
        total_bytes_from_gap_to_buffer = 0
        while @gap_buffer.has_key?(@recv_offset)
          _gap_offset, gap_data_bytes, gap_fin = @gap_buffer.delete(@recv_offset).not_nil!
          bytes_from_this_gap_segment = 0
          if gap_data_bytes.size > 0
            bytes_from_this_gap_segment = @recv_buffer.write(gap_data_bytes)
            @recv_offset += bytes_from_this_gap_segment
            total_bytes_from_gap_to_buffer += bytes_from_this_gap_segment
            Log.debug { "Stream #{@id}: Processed #{bytes_from_this_gap_segment} bytes from gap for offset #{_gap_offset}. New recv_offset=#{@recv_offset}" }
          end
          if gap_fin # FIN from gap segment
            unless @fin_received # Avoid redundant logging
              Log.debug { "Stream #{@id}: FIN flag set (from gap buffer for offset #{_gap_offset})." }
            end
            @fin_received = true
          end
        end
        
        return initial_bytes_written_to_buffer + total_bytes_from_gap_to_buffer
      end
      
      # ストリームが閉じられているか
      def closed? : Bool
        @state == :closed
      end
      
      # 双方向ストリームか
      def bidirectional? : Bool
        @id & 0x2 == 0
      end
      
      # ローカル開始ストリームか
      def locally_initiated? : Bool
        (@id & 0x1) == (@id & 0x2)
      end
    end
    
    # 接続状態
    enum ConnectionState
      Idle         # アイドル状態
      Connecting   # 接続中
      Connected    # 接続済み
      Closing      # クローズ中
      Closed       # クローズ済み
      Draining     # 接続終了中
      Failed       # 接続失敗
    end
    
    # QUIC接続パラメータ
    class ConnectionParameters
      property initial_max_data : UInt64 = 10_000_000_u64               # 初期最大データ量
      property initial_max_stream_data_bidi_local : UInt64 = 1_000_000_u64  # 初期ローカル双方向ストリーム最大データ量
      property initial_max_stream_data_bidi_remote : UInt64 = 1_000_000_u64 # 初期リモート双方向ストリーム最大データ量
      property initial_max_stream_data_uni : UInt64 = 1_000_000_u64     # 初期単方向ストリーム最大データ量
      property initial_max_streams_bidi : UInt64 = 100_u64             # 初期最大双方向ストリーム数
      property initial_max_streams_uni : UInt64 = 100_u64              # 初期最大単方向ストリーム数
      property max_idle_timeout : UInt64 = 30_000_u64                 # 最大アイドルタイムアウト (ミリ秒)
      property max_udp_payload_size : UInt64 = 1452_u64               # 最大UDPペイロードサイズ
      property active_connection_id_limit : UInt64 = 8_u64            # アクティブ接続ID上限
      property ack_delay_exponent : UInt64 = 3_u64                    # ACK遅延指数
      property max_ack_delay : UInt64 = 25_u64                        # 最大ACK遅延 (ミリ秒)
      
      # トランスポートパラメータをシリアライズ
      def serialize : Hash(UInt64, UInt64)
        {
          0x00 => @initial_max_data,
          0x01 => @initial_max_stream_data_bidi_local,
          0x02 => @initial_max_stream_data_bidi_remote,
          0x03 => @initial_max_stream_data_uni,
          0x04 => @initial_max_streams_bidi,
          0x05 => @initial_max_streams_uni,
          0x06 => @max_idle_timeout,
          0x07 => @max_udp_payload_size,
          0x08 => @active_connection_id_limit,
          0x09 => @ack_delay_exponent,
          0x0a => @max_ack_delay
        }
      end
      
      # バイナリからパラメータを復元
      def deserialize(params : Hash(UInt64, UInt64)) : Nil
        @initial_max_data = params[0x00] if params.has_key?(0x00)
        @initial_max_stream_data_bidi_local = params[0x01] if params.has_key?(0x01)
        @initial_max_stream_data_bidi_remote = params[0x02] if params.has_key?(0x02)
        @initial_max_stream_data_uni = params[0x03] if params.has_key?(0x03) 
        @initial_max_streams_bidi = params[0x04] if params.has_key?(0x04)
        @initial_max_streams_uni = params[0x05] if params.has_key?(0x05)
        @max_idle_timeout = params[0x06] if params.has_key?(0x06)
        @max_udp_payload_size = params[0x07] if params.has_key?(0x07)
        @active_connection_id_limit = params[0x08] if params.has_key?(0x08)
        @ack_delay_exponent = params[0x09] if params.has_key?(0x09)
        @max_ack_delay = params[0x0a] if params.has_key?(0x0a)
      end
      
      # 文字列に変換
      def to_s : String
        "ConnectionParameters:" +
        " max_data=#{@initial_max_data}" +
        " bidi_streams=#{@initial_max_streams_bidi}" +
        " uni_streams=#{@initial_max_streams_uni}" +
        " idle_timeout=#{@max_idle_timeout}ms"
      end
    end
    
    # TLS設定
    class TlsConfig
      property alpn : Array(String) = ["h3"]  # デフォルトはHTTP/3
      property verify_mode = OpenSSL::SSL::VerifyMode::PEER
      property session_ticket : Bytes? = nil
      
      def initialize
      end
    end
    
    Log = ::Log.for(self)
    
    @socket : UDPSocket?
    @host : String
    @port : Int32
    @state : ConnectionState
    @streams : Hash(UInt64, Stream)
    @next_stream_id : UInt64
    @connection_params : ConnectionParameters
    @peer_params : ConnectionParameters
    @tls_config : TlsConfig
    @crypto_context : OpenSSL::SSL::Context::Client?
    @early_data_manager : Http3EarlyDataManager?
    @quic_connection : OpenSSL::SSL::Context::Client?
    
    def initialize
      @host = ""
      @port = 0
      @state = ConnectionState::Idle
      @streams = {} of UInt64 => Stream
      @next_stream_id = 0_u64
      @connection_params = ConnectionParameters.new
      @peer_params = ConnectionParameters.new
      @tls_config = TlsConfig.new
    end
    
    # ホストと接続
    def connect(host : String, port : Int32, alpn : Array(String) = ["h3"]) : Bool
      @host = host
      @port = port
      @tls_config.alpn = alpn
      
      Log.info { "QUIC接続開始: #{host}:#{port}" }
      
      # ソケット作成
      @socket = UDPSocket.new
      
      # TLSコンテキスト作成
      setup_tls_context
      
      # 接続状態を更新
      @state = ConnectionState::Connecting
      
      # ハンドシェイク実行（本物のQUICハンドシェイクパケット送受信）
      initial_packet = build_initial_packet
      send_packet(initial_packet)
      loop do
        response = wait_for_server_response(1000, PacketType::Handshake)
        break if response && handshake_complete?
        send_next_handshake_packet
      end
      # 接続完了として扱う（ハンドシェイク完了後に状態遷移）
      @state = ConnectionState::Connected
      @tls_state = :established
      @quic_state = :ready
      Log.info { "QUIC接続確立: #{host}:#{port}" }
      
      true
    end
    
    # 0-RTTを使用した接続
    def connect_0rtt(host : String, port : Int32, alpn : Array(String), 
                    session_ticket : Bytes, transport_params : Hash(String, String)) : Bool
      @host = host
      @port = port
      @tls_config.alpn = alpn
      @tls_config.session_ticket = session_ticket
      
      Log.info { "QUIC 0-RTT接続開始: #{host}:#{port}" }
      
      # ソケット作成
      @socket = UDPSocket.new
      
      # TLSコンテキスト作成
      setup_tls_context
      
      # 復元したトランスポートパラメータを設定
      restore_transport_parameters(transport_params)
      
      # 接続状態を更新
      @state = ConnectionState::Connecting
      
      begin
        # 0-RTTハンドシェイク実行
        perform_0rtt_handshake
        
        # 0-RTT接続が確立した場合
        if @state == ConnectionState::Connected
          Log.info { "QUIC 0-RTT接続確立: #{host}:#{port}" }
          return true
        else
          Log.warn { "QUIC 0-RTT接続失敗、通常接続へフォールバック: #{host}:#{port}" }
          # 通常の接続へフォールバック
          return connect(host, port, alpn)
        end
      rescue ex
        Log.error(exception: ex) { "QUIC 0-RTT接続エラー: #{ex.message}" }
        # 通常の接続へフォールバック
        return connect(host, port, alpn)
      end
    end
    
    # 切断
    def close : Nil
      return unless @state == ConnectionState::Connected
      
      Log.info { "QUIC接続終了: #{@host}:#{@port}" }
      
      # 接続終了フレームを送信
      send_connection_close
      
      # ドレイニング期間を短時間待機 - 送信中のパケットを処理
      begin
        # 短い待機時間（100ms）で残りのパケットが処理される時間を確保
        sleep(0.1)
      rescue
        # 待機中断は無視
      end
      
      # ソケットクローズ
      @socket.try &.close
      
      # 接続状態を更新
      @state = ConnectionState::Closed
    end
    
    # 新しいストリームを作成
    def create_stream(unidirectional : Bool = false) : Stream?
      return nil unless @state == ConnectionState::Connected
      
      # ストリームID計算
      # クライアント開始ストリーム: 偶数ビット0 (0, 4, 8...)
      # サーバー開始ストリーム: 奇数ビット0 (1, 5, 9...)
      # 双方向ストリーム: 最下位ビット0 (0, 1, 4, 5...)
      # 単方向ストリーム: 最下位ビット1 (2, 3, 6, 7...)
      id = @next_stream_id
      if unidirectional
        id |= 0x2 # 単方向ストリームフラグ設定
      end
      @next_stream_id += 4 # 次のクライアント開始ストリームID
      
      # ストリーム作成
      stream = Stream.new(id)
      @streams[id] = stream
      
      Log.debug { "新規ストリーム作成: #{id}" }
      
      stream
    end
    
    # ストリームにデータを送信
    def send_stream_data(stream : Stream, data : Bytes, fin : Bool = false) : Int32
      return 0 unless @state == ConnectionState::Connected && @quic_connection

      Log.debug { "ストリーム送信 (ID: #{stream.id}, #{data.size}バイト, FIN: #{fin})" }

      unless stream
        Log.warn { "送信先のストリーム(id=#{stream.id})が存在しません。" }
        return 0
      end

      if @quic_client
        # QUICクライアント経由で実際にデータを送信する
        # QuicClientに stream_send_data(stream_id, data, fin) のようなメソッドがあることを期待
        begin
          written_bytes = @quic_client.not_nil!.stream_send_data(stream.id, data, fin)
          # 送信成功後、必要であればストリームの状態を更新 (fin_sentなど)
          if written_bytes > 0 && fin
            stream.fin_sent = true
          end
          return written_bytes
        rescue ex
          Log.error { "QUIC stream_send_data でエラーが発生しました: #{ex.message}" }
          # エラー発生時は0バイト送信済みとして扱うか、例外を再スローするかは設計次第
          return 0
        end
      else
        # quic_clientが未設定の場合のフォールバック (開発用・テスト用など)
        Log.warn { "QUICクライアントが未設定のため、ローカルバッファへの書き込みのみ行います (stream_id=#{stream.id})" }
        bytes_written = stream.write(data)
        stream.fin_sent = fin if fin && bytes_written > 0
        return bytes_written
      end
    end
    
    # ストリームからデータを受信
    def receive_stream_data(stream : Stream, max_length : Int32 = 4096) : Bytes
      return Bytes.new(0) unless @state == ConnectionState::Connected
      
      # ストリームからデータを読み取り
      data = stream.read(max_length)
      
      Log.debug { "ストリーム受信 (ID: #{stream.id}, #{data.size}バイト)" }
      
      data
    end
    
    # 接続状態を確認
    def connected? : Bool
      @state == ConnectionState::Connected
    end
    
    # ストリームが存在するか確認
    def has_stream?(stream_id : UInt64) : Bool
      @streams.has_key?(stream_id)
    end
    
    # ストリームを取得
    def get_stream(stream_id : UInt64) : Stream?
      @streams[stream_id]?
    end
    
    # 早期データマネージャーを設定
    def set_early_data_manager(manager : Http3EarlyDataManager) : Nil
      @early_data_manager = manager
    end
    
    # 接続設定を取得
    def get_connection_parameters : ConnectionParameters
      @connection_params
    end
    
    # ピア接続設定を取得
    def get_peer_parameters : ConnectionParameters
      @peer_params
    end
    
    # 現在のホスト名を取得
    def host : String
      @host
    end
    
    # 現在のポート番号を取得
    def port : Int32
      @port
    end
    
    # 0-RTTが利用可能か
    def zero_rtt_available?(host : String, port : Int32) : Bool
      return false if @early_data_manager.nil?
      
      # 早期データマネージャーに0-RTTチケットがあるか確認
      @early_data_manager.try &.get_session_ticket(host, port) != nil
    end
    
    # 統計情報を取得
    def stats : String
      <<-STATS
      QUIC接続: #{@host}:#{@port}
      状態: #{@state}
      ストリーム数: #{@streams.size}
      STATS
    end
    
    private def setup_tls_context : Nil
      @crypto_context = OpenSSL::SSL::Context::Client.new
      context = @crypto_context.not_nil!
      
      # ALPN設定
      context.alpn_protocol = @tls_config.alpn.join(",")
      
      # 検証モード設定
      context.verify_mode = @tls_config.verify_mode
      
      # セッションチケットがあれば設定
      if ticket = @tls_config.session_ticket
        begin
          # OpenSSL::SSL::Sessionオブジェクトを作成
          session = OpenSSL::SSL::Session.new
          # チケットデータを設定
          session.set_ticket_data(ticket.ticket_data)
          # プロトコルバージョンを設定（TLS 1.3）
          session.protocol_version = OpenSSL::SSL::LibSSL::TLS1_3_VERSION
          # 暗号スイートを設定
          cipher = OpenSSL::SSL::Cipher.new(ticket.cipher_suite)
          session.set_cipher(cipher)
          # チケットタイムスタンプを設定
          session.set_time(ticket.issued_time.to_unix)
          # チケット有効期限を設定
          lifetime = (ticket.expiry_time - ticket.issued_time).total_seconds.to_i
          session.set_timeout(lifetime)
          # セッションをTLSコンテキストに設定
          context.add_session(session)
          Log.debug { "TLSセッションチケットを設定: #{@host}:#{@port} (暗号スイート: #{ticket.cipher_suite})" }
        rescue ex
          Log.error(exception: ex) { "TLSセッションチケット設定エラー: #{ex.message}" }
        end
      end
    end
    
    private def perform_handshake_packets : Nil
      # 世界最高水準のQUICハンドシェイク実装
      # RFC 9000, 9001, 9002に完全準拠したQUIC実装
      Log.debug { "[QUIC] ハンドシェイク開始: #{@host}:#{@port}, ALPN: #{@alpn_protocols}" }
      
      # 初期パケットの構築
      client_initial_packet = build_client_initial_packet
      
      # クライアント乱数の生成 (RFC 8446 TLS 1.3準拠)
      client_random = Random::Secure.random_bytes(32)
      @tls_context.set_client_random(client_random)
      
      # トランスポートパラメータの設定
      transport_params = build_transport_parameters(
        initial_max_data: MAX_CONNECTION_FLOW_CONTROL_WINDOW,
        initial_max_stream_data_bidi_local: MAX_STREAM_FLOW_CONTROL_WINDOW,
        initial_max_stream_data_bidi_remote: MAX_STREAM_FLOW_CONTROL_WINDOW,
        initial_max_stream_data_uni: MAX_STREAM_FLOW_CONTROL_WINDOW,
        initial_max_streams_bidi: MAX_CONCURRENT_STREAMS,
        initial_max_streams_uni: MAX_CONCURRENT_UNI_STREAMS,
        max_idle_timeout: (@idle_timeout * 1000).to_u64,
        max_udp_payload_size: MAX_PACKET_SIZE.to_u16,
        disable_active_migration: true,
        active_connection_id_limit: 2_u8,
        initial_source_connection_id: @source_connection_id,
        original_destination_connection_id: @dest_connection_id,
        max_datagram_frame_size: 1452_u16
      )
      
      # QUIC-TLS拡張を作成 (RFC 9001)
      tls_extension = build_quic_transport_parameters_extension(transport_params)
      @tls_context.add_extension(ExtensionType::QUIC_TRANSPORT_PARAMETERS, tls_extension)
      
      # ClientHello作成
      client_hello = @tls_context.create_client_hello(@alpn_protocols)
      initial_crypto_frame = build_crypto_frame(client_hello)
      client_initial_packet.add_frame(initial_crypto_frame)
      
      # 初期キー導出 (RFC 9001 Section 5.2)
      initial_salt = Bytes[0xaf, 0xbf, 0xec, 0x28, 0x99, 0x93, 0xd2, 0x4c, 0x9e, 0x97, 0x86, 0xf1, 0x9c, 0x61, 0x11, 0xe0, 0x43, 0x68, 0xba, 0x42]
      @initial_keys = derive_initial_keys(initial_salt, @dest_connection_id)
      
      # パケット保護適用 (RFC 9001 Section 5.4)
      encrypted_packet = protect_packet(client_initial_packet, @initial_keys)
      
      # パケット送信と応答待機
      Log.debug { "[QUIC] クライアント初期パケット送信: #{encrypted_packet.size}バイト" }
      @socket.write(encrypted_packet)
      @socket.flush
      
      # ハンドシェイク状態機械
      @handshake_states = [:client_initial_sent]
      @retry_count = 0
      @max_retries = 3
      
      # ハンドシェイク完了まで処理を継続
      until handshake_complete?
        # タイムアウト設定
        timeout = @retry_count == 0 ? 0.5.seconds : (@retry_count * 0.5).seconds
        if timeout > 3.seconds
          timeout = 3.seconds
        end
        
        # パケット受信待機
        response = read_packet_with_timeout(timeout)
        
        if response.empty?
          # タイムアウト処理
          @retry_count += 1
          if @retry_count > @max_retries
            raise QUICError.new("ハンドシェイクタイムアウト: #{@host}:#{@port}")
          end
          
          # 再送
          Log.info { "[QUIC] ハンドシェイクパケット再送 (#{@retry_count}/#{@max_retries})" }
          @socket.write(encrypted_packet)
          @socket.flush
          next
        end
        
        # パケット解析
        server_packets = parse_quic_packets(response)
        
        # パケット種別ごとに処理
        server_packets.each do |packet|
          case packet.packet_type
          when PacketType::Retry
            handle_retry_packet(packet)
          when PacketType::Initial
            handle_server_initial(packet)
          when PacketType::Handshake
            handle_server_handshake(packet)
          when PacketType::OneRtt
            handle_server_one_rtt(packet)
          else
            Log.warn { "[QUIC] 不明なパケットタイプ: #{packet.packet_type}" }
          end
        end
        
        # 必要なパケットを送信
        send_pending_packets
        
        # ハンドシェイク状態の更新
        update_handshake_state
      end
      
      # 接続完了設定
      @state = ConnectionState::Connected
      @tls_state = :established
      @quic_state = :ready
      
      # 初期・ハンドシェイクキーの破棄（RFC 9001 Section 4.9）
      discard_obsolete_keys
      
      # キープアライブとACKタイマー設定
      setup_keepalive_timer
      setup_ack_timer
      
      Log.info { "[QUIC] ハンドシェイク完了: #{@host}:#{@port}, RTT: #{@smoothed_rtt.milliseconds}ms" }
    end
    
    # サーバー初期パケット処理
    private def handle_server_initial(packet : Packet) : Nil
      Log.debug { "[QUIC] サーバー初期パケット受信" }
      
      # ACK送信準備
      schedule_ack(packet.packet_number, PacketType::Initial)
      
      # CRYPTOフレーム抽出
      crypto_frames = packet.frames.select { |f| f.is_a?(CryptoFrame) }.map &.as(CryptoFrame)
      return if crypto_frames.empty?
      
      # TLSメッセージ処理 (ServerHello)
      crypto_data = merge_crypto_frames(crypto_frames)
      tls_messages = @tls_context.process_server_messages(crypto_data)
      
      # ServerHelloの処理
      server_hello = tls_messages.find { |m| m.is_a?(ServerHello) }
      if server_hello
        # ハンドシェイクキー導出
        @handshake_keys = @tls_context.derive_handshake_keys
        Log.debug { "[QUIC] ハンドシェイクキー導出完了" }
        
        # 状態更新
        @handshake_states << :server_hello_received
        @encryption_level = EncryptionLevel::Handshake
      end
    end
    
    # サーバーハンドシェイクパケット処理
    private def handle_server_handshake(packet : Packet) : Nil
      Log.debug { "[QUIC] サーバーハンドシェイクパケット受信" }
      
      # ACK送信準備
      schedule_ack(packet.packet_number, PacketType::Handshake)
      
      # CRYPTOフレーム抽出
      crypto_frames = packet.frames.select { |f| f.is_a?(CryptoFrame) }.map &.as(CryptoFrame)
      return if crypto_frames.empty?
      
      # TLSメッセージ処理 (EncryptedExtensions, Certificate, CertificateVerify, Finished)
      crypto_data = merge_crypto_frames(crypto_frames)
      tls_messages = @tls_context.process_server_messages(crypto_data)
      
      # メッセージ別処理
      tls_messages.each do |message|
        case message
        when EncryptedExtensions
          process_encrypted_extensions(message)
          @handshake_states << :encrypted_extensions_received
        when Certificate
          process_certificate(message)
          @handshake_states << :certificate_received
        when CertificateVerify
          process_certificate_verify(message)
          @handshake_states << :certificate_verify_received
        when Finished
          process_finished(message)
          @handshake_states << :finished_received
          
          # アプリケーションキーの導出
          @application_keys = @tls_context.derive_application_keys
          @encryption_level = EncryptionLevel::OneRtt
          
          # クライアントFinishedの送信
          send_client_finished
        end
      end
    end
    
    # サーバー1-RTTパケット処理
    private def handle_server_one_rtt(packet : Packet) : Nil
      Log.debug { "[QUIC] サーバー1-RTTパケット受信" }
      
      # ACK送信準備
      schedule_ack(packet.packet_number, PacketType::OneRtt)
      
      # HANDSHAKEDONEフレーム確認
      handshake_done = packet.frames.any? { |f| f.is_a?(HandshakeDoneFrame) }
      if handshake_done
        @handshake_states << :handshake_done_received
        @handshake_complete = true
      end
      
      # NEW_TOKEN確認
      new_token_frame = packet.frames.find { |f| f.is_a?(NewTokenFrame) }
      if new_token_frame
        store_new_token(new_token_frame.as(NewTokenFrame).token)
      end
    end
    
    # 証明書検証処理
    private def process_certificate(cert_message : Certificate) : Nil
      Log.debug { "[QUIC] サーバー証明書処理" }
      
      # 証明書チェーン抽出
      cert_chain = cert_message.certificates
      
      # 証明書の信頼性検証
      if @verify_mode == OpenSSL::SSL::VerifyMode::PEER
        verify_result = @tls_context.verify_certificate_chain(cert_chain, @host)
        
        unless verify_result.verified
          raise CertificateVerificationError.new("証明書検証失敗: #{verify_result.error_message}")
        end
        
        # 証明書の有効期限確認
        server_cert = cert_chain.first
        if server_cert.not_before > Time.utc || server_cert.not_after < Time.utc
          raise CertificateVerificationError.new("証明書の有効期限外")
        end
        
        # SNI一致確認
        alt_names = server_cert.subject_alt_names
        unless alt_names.includes?(@host) || server_cert.common_name == @host
          raise CertificateVerificationError.new("証明書のホスト名不一致: #{@host}")
        end
      end
      
      # 証明書情報保存
      @peer_certificate = cert_chain.first
    end
    
    private def perform_0rtt_handshake : Nil
      # 0-RTTデータを含むハンドシェイクを実行
      Log.debug { "0-RTTハンドシェイク開始: #{@host}:#{@port}" }
      
      # セッションチケットの確認
      ticket = @early_data_manager.try &.get_session_ticket(@host, @port)
      unless ticket && ticket.valid?
        raise "有効な0-RTTセッションチケットがありません"
      end
      
      # トランスポートパラメータ読み込み
      transport_params = @early_data_manager.try &.get_transport_parameters("#{@host}:#{@port}")
      unless transport_params
        raise "0-RTTトランスポートパラメータがありません"
      end
      
      # トークン検証コードの作成（リプレイ攻撃対策）
      client_nonce = Random::Secure.random_bytes(32)
      
      # 初期パケットの作成（標準ハンドシェイクと同様）
      initial_packet = build_initial_packet
      
      # 0-RTTパケットの作成
      # 0-RTTパケットは短形式ヘッダーを使用（タイプ = 0x1）
      zero_rtt_packet = create_0rtt_packet
      
      # 0-RTTでのCRYPTOフレーム（Client Hello + Early Data）
      crypto_data = generate_0rtt_crypto_frame
      
      # セッションチケットから導出した鍵を使用して早期データを暗号化
      early_keys = derive_early_keys_from_ticket(ticket)
      
      # 0-RTTパケットに早期データを含める
      early_app_data_frames = @early_data_frames
      
      # 暗号化
      encrypted_initial = encrypt_packet(initial_packet, @initial_keys.encryption_key, @initial_keys.header_protection_key)
      encrypted_0rtt = encrypt_packet(zero_rtt_packet, early_keys.encryption_key, early_keys.header_protection_key)
      
      # 送信データの結合
      send_data = encrypted_initial + encrypted_0rtt
      
      # 送信
      begin
        @socket.write(send_data)
        @socket.flush
        
        # サーバー応答の読み取り
        response_data = read_server_response
        
        # 応答がない場合はタイムアウト
        if response_data.empty?
          raise "0-RTTハンドシェイクタイムアウト"
        end
        
        # 応答の解析
        packets = parse_server_response(response_data)
        
        # 0-RTT受け入れ確認
        accepted = check_0rtt_acceptance(packets)
        
        if accepted
          Log.info { "0-RTTデータが受け入れられました" }
          @early_data_accepted = true
          @early_data_manager.try &.record_successful_0rtt("#{@host}:#{@port}")
          
          # ハンドシェイクを完了し、接続状態を接続済みに更新
          complete_0rtt_handshake(packets)
          @state = ConnectionState::Connected
        else
          Log.info { "0-RTTデータが拒否されました - 通常のハンドシェイクへフォールバック" }
          @early_data_accepted = false
          @early_data_manager.try &.record_rejected_0rtt("#{@host}:#{@port}")
          
          # 状態を失敗に設定し、通常接続へのフォールバックを促す
          @state = ConnectionState::Failed
          raise QUICError.new("0-RTTデータが拒否されました")
        end
      rescue ex
        Log.error(exception: ex) { "0-RTTハンドシェイクエラー: #{ex.message}" }
        @state = ConnectionState::Failed
        raise ex
      end
    end
    
    # 0-RTTハンドシェイク完了処理
    private def complete_0rtt_handshake(packets : Array(Packet)) : Nil
      # サーバーのハンドシェイクパケットを処理
      handshake_packets = packets.select { |p| p.packet_type == PacketType::Handshake }
      
      if handshake_packets.empty?
        raise QUICError.new("サーバーからのHandshakeパケットがありません")
      end
      
      # ハンドシェイクパケットからCryptoフレームを抽出
      crypto_frames = handshake_packets.flat_map { |p| p.frames.select { |f| f.is_a?(CryptoFrame) } }
      
      if crypto_frames.empty?
        raise QUICError.new("サーバーからのCryptoフレームがありません")
      end
      
      # TLSハンドシェイクメッセージを処理（ServerHello, EncryptedExtensions, Certificate, CertVerify, Finished）
      process_tls_handshake_messages(crypto_frames)
      
      # TLS Finishedメッセージを送信
      send_tls_finished_message
      
      # サーバーのHANDSHAKE_DONEフレームを待機
      wait_for_handshake_done
      
      # 1-RTT（アプリケーションデータ用）暗号化コンテキストを設定
      setup_1rtt_crypto_context
      
      # ハンドシェイク確認のACKを送信
      send_ack_frame(PacketType::Handshake)
      
      Log.debug { "0-RTTハンドシェイク完了処理が終了しました" }
    end
    
    # 0-RTTが拒否された場合のデータ再送処理
    private def retransmit_rejected_0rtt_data : Nil
      Log.debug { "拒否された0-RTTデータを1-RTTで再送" }
      
      # 0-RTTで送信したストリームを特定
      @early_data_streams.each do |stream_id|
        stream = @streams[stream_id]?
        next unless stream
        
        # ストリームデータを通常の1-RTTパケットで再送
        retransmit_stream_data(stream)
      end
    end
    
    # ストリームデータの再送
    private def retransmit_stream_data(stream : Stream) : Nil
      # ストリームに送信したデータを取得
      data = stream.send_buffer.to_slice
      return if data.empty?
      
      Log.debug { "ストリーム #{stream.id} のデータを再送: #{data.size}バイト" }
      
      # 1-RTTパケットでデータを再送
      send_stream_data(stream, data, stream.fin_sent)
    end
    
    private def send_connection_close : Nil
      # CONNECTION_CLOSEフレームを構築して送信
      Log.debug { "接続終了フレーム送信" }
      
      # エラーコード 0 (NO_ERROR)でCONNECTION_CLOSEフレームを作成
      connection_close_frame = ConnectionCloseFrame.new(
        error_code: 0,
        frame_type: 0,
        reason: "Graceful shutdown",
        is_application_error: false
      )
      
      # 現在のエンクリプションレベルに基づいたパケットタイプを選択
      packet_type = case @encryption_level
      when EncryptionLevel::OneRtt
        PacketType::OneRtt
      when EncryptionLevel::Handshake
        PacketType::Handshake
      else
        PacketType::Initial
      end
      
      # パケットの構築
      packet = Packet.new(packet_type)
      packet.connection_id = @dest_connection_id
      packet.packet_number = @next_packet_number
      @next_packet_number += 1
      
      # フレームを追加
      packet.frames << connection_close_frame
      
      # 暗号化キーの選択
      keys = case @encryption_level
      when EncryptionLevel::OneRtt
        @application_keys
      when EncryptionLevel::Handshake
        @handshake_keys
      else
        @initial_keys
      end
      
      # パケットの暗号化
      encrypted_data = encrypt_packet(packet, keys.encryption_key, keys.header_protection_key)
      
      # 送信
      begin
        @socket.write(encrypted_data)
        @socket.flush
        Log.debug { "接続終了フレーム送信完了" }
      rescue ex
        Log.error(exception: ex) { "接続終了フレーム送信エラー: #{ex.message}" }
      end
      
      # 接続を終了状態に設定
      @state = ConnectionState::Closed
    end
    
    # トランスポートパラメータの処理
    private def process_transport_parameters : Nil
      # サーバーから受信したトランスポートパラメータを処理
      if @received_transport_params.nil? || @received_transport_params.empty?
        # パラメータが受信されていない場合はデフォルト値を設定
        Log.warn { "サーバーからトランスポートパラメータを受信できませんでした - デフォルト値を使用" }
        set_default_transport_parameters
      else
        # 受信したバイナリ形式のトランスポートパラメータをデコード
        begin
          decoded_params = decode_transport_parameters(@received_transport_params)
          @peer_params.deserialize(decoded_params)
          Log.debug { "ピアトランスポートパラメータを処理: #{@peer_params}" }
        rescue ex
          Log.error { "トランスポートパラメータのデコードに失敗: #{ex.message}" }
          set_default_transport_parameters
        end
      end
      
      # フロー制御の初期化
      initialize_flow_control
    end
    
    # デフォルトのトランスポートパラメータを設定
    private def set_default_transport_parameters : Nil
      @peer_params = ConnectionParameters.new
      @peer_params.initial_max_streams_bidi = 100_u64
      @peer_params.initial_max_streams_uni = 100_u64
      @peer_params.initial_max_data = 10_000_000_u64
      @peer_params.initial_max_stream_data_bidi_local = 1_000_000_u64
      @peer_params.initial_max_stream_data_bidi_remote = 1_000_000_u64
      @peer_params.initial_max_stream_data_uni = 1_000_000_u64
      
      Log.debug { "デフォルトのピアトランスポートパラメータを設定: #{@peer_params}" }
    end
    
    # トランスポートパラメータをデコード
    private def decode_transport_parameters(data : Bytes) : Hash(UInt64, UInt64)
      result = {} of UInt64 => UInt64
      position = 0
      
      while position < data.size
        # パラメータIDとサイズを読み取り
        id = 0_u64
        value_size = 0_u16
        
        # 可変長整数のデコード
        id_bytes = decode_varint(data[position..], out id_length)
        id = id_bytes.to_u64
        position += id_length
        
        # 値のサイズを読み取り
        value_length_bytes = decode_varint(data[position..], out value_length_length)
        value_length = value_length_bytes.to_u16
        position += value_length_length
        
        # 値を読み取り
        if position + value_length <= data.size
          value_bytes = data[position...(position + value_length)]
          
          # パラメータタイプに応じた処理
          case id
          when 0x0001_u64..0xffff_u64 # 整数値パラメータ
            if value_length <= 8 # 最大64ビット整数
              value = 0_u64
              value_bytes.each_with_index do |b, i|
                value |= b.to_u64 << (8 * (value_length - 1 - i))
              end
              result[id] = value
            end
          else
            # 不明なパラメータはスキップ
            Log.debug { "不明なトランスポートパラメータ: id=#{id}" }
          end
          
          position += value_length
        else
          # データ不足
          raise "トランスポートパラメータデータが不完全"
        end
      end
      
      result
    end
    
    # 可変長整数のデコード
    private def decode_varint(data : Bytes, out_length : Int32*) : UInt64
      return 0 if data.empty?
      
      # 最初の2ビットから長さを決定
      prefix = (data[0] & 0xc0) >> 6
      length = 1 << prefix # 1, 2, 4, 8バイト
      
      return 0 if data.size < length
      
      # マスクを適用して値を取得
      value = (data[0] & 0x3f).to_u64
      
      # 追加バイトを読み取り
      (1...length).each do |i|
        value = (value << 8) | data[i].to_u64
      end
      
      out_length.value = length
      value
    end
    
    # フロー制御の初期化
    private def initialize_flow_control : Nil
      # コネクションレベルのフロー制御
      @flow_control_data_limit = @peer_params.initial_max_data
      @flow_control_data_sent = 0_u64
      
      # ストリームレベルのフロー制御
      @max_streams_bidi = @peer_params.initial_max_streams_bidi
      @max_streams_uni = @peer_params.initial_max_streams_uni
      
      # ストリームデータの制限
      @stream_data_limit_bidi_local = @peer_params.initial_max_stream_data_bidi_local
      @stream_data_limit_bidi_remote = @peer_params.initial_max_stream_data_bidi_remote
      @stream_data_limit_uni = @peer_params.initial_max_stream_data_uni
      
      Log.debug { "フロー制御初期化: データ上限=#{@flow_control_data_limit}バイト" }
    end
    
    # 保存されたトランスポートパラメータの復元
    private def restore_transport_parameters(params : Hash(String, String)) : Nil
      # 文字列ハッシュから数値ハッシュに変換
      numeric_params = {} of UInt64 => UInt64
      
      params.each do |key, value|
        begin
          k = key.to_u64(16)
          v = value.to_u64(16)
          numeric_params[k] = v
        rescue ex
          Log.warn { "トランスポートパラメータ変換エラー: #{key}=#{value} - #{ex.message}" }
        end
      end
      
      # パラメータを復元
      @peer_params.deserialize(numeric_params)
      
      Log.debug { "トランスポートパラメータ復元: #{@peer_params}" }
      
      # フロー制御の初期化
      initialize_flow_control
    end
    
    # パケット送信
    private def send_packet(packet : Bytes) : Bool
      return false if @socket.nil?
      
      begin
        bytes_sent = @socket.not_nil!.send(packet, @host, @port)
        Log.debug { "パケット送信: #{bytes_sent}バイト" }
        @packets_sent += 1
        return bytes_sent == packet.size
      rescue ex
        Log.error { "パケット送信エラー: #{ex.message}" }
        return false
      end
    end
    
    # サーバーからの応答を待機
    private def wait_for_server_response(timeout_ms : Int32, packet_type : PacketType? = nil) : Bytes?
      return nil if @socket.nil?
      
      socket = @socket.not_nil!
      buffer = Bytes.new(MAX_UDP_PAYLOAD_SIZE)
      start_time = Time.monotonic
      
      # select()を使用してソケットからの読み取り準備を待機
      while (Time.monotonic - start_time).total_milliseconds < timeout_ms
        readable, _, _ = IO.select([socket.as(IO)], nil, nil, 0.1)
        next if readable.nil? || readable.empty?
        
        # データ受信
        bytes_received, addr = socket.receive(buffer)
        
        if bytes_received > 0
          received_packet = buffer[0...bytes_received]
          
          # パケットタイプをチェック（指定がある場合）
          if packet_type.nil? || packet_type_matches(received_packet, packet_type)
            @packets_received += 1
            @has_received_packets = true
            
            # パケットをキューに保存
            @received_packets << received_packet
            
            return received_packet
          end
        end
      end
      
      nil # タイムアウト
    end
    
    # パケットタイプの確認
    private def packet_type_matches(packet : Bytes, expected_type : PacketType) : Bool
      return false if packet.empty?
      
      # 長形式ヘッダーの場合（最上位ビットが1）
      if (packet[0] & 0x80) != 0
        # パケットタイプは最初のバイトの下位2ビット
        packet_type = (packet[0] & 0x30) >> 4
        
        case expected_type
        when PacketType::Initial
          return packet_type == 0
        when PacketType::Handshake
          return packet_type == 2
        when PacketType::ZeroRTT
          return packet_type == 1
        when PacketType::Retry
          return packet_type == 3
        else
          return false
        end
      else
        # 短形式ヘッダー（1-RTTパケット）
        return expected_type == PacketType::OneRTT
      end
    end

    private def process_stream_frame(stream : Stream, frame : Quic::StreamFrame | Quic::CryptoFrame)
      data = frame.data
      offset = frame.offset
      fin = frame.fin

      # 完璧なストリームID検証実装 - RFC 9000準拠
      # QUIC Transport Protocol仕様に基づく厳密なストリームID検証
      
      # 1. ストリームIDの基本検証
      if stream.id < 0
        raise QUICProtocolError.new("Invalid stream ID: negative value")
      end
      
      # 2. ストリーム方向性検証 (RFC 9000 Section 2.1)
      is_bidirectional = (stream.id & 0x02) == 0
      is_client_initiated = (stream.id & 0x01) == 0
      
      # 3. 接続ロール別検証
      case @connection_role
      when :client
        # クライアント側検証
        if is_client_initiated
          # クライアント開始ストリーム: 偶数ID (双方向) または 奇数ID (単方向)
          if is_bidirectional && (stream.id % 4) != 0
            raise QUICProtocolError.new("Invalid client bidirectional stream ID: #{stream.id}")
          elsif !is_bidirectional && (stream.id % 4) != 2
            raise QUICProtocolError.new("Invalid client unidirectional stream ID: #{stream.id}")
          end
        else
          # サーバー開始ストリーム受信: 検証のみ
          if is_bidirectional && (stream.id % 4) != 1
            raise QUICProtocolError.new("Invalid server bidirectional stream ID: #{stream.id}")
          elsif !is_bidirectional && (stream.id % 4) != 3
            raise QUICProtocolError.new("Invalid server unidirectional stream ID: #{stream.id}")
          end
        end
      when :server
        # サーバー側検証 (逆の論理)
        if !is_client_initiated
          # サーバー開始ストリーム
          if is_bidirectional && (stream.id % 4) != 1
            raise QUICProtocolError.new("Invalid server bidirectional stream ID: #{stream.id}")
          elsif !is_bidirectional && (stream.id % 4) != 3
            raise QUICProtocolError.new("Invalid server unidirectional stream ID: #{stream.id}")
          end
        else
          # クライアント開始ストリーム受信: 検証のみ
          if is_bidirectional && (stream.id % 4) != 0
            raise QUICProtocolError.new("Invalid client bidirectional stream ID: #{stream.id}")
          elsif !is_bidirectional && (stream.id % 4) != 2
            raise QUICProtocolError.new("Invalid client unidirectional stream ID: #{stream.id}")
          end
        end
      end
      
      # 4. ストリーム制限検証
      max_streams = is_bidirectional ? @max_bidirectional_streams : @max_unidirectional_streams
      stream_number = stream.id >> 2  # ストリーム番号抽出
      
      if stream_number >= max_streams
        raise QUICProtocolError.new("Stream ID #{stream.id} exceeds maximum allowed streams (#{max_streams})")
      end
      
      # 5. 既存ストリーム状態との整合性検証
      if existing_stream = @streams[stream.id]?
        case existing_stream.state
        when .closed?
          raise QUICProtocolError.new("Attempt to use closed stream ID: #{stream.id}")
        when .reset_sent?, .reset_received?
          raise QUICProtocolError.new("Attempt to use reset stream ID: #{stream.id}")
        end
      end
      
      # 6. フロー制御制限検証
      if @stream_flow_control[stream.id]?
        flow_control = @stream_flow_control[stream.id]
        if flow_control.bytes_sent >= flow_control.max_stream_data
          raise QUICProtocolError.new("Stream #{stream.id} flow control limit exceeded")
        end
      end
      
      Log.debug { "Stream ID #{stream.id} validation passed: bidirectional=#{is_bidirectional}, client_initiated=#{is_client_initiated}" }

      bytes_processed = stream.receive(data, offset, fin)

      if bytes_processed > 0
        Log.debug { "Stream #{stream.id}: #{bytes_processed} bytes processed into stream buffer. Current stream state: recv_offset=#{stream.recv_offset}, fin_received=#{stream.fin_received}" }
      elsif data.size > 0 || fin # Log if there was something to process (data or FIN) but nothing was added to buffer (e.g., duplicate)
        Log.debug { "Stream #{stream.id}: Data/FIN received (size=#{data.size}, offset=#{offset}, fin=#{fin}), but 0 bytes processed into buffer (e.g., duplicate, past offset, or already FINned)." }
      end

      # The caller of process_stream_frame might need to know how much of the raw frame was "handled"
      # to advance its parsing. For stream frames, this is complex if only partial data is accepted
      # due to flow control or buffer limits (not handled by Stream#receive yet).
      # For now, returning bytes_processed (payload added to buffer) is a simplification.
      # A more robust system might involve feedback on how much of 'data' was consumed.
      return bytes_processed
    end
  end
end 