//! Test: long must start with a letter

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "bad_option", .kind = .option, .long = "123invalid" }, // Invalid: long must start with a letter
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
