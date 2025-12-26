//! Test: default must be valid for value_type

const defs = @import("parsz");

comptime {
    const arg = defs.Arg{
        .name = "bad_option",
        .kind = .option,
        .value_type = .integer,
        .long = "count",
        .default = "not_a_number", // Invalid: not a valid integer
    };
    arg.validate();
}
