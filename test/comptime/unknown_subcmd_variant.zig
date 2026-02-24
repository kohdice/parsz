const parsz = @import("parsz");
const std = @import("std");

// Subcommand config key 'runn' is a typo for 'run'.
const Command = union(enum) {
    run: struct {},
    build: struct {},
};
const T = struct {
    command: Command,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .command = .{
            .runn = .{},
        },
    });
}

test "unknown subcommand config key should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
