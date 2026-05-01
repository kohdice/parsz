const std = @import("std");

const schema = @import("schema.zig");

pub fn renderUsage(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime args: anytype,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();

    writeUsage(&buffer.writer, command_name, args) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

pub fn writeUsage(
    writer: *std.Io.Writer,
    comptime command_name: []const u8,
    comptime args: anytype,
) std.Io.Writer.Error!void {
    try writeUsageLine(writer, command_name, args);
    try writer.writeAll("\n");
}

pub fn renderHelp(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime command_about: ?[]const u8,
    comptime args: anytype,
    comptime subcommands: anytype,
    comptime controls: schema.StandardControls,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();

    writeHelp(&buffer.writer, command_name, command_about, args, subcommands, controls) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

pub fn writeHelp(
    writer: *std.Io.Writer,
    comptime command_name: []const u8,
    comptime command_about: ?[]const u8,
    comptime args: anytype,
    comptime subcommands: anytype,
    comptime controls: schema.StandardControls,
) std.Io.Writer.Error!void {
    try writeUsageLine(writer, command_name, args);
    if (command_about) |about| {
        try writer.writeAll("\n\n");
        try writer.writeAll(about);
    }
    try writer.writeAll("\n\nOptions:\n");

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field_info| {
        const spec = @field(args, field_info.name);
        if (spec.kind != .operand) {
            try writeOptionLine(writer, field_info.name, spec);
        }
    }

    try writeStandardControlLines(writer, controls);

    if (comptime hasSubcommandHelp(subcommands)) {
        try writer.writeAll("\nCommands:\n");
        try writeSubcommandLines(writer, subcommands);
    }

    if (comptime hasOperandHelp(args)) {
        try writer.writeAll("\nOperands:\n");
        inline for (fields) |field_info| {
            const spec = @field(args, field_info.name);
            if (spec.kind == .operand) {
                try writeOperandLine(writer, field_info.name, spec);
            }
        }
    }
}

fn writeStandardControlLines(
    writer: *std.Io.Writer,
    comptime controls: schema.StandardControls,
) std.Io.Writer.Error!void {
    if (comptime controls.help) {
        try writer.writeAll("  --");
        try writer.writeAll(schema.standardControlLongName(.help));
        try writer.writeByte('\n');
    }
    if (comptime controls.version) {
        try writer.writeAll("  --");
        try writer.writeAll(schema.standardControlLongName(.version));
        try writer.writeByte('\n');
    }
}

fn hasSubcommandHelp(comptime subcommands: anytype) bool {
    return @typeInfo(@TypeOf(subcommands)).@"struct".fields.len > 0;
}

fn writeSubcommandLines(
    writer: *std.Io.Writer,
    comptime subcommands: anytype,
) std.Io.Writer.Error!void {
    const fields = @typeInfo(@TypeOf(subcommands)).@"struct".fields;

    inline for (fields) |field_info| {
        const Child = @field(subcommands, field_info.name);
        try writer.writeAll("  ");
        try writer.writeAll(Child.name);
        if (Child.about) |about| {
            try writer.writeAll("  ");
            try writer.writeAll(about);
        }
        try writer.writeByte('\n');
    }
}

pub fn renderVersion(
    allocator: std.mem.Allocator,
    comptime command_name: []const u8,
    comptime version: schema.VersionMetadata,
) std.mem.Allocator.Error![]const u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();

    writeVersion(&buffer.writer, command_name, version) catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

pub fn writeVersion(
    writer: *std.Io.Writer,
    comptime command_name: []const u8,
    comptime version: schema.VersionMetadata,
) std.Io.Writer.Error!void {
    try writer.writeAll(command_name);
    try writer.writeByte(' ');
    try writer.writeAll(version.number);
    try writer.writeByte('\n');
    try writer.writeAll(version.details);
    if (version.details[version.details.len - 1] != '\n') {
        try writer.writeByte('\n');
    }
}

fn writeUsageLine(
    writer: *std.Io.Writer,
    comptime command_name: []const u8,
    comptime args: anytype,
) std.Io.Writer.Error!void {
    try writer.writeAll("Usage: ");
    try writer.writeAll(command_name);

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields) |field_info| {
        try writeUsageArg(writer, field_info.name, @field(args, field_info.name));
    }
}

fn writeUsageArg(
    writer: *std.Io.Writer,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.Io.Writer.Error!void {
    try writer.writeAll(" ");

    if (!spec.required) {
        try writer.writeAll("[");
    }

    switch (spec.kind) {
        .flag => try writeOptionSpelling(writer, spec),
        .option => {
            try writeOptionSpelling(writer, spec);
            try writer.writeAll(" <");
            try writer.writeAll(valueName(field_name, spec));
            try writer.writeByte('>');
        },
        .operand => {
            if (spec.required) {
                try writer.writeByte('<');
                try writer.writeAll(valueName(field_name, spec));
                try writer.writeByte('>');
            } else {
                try writer.writeAll(valueName(field_name, spec));
            }
        },
    }

    if (!spec.required) {
        try writer.writeAll("]");
    }

    if (spec.action == .append) {
        try writer.writeAll("...");
    }
}

fn valueName(comptime field_name: []const u8, comptime spec: schema.ArgSpec) []const u8 {
    return spec.value_name orelse field_name;
}

fn writeOptionSpelling(
    writer: *std.Io.Writer,
    comptime spec: schema.ArgSpec,
) std.Io.Writer.Error!void {
    if (spec.short) |short| {
        try writer.writeByte('-');
        try writer.writeByte(short);
        if (spec.long) |long| {
            try writer.writeAll("|--");
            try writer.writeAll(long);
        }
        return;
    }

    if (spec.long) |long| {
        try writer.writeAll("--");
        try writer.writeAll(long);
        return;
    }

    unreachable;
}

fn writeOptionLine(
    writer: *std.Io.Writer,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.Io.Writer.Error!void {
    try writer.writeAll("  ");

    if (spec.short) |short| {
        try writer.writeByte('-');
        try writer.writeByte(short);
        if (spec.long) |long| {
            try writer.writeAll(", --");
            try writer.writeAll(long);
        }
    } else if (spec.long) |long| {
        try writer.writeAll("--");
        try writer.writeAll(long);
    } else {
        unreachable;
    }

    if (spec.kind == .option) {
        try writer.writeAll(" <");
        try writer.writeAll(valueName(field_name, spec));
        try writer.writeByte('>');
    }

    if (spec.help) |help_text| {
        try writer.writeAll("  ");
        try writer.writeAll(help_text);
    }

    try writer.writeByte('\n');
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

fn writeOperandLine(
    writer: *std.Io.Writer,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.Io.Writer.Error!void {
    try writer.writeAll("  ");
    try writeOperandSpelling(writer, field_name, spec);

    if (spec.help) |help_text| {
        try writer.writeAll("  ");
        try writer.writeAll(help_text);
    }

    try writer.writeByte('\n');
}

fn writeOperandSpelling(
    writer: *std.Io.Writer,
    comptime field_name: []const u8,
    comptime spec: schema.ArgSpec,
) std.Io.Writer.Error!void {
    const name = valueName(field_name, spec);

    if (spec.required) {
        try writer.writeByte('<');
        try writer.writeAll(name);
        try writer.writeByte('>');
    } else {
        try writer.writeByte('[');
        try writer.writeAll(name);
    }

    if (!spec.required) {
        try writer.writeAll("]");
    }

    if (spec.action == .append) {
        try writer.writeAll("...");
    }
}
