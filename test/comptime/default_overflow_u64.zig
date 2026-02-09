//! Test: default value overflows u64 range.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .u64, .long = "val", .default = "18446744073709551616" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
