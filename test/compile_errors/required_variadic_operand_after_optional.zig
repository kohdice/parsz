const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "app",
    .args = .{
        .maybe_source = parsz.operand([]const u8, .{}),
        .sources = parsz.operand([]const u8, .{
            .action = .append,
            .required = true,
        }),
    },
});

test "schema error" {
    _ = Cli;
}
