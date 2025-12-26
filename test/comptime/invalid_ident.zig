//! Test: name must be a valid Zig identifier

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "123invalid", // Invalid: starts with digit
        .kind = .option,
        .long = "test",
    };
    arg.validate();
}
