const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "quantum_zig_core",
        .root_source_file = b.path("main.zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .version = std.SemanticVersion.parse("0.0.1") catch unreachable,
    });

    lib.linkLibC();

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("main.zig/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
} 