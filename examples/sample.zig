const std = @import("std");
const parsz = @import("parsz");

const Cli = struct {
    verbose: bool = false,
    output: []const u8 = "out.txt",
    count: u32 = 1,
    input: []const u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const cli = parsz.parse(Cli, allocator, argv[1..], .{
        .verbose = .{ .short = 'v', .help = "Enable verbose output" },
        .output = .{ .short = 'o', .help = "Output file path" },
        .count = .{ .help = "Repeat count" },
        .input = .{ .positional = true, .help = "Input file" },
    }) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    std.debug.print("verbose: {}\n", .{cli.verbose});
    std.debug.print("output:  {s}\n", .{cli.output});
    std.debug.print("count:   {}\n", .{cli.count});
    std.debug.print("input:   {s}\n", .{cli.input});
}
