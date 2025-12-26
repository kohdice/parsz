//! Test: multiple cannot have default

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .long = "test",
        .multiple = true,
        .default = "value", // Invalid: multiple cannot have default
    };
    arg.validate();
}
