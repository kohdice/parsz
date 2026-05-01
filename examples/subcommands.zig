const std = @import("std");
const parsz = @import("parsz");

const Add = parsz.Command(.{
    .name = "add",
    .about = "Add two numbers",
    .args = .{
        .left = parsz.operand(i64, .{
            .value_name = "LEFT",
            .required = true,
            .help = "Left-hand number",
        }),
        .right = parsz.operand(i64, .{
            .value_name = "RIGHT",
            .required = true,
            .help = "Right-hand number",
        }),
    },
});

const Repeat = parsz.Command(.{
    .name = "repeat",
    .about = "Print a word more than once",
    .args = .{
        .count = parsz.option(u8, .{
            .short = 'n',
            .long = "count",
            .value_name = "N",
            .default = 2,
            .help = "Number of times to print the word",
        }),
        .word = parsz.operand([]const u8, .{
            .value_name = "WORD",
            .required = true,
            .help = "Word to print",
        }),
    },
});

const Cli = parsz.Command(.{
    .name = "toolbox",
    .about = "Demonstrate simple subcommand parsing",
    .version = parsz.version(.{ .number = "0.1.0", .details =
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
    }),
    .args = .{},
    .subcommands = .{
        .add = Add,
        .repeat = Repeat,
    },
});

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var args = try Cli.parse(init.arena.allocator(), argv, .{});
    defer Cli.deinit(init.arena.allocator(), &args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    switch (args) {
        .parsed => try Cli.writeHelp(stdout),
        .help => try Cli.writeHelp(stdout),
        .version => try Cli.writeVersion(stdout),
        .subcommand => |node| switch (node.command) {
            .add => |add_result| switch (add_result) {
                .parsed => |result| try stdout.print("{d}\n", .{result.left + result.right}),
                .help => try Add.writeHelp(stdout),
            },
            .repeat => |repeat_result| switch (repeat_result) {
                .parsed => |result| {
                    for (0..result.count) |_| {
                        try stdout.print("{s}\n", .{result.word});
                    }
                },
                .help => try Repeat.writeHelp(stdout),
            },
        },
    }

    try stdout.flush();
}
