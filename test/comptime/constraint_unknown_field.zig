const parsz = @import("parsz");
const std = @import("std");

const T = struct {
    json: bool = false,
    csv: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .json = .{ .conflicts_with = &.{"nonexistent"} },
    }, null);
}

test "constraint referencing unknown field should fail at comptime" {}
