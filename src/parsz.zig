const std = @import("std");

const schema = @import("schema.zig");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const diagnostics = @import("diagnostic.zig");

pub const ParseError = diagnostics.ParseError;
pub const ParseErrorKind = diagnostics.ParseErrorKind;
pub const Diagnostic = diagnostics.Diagnostic;
pub const ParseOptions = diagnostics.ParseOptions;
pub const Action = schema.Action;

pub const flag = schema.flag;
pub const option = schema.option;
pub const operand = schema.operand;

pub fn Command(comptime declaration: anytype) type {
    schema.validateCommandDeclaration(declaration);

    const args = declaration.args;
    const result_type = schema.buildResultType(args);

    return struct {
        pub const name = declaration.name;
        pub const Result = result_type;

        pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8, options: ParseOptions) ParseError!Result {
            var result: Result = undefined;
            schema.initializeResultDefaults(args, &result);
            errdefer deinit(allocator, &result);

            const matches = try parser.parseMatches(args, allocator, argv, options);
            defer allocator.free(matches);

            try semantic.applyMatches(args, allocator, matches, &result, options);
            try semantic.validateRequiredMatches(args, matches, options);
            return result;
        }

        pub fn deinit(allocator: std.mem.Allocator, result: *Result) void {
            schema.deinitResult(args, allocator, result);
        }
    };
}

test "schema: accepts empty command definition" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    try std.testing.expectEqual(@as(usize, 0), @typeInfo(Cli.Result).@"struct".fields.len);

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

    try std.testing.expect(@FieldType(Cli.Result, "verbose") == bool);

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    try std.testing.expect(@FieldType(Cli.Result, "verbose") == bool);
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

    const fields = @typeInfo(Cli.Result).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("verbose", fields[0].name);
}

test "schema: maps actions and required/default settings to result field types" {
    const Cli = Command(.{
        .name = "copy",
        .args = .{
            .debug = flag(.{}),
            .verbose = flag(.{
                .action = .count,
            }),
            .output = option([]const u8, .{
                .required = true,
            }),
            .color = option([]const u8, .{}),
            .port = option(u16, .{
                .default = 80,
            }),
            .include = option([]const u8, .{
                .action = .append,
            }),
        },
    });

    try std.testing.expect(@FieldType(Cli.Result, "debug") == bool);
    try std.testing.expect(@FieldType(Cli.Result, "verbose") == u32);
    try std.testing.expect(@FieldType(Cli.Result, "output") == []const u8);
    try std.testing.expect(@FieldType(Cli.Result, "color") == ?[]const u8);
    try std.testing.expect(@FieldType(Cli.Result, "port") == u16);
    try std.testing.expect(@FieldType(Cli.Result, "include") == []const []const u8);
}

test "runtime api: parses borrowed argv slices without argv zero" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .long = "verbose",
            }),
        },
    });

    const process_argv = [_][]const u8{"app"};
    const user_args = process_argv[1..];

    var result = try Cli.parse(std.testing.allocator, user_args, .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expect(!result.verbose);
}

test "runtime api: reports diagnostics through parse options" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"extra"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqualStrings("extra", diagnostic.raw_arg.?);
}

test "runtime api: reports missing required flag without input" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
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
                .action = .append,
                .required = true,
            }),
        },
    });

    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.missing_required, diagnostic.kind);
    try std.testing.expectEqualStrings("include", diagnostic.arg_name.?);
}

test "runtime api: exposes result deinit as no-op for borrowed-only schemas" {
    const Cli = Command(.{
        .name = "app",
        .args = .{
            .verbose = flag(.{}),
        },
    });

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    Cli.deinit(std.testing.allocator, &result);
}

test "tokenizer: treats empty argv as empty token stream" {
    const tokens = try tokenizer.tokenize(std.testing.allocator, &.{});
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "tokenizer: classifies operands" {
    const argv = [_][]const u8{"file.txt"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectOperandToken(tokens[0], 0, "file.txt");
}

test "tokenizer: classifies end of options marker" {
    const argv = [_][]const u8{"--"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectEndOfOptionsToken(tokens[0], 0, "--");
}

test "tokenizer: does not force tokens after end marker to operands" {
    const argv = [_][]const u8{ "--", "--verbose" };
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try expectEndOfOptionsToken(tokens[0], 0, "--");
    try expectLongOptionToken(tokens[1], 1, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option without value" {
    const argv = [_][]const u8{"--verbose"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--verbose", "verbose", null);
}

test "tokenizer: classifies long option with inline value" {
    const argv = [_][]const u8{"--output=path"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--output=path", "output", "path");
}

test "tokenizer: preserves empty long inline value" {
    const argv = [_][]const u8{"--output="};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectLongOptionToken(tokens[0], 0, "--output=", "output", "");
}

test "tokenizer: classifies single hyphen as operand" {
    const argv = [_][]const u8{"-"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectOperandToken(tokens[0], 0, "-");
}

test "tokenizer: preserves short option suffix" {
    const argv = [_][]const u8{"-abc"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectShortOptionToken(tokens[0], 0, "-abc", 'a', "bc");
}

test "tokenizer: preserves attached short value candidate" {
    const argv = [_][]const u8{"-Iinclude"};
    const tokens = try tokenizer.tokenize(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try expectShortOptionToken(tokens[0], 0, "-Iinclude", 'I', "include");
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &result);

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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{
        .abbreviate_long_options = true,
    });
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    try std.testing.expectEqualStrings("a", result.include[0]);
    try std.testing.expectEqualStrings("b", result.include[1]);
}

test "parser: reports unknown long option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"--missing"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
    try std.testing.expectEqualStrings("--missing", diagnostic.raw_arg.?);
}

test "parser: reports unknown short option with diagnostic" {
    const Cli = Command(.{
        .name = "app",
        .args = .{},
    });

    const argv = [_][]const u8{"-x"};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unknown_option, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 0), diagnostic.argv_index);
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, &.{}, .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.unexpected_operand, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    var result = try Cli.parse(std.testing.allocator, &.{}, .{});
    defer Cli.deinit(std.testing.allocator, &result);

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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    const argv = [_][]const u8{ "-I", "a", "-I", "b" };
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});

    try std.testing.expectEqual(@as(usize, 2), result.include.len);
    Cli.deinit(std.testing.allocator, &result);
    try std.testing.expectEqual(@as(usize, 0), result.include.len);
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
    const matches = [_]parser.Match{.{
        .arg_index = 0,
        .raw_value = null,
        .argv_index = 0,
        .raw_arg = "-v",
        .cluster_offset = 1,
    }};
    var diagnostic: Diagnostic = undefined;

    try std.testing.expectError(error.ParseFailed, semantic.applyMatches(args, std.testing.allocator, matches[0..], &result, .{
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.overflow, diagnostic.kind);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.argv_index);
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
    var result = try Cli.parse(std.testing.allocator, argv[0..], .{});
    defer Cli.deinit(std.testing.allocator, &result);

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

    try std.testing.expectError(error.ParseFailed, Cli.parse(std.testing.allocator, argv[0..], .{
        .diagnostic = &diagnostic,
    }));

    try std.testing.expectEqual(ParseErrorKind.invalid_value, diagnostic.kind);
    try std.testing.expectEqualStrings("mode", diagnostic.arg_name.?);
    try std.testing.expectEqualStrings("quick", diagnostic.value.?);
}

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
