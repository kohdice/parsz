const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .sources = parsz.operand([]const u8, .{ .action = .append }),
        .destination = parsz.operand([]const u8, .{ .required = true }),
    },
});

test "schema error" {
    _ = Cli;
}
