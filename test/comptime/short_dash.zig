//! Test: short cannot be '-'

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .short = '-' }, // Invalid: short cannot be '-'
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
