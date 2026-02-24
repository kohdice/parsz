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
    const info = @typeInfo(T);
    if (info != .@"union") return false;
    return info.@"union".tag_type != null;
}

fn isOptionalSubcommandType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    return isSubcommandType(info.optional.child);
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
            if (kind == .flag or kind == .option or (kind == .multi and !fc.positional)) {
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

    comptime {
        var subcommand_count: usize = 0;
        var first_subcmd_name: []const u8 = "";
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (argKind(field.type, fc) == .subcommand) {
                if (subcommand_count == 0) {
                    first_subcmd_name = field.name;
                } else {
                    @compileError("multiple subcommand fields found: '" ++ first_subcmd_name ++ "' and '" ++ field.name ++ "'; only one subcommand field is allowed per struct");
                }
                subcommand_count += 1;
            }
        }
    }

    comptime {
        const Config = @TypeOf(config);
        const config_info = @typeInfo(Config);
        if (config_info == .@"struct" and Config != @TypeOf(.{})) {
            for (config_info.@"struct".fields) |cf| {
                var found = false;
                for (fields) |field| {
                    if (std.mem.eql(u8, cf.name, field.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("unknown config key '" ++ cf.name ++ "' does not match any field in " ++ @typeName(T));
                }
            }
        }
    }

    comptime {
        for (fields) |field| {
            const F = field.type;
            const is_bare_union = @typeInfo(F) == .@"union" and !isSubcommandType(F);
            const is_optional_bare_union = blk: {
                const fi = @typeInfo(F);
                if (fi != .optional) break :blk false;
                break :blk @typeInfo(fi.optional.child) == .@"union" and !isSubcommandType(fi.optional.child);
            };
            if (is_bare_union) {
                @compileError("field '" ++ field.name ++ "' has type '" ++ @typeName(F) ++ "' which is an untagged union; union fields must be tagged (union(enum))");
            }
            if (is_optional_bare_union) {
                @compileError("field '" ++ field.name ++ "' has type '" ++ @typeName(F) ++ "' which wraps an untagged union; union fields must be tagged (union(enum))");
            }
        }
    }

    comptime {
        var seen_multi_positional = false;
        var multi_positional_name: []const u8 = "";
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            const kind = argKind(field.type, fc);
            if (kind == .positional and seen_multi_positional) {
                @compileError("positional field '" ++ field.name ++ "' comes after multi-value positional '" ++ multi_positional_name ++ "'; multi-value positional must be the last positional field");
            }
            if (kind == .multi and fc.positional) {
                if (seen_multi_positional) {
                    @compileError("multiple multi-value positional fields found: '" ++ multi_positional_name ++ "' and '" ++ field.name ++ "'; only one multi-value positional is allowed");
                }
                seen_multi_positional = true;
                multi_positional_name = field.name;
            }
        }
    }

    comptime {
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (fc.action == .count and fc.positional) {
                @compileError("field '" ++ field.name ++ "' has both .action = .count and .positional = true; these are mutually exclusive");
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

pub fn sliceChild(comptime T: type) type {
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

    // Track which multi fields have been heap-allocated during finalization.
    // errdefer inside inline for is block-scoped per iteration and does not
    // accumulate, so we use a single errdefer outside the loop with an EnumSet.
    var finalized_multi = std.EnumSet(FieldEnum).initEmpty();
    errdefer {
        inline for (fields) |field| {
            const fc = comptime getFieldConfig(config, field.name);
            if (comptime argKind(field.type, fc) == .multi) {
                if (finalized_multi.contains(@field(FieldEnum, field.name))) {
                    if (comptime @typeInfo(field.type) == .optional) {
                        if (@field(result, field.name)) |s| allocator.free(s);
                    } else {
                        allocator.free(@field(result, field.name));
                    }
                }
            }
        }
    }

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            if (@field(lists, field.name).items.len == 0 and field.default_value_ptr != null) {
                // Preserve default. Copy non-empty defaults to heap for uniform deinit.
                const Child = comptime sliceChild(field.type);
                if (comptime @typeInfo(field.type) == .optional) {
                    if (@field(result, field.name)) |default_slice| {
                        if (default_slice.len > 0) {
                            @field(result, field.name) = try allocator.dupe(Child, default_slice);
                            finalized_multi.insert(@field(FieldEnum, field.name));
                        }
                        // len == 0: keep &.{}, free is no-op
                    }
                    // null: keep null, deinit skips null
                } else {
                    const default_slice = @field(result, field.name);
                    if (default_slice.len > 0) {
                        @field(result, field.name) = try allocator.dupe(Child, default_slice);
                        finalized_multi.insert(@field(FieldEnum, field.name));
                    }
                    // len == 0: keep &.{}, free is no-op
                }
            } else {
                @field(result, field.name) = try @field(lists, field.name).toOwnedSlice(allocator);
                finalized_multi.insert(@field(FieldEnum, field.name));
            }
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

        if (kind == .subcommand or kind == .positional or (kind == .multi and fc.positional)) continue;

        const ln = comptime longName(field.name, fc);
        if (std.mem.eql(u8, long.name, ln)) {
            if (kind == .flag) {
                if (long.value != null) return error.InvalidValue;
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
        const kind = comptime argKind(field.type, fc);

        if (kind == .subcommand or kind == .positional or (kind == .multi and fc.positional)) continue;

        if (comptime fc.short) |s| {
            if (s == ch) {
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
    // Default null is preserved when no values are specified.
    try std.testing.expect(result.ports == null);
}

test "parser: bool flag rejects inline value" {
    const T = struct { verbose: bool = false };
    const result = parseArgs(T, std.testing.allocator, &.{"--verbose=false"}, .{});
    try std.testing.expectError(error.InvalidValue, result);
}

test "parser: bool flag rejects inline value arbitrary" {
    const T = struct { verbose: bool = false };
    const result = parseArgs(T, std.testing.allocator, &.{"--verbose=typo"}, .{});
    try std.testing.expectError(error.InvalidValue, result);
}

test "parser: count flag rejects inline value" {
    const T = struct { verbose: u8 = 0 };
    const result = parseArgs(T, std.testing.allocator, &.{"--verbose=1"}, .{
        .verbose = .{ .short = 'v', .action = .count },
    });
    try std.testing.expectError(error.InvalidValue, result);
}

test "parser: multi field preserves non-empty default" {
    const T = struct { ports: []const u16 = &.{ 80, 443 } };
    var result = try parseArgs(T, std.testing.allocator, &.{}, .{});
    defer deinitResult(T, &result, std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 2), result.ports.len);
    try std.testing.expectEqual(@as(u16, 80), result.ports[0]);
    try std.testing.expectEqual(@as(u16, 443), result.ports[1]);
}

test "parser: multi field default overridden when values specified" {
    const T = struct { ports: []const u16 = &.{ 80, 443 } };
    var result = try parseArgs(T, std.testing.allocator, &.{ "--ports", "8080" }, .{});
    defer deinitResult(T, &result, std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 1), result.ports.len);
    try std.testing.expectEqual(@as(u16, 8080), result.ports[0]);
}

test "parser: tagged union subcommand still works after strictening" {
    // Verify that isSubcommandType and isOptionalSubcommandType correctly
    // classify union(enum) as .subcommand after the strictening change.
    const Command = union(enum) {
        run: struct {},
        build: struct {},
    };
    try std.testing.expectEqual(ArgKind.subcommand, comptime argKind(Command, .{}));
    try std.testing.expectEqual(ArgKind.subcommand, comptime argKind(?Command, .{}));

    // Untagged union should NOT be classified as subcommand.
    const BadUnion = union { a: i32, b: f64 };
    try std.testing.expectEqual(ArgKind.option, comptime argKind(BadUnion, .{}));
}

test "parser: multi positional as last field" {
    const T = struct {
        target: []const u8,
        files: []const []const u8 = &.{},
    };
    var result = try parseArgs(T, std.testing.allocator, &.{ "output", "a.zig", "b.zig" }, .{
        .target = .{ .positional = true },
        .files = .{ .positional = true },
    });
    defer deinitResult(T, &result, std.testing.allocator, .{
        .target = .{ .positional = true },
        .files = .{ .positional = true },
    });
    try std.testing.expectEqualStrings("output", result.target);
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try std.testing.expectEqualStrings("a.zig", result.files[0]);
    try std.testing.expectEqualStrings("b.zig", result.files[1]);
}

test "parser: no leak on OOM during multi field finalization" {
    const T = struct {
        ports: []const u16 = &.{},
        tags: []const []const u8 = &.{},
    };
    const argv: []const [:0]const u8 = &.{ "--ports", "80", "--tags", "web" };

    for (0..20) |fail_index| {
        var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        if (parseArgs(T, failing_allocator_state.allocator(), argv, .{})) |r| {
            var result = r;
            deinitResult(T, &result, failing_allocator_state.allocator(), .{});
            break;
        } else |_| {
            // Expected OOM — std.testing.allocator detects leaks automatically.
        }
    }
}
