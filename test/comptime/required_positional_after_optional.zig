//! Test: required positional cannot come after an optional positional

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "encoding", .kind = .positional },
            .{ .name = "filename", .kind = .positional, .required = true }, // Invalid: required after optional
        },
    };
    _ = parsz.ParseResult(cmd);
}
