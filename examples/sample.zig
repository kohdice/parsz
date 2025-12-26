const std = @import("std");
const parsz = @import("parsz");

pub fn main() void {
    const cmd = parsz.Command{
        .name = "sample",
        .about = "A sample CLI application",
        .args = &.{
            .{
                .name = "help",
                .kind = .flag,
                .short = 'h',
                .long = "help",
                .value_type = .boolean,
                .help = "Show help message",
            },
            .{
                .name = "output",
                .kind = .option,
                .short = 'o',
                .long = "output",
                .value_type = .string,
                .help = "Output file path",
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Failed to allocate args\n", .{});
        return;
    };
    defer std.process.argsFree(allocator, args);

    // Skip program name (args[0])
    const argv = if (args.len > 0) args[1..] else args[0..0];

    parsz.parse(allocator, argv, cmd);

    std.debug.print("Parsing complete (implementation pending)\n", .{});
}
