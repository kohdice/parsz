const std = @import("std");

pub const Error = error{
    InvalidValue,
    Overflow,
};

pub fn parse(comptime T: type, raw: []const u8) Error!T {
    if (T == []const u8) {
        return raw;
    }

    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, raw, 10) catch |err| switch (err) {
            error.InvalidCharacter => error.InvalidValue,
            error.Overflow => error.Overflow,
        },
        .@"enum" => std.meta.stringToEnum(T, raw) orelse error.InvalidValue,
        else => @compileError("unsupported parsed value type: " ++ @typeName(T)),
    };
}
