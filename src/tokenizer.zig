const std = @import("std");

pub const Token = union(enum) {
    long_option: struct {
        argv_index: usize,
        raw: []const u8,
        name: []const u8,
        inline_value: ?[]const u8,
    },
    short_option: struct {
        argv_index: usize,
        raw: []const u8,
        ch: u8,
        rest: []const u8,
    },
    end_of_options: struct {
        argv_index: usize,
        raw: []const u8,
    },
    operand: struct {
        argv_index: usize,
        raw: []const u8,
    },
};

pub fn tokenize(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    argv_index_base: usize,
) std.mem.Allocator.Error![]Token {
    const tokens = try allocator.alloc(Token, argv.len);

    for (argv, 0..) |raw, argv_index| {
        tokens[argv_index] = tokenizeArg(argv_index_base + argv_index, raw);
    }

    return tokens;
}

fn tokenizeArg(argv_index: usize, raw: []const u8) Token {
    if (std.mem.eql(u8, raw, "--")) {
        return .{
            .end_of_options = .{
                .argv_index = argv_index,
                .raw = raw,
            },
        };
    }

    if (std.mem.startsWith(u8, raw, "--")) {
        const option_text = raw[2..];
        if (std.mem.cutScalar(u8, option_text, '=')) |parts| {
            const name, const inline_value = parts;
            return .{
                .long_option = .{
                    .argv_index = argv_index,
                    .raw = raw,
                    .name = name,
                    .inline_value = inline_value,
                },
            };
        }

        return .{
            .long_option = .{
                .argv_index = argv_index,
                .raw = raw,
                .name = option_text,
                .inline_value = null,
            },
        };
    }

    if (raw.len > 1 and raw[0] == '-') {
        return .{
            .short_option = .{
                .argv_index = argv_index,
                .raw = raw,
                .ch = raw[1],
                .rest = raw[2..],
            },
        };
    }

    return .{
        .operand = .{
            .argv_index = argv_index,
            .raw = raw,
        },
    };
}
