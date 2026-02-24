const parsz = @import("parsz");
const std = @import("std");

// A single-value positional field after a multi-value positional field
// is unreachable at runtime because the multi-value field absorbs all
// remaining positional arguments. This should be caught at comptime.
const T = struct {
    files: []const []const u8 = &.{},
    target: []const u8,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .files = .{ .positional = true },
        .target = .{ .positional = true },
    });
}

test "positional after multi-value positional should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
