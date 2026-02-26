const std = @import("std");
const spec_arg = @import("../spec/arg.zig");
const spec_command = @import("../spec/command.zig");
const parser = @import("../parser.zig");

const ArgKind = spec_arg.ArgKind;
const ArgSpec = spec_arg.ArgSpec;
const snakeToKebab = spec_arg.snakeToKebab;
const getFieldConfig = spec_arg.getFieldConfig;
const getMetaConfig = spec_arg.getMetaConfig;

pub fn writeUsage(comptime T: type, comptime config: anytype, writer: anytype) !void {
    const meta = comptime getMetaConfig(config);
    const cmd_spec = comptime spec_command.buildSpec(T, config);
    const args = cmd_spec.args;

    try writer.writeAll("Usage: ");
    try writer.writeAll(meta.name orelse "PROGRAM");

    // [OPTIONS] if there are any option-like entries (flags, options, non-positional multi)
    // or if built-in help is active (at least one of -h or --help)
    if (comptime hasOptions(T, config)) {
        try writer.writeAll(" [OPTIONS]");
    }

    // Positional args in order
    inline for (args) |arg| {
        if (arg.kind == .positional) {
            try writer.writeByte(' ');
            if (arg.has_default or arg.is_optional) {
                try writer.writeByte('[');
                try writeArgName(arg, writer);
                try writer.writeByte(']');
            } else {
                try writer.writeByte('<');
                try writeArgName(arg, writer);
                try writer.writeByte('>');
            }
        } else if (arg.kind == .multi) {
            const fc = comptime getFieldConfig(config, arg.field_name);
            if (fc.positional) {
                try writer.writeByte(' ');
                if (arg.has_default or arg.is_optional) {
                    try writer.writeByte('[');
                    try writeArgName(arg, writer);
                    try writer.writeAll("...]");
                } else {
                    try writer.writeByte('<');
                    try writeArgName(arg, writer);
                    try writer.writeAll("...>");
                }
            }
        }
    }

    // Subcommand
    if (cmd_spec.subcommand_field) |sfn| {
        inline for (args) |arg| {
            if (arg.kind == .subcommand and comptime std.mem.eql(u8, arg.field_name, sfn)) {
                if (arg.is_optional or arg.has_default) {
                    try writer.writeAll(" [COMMAND]");
                } else {
                    try writer.writeAll(" <COMMAND>");
                }
            }
        }
    }

    try writer.writeByte('\n');
}

fn writeArgName(comptime arg: ArgSpec, writer: anytype) !void {
    if (arg.value_name) |vn| {
        try writer.writeAll(vn);
    } else {
        const kebab = comptime snakeToKebab(arg.field_name);
        inline for (kebab) |c| {
            try writer.writeByte(comptime std.ascii.toUpper(c));
        }
    }
}

fn hasOptions(comptime T: type, comptime config: anytype) bool {
    const fields = @typeInfo(T).@"struct".fields;

    // Check if built-in help is active (at least one of -h or --help)
    if (comptime parser.hasBuiltinHelpShort(T, config) or parser.hasBuiltinHelpLong(T, config)) {
        return true;
    }

    // Check for user-defined flags, options, or non-positional multi
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime spec_arg.argKind(field.type, fc);
        if (kind == .flag or kind == .option or (kind == .multi and !fc.positional)) {
            return true;
        }
    }

    return false;
}

test "usage: flags only" {
    const Cli = struct { verbose: bool = false };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS]\n", stream.getWritten());
}

test "usage: with required positional" {
    const Cli = struct {
        verbose: bool = false,
        input: []const u8,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .verbose = .{ .short = 'v' },
        .input = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <INPUT>\n", stream.getWritten());
}

test "usage: with optional positional" {
    const Cli = struct {
        input: []const u8 = "default.txt",
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .input = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] [INPUT]\n", stream.getWritten());
}

test "usage: with required subcommand" {
    const Command = union(enum) {
        run: struct {},
        build: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        command: Command,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .command = .{},
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <COMMAND>\n", stream.getWritten());
}

test "usage: with optional subcommand" {
    const Command = union(enum) {
        run: struct {},
    };
    const Cli = struct {
        command: ?Command = null,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .command = .{},
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] [COMMAND]\n", stream.getWritten());
}

test "usage: with multi positional" {
    const Cli = struct {
        files: []const []const u8 = &.{},
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .files = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] [FILES...]\n", stream.getWritten());
}

test "usage: required multi positional" {
    const Cli = struct {
        files: []const []const u8,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .files = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <FILES...>\n", stream.getWritten());
}

test "usage: no meta fallback" {
    const Cli = struct { verbose: bool = false };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{}, stream.writer());
    try std.testing.expectEqualStrings("Usage: PROGRAM [OPTIONS]\n", stream.getWritten());
}

test "usage: value_name on positional" {
    const Cli = struct {
        input: []const u8,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .input = .{ .positional = true, .value_name = "FILE" },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <FILE>\n", stream.getWritten());
}

test "usage: always shows [OPTIONS] when built-in help is active" {
    const Cli = struct {
        input: []const u8,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeUsage(Cli, .{
        ._meta = .{ .name = "myapp" },
        .input = .{ .positional = true },
    }, stream.writer());
    try std.testing.expectEqualStrings("Usage: myapp [OPTIONS] <INPUT>\n", stream.getWritten());
}
