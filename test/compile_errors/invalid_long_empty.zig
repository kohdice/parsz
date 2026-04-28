const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{ .long = "" }),
    },
});

test "schema error" {
    _ = Cli;
}
