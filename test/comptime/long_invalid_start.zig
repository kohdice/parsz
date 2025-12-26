//! Test: long must start with a letter

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .long = "123invalid", // Invalid: long must start with a letter
    };
    arg.validate();
}
