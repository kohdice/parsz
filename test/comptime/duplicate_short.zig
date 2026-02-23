const parsz = @import("parsz");
const std = @import("std");

// Short option 'v' is used by both verbose and version,
// so we expect compile error "duplicate short option: -v".
const T = struct {
    verbose: bool = false,
    version: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .verbose = .{ .short = 'v' },
        .version = .{ .short = 'v' },
    });
}

test "duplicate short option should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
