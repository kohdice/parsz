const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .port = parsz.option(u16, .{
            .required = true,
            .default = 80,
        }),
    },
});

test "schema error" {
    _ = Cli;
}
