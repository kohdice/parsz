const std = @import("std");
const parsz = @import("parsz");

// Nested subcommand: models `git remote add/remove` and `git stash list/pop`.

const RemoteAdd = struct {
    name: []const u8,
    url: []const u8,
};

const RemoteRemove = struct {
    name: []const u8,
};

const RemoteCommand = union(enum) {
    add: RemoteAdd,
    remove: RemoteRemove,
};

const StashList = struct {
    all: bool = false,
};

const StashPop = struct {
    index: u32 = 0,
};

const StashCommand = union(enum) {
    list: StashList,
    pop: StashPop,
};

const Command = union(enum) {
    remote: struct { command: RemoteCommand },
    stash: struct { command: StashCommand },
    clone: struct { url: []const u8 },
};

const Cli = struct {
    verbose: bool = false,
    command: Command,
};

const config = .{
    .verbose = .{ .short = 'v' },
    .command = .{
        .remote = .{
            .command = .{
                .add = .{
                    .name = .{ .positional = true },
                    .url = .{ .positional = true },
                },
                .remove = .{
                    .name = .{ .positional = true },
                },
            },
        },
        .stash = .{
            .command = .{
                .list = .{
                    .all = .{ .short = 'a' },
                },
            },
        },
        .clone = .{
            .url = .{ .positional = true },
        },
    },
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parsz.parse(Cli, allocator, argv[1..], config, null) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.debug.print("verbose: {}\n", .{cli.verbose});

    switch (cli.command) {
        .remote => |r| switch (r.command) {
            .add => |a| std.debug.print("remote add: name={s} url={s}\n", .{ a.name, a.url }),
            .remove => |rm| std.debug.print("remote remove: name={s}\n", .{rm.name}),
        },
        .stash => |s| switch (s.command) {
            .list => |l| std.debug.print("stash list: all={}\n", .{l.all}),
            .pop => |p| std.debug.print("stash pop: index={}\n", .{p.index}),
        },
        .clone => |c| std.debug.print("clone: url={s}\n", .{c.url}),
    }
}
