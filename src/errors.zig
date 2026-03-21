const std = @import("std");

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    MissingRequired,
    InvalidValue,
    ValueOutOfRange,
    TooManyPositionals,
    DuplicateArg,
    UnknownSubcommand,
    MissingSubcommand,
    HelpRequested,
    ConflictingArgs,
    MissingRequiredBy,
};

pub const FlagRef = union(enum) {
    none,
    long: []const u8,
    short: u8,
};

pub const Diagnostic = struct {
    arg_name: []const u8 = "",
    flag: FlagRef = .none,
    provided_value: []const u8 = "",
    expected: []const u8 = "",
    message: []const u8 = "",

    pub fn format(self: Diagnostic, writer: anytype) !void {
        var has_subject = false;

        switch (self.flag) {
            .long => |name| {
                try writer.print("argument '--{s}'", .{name});
                has_subject = true;
            },
            .short => |ch| {
                try writer.print("argument '-{c}'", .{ch});
                has_subject = true;
            },
            .none => {
                if (self.arg_name.len > 0) {
                    try writer.print("argument '{s}'", .{self.arg_name});
                    has_subject = true;
                }
            },
        }

        if (self.message.len > 0) {
            if (has_subject) try writer.writeAll(": ");
            try writer.writeAll(self.message);
            if (self.provided_value.len > 0) {
                try writer.print(" '{s}'", .{self.provided_value});
            }
            if (self.expected.len > 0) {
                try writer.print(" (expected {s})", .{self.expected});
            }
            return;
        }

        if (self.provided_value.len > 0) {
            if (has_subject) {
                try writer.print(": invalid value '{s}'", .{self.provided_value});
            } else {
                try writer.print("invalid value '{s}'", .{self.provided_value});
            }
        }
        if (self.expected.len > 0) {
            if (has_subject or self.provided_value.len > 0) {
                try writer.print(" (expected {s})", .{self.expected});
            } else {
                try writer.print("(expected {s})", .{self.expected});
            }
        }
    }
};

test "diagnostic: format with long flag" {
    const diag = Diagnostic{ .flag = .{ .long = "verbose" } };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--verbose'", result);
}

test "diagnostic: format with short flag" {
    const diag = Diagnostic{ .flag = .{ .short = 'x' } };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '-x'", result);
}

test "diagnostic: format with provided_value" {
    const diag = Diagnostic{ .flag = .{ .long = "count" }, .provided_value = "abc" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--count': invalid value 'abc'", result);
}

test "diagnostic: format empty" {
    const diag = Diagnostic{};
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("", result);
}

test "diagnostic: format with expected" {
    const diag = Diagnostic{ .flag = .{ .long = "port" }, .provided_value = "abc", .expected = "u16" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--port': invalid value 'abc' (expected u16)", result);
}

test "diagnostic: format expected without provided_value" {
    const diag = Diagnostic{ .flag = .{ .long = "port" }, .expected = "u16" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--port' (expected u16)", result);
}

test "diagnostic: format provided_value only" {
    const diag = Diagnostic{ .provided_value = "bogus" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("invalid value 'bogus'", result);
}

test "diagnostic: format value and expected without subject" {
    const diag = Diagnostic{ .provided_value = "abc", .expected = "u16" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("invalid value 'abc' (expected u16)", result);
}

test "diagnostic: format expected only without subject" {
    const diag = Diagnostic{ .expected = "one of: run, build" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("(expected one of: run, build)", result);
}

test "diagnostic: format message with subject" {
    const diag = Diagnostic{ .flag = .{ .long = "json" }, .message = "cannot be used with '--csv'" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--json': cannot be used with '--csv'", result);
}

test "diagnostic: format message without subject" {
    const diag = Diagnostic{ .message = "required unless '--stdin' is present" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("required unless '--stdin' is present", result);
}

test "diagnostic: message with provided_value" {
    const diag = Diagnostic{ .flag = .{ .long = "cmd" }, .provided_value = "foo", .message = "unknown subcommand" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--cmd': unknown subcommand 'foo'", result);
}

test "diagnostic: message with expected" {
    const diag = Diagnostic{ .flag = .{ .long = "output" }, .message = "missing value", .expected = "[]const u8" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--output': missing value (expected []const u8)", result);
}

test "diagnostic: message with provided_value and expected" {
    const diag = Diagnostic{ .flag = .{ .short = 'o' }, .provided_value = "bar", .message = "invalid option", .expected = "u16" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '-o': invalid option 'bar' (expected u16)", result);
}
