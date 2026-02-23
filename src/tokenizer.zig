const std = @import("std");

pub const Token = union(enum) {
    short: u8,
    long: Long,
    end_of_options,
    positional: [:0]const u8,

    pub const Long = struct {
        name: []const u8,
        value: ?[]const u8,
    };
};

pub const Tokenizer = struct {
    args: []const [:0]const u8,
    index: usize = 0,
    short_remaining: []const u8 = "",
    options_ended: bool = false,

    pub fn next(self: *Tokenizer) ?Token {
        if (self.short_remaining.len > 0) {
            const ch = self.short_remaining[0];
            self.short_remaining = self.short_remaining[1..];
            return .{ .short = ch };
        }

        if (self.index >= self.args.len) return null;

        const arg = self.args[self.index];
        self.index += 1;

        if (self.options_ended) {
            return .{ .positional = arg };
        }

        const slice: []const u8 = arg;

        if (std.mem.eql(u8, slice, "--")) {
            self.options_ended = true;
            return .end_of_options;
        }

        if (slice.len > 2 and slice[0] == '-' and slice[1] == '-') {
            if (std.mem.indexOfScalar(u8, slice[2..], '=')) |eq_pos| {
                return .{ .long = .{
                    .name = slice[2 .. 2 + eq_pos],
                    .value = slice[2 + eq_pos + 1 ..],
                } };
            }
            return .{ .long = .{
                .name = slice[2..],
                .value = null,
            } };
        }

        if (slice.len > 1 and slice[0] == '-') {
            const ch = slice[1];
            if (slice.len > 2) {
                self.short_remaining = slice[2..];
            }
            return .{ .short = ch };
        }

        return .{ .positional = arg };
    }

    pub fn nextRaw(self: *Tokenizer) ?[:0]const u8 {
        self.short_remaining = "";
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }
};

test "tokenizer: long option" {
    var tok = Tokenizer{ .args = &.{"--verbose"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("verbose", t.long.name);
    try std.testing.expect(t.long.value == null);
    try std.testing.expect(tok.next() == null);
}

test "tokenizer: long option with inline value" {
    var tok = Tokenizer{ .args = &.{"--output=file.txt"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("output", t.long.name);
    try std.testing.expectEqualStrings("file.txt", t.long.value.?);
}

test "tokenizer: short option" {
    var tok = Tokenizer{ .args = &.{"-v"} };
    const t = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'v'), t.short);
    try std.testing.expect(tok.next() == null);
}

test "tokenizer: short clustering" {
    var tok = Tokenizer{ .args = &.{"-abc"} };

    const t1 = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'a'), t1.short);

    const t2 = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'b'), t2.short);

    const t3 = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'c'), t3.short);

    try std.testing.expect(tok.next() == null);
}

test "tokenizer: end of options separator" {
    var tok = Tokenizer{ .args = &.{ "--", "--not-a-flag" } };

    const t1 = tok.next().?;
    try std.testing.expect(t1 == .end_of_options);

    const t2 = tok.next().?;
    try std.testing.expectEqualStrings("--not-a-flag", t2.positional);
}

test "tokenizer: positional argument" {
    var tok = Tokenizer{ .args = &.{"file.txt"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("file.txt", t.positional);
}

test "tokenizer: dash as positional" {
    var tok = Tokenizer{ .args = &.{"-"} };
    const t = tok.next().?;
    try std.testing.expectEqualStrings("-", t.positional);
}

test "tokenizer: mixed sequence" {
    var tok = Tokenizer{ .args = &.{ "-v", "--output", "file.txt", "pos" } };

    const t1 = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'v'), t1.short);

    const t2 = tok.next().?;
    try std.testing.expectEqualStrings("output", t2.long.name);

    const t3 = tok.next().?;
    try std.testing.expectEqualStrings("file.txt", t3.positional);

    const t4 = tok.next().?;
    try std.testing.expectEqualStrings("pos", t4.positional);

    try std.testing.expect(tok.next() == null);
}

test "tokenizer: nextRaw consumes raw argument" {
    var tok = Tokenizer{ .args = &.{ "-abc", "value" } };

    const t1 = tok.next().?;
    try std.testing.expectEqual(@as(u8, 'a'), t1.short);

    const raw = tok.nextRaw().?;
    try std.testing.expectEqualStrings("value", raw);

    try std.testing.expect(tok.next() == null);
}

test "tokenizer: nextRaw clears short_remaining" {
    var tok = Tokenizer{ .args = &.{ "-abc", "value" } };

    _ = tok.next();

    const raw = tok.nextRaw().?;
    try std.testing.expectEqualStrings("value", raw);

    try std.testing.expect(tok.next() == null);
}

test "tokenizer: empty args" {
    var tok = Tokenizer{ .args = &.{} };
    try std.testing.expect(tok.next() == null);
}
