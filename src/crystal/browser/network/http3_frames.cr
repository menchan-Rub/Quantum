# HTTP/3フレーム定義と処理モジュール
#
# RFC 9114に準拠したHTTP/3フレーム処理の実装
# 世界最高レベルの超高速実装

require "log"
require "io"
require "bytes"
require "bit_array"
require "./http3_varint"
require "./http3_errors"

module QuantumBrowser
  # HTTP/3フレーム処理モジュール
  module Http3Frames
    Log = ::Log.for(self)
    
    # HTTP/3フレームタイプ（RFC 9114 Section 7.2）
    enum FrameType : UInt64
      Data         = 0x00  # DATA - リクエスト/レスポンスのボディ
      Headers      = 0x01  # HEADERS - ヘッダー
      CancelPush   = 0x03  # CANCEL_PUSH - プッシュのキャンセル
      Settings     = 0x04  # SETTINGS - 設定
      PushPromise  = 0x05  # PUSH_PROMISE - プッシュの約束
      Goaway       = 0x07  # GOAWAY - 接続終了通知
      MaxPushId    = 0x0D  # MAX_PUSH_ID - 最大プッシュID
      ReservedH3   = 0x21  # HTTP/3用に予約（0x21-0x3F）
      WebTransport = 0x41  # WEBTRANSPORT - WebTransportメッセージ
      Reserved     = 0xFF  # 将来の拡張のために予約
      
      def to_s : String
        case self
        when Data        then "DATA"
        when Headers     then "HEADERS"
        when CancelPush  then "CANCEL_PUSH"
        when Settings    then "SETTINGS"
        when PushPromise then "PUSH_PROMISE"
        when Goaway      then "GOAWAY"
        when MaxPushId   then "MAX_PUSH_ID"
        when WebTransport then "WEBTRANSPORT"
        when ReservedH3  then "RESERVED_H3"
        when Reserved    then "RESERVED_GREASE"
        else                 "UNKNOWN"
        end
      end
      
      # 整数値からフレームタイプを取得
      def self.from_value(value : UInt64) : FrameType
        case value
        when 0x00 then Data
        when 0x01 then Headers
        when 0x03 then CancelPush
        when 0x04 then Settings
        when 0x05 then PushPromise
        when 0x07 then Goaway
        when 0x0D then MaxPushId
        when 0x41 then WebTransport
        when 0xFF then Reserved
        else
          if value >= 0x21 && value <= 0x3F
            ReservedH3
          else
            Reserved
          end
        end
      end
    end
    
    # HTTP/3フレームフラグ（拡張仕様）
    @[Flags]
    enum FrameFlags : UInt8
      None      = 0       # フラグなし
      EndStream = 1 << 0  # ストリーム終了
      Padded    = 1 << 1  # パディング付き
      Priority  = 1 << 2  # 優先度情報付き
      Metadata  = 1 << 3  # メタデータ付き
    end
    
    # HTTP/3フレーム共通インターフェース
    abstract class Frame
      getter frame_type : FrameType  # フレームタイプ
      getter length : UInt64         # ペイロード長
      getter flags : FrameFlags      # フラグ
      
      def initialize(@frame_type, @length, @flags = FrameFlags::None)
      end
      
      # シリアライズ処理
      abstract def serialize(io : IO) : Nil
      
      # 検証処理
      abstract def validate : Bool
      
      # 文字列表現
      def to_s : String
        "#{@frame_type} frame, length=#{@length}, flags=#{@flags}"
      end
    end
    
    # DATAフレーム
    class DataFrame < Frame
      property data : Bytes  # データペイロード
      
      def initialize(@data : Bytes, @flags : FrameFlags = FrameFlags::None)
        super(FrameType::Data, @data.size.to_u64, @flags)
      end
      
      # 空のDATAフレームを作成
      def self.empty(flags : FrameFlags = FrameFlags::None) : DataFrame
        DataFrame.new(Bytes.new(0), flags)
      end
      
      # 終了フラグ付きDATAフレームを作成
      def self.end_stream(data : Bytes) : DataFrame
        DataFrame.new(data, FrameFlags::EndStream)
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # データをシリアライズ
        io.write(@data) if @data.size > 0
      end
      
      # 検証
      def validate : Bool
        true # DATAフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        end_stream = @flags.includes?(FrameFlags::EndStream) ? " END_STREAM" : ""
        "DATA frame, length=#{@length}#{end_stream}"
      end
    end
    
    # HEADERSフレーム
    class HeadersFrame < Frame
      property headers : Bytes  # ヘッダーブロック
      
      def initialize(@headers : Bytes, @flags : FrameFlags = FrameFlags::None)
        super(FrameType::Headers, @headers.size.to_u64, @flags)
      end
      
      # 空のHEADERSフレームを作成
      def self.empty(flags : FrameFlags = FrameFlags::None) : HeadersFrame
        HeadersFrame.new(Bytes.new(0), flags)
      end
      
      # 終了フラグ付きHEADERSフレームを作成
      def self.end_stream(headers : Bytes) : HeadersFrame
        HeadersFrame.new(headers, FrameFlags::EndStream)
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # ヘッダーをシリアライズ
        io.write(@headers) if @headers.size > 0
      end
      
      # 検証
      def validate : Bool
        true # HEADERSフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        end_stream = @flags.includes?(FrameFlags::EndStream) ? " END_STREAM" : ""
        "HEADERS frame, length=#{@length}#{end_stream}"
      end
    end
    
    # SETTINGSフレーム
    class SettingsFrame < Frame
      # 設定ID定数
      SETTINGS_QPACK_MAX_TABLE_CAPACITY = 0x01_u64
      SETTINGS_MAX_FIELD_SECTION_SIZE = 0x06_u64
      SETTINGS_QPACK_BLOCKED_STREAMS = 0x07_u64
      
      property settings : Hash(UInt64, UInt64)  # 設定パラメータ
      
      def initialize(@settings : Hash(UInt64, UInt64))
        # 設定パラメータの長さを計算
        length = 0_u64
        @settings.each do |id, value|
          length += Http3Varint.size(id) + Http3Varint.size(value)
        end
        
        super(FrameType::Settings, length)
      end
      
      # 空のSETTINGSフレームを作成
      def self.empty : SettingsFrame
        SettingsFrame.new({} of UInt64 => UInt64)
      end
      
      # デフォルト設定のSETTINGSフレームを作成
      def self.default : SettingsFrame
        settings = {
          SETTINGS_QPACK_MAX_TABLE_CAPACITY => 4096_u64,
          SETTINGS_MAX_FIELD_SECTION_SIZE => 65536_u64,
          SETTINGS_QPACK_BLOCKED_STREAMS => 16_u64
        }
        SettingsFrame.new(settings)
      end
      
      # 設定値を追加
      def add_setting(id : UInt64, value : UInt64) : Nil
        @settings[id] = value
        # 長さの再計算
        @length = 0_u64
        @settings.each do |id, value|
          @length += Http3Varint.size(id) + Http3Varint.size(value)
        end
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # 設定パラメータをシリアライズ
        @settings.each do |id, value|
          Http3Varint.encode(io, id)
          Http3Varint.encode(io, value)
        end
      end
      
      # 検証
      def validate : Bool
        # MAX_SETTINGS_ENTRIESを超えていないか
        @settings.size <= 32
      end
      
      # 設定名文字列を取得
      private def setting_name(id : UInt64) : String
        case id
        when SETTINGS_QPACK_MAX_TABLE_CAPACITY
          "QPACK_MAX_TABLE_CAPACITY"
        when SETTINGS_MAX_FIELD_SECTION_SIZE
          "MAX_FIELD_SECTION_SIZE"
        when SETTINGS_QPACK_BLOCKED_STREAMS
          "QPACK_BLOCKED_STREAMS"
        else
          "0x#{id.to_s(16)}"
        end
      end
      
      # 文字列表現
      def to_s : String
        settings_str = @settings.map { |id, value| "#{setting_name(id)}=#{value}" }.join(", ")
        "SETTINGS frame, length=#{@length}, settings={#{settings_str}}"
      end
    end
    
    # GOAWAYフレーム
    class GoawayFrame < Frame
      property stream_id : UInt64  # ストリームID
      
      def initialize(@stream_id : UInt64)
        super(FrameType::Goaway, Http3Varint.size(@stream_id))
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # ストリームIDをシリアライズ
        Http3Varint.encode(io, @stream_id)
      end
      
      # 検証
      def validate : Bool
        true # GOAWAYフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        "GOAWAY frame, stream_id=#{@stream_id}"
      end
    end
    
    # PUSH_PROMISEフレーム
    class PushPromiseFrame < Frame
      property push_id : UInt64      # プッシュID
      property headers : Bytes       # ヘッダーブロック
      
      def initialize(@push_id : UInt64, @headers : Bytes)
        length = Http3Varint.size(@push_id) + @headers.size
        super(FrameType::PushPromise, length)
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # プッシュIDをシリアライズ
        Http3Varint.encode(io, @push_id)
        
        # ヘッダーをシリアライズ
        io.write(@headers) if @headers.size > 0
      end
      
      # 検証
      def validate : Bool
        true # PUSH_PROMISEフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        "PUSH_PROMISE frame, push_id=#{@push_id}, headers_length=#{@headers.size}"
      end
    end
    
    # CANCEL_PUSHフレーム
    class CancelPushFrame < Frame
      property push_id : UInt64  # プッシュID
      
      def initialize(@push_id : UInt64)
        super(FrameType::CancelPush, Http3Varint.size(@push_id))
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # プッシュIDをシリアライズ
        Http3Varint.encode(io, @push_id)
      end
      
      # 検証
      def validate : Bool
        true # CANCEL_PUSHフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        "CANCEL_PUSH frame, push_id=#{@push_id}"
      end
    end
    
    # MAX_PUSH_IDフレーム
    class MaxPushIdFrame < Frame
      property max_push_id : UInt64  # 最大プッシュID
      
      def initialize(@max_push_id : UInt64)
        super(FrameType::MaxPushId, Http3Varint.size(@max_push_id))
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # 最大プッシュIDをシリアライズ
        Http3Varint.encode(io, @max_push_id)
      end
      
      # 検証
      def validate : Bool
        true # MAX_PUSH_IDフレームは常に有効
      end
      
      # 文字列表現
      def to_s : String
        "MAX_PUSH_ID frame, max_push_id=#{@max_push_id}"
      end
    end
    
    # その他のフレーム用汎用クラス
    class UnknownFrame < Frame
      property payload : Bytes  # ペイロード
      
      def initialize(type : FrameType, @payload : Bytes)
        super(type, @payload.size.to_u64)
      end
      
      # シリアライズ
      def serialize(io : IO) : Nil
        # フレームタイプをシリアライズ
        Http3Varint.encode(io, @frame_type.value)
        
        # フレーム長をシリアライズ
        Http3Varint.encode(io, @length)
        
        # ペイロードをシリアライズ
        io.write(@payload) if @payload.size > 0
      end
      
      # 検証
      def validate : Bool
        true # UnknownFrameは常に有効
      end
      
      # 文字列表現
      def to_s : String
        "#{@frame_type} frame, payload_length=#{@payload.size}"
      end
    end
    
    # フレームパーサークラス - 高速なバイナリパーシング
    class FrameParser
      # 最大フレームサイズ制限
      MAX_FRAME_PAYLOAD_SIZE = 16_777_215  # 16MB
      
      # 例外クラス
      class FrameParseError < Exception
      end
      
      # バイナリデータからフレームをパース
      def self.parse(data : Bytes, offset : Int32 = 0) : {Frame, Int32}
        # バッファチェック
        if offset >= data.size
          raise FrameParseError.new("バッファ終端を超えています")
        end
        
        # 現在のオフセット位置
        current_offset = offset
        
        # フレームタイプをデコード
        frame_type_value, bytes_read = Http3Varint.decode(data, current_offset)
        if bytes_read <= 0
          raise FrameParseError.new("フレームタイプのデコードに失敗しました")
        end
        current_offset += bytes_read
        
        # フレーム長をデコード
        frame_length, bytes_read = Http3Varint.decode(data, current_offset)
        if bytes_read <= 0
          raise FrameParseError.new("フレーム長のデコードに失敗しました")
        end
        current_offset += bytes_read
        
        # フレーム長の検証
        if frame_length > MAX_FRAME_PAYLOAD_SIZE
          raise FrameParseError.new("フレーム長が上限を超えています: #{frame_length} > #{MAX_FRAME_PAYLOAD_SIZE}")
        end
        
        # ペイロード長チェック
        remaining_bytes = data.size - current_offset
        if remaining_bytes < frame_length
          raise FrameParseError.new("ペイロードが不完全です: 必要=#{frame_length}, 残り=#{remaining_bytes}")
        end
        
        # フレームタイプからオブジェクト作成
        frame_type = FrameType.from_value(frame_type_value)
        
        frame = case frame_type
        when FrameType::Data
          # データフレーム
          payload = Bytes.new(frame_length.to_i32)
          payload.copy_from(data.to_unsafe + current_offset, frame_length.to_i32) if frame_length > 0
          current_offset += frame_length.to_i32
          DataFrame.new(payload)
          
        when FrameType::Headers
          # ヘッダーフレーム
          payload = Bytes.new(frame_length.to_i32)
          payload.copy_from(data.to_unsafe + current_offset, frame_length.to_i32) if frame_length > 0
          current_offset += frame_length.to_i32
          HeadersFrame.new(payload)
          
        when FrameType::Settings
          # 設定フレーム
          settings = {} of UInt64 => UInt64
          end_offset = current_offset + frame_length.to_i32
          
          while current_offset < end_offset
            # 設定IDをデコード
            setting_id, bytes_read = Http3Varint.decode(data, current_offset)
            if bytes_read <= 0
              raise FrameParseError.new("設定IDのデコードに失敗しました")
            end
            current_offset += bytes_read
            
            # 設定値をデコード
            setting_value, bytes_read = Http3Varint.decode(data, current_offset)
            if bytes_read <= 0
              raise FrameParseError.new("設定値のデコードに失敗しました")
            end
            current_offset += bytes_read
            
            # 設定を追加
            settings[setting_id] = setting_value
            
            # 設定エントリが多すぎる場合はエラー
            if settings.size > 32
              raise FrameParseError.new("設定エントリが多すぎます: #{settings.size} > 32")
            end
          end
          
          SettingsFrame.new(settings)
          
        when FrameType::Goaway
          # GOAWAYフレーム
          stream_id, bytes_read = Http3Varint.decode(data, current_offset)
          if bytes_read <= 0
            raise FrameParseError.new("ストリームIDのデコードに失敗しました")
          end
          current_offset += bytes_read
          GoawayFrame.new(stream_id)
          
        when FrameType::PushPromise
          # PUSH_PROMISEフレーム
          push_id, bytes_read = Http3Varint.decode(data, current_offset)
          if bytes_read <= 0
            raise FrameParseError.new("プッシュIDのデコードに失敗しました")
          end
          current_offset += bytes_read
          
          # ヘッダーブロックを取得
          header_block_size = frame_length.to_i32 - bytes_read
          headers = Bytes.new(header_block_size)
          headers.copy_from(data.to_unsafe + current_offset, header_block_size) if header_block_size > 0
          current_offset += header_block_size
          
          PushPromiseFrame.new(push_id, headers)
          
        when FrameType::CancelPush
          # CANCEL_PUSHフレーム
          push_id, bytes_read = Http3Varint.decode(data, current_offset)
          if bytes_read <= 0
            raise FrameParseError.new("プッシュIDのデコードに失敗しました")
          end
          current_offset += bytes_read
          CancelPushFrame.new(push_id)
          
        when FrameType::MaxPushId
          # MAX_PUSH_IDフレーム
          max_push_id, bytes_read = Http3Varint.decode(data, current_offset)
          if bytes_read <= 0
            raise FrameParseError.new("最大プッシュIDのデコードに失敗しました")
          end
          current_offset += bytes_read
          MaxPushIdFrame.new(max_push_id)
          
        else
          # その他の未知のフレーム
          payload = Bytes.new(frame_length.to_i32)
          payload.copy_from(data.to_unsafe + current_offset, frame_length.to_i32) if frame_length > 0
          current_offset += frame_length.to_i32
          UnknownFrame.new(frame_type, payload)
        end
        
        # 作成したフレームと消費したバイト数を返却
        {frame, current_offset - offset}
      end
      
      # 複数フレームのパース
      def self.parse_frames(data : Bytes) : Array(Frame)
        frames = [] of Frame
        offset = 0
        
        while offset < data.size
          begin
            frame, bytes_consumed = parse(data, offset)
            frames << frame
            offset += bytes_consumed
          rescue e : FrameParseError
            Log.error { "フレームパースエラー: #{e.message}" }
            break
          end
        end
        
        frames
      end
    end
    
    # フレームコレクション管理クラス
    class FrameCollection
      property frames : Array(Frame)
      property total_size : Int64
      property frame_count : Int32
      
      def initialize
        @frames = [] of Frame
        @total_size = 0_i64
        @frame_count = 0
      end
      
      # フレームを追加
      def add_frame(frame : Frame) : Nil
        @frames << frame
        @frame_count += 1
        
        # フレームサイズの計算（ヘッダー + ペイロード）
        header_size = Http3Varint.size(frame.frame_type.value) + Http3Varint.size(frame.length)
        @total_size += header_size + frame.length
      end
      
      # 特定タイプのフレームを検索
      def find_frames_by_type(frame_type : FrameType) : Array(Frame)
        @frames.select { |frame| frame.frame_type == frame_type }
      end
      
      # 最初のSettings frameを取得
      def first_settings : SettingsFrame?
        @frames.find { |frame| frame.is_a?(SettingsFrame) }.as(SettingsFrame?)
      end
      
      # すべてのフレームをシリアライズ
      def serialize(io : IO) : Nil
        @frames.each do |frame|
          frame.serialize(io)
        end
      end
      
      # シリアライズしたバイト列を取得
      def to_bytes : Bytes
        io = IO::Memory.new(@total_size.to_i32)
        serialize(io)
        io.to_slice
      end
    end
    
    # HTTP/3フレームハンドラ
    abstract class FrameHandler
      # DATAフレームのハンドリング
      abstract def on_data(stream_id : UInt64, data : Bytes, end_stream : Bool) : Nil
      
      # HEADERSフレームのハンドリング
      abstract def on_headers(stream_id : UInt64, header_block : Bytes, end_stream : Bool) : Nil
      
      # SETTINGSフレームのハンドリング
      abstract def on_settings(settings : Hash(UInt64, UInt64)) : Nil
      
      # GOAWAYフレームのハンドリング
      abstract def on_goaway(stream_id : UInt64) : Nil
      
      # PUSH_PROMISEフレームのハンドリング
      abstract def on_push_promise(stream_id : UInt64, push_id : UInt64, header_block : Bytes) : Nil
      
      # CANCEL_PUSHフレームのハンドリング
      abstract def on_cancel_push(push_id : UInt64) : Nil
      
      # MAX_PUSH_IDフレームのハンドリング
      abstract def on_max_push_id(max_push_id : UInt64) : Nil
      
      # 未知のフレームのハンドリング
      abstract def on_unknown_frame(stream_id : UInt64, frame_type : UInt64, payload : Bytes) : Nil
      
      # フレームを処理
      def process_frame(stream_id : UInt64, frame : Frame) : Nil
        case frame
        when DataFrame
          on_data(stream_id, frame.data, frame.flags.includes?(FrameFlags::EndStream))
        when HeadersFrame
          on_headers(stream_id, frame.headers, frame.flags.includes?(FrameFlags::EndStream))
        when SettingsFrame
          on_settings(frame.settings)
        when GoawayFrame
          on_goaway(frame.stream_id)
        when PushPromiseFrame
          on_push_promise(stream_id, frame.push_id, frame.headers)
        when CancelPushFrame
          on_cancel_push(frame.push_id)
        when MaxPushIdFrame
          on_max_push_id(frame.max_push_id)
        else
          payload = frame.is_a?(UnknownFrame) ? frame.payload : Bytes.new(0)
          on_unknown_frame(stream_id, frame.frame_type.value, payload)
        end
      end
      
      # フレーム配列を一括処理
      def process_frames(stream_id : UInt64, frames : Array(Frame)) : Nil
        frames.each do |frame|
          process_frame(stream_id, frame)
        end
      end
    end
  end
end 