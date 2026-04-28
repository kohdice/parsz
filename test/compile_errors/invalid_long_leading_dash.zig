const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{ .long = "-verbose" }),
    },
});

test "schema error" {
    _ = Cli;
}
