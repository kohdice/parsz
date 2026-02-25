const parsz = @import("parsz");
const std = @import("std");

// .action = .count and .positional = true are mutually exclusive.
// count produces a flag that increments, while positional consumes
// a positional argument — these semantics conflict.
const T = struct {
    verbose: u8 = 0,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .verbose = .{ .action = .count, .positional = true },
    }, null);
}

test "count with positional should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
