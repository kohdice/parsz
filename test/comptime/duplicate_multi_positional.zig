const parsz = @import("parsz");
const std = @import("std");

// Two multi-value positional fields cannot coexist because the first one
// absorbs all remaining positional arguments, making the second unreachable.
const T = struct {
    files: []const []const u8 = &.{},
    targets: []const []const u8 = &.{},
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .files = .{ .positional = true },
        .targets = .{ .positional = true },
    });
}

test "duplicate multi-value positional should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
