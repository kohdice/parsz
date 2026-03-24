// expected-error: error: parsz schema error at unsupported_option_payload.Cli.values: unsupported scalar payload type []const u32

const parsz = @import("parsz");

const Cli = struct {
    values: parsz.Option([]const u32, .{}),
};

comptime {
    _ = parsz.Parsed(Cli);
}
