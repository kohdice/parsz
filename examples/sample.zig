const std = @import("std");
const parsz = @import("parsz");

const cmd = parsz.Command{
    .name = "sample",
    .about = "A sample CLI application",
    .args = &.{
        .{
            .name = "verbose",
            .kind = .flag,
            .short = 'v',
            .long = "verbose",
            .value_type = .boolean,
            .help = "Enable verbose output",
        },
        .{
            .name = "output",
            .kind = .option,
            .short = 'o',
            .long = "output",
            .value_type = .string,
            .default = "out.txt",
            .help = "Output file path",
        },
        .{
            .name = "count",
            .kind = .option,
            .value_type = .integer,
            .long = "count",
            .default = "1",
            .help = "Repeat count",
        },
        .{
            .name = "input",
            .kind = .positional,
            .value_type = .string,
            .required = true,
            .help = "Input file",
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak detected");
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name (args[0])
    const argv: []const [:0]const u8 = if (args.len > 0) args[1..] else args[0..0];

    var diagnostic: parsz.Diagnostic = .{};
    var result = parsz.parse(allocator, argv, cmd, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diagnostic.arg_name.len > 0) {
                std.debug.print("Error: argument '{s}': {s}", .{ diagnostic.arg_name, @errorName(err) });
                if (diagnostic.provided_value.len > 0) {
                    std.debug.print(" (got '{s}')", .{diagnostic.provided_value});
                }
                std.debug.print("\n", .{});
            } else if (diagnostic.flag_name.len > 0) {
                std.debug.print("Error: unknown flag '{s}'\n", .{diagnostic.flag_name});
            } else {
                std.debug.print("Parse error: {s}\n", .{@errorName(err)});
            }
            std.process.exit(1);
        },
    };
    defer parsz.deinit(cmd, &result, allocator);

    std.debug.print("verbose: {}\n", .{result.verbose});
    std.debug.print("output:  {s}\n", .{result.output});
    std.debug.print("count:   {d}\n", .{result.count});
    std.debug.print("input:   {s}\n", .{result.input});
}
