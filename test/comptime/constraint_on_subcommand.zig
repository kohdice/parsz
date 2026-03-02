const parsz = @import("parsz");
const std = @import("std");

const Command = union(enum) {
    run: struct {},
};

const T = struct {
    verbose: bool = false,
    command: ?Command = null,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .command = .{ .conflicts_with = &.{"verbose"} },
    }, null);
}

test "constraint on subcommand field should fail at comptime" {}
