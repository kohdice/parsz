const std = @import("std");
const parsz = @import("parsz");

const Cli = parsz.Command(.{
    .name = "greet",
    .about = "Print a friendly greeting",
    .version = parsz.version(.{ .number = "0.1.0", .details =
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
    }),
    .args = .{
        .shout = parsz.flag(.{
            .short = 's',
            .long = "shout",
            .help = "Print the greeting in uppercase",
        }),
        .greeting = parsz.option([]const u8, .{
            .short = 'g',
            .long = "greeting",
            .value_name = "WORD",
            .default = "Hello",
            .help = "Word used to open the greeting",
        }),
        .name = parsz.operand([]const u8, .{
            .value_name = "NAME",
            .required = true,
            .help = "Person to greet",
        }),
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
        .parsed => |result| {
            if (result.shout) {
                const line = try std.fmt.allocPrint(
                    init.arena.allocator(),
                    "{s}, {s}!\n",
                    .{ result.greeting, result.name },
                );
                _ = std.ascii.upperString(line, line);
                try stdout.writeAll(line);
            } else {
                try stdout.print("{s}, {s}!\n", .{ result.greeting, result.name });
            }
        },
        .help => {
            const text = try Cli.renderHelp(init.arena.allocator());
            try stdout.writeAll(text);
        },
        .version => {
            const text = try Cli.renderVersion(init.arena.allocator());
            try stdout.writeAll(text);
        },
    }

    try stdout.flush();
}
