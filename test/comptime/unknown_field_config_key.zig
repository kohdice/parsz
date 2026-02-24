const parsz = @import("parsz");
const std = @import("std");

// Field config key 'positionl' is a typo for 'positional'.
const T = struct {
    input: []const u8,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .input = .{ .positionl = true },
    });
}

test "unknown field config key should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
