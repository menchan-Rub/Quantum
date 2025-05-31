const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const arena_mod = @import("arena_allocator.zig");
const QuantumArenaAllocator = arena_mod.QuantumArenaAllocator;

/// 高性能メモリマネージャ
/// 異なるタイプのメモリアロケーションパターン向けに最適化された
/// 複数のアロケータを管理します
pub const MemoryManager = struct {
    /// アロケータ種別
    pub const AllocatorType = enum {
        /// 標準GPAアロケータ - 一般的な用途向け
        Standard,
        /// アリーナアロケータ - 短期間のバーストアロケーション向け
        Arena,
        /// オブジェクトプール - 頻繁に生成・破棄される均一サイズのオブジェクト向け
        Pool,
        /// 一時バッファ - スクラッチメモリとして使用
        Temp,
    };

    // 内部アロケータ
    backing_allocator: Allocator,
    standard_allocator: Allocator,
    arena_allocator: *QuantumArenaAllocator,
    temp_allocator: Allocator,

    // メモリ統計
    total_allocated: std.atomic.Atomic(usize),
    peak_usage: std.atomic.Atomic(usize),
    allocation_count: std.atomic.Atomic(usize),

    // メモリプロファイリング設定
    profiling_enabled: bool,
    allocation_trace: ?*AllocationTracer,

    /// メモリマネージャを初期化
    pub fn init(backing_allocator: Allocator) !*MemoryManager {
        const self = try backing_allocator.create(MemoryManager);
        errdefer backing_allocator.destroy(self);

        // アリーナアロケータの初期化
        const arena = try backing_allocator.create(QuantumArenaAllocator);
        arena.* = QuantumArenaAllocator.init(backing_allocator, .Balanced);

        self.* = .{
            .backing_allocator = backing_allocator,
            .standard_allocator = backing_allocator,
            .arena_allocator = arena,
            .temp_allocator = backing_allocator,
            .total_allocated = std.atomic.Atomic(usize).init(0),
            .peak_usage = std.atomic.Atomic(usize).init(0),
            .allocation_count = std.atomic.Atomic(usize).init(0),
            .profiling_enabled = false,
            .allocation_trace = null,
        };

        return self;
    }

    /// リソース解放
    pub fn deinit(self: *MemoryManager) void {
        if (self.profiling_enabled and self.allocation_trace != null) {
            self.allocation_trace.?.deinit();
            self.backing_allocator.destroy(self.allocation_trace.?);
        }

        self.arena_allocator.deinit();
        self.backing_allocator.destroy(self.arena_allocator);
        self.backing_allocator.destroy(self);
    }

    /// 指定タイプのアロケータを取得
    pub fn getAllocator(self: *MemoryManager, allocator_type: AllocatorType) Allocator {
        return switch (allocator_type) {
            .Standard => self.standard_allocator,
            .Arena => self.arena_allocator.allocator(),
            .Pool => self.standard_allocator, // 将来的に実装
            .Temp => self.temp_allocator,
        };
    }

    /// メモリ使用状況レポート
    pub fn reportMemoryUsage(self: *MemoryManager) MemoryUsageReport {
        return .{
            .total_allocated = self.total_allocated.load(.Acquire),
            .peak_usage = self.peak_usage.load(.Acquire),
            .allocation_count = self.allocation_count.load(.Acquire),
            .arena_stats = if (self.arena_allocator != null) self.arena_allocator.getStats() else null,
        };
    }

    /// メモリプロファイリングを有効化
    pub fn enableProfiling(self: *MemoryManager) !void {
        if (self.profiling_enabled) return;

        self.profiling_enabled = true;
        const tracer = try self.backing_allocator.create(AllocationTracer);
        tracer.* = try AllocationTracer.init(self.backing_allocator);
        self.allocation_trace = tracer;

        // プロファイリング用ラッパーアロケータで標準アロケータを置き換え
        self.standard_allocator = self.createProfilingAllocator();
    }

    /// プロファイリング用アロケータを作成
    fn createProfilingAllocator(self: *MemoryManager) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = profilingAlloc,
                .resize = profilingResize,
                .free = profilingFree,
            },
        };
    }

    /// プロファイリング付きメモリ確保関数
    fn profilingAlloc(ctx: *anyopaque, len: usize, log2_ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *MemoryManager = @ptrCast(ctx);
        const result = self.backing_allocator.rawAlloc(len, log2_ptr_align, ret_addr);

        if (result != null) {
            // 統計を更新
            _ = self.total_allocated.fetchAdd(len, .Release);
            _ = self.allocation_count.fetchAdd(1, .Release);
            
            const current_total = self.total_allocated.load(.Acquire);
            var expected_peak = self.peak_usage.load(.Acquire);
            while (current_total > expected_peak) {
                _ = self.peak_usage.compareAndSwap(expected_peak, current_total, .SeqCst, .SeqCst);
                expected_peak = self.peak_usage.load(.Acquire);
            }

            // アロケーション情報を記録
            if (self.allocation_trace) |tracer| {
                tracer.trackAllocation(result.?, len, ret_addr);
            }
        }

        return result;
    }

    /// プロファイリング付きメモリリサイズ関数
    fn profilingResize(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *MemoryManager = @ptrCast(ctx);
        
        // サイズ変更前に統計を更新
        if (new_len > buf.len) {
            _ = self.total_allocated.fetchAdd(new_len - buf.len, .Release);
            
            const current_total = self.total_allocated.load(.Acquire);
            var expected_peak = self.peak_usage.load(.Acquire);
            while (current_total > expected_peak) {
                _ = self.peak_usage.compareAndSwap(expected_peak, current_total, .SeqCst, .SeqCst);
                expected_peak = self.peak_usage.load(.Acquire);
            }
        } else if (new_len < buf.len) {
            _ = self.total_allocated.fetchSub(buf.len - new_len, .Release);
        }

        // アロケーション情報を更新
        if (self.allocation_trace) |tracer| {
            tracer.updateAllocation(buf.ptr, buf.len, new_len, ret_addr);
        }

        return self.backing_allocator.rawResize(buf, log2_buf_align, new_len, ret_addr);
    }

    /// プロファイリング付きメモリ解放関数
    fn profilingFree(ctx: *anyopaque, buf: []u8, log2_buf_align: u8, ret_addr: usize) void {
        const self: *MemoryManager = @ptrCast(ctx);
        
        // 統計を更新
        _ = self.total_allocated.fetchSub(buf.len, .Release);
        
        // アロケーション情報を記録
        if (self.allocation_trace) |tracer| {
            tracer.trackDeallocation(buf.ptr, ret_addr);
        }

        self.backing_allocator.rawFree(buf, log2_buf_align, ret_addr);
    }

    /// メモリリーク検出
    pub fn detectLeaks(self: *MemoryManager) ?LeakReport {
        if (!self.profiling_enabled or self.allocation_trace == null) {
            return null;
        }

        return self.allocation_trace.?.generateLeakReport();
    }

    /// 一時アロケータをリセット
    pub fn resetTempAllocator(self: *MemoryManager) void {
        // 一時アロケータが実装されていれば、そのリセット操作を実行
    }

    /// アリーナアロケータをリセット
    pub fn resetArenaAllocator(self: *MemoryManager) void {
        self.arena_allocator.reset();
    }
};

/// メモリ使用状況レポート
pub const MemoryUsageReport = struct {
    total_allocated: usize,
    peak_usage: usize,
    allocation_count: usize,
    arena_stats: ?QuantumArenaAllocator.Stats,
};

/// メモリリークレポート
pub const LeakReport = struct {
    leak_count: usize,
    leaked_bytes: usize,
    leaks: []LeakInfo,

    pub const LeakInfo = struct {
        address: *anyopaque,
        size: usize,
        allocation_trace: ?[]usize,
    };
};

/// アロケーショントレーサー - メモリリーク検出とプロファイリング用
pub const AllocationTracer = struct {
    allocator: Allocator,
    allocations: std.AutoHashMap(*anyopaque, AllocationInfo),
    mutex: std.Thread.Mutex,

    pub const AllocationInfo = struct {
        size: usize,
        stack_trace: ?[]usize,
        timestamp: i64,
    };

    pub fn init(allocator: Allocator) !AllocationTracer {
        return AllocationTracer{
            .allocator = allocator,
            .allocations = std.AutoHashMap(*anyopaque, AllocationInfo).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *AllocationTracer) void {
        // スタックトレース情報の解放
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.stack_trace) |trace| {
                self.allocator.free(trace);
            }
        }
        self.allocations.deinit();
    }

    pub fn trackAllocation(self: *AllocationTracer, ptr: [*]u8, size: usize, ret_addr: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // 現在のスタックトレースを取得
        var addresses: [128]usize = undefined;
        const trace_len = std.debug.captureStackTrace(ret_addr, &addresses);
        var trace: ?[]usize = null;
        
        if (trace_len > 0) {
            trace = self.allocator.dupe(usize, addresses[0..trace_len]) catch null;
        }

        // アロケーション情報を記録
        self.allocations.put(@ptrCast(ptr), .{
            .size = size,
            .stack_trace = trace,
            .timestamp = std.time.milliTimestamp(),
        }) catch {
            // エラー処理 - メモリ不足の可能性
            if (trace) |t| self.allocator.free(t);
        };
    }

    pub fn trackDeallocation(self: *AllocationTracer, ptr: *anyopaque, ret_addr: usize) void {
        _ = ret_addr; // 未使用
        self.mutex.lock();
        defer self.mutex.unlock();

        // アロケーション情報を削除
        if (self.allocations.fetchRemove(ptr)) |kv| {
            if (kv.value.stack_trace) |trace| {
                self.allocator.free(trace);
            }
        }
    }

    pub fn updateAllocation(self: *AllocationTracer, ptr: *anyopaque, old_size: usize, new_size: usize, ret_addr: usize) void {
        _ = old_size; // 未使用
        self.mutex.lock();
        defer self.mutex.unlock();

        // 既存のエントリを取得
        if (self.allocations.getEntry(ptr)) |entry| {
            var info = entry.value_ptr;
            info.size = new_size;

            // 新しいスタックトレースを設定
            if (info.stack_trace) |old_trace| {
                self.allocator.free(old_trace);
            }

            var addresses: [128]usize = undefined;
            const trace_len = std.debug.captureStackTrace(ret_addr, &addresses);
            info.stack_trace = if (trace_len > 0)
                self.allocator.dupe(usize, addresses[0..trace_len]) catch null
            else
                null;
            
            info.timestamp = std.time.milliTimestamp();
        } else {
            // 見つからない場合は新規追加
            self.trackAllocation(@ptrCast(ptr), new_size, ret_addr);
        }
    }

    pub fn generateLeakReport(self: *AllocationTracer) LeakReport {
        self.mutex.lock();
        defer self.mutex.unlock();

        var leaked_bytes: usize = 0;
        const leaks = self.allocator.alloc(LeakReport.LeakInfo, self.allocations.count()) catch
            return .{ .leak_count = self.allocations.count(), .leaked_bytes = 0, .leaks = &[_]LeakReport.LeakInfo{} };

        var i: usize = 0;
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            leaked_bytes += entry.value_ptr.size;
            leaks[i] = .{
                .address = entry.key_ptr.*,
                .size = entry.value_ptr.size,
                .allocation_trace = entry.value_ptr.stack_trace,
            };
            i += 1;
        }

        return .{
            .leak_count = self.allocations.count(),
            .leaked_bytes = leaked_bytes,
            .leaks = leaks,
        };
    }
};

// グローバルメモリマネージャインスタンス
var global_memory_manager: ?*MemoryManager = null;

/// グローバルメモリマネージャを初期化
pub fn initGlobalMemoryManager(backing_allocator: Allocator) !void {
    if (global_memory_manager != null) {
        return;
    }

    global_memory_manager = try MemoryManager.init(backing_allocator);
}

/// グローバルメモリマネージャを取得
pub fn getGlobalMemoryManager() *MemoryManager {
    return global_memory_manager orelse @panic("グローバルメモリマネージャが初期化されていません");
}

/// グローバルメモリマネージャを解放
pub fn deinitGlobalMemoryManager() void {
    if (global_memory_manager) |manager| {
        manager.deinit();
        global_memory_manager = null;
    }
}

/// 標準アロケータを取得（ショートカット）
pub fn getStandardAllocator() Allocator {
    return getGlobalMemoryManager().getAllocator(.Standard);
}

/// アリーナアロケータを取得（ショートカット）
pub fn getArenaAllocator() Allocator {
    return getGlobalMemoryManager().getAllocator(.Arena);
}

/// 一時アロケータを取得（ショートカット）
pub fn getTempAllocator() Allocator {
    return getGlobalMemoryManager().getAllocator(.Temp);
}

/// テスト
test "MemoryManager基本機能" {
    const testing = std.testing;
    const test_allocator = testing.allocator;

    var manager = try MemoryManager.init(test_allocator);
    defer manager.deinit();

    // 標準アロケータのテスト
    const std_allocator = manager.getAllocator(.Standard);
    const memory = try std_allocator.alloc(u8, 1024);
    defer std_allocator.free(memory);

    // メモリ使用状況の確認
    const report = manager.reportMemoryUsage();
    try testing.expect(report.total_allocated >= 1024);
    try testing.expect(report.peak_usage >= 1024);
    try testing.expect(report.allocation_count >= 1);

    // アリーナアロケータのテスト
    const arena_allocator = manager.getAllocator(.Arena);
    const arena_memory = try arena_allocator.alloc(u8, 2048);
    _ = arena_memory;

    // アリーナリセット
    manager.resetArenaAllocator();
}