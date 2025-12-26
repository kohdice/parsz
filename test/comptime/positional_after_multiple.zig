//! Test: positional cannot come after a multiple positional

const defs = @import("parsz");

comptime {
    const cmd = defs.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "files", .kind = .positional, .multiple = true },
            .{ .name = "output", .kind = .positional }, // Invalid: after multiple positional
        },
    };
    cmd.validate();
}
