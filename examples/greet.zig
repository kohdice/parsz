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
                try writeAsciiUpper(stdout, result.greeting);
                try stdout.writeAll(", ");
                try writeAsciiUpper(stdout, result.name);
                try stdout.writeAll("!\n");
            } else {
                try stdout.print("{s}, {s}!\n", .{ result.greeting, result.name });
            }
        },
        .help => try Cli.writeHelp(stdout),
        .version => try Cli.writeVersion(stdout),
    }

    try stdout.flush();
}

fn writeAsciiUpper(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    var remaining = bytes;

    while (remaining.len > 0) {
        const chunk_len = @min(buffer.len, remaining.len);
        const chunk = std.ascii.upperString(&buffer, remaining[0..chunk_len]);
        try writer.writeAll(chunk);
        remaining = remaining[chunk_len..];
    }
}
