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
};

pub const Diagnostic = struct {
    arg_name: []const u8 = "",
    flag_name: []const u8 = "",
    provided_value: []const u8 = "",

    pub fn format(self: Diagnostic, writer: anytype) !void {
        if (self.flag_name.len > 0) {
            try writer.print("argument '{s}'", .{self.flag_name});
        } else if (self.arg_name.len > 0) {
            try writer.print("argument '{s}'", .{self.arg_name});
        }
        if (self.provided_value.len > 0) {
            try writer.print(": invalid value '{s}'", .{self.provided_value});
        }
    }
};

test "diagnostic: format with flag_name" {
    const diag = Diagnostic{ .flag_name = "--verbose" };
    var buf: [256]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try std.testing.expectEqualStrings("argument '--verbose'", result);
}

test "diagnostic: format with provided_value" {
    const diag = Diagnostic{ .flag_name = "--count", .provided_value = "abc" };
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
