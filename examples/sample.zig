const std = @import("std");
const parsz = @import("parsz");

const Cli = struct {
    verbose: bool = false,
    output: []const u8 = "out.txt",
    count: u32 = 1,
    input: []const u8,
};

const config = .{
    ._meta = .{ .name = "sample", .about = "A sample CLI application" },
    .verbose = .{ .short = 'v', .help = "Enable verbose output" },
    .output = .{ .short = 'o', .help = "Output file path", .value_name = "PATH" },
    .count = .{ .help = "Repeat count", .value_name = "COUNT" },
    .input = .{ .positional = true, .help = "Input file" },
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parsz.parse(Cli, allocator, argv[1..], config, null) catch |err| switch (err) {
        error.HelpRequested => {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            parsz.help(Cli, config, stdout) catch {};
            std.process.exit(0);
        },
        else => {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    std.debug.print("verbose: {}\n", .{cli.verbose});
    std.debug.print("output:  {s}\n", .{cli.output});
    std.debug.print("count:   {}\n", .{cli.count});
    std.debug.print("input:   {s}\n", .{cli.input});
}
