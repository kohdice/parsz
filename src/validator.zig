//! Semantic analysis stage: type conversion and constraint validation.
//!
//! Converts RawResult (string values) into ParseResult (typed values).
//! Checks required fields and applies defaults.

const std = @import("std");
const definitions = @import("definitions.zig");
const errors = @import("errors.zig");
const parser = @import("parser.zig");
const Arg = definitions.Arg;
const Command = definitions.Command;
const Diagnostic = errors.Diagnostic;
const ParseError = errors.ParseError;

/// Comptime-generated struct holding fully typed parse results.
///
/// Field type rules:
/// - flag                        → bool
/// - option/positional, !required, no default, !multiple → ?T
/// - option/positional, required, !multiple              → T
/// - option/positional, has default, !multiple           → T
/// - option/positional, multiple                         → []const T
pub fn ParseResult(comptime cmd: Command) type {
    @setEvalBranchQuota(10_000);
    comptime definitions.validateCommand(cmd);
    var fields: [cmd.args.len]std.builtin.Type.StructField = undefined;
    for (cmd.args, 0..) |arg, i| {
        const T = ParseFieldType(arg);
        fields[i] = .{
            // Comptime concatenation coerces []const u8 to [:0]const u8 for StructField.name
            .name = arg.name ++ "",
            .type = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn ParseFieldType(comptime arg: Arg) type {
    const T = definitions.valueTypeToZigType(arg.value_type);
    return switch (arg.kind) {
        .flag => bool,
        .option, .positional => {
            if (arg.multiple) return []const T;
            if (arg.required or arg.default != null) return T;
            return ?T;
        },
    };
}

pub fn validate(
    allocator: std.mem.Allocator,
    comptime cmd: Command,
    raw: *parser.RawResult(cmd),
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!ParseResult(cmd) {
    var result: ParseResult(cmd) = undefined;

    // Initialize flag and multiple fields so errdefer deinitResult() is safe.
    // This MUST happen before errdefer because deinitResult() iterates ALL
    // multiple fields — if validation of field N fails, fields N+1, N+2, etc.
    // must already hold safe values (not undefined memory).
    inline for (cmd.args) |arg| {
        if (arg.kind == .flag) {
            @field(&result, arg.name) = false;
        } else if (arg.multiple) {
            @field(&result, arg.name) = &.{};
        }
    }

    errdefer deinitResult(cmd, &result, allocator);

    inline for (cmd.args) |arg| {
        if (arg.multiple) {
            @field(&result, arg.name) = try validateMultipleField(
                definitions.valueTypeToZigType(arg.value_type),
                allocator,
                &@field(raw, arg.name),
                arg.name,
                comptime flagDisplayName(arg),
                diagnostic,
            );
            if (arg.required and @field(&result, arg.name).len == 0) {
                if (diagnostic) |d| d.* = .{
                    .arg_name = arg.name,
                    .flag_name = comptime flagDisplayName(arg),
                };
                return ParseError.MissingRequired;
            }
        } else {
            @field(&result, arg.name) = validateField(arg, @field(raw, arg.name)) catch |err| {
                if (diagnostic) |d| {
                    d.arg_name = arg.name;
                    d.flag_name = comptime flagDisplayName(arg);
                    if (arg.kind != .flag) {
                        if (@field(raw, arg.name)) |v| {
                            d.provided_value = v;
                        }
                    }
                }
                return err;
            };
        }
    }

    return result;
}

fn validateField(
    comptime arg: Arg,
    raw_value: parser.RawFieldType(arg),
) ParseError!ParseFieldType(arg) {
    const T = definitions.valueTypeToZigType(arg.value_type);

    switch (arg.kind) {
        .flag => return raw_value,
        .option, .positional => {
            // Single value (multiple is handled separately in validate())
            if (raw_value) |str| {
                return try convertValue(T, str);
            }

            if (arg.required) {
                return ParseError.MissingRequired;
            }

            if (arg.default) |def| {
                return comptime convertDefault(T, def);
            }

            return null;
        },
    }
}

/// Convert a runtime string value to its typed form.
/// Returns ParseError.InvalidValue on parse failure.
/// T is constrained to {[]const u8, i64, f64, bool} by valueTypeToZigType,
/// making the trailing @compileError unreachable in practice.
///
/// Note: For string type, an empty string (e.g., --output=) is accepted as-is.
/// This is intentional — an empty string is a valid string value.
fn convertValue(comptime T: type, str: []const u8) ParseError!T {
    if (T == []const u8) return str;
    if (T == i64) return std.fmt.parseInt(i64, str, 10) catch return ParseError.InvalidValue;
    if (T == f64) {
        const val = std.fmt.parseFloat(f64, str) catch return ParseError.InvalidValue;
        if (std.math.isNan(val) or std.math.isInf(val)) return ParseError.InvalidValue;
        return val;
    }
    if (T == bool) return definitions.parseBool(str) catch return ParseError.InvalidValue;
    @compileError("convertValue: unsupported type " ++ @typeName(T));
}

/// Comptime counterpart of convertValue — converts a default value string
/// to its typed form at comptime.
/// Safety: validateDefault() has already verified the string is valid for
/// the target type. If that invariant ever breaks, @compileError produces
/// a clear message instead of a cryptic "reached unreachable" error.
fn convertDefault(
    comptime T: type,
    comptime def: []const u8,
) T {
    if (T == []const u8) return def;
    if (T == i64) return comptime std.fmt.parseInt(i64, def, 10) catch
        @compileError("convertDefault: '" ++ def ++ "' is not a valid i64 (invariant violation: validateDefault should have caught this)");
    if (T == f64) return comptime std.fmt.parseFloat(f64, def) catch
        @compileError("convertDefault: '" ++ def ++ "' is not a valid f64 (invariant violation: validateDefault should have caught this)");
    if (T == bool) return comptime definitions.parseBool(def) catch
        @compileError("convertDefault: '" ++ def ++ "' is not a valid bool (invariant violation: validateDefault should have caught this)");
    @compileError("convertDefault: unsupported type " ++ @typeName(T));
}

/// Return a display name for the flag/option in diagnostic messages.
/// For options: returns the long name if available, otherwise the short character.
/// For positionals: returns an empty string (no flag form).
fn flagDisplayName(comptime arg: Arg) []const u8 {
    if (arg.long) |long| return long;
    if (arg.short) |s| return &.{s};
    return "";
}

fn validateMultipleField(
    comptime T: type,
    allocator: std.mem.Allocator,
    raw_list: *std.ArrayListUnmanaged([]const u8),
    comptime arg_name: []const u8,
    comptime flag_name: []const u8,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})![]const T {
    if (T == []const u8) {
        // Ownership transfer: toOwnedSlice() moves the backing array from
        // the RawResult's ArrayListUnmanaged into the returned slice.
        // After this call, the raw list is reset to empty (capacity=0,
        // items.len=0), so deinitRawResult() calling .deinit() on it
        // will be a no-op — preventing double-free.
        return try raw_list.toOwnedSlice(allocator);
    }

    const items = raw_list.items;
    const result = try allocator.alloc(T, items.len);
    errdefer allocator.free(result);

    for (items, 0..) |str, i| {
        result[i] = convertValue(T, str) catch |err| {
            if (diagnostic) |d| d.* = .{ .arg_name = arg_name, .flag_name = flag_name, .provided_value = str };
            return err;
        };
    }

    return result;
}

pub fn deinitResult(
    comptime cmd: Command,
    result: *ParseResult(cmd),
    allocator: std.mem.Allocator,
) void {
    // Safe to check only arg.multiple: comptime validation guarantees
    // flags cannot be multiple, so arg.multiple implies non-flag.
    inline for (cmd.args) |arg| {
        if (arg.multiple) {
            const slice = @field(result, arg.name);
            // Guard: We skip free for zero-length slices because:
            // 1. &.{} (comptime empty literal used for initialization) is NOT heap-allocated
            // 2. allocator.alloc(T, 0) returns a non-heap slice per Zig spec
            // 3. toOwnedSlice on an empty ArrayList returns a non-heap slice
            // Passing any of these to allocator.free() is invalid (safety-checked illegal behavior).
            if (slice.len > 0) {
                allocator.free(slice);
            }
        }
    }
}

const testing = std.testing;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

const test_cmd = Command{
    .name = "test",
    .args = &.{
        .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        .{ .name = "output", .kind = .option, .short = 'o', .long = "output", .default = "out.txt" },
        .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .required = true },
        .{ .name = "input", .kind = .positional, .required = true },
    },
};

test "validator: full pipeline" {
    var tok = Tokenizer{ .args = &.{ "-v", "--count=42", "input.txt" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    const result = try validate(testing.allocator, test_cmd, &raw, null);

    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("out.txt", result.output);
    try testing.expectEqual(@as(i64, 42), result.count);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "validator: optional with no value → null" {
    const opt_cmd = Command{
        .name = "opt",
        .args = &.{
            .{ .name = "flag", .kind = .flag, .value_type = .boolean, .long = "flag" },
            .{ .name = "opt_str", .kind = .option, .long = "opt-str" },
        },
    };
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, opt_cmd, null);
    const result = try validate(testing.allocator, opt_cmd, &raw, null);

    try testing.expect(result.flag == false);
    try testing.expectEqual(null, result.opt_str);
}

test "validator: missing required → error" {
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, test_cmd, &raw, null));
}

test "validator: invalid integer → error" {
    var tok = Tokenizer{ .args = &.{ "--count=abc", "input.txt" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, test_cmd, &raw, null));
}

const float_cmd = Command{
    .name = "fc",
    .args = &.{
        .{ .name = "ratio", .kind = .option, .value_type = .float, .long = "ratio", .required = true },
    },
};

const bool_cmd = Command{
    .name = "bc",
    .args = &.{
        .{ .name = "dry_run", .kind = .option, .value_type = .boolean, .long = "dry-run", .required = true },
    },
};

const int_cmd = Command{
    .name = "ic",
    .args = &.{
        .{ .name = "num", .kind = .option, .value_type = .integer, .long = "num", .required = true },
    },
};

test "validator: float conversion" {
    var tok = Tokenizer{ .args = &.{"--ratio=3.14"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    const result = try validate(testing.allocator, float_cmd, &raw, null);
    try testing.expectApproxEqAbs(@as(f64, 3.14), result.ratio, 0.001);
}

test "validator: boolean conversion true" {
    var tok = Tokenizer{ .args = &.{"--dry-run=true"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    const result = try validate(testing.allocator, bool_cmd, &raw, null);
    try testing.expect(result.dry_run == true);
}

test "validator: boolean conversion false" {
    var tok = Tokenizer{ .args = &.{"--dry-run=false"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    const result = try validate(testing.allocator, bool_cmd, &raw, null);
    try testing.expect(result.dry_run == false);
}

test "validator: boolean conversion 1" {
    var tok = Tokenizer{ .args = &.{"--dry-run=1"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    const result = try validate(testing.allocator, bool_cmd, &raw, null);
    try testing.expect(result.dry_run == true);
}

test "validator: boolean conversion 0" {
    var tok = Tokenizer{ .args = &.{"--dry-run=0"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    const result = try validate(testing.allocator, bool_cmd, &raw, null);
    try testing.expect(result.dry_run == false);
}

test "validator: boolean conversion case-insensitive TRUE" {
    var tok = Tokenizer{ .args = &.{"--dry-run=TRUE"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    const result = try validate(testing.allocator, bool_cmd, &raw, null);
    try testing.expect(result.dry_run == true);
}

const multi_cmd = Command{
    .name = "multi",
    .args = &.{
        .{ .name = "files", .kind = .positional, .multiple = true },
    },
};

test "validator: multiple string positional" {
    var tok = Tokenizer{ .args = &.{ "a.txt", "b.txt" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_cmd, null);
    defer parser.deinitRawResult(multi_cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, multi_cmd, &raw, null);
    defer deinitResult(multi_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.files.len);
    try testing.expectEqualStrings("a.txt", result.files[0]);
    try testing.expectEqualStrings("b.txt", result.files[1]);
}

const multi_int_cmd = Command{
    .name = "mi",
    .args = &.{
        .{ .name = "nums", .kind = .option, .value_type = .integer, .long = "num", .multiple = true },
    },
};

test "validator: multiple integer option" {
    var tok = Tokenizer{ .args = &.{ "--num=1", "--num=2", "--num=3" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_int_cmd, null);
    defer parser.deinitRawResult(multi_int_cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, multi_int_cmd, &raw, null);
    defer deinitResult(multi_int_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.nums.len);
    try testing.expectEqual(@as(i64, 1), result.nums[0]);
    try testing.expectEqual(@as(i64, 2), result.nums[1]);
    try testing.expectEqual(@as(i64, 3), result.nums[2]);
}

const req_multi_cmd = Command{
    .name = "rm",
    .args = &.{
        .{ .name = "files", .kind = .positional, .multiple = true, .required = true },
    },
};

test "validator: required multiple with no values → error" {
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, req_multi_cmd, null);
    defer parser.deinitRawResult(req_multi_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, req_multi_cmd, &raw, null));
}

test "validator: required multiple with values → success" {
    var tok = Tokenizer{ .args = &.{ "a.txt", "b.txt" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, req_multi_cmd, null);
    defer parser.deinitRawResult(req_multi_cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, req_multi_cmd, &raw, null);
    defer deinitResult(req_multi_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.files.len);
}

test "validator: integer overflow → error" {
    var tok = Tokenizer{ .args = &.{"--num=99999999999999999999"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, int_cmd, &raw, null));
}

test "validator: invalid float string → error" {
    var tok = Tokenizer{ .args = &.{"--ratio=abc"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
}

test "validator: invalid boolean string → error" {
    var tok = Tokenizer{ .args = &.{"--dry-run=maybe"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, bool_cmd, &raw, null));
}

test "validator: negative float → success" {
    var tok = Tokenizer{ .args = &.{"--ratio=-2.5"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    const result = try validate(testing.allocator, float_cmd, &raw, null);
    try testing.expectApproxEqAbs(@as(f64, -2.5), result.ratio, 0.001);
}

test "validator: negative integer → success" {
    var tok = Tokenizer{ .args = &.{"--num=-42"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    const result = try validate(testing.allocator, int_cmd, &raw, null);
    try testing.expectEqual(@as(i64, -42), result.num);
}

test "validator: diagnostic on missing required" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, test_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("count", diagnostic.arg_name);
}

test "validator: diagnostic on invalid value" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "--count=abc", "input.txt" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, test_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("count", diagnostic.arg_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

test "validator: multiple integer with invalid value → error" {
    var tok = Tokenizer{ .args = &.{ "--num=1", "--num=abc", "--num=3" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_int_cmd, null);
    defer parser.deinitRawResult(multi_int_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, multi_int_cmd, &raw, null));
}

test "validator: deinitResult on empty non-required multiple" {
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_cmd, null);
    defer parser.deinitRawResult(multi_cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, multi_cmd, &raw, null);
    defer deinitResult(multi_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 0), result.files.len);
}

test "validator: diagnostic on multiple integer with invalid value" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "--num=1", "--num=abc", "--num=3" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_int_cmd, null);
    defer parser.deinitRawResult(multi_int_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, multi_int_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("nums", diagnostic.arg_name);
    try testing.expectEqualStrings("num", diagnostic.flag_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

// --- Phase 2 tests ---

test "validator: NaN float → error" {
    var tok = Tokenizer{ .args = &.{"--ratio=nan"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
}

test "validator: Inf float → error" {
    var tok = Tokenizer{ .args = &.{"--ratio=inf"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
}

test "validator: -Inf float → error" {
    var tok = Tokenizer{ .args = &.{"--ratio=-inf"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
}

test "validator: empty string for integer → error" {
    var tok = Tokenizer{ .args = &.{"--num="} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, int_cmd, &raw, null));
}

test "validator: empty string for float → error" {
    var tok = Tokenizer{ .args = &.{"--ratio="} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
}

test "validator: empty string for boolean → error" {
    var tok = Tokenizer{ .args = &.{"--dry-run="} };
    var raw = try parser.parseTokens(testing.allocator, &tok, bool_cmd, null);
    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, bool_cmd, &raw, null));
}

const str_cmd = Command{
    .name = "sc",
    .args = &.{
        .{ .name = "output", .kind = .option, .long = "output", .required = true },
    },
};

test "validator: empty string for string → success" {
    var tok = Tokenizer{ .args = &.{"--output="} };
    var raw = try parser.parseTokens(testing.allocator, &tok, str_cmd, null);
    const result = try validate(testing.allocator, str_cmd, &raw, null);
    try testing.expectEqualStrings("", result.output);
}

const two_multi_cmd = Command{
    .name = "tm",
    .args = &.{
        .{ .name = "nums", .kind = .option, .value_type = .integer, .long = "num", .multiple = true },
        .{ .name = "ratios", .kind = .option, .value_type = .float, .long = "ratio", .multiple = true },
    },
};

test "validator: errdefer safety with multiple fields on partial failure" {
    // Two multiple fields: nums (integer) and ratios (float).
    // nums succeeds, ratios fails → errdefer must free nums without double-free.
    var tok = Tokenizer{ .args = &.{ "--num=1", "--num=2", "--ratio=abc" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, two_multi_cmd, null);
    defer parser.deinitRawResult(two_multi_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, two_multi_cmd, &raw, null));
}

const multi_short_only_cmd = Command{
    .name = "mso",
    .args = &.{
        .{ .name = "nums", .kind = .option, .value_type = .integer, .short = 'n', .multiple = true },
    },
};

test "validator: diagnostic on multiple with short-only option includes flag_name" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "-n", "1", "-n", "abc" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_short_only_cmd, null);
    defer parser.deinitRawResult(multi_short_only_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, multi_short_only_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("nums", diagnostic.arg_name);
    try testing.expectEqualStrings("n", diagnostic.flag_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

test "validator: diagnostic on multiple positional InvalidValue has empty flag_name" {
    const multi_int_pos_cmd = Command{
        .name = "mip",
        .args = &.{
            .{ .name = "nums", .kind = .positional, .value_type = .integer, .multiple = true },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "1", "abc", "3" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_int_pos_cmd, null);
    defer parser.deinitRawResult(multi_int_pos_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, multi_int_pos_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("nums", diagnostic.arg_name);
    try testing.expectEqualStrings("", diagnostic.flag_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

test "validator: diagnostic on missing required includes flag_name" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, test_cmd, null);
    defer parser.deinitRawResult(test_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, test_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("count", diagnostic.arg_name);
    try testing.expectEqualStrings("count", diagnostic.flag_name);
}

test "validator: diagnostic on missing required single positional" {
    const cmd = Command{
        .name = "pos",
        .args = &.{
            .{ .name = "file", .kind = .positional, .required = true },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("file", diagnostic.arg_name);
    try testing.expectEqualStrings("", diagnostic.flag_name);
}

test "validator: parseBool case-insensitive acceptance" {
    // "FALSE" (uppercase) should be accepted as false
    const cmd = Command{
        .name = "booltest",
        .args = &.{
            .{ .name = "flag", .kind = .option, .value_type = .boolean, .long = "flag", .required = true },
        },
    };
    var tok = Tokenizer{ .args = &.{"--flag=FALSE"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    const result = try validate(testing.allocator, cmd, &raw, null);
    try testing.expectEqual(false, result.flag);
}

test "validator: parseBool rejects invalid strings" {
    const cmd = Command{
        .name = "booltest",
        .args = &.{
            .{ .name = "flag", .kind = .option, .value_type = .boolean, .long = "flag", .required = true },
        },
    };

    // "2" is not a valid boolean
    {
        var tok = Tokenizer{ .args = &.{"--flag=2"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
        defer parser.deinitRawResult(cmd, &raw, testing.allocator);
        try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, cmd, &raw, null));
    }
    // "yes" is not a valid boolean
    {
        var tok = Tokenizer{ .args = &.{"--flag=yes"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
        defer parser.deinitRawResult(cmd, &raw, testing.allocator);
        try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, cmd, &raw, null));
    }
    // "no" is not a valid boolean
    {
        var tok = Tokenizer{ .args = &.{"--flag=no"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
        defer parser.deinitRawResult(cmd, &raw, testing.allocator);
        try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, cmd, &raw, null));
    }
}
