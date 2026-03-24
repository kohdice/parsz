const std = @import("std");
const schema = @import("schema.zig");

const Type = std.builtin.Type;

pub fn Parsed(comptime SchemaType: type) type {
    _ = schema.getCommandSchema(SchemaType);
    return parsedCommandType(SchemaType);
}

fn parsedCommandType(comptime SchemaType: type) type {
    const schema_info = switch (@typeInfo(SchemaType)) {
        .@"struct" => |info| info,
        else => @compileError(std.fmt.comptimePrint(
            "parsz.Parsed expects a command schema struct, found {s}",
            .{@typeName(SchemaType)},
        )),
    };

    if (schema_info.is_tuple) {
        @compileError(std.fmt.comptimePrint(
            "parsz.Parsed does not support tuple command schemas: {s}",
            .{@typeName(SchemaType)},
        ));
    }

    return buildParsedStructType(SchemaType, schema_info);
}

fn buildParsedStructType(
    comptime SchemaType: type,
    comptime schema_info: Type.Struct,
) type {
    var fields: [schema_info.fields.len]Type.StructField = undefined;

    inline for (schema_info.fields, 0..) |field, i| {
        const ParsedFieldType = parsedTypeForSchemaField(SchemaType, field.name, field.type);
        fields[i] = .{
            .name = field.name,
            .type = ParsedFieldType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ParsedFieldType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn parsedTypeForSchemaField(
    comptime SchemaType: type,
    comptime field_name: [:0]const u8,
    comptime FieldType: type,
) type {
    if (!@hasDecl(FieldType, "parsz_kind") or !@hasDecl(FieldType, "ParsedValue")) {
        @compileError(std.fmt.comptimePrint(
            "parsz.Parsed expected field '{s}' in {s} to use a parsz schema wrapper, found {s}",
            .{ field_name, @typeName(SchemaType), @typeName(FieldType) },
        ));
    }

    return switch (FieldType.parsz_kind) {
        .flag, .option, .positional => FieldType.ParsedValue,
        .subcommand => parsedSubcommandUnionType(SchemaType, field_name, FieldType.ParsedValue),
    };
}

fn parsedSubcommandUnionType(
    comptime SchemaType: type,
    comptime field_name: [:0]const u8,
    comptime UnionType: type,
) type {
    const union_info = switch (@typeInfo(UnionType)) {
        .@"union" => |info| info,
        else => @compileError(std.fmt.comptimePrint(
            "parsz.Parsed expected subcommand field '{s}' in {s} to wrap a tagged union, found {s}",
            .{ field_name, @typeName(SchemaType), @typeName(UnionType) },
        )),
    };

    const TagType = union_info.tag_type orelse @compileError(std.fmt.comptimePrint(
        "parsz.Parsed expected subcommand field '{s}' in {s} to wrap a tagged union, found untagged union {s}",
        .{ field_name, @typeName(SchemaType), @typeName(UnionType) },
    ));

    var fields: [union_info.fields.len]Type.UnionField = undefined;

    inline for (union_info.fields, 0..) |field, i| {
        const ParsedPayloadType = parsedCommandType(field.type);
        fields[i] = .{
            .name = field.name,
            .type = ParsedPayloadType,
            .alignment = @alignOf(ParsedPayloadType),
        };
    }

    return @Type(.{ .@"union" = .{
        .layout = union_info.layout,
        .tag_type = TagType,
        .fields = &fields,
        .decls = &.{},
    } });
}
