//! Test: default value overflows u8 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .u8, .long = "val", .default = "256" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
