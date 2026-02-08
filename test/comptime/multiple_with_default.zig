//! Test: multiple cannot have default

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .long = "test", .multiple = true, .default = "value" }, // Invalid: multiple cannot have default
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
