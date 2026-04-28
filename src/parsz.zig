const std = @import("std");

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
            _ = allocator;

            var result: Result = undefined;
            initializeResultDefaults(args, &result);

            if (argv.len > 0) {
                setUnsupportedInputDiagnostic(argv, options);
                return error.ParseFailed;
            }

            if (firstMissingRequiredArgName(args)) |arg_name| {
                if (options.diagnostic) |diagnostic| {
                    diagnostic.* = .{
                        .kind = .missing_required,
                        .arg_name = arg_name,
                    };
                }
                return error.ParseFailed;
            }

            return result;
        }

        pub fn deinit(allocator: std.mem.Allocator, result: *Result) void {
            _ = allocator;
            _ = result;
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
        if (canInitializeWithoutInput(spec)) {
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
        if (std.mem.findScalar(u8, option_text, '=')) |equals_index| {
            return .{
                .long_option = .{
                    .argv_index = argv_index,
                    .raw = raw,
                    .name = option_text[0..equals_index],
                    .inline_value = option_text[equals_index + 1 ..],
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

fn firstMissingRequiredArgName(comptime args: anytype) ?[]const u8 {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.required and !spec.has_default) {
            return field_info.name;
        }
    }

    return null;
}

fn setUnsupportedInputDiagnostic(argv: []const []const u8, options: ParseOptions) void {
    if (options.diagnostic) |diagnostic| {
        const raw = argv[0];
        diagnostic.* = .{
            .kind = if (raw.len > 1 and raw[0] == '-') .unknown_option else .unexpected_operand,
            .argv_index = 0,
            .raw_arg = raw,
        };
    }
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
