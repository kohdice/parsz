const std = @import("std");

const diagnostics = @import("diagnostic.zig");
const schema = @import("schema.zig");
const tokenizer = @import("tokenizer.zig");

const ArgSpec = schema.ArgSpec;
const Token = tokenizer.Token;
const tokenize = tokenizer.tokenize;
const ParseError = diagnostics.ParseError;
const ParseOptions = diagnostics.ParseOptions;

pub const MatchParseResult = union(enum) {
    matches: []Match,
    control: schema.StandardControl,
    subcommand: SubcommandInvocation,
};

pub const SubcommandInvocation = struct {
    matches: []Match,
    subcommand_index: usize,
    argv_index: usize,
};

pub const Match = struct {
    arg_index: usize,
    raw_value: ?[]const u8,
    argv_index: usize,
    raw_arg: []const u8,
    cluster_offset: ?usize = null,
    value_argv_index: ?usize = null,
    value_raw_arg: ?[]const u8 = null,
    value_cluster_offset: ?usize = null,
    arg_occurrence_index: usize = 0,
};

const ValueLocation = struct {
    raw_value: []const u8,
    argv_index: usize,
    raw_arg: []const u8,
    cluster_offset: ?usize = null,
};

pub fn parseMatches(
    comptime args: anytype,
    comptime long_options: []const schema.LongOption,
    comptime subcommands: anytype,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: ParseOptions,
) ParseError!MatchParseResult {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const has_subcommands = @typeInfo(@TypeOf(subcommands)).@"struct".fields.len > 0;
    const tokens = tokenize(allocator, argv) catch return error.OutOfMemory;
    defer allocator.free(tokens);

    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);

    const occurrence_counts = allocator.alloc(usize, fields.len) catch return error.OutOfMemory;
    defer allocator.free(occurrence_counts);
    @memset(occurrence_counts, 0);

    var next_operand_ordinal: usize = 0;
    var token_index: usize = 0;

    while (token_index < tokens.len) {
        switch (tokens[token_index]) {
            .long_option => |payload| {
                if (try appendLongOptionMatch(args, long_options, allocator, &matches, occurrence_counts, payload, argv, &token_index, options)) |control| {
                    matches.deinit(allocator);
                    return .{ .control = control };
                }
            },
            .short_option => |payload| {
                try appendShortOptionMatch(args, allocator, &matches, occurrence_counts, payload, argv, &token_index, options);
            },
            .end_of_options => {
                token_index += 1;
                while (token_index < tokens.len) : (token_index += 1) {
                    const source_argv_index, const source_raw = switch (tokens[token_index]) {
                        .long_option => |payload| .{ payload.argv_index, payload.raw },
                        .short_option => |payload| .{ payload.argv_index, payload.raw },
                        .end_of_options => |payload| .{ payload.argv_index, payload.raw },
                        .operand => |payload| .{ payload.argv_index, payload.raw },
                    };
                    try appendOperandMatch(
                        args,
                        allocator,
                        &matches,
                        occurrence_counts,
                        source_argv_index,
                        source_raw,
                        &next_operand_ordinal,
                        options,
                    );
                }
                break;
            },
            .operand => |payload| {
                if (comptime has_subcommands) {
                    if (findSubcommandIndex(subcommands, payload.raw)) |subcommand_index| {
                        return .{ .subcommand = .{
                            .matches = matches.toOwnedSlice(allocator) catch return error.OutOfMemory,
                            .subcommand_index = subcommand_index,
                            .argv_index = payload.argv_index,
                        } };
                    }

                    return diagnostics.failWithDiagnostic(options, .{
                        .kind = .unknown_subcommand,
                        .argv_index = payload.argv_index,
                        .raw_arg = payload.raw,
                        .value = payload.raw,
                    });
                }

                try appendOperandMatch(
                    args,
                    allocator,
                    &matches,
                    occurrence_counts,
                    payload.argv_index,
                    payload.raw,
                    &next_operand_ordinal,
                    options,
                );
            },
        }

        token_index += 1;
    }

    return .{ .matches = matches.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

fn findSubcommandIndex(comptime subcommands: anytype, name: []const u8) ?usize {
    const fields = @typeInfo(@TypeOf(subcommands)).@"struct".fields;

    inline for (fields, 0..) |field_info, subcommand_index| {
        const Child = @field(subcommands, field_info.name);
        if (std.mem.eql(u8, name, Child.name)) {
            return subcommand_index;
        }
    }

    return null;
}

fn appendLongOptionMatch(
    comptime args: anytype,
    comptime long_options: []const schema.LongOption,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!?schema.StandardControl {
    if (schema.resolveExactLongOption(long_options, payload.name)) |resolution| {
        return try appendResolvedLongOptionResolution(
            args,
            allocator,
            matches,
            occurrence_counts,
            payload,
            argv,
            token_index,
            options,
            resolution,
        );
    }

    if (options.abbreviate_long_options and payload.name.len > 0) {
        switch (schema.resolveAbbreviatedLongOption(long_options, payload.name)) {
            .none => {},
            .one => |resolution| {
                return try appendResolvedLongOptionResolution(
                    args,
                    allocator,
                    matches,
                    occurrence_counts,
                    payload,
                    argv,
                    token_index,
                    options,
                    resolution,
                );
            },
            .ambiguous => {
                return diagnostics.failWithDiagnostic(options, .{
                    .kind = .ambiguous_abbreviation,
                    .argv_index = payload.argv_index,
                    .raw_arg = payload.raw,
                    .value = payload.name,
                });
            },
        }
    }

    return diagnostics.failWithDiagnostic(options, .{
        .kind = .unknown_option,
        .argv_index = payload.argv_index,
        .raw_arg = payload.raw,
        .value = payload.name,
    });
}

fn appendResolvedLongOptionResolution(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
    resolution: schema.LongOptionResolution,
) ParseError!?schema.StandardControl {
    switch (resolution) {
        .control => |control| return try validateStandardControlPayload(payload, control, options),
        .arg => |resolved_arg_index| {
            const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

            inline for (fields, 0..) |field_info, arg_index| {
                if (arg_index == resolved_arg_index) {
                    try appendResolvedLongOptionMatch(
                        arg_index,
                        field_info.name,
                        @field(args, field_info.name),
                        allocator,
                        matches,
                        occurrence_counts,
                        payload,
                        argv,
                        token_index,
                        options,
                    );
                    return null;
                }
            }

            unreachable;
        },
    }
}

fn validateStandardControlPayload(
    payload: @FieldType(Token, "long_option"),
    control: schema.StandardControl,
    options: ParseOptions,
) ParseError!schema.StandardControl {
    if (payload.inline_value != null) {
        return diagnostics.failWithDiagnostic(options, .{
            .kind = .unexpected_value,
            .argv_index = payload.argv_index,
            .arg_name = schema.standardControlLongName(control),
            .raw_arg = payload.raw,
            .value = payload.inline_value,
        });
    }

    return control;
}

fn appendResolvedLongOptionMatch(
    comptime arg_index: usize,
    comptime arg_name: []const u8,
    comptime spec: ArgSpec,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    switch (spec.kind) {
        .flag => {
            if (payload.inline_value != null) {
                return diagnostics.failWithDiagnostic(options, .{
                    .kind = .unexpected_value,
                    .argv_index = payload.argv_index,
                    .arg_name = arg_name,
                    .raw_arg = payload.raw,
                    .value = payload.inline_value,
                });
            }

            try appendMatch(allocator, matches, occurrence_counts, .{
                .arg_index = arg_index,
                .raw_value = null,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
            });
        },
        .option => {
            const value_location: ValueLocation = if (payload.inline_value) |inline_value| .{
                .raw_value = inline_value,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .cluster_offset = null,
            } else value: {
                const value_index = token_index.* + 1;
                if (value_index >= argv.len) {
                    return diagnostics.failWithDiagnostic(options, .{
                        .kind = .missing_value,
                        .argv_index = payload.argv_index,
                        .arg_name = arg_name,
                        .raw_arg = payload.raw,
                    });
                }
                token_index.* = value_index;
                break :value .{
                    .raw_value = argv[value_index],
                    .argv_index = value_index,
                    .raw_arg = argv[value_index],
                    .cluster_offset = null,
                };
            };

            try appendMatch(allocator, matches, occurrence_counts, .{
                .arg_index = arg_index,
                .raw_value = value_location.raw_value,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .value_argv_index = value_location.argv_index,
                .value_raw_arg = value_location.raw_arg,
                .value_cluster_offset = value_location.cluster_offset,
            });
        },
        .operand => unreachable,
    }
}

fn appendShortOptionMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    payload: @FieldType(Token, "short_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var cluster_offset: usize = 1;

    while (cluster_offset < payload.raw.len) {
        const ch = payload.raw[cluster_offset];
        const rest = payload.raw[cluster_offset + 1 ..];
        var found = false;

        inline for (fields, 0..) |field_info, arg_index| {
            const spec = @field(args, field_info.name);
            if (!found and spec.kind != .operand) {
                if (spec.short) |short| {
                    if (ch == short) {
                        found = true;
                        const current_offset = cluster_offset;

                        switch (spec.kind) {
                            .flag => {
                                try appendMatch(allocator, matches, occurrence_counts, .{
                                    .arg_index = arg_index,
                                    .raw_value = null,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                });
                                cluster_offset += 1;
                            },
                            .option => {
                                const value_location: ValueLocation = if (rest.len > 0) .{
                                    .raw_value = rest,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                } else value: {
                                    const value_index = token_index.* + 1;
                                    if (value_index >= argv.len) {
                                        return diagnostics.failWithDiagnostic(options, .{
                                            .kind = .missing_value,
                                            .argv_index = payload.argv_index,
                                            .cluster_offset = current_offset,
                                            .arg_name = field_info.name,
                                            .raw_arg = payload.raw,
                                        });
                                    }

                                    token_index.* = value_index;
                                    break :value .{
                                        .raw_value = argv[value_index],
                                        .argv_index = value_index,
                                        .raw_arg = argv[value_index],
                                        .cluster_offset = null,
                                    };
                                };

                                try appendMatch(allocator, matches, occurrence_counts, .{
                                    .arg_index = arg_index,
                                    .raw_value = value_location.raw_value,
                                    .argv_index = payload.argv_index,
                                    .raw_arg = payload.raw,
                                    .cluster_offset = current_offset,
                                    .value_argv_index = value_location.argv_index,
                                    .value_raw_arg = value_location.raw_arg,
                                    .value_cluster_offset = value_location.cluster_offset,
                                });
                                return;
                            },
                            .operand => unreachable,
                        }
                    }
                }
            }
        }

        if (!found) {
            return diagnostics.failWithDiagnostic(options, .{
                .kind = .unknown_option,
                .argv_index = payload.argv_index,
                .cluster_offset = cluster_offset,
                .raw_arg = payload.raw,
            });
        }
    }
}

fn appendOperandMatch(
    comptime args: anytype,
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    argv_index: usize,
    raw: []const u8,
    next_operand_ordinal: *usize,
    options: ParseOptions,
) ParseError!void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var operand_ordinal: usize = 0;

    inline for (fields, 0..) |field_info, arg_index| {
        const spec = @field(args, field_info.name);
        if (spec.kind == .operand) {
            if (operand_ordinal == next_operand_ordinal.*) {
                if (spec.action != .append) {
                    next_operand_ordinal.* += 1;
                }
                try appendMatch(allocator, matches, occurrence_counts, .{
                    .arg_index = arg_index,
                    .raw_value = raw,
                    .argv_index = argv_index,
                    .raw_arg = raw,
                });
                return;
            }
            operand_ordinal += 1;
        }
    }

    return diagnostics.failWithDiagnostic(options, .{
        .kind = .unexpected_operand,
        .argv_index = argv_index,
        .raw_arg = raw,
    });
}

fn appendMatch(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList(Match),
    occurrence_counts: []usize,
    match: Match,
) ParseError!void {
    var next = match;
    next.arg_occurrence_index = occurrence_counts[match.arg_index];
    matches.append(allocator, next) catch return error.OutOfMemory;
    occurrence_counts[match.arg_index] += 1;
}
