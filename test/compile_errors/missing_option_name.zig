const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{}),
    },
});

test "schema error" {
    _ = Cli;
}
