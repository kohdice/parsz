//! Test: flag must have long or short

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_flag",
        .kind = .flag,
        .value_type = .boolean,
        // Invalid: no short or long specified
    };
    arg.validate();
}
