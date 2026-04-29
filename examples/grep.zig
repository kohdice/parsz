const std = @import("std");
const parsz = @import("parsz");

const ColorMode = enum {
    never,
    auto,
    always,
};

const Cli = parsz.Command(.{
    .name = "grep",
    .about = "Search input files for lines that match a pattern",
    .version = parsz.version(.{ .number = "1.2.3", .details =
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
    }),
    .args = .{
        .ignore_case = parsz.flag(.{
            .short = 'i',
            .long = "ignore-case",
            .help = "Ignore case distinctions in patterns and input",
        }),
        .invert_match = parsz.flag(.{
            .short = 'v',
            .long = "invert-match",
            .help = "Select non-matching lines",
        }),
        .line_number = parsz.flag(.{
            .short = 'n',
            .long = "line-number",
            .help = "Print line numbers with output lines",
        }),
        .count = parsz.flag(.{
            .short = 'c',
            .long = "count",
            .help = "Print only a count of matching lines per file",
        }),
        .context = parsz.option(u8, .{
            .short = 'C',
            .long = "context",
            .value_name = "NUM",
            .default = 0,
            .help = "Print NUM lines of leading and trailing context",
        }),
        .color = parsz.option(ColorMode, .{
            .long = "color",
            .value_name = "WHEN",
            .default = .auto,
            .help = "Color matches: never, auto, or always",
        }),
        .include = parsz.option([]const u8, .{
            .long = "include",
            .value_name = "GLOB",
            .action = .append,
            .help = "Search only files whose base name matches GLOB",
        }),
        .pattern = parsz.operand([]const u8, .{
            .value_name = "PATTERN",
            .required = true,
            .help = "Pattern to search for",
        }),
        .path = parsz.operand([]const u8, .{
            .value_name = "PATH",
            .action = .append,
            .help = "File or directory to search",
        }),
    },
});

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const user_args = if (argv.len > 0) argv[1..] else argv[0..0];

    var args = try Cli.parse(init.arena.allocator(), user_args, .{});
    defer Cli.deinit(init.arena.allocator(), &args);

    switch (args) {
        .parsed => |result| {
            const stdout = std.Io.File.stdout();
            const summary = try std.fmt.allocPrint(init.arena.allocator(),
                \\pattern={s}
                \\ignore_case={}
                \\invert_match={}
                \\line_number={}
                \\count={}
                \\context={d}
                \\color={s}
                \\
            , .{
                result.pattern,
                result.ignore_case,
                result.invert_match,
                result.line_number,
                result.count,
                result.context,
                @tagName(result.color),
            });
            try stdout.writeStreamingAll(init.io, summary);

            if (result.include.len == 0) {
                try stdout.writeStreamingAll(init.io, "include=(none)\n");
            } else {
                for (result.include) |glob| {
                    const line = try std.fmt.allocPrint(init.arena.allocator(), "include={s}\n", .{glob});
                    try stdout.writeStreamingAll(init.io, line);
                }
            }

            if (result.path.len == 0) {
                try stdout.writeStreamingAll(init.io, "path=(stdin)\n");
            } else {
                for (result.path) |path| {
                    const line = try std.fmt.allocPrint(init.arena.allocator(), "path={s}\n", .{path});
                    try stdout.writeStreamingAll(init.io, line);
                }
            }
        },
        .help => {
            const text = try Cli.renderHelp(init.arena.allocator());
            try std.Io.File.stdout().writeStreamingAll(init.io, text);
        },
        .version => {
            const text = try Cli.renderVersion(init.arena.allocator());
            try std.Io.File.stdout().writeStreamingAll(init.io, text);
        },
    }
}
