const std = @import("std");

const ExternalTestCase = struct {
    path: []const u8,
};

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

    const external_tests = [_]ExternalTestCase{
        .{ .path = "test/schema_declaration_test.zig" },
        .{ .path = "test/parsed_type_test.zig" },
    };

    for (external_tests) |case| {
        addExternalTest(b, test_step, mod, target, optimize, case);
    }
}

fn addExternalTest(
    b: *std.Build,
    parent_step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    case: ExternalTestCase,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(case.path),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("parsz", mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    parent_step.dependOn(&run_tests.step);
}
