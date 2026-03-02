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

    const comptime_test_step = b.step("test-comptime", "Run comptime validation tests (expect compile errors)");

    inline for (.{
        .{ "test/comptime/duplicate_short.zig", "duplicate short option: -v" },
        .{ "test/comptime/duplicate_long.zig", "duplicate long option: --output" },
        .{ "test/comptime/count_non_integer.zig", "field 'verbose' uses .count action but has non-integer type 'bool'" },
        .{ "test/comptime/multiple_subcommands.zig", "multiple subcommand fields found: 'cmd1' and 'cmd2'; only one subcommand field is allowed per struct" },
        .{ "test/comptime/unknown_config_key.zig", "unknown config key 'verbsoe' does not match any field in unknown_config_key.T" },
        .{ "test/comptime/unknown_subcmd_variant.zig", "unknown subcommand config key 'runn' does not match any variant in unknown_subcmd_variant.Command" },
        .{ "test/comptime/untagged_union.zig", "untagged union; union fields must be tagged (union(enum))" },
        .{ "test/comptime/optional_untagged_union.zig", "untagged union; union fields must be tagged (union(enum))" },
        .{ "test/comptime/positional_after_multi.zig", "multi-value positional must be the last positional field" },
        .{ "test/comptime/duplicate_multi_positional.zig", "only one multi-value positional is allowed" },
        .{ "test/comptime/count_positional.zig", "mutually exclusive" },
        .{ "test/comptime/unknown_field_config_key.zig", "unknown field config key 'positionl' for field 'input'" },
        .{ "test/comptime/positional_short.zig", "positional fields cannot have short options" },
        .{ "test/comptime/positional_long.zig", "positional fields cannot have long options" },
        .{ "test/comptime/unknown_meta_key.zig", "expected one of: name, about, version" },
        .{ "test/comptime/constraint_unknown_field.zig", "conflicts_with referencing unknown field 'nonexistent'" },
        .{ "test/comptime/constraint_self_reference.zig", "conflicts_with referencing itself" },
        .{ "test/comptime/constraint_on_subcommand.zig", "is a subcommand and cannot have constraints" },
        .{ "test/comptime/required_unless_no_default.zig", "non-optional with no default; use ?T or provide a default value" },
    }) |entry| {
        const ct = b.addObject(.{
            .name = "comptime-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[0]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "parsz", .module = mod }},
            }),
        });
        ct.expect_errors = .{ .contains = entry[1] };
        comptime_test_step.dependOn(&ct.step);
    }

    test_step.dependOn(comptime_test_step);

    const examples_step = b.step("examples", "Build example programs");

    inline for (.{
        .{ "sample", "examples/sample.zig" },
        .{ "subcommand", "examples/subcommand.zig" },
        .{ "value_enum", "examples/value_enum.zig" },
        .{ "nested_subcommand", "examples/nested_subcommand.zig" },
    }) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "parsz", .module = mod }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
    }
}
