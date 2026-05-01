const std = @import("std");
const builtin = @import("builtin");
const parsz = @import("parsz");

const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const default_iterations: usize = 100_000;
const arena_size = 128 * 1024;

const Mode = enum {
    fast,
    small,
};

const BasicCli = parsz.Command(.{
    .name = "basic",
    .args = .{
        .verbose = parsz.flag(.{
            .short = 'v',
            .long = "verbose",
            .action = .count,
        }),
        .quiet = parsz.flag(.{
            .short = 'q',
            .long = "quiet",
        }),
        .count = parsz.option(u32, .{
            .short = 'n',
            .long = "count",
            .default = 1,
        }),
        .mode = parsz.option(Mode, .{
            .long = "mode",
            .default = .fast,
        }),
        .input = parsz.operand([]const u8, .{
            .required = true,
        }),
    },
});

const AppendCli = parsz.Command(.{
    .name = "append",
    .args = .{
        .include = parsz.option([]const u8, .{
            .short = 'I',
            .long = "include",
            .action = .append,
        }),
        .define = parsz.option([]const u8, .{
            .short = 'D',
            .long = "define",
            .action = .append,
        }),
        .input = parsz.operand([]const u8, .{
            .required = true,
        }),
    },
});

const Add = parsz.Command(.{
    .name = "add",
    .args = .{
        .left = parsz.operand(i64, .{
            .required = true,
        }),
        .right = parsz.operand(i64, .{
            .required = true,
        }),
    },
});

const Repeat = parsz.Command(.{
    .name = "repeat",
    .args = .{
        .count = parsz.option(u8, .{
            .short = 'n',
            .long = "count",
            .default = 2,
        }),
        .word = parsz.operand([]const u8, .{
            .required = true,
        }),
    },
});

const SubcommandCli = parsz.Command(.{
    .name = "toolbox",
    .args = .{},
    .subcommands = .{
        .add = Add,
        .repeat = Repeat,
    },
});

const basic_argv = [_][]const u8{
    "basic",
    "--verbose",
    "-q",
    "-n",
    "42",
    "--mode=small",
    "input.txt",
};

const permutation_argv = [_][]const u8{
    "basic",
    "input.txt",
    "--mode",
    "small",
    "-vv",
    "--count=42",
};

const append_argv = [_][]const u8{
    "append",
    "-Iinclude",
    "--include",
    "src",
    "-DDEBUG=1",
    "--define=TRACE=1",
    "main.zig",
};

const subcommand_argv = [_][]const u8{
    "toolbox",
    "repeat",
    "--count",
    "3",
    "zig",
};

const benchmarks = .{
    .{ .name = "basic options and operand", .run = benchBasic },
    .{ .name = "gnu-style permutation", .run = benchPermutation },
    .{ .name = "append options", .run = benchAppend },
    .{ .name = "subcommand", .run = benchSubcommand },
};

pub fn main(init: std.process.Init) !void {
    const iterations = try readIterations(init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    try stdout.print("zig={s} optimize={s} iterations={d}\n", .{
        builtin.zig_version_string,
        @tagName(builtin.mode),
        iterations,
    });

    inline for (benchmarks) |benchmark| {
        try runBenchmark(init.io, stdout, benchmark.name, benchmark.run, iterations);
    }

    try stdout.flush();
}

fn readIterations(init: std.process.Init) !usize {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    if (!args.skip()) {
        return default_iterations;
    }

    const raw_iterations = args.next() orelse {
        return default_iterations;
    };
    if (args.next() != null) {
        return error.InvalidBenchmarkArguments;
    }

    const iterations = std.fmt.parseInt(usize, raw_iterations, 10) catch return error.InvalidBenchmarkIterations;
    if (iterations == 0) {
        return error.InvalidBenchmarkIterations;
    }

    return iterations;
}

fn runBenchmark(
    io: std.Io,
    stdout: *std.Io.Writer,
    comptime name: []const u8,
    comptime run: anytype,
    iterations: usize,
) !void {
    var memory: [arena_size]u8 = undefined;
    var fba = FixedBufferAllocator.init(&memory);
    const allocator = fba.allocator();

    var peak_bytes: usize = 0;

    const warmup_iterations = @min(iterations, 10_000);
    var warmup_index: usize = 0;
    while (warmup_index < warmup_iterations) : (warmup_index += 1) {
        fba.reset();
        peak_bytes = @max(peak_bytes, try run(allocator, &fba));
    }

    const clock: std.Io.Clock = .awake;
    const start = clock.now(io);

    var index: usize = 0;
    while (index < iterations) : (index += 1) {
        fba.reset();
        peak_bytes = @max(peak_bytes, try run(allocator, &fba));
    }

    const elapsed = start.durationTo(clock.now(io));
    const total_ns = elapsed.toNanoseconds();
    const ns_per_iter = @divTrunc(total_ns, @as(i96, @intCast(iterations)));

    try stdout.print("{s}: total_ns={d} ns_per_iter={d} peak_bytes={d}\n", .{
        name,
        total_ns,
        ns_per_iter,
        peak_bytes,
    });
}

fn benchBasic(allocator: Allocator, fba: *FixedBufferAllocator) !usize {
    std.mem.doNotOptimizeAway(&basic_argv);
    var result = try BasicCli.parse(allocator, basic_argv[0..], .{});
    const peak_bytes = fba.end_index;
    std.mem.doNotOptimizeAway(&result);
    switch (result) {
        .parsed => {},
        .help => return error.UnexpectedBenchmarkResult,
    }
    BasicCli.deinit(allocator, &result);
    return peak_bytes;
}

fn benchPermutation(allocator: Allocator, fba: *FixedBufferAllocator) !usize {
    std.mem.doNotOptimizeAway(&permutation_argv);
    var result = try BasicCli.parse(allocator, permutation_argv[0..], .{});
    const peak_bytes = fba.end_index;
    std.mem.doNotOptimizeAway(&result);
    switch (result) {
        .parsed => {},
        .help => return error.UnexpectedBenchmarkResult,
    }
    BasicCli.deinit(allocator, &result);
    return peak_bytes;
}

fn benchAppend(allocator: Allocator, fba: *FixedBufferAllocator) !usize {
    std.mem.doNotOptimizeAway(&append_argv);
    var result = try AppendCli.parse(allocator, append_argv[0..], .{});
    const peak_bytes = fba.end_index;
    std.mem.doNotOptimizeAway(&result);
    switch (result) {
        .parsed => {},
        .help => return error.UnexpectedBenchmarkResult,
    }
    AppendCli.deinit(allocator, &result);
    return peak_bytes;
}

fn benchSubcommand(allocator: Allocator, fba: *FixedBufferAllocator) !usize {
    std.mem.doNotOptimizeAway(&subcommand_argv);
    var result = try SubcommandCli.parse(allocator, subcommand_argv[0..], .{});
    const peak_bytes = fba.end_index;
    std.mem.doNotOptimizeAway(&result);
    switch (result) {
        .subcommand => {},
        .parsed, .help => return error.UnexpectedBenchmarkResult,
    }
    SubcommandCli.deinit(allocator, &result);
    return peak_bytes;
}
