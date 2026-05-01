const std = @import("std");

const diagnostics = @import("diagnostic.zig");
const parser = @import("parser.zig");
const schema = @import("schema.zig");
const value_parser = @import("value_parser.zig");

const Match = parser.Match;
const ParseError = diagnostics.ParseError;
const ParseOptions = diagnostics.ParseOptions;

pub fn applyNonAppendMatch(
    comptime arg_name: []const u8,
    comptime spec: schema.ArgSpec,
    match: Match,
    result: anytype,
    options: ParseOptions,
) ParseError!void {
    switch (spec.action) {
        .set_true => {
            if (match.raw_value != null) {
                return diagnostics.failWithDiagnostic(options, .{
                    .kind = .unexpected_value,
                    .argv_index = match.argv_index,
                    .cluster_offset = match.cluster_offset,
                    .arg_name = arg_name,
                    .raw_arg = match.raw_arg,
                    .value = match.raw_value,
                });
            }
            @field(result.*, arg_name) = true;
        },
        .count => {
            if (match.raw_value != null) {
                return diagnostics.failWithDiagnostic(options, .{
                    .kind = .unexpected_value,
                    .argv_index = match.argv_index,
                    .cluster_offset = match.cluster_offset,
                    .arg_name = arg_name,
                    .raw_arg = match.raw_arg,
                    .value = match.raw_value,
                });
            }

            @field(result.*, arg_name) = std.math.add(
                u32,
                @field(result.*, arg_name),
                1,
            ) catch return diagnostics.failWithDiagnostic(options, .{
                .kind = .overflow,
                .argv_index = match.argv_index,
                .cluster_offset = match.cluster_offset,
                .arg_name = arg_name,
                .raw_arg = match.raw_arg,
            });
        },
        .set => {
            const raw_value = match.raw_value orelse return diagnostics.failWithDiagnostic(options, .{
                .kind = .missing_value,
                .argv_index = match.argv_index,
                .cluster_offset = match.cluster_offset,
                .arg_name = arg_name,
                .raw_arg = match.raw_arg,
            });

            @field(result.*, arg_name) = try parseValue(
                spec.value_type,
                raw_value,
                match,
                arg_name,
                options,
            );
        },
        .append => @compileError("applyNonAppendMatch requires a non-append argument"),
    }
}

pub fn applyAppendMatch(
    comptime arg_name: []const u8,
    comptime spec: schema.ArgSpec,
    match: Match,
    values: []spec.value_type,
    index: usize,
    options: ParseOptions,
) ParseError!void {
    if (comptime spec.action != .append) {
        @compileError("applyAppendMatch requires an append argument");
    }

    const raw_value = match.raw_value orelse return diagnostics.failWithDiagnostic(options, .{
        .kind = .missing_value,
        .argv_index = match.argv_index,
        .cluster_offset = match.cluster_offset,
        .arg_name = arg_name,
        .raw_arg = match.raw_arg,
    });

    const value = try parseValue(
        spec.value_type,
        raw_value,
        match,
        arg_name,
        options,
    );
    values[index] = value;
}

fn parseValue(
    comptime T: type,
    raw: []const u8,
    match: Match,
    comptime arg_name: []const u8,
    options: ParseOptions,
) ParseError!T {
    return value_parser.parse(T, raw) catch |err| switch (err) {
        error.InvalidValue => return diagnostics.failWithDiagnostic(options, .{
            .kind = .invalid_value,
            .argv_index = valueArgvIndex(match),
            .cluster_offset = valueClusterOffset(match),
            .arg_name = arg_name,
            .raw_arg = valueRawArg(match),
            .value = raw,
        }),
        error.Overflow => return diagnostics.failWithDiagnostic(options, .{
            .kind = .overflow,
            .argv_index = valueArgvIndex(match),
            .cluster_offset = valueClusterOffset(match),
            .arg_name = arg_name,
            .raw_arg = valueRawArg(match),
            .value = raw,
        }),
    };
}

fn valueArgvIndex(match: Match) usize {
    return match.value_argv_index orelse match.argv_index;
}

fn valueRawArg(match: Match) []const u8 {
    return match.value_raw_arg orelse match.raw_arg;
}

fn valueClusterOffset(match: Match) ?usize {
    if (match.value_argv_index != null or match.value_raw_arg != null) {
        return match.value_cluster_offset;
    }

    return match.cluster_offset;
}

pub fn validateRequiredSeen(comptime args: anytype, seen: []const bool, options: ParseOptions) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.required and !seen[arg_index]) {
            return diagnostics.failWithDiagnostic(options, .{
                .kind = .missing_required,
                .arg_name = field_info.name,
            });
        }
    }
}
