const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .maybe_source = parsz.operand([]const u8, .{}),
        .destination = parsz.operand([]const u8, .{ .required = true }),
    },
});

test "schema error" {
    _ = Cli;
}
