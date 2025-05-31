const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;

/// 高性能アリーナアロケータ
/// メモリの断片化を最小限に抑え、割り当てと解放の効率を最大化
pub const QuantumArenaAllocator = struct {
    // 内部メモリプール
    arena: std.heap.ArenaAllocator,
    // 統計情報
    stats: Stats,
    // アロケーションストラテジー
    strategy: AllocationStrategy,

    pub const Stats = struct {
        total_allocated: usize = 0,
        total_freed: usize = 0,
        peak_memory: usize = 0,
        allocation_count: usize = 0,
    };

    pub const AllocationStrategy = enum {
        // 小さなオブジェクト向けに最適化
        SmallObjects,
        // 大きなオブジェクト向けに最適化
        LargeObjects,
        // バランス型（デフォルト）
        Balanced,
    };

    const BucketSize = 16 * 1024; // 16KB
    const LargeAllocationThreshold = 4 * 1024; // 4KB

    /// アリーナアロケータを初期化
    pub fn init(backing_allocator: mem.Allocator, strategy: AllocationStrategy) QuantumArenaAllocator {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .stats = .{},
            .strategy = strategy,
        };
    }

    /// リソースを解放
    pub fn deinit(self: *QuantumArenaAllocator) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// アロケータインターフェースを取得
    pub fn allocator(self: *QuantumArenaAllocator) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    /// メモリを割り当て
    fn alloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *QuantumArenaAllocator = @ptrCast(ctx);
        const alignment = @as(usize, 1) << @as(math.Log2Int(usize), @intCast(log2_ptr_align));

        // 最適化戦略に基づいたメモリ割り当て
        var result: ?[*]u8 = null;

        switch (self.strategy) {
            .SmallObjects => {
                // 小さなオブジェクト用の最適化
                // ページ境界をまたがないように調整
                const page_size = mem.page_size;
                if (len < page_size / 4) {
                    result = self.arena.allocator().rawAlloc(len, log2_ptr_align, ret_addr);
                } else {
                    // ページアラインメントで割り当て
                    const adjusted_align = math.max(alignment, page_size);
                    const log2_adjusted_align = math.log2(adjusted_align);
                    result = self.arena.allocator().rawAlloc(len, @intCast(log2_adjusted_align), ret_addr);
                }
            },
            .LargeObjects => {
                // 大きなオブジェクト用の最適化
                if (len >= LargeAllocationThreshold) {
                    // 大きなオブジェクトは直接バッキングアロケータから割り当て
                    const backing_allocator = self.arena.child_allocator;
                    result = backing_allocator.rawAlloc(len, log2_ptr_align, ret_addr);
                    if (result) |ptr| {
                        return ptr;
                    }
                }
                // フォールバック
                result = self.arena.allocator().rawAlloc(len, log2_ptr_align, ret_addr);
            },
            .Balanced => {
                // バランス型戦略 - 最も汎用的
                result = self.arena.allocator().rawAlloc(len, log2_ptr_align, ret_addr);
            },
        }

        // 統計を更新
        if (result != null) {
            self.stats.total_allocated += len;
            self.stats.allocation_count += 1;
            self.stats.peak_memory = math.max(self.stats.peak_memory, self.stats.total_allocated - self.stats.total_freed);
        }

        return result;
    }

    /// メモリのサイズを変更
    fn resize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *QuantumArenaAllocator = @ptrCast(ctx);

        // 統計を更新
        if (new_len > buf.len) {
            self.stats.total_allocated += (new_len - buf.len);
            self.stats.peak_memory = math.max(self.stats.peak_memory, self.stats.total_allocated - self.stats.total_freed);
        } else if (new_len < buf.len) {
            self.stats.total_freed += (buf.len - new_len);
        }

        // アリーナアロケータでのリサイズを試みる
        return self.arena.allocator().rawResize(buf, log2_buf_align, new_len, ret_addr);
    }

    /// メモリを解放
    fn free(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
        const self: *QuantumArenaAllocator = @ptrCast(ctx);

        // 統計を更新
        self.stats.total_freed += buf.len;

        // 大きなオブジェクトの場合は直接解放を試みる
        if (self.strategy == .LargeObjects and buf.len >= LargeAllocationThreshold) {
            // バッキングアロケータからの割り当てを試みる
            const backing_allocator = self.arena.child_allocator;

            // ここでは単純に無視 - アリーナアロケータは実際には個別に解放しない
            _ = backing_allocator;
            return;
        }

        // アリーナアロケータは個別解放をサポートしないため、何もしない
        _ = log2_buf_align;
        _ = ret_addr;
    }

    /// アリーナのすべてのメモリを解放するが、アリーナ自体は維持
    pub fn reset(self: *QuantumArenaAllocator) void {
        self.stats.total_freed = self.stats.total_allocated;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
    }

    /// 統計情報を取得
    pub fn getStats(self: *const QuantumArenaAllocator) Stats {
        return self.stats;
    }
};

// オブジェクトプール実装 - 固定サイズのオブジェクトを効率的に管理
pub const ObjectPool = struct {
    const Node = struct {
        next: ?*Node,
    };

    allocator: mem.Allocator,
    free_list: ?*Node,
    chunk_list: std.ArrayList(*anyopaque),
    object_size: usize,
    objects_per_chunk: usize,
    alignment: usize,

    pub fn init(allocator: mem.Allocator, comptime T: type, objects_per_chunk: usize) ObjectPool {
        const object_size = @max(@sizeOf(T), @sizeOf(Node));
        const alignment = @max(@alignOf(T), @alignOf(Node));

        return .{
            .allocator = allocator,
            .free_list = null,
            .chunk_list = std.ArrayList(*anyopaque).init(allocator),
            .object_size = object_size,
            .objects_per_chunk = objects_per_chunk,
            .alignment = alignment,
        };
    }

    pub fn deinit(self: *ObjectPool) void {
        for (self.chunk_list.items) |chunk| {
            self.allocator.free(@as([*]u8, @ptrCast(chunk))[0 .. self.object_size * self.objects_per_chunk]);
        }
        self.chunk_list.deinit();
        self.* = undefined;
    }

    pub fn create(self: *ObjectPool) !*anyopaque {
        // フリーリストからオブジェクトを再利用
        if (self.free_list) |node| {
            self.free_list = node.next;
            @memset(@as([*]u8, @ptrCast(node))[0..self.object_size], 0);
            return node;
        }

        // 新しいチャンクを割り当て
        if (self.chunk_list.items.len == 0 or self._isFull()) {
            try self._allocateChunk();
        }

        // 最新チャンクから割り当て
        const chunk = self.chunk_list.items[self.chunk_list.items.len - 1];
        const chunk_bytes = @as([*]u8, @ptrCast(chunk));

        var i: usize = 0;
        while (i < self.objects_per_chunk) : (i += 1) {
            const obj_ptr = chunk_bytes + i * self.object_size;
            const node = @as(*Node, @ptrCast(@alignCast(obj_ptr)));

            // オブジェクトが未使用かチェック (0埋めされているはず)
            var is_unused = true;
            for (0..self.object_size) |j| {
                if (obj_ptr[j] != 0) {
                    is_unused = false;
                    break;
                }
            }

            if (is_unused) {
                return node;
            }
        }

        // すべてのオブジェクトが使用中の場合は新しいチャンクを割り当て
        try self._allocateChunk();
        const new_chunk = self.chunk_list.items[self.chunk_list.items.len - 1];
        return @as(*Node, @ptrCast(@alignCast(new_chunk)));
    }

    pub fn destroy(self: *ObjectPool, ptr: *anyopaque) void {
        const node = @as(*Node, @ptrCast(@alignCast(ptr)));
        node.next = self.free_list;
        self.free_list = node;
    }

    fn _allocateChunk(self: *ObjectPool) !void {
        const chunk_size = self.object_size * self.objects_per_chunk;
        const chunk = try self.allocator.alignedAlloc(u8, self.alignment, chunk_size);

        // チャンクを0で初期化
        @memset(chunk, 0);

        try self.chunk_list.append(@ptrCast(chunk.ptr));
    }

    fn _isFull(self: *ObjectPool) bool {
        if (self.chunk_list.items.len == 0) return true;

        const chunk = self.chunk_list.items[self.chunk_list.items.len - 1];
        const chunk_bytes = @as([*]u8, @ptrCast(chunk));

        // チャンク内のすべてのオブジェクトをチェック
        var i: usize = 0;
        while (i < self.objects_per_chunk) : (i += 1) {
            const obj_ptr = chunk_bytes + i * self.object_size;

            // オブジェクトが未使用かチェック (0埋めされているはず)
            var is_unused = true;
            for (0..self.object_size) |j| {
                if (obj_ptr[j] != 0) {
                    is_unused = false;
                    break;
                }
            }

            if (is_unused) {
                return false; // 未使用のオブジェクトがある
            }
        }

        return true; // すべてのオブジェクトが使用中
    }
};

// 使用例のためのテスト
test "QuantumArenaAllocator基本テスト" {
    var arena = QuantumArenaAllocator.init(std.testing.allocator, .Balanced);
    defer arena.deinit();

    const allocator = arena.allocator();

    // 複数のアロケーション
    var memory1 = try allocator.alloc(u8, 1000);
    var memory2 = try allocator.alloc(u8, 2000);
    var memory3 = try allocator.alloc(u8, 3000);

    // メモリ使用
    @memset(memory1, 0xAA);
    @memset(memory2, 0xBB);
    @memset(memory3, 0xCC);

    // 統計確認
    const stats = arena.getStats();
    try std.testing.expect(stats.total_allocated >= 6000);
    try std.testing.expect(stats.allocation_count >= 3);

    // リセット
    arena.reset();

    // リセット後の新しいアロケーション
    var new_memory = try allocator.alloc(u8, 5000);
    @memset(new_memory, 0xDD);
}

test "ObjectPool基本テスト" {
    const TestObject = struct {
        value: u64,
        data: [64]u8,
    };

    var pool = ObjectPool.init(std.testing.allocator, TestObject, 16);
    defer pool.deinit();

    // オブジェクト作成
    const obj1 = try pool.create();
    const obj2 = try pool.create();
    const obj3 = try pool.create();

    // オブジェクトをキャストして使用
    const test_obj1 = @as(*TestObject, @ptrCast(@alignCast(obj1)));
    test_obj1.value = 42;
    test_obj1.data[0] = 123;

    // オブジェクト解放と再利用
    pool.destroy(obj1);
    const obj4 = try pool.create();

    // 再利用されたオブジェクトは初期化済み
    const test_obj4 = @as(*TestObject, @ptrCast(@alignCast(obj4)));
    try std.testing.expect(test_obj4.value == 0);
    try std.testing.expect(test_obj4.data[0] == 0);

    // 残りのオブジェクトも解放
    pool.destroy(obj2);
    pool.destroy(obj3);
    pool.destroy(obj4);
}
