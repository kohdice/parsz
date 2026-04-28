const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .verbose = parsz.flag(.{ .action = .append }),
    },
});

test "schema error" {
    _ = Cli;
}
