//! Test: short cannot be '-'

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .short = '-', // Invalid: short cannot be '-'
    };
    arg.validate();
}
