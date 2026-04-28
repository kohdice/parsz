const std = @import("std");

const Fixture = struct {
    path: []const u8,
    expected: []const u8,
};

const fixtures = [_]Fixture{
    .{
        .path = "test/compile_errors/duplicate_long.zig",
        .expected = "duplicates long option name",
    },
    .{
        .path = "test/compile_errors/duplicate_short.zig",
        .expected = "duplicates short option name",
    },
    .{
        .path = "test/compile_errors/invalid_long_empty.zig",
        .expected = "empty long option name",
    },
    .{
        .path = "test/compile_errors/invalid_long_character.zig",
        .expected = "long option name containing",
    },
    .{
        .path = "test/compile_errors/invalid_long_leading_dash.zig",
        .expected = "long option name that begins with '-'",
    },
    .{
        .path = "test/compile_errors/invalid_short.zig",
        .expected = "short option name",
    },
    .{
        .path = "test/compile_errors/required_with_default.zig",
        .expected = "cannot be required and have a default value",
    },
    .{
        .path = "test/compile_errors/invalid_flag_action.zig",
        .expected = "is a flag and must use set_true or count action",
    },
    .{
        .path = "test/compile_errors/invalid_option_action.zig",
        .expected = "is not a flag and must use set or append action",
    },
    .{
        .path = "test/compile_errors/required_operand_after_optional.zig",
        .expected = "required operand after an optional operand",
    },
    .{
        .path = "test/compile_errors/operand_after_variadic.zig",
        .expected = "operand after a variadic operand",
    },
    .{
        .path = "test/compile_errors/required_operand_after_variadic.zig",
        .expected = "operand after a variadic operand",
    },
};

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const zig_exe = if (argv.len > 1) argv[1] else "zig";

    var failed = false;

    for (fixtures) |fixture| {
        const root_module_arg = try std.fmt.allocPrint(init.arena.allocator(), "-Mroot={s}", .{fixture.path});
        const command = [_][]const u8{
            zig_exe,
            "test",
            "--cache-dir",
            ".zig-cache/compile-errors",
            "--global-cache-dir",
            ".zig-cache/compile-errors-global",
            "--dep",
            "parsz",
            root_module_arg,
            "-Mparsz=src/parsz.zig",
        };

        const result = try std.process.run(init.gpa, init.io, .{
            .argv = &command,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer {
            init.gpa.free(result.stdout);
            init.gpa.free(result.stderr);
        }

        switch (result.term) {
            .exited => |code| {
                if (code == 0) {
                    std.debug.print("compile-error fixture unexpectedly compiled: {s}\n", .{fixture.path});
                    failed = true;
                    continue;
                }
            },
            else => {
                std.debug.print("compile-error fixture ended abnormally: {s}\n", .{fixture.path});
                failed = true;
                continue;
            },
        }

        if (std.mem.find(u8, result.stderr, fixture.expected) == null) {
            std.debug.print("compile-error fixture did not contain expected text: {s}\nexpected: {s}\nstderr:\n{s}\n", .{
                fixture.path,
                fixture.expected,
                result.stderr,
            });
            failed = true;
        }
    }

    if (failed) return error.CompileErrorFixtureFailed;
}
