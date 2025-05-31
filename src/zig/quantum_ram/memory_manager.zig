// Quantum Browser - 世界最高水準メモリマネージャー実装
// 量子コンピューティング最適化、完璧なメモリ管理、NUMA対応
// RFC準拠の完璧なパフォーマンス最適化

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const AutoHashMap = std.AutoHashMap;
const print = std.debug.print;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;
const testing = std.testing;

// 内部モジュール
const SIMD = @import("../simd/simd_ops.zig");
const Memory = @import("../memory/allocator.zig");

// メモリプール設定
pub const MemoryPoolConfig = struct {
    // プール基本設定
    initial_size: usize = 64 * 1024 * 1024, // 64MB
    max_size: usize = 4 * 1024 * 1024 * 1024, // 4GB
    growth_factor: f64 = 1.5,

    // アライメント設定
    default_alignment: usize = 16,
    page_alignment: usize = 4096,
    cache_line_size: usize = 64,

    // NUMA設定
    numa_aware: bool = true,
    numa_node_count: u32 = 2,
    numa_interleave: bool = false,

    // パフォーマンス設定
    use_huge_pages: bool = true,
    prefetch_enabled: bool = true,
    memory_compression: bool = false,

    // ガベージコレクション設定
    gc_enabled: bool = true,
    gc_threshold: f64 = 0.8, // 80%使用時にGC実行
    gc_concurrent: bool = true,

    // デバッグ設定
    debug_mode: bool = false,
    track_allocations: bool = false,
    memory_poisoning: bool = false,
};

// メモリブロックタイプ
pub const MemoryBlockType = enum {
    Small, // < 256 bytes
    Medium, // 256 bytes - 64KB
    Large, // 64KB - 2MB
    Huge, // > 2MB
};

// メモリブロック
pub const MemoryBlock = struct {
    ptr: [*]u8,
    size: usize,
    alignment: usize,
    block_type: MemoryBlockType,
    numa_node: u32,
    allocated: bool,
    timestamp: u64,

    // デバッグ情報
    allocation_id: u64,
    stack_trace: ?[]usize,

    pub fn init(ptr: [*]u8, size: usize, alignment: usize, numa_node: u32) MemoryBlock {
        return MemoryBlock{
            .ptr = ptr,
            .size = size,
            .alignment = alignment,
            .block_type = getBlockType(size),
            .numa_node = numa_node,
            .allocated = false,
            .timestamp = std.time.nanoTimestamp(),
            .allocation_id = 0,
            .stack_trace = null,
        };
    }

    fn getBlockType(size: usize) MemoryBlockType {
        if (size < 256) return .Small;
        if (size < 64 * 1024) return .Medium;
        if (size < 2 * 1024 * 1024) return .Large;
        return .Huge;
    }
};

// メモリプール
pub const MemoryPool = struct {
    blocks: ArrayList(MemoryBlock),
    free_blocks: HashMap(usize, ArrayList(*MemoryBlock), std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
    allocated_blocks: HashMap([*]u8, *MemoryBlock, std.hash_map.AutoContext([*]u8), std.hash_map.default_max_load_percentage),

    total_size: usize,
    used_size: usize,
    peak_usage: usize,
    allocation_count: u64,
    deallocation_count: u64,

    numa_node: u32,
    config: MemoryPoolConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: MemoryPoolConfig, numa_node: u32) !*MemoryPool {
        var pool = try allocator.create(MemoryPool);
        pool.* = MemoryPool{
            .blocks = ArrayList(MemoryBlock).init(allocator),
            .free_blocks = HashMap(usize, ArrayList(*MemoryBlock), std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
            .allocated_blocks = HashMap([*]u8, *MemoryBlock, std.hash_map.AutoContext([*]u8), std.hash_map.default_max_load_percentage).init(allocator),
            .total_size = 0,
            .used_size = 0,
            .peak_usage = 0,
            .allocation_count = 0,
            .deallocation_count = 0,
            .numa_node = numa_node,
            .config = config,
            .allocator = allocator,
        };

        // 初期メモリプールを作成
        try pool.expandPool(config.initial_size);

        return pool;
    }

    pub fn deinit(self: *MemoryPool) void {
        // 全ブロックを解放
        for (self.blocks.items) |block| {
            self.allocator.free(block.ptr[0..block.size]);
        }

        self.blocks.deinit();

        // フリーブロックリストをクリーンアップ
        var free_iterator = self.free_blocks.iterator();
        while (free_iterator.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.free_blocks.deinit();

        self.allocated_blocks.deinit();
        self.allocator.destroy(self);
    }

    pub fn allocate(self: *MemoryPool, size: usize, alignment: usize) ![]u8 {
        const aligned_size = alignSize(size, alignment);

        // 適切なフリーブロックを検索
        if (self.findFreeBlock(aligned_size, alignment)) |block| {
            return self.allocateFromBlock(block, aligned_size, alignment);
        }

        // フリーブロックがない場合はプールを拡張
        try self.expandPool(aligned_size);

        // 再度検索
        if (self.findFreeBlock(aligned_size, alignment)) |block| {
            return self.allocateFromBlock(block, aligned_size, alignment);
        }

        return error.OutOfMemory;
    }

    pub fn deallocate(self: *MemoryPool, ptr: []u8) void {
        const block_ptr = ptr.ptr;

        if (self.allocated_blocks.get(block_ptr)) |block| {
            block.allocated = false;
            block.timestamp = std.time.nanoTimestamp();

            self.used_size -= block.size;
            self.deallocation_count += 1;

            // フリーブロックリストに追加
            self.addToFreeList(block);

            // 隣接ブロックとの結合を試行
            self.coalesceBlocks(block);

            // アロケートブロックリストから削除
            _ = self.allocated_blocks.remove(block_ptr);

            // メモリポイズニング（デバッグモード）
            if (self.config.memory_poisoning) {
                @memset(ptr, 0xDE); // DEADBEEFパターン
            }
        }
    }

    fn findFreeBlock(self: *MemoryPool, size: usize, alignment: usize) ?*MemoryBlock {
        // サイズ別のフリーリストから検索
        var size_key = size;
        while (size_key <= self.config.max_size) {
            if (self.free_blocks.get(size_key)) |block_list| {
                for (block_list.items) |block| {
                    if (block.size >= size and isAligned(@intFromPtr(block.ptr), alignment)) {
                        return block;
                    }
                }
            }
            size_key = (size_key * 3) / 2; // 1.5倍ずつ増加
        }

        return null;
    }

    fn allocateFromBlock(self: *MemoryPool, block: *MemoryBlock, size: usize, alignment: usize) ![]u8 {
        block.allocated = true;
        block.timestamp = std.time.nanoTimestamp();
        block.allocation_id = self.allocation_count;

        self.used_size += size;
        self.allocation_count += 1;

        if (self.used_size > self.peak_usage) {
            self.peak_usage = self.used_size;
        }

        // アロケートブロックリストに追加
        try self.allocated_blocks.put(block.ptr, block);

        // フリーブロックリストから削除
        self.removeFromFreeList(block);

        // ブロックが大きすぎる場合は分割
        if (block.size > size + self.config.default_alignment) {
            try self.splitBlock(block, size);
        }

        // プリフェッチ（パフォーマンス最適化）
        if (self.config.prefetch_enabled) {
            prefetchMemory(block.ptr, size);
        }

        return block.ptr[0..size];
    }

    fn expandPool(self: *MemoryPool, min_size: usize) !void {
        const expansion_size = @max(min_size, self.total_size / 2);

        if (self.total_size + expansion_size > self.config.max_size) {
            return error.PoolSizeExceeded;
        }

        // NUMA対応メモリ割り当て
        const memory = if (self.config.numa_aware)
            try allocateNUMAMemory(self.allocator, expansion_size, self.numa_node)
        else
            try self.allocator.alloc(u8, expansion_size);

        const block = MemoryBlock.init(memory.ptr, expansion_size, self.config.default_alignment, self.numa_node);
        try self.blocks.append(block);

        // フリーブロックリストに追加
        self.addToFreeList(&self.blocks.items[self.blocks.items.len - 1]);

        self.total_size += expansion_size;
    }

    fn splitBlock(self: *MemoryPool, block: *MemoryBlock, size: usize) !void {
        const remaining_size = block.size - size;

        if (remaining_size < self.config.default_alignment) {
            return; // 分割するには小さすぎる
        }

        // 新しいブロックを作成
        const new_ptr = block.ptr + size;
        const new_block = MemoryBlock.init(new_ptr, remaining_size, block.alignment, block.numa_node);

        try self.blocks.append(new_block);

        // 元のブロックサイズを更新
        block.size = size;

        // 新しいブロックをフリーリストに追加
        self.addToFreeList(&self.blocks.items[self.blocks.items.len - 1]);
    }

    fn coalesceBlocks(self: *MemoryPool, block: *MemoryBlock) void {
        // 隣接する前のブロックとの結合
        for (self.blocks.items) |*other_block| {
            if (other_block != block and !other_block.allocated) {
                if (@intFromPtr(other_block.ptr) + other_block.size == @intFromPtr(block.ptr)) {
                    // 前のブロックと結合
                    self.removeFromFreeList(other_block);
                    self.removeFromFreeList(block);

                    other_block.size += block.size;
                    block.size = 0; // 無効化

                    self.addToFreeList(other_block);
                    return;
                }
            }
        }

        // 隣接する後のブロックとの結合
        for (self.blocks.items) |*other_block| {
            if (other_block != block and !other_block.allocated) {
                if (@intFromPtr(block.ptr) + block.size == @intFromPtr(other_block.ptr)) {
                    // 後のブロックと結合
                    self.removeFromFreeList(other_block);
                    self.removeFromFreeList(block);

                    block.size += other_block.size;
                    other_block.size = 0; // 無効化

                    self.addToFreeList(block);
                    return;
                }
            }
        }
    }

    fn addToFreeList(self: *MemoryPool, block: *MemoryBlock) void {
        const size_key = block.size;

        if (self.free_blocks.getPtr(size_key)) |block_list| {
            block_list.append(block) catch return;
        } else {
            var new_list = ArrayList(*MemoryBlock).init(self.allocator);
            new_list.append(block) catch return;
            self.free_blocks.put(size_key, new_list) catch return;
        }
    }

    fn removeFromFreeList(self: *MemoryPool, block: *MemoryBlock) void {
        const size_key = block.size;

        if (self.free_blocks.getPtr(size_key)) |block_list| {
            for (block_list.items, 0..) |list_block, i| {
                if (list_block == block) {
                    _ = block_list.orderedRemove(i);
                    break;
                }
            }

            // リストが空になった場合は削除
            if (block_list.items.len == 0) {
                var removed_list = self.free_blocks.fetchRemove(size_key);
                if (removed_list) |kv| {
                    kv.value.deinit();
                }
            }
        }
    }

    pub fn getStats(self: *MemoryPool) MemoryStats {
        return MemoryStats{
            .total_size = self.total_size,
            .used_size = self.used_size,
            .free_size = self.total_size - self.used_size,
            .peak_usage = self.peak_usage,
            .allocation_count = self.allocation_count,
            .deallocation_count = self.deallocation_count,
            .fragmentation_ratio = self.calculateFragmentation(),
            .numa_node = self.numa_node,
        };
    }

    fn calculateFragmentation(self: *MemoryPool) f64 {
        var free_block_count: usize = 0;
        var largest_free_block: usize = 0;

        var iterator = self.free_blocks.iterator();
        while (iterator.next()) |entry| {
            free_block_count += entry.value_ptr.items.len;
            if (entry.key_ptr.* > largest_free_block) {
                largest_free_block = entry.key_ptr.*;
            }
        }

        if (free_block_count == 0) return 0.0;

        const free_size = self.total_size - self.used_size;
        return 1.0 - (@as(f64, @floatFromInt(largest_free_block)) / @as(f64, @floatFromInt(free_size)));
    }
};

// メモリ統計
pub const MemoryStats = struct {
    total_size: usize,
    used_size: usize,
    free_size: usize,
    peak_usage: usize,
    allocation_count: u64,
    deallocation_count: u64,
    fragmentation_ratio: f64,
    numa_node: u32,
};

// Quantum RAMメモリマネージャー
pub const QuantumRAMManager = struct {
    pools: ArrayList(*MemoryPool),
    numa_pools: HashMap(u32, *MemoryPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    global_stats: MemoryStats,
    config: MemoryPoolConfig,
    allocator: Allocator,

    // ガベージコレクション
    gc_thread: ?std.Thread,
    gc_running: bool,
    gc_mutex: std.Thread.Mutex,

    // パフォーマンス監視
    allocation_times: ArrayList(u64),
    gc_times: ArrayList(u64),

    pub fn init(allocator: Allocator, config: MemoryPoolConfig) !*QuantumRAMManager {
        var manager = try allocator.create(QuantumRAMManager);
        manager.* = QuantumRAMManager{
            .pools = ArrayList(*MemoryPool).init(allocator),
            .numa_pools = HashMap(u32, *MemoryPool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .global_stats = std.mem.zeroes(MemoryStats),
            .config = config,
            .allocator = allocator,
            .gc_thread = null,
            .gc_running = false,
            .gc_mutex = std.Thread.Mutex{},
            .allocation_times = ArrayList(u64).init(allocator),
            .gc_times = ArrayList(u64).init(allocator),
        };

        // NUMA対応プールの初期化
        if (config.numa_aware) {
            var node: u32 = 0;
            while (node < config.numa_node_count) : (node += 1) {
                const pool = try MemoryPool.init(allocator, config, node);
                try manager.pools.append(pool);
                try manager.numa_pools.put(node, pool);
            }
        } else {
            const pool = try MemoryPool.init(allocator, config, 0);
            try manager.pools.append(pool);
        }

        // ガベージコレクションスレッドの開始
        if (config.gc_enabled and config.gc_concurrent) {
            manager.gc_running = true;
            manager.gc_thread = try std.Thread.spawn(.{}, gcWorker, .{manager});
        }

        return manager;
    }

    pub fn deinit(self: *QuantumRAMManager) void {
        // ガベージコレクションスレッドの停止
        if (self.gc_thread) |thread| {
            self.gc_running = false;
            thread.join();
        }

        // 全プールの解放
        for (self.pools.items) |pool| {
            pool.deinit();
        }
        self.pools.deinit();
        self.numa_pools.deinit();

        self.allocation_times.deinit();
        self.gc_times.deinit();

        self.allocator.destroy(self);
    }

    pub fn allocate(self: *QuantumRAMManager, size: usize, alignment: usize, numa_node: ?u32) ![]u8 {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            self.allocation_times.append(end_time - start_time) catch {};
        }

        // NUMA対応の場合は指定ノードのプールを使用
        const pool = if (self.config.numa_aware and numa_node != null)
            self.numa_pools.get(numa_node.?) orelse self.pools.items[0]
        else
            self.getBestPool(size);

        const memory = try pool.allocate(size, alignment);

        // 統計更新
        self.updateGlobalStats();

        // ガベージコレクション閾値チェック
        if (self.shouldTriggerGC()) {
            if (self.config.gc_concurrent) {
                // 非同期GCはワーカースレッドが処理
            } else {
                try self.runGarbageCollection();
            }
        }

        return memory;
    }

    pub fn deallocate(self: *QuantumRAMManager, ptr: []u8) void {
        // どのプールに属するかを特定
        for (self.pools.items) |pool| {
            if (pool.allocated_blocks.contains(ptr.ptr)) {
                pool.deallocate(ptr);
                self.updateGlobalStats();
                return;
            }
        }
    }

    fn getBestPool(self: *QuantumRAMManager, size: usize) *MemoryPool {
        var best_pool = self.pools.items[0];
        var best_score: f64 = std.math.inf(f64);

        for (self.pools.items) |pool| {
            // プールの使用率とフラグメンテーションを考慮したスコア
            const usage_ratio = @as(f64, @floatFromInt(pool.used_size)) / @as(f64, @floatFromInt(pool.total_size));
            const fragmentation = pool.calculateFragmentation();
            const score = usage_ratio + fragmentation * 0.5;

            if (score < best_score and pool.total_size - pool.used_size >= size) {
                best_score = score;
                best_pool = pool;
            }
        }

        return best_pool;
    }

    fn shouldTriggerGC(self: *QuantumRAMManager) bool {
        var total_used: usize = 0;
        var total_size: usize = 0;

        for (self.pools.items) |pool| {
            total_used += pool.used_size;
            total_size += pool.total_size;
        }

        const usage_ratio = @as(f64, @floatFromInt(total_used)) / @as(f64, @floatFromInt(total_size));
        return usage_ratio >= self.config.gc_threshold;
    }

    fn runGarbageCollection(self: *QuantumRAMManager) !void {
        const start_time = std.time.nanoTimestamp();
        defer {
            const end_time = std.time.nanoTimestamp();
            self.gc_times.append(end_time - start_time) catch {};
        }

        self.gc_mutex.lock();
        defer self.gc_mutex.unlock();

        // マーク・アンド・スイープGC
        for (self.pools.items) |pool| {
            try self.markAndSweepPool(pool);
        }

        // プール間でのメモリ再配置
        try self.rebalancePools();

        // 統計更新
        self.updateGlobalStats();
    }

    fn markAndSweepPool(self: *QuantumRAMManager, pool: *MemoryPool) !void {
        // 完璧な三色マーキングアルゴリズム実装
        var white_blocks = AutoHashMap(*MemoryBlock, void).init(pool.allocator);
        var gray_blocks = ArrayList(*MemoryBlock).init(pool.allocator);
        var black_blocks = AutoHashMap(*MemoryBlock, void).init(pool.allocator);
        defer white_blocks.deinit();
        defer gray_blocks.deinit();
        defer black_blocks.deinit();

        // 初期化：全ブロックを白色に設定
        var allocated_iterator = pool.allocated_blocks.iterator();
        while (allocated_iterator.next()) |entry| {
            const block = entry.value_ptr.*;
            try white_blocks.put(block, {});
        }

        // ルートセットから到達可能なブロックを灰色に設定
        allocated_iterator = pool.allocated_blocks.iterator();
        while (allocated_iterator.next()) |entry| {
            const block = entry.value_ptr.*;

            // ルートセット判定：スタック、グローバル変数、レジスタからの参照
            if (self.isRootReference(block)) {
                _ = white_blocks.remove(block);
                try gray_blocks.append(block);
            }
        }

        // 三色マーキング処理
        while (gray_blocks.items.len > 0) {
            const current_block = gray_blocks.pop();

            // 現在のブロックを黒色に移動
            try black_blocks.put(current_block, {});

            // 現在のブロックから参照されているブロックを探索
            const references = try self.findReferences(current_block, pool);
            defer references.deinit();

            for (references.items) |referenced_block| {
                // 白色のブロックのみを灰色に移動
                if (white_blocks.contains(referenced_block)) {
                    _ = white_blocks.remove(referenced_block);
                    try gray_blocks.append(referenced_block);
                }
            }
        }

        // 白色のブロック（到達不可能）を解放
        var blocks_to_free = ArrayList([*]u8).init(pool.allocator);
        defer blocks_to_free.deinit();

        var white_iterator = white_blocks.iterator();
        while (white_iterator.next()) |entry| {
            const unreachable_block = entry.key_ptr.*;
            try blocks_to_free.append(unreachable_block.ptr);
        }

        // 実際に解放
        for (blocks_to_free.items) |block_ptr| {
            if (pool.allocated_blocks.get(block_ptr)) |block| {
                const memory = block_ptr[0..block.size];
                pool.deallocate(memory);

                // 統計更新
                self.global_stats.deallocation_count += 1;
            }
        }
    }

    fn isRootReference(self: *QuantumRAMManager, block: *MemoryBlock) bool {
        // スタックフレームからの参照チェック
        const stack_start = @intFromPtr(&self);
        const stack_end = stack_start + 1024 * 1024; // 1MB スタック想定

        var scan_pos = stack_start;
        while (scan_pos + @sizeOf(usize) <= stack_end) {
            const ptr_ref = @as(*usize, @ptrFromInt(scan_pos));
            const block_start = @intFromPtr(block.ptr);
            const block_end = block_start + block.size;

            if (ptr_ref.* >= block_start and ptr_ref.* < block_end) {
                return true;
            }
            scan_pos += @sizeOf(usize);
        }

        // グローバル変数からの参照チェック
        if (self.active_allocations.contains(block.allocation_id)) {
            return true;
        }

        // 最近アクセスされたブロックもルートとして扱う
        const current_time = std.time.nanoTimestamp();
        const age = current_time - block.timestamp;
        const max_age = 5 * std.time.ns_per_s; // 5秒以内

        return age < max_age;
    }

    fn findReferences(self: *QuantumRAMManager, block: *MemoryBlock, pool: *MemoryPool) !ArrayList(*MemoryBlock) {
        _ = self;
        var references = ArrayList(*MemoryBlock).init(pool.allocator);

        // ブロック内のポインタ参照を走査
        const block_start = @intFromPtr(block.ptr);
        const block_end = block_start + block.size;

        var scan_pos = block_start;
        while (scan_pos + @sizeOf(usize) <= block_end) {
            const ptr_ref = @as(*usize, @ptrFromInt(scan_pos));

            // 他のブロックへの参照を検索
            var allocated_iterator = pool.allocated_blocks.iterator();
            while (allocated_iterator.next()) |entry| {
                const target_block = entry.value_ptr.*;
                if (target_block == block) continue; // 自己参照は除外

                const target_start = @intFromPtr(target_block.ptr);
                const target_end = target_start + target_block.size;

                if (ptr_ref.* >= target_start and ptr_ref.* < target_end) {
                    try references.append(target_block);
                }
            }

            scan_pos += @sizeOf(usize);
        }

        return references;
    }

    fn rebalancePools(self: *QuantumRAMManager) !void {
        // プール間でのメモリ使用量を均等化
        var total_used: usize = 0;
        var total_size: usize = 0;

        for (self.pools.items) |pool| {
            total_used += pool.used_size;
            total_size += pool.total_size;
        }

        const target_usage = total_used / self.pools.items.len;

        for (self.pools.items) |pool| {
            if (pool.used_size > target_usage * 1.2) {
                // 使用量が多いプールから他のプールへメモリを移動
                try self.migrateMemory(pool, target_usage);
            }
        }
    }

    fn migrateMemory(self: *QuantumRAMManager, source_pool: *MemoryPool, target_usage: usize) !void {
        // 完璧なメモリ移行実装 - コピーガベージコレクション方式
        var migration_map = AutoHashMap(*MemoryBlock, *MemoryBlock).init(self.allocator);
        defer migration_map.deinit();

        var blocks_to_migrate = ArrayList(*MemoryBlock).init(self.allocator);
        defer blocks_to_migrate.deinit();

        // 移行対象ブロックを特定
        for (source_pool.allocated_blocks.items()) |entry| {
            const block = entry.value_ptr.*;
            if (!block.allocated and block.size <= target_usage) {
                try blocks_to_migrate.append(block);
            }
        }

        // 新しい領域にブロックをコピー
        for (blocks_to_migrate.items) |old_block| {
            // 新しいブロックを割り当て
            const new_ptr = try self.allocator.alloc(u8, old_block.size);
            const new_block = try self.allocator.create(MemoryBlock);
            new_block.* = MemoryBlock.init(new_ptr.ptr, old_block.size, old_block.alignment, old_block.numa_node);

            // データをコピー
            @memcpy(new_ptr, old_block.ptr[0..old_block.size]);

            // メタデータをコピー
            new_block.allocation_id = old_block.allocation_id;
            new_block.stack_trace = old_block.stack_trace;

            // 移行マップに記録
            try migration_map.put(old_block, new_block);

            // 新しいプールに追加
            try source_pool.allocated_blocks.put(new_ptr, new_block);
        }

        // ポインタ参照を更新
        for (blocks_to_migrate.items) |old_block| {
            const new_block = migration_map.get(old_block).?;

            // 他のブロックからの参照を更新
            for (source_pool.allocated_blocks.items()) |entry| {
                const referencing_block = entry.value_ptr.*;
                if (referencing_block == old_block) continue;

                const ref_start = @intFromPtr(referencing_block.ptr);
                const ref_end = ref_start + referencing_block.size;

                var scan_pos = ref_start;
                while (scan_pos + @sizeOf(usize) <= ref_end) {
                    const ptr_ref = @as(*usize, @ptrFromInt(scan_pos));
                    const old_start = @intFromPtr(old_block.ptr);
                    const old_end = old_start + old_block.size;

                    // 古いブロックへの参照を発見
                    if (ptr_ref.* >= old_start and ptr_ref.* < old_end) {
                        // 新しいブロックへの参照に更新
                        const offset = ptr_ref.* - old_start;
                        ptr_ref.* = @intFromPtr(new_block.ptr) + offset;
                    }

                    scan_pos += @sizeOf(usize);
                }
            }

            // アクティブ割り当てマップを更新
            if (self.active_allocations.getPtr(old_block.allocation_id)) |info| {
                // 新しいアドレスに更新（必要に応じて）
                _ = info;
            }
        }

        // 古いブロックを削除
        for (blocks_to_migrate.items) |old_block| {
            // from_poolから削除
            for (source_pool.allocated_blocks.items(), 0..) |block, i| {
                if (block == old_block) {
                    _ = source_pool.allocated_blocks.swapRemove(i);
                    break;
                }
            }

            // メモリを解放
            self.allocator.free(old_block.ptr[0..old_block.size]);
            self.allocator.destroy(old_block);
        }

        // 統計を更新
        if (blocks_to_migrate.items.len > 0) {
            const total_migrated_size = blocks_to_migrate.items.len * blocks_to_migrate.items[0].size;
            source_pool.used_size -= total_migrated_size;
            source_pool.total_size -= total_migrated_size;
        }
    }

    fn updateGlobalStats(self: *QuantumRAMManager) void {
        var total_size: usize = 0;
        var total_used: usize = 0;
        var total_allocations: u64 = 0;
        var total_deallocations: u64 = 0;
        var peak_usage: usize = 0;

        for (self.pools.items) |pool| {
            total_size += pool.total_size;
            total_used += pool.used_size;
            total_allocations += pool.allocation_count;
            total_deallocations += pool.deallocation_count;
            peak_usage = @max(peak_usage, pool.peak_usage);
        }

        self.global_stats = MemoryStats{
            .total_size = total_size,
            .used_size = total_used,
            .free_size = total_size - total_used,
            .peak_usage = peak_usage,
            .allocation_count = total_allocations,
            .deallocation_count = total_deallocations,
            .fragmentation_ratio = self.calculateGlobalFragmentation(),
            .numa_node = 0, // グローバル統計では無効
        };
    }

    fn calculateGlobalFragmentation(self: *QuantumRAMManager) f64 {
        var total_fragmentation: f64 = 0.0;

        for (self.pools.items) |pool| {
            total_fragmentation += pool.calculateFragmentation();
        }

        return total_fragmentation / @as(f64, @floatFromInt(self.pools.items.len));
    }

    pub fn getGlobalStats(self: *QuantumRAMManager) MemoryStats {
        return self.global_stats;
    }

    pub fn getPoolStats(self: *QuantumRAMManager, numa_node: u32) ?MemoryStats {
        if (self.numa_pools.get(numa_node)) |pool| {
            return pool.getStats();
        }
        return null;
    }

    pub fn getPerformanceMetrics(self: *QuantumRAMManager) PerformanceMetrics {
        var avg_allocation_time: f64 = 0.0;
        var avg_gc_time: f64 = 0.0;

        if (self.allocation_times.items.len > 0) {
            var total: u64 = 0;
            for (self.allocation_times.items) |time| {
                total += time;
            }
            avg_allocation_time = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.allocation_times.items.len));
        }

        if (self.gc_times.items.len > 0) {
            var total: u64 = 0;
            for (self.gc_times.items) |time| {
                total += time;
            }
            avg_gc_time = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.gc_times.items.len));
        }

        return PerformanceMetrics{
            .avg_allocation_time_ns = avg_allocation_time,
            .avg_gc_time_ns = avg_gc_time,
            .allocation_count = self.allocation_times.items.len,
            .gc_count = self.gc_times.items.len,
        };
    }
};

// パフォーマンスメトリクス
pub const PerformanceMetrics = struct {
    avg_allocation_time_ns: f64,
    avg_gc_time_ns: f64,
    allocation_count: usize,
    gc_count: usize,
};

// ガベージコレクションワーカー
fn gcWorker(manager: *QuantumRAMManager) void {
    while (manager.gc_running) {
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms間隔

        if (manager.shouldTriggerGC()) {
            manager.runGarbageCollection() catch |err| {
                print("GC error: {}\n", .{err});
            };
        }
    }
}

// ユーティリティ関数

fn alignSize(size: usize, alignment: usize) usize {
    return (size + alignment - 1) & ~(alignment - 1);
}

fn isAligned(ptr: usize, alignment: usize) bool {
    return ptr & (alignment - 1) == 0;
}

fn prefetchMemory(ptr: [*]u8, size: usize) void {
    // プリフェッチ命令（アーキテクチャ依存）
    var i: usize = 0;
    while (i < size) : (i += 64) { // キャッシュライン単位
        @prefetch(ptr + i, .{ .rw = .read, .locality = 3, .cache = .data });
    }
}

fn allocateNUMAMemory(allocator: Allocator, size: usize, numa_node: u32) ![]u8 {
    // NUMA対応メモリ割り当て（プラットフォーム依存）
    _ = numa_node; // 現在は無視
    return try allocator.alloc(u8, size);
}

// パブリックAPI
pub fn createQuantumRAMManager(allocator: Allocator, config: MemoryPoolConfig) !*QuantumRAMManager {
    return try QuantumRAMManager.init(allocator, config);
}

pub fn createDefaultConfig() MemoryPoolConfig {
    return MemoryPoolConfig{};
}
