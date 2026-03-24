const std = @import("std");
const parse_error = @import("error.zig");

pub fn convertScalar(comptime TargetType: type, token: []const u8) parse_error.ParseError!TargetType {
    return switch (@typeInfo(TargetType)) {
        .optional => |optional_info| try convertScalar(optional_info.child, token),
        .bool => parseBool(token),
        .int => std.fmt.parseInt(TargetType, token, 10) catch error.InvalidValue,
        .float => std.fmt.parseFloat(TargetType, token) catch error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(TargetType, token) orelse error.InvalidValue,
        .pointer => convertBorrowedString(TargetType, token),
        .comptime_int => @compileError("parsz runtime parsing does not support comptime_int payloads"),
        .comptime_float => @compileError("parsz runtime parsing does not support comptime_float payloads"),
        else => @compileError(std.fmt.comptimePrint(
            "parsz runtime parsing does not support payload type {s}",
            .{@typeName(TargetType)},
        )),
    };
}

fn parseBool(token: []const u8) parse_error.ParseError!bool {
    if (std.mem.eql(u8, token, "true")) {
        return true;
    }

    if (std.mem.eql(u8, token, "false")) {
        return false;
    }

    return error.InvalidValue;
}

fn convertBorrowedString(comptime TargetType: type, token: []const u8) parse_error.ParseError!TargetType {
    const pointer_info = @typeInfo(TargetType).pointer;

    if (!pointer_info.is_const or pointer_info.child != u8) {
        @compileError(std.fmt.comptimePrint(
            "parsz runtime parsing does not support pointer payload type {s}",
            .{@typeName(TargetType)},
        ));
    }

    return switch (pointer_info.size) {
        .slice => if (pointer_info.sentinel_ptr == null) token else blk: {
            const sentinel_ptr: [*:0]const u8 = @ptrCast(token.ptr);
            break :blk sentinel_ptr[0..token.len :0];
        },
        else => @compileError(std.fmt.comptimePrint(
            "parsz runtime parsing does not support pointer payload type {s}",
            .{@typeName(TargetType)},
        )),
    };
}

test "convertScalar parses supported scalar values" {
    const Mode = enum {
        fast,
        slow,
    };

    try std.testing.expectEqual(@as(i32, -42), try convertScalar(i32, "-42"));
    try std.testing.expectEqual(@as(u16, 42), try convertScalar(u16, "42"));
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), try convertScalar(f64, "3.5"), 0.000_001);
    try std.testing.expectEqual(Mode.fast, try convertScalar(Mode, "fast"));
    try std.testing.expectEqual(true, try convertScalar(bool, "true"));
    try std.testing.expectEqual(false, try convertScalar(bool, "false"));

    const text = try convertScalar([]const u8, "value");
    try std.testing.expectEqualStrings("value", text);
    try std.testing.expect(text.ptr == "value".ptr);
}

test "convertScalar returns InvalidValue for malformed tokens" {
    const Mode = enum {
        fast,
        slow,
    };

    try std.testing.expectError(error.InvalidValue, convertScalar(i32, "abc"));
    try std.testing.expectError(error.InvalidValue, convertScalar(f32, "abc"));
    try std.testing.expectError(error.InvalidValue, convertScalar(Mode, "medium"));
    try std.testing.expectError(error.InvalidValue, convertScalar(bool, "TRUE"));
}
