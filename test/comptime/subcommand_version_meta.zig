// expected-error: subcommand command meta supports only 'about'

const parsz = @import("parsz");

const Command = union(enum) {
    init: struct {
        pub const meta = .{
            .version = "1.0.0",
        };
    },
};

const Cli = struct {
    command: parsz.Subcommand(Command),
};

comptime {
    _ = parsz.Parsed(Cli);
}
