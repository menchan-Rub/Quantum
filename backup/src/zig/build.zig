const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "quantum_core",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // C API exports
    const c_exports = b.addStaticLibrary(.{
        .name = "quantum_core_c_api",
        .root_source_file = .{ .path = "src/c_api.zig" },
        .target = target,
        .optimize = optimize,
    });
    c_exports.linkLibC();
    b.installArtifact(c_exports);
} 