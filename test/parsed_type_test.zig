const std = @import("std");
const parsz = @import("parsz");

test "Parsed transforms schema wrappers into plain struct fields" {
    const Cli = struct {
        verbose: parsz.Flag(.{}),
        output: parsz.Option(?[]const u8, .{}),
        input: parsz.Positional([]const u8, .{}),
    };

    const ParsedCli = parsz.Parsed(Cli);
    const info = @typeInfo(ParsedCli).@"struct";

    try std.testing.expectEqual(@as(usize, 3), info.fields.len);
    try std.testing.expectEqualStrings("verbose", info.fields[0].name);
    try std.testing.expect(info.fields[0].type == bool);
    try std.testing.expectEqualStrings("output", info.fields[1].name);
    try std.testing.expect(info.fields[1].type == ?[]const u8);
    try std.testing.expectEqualStrings("input", info.fields[2].name);
    try std.testing.expect(info.fields[2].type == []const u8);
}

test "Parsed preserves repeated positional slice payloads" {
    const StringCli = struct {
        paths: parsz.Positional([]const []const u8, .{}),
    };
    const NumericCli = struct {
        ids: parsz.Positional([]const u32, .{}),
    };

    const ParsedStringCli = parsz.Parsed(StringCli);
    const ParsedNumericCli = parsz.Parsed(NumericCli);
    const string_info = @typeInfo(ParsedStringCli).@"struct";
    const numeric_info = @typeInfo(ParsedNumericCli).@"struct";

    try std.testing.expectEqual(@as(usize, 1), string_info.fields.len);
    try std.testing.expect(string_info.fields[0].type == []const []const u8);
    try std.testing.expectEqual(@as(usize, 1), numeric_info.fields.len);
    try std.testing.expect(numeric_info.fields[0].type == []const u32);
}

test "Parsed transforms subcommand unions recursively" {
    const AdminCommand = union(enum) {
        user: struct {
            name: parsz.Positional([]const u8, .{}),
        },
        group: struct {
            ids: parsz.Positional([]const u32, .{}),
        },
    };

    const Command = union(enum) {
        init: struct {
            bare: parsz.Flag(.{}),
            config: parsz.Option(?[]const u8, .{}),
        },
        admin: struct {
            command: parsz.Subcommand(AdminCommand),
        },
    };

    const Cli = struct {
        command: parsz.Subcommand(Command),
    };

    const ParsedCli = parsz.Parsed(Cli);
    const cli_fields = @typeInfo(ParsedCli).@"struct".fields;
    const ParsedCommand = cli_fields[0].type;
    const command_info = @typeInfo(ParsedCommand).@"union";

    try std.testing.expectEqual(@as(usize, 1), cli_fields.len);
    try std.testing.expect(command_info.tag_type != null);
    try std.testing.expectEqual(@as(usize, 2), command_info.fields.len);

    const init_payload = command_info.fields[0].type;
    const init_fields = @typeInfo(init_payload).@"struct".fields;
    try std.testing.expectEqualStrings("init", command_info.fields[0].name);
    try std.testing.expect(init_fields[0].type == bool);
    try std.testing.expect(init_fields[1].type == ?[]const u8);

    const admin_payload = command_info.fields[1].type;
    const admin_fields = @typeInfo(admin_payload).@"struct".fields;
    const ParsedAdminCommand = admin_fields[0].type;
    const admin_command_info = @typeInfo(ParsedAdminCommand).@"union";

    try std.testing.expectEqualStrings("admin", command_info.fields[1].name);
    try std.testing.expectEqual(@as(usize, 1), admin_fields.len);
    try std.testing.expect(admin_command_info.tag_type != null);
    try std.testing.expectEqual(@as(usize, 2), admin_command_info.fields.len);

    const user_payload = admin_command_info.fields[0].type;
    const user_fields = @typeInfo(user_payload).@"struct".fields;
    try std.testing.expectEqualStrings("user", admin_command_info.fields[0].name);
    try std.testing.expectEqual(@as(usize, 1), user_fields.len);
    try std.testing.expect(user_fields[0].type == []const u8);

    const group_payload = admin_command_info.fields[1].type;
    const group_fields = @typeInfo(group_payload).@"struct".fields;
    try std.testing.expectEqualStrings("group", admin_command_info.fields[1].name);
    try std.testing.expectEqual(@as(usize, 1), group_fields.len);
    try std.testing.expect(group_fields[0].type == []const u32);
}
