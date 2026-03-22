const std = @import("std");
const parsed = @import("parsed.zig");

pub fn deinit(
    comptime SchemaType: type,
    allocator: std.mem.Allocator,
    value: *parsed.Parsed(SchemaType),
) void {
    _ = allocator;
    _ = value;
}
