const parsz = @import("parsz");
const std = @import("std");

// Both output and output2 resolve to long name --output,
// so we expect compile error "duplicate long option: --output".
const T = struct {
    output: []const u8 = "",
    output2: []const u8 = "",
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .output2 = .{ .long = "output" },
    }, null);
}

test "duplicate long option should fail at comptime" {}
