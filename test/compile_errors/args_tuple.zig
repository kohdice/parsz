const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        parsz.flag(.{ .long = "verbose" }),
    },
});

test "schema error" {
    _ = Cli;
}
