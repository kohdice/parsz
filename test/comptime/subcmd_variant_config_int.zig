const parsz = @import("parsz");
const std = @import("std");

// Subcommand variant config value must be a struct, not an integer.
const Command = union(enum) {
    run: struct { target: []const u8 },
    build: struct {},
};
const T = struct {
    command: Command,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .command = .{ .run = 123 },
    }, null);
}

test "subcmd variant config int should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
