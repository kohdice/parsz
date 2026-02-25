const std = @import("std");
const spec_arg = @import("spec/arg.zig");
const FieldConfig = spec_arg.FieldConfig;
const argKind = spec_arg.argKind;
const getFieldConfig = spec_arg.getFieldConfig;
const longName = spec_arg.longName;
const isSubcommandType = spec_arg.isSubcommandType;

pub fn validate(comptime T: type, comptime config: anytype) void {
    const fields = @typeInfo(T).@"struct".fields;

    checkDuplicateShorts(fields, config);
    checkDuplicateLongs(fields, config);
    checkCountFieldTypes(fields, config);
    checkSingleSubcommand(fields, config);
    checkUnknownConfigKeys(T, fields, config);
    checkUnknownFieldConfigKeys(fields, config);
    checkUntaggedUnions(fields);
    checkPositionalOrdering(fields, config);
    checkCountPositionalConflict(fields, config);
    checkPositionalOptionConflict(fields, config);
}

fn checkDuplicateShorts(comptime fields: anytype, comptime config: anytype) void {
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
}

fn checkDuplicateLongs(comptime fields: anytype, comptime config: anytype) void {
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
}

fn checkCountFieldTypes(comptime fields: anytype, comptime config: anytype) void {
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

fn checkSingleSubcommand(comptime fields: anytype, comptime config: anytype) void {
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
}

fn checkUnknownConfigKeys(comptime T: type, comptime fields: anytype, comptime config: anytype) void {
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
}

fn checkUnknownFieldConfigKeys(comptime fields: anytype, comptime config: anytype) void {
    comptime {
        const Config = @TypeOf(config);
        const config_info = @typeInfo(Config);
        if (config_info == .@"struct" and Config != @TypeOf(.{})) {
            for (fields) |field| {
                const fc = getFieldConfig(config, field.name);
                const kind = argKind(field.type, fc);
                // Skip subcommand fields — their config values contain
                // variant names (e.g. .clone, .push), not FieldConfig keys.
                if (kind == .subcommand) continue;

                for (config_info.@"struct".fields) |cf| {
                    if (std.mem.eql(u8, cf.name, field.name)) {
                        const val = @field(config, field.name);
                        const ValType = @TypeOf(val);
                        if (ValType == FieldConfig) break;
                        const val_info = @typeInfo(ValType);
                        if (val_info != .@"struct") break;

                        for (val_info.@"struct".fields) |vf| {
                            const is_known = blk: {
                                for (@typeInfo(FieldConfig).@"struct".fields) |fc_field| {
                                    if (std.mem.eql(u8, vf.name, fc_field.name)) break :blk true;
                                }
                                break :blk false;
                            };
                            if (!is_known) {
                                @compileError("unknown field config key '" ++ vf.name ++ "' for field '" ++ field.name ++ "'");
                            }
                        }
                        break;
                    }
                }
            }
        }
    }
}

fn checkUntaggedUnions(comptime fields: anytype) void {
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
}

fn checkPositionalOrdering(comptime fields: anytype, comptime config: anytype) void {
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
}

fn checkCountPositionalConflict(comptime fields: anytype, comptime config: anytype) void {
    comptime {
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (fc.action == .count and fc.positional) {
                @compileError("field '" ++ field.name ++ "' has both .action = .count and .positional = true; these are mutually exclusive");
            }
        }
    }
}

fn checkPositionalOptionConflict(comptime fields: anytype, comptime config: anytype) void {
    comptime {
        for (fields) |field| {
            const fc = getFieldConfig(config, field.name);
            if (fc.positional) {
                if (fc.short != null) {
                    @compileError("field '" ++ field.name ++ "' has both .positional = true and .short option; positional fields cannot have short options");
                }
                if (fc.long != null) {
                    @compileError("field '" ++ field.name ++ "' has both .positional = true and explicit .long option; positional fields cannot have long options");
                }
            }
        }
    }
}

/// Subcommand config key validation.
/// Requires subcmd_field_name to produce the correct error message
/// with the SubUnion type name.
pub fn validateSubcommandConfig(
    comptime T: type,
    comptime config: anytype,
    comptime subcmd_field_name: []const u8,
) void {
    const fields = @typeInfo(T).@"struct".fields;
    const subcmd_field = comptime blk: {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, subcmd_field_name)) break :blk f;
        }
        unreachable;
    };
    const SubUnion = comptime switch (@typeInfo(subcmd_field.type)) {
        .optional => |opt| opt.child,
        else => subcmd_field.type,
    };
    const sub_fields = @typeInfo(SubUnion).@"union".fields;

    comptime {
        const Config = @TypeOf(config);
        const config_info = @typeInfo(Config);
        if (config_info == .@"struct" and Config != @TypeOf(.{})) {
            for (config_info.@"struct".fields) |cf| {
                if (std.mem.eql(u8, cf.name, subcmd_field_name)) {
                    const subcmd_config = @field(config, subcmd_field_name);
                    const SubConfig = @TypeOf(subcmd_config);
                    const sub_config_info = @typeInfo(SubConfig);
                    if (sub_config_info == .@"struct" and SubConfig != @TypeOf(.{})) {
                        for (sub_config_info.@"struct".fields) |vcf| {
                            var found = false;
                            for (sub_fields) |sf| {
                                if (std.mem.eql(u8, vcf.name, sf.name)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                @compileError(
                                    "unknown subcommand config key '" ++ vcf.name ++
                                        "' does not match any variant in " ++ @typeName(SubUnion),
                                );
                            }
                        }
                    }
                    break;
                }
            }
        }
    }
}
