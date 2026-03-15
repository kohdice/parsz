const parsz = @import("parsz");
const std = @import("std");

// Field config value must be a struct (FieldConfig), not a bool.
const T = struct {
    verbose: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{ .verbose = true }, null);
}

test "field config bool should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
