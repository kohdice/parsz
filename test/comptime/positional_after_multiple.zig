//! Test: positional cannot come after a multiple positional

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "files", .kind = .positional, .multiple = true },
            .{ .name = "output", .kind = .positional }, // Invalid: after multiple positional
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
