// expected-error: positional fields may not appear after a variadic positional

const parsz = @import("parsz");

const Cli = struct {
    rest: parsz.Positional([]const []const u8, .{}),
    input: parsz.Positional([]const u8, .{}),
};

comptime {
    _ = parsz.Parsed(Cli);
}
