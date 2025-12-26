//! Valid definitions test - ensures correct definitions compile successfully.

const defs = @import("parsz");

comptime {
    // Valid flag
    const flag = defs.Arg{
        .name = "verbose",
        .kind = .flag,
        .value_type = .boolean,
        .short = 'v',
        .long = "verbose",
    };
    flag.validate();

    // Valid option with default
    const option = defs.Arg{
        .name = "output",
        .kind = .option,
        .value_type = .string,
        .short = 'o',
        .long = "output",
        .default = "out.txt",
    };
    option.validate();

    // Valid required option
    const required_opt = defs.Arg{
        .name = "config",
        .kind = .option,
        .value_type = .string,
        .long = "config",
        .required = true,
    };
    required_opt.validate();

    // Valid positional
    const positional = defs.Arg{
        .name = "input",
        .kind = .positional,
        .value_type = .string,
        .required = true,
    };
    positional.validate();

    // Valid multiple positional
    const multi_pos = defs.Arg{
        .name = "files",
        .kind = .positional,
        .value_type = .string,
        .multiple = true,
    };
    multi_pos.validate();

    // Valid Command with multiple args
    const cmd = defs.Command{
        .name = "myapp",
        .about = "A sample application",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v' },
            .{ .name = "output", .kind = .option, .long = "output", .short = 'o' },
            .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .default = "10" },
            .{ .name = "input", .kind = .positional, .required = true },
            .{ .name = "extras", .kind = .positional, .multiple = true },
        },
    };
    cmd.validate();
}

test "valid definitions compile" {
    // This test just needs to compile - the comptime block above does the validation
}
