const std = @import("std");
const parsz = @import("parsz");

const Clone = struct {
    remote: []const u8,
    depth: ?u32 = null,
};

const Push = struct {
    force: bool = false,
    remote: []const u8 = "origin",
};

const Command = union(enum) {
    clone: Clone,
    push: Push,
};

const Cli = struct {
    verbose: bool = false,
    command: ?Command = null,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parsz.parse(Cli, allocator, argv[1..], .{
        .verbose = .{ .short = 'v' },
        .command = .{
            .clone = .{
                .remote = .{ .positional = true },
            },
            .push = .{
                .force = .{ .short = 'f' },
            },
        },
    }, null) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.debug.print("verbose: {}\n", .{cli.verbose});

    if (cli.command) |cmd| {
        switch (cmd) {
            .clone => |c| {
                std.debug.print("clone remote: {s}\n", .{c.remote});
                if (c.depth) |d| {
                    std.debug.print("clone depth:  {}\n", .{d});
                }
            },
            .push => |p| {
                std.debug.print("push force:  {}\n", .{p.force});
                std.debug.print("push remote: {s}\n", .{p.remote});
            },
        }
    } else {
        std.debug.print("no subcommand\n", .{});
    }
}
