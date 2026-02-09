//! Test: positional cannot have long or short (long variant)

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_positional", .kind = .positional, .long = "bad" }, // Invalid: positional cannot have long
        },
    };
    _ = parsz.ParseResult(cmd);
}
