//! Test: default must be valid for value_type (float)

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .value_type = .f64, .long = "ratio", .default = "not_a_number" }, // Invalid: not a valid float
        },
    };
    _ = parsz.ParseResult(cmd);
}
