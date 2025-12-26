//! Test: flag must have boolean value_type

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_flag", .kind = .flag, .value_type = .string, .short = 'x' }, // Invalid: flag must be boolean
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
