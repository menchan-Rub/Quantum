// src/zig/memory/allocator.zig
// Zig側のグローバルメモリアロケータを管理します。

const std = @import("std");

// アプリケーション全体（Zig側）で使用されるグローバルアロケータ。
// GeneralPurposeAllocator はメモリリーク検出などのデバッグ機能を提供します。
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator(); // 公開アロケータインターフェース

// グローバルアロケータを初期化します。
// アプリケーション起動時に一度だけ呼び出す想定です。
pub fn initAllocator() !void {
    std.log.debug("Initializing global allocator (GPA)", .{});
    // GeneralPurposeAllocator の初期化は宣言時に行われるため、
    // ここでは追加の初期化処理は不要ですが、将来的な拡張のために残します。
    // 例えば、特定のアリーナアロケータを初期化するなど。
    return; // 現状は何もしない
}

// グローバルアロケータを破棄し、リソースを解放します。
// アプリケーション終了時に一度だけ呼び出す想定です。
// メモリリークがあれば検出・報告します。
pub fn deinitAllocator() void {
    std.log.debug("Deinitializing global allocator (GPA)...", .{});
    // gpa.deinit() は allocator() で取得したメモリがすべて解放されたかチェックします。
    // リークがあれば、テスト実行時や特定のビルドモードでエラーを報告します。
    const leaked_bytes = gpa.deinit();
    if (leaked_bytes == 0) {
        std.log.info("Global allocator deinitialized successfully. No memory leaks detected.", .{});
    } else {
        // 重要: リリースビルドではリーク検出が有効でない場合があります。
        // デバッグビルドやテストでリークを確認することが重要です。
        std.log.err("Memory leak detected! {d} bytes leaked.", .{leaked_bytes});
        // アプリケーションのポリシーに応じて、ここで panic するか、エラーログのみとするかを決定します。
        // std.debug.panic("Memory leak detected: {d} bytes\n", .{leaked_bytes});
    }
}

// カスタムアロケータやメモリ管理戦略 (将来実装) 