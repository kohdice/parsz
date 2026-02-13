//! Test: positional Arg cannot coexist with subcommands

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "file", .kind = .positional }, // Invalid: positional + subcommands
        },
        .subcommands = &.{
            .{ .name = "init" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
