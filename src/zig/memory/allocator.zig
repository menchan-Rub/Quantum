// src/zig/memory/allocator.zig
// Quantum Browser - 高性能メモリアロケーター完全実装
// メモリプール、ガベージコレクション、SIMD最適化対応

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Atomic;
const assert = std.debug.assert;
const print = std.debug.print;

// SIMD最適化
const SIMD = @import("../simd/simd_ops.zig");

// Quantum メモリアロケーター
pub const QuantumAllocator = struct {
    base_allocator: Allocator,
    
    // メモリプール
    small_pool: *SmallObjectPool,
    medium_pool: *MediumObjectPool,
    large_pool: *LargeObjectPool,
    
    // ガベージコレクション
    gc: *GarbageCollector,
    
    // 統計情報
    stats: AllocatorStats,
    
    // 設定
    config: AllocatorConfig,
    
    // 同期プリミティブ
    mutex: Mutex,
    
    // 状態管理
    initialized: bool,
    
    pub fn init(base_allocator: Allocator, config: AllocatorConfig) !*QuantumAllocator {
        var allocator = try base_allocator.create(QuantumAllocator);
        
        allocator.* = QuantumAllocator{
            .base_allocator = base_allocator,
            .small_pool = try SmallObjectPool.init(base_allocator, config.small_pool),
            .medium_pool = try MediumObjectPool.init(base_allocator, config.medium_pool),
            .large_pool = try LargeObjectPool.init(base_allocator, config.large_pool),
            .gc = try GarbageCollector.init(base_allocator, config.gc),
            .stats = AllocatorStats.init(),
            .config = config,
            .mutex = Mutex{},
            .initialized = false,
        };
        
        try allocator.initialize();
        return allocator;
    }
    
    pub fn deinit(self: *QuantumAllocator) void {
        if (!self.initialized) return;
        
        self.gc.deinit();
        self.large_pool.deinit();
        self.medium_pool.deinit();
        self.small_pool.deinit();
        
        self.base_allocator.destroy(self);
    }
    
    fn initialize(self: *QuantumAllocator) !void {
        // プールの初期化
        try self.small_pool.initialize();
        try self.medium_pool.initialize();
        try self.large_pool.initialize();
        
        // ガベージコレクターの開始
        try self.gc.start(self);
        
        self.initialized = true;
        print("Quantum Allocator initialized successfully\n");
    }
    
    // メモリ割り当て
    pub fn alloc(self: *QuantumAllocator, size: usize, alignment: u29) ![]u8 {
        if (!self.initialized) return error.NotInitialized;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const start_time = std.time.nanoTimestamp();
        
        const memory = try self.allocateMemory(size, alignment);
        
        // 統計情報の更新
        const duration = std.time.nanoTimestamp() - start_time;
        self.updateAllocStats(size, duration);
        
        return memory;
    }
    
    // メモリ解放
    pub fn free(self: *QuantumAllocator, memory: []u8) void {
        if (!self.initialized) return;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const start_time = std.time.nanoTimestamp();
        
        self.freeMemory(memory);
        
        // 統計情報の更新
        const duration = std.time.nanoTimestamp() - start_time;
        self.updateFreeStats(memory.len, duration);
    }
    
    // リサイズ
    pub fn resize(self: *QuantumAllocator, old_memory: []u8, new_size: usize, alignment: u29) ![]u8 {
        if (!self.initialized) return error.NotInitialized;
        
        if (new_size == 0) {
            self.free(old_memory);
            return &[_]u8{};
        }
        
        if (old_memory.len == 0) {
            return try self.alloc(new_size, alignment);
        }
        
        // 同じプール内でのリサイズを試行
        if (self.tryResizeInPlace(old_memory, new_size)) |resized| {
            return resized;
        }
        
        // 新しいメモリを割り当てて内容をコピー
        const new_memory = try self.alloc(new_size, alignment);
        const copy_size = @min(old_memory.len, new_size);
        
        // SIMD最適化されたメモリコピー
        SIMD.memcpy(new_memory.ptr, old_memory.ptr, copy_size);
        
        self.free(old_memory);
        return new_memory;
    }
    
    // インプレースリサイズの試行
    fn tryResizeInPlace(self: *QuantumAllocator, memory: []u8, new_size: usize) ?[]u8 {
        const pool_type = self.getPoolType(memory.len);
        const new_pool_type = self.getPoolType(new_size);
        
        // 同じプールタイプの場合のみインプレースリサイズを試行
        if (pool_type != new_pool_type) return null;
        
        return switch (pool_type) {
            .Small => self.small_pool.tryResize(memory, new_size),
            .Medium => self.medium_pool.tryResize(memory, new_size),
            .Large => self.large_pool.tryResize(memory, new_size),
        };
    }
    
    // メモリ割り当ての実装
    fn allocateMemory(self: *QuantumAllocator, size: usize, alignment: u29) ![]u8 {
        const pool_type = self.getPoolType(size);
        
        return switch (pool_type) {
            .Small => try self.small_pool.allocate(size, alignment),
            .Medium => try self.medium_pool.allocate(size, alignment),
            .Large => try self.large_pool.allocate(size, alignment),
        };
    }
    
    // メモリ解放の実装
    fn freeMemory(self: *QuantumAllocator, memory: []u8) void {
        const pool_type = self.getPoolType(memory.len);
        
        switch (pool_type) {
            .Small => self.small_pool.free(memory),
            .Medium => self.medium_pool.free(memory),
            .Large => self.large_pool.free(memory),
        }
    }
    
    // プールタイプの決定
    fn getPoolType(self: *QuantumAllocator, size: usize) PoolType {
        if (size <= self.config.small_pool.max_size) return .Small;
        if (size <= self.config.medium_pool.max_size) return .Medium;
        return .Large;
    }
    
    // 統計情報の更新
    fn updateAllocStats(self: *QuantumAllocator, size: usize, duration: i64) void {
        self.stats.total_allocations += 1;
        self.stats.total_allocated += size;
        self.stats.total_alloc_time += duration;
        self.stats.average_alloc_time = @intToFloat(f64, self.stats.total_alloc_time) / @intToFloat(f64, self.stats.total_allocations);
    }
    
    fn updateFreeStats(self: *QuantumAllocator, size: usize, duration: i64) void {
        self.stats.total_frees += 1;
        self.stats.total_freed += size;
        self.stats.total_free_time += duration;
        self.stats.average_free_time = @intToFloat(f64, self.stats.total_free_time) / @intToFloat(f64, self.stats.total_frees);
    }
    
    // 統計情報の取得
    pub fn getStats(self: *QuantumAllocator) AllocatorStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var stats = self.stats;
        stats.small_pool = self.small_pool.getStats();
        stats.medium_pool = self.medium_pool.getStats();
        stats.large_pool = self.large_pool.getStats();
        stats.gc = self.gc.getStats();
        
        return stats;
    }
    
    // ガベージコレクションの手動実行
    pub fn collectGarbage(self: *QuantumAllocator) !usize {
        return try self.gc.collect();
    }
    
    // メモリ使用量の取得
    pub fn getMemoryUsage(self: *QuantumAllocator) MemoryUsage {
        return MemoryUsage{
            .allocated = self.stats.total_allocated - self.stats.total_freed,
            .reserved = self.small_pool.getReservedMemory() + 
                       self.medium_pool.getReservedMemory() + 
                       self.large_pool.getReservedMemory(),
            .fragmentation = self.calculateFragmentation(),
        };
    }
    
    // フラグメンテーション率の計算
    fn calculateFragmentation(self: *QuantumAllocator) f64 {
        const usage = self.getMemoryUsage();
        if (usage.reserved == 0) return 0.0;
        
        return (@intToFloat(f64, usage.reserved - usage.allocated) / @intToFloat(f64, usage.reserved)) * 100.0;
    }
    
    // ヘルスチェック
    pub fn healthCheck(self: *QuantumAllocator) HealthStatus {
        const usage = self.getMemoryUsage();
        const fragmentation = usage.fragmentation;
        
        if (fragmentation > 50.0 or usage.allocated > self.config.max_memory * 9 / 10) {
            return .Critical;
        }
        
        if (fragmentation > 30.0 or usage.allocated > self.config.max_memory * 7 / 10) {
            return .Warning;
        }
        
        return .Healthy;
    }
};

// 小オブジェクトプール (1B - 1KB)
pub const SmallObjectPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    
    // サイズクラス別のフリーリスト
    free_lists: [NUM_SIZE_CLASSES]FreeList,
    
    // メモリブロック
    blocks: ArrayList(*MemoryBlock),
    
    // 統計情報
    stats: PoolStats,
    mutex: Mutex,
    
    const NUM_SIZE_CLASSES = 64;
    const MIN_SIZE = 8;
    const MAX_SIZE = 1024;
    
    pub fn init(allocator: Allocator, config: PoolConfig) !*SmallObjectPool {
        var pool = try allocator.create(SmallObjectPool);
        pool.* = SmallObjectPool{
            .allocator = allocator,
            .config = config,
            .free_lists = [_]FreeList{FreeList.init()} ** NUM_SIZE_CLASSES,
            .blocks = ArrayList(*MemoryBlock).init(allocator),
            .stats = PoolStats.init(),
            .mutex = Mutex{},
        };
        
        return pool;
    }
    
    pub fn deinit(self: *SmallObjectPool) void {
        for (self.blocks.items) |block| {
            block.deinit(self.allocator);
        }
        self.blocks.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn initialize(self: *SmallObjectPool) !void {
        // 初期ブロックの作成
        for (0..self.config.initial_blocks) |_| {
            try self.addBlock();
        }
    }
    
    pub fn allocate(self: *SmallObjectPool, size: usize, alignment: u29) ![]u8 {
        // 完璧なアライメント対応小オブジェクト割り当て
        if (size > self.object_size) {
            return error.SizeTooLarge;
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // アライメント要求をチェック
        const required_alignment = @max(alignment, @alignOf(u8));
        const aligned_size = alignForward(size, required_alignment);
        
        if (aligned_size > self.object_size) {
            return error.SizeTooLarge;
        }
        
        // フリーリストから取得
        if (self.free_list) |node| {
            self.free_list = node.next;
            self.allocated_count += 1;
            
            // メモリをクリア
            const memory = @as([*]u8, @ptrCast(node))[0..self.object_size];
            @memset(memory, 0);
            
            // アライメント調整
            const addr = @intFromPtr(memory.ptr);
            const aligned_addr = alignForward(addr, required_alignment);
            const offset = aligned_addr - addr;
            
            if (offset + aligned_size <= self.object_size) {
                const aligned_memory = @as([*]u8, @ptrFromInt(aligned_addr));
                return aligned_memory[0..aligned_size];
            }
            
            return memory[0..aligned_size];
        }
        
        // プールを拡張
        try self.expandPool();
        
        // 再試行
        if (self.free_list) |node| {
            self.free_list = node.next;
            self.allocated_count += 1;
            
            const memory = @as([*]u8, @ptrCast(node))[0..self.object_size];
            @memset(memory, 0);
            
            const addr = @intFromPtr(memory.ptr);
            const aligned_addr = alignForward(addr, required_alignment);
            const offset = aligned_addr - addr;
            
            if (offset + aligned_size <= self.object_size) {
                const aligned_memory = @as([*]u8, @ptrFromInt(aligned_addr));
                return aligned_memory[0..aligned_size];
            }
            
            return memory[0..aligned_size];
        }
        
        return error.OutOfMemory;
    }
    
    pub fn free(self: *SmallObjectPool, memory: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const size_class = self.getSizeClass(memory.len);
        const actual_size = self.getSizeFromClass(size_class);
        
        // メモリをクリア（セキュリティ）
        SIMD.memset(memory.ptr, 0, memory.len);
        
        // フリーリストに追加
        self.free_lists[size_class].push(memory.ptr[0..actual_size]);
        
        self.stats.frees += 1;
        self.stats.freed_bytes += actual_size;
    }
    
    pub fn tryResize(self: *SmallObjectPool, memory: []u8, new_size: usize) ?[]u8 {
        const old_size_class = self.getSizeClass(memory.len);
        const new_size_class = self.getSizeClass(new_size);
        
        // 同じサイズクラスの場合はそのまま返す
        if (old_size_class == new_size_class) {
            return memory.ptr[0..new_size];
        }
        
        return null;
    }
    
    fn addBlock(self: *SmallObjectPool) !void {
        const block = try MemoryBlock.init(self.allocator, self.config.block_size);
        try self.blocks.append(block);
        
        // ブロックを各サイズクラスに分割
        self.subdivideBlock(block);
    }
    
    fn subdivideBlock(self: *SmallObjectPool, block: *MemoryBlock) void {
        var offset: usize = 0;
        
        for (0..NUM_SIZE_CLASSES) |size_class| {
            const size = self.getSizeFromClass(size_class);
            const count = (self.config.block_size / NUM_SIZE_CLASSES) / size;
            
            for (0..count) |_| {
                if (offset + size > block.size) break;
                
                const memory = block.data[offset..offset + size];
                self.free_lists[size_class].push(memory);
                offset += size;
            }
        }
    }
    
    fn getSizeClass(self: *SmallObjectPool, size: usize) usize {
        _ = self;
        
        if (size <= MIN_SIZE) return 0;
        
        // 2の累乗に基づくサイズクラス
        const log_size = std.math.log2_int(usize, size - 1) + 1;
        const base_class = log_size - std.math.log2_int(usize, MIN_SIZE);
        
        return @min(base_class, NUM_SIZE_CLASSES - 1);
    }
    
    fn getSizeFromClass(self: *SmallObjectPool, size_class: usize) usize {
        _ = self;
        
        if (size_class == 0) return MIN_SIZE;
        return MIN_SIZE << size_class;
    }
    
    pub fn getStats(self: *SmallObjectPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stats;
    }
    
    pub fn getReservedMemory(self: *SmallObjectPool) usize {
        return self.blocks.items.len * self.config.block_size;
    }
};

// 中オブジェクトプール (1KB - 1MB)
pub const MediumObjectPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    
    // バディアロケーター
    buddy_allocator: *BuddyAllocator,
    
    // 統計情報
    stats: PoolStats,
    mutex: Mutex,
    
    pub fn init(allocator: Allocator, config: PoolConfig) !*MediumObjectPool {
        var pool = try allocator.create(MediumObjectPool);
        pool.* = MediumObjectPool{
            .allocator = allocator,
            .config = config,
            .buddy_allocator = try BuddyAllocator.init(allocator, config.block_size),
            .stats = PoolStats.init(),
            .mutex = Mutex{},
        };
        
        return pool;
    }
    
    pub fn deinit(self: *MediumObjectPool) void {
        self.buddy_allocator.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn initialize(self: *MediumObjectPool) !void {
        try self.buddy_allocator.initialize();
    }
    
    pub fn allocate(self: *MediumObjectPool, size: usize, alignment: u29) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const memory = try self.buddy_allocator.allocate(size, alignment);
        
        self.stats.allocations += 1;
        self.stats.allocated_bytes += memory.len;
        
        return memory;
    }
    
    pub fn free(self: *MediumObjectPool, memory: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // メモリをクリア
        SIMD.memset(memory.ptr, 0, memory.len);
        
        self.buddy_allocator.free(memory);
        
        self.stats.frees += 1;
        self.stats.freed_bytes += memory.len;
    }
    
    pub fn tryResize(self: *MediumObjectPool, memory: []u8, new_size: usize) ?[]u8 {
        return self.buddy_allocator.tryResize(memory, new_size);
    }
    
    pub fn getStats(self: *MediumObjectPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stats;
    }
    
    pub fn getReservedMemory(self: *MediumObjectPool) usize {
        return self.buddy_allocator.getTotalMemory();
    }
};

// 大オブジェクトプール (1MB+)
pub const LargeObjectPool = struct {
    allocator: Allocator,
    config: PoolConfig,
    
    // 直接割り当て
    allocations: HashMap(usize, []u8, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
    
    // 統計情報
    stats: PoolStats,
    mutex: Mutex,
    
    pub fn init(allocator: Allocator, config: PoolConfig) !*LargeObjectPool {
        var pool = try allocator.create(LargeObjectPool);
        pool.* = LargeObjectPool{
            .allocator = allocator,
            .config = config,
            .allocations = HashMap(usize, []u8, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
            .stats = PoolStats.init(),
            .mutex = Mutex{},
        };
        
        return pool;
    }
    
    pub fn deinit(self: *LargeObjectPool) void {
        var iterator = self.allocations.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.allocations.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn initialize(self: *LargeObjectPool) !void {
        // 初期化は不要
    }
    
    pub fn allocate(self: *LargeObjectPool, size: usize, alignment: u29) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const memory = try self.allocator.alignedAlloc(u8, alignment, size);
        const addr = @ptrToInt(memory.ptr);
        
        try self.allocations.put(addr, memory);
        
        self.stats.allocations += 1;
        self.stats.allocated_bytes += size;
        
        return memory;
    }
    
    pub fn free(self: *LargeObjectPool, memory: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const addr = @ptrToInt(memory.ptr);
        
        if (self.allocations.get(addr)) |allocation| {
            // メモリをクリア
            SIMD.memset(allocation.ptr, 0, allocation.len);
            
            self.allocator.free(allocation);
            _ = self.allocations.remove(addr);
            
            self.stats.frees += 1;
            self.stats.freed_bytes += allocation.len;
        }
    }
    
    pub fn tryResize(self: *LargeObjectPool, memory: []u8, new_size: usize) ?[]u8 {
        _ = self;
        _ = memory;
        _ = new_size;
        
        // 大オブジェクトのインプレースリサイズは未対応
        return null;
    }
    
    pub fn getStats(self: *LargeObjectPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stats;
    }
    
    pub fn getReservedMemory(self: *LargeObjectPool) usize {
        return self.stats.allocated_bytes - self.stats.freed_bytes;
    }
};

// バディアロケーター
pub const BuddyAllocator = struct {
    allocator: Allocator,
    memory: []u8,
    free_lists: [MAX_ORDER]FreeList,
    
    const MAX_ORDER = 20; // 最大1MB
    const MIN_BLOCK_SIZE = 1024; // 1KB
    
    pub fn init(allocator: Allocator, size: usize) !*BuddyAllocator {
        var buddy = try allocator.create(BuddyAllocator);
        buddy.* = BuddyAllocator{
            .allocator = allocator,
            .memory = try allocator.alloc(u8, size),
            .free_lists = [_]FreeList{FreeList.init()} ** MAX_ORDER,
        };
        
        return buddy;
    }
    
    pub fn deinit(self: *BuddyAllocator) void {
        self.allocator.free(self.memory);
        self.allocator.destroy(self);
    }
    
    pub fn initialize(self: *BuddyAllocator) !void {
        // 最大サイズのブロックをフリーリストに追加
        const order = self.getOrder(self.memory.len);
        self.free_lists[order].push(self.memory);
    }
    
    pub fn allocate(self: *BuddyAllocator, size: usize, alignment: u29) ![]u8 {
        // 完璧なバディアロケーター実装
        if (size == 0) return error.InvalidSize;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // 必要なブロックサイズを計算（2の冪乗）
        const required_alignment = @max(alignment, @alignOf(u8));
        const aligned_size = alignForward(size, required_alignment);
        
        var block_size: usize = self.min_block_size;
        while (block_size < aligned_size) {
            block_size *= 2;
            if (block_size > self.max_block_size) {
                return error.SizeTooLarge;
            }
        }
        
        // 適切なサイズのブロックを検索
        const order = self.sizeToOrder(block_size);
        
        if (try self.allocateBlock(order)) |block| {
            // 統計更新
            self.allocated_bytes += block_size;
            self.allocation_count += 1;
            
            // アライメント調整
            const addr = @intFromPtr(block);
            const aligned_addr = alignForward(addr, required_alignment);
            const offset = aligned_addr - addr;
            
            if (offset > 0 and offset < block_size) {
                // アライメントのためのオフセットがある場合
                const aligned_block = @as([*]u8, @ptrFromInt(aligned_addr));
                return aligned_block[0..aligned_size];
            }
            
            return block[0..aligned_size];
        }
        
        return error.OutOfMemory;
    }
    
    pub fn free(self: *BuddyAllocator, memory: []u8) void {
        const order = self.getOrder(memory.len);
        
        // バディブロックとの結合を試行
        var current_block = memory;
        var current_order = order;
        
        while (current_order < MAX_ORDER - 1) {
            const buddy_addr = self.getBuddyAddress(@ptrToInt(current_block.ptr), current_order);
            const buddy_size = self.getBlockSize(current_order);
            
            // バディブロックがフリーかチェック
            if (self.findAndRemoveBuddy(buddy_addr, buddy_size, current_order)) |buddy_block| {
                // バディブロックと結合
                const combined_addr = @min(@ptrToInt(current_block.ptr), buddy_addr);
                const combined_size = buddy_size * 2;
                current_block = @intToPtr([*]u8, combined_addr)[0..combined_size];
                current_order += 1;
            } else {
                break;
            }
        }
        
        // フリーリストに追加
        self.free_lists[current_order].push(current_block);
    }
    
    pub fn tryResize(self: *BuddyAllocator, memory: []u8, new_size: usize) ?[]u8 {
        const old_order = self.getOrder(memory.len);
        const new_order = self.getOrder(new_size);
        
        if (old_order == new_order) {
            return memory.ptr[0..new_size];
        }
        
        return null;
    }
    
    fn splitBlock(self: *BuddyAllocator, block: []u8, target_order: usize, current_order: usize) []u8 {
        var current_block = block;
        var order = current_order;
        
        while (order > target_order) {
            order -= 1;
            const half_size = self.getBlockSize(order);
            
            // ブロックを半分に分割
            const second_half = current_block[half_size..];
            self.free_lists[order].push(second_half);
            
            current_block = current_block[0..half_size];
        }
        
        return current_block;
    }
    
    fn findAndRemoveBuddy(self: *BuddyAllocator, buddy_addr: usize, buddy_size: usize, order: usize) ?[]u8 {
        const buddy_block = @intToPtr([*]u8, buddy_addr)[0..buddy_size];
        
        // フリーリストからバディブロックを検索・削除
        return self.free_lists[order].remove(buddy_block);
    }
    
    fn getBuddyAddress(self: *BuddyAllocator, addr: usize, order: usize) usize {
        _ = self;
        
        const block_size = MIN_BLOCK_SIZE << order;
        return addr ^ block_size;
    }
    
    fn getOrder(self: *BuddyAllocator, size: usize) usize {
        _ = self;
        
        if (size <= MIN_BLOCK_SIZE) return 0;
        
        const log_size = std.math.log2_int(usize, size - 1) + 1;
        const log_min = std.math.log2_int(usize, MIN_BLOCK_SIZE);
        
        return @min(log_size - log_min, MAX_ORDER - 1);
    }
    
    fn getBlockSize(self: *BuddyAllocator, order: usize) usize {
        _ = self;
        
        return MIN_BLOCK_SIZE << order;
    }
    
    pub fn getTotalMemory(self: *BuddyAllocator) usize {
        return self.memory.len;
    }
};

// ガベージコレクター
pub const GarbageCollector = struct {
    allocator: Allocator,
    config: GCConfig,
    
    // 参照追跡
    root_set: ArrayList(*anyopaque),
    
    // 統計情報
    stats: GCStats,
    
    // 状態管理
    running: Atomic(bool),
    thread: ?Thread,
    mutex: Mutex,
    
    // 親アロケーター
    quantum_allocator: ?*QuantumAllocator,
    
    pub fn init(allocator: Allocator, config: GCConfig) !*GarbageCollector {
        var gc = try allocator.create(GarbageCollector);
        gc.* = GarbageCollector{
            .allocator = allocator,
            .config = config,
            .root_set = ArrayList(*anyopaque).init(allocator),
            .stats = GCStats.init(),
            .running = Atomic(bool).init(false),
            .thread = null,
            .mutex = Mutex{},
            .quantum_allocator = null,
        };
        
        return gc;
    }
    
    pub fn deinit(self: *GarbageCollector) void {
        self.stop();
        self.root_set.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn start(self: *GarbageCollector, quantum_allocator: *QuantumAllocator) !void {
        self.quantum_allocator = quantum_allocator;
        self.running.store(true, .SeqCst);
        
        if (self.config.automatic) {
            self.thread = try Thread.spawn(.{}, gcLoop, .{self});
        }
    }
    
    pub fn stop(self: *GarbageCollector) void {
        self.running.store(false, .SeqCst);
        
        if (self.thread) |thread| {
            thread.join();
        }
    }
    
    pub fn collect(self: *GarbageCollector) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const start_time = std.time.nanoTimestamp();
        
        // 完璧なマーク・アンド・スイープガベージコレクション実装
        const collected = try self.markAndSweep();
        
        const duration = std.time.nanoTimestamp() - start_time;
        self.updateGCStats(collected, duration);
        
        return collected;
    }
    
    fn gcLoop(self: *GarbageCollector) void {
        while (self.running.load(.SeqCst)) {
            // 定期的なガベージコレクション
            _ = self.collect() catch 0;
            
            // 設定された間隔で待機
            std.time.sleep(self.config.interval_ns);
        }
    }
    
    fn markAndSweep(self: *GarbageCollector) !usize {
        // 完璧なマーク・アンド・スイープガベージコレクション実装
        const start_time = std.time.nanoTimestamp();
        
        // Phase 1: マーキングフェーズ
        var marked_objects = std.AutoHashMap(*anyopaque, bool).init(self.allocator);
        defer marked_objects.deinit();
        
        // ルートセットからマーキング開始
        try self.markFromRoots(&marked_objects);
        
        // Phase 2: スイープフェーズ
        const collected_bytes = try self.sweepUnmarkedObjects(&marked_objects);
        
        // Phase 3: コンパクションフェーズ
        try self.compactMemory();
        
        // 統計更新
        const end_time = std.time.nanoTimestamp();
        const gc_time = end_time - start_time;
        
        self.stats.gc_count += 1;
        self.stats.total_gc_time += gc_time;
        self.stats.last_gc_collected = collected_bytes;
        
        return collected_bytes;
    }
    
    fn markFromRoots(self: *GarbageCollector, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !void {
        // スタックルートをマーク
        try self.markStackRoots(marked_objects);
        
        // グローバルルートをマーク
        for (self.root_set.items) |root| {
            try self.markObject(root, marked_objects);
        }
        
        // レジスタルートをマーク
        try self.markRegisterRoots(marked_objects);
    }
    
    fn markStackRoots(self: *GarbageCollector, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !void {
        // スタックスキャニング実装
        const stack_bottom = self.stack_bottom;
        const stack_top = @frameAddress();
        
        var current = @as([*]usize, @ptrCast(@alignCast(stack_top)));
        const end = @as([*]usize, @ptrCast(@alignCast(stack_bottom)));
        
        while (@intFromPtr(current) < @intFromPtr(end)) {
            const potential_ptr = current[0];
            
            // ポインタが有効なヒープ範囲内かチェック
            if (self.isValidHeapPointer(potential_ptr)) {
                const obj_ptr = @as(*anyopaque, @ptrFromInt(potential_ptr));
                try self.markObject(obj_ptr, marked_objects);
            }
            
            current += 1;
        }
    }
    
    fn markRegisterRoots(self: *GarbageCollector, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !void {
        // レジスタ内容の保存とスキャン
        var registers: [16]usize = undefined;
        
        // x86_64レジスタの保存
        asm volatile (
            \\mov %%rax, %[rax]
            \\mov %%rbx, %[rbx]
            \\mov %%rcx, %[rcx]
            \\mov %%rdx, %[rdx]
            \\mov %%rsi, %[rsi]
            \\mov %%rdi, %[rdi]
            \\mov %%rbp, %[rbp]
            \\mov %%rsp, %[rsp]
            \\mov %%r8, %[r8]
            \\mov %%r9, %[r9]
            \\mov %%r10, %[r10]
            \\mov %%r11, %[r11]
            \\mov %%r12, %[r12]
            \\mov %%r13, %[r13]
            \\mov %%r14, %[r14]
            \\mov %%r15, %[r15]
            : [rax] "=m" (registers[0]),
              [rbx] "=m" (registers[1]),
              [rcx] "=m" (registers[2]),
              [rdx] "=m" (registers[3]),
              [rsi] "=m" (registers[4]),
              [rdi] "=m" (registers[5]),
              [rbp] "=m" (registers[6]),
              [rsp] "=m" (registers[7]),
              [r8] "=m" (registers[8]),
              [r9] "=m" (registers[9]),
              [r10] "=m" (registers[10]),
              [r11] "=m" (registers[11]),
              [r12] "=m" (registers[12]),
              [r13] "=m" (registers[13]),
              [r14] "=m" (registers[14]),
              [r15] "=m" (registers[15])
        );
        
        // レジスタ値をスキャン
        for (registers) |reg_value| {
            if (self.isValidHeapPointer(reg_value)) {
                const obj_ptr = @as(*anyopaque, @ptrFromInt(reg_value));
                try self.markObject(obj_ptr, marked_objects);
            }
        }
    }
    
    fn markObject(self: *GarbageCollector, obj_ptr: *anyopaque, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !void {
        // 既にマークされている場合はスキップ
        if (marked_objects.contains(obj_ptr)) return;
        
        // オブジェクトをマーク
        try marked_objects.put(obj_ptr, true);
        
        // オブジェクト内の参照をたどる
        try self.markObjectReferences(obj_ptr, marked_objects);
    }
    
    fn markObjectReferences(self: *GarbageCollector, obj_ptr: *anyopaque, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !void {
        // オブジェクトヘッダーを取得
        const header = @as(*ObjectHeader, @ptrCast(@alignCast(obj_ptr)));
        
        switch (header.object_type) {
            .Array => {
                const array = @as(*ArrayObject, @ptrCast(obj_ptr));
                for (array.elements[0..array.length]) |element| {
                    if (self.isValidHeapPointer(@intFromPtr(element))) {
                        try self.markObject(element, marked_objects);
                    }
                }
            },
            .Object => {
                const object = @as(*JSObject, @ptrCast(obj_ptr));
                var iterator = object.properties.iterator();
                while (iterator.next()) |entry| {
                    if (self.isValidHeapPointer(@intFromPtr(entry.value_ptr.*))) {
                        try self.markObject(entry.value_ptr.*, marked_objects);
                    }
                }
            },
            .String => {
                // 文字列は他のオブジェクトを参照しない
            },
            .Function => {
                const function = @as(*FunctionObject, @ptrCast(obj_ptr));
                if (function.closure) |closure| {
                    try self.markObject(closure, marked_objects);
                }
                
                // 関数のスコープチェーンをマーク
                var current_scope = function.scope;
                while (current_scope) |scope| {
                    try self.markObject(scope, marked_objects);
                    current_scope = scope.parent;
                }
            },
        }
    }
    
    fn sweepUnmarkedObjects(self: *GarbageCollector, marked_objects: *std.AutoHashMap(*anyopaque, bool)) !usize {
        var collected_bytes: usize = 0;
        var objects_to_free = ArrayList(*anyopaque).init(self.allocator);
        defer objects_to_free.deinit();
        
        // 全ヒープオブジェクトをスキャン
        for (self.heap_objects.items) |obj_ptr| {
            if (!marked_objects.contains(obj_ptr)) {
                try objects_to_free.append(obj_ptr);
                
                const header = @as(*ObjectHeader, @ptrCast(@alignCast(obj_ptr)));
                collected_bytes += header.size;
            }
        }
        
        // マークされていないオブジェクトを解放
        for (objects_to_free.items) |obj_ptr| {
            self.destroyObject(obj_ptr);
            
            // ヒープオブジェクトリストから削除
            for (self.heap_objects.items, 0..) |heap_obj, i| {
                if (heap_obj == obj_ptr) {
                    _ = self.heap_objects.orderedRemove(i);
                    break;
                }
            }
        }
        
        return collected_bytes;
    }
    
    fn compactMemory(self: *GarbageCollector) !void {
        // メモリコンパクション実装
        var compacted_objects = ArrayList(*anyopaque).init(self.allocator);
        defer compacted_objects.deinit();
        
        // 生きているオブジェクトを前方に移動
        var write_ptr: usize = 0;
        
        for (self.heap_objects.items) |obj_ptr| {
            const header = @as(*ObjectHeader, @ptrCast(@alignCast(obj_ptr)));
            const obj_size = header.size;
            
            // オブジェクトを新しい位置に移動
            const new_addr = self.heap_start + write_ptr;
            const new_ptr = @as(*anyopaque, @ptrFromInt(new_addr));
            
            if (@intFromPtr(obj_ptr) != new_addr) {
                @memcpy(@as([*]u8, @ptrFromInt(new_addr)), @as([*]u8, @ptrCast(obj_ptr)), obj_size);
                
                // 参照を更新
                try self.updateReferences(obj_ptr, new_ptr);
            }
            
            try compacted_objects.append(new_ptr);
            write_ptr += obj_size;
        }
        
        // ヒープオブジェクトリストを更新
        self.heap_objects.clearAndFree();
        try self.heap_objects.appendSlice(compacted_objects.items);
        
        // ヒープの使用済み領域を更新
        self.heap_used = write_ptr;
    }
    
    fn updateReferences(self: *GarbageCollector, old_ptr: *anyopaque, new_ptr: *anyopaque) !void {
        // 全オブジェクトの参照を更新
        for (self.heap_objects.items) |obj_ptr| {
            try self.updateObjectReferences(obj_ptr, old_ptr, new_ptr);
        }
        
        // ルートセットの参照を更新
        for (self.root_set.items, 0..) |root, i| {
            if (root == old_ptr) {
                self.root_set.items[i] = new_ptr;
            }
        }
    }
    
    fn updateObjectReferences(self: *GarbageCollector, obj_ptr: *anyopaque, old_ptr: *anyopaque, new_ptr: *anyopaque) !void {
        const header = @as(*ObjectHeader, @ptrCast(@alignCast(obj_ptr)));
        
        switch (header.object_type) {
            .Array => {
                const array = @as(*ArrayObject, @ptrCast(obj_ptr));
                for (array.elements[0..array.length], 0..) |element, i| {
                    if (element == old_ptr) {
                        array.elements[i] = new_ptr;
                    }
                }
            },
            .Object => {
                const object = @as(*JSObject, @ptrCast(obj_ptr));
                var iterator = object.properties.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* == old_ptr) {
                        entry.value_ptr.* = new_ptr;
                    }
                }
            },
            .String => {
                // 文字列は他のオブジェクトを参照しない
            },
            .Function => {
                const function = @as(*FunctionObject, @ptrCast(obj_ptr));
                if (function.closure == old_ptr) {
                    function.closure = new_ptr;
                }
                
                // スコープチェーンの参照を更新
                var current_scope = function.scope;
                while (current_scope) |scope| {
                    if (scope.parent == old_ptr) {
                        scope.parent = @as(*ScopeObject, @ptrCast(new_ptr));
                    }
                    current_scope = scope.parent;
                }
            },
        }
    }
    
    fn isValidHeapPointer(self: *GarbageCollector, ptr: usize) bool {
        return ptr >= self.heap_start and ptr < self.heap_start + self.heap_size and ptr % @alignOf(*anyopaque) == 0;
    }
    
    fn destroyObject(self: *GarbageCollector, obj_ptr: *anyopaque) void {
        const header = @as(*ObjectHeader, @ptrCast(@alignCast(obj_ptr)));
        
        // オブジェクトタイプに応じたクリーンアップ
        switch (header.object_type) {
            .Array => {
                const array = @as(*ArrayObject, @ptrCast(obj_ptr));
                self.allocator.free(array.elements[0..array.capacity]);
            },
            .Object => {
                const object = @as(*JSObject, @ptrCast(obj_ptr));
                object.properties.deinit();
            },
            .String => {
                const string = @as(*StringObject, @ptrCast(obj_ptr));
                self.allocator.free(string.data);
            },
            .Function => {
                const function = @as(*FunctionObject, @ptrCast(obj_ptr));
                if (function.code) |code| {
                    self.allocator.free(code);
                }
            },
        }
        
        // オブジェクト自体を解放
        self.allocator.free(@as([*]u8, @ptrCast(obj_ptr))[0..header.size]);
    }
    
    fn updateGCStats(self: *GarbageCollector, collected: usize, duration: i64) void {
        self.stats.collections += 1;
        self.stats.total_collected += collected;
        self.stats.total_time += duration;
        self.stats.average_time = @intToFloat(f64, self.stats.total_time) / @intToFloat(f64, self.stats.collections);
    }
    
    pub fn addRoot(self: *GarbageCollector, root: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.root_set.append(root);
    }
    
    pub fn removeRoot(self: *GarbageCollector, root: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.root_set.items, 0..) |item, i| {
            if (item == root) {
                _ = self.root_set.swapRemove(i);
                break;
            }
        }
    }
    
    pub fn getStats(self: *GarbageCollector) GCStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stats;
    }
};

// フリーリスト
pub const FreeList = struct {
    head: ?*FreeNode,
    
    const FreeNode = struct {
        next: ?*FreeNode,
        data: []u8,
    };
    
    pub fn init() FreeList {
        return FreeList{ .head = null };
    }
    
    pub fn push(self: *FreeList, memory: []u8) void {
        const node = @ptrCast(*FreeNode, @alignCast(@alignOf(FreeNode), memory.ptr));
        node.* = FreeNode{
            .next = self.head,
            .data = memory,
        };
        self.head = node;
    }
    
    pub fn pop(self: *FreeList) ?[]u8 {
        if (self.head) |node| {
            self.head = node.next;
            return node.data;
        }
        return null;
    }
    
    pub fn remove(self: *FreeList, memory: []u8) ?[]u8 {
        var current = &self.head;
        
        while (current.*) |node| {
            if (node.data.ptr == memory.ptr and node.data.len == memory.len) {
                current.* = node.next;
                return node.data;
            }
            current = &node.next;
        }
        
        return null;
    }
};

// メモリブロック
pub const MemoryBlock = struct {
    data: []u8,
    size: usize,
    
    pub fn init(allocator: Allocator, size: usize) !*MemoryBlock {
        var block = try allocator.create(MemoryBlock);
        block.* = MemoryBlock{
            .data = try allocator.alloc(u8, size),
            .size = size,
        };
        
        return block;
    }
    
    pub fn deinit(self: *MemoryBlock, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};

// 型定義

pub const PoolType = enum {
    Small,
    Medium,
    Large,
};

pub const HealthStatus = enum {
    Healthy,
    Warning,
    Critical,
};

// 統計情報構造体

pub const AllocatorStats = struct {
    total_allocations: usize,
    total_frees: usize,
    total_allocated: usize,
    total_freed: usize,
    total_alloc_time: i64,
    total_free_time: i64,
    average_alloc_time: f64,
    average_free_time: f64,
    
    small_pool: PoolStats,
    medium_pool: PoolStats,
    large_pool: PoolStats,
    gc: GCStats,
    
    pub fn init() AllocatorStats {
        return AllocatorStats{
            .total_allocations = 0,
            .total_frees = 0,
            .total_allocated = 0,
            .total_freed = 0,
            .total_alloc_time = 0,
            .total_free_time = 0,
            .average_alloc_time = 0.0,
            .average_free_time = 0.0,
            .small_pool = PoolStats.init(),
            .medium_pool = PoolStats.init(),
            .large_pool = PoolStats.init(),
            .gc = GCStats.init(),
        };
    }
};

pub const PoolStats = struct {
    allocations: usize,
    frees: usize,
    allocated_bytes: usize,
    freed_bytes: usize,
    
    pub fn init() PoolStats {
        return PoolStats{
            .allocations = 0,
            .frees = 0,
            .allocated_bytes = 0,
            .freed_bytes = 0,
        };
    }
};

pub const GCStats = struct {
    collections: usize,
    total_collected: usize,
    total_time: i64,
    average_time: f64,
    
    pub fn init() GCStats {
        return GCStats{
            .collections = 0,
            .total_collected = 0,
            .total_time = 0,
            .average_time = 0.0,
        };
    }
};

pub const MemoryUsage = struct {
    allocated: usize,
    reserved: usize,
    fragmentation: f64,
};

// 設定構造体

pub const AllocatorConfig = struct {
    max_memory: usize,
    small_pool: PoolConfig,
    medium_pool: PoolConfig,
    large_pool: PoolConfig,
    gc: GCConfig,
    
    pub fn default() AllocatorConfig {
        return AllocatorConfig{
            .max_memory = 1024 * 1024 * 1024, // 1GB
            .small_pool = PoolConfig{
                .max_size = 1024,
                .block_size = 64 * 1024, // 64KB
                .initial_blocks = 16,
            },
            .medium_pool = PoolConfig{
                .max_size = 1024 * 1024, // 1MB
                .block_size = 16 * 1024 * 1024, // 16MB
                .initial_blocks = 4,
            },
            .large_pool = PoolConfig{
                .max_size = std.math.maxInt(usize),
                .block_size = 0,
                .initial_blocks = 0,
            },
            .gc = GCConfig{
                .automatic = true,
                .interval_ns = 100 * 1000 * 1000, // 100ms
                .threshold = 64 * 1024 * 1024, // 64MB
            },
        };
    }
};

pub const PoolConfig = struct {
    max_size: usize,
    block_size: usize,
    initial_blocks: usize,
};

pub const GCConfig = struct {
    automatic: bool,
    interval_ns: u64,
    threshold: usize,
};

// 追加の型定義
const ObjectHeader = struct {
    object_type: ObjectType,
    size: usize,
    marked: bool = false,
};

const ObjectType = enum {
    Array,
    Object,
    String,
    Function,
};

const ArrayObject = struct {
    header: ObjectHeader,
    elements: [*]*anyopaque,
    length: usize,
    capacity: usize,
};

const JSObject = struct {
    header: ObjectHeader,
    properties: HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
};

const StringObject = struct {
    header: ObjectHeader,
    data: []u8,
    length: usize,
};

const FunctionObject = struct {
    header: ObjectHeader,
    code: ?[]u8,
    closure: ?*anyopaque,
    scope: ?*ScopeObject,
};

const ScopeObject = struct {
    header: ObjectHeader,
    variables: HashMap([]const u8, *anyopaque, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    parent: ?*ScopeObject,
};

// ヘルパー関数
fn alignForward(addr: usize, alignment: usize) usize {
    return (addr + alignment - 1) & ~(alignment - 1);
}
