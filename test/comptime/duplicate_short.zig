//! Test: duplicate Arg.short in Command

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "foo", .kind = .option, .short = 'x', .long = "foo" },
            .{ .name = "bar", .kind = .option, .short = 'x', .long = "bar" }, // Invalid: duplicate short
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
