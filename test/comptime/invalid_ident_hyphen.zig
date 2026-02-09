//! Test: Arg.name with hyphen is rejected (not a valid Zig identifier)

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "test",
        .args = &.{
            .{ .name = "my-arg", .kind = .option, .long = "my-arg" }, // Invalid: hyphen in Zig identifier
        },
    };
    _ = parsz.ParseResult(cmd);
}
