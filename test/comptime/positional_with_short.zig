//! Test: positional cannot have long or short

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_positional",
        .kind = .positional,
        .short = 'x', // Invalid: positional cannot have short
    };
    arg.validate();
}
