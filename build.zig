const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const parsz_mod = b.addModule("parsz", .{
        .root_source_file = b.path("src/parsz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = parsz_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const schema_declaration_test_mod = b.createModule(.{
        .root_source_file = b.path("test/schema_declaration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    schema_declaration_test_mod.addImport("parsz", parsz_mod);

    const schema_declaration_tests = b.addTest(.{
        .root_module = schema_declaration_test_mod,
    });

    const run_schema_declaration_tests = b.addRunArtifact(schema_declaration_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_schema_declaration_tests.step);
}
