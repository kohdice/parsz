//! Test: negative default overflows unsigned u32 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .u32, .long = "val", .default = "-1" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
