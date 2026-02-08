//! Test: short must be alphanumeric (POSIX Guideline 3)

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .short = '-' }, // Invalid: '-' is not alphanumeric
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
