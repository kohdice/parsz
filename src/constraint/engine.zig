const std = @import("std");
const errors = @import("../errors.zig");
const ParseError = errors.ParseError;
const Diagnostic = errors.Diagnostic;
const FlagRef = errors.FlagRef;

const spec_arg = @import("../spec/arg.zig");
const getFieldConfig = spec_arg.getFieldConfig;
const argKind = spec_arg.argKind;
const longName = spec_arg.longName;
const spec_constraint = @import("../spec/constraint.zig");

pub fn evaluate(
    comptime T: type,
    comptime config: anytype,
    user_set: std.EnumSet(std.meta.FieldEnum(T)),
    diagnostic: ?*Diagnostic,
) ParseError!void {
    const fields = @typeInfo(T).@"struct".fields;
    const FieldEnum = std.meta.FieldEnum(T);

    inline for (fields) |field| {
        const fc = comptime getFieldConfig(config, field.name);

        if (user_set.contains(@field(FieldEnum, field.name))) {
            // conflicts_with: if this field is user-set, no target may also be user-set
            inline for (fc.conflicts_with) |target| {
                if (user_set.contains(@field(FieldEnum, target))) {
                    if (diagnostic) |d| {
                        const kind = comptime argKind(field.type, fc);
                        d.* = .{
                            .arg_name = field.name,
                            .flag = comptime if (kind == .positional or (kind == .multi and fc.positional)) .none else .{ .long = longName(field.name, fc) },
                            .message = comptime spec_constraint.conflictsMessage(config, target),
                        };
                    }
                    return error.ConflictingArgs;
                }
            }

            // requires: if this field is user-set, all targets must be user-set
            inline for (fc.requires) |target| {
                if (!user_set.contains(@field(FieldEnum, target))) {
                    if (diagnostic) |d| {
                        const kind = comptime argKind(field.type, fc);
                        d.* = .{
                            .arg_name = field.name,
                            .flag = comptime if (kind == .positional or (kind == .multi and fc.positional)) .none else .{ .long = longName(field.name, fc) },
                            .message = comptime spec_constraint.requiresMessage(config, target),
                        };
                    }
                    return error.MissingRequiredBy;
                }
            }
        }
    }
}

pub fn checkRequiredUnlessPresent(
    comptime T: type,
    comptime config: anytype,
    user_set: std.EnumSet(std.meta.FieldEnum(T)),
    comptime field_name: []const u8,
) bool {
    const fc = comptime getFieldConfig(config, field_name);
    inline for (fc.required_unless_present) |target| {
        const FieldEnum = std.meta.FieldEnum(T);
        if (user_set.contains(@field(FieldEnum, target))) {
            return true;
        }
    }
    return false;
}

// --- Unit tests ---

const TestCli = struct {
    json: bool = false,
    csv: bool = false,
    output: ?[]const u8 = null,
    format: ?[]const u8 = null,
    input: ?[]const u8 = null,
    stdin: bool = false,
};

const TestFieldEnum = std.meta.FieldEnum(TestCli);

const test_config = .{
    .json = .{ .short = 'j', .conflicts_with = &.{"csv"} },
    .csv = .{ .short = 'c', .conflicts_with = &.{"json"} },
    .output = .{ .short = 'o' },
    .format = .{ .requires = &.{"output"} },
    .input = .{ .positional = true, .required_unless_present = &.{"stdin"} },
};

test "constraint: conflicts_with both user-set" {
    var user_set = std.EnumSet(TestFieldEnum).initEmpty();
    user_set.insert(.json);
    user_set.insert(.csv);
    var diag: Diagnostic = .{};
    const result = evaluate(TestCli, test_config, user_set, &diag);
    try std.testing.expectError(error.ConflictingArgs, result);
    try std.testing.expectEqualStrings("json", diag.arg_name);
    try std.testing.expect(diag.message.len > 0);
}

test "constraint: conflicts_with one default" {
    var user_set = std.EnumSet(TestFieldEnum).initEmpty();
    user_set.insert(.json);
    // csv not in user_set (has default false, but not user-provided)
    try evaluate(TestCli, test_config, user_set, null);
}

test "constraint: requires all present" {
    var user_set = std.EnumSet(TestFieldEnum).initEmpty();
    user_set.insert(.format);
    user_set.insert(.output);
    try evaluate(TestCli, test_config, user_set, null);
}

test "constraint: requires target missing" {
    var user_set = std.EnumSet(TestFieldEnum).initEmpty();
    user_set.insert(.format);
    // output not in user_set
    var diag: Diagnostic = .{};
    const result = evaluate(TestCli, test_config, user_set, &diag);
    try std.testing.expectError(error.MissingRequiredBy, result);
    try std.testing.expectEqualStrings("format", diag.arg_name);
    try std.testing.expect(diag.message.len > 0);
}

test "constraint: required_unless_present exempted" {
    var user_set = std.EnumSet(TestFieldEnum).initEmpty();
    user_set.insert(.stdin);
    const exempted = checkRequiredUnlessPresent(TestCli, test_config, user_set, "input");
    try std.testing.expect(exempted);
}

test "constraint: required_unless_present not exempted" {
    const user_set = std.EnumSet(TestFieldEnum).initEmpty();
    const exempted = checkRequiredUnlessPresent(TestCli, test_config, user_set, "input");
    try std.testing.expect(!exempted);
}
