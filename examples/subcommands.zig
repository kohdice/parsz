const std = @import("std");
const parsz = @import("parsz");

const RemoteAdd = parsz.Command(.{
    .name = "add",
    .about = "Add a named remote",
    .args = .{
        .fetch = parsz.flag(.{
            .short = 'f',
            .long = "fetch",
            .help = "Fetch from the remote after adding it",
        }),
        .name = parsz.operand([]const u8, .{
            .value_name = "NAME",
            .required = true,
            .help = "Remote name",
        }),
        .url = parsz.operand([]const u8, .{
            .value_name = "URL",
            .required = true,
            .help = "Remote URL",
        }),
    },
});

const RemoteRemove = parsz.Command(.{
    .name = "remove",
    .about = "Remove a named remote",
    .args = .{
        .name = parsz.operand([]const u8, .{
            .value_name = "NAME",
            .required = true,
            .help = "Remote name",
        }),
    },
});

const Remote = parsz.Command(.{
    .name = "remote",
    .about = "Manage remote repositories",
    .args = .{
        .verbose = parsz.flag(.{
            .short = 'v',
            .long = "verbose",
            .action = .count,
            .help = "Print more remote command details",
        }),
    },
    .subcommands = .{
        .add = RemoteAdd,
        .remove = RemoteRemove,
    },
});

const Status = parsz.Command(.{
    .name = "status",
    .about = "Show working tree status",
    .args = .{
        .short = parsz.flag(.{
            .short = 's',
            .long = "short",
            .help = "Print status in short format",
        }),
    },
});

const Cli = parsz.Command(.{
    .name = "mini-git",
    .about = "Demonstrate nested subcommand parsing",
    .version = parsz.version(.{ .number = "1.2.3", .details =
        \\Copyright (C) 2026 parsz contributors
        \\License MIT: MIT License <https://opensource.org/licenses/MIT>
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
    }),
    .args = .{
        .verbose = parsz.flag(.{
            .short = 'v',
            .long = "verbose",
            .action = .count,
            .help = "Print more top-level details",
        }),
        .work_tree = parsz.option([]const u8, .{
            .long = "work-tree",
            .value_name = "PATH",
            .help = "Use PATH as the working tree",
        }),
    },
    .subcommands = .{
        .remote = Remote,
        .status = Status,
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
        .parsed => |result| try printRootOnly(stdout, result),
        .help => {
            const text = try Cli.renderHelp(init.arena.allocator());
            try stdout.writeAll(text);
        },
        .version => {
            const text = try Cli.renderVersion(init.arena.allocator());
            try stdout.writeAll(text);
        },
        .subcommand => |node| switch (node.command) {
            .remote => |remote_result| try printRemote(init, stdout, node.parsed, remote_result),
            .status => |status_result| try printStatus(init, stdout, node.parsed, status_result),
        },
    }

    try stdout.flush();
}

fn printRootOnly(writer: *std.Io.Writer, result: Cli.Parsed) !void {
    try printRootOptions(writer, result);
    try writer.writeAll("command=(none)\n");
}

fn printRootOptions(writer: *std.Io.Writer, result: Cli.Parsed) !void {
    try writer.print(
        \\top_verbose={d}
        \\work_tree={s}
        \\
    , .{
        result.verbose,
        result.work_tree orelse "(current)",
    });
}

fn printRemote(init: std.process.Init, writer: *std.Io.Writer, root: Cli.Parsed, result: Remote.Result) !void {
    switch (result) {
        .parsed => |parsed| {
            try printRootOptions(writer, root);
            try writer.print(
                \\command=remote
                \\remote_verbose={d}
                \\
            , .{parsed.verbose});
        },
        .help => {
            const text = try Remote.renderHelp(init.arena.allocator());
            try writer.writeAll(text);
        },
        .version => unreachable,
        .subcommand => |node| switch (node.command) {
            .add => |add_result| try printRemoteAdd(init, writer, root, node.parsed, add_result),
            .remove => |remove_result| try printRemoteRemove(init, writer, root, node.parsed, remove_result),
        },
    }
}

fn printRemoteAdd(
    init: std.process.Init,
    writer: *std.Io.Writer,
    root: Cli.Parsed,
    remote: Remote.Parsed,
    result: RemoteAdd.Result,
) !void {
    switch (result) {
        .parsed => |parsed| {
            try printRootOptions(writer, root);
            try writer.print(
                \\remote_verbose={d}
                \\command=remote add
                \\fetch={}
                \\name={s}
                \\url={s}
                \\
            , .{
                remote.verbose,
                parsed.fetch,
                parsed.name,
                parsed.url,
            });
        },
        .help => {
            const text = try RemoteAdd.renderHelp(init.arena.allocator());
            try writer.writeAll(text);
        },
        .version => unreachable,
    }
}

fn printRemoteRemove(
    init: std.process.Init,
    writer: *std.Io.Writer,
    root: Cli.Parsed,
    remote: Remote.Parsed,
    result: RemoteRemove.Result,
) !void {
    switch (result) {
        .parsed => |parsed| {
            try printRootOptions(writer, root);
            try writer.print(
                \\remote_verbose={d}
                \\command=remote remove
                \\name={s}
                \\
            , .{
                remote.verbose,
                parsed.name,
            });
        },
        .help => {
            const text = try RemoteRemove.renderHelp(init.arena.allocator());
            try writer.writeAll(text);
        },
        .version => unreachable,
    }
}

fn printStatus(init: std.process.Init, writer: *std.Io.Writer, root: Cli.Parsed, result: Status.Result) !void {
    switch (result) {
        .parsed => |parsed| {
            try printRootOptions(writer, root);
            try writer.print(
                \\command=status
                \\short={}
                \\
            , .{parsed.short});
        },
        .help => {
            const text = try Status.renderHelp(init.arena.allocator());
            try writer.writeAll(text);
        },
        .version => unreachable,
    }
}
