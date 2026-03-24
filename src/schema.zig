const std = @import("std");
const field = @import("field.zig");

const Type = std.builtin.Type;

pub const RootCommandMeta = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    about: ?[]const u8 = null,
};

pub const SubcommandMeta = struct {
    about: ?[]const u8 = null,
};

pub const SubcommandEntry = struct {
    tag_name: []const u8,
    normalized_name: []const u8,
    payload_type: type,
    payload_path: []const u8,
};

pub const FieldSchema = struct {
    declaration_name: []const u8,
    kind: field.FieldKind,
    parsed_type: type,
    long_name: ?[]const u8 = null,
    short_name: ?u8 = null,
    value_name: ?[]const u8 = null,
    is_optional: bool = false,
    is_variadic: bool = false,
    subcommands: []const SubcommandEntry = &.{},
};

pub const CommandSchema = struct {
    command_type: type,
    path: []const u8,
    is_root: bool,
    root_meta: RootCommandMeta = .{},
    subcommand_meta: SubcommandMeta = .{},
    fields: []const FieldSchema,
};

pub fn getCommandSchema(comptime SchemaType: type) CommandSchema {
    return buildCommandSchema(SchemaType, .root, @typeName(SchemaType));
}

pub fn getSubcommandPayloadSchema(
    comptime SchemaType: type,
    comptime path: []const u8,
) CommandSchema {
    return buildCommandSchema(SchemaType, .subcommand_payload, path);
}

pub fn validateSchema(comptime SchemaType: type) void {
    _ = getCommandSchema(SchemaType);
}

const CommandRole = enum {
    root,
    subcommand_payload,
};

const PayloadInfo = struct {
    parsed_type: type,
    is_optional: bool,
    is_variadic: bool,
};

fn buildCommandSchema(
    comptime SchemaType: type,
    comptime role: CommandRole,
    comptime path: []const u8,
) CommandSchema {
    const command_info = switch (@typeInfo(SchemaType)) {
        .@"struct" => |info| info,
        else => schemaError(
            "parsz schema error at {s}: expected command schema struct, found {s}",
            .{ path, @typeName(SchemaType) },
        ),
    };

    if (command_info.is_tuple) {
        schemaError(
            "parsz schema error at {s}: tuple command schemas are not supported",
            .{path},
        );
    }

    const root_meta: RootCommandMeta = switch (role) {
        .root => normalizeRootMeta(SchemaType, path),
        .subcommand_payload => .{},
    };
    const subcommand_meta: SubcommandMeta = switch (role) {
        .root => .{},
        .subcommand_payload => normalizeSubcommandMeta(SchemaType, path),
    };

    const fields = comptime blk: {
        var normalized_fields: [command_info.fields.len]FieldSchema = undefined;
        var subcommand_field_count: usize = 0;
        var saw_optional_positional = false;
        var saw_variadic_positional = false;

        for (command_info.fields, 0..) |command_field, index| {
            const field_path = joinPath(path, command_field.name);
            const normalized = normalizeFieldSchema(command_field, field_path);

            switch (normalized.kind) {
                .flag, .option => {
                    if (normalized.long_name) |long_name| {
                        ensureNotReservedName(long_name, field_path, "option/flag name");
                    }
                },
                .positional => {
                    if (saw_variadic_positional) {
                        schemaError(
                            "parsz schema error at {s}: positional fields may not appear after a variadic positional",
                            .{field_path},
                        );
                    }

                    if (!normalized.is_optional and saw_optional_positional) {
                        schemaError(
                            "parsz schema error at {s}: required positional fields may not appear after optional positional fields",
                            .{field_path},
                        );
                    }

                    if (normalized.is_optional) {
                        saw_optional_positional = true;
                    }

                    if (normalized.is_variadic) {
                        saw_variadic_positional = true;
                    }
                },
                .subcommand => {
                    subcommand_field_count += 1;
                    if (subcommand_field_count > 1) {
                        schemaError(
                            "parsz schema error at {s}: command schemas may declare at most one Subcommand(...) field",
                            .{field_path},
                        );
                    }
                },
            }

            normalized_fields[index] = normalized;
        }

        for (normalized_fields, 0..) |current_field, current_index| {
            switch (current_field.kind) {
                .flag, .option => {
                    if (current_field.long_name) |current_long| {
                        for (normalized_fields[0..current_index]) |previous_field| {
                            if (previous_field.long_name) |previous_long| {
                                if (std.mem.eql(u8, current_long, previous_long)) {
                                    schemaError(
                                        "parsz schema error at {s}: duplicate long name '--{s}' within command scope {s}",
                                        .{
                                            joinPath(path, current_field.declaration_name),
                                            current_long,
                                            path,
                                        },
                                    );
                                }
                            }
                        }
                    }

                    if (current_field.short_name) |current_short| {
                        for (normalized_fields[0..current_index]) |previous_field| {
                            if (previous_field.short_name) |previous_short| {
                                if (current_short == previous_short) {
                                    schemaError(
                                        "parsz schema error at {s}: duplicate short name '-{c}' within command scope {s}",
                                        .{
                                            joinPath(path, current_field.declaration_name),
                                            current_short,
                                            path,
                                        },
                                    );
                                }
                            }
                        }
                    }
                },
                .positional, .subcommand => {},
            }
        }

        break :blk normalized_fields;
    };

    return .{
        .command_type = SchemaType,
        .path = path,
        .is_root = role == .root,
        .root_meta = root_meta,
        .subcommand_meta = subcommand_meta,
        .fields = &fields,
    };
}

fn normalizeFieldSchema(
    comptime command_field: Type.StructField,
    comptime field_path: []const u8,
) FieldSchema {
    const FieldType = command_field.type;

    if (!canHaveDecls(FieldType) or
        !@hasDecl(FieldType, "parsz_kind") or
        !@hasDecl(FieldType, "ParsedValue") or
        !@hasDecl(FieldType, "meta"))
    {
        schemaError(
            "parsz schema error at {s}: expected a parsz schema wrapper, found {s}",
            .{ field_path, @typeName(FieldType) },
        );
    }

    return switch (FieldType.parsz_kind) {
        .flag => .{
            .declaration_name = command_field.name,
            .kind = .flag,
            .parsed_type = bool,
            .long_name = normalizeLongName(command_field.name, FieldType.meta),
            .short_name = FieldType.meta.short,
        },
        .option => normalizeOptionField(command_field.name, FieldType.ParsedValue, FieldType.meta, field_path),
        .positional => normalizePositionalField(command_field.name, FieldType.ParsedValue, FieldType.meta, field_path),
        .subcommand => normalizeSubcommandField(command_field.name, FieldType.ParsedValue, field_path),
    };
}

fn normalizeOptionField(
    comptime declaration_name: []const u8,
    comptime ValueType: type,
    comptime meta: field.FieldMeta,
    comptime field_path: []const u8,
) FieldSchema {
    const payload = analyzeOptionPayload(ValueType, field_path);

    return .{
        .declaration_name = declaration_name,
        .kind = .option,
        .parsed_type = payload.parsed_type,
        .long_name = normalizeLongName(declaration_name, meta),
        .short_name = meta.short,
        .value_name = meta.value_name orelse uppercaseAscii(declaration_name),
        .is_optional = payload.is_optional,
    };
}

fn normalizePositionalField(
    comptime declaration_name: []const u8,
    comptime ValueType: type,
    comptime meta: field.FieldMeta,
    comptime field_path: []const u8,
) FieldSchema {
    if (meta.long != null or meta.short != null) {
        schemaError(
            "parsz schema error at {s}: positional fields may not declare long or short names",
            .{field_path},
        );
    }

    const payload = analyzePositionalPayload(ValueType, field_path);

    return .{
        .declaration_name = declaration_name,
        .kind = .positional,
        .parsed_type = payload.parsed_type,
        .value_name = meta.value_name orelse uppercaseAscii(declaration_name),
        .is_optional = payload.is_optional,
        .is_variadic = payload.is_variadic,
    };
}

fn normalizeSubcommandField(
    comptime declaration_name: []const u8,
    comptime UnionType: type,
    comptime field_path: []const u8,
) FieldSchema {
    const union_info = switch (@typeInfo(UnionType)) {
        .@"union" => |info| info,
        else => schemaError(
            "parsz schema error at {s}: Subcommand(...) expects a tagged union, found {s}",
            .{ field_path, @typeName(UnionType) },
        ),
    };

    if (union_info.tag_type == null) {
        schemaError(
            "parsz schema error at {s}: Subcommand(...) expects a tagged union, found untagged union {s}",
            .{ field_path, @typeName(UnionType) },
        );
    }

    const entries = comptime blk: {
        var subcommands: [union_info.fields.len]SubcommandEntry = undefined;

        for (union_info.fields, 0..) |union_field, index| {
            const normalized_name = union_field.name;
            const payload_path = joinPath(field_path, union_field.name);

            ensureNotReservedName(normalized_name, payload_path, "subcommand name");
            _ = buildCommandSchema(union_field.type, .subcommand_payload, payload_path);

            for (subcommands[0..index]) |previous| {
                if (std.mem.eql(u8, normalized_name, previous.normalized_name)) {
                    schemaError(
                        "parsz schema error at {s}: duplicate subcommand name '{s}' within command scope {s}",
                        .{ payload_path, normalized_name, field_path },
                    );
                }
            }

            subcommands[index] = .{
                .tag_name = union_field.name,
                .normalized_name = normalized_name,
                .payload_type = union_field.type,
                .payload_path = payload_path,
            };
        }

        break :blk subcommands;
    };

    return .{
        .declaration_name = declaration_name,
        .kind = .subcommand,
        .parsed_type = UnionType,
        .subcommands = &entries,
    };
}

fn analyzeOptionPayload(comptime ValueType: type, comptime field_path: []const u8) PayloadInfo {
    switch (@typeInfo(ValueType)) {
        .optional => |optional_info| {
            ensureSupportedScalar(optional_info.child, field_path);
            return .{
                .parsed_type = ValueType,
                .is_optional = true,
                .is_variadic = false,
            };
        },
        else => {},
    }

    ensureSupportedScalar(ValueType, field_path);
    return .{
        .parsed_type = ValueType,
        .is_optional = false,
        .is_variadic = false,
    };
}

fn analyzePositionalPayload(comptime ValueType: type, comptime field_path: []const u8) PayloadInfo {
    switch (@typeInfo(ValueType)) {
        .optional => |optional_info| {
            ensureSupportedScalar(optional_info.child, field_path);
            return .{
                .parsed_type = ValueType,
                .is_optional = true,
                .is_variadic = false,
            };
        },
        else => {},
    }

    if (isSupportedScalar(ValueType)) {
        return .{
            .parsed_type = ValueType,
            .is_optional = false,
            .is_variadic = false,
        };
    }

    if (isRepeatedPositionalPayload(ValueType)) {
        return .{
            .parsed_type = ValueType,
            .is_optional = false,
            .is_variadic = true,
        };
    }

    schemaError(
        "parsz schema error at {s}: unsupported positional payload type {s}",
        .{ field_path, @typeName(ValueType) },
    );
}

fn ensureSupportedScalar(comptime ValueType: type, comptime field_path: []const u8) void {
    if (!isSupportedScalar(ValueType)) {
        schemaError(
            "parsz schema error at {s}: unsupported scalar payload type {s}",
            .{ field_path, @typeName(ValueType) },
        );
    }
}

fn isSupportedScalar(comptime ValueType: type) bool {
    if (ValueType == bool) {
        return true;
    }

    if (isBorrowedStringType(ValueType)) {
        return true;
    }

    return switch (@typeInfo(ValueType)) {
        .int, .comptime_int, .float, .comptime_float, .@"enum" => true,
        else => false,
    };
}

fn isRepeatedPositionalPayload(comptime ValueType: type) bool {
    const pointer_info = switch (@typeInfo(ValueType)) {
        .pointer => |info| info,
        else => return false,
    };

    if (pointer_info.size != .slice or !pointer_info.is_const or pointer_info.sentinel_ptr != null) {
        return false;
    }

    return isSupportedScalar(pointer_info.child);
}

fn isBorrowedStringType(comptime ValueType: type) bool {
    const pointer_info = switch (@typeInfo(ValueType)) {
        .pointer => |info| info,
        else => return false,
    };

    if (pointer_info.size != .slice or !pointer_info.is_const or pointer_info.child != u8) {
        return false;
    }

    return true;
}

fn normalizeLongName(
    comptime declaration_name: []const u8,
    comptime meta: field.FieldMeta,
) []const u8 {
    return meta.long orelse declaration_name;
}

fn normalizeRootMeta(comptime SchemaType: type, comptime path: []const u8) RootCommandMeta {
    if (!@hasDecl(SchemaType, "meta")) {
        return .{};
    }

    const meta_value = SchemaType.meta;
    const meta_type = @TypeOf(meta_value);
    const meta_info = switch (@typeInfo(meta_type)) {
        .@"struct" => |info| info,
        else => schemaError(
            "parsz schema error at {s}.meta: expected command meta to be a struct literal",
            .{path},
        ),
    };

    if (meta_info.is_tuple) {
        schemaError(
            "parsz schema error at {s}.meta: tuple meta values are not supported",
            .{path},
        );
    }

    var normalized = RootCommandMeta{};

    inline for (meta_info.fields) |meta_field| {
        const meta_path = joinPath(joinPath(path, "meta"), meta_field.name);
        const value = @field(meta_value, meta_field.name);

        if (std.mem.eql(u8, meta_field.name, "name")) {
            normalized.name = normalizeMetaString(value, meta_path);
        } else if (std.mem.eql(u8, meta_field.name, "version")) {
            normalized.version = normalizeMetaString(value, meta_path);
        } else if (std.mem.eql(u8, meta_field.name, "about")) {
            normalized.about = normalizeMetaString(value, meta_path);
        } else {
            schemaError(
                "parsz schema error at {s}: root command meta does not support field '{s}'",
                .{ meta_path, meta_field.name },
            );
        }
    }

    return normalized;
}

fn normalizeSubcommandMeta(comptime SchemaType: type, comptime path: []const u8) SubcommandMeta {
    if (!@hasDecl(SchemaType, "meta")) {
        return .{};
    }

    const meta_value = SchemaType.meta;
    const meta_type = @TypeOf(meta_value);
    const meta_info = switch (@typeInfo(meta_type)) {
        .@"struct" => |info| info,
        else => schemaError(
            "parsz schema error at {s}.meta: expected command meta to be a struct literal",
            .{path},
        ),
    };

    if (meta_info.is_tuple) {
        schemaError(
            "parsz schema error at {s}.meta: tuple meta values are not supported",
            .{path},
        );
    }

    var normalized = SubcommandMeta{};

    inline for (meta_info.fields) |meta_field| {
        const meta_path = joinPath(joinPath(path, "meta"), meta_field.name);
        const value = @field(meta_value, meta_field.name);

        if (std.mem.eql(u8, meta_field.name, "about")) {
            normalized.about = normalizeMetaString(value, meta_path);
        } else {
            schemaError(
                "parsz schema error at {s}: subcommand command meta supports only 'about'",
                .{meta_path},
            );
        }
    }

    return normalized;
}

fn normalizeMetaString(comptime value: anytype, comptime path: []const u8) ?[]const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |some| normalizeRequiredMetaString(some, path) else null,
        else => normalizeRequiredMetaString(value, path),
    };
}

fn normalizeRequiredMetaString(comptime value: anytype, comptime path: []const u8) []const u8 {
    const ValueType = @TypeOf(value);

    if (!isMetaStringType(ValueType)) {
        schemaError(
            "parsz schema error at {s}: expected a string value",
            .{path},
        );
    }

    const normalized: []const u8 = value;
    return normalized;
}

fn isMetaStringType(comptime ValueType: type) bool {
    const pointer_info = switch (@typeInfo(ValueType)) {
        .pointer => |info| info,
        else => return false,
    };

    if (!pointer_info.is_const) {
        return false;
    }

    return switch (pointer_info.size) {
        .slice => pointer_info.child == u8,
        .one => switch (@typeInfo(pointer_info.child)) {
            .array => |array_info| array_info.child == u8,
            else => false,
        },
        else => false,
    };
}

fn canHaveDecls(comptime ValueType: type) bool {
    return switch (@typeInfo(ValueType)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn ensureNotReservedName(
    comptime name: []const u8,
    comptime path: []const u8,
    comptime label: []const u8,
) void {
    inline for (.{ "help", "version" }) |reserved_name| {
        if (std.mem.eql(u8, name, reserved_name)) {
            schemaError(
                "parsz schema error at {s}: reserved {s} '{s}' is not allowed in the MVP",
                .{ path, label, reserved_name },
            );
        }
    }
}

fn uppercaseAscii(comptime input: []const u8) []const u8 {
    var output: []const u8 = "";

    inline for (input) |byte| {
        output = output ++ [_]u8{std.ascii.toUpper(byte)};
    }

    return output;
}

fn joinPath(comptime left: []const u8, comptime right: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}.{s}", .{ left, right });
}

fn schemaError(comptime format: []const u8, args: anytype) noreturn {
    @compileError(std.fmt.comptimePrint(format, args));
}

test "schema extraction normalizes metadata defaults" {
    const Command = union(enum) {
        init: struct {
            pub const meta = .{
                .about = "Create a new project",
            };

            path: field.Positional([]const u8, .{}),
        },
    };

    const Cli = struct {
        pub const meta = .{
            .name = "demo",
            .version = "0.1.0",
            .about = "Demo application",
        };

        verbose: field.Flag(.{}),
        output: field.Option(?[]const u8, .{}),
        input: field.Positional([]const u8, .{}),
        command: field.Subcommand(Command),
    };

    const cli_schema = getCommandSchema(Cli);

    try std.testing.expect(cli_schema.is_root);
    try std.testing.expectEqualStrings("demo", cli_schema.root_meta.name.?);
    try std.testing.expectEqualStrings("0.1.0", cli_schema.root_meta.version.?);
    try std.testing.expectEqualStrings("Demo application", cli_schema.root_meta.about.?);
    try std.testing.expectEqual(@as(usize, 4), cli_schema.fields.len);

    try std.testing.expectEqualStrings("verbose", cli_schema.fields[0].long_name.?);
    try std.testing.expectEqualStrings("output", cli_schema.fields[1].long_name.?);
    try std.testing.expectEqualStrings("OUTPUT", cli_schema.fields[1].value_name.?);
    try std.testing.expectEqualStrings("INPUT", cli_schema.fields[2].value_name.?);

    try std.testing.expectEqual(@as(usize, 1), cli_schema.fields[3].subcommands.len);
    try std.testing.expectEqualStrings("init", cli_schema.fields[3].subcommands[0].normalized_name);

    const init_schema = getSubcommandPayloadSchema(
        cli_schema.fields[3].subcommands[0].payload_type,
        cli_schema.fields[3].subcommands[0].payload_path,
    );

    try std.testing.expect(!init_schema.is_root);
    try std.testing.expectEqualStrings("Create a new project", init_schema.subcommand_meta.about.?);
    try std.testing.expectEqualStrings("PATH", init_schema.fields[0].value_name.?);
}

test "schema validation accepts valid positional ordering" {
    const Cli = struct {
        first: field.Positional([]const u8, .{}),
        second: field.Positional(?u32, .{}),
        rest: field.Positional([]const []const u8, .{}),
    };

    const cli_schema = getCommandSchema(Cli);

    try std.testing.expect(!cli_schema.fields[0].is_optional);
    try std.testing.expect(cli_schema.fields[1].is_optional);
    try std.testing.expect(cli_schema.fields[2].is_variadic);
}

test "duplicate names are validated per command scope" {
    const Command = union(enum) {
        child: struct {
            verbose: field.Flag(.{
                .short = 'v',
            }),
        },
    };

    const Cli = struct {
        verbose: field.Flag(.{
            .short = 'v',
        }),
        command: field.Subcommand(Command),
    };

    const cli_schema = getCommandSchema(Cli);
    const child_schema = getSubcommandPayloadSchema(
        cli_schema.fields[1].subcommands[0].payload_type,
        cli_schema.fields[1].subcommands[0].payload_path,
    );

    try std.testing.expectEqualStrings("verbose", cli_schema.fields[0].long_name.?);
    try std.testing.expectEqual(@as(u8, 'v'), cli_schema.fields[0].short_name.?);
    try std.testing.expectEqualStrings("verbose", child_schema.fields[0].long_name.?);
    try std.testing.expectEqual(@as(u8, 'v'), child_schema.fields[0].short_name.?);
}
