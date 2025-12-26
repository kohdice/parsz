//! Test: duplicate Arg.short in Command

const defs = @import("parsz");

comptime {
    const cmd = defs.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "foo", .kind = .option, .short = 'x', .long = "foo" },
            .{ .name = "bar", .kind = .option, .short = 'x', .long = "bar" }, // Invalid: duplicate short
        },
    };
    cmd.validate();
}
