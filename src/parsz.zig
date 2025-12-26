const std = @import("std");

const definitions = @import("definitions.zig");
const errors = @import("errors.zig");

// definitions
pub const Arg = definitions.Arg;
pub const ArgKind = definitions.ArgKind;
pub const Command = definitions.Command;
pub const ValueType = definitions.ValueType;

// errors
pub const ParseError = errors.ParseError;

/// Parse command-line arguments.
/// TODO: Implement tokenizer, parser, and validator pipeline.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    comptime cmd: Command,
) void {
    // Comptime validation - errors reported at compile time
    comptime definitions.validateCommand(cmd);

    // TODO: Implement actual parsing:
    // 1. Tokenize argv
    // 2. Parse tokens into RawResult
    // 3. Validate and convert to ParseResult
    _ = allocator;
    _ = argv;
}
