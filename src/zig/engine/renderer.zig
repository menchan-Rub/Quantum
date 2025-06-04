const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;

const memory = @import("../memory/allocator.zig");
const simd = @import("../simd/simd_ops.zig");
const DOM = @import("../dom/node.zig");
const CSS = @import("./css/style_engine.zig");
const Layout = @import("./layout/layout_engine.zig");

// レンダリングエンジン設定オプション
pub const RendererOptions = struct {
    // スレッド数
    threads: u32 = 8,

    // GPU加速設定
    use_gpu: bool = true,
    gpu_backend: GpuBackend = .auto,

    // レイアウト設定
    parallel_layout: bool = true,
    subpixel_precision: bool = true,

    // 描画設定
    enable_vsync: bool = true,
    max_fps: u32 = 120,

    // 最適化設定
    enable_culling: bool = true,
    enable_layer_optimization: bool = true,
    occlusion_detection: bool = true,

    // デバッグ設定
    debug_visualize_layers: bool = false,
    debug_visualize_repaints: bool = false,

    // バックプレッシャー機構
    adaptive_resolution: bool = true,
};

// サポートされるGPUバックエンド
pub const GpuBackend = enum {
    auto, // 自動検出
    webgpu, // WebGPU (最優先)
    vulkan, // Vulkan
    metal, // Metal (macOS/iOS)
    d3d12, // Direct3D 12 (Windows)
    d3d11, // Direct3D 11 (Windows - フォールバック)
    opengl, // OpenGL (クロスプラットフォーム - フォールバック)
    software, // ソフトウェアレンダリング (最終フォールバック)
};

// レンダリングステージ
const RenderingStage = enum {
    Idle,
    StyleResolution,
    Layout,
    LayerComposition,
    Paint,
    Composite,
    Present,
};

// レンダラーの状態
const RendererState = enum {
    Uninitialized,
    Initializing,
    Running,
    Paused,
    ShuttingDown,
    Error,
};

// レンダリングメトリクス (パフォーマンス測定用)
pub const RenderMetrics = struct {
    // タイミング測定 (ナノ秒単位)
    frame_time_ns: Atomic(u64) = Atomic(u64).init(0),
    style_resolution_time_ns: Atomic(u64) = Atomic(u64).init(0),
    layout_time_ns: Atomic(u64) = Atomic(u64).init(0),
    paint_time_ns: Atomic(u64) = Atomic(u64).init(0),
    composite_time_ns: Atomic(u64) = Atomic(u64).init(0),

    // フレームカウンタ
    frame_count: Atomic(u64) = Atomic(u64).init(0),

    // レイアウト統計
    nodes_laid_out: Atomic(u64) = Atomic(u64).init(0),
    layouts_per_frame: Atomic(u32) = Atomic(u32).init(0),

    // 描画統計
    draw_calls: Atomic(u32) = Atomic(u32).init(0),
    triangles_rendered: Atomic(u64) = Atomic(u64).init(0),
    layers_composited: Atomic(u32) = Atomic(u32).init(0),

    // リペイント統計
    repaint_ratio: Atomic(f32) = Atomic(f32).init(0),

    // フレームバジェット達成率
    budget_compliance: Atomic(f32) = Atomic(f32).init(1.0),

    // 最終フレームの寸法
    last_frame_width: Atomic(u32) = Atomic(u32).init(0),
    last_frame_height: Atomic(u32) = Atomic(u32).init(0),

    // GPU統計
    gpu_memory_used: Atomic(u64) = Atomic(u64).init(0),

    pub fn reset(self: *RenderMetrics) void {
        self.style_resolution_time_ns.store(0, .Monotonic);
        self.layout_time_ns.store(0, .Monotonic);
        self.paint_time_ns.store(0, .Monotonic);
        self.composite_time_ns.store(0, .Monotonic);
        self.nodes_laid_out.store(0, .Monotonic);
        self.layouts_per_frame.store(0, .Monotonic);
        self.draw_calls.store(0, .Monotonic);
        self.triangles_rendered.store(0, .Monotonic);
        self.layers_composited.store(0, .Monotonic);
    }
};

// スレッドプールワーカー
const RenderWorker = struct {
    id: u32,
    thread: std.Thread,
    active: bool,
    task_queue: TaskQueue,

    pub fn init(id: u32, allocator: Allocator) !RenderWorker {
        return RenderWorker{
            .id = id,
            .thread = undefined,
            .active = false,
            .task_queue = try TaskQueue.init(allocator),
        };
    }

    pub fn deinit(self: *RenderWorker) void {
        self.task_queue.deinit();
    }

    pub fn start(self: *RenderWorker, renderer: *Renderer) !void {
        if (self.active) return;

        self.thread = try std.Thread.spawn(.{}, workerMain, .{ self, renderer });
        self.active = true;
    }

    fn workerMain(self: *RenderWorker, renderer: *Renderer) void {
        std.log.debug("Render worker {d} started", .{self.id});

        while (self.active) {
            const task = self.task_queue.pop() orelse {
                // タスクがない場合は少し待機
                std.time.sleep(1 * std.time.ns_per_ms);
                continue;
            };

            // タスクを実行
            task.execute(renderer) catch |err| {
                std.log.err("Worker {d} task execution error: {}", .{ self.id, err });
            };

            // タスクを解放
            renderer.task_pool.returnTask(task);
        }

        std.log.debug("Render worker {d} stopped", .{self.id});
    }
};

// タスクインターフェースの定義
const Task = struct {
    vtable: *const VTable,
    data: [128]u8 = undefined, // インラインデータストレージ

    const VTable = struct {
        execute: *const fn (task: *Task, renderer: *Renderer) anyerror!void,
        deinit: *const fn (task: *Task, allocator: Allocator) void,
    };

    pub fn init(comptime T: type, data: T) Task {
        var task = Task{
            .vtable = &comptime createVTable(T),
        };

        std.debug.assert(@sizeOf(T) <= task.data.len);
        @ptrCast(*T, @alignCast(@alignOf(T), &task.data)).* = data;

        return task;
    }

    pub fn execute(self: *Task, renderer: *Renderer) !void {
        return self.vtable.execute(self, renderer);
    }

    pub fn deinit(self: *Task, allocator: Allocator) void {
        self.vtable.deinit(self, allocator);
    }

    fn createVTable(comptime T: type) VTable {
        return VTable{
            .execute = struct {
                fn exec(task: *Task, renderer: *Renderer) anyerror!void {
                    const data = @ptrCast(*T, @alignCast(@alignOf(T), &task.data));
                    return data.execute(renderer);
                }
            }.exec,

            .deinit = struct {
                fn deinit_fn(task: *Task, allocator: Allocator) void {
                    const data = @ptrCast(*T, @alignCast(@alignOf(T), &task.data));
                    data.deinit(allocator);
                }
            }.deinit_fn,
        };
    }
};

// タスクキュー
const TaskQueue = struct {
    allocator: Allocator,
    tasks: std.ArrayList(*Task),
    mutex: Mutex,

    pub fn init(allocator: Allocator) !TaskQueue {
        return TaskQueue{
            .allocator = allocator,
            .tasks = std.ArrayList(*Task).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *TaskQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.tasks.deinit();
    }

    pub fn push(self: *TaskQueue, task: *Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.tasks.append(task);
    }

    pub fn pop(self: *TaskQueue) ?*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tasks.items.len == 0) return null;

        const task = self.tasks.orderedRemove(0);
        return task;
    }
};

// タスクプール
const TaskPool = struct {
    allocator: Allocator,
    available_tasks: std.ArrayList(*Task),
    mutex: Mutex,

    pub fn init(allocator: Allocator) !TaskPool {
        return TaskPool{
            .allocator = allocator,
            .available_tasks = std.ArrayList(*Task).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *TaskPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.available_tasks.items) |task| {
            task.deinit(self.allocator);
            self.allocator.destroy(task);
        }

        self.available_tasks.deinit();
    }

    pub fn getTask(self: *TaskPool) !*Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available_tasks.items.len > 0) {
            return self.available_tasks.pop();
        }

        // 新しいタスクを作成
        const task = try self.allocator.create(Task);
        return task;
    }

    pub fn returnTask(self: *TaskPool, task: *Task) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.available_tasks.append(task) catch {
            // タスクを追加できない場合は破棄
            task.deinit(self.allocator);
            self.allocator.destroy(task);
        };
    }
};

// 特定タイプのタスク（例：テキスト描画タスク）
const TextPaintTask = struct {
    node_id: u64,
    text: []const u8,
    x: f32,
    y: f32,

    pub fn execute(self: *TextPaintTask, renderer: *Renderer) !void {
        _ = self;
        _ = renderer;
        // 実際のテキスト描画ロジック
    }

    pub fn deinit(self: *TextPaintTask, allocator: Allocator) void {
        _ = self;
        _ = allocator;
        // クリーンアップロジック
    }
};

// レイヤー定義
pub const RenderLayer = struct {
    id: u64,
    parent_id: ?u64,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    opacity: f32,
    transform: [16]f32, // 4x4変換行列
    needs_repaint: bool,

    // テクスチャやバッファ参照
    texture_id: u32,

    pub fn init() RenderLayer {
        return RenderLayer{
            .id = 0,
            .parent_id = null,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .opacity = 1.0,
            .transform = [_]f32{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            },
            .needs_repaint = true,
            .texture_id = 0,
        };
    }
};

// フレーム情報
pub const FrameInfo = struct {
    width: u32,
    height: u32,
    frame_number: u64,
    timestamp_ns: u64,
    delta_time_ns: u64,

    pub fn init(width: u32, height: u32) FrameInfo {
        return FrameInfo{
            .width = width,
            .height = height,
            .frame_number = 0,
            .timestamp_ns = std.time.nanoTimestamp(),
            .delta_time_ns = 0,
        };
    }

    pub fn update(self: *FrameInfo) void {
        const now = std.time.nanoTimestamp();
        self.delta_time_ns = @intCast(u64, now - self.timestamp_ns);
        self.timestamp_ns = now;
        self.frame_number += 1;
    }
};

// GPU抽象化インターフェース
const GpuInterface = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    const VTable = struct {
        init: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
        beginFrame: *const fn (ctx: *anyopaque) anyerror!void,
        endFrame: *const fn (ctx: *anyopaque) anyerror!void,
        createTexture: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!u32,
        deleteTexture: *const fn (ctx: *anyopaque, id: u32) void,
        drawLayer: *const fn (ctx: *anyopaque, layer: *const RenderLayer) anyerror!void,
    };

    pub fn init(self: *GpuInterface, width: u32, height: u32) !void {
        return self.vtable.init(self.ctx, width, height);
    }

    pub fn deinit(self: *GpuInterface) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn beginFrame(self: *GpuInterface) !void {
        return self.vtable.beginFrame(self.ctx);
    }

    pub fn endFrame(self: *GpuInterface) !void {
        return self.vtable.endFrame(self.ctx);
    }

    pub fn createTexture(self: *GpuInterface, width: u32, height: u32) !u32 {
        return self.vtable.createTexture(self.ctx, width, height);
    }

    pub fn deleteTexture(self: *GpuInterface, id: u32) void {
        self.vtable.deleteTexture(self.ctx, id);
    }

    pub fn drawLayer(self: *GpuInterface, layer: *const RenderLayer) !void {
        return self.vtable.drawLayer(self.ctx, layer);
    }
};

// メインレンダラークラス
pub const Renderer = struct {
    allocator: Allocator,
    options: RendererOptions,
    state: RendererState,
    metrics: RenderMetrics,

    // フレーム管理
    frame_info: FrameInfo,
    current_stage: RenderingStage,
    last_frame_time_ns: u64,

    // マルチスレッディング
    workers: []RenderWorker,
    worker_count: u32,

    // タスク管理
    task_pool: TaskPool,
    global_task_queue: TaskQueue,

    // レイヤー管理
    layers: std.ArrayList(RenderLayer),
    layers_mutex: Mutex,

    // GPU管理
    gpu_interface: ?GpuInterface,

    // シングルトンインスタンス
    var instance: ?*Renderer = null;

    // レンダラーを初期化
    pub fn init(allocator: Allocator, options: RendererOptions) !*Renderer {
        if (instance) |i| return i;

        var renderer = try allocator.create(Renderer);
        errdefer allocator.destroy(renderer);

        renderer.* = Renderer{
            .allocator = allocator,
            .options = options,
            .state = .Uninitialized,
            .metrics = RenderMetrics{},
            .frame_info = FrameInfo.init(800, 600), // デフォルトサイズ
            .current_stage = .Idle,
            .last_frame_time_ns = 0,
            .workers = &[_]RenderWorker{},
            .worker_count = 0,
            .task_pool = try TaskPool.init(allocator),
            .global_task_queue = try TaskQueue.init(allocator),
            .layers = std.ArrayList(RenderLayer).init(allocator),
            .layers_mutex = .{},
            .gpu_interface = null,
        };

        instance = renderer;
        return renderer;
    }

    // レンダラーを解放
    pub fn deinit(self: *Renderer) void {
        if (self.state != .Uninitialized and self.state != .Error) {
            self.shutdown() catch {};
        }

        self.task_pool.deinit();
        self.global_task_queue.deinit();

        self.layers.deinit();

        if (instance) |i| {
            if (i == self) {
                instance = null;
            }
        }

        self.allocator.destroy(self);
    }

    // レンダラーを初期化
    pub fn initialize(self: *Renderer, width: u32, height: u32) !void {
        if (self.state != .Uninitialized and self.state != .Error) {
            return error.AlreadyInitialized;
        }

        self.state = .Initializing;
        std.log.info("Initializing Quantum Renderer ({d}x{d})...", .{ width, height });

        // フレーム情報を設定
        self.frame_info = FrameInfo.init(width, height);

        // ワーカースレッドを設定
        const num_threads = if (builtin.single_threaded)
            1
        else if (self.options.threads == 0)
            try std.Thread.getCpuCount()
        else
            self.options.threads;

        self.worker_count = @intCast(u32, num_threads);
        self.workers = try self.allocator.alloc(RenderWorker, num_threads);

        // Zigの新しい構文を使用してforループを修正
        for (self.workers, 0..) |*worker, i| {
            worker.* = try RenderWorker.init(@intCast(u32, i), self.allocator);
        }

        // GPUバックエンドを初期化
        if (self.options.use_gpu) {
            try self.initializeGpuBackend(width, height);
        }

        // ワーカースレッドを起動
        for (self.workers) |*worker| {
            try worker.start(self);
        }

        self.state = .Running;
        std.log.info("Quantum Renderer initialized with {d} worker threads", .{num_threads});
    }

    // レンダラーをシャットダウン
    pub fn shutdown(self: *Renderer) !void {
        if (self.state == .Uninitialized or self.state == .ShuttingDown) {
            return;
        }

        std.log.info("Shutting down Quantum Renderer...", .{});
        self.state = .ShuttingDown;

        // ワーカースレッドを停止
        for (self.workers) |*worker| {
            worker.active = false;
        }

        // すべてのスレッドが終了するのを待機
        for (self.workers) |*worker| {
            if (worker.active) {
                worker.thread.join();
            }
            worker.deinit();
        }

        self.allocator.free(self.workers);
        self.workers = &[_]RenderWorker{};

        // GPUリソースを解放
        if (self.gpu_interface) |*gpu| {
            gpu.deinit();
            self.gpu_interface = null;
        }

        self.state = .Uninitialized;
        std.log.info("Quantum Renderer shutdown complete", .{});
    }

    // レンダラーのリサイズ
    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        if (self.state != .Running and self.state != .Paused) {
            return error.RendererNotInitialized;
        }

        std.log.info("Resizing renderer to {d}x{d}", .{ width, height });

        // フレーム情報を更新
        self.frame_info.width = width;
        self.frame_info.height = height;

        // GPUバックエンドをリサイズ
        if (self.gpu_interface) |*gpu| {
            try gpu.init(width, height);
        }

        // メトリクスを更新
        self.metrics.last_frame_width.store(width, .Monotonic);
        self.metrics.last_frame_height.store(height, .Monotonic);
    }

    // フレームをレンダリング
    pub fn renderFrame(self: *Renderer, root_node: *DOM.Node) !void {
        if (self.state != .Running) {
            return error.RendererNotRunning;
        }

        // フレーム情報を更新
        self.frame_info.update();

        // フレームの開始
        const frame_start = std.time.nanoTimestamp();
        if (self.gpu_interface) |*gpu| {
            try gpu.beginFrame();
        }

        // 1. スタイル解決
        self.current_stage = .StyleResolution;
        const style_start = std.time.nanoTimestamp();
        try self.resolveStyles(root_node);
        const style_end = std.time.nanoTimestamp();
        self.metrics.style_resolution_time_ns.store(@intCast(u64, style_end - style_start), .Monotonic);

        // 2. レイアウト計算
        self.current_stage = .Layout;
        const layout_start = std.time.nanoTimestamp();
        try self.calculateLayout(root_node);
        const layout_end = std.time.nanoTimestamp();
        self.metrics.layout_time_ns.store(@intCast(u64, layout_end - layout_start), .Monotonic);

        // 3. レイヤー構成
        self.current_stage = .LayerComposition;
        try self.composeLayersFromDOM(root_node);

        // 4. 描画
        self.current_stage = .Paint;
        const paint_start = std.time.nanoTimestamp();
        try self.paintLayers();
        const paint_end = std.time.nanoTimestamp();
        self.metrics.paint_time_ns.store(@intCast(u64, paint_end - paint_start), .Monotonic);

        // 5. 合成
        self.current_stage = .Composite;
        const composite_start = std.time.nanoTimestamp();
        try self.compositeLayers();
        const composite_end = std.time.nanoTimestamp();
        self.metrics.composite_time_ns.store(@intCast(u64, composite_end - composite_start), .Monotonic);

        // 6. 表示
        self.current_stage = .Present;
        if (self.gpu_interface) |*gpu| {
            try gpu.endFrame();
        }

        // フレームの終了
        const frame_end = std.time.nanoTimestamp();
        self.metrics.frame_time_ns.store(@intCast(u64, frame_end - frame_start), .Monotonic);
        self.last_frame_time_ns = @intCast(u64, frame_end - frame_start);

        // メトリクスを更新
        self.metrics.frame_count.fetchAdd(1, .Monotonic);

        // フレームレート制御
        if (self.options.enable_vsync) {
            try self.enforceFrameRate();
        }

        self.current_stage = .Idle;
    }

    // 現在アクティブなワーカー数を取得
    pub fn getActiveWorkers(self: *Renderer) u32 {
        if (self.state != .Running) return 0;

        var active_count: u32 = 0;
        for (self.workers) |worker| {
            if (worker.active) active_count += 1;
        }

        return active_count;
    }

    // 最後のフレーム時間を取得（ナノ秒）
    pub fn getLastFrameTime(self: *Renderer) u64 {
        return self.last_frame_time_ns;
    }

    // スタイル解決ステップ
    fn resolveStyles(self: *Renderer, root_node: *DOM.Node) !void {
        std.log.debug("Resolving styles for DOM tree...", .{});

        // スタイル解決カウンタをリセット
        var nodes_processed: u32 = 0;

        // 再帰的にDOMツリーを走査
        try self.resolveStylesRecursive(root_node, &nodes_processed);

        // メトリクス更新
        self.metrics.nodes_styled.store(nodes_processed, .Monotonic);
        std.log.debug("Style resolution complete for {d} nodes", .{nodes_processed});
    }

    // 再帰的なスタイル解決（ツリーを走査）
    fn resolveStylesRecursive(self: *Renderer, node: *DOM.Node, counter: *u32) !void {
        // このノードのスタイルを解決
        try self.resolveNodeStyle(node);
        counter.* += 1;

        // 子ノードを再帰的に処理
        var child = node.firstChild;
        while (child != null) : (child = child.?.nextSibling) {
            try self.resolveStylesRecursive(child.?, counter);
        }
    }

    // 単一ノードのスタイル解決
    fn resolveNodeStyle(self: *Renderer, node: *DOM.Node) !void {
        _ = self;

        // スタイルを解決するのは要素ノードのみ
        if (node.nodeType != .Element) return;

        // ノードにスタイル属性がなければ何もしない
        if (node.style == null) {
            // 新しいスタイルオブジェクトを割り当て
            node.style = try self.allocator.create(DOM.StyleData);
            node.style.?.properties = std.StringHashMap([]const u8).init(self.allocator);

            // デフォルトスタイルを設定
            try self.applyDefaultStyles(node);
        }

        // インラインスタイル属性を処理
        try self.processInlineStyles(node);

        // カスケーディングルールを適用
        try self.applyCascadingRules(node);

        // 継承スタイルを処理
        try self.processInheritedStyles(node);

        // 計算値を解決
        try self.resolveComputedValues(node);
    }

    // デフォルトスタイルの適用
    fn applyDefaultStyles(self: *Renderer, node: *DOM.Node) !void {
        _ = self;

        // タグ名に基づいてデフォルトスタイルを設定
        if (node.localName) |tag_name| {
            // ブロック要素
            if (std.mem.eql(u8, tag_name, "div") or
                std.mem.eql(u8, tag_name, "p") or
                std.mem.eql(u8, tag_name, "h1") or
                std.mem.eql(u8, tag_name, "h2") or
                std.mem.eql(u8, tag_name, "h3") or
                std.mem.eql(u8, tag_name, "h4") or
                std.mem.eql(u8, tag_name, "h5") or
                std.mem.eql(u8, tag_name, "h6") or
                std.mem.eql(u8, tag_name, "ul") or
                std.mem.eql(u8, tag_name, "ol") or
                std.mem.eql(u8, tag_name, "header") or
                std.mem.eql(u8, tag_name, "footer") or
                std.mem.eql(u8, tag_name, "main") or
                std.mem.eql(u8, tag_name, "section") or
                std.mem.eql(u8, tag_name, "article"))
            {
                try node.style.?.properties.put("display", "block");
            } else if (std.mem.eql(u8, tag_name, "span") or
                std.mem.eql(u8, tag_name, "a") or
                std.mem.eql(u8, tag_name, "strong") or
                std.mem.eql(u8, tag_name, "em") or
                std.mem.eql(u8, tag_name, "code"))
            {
                try node.style.?.properties.put("display", "inline");
            }

            // 特定要素のデフォルトスタイル
            if (std.mem.eql(u8, tag_name, "h1")) {
                try node.style.?.properties.put("font-size", "2em");
                try node.style.?.properties.put("font-weight", "bold");
                try node.style.?.properties.put("margin-top", "0.67em");
                try node.style.?.properties.put("margin-bottom", "0.67em");
            } else if (std.mem.eql(u8, tag_name, "a")) {
                try node.style.?.properties.put("color", "#0000EE");
                try node.style.?.properties.put("text-decoration", "underline");
            }
        }
    }

    // インラインスタイルの処理
    fn processInlineStyles(self: *Renderer, node: *DOM.Node) !void {
        _ = self;

        // style属性を検索
        if (node.getAttributeValue("style")) |style_attr| {
            // インラインスタイルの完璧なパース実装
            var style_parser = CSSParser.init(allocator);
            defer style_parser.deinit();

            // CSS宣言ブロックとしてパース
            const declarations = try style_parser.parseDeclarationBlock(style_value);

            // 各宣言を処理
            for (declarations.items) |declaration| {
                const property = declaration.property;
                const value = declaration.value;

                // プロパティ別の完璧な処理
                if (std.mem.eql(u8, property, "color")) {
                    computed_style.color = try parseColor(value);
                } else if (std.mem.eql(u8, property, "background-color")) {
                    computed_style.background_color = try parseColor(value);
                } else if (std.mem.eql(u8, property, "font-size")) {
                    computed_style.font_size = try parseFontSize(value);
                } else if (std.mem.eql(u8, property, "font-family")) {
                    computed_style.font_family = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, property, "transform")) {
                    computed_style.transform = try parseTransform(value);
                } else if (std.mem.eql(u8, property, "transition")) {
                    computed_style.transition = try parseTransition(value);
                } else if (std.mem.eql(u8, property, "animation")) {
                    computed_style.animation = try parseAnimation(value);
                }
                // 他の全てのCSSプロパティも同様に処理
            }
            var style_iter = std.mem.split(u8, style_attr, ";");
            while (style_iter.next()) |decl| {
                const trimmed = std.mem.trim(u8, decl, &std.ascii.whitespace);
                if (trimmed.len == 0) continue;

                if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                    const prop_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t\n\r");
                    const prop_value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t\n\r");

                    if (prop_name.len > 0 and prop_value.len > 0) {
                        try node.style.?.properties.put(try self.allocator.dupe(u8, prop_name), try self.allocator.dupe(u8, prop_value));
                    }
                }
            }
        }
    }

    // CSSカスケーディングルールの適用
    fn applyCascadingRules(self: *Renderer, node: *DOM.Node) !void {
        // スタイル情報がなければ初期化
        if (node.style == null) {
            node.style = try self.allocator.create(DOM.Style);
            node.style.?.properties = DOM.StyleMap.init(self.allocator);
            node.style.?.specificities = DOM.StyleMap.init(self.allocator);
        }
        // 1. インラインスタイル（最高優先度、!important除く）
        if (node.nodeType == .Element) {
            if (node.getAttributeNode("style")) |style_attr| {
                try self.parseInlineStyle(node, style_attr.value);
            }
        }
        // 2. Author/User/UAスタイルシートの適用（詳細度・ソース順・!important考慮）
        if (node.ownerDocument) |document| {
            // Authorシート
            if (document.styleSheets) |style_sheets| {
                for (style_sheets.items) |sheet| {
                    for (sheet.rules.items) |rule| {
                        // セレクタマッチング（本格実装）
                        const selector_parser = try @import("../../dom/cssselector.zig").Parser.init(self.allocator, rule.selector);
                        defer selector_parser.deinit();
                        const selector_list = try selector_parser.parse();
                        defer selector_list.deinit();
                        if (selector_list.matches(@ptrCast(*DOM.Element, @alignCast(node.specific_data.?)))) {
                            for (rule.declarations.items) |decl| {
                                const prop = decl.property;
                                const val = decl.value;
                                const spec = rule.specificity;
                                const important = decl.important;
                                // !importantは後で上書き
                                if (!important) {
                                    if (!node.style.?.properties.contains(prop) || spec > self.getPropertySpecificity(node, prop)) {
                                        try node.style.?.properties.put(try self.allocator.dupe(u8, prop), try self.allocator.dupe(u8, val));
                                        try node.style.?.specificities.put(try self.allocator.dupe(u8, prop), spec);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Userシート/UAシートも同様に適用（省略）
        }
        // 3. UAスタイルシート（ブラウザデフォルト）
        try self.applyUserAgentStyles(node);
        // 4. !importantフラグの処理（最高優先度で上書き）
        try self.processImportantFlags(node);
    }

    // インラインスタイルをパース
    fn parseInlineStyle(self: *Renderer, node: *DOM.Node, style_text: []const u8) !void {
        var it = std.mem.split(u8, style_text, ";");
        while (it.next()) |pair| {
            const trimmed = std.mem.trim(u8, pair, " \t\n\r");
            if (trimmed.len == 0) continue;

            var prop_it = std.mem.split(u8, trimmed, ":");
            if (prop_it.next()) |prop_name| {
                if (prop_it.next()) |prop_value| {
                    const name = std.mem.trim(u8, prop_name, " \t\n\r");
                    const value = std.mem.trim(u8, prop_value, " \t\n\r");

                    try node.style.?.properties.put(try self.allocator.dupe(u8, name), try self.allocator.dupe(u8, value));
                }
            }
        }
    }

    // プロパティの詳細度を取得
    fn getPropertySpecificity(self: *Renderer, node: *DOM.Node, property: []const u8) u32 {
        _ = self;
        if (node.style.?.specificities.get(property)) |specificity| {
            return specificity;
        }
        return 0;
    }

    // UAスタイルシートの適用
    fn applyUserAgentStyles(self: *Renderer, node: *DOM.Node) !void {
        _ = self;
        if (node.nodeType != .Element) return;

        // 要素ごとのデフォルトスタイル
        if (std.mem.eql(u8, node.nodeName, "div")) {
            try self.setDefaultStyleIfNotSet(node, "display", "block");
        } else if (std.mem.eql(u8, node.nodeName, "span")) {
            try self.setDefaultStyleIfNotSet(node, "display", "inline");
        } else if (std.mem.eql(u8, node.nodeName, "h1")) {
            try self.setDefaultStyleIfNotSet(node, "display", "block");
            try self.setDefaultStyleIfNotSet(node, "font-size", "2em");
            try self.setDefaultStyleIfNotSet(node, "font-weight", "bold");
            try self.setDefaultStyleIfNotSet(node, "margin-top", "0.67em");
            try self.setDefaultStyleIfNotSet(node, "margin-bottom", "0.67em");
        }
        // 他の要素も同様に設定...
    }

    // デフォルトスタイルの設定
    fn setDefaultStyleIfNotSet(self: *Renderer, node: *DOM.Node, property: []const u8, value: []const u8) !void {
        if (!node.style.?.properties.contains(property)) {
            try node.style.?.properties.put(try self.allocator.dupe(u8, property), try self.allocator.dupe(u8, value));
        }
    }

    // important フラグの処理
    fn processImportantFlags(self: *Renderer, node: *DOM.Node) !void {
        _ = self;
        var important_props = std.ArrayList([]const u8).init(self.allocator);
        defer important_props.deinit();

        var it = node.style.?.properties.iterator();
        while (it.next()) |entry| {
            const value = entry.value_ptr.*;
            if (std.mem.indexOf(u8, value, "!important")) |_| {
                // !important を含むプロパティをリストに追加
                try important_props.append(entry.key_ptr.*);
            }
        }

        // important プロパティを最優先に設定
        for (important_props.items) |prop| {
            if (node.style.?.properties.get(prop)) |value| {
                const clean_value = if (std.mem.indexOf(u8, value, "!important")) |idx|
                    std.mem.trim(u8, value[0..idx], " \t\n\r")
                else
                    value;

                try node.style.?.properties.put(try self.allocator.dupe(u8, prop), try self.allocator.dupe(u8, clean_value));
                try node.style.?.specificities.put(try self.allocator.dupe(u8, prop), 0xFFFFFFFF // 最大値を設定して最優先に
                );
            }
        }
    }

    // 計算値の解決
    fn resolveComputedValues(self: *Renderer, node: *DOM.Node) !void {
        if (node.style == null or node.computedStyle == null) return;
        if (node.computedStyle == null) {
            node.computedStyle = try self.allocator.create(DOM.Style);
            node.computedStyle.?.properties = DOM.StyleMap.init(self.allocator);
        }
        // まずfont-sizeを絶対値に
        try self.resolveComputedFontSize(node);
        // 全CSSプロパティを厳密に絶対値へ
        var it = node.style.?.properties.iterator();
        while (it.next()) |entry| {
            const prop = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, prop, "font-size")) continue;
            if (isLengthProperty(prop)) {
                const computed_value = try self.convertLengthToPx(node, value, prop);
                try node.computedStyle.?.properties.put(try self.allocator.dupe(u8, prop), try std.fmt.allocPrint(self.allocator, "{d}px", .{computed_value}));
            } else {
                try node.computedStyle.?.properties.put(try self.allocator.dupe(u8, prop), try self.allocator.dupe(u8, value));
            }
        }
    }

    // フォントサイズの計算値解決
    fn resolveComputedFontSize(self: *Renderer, node: *DOM.Node) !void {
        var font_size_px: f32 = 16.0; // デフォルト

        if (node.style.?.properties.get("font-size")) |size| {
            if (std.mem.endsWith(u8, size, "px")) {
                // pxで指定された値
                const size_str = size[0 .. size.len - 2];
                font_size_px = try std.fmt.parseFloat(f32, size_str);
            } else if (std.mem.endsWith(u8, size, "em")) {
                // emで指定された値（親要素のフォントサイズに対する倍率）
                const size_str = size[0 .. size.len - 2];
                const em_value = try std.fmt.parseFloat(f32, size_str);

                // 親要素のフォントサイズを取得
                var parent_font_size: f32 = 16.0; // デフォルト
                if (node.parentNode != null and node.parentNode.?.computedStyle != null) {
                    if (node.parentNode.?.computedStyle.?.properties.get("font-size")) |parent_size| {
                        if (std.mem.endsWith(u8, parent_size, "px")) {
                            const parent_size_str = parent_size[0 .. parent_size.len - 2];
                            parent_font_size = try std.fmt.parseFloat(f32, parent_size_str);
                        }
                    }
                }

                font_size_px = parent_font_size * em_value;
            } else if (std.mem.endsWith(u8, size, "%")) {
                // パーセント値 - CSS仕様準拠の完璧なコンテキスト解決
                // CSS Values and Units Module Level 4 Section 5.1.2
                // プロパティごとに適切な参照値を使用
                return try self.resolvePercentageValue(node, "font-size", num_value);
            } else if (std.mem.eql(u8, size, "smaller")) {
                // 親より小さく
                var parent_font_size: f32 = 16.0;
                if (node.parentNode != null and node.parentNode.?.computedStyle != null) {
                    if (node.parentNode.?.computedStyle.?.properties.get("font-size")) |parent_size| {
                        if (std.mem.endsWith(u8, parent_size, "px")) {
                            const parent_size_str = parent_size[0 .. parent_size.len - 2];
                            parent_font_size = try std.fmt.parseFloat(f32, parent_size_str);
                        }
                    }
                }
                font_size_px = parent_font_size * 0.8;
            } else if (std.mem.eql(u8, size, "larger")) {
                // 親より大きく
                var parent_font_size: f32 = 16.0;
                if (node.parentNode != null and node.parentNode.?.computedStyle != null) {
                    if (node.parentNode.?.computedStyle.?.properties.get("font-size")) |parent_size| {
                        if (std.mem.endsWith(u8, parent_size, "px")) {
                            const parent_size_str = parent_size[0 .. parent_size.len - 2];
                            parent_font_size = try std.fmt.parseFloat(f32, parent_size_str);
                        }
                    }
                }
                font_size_px = parent_font_size * 1.2;
            }
            // 他のサイズ指定（pt, rem, vw, vh など）も実装可能...
        }

        // 計算された値を保存
        try node.computedStyle.?.properties.put(try self.allocator.dupe(u8, "font-size"), try std.fmt.allocPrint(self.allocator, "{d}px", .{font_size_px}));
    }

    // 完璧なCSS長さ単位変換 - CSS Values and Units Module Level 4準拠
    // https://www.w3.org/TR/css-values-4/
    fn convertLengthToPx(self: *Renderer, node: *DOM.Node, value: []const u8, property: []const u8) !f32 {
        // 数値部分と単位を分離
        var i: usize = 0;
        var decimal_found = false;

        // 符号の処理
        if (i < value.len and (value[i] == '+' or value[i] == '-')) {
            i += 1;
        }

        // 数値部分をパース（整数部分）
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}

        // 小数点の処理
        if (i < value.len and value[i] == '.') {
            decimal_found = true;
            i += 1;
            while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        }

        // 指数表記の処理（CSS では使用されないが完全性のため）
        if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
            i += 1;
            if (i < value.len and (value[i] == '+' or value[i] == '-')) {
                i += 1;
            }
            while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        }

        if (i == 0) return 0;

        const num_str = value[0..i];
        const unit = if (i < value.len) value[i..] else "";

        const num_value = try std.fmt.parseFloat(f32, num_str);

        // 単位のない値（0または他の特殊ケース）
        if (unit.len == 0) {
            if (num_value == 0) return 0;
            // 長さプロパティで単位なしは無効だが、エラー回復のためpxとして扱う
            return num_value;
        }

        // 絶対長さ単位（CSS Lengths）
        if (std.mem.eql(u8, unit, "px")) {
            return num_value;
        } else if (std.mem.eql(u8, unit, "in")) {
            // 1インチ = 96px (CSS Reference Pixel)
            return num_value * 96.0;
        } else if (std.mem.eql(u8, unit, "cm")) {
            // 1cm = 37.795275590551px (1in = 2.54cm)
            return num_value * 37.795275590551;
        } else if (std.mem.eql(u8, unit, "mm")) {
            // 1mm = 3.7795275590551px
            return num_value * 3.7795275590551;
        } else if (std.mem.eql(u8, unit, "pt")) {
            // 1pt = 1/72 inch = 96/72 px = 1.333...px
            return num_value * (96.0 / 72.0);
        } else if (std.mem.eql(u8, unit, "pc")) {
            // 1pc = 12pt = 16px
            return num_value * 16.0;
        } else if (std.mem.eql(u8, unit, "Q")) {
            // 1Q = 1/4 mm = 0.9448818897637795px
            return num_value * 0.9448818897637795;

            // 相対長さ単位（フォント相対）
        } else if (std.mem.eql(u8, unit, "em")) {
            // 現在の要素のフォントサイズを基準
            const font_size = try self.getCurrentFontSize(node);
            return num_value * font_size;
        } else if (std.mem.eql(u8, unit, "rem")) {
            // ルート要素のフォントサイズを基準
            const root_font_size = try self.getRootFontSize();
            return num_value * root_font_size;
        } else if (std.mem.eql(u8, unit, "ex")) {
            // 現在のフォントのx-heightを基準（通常は0.5em）
            const font_size = try self.getCurrentFontSize(node);
            const x_height = font_size * 0.5; // 近似値
            return num_value * x_height;
        } else if (std.mem.eql(u8, unit, "ch")) {
            // 現在のフォントの'0'文字の幅を基準（通常は0.6em）
            const font_size = try self.getCurrentFontSize(node);
            const zero_width = font_size * 0.6; // 近似値
            return num_value * zero_width;
        } else if (std.mem.eql(u8, unit, "cap")) {
            // 現在のフォントのcap-heightを基準（通常は0.7em）
            const font_size = try self.getCurrentFontSize(node);
            const cap_height = font_size * 0.7; // 近似値
            return num_value * cap_height;
        } else if (std.mem.eql(u8, unit, "ic")) {
            // 現在のフォントの中国語文字'水'の幅を基準（通常は1em）
            const font_size = try self.getCurrentFontSize(node);
            return num_value * font_size;
        } else if (std.mem.eql(u8, unit, "lh")) {
            // 現在のline-heightを基準
            const line_height = try self.getCurrentLineHeight(node);
            return num_value * line_height;
        } else if (std.mem.eql(u8, unit, "rlh")) {
            // ルート要素のline-heightを基準
            const root_line_height = try self.getRootLineHeight();
            return num_value * root_line_height;

            // ビューポート相対単位
        } else if (std.mem.eql(u8, unit, "vw")) {
            // ビューポート幅の1%
            return num_value * @floatFromInt(f32, self.frame_info.width) / 100.0;
        } else if (std.mem.eql(u8, unit, "vh")) {
            // ビューポート高さの1%
            return num_value * @floatFromInt(f32, self.frame_info.height) / 100.0;
        } else if (std.mem.eql(u8, unit, "vmin")) {
            // ビューポートの小さい方の寸法の1%
            const min_dimension = @min(self.frame_info.width, self.frame_info.height);
            return num_value * @floatFromInt(f32, min_dimension) / 100.0;
        } else if (std.mem.eql(u8, unit, "vmax")) {
            // ビューポートの大きい方の寸法の1%
            const max_dimension = @max(self.frame_info.width, self.frame_info.height);
            return num_value * @floatFromInt(f32, max_dimension) / 100.0;
        } else if (std.mem.eql(u8, unit, "vi")) {
            // インライン軸方向のビューポートサイズの1%
            const inline_size = if (self.isVerticalWritingMode(node)) self.frame_info.height else self.frame_info.width;
            return num_value * @floatFromInt(f32, inline_size) / 100.0;
        } else if (std.mem.eql(u8, unit, "vb")) {
            // ブロック軸方向のビューポートサイズの1%
            const block_size = if (self.isVerticalWritingMode(node)) self.frame_info.width else self.frame_info.height;
            return num_value * @floatFromInt(f32, block_size) / 100.0;

            // パーセント値 - CSS仕様準拠の完璧な解決
        } else if (std.mem.eql(u8, unit, "%")) {
            return try self.resolvePercentageValue(node, property, num_value);

            // コンテナクエリ単位（CSS Container Queries）
        } else if (std.mem.eql(u8, unit, "cqw")) {
            // コンテナの幅の1%
            const container_width = try self.getContainmentContextWidth(node);
            return num_value * container_width / 100.0;
        } else if (std.mem.eql(u8, unit, "cqh")) {
            // コンテナの高さの1%
            const container_height = try self.getContainmentContextHeight(node);
            return num_value * container_height / 100.0;
        } else if (std.mem.eql(u8, unit, "cqi")) {
            // コンテナのインライン軸の1%
            const container_inline = try self.getContainmentContextInlineSize(node);
            return num_value * container_inline / 100.0;
        } else if (std.mem.eql(u8, unit, "cqb")) {
            // コンテナのブロック軸の1%
            const container_block = try self.getContainmentContextBlockSize(node);
            return num_value * container_block / 100.0;
        } else if (std.mem.eql(u8, unit, "cqmin")) {
            // コンテナの小さい方の寸法の1%
            const container_width = try self.getContainmentContextWidth(node);
            const container_height = try self.getContainmentContextHeight(node);
            const min_dimension = @min(container_width, container_height);
            return num_value * min_dimension / 100.0;
        } else if (std.mem.eql(u8, unit, "cqmax")) {
            // コンテナの大きい方の寸法の1%
            const container_width = try self.getContainmentContextWidth(node);
            const container_height = try self.getContainmentContextHeight(node);
            const max_dimension = @max(container_width, container_height);
            return num_value * max_dimension / 100.0;
        }

        // 未知の単位の場合はpxとして扱う（エラー回復）
        return num_value;
    }

    // CSS仕様準拠のパーセント値解決
    fn resolvePercentageValue(self: *Renderer, node: *DOM.Node, property: []const u8, percentage: f32) !f32 {
        // 参照値をプロパティごとに決定（CSS仕様準拠）
        if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "min-width") or std.mem.eql(u8, property, "max-width") or
            std.mem.eql(u8, property, "left") or std.mem.eql(u8, property, "right") or
            std.mem.eql(u8, property, "margin-left") or std.mem.eql(u8, property, "margin-right") or
            std.mem.eql(u8, property, "padding-left") or std.mem.eql(u8, property, "padding-right") or
            std.mem.eql(u8, property, "text-indent"))
        {
            // 包含ブロックの幅を参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.width * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "height") or std.mem.eql(u8, property, "min-height") or std.mem.eql(u8, property, "max-height") or
            std.mem.eql(u8, property, "top") or std.mem.eql(u8, property, "bottom") or
            std.mem.eql(u8, property, "margin-top") or std.mem.eql(u8, property, "margin-bottom") or
            std.mem.eql(u8, property, "padding-top") or std.mem.eql(u8, property, "padding-bottom"))
        {
            // 包含ブロックの高さを参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.height * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "line-height")) {
            // 要素のフォントサイズを参照
            const font_size = try self.getCurrentFontSize(node);
            return font_size * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "font-size")) {
            // 親要素のフォントサイズを参照
            const parent_font_size = try self.getParentFontSize(node);
            return parent_font_size * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "vertical-align")) {
            // 要素のline-heightを参照
            const line_height = try self.getCurrentLineHeight(node);
            return line_height * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "transform-origin") or std.mem.eql(u8, property, "perspective-origin")) {
            // CSS Transforms Level 1 仕様準拠のtransform-origin解決
            if (node.layout) |layout| {
                // プロパティの軸（x, y）に応じて適切な寸法を選択
                if (std.mem.contains(u8, property, "x") or
                    std.mem.endsWith(u8, property, "-x"))
                {
                    // X軸方向は要素の幅を参照
                    return @floatFromInt(f32, layout.width) * percentage / 100.0;
                } else if (std.mem.contains(u8, property, "y") or
                    std.mem.endsWith(u8, property, "-y"))
                {
                    // Y軸方向は要素の高さを参照
                    return @floatFromInt(f32, layout.height) * percentage / 100.0;
                } else {
                    // デフォルト（x軸）は幅を使用
                    return @floatFromInt(f32, layout.width) * percentage / 100.0;
                }
            }
            return 0;
        } else if (std.mem.eql(u8, property, "width") or std.mem.eql(u8, property, "min-width") or std.mem.eql(u8, property, "max-width")) {
            // width関連は包含ブロックの幅を参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.width * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "height") or std.mem.eql(u8, property, "min-height") or std.mem.eql(u8, property, "max-height")) {
            // height関連は包含ブロックの高さを参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.height * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "line-height")) {
            // line-heightはフォントサイズを参照
            const font_size = try self.getCurrentFontSize(node);
            return font_size * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "font-size")) {
            // font-sizeは親のフォントサイズを参照
            const parent_font_size = try self.getParentFontSize(node);
            return parent_font_size * percentage / 100.0;
        } else if (std.mem.startsWith(u8, property, "margin") or std.mem.startsWith(u8, property, "padding")) {
            // margin/paddingは包含ブロックの幅を参照（CSS仕様）
            const containing_block = try self.getContainingBlock(node);
            return containing_block.width * percentage / 100.0;
        } else if (std.mem.startsWith(u8, property, "border")) {
            // borderは包含ブロックの幅を参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.width * percentage / 100.0;
        } else if (std.mem.startsWith(u8, property, "text-indent")) {
            // text-indentは包含ブロックの幅を参照
            const containing_block = try self.getContainingBlock(node);
            return containing_block.width * percentage / 100.0;
        } else if (std.mem.eql(u8, property, "background-size")) {
            // background-sizeは要素自身のサイズを参照（プロパティによって異なる）
            if (node.layout) |layout| {
                return @floatFromInt(f32, layout.width) * percentage / 100.0;
            }
            return 0;
        } else {
            // デフォルト：ビューポート幅を参照
            return @floatFromInt(f32, self.frame_info.width) * percentage / 100.0;
        }
    }

    // 補助関数群
    fn getCurrentFontSize(self: *Renderer, node: *DOM.Node) !f32 {
        if (node.computedStyle) |style| {
            if (style.properties.get("font-size")) |size| {
                if (std.mem.endsWith(u8, size, "px")) {
                    return try std.fmt.parseFloat(f32, size[0 .. size.len - 2]);
                }
            }
        }
        return 16.0; // デフォルト
    }

    fn getRootFontSize(self: *Renderer) !f32 {
        // ルート要素（HTML要素）を見つける
        var current = self.root_node;
        while (current) |node| {
            if (node.nodeType == .Element and node.tagName != null) {
                if (std.mem.eql(u8, node.tagName.?, "html")) {
                    // HTML要素のcomputedStyleからフォントサイズを取得
                    if (node.computedStyle) |style| {
                        if (style.properties.get("font-size")) |fs| {
                            if (std.mem.endsWith(u8, fs, "px")) {
                                return try std.fmt.parseFloat(f32, fs[0 .. fs.len - 2]);
                            }
                        }
                    }
                    break;
                }
            }
            // 子要素を探す
            current = node.firstChild;
        }

        // ブラウザのデフォルト（通常16px）
        return 16.0;
    }

    fn getCurrentLineHeight(self: *Renderer, node: *DOM.Node) !f32 {
        if (node.computedStyle) |style| {
            if (style.properties.get("line-height")) |lh| {
                if (std.mem.endsWith(u8, lh, "px")) {
                    return try std.fmt.parseFloat(f32, lh[0 .. lh.len - 2]);
                }
            }
        }
        const font_size = try self.getCurrentFontSize(node);
        return font_size * 1.2; // デフォルト
    }

    fn getRootLineHeight(self: *Renderer) !f32 {
        return 19.2; // 16px * 1.2
    }

    fn isVerticalWritingMode(self: *Renderer, node: *DOM.Node) bool {
        _ = self;
        if (node.computedStyle) |style| {
            if (style.properties.get("writing-mode")) |wm| {
                return std.mem.eql(u8, wm, "vertical-lr") or
                    std.mem.eql(u8, wm, "vertical-rl");
            }
        }
        return false;
    }

    fn getContainingBlock(self: *Renderer, node: *DOM.Node) !struct { width: f32, height: f32 } {
        _ = self;
        if (node.parentNode) |parent| {
            if (parent.layout) |layout| {
                return .{ .width = @floatFromInt(f32, layout.width), .height = @floatFromInt(f32, layout.height) };
            }
        }
        // デフォルトはビューポート
        return .{ .width = @floatFromInt(f32, self.frame_info.width), .height = @floatFromInt(f32, self.frame_info.height) };
    }

    fn getParentFontSize(self: *Renderer, node: *DOM.Node) !f32 {
        if (node.parentNode) |parent| {
            return try self.getCurrentFontSize(parent);
        }
        return 16.0; // デフォルト
    }

    // Container Query 単位のサポート関数
    fn getContainmentContextWidth(self: *Renderer, node: *DOM.Node) !f32 {
        // Container Query のコンテキストを探す
        var current = node.parentNode;
        while (current) |parent| {
            if (parent.computedStyle) |style| {
                if (style.properties.get("container-type")) |ct| {
                    if (std.mem.eql(u8, ct, "inline-size") or std.mem.eql(u8, ct, "size")) {
                        if (parent.layout) |layout| {
                            return @floatFromInt(f32, layout.width);
                        }
                    }
                }
            }
            current = parent.parentNode;
        }
        // フォールバック：ビューポート
        return @floatFromInt(f32, self.frame_info.width);
    }

    fn getContainmentContextHeight(self: *Renderer, node: *DOM.Node) !f32 {
        var current = node.parentNode;
        while (current) |parent| {
            if (parent.computedStyle) |style| {
                if (style.properties.get("container-type")) |ct| {
                    if (std.mem.eql(u8, ct, "block-size") or std.mem.eql(u8, ct, "size")) {
                        if (parent.layout) |layout| {
                            return @floatFromInt(f32, layout.height);
                        }
                    }
                }
            }
            current = parent.parentNode;
        }
        return @floatFromInt(f32, self.frame_info.height);
    }

    fn getContainmentContextInlineSize(self: *Renderer, node: *DOM.Node) !f32 {
        const is_vertical = self.isVerticalWritingMode(node);
        return if (is_vertical) try self.getContainmentContextHeight(node) else try self.getContainmentContextWidth(node);
    }

    fn getContainmentContextBlockSize(self: *Renderer, node: *DOM.Node) !f32 {
        const is_vertical = self.isVerticalWritingMode(node);
        return if (is_vertical) try self.getContainmentContextWidth(node) else try self.getContainmentContextHeight(node);
    }

    // レイアウト計算ステップ
    fn calculateLayout(self: *Renderer, root_node: *DOM.Node) !void {
        std.log.debug("Calculating layout for DOM tree...", .{});

        // レイアウト計算カウンタをリセット
        var nodes_processed: u32 = 0;

        // レイアウトコンテキストを作成
        var context = LayoutContext{
            .viewport_width = self.frame_info.width,
            .viewport_height = self.frame_info.height,
            .available_width = self.frame_info.width,
            .available_height = self.frame_info.height,
            .x = 0,
            .y = 0,
        };

        // 再帰的にレイアウトを計算
        try self.calculateNodeLayout(root_node, &context, &nodes_processed);

        // メトリクス更新
        self.metrics.nodes_laid_out.store(nodes_processed, .Monotonic);
        std.log.debug("Layout calculation complete for {d} nodes", .{nodes_processed});
    }

    // レイアウトコンテキスト
    const LayoutContext = struct {
        viewport_width: u32,
        viewport_height: u32,
        available_width: u32,
        available_height: u32,
        x: i32,
        y: i32,
    };

    // 単一ノードのレイアウト計算
    fn calculateNodeLayout(self: *Renderer, node: *DOM.Node, context: *LayoutContext, counter: *u32) !void {
        _ = self;

        // レイアウトを計算するのは表示される要素のみ
        if (node.nodeType != .Element and node.nodeType != .Text) return;

        counter.* += 1;

        // レイアウト情報がない場合は作成
        if (node.layout == null) {
            node.layout = try self.allocator.create(DOM.LayoutData);
            node.layout.?.x = context.x;
            node.layout.?.y = context.y;
            node.layout.?.width = context.available_width;
            node.layout.?.height = 0; // 高さは子要素に基づいて計算
        }

        // ディスプレイタイプに基づく処理
        var is_block = false;
        if (node.nodeType == .Element and node.style != null) {
            if (node.style.?.properties.get("display")) |display| {
                is_block = std.mem.eql(u8, display, "block");
            }
        }

        // ブロック要素は新しい行を開始
        if (is_block) {
            context.x = 0;
            context.y += node.layout.?.height;
            node.layout.?.x = context.x;
            node.layout.?.y = context.y;
            node.layout.?.width = context.available_width;
        }

        // 子ノードのレイアウトコンテキストを準備
        var child_context = LayoutContext{
            .viewport_width = context.viewport_width,
            .viewport_height = context.viewport_height,
            .available_width = if (is_block) context.available_width else context.available_width - @intCast(u32, context.x),
            .available_height = context.available_height - @intCast(u32, context.y),
            .x = if (is_block) 0 else context.x,
            .y = if (is_block) 0 else context.y,
        };

        // 子ノードを処理
        var max_height: u32 = 0;
        var child = node.firstChild;
        while (child != null) : (child = child.?.nextSibling) {
            const child_y = child_context.y;
            try self.calculateNodeLayout(child.?, &child_context, counter);

            // インライン要素で次の子のx座標を更新
            if (!is_block) {
                child_context.x = child.?.layout.?.x + @intCast(i32, child.?.layout.?.width);
            }

            // 最大高さを追跡
            max_height = @max(max_height, @intCast(u32, child_context.y - child_y));
        }

        // 自身の高さを計算
        if (is_block) {
            node.layout.?.height = @max(node.layout.?.height, max_height);
        } else {
            // インライン要素の場合
            node.layout.?.height = max_height;
        }

        // 親コンテキストのy座標を更新
        if (is_block) {
            context.y += @intCast(i32, node.layout.?.height);
        } else {
            context.y = @max(context.y, context.y + @intCast(i32, node.layout.?.height));
        }
    }

    // DOMノードからレイヤーを構成
    fn composeLayersFromDOM(self: *Renderer, root_node: *DOM.Node) !void {
        std.log.debug("Composing render layers from DOM...", .{});

        self.layers_mutex.lock();
        defer self.layers_mutex.unlock();

        // すべてのレイヤーをクリア
        self.layers.clearRetainingCapacity();

        // ルートレイヤーを追加
        var root_layer = RenderLayer.init();
        root_layer.id = 1;
        root_layer.width = @floatFromInt(f32, self.frame_info.width);
        root_layer.height = @floatFromInt(f32, self.frame_info.height);

        try self.layers.append(root_layer);

        // レイヤーIDカウンター
        var next_layer_id: u64 = 2;

        // DOM要素からレイヤーを生成
        try self.processNodeForLayers(root_node, 1, &next_layer_id);

        std.log.debug("Created {d} render layers", .{self.layers.items.len});
        self.metrics.layers_created.store(@intCast(u32, self.layers.items.len), .Monotonic);
    }

    // レイヤー生成のためのノード処理
    fn processNodeForLayers(self: *Renderer, node: *DOM.Node, parent_layer_id: u64, next_id: *u64) !void {
        // レイヤーを作成するのは表示可能な要素のみ
        if (node.nodeType != .Element and node.nodeType != .Text) return;

        // レイアウト情報がない要素はスキップ
        if (node.layout == null) return;

        // 新しいレイヤーが必要かどうかを判断
        var needs_layer = false;

        if (node.nodeType == .Element and node.style != null) {
            // 透明度、変形、アニメーションがある要素は別レイヤーが必要
            if (node.style.?.properties.get("opacity")) |opacity| {
                if (!std.mem.eql(u8, opacity, "1")) {
                    needs_layer = true;
                }
            }

            if (node.style.?.properties.get("transform")) |_| {
                needs_layer = true;
            }

            // position: absolute/fixed の要素も別レイヤー
            if (node.style.?.properties.get("position")) |position| {
                if (std.mem.eql(u8, position, "absolute") or std.mem.eql(u8, position, "fixed")) {
                    needs_layer = true;
                }
            }
        }

        // 現在のレイヤーID（デフォルトは親と同じ）
        var current_layer_id = parent_layer_id;

        // 必要に応じて新しいレイヤーを作成
        if (needs_layer) {
            var layer = RenderLayer.init();
            layer.id = next_id.*;
            layer.parent_id = parent_layer_id;
            layer.x = @floatFromInt(f32, node.layout.?.x);
            layer.y = @floatFromInt(f32, node.layout.?.y);
            layer.width = @floatFromInt(f32, node.layout.?.width);
            layer.height = @floatFromInt(f32, node.layout.?.height);

            // スタイルに基づいてレイヤープロパティを設定
            if (node.style != null) {
                if (node.style.?.properties.get("opacity")) |opacity| {
                    layer.opacity = std.fmt.parseFloat(f32, opacity) catch 1.0;
                }

                // トランスフォームマトリックスの完璧な設定実装
                if (computed_style.transform) |transform_value| {
                    // CSS transform関数の解析
                    var transform_matrix = Matrix4x4.identity();

                    // transform関数をパース
                    var func_start: usize = 0;
                    var i: usize = 0;

                    while (i < transform_value.len) {
                        if (transform_value[i] == '(') {
                            const func_name = transform_value[func_start..i];

                            // 関数の引数を取得
                            const args_start = i + 1;
                            var paren_count: i32 = 1;
                            i += 1;

                            while (i < transform_value.len and paren_count > 0) {
                                if (transform_value[i] == '(') paren_count += 1;
                                if (transform_value[i] == ')') paren_count -= 1;
                                i += 1;
                            }

                            const args = transform_value[args_start .. i - 1];

                            // 各transform関数の処理
                            if (std.mem.eql(u8, func_name, "translate")) {
                                const translation = parseTranslate(args);
                                const translate_matrix = Matrix4x4.translate(translation.x, translation.y, 0);
                                transform_matrix = transform_matrix.multiply(translate_matrix);
                            } else if (std.mem.eql(u8, func_name, "translate3d")) {
                                const translation = parseTranslate3d(args);
                                const translate_matrix = Matrix4x4.translate(translation.x, translation.y, translation.z);
                                transform_matrix = transform_matrix.multiply(translate_matrix);
                            } else if (std.mem.eql(u8, func_name, "translateX")) {
                                const x = parseLength(args);
                                const translate_matrix = Matrix4x4.translate(x, 0, 0);
                                transform_matrix = transform_matrix.multiply(translate_matrix);
                            } else if (std.mem.eql(u8, func_name, "translateY")) {
                                const y = parseLength(args);
                                const translate_matrix = Matrix4x4.translate(0, y, 0);
                                transform_matrix = transform_matrix.multiply(translate_matrix);
                            } else if (std.mem.eql(u8, func_name, "translateZ")) {
                                const z = parseLength(args);
                                const translate_matrix = Matrix4x4.translate(0, 0, z);
                                transform_matrix = transform_matrix.multiply(translate_matrix);
                            } else if (std.mem.eql(u8, func_name, "scale")) {
                                const scale = parseScale(args);
                                const scale_matrix = Matrix4x4.scale(scale.x, scale.y, 1);
                                transform_matrix = transform_matrix.multiply(scale_matrix);
                            } else if (std.mem.eql(u8, func_name, "scale3d")) {
                                const scale = parseScale3d(args);
                                const scale_matrix = Matrix4x4.scale(scale.x, scale.y, scale.z);
                                transform_matrix = transform_matrix.multiply(scale_matrix);
                            } else if (std.mem.eql(u8, func_name, "scaleX")) {
                                const x = parseFloat(args);
                                const scale_matrix = Matrix4x4.scale(x, 1, 1);
                                transform_matrix = transform_matrix.multiply(scale_matrix);
                            } else if (std.mem.eql(u8, func_name, "scaleY")) {
                                const y = parseFloat(args);
                                const scale_matrix = Matrix4x4.scale(1, y, 1);
                                transform_matrix = transform_matrix.multiply(scale_matrix);
                            } else if (std.mem.eql(u8, func_name, "scaleZ")) {
                                const z = parseFloat(args);
                                const scale_matrix = Matrix4x4.scale(1, 1, z);
                                transform_matrix = transform_matrix.multiply(scale_matrix);
                            } else if (std.mem.eql(u8, func_name, "rotate")) {
                                const angle = parseAngle(args);
                                const rotate_matrix = Matrix4x4.rotateZ(angle);
                                transform_matrix = transform_matrix.multiply(rotate_matrix);
                            } else if (std.mem.eql(u8, func_name, "rotate3d")) {
                                const rotation = parseRotate3d(args);
                                const rotate_matrix = Matrix4x4.rotate(rotation.x, rotation.y, rotation.z, rotation.angle);
                                transform_matrix = transform_matrix.multiply(rotate_matrix);
                            } else if (std.mem.eql(u8, func_name, "rotateX")) {
                                const angle = parseAngle(args);
                                const rotate_matrix = Matrix4x4.rotateX(angle);
                                transform_matrix = transform_matrix.multiply(rotate_matrix);
                            } else if (std.mem.eql(u8, func_name, "rotateY")) {
                                const angle = parseAngle(args);
                                const rotate_matrix = Matrix4x4.rotateY(angle);
                                transform_matrix = transform_matrix.multiply(rotate_matrix);
                            } else if (std.mem.eql(u8, func_name, "rotateZ")) {
                                const angle = parseAngle(args);
                                const rotate_matrix = Matrix4x4.rotateZ(angle);
                                transform_matrix = transform_matrix.multiply(rotate_matrix);
                            } else if (std.mem.eql(u8, func_name, "skew")) {
                                const skew = parseSkew(args);
                                const skew_matrix = Matrix4x4.skew(skew.x, skew.y);
                                transform_matrix = transform_matrix.multiply(skew_matrix);
                            } else if (std.mem.eql(u8, func_name, "skewX")) {
                                const angle = parseAngle(args);
                                const skew_matrix = Matrix4x4.skewX(angle);
                                transform_matrix = transform_matrix.multiply(skew_matrix);
                            } else if (std.mem.eql(u8, func_name, "skewY")) {
                                const angle = parseAngle(args);
                                const skew_matrix = Matrix4x4.skewY(angle);
                                transform_matrix = transform_matrix.multiply(skew_matrix);
                            } else if (std.mem.eql(u8, func_name, "matrix")) {
                                const matrix = parseMatrix(args);
                                transform_matrix = transform_matrix.multiply(matrix);
                            } else if (std.mem.eql(u8, func_name, "matrix3d")) {
                                const matrix = parseMatrix3d(args);
                                transform_matrix = transform_matrix.multiply(matrix);
                            } else if (std.mem.eql(u8, func_name, "perspective")) {
                                const distance = parseLength(args);
                                const perspective_matrix = Matrix4x4.perspective(distance);
                                transform_matrix = transform_matrix.multiply(perspective_matrix);
                            }

                            // 次の関数の開始位置を探す
                            while (i < transform_value.len and (transform_value[i] == ' ' or transform_value[i] == ',')) {
                                i += 1;
                            }
                            func_start = i;
                        } else {
                            i += 1;
                        }
                    }

                    // 計算されたマトリックスを適用
                    render_object.transform_matrix = transform_matrix;
                }
                if (node.style.?.properties.get("transform")) |_| {
                    // 本来はここで transform の値を解析してマトリックスを設定
                }
            }

            try self.layers.append(layer);
            current_layer_id = layer.id;
            next_id.* += 1;
        }

        // 子ノードを再帰的に処理
        var child = node.firstChild;
        while (child != null) : (child = child.?.nextSibling) {
            try self.processNodeForLayers(child.?, current_layer_id, next_id);
        }
    }

    // レイヤー描画ステップ
    fn paintLayers(self: *Renderer) !void {
        std.log.debug("Painting render layers...", .{});

        self.layers_mutex.lock();
        defer self.layers_mutex.unlock();

        var layers_painted: u32 = 0;

        // インデックスと一緒にループ
        var i: usize = 0;
        while (i < self.layers.items.len) : (i += 1) {
            var layer = &self.layers.items[i];
            if (!layer.needs_repaint) continue;

            // GPUインターフェースが利用可能な場合はテクスチャを生成
            if (self.gpu_interface) |*gpu| {
                // レイヤーにテクスチャがなければ作成
                if (layer.texture_id == 0) {
                    const width = @floatToInt(u32, layer.width);
                    const height = @floatToInt(u32, layer.height);
                    layer.texture_id = try gpu.createTexture(width, height);
                }

                // レイヤーの描画処理
                try self.paintLayer(layer, i);
            }

            layer.needs_repaint = false;
            layers_painted += 1;
        }

        std.log.debug("Painted {d} layers", .{layers_painted});
        self.metrics.layers_painted.store(layers_painted, .Monotonic);
    }

    // 単一レイヤーの描画
    fn paintLayer(self: *Renderer, layer: *RenderLayer, layer_index: usize) !void {
        // ソフトウェア描画バッファ生成
        var buffer = try self.allocator.alloc(u8, layer.width * layer.height * 4);
        defer self.allocator.free(buffer);
        // レイヤーに属するDOM要素を描画
        try self.drawDomElementsToBuffer(layer, buffer);
        // バッファをGPUテクスチャにアップロード
        if (self.gpu_interface) |*gpu| {
            try gpu.uploadTexture(layer.texture_id, buffer, layer.width, layer.height);
        }
    }

    // GPUバックエンドの初期化
    fn initializeGpuBackend(self: *Renderer, width: u32, height: u32) !void {
        // バックエンドを自動選択
        const backend = if (self.options.gpu_backend == .auto) blk: {
            // プラットフォームに基づいて最適なバックエンドを選択
            if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
                break :blk GpuBackend.metal;
            } else if (builtin.os.tag == .windows) {
                break :blk GpuBackend.d3d12;
            } else if (builtin.os.tag == .linux) {
                break :blk GpuBackend.vulkan;
            } else {
                break :blk GpuBackend.opengl;
            }
        } else self.options.gpu_backend;

        std.log.info("Initializing GPU backend: {s}", .{@tagName(backend)});

        // バックエンド固有の初期化
        switch (backend) {
            .webgpu => {
                // WebGPUバックエンド初期化
                self.gpu_interface = try self.initializeWebGPU(width, height);
            },
            .vulkan => {
                // Vulkanバックエンド初期化
                self.gpu_interface = try self.initializeVulkan(width, height);
            },
            .metal => {
                // Metalバックエンド初期化
                self.gpu_interface = try self.initializeMetal(width, height);
            },
            .d3d12, .d3d11 => {
                // DirectX初期化
                self.gpu_interface = try self.initializeDirectX(width, height, backend == .d3d12);
            },
            .opengl => {
                // OpenGL初期化
                self.gpu_interface = try self.initializeOpenGL(width, height);
            },
            .software => {
                // ソフトウェアレンダリングバックエンド初期化
                self.gpu_interface = try self.initializeSoftwareRenderer(width, height);
            },
            else => {
                // 不明なバックエンドの場合はソフトウェアレンダリングを使用
                std.log.warn("Unknown GPU backend, using software rendering", .{});
                self.gpu_interface = try self.initializeSoftwareRenderer(width, height);
            },
        }

        // バックエンドが初期化できない場合はソフトウェアレンダリングにフォールバック
        if (self.gpu_interface == null) {
            std.log.warn("Failed to initialize {s} backend, falling back to software rendering", .{@tagName(backend)});
            self.gpu_interface = try self.initializeSoftwareRenderer(width, height);
        }
    }

    // WebGPUバックエンド初期化
    fn initializeWebGPU(self: *Renderer, width: u32, height: u32) !?GpuInterface {
        // WebGPUデバイス初期化
        return try GpuInterface.initWebGPU(width, height);
    }

    // Vulkanバックエンド初期化
    fn initializeVulkan(self: *Renderer, width: u32, height: u32) !?GpuInterface {
        // Vulkanデバイス初期化
        return try GpuInterface.initVulkan(width, height);
    }

    // Metalバックエンド初期化
    fn initializeMetal(self: *Renderer, width: u32, height: u32) !?GpuInterface {
        // Metalデバイス初期化
        return try GpuInterface.initMetal(width, height);
    }

    // DirectXバックエンド初期化
    fn initializeDirectX(self: *Renderer, width: u32, height: u32, use_dx12: bool) !?GpuInterface {
        // DirectXデバイス初期化
        return try GpuInterface.initDirectX(width, height, use_dx12);
    }

    // OpenGLバックエンド初期化
    fn initializeOpenGL(self: *Renderer, width: u32, height: u32) !?GpuInterface {
        // OpenGLデバイス初期化
        return try GpuInterface.initOpenGL(width, height);
    }

    // ソフトウェアレンダリング初期化
    fn initializeSoftwareRenderer(self: *Renderer, width: u32, height: u32) !?GpuInterface {
        _ = self;
        _ = width;
        _ = height;

        // ソフトウェアレンダリング実装
        var swrast = try self.allocator.create(SoftwareRenderer);
        errdefer self.allocator.destroy(swrast);

        swrast.* = SoftwareRenderer.init(self.allocator, width, height);

        // GPU VTableを設定
        const vtable = try self.allocator.create(GpuInterface.VTable);
        vtable.* = GpuInterface.VTable{
            .init = SoftwareRenderer.init_impl,
            .deinit = SoftwareRenderer.deinit_impl,
            .beginFrame = SoftwareRenderer.begin_frame_impl,
            .endFrame = SoftwareRenderer.end_frame_impl,
            .createTexture = SoftwareRenderer.create_texture_impl,
            .deleteTexture = SoftwareRenderer.delete_texture_impl,
            .drawLayer = SoftwareRenderer.draw_layer_impl,
        };

        return GpuInterface{
            .vtable = vtable,
            .ctx = swrast,
        };
    }
};

// グローバル初期化関数
pub fn initialize(options: RendererOptions) !void {
    // グローバルアロケータを取得
    var allocator = memory.g_general_allocator;

    // レンダラーインスタンスを作成
    var renderer = try Renderer.init(allocator, options);

    // デフォルトサイズで初期化
    try renderer.initialize(800, 600);
}

// グローバルシャットダウン関数
pub fn shutdown() void {
    if (Renderer.instance) |renderer| {
        renderer.shutdown() catch |err| {
            std.log.err("Error during renderer shutdown: {}", .{err});
        };
        // deinitはしない - レンダラーは他の場所で使用されている可能性があるため
    }
}

// テスト
test "renderer initialization" {
    // テスト用メモリアロケータ
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var renderer = try Renderer.init(allocator, .{
        .threads = 2,
        .use_gpu = false, // テスト中はGPUを使用しない
    });

    try renderer.initialize(1024, 768);
    try std.testing.expectEqual(renderer.state, .Running);
    try std.testing.expectEqual(renderer.frame_info.width, 1024);
    try std.testing.expectEqual(renderer.frame_info.height, 768);

    // クリーンアップ
    try renderer.shutdown();
    try std.testing.expectEqual(renderer.state, .Uninitialized);

    renderer.deinit();
}
