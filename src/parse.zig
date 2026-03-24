const std = @import("std");
const convert = @import("convert.zig");
const parse_error = @import("error.zig");
const parsed = @import("parsed.zig");
const schema = @import("schema.zig");

pub fn parse(
    comptime SchemaType: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) parse_error.ParseError!parsed.Parsed(SchemaType) {
    _ = allocator;

    schema.validateSchema(SchemaType);
    comptime ensurePhase4Shape(SchemaType);

    const command_schema = schema.getCommandSchema(SchemaType);
    var result: parsed.Parsed(SchemaType) = undefined;
    var seen = [_]bool{false} ** command_schema.fields.len;
    var after_terminator = false;
    var positional_cursor: usize = 0;
    var index: usize = if (argv.len == 0) 0 else 1;

    initializeDefaults(SchemaType, &result);

    while (index < argv.len) {
        const token = argv[index];

        if (!after_terminator) {
            if (std.mem.eql(u8, token, "--")) {
                after_terminator = true;
                index += 1;
                continue;
            }

            if (isLongOptionToken(token)) {
                index += try parseLongToken(SchemaType, &result, &seen, argv, index);
                continue;
            }

            if (isShortOptionToken(token) and
                !shouldTreatAsNegativePositional(SchemaType, positional_cursor, token))
            {
                index += try parseShortToken(SchemaType, &result, &seen, argv, index);
                continue;
            }
        }

        try parsePositionalToken(SchemaType, &result, &seen, &positional_cursor, token);
        index += 1;
    }

    try ensureRequiredFieldsSeen(SchemaType, seen);
    return result;
}

fn ensurePhase4Shape(comptime SchemaType: type) void {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields) |field_schema| {
        if (field_schema.kind == .subcommand) {
            @compileError(std.fmt.comptimePrint(
                "parsz parse does not support Subcommand(...) yet for schema {s}",
                .{@typeName(SchemaType)},
            ));
        }

        if (field_schema.is_variadic) {
            @compileError(std.fmt.comptimePrint(
                "parsz parse does not support repeated positional fields yet for schema {s}",
                .{@typeName(SchemaType)},
            ));
        }
    }
}

fn initializeDefaults(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
) void {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields) |field_schema| {
        switch (field_schema.kind) {
            .flag => @field(result.*, field_schema.declaration_name) = false,
            .option, .positional => {
                if (field_schema.is_optional) {
                    @field(result.*, field_schema.declaration_name) = null;
                }
            },
            .subcommand => unreachable,
        }
    }
}

fn parseLongToken(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
    seen: *[schema.getCommandSchema(SchemaType).fields.len]bool,
    argv: []const []const u8,
    arg_index: usize,
) parse_error.ParseError!usize {
    const token = argv[arg_index];
    const body = token[2..];
    if (std.mem.indexOfScalar(u8, body, '=')) |equals_index| {
        const option_name = body[0..equals_index];
        const option_value = body[equals_index + 1 ..];
        const field_index = findLongOptionIndex(SchemaType, option_name) orelse return error.UnknownOption;
        const command_schema = schema.getCommandSchema(SchemaType);

        inline for (command_schema.fields, 0..) |field_schema, index| {
            if (field_index == index) {
                return switch (field_schema.kind) {
                    .flag => error.UnexpectedArgument,
                    .option => blk: {
                        if (seen[field_index]) return error.DuplicateOption;
                        try setScalarField(SchemaType, result, field_index, option_value);
                        seen[field_index] = true;
                        break :blk 1;
                    },
                    .positional, .subcommand => unreachable,
                };
            }
        }

        unreachable;
    }

    const field_index = findLongOptionIndex(SchemaType, body) orelse return error.UnknownOption;
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields, 0..) |field_schema, index| {
        if (field_index == index) {
            return switch (field_schema.kind) {
                .flag => blk: {
                    if (seen[field_index]) return error.DuplicateOption;
                    setFlagField(SchemaType, result, field_index);
                    seen[field_index] = true;
                    break :blk 1;
                },
                .option => blk: {
                    if (seen[field_index]) return error.DuplicateOption;
                    if (arg_index + 1 >= argv.len) return error.MissingOptionValue;
                    try setScalarField(SchemaType, result, field_index, argv[arg_index + 1]);
                    seen[field_index] = true;
                    break :blk 2;
                },
                .positional, .subcommand => unreachable,
            };
        }
    }

    unreachable;
}

fn parseShortToken(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
    seen: *[schema.getCommandSchema(SchemaType).fields.len]bool,
    argv: []const []const u8,
    arg_index: usize,
) parse_error.ParseError!usize {
    const token = argv[arg_index];
    const body = token[1..];
    var offset: usize = 0;

    while (offset < body.len) {
        const short_name = body[offset];
        const field_index = findShortOptionIndex(SchemaType, short_name) orelse return error.UnknownOption;
        const command_schema = schema.getCommandSchema(SchemaType);

        inline for (command_schema.fields, 0..) |field_schema, index| {
            if (field_index == index) {
                switch (field_schema.kind) {
                    .flag => {
                        if (seen[field_index]) return error.DuplicateOption;
                        setFlagField(SchemaType, result, field_index);
                        seen[field_index] = true;
                        offset += 1;
                    },
                    .option => {
                        if (seen[field_index]) return error.DuplicateOption;

                        if (offset + 1 < body.len) {
                            var inline_value = body[offset + 1 ..];
                            if (inline_value.len > 0 and inline_value[0] == '=') {
                                inline_value = inline_value[1..];
                            }

                            try setScalarField(SchemaType, result, field_index, inline_value);
                            seen[field_index] = true;
                            return 1;
                        }

                        if (arg_index + 1 >= argv.len) return error.MissingOptionValue;
                        try setScalarField(SchemaType, result, field_index, argv[arg_index + 1]);
                        seen[field_index] = true;
                        return 2;
                    },
                    .positional, .subcommand => unreachable,
                }
            }
        }
    }

    return 1;
}

fn parsePositionalToken(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
    seen: *[schema.getCommandSchema(SchemaType).fields.len]bool,
    positional_cursor: *usize,
    token: []const u8,
) parse_error.ParseError!void {
    const field_index = findNextPositionalFieldIndex(SchemaType, positional_cursor.*) orelse {
        return error.UnexpectedArgument;
    };

    try setScalarField(SchemaType, result, field_index, token);
    seen[field_index] = true;
    positional_cursor.* = field_index + 1;
}

fn ensureRequiredFieldsSeen(
    comptime SchemaType: type,
    seen: [schema.getCommandSchema(SchemaType).fields.len]bool,
) parse_error.ParseError!void {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields, 0..) |field_schema, field_index| {
        if (!seen[field_index]) {
            switch (field_schema.kind) {
                .flag => {},
                .option => {
                    if (!field_schema.is_optional) {
                        return error.MissingRequiredOption;
                    }
                },
                .positional => {
                    if (!field_schema.is_optional) {
                        return error.MissingRequiredPositional;
                    }
                },
                .subcommand => unreachable,
            }
        }
    }
}

fn findLongOptionIndex(comptime SchemaType: type, name: []const u8) ?usize {
    const LookupEntry = struct { []const u8, usize };
    const command_schema = schema.getCommandSchema(SchemaType);
    const long_option_count = comptime countLongOptions(command_schema);
    const entries = comptime blk: {
        var table: [long_option_count]LookupEntry = undefined;
        var next_index: usize = 0;

        for (command_schema.fields, 0..) |field_schema, field_index| {
            if (field_schema.kind == .flag or field_schema.kind == .option) {
                table[next_index] = .{ field_schema.long_name.?, field_index };
                next_index += 1;
            }
        }

        break :blk table;
    };
    const lookup = std.StaticStringMap(usize).initComptime(entries);

    return lookup.get(name);
}

fn countLongOptions(comptime command_schema: schema.CommandSchema) usize {
    var count: usize = 0;

    for (command_schema.fields) |field_schema| {
        if (field_schema.kind == .flag or field_schema.kind == .option) {
            count += 1;
        }
    }

    return count;
}

fn findShortOptionIndex(comptime SchemaType: type, short_name: u8) ?usize {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields, 0..) |field_schema, field_index| {
        if (field_schema.kind == .flag or field_schema.kind == .option) {
            if (field_schema.short_name) |field_short| {
                if (field_short == short_name) {
                    return field_index;
                }
            }
        }
    }

    return null;
}

fn findNextPositionalFieldIndex(comptime SchemaType: type, start_index: usize) ?usize {
    const command_schema = schema.getCommandSchema(SchemaType);
    var match: ?usize = null;

    inline for (command_schema.fields, 0..) |field_schema, field_index| {
        if (match == null and field_index >= start_index and field_schema.kind == .positional) {
            match = field_index;
        }
    }

    return match;
}

fn setFlagField(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
    field_index: usize,
) void {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields, 0..) |field_schema, index| {
        if (field_schema.kind == .flag and field_index == index) {
            @field(result.*, field_schema.declaration_name) = true;
            return;
        }
    }

    unreachable;
}

fn setScalarField(
    comptime SchemaType: type,
    result: *parsed.Parsed(SchemaType),
    field_index: usize,
    token: []const u8,
) parse_error.ParseError!void {
    const command_schema = schema.getCommandSchema(SchemaType);

    inline for (command_schema.fields, 0..) |field_schema, index| {
        if (field_index == index) {
            const FieldType = @FieldType(parsed.Parsed(SchemaType), field_schema.declaration_name);
            @field(result.*, field_schema.declaration_name) = try convert.convertScalar(FieldType, token);
            return;
        }
    }

    unreachable;
}

fn shouldTreatAsNegativePositional(
    comptime SchemaType: type,
    positional_cursor: usize,
    token: []const u8,
) bool {
    if (!looksLikeNegativeNumber(token)) {
        return false;
    }

    const command_schema = schema.getCommandSchema(SchemaType);
    var allows_negative = false;
    var found = false;

    inline for (command_schema.fields, 0..) |field_schema, field_index| {
        if (!found and field_index >= positional_cursor and field_schema.kind == .positional) {
            allows_negative = isNumericType(unwrapOptional(field_schema.parsed_type));
            found = true;
        }
    }

    return allows_negative;
}

fn unwrapOptional(comptime ValueType: type) type {
    return switch (@typeInfo(ValueType)) {
        .optional => |optional_info| optional_info.child,
        else => ValueType,
    };
}

fn isNumericType(comptime ValueType: type) bool {
    return switch (@typeInfo(ValueType)) {
        .int, .float => true,
        else => false,
    };
}

fn looksLikeNegativeNumber(token: []const u8) bool {
    if (token.len < 2 or token[0] != '-') {
        return false;
    }

    if (std.ascii.isDigit(token[1])) {
        return true;
    }

    return token[1] == '.' and token.len >= 3 and std.ascii.isDigit(token[2]);
}

fn isLongOptionToken(token: []const u8) bool {
    return token.len > 2 and std.mem.startsWith(u8, token, "--");
}

fn isShortOptionToken(token: []const u8) bool {
    return token.len > 1 and token[0] == '-' and !std.mem.startsWith(u8, token, "--");
}
