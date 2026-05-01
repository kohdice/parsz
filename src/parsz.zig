const std = @import("std");

const schema = @import("schema.zig");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const diagnostics = @import("diagnostic.zig");
const help = @import("help.zig");

pub const ParseError = diagnostics.ParseError;
pub const ParseErrorKind = diagnostics.ParseErrorKind;
pub const Diagnostic = diagnostics.Diagnostic;
pub const ParseOptions = diagnostics.ParseOptions;
pub const Action = schema.Action;

pub const flag = schema.flag;
pub const option = schema.option;
pub const operand = schema.operand;
pub const version = schema.version;

fn hasAppendAction(comptime args: anytype) bool {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    inline for (fields) |field_info| {
        if (@field(args, field_info.name).action == .append) {
            return true;
        }
    }

    return false;
}

fn buildAppendBuffersType(comptime args: anytype) type {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    comptime {
        var names: [fields.len][:0]const u8 = undefined;
        var types: [fields.len]type = undefined;
        const attrs: [fields.len]std.builtin.Type.StructField.Attributes = @splat(.{});

        for (fields, 0..) |field_info, index| {
            const spec = @field(args, field_info.name);
            names[index] = field_info.name;
            types[index] = appendBufferFieldType(spec);
        }

        return @Struct(.auto, null, &names, &types, &attrs);
    }
}

fn appendBufferFieldType(comptime spec: schema.ArgSpec) type {
    return switch (spec.action) {
        .append => []spec.value_type,
        .set_true, .count, .set => void,
    };
}

pub fn Command(comptime declaration: anytype) type {
    schema.validateCommandDeclaration(declaration);

    const Declaration = @TypeOf(declaration);
    const has_version = @hasField(Declaration, "version");
    const subcommands = if (@hasField(Declaration, "subcommands")) declaration.subcommands else .{};
    const has_subcommands = @typeInfo(@TypeOf(subcommands)).@"struct".fields.len > 0;
    const command_about: ?[]const u8 = if (@hasField(Declaration, "about")) declaration.about else null;
    const args = declaration.args;
    const has_append_args = hasAppendAction(args);
    const standard_controls: schema.StandardControls = .{
        .help = true,
        .version = has_version,
    };
    const long_options = schema.buildLongOptions(args, standard_controls);
    const long_option_map = schema.buildLongOptionMap(&long_options);
    const short_options = schema.buildShortOptions(args);
    const operand_arg_indexes = schema.buildOperandArgIndexes(args);
    const parsed_type = schema.buildResultType(args);
    const append_buffers_type = buildAppendBuffersType(args);
    const subcommand_result_type = if (has_subcommands) schema.buildSubcommandResultType(subcommands) else void;
    const subcommand_type = if (has_subcommands) struct {
        parsed: parsed_type,
        command: subcommand_result_type,
    } else void;

    return struct {
        pub const is_parsz_command = true;
        pub const name = declaration.name;
        pub const about = command_about;
        pub const Parsed = parsed_type;
        const AppendBuffers = append_buffers_type;
        pub const SubcommandResult = subcommand_result_type;
        pub const Subcommand = subcommand_type;
        pub const Result = if (has_subcommands)
            if (has_version) union(enum) {
                parsed: Parsed,
                help,
                version,
                subcommand: Subcommand,
            } else union(enum) {
                parsed: Parsed,
                help,
                subcommand: Subcommand,
            }
        else if (has_version) union(enum) {
            parsed: Parsed,
            help,
            version,
        } else union(enum) {
            parsed: Parsed,
            help,
        };

        pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8, options: ParseOptions) ParseError!Result {
            const user_args = if (argv.len > 0) argv[1..] else argv[0..0];
            const argv_index_base: usize = if (argv.len > 0) 1 else 0;

            return parseUserArgs(allocator, user_args, argv_index_base, options);
        }

        fn parseUserArgs(
            allocator: std.mem.Allocator,
            user_args: []const []const u8,
            argv_index_base: usize,
            options: ParseOptions,
        ) ParseError!Result {
            if (comptime !has_append_args) {
                return parseUserArgsNoAppend(allocator, user_args, argv_index_base, options);
            }

            return parseUserArgsAppend(allocator, user_args, argv_index_base, options);
        }

        const NoAppendSink = struct {
            parsed: *Parsed,
            seen: []bool,

            pub fn emit(
                self: *@This(),
                comptime arg_index: usize,
                comptime arg_name: []const u8,
                comptime spec: schema.ArgSpec,
                match: parser.Match,
                options: ParseOptions,
            ) ParseError!void {
                try semantic.applyNonAppendMatch(arg_name, spec, match, self.parsed, options);
                self.seen[arg_index] = true;
            }
        };

        const AppendCountSink = struct {
            counts: []usize,

            pub fn emit(
                self: *@This(),
                comptime arg_index: usize,
                comptime arg_name: []const u8,
                comptime spec: schema.ArgSpec,
                match: parser.Match,
                options: ParseOptions,
            ) ParseError!void {
                _ = arg_name;
                _ = match;
                _ = options;

                if (comptime spec.action == .append) {
                    self.counts[arg_index] += 1;
                }
            }
        };

        const AppendSink = struct {
            parsed: *Parsed,
            seen: []bool,
            append_buffers: *AppendBuffers,
            append_indices: []usize,

            pub fn emit(
                self: *@This(),
                comptime arg_index: usize,
                comptime arg_name: []const u8,
                comptime spec: schema.ArgSpec,
                match: parser.Match,
                options: ParseOptions,
            ) ParseError!void {
                if (comptime spec.action == .append) {
                    const append_index = self.append_indices[arg_index];
                    try semantic.applyAppendMatch(
                        arg_name,
                        spec,
                        match,
                        @field(self.append_buffers.*, arg_name),
                        append_index,
                        options,
                    );
                    self.append_indices[arg_index] = append_index + 1;
                } else {
                    try semantic.applyNonAppendMatch(arg_name, spec, match, self.parsed, options);
                }

                self.seen[arg_index] = true;
            }

            fn finish(self: *@This()) void {
                const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

                inline for (fields) |field_info| {
                    const spec = @field(args, field_info.name);
                    if (comptime spec.action == .append) {
                        @field(self.parsed.*, field_info.name) = @field(self.append_buffers.*, field_info.name);
                        @field(self.append_buffers.*, field_info.name) = &.{};
                    }
                }
            }
        };

        fn initAppendBuffers(allocator: std.mem.Allocator, counts: []const usize) ParseError!AppendBuffers {
            const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

            var append_buffers: AppendBuffers = undefined;
            inline for (fields) |field_info| {
                const spec = @field(args, field_info.name);
                @field(append_buffers, field_info.name) = if (comptime spec.action == .append) &.{} else {};
            }
            errdefer deinitAppendBuffers(allocator, &append_buffers);

            inline for (fields, 0..) |field_info, arg_index| {
                const spec = @field(args, field_info.name);
                if (comptime spec.action == .append) {
                    const count = counts[arg_index];
                    @field(append_buffers, field_info.name) = if (count == 0)
                        &.{}
                    else
                        allocator.alloc(spec.value_type, count) catch return error.OutOfMemory;
                }
            }

            return append_buffers;
        }

        fn deinitAppendBuffers(allocator: std.mem.Allocator, append_buffers: *AppendBuffers) void {
            const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

            inline for (fields) |field_info| {
                const spec = @field(args, field_info.name);
                if (comptime spec.action == .append) {
                    const values = @field(append_buffers.*, field_info.name);
                    if (values.len > 0) {
                        allocator.free(values);
                    }
                    @field(append_buffers.*, field_info.name) = &.{};
                }
            }
        }

        fn parseUserArgsNoAppend(
            allocator: std.mem.Allocator,
            user_args: []const []const u8,
            argv_index_base: usize,
            options: ParseOptions,
        ) ParseError!Result {
            const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

            var parsed: Parsed = undefined;
            schema.initializeResultDefaults(args, &parsed);

            var seen = [_]bool{false} ** fields.len;
            var sink = NoAppendSink{
                .parsed = &parsed,
                .seen = seen[0..],
            };

            const outcome = try parser.parseInto(
                args,
                &long_options,
                long_option_map,
                &short_options,
                &operand_arg_indexes,
                subcommands,
                user_args,
                argv_index_base,
                options,
                &sink,
            );

            switch (outcome) {
                .complete => {
                    try semantic.validateRequiredSeen(args, seen[0..], options);
                    return .{ .parsed = parsed };
                },
                .control => |control| return controlResult(control),
                .subcommand => |invocation| {
                    if (comptime has_subcommands) {
                        try semantic.validateRequiredSeen(args, seen[0..], options);

                        return .{ .subcommand = .{
                            .parsed = parsed,
                            .command = try parseSubcommandStart(
                                allocator,
                                user_args,
                                options,
                                invocation.subcommand_index,
                                invocation.argv_index,
                                invocation.user_arg_index,
                            ),
                        } };
                    } else {
                        unreachable;
                    }
                },
            }
        }

        fn parseUserArgsAppend(
            allocator: std.mem.Allocator,
            user_args: []const []const u8,
            argv_index_base: usize,
            options: ParseOptions,
        ) ParseError!Result {
            const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

            var append_counts = [_]usize{0} ** fields.len;
            var count_sink = AppendCountSink{
                .counts = append_counts[0..],
            };

            const counted_outcome = try parser.parseInto(
                args,
                &long_options,
                long_option_map,
                &short_options,
                &operand_arg_indexes,
                subcommands,
                user_args,
                argv_index_base,
                options,
                &count_sink,
            );

            if (counted_outcome == .control) {
                return controlResult(counted_outcome.control);
            }

            var parsed: Parsed = undefined;
            schema.initializeResultDefaults(args, &parsed);
            errdefer deinitParsed(allocator, &parsed);

            var append_buffers = try initAppendBuffers(allocator, append_counts[0..]);
            defer deinitAppendBuffers(allocator, &append_buffers);

            var seen = [_]bool{false} ** fields.len;
            var append_indices = [_]usize{0} ** fields.len;
            var sink = AppendSink{
                .parsed = &parsed,
                .seen = seen[0..],
                .append_buffers = &append_buffers,
                .append_indices = append_indices[0..],
            };

            const outcome = try parser.parseInto(
                args,
                &long_options,
                long_option_map,
                &short_options,
                &operand_arg_indexes,
                subcommands,
                user_args,
                argv_index_base,
                options,
                &sink,
            );

            switch (outcome) {
                .complete => {
                    try semantic.validateRequiredSeen(args, seen[0..], options);
                    sink.finish();
                    return .{ .parsed = parsed };
                },
                .control => |control| return controlResult(control),
                .subcommand => |invocation| {
                    if (comptime has_subcommands) {
                        try semantic.validateRequiredSeen(args, seen[0..], options);
                        sink.finish();

                        return .{ .subcommand = .{
                            .parsed = parsed,
                            .command = try parseSubcommandStart(
                                allocator,
                                user_args,
                                options,
                                invocation.subcommand_index,
                                invocation.argv_index,
                                invocation.user_arg_index,
                            ),
                        } };
                    } else {
                        unreachable;
                    }
                },
            }
        }

        fn controlResult(control: schema.StandardControl) Result {
            switch (control) {
                .help => return .help,
                .version => {
                    if (comptime has_version) {
                        return .version;
                    }
                    unreachable;
                },
            }
        }

        fn parseSubcommandStart(
            allocator: std.mem.Allocator,
            user_args: []const []const u8,
            options: ParseOptions,
            subcommand_index: usize,
            argv_index: usize,
            user_arg_index: usize,
        ) ParseError!SubcommandResult {
            const fields = @typeInfo(@TypeOf(subcommands)).@"struct".fields;

            if (comptime fields.len == 0) {
                unreachable;
            }

            switch (subcommand_index) {
                inline 0...fields.len - 1 => |child_index| {
                    const field_info = fields[child_index];
                    const Child = @field(subcommands, field_info.name);
                    const child_user_args = user_args[user_arg_index + 1 ..];
                    const child_argv_index_base = argv_index + 1;
                    const child_result = try Child.parseUserArgs(
                        allocator,
                        child_user_args,
                        child_argv_index_base,
                        options,
                    );
                    return @unionInit(SubcommandResult, field_info.name, child_result);
                },
                else => unreachable,
            }
        }

        pub fn deinit(allocator: std.mem.Allocator, result: *Result) void {
            if (comptime has_subcommands) {
                if (comptime has_version) {
                    switch (result.*) {
                        .parsed => |*parsed| deinitParsed(allocator, parsed),
                        .help, .version => {},
                        .subcommand => |*subcommand_node| deinitSubcommand(allocator, subcommand_node),
                    }
                } else {
                    switch (result.*) {
                        .parsed => |*parsed| deinitParsed(allocator, parsed),
                        .help => {},
                        .subcommand => |*subcommand_node| deinitSubcommand(allocator, subcommand_node),
                    }
                }
            } else {
                if (comptime has_version) {
                    switch (result.*) {
                        .parsed => |*parsed| deinitParsed(allocator, parsed),
                        .help, .version => {},
                    }
                } else {
                    switch (result.*) {
                        .parsed => |*parsed| deinitParsed(allocator, parsed),
                        .help => {},
                    }
                }
            }
        }

        fn deinitParsed(allocator: std.mem.Allocator, parsed: *Parsed) void {
            schema.deinitResult(args, allocator, parsed);
        }

        fn deinitSubcommand(allocator: std.mem.Allocator, subcommand_node: *Subcommand) void {
            deinitParsed(allocator, &subcommand_node.parsed);
            deinitSubcommandResult(allocator, &subcommand_node.command);
        }

        fn deinitSubcommandResult(allocator: std.mem.Allocator, subcommand_result: *SubcommandResult) void {
            switch (subcommand_result.*) {
                inline else => |*child_result, tag| {
                    const Child = @field(subcommands, @tagName(tag));
                    Child.deinit(allocator, child_result);
                },
            }
        }

        pub fn writeUsage(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return help.writeUsage(writer, declaration.name, args);
        }

        pub fn writeHelp(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return help.writeHelp(writer, declaration.name, command_about, args, subcommands, standard_controls);
        }

        pub fn writeVersion(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (comptime !has_version) {
                @compileError("writeVersion requires command version metadata");
            }

            return help.writeVersion(writer, declaration.name, declaration.version);
        }

        pub fn renderUsage(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            return help.renderUsage(allocator, declaration.name, args);
        }

        pub fn renderHelp(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            return help.renderHelp(allocator, declaration.name, command_about, args, subcommands, standard_controls);
        }

        pub fn renderVersion(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
            if (comptime !has_version) {
                @compileError("renderVersion requires command version metadata");
            }

            return help.renderVersion(allocator, declaration.name, declaration.version);
        }
    };
}

const test_version_metadata = version(.{ .number = "1.2.3", .details =
    \\Copyright (C) 2026 parsz contributors
    \\License MIT: MIT License <https://opensource.org/licenses/MIT>
    \\This is free software: you are free to change and redistribute it.
    \\There is NO WARRANTY, to the extent permitted by law.
});

test "schema: accepts empty command definition" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    try std.testing.expectEqual(@as(usize, 0), @typeInfo(Cli.Parsed).@"struct".fields.len);

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    Cli.deinit(std.testing.allocator, &result);
}

test "schema: accepts one boolean flag" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Parsed, "verbose") == bool);

    var result = try parseTestResult(Cli, std.testing.allocator, &.{}, .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(!result.verbose);
}

test "schema: accepts short and long names for the same option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Parsed, "verbose") == bool);
}

test "schema: maps anonymous struct arg fields to result field names" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const fields = @typeInfo(Cli.Parsed).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("verbose", fields[0].name);
}

test "schema: maps actions and required/default settings to result field types" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .debug = flag(.{
                .long = "debug",
            }),
            .verbose = flag(.{
                .long = "verbose",
                .action = .count,
            }),
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
            .color = option([]const u8, .{
                .long = "color",
            }),
            .port = option(u16, .{
                .long = "port",
                .default = 80,
            }),
            .include = option([]const u8, .{
                .long = "include",
                .action = .append,
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Parsed, "debug") == bool);
    try std.testing.expect(@FieldType(Cli.Parsed, "verbose") == u32);
    try std.testing.expect(@FieldType(Cli.Parsed, "output") == []const u8);
    try std.testing.expect(@FieldType(Cli.Parsed, "color") == ?[]const u8);
    try std.testing.expect(@FieldType(Cli.Parsed, "port") == u16);
    try std.testing.expect(@FieldType(Cli.Parsed, "include") == []const []const u8);
}

test "runtime api: parse accepts process argv and skips argv zero" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{ "app", "--verbose" };

    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    switch (result) {
        .parsed => |parsed| try std.testing.expect(parsed.verbose),
        else => return error.ExpectedParsedResult,
    }
}

test "runtime api: result type omits unreachable version tag without metadata" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    try std.testing.expect(!@hasField(Cli.Result, "version"));
}

test "runtime api: result type includes version tag with metadata" {
    const Cli = Command(.{
        .name = "app",
        .version = test_version_metadata,
        .args = .{},
    });

    try std.testing.expect(@hasField(Cli.Result, "version"));
}

test "runtime api: parse accepts empty argv as empty process argv" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    switch (result) {
        .parsed => |parsed| try std.testing.expectEqual(@as(usize, 0), @typeInfo(@TypeOf(parsed)).@"struct".fields.len),
        else => return error.ExpectedParsedResult,
    }
}

test "runtime api: parse reports diagnostics in caller argv coordinates" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{ "app", "extra" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "runtime api: reports diagnostics through parse options" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"extra"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "runtime api: reports missing required flag without input" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
}

test "runtime api: reports missing required append option without input" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .include = option([]const u8, .{
                .long = "include",
                .action = .append,
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("include", diagnostic.arg_name.?);
}

test "runtime api: exposes result deinit as no-op for borrowed-only schemas" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    Cli.deinit(std.testing.allocator, &result);
}

test "runtime api: parses empty input without allocation" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"app"};
    var result = try Cli.parse(std.testing.failing_allocator, argv[0..], .{});
    Cli.deinit(std.testing.failing_allocator, &result);
}

test "runtime api: parses standard help without allocation" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{ "app", "--help" };
    var result = try Cli.parse(std.testing.failing_allocator, argv[0..], .{});
    Cli.deinit(std.testing.failing_allocator, &result);

    switch (result) {
        .help => {},
        else => return error.ExpectedHelpResult,
    }
}

test "runtime api: parses borrowed-only input without allocation" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "app", "--verbose", "--output", "path" };
    var result = try Cli.parse(std.testing.failing_allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.failing_allocator, &result);

    switch (result) {
        .parsed => |parsed| {
            try std.testing.expect(parsed.verbose);
            try std.testing.expectEqualStrings("path", parsed.output);
        },
        else => return error.ExpectedParsedResult,
    }
}

test "tokenizer: classifies operands" {
    const token = tokenizer.tokenize(0, "file.txt");
    try expectOperandToken(token, 0, "file.txt");
}

test "tokenizer: offsets token indexes by argv base" {
    const token = tokenizer.tokenize(3, "file.txt");
    try expectOperandToken(token, 3, "file.txt");
}

test "tokenizer: classifies end of options marker" {
    const token = tokenizer.tokenize(0, "--");
    try expectEndOfOptionsToken(token, 0, "--");
}

test "tokenizer: classifies each argument independently" {
    try expectEndOfOptionsToken(tokenizer.tokenize(0, "--"), 0, "--");
    try expectLongOptionToken(tokenizer.tokenize(1, "--verbose"), 1, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option without value" {
    const token = tokenizer.tokenize(0, "--verbose");
    try expectLongOptionToken(token, 0, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option with inline value" {
    const token = tokenizer.tokenize(0, "--output=path");
    try expectLongOptionToken(token, 0, "--output=path", "output", "path");
}

test "tokenizer: preserves empty long inline value" {
    const token = tokenizer.tokenize(0, "--output=");
    try expectLongOptionToken(token, 0, "--output=", "output", "");
}

test "tokenizer: classifies single hyphen as operand" {
    const token = tokenizer.tokenize(0, "-");
    try expectOperandToken(token, 0, "-");
}

test "tokenizer: preserves short option suffix" {
    const token = tokenizer.tokenize(0, "-abc");
    try expectShortOptionToken(token, 0, "-abc", 'a', "bc");
}

test "tokenizer: preserves attached short value candidate" {
    const token = tokenizer.tokenize(0, "-Iinclude");
    try expectShortOptionToken(token, 0, "-Iinclude", 'I', "include");
}

test "parser: parses one long flag occurrence" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: rejects long abbreviation unless explicitly enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqualStrings("ver", diagnostic.value.?);
}

test "parser: parses unique long abbreviation when enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: reports ambiguous long abbreviation when enabled" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .version = flag(.{
                .long = "version",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
        .abbreviate_long_options = true,
    }));

    try std.testing.expectEqual(ParseErrorKind.ambiguous_abbreviation, diagnostic.kind);
    try std.testing.expectEqualStrings("ver", diagnostic.value.?);
}

test "parser: prefers exact long option match over abbreviation" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .ver = flag(.{
                .long = "ver",
            }),
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--ver"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.ver);
    try std.testing.expect(!result.verbose);
}

test "parser: parses one short flag occurrence" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
            }),
        },
    });

    const argv = [_][]const u8{"-v"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
}

test "parser: expands short flag clusters" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .binary = flag(.{
                .short = 'b',
            }),
            .count = flag(.{
                .short = 'c',
            }),
        },
    });

    const argv = [_][]const u8{"-abc"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expect(result.binary);
    try std.testing.expect(result.count);
}

test "parser: counts repeated flag occurrences" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .action = .count,
            }),
        },
    });

    const argv = [_][]const u8{ "-v", "-v", "-v" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u32, 3), result.verbose);
}

test "parser: counts repeated grouped short flag occurrences" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .action = .count,
            }),
        },
    });

    const argv = [_][]const u8{"-vvv"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u32, 3), result.verbose);
}

test "parser: parses long option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "path" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses long option value from inline equals form" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output=path"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses short option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .short = 'o',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-o", "path" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("path", result.output);
}

test "parser: parses short option value from attached suffix" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"-Iinclude"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("include", result.include);
}

test "parser: treats suffix after short option as its value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .short = 'o',
                .required = true,
            }),
            .verbose = flag(.{
                .short = 'v',
            }),
        },
    });

    const argv = [_][]const u8{"-ov"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("v", result.output);
    try std.testing.expect(!result.verbose);
}

test "parser: parses trailing short cluster suffix as value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .output = option([]const u8, .{
                .short = 'b',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"-abVALUE"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expectEqualStrings("VALUE", result.output);
}

test "parser: parses trailing short cluster option value from next argv item" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .output = option([]const u8, .{
                .short = 'b',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-ab", "VALUE" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.all);
    try std.testing.expectEqualStrings("VALUE", result.output);
}

test "parser: assigns one operand by declaration order" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"input.txt"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("input.txt", result.source);
}

test "parser: assigns multiple operands by declaration order" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "src", "dst" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("src", result.source);
    try std.testing.expectEqualStrings("dst", result.dest);
}

test "parser: permits options between operands" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "src", "--verbose", "dst" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.verbose);
    try std.testing.expectEqualStrings("src", result.source);
    try std.testing.expectEqualStrings("dst", result.dest);
}

test "parser: treats arguments after end marker as operands" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--", "--source", "-d" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--source", result.source);
    try std.testing.expectEqualStrings("-d", result.dest);
}

test "parser: consumes end marker as required option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "--" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--", result.output);
}

test "parser: continues option scanning after end marker consumed as value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "--", "--verbose" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("--", result.output);
    try std.testing.expect(result.verbose);
}

test "parser: consumes dash-prefixed required option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(i8, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--port", "-1" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(i8, -1), result.port);
}

test "parser: assigns variadic operands in command-line order" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .sources = operand([]const u8, .{
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "a.zig", "b.zig" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.sources.len);
    try std.testing.expectEqualStrings("a.zig", result.sources[0]);
    try std.testing.expectEqualStrings("b.zig", result.sources[1]);
}

test "parser: preserves repeated option value matches in command-line order" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "-I", "a", "-I", "b" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    try std.testing.expectEqualStrings("a", result.include[0]);
    try std.testing.expectEqualStrings("b", result.include[1]);
}

test "append: parses append option values correctly after direct accumulation" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .long = "include",
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "cc", "--include", "a", "--include=b", "--include", "c" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| {
            try std.testing.expectEqual(@as(usize, 3), result.include.len);
            try std.testing.expectEqualStrings("a", result.include[0]);
            try std.testing.expectEqualStrings("b", result.include[1]);
            try std.testing.expectEqualStrings("c", result.include[2]);
        },
        else => return error.ExpectedParsedResult,
    }
}

test "append: deinit releases only owned append slices" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .long = "include",
                .action = .append,
            }),
        },
    });

    const empty_argv = [_][]const u8{"cc"};
    var empty_result = try Cli.parse(std.testing.allocator, empty_argv[0..], .{});
    Cli.deinit(std.testing.allocator, &empty_result);

    switch (empty_result) {
        .parsed => |result| try std.testing.expectEqual(@as(usize, 0), result.include.len),
        else => return error.ExpectedParsedResult,
    }

    const non_empty_argv = [_][]const u8{ "cc", "--include", "a" };
    var non_empty_result = try Cli.parse(std.testing.allocator, non_empty_argv[0..], .{});
    Cli.deinit(std.testing.allocator, &non_empty_result);

    switch (non_empty_result) {
        .parsed => |result| try std.testing.expectEqual(@as(usize, 0), result.include.len),
        else => return error.ExpectedParsedResult,
    }
}

test "append: preserves diagnostics for invalid appended values" {
    const Mode = enum { fast };
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .mode = option(Mode, .{
                .short = 'm',
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "app", "-mquick" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("mode", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("-mquick", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("quick", diagnostic.value.?);
}

test "runtime api: append command only allocates returned append slices" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .long = "include",
                .action = .append,
            }),
        },
    });

    var counting = CountingAllocator.init(std.testing.allocator);
    const allocator = counting.allocator();

    const argv = [_][]const u8{ "cc", "--include", "a", "--include", "b", "--include=c" };
    var parse_result = try Cli.parse(allocator, argv[0..], .{});
    defer Cli.deinit(allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| {
            try std.testing.expectEqual(@as(usize, 3), result.include.len);
            try std.testing.expectEqualStrings("a", result.include[0]);
            try std.testing.expectEqualStrings("b", result.include[1]);
            try std.testing.expectEqualStrings("c", result.include[2]);
        },
        else => return error.ExpectedParsedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), counting.alloc_count);
}

test "parser: reports unknown long option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"--missing"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("--missing", diagnostic.raw_arg.?);
}

test "parser: reports unknown short option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"-x"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("-x", diagnostic.raw_arg.?);
}

test "parser: reports unknown short option inside cluster with diagnostic offset" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
        },
    });

    const argv = [_][]const u8{"-ax"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("-ax", diagnostic.raw_arg.?);
}

test "semantic: reports missing required option value with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_value, diagnostic.kind);
    try std.testing.expectEqualStrings("output", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("--output", diagnostic.raw_arg.?);
}

test "semantic: reports unexpected value for flag with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose=true"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("true", diagnostic.value.?);
}

test "semantic: reports empty inline value for flag as unexpected value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{"--verbose="};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqualStrings("", diagnostic.value.?);
}

test "semantic: reports missing required operand with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("source", diagnostic.arg_name.?);
}

test "semantic: reports unexpected operand with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "input", "extra" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "semantic: accepts empty inline value for string option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--output="};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("", result.output);
}

test "semantic: returns null for absent optional option without default" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .color = option([]const u8, .{
                .long = "color",
            }),
        },
    });

    var result = try parseTestResult(Cli, std.testing.allocator, &.{}, .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.color == null);
}

test "semantic: applies default value for absent optional option" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .default = 80,
            }),
        },
    });

    var result = try parseTestResult(Cli, std.testing.allocator, &.{}, .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u16, 80), result.port);
}

test "semantic: returns borrowed string slices for textual values" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--output", "path" };
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expect(result.output.ptr == argv[1].ptr);
    try std.testing.expectEqual(argv[1].len, result.output.len);
}

test "semantic: deinit releases collected append storage" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .short = 'I',
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "-I", "a", "-I", "b" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});

    switch (result) {
        .parsed => |parsed| try std.testing.expectEqual(@as(usize, 2), parsed.include.len),
        else => return error.ExpectedParsedResult,
    }

    Cli.deinit(std.testing.allocator, &result);

    switch (result) {
        .parsed => |parsed| try std.testing.expectEqual(@as(usize, 0), parsed.include.len),
        else => return error.ExpectedParsedResult,
    }
}

test "semantic: reports count action overflow with diagnostic" {
    const args = .{
        .verbose = flag(.{
            .short = 'v',
            .action = .count,
        }),
    };
    var result: schema.buildResultType(args) = .{
        .verbose = std.math.maxInt(u32),
    };
    const match: parser.Match = .{
        .arg_index = 0,
        .raw_value = null,
        .argv_index = 0,
        .raw_arg = "-v",
        .cluster_offset = 1,
    };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, semantic.applyNonAppendMatch("verbose", args.verbose, match, &result, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("verbose", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("-v", diagnostic.raw_arg.?);
}

test "semantic: parses integer option value" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=8080"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(u16, 8080), result.port);
}

test "semantic: reports invalid integer option value with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=abc"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("abc", diagnostic.value.?);
}

test "semantic: reports invalid separated integer value at value argv index" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u16, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "--port", "abc" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("abc", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("abc", diagnostic.value.?);
}

test "semantic: reports integer range overflow with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u8, .{
                .long = "port",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--port=300"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("300", diagnostic.value.?);
}

test "semantic: reports short separated integer overflow at value argv index" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .port = option(u8, .{
                .short = 'p',
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "-p", "300" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.argv_index);
    try std.testing.expectEqual(@as(?usize, null), diagnostic.cluster_offset);
    try std.testing.expectEqualStrings("port", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("300", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("300", diagnostic.value.?);
}

test "semantic: parses enum option value" {
    const Mode = enum { fast, slow };
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .mode = option(Mode, .{
                .long = "mode",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--mode=fast"};
    var result = try parseTestResult(Cli, std.testing.allocator, argv[0..], .{});
    defer Cli.deinitParsed(std.testing.allocator, &result);

    try std.testing.expectEqual(Mode.fast, result.mode);
}

test "semantic: reports invalid enum option value with diagnostic" {
    const Mode = enum { fast, slow };
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .mode = option(Mode, .{
                .long = "mode",
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{"--mode=quick"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, parseTestResult(Cli, std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("mode", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("quick", diagnostic.value.?);
}

test "help: renders usage for flags options and operands" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
            }),
            .output = option([]const u8, .{
                .short = 'o',
                .long = "output",
                .required = true,
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
            .dest = operand([]const u8, .{}),
        },
    });

    const usage = try Cli.renderUsage(std.testing.allocator);
    defer std.testing.allocator.free(usage);

    try std.testing.expectEqualStrings(
        "Usage: copy [-v|--verbose] -o|--output <output> <source> [dest]\n",
        usage,
    );
}

test "help: renders append option as a repeated option occurrence" {
    const Cli = Command(.{
        .name = "cc",
        .args = .{
            .include = option([]const u8, .{
                .long = "include",
                .value_name = "PATH",
                .action = .append,
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const usage = try Cli.renderUsage(std.testing.allocator);
    defer std.testing.allocator.free(usage);

    try std.testing.expectEqualStrings(
        "Usage: cc [--include <PATH>]... <source>\n",
        usage,
    );
}

test "help: handles explicit help request without ParseFailed" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--help" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .help => {},
        else => return error.ExpectedHelpResult,
    }
}

test "help: rejects inline value for standard help option" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{},
    });

    const argv = [_][]const u8{ "test", "--help=value" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("help", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("--help=value", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("value", diagnostic.value.?);
}

test "help: renders command and argument metadata" {
    const Cli = Command(.{
        .name = "copy",
        .about = "Copy one file",
        .version = test_version_metadata,
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
                .help = "Print additional progress information",
            }),
            .output = option([]const u8, .{
                .long = "output",
                .value_name = "PATH",
                .help = "Write output to PATH",
                .required = true,
            }),
            .source = operand([]const u8, .{
                .value_name = "SRC",
                .required = true,
            }),
        },
    });

    const text = try Cli.renderHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Usage: copy [-v|--verbose] --output <PATH> <SRC>
        \\
        \\Copy one file
        \\
        \\Options:
        \\  -v, --verbose  Print additional progress information
        \\  --output <PATH>  Write output to PATH
        \\  --help
        \\  --version
        \\
    , text);
}

test "help: renders operand help metadata" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .value_name = "SRC",
                .help = "Read input from SRC",
                .required = true,
            }),
            .dest = operand([]const u8, .{
                .value_name = "DEST",
                .help = "Write output to DEST",
            }),
        },
    });

    const text = try Cli.renderHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Usage: copy <SRC> [DEST]
        \\
        \\Options:
        \\  --help
        \\
        \\Operands:
        \\  <SRC>  Read input from SRC
        \\  [DEST]  Write output to DEST
        \\
    , text);
}

test "help: writes help to writer without allocation" {
    const Cli = Command(.{
        .name = "copy",
        .about = "Copy one file",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
                .help = "Print additional progress information",
            }),
        },
    });

    const argv = [_][]const u8{ "copy", "--help" };
    var parse_result = try Cli.parse(std.testing.failing_allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.failing_allocator, &parse_result);

    switch (parse_result) {
        .help => {},
        else => return error.ExpectedHelpResult,
    }

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try Cli.writeHelp(&writer);

    try std.testing.expectEqualStrings(
        \\Usage: copy [--verbose]
        \\
        \\Copy one file
        \\
        \\Options:
        \\  --verbose  Print additional progress information
        \\  --help
        \\
    , writer.buffered());
}

test "version: writes version to writer without allocation" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{},
    });

    const text = try Cli.renderVersion(std.testing.allocator);
    defer std.testing.allocator.free(text);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try Cli.writeVersion(&writer);

    try std.testing.expectEqualStrings(text, writer.buffered());
}

test "usage: writes usage to writer without allocation" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
            }),
            .output = option([]const u8, .{
                .short = 'o',
                .long = "output",
                .required = true,
            }),
        },
    });

    const text = try Cli.renderUsage(std.testing.allocator);
    defer std.testing.allocator.free(text);

    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try Cli.writeUsage(&writer);

    try std.testing.expectEqualStrings(text, writer.buffered());
}

test "help: ignores later invalid arguments after standard help request" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--help", "--unknown", "missing" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .help => {},
        else => return error.ExpectedHelpResult,
    }
}

test "parse: returns parsed result for normal command input" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--verbose", "input.txt" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| {
            try std.testing.expect(result.verbose);
            try std.testing.expectEqualStrings("input.txt", result.source);
        },
        else => return error.ExpectedParsedResult,
    }
}

test "help: parses unique standard help abbreviation when enabled" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{},
    });

    const argv = [_][]const u8{ "test", "--hel" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .help => {},
        else => return error.ExpectedHelpResult,
    }
}

test "help: exact user long option wins over standard help abbreviation" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .he = flag(.{
                .long = "he",
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--he" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| try std.testing.expect(result.he),
        else => return error.ExpectedParsedResult,
    }
}

test "help: standard help abbreviation participates in ambiguity checks" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .host = flag(.{
                .long = "host",
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--h" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
        .abbreviate_long_options = true,
    }));

    try std.testing.expectEqual(ParseErrorKind.ambiguous_abbreviation, diagnostic.kind);
    try std.testing.expectEqualStrings("h", diagnostic.value.?);
}

test "version: renders version text from command metadata" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{},
    });

    const text = try Cli.renderVersion(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\copy 1.2.3
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
        \\
    , text);
}

test "version: handles explicit version request without ParseFailed" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--version" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .version => {},
        else => return error.ExpectedVersionResult,
    }
}

test "version: rejects inline value for standard version option" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{},
    });

    const argv = [_][]const u8{ "test", "--version=value" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("version", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("--version=value", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("value", diagnostic.value.?);
}

test "version: ignores later invalid arguments after standard version request" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--version", "--unknown", "missing" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .version => {},
        else => return error.ExpectedVersionResult,
    }
}

test "version: standard version abbreviation participates in ambiguity checks" {
    const Cli = Command(.{
        .name = "copy",
        .version = test_version_metadata,
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--ver" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
        .abbreviate_long_options = true,
    }));

    try std.testing.expectEqual(ParseErrorKind.ambiguous_abbreviation, diagnostic.kind);
    try std.testing.expectEqualStrings("ver", diagnostic.value.?);
}

test "version: does not inject implicit version option without version metadata" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{},
    });

    const argv = [_][]const u8{ "test", "--version" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqualStrings("--version", diagnostic.raw_arg.?);
}

test "version: user declared version remains ordinary without version metadata" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .version = flag(.{
                .long = "version",
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--version" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| try std.testing.expect(result.version),
        else => return error.ExpectedParsedResult,
    }
}

test "subcommand: parses one nested command" {
    const Cli = Command(.{
        .name = "git",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
        .subcommands = .{
            .remote = Command(.{
                .name = "remote",
                .args = .{},
                .subcommands = .{
                    .add = Command(.{
                        .name = "add",
                        .args = .{
                            .name = operand([]const u8, .{
                                .required = true,
                            }),
                        },
                    }),
                },
            }),
        },
    });

    const argv = [_][]const u8{ "test", "--verbose", "remote", "add", "origin" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .subcommand => |node| {
            try std.testing.expect(node.parsed.verbose);
            switch (node.command) {
                .remote => |remote_result| switch (remote_result) {
                    .subcommand => |remote_node| switch (remote_node.command) {
                        .add => |add_result| switch (add_result) {
                            .parsed => |result| try std.testing.expectEqualStrings("origin", result.name),
                            else => return error.ExpectedParsedResult,
                        },
                    },
                    else => return error.ExpectedSubcommandResult,
                },
            }
        },
        else => return error.ExpectedSubcommandResult,
    }
}

test "subcommand: root help lists available subcommands" {
    const Remote = Command(.{
        .name = "remote",
        .about = "Manage remote repositories",
        .args = .{},
    });
    const Status = Command(.{
        .name = "status",
        .about = "Show working tree status",
        .args = .{},
    });
    const Cli = Command(.{
        .name = "mini-git",
        .about = "Demonstrate nested subcommand parsing",
        .args = .{},
        .subcommands = .{
            .remote = Remote,
            .status = Status,
        },
    });

    const text = try Cli.renderHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Usage: mini-git
        \\
        \\Demonstrate nested subcommand parsing
        \\
        \\Options:
        \\  --help
        \\
        \\Commands:
        \\  remote  Manage remote repositories
        \\  status  Show working tree status
        \\
    , text);
}

test "subcommand: nested help lists available subcommands" {
    const Add = Command(.{
        .name = "add",
        .about = "Add a named remote",
        .args = .{},
    });
    const Remove = Command(.{
        .name = "remove",
        .about = "Remove a named remote",
        .args = .{},
    });
    const Remote = Command(.{
        .name = "remote",
        .about = "Manage remote repositories",
        .args = .{},
        .subcommands = .{
            .add = Add,
            .remove = Remove,
        },
    });
    const Status = Command(.{
        .name = "status",
        .about = "Show working tree status",
        .args = .{},
    });
    const Cli = Command(.{
        .name = "mini-git",
        .args = .{},
        .subcommands = .{
            .remote = Remote,
            .status = Status,
        },
    });
    _ = Cli;

    const text = try Remote.renderHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Usage: remote
        \\
        \\Manage remote repositories
        \\
        \\Options:
        \\  --help
        \\
        \\Commands:
        \\  add  Add a named remote
        \\  remove  Remove a named remote
        \\
    , text);
}

test "subcommand: help omits commands section without subcommands" {
    const Cli = Command(.{
        .name = "copy",
        .about = "Copy one file",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
                .help = "Print additional progress information",
            }),
        },
    });

    const text = try Cli.renderHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\Usage: copy [--verbose]
        \\
        \\Copy one file
        \\
        \\Options:
        \\  --verbose  Print additional progress information
        \\  --help
        \\
    , text);
}

test "subcommand: reports unknown subcommand" {
    const Cli = Command(.{
        .name = "git",
        .args = .{},
        .subcommands = .{
            .remote = Command(.{
                .name = "remote",
                .args = .{},
            }),
        },
    });

    const argv = [_][]const u8{ "test", "branch" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_subcommand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
    try std.testing.expectEqualStrings("branch", diagnostic.raw_arg.?);
    try std.testing.expectEqualStrings("branch", diagnostic.value.?);
}

test "subcommand: child diagnostics preserve root argv coordinates" {
    const Cli = Command(.{
        .name = "git",
        .args = .{},
        .subcommands = .{
            .remote = Command(.{
                .name = "remote",
                .args = .{},
            }),
        },
    });

    const argv = [_][]const u8{ "git", "remote", "--bad" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 2), diagnostic.argv_index);
    try std.testing.expectEqualStrings("--bad", diagnostic.raw_arg.?);
}

test "subcommand: nested child diagnostics preserve root argv coordinates" {
    const Cli = Command(.{
        .name = "git",
        .args = .{},
        .subcommands = .{
            .remote = Command(.{
                .name = "remote",
                .args = .{},
                .subcommands = .{
                    .add = Command(.{
                        .name = "add",
                        .args = .{},
                    }),
                },
            }),
        },
    });

    const argv = [_][]const u8{ "git", "remote", "add", "--bad" };
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 3), diagnostic.argv_index);
    try std.testing.expectEqualStrings("--bad", diagnostic.raw_arg.?);
}

test "integration: declarative command parses typed result" {
    const Mode = enum { fast, safe };
    const Cli = Command(.{
        .name = "copy",
        .about = "Copy one file",
        .version = test_version_metadata,
        .args = .{
            .verbose = flag(.{
                .short = 'v',
                .long = "verbose",
            }),
            .output = option([]const u8, .{
                .short = 'o',
                .long = "output",
                .value_name = "PATH",
                .required = true,
            }),
            .mode = option(Mode, .{
                .long = "mode",
                .default = .safe,
            }),
            .source = operand([]const u8, .{
                .required = true,
            }),
        },
    });

    const argv = [_][]const u8{ "test", "input.txt", "-v", "--output=out.txt", "--mode", "fast" };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| {
            try std.testing.expect(result.verbose);
            try std.testing.expectEqualStrings("out.txt", result.output);
            try std.testing.expectEqual(Mode.fast, result.mode);
            try std.testing.expectEqualStrings("input.txt", result.source);
        },
        else => return error.ExpectedParsedResult,
    }
}

test "integration: optimized parser keeps existing GNU-style permutation behavior" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .all = flag(.{
                .short = 'a',
            }),
            .binary = flag(.{
                .short = 'b',
            }),
            .verbose = flag(.{
                .short = 'v',
                .action = .count,
            }),
            .output = option([]const u8, .{
                .long = "output",
                .required = true,
            }),
            .include = option([]const u8, .{
                .short = 'I',
                .long = "include",
                .action = .append,
            }),
            .paths = operand([]const u8, .{
                .action = .append,
            }),
        },
    });

    const argv = [_][]const u8{
        "copy",
        "src1",
        "-abv",
        "--output=out",
        "--include",
        "inc1",
        "src2",
        "--include=inc2",
        "--",
        "--literal",
        "-x",
    };
    var parse_result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &parse_result);

    switch (parse_result) {
        .parsed => |result| {
            try std.testing.expect(result.all);
            try std.testing.expect(result.binary);
            try std.testing.expectEqual(@as(u32, 1), result.verbose);
            try std.testing.expectEqualStrings("out", result.output);

            try std.testing.expectEqual(@as(usize, 2), result.include.len);
            try std.testing.expectEqualStrings("inc1", result.include[0]);
            try std.testing.expectEqualStrings("inc2", result.include[1]);

            try std.testing.expectEqual(@as(usize, 4), result.paths.len);
            try std.testing.expectEqualStrings("src1", result.paths[0]);
            try std.testing.expectEqualStrings("src2", result.paths[1]);
            try std.testing.expectEqualStrings("--literal", result.paths[2]);
            try std.testing.expectEqualStrings("-x", result.paths[3]);
        },
        else => return error.ExpectedParsedResult,
    }
}

fn parseTestResult(
    comptime Cli: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: ParseOptions,
) !Cli.Parsed {
    const process_argv = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(process_argv);

    process_argv[0] = "test";
    @memcpy(process_argv[1..], argv);

    const parse_result = try Cli.parse(allocator, process_argv, options);
    return switch (parse_result) {
        .parsed => |result| result,
        else => return error.ExpectedParsedResult,
    };
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    remap_count: usize = 0,

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn context(ptr: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = context(ptr);
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return context(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = context(ptr);
        const new_memory = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.remap_count += 1;
        return new_memory;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = context(ptr);
        self.free_count += 1;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn expectOperandToken(token: tokenizer.Token, expected_argv_index: usize, expected_raw: []const u8) !void {
    switch (token) {
        .operand => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
        },
        else => return error.ExpectedOperandToken,
    }
}

fn expectEndOfOptionsToken(token: tokenizer.Token, expected_argv_index: usize, expected_raw: []const u8) !void {
    switch (token) {
        .end_of_options => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
        },
        else => return error.ExpectedEndOfOptionsToken,
    }
}

fn expectLongOptionToken(
    token: tokenizer.Token,
    expected_argv_index: usize,
    expected_raw: []const u8,
    expected_name: []const u8,
    expected_inline_value: ?[]const u8,
) !void {
    switch (token) {
        .long_option => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
            try std.testing.expectEqualStrings(expected_name, payload.name);

            if (expected_inline_value) |expected| {
                try std.testing.expect(payload.inline_value != null);
                try std.testing.expectEqualStrings(expected, payload.inline_value.?);
            } else {
                try std.testing.expect(payload.inline_value == null);
            }
        },
        else => return error.ExpectedLongOptionToken,
    }
}

fn expectShortOptionToken(
    token: tokenizer.Token,
    expected_argv_index: usize,
    expected_raw: []const u8,
    expected_ch: u8,
    expected_rest: []const u8,
) !void {
    switch (token) {
        .short_option => |payload| {
            try std.testing.expectEqual(expected_argv_index, payload.argv_index);
            try std.testing.expectEqualStrings(expected_raw, payload.raw);
            try std.testing.expectEqual(expected_ch, payload.ch);
            try std.testing.expectEqualStrings(expected_rest, payload.rest);
        },
        else => return error.ExpectedShortOptionToken,
    }
}
