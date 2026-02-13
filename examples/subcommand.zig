const std = @import("std");
const parsz = @import("parsz");

/// Git-style CLI command definition with subcommands.
///
/// Usage:
///   myapp [--verbose] <subcommand>
///
/// Subcommands:
///   init <name>                   Initialize a new project
///   build [--release] [--jobs=N]  Build the project
const cmd = parsz.Command{
    .name = "myapp",
    .about = "A sample CLI application demonstrating subcommand support",
    .args = &.{
        .{
            .name = "verbose",
            .kind = .flag,
            .short = 'v',
            .long = "verbose",
            .value_type = .boolean,
            .help = "Enable verbose output",
        },
    },
    .subcommands = &.{
        .{
            .name = "init",
            .about = "Initialize a new project",
            .args = &.{
                .{
                    .name = "name",
                    .kind = .positional,
                    .value_type = .string,
                    .required = true,
                    .help = "Project name",
                },
            },
        },
        .{
            .name = "build",
            .about = "Build the project",
            .args = &.{
                .{
                    .name = "release",
                    .kind = .flag,
                    .long = "release",
                    .value_type = .boolean,
                    .help = "Build in release mode",
                },
                .{
                    .name = "jobs",
                    .kind = .option,
                    .short = 'j',
                    .long = "jobs",
                    .value_type = .i64,
                    .default = "4",
                    .help = "Number of parallel jobs",
                },
            },
        },
    },
    .subcommand_required = true,
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
        error.MissingSubcommand => {
            std.debug.print("Error: subcommand is required\n", .{});
            std.debug.print("Available subcommands: init, build\n", .{});
            std.process.exit(1);
        },
        error.UnknownSubcommand => {
            std.debug.print("Error: unknown subcommand '{s}'\n", .{diagnostic.provided_value});
            std.debug.print("Available subcommands: init, build\n", .{});
            std.process.exit(1);
        },
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

    if (result.verbose) {
        std.debug.print("[verbose mode enabled]\n", .{});
    }

    // subcommand_required = true makes result.subcommand non-optional,
    // allowing a direct switch without null check.
    switch (result.subcommand) {
        .init => |init_result| {
            std.debug.print("Initializing project '{s}'\n", .{init_result.name});
        },
        .build => |build_result| {
            const mode: []const u8 = if (build_result.release) "release" else "debug";
            std.debug.print("Building project ({s} mode, {d} jobs)\n", .{ mode, build_result.jobs });
        },
    }
}
