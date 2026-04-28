const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{ .short = '-' }),
    },
});

test "schema error" {
    _ = Cli;
}
