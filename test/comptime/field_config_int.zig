const parsz = @import("parsz");
const std = @import("std");

// Field config value must be a struct (FieldConfig), not an integer.
const T = struct {
    output: []const u8 = "out.txt",
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{ .output = 123 }, null);
}

test "field config int should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
