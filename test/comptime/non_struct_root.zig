// expected-error: error: parsz schema error at u32: expected command schema struct, found u32

const parsz = @import("parsz");

const Cli = u32;

comptime {
    _ = parsz.Parsed(Cli);
}
