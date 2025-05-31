// src/zig/bindings/ffi.zig
// Quantum ブラウザ - 最適化FFIバインディング
// Crystal/Nim/C言語から安全にZig実装を呼び出すインターフェイス

const std = @import("std");
const builtin = @import("builtin");
const Self = @This();

const memory = @import("../memory/allocator.zig");
const js_engine = @import("../javascript/engine.zig");
const renderer = @import("../engine/renderer.zig");
const dom = @import("../dom/node.zig");
const simd = @import("../simd/simd_ops.zig");

// バインディングエラーコード
pub const BindingError = enum(i32) {
    NoError = 0,
    NullPointer = -1,
    OutOfMemory = -2,
    InvalidArgument = -3,
    NotInitialized = -4,
    AlreadyInitialized = -5,
    InternalError = -6,
    NotImplemented = -7,
    ScriptError = -8,
    LayoutError = -9,
    RuntimeError = -10,
};

// ヘルスチェック情報（ヘルスチェック用）
pub const HealthInfo = extern struct {
    is_initialized: bool = false,
    memory_usage_mb: f64 = 0,
    version: [32]u8 = [_]u8{0} ** 32,

    fn init() HealthInfo {
        var info = HealthInfo{
            .is_initialized = true,
            .memory_usage_mb = 0,
        };

        const version_str = "0.1.0";
        std.mem.copy(u8, &info.version, version_str);

        return info;
    }
};

// 診断情報（パフォーマンスモニタリング用）
pub const DiagnosticsInfo = extern struct {
    memory_usage_bytes: usize = 0,
    peak_memory_bytes: usize = 0,
    active_workers: u32 = 0,
    frame_time_ns: u64 = 0,
    javascript_heap_bytes: usize = 0,
    is_simd_enabled: bool = false,
};

// DOM操作の配列形式結果
pub const DOMQueryResult = extern struct {
    node_ids: [*]u64 = undefined,
    count: usize = 0,
    capacity: usize = 0,
    error_code: i32 = 0,
};

// CSSスタイル結果
pub const CSSStyleResult = extern struct {
    property_names: [*]?[*:0]const u8 = undefined,
    property_values: [*]?[*:0]const u8 = undefined,
    count: usize = 0,
    capacity: usize = 0,
    error_code: i32 = 0,
};

// レンダリング設定
pub const RenderOptions = extern struct {
    width: u32 = 800,
    height: u32 = 600,
    use_gpu: bool = true,
    max_fps: u32 = 60,
    gpu_backend: u32 = 0, // 0: 自動、1: WebGPU、2: Vulkan...
    worker_threads: u32 = 0, // 0: CPU数を使用
};

// JavaScript実行結果
pub const JSExecutionResult = extern struct {
    result_type: u8 = 0, // 0: undefined, 1: null, 2: boolean, 3: number, 4: string, 5: object
    value_boolean: bool = false,
    value_number: f64 = 0,
    value_string: ?[*:0]const u8 = null,
    value_object_id: u64 = 0,
    has_error: bool = false,
    error_message: ?[*:0]const u8 = null,
};

//------------------------------------------------------------------------------
// メモリ管理と初期化
//------------------------------------------------------------------------------

/// EngineのZig側を初期化します。
/// 他の関数を呼び出す前に必ず呼び出す必要があります。
export fn quantum_zig_initialize() i32 {
    memory.initAllocator() catch |err| {
        std.log.err("Failed to initialize allocator: {}", .{err});
        return @intFromEnum(BindingError.OutOfMemory);
    };

    // SIMDサブシステムを初期化
    simd.initialize() catch |err| {
        std.log.err("Failed to initialize SIMD: {}", .{err});
        // SIMDが利用できなくてもエラーにはしない
    };

    // エンジンの各種サブシステムを初期化
    renderer.Renderer.init(memory.g_general_allocator) catch |err| {
        std.log.err("Failed to initialize renderer: {}", .{err});
        return @intFromEnum(BindingError.RuntimeError);
    };

    return @intFromEnum(BindingError.NoError);
}

/// EngineのZig側をシャットダウンします。
/// アプリケーション終了時に呼び出してください。
export fn quantum_zig_shutdown() void {
    // 全サブシステムをシャットダウン
    if (js_engine.Engine.instance) |instance| {
        instance.deinit();
        std.log.debug("JavaScript engine shutting down.", .{});
    }

    renderer.shutdown();
    std.log.debug("Renderer shutting down.", .{});

    // DOMキャッシュをクリア
    dom.clearGlobalCache();
    std.log.debug("DOM cache cleared.", .{});

    // SIMDリソースを解放
    simd.shutdown();
    std.log.debug("SIMD resources released.", .{});

    memory.deinitAllocator();
}

/// ヘルスチェック情報を取得します。
export fn quantum_zig_health_check() HealthInfo {
    return HealthInfo.init();
}

/// 診断情報を取得します。
export fn quantum_zig_diagnostics() DiagnosticsInfo {
    var javascript_heap_size: usize = 0;

    if (js_engine.Engine.instance) |instance| {
        if (instance.runtime) |runtime| {
            var current: usize = 0;
            var peak: usize = 0;
            // JavaScriptエンジンのメモリ使用量を取得
            const usage = jsGetMemoryUsage(runtime, &current, &peak);
            javascript_heap_size = current;
        }
    }

    return DiagnosticsInfo{
        .memory_usage_bytes = memory.getCurrentUsage(),
        .peak_memory_bytes = memory.getPeakUsage(),
        .active_workers = if (renderer.Renderer.instance) |r| r.getActiveWorkers() else 0,
        .frame_time_ns = if (renderer.Renderer.instance) |r| r.getLastFrameTime() else 0,
        .javascript_heap_bytes = javascript_heap_size,
        .is_simd_enabled = simd.isHardwareAccelerated(),
    };
}

//------------------------------------------------------------------------------
// JavaScript エンジン インターフェース
//------------------------------------------------------------------------------

/// JavaScriptエンジンを初期化します。
export fn quantum_zig_js_initialize(use_jit: bool, max_heap_mb: usize) i32 {
    // JavaScriptエンジンのオプションを設定
    const options = js_engine.EngineOptions{
        .optimize_jit = use_jit,
        .max_heap_size = max_heap_mb * 1024 * 1024,
    };

    // エンジンを初期化
    _ = js_engine.Engine.init(memory.g_general_allocator, options) catch |err| {
        std.log.err("Failed to initialize JS engine: {}", .{err});
        return @intFromEnum(BindingError.OutOfMemory);
    };

    return @intFromEnum(BindingError.NoError);
}

/// JavaScriptコードを実行します。
export fn quantum_zig_js_execute(script: [*:0]const u8, script_name: [*:0]const u8, result: *JSExecutionResult) i32 {
    if (script == null) return @intFromEnum(BindingError.NullPointer);
    if (result == null) return @intFromEnum(BindingError.NullPointer);

    // スクリプトをコンパイル・実行
    _ = js_engine.Engine.getInstance() catch {
        result.* = JSExecutionResult{
            .has_error = true,
            .error_message = dupeToNulTerminated("JavaScript engine not initialized"),
        };
        return @intFromEnum(BindingError.NotInitialized);
    };

    const script_str = std.mem.span(script);
    const name_str = std.mem.span(script_name);

    // エンジンインスタンスを取得してスクリプトを実行
    var engine = js_engine.Engine.getInstance() catch {
        result.* = JSExecutionResult{
            .has_error = true,
            .error_message = dupeToNulTerminated("JavaScript engine not initialized"),
        };
        return @intFromEnum(BindingError.NotInitialized);
    };

    var js_result = engine.executeScript(script_str, name_str) catch |err| {
        var err_msg: []const u8 = switch (err) {
            error.SyntaxError => "JavaScript syntax error",
            error.ExecutionError => "JavaScript execution error",
            error.OutOfMemory => "Out of memory during script execution",
            else => "Unknown JavaScript error",
        };
        result.* = JSExecutionResult{
            .has_error = true,
            .error_message = dupeToNulTerminated(err_msg),
        };
        return @intFromEnum(BindingError.ScriptError);
    };

    // 実行結果を変換
    setExecutionResultFromJSValue(js_result, result);

    return @intFromEnum(BindingError.NoError);
}

/// JSONをパースします。
export fn quantum_zig_js_parse_json(json: [*:0]const u8, result: *JSExecutionResult) i32 {
    if (json == null) return @intFromEnum(BindingError.NullPointer);
    if (result == null) return @intFromEnum(BindingError.NullPointer);

    const json_str = std.mem.span(json);

    // エンジンインスタンスを取得
    var engine = js_engine.Engine.getInstance() catch {
        result.* = JSExecutionResult{
            .has_error = true,
            .error_message = dupeToNulTerminated("JavaScript engine not initialized"),
        };
        return @intFromEnum(BindingError.NotInitialized);
    };

    // JSONを解析
    var js_result = engine.parseJSON(json_str) catch |err| {
        var err_msg: []const u8 = switch (err) {
            error.SyntaxError => "JSON syntax error",
            error.OutOfMemory => "Out of memory during JSON parsing",
            else => "Unknown JSON parsing error",
        };
        result.* = JSExecutionResult{
            .has_error = true,
            .error_message = dupeToNulTerminated(err_msg),
        };
        return @intFromEnum(BindingError.InvalidArgument);
    };

    // 結果を変換
    setExecutionResultFromJSValue(js_result, result);

    return @intFromEnum(BindingError.NoError);
}

//------------------------------------------------------------------------------
// DOM 操作インターフェース
//------------------------------------------------------------------------------

/// 新しいDOMドキュメントを作成します。
export fn quantum_zig_dom_create_document() u64 {
    // 実際のDOM作成
    const allocator = memory.g_general_allocator;

    // Document作成
    const doc = dom.Document.create(allocator, "text/html") catch |err| {
        std.log.err("Failed to create document: {}", .{err});
        return 0;
    };

    // IDを返却（単純にポインタをキャスト）
    return @intFromPtr(doc);
}

/// DOMノードをクエリで検索します。
export fn quantum_zig_dom_query_selector(document_id: u64, selector: [*:0]const u8, result: *DOMQueryResult) i32 {
    if (selector == null) return @intFromEnum(BindingError.NullPointer);
    if (result == null) return @intFromEnum(BindingError.NullPointer);

    // ドキュメントオブジェクトを取得
    const doc = @as(*dom.Document, @ptrFromInt(document_id));
    const selector_str = std.mem.span(selector);

    std.log.debug("Running query selector: {s}", .{selector_str});

    // DOMクエリ実行
    var nodes = dom.querySelector(doc, selector_str, memory.g_general_allocator) catch |err| {
        std.log.err("Failed to execute query selector: {}", .{err});
        result.error_code = @intFromEnum(BindingError.InvalidArgument);
        return @intFromEnum(BindingError.InvalidArgument);
    };
    defer nodes.deinit();

    // 結果をコピー
    if (nodes.items.len > 0) {
        const node_ids = memory.g_general_allocator.alloc(u64, nodes.items.len) catch {
            result.error_code = @intFromEnum(BindingError.OutOfMemory);
            return @intFromEnum(BindingError.OutOfMemory);
        };

        for (nodes.items, 0..) |node, i| {
            node_ids[i] = @intFromPtr(node);
        }

        result.node_ids = node_ids.ptr;
        result.count = nodes.items.len;
        result.capacity = nodes.items.len;
        result.error_code = @intFromEnum(BindingError.NoError);
    } else {
        // 結果なし
        result.count = 0;
        result.capacity = 0;
        result.node_ids = undefined;
    }

    return @intFromEnum(BindingError.NoError);
}

/// ノードのテキスト内容を設定します。
export fn quantum_zig_dom_set_text_content(node_id: u64, text: [*:0]const u8) i32 {
    if (text == null) return @intFromEnum(BindingError.NullPointer);

    // ノードを取得
    const node = @as(*dom.Node, @ptrFromInt(node_id));
    const text_str = std.mem.span(text);

    std.log.debug("Setting text content: {s}", .{text_str});

    // テキスト設定
    dom.setTextContent(node, text_str, memory.g_general_allocator) catch |err| {
        std.log.err("Failed to set text content: {}", .{err});
        return @intFromEnum(BindingError.InvalidArgument);
    };

    return @intFromEnum(BindingError.NoError);
}

/// ノードの属性を設定します。
export fn quantum_zig_dom_set_attribute(node_id: u64, name: [*:0]const u8, value: [*:0]const u8) i32 {
    if (name == null) return @intFromEnum(BindingError.NullPointer);

    // ノードを取得
    const node = @as(*dom.Node, @ptrFromInt(node_id));
    const name_str = std.mem.span(name);
    const value_str = if (value != null) std.mem.span(value) else "";

    // ノードタイプチェック（要素のみ属性を持てる）
    if (node.nodeType != .Element) {
        std.log.err("Cannot set attribute on non-element node", .{});
        return @intFromEnum(BindingError.InvalidArgument);
    }

    // 要素にキャスト
    const element = @ptrCast(*dom.Element, node.specific_data orelse {
        std.log.err("Invalid element node", .{});
        return @intFromEnum(BindingError.InvalidArgument);
    });

    std.log.debug("Setting attribute {s}={s}", .{ name_str, value_str });

    // 属性設定
    element.setAttribute(memory.g_general_allocator, name_str, value_str) catch |err| {
        std.log.err("Failed to set attribute: {}", .{err});
        return @intFromEnum(BindingError.InvalidArgument);
    };

    return @intFromEnum(BindingError.NoError);
}

//------------------------------------------------------------------------------
// レンダリングエンジンインターフェース
//------------------------------------------------------------------------------

/// レンダリングエンジンを初期化します。
export fn quantum_zig_renderer_initialize(options: *const RenderOptions) i32 {
    if (options == null) return @intFromEnum(BindingError.NullPointer);

    // レンダラーオプションを設定
    const renderer_options = renderer.RendererOptions{
        .threads = options.worker_threads,
        .use_gpu = options.use_gpu,
        .max_fps = options.max_fps,
        .gpu_backend = switch (options.gpu_backend) {
            0 => .auto,
            1 => .webgpu,
            2 => .vulkan,
            3 => .metal,
            4 => .d3d12,
            5 => .d3d11,
            6 => .opengl,
            else => .software,
        },
    };

    // レンダラーを初期化
    renderer.initialize(renderer_options) catch |err| {
        std.log.err("Failed to initialize renderer: {}", .{err});
        return @intFromEnum(BindingError.InternalError);
    };

    // レンダラーを初期サイズで設定
    if (renderer.Renderer.instance) |r| {
        r.resize(options.width, options.height) catch |err| {
            std.log.err("Failed to resize renderer: {}", .{err});
            return @intFromEnum(BindingError.InternalError);
        };
    }

    return @intFromEnum(BindingError.NoError);
}

/// レンダリングエンジンをシャットダウンします。
export fn quantum_zig_renderer_shutdown() void {
    renderer.shutdown();
}

/// レンダリングエンジンのサイズを変更します。
export fn quantum_zig_renderer_resize(width: u32, height: u32) i32 {
    if (renderer.Renderer.instance) |r| {
        r.resize(width, height) catch |err| {
            std.log.err("Failed to resize renderer: {}", .{err});
            return @intFromEnum(BindingError.InternalError);
        };
        return @intFromEnum(BindingError.NoError);
    } else {
        return @intFromEnum(BindingError.NotInitialized);
    }
}

/// 1フレームをレンダリングします。
export fn quantum_zig_renderer_render_frame(document_id: u64) i32 {
    if (renderer.Renderer.instance) |r| {
        // ドキュメントIDからDOMノードを取得
        const doc = @as(*dom.Document, @ptrFromInt(document_id));

        if (doc == null) {
            std.log.err("Invalid document ID: {d}", .{document_id});
            return @intFromEnum(BindingError.InvalidArgument);
        }

        // レンダリング実行
        r.renderFrame(doc) catch |err| {
            std.log.err("Failed to render frame: {}", .{err});
            return @intFromEnum(BindingError.RuntimeError);
        };

        return @intFromEnum(BindingError.NoError);
    } else {
        return @intFromEnum(BindingError.NotInitialized);
    }
}

//------------------------------------------------------------------------------
// メモリとリソース管理
//------------------------------------------------------------------------------

/// DOMクエリ結果を解放します。
export fn quantum_zig_free_dom_query_result(result: *DOMQueryResult) void {
    if (result == null) return;
    if (result.node_ids == null or result.capacity == 0) return;

    // メモリを解放
    memory.g_general_allocator.free(result.node_ids[0..result.capacity]);

    result.* = DOMQueryResult{
        .node_ids = undefined,
        .count = 0,
        .capacity = 0,
        .error_code = 0,
    };
}

/// CSSスタイル結果を解放します。
export fn quantum_zig_free_css_style_result(result: *CSSStyleResult) void {
    if (result == null) return;

    // プロパティ名を解放
    if (result.property_names != null) {
        for (result.property_names[0..result.count]) |name| {
            if (name != null) {
                memory.g_general_allocator.free(std.mem.span(name));
            }
        }
        memory.g_general_allocator.free(result.property_names[0..result.capacity]);
    }

    // プロパティ値を解放
    if (result.property_values != null) {
        for (result.property_values[0..result.count]) |value| {
            if (value != null) {
                memory.g_general_allocator.free(std.mem.span(value));
            }
        }
        memory.g_general_allocator.free(result.property_values[0..result.capacity]);
    }

    result.* = CSSStyleResult{};
}

/// JavaScriptの実行結果を解放します。
export fn quantum_zig_free_js_result(result: *JSExecutionResult) void {
    if (result == null) return;

    // 文字列を解放
    if (result.value_string != null) {
        memory.g_general_allocator.free(std.mem.span(result.value_string));
    }

    // エラーメッセージを解放
    if (result.error_message != null) {
        memory.g_general_allocator.free(std.mem.span(result.error_message));
    }

    result.* = JSExecutionResult{};
}

//------------------------------------------------------------------------------
// ユーティリティ関数
//------------------------------------------------------------------------------

/// バージョン文字列を取得します。
export fn quantum_zig_version() [*:0]const u8 {
    const version = "Quantum Zig Core 0.1.0";

    // 静的な文字列をそのまま返す
    return version;
}

/// 2つの数値を加算します。(テスト用)
export fn quantum_zig_add(a: i32, b: i32) i32 {
    return a + b;
}

/// SIMD命令セットが有効かどうかを確認します。
export fn quantum_zig_is_simd_enabled() bool {
    return simd.isHardwareAccelerated();
}

/// メモリ使用量を取得します。
export fn quantum_zig_memory_usage() usize {
    return memory.getCurrentUsage();
}

/// ピークメモリ使用量を取得します。
export fn quantum_zig_peak_memory_usage() usize {
    return memory.getPeakUsage();
}

//------------------------------------------------------------------------------
// テスト
//------------------------------------------------------------------------------

test "FFI initialization and version" {
    // 初期化
    const init_result = quantum_zig_initialize();
    defer quantum_zig_shutdown();

    try std.testing.expectEqual(@intFromEnum(BindingError.NoError), init_result);

    // バージョン取得
    const version = quantum_zig_version();
    const version_str = std.mem.span(version);

    try std.testing.expect(std.mem.startsWith(u8, version_str, "Quantum Zig Core"));
}

test "FFI basic operations" {
    // 加算テスト
    const sum = quantum_zig_add(2, 3);
    try std.testing.expectEqual(@as(i32, 5), sum);

    // ヘルスチェック
    const health = quantum_zig_health_check();
    try std.testing.expect(health.is_initialized);
}

// DOM関連のテストは実装完了後に追加

// ヘルパー関数: ヌル終端文字列を作成
fn dupeToNulTerminated(str: []const u8) [*:0]const u8 {
    var result = memory.g_general_allocator.allocSentinel(u8, str.len, 0) catch {
        return "Error: out of memory";
    };
    std.mem.copy(u8, result, str);
    return result.ptr;
}

// JSValue から JSExecutionResult へ変換するヘルパー関数
fn setExecutionResultFromJSValue(js_value: *js_engine.JSValue, result: *JSExecutionResult) void {
    switch (js_value.getType()) {
        .Undefined => {
            result.result_type = 0;
        },
        .Null => {
            result.result_type = 1;
        },
        .Boolean => {
            result.result_type = 2;
            result.value_boolean = js_value.getBooleanValue();
        },
        .Number => {
            result.result_type = 3;
            result.value_number = js_value.getNumberValue();
        },
        .String => {
            result.result_type = 4;
            result.value_string = dupeToNulTerminated(js_value.getStringValue());
        },
        .Object => {
            result.result_type = 5;
            result.value_object_id = js_value.getObjectId();
        },
    }
}
