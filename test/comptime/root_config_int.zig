const parsz = @import("parsz");
const std = @import("std");

// Root config must be a struct, not an integer.
const T = struct {
    verbose: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, 123, null);
}

test "root config int should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
