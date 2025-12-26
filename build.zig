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

    // --- comptime validation tests ---
    const comptime_test_step = b.step("test-comptime", "Run comptime validation tests");

    // Valid definitions (should compile successfully)
    const valid_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/comptime/valid_definitions.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parsz", .module = mod },
            },
        }),
    });
    comptime_test_step.dependOn(&b.addRunArtifact(valid_test).step);

    // Error tests - each expects a specific compile error
    const error_tests = .{
        .{ "test/comptime/invalid_ident.zig", "name must be a valid Zig identifier" },
        .{ "test/comptime/flag_wrong_value_type.zig", "flag must have boolean value_type, got string" },
        .{ "test/comptime/flag_multiple.zig", "flag cannot be multiple" },
        .{ "test/comptime/flag_with_default.zig", "flag cannot have default value" },
        .{ "test/comptime/flag_required.zig", "flag cannot be required" },
        .{ "test/comptime/flag_no_short_long.zig", "flag must have long or short." },
        .{ "test/comptime/option_no_short_long.zig", "option must have long or short." },
        .{ "test/comptime/positional_with_short.zig", "positional cannot have long or short." },
        .{ "test/comptime/required_with_default.zig", "required and default cannot both be set" },
        .{ "test/comptime/multiple_with_default.zig", "multiple cannot have default" },
        .{ "test/comptime/short_dash.zig", "short cannot be '-'" },
        .{ "test/comptime/long_empty.zig", "long must not be empty" },
        .{ "test/comptime/long_invalid_start.zig", "long must start with a letter" },
        .{ "test/comptime/default_invalid_integer.zig", "is not a valid integer" },
        .{ "test/comptime/duplicate_name.zig", "duplicate Arg.name 'foo'" },
        .{ "test/comptime/duplicate_short.zig", "duplicate Arg.short '-x' between 'foo' and 'bar'" },
        .{ "test/comptime/duplicate_long.zig", "duplicate Arg.long '--same' between 'foo' and 'bar'" },
        .{ "test/comptime/positional_after_multiple.zig", "cannot come after a multiple positional argument" },
    };

    inline for (error_tests) |test_case| {
        const err_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_case[0]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "parsz", .module = mod },
                },
            }),
        });
        err_test.expect_errors = .{ .contains = test_case[1] };
        comptime_test_step.dependOn(&err_test.step);
    }
}
