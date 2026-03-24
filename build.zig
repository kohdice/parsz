const std = @import("std");

const ComptimeHarness = struct {
    b: *std.Build,
    step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

    const external_tests = [_][]const u8{
        "test/schema_declaration_test.zig",
        "test/parsed_type_test.zig",
    };

    for (external_tests) |path| {
        addExternalTest(b, test_step, mod, target, optimize, path);
    }

    const comptime_fixtures = [_][]const u8{
        "test/comptime/non_struct_root.zig",
        "test/comptime/tuple_root.zig",
        "test/comptime/non_wrapper_field.zig",
        "test/comptime/unsupported_option_payload.zig",
        "test/comptime/duplicate_long_name.zig",
        "test/comptime/duplicate_short_name.zig",
        "test/comptime/required_after_optional_positional.zig",
        "test/comptime/positional_after_variadic.zig",
        "test/comptime/multiple_subcommands.zig",
        "test/comptime/subcommand_requires_tagged_union.zig",
        "test/comptime/subcommand_payload_must_be_command_struct.zig",
        "test/comptime/reserved_long_name.zig",
        "test/comptime/reserved_subcommand_name.zig",
        "test/comptime/subcommand_version_meta.zig",
        "test/comptime/positional_with_long_name.zig",
    };

    const comptime_test_step = b.step(
        "test-comptime",
        "Run comptime validation tests that expect compile errors",
    );

    const comptime_harness = ComptimeHarness{
        .b = b,
        .step = comptime_test_step,
        .mod = mod,
        .target = target,
        .optimize = optimize,
    };

    for (comptime_fixtures) |path| {
        addComptimeFailureTest(comptime_harness, path);
    }

    test_step.dependOn(comptime_test_step);
}

fn addExternalTest(
    b: *std.Build,
    parent_step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path(path),
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

fn addComptimeFailureTest(h: ComptimeHarness, path: []const u8) void {
    const expected = readExpectedErrorFromFixture(h.b, path);

    const test_mod = h.b.createModule(.{
        .root_source_file = h.b.path(path),
        .target = h.target,
        .optimize = h.optimize,
    });
    test_mod.addImport("parsz", h.mod);

    const run_tests = h.b.addObject(.{
        .name = std.fs.path.stem(path),
        .root_module = test_mod,
    });
    run_tests.expect_errors = .{ .contains = expected };
    h.step.dependOn(&run_tests.step);
}

fn readExpectedErrorFromFixture(b: *std.Build, path: []const u8) []const u8 {
    const fixture_path = b.pathFromRoot(path);
    const contents = std.fs.cwd().readFileAlloc(b.allocator, fixture_path, 64 * 1024) catch |err| {
        std.debug.panic("failed to read fixture '{s}': {s}", .{
            path,
            @errorName(err),
        });
    };

    const first_line_end = std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len;
    const first_line = std.mem.trimRight(u8, contents[0..first_line_end], "\r");
    const prefix = "// expected-error: ";

    if (!std.mem.startsWith(u8, first_line, prefix)) {
        std.debug.panic("fixture '{s}' must start with '{s}'", .{
            path,
            prefix,
        });
    }

    return first_line[prefix.len..];
}
