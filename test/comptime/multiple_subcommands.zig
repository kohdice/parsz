// expected-error: may declare at most one Subcommand(...) field

const parsz = @import("parsz");

const Command = union(enum) {
    init: struct {},
};

const Cli = struct {
    command: parsz.Subcommand(Command),
    other: parsz.Subcommand(Command),
};

comptime {
    _ = parsz.Parsed(Cli);
}
