//! Test: duplicate Arg.long in Command

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "foo", .kind = .option, .short = 'x', .long = "same" },
            .{ .name = "bar", .kind = .option, .short = 'y', .long = "same" }, // Invalid: duplicate long
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
