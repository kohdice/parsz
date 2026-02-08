//! Test: duplicate Arg.name in Command

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "foo", .kind = .option, .long = "foo" },
            .{ .name = "foo", .kind = .option, .long = "bar" }, // Invalid: duplicate name
        },
    };
    _ = parsz.ParseResult(cmd);
}
