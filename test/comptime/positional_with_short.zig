//! Test: positional cannot have long or short

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_positional", .kind = .positional, .short = 'x' }, // Invalid: positional cannot have short
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
