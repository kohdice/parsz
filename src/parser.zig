const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const errors = @import("errors.zig");
const ParseError = errors.ParseError;
const Diagnostic = errors.Diagnostic;

pub const ArgKind = enum {
    flag,
    option,
    positional,
    multi,
    subcommand,
};

pub fn argKind(comptime F: type, comptime fc: FieldConfig) ArgKind {
    if (isSubcommandType(F)) return .subcommand;
    if (isOptionalSubcommandType(F)) return .subcommand;
    if (F == bool) return .flag;
    if (fc.action == .count) return .flag;
    if (isSliceOfNonU8(F)) return .multi;
    if (isOptionalSliceOfNonU8(F)) return .multi;
    if (fc.positional) return .positional;
    return .option;
}

fn isSubcommandType(comptime T: type) bool {
    return @typeInfo(T) == .@"union";
}

fn isOptionalSubcommandType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    return @typeInfo(info.optional.child) == .@"union";
}

fn isSliceOfNonU8(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    if (info.pointer.size != .slice) return false;
    return info.pointer.child != u8;
}

fn isOptionalSliceOfNonU8(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    return isSliceOfNonU8(info.optional.child);
}

pub const FieldConfig = struct {
    short: ?u8 = null,
    long: ?[]const u8 = null,
    help: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
    positional: bool = false,
    action: Action = .set,

    pub const Action = enum { set, count };
};

pub fn getFieldConfig(comptime config: anytype, comptime field_name: []const u8) FieldConfig {
    if (@TypeOf(config) == @TypeOf(.{})) return .{};
    const Config = @TypeOf(config);
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return .{};

    inline for (config_info.@"struct".fields) |cf| {
        if (comptime std.mem.eql(u8, cf.name, field_name)) {
            const val = @field(config, field_name);
            const ValType = @TypeOf(val);
            if (ValType == FieldConfig) return val;

            const val_info = @typeInfo(ValType);
            if (val_info != .@"struct") return .{};

            var result = FieldConfig{};
            inline for (val_info.@"struct".fields) |vf| {
                if (comptime std.mem.eql(u8, vf.name, "short")) result.short = @field(val, "short");
                if (comptime std.mem.eql(u8, vf.name, "long")) result.long = @field(val, "long");
                if (comptime std.mem.eql(u8, vf.name, "help")) result.help = @field(val, "help");
                if (comptime std.mem.eql(u8, vf.name, "value_name")) result.value_name = @field(val, "value_name");
                if (comptime std.mem.eql(u8, vf.name, "positional")) result.positional = @field(val, "positional");
                if (comptime std.mem.eql(u8, vf.name, "action")) result.action = @field(val, "action");
            }
            return result;
        }
    }
    return .{};
}

pub fn snakeToKebab(comptime name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (name) |c| {
            result = result ++ (if (c == '_') "-" else &[1]u8{c});
        }
        return result;
    }
}

fn longName(comptime field_name: []const u8, comptime fc: FieldConfig) []const u8 {
    if (fc.long) |l| return l;
    return comptime snakeToKebab(field_name);
}

pub fn validateConfig(comptime T: type, comptime config: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;

    comptime {
        var shorts_used: []const u8 = "";
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (fc.short) |s| {
                for (shorts_used) |existing| {
                    if (existing == s) {
                        @compileError("duplicate short option: -" ++ &[1]u8{s});
                    }
                }
                shorts_used = shorts_used ++ &[1]u8{s};
            }
        }
    }

    comptime {
        var longs_used: []const []const u8 = &.{};
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            const kind = argKind(field.type, fc);
            if (kind == .flag or kind == .option or kind == .multi) {
                const ln = longName(field.name, fc);
                for (longs_used) |existing| {
                    if (std.mem.eql(u8, existing, ln)) {
                        @compileError("duplicate long option: --" ++ ln);
                    }
                }
                longs_used = longs_used ++ .{ln};
            }
        }
    }

    comptime {
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (fc.action == .count) {
                if (@typeInfo(field.type) != .int) {
                    @compileError("field '" ++ field.name ++ "' uses .count action but has non-integer type '" ++ @typeName(field.type) ++ "'");
                }
            }
        }
    }
}

fn convertValue(comptime T: type, raw: []const u8) ParseError!T {
    if (T == []const u8) return raw;
    if (T == bool) {
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return error.InvalidValue;
    }
    if (comptime @typeInfo(T) == .int) {
        return std.fmt.parseInt(T, raw, 0) catch |err| switch (err) {
            error.Overflow => return error.ValueOutOfRange,
            error.InvalidCharacter => return error.InvalidValue,
        };
    }
    if (comptime @typeInfo(T) == .float) {
        return std.fmt.parseFloat(T, raw) catch return error.InvalidValue;
    }
    if (comptime @typeInfo(T) == .@"enum") {
        return std.meta.stringToEnum(T, raw) orelse return error.InvalidValue;
    }
    @compileError("unsupported value type: " ++ @typeName(T));
}

pub fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |opt| opt.child,
        else => T,
    };
}

fn sliceChild(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .optional) return sliceChild(info.optional.child);
    return info.pointer.child;
}

fn MultiLists(comptime T: type, comptime config: anytype) type {
    const fields = @typeInfo(T).@"struct".fields;
    var struct_fields: []const std.builtin.Type.StructField = &.{};

    for (fields) |field| {
        const fc = getFieldConfig(config, field.name);
        if (argKind(field.type, fc) == .multi) {
            const Child = sliceChild(field.type);
            const ListType = std.ArrayList(Child);
            struct_fields = struct_fields ++ .{std.builtin.Type.StructField{
                .name = field.name,
                .type = ListType,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(ListType),
            }};
        }
    }

    if (struct_fields.len == 0) {
        return struct {};
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub fn initMultiLists(comptime T: type, comptime config: anytype) MultiLists(T, config) {
    var lists: MultiLists(T, config) = undefined;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            @field(lists, field.name) = .{};
        }
    }
    return lists;
}

pub fn deinitMultiLists(comptime T: type, comptime config: anytype, lists: *MultiLists(T, config), allocator: std.mem.Allocator) void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            @field(lists, field.name).deinit(allocator);
        }
    }
}

pub fn parseArgs(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime config: anytype,
) (ParseError || error{OutOfMemory})!T {
    @setEvalBranchQuota(10_000);
    comptime validateConfig(T, config);

    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    var result: T = undefined;
    var field_set = std.EnumSet(FieldEnum).initEmpty();
    var positional_index: usize = 0;

    inline for (fields) |field| {
        if (field.default_value_ptr) |ptr| {
            const default = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
            @field(result, field.name) = default;
            field_set.insert(@field(FieldEnum, field.name));
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
            field_set.insert(@field(FieldEnum, field.name));
        }
    }

    var lists = initMultiLists(T, config);
    defer deinitMultiLists(T, config, &lists, allocator);

    var tokenizer = Tokenizer{ .args = argv };

    // GNU permutation: defer positional processing so options can appear after positionals
    var deferred_positionals: std.ArrayList([:0]const u8) = .{};
    defer deferred_positionals.deinit(allocator);

    while (tokenizer.next()) |token| {
        switch (token) {
            .long => |long| {
                if (!try handleLong(T, config, &result, &field_set, &tokenizer, &lists, long, allocator))
                    return error.UnknownFlag;
            },
            .short => |ch| {
                if (!try handleShort(T, config, &result, &field_set, &tokenizer, &lists, ch, allocator))
                    return error.UnknownFlag;
            },
            .positional => |val| {
                try deferred_positionals.append(allocator, val);
            },
            .end_of_options => {
                while (tokenizer.next()) |rest| {
                    switch (rest) {
                        .positional => |val| try deferred_positionals.append(allocator, val),
                        else => try deferred_positionals.append(allocator, tokenizer.args[tokenizer.index - 1]),
                    }
                }
            },
        }
    }

    for (deferred_positionals.items) |pos_val| {
        if (!try handlePositional(T, config, &result, &field_set, &lists, &positional_index, pos_val, allocator))
            return error.TooManyPositionals;
    }

    // Mark multi fields as set before required-field check.
    // Multi fields always produce a valid (possibly empty) slice,
    // so they are never "missing". This must happen before the
    // required check to avoid leaking toOwnedSlice allocations on error.
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            field_set.insert(@field(FieldEnum, field.name));
        }
    }

    inline for (fields) |field| {
        if (!field_set.contains(@field(FieldEnum, field.name))) {
            const fc = comptime getFieldConfig(config, field.name);
            const kind = comptime argKind(field.type, fc);
            if (kind == .subcommand) {
                if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                    continue;
                }
                return error.MissingSubcommand;
            }
            return error.MissingRequired;
        }
    }

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            @field(result, field.name) = try @field(lists, field.name).toOwnedSlice(allocator);
        }
    }

    return result;
}

pub fn handleLong(
    comptime T: type,
    comptime config: anytype,
    result: *T,
    field_set: anytype,
    tokenizer: *Tokenizer,
    lists: anytype,
    long: Token.Long,
    allocator: std.mem.Allocator,
) (ParseError || error{OutOfMemory})!bool {
    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);

        if (kind == .subcommand or kind == .positional) continue;

        const ln = comptime longName(field.name, fc);
        if (std.mem.eql(u8, long.name, ln)) {
            if (kind == .flag) {
                if (comptime fc.action == .count) {
                    if (field_set.contains(@field(FieldEnum, field.name))) {
                        @field(result, field.name) +|= 1;
                    } else {
                        @field(result, field.name) = 1;
                        field_set.insert(@field(FieldEnum, field.name));
                    }
                } else {
                    if (field_set.contains(@field(FieldEnum, field.name)) and
                        @field(result, field.name) == true)
                        return error.DuplicateArg;
                    @field(result, field.name) = true;
                    field_set.insert(@field(FieldEnum, field.name));
                }
                return true;
            }

            const raw_value = long.value orelse
                (tokenizer.nextRaw() orelse return error.MissingValue);

            if (kind == .multi) {
                const Child = comptime sliceChild(field.type);
                const converted = try convertValue(Child, raw_value);
                try @field(lists, field.name).append(allocator, converted);
                return true;
            }

            // option: duplicate check for required (no default) fields
            if (field_set.contains(@field(FieldEnum, field.name)) and
                field.default_value_ptr == null and
                @typeInfo(field.type) != .optional)
                return error.DuplicateArg;

            const ValueType = comptime unwrapOptional(field.type);
            const converted = try convertValue(ValueType, raw_value);
            @field(result, field.name) = converted;
            field_set.insert(@field(FieldEnum, field.name));
            return true;
        }
    }
    return false;
}

pub fn handleShort(
    comptime T: type,
    comptime config: anytype,
    result: *T,
    field_set: anytype,
    tokenizer: *Tokenizer,
    lists: anytype,
    ch: u8,
    allocator: std.mem.Allocator,
) (ParseError || error{OutOfMemory})!bool {
    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime fc.short) |s| {
            if (s == ch) {
                const kind = comptime argKind(field.type, fc);
                if (kind == .flag) {
                    if (comptime fc.action == .count) {
                        if (field_set.contains(@field(FieldEnum, field.name))) {
                            @field(result, field.name) +|= 1;
                        } else {
                            @field(result, field.name) = 1;
                            field_set.insert(@field(FieldEnum, field.name));
                        }
                    } else {
                        if (field_set.contains(@field(FieldEnum, field.name)) and
                            @field(result, field.name) == true)
                            return error.DuplicateArg;
                        @field(result, field.name) = true;
                        field_set.insert(@field(FieldEnum, field.name));
                    }
                    return true;
                }

                // Use remaining characters in the short cluster as an inline value (e.g. -ofile.txt)
                const raw_value: []const u8 = if (tokenizer.short_remaining.len > 0) blk: {
                    const val = tokenizer.short_remaining;
                    tokenizer.short_remaining = "";
                    break :blk val;
                } else (tokenizer.nextRaw() orelse return error.MissingValue);

                if (kind == .multi) {
                    const Child = comptime sliceChild(field.type);
                    const converted = try convertValue(Child, raw_value);
                    try @field(lists, field.name).append(allocator, converted);
                    return true;
                }

                if (field_set.contains(@field(FieldEnum, field.name)) and
                    field.default_value_ptr == null and
                    @typeInfo(field.type) != .optional)
                    return error.DuplicateArg;

                const ValueType = comptime unwrapOptional(field.type);
                const converted = try convertValue(ValueType, raw_value);
                @field(result, field.name) = converted;
                field_set.insert(@field(FieldEnum, field.name));
                return true;
            }
        }
    }
    return false;
}

pub fn handlePositional(
    comptime T: type,
    comptime config: anytype,
    result: *T,
    field_set: anytype,
    lists: anytype,
    positional_index: *usize,
    raw_value: [:0]const u8,
    allocator: std.mem.Allocator,
) (ParseError || error{OutOfMemory})!bool {
    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    var current_pos: usize = 0;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);
        if (kind == .positional) {
            if (current_pos == positional_index.*) {
                const ValueType = comptime unwrapOptional(field.type);
                const converted = try convertValue(ValueType, raw_value);
                @field(result, field.name) = converted;
                field_set.insert(@field(FieldEnum, field.name));
                positional_index.* += 1;
                return true;
            }
            current_pos += 1;
        } else if (kind == .multi and comptime fc.positional) {
            if (current_pos == positional_index.*) {
                const Child = comptime sliceChild(field.type);
                const converted = try convertValue(Child, raw_value);
                try @field(lists, field.name).append(allocator, converted);
                return true;
            }
            current_pos += 1;
        }
    }

    return false;
}

pub fn deinitResult(comptime T: type, result: *T, allocator: std.mem.Allocator, comptime config: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            if (comptime @typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |s| {
                    allocator.free(s);
                }
                @field(result, field.name) = null;
            } else {
                allocator.free(@field(result, field.name));
                @field(result, field.name) = &.{};
            }
        }
    }
}

test "parser: bool flag with long" {
    const T = struct { verbose: bool = false };
    const result = try parseArgs(T, std.testing.allocator, &.{"--verbose"}, .{});
    try std.testing.expect(result.verbose == true);
}

test "parser: bool flag with short" {
    const T = struct { verbose: bool = false };
    const result = try parseArgs(T, std.testing.allocator, &.{"-v"}, .{
        .verbose = .{ .short = 'v' },
    });
    try std.testing.expect(result.verbose == true);
}

test "parser: string option with long" {
    const T = struct { output: []const u8 = "default" };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--output", "file.txt" }, .{});
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parser: string option with inline value" {
    const T = struct { output: []const u8 = "default" };
    const result = try parseArgs(T, std.testing.allocator, &.{"--output=file.txt"}, .{});
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parser: integer positional" {
    const T = struct { count: u32 };
    const result = try parseArgs(T, std.testing.allocator, &.{"42"}, .{
        .count = .{ .positional = true },
    });
    try std.testing.expectEqual(@as(u32, 42), result.count);
}

test "parser: optional field null" {
    const T = struct { config_path: ?[]const u8 = null };
    const result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    try std.testing.expect(result.config_path == null);
}

test "parser: optional field with value" {
    const T = struct { config_path: ?[]const u8 = null };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--config-path", "cfg.toml" }, .{});
    try std.testing.expectEqualStrings("cfg.toml", result.config_path.?);
}

test "parser: optional field without explicit default" {
    const T = struct { config_path: ?[]const u8 };
    const result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    try std.testing.expect(result.config_path == null);
}

test "parser: optional field without explicit default with value" {
    const T = struct { config_path: ?[]const u8 };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--config-path", "cfg.toml" }, .{});
    try std.testing.expectEqualStrings("cfg.toml", result.config_path.?);
}

test "parser: optional integer without explicit default" {
    const T = struct { port: ?u16 };
    const result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    try std.testing.expect(result.port == null);
}

test "parser: optional integer without explicit default with value" {
    const T = struct { port: ?u16 };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--port", "8080" }, .{});
    try std.testing.expectEqual(@as(u16, 8080), result.port.?);
}

test "parser: missing required" {
    const T = struct { host: []const u8 };
    const result = parseArgs(T, std.testing.allocator, &.{}, .{
        .host = .{ .positional = true },
    });
    try std.testing.expectError(error.MissingRequired, result);
}

test "parser: unknown flag" {
    const T = struct { verbose: bool = false };
    const result = parseArgs(T, std.testing.allocator, &.{"--unknown"}, .{});
    try std.testing.expectError(error.UnknownFlag, result);
}

test "parser: invalid integer value" {
    const T = struct { count: u32 = 0 };
    const result = parseArgs(T, std.testing.allocator, &.{ "--count", "abc" }, .{});
    try std.testing.expectError(error.InvalidValue, result);
}

test "parser: integer overflow" {
    const T = struct { port: u16 = 0 };
    const result = parseArgs(T, std.testing.allocator, &.{ "--port", "99999" }, .{});
    try std.testing.expectError(error.ValueOutOfRange, result);
}

test "parser: enum value" {
    const Mode = enum { fast, slow, balanced };
    const T = struct { mode: Mode = .balanced };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--mode", "fast" }, .{});
    try std.testing.expectEqual(Mode.fast, result.mode);
}

test "parser: invalid enum value" {
    const Mode = enum { fast, slow, balanced };
    const T = struct { mode: Mode = .balanced };
    const result = parseArgs(T, std.testing.allocator, &.{ "--mode", "invalid" }, .{});
    try std.testing.expectError(error.InvalidValue, result);
}

test "parser: short clustering flags" {
    const T = struct {
        a_flag: bool = false,
        b_flag: bool = false,
        c_flag: bool = false,
    };
    const result = try parseArgs(T, std.testing.allocator, &.{"-abc"}, .{
        .a_flag = .{ .short = 'a' },
        .b_flag = .{ .short = 'b' },
        .c_flag = .{ .short = 'c' },
    });
    try std.testing.expect(result.a_flag);
    try std.testing.expect(result.b_flag);
    try std.testing.expect(result.c_flag);
}

test "parser: short with inline value" {
    const T = struct { output: []const u8 = "default" };
    const result = try parseArgs(T, std.testing.allocator, &.{"-ofile.txt"}, .{
        .output = .{ .short = 'o' },
    });
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parser: end of options" {
    const T = struct {
        verbose: bool = false,
        file: []const u8,
    };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--verbose", "--", "--not-a-flag" }, .{
        .file = .{ .positional = true },
    });
    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("--not-a-flag", result.file);
}

test "parser: positional argument" {
    const T = struct { input: []const u8 };
    const result = try parseArgs(T, std.testing.allocator, &.{"file.txt"}, .{
        .input = .{ .positional = true },
    });
    try std.testing.expectEqualStrings("file.txt", result.input);
}

test "parser: default values" {
    const T = struct {
        verbose: bool = false,
        output: []const u8 = "out.txt",
        port: u16 = 8080,
    };
    const result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    try std.testing.expect(!result.verbose);
    try std.testing.expectEqualStrings("out.txt", result.output);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "parser: multiple values" {
    const T = struct { ports: []const u16 = &.{} };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{});
    defer std.testing.allocator.free(result.ports);
    try std.testing.expectEqual(@as(usize, 2), result.ports.len);
    try std.testing.expectEqual(@as(u16, 80), result.ports[0]);
    try std.testing.expectEqual(@as(u16, 443), result.ports[1]);
}

test "parser: snake_case to kebab-case" {
    const T = struct { output_file: []const u8 = "default" };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--output-file", "out.txt" }, .{});
    try std.testing.expectEqualStrings("out.txt", result.output_file);
}

test "parser: count action with short" {
    const T = struct { verbose: u8 = 0 };
    const result = try parseArgs(T, std.testing.allocator, &.{ "-v", "-v", "-v" }, .{
        .verbose = .{ .short = 'v', .action = .count },
    });
    try std.testing.expectEqual(@as(u8, 3), result.verbose);
}

test "parser: GNU permutation" {
    const T = struct {
        verbose: bool = false,
        file: []const u8,
    };
    const result = try parseArgs(T, std.testing.allocator, &.{ "file.txt", "--verbose" }, .{
        .file = .{ .positional = true },
    });
    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("file.txt", result.file);
}

test "parser: dash as positional" {
    const T = struct { file: []const u8 };
    const result = try parseArgs(T, std.testing.allocator, &.{"-"}, .{
        .file = .{ .positional = true },
    });
    try std.testing.expectEqualStrings("-", result.file);
}

test "parser: float option" {
    const T = struct { rate: f64 = 1.0 };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--rate", "3.14" }, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.rate, 0.001);
}

test "parser: count with long flag" {
    const T = struct { verbose: u8 = 0 };
    const result = try parseArgs(T, std.testing.allocator, &.{ "--verbose", "--verbose" }, .{
        .verbose = .{ .short = 'v', .action = .count },
    });
    try std.testing.expectEqual(@as(u8, 2), result.verbose);
}

test "parser: missing value for option" {
    const T = struct { output: []const u8 = "default" };
    const result = parseArgs(T, std.testing.allocator, &.{"--output"}, .{});
    try std.testing.expectError(error.MissingValue, result);
}

test "parser: short option with separate value" {
    const T = struct { output: []const u8 = "default" };
    const result = try parseArgs(T, std.testing.allocator, &.{ "-o", "file.txt" }, .{
        .output = .{ .short = 'o' },
    });
    try std.testing.expectEqualStrings("file.txt", result.output);
}

test "parser: no leak when multi field set but required field missing" {
    const T = struct {
        ports: []const u16 = &.{},
        host: []const u8,
    };
    const result = parseArgs(T, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{
        .host = .{ .positional = true },
    });
    try std.testing.expectError(error.MissingRequired, result);
}

test "parser: optional multi field" {
    const T = struct { ports: ?[]const u16 = null };
    var result = try parseArgs(T, std.testing.allocator, &.{ "--ports", "80", "--ports", "443" }, .{});
    defer deinitResult(T, &result, std.testing.allocator, .{});
    try std.testing.expect(result.ports != null);
    try std.testing.expectEqual(@as(usize, 2), result.ports.?.len);
    try std.testing.expectEqual(@as(u16, 80), result.ports.?[0]);
    try std.testing.expectEqual(@as(u16, 443), result.ports.?[1]);
}

test "parser: optional multi field empty" {
    const T = struct { ports: ?[]const u16 = null };
    var result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    defer deinitResult(T, &result, std.testing.allocator, .{});
    // toOwnedSlice always produces a non-null (possibly empty) slice,
    // so the default null is overwritten with an empty slice.
    try std.testing.expect(result.ports != null);
    try std.testing.expectEqual(@as(usize, 0), result.ports.?.len);
}
