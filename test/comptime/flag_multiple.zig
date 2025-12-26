//! Test: flag cannot be multiple

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_flag",
        .kind = .flag,
        .value_type = .boolean,
        .short = 'x',
        .multiple = true, // Invalid: flag cannot be multiple
    };
    arg.validate();
}
