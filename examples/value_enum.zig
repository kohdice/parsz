const std = @import("std");
const parsz = @import("parsz");

const Mode = enum {
    fast,
    slow,
    balanced,
};

const Cli = struct {
    mode: Mode = .balanced,
    verbose: bool = false,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parsz.parse(Cli, allocator, argv[1..], .{
        .verbose = .{ .short = 'v' },
    }, null) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.debug.print("mode:    {s}\n", .{@tagName(cli.mode)});
    std.debug.print("verbose: {}\n", .{cli.verbose});
}
