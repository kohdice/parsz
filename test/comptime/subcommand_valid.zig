//! Valid subcommand definitions test - ensures correct definitions compile successfully.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        },
        .subcommands = &.{
            .{
                .name = "init",
                .args = &.{
                    .{ .name = "name", .kind = .positional, .required = true },
                },
            },
            .{
                .name = "build",
                .args = &.{
                    .{ .name = "release", .kind = .flag, .value_type = .boolean, .long = "release" },
                },
            },
        },
    };
    // ParseResult() calls validateCommand() internally at comptime
    _ = parsz.ParseResult(cmd);
}

test "valid subcommand definitions compile" {
    // This test just needs to compile - the comptime block above does the validation
}
