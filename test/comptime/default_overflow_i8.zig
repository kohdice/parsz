//! Test: default value overflows i8 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .i8, .long = "val", .default = "128" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
