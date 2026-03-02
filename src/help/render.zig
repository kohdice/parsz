const std = @import("std");
const spec_arg = @import("../spec/arg.zig");
const spec_command = @import("../spec/command.zig");
const parser = @import("../parser.zig");
const usage = @import("usage.zig");

const ArgKind = spec_arg.ArgKind;
const ArgSpec = spec_arg.ArgSpec;
const FieldConfig = spec_arg.FieldConfig;
const snakeToKebab = spec_arg.snakeToKebab;
const getFieldConfig = spec_arg.getFieldConfig;
const getMetaConfig = spec_arg.getMetaConfig;
const isSubcommandType = spec_arg.isSubcommandType;

fn writeNSpaces(writer: anytype, n: usize) !void {
    for (0..n) |_| {
        try writer.writeByte(' ');
    }
}

pub fn writeHelp(comptime T: type, comptime config: anytype, writer: anytype) !void {
    const meta = comptime getMetaConfig(config);
    const cmd_spec = comptime spec_command.buildSpec(T, config);
    const args = cmd_spec.args;

    const has_help_short = comptime parser.hasBuiltinHelpShort(T, config);
    const has_help_long = comptime parser.hasBuiltinHelpLong(T, config);

    // 1. About
    if (meta.about) |about| {
        try writer.writeAll(about);
        try writer.writeAll("\n\n");
    }

    // 2. Usage
    try usage.writeUsage(T, config, writer);

    // 3. Arguments section
    const has_positionals = comptime blk: {
        for (args) |arg| {
            if (arg.kind == .positional) break :blk true;
            if (arg.kind == .multi) {
                const fc = getFieldConfig(config, arg.field_name);
                if (fc.positional) break :blk true;
            }
        }
        break :blk false;
    };

    if (has_positionals) {
        try writer.writeAll("\nArguments:\n");
        inline for (args) |arg| {
            if (arg.kind == .positional or (arg.kind == .multi and comptime getFieldConfig(config, arg.field_name).positional)) {
                try writer.writeAll("  ");
                if (arg.has_default or arg.is_optional) {
                    try writer.writeByte('[');
                    try writeArgDisplayName(arg, writer);
                    if (arg.kind == .multi) try writer.writeAll("...");
                    try writer.writeByte(']');
                } else {
                    try writer.writeByte('<');
                    try writeArgDisplayName(arg, writer);
                    if (arg.kind == .multi) try writer.writeAll("...");
                    try writer.writeByte('>');
                }
                if (arg.help) |h| {
                    try writer.writeAll("  ");
                    try writer.writeAll(h);
                }
                try writer.writeByte('\n');
            }
        }
    }

    // 4. Options section
    const has_option_entries = comptime blk: {
        for (args) |arg| {
            if (arg.kind == .flag or arg.kind == .option or (arg.kind == .multi and !getFieldConfig(config, arg.field_name).positional)) {
                break :blk true;
            }
        }
        // Built-in help entry counts
        if (has_help_short or has_help_long) break :blk true;
        break :blk false;
    };

    if (has_option_entries) {
        const max_left = comptime computeMaxLeftWidth(T, config, args, has_help_short, has_help_long);

        try writer.writeAll("\nOptions:\n");
        inline for (args) |arg| {
            if (arg.kind == .flag or arg.kind == .option or (arg.kind == .multi and !comptime getFieldConfig(config, arg.field_name).positional)) {
                try writeOptionEntry(T, config, arg, max_left, writer);
            }
        }
        // Built-in help entry
        if (has_help_short or has_help_long) {
            try writeBuiltinHelpEntry(has_help_short, has_help_long, max_left, writer);
        }
    }

    // 5. Commands section
    if (cmd_spec.subcommand_field) |sfn| {
        const fields = @typeInfo(T).@"struct".fields;
        const SubUnion = comptime blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, sfn)) {
                    const ft = f.type;
                    if (@typeInfo(ft) == .optional) {
                        break :blk @typeInfo(ft).optional.child;
                    }
                    break :blk ft;
                }
            }
            unreachable;
        };
        const sub_fields = @typeInfo(SubUnion).@"union".fields;

        if (sub_fields.len > 0) {
            // Compute max subcommand name width
            const max_cmd_width = comptime blk: {
                var max: usize = 0;
                for (sub_fields) |sf| {
                    const name_len = snakeToKebab(sf.name).len;
                    if (name_len > max) max = name_len;
                }
                break :blk max;
            };

            try writer.writeAll("\nCommands:\n");
            inline for (sub_fields) |sf| {
                const name = comptime snakeToKebab(sf.name);
                try writer.writeAll("  ");
                try writer.writeAll(name);
                // Pad to alignment (no about text in Phase 3)
                _ = max_cmd_width;
                try writer.writeByte('\n');
            }
        }
    }
}

fn writeArgDisplayName(comptime arg: ArgSpec, writer: anytype) !void {
    if (arg.value_name) |vn| {
        try writer.writeAll(vn);
    } else {
        const kebab = comptime snakeToKebab(arg.field_name);
        inline for (kebab) |c| {
            try writer.writeByte(comptime std.ascii.toUpper(c));
        }
    }
}

fn computeMaxLeftWidth(
    comptime T: type,
    comptime config: anytype,
    comptime args: anytype,
    comptime has_help_short: bool,
    comptime has_help_long: bool,
) usize {
    comptime {
        var max: usize = 0;
        for (args) |arg| {
            if (arg.kind == .flag or arg.kind == .option or (arg.kind == .multi and !getFieldConfig(config, arg.field_name).positional)) {
                const w = optionLeftWidth(arg);
                if (w > max) max = w;
            }
        }
        // Built-in help entry width
        if (has_help_short or has_help_long) {
            const help_w = builtinHelpLeftWidth(has_help_short, has_help_long);
            if (help_w > max) max = help_w;
        }
        _ = T;
        return max;
    }
}

fn optionLeftWidth(comptime arg: ArgSpec) usize {
    // Format: "  -s, --long-name <VALUE>"
    //         "      --long-name <VALUE>"
    //         "  -s, --long-name"
    comptime {
        var w: usize = 0;
        // Short part
        if (arg.short != null) {
            w += 2; // "-s"
            w += 2; // ", "
        } else {
            w += 4; // "    "
        }
        // Long part
        w += 2; // "--"
        w += arg.long.len;
        // Value name for options/multi
        if (arg.kind == .option or arg.kind == .multi) {
            w += 1; // " "
            w += 1; // "<"
            if (arg.value_name) |vn| {
                w += vn.len;
            } else {
                const kebab = snakeToKebab(arg.field_name);
                // Uppercase length is the same
                w += kebab.len;
            }
            w += 1; // ">"
        }
        return w;
    }
}

fn builtinHelpLeftWidth(comptime has_short: bool, comptime has_long: bool) usize {
    comptime {
        var w: usize = 0;
        if (has_short) {
            w += 2; // "-h"
            if (has_long) w += 2; // ", "
        } else {
            w += 4; // "    "
        }
        if (has_long) {
            w += 6; // "--help"
        }
        return w;
    }
}

fn writeOptionEntry(comptime T: type, comptime config: anytype, comptime arg: ArgSpec, comptime max_left: usize, writer: anytype) !void {
    const left_width = comptime optionLeftWidth(arg);

    try writer.writeAll("  ");
    // Short
    if (arg.short) |s| {
        try writer.writeByte('-');
        try writer.writeByte(s);
        try writer.writeAll(", ");
    } else {
        try writer.writeAll("    ");
    }
    // Long
    try writer.writeAll("--");
    try writer.writeAll(arg.long);
    // Value name
    if (arg.kind == .option or arg.kind == .multi) {
        try writer.writeAll(" <");
        if (arg.value_name) |vn| {
            try writer.writeAll(vn);
        } else {
            const kebab = comptime snakeToKebab(arg.field_name);
            inline for (kebab) |c| {
                try writer.writeByte(comptime std.ascii.toUpper(c));
            }
        }
        try writer.writeByte('>');
    }

    // Help text and default (suppress default for flags — bool defaults are always obvious)
    const help_text = arg.help;
    const default_str = comptime if (arg.kind == .flag) null else getDefaultString(T, config, arg);

    if (help_text != null or default_str != null) {
        // Pad to alignment: 2 (indent) + left_width + gap(2)
        const padding = max_left - left_width + 2;
        try writeNSpaces(writer, padding);
        if (help_text) |h| {
            try writer.writeAll(h);
        }
        if (default_str) |d| {
            if (help_text != null) try writer.writeByte(' ');
            try writer.writeAll("[default: ");
            try writer.writeAll(d);
            try writer.writeByte(']');
        }
    }
    try writer.writeByte('\n');
}

fn getDefaultString(comptime T: type, comptime config: anytype, comptime arg: ArgSpec) ?[]const u8 {
    _ = config;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, arg.field_name)) {
            if (field.default_value_ptr) |ptr| {
                const FieldType = field.type;
                const val = @as(*const FieldType, @ptrCast(@alignCast(ptr))).*;
                return comptime formatDefault(FieldType, val);
            }
            return null;
        }
    }
    return null;
}

fn formatDefault(comptime T: type, comptime val: T) ?[]const u8 {
    comptime {
        if (T == bool) {
            return if (val) "true" else "false";
        }
        if (@typeInfo(T) == .int) {
            return std.fmt.comptimePrint("{}", .{val});
        }
        if (@typeInfo(T) == .float) {
            return std.fmt.comptimePrint("{d}", .{val});
        }
        if (T == []const u8) {
            return val;
        }
        if (@typeInfo(T) == .@"enum") {
            return @tagName(val);
        }
        // Optional types: unwrap and format inner
        if (@typeInfo(T) == .optional) {
            if (val) |inner| {
                return formatDefault(@typeInfo(T).optional.child, inner);
            }
            return null;
        }
        return null;
    }
}

fn writeBuiltinHelpEntry(comptime has_short: bool, comptime has_long: bool, comptime max_left: usize, writer: anytype) !void {
    const left_width = comptime builtinHelpLeftWidth(has_short, has_long);

    try writer.writeAll("  ");
    if (has_short) {
        try writer.writeAll("-h");
        if (has_long) {
            try writer.writeAll(", ");
        }
    } else {
        try writer.writeAll("    ");
    }
    if (has_long) {
        try writer.writeAll("--help");
    }

    const padding = max_left - left_width + 2;
    try writeNSpaces(writer, padding);
    try writer.writeAll("Print help\n");
}

// --- Tests ---

test "help: basic flags and positionals" {
    const Cli = struct {
        verbose: bool = false,
        input: []const u8,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp", .about = "A sample CLI application" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .input = .{ .positional = true, .help = "Input file" },
    }, stream.writer());
    const expected =
        \\A sample CLI application
        \\
        \\Usage: myapp [OPTIONS] <INPUT>
        \\
        \\Arguments:
        \\  <INPUT>  Input file
        \\
        \\Options:
        \\  -v, --verbose  Enable verbose output
        \\  -h, --help     Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: options with value_name and defaults" {
    const Cli = struct {
        verbose: bool = false,
        output: []const u8 = "out.txt",
        count: u32 = 1,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .output = .{ .short = 'o', .help = "Output file path", .value_name = "PATH" },
        .count = .{ .help = "Repeat count", .value_name = "COUNT" },
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS]
        \\
        \\Options:
        \\  -v, --verbose        Enable verbose output
        \\  -o, --output <PATH>  Output file path [default: out.txt]
        \\      --count <COUNT>  Repeat count [default: 1]
        \\  -h, --help           Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: subcommand listing" {
    const Command = union(enum) {
        clone: struct {},
        push: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        command: ?Command = null,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .command = .{},
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS] [COMMAND]
        \\
        \\Options:
        \\  -v, --verbose  Enable verbose output
        \\  -h, --help     Print help
        \\
        \\Commands:
        \\  clone
        \\  push
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: no meta fallback" {
    const Cli = struct { verbose: bool = false };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{}, stream.writer());
    const expected =
        \\Usage: PROGRAM [OPTIONS]
        \\
        \\Options:
        \\      --verbose  Enable verbose output
        \\  -h, --help     Print help
        \\
    ;
    // verbose has no help text and no short, so it shows differently
    // Let me recalculate: verbose has no .help field in config .{}
    _ = expected;

    // Actually with empty config, verbose has no help text
    const expected2 =
        \\Usage: PROGRAM [OPTIONS]
        \\
        \\Options:
        \\      --verbose
        \\  -h, --help     Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected2, stream.getWritten());
}

test "help: complete with all features" {
    const Command = union(enum) {
        clone: struct {},
        push: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        output: []const u8 = "out.txt",
        count: u32 = 1,
        input: []const u8,
        command: ?Command = null,
    };
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp", .about = "A sample CLI application" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .output = .{ .short = 'o', .help = "Output file path", .value_name = "PATH" },
        .count = .{ .help = "Repeat count", .value_name = "COUNT" },
        .input = .{ .positional = true, .help = "Input file" },
        .command = .{},
    }, stream.writer());
    const expected =
        \\A sample CLI application
        \\
        \\Usage: myapp [OPTIONS] <INPUT> [COMMAND]
        \\
        \\Arguments:
        \\  <INPUT>  Input file
        \\
        \\Options:
        \\  -v, --verbose        Enable verbose output
        \\  -o, --output <PATH>  Output file path [default: out.txt]
        \\      --count <COUNT>  Repeat count [default: 1]
        \\  -h, --help           Print help
        \\
        \\Commands:
        \\  clone
        \\  push
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: -h user-occupied shows --help only" {
    const Cli = struct {
        host: []const u8 = "localhost",
        verbose: bool = false,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .host = .{ .short = 'h', .help = "Hostname", .value_name = "HOST" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS]
        \\
        \\Options:
        \\  -h, --host <HOST>  Hostname [default: localhost]
        \\  -v, --verbose      Enable verbose output
        \\      --help         Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: both -h and --help user-occupied, no built-in help entry" {
    const Cli = struct {
        host: []const u8 = "localhost",
        help: bool = false,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .host = .{ .short = 'h', .help = "Hostname", .value_name = "HOST" },
        .help = .{ .help = "Show help" },
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS]
        \\
        \\Options:
        \\  -h, --host <HOST>  Hostname [default: localhost]
        \\      --help         Show help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: enum default display" {
    const Mode = enum { fast, slow, balanced };
    const Cli = struct {
        mode: Mode = .balanced,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .mode = .{ .help = "Processing mode" },
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS]
        \\
        \\Options:
        \\      --mode <MODE>  Processing mode [default: balanced]
        \\  -h, --help         Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: float default display" {
    const Cli = struct {
        rate: f64 = 1.5,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .rate = .{ .help = "Processing rate" },
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS]
        \\
        \\Options:
        \\      --rate <RATE>  Processing rate [default: 1.5]
        \\  -h, --help         Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "help: kebab-case subcommand names" {
    const Command = union(enum) {
        dry_run: struct {},
        init_db: struct {},
    };
    const Cli = struct {
        command: Command,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "myapp" },
        .command = .{},
    }, stream.writer());
    const expected =
        \\Usage: myapp [OPTIONS] <COMMAND>
        \\
        \\Options:
        \\  -h, --help  Print help
        \\
        \\Commands:
        \\  dry-run
        \\  init-db
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "golden: help with all field types" {
    const Command = union(enum) {
        build: struct {},
        test_cmd: struct {},
    };
    const Cli = struct {
        verbose: bool = false,
        output: []const u8 = "a.out",
        input: []const u8,
        files: []const []const u8 = &.{},
        command: ?Command = null,
    };
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "golden", .about = "Golden test CLI with all field types" },
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .output = .{ .short = 'o', .help = "Output file path", .value_name = "PATH" },
        .input = .{ .positional = true, .help = "Input file" },
        .files = .{ .positional = true, .help = "Additional files" },
        .command = .{},
    }, stream.writer());
    const expected =
        \\Golden test CLI with all field types
        \\
        \\Usage: golden [OPTIONS] <INPUT> [FILES...] [COMMAND]
        \\
        \\Arguments:
        \\  <INPUT>  Input file
        \\  [FILES...]  Additional files
        \\
        \\Options:
        \\  -v, --verbose        Enable verbose output
        \\  -o, --output <PATH>  Output file path [default: a.out]
        \\  -h, --help           Print help
        \\
        \\Commands:
        \\  build
        \\  test-cmd
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "golden: help with constraints" {
    const Cli = struct {
        json: bool = false,
        csv: bool = false,
        output: ?[]const u8 = null,
        format: ?[]const u8 = null,
    };
    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeHelp(Cli, .{
        ._meta = .{ .name = "fmt-tool", .about = "Format conversion tool" },
        .json = .{ .short = 'j', .help = "Use JSON output", .conflicts_with = &.{"csv"} },
        .csv = .{ .short = 'c', .help = "Use CSV output", .conflicts_with = &.{"json"} },
        .output = .{ .short = 'o', .help = "Output file path", .value_name = "PATH" },
        .format = .{ .help = "Output format string", .requires = &.{"output"} },
    }, stream.writer());
    // Constraint information is NOT displayed in help text (current behavior).
    // This test verifies that constraint settings do not break help output stability.
    const expected =
        \\Format conversion tool
        \\
        \\Usage: fmt-tool [OPTIONS]
        \\
        \\Options:
        \\  -j, --json             Use JSON output
        \\  -c, --csv              Use CSV output
        \\  -o, --output <PATH>    Output file path
        \\      --format <FORMAT>  Output format string
        \\  -h, --help             Print help
        \\
    ;
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}
