//! Test: default must be valid for value_type

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .value_type = .integer, .long = "count", .default = "not_a_number" }, // Invalid: not a valid integer
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
