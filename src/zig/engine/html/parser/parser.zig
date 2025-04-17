const std = @import("std");
const Dom = @import("../dom/dom.zig");
const Tokenizer = @import("../tokenizer/tokenizer.zig");
const Logger = @import("../../../core/logger.zig");

pub const ParserError = error{
    InvalidToken,
    StackOverflow,
    UnexpectedEOF,
    MalformedInput,
    InvalidNesting,
    UnsupportedFeature,
    OutOfMemory,
    InternalError,
};

pub const ParserOptions = struct {
    // メモリ使用量の制限（バイト単位）
    memory_limit: usize = 64 * 1024 * 1024, // デフォルト64MB
    // 最大ネスト深度
    max_nesting_depth: usize = 512,
    // 並列解析を有効にする
    enable_parallel_parsing: bool = true,
    // スクリプト評価を有効にする
    evaluate_scripts: bool = true,
    // エラー時に復旧を試みる
    recovery_mode: bool = true,
    // 特殊コメントの処理を有効にする
    process_conditional_comments: bool = true,
    // パース中にDOMをインクリメンタルに構築する
    incremental_dom_building: bool = true,
    // カスタムアロケータ、nullの場合はデフォルトを使用
    allocator: ?std.mem.Allocator = null,
};

pub const ParserMetrics = struct {
    elapsed_time_ns: u64 = 0,
    bytes_processed: usize = 0,
    token_count: usize = 0,
    element_count: usize = 0,
    text_node_count: usize = 0,
    comment_count: usize = 0,
    error_count: usize = 0,
    warning_count: usize = 0,
    max_memory_used: usize = 0,
    parsing_speed_mbps: f64 = 0.0,
};

pub const ParserMode = enum {
    Standard, // 標準HTML解析
    Fragment, // HTMLフラグメント解析
    Streaming, // ストリーミング解析
    Tolerant,  // エラー許容モード
    Strict,    // 厳格モード
};

pub const HtmlParser = struct {
    allocator: std.mem.Allocator,
    document: *Dom.Document,
    tokenizer: Tokenizer.HtmlTokenizer,
    options: ParserOptions,
    metrics: ParserMetrics,
    mode: ParserMode,
    stack: std.ArrayList(*Dom.Element),
    current_node: *Dom.Node,
    errors: std.ArrayList([]const u8),
    logger: Logger.Logger,
    
    // スレッド並列化のためのワーカープール
    worker_pool: ?*WorkerPool = null,
    
    // キャッシュ・最適化のためのデータ構造
    tag_name_cache: std.StringHashMap(void),
    attr_name_cache: std.StringHashMap(void),
    
    pub fn init(allocator: std.mem.Allocator, options: ParserOptions) !*HtmlParser {
        var parser = try allocator.create(HtmlParser);
        errdefer allocator.destroy(parser);
        
        const effective_allocator = options.allocator orelse allocator;
        
        parser.* = HtmlParser{
            .allocator = effective_allocator,
            .document = try Dom.Document.create(effective_allocator),
            .tokenizer = try Tokenizer.HtmlTokenizer.init(effective_allocator),
            .options = options,
            .metrics = ParserMetrics{},
            .mode = ParserMode.Standard,
            .stack = std.ArrayList(*Dom.Element).init(effective_allocator),
            .current_node = @ptrCast(parser.document),
            .errors = std.ArrayList([]const u8).init(effective_allocator),
            .logger = Logger.Logger.init(effective_allocator, .Debug),
            .tag_name_cache = std.StringHashMap(void).init(effective_allocator),
            .attr_name_cache = std.StringHashMap(void).init(effective_allocator),
        };
        
        // ワーカープールの初期化（並列解析が有効な場合）
        if (options.enable_parallel_parsing) {
            parser.worker_pool = try WorkerPool.init(effective_allocator, 
                std.math.min(8, try std.Thread.getCpuCount()));
        }
        
        return parser;
    }
    
    pub fn deinit(self: *HtmlParser) void {
        self.stack.deinit();
        self.errors.deinit();
        self.tag_name_cache.deinit();
        self.attr_name_cache.deinit();
        
        if (self.worker_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        
        self.tokenizer.deinit();
        self.document.deinit();
        self.logger.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn setMode(self: *HtmlParser, mode: ParserMode) void {
        self.mode = mode;
    }
    
    pub fn parseHtml(self: *HtmlParser, input: []const u8) !*Dom.Document {
        const start_time = std.time.nanoTimestamp();
        
        try self.tokenizer.setInput(input);
        try self.setupDocument();
        
        // メインの解析ループ
        try self.parseLoop();
        
        // メトリクスの更新
        self.metrics.elapsed_time_ns = @intCast(std.time.nanoTimestamp() - start_time);
        self.metrics.bytes_processed = input.len;
        if (self.metrics.elapsed_time_ns > 0) {
            const secs = @as(f64, @floatFromInt(self.metrics.elapsed_time_ns)) / 1_000_000_000.0;
            self.metrics.parsing_speed_mbps = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0) / secs;
        }
        
        return self.document;
    }
    
    pub fn parseFragment(self: *HtmlParser, input: []const u8, context_element: ?*Dom.Element) !*Dom.DocumentFragment {
        self.setMode(ParserMode.Fragment);
        
        const fragment = try Dom.DocumentFragment.create(self.allocator, self.document);
        self.current_node = @ptrCast(fragment);
        
        // コンテキスト要素が提供されている場合、その要素のコンテキストで解析
        if (context_element) |element| {
            // context要素の名前空間とタグ名に基づいて解析コンテキストを調整
            _ = element; // TODO: 適切なフォーム要素のコンテキスト処理
        }
        
        try self.tokenizer.setInput(input);
        try self.parseLoop();
        
        return fragment;
    }
    
    fn setupDocument(self: *HtmlParser) !void {
        // DOMドキュメントの初期化
        self.document.reset();
        
        // パーサースタックのクリア
        self.stack.clearRetainingCapacity();
        
        // 現在のノードをドキュメントに設定
        self.current_node = @ptrCast(self.document);
        
        // エラーリストのクリア
        self.errors.clearRetainingCapacity();
        
        // メトリクスのリセット
        self.metrics = ParserMetrics{};
    }
    
    fn parseLoop(self: *HtmlParser) !void {
        var token_count: usize = 0;
        var stack_depth: usize = 0;
        
        while (try self.tokenizer.nextToken()) |token| {
            token_count += 1;
            self.metrics.token_count += 1;
            
            try self.processToken(token);
            
            // スタック深度チェック
            stack_depth = self.stack.items.len;
            if (stack_depth > self.options.max_nesting_depth) {
                try self.reportError("Maximum nesting depth exceeded");
                return ParserError.StackOverflow;
            }
            
            // メモリ使用量チェック
            if (self.allocator.total_size > self.options.memory_limit) {
                try self.reportError("Memory limit exceeded");
                return ParserError.OutOfMemory;
            }
            
            // ストリーミングモードの場合、一定間隔でDOMを構築
            if (self.mode == ParserMode.Streaming and 
                self.options.incremental_dom_building and 
                token_count % 1000 == 0) {
                // インクリメンタルDOMビルドコールバックをここで呼び出す
            }
        }
        
        // 残りのオープン要素を処理
        try self.processRemainingOpenElements();
    }
    
    fn processToken(self: *HtmlParser, token: Tokenizer.Token) !void {
        switch (token.type) {
            .DocType => try self.processDocType(token),
            .StartTag => try self.processStartTag(token),
            .EndTag => try self.processEndTag(token),
            .Comment => try self.processComment(token),
            .Text => try self.processText(token),
            .CDATA => try self.processCDATA(token),
            .EOF => {}, // EOF処理は解析ループで処理
            .Error => {
                const err_msg = try std.fmt.allocPrint(self.allocator, 
                    "Tokenizer error: {s}", .{token.error_msg});
                try self.reportError(err_msg);
                self.allocator.free(err_msg);
            },
        }
    }
    
    fn processDocType(self: *HtmlParser, token: Tokenizer.Token) !void {
        // DOCTYPE処理
        _ = try self.document.createDocumentType(
            token.doctype.name, 
            token.doctype.public_id, 
            token.doctype.system_id
        );
        
        // HTML文書型定義を設定
        self.document.setContentType("text/html");
    }
    
    fn processStartTag(self: *HtmlParser, token: Tokenizer.Token) !void {
        // 最適化: 共通タグ名の文字列プールを使用
        var tag_name = token.start_tag.name;
        if (!self.tag_name_cache.contains(tag_name)) {
            try self.tag_name_cache.put(tag_name, {});
        }
        
        // 新しい要素の作成
        var element = try self.document.createElement(tag_name);
        
        // 属性の追加
        for (token.start_tag.attributes) |attr| {
            // 属性名のキャッシュ
            var attr_name = attr.name;
            if (!self.attr_name_cache.contains(attr_name)) {
                try self.attr_name_cache.put(attr_name, {});
            }
            
            try element.setAttribute(attr_name, attr.value);
        }
        
        // 現在のノードに要素を追加
        try self.current_node.appendChild(@ptrCast(element));
        
        // 自己終了タグでない場合、スタックに追加して現在のノードに設定
        if (!token.start_tag.self_closing) {
            try self.stack.append(element);
            self.current_node = @ptrCast(element);
        }
        
        self.metrics.element_count += 1;
    }
    
    fn processEndTag(self: *HtmlParser, token: Tokenizer.Token) !void {
        const tag_name = token.end_tag.name;
        
        // スタックが空の場合は無視
        if (self.stack.items.len == 0) {
            const err_msg = try std.fmt.allocPrint(self.allocator, 
                "End tag </{s}> with no matching start tag", .{tag_name});
            try self.reportError(err_msg);
            self.allocator.free(err_msg);
            return;
        }
        
        // スタックの先頭から一致する要素を検索
        var found = false;
        var i: usize = self.stack.items.len;
        
        while (i > 0) {
            i -= 1;
            const element = self.stack.items[i];
            
            if (std.mem.eql(u8, element.tagName(), tag_name)) {
                found = true;
                
                // スタックから要素を削除
                while (self.stack.items.len > i) {
                    _ = self.stack.pop();
                }
                
                // 新しい現在のノードを設定
                if (self.stack.items.len > 0) {
                    self.current_node = @ptrCast(self.stack.items[self.stack.items.len - 1]);
                } else {
                    self.current_node = @ptrCast(self.document);
                }
                
                break;
            }
        }
        
        if (!found) {
            const err_msg = try std.fmt.allocPrint(self.allocator, 
                "End tag </{s}> with no matching start tag", .{tag_name});
            try self.reportError(err_msg);
            self.allocator.free(err_msg);
        }
    }
    
    fn processComment(self: *HtmlParser, token: Tokenizer.Token) !void {
        // 条件付きコメントの処理
        if (self.options.process_conditional_comments and 
            (std.mem.startsWith(u8, token.comment.data, "[if ") or 
             std.mem.startsWith(u8, token.comment.data, "![endif]"))) {
            try self.processConditionalComment(token.comment.data);
            return;
        }
        
        // 通常のコメントノードの作成
        _ = try self.document.createComment(token.comment.data);
        self.metrics.comment_count += 1;
    }
    
    fn processText(self: *HtmlParser, token: Tokenizer.Token) !void {
        _ = try self.document.createTextNode(token.text.data);
        self.metrics.text_node_count += 1;
    }
    
    fn processCDATA(self: *HtmlParser, token: Tokenizer.Token) !void {
        _ = try self.document.createCDATASection(token.cdata.data);
    }
    
    fn processConditionalComment(self: *HtmlParser, data: []const u8) !void {
        // IE条件付きコメントの処理
        _ = data; // TODO: 条件付きコメントの完全な実装
    }
    
    fn processRemainingOpenElements(self: *HtmlParser) !void {
        // 閉じられていない要素をすべて閉じる
        while (self.stack.items.len > 0) {
            const element = self.stack.pop();
            const err_msg = try std.fmt.allocPrint(self.allocator, 
                "Unclosed element <{s}>", .{element.tagName()});
            try self.reportError(err_msg);
            self.allocator.free(err_msg);
        }
        
        self.current_node = @ptrCast(self.document);
    }
    
    fn reportError(self: *HtmlParser, message: []const u8) !void {
        const copied_message = try self.allocator.dupe(u8, message);
        try self.errors.append(copied_message);
        self.metrics.error_count += 1;
        
        self.logger.error("HTML Parser: {s}", .{message});
        
        // 厳格モードではエラーで即終了
        if (self.mode == ParserMode.Strict) {
            return ParserError.MalformedInput;
        }
    }
    
    pub fn getErrors(self: *const HtmlParser) []const []const u8 {
        return self.errors.items;
    }
    
    pub fn getMetrics(self: *const HtmlParser) ParserMetrics {
        return self.metrics;
    }
};

// 並列解析のためのワーカープール
const WorkerPool = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayList(std.Thread),
    task_queue: TaskQueue,
    running: std.atomic.Atomic(bool),
    
    const Task = struct {
        data: []const u8,
        callback: *const fn([]const u8, *Dom.Node) anyerror!void,
        context: *Dom.Node,
    };
    
    const TaskQueue = struct {
        mutex: std.Thread.Mutex,
        tasks: std.ArrayList(Task),
        condition: std.Thread.Condition,
        
        fn init(allocator: std.mem.Allocator) !TaskQueue {
            return TaskQueue{
                .mutex = std.Thread.Mutex{},
                .tasks = std.ArrayList(Task).init(allocator),
                .condition = std.Thread.Condition{},
            };
        }
        
        fn deinit(self: *TaskQueue) void {
            self.tasks.deinit();
        }
        
        fn push(self: *TaskQueue, task: Task) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            try self.tasks.append(task);
            self.condition.signal();
        }
        
        fn pop(self: *TaskQueue) ?Task {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            if (self.tasks.items.len == 0) {
                return null;
            }
            
            return self.tasks.orderedRemove(0);
        }
        
        fn waitForTask(self: *TaskQueue) ?Task {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            while (self.tasks.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
            
            if (self.tasks.items.len == 0) {
                return null;
            }
            
            return self.tasks.orderedRemove(0);
        }
    };
    
    fn init(allocator: std.mem.Allocator, thread_count: usize) !*WorkerPool {
        var pool = try allocator.create(WorkerPool);
        
        pool.* = WorkerPool{
            .allocator = allocator,
            .threads = std.ArrayList(std.Thread).init(allocator),
            .task_queue = try TaskQueue.init(allocator),
            .running = std.atomic.Atomic(bool).init(true),
        };
        
        // ワーカースレッドの作成
        try pool.threads.ensureTotalCapacity(thread_count);
        
        var i: usize = 0;
        while (i < thread_count) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerFunction, .{pool});
            try pool.threads.append(thread);
        }
        
        return pool;
    }
    
    fn deinit(self: *WorkerPool) void {
        // ワーカーを停止
        self.running.store(false, .SeqCst);
        
        // すべてのスレッドを起こしてシャットダウンさせる
        for (0..self.threads.items.len) |_| {
            self.task_queue.condition.signal();
        }
        
        // すべてのスレッドが終了するのを待つ
        for (self.threads.items) |thread| {
            thread.join();
        }
        
        self.threads.deinit();
        self.task_queue.deinit();
    }
    
    fn submitTask(self: *WorkerPool, data: []const u8, callback: *const fn([]const u8, *Dom.Node) anyerror!void, context: *Dom.Node) !void {
        const task = Task{
            .data = data,
            .callback = callback,
            .context = context,
        };
        
        try self.task_queue.push(task);
    }
    
    fn workerFunction(pool: *WorkerPool) !void {
        while (pool.running.load(.SeqCst)) {
            if (pool.task_queue.waitForTask()) |task| {
                // タスクの実行
                task.callback(task.data, task.context) catch |err| {
                    std.debug.print("Worker error: {any}\n", .{err});
                };
            }
        }
    }
}; 