//! Test: subcommand name must be a valid Zig identifier

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .subcommands = &.{
            .{ .name = "my-sub" }, // Invalid: hyphen is not valid in Zig identifiers
        },
    };
    _ = parsz.ParseResult(cmd);
}
