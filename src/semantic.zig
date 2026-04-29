const std = @import("std");

const diagnostics = @import("diagnostic.zig");
const parser = @import("parser.zig");
const value_parser = @import("value_parser.zig");

const Match = parser.Match;
const ParseError = diagnostics.ParseError;
const ParseOptions = diagnostics.ParseOptions;

pub fn applyMatches(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: []const Match,
    result: anytype,
    options: ParseOptions,
) ParseError!void {
    for (matches) |match| {
        try applyMatch(args, allocator, matches, match, result, options);
    }
}

fn applyMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: []const Match,
    match: Match,
    result: anytype,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (match.arg_index == arg_index) {
            switch (spec.action) {
                .set_true => {
                    if (match.raw_value != null) {
                        return diagnostics.failWithDiagnostic(options, .{
                            .kind = .unexpected_value,
                            .argv_index = match.argv_index,
                            .cluster_offset = match.cluster_offset,
                            .arg_name = field_info.name,
                            .raw_arg = match.raw_arg,
                            .value = match.raw_value,
                        });
                    }
                    @field(result.*, field_info.name) = true;
                },
                .count => {
                    if (match.raw_value != null) {
                        return diagnostics.failWithDiagnostic(options, .{
                            .kind = .unexpected_value,
                            .argv_index = match.argv_index,
                            .cluster_offset = match.cluster_offset,
                            .arg_name = field_info.name,
                            .raw_arg = match.raw_arg,
                            .value = match.raw_value,
                        });
                    }

                    @field(result.*, field_info.name) = std.math.add(
                        u32,
                        @field(result.*, field_info.name),
                        1,
                    ) catch return diagnostics.failWithDiagnostic(options, .{
                        .kind = .overflow,
                        .argv_index = match.argv_index,
                        .cluster_offset = match.cluster_offset,
                        .arg_name = field_info.name,
                        .raw_arg = match.raw_arg,
                    });
                },
                .set => {
                    const raw_value = match.raw_value orelse return diagnostics.failWithDiagnostic(options, .{
                        .kind = .missing_value,
                        .argv_index = match.argv_index,
                        .cluster_offset = match.cluster_offset,
                        .arg_name = field_info.name,
                        .raw_arg = match.raw_arg,
                    });

                    @field(result.*, field_info.name) = try parseValue(
                        spec.value_type,
                        raw_value,
                        match,
                        field_info.name,
                        options,
                    );
                },
                .append => {
                    if (match.arg_occurrence_index != 0) {
                        return;
                    }

                    const value_count = countMatchesForArg(matches, arg_index);
                    const values = allocator.alloc(spec.value_type, value_count) catch return error.OutOfMemory;
                    errdefer allocator.free(values);

                    for (matches) |append_match| {
                        if (append_match.arg_index == arg_index) {
                            const raw_value = append_match.raw_value orelse return diagnostics.failWithDiagnostic(options, .{
                                .kind = .missing_value,
                                .argv_index = append_match.argv_index,
                                .cluster_offset = append_match.cluster_offset,
                                .arg_name = field_info.name,
                                .raw_arg = append_match.raw_arg,
                            });

                            values[append_match.arg_occurrence_index] = try parseValue(
                                spec.value_type,
                                raw_value,
                                append_match,
                                field_info.name,
                                options,
                            );
                        }
                    }

                    @field(result.*, field_info.name) = values;
                },
            }
            return;
        }
    }

    unreachable;
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

pub fn validateRequiredMatches(comptime args: anytype, matches: []const Match, options: ParseOptions) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.required and !hasMatchForArg(matches, arg_index)) {
            return diagnostics.failWithDiagnostic(options, .{
                .kind = .missing_required,
                .arg_name = field_info.name,
            });
        }
    }
}

fn countMatchesForArg(matches: []const Match, arg_index: usize) usize {
    var count: usize = 0;
    for (matches) |match| {
        if (match.arg_index == arg_index) {
            count += 1;
        }
    }
    return count;
}

fn hasMatchForArg(matches: []const Match, arg_index: usize) bool {
    for (matches) |match| {
        if (match.arg_index == arg_index) {
            return true;
        }
    }

    return false;
}
