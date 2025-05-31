const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

/// SIMD最適化ベクトル演算ライブラリ
/// CPUのSIMD命令セットを活用して高速なベクトル演算を提供します
pub const VectorOps = struct {
    /// 利用可能なSIMD命令セット
    pub const SimdInstructionSet = enum {
        None,   // SIMD命令なし
        SSE2,   // x86 SSE2
        AVX,    // x86 AVX
        AVX2,   // x86 AVX2
        AVX512, // x86 AVX512
        NEON,   // ARM NEON
        WASM,   // WebAssembly SIMD
        Auto,   // 自動検出
    };
    
    /// 命令セット自動検出
    pub fn detectInstructionSet() SimdInstructionSet {
        const features = std.Target.current.cpu.featureSet;
        if (features.has(.avx512f)) return .AVX512;
        if (features.has(.avx2)) return .AVX2;
        if (features.has(.avx)) return .AVX;
        if (features.has(.sse4_1)) return .SSE41;
        if (features.has(.sse2)) return .SSE2;
        if (features.has(.neon)) return .NEON;
        if (features.has(.simd128)) return .WASM;
        return .Scalar;
    }

    // WebAssembly SIMDサポートの検出
    fn detectWasmSimd() bool {
        // WebAssembly環境でのSIMDサポート検出
        // 実行時の環境によって異なる方法が必要
        const wasm_features = @import("std").Target.wasm.Feature;
        
        // ビルドターゲットのfeature情報に基づいて判断
        if (std.Target.current.cpu.arch == .wasm32 or std.Target.current.cpu.arch == .wasm64) {
            const has_simd128 = std.Target.wasm.featureSetHas(
                std.Target.current.cpu.features,
                .simd128
            );
            return has_simd128;
        }
        
        return false;
    }
    
    /// ベクトル加算
    /// a + b を計算
    pub fn vectorAdd(comptime T: type, a: []const T, b: []const T, result: []T) void {
        if (vectorAdd_SIMD(T, a, b, result)) {
            return;
        }
        
        // フォールバック実装
        for (a, 0..) |val, i| {
            if (i >= result.len) break;
            result[i] = val + b[i];
        }
    }
    
    /// SIMDベクトル加算
    fn vectorAdd_SIMD(comptime T: type, a: []const T, b: []const T, result: []T) bool {
        const inst_set = detectInstructionSet();
        const len = @min(a.len, b.len, result.len);
        
        switch (inst_set) {
            .AVX, .AVX2, .AVX512 => {
                if (T == f32) {
                    return vectorAdd_AVX_f32(a, b, result);
                } else if (T == f64) {
                    return vectorAdd_AVX_f64(a, b, result);
                } else if (T == i32 or T == u32) {
                    return vectorAdd_AVX_i32(a, b, result);
                }
            },
            .SSE2 => {
                if (T == f32) {
                    return vectorAdd_SSE_f32(a, b, result);
                } else if (T == f64) {
                    return vectorAdd_SSE_f64(a, b, result);
                }
            },
            .NEON => {
                if (T == f32) {
                    return vectorAdd_NEON_f32(a, b, result);
                }
            },
            else => {},
        }
        
        return false;
    }
    
    /// AVX float32ベクトル加算
    fn vectorAdd_AVX_f32(a: []const f32, b: []const f32, result: []f32) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(8, f32); // 256ビット = 8 x f32
        
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            const va: Vector = a[i..][0..8].*;
            const vb: Vector = b[i..][0..8].*;
            const vr = va + vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
        
        return true;
    }
    
    /// AVX float64ベクトル加算
    fn vectorAdd_AVX_f64(a: []const f64, b: []const f64, result: []f64) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(4, f64); // 256ビット = 4 x f64
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            const vr = va + vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
        
        return true;
    }
    
    /// AVX int32ベクトル加算
    fn vectorAdd_AVX_i32(a: []const anytype, b: []const anytype, result: []anytype) bool {
        const len = @min(a.len, b.len, result.len);
        const T = @TypeOf(a[0]);
        const Vector = @Vector(8, T); // 256ビット = 8 x i32/u32
        
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            const va: Vector = a[i..][0..8].*;
            const vb: Vector = b[i..][0..8].*;
            const vr = va +% vb; // ラップアラウンド加算
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] +% b[i]; // ラップアラウンド加算
        }
        
        return true;
    }
    
    /// SSE float32ベクトル加算
    fn vectorAdd_SSE_f32(a: []const f32, b: []const f32, result: []f32) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(4, f32); // 128ビット = 4 x f32
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            const vr = va + vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
        
        return true;
    }
    
    /// SSE float64ベクトル加算
    fn vectorAdd_SSE_f64(a: []const f64, b: []const f64, result: []f64) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(2, f64); // 128ビット = 2 x f64
        
        var i: usize = 0;
        while (i + 2 <= len) : (i += 2) {
            const va: Vector = a[i..][0..2].*;
            const vb: Vector = b[i..][0..2].*;
            const vr = va + vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
        
        return true;
    }
    
    /// ARM NEON float32ベクトル加算
    fn vectorAdd_NEON_f32(a: []const f32, b: []const f32, result: []f32) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(4, f32); // 128ビット = 4 x f32
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            const vr = va + vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
        
        return true;
    }
    
    /// ベクトル減算
    /// a - b を計算
    pub fn vectorSub(comptime T: type, a: []const T, b: []const T, result: []T) void {
        if (vectorSub_SIMD(T, a, b, result)) {
            return;
        }
        
        // フォールバック実装
        for (a, 0..) |val, i| {
            if (i >= result.len) break;
            result[i] = val - b[i];
        }
    }
    
    /// SIMDベクトル減算
    fn vectorSub_SIMD(comptime T: type, a: []const T, b: []const T, result: []T) bool {
        const inst_set = detectInstructionSet();
        const len = @min(a.len, b.len, result.len);
        
        switch (inst_set) {
            .AVX, .AVX2, .AVX512 => {
                if (T == f32) {
                    return vectorSub_AVX_f32(a, b, result);
                } else if (T == f64) {
                    return vectorSub_AVX_f64(a, b, result);
                }
            },
            .SSE2 => {
                if (T == f32) {
                    return vectorSub_SSE_f32(a, b, result);
                } else if (T == f64) {
                    return vectorSub_SSE_f64(a, b, result);
                }
            },
            else => {},
        }
        
        return false;
    }
    
    /// AVX float32ベクトル減算
    fn vectorSub_AVX_f32(a: []const f32, b: []const f32, result: []f32) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(8, f32);
        
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            const va: Vector = a[i..][0..8].*;
            const vb: Vector = b[i..][0..8].*;
            const vr = va - vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] - b[i];
        }
        
        return true;
    }
    
    /// AVX float64ベクトル減算
    fn vectorSub_AVX_f64(a: []const f64, b: []const f64, result: []f64) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(4, f64);
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            const vr = va - vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] - b[i];
        }
        
        return true;
    }
    
    /// SSE float32ベクトル減算
    fn vectorSub_SSE_f32(a: []const f32, b: []const f32, result: []f32) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(4, f32);
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            const vr = va - vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] - b[i];
        }
        
        return true;
    }
    
    /// SSE float64ベクトル減算
    fn vectorSub_SSE_f64(a: []const f64, b: []const f64, result: []f64) bool {
        const len = @min(a.len, b.len, result.len);
        const Vector = @Vector(2, f64);
        
        var i: usize = 0;
        while (i + 2 <= len) : (i += 2) {
            const va: Vector = a[i..][0..2].*;
            const vb: Vector = b[i..][0..2].*;
            const vr = va - vb;
            @as(*Vector, @ptrCast(result[i..].ptr)).* = vr;
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            result[i] = a[i] - b[i];
        }
        
        return true;
    }
    
    /// ドット積（内積）計算
    pub fn dotProduct(comptime T: type, a: []const T, b: []const T) T {
        if (a.len == 0 or b.len == 0) return 0;
        
        const result = dotProduct_SIMD(T, a, b);
        if (result) |val| {
            return val;
        }
        
        // フォールバック実装
        const len = @min(a.len, b.len);
        var sum: T = 0;
        for (a[0..len], b[0..len]) |va, vb| {
            sum += va * vb;
        }
        return sum;
    }
    
    /// SIMDドット積（内積）計算
    fn dotProduct_SIMD(comptime T: type, a: []const T, b: []const T) ?T {
        const inst_set = detectInstructionSet();
        const len = @min(a.len, b.len);
        
        switch (inst_set) {
            .AVX, .AVX2, .AVX512 => {
                if (T == f32) {
                    return dotProduct_AVX_f32(a[0..len], b[0..len]);
                } else if (T == f64) {
                    return dotProduct_AVX_f64(a[0..len], b[0..len]);
                }
            },
            .SSE2 => {
                if (T == f32) {
                    return dotProduct_SSE_f32(a[0..len], b[0..len]);
                } else if (T == f64) {
                    return dotProduct_SSE_f64(a[0..len], b[0..len]);
                }
            },
            else => {},
        }
        
        return null;
    }
    
    /// AVX float32ドット積計算
    fn dotProduct_AVX_f32(a: []const f32, b: []const f32) f32 {
        const len = a.len;
        var sum: f32 = 0.0;
        
        const Vector = @Vector(8, f32);
        var acc: Vector = @splat(0.0);
        
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            const va: Vector = a[i..][0..8].*;
            const vb: Vector = b[i..][0..8].*;
            acc += va * vb;
        }
        
        // 水平加算
        var hsum: f32 = 0.0;
        for (0..8) |j| {
            hsum += acc[j];
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            sum += a[i] * b[i];
        }
        
        return hsum + sum;
    }
    
    /// AVX float64ドット積計算
    fn dotProduct_AVX_f64(a: []const f64, b: []const f64) f64 {
        const len = a.len;
        var sum: f64 = 0.0;
        
        const Vector = @Vector(4, f64);
        var acc: Vector = @splat(0.0);
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            acc += va * vb;
        }
        
        // 水平加算
        var hsum: f64 = 0.0;
        for (0..4) |j| {
            hsum += acc[j];
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            sum += a[i] * b[i];
        }
        
        return hsum + sum;
    }
    
    /// SSE float32ドット積計算
    fn dotProduct_SSE_f32(a: []const f32, b: []const f32) f32 {
        const len = a.len;
        var sum: f32 = 0.0;
        
        const Vector = @Vector(4, f32);
        var acc: Vector = @splat(0.0);
        
        var i: usize = 0;
        while (i + 4 <= len) : (i += 4) {
            const va: Vector = a[i..][0..4].*;
            const vb: Vector = b[i..][0..4].*;
            acc += va * vb;
        }
        
        // 水平加算
        var hsum: f32 = 0.0;
        for (0..4) |j| {
            hsum += acc[j];
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            sum += a[i] * b[i];
        }
        
        return hsum + sum;
    }
    
    /// SSE float64ドット積計算
    fn dotProduct_SSE_f64(a: []const f64, b: []const f64) f64 {
        const len = a.len;
        var sum: f64 = 0.0;
        
        const Vector = @Vector(2, f64);
        var acc: Vector = @splat(0.0);
        
        var i: usize = 0;
        while (i + 2 <= len) : (i += 2) {
            const va: Vector = a[i..][0..2].*;
            const vb: Vector = b[i..][0..2].*;
            acc += va * vb;
        }
        
        // 水平加算
        var hsum: f64 = 0.0;
        for (0..2) |j| {
            hsum += acc[j];
        }
        
        // 残りの要素を処理
        while (i < len) : (i += 1) {
            sum += a[i] * b[i];
        }
        
        return hsum + sum;
    }
};

// テスト
test "ベクトル加算" {
    const testing = std.testing;
    
    var a = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var b = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };
    var result = [_]f32{0} ** 8;
    
    VectorOps.vectorAdd(f32, &a, &b, &result);
    
    try testing.expectApproxEqAbs(result[0], 1.1, 0.001);
    try testing.expectApproxEqAbs(result[7], 8.8, 0.001);
}

test "ベクトル減算" {
    const testing = std.testing;
    
    var a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var b = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var result = [_]f32{0} ** 4;
    
    VectorOps.vectorSub(f32, &a, &b, &result);
    
    try testing.expectApproxEqAbs(result[0], 0.9, 0.001);
    try testing.expectApproxEqAbs(result[3], 3.6, 0.001);
}

test "ドット積" {
    const testing = std.testing;
    
    var a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var b = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    
    const result = VectorOps.dotProduct(f32, &a, &b);
    
    // 1*5 + 2*6 + 3*7 + 4*8 = 5 + 12 + 21 + 32 = 70
    try testing.expectApproxEqAbs(result, 70.0, 0.001);
} 