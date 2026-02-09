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
        .root_module = createClientModule(b, mod, target, optimize, "examples/sample.zig"),
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install_exe.step);

    // --- comptime validation tests ---
    const comptime_test_step = b.step("test-comptime", "Run comptime validation tests");

    // Valid definitions (should compile successfully)
    const valid_tests = .{
        "test/comptime/valid_definitions.zig",
        "test/comptime/keyword_arg_name.zig",
    };

    inline for (valid_tests) |path| {
        const valid_test = b.addTest(.{
            .root_module = createClientModule(b, mod, target, optimize, path),
        });
        comptime_test_step.dependOn(&b.addRunArtifact(valid_test).step);
    }

    // Error tests - each expects a specific compile error
    const error_tests = .{
        // Command validation
        .{ "test/comptime/command_empty_name.zig", "name cannot be empty" },

        // Arg.name validation
        .{ "test/comptime/invalid_ident.zig", "name must be a valid Zig identifier" },
        .{ "test/comptime/empty_arg_name.zig", "name must be a valid Zig identifier" },
        .{ "test/comptime/invalid_ident_hyphen.zig", "name must be a valid Zig identifier" },

        // Kind rules: flag
        .{ "test/comptime/flag_wrong_value_type.zig", "flag must have boolean value_type, got string" },
        .{ "test/comptime/flag_multiple.zig", "flag cannot be multiple" },
        .{ "test/comptime/flag_with_default.zig", "flag cannot have default value" },
        .{ "test/comptime/flag_required.zig", "flag cannot be required" },
        .{ "test/comptime/flag_no_short_long.zig", "flag must have long or short" },

        // Kind rules: option
        .{ "test/comptime/option_no_short_long.zig", "option must have long or short" },

        // Kind rules: positional
        .{ "test/comptime/positional_with_short.zig", "positional cannot have long or short" },
        .{ "test/comptime/positional_with_long.zig", "positional cannot have long or short" },
        .{ "test/comptime/positional_after_multiple.zig", "cannot come after a multiple positional argument" },
        .{ "test/comptime/required_positional_after_optional.zig", "required positional Arg 'filename' cannot come after an optional positional argument" },

        // Short/long format validation
        .{ "test/comptime/short_dash.zig", "short must be alphanumeric" },
        .{ "test/comptime/long_empty.zig", "long must not be empty" },
        .{ "test/comptime/long_invalid_start.zig", "long must start with a letter" },
        .{ "test/comptime/long_invalid_char.zig", "long contains invalid character" },

        // Default value validation
        .{ "test/comptime/default_invalid_integer.zig", "is not a valid i64" },
        .{ "test/comptime/default_invalid_float.zig", "is not a valid f64" },
        .{ "test/comptime/default_nan_float.zig", "overflows f64 range" },
        .{ "test/comptime/default_inf_float.zig", "overflows f64 range" },
        .{ "test/comptime/default_hex_float.zig", "must not use hex float notation" },
        .{ "test/comptime/default_invalid_boolean.zig", "is not a valid boolean" },

        // Narrow numeric type default validation
        .{ "test/comptime/default_overflow_u8.zig", "overflows u8 range" },
        .{ "test/comptime/default_overflow_i8.zig", "overflows i8 range" },
        .{ "test/comptime/default_negative_unsigned.zig", "overflows u32 range" },
        .{ "test/comptime/default_invalid_u16.zig", "is not a valid u16" },
        .{ "test/comptime/default_overflow_f32.zig", "overflows f32 range" },

        // Cross-field constraints
        .{ "test/comptime/required_with_default.zig", "required and default cannot both be set" },
        .{ "test/comptime/multiple_with_default.zig", "multiple cannot have default" },

        // Uniqueness validation
        .{ "test/comptime/duplicate_name.zig", "duplicate Arg.name 'foo'" },
        .{ "test/comptime/duplicate_short.zig", "duplicate Arg.short '-x' between 'foo' and 'bar'" },
        .{ "test/comptime/duplicate_long.zig", "duplicate Arg.long '--same' between 'foo' and 'bar'" },
    };

    inline for (error_tests) |test_case| {
        const err_test = b.addTest(.{
            .root_module = createClientModule(b, mod, target, optimize, test_case[0]),
        });
        err_test.expect_errors = .{ .contains = test_case[1] };
        comptime_test_step.dependOn(&err_test.step);
    }
}

fn createClientModule(
    b: *std.Build,
    parsz_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "parsz", .module = parsz_mod },
        },
    });
}
