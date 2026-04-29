const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .help = parsz.flag(.{ .long = "help" }),
    },
});

test "schema error" {
    _ = Cli;
}
