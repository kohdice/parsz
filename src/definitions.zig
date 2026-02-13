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

/// Specifies the target Zig type for an argument's value.
///
/// Each variant maps to a Zig primitive type via `valueTypeToZigType()`:
///   .i8-.i64   → i8-i64     (signed integers, base-10 only)
///   .u8-.u64   → u8-u64     (unsigned integers, base-10 only)
///   .f32/.f64  → f32/f64    (decimal floats only, hex/inf/nan rejected)
///   .boolean   → bool       ("true"/"false" case-insensitive, "1"/"0")
///   .string    → []const u8 (raw string, no conversion)
///
/// Default: .string (set via Arg.value_type default)
pub const ValueType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    boolean,
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
    /// Determines how this argument is parsed. Required, no default.
    kind: ArgKind,
    /// Target type for the argument's value. Determines the field type in ParseResult.
    /// Flags must use .boolean. Defaults to .string.
    value_type: ValueType = .string,
    /// Long option name (e.g., "output" → --output)
    long: ?[]const u8 = null,
    /// Short option character (e.g., 'o' → -o)
    short: ?u8 = null,
    /// When true, parsing fails with MissingRequired if this argument is not provided.
    /// Mutually exclusive with `default`. Flags cannot be required.
    required: bool = false,
    /// Default value as a string literal.
    /// For non-string value_type (i8..i64, u8..u64, f32, f64, boolean), the string is
    /// validated at comptime to ensure it can be parsed to the target type.
    default: ?[]const u8 = null,
    /// Help text for this argument. Currently unused; intended for future help/usage message generation.
    help: ?[]const u8 = null,
    /// When true, this argument accepts multiple values.
    /// The corresponding ParseResult field becomes `[]const T` (heap-allocated when non-empty).
    /// The caller must call `deinit()` to free the backing memory.
    /// Cannot be combined with `default`. Flags cannot be multiple.
    multiple: bool = false,
};

pub const Command = struct {
    /// Command name (required, non-empty)
    name: []const u8,
    /// Description of the command. Currently unused; intended for future help/usage message generation.
    about: ?[]const u8 = null,
    /// Argument definitions for this command.
    /// Ordering constraint for positionals: required positionals must come before
    /// optional ones, and at most one `multiple` positional is allowed (must be last).
    /// Names, short characters, and long names must be unique across all args.
    args: []const Arg = &.{},
    /// Subcommand definitions for this command.
    /// When non-empty, ParseResult gains a `subcommand` field (type depends on `subcommand_required`).
    /// Positional args are forbidden when subcommands are defined (ambiguity).
    /// Default `&.{}` ensures full backward compatibility.
    subcommands: []const Command = &.{},
    /// When true, parsing fails with MissingSubcommand if no subcommand is provided.
    /// The ParseResult.subcommand field becomes non-optional (ParseSubcommandUnion).
    /// Only valid when subcommands are defined (subcommands.len > 0).
    subcommand_required: bool = false,
};

/// Look up a subcommand definition by name at comptime.
///
/// Used by `deinitRawResult` and `deinitResult` to resolve the `Command`
/// definition corresponding to a tagged union variant's `@tagName`.
pub fn getSubcommandByName(comptime cmd: Command, comptime name: []const u8) Command {
    for (cmd.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, name)) return sub;
    }
    @compileError("getSubcommandByName: no subcommand '" ++ name ++ "' in command '" ++ cmd.name ++ "'");
}

/// Validate a single Arg definition at comptime.
/// Called automatically during RawResult/ParseResult generation;
/// can also be called directly for early validation.
pub fn validateArg(comptime arg: Arg) void {
    validateIdent("Arg", arg.name);
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

    if (cmd.subcommand_required and cmd.subcommands.len == 0) {
        compileErrorInvalidDefinition(
            "Command",
            cmd.name,
            "subcommand_required cannot be true when no subcommands are defined",
            .{},
        );
    }

    if (cmd.subcommands.len > 0) {
        // Positional args cannot coexist with subcommands: the parser cannot
        // distinguish a subcommand name from a positional argument value.
        inline for (cmd.args) |arg| {
            if (arg.kind == .positional) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "positional Arg '{s}' cannot coexist with subcommands",
                    .{arg.name},
                );
            }
        }

        // The generated struct uses "subcommand" as a field name, so no Arg
        // may claim that name when subcommands are present.
        inline for (cmd.args) |arg| {
            if (std.mem.eql(u8, arg.name, "subcommand")) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "Arg name 'subcommand' is reserved when subcommands are defined",
                    .{},
                );
            }
        }

        validateSubcommandUniqueness(cmd);

        // Recursively validate each subcommand definition.
        inline for (cmd.subcommands) |sub| {
            validateIdent("Subcommand", sub.name);
            validateCommand(sub);
        }
    }
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
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .f32 => f32,
        .f64 => f64,
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

/// Strip a leading '+' or '-' sign from a string, returning the remainder.
/// If the string is empty or does not start with a sign, returns the original string unchanged.
/// Used by isHexFloat (definitions.zig) and convertValue (validator.zig) to normalize
/// numeric strings before prefix/literal classification.
pub fn stripLeadingSign(str: []const u8) []const u8 {
    return if (str.len > 0 and (str[0] == '+' or str[0] == '-')) str[1..] else str;
}

/// Check whether a string has a hex float prefix (0x/0X, with optional leading sign).
/// This is a prefix-only check — it does not validate the full hex float syntax.
/// Used by comptime validation (validateDefault, convertDefault) and runtime conversion
/// (convertValue) to reject hex float notation in CLI float arguments.
pub fn isHexFloat(str: []const u8) bool {
    const s = stripLeadingSign(str);
    return s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X');
}

/// Check whether a string is a non-finite float literal (nan, inf, infinity),
/// with optional leading sign. Case-insensitive.
/// Used by convertValue (validator.zig) to reject non-finite literals **before**
/// calling parseFloat, avoiding reliance on parseFloat's internal representation
/// of inf/nan results.
pub fn isNonFiniteLiteral(str: []const u8) bool {
    const s = stripLeadingSign(str);
    return std.ascii.eqlIgnoreCase(s, "nan") or
        std.ascii.eqlIgnoreCase(s, "inf") or
        std.ascii.eqlIgnoreCase(s, "infinity");
}

fn validateIdent(comptime context_type: []const u8, comptime name: []const u8) void {
    const error_msg = "name must be a valid Zig identifier";
    if (name.len == 0) compileErrorInvalidDefinition(context_type, "", error_msg, .{});

    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) {
        compileErrorInvalidDefinition(context_type, name, error_msg, .{});
    }

    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            compileErrorInvalidDefinition(context_type, name, error_msg, .{});
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
    const T = valueTypeToZigType(arg.value_type);

    if (T == []const u8) return;
    if (T == bool) {
        _ = parseBool(def) catch {
            compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid boolean", .{def});
        };
        return;
    }

    switch (@typeInfo(T)) {
        .int => {
            _ = std.fmt.parseInt(T, def, 10) catch |err| switch (err) {
                error.Overflow => compileErrorInvalidDefinition(
                    "Arg",
                    arg.name,
                    "default '{s}' overflows " ++ @typeName(T) ++ " range",
                    .{def},
                ),
                error.InvalidCharacter => compileErrorInvalidDefinition(
                    "Arg",
                    arg.name,
                    "default '{s}' is not a valid " ++ @typeName(T),
                    .{def},
                ),
            };
        },
        .float => {
            // Reject hex float literals for consistency with runtime convertValue.
            if (isHexFloat(def)) {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' must not use hex float notation", .{def});
            }
            const val = std.fmt.parseFloat(T, def) catch {
                compileErrorInvalidDefinition(
                    "Arg",
                    arg.name,
                    "default '{s}' is not a valid " ++ @typeName(T),
                    .{def},
                );
            };
            if (!std.math.isFinite(val)) {
                compileErrorInvalidDefinition(
                    "Arg",
                    arg.name,
                    "default '{s}' overflows " ++ @typeName(T) ++ " range",
                    .{def},
                );
            }
        },
        else => @compileError("validateDefault: unsupported type " ++ @typeName(T)),
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

test "isNonFiniteLiteral: detects non-finite float literals" {
    try std.testing.expect(isNonFiniteLiteral("nan"));
    try std.testing.expect(isNonFiniteLiteral("NaN"));
    try std.testing.expect(isNonFiniteLiteral("NAN"));
    try std.testing.expect(isNonFiniteLiteral("inf"));
    try std.testing.expect(isNonFiniteLiteral("Inf"));
    try std.testing.expect(isNonFiniteLiteral("INF"));
    try std.testing.expect(isNonFiniteLiteral("infinity"));
    try std.testing.expect(isNonFiniteLiteral("Infinity"));
    try std.testing.expect(isNonFiniteLiteral("INFINITY"));
    try std.testing.expect(isNonFiniteLiteral("+inf"));
    try std.testing.expect(isNonFiniteLiteral("-inf"));
    try std.testing.expect(isNonFiniteLiteral("+nan"));
    try std.testing.expect(isNonFiniteLiteral("-nan"));
    try std.testing.expect(isNonFiniteLiteral("-Infinity"));
    try std.testing.expect(isNonFiniteLiteral("+Infinity"));
}

test "isNonFiniteLiteral: rejects non-literal strings" {
    try std.testing.expect(!isNonFiniteLiteral("1.5"));
    try std.testing.expect(!isNonFiniteLiteral("-1.5"));
    try std.testing.expect(!isNonFiniteLiteral("0"));
    try std.testing.expect(!isNonFiniteLiteral(""));
    try std.testing.expect(!isNonFiniteLiteral("infinite"));
    try std.testing.expect(!isNonFiniteLiteral("nana"));
    try std.testing.expect(!isNonFiniteLiteral("information"));
}

test "isHexFloat: rejects non-hex strings" {
    try std.testing.expect(!isHexFloat("1.5"));
    try std.testing.expect(!isHexFloat("-1.5"));
    try std.testing.expect(!isHexFloat("0"));
    try std.testing.expect(!isHexFloat(""));
    try std.testing.expect(!isHexFloat("x"));
    try std.testing.expect(!isHexFloat("0b101"));
}

fn validateSubcommandUniqueness(comptime cmd: Command) void {
    inline for (cmd.subcommands, 0..) |sub_a, i| {
        inline for (cmd.subcommands[i + 1 ..]) |sub_b| {
            if (std.mem.eql(u8, sub_a.name, sub_b.name)) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "duplicate subcommand name '{s}'",
                    .{sub_a.name},
                );
            }
        }
    }
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
