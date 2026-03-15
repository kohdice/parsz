const parsz = @import("parsz");
const std = @import("std");

// Subcommand config container must be a struct, not an integer.
const Command = union(enum) {
    run: struct {},
    build: struct {},
};
const T = struct {
    command: Command,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{ .command = 123 }, null);
}

test "subcmd config int should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
