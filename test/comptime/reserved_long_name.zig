// expected-error: error: parsz schema error at reserved_long_name.Cli.help: reserved option/flag name 'help' is not allowed in the MVP

const parsz = @import("parsz");

const Cli = struct {
    help: parsz.Flag(.{}),
};

comptime {
    _ = parsz.Parsed(Cli);
}
