// src/zig/engine/core.zig
// Zig 側のコアエンジンロジック。
// 状態管理、主要コンポーネントのオーケストレーションなどを担当します（将来実装）。

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // グローバルアロケータ
const errors = @import("../util/error.zig");   // 共通エラー型

// Zig エンジンコアの状態を保持する構造体 (例)
const EngineState = struct {
    // allocator: std.mem.Allocator, // 削除: グローバルアロケータを使用
    initialized_time: i64,       // 初期化時のタイムスタンプ (Unix秒)
    is_running: bool,            // エンジンがアクティブかどうか
    // TODO: 他のマネージャーや状態への参照を追加
    // page_manager: *PageManager,
    // resource_scheduler: *ResourceScheduler,

    // 簡単な初期化関数
    // allocator 引数を削除
    fn init() !EngineState {
        return EngineState{
            // .allocator = allocator, // 削除
            .initialized_time = std.time.timestamp(),
            .is_running = true,
        };
    }

    // 破棄処理 (構造体が管理するリソースを解放)
    fn deinit(self: *EngineState) void {
        std.log.debug("Deinitializing EngineState resources...", .{});
        // TODO: この構造体が所有する他のリソースがあればここで解放する。
        // 例えば、他のマネージャーへのポインタを解放するなど。
        // mem.allocator.destroy(self.page_manager); // 例: グローバルアロケータを使用
        self.* = undefined; // メモリが無効になったことを示す (オプション)
    }
};

// グローバルなエンジン状態変数 (シングルトンパターン)
// マルチスレッドからのアクセスには外部で Mutex などが必要になる。
var global_engine_state: ?EngineState = null;

// Zig エンジンコアを初期化します。
// FFI の quantum_zig_initialize から呼び出される想定です。
// グローバルアロケータを初期化し、エンジン状態をセットアップします。
// エラーが発生する可能性があるため `!void` を返します。
pub fn initialize() !void { // allocator 引数を削除
    std.log.info("Initializing Zig Engine Core...", .{});

    // グローバルアロケータを初期化
    try mem.initAllocator();
    std.log.debug("Global allocator initialized.", .{});

    // 既に初期化されている場合はエラー
    if (global_engine_state != null) {
        std.log.warn("Zig Engine Core already initialized.", .{});
        // QuantumError を使用
        return error.InvalidState;
    }

    // エンジン状態構造体を初期化
    // グローバル変数に直接格納
    global_engine_state = try EngineState.init(); // allocator 引数を削除

    std.log.info("Zig Engine Core initialized successfully at timestamp {d}.", .{global_engine_state.?.initialized_time});

    // TODO: 他のサブコンポーネント (DOM, JS連携など) の初期化をここで行う
    // 例: try dom.init(mem.allocator); // グローバルアロケータを使用
}

// Zig エンジンコアをシャットダウンし、リソースを解放します。
// FFI の quantum_zig_shutdown から呼び出される想定です。
pub fn shutdown() void { // allocator 引数を削除
    std.log.info("Shutting down Zig Engine Core...", .{});

    // 初期化されていない場合は警告ログを出して終了
    var state = global_engine_state orelse {
        std.log.warn("Zig Engine Core not initialized or already shut down.", .{});
        // シャットダウン前にアロケータを破棄しないように注意
        return;
    };

    // TODO: 他のサブコンポーネントのシャットダウン処理をここで行う
    // 例: dom.deinit(mem.allocator); // グローバルアロケータを使用

    // エンジン状態を破棄
    state.deinit();
    global_engine_state = null;

    std.log.info("Zig Engine Core state deinitialized.", .{});

    // 最後にグローバルアロケータを破棄
    mem.deinitAllocator();

    std.log.info("Zig Engine Core shutdown complete.", .{});
}

// エンジンが初期化され、実行中かどうかを確認するヘルパー関数 (例)
pub fn isRunning() bool {
    // グローバル状態が存在し、かつ is_running フラグが true かどうか
    return global_engine_state != null and global_engine_state.?.is_running;
} 