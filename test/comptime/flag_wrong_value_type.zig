//! Test: flag must have boolean value_type

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_flag",
        .kind = .flag,
        .value_type = .string, // Invalid: flag must be boolean
        .short = 'x',
    };
    arg.validate();
}
