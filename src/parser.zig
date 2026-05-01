const std = @import("std");

const diagnostics = @import("diagnostic.zig");
const schema = @import("schema.zig");
const tokenizer = @import("tokenizer.zig");

const ArgSpec = schema.ArgSpec;
const Token = tokenizer.Token;
const ParseError = diagnostics.ParseError;
const ParseOptions = diagnostics.ParseOptions;

pub const SubcommandStart = struct {
    subcommand_index: usize,
    argv_index: usize,
    user_arg_index: usize,
};

pub const ParseOutcome = union(enum) {
    complete,
    control: schema.StandardControl,
    subcommand: SubcommandStart,
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
};

const ValueLocation = struct {
    raw_value: []const u8,
    argv_index: usize,
    raw_arg: []const u8,
    cluster_offset: ?usize = null,
};

pub fn parseInto(
    comptime args: anytype,
    comptime long_options: []const schema.LongOption,
    comptime long_option_map: schema.LongOptionMap,
    comptime short_options: []const schema.ShortOption,
    comptime operand_arg_indexes: []const usize,
    comptime subcommands: anytype,
    user_args: []const []const u8,
    argv_index_base: usize,
    options: ParseOptions,
    sink: anytype,
) ParseError!ParseOutcome {
    const has_subcommands = @typeInfo(@TypeOf(subcommands)).@"struct".fields.len > 0;

    var next_operand_ordinal: usize = 0;
    var token_index: usize = 0;

    while (token_index < user_args.len) {
        const token = tokenizer.tokenize(argv_index_base + token_index, user_args[token_index]);
        switch (token) {
            .long_option => |payload| {
                if (try emitLongOptionMatch(args, long_options, long_option_map, sink, payload, user_args, &token_index, options)) |control| {
                    return .{ .control = control };
                }
            },
            .short_option => |payload| {
                try emitShortOptionMatch(args, short_options, sink, payload, user_args, &token_index, options);
            },
            .end_of_options => {
                token_index += 1;
                while (token_index < user_args.len) : (token_index += 1) {
                    try emitOperandMatch(
                        args,
                        operand_arg_indexes,
                        sink,
                        argv_index_base + token_index,
                        user_args[token_index],
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
                            .subcommand_index = subcommand_index,
                            .argv_index = payload.argv_index,
                            .user_arg_index = token_index,
                        } };
                    }

                    return diagnostics.failWithDiagnostic(options, .{
                        .kind = .unknown_subcommand,
                        .argv_index = payload.argv_index,
                        .raw_arg = payload.raw,
                        .value = payload.raw,
                    });
                }

                try emitOperandMatch(
                    args,
                    operand_arg_indexes,
                    sink,
                    payload.argv_index,
                    payload.raw,
                    &next_operand_ordinal,
                    options,
                );
            },
        }

        token_index += 1;
    }

    return .complete;
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

fn emitLongOptionMatch(
    comptime args: anytype,
    comptime long_options: []const schema.LongOption,
    comptime long_option_map: schema.LongOptionMap,
    sink: anytype,
    payload: @FieldType(Token, "long_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!?schema.StandardControl {
    if (long_option_map.get(payload.name)) |resolution| {
        return try emitResolvedLongOptionResolution(
            args,
            sink,
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
                return try emitResolvedLongOptionResolution(
                    args,
                    sink,
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

fn emitResolvedLongOptionResolution(
    comptime args: anytype,
    sink: anytype,
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

            if (comptime fields.len == 0) {
                unreachable;
            }

            switch (resolved_arg_index) {
                inline 0...fields.len - 1 => |arg_index| {
                    const field_info = fields[arg_index];
                    try emitResolvedLongOptionMatch(
                        arg_index,
                        field_info.name,
                        @field(args, field_info.name),
                        sink,
                        payload,
                        argv,
                        token_index,
                        options,
                    );
                    return null;
                },
                else => unreachable,
            }
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

fn emitResolvedLongOptionMatch(
    comptime arg_index: usize,
    comptime arg_name: []const u8,
    comptime spec: ArgSpec,
    sink: anytype,
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

            try sink.emit(arg_index, arg_name, spec, .{
                .arg_index = arg_index,
                .raw_value = null,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
            }, options);
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
                const value_argv_index = payload.argv_index + (value_index - token_index.*);
                token_index.* = value_index;
                break :value .{
                    .raw_value = argv[value_index],
                    .argv_index = value_argv_index,
                    .raw_arg = argv[value_index],
                    .cluster_offset = null,
                };
            };

            try sink.emit(arg_index, arg_name, spec, .{
                .arg_index = arg_index,
                .raw_value = value_location.raw_value,
                .argv_index = payload.argv_index,
                .raw_arg = payload.raw,
                .value_argv_index = value_location.argv_index,
                .value_raw_arg = value_location.raw_arg,
                .value_cluster_offset = value_location.cluster_offset,
            }, options);
        },
        .operand => unreachable,
    }
}

fn emitShortOptionMatch(
    comptime args: anytype,
    comptime short_options: []const schema.ShortOption,
    sink: anytype,
    payload: @FieldType(Token, "short_option"),
    argv: []const []const u8,
    token_index: *usize,
    options: ParseOptions,
) ParseError!void {
    var cluster_offset: usize = 1;

    while (cluster_offset < payload.raw.len) {
        const ch = payload.raw[cluster_offset];
        const rest = payload.raw[cluster_offset + 1 ..];

        if (comptime short_options.len == 0) {
            return diagnostics.failWithDiagnostic(options, .{
                .kind = .unknown_option,
                .argv_index = payload.argv_index,
                .cluster_offset = cluster_offset,
                .raw_arg = payload.raw,
            });
        }

        const short_option_index = std.sort.binarySearch(
            schema.ShortOption,
            short_options,
            ch,
            compareShortOption,
        ) orelse {
            return diagnostics.failWithDiagnostic(options, .{
                .kind = .unknown_option,
                .argv_index = payload.argv_index,
                .cluster_offset = cluster_offset,
                .raw_arg = payload.raw,
            });
        };

        if (try emitResolvedShortOptionMatch(
            args,
            short_options[short_option_index].arg_index,
            sink,
            payload,
            rest,
            argv,
            token_index,
            cluster_offset,
            options,
        )) {
            return;
        }

        cluster_offset += 1;
    }
}

fn compareShortOption(ch: u8, short_option: schema.ShortOption) std.math.Order {
    return std.math.order(ch, short_option.ch);
}

fn emitResolvedShortOptionMatch(
    comptime args: anytype,
    resolved_arg_index: usize,
    sink: anytype,
    payload: @FieldType(Token, "short_option"),
    rest: []const u8,
    argv: []const []const u8,
    token_index: *usize,
    cluster_offset: usize,
    options: ParseOptions,
) ParseError!bool {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    if (comptime fields.len == 0) {
        unreachable;
    }

    switch (resolved_arg_index) {
        inline 0...fields.len - 1 => |arg_index| {
            const field_info = fields[arg_index];
            const spec = @field(args, field_info.name);

            switch (spec.kind) {
                .flag => {
                    try sink.emit(arg_index, field_info.name, spec, .{
                        .arg_index = arg_index,
                        .raw_value = null,
                        .argv_index = payload.argv_index,
                        .raw_arg = payload.raw,
                        .cluster_offset = cluster_offset,
                    }, options);
                    return false;
                },
                .option => {
                    const value_location: ValueLocation = if (rest.len > 0) .{
                        .raw_value = rest,
                        .argv_index = payload.argv_index,
                        .raw_arg = payload.raw,
                        .cluster_offset = cluster_offset,
                    } else value: {
                        const value_index = token_index.* + 1;
                        if (value_index >= argv.len) {
                            return diagnostics.failWithDiagnostic(options, .{
                                .kind = .missing_value,
                                .argv_index = payload.argv_index,
                                .cluster_offset = cluster_offset,
                                .arg_name = field_info.name,
                                .raw_arg = payload.raw,
                            });
                        }

                        const value_argv_index = payload.argv_index + (value_index - token_index.*);
                        token_index.* = value_index;
                        break :value .{
                            .raw_value = argv[value_index],
                            .argv_index = value_argv_index,
                            .raw_arg = argv[value_index],
                            .cluster_offset = null,
                        };
                    };

                    try sink.emit(arg_index, field_info.name, spec, .{
                        .arg_index = arg_index,
                        .raw_value = value_location.raw_value,
                        .argv_index = payload.argv_index,
                        .raw_arg = payload.raw,
                        .cluster_offset = cluster_offset,
                        .value_argv_index = value_location.argv_index,
                        .value_raw_arg = value_location.raw_arg,
                        .value_cluster_offset = value_location.cluster_offset,
                    }, options);
                    return true;
                },
                .operand => unreachable,
            }
        },
        else => unreachable,
    }
}

fn emitOperandMatch(
    comptime args: anytype,
    comptime operand_arg_indexes: []const usize,
    sink: anytype,
    argv_index: usize,
    raw: []const u8,
    next_operand_ordinal: *usize,
    options: ParseOptions,
) ParseError!void {
    if (comptime operand_arg_indexes.len == 0) {
        return diagnostics.failWithDiagnostic(options, .{
            .kind = .unexpected_operand,
            .argv_index = argv_index,
            .raw_arg = raw,
        });
    }

    if (next_operand_ordinal.* >= operand_arg_indexes.len) {
        return diagnostics.failWithDiagnostic(options, .{
            .kind = .unexpected_operand,
            .argv_index = argv_index,
            .raw_arg = raw,
        });
    }

    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    if (comptime fields.len == 0) {
        unreachable;
    }

    switch (operand_arg_indexes[next_operand_ordinal.*]) {
        inline 0...fields.len - 1 => |arg_index| {
            const field_info = fields[arg_index];
            const spec = @field(args, field_info.name);
            if (spec.action != .append) {
                next_operand_ordinal.* += 1;
            }
            try sink.emit(arg_index, field_info.name, spec, .{
                .arg_index = arg_index,
                .raw_value = raw,
                .argv_index = argv_index,
                .raw_arg = raw,
            }, options);
            return;
        },
        else => unreachable,
    }
}
