// src/zig/engine/core.zig
// Zig 側のコアエンジンロジック。
// 状態管理、主要コンポーネントのオーケストレーションなどを担当します（将来実装）。

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // グローバルアロケータ
const errors = @import("../util/error.zig");   // 共通エラー型
const dom = @import("../dom/document.zig");    // DOMドキュメント
const js_engine = @import("../javascript/engine.zig"); // JavaScriptエンジン

// ページ管理マネージャー（シングルページでも必要）
const PageManager = struct {
    active_document_id: u64 = 0,
    documents: std.AutoHashMap(u64, *dom.Document),
    next_document_id: u64 = 1,

    fn init(allocator: std.mem.Allocator) !*PageManager {
        const manager = try allocator.create(PageManager);
        manager.* = PageManager{
            .documents = std.AutoHashMap(u64, *dom.Document).init(allocator),
        };
        return manager;
    }

    fn deinit(self: *PageManager, allocator: std.mem.Allocator) void {
        // すべてのドキュメントを解放
        var iter = self.documents.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.destroy();
        }
        self.documents.deinit();
        allocator.destroy(self);
    }

    fn createDocument(self: *PageManager, allocator: std.mem.Allocator, content_type: []const u8) !u64 {
        const doc = try dom.Document.create(allocator, content_type);
        const id = self.next_document_id;
        self.next_document_id += 1;
        
        try self.documents.put(id, doc);
        self.active_document_id = id;
        return id;
    }
};

// リソーススケジューラー（ネットワークリソース、キャッシュなどの管理）
const ResourceScheduler = struct {
    allocator: std.mem.Allocator,
    active_requests: u32 = 0,
    max_concurrent_requests: u32 = 6, // HTTP/1.1標準の並列接続制限

    fn init(allocator: std.mem.Allocator) !*ResourceScheduler {
        const scheduler = try allocator.create(ResourceScheduler);
        scheduler.* = ResourceScheduler{
            .allocator = allocator,
        };
        return scheduler;
    }

    fn deinit(self: *ResourceScheduler, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

// Zig エンジンコアの状態を保持する構造体
const EngineState = struct {
    initialized_time: i64,       // 初期化時のタイムスタンプ (Unix秒)
    is_running: bool,            // エンジンがアクティブかどうか
    page_manager: *PageManager,  // ページ/ドキュメント管理
    resource_scheduler: *ResourceScheduler, // リソースリクエスト管理

    // 簡単な初期化関数
    fn init() !EngineState {
        const allocator = mem.g_general_allocator;
        
        // サブシステムを初期化
        const page_mgr = try PageManager.init(allocator);
        errdefer page_mgr.deinit(allocator);
        
        const resource_sched = try ResourceScheduler.init(allocator);
        errdefer resource_sched.deinit(allocator);
        
        return EngineState{
            .initialized_time = std.time.timestamp(),
            .is_running = true,
            .page_manager = page_mgr,
            .resource_scheduler = resource_sched,
        };
    }

    // 破棄処理 (構造体が管理するリソースを解放)
    fn deinit(self: *EngineState) void {
        std.log.debug("Deinitializing EngineState resources...", .{});
        
        // サブシステムを解放
        self.resource_scheduler.deinit(mem.g_general_allocator);
        self.page_manager.deinit(mem.g_general_allocator);
        
        self.* = undefined; // メモリが無効になったことを示す
    }
};

// グローバルなエンジン状態変数 (シングルトンパターン)
// マルチスレッドからのアクセスには外部で Mutex などが必要になる。
var global_engine_state: ?EngineState = null;

// Zig エンジンコアを初期化します。
// FFI の quantum_zig_initialize から呼び出される想定です。
// グローバルアロケータを初期化し、エンジン状態をセットアップします。
// エラーが発生する可能性があるため `!void` を返します。
pub fn initialize() !void {
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
    global_engine_state = try EngineState.init();

    std.log.info("Zig Engine Core initialized successfully at timestamp {d}.", .{global_engine_state.?.initialized_time});

    // DOM初期化（ページマネージャー経由でベースドキュメントを作成）
    _ = try global_engine_state.?.page_manager.createDocument(mem.g_general_allocator, "text/html");
    std.log.debug("Initial document created.", .{});
    
    // JavaScriptエンジン初期化
    try js_engine.Engine.init(mem.g_general_allocator, .{});
    std.log.debug("JavaScript engine initialized.", .{});
}

// Zig エンジンコアをシャットダウンし、リソースを解放します。
// FFI の quantum_zig_shutdown から呼び出される想定です。
pub fn shutdown() void {
    std.log.info("Shutting down Zig Engine Core...", .{});

    // 初期化されていない場合は警告ログを出して終了
    var state = global_engine_state orelse {
        std.log.warn("Zig Engine Core not initialized or already shut down.", .{});
        // シャットダウン前にアロケータを破棄しないように注意
        return;
    };

    // JavaScriptエンジンのシャットダウン
    if (js_engine.Engine.instance) |instance| {
        instance.deinit();
    }
    std.log.debug("JavaScript engine shut down.", .{});

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