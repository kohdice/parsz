//! Test: duplicate Arg.name in Command

const defs = @import("parsz");

comptime {
    const cmd = defs.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "foo", .kind = .option, .long = "foo" },
            .{ .name = "foo", .kind = .option, .long = "bar" }, // Invalid: duplicate name
        },
    };
    cmd.validate();
}
