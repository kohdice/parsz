// expected-error: error: parsz schema error at duplicate_long_name.Cli.second: duplicate long name '--verbose' within command scope duplicate_long_name.Cli

const parsz = @import("parsz");

const Cli = struct {
    first: parsz.Flag(.{
        .long = "verbose",
    }),
    second: parsz.Option([]const u8, .{
        .long = "verbose",
    }),
};

comptime {
    _ = parsz.Parsed(Cli);
}
