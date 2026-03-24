const std = @import("std");
const parsz = @import("parsz");

test "parse skips argv[0] and supports mixed flags" {
    const Cli = struct {
        verbose: parsz.Flag(.{
            .short = 'v',
        }),
        dry_run: parsz.Flag(.{
            .short = 'd',
            .long = "dry-run",
        }),
        quiet: parsz.Flag(.{
            .short = 'q',
        }),
    };

    const argv = [_][]const u8{
        "--not-a-real-argv0",
        "-vq",
        "--dry-run",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expect(value.verbose);
    try std.testing.expect(value.quiet);
    try std.testing.expect(value.dry_run);
}

test "parse supports long options with space and equals forms" {
    const Cli = struct {
        count: parsz.Option(u32, .{
            .long = "count",
        }),
        output: parsz.Option(?[]const u8, .{
            .long = "output",
        }),
    };

    const argv = [_][]const u8{
        "demo",
        "--count",
        "7",
        "--output=log.txt",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expectEqual(@as(u32, 7), value.count);
    try std.testing.expectEqualStrings("log.txt", value.output.?);
}

test "parse supports short options with separate, inline, and empty values" {
    const Cli = struct {
        count: parsz.Option(u32, .{
            .short = 'c',
        }),
        output: parsz.Option([]const u8, .{
            .short = 'o',
        }),
        label: parsz.Option([]const u8, .{
            .long = "label",
        }),
    };

    const argv = [_][]const u8{
        "demo",
        "-c",
        "7",
        "-ofile.txt",
        "--label=",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expectEqual(@as(u32, 7), value.count);
    try std.testing.expectEqualStrings("file.txt", value.output);
    try std.testing.expectEqualStrings("", value.label);
}

test "parse consumes positional values in declaration order and preserves optional omission" {
    const Cli = struct {
        input: parsz.Positional([]const u8, .{}),
        retries: parsz.Positional(?u32, .{}),
    };

    const argv = [_][]const u8{
        "demo",
        "input.txt",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expectEqualStrings("input.txt", value.input);
    try std.testing.expectEqual(@as(?u32, null), value.retries);
}

test "parse handles option values, terminator, and negative numeric positionals" {
    const Cli = struct {
        output: parsz.Option([]const u8, .{
            .short = 'o',
        }),
        delta: parsz.Positional(i32, .{}),
        literal: parsz.Positional([]const u8, .{}),
    };

    const argv = [_][]const u8{
        "demo",
        "-o",
        "--",
        "-42",
        "--",
        "--literal",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expectEqualStrings("--", value.output);
    try std.testing.expectEqual(@as(i32, -42), value.delta);
    try std.testing.expectEqualStrings("--literal", value.literal);
}

test "parse supports bool option and bool positional values" {
    const Cli = struct {
        enabled: parsz.Option(bool, .{
            .long = "enabled",
        }),
        confirm: parsz.Positional(bool, .{}),
    };

    const argv = [_][]const u8{
        "demo",
        "--enabled",
        "true",
        "false",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expectEqual(true, value.enabled);
    try std.testing.expectEqual(false, value.confirm);
}

test "parse returns runtime errors for invalid inputs" {
    const Mode = enum {
        fast,
        slow,
    };

    const Cli = struct {
        verbose: parsz.Flag(.{
            .long = "verbose",
            .short = 'v',
        }),
        count: parsz.Option(u32, .{
            .short = 'c',
        }),
        mode: parsz.Option(?Mode, .{
            .long = "mode",
        }),
        input: parsz.Positional([]const u8, .{}),
    };

    try std.testing.expectError(error.UnknownOption, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "--unknown",
        "value",
        "input.txt",
    }));

    try std.testing.expectError(error.MissingOptionValue, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "-c",
    }));

    try std.testing.expectError(error.MissingRequiredOption, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "input.txt",
    }));

    try std.testing.expectError(error.MissingRequiredPositional, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "-c",
        "3",
    }));

    try std.testing.expectError(error.UnexpectedArgument, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "--verbose=true",
        "-c",
        "3",
        "input.txt",
    }));

    try std.testing.expectError(error.UnexpectedArgument, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "-c",
        "3",
        "input.txt",
        "extra.txt",
    }));

    try std.testing.expectError(error.DuplicateOption, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "-vv",
        "-c",
        "3",
        "input.txt",
    }));

    try std.testing.expectError(error.InvalidValue, parsz.parse(Cli, std.testing.allocator, &[_][]const u8{
        "demo",
        "-c",
        "3",
        "--mode",
        "medium",
        "input.txt",
    }));
}

test "parse keeps borrowed string results zero copy" {
    const Cli = struct {
        output: parsz.Option(?[]const u8, .{
            .long = "output",
        }),
        input: parsz.Positional([]const u8, .{}),
    };

    const argv = [_][]const u8{
        "demo",
        "--output",
        "out.txt",
        "input.txt",
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expect(value.output.?.ptr == argv[2].ptr);
    try std.testing.expect(value.input.ptr == argv[3].ptr);
}

test "parse preserves sentinel borrowed string values when argv tokens are sentinel backed" {
    const Cli = struct {
        path: parsz.Option(?[:0]const u8, .{
            .long = "path",
        }),
    };

    const argv_storage = [_][:0]const u8{
        "demo",
        "--path",
        "sentinel.txt",
    };
    const argv = [_][]const u8{
        argv_storage[0],
        argv_storage[1],
        argv_storage[2],
    };

    var value = try parsz.parse(Cli, std.testing.allocator, &argv);
    defer parsz.deinit(Cli, std.testing.allocator, &value);

    try std.testing.expect(value.path.?.ptr == argv_storage[2].ptr);
    try std.testing.expectEqual(@as(u8, 0), value.path.?[value.path.?.len]);
}

test "parse does not require heap allocation for fixed scalar outputs" {
    const Cli = struct {
        verbose: parsz.Flag(.{
            .short = 'v',
        }),
        count: parsz.Option(u32, .{
            .short = 'c',
        }),
        input: parsz.Positional([]const u8, .{}),
    };

    var buffer: [0]u8 = .{};
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&buffer);
    const argv = [_][]const u8{
        "demo",
        "-v",
        "-c",
        "5",
        "input.txt",
    };

    var value = try parsz.parse(Cli, fixed_buffer_allocator.allocator(), &argv);
    defer parsz.deinit(Cli, fixed_buffer_allocator.allocator(), &value);

    try std.testing.expect(value.verbose);
    try std.testing.expectEqual(@as(u32, 5), value.count);
    try std.testing.expectEqualStrings("input.txt", value.input);
}
