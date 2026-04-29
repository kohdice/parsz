const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .source = parsz.operand([]const u8, .{
            .long = "source",
        }),
    },
});

test "schema error" {
    _ = Cli;
}
