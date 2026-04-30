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

pub const StandardControl = enum {
    help,
    version,
};

pub const StandardControls = struct {
    help: bool = false,
    version: bool = false,
};

pub const LongOptionResolution = union(enum) {
    arg: usize,
    control: StandardControl,
};

pub const LongOptionResolutionResult = union(enum) {
    none,
    one: LongOptionResolution,
    ambiguous,
};

pub const LongOption = struct {
    name: []const u8,
    resolution: LongOptionResolution,
};

pub const VersionMetadata = struct {
    number: []const u8,
    details: []const u8,
};

pub const ArgSpec = struct {
    kind: ArgKind,
    value_type: type,
    action: Action,
    short: ?u8 = null,
    long: ?[]const u8 = null,
    help: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
    required: bool = false,
    has_default: bool = false,
    default_value_ptr: ?*const anyopaque = null,
};

pub fn standardControlLongName(control: StandardControl) []const u8 {
    return switch (control) {
        .help => "help",
        .version => "version",
    };
}

pub fn resolveExactLongOption(
    comptime long_options: []const LongOption,
    name: []const u8,
) ?LongOptionResolution {
    inline for (long_options) |long_option| {
        if (std.mem.eql(u8, name, long_option.name)) {
            return long_option.resolution;
        }
    }

    return null;
}

pub fn resolveAbbreviatedLongOption(
    comptime long_options: []const LongOption,
    prefix: []const u8,
) LongOptionResolutionResult {
    var matches: usize = 0;
    var resolution: LongOptionResolution = undefined;

    inline for (long_options) |long_option| {
        if (std.mem.startsWith(u8, long_option.name, prefix)) {
            matches += 1;
            resolution = long_option.resolution;
        }
    }

    return switch (matches) {
        0 => .none,
        1 => .{ .one = resolution },
        else => .ambiguous,
    };
}

pub fn buildLongOptions(
    comptime args: anytype,
    comptime controls: StandardControls,
) [longOptionCount(args, controls)]LongOption {
    comptime {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        var long_options: [longOptionCount(args, controls)]LongOption = undefined;
        var index: usize = 0;

        for (fields, 0..) |field_info, arg_index| {
            const spec = @field(args, field_info.name);
            if (spec.kind != .operand) {
                if (spec.long) |long| {
                    long_options[index] = .{
                        .name = long,
                        .resolution = .{ .arg = arg_index },
                    };
                    index += 1;
                }
            }
        }

        if (controls.help) {
            long_options[index] = .{
                .name = standardControlLongName(.help),
                .resolution = .{ .control = .help },
            };
            index += 1;
        }
        if (controls.version) {
            long_options[index] = .{
                .name = standardControlLongName(.version),
                .resolution = .{ .control = .version },
            };
            index += 1;
        }

        if (index != long_options.len) {
            @compileError("internal long option count mismatch");
        }

        return long_options;
    }
}

fn longOptionCount(comptime args: anytype, comptime controls: StandardControls) comptime_int {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    comptime var count = 0;

    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.kind != .operand and spec.long != null) {
            count += 1;
        }
    }

    if (controls.help) {
        count += 1;
    }
    if (controls.version) {
        count += 1;
    }

    return count;
}

pub fn flag(comptime config: anytype) ArgSpec {
    return normalizeArg(.flag, void, .set_true, config);
}

pub fn option(comptime T: type, comptime config: anytype) ArgSpec {
    return normalizeArg(.option, T, .set, config);
}

pub fn operand(comptime T: type, comptime config: anytype) ArgSpec {
    return normalizeArg(.operand, T, .set, config);
}

pub fn version(comptime config: anytype) VersionMetadata {
    const Config = @TypeOf(config);
    validateVersionConfigFields(Config);

    if (!@hasField(Config, "number")) {
        @compileError("version metadata must include a number field");
    }
    if (!@hasField(Config, "details")) {
        @compileError("version metadata must include a details field");
    }

    validateNonEmptyTextField("version number", config.number);
    validateNonEmptyTextField("version details", config.details);

    return .{
        .number = config.number,
        .details = config.details,
    };
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
    const help_text: ?[]const u8 = if (@hasField(Config, "help")) blk: {
        validateTextField("arg help", config.help);
        break :blk config.help;
    } else null;
    const value_name: ?[]const u8 = if (@hasField(Config, "value_name")) blk: {
        validateNonEmptyTextField("arg value_name", config.value_name);
        break :blk config.value_name;
    } else null;

    return .{
        .kind = kind,
        .value_type = T,
        .action = if (@hasField(Config, "action")) config.action else default_action,
        .short = if (@hasField(Config, "short")) config.short else null,
        .long = if (@hasField(Config, "long")) config.long else null,
        .help = help_text,
        .value_name = value_name,
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
    if (std.mem.eql(u8, field_name, "help")) return true;

    return switch (kind) {
        .flag => std.mem.eql(u8, field_name, "short") or
            std.mem.eql(u8, field_name, "long"),
        .option => std.mem.eql(u8, field_name, "short") or
            std.mem.eql(u8, field_name, "long") or
            std.mem.eql(u8, field_name, "default") or
            std.mem.eql(u8, field_name, "value_name"),
        .operand => std.mem.eql(u8, field_name, "default") or
            std.mem.eql(u8, field_name, "value_name"),
    };
}

pub fn validateCommandDeclaration(comptime declaration: anytype) void {
    const Declaration = @TypeOf(declaration);
    validateCommandFields(Declaration);

    if (!@hasField(Declaration, "name")) {
        @compileError("command declaration must include a name field");
    }
    if (!@hasField(Declaration, "args")) {
        @compileError("command declaration must include an args field");
    }

    validateNonEmptyTextField("command name", declaration.name);
    if (@hasField(Declaration, "about")) {
        validateTextField("command about", declaration.about);
    }
    if (@hasField(Declaration, "version")) {
        validateVersionMetadata(declaration.version);
    }
    if (@hasField(Declaration, "subcommands")) {
        validateSubcommands(declaration.subcommands);
    }

    const args_info = switch (@typeInfo(@TypeOf(declaration.args))) {
        .@"struct" => |info| info,
        else => @compileError("command args must be a struct literal"),
    };

    if (args_info.is_tuple and args_info.fields.len > 0) {
        @compileError("command args must be a field-named struct literal");
    }

    validateArgs(declaration.args);
    if (@hasField(Declaration, "subcommands")) {
        validateNoOperandsWithSubcommands(declaration.args, declaration.subcommands);
    }
    validateNoDuplicateLongOptions(declaration.args, .{
        .help = true,
        .version = @hasField(Declaration, "version"),
    });
}

fn validateCommandFields(comptime Declaration: type) void {
    const declaration_info = switch (@typeInfo(Declaration)) {
        .@"struct" => |info| info,
        else => @compileError("command declaration must be a field-named struct literal"),
    };

    if (declaration_info.is_tuple) {
        @compileError("command declaration must be a field-named struct literal");
    }

    inline for (declaration_info.fields) |field_info| {
        if (!isAllowedCommandField(field_info.name)) {
            @compileError("unsupported command field '" ++ field_info.name ++ "'");
        }
    }
}

fn isAllowedCommandField(comptime field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "name") or
        std.mem.eql(u8, field_name, "about") or
        std.mem.eql(u8, field_name, "version") or
        std.mem.eql(u8, field_name, "args") or
        std.mem.eql(u8, field_name, "subcommands");
}

fn validateSubcommands(comptime subcommands: anytype) void {
    const subcommands_info = switch (@typeInfo(@TypeOf(subcommands))) {
        .@"struct" => |info| info,
        else => @compileError("command subcommands must be a field-named struct literal"),
    };

    if (subcommands_info.is_tuple and subcommands_info.fields.len > 0) {
        @compileError("command subcommands must be a field-named struct literal");
    }

    inline for (subcommands_info.fields, 0..) |field_info, index| {
        const Child = @field(subcommands, field_info.name);
        if (@TypeOf(Child) != type or !@hasDecl(Child, "is_parsz_command")) {
            @compileError("subcommand '" ++ field_info.name ++ "' must be created with parsz.Command");
        }

        inline for (subcommands_info.fields[0..index]) |previous_field_info| {
            const Previous = @field(subcommands, previous_field_info.name);
            if (std.mem.eql(u8, Child.name, Previous.name)) {
                @compileError("subcommand '" ++ field_info.name ++ "' duplicates command name from subcommand '" ++ previous_field_info.name ++ "'");
            }
        }
    }
}

fn validateNoOperandsWithSubcommands(comptime args: anytype, comptime subcommands: anytype) void {
    if (@typeInfo(@TypeOf(subcommands)).@"struct".fields.len == 0) {
        return;
    }

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field_info| {
        if (@field(args, field_info.name).kind == .operand) {
            @compileError("arg '" ++ field_info.name ++ "' cannot be an operand because command declares subcommands");
        }
    }
}

pub fn buildSubcommandResultType(comptime subcommands: anytype) type {
    const fields = @typeInfo(@TypeOf(subcommands)).@"struct".fields;

    comptime {
        if (fields.len == 0) {
            @compileError("internal subcommand result type requires at least one subcommand");
        }

        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;

        for (fields, 0..) |field_info, index| {
            const Child = @field(subcommands, field_info.name);
            names[index] = field_info.name;
            types[index] = Child.Result;
        }

        const Tag = std.meta.FieldEnum(@TypeOf(subcommands));
        return @Union(.auto, Tag, &names, &types, &@splat(.{}));
    }
}

fn validateVersionConfigFields(comptime Config: type) void {
    const config_info = switch (@typeInfo(Config)) {
        .@"struct" => |info| info,
        else => @compileError("version metadata must be a field-named struct literal"),
    };

    if (config_info.is_tuple and config_info.fields.len > 0) {
        @compileError("version metadata must be a field-named struct literal");
    }

    inline for (config_info.fields) |field_info| {
        if (!isAllowedVersionField(field_info.name)) {
            @compileError("unsupported version metadata field '" ++ field_info.name ++ "'");
        }
    }
}

fn isAllowedVersionField(comptime field_name: []const u8) bool {
    return std.mem.eql(u8, field_name, "number") or
        std.mem.eql(u8, field_name, "details");
}

fn validateVersionMetadata(comptime value: anytype) void {
    if (@TypeOf(value) != VersionMetadata) {
        @compileError("command version must be created with parsz.version");
    }
}

fn validateTextField(comptime field_description: []const u8, comptime value: anytype) void {
    if (!isTextType(@TypeOf(value))) {
        @compileError(field_description ++ " must be text");
    }
}

fn validateNonEmptyTextField(comptime field_description: []const u8, comptime value: anytype) void {
    validateTextField(field_description, value);
    if (value.len == 0) {
        @compileError(field_description ++ " must not be empty");
    }
}

fn isTextType(comptime Value: type) bool {
    return switch (@typeInfo(Value)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
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

            if (spec.required and seen_optional_operand) {
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
            validateNoDuplicateShortName(field_info.name, spec, previous_field_info.name, previous);
        }
    }
}

fn validateNoDuplicateLongOptions(comptime args: anytype, comptime controls: StandardControls) void {
    const long_options = buildLongOptions(args, controls);

    inline for (long_options, 0..) |long_option, index| {
        inline for (long_options[0..index]) |previous| {
            if (std.mem.eql(u8, long_option.name, previous.name)) {
                duplicateLongOptionError(args, long_option.resolution, previous.resolution);
            }
        }
    }
}

fn duplicateLongOptionError(
    comptime args: anytype,
    comptime current: LongOptionResolution,
    comptime previous: LongOptionResolution,
) noreturn {
    switch (current) {
        .arg => |current_arg_index| switch (previous) {
            .arg => |previous_arg_index| @compileError("arg '" ++ argFieldName(args, current_arg_index) ++ "' duplicates long option name from arg '" ++ argFieldName(args, previous_arg_index) ++ "'"),
            .control => |control| @compileError("arg '" ++ argFieldName(args, current_arg_index) ++ "' duplicates standard " ++ @tagName(control) ++ " option"),
        },
        .control => |control| switch (previous) {
            .arg => |arg_index| @compileError("arg '" ++ argFieldName(args, arg_index) ++ "' duplicates standard " ++ @tagName(control) ++ " option"),
            .control => @compileError("standard " ++ @tagName(control) ++ " option is duplicated"),
        },
    }
}

fn argFieldName(comptime args: anytype, comptime arg_index: usize) []const u8 {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    return fields[arg_index].name;
}

fn validateArgSpec(comptime field_name: []const u8, comptime spec: ArgSpec) void {
    validateActionForKind(field_name, spec);
    validateValueTypeForKind(field_name, spec);

    if (spec.required and spec.has_default) {
        @compileError("arg '" ++ field_name ++ "' cannot be required and have a default value");
    }

    if (spec.has_default and spec.action != .set) {
        @compileError("arg '" ++ field_name ++ "' cannot have a default value unless its action is set");
    }

    if (spec.kind != .operand and spec.short == null and spec.long == null) {
        @compileError("arg '" ++ field_name ++ "' must declare a short or long option name");
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

fn validateValueTypeForKind(comptime field_name: []const u8, comptime spec: ArgSpec) void {
    switch (spec.kind) {
        .flag => {},
        .option, .operand => if (!isSupportedValueType(spec.value_type)) {
            @compileError("arg '" ++ field_name ++ "' has unsupported value type '" ++ @typeName(spec.value_type) ++ "'");
        },
    }
}

fn isSupportedValueType(comptime T: type) bool {
    if (T == []const u8) {
        return true;
    }

    return switch (@typeInfo(T)) {
        .int, .@"enum" => true,
        else => false,
    };
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

fn validateNoDuplicateShortName(
    comptime field_name: []const u8,
    comptime spec: ArgSpec,
    comptime previous_field_name: []const u8,
    comptime previous: ArgSpec,
) void {
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
