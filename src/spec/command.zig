const std = @import("std");
const arg = @import("arg.zig");
const ArgSpec = arg.ArgSpec;
const ArgKind = arg.ArgKind;
const FieldConfig = arg.FieldConfig;

pub fn CommandSpec(comptime n_args: usize) type {
    return struct {
        args: [n_args]ArgSpec,
        subcommand_field: ?[]const u8,
    };
}

pub fn buildSpec(comptime T: type, comptime config: anytype) CommandSpec(@typeInfo(T).@"struct".fields.len) {
    const fields = @typeInfo(T).@"struct".fields;
    var args: [fields.len]ArgSpec = undefined;
    var subcommand_field: ?[]const u8 = null;

    for (fields, 0..) |field, i| {
        const fc = arg.getFieldConfig(config, field.name);
        const kind = arg.argKind(field.type, fc);
        args[i] = .{
            .field_name = field.name,
            .short = fc.short,
            .long = arg.longName(field.name, fc),
            .help = fc.help,
            .value_name = fc.value_name,
            .kind = kind,
            .is_count = fc.action == .count,
            .has_default = field.default_value_ptr != null,
            .is_optional = @typeInfo(field.type) == .optional,
        };
        if (kind == .subcommand) {
            subcommand_field = field.name;
        }
    }

    return .{
        .args = args,
        .subcommand_field = subcommand_field,
    };
}
