//! Test: default must be valid for value_type (boolean)

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .value_type = .boolean, .long = "enabled", .default = "yes" }, // Invalid: not a valid boolean
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
