const std = @import("std");
const parse_error = @import("error.zig");
const parsed = @import("parsed.zig");
const schema = @import("schema.zig");

pub fn parse(
    comptime SchemaType: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) parse_error.ParseError!parsed.Parsed(SchemaType) {
    _ = allocator;
    _ = argv;

    schema.validateSchema(SchemaType);

    return parse_error.NotImplemented;
}
