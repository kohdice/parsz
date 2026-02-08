//! Lexical analysis stage: classifies each argv element by its lexical form.
//!
//! The Tokenizer does NOT know about Command definitions.
//! It purely classifies based on prefix patterns (-, --, etc.).

const std = @import("std");

pub const Token = union(enum) {
    /// "-abc" → "abc" (leading '-' stripped).
    /// The Parser will split this cluster one character at a time
    /// using the Command definition.
    short: []const u8,

    /// "--verbose" → { .name = "verbose", .value = null }
    /// "--output=file" → { .name = "output", .value = "file" }
    long: struct {
        name: []const u8,
        value: ?[]const u8,
    },

    /// The "--" token itself. Signals that all subsequent argv
    /// elements are positional arguments.
    end_of_options,

    /// A bare string, "-" alone, or any element after "--".
    positional: []const u8,
};

/// Lexical tokenizer that iterates over argv elements and classifies them.
///
/// Zero allocation: all slices are references into the original argv memory.
/// The Tokenizer struct itself is a small stack-allocated value.
pub const Tokenizer = struct {
    args: []const [:0]const u8,
    index: usize = 0,
    options_ended: bool = false,

    /// Returns the next token, or null if all argv elements have been consumed.
    ///
    /// Classification priority (evaluated in order):
    /// 1. options_ended == true → .positional
    /// 2. "--" exact match → .end_of_options (sets options_ended = true)
    /// 3. "-" exact match → .positional (POSIX G13: stdin/stdout convention)
    /// 4. "--" prefix (3+ chars) → .long (split on '=' if present),
    ///    except "--=" or "--=..." (first char after "--" is '=') → .positional
    /// 5. "-" prefix (2+ chars) → .short
    /// 6. Otherwise → .positional
    pub fn next(self: *Tokenizer) ?Token {
        if (self.index >= self.args.len) return null;

        const arg: []const u8 = self.args[self.index];
        self.index += 1;

        // Priority 1: After "--", everything is positional
        if (self.options_ended) {
            return .{ .positional = arg };
        }

        // Priority 2: "--" exact match → end of options
        if (std.mem.eql(u8, arg, "--")) {
            self.options_ended = true;
            return .end_of_options;
        }

        // Priority 3: "-" exact match → positional (POSIX G13)
        if (std.mem.eql(u8, arg, "-")) {
            return .{ .positional = arg };
        }

        // Priority 4: "--" prefix (long option)
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            const rest = arg[2..];
            // "--=" or "--=value" is not a valid long option
            if (rest[0] == '=') {
                return .{ .positional = arg };
            }
            if (std.mem.indexOfScalar(u8, rest, '=')) |eq_pos| {
                return .{ .long = .{
                    .name = rest[0..eq_pos],
                    .value = rest[eq_pos + 1 ..],
                } };
            }
            return .{ .long = .{
                .name = rest,
                .value = null,
            } };
        }

        // Priority 5: "-" prefix (short option cluster)
        if (arg.len >= 2 and arg[0] == '-') {
            return .{ .short = arg[1..] };
        }

        // Priority 6: bare string → positional
        return .{ .positional = arg };
    }

    /// Consume the next argv element as a raw string without token classification.
    ///
    /// Used by the Parser to obtain option-arguments.
    /// Since option-arguments are mandatory for their respective options (POSIX G7),
    /// the next element is consumed as-is regardless of its form (even "-..." prefixed).
    ///
    /// Returns null if no more argv elements remain.
    pub fn nextRaw(self: *Tokenizer) ?[:0]const u8 {
        if (self.index >= self.args.len) return null;

        const raw = self.args[self.index];
        self.index += 1;
        return raw;
    }
};

test "positional: bare strings" {
    var tok = Tokenizer{ .args = &.{ "hello", "world" } };
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("hello", t.positional);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("world", t.positional);
    }
    try std.testing.expectEqual(null, tok.next());
}

test "positional: '-' alone is positional (POSIX G13)" {
    var tok = Tokenizer{ .args = &.{"-"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("-", t.positional);
}

test "short: single character" {
    var tok = Tokenizer{ .args = &.{"-v"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("v", t.short);
}

test "short: cluster" {
    var tok = Tokenizer{ .args = &.{"-abc"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("abc", t.short);
}

test "long: without value" {
    var tok = Tokenizer{ .args = &.{"--verbose"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("verbose", t.long.name);
    try std.testing.expectEqual(null, t.long.value);
}

test "long: with inline value" {
    var tok = Tokenizer{ .args = &.{"--output=file.txt"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("output", t.long.name);
    try std.testing.expectEqualStrings("file.txt", t.long.value.?);
}

test "long: with empty inline value" {
    var tok = Tokenizer{ .args = &.{"--output="} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("output", t.long.name);
    try std.testing.expectEqualStrings("", t.long.value.?);
}

test "end_of_options: '--' makes subsequent args positional" {
    var tok = Tokenizer{ .args = &.{ "--", "-v", "--output" } };
    {
        const t = tok.next().?;
        try std.testing.expect(t == .end_of_options);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("-v", t.positional);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("--output", t.positional);
    }
    try std.testing.expectEqual(null, tok.next());
}

test "mixed sequence" {
    var tok = Tokenizer{ .args = &.{ "-v", "--output=file", "input.txt", "--", "-x" } };
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("v", t.short);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("output", t.long.name);
        try std.testing.expectEqualStrings("file", t.long.value.?);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("input.txt", t.positional);
    }
    {
        const t = tok.next().?;
        try std.testing.expect(t == .end_of_options);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("-x", t.positional);
    }
    try std.testing.expectEqual(null, tok.next());
}

test "nextRaw: consumes raw argv element" {
    var tok = Tokenizer{ .args = &.{ "-o", "--file" } };
    _ = tok.next(); // consume "-o" as short
    const raw = tok.nextRaw().?;
    try std.testing.expectEqualStrings("--file", raw);
    try std.testing.expectEqual(null, tok.next());
}

test "nextRaw: returns null when no more elements" {
    var tok = Tokenizer{ .args = &.{} };
    try std.testing.expectEqual(null, tok.nextRaw());
}

test "empty argv" {
    var tok = Tokenizer{ .args = &.{} };
    try std.testing.expectEqual(null, tok.next());
}

test "long: '--=value' treated as positional" {
    var tok = Tokenizer{ .args = &.{"--=value"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("--=value", t.positional);
}

test "long: '--=' treated as positional" {
    var tok = Tokenizer{ .args = &.{"--="} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("--=", t.positional);
}

test "second '--' after end_of_options is treated as positional" {
    var tok = Tokenizer{ .args = &.{ "--", "--" } };
    {
        const t = tok.next().?;
        try std.testing.expect(t == .end_of_options);
    }
    {
        const t = tok.next().?;
        try std.testing.expectEqualStrings("--", t.positional);
    }
    try std.testing.expectEqual(null, tok.next());
}
