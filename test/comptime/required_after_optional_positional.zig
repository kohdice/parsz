// expected-error: required positional fields may not appear after optional positional fields

const parsz = @import("parsz");

const Cli = struct {
    maybe_input: parsz.Positional(?[]const u8, .{}),
    input: parsz.Positional([]const u8, .{}),
};

comptime {
    _ = parsz.Parsed(Cli);
}
