// expected-error: positional fields may not declare long or short names

const parsz = @import("parsz");

const Cli = struct {
    input: parsz.Positional([]const u8, .{
        .long = "input",
    }),
};

comptime {
    _ = parsz.Parsed(Cli);
}
