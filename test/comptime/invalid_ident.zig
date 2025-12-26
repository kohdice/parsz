//! Test: name must be a valid Zig identifier

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "123invalid", .kind = .option, .long = "test" }, // Invalid: starts with digit
        },
    };
    parsz.parse(undefined, &.{}, cmd);
}
