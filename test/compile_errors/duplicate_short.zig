const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .alpha = parsz.flag(.{ .short = 'a' }),
        .again = parsz.flag(.{ .short = 'a' }),
    },
});

test "schema error" {
    _ = Cli;
}
