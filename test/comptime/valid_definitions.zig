//! Valid definitions test - ensures correct definitions compile successfully.

const parsz = @import("parsz");

comptime {
    // Valid Command with multiple args
    const cmd = parsz.Command{
        .name = "myapp",
        .about = "A sample application",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "output", .kind = .option, .long = "output", .short = 'o', .default = "out.txt" },
            .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .default = "10" },
            .{ .name = "config", .kind = .option, .long = "config", .required = true },
            .{ .name = "input", .kind = .positional, .required = true },
            .{ .name = "extras", .kind = .positional, .multiple = true },
        },
    };
    // parse() calls validateCommand() internally
    parsz.parse(undefined, &.{}, cmd);
}

test "valid definitions compile" {
    // This test just needs to compile - the comptime block above does the validation
}
