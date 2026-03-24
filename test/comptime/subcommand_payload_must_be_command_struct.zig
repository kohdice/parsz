// expected-error: error: parsz schema error at subcommand_payload_must_be_command_struct.Cli.command.init: expected command schema struct, found u32

const parsz = @import("parsz");

const Command = union(enum) {
    init: u32,
};

const Cli = struct {
    command: parsz.Subcommand(Command),
};

comptime {
    _ = parsz.Parsed(Cli);
}
