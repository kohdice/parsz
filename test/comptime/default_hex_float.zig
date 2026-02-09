//! Test: hex float notation is not valid for float defaults.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "ratio", .kind = .option, .value_type = .f64, .long = "ratio", .default = "0x1.fp10" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
