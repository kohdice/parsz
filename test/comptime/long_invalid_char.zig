//! Test: long option name cannot contain invalid characters

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .long = "output@file" }, // Invalid: contains '@'
        },
    };
    _ = parsz.ParseResult(cmd);
}
