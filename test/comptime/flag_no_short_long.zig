//! Test: flag must have long or short

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_flag", .kind = .flag, .value_type = .boolean }, // Invalid: no long or short
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
