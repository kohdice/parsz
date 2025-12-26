//! Test: option must have long or short

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option }, // Invalid: no long or short
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
