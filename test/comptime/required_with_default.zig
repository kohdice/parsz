//! Test: required and default cannot both be set

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .long = "test", .required = true, .default = "value" }, // Invalid: cannot have both
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
