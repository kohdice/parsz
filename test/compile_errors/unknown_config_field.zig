const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .output = parsz.option([]const u8, .{
            .long = "output",
            .requred = true,
        }),
    },
});

test "schema error" {
    _ = Cli;
}
