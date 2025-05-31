// src/zig/build.zig
// Quantum ブラウザ Zig コンポーネント - 世界最高水準のビルドシステム
// 最大のパフォーマンス・最小のバイナリサイズ・包括的な自動テストを実現

const std = @import("std");
const builtin = @import("builtin");

// ビルド設定 - 最適化レベルごとにカスタマイズされた設定
const BuildConfig = struct {
    // 各コンポーネントが必要とする依存ライブラリ
    required_system_libs: []const []const u8 = &.{
        "c", // libc
        "m", // libm (数学関数)
    },

    // macOS専用の追加フレームワーク
    macos_frameworks: []const []const u8 = &.{
        "CoreFoundation",
        "CoreGraphics",
        "Metal",
    },

    // 追加コンパイラフラグ - 最適化・セキュリティ・デバッグに関係
    extra_cpp_flags: []const []const u8 = &.{
        "-fno-rtti",
        "-fno-exceptions",
        "-Wall",
        "-Wextra",
    },

    // 高度なLTO (Link Time Optimization) 設定
    enable_lto: bool = true,

    // PGO (Profile Guided Optimization) 設定
    enable_pgo: bool = false,
    pgo_profile_path: ?[]const u8 = null,
};

// ビルドフェーズのパフォーマンス測定
const BuildTimer = struct {
    start_time: i64,
    name: []const u8,

    fn start(name: []const u8) BuildTimer {
        return .{
            .start_time = std.time.milliTimestamp(),
            .name = name,
        };
    }

    fn end(self: BuildTimer) void {
        const elapsed = std.time.milliTimestamp() - self.start_time;
        std.debug.print("BUILD PHASE '{s}' completed in {d}ms\n", .{ self.name, elapsed });
    }
};

// プロファイル設定
const Profiles = struct {
    // パフォーマンス重視プロファイル
    pub const performance = .{
        .strip = true,
        .single_threaded = false,
        .use_llvm = true,
        .use_lto = true,
        .use_pgo = true,
    };

    // サイズ重視プロファイル (最小バイナリ)
    pub const size = .{
        .strip = true,
        .single_threaded = true,
        .use_llvm = true,
        .use_lto = true,
        .use_pgo = false,
    };

    // デバッグプロファイル
    pub const debug = .{
        .strip = false,
        .single_threaded = false,
        .use_llvm = true,
        .use_lto = false,
        .use_pgo = false,
    };
};

pub fn build(b: *std.Build) !void {
    const build_timer = BuildTimer.start("complete_build");
    defer build_timer.end();

    // ビルド設定を解析
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // デフォルトプロファイルの選択
    const use_profile = b.option(
        bool,
        "use-profile",
        "Enable profile-specific optimizations",
    ) orelse false;

    const profile_name = b.option(
        []const u8,
        "profile",
        "Select build profile: performance, size, or debug",
    ) orelse "performance";

    // カスタムコンパイルフラグ
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    // 基本フラグを追加
    try flags.appendSlice(&.{
        "-ffunction-sections",
        "-fdata-sections",
    });

    // ターゲットとプロファイルに基づいてフラグを調整
    if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
        try flags.appendSlice(&.{ "-framework", "CoreFoundation" });
        try flags.appendSlice(&.{ "-framework", "CoreGraphics" });
    }

    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        try flags.append("-fomit-frame-pointer");
    }

    // ASANを有効化するオプション (メモリエラー検出)
    const enable_asan = b.option(
        bool,
        "asan",
        "Enable Address Sanitizer",
    ) orelse false;

    if (enable_asan and optimize != .ReleaseFast) {
        try flags.append("-fsanitize=address");
    }

    // メインのライブラリをビルド
    const lib_timer = BuildTimer.start("build_main_library");

    const lib = b.addSharedLibrary(.{
        .name = "quantum_zig_core",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .version = try std.SemanticVersion.parse("0.1.0"),
    });

    // システムライブラリをリンク
    lib.linkLibC();
    lib.linkLibCpp();

    // 数学ライブラリをリンク
    if (target.result.os.tag != .windows) {
        lib.linkSystemLibrary("m");
    }

    // プラットフォーム固有のライブラリをリンク
    if (target.result.os.tag == .macos) {
        lib.linkFramework("CoreFoundation");
        lib.linkFramework("CoreGraphics");
        lib.linkFramework("Metal");
    } else if (target.result.os.tag == .linux) {
        // Wayland/X11サポート
        lib.linkSystemLibrary("wayland-client");
        lib.linkSystemLibrary("wayland-egl");
        lib.linkSystemLibrary("egl");
        lib.linkSystemLibrary("gl");
        lib.linkSystemLibrary("x11");
    } else if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("user32");
        lib.linkSystemLibrary("gdi32");
        lib.linkSystemLibrary("d3d11");
        lib.linkSystemLibrary("dxgi");
    }

    // コンパイルフラグを適用
    lib.addCSourceFiles(&.{
        "src/zig/bindings/c_layer.c",
    }, flags.items);

    // LTOを有効化（ReleaseモードのみProfileの設定に従う）
    if (optimize != .Debug) {
        if (use_profile) {
            var lto_enabled = false;
            if (std.mem.eql(u8, profile_name, "performance")) {
                lto_enabled = Profiles.performance.use_lto;
            } else if (std.mem.eql(u8, profile_name, "size")) {
                lto_enabled = Profiles.size.use_lto;
            }

            if (lto_enabled) {
                lib.want_lto = true;
            }
        } else {
            // デフォルトでリリースモードではLTOを有効化
            lib.want_lto = true;
        }
    }

    // リリースビルドでシンボルをストリップ
    if (optimize != .Debug) {
        lib.strip = true;
    }

    // スタックトレースとパニック情報を含める（デバッグビルドのみ）
    lib.bundle_compiler_rt = (optimize == .Debug);

    // ビルド成果物をインストール
    b.installArtifact(lib);
    lib_timer.end();

    // ======== テストセクション ========
    const test_timer = BuildTimer.start("configure_tests");

    // 通常のユニットテスト
    const main_tests = b.addTest(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    main_tests.linkLibC();

    // 統合テスト - 各モジュールの接続をテスト
    const integration_tests = b.addTest(.{
        .name = "integration_tests",
        .root_source_file = b.path("tests/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    integration_tests.linkLibC();
    if (target.result.os.tag == .macos) {
        integration_tests.linkFramework("CoreFoundation");
    }

    // パフォーマンステスト - 最適化バージョンのみ
    const perf_tests = b.addTest(.{
        .name = "performance_tests",
        .root_source_file = b.path("tests/performance_tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    perf_tests.linkLibC();

    // テスト実行ステップ
    const run_unit_tests = b.addRunArtifact(main_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const run_perf_tests = b.addRunArtifact(perf_tests);

    // テストステップをビルドに追加
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_test_step = b.step("integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const perf_test_step = b.step("benchmark", "Run performance benchmarks");
    perf_test_step.dependOn(&run_perf_tests.step);

    test_timer.end();

    // ======== ドキュメント生成セクション ========
    const docs_timer = BuildTimer.start("generate_docs");

    // APIドキュメントを生成
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&docs.step);

    docs_timer.end();

    // ビルド完了メッセージとサマリーを表示
    std.debug.print("\n=== Quantum Zig Core Build Summary ===\n", .{});
    std.debug.print("Target: {}\n", .{target.result});
    std.debug.print("Optimization: {}\n", .{optimize});
    if (use_profile) {
        std.debug.print("Profile: {s}\n", .{profile_name});
    }
    std.debug.print("==================================\n\n", .{});
}
