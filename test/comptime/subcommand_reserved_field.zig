//! Test: Arg name 'subcommand' is reserved when subcommands are defined

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "subcommand", .kind = .option, .long = "subcommand" }, // Invalid: reserved name
        },
        .subcommands = &.{
            .{ .name = "init" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
