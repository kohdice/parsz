const std = @import("std");

const schema = @import("schema.zig");

pub fn renderUsage(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime args: anytype,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try appendUsageLine(&buffer, allocator, command_name, args);
    try buffer.append(allocator, '\n');
    return buffer.toOwnedSlice(allocator);
}

pub fn renderHelp(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime command_about: ?[]const u8,
    comptime args: anytype,
    comptime controls: schema.StandardControls,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try appendUsageLine(&buffer, allocator, command_name, args);
    if (command_about) |about| {
        try buffer.print(allocator, "\n\n{s}", .{about});
    }
    try buffer.appendSlice(allocator, "\n\nOptions:\n");

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.kind != .operand) {
            try appendOptionLine(&buffer, allocator, field_info.name, spec);
        }
    }

    try appendStandardControlLines(&buffer, allocator, controls);

    if (comptime hasOperandHelp(args)) {
        try buffer.appendSlice(allocator, "\nOperands:\n");
        inline for (fields) |field_info| {
            const spec = @field(args, field_info.name);
            if (spec.kind == .operand) {
                try appendOperandLine(&buffer, allocator, field_info.name, spec);
            }
        }
    }

    return buffer.toOwnedSlice(allocator);
}

fn appendStandardControlLines(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime controls: schema.StandardControls,
) std.mem.Allocator.Error!void {
    if (comptime controls.help) {
        try buffer.print(allocator, "  --{s}\n", .{schema.standardControlLongName(.help)});
    }
    if (comptime controls.version) {
        try buffer.print(allocator, "  --{s}\n", .{schema.standardControlLongName(.version)});
    }
}

pub fn renderVersion(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime version: schema.VersionMetadata,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.print(allocator, "{s} {s}\n{s}", .{ command_name, version.number, version.details });
    if (version.details[version.details.len - 1] != '\n') {
        try buffer.append(allocator, '\n');
    }
    return buffer.toOwnedSlice(allocator);
}

fn appendUsageLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime args: anytype,
) std.mem.Allocator.Error!void {
    try buffer.print(allocator, "Usage: {s}", .{command_name});

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field_info| {
        try appendUsageArg(buffer, allocator, field_info.name, @field(args, field_info.name));
    }
}

fn appendUsageArg(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.mem.Allocator.Error!void {
    try buffer.append(allocator, ' ');

    if (!spec.required) {
        try buffer.append(allocator, '[');
    }

    switch (spec.kind) {
        .flag => try appendOptionSpelling(buffer, allocator, spec),
        .option => {
            try appendOptionSpelling(buffer, allocator, spec);
            try buffer.print(allocator, " <{s}>", .{valueName(field_name, spec)});
        },
        .operand => {
            if (spec.required) {
                try buffer.print(allocator, "<{s}>", .{valueName(field_name, spec)});
            } else {
                try buffer.appendSlice(allocator, valueName(field_name, spec));
            }
        },
    }

    if (!spec.required) {
        try buffer.append(allocator, ']');
    }

    if (spec.action == .append) {
        try buffer.appendSlice(allocator, "...");
    }
}

fn valueName(comptime field_name: []const u8, comptime spec: schema.ArgSpec) []const u8 {
    return spec.value_name orelse field_name;
}

fn appendOptionSpelling(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime spec: schema.ArgSpec,
) std.mem.Allocator.Error!void {
    if (spec.short) |short| {
        try buffer.print(allocator, "-{c}", .{short});
        if (spec.long) |long| {
            try buffer.print(allocator, "|--{s}", .{long});
        }
        return;
    }

    if (spec.long) |long| {
        try buffer.print(allocator, "--{s}", .{long});
        return;
    }

    unreachable;
}

fn appendOptionLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.mem.Allocator.Error!void {
    try buffer.appendSlice(allocator, "  ");

    if (spec.short) |short| {
        try buffer.print(allocator, "-{c}", .{short});
        if (spec.long) |long| {
            try buffer.print(allocator, ", --{s}", .{long});
        }
    } else if (spec.long) |long| {
        try buffer.print(allocator, "--{s}", .{long});
    } else {
        unreachable;
    }

    if (spec.kind == .option) {
        try buffer.print(allocator, " <{s}>", .{valueName(field_name, spec)});
    }

    if (spec.help) |help_text| {
        try buffer.print(allocator, "  {s}", .{help_text});
    }

    try buffer.append(allocator, '\n');
}

fn hasOperandHelp(comptime args: anytype) bool {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.kind == .operand and spec.help != null) {
            return true;
        }
    }

    return false;
}

fn appendOperandLine(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.mem.Allocator.Error!void {
    try buffer.appendSlice(allocator, "  ");
    try appendOperandSpelling(buffer, allocator, field_name, spec);

    if (spec.help) |help_text| {
        try buffer.print(allocator, "  {s}", .{help_text});
    }

    try buffer.append(allocator, '\n');
}

fn appendOperandSpelling(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.mem.Allocator.Error!void {
    const name = valueName(field_name, spec);

    if (spec.required) {
        try buffer.print(allocator, "<{s}>", .{name});
    } else {
        try buffer.print(allocator, "[{s}", .{name});
    }

    if (!spec.required) {
        try buffer.append(allocator, ']');
    }

    if (spec.action == .append) {
        try buffer.appendSlice(allocator, "...");
    }
}
