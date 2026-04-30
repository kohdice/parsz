const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "git",
    .args = .{
        .path = parsz.operand([]const u8, .{}),
    },
    .subcommands = .{
        .remote = parsz.Command(.{
            .name = "remote",
            .args = .{},
        }),
    },
});

test "subcommands reject operands on the same command" {
    _ = Cli;
}
