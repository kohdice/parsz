//! Test: Command.name cannot be empty

const parsz = @import("parsz");

comptime {
    const cmd = parsz.Command{
        .name = "", // Invalid: empty command name
        .args = &.{},
    };
    parsz.parse(undefined, &.{}, cmd);
}
