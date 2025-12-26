//! Test: required and default cannot both be set

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .long = "test",
        .required = true,
        .default = "value", // Invalid: cannot have both required and default
    };
    arg.validate();
}
