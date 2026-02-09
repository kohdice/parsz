//! Syntactic analysis stage: binds tokens to argument definitions.
//!
//! Uses comptime Command definitions as a "symbol table" to resolve
//! ambiguities (e.g., is `-o file` an option with value, or a flag + positional?).
//! Generates RawResult — a comptime struct whose fields are bool (flags),
//! ?[]const u8 (single options/positionals), or ArrayListUnmanaged (multiple).
//!
//! Note: This parser deliberately deviates from POSIX Guideline 9
//! (all options before operands). Options and positional arguments can be
//! freely interleaved (GNU-style permutation), matching modern CLI tool
//! behavior (e.g., git, cargo, gcc).

const std = @import("std");
const definitions = @import("definitions.zig");
const errors = @import("errors.zig");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
const Arg = definitions.Arg;
const Command = definitions.Command;
const Diagnostic = errors.Diagnostic;
const ParseError = errors.ParseError;

/// Comptime-generated struct holding raw (string) parse results.
///
/// Field types:
/// - flag           → bool            (initial: false)
/// - single option  → ?[]const u8     (initial: null)
/// - single positional → ?[]const u8  (initial: null)
/// - multiple option/positional → std.ArrayListUnmanaged([]const u8)  (initial: .{})
pub fn RawResult(comptime cmd: Command) type {
    @setEvalBranchQuota(10_000);
    comptime definitions.validateCommand(cmd);
    var fields: [cmd.args.len]std.builtin.Type.StructField = undefined;
    for (cmd.args, 0..) |arg, i| {
        const T = RawFieldType(arg);
        fields[i] = .{
            // Comptime concatenation coerces []const u8 to [:0]const u8 for StructField.name
            .name = arg.name ++ "",
            .type = T,
            .default_value_ptr = @ptrCast(&rawFieldDefault(arg)),
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

/// Map an Arg definition to its RawResult field type.
///
/// - flag           → bool
/// - single option/positional  → ?[]const u8
/// - multiple option/positional → std.ArrayListUnmanaged([]const u8)
///
/// Used by RawResult (parser.zig) for struct generation and by
/// validateField (validator.zig) for parameter type resolution.
pub fn RawFieldType(comptime arg: Arg) type {
    return switch (arg.kind) {
        .flag => bool,
        .option, .positional => if (arg.multiple)
            std.ArrayListUnmanaged([]const u8)
        else
            ?[]const u8,
    };
}

fn rawFieldDefault(comptime arg: Arg) RawFieldType(arg) {
    return switch (arg.kind) {
        .flag => false,
        .option, .positional => if (arg.multiple)
            std.ArrayListUnmanaged([]const u8){}
        else
            null,
    };
}

/// Parse a token stream into RawResult.
///
/// Uses a comptime-driven linear matching approach: helper functions match each
/// token against the Command definition using `inline for` for zero-cost dispatch.
pub fn parseTokens(
    allocator: std.mem.Allocator,
    tok: *Tokenizer,
    comptime cmd: Command,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!RawResult(cmd) {
    var result: RawResult(cmd) = .{};
    errdefer deinitRawResult(cmd, &result, allocator);

    var positional_index: usize = 0;

    while (tok.next()) |token| {
        switch (token) {
            .short => |cluster| {
                try handleShortCluster(cmd, &result, tok, allocator, cluster, diagnostic);
            },
            .long => |long| {
                try handleLong(cmd, &result, tok, allocator, long.name, long.value, diagnostic);
            },
            .positional => |value| {
                try handlePositional(
                    cmd,
                    &result,
                    allocator,
                    &positional_index,
                    value,
                    diagnostic,
                );
            },
            .end_of_options => {
                // Intentional no-op: the Tokenizer already set options_ended=true,
                // so all subsequent tokens will arrive as .positional.
            },
        }
    }

    return result;
}

fn handleShortCluster(
    comptime cmd: Command,
    result: *RawResult(cmd),
    tok: *Tokenizer,
    allocator: std.mem.Allocator,
    cluster: []const u8,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!void {
    // Invariant: Tokenizer never produces a zero-length short cluster.
    // A "-" alone is classified as .positional, and "-x..." always yields len >= 1.
    std.debug.assert(cluster.len > 0);
    var i: usize = 0;
    while (i < cluster.len) {
        const ch = cluster[i];
        var found = false;

        inline for (cmd.args) |arg| {
            if (comptime arg.short) |short_ch| {
                if (short_ch == ch) {
                    found = true;
                    switch (arg.kind) {
                        .flag => {
                            // Flags are idempotent: repeating -v or -vv
                            // simply sets the bool to true again.
                            @field(result, arg.name) = true;
                        },
                        .option, .positional => {
                            // .positional is unreachable here: comptime validation
                            // (validateKindRules) forbids positionals from having
                            // short names. Sharing the branch avoids `else => unreachable`.
                            comptime std.debug.assert(arg.kind == .option);
                            const value: []const u8 = if (i + 1 < cluster.len)
                                cluster[i + 1 ..]
                            else
                                tok.nextRaw() orelse {
                                    if (diagnostic) |d| d.* = .{ .arg_name = arg.name, .flag_name = cluster[i .. i + 1] };
                                    return ParseError.MissingValue;
                                };

                            try assignValue(cmd, result, allocator, arg, value, cluster[i .. i + 1], diagnostic);
                            return; // Rest of cluster consumed as option value
                        },
                    }
                }
            }
        }

        if (!found) {
            if (diagnostic) |d| d.* = .{ .flag_name = cluster[i .. i + 1] };
            return ParseError.UnknownFlag;
        }
        i += 1;
    }
}

fn handleLong(
    comptime cmd: Command,
    result: *RawResult(cmd),
    tok: *Tokenizer,
    allocator: std.mem.Allocator,
    name: []const u8,
    inline_value: ?[]const u8,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!void {
    inline for (cmd.args) |arg| {
        if (arg.long) |long_name| {
            if (std.mem.eql(u8, name, long_name)) {
                switch (arg.kind) {
                    .flag => {
                        if (inline_value) |val| {
                            if (diagnostic) |d| d.* = .{ .arg_name = arg.name, .flag_name = long_name, .provided_value = val };
                            return ParseError.InvalidValue;
                        }
                        // See handleShortCluster for rationale on flag idempotency.
                        @field(result, arg.name) = true;
                        return;
                    },
                    .option, .positional => {
                        // .positional is unreachable here: comptime validation
                        // (validateKindRules) forbids positionals from having
                        // long names. Sharing the branch avoids `else => unreachable`.
                        comptime std.debug.assert(arg.kind == .option);
                        const value = inline_value orelse
                            tok.nextRaw() orelse {
                            if (diagnostic) |d| d.* = .{ .arg_name = arg.name, .flag_name = long_name };
                            return ParseError.MissingValue;
                        };

                        try assignValue(cmd, result, allocator, arg, value, long_name, diagnostic);
                        return;
                    },
                }
            }
        }
    }
    if (diagnostic) |d| d.* = .{ .flag_name = name };
    return ParseError.UnknownFlag;
}

/// Assign a positional value to the next unbound positional argument definition.
///
/// Uses positional_index to track which positional Arg should receive the next value.
/// For non-multiple args, the index advances after assignment. For multiple args,
/// the index stays, so all subsequent positional values accumulate in the same field.
fn handlePositional(
    comptime cmd: Command,
    result: *RawResult(cmd),
    allocator: std.mem.Allocator,
    positional_index: *usize,
    value: []const u8,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!void {
    const positional_args = comptime blk: {
        var args: []const Arg = &.{};
        for (cmd.args) |arg| {
            if (arg.kind == .positional) {
                args = args ++ .{arg};
            }
        }
        break :blk args;
    };

    inline for (positional_args, 0..) |arg, pidx| {
        if (positional_index.* == pidx) {
            if (arg.multiple) {
                try @field(result, arg.name).append(allocator, value);
            } else {
                @field(result, arg.name) = value;
                positional_index.* = pidx + 1;
            }
            return;
        }
    }

    if (diagnostic) |d| d.* = .{
        .arg_name = if (positional_args.len > 0) positional_args[positional_args.len - 1].name else "",
        .provided_value = value,
    };
    return ParseError.TooManyPositionals;
}

/// Assign a value to a named option field in the RawResult.
/// For multiple options: appends to the ArrayListUnmanaged.
/// For single options: sets the field, or returns DuplicateArg if already set.
fn assignValue(
    comptime cmd: Command,
    result: *RawResult(cmd),
    allocator: std.mem.Allocator,
    comptime arg: Arg,
    value: []const u8,
    flag_name: []const u8,
    diagnostic: ?*Diagnostic,
) (ParseError || error{OutOfMemory})!void {
    if (arg.multiple) {
        try @field(result, arg.name).append(allocator, value);
    } else {
        if (@field(result, arg.name) != null) {
            if (diagnostic) |d| d.* = .{ .arg_name = arg.name, .flag_name = flag_name, .provided_value = value };
            return ParseError.DuplicateArg;
        }
        @field(result, arg.name) = value;
    }
}

/// Free any ArrayListUnmanaged backing arrays in a RawResult.
pub fn deinitRawResult(
    comptime cmd: Command,
    result: *RawResult(cmd),
    allocator: std.mem.Allocator,
) void {
    inline for (cmd.args) |arg| {
        // Safe to check only arg.multiple: comptime validation guarantees
        // flags cannot be multiple, so arg.multiple implies non-flag.
        if (arg.multiple) {
            @field(result, arg.name).deinit(allocator);
        }
    }
    result.* = undefined;
}

const testing = std.testing;

const test_cmd = Command{
    .name = "test",
    .args = &.{
        .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .short = 'v', .long = "verbose" },
        .{ .name = "output", .kind = .option, .short = 'o', .long = "output" },
        .{ .name = "count", .kind = .option, .value_type = .i64, .long = "count", .required = true },
        .{ .name = "input", .kind = .positional, .required = true },
    },
};

test "parser: flag short" {
    var tok = Tokenizer{ .args = &.{"-v"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == true);
}

test "parser: flag long" {
    var tok = Tokenizer{ .args = &.{"--verbose"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == true);
}

test "parser: option short with separate value" {
    var tok = Tokenizer{ .args = &.{ "-o", "file.txt" } };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expectEqualStrings("file.txt", result.output.?);
}

test "parser: option short with inline cluster value" {
    var tok = Tokenizer{ .args = &.{"-ofile.txt"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expectEqualStrings("file.txt", result.output.?);
}

test "parser: option long with separate value" {
    var tok = Tokenizer{ .args = &.{ "--output", "file.txt" } };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expectEqualStrings("file.txt", result.output.?);
}

test "parser: option long with inline value" {
    var tok = Tokenizer{ .args = &.{"--output=file.txt"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expectEqualStrings("file.txt", result.output.?);
}

test "parser: positional argument" {
    var tok = Tokenizer{ .args = &.{"input.txt"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expectEqualStrings("input.txt", result.input.?);
}

test "parser: short cluster -vo file" {
    var tok = Tokenizer{ .args = &.{ "-vo", "file.txt" } };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("file.txt", result.output.?);
}

test "parser: short cluster -vof (inline value)" {
    var tok = Tokenizer{ .args = &.{"-vof"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("f", result.output.?);
}

test "parser: mixed arguments" {
    var tok = Tokenizer{ .args = &.{ "-v", "--output=out.txt", "--count", "5", "input.txt" } };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == true);
    try testing.expectEqualStrings("out.txt", result.output.?);
    try testing.expectEqualStrings("5", result.count.?);
    try testing.expectEqualStrings("input.txt", result.input.?);
}

test "parser: '--' ends options" {
    var tok = Tokenizer{ .args = &.{ "--", "-v" } };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == false);
    try testing.expectEqualStrings("-v", result.input.?);
}

test "parser: unknown short flag" {
    var tok = Tokenizer{ .args = &.{"-x"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: unknown long flag" {
    var tok = Tokenizer{ .args = &.{"--unknown"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: missing value for option" {
    var tok = Tokenizer{ .args = &.{"--output"} };
    try testing.expectError(ParseError.MissingValue, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: flag with inline value" {
    var tok = Tokenizer{ .args = &.{"--verbose=true"} };
    try testing.expectError(ParseError.InvalidValue, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: duplicate non-multiple option" {
    var tok = Tokenizer{ .args = &.{ "--output=a", "--output=b" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: too many positionals" {
    var tok = Tokenizer{ .args = &.{ "a", "b" } };
    try testing.expectError(ParseError.TooManyPositionals, parseTokens(testing.allocator, &tok, test_cmd, null));
}

const multi_cmd = Command{
    .name = "multi",
    .args = &.{
        .{ .name = "files", .kind = .positional, .multiple = true },
    },
};

test "parser: multiple positional" {
    var tok = Tokenizer{ .args = &.{ "a.txt", "b.txt", "c.txt" } };
    var result = try parseTokens(testing.allocator, &tok, multi_cmd, null);
    defer deinitRawResult(multi_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 3), result.files.items.len);
    try testing.expectEqualStrings("a.txt", result.files.items[0]);
    try testing.expectEqualStrings("b.txt", result.files.items[1]);
    try testing.expectEqualStrings("c.txt", result.files.items[2]);
}

const multi_option_cmd = Command{
    .name = "multi_opt",
    .args = &.{
        .{ .name = "include", .kind = .option, .long = "include", .multiple = true },
    },
};

test "parser: multiple option" {
    var tok = Tokenizer{ .args = &.{ "--include=a", "--include=b" } };
    var result = try parseTokens(testing.allocator, &tok, multi_option_cmd, null);
    defer deinitRawResult(multi_option_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.include.items.len);
    try testing.expectEqualStrings("a", result.include.items[0]);
    try testing.expectEqualStrings("b", result.include.items[1]);
}

test "parser: short option missing value at end of argv" {
    var tok = Tokenizer{ .args = &.{"-o"} };
    try testing.expectError(ParseError.MissingValue, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: diagnostic on unknown short flag" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"-x"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("x", diagnostic.flag_name);
}

test "parser: diagnostic on unknown long flag" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"--unknown"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("unknown", diagnostic.flag_name);
}

test "parser: diagnostic on missing value" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"--output"} };
    try testing.expectError(ParseError.MissingValue, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("output", diagnostic.arg_name);
    try testing.expectEqualStrings("output", diagnostic.flag_name);
}

test "parser: diagnostic on duplicate arg" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "--output=a", "--output=b" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("output", diagnostic.arg_name);
    try testing.expectEqualStrings("b", diagnostic.provided_value);
}

test "parser: diagnostic on too many positionals" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "a", "b" } };
    try testing.expectError(ParseError.TooManyPositionals, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("b", diagnostic.provided_value);
}

test "parser: diagnostic on short option missing value" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"-o"} };
    try testing.expectError(ParseError.MissingValue, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("output", diagnostic.arg_name);
    try testing.expectEqualStrings("o", diagnostic.flag_name);
}

test "parser: diagnostic on duplicate arg includes flag_name" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "-o", "a", "-o", "b" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("output", diagnostic.arg_name);
    try testing.expectEqualStrings("o", diagnostic.flag_name);
    try testing.expectEqualStrings("b", diagnostic.provided_value);
}

test "parser: diagnostic on flag with inline value" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{"--verbose=true"} };
    try testing.expectError(ParseError.InvalidValue, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("verbose", diagnostic.arg_name);
    try testing.expectEqualStrings("verbose", diagnostic.flag_name);
    try testing.expectEqualStrings("true", diagnostic.provided_value);
}

// --- Multiple options, errdefer, and diagnostic edge case tests ---

const multi_short_opt_cmd = Command{
    .name = "mso",
    .args = &.{
        .{ .name = "include", .kind = .option, .short = 'I', .long = "include", .multiple = true },
    },
};

test "parser: multiple option via short flag" {
    var tok = Tokenizer{ .args = &.{ "-I", "a", "-I", "b" } };
    var result = try parseTokens(testing.allocator, &tok, multi_short_opt_cmd, null);
    defer deinitRawResult(multi_short_opt_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.include.items.len);
    try testing.expectEqualStrings("a", result.include.items[0]);
    try testing.expectEqualStrings("b", result.include.items[1]);
}

test "parser: diagnostic on too many positionals includes arg_name" {
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "a", "b" } };
    try testing.expectError(ParseError.TooManyPositionals, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("input", diagnostic.arg_name);
    try testing.expectEqualStrings("b", diagnostic.provided_value);
}

test "parser: errdefer frees multiple field on subsequent error" {
    const cmd = Command{
        .name = "errd",
        .args = &.{
            .{ .name = "files", .kind = .positional, .multiple = true },
        },
    };
    var tok = Tokenizer{ .args = &.{ "a.txt", "b.txt", "-x" } };
    // -x is an unknown flag → UnknownFlag error.
    // The multiple field "files" must be freed by errdefer without leaking.
    // testing.allocator detects leaks, so this test passing proves cleanup works.
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, cmd, null));
}

test "parser: unknown char in middle of short cluster" {
    var diagnostic: Diagnostic = .{};
    // -v is valid flag, x is unknown → UnknownFlag with diagnostic.flag_name = "x"
    var tok = Tokenizer{ .args = &.{"-vx"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, test_cmd, &diagnostic));
    try testing.expectEqualStrings("x", diagnostic.flag_name);
}

test "parser: multiple option long with separate values" {
    var tok = Tokenizer{ .args = &.{ "--include", "a", "--include", "b" } };
    var result = try parseTokens(testing.allocator, &tok, multi_option_cmd, null);
    defer deinitRawResult(multi_option_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.include.items.len);
    try testing.expectEqualStrings("a", result.include.items[0]);
    try testing.expectEqualStrings("b", result.include.items[1]);
}

test "parser: multiple option via short inline value" {
    var tok = Tokenizer{ .args = &.{ "-Ia", "-Ib" } };
    var result = try parseTokens(testing.allocator, &tok, multi_short_opt_cmd, null);
    defer deinitRawResult(multi_short_opt_cmd, &result, testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.include.items.len);
    try testing.expectEqualStrings("a", result.include.items[0]);
    try testing.expectEqualStrings("b", result.include.items[1]);
}

test "parser: duplicate via mixed short and long" {
    var tok = Tokenizer{ .args = &.{ "-o", "a", "--output=b" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: duplicate via mixed long then short" {
    var tok = Tokenizer{ .args = &.{ "--output=a", "-o", "b" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, test_cmd, null));
}

test "parser: short cluster starting with option consumes rest as value" {
    // -ov: 'o' is an option, so "v" is consumed as its value (not as flag -v)
    var tok = Tokenizer{ .args = &.{"-ov"} };
    const result = try parseTokens(testing.allocator, &tok, test_cmd, null);
    try testing.expect(result.verbose == false);
    try testing.expectEqualStrings("v", result.output.?);
}

test "parser: diagnostic on duplicate short-only option" {
    const short_only_cmd = Command{
        .name = "so",
        .args = &.{
            .{ .name = "num", .kind = .option, .value_type = .i64, .short = 'n' },
        },
    };
    var diagnostic: Diagnostic = .{};
    var tok = Tokenizer{ .args = &.{ "-n", "1", "-n", "2" } };
    try testing.expectError(ParseError.DuplicateArg, parseTokens(testing.allocator, &tok, short_only_cmd, &diagnostic));
    try testing.expectEqualStrings("num", diagnostic.arg_name);
    try testing.expectEqualStrings("n", diagnostic.flag_name);
    try testing.expectEqualStrings("2", diagnostic.provided_value);
}

test "parser: long name substring does not match" {
    // --verb should not match --verbose
    const cmd = Command{
        .name = "sub",
        .args = &.{
            .{ .name = "verbose", .kind = .flag, .value_type = .boolean, .long = "verbose" },
        },
    };
    var tok = Tokenizer{ .args = &.{"--verb"} };
    try testing.expectError(ParseError.UnknownFlag, parseTokens(testing.allocator, &tok, cmd, null));
}
