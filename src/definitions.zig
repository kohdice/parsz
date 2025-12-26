//! CLI argument definitions with comptime validation.

const std = @import("std");

/// Argument kind.
pub const ArgKind = enum {
    /// Boolean option without value (e.g., -v, --verbose)
    flag,
    /// Option with value (e.g., -o file, --output=file)
    option,
    /// Positional argument (e.g., <input>, <files>...)
    positional,
};

/// Value type for arguments.
pub const ValueType = enum {
    integer,
    float,
    boolean,
    string,
};

/// Single argument definition.
pub const Arg = struct {
    /// Valid Zig identifier (required)
    name: []const u8,
    kind: ArgKind,
    value_type: ValueType = .string,
    /// Long option name (e.g., "output" → --output)
    long: ?[]const u8 = null,
    /// Short option character (e.g., 'o' → -o)
    short: ?u8 = null,
    required: bool = false,
    /// Default value (string format)
    default: ?[]const u8 = null,
    help: ?[]const u8 = null,
    /// Allow multiple occurrences
    multiple: bool = false,
};

/// Command definition holding multiple `Arg`s.
pub const Command = struct {
    /// Command name (required, non-empty)
    name: []const u8,
    about: ?[]const u8 = null,
    args: []const Arg = &.{},
};

/// Validate Arg at comptime.
pub fn validateArg(comptime arg: Arg) void {
    validateIdent(arg.name);
    validateKindRules(arg);
    validateConstraints(arg);
    validateNameFormats(arg);
    validateDefault(arg);
}

/// Validate Command and all Args at comptime.
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

// Valid values: "true", "false", "1", "0" (case-insensitive)
pub fn parseBool(value: []const u8) ParseBoolError!bool {
    return if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true"))
        true
    else if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"))
        false
    else
        error.InvalidBool;
}

fn validateIdent(comptime name: []const u8) void {
    const error_msg = "name must be a valid Zig identifier";
    if (name.len == 0) compileErrorInvalidDefinition("Arg", "", error_msg, .{});

    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) {
        compileErrorInvalidDefinition("Arg", name, error_msg, .{});
    }

    for (name[1..]) |c| {
        if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_')) {
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
                compileErrorInvalidDefinition("Arg", arg.name, "flag must have long or short.", .{});
            }
        },
        .option => {
            if (arg.short == null and arg.long == null) {
                compileErrorInvalidDefinition("Arg", arg.name, "option must have long or short.", .{});
            }
        },
        .positional => {
            if (arg.short != null or arg.long != null) {
                compileErrorInvalidDefinition("Arg", arg.name, "positional cannot have long or short.", .{});
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
        if (c == '-') {
            compileErrorInvalidDefinition("Arg", arg.name, "short cannot be '-'", .{});
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
            if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) {
                compileErrorInvalidDefinition("Arg", arg.name, "long contains invalid character", .{});
            }
        }
    }
}

fn validateDefault(comptime arg: Arg) void {
    if (arg.default == null) return;

    const def = arg.default.?;
    switch (arg.value_type) {
        .integer => {
            _ = std.fmt.parseInt(i64, def, 10) catch {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid integer", .{def});
            };
        },
        .float => {
            _ = std.parseFloat(f64, def) catch {
                compileErrorInvalidDefinition("Arg", arg.name, "default '{s}' is not a valid float", .{def});
            };
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

            if (arg_a.short != null and arg_b.short != null and arg_a.short.? == arg_b.short.?) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "duplicate Arg.short '-{c}' between '{s}' and '{s}'",
                    .{ arg_a.short.?, arg_a.name, arg_b.name },
                );
            }

            if (arg_a.long != null and arg_b.long != null and std.mem.eql(u8, arg_a.long.?, arg_b.long.?)) {
                compileErrorInvalidDefinition(
                    "Command",
                    cmd.name,
                    "duplicate Arg.long '--{s}' between '{s}' and '{s}'",
                    .{ arg_a.long.?, arg_a.name, arg_b.name },
                );
            }
        }
    }
}

fn validatePositionalOrder(comptime cmd: Command) void {
    var found_multiple = false;
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

            if (arg.multiple) {
                found_multiple = true;
            }
        }
    }
}
