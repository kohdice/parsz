//! Test: default value overflows i32 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .i32, .long = "val", .default = "2147483648" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
