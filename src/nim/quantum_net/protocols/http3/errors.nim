## quantum_net/protocols/http3/errors.nim
## 
## HTTP/3プロトコルのエラーコード定義
## RFC 9114および関連仕様に基づくエラーコード

import std/options
import std/strutils
import std/strformat
import std/tables

type
  Http3ErrorCode* = enum
    ## HTTP/3エラーコード (RFC 9114)
    H3NoError = 0x0100             ## エラーなし
    H3GeneralProtocolError = 0x0101 ## 一般的なプロトコルエラー
    H3InternalError = 0x0102       ## 内部エラー
    H3StreamCreationError = 0x0103  ## ストリーム作成エラー
    H3ClosedCriticalStream = 0x0104 ## クリティカルストリームが閉じられた
    H3FrameUnexpected = 0x0105     ## 予期しないフレーム
    H3FrameError = 0x0106          ## フレームエラー
    H3ExcessiveLoad = 0x0107       ## 過剰な負荷
    H3IdError = 0x0108             ## ID関連エラー
    H3SettingsError = 0x0109       ## 設定エラー
    H3MissingSettings = 0x010a     ## 設定が見つからない
    H3RequestRejected = 0x010b     ## リクエスト拒否
    H3RequestCancelled = 0x010c    ## リクエストキャンセル
    H3RequestIncomplete = 0x010d   ## 不完全なリクエスト
    H3MessageError = 0x010e        ## メッセージエラー
    H3ConnectError = 0x010f        ## 接続エラー
    H3VersionFallback = 0x0110     ## バージョンフォールバック
    H3Reserved = 0x01ff            ## 予約済み

  QpackErrorCode* = enum
    ## QPACKエラーコード (RFC 9204)
    QpackDecompressionFailed = 0x0200      ## 圧縮解除失敗
    QpackEncoderStreamError = 0x0201       ## エンコーダーストリームエラー
    QpackDecoderStreamError = 0x0202       ## デコーダーストリームエラー

  QuicTransportErrorCode* = enum
    ## QUICトランスポートエラーコード (RFC 9000)
    QuicNoError = 0x0               ## エラーなし
    QuicInternalError = 0x1         ## 内部エラー
    QuicConnectionRefused = 0x2     ## 接続拒否
    QuicFlowControlError = 0x3      ## フロー制御エラー
    QuicStreamLimitError = 0x4      ## ストリーム制限エラー
    QuicStreamStateError = 0x5      ## ストリーム状態エラー
    QuicFinalSizeError = 0x6        ## 最終サイズエラー
    QuicFrameEncodingError = 0x7    ## フレームエンコーディングエラー
    QuicTransportParameterError = 0x8 ## トランスポートパラメータエラー
    QuicConnectionIdLimitError = 0x9 ## 接続ID制限エラー
    QuicProtocolViolation = 0xa     ## プロトコル違反
    QuicInvalidToken = 0xb          ## 無効なトークン
    QuicApplicationError = 0xc      ## アプリケーションエラー
    QuicCryptoBufferExceeded = 0xd  ## 暗号バッファオーバーフロー
    QuicKeyUpdateError = 0xe        ## キー更新エラー
    QuicAeadLimitReached = 0xf      ## AEAD制限到達
    QuicNoViablePath = 0x10         ## 実行可能なパスがない
    QuicCryptoError = 0x100         ## 暗号エラー基準値

type
  Http3Error* = object
    ## HTTP/3エラーオブジェクト
    code*: uint64             ## エラーコード
    message*: string          ## エラーメッセージ
    details*: string          ## 詳細情報
    source*: string           ## エラーの発生源

proc newHttp3Error*(code: Http3ErrorCode, message: string = "", 
                   details: string = "", source: string = ""): Http3Error =
  ## 新しいHTTP/3エラーを作成
  result.code = uint64(code)
  result.message = message
  result.details = details
  result.source = source

proc newQpackError*(code: QpackErrorCode, message: string = "",
                   details: string = "", source: string = ""): Http3Error =
  ## 新しいQPACKエラーを作成
  result.code = uint64(code)
  result.message = message
  result.details = details
  result.source = source

proc newQuicError*(code: QuicTransportErrorCode, message: string = "",
                  details: string = "", source: string = ""): Http3Error =
  ## 新しいQUICエラーを作成
  result.code = uint64(code)
  result.message = message
  result.details = details
  result.source = source

proc newCustomError*(code: uint64, message: string = "",
                    details: string = "", source: string = ""): Http3Error =
  ## 新しいカスタムエラーを作成
  result.code = code
  result.message = message
  result.details = details
  result.source = source

proc isHttp3Error*(error: Http3Error): bool =
  ## HTTP/3エラーかどうかを判定
  result = error.code >= 0x0100 and error.code <= 0x01ff

proc isQpackError*(error: Http3Error): bool =
  ## QPACKエラーかどうかを判定
  result = error.code >= 0x0200 and error.code <= 0x02ff

proc isQuicError*(error: Http3Error): bool =
  ## QUICエラーかどうかを判定
  result = error.code <= 0xff or error.code >= 0x100 and error.code < 0x1ff

proc `$`*(error: Http3Error): string =
  ## エラーの文字列表現
  var codeType = "Unknown"
  if error.isHttp3Error():
    codeType = "HTTP/3"
  elif error.isQpackError():
    codeType = "QPACK"
  elif error.isQuicError():
    codeType = "QUIC"
    
  result = codeType & " Error 0x" & toHex(error.code) & ": " & error.message
  if error.details.len > 0:
    result &= " (" & error.details & ")"
  if error.source.len > 0:
    result &= " [Source: " & error.source & "]"

proc errorName*(error: Http3Error): string =
  ## エラーコードの名前を取得
  if error.isHttp3Error():
    try:
      result = $Http3ErrorCode(error.code)
    except:
      result = "Unknown HTTP/3 Error"
  elif error.isQpackError():
    try:
      result = $QpackErrorCode(error.code)
    except:
      result = "Unknown QPACK Error"
  elif error.isQuicError():
    try:
      result = $QuicTransportErrorCode(error.code)
    except:
      result = "Unknown QUIC Error"
  else:
    result = "Custom Error"

# エラー定数
const
  H3ConnectionError* = newHttp3Error(H3InternalError, "Connection error")
  H3TimeoutError* = newHttp3Error(H3InternalError, "Request timeout")
  H3ProtocolError* = newHttp3Error(H3GeneralProtocolError, "Protocol error")
  H3StreamError* = newHttp3Error(H3FrameError, "Stream error")

  QpackHeaderError* = newQpackError(QpackDecompressionFailed, "Header decompression failed")
  
  QuicConnectionLost* = newQuicError(QuicInternalError, "Connection lost")
  QuicVersionNegotiationFailed* = newQuicError(QuicProtocolViolation, "Version negotiation failed")

## HTTP/3エラー処理モジュール
## 
## このモジュールはHTTP/3プロトコルのエラー処理を提供します。
## RFC 9114に準拠したエラーコード処理と効率的なエラー回復機能を実装しています。

type
  Http3ErrorCategory* = enum
    ## エラーのカテゴリ
    ecProtocol,         ## プロトコル関連エラー
    ecImplementation,   ## 実装関連エラー
    ecConnection,       ## 接続関連エラー
    ecStream,           ## ストリーム関連エラー
    ecCompression,      ## 圧縮関連エラー
    ecApplication,      ## アプリケーション関連エラー
    ecSecurity          ## セキュリティ関連エラー

  Http3ErrorSeverity* = enum
    ## エラーの重大度
    esWarning,          ## 警告
    esError,            ## エラー
    esCritical,         ## 重大
    esFatal             ## 致命的

  Http3ErrorAction* = enum
    ## エラー発生時の推奨アクション
    eaIgnore,           ## 無視
    eaRetry,            ## 再試行
    eaClose,            ## クローズ
    eaCloseConnection,  ## 接続を閉じる
    eaReset,            ## リセット
    eaRecover           ## 回復を試みる

  Http3Error* = object
    ## HTTP/3エラーオブジェクト
    code*: Http3ErrorCode               ## エラーコード
    message*: string                    ## エラーメッセージ
    streamId*: Option[uint64]           ## 関連ストリームID
    category*: Http3ErrorCategory       ## エラーカテゴリ
    severity*: Http3ErrorSeverity       ## 重大度
    action*: Http3ErrorAction           ## 推奨アクション
    recoverable*: bool                  ## 回復可能か
    details*: Option[string]            ## 詳細情報
    timestamp*: int64                   ## エラー発生時刻（ミリ秒）

  Http3ErrorHandler* = ref object
    ## エラーハンドラ
    onError*: proc(err: Http3Error) {.closure.}
    errors*: seq[Http3Error]
    suppressedCodes*: set[Http3ErrorCode] ## 抑制するエラーコード
    customHandlers*: Table[Http3ErrorCode, proc(err: Http3Error): bool {.closure.}]
    maxErrors*: int                       ## 保持する最大エラー数
    errorCount*: int                      ## 発生したエラーの総数
    fatalErrorOccurred*: bool             ## 致命的エラーが発生したか

# エラーコードの名前を取得
proc getName*(code: Http3ErrorCode): string =
  case code
  of H3NoError: "NO_ERROR"
  of H3GeneralProtocolError: "GENERAL_PROTOCOL_ERROR"
  of H3InternalError: "INTERNAL_ERROR"
  of H3StreamCreationError: "STREAM_CREATION_ERROR"
  of H3ClosedCriticalStream: "CLOSED_CRITICAL_STREAM"
  of H3FrameUnexpected: "FRAME_UNEXPECTED"
  of H3FrameError: "FRAME_ERROR"
  of H3ExcessiveLoad: "EXCESSIVE_LOAD"
  of H3IdError: "ID_ERROR"
  of H3SettingsError: "SETTINGS_ERROR"
  of H3MissingSettings: "MISSING_SETTINGS"
  of H3RequestRejected: "REQUEST_REJECTED"
  of H3RequestCancelled: "REQUEST_CANCELLED"
  of H3RequestIncomplete: "REQUEST_INCOMPLETE"
  of H3MessageError: "MESSAGE_ERROR"
  of H3ConnectError: "CONNECT_ERROR"
  of H3VersionFallback: "VERSION_FALLBACK"
  of QpackDecompressionFailed: "QPACK_DECOMPRESSION_FAILED"
  of QpackEncoderStreamError: "QPACK_ENCODER_STREAM_ERROR"
  of QpackDecoderStreamError: "QPACK_DECODER_STREAM_ERROR"

# エラーコードの説明を取得
proc getDescription*(code: Http3ErrorCode): string =
  case code
  of H3NoError: 
    "リクエストは成功し、それ以上のエラー情報はありません。"
  of H3GeneralProtocolError: 
    "ピアがHTTP/3プロトコルに違反する動作をしました。"
  of H3InternalError: 
    "エンドポイントが内部エラーに遭遇しました。"
  of H3StreamCreationError: 
    "エンドポイントがHTTP/3ストリームの作成に失敗しました。"
  of H3ClosedCriticalStream:
    "重要なストリームが想定外に閉じられました。"
  of H3FrameUnexpected:
    "予期しないフレームを受信しました。"
  of H3FrameError:
    "フレームがHTTP/3仕様に違反しています。"
  of H3ExcessiveLoad:
    "エンドポイントが処理できる以上の負荷がかかっています。"
  of H3IdError:
    "ID関連のエラーが発生しました。"
  of H3SettingsError:
    "SETTINGSフレームにエラーがあります。"
  of H3MissingSettings:
    "設定が欠落しています。"
  of H3RequestRejected:
    "サーバーがリクエストを処理する前に拒否しました。"
  of H3RequestCancelled:
    "リクエストはキャンセルされました。"
  of H3RequestIncomplete:
    "リクエストまたはレスポンスが不完全です。"
  of H3MessageError:
    "HTTPメッセージがプロトコル要件を満たしていません。"
  of H3ConnectError:
    "CONNECTリクエスト中にエラーが発生しました。"
  of H3VersionFallback:
    "HTTP/3との互換性がなく、HTTP/1.1または2へのフォールバックが必要です。"
  of QpackDecompressionFailed:
    "QPACKヘッダーのデコンプレッションに失敗しました。"
  of QpackEncoderStreamError:
    "QPACKエンコーダーストリームでエラーが発生しました。"
  of QpackDecoderStreamError:
    "QPACKデコーダーストリームでエラーが発生しました。"

# エラーコードのカテゴリを取得
proc getCategory*(code: Http3ErrorCode): Http3ErrorCategory =
  case code
  of H3NoError, H3FrameUnexpected, H3FrameError,
     H3SettingsError, H3MissingSettings, H3IdError: ecProtocol
  of H3InternalError: ecImplementation
  of H3StreamCreationError, H3ClosedCriticalStream: ecStream
  of H3ExcessiveLoad, H3ConnectError: ecConnection
  of H3RequestRejected, H3RequestCancelled, 
     H3RequestIncomplete, H3MessageError: ecApplication
  of H3VersionFallback: ecProtocol
  of QpackDecompressionFailed, QpackEncoderStreamError, 
     QpackDecoderStreamError: ecCompression

# エラーの重大度を取得
proc getSeverity*(code: Http3ErrorCode): Http3ErrorSeverity =
  case code
  of H3NoError, H3RequestCancelled: esWarning
  of H3GeneralProtocolError, H3FrameUnexpected, H3FrameError,
     H3IdError, H3RequestRejected, H3RequestIncomplete,
     H3MessageError, H3VersionFallback: esError
  of H3InternalError, H3StreamCreationError, H3ClosedCriticalStream,
     H3SettingsError, H3MissingSettings, H3ExcessiveLoad,
     H3ConnectError, QpackDecompressionFailed,
     QpackEncoderStreamError, QpackDecoderStreamError: esCritical

# 推奨アクションを取得
proc getRecommendedAction*(code: Http3ErrorCode): Http3ErrorAction =
  case code
  of H3NoError: eaIgnore
  of H3RequestCancelled, H3RequestRejected: eaRetry
  of H3GeneralProtocolError, H3InternalError, H3SettingsError,
     H3MissingSettings, H3ExcessiveLoad, H3VersionFallback: eaCloseConnection
  of H3StreamCreationError, H3ClosedCriticalStream, H3FrameUnexpected,
     H3FrameError, H3IdError, H3RequestIncomplete, H3MessageError,
     H3ConnectError, QpackDecompressionFailed,
     QpackEncoderStreamError, QpackDecoderStreamError: eaReset

# 回復可能かどうかを取得
proc isRecoverable*(code: Http3ErrorCode): bool =
  case code
  of H3NoError, H3RequestCancelled, H3RequestRejected,
     H3RequestIncomplete, H3MessageError, H3VersionFallback: true
  else: false

# エラーの文字列表現
proc `$`*(err: Http3Error): string =
  let streamMsg = if err.streamId.isSome: fmt" on stream {err.streamId.get}" else: ""
  let details = if err.details.isSome: fmt" - Details: {err.details.get}" else: ""
  fmt"HTTP/3 {err.severity} ({err.code.getName}){streamMsg}: {err.message}{details}"

# 新しいHTTP/3エラーを作成
proc newHttp3Error*(code: Http3ErrorCode, message: string, 
                   streamId: Option[uint64] = none(uint64),
                   details: Option[string] = none(string),
                   timestamp: int64 = 0): Http3Error =
  result = Http3Error(
    code: code,
    message: message,
    streamId: streamId,
    category: getCategory(code),
    severity: getSeverity(code),
    action: getRecommendedAction(code),
    recoverable: isRecoverable(code),
    details: details,
    timestamp: timestamp
  )

# エラーハンドラの作成
proc newHttp3ErrorHandler*(): Http3ErrorHandler =
  result = Http3ErrorHandler(
    errors: @[],
    suppressedCodes: {},
    customHandlers: initTable[Http3ErrorCode, proc(err: Http3Error): bool {.closure.}](),
    maxErrors: 100,
    errorCount: 0,
    fatalErrorOccurred: false
  )

# エラー処理
proc handleError*(handler: Http3ErrorHandler, error: Http3Error): bool =
  inc(handler.errorCount)
  
  # カスタムハンドラがあれば実行
  if handler.customHandlers.hasKey(error.code):
    let handled = handler.customHandlers[error.code](error)
    if handled:
      return true
  
  # 抑制されていないエラーのみ処理
  if error.code notin handler.suppressedCodes:
    # 致命的エラーのフラグを設定
    if error.severity == esFatal:
      handler.fatalErrorOccurred = true
    
    # エラーリストが最大数に達していたら古いものを削除
    if handler.errors.len >= handler.maxErrors:
      handler.errors.delete(0)
    
    # エラーを追加
    handler.errors.add(error)
    
    # コールバックがあれば呼び出し
    if handler.onError != nil:
      handler.onError(error)
    
    return true
  
  return false

# エラーコードを抑制
proc suppressErrorCode*(handler: Http3ErrorHandler, code: Http3ErrorCode) =
  handler.suppressedCodes.incl(code)

# エラーコードの抑制を解除
proc unsuppressErrorCode*(handler: Http3ErrorHandler, code: Http3ErrorCode) =
  handler.suppressedCodes.excl(code)

# カスタムエラーハンドラを設定
proc setCustomHandler*(handler: Http3ErrorHandler, code: Http3ErrorCode, 
                      customHandler: proc(err: Http3Error): bool {.closure.}) =
  handler.customHandlers[code] = customHandler

# エラーリストをクリア
proc clearErrors*(handler: Http3ErrorHandler) =
  handler.errors.setLen(0)
  handler.fatalErrorOccurred = false

# 条件に一致するエラーを検索
proc findErrors*(handler: Http3ErrorHandler, category: Http3ErrorCategory): seq[Http3Error] =
  result = @[]
  for err in handler.errors:
    if err.category == category:
      result.add(err)

# エラーメッセージからエラーコードを推測
proc inferErrorCode*(message: string): Http3ErrorCode =
  let lowerMsg = message.toLowerAscii()
  
  if "protocol" in lowerMsg:
    return H3GeneralProtocolError
  elif "internal" in lowerMsg:
    return H3InternalError
  elif "stream" in lowerMsg and "creat" in lowerMsg:
    return H3StreamCreationError
  elif "critical stream" in lowerMsg or "closed stream" in lowerMsg:
    return H3ClosedCriticalStream
  elif "unexpected frame" in lowerMsg:
    return H3FrameUnexpected
  elif "frame" in lowerMsg and "error" in lowerMsg:
    return H3FrameError
  elif "load" in lowerMsg or "overload" in lowerMsg:
    return H3ExcessiveLoad
  elif "id" in lowerMsg:
    return H3IdError
  elif "settings" in lowerMsg:
    if "missing" in lowerMsg:
      return H3MissingSettings
    else:
      return H3SettingsError
  elif "reject" in lowerMsg:
    return H3RequestRejected
  elif "cancel" in lowerMsg:
    return H3RequestCancelled
  elif "incomplete" in lowerMsg:
    return H3RequestIncomplete
  elif "message" in lowerMsg:
    return H3MessageError
  elif "connect" in lowerMsg:
    return H3ConnectError
  elif "version" in lowerMsg or "fallback" in lowerMsg:
    return H3VersionFallback
  elif "decompress" in lowerMsg:
    return QpackDecompressionFailed
  elif "qpack" in lowerMsg and "encoder" in lowerMsg:
    return QpackEncoderStreamError
  elif "qpack" in lowerMsg and "decoder" in lowerMsg:
    return QpackDecoderStreamError
  else:
    return H3InternalError  # デフォルト

# エラーの統計情報
proc getErrorStats*(handler: Http3ErrorHandler): tuple[total: int, byCategory: Table[Http3ErrorCategory, int], 
                                                      bySeverity: Table[Http3ErrorSeverity, int]] =
  result.total = handler.errorCount
  result.byCategory = initTable[Http3ErrorCategory, int]()
  result.bySeverity = initTable[Http3ErrorSeverity, int]()
  
  for err in handler.errors:
    if result.byCategory.hasKey(err.category):
      result.byCategory[err.category] += 1
    else:
      result.byCategory[err.category] = 1
    
    if result.bySeverity.hasKey(err.severity):
      result.bySeverity[err.severity] += 1
    else:
      result.bySeverity[err.severity] = 1

# 例外からHTTP/3エラーを作成
proc errorFromException*(e: ref Exception, streamId: Option[uint64] = none(uint64)): Http3Error =
  let msg = e.msg
  let code = inferErrorCode(msg)
  newHttp3Error(code, msg, streamId) 