const std = @import("std");

pub const Action = enum {
    set_true,
    count,
    set,
    append,
};

pub const ArgKind = enum {
    flag,
    option,
    operand,
};

pub const ArgSpec = struct {
    kind: ArgKind,
    value_type: type,
    action: Action,
    short: ?u8 = null,
    long: ?[]const u8 = null,
    required: bool = false,
    has_default: bool = false,
    default_value_ptr: ?*const anyopaque = null,
};

pub fn flag(comptime config: anytype) ArgSpec {
    return normalizeArg(.flag, void, .set_true, config);
}

pub fn option(comptime T: type, comptime config: anytype) ArgSpec {
    return normalizeArg(.option, T, .set, config);
}

pub fn operand(comptime T: type, comptime config: anytype) ArgSpec {
    return normalizeArg(.operand, T, .set, config);
}

fn normalizeArg(
    comptime kind: ArgKind,
    comptime T: type,
    comptime default_action: Action,
    comptime config: anytype,
) ArgSpec {
    const Config = @TypeOf(config);
    validateArgConfigFields(kind, Config);

    const has_default = @hasField(Config, "default");
    const default_value_ptr: ?*const anyopaque = if (has_default) blk: {
        const default_value: T = @field(config, "default");
        break :blk @ptrCast(&default_value);
    } else null;

    return .{
        .kind = kind,
        .value_type = T,
        .action = if (@hasField(Config, "action")) config.action else default_action,
        .short = if (@hasField(Config, "short")) config.short else null,
        .long = if (@hasField(Config, "long")) config.long else null,
        .required = if (@hasField(Config, "required")) config.required else false,
        .has_default = has_default,
        .default_value_ptr = default_value_ptr,
    };
}

fn validateArgConfigFields(comptime kind: ArgKind, comptime Config: type) void {
    const config_info = switch (@typeInfo(Config)) {
        .@"struct" => |info| info,
        else => @compileError("arg config must be a field-named struct literal"),
    };

    if (config_info.is_tuple and config_info.fields.len > 0) {
        @compileError("arg config must be a field-named struct literal");
    }

    inline for (config_info.fields) |field_info| {
        if (!isAllowedArgConfigField(kind, field_info.name)) {
            @compileError("unsupported config field '" ++ field_info.name ++ "' for " ++ @tagName(kind) ++ " argument");
        }
    }
}

fn isAllowedArgConfigField(comptime kind: ArgKind, comptime field_name: []const u8) bool {
    if (std.mem.eql(u8, field_name, "action")) return true;
    if (std.mem.eql(u8, field_name, "required")) return true;

    return switch (kind) {
        .flag => std.mem.eql(u8, field_name, "short") or
            std.mem.eql(u8, field_name, "long"),
        .option => std.mem.eql(u8, field_name, "short") or
            std.mem.eql(u8, field_name, "long") or
            std.mem.eql(u8, field_name, "default"),
        .operand => std.mem.eql(u8, field_name, "default"),
    };
}

pub fn validateCommandDeclaration(comptime declaration: anytype) void {
    const Declaration = @TypeOf(declaration);

    if (!@hasField(Declaration, "name")) {
        @compileError("command declaration must include a name field");
    }
    if (!@hasField(Declaration, "args")) {
        @compileError("command declaration must include an args field");
    }

    const args_info = switch (@typeInfo(@TypeOf(declaration.args))) {
        .@"struct" => |info| info,
        else => @compileError("command args must be a struct literal"),
    };

    if (args_info.is_tuple and args_info.fields.len > 0) {
        @compileError("command args must be a field-named struct literal");
    }

    validateArgs(declaration.args);
}

fn validateArgs(comptime args: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    comptime var seen_optional_operand = false;
    comptime var seen_variadic_operand = false;

    inline for (fields, 0..) |field_info, index| {
        const spec = @field(args, field_info.name);
        if (@TypeOf(spec) != ArgSpec) {
            @compileError("arg '" ++ field_info.name ++ "' must be created with parsz.flag, parsz.option, or parsz.operand");
        }

        validateArgSpec(field_info.name, spec);

        if (spec.kind == .operand) {
            if (seen_variadic_operand) {
                @compileError("arg '" ++ field_info.name ++ "' is an operand after a variadic operand");
            }

            if (spec.action == .set and spec.required and seen_optional_operand) {
                @compileError("arg '" ++ field_info.name ++ "' is a required operand after an optional operand");
            }

            if (spec.action == .append) {
                seen_variadic_operand = true;
            } else if (spec.action == .set and !spec.required) {
                seen_optional_operand = true;
            }
        }

        inline for (fields[0..index]) |previous_field_info| {
            const previous = @field(args, previous_field_info.name);
            validateNoDuplicateNames(field_info.name, spec, previous_field_info.name, previous);
        }
    }
}

fn validateArgSpec(comptime field_name: []const u8, comptime spec: ArgSpec) void {
    validateActionForKind(field_name, spec);

    if (spec.required and spec.has_default) {
        @compileError("arg '" ++ field_name ++ "' cannot be required and have a default value");
    }

    if (spec.has_default and spec.action != .set) {
        @compileError("arg '" ++ field_name ++ "' cannot have a default value unless its action is set");
    }

    if (spec.long) |long| {
        validateLongName(field_name, long);
    }

    if (spec.short) |short| {
        validateShortName(field_name, short);
    }
}

fn validateActionForKind(comptime field_name: []const u8, comptime spec: ArgSpec) void {
    switch (spec.kind) {
        .flag => switch (spec.action) {
            .set_true, .count => {},
            .set, .append => @compileError("arg '" ++ field_name ++ "' is a flag and must use set_true or count action"),
        },
        .option, .operand => switch (spec.action) {
            .set, .append => {},
            .set_true, .count => @compileError("arg '" ++ field_name ++ "' is not a flag and must use set or append action"),
        },
    }
}

fn validateLongName(comptime field_name: []const u8, comptime long: []const u8) void {
    if (long.len == 0) {
        @compileError("arg '" ++ field_name ++ "' has an empty long option name");
    }
    if (long[0] == '-') {
        @compileError("arg '" ++ field_name ++ "' has a long option name that begins with '-'");
    }

    for (long) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') {
            @compileError("arg '" ++ field_name ++ "' has a long option name containing a non ASCII alphanumeric or '-' byte");
        }
    }
}

fn validateShortName(comptime field_name: []const u8, comptime short: u8) void {
    if (!std.ascii.isAlphanumeric(short)) {
        @compileError("arg '" ++ field_name ++ "' has a short option name that is not an ASCII alphanumeric byte");
    }
}

fn validateNoDuplicateNames(
    comptime field_name: []const u8,
    comptime spec: ArgSpec,
    comptime previous_field_name: []const u8,
    comptime previous: ArgSpec,
) void {
    if (spec.long) |long| {
        if (previous.long) |previous_long| {
            if (std.mem.eql(u8, long, previous_long)) {
                @compileError("arg '" ++ field_name ++ "' duplicates long option name from arg '" ++ previous_field_name ++ "'");
            }
        }
    }

    if (spec.short) |short| {
        if (previous.short) |previous_short| {
            if (short == previous_short) {
                @compileError("arg '" ++ field_name ++ "' duplicates short option name from arg '" ++ previous_field_name ++ "'");
            }
        }
    }
}

pub fn buildResultType(comptime args: anytype) type {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    comptime {
        var names: [fields.len][:0]const u8 = undefined;
        var types: [fields.len]type = undefined;
        const attrs: [fields.len]std.builtin.Type.StructField.Attributes = @splat(.{});

        for (fields, 0..) |field_info, index| {
            const spec = @field(args, field_info.name);
            names[index] = field_info.name;
            types[index] = resultFieldType(spec);
        }

        return @Struct(.auto, null, &names, &types, &attrs);
    }
}

fn resultFieldType(comptime spec: ArgSpec) type {
    return switch (spec.action) {
        .set_true => bool,
        .count => u32,
        .set => if (spec.required or spec.has_default) spec.value_type else ?spec.value_type,
        .append => []const spec.value_type,
    };
}

pub fn initializeResultDefaults(comptime args: anytype, result: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (comptime canInitializeWithoutInput(spec)) {
            @field(result.*, field_info.name) = defaultFieldValue(spec);
        }
    }
}

fn canInitializeWithoutInput(comptime spec: ArgSpec) bool {
    return switch (spec.action) {
        .set_true, .count, .append => true,
        .set => !spec.required or spec.has_default,
    };
}

fn defaultFieldValue(comptime spec: ArgSpec) resultFieldType(spec) {
    return switch (spec.action) {
        .set_true => false,
        .count => 0,
        .set => if (spec.has_default) defaultValue(spec) else null,
        .append => &.{},
    };
}

fn defaultValue(comptime spec: ArgSpec) spec.value_type {
    const ptr: *const spec.value_type = @ptrCast(@alignCast(spec.default_value_ptr.?));
    return ptr.*;
}

pub fn deinitResult(comptime args: anytype, allocator: std.mem.Allocator, result: anytype) void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.action == .append) {
            const values = @field(result.*, field_info.name);
            if (values.len > 0) {
                allocator.free(values);
            }
            @field(result.*, field_info.name) = &.{};
        }
    }
}
