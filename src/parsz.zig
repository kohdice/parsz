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
/// to skip diagnostics. Note: `error.OutOfMemory` does NOT populate Diagnostic fields.
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
///
/// WARNING: Do not call deinit() twice on the same result. After the first
/// call, the freed slices still hold their original `len` values, so a second
/// call would attempt to free already-freed memory (undefined behavior).
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

test "integration: GNU-style options after positional (permutation)" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "output", .kind = .option, .short = 'o', .long = "output", .default = "out.txt" },
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "input.txt", "-v", "-o", "result.txt" };
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("result.txt", result.output);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "integration: GNU-style interleaved options and positionals" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "output", .kind = .option, .long = "output", .required = true },
            .{ .name = "count", .kind = .option, .value_type = .integer, .long = "count", .required = true },
            .{ .name = "input", .kind = .positional, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "--output=result.txt", "input.txt", "-v", "--count=5" };
    const result = try parse(testing.allocator, argv, cmd, null);

    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("result.txt", result.output);
    try testing.expectEqual(@as(i64, 5), result.count);
    try testing.expectEqualStrings("input.txt", result.input);
}

test "integration: GNU-style multiple positionals with interleaved options" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
            .{ .name = "files", .kind = .positional, .multiple = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "a.txt", "-v", "b.txt", "c.txt" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expect(result.verbose == true);
    try testing.expectEqual(@as(usize, 3), result.files.len);
    try testing.expectEqualStrings("a.txt", result.files[0]);
    try testing.expectEqualStrings("b.txt", result.files[1]);
    try testing.expectEqualStrings("c.txt", result.files[2]);
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

test "integration: option value containing '='" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "config", .kind = .option, .long = "config", .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"--config=key=value"};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqualStrings("key=value", result.config);
}

test "integration: integer positional argument" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "port", .kind = .positional, .value_type = .integer, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"8080"};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqual(@as(i64, 8080), result.port);
}

test "integration: float positional argument" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "threshold", .kind = .positional, .value_type = .float, .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"0.75"};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectApproxEqAbs(@as(f64, 0.75), result.threshold, 0.001);
}

test "integration: multiple float options" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "ratios", .kind = .option, .value_type = .float, .long = "ratio", .multiple = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "--ratio=1.5", "--ratio=-2.0", "--ratio=3.14" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.ratios.len);
    try testing.expectApproxEqAbs(@as(f64, 1.5), result.ratios[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, -2.0), result.ratios[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.14), result.ratios[2], 0.001);
}

test "integration: short-only option without long" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "num", .kind = .option, .value_type = .integer, .short = 'n', .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "-n", "42" };
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqual(@as(i64, 42), result.num);
}

test "integration: short-only option with inline value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "num", .kind = .option, .value_type = .integer, .short = 'n', .required = true },
        },
    };

    const argv: []const [:0]const u8 = &.{"-n42"};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqual(@as(i64, 42), result.num);
}

test "integration: diagnostic on required multiple missing" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "files", .kind = .positional, .multiple = true, .required = true },
        },
    };

    var diagnostic: Diagnostic = .{};
    const argv: []const [:0]const u8 = &.{};
    try testing.expectError(ParseError.MissingRequired, parse(testing.allocator, argv, cmd, &diagnostic));
    try testing.expectEqualStrings("files", diagnostic.arg_name);
    try testing.expectEqualStrings("", diagnostic.flag_name);
}

test "integration: diagnostic on multiple option InvalidValue includes flag_name" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "nums", .kind = .option, .value_type = .integer, .long = "num", .multiple = true },
        },
    };

    var diagnostic: Diagnostic = .{};
    const argv: []const [:0]const u8 = &.{ "--num=1", "--num=abc" };
    try testing.expectError(ParseError.InvalidValue, parse(testing.allocator, argv, cmd, &diagnostic));
    try testing.expectEqualStrings("nums", diagnostic.arg_name);
    try testing.expectEqualStrings("num", diagnostic.flag_name);
    try testing.expectEqualStrings("abc", diagnostic.provided_value);
}

test "integration: option value that looks like a flag" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "output", .kind = .option, .long = "output", .required = true },
        },
    };

    // "--verbose" is consumed as the value for --output (not as a separate flag)
    const argv: []const [:0]const u8 = &.{ "--output", "--verbose" };
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqualStrings("--verbose", result.output);
}

test "integration: single positional followed by multiple positional" {
    const cmd = Command{
        .name = "cp",
        .args = &.{
            .{ .name = "source", .kind = .positional, .required = true },
            .{ .name = "targets", .kind = .positional, .multiple = true },
        },
    };

    const argv: []const [:0]const u8 = &.{ "src.txt", "dst1.txt", "dst2.txt" };
    var result = try parse(testing.allocator, argv, cmd, null);
    defer deinit(cmd, &result, testing.allocator);

    try testing.expectEqualStrings("src.txt", result.source);
    try testing.expectEqual(@as(usize, 2), result.targets.len);
    try testing.expectEqualStrings("dst1.txt", result.targets[0]);
    try testing.expectEqualStrings("dst2.txt", result.targets[1]);
}

test "integration: positional with default value" {
    const cmd = Command{
        .name = "app",
        .args = &.{
            .{ .name = "mode", .kind = .positional, .default = "normal" },
        },
    };

    // Empty argv → default "normal" applied
    const argv: []const [:0]const u8 = &.{};
    const result = try parse(testing.allocator, argv, cmd, null);
    try testing.expectEqualStrings("normal", result.mode);
}

test "integration: command with no args, empty argv succeeds" {
    const cmd = Command{
        .name = "noop",
        .args = &.{},
    };

    const argv: []const [:0]const u8 = &.{};
    _ = try parse(testing.allocator, argv, cmd, null);
}

test "integration: command with no args, unexpected positional" {
    const cmd = Command{
        .name = "noop",
        .args = &.{},
    };

    const argv: []const [:0]const u8 = &.{"unexpected"};
    try testing.expectError(ParseError.TooManyPositionals, parse(testing.allocator, argv, cmd, null));
}
