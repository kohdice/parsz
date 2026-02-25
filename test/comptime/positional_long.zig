const parsz = @import("parsz");
const std = @import("std");

// .positional = true and explicit .long = "input-file" are mutually exclusive.
// Positional fields consume bare arguments by position, not via --input-file.
const T = struct {
    input: []const u8,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .input = .{ .positional = true, .long = "input-file" },
    }, null);
}

test "positional with long should fail at comptime" {
    // This test body is unreachable because the comptime block above triggers
    // a compile error. The build system verifies that compilation fails.
}
