const parsz = @import("parsz");
const std = @import("std");

// The 'verbose' field uses .count action but has type bool (non-integer),
// so we expect compile error containing "non-integer type".
const T = struct {
    verbose: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .verbose = .{ .action = .count },
    });
}

test "count action with non-integer type should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
