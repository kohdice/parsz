const std = @import("std");

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

pub fn isSubcommandType(comptime T: type) bool {
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

pub fn longName(comptime field_name: []const u8, comptime fc: FieldConfig) []const u8 {
    if (fc.long) |l| return l;
    return comptime snakeToKebab(field_name);
}

pub const MetaConfig = struct {
    name: ?[]const u8 = null,
    about: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub fn getMetaConfig(comptime config: anytype) MetaConfig {
    const Config = @TypeOf(config);
    if (Config == @TypeOf(.{})) return .{};
    const config_info = @typeInfo(Config);
    if (config_info != .@"struct") return .{};

    inline for (config_info.@"struct".fields) |cf| {
        if (comptime std.mem.eql(u8, cf.name, "_meta")) {
            const val = @field(config, "_meta");
            const ValType = @TypeOf(val);
            if (ValType == MetaConfig) return val;

            const val_info = @typeInfo(ValType);
            if (val_info != .@"struct") return .{};

            var result = MetaConfig{};
            inline for (val_info.@"struct".fields) |vf| {
                if (comptime std.mem.eql(u8, vf.name, "name")) result.name = @field(val, "name");
                if (comptime std.mem.eql(u8, vf.name, "about")) result.about = @field(val, "about");
                if (comptime std.mem.eql(u8, vf.name, "version")) result.version = @field(val, "version");
            }
            return result;
        }
    }
    return .{};
}

pub const ArgSpec = struct {
    field_name: []const u8,
    short: ?u8,
    long: []const u8,
    help: ?[]const u8,
    value_name: ?[]const u8,
    kind: ArgKind,
    is_count: bool,
    has_default: bool,
    is_optional: bool,
};
