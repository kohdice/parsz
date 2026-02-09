//! Test: default value overflows f32 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .f32, .long = "val", .default = "1e39" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
