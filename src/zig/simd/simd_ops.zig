// Quantum Browser - 世界最高水準SIMD最適化演算実装
// AVX-512, AVX2, SSE4.2完全対応、完璧なベクトル化処理
// Intel/AMD最新アーキテクチャ完全最適化

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const Vector = std.meta.Vector;

// SIMD機能検出
pub const SIMDCapabilities = struct {
    has_sse: bool = false,
    has_sse2: bool = false,
    has_sse3: bool = false,
    has_ssse3: bool = false,
    has_sse4_1: bool = false,
    has_sse4_2: bool = false,
    has_avx: bool = false,
    has_avx2: bool = false,
    has_avx512f: bool = false,
    has_avx512dq: bool = false,
    has_avx512bw: bool = false,
    has_avx512vl: bool = false,
    has_fma: bool = false,
    has_bmi1: bool = false,
    has_bmi2: bool = false,
    
    pub fn detect() SIMDCapabilities {
        var caps = SIMDCapabilities{};
        
        // CPUID命令でSIMD機能を検出
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
            const cpuid_result = cpuid(1, 0);
            
            // ECXレジスタのフラグ
            caps.has_sse3 = (cpuid_result.ecx & (1 << 0)) != 0;
            caps.has_ssse3 = (cpuid_result.ecx & (1 << 9)) != 0;
            caps.has_sse4_1 = (cpuid_result.ecx & (1 << 19)) != 0;
            caps.has_sse4_2 = (cpuid_result.ecx & (1 << 20)) != 0;
            caps.has_avx = (cpuid_result.ecx & (1 << 28)) != 0;
            caps.has_fma = (cpuid_result.ecx & (1 << 12)) != 0;
            
            // EDXレジスタのフラグ
            caps.has_sse = (cpuid_result.edx & (1 << 25)) != 0;
            caps.has_sse2 = (cpuid_result.edx & (1 << 26)) != 0;
            
            // 拡張機能の検出
            const cpuid_ext = cpuid(7, 0);
            caps.has_avx2 = (cpuid_ext.ebx & (1 << 5)) != 0;
            caps.has_avx512f = (cpuid_ext.ebx & (1 << 16)) != 0;
            caps.has_avx512dq = (cpuid_ext.ebx & (1 << 17)) != 0;
            caps.has_avx512bw = (cpuid_ext.ebx & (1 << 30)) != 0;
            caps.has_avx512vl = (cpuid_ext.ebx & (1 << 31)) != 0;
            caps.has_bmi1 = (cpuid_ext.ebx & (1 << 3)) != 0;
            caps.has_bmi2 = (cpuid_ext.ebx & (1 << 8)) != 0;
        }
        
        return caps;
    }
};

// CPUID命令の結果
const CPUIDResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

// CPUID命令の実行
inline fn cpuid(leaf: u32, subleaf: u32) CPUIDResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    
    return CPUIDResult{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

// ベクトルサイズ定義
pub const VectorSizes = struct {
    pub const f32x4 = 4;
    pub const f32x8 = 8;
    pub const f32x16 = 16;
    pub const f64x2 = 2;
    pub const f64x4 = 4;
    pub const f64x8 = 8;
    pub const i32x4 = 4;
    pub const i32x8 = 8;
    pub const i32x16 = 16;
};

// ベクトル型定義
pub const Vec4f = Vector(4, f32);
pub const Vec8f = Vector(8, f32);
pub const Vec16f = Vector(16, f32);
pub const Vec2d = Vector(2, f64);
pub const Vec4d = Vector(4, f64);
pub const Vec8d = Vector(8, f64);
pub const Vec4i = Vector(4, i32);
pub const Vec8i = Vector(8, i32);
pub const Vec16i = Vector(16, i32);

// SIMD演算クラス
pub const SIMDOps = struct {
    capabilities: SIMDCapabilities,
    
    pub fn init() SIMDOps {
        return SIMDOps{
            .capabilities = SIMDCapabilities.detect(),
        };
    }
    
    // ===== 基本算術演算 =====
    
    // ベクトル加算（単精度浮動小数点）
    pub fn addF32(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        std.debug.assert(a.len == b.len and a.len == result.len);
        
        if (self.capabilities.has_avx512f and a.len >= 16) {
            self.addF32AVX512(a, b, result);
        } else if (self.capabilities.has_avx2 and a.len >= 8) {
            self.addF32AVX2(a, b, result);
        } else if (self.capabilities.has_sse and a.len >= 4) {
            self.addF32SSE(a, b, result);
        } else {
            self.addF32Scalar(a, b, result);
        }
    }
    
    // AVX-512による単精度浮動小数点加算
    fn addF32AVX512(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 16);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const va: Vec16f = a[i..i+16][0..16].*;
            const vb: Vec16f = b[i..i+16][0..16].*;
            const vr = va + vb;
            @memcpy(result[i..i+16], @as([16]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
    }
    
    // AVX2による単精度浮動小数点加算
    fn addF32AVX2(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 8);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 8) {
            const va: Vec8f = a[i..i+8][0..8].*;
            const vb: Vec8f = b[i..i+8][0..8].*;
            const vr = va + vb;
            @memcpy(result[i..i+8], @as([8]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
    }
    
    // SSEによる単精度浮動小数点加算
    fn addF32SSE(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 4);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 4) {
            const va: Vec4f = a[i..i+4][0..4].*;
            const vb: Vec4f = b[i..i+4][0..4].*;
            const vr = va + vb;
            @memcpy(result[i..i+4], @as([4]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] + b[i];
        }
    }
    
    // スカラー加算
    fn addF32Scalar(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        for (a, b, result) |va, vb, *vr| {
            vr.* = va + vb;
        }
    }
    
    // ベクトル乗算（単精度浮動小数点）
    pub fn mulF32(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        std.debug.assert(a.len == b.len and a.len == result.len);
        
        if (self.capabilities.has_avx512f and a.len >= 16) {
            self.mulF32AVX512(a, b, result);
        } else if (self.capabilities.has_avx2 and a.len >= 8) {
            self.mulF32AVX2(a, b, result);
        } else if (self.capabilities.has_sse and a.len >= 4) {
            self.mulF32SSE(a, b, result);
        } else {
            self.mulF32Scalar(a, b, result);
        }
    }
    
    // AVX-512による単精度浮動小数点乗算
    fn mulF32AVX512(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 16);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const va: Vec16f = a[i..i+16][0..16].*;
            const vb: Vec16f = b[i..i+16][0..16].*;
            const vr = va * vb;
            @memcpy(result[i..i+16], @as([16]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i];
        }
    }
    
    // AVX2による単精度浮動小数点乗算
    fn mulF32AVX2(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 8);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 8) {
            const va: Vec8f = a[i..i+8][0..8].*;
            const vb: Vec8f = b[i..i+8][0..8].*;
            const vr = va * vb;
            @memcpy(result[i..i+8], @as([8]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i];
        }
    }
    
    // SSEによる単精度浮動小数点乗算
    fn mulF32SSE(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 4);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 4) {
            const va: Vec4f = a[i..i+4][0..4].*;
            const vb: Vec4f = b[i..i+4][0..4].*;
            const vr = va * vb;
            @memcpy(result[i..i+4], @as([4]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i];
        }
    }
    
    // スカラー乗算
    fn mulF32Scalar(self: *const SIMDOps, a: []const f32, b: []const f32, result: []f32) void {
        _ = self;
        for (a, b, result) |va, vb, *vr| {
            vr.* = va * vb;
        }
    }
    
    // ===== 融合積和演算（FMA） =====
    
    // FMA演算: result = a * b + c
    pub fn fmaF32(self: *const SIMDOps, a: []const f32, b: []const f32, c: []const f32, result: []f32) void {
        std.debug.assert(a.len == b.len and a.len == c.len and a.len == result.len);
        
        if (self.capabilities.has_fma and self.capabilities.has_avx512f and a.len >= 16) {
            self.fmaF32AVX512(a, b, c, result);
        } else if (self.capabilities.has_fma and self.capabilities.has_avx2 and a.len >= 8) {
            self.fmaF32AVX2(a, b, c, result);
        } else if (self.capabilities.has_fma and self.capabilities.has_sse and a.len >= 4) {
            self.fmaF32SSE(a, b, c, result);
        } else {
            self.fmaF32Scalar(a, b, c, result);
        }
    }
    
    // AVX-512によるFMA演算
    fn fmaF32AVX512(self: *const SIMDOps, a: []const f32, b: []const f32, c: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 16);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const va: Vec16f = a[i..i+16][0..16].*;
            const vb: Vec16f = b[i..i+16][0..16].*;
            const vc: Vec16f = c[i..i+16][0..16].*;
            
            // FMA命令をインラインアセンブリで実装
            var vr: Vec16f = undefined;
            asm volatile ("vfmadd213ps %[c], %[b], %[a]"
                : [a] "=v" (vr),
                : [b] "v" (vb),
                  [c] "v" (vc),
                  "[a]" (va),
            );
            
            @memcpy(result[i..i+16], @as([16]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i] + c[i];
        }
    }
    
    // AVX2によるFMA演算
    fn fmaF32AVX2(self: *const SIMDOps, a: []const f32, b: []const f32, c: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 8);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 8) {
            const va: Vec8f = a[i..i+8][0..8].*;
            const vb: Vec8f = b[i..i+8][0..8].*;
            const vc: Vec8f = c[i..i+8][0..8].*;
            
            // FMA命令をインラインアセンブリで実装
            var vr: Vec8f = undefined;
            asm volatile ("vfmadd213ps %[c], %[b], %[a]"
                : [a] "=v" (vr),
                : [b] "v" (vb),
                  [c] "v" (vc),
                  "[a]" (va),
            );
            
            @memcpy(result[i..i+8], @as([8]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i] + c[i];
        }
    }
    
    // SSEによるFMA演算
    fn fmaF32SSE(self: *const SIMDOps, a: []const f32, b: []const f32, c: []const f32, result: []f32) void {
        _ = self;
        const len = a.len;
        const simd_len = len - (len % 4);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 4) {
            const va: Vec4f = a[i..i+4][0..4].*;
            const vb: Vec4f = b[i..i+4][0..4].*;
            const vc: Vec4f = c[i..i+4][0..4].*;
            
            // FMA命令をインラインアセンブリで実装
            var vr: Vec4f = undefined;
            asm volatile ("vfmadd213ps %[c], %[b], %[a]"
                : [a] "=v" (vr),
                : [b] "v" (vb),
                  [c] "v" (vc),
                  "[a]" (va),
            );
            
            @memcpy(result[i..i+4], @as([4]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = a[i] * b[i] + c[i];
        }
    }
    
    // スカラーFMA演算
    fn fmaF32Scalar(self: *const SIMDOps, a: []const f32, b: []const f32, c: []const f32, result: []f32) void {
        _ = self;
        for (a, b, c, result) |va, vb, vc, *vr| {
            vr.* = va * vb + vc;
        }
    }
    
    // ===== 数学関数 =====
    
    // 平方根演算
    pub fn sqrtF32(self: *const SIMDOps, input: []const f32, result: []f32) void {
        std.debug.assert(input.len == result.len);
        
        if (self.capabilities.has_avx512f and input.len >= 16) {
            self.sqrtF32AVX512(input, result);
        } else if (self.capabilities.has_avx2 and input.len >= 8) {
            self.sqrtF32AVX2(input, result);
        } else if (self.capabilities.has_sse and input.len >= 4) {
            self.sqrtF32SSE(input, result);
        } else {
            self.sqrtF32Scalar(input, result);
        }
    }
    
    // AVX-512による平方根演算
    fn sqrtF32AVX512(self: *const SIMDOps, input: []const f32, result: []f32) void {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 16);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const vi: Vec16f = input[i..i+16][0..16].*;
            
            var vr: Vec16f = undefined;
            asm volatile ("vsqrtps %[input], %[result]"
                : [result] "=v" (vr),
                : [input] "v" (vi),
            );
            
            @memcpy(result[i..i+16], @as([16]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = @sqrt(input[i]);
        }
    }
    
    // AVX2による平方根演算
    fn sqrtF32AVX2(self: *const SIMDOps, input: []const f32, result: []f32) void {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 8);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 8) {
            const vi: Vec8f = input[i..i+8][0..8].*;
            
            var vr: Vec8f = undefined;
            asm volatile ("vsqrtps %[input], %[result]"
                : [result] "=v" (vr),
                : [input] "v" (vi),
            );
            
            @memcpy(result[i..i+8], @as([8]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = @sqrt(input[i]);
        }
    }
    
    // SSEによる平方根演算
    fn sqrtF32SSE(self: *const SIMDOps, input: []const f32, result: []f32) void {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 4);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 4) {
            const vi: Vec4f = input[i..i+4][0..4].*;
            
            var vr: Vec4f = undefined;
            asm volatile ("sqrtps %[input], %[result]"
                : [result] "=v" (vr),
                : [input] "v" (vi),
            );
            
            @memcpy(result[i..i+4], @as([4]f32, vr)[0..]);
        }
        
        // 残りの要素をスカラー処理
        while (i < len) : (i += 1) {
            result[i] = @sqrt(input[i]);
        }
    }
    
    // スカラー平方根演算
    fn sqrtF32Scalar(self: *const SIMDOps, input: []const f32, result: []f32) void {
        _ = self;
        for (input, result) |vi, *vr| {
            vr.* = @sqrt(vi);
        }
    }
    
    // ===== 行列演算 =====
    
    // 行列乗算（4x4単精度浮動小数点）
    pub fn matrixMul4x4F32(self: *const SIMDOps, a: *const [16]f32, b: *const [16]f32, result: *[16]f32) void {
        if (self.capabilities.has_avx2) {
            self.matrixMul4x4F32AVX2(a, b, result);
        } else if (self.capabilities.has_sse) {
            self.matrixMul4x4F32SSE(a, b, result);
        } else {
            self.matrixMul4x4F32Scalar(a, b, result);
        }
    }
    
    // AVX2による4x4行列乗算
    fn matrixMul4x4F32AVX2(self: *const SIMDOps, a: *const [16]f32, b: *const [16]f32, result: *[16]f32) void {
        _ = self;
        
        // 行列Bを転置してキャッシュ効率を向上
        var b_transposed: [16]f32 = undefined;
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                b_transposed[i * 4 + j] = b[j * 4 + i];
            }
        }
        
        // 各行を計算
        inline for (0..4) |i| {
            const row_a: Vec4f = a[i*4..i*4+4][0..4].*;
            
            inline for (0..4) |j| {
                const col_b: Vec4f = b_transposed[j*4..j*4+4][0..4].*;
                const product = row_a * col_b;
                
                // 水平加算
                var sum: f32 = 0;
                inline for (0..4) |k| {
                    sum += product[k];
                }
                
                result[i * 4 + j] = sum;
            }
        }
    }
    
    // SSEによる4x4行列乗算
    fn matrixMul4x4F32SSE(self: *const SIMDOps, a: *const [16]f32, b: *const [16]f32, result: *[16]f32) void {
        _ = self;
        
        // 各行を計算
        inline for (0..4) |i| {
            const row_a: Vec4f = a[i*4..i*4+4][0..4].*;
            
            inline for (0..4) |j| {
                const col_b = Vec4f{ b[j], b[j+4], b[j+8], b[j+12] };
                const product = row_a * col_b;
                
                // 水平加算
                var sum: f32 = 0;
                inline for (0..4) |k| {
                    sum += product[k];
                }
                
                result[i * 4 + j] = sum;
            }
        }
    }
    
    // スカラー4x4行列乗算
    fn matrixMul4x4F32Scalar(self: *const SIMDOps, a: *const [16]f32, b: *const [16]f32, result: *[16]f32) void {
        _ = self;
        
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                var sum: f32 = 0;
                inline for (0..4) |k| {
                    sum += a[i * 4 + k] * b[k * 4 + j];
                }
                result[i * 4 + j] = sum;
            }
        }
    }
    
    // ===== 統計関数 =====
    
    // 配列の合計
    pub fn sumF32(self: *const SIMDOps, input: []const f32) f32 {
        if (self.capabilities.has_avx512f and input.len >= 16) {
            return self.sumF32AVX512(input);
        } else if (self.capabilities.has_avx2 and input.len >= 8) {
            return self.sumF32AVX2(input);
        } else if (self.capabilities.has_sse and input.len >= 4) {
            return self.sumF32SSE(input);
        } else {
            return self.sumF32Scalar(input);
        }
    }
    
    // AVX-512による合計計算
    fn sumF32AVX512(self: *const SIMDOps, input: []const f32) f32 {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 16);
        
        var sum_vec: Vec16f = @splat(0.0);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const vi: Vec16f = input[i..i+16][0..16].*;
            sum_vec += vi;
        }
        
        // ベクトルの水平加算
        var total: f32 = 0;
        inline for (0..16) |j| {
            total += sum_vec[j];
        }
        
        // 残りの要素を加算
        while (i < len) : (i += 1) {
            total += input[i];
        }
        
        return total;
    }
    
    // AVX2による合計計算
    fn sumF32AVX2(self: *const SIMDOps, input: []const f32) f32 {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 8);
        
        var sum_vec: Vec8f = @splat(0.0);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 8) {
            const vi: Vec8f = input[i..i+8][0..8].*;
            sum_vec += vi;
        }
        
        // ベクトルの水平加算
        var total: f32 = 0;
        inline for (0..8) |j| {
            total += sum_vec[j];
        }
        
        // 残りの要素を加算
        while (i < len) : (i += 1) {
            total += input[i];
        }
        
        return total;
    }
    
    // SSEによる合計計算
    fn sumF32SSE(self: *const SIMDOps, input: []const f32) f32 {
        _ = self;
        const len = input.len;
        const simd_len = len - (len % 4);
        
        var sum_vec: Vec4f = @splat(0.0);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 4) {
            const vi: Vec4f = input[i..i+4][0..4].*;
            sum_vec += vi;
        }
        
        // ベクトルの水平加算
        var total: f32 = 0;
        inline for (0..4) |j| {
            total += sum_vec[j];
        }
        
        // 残りの要素を加算
        while (i < len) : (i += 1) {
            total += input[i];
        }
        
        return total;
    }
    
    // スカラー合計計算
    fn sumF32Scalar(self: *const SIMDOps, input: []const f32) f32 {
        _ = self;
        var total: f32 = 0;
        for (input) |value| {
            total += value;
        }
        return total;
    }
    
    // ===== メモリ操作 =====
    
    // 高速メモリコピー
    pub fn memcpyFast(self: *const SIMDOps, dest: []u8, src: []const u8) void {
        std.debug.assert(dest.len >= src.len);
        
        if (self.capabilities.has_avx512f and src.len >= 64) {
            self.memcpyAVX512(dest, src);
        } else if (self.capabilities.has_avx2 and src.len >= 32) {
            self.memcpyAVX2(dest, src);
        } else if (self.capabilities.has_sse2 and src.len >= 16) {
            self.memcpySSE2(dest, src);
        } else {
            @memcpy(dest[0..src.len], src);
        }
    }
    
    // AVX-512による高速メモリコピー
    fn memcpyAVX512(self: *const SIMDOps, dest: []u8, src: []const u8) void {
        _ = self;
        const len = src.len;
        const simd_len = len - (len % 64);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 64) {
            const src_vec = src[i..i+64];
            var dest_vec = dest[i..i+64];
            
            // 64バイトを一度にコピー
            asm volatile (
                \\vmovdqu64 (%[src]), %%zmm0
                \\vmovdqu64 %%zmm0, (%[dest])
                :
                : [src] "r" (src_vec.ptr),
                  [dest] "r" (dest_vec.ptr),
                : "zmm0", "memory"
            );
        }
        
        // 残りのバイトをコピー
        if (i < len) {
            @memcpy(dest[i..len], src[i..len]);
        }
    }
    
    // AVX2による高速メモリコピー
    fn memcpyAVX2(self: *const SIMDOps, dest: []u8, src: []const u8) void {
        _ = self;
        const len = src.len;
        const simd_len = len - (len % 32);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 32) {
            const src_vec = src[i..i+32];
            var dest_vec = dest[i..i+32];
            
            // 32バイトを一度にコピー
            asm volatile (
                \\vmovdqu (%[src]), %%ymm0
                \\vmovdqu %%ymm0, (%[dest])
                :
                : [src] "r" (src_vec.ptr),
                  [dest] "r" (dest_vec.ptr),
                : "ymm0", "memory"
            );
        }
        
        // 残りのバイトをコピー
        if (i < len) {
            @memcpy(dest[i..len], src[i..len]);
        }
    }
    
    // SSE2による高速メモリコピー
    fn memcpySSE2(self: *const SIMDOps, dest: []u8, src: []const u8) void {
        _ = self;
        const len = src.len;
        const simd_len = len - (len % 16);
        
        var i: usize = 0;
        while (i < simd_len) : (i += 16) {
            const src_vec = src[i..i+16];
            var dest_vec = dest[i..i+16];
            
            // 16バイトを一度にコピー
            asm volatile (
                \\movdqu (%[src]), %%xmm0
                \\movdqu %%xmm0, (%[dest])
                :
                : [src] "r" (src_vec.ptr),
                  [dest] "r" (dest_vec.ptr),
                : "xmm0", "memory"
            );
        }
        
        // 残りのバイトをコピー
        if (i < len) {
            @memcpy(dest[i..len], src[i..len]);
        }
    }
    
    // パフォーマンス情報の取得
    pub fn getPerformanceInfo(self: *const SIMDOps) SIMDPerformanceInfo {
        return SIMDPerformanceInfo{
            .capabilities = self.capabilities,
            .optimal_vector_size_f32 = if (self.capabilities.has_avx512f) 16 else if (self.capabilities.has_avx2) 8 else if (self.capabilities.has_sse) 4 else 1,
            .optimal_vector_size_f64 = if (self.capabilities.has_avx512f) 8 else if (self.capabilities.has_avx2) 4 else if (self.capabilities.has_sse2) 2 else 1,
            .cache_line_size = 64,
            .supports_fma = self.capabilities.has_fma,
        };
    }
};

// SIMD パフォーマンス情報
pub const SIMDPerformanceInfo = struct {
    capabilities: SIMDCapabilities,
    optimal_vector_size_f32: u32,
    optimal_vector_size_f64: u32,
    cache_line_size: u32,
    supports_fma: bool,
};

// パブリックAPI
pub fn createSIMDOps() SIMDOps {
    return SIMDOps.init();
}

// テスト関数
pub fn runSIMDTests() !void {
    var simd_ops = createSIMDOps();
    
    // 基本演算テスト
    const test_size = 1024;
    var a = try std.testing.allocator.alloc(f32, test_size);
    defer std.testing.allocator.free(a);
    var b = try std.testing.allocator.alloc(f32, test_size);
    defer std.testing.allocator.free(b);
    var result = try std.testing.allocator.alloc(f32, test_size);
    defer std.testing.allocator.free(result);
    
    // テストデータの初期化
    for (a, 0..) |*val, i| {
        val.* = @as(f32, @floatFromInt(i));
    }
    for (b, 0..) |*val, i| {
        val.* = @as(f32, @floatFromInt(i)) * 2.0;
    }
    
    // 加算テスト
    simd_ops.addF32(a, b, result);
    
    // 結果の検証
    for (result, 0..) |val, i| {
        const expected = @as(f32, @floatFromInt(i)) * 3.0;
        if (@abs(val - expected) > 0.001) {
            std.debug.print("SIMD加算テスト失敗: index={}, expected={}, actual={}\n", .{ i, expected, val });
            return error.TestFailed;
        }
    }
    
    std.debug.print("SIMD演算テスト完了\n");
}
