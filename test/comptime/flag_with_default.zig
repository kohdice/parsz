//! Test: flag cannot have default value

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_flag",
        .kind = .flag,
        .value_type = .boolean,
        .short = 'x',
        .default = "true", // Invalid: flag cannot have default
    };
    arg.validate();
}
