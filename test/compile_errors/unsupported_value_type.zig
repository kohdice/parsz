const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .ratio = parsz.option(f32, .{
            .long = "ratio",
        }),
    },
});

test "schema error" {
    _ = Cli;
}
