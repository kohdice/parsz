const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .version = parsz.version(.{
        .number = "1.0.0",
    }),
    .args = .{},
});

test "schema error" {
    _ = Cli;
}
