//! Test: long must not be empty

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .long = "", // Invalid: long must not be empty
    };
    arg.validate();
}
