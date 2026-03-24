// expected-error: error: parsz schema error at duplicate_short_name.Cli.second: duplicate short name '-v' within command scope duplicate_short_name.Cli

const parsz = @import("parsz");

const Cli = struct {
    first: parsz.Flag(.{
        .short = 'v',
    }),
    second: parsz.Option([]const u8, .{
        .short = 'v',
    }),
};

comptime {
    _ = parsz.Parsed(Cli);
}
