const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("parsz", .{
        .root_source_file = b.path("src/parsz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // --- examples ---
    const examples_step = b.step("examples", "Build examples");

    const exe = b.addExecutable(.{
        .name = "sample",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/sample.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parsz", .module = mod },
            },
        }),
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install_exe.step);
}
