const std = @import("std");
const arg = @import("arg.zig");
const FieldConfig = arg.FieldConfig;
const getFieldConfig = arg.getFieldConfig;
const longName = arg.longName;

pub fn fieldExists(comptime fields: anytype, comptime name: []const u8) bool {
    inline for (fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn formatArgRef(comptime field_name: []const u8, comptime config: anytype) []const u8 {
    comptime {
        const fc = getFieldConfig(config, field_name);
        if (fc.positional) return "'" ++ field_name ++ "'";
        const ln = longName(field_name, fc);
        if (fc.short) |s| return "'-" ++ &[1]u8{s} ++ "/--" ++ ln ++ "'";
        return "'--" ++ ln ++ "'";
    }
}

pub fn conflictsMessage(comptime config: anytype, comptime target_name: []const u8) []const u8 {
    comptime return "cannot be used with " ++ formatArgRef(target_name, config);
}

pub fn requiresMessage(comptime config: anytype, comptime target_name: []const u8) []const u8 {
    comptime return "requires " ++ formatArgRef(target_name, config);
}

pub fn requiredUnlessMessage(comptime config: anytype, comptime targets: []const []const u8) []const u8 {
    comptime {
        if (targets.len == 1) {
            return "required unless " ++ formatArgRef(targets[0], config) ++ " is present";
        }
        var msg: []const u8 = "required unless one of ";
        for (targets, 0..) |t, i| {
            if (i > 0) msg = msg ++ ", ";
            msg = msg ++ formatArgRef(t, config);
        }
        return msg ++ " is present";
    }
}
