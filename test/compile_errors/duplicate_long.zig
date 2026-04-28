const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{ .long = "same" }),
        .version = parsz.flag(.{ .long = "same" }),
    },
});

test "schema error" {
    _ = Cli;
}
