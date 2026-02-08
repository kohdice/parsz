//! parsz — A CLI argument parser library using only the Zig standard library.
//!
//! Parses command-line arguments through a 3-stage pipeline:
//!   1. Tokenizer (lexical analysis): classifies argv elements by form
//!   2. Parser (syntactic analysis): binds tokens to argument definitions
//!   3. Validator (semantic analysis): type conversion and constraint checks

const std = @import("std");

const definitions = @import("definitions.zig");
const errors = @import("errors.zig");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const validator = @import("validator.zig");

pub const Arg = definitions.Arg;
pub const ArgKind = definitions.ArgKind;
pub const Command = definitions.Command;
pub const ValueType = definitions.ValueType;

pub const Diagnostic = errors.Diagnostic;
pub const ParseError = errors.ParseError;

pub const ParseResult = validator.ParseResult;

/// Parse command-line arguments through the 3-stage pipeline.
///
/// `argv` should NOT include the program name (argv[0]).
/// Callers typically pass `args[1..]` from `std.process.argsAlloc()`.
///
/// The Command definition is validated at compile time. At runtime:
///   1. Tokenizer classifies each argv element (zero allocation)
///   2. Parser binds tokens to argument definitions (allocates only for `multiple` args)
///   3. Validator converts strings to typed values and checks constraints
///      (transfers ownership for `multiple` string args via toOwnedSlice;
///       allocates new typed arrays for `multiple` non-string args)
///
/// Returns a comptime-generated struct with typed fields matching the Command definition.
/// Call `deinit()` to free any memory allocated for `multiple` arguments.
///
/// Pass a `*Diagnostic` to receive detailed error context on failure, or `null`
/// to skip diagnostics.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    comptime cmd: Command,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!ParseResult(cmd) {
    var tok = tokenizer.Tokenizer{ .args = argv };

    var raw = try parser.parseTokens(allocator, &tok, cmd, diagnostic);
    defer parser.deinitRawResult(cmd, &raw, allocator);

    return try validator.validate(allocator, cmd, &raw, diagnostic);
}

/// Free any memory owned by a ParseResult.
///
/// This releases backing arrays for `multiple` arguments.
/// For commands with no `multiple` arguments, this is a no-op.
pub fn deinit(
    comptime cmd: Command,
    result: *ParseResult(cmd),
    allocator: std.mem.Allocator,
) void {
    validator.deinitResult(cmd, result, allocator);
}

test {
    _ = tokenizer;
    _ = parser;
    _ = validator;
}

const testing = std.testing;

test "integration: basic flag + option + positional" {
    const cmd = Command{
        .name = "myapp",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "output", .kind = .option, .short = 'o', .long = "output", .default = "out.txt" },
            .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .required = true },
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "-v", "-o", "result.txt", "--count=5", "input.txt" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("result.txt", result.output);
    try testing.expectEqual(@as(i64, 5), result.count);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "integration: defaults applied" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "output", .kind = .option, .long = "output", .default = "default.txt" },
            .{ .name = "level", .kind = .option, .value_type = .integer, .long = "level", .default = "3" },
        },
    };

    const argv: []const [:0]const u8 = &.{};
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expectEqualStrings("default.txt", result.output);
    try testing.expectEqual(@as(i64, 3), result.level);
}

test "integration: '--' ends option parsing" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "file", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "--", "-v" };
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expect(result.verbose == false);
    try testing.expectEqualStrings("-v", result.file);
}

test "integration: short cluster with inline value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "output", .kind = .option, .short = 'o', .long = "output", .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"-vofile.txt"};
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("file.txt", result.output);
}

test "integration: multiple positional arguments" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "files", .kind = .positional, .multiple = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "a.txt", "b.txt", "c.txt" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.files.len);
    try testing.expectEqualStrings("a.txt", result.files[0]);
    try testing.expectEqualStrings("b.txt", result.files[1]);
    try testing.expectEqualStrings("c.txt", result.files[2]);
}

test "integration: missing required → MissingRequired" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{};
    try testing.expectError(ParseError.MissingRequired, parse(testing.allocator, argv, cmd, null));
}

test "integration: unknown flag → UnknownFlag" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        },
    };

    const argv: []const [:0]const u8 = &.{"-x"};
    try testing.expectError(ParseError.UnknownFlag, parse(testing.allocator, argv, cmd, null));
}

test "integration: '-' alone is positional (POSIX G13)" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"-"};
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expectEqualStrings("-", result.input);
}

test "integration: diagnostic provides error context" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .required = true },
        },
    };

    var diagnostic: Diagnostic = .{};
    const argv: []const [:0]const u8 = &.{"--count=abc"};
    try testing.expectError(ParseError.InvalidValue, parse(testing.allocator, argv, cmd, &diagnostic));
    try testing.expectEqualStrings("count", diagnostic.arg_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

test "integration: negative integer as option value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "offset", .kind = .option, .value_type = .integer, .long = "offset", .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"--offset=-10"};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqual(@as(i64, -10), result.offset);
}

test "integration: '--' with multiple positionals captures flag-like strings" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "files", .kind = .positional, .multiple = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "--", "-v", "--verbose", "file.txt" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expect(result.verbose == false);
    try testing.expectEqual(@as(usize, 3), result.files.len);
    try testing.expectEqualStrings("-v", result.files[0]);
    try testing.expectEqualStrings("--verbose", result.files[1]);
    try testing.expectEqualStrings("file.txt", result.files[2]);
}

test "integration: Zig keyword as arg name" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "type", .kind = .option, .long = "type", .required = true },
            .{ .name = "error", .kind = .positional },
        },
    };

    const argv: []const [:0]const u8 = &.{ "--type", "json", "some-error" };
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expectEqualStrings("json", @field(result, "type"));
    try testing.expectEqualStrings("some-error", @field(result, "error").?);
}

test "integration: short option with separate negative integer value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "count", .kind = .option, .value_type = .integer, .short = 'c', .long = "count", .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "-c", "-10" };
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqual(@as(i64, -10), result.count);
}

// --- Phase 2 integration tests ---

test "integration: float default applied" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "ratio", .kind = .option, .value_type = .float, .long = "ratio", .default = "1.5" },
        },
    };

    const argv: []const [:0]const u8 = &.{};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectApproxEqAbs(@as(f64, 1.5), result.ratio, 0.001);
}

test "integration: boolean default applied" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "dry_run", .kind = .option, .value_type = .boolean, .long = "dry-run", .default = "true" },
        },
    };

    const argv: []const [:0]const u8 = &.{};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expect(result.dry_run == true);
}

test "integration: duplicate flag is idempotent" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "-v", "--verbose", "input.txt" };
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "integration: repeated short flag cluster" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "-vv", "input.txt" };
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "integration: empty string option value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "output", .kind = .option, .long = "output", .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"--output="};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqualStrings("", result.output);
}
