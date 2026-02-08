//! Test: empty Arg.name is rejected

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "", .kind = .option, .long = "test" }, // Invalid: empty name
        },
    };
    _ = parsz.ParseResult(cmd);
}
