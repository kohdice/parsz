//! Test: duplicate subcommand name in Command

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .subcommands = &.{
            .{ .name = "init" },
            .{ .name = "init" }, // Invalid: duplicate subcommand name
        },
    };
    _ = parsz.ParseResult(cmd);
}
