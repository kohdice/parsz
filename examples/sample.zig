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
        error.UnknownFlag,
        error.MissingValue,
        error.MissingRequired,
        error.InvalidValue,
        error.ValueOutOfRange,
        error.TooManyPositionals,
        error.DuplicateArg,
        => {
            if (diagnostic.flag_name.len > 0 and diagnostic.arg_name.len > 0) {
                // Known option/flag: determine the label by matching against the definition
                const label: []const u8 = label: {
                    inline for (cmd.args) |arg| {
                        if (std.mem.eql(u8, arg.name, diagnostic.arg_name)) {
                            break :label if (arg.kind == .flag) "flag" else "option";
                        }
                    }
                    break :label "option";
                };
                std.debug.print("Error: {s} '{s}': {s}", .{ label, diagnostic.flag_name, @errorName(err) });
                if (diagnostic.provided_value.len > 0) {
                    std.debug.print(" (got '{s}')", .{diagnostic.provided_value});
                }
                std.debug.print("\n", .{});
            } else if (diagnostic.arg_name.len > 0) {
                // Positional argument error (no flag_name)
                std.debug.print("Error: argument '{s}': {s}", .{ diagnostic.arg_name, @errorName(err) });
                if (diagnostic.provided_value.len > 0) {
                    std.debug.print(" (got '{s}')", .{diagnostic.provided_value});
                }
                std.debug.print("\n", .{});
            } else if (diagnostic.flag_name.len > 0) {
                // Unknown flag (no arg_name, only flag_name)
                std.debug.print("Error: unknown flag '{s}'\n", .{diagnostic.flag_name});
            } else {
                // Fallback (e.g., TooManyPositionals with no positional definitions)
                std.debug.print("Parse error: {s}", .{@errorName(err)});
                if (diagnostic.provided_value.len > 0) {
                    std.debug.print(" (got '{s}')", .{diagnostic.provided_value});
                }
                std.debug.print("\n", .{});
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
