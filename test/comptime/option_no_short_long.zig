//! Test: option must have long or short

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        // Invalid: no short or long specified
    };
    arg.validate();
}
