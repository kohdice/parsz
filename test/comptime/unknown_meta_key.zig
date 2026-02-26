const parsz = @import("parsz");
const std = @import("std");

// Config key 'description' is not a valid _meta key.
// Valid keys are: name, about, version.
const T = struct {
    verbose: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        ._meta = .{ .name = "myapp", .description = "invalid key" },
    }, null);
}

test "unknown _meta key should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
