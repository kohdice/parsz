const std = @import("std");
const value_parser = @import("value_parser.zig");

pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

pub const ParseErrorKind = enum {
    unknown_option,
    missing_value,
    unexpected_value,
    invalid_value,
    overflow,
    missing_required,
    unexpected_operand,
    ambiguous_abbreviation,
};

pub const Diagnostic = struct {
    kind: ParseErrorKind,
    argv_index: ?usize = null,
    cluster_offset: ?usize = null,
    arg_name: ?[]const u8 = null,
    raw_arg: ?[]const u8 = null,
    value: ?[]const u8 = null,
};

pub const ParseOptions = struct {
    diagnostic: ?*Diagnostic = null,
    abbreviate_long_options: bool = false,
};

const Token = union(enum) {
    long_option: struct {
        argv_index: usize,
        raw: []const u8,
        name: []const u8,
        inline_value: ?[]const u8,
    },
    short_option: struct {
        argv_index: usize,
        raw: []const u8,
        ch: u8,
        rest: []const u8,
    },
    end_of_options: struct {
        argv_index: usize,
        raw: []const u8,
    },
    operand: struct {
        argv_index: usize,
        raw: []const u8,
    },
};

const Match = struct {
    arg_index: usize,
    raw_value: ?[]const u8,
    argv_index: usize,
    raw_arg: []const u8,
    cluster_offset: ?usize = null,
    value_argv_index: ?usize = null,
    value_raw_arg: ?[]const u8 = null,
    value_cluster_offset: ?usize = null,
    arg_occurrence_index: usize = 0,
};

const ValueLocation = struct {
    raw_value: []const u8,
    argv_index: usize,
    raw_arg: []const u8,
    cluster_offset: ?usize = null,
};

pub const Action = enum {
    set_true,
    count,
    set,
    append,
};

const ArgKind = enum {
    flag,
    option,
    operand,
};

const ArgSpec = struct {
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

pub fn Command(comptime declaration: anytype) type {
    validateCommandDeclaration(declaration);

    const args = declaration.args;
    const result_type = buildResultType(args);

    return struct {
        pub const name = declaration.name;
        pub const Result = result_type;

        pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8, options: ParseOptions) ParseError!Result {
            var result: Result = undefined;
            initializeResultDefaults(args, &result);
            errdefer deinit(allocator, &result);

            const matches = try parseMatches(args, allocator, argv, options);
            defer allocator.free(matches);

            try applyMatches(args, allocator, matches, &result, options);
            try validateRequiredMatches(args, matches, options);
            return result;
        }

        pub fn deinit(allocator: std.mem.Allocator, result: *Result) void {
            deinitResult(args, allocator, result);
        }
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

fn validateCommandDeclaration(comptime declaration: anytype) void {
    const Declaration = @TypeOf(declaration);

    if (!@hasField(Declaration, "name")) {
        @compileError("command declaration must include a name field");
    }
    if (!@hasField(Declaration, "args")) {
        @compileError("command declaration must include an args field");
    }

    switch (@typeInfo(@TypeOf(declaration.args))) {
        .@"struct" => {},
        else => @compileError("command args must be a struct literal"),
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

fn buildResultType(comptime args: anytype) type {
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

fn initializeResultDefaults(comptime args: anytype, result: anytype) void {
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

fn deinitResult(comptime args: anytype, allocator: std.mem.Allocator, result: anytype) void {
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

fn tokenize(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error![]Token {
    const tokens = try allocator.alloc(Token, argv.len);

    for (argv, 0..) |raw, argv_index| {
        tokens[argv_index] = tokenizeArg(argv_index, raw);
    }

    return tokens;
}

fn tokenizeArg(argv_index: usize, raw: []const u8) Token {
    if (std.mem.eql(u8, raw, "--")) {
        return .{
            .end_of_options = .{
                .argv_index = argv_index,
                .raw = raw,
            },
        };
    }

    if (std.mem.startsWith(u8, raw, "--")) {
        const option_text = raw[2..];
        if (std.mem.cutScalar(u8, option_text, '=')) |parts| {
            const name, const inline_value = parts;
            return .{
                .long_option = .{
                    .argv_index = argv_index,
                    .raw = raw,
                    .name = name,
                    .inline_value = inline_value,
                },
            };
        }

        return .{
            .long_option = .{
                .argv_index = argv_index,
                .raw = raw,
                .name = option_text,
                .inline_value = null,
            },
        };
    }

    if (raw.len > 1 and raw[0] == '-') {
        return .{
            .short_option = .{
                .argv_index = argv_index,
                .raw = raw,
                .ch = raw[1],
                .rest = raw[2..],
            },
        };
    }

    return .{
        .operand = .{
            .argv_index = argv_index,
            .raw = raw,
        },
    };
}

fn parseMatches(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: ParseOptions,
) ParseError![]Match {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const tokens = tokenize(allocator, argv) catch return error.OutOfMemory;
    defer allocator.free(tokens);

    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);

    const occurrence_counts = allocator.alloc(usize, fields.len) catch return error.OutOfMemory;
    defer allocator.free(occurrence_counts);
    @memset(occurrence_counts, 0);

    var next_operand_ordinal: usize = 0;
    var token_index: usize = 0;

    while (token_index < tokens.len) {
        switch (tokens[token_index]) {
            .long_option => |payload| {
                try appendLongOptionMatch(args, allocator, &matches, occurrence_counts, payload, argv, &token_index, options);
            },
            .short_option => |payload| {
                try appendShortOptionMatch(args, allocator, &matches, occurrence_counts, payload, argv, &token_index, options);
            },
            .end_of_options => {
                token_index += 1;
                while (token_index < tokens.len) : (token_index += 1) {
                    try appendOperandMatch(
                        args,
                        allocator,
                        &matches,
                        occurrence_counts,
                        token_index,
                        argv[token_index],
                        &next_operand_ordinal,
                        options,
                    );
                }
                break;
            },
            .operand => |payload| {
                try appendOperandMatch(
                    args,
                    allocator,
                    &matches,
                    occurrence_counts,
                    payload.argv_index,
                    payload.raw,
                    &next_operand_ordinal,
                    options,
                );
            },
        }

        token_index += 1;
    }

    return matches.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendLongOptionMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.kind != .operand) {
            if (spec.long) |long| {
                if (std.mem.eql(u8, payload.name, long)) {
                    return appendResolvedLongOptionMatch(
                        arg_index,
                        field_info.name,
                        spec,
                        allocator,
                        matches,
                        occurrence_counts,
                        payload,
                        argv,
                        token_index,
                        options,
                    );
                }
            }
        }
    }

    if (options.abbreviate_long_options and payload.name.len > 0) {
        var abbreviation_matches: usize = 0;
        var abbreviation_arg_index: usize = 0;

        inline for (fields, 0..) |field_info, arg_index| {
            const spec = @field(args, field_info.name);
            if (spec.kind != .operand) {
                if (spec.long) |long| {
                    if (std.mem.startsWith(u8, long, payload.name)) {
                        abbreviation_matches += 1;
                        abbreviation_arg_index = arg_index;
                    }
                }
            }
        }

        if (abbreviation_matches > 1) {
            return failWithDiagnostic(options, .{
                .kind = .ambiguous_abbreviation,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .value = payload.name,
            });
        }

        if (abbreviation_matches == 1) {
            inline for (fields, 0..) |field_info, arg_index| {
                const spec = @field(args, field_info.name);
                if (arg_index == abbreviation_arg_index) {
                    return appendResolvedLongOptionMatch(
                        arg_index,
                        field_info.name,
                        spec,
                        allocator,
                        matches,
                        occurrence_counts,
                        payload,
                        argv,
                        token_index,
                        options,
                    );
                }
            }
        }
    }

    return failWithDiagnostic(options, .{
        .kind = .unknown_option,
        .argv_index = payload.argv_index,
        .raw_arg = payload.raw,
        .value = payload.name,
    });
}

fn appendResolvedLongOptionMatch(
    comptime arg_index: usize,
    comptime arg_name: []const u8,
    comptime spec: ArgSpec,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    switch (spec.kind) {
        .flag => {
            if (payload.inline_value != null) {
                return failWithDiagnostic(options, .{
                    .kind = .unexpected_value,
                    .argv_index = payload.argv_index,
                    .arg_name = arg_name,
                    .raw_arg = payload.raw,
                    .value = payload.inline_value,
                });
            }

            try appendMatch(allocator, matches, occurrence_counts, .{
                .arg_index = arg_index,
                .raw_value = null,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
            });
        },
        .option => {
            const value_location: ValueLocation = if (payload.inline_value) |inline_value| .{
                .raw_value = inline_value,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .cluster_offset = null,
            } else value: {
                const value_index = token_index.* + 1;
                if (value_index >= argv.len) {
                    return failWithDiagnostic(options, .{
                        .kind = .missing_value,
                        .argv_index = payload.argv_index,
                        .arg_name = arg_name,
                        .raw_arg = payload.raw,
                    });
                }
                token_index.* = value_index;
                break :value .{
                    .raw_value = argv[value_index],
                    .argv_index = value_index,
                    .raw_arg = argv[value_index],
                    .cluster_offset = null,
                };
            };

            try appendMatch(allocator, matches, occurrence_counts, .{
                .arg_index = arg_index,
                .raw_value = value_location.raw_value,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .value_argv_index = value_location.argv_index,
                .value_raw_arg = value_location.raw_arg,
                .value_cluster_offset = value_location.cluster_offset,
            });
        },
        .operand => unreachable,
    }
}

fn appendShortOptionMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "short_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var cluster_offset: usize = 1;

    while (cluster_offset < payload.raw.len) {
        const ch = payload.raw[cluster_offset];
        const rest = payload.raw[cluster_offset + 1 ..];
        var found = false;

        inline for (fields, 0..) |field_info, arg_index| {
            const spec = @field(args, field_info.name);
            if (!found and spec.kind != .operand) {
                if (spec.short) |short| {
                    if (ch == short) {
                        found = true;
                        const current_offset = cluster_offset;

                        switch (spec.kind) {
                            .flag => {
                                try appendMatch(allocator, matches, occurrence_counts, .{
                                    .arg_index = arg_index,
                                    .raw_value = null,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                });
                                cluster_offset += 1;
                            },
                            .option => {
                                const value_location: ValueLocation = if (rest.len > 0) .{
                                    .raw_value = rest,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                } else value: {
                                    const value_index = token_index.* + 1;
                                    if (value_index >= argv.len) {
                                        return failWithDiagnostic(options, .{
                                            .kind = .missing_value,
                                            .argv_index = payload.argv_index,
                                            .cluster_offset = current_offset,
                                            .arg_name = field_info.name,
                                            .raw_arg = payload.raw,
                                        });
                                    }

                                    token_index.* = value_index;
                                    break :value .{
                                        .raw_value = argv[value_index],
                                        .argv_index = value_index,
                                        .raw_arg = argv[value_index],
                                        .cluster_offset = null,
                                    };
                                };

                                try appendMatch(allocator, matches, occurrence_counts, .{
                                    .arg_index = arg_index,
                                    .raw_value = value_location.raw_value,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                    .value_argv_index = value_location.argv_index,
                                    .value_raw_arg = value_location.raw_arg,
                                    .value_cluster_offset = value_location.cluster_offset,
                                });
                                return;
                            },
                            .operand => unreachable,
                        }
                    }
                }
            }
        }

        if (!found) {
            return failWithDiagnostic(options, .{
                .kind = .unknown_option,
                .argv_index = payload.argv_index,
                .cluster_offset = cluster_offset,
                .raw_arg = payload.raw,
            });
        }
    }
}

fn appendOperandMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    argv_index: usize,
    raw: []const u8,
    next_operand_ordinal: *usize,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var operand_ordinal: usize = 0;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.kind == .operand) {
            if (operand_ordinal == next_operand_ordinal.*) {
                if (spec.action != .append) {
                    next_operand_ordinal.* += 1;
                }
                try appendMatch(allocator, matches, occurrence_counts, .{
                    .arg_index = arg_index,
                    .raw_value = raw,
                    .argv_index = argv_index,
                    .raw_arg = raw,
                });
                return;
            }
            operand_ordinal += 1;
        }
    }

    return failWithDiagnostic(options, .{
        .kind = .unexpected_operand,
        .argv_index = argv_index,
        .raw_arg = raw,
    });
}

fn appendMatch(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    match: Match,
) ParseError!void {
    var next = match;
    next.arg_occurrence_index = occurrence_counts[match.arg_index];
    matches.append(allocator, next) catch return error.OutOfMemory;
    occurrence_counts[match.arg_index] += 1;
}

fn applyMatches(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: []const Match,
    result: anytype,
    options: ParseOptions,
) ParseError!void {
    for (matches) |match| {
        try applyMatch(args, allocator, matches, match, result, options);
    }
}

fn applyMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: []const Match,
    match: Match,
    result: anytype,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (match.arg_index == arg_index) {
            switch (spec.action) {
                .set_true => {
                    if (match.raw_value != null) {
                        return failWithDiagnostic(options, .{
                            .kind = .unexpected_value,
                            .argv_index = match.argv_index,
                            .cluster_offset = match.cluster_offset,
                            .arg_name = field_info.name,
                            .raw_arg = match.raw_arg,
                            .value = match.raw_value,
                        });
                    }
                    @field(result.*, field_info.name) = true;
                },
                .count => {
                    if (match.raw_value != null) {
                        return failWithDiagnostic(options, .{
                            .kind = .unexpected_value,
                            .argv_index = match.argv_index,
                            .cluster_offset = match.cluster_offset,
                            .arg_name = field_info.name,
                            .raw_arg = match.raw_arg,
                            .value = match.raw_value,
                        });
                    }

                    @field(result.*, field_info.name) = std.math.add(
                        u32,
                        @field(result.*, field_info.name),
                        1,
                    ) catch return failWithDiagnostic(options, .{
                        .kind = .overflow,
                        .argv_index = match.argv_index,
                        .cluster_offset = match.cluster_offset,
                        .arg_name = field_info.name,
                        .raw_arg = match.raw_arg,
                    });
                },
                .set => {
                    const raw_value = match.raw_value orelse return failWithDiagnostic(options, .{
                        .kind = .missing_value,
                        .argv_index = match.argv_index,
                        .cluster_offset = match.cluster_offset,
                        .arg_name = field_info.name,
                        .raw_arg = match.raw_arg,
                    });

                    @field(result.*, field_info.name) = try parseValue(
                        spec.value_type,
                        raw_value,
                        match,
                        field_info.name,
                        options,
                    );
                },
                .append => {
                    if (match.arg_occurrence_index != 0) {
                        return;
                    }

                    const value_count = countMatchesForArg(matches, arg_index);
                    const values = allocator.alloc(spec.value_type, value_count) catch return error.OutOfMemory;
                    errdefer allocator.free(values);

                    for (matches) |append_match| {
                        if (append_match.arg_index == arg_index) {
                            const raw_value = append_match.raw_value orelse return failWithDiagnostic(options, .{
                                .kind = .missing_value,
                                .argv_index = append_match.argv_index,
                                .cluster_offset = append_match.cluster_offset,
                                .arg_name = field_info.name,
                                .raw_arg = append_match.raw_arg,
                            });

                            values[append_match.arg_occurrence_index] = try parseValue(
                                spec.value_type,
                                raw_value,
                                append_match,
                                field_info.name,
                                options,
                            );
                        }
                    }

                    @field(result.*, field_info.name) = values;
                },
            }
            return;
        }
    }

    unreachable;
}

fn parseValue(
    comptime T: type,
    raw: []const u8,
    match: Match,
    comptime arg_name: []const u8,
    options: ParseOptions,
) ParseError!T {
    return value_parser.parse(T, raw) catch |err| switch (err) {
        error.InvalidValue => return failWithDiagnostic(options, .{
            .kind = .invalid_value,
            .argv_index = valueArgvIndex(match),
            .cluster_offset = valueClusterOffset(match),
            .arg_name = arg_name,
            .raw_arg = valueRawArg(match),
            .value = raw,
        }),
        error.Overflow => return failWithDiagnostic(options, .{
            .kind = .overflow,
            .argv_index = valueArgvIndex(match),
            .cluster_offset = valueClusterOffset(match),
            .arg_name = arg_name,
            .raw_arg = valueRawArg(match),
            .value = raw,
        }),
    };
}

fn valueArgvIndex(match: Match) usize {
    return match.value_argv_index orelse match.argv_index;
}

fn valueRawArg(match: Match) []const u8 {
    return match.value_raw_arg orelse match.raw_arg;
}

fn valueClusterOffset(match: Match) ?usize {
    if (match.value_argv_index != null or match.value_raw_arg != null) {
        return match.value_cluster_offset;
    }

    return match.cluster_offset;
}

fn validateRequiredMatches(comptime args: anytype, matches: []const Match, options: ParseOptions) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.required and !hasMatchForArg(matches, arg_index)) {
            return failWithDiagnostic(options, .{
                .kind = .missing_required,
                .arg_name = field_info.name,
            });
        }
    }
}

fn countMatchesForArg(matches: []const Match, arg_index: usize) usize {
    var count: usize = 0;
    for (matches) |match| {
        if (match.arg_index == arg_index) {
            count += 1;
        }
    }
    return count;
}

fn hasMatchForArg(matches: []const Match, arg_index: usize) bool {
    for (matches) |match| {
        if (match.arg_index == arg_index) {
            return true;
        }
    }

    return false;
}

fn failWithDiagnostic(options: ParseOptions, diagnostic_value: Diagnostic) ParseError {
    if (options.diagnostic) |diagnostic| {
        diagnostic.* = diagnostic_value;
    }

    return error.ParseFailed;
}

test "schema: accepts empty command definition" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    try std.testing.expectEqual(@as(usize, 0), @typeInfo(Cli.Result).@"struct".fields.len);

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    Cli.deinit(std.testing.allocator, &result);
}

test "schema: accepts one boolean flag" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Result, "verbose") == bool);

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(!result.verbose);
}

test "schema: accepts short and long names for the same option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Result, "verbose") == bool);
}

test "schema: maps anonymous struct arg fields to result field names" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const fields = @typeInfo(Cli.Result).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("verbose", fields[0].name);
}

test "schema: maps actions and required/default settings to result field types" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .debug = flag(.{}),
            .verbose = flag(.{
                .action = .count,
            }),
            .output = option([]const u8, .{
                .required = true,
            }),
            .color = option([]const u8, .{}),
            .port = option(u16, .{
                .default = 80,
            }),
            .include = option([]const u8, .{
                .action = .append,
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Result, "debug") == bool);
    try std.testing.expect(@FieldType(Cli.Result, "verbose") == u32);
    try std.testing.expect(@FieldType(Cli.Result, "output") == []const u8);
    try std.testing.expect(@FieldType(Cli.Result, "color") == ?[]const u8);
    try std.testing.expect(@FieldType(Cli.Result, "port") == u16);
    try std.testing.expect(@FieldType(Cli.Result, "include") == []const []const u8);
}

test "runtime api: parses borrowed argv slices without argv zero" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const process_argv = [_][]const u8{"app"};
    const user_args = process_argv[1..];

    var result = try Cli.parse(std.testing.allocator, user_args, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(!result.verbose);
}

test "runtime api: reports diagnostics through parse options" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"extra"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "runtime api: reports missing required flag without input" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
}

test "runtime api: reports missing required append option without input" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .include = option([]const u8, .{
                .action = .append,
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("include", diagnostic.arg_name.?);
}

test "runtime api: exposes result deinit as no-op for borrowed-only schemas" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{}),
        },
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    Cli.deinit(std.testing.allocator, &result);
}

test "tokenizer: treats empty argv as empty token stream" {
    const tokens = try tokenize(std.testing.allocator, &.{});
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "tokenizer: classifies operands" {
    const argv = [_][]const u8{"file.txt"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectOperandToken(tokens[0], 0, "file.txt");
}

test "tokenizer: classifies end of options marker" {
    const argv = [_][]const u8{"--"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectEndOfOptionsToken(tokens[0], 0, "--");
}

test "tokenizer: does not force tokens after end marker to operands" {
    const argv = [_][]const u8{ "--", "--verbose" };
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try expectEndOfOptionsToken(tokens[0], 0, "--");
    try expectLongOptionToken(tokens[1], 1, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option without value" {
    const argv = [_][]const u8{"--verbose"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option with inline value" {
    const argv = [_][]const u8{"--output=path"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--output=path", "output", "path");
}

test "tokenizer: preserves empty long inline value" {
    const argv = [_][]const u8{"--output="};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--output=", "output", "");
}

test "tokenizer: classifies single hyphen as operand" {
    const argv = [_][]const u8{"-"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectOperandToken(tokens[0], 0, "-");
}

test "tokenizer: preserves short option suffix" {
    const argv = [_][]const u8{"-abc"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectShortOptionToken(tokens[0], 0, "-abc", 'a', "bc");
}

test "tokenizer: preserves attached short value candidate" {
    const argv = [_][]const u8{"-Iinclude"};
    const tokens = try tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectShortOptionToken(tokens[0], 0, "-Iinclude", 'I', "include");
}

test "parser: parses one long flag occurrence" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: rejects long abbreviation unless explicitly enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqualStrings("ver", diagnostic.value.?);
}

test "parser: parses unique long abbreviation when enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: reports ambiguous long abbreviation when enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .version = flag(.{
                .long = "version",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
        .abbreviate_long_options = true,
    }));

    try std.testing.expectEqual(ParseErrorKind.ambiguous_abbreviation, diagnostic.kind);
    try std.testing.expectEqualStrings("ver", diagnostic.value.?);
}

test "parser: prefers exact long option match over abbreviation" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .ver = flag(.{
                .long = "ver",
            }),
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.ver);
    try std.testing.expect(!result.verbose);
}

test "parser: parses one short flag occurrence" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
            }),
        },
    });

    const argv = [_][]const u8{"-v"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: expands short flag clusters" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .binary = flag(.{
                .short = 'b',
            }),
            .count = flag(.{
                .short = 'c',
            }),
        },
    });

    const argv = [_][]const u8{"-abc"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expect(result.binary);
    try std.testing.expect(result.count);
}

test "parser: counts repeated flag occurrences" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .action = .count,
            }),
        },
    });

    const argv = [_][]const u8{ "-v", "-v", "-v" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u32, 3), result.verbose);
}

test "parser: counts repeated grouped short flag occurrences" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .action = .count,
            }),
        },
    });

    const argv = [_][]const u8{"-vvv"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u32, 3), result.verbose);
}

test "parser: parses long option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "path" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses long option value from inline equals form" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output=path"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses short option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .short = 'o',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-o", "path" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses short option value from attached suffix" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"-Iinclude"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("include", result.include);
}

test "parser: treats suffix after short option as its value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .short = 'o',
                .required = true,
            }),
            .verbose = flag(.{
                .short = 'v',
            }),
        },
    });

    const argv = [_][]const u8{"-ov"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("v", result.output);
    try std.testing.expect(!result.verbose);
}

test "parser: parses trailing short cluster suffix as value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .output = option([]const u8, .{
                .short = 'b',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"-abVALUE"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expectEqualStrings("VALUE", result.output);
}

test "parser: parses trailing short cluster option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .output = option([]const u8, .{
                .short = 'b',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-ab", "VALUE" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expectEqualStrings("VALUE", result.output);
}

test "parser: assigns one operand by declaration order" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"input.txt"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("input.txt", result.source);
}

test "parser: assigns multiple operands by declaration order" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "src", "dst" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("src", result.source);
    try std.testing.expectEqualStrings("dst", result.dest);
}

test "parser: permits options between operands" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "src", "--verbose", "dst" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("src", result.source);
    try std.testing.expectEqualStrings("dst", result.dest);
}

test "parser: treats arguments after end marker as operands" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--", "--source", "-d" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--source", result.source);
    try std.testing.expectEqualStrings("-d", result.dest);
}

test "parser: consumes end marker as required option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "--" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--", result.output);
}

test "parser: continues option scanning after end marker consumed as value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "--", "--verbose" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--", result.output);
    try std.testing.expect(result.verbose);
}

test "parser: consumes dash-prefixed required option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(i8, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--port", "-1" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(i8, -1), result.port);
}

test "parser: assigns variadic operands in command-line order" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .sources = operand([]const u8, .{
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "a.zig", "b.zig" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.sources.len);
    try std.testing.expectEqualStrings("a.zig", result.sources[0]);
    try std.testing.expectEqualStrings("b.zig", result.sources[1]);
}

test "parser: preserves repeated option value matches in command-line order" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "-I", "a", "-I", "b" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    try std.testing.expectEqualStrings("a", result.include[0]);
    try std.testing.expectEqualStrings("b", result.include[1]);
}

test "parser: reports unknown long option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"--missing"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqualStrings("--missing", diagnostic.raw_arg.?);
}

test "parser: reports unknown short option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"-x"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("-x", diagnostic.raw_arg.?);
}

test "parser: reports unknown short option inside cluster with diagnostic offset" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
        },
    });

    const argv = [_][]const u8{"-ax"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("-ax", diagnostic.raw_arg.?);
}

test "semantic: reports missing required option value with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_value, diagnostic.kind);
    try std.testing.expectEqualStrings("output", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("--output", diagnostic.raw_arg.?);
}

test "semantic: reports unexpected value for flag with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose=true"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("true", diagnostic.value.?);
}

test "semantic: reports empty inline value for flag as unexpected value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose="};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqualStrings("", diagnostic.value.?);
}

test "semantic: reports missing required operand with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("source", diagnostic.arg_name.?);
}

test "semantic: reports unexpected operand with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "input", "extra" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "semantic: accepts empty inline value for string option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output="};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("", result.output);
}

test "semantic: returns null for absent optional option without default" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .color = option([]const u8, .{
                .long = "color",
            }),
        },
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.color == null);
}

test "semantic: applies default value for absent optional option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .default = 80,
            }),
        },
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u16, 80), result.port);
}

test "semantic: returns borrowed string slices for textual values" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "path" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(result.output.ptr == argv[1].ptr);
    try std.testing.expectEqual(argv[1].len, result.output.len);
}

test "semantic: deinit releases collected append storage" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "-I", "a", "-I", "b" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});

    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    Cli.deinit(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(usize, 0), result.include.len);
}

test "semantic: reports count action overflow with diagnostic" {
    const args = .{
        .verbose = flag(.{
            .short = 'v',
            .action = .count,
        }),
    };
    var result: buildResultType(args) = .{
        .verbose = std.math.maxInt(u32),
    };
    const matches = [_]Match{.{
        .arg_index = 0,
        .raw_value = null,
        .argv_index = 0,
        .raw_arg = "-v",
        .cluster_offset = 1,
    }};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, applyMatches(args, std.testing.allocator, matches[0..], &result, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("-v", diagnostic.raw_arg.?);
}

test "semantic: parses integer option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=8080"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "semantic: reports invalid integer option value with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=abc"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("abc", diagnostic.value.?);
}

test "semantic: reports invalid separated integer value at value argv index" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--port", "abc" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("abc", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("abc", diagnostic.value.?);
}

test "semantic: reports integer range overflow with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u8, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=300"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("300", diagnostic.value.?);
}

test "semantic: reports short separated integer overflow at value argv index" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u8, .{
                .short = 'p',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-p", "300" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("300", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("300", diagnostic.value.?);
}

test "semantic: parses enum option value" {
    const Mode = enum { fast, slow };
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .mode = option(Mode, .{
                .long = "mode",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--mode=fast"};
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(Mode.fast, result.mode);
}

test "semantic: reports invalid enum option value with diagnostic" {
    const Mode = enum { fast, slow };
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .mode = option(Mode, .{
                .long = "mode",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--mode=quick"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("mode", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("quick", diagnostic.value.?);
}

fn expectOperandToken(token: Token, expected_argv_index: usize, expected_raw: []const u8) !void {
    switch (token) {
        .operand => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
        },
        else => return error.ExpectedOperandToken,
    }
}

fn expectEndOfOptionsToken(token: Token, expected_argv_index: usize, expected_raw: []const u8) !void {
    switch (token) {
        .end_of_options => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
        },
        else => return error.ExpectedEndOfOptionsToken,
    }
}

fn expectLongOptionToken(
    token: Token,
    expected_argv_index: usize,
    expected_raw: []const u8,
    expected_name: []const u8,
    expected_inline_value: ?[]const u8,
) !void {
    switch (token) {
        .long_option => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
            try std.testing.expectEqualStrings(expected_name, payload.name);

            if (expected_inline_value) |expected| {
                try std.testing.expect(payload.inline_value != null);
                try std.testing.expectEqualStrings(expected, payload.inline_value.?);
            } else {
                try std.testing.expect(payload.inline_value == null);
            }
        },
        else => return error.ExpectedLongOptionToken,
    }
}

fn expectShortOptionToken(
    token: Token,
    expected_argv_index: usize,
    expected_raw: []const u8,
    expected_ch: u8,
    expected_rest: []const u8,
) !void {
    switch (token) {
        .short_option => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
            try std.testing.expectEqual(expected_ch, payload.ch);
            try std.testing.expectEqualStrings(expected_rest, payload.rest);
        },
        else => return error.ExpectedShortOptionToken,
    }
}
