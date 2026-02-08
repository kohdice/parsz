//! Test: flag cannot be required

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_flag", .kind = .flag, .value_type = .boolean, .short = 'x', .required = true }, // Invalid: flag cannot be required
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
