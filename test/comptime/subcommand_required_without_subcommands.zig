//! Test: subcommand_required cannot be true when no subcommands are defined

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        },
        .subcommand_required = true, // Invalid: no subcommands defined
    };
    _ = parsz.ParseResult(cmd);
}
