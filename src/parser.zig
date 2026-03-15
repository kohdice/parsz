const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const errors = @import("errors.zig");
const ParseError = errors.ParseError;
const Diagnostic = errors.Diagnostic;
const FlagRef = errors.FlagRef;

const spec_arg = @import("spec/arg.zig");
pub const ArgKind = spec_arg.ArgKind;
pub const FieldConfig = spec_arg.FieldConfig;
pub const argKind = spec_arg.argKind;
pub const getFieldConfig = spec_arg.getFieldConfig;
pub const snakeToKebab = spec_arg.snakeToKebab;
const longName = spec_arg.longName;

fn convertValue(
    comptime T: type,
    raw: []const u8,
    diagnostic: ?*Diagnostic,
    comptime field_name: []const u8,
    comptime flag: FlagRef,
) ParseError!T {
    if (T == []const u8) return raw;
    if (T == bool) {
        if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        if (diagnostic) |d| d.* = .{
            .arg_name = field_name,
            .flag = flag,
            .provided_value = raw,
            .expected = "true or false",
        };
        return error.InvalidValue;
    }
    if (comptime @typeInfo(T) == .int) {
        return std.fmt.parseInt(T, raw, 0) catch |err| switch (err) {
            error.Overflow => {
                if (diagnostic) |d| d.* = .{
                    .arg_name = field_name,
                    .flag = flag,
                    .provided_value = raw,
                    .expected = @typeName(T),
                };
                return error.ValueOutOfRange;
            },
            error.InvalidCharacter => {
                if (diagnostic) |d| d.* = .{
                    .arg_name = field_name,
                    .flag = flag,
                    .provided_value = raw,
                    .expected = @typeName(T),
                };
                return error.InvalidValue;
            },
        };
    }
    if (comptime @typeInfo(T) == .float) {
        return std.fmt.parseFloat(T, raw) catch {
            if (diagnostic) |d| d.* = .{
                .arg_name = field_name,
                .flag = flag,
                .provided_value = raw,
                .expected = @typeName(T),
            };
            return error.InvalidValue;
        };
    }
    if (comptime @typeInfo(T) == .@"enum") {
        return std.meta.stringToEnum(T, raw) orelse {
            if (diagnostic) |d| d.* = .{
                .arg_name = field_name,
                .flag = flag,
                .provided_value = raw,
                .expected = comptime enumExpectedStr(T),
            };
            return error.InvalidValue;
        };
    }
    @compileError("unsupported value type: " ++ @typeName(T));
}

fn enumExpectedStr(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"enum".fields;
    var result: []const u8 = "one of: ";
    for (fields, 0..) |f, i| {
        if (i > 0) result = result ++ ", ";
        result = result ++ f.name;
    }
    return result;
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
    return parseCore(T, allocator, argv, config, null, null);
}

pub fn parseCore(
    comptime T: type,
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime config: anytype,
    diagnostic: ?*Diagnostic,
    comptime subcmd_field_name: ?[]const u8,
) (ParseError || error{OutOfMemory})!T {
    @setEvalBranchQuota(10_000);
    const validator = @import("validator.zig");
    comptime validator.validate(T, config);
    if (comptime subcmd_field_name != null) {
        comptime validator.validateSubcommandConfig(T, config, subcmd_field_name.?);
    }

    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    var result: T = undefined;
    var field_set = std.EnumSet(FieldEnum).initEmpty();
    var user_set = std.EnumSet(FieldEnum).initEmpty();
    var positional_index: usize = 0;

    // 1. Field initialization (shared)
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

    // 2. Multi list init + defer (shared)
    var lists = initMultiLists(T, config);
    defer deinitMultiLists(T, config, &lists, allocator);

    // 3. Subcommand-specific state (comptime guarded)
    const SubUnionInfo = comptime if (subcmd_field_name) |sfn| blk: {
        const subcmd_field = for (fields) |f| {
            if (std.mem.eql(u8, f.name, sfn)) break f;
        } else unreachable;
        break :blk .{ .field = subcmd_field, .SubUnion = unwrapOptional(subcmd_field.type) };
    } else .{ .field = @as(?void, null), .SubUnion = @as(?void, null) };

    var subcmd_parsed = false;

    // Subcommand errdefer (comptime guarded)
    if (comptime subcmd_field_name != null) {
        // We need errdefer logic here, but it must be structured differently.
        // See below — errdefer is placed unconditionally but guarded by subcmd_parsed.
    }

    // Errdefer for subcommand cleanup on error
    errdefer {
        if (comptime subcmd_field_name != null) {
            if (subcmd_parsed) {
                const SubUnion = comptime SubUnionInfo.SubUnion;
                const subcmd_field = comptime SubUnionInfo.field;
                if (@typeInfo(subcmd_field.type) == .optional) {
                    if (@field(result, subcmd_field_name.?)) |*sub| {
                        deinitSubcommand(SubUnion, sub, allocator, config, subcmd_field_name.?);
                    }
                } else {
                    deinitSubcommand(SubUnion, &@field(result, subcmd_field_name.?), allocator, config, subcmd_field_name.?);
                }
            }
        }
    }

    var tokenizer = Tokenizer{ .args = argv };

    // 4. GNU permutation: defer positional processing (non-subcommand mode only)
    // Always created but only used (appended to) in non-subcommand mode.
    // When unused, no heap allocation occurs and deinit is a no-op.
    var deferred_positionals: std.ArrayList([:0]const u8) = .{};
    defer deferred_positionals.deinit(allocator);

    // 5. Token dispatch loop
    while (tokenizer.next()) |token| {
        switch (token) {
            .long => |long| {
                if (!try handleLong(T, config, &result, &field_set, &user_set, &tokenizer, &lists, long, allocator, diagnostic)) {
                    return error.UnknownFlag;
                }
            },
            .short => |ch| {
                if (!try handleShort(T, config, &result, &field_set, &user_set, &tokenizer, &lists, ch, allocator, diagnostic))
                    return error.UnknownFlag;
            },
            .positional => |val| {
                if (comptime subcmd_field_name != null) {
                    // Subcommand mode: match subcommand names immediately
                    const SubUnion = comptime SubUnionInfo.SubUnion;
                    const subcmd_field = comptime SubUnionInfo.field;
                    const sub_fields = @typeInfo(SubUnion).@"union".fields;
                    const slice: []const u8 = val;
                    var found_sub = false;
                    if (!tokenizer.options_ended) {
                        inline for (sub_fields) |sf| {
                            if (std.mem.eql(u8, slice, comptime snakeToKebab(sf.name))) {
                                const remaining = tokenizer.args[tokenizer.index..];
                                const sub_config = comptime getSubVariantConfig(config, subcmd_field_name.?, sf.name);
                                const sub_result = try parseCore(sf.type, allocator, remaining, sub_config, diagnostic, comptime blk: {
                                    const inner_spec = @import("spec/command.zig").buildSpec(sf.type, sub_config);
                                    break :blk inner_spec.subcommand_field;
                                });
                                @field(result, subcmd_field_name.?) =
                                    if (@typeInfo(subcmd_field.type) == .optional)
                                        @unionInit(SubUnion, sf.name, sub_result)
                                    else
                                        @unionInit(SubUnion, sf.name, sub_result);
                                field_set.insert(@field(FieldEnum, subcmd_field_name.?));
                                user_set.insert(@field(FieldEnum, subcmd_field_name.?));
                                subcmd_parsed = true;
                                tokenizer.index = tokenizer.args.len;
                                found_sub = true;
                            }
                        }
                    }
                    if (!found_sub) {
                        if (!try handlePositional(T, config, &result, &field_set, &user_set, &lists, &positional_index, val, allocator, diagnostic)) {
                            const sub_fields_2 = @typeInfo(SubUnion).@"union".fields;
                            if (sub_fields_2.len > 0 and !subcmd_parsed and !tokenizer.options_ended) {
                                if (diagnostic) |d| d.* = .{ .provided_value = val };
                                return error.UnknownSubcommand;
                            } else {
                                if (diagnostic) |d| d.* = .{ .provided_value = val };
                                return error.TooManyPositionals;
                            }
                        }
                    }
                } else {
                    // Non-subcommand mode: GNU permutation (defer positionals)
                    try deferred_positionals.append(allocator, val);
                }
            },
            .end_of_options => {
                if (comptime subcmd_field_name == null) {
                    while (tokenizer.next()) |rest| {
                        switch (rest) {
                            .positional => |v| try deferred_positionals.append(allocator, v),
                            else => try deferred_positionals.append(allocator, tokenizer.args[tokenizer.index - 1]),
                        }
                    }
                }
                // Subcommand mode: end_of_options is a no-op (options_ended is tracked by tokenizer)
            },
        }
    }

    // 6. Deferred positionals processing (non-subcommand mode only)
    if (comptime subcmd_field_name == null) {
        for (deferred_positionals.items) |pos_val| {
            if (!try handlePositional(T, config, &result, &field_set, &user_set, &lists, &positional_index, pos_val, allocator, diagnostic)) {
                if (diagnostic) |d| d.* = .{ .provided_value = pos_val };
                return error.TooManyPositionals;
            }
        }
    }

    // 7. Mark multi fields as set (shared)
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (comptime argKind(field.type, fc) == .multi) {
            if (user_set.contains(@field(FieldEnum, field.name)) or
                field.default_value_ptr != null or
                @typeInfo(field.type) == .optional)
            {
                field_set.insert(@field(FieldEnum, field.name));
            }
        }
    }

    // 8. Required field check (shared)
    inline for (fields) |field| {
        if (!field_set.contains(@field(FieldEnum, field.name))) {
            const fc = comptime getFieldConfig(config, field.name);
            const kind = comptime argKind(field.type, fc);
            if (kind == .subcommand and @typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else if (kind == .subcommand) {
                if (diagnostic) |d| d.* = .{ .arg_name = field.name };
                return error.MissingSubcommand;
            } else {
                if (diagnostic) |d| d.* = .{
                    .arg_name = field.name,
                    .flag = if (comptime kind == .positional or (kind == .multi and fc.positional))
                        .none
                    else
                        .{ .long = comptime longName(field.name, fc) },
                };
                return error.MissingRequired;
            }
        }
    }

    // 8.25 required_unless_present check (user_set-based)
    {
        const constraint_engine = @import("constraint/engine.zig");
        inline for (fields) |field| {
            const fc = comptime getFieldConfig(config, field.name);
            if (comptime fc.required_unless_present.len > 0) {
                if (!user_set.contains(@field(FieldEnum, field.name))) {
                    if (!constraint_engine.checkRequiredUnlessPresent(T, config, user_set, field.name)) {
                        const kind = comptime argKind(field.type, fc);
                        if (diagnostic) |d| {
                            const spec_constraint = @import("spec/constraint.zig");
                            d.* = .{
                                .arg_name = field.name,
                                .flag = if (comptime kind == .positional or (kind == .multi and fc.positional))
                                    .none
                                else
                                    .{ .long = comptime longName(field.name, fc) },
                                .message = comptime spec_constraint.requiredUnlessMessage(config, fc.required_unless_present),
                            };
                        }
                        return error.MissingRequired;
                    }
                }
            }
        }
    }

    // 8.5 Constraint evaluation (conflicts_with, requires)
    {
        const constraint_engine = @import("constraint/engine.zig");
        try constraint_engine.evaluate(T, config, user_set, diagnostic);
    }

    // 9. Multi field finalization + errdefer (shared)
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
                const Child = comptime sliceChild(field.type);
                if (comptime @typeInfo(field.type) == .optional) {
                    if (@field(result, field.name)) |default_slice| {
                        if (default_slice.len > 0) {
                            @field(result, field.name) = try allocator.dupe(Child, default_slice);
                            finalized_multi.insert(@field(FieldEnum, field.name));
                        }
                    }
                } else {
                    const default_slice = @field(result, field.name);
                    if (default_slice.len > 0) {
                        @field(result, field.name) = try allocator.dupe(Child, default_slice);
                        finalized_multi.insert(@field(FieldEnum, field.name));
                    }
                }
            } else {
                @field(result, field.name) = try @field(lists, field.name).toOwnedSlice(allocator);
                finalized_multi.insert(@field(FieldEnum, field.name));
            }
        }
    }

    // 10. Subcommand multi-default normalization (comptime guarded)
    if (comptime subcmd_field_name != null) {
        const SubUnion = comptime SubUnionInfo.SubUnion;
        const subcmd_field = comptime SubUnionInfo.field;
        if (!subcmd_parsed) {
            if (comptime @typeInfo(subcmd_field.type) == .optional) {
                if (@field(result, subcmd_field_name.?)) |*sub| {
                    try normalizeSubcommandMultiDefaults(SubUnion, sub, allocator, config, subcmd_field_name.?);
                    @field(result, subcmd_field_name.?) = sub.*;
                }
            } else if (comptime subcmd_field.default_value_ptr != null) {
                try normalizeSubcommandMultiDefaults(SubUnion, &@field(result, subcmd_field_name.?), allocator, config, subcmd_field_name.?);
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
    user_set: anytype,
    tokenizer: *Tokenizer,
    lists: anytype,
    long: Token.Long,
    allocator: std.mem.Allocator,
    diagnostic: ?*Diagnostic,
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
                if (long.value != null) {
                    if (diagnostic) |d| d.* = .{
                        .arg_name = field.name,
                        .flag = .{ .long = comptime longName(field.name, fc) },
                        .provided_value = long.value.?,
                    };
                    return error.InvalidValue;
                }
                if (comptime fc.action == .count) {
                    if (field_set.contains(@field(FieldEnum, field.name))) {
                        @field(result, field.name) +|= 1;
                    } else {
                        @field(result, field.name) = 1;
                        field_set.insert(@field(FieldEnum, field.name));
                    }
                    user_set.insert(@field(FieldEnum, field.name));
                } else {
                    if (user_set.contains(@field(FieldEnum, field.name))) {
                        if (diagnostic) |d| d.* = .{
                            .arg_name = field.name,
                            .flag = .{ .long = comptime longName(field.name, fc) },
                        };
                        return error.DuplicateArg;
                    }
                    @field(result, field.name) = true;
                    field_set.insert(@field(FieldEnum, field.name));
                    user_set.insert(@field(FieldEnum, field.name));
                }
                return true;
            }

            const raw_value = long.value orelse blk: {
                const raw = tokenizer.nextRaw() orelse {
                    if (diagnostic) |d| d.* = .{
                        .arg_name = field.name,
                        .flag = .{ .long = comptime longName(field.name, fc) },
                        .expected = @typeName(comptime unwrapOptional(field.type)),
                    };
                    return error.MissingValue;
                };
                break :blk raw;
            };

            if (kind == .multi) {
                const Child = comptime sliceChild(field.type);
                const converted = try convertValue(Child, raw_value, diagnostic, field.name, .{ .long = comptime longName(field.name, fc) });
                try @field(lists, field.name).append(allocator, converted);
                user_set.insert(@field(FieldEnum, field.name));
                return true;
            }

            // option: duplicate check for required (no default) fields
            if (user_set.contains(@field(FieldEnum, field.name)) and
                field.default_value_ptr == null and
                @typeInfo(field.type) != .optional)
            {
                if (diagnostic) |d| d.* = .{
                    .arg_name = field.name,
                    .flag = .{ .long = comptime longName(field.name, fc) },
                };
                return error.DuplicateArg;
            }

            const ValueType = comptime unwrapOptional(field.type);
            const converted = try convertValue(ValueType, raw_value, diagnostic, field.name, .{ .long = comptime longName(field.name, fc) });
            @field(result, field.name) = converted;
            field_set.insert(@field(FieldEnum, field.name));
            user_set.insert(@field(FieldEnum, field.name));
            return true;
        }
    }
    // Built-in help flag (only if no user field matched)
    if (comptime hasBuiltinHelpLong(T, config)) {
        if (std.mem.eql(u8, long.name, "help")) {
            if (long.value != null) {
                if (diagnostic) |d| d.* = .{
                    .arg_name = "help",
                    .flag = .{ .long = "help" },
                    .provided_value = long.value.?,
                };
                return error.InvalidValue;
            }
            return error.HelpRequested;
        }
    }
    // Unknown long flag
    if (diagnostic) |d| d.* = .{
        .flag = .{ .long = long.name },
    };
    return false;
}

pub fn handleShort(
    comptime T: type,
    comptime config: anytype,
    result: *T,
    field_set: anytype,
    user_set: anytype,
    tokenizer: *Tokenizer,
    lists: anytype,
    ch: u8,
    allocator: std.mem.Allocator,
    diagnostic: ?*Diagnostic,
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
                        user_set.insert(@field(FieldEnum, field.name));
                    } else {
                        if (user_set.contains(@field(FieldEnum, field.name))) {
                            if (diagnostic) |d| d.* = .{
                                .arg_name = field.name,
                                .flag = .{ .short = s },
                            };
                            return error.DuplicateArg;
                        }
                        @field(result, field.name) = true;
                        field_set.insert(@field(FieldEnum, field.name));
                        user_set.insert(@field(FieldEnum, field.name));
                    }
                    return true;
                }

                // Use remaining characters in the short cluster as an inline value (e.g. -ofile.txt)
                const raw_value: []const u8 = if (tokenizer.short_remaining.len > 0) blk: {
                    const val = tokenizer.short_remaining;
                    tokenizer.short_remaining = "";
                    break :blk val;
                } else blk: {
                    const raw = tokenizer.nextRaw() orelse {
                        if (diagnostic) |d| d.* = .{
                            .arg_name = field.name,
                            .flag = .{ .short = s },
                            .expected = @typeName(comptime unwrapOptional(field.type)),
                        };
                        return error.MissingValue;
                    };
                    break :blk raw;
                };

                if (kind == .multi) {
                    const Child = comptime sliceChild(field.type);
                    const converted = try convertValue(Child, raw_value, diagnostic, field.name, .{ .short = s });
                    try @field(lists, field.name).append(allocator, converted);
                    user_set.insert(@field(FieldEnum, field.name));
                    return true;
                }

                if (user_set.contains(@field(FieldEnum, field.name)) and
                    field.default_value_ptr == null and
                    @typeInfo(field.type) != .optional)
                {
                    if (diagnostic) |d| d.* = .{
                        .arg_name = field.name,
                        .flag = .{ .short = s },
                    };
                    return error.DuplicateArg;
                }

                const ValueType = comptime unwrapOptional(field.type);
                const converted = try convertValue(ValueType, raw_value, diagnostic, field.name, .{ .short = s });
                @field(result, field.name) = converted;
                field_set.insert(@field(FieldEnum, field.name));
                user_set.insert(@field(FieldEnum, field.name));
                return true;
            }
        }
    }
    // Built-in help flag (only if no user field matched)
    if (comptime hasBuiltinHelpShort(T, config)) {
        if (ch == 'h') {
            return error.HelpRequested;
        }
    }
    // Unknown short flag
    if (diagnostic) |d| d.* = .{
        .flag = .{ .short = ch },
    };
    return false;
}

pub fn handlePositional(
    comptime T: type,
    comptime config: anytype,
    result: *T,
    field_set: anytype,
    user_set: anytype,
    lists: anytype,
    positional_index: *usize,
    raw_value: [:0]const u8,
    allocator: std.mem.Allocator,
    diagnostic: ?*Diagnostic,
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
                const converted = try convertValue(ValueType, raw_value, diagnostic, field.name, .none);
                @field(result, field.name) = converted;
                field_set.insert(@field(FieldEnum, field.name));
                user_set.insert(@field(FieldEnum, field.name));
                positional_index.* += 1;
                return true;
            }
            current_pos += 1;
        } else if (kind == .multi and comptime fc.positional) {
            if (current_pos == positional_index.*) {
                const Child = comptime sliceChild(field.type);
                const converted = try convertValue(Child, raw_value, diagnostic, field.name, .none);
                try @field(lists, field.name).append(allocator, converted);
                user_set.insert(@field(FieldEnum, field.name));
                return true;
            }
            current_pos += 1;
        }
    }

    // Too many positionals — write diagnostic before caller returns error
    if (diagnostic) |d| d.* = .{
        .provided_value = raw_value,
    };
    return false;
}

pub fn deinitResult(comptime T: type, result: *T, allocator: std.mem.Allocator, comptime config: anytype) void {
    deinitFields(T, result, allocator, config);
}

pub fn deinitFields(comptime T: type, result: *T, allocator: std.mem.Allocator, comptime config: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);
        if (kind == .multi) {
            if (comptime @typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |s| {
                    allocator.free(s);
                }
                @field(result, field.name) = null;
            } else {
                allocator.free(@field(result, field.name));
                @field(result, field.name) = &.{};
            }
        } else if (kind == .subcommand) {
            const SubType = comptime unwrapOptional(field.type);
            if (@typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |*sub| {
                    deinitSubcommand(SubType, sub, allocator, config, field.name);
                }
            } else {
                deinitSubcommand(SubType, &@field(result, field.name), allocator, config, field.name);
            }
        }
    }
}

pub fn deinitSubcommand(
    comptime SubUnion: type,
    sub: *SubUnion,
    allocator: std.mem.Allocator,
    comptime config: anytype,
    comptime subcmd_field_name: []const u8,
) void {
    const sub_ufields = @typeInfo(SubUnion).@"union".fields;
    inline for (sub_ufields) |sf| {
        if (sub.* == @field(std.meta.FieldEnum(SubUnion), sf.name)) {
            const sub_config = comptime getSubVariantConfig(config, subcmd_field_name, sf.name);
            var payload = @field(sub, sf.name);
            deinitFields(sf.type, &payload, allocator, sub_config);
            sub.* = @unionInit(SubUnion, sf.name, payload);
        }
    }
}

pub fn getSubVariantConfig(comptime config: anytype, comptime subcmd_field_name: []const u8, comptime variant_name: []const u8) SubVariantConfigType(config, subcmd_field_name, variant_name) {
    const Config = @TypeOf(config);
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return .{};

    inline for (config_info.@"struct".fields) |cf| {
        if (comptime std.mem.eql(u8, cf.name, subcmd_field_name)) {
            const subcmd_config = @field(config, subcmd_field_name);
            const SubConfig = @TypeOf(subcmd_config);
            const sub_info = @typeInfo(SubConfig);
            if (sub_info != .@"struct") return .{};

            inline for (sub_info.@"struct".fields) |vf| {
                if (comptime std.mem.eql(u8, vf.name, variant_name)) {
                    return @field(subcmd_config, variant_name);
                }
            }
            return .{};
        }
    }
    return .{};
}

fn SubVariantConfigType(comptime config: anytype, comptime subcmd_field_name: []const u8, comptime variant_name: []const u8) type {
    const Config = @TypeOf(config);
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return @TypeOf(.{});

    for (config_info.@"struct".fields) |cf| {
        if (std.mem.eql(u8, cf.name, subcmd_field_name)) {
            const subcmd_config = @field(config, subcmd_field_name);
            const SubConfig = @TypeOf(subcmd_config);
            const sub_info = @typeInfo(SubConfig);
            if (sub_info != .@"struct") return @TypeOf(.{});

            for (sub_info.@"struct".fields) |vf| {
                if (std.mem.eql(u8, vf.name, variant_name)) {
                    return @TypeOf(@field(subcmd_config, variant_name));
                }
            }
            return @TypeOf(.{});
        }
    }
    return @TypeOf(.{});
}

pub fn normalizeMultiDefaults(
    comptime T: type,
    result: *T,
    allocator: std.mem.Allocator,
    comptime config: anytype,
) error{OutOfMemory}!void {
    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    var normalized = std.EnumSet(FieldEnum).initEmpty();
    errdefer {
        inline for (fields) |field| {
            const fc = comptime getFieldConfig(config, field.name);
            const kind = comptime argKind(field.type, fc);
            if (kind == .multi) {
                if (normalized.contains(@field(FieldEnum, field.name))) {
                    if (comptime @typeInfo(field.type) == .optional) {
                        if (@field(result, field.name)) |s| allocator.free(s);
                    } else {
                        allocator.free(@field(result, field.name));
                    }
                }
            } else if (kind == .subcommand) {
                if (normalized.contains(@field(FieldEnum, field.name))) {
                    const SubType = comptime unwrapOptional(field.type);
                    if (@typeInfo(field.type) == .optional) {
                        if (@field(result, field.name)) |*sub| {
                            deinitSubcommand(SubType, sub, allocator, config, field.name);
                        }
                    } else {
                        deinitSubcommand(SubType, &@field(result, field.name), allocator, config, field.name);
                    }
                }
            }
        }
    }

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);
        if (kind == .multi) {
            const Child = comptime sliceChild(field.type);
            if (comptime @typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |slice| {
                    if (slice.len > 0) {
                        @field(result, field.name) = try allocator.dupe(Child, slice);
                        normalized.insert(@field(FieldEnum, field.name));
                    }
                }
            } else {
                const slice = @field(result, field.name);
                if (slice.len > 0) {
                    @field(result, field.name) = try allocator.dupe(Child, slice);
                    normalized.insert(@field(FieldEnum, field.name));
                }
            }
        } else if (kind == .subcommand) {
            const SubType = comptime unwrapOptional(field.type);
            if (@typeInfo(field.type) == .optional) {
                if (@field(result, field.name)) |*sub| {
                    try normalizeSubcommandMultiDefaults(SubType, sub, allocator, config, field.name);
                    normalized.insert(@field(FieldEnum, field.name));
                }
            } else {
                try normalizeSubcommandMultiDefaults(SubType, &@field(result, field.name), allocator, config, field.name);
                normalized.insert(@field(FieldEnum, field.name));
            }
        }
    }
}

pub fn normalizeSubcommandMultiDefaults(
    comptime SubUnion: type,
    sub: *SubUnion,
    allocator: std.mem.Allocator,
    comptime config: anytype,
    comptime subcmd_field_name: []const u8,
) error{OutOfMemory}!void {
    const sub_ufields = @typeInfo(SubUnion).@"union".fields;
    inline for (sub_ufields) |sf| {
        if (sub.* == @field(std.meta.FieldEnum(SubUnion), sf.name)) {
            const sub_config = comptime getSubVariantConfig(config, subcmd_field_name, sf.name);
            var payload = @field(sub, sf.name);
            try normalizeMultiDefaults(sf.type, &payload, allocator, sub_config);
            sub.* = @unionInit(SubUnion, sf.name, payload);
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

test "parser: bool flag default true first use succeeds" {
    const T = struct { flag: bool = true };
    const result = try parseArgs(T, std.testing.allocator, &.{"--flag"}, .{});
    try std.testing.expect(result.flag == true);
}

test "parser: bool flag default true duplicate returns DuplicateArg" {
    const T = struct { flag: bool = true };
    const result = parseArgs(T, std.testing.allocator, &.{ "--flag", "--flag" }, .{});
    try std.testing.expectError(error.DuplicateArg, result);
}

test "parser: bool flag default true short first use succeeds" {
    const T = struct { flag: bool = true };
    const result = try parseArgs(T, std.testing.allocator, &.{"-f"}, .{
        .flag = .{ .short = 'f' },
    });
    try std.testing.expect(result.flag == true);
}

test "parser: bool flag default false first use succeeds" {
    const T = struct { verbose: bool = false };
    const result = try parseArgs(T, std.testing.allocator, &.{"--verbose"}, .{});
    try std.testing.expect(result.verbose == true);
}

test "parser: bool flag default false duplicate returns DuplicateArg" {
    const T = struct { verbose: bool = false };
    const result = parseArgs(T, std.testing.allocator, &.{ "--verbose", "--verbose" }, .{});
    try std.testing.expectError(error.DuplicateArg, result);
}

test "parser: bool flag long short mixed duplicate returns DuplicateArg" {
    const T = struct { verbose: bool = false };
    const result = parseArgs(T, std.testing.allocator, &.{ "--verbose", "-v" }, .{
        .verbose = .{ .short = 'v' },
    });
    try std.testing.expectError(error.DuplicateArg, result);
}

pub fn hasBuiltinHelpShort(comptime T: type, comptime config: anytype) bool {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        if (fc.short) |s| {
            if (s == 'h') return false;
        }
    }
    return true;
}

pub fn hasBuiltinHelpLong(comptime T: type, comptime config: anytype) bool {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);
        const kind = comptime argKind(field.type, fc);
        if (kind == .subcommand or kind == .positional or (kind == .multi and fc.positional)) continue;
        if (std.mem.eql(u8, comptime longName(field.name, fc), "help")) return false;
    }
    return true;
}
