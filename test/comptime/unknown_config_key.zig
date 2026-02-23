const parsz = @import("parsz");
const std = @import("std");

// Config key 'verbsoe' is a typo for 'verbose'.
const T = struct {
    verbose: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .verbsoe = .{ .short = 'v' },
    });
}

test "unknown config key should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
