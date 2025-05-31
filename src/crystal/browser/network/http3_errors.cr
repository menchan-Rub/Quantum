# HTTP/3エラー定義モジュール
#
# RFC 9114で定義されたHTTP/3エラーの実装
# 効率的なエラーハンドリングと豊富なコンテキスト情報

require "log"

module QuantumBrowser
  # HTTP/3エラー処理モジュール
  module Http3Errors
    Log = ::Log.for(self)
    
    # HTTP/3エラータイプ
    enum ErrorType : UInt64
      # HTTP/3コアエラー（RFC 9114 8.1節）
      H3_NO_ERROR                = 0x100  # エラーなし、優雅な接続終了
      H3_GENERAL_PROTOCOL_ERROR  = 0x101  # 一般的なプロトコルエラー
      H3_INTERNAL_ERROR          = 0x102  # 内部エラー
      H3_STREAM_CREATION_ERROR   = 0x103  # ストリーム生成エラー
      H3_CLOSED_CRITICAL_STREAM  = 0x104  # 重要なストリームが閉じられた
      H3_FRAME_UNEXPECTED        = 0x105  # 予期しないフレーム
      H3_FRAME_ERROR             = 0x106  # フレームエラー
      H3_EXCESSIVE_LOAD          = 0x107  # 過負荷
      H3_ID_ERROR                = 0x108  # ID関連エラー
      H3_SETTINGS_ERROR          = 0x109  # 設定エラー
      H3_MISSING_SETTINGS        = 0x10A  # 設定が欠落
      H3_REQUEST_REJECTED        = 0x10B  # リクエスト拒否
      H3_REQUEST_CANCELLED       = 0x10C  # リクエストキャンセル
      H3_REQUEST_INCOMPLETE      = 0x10D  # リクエスト不完全
      H3_MESSAGE_ERROR           = 0x10E  # メッセージエラー
      H3_CONNECT_ERROR           = 0x10F  # CONNECTエラー
      H3_VERSION_FALLBACK        = 0x110  # バージョンフォールバック
      
      # QPACKエラー（RFC 9204 6.3節）
      QPACK_DECOMPRESSION_FAILED = 0x200  # 復号化失敗
      QPACK_ENCODER_STREAM_ERROR = 0x201  # エンコーダーストリームエラー
      QPACK_DECODER_STREAM_ERROR = 0x202  # デコーダーストリームエラー
      
      # カスタムエラー（実装固有）
      QUANTUM_INTERNAL_ERROR     = 0x300  # Quantum内部エラー
      QUANTUM_SECURITY_ERROR     = 0x301  # セキュリティ関連エラー
      QUANTUM_RESOURCE_LIMIT     = 0x302  # リソース制限エラー
      QUANTUM_DNS_ERROR          = 0x303  # DNS解決エラー
      QUANTUM_VALIDATION_ERROR   = 0x304  # 検証エラー
      
      # 文字列表現
      def to_s : String
        case self
        when H3_NO_ERROR                then "H3_NO_ERROR"
        when H3_GENERAL_PROTOCOL_ERROR  then "H3_GENERAL_PROTOCOL_ERROR"
        when H3_INTERNAL_ERROR          then "H3_INTERNAL_ERROR"
        when H3_STREAM_CREATION_ERROR   then "H3_STREAM_CREATION_ERROR"
        when H3_CLOSED_CRITICAL_STREAM  then "H3_CLOSED_CRITICAL_STREAM"
        when H3_FRAME_UNEXPECTED        then "H3_FRAME_UNEXPECTED"
        when H3_FRAME_ERROR             then "H3_FRAME_ERROR"
        when H3_EXCESSIVE_LOAD          then "H3_EXCESSIVE_LOAD"
        when H3_ID_ERROR                then "H3_ID_ERROR"
        when H3_SETTINGS_ERROR          then "H3_SETTINGS_ERROR"
        when H3_MISSING_SETTINGS        then "H3_MISSING_SETTINGS"
        when H3_REQUEST_REJECTED        then "H3_REQUEST_REJECTED"
        when H3_REQUEST_CANCELLED       then "H3_REQUEST_CANCELLED"
        when H3_REQUEST_INCOMPLETE      then "H3_REQUEST_INCOMPLETE"
        when H3_MESSAGE_ERROR           then "H3_MESSAGE_ERROR"
        when H3_CONNECT_ERROR           then "H3_CONNECT_ERROR"
        when H3_VERSION_FALLBACK        then "H3_VERSION_FALLBACK"
        when QPACK_DECOMPRESSION_FAILED then "QPACK_DECOMPRESSION_FAILED"
        when QPACK_ENCODER_STREAM_ERROR then "QPACK_ENCODER_STREAM_ERROR"
        when QPACK_DECODER_STREAM_ERROR then "QPACK_DECODER_STREAM_ERROR"
        when QUANTUM_INTERNAL_ERROR     then "QUANTUM_INTERNAL_ERROR"
        when QUANTUM_SECURITY_ERROR     then "QUANTUM_SECURITY_ERROR"
        when QUANTUM_RESOURCE_LIMIT     then "QUANTUM_RESOURCE_LIMIT"
        when QUANTUM_DNS_ERROR          then "QUANTUM_DNS_ERROR"
        when QUANTUM_VALIDATION_ERROR   then "QUANTUM_VALIDATION_ERROR"
        else "UNKNOWN_ERROR(0x#{value.to_s(16)})"
        end
      end
      
      # 説明文
      def description : String
        case self
        when H3_NO_ERROR
          "正常終了（エラーなし）"
        when H3_GENERAL_PROTOCOL_ERROR
          "HTTP/3プロトコルに準拠していない動作が検出されました"
        when H3_INTERNAL_ERROR
          "HTTP/3スタックの内部エラーが発生しました"
        when H3_STREAM_CREATION_ERROR
          "ストリーム作成時にエラーが発生しました"
        when H3_CLOSED_CRITICAL_STREAM
          "重要なストリームが予期せず閉じられました"
        when H3_FRAME_UNEXPECTED
          "予期しないコンテキストでフレームを受信しました"
        when H3_FRAME_ERROR
          "フレームのフォーマットや処理中にエラーが発生しました"
        when H3_EXCESSIVE_LOAD
          "サーバーが過負荷状態のため要求を処理できません"
        when H3_ID_ERROR
          "ID値が不正または範囲外です"
        when H3_SETTINGS_ERROR
          "設定フレームまたは設定値が不正です"
        when H3_MISSING_SETTINGS
          "必要な設定が受信されていません"
        when H3_REQUEST_REJECTED
          "サーバーがリクエストを拒否しました"
        when H3_REQUEST_CANCELLED
          "リクエストがキャンセルされました"
        when H3_REQUEST_INCOMPLETE
          "リクエストが完了する前にストリームが終了しました"
        when H3_MESSAGE_ERROR
          "HTTPメッセージフォーマットが不正です"
        when H3_CONNECT_ERROR
          "CONNECTリクエスト処理中にエラーが発生しました"
        when H3_VERSION_FALLBACK
          "別のHTTPバージョンへのフォールバックが必要です"
        when QPACK_DECOMPRESSION_FAILED
          "ヘッダーブロックの復号化に失敗しました"
        when QPACK_ENCODER_STREAM_ERROR
          "QPACKエンコーダーストリームでエラーが発生しました"
        when QPACK_DECODER_STREAM_ERROR
          "QPACKデコーダーストリームでエラーが発生しました"
        when QUANTUM_INTERNAL_ERROR
          "Quantumブラウザ内部エラーが発生しました"
        when QUANTUM_SECURITY_ERROR
          "セキュリティに関するエラーが発生しました"
        when QUANTUM_RESOURCE_LIMIT
          "リソース制限に達しました"
        when QUANTUM_DNS_ERROR
          "DNS解決に失敗しました"
        when QUANTUM_VALIDATION_ERROR
          "データ検証に失敗しました"
        else
          "未知のエラー: 0x#{value.to_s(16)}"
        end
      end
      
      # エラーの重大度を判定
      def severity : Log::Severity
        case self
        when H3_NO_ERROR
          Log::Severity::Info
        when H3_REQUEST_REJECTED, H3_REQUEST_CANCELLED, H3_VERSION_FALLBACK
          Log::Severity::Notice
        when H3_EXCESSIVE_LOAD, H3_MISSING_SETTINGS
          Log::Severity::Warn
        else
          Log::Severity::Error
        end
      end
      
      # デバッグに役立つ情報
      def debug_info : String
        case self
        when H3_REQUEST_REJECTED
          "リクエストが拒否された理由は様々です。サーバーの負荷、認証失敗、アクセス制限などが考えられます。"
        when H3_EXCESSIVE_LOAD
          "サーバーの負荷が高すぎます。再試行するか、後ほど接続してください。"
        when QPACK_DECOMPRESSION_FAILED
          "ヘッダー圧縮の互換性に問題がある可能性があります。QPACKのバージョンやパラメータを確認してください。"
        else
          ""
        end
      end
      
      # エラーが一時的なものかどうか
      def transient? : Bool
        case self
        when H3_NO_ERROR, H3_EXCESSIVE_LOAD, H3_REQUEST_CANCELLED, QUANTUM_DNS_ERROR
          true
        else
          false
        end
      end
      
      # エラーが重大かどうか（接続を終了すべきか）
      def critical? : Bool
        case self
        when H3_NO_ERROR, H3_REQUEST_REJECTED, H3_REQUEST_CANCELLED, H3_REQUEST_INCOMPLETE
          false
        else
          true
        end
      end
      
      # 再試行すべきかどうか
      def should_retry? : Bool
        case self
        when H3_EXCESSIVE_LOAD, H3_REQUEST_CANCELLED, QUANTUM_DNS_ERROR
          true
        else
          false
        end
      end
    end
    
    # HTTP/3例外基底クラス
    class Http3Exception < Exception
      getter error_type : ErrorType
      getter stream_id : UInt64?
      getter source_location : String?
      getter timestamp : Time
      
      def initialize(@error_type, message : String? = nil, @stream_id : UInt64? = nil, @source_location : String? = nil)
        @timestamp = Time.utc
        super(message || @error_type.description)
      end
      
      # エラーの文字列表現
      def to_s : String
        result = "HTTP/3エラー: #{@error_type} - #{message}"
        result += " (ストリームID: #{@stream_id})" if @stream_id
        result += " [#{@source_location}]" if @source_location
        result
      end
      
      # ログレベルを取得
      def log_level : Log::Severity
        @error_type.severity
      end
      
      # 詳細情報を取得
      def details : String
        debug_info = @error_type.debug_info
        return debug_info unless debug_info.empty?
        message
      end
    end
    
    # フレーム関連のエラー
    class FrameError < Http3Exception
      getter frame_type : UInt64?
      
      def initialize(error_type : ErrorType, @frame_type : UInt64? = nil, message : String? = nil, stream_id : UInt64? = nil)
        super(error_type, message, stream_id)
      end
      
      def to_s : String
        result = super
        result += " (フレームタイプ: 0x#{@frame_type.try &.to_s(16)})" if @frame_type
        result
      end
    end
    
    # ストリーム関連のエラー
    class StreamError < Http3Exception
      def initialize(error_type : ErrorType, stream_id : UInt64, message : String? = nil)
        super(error_type, message, stream_id)
      end
    end
    
    # 接続全体に関するエラー
    class ConnectionError < Http3Exception
      def initialize(error_type : ErrorType, message : String? = nil)
        super(error_type, message)
      end
    end
    
    # QPACK関連のエラー
    class QpackError < Http3Exception
      def initialize(error_type : ErrorType, message : String? = nil, stream_id : UInt64? = nil)
        super(error_type, message, stream_id)
      end
    end
    
    # エラーコードからエラータイプに変換
    def self.error_type_from_code(code : UInt64) : ErrorType
      begin
        ErrorType.new(code)
      rescue
        ErrorType::H3_INTERNAL_ERROR
      end
    end
    
    # エラーログ出力
    def self.log_error(error : Http3Exception) : Nil
      Log.log(error.log_level, exception: error) { error.to_s }
    end
    
    # エラーが致命的かどうかをチェック
    def self.is_critical_error?(error_type : ErrorType) : Bool
      error_type.critical?
    end
    
    # エラーの再試行が適切かどうかをチェック
    def self.should_retry?(error_type : ErrorType) : Bool
      error_type.should_retry?
    end
  end
end 