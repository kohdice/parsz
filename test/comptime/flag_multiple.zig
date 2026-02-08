//! Test: flag cannot be multiple

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_flag", .kind = .flag, .value_type = .boolean, .short = 'x', .multiple = true }, // Invalid: flag cannot be multiple
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
