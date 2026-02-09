//! Test: default value overflows i16 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .i16, .long = "val", .default = "32768" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
