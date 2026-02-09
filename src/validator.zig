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

/// Semantic analysis: convert RawResult (all-string) to ParseResult (typed).
///
/// Applies type conversion, required checks, and defaults. Allocates
/// only for `multiple` fields. On error, all partially-built slices
/// are freed via errdefer before returning.
pub fn validate(
    allocator: std.mem.Allocator,
    comptime cmd: Command,
    raw: *parser.RawResult(cmd),
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!ParseResult(cmd) {
    var result: ParseResult(cmd) = undefined;

    // Initialize multiple fields so errdefer deinitResult() is safe.
    // deinitResult() iterates ALL multiple fields, so if validation of field N
    // fails, fields N+1, N+2, etc. must already hold safe values (not undefined).
    // This initialization and the errdefer below must both appear before the
    // validation loop, which is the first point where errors can occur.
    //
    // Non-multiple fields are left as `undefined` here intentionally:
    // deinitResult() only frees `multiple` fields, and the validation loop
    // below will assign all non-multiple fields before `result` is returned.
    inline for (cmd.args) |arg| {
        if (arg.multiple) {
            @field(&result, arg.name) = &.{};
        }
    }

    errdefer deinitResult(cmd, &result, allocator);

    inline for (cmd.args) |arg| {
        if (arg.multiple) {
            @field(&result, arg.name) = try validateMultipleField(
                arg,
                allocator,
                &@field(raw, arg.name),
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
                if (diagnostic) |d| d.* = .{
                    .arg_name = arg.name,
                    .flag_name = comptime flagDisplayName(arg),
                    .provided_value = if (arg.kind != .flag)
                        (@field(raw, arg.name) orelse "")
                    else
                        "",
                };
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
/// Returns ParseError.InvalidValue on parse failure, or
/// ParseError.ValueOutOfRange when a numeric value exceeds the target type's range
/// (integer overflow, float overflow to infinity).
/// T is constrained to integer types (i8..i64, u8..u64), float types (f32, f64),
/// bool, or []const u8 by valueTypeToZigType, making the trailing @compileError
/// unreachable in practice.
///
/// For integers: only base-10 decimal notation is accepted (no hex, octal, or binary prefixes).
/// Range is automatically enforced by std.fmt.parseInt(T, ...).
///
/// For floats: hex float literals (0x...) and non-finite literals (nan, inf) are
/// rejected as InvalidValue. Decimal values that overflow to infinity
/// are rejected as ValueOutOfRange.
///
/// Note: For string type, an empty string (e.g., --output=) is accepted as-is.
/// This is intentional — an empty string is a valid string value.
fn convertValue(comptime T: type, str: []const u8) ParseError!T {
    if (T == []const u8) return str;
    if (T == bool) return definitions.parseBool(str) catch |err| return switch (err) {
        error.InvalidBool => ParseError.InvalidValue,
    };

    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, str, 10) catch |err| return switch (err) {
            error.Overflow => ParseError.ValueOutOfRange,
            error.InvalidCharacter => ParseError.InvalidValue,
        },
        .float => {
            // Reject hex float literals (0x1.fp10, -0xFF, etc.) — CLI arguments
            // should use decimal notation only. std.fmt.parseFloat accepts hex
            // floats per IEEE 754, but that format is not user-friendly for CLI input.
            if (definitions.isHexFloat(str)) {
                return ParseError.InvalidValue;
            }
            const val = std.fmt.parseFloat(T, str) catch |err| return switch (err) {
                error.InvalidCharacter => ParseError.InvalidValue,
            };
            if (!std.math.isFinite(val)) {
                // Distinguish non-finite literals (inf/nan) from numeric overflow.
                // "inf", "nan", etc. are genuinely invalid CLI input → InvalidValue.
                // Decimal numbers that overflow to infinity (e.g., "1e999") exceed
                // the type range → ValueOutOfRange, consistent with integer overflow.
                const s = if (str.len > 0 and (str[0] == '+' or str[0] == '-')) str[1..] else str;
                if (s.len > 0) switch (s[0]) {
                    'i', 'I', 'n', 'N' => return ParseError.InvalidValue,
                    else => {},
                };
                return ParseError.ValueOutOfRange;
            }
            return val;
        },
        else => @compileError("convertValue: unsupported type " ++ @typeName(T)),
    }
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
    if (T == bool) return definitions.parseBool(def) catch
        @compileError("convertDefault: '" ++ def ++ "' is not a valid bool (invariant violation: validateDefault should have caught this)");

    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, def, 10) catch
            @compileError("convertDefault: '" ++ def ++ "' is not a valid " ++ @typeName(T) ++ " (invariant violation: validateDefault should have caught this)"),
        .float => {
            // Defense-in-depth: reject hex float notation and non-finite values.
            // validateDefault() should already catch these, but guard here too
            // in case the two functions drift apart.
            if (definitions.isHexFloat(def))
                @compileError("convertDefault: '" ++ def ++ "' uses hex float notation (invariant violation: validateDefault should have caught this)");
            const val = std.fmt.parseFloat(T, def) catch
                @compileError("convertDefault: '" ++ def ++ "' is not a valid " ++ @typeName(T) ++ " (invariant violation: validateDefault should have caught this)");
            if (!std.math.isFinite(val))
                @compileError("convertDefault: '" ++ def ++ "' is not a finite " ++ @typeName(T) ++ " (invariant violation: validateDefault should have caught this)");
            return val;
        },
        else => @compileError("convertDefault: unsupported type " ++ @typeName(T)),
    }
}

/// Return a display name for the flag/option in diagnostic messages.
/// For flags/options: returns the long name if available, otherwise the short character.
/// For positionals: returns an empty string (no flag form).
fn flagDisplayName(comptime arg: Arg) []const u8 {
    if (arg.long) |long| return long;
    if (arg.short) |s| return &.{s};
    return "";
}

fn validateMultipleField(
    comptime arg: Arg,
    allocator: std.mem.Allocator,
    raw_list: *std.ArrayListUnmanaged([]const u8),
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})![]const definitions.valueTypeToZigType(arg.value_type) {
    const T = definitions.valueTypeToZigType(arg.value_type);
    if (T == []const u8) {
        // Ownership transfer: toOwnedSlice() moves the backing array from
        // the RawResult's ArrayListUnmanaged into the returned slice.
        // Success: raw list is reset to empty → deinitRawResult() is no-op.
        // Failure (OOM): raw list retains its backing buffer →
        //   deinitRawResult() frees it; result field stays &.{} (pre-initialized).
        return try raw_list.toOwnedSlice(allocator);
    }

    // Ownership: allocate a new typed slice and convert each string element.
    // The raw_list's backing buffer is NOT transferred (unlike the string case
    // above); it will be freed by deinitRawResult() after validate() returns.
    const items = raw_list.items;
    if (items.len == 0) {
        return &.{};
    }
    const result = try allocator.alloc(T, items.len);
    errdefer allocator.free(result);

    for (items, 0..) |str, i| {
        result[i] = convertValue(T, str) catch |err| {
            if (diagnostic) |d| d.* = .{
                .arg_name = arg.name,
                .flag_name = comptime flagDisplayName(arg),
                .provided_value = str,
            };
            return err;
        };
    }

    return result;
}

/// Free any heap-allocated `multiple` field slices in a ParseResult.
///
/// Safe to call even when no `multiple` fields exist (no memory is freed). After
/// deinit, the result struct is poisoned to `undefined` to catch
/// use-after-free in Debug/ReleaseSafe builds.
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
            // 2. toOwnedSlice on an empty ArrayList returns a non-heap slice
            // Passing any of these to allocator.free() is invalid (safety-checked illegal behavior).
            if (slice.len > 0) {
                allocator.free(slice);
            }
        }
    }

    // Poison the entire result struct so that any subsequent use (including a
    // second deinit call) triggers a safety-checked illegal behavior in
    // Debug/ReleaseSafe builds. This follows the same pattern as
    // std.ArrayListUnmanaged.deinit which sets `self.* = undefined`.
    result.* = undefined;
}

const testing = std.testing;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

const test_cmd = Command{
    .name = "test",
    .args = &.{
        .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        .{ .name = "output", .kind = .option, .short = 'o', .long = "output", .default = "out.txt" },
        .{ .name = "count", .kind = .option, .value_type = .i64, .long = "count", .required = true },
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
        .{ .name = "ratio", .kind = .option, .value_type = .f64, .long = "ratio", .required = true },
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
        .{ .name = "num", .kind = .option, .value_type = .i64, .long = "num", .required = true },
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
        .{ .name = "nums", .kind = .option, .value_type = .i64, .long = "num", .multiple = true },
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

test "validator: required multiple option with no values → MissingRequired" {
    const req_multi_opt_cmd = Command{
        .name = "rmo",
        .args = &.{
            .{ .name = "tags", .kind = .option, .long = "tag", .multiple = true, .required = true },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, req_multi_opt_cmd, null);
    defer parser.deinitRawResult(req_multi_opt_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, req_multi_opt_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("tags", diagnostic.arg_name);
    try testing.expectEqualStrings("tag", diagnostic.flag_name);
}

test "validator: integer overflow → error" {
    var tok = Tokenizer{ .args = &.{"--num=99999999999999999999"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, int_cmd, &raw, null));
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

// --- Type conversion edge cases and diagnostic tests ---

test "validator: non-finite float variants → error" {
    const cases = .{ "nan", "inf", "-inf", "NaN", "Infinity", "+inf", "-Infinity" };
    inline for (cases) |input| {
        var tok = Tokenizer{ .args = &.{"--ratio=" ++ input} };
        var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
        try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
    }
}

test "validator: hex float literals → error" {
    const cases = .{ "0x1.fp10", "0XFF", "-0x1.0", "+0x1p0", "0x0" };
    inline for (cases) |input| {
        var tok = Tokenizer{ .args = &.{"--ratio=" ++ input} };
        var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
        try testing.expectError(ParseError.InvalidValue, validate(testing.allocator, float_cmd, &raw, null));
    }
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
        .{ .name = "nums", .kind = .option, .value_type = .i64, .long = "num", .multiple = true },
        .{ .name = "ratios", .kind = .option, .value_type = .f64, .long = "ratio", .multiple = true },
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
        .{ .name = "nums", .kind = .option, .value_type = .i64, .short = 'n', .multiple = true },
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
            .{ .name = "nums", .kind = .positional, .value_type = .i64, .multiple = true },
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

test "validator: i64 boundary values" {
    // max i64
    {
        var tok = Tokenizer{ .args = &.{"--num=9223372036854775807"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
        const result = try validate(testing.allocator, int_cmd, &raw, null);
        try testing.expectEqual(@as(i64, 9223372036854775807), result.num);
    }
    // min i64
    {
        var tok = Tokenizer{ .args = &.{"--num=-9223372036854775808"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
        const result = try validate(testing.allocator, int_cmd, &raw, null);
        try testing.expectEqual(@as(i64, -9223372036854775808), result.num);
    }
    // overflow beyond max
    {
        var tok = Tokenizer{ .args = &.{"--num=9223372036854775808"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, int_cmd, &raw, null));
    }
    // underflow beyond min
    {
        var tok = Tokenizer{ .args = &.{"--num=-9223372036854775809"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, int_cmd, &raw, null));
    }
}

test "validator: multiple boolean option" {
    const cmd = Command{
        .name = "mb",
        .args = &.{
            .{ .name = "flags", .kind = .option, .value_type = .boolean, .long = "flag", .multiple = true },
        },
    };
    var tok = Tokenizer{ .args = &.{ "--flag=true", "--flag=false", "--flag=1" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, cmd, &raw, null);
    defer deinitResult(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.flags.len);
    try testing.expectEqual(true, result.flags[0]);
    try testing.expectEqual(false, result.flags[1]);
    try testing.expectEqual(true, result.flags[2]);
}

test "validator: integer with leading zeros is accepted" {
    // std.fmt.parseInt accepts leading zeros (007 → 7)
    var tok = Tokenizer{ .args = &.{"--num=007"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    const result = try validate(testing.allocator, int_cmd, &raw, null);
    try testing.expectEqual(@as(i64, 7), result.num);
}

test "validator: multiple integer positional" {
    const cmd = Command{
        .name = "mip",
        .args = &.{
            .{ .name = "nums", .kind = .positional, .value_type = .i64, .multiple = true },
        },
    };
    // Use "--" to pass negative numbers as positional arguments
    var tok = Tokenizer{ .args = &.{ "10", "--", "-20", "0" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, cmd, &raw, null);
    defer deinitResult(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.nums.len);
    try testing.expectEqual(@as(i64, 10), result.nums[0]);
    try testing.expectEqual(@as(i64, -20), result.nums[1]);
    try testing.expectEqual(@as(i64, 0), result.nums[2]);
}

test "validator: multiple float positional" {
    const cmd = Command{
        .name = "mfp",
        .args = &.{
            .{ .name = "vals", .kind = .positional, .value_type = .f64, .multiple = true },
        },
    };
    // Use "--" to pass negative numbers as positional arguments
    var tok = Tokenizer{ .args = &.{ "1.5", "--", "-2.0", "0.0" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, cmd, &raw, null);
    defer deinitResult(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.vals.len);
    try testing.expectEqual(@as(f64, 1.5), result.vals[0]);
    try testing.expectEqual(@as(f64, -2.0), result.vals[1]);
    try testing.expectEqual(@as(f64, 0.0), result.vals[2]);
}

test "validator: multiple boolean positional" {
    const cmd = Command{
        .name = "mbp",
        .args = &.{
            .{ .name = "flags", .kind = .positional, .value_type = .boolean, .multiple = true },
        },
    };
    var tok = Tokenizer{ .args = &.{ "true", "false", "1", "0" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    var result = try validate(testing.allocator, cmd, &raw, null);
    defer deinitResult(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 4), result.flags.len);
    try testing.expectEqual(true, result.flags[0]);
    try testing.expectEqual(false, result.flags[1]);
    try testing.expectEqual(true, result.flags[2]);
    try testing.expectEqual(false, result.flags[3]);
}

test "validator: diagnostic on ValueOutOfRange includes all fields" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"--num=99999999999999999999"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, int_cmd, null);
    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, int_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("num", diagnostic.arg_name);
    try testing.expectEqualStrings("num", diagnostic.flag_name);
    try testing.expectEqualStrings("99999999999999999999", diagnostic.provided_value);
}

test "validator: multiple integer ValueOutOfRange" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "--num=1", "--num=99999999999999999999" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, multi_int_cmd, null);
    defer parser.deinitRawResult(multi_int_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, multi_int_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("nums", diagnostic.arg_name);
    try testing.expectEqualStrings("num", diagnostic.flag_name);
    try testing.expectEqualStrings("99999999999999999999", diagnostic.provided_value);
}

test "validator: float overflow → ValueOutOfRange" {
    const cases = .{ "1e999", "-1e999", "1e309", "-1e309" };
    inline for (cases) |input| {
        var tok = Tokenizer{ .args = &.{"--ratio=" ++ input} };
        var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, float_cmd, &raw, null));
    }
}

test "validator: diagnostic on float ValueOutOfRange includes all fields" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"--ratio=1e999"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, float_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("ratio", diagnostic.arg_name);
    try testing.expectEqualStrings("ratio", diagnostic.flag_name);
    try testing.expectEqualStrings("1e999", diagnostic.provided_value);
}

test "validator: multiple float ValueOutOfRange" {
    const cmd = Command{
        .name = "mf",
        .args = &.{
            .{ .name = "ratios", .kind = .option, .value_type = .f64, .long = "ratio", .multiple = true },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "--ratio=1.5", "--ratio=1e999" } };
    var raw = try parser.parseTokens(testing.allocator, &tok, cmd, null);
    defer parser.deinitRawResult(cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("ratios", diagnostic.arg_name);
    try testing.expectEqualStrings("ratio", diagnostic.flag_name);
    try testing.expectEqualStrings("1e999", diagnostic.provided_value);
}

test "validator: f64 boundary values succeed" {
    // 1e308 is within f64 range, should succeed
    {
        var tok = Tokenizer{ .args = &.{"--ratio=1e308"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
        const result = try validate(testing.allocator, float_cmd, &raw, null);
        try testing.expectApproxEqAbs(@as(f64, 1e308), result.ratio, 1e293);
    }
    // -1e308 is within f64 range, should succeed
    {
        var tok = Tokenizer{ .args = &.{"--ratio=-1e308"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, float_cmd, null);
        const result = try validate(testing.allocator, float_cmd, &raw, null);
        try testing.expectApproxEqAbs(@as(f64, -1e308), result.ratio, 1e293);
    }
}

test "validator: diagnostic on MissingRequired for short-only option" {
    const short_only_req_cmd = Command{
        .name = "sor",
        .args = &.{
            .{ .name = "num", .kind = .option, .value_type = .i64, .short = 'n', .required = true },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{} };
    var raw = try parser.parseTokens(testing.allocator, &tok, short_only_req_cmd, null);
    defer parser.deinitRawResult(short_only_req_cmd, &raw, testing.allocator);

    try testing.expectError(ParseError.MissingRequired, validate(testing.allocator, short_only_req_cmd, &raw, &diagnostic));
    try testing.expectEqualStrings("num", diagnostic.arg_name);
    try testing.expectEqualStrings("n", diagnostic.flag_name);
}

// --- Narrow numeric type tests ---

const u8_cmd = Command{
    .name = "u8c",
    .args = &.{
        .{ .name = "val", .kind = .option, .value_type = .u8, .long = "val", .required = true },
    },
};

test "validator: u8 boundary values" {
    // 255 is max u8
    {
        var tok = Tokenizer{ .args = &.{"--val=255"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, u8_cmd, null);
        const result = try validate(testing.allocator, u8_cmd, &raw, null);
        try testing.expectEqual(@as(u8, 255), result.val);
    }
    // 0 is min u8
    {
        var tok = Tokenizer{ .args = &.{"--val=0"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, u8_cmd, null);
        const result = try validate(testing.allocator, u8_cmd, &raw, null);
        try testing.expectEqual(@as(u8, 0), result.val);
    }
    // 256 overflows u8
    {
        var tok = Tokenizer{ .args = &.{"--val=256"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, u8_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, u8_cmd, &raw, null));
    }
    // -1 overflows u8 (unsigned cannot be negative)
    {
        var tok = Tokenizer{ .args = &.{"--val=-1"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, u8_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, u8_cmd, &raw, null));
    }
}

const i8_cmd = Command{
    .name = "i8c",
    .args = &.{
        .{ .name = "val", .kind = .option, .value_type = .i8, .long = "val", .required = true },
    },
};

test "validator: i8 boundary values" {
    // 127 is max i8
    {
        var tok = Tokenizer{ .args = &.{"--val=127"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, i8_cmd, null);
        const result = try validate(testing.allocator, i8_cmd, &raw, null);
        try testing.expectEqual(@as(i8, 127), result.val);
    }
    // -128 is min i8
    {
        var tok = Tokenizer{ .args = &.{"--val=-128"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, i8_cmd, null);
        const result = try validate(testing.allocator, i8_cmd, &raw, null);
        try testing.expectEqual(@as(i8, -128), result.val);
    }
    // 128 overflows i8
    {
        var tok = Tokenizer{ .args = &.{"--val=128"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, i8_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, i8_cmd, &raw, null));
    }
    // -129 overflows i8
    {
        var tok = Tokenizer{ .args = &.{"--val=-129"} };
        var raw = try parser.parseTokens(testing.allocator, &tok, i8_cmd, null);
        try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, i8_cmd, &raw, null));
    }
}

const f32_cmd = Command{
    .name = "f32c",
    .args = &.{
        .{ .name = "val", .kind = .option, .value_type = .f32, .long = "val", .required = true },
    },
};

test "validator: f32 basic conversion" {
    var tok = Tokenizer{ .args = &.{"--val=3.14"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, f32_cmd, null);
    const result = try validate(testing.allocator, f32_cmd, &raw, null);
    try testing.expectApproxEqAbs(@as(f32, 3.14), result.val, 0.001);
}

test "validator: f32 overflow → ValueOutOfRange" {
    var tok = Tokenizer{ .args = &.{"--val=1e39"} };
    var raw = try parser.parseTokens(testing.allocator, &tok, f32_cmd, null);
    try testing.expectError(ParseError.ValueOutOfRange, validate(testing.allocator, f32_cmd, &raw, null));
}
