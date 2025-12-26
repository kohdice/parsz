//! Test: flag cannot have default value

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_flag", .kind = .flag, .value_type = .boolean, .short = 'x', .default = "true" }, // Invalid: flag cannot have default
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
