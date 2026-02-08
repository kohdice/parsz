//! Test: long must not be empty

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .long = "" }, // Invalid: long must not be empty
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
