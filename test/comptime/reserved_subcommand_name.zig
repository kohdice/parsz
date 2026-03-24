// expected-error: error: parsz schema error at reserved_subcommand_name.Cli.command.version: reserved subcommand name 'version' is not allowed in the MVP

const parsz = @import("parsz");

const Command = union(enum) {
    version: struct {},
};

const Cli = struct {
    command: parsz.Subcommand(Command),
};

comptime {
    _ = parsz.Parsed(Cli);
}
