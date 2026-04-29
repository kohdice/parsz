const std = @import("std");
const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "copy",
    .args = .{},
});

test "schema error" {
    _ = try Cli.renderVersion(std.testing.allocator);
}
