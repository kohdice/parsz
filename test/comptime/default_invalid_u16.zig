//! Test: default must be valid for u16 value_type.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "val", .kind = .option, .value_type = .u16, .long = "val", .default = "abc" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
