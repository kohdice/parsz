const parsz = @import("parsz");
const std = @import("std");

// Two union(enum) fields in the same struct — only one subcommand is allowed.
const Command1 = union(enum) {
    run: struct {},
};

const Command2 = union(enum) {
    build: struct {},
};

const T = struct {
    cmd1: ?Command1 = null,
    cmd2: ?Command2 = null,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{}, null);
}

test "multiple subcommand fields should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
