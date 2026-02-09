//! Test: NaN is not a valid float default.

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "ratio", .kind = .option, .value_type = .float, .long = "ratio", .default = "nan" },
        },
    };
    _ = parsz.ParseResult(cmd);
}
