//! CLI argument definitions with comptime validation.

const std = @import("std");

pub const ArgKind = enum {
    /// Boolean option without value (e.g., -v, --verbose)
    flag,
    /// Option with value (e.g., -o file, --output=file)
    option,
    /// Positional argument (e.g., <input>, <files>...)
    positional,
};

pub const ValueType = enum {
    /// Zig type: i64
    integer,
    /// Zig type: f64
    float,
    /// Zig type: bool
    boolean,
    /// Zig type: []const u8
    string,
};

/// Single argument definition.
///
/// Valid field combinations per `ArgKind`:
/// - flag:       short/long (at least one), value_type must be .boolean,
///               required/default/multiple are all forbidden
/// - option:     short/long (at least one required); value_type, required, default, multiple are allowed
/// - positional: value_type, required, default, multiple (short/long forbidden)
///
/// Cross-field constraints (apply to all kinds):
/// - required and default cannot both be set
/// - multiple and default cannot both be set
pub const Arg = struct {
    /// Field name for ParseResult (required).
    /// Must match the Zig identifier character pattern: [a-zA-Z_][a-zA-Z0-9_]*
    ///
    /// Zig keywords (e.g., "type", "error") are also accepted. When a keyword is used,
    /// access the result field via `result.@"type"` or `@field(result, "type")`.
    name: []const u8,
    kind: ArgKind,
    value_type: ValueType = .string,
    /// Long option name (e.g., "output" → --output)
    long: ?[]const u8 = null,
    /// Short option character (e.g., 'o' → -o)
    short: ?u8 = null,
    required: bool = false,
    /// Default value as a string literal.
    /// For non-string value_type (integer, float, boolean), the string is
    /// validated at comptime to ensure it can be parsed to the target type.
    default: ?[]const u8 = null,
    /// Help text for this argument. Currently unused; intended for future help/usage message generation.
    help: ?[]const u8 = null,
    multiple: bool = false,
};

pub const Command = struct {
    /// Command name (required, non-empty)
    name: []const u8,
    /// Description of the command. Currently unused; intended for future help/usage message generation.
    about: ?[]const u8 = null,
    args: []const Arg = &.{},
};

/// Validate a single Arg definition at comptime.
/// Called automatically during RawResult/ParseResult generation;
/// can also be called directly for early validation.
pub fn validateArg(comptime arg: Arg) void {
    validateIdent(arg.name);
    validateKindRules(arg);
    validateConstraints(arg);
    validateNameFormats(arg);
    validateDefault(arg);
}

/// Validate a Command definition and all its Args at comptime.
/// Called automatically during RawResult/ParseResult generation;
/// can also be called directly for early validation.
pub fn validateCommand(comptime cmd: Command) void {
    if (cmd.name.len == 0) {
        @compileError("Invalid Command definition: name cannot be empty");
    }

    inline for (cmd.args) |arg| {
        validateArg(arg);
    }

    validateArgUniqueness(cmd);
    validatePositionalOrder(cmd);
}

fn compileErrorInvalidDefinition(
    comptime context_type: []const u8,
    comptime context_name: []const u8,
    comptime fmt: []const u8,
    comptime args: anytype,
) noreturn {
    @compileError(std.fmt.comptimePrint(
        "Invalid {s} definition '{s}': " ++ fmt,
        .{ context_type, context_name } ++ args,
    ));
}

/// Map a ValueType to the corresponding Zig type used in ParseResult fields.
pub fn valueTypeToZigType(comptime value_type: ValueType) type {
    return switch (value_type) {
        .integer => i64,
        .float => f64,
        .boolean => bool,
        .string => []const u8,
    };
}

pub const ParseBoolError = error{
    InvalidBool,
};

/// Parse a boolean string value.
/// Valid values: "true"/"false" (case-insensitive), "1"/"0" (exact match).
pub fn parseBool(value: []const u8) ParseBoolError!bool {
    return if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true"))
        true
    else if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"))
        false
    else
        error.InvalidBool;
}

/// Check whether a string represents a hex float literal (0x/0X prefix, with optional leading sign).
/// Used by comptime validation (validateDefault, convertDefault) and runtime conversion
/// (convertValue) to reject hex float notation in CLI float arguments.
pub fn isHexFloat(str: []const u8) bool {
    const s = if (str.len > 0 and (str[0] == '+' or str[0] == '-')) str[1..] else str;
    return s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X');
}

fn validateIdent(comptime name: []const u8) void {
    const error_msg = "name must be a valid Zig identifier";
    if (name.len == 0) compileErrorInvalidDefinition("Arg", "", error_msg, .{});

    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) {
        compileErrorInvalidDefinition("Arg", name, error_msg, .{});
    }

    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            compileErrorInvalidDefinition("Arg", name, error_msg, .{});
        }
    }
}

fn validateKindRules(comptime arg: Arg) void {
    switch (arg.kind) {
        .flag => {
            if (arg.value_type != .boolean) {
                compileErrorInvalidDefinition("Arg", arg.name, "flag must have boolean value_type, got {s}", .{@tagName(arg.value_type)});
            }

            if (arg.multiple) {
                compileErrorInvalidDefinition("Arg", arg.name, "flag cannot be multiple", .{});
            }

            if (arg.default != null) {
                compileErrorInvalidDefinition("Arg", arg.name, "flag cannot have default value", .{});
            }

            if (arg.required) {
                compileErrorInvalidDefinition("Arg", arg.name, "flag cannot be required", .{});
            }

            if (arg.short == null and arg.long == null) {
                compileErrorInvalidDefinition("Arg", arg.name, "flag must have long or short", .{});
            }
        },
        .option => {
            if (arg.short == null and arg.long == null) {
                compileErrorInvalidDefinition("Arg", arg.name, "option must have long or short", .{});
            }
        },
        .positional => {
            if (arg.short != null or arg.long != null) {
                compileErrorInvalidDefinition("Arg", arg.name, "positional cannot have long or short", .{});
            }
        },
    }
}

fn validateConstraints(comptime arg: Arg) void {
    if (arg.required and arg.default != null) {
        compileErrorInvalidDefinition("Arg", arg.name, "required and default cannot both be set", .{});
    }

    if (arg.multiple and arg.default != null) {
        compileErrorInvalidDefinition("Arg", arg.name, "multiple cannot have default", .{});
    }
}

fn validateNameFormats(comptime arg: Arg) void {
    if (arg.short) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            compileErrorInvalidDefinition("Arg", arg.name, "short must be alphanumeric", .{});
        }
    }

    if (arg.long) |lname| {
        if (lname.len == 0) {
            compileErrorInvalidDefinition("Arg", arg.name, "long must not be empty", .{});
        }

        if (!std.ascii.isAlphabetic(lname[0])) {
            compileErrorInvalidDefinition("Arg", arg.name, "long must start with a letter", .{});
        }

        for (lname[1..]) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
                compileErrorInvalidDefinition("Arg", arg.name, "long contains invalid character", .{});
            }
        }
    }
}

fn validateDefault(comptime arg: Arg) void {
    const def = arg.default orelse return;
    switch (arg.value_type) {
        .integer => {
            _ = std.fmt.parseInt(i64, def, 10) catch {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid integer", .{def});
            };
        },
        .float => {
            // Reject hex float literals for consistency with runtime convertValue.
            if (isHexFloat(def)) {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' must not use hex float notation", .{def});
            }
            const val = std.fmt.parseFloat(f64, def) catch {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid float", .{def});
            };
            if (!std.math.isFinite(val)) {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid float", .{def});
            }
        },
        .boolean => {
            _ = parseBool(def) catch {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid boolean", .{def});
            };
        },
        .string => {},
    }
}

fn validateArgUniqueness(comptime cmd: Command) void {
    inline for (cmd.args, 0..) |arg_a, i| {
        inline for (cmd.args[i + 1 ..]) |arg_b| {
            if (std.mem.eql(u8, arg_a.name, arg_b.name)) {
                compileErrorInvalidDefinition("Command", cmd.name, "duplicate Arg.name '{s}'", .{arg_a.name});
            }

            if (arg_a.short) |a_short| {
                if (a_short == arg_b.short) {
                    compileErrorInvalidDefinition(
                        "Command",
                        cmd.name,
                        "duplicate Arg.short '-{c}' between '{s}' and '{s}'",
                        .{ a_short, arg_a.name, arg_b.name },
                    );
                }
            }

            if (arg_a.long) |a_long| {
                if (arg_b.long) |b_long| {
                    if (std.mem.eql(u8, a_long, b_long)) {
                        compileErrorInvalidDefinition(
                            "Command",
                            cmd.name,
                            "duplicate Arg.long '--{s}' between '{s}' and '{s}'",
                            .{ a_long, arg_a.name, arg_b.name },
                        );
                    }
                }
            }
        }
    }
}

test "parseBool: accepts valid boolean strings" {
    try std.testing.expectEqual(true, try parseBool("true"));
    try std.testing.expectEqual(true, try parseBool("TRUE"));
    try std.testing.expectEqual(true, try parseBool("True"));
    try std.testing.expectEqual(true, try parseBool("1"));
    try std.testing.expectEqual(false, try parseBool("false"));
    try std.testing.expectEqual(false, try parseBool("FALSE"));
    try std.testing.expectEqual(false, try parseBool("False"));
    try std.testing.expectEqual(false, try parseBool("0"));
}

test "parseBool: rejects invalid strings" {
    try std.testing.expectError(error.InvalidBool, parseBool("yes"));
    try std.testing.expectError(error.InvalidBool, parseBool("no"));
    try std.testing.expectError(error.InvalidBool, parseBool("2"));
    try std.testing.expectError(error.InvalidBool, parseBool(""));
    try std.testing.expectError(error.InvalidBool, parseBool("truthy"));
}

test "isHexFloat: detects hex float literals" {
    try std.testing.expect(isHexFloat("0x1.0p10"));
    try std.testing.expect(isHexFloat("0X1.0p10"));
    try std.testing.expect(isHexFloat("+0x1.0"));
    try std.testing.expect(isHexFloat("-0x1.0"));
    try std.testing.expect(isHexFloat("0xABC"));
}

test "isHexFloat: rejects non-hex strings" {
    try std.testing.expect(!isHexFloat("1.5"));
    try std.testing.expect(!isHexFloat("-1.5"));
    try std.testing.expect(!isHexFloat("0"));
    try std.testing.expect(!isHexFloat(""));
    try std.testing.expect(!isHexFloat("x"));
    try std.testing.expect(!isHexFloat("0b101"));
}

fn validatePositionalOrder(comptime cmd: Command) void {
    var found_multiple = false;
    var found_optional = false;
    inline for (cmd.args) |arg| {
        if (arg.kind == .positional) {
            if (found_multiple) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "positional Arg '{s}' cannot come after a multiple positional argument",
                    .{arg.name},
                );
            }

            if (found_optional and arg.required) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "required positional Arg '{s}' cannot come after an optional positional argument",
                    .{arg.name},
                );
            }

            if (arg.multiple) {
                found_multiple = true;
            }
            if (!arg.required and !arg.multiple) {
                found_optional = true;
            }
        }
    }
}
