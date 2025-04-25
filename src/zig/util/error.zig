// src/zig/util/error.zig
// Zig側で使用する共通のエラー型を定義します。

const std = @import("std");

// メモリ確保失敗エラー
pub const AllocationError = error{
    OutOfMemory,
};

// 無効な引数エラー
pub const InvalidArgumentError = error{
    NullPointer,
    ValueOutOfBounds,
    UnexpectedValue,
};

// 状態が無効な場合のエラー
pub const InvalidStateError = error{
    NotInitialized,
    AlreadyInitialized,
    NotRunning,
    AlreadyRunning,
};

// 外部コンポーネント (FFI/IPC経由) との連携エラー
pub const ExternalComponentError = error {
    InitializationFailed,
    CommunicationFailed,
    ShutdownFailed,
};

// DOM操作関連のエラー
pub const DomError = error {
    /// 操作が許可されていない階層にノードを挿入しようとしたとき。
    HierarchyRequestError,
    /// 要求された操作に対してノードが間違ったドキュメント内にあるとき。
    WrongDocumentError,
    /// 無効または不正な文字が使用されたとき (例: XML 名など)。
    InvalidCharacterError,
    /// データが提供されなかったとき。
    NoDataAllowedError,
    /// 要求された型のオブジェクトがサポートされていないか、存在しないとき。
    NoModificationAllowedError,
    /// 要求されたノードが存在しないコンテキストで参照されたとき。
    NotFoundError,
    /// 要求された操作がサポートされていないとき。
    NotSupportedError,
    /// オブジェクトが無効な状態にあるとき (例: 使用中の属性ノードなど)。
    InUseAttributeError,
    /// 文字列が無効な状態を含んでいるとき (例: 不正な修飾名)。
    InvalidStateError,
    /// 操作が構文的に無効であるとき (例: 無効なセレクタ)。
    SyntaxError,
    /// 要求された変更の種類が許可されていないとき。
    InvalidModificationError,
    /// 要求された名前空間に関連する操作が許可されていないとき。
    NamespaceError,
    /// 操作がセキュリティ上の理由で許可されていないとき。
    SecurityError,
    /// ネットワークエラーが発生したとき。
    NetworkError,
    /// 操作が中止されたとき。
    AbortError,
    /// URL が指定された制約に一致しないとき。
    URLMismatchError,
    /// クォータを超過したとき。
    QuotaExceededError,
    /// 操作がタイムアウトしたとき。
    TimeoutError,
    /// 読み取り専用の操作に対して書き込みが試みられたとき。
    InvalidNodeTypeError,
    /// データが期待された形式でないとき。
    DataCloneError,
};

// QuantumCore Zig モジュール全体で使用される共通のエラーセット。
pub const QuantumError = error{
    /// メモリ割り当てに失敗した場合。
    OutOfMemory,
    /// 不正な状態での操作が試みられた場合 (例: 未初期化、既に初期化済みなど)。
    InvalidState,
    /// 引数が不正な場合。
    InvalidArgument,
    /// 未実装の機能が呼び出された場合。
    NotImplemented,
    /// 予期しない、または分類不能な内部エラー。
    InternalError,
    /// FFI 境界で文字列の変換に失敗した場合。
    StringConversionFailed,
    /// ファイル I/O 操作中にエラーが発生した場合。
    FileIOError,
    /// ネットワーク操作中にエラーが発生した場合。
    NetworkError,
    /// パース処理中にエラーが発生した場合。
    ParseError,
};

// 必要に応じて、より具体的なエラーセットをここで定義したり、
// 他のモジュールでこの QuantumError を含んだエラーセットを定義したりできます。

// TODO: 必要に応じて他のエラーセットを追加
// (例: ParsingError, NetworkError, PermissionError など) 

// --- Parser エラー ---
pub const ParserError = error{
    UnexpectedEndOfInput,
    UnexpectedToken,
    InvalidSyntax,
    EncodingError,
    // ... その他必要なパーサー関連エラー
};

// --- Network エラー ---
pub const NetworkError = error{
    ConnectionRefused,
    HostUnreachable,
    Timeout,
    DNSNotFound,
    TLSHandshakeFailed,
    // ... その他ネットワーク関連エラー
};

// --- Generic エラー ---
pub const GenericError = error{
    /// メモリ割り当てに失敗したとき。
    OutOfMemory,
    /// 未実装の機能が呼び出されたとき。
    NotImplemented,
    /// 不正な引数が渡されたとき。
    InvalidArgument,
    /// 予期しない内部エラー。
    InternalError,
    /// 操作が許可されていないとき。
    OperationNotAllowed,
};

// --- すべてのエラーセットを統合 (オプション) ---
// アプリケーション全体で単一のエラーセットを使用する場合。
// pub const AppError = DomError || ParserError || NetworkError || GenericError;

// テスト
test "Error Sets Declaration" {
    // 各エラーセットが正しく宣言されているかを確認する基本的なテスト。
    // このテストは主にコンパイルが通ることを確認します。
    try std.testing.expect(DomError.HierarchyRequestError != DomError.NotFoundError);
    try std.testing.expect(ParserError.UnexpectedToken != ParserError.EncodingError);
    try std.testing.expect(NetworkError.Timeout != NetworkError.ConnectionRefused);
    try std.testing.expect(GenericError.NotImplemented != GenericError.OutOfMemory);
} 