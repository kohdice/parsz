// expected-error: error: parsz schema error at subcommand_requires_tagged_union.Cli.command: Subcommand(...) expects a tagged union, found untagged union subcommand_requires_tagged_union.Command

const parsz = @import("parsz");

const Command = union {
    init: struct {},
};

const Cli = struct {
    command: parsz.Subcommand(Command),
};

comptime {
    _ = parsz.Parsed(Cli);
}
