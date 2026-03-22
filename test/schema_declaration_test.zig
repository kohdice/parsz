const std = @import("std");
const parsz = @import("parsz");

test "schema wrappers expose field kind, parsed value, and metadata declarations" {
    const Cli = struct {
        pub const meta = .{
            .name = "demo",
            .version = "0.1.0",
            .about = "Demo application",
        };

        verbose: parsz.Flag(.{
            .short = 'v',
            .help = "Enable verbose output",
        }),

        output: parsz.Option(?[]const u8, .{
            .long = "output",
            .value_name = "PATH",
        }),

        input: parsz.Positional([]const u8, .{
            .help = "Input file",
        }),
    };

    const cli_fields = @typeInfo(Cli).@"struct".fields;
    const verbose_field = cli_fields[0].type;
    const output_field = cli_fields[1].type;
    const input_field = cli_fields[2].type;

    try std.testing.expect(@hasDecl(verbose_field, "parsz_kind"));
    try std.testing.expect(@hasDecl(verbose_field, "ParsedValue"));
    try std.testing.expect(@hasDecl(verbose_field, "meta"));
    try std.testing.expect(verbose_field.parsz_kind == .flag);
    try std.testing.expect(verbose_field.ParsedValue == bool);

    try std.testing.expect(output_field.parsz_kind == .option);
    try std.testing.expect(output_field.ParsedValue == ?[]const u8);
    try std.testing.expectEqualStrings("output", output_field.meta.long.?);
    try std.testing.expectEqualStrings("PATH", output_field.meta.value_name.?);

    try std.testing.expect(input_field.parsz_kind == .positional);
    try std.testing.expect(input_field.ParsedValue == []const u8);
    try std.testing.expectEqualStrings("Input file", input_field.meta.help.?);
}

test "Subcommand wrapper accepts tagged union command schemas" {
    const Command = union(enum) {
        init: struct {
            pub const meta = .{
                .about = "Create a new project",
            };

            bare: parsz.Flag(.{}),
        },
        fmt: struct {
            pub const meta = .{
                .about = "Format input paths",
            };

            check: parsz.Flag(.{}),
            paths: parsz.Positional([]const []const u8, .{}),
        },
    };

    const Cli = struct {
        pub const meta = .{
            .name = "demo",
            .about = "Demo application",
        };

        command: parsz.Subcommand(Command),
    };

    const command_field = @typeInfo(Cli).@"struct".fields[0].type;
    const ParsedCli = parsz.Parsed(Cli);
    const parsed_fields = @typeInfo(ParsedCli).@"struct".fields;

    try std.testing.expect(command_field.parsz_kind == .subcommand);
    try std.testing.expect(command_field.ParsedValue == Command);
    try std.testing.expectEqual(@as(usize, 1), parsed_fields.len);
    try std.testing.expectEqualStrings("command", parsed_fields[0].name);
}
