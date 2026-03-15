# parsz

A declarative command-line argument parser for Zig — zero dependencies, comptime-validated, GNU-style.

## Features

- **Struct-as-schema** — Define your CLI interface entirely through Zig struct types. Field types (`bool`, `?T`, `[]const T`, `union(enum)`) determine parsing behavior automatically.
- **Comptime validation** — 18+ compile-time checks catch invalid configurations (duplicate flags, unknown keys, invalid constraint targets, etc.) before your program runs.
- **GNU-style parsing** — Option/operand permutation, `--` end-of-options, short clustering (`-abc`), inline values (`--opt=val`, `-oval`).
- **Auto help generation** — Built-in `-h`/`--help` detection with automatic usage and help text rendering from spec.
- **Constraint engine** — Declarative `conflicts_with`, `requires`, and `required_unless_present` rules with compile-time target validation and runtime evaluation.
- **Zero external dependencies** — Zig standard library only.

## Quick Start

```zig
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
```

Running `sample --help` produces:

```
A sample CLI application

Usage: sample [OPTIONS] <INPUT>

Arguments:
  <INPUT>  Input file

Options:
  -v, --verbose        Enable verbose output
  -o, --output <PATH>  Output file path [default: out.txt]
      --count <COUNT>  Repeat count [default: 1]
  -h, --help           Print help
```

## Supported

- Boolean flags, named options (short/long), positional arguments
- Required, optional, and default-valued arguments
- Multiple values (`[]const T`)
- Count action (`.action = .count`)
- Subcommands (nested, required, optional) via `union(enum)`
- String, integer, float, bool-from-string, enum value types
- GNU-style permutation, `--` end-of-options, short clustering, inline values
- Auto help (`-h`/`--help`) with usage string generation
- Per-arg help text and value names
- `conflicts_with`, `requires`, `required_unless_present` constraints
- 12 error types with diagnostic context
- 18+ compile-time validation checks

## Not Supported

- Value delimiters (e.g. `--opt=a,b,c` comma splitting)
- Fixed arity (`num_args(2)`)
- Path types, custom value parsers
- Global options, subcommand aliases
- Colored error output, did-you-mean suggestions
- Argument groups
- Auto version (`-V`/`--version`)

See [docs/unsupported-cases.md](docs/unsupported-cases.md) for rationale on each unsupported case.

## Requirements

- Zig 0.15.2+
- No external dependencies

## Build & Test

```bash
zig build test                               # Run all tests
zig build test -- --test-filter "golden:"    # Run golden tests only
zig fmt --check .                            # Format check
```

## Detailed Feature Matrix

See [docs/capability-matrix.md](docs/capability-matrix.md) for a full feature-by-feature comparison with Clap.
