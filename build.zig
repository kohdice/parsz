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

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/grep.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("parsz", mod);
    const grep_example = b.addExecutable(.{
        .name = "parsz-example-grep",
        .root_module = example_mod,
    });

    const compile_error_runner = b.addExecutable(.{
        .name = "compile-error-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/compile_errors/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_compile_error_tests = b.addRunArtifact(compile_error_runner);
    run_compile_error_tests.addArg(b.graph.zig_exe);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&grep_example.step);
    test_step.dependOn(&run_compile_error_tests.step);
}
