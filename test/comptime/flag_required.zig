//! Test: flag cannot be required

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_flag",
        .kind = .flag,
        .value_type = .boolean,
        .short = 'x',
        .required = true, // Invalid: flag cannot be required
    };
    arg.validate();
}
