const parsz = @import("parsz");
const std = @import("std");

const T = struct {
    input: []const u8,
    stdin: bool = false,
};

comptime {
    _ = parsz.parse(T, undefined, &.{}, .{
        .input = .{ .positional = true, .required_unless_present = &.{"stdin"} },
    }, null);
}

test "required_unless_present on non-optional no-default field should fail at comptime" {}
